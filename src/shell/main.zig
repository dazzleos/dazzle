//! dazzle-shell: a minimal Wayland compositor and shell.
//!
//! It owns the display (as the DRM master) and draws with the low-level vc4
//! API: a dock along the bottom with an icon for each app in /data/apps (see
//! dock.zig), and the front window, maximized above it. Apps draw their own
//! title bars (with the toolkit's TitleBar), so with no app open the screen
//! shows just the dock. USB mice move a cursor
//! (on the display's cursor plane) and, with USB keyboards, give input to
//! that window. Clicking an app in the dock starts it, or brings its window
//! to the front if it is running: apps run once each.
//!
//! Clients connect on /os/sockets/wayland-0 (or, run elsewhere with XDG_RUNTIME_DIR
//! set, $XDG_RUNTIME_DIR/wayland-0, as other compositors do; its clients
//! are then told so). The shell starts no app
//! itself, other than the programs named on its command line. It is not an
//! app: it lives in /os/shell, with its font and its own apps (Settings, which
//! the dock lists with the others, and Setup). On the first run (init gives
//! it --setup) it starts the setup app with the whole screen and no dock;
//! the dock appears once setup has finished.
//!
//! Apps can ask it to open another app, showing something (see
//! `sys.shell`): the Data Logger opens Settings at its GPIO page.
//!
//! Init starts it as the unprivileged Dazzle user, with stdout and stderr
//! going to the kernel log.
//!
//!     dazzle-shell [client ...]

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const evdev = sys.evdev;
const locale = @import("locale");
const vc4 = @import("vc4");
const font = @import("font");
const wayland = @import("wayland");
const server_mod = @import("server.zig");
const render = @import("render.zig");
const input = @import("input.zig");
const dock_mod = @import("dock.zig");
const background_mod = @import("background.zig");
const updates_mod = @import("updates.zig");
const perf_mod = @import("perf.zig");
const quick_mod = @import("quick.zig");
const notice_mod = @import("notice.zig");
const lock_mod = @import("lock.zig");
const power_mod = @import("power.zig");
const osk_mod = @import("osk.zig");
const companion_mod = @import("companion.zig");
const gesture = @import("gesture.zig");
const kete_panel = @import("kete_panel.zig");
const ime_mod = @import("ime.zig");
const keyboard = @import("keyboard.zig");
const screenshot = @import("screenshot.zig");
const remote_mod = @import("remote.zig");
const audio = @import("audio");
const build_info = @import("build_info");
const store = @import("store");

const print = sys.print;

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    _ = level;
    print("dazzle-shell: " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ") ++ fmt ++ "\n", args);
}

/// The events from a touchscreen beside the monitor (`cm`), its touches
/// made what they do: on its keyboard, its keys pressed (nothing
/// returned); on its touchpad, the pointer's motion, clicks and
/// scrolling. Other events as they are.
fn routeCompanion(cm: *companion_mod.Companion, osk: *osk_mod.Osk, osk_touches: *TouchSet, batch: []const input.Event, out: []input.Event) []const input.Event {
    var n: usize = 0;
    const now = sys.nowNs();
    for (batch) |e| {
        if (e != .touch) {
            if (n < out.len) out[n] = e;
            n += 1;
            continue;
        }
        const t = e.touch;
        const at = cm.place(t.x, t.y);
        const key_at: [2]f32 = .{ @floatCast(at[0]), @floatCast(at[1] - @as(f64, @floatFromInt(cm.pad_height))) };
        if (osk_touches.has(t.id) or (t.kind == .down and !cm.onPad(at))) {
            switch (t.kind) {
                .down => {
                    osk_touches.set(t.id);
                    cm.key_touch_at = key_at;
                    osk.panel.pointerMotion(key_at);
                    osk.panel.pointerButton(key_at, true);
                },
                .motion => {
                    cm.key_touch_at = key_at;
                    osk.panel.pointerMotion(key_at);
                },
                // Let go where it last was (it says no place).
                .up => {
                    _ = osk_touches.unset(t.id);
                    osk.panel.pointerButton(cm.key_touch_at, false);
                },
            }
            cm.dirty = true;
            continue;
        }
        var made: companion_mod.Out = .{};
        switch (t.kind) {
            .down => cm.pad.down(t.id, at[0], at[1], now),
            .motion => cm.pad.motion(t.id, at[0], at[1], &made),
            .up => cm.pad.up(t.id, now, &made),
        }
        for (made.slice()) |m| {
            if (n < out.len) out[n] = m;
            n += 1;
        }
        // Ended, as a mouse's are (the pointer moves at a frame).
        if (made.len > 0) {
            if (n < out.len) out[n] = .frame;
            n += 1;
        }
    }
    return out[0..@min(n, out.len)];
}

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    run(init.minimal, init.io) catch |err| {
        print(sys.log_error ++ "dazzle-shell: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, io: std.Io) !void {
    const launched = sys.nowNs();
    // How long each part of starting takes, said with the first frame.
    var took: StartTimes = .{ .at = launched };
    const gpa = std.heap.page_allocator;
    // Run elsewhere (on Raspberry Pi OS), the socket goes where other
    // compositors' do.
    const runtime_dir = std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR");
    // For keymaps' files, where the kernel cannot make them in memory.
    keyboard.file_dir = runtime_dir orelse "/os/sockets";

    const dev = try vc4.device.open();
    const output = try vc4.drm.waitForOutput(dev.fd);
    // A touchscreen beside the monitor: its keyboard and touchpad (see
    // companion.zig). Each is turned for its own port's orientation.
    const companion_output = vc4.drm.findCompanion(dev.fd, output);
    var renderer = try render.Renderer.init(gpa, dev, output);
    took.step(.display);
    // What the boot screen shows, over the first frames, fading out.
    var boot_fade: BootFade = .start(&renderer);
    print("dazzle-shell: build {s}, display {d}x{d}, {s}\n", .{
        build_info.commit,                                                                                                                                                                                                             renderer.width, renderer.height,
        if (renderer.display.kms) |k| (if (k.overlays[vc4.kms.max_overlays - 1] != null) "atomic mode setting with overlay planes" else "atomic mode setting, too few overlay planes") else "legacy mode setting (no direct scanout)",
    });

    // The fonts the shell's kete UI draws text in: the system's, with the
    // emoji font for what it has not.
    var ui_font_data: ?[]const u8 = null;
    var font_buf: [512]u8 = undefined;
    const font_path = sys.fontFile(&font_buf, font.default_font_file);
    if (sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024)) |data| {
        ui_font_data = data;
    } else |err| print(sys.log_warning ++ "dazzle-shell: cannot read {s}: {s}\n", .{ font_path, @errorName(err) });
    var emoji_buf: [512]u8 = undefined;
    const emoji_path = sys.fontFile(&emoji_buf, font.emoji_font_file);
    const emoji: ?[]const u8 = if (linux.errno(linux.access(emoji_path, linux.F_OK)) == .SUCCESS) emoji_path else null;

    took.step(.fonts);
    // The shell's own apps are beside it; the others are in /data/apps.
    var settings_buf: [512]u8 = undefined;
    const settings_path = try sys.appFile(&settings_buf, "dazzle-settings");
    const builtin_apps = [_][]const u8{settings_path};
    var apps = try dock_mod.findApps(gpa, dock_mod.apps_dir, &builtin_apps);
    // Apps installed or removed (from Settings) come and go from the dock,
    // and the sound and appearance settings kept with them are followed.
    // (The keyboard's layout comes from the system manager's reports.)
    var apps_watch: dock_mod.AppsWatch = .init(dock_mod.apps_dir);
    defer apps_watch.deinit();
    for (apps) |app| print("dazzle-shell: app {s} ({s})\n", .{ app.label, app.path });
    took.step(.apps);
    // The shell's UI is kete's: its panels share the font (and its
    // glyphs) and the renderers; the big ones are drawn on the GPU.
    // Chinese, Japanese, Arabic, and other scripts Fira Sans lacks.
    var cjk_buf: [256]u8 = undefined;
    var arabic_buf: [256]u8 = undefined;
    const kit = try kete_panel.Kit.create(gpa, io, ui_font_data, emoji, &.{ sys.fontFile(&cjk_buf, font.cjk_font_file), sys.fontFile(&arabic_buf, font.arabic_font_file) });
    kit.useGpu(renderer.dev) catch |err| print(sys.log_warning ++ "dazzle-shell: the panels are drawn on the CPU: {s}\n", .{@errorName(err)});
    var dock = try dock_mod.Dock.init(kit, apps, renderer.width, renderer.height);
    // The quick settings, over the status box when it is clicked: the
    // volume, the network, updates and powering off.
    var quick = try quick_mod.Quick.init(kit, dock.scale);
    // It needs drawing again (while shown).
    var quick_dirty = false;
    // The touch dragging its slider.
    var quick_touch: ?i32 = null;
    var audio_devices = audio.listDevices();
    // Notifications, at the top of the screen (a screenshot was saved).
    var notice = try notice_mod.Notice.init(gpa, try kit.panel(), renderer.width, dock.scale);
    // Parental controls (the system manager keeps them): while it says the
    // computer is locked, the lock screen in place of the windows and the
    // dock; before then, warnings as time runs out.
    var lock: lock_mod.Screen = .{ .panel = try kit.panel() };
    // The power menu: the power button, or the dock's, shows it.
    var power: power_mod.Menu = .{ .panel = try kit.panel() };
    // The input method (emoji, pinyin, romaji), for the app with the
    // keyboard: it gets each key first, and its candidates show by the
    // text's cursor.
    var ime: ime_mod.Ime = .{ .panel = try kit.panel() };
    // The on-screen keyboard, for touchscreens (see osk.zig), and the
    // touches on it; the last input was a touch (it shows only then).
    var osk: osk_mod.Osk = .init(try kit.gpuPanel(), renderer.width, renderer.height, dock.scale);
    var osk_touches: TouchSet = .{};
    // With a touchscreen beside the monitor, the keyboard is on it, always,
    // below its touchpad.
    var companion: ?companion_mod.Companion = if (companion_output) |co| blk: {
        var cm: companion_mod.Companion = .{
            .renderer = try render.Renderer.init(gpa, dev, co),
            .panel = try kit.gpuPanel(),
        };
        // The two share the DRM file: neither waits for its events.
        renderer.display.shared = true;
        cm.renderer.display.shared = true;
        osk.setScreen(cm.width(), cm.height(), 1);
        cm.layout(osk.height);
        print("dazzle-shell: the touchscreen ({d}x{d}) is the monitor's keyboard and touchpad\n", .{ cm.width(), cm.height() });
        break :blk cm;
    } else null;
    // The touchscreen's keyboard and touchpad, put aside while the monitor
    // is unplugged (the desktop is on the touchscreen then).
    var parked: ?companion_mod.Companion = null;
    // The kernel's word that a display was plugged in or unplugged, and
    // that the desktop moved (what is sized by the screen, again).
    const hotplug: ?linux.fd_t = openHotplug() catch |err| blk: {
        print(sys.log_warning ++ "dazzle-shell: displays plugged in are not noticed: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    var display_moved = false;
    // The shell's touch gestures (four fingers swiped: the overview).
    var gestures: gesture.Gestures = .{ .distance = @as(f64, @floatFromInt(@min(renderer.width, renderer.height))) * 0.08 };
    // Where the last touch on it was (a touch let go says no place: it
    // lets go there).
    var osk_touch_at: [2]f32 = .{ 0, 0 };
    // Where it went down (a swipe down from there hides the keyboard), and
    // whether it has (the rest of the touch does nothing).
    var osk_touch_from: [2]f32 = .{ 0, 0 };
    var osk_swiped = false;
    var last_touch = false;
    // The text input it was shown for (another one, and it shows again
    // after being hidden).
    var osk_for: ?*server_mod.TextInput = null;
    var candidates_hidden = true;
    var parental: sys.system.Parental = .{};
    var locked = false;
    var warnings: lock_mod.Warnings = .{};
    // Screenshots are saved on threads, which say how it went on this
    // pipe (`screenshot.Report`).
    // Remote control, while it is turned on (in Settings), and the input
    // it sends, handled as the devices' is.
    var remote: remote_mod.Server = .{};
    _ = remote.configure(sys.remote.load());
    var remote_events: [256]input.Event = undefined;
    var remote_len: usize = 0;
    // Remote control's touches on the touchscreen beside the monitor.
    var pad_events: [256]input.Event = undefined;
    var pad_len: usize = 0;
    var shot_pipe: [2]linux.fd_t = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&shot_pipe, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) shot_pipe = .{ -1, -1 };
    var net_sub: sys.network.Subscription = .{};
    defer net_sub.deinit();
    net_sub.connect();
    var sys_sub: sys.system.Subscription = .{};
    defer sys_sub.deinit();
    sys_sub.connect();
    if (net_sub.poll()) |r| {
        dock.network = dock_mod.networkStatusFromReport(r);
        quick.network = .fromReport(&r);
    } else dock.network = dock_mod.readNetworkStatus();
    // The bytes moved so far, to see each second whether data is moving.
    var traffic = dock_mod.readTraffic();
    const initial_sound = audio.loadSettings();
    audio.applySettings(initial_sound, &audio_devices);
    dock.volume = .{ .volume = initial_sound.volume, .muted = initial_sound.muted };
    // Updates of the system and the apps: checked for a minute from now,
    // then daily.
    var updates: updates_mod.Updates = undefined;
    took.step(.dock);
    updates.init(gpa, sys.nowNs());
    took.step(.updates);
    dock.updates = updates.available;
    const appearance = dock_mod.readAppearance();
    dock.theme = appearance.theme;
    dock.show_clock = appearance.clock;
    dock.show_network = appearance.network;
    // The background image, if any: made ready on a thread of its own.
    var background_image: background_mod.Loader = .init(gpa, renderer.width, renderer.height, dock.bandHeight());
    defer background_image.deinit();
    wantBackground(&background_image, &renderer, appearance);
    took.step(.background);
    // The dock floats in a band along the bottom, which windows stay above;
    // on an overlay plane, the band is drawn whole, background and all.
    var band_y: u32 = renderer.height - dock.bandHeight();
    var with_dock: server_mod.Rect = .{ .x = 0, .y = 0, .width = renderer.width, .height = band_y };
    renderer.setPanelBand(.dock, @intCast(band_y));
    var perf = try perf_mod.Overlay.init(kit, renderer.width, renderer.height);
    var perf_monitor: perf_mod.Monitor = .{};
    var perf_shown = false;
    var shortcut_key: ?u32 = null;
    // The last frame was a window's buffer, shown directly.
    var shown_directly = false;
    // Where remote control has moved the pointer to (with what is queued).
    var remote_at: [2]f64 = .{ 0, 0 };
    // Super is down, and nothing else has been pressed with it: let go, it
    // was tapped (which shows the overview, or ends it).
    var super_alone = false;
    var perf_frames: u32 = 0;
    var perf_gpu_ns: u64 = 0;
    // What the frames cost, for remote control's status.
    var frame_times: FrameTimes = .{};
    renderer.setPanelHidden(.perf, true);
    renderer.setPanelHidden(.keyboard, true);
    renderer.setPanelHidden(.quick, true);
    renderer.setPanelHidden(.notice, true);

    // On the first run (--setup), the setup app has the whole screen, and
    // the dock shows once it has finished.
    var args = init.args.iterate();
    _ = args.skip();
    var in_setup = false;
    var setup_args = args;
    while (setup_args.next()) |arg| if (std.mem.eql(u8, arg, "--setup")) {
        in_setup = true;
    };
    var dock_shown = !in_setup;
    if (dock_shown) {
        dock.draw();
        showDock(&renderer, &dock);
    }
    var server = server_mod.Server.init(gpa, renderer.backend(), if (dock_shown) with_dock else .{
        .x = 0,
        .y = 0,
        .width = renderer.width,
        .height = renderer.height,
    });
    server.gpu = if (renderer.dev.is_v3d) .v3d else .vc4;
    // The input method gets keys first.
    server.input_method = .{ .ctx = &ime, .key = struct {
        fn key(ctx: *anyopaque, s: *server_mod.Server, code: u32, pressed: bool) bool {
            const i: *ime_mod.Ime = @ptrCast(@alignCast(ctx));
            return i.key(s, code, pressed);
        }
    }.key };
    // The keyboard, the language (the clock's ways) and the time zone,
    // until the system's report says.
    _ = applyLocale(locale.load(), &server, &lock, &dock, &quick);
    // The screen, for clients that ask (wl_output).
    server.output = .{
        .width = renderer.width,
        .height = renderer.height,
        .refresh_mhz = @intCast(std.time.us_per_s * 1000 / @max(renderer.display.refreshPeriodUs(), 1)),
    };

    var path_buf: [108]u8 = undefined;
    const path = if (runtime_dir) |dir| try std.mem.printSentinel(&path_buf, "{s}/wayland-0", .{dir}, 0) else wayland.client.default_socket;
    const listener = try listen(path);
    print("dazzle-shell: listening on {s}\n", .{path});
    took.step(.rest);

    var setup_pid: ?linux.pid_t = if (in_setup) blk: {
        var setup_buf: [512]u8 = undefined;
        break :blk spawn(try sys.appFile(&setup_buf, "dazzle-setup"), null, runtime_dir);
    } else null;

    // Start the clients named on the command line.
    while (args.next()) |client| if (!std.mem.eql(u8, client, "--setup")) {
        _ = spawn(client, null, runtime_dir);
    };
    // Apps asking for another app to be opened.
    const opener: ?linux.fd_t = if (runtime_dir == null) sys.shell.listen(sys.shell.socket_path) catch |err| blk: {
        print(sys.log_warning ++ "dazzle-shell: cannot listen on {s}: {s}\n", .{ sys.shell.socket_path, @errorName(err) });
        break :blk null;
    } else null;

    // The pointer starts in the middle of the screen.
    var devices: input.Devices = .{};
    devices.watchNodes();
    var pointer: Pointer = .{
        .x = @floatFromInt(renderer.width / 2),
        .y = @floatFromInt(renderer.height / 2),
        .max_x = @floatFromInt(renderer.width - 1),
        .max_y = @floatFromInt(renderer.height - 1),
    };
    server.pointer_x = pointer.x;
    server.pointer_y = pointer.y;
    var cursor_shown = false;
    // Each port's display's orientation (the system manager's report
    // says, once asked; until then, as the boot screen had it), and
    // whether the dock is sized for fingers (a touchscreen is there).
    var orientations = sys.system.Orientation.now();
    var dock_touch = false;

    const start = sys.nowNs();
    // A client buffer the display shows directly is held until a later
    // frame replaces it on the screen.
    var scanout: Scanout = .{};
    // The tick (see below): when it is next due, and when it last ran.
    var next_tick: u64 = start;
    var last_tick: u64 = start;
    // The dock changed, and is waiting to be shown.
    var panels_damaged = true;
    // Print Screen was pressed: the screen is saved once input is handled.
    var screenshot_wanted = false;
    // Touches that went down on the dock (the shell's, not a window's).
    var dock_touches: TouchSet = .{};
    // A touch down in the overview: let go, what it does there.
    var overview_tap: ?struct { id: i32, x: f64, y: f64 } = null;
    // A touch down on the dock's icons: where, where it is along now, and
    // whether it has moved along (sliding the icons) or is a tap.
    var dock_slide: ?struct { id: i32, from: [2]f64, last: f64, moved: bool = false } = null;
    // When a client last had a frame for the screen.
    var client_frame_ns: u64 = 0;
    // /data/apps has appeared, found too late for this time round.
    var apps_pending: dock_mod.AppsWatch.Changes = .{};
    watchChildren();
    while (true) {
        if (child_exited.swap(false, .monotonic) and reapChildren(apps, &setup_pid) and dock_shown) {
            dock.draw();
            showDock(&renderer, &dock);
            panels_damaged = true;
        }
        // Setup has finished (or stopped): the dock comes.
        if (!dock_shown and setup_pid == null) {
            dock_shown = true;
            print("dazzle-shell: setup finished\n", .{});
            // Setup made /data/apps, and may have installed apps there.
            if (apps_watch.retry()) apps_pending.apps = true;
            if (net_sub.fd == null) dock.network = dock_mod.readNetworkStatus();
            dock.volume = dock_mod.readVolumeStatus();
            const chosen = dock_mod.readAppearance();
            dock.theme = chosen.theme;
            dock.show_clock = chosen.clock;
            dock.show_network = chosen.network;
            wantBackground(&background_image, &renderer, chosen);
            dock.draw();
            showDock(&renderer, &dock);
            server.setWorkArea(with_dock);
            panels_damaged = true;
        }

        // Wait for clients, input, the display (a page flip completing), or
        // the next clock tick; or not at all if a frame is due and can be
        // drawn.
        var fds: [10 + 2 * max_clients + input.max_devices]linux.pollfd = undefined;
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = renderer.dev.fd, .events = linux.POLL.IN, .revents = 0 };
        const n_clients = @min(server.clients.items.len, max_clients);
        for (server.clients.items[0..n_clients], 2..) |c, i| fds[i] = .{ .fd = c.conn.fd, .events = linux.POLL.IN, .revents = 0 };
        const n_inputs = devices.pollFds(fds[2 + n_clients ..]);
        const now = sys.nowNs();
        // The windows on their way into or out of the overview: a frame
        // each refresh until they are there.
        _ = server.animateOverview(now);
        _ = server.animateWindows(now);
        slideDock(&dock, &server, &renderer, dock_shown, osk.shown, now);
        slideOsk(&osk, &server, &renderer, now);
        animateNotice(&notice, &renderer, &server, now);
        // The tick: what has to be looked at rather than waited for, only
        // when there is something to look at, and when.
        {
            var due: u64 = now + std.time.ns_per_hour;
            // Every second: the network's traffic (while the dock's arrows
            // show it), the managers and the apps' folder until they are
            // reached, the performance overlay, and the input devices if
            // they cannot be watched.
            const polled = (dock_shown and dock.slide < 1 and dock.show_network and dock.network.connected()) or
                net_sub.fd == null or sys_sub.fd == null or !apps_watch.watching or
                perf_shown or devices.watch == null;
            if (polled) due = @min(due, last_tick + std.time.ns_per_s);
            // The clock, when the minute changes (and a little after).
            const wall_ns = sys.realtimeNs();
            if ((dock_shown and dock.show_clock) or quick.shown) {
                const into: u64 = @intCast(@mod(wall_ns, 60 * std.time.ns_per_s));
                due = @min(due, now + (60 * std.time.ns_per_s - into) + std.time.ns_per_ms);
            }
            // Updates: the daily check, or one running.
            due = @min(due, updates.dueAt(now));
            // Parental controls' next warning.
            const wall: i64 = @intCast(@divFloor(wall_ns, std.time.ns_per_s));
            if (warnings.nextAt(parental, wall)) |at| due = @min(due, now + @as(u64, @intCast(@max(at - wall, 0))) * std.time.ns_per_s);
            next_tick = due;
        }
        var wake = next_tick;
        if (notice.wakeAt(now)) |due| wake = @min(wake, due);
        if (dock.tooltipDue()) |due| wake = @min(wake, due);
        // A key pressed on the on-screen keyboard (what it typed, or Hide):
        // dealt with at once, not when something next wakes the shell.
        if (osk.pending()) wake = now;
        // The touchscreen beside the monitor, to be drawn again once its
        // last frame is shown: soon.
        if (companion) |*cm| if (cm.dirty or osk.needsDraw()) {
            wake = @min(wake, now + 8 * std.time.ns_per_ms);
        };
        // Remote control's input still queued (it goes in a batch at a
        // time): at once.
        if (remote_len > 0 or pad_len > 0) wake = now;
        if (!renderer.flipPending()) {
            if (server.damaged) wake = now;
            if (panels_damaged) wake = @min(wake, client_frame_ns + panel_grace_ns);
        }
        // A flip of the monitor's read with the touchscreen's: at once.
        if (vc4.drm.flipKept(renderer.display.output.crtc_id)) wake = now;
        const timeout: i32 = if (wake > now) @intCast((wake - now) / std.time.ns_per_ms + 1) else 0;
        const opener_index = 2 + n_clients + n_inputs;
        const net_index = opener_index + 1;
        const sys_index = opener_index + 2;
        const watch_index = opener_index + 3;
        const shot_index = opener_index + 4;
        const remote_index = opener_index + 5;
        const input_watch_index = opener_index + 6;
        const hotplug_index = opener_index + 7;
        fds[opener_index] = .{ .fd = opener orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[net_index] = .{ .fd = net_sub.fd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[sys_index] = .{ .fd = sys_sub.fd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[watch_index] = .{ .fd = apps_watch.fd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[shot_index] = .{ .fd = shot_pipe[0], .events = linux.POLL.IN, .revents = 0 };
        fds[remote_index] = .{ .fd = remote.listener orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[input_watch_index] = .{ .fd = devices.watch orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[hotplug_index] = .{ .fd = hotplug orelse -1, .events = linux.POLL.IN, .revents = 0 };
        // The clients' processes, to notice one ending (crashing) while its
        // socket is still open elsewhere.
        const exits = fds[hotplug_index + 1 ..][0..n_clients];
        for (server.clients.items[0..n_clients], exits) |c, *f| f.* = .{ .fd = c.pidfd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        _ = linux.poll(&fds, hotplug_index + 1 + n_clients, timeout);
        frame_times.wakes += 1;
        if (sys.nowNs() >= next_tick) frame_times.ticks += 1;
        // A keyboard or mouse plugged in (or handed to the user).
        if (fds[input_watch_index].revents != 0) devices.nodesChanged();
        // A monitor plugged in or unplugged: the desktop moves to it, or
        // to the touchscreen.
        if (fds[hotplug_index].revents != 0 and drmChanged(hotplug.?)) {
            if (moveDisplays(gpa, dev, kit, &renderer, &companion, &parked, orientations, &osk)) |moved| {
                if (moved) display_moved = true;
            } else |err| print(sys.log_warning ++ "dazzle-shell: cannot move to the display: {s}\n", .{@errorName(err)});
        }
        // Asked to stop (the computer restarting or turning off): the last
        // frame is left for the shutdown screen to fade from.
        if (stop_asked.load(.monotonic)) {
            var windows: [render.max_windows]render.Window = undefined;
            stopShowingLast(&renderer, frameWindows(&server, &windows));
            return;
        }
        // A screenshot was saved (or could not be): the user is told.
        if (fds[shot_index].revents != 0) while (screenshot.Report.read(shot_pipe[0])) |r| {
            notice.theme = dock.theme;
            var body_buf: [300]u8 = undefined;
            if (r.saved) {
                notice.show(.photo_camera, locale.text("Screenshot saved"), std.fmt.bufPrint(&body_buf, "Saved as \u{201c}{s}\u{201d} in your files", .{r.text()}) catch r.text(), sys.nowNs());
            } else notice.show(.warning, locale.text("Screenshot not saved"), r.text(), sys.nowNs());
            server.damaged = true;
        };
        // What changed in /data/apps, or all of it if it has just appeared
        // (/data was made ready: the system manager reports it).
        var apps_changes = apps_pending;
        apps_pending = .{};
        if (fds[opener_index].revents != 0) if (opener) |l| {
            if (openApp(l, apps, &server, &renderer, runtime_dir) and dock_shown) {
                dock.draw();
                showDock(&renderer, &dock);
                panels_damaged = true;
            }
        };
        if (fds[net_index].revents != 0) {
            if (net_sub.poll()) |r| if (!r.denied) {
                quick.network = .fromReport(&r);
                quick_dirty = true;
                const net = dock_mod.networkStatusFromReport(r);
                if (!std.meta.eql(net, dock.network)) {
                    dock.network = net;
                    if (dock_shown) {
                        dock.draw();
                        showDock(&renderer, &dock);
                        panels_damaged = true;
                    }
                }
            };
        }
        // Whether there are updates changed: the dock shows it.
        var updates_changed = false;
        if (fds[sys_index].revents != 0) {
            if (sys_sub.poll()) |r| if (!r.denied) {
                orientations = r.orientations;
                if (applyLocale(r.locale, &server, &lock, &dock, &quick)) panels_damaged = true;
                if (updates.setReport(r)) updates_changed = true;
                if (applyParental(r.parental, &parental, &locked, &lock, &quick, &renderer)) {
                    server.damaged = true;
                    panels_damaged = true;
                    // A game's hold on the pointer ends: it is the lock
                    // screen's.
                    if (locked) server.breakLock();
                }
            };
            if (apps_watch.retry()) apps_changes = .all;
        }
        if (fds[watch_index].revents != 0) {
            const c = apps_watch.take();
            apps_changes = apps_changes.with(c);
        }
        // The on-screen keyboard: what its keys typed, to the app with the
        // keyboard; shown while that has a text field enabled and the last
        // input was a touch (not once hidden, until another text field),
        // with the windows' work area above it.
        {
            for (osk.take()) |typed| switch (typed) {
                .text => if (server.activeTextInput() != null) {
                    server.textInputCommitString(typed.slice());
                    server.textInputDone();
                } else {
                    // No text field takes text (an app used with a mouse,
                    // from the touchscreen beside the monitor): typed as a
                    // keyboard's keys would type it (those of a US
                    // keyboard's that make it).
                    const ms: u32 = @truncate(sys.nowNs() / std.time.ns_per_ms);
                    for (typed.slice()) |c| if (remote_mod.keyFor(c)) |k| {
                        if (k.shift) server.keyboardKey(ms, remote_mod.key_left_shift, true);
                        server.keyboardKey(ms, k.code, true);
                        server.keyboardKey(ms, k.code, false);
                        if (k.shift) server.keyboardKey(ms, remote_mod.key_left_shift, false);
                    };
                },
                .key => |code| {
                    const ms: u32 = @truncate(sys.nowNs() / std.time.ns_per_ms);
                    server.keyboardKey(ms, code, true);
                    server.keyboardKey(ms, code, false);
                },
            };
            const input_now = server.activeTextInput();
            if (input_now != osk_for) {
                osk_for = input_now;
                osk.dismissed = false;
            }
            const want = companion == null and input_now != null and last_touch and !osk.dismissed and !locked and dock_shown and !server.fullscreenTop();
            if (want != osk.shown) {
                // Up from the bottom, over the dock (which slides down out
                // of its way: see `slideDock`), or back down.
                osk.slideTo(want, sys.nowNs());
                if (want) {
                    osk.changed = true;
                    renderer.setPanelHidden(.keyboard, false);
                }
                var wa = with_dock;
                if (want) wa.height = osk.restTop();
                server.setWorkArea(wa);
                panels_damaged = true;
                server.damaged = true;
            }
            if (companion) |*cm| {
                // The touchscreen beside the monitor turned (it follows
                // the orientation): its keyboard and touchpad, again.
                const turn = orientations.get(cm.renderer.port()).turn(cm.renderer.display.width, cm.renderer.display.height);
                if (turn != cm.renderer.turn) {
                    cm.renderer.setTurn(turn) catch |err| print(sys.log_warning ++ "dazzle-shell: cannot turn the touchscreen: {s}\n", .{@errorName(err)});
                    osk.setScreen(cm.width(), cm.height(), 1);
                    cm.layout(osk.height);
                    print("dazzle-shell: the touchscreen {d}x{d}\n", .{ cm.width(), cm.height() });
                }
                // On the touchscreen beside the monitor: drawn when it
                // changes (once the last frame there is shown).
                if ((cm.dirty or osk.needsDraw()) and cm.serviceFlip(sys.nowNs())) {
                    cm.show(osk.draw(sys.nowNs()), sys.nowNs()) catch |err| print(sys.log_warning ++ "dazzle-shell: cannot draw the touchscreen: {s}\n", .{@errorName(err)});
                }
            } else if (osk.visible() and osk.needsDraw()) {
                renderer.setPanelAt(.keyboard, osk.draw(sys.nowNs()), 0, osk.top());
                panels_damaged = true;
            }
        }
        // The screen turned (the orientation chosen in Settings), or a
        // touchscreen came or went (the dock is sized for fingers then):
        // what is sized by them, again.
        {
            const turn = orientations.get(renderer.port()).turn(renderer.display.width, renderer.display.height);
            // (A touchscreen beside the monitor is not the monitor's.)
            const touch = devices.hasTouch() and companion == null;
            if (turn != renderer.turn or touch != dock_touch or display_moved) {
                dock_touch = touch;
                display_moved = false;
                renderer.setTurn(turn) catch |err| print(sys.log_warning ++ "dazzle-shell: cannot turn the cursor: {s}\n", .{@errorName(err)});
                dock.setScreen(renderer.width, renderer.height, touch);
                if (companion == null) osk.setScreen(renderer.width, renderer.height, dock.scale);
                quick.setScale(dock.scale);
                notice.resize(gpa, renderer.width, dock.scale) catch |err| print(sys.log_warning ++ "dazzle-shell: cannot size the notice: {s}\n", .{@errorName(err)});
                perf.setScreen(renderer.width, renderer.height);
                band_y = renderer.height - dock.bandHeight();
                with_dock = .{ .x = 0, .y = 0, .width = renderer.width, .height = band_y };
                renderer.setPanelBand(.dock, @intCast(band_y));
                server.output.width = renderer.width;
                server.output.height = renderer.height;
                server.work_area = if (dock_shown) with_dock else server.screen();
                if (osk.shown) server.work_area.height = osk.restTop();
                server.fitWindows();
                server.setWorkArea(server.work_area);
                pointer.max_x = @floatFromInt(renderer.width - 1);
                pointer.max_y = @floatFromInt(renderer.height - 1);
                pointer.x = std.math.clamp(pointer.x, 0, pointer.max_x);
                pointer.y = std.math.clamp(pointer.y, 0, pointer.max_y);
                server.pointer_x = pointer.x;
                server.pointer_y = pointer.y;
                renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
                // The background, made again at the new size.
                background_image.deinit();
                background_image = .init(gpa, renderer.width, renderer.height, dock.bandHeight());
                renderer.setBackgroundImage(null) catch {};
                wantBackground(&background_image, &renderer, dock_mod.readAppearance());
                if (dock_shown) {
                    dock.draw();
                    showDock(&renderer, &dock);
                }
                server.damaged = true;
                panels_damaged = true;
                print("dazzle-shell: the screen {d}x{d}{s}{s}\n", .{ renderer.width, renderer.height, if (turn.sideways()) ", the display on its side" else if (turn == .half) ", the display upside down" else "", if (touch) ", the dock for fingers" else "" });
            }
        }
        // Settings fetched the catalogue, or installed or removed apps.
        if ((apps_changes.apps or apps_changes.catalogue) and updates.reload()) updates_changed = true;
        if (apps_changes.apps) {
            if (dock_mod.rescan(gpa, apps, dock_mod.apps_dir, &builtin_apps)) |new| {
                // Those installed grow in, those removed shrink out.
                dock.setApps(new, sys.nowNs());
                dock_mod.freeApps(gpa, apps);
                apps = new;
                dock.hover = null;
                print("dazzle-shell: {d} apps\n", .{new.len});
                if (dock_shown) {
                    dock.draw();
                    showDock(&renderer, &dock);
                    panels_damaged = true;
                }
            } else |err| print(sys.log_warning ++ "dazzle-shell: cannot list the apps: {s}\n", .{@errorName(err)});
        }
        // The last frame reached the screen: its frame callbacks fire, and
        // the next one can be drawn.
        if (fds[1].revents != 0 or vc4.drm.flipKept(renderer.display.output.crtc_id)) {
            if (renderer.handleEvents() catch |err| blk: {
                print("dazzle-shell: display events: {s}\n", .{@errorName(err)});
                break :blk null;
            }) |vblank_us| {
                const direct = scanout.queued != null;
                scanout.presented(&server);
                const kind = wayland.protocol.wp_presentation_feedback.kind;
                const flags: u32 = kind.vsync | kind.hw_clock | kind.hw_completion | (if (direct) @as(u32, kind.zero_copy) else 0);
                server.framePresentedNs(vblank_us * std.time.ns_per_us, flags);
            }
        }

        const time_ms: u32 = @truncate((sys.nowNs() - start) / std.time.ns_per_ms);
        // Under a fullscreen window the dock is hidden, and takes no input.
        const dock_visible = dock_shown and !server.fullscreenTop() and !osk.shown;
        // Remote control: each request carried out (its input queued, to
        // be handled with the devices').
        if (fds[remote_index].revents != 0) {
            // Moves start from the pointer, unless some are still queued.
            if (remote_len == 0) remote_at = .{ pointer.x, pointer.y };
            var req: remote_mod.Request = undefined;
            while (remote.accept(&req)) {
                const queue = struct {
                    fn add(q: *[256]input.Event, len: *usize, e: input.Event) void {
                        if (len.* < q.len) {
                            q[len.*] = e;
                            len.* += 1;
                        }
                    }
                }.add;
                const q = &remote_events;
                const qn = &remote_len;
                switch (req.command) {
                    .status => {
                        var out: std.ArrayList(u8) = .empty;
                        defer out.deinit(gpa);
                        remoteStatus(gpa, &out, &server, apps, &renderer, &pointer) catch {};
                        out.print(gpa, "wakes {d} (the tick {d})\nframes:\n  composited {f}\n  shown directly {f}\n", .{ frame_times.wakes, frame_times.ticks, frame_times.composited, frame_times.direct }) catch {};
                        panelStatus(gpa, &out, &renderer, &.{
                            .{ .dock, dock.panel },
                            .{ .tooltip, dock.tip_panel },
                            .{ .quick, quick.panel },
                            .{ .notice, notice.panel },
                            .{ .candidates, ime.panel.? },
                            .{ .perf, perf.panel },
                            .{ .lock, lock.panel },
                            .{ .power, power.panel },
                            .{ .keyboard, osk.panel },
                        }) catch {};
                        req.respond("200 OK", "text/plain; charset=utf-8", out.items);
                    },
                    .screenshot => |shot| {
                        var windows: [render.max_windows]render.Window = undefined;
                        // The touchscreen beside the monitor: its own.
                        const r = if (shot.touchscreen) if (companion) |*cm| &cm.renderer else {
                            req.respond("404 Not Found", "text/plain", "No touchscreen beside a monitor\n");
                            continue;
                        } else &renderer;
                        const shown: []const render.Window = if (locked or shot.touchscreen) &.{} else frameWindows(&server, &windows);
                        if (r.capture(gpa, shown, shot.bands)) |pixels| {
                            defer gpa.free(pixels);
                            if (@import("gfx").png.encode(gpa, pixels, r.width, r.height)) |data| {
                                defer gpa.free(data);
                                req.respond("200 OK", "image/png", data);
                            } else |err| req.respond("500 Internal Server Error", "text/plain", @errorName(err));
                        } else |err| req.respond("500 Internal Server Error", "text/plain", @errorName(err));
                    },
                    .pointer, .click => {
                        const to = switch (req.command) {
                            .pointer => |p| p,
                            .click => |c| [2]f64{ c.x, c.y },
                            else => unreachable,
                        };
                        // From where the pointer will be, after what is
                        // queued.
                        queue(q, qn, .{ .motion = .{ @intFromFloat(@round(to[0] - remote_at[0])), @intFromFloat(@round(to[1] - remote_at[1])) } });
                        queue(q, qn, .frame);
                        remote_at = to;
                        if (req.command == .click) {
                            queue(q, qn, .{ .button = .{ .code = req.command.click.button, .pressed = true } });
                            queue(q, qn, .frame);
                            queue(q, qn, .{ .button = .{ .code = req.command.click.button, .pressed = false } });
                            queue(q, qn, .frame);
                        }
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .move => |d| {
                        queue(q, qn, .{ .motion = .{ @intFromFloat(@round(d[0])), @intFromFloat(@round(d[1])) } });
                        queue(q, qn, .frame);
                        remote_at = .{ remote_at[0] + d[0], remote_at[1] + d[1] };
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .button => |b| {
                        queue(q, qn, .{ .button = .{ .code = b.button, .pressed = b.pressed } });
                        queue(q, qn, .frame);
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .scroll => |dy| {
                        queue(q, qn, .{ .axis = .{ .axis = 0, .value = dy } });
                        queue(q, qn, .frame);
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .swipe => |sw| {
                        // On the touchscreen beside the monitor: its
                        // touches, as it would make them.
                        const cm: ?*companion_mod.Companion = if (sw.touchscreen) if (companion) |*c| c else {
                            req.respond("404 Not Found", "text/plain", "No touchscreen beside a monitor\n");
                            continue;
                        } else null;
                        const sq = if (cm != null) &pad_events else q;
                        const sn = if (cm != null) &pad_len else qn;
                        // Down, along in steps, and up (with no place, as a
                        // touchscreen says it).
                        const steps = 12;
                        for (0..steps + 1) |i| {
                            const f = @as(f64, @floatFromInt(i)) / steps;
                            for (0..sw.fingers) |k| {
                                const off = 60 * @as(f64, @floatFromInt(k));
                                const px = sw.from[0] + off + (sw.to[0] - sw.from[0]) * f;
                                const py = sw.from[1] + (sw.to[1] - sw.from[1]) * f;
                                const at = if (cm) |c| c.unplace(.{ px, py }) else touchAt(&renderer, px, py);
                                queue(sq, sn, .{ .touch = .{ .kind = if (i == 0) .down else .motion, .id = @intCast(1001 + k), .x = at[0], .y = at[1] } });
                            }
                        }
                        for (0..sw.fingers) |k| queue(sq, sn, .{ .touch = .{ .kind = .up, .id = @intCast(1001 + k) } });
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .tap => |tap| {
                        const cm: ?*companion_mod.Companion = if (tap.touchscreen) if (companion) |*c| c else {
                            req.respond("404 Not Found", "text/plain", "No touchscreen beside a monitor\n");
                            continue;
                        } else null;
                        const at = if (cm) |c| c.unplace(tap.at) else touchAt(&renderer, tap.at[0], tap.at[1]);
                        const sq = if (cm != null) &pad_events else q;
                        const sn = if (cm != null) &pad_len else qn;
                        queue(sq, sn, .{ .touch = .{ .kind = .down, .id = 1000, .x = at[0], .y = at[1] } });
                        // Let go with no place, as a touchscreen says it.
                        queue(sq, sn, .{ .touch = .{ .kind = .up, .id = 1000 } });
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .key => |k| {
                        if (k.pressed orelse true) queue(q, qn, .{ .key = .{ .code = k.code, .pressed = true } });
                        if (!(k.pressed orelse false)) queue(q, qn, .{ .key = .{ .code = k.code, .pressed = false } });
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .type => |text| {
                        // All of it or none: with no room for it all (other
                        // requests' input still queued), the caller tries
                        // again (part of it, a Shift might stay down).
                        var need: usize = 0;
                        for (text) |c| if (remote_mod.keyFor(c)) |k| {
                            need += if (k.shift) 4 else 2;
                        };
                        if (qn.* + need > q.len) {
                            req.respond("503 Service Unavailable", "text/plain", "Busy: try again\n");
                            continue;
                        }
                        for (text) |c| if (remote_mod.keyFor(c)) |k| {
                            if (k.shift) queue(q, qn, .{ .key = .{ .code = remote_mod.key_left_shift, .pressed = true } });
                            queue(q, qn, .{ .key = .{ .code = k.code, .pressed = true } });
                            queue(q, qn, .{ .key = .{ .code = k.code, .pressed = false } });
                            if (k.shift) queue(q, qn, .{ .key = .{ .code = remote_mod.key_left_shift, .pressed = false } });
                        };
                        req.respond("200 OK", "text/plain", "ok\n");
                    },
                    .notify => |note| {
                        if (notice_mod.iconNamed(note.icon)) |icon| {
                            notice.show(icon, note.title, note.body, sys.nowNs());
                            req.respond("200 OK", "text/plain", "ok\n");
                        } else req.respond("400 Bad Request", "text/plain", "No such icon\n");
                    },
                    .launch => |name| {
                        const found = for (apps) |*a| {
                            if (std.mem.eql(u8, a.name, name)) break a;
                        } else null;
                        if (found) |a| {
                            activateApp(a, &server, &dock, &renderer, runtime_dir, &panels_damaged);
                            req.respond("200 OK", "text/plain", "ok\n");
                        } else req.respond("404 Not Found", "text/plain", "No such app\n");
                    },
                    .quit => |want| {
                        const found = for (apps) |*a| {
                            if (std.mem.eql(u8, a.name, want.app)) break a;
                        } else null;
                        const pid = if (found) |a| a.pid else null;
                        if (pid == null) {
                            req.respond("404 Not Found", "text/plain", "Not running\n");
                        } else if (want.force) {
                            _ = linux.kill(pid.?, .KILL);
                            req.respond("200 OK", "text/plain", "ok\n");
                        } else {
                            // Each of its windows asked to close, as its
                            // close button does.
                            for (server.toplevels.items) |t| if (t.xdg.surface) |surf| if (surf.client.pid == pid.?) server.closeToplevel(t);
                            req.respond("200 OK", "text/plain", "ok\n");
                        }
                    },
                    .window => |w| if (server.findWindow(w.app)) |t| {
                        server.act(t, std.meta.stringToEnum(server_mod.Server.WindowAction, @tagName(w.action)).?);
                        req.respond("200 OK", "text/plain", "ok\n");
                    } else req.respond("404 Not Found", "text/plain", "No such window\n"),
                    .place => |pl| if (server.findWindow(pl.app)) |t| {
                        server.place(t, pl.x, pl.y, pl.width, pl.height);
                        req.respond("200 OK", "text/plain", "ok\n");
                    } else req.respond("404 Not Found", "text/plain", "No such window\n"),
                    .updates => {
                        var out_buf: [512]u8 = undefined;
                        var w: std.Io.Writer = .fixed(&out_buf);
                        updates.describe(&w) catch {};
                        req.respond("200 OK", "text/plain; charset=utf-8", w.buffered());
                    },
                    .check => {
                        updates.checkNow();
                        req.respond("200 OK", "text/plain", "checking\n");
                    },
                    .install => |name| {
                        updates.installApp(name);
                        req.respond("200 OK", "text/plain", "checking, then installing it\n");
                    },
                    .update => {
                        updates.installAll();
                        req.respond("200 OK", "text/plain", "checking, then installing what is newer\n");
                    },
                    .source => |set| {
                        if (set) |s| {
                            const official = std.mem.eql(u8, s.url, "official");
                            store.setSource(if (official) null else s.url, if (official) "" else s.key) catch |err| {
                                req.respond("400 Bad Request", "text/plain", switch (err) {
                                    error.NotAnHttpsUrl => "Give an https:// URL (or \"official\")\n",
                                    error.NotAKey => "Give a 64-character hex Ed25519 public key\n",
                                });
                                continue;
                            };
                            updates.checkNow();
                        }
                        var url_buf: [store.max_url_len]u8 = undefined;
                        const url = store.loadServerUrl(&url_buf, build_info.apps_url);
                        const keys = store.loadKeys();
                        var out_buf: [512]u8 = undefined;
                        const custom = !std.mem.eql(u8, url, build_info.apps_url);
                        const text = std.fmt.bufPrint(&out_buf, "source {s}\nurl {s}\nkey {s}\n", .{
                            if (custom) "custom" else "official",
                            url,
                            if (custom) (if (keys.len > 0) &keys.slice()[0] else "none") else build_info.signing_key,
                        }) catch "";
                        req.respond("200 OK", "text/plain; charset=utf-8", text);
                    },
                    .restart => if (sys.system.ask("restart\n", 3000)) |r| {
                        req.respond(if (r.denied) "403 Forbidden" else "200 OK", "text/plain", if (r.denied) "Not allowed\n" else "restarting\n");
                    } else req.respond("503 Service Unavailable", "text/plain", "The system did not answer\n"),
                    .setup => if (sys.system.ask("setup_again\n", 3000)) |r| {
                        req.respond(if (r.denied) "403 Forbidden" else "200 OK", "text/plain", if (r.denied) "Not allowed\n" else "restarting into setup\n");
                    } else req.respond("503 Service Unavailable", "text/plain", "The system did not answer\n"),
                }
            }
        }
        // The devices' events, then remote control's.
        for (0..n_inputs + 2) |source| {
            var events: [64]input.Event = undefined;
            const batch: []const input.Event = if (source < n_inputs) blk: {
                const f = fds[2 + n_clients + source];
                break :blk if (f.revents != 0) devices.read(f.fd, &events) else &.{};
            } else if (source == n_inputs) takeQueued(&remote_events, &remote_len, &events) else takeQueued(&pad_events, &pad_len, &events);
            if (batch.len == 0) continue;
            // A touchscreen beside the monitor: its touches are its
            // keyboard's, or its touchpad's (the pointer's motion, clicks
            // and scrolling, as a mouse's).
            var routed: [256]input.Event = undefined;
            const events_now = if (companion) |*cm| if (source != n_inputs) routeCompanion(cm, &osk, &osk_touches, batch, &routed) else batch else batch;
            for (events_now) |e| {
                // The on-screen keyboard shows after a touch, not after a
                // key typed or a button pressed (a keyboard, a mouse).
                switch (e) {
                    .touch => |t| if (t.kind == .down) {
                        last_touch = true;
                    },
                    .key => |k| if (k.pressed) {
                        last_touch = false;
                    },
                    .button => |b| if (b.pressed and !(osk.shown and osk.local(pointer.x, pointer.y) != null)) {
                        last_touch = false;
                    },
                    else => {},
                }
                // The power button: the power menu; pressed again while it
                // shows, the computer powers off (as Raspberry Pi's desktop
                // does). Never the windows'.
                if (e == .key and e.key.code == evdev.key_power) {
                    if (e.key.pressed) {
                        if (power.shown) {
                            powerChoice(.power_off, &power);
                        } else {
                            quick.close();
                            power.open();
                            print("dazzle-shell: the power button: the power menu\n", .{});
                        }
                        drawPower(&power, &renderer);
                        server.damaged = true;
                        panels_damaged = true;
                    }
                    continue;
                }
                // The power menu showing: the keys and the pointer (and
                // touches) are its; Escape closes it.
                if (power.shown) {
                    power.panel.setKeyboard(server.keyboard_layout);
                    switch (e) {
                        .key => |k| if (k.code == evdev.key_esc) {
                            if (k.pressed) power.close();
                        } else power.panel.key(k.code, k.pressed),
                        .motion => |d| {
                            pointer.x = std.math.clamp(pointer.x + @as(f64, @floatFromInt(d[0])), 0, pointer.max_x);
                            pointer.y = std.math.clamp(pointer.y + @as(f64, @floatFromInt(d[1])), 0, pointer.max_y);
                            pointer.moved = true;
                            power.panel.pointerMotion(power_mod.Menu.local(pointer.x, pointer.y, renderer.width, renderer.height));
                        },
                        .button => |b| if (b.code == evdev.btn_left) {
                            power.panel.pointerButton(power_mod.Menu.local(pointer.x, pointer.y, renderer.width, renderer.height), b.pressed);
                        },
                        .touch => |t| if (t.kind != .motion) {
                            const on = renderer.turn.toScreen(t.x, t.y);
                            const at = power_mod.Menu.local(on[0] * @as(f64, @floatFromInt(renderer.width - 1)), on[1] * @as(f64, @floatFromInt(renderer.height - 1)), renderer.width, renderer.height);
                            power.panel.pointerMotion(at);
                            power.panel.pointerButton(at, t.kind == .down);
                        },
                        else => {},
                    }
                    // What a press picked takes effect at the next frame.
                    _ = power.draw(sys.nowNs());
                    if (power.take()) |c| powerChoice(c, &power);
                    if (power.shown) drawPower(&power, &renderer);
                    server.damaged = true;
                    panels_damaged = true;
                    continue;
                }
                // Locked: the keys type the password, and the pointer moves
                // over the lock screen and clicks in it; nothing goes to
                // the windows.
                if (locked) {
                    lock.panel.setKeyboard(server.keyboard_layout);
                    const changed = switch (e) {
                        .key => |k| lockKey(&lock, k.code, k.pressed, &parental, &locked, &quick, &renderer),
                        .motion => |d| blk: {
                            pointer.x = std.math.clamp(pointer.x + @as(f64, @floatFromInt(d[0])), 0, pointer.max_x);
                            pointer.y = std.math.clamp(pointer.y + @as(f64, @floatFromInt(d[1])), 0, pointer.max_y);
                            pointer.moved = true;
                            lock.panel.pointerMotion(lockLocal(pointer.x, pointer.y, &renderer));
                            break :blk lockRedraw(&lock, parental, &renderer);
                        },
                        .button => |b| if (b.code == evdev.btn_left) blk: {
                            lock.panel.pointerButton(lockLocal(pointer.x, pointer.y, &renderer), b.pressed);
                            break :blk lockAfterInput(&lock, &parental, &locked, &quick, &renderer);
                        } else false,
                        else => false,
                    };
                    if (changed) {
                        server.damaged = true;
                        panels_damaged = true;
                    }
                    continue;
                }
                // Print Screen is the shell's: it saves the screen.
                if (e == .key and e.key.code == evdev.key_sysrq) {
                    if (e.key.pressed) screenshot_wanted = true;
                    continue;
                }
                // Super+I toggles the performance overlay; Super+S opens
                // Settings, and Super+1..9,0 open the app at that dock
                // position.
                var super_tapped = false;
                if (e == .key) {
                    if (e.key.code == evdev.key_leftmeta or e.key.code == evdev.key_rightmeta) {
                        if (e.key.pressed) {
                            super_alone = true;
                        } else if (super_alone) {
                            super_alone = false;
                            super_tapped = true;
                        }
                    } else if (e.key.pressed) super_alone = false;
                }
                if (e == .button and e.button.pressed) super_alone = false;
                if (e == .key) {
                    if (!e.key.pressed and shortcut_key == e.key.code) {
                        shortcut_key = null;
                        continue;
                    }
                    // Escape closes the quick settings.
                    if (e.key.pressed and e.key.code == evdev.key_esc and quick.shown) {
                        shortcut_key = e.key.code;
                        quick.close();
                        panels_damaged = true;
                        continue;
                    }
                    if (e.key.pressed and (server.modifiers.depressed() & keyboard.mod4) != 0) {
                        if (e.key.code == evdev.key_i) {
                            shortcut_key = e.key.code;
                            perf_shown = !perf_shown;
                            renderer.setPanelHidden(.perf, !perf_shown);
                            if (perf_shown) {
                                const now_ns = sys.nowNs();
                                perf_monitor.reset(now_ns);
                                perf_frames = 0;
                                perf_gpu_ns = 0;
                                var pids: [max_clients]linux.pid_t = undefined;
                                perf.draw(perf_monitor.sample(now_ns, 0, 0, clientPids(&server, &pids)), dock.theme);
                                renderer.setPanelAt(.perf, perf.picture(), perf.x, perf.y);
                            }
                            panels_damaged = true;
                            continue;
                        }
                        if (dock_shown) if (dock_mod.shortcutApp(apps, e.key.code)) |i| {
                            shortcut_key = e.key.code;
                            server.setOverview(false);
                            activateApp(&apps[i], &server, &dock, &renderer, runtime_dir, &panels_damaged);
                            continue;
                        };
                    }
                }
                // Touches go to the window they go down on, but those on
                // the dock are the shell's (a tap there is a click).
                var dock_tap: ?[2]f64 = null;
                if (e == .touch) {
                    const t = e.touch;
                    // On a panel turned (on its side, or upside down):
                    // where on the screen its touch is.
                    const on_screen = renderer.turn.toScreen(t.x, t.y);
                    const x = on_screen[0] * @as(f64, @floatFromInt(renderer.width - 1));
                    const y = on_screen[1] * @as(f64, @floatFromInt(renderer.height - 1));
                    // Four fingers down: the shell's (the apps' touches
                    // cancelled); swiped, the overview, as Super.
                    const g = switch (t.kind) {
                        .down => gestures.down(t.id, x, y),
                        .motion => gestures.motion(t.id, x, y),
                        .up => gestures.up(t.id),
                    };
                    switch (g) {
                        .none => {},
                        .began => {
                            server.cancelTouches();
                            // A key held on the on-screen keyboard is not
                            // typed; nothing on the dock or quick settings
                            // goes on.
                            if (osk_touches.any()) {
                                osk.panel.pointerMotion(.{ -1000, -1000 });
                                osk.panel.pointerButton(.{ -1000, -1000 }, false);
                            }
                            osk_touches = .{};
                            dock_touches = .{};
                            quick_touch = null;
                            overview_tap = null;
                            dock_slide = null;
                            print("dazzle-shell: four fingers down\n", .{});
                            continue;
                        },
                        .swipe => {
                            server.setOverview(!server.overview);
                            continue;
                        },
                        .taken => {
                            // Let go of where it went (the server's touch,
                            // its client told already).
                            if (t.kind == .up) server.touchUp(time_ms, t.id);
                            continue;
                        },
                    }
                    // On the on-screen keyboard: its keys, pressed and let go.
                    if (t.kind == .down) if (osk.local(x, y)) |at| {
                        osk_touches.set(t.id);
                        osk_touch_at = at;
                        osk_touch_from = at;
                        osk_swiped = false;
                        osk.panel.pointerMotion(at);
                        osk.panel.pointerButton(at, true);
                        continue;
                    };
                    if (osk_touches.has(t.id)) {
                        const at: [2]f32 = .{ @floatCast(x), @floatCast(y - @as(f64, @floatFromInt(osk.top()))) };
                        switch (t.kind) {
                            .motion => if (!osk_swiped) {
                                osk_touch_at = at;
                                if (osk.swipedDown(osk_touch_from, at)) {
                                    // Swiped down: it hides, and the key
                                    // it went down on is let go of away
                                    // from it (not typed).
                                    osk_swiped = true;
                                    osk.panel.pointerMotion(.{ -1000, -1000 });
                                    osk.panel.pointerButton(.{ -1000, -1000 }, false);
                                    osk.dismissed = true;
                                } else osk.panel.pointerMotion(at);
                            },
                            .up => {
                                _ = osk_touches.unset(t.id);
                                if (!osk_swiped) osk.panel.pointerButton(osk_touch_at, false);
                            },
                            .down => {},
                        }
                        continue;
                    }
                    const on_dock = dock_visible and dock.local(x, y) != null;
                    switch (t.kind) {
                        .down => if (quick.local(x, y)) |at| {
                            // On the quick settings: pressed there, and
                            // the slider dragged along.
                            dock_touches.set(t.id);
                            const action = quick.press(at[0], at[1]);
                            if (quick.dragging) quick_touch = t.id;
                            quickAction(action, &quick, &dock, &renderer, apps, &server, runtime_dir, &audio_devices, &quick_dirty, &power);
                        } else if (quick.shown and !(on_dock and dock.hitStatus((dock.local(x, y) orelse continue)[0], dock.local(x, y).?[1]))) {
                            // Elsewhere, it closes (the status box toggles
                            // it, below), and that is all the touch does.
                            dock_touches.set(t.id);
                            quick.close();
                            panels_damaged = true;
                        } else if (on_dock) {
                            dock_touches.set(t.id);
                            // The status box: at once. An icon: let go
                            // where it went down, a tap; moved along the
                            // dock first, it slides the icons.
                            const at = dock.local(x, y).?;
                            if (dock.hitStatus(at[0], at[1])) dock_tap = .{ x, y } else dock_slide = .{ .id = t.id, .from = .{ x, y }, .last = x };
                        } else if (server.overview) {
                            // The shell's: let go, it picks a window, or
                            // ends the overview (not if it turns out to be
                            // part of a gesture).
                            dock_touches.set(t.id);
                            overview_tap = .{ .id = t.id, .x = x, .y = y };
                        } else server.touchDown(time_ms, t.id, x, y),
                        .motion => if (quick_touch == t.id) {
                            if (quick.drag(x - @as(f64, @floatFromInt(quick.x)))) |v| setVolume(v, false, &quick, &dock, &renderer, &audio_devices, &quick_dirty);
                        } else if (dock_slide != null and dock_slide.?.id == t.id) {
                            const sl = &dock_slide.?;
                            if (!sl.moved and @abs(x - sl.from[0]) > 10 * dock.scale) sl.moved = true;
                            if (sl.moved) {
                                if (dock.slideIcons(@floatCast(x - sl.last))) {
                                    dock.draw();
                                    showDock(&renderer, &dock);
                                    panels_damaged = true;
                                }
                                sl.last = x;
                            }
                        } else if (!dock_touches.has(t.id)) server.touchMotion(time_ms, t.id, x, y),
                        .up => {
                            if (quick_touch == t.id) {
                                quick_touch = null;
                                if (quick.release()) setVolume(quick.volume, true, &quick, &dock, &renderer, &audio_devices, &quick_dirty);
                            }
                            if (dock_slide) |sl| if (sl.id == t.id) {
                                dock_slide = null;
                                // Not slid: a tap on the icon it went
                                // down on.
                                if (!sl.moved) dock_tap = sl.from;
                            };
                            if (overview_tap) |tap| if (tap.id == t.id) {
                                overview_tap = null;
                                if (server.overview) if (server.overviewAt(tap.x, tap.y)) |win| server.overviewPick(win) else server.setOverview(false);
                            };
                            if (!dock_touches.unset(t.id)) server.touchUp(time_ms, t.id);
                        },
                    }
                    if (dock_tap == null) continue;
                }
                if (e == .button) pointer.flushMotion(&server, time_ms);
                // Clicked on the on-screen keyboard: its keys.
                if (e == .button and e.button.code == evdev.btn_left) if (osk.local(pointer.x, pointer.y)) |at| {
                    osk.panel.pointerMotion(at);
                    osk.panel.pointerButton(at, e.button.pressed);
                    continue;
                };
                // While the quick settings are shown, the left button is
                // theirs: pressed on them, it does what is there; pressed
                // elsewhere (but the status box, which toggles them), it
                // closes them and does nothing more. Let go, the slider is.
                if (dock_tap == null and quick.shown and e == .button and e.button.code == evdev.btn_left) {
                    if (!e.button.pressed) {
                        if (quick.release()) {
                            setVolume(quick.volume, true, &quick, &dock, &renderer, &audio_devices, &quick_dirty);
                            continue;
                        }
                    } else if (quick.local(pointer.x, pointer.y)) |at| {
                        quickAction(quick.press(at[0], at[1]), &quick, &dock, &renderer, apps, &server, runtime_dir, &audio_devices, &quick_dirty, &power);
                        continue;
                    } else {
                        const on_status = if (dock_visible) if (dock.local(pointer.x, pointer.y)) |at| dock.hitStatus(at[0], at[1]) else false else false;
                        if (!on_status) {
                            quick.close();
                            panels_damaged = true;
                            continue;
                        }
                    }
                }
                // Buttons pressed over the dock (when not dragging) are the shell's.
                if (dock_tap != null or (dock_visible and e == .button and e.button.pressed and server.grab == null and server.drag == null and server.buttons_down == 0 and dock.local(pointer.x, pointer.y) != null)) {
                    if (dock_tap == null and e.button.code != evdev.btn_left) continue;
                    const on = dock_tap orelse [2]f64{ pointer.x, pointer.y };
                    const at = dock.local(on[0], on[1]) orelse continue;
                    // Pressed, an icon's tooltip goes.
                    if (dock.tooltip_shown != null) panels_damaged = true;
                    dock.dismissTooltip();
                    server.setOverview(false);
                    // The status box: the quick settings open, or close.
                    if (dock.hitStatus(at[0], at[1])) {
                        if (quick.shown) {
                            quick.close();
                        } else {
                            // Sound cards plugged in since are set too.
                            audio_devices = audio.listDevices();
                            quick.shown = true;
                            quick_dirty = true;
                        }
                        panels_damaged = true;
                        continue;
                    }
                    const i = dock.hit(at[0], at[1]) orelse continue;
                    // A turned icon (they do not all fit) comes round to
                    // the front first.
                    if (dock.faceFront(i, sys.nowNs())) {
                        panels_damaged = true;
                        continue;
                    }
                    activateApp(&apps[i], &server, &dock, &renderer, runtime_dir, &panels_damaged);
                    continue;
                }
                // In the overview, the buttons are the shell's: the left
                // one picks a window, or (elsewhere) ends it.
                if (server.overview and e == .button) {
                    if (e.button.pressed and e.button.code == evdev.btn_left) {
                        if (server.overviewAt(pointer.x, pointer.y)) |win| server.overviewPick(win) else server.setOverview(false);
                    }
                    continue;
                }
                pointer.handle(&server, time_ms, e);
                if (e == .frame) server.touchFrame();
                if (super_tapped) server.setOverview(!server.overview);
            }
            if (pointer.moved) {
                pointer.moved = false;
                renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
            }
            // The slider follows the pointer while it is dragged; the
            // quick settings highlight what is under it.
            if (quick.drag(pointer.x - @as(f64, @floatFromInt(quick.x)))) |v| setVolume(v, false, &quick, &dock, &renderer, &audio_devices, &quick_dirty);
            if (quick.pointerAt(if (server.grab == null and server.drag == null) quick.local(pointer.x, pointer.y) else null)) quick_dirty = true;
            const in_dock = dock_visible and server.grab == null and server.drag == null and server.buttons_down == 0;
            const on = if (in_dock) dock.local(pointer.x, pointer.y) else null;
            if (dock.pointerAt(if (on) |l| l[0] else null, if (on) |l| l[1] else 0, sys.nowNs())) {
                dock.draw();
                showDock(&renderer, &dock);
                panels_damaged = true;
            }
        }
        // The background image, once it is ready (or gone).
        if (background_image.poll()) |outcome| {
            boot_fade.ready = true;
            switch (outcome) {
                .image => |ready| {
                    var img = ready;
                    defer img.deinit(gpa);
                    renderer.setBackgroundImage(&img) catch |err| print(sys.log_warning ++ "dazzle-shell: cannot show the background image: {s}\n", .{@errorName(err)});
                },
                .none => renderer.setBackgroundImage(null) catch {},
                .failed => |err| {
                    print(sys.log_warning ++ "dazzle-shell: cannot read the background image: {s}\n", .{@errorName(err)});
                    renderer.setBackgroundImage(null) catch {};
                },
            }
            server.damaged = true;
        }
        // The name of the app whose icon the pointer rests on, once it has
        // rested a while.
        if (dock.drawTooltip(sys.nowNs())) |tip| {
            renderer.setPanelAt(.tooltip, tip.picture, tip.x, tip.y);
            panels_damaged = true;
        }
        // The input method's candidates, as they change.
        {
            var gone = false;
            if (ime.draw(&server, sys.nowNs(), dock.scale, &gone)) |c| {
                renderer.setPanelAt(.candidates, c.picture, c.x, c.y);
                candidates_hidden = false;
                panels_damaged = true;
            } else if (gone and !candidates_hidden) {
                candidates_hidden = true;
                panels_damaged = true;
            }
        }

        if (screenshot_wanted) {
            screenshot_wanted = false;
            var windows: [render.max_windows]render.Window = undefined;
            if (renderer.capture(gpa, if (locked) &.{} else frameWindows(&server, &windows), false)) |pixels| {
                screenshot.save(gpa, screenshot.folder, pixels, renderer.width, renderer.height, shot_pipe[1]);
            } else |err| print(sys.log_warning ++ "dazzle-shell: cannot take a screenshot: {s}\n", .{@errorName(err)});
        }

        if (fds[0].revents != 0) {
            const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) == .SUCCESS) {
                _ = try server.addClient(@intCast(rc));
                print("dazzle-shell: client connected\n", .{});
            }
        }
        // Clients may disconnect (and leave the list) while being handled.
        var i: usize = 0;
        while (i < server.clients.items.len) {
            const c = server.clients.items[i];
            const ready = for (fds[2 .. n_clients + 2]) |f| {
                if (f.fd == c.conn.fd) break f.revents != 0;
            } else false;
            if (ready and !server.dispatch(c)) {
                print("dazzle-shell: client disconnected\n", .{});
                continue;
            }
            i += 1;
        }
        // Once its requests are handled, a client whose process ended goes.
        for (exits) |f| if (f.revents != 0 and f.fd >= 0 and server.clientExited(f.fd)) {
            print("dazzle-shell: client's process ended\n", .{});
        };

        if (server.damaged) client_frame_ns = sys.nowNs();

        // The window under the pointer, and the one with the keyboard, may
        // have changed; the pointer over the dock or its quick settings is
        // the shell's.
        server.shell_areas = .{
            if (dock_shown and !server.fullscreenTop() and dock.slide == 0) dockArea(&dock) else null,
            if (quick.shown) .{ .x = quick.x, .y = quick.y, .width = quick.width, .height = quick.height } else null,
        };
        server.updateFocus();

        const top = server.topWindow();
        const t_now = sys.nowNs();
        if (apps_changes.sound) {
            const vol = dock_mod.readVolumeStatus();
            if (!std.meta.eql(vol, dock.volume) and !quick.dragging) {
                dock.volume = vol;
                quick_dirty = true;
                if (dock_shown) {
                    dock.draw();
                    showDock(&renderer, &dock);
                    panels_damaged = true;
                }
            }
        }
        if (apps_changes.remote) if (remote.configure(sys.remote.load())) {
            // The person at the screen is told, and how to reach it.
            notice.theme = dock.theme;
            var body_buf: [64]u8 = undefined;
            if (remote.code) |code| {
                notice.show(.warning, locale.text("Remote control is on"), std.fmt.bufPrint(&body_buf, "Code {d}, port {d}", .{ code, sys.remote.port }) catch "", sys.nowNs());
            } else notice.show(.check, locale.text("Remote control is off"), "", sys.nowNs());
            server.damaged = true;
        };
        if (apps_changes.appearance) {
            const chosen = dock_mod.readAppearance();
            if (chosen.theme != dock.theme or chosen.clock != dock.show_clock or chosen.network != dock.show_network) {
                dock.theme = chosen.theme;
                dock.show_clock = chosen.clock;
                dock.show_network = chosen.network;
                quick_dirty = true;
                if (dock_shown) {
                    dock.draw();
                    showDock(&renderer, &dock);
                }
                panels_damaged = true;
            }
            wantBackground(&background_image, &renderer, chosen);
            server.wakeAll();
        }
        if (t_now >= next_tick) {
            last_tick = t_now;
            // Keyboards and mice plugged in since, if they cannot be
            // watched for.
            if (devices.watch == null) devices.scan();
            // Whether data moved over the network this second (the kernel
            // tells nothing of it as it happens: its counters are read).
            const now_traffic = dock_mod.readTraffic();
            const activity = dock_mod.Activity.between(traffic, now_traffic);
            traffic = now_traffic;
            if (!std.meta.eql(activity, dock.activity)) {
                dock.activity = activity;
                if (dock_shown) {
                    dock.draw();
                    showDock(&renderer, &dock);
                    panels_damaged = true;
                }
            }
            if (net_sub.fd == null) {
                net_sub.connect();
                if (net_sub.poll()) |r| if (!r.denied) {
                    quick.network = .fromReport(&r);
                    quick_dirty = true;
                    const net = dock_mod.networkStatusFromReport(r);
                    if (!std.meta.eql(net, dock.network)) {
                        dock.network = net;
                        if (dock_shown) {
                            dock.draw();
                            showDock(&renderer, &dock);
                            panels_damaged = true;
                        }
                    }
                };
            }
            if (sys_sub.fd == null) {
                sys_sub.connect();
                if (sys_sub.poll()) |r| if (!r.denied) {
                    if (applyLocale(r.locale, &server, &lock, &dock, &quick)) panels_damaged = true;
                    if (updates.setReport(r)) updates_changed = true;
                    if (applyParental(r.parental, &parental, &locked, &lock, &quick, &renderer)) {
                        server.damaged = true;
                        panels_damaged = true;
                        if (locked) server.breakLock();
                    }
                };
                if (apps_watch.retry()) apps_pending = .all;
            }
            // The clock, a minute on: the dock's, and the quick settings'.
            const wall = sys.realtimeSec();
            if (dock_shown and dock.clockBehind(wall)) {
                dock.draw();
                showDock(&renderer, &dock);
                panels_damaged = true;
            }
            if (quick.shown) if (quick.time) |t| if (t.minute != @divFloor(wall, 60)) {
                quick_dirty = true;
            };
            // The daily check for updates, when it is due.
            if (updates.tick(t_now)) updates_changed = true;
            // Time running out: said, at ten minutes, five and one.
            var warn_buf: [192]u8 = undefined;
            if (warnings.due(parental, sys.realtimeSec(), lock.zone, &warn_buf)) |w| {
                notice.theme = dock.theme;
                notice.show(.schedule, w.title, w.body, sys.nowNs());
                server.damaged = true;
            }
            if (perf_shown) {
                var pids: [max_clients]linux.pid_t = undefined;
                perf.draw(perf_monitor.sample(t_now, perf_frames, perf_gpu_ns, clientPids(&server, &pids)), dock.theme);
                perf_frames = 0;
                perf_gpu_ns = 0;
                renderer.setPanelAt(.perf, perf.picture(), perf.x, perf.y);
                panels_damaged = true;
            }
        }

        // Gone with the dock (a fullscreen window came on top); or drawn
        // again, as it is now.
        if (quick.shown and (!dock_shown or server.fullscreenTop())) {
            quick.close();
            panels_damaged = true;
        }
        if (quick_dirty) panels_damaged = true;
        if (quick_dirty and quick.shown) {
            quick.theme = dock.theme;
            quick.volume = dock.volume;
            quick.updates = .of(updates.system, updates.apps_newer);
            quick.draw();
            const box = dock.place();
            const status = dock.statusRect();
            quick.place(box.x + @as(i32, @intFromFloat(@round(status.x + status.width))), box.y, renderer.width);
            renderer.setPanelAt(.quick, quick.picture(), quick.x, quick.y);
            panels_damaged = true;
        }
        quick_dirty = false;
        if (updates_changed) {
            dock.updates = updates.available;
            quick_dirty = true;
            print("dazzle-shell: {s}\n", .{if (updates.available) "updates available" else "up to date"});
            if (dock_shown) {
                dock.draw();
                showDock(&renderer, &dock);
                panels_damaged = true;
            }
        }

        // Draw while the previous frame is on the screen; it is shown at
        // the next vertical blank, without waiting here. A change to the
        // dock alone waits for a while if a client is animating, and goes
        // out with its next frame: otherwise it would take the next
        // vertical blank, and the client's frame would be shown a refresh
        // late.
        if (!renderer.flipPending()) {
            _ = server.animateOverview(sys.nowNs());
            _ = server.animateWindows(sys.nowNs());
            slideDock(&dock, &server, &renderer, dock_shown, osk.shown, sys.nowNs());
            slideOsk(&osk, &server, &renderer, sys.nowNs());
            animateNotice(&notice, &renderer, &server, sys.nowNs());
        }
        const dock_due = panels_damaged and sys.nowNs() >= client_frame_ns + panel_grace_ns;
        // The boot screen fading out: a frame each refresh until it has.
        if (!renderer.flipPending() and boot_fade.step(&renderer, sys.nowNs())) server.damaged = true;
        if ((server.damaged or dock_due) and !renderer.flipPending()) {
            const count_frame = server.damaged;
            panels_damaged = false;
            server.frameDrawn();
            // A fullscreen window on top sends the dock down, off the
            // screen; its tooltip goes at once.
            renderer.setPanelHidden(.dock, !dock_shown or dock.offScreen() or locked);
            renderer.setPanelHidden(.lock, !locked);
            renderer.setPanelHidden(.power, !power.shown);
            renderer.setPanelHidden(.tooltip, locked or !dock_shown or server.fullscreenTop() or dock.slide > 0 or dock.tooltip_shown == null);
            renderer.setPanelHidden(.perf, !perf_shown);
            renderer.setPanelHidden(.quick, !quick.shown);
            renderer.setPanelHidden(.notice, !notice.visible(sys.nowNs()));
            renderer.setPanelHidden(.candidates, locked or candidates_hidden);
            // A maximized, full-size window on top goes straight onto the
            // display, with the dock on a plane below it; a fullscreen one,
            // alone. Otherwise (or if the display cannot show it) the frame
            // is composited.
            var on_screen: ?bool = null;
            // Not while the dock slides: it would leave its band.
            if (!locked and !power.shown) if (top) |t| if (!dock.sliding()) if (server.scanoutBuffer(t)) |b| {
                const at = server.windowRect(t);
                const direct_started = sys.nowNs();
                const shown = renderer.showDirect(b.dmabuf.?, at.x, at.y, .{ at.width, at.height });
                if (shown != null) frame_times.direct.add(sys.nowNs() - direct_started, 0);
                if (shown) |at_once| {
                    server.holdBuffer(b);
                    scanout.queued = b;
                    if (count_frame) perf_frames += 1;
                    on_screen = at_once;
                }
            };
            // Said when it changes: a window shown directly costs the GPU
            // nothing more; composited, a copy of it each frame.
            const now_direct = on_screen != null;
            if (now_direct != shown_directly) {
                shown_directly = now_direct;
                if (now_direct) print("dazzle-shell: showing \"{s}\" directly\n", .{top.?.title()}) else print("dazzle-shell: compositing\n", .{});
            }
            if (on_screen == null) {
                var windows: [render.max_windows]render.Window = undefined;
                if (renderer.composite(if (locked) &.{} else frameWindows(&server, &windows))) |timing| {
                    frame_times.composited.add(timing.cpu_ns + timing.gpu_ns, @as(u64, renderer.width) * renderer.height);
                    if (count_frame) perf_frames += 1;
                    perf_gpu_ns += timing.gpu_ns;
                    on_screen = renderer.show() catch |err| blk: {
                        print(sys.log_warning ++ "dazzle-shell: cannot show the frame: {s}\n", .{@errorName(err)});
                        server.framePresented(@truncate(sys.nowNs() / std.time.ns_per_ms));
                        break :blk false;
                    };
                } else |err| {
                    // Nothing new reaches the screen, but the clients should
                    // not wait for it.
                    print(sys.log_error ++ "dazzle-shell: frame failed: {s}\n", .{@errorName(err)});
                    server.framePresented(@truncate(sys.nowNs() / std.time.ns_per_ms));
                    on_screen = false;
                }
            }
            if (on_screen.?) {
                const direct = scanout.queued != null;
                scanout.presented(&server);
                const kind = wayland.protocol.wp_presentation_feedback.kind;
                const flags: u32 = kind.vsync | kind.hw_completion | (if (direct) @as(u32, kind.zero_copy) else 0);
                server.framePresentedNs(sys.nowNs(), flags);
            }
            // The cursor plane needs the mode the first frame set.
            if (!cursor_shown) {
                cursor_shown = true;
                // How long starting took (the boot screen was shown until
                // now), for the log.
                took.step(.first_frame);
                took.report(launched);
            }
        }
        // The pointer, while a mouse is plugged in (a touchscreen has none).
        if (cursor_shown) {
            // (A touchscreen beside the monitor is its touchpad.)
            const mouse = devices.hasMouse() or companion != null;
            if (mouse and renderer.cursor_shape == null) {
                if (renderer.showCursor(.arrow)) {
                    renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
                    print("dazzle-shell: cursor shown (a mouse)\n", .{});
                } else |err| print(sys.log_warning ++ "dazzle-shell: no cursor: {s}\n", .{@errorName(err)});
            } else if (!mouse and renderer.cursor_shape != null) {
                renderer.hideCursor();
                print("dazzle-shell: cursor hidden (no mouse)\n", .{});
            }
        }
        // The pointer's picture: a hand over what can be clicked on the
        // dock and its quick settings, a resize while one is under way, or
        // what the window under it chose.
        const over_shell = server.grab == null and server.drag == null and
            (quick.dragging or quick.hover != null or
                (if (server.shell_areas[0] != null) if (dock.local(pointer.x, pointer.y)) |at| dock.hit(at[0], at[1]) != null or dock.hitStatus(at[0], at[1]) else false else false));
        const want: server_mod.Server.Cursor = if (over_shell) .pointer else server.cursor();
        if (renderer.cursor_shape) |shown| if (want != shown) {
            if (renderer.showCursor(want)) {
                renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
            } else |err| print(sys.log_warning ++ "dazzle-shell: cannot change the cursor: {s}\n", .{@errorName(err)});
        };
        server.flushClients();
    }
}

/// The boot screen's last frame (see init's splash.zig), shown over
/// everything on the display's top plane from the shell's first frame, so
/// nothing changes then; once the desktop is ready (its background loaded,
/// or after a moment), it fades out, by the plane's alpha. Not if the
/// display cannot (no plane for it, or no alpha): the desktop is shown at
/// once.
const BootFade = struct {
    fb_id: u32 = 0,
    handle: u32 = 0,
    layer: vc4.kms.Layer = undefined,
    /// When the first frame was shown, and when fading began.
    first_ns: ?u64 = null,
    fading_ns: ?u64 = null,
    /// The desktop is ready to be seen.
    ready: bool = false,
    /// Taken away: the framebuffer goes once the frame without it is on
    /// the screen.
    gone: bool = false,

    const hold_ns = 1500 * std.time.ns_per_ms;
    const fade_ns = 500 * std.time.ns_per_ms;

    fn start(renderer: *render.Renderer) BootFade {
        const k = &(renderer.display.kms orelse return none("no atomic mode setting"));
        if (k.cover_plane == null) return none("no plane for it");
        if (!k.canFadeCover()) return none("the display's planes have no alpha");
        const shown = vc4.drm.adoptShown(renderer.display.fd, renderer.display.output.crtc_id) orelse return none("nothing to take");
        const w: u32 = renderer.width;
        const h: u32 = renderer.height;
        var f: BootFade = .{ .fb_id = shown.fb_id, .handle = shown.handle };
        f.layer = .{ .fb_id = shown.fb_id, .src_width = @min(shown.width, w), .src_height = @min(shown.height, h), .x = 0, .y = 0, .width = @min(shown.width, w), .height = @min(shown.height, h) };
        if (!k.setCover(f.layer)) {
            f.release(renderer);
            return none("no plane for it");
        }
        print("dazzle-shell: fading in from the boot screen\n", .{});
        return f;
    }

    fn none(why: []const u8) BootFade {
        print("dazzle-shell: not fading in from the boot screen: {s}\n", .{why});
        return .{ .gone = true };
    }

    /// Before each frame: whether the cover changed (a frame is needed).
    fn step(f: *BootFade, renderer: *render.Renderer, now: u64) bool {
        if (f.fb_id == 0) return false;
        const k = &(renderer.display.kms orelse return false);
        if (f.gone) {
            // The frame without it is on the screen: it can go.
            f.release(renderer);
            return false;
        }
        const first = f.first_ns orelse {
            f.first_ns = now;
            return false;
        };
        const fading = f.fading_ns orelse blk: {
            if (!f.ready and now - first < hold_ns) return false;
            f.fading_ns = now;
            break :blk now;
        };
        const t = @min(@as(f32, @floatFromInt(now - fading)) / @as(f32, @floatFromInt(fade_ns)), 1);
        if (t >= 1) {
            _ = k.setCover(null);
            f.gone = true;
            return true;
        }
        var layer = f.layer;
        // Eased: quick at first, gentle at the end.
        const ease = 1 - (1 - t) * (1 - t);
        layer.alpha = @intFromFloat(@round((1 - ease) * 0xffff));
        _ = k.setCover(layer);
        return true;
    }

    fn release(f: *BootFade, renderer: *render.Renderer) void {
        if (f.fb_id != 0) vc4.drm.removeFramebuffer(renderer.display.fd, f.fb_id);
        if (f.handle != 0) vc4.drm.gemClose(renderer.display.fd, f.handle);
        f.fb_id = 0;
        f.handle = 0;
    }
};

/// How long the parts of starting took (milliseconds), for the log.
const StartTimes = struct {
    at: u64,
    ms: std.EnumArray(Step, u64) = .initFill(0),

    const Step = enum { display, fonts, apps, dock, updates, background, rest, first_frame };

    fn step(t: *StartTimes, s: Step) void {
        const now = sys.nowNs();
        t.ms.set(s, (now - t.at) / std.time.ns_per_ms);
        t.at = now;
    }

    fn report(t: *const StartTimes, launched: u64) void {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (std.enums.values(Step), 0..) |s, i| w.print("{s}{s} {d}", .{ if (i == 0) "" else ", ", @tagName(s), t.ms.get(s) }) catch {};
        print("dazzle-shell: first frame, {d} ms after the shell started ({s} ms)\n", .{ (t.at - launched) / std.time.ns_per_ms, w.buffered() });
    }
};

/// How long a change to the dock alone waits for a client's
/// frame to go out with (a few refreshes).
const panel_grace_ns = 50 * std.time.ns_per_ms;

/// The client buffers on the display, shown directly.
const Scanout = struct {
    /// On the screen now.
    shown: ?*server_mod.Buffer = null,
    /// In the frame queued for the next vertical blank.
    queued: ?*server_mod.Buffer = null,

    /// The queued frame reached the screen: the buffer it replaced goes
    /// back to its client.
    fn presented(s: *Scanout, server: *server_mod.Server) void {
        if (s.shown) |b| server.dropBuffer(b);
        s.shown = s.queued;
        s.queued = null;
    }
};

const max_clients = 32;

/// The pointer: input events move it and go to the server.

const Pointer = struct {
    x: f64,
    y: f64,
    max_x: f64,
    max_y: f64,
    /// Motion not sent to the server yet, and how much.
    pending_motion: bool = false,
    dx: f64 = 0,
    dy: f64 = 0,
    /// Pointer events since the last frame.
    in_frame: bool = false,
    /// Moved since the cursor was last moved.
    moved: bool = false,

    fn handle(ptr: *Pointer, server: *server_mod.Server, time_ms: u32, e: input.Event) void {
        switch (e) {
            .motion => |d| {
                ptr.dx += @floatFromInt(d[0]);
                ptr.dy += @floatFromInt(d[1]);
                ptr.pending_motion = true;
            },
            .button => |b| {
                ptr.flushMotion(server, time_ms);
                server.pointerButton(time_ms, b.code, b.pressed);
                ptr.in_frame = true;
            },
            .axis => |a| {
                ptr.flushMotion(server, time_ms);
                server.pointerAxis(time_ms, a.axis, a.value);
                ptr.in_frame = true;
            },
            .key => |k| {
                // The Super key takes the pointer back from a game that
                // has it locked.
                if (k.code == evdev.key_leftmeta and k.pressed) server.breakLock();
                server.keyboardKey(time_ms, k.code, k.pressed);
            },
            // Touches are handled before.
            .touch => {},
            .frame => {
                ptr.flushMotion(server, time_ms);
                if (ptr.in_frame) server.pointerFrame();
                ptr.in_frame = false;
            },
        }
    }

    /// X and Y motion arrive as separate events; they become one. A
    /// locked pointer stays where it is (the client hears only how it
    /// moved).
    fn flushMotion(ptr: *Pointer, server: *server_mod.Server, time_ms: u32) void {
        if (!ptr.pending_motion) return;
        ptr.pending_motion = false;
        ptr.in_frame = true;
        const dx = ptr.dx;
        const dy = ptr.dy;
        ptr.dx = 0;
        ptr.dy = 0;
        if (server.pointerRelative(time_ms, dx, dy)) return;
        const clamped = server.clampPointer(
            std.math.clamp(ptr.x + dx, 0, ptr.max_x),
            std.math.clamp(ptr.y + dy, 0, ptr.max_y),
        );
        ptr.x = clamped[0];
        ptr.y = clamped[1];
        ptr.moved = true;
        server.pointerMotion(time_ms, ptr.x, ptr.y);
    }
};

/// A few touch IDs.
const TouchSet = struct {
    ids: [10]?i32 = @splat(null),

    fn set(t: *TouchSet, id: i32) void {
        for (&t.ids) |*slot| if (slot.* == null) {
            slot.* = id;
            return;
        };
    }

    fn any(t: *const TouchSet) bool {
        for (t.ids) |slot| if (slot != null) return true;
        return false;
    }

    fn has(t: *const TouchSet, id: i32) bool {
        for (t.ids) |slot| if (slot == id) return true;
        return false;
    }

    /// Removes `id`; returns whether it was there.
    fn unset(t: *TouchSet, id: i32) bool {
        for (&t.ids) |*slot| if (slot.* == id) {
            slot.* = null;
            return true;
        };
        return false;
    }
};

/// Creates the listening socket, replacing a stale one.
fn listen(path: [:0]const u8) !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer sys.close(fd);
    _ = linux.unlink(path);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    _ = try sys.check(linux.listen(fd, 8));
    return fd;
}

/// A socket the kernel's uevents come on (a display plugged in, among
/// them).
fn openHotplug() !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.NETLINK.KOBJECT_UEVENT)));
    errdefer sys.close(fd);
    var addr: linux.sockaddr.nl = .{ .pid = 0, .groups = 1 };
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)));
    return fd;
}

/// Reads the uevents there; whether one is of a display (DRM) changing.
fn drmChanged(fd: linux.fd_t) bool {
    var changed = false;
    var buf: [2048]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        if (isDrmHotplug(buf[0..n])) changed = true;
    }
    return changed;
}

/// Whether a uevent (its fields, each ended by a NUL) says a display was
/// plugged in or unplugged.
fn isDrmHotplug(event: []const u8) bool {
    var drm = false;
    var hotplug_ = false;
    var it = std.mem.splitScalar(u8, event, 0);
    while (it.next()) |field| {
        if (std.mem.eql(u8, field, "SUBSYSTEM=drm")) drm = true;
        if (std.mem.eql(u8, field, "HOTPLUG=1")) hotplug_ = true;
    }
    return drm and hotplug_;
}

/// After a display was plugged in or unplugged: the desktop on the monitor
/// if one is connected (the touchscreen, if there is one, its keyboard and
/// touchpad), else on the touchscreen. Returns whether it moved.
fn moveDisplays(gpa: std.mem.Allocator, dev: vc4.Device, kit: *kete_panel.Kit, renderer: *render.Renderer, companion: *?companion_mod.Companion, parked: *?companion_mod.Companion, orientations: sys.system.Orientations, osk: *osk_mod.Osk) !bool {
    const want = vc4.drm.findOutput(dev.fd) catch return false;
    const was = renderer.display.output;
    if (want.connector_id == was.connector_id and std.meta.eql(want.mode, was.mode)) return false;
    if (companion.*) |*cm| if (cm.renderer.display.output.connector_id == want.connector_id) {
        // The monitor unplugged: the desktop on the touchscreen, its
        // keyboard and touchpad put aside (its renderer keeps nothing of
        // the display, which is the desktop's now). Its last frame shown
        // first: the desktop's frames wait for none of its.
        const waited = sys.nowNs();
        while (!cm.serviceFlip(sys.nowNs())) sys.sleepMs(2);
        print("dazzle-shell: the touchscreen's last frame shown after {d} ms\n", .{(sys.nowNs() - waited) / std.time.ns_per_ms});
        var old = renderer.swapDisplay(cm.renderer.display, turnFor(orientations, want));
        renderer.display.shared = false;
        old.deinit(dev);
        parked.* = cm.*;
        companion.* = null;
        osk.setScreen(renderer.width, renderer.height, 1);
        print("dazzle-shell: the monitor unplugged: the desktop on the touchscreen ({d}x{d})\n", .{ renderer.width, renderer.height });
        return true;
    };
    var old = renderer.swapDisplay(try vc4.display.Display.init(dev, want, .xrgb8888), turnFor(orientations, want));
    print("dazzle-shell: the desktop on the {s} display ({d}x{d})\n", .{ @tagName(want.port), renderer.width, renderer.height });
    if (!old.output.dsi or want.dsi) {
        old.deinit(dev);
        return true;
    }
    // A monitor plugged in beside the touchscreen: the touchscreen its
    // keyboard and touchpad again.
    var cm: companion_mod.Companion = if (parked.*) |p| blk: {
        var c = p;
        _ = c.renderer.swapDisplay(old, turnFor(orientations, old.output));
        break :blk c;
    } else blk: {
        const output = old.output;
        old.deinit(dev);
        break :blk .{ .renderer = try render.Renderer.init(gpa, dev, output), .panel = try kit.gpuPanel() };
    };
    parked.* = null;
    renderer.display.shared = true;
    cm.renderer.display.shared = true;
    osk.setScreen(cm.width(), cm.height(), 1);
    cm.layout(osk.height);
    renderer.setPanelHidden(.keyboard, true);
    companion.* = cm;
    print("dazzle-shell: the touchscreen ({d}x{d}) is the monitor's keyboard and touchpad\n", .{ cm.width(), cm.height() });
    return true;
}

/// How `output`'s display is turned for its port's orientation.
fn turnFor(orientations: sys.system.Orientations, output: vc4.drm.Output) sys.system.Turn {
    return orientations.get(output.port).turn(output.mode.hdisplay, output.mode.vdisplay);
}

/// An app asks for another to be opened (see `sys.shell`): one running is
/// raised, and told what to show; another is started, with it as its
/// argument. Returns whether an app was started. (Or it asks the screen's
/// size.)
fn openApp(listener: linux.fd_t, apps: []dock_mod.App, server: *server_mod.Server, renderer: *const render.Renderer, runtime_dir: ?[:0]const u8) bool {
    var buf: [160]u8 = undefined;
    const got = sys.shell.accept(listener, &buf) orelse return false;
    defer sys.close(got.fd);
    const parsed = sys.shell.Request.parse(got.line) orelse {
        _ = linux.write(got.fd, "unknown\n", 8);
        return false;
    };
    const req = switch (parsed) {
        .open => |o| o,
        .screen => {
            var size_buf: [32]u8 = undefined;
            const line = std.fmt.bufPrint(&size_buf, "{d} {d} {s}\n", .{ renderer.width, renderer.height, @tagName(renderer.port()) }) catch return false;
            _ = linux.write(got.fd, line.ptr, line.len);
            return false;
        },
    };
    const app = for (apps) |*a| {
        if (std.mem.eql(u8, a.name, req.app)) break a;
    } else {
        _ = linux.write(got.fd, "unknown\n", 8);
        return false;
    };
    _ = linux.write(got.fd, "opened\n", 7);
    return openAt(app, req.what, server, runtime_dir);
}

/// Opens `app` at `what` (a page of it, a file: what it takes as its
/// argument), or raises it and tells it `what` if it is already running.
/// Returns whether it was started (the dock then shows it running).
fn openAt(app: *dock_mod.App, what: ?[]const u8, server: *server_mod.Server, runtime_dir: ?[:0]const u8) bool {
    if (app.pid) |pid| {
        _ = server.raise(pid);
        if (what) |w| {
            var path_buf: [96]u8 = undefined;
            var line_buf: [80]u8 = undefined;
            var none: [0]u8 = .{};
            if (sys.shell.appSocket(&path_buf, app.name)) |path| {
                const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{w}) catch return false;
                _ = sys.shell.send(path, line, &none);
            }
        }
        return false;
    }
    var arg_buf: [80]u8 = undefined;
    const arg: ?[*:0]const u8 = if (what) |w| (std.mem.printSentinel(&arg_buf, "{s}", .{w}, 0) catch return false).ptr else null;
    print("dazzle-shell: opening {s}{s}{s}\n", .{ app.name, if (what != null) " at " else "", what orelse "" });
    app.pid = spawn(app.path, arg, runtime_dir);
    return true;
}

/// Starts `app`, or raises its window to the front if it is already running.
/// Asks for the background image the appearance settings name (if any),
/// made ready as the GPU best takes it.
fn wantBackground(loader: *background_mod.Loader, renderer: *render.Renderer, a: dock_mod.Appearance) void {
    const path = a.image.slice();
    loader.want(path, if (path != null) renderer.backgroundKind() else renderer.background16());
}

/// Sets the volume (as the quick settings' slider or mute say): on the
/// sound cards at once, and kept (`save`) once it is chosen (not while the
/// slider is still dragged).
fn setVolume(v: dock_mod.VolumeStatus, save: bool, quick: *quick_mod.Quick, dock: *dock_mod.Dock, renderer: *render.Renderer, devices: *const audio.Devices, quick_dirty: *bool) void {
    var s = audio.loadSettings();
    s.volume = v.volume;
    s.muted = v.muted;
    audio.applySettings(s, devices);
    if (save) audio.saveSettings(s);
    dock.volume = v;
    quick.volume = v;
    quick_dirty.* = true;
    dock.draw();
    showDock(renderer, dock);
}

/// Does what pressing the quick settings asked.
fn quickAction(
    action: quick_mod.Quick.Action,
    quick: *quick_mod.Quick,
    dock: *dock_mod.Dock,
    renderer: *render.Renderer,
    apps: []dock_mod.App,
    server: *server_mod.Server,
    runtime_dir: ?[:0]const u8,
    devices: *const audio.Devices,
    quick_dirty: *bool,
    power: *power_mod.Menu,
) void {
    switch (action) {
        .none => {},
        .redraw => quick_dirty.* = true,
        .volume => |v| setVolume(v, !quick.dragging, quick, dock, renderer, devices, quick_dirty),
        // Settings' Software page, to update.
        .updates => {
            quick.close();
            quick_dirty.* = true;
            for (apps) |*a| if (std.mem.eql(u8, a.name, "dazzle-settings")) {
                if (openAt(a, "apps", server, runtime_dir)) {
                    dock.draw();
                    showDock(renderer, dock);
                }
            };
        },
        .power_menu => {
            quick.close();
            quick_dirty.* = true;
            power.open();
            drawPower(power, renderer);
        },
    }
}

/// Where the dock's box is on the screen.
fn dockArea(dock: *const dock_mod.Dock) server_mod.Rect {
    const at = dock.place();
    return .{ .x = at.x, .y = at.y, .width = dock.width, .height = dock.height };
}

/// Gives the renderer the dock's latest picture, where it is.
/// (`x`, `y`) on the screen, as a touchscreen would say it: 0 to 1 across
/// the display (turned as the screen is on it).
fn touchAt(renderer: *const render.Renderer, x: f64, y: f64) [2]f64 {
    const sx = x / @as(f64, @floatFromInt(@max(renderer.width, 2) - 1));
    const sy = y / @as(f64, @floatFromInt(@max(renderer.height, 2) - 1));
    return renderer.turn.fromScreen(sx, sy);
}

fn showDock(renderer: *render.Renderer, dock: *const dock_mod.Dock) void {
    const at = dock.place();
    renderer.setPanelAt(.dock, dock.picture(), at.x, at.y);
}

/// Up to `out.len` of the events queued (by remote control), taken from
/// the front of the queue.
fn takeQueued(queue: []input.Event, len: *usize, out: []input.Event) []const input.Event {
    const n = @min(len.*, out.len);
    @memcpy(out[0..n], queue[0..n]);
    std.mem.copyForwards(input.Event, queue[0 .. len.* - n], queue[n..len.*]);
    len.* -= n;
    return out[0..n];
}

/// What remote control's /status says: the screen, the pointer, the
/// windows (top first) and the apps.
fn remoteStatus(gpa: std.mem.Allocator, out: *std.ArrayList(u8), server: *const server_mod.Server, apps: []const dock_mod.App, renderer: *const render.Renderer, pointer: *const Pointer) !void {
    try out.print(gpa, "build {s}\nscreen {d}x{d}\npointer {d:.0} {d:.0}\nwindows (top first):\n", .{ build_info.commit, renderer.width, renderer.height, pointer.x, pointer.y });
    var i = server.toplevels.items.len;
    while (i > 0) {
        i -= 1;
        const t = server.toplevels.items[i];
        const r = server.windowRect(t);
        try out.print(gpa, "  \"{s}\" at {d},{d} {d}x{d}{s}{s}{s}\n", .{ t.title(), r.x, r.y, r.width, r.height, if (t.maximized) " maximized" else "", if (t.fullscreen) " fullscreen" else "", if (t.suspended) " covered" else "" });
    }
    // Memory, and video memory (the CMA pool every GPU buffer comes from):
    // used of all.
    if (sys.meminfo()) |mi| {
        const mib = 1024 * 1024;
        try out.print(gpa, "memory {d} MB of {d} MB\nvideo memory {d} MB of {d} MB\n", .{ (mi.total -| mi.available) / mib, mi.total / mib, (mi.cma_total -| mi.cma_free) / mib, mi.cma_total / mib });
        if (perf_mod.drmMemoryOf(null)) |b| try out.print(gpa, "  the shell's {d} MB\n", .{b / mib});
    }
    try out.print(gpa, "apps:\n", .{});
    for (apps) |a| {
        try out.print(gpa, "  {s}{s}", .{ a.name, if (a.pid != null) " (running)" else "" });
        if (a.pid) |pid| if (perf_mod.drmMemoryOf(pid)) |b| try out.print(gpa, ", {d} MB of video memory", .{b / (1024 * 1024)});
        try out.print(gpa, "\n", .{});
    }
}

/// What the screen's frames have cost: composited (the GPU drawing the
/// whole screen; preparing the panels' pictures for it too), or shown
/// directly (a window's buffer on the display, the panels on planes over
/// it, drawn into them as they changed).
const FrameTimes = struct {
    composited: kete_panel.Times = .{},
    direct: kete_panel.Times = .{},
    /// How often the shell has woken (from waiting for something to
    /// happen), and of those, for its tick.
    wakes: u64 = 0,
    ticks: u64 = 0,
};

/// What drawing each panel has cost (see `kete_panel.Times`): its
/// widgets laid out and painted, drawn into its picture on the CPU, and
/// copied for the display.
fn panelStatus(gpa: std.mem.Allocator, out: *std.ArrayList(u8), renderer: *const render.Renderer, panels: []const struct { render.PanelId, *const kete_panel.Panel }) !void {
    try out.print(gpa, "panels:\n", .{});
    for (panels) |entry| {
        const id, const p = entry;
        const copies = renderer.panelTimes(id);
        try out.print(gpa, "  {s} {d}x{d}\n    frame {f}\n    render {f}\n    of it the GPU {f}\n    of that waiting {f}\n    submitting {f}\n    texture {f}\n    overlay {f}\n", .{ @tagName(id), p.width, p.height, p.frame_times, p.render_times, p.gpu_times, p.wait_times, p.submit_times, copies[0], copies[1] });
    }
}

/// Fades the notification in or out, a frame each refresh while it does;
/// and a frame more when it has gone.
/// A report's parental controls: locks, or unlocks, the screen as they
/// say. Returns whether the screen changed.
/// The system's keyboard and time zone, as its report says: the
/// keyboard for the windows; the zone for the clock (the dock's, and the
/// quick settings') and the lock screen. Returns whether the clock
/// changed.
fn applyLocale(l: locale.Settings, server: *server_mod.Server, lock: *lock_mod.Screen, dock: *dock_mod.Dock, quick: *quick_mod.Quick) bool {
    if (l.keyboard != server.keyboard_layout) {
        print("dazzle-shell: keyboard {s}\n", .{l.keyboard.code()});
        server.setKeyboard(l.keyboard);
    }
    // The language says how the time is written (18:05, 6:05 PM).
    const language_changed = l.language != locale.current;
    locale.current = l.language;
    // The panels stay left to right in Arabic (their text still runs
    // right to left): the dock finds what is clicked, and where its
    // tooltips go, by its own geometry, which kete's mirroring would not
    // follow.
    if (language_changed) dock.time = null;
    if (l.timezone == lock.zone) return language_changed;
    print("dazzle-shell: time zone {s}\n", .{l.timezone.name()});
    lock.zone = l.timezone;
    dock.setTimeZone(l.timezone);
    quick.zone = l.timezone;
    return true;
}

fn applyParental(p: sys.system.Parental, have: *sys.system.Parental, locked: *bool, lock: *lock_mod.Screen, quick: *quick_mod.Quick, renderer: *render.Renderer) bool {
    const changed = !std.meta.eql(p, have.*);
    have.* = p;
    const now_locked = p.on and p.lock != .none;
    if (now_locked != locked.*) {
        locked.* = now_locked;
        lock.entry.clear();
        lock.entry.wrong = false;
        lock.panel.followTheme();
        print("dazzle-shell: {s}\n", .{if (now_locked) "locked by parental controls" else "unlocked"});
        if (now_locked) quick.close();
    }
    if (!changed and !locked.*) return false;
    if (locked.*) drawLock(lock, p, renderer);
    return true;
}

/// Draws the power menu, in the middle of the screen.
fn drawPower(power: *power_mod.Menu, renderer: *render.Renderer) void {
    const picture = power.draw(sys.nowNs());
    if (picture.isEmpty()) return;
    const at = power_mod.Menu.place(renderer.width, renderer.height);
    renderer.setPanelAt(.power, picture, at[0], at[1]);
}

/// Does what was picked in the power menu: the system manager powers off
/// or restarts (as Raspberry Pi OS does, the kernel's power-off handler
/// ends it: see init's shutdown.zig); or it closes.
fn powerChoice(choice: power_mod.Choice, power: *power_mod.Menu) void {
    power.close();
    const req: []const u8 = switch (choice) {
        .cancel => return,
        .power_off => "power_off\n",
        .restart => "restart\n",
    };
    print("dazzle-shell: {s}\n", .{if (choice == .power_off) "powering off" else "restarting"});
    if (sys.system.ask(req, 3000) == null) print(sys.log_warning ++ "dazzle-shell: cannot {s}: the system did not answer\n", .{if (choice == .power_off) "power off" else "restart"});
}

fn drawLock(lock: *lock_mod.Screen, p: sys.system.Parental, renderer: *render.Renderer) void {
    const picture = lock.draw(p);
    if (picture.isEmpty()) return;
    const at = lock_mod.Screen.place(renderer.width, renderer.height);
    renderer.setPanelAt(.lock, picture, at[0], at[1]);
}

/// A key on the lock screen; Enter tries the password (the system manager
/// turns parental controls off if it is the one). Returns whether the
/// screen changed.
/// Where (`x`, `y`) on the screen is on the lock screen.
fn lockLocal(x: f64, y: f64, renderer: *const render.Renderer) [2]f32 {
    const at = lock_mod.Screen.place(renderer.width, renderer.height);
    return .{ @floatCast(x - @as(f64, @floatFromInt(at[0]))), @floatCast(y - @as(f64, @floatFromInt(at[1]))) };
}

/// Draws the lock screen again if what it shows changed (the pointer over
/// a button, say).
fn lockRedraw(lock: *lock_mod.Screen, p: sys.system.Parental, renderer: *render.Renderer) bool {
    if (!lock.panel.needsFrame()) return false;
    drawLock(lock, p, renderer);
    return true;
}

fn lockKey(lock: *lock_mod.Screen, code: u32, pressed: bool, parental: *sys.system.Parental, locked: *bool, quick: *quick_mod.Quick, renderer: *render.Renderer) bool {
    lock.panel.key(code, pressed);
    return lockAfterInput(lock, parental, locked, quick, renderer);
}

/// After a key or a click on the lock screen: the password tried, if it
/// was given.
fn lockAfterInput(lock: *lock_mod.Screen, parental: *sys.system.Parental, locked: *bool, quick: *quick_mod.Quick, renderer: *render.Renderer) bool {
    // The field takes it at the next frame.
    _ = lock.draw(parental.*);
    if (lock.entry.submitted) {
        var hex_buf: [2 * sys.parental.max_password]u8 = undefined;
        var req_buf: [32 + 2 * sys.parental.max_password]u8 = undefined;
        const pw = sys.parental.Password.of(lock.entry.password()) orelse return false;
        const req = std.fmt.bufPrint(&req_buf, "parental_off {s}\n", .{pw.hex(&hex_buf)}) catch return false;
        lock.entry.clear();
        const answer = sys.system.ask(req, 5000);
        if (answer) |r| if (r.password == true) {
            _ = applyParental(r.parental, parental, locked, lock, quick, renderer);
            return true;
        };
        lock.entry.wrong = true;
    }
    drawLock(lock, parental.*, renderer);
    return true;
}

fn animateNotice(notice: *notice_mod.Notice, renderer: *render.Renderer, server: *server_mod.Server, now: u64) void {
    const was_shown = notice.shown_ns != null;
    if (notice.frame(now)) |pixels| {
        const at = notice.place();
        renderer.setPanelAt(.notice, .{ .width = notice.width, .height = notice.height, .pixels = pixels }, at[0], at[1]);
        server.damaged = true;
    } else if (was_shown and notice.shown_ns == null) server.damaged = true;
}

/// Slides the on-screen keyboard up or down, a frame each refresh while it
/// is on its way; down, its panel is hidden.
fn slideOsk(osk: *osk_mod.Osk, server: *server_mod.Server, renderer: *render.Renderer, now: u64) void {
    if (!osk.animate(now)) return;
    renderer.movePanel(.keyboard, 0, osk.top());
    if (!osk.visible()) renderer.setPanelHidden(.keyboard, true);
    server.damaged = true;
}

/// Sends the dock down while a fullscreen window is on top or the
/// on-screen keyboard is shown (`osk_shown`), and back up after, a frame
/// each refresh while it is on its way; and grows and shrinks icons of
/// apps installed or removed, and the box with them.
fn slideDock(dock: *dock_mod.Dock, server: *server_mod.Server, renderer: *render.Renderer, dock_shown: bool, osk_shown: bool, now: u64) void {
    if (dock.resizing()) {
        _ = dock.animateApps(now);
        dock.draw();
        showDock(renderer, dock);
        server.damaged = true;
    }
    if (dock_shown) dock.slideTo(server.fullscreenTop() or osk_shown, now);
    if (!dock.animateSlide(now)) return;
    const at = dock.place();
    renderer.movePanel(.dock, at.x, at.y);
    server.damaged = true;
}

fn activateApp(
    app: *dock_mod.App,
    server: *server_mod.Server,
    dock: *dock_mod.Dock,
    renderer: *render.Renderer,
    runtime_dir: ?[:0]const u8,
    panels_damaged: *bool,
) void {
    if (app.pid) |pid| {
        if (!server.raise(pid)) print("dazzle-shell: {s} has no window yet\n", .{app.label});
    } else {
        app.pid = spawn(app.path, null, runtime_dir);
        dock.draw();
        showDock(renderer, dock);
        panels_damaged.* = true;
    }
}

/// Starts a client program. Dazzle's apps find the shell on
/// /os/sockets/wayland-0;
/// with a runtime directory (run elsewhere) they are told where it is.
fn spawn(program: [*:0]const u8, arg: ?[*:0]const u8, runtime_dir: ?[:0]const u8) ?linux.pid_t {
    var env_buf: [160]u8 = undefined;
    const runtime_env: ?[*:0]const u8 = if (runtime_dir) |dir| (std.mem.printSentinel(&env_buf, "XDG_RUNTIME_DIR={s}", .{dir}, 0) catch return null).ptr else null;
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        print(sys.log_error ++ "dazzle-shell: cannot start {s}: fork failed\n", .{program});
        return null;
    }
    if (rc != 0) {
        print("dazzle-shell: started {s} (pid {d})\n", .{ program, rc });
        return @intCast(rc);
    }
    const argv = [_:null]?[*:0]const u8{ program, arg };
    const envp = if (runtime_env) |r| [_:null]?[*:0]const u8{ "HOME=/", "WAYLAND_DISPLAY=wayland-0", r } else [_:null]?[*:0]const u8{ "HOME=/", null, null };
    const err = linux.errno(linux.execve(program, &argv, &envp));
    print(sys.log_warning ++ "dazzle-shell: cannot run {s} ({s})\n", .{ program, @tagName(err) });
    linux.exit(127);
}

/// The surfaces that can be seen (windows, their subsurfaces and popups),
/// bottom first, as the renderer draws them.
fn frameWindows(server: *server_mod.Server, out: *[render.max_windows]render.Window) []const render.Window {
    var quads: [render.max_windows]server_mod.Server.Quad = undefined;
    const list = server.drawList(&quads);
    for (list, out[0..list.len]) |q, *w| w.* = .{
        .texture = q.texture,
        .x = q.x,
        .y = q.y,
        .width = q.width,
        .height = q.height,
        .transform = q.transform,
        .clip = q.clip,
        .preview = q.preview,
        .radius = q.radius,
        .shadow = q.shadow,
        .shadow_clip = q.shadow_clip,
        .opacity = q.opacity,
    };
    return out[0..list.len];
}

/// Set when a child process exits (SIGCHLD: a client, or one saving a
/// screenshot), so it is reaped.
var child_exited: std.atomic.Value(bool) = .init(true);

/// SIGTERM came: the system is stopping (see init's shutdown.zig).
var stop_asked = std.atomic.Value(bool).init(false);

fn onStop(_: linux.SIG) callconv(.c) void {
    stop_asked.store(true, .monotonic);
}

/// Shows the last frame (`Renderer.showLast`), lets the display go, and
/// waits (a while at most) for the shutdown screen to take it: the frame's
/// buffer stays on the screen until it has.
fn stopShowingLast(renderer: *render.Renderer, windows: []const render.Window) void {
    print("dazzle-shell: stopping\n", .{});
    renderer.showLast(windows) catch |err| {
        print(sys.log_warning ++ "dazzle-shell: cannot show the last frame: {s}\n", .{@errorName(err)});
        return;
    };
    const fd = renderer.display.fd;
    const crtc = renderer.display.output.crtc_id;
    const shown = vc4.drm.crtcFramebuffer(fd, crtc) catch return;
    vc4.drm.dropMaster(fd) catch return;
    const started = sys.nowNs();
    while (sys.nowNs() - started < 3 * std.time.ns_per_s) {
        const now_shown = vc4.drm.crtcFramebuffer(fd, crtc) catch return;
        if (now_shown != shown) return;
        sys.sleepMs(20);
    }
}

fn onChildExit(_: linux.SIG) callconv(.c) void {
    child_exited.store(true, .monotonic);
}

fn watchChildren() void {
    const act: linux.Sigaction = .{
        .handler = .{ .handler = onChildExit },
        .mask = linux.sigemptyset(),
        // System calls (poll) are not restarted: they return EINTR, and the
        // loop goes round.
        .flags = 0,
    };
    _ = linux.sigaction(.CHLD, &act, null);
    const stop: linux.Sigaction = .{ .handler = .{ .handler = onStop }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.TERM, &stop, null);
}

/// Reaps exited clients. Returns whether one was an app (which the dock
/// then shows as not running); the setup app's ending clears `setup_pid`.
fn reapChildren(apps: []dock_mod.App, setup_pid: *?linux.pid_t) bool {
    var app_exited = false;
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, @ptrCast(&status), linux.W.NOHANG, null);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return app_exited;
        for (apps) |*app| if (app.pid == @as(linux.pid_t, @intCast(rc))) {
            app.pid = null;
            app_exited = true;
        };
        if (setup_pid.* == @as(linux.pid_t, @intCast(rc))) setup_pid.* = null;
        if (linux.W.IFEXITED(status)) {
            print("dazzle-shell: client {d} exited with status {d}\n", .{ rc, linux.W.EXITSTATUS(status) });
        } else if (linux.W.IFSIGNALED(status)) {
            print("dazzle-shell: client {d} killed by signal {d}\n", .{ rc, linux.W.TERMSIG(status) });
        }
    }
}

/// The process IDs of connected clients, for reading their DRM fdinfo.
fn clientPids(server: *const server_mod.Server, out: *[max_clients]linux.pid_t) []const linux.pid_t {
    var n: usize = 0;
    for (server.clients.items) |c| {
        const pid = c.pid orelse continue;
        if (n >= out.len) break;
        out[n] = pid;
        n += 1;
    }
    return out[0..n];
}

test {
    _ = @import("server.zig");
    _ = @import("server_test.zig");
    _ = @import("input.zig");
    _ = @import("companion.zig");
    _ = @import("cursor.zig");
    _ = @import("dock.zig");
    _ = @import("updates.zig");
    _ = @import("perf.zig");
    _ = @import("quick.zig");
    _ = @import("notice.zig");
    _ = @import("lock.zig");
    _ = @import("power.zig");
    _ = @import("osk.zig");
    _ = @import("gesture.zig");
    _ = @import("kete_panel.zig");
    _ = @import("remote.zig");
    _ = @import("glass.zig");
    _ = @import("screenshot.zig");
    _ = @import("keyboard.zig");
    _ = @import("protocol_test.zig");
    _ = @import("input_method/input_method.zig");
    _ = @import("input_method/conversion.zig");
    _ = @import("placement.zig");
    _ = @import("render.zig");
    _ = @import("background.zig");
    _ = @import("clock.zig");
}

test "a display plugged in or unplugged, from its uevent" {
    try std.testing.expect(isDrmHotplug("change@/devices/platform/gpu/drm/card1\x00ACTION=change\x00DEVPATH=/devices/platform/gpu/drm/card1\x00SUBSYSTEM=drm\x00HOTPLUG=1\x00DEVNAME=dri/card1\x00"));
    try std.testing.expect(!isDrmHotplug("add@/devices/x\x00ACTION=add\x00SUBSYSTEM=input\x00"));
    try std.testing.expect(!isDrmHotplug("change@/x\x00SUBSYSTEM=drm\x00"));
}
