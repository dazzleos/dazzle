//! Texture memory layout and texture unit configuration for the V3D.
//!
//! The texture unit reads 32-bit RGBA textures in one of two tiled layouts:
//!
//! * LT ("linear tile") for small images (either dimension at most 4
//!   micro-tiles): a raster-order grid of 4x4-pixel, 64-byte micro-tiles.
//! * T for everything else: 4 KB tiles of 32x32 pixels, each made of four
//!   1 KB sub-tiles of 4x4 micro-tiles, with tile rows alternating
//!   direction and sub-tile order depending on the row.
//!
//! The kernel decides which layout the hardware uses from the size alone
//! (vc4_validate.c, size_is_lt) and checks that the buffer is big enough,
//! so uploads here must agree with it exactly. Mipmaps are not supported
//! yet.
//!
//! Reference: Mesa src/gallium/drivers/vc4/vc4_tiling.c.

const std = @import("std");

pub const Type = enum(u5) {
    rgba8888 = 0,
    rgbx8888 = 1,
    rgba4444 = 2,
    rgba5551 = 3,
    rgb565 = 4,
    luminance = 5,
    alpha = 6,
    lumalpha = 7,
    etc1 = 8,
    s16f = 9,
    s8 = 10,
    s16 = 11,
    bw1 = 12,
    a4 = 13,
    a1 = 14,
    rgba64 = 15,
    rgba32r = 16,
    yuv422r = 17,
    _,
};

pub const Filter = enum { linear, nearest };
pub const Wrap = enum(u2) { repeat = 0, clamp = 1, mirror = 2, border = 3 };

pub const Config = struct {
    /// Byte offset of the image in its buffer; must be 4 KB aligned.
    offset: u32 = 0,
    type: Type = .rgba8888,
    width: u32,
    height: u32,
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    wrap_s: Wrap = .repeat,
    wrap_t: Wrap = .repeat,
};

/// Texture config parameter 0: image offset, type and mip levels. The
/// kernel adds the buffer's physical address when relocating it.
pub fn p0(c: Config) u32 {
    std.debug.assert(c.offset & 0xfff == 0);
    return c.offset | (@as(u32, @intFromEnum(c.type)) & 0xf) << 4;
}

/// Texture config parameter 1: size, filtering and wrapping.
pub fn p1(c: Config) u32 {
    const min: u32 = switch (c.min_filter) {
        .linear => 0,
        .nearest => 1,
    };
    const mag: u32 = switch (c.mag_filter) {
        .linear => 0,
        .nearest => 1,
    };
    return (@as(u32, @intFromEnum(c.type)) >> 4) << 31 |
        (c.height & 2047) << 20 |
        (c.width & 2047) << 8 |
        mag << 7 |
        min << 4 |
        @as(u32, @intFromEnum(c.wrap_t)) << 2 |
        @as(u32, @intFromEnum(c.wrap_s));
}

pub fn decodeConfig(param0: u32, param1: u32) Config {
    const w = (param1 >> 8) & 2047;
    const h = (param1 >> 20) & 2047;
    return .{
        .offset = param0 & 0xfffff000,
        .type = @enumFromInt(((param0 >> 4) & 0xf) | ((param1 >> 31) << 4)),
        .width = if (w == 0) 2048 else w,
        .height = if (h == 0) 2048 else h,
        .mag_filter = if ((param1 >> 7) & 1 != 0) .nearest else .linear,
        .min_filter = switch ((param1 >> 4) & 7) {
            1 => .nearest,
            else => .linear,
        },
        .wrap_t = @enumFromInt(@as(u2, @truncate(param1 >> 2))),
        .wrap_s = @enumFromInt(@as(u2, @truncate(param1))),
    };
}

const cpp = 4;
const utile_w = 4;
const utile_h = 4;

/// Whether the hardware treats an image of this size as LT rather than T.
pub fn isLt(width: u32, height: u32) bool {
    return width <= 4 * utile_w or height <= 4 * utile_h;
}

/// Bytes needed for a 32-bit-per-pixel image, padded the way the kernel's
/// vc4_check_tex_size() expects.
pub fn imageSize(width: u32, height: u32) u32 {
    if (isLt(width, height)) {
        return std.mem.alignForward(u32, width, utile_w) * std.mem.alignForward(u32, height, utile_h) * cpp;
    }
    return std.mem.alignForward(u32, width, 8 * utile_w) * std.mem.alignForward(u32, height, 8 * utile_h) * cpp;
}

/// Byte offset of the 1 KB sub-tile containing micro-tile (utile_x,
/// utile_y) in a T image `utile_stride` micro-tiles wide.
fn tSubtileOffset(utile_x: u32, utile_y: u32, utile_stride: u32) u32 {
    const tile_stride = utile_stride / 8;
    var tile_x = utile_x / 8;
    const tile_y = utile_y / 8;
    const odd_row = tile_y & 1 != 0;
    // Odd rows of 4 KB tiles run right to left.
    if (odd_row) tile_x = tile_stride - tile_x - 1;
    const tile_offset = 4096 * (tile_y * tile_stride + tile_x);

    const stile_index = ((utile_y / 4) & 1) << 1 | ((utile_x / 4) & 1);
    const odd_map = [4]u32{ 2, 1, 3, 0 };
    const even_map = [4]u32{ 0, 3, 1, 2 };
    return tile_offset + 1024 * (if (odd_row) odd_map else even_map)[stile_index];
}

/// Byte offset of pixel (x, y) in a tiled 32-bit image.
pub fn texelOffset(width: u32, height: u32, x: u32, y: u32) u32 {
    const in_utile = ((y % utile_h) * utile_w + x % utile_w) * cpp;
    if (isLt(width, height)) {
        const row_stride = std.mem.alignForward(u32, width, utile_w) * cpp;
        return (y - y % utile_h) * row_stride + (x / utile_w) * 64 + in_utile;
    }
    const utile_stride = std.mem.alignForward(u32, width, 8 * utile_w) / utile_w;
    const utile_x = x / utile_w;
    const utile_y = y / utile_h;
    // Within a sub-tile, micro-tiles are a 4x4 raster-order grid.
    const in_subtile = ((utile_y % 4) * 4 + utile_x % 4) * 64;
    return tSubtileOffset(utile_x & ~@as(u32, 3), utile_y & ~@as(u32, 3), utile_stride) + in_subtile + in_utile;
}

/// Copies a raster-order 32-bit image (rows of `width` pixels) into `dst`
/// in the layout the texture unit expects.
pub fn upload(dst: []u8, pixels: []const u32, width: u32, height: u32) void {
    std.debug.assert(dst.len >= imageSize(width, height));
    for (0..height) |y| {
        for (0..width) |x| {
            const off = texelOffset(width, height, @intCast(x), @intCast(y));
            std.mem.writeInt(u32, dst[off..][0..4], pixels[y * width + x], .little);
        }
    }
}

const testing = std.testing;

test "config round trip" {
    const c: Config = .{ .offset = 0x3000, .width = 128, .height = 64, .mag_filter = .nearest, .min_filter = .nearest, .wrap_s = .clamp };
    const d = decodeConfig(p0(c), p1(c));
    try testing.expectEqual(c.offset, d.offset);
    try testing.expectEqual(c.type, d.type);
    try testing.expectEqual(c.width, d.width);
    try testing.expectEqual(c.height, d.height);
    try testing.expectEqual(c.mag_filter, d.mag_filter);
    try testing.expectEqual(c.min_filter, d.min_filter);
    try testing.expectEqual(c.wrap_s, d.wrap_s);
    try testing.expectEqual(c.wrap_t, d.wrap_t);
}

test "layout matches the reference description" {
    const sim = @import("qpu_sim.zig");
    const sizes = [_][2]u32{ .{ 16, 16 }, .{ 8, 64 }, .{ 64, 64 }, .{ 128, 96 }, .{ 96, 128 }, .{ 256, 256 } };
    for (sizes) |sz| {
        var y: u32 = 0;
        while (y < sz[1]) : (y += 1) {
            var x: u32 = 0;
            while (x < sz[0]) : (x += 1) {
                try testing.expectEqual(sim.referenceTexelOffset(sz[0], sz[1], x, y), texelOffset(sz[0], sz[1], x, y));
            }
        }
    }
}

test "every texel lands in a distinct slot inside the image" {
    const w = 96;
    const h = 64;
    var seen = [_]bool{false} ** (imageSize(w, h) / 4);
    for (0..h) |y| for (0..w) |x| {
        const off = texelOffset(w, h, @intCast(x), @intCast(y));
        try testing.expect(off % 4 == 0 and off / 4 < seen.len);
        try testing.expect(!seen[off / 4]);
        seen[off / 4] = true;
    };
}
