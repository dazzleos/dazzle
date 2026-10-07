//! Texture memory layout and texture unit configuration for the V3D.
//!
//! The texture unit reads textures in one of two tiled layouts, made of
//! 64-byte micro-tiles (4x4 pixels of 32 bits, 8x4 of 16, 8x8 of 8):
//!
//! * LT ("linear tile") for small images (either dimension at most 4
//!   micro-tiles): a raster-order grid of micro-tiles.
//! * T for everything else: 4 KB tiles of 8x8 micro-tiles (32x32 pixels of
//!   32 bits, 64x32 of 16, 64x64 of 8), each made of four 1 KB sub-tiles of 4x4
//!   micro-tiles, with tile rows alternating direction and sub-tile order
//!   depending on the row.
//!
//! The functions without a format are for 32-bit images.
//!
//! The kernel decides which layout the hardware uses from the size alone
//! (vc4_validate.c, size_is_lt) and checks that the buffer is big enough,
//! so uploads here must agree with it exactly. Mipmaps are not supported
//! yet.
//!
//! Reference: Mesa src/gallium/drivers/vc4/vc4_tiling.c.

const std = @import("std");
const Format = @import("format.zig").Format;

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

/// Whether the hardware treats a 32-bit image of this size as LT rather
/// than T.
pub fn isLt(width: u32, height: u32) bool {
    return isLtOf(.xrgb8888, width, height);
}

pub fn isLtOf(format: Format, width: u32, height: u32) bool {
    return width <= 4 * format.utileWidth() or height <= 4 * format.utileHeight();
}

/// Bytes needed for a 32-bit-per-pixel image, padded the way the kernel's
/// vc4_check_tex_size() expects.
pub fn imageSize(width: u32, height: u32) u32 {
    return imageSizeOf(.xrgb8888, width, height);
}

pub fn imageSizeOf(format: Format, width: u32, height: u32) u32 {
    const uw = format.utileWidth();
    const uh = format.utileHeight();
    const cpp = format.bytesPerPixel();
    if (isLtOf(format, width, height)) {
        return std.mem.alignForward(u32, width, uw) * std.mem.alignForward(u32, height, uh) * cpp;
    }
    return std.mem.alignForward(u32, width, 8 * uw) * std.mem.alignForward(u32, height, 8 * uh) * cpp;
}

/// Bytes from one row of pixels to the next in a tiled image, as DRM
/// framebuffers and dma-bufs give it: the width padded to whole tiles
/// (micro-tiles for LT), times the bytes per pixel. For T images that is
/// 128 bytes per tile across, whatever the format.
pub fn tiledPitch(format: Format, width: u32, height: u32) u32 {
    const uw = format.utileWidth();
    const align_w = if (isLtOf(format, width, height)) uw else 8 * uw;
    return std.mem.alignForward(u32, width, align_w) * format.bytesPerPixel();
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
    return texelOffsetOf(.xrgb8888, width, height, x, y);
}

pub fn texelOffsetOf(format: Format, width: u32, height: u32, x: u32, y: u32) u32 {
    const uw = format.utileWidth();
    const uh = format.utileHeight();
    const cpp = format.bytesPerPixel();
    const in_utile = ((y % uh) * uw + x % uw) * cpp;
    if (isLtOf(format, width, height)) {
        const row_stride = std.mem.alignForward(u32, width, uw) * cpp;
        return (y - y % uh) * row_stride + (x / uw) * 64 + in_utile;
    }
    const utile_stride = std.mem.alignForward(u32, width, 8 * uw) / uw;
    const utile_x = x / uw;
    const utile_y = y / uh;
    // Within a sub-tile, micro-tiles are a 4x4 raster-order grid.
    const in_subtile = ((utile_y % 4) * 4 + utile_x % 4) * 64;
    return tSubtileOffset(utile_x & ~@as(u32, 3), utile_y & ~@as(u32, 3), utile_stride) + in_subtile + in_utile;
}

/// Copies a raster-order 32-bit image (rows of `width` pixels) into `dst`
/// in the layout the texture unit expects.
pub fn upload(dst: []u8, pixels: []const u32, width: u32, height: u32) void {
    uploadRect(dst, width, height, .{ .x = 0, .y = 0, .width = width, .height = height }, pixels, width);
}

pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

/// Writes 32-bit pixels into a rectangle of a tiled image. `pixels` holds
/// the rectangle's rows, `stride` pixels apart.
pub fn uploadRect(dst: []u8, width: u32, height: u32, rect: Rect, pixels: []align(1) const u32, stride: u32) void {
    uploadRectOf(.xrgb8888, dst, width, height, rect, std.mem.sliceAsBytes(pixels), stride * 4);
}

/// Writes pixels of `format` into a rectangle of a tiled image. `src`
/// holds the rectangle's rows, `stride` bytes apart.
///
/// Images are written a micro-tile at a time: its 4 rows are 64
/// contiguous bytes, so each row is one 16-byte copy and the tiled address
/// is worked out once per micro-tile. That keeps uploads fast, and writes
/// to GPU buffers (mapped write-combined) whole cache lines at a time.
pub fn uploadRectOf(format: Format, dst: []u8, width: u32, height: u32, rect: Rect, src: []const u8, stride: u32) void {
    std.debug.assert(dst.len >= imageSizeOf(format, width, height));
    std.debug.assert(rect.x + rect.width <= width and rect.y + rect.height <= height);
    if (rect.width == 0 or rect.height == 0) return;
    const uw = format.utileWidth();
    const uh = format.utileHeight();
    const cpp = format.bytesPerPixel();
    const x_end = rect.x + rect.width;
    const y_end = rect.y + rect.height;
    var uy = rect.y / uh;
    while (uy * uh < y_end) : (uy += 1) {
        var ux = rect.x / uw;
        while (ux * uw < x_end) : (ux += 1) {
            const base = texelOffsetOf(format, width, height, ux * uw, uy * uh);
            // The part of this micro-tile inside the rectangle.
            const x0 = @max(ux * uw, rect.x);
            const x1 = @min(ux * uw + uw, x_end);
            const y0 = @max(uy * uh, rect.y);
            const y1 = @min(uy * uh + uh, y_end);
            const n = (x1 - x0) * cpp;
            for (y0..y1) |y| {
                const d = base + ((@as(u32, @intCast(y)) % uh) * uw + x0 % uw) * cpp;
                const sidx = (@as(u32, @intCast(y)) - rect.y) * stride + (x0 - rect.x) * cpp;
                @memcpy(dst[d..][0..n], src[sidx..][0..n]);
            }
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
    const sizes = [_][2]u32{ .{ 16, 16 }, .{ 8, 64 }, .{ 32, 64 }, .{ 64, 64 }, .{ 128, 96 }, .{ 96, 128 }, .{ 256, 256 } };
    for ([_]Format{ .xrgb8888, .rgb565, .a8 }) |format| for (sizes) |sz| {
        var y: u32 = 0;
        while (y < sz[1]) : (y += 1) {
            var x: u32 = 0;
            while (x < sz[0]) : (x += 1) {
                try testing.expectEqual(sim.referenceTexelOffsetOf(format.bytesPerPixel(), sz[0], sz[1], x, y), texelOffsetOf(format, sz[0], sz[1], x, y));
            }
        }
    };
}

test "16-bit images: 8x4 micro-tiles, 64x32 tiles, sized as the kernel checks" {
    // LT up to 32 wide (4 micro-tiles of 8) or 16 high.
    try testing.expect(isLtOf(.rgb565, 32, 100));
    try testing.expect(!isLtOf(.rgb565, 40, 100));
    // vc4_check_tex_size: T rounds to 64x32 pixels, LT to 8x4.
    try testing.expectEqual(@as(u32, 128 * 64 * 2), imageSizeOf(.rgb565, 100, 50));
    try testing.expectEqual(@as(u32, 16 * 100 * 2), imageSizeOf(.rgb565, 13, 100));
    // A micro-tile's rows are 16 bytes: 8 pixels.
    try testing.expectEqual(@as(u32, 14), texelOffsetOf(.rgb565, 100, 50, 7, 0));
    try testing.expectEqual(@as(u32, 16), texelOffsetOf(.rgb565, 100, 50, 0, 1));
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

test "8-bit images: 8x8 micro-tiles, 64x64 tiles, sized as the kernel checks" {
    try testing.expect(isLtOf(.a8, 100, 32));
    try testing.expect(!isLtOf(.a8, 100, 40));
    // The glyph atlas: a quarter of its 32-bit size.
    try testing.expectEqual(@as(u32, 1024 * 512), imageSizeOf(.a8, 1024, 512));
    try testing.expectEqual(@as(u32, 128 * 64), imageSizeOf(.a8, 100, 50));
    // A micro-tile's rows are 8 bytes.
    try testing.expectEqual(@as(u32, 7), texelOffsetOf(.a8, 100, 50, 7, 0));
    try testing.expectEqual(@as(u32, 8), texelOffsetOf(.a8, 100, 50, 0, 1));
}

test "uploadRectOf writes 16-bit pixels where texelOffsetOf says" {
    const gpa = std.testing.allocator;
    const w = 100;
    const h = 37;
    const pixels = try gpa.alloc(u16, w * h);
    defer gpa.free(pixels);
    for (pixels, 0..) |*px, i| px.* = @truncate(i * 40503);
    const a = try gpa.alloc(u8, imageSizeOf(.rgb565, w, h));
    defer gpa.free(a);
    @memset(a, 0);
    const r: Rect = .{ .x = 3, .y = 2, .width = w - 5, .height = h - 3 };
    uploadRectOf(.rgb565, a, w, h, r, std.mem.sliceAsBytes(pixels), w * 2);
    for (0..h) |y| for (0..w) |x| {
        const off = texelOffsetOf(.rgb565, w, h, @intCast(x), @intCast(y));
        const inside = x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
        const want: u16 = if (inside) pixels[(y - r.y) * w + (x - r.x)] else 0;
        try testing.expectEqual(want, std.mem.readInt(u16, a[off..][0..2], .little));
    };
}

test "uploadRect matches per-texel addressing, for whole images and parts" {
    const gpa = std.testing.allocator;
    for ([_][2]u32{ .{ 13, 7 }, .{ 64, 64 }, .{ 100, 37 }, .{ 37, 100 } }) |size| {
        const w = size[0];
        const h = size[1];
        const pixels = try gpa.alloc(u32, w * h);
        defer gpa.free(pixels);
        for (pixels, 0..) |*px, i| px.* = @intCast(i * 2654435761 % 0xffffffff);
        const a = try gpa.alloc(u8, imageSize(w, h));
        defer gpa.free(a);
        @memset(a, 0);
        upload(a, pixels, w, h);
        for (0..h) |y| for (0..w) |x| {
            const off = texelOffset(w, h, @intCast(x), @intCast(y));
            try std.testing.expectEqual(pixels[y * w + x], std.mem.readInt(u32, a[off..][0..4], .little));
        };
        // A rectangle at odd coordinates leaves the rest alone.
        const r: Rect = .{ .x = 3, .y = 2, .width = w - 5, .height = h - 3 };
        const sub = try gpa.alloc(u32, r.width * r.height);
        defer gpa.free(sub);
        @memset(sub, 0xdeadbeef);
        uploadRect(a, w, h, r, sub, r.width);
        for (0..h) |y| for (0..w) |x| {
            const off = texelOffset(w, h, @intCast(x), @intCast(y));
            const inside = x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
            const want = if (inside) 0xdeadbeef else pixels[y * w + x];
            try std.testing.expectEqual(want, std.mem.readInt(u32, a[off..][0..4], .little));
        };
    }
}
