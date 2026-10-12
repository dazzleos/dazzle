//! Dazzle's settings app: what the system is and how it is doing. It
//! shows the build, Linux's version, how long the system has been up and
//! the board; the resources in use (CPU, temperature, memory, the GPU's
//! memory and storage); the network (adapters, addresses and traffic);
//! and the Wi-Fi networks around. Only this app may scan for them, join
//! one, or choose how Ethernet gets its address: it asks init's network
//! manager, which answers no other program (see sys.network). The figures
//! that change are read again every second (see info.zig); the window is built with the
//! `ui` toolkit (see view.zig), and only what changed is drawn again.
//! Apps are installed and removed on the Apps page (see store.zig): the
//! list of them is downloaded when the page is first shown. Updates of the
//! system are checked for when the System page is first shown, and
//! downloaded and installed from there (see update.zig).
//!
//!     dazzle-settings [page] [font.ttf]
//!
//! It starts at `page` if it is given ("gpio": see `view.Page`); while it
//! runs, other apps can show it a page through the shell (see
//! `sys.shell`), which sends it on to /os/sockets/app-dazzle-settings.
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const ui = @import("ui");
const build_info = @import("build_info");
const info = @import("info.zig");
const usb = @import("usb.zig");
const log = @import("log.zig");
const gpio = @import("gpio.zig");
const view = @import("view.zig");
const store = @import("store");
const update = @import("update.zig");

/// How often the GPIO pins' levels are read, while their page shows.
const gpio_poll_ns = 100 * std.time.ns_per_ms;

const print = sys.print;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    var font_path: [*:0]const u8 = sys.fontFile(&font_buf, font.default_font_file);
    var page: ?view.Page = null;
    while (args.next()) |arg| {
        if (std.meta.stringToEnum(view.Page, arg)) |p| page = p else font_path = arg.ptr;
    }
    run(init, font_path, page) catch |err| {
        print(sys.log_error ++ "dazzle-settings: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8, first_page: ?view.Page) !void {
    // The language chosen (in setup, or here).
    var chosen = locale.load();
    locale.current = chosen.language;
    const gpa = std.heap.page_allocator;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Settings",
        .app_id = "dazzle-settings",
        .size = view.open_size,
        .min_size = view.min_size,
        .font_path = font_path,
    });
    defer a.close();

    const system = info.System.read();
    print("dazzle-settings: {s}, {d} {s}\n", .{ system.model.slice(), system.cores, if (system.cores == 1) "core" else "cores" });
    var monitor: info.UsageMonitor = .{};
    var usage = monitor.read(sys.nowNs());
    var network = info.Network.read();
    // The USB devices, read while the board page shows.
    var devices = usb.Devices.read();
    // The GPIO pins, read while their page shows: their levels several
    // times a second (inputs change as they like).
    var pins: gpio.Pins = .{};
    defer pins.deinit();
    var pins_read = false;
    var next_levels: u64 = 0;
    // The system's log, read while its page shows.
    var syslog: log.Log = .{};
    defer syslog.deinit();
    // The network manager is asked less often: each request may start a
    // Wi-Fi scan.
    var report: ?info.manager.Report = null;
    var next_ask: u64 = 0;
    var was_wifi_page = true;
    var wifi_adapter: info.Str(16) = .{};
    // What the window asks of the network manager (Connect, Disconnect, an
    // Ethernet address).
    var actions: view.Actions = .{};
    // The apps that can be installed, and which are.
    var apps: store.Store = .init(gpa, build_info.apps_url);
    apps.check_os = true;
    var installed: [64]bool = undefined;
    var updatable: [64]bool = undefined;
    // Updates of the system, and which system this is.
    var updater: update.Updater = .init(gpa, build_info.apps_url, sys.system.Version.init(build_info.commit_time, build_info.commit) orelse .{});
    var icons: view.software_view.IconSet = .init(gpa);
    defer icons.deinit();
    var icons_dirty = true;
    var video_memory_failed = false;
    var date_buf: [32]u8 = undefined;
    var build_buf: [64]u8 = undefined;
    const build = std.fmt.bufPrint(&build_buf, "{s} ({s})", .{ build_info.commit, update.formatDate(&date_buf, build_info.commit_time) }) catch build_info.commit;
    // The page to show, once the window is built: the one asked for.
    var pending_page = first_page;
    var sock_buf: [64]u8 = undefined;
    const sock_path = sys.shell.appSocket(&sock_buf, "dazzle-settings").?;
    const pages_fd: ?linux.fd_t = sys.shell.listen(sock_path) catch null;
    defer if (pages_fd) |fd| {
        sys.close(fd);
        _ = linux.unlink(sock_path);
    };
    a.win.wake_fd = pages_fd;

    var next_update: u64 = sys.nowNs() + std.time.ns_per_s;
    while (true) {
        const gpio_page = view.shownPage(a.ui) == .gpio;
        const until = if (a.suspended) sys.nowNs() + 60 * std.time.ns_per_s else if (gpio_page) @min(next_update, next_levels) else next_update;
        if (!try a.step(@max(until -| sys.nowNs(), std.time.ns_per_ms))) return;
        // Covered by another window: nothing is read or drawn, and the
        // window in front gets the GPU memory.
        if (a.suspended_changed and !a.suspended) next_update = 0;
        const now = sys.nowNs();
        a.takeInput();

        // The figures change every second.
        if (!a.suspended and now >= next_update) {
            next_update = now + std.time.ns_per_s;
            usage = monitor.read(now);
            network = info.Network.read();
            if (view.shownPage(a.ui) == .board) devices = usb.Devices.read();
            if (view.shownPage(a.ui) == .log) _ = syslog.poll();
            if (view.shownPage(a.ui) == .gpio) pins.readUsers();
            a.dirty = true;
        }
        if (!a.suspended and view.shownPage(a.ui) == .gpio and now >= next_levels) {
            next_levels = now + gpio_poll_ns;
            const before = pins.lines;
            pins.readLevels();
            if (!pins_read) pins.readUsers();
            if (!pins_read or !std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&pins.lines))) a.dirty = true;
            pins_read = true;
        }
        if (actions.gpio) |g| {
            actions.gpio = null;
            pins.set(g.pin, g.mode);
            a.dirty = true;
        }
        // Installing, or getting the list of apps (and os.json, over the
        // same keep-alive connection).
        if (apps.poll()) {
            updater.loadManifest();
            icons_dirty = true;
            a.dirty = true;
        }
        if (actions.install != null or actions.remove != null or actions.refresh_apps or actions.check_update) {
            if (actions.install) |*n| apps.install(n.slice());
            if (actions.remove) |*n| {
                apps.uninstall(n.slice());
                icons_dirty = true;
            }
            if (actions.refresh_apps or actions.check_update) apps.refresh(true);
            actions.install = null;
            actions.remove = null;
            actions.refresh_apps = false;
            actions.check_update = false;
            a.dirty = true;
        }
        // The list is got when the page is first shown.
        // The log is read as soon as its page shows.
        if (view.shownPage(a.ui) == .log and syslog.fd == null and !syslog.failed) {
            _ = syslog.poll();
            a.dirty = true;
        }
        if (view.shownPage(a.ui) == .apps and !apps.asked) {
            apps.refresh(false);
            a.dirty = true;
        }
        // Updates: checked for when the Software page is first shown.
        if (!a.suspended and updater.poll(now)) {
            icons_dirty = true;
            a.dirty = true;
        }
        if (actions.download_update or actions.update_all or actions.restart) {
            if (actions.download_update or actions.update_all) updater.download();
            if (actions.update_all) apps.updateAll();
            if (actions.restart) updater.restart();
            actions.download_update = false;
            actions.update_all = false;
            actions.restart = false;
            a.dirty = true;
        }
        // A language or keyboard picked: the system manager keeps it (and
        // the shell sends the apps the keyboard's layout).
        if (actions.locale) |l| {
            actions.locale = null;
            var req_buf: [64]u8 = undefined;
            const req = std.fmt.bufPrint(&req_buf, "locale {s} {s}\n", .{ l.language.code(), l.keyboard.code() }) catch "";
            if (sys.system.ask(req, 3000)) |r| {
                if (!r.denied) {
                    chosen = l;
                    locale.current = l.language;
                }
            } else print(sys.log_warning ++ "dazzle-settings: the system did not answer\n", .{});
            a.dirty = true;
        }
        // Video memory chosen: the system manager has the next start use
        // it, and says what that now is.
        if (actions.video_memory) |mib| {
            actions.video_memory = null;
            var req_buf: [32]u8 = undefined;
            const req = std.fmt.bufPrint(&req_buf, "video_memory {d}\n", .{mib}) catch "";
            const r = sys.system.ask(req, 3000);
            if (r) |have| if (!have.denied) {
                updater.report = have;
            };
            video_memory_failed = if (r) |have| have.denied or have.video_memory_next != mib else true;
            print("dazzle-settings: video memory {d} MiB from the next start{s}\n", .{ mib, if (video_memory_failed) ": refused" else "" });
            a.dirty = true;
        }
        if (actions.wifi_adapter) |ad| wifi_adapter = ad;
        if (actions.connect != null or actions.hotspot != null or actions.disconnect or actions.ethernet != null or actions.wifi_addressing != null or actions.wifi_adapter != null) {
            var req_buf: [256]u8 = undefined;
            if (actions.ethernet) |eth| report = info.askManager(info.manager.ethernetAdapterRequest(&req_buf, actions.ethernet_adapter.slice(), eth));
            if (actions.wifi_addressing) |addr| report = info.askManager(info.manager.wifiAddressRequest(&req_buf, wifi_adapter.slice(), addr));
            if (actions.hotspot) |*h| {
                print("dazzle-settings: starting access point \"{s}\"\n", .{h.ssid()});
                report = info.askManager(info.manager.hotspotFullRequest(&req_buf, h.adapter.slice(), h.ssid(), h.passphrase(), h.network, h.upstream.slice()));
            } else if (actions.connect != null or actions.disconnect) {
                const req = if (actions.connect) |*j| info.manager.connectAdapterRequest(&req_buf, j.adapter.slice(), j.ssid(), j.passphrase()) else info.manager.disconnectRequest(&req_buf, wifi_adapter.slice());
                if (actions.connect) |*j| print("dazzle-settings: joining \"{s}\"\n", .{j.ssid()});
                report = info.askManager(req);
            } else if (actions.wifi_adapter != null and actions.wifi_addressing == null) {
                report = info.askManager(info.manager.scanRequest(&req_buf, wifi_adapter.slice()));
            }
            actions = .{};
            next_ask = sys.nowNs() + std.time.ns_per_s;
            a.dirty = true;
        }
        // Wi-Fi networks are scanned for only while their page is shown
        // (at once when it is chosen); other pages only ask how things
        // are.
        const wifi_page = view.shownPage(a.ui) == .wifi;
        if (wifi_page and !was_wifi_page) next_ask = 0;
        was_wifi_page = wifi_page;
        if (!a.suspended and now >= next_ask) {
            // Soon after the first answer (to show what the first scan
            // found) and while joining a network, then every few seconds.
            const busy = if (report) |r| r.scanning or r.connection.state == .connecting or r.connection.state == .authenticating or r.connection.state == .addressing else true;
            next_ask = now + @as(u64, if (busy and wifi_page) 1 else 5) * std.time.ns_per_s;
            var scan_buf: [64]u8 = undefined;
            report = info.askManager(if (wifi_page) info.manager.scanRequest(&scan_buf, wifi_adapter.slice()) else "status\n");
            a.dirty = true;
        }

        // Another app asked (through the shell) for a page to be shown.
        if (pages_fd) |fd| {
            var line_buf: [64]u8 = undefined;
            while (sys.shell.accept(fd, &line_buf)) |got| {
                sys.close(got.fd);
                if (std.meta.stringToEnum(view.Page, got.line)) |p| pending_page = p;
            }
        }
        if (pending_page) |p| if (view.showPage(a.ui, p)) {
            pending_page = null;
            a.dirty = true;
        };

        if (!a.suspended and (a.dirty or a.ui.needs_frame)) {
            const catalogue = apps.apps()[0..@min(apps.apps().len, installed.len)];
            var available_buf: [64]u8 = undefined;
            for (catalogue, installed[0..catalogue.len], updatable[0..catalogue.len]) |item, *i, *u| {
                i.* = store.isInstalled(store.apps_dir, item.name);
                u.* = i.* and store.hasNewerVersion(store.apps_dir, item);
            }
            if (icons_dirty) {
                icons_dirty = false;
                icons.reload(
                    store.os_icon_file,
                    store.update_icon_file,
                    updater.available() != null,
                    store.apps_dir,
                    store.icons_dir,
                    catalogue,
                );
            }
            try a.draw(now, view.Settings{
                .commit = build,
                .locale = chosen,
                .system = &system,
                .usage = usage,
                .network = &network,
                .usb = &devices,
                .gpio = if (pins_read) &pins else null,
                .log = if (syslog.fd != null or syslog.failed) &syslog else null,
                .manager = if (report) |*r| r else null,
                .actions = &actions,
                .apps = .{
                    .list = catalogue,
                    .installed = installed[0..catalogue.len],
                    .updatable = updatable[0..catalogue.len],
                    .icons = icons.appIcons(catalogue.len),
                    .busy = apps.busy(),
                    .message = apps.message(),
                    .source = build_info.apps_url,
                },
                .video_memory = .{
                    .now = if (updater.report) |r| r.video_memory_now else null,
                    .next = if (updater.report) |r| r.video_memory_next else null,
                    .failed = video_memory_failed,
                },
                .update = .{
                    .status = updater.status(),
                    .available = if (updater.available()) |m| std.fmt.bufPrint(&available_buf, "{s} ({s})", .{ m.version, update.formatDate(&date_buf, m.time) }) catch m.version else "",
                    .message = updater.message(),
                    .icon = icons.osIcon(),
                },
            });
        } else {
            a.idle = true;
        }
    }
}

test {
    _ = info;
    _ = view;
    _ = @import("wifi_view.zig");
    _ = @import("ethernet_view.zig");
    _ = @import("board_view.zig");
    _ = @import("software_view.zig");
    _ = @import("resources_view.zig");
    _ = @import("gpio_view.zig");
    _ = @import("language_view.zig");
    _ = @import("log_view.zig");
    _ = @import("update.zig");
    _ = @import("board.zig");
    _ = usb;
    _ = gpio;
    _ = log;
}
