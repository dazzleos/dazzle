//! Dazzle's settings app: what the system is and how it is doing. It
//! shows the Wi-Fi networks around (or runs an access point), Ethernet
//! adapters, sound output and volume, colour scheme (Dark or Light), the
//! board and its GPIO header, software and system updates, the resources
//! in use (CPU, temperature, memory, the GPU's memory and storage),
//! language and keyboard, and the system's log. Only this app may scan for
//! Wi-Fi networks, join one, start an access point, or choose how Ethernet
//! gets its address: it asks init's network manager, which answers no
//! other program (see sys.network). The figures that change are read again
//! every second (see info.zig); the window is built with kete
//! (see view.zig), and only what changed is drawn again.
//! Apps are installed and removed, and updates of the system checked for,
//! downloaded and installed, on the Software page (see store.zig and
//! update.zig): the app catalogue and system manifest are downloaded when
//! the page is first shown.
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
const appearance_settings = @import("appearance");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const build_info = @import("build_info");
const info = @import("info.zig");
const usb = @import("usb.zig");
const log = @import("log.zig");
const gpio = @import("gpio.zig");
const view = @import("view.zig");
const store = @import("store");
const update = @import("update.zig");
const failed_start = @import("failed_start.zig");
const audio = @import("audio");

/// How often the GPIO pins' levels are read, while their page shows.
const gpio_poll_ns = 100 * std.time.ns_per_ms;

const print = sys.print;

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    var args = init.minimal.args.iterate();
    _ = args.skip();
    var page: ?view.Page = null;
    var select_gpio = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "gpio")) {
            page = .board;
            select_gpio = true;
        } else if (std.meta.stringToEnum(view.Page, arg)) |p| page = p;
    }
    run(init, page, select_gpio) catch |err| {
        print(sys.log_error ++ "dazzle-settings: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// The window's root: the pages, as last worked out (see `run`).
const Root = struct {
    shown: *const view.Settings,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(r.shown.*);
    }
};

/// The files that wake the loop, kept in step with kete_vc4's.
const Wakes = struct {
    fds: [4]?linux.fd_t = @splat(null),

    fn set(w: *Wakes, host: *kete_vc4.Host, want: [4]?linux.fd_t) void {
        for (w.fds) |had| if (had) |fd| if (std.mem.indexOfScalar(?linux.fd_t, &want, fd) == null) host.wakeOn(fd, false);
        for (want) |wanted| if (wanted) |fd| if (std.mem.indexOfScalar(?linux.fd_t, &w.fds, fd) == null) host.wakeOn(fd, true);
        w.fds = want;
    }
};

/// How keyboard `k`'s language pack is, if it has one.
fn packState(apps: *const store.Store, k: locale.Keyboard) view.LanguagePack {
    const code = k.languagePack() orelse return .none;
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "dazzle-language-{s}", .{code}) catch return .none;
    if (store.isPackInstalled(store.apps_dir, name)) return .installed;
    if (apps.busy()) |b| if (std.mem.eql(u8, b, name)) return .installing;
    return if (apps.languagePack(code) != null) .offered else .not_offered;
}

fn run(init: std.process.Init, first_page: ?view.Page, first_gpio: bool) !void {
    // The language chosen (in setup, or here).
    var chosen = locale.load();
    locale.current = chosen.language;
    const gpa = std.heap.page_allocator;
    var host: kete_vc4.Host = undefined;
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-settings" });
    defer host.deinit();
    var appearance = appearance_settings.loadSettings();

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
    var subscribed_keys = store.loadKeys();
    var apps: store.Store = .init(gpa, server_url);
    // The keyboard's language pack is wanted (its keyboard was picked, or
    // Install pressed): installed once the catalogue has it.
    var want_pack = false;
    var asked_catalogue = false;
    apps.check_os = true;
    var installed: [64]bool = undefined;
    var updatable: [64]bool = undefined;
    // The apps listed: the catalogue's, then those installed that it does
    // not have (which can only be removed).
    var listed: std.ArrayList(store.App) = .empty;
    defer listed.deinit(gpa);
    var not_offered: []store.App = &.{};
    defer store.freeInstalledOnly(gpa, not_offered);
    // Updates of the system, and which system this is.
    var updater: update.Updater = .init(gpa, server_url, sys.system.Version.init(build_info.commit_time, build_info.commit) orelse .{});
    defer updater.deinit();
    var icons: view.software_view.IconSet = .init(gpa);
    defer icons.deinit();
    var screenshots: view.software_view.Screenshots = .init(gpa);
    defer screenshots.deinit();
    var icons_dirty = true;
    var video_memory_failed = false;
    var orientation_failed = false;
    // The desktop's screen, as the shell says (its size, and its
    // display's port, whose orientation the Appearance page shows): asked
    // again each second while that page is shown (the shell turns, or
    // another display is used).
    var screen = sys.shell.screen();
    // The log of the slot that last did not start properly, and which
    // failure it is of.
    var failed_log: ?failed_start.Summary = null;
    var failed_log_for: ?sys.system.FailedStart = null;
    defer if (failed_log) |*l| l.deinit(gpa);
    // Remote control, as Settings last saw (or set) it.
    var remote = sys.remote.load();
    // The password last given for parental controls was wrong.
    var parental_wrong = false;
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

    var shown: view.Settings = .{ .commit = build, .system = &system, .usage = usage, .network = &network };
    const root: Root = .{ .shown = &shown };
    const window = try host.app.openWindow(.{
        .title = locale.text("Settings"),
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .on_close_request = .close,
    });
    var wakes: Wakes = .{};
    // What the window shows changed: it is worked out again.
    var dirty = true;
    var suspended = false;
    var available_buf: [64]u8 = undefined;

    var next_update: u64 = sys.nowNs() + std.time.ns_per_s;
    var last_transfer: [2]store.Transfer = .{ .{}, .{} };
    while (true) {
        wakes.set(&host, .{ pages_fd, net_sub.fd, updater.sub.fd, if (view.shownPage(window.ui) == .log) syslog.fd else null });
        const board_page = view.shownPage(window.ui) == .board;
        // While something downloads: how far it has got, four times a second.
        const downloading = apps.job != null or updater.job != null;
        const base_until = if (window.suspended) sys.nowNs() + 60 * std.time.ns_per_s else if (board_page) @min(next_update, next_levels) else if (downloading) @min(next_update, sys.nowNs() + std.time.ns_per_s / 4) else next_update;
        const until = if (test_player != null) @min(base_until, sys.nowNs() + 16 * std.time.ns_per_ms) else base_until;
        if (!try host.step(@max(until -| sys.nowNs(), std.time.ns_per_ms))) return;
        // Covered by another window: nothing is read or drawn, and the
        // window in front gets the GPU memory.
        if (window.suspended != suspended) {
            suspended = window.suspended;
            if (!suspended) next_update = 0;
        }
        const now = sys.nowNs();
        if (downloading) {
            const got: [2]store.Transfer = .{ apps.transfer(), updater.transfer() };
            if (!std.meta.eql(got, last_transfer)) dirty = true;
            last_transfer = got;
        }

        // The figures change every second.
        if (!window.suspended and now >= next_update) {
            next_update = now + std.time.ns_per_s;
            usage = monitor.read(now);
            if (view.shownPage(window.ui) == .appearance) {
                const got = sys.shell.screen() orelse screen;
                if (!std.meta.eql(got, screen)) dirty = true;
                screen = got;
            }
            network = info.Network.read();
            if (view.shownPage(window.ui) == .board) {
                devices = usb.Devices.read();
                pins.readUsers();
            }
            if (view.shownPage(window.ui) == .sound) {
                audio_devices = audio.listDevices();
            }
            if (view.shownPage(window.ui) == .log) _ = syslog.poll();
            dirty = true;
        }
        if (!window.suspended and view.shownPage(window.ui) == .board and now >= next_levels) {
            next_levels = now + gpio_poll_ns;
            const before = pins.lines;
            pins.readLevels();
            if (!pins_read) pins.readUsers();
            if (!pins_read or !std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&pins.lines))) dirty = true;
            pins_read = true;
        }
        if (actions.gpio) |g| {
            actions.gpio = null;
            pins.set(g.pin, g.mode);
            dirty = true;
        }
        if (actions.sound) |s| {
            actions.sound = null;
            sound = s;
            audio.saveSettings(sound);
            audio.applySettings(sound, &audio_devices);
            if (test_player) |*p| p.updateSettings(sound);
            dirty = true;
        }
        if (actions.test_sound) {
            actions.test_sound = false;
            if (test_player) |*p| p.close();
            test_player = audio.Player.openTestTone(sound);
            dirty = true;
        }
        if (actions.appearance) |ap| {
            actions.appearance = null;
            appearance_settings.saveSettings(ap);
            appearance = ap;
            host.app.setTheme(kete_vc4.themeMode(ap.theme));
            dirty = true;
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
            dirty = true;
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
            dirty = true;
        }
        if (actions.software_key) |*k| {
            // The custom server's key alone (or none).
            var list: store.KeyList = .{};
            if (k.slice().len > 0) _ = list.add(k.slice());
            store.saveKeys(&list);
            subscribed_keys = store.loadKeys();
            actions.software_key = null;
            dirty = true;
        }
        // Not while parental controls stop it (updating an app is still
        // installing it).
        if (updater.report) |r| if (r.parental.on and r.parental.limits.block_software) {
            if (actions.install) |*n| if (!store.isInstalled(store.apps_dir, n.slice())) {
                actions.install = null;
            };
            actions.remove = null;
        };
        if (actions.install != null or actions.remove != null or actions.refresh_apps or actions.check_update) {
            if (actions.install) |*n| apps.install(n.slice());
            if (actions.remove) |*n| {
                apps.uninstall(n.slice());
                icons_dirty = true;
            }
            if (actions.refresh_apps or actions.check_update) {
                // Where software comes from, as it is now (remote control
                // may have set it since).
                const now_url = store.loadServerUrl(&server_url_buf, build_info.apps_url);
                if (!std.mem.eql(u8, now_url, server_url)) {
                    server_url = now_url;
                    apps.setBaseUrl(server_url);
                    updater.setBaseUrl(server_url);
                }
                subscribed_keys = store.loadKeys();
                updater.message_len = 0;
                apps.refresh(true);
            }
            actions.install = null;
            actions.remove = null;
            actions.refresh_apps = false;
            actions.check_update = false;
            dirty = true;
        }
        // The list is got when the page is first shown.
        // The log is read as soon as its page shows, and whenever new lines arrive.
        if (view.shownPage(window.ui) == .log and !syslog.failed) {
            if (syslog.fd == null or syslog.poll()) dirty = true;
        }
        if (view.shownPage(window.ui) == .apps and !apps.asked) {
            apps.refresh(false);
            dirty = true;
        }
        // Updates: checked for when the Software page is first shown.
        if (!window.suspended and updater.poll(now)) {
            icons_dirty = true;
            dirty = true;
        }
        if (actions.download_update or actions.update_all or actions.restart) {
            if (actions.download_update or actions.update_all) updater.download();
            if (actions.update_all) apps.updateAll();
            if (actions.restart) updater.restart();
            actions.download_update = false;
            actions.update_all = false;
            actions.restart = false;
            dirty = true;
        }
        // A language or keyboard picked: the system manager keeps it (and
        // the shell sends the apps the keyboard's layout).
        if (actions.locale) |l| {
            actions.locale = null;
            var req_buf: [64]u8 = undefined;
            const req = std.fmt.bufPrint(&req_buf, "locale {s} {s} {s}\n", .{ l.language.code(), l.keyboard.code(), l.timezone.name() }) catch "";
            if (sys.system.ask(req, 3000)) |r| {
                if (!r.denied) {
                    chosen = l;
                    locale.current = l.language;
                    window.setTitle(locale.text("Settings"));
                    if (l.keyboard.languagePack() != null) want_pack = true;
                }
            } else print(sys.log_warning ++ "dazzle-settings: the system did not answer\n", .{});
            dirty = true;
        }
        // The keyboard's language pack (its full input method), wanted:
        // installed, once the catalogue (downloaded if need be) has it.
        if (want_pack) if (chosen.keyboard.languagePack()) |code| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "dazzle-language-{s}", .{code}) catch "";
            if (store.isPackInstalled(store.apps_dir, name)) {
                want_pack = false;
            } else if (apps.busy() == null) {
                if (apps.languagePack(code)) |pack| {
                    apps.install(pack.name);
                    want_pack = false;
                    dirty = true;
                } else if (!asked_catalogue) {
                    apps.refresh(false);
                    asked_catalogue = true;
                    dirty = true;
                }
            }
        } else {
            want_pack = false;
        };
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
            dirty = true;
        }
        // An OS slot chosen to start next time: the system manager has the
        // firmware start it (tried, if it is not the running one).
        if (actions.boot) |slot| {
            actions.boot = null;
            var req_buf: [16]u8 = undefined;
            const r = sys.system.ask(std.fmt.bufPrint(&req_buf, "boot {c}\n", .{slot}) catch "", 3000);
            if (r) |have| if (!have.denied) {
                updater.report = have;
            };
            const done = if (r) |have| !have.denied and have.next == slot else false;
            print("dazzle-settings: OS slot {c} next time{s}\n", .{ std.ascii.toUpper(slot), if (done) "" else ": refused" });
            dirty = true;
        }
        // The slot that last did not start properly: its log, read once.
        {
            const now_failed = if (updater.report) |r| r.failed_start else null;
            if (!std.meta.eql(now_failed, failed_log_for)) {
                failed_log_for = now_failed;
                if (failed_log) |*l| l.deinit(gpa);
                failed_log = if (now_failed != null) failed_start.load(gpa) else null;
                dirty = true;
            }
        }
        // The orientation chosen, for the desktop's screen's display: the
        // system manager keeps it (the shell turns to it at once), and
        // says what it now is.
        if (actions.orientation) |o| if (screen) |s| {
            actions.orientation = null;
            var req_buf: [48]u8 = undefined;
            const r = sys.system.ask(std.fmt.bufPrint(&req_buf, "orientation {s} {s}\n", .{ @tagName(s.port), @tagName(o) }) catch "", 3000);
            if (r) |have| if (!have.denied) {
                updater.report = have;
            };
            orientation_failed = if (r) |have| have.denied or have.orientations.get(s.port) != o else true;
            print("dazzle-settings: the {s} display {s}{s}\n", .{ @tagName(s.port), @tagName(o), if (orientation_failed) ": refused" else "" });
            dirty = true;
        };
        // Serving the log over HTTP turned on or off: the system manager
        // keeps it, and the log server follows.
        if (actions.log_server) |on| {
            actions.log_server = null;
            const r = sys.system.ask(if (on) "log_server on\n" else "log_server off\n", 3000);
            if (r) |have| if (!have.denied) {
                updater.report = have;
            };
            if (r == null) print(sys.log_warning ++ "dazzle-settings: the system did not answer\n", .{});
            dirty = true;
        }
        // Parental controls turned on or off, or more time given: the
        // system manager keeps them, if the password is right.
        if (actions.parental_on != null or actions.parental_off != null or actions.parental_bonus != null) {
            var hex_buf: [2 * sys.parental.max_password]u8 = undefined;
            var req_buf: [64 + 2 * sys.parental.max_password]u8 = undefined;
            var w: std.Io.Writer = .fixed(&req_buf);
            if (actions.parental_on) |on| {
                const pw = sys.parental.Password.of(on.password.slice()).?;
                w.print("parental_on {s} ", .{pw.hex(&hex_buf)}) catch {};
                on.limits.write(&w) catch {};
                w.writeByte('\n') catch {};
            } else if (actions.parental_off) |off| {
                const pw = sys.parental.Password.of(off.slice()).?;
                w.print("parental_off {s}\n", .{pw.hex(&hex_buf)}) catch {};
            } else if (actions.parental_bonus) |bonus| {
                const pw = sys.parental.Password.of(bonus.password.slice()).?;
                w.print("parental_bonus {s} {d}\n", .{ pw.hex(&hex_buf), bonus.minutes }) catch {};
            }
            actions.parental_on = null;
            actions.parental_off = null;
            actions.parental_bonus = null;
            const r = sys.system.ask(w.buffered(), 5000);
            if (r) |have| if (!have.denied) {
                updater.report = have;
            };
            parental_wrong = if (r) |have| have.password == false else false;
            if (r == null) print(sys.log_warning ++ "dazzle-settings: the system did not answer\n", .{});
            dirty = true;
        }
        // Remote control turned on (with a new code) or off: the shell
        // follows the setting.
        if (actions.remote) |on| {
            actions.remote = null;
            remote = if (on) .fresh() else .{};
            sys.remote.save(remote);
            print("dazzle-settings: remote control {s}\n", .{if (on) "on" else "off"});
            dirty = true;
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
            dirty = true;
        }
        if (net_sub.fd == null and !window.suspended) net_sub.connect();
        if (net_sub.poll()) |r| if (!r.denied) {
            report = r;
            network = info.Network.read();
            dirty = true;
        };
        // Wi-Fi networks are scanned for only while their page is shown
        // (at once when it is chosen, and periodically when no network is
        // selected); status updates arrive over `net_sub`.
        const wifi_page = view.shownPage(window.ui) == .wifi;
        if (wifi_page and !was_wifi_page) next_scan = 0;
        was_wifi_page = wifi_page;
        if (!window.suspended and wifi_page and now >= next_scan) {
            next_scan = now + 10 * std.time.ns_per_s;
            if (!view.wifiNetworkSelected(window.ui)) {
                var scan_buf: [64]u8 = undefined;
                if (info.askManager(info.manager.scanRequest(&scan_buf, wifi_adapter.slice()))) |r| {
                    report = r;
                    dirty = true;
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
        if (pending_page) |p| if (view.showPage(window.ui, p)) {
            if (pending_gpio) {
                _ = view.showGpio(window.ui);
                pending_gpio = false;
            }
            pending_page = null;
            dirty = true;
        };

        if (dirty) {
            dirty = false;
            // The apps, then the language packs: listed as the apps are.
            const offered = apps.entries();
            if (store.installedOnly(gpa, store.apps_dir, offered)) |now_not_offered| {
                if (!sameNames(not_offered, now_not_offered)) icons_dirty = true;
                store.freeInstalledOnly(gpa, not_offered);
                not_offered = now_not_offered;
            } else |_| {}
            listed.clearRetainingCapacity();
            listed.appendSlice(gpa, offered) catch {};
            listed.appendSlice(gpa, not_offered) catch {};
            const catalogue = listed.items[0..@min(listed.items.len, installed.len)];
            for (catalogue, installed[0..catalogue.len], updatable[0..catalogue.len]) |item, *i, *u| {
                i.* = store.isInstalled(store.apps_dir, item.name);
                u.* = i.* and store.hasNewerVersion(store.apps_dir, item);
            }
            if (icons_dirty) {
                icons_dirty = false;
                screenshots.deinit();
                icons.reload(
                    store.os_icon_file,
                    store.update_icon_file,
                    updater.available() != null,
                    store.apps_dir,
                    store.icons_dir,
                    catalogue,
                );
            }
            shown = .{
                .commit = build,
                .locale = chosen,
                .system = &system,
                .usage = usage,
                .network = &network,
                .usb = &devices,
                .gpio = if (pins_read) &pins else null,
                .log = if (syslog.fd != null or syslog.failed) &syslog else null,
                .log_server = if (updater.report) |r| r.log_server else null,
                .remote_code = remote.code,
                .parental = if (updater.report) |r| r.parental else null,
                .parental_wrong = parental_wrong,
                .manager = if (report) |*r| r else null,
                .actions = &actions,
                .language_pack = packState(&apps, chosen.keyboard),
                .apps = .{
                    .list = catalogue,
                    .offered = @min(offered.len, catalogue.len),
                    .installed = installed[0..catalogue.len],
                    .updatable = updatable[0..catalogue.len],
                    .icons = icons.appIcons(catalogue.len),
                    .screenshots = &screenshots,
                    .busy = apps.busy(),
                    .transfer = apps.transfer(),
                    .message = apps.message(),
                    .source = server_url,
                    .default_source = build_info.apps_url,
                    .default_key = build_info.signing_key,
                    .subscribed_keys = subscribed_keys.slice(),
                },
                .slots = if (updater.report) |r| .{
                    .running = r.slot,
                    .next = r.next,
                    .versions = r.versions,
                    .failed = r.failed_start,
                    .log = if (failed_log) |*l| l else null,
                    .busy = r.update == .installing or updater.job != null,
                } else .{},
                .display = .{
                    .orientation = if (updater.report) |r| (if (screen) |s| r.orientations.get(s.port) else null) else null,
                    .failed = orientation_failed,
                    .screen = if (screen) |s| .{ s.width, s.height } else null,
                },
                .video_memory = .{
                    .now = if (updater.report) |r| r.video_memory_now else null,
                    .next = if (updater.report) |r| r.video_memory_next else null,
                    .failed = video_memory_failed,
                },
                .sound = sound,
                .audio_devices = &audio_devices,
                .appearance = appearance,
                .update = .{
                    .status = updater.status(),
                    .available = if (updater.available()) |m| std.fmt.bufPrint(&available_buf, "{s} ({s})", .{ m.version, update.formatDate(&date_buf, m.time) }) catch m.version else "",
                    .size = if (updater.available()) |m| m.size else 0,
                    .message = updater.message(),
                    .transfer = updater.transfer(),
                    .icon = icons.osIcon(),
                },
            };
            host.redraw();
        }
    }
}

/// Whether two lists of apps are the same apps.
fn sameNames(a: []const store.App, b: []const store.App) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.name, y.name)) return false;
    return true;
}

test {
    _ = info;
    _ = view;
    _ = @import("wifi_view.zig");
    _ = @import("ethernet_view.zig");
    _ = @import("sound_view.zig");
    _ = @import("appearance_view.zig");
    _ = @import("board_view.zig");
    _ = @import("software_view.zig");
    _ = @import("resources_view.zig");
    _ = @import("language_view.zig");
    _ = @import("log_view.zig");
    _ = @import("parental_view.zig");
    _ = @import("update.zig");
    _ = @import("failed_start.zig");
    _ = @import("os_slots_view.zig");
    _ = @import("board.zig");
    _ = usb;
    _ = gpio;
    _ = log;
}
