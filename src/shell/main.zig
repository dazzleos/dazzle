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
const keyboard = @import("keyboard.zig");
const screenshot = @import("screenshot.zig");
const audio = @import("audio");
const build_info = @import("build_info");

const print = sys.print;

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    _ = level;
    print("dazzle-shell: " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ") ++ fmt ++ "\n", args);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-shell: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    // Run elsewhere (on Raspberry Pi OS), the socket goes where other
    // compositors' do.
    const runtime_dir = std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR");

    const dev = try vc4.device.open();
    const output = try vc4.drm.waitForOutput(dev.fd);
    var renderer = try render.Renderer.init(gpa, dev, output);
    print("dazzle-shell: build {s}, display {d}x{d}, {s}\n", .{
        build_info.commit,                                                                                                                                                                                                             renderer.width, renderer.height,
        if (renderer.display.kms) |k| (if (k.overlays[vc4.kms.max_overlays - 1] != null) "atomic mode setting with overlay planes" else "atomic mode setting, too few overlay planes") else "legacy mode setting (no direct scanout)",
    });

    var ui_font: ?font.Font = null;
    var emoji_font: ?font.Font = null;
    var font_buf: [512]u8 = undefined;
    const font_path = sys.fontFile(&font_buf, font.default_font_file);
    if (sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024)) |data| {
        if (font.Font.init(data)) |f| {
            ui_font = f;
        } else |err| print("dazzle-shell: font: {s}\n", .{@errorName(err)});
    } else |err| print(sys.log_warning ++ "dazzle-shell: cannot read {s}: {s}\n", .{ font_path, @errorName(err) });
    var emoji_buf: [512]u8 = undefined;
    const emoji_path = sys.fontFile(&emoji_buf, font.emoji_font_file);
    if (sys.readFileAlloc(gpa, emoji_path, 32 * 1024 * 1024)) |data| {
        if (font.Font.init(data)) |ef| emoji_font = ef else |_| {}
    } else |_| {}
    if (ui_font) |*f| if (emoji_font) |*ef| {
        f.fallback = ef;
    };

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
    var dock = try dock_mod.Dock.init(gpa, ui_font, apps, renderer.width, renderer.height);
    // The quick settings, over the status box when it is clicked: the
    // volume, the network, updates and powering off.
    var quick = try quick_mod.Quick.init(gpa, ui_font, dock.scale);
    // It needs drawing again (while shown).
    var quick_dirty = false;
    // The touch dragging its slider.
    var quick_touch: ?i32 = null;
    var audio_devices = audio.listDevices();
    // Notifications, at the top of the screen (a screenshot was saved).
    var notice = try notice_mod.Notice.init(gpa, ui_font, renderer.width, dock.scale);
    // Screenshots are saved on threads, which say how it went on this
    // pipe (`screenshot.Report`).
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
    updates.init(gpa, sys.nowNs());
    dock.updates = updates.available;
    const appearance = dock_mod.readAppearance();
    dock.theme = appearance.theme;
    // The background image, if any: made ready on a thread of its own.
    var background_image: background_mod.Loader = .init(gpa, renderer.width, renderer.height, dock.bandHeight());
    defer background_image.deinit();
    wantBackground(&background_image, &renderer, appearance);
    // The dock floats in a band along the bottom, which windows stay above;
    // on an overlay plane, the band is drawn whole, background and all.
    const band_y: u32 = renderer.height - dock.bandHeight();
    const with_dock: server_mod.Rect = .{ .x = 0, .y = 0, .width = renderer.width, .height = band_y };
    renderer.setPanelBand(.dock, @intCast(band_y));
    var perf = try perf_mod.Overlay.init(gpa, ui_font, renderer.width, renderer.height);
    var perf_monitor: perf_mod.Monitor = .{};
    var perf_shown = false;
    var shortcut_key: ?u32 = null;
    // Super is down, and nothing else has been pressed with it: let go, it
    // was tapped (which shows the overview, or ends it).
    var super_alone = false;
    var perf_frames: u32 = 0;
    var perf_gpu_ns: u64 = 0;
    renderer.setPanelHidden(.perf, true);
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
    server.setKeyboard(locale.load().keyboard);
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
    var pointer: Pointer = .{
        .x = @floatFromInt(renderer.width / 2),
        .y = @floatFromInt(renderer.height / 2),
        .max_x = @floatFromInt(renderer.width - 1),
        .max_y = @floatFromInt(renderer.height - 1),
    };
    server.pointer_x = pointer.x;
    server.pointer_y = pointer.y;
    var cursor_shown = false;

    const start = sys.nowNs();
    // A client buffer the display shows directly is held until a later
    // frame replaces it on the screen.
    var scanout: Scanout = .{};
    var next_tick: u64 = start;
    // The dock changed, and is waiting to be shown.
    var panels_damaged = true;
    // Print Screen was pressed: the screen is saved once input is handled.
    var screenshot_wanted = false;
    // Touches that went down on the dock (the shell's, not a window's).
    var dock_touches: TouchSet = .{};
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
            wantBackground(&background_image, &renderer, chosen);
            dock.draw();
            showDock(&renderer, &dock);
            server.setWorkArea(with_dock);
            panels_damaged = true;
        }

        // Wait for clients, input, the display (a page flip completing), or
        // the next clock tick; or not at all if a frame is due and can be
        // drawn.
        var fds: [7 + 2 * max_clients + input.max_devices]linux.pollfd = undefined;
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
        slideDock(&dock, &server, &renderer, dock_shown, now);
        animateNotice(&notice, &renderer, &server, now);
        var wake = next_tick;
        if (notice.wakeAt(now)) |due| wake = @min(wake, due);
        if (dock.tooltipDue()) |due| wake = @min(wake, due);
        if (!renderer.flipPending()) {
            if (server.damaged) wake = now;
            if (panels_damaged) wake = @min(wake, client_frame_ns + panel_grace_ns);
        }
        const timeout: i32 = if (wake > now) @intCast((wake - now) / std.time.ns_per_ms + 1) else 0;
        const opener_index = 2 + n_clients + n_inputs;
        const net_index = opener_index + 1;
        const sys_index = opener_index + 2;
        const watch_index = opener_index + 3;
        const shot_index = opener_index + 4;
        fds[opener_index] = .{ .fd = opener orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[net_index] = .{ .fd = net_sub.fd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[sys_index] = .{ .fd = sys_sub.fd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[watch_index] = .{ .fd = apps_watch.fd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        fds[shot_index] = .{ .fd = shot_pipe[0], .events = linux.POLL.IN, .revents = 0 };
        // The clients' processes, to notice one ending (crashing) while its
        // socket is still open elsewhere.
        const exits = fds[shot_index + 1 ..][0..n_clients];
        for (server.clients.items[0..n_clients], exits) |c, *f| f.* = .{ .fd = c.pidfd orelse -1, .events = linux.POLL.IN, .revents = 0 };
        _ = linux.poll(&fds, shot_index + 1 + n_clients, timeout);
        // A screenshot was saved (or could not be): the user is told.
        if (fds[shot_index].revents != 0) while (screenshot.Report.read(shot_pipe[0])) |r| {
            notice.theme = dock.theme;
            var body_buf: [300]u8 = undefined;
            if (r.saved) {
                notice.show(.photo_camera, "Screenshot saved", std.fmt.bufPrint(&body_buf, "Saved as \u{201c}{s}\u{201d} in your files", .{r.text()}) catch r.text(), sys.nowNs());
            } else notice.show(.warning, "Screenshot not saved", r.text(), sys.nowNs());
            server.damaged = true;
        };
        // What changed in /data/apps, or all of it if it has just appeared
        // (/data was made ready: the system manager reports it).
        var apps_changes = apps_pending;
        apps_pending = .{};
        if (fds[opener_index].revents != 0) if (opener) |l| {
            if (openApp(l, apps, &server, runtime_dir) and dock_shown) {
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
                if (r.locale.keyboard != server.keyboard_layout) {
                    print("dazzle-shell: keyboard {s}\n", .{r.locale.keyboard.code()});
                    server.setKeyboard(r.locale.keyboard);
                }
                if (updates.setReport(r)) updates_changed = true;
            };
            if (apps_watch.retry()) apps_changes = .all;
        }
        if (fds[watch_index].revents != 0) {
            const c = apps_watch.take();
            apps_changes.apps = apps_changes.apps or c.apps;
            apps_changes.sound = apps_changes.sound or c.sound;
            apps_changes.appearance = apps_changes.appearance or c.appearance;
            apps_changes.catalogue = apps_changes.catalogue or c.catalogue;
        }
        // Settings fetched the catalogue, or installed or removed apps.
        if ((apps_changes.apps or apps_changes.catalogue) and updates.reload()) updates_changed = true;
        if (apps_changes.apps) {
            if (dock_mod.rescan(gpa, apps, dock_mod.apps_dir, &builtin_apps)) |new| {
                apps = new;
                dock.apps = new;
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
        if (fds[1].revents != 0) {
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
        const dock_visible = dock_shown and !server.fullscreenTop();
        for (fds[2 + n_clients ..][0..n_inputs]) |f| if (f.revents != 0) {
            var events: [64]input.Event = undefined;
            for (devices.read(f.fd, &events)) |e| {
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
                                renderer.setPanelAt(.perf, perf.picture(), perf.width, perf.height, perf.x, perf.y);
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
                    const x = t.x * @as(f64, @floatFromInt(renderer.width - 1));
                    const y = t.y * @as(f64, @floatFromInt(renderer.height - 1));
                    const on_dock = dock_visible and dock.local(x, y) != null;
                    switch (t.kind) {
                        .down => if (quick.local(x, y)) |at| {
                            // On the quick settings: pressed there, and
                            // the slider dragged along.
                            dock_touches.set(t.id);
                            const action = quick.press(at[0], at[1]);
                            if (quick.dragging) quick_touch = t.id;
                            quickAction(action, &quick, &dock, &renderer, apps, &server, runtime_dir, &audio_devices, &quick_dirty);
                        } else if (quick.shown and !(on_dock and dock.hitStatus((dock.local(x, y) orelse continue)[0], dock.local(x, y).?[1]))) {
                            // Elsewhere, it closes (the status box toggles
                            // it, below), and that is all the touch does.
                            dock_touches.set(t.id);
                            quick.close();
                            panels_damaged = true;
                        } else if (on_dock) {
                            dock_touches.set(t.id);
                            dock_tap = .{ x, y };
                        } else if (server.overview) {
                            // The shell's: it picks a window, or ends the
                            // overview.
                            dock_touches.set(t.id);
                            if (server.overviewAt(x, y)) |win| server.overviewPick(win) else server.setOverview(false);
                        } else server.touchDown(time_ms, t.id, x, y),
                        .motion => if (quick_touch == t.id) {
                            if (quick.drag(x - @as(f64, @floatFromInt(quick.x)))) |v| setVolume(v, false, &quick, &dock, &renderer, &audio_devices, &quick_dirty);
                        } else if (!dock_touches.has(t.id)) server.touchMotion(time_ms, t.id, x, y),
                        .up => {
                            if (quick_touch == t.id) {
                                quick_touch = null;
                                if (quick.release()) setVolume(quick.volume, true, &quick, &dock, &renderer, &audio_devices, &quick_dirty);
                            }
                            if (!dock_touches.unset(t.id)) server.touchUp(time_ms, t.id);
                        },
                    }
                    if (dock_tap == null) continue;
                }
                if (e == .button) pointer.flushMotion(&server, time_ms);
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
                        quickAction(quick.press(at[0], at[1]), &quick, &dock, &renderer, apps, &server, runtime_dir, &audio_devices, &quick_dirty);
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
        };
        // The background image, once it is ready (or gone).
        if (background_image.poll()) |outcome| {
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
            renderer.setPanelAt(.tooltip, tip.pixels, tip.width, tip.height, tip.x, tip.y);
            panels_damaged = true;
        }

        if (screenshot_wanted) {
            screenshot_wanted = false;
            var windows: [render.max_windows]render.Window = undefined;
            if (renderer.capture(gpa, frameWindows(&server, &windows))) |pixels| {
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
        if (apps_changes.appearance) {
            const chosen = dock_mod.readAppearance();
            if (chosen.theme != dock.theme) {
                dock.theme = chosen.theme;
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
            next_tick = start + ((t_now - start) / std.time.ns_per_s + 1) * std.time.ns_per_s;
            // Keyboards and mice plugged in since.
            devices.scan();
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
                    if (r.locale.keyboard != server.keyboard_layout) {
                        print("dazzle-shell: keyboard {s}\n", .{r.locale.keyboard.code()});
                        server.setKeyboard(r.locale.keyboard);
                    }
                    if (updates.setReport(r)) updates_changed = true;
                };
                if (apps_watch.retry()) apps_pending = .all;
            }
            // The daily check for updates, when it is due.
            if (updates.tick(t_now)) updates_changed = true;
            if (perf_shown) {
                var pids: [max_clients]linux.pid_t = undefined;
                perf.draw(perf_monitor.sample(t_now, perf_frames, perf_gpu_ns, clientPids(&server, &pids)), dock.theme);
                perf_frames = 0;
                perf_gpu_ns = 0;
                renderer.setPanelAt(.perf, perf.picture(), perf.width, perf.height, perf.x, perf.y);
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
            renderer.setPanelAt(.quick, quick.picture(), quick.width, quick.height, quick.x, quick.y);
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
            slideDock(&dock, &server, &renderer, dock_shown, sys.nowNs());
            animateNotice(&notice, &renderer, &server, sys.nowNs());
        }
        const dock_due = panels_damaged and sys.nowNs() >= client_frame_ns + panel_grace_ns;
        if ((server.damaged or dock_due) and !renderer.flipPending()) {
            const count_frame = server.damaged;
            panels_damaged = false;
            server.frameDrawn();
            // A fullscreen window on top sends the dock down, off the
            // screen; its tooltip goes at once.
            renderer.setPanelHidden(.dock, !dock_shown or dock.offScreen());
            renderer.setPanelHidden(.tooltip, !dock_shown or server.fullscreenTop() or dock.slide > 0 or dock.tooltip_shown == null);
            renderer.setPanelHidden(.perf, !perf_shown);
            renderer.setPanelHidden(.quick, !quick.shown);
            renderer.setPanelHidden(.notice, !notice.visible(sys.nowNs()));
            // A maximized, full-size window on top goes straight onto the
            // display, with the dock on a plane below it; a fullscreen one,
            // alone. Otherwise (or if the display cannot show it) the frame
            // is composited.
            var on_screen: ?bool = null;
            // Not while the dock slides: it would leave its band.
            if (top) |t| if (!dock.sliding()) if (server.scanoutBuffer(t)) |b| {
                const at = server.windowRect(t);
                if (renderer.showDirect(b.dmabuf.?, at.x, at.y)) |at_once| {
                    server.holdBuffer(b);
                    scanout.queued = b;
                    if (count_frame) perf_frames += 1;
                    on_screen = at_once;
                }
            };
            if (on_screen == null) {
                var windows: [render.max_windows]render.Window = undefined;
                if (renderer.composite(frameWindows(&server, &windows))) |timing| {
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
                if (renderer.showCursor(.arrow)) {
                    renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
                    print("dazzle-shell: cursor shown\n", .{});
                } else |err| print(sys.log_warning ++ "dazzle-shell: no cursor: {s}\n", .{@errorName(err)});
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

/// An app asks for another to be opened (see `sys.shell`): one running is
/// raised, and told what to show; another is started, with it as its
/// argument. Returns whether an app was started.
fn openApp(listener: linux.fd_t, apps: []dock_mod.App, server: *server_mod.Server, runtime_dir: ?[:0]const u8) bool {
    var buf: [160]u8 = undefined;
    const got = sys.shell.accept(listener, &buf) orelse return false;
    defer sys.close(got.fd);
    const req = sys.shell.Request.parse(got.line) orelse {
        _ = linux.write(got.fd, "unknown\n", 8);
        return false;
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
    loader.want(path, if (path != null) renderer.backgroundKind() else .rgb565);
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
        .power_off => {
            print("dazzle-shell: powering off\n", .{});
            if (sys.system.ask("power_off\n", 3000) == null) print(sys.log_warning ++ "dazzle-shell: cannot power off: the system did not answer\n", .{});
            quick.power_armed = false;
            quick_dirty.* = true;
        },
    }
}

/// Where the dock's box is on the screen.
fn dockArea(dock: *const dock_mod.Dock) server_mod.Rect {
    const at = dock.place();
    return .{ .x = at.x, .y = at.y, .width = dock.width, .height = dock.height };
}

/// Gives the renderer the dock's latest picture, where it is.
fn showDock(renderer: *render.Renderer, dock: *const dock_mod.Dock) void {
    const at = dock.place();
    renderer.setPanelAt(.dock, dock.picture(), dock.width, dock.height, at.x, at.y);
}

/// Fades the notification in or out, a frame each refresh while it does;
/// and a frame more when it has gone.
fn animateNotice(notice: *notice_mod.Notice, renderer: *render.Renderer, server: *server_mod.Server, now: u64) void {
    const was_shown = notice.shown_ns != null;
    if (notice.frame(now)) |pixels| {
        const at = notice.place();
        renderer.setPanelAt(.notice, pixels, notice.width, notice.height, at[0], at[1]);
        server.damaged = true;
    } else if (was_shown and notice.shown_ns == null) server.damaged = true;
}

/// Sends the dock down while a fullscreen window is on top, and back up
/// after, a frame each refresh while it is on its way.
fn slideDock(dock: *dock_mod.Dock, server: *server_mod.Server, renderer: *render.Renderer, dock_shown: bool, now: u64) void {
    if (dock_shown) dock.slideTo(server.fullscreenTop(), now);
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
    _ = @import("cursor.zig");
    _ = @import("dock.zig");
    _ = @import("updates.zig");
    _ = @import("perf.zig");
    _ = @import("quick.zig");
    _ = @import("notice.zig");
    _ = @import("glass.zig");
    _ = @import("screenshot.zig");
    _ = @import("keyboard.zig");
    _ = @import("protocol_test.zig");
    _ = @import("placement.zig");
    _ = @import("render.zig");
    _ = @import("background.zig");
}
