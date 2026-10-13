//! Making pictures of the sensor's raw frames, on the CPU: what an image
//! signal processor would do (there is none in mainline Linux for these
//! boards). A raw frame is a Bayer mosaic: each pixel has one colour, red,
//! green or blue, in 2x2 blocks (`v4l2.Bayer` says which where).
//!
//! * Each sample's value has the sensor's black level taken off, is scaled
//!   by its colour's white balance gain, and goes through the sRGB gamma
//!   curve: all three in one 256-entry table per colour (`Tables`), as the
//!   samples are 8 bits (an 8-bit mode, or a 10-bit one's top 8 bits).
//! * The preview makes one pixel of each 2x2 block (red, the two greens'
//!   mean, blue), every `step`th block across and down so it fits the
//!   window: cheap enough for a Pi Zero at the camera's frame rate. It
//!   also gathers the frame's statistics (`Stats`): each colour's mean,
//!   for white balance (the grey world: the picture's average is grey) and
//!   exposure.
//! * A photo is demosaiced at the frame's full size (`develop`): each
//!   pixel's missing colours are the means of its neighbours that have
//!   them (bilinear).

const std = @import("std");
const sys = @import("sys");
const v4l2 = sys.v4l2;

pub const Bayer = v4l2.Bayer;

/// A raw frame.
pub const Raw = struct {
    data: []const u8,
    width: u32,
    height: u32,
    /// Bytes from one row to the next.
    stride: u32,
    bayer: Bayer,
    /// 8, or 10 (packed: four samples' top 8 bits, then a byte of their
    /// low 2 bits).
    bits: u8,

    /// The sample at (x, y), its top 8 bits.
    pub fn at(r: Raw, x: u32, y: u32) u8 {
        return sampleAt(r.data[@as(usize, y) * r.stride ..], r.bits, x);
    }

    /// Bytes of pixels in a row of `width` samples.
    pub fn rowBytes(r: Raw) usize {
        return if (r.bits == 8) r.width else (@as(usize, r.width) + 3) / 4 * 5;
    }

    /// Copies row `y` into `dst` and returns the slice of it. V4L2 `MMAP`
    /// capture buffers are mapped by `vb2_dma_contig` as uncached DMA
    /// memory; copying each needed row sequentially into cached stack
    /// memory lets the CPU burst-read a row once instead of stalling the
    /// bus interface on every sample across two or three rows.
    fn copyRow(r: Raw, y: u32, dst: []u8) []const u8 {
        const len = @min(r.rowBytes(), r.stride);
        const src = r.data[@as(usize, y) * r.stride ..][0..len];
        if (len > dst.len) return src;
        const out = dst[0..len];
        @memcpy(out, src);
        return out;
    }
};

/// Enough for a row of up to 6552 10-bit or 8192 8-bit samples.
const max_row_bytes = 8192;

fn sampleAt(row: []const u8, bits: u8, x: u32) u8 {
    return if (bits == 8) row[x] else row[x / 4 * 5 + x % 4];
}

pub const Channel = enum(u2) { r, g, b };

/// The colour of the pixel at (x, y) of a Bayer pattern.
pub fn colourAt(bayer: Bayer, x: u32, y: u32) Channel {
    const odd_x = x & 1 != 0;
    const odd_y = y & 1 != 0;
    // The colour at the top left of each 2x2 block, and diagonally.
    const top_left: Channel, const bottom_right: Channel = switch (bayer) {
        .rggb => .{ .r, .b },
        .bggr => .{ .b, .r },
        .grbg, .gbrg => .{ .g, .g },
    };
    if (odd_x == odd_y) return if (odd_x) bottom_right else top_left;
    return switch (bayer) {
        .rggb, .bggr => .g,
        // Green on the diagonal: red and blue on the others.
        .grbg => if (odd_y) .b else .r,
        .gbrg => if (odd_y) .r else .b,
    };
}

/// How samples become pixels: the black level, and each colour's gain.
pub const Params = struct {
    /// What a sample reads in the dark (8-bit): both Camera Modules' is 64
    /// of 1023.
    black: u8 = 16,
    gains: [3]f32 = .{ 1, 1, 1 },
};

/// Each colour's table from an 8-bit sample to an 8-bit, gamma-encoded
/// value.
pub const Tables = struct {
    t: [3][256]u8,

    pub fn init(p: Params) Tables {
        var out: Tables = undefined;
        const range: f32 = @floatFromInt(255 - @as(u32, p.black));
        for (&out.t, p.gains) |*table, gain| {
            for (table, 0..) |*v, i| {
                const linear = @as(f32, @floatFromInt(@as(i32, @intCast(i)) -| @as(i32, p.black))) / range * gain;
                v.* = @intFromFloat(@round(srgb(std.math.clamp(linear, 0, 1)) * 255));
            }
        }
        return out;
    }
};

/// The sRGB transfer curve: linear light to the encoded value.
pub fn srgb(x: f32) f32 {
    return if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

/// A frame's colours: each one's mean sample, the black level taken off,
/// from 0 to 1.
pub const Stats = struct {
    mean: [3]f32 = .{ 0, 0, 0 },
};

/// The size of the preview of a `width` by `height` frame: every `step`th
/// 2x2 block, the step as small as keeps it within `max_width` by
/// `max_height`.
pub fn previewSize(width: u32, height: u32, max_width: u32, max_height: u32) struct { width: u32, height: u32, step: u32 } {
    var step: u32 = 1;
    while (width / 2 / step > max_width or height / 2 / step > max_height) step += 1;
    return .{ .width = @max(width / 2 / step, 1), .height = @max(height / 2 / step, 1), .step = step };
}

/// Makes the preview of `raw` in `out` (0xffRRGGBB, `width` by `height`
/// from `previewSize`, rows of `width`), and returns the frame's
/// statistics.
pub fn preview(raw: Raw, tables: *const Tables, black: u8, out: []u32, width: u32, height: u32, step: u32) Stats {
    std.debug.assert(out.len >= @as(usize, width) * height);
    // Where each colour is in a 2x2 block (the two greens).
    var pos: [4][2]u32 = undefined;
    var g_n: usize = 0;
    var r_at: [2]u32 = undefined;
    var b_at: [2]u32 = undefined;
    for (0..2) |y| for (0..2) |x| switch (colourAt(raw.bayer, @intCast(x), @intCast(y))) {
        .r => r_at = .{ @intCast(x), @intCast(y) },
        .b => b_at = .{ @intCast(x), @intCast(y) },
        .g => {
            pos[g_n] = .{ @intCast(x), @intCast(y) };
            g_n += 1;
        },
    };
    var row_buf: [2][max_row_bytes]u8 = undefined;
    var sums: [3]u64 = .{ 0, 0, 0 };
    for (0..height) |oy| {
        const by: u32 = @intCast(oy * step * 2);
        const rows = [2][]const u8{
            raw.copyRow(by, &row_buf[0]),
            raw.copyRow(by + 1, &row_buf[1]),
        };
        const r_row = rows[r_at[1]];
        const g0_row = rows[pos[0][1]];
        const g1_row = rows[pos[1][1]];
        const b_row = rows[b_at[1]];
        const row = out[oy * width ..][0..width];
        for (row, 0..) |*o, ox| {
            const bx: u32 = @intCast(ox * step * 2);
            const r = sampleAt(r_row, raw.bits, bx + r_at[0]);
            const g: u8 = @intCast((@as(u32, sampleAt(g0_row, raw.bits, bx + pos[0][0])) + sampleAt(g1_row, raw.bits, bx + pos[1][0]) + 1) / 2);
            const b = sampleAt(b_row, raw.bits, bx + b_at[0]);
            sums[0] += r -| black;
            sums[1] += g -| black;
            sums[2] += b -| black;
            o.* = 0xff000000 | @as(u32, tables.t[0][r]) << 16 | @as(u32, tables.t[1][g]) << 8 | tables.t[2][b];
        }
    }
    const n: f32 = @floatFromInt(@as(u64, width) * height * (255 - @as(u64, black)));
    return .{ .mean = .{ @as(f32, @floatFromInt(sums[0])) / n, @as(f32, @floatFromInt(sums[1])) / n, @as(f32, @floatFromInt(sums[2])) / n } };
}

/// Demosaics all of `raw` into `out` (0xffRRGGBB, rows of `raw.width`).
pub fn develop(raw: Raw, tables: *const Tables, out: []u32) void {
    std.debug.assert(out.len >= @as(usize, raw.width) * raw.height);
    const w = raw.width;
    const h = raw.height;
    var row_buf: [3][max_row_bytes]u8 = undefined;
    var row_slice: [3][]const u8 = undefined;
    var cached_y: [3]u32 = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) };
    for (0..h) |yi| {
        const y: u32 = @intCast(yi);
        const ys = [3]u32{
            mirror(@as(i32, @intCast(y)) - 1, h),
            y,
            mirror(@as(i32, @intCast(y)) + 1, h),
        };
        var rows: [3][]const u8 = undefined;
        for (ys, 0..) |ry, i| {
            const slot = ry % 3;
            if (cached_y[slot] != ry) {
                row_slice[slot] = raw.copyRow(ry, &row_buf[slot]);
                cached_y[slot] = ry;
            }
            rows[i] = row_slice[slot];
        }
        for (0..w) |xi| {
            const x: u32 = @intCast(xi);
            var v: [3]u32 = undefined;
            const own = colourAt(raw.bayer, x, y);
            v[@intFromEnum(own)] = sampleAt(rows[1], raw.bits, x);
            // The others: the means of the nearest that have them (within
            // the 3x3 around it, the edges mirrored).
            var sum: [3]u32 = .{ 0, 0, 0 };
            var count: [3]u32 = .{ 0, 0, 0 };
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                const di: usize = @intCast(dy + 1);
                const ny = ys[di];
                const r_row = rows[di];
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const nx = mirror(@as(i32, @intCast(x)) + dx, w);
                    const c = colourAt(raw.bayer, nx, ny);
                    if (c == own) continue;
                    // Green's nearest are beside it, not diagonal.
                    if (c == .g and dx != 0 and dy != 0) continue;
                    sum[@intFromEnum(c)] += sampleAt(r_row, raw.bits, nx);
                    count[@intFromEnum(c)] += 1;
                }
            }
            for (0..3) |ci| if (ci != @intFromEnum(own)) {
                v[ci] = if (count[ci] > 0) (sum[ci] + count[ci] / 2) / count[ci] else 0;
            };
            out[yi * w + xi] = 0xff000000 | @as(u32, tables.t[0][v[0]]) << 16 | @as(u32, tables.t[1][v[1]]) << 8 | tables.t[2][v[2]];
        }
    }
}

/// A coordinate reflected back inside 0..n (for 2x2 patterns, a mirror
/// two away keeps the colour: -1 becomes 1).
fn mirror(i: i32, n: u32) u32 {
    if (i < 0) return @intCast(-i);
    if (i >= n) return @intCast(2 * @as(i32, @intCast(n)) - 2 - i);
    return @intCast(i);
}

/// White balance by the grey world: gains that make the colours' means
/// (the raw samples', before any gain) equal, green's staying 1, moved
/// part of the way from `current` each frame so the picture does not
/// flicker, and kept within reason (a frame of one colour would otherwise
/// be made grey).
pub fn greyWorld(current: [3]f32, stats: Stats) [3]f32 {
    const g = stats.mean[1];
    if (g < 0.01) return current;
    var out = current;
    for ([_]usize{ 0, 2 }) |c| {
        if (stats.mean[c] < 0.002) continue;
        const want = std.math.clamp(g / stats.mean[c], 0.5, 4);
        out[c] = current[c] + (want - current[c]) * 0.2;
    }
    return out;
}

const testing = std.testing;

test "Bayer patterns' colours" {
    try testing.expectEqual(Channel.r, colourAt(.rggb, 0, 0));
    try testing.expectEqual(Channel.g, colourAt(.rggb, 1, 0));
    try testing.expectEqual(Channel.g, colourAt(.rggb, 0, 1));
    try testing.expectEqual(Channel.b, colourAt(.rggb, 1, 1));
    try testing.expectEqual(Channel.b, colourAt(.bggr, 2, 4));
    try testing.expectEqual(Channel.r, colourAt(.bggr, 3, 5));
    try testing.expectEqual(Channel.g, colourAt(.grbg, 0, 0));
    try testing.expectEqual(Channel.r, colourAt(.grbg, 1, 0));
    try testing.expectEqual(Channel.b, colourAt(.grbg, 0, 1));
    try testing.expectEqual(Channel.b, colourAt(.gbrg, 1, 0));
    try testing.expectEqual(Channel.r, colourAt(.gbrg, 0, 1));
    try testing.expectEqual(Channel.g, colourAt(.gbrg, 1, 1));
}

test "10-bit packed samples: their top 8 bits" {
    // Four samples, then their low bits.
    const data = [_]u8{ 10, 20, 30, 40, 0xff, 50, 60, 70, 80, 0 };
    const raw: Raw = .{ .data = &data, .width = 8, .height = 1, .stride = 10, .bayer = .rggb, .bits = 10 };
    try testing.expectEqual(@as(u8, 30), raw.at(2, 0));
    try testing.expectEqual(@as(u8, 50), raw.at(4, 0));
    try testing.expectEqual(@as(u8, 80), raw.at(7, 0));
}

test "the tables take off the black level, apply the gains and the gamma" {
    const t = Tables.init(.{ .black = 16, .gains = .{ 2, 1, 1 } });
    try testing.expectEqual(@as(u8, 0), t.t[1][16]);
    try testing.expectEqual(@as(u8, 0), t.t[1][0]);
    try testing.expectEqual(@as(u8, 255), t.t[1][255]);
    // Mid-grey, linearly: sRGB's 0.5 encodes about 0.214.
    const mid: u8 = 16 + @as(u8, @intFromFloat(@round(0.214 * 239)));
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(t.t[1][mid])), 1.5);
    // Red's gain of 2 reaches white at half way.
    try testing.expectEqual(@as(u8, 255), t.t[0][16 + 120]);
}

/// A frame of one colour (linear r, g, b, 0 to 1) in `bayer` order, 8-bit
/// with the given black level.
fn flatFrame(buf: []u8, w: u32, h: u32, bayer: Bayer, black: u8, colour: [3]f32) Raw {
    for (0..h) |y| for (0..w) |x| {
        const c = colourAt(bayer, @intCast(x), @intCast(y));
        buf[y * w + x] = black + @as(u8, @intFromFloat(@round(colour[@intFromEnum(c)] * @as(f32, @floatFromInt(255 - @as(u32, black))))));
    };
    return .{ .data = buf, .width = w, .height = h, .stride = w, .bayer = bayer, .bits = 8 };
}

test "the preview: one pixel a block, the statistics, each Bayer order" {
    const colour = [3]f32{ 0.8, 0.4, 0.1 };
    const tables = Tables.init(.{});
    for (std.enums.values(Bayer)) |bayer| {
        var buf: [32 * 16]u8 = undefined;
        const raw = flatFrame(&buf, 32, 16, bayer, 16, colour);
        const size = previewSize(32, 16, 8, 8);
        try testing.expectEqual(@as(u32, 2), size.step);
        try testing.expectEqual(@as(u32, 8), size.width);
        try testing.expectEqual(@as(u32, 4), size.height);
        var out: [8 * 4]u32 = undefined;
        const stats = preview(raw, &tables, 16, &out, size.width, size.height, size.step);
        for (colour, stats.mean) |want, got| try testing.expectApproxEqAbs(want, got, 0.005);
        const px = out[5];
        try testing.expectApproxEqAbs(srgb(0.8) * 255, @as(f32, @floatFromInt(px >> 16 & 0xff)), 1.5);
        try testing.expectApproxEqAbs(srgb(0.4) * 255, @as(f32, @floatFromInt(px >> 8 & 0xff)), 1.5);
        try testing.expectApproxEqAbs(srgb(0.1) * 255, @as(f32, @floatFromInt(px & 0xff)), 1.5);
    }
}

test "developing a photo: every pixel gets all three colours" {
    const colour = [3]f32{ 0.2, 0.6, 0.9 };
    const tables = Tables.init(.{});
    for (std.enums.values(Bayer)) |bayer| {
        var buf: [10 * 6]u8 = undefined;
        const raw = flatFrame(&buf, 10, 6, bayer, 16, colour);
        var out: [10 * 6]u32 = undefined;
        develop(raw, &tables, &out);
        // A flat frame stays flat, edges and corners too.
        for (out) |px| {
            try testing.expectApproxEqAbs(srgb(0.2) * 255, @as(f32, @floatFromInt(px >> 16 & 0xff)), 1.5);
            try testing.expectApproxEqAbs(srgb(0.6) * 255, @as(f32, @floatFromInt(px >> 8 & 0xff)), 1.5);
            try testing.expectApproxEqAbs(srgb(0.9) * 255, @as(f32, @floatFromInt(px & 0xff)), 1.5);
        }
    }
}

test "the grey world balances the colours, a little at a time" {
    var gains = [3]f32{ 1, 1, 1 };
    // A bluish picture: blue's gain comes down, red's goes up.
    for (0..40) |_| gains = greyWorld(gains, .{ .mean = .{ 0.2, 0.3, 0.45 } });
    try testing.expectApproxEqAbs(@as(f32, 1.5), gains[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.667), gains[2], 0.01);
    try testing.expectEqual(@as(f32, 1), gains[1]);
    // In the dark, they stay.
    try testing.expectEqual(gains, greyWorld(gains, .{ .mean = .{ 0, 0.001, 0 } }));
}
