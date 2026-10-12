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
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Setup",
        .app_id = "dazzle-setup",
        .size = view.open_size,
        .font_path = font_path,
    });
    defer a.close();
    a.sync_keyboard = false;

    var name_buf: [32]u8 = undefined;
    const suggestion = names.random(&name_buf);
    // Preparing the card starts now, while the pages are filled in.
    var report: ?proto.Report = ask("prepare\n");
    var net_report: ?net.Report = net.ask("wifi scan\n");
    // The language and keyboard, as they are (until others are picked).
    const start_locale: locale.Settings = if (report) |r| r.locale else .{};
    locale.current = start_locale.language;
    a.ui.keyboard = start_locale.keyboard;
    var next_ask: u64 = sys.nowNs() + 500 * std.time.ns_per_ms;
    var next_net_ask: u64 = sys.nowNs() + std.time.ns_per_s;
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

    while (try a.step(@max(@min(next_ask, next_net_ask) -| sys.nowNs(), std.time.ns_per_ms))) {
        const now = sys.nowNs();
        a.takeInput();

        // A language or keyboard picked: used now, and kept.
        if (actions.locale) |l| {
            actions.locale = null;
            locale.current = l.language;
            a.ui.keyboard = l.keyboard;
            var req_buf: [64]u8 = undefined;
            _ = ask(std.fmt.bufPrint(&req_buf, "locale {s} {s}\n", .{ l.language.code(), l.keyboard.code() }) catch "");
            a.dirty = true;
        }
        // The computer's name, confirmed on its page: set now so the
        // network connects with it before the list of apps is fetched.
        if (actions.hostname) |h| {
            actions.hostname = null;
            var req_buf: [96]u8 = undefined;
            report = ask(std.fmt.bufPrint(&req_buf, "hostname {s}\n", .{h.slice()}) catch "");
            net_report = net.ask("wifi scan\n");
            // If an Ethernet cable is plugged in, give DHCP a moment to get
            // an address before deciding whether to show the Wi-Fi page.
            if (ethernetCarrier(net_report) and !ethernetConnected(net_report)) {
                const deadline = sys.nowNs() + 3 * std.time.ns_per_s;
                while (sys.nowNs() < deadline and !ethernetConnected(net_report)) {
                    sys.sleepMs(100);
                }
            }
            if (!named) {
                named = true;
                wait_network_until = sys.nowNs() + 10 * std.time.ns_per_s;
                retry_at = 0;
            }
            next_net_ask = sys.nowNs() + std.time.ns_per_s;
            a.dirty = true;
        }
        if (actions.connect) |*j| {
            var req_buf: [256]u8 = undefined;
            print("dazzle-setup: joining \"{s}\"\n", .{j.ssid()});
            net_report = net.ask(net.connectRequest(&req_buf, j.ssid(), j.passphrase()));
            actions.connect = null;
            wait_network_until = now + 10 * std.time.ns_per_s;
            retry_at = 0;
            next_net_ask = now + 500 * std.time.ns_per_ms;
            a.dirty = true;
        }
        if (actions.disconnect) {
            actions.disconnect = false;
            var req_buf: [64]u8 = undefined;
            net_report = net.ask(net.disconnectRequest(&req_buf, ""));
            next_net_ask = now + 500 * std.time.ns_per_ms;
            a.dirty = true;
        }
        if (actions.skip_wifi) {
            actions.skip_wifi = false;
            wait_network_until = 0;
            retry_at = 0;
            a.dirty = true;
        }
        // How preparing goes: often while it does.
        if (now >= next_ask) {
            const need_prepare = report == null or report.?.storage == .unprepared;
            report = ask(if (need_prepare) "prepare\n" else "status\n");
            const preparing = if (report) |r| r.storage == .preparing or r.storage == .unprepared else true;
            const waiting = preparing or (named and apps.apps().len == 0 and apps.job == null and now < wait_network_until);
            next_ask = now + @as(u64, if (waiting) 250 else 1000) * std.time.ns_per_ms;
            a.dirty = true;
        }
        const on_wifi_page = if (a.ui.root) |root| view.pages[root.state(view.Setup.State).page] == .wifi else false;
        const wifi_selected = if (a.ui.root) |root| root.state(view.Setup.State).has_selected else false;
        if (now >= next_net_ask) {
            const need_scan = (on_wifi_page and !wifi_selected) or if (net_report) |r| r.len == 0 else true;
            net_report = net.ask(if (need_scan) "wifi scan\n" else "status\n");
            const busy = if (net_report) |r| r.scanning or r.connection.state == .connecting or r.connection.state == .authenticating or r.connection.state == .addressing else false;
            next_net_ask = now + @as(u64, if (busy or on_wifi_page) 1000 else 3000) * std.time.ns_per_ms;
            a.dirty = true;
        }
        const storage_now: proto.StorageState = if (report) |r| r.storage else .none;
        // The list of apps, kept on the card: once the computer is named
        // and the card and network are ready, and again every while until
        // it comes (the network is brought up once the name is confirmed).
        if (apps.poll()) a.dirty = true;
        if (named and storage_now == .ready and apps.job == null and apps.apps().len == 0 and queue == null and now >= retry_at) {
            if (networkReady() or (!on_wifi_page and now >= wait_network_until)) {
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
            if (can and apps_done) {
                var req_buf: [96]u8 = undefined;
                const req = std.fmt.bufPrint(&req_buf, "finish {s}\n", .{h.slice()}) catch "";
                _ = ask(req);
                print("dazzle-setup: finished; the computer is {s}\n", .{h.slice()});
                return;
            }
        }

        try a.draw(sys.nowNs(), view.Setup{
            .suggestion = suggestion,
            .locale = start_locale,
            .report = if (report) |*r| r else null,
            .wifi = if (net_report) |*r| r else null,
            .ethernet_connected = ethernetConnected(net_report),
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

/// Whether any wired Ethernet adapter has a carrier (a cable plugged in).
fn ethernetCarrier(report: ?net.Report) bool {
    const r = report orelse return false;
    for (r.ethernetAdapters()) |*e| {
        const a = e.adapter orelse continue;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/net/{s}/carrier", .{a.name()}) catch continue;
        var buf: [8]u8 = undefined;
        const text = sys.readFile(path.ptr, &buf) orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, text, " \n"), "1")) return true;
    }
    return false;
}

/// Whether any wired Ethernet adapter has an IPv4 address.
fn ethernetConnected(report: ?net.Report) bool {
    const r = report orelse return false;
    const sock: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return false);
    defer sys.close(sock);
    for (r.ethernetAdapters()) |*e| {
        const a = e.adapter orelse continue;
        const name = a.name();
        var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
        const n = @min(name.len, req.ifrn.name.len - 1);
        @memcpy(req.ifrn.name[0..n], name[0..n]);
        if (linux.errno(linux.ioctl(sock, linux.SIOCGIFADDR, @intFromPtr(&req))) != .SUCCESS) continue;
        const in: *const linux.sockaddr.in = @ptrCast(@alignCast(&req.ifru.addr));
        const ip: [4]u8 = @bitCast(in.addr);
        if (!std.mem.allEqual(u8, &ip, 0)) return true;
    }
    return false;
}

/// Whether the network manager has configured name servers (and the clock)
/// in /etc/resolv.conf.
fn networkReady() bool {
    var buf: [64]u8 = undefined;
    const text = sys.readFile("/etc/resolv.conf", &buf) orelse return false;
    return std.mem.trim(u8, text, " \t\n").len > 0;
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
