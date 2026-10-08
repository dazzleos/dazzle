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
const locale = @import("locale");
const vc4 = @import("vc4");
const font = @import("font");
const wayland = @import("wayland");
const server_mod = @import("server.zig");
const render = @import("render.zig");
const input = @import("input.zig");
const dock_mod = @import("dock.zig");
const screenshot = @import("screenshot.zig");
const build_info = @import("build_info");

const print = sys.print;

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    _ = level;
    print("dazzle-shell: " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ") ++ fmt ++ "\n", args);
}

/// The mouse's left button.
const btn_left = 0x110;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print("dazzle-shell: error: {s}\n", .{@errorName(err)});
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
    var font_buf: [512]u8 = undefined;
    const font_path = sys.fontFile(&font_buf, font.default_font_file);
    if (sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024)) |data| {
        if (font.Font.init(data)) |f| {
            ui_font = f;
        } else |err| print("dazzle-shell: font: {s}\n", .{@errorName(err)});
    } else |err| print("dazzle-shell: cannot read {s}: {s}\n", .{ font_path, @errorName(err) });

    // The shell's own apps are beside it; the others are in /data/apps.
    var settings_buf: [512]u8 = undefined;
    const settings_path = try sys.appFile(&settings_buf, "dazzle-settings");
    const builtin_apps = [_][]const u8{settings_path};
    var apps = try dock_mod.findApps(gpa, dock_mod.apps_dir, &builtin_apps);
    // Apps installed or removed (from Settings) come and go from the dock.
    var apps_watch: dock_mod.Watch = .{ .path = dock_mod.apps_dir };
    _ = apps_watch.changed();
    // The keyboard's layout, as chosen (in setup or Settings): the clients
    // are sent its keymap, again when it changes.
    var locale_watch: dock_mod.Watch = .{ .path = locale.settings_file };
    _ = locale_watch.changed();
    for (apps) |app| print("dazzle-shell: app {s} ({s})\n", .{ app.label, app.path });
    var dock = try dock_mod.Dock.init(gpa, ui_font, apps, renderer.width, renderer.height);
    const dock_y: u32 = renderer.height - dock.height;
    const with_dock: server_mod.Rect = .{ .x = 0, .y = 0, .width = renderer.width, .height = dock_y };

    // On the first run (--setup), the setup app has the whole screen, and
    // the dock shows once it has finished.
    var args = init.args.iterate();
    _ = args.skip();
    var setup_pid: ?linux.pid_t = null;
    var setup_args = args;
    while (setup_args.next()) |arg| if (std.mem.eql(u8, arg, "--setup")) {
        var setup_buf: [512]u8 = undefined;
        setup_pid = spawn(try sys.appFile(&setup_buf, "dazzle-setup"), null, runtime_dir);
    };
    var dock_shown = setup_pid == null;
    if (dock_shown) {
        dock.draw();
        renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
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
    const path = if (runtime_dir) |dir| try std.fmt.bufPrintZ(&path_buf, "{s}/wayland-0", .{dir}) else wayland.client.default_socket;
    const listener = try listen(path);
    print("dazzle-shell: listening on {s}\n", .{path});

    // Start the clients named on the command line.
    while (args.next()) |client| if (!std.mem.eql(u8, client, "--setup")) {
        _ = spawn(client, null, runtime_dir);
    };
    // Apps asking for another app to be opened.
    const opener: ?linux.fd_t = if (runtime_dir == null) sys.shell.listen(sys.shell.socket_path) catch |err| blk: {
        print("dazzle-shell: cannot listen on {s}: {s}\n", .{ sys.shell.socket_path, @errorName(err) });
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
    var stats: FrameStats = .{ .since = start, .period_us = renderer.display.refreshPeriodUs() };
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
    watchChildren();
    while (true) {
        if (child_exited.swap(false, .monotonic) and reapChildren(apps, &setup_pid) and dock_shown) {
            dock.draw();
            renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
            panels_damaged = true;
        }
        // Setup has finished (or stopped): the dock comes.
        if (!dock_shown and setup_pid == null) {
            dock_shown = true;
            print("dazzle-shell: setup finished\n", .{});
            dock.draw();
            renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
            server.setWorkArea(with_dock);
            panels_damaged = true;
        }
        stats.wakeups += 1;

        // Wait for clients, input, the display (a page flip completing), or
        // the next clock tick; or not at all if a frame is due and can be
        // drawn.
        var fds: [3 + max_clients + input.max_devices]linux.pollfd = undefined;
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = renderer.dev.fd, .events = linux.POLL.IN, .revents = 0 };
        const n_clients = @min(server.clients.items.len, max_clients);
        for (server.clients.items[0..n_clients], 2..) |c, i| fds[i] = .{ .fd = c.conn.fd, .events = linux.POLL.IN, .revents = 0 };
        const n_inputs = devices.pollFds(fds[2 + n_clients ..]);
        const now = sys.nowNs();
        var wake = next_tick;
        if (!renderer.flipPending()) {
            if (server.damaged) wake = now;
            if (panels_damaged) wake = @min(wake, client_frame_ns + panel_grace_ns);
        }
        const timeout: i32 = if (wake > now) @intCast((wake - now) / std.time.ns_per_ms + 1) else 0;
        const opener_index = 2 + n_clients + n_inputs;
        fds[opener_index] = .{ .fd = opener orelse -1, .events = linux.POLL.IN, .revents = 0 };
        _ = linux.poll(&fds, opener_index + 1, timeout);
        if (fds[opener_index].revents != 0) if (opener) |l| {
            if (openApp(l, apps, &server, runtime_dir) and dock_shown) {
                dock.draw();
                renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
                panels_damaged = true;
            }
        };
        const work_start = sys.nowNs();

        // The last frame reached the screen: its frame callbacks fire, and
        // the next one can be drawn.
        if (fds[1].revents != 0) {
            const flip_start = sys.nowNs();
            defer stats.flips_ns += sys.nowNs() - flip_start;
            if (renderer.handleEvents() catch |err| blk: {
                print("dazzle-shell: display events: {s}\n", .{@errorName(err)});
                break :blk null;
            }) |vblank_us| {
                stats.flipped(vblank_us);
                scanout.presented(&server);
                server.framePresented(@truncate(vblank_us / std.time.us_per_ms));
            }
        }

        const time_ms: u32 = @truncate((sys.nowNs() - start) / std.time.ns_per_ms);
        for (fds[2 + n_clients ..][0..n_inputs]) |f| if (f.revents != 0) {
            var events: [64]input.Event = undefined;
            for (devices.read(f.fd, &events)) |e| {
                // Print Screen is the shell's: it saves the screen.
                if (e == .key and e.key.code == screenshot.key_print) {
                    if (e.key.pressed) screenshot_wanted = true;
                    continue;
                }
                // Touches go to the window they go down on, but those on
                // the dock are the shell's (a tap there is a click).
                var dock_tap: ?[2]f64 = null;
                if (e == .touch) {
                    const t = e.touch;
                    const x = t.x * @as(f64, @floatFromInt(renderer.width - 1));
                    const y = t.y * @as(f64, @floatFromInt(renderer.height - 1));
                    const on_dock = dock_shown and y >= @as(f64, @floatFromInt(dock_y));
                    switch (t.kind) {
                        .down => if (on_dock) {
                            dock_touches.set(t.id);
                            dock_tap = .{ x, y };
                        } else server.touchDown(time_ms, t.id, x, y),
                        .motion => if (!dock_touches.has(t.id)) server.touchMotion(time_ms, t.id, x, y),
                        .up => if (!dock_touches.unset(t.id)) server.touchUp(time_ms, t.id),
                    }
                    if (dock_tap == null) continue;
                }
                // Buttons over the dock are the shell's.
                if (dock_tap != null or (dock_shown and e == .button and pointer.y >= @as(f64, @floatFromInt(dock_y)))) {
                    if (dock_tap == null) {
                        pointer.flushMotion(&server, time_ms);
                        if (!e.button.pressed or e.button.code != btn_left) continue;
                    }
                    const at = dock_tap orelse [2]f64{ pointer.x, pointer.y };
                    const i = dock.hit(at[0], at[1] - @as(f64, @floatFromInt(dock_y))) orelse continue;
                    const app = &apps[i];
                    if (app.pid) |pid| {
                        if (!server.raise(pid)) print("dazzle-shell: {s} has no window yet\n", .{app.label});
                    } else {
                        app.pid = spawn(app.path, null, runtime_dir);
                        dock.draw();
                        renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
                        panels_damaged = true;
                    }
                    continue;
                }
                pointer.handle(&server, time_ms, e);
                if (e == .frame) server.touchFrame();
            }
            if (pointer.moved) {
                pointer.moved = false;
                renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
                const in_dock = dock_shown and pointer.y >= @as(f64, @floatFromInt(dock_y));
                if (dock.pointerAt(if (in_dock) pointer.x else null, pointer.y - @as(f64, @floatFromInt(dock_y)))) {
                    dock.draw();
                    renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
                    panels_damaged = true;
                }
            }
        };

        if (screenshot_wanted) {
            screenshot_wanted = false;
            var windows: [render.max_windows]render.Window = undefined;
            if (renderer.capture(gpa, frameWindows(&server, &windows))) |pixels| {
                screenshot.save(gpa, screenshot.folder, pixels, renderer.width, renderer.height);
            } else |err| print("dazzle-shell: cannot take a screenshot: {s}\n", .{@errorName(err)});
        }

        if (fds[0].revents != 0) {
            const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) == .SUCCESS) {
                _ = try server.addClient(@intCast(rc));
                print("dazzle-shell: client connected\n", .{});
            }
        }
        // Clients may disconnect (and leave the list) while being handled.
        const clients_start = sys.nowNs();
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

        if (server.damaged) client_frame_ns = sys.nowNs();
        stats.clients_ns += sys.nowNs() - clients_start;

        // The window under the pointer, and the one with the keyboard, may
        // have changed.
        server.updateFocus();

        const top = server.topWindow();
        const t_now = sys.nowNs();
        if (t_now >= next_tick) {
            next_tick = start + ((t_now - start) / std.time.ns_per_s + 1) * std.time.ns_per_s;
            // Keyboards and mice plugged in since.
            devices.scan();
            if (locale_watch.changed()) {
                const chosen = locale.load();
                print("dazzle-shell: keyboard {s}\n", .{chosen.keyboard.code()});
                server.setKeyboard(chosen.keyboard);
            }
            if (apps_watch.changed()) {
                if (dock_mod.rescan(gpa, apps, dock_mod.apps_dir, &builtin_apps)) |new| {
                    apps = new;
                    dock.apps = new;
                    dock.hover = null;
                    print("dazzle-shell: {d} apps\n", .{new.len});
                    if (dock_shown) {
                        dock.draw();
                        renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
                        panels_damaged = true;
                    }
                } else |err| print("dazzle-shell: cannot list the apps: {s}\n", .{@errorName(err)});
            }
        }

        // Draw while the previous frame is on the screen; it is shown at
        // the next vertical blank, without waiting here. A change to the
        // dock alone waits for a while if a client is animating, and goes
        // out with its next frame: otherwise it would take the next
        // vertical blank, and the client's frame would be shown a refresh
        // late.
        const dock_due = panels_damaged and sys.nowNs() >= client_frame_ns + panel_grace_ns;
        if ((server.damaged or dock_due) and !renderer.flipPending()) {
            const draw_start = sys.nowNs();
            defer stats.display_ns += sys.nowNs() - draw_start;
            panels_damaged = false;
            server.frameDrawn();
            // A maximized, full-size window on top goes straight onto the
            // display, with the dock on a plane below it. Otherwise (or if
            // the display cannot show it) the frame is composited.
            var on_screen: ?bool = null;
            if (top) |t| if (server.scanoutBuffer(t)) |b| {
                if (renderer.showDirect(b.dmabuf.?, server.work_area.x, server.work_area.y)) |at_once| {
                    server.holdBuffer(b);
                    scanout.queued = b;
                    stats.direct += 1;
                    on_screen = at_once;
                }
            };
            if (on_screen == null) {
                var windows: [render.max_windows]render.Window = undefined;
                if (renderer.composite(frameWindows(&server, &windows))) |timing| {
                    stats.composited(timing);
                    on_screen = renderer.show() catch |err| blk: {
                        print("dazzle-shell: cannot show the frame: {s}\n", .{@errorName(err)});
                        server.framePresented(@truncate(sys.nowNs() / std.time.ns_per_ms));
                        break :blk false;
                    };
                } else |err| {
                    // Nothing new reaches the screen, but the clients should
                    // not wait for it.
                    print("dazzle-shell: frame failed: {s}\n", .{@errorName(err)});
                    server.framePresented(@truncate(sys.nowNs() / std.time.ns_per_ms));
                    on_screen = false;
                }
            }
            if (on_screen.?) {
                scanout.presented(&server);
                server.framePresented(@truncate(sys.nowNs() / std.time.ns_per_ms));
            }
            // The cursor plane needs the mode the first frame set.
            if (!cursor_shown) {
                cursor_shown = true;
                if (renderer.showCursor(.arrow)) {
                    renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
                    print("dazzle-shell: cursor shown\n", .{});
                } else |err| print("dazzle-shell: no cursor: {s}\n", .{@errorName(err)});
            }
        }
        // The pointer's picture: a resize while one is under way, or what
        // the window under it chose.
        if (renderer.cursor_shape) |shown| if (server.cursor() != shown) {
            if (renderer.showCursor(server.cursor())) {
                renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
            } else |err| print("dazzle-shell: cannot change the cursor: {s}\n", .{@errorName(err)});
        };
        server.flushClients();
        const work_end = sys.nowNs();
        stats.work_ns += work_end - work_start;
        if (renderer.display.kms) |*k| {
            stats.commit_ns += k.commit_ns;
            k.commit_ns = 0;
        }
        stats.maybeLog(work_end);
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

/// Frame statistics, logged every 5 seconds while frames are drawn.
const FrameStats = struct {
    since: u64,
    period_us: u64,
    /// Frames composited by the GPU, and shown directly.
    frames: u32 = 0,
    direct: u32 = 0,
    /// The shell's own work (not waiting): in all, handling clients'
    /// requests, and drawing or showing frames.
    work_ns: u64 = 0,
    clients_ns: u64 = 0,
    display_ns: u64 = 0,
    /// Handling page flips: frame callbacks and buffer releases.
    flips_ns: u64 = 0,
    /// Times round the main loop.
    wakeups: u32 = 0,
    /// Of `display_ns`, the display commit system calls (kernel time).
    commit_ns: u64 = 0,
    cpu_ns: u64 = 0,
    gpu_ns: u64 = 0,
    /// Vertical blanks without a new frame between two flips. While a
    /// client animates, these are frames it (or the shell) missed.
    skipped: u64 = 0,
    last_flip_us: u64 = 0,

    fn composited(s: *FrameStats, t: render.Renderer.Timing) void {
        s.frames += 1;
        s.cpu_ns += t.cpu_ns;
        s.gpu_ns += t.gpu_ns;
    }

    fn flipped(s: *FrameStats, vblank_us: u64) void {
        if (s.last_flip_us != 0 and vblank_us > s.last_flip_us) {
            // Rounded to whole refreshes.
            const refreshes = (vblank_us - s.last_flip_us + s.period_us / 2) / s.period_us;
            if (refreshes > 1) s.skipped += refreshes - 1;
        }
        s.last_flip_us = vblank_us;
    }

    fn maybeLog(s: *FrameStats, now: u64) void {
        const elapsed = now - s.since;
        if (elapsed < 5 * std.time.ns_per_s) return;
        const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
        const ms: f64 = std.time.ns_per_ms;
        if (s.frames > 0) {
            const n: f64 = @floatFromInt(s.frames);
            print("dazzle-shell: {d:.1} frames/s composited (CPU {d:.2} ms, GPU {d:.2} ms per frame), {d:.1} frames/s direct, {d} refreshes skipped\n", .{
                n / seconds,
                @as(f64, @floatFromInt(s.cpu_ns)) / n / ms,
                @as(f64, @floatFromInt(s.gpu_ns)) / n / ms,
                @as(f64, @floatFromInt(s.direct)) / seconds,
                s.skipped,
            });
        } else if (s.direct > 0) {
            print("dazzle-shell: {d:.1} frames/s, all shown directly, {d} refreshes skipped\n", .{ @as(f64, @floatFromInt(s.direct)) / seconds, s.skipped });
        }
        const shown = s.frames + s.direct;
        if (shown > 0) {
            const n: f64 = @floatFromInt(shown);
            const other = s.work_ns -| (s.clients_ns + s.display_ns + s.flips_ns);
            print("dazzle-shell: work {d:.2} ms per frame (clients {d:.2}, display {d:.2} of which commits {d:.2}, flips {d:.2}, other {d:.2}), {d:.1} wakeups per frame, {d:.1}% of the time\n", .{
                @as(f64, @floatFromInt(s.work_ns)) / n / ms,
                @as(f64, @floatFromInt(s.clients_ns)) / n / ms,
                @as(f64, @floatFromInt(s.display_ns)) / n / ms,
                @as(f64, @floatFromInt(s.commit_ns)) / n / ms,
                @as(f64, @floatFromInt(s.flips_ns)) / n / ms,
                @as(f64, @floatFromInt(other)) / n / ms,
                @as(f64, @floatFromInt(s.wakeups)) / n,
                100 * @as(f64, @floatFromInt(s.work_ns)) / @as(f64, @floatFromInt(elapsed)),
            });
        }
        s.* = .{ .since = now, .period_us = s.period_us, .last_flip_us = s.last_flip_us };
    }
};

const max_clients = 32;

/// The pointer: input events move it and go to the server.
const Pointer = struct {
    x: f64,
    y: f64,
    max_x: f64,
    max_y: f64,
    /// Motion not sent to the server yet.
    pending_motion: bool = false,
    /// Pointer events since the last frame.
    in_frame: bool = false,
    /// Moved since the cursor was last moved.
    moved: bool = false,

    fn handle(ptr: *Pointer, server: *server_mod.Server, time_ms: u32, e: input.Event) void {
        switch (e) {
            .motion => |d| {
                ptr.x = std.math.clamp(ptr.x + @as(f64, @floatFromInt(d[0])), 0, ptr.max_x);
                ptr.y = std.math.clamp(ptr.y + @as(f64, @floatFromInt(d[1])), 0, ptr.max_y);
                ptr.pending_motion = true;
                ptr.moved = true;
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
            .key => |k| server.keyboardKey(time_ms, k.code, k.pressed),
            // Touches are handled before.
            .touch => {},
            .frame => {
                ptr.flushMotion(server, time_ms);
                if (ptr.in_frame) server.pointerFrame();
                ptr.in_frame = false;
            },
        }
    }

    /// X and Y motion arrive as separate events; they become one.
    fn flushMotion(ptr: *Pointer, server: *server_mod.Server, time_ms: u32) void {
        if (!ptr.pending_motion) return;
        ptr.pending_motion = false;
        server.pointerMotion(time_ms, ptr.x, ptr.y);
        ptr.in_frame = true;
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
    if (app.pid) |pid| {
        _ = server.raise(pid);
        if (req.what) |what| {
            var path_buf: [96]u8 = undefined;
            var line_buf: [80]u8 = undefined;
            var none: [0]u8 = .{};
            if (sys.shell.appSocket(&path_buf, app.name)) |path| {
                const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{what}) catch return false;
                _ = sys.shell.send(path, line, &none);
            }
        }
        return false;
    }
    var arg_buf: [80]u8 = undefined;
    const arg: ?[*:0]const u8 = if (req.what) |w| (std.fmt.bufPrintZ(&arg_buf, "{s}", .{w}) catch return false).ptr else null;
    print("dazzle-shell: opening {s}{s}{s}\n", .{ app.name, if (req.what != null) " at " else "", req.what orelse "" });
    app.pid = spawn(app.path, arg, runtime_dir);
    return true;
}

/// Starts a client program. Dazzle's apps find the shell on
/// /os/sockets/wayland-0;
/// with a runtime directory (run elsewhere) they are told where it is.
fn spawn(program: [*:0]const u8, arg: ?[*:0]const u8, runtime_dir: ?[:0]const u8) ?linux.pid_t {
    var env_buf: [160]u8 = undefined;
    const runtime_env: ?[*:0]const u8 = if (runtime_dir) |dir| (std.fmt.bufPrintZ(&env_buf, "XDG_RUNTIME_DIR={s}", .{dir}) catch return null).ptr else null;
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        print("dazzle-shell: cannot start {s}: fork failed\n", .{program});
        return null;
    }
    if (rc != 0) {
        print("dazzle-shell: started {s} (pid {d})\n", .{ program, rc });
        return @intCast(rc);
    }
    const argv = [_:null]?[*:0]const u8{ program, arg };
    const envp = if (runtime_env) |r| [_:null]?[*:0]const u8{ "HOME=/", "WAYLAND_DISPLAY=wayland-0", r } else [_:null]?[*:0]const u8{ "HOME=/", null, null };
    const err = linux.errno(linux.execve(program, &argv, &envp));
    print("dazzle-shell: cannot run {s} ({s})\n", .{ program, @tagName(err) });
    linux.exit(127);
}

/// The surfaces that can be seen (windows, their subsurfaces and popups),
/// bottom first, as the renderer draws them.
fn frameWindows(server: *server_mod.Server, out: *[render.max_windows]render.Window) []const render.Window {
    var quads: [render.max_windows]server_mod.Server.Quad = undefined;
    const list = server.drawList(&quads);
    for (list, out[0..list.len]) |q, *w| w.* = .{ .texture = q.texture, .x = q.x, .y = q.y, .clip = q.clip };
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
        const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
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

test {
    _ = @import("server.zig");
    _ = @import("server_test.zig");
    _ = @import("input.zig");
    _ = @import("cursor.zig");
    _ = @import("dock.zig");
    _ = @import("screenshot.zig");
    _ = @import("keyboard.zig");
    _ = @import("protocol_test.zig");
    _ = @import("placement.zig");
}
