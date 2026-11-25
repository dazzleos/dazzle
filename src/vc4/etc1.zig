//! ETC1 compressed textures: 4 bits a pixel (an eighth of a 32-bit
//! texture, a quarter of RGB565), which the VideoCore IV's texture unit
//! decodes as it samples. For pictures the CPU makes once and the GPU
//! shows for long after: the desktop's background.
//!
//! Each 4x4 block of pixels is 64 bits: two halves (side by side, or one
//! above the other: "flipped"), each a base colour and one of eight tables
//! of brightness changes, and per pixel which of the table's four changes
//! it takes. `encode` picks them; `decodeBlock` undoes them (for tests).
//!
//! The texture unit lays the blocks out as it would 64-bit pixels: the
//! image is (width / 4) by (height / 4) blocks, tiled (`upload`).

const std = @import("std");
const texture = @import("texture.zig");

/// The brightness changes of each table (and their negatives).
const tables = [8][2]i32{ .{ 2, 8 }, .{ 5, 17 }, .{ 9, 29 }, .{ 13, 42 }, .{ 18, 60 }, .{ 24, 80 }, .{ 33, 106 }, .{ 47, 183 } };

/// A pixel's index (2 bits: its high bit, then low) to its change.
fn change(table: u3, index: u2) i32 {
    const t = tables[table];
    return switch (index) {
        0 => t[0],
        1 => t[1],
        2 => -t[0],
        3 => -t[1],
    };
}

fn clamp255(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Blocks across and down for an image `width` by `height`.
pub fn blocksOf(width: u32, height: u32) [2]u32 {
    return .{ (width + 3) / 4, (height + 3) / 4 };
}

/// The colour at (x, y) of `pixels` (0xAARRGGBB rows, `width` wide), as
/// RGB, the edge repeated past the image.
fn rgbAt(pixels: []const u32, width: u32, height: u32, x: u32, y: u32) [3]i32 {
    const px = pixels[@min(y, height - 1) * width + @min(x, width - 1)];
    return .{ @intCast(px >> 16 & 0xff), @intCast(px >> 8 & 0xff), @intCast(px & 0xff) };
}

/// Whether pixel (x, y) of a block is in its second half.
fn inSecond(flip: bool, x: u32, y: u32) bool {
    return if (flip) y >= 2 else x >= 2;
}

/// A half block's choice: its table and each pixel's index, and the error.
const HalfFit = struct { table: u3, indices: [16]u2, err: u64 };

/// The best table and indices for the pixels of one half (`which`), given
/// its base colour.
fn fitHalf(block: *const [16][3]i32, flip: bool, which: bool, base: [3]i32) HalfFit {
    var best: HalfFit = .{ .table = 0, .indices = @splat(0), .err = std.math.maxInt(u64) };
    for (0..8) |ti| {
        const table: u3 = @intCast(ti);
        var fit: HalfFit = .{ .table = table, .indices = @splat(0), .err = 0 };
        for (0..16) |p| {
            const x: u32 = @intCast(p % 4);
            const y: u32 = @intCast(p / 4);
            if (inSecond(flip, x, y) != which) continue;
            var least: u64 = std.math.maxInt(u64);
            for (0..4) |ii| {
                const idx: u2 = @intCast(ii);
                const d = change(table, idx);
                var e: u64 = 0;
                for (0..3) |c| {
                    const diff = @as(i64, clamp255(base[c] + d)) - block[p][c];
                    e += @intCast(diff * diff);
                }
                if (e < least) {
                    least = e;
                    fit.indices[p] = idx;
                }
            }
            fit.err += least;
            if (fit.err >= best.err) break;
        }
        if (fit.err < best.err) best = fit;
    }
    return best;
}

/// The average colour of a half.
fn average(block: *const [16][3]i32, flip: bool, which: bool) [3]i32 {
    var sum: [3]i32 = .{ 0, 0, 0 };
    for (0..16) |p| {
        if (inSecond(flip, @intCast(p % 4), @intCast(p / 4)) != which) continue;
        for (0..3) |c| sum[c] += block[p][c];
    }
    return .{ @divTrunc(sum[0] + 4, 8), @divTrunc(sum[1] + 4, 8), @divTrunc(sum[2] + 4, 8) };
}

/// Encodes one block (16 pixels, row by row, as RGB): its 64 bits, the
/// first byte of the standard layout in the top 8.
pub fn encodeBlock(block: *const [16][3]i32) u64 {
    var best_bits: u64 = 0;
    var best_err: u64 = std.math.maxInt(u64);
    for ([_]bool{ false, true }) |flip| {
        const avg = [2][3]i32{ average(block, flip, false), average(block, flip, true) };
        // Differential (5 bits for the first colour, and the second within
        // -4..3 of it) when the halves are near enough; otherwise each its
        // own 4 bits.
        var q5: [2][3]i32 = undefined;
        for (0..2) |h| for (0..3) |c| {
            q5[h][c] = @divTrunc(avg[h][c] * 31 + 127, 255);
        };
        var differential = true;
        for (0..3) |c| {
            const d = q5[1][c] - q5[0][c];
            if (d < -4 or d > 3) differential = false;
        }
        var base: [2][3]i32 = undefined;
        var bits: u64 = 0;
        if (differential) {
            for (0..2) |h| for (0..3) |c| {
                base[h][c] = (q5[h][c] << 3) | (q5[h][c] >> 2);
            };
            for (0..3) |c| {
                const shift: u6 = @intCast(59 - 8 * c);
                bits |= @as(u64, @intCast(q5[0][c])) << shift;
                const d: u3 = @bitCast(@as(i3, @intCast(q5[1][c] - q5[0][c])));
                bits |= @as(u64, d) << (shift - 3);
            }
            bits |= 1 << 33;
        } else {
            for (0..2) |h| for (0..3) |c| {
                const q4 = @divTrunc(avg[h][c] * 15 + 127, 255);
                base[h][c] = q4 * 17;
                const shift: u6 = @intCast(60 - 8 * c - 4 * h);
                bits |= @as(u64, @intCast(q4)) << shift;
            };
        }
        if (flip) bits |= 1 << 32;
        const fits = [2]HalfFit{ fitHalf(block, flip, false, base[0]), fitHalf(block, flip, true, base[1]) };
        const err = fits[0].err + fits[1].err;
        if (err >= best_err) continue;
        bits |= @as(u64, fits[0].table) << 37;
        bits |= @as(u64, fits[1].table) << 34;
        for (0..16) |p| {
            const x = p % 4;
            const y = p / 4;
            const idx = fits[@intFromBool(inSecond(flip, @intCast(x), @intCast(y)))].indices[p];
            // Pixels are numbered down the columns.
            const n: u6 = @intCast(x * 4 + y);
            bits |= @as(u64, idx >> 1) << (16 + n);
            bits |= @as(u64, idx & 1) << n;
        }
        best_bits = bits;
        best_err = err;
    }
    return best_bits;
}

/// Decodes one block to 16 pixels (0xffRRGGBB, row by row).
pub fn decodeBlock(bits: u64) [16]u32 {
    const flip = bits >> 32 & 1 != 0;
    var base: [2][3]i32 = undefined;
    if (bits >> 33 & 1 != 0) {
        for (0..3) |c| {
            const shift: u6 = @intCast(59 - 8 * c);
            const c5: i32 = @intCast(bits >> shift & 31);
            const d: i32 = @as(i3, @bitCast(@as(u3, @intCast(bits >> (shift - 3) & 7))));
            const c5b = c5 + d;
            base[0][c] = (c5 << 3) | (c5 >> 2);
            base[1][c] = (c5b << 3) | (c5b >> 2);
        }
    } else {
        for (0..2) |h| for (0..3) |c| {
            const shift: u6 = @intCast(60 - 8 * c - 4 * h);
            base[h][c] = @as(i32, @intCast(bits >> shift & 15)) * 17;
        };
    }
    const table = [2]u3{ @intCast(bits >> 37 & 7), @intCast(bits >> 34 & 7) };
    var out: [16]u32 = undefined;
    for (0..16) |p| {
        const x = p % 4;
        const y = p / 4;
        const n: u6 = @intCast(x * 4 + y);
        const idx: u2 = @intCast((bits >> (16 + n) & 1) << 1 | (bits >> n & 1));
        const h = @intFromBool(inSecond(flip, @intCast(x), @intCast(y)));
        const d = change(table[h], idx);
        out[p] = 0xff000000 | @as(u32, clamp255(base[h][0] + d)) << 16 | @as(u32, clamp255(base[h][1] + d)) << 8 | clamp255(base[h][2] + d);
    }
    return out;
}

/// Encodes `pixels` (0xAARRGGBB rows, `width` by `height`; alpha is
/// dropped) to blocks, row by row, into `out` (`blocksOf` long).
pub fn encode(pixels: []const u32, width: u32, height: u32, out: []u64) void {
    const n = blocksOf(width, height);
    std.debug.assert(out.len >= n[0] * n[1]);
    for (0..n[1]) |by| for (0..n[0]) |bx| {
        var block: [16][3]i32 = undefined;
        for (0..16) |p| block[p] = rgbAt(pixels, width, height, @intCast(bx * 4 + p % 4), @intCast(by * 4 + p / 4));
        out[by * n[0] + bx] = encodeBlock(&block);
    };
}

/// How a block's 64 bits are stored, a byte at a time: the first byte of
/// the standard layout first (as files hold it), or last; and whether its
/// red and blue are exchanged (`swapRedBlue`). A Pi 3's GPU takes the
/// standard order, but returns the colour it decodes with red where
/// Dazzle's 32-bit textures have blue: given blocks with red and blue
/// exchanged, it returns them as they should be (exchanging them costs
/// nothing, where the shader would have to on every pixel).
pub const ByteOrder = enum {
    standard,
    reversed,
    standard_blue_red,
    reversed_blue_red,

    fn swapped(o: ByteOrder) bool {
        return o == .standard_blue_red or o == .reversed_blue_red;
    }
};

/// The block with its red and blue exchanged. In both of ETC1's modes a
/// block's first byte holds red's base colour(s) and its third blue's,
/// the same way, and the brightness changes apply to every channel alike:
/// exchanging the two bytes exchanges the colours.
pub fn swapRedBlue(b: u64) u64 {
    const red = (b >> 56) & 0xff;
    const blue = (b >> 40) & 0xff;
    return (b & ~@as(u64, 0xff00_ff00_0000_0000)) | blue << 56 | red << 40;
}

/// The bytes a texture of `width` by `height` pixels takes, laid out by
/// `upload`: as an image of 64-bit "pixels", a block each (the kernel
/// checks it the same way), in the GPU's layout (see texture.zig).
pub fn imageSize(width: u32, height: u32) u32 {
    const n = blocksOf(width, height);
    return texture.imageSizeOf(.etc1, n[0], n[1]);
}

/// Byte offset of block (bx, by) in an image `bw` blocks wide (and `bh`
/// high), as the texture unit reads it.
pub fn blockOffset(bw: u32, bh: u32, bx: u32, by: u32) u32 {
    return texture.texelOffsetOf(.etc1, bw, bh, bx, by);
}

/// Writes `blocks` (row by row, from `encode`) for an image `width` by
/// `height` into `dst` (`imageSize` bytes), as the texture unit reads it.
pub fn upload(dst: []u8, width: u32, height: u32, blocks: []const u64, order: ByteOrder) void {
    std.debug.assert(dst.len >= imageSize(width, height));
    const n = blocksOf(width, height);
    for (0..n[1]) |by| for (0..n[0]) |bx| {
        const at = blockOffset(n[0], n[1], @intCast(bx), @intCast(by));
        const b = if (order.swapped()) swapRedBlue(blocks[by * n[0] + bx]) else blocks[by * n[0] + bx];
        switch (order) {
            .standard, .standard_blue_red => std.mem.writeInt(u64, dst[at..][0..8], b, .big),
            .reversed, .reversed_blue_red => std.mem.writeInt(u64, dst[at..][0..8], b, .little),
        }
    };
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

fn channelError(a: u32, b: u32) u32 {
    var most: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const x: i32 = @intCast(a >> shift & 0xff);
        const y: i32 = @intCast(b >> shift & 0xff);
        most = @max(most, @abs(x - y));
    }
    return most;
}

test "a flat block comes back as its colour, near enough" {
    for ([_]u32{ 0xff000000, 0xffffffff, 0xff336699, 0xff80c020 }) |color| {
        var block: [16][3]i32 = undefined;
        for (&block) |*p| p.* = .{ @intCast(color >> 16 & 0xff), @intCast(color >> 8 & 0xff), @intCast(color & 0xff) };
        const out = decodeBlock(encodeBlock(&block));
        for (out) |px| try testing.expect(channelError(px, color) <= 6);
    }
}

test "halves of different colours, side by side or one above the other, are kept apart" {
    // Left red, right blue; then top green, bottom grey.
    var block: [16][3]i32 = undefined;
    for (0..16) |p| block[p] = if (p % 4 < 2) .{ 200, 30, 30 } else .{ 30, 30, 200 };
    var out = decodeBlock(encodeBlock(&block));
    try testing.expect(channelError(out[0], 0xffc81e1e) <= 12);
    try testing.expect(channelError(out[3], 0xff1e1ec8) <= 12);
    for (0..16) |p| block[p] = if (p / 4 < 2) .{ 40, 200, 40 } else .{ 120, 120, 120 };
    out = decodeBlock(encodeBlock(&block));
    try testing.expect(channelError(out[0], 0xff28c828) <= 12);
    try testing.expect(channelError(out[15], 0xff787878) <= 12);
}

test "a smooth image comes back close to itself" {
    const w = 64;
    const h = 48;
    var pixels: [w * h]u32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const r: u32 = @intCast(x * 255 / (w - 1));
        const g: u32 = @intCast(y * 255 / (h - 1));
        pixels[y * w + x] = 0xff000000 | r << 16 | g << 8 | 128;
    };
    var blocks: [16 * 12]u64 = undefined;
    encode(&pixels, w, h, &blocks);
    var total: u64 = 0;
    for (0..12) |by| for (0..16) |bx| {
        const out = decodeBlock(blocks[by * 16 + bx]);
        for (0..16) |p| {
            const e = channelError(out[p], pixels[(by * 4 + p / 4) * w + bx * 4 + p % 4]);
            try testing.expect(e <= 16);
            total += e;
        }
    };
    // On average, a few levels out.
    try testing.expect(total / (w * h) <= 5);
}

test "blocks are laid out as 64-bit pixels: micro-tiles of 2 by 4, in 4 KB tiles" {
    // A big image is tiled: each block somewhere of its own, within it.
    const w = 640;
    const h = 480;
    const n = blocksOf(w, h);
    const size = imageSize(w, h);
    try testing.expectEqual(@as(u32, 160 * 128 * 8), size);
    const seen = try testing.allocator.alloc(bool, size / 8);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    for (0..n[1]) |by| for (0..n[0]) |bx| {
        const at = blockOffset(n[0], n[1], @intCast(bx), @intCast(by));
        try testing.expect(at % 8 == 0 and at + 8 <= size);
        try testing.expect(!seen[at / 8]);
        seen[at / 8] = true;
    };
    // A micro-tile: two across, then the next row of it.
    try testing.expectEqual(@as(u32, 8), blockOffset(n[0], n[1], 1, 0));
    try testing.expectEqual(@as(u32, 16), blockOffset(n[0], n[1], 0, 1));
    try testing.expectEqual(@as(u32, 64), blockOffset(n[0], n[1], 2, 0));
    // A small one is in linear micro-tiles.
    try testing.expectEqual(@as(u32, 4 * 4 * 8), imageSize(16, 16));
    try testing.expectEqual(@as(u32, 64), blockOffset(4, 4, 2, 0));
    // Its next row of micro-tiles follows the first (two of them, 32 bytes
    // a row of blocks, four rows).
    try testing.expectEqual(@as(u32, 128), blockOffset(4, 8, 0, 4));
}

test "a block's bytes are stored first byte first, or reversed" {
    var dst: [imageSize(4, 4)]u8 = undefined;
    upload(&dst, 4, 4, &.{0x0102030405060708}, .standard);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, dst[0..8]);
    upload(&dst, 4, 4, &.{0x0102030405060708}, .reversed);
    try testing.expectEqualSlices(u8, &.{ 8, 7, 6, 5, 4, 3, 2, 1 }, dst[0..8]);
}

test "exchanging a block's red and blue exchanges its colours" {
    for ([_]u32{ 0xffff0000, 0xff2080c0, 0xff10f020 }) |color| {
        var px: [16]u32 = @splat(color);
        var blocks: [1]u64 = undefined;
        encode(&px, 4, 4, &blocks);
        const swapped = decodeBlock(swapRedBlue(blocks[0]));
        const plain = decodeBlock(blocks[0]);
        for (swapped, plain) |a, b| {
            try testing.expectEqual(b >> 16 & 0xff, a & 0xff);
            try testing.expectEqual(b & 0xff, a >> 16 & 0xff);
            try testing.expectEqual(b >> 8 & 0xff, a >> 8 & 0xff);
        }
    }
}
