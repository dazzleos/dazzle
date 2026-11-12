//! The pixel formats Dazzle renders into, samples as textures and shows on
//! the display, and what each is called by the GPU, the kernel and
//! Wayland.
//!
//! Everything is drawn into the tile buffer as 32-bit colour, blue in the
//! low byte (shaders write their colour in that order); the format only
//! changes how the tile buffer is stored to memory (and loaded back). So
//! the same shaders render into any of them.
//!
//! A8 is for textures only (the tile buffer cannot store it): one byte of
//! coverage per pixel, a quarter of a 32-bit texture, for the glyph atlas.
//!
//! RGB565 halves a buffer's memory (and the memory bandwidth to draw,
//! composite and show it), at the cost of 5 or 6 bits per channel and no
//! alpha: right for opaque windows of flat colours (Dazzle's toolkit), less
//! so for smooth gradients, which band.

const std = @import("std");
const texture = @import("texture.zig");
const cl = @import("cl.zig");

pub const Format = enum {
    /// 32 bits: blue, green, red, then 8 unused, from the low byte
    /// (DRM_FORMAT_XRGB8888).
    xrgb8888,
    /// The same with alpha in the top byte (DRM_FORMAT_ARGB8888).
    argb8888,
    /// 16 bits: red in the low 5, green in the middle 6, blue in the top 5
    /// (DRM_FORMAT_BGR565; the GPU's tile buffer calls it BGR565, and its
    /// texture unit calls it RGB565).
    rgb565,
    /// 8 bits of alpha (or coverage); textures only. The texture unit
    /// returns it as alpha, with black for the colour.
    a8,

    pub fn bytesPerPixel(f: Format) u32 {
        return switch (f) {
            .xrgb8888, .argb8888 => 4,
            .rgb565 => 2,
            .a8 => 1,
        };
    }

    /// Its DRM (and linux-dmabuf) four-character code.
    pub fn fourcc(f: Format) u32 {
        return switch (f) {
            .xrgb8888 => code("XR24"),
            .argb8888 => code("AR24"),
            .rgb565 => code("BG16"),
            .a8 => code("R8  "),
        };
    }

    pub fn fromFourcc(c: u32) ?Format {
        inline for (@typeInfo(Format).@"enum".field_values) |value| {
            const f: Format = @enumFromInt(value);
            if (f.fourcc() == c) return f;
        }
        return null;
    }

    /// The texture unit's type for it.
    pub fn textureType(f: Format) texture.Type {
        return switch (f) {
            .xrgb8888, .argb8888 => .rgba8888,
            .rgb565 => .rgb565,
            .a8 => .alpha,
        };
    }

    /// How the tile buffer is stored to memory (and loaded back) in it:
    /// for the render configuration and for load/store packets. RGB565 is
    /// stored without dithering, so a buffer loaded back and stored again
    /// (when only part of a frame is redrawn) keeps the pixels it had.
    pub fn renderConfigFormat(f: Format) u2 {
        return switch (f) {
            .xrgb8888, .argb8888 => cl.render_config_format_rgba8888,
            .rgb565 => cl.render_config_format_bgr565,
            .a8 => unreachable, // not a render target
        };
    }

    pub fn loadStoreFormat(f: Format) u2 {
        return switch (f) {
            .xrgb8888, .argb8888 => cl.loadstore_format_rgba8888,
            .rgb565 => cl.loadstore_format_bgr565,
            .a8 => unreachable, // not a render target
        };
    }

    /// Whether the GPU can render into it.
    pub fn renderable(f: Format) bool {
        return f != .a8;
    }

    /// A micro-tile, the 64 bytes the tiled layouts are made of: 4x4
    /// pixels of 32 bits, 8x4 of 16, 8x8 of 8.
    pub fn utileWidth(f: Format) u32 {
        return if (f.bytesPerPixel() == 4) 4 else 8;
    }

    pub fn utileHeight(f: Format) u32 {
        return if (f.bytesPerPixel() == 1) 8 else 4;
    }
};

fn code(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

/// A 0xAARRGGBB colour as an RGB565 pixel (rounded to the nearest), with
/// blue in the top 5 bits as the tile buffer stores it.
pub inline fn toRgb565(argb: u32) u16 {
    const r: u32 = (argb >> 16) & 0xff;
    const g: u32 = (argb >> 8) & 0xff;
    const b: u32 = argb & 0xff;
    return @intCast(((b * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (r * 31 + 127) / 255);
}

/// An RGB565 pixel as 0xffRRGGBB, each channel's bits repeated to fill 8.
pub inline fn fromRgb565(p: u16) u32 {
    const b: u32 = p >> 11;
    const g: u32 = (p >> 5) & 0x3f;
    const r: u32 = p & 0x1f;
    return 0xff000000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
}

pub inline fn toRgb565Vec8(argb: @Vector(8, u32)) @Vector(8, u16) {
    const r = (argb >> @splat(16)) & @as(@Vector(8, u32), @splat(0xff));
    const g = (argb >> @splat(8)) & @as(@Vector(8, u32), @splat(0xff));
    const b = argb & @as(@Vector(8, u32), @splat(0xff));
    const rx = r * @as(@Vector(8, u32), @splat(31)) + @as(@Vector(8, u32), @splat(127));
    const gx = g * @as(@Vector(8, u32), @splat(63)) + @as(@Vector(8, u32), @splat(127));
    const bx = b * @as(@Vector(8, u32), @splat(31)) + @as(@Vector(8, u32), @splat(127));
    const r5 = (rx + @as(@Vector(8, u32), @splat(1)) + (rx >> @splat(8))) >> @splat(8);
    const g6 = (gx + @as(@Vector(8, u32), @splat(1)) + (gx >> @splat(8))) >> @splat(8);
    const b5 = (bx + @as(@Vector(8, u32), @splat(1)) + (bx >> @splat(8))) >> @splat(8);
    return @truncate((b5 << @splat(11)) | (g6 << @splat(5)) | r5);
}

pub inline fn fromRgb565Vec8(p16: @Vector(8, u16)) @Vector(8, u32) {
    const p: @Vector(8, u32) = p16;
    const b = p >> @splat(11);
    const g = (p >> @splat(5)) & @as(@Vector(8, u32), @splat(0x3f));
    const r = p & @as(@Vector(8, u32), @splat(0x1f));
    const r8 = (r << @splat(3)) | (r >> @splat(2));
    const g8 = (g << @splat(2)) | (g >> @splat(4));
    const b8 = (b << @splat(3)) | (b >> @splat(2));
    return @as(@Vector(8, u32), @splat(0xff000000)) | (r8 << @splat(16)) | (g8 << @splat(8)) | b8;
}

const testing = std.testing;

test "formats' codes and sizes" {
    try testing.expectEqual(@as(?Format, .rgb565), Format.fromFourcc(code("BG16")));
    try testing.expectEqual(@as(?Format, .xrgb8888), Format.fromFourcc(code("XR24")));
    try testing.expectEqual(@as(?Format, null), Format.fromFourcc(code("NV12")));
    try testing.expectEqual(@as(u32, 8), Format.rgb565.utileWidth());
    try testing.expectEqual(@as(u32, 4), Format.xrgb8888.utileWidth());
    try testing.expectEqual(@as(u32, 8), Format.a8.utileHeight());
}

test "RGB565 conversions" {
    try testing.expectEqual(@as(u16, 0x001f), toRgb565(0xffff0000));
    try testing.expectEqual(@as(u16, 0x07e0), toRgb565(0xff00ff00));
    try testing.expectEqual(@as(u16, 0xf800), toRgb565(0xff0000ff));
    try testing.expectEqual(@as(u32, 0xffffffff), fromRgb565(0xffff));
    // Every 565 value survives a round trip, and 8-wide SIMD matches scalar.
    var p: u32 = 0;
    while (p < 0x10000) : (p += 8) {
        var in16: [8]u16 = undefined;
        for (0..8) |i| in16[i] = @intCast(p + i);
        const rgb32: [8]u32 = fromRgb565Vec8(in16);
        const out16: [8]u16 = toRgb565Vec8(rgb32);
        for (0..8) |i| {
            try testing.expectEqual(fromRgb565(in16[i]), rgb32[i]);
            try testing.expectEqual(in16[i], out16[i]);
        }
    }
}
