//! The shell's see-through boxes (the dock, the performance overlay): what
//! is drawn in them is drawn twice, over black and over white, which says
//! how much of each pixel it covers; it is then put over the box's colour,
//! `alpha` opaque, so what is behind the box shows through it but not
//! through what is drawn in it (anti-aliased edges and see-through colours
//! included). Pixels are 0xAARRGGBB, not premultiplied.

const std = @import("std");
const font = @import("font");

/// How opaque a box is.
pub const alpha = 0xb8;

/// The colour drawn over black to start with.
pub const black = 0xff000000;
/// The colour drawn over white.
pub const white = 0xffffffff;

/// Puts what was drawn over black (`over_black`, which gets the result)
/// and the same over white over `box` (its alpha `alpha`).
pub fn compose(over_black: []u32, over_white: []const u32, box: u32) void {
    const box_a: u32 = alpha;
    for (over_black, over_white) |*p, w| {
        const b = p.*;
        // How much the drawing covers: none of it lets white through.
        var through: u32 = 0;
        inline for (.{ 0, 8, 16 }) |shift| through += (w >> shift & 0xff) -| (b >> shift & 0xff);
        const a: u32 = 255 - @min((through + 1) / 3, 255);
        // Its colour, premultiplied, is what it left over black; the box
        // shows through the rest.
        const rest = box_a * (255 - a);
        const out_a = a + (rest + 127) / 255;
        if (out_a == 0) {
            p.* = 0;
            continue;
        }
        var out: u32 = out_a << 24;
        inline for (.{ 0, 8, 16 }) |shift| {
            const premul = (b >> shift & 0xff) * 255 + (box >> shift & 0xff) * rest / 255;
            out |= @as(u32, @min((premul + out_a / 2) / out_a, 255)) << shift;
        }
        p.* = out;
    }
}

/// Makes the canvas's corners, outside a rounded rectangle of `radius`,
/// see-through (in the pixels' alpha, as much as they are covered),
/// anti-aliased.
pub fn cutCorners(c: font.Canvas, radius: f32) void {
    const w: f32 = @floatFromInt(c.width);
    const h: f32 = @floatFromInt(c.height);
    const r = @min(radius, @min(w, h) / 2);
    const n: u32 = @intFromFloat(@ceil(r));
    for (0..c.height) |py| {
        // Only the rows and columns of the corners.
        if (py >= n and py + n < c.height) continue;
        for (0..c.width) |px| {
            if (px >= n and px + n < c.width) continue;
            const qx = @abs(@as(f32, @floatFromInt(px)) + 0.5 - w / 2) - (w / 2 - r);
            const qy = @abs(@as(f32, @floatFromInt(py)) + 0.5 - h / 2) - (h / 2 - r);
            const outside = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
            const coverage = std.math.clamp(0.5 - outside, 0, 1);
            const p = &c.pixels[py * c.stride + px];
            const a: f32 = @floatFromInt(p.* >> 24);
            p.* = (p.* & 0x00ffffff) | (@as(u32, @intFromFloat(@round(coverage * a))) << 24);
        }
    }
}

/// Fills a rectangle with rounded corners, anti-aliased, blended (as
/// much as the colour is opaque).
pub fn fillRounded(c: font.Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: u32) void {
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(x), 0, @as(f32, @floatFromInt(c.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(y), 0, @as(f32, @floatFromInt(c.height))));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(x + w), 0, @as(f32, @floatFromInt(c.width))));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(y + h), 0, @as(f32, @floatFromInt(c.height))));
    const cx = x + w / 2;
    const cy = y + h / 2;
    const r = @min(radius, @min(w, h) / 2);
    const opacity: f32 = @floatFromInt(color >> 24);
    for (y0..y1) |py| for (x0..x1) |px| {
        const qx = @abs(@as(f32, @floatFromInt(px)) + 0.5 - cx) - (w / 2 - r);
        const qy = @abs(@as(f32, @floatFromInt(py)) + 0.5 - cy) - (h / 2 - r);
        const outside = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
        const coverage = std.math.clamp(0.5 - outside, 0, 1);
        if (coverage <= 0) continue;
        const p = &c.pixels[py * c.stride + px];
        p.* = font.text.blend(p.*, color, @intFromFloat(@round(coverage * opacity)));
    };
}

/// `p` premultiplied by its alpha, as the display's planes take it.
pub fn premultiply(p: u32) u32 {
    const a = p >> 24;
    if (a == 255) return p;
    var out: u32 = a << 24;
    inline for (.{ 0, 8, 16 }) |shift| out |= ((p >> shift & 0xff) * a + 127) / 255 << shift;
    return out;
}

const testing = std.testing;

test "a box is see-through, but not what is drawn in it" {
    const box = 0xff1c2a4a;
    // The box alone, an opaque colour, white half covering, and a
    // see-through white (a quarter).
    var b = [_]u32{ black, 0xff3080c0, 0xff808080, 0xff404040 };
    const w = [_]u32{ white, 0xff3080c0, 0xffffffff, 0xffffffff };
    compose(&b, &w, box);
    try testing.expectEqual(@as(u32, alpha << 24 | 0x1c2a4a), b[0]);
    try testing.expectEqual(@as(u32, 0xff3080c0), b[1]);
    // Half covered: more opaque than the box, and lighter.
    try testing.expect(b[2] >> 24 > alpha and b[2] >> 24 < 0xff);
    try testing.expect((b[2] & 0xff) > 0x80);
    try testing.expect(b[3] >> 24 > alpha and b[3] >> 24 < b[2] >> 24);
    try testing.expectEqual(@as(u32, 0x80402010), premultiply(0x80804020));
}
