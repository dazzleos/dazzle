//! stardust-shell: a minimal Wayland compositor and shell.
//!
//! It owns the display (as the DRM master) and draws with the low-level vc4
//! API: a bar across the top (the window title and the time since boot), a
//! dock along the bottom with an icon for each app in /apps (see dock.zig),
//! and the front window, maximized between them. USB mice move a cursor
//! (on the display's cursor plane) and, with USB keyboards, give input to
//! that window. Clicking an app in the dock starts it, or brings its window
//! to the front if it is running: apps run once each.
//!
//! Clients connect on $XDG_RUNTIME_DIR/wayland-0. The shell starts no app
//! itself, other than the programs named on its command line. It is not an
//! app: it lives in /shell, with its font.
//!
//! Init starts it as the unprivileged Stardust user, with stdout and stderr
//! going to the kernel log.
//!
//!     stardust-shell [client ...]

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");
const font = @import("font");
const server_mod = @import("server.zig");
const render = @import("render.zig");
const input = @import("input.zig");
const dock_mod = @import("dock.zig");
const build_info = @import("build_info");

const print = sys.print;

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    _ = level;
    print("stardust-shell: " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ") ++ fmt ++ "\n", args);
}

/// The mouse's left button.
const btn_left = 0x110;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print("stardust-shell: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    const runtime_dir = std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR") orelse {
        print("stardust-shell: XDG_RUNTIME_DIR is not set\n", .{});
        return error.NoRuntimeDir;
    };

    const dev = try vc4.device.open();
    const output = try vc4.drm.waitForOutput(dev.fd);
    var renderer = try render.Renderer.init(gpa, dev, output);
    print("stardust-shell: build {s}, display {d}x{d}, {s}\n", .{
        build_info.commit, renderer.width, renderer.height,
        if (renderer.display.kms) |k| (if (k.overlays[vc4.kms.max_overlays - 1] != null) "atomic mode setting with overlay planes" else "atomic mode setting, too few overlay planes") else "legacy mode setting (no direct scanout)",
    });

    var bar: ?render.Bar = null;
    var ui_font: ?font.Font = null;
    var font_buf: [512]u8 = undefined;
    const font_path = try sys.appFile(&font_buf, font.default_font_file);
    if (sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024)) |data| {
        if (font.Font.init(data)) |f| {
            ui_font = f;
            bar = try render.Bar.init(gpa, f, renderer.width, renderer.height);
        } else |err| print("stardust-shell: font: {s}\n", .{@errorName(err)});
    } else |err| print("stardust-shell: cannot read {s}: {s}\n", .{ font_path, @errorName(err) });
    const bar_height: u32 = if (bar) |b| b.height else 0;

    const apps = try dock_mod.findApps(gpa, dock_mod.apps_dir);
    for (apps) |app| print("stardust-shell: app {s} ({s})\n", .{ app.label, app.path });
    var dock = try dock_mod.Dock.init(gpa, ui_font, apps, renderer.width, renderer.height);
    const dock_y: u32 = renderer.height - dock.height;
    dock.draw();
    renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));

    var server = server_mod.Server.init(gpa, renderer.backend(), .{
        .x = 0,
        .y = @intCast(bar_height),
        .width = renderer.width,
        .height = dock_y - bar_height,
    });

    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/wayland-0", .{runtime_dir});
    const listener = try listen(path);
    print("stardust-shell: listening on {s}\n", .{path});

    // Start the clients named on the command line.
    var args = init.args.iterate();
    _ = args.skip();
    while (args.next()) |client| _ = spawn(client, runtime_dir);

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
    var last_title: [64]u8 = undefined;
    var last_title_len: usize = 0;
    // The bar or the dock changed, and is waiting to be shown.
    var panels_damaged = true;
    // When a client last had a frame for the screen.
    var client_frame_ns: u64 = 0;
    watchChildren();
    while (true) {
        if (child_exited.swap(false, .monotonic) and reapChildren(apps)) {
            dock.draw();
            renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
            panels_damaged = true;
        }
        stats.wakeups += 1;

        // Wait for clients, input, the display (a page flip completing), or
        // the next clock tick; or not at all if a frame is due and can be
        // drawn.
        var fds: [2 + max_clients + input.max_devices]linux.pollfd = undefined;
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = renderer.dev.fd, .events = linux.POLL.IN, .revents = 0 };
        const n_clients = @min(server.clients.items.len, max_clients);
        for (server.clients.items[0..n_clients], 2..) |c, i| fds[i] = .{ .fd = c.conn.fd, .events = linux.POLL.IN, .revents = 0 };
        const n_inputs = devices.pollFds(fds[2 + n_clients ..]);
        const now = sys.nowNs();
        var wake = next_tick;
        if (!renderer.flipPending()) {
            if (server.damaged) wake = now;
            if (panels_damaged) wake = @min(wake, client_frame_ns + bar_grace_ns);
        }
        const timeout: i32 = if (wake > now) @intCast((wake - now) / std.time.ns_per_ms + 1) else 0;
        _ = linux.poll(&fds, 2 + n_clients + n_inputs, timeout);
        const work_start = sys.nowNs();

        // The last frame reached the screen: its frame callbacks fire, and
        // the next one can be drawn.
        if (fds[1].revents != 0) {
            const flip_start = sys.nowNs();
            defer stats.flips_ns += sys.nowNs() - flip_start;
            if (renderer.handleEvents() catch |err| blk: {
                print("stardust-shell: display events: {s}\n", .{@errorName(err)});
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
                // Buttons over the dock are the shell's.
                if (e == .button and pointer.y >= @as(f64, @floatFromInt(dock_y))) {
                    pointer.flushMotion(&server, time_ms);
                    if (!e.button.pressed or e.button.code != btn_left) continue;
                    const i = dock.hit(pointer.x, pointer.y - @as(f64, @floatFromInt(dock_y))) orelse continue;
                    const app = &apps[i];
                    if (app.pid) |pid| {
                        if (!server.raise(pid)) print("stardust-shell: {s} has no window yet\n", .{app.label});
                    } else {
                        app.pid = spawn(app.path, runtime_dir);
                        dock.draw();
                        renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
                        panels_damaged = true;
                    }
                    continue;
                }
                pointer.handle(&server, time_ms, e);
            }
            if (pointer.moved) {
                pointer.moved = false;
                renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
                const in_dock = pointer.y >= @as(f64, @floatFromInt(dock_y));
                if (dock.pointerAt(if (in_dock) pointer.x else null, pointer.y - @as(f64, @floatFromInt(dock_y)))) {
                    dock.draw();
                    renderer.setPanel(.dock, dock.pixels, dock.width, dock.height, @intCast(dock_y));
                    panels_damaged = true;
                }
            }
        };

        if (fds[0].revents != 0) {
            const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) == .SUCCESS) {
                _ = try server.addClient(@intCast(rc));
                print("stardust-shell: client connected\n", .{});
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
                print("stardust-shell: client disconnected\n", .{});
                continue;
            }
            i += 1;
        }

        if (server.damaged) client_frame_ns = sys.nowNs();
        stats.clients_ns += sys.nowNs() - clients_start;

        // The window under the pointer, and the one with the keyboard, may
        // have changed.
        server.updateFocus();

        // The bar: once a second, or when the title changes.
        const top = server.topWindow();
        const title = if (top) |t| t.title() else "";
        const t_now = sys.nowNs();
        const title_changed = !std.mem.eql(u8, title, last_title[0..last_title_len]);
        if (bar) |*b| if (t_now >= next_tick or title_changed) {
            last_title_len = @min(title.len, last_title.len);
            @memcpy(last_title[0..last_title_len], title[0..last_title_len]);
            b.draw(title, (t_now - start) / std.time.ns_per_s) catch {};
            renderer.setPanel(.bar, b.pixels, b.width, b.height, 0);
            panels_damaged = true;
            stats.bar_ns += sys.nowNs() - t_now;
        };
        if (t_now >= next_tick) {
            next_tick = start + ((t_now - start) / std.time.ns_per_s + 1) * std.time.ns_per_s;
            // Keyboards and mice plugged in since.
            devices.scan();
        }

        // Draw while the previous frame is on the screen; it is shown at
        // the next vertical blank, without waiting here. A change to the
        // bar alone waits for a while if a client is animating, and goes
        // out with its next frame: otherwise it would take the next
        // vertical blank, and the client's frame would be shown a refresh
        // late.
        const bar_due = panels_damaged and sys.nowNs() >= client_frame_ns + bar_grace_ns;
        if ((server.damaged or bar_due) and !renderer.flipPending()) {
            const draw_start = sys.nowNs();
            defer stats.display_ns += sys.nowNs() - draw_start;
            panels_damaged = false;
            server.frameDrawn();
            // A full-size window goes straight onto the display, with the
            // bar on a plane above it. Otherwise (or if the display cannot
            // show it) the frame is composited.
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
                const window: ?render.Window = if (top) |t| .{
                    .texture = t.xdg.surface.?.texture().?,
                    .x = server.work_area.x,
                    .y = server.work_area.y,
                    .clip = server.work_area,
                } else null;
                if (renderer.composite(window)) |timing| {
                    stats.composited(timing);
                    on_screen = renderer.show() catch |err| blk: {
                        print("stardust-shell: cannot show the frame: {s}\n", .{@errorName(err)});
                        server.framePresented(@truncate(sys.nowNs() / std.time.ns_per_ms));
                        break :blk false;
                    };
                } else |err| {
                    // Nothing new reaches the screen, but the clients should
                    // not wait for it.
                    print("stardust-shell: frame failed: {s}\n", .{@errorName(err)});
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
                if (renderer.showCursor()) {
                    renderer.moveCursor(@intFromFloat(pointer.x), @intFromFloat(pointer.y));
                    print("stardust-shell: cursor shown\n", .{});
                } else |err| print("stardust-shell: no cursor: {s}\n", .{@errorName(err)});
            }
        }
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

/// How long a change to the bar or the dock alone waits for a client's
/// frame to go out with (a few refreshes).
const bar_grace_ns = 50 * std.time.ns_per_ms;

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
    /// requests, redrawing the bar, and drawing or showing frames.
    work_ns: u64 = 0,
    clients_ns: u64 = 0,
    bar_ns: u64 = 0,
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
            print("stardust-shell: {d:.1} frames/s composited (CPU {d:.2} ms, GPU {d:.2} ms per frame), {d:.1} frames/s direct, {d} refreshes skipped\n", .{
                n / seconds,
                @as(f64, @floatFromInt(s.cpu_ns)) / n / ms,
                @as(f64, @floatFromInt(s.gpu_ns)) / n / ms,
                @as(f64, @floatFromInt(s.direct)) / seconds,
                s.skipped,
            });
        } else if (s.direct > 0) {
            print("stardust-shell: {d:.1} frames/s, all shown directly, {d} refreshes skipped\n", .{ @as(f64, @floatFromInt(s.direct)) / seconds, s.skipped });
        }
        const shown = s.frames + s.direct;
        if (shown > 0) {
            const n: f64 = @floatFromInt(shown);
            const other = s.work_ns -| (s.clients_ns + s.bar_ns + s.display_ns + s.flips_ns);
            print("stardust-shell: work {d:.2} ms per frame (clients {d:.2}, bar {d:.2}, display {d:.2} of which commits {d:.2}, flips {d:.2}, other {d:.2}), {d:.1} wakeups per frame, {d:.1}% of the time\n", .{
                @as(f64, @floatFromInt(s.work_ns)) / n / ms,
                @as(f64, @floatFromInt(s.clients_ns)) / n / ms,
                @as(f64, @floatFromInt(s.bar_ns)) / n / ms,
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

/// Starts a client program, with the Wayland environment.
fn spawn(program: [*:0]const u8, runtime_dir: [:0]const u8) ?linux.pid_t {
    var env_buf: [160]u8 = undefined;
    const runtime_env = std.fmt.bufPrintZ(&env_buf, "XDG_RUNTIME_DIR={s}", .{runtime_dir}) catch return null;
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        print("stardust-shell: cannot start {s}: fork failed\n", .{program});
        return null;
    }
    if (rc != 0) {
        print("stardust-shell: started {s} (pid {d})\n", .{ program, rc });
        return @intCast(rc);
    }
    const argv = [_:null]?[*:0]const u8{program};
    const envp = [_:null]?[*:0]const u8{ "HOME=/", "WAYLAND_DISPLAY=wayland-0", runtime_env.ptr };
    const err = linux.errno(linux.execve(program, &argv, &envp));
    print("stardust-shell: cannot run {s} ({s})\n", .{ program, @tagName(err) });
    linux.exit(127);
}

/// Set when a client process exits (SIGCHLD), so it is reaped.
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
/// then shows as not running).
fn reapChildren(apps: []dock_mod.App) bool {
    var app_exited = false;
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return app_exited;
        for (apps) |*app| if (app.pid == @as(linux.pid_t, @intCast(rc))) {
            app.pid = null;
            app_exited = true;
        };
        if (linux.W.IFEXITED(status)) {
            print("stardust-shell: client {d} exited with status {d}\n", .{ rc, linux.W.EXITSTATUS(status) });
        } else if (linux.W.IFSIGNALED(status)) {
            print("stardust-shell: client {d} killed by signal {d}\n", .{ rc, linux.W.TERMSIG(status) });
        }
    }
}

test {
    _ = @import("server.zig");
    _ = @import("server_test.zig");
    _ = @import("input.zig");
    _ = @import("cursor.zig");
    _ = @import("dock.zig");
}
