//! The pixel formats Dazzle renders into, samples as textures and shows on
//! the display, and what each is called by the GPU, the kernel and
//! Wayland.
//!
//! Everything is drawn into the tile buffer as 32-bit colour, blue in the
//! low byte (shaders write their colour in that order); the format only
//! changes how the tile buffer is stored to memory (and loaded back). So
//! the same shaders render into any of them.
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
    /// 16 bits: blue in the low 5, green in the middle 6, red in the top 5
    /// (DRM_FORMAT_RGB565; the GPU's tile buffer calls it BGR565).
    rgb565,

    pub fn bytesPerPixel(f: Format) u32 {
        return switch (f) {
            .xrgb8888, .argb8888 => 4,
            .rgb565 => 2,
        };
    }

    /// Its DRM (and linux-dmabuf) four-character code.
    pub fn fourcc(f: Format) u32 {
        return switch (f) {
            .xrgb8888 => code("XR24"),
            .argb8888 => code("AR24"),
            .rgb565 => code("RG16"),
        };
    }

    pub fn fromFourcc(c: u32) ?Format {
        inline for (@typeInfo(Format).@"enum".fields) |field| {
            const f: Format = @enumFromInt(field.value);
            if (f.fourcc() == c) return f;
        }
        return null;
    }

    /// The texture unit's type for it.
    pub fn textureType(f: Format) texture.Type {
        return switch (f) {
            .xrgb8888, .argb8888 => .rgba8888,
            .rgb565 => .rgb565,
        };
    }

    /// Whether the texture unit returns its red and blue the other way
    /// round from the tile buffer's order. It returns a 32-bit texel's
    /// bytes in memory order (blue first, as the tile buffer has them),
    /// but an RGB565 texel's red first (Mesa's vc4 driver swizzles it so),
    /// so a shader that copies an RGB565 texture swaps them back.
    pub fn textureSwapsRedBlue(f: Format) bool {
        return f == .rgb565;
    }

    /// How the tile buffer is stored to memory (and loaded back) in it:
    /// for the render configuration and for load/store packets. RGB565 is
    /// stored without dithering, so a buffer loaded back and stored again
    /// (when only part of a frame is redrawn) keeps the pixels it had.
    pub fn renderConfigFormat(f: Format) u2 {
        return switch (f) {
            .xrgb8888, .argb8888 => cl.render_config_format_rgba8888,
            .rgb565 => cl.render_config_format_bgr565,
        };
    }

    pub fn loadStoreFormat(f: Format) u2 {
        return switch (f) {
            .xrgb8888, .argb8888 => cl.loadstore_format_rgba8888,
            .rgb565 => cl.loadstore_format_bgr565,
        };
    }

    /// A micro-tile, the 64 bytes the tiled layouts are made of: 4x4
    /// pixels of 32 bits, 8x4 of 16.
    pub fn utileWidth(f: Format) u32 {
        return 64 / 4 / f.bytesPerPixel();
    }

    pub fn utileHeight(_: Format) u32 {
        return 4;
    }
};

fn code(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

/// A 0xAARRGGBB colour as an RGB565 pixel (rounded to the nearest).
pub fn toRgb565(argb: u32) u16 {
    const r: u32 = (argb >> 16) & 0xff;
    const g: u32 = (argb >> 8) & 0xff;
    const b: u32 = argb & 0xff;
    return @intCast(((r * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (b * 31 + 127) / 255);
}

/// An RGB565 pixel as 0xffRRGGBB, each channel's bits repeated to fill 8.
pub fn fromRgb565(p: u16) u32 {
    const r: u32 = p >> 11;
    const g: u32 = (p >> 5) & 0x3f;
    const b: u32 = p & 0x1f;
    return 0xff000000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
}

const testing = std.testing;

test "formats' codes and sizes" {
    try testing.expectEqual(@as(?Format, .rgb565), Format.fromFourcc(code("RG16")));
    try testing.expectEqual(@as(?Format, .xrgb8888), Format.fromFourcc(code("XR24")));
    try testing.expectEqual(@as(?Format, null), Format.fromFourcc(code("NV12")));
    try testing.expectEqual(@as(u32, 8), Format.rgb565.utileWidth());
    try testing.expectEqual(@as(u32, 4), Format.xrgb8888.utileWidth());
}

test "RGB565 conversions" {
    try testing.expectEqual(@as(u16, 0xf800), toRgb565(0xffff0000));
    try testing.expectEqual(@as(u16, 0x07e0), toRgb565(0xff00ff00));
    try testing.expectEqual(@as(u16, 0x001f), toRgb565(0xff0000ff));
    try testing.expectEqual(@as(u32, 0xffffffff), fromRgb565(0xffff));
    // Every 565 value survives a round trip.
    var p: u32 = 0;
    while (p < 0x10000) : (p += 1) try testing.expectEqual(@as(u16, @intCast(p)), toRgb565(fromRgb565(@intCast(p))));
}
