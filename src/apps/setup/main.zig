//! Dazzle's setup app: runs on the first start only, with the whole screen
//! (the shell shows no dock while it runs). It asks for the computer's name
//! and the apps to install (and, later, more), a page at a time (see
//! view.zig), while init's system manager makes the SD card's free space a
//! place for files (see sys.system). The list of apps is downloaded once
//! that is ready (they are kept there; see the store module). Then it
//! installs the apps chosen, tells the manager to finish, which names the
//! computer and marks setup done, and ends. It lives in /os/shell with the
//! shell: it cannot be removed.
//!
//!     dazzle-setup [font.ttf]

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const ui = @import("ui");
const store = @import("store");
const build_info = @import("build_info");
const names = @import("names.zig");
const view = @import("view.zig");

const proto = sys.system;
const net = sys.network;
const print = sys.print;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    run(init, font_path) catch |err| {
        print(sys.log_error ++ "dazzle-setup: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    const start_locale = locale.load();
    locale.current = start_locale.language;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Setup",
        .app_id = "dazzle-setup",
        .size = view.open_size,
        .font_path = font_path,
    });
    defer a.close();
    a.sync_keyboard = false;
    a.ui.keyboard = start_locale.keyboard;

    var name_buf: [32]u8 = undefined;
    const suggestion = names.random(&name_buf);
    var actions: view.Actions = .{};
    // The apps that can be installed (once the card is ready), and those
    // chosen, left to install.
    var server_url_buf: [store.max_url_len]u8 = undefined;
    var apps: store.Store = .init(gpa, store.loadServerUrl(&server_url_buf, build_info.apps_url));
    var named = false;
    var wait_network_until: u64 = 0;
    var retry_at: u64 = 0;
    var queue: ?u64 = null;
    var installed: usize = 0;
    var total: usize = 0;

    // Show the first page at once before talking to the system and network
    // managers.
    try a.draw(sys.nowNs(), view.Setup{
        .suggestion = suggestion,
        .locale = start_locale,
        .actions = &actions,
    });

    // All talking to the system and network managers runs on a worker thread
    // so the UI thread never blocks on sockets or network bring-up.
    const worker = try Worker.start();
    defer worker.stop();
    a.win.wake_fd = worker.wakeFd();

    var report: ?proto.Report = null;
    var net_report: ?net.Report = null;
    var wait_eth_until: u64 = 0;
    var finish_sent = false;

    while (true) {
        const before_step = sys.nowNs();
        const wait_net = named and apps.apps().len == 0 and apps.job == null and queue == null and before_step < wait_network_until;
        const wait_eth = named and before_step < wait_eth_until;
        const wake = @min(
            if (wait_net or apps.job != null) before_step + 250 * std.time.ns_per_ms else std.math.maxInt(u64),
            if (wait_eth) wait_eth_until else std.math.maxInt(u64),
        );
        if (!try a.step(@max(wake -| before_step, std.time.ns_per_ms))) break;
        const now = sys.nowNs();
        a.takeInput();

        const prev_eth_connected = if (net_report) |r|
            r.ethernetConnected() or (r.ethernetCarrier() and (!named or now < wait_eth_until))
        else
            false;
        if (worker.take(&report, &net_report)) |done| {
            if (done) return;
            a.dirty = true;
        }
        const eth_connected = if (net_report) |r|
            r.ethernetConnected() or (r.ethernetCarrier() and (!named or now < wait_eth_until))
        else
            false;
        if (eth_connected != prev_eth_connected) {
            a.dirty = true;
            // If a plugged-in Ethernet cable timed out waiting for DHCP and a
            // Wi-Fi adapter is available, step back to the Wi-Fi page.
            if (!eth_connected and net_report != null and net_report.?.wifiAdapters().len > 0) {
                if (a.ui.root) |root| {
                    const st = root.state(view.Setup.State);
                    if (view.pages[st.page] == .apps and !actions.skip_wifi and actions.finish == null) {
                        st.page = @intFromEnum(view.Page.wifi);
                    }
                }
            }
        }

        // A language or keyboard picked: used now, and kept.
        if (actions.locale) |l| {
            actions.locale = null;
            locale.current = l.language;
            a.ui.keyboard = l.keyboard;
            worker.setLocale(l);
            a.dirty = true;
        }
        // The computer's name, confirmed on its page: set now so the
        // network connects with it before the list of apps is fetched.
        if (actions.hostname) |h| {
            actions.hostname = null;
            if (!named) {
                named = true;
                wait_eth_until = now + 3 * std.time.ns_per_s;
                wait_network_until = now + 10 * std.time.ns_per_s;
                retry_at = 0;
            }
            worker.setHostname(h);
            a.dirty = true;
        }
        if (actions.connect) |j| {
            actions.connect = null;
            worker.connect(j);
            wait_network_until = now + 10 * std.time.ns_per_s;
            retry_at = 0;
            a.dirty = true;
        }
        if (actions.disconnect) {
            actions.disconnect = false;
            worker.disconnect();
            a.dirty = true;
        }
        if (actions.skip_wifi) {
            actions.skip_wifi = false;
            wait_network_until = 0;
            retry_at = 0;
            a.dirty = true;
        }

        const on_wifi_page = if (a.ui.root) |root| view.pages[root.state(view.Setup.State).page] == .wifi else false;
        const wifi_selected = if (a.ui.root) |root| root.state(view.Setup.State).has_selected else false;
        worker.setPageState(on_wifi_page, wifi_selected, actions.finish != null);

        const storage_now: proto.StorageState = if (report) |r| r.storage else .none;
        const net_ready = if (net_report) |r| r.ready else false;
        // The list of apps, kept on the card: once the computer is named
        // and the card and network are ready, and again every while until
        // it comes (the network is brought up once the name is confirmed).
        if (apps.poll()) a.dirty = true;
        if (named and storage_now == .ready and apps.job == null and apps.apps().len == 0 and queue == null and now >= retry_at) {
            if (net_ready or (!on_wifi_page and now >= wait_network_until)) {
                apps.refresh(true);
                retry_at = now + 10 * std.time.ns_per_s;
                a.dirty = true;
            }
        }
        // The pages are done: finish once the card is ready (or there is
        // none, or it failed and that has been accepted), after installing
        // the apps chosen.
        if (actions.finish) |h| {
            const storage: proto.StorageState = if (report) |r| r.storage else .none;
            const can = switch (storage) {
                .ready, .none => true,
                .failed => actions.without_storage,
                .preparing, .unprepared => false,
            };
            // The apps first (with a card to put them on), one at a time.
            var apps_done = true;
            if (can and storage == .ready) {
                if (apps.job != null) {
                    apps_done = false;
                } else {
                    if (queue == null) {
                        const n = @min(apps.apps().len, view.max_apps);
                        queue = actions.apps & if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
                        total = @popCount(queue.?);
                    }
                    if (queue.? != 0) {
                        const item = apps.apps()[@ctz(queue.?)];
                        queue.? &= queue.? - 1;
                        installed = total - @popCount(queue.?) - 1;
                        print("dazzle-setup: installing {s}\n", .{item.name});
                        apps.install(item.name);
                        apps_done = false;
                        a.dirty = true;
                    }
                }
            }
            if (can and apps_done and !finish_sent) {
                finish_sent = true;
                worker.finish(h);
            }
        }

        try a.draw(sys.nowNs(), view.Setup{
            .suggestion = suggestion,
            .locale = start_locale,
            .report = if (report) |*r| r else null,
            .wifi = if (net_report) |*r| r else null,
            .ethernet_connected = if (net_report) |r|
                r.ethernetConnected() or (r.ethernetCarrier() and (!named or now < wait_eth_until))
            else
                false,
            .apps = .{
                .list = apps.apps(),
                .loading = apps.job != null,
                .message = apps.message(),
                .installing = if (apps.busy()) |name| (if (name.len > 0) apps.title(name) else null) else null,
                .done = installed,
                .total = total,
            },
            .actions = &actions,
        });
    }
}

/// Talks to `system` and `network` on a background thread so the UI thread
/// never waits on socket IPC or DHCP.
const Worker = struct {
    mutex: Lock = .{},
    cmd_fds: [2]linux.fd_t = .{ -1, -1 },
    wake_fds: [2]linux.fd_t = .{ -1, -1 },
    thread: ?std.Thread = null,

    stopping: bool = false,
    on_wifi_page: bool = false,
    wifi_selected: bool = false,
    finishing: bool = false,
    pending_locale: ?locale.Settings = null,
    pending_hostname: ?proto.Hostname = null,
    pending_connect: ?view.Actions.Join = null,
    pending_disconnect: bool = false,
    pending_finish: ?proto.Hostname = null,

    report: ?proto.Report = null,
    net_report: ?net.Report = null,
    changed: bool = false,
    finished: bool = false,

    fn start() !*Worker {
        const gpa = std.heap.page_allocator;
        const w = try gpa.create(Worker);
        errdefer gpa.destroy(w);
        w.* = .{};
        _ = try sys.check(linux.pipe2(&w.cmd_fds, .{ .CLOEXEC = true, .NONBLOCK = true }));
        errdefer {
            sys.close(w.cmd_fds[0]);
            sys.close(w.cmd_fds[1]);
        }
        _ = try sys.check(linux.pipe2(&w.wake_fds, .{ .CLOEXEC = true, .NONBLOCK = true }));
        errdefer {
            sys.close(w.wake_fds[0]);
            sys.close(w.wake_fds[1]);
        }
        w.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Worker.loop, .{w});
        return w;
    }

    fn stop(w: *Worker) void {
        w.mutex.lock();
        w.stopping = true;
        w.mutex.unlock();
        poke(w.cmd_fds[1]);
        if (w.thread) |t| t.join();
        sys.close(w.cmd_fds[0]);
        sys.close(w.cmd_fds[1]);
        sys.close(w.wake_fds[0]);
        sys.close(w.wake_fds[1]);
        std.heap.page_allocator.destroy(w);
    }

    fn wakeFd(w: *const Worker) linux.fd_t {
        return w.wake_fds[0];
    }

    /// Drains the wake pipe and copies out the latest reports if anything
    /// changed; returns `true` when `finish` has completed, `false` when
    /// reports were updated, or `null` when nothing changed.
    fn take(w: *Worker, report: *?proto.Report, net_report: *?net.Report) ?bool {
        drain(w.wake_fds[0]);
        w.mutex.lock();
        defer w.mutex.unlock();
        if (!w.changed) return null;
        w.changed = false;
        if (w.report) |r| report.* = r;
        if (w.net_report) |r| net_report.* = r;
        return w.finished;
    }

    fn setLocale(w: *Worker, l: locale.Settings) void {
        w.mutex.lock();
        w.pending_locale = l;
        w.mutex.unlock();
        poke(w.cmd_fds[1]);
    }

    fn setHostname(w: *Worker, h: proto.Hostname) void {
        w.mutex.lock();
        w.pending_hostname = h;
        w.mutex.unlock();
        poke(w.cmd_fds[1]);
    }

    fn connect(w: *Worker, j: view.Actions.Join) void {
        w.mutex.lock();
        w.pending_connect = j;
        w.mutex.unlock();
        poke(w.cmd_fds[1]);
    }

    fn disconnect(w: *Worker) void {
        w.mutex.lock();
        w.pending_disconnect = true;
        w.mutex.unlock();
        poke(w.cmd_fds[1]);
    }

    fn finish(w: *Worker, h: proto.Hostname) void {
        w.mutex.lock();
        w.pending_finish = h;
        w.finishing = true;
        w.mutex.unlock();
        poke(w.cmd_fds[1]);
    }

    fn setPageState(w: *Worker, on_wifi_page: bool, wifi_selected: bool, finishing: bool) void {
        w.mutex.lock();
        const wake = (on_wifi_page and !w.on_wifi_page) or (finishing and !w.finishing);
        w.on_wifi_page = on_wifi_page;
        w.wifi_selected = wifi_selected;
        w.finishing = finishing;
        w.mutex.unlock();
        if (wake) poke(w.cmd_fds[1]);
    }

    fn publishSystem(w: *Worker, r: proto.Report) void {
        w.mutex.lock();
        const changed = w.report == null or
            w.report.?.storage != r.storage or
            w.report.?.progress != r.progress or
            w.report.?.failure != r.failure;
        w.report = r;
        if (changed) w.changed = true;
        w.mutex.unlock();
        if (changed) poke(w.wake_fds[1]);
    }

    fn publishNet(w: *Worker, r: net.Report) void {
        w.mutex.lock();
        w.net_report = r;
        w.changed = true;
        w.mutex.unlock();
        poke(w.wake_fds[1]);
    }

    fn isStopping(w: *Worker) bool {
        w.mutex.lock();
        defer w.mutex.unlock();
        return w.stopping;
    }

    fn loop(w: *Worker) void {
        var sys_rep: ?proto.Report = ask("prepare\n");
        if (sys_rep) |r| w.publishSystem(r);
        if (w.isStopping()) return;

        var net_rep: ?net.Report = net.ask("wifi scan\n");
        if (net_rep) |r| w.publishNet(r);

        var named = false;
        var was_wifi_page = false;
        var next_ask: u64 = sys.nowNs() + std.time.ns_per_s;
        var next_net_ask: u64 = sys.nowNs() + 3 * std.time.ns_per_s;

        while (true) {
            drain(w.cmd_fds[0]);
            w.mutex.lock();
            if (w.stopping) {
                w.mutex.unlock();
                return;
            }
            const loc = w.pending_locale;
            w.pending_locale = null;
            const host = w.pending_hostname;
            w.pending_hostname = null;
            const conn = w.pending_connect;
            w.pending_connect = null;
            const disc = w.pending_disconnect;
            w.pending_disconnect = false;
            const fin = w.pending_finish;
            w.pending_finish = null;
            const on_wifi_page = w.on_wifi_page;
            const wifi_selected = w.wifi_selected;
            const finishing = w.finishing;
            w.mutex.unlock();

            if (loc) |l| {
                var req_buf: [64]u8 = undefined;
                sys_rep = ask(std.fmt.bufPrint(&req_buf, "locale {s} {s}\n", .{ l.language.code(), l.keyboard.code() }) catch "");
                if (sys_rep) |r| w.publishSystem(r);
            }
            if (host) |h| {
                named = true;
                var req_buf: [96]u8 = undefined;
                sys_rep = ask(std.fmt.bufPrint(&req_buf, "hostname {s}\n", .{h.slice()}) catch "");
                if (sys_rep) |r| w.publishSystem(r);
                net_rep = net.ask("wifi scan\n");
                if (net_rep) |r| w.publishNet(r);
                // If an Ethernet cable is plugged in, poll while DHCP gets
                // an address and configures DNS.
                if (net_rep != null and net_rep.?.ethernetCarrier() and !net_rep.?.ethernetConnected()) {
                    const deadline = sys.nowNs() + 3 * std.time.ns_per_s;
                    while (sys.nowNs() < deadline and !w.isStopping()) {
                        sys.sleepMs(100);
                        net_rep = net.ask("status\n");
                        if (net_rep) |r| {
                            w.publishNet(r);
                            if (r.ethernetConnected()) break;
                        }
                    }
                }
                next_net_ask = sys.nowNs() + 500 * std.time.ns_per_ms;
            }
            if (conn) |j| {
                var req_buf: [256]u8 = undefined;
                print("dazzle-setup: joining \"{s}\"\n", .{j.ssid()});
                net_rep = net.ask(net.connectRequest(&req_buf, j.ssid(), j.passphrase()));
                if (net_rep) |r| w.publishNet(r);
                next_net_ask = sys.nowNs() + 500 * std.time.ns_per_ms;
            }
            if (disc) {
                var req_buf: [64]u8 = undefined;
                net_rep = net.ask(net.disconnectRequest(&req_buf, ""));
                if (net_rep) |r| w.publishNet(r);
                next_net_ask = sys.nowNs() + 500 * std.time.ns_per_ms;
            }
            if (fin) |h| {
                var req_buf: [96]u8 = undefined;
                const req = std.fmt.bufPrint(&req_buf, "finish {s}\n", .{h.slice()}) catch "";
                _ = ask(req);
                print("dazzle-setup: finished; the computer is {s}\n", .{h.slice()});
                w.mutex.lock();
                w.finished = true;
                w.changed = true;
                w.mutex.unlock();
                poke(w.wake_fds[1]);
                return;
            }

            if (on_wifi_page and !was_wifi_page) next_net_ask = 0;
            was_wifi_page = on_wifi_page;

            const now = sys.nowNs();
            if (now >= next_ask or (finishing and next_ask > now + 250 * std.time.ns_per_ms)) {
                const need_prepare = sys_rep == null or sys_rep.?.storage == .unprepared;
                sys_rep = ask(if (need_prepare) "prepare\n" else "status\n");
                if (sys_rep) |r| w.publishSystem(r);
                const preparing = if (sys_rep) |r| r.storage == .preparing or r.storage == .unprepared else true;
                next_ask = if (preparing) sys.nowNs() + @as(u64, if (finishing) 250 else 1000) * std.time.ns_per_ms else std.math.maxInt(u64);
            }
            if (sys.nowNs() >= next_net_ask) {
                const need_bg = net_rep == null or net_rep.?.wifiAdapters().len == 0 or (net_rep.?.scanning and net_rep.?.len == 0) or (named and !net_rep.?.ready);
                if (on_wifi_page or need_bg) {
                    const need_scan = (on_wifi_page and !wifi_selected) or if (net_rep) |r| r.len == 0 else true;
                    net_rep = net.ask(if (need_scan) "wifi scan\n" else "status\n");
                    if (net_rep) |r| w.publishNet(r);
                    const busy = if (net_rep) |r| r.scanning or r.connection.state == .connecting or r.connection.state == .authenticating or r.connection.state == .addressing else false;
                    const fast = (on_wifi_page and busy) or (named and (net_rep == null or !net_rep.?.ready));
                    next_net_ask = sys.nowNs() + @as(u64, if (fast) 1000 else 3000) * std.time.ns_per_ms;
                } else {
                    next_net_ask = std.math.maxInt(u64);
                }
            }

            const after = sys.nowNs();
            const wake_ns = @min(next_ask, next_net_ask);
            const timeout_ms: i32 = if (wake_ns == std.math.maxInt(u64))
                -1
            else
                @intCast(@min((wake_ns -| after) / std.time.ns_per_ms, std.math.maxInt(i32)));
            var pfd = [1]linux.pollfd{.{ .fd = w.cmd_fds[0], .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, timeout_ms);
        }
    }
};

const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(l: *Lock) void {
        while (l.held.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            sys.sleepUs(50);
        }
    }

    fn unlock(l: *Lock) void {
        l.held.store(false, .release);
    }
};

fn poke(fd: linux.fd_t) void {
    const byte = [1]u8{1};
    _ = linux.write(fd, &byte, 1);
}

fn drain(fd: linux.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
    }
}

/// Sends the system manager a request (preparing the card can take it a
/// moment to answer).
fn ask(request: []const u8) ?proto.Report {
    return proto.ask(request, 5000);
}

test {
    _ = names;
    _ = view;
}
