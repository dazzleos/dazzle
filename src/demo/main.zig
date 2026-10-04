//! The Stardust demo: a spinning Platonic solid, with the machine's IP
//! address and rendering statistics in the top left corner, written in
//! Fira Sans (its own copy, next to the executable), buttons that change
//! the solid's speed, radio buttons to choose the solid and switches for
//! its lighting and texture. Clicks draw expanding, fading rings behind
//! the solid.
//!
//! It is a native Stardust app: a window on stardust-shell (see the `app`
//! module), built with the `ui` toolkit (see view.zig), drawn with the vc4
//! API and shaders written in Zig.
//!
//!     stardust-demo [font.ttf]
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const solids = @import("solids.zig");
const netinfo = @import("netinfo.zig");
const rings_mod = @import("rings.zig");
const view = @import("view.zig");
const ui = @import("ui");
const sysinfo = @import("sysinfo.zig");
const build_info = @import("build_info");
const wayland = @import("wayland");

const print = sys.print;

/// The clear colour.
const background = 0xff101830;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse (sys.appFile(&font_buf, font.default_font_file) catch font.default_font_file);
    print("stardust: demo (build {s}) running as uid {d}\n", .{ build_info.commit, linux.getuid() });

    run(init, font_path) catch |err| {
        print("stardust: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn loadFont(gpa: std.mem.Allocator, path: [*:0]const u8) ?font.Font {
    const data = sys.readFileAlloc(gpa, path, 32 * 1024 * 1024) catch |err| {
        print("stardust: cannot read the font {s} ({s}); no text\n", .{ path, @errorName(err) });
        return null;
    };
    return font.Font.init(data) catch |err| {
        print("stardust: {s} is not a usable font ({s}); no text\n", .{ path, @errorName(err) });
        return null;
    };
}

/// Opens a window on the Wayland compositor.
fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    const display_name = Environ.getPosix(init.environ, "WAYLAND_DISPLAY") orelse {
        print("stardust: WAYLAND_DISPLAY is not set; run me under stardust-shell\n", .{});
        return error.NoCompositor;
    };
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), display_name) catch {
        print("stardust: XDG_RUNTIME_DIR is not set\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Stardust demo") catch |err| {
        print("stardust: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("stardust-demo");
    return win;
}

/// Frames are large; the demo records one at a time.
var frame: vc4.render.Frame = undefined;

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print("stardust: no GPU ({s}); look for vc4 or v3d errors earlier in the log\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;
    print("stardust: drawing with the vc4 API, window {d}x{d}\n", .{ width, height });

    var all_solids = try solids.Solids.init(gpa, dev);
    var f = loadFont(gpa, font_path);
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    try window_ui.attachGpu(dev);
    var rings: rings_mod.Rings = .{};
    var status_bufs: [view.lines][96]u8 = undefined;
    var status: [view.lines][]const u8 = @splat("");
    var input: InputStatus = .{};
    // The CPU's speed is measured against this first sample, taken cool.
    var monitor: sysinfo.Monitor = .{};
    var health = monitor.sample();

    const start = sys.nowNs();
    var stats_window: Stats = .{ .since = start };
    var shown: Stats.Summary = .{};
    var log_window: Stats = .{ .since = start };
    var next_update: u64 = start;
    while (true) {
        win.poll() catch |err| {
            if (err == error.ServerError) print("stardust: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed) return;
        if (try win.applyConfigure()) |size| {
            // The next frame is rendered at the new size.
            width = size[0];
            height = size[1];
            next_update = 0;
        }
        const frame_start = sys.nowNs();
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| {
                input.pointer = pos;
                window_ui.pointerMotion(pos);
            },
            .button => |b| {
                if (b.pressed) rings.add(frame_start, b.pos[0], b.pos[1], .argb(buttonColor(b.code)));
                window_ui.pointerButton(b.pos, b.code, b.pressed);
            },
            .key => |k| if (k.pressed) {
                input.key = k.code;
                next_update = 0;
            },
        };

        // The statistics change twice a second.
        if (frame_start >= next_update) {
            next_update = frame_start + std.time.ns_per_s / 2;
            status = statusLines(&status_bufs, shown, width, height, input, health);
        }

        const scale = @min(@as(f32, @floatFromInt(width)) / 1920, @as(f32, @floatFromInt(height)) / 1080);
        window_ui.frame(width, height, frame_start, view.Demo{
            .solids = &all_solids,
            .rings = &rings,
            .subtitle = "build " ++ build_info.commit,
            .status = status,
            .scale = scale,
        });
        frame.begin(try win.beginFrame(), .{ .clear = background });
        try window_ui.render(&frame);
        const issued = sys.nowNs();
        // Render, then hand the frame to the shell (which may wait for the
        // previous one to be shown), so the GPU's time is measured alone.
        try win.render(&frame);
        const rendered = sys.nowNs();
        try win.show();

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
            health = monitor.sample();
            var temp_buf: [16]u8 = undefined;
            print("stardust: {d:.1} fps, GPU {d:.2} ms, CPU {d:.2} ms per frame; SoC {s}, CPU speed {d:.0}%, CPU busy {d:.0}% (demo {d:.0}%, shell {d:.0}%)\n", .{
                s.fps,        s.gpu_ms,          s.cpu_ms,         temperatureText(&temp_buf, health.temperature),
                health.speed, health.total_busy, health.demo_busy, health.shell_busy,
            });
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
        /// Recording the frame's draws.
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

fn buttonColor(code: u32) u32 {
    return switch (code) {
        wayland.protocol.input.btn_left => 0xff60d0ff,
        wayland.protocol.input.btn_right => 0xffffa040,
        wayland.protocol.input.btn_middle => 0xff80ff80,
        else => 0xffffffff,
    };
}

/// What the panel shows about input.
const InputStatus = struct {
    pointer: ?[2]f32 = null,
    /// The last key pressed (a Linux key code).
    key: ?u32 = null,
};

/// A name for a Linux key code (US layout).
fn keyName(buf: []u8, code: u32) []const u8 {
    const rows = [_]struct { first: u32, keys: []const u8 }{
        .{ .first = 2, .keys = "1234567890" },
        .{ .first = 16, .keys = "QWERTYUIOP" },
        .{ .first = 30, .keys = "ASDFGHJKL" },
        .{ .first = 44, .keys = "ZXCVBNM" },
    };
    for (rows) |row| if (code >= row.first and code < row.first + row.keys.len) {
        return std.fmt.bufPrint(buf, "{c}", .{row.keys[code - row.first]}) catch "";
    };
    const named = [_]struct { u32, []const u8 }{
        .{ 1, "Esc" },    .{ 14, "Backspace" }, .{ 15, "Tab" },   .{ 28, "Enter" },
        .{ 29, "Ctrl" },  .{ 42, "Shift" },     .{ 54, "Shift" }, .{ 56, "Alt" },
        .{ 57, "Space" }, .{ 97, "Ctrl" },      .{ 100, "Alt" },  .{ 103, "Up" },
        .{ 105, "Left" }, .{ 106, "Right" },    .{ 108, "Down" },
    };
    for (named) |n| if (n[0] == code) return n[1];
    return std.fmt.bufPrint(buf, "key {d}", .{code}) catch "";
}

fn temperatureText(buf: []u8, t: ?f32) []const u8 {
    const c = t orelse return "? °C";
    return std.fmt.bufPrint(buf, "{d:.0} °C", .{c}) catch "";
}

/// The panel's lines of statistics.
fn statusLines(bufs: *[view.lines][96]u8, s: Stats.Summary, width: u32, height: u32, input: InputStatus, health: sysinfo.Sample) [view.lines][]const u8 {
    var out: [view.lines][]const u8 = undefined;
    out[0] = if (netinfo.primaryAddress()) |a|
        std.fmt.bufPrint(&bufs[0], "{d}.{d}.{d}.{d}  ({s})", .{ a.ip[0], a.ip[1], a.ip[2], a.ip[3], a.name() }) catch ""
    else
        "No network";
    out[1] = std.fmt.bufPrint(&bufs[1], "{d:.1} fps  ·  {d}×{d}", .{ s.fps, width, height }) catch "";
    out[2] = std.fmt.bufPrint(&bufs[2], "GPU {d:.2} ms per frame", .{s.gpu_ms}) catch "";
    out[3] = std.fmt.bufPrint(&bufs[3], "CPU {d:.2} ms per frame", .{s.cpu_ms}) catch "";
    var key_buf: [16]u8 = undefined;
    const key = if (input.key) |k| keyName(&key_buf, k) else "none";
    out[4] = if (input.pointer) |pos|
        std.fmt.bufPrint(&bufs[4], "Pointer {d:.0}, {d:.0}  ·  last key {s}", .{ pos[0], pos[1], key }) catch ""
    else
        std.fmt.bufPrint(&bufs[4], "No pointer  ·  last key {s}", .{key}) catch "";
    var temp_buf: [24]u8 = undefined;
    out[5] = std.fmt.bufPrint(&bufs[5], "{s}  ·  CPU speed {d:.0}%  ·  busy {d:.0}%", .{ temperatureText(&temp_buf, health.temperature), health.speed, health.total_busy }) catch "";
    return out;
}

test {
    _ = @import("solids.zig");
    _ = @import("view.zig");
    _ = @import("netinfo.zig");
    _ = @import("rings.zig");
    _ = @import("sysinfo.zig");
}

test "status lines" {
    var bufs: [view.lines][96]u8 = undefined;
    const lines = statusLines(&bufs, .{ .fps = 59.94, .cpu_ms = 0.42, .gpu_ms = 6.5 }, 1920, 1080, .{ .pointer = .{ 12.25, 400 }, .key = 30 }, .{ .temperature = 61.6, .speed = 99.6, .total_busy = 45 });
    try std.testing.expectEqualStrings("59.9 fps  ·  1920×1080", lines[1]);
    try std.testing.expectEqualStrings("GPU 6.50 ms per frame", lines[2]);
    try std.testing.expectEqualStrings("Pointer 12, 400  ·  last key A", lines[4]);
    try std.testing.expectEqualStrings("62 °C  ·  CPU speed 100%  ·  busy 45%", lines[5]);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Space", keyName(&buf, 57));
    try std.testing.expectEqualStrings("0", keyName(&buf, 11));
    try std.testing.expectEqualStrings("key 200", keyName(&buf, 200));
}
