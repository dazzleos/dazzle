//! The pointer's pictures: a white arrow, or a double-headed arrow for
//! resizing (across, down, or diagonally), with a black outline, drawn
//! into premultiplied ARGB8888 pixels for the display's cursor plane.

const std = @import("std");

/// The cursor buffer's width and height in pixels.
pub const size = 32;

pub const Shape = enum {
    arrow,
    resize_horizontal,
    resize_vertical,
    /// Top left to bottom right.
    resize_diagonal_down,
    /// Bottom left to top right.
    resize_diagonal_up,
};

/// The point that is where the pointer is, from the top left corner: the
/// arrow's tip, or a double arrow's middle.
pub fn hotspot(shape: Shape) [2]i32 {
    return if (shape == .arrow) .{ 1, 1 } else .{ size / 2, size / 2 };
}

/// The arrow's outline, in units scaled by `scale`, with the tip at 0,0.
const arrow = [_][2]f32{ .{ 0, 0 }, .{ 0, 16 }, .{ 4, 12.5 }, .{ 7, 19 }, .{ 9.5, 18 }, .{ 6.5, 11.5 }, .{ 11.5, 11.5 } };
/// A double-headed arrow across, in the same units, its middle at 0,0.
const double = [_][2]f32{ .{ -8, 0 }, .{ -3.5, -4.5 }, .{ -3.5, -1.75 }, .{ 3.5, -1.75 }, .{ 3.5, -4.5 }, .{ 8, 0 }, .{ 3.5, 4.5 }, .{ 3.5, 1.75 }, .{ -3.5, 1.75 }, .{ -3.5, 4.5 } };
const scale = 1.5;
/// The black border's width in pixels.
const border = 1.0;

pub fn draw(pixels: *[size * size]u32, shape: Shape) void {
    // The outline, turned for the double arrows.
    const angle: f32 = switch (shape) {
        .arrow, .resize_horizontal => 0,
        .resize_vertical => std.math.pi / 2.0,
        .resize_diagonal_down => std.math.pi / 4.0,
        .resize_diagonal_up => -std.math.pi / 4.0,
    };
    const outline: []const [2]f32 = if (shape == .arrow) &arrow else &double;
    const hot = hotspot(shape);
    var buf: [double.len][2]f32 = undefined;
    const points = buf[0..outline.len];
    for (outline, points) |o, *pt| pt.* = .{
        (o[0] * @cos(angle) - o[1] * @sin(angle)) * scale + @as(f32, @floatFromInt(hot[0])),
        (o[0] * @sin(angle) + o[1] * @cos(angle)) * scale + @as(f32, @floatFromInt(hot[1])),
    };
    for (0..size) |y| for (0..size) |x| {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        // Coverage from 4x4 samples.
        var hits: u32 = 0;
        for (0..4) |sy| for (0..4) |sx| {
            const px = fx + (@as(f32, @floatFromInt(sx)) + 0.5) / 4;
            const py = fy + (@as(f32, @floatFromInt(sy)) + 0.5) / 4;
            if (inside(points, px, py)) hits += 1;
        };
        const alpha: f32 = @as(f32, @floatFromInt(hits)) / 16;
        // White, fading to black over the border.
        const white = std.math.clamp(edgeDistance(points, fx + 0.5, fy + 0.5) - border + 0.5, 0, 1);
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
    draw(&pixels, .arrow);
    // Inside: opaque white. At the border: opaque black. Outside: clear.
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[14 * size + 4]);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[20 * size + 1]);
    try std.testing.expectEqual(@as(u32, 0), pixels[0 * size + 20]);
    try std.testing.expectEqual(@as(u32, 0), pixels[31 * size + 31]);
    // Premultiplied: no colour is brighter than its alpha.
    for (pixels) |px| try std.testing.expect(px & 0xff <= px >> 24);
}

test "resize arrows point along their edges" {
    var pixels: [size * size]u32 = undefined;
    const Px = struct {
        fn white(px: u32) bool {
            return px >> 24 == 0xff and px & 0xff > 0xc0;
        }
    };
    // Across: white in the middle and towards the left tip, nothing above
    // or below the middle.
    draw(&pixels, .resize_horizontal);
    try std.testing.expect(Px.white(pixels[16 * size + 16]));
    try std.testing.expect(Px.white(pixels[16 * size + 6]));
    try std.testing.expectEqual(@as(u32, 0), pixels[4 * size + 16]);
    // Down: the same, turned.
    draw(&pixels, .resize_vertical);
    try std.testing.expect(Px.white(pixels[6 * size + 16]));
    try std.testing.expectEqual(@as(u32, 0), pixels[16 * size + 4]);
    // Diagonally: towards the top left, not the top right; and the other
    // way.
    draw(&pixels, .resize_diagonal_down);
    try std.testing.expect(Px.white(pixels[9 * size + 9]));
    try std.testing.expectEqual(@as(u32, 0), pixels[8 * size + 24]);
    draw(&pixels, .resize_diagonal_up);
    try std.testing.expect(Px.white(pixels[9 * size + 22]));
    try std.testing.expectEqual(@as(u32, 0), pixels[8 * size + 8]);
}
