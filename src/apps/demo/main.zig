//! The Dazzle demo: a spinning Platonic solid, with rendering statistics
//! in the top left corner, written in Fira Sans (its own copy, next to the
//! executable), buttons that change the solid's speed, radio buttons to
//! choose the solid and switches for its lighting and texture, and for
//! drawing in 16-bit colour (RGB565, the default) or 32-bit. Clicks draw
//! expanding, fading rings behind the solid.
//!
//! It is a native Dazzle app: a window on dazzle-shell (see the `app`
//! module), built with the `ui` toolkit (see view.zig), drawn with the vc4
//! API and shaders written in Zig.
//!
//!     dazzle-demo [font.ttf]
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const vc4 = @import("vc4");
const solids = @import("solids.zig");
const rings_mod = @import("rings.zig");
const view = @import("view.zig");
const ui = @import("ui");
const sysinfo = @import("sysinfo.zig");
const build_info = @import("build_info");

const print = sys.print;

/// The clear colour.
const background = 0xff101830;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    print("dazzle: demo (build {s}) running as uid {d}\n", .{ build_info.commit, linux.getuid() });

    run(init, font_path) catch |err| {
        print(sys.log_error ++ "dazzle: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    // The language chosen (in setup, or Settings).
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Dazzle demo",
        .app_id = "dazzle-demo",
        .size = view.open_size,
        .min_size = view.min_size,
        .font_path = font_path,
        .clear_color = background,
    });
    defer a.close();
    print("dazzle: drawing with the vc4 API, window {d}x{d}\n", .{ a.width, a.height });

    var all_solids = try solids.Solids.init(gpa, a.dev);
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
    // Something outside the UI changed (the size, the statistics): build a
    // frame. Otherwise frames are built only while a widget asks (for an
    // animation, or after input), and shown only if they changed.
    while (try a.step(@max(next_update -| sys.nowNs(), std.time.ns_per_ms))) {
        if (a.resized) next_update = 0;
        if (a.suspended_changed) {
            print("dazzle: {s}\n", .{if (a.suspended) "covered: not drawing" else "in front: drawing"});
        }
        const frame_start = sys.nowNs();
        for (a.win.takeInput()) |e| switch (e) {
            .motion => |pos| {
                input.pointer = pos;
                a.ui.pointerMotion(pos);
            },
            .button => |b| {
                a.ui.pointerButton(b.pos, b.code, b.pressed);
                a.dirty = true;
            },
            .key => |k| if (k.pressed) {
                input.key = k.code;
                next_update = 0;
            },
            else => a.ui.handleInput(e),
        };

        // The statistics change twice a second.
        if (frame_start >= next_update) {
            next_update = frame_start + std.time.ns_per_s / 2;
            status = statusLines(&status_bufs, shown, a.width, a.height, a.win.bufferFormat(), input, health);
            a.dirty = true;
        }

        a.idle = true;
        if (!a.suspended and (a.dirty or a.ui.needs_frame)) {
            a.dirty = false;
            a.ui.frame(a.width, a.height, frame_start, view.Demo{
                .solids = &all_solids,
                .rings = &rings,
                .status = status,
            });
            // The buffers' format, as the switch says (new buffers take it).
            if (a.ui.root) |root| a.win.setFormat(if (root.state(view.Demo.State).colour_16) .rgb565 else .xrgb8888);
            if (a.ui.changed()) {
                a.idle = false;
                // Only what changed since the buffer was last drawn is drawn
                // again; the rest of it already shows this frame.
                const target = try a.win.beginFrame();
                const region = a.ui.repaint(a.win.bufferAge());
                a.frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&a.frame, &region);
                try a.ui.render(&a.frame, a.win.flusher());
                const issued = sys.nowNs();
                // Render, then hand the frame to the shell (which may wait
                // for the previous one to be shown), so the GPU's time is
                // measured alone.
                try a.win.render(&a.frame);
                const rendered = sys.nowNs();
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                try a.win.showDamaged(a.ui.damagedViewports(&damage));
                stats_window.add(issued - frame_start, rendered - issued, region.slice());
                log_window.add(issued - frame_start, rendered - issued, region.slice());
            }
        }

        const now = sys.nowNs();
        if (now - stats_window.since >= std.time.ns_per_s / 2) {
            shown = stats_window.summary(now, a.width, a.height);
            stats_window = .{ .since = now };
        }
        // Also log every 5 seconds, for the network log.
        if (now - log_window.since >= 5 * std.time.ns_per_s) {
            const s = log_window.summary(now, a.width, a.height);
            health = monitor.sample();
            var temp_buf: [16]u8 = undefined;
            print("dazzle: {d:.1} fps ({d:.0}% of the window redrawn), GPU {d:.2} ms, CPU {d:.2} ms per frame; SoC {s}, CPU speed {d:.0}%, CPU busy {d:.0}% (demo {d:.0}%, shell {d:.0}%)\n", .{
                s.fps,                                          s.redrawn,    s.gpu_ms,          s.cpu_ms,
                temperatureText(&temp_buf, health.temperature), health.speed, health.total_busy, health.demo_busy,
                health.shell_busy,
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
    /// Pixels redrawn.
    pixels: f64 = 0,

    const Summary = struct {
        /// Frames drawn per second (none while nothing changes).
        fps: f32 = 0,
        /// Recording the frame's draws.
        cpu_ms: f32 = 0,
        /// From submitting the frame to the GPU finishing it.
        gpu_ms: f32 = 0,
        /// How much of the window a frame redrew, on average, in percent.
        redrawn: f32 = 0,
    };

    fn add(s: *Stats, cpu_ns: u64, gpu_ns: u64, region: []const ui.Rect) void {
        s.frames += 1;
        s.cpu_ns += cpu_ns;
        s.gpu_ns += gpu_ns;
        for (region) |r| s.pixels += r.w * r.h;
    }

    fn summary(s: *const Stats, now: u64, width: u32, height: u32) Summary {
        if (s.frames == 0 or now == s.since) return .{};
        const n: f32 = @floatFromInt(s.frames);
        const ms = std.time.ns_per_ms;
        const area: f64 = @floatFromInt(@as(u64, width) * height);
        return .{
            .fps = n / (@as(f32, @floatFromInt(now - s.since)) / std.time.ns_per_s),
            .cpu_ms = @as(f32, @floatFromInt(s.cpu_ns)) / n / ms,
            .gpu_ms = @as(f32, @floatFromInt(s.gpu_ns)) / n / ms,
            .redrawn = @floatCast(100 * s.pixels / @max(area, 1) / n),
        };
    }
};

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
fn statusLines(bufs: *[view.lines][96]u8, s: Stats.Summary, width: u32, height: u32, format: vc4.Format, input: InputStatus, health: sysinfo.Sample) [view.lines][]const u8 {
    var out: [view.lines][]const u8 = undefined;
    out[0] = std.fmt.bufPrint(&bufs[0], "{d:.1} fps  ·  {d}×{d}  ·  {d:.0}% redrawn", .{ s.fps, width, height, s.redrawn }) catch "";
    out[1] = std.fmt.bufPrint(&bufs[1], "GPU {d:.2} ms per frame  ·  {d}-bit {s}", .{ s.gpu_ms, format.bytesPerPixel() * 8, locale.text("colour") }) catch "";
    out[2] = std.fmt.bufPrint(&bufs[2], "CPU {d:.2} ms per frame", .{s.cpu_ms}) catch "";
    var key_buf: [16]u8 = undefined;
    const key = if (input.key) |k| keyName(&key_buf, k) else "none";
    out[3] = if (input.pointer) |pos|
        std.fmt.bufPrint(&bufs[3], "Pointer {d:.0}, {d:.0}  ·  last key {s}", .{ pos[0], pos[1], key }) catch ""
    else
        std.fmt.bufPrint(&bufs[3], "No pointer  ·  last key {s}", .{key}) catch "";
    var temp_buf: [24]u8 = undefined;
    out[4] = std.fmt.bufPrint(&bufs[4], "{s}  ·  CPU speed {d:.0}%  ·  busy {d:.0}%", .{ temperatureText(&temp_buf, health.temperature), health.speed, health.total_busy }) catch "";
    return out;
}

test {
    _ = @import("solids.zig");
    _ = @import("view.zig");
    _ = @import("rings.zig");
    _ = @import("sysinfo.zig");
}

test "status lines" {
    var bufs: [view.lines][96]u8 = undefined;
    const lines = statusLines(&bufs, .{ .fps = 59.94, .cpu_ms = 0.42, .gpu_ms = 6.5, .redrawn = 21.3 }, 1920, 1080, .rgb565, .{ .pointer = .{ 12.25, 400 }, .key = 30 }, .{ .temperature = 61.6, .speed = 99.6, .total_busy = 45 });
    try std.testing.expectEqualStrings("59.9 fps  ·  1920×1080  ·  21% redrawn", lines[0]);
    try std.testing.expectEqualStrings("GPU 6.50 ms per frame  ·  16-bit colour", lines[1]);
    try std.testing.expectEqualStrings("Pointer 12, 400  ·  last key A", lines[3]);
    try std.testing.expectEqualStrings("62 °C  ·  CPU speed 100%  ·  busy 45%", lines[4]);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Space", keyName(&buf, 57));
    try std.testing.expectEqualStrings("0", keyName(&buf, 11));
    try std.testing.expectEqualStrings("key 200", keyName(&buf, 200));
}
