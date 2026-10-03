//! The pointer's picture: a white arrow with a black outline, drawn into
//! premultiplied ARGB8888 pixels for the display's cursor plane.

const std = @import("std");

/// The cursor buffer's width and height in pixels.
pub const size = 32;
/// The arrow's tip, from the top left corner.
pub const hotspot = [2]i32{ 1, 1 };

/// The arrow's outline, in units scaled by `scale`, with the tip at 0,0.
const outline = [_][2]f32{ .{ 0, 0 }, .{ 0, 16 }, .{ 4, 12.5 }, .{ 7, 19 }, .{ 9.5, 18 }, .{ 6.5, 11.5 }, .{ 11.5, 11.5 } };
const scale = 1.5;
/// The black border's width in pixels.
const border = 1.0;

pub fn draw(pixels: *[size * size]u32) void {
    var points: [outline.len][2]f32 = undefined;
    for (outline, &points) |o, *pt| pt.* = .{
        o[0] * scale + @as(f32, @floatFromInt(hotspot[0])),
        o[1] * scale + @as(f32, @floatFromInt(hotspot[1])),
    };
    for (0..size) |y| for (0..size) |x| {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        // Coverage from 4x4 samples.
        var hits: u32 = 0;
        for (0..4) |sy| for (0..4) |sx| {
            const px = fx + (@as(f32, @floatFromInt(sx)) + 0.5) / 4;
            const py = fy + (@as(f32, @floatFromInt(sy)) + 0.5) / 4;
            if (inside(&points, px, py)) hits += 1;
        };
        const alpha: f32 = @as(f32, @floatFromInt(hits)) / 16;
        // White, fading to black over the border.
        const white = std.math.clamp(edgeDistance(&points, fx + 0.5, fy + 0.5) - border + 0.5, 0, 1);
        const a: u32 = @intFromFloat(@round(alpha * 255));
        const g: u32 = @intFromFloat(@round(white * alpha * 255));
        pixels[y * size + x] = a << 24 | g << 16 | g << 8 | g;
    };
}

/// Even-odd point in polygon test.
fn inside(points: []const [2]f32, x: f32, y: f32) bool {
    var in = false;
    var j = points.len - 1;
    for (points, 0..) |a, i| {
        const b = points[j];
        if ((a[1] > y) != (b[1] > y) and x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) in = !in;
        j = i;
    }
    return in;
}

/// The distance from a point to the polygon's outline.
fn edgeDistance(points: []const [2]f32, x: f32, y: f32) f32 {
    var best: f32 = std.math.inf(f32);
    var j = points.len - 1;
    for (points, 0..) |a, i| {
        const b = points[j];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const t = std.math.clamp(((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy), 0, 1);
        best = @min(best, std.math.hypot(x - (a[0] + t * dx), y - (a[1] + t * dy)));
        j = i;
    }
    return best;
}

test "arrow" {
    var pixels: [size * size]u32 = undefined;
    draw(&pixels);
    // Inside: opaque white. At the border: opaque black. Outside: clear.
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[14 * size + 4]);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[20 * size + 1]);
    try std.testing.expectEqual(@as(u32, 0), pixels[0 * size + 20]);
    try std.testing.expectEqual(@as(u32, 0), pixels[31 * size + 31]);
    // Premultiplied: no colour is brighter than its alpha.
    for (pixels) |px| try std.testing.expect(px & 0xff <= px >> 24);
}
