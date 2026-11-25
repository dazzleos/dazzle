//! Dazzle's setup app: runs on the first start only, with the whole screen
//! (the shell shows no dock while it runs). It asks for the language, the
//! keyboard, the computer's name, the network and the time zone, a page at
//! a time (see view.zig), while init's system manager makes the SD card's
//! free space a place for files (see sys.system). Then it tells the manager
//! to finish, which names the computer and marks setup done, and ends.
//! Apps are installed from Settings. It lives in /os/shell with the shell:
//! it cannot be removed.
//!
//!     dazzle-setup

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const names = @import("names.zig");
const view = @import("view.zig");

const proto = sys.system;
const net = sys.network;
const print = sys.print;

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-setup: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// What the window shows: the page, and what is known so far.
const Shown = struct {
    suggestion: []const u8,
    start_locale: locale.Settings,
    actions: *view.Actions,
    report: ?proto.Report = null,
    net_report: ?net.Report = null,
    ethernet_connected: bool = false,

    pub fn build(s: *const Shown, cx: *kete.BuildContext) kete.Widget {
        return cx.make(view.Setup{
            .suggestion = s.suggestion,
            .locale = s.start_locale,
            .report = if (s.report) |*r| r else null,
            .wifi = if (s.net_report) |*r| r else null,
            .ethernet_connected = s.ethernet_connected,
            .actions = s.actions,
        });
    }
};

/// The pages' state (which is showing), in the window's widgets.
fn pageState(window: *kete.App.Window) ?*view.Setup.State {
    const root = window.ui.root orelse return null;
    const n = find(root) orelse return null;
    return n.state(view.Setup.State);
}

fn find(n: *kete.WidgetNode) ?*kete.WidgetNode {
    if (n.widget.is(view.Setup)) return n;
    for (n.children.items) |ch| if (find(ch)) |f| return f;
    return null;
}

fn run(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const start_locale = locale.load();
    locale.current = start_locale.language;
    var host: kete_vc4.Host = undefined;
    // The whole screen, with no title bar: it is the only window.
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-setup", .decorations = .none });
    defer host.deinit();
    // The keyboard chosen here, not yet the system's.
    host.display.setKeyboard(start_locale.keyboard);

    var name_buf: [32]u8 = undefined;
    const suggestion = names.random(&name_buf);
    var actions: view.Actions = .{};
    // No time zone yet: the language's, as the first page shows it, kept
    // whether or not another is picked.
    if (start_locale.timezone == .utc) actions.locale = .{
        .language = start_locale.language,
        .keyboard = start_locale.keyboard,
        .timezone = start_locale.language.timeZone(),
    };
    var named = false;

    var shown: Shown = .{ .suggestion = suggestion, .start_locale = start_locale, .actions = &actions };
    const window = try host.app.openWindow(.{
        .title = locale.text("Setup"),
        .root = .of(&shown),
        .size = view.open_size,
        .on_close_request = .close,
    });
    // The whole screen (the first page is "Hello" all over it).
    window.setFullscreen(true);
    // Show the first page at once before talking to the system and network
    // managers.
    _ = try host.step(0);

    // All talking to the system and network managers runs on a worker thread
    // so the UI thread never blocks on sockets or network bring-up.
    const worker = try Worker.start();
    defer worker.stop();
    host.wakeOn(worker.wakeFd(), true);

    var report: ?proto.Report = null;
    var net_report: ?net.Report = null;
    var wait_eth_until: u64 = 0;
    var finish_sent = false;

    while (true) {
        const before_step = sys.nowNs();
        const wait_eth = named and before_step < wait_eth_until;
        const wake = if (wait_eth) wait_eth_until else std.math.maxInt(u64);
        if (!try host.step(@max(wake -| before_step, std.time.ns_per_ms))) break;
        const now = sys.nowNs();

        const prev_eth_connected = if (net_report) |r|
            r.ethernetConnected() or (r.ethernetCarrier() and (!named or now < wait_eth_until))
        else
            false;
        if (worker.take(&report, &net_report)) |done| {
            if (done) return;
            host.redraw();
        }
        const eth_connected = if (net_report) |r|
            r.ethernetConnected() or (r.ethernetCarrier() and (!named or now < wait_eth_until))
        else
            false;
        if (eth_connected != prev_eth_connected) {
            host.redraw();
            // If a plugged-in Ethernet cable timed out waiting for DHCP and a
            // Wi-Fi adapter is available, step back to the Wi-Fi page (from
            // the page after it, which it was passed by for the cable).
            if (!eth_connected and net_report != null and net_report.?.wifiAdapters().len > 0) {
                if (pageState(window)) |st| {
                    if (view.pages[st.page] == .time and !actions.skip_wifi and actions.finish == null) {
                        st.page = @intFromEnum(view.Page.wifi);
                    }
                }
            }
        }

        // A language or keyboard picked: used now, and kept.
        if (actions.locale) |l| {
            actions.locale = null;
            locale.current = l.language;
            window.setTitle(locale.text("Setup"));
            host.display.setKeyboard(l.keyboard);
            worker.setLocale(l);
            host.redraw();
        }
        // The computer's name, confirmed on its page: set now so the
        // network connects with it.
        if (actions.hostname) |h| {
            actions.hostname = null;
            if (!named) {
                named = true;
                wait_eth_until = now + 3 * std.time.ns_per_s;
            }
            worker.setHostname(h);
            host.redraw();
        }
        if (actions.connect) |j| {
            actions.connect = null;
            worker.connect(j);
            host.redraw();
        }
        if (actions.disconnect) {
            actions.disconnect = false;
            worker.disconnect();
            host.redraw();
        }
        if (actions.skip_wifi) {
            actions.skip_wifi = false;
            host.redraw();
        }

        const page_state = pageState(window);
        const on_wifi_page = if (page_state) |st| view.pages[st.page] == .wifi else false;
        const wifi_selected = if (page_state) |st| st.has_selected else false;
        worker.setPageState(on_wifi_page, wifi_selected, actions.finish != null);

        // The pages are done: finish once the card is ready (or there is
        // none, or it failed and that has been accepted).
        if (actions.finish) |h| {
            const storage: proto.StorageState = if (report) |r| r.storage else .none;
            const can = switch (storage) {
                .ready, .none => true,
                .failed => actions.without_storage,
                .preparing, .unprepared => false,
            };
            if (can and !finish_sent) {
                finish_sent = true;
                worker.finish(h);
            }
        }

        shown.report = report;
        shown.net_report = net_report;
        shown.ethernet_connected = if (net_report) |r|
            r.ethernetConnected() or (r.ethernetCarrier() and (!named or now < wait_eth_until))
        else
            false;
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
        var sys_sub: proto.Subscription = .{};
        defer sys_sub.deinit();
        sys_sub.connect();
        var net_sub: net.Subscription = .{};
        defer net_sub.deinit();
        net_sub.connect();

        var sys_rep: ?proto.Report = ask("prepare\n");
        if (sys_rep) |r| w.publishSystem(r);
        if (w.isStopping()) return;

        var net_rep: ?net.Report = net.ask("wifi scan\n");
        if (net_rep) |r| w.publishNet(r);

        var was_wifi_page = false;
        var next_scan: u64 = sys.nowNs() + 5 * std.time.ns_per_s;

        while (true) {
            drain(w.cmd_fds[0]);
            if (sys_sub.fd == null) sys_sub.connect();
            if (sys_sub.poll()) |r| if (!r.denied) {
                sys_rep = r;
                w.publishSystem(r);
            };
            if (net_sub.fd == null) net_sub.connect();
            if (net_sub.poll()) |r| if (!r.denied) {
                net_rep = r;
                w.publishNet(r);
            };

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
            w.mutex.unlock();

            if (loc) |l| {
                var req_buf: [64]u8 = undefined;
                sys_rep = ask(std.fmt.bufPrint(&req_buf, "locale {s} {s} {s}\n", .{ l.language.code(), l.keyboard.code(), l.timezone.name() }) catch "");
                if (sys_rep) |r| w.publishSystem(r);
            }
            if (host) |h| {
                var req_buf: [96]u8 = undefined;
                sys_rep = ask(std.fmt.bufPrint(&req_buf, "hostname {s}\n", .{h.slice()}) catch "");
                if (sys_rep) |r| w.publishSystem(r);
                net_rep = net.ask("wifi scan\n");
                if (net_rep) |r| w.publishNet(r);
                // If an Ethernet cable is plugged in, wait for the network
                // manager's subscription to report that DHCP got an address.
                if (net_rep != null and net_rep.?.ethernetCarrier() and !net_rep.?.ethernetConnected()) {
                    const deadline = sys.nowNs() + 3 * std.time.ns_per_s;
                    while (sys.nowNs() < deadline and !w.isStopping()) {
                        if (net_sub.fd == null) net_sub.connect();
                        const rem_ms: i32 = @intCast(@min((deadline -| sys.nowNs()) / std.time.ns_per_ms, std.math.maxInt(i32)));
                        var wait_fds = [2]linux.pollfd{
                            .{ .fd = w.cmd_fds[0], .events = linux.POLL.IN, .revents = 0 },
                            .{ .fd = net_sub.fd orelse -1, .events = linux.POLL.IN, .revents = 0 },
                        };
                        _ = linux.poll(&wait_fds, wait_fds.len, rem_ms);
                        if (net_sub.poll()) |r| if (!r.denied) {
                            net_rep = r;
                            w.publishNet(r);
                            if (r.ethernetConnected()) break;
                        };
                        if (wait_fds[0].revents != 0) break;
                    }
                }
                next_scan = sys.nowNs() + 5 * std.time.ns_per_s;
            }
            if (conn) |j| {
                var req_buf: [256]u8 = undefined;
                print("dazzle-setup: joining \"{s}\"\n", .{j.ssid()});
                net_rep = net.ask(net.connectRequest(&req_buf, j.ssid(), j.passphrase()));
                if (net_rep) |r| w.publishNet(r);
                next_scan = sys.nowNs() + 5 * std.time.ns_per_s;
            }
            if (disc) {
                var req_buf: [64]u8 = undefined;
                net_rep = net.ask(net.disconnectRequest(&req_buf, ""));
                if (net_rep) |r| w.publishNet(r);
                next_scan = sys.nowNs() + 5 * std.time.ns_per_s;
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

            if (on_wifi_page and !was_wifi_page) next_scan = 0;
            was_wifi_page = on_wifi_page;

            if (sys_rep == null or sys_rep.?.storage == .unprepared) {
                sys_rep = ask("prepare\n");
                if (sys_rep) |r| w.publishSystem(r);
            }
            if (sys.nowNs() >= next_scan) {
                const need_scan = (on_wifi_page and !wifi_selected) or if (net_rep) |r| r.len == 0 else true;
                if (need_scan) {
                    net_rep = net.ask("wifi scan\n");
                    if (net_rep) |r| w.publishNet(r);
                }
                next_scan = if (on_wifi_page or net_rep == null or net_rep.?.len == 0)
                    sys.nowNs() + 5 * std.time.ns_per_s
                else
                    std.math.maxInt(u64);
            }

            const after = sys.nowNs();
            const timeout_ms: i32 = if (next_scan == std.math.maxInt(u64))
                -1
            else
                @intCast(@min((next_scan -| after) / std.time.ns_per_ms, std.math.maxInt(i32)));
            var pfd = [3]linux.pollfd{
                .{ .fd = w.cmd_fds[0], .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = sys_sub.fd orelse -1, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = net_sub.fd orelse -1, .events = linux.POLL.IN, .revents = 0 },
            };
            _ = linux.poll(&pfd, pfd.len, timeout_ms);
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
