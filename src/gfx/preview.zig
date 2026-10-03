//! Renders a canvas on the CPU with the real fragment shaders, run in the
//! QPU simulator: the triangles are rasterized here (pixel centres, with
//! the top-left fill rule), and each 16 pixels' interpolated varyings and
//! tile colours go through the compiled shader. Tests check pixels with
//! it, and it makes preview images without a Pi.

const std = @import("std");
const vc4 = @import("vc4");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");

const shader = @import("shader");

const sim = vc4.qpu_sim;

pub const Programs = struct {
    shape: shader.Program,
    solid: shader.Program,

    pub fn load() Programs {
        return .{ .shape = shaders.shape(), .solid = shaders.solid() };
    }
};

/// An image in the tile buffer's format: 0xAARRGGBB per pixel.
pub const Image = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn at(img: Image, x: u32, y: u32) u32 {
        return img.pixels[y * img.width + x];
    }
};

const max_varyings = shaders.shape_floats - 2;

/// Pixels waiting to be shaded together.
const Group = struct {
    index: [sim.lanes]usize = undefined,
    varyings: [max_varyings]sim.Vec = undefined,
    n: usize = 0,
};

pub fn render(c: *const canvas_mod.Canvas, programs: *const Programs, img: Image) !void {
    for (c.batches.items) |*b| {
        const floats = canvas_mod.floatsPerVertex(b.kind);
        const fs = if (b.kind == .shape) &programs.shape.fs else &programs.solid.fs;
        const nvary = floats - 2;
        var group: Group = .{};
        const verts = b.floats.items;
        var t: usize = 0;
        while (t + 3 * floats <= verts.len) : (t += 3 * floats) {
            const tri = [3][]const f32{ verts[t..][0..floats], verts[t + floats ..][0..floats], verts[t + 2 * floats ..][0..floats] };
            var p: [3][2]f32 = undefined;
            for (tri, &p) |vert, *q| q.* = .{ (vert[0] + 1) / 2 * @as(f32, @floatFromInt(img.width)), (1 - vert[1]) / 2 * @as(f32, @floatFromInt(img.height)) };
            const area = edge(p[0], p[1], p[2]);
            if (area == 0) continue;
            var x0: i32 = @intFromFloat(@floor(@min(p[0][0], @min(p[1][0], p[2][0]))));
            var y0: i32 = @intFromFloat(@floor(@min(p[0][1], @min(p[1][1], p[2][1]))));
            var x1: i32 = @intFromFloat(@ceil(@max(p[0][0], @max(p[1][0], p[2][0]))));
            var y1: i32 = @intFromFloat(@ceil(@max(p[0][1], @max(p[1][1], p[2][1]))));
            x0 = @max(x0, 0);
            y0 = @max(y0, 0);
            x1 = @min(x1, @as(i32, @intCast(img.width)));
            y1 = @min(y1, @as(i32, @intCast(img.height)));
            if (b.clip) |clip| {
                x0 = @max(x0, @as(i32, @intFromFloat(@floor(clip.x))));
                y0 = @max(y0, @as(i32, @intFromFloat(@floor(clip.y))));
                x1 = @min(x1, @as(i32, @intFromFloat(@floor(clip.x))) + @as(i32, @intFromFloat(@ceil(clip.w))));
                y1 = @min(y1, @as(i32, @intFromFloat(@floor(clip.y))) + @as(i32, @intFromFloat(@ceil(clip.h))));
            }
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                    var w: [3]f32 = undefined;
                    var inside = true;
                    for (0..3) |k| {
                        const a = p[(k + 1) % 3];
                        const bb = p[(k + 2) % 3];
                        // Oriented so the inside is positive. Evaluated with
                        // the endpoints in a fixed order, so the two
                        // triangles sharing an edge get exactly opposite
                        // values and a centre on it goes to just one.
                        w[k] = canonicalEdge(a, bb, c_) * std.math.sign(area);
                        if (w[k] < 0 or (w[k] == 0 and !topLeft(a, bb, area))) inside = false;
                    }
                    if (!inside) continue;
                    const sum = w[0] + w[1] + w[2];
                    const lane = group.n;
                    group.index[lane] = @as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x));
                    for (0..nvary) |i| {
                        const value = (w[0] * tri[0][2 + i] + w[1] * tri[1][2 + i] + w[2] * tri[2][2 + i]) / sum;
                        group.varyings[i][lane] = @bitCast(value);
                    }
                    group.n += 1;
                    if (group.n == sim.lanes) try shade(fs, &group, nvary, img);
                }
            }
        }
        if (group.n > 0) try shade(fs, &group, nvary, img);
    }
}

fn canonicalEdge(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    const swap = a[0] > b[0] or (a[0] == b[0] and a[1] > b[1]);
    return if (swap) -edge(b, a, c) else edge(a, b, c);
}

fn edge(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// Pixel centres exactly on an edge belong to the triangle if the edge is
/// a top or left one (so a pixel on a shared edge is drawn once).
fn topLeft(a: [2]f32, b: [2]f32, area: f32) bool {
    const dx = (b[0] - a[0]) * std.math.sign(area);
    const dy = (b[1] - a[1]) * std.math.sign(area);
    // With y down and the inside positive, a top edge runs right to left
    // horizontally, and a left edge runs down.
    return (dy == 0 and dx < 0) or dy > 0;
}

fn shade(fs: *const vc4.compiler.Compiled, g: *Group, nvary: usize, img: Image) !void {
    // Unused lanes repeat the last pixel; their results are dropped.
    for (g.n..sim.lanes) |lane| {
        g.index[lane] = g.index[g.n - 1];
        for (0..nvary) |i| g.varyings[i][lane] = g.varyings[i][g.n - 1];
    }
    var tile: sim.Vec = undefined;
    for (&tile, g.index) |*t, idx| t.* = img.pixels[idx];
    const r = try sim.run(fs.code(), .{ .varyings = g.varyings[0..nvary], .tlb_color_in = tile });
    for (g.index[0..g.n], 0..) |idx, lane| img.pixels[idx] = r.tlb_color.?[lane];
    g.n = 0;
}

/// Writes the image as a binary PPM.
pub fn writePpm(img: Image, writer: anytype) !void {
    try writer.print("P6\n{d} {d}\n255\n", .{ img.width, img.height });
    for (img.pixels) |px| {
        const rgb = [3]u8{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
        try writer.writeAll(&rgb);
    }
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;
const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;

fn channel(px: u32, shift: u5) i32 {
    return @intCast(px >> shift & 0xff);
}

fn expectNear(want: u32, got: u32, tolerance: i32) !void {
    for ([_]u5{ 0, 8, 16 }) |s| {
        const d = channel(want, s) - channel(got, s);
        if (d < -tolerance or d > tolerance) {
            std.debug.print("expected 0x{x:0>8}, got 0x{x:0>8}\n", .{ want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "rounded rectangles: solid inside, clear outside, smooth corners and edges" {
    const programs = Programs.load();
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(64, 48);
    c.fillRoundedRect(.{ .x = 8, .y = 8, .w = 48, .h = 32 }, .all(10), Color.rgb(0xff0000));
    var pixels: [64 * 48]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 64, .height = 48 };
    try render(&c, &programs, img);
    // Inside, in the solid centre and in a corner cell.
    try expectNear(0xffff0000, img.at(32, 24), 1);
    try expectNear(0xffff0000, img.at(12, 14), 1);
    // Outside: beyond the corner's curve, and beside the rectangle.
    try expectNear(0xff000000, img.at(9, 9), 1);
    try expectNear(0xff000000, img.at(5, 24), 1);
    // The left edge at x = 8 runs between pixel columns: column 8 is
    // fully inside, column 7 fully outside.
    try expectNear(0xffff0000, img.at(8, 24), 1);
    try expectNear(0xff000000, img.at(7, 24), 1);
    // On the curve: partly covered.
    const curve = channel(img.at(10, 11), 16);
    try testing.expect(curve > 20 and curve < 235);
}

test "edges at half pixels are half covered, and blending mixes colours" {
    const programs = Programs.load();
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(32, 32);
    // Square edges through pixel centres: those pixels are half covered.
    c.fillRect(.{ .x = 4.5, .y = 4.5, .w = 20, .h = 20 }, Color.rgb(0xffffff));
    // A half-transparent blue square over part of it.
    c.fillRect(.{ .x = 16, .y = 16, .w = 10, .h = 10 }, Color.rgb(0x0000ff).withAlpha(0.5));
    var pixels: [32 * 32]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 32, .height = 32 };
    try render(&c, &programs, img);
    try expectNear(0xff808080, img.at(4, 10), 2);
    try expectNear(0xff808080, img.at(10, 4), 2);
    // A corner pixel: a quarter.
    try expectNear(0xff404040, img.at(4, 4), 3);
    // White under half blue; black under half blue.
    try expectNear(0xff8080ff, img.at(20, 20), 2);
    try expectNear(0xff000080, img.at(25, 25), 2);
}

test "strokes and polygons" {
    const programs = Programs.load();
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(40, 40);
    // A 2-pixel outline inside a 20x20 rounded square.
    c.strokeRoundedRect(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, .all(4), 2, Color.rgb(0x00ff00));
    var pixels: [40 * 40]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 40, .height = 40 };
    try render(&c, &programs, img);
    try expectNear(0xff00ff00, img.at(10, 20), 1);
    try expectNear(0xff00ff00, img.at(11, 20), 1);
    try expectNear(0xff000000, img.at(12, 20), 1);
    try expectNear(0xff000000, img.at(20, 20), 1);
    try expectNear(0xff00ff00, img.at(20, 29), 1);

    // A triangle, filled: inside and outside.
    c.begin(40, 40);
    c.fillPolygon(&.{ .{ 5, 35 }, .{ 20, 5 }, .{ 35, 35 } }, Color.rgb(0xffffff));
    @memset(&pixels, 0xff000000);
    try render(&c, &programs, img);
    try expectNear(0xffffffff, img.at(20, 25), 1);
    try expectNear(0xff000000, img.at(5, 10), 1);
}
