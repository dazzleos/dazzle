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
const audio = @import("audio");

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
    var select_gpio = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "gpio")) {
            page = .board;
            select_gpio = true;
        } else if (std.meta.stringToEnum(view.Page, arg)) |p| page = p else font_path = arg.ptr;
    }
    run(init, font_path, page, select_gpio) catch |err| {
        print(sys.log_error ++ "dazzle-settings: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8, first_page: ?view.Page, first_gpio: bool) !void {
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
    var sound = audio.loadSettings();
    var audio_devices = audio.listDevices();
    audio.applySettings(sound, &audio_devices);
    var test_player: ?audio.Player = null;
    defer if (test_player) |*p| p.close();
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
    // Updates of the network manager's state arrive over a subscription;
    // a Wi-Fi scan is asked for while the Wi-Fi page shows.
    var report: ?info.manager.Report = null;
    var net_sub: info.manager.Subscription = .{};
    defer net_sub.deinit();
    net_sub.connect();
    var next_scan: u64 = 0;
    var was_wifi_page = false;
    var wifi_adapter: info.Str(16) = .{};
    // What the window asks of the network manager (Connect, Disconnect, an
    // Ethernet address).
    var actions: view.Actions = .{};
    // The apps that can be installed, and which are.
    var server_url_buf: [store.max_url_len]u8 = undefined;
    var server_url: []const u8 = store.loadServerUrl(&server_url_buf, build_info.apps_url);
    var apps: store.Store = .init(gpa, server_url);
    apps.check_os = true;
    var installed: [64]bool = undefined;
    var updatable: [64]bool = undefined;
    // Updates of the system, and which system this is.
    var updater: update.Updater = .init(gpa, server_url, sys.system.Version.init(build_info.commit_time, build_info.commit) orelse .{});
    defer updater.deinit();
    var icons: view.software_view.IconSet = .init(gpa);
    defer icons.deinit();
    var icons_dirty = true;
    var video_memory_failed = false;
    var date_buf: [32]u8 = undefined;
    var build_buf: [64]u8 = undefined;
    const build = std.fmt.bufPrint(&build_buf, "{s} ({s})", .{ build_info.commit, update.formatDate(&date_buf, build_info.commit_time) }) catch build_info.commit;
    // The page to show, once the window is built: the one asked for.
    var pending_page = first_page;
    var pending_gpio = first_gpio;
    var sock_buf: [64]u8 = undefined;
    const sock_path = sys.shell.appSocket(&sock_buf, "dazzle-settings").?;
    const pages_fd: ?linux.fd_t = sys.shell.listen(sock_path) catch null;
    defer if (pages_fd) |fd| {
        sys.close(fd);
        _ = linux.unlink(sock_path);
    };

    var next_update: u64 = sys.nowNs() + std.time.ns_per_s;
    while (true) {
        a.win.wake_fds = .{ pages_fd, net_sub.fd, updater.sub.fd, if (view.shownPage(a.ui) == .log) syslog.fd else null };
        const board_page = view.shownPage(a.ui) == .board;
        const base_until = if (a.suspended) sys.nowNs() + 60 * std.time.ns_per_s else if (board_page) @min(next_update, next_levels) else next_update;
        const until = if (test_player != null) @min(base_until, sys.nowNs() + 16 * std.time.ns_per_ms) else base_until;
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
            if (view.shownPage(a.ui) == .board) {
                devices = usb.Devices.read();
                pins.readUsers();
            }
            if (view.shownPage(a.ui) == .sound) {
                audio_devices = audio.listDevices();
            }
            if (view.shownPage(a.ui) == .log) _ = syslog.poll();
            a.dirty = true;
        }
        if (!a.suspended and view.shownPage(a.ui) == .board and now >= next_levels) {
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
        if (actions.sound) |s| {
            actions.sound = null;
            sound = s;
            audio.saveSettings(sound);
            audio.applySettings(sound, &audio_devices);
            if (test_player) |*p| p.updateSettings(sound);
            a.dirty = true;
        }
        if (actions.test_sound) {
            actions.test_sound = false;
            if (test_player) |*p| p.close();
            test_player = audio.Player.openTestTone(sound);
            a.dirty = true;
        }
        if (test_player) |*p| {
            if (p.step(now) == null) {
                p.close();
                test_player = null;
            }
        }
        // Installing, or getting the list of apps (and os.json, over the
        // same keep-alive connection).
        if (apps.poll()) {
            updater.loadManifest();
            icons_dirty = true;
            a.dirty = true;
        }
        if (actions.software_server) |*srv| {
            const raw = srv.slice();
            if (raw.len == 0) {
                store.saveServerUrl(null);
                server_url = build_info.apps_url;
            } else if (store.parseHttpsUrl(raw)) |valid| {
                store.saveServerUrl(valid);
                @memcpy(server_url_buf[0..valid.len], valid);
                server_url = server_url_buf[0..valid.len];
            }
            apps.setBaseUrl(server_url);
            updater.setBaseUrl(server_url);
            apps.refresh(true);
            actions.software_server = null;
            a.dirty = true;
        }
        if (actions.install != null or actions.remove != null or actions.refresh_apps or actions.check_update) {
            if (actions.install) |*n| apps.install(n.slice());
            if (actions.remove) |*n| {
                apps.uninstall(n.slice());
                icons_dirty = true;
            }
            if (actions.refresh_apps or actions.check_update) {
                updater.message_len = 0;
                apps.refresh(true);
            }
            actions.install = null;
            actions.remove = null;
            actions.refresh_apps = false;
            actions.check_update = false;
            a.dirty = true;
        }
        // The list is got when the page is first shown.
        // The log is read as soon as its page shows, and whenever new lines arrive.
        if (view.shownPage(a.ui) == .log and !syslog.failed) {
            if (syslog.fd == null or syslog.poll()) a.dirty = true;
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
            next_scan = sys.nowNs() + 10 * std.time.ns_per_s;
            a.dirty = true;
        }
        if (net_sub.fd == null and !a.suspended) net_sub.connect();
        if (net_sub.poll()) |r| if (!r.denied) {
            report = r;
            network = info.Network.read();
            a.dirty = true;
        };
        // Wi-Fi networks are scanned for only while their page is shown
        // (at once when it is chosen, and periodically when no network is
        // selected); status updates arrive over `net_sub`.
        const wifi_page = view.shownPage(a.ui) == .wifi;
        if (wifi_page and !was_wifi_page) next_scan = 0;
        was_wifi_page = wifi_page;
        if (!a.suspended and wifi_page and now >= next_scan) {
            next_scan = now + 10 * std.time.ns_per_s;
            if (!view.wifiNetworkSelected(a.ui)) {
                var scan_buf: [64]u8 = undefined;
                if (info.askManager(info.manager.scanRequest(&scan_buf, wifi_adapter.slice()))) |r| {
                    report = r;
                    a.dirty = true;
                }
            }
        }

        // Another app asked (through the shell) for a page to be shown.
        if (pages_fd) |fd| {
            var line_buf: [64]u8 = undefined;
            while (sys.shell.accept(fd, &line_buf)) |got| {
                sys.close(got.fd);
                if (std.mem.eql(u8, got.line, "gpio")) {
                    pending_page = .board;
                    pending_gpio = true;
                } else if (std.meta.stringToEnum(view.Page, got.line)) |p| {
                    pending_page = p;
                }
            }
        }
        if (pending_page) |p| if (view.showPage(a.ui, p)) {
            if (pending_gpio) {
                _ = view.showGpio(a.ui);
                pending_gpio = false;
            }
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
                    .source = server_url,
                    .default_source = build_info.apps_url,
                },
                .video_memory = .{
                    .now = if (updater.report) |r| r.video_memory_now else null,
                    .next = if (updater.report) |r| r.video_memory_next else null,
                    .failed = video_memory_failed,
                },
                .sound = sound,
                .audio_devices = &audio_devices,
                .update = .{
                    .status = updater.status(),
                    .available = if (updater.available()) |m| std.fmt.bufPrint(&available_buf, "{s} ({s})", .{ m.version, update.formatDate(&date_buf, m.time) }) catch m.version else "",
                    .size = if (updater.available()) |m| m.size else 0,
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
    _ = @import("sound_view.zig");
    _ = @import("board_view.zig");
    _ = @import("software_view.zig");
    _ = @import("resources_view.zig");
    _ = @import("language_view.zig");
    _ = @import("log_view.zig");
    _ = @import("update.zig");
    _ = @import("board.zig");
    _ = usb;
    _ = gpio;
    _ = log;
}
