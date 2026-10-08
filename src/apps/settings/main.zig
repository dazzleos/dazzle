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
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
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

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

var frame: vc4.render.Frame = undefined;

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
        print("dazzle-settings: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8, first_page: ?view.Page) !void {
    // The language chosen (in setup, or here).
    var chosen = locale.load();
    locale.current = chosen.language;
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print("dazzle-settings: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
            print("dazzle-settings: cannot read the font {s} ({s}); no text\n", .{ font_path, @errorName(err) });
            break :blk null;
        };
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    // Copying and pasting go through the system's clipboard.
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

    const system = info.System.read();
    print("dazzle-settings: {s}, {d} {s}\n", .{ system.model.slice(), system.cores, if (system.cores == 1) "core" else "cores" });
    var monitor: info.UsageMonitor = .{};
    var usage = monitor.read(sys.nowNs());
    var network = info.Network.read();
    // The USB devices, read while their page shows.
    var devices: usb.Devices = .{};
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
    // What the window asks of the network manager (Connect, Disconnect, an
    // Ethernet address).
    var actions: view.Actions = .{};
    // What the title bar's buttons do, and how small the window may be.
    // The apps that can be installed, and which are.
    var apps: store.Store = .init(gpa, build_info.apps_url);
    var installed: [64]bool = undefined;
    // Updates of the system, and which system this is.
    var updater: update.Updater = .init(gpa, build_info.apps_url, sys.system.Version.init(build_info.commit_time, build_info.commit) orelse .{});
    var video_memory_failed = false;
    var date_buf: [32]u8 = undefined;
    var build_buf: [64]u8 = undefined;
    const build = std.fmt.bufPrint(&build_buf, "{s} ({s})", .{ build_info.commit, update.formatDate(&date_buf, build_info.commit_time) }) catch build_info.commit;
    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);
    // The page to show, once the window is built: the one asked for.
    var pending_page = first_page;
    var sock_buf: [64]u8 = undefined;
    const sock_path = sys.shell.appSocket(&sock_buf, "dazzle-settings").?;
    const pages_fd: ?linux.fd_t = sys.shell.listen(sock_path) catch null;
    defer if (pages_fd) |fd| {
        sys.close(fd);
        _ = linux.unlink(sock_path);
    };
    win.wake_fd = pages_fd;

    var next_update: u64 = sys.nowNs() + std.time.ns_per_s;
    var dirty = true;
    var idle = false;
    var suspended = false;
    while (true) {
        const waited = if (idle) blk: {
            const gpio_page = view.shownPage(window_ui) == .gpio;
            const until = if (suspended) sys.nowNs() + 60 * std.time.ns_per_s else if (window_ui.needs_frame) sys.nowNs() + 16 * std.time.ns_per_ms else if (gpio_page) @min(next_update, next_levels) else next_update;
            break :blk win.wait(@max(until -| sys.nowNs(), std.time.ns_per_ms));
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print("dazzle-settings: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed or controls.quit) return;
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }
        // Covered by another window: nothing is read or drawn, and the
        // window in front gets the GPU memory.
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else next_update = 0;
        }
        const now = sys.nowNs();
        // The keyboard's layout, as the shell says.
        window_ui.keyboard = win.layout;
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| window_ui.keyEvent(k.code, k.pressed),
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
        };

        // The figures change every second.
        if (!suspended and now >= next_update) {
            next_update = now + std.time.ns_per_s;
            usage = monitor.read(now);
            network = info.Network.read();
            if (view.shownPage(window_ui) == .usb) devices = usb.Devices.read();
            if (view.shownPage(window_ui) == .log) _ = syslog.poll();
            if (view.shownPage(window_ui) == .gpio) pins.readUsers();
            dirty = true;
        }
        if (!suspended and view.shownPage(window_ui) == .gpio and now >= next_levels) {
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
        // Installing, or getting the list of apps.
        if (apps.poll()) dirty = true;
        if (actions.install != null or actions.remove != null or actions.refresh_apps) {
            if (actions.install) |*n| apps.install(n.slice());
            if (actions.remove) |*n| apps.uninstall(n.slice());
            if (actions.refresh_apps) apps.refresh(true);
            actions.install = null;
            actions.remove = null;
            actions.refresh_apps = false;
            dirty = true;
        }
        // The list is got when the page is first shown.
        // The log is read as soon as its page shows.
        if (view.shownPage(window_ui) == .log and syslog.fd == null and !syslog.failed) {
            _ = syslog.poll();
            dirty = true;
        }
        if (view.shownPage(window_ui) == .apps and !apps.asked) {
            apps.refresh(false);
            dirty = true;
        }
        // Updates: checked for when the System page is first shown.
        if (!suspended and updater.poll(now)) dirty = true;
        if (actions.check_update or actions.download_update or actions.restart) {
            if (actions.check_update) updater.check(true);
            if (actions.download_update) updater.download();
            if (actions.restart) updater.restart();
            actions.check_update = false;
            actions.download_update = false;
            actions.restart = false;
            dirty = true;
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
            } else print("dazzle-settings: the system did not answer\n", .{});
            dirty = true;
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
            dirty = true;
        }
        if (view.shownPage(window_ui) == .system and !updater.asked) {
            updater.check(false);
            dirty = true;
        }
        if (actions.connect != null or actions.disconnect or actions.ethernet != null) {
            var req_buf: [256]u8 = undefined;
            if (actions.ethernet) |a| report = info.askManager(info.manager.ethernetRequest(&req_buf, a));
            if (actions.connect != null or actions.disconnect) {
                const req = if (actions.connect) |*j| info.manager.connectRequest(&req_buf, j.ssid(), j.passphrase()) else "wifi disconnect\n";
                if (actions.connect) |*j| print("dazzle-settings: joining \"{s}\"\n", .{j.ssid()});
                report = info.askManager(req);
            }
            actions = .{};
            next_ask = sys.nowNs() + std.time.ns_per_s;
            dirty = true;
        }
        // Wi-Fi networks are scanned for only while their page is shown
        // (at once when it is chosen); other pages only ask how things
        // are.
        const wifi_page = view.shownPage(window_ui) == .wifi;
        if (wifi_page and !was_wifi_page) next_ask = 0;
        was_wifi_page = wifi_page;
        if (!suspended and now >= next_ask) {
            // Soon after the first answer (to show what the first scan
            // found) and while joining a network, then every few seconds.
            const busy = if (report) |r| r.scanning or r.connection.state == .connecting or r.connection.state == .authenticating or r.connection.state == .addressing else true;
            next_ask = now + @as(u64, if (busy and wifi_page) 1 else 5) * std.time.ns_per_s;
            report = info.askManager(if (wifi_page) "wifi scan\n" else "status\n");
            dirty = true;
        }

        // Another app asked (through the shell) for a page to be shown.
        if (pages_fd) |fd| {
            var line_buf: [64]u8 = undefined;
            while (sys.shell.accept(fd, &line_buf)) |got| {
                sys.close(got.fd);
                if (std.meta.stringToEnum(view.Page, got.line)) |p| pending_page = p;
            }
        }
        if (pending_page) |p| if (view.showPage(window_ui, p)) {
            pending_page = null;
            dirty = true;
        };

        idle = true;
        if (!suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            const catalogue = apps.apps()[0..@min(apps.apps().len, installed.len)];
            var available_buf: [64]u8 = undefined;
            for (catalogue, installed[0..catalogue.len]) |a, *i| i.* = store.isInstalled(store.apps_dir, a.name);
            window_ui.fullscreen = win.fullscreen;
            window_ui.frame(width, height, now, view.Settings{
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
                },
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
            });
            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame, win.flusher());
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
    }
}

/// Opens a window on the Wayland compositor.
fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    // Dazzle's compositor listens on /os/sockets/wayland-0; elsewhere, where
    // WAYLAND_DISPLAY and XDG_RUNTIME_DIR say.
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-settings: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Settings") catch |err| {
        print("dazzle-settings: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-settings");
    return win;
}

test {
    _ = info;
    _ = view;
    _ = @import("update.zig");
    _ = @import("board.zig");
    _ = usb;
    _ = gpio;
    _ = @import("gpio_view.zig");
    _ = log;
}
