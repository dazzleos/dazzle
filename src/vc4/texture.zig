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
//! so uploads here must agree with it exactly.
//!
//! Mipmaps: the smaller levels go just before level 0 in the buffer, the
//! smallest first, each straight after the next smaller, and level 0
//! starts on a 4 KB page (the texture's offset points at it; the texture
//! unit finds the others by going back from there). Each level is T or LT
//! by its own size, as the kernel works out when it checks the buffer.
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
/// Between mipmap levels: the nearest level, or a mix of the two nearest.
pub const MipFilter = enum { none, nearest, linear };
pub const Wrap = enum(u2) { repeat = 0, clamp = 1, mirror = 2, border = 3 };

pub const Config = struct {
    /// Byte offset of the image in its buffer; must be 4 KB aligned.
    offset: u32 = 0,
    /// One the GPU samples (`Format.sampleable`).
    format: Format = .argb8888,
    /// In pixels (for compressed formats too).
    width: u32,
    height: u32,
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    wrap_s: Wrap = .repeat,
    wrap_t: Wrap = .repeat,
    /// Mipmap levels after level 0 (see `mipmapLayout`), and how they are
    /// chosen between.
    mip_levels: u4 = 0,
    mip_filter: MipFilter = .none,
};

/// A VC4 texture configuration as the hardware has it (`decodeConfig`):
/// its texture type, not a `Format`.
pub const Decoded = struct {
    offset: u32 = 0,
    type: Type = .rgba8888,
    width: u32,
    height: u32,
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    wrap_s: Wrap = .repeat,
    wrap_t: Wrap = .repeat,
    mip_levels: u4 = 0,
    mip_filter: MipFilter = .none,
};

fn vc4Type(c: Config) Type {
    return c.format.vc4().texture orelse unreachable; // not sampled by the VC4
}

/// Texture config parameter 0: image offset, type and mip levels. The
/// kernel adds the buffer's physical address when relocating it.
pub fn p0(c: Config) u32 {
    std.debug.assert(c.offset & 0xfff == 0);
    return c.offset | (@as(u32, @intFromEnum(vc4Type(c))) & 0xf) << 4 | c.mip_levels;
}

/// Texture config parameter 1: size, filtering and wrapping.
pub fn p1(c: Config) u32 {
    const mipmapped = c.mip_levels > 0 and c.mip_filter != .none;
    const min: u32 = if (!mipmapped) switch (c.min_filter) {
        .linear => 0,
        .nearest => 1,
    } else switch (c.min_filter) {
        .nearest => if (c.mip_filter == .nearest) 2 else 3,
        .linear => if (c.mip_filter == .nearest) 4 else 5,
    };
    const mag: u32 = switch (c.mag_filter) {
        .linear => 0,
        .nearest => 1,
    };
    return (@as(u32, @intFromEnum(vc4Type(c))) >> 4) << 31 |
        (c.height & 2047) << 20 |
        (c.width & 2047) << 8 |
        mag << 7 |
        min << 4 |
        @as(u32, @intFromEnum(c.wrap_t)) << 2 |
        @as(u32, @intFromEnum(c.wrap_s));
}

pub fn decodeConfig(param0: u32, param1: u32) Decoded {
    const w = (param1 >> 8) & 2047;
    const h = (param1 >> 20) & 2047;
    return .{
        .offset = param0 & 0xfffff000,
        .type = @enumFromInt(((param0 >> 4) & 0xf) | ((param1 >> 31) << 4)),
        .width = if (w == 0) 2048 else w,
        .height = if (h == 0) 2048 else h,
        .mag_filter = if ((param1 >> 7) & 1 != 0) .nearest else .linear,
        .min_filter = switch ((param1 >> 4) & 7) {
            1, 2, 3 => .nearest,
            else => .linear,
        },
        .wrap_t = @enumFromInt(@as(u2, @truncate(param1 >> 2))),
        .wrap_s = @enumFromInt(@as(u2, @truncate(param1))),
        .mip_levels = @truncate(param0),
        .mip_filter = switch ((param1 >> 4) & 7) {
            2, 4 => .nearest,
            3, 5 => .linear,
            else => .none,
        },
    };
}

/// Set when opening a V3D (`v3d`: the Pi 4 and 5) device (see
/// `device.open`), so textures are laid out as it reads them (UIF), not as
/// the VC4 does. (Never set, a Pi 4's textures came out scrambled.)
pub var use_uif: bool = false;

/// Hardware tiling modes on V3D 4.2 (`enum v3d_tiling_mode` in Mesa).
pub const UifTiling = enum(u3) {
    raster = 0,
    lineartile = 1,
    ublinear_1_column = 2,
    ublinear_2_column = 3,
    uif_no_xor = 4,
    uif_xor = 5,
};

pub const UifSlice = struct {
    tiling: UifTiling,
    padded_width: u32,
    padded_height: u32,
    ub_pad: u8,
    size: u32,
};

fn uifUbPad(ub_h: u32, height: u32) u8 {
    // V3D_UIFCFG_PAGE_SIZE = 4096, V3D_UIFBLOCK_ROW_SIZE = 1024, V3D_PAGE_CACHE_SIZE = 32768.
    const page_ub_rows_times_1_5 = 6;
    const page_cache_ub_rows = 32;
    const page_cache_minus_1_5_ub_rows = page_cache_ub_rows - page_ub_rows_times_1_5;

    const height_ub = height / ub_h;
    const height_offset_in_pc = height_ub % page_cache_ub_rows;
    if (height_offset_in_pc == 0) return 0;
    if (height_offset_in_pc < page_ub_rows_times_1_5) {
        return if (height_ub < page_cache_ub_rows) 0 else @intCast(page_ub_rows_times_1_5 - height_offset_in_pc);
    }
    if (height_offset_in_pc > page_cache_minus_1_5_ub_rows) {
        return @intCast(page_cache_ub_rows - height_offset_in_pc);
    }
    return 0;
}

/// log2 of a format's utile width and height and of its element's bytes.
const Shifts = struct { uw: u5, uh: u5, cpp: u5 };

inline fn shiftsOf(format: Format) Shifts {
    return .{
        .uw = @intCast(std.math.log2_int(u32, format.utileWidth())),
        .uh = @intCast(std.math.log2_int(u32, format.utileHeight())),
        .cpp = @intCast(std.math.log2_int(u32, format.elementBytes())),
    };
}

/// Computes the V3D 4.2 slice tiling and padded dimensions (`v3d_setup_slices`).
///
/// Here and in the other layout functions taking a format, sizes and
/// positions are in elements: pixels, or the blocks of a compressed
/// format (`Format.elements`).
pub fn uifSlice(format: Format, width: u32, height: u32) UifSlice {
    const uw = format.utileWidth();
    const uh = format.utileHeight();
    const ub_w = uw * 2;
    const ub_h = uh * 2;
    const cpp = format.elementBytes();
    if (width <= uw or height <= uh) {
        const pw = std.mem.alignForward(u32, @max(width, 1), uw);
        const ph = std.mem.alignForward(u32, @max(height, 1), uh);
        return .{ .tiling = .lineartile, .padded_width = pw, .padded_height = ph, .ub_pad = 0, .size = pw * ph * cpp };
    }
    if (width <= ub_w) {
        const pw = std.mem.alignForward(u32, width, ub_w);
        const ph = std.mem.alignForward(u32, height, ub_h);
        return .{ .tiling = .ublinear_1_column, .padded_width = pw, .padded_height = ph, .ub_pad = 0, .size = pw * ph * cpp };
    }
    if (width <= 2 * ub_w) {
        const pw = std.mem.alignForward(u32, width, 2 * ub_w);
        const ph = std.mem.alignForward(u32, height, ub_h);
        return .{ .tiling = .ublinear_2_column, .padded_width = pw, .padded_height = ph, .ub_pad = 0, .size = pw * ph * cpp };
    }
    const pw = std.mem.alignForward(u32, width, 4 * ub_w);
    var ph = std.mem.alignForward(u32, height, ub_h);
    const ub_pad = uifUbPad(ub_h, ph);
    ph += @as(u32, ub_pad) * ub_h;
    const tiling: UifTiling = if ((ph / ub_h) % 32 == 0) .uif_xor else .uif_no_xor;
    return .{ .tiling = tiling, .padded_width = pw, .padded_height = ph, .ub_pad = ub_pad, .size = pw * ph * cpp };
}

pub inline fn uifTexelOffsetOf(format: Format, width: u32, height: u32, x: u32, y: u32) u32 {
    const sh = shiftsOf(format);
    const uw_shift = sh.uw;
    const uh_shift = sh.uh;
    const uw: u32 = @as(u32, 1) << uw_shift;
    const uh: u32 = @as(u32, 1) << uh_shift;
    const ub_w_shift: u5 = uw_shift + 1;
    const ub_h_shift: u5 = uh_shift + 1;
    const cpp_shift = sh.cpp;
    const in_utile = (((y & (uh - 1)) << uw_shift) | (x & (uw - 1))) << cpp_shift;
    const slice = uifSlice(format, width, height);
    return switch (slice.tiling) {
        .raster => (y * slice.padded_width + x) << cpp_shift,
        .lineartile => (((x >> uw_shift) + (y >> uh_shift)) << 6) + in_utile,
        .ublinear_1_column => ((y >> ub_h_shift) << 8) + (if ((x & uw) != 0) @as(u32, 64) else 0) + (if ((y & uh) != 0) @as(u32, 128) else 0) + in_utile,
        .ublinear_2_column => ((((y >> ub_h_shift) << 1) + (x >> ub_w_shift)) << 8) + (if ((x & uw) != 0) @as(u32, 64) else 0) + (if ((y & uh) != 0) @as(u32, 128) else 0) + in_utile,
        .uif_no_xor, .uif_xor => blk: {
            const mb_x = x >> ub_w_shift;
            var mb_y = y >> ub_h_shift;
            if (slice.tiling == .uif_xor and ((mb_x >> 2) & 1) != 0) mb_y ^= 0x10;
            const mb_h = slice.padded_height >> ub_h_shift;
            const mb_id = ((mb_x >> 2) * ((mb_h - 1) << 2)) + mb_x + (mb_y << 2);
            const mb_tile_offset = (if ((y & uh) != 0) @as(u32, 128) else 0) + (if ((x & uw) != 0) @as(u32, 64) else 0);
            break :blk (mb_id << 8) + mb_tile_offset + in_utile;
        },
    };
}

// --- Mipmaps --------------------------------------------------------------------

/// Where a 32-bit mipmapped image goes in its buffer.
pub const Mipmapped = struct {
    /// Bytes the buffer needs.
    size: u32,
    /// Where level 0 starts (4 KB aligned): the texture's offset.
    base: u32,
};

/// The size of level `level` (0 is the image itself).
pub fn levelSize(width: u32, height: u32, level: u4) [2]u32 {
    return .{ @max(width >> level, 1), @max(height >> level, 1) };
}

fn mipSliceDims(width: u32, height: u32, level: u4) [2]u32 {
    if (!use_uif or level < 2) return levelSize(width, height, level);
    const pot_w = 2 * std.math.ceilPowerOfTwoAssert(u32, @max(width >> 1, 1));
    const pot_h = 2 * std.math.ceilPowerOfTwoAssert(u32, @max(height >> 1, 1));
    return .{ @max(pot_w >> level, 1), @max(pot_h >> level, 1) };
}

fn mipLevelBytes(width: u32, height: u32, level: u4) u32 {
    const dims = mipSliceDims(width, height, level);
    const sz = imageSize(dims[0], dims[1]);
    if (use_uif and level == 1) {
        const slice = uifSlice(.xrgb8888, dims[0], dims[1]);
        const ub_w = Format.xrgb8888.utileWidth() * 2;
        const ub_h = Format.xrgb8888.utileHeight() * 2;
        if (slice.padded_width > 4 * ub_w and slice.padded_height > 26 * ub_h) {
            return std.mem.alignForward(u32, sz, 4096);
        }
    }
    return sz;
}

/// The layout of a 32-bit image with `levels` levels after level 0.
pub fn mipmapLayout(width: u32, height: u32, levels: u4) Mipmapped {
    var below: u32 = 0;
    var i: u4 = 1;
    while (i <= levels) : (i += 1) {
        below += mipLevelBytes(width, height, i);
        if (i == 15) break;
    }
    const base = std.mem.alignForward(u32, below, 4096);
    return .{ .size = base + imageSize(width, height), .base = base };
}

/// Where level `level` starts, in an image laid out as `mipmapLayout`.
pub fn levelOffset(width: u32, height: u32, layout: Mipmapped, level: u4) u32 {
    var offset = layout.base;
    var i: u4 = 1;
    while (i <= level) : (i += 1) {
        offset -= mipLevelBytes(width, height, i);
        if (i == 15) break;
    }
    return offset;
}

/// The most levels after level 0 an image can have (down to a pixel).
pub fn maxLevels(width: u32, height: u32) u4 {
    return @intCast(std.math.log2_int(u32, @max(width, height)));
}

/// Uploads a 32-bit image (0xAARRGGBB, raster order) and its smaller
/// levels, each a quarter of the one before (each pixel the average of
/// four, weighted by how opaque they are, so see-through pixels do not
/// darken the edges of what is not), into `dst` as `mipmapLayout` says.
/// What a texture's texels are, for making its mipmaps.
pub const MipKind = enum {
    /// Colours, averaged weighted by alpha.
    colour,
    /// Normals packed as r, g, b = (n + 1) / 2: averaged, and made unit
    /// length again (a shorter normal would darken what is lit by it).
    normal,
};

pub fn uploadMipmaps(gpa: std.mem.Allocator, dst: []u8, pixels: []const u32, width: u32, height: u32, levels: u4, kind: MipKind) !void {
    const layout = mipmapLayout(width, height, levels);
    std.debug.assert(dst.len >= layout.size);
    upload(dst[layout.base..], pixels, width, height);
    var prev = try gpa.dupe(u32, pixels);
    defer gpa.free(prev);
    var pw = width;
    var ph = height;
    var level: u4 = 1;
    while (level <= levels) : (level += 1) {
        const sz = levelSize(width, height, level);
        const dims = mipSliceDims(width, height, level);
        const next = try nextLevel(gpa, prev, pw, ph, sz, kind);
        uploadRect(dst[levelOffset(width, height, layout, level)..], dims[0], dims[1], .{ .x = 0, .y = 0, .width = sz[0], .height = sz[1] }, next, sz[0]);
        gpa.free(prev);
        prev = next;
        pw = sz[0];
        ph = sz[1];
        if (level == 15) break;
    }
}

/// Level `sz` big from the one before it (`prev`, `pw` by `ph`): each
/// pixel the average of four (see `uploadMipmaps`).
fn nextLevel(gpa: std.mem.Allocator, prev: []const u32, pw: u32, ph: u32, sz: [2]u32, kind: MipKind) ![]u32 {
    const next = try gpa.alloc(u32, sz[0] * sz[1]);
    for (0..sz[1]) |y| for (0..sz[0]) |x| {
        var sum: [4]f32 = .{ 0, 0, 0, 0 };
        var n: f32 = 0;
        for ([2]u32{ 0, 1 }) |dy| for ([2]u32{ 0, 1 }) |dx| {
            const sx = @min(@as(u32, @intCast(x)) * 2 + dx, pw - 1);
            const sy = @min(@as(u32, @intCast(y)) * 2 + dy, ph - 1);
            const c = prev[sy * pw + sx];
            const a: f32 = @floatFromInt(c >> 24);
            sum[0] += a;
            for (0..3) |k| sum[k + 1] += a * @as(f32, @floatFromInt(c >> @intCast(16 - k * 8) & 0xff));
            n += 1;
        };
        var out: u32 = @as(u32, @intFromFloat(@round(sum[0] / n))) << 24;
        if (sum[0] > 0) switch (kind) {
            .colour => for (0..3) |k| {
                out |= @as(u32, @intFromFloat(@round(sum[k + 1] / sum[0]))) << @intCast(16 - k * 8);
            },
            .normal => {
                var v: [3]f32 = undefined;
                for (&v, 0..) |*e, k| e.* = sum[k + 1] / sum[0] / 127.5 - 1;
                const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
                for (v, 0..) |e, k| {
                    const unit = if (len > 1e-4) e / len else @as(f32, if (k == 2) 1 else 0);
                    out |= @as(u32, @intFromFloat(std.math.clamp(@round((unit + 1) * 127.5), 0, 255))) << @intCast(16 - k * 8);
                }
            },
        };
        next[y * sz[0] + x] = out;
    };
    return next;
}

/// The layout of an image of `format` with `levels` levels after level 0
/// (as `mipmapLayout`, for the GPU's layouts without UIF).
pub fn mipmapLayoutOf(format: Format, width: u32, height: u32, levels: u4) Mipmapped {
    var below: u32 = 0;
    var i: u4 = 1;
    while (i <= levels) : (i += 1) {
        const d = levelSize(width, height, i);
        below += imageSizeOf(format, d[0], d[1]);
        if (i == 15) break;
    }
    const base = std.mem.alignForward(u32, below, 4096);
    return .{ .size = base + imageSizeOf(format, width, height), .base = base };
}

/// Where level `level` starts, in an image laid out as `mipmapLayoutOf`.
pub fn levelOffsetOf(format: Format, width: u32, height: u32, layout: Mipmapped, level: u4) u32 {
    var offset = layout.base;
    var i: u4 = 1;
    while (i <= level) : (i += 1) {
        const d = levelSize(width, height, i);
        offset -= imageSizeOf(format, d[0], d[1]);
        if (i == 15) break;
    }
    return offset;
}

/// A 16-bit format's texel from a 32-bit one (0xAARRGGBB) at (x, y) in its
/// level (to dither by).
pub const Pack16 = *const fn (c: u32, x: u32, y: u32) u16;

/// Uploads a 32-bit image (0xAARRGGBB, raster order) and its smaller
/// levels (as `uploadMipmaps`) as a 16-bit `format` (BGR565 or RGBA4444),
/// each texel made by `pack`, into `dst` as `mipmapLayoutOf` says.
pub fn uploadMipmapsOf(gpa: std.mem.Allocator, format: Format, dst: []u8, pixels: []const u32, width: u32, height: u32, levels: u4, kind: MipKind, pack: Pack16) !void {
    std.debug.assert(format.bytesPerPixel() == 2);
    const layout = mipmapLayoutOf(format, width, height, levels);
    std.debug.assert(dst.len >= layout.size);
    var prev = try gpa.dupe(u32, pixels);
    defer gpa.free(prev);
    var sz: [2]u32 = .{ width, height };
    var level: u4 = 0;
    while (true) {
        const texels = try gpa.alloc(u16, sz[0] * sz[1]);
        defer gpa.free(texels);
        for (0..sz[1]) |y| for (0..sz[0]) |x| {
            texels[y * sz[0] + x] = pack(prev[y * sz[0] + x], @intCast(x), @intCast(y));
        };
        uploadRectOf(format, dst[levelOffsetOf(format, width, height, layout, level)..], sz[0], sz[1], .{ .x = 0, .y = 0, .width = sz[0], .height = sz[1] }, std.mem.sliceAsBytes(texels), sz[0] * 2);
        if (level == levels or level == 15) break;
        level += 1;
        const next_sz = levelSize(width, height, level);
        const next = try nextLevel(gpa, prev, sz[0], sz[1], next_sz, kind);
        gpa.free(prev);
        prev = next;
        sz = next_sz;
    }
}

/// Whether the hardware treats a 32-bit image of this size as LT rather
/// than T.
pub fn isLt(width: u32, height: u32) bool {
    return isLtOf(.xrgb8888, width, height);
}

pub fn isLtOf(format: Format, width: u32, height: u32) bool {
    if (!@inComptime() and use_uif) return width <= format.utileWidth() or height <= format.utileHeight();
    return width <= 4 * format.utileWidth() or height <= 4 * format.utileHeight();
}

/// Bytes needed for a 32-bit-per-pixel image, padded the way the kernel's
/// vc4_check_tex_size() expects.
pub fn imageSize(width: u32, height: u32) u32 {
    return imageSizeOf(.xrgb8888, width, height);
}

pub fn imageSizeOf(format: Format, width: u32, height: u32) u32 {
    if (!@inComptime() and use_uif) return uifSlice(format, width, height).size;
    const uw = format.utileWidth();
    const uh = format.utileHeight();
    const cpp = format.elementBytes();
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
    if (!@inComptime() and use_uif) return uifSlice(format, width, height).padded_width * format.elementBytes();
    const uw = format.utileWidth();
    const align_w = if (isLtOf(format, width, height)) uw else 8 * uw;
    return std.mem.alignForward(u32, width, align_w) * format.elementBytes();
}

/// Byte offset of the 1 KB sub-tile containing micro-tile (utile_x,
/// utile_y) in a T image `utile_stride` micro-tiles wide.
pub inline fn tSubtileOffset(utile_x: u32, utile_y: u32, utile_stride: u32) u32 {
    const tile_stride = utile_stride >> 3;
    var tile_x = utile_x >> 3;
    const tile_y = utile_y >> 3;
    const odd_row = (tile_y & 1) != 0;
    // Odd rows of 4 KB tiles run right to left.
    if (odd_row) tile_x = tile_stride - tile_x - 1;
    const tile_offset = (tile_y * tile_stride + tile_x) << 12;

    const stile_index = ((utile_y >> 2) & 1) << 1 | ((utile_x >> 2) & 1);
    const odd_map = [4]u32{ 2, 1, 3, 0 };
    const even_map = [4]u32{ 0, 3, 1, 2 };
    return tile_offset + ((if (odd_row) odd_map else even_map)[stile_index] << 10);
}

/// Byte offset of pixel (x, y) in a tiled 32-bit image.
pub fn texelOffset(width: u32, height: u32, x: u32, y: u32) u32 {
    return texelOffsetOf(.xrgb8888, width, height, x, y);
}

pub inline fn texelOffsetOf(format: Format, width: u32, height: u32, x: u32, y: u32) u32 {
    if (!@inComptime() and use_uif) return uifTexelOffsetOf(format, width, height, x, y);
    const sh = shiftsOf(format);
    const uw_shift = sh.uw;
    const uh_shift = sh.uh;
    const uw: u32 = @as(u32, 1) << uw_shift;
    const uh: u32 = @as(u32, 1) << uh_shift;
    const cpp_shift = sh.cpp;
    const in_utile = (((y & (uh - 1)) << uw_shift) | (x & (uw - 1))) << cpp_shift;
    if (width <= (uw << 2) or height <= (uh << 2)) {
        const row_stride = ((width + uw - 1) & ~(uw - 1)) << cpp_shift;
        return (y & ~(uh - 1)) * row_stride + ((x >> uw_shift) << 6) + in_utile;
    }
    const tile_w = uw << 3;
    const utile_stride = ((width + tile_w - 1) & ~(tile_w - 1)) >> uw_shift;
    const utile_x = x >> uw_shift;
    const utile_y = y >> uh_shift;
    // Within a sub-tile, micro-tiles are a 4x4 raster-order grid.
    const in_subtile = (((utile_y & 3) << 2) | (utile_x & 3)) << 6;
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
    const sh = shiftsOf(format);
    const uw_shift = sh.uw;
    const uh_shift = sh.uh;
    const uw: u32 = @as(u32, 1) << uw_shift;
    const uh: u32 = @as(u32, 1) << uh_shift;
    const cpp_shift = sh.cpp;
    const x_end = rect.x + rect.width;
    const y_end = rect.y + rect.height;
    var uy = rect.y >> uh_shift;
    while ((uy << uh_shift) < y_end) : (uy += 1) {
        var ux = rect.x >> uw_shift;
        while ((ux << uw_shift) < x_end) : (ux += 1) {
            const base = texelOffsetOf(format, width, height, ux << uw_shift, uy << uh_shift);
            // The part of this micro-tile inside the rectangle.
            const x0 = @max(ux << uw_shift, rect.x);
            const x1 = @min((ux << uw_shift) + uw, x_end);
            const y0 = @max(uy << uh_shift, rect.y);
            const y1 = @min((uy << uh_shift) + uh, y_end);
            const n = (x1 - x0) << cpp_shift;
            for (y0..y1) |y| {
                const d = base + ((((@as(u32, @intCast(y)) & (uh - 1)) << uw_shift) | (x0 & (uw - 1))) << cpp_shift);
                const sidx = (@as(u32, @intCast(y)) - rect.y) * stride + ((x0 - rect.x) << cpp_shift);
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
    try testing.expectEqual(Type.rgba8888, d.type);
    try testing.expectEqual(c.width, d.width);
    try testing.expectEqual(c.height, d.height);
    try testing.expectEqual(c.mag_filter, d.mag_filter);
    try testing.expectEqual(c.min_filter, d.min_filter);
    try testing.expectEqual(c.wrap_s, d.wrap_s);
    try testing.expectEqual(c.wrap_t, d.wrap_t);
}

test "mipmaps: the levels packed before level 0, sized as the kernel checks them" {
    // A strip of tiles, 64 by 1024: 32x512 is T, then LT from 16 across.
    const layout = mipmapLayout(64, 1024, 6);
    const sizes = [_]u32{ 32 * 512 * 4, 16 * 256 * 4, 8 * 128 * 4, 4 * 64 * 4, 4 * 32 * 4, 4 * 16 * 4 };
    var below: u32 = 0;
    for (sizes) |sz| below += sz;
    try testing.expectEqual(std.mem.alignForward(u32, below, 4096), layout.base);
    try testing.expectEqual(layout.base + 64 * 1024 * 4, layout.size);
    // Each level ends where the next larger starts; the kernel's check (the
    // offset is at least the levels' sizes) holds.
    var end = layout.base;
    for (sizes, 1..) |sz, i| {
        const off = levelOffset(64, 1024, layout, @intCast(i));
        try testing.expectEqual(end - sz, off);
        end = off;
    }
    try testing.expectEqual(@as(u4, 10), maxLevels(64, 1024));
    // The levels go in P0, and the mip filter in P1.
    const c: Config = .{ .offset = layout.base, .width = 64, .height = 1024, .min_filter = .nearest, .mip_levels = 6, .mip_filter = .linear };
    try testing.expectEqual(@as(u32, 6), p0(c) & 0xf);
    try testing.expectEqual(@as(u32, 3), p1(c) >> 4 & 7);
    const d = decodeConfig(p0(c), p1(c));
    try testing.expectEqual(c.mip_levels, d.mip_levels);
    try testing.expectEqual(c.mip_filter, d.mip_filter);
    try testing.expectEqual(c.min_filter, d.min_filter);
    try testing.expectEqual(c.offset, d.offset);
}

test "mipmaps: each level averages the one before, and see-through pixels do not darken it" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 32;
    var px: [w * h]u32 = undefined;
    // Left half opaque red, right half clear black.
    for (0..h) |y| for (0..w) |x| {
        px[y * w + x] = if (x < 4) 0xffff0000 else 0x00000000;
    };
    // One pixel of the top left 2x2 is see-through.
    px[1] = 0;
    const layout = mipmapLayout(w, h, 3);
    const mem = try gpa.alloc(u8, layout.size);
    defer gpa.free(mem);
    try uploadMipmaps(gpa, mem, &px, w, h, 3, .colour);
    const at = struct {
        fn f(m: []const u8, off: u32, ww: u32, hh: u32, x: u32, y: u32) u32 {
            return std.mem.readInt(u32, m[off + texelOffset(ww, hh, x, y) ..][0..4], .little);
        }
    }.f;
    try testing.expectEqual(@as(u32, 0xffff0000), at(mem, layout.base, w, h, 0, 1));
    const l1 = levelOffset(w, h, layout, 1);
    // Three red, one clear: red, three quarters opaque.
    try testing.expectEqual(@as(u32, 0xbfff0000), at(mem, l1, 4, 16, 0, 0));
    try testing.expectEqual(@as(u32, 0xffff0000), at(mem, l1, 4, 16, 1, 1));
    try testing.expectEqual(@as(u32, 0x00000000), at(mem, l1, 4, 16, 3, 3));
    // Level 2 is 2x8: half red (the left column, mostly opaque).
    const l2 = levelOffset(w, h, layout, 2);
    try testing.expectEqual(@as(u32, 0x00ff0000), at(mem, l2, 2, 8, 0, 1) & 0x00ffffff);
    try testing.expectEqual(@as(u32, 0xff), at(mem, l2, 2, 8, 0, 1) >> 24);
}

test "mipmaps of normals stay unit length" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 32;
    // Columns tilted left and right in turn (+-0.6, 0, 0.8): their average
    // is (0, 0, 0.8), made (0, 0, 1) again.
    var px: [w * h]u32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        px[y * w + x] = if (x % 2 == 0) 0xff_33_80_e5 else 0xff_cc_80_e5;
    };
    const layout = mipmapLayout(w, h, 1);
    const mem = try gpa.alloc(u8, layout.size);
    defer gpa.free(mem);
    try uploadMipmaps(gpa, mem, &px, w, h, 1, .normal);
    const c = std.mem.readInt(u32, mem[levelOffset(w, h, layout, 1) + texelOffset(4, 16, 1, 2) ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0xff_80_80_ff), c);
}

test "layout matches the reference description" {
    const sim = @import("qpu_sim.zig");
    const sizes = [_][2]u32{ .{ 16, 16 }, .{ 8, 64 }, .{ 32, 64 }, .{ 64, 64 }, .{ 128, 96 }, .{ 96, 128 }, .{ 256, 256 } };
    for ([_]Format{ .xrgb8888, .bgr565, .a8 }) |format| for (sizes) |sz| {
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
    try testing.expect(isLtOf(.bgr565, 32, 100));
    try testing.expect(!isLtOf(.bgr565, 40, 100));
    // vc4_check_tex_size: T rounds to 64x32 pixels, LT to 8x4.
    try testing.expectEqual(@as(u32, 128 * 64 * 2), imageSizeOf(.bgr565, 100, 50));
    try testing.expectEqual(@as(u32, 16 * 100 * 2), imageSizeOf(.bgr565, 13, 100));
    // A micro-tile's rows are 16 bytes: 8 pixels.
    try testing.expectEqual(@as(u32, 14), texelOffsetOf(.bgr565, 100, 50, 7, 0));
    try testing.expectEqual(@as(u32, 16), texelOffsetOf(.bgr565, 100, 50, 0, 1));
}

test "every texel lands in a distinct slot inside the image" {
    const w = 96;
    const h = 64;
    var seen: [imageSize(w, h) / 4]bool = @splat(false);
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
    const a = try gpa.alloc(u8, imageSizeOf(.bgr565, w, h));
    defer gpa.free(a);
    @memset(a, 0);
    const r: Rect = .{ .x = 3, .y = 2, .width = w - 5, .height = h - 3 };
    uploadRectOf(.bgr565, a, w, h, r, std.mem.sliceAsBytes(pixels), w * 2);
    for (0..h) |y| for (0..w) |x| {
        const off = texelOffsetOf(.bgr565, w, h, @intCast(x), @intCast(y));
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

test "V3D 4.2 UIF tiling: uif_xor, ublinear, and lineartile match uploadRectOf" {
    const prev_uif = use_uif;
    use_uif = true;
    defer use_uif = prev_uif;

    const gpa = std.testing.allocator;
    // Test sizes covering lineartile (13x7), ublinear_1_column (40x20),
    // ublinear_2_column (100x20), and uif_xor (192x128).
    for ([_][2]u32{ .{ 13, 7 }, .{ 40, 20 }, .{ 100, 20 }, .{ 192, 128 } }) |size| {
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
    }
    const m = mipmapLayout(256, 256, 8);
    try std.testing.expect(m.base > 0 and m.base % 4096 == 0);
}

test "16-bit mipmapped images: each level where the layout says, the texels as packed" {
    const gpa = std.testing.allocator;
    const w = 64;
    const h = 32;
    var pixels: [w * h]u32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = 0xff000000 | @as(u32, @intCast(i % 256));
    const layout = mipmapLayoutOf(.bgra4444, w, h, 3);
    // Levels below level 0, which is 4 KB aligned at the end.
    try std.testing.expectEqual(@as(u32, 0), layout.base % 4096);
    try std.testing.expectEqual(layout.base + imageSizeOf(.bgra4444, w, h), layout.size);
    try std.testing.expect(levelOffsetOf(.bgra4444, w, h, layout, 1) < layout.base);
    const dst = try gpa.alloc(u8, layout.size);
    defer gpa.free(dst);
    @memset(dst, 0);
    const pack = struct {
        fn f(c: u32, _: u32, _: u32) u16 {
            return @truncate(c);
        }
    }.f;
    try uploadMipmapsOf(gpa, .bgra4444, dst, &pixels, w, h, 3, .colour, pack);
    // Level 0's texel (5, 3), where the tiled layout puts it.
    const off = layout.base + texelOffsetOf(.bgra4444, w, h, 5, 3);
    try std.testing.expectEqual(@as(u16, @truncate(pixels[3 * w + 5])), std.mem.readInt(u16, dst[off..][0..2], .little));
}
