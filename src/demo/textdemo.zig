//! The text demo: a specimen page of the system font, drawn by the CPU with
//! Stardust's OpenType renderer and shown with page flips. A status line
//! (frame count, frame rate, uptime) is redrawn every frame.
//!
//! The page is drawn once into an ordinary (cached) buffer and copied to
//! both scanout buffers; after that only the status line's rows are
//! redrawn and copied, since scanout memory is slow to read and write.

const std = @import("std");
const sys = @import("sys");
const vc4 = @import("vc4");
const font = @import("font");
const demos = @import("demos.zig");

const background = 0xff101830;
const paper = 0xfff4f1ea;
const ink = 0xff202020;
const light = 0xffd8e0f0;
const accent = 0xffff9f43;

pub fn run(font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
        sys.print("stardust: cannot read the font {s}: {s}\n", .{ font_path, @errorName(err) });
        return err;
    };
    const f = font.Font.init(data) catch |err| {
        sys.print("stardust: {s} is not a usable font: {s}\n", .{ font_path, @errorName(err) });
        return err;
    };
    sys.print("stardust: font {s}: {d} glyphs, {d} kerning lookups\n", .{ font_path, f.num_glyphs, f.num_kern_lookups });

    const dev = try vc4.device.open();
    defer sys.close(dev.fd);
    const output = try vc4.drm.waitForOutput(dev.fd);
    var display = try vc4.display.Display.init(dev, output);
    const width: u32 = display.width;
    const height: u32 = display.height;
    const stride = vc4.render.Target.pitch(display.width) / 4;

    const pixels = try gpa.alloc(u32, @as(usize, stride) * height);
    const canvas: font.Canvas = .{ .pixels = pixels, .width = width, .height = height, .stride = stride };
    var cache = font.GlyphCache.init(gpa);

    // Sizes scale with the display, designed at 1080 lines.
    const scale = @as(f32, @floatFromInt(height)) / 1080;
    const start = sys.nowNs();
    const status_y = try drawPage(canvas, &cache, &f, scale);
    const status_h: u32 = @intFromFloat(@ceil(48 * scale));
    sys.print("stardust: text page drawn in {d:.1} ms, {d} glyphs cached\n", .{
        @as(f64, @floatFromInt(sys.nowNs() - start)) / std.time.ns_per_ms, cache.map.count(),
    });

    // Both scanout buffers start with the whole page.
    for (0..2) |_| {
        copyRows(&display, pixels, stride, 0, height);
        try display.present();
    }

    var stats: demos.FrameStats = .init(sys.nowNs());
    var frame: u64 = 0;
    var last = sys.nowNs();
    var fps: f32 = 0;
    while (true) : (frame += 1) {
        const now = sys.nowNs();
        const dt = @as(f32, @floatFromInt(now - last)) / std.time.ns_per_s;
        last = now;
        if (dt > 0) fps = if (fps == 0) 1 / dt else fps * 0.95 + 0.05 / dt;
        const up_s = (now - start) / std.time.ns_per_s;

        canvas.fill(0, @intCast(status_y), width, status_h, background);
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Frame {d}  ·  {d:.1} fps  ·  up {d}:{d:0>2}:{d:0>2}  ·  {d}×{d}", .{
            frame, fps, up_s / 3600, up_s / 60 % 60, up_s % 60, width, height,
        }) catch "";
        _ = try font.draw(canvas, &cache, .{ .font = &f, .size = 30 * scale, .color = accent }, 60 * scale, @as(f32, @floatFromInt(status_y)) + 36 * scale, line);
        copyRows(&display, pixels, stride, status_y, status_y + status_h);
        try display.present();
        stats.frame(0);
    }
}

/// Copies rows [y0, y1) of the page into the back buffer.
fn copyRows(display: *vc4.display.Display, pixels: []const u32, stride: u32, y0: u32, y1: u32) void {
    const dst = std.mem.bytesAsSlice(u32, display.back().bo.map);
    @memcpy(dst[@as(usize, y0) * stride .. @as(usize, y1) * stride], pixels[@as(usize, y0) * stride .. @as(usize, y1) * stride]);
}

/// Draws the static page. Returns the top of the status line.
fn drawPage(canvas: font.Canvas, cache: *font.GlyphCache, f: *const font.Font, scale: f32) !u32 {
    const w = canvas.width;
    const h = canvas.height;
    canvas.fill(0, 0, w, h, background);
    const left = 60 * scale;
    const style = struct {
        fn s(fnt: *const font.Font, size: f32, color: u32) font.Style {
            return .{ .font = fnt, .size = size, .color = color };
        }
    }.s;

    var y = 150 * scale;
    _ = try font.draw(canvas, cache, style(f, 120 * scale, 0xffffffff), left, y, "Stardust");
    y += 60 * scale;
    _ = try font.draw(canvas, cache, style(f, 32 * scale, light), left, y, "Fira Sans, drawn by Stardust's own OpenType renderer");
    y += 30 * scale;
    const status_y: u32 = @intFromFloat(y);
    y += 90 * scale;

    const pangram = "The quick brown fox jumps over the lazy dog. 0123456789";
    for ([_]f32{ 14, 18, 24, 32, 44 }) |size| {
        var label: [16]u8 = undefined;
        const l = std.fmt.bufPrint(&label, "{d} px", .{size}) catch "";
        _ = try font.draw(canvas, cache, style(f, 16 * scale, 0xff8090b0), left, y, l);
        _ = try font.draw(canvas, cache, style(f, size * scale, light), left + 90 * scale, y, pangram);
        y += (size * 1.25 + 14) * scale;
    }

    // Dark on light, with kerning, other scripts and punctuation.
    const paper_top: i32 = @intFromFloat(y);
    canvas.fill(0, paper_top, w, h - @as(u32, @intCast(paper_top)), paper);
    y += 80 * scale;
    _ = try font.draw(canvas, cache, style(f, 56 * scale, ink), left, y, "AVATAR · Type · Wolf · LT · r.");
    y += 64 * scale;
    _ = try font.draw(canvas, cache, style(f, 34 * scale, ink), left, y, "Ελληνικά  ·  Кириллица  ·  Ångström  ·  naïve  ·  € £ ¥");
    y += 50 * scale;
    _ = try font.draw(canvas, cache, style(f, 22 * scale, 0xff505050), left, y, "“Quotes”, (parentheses), [brackets], {braces} — and dashes – @ # % & *");
    const big = style(f, 260 * scale, 0xffc03020);
    _ = try font.draw(canvas, cache, big, @as(f32, @floatFromInt(w)) - font.measure(big, "Rg") - left, @as(f32, @floatFromInt(h)) - 70 * scale, "Rg");
    return status_y;
}
