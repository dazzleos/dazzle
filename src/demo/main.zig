//! The Stardust demo: a spinning, textured cube drawn with OpenGL ES 2.0,
//! with the machine's IP address and rendering statistics in the top left
//! corner, written in the system font.
//!
//! It is a Wayland client: stardust-shell starts it, and it draws into a
//! window through EGL's Wayland platform. Without a compositor
//! ($WAYLAND_DISPLAY unset or not answering) it draws on the screen
//! directly instead, which is handy on Raspberry Pi OS (from a text
//! console, as a user who can open /dev/dri/card*):
//!
//!     stardust-demo [font.ttf]
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const font = @import("font");
const gles = @import("gles");
const cube_mod = @import("cube.zig");
const hud_mod = @import("hud.zig");
const netinfo = @import("netinfo.zig");
const window_mod = @import("window.zig");
const wayland = @import("wayland");

const gl = gles.gl;
const egl = gles.egl;
const print = sys.print;

/// The clear colour (also the overlay's background).
const background = 0xff101830;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    const font_path: [*:0]const u8 = args.next() orelse font.system_font_path;
    print("stardust: demo running as uid {d}\n", .{linux.getuid()});

    run(init, font_path) catch |err| {
        print("stardust: error: {s}\n", .{@errorName(err)});
        if (err == error.EglInitializeFailed)
            print("stardust: no GPU or display; look for vc4, hdmi or v3d errors earlier in the log\n", .{});
        return 1;
    };
    return 0;
}

fn loadFont(gpa: std.mem.Allocator, path: [*:0]const u8) ?font.Font {
    const data = sys.readFileAlloc(gpa, path, 32 * 1024 * 1024) catch |err| {
        print("stardust: cannot read the font {s} ({s}); no statistics overlay\n", .{ path, @errorName(err) });
        return null;
    };
    return font.Font.init(data) catch |err| {
        print("stardust: {s} is not a usable font ({s}); no statistics overlay\n", .{ path, @errorName(err) });
        return null;
    };
}

/// Opens a window on the Wayland compositor, if there is one.
fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal) ?*window_mod.Window {
    const Environ = std.process.Environ;
    const display_name = Environ.getPosix(init.environ, "WAYLAND_DISPLAY") orelse {
        print("stardust: WAYLAND_DISPLAY is not set; drawing on the screen directly\n", .{});
        return null;
    };
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), display_name) catch {
        print("stardust: XDG_RUNTIME_DIR is not set; drawing on the screen directly\n", .{});
        return null;
    };
    return window_mod.Window.open(gpa, path, "Stardust demo") catch |err| {
        print("stardust: cannot open a window on {s} ({s}); drawing on the screen directly\n", .{ path, @errorName(err) });
        return null;
    };
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    const window = openWindow(gpa, init);
    var egl_window: ?*egl.egl_wayland.Window = null;
    const dpy = if (window) |win| blk: {
        egl_window = egl.egl_wayland.wl_egl_window_create(&win.surface, @intCast(win.width), @intCast(win.height));
        break :blk egl.eglGetDisplay(win.conn);
    } else egl.eglGetDisplay(egl.EGL_DEFAULT_DISPLAY);
    if (egl.eglInitialize(dpy, null, null) == egl.EGL_FALSE) return error.EglInitializeFailed;
    const config_attribs = [_]egl.EGLint{
        egl.EGL_RED_SIZE,        8,
        egl.EGL_GREEN_SIZE,      8,
        egl.EGL_BLUE_SIZE,       8,
        egl.EGL_DEPTH_SIZE,      24,
        egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
        egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_ES2_BIT,
        egl.EGL_NONE,
    };
    var config: egl.EGLConfig = null;
    var num_configs: egl.EGLint = 0;
    if (egl.eglChooseConfig(dpy, &config_attribs, @ptrCast(&config), 1, &num_configs) == egl.EGL_FALSE or num_configs == 0)
        return error.NoEglConfig;
    const surface = egl.eglCreateWindowSurface(dpy, config, if (egl_window) |w| @intFromPtr(w) else 0, null);
    if (surface == egl.EGL_NO_SURFACE) return error.EglSurfaceFailed;
    const context_attribs = [_]egl.EGLint{ egl.EGL_CONTEXT_CLIENT_VERSION, 2, egl.EGL_NONE };
    const context = egl.eglCreateContext(dpy, config, egl.EGL_NO_CONTEXT, &context_attribs);
    if (context == egl.EGL_NO_CONTEXT) return error.EglContextFailed;
    if (egl.eglMakeCurrent(dpy, surface, surface, context) == egl.EGL_FALSE) return error.EglMakeCurrentFailed;

    var w: egl.EGLint = 0;
    var h: egl.EGLint = 0;
    _ = egl.eglQuerySurface(dpy, surface, egl.EGL_WIDTH, &w);
    _ = egl.eglQuerySurface(dpy, surface, egl.EGL_HEIGHT, &h);
    var width: u32 = @intCast(w);
    var height: u32 = @intCast(h);
    const where = if (window != null) "window" else "screen";
    print("stardust: {s} on {s}, {s} {d}x{d}\n", .{
        std.mem.span(gl.glGetString(gl.GL_VERSION).?), std.mem.span(gl.glGetString(gl.GL_RENDERER).?), where, width, height,
    });

    const cube = try cube_mod.Cube.init();
    var f = loadFont(gpa, font_path);
    var hud: ?hud_mod.Hud = if (f) |*fnt| try hud_mod.Hud.init(gpa, fnt, width, height, background) else null;

    gl.glViewport(0, 0, w, h);
    gl.glClearColor(16.0 / 255.0, 24.0 / 255.0, 48.0 / 255.0, 1.0);
    const gl_error = gl.glGetError();
    if (gl_error != gl.GL_NO_ERROR) print("stardust: GL error 0x{x} during setup\n", .{gl_error});

    const start = sys.nowNs();
    var stats_window: Stats = .{ .since = start };
    var shown: Stats.Summary = .{};
    var log_window: Stats = .{ .since = start };
    var next_update: u64 = start;
    while (true) {
        if (window) |win| {
            win.poll() catch |err| {
                if (err == error.ServerError) print("stardust: compositor error: {s}\n", .{win.conn.errorMessage()});
                return err;
            };
            if (win.closed) return;
            if (try win.applyConfigure()) |size| {
                // The next buffer EGL picks has the new size.
                egl.egl_wayland.wl_egl_window_resize(egl_window.?, @intCast(size[0]), @intCast(size[1]), 0, 0);
                width = size[0];
                height = size[1];
                gl.glViewport(0, 0, @intCast(width), @intCast(height));
                if (hud) |*hd| try hd.resize(width, height);
                next_update = 0;
            }
        }
        const frame_start = sys.nowNs();
        const t: f32 = @floatCast(@as(f64, @floatFromInt(frame_start - start)) / std.time.ns_per_s);

        // The overlay changes twice a second.
        if (hud) |*hd| if (frame_start >= next_update) {
            next_update = frame_start + std.time.ns_per_s / 2;
            var bufs: [hud_mod.Hud.lines][96]u8 = undefined;
            hd.update(statusLines(&bufs, shown, width, height)) catch |e| print("stardust: overlay: {s}\n", .{@errorName(e)});
        };

        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
        cube.draw(width, height, t);
        if (hud) |*hd| hd.draw();
        const issued = sys.nowNs();
        // Render now, so the GPU's time can be told apart from waiting for
        // the display's vertical blank in eglSwapBuffers.
        gl.glFinish();
        const rendered = sys.nowNs();
        if (egl.eglSwapBuffers(dpy, surface) == egl.EGL_FALSE) return error.EglSwapBuffersFailed;

        stats_window.add(issued - frame_start, rendered - issued);
        log_window.add(issued - frame_start, rendered - issued);
        const now = sys.nowNs();
        if (now - stats_window.since >= std.time.ns_per_s / 2) {
            shown = stats_window.summary(now);
            stats_window = .{ .since = now };
        }
        // Also log every 5 seconds, for the network log.
        if (now - log_window.since >= 5 * std.time.ns_per_s) {
            const s = log_window.summary(now);
            print("stardust: {d:.1} fps, GPU {d:.2} ms, CPU {d:.2} ms per frame\n", .{ s.fps, s.gpu_ms, s.cpu_ms });
            log_window = .{ .since = now };
        }
    }
}

/// Frame timing over a window of time.
const Stats = struct {
    since: u64,
    frames: u32 = 0,
    cpu_ns: u64 = 0,
    gpu_ns: u64 = 0,

    const Summary = struct {
        fps: f32 = 0,
        /// Issuing the frame's GL calls.
        cpu_ms: f32 = 0,
        /// From submitting the frame to the GPU finishing it.
        gpu_ms: f32 = 0,
    };

    fn add(s: *Stats, cpu_ns: u64, gpu_ns: u64) void {
        s.frames += 1;
        s.cpu_ns += cpu_ns;
        s.gpu_ns += gpu_ns;
    }

    fn summary(s: *const Stats, now: u64) Summary {
        if (s.frames == 0 or now == s.since) return .{};
        const n: f32 = @floatFromInt(s.frames);
        const ms = std.time.ns_per_ms;
        return .{
            .fps = n / (@as(f32, @floatFromInt(now - s.since)) / std.time.ns_per_s),
            .cpu_ms = @as(f32, @floatFromInt(s.cpu_ns)) / n / ms,
            .gpu_ms = @as(f32, @floatFromInt(s.gpu_ns)) / n / ms,
        };
    }
};

/// The overlay's lines of text.
fn statusLines(bufs: *[hud_mod.Hud.lines][96]u8, s: Stats.Summary, width: u32, height: u32) [hud_mod.Hud.lines][]const u8 {
    var out: [hud_mod.Hud.lines][]const u8 = undefined;
    out[0] = if (netinfo.primaryAddress()) |a|
        std.fmt.bufPrint(&bufs[0], "{d}.{d}.{d}.{d}  ({s})", .{ a.ip[0], a.ip[1], a.ip[2], a.ip[3], a.name() }) catch ""
    else
        "No network";
    out[1] = std.fmt.bufPrint(&bufs[1], "{d:.1} fps  ·  {d}×{d}  ·  {d} triangles", .{ s.fps, width, height, cube_mod.triangles }) catch "";
    out[2] = std.fmt.bufPrint(&bufs[2], "GPU {d:.2} ms per frame", .{s.gpu_ms}) catch "";
    out[3] = std.fmt.bufPrint(&bufs[3], "CPU {d:.2} ms per frame", .{s.cpu_ms}) catch "";
    return out;
}

test {
    _ = @import("window.zig");
    _ = @import("cube.zig");
    _ = @import("hud.zig");
    _ = @import("netinfo.zig");
}

test "status lines" {
    var bufs: [hud_mod.Hud.lines][96]u8 = undefined;
    const lines = statusLines(&bufs, .{ .fps = 59.94, .cpu_ms = 0.42, .gpu_ms = 6.5 }, 1920, 1080);
    try std.testing.expectEqualStrings("59.9 fps  ·  1920×1080  ·  12 triangles", lines[1]);
    try std.testing.expectEqualStrings("GPU 6.50 ms per frame", lines[2]);
}
