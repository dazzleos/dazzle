//! The pixel formats Dazzle renders into, samples as textures and shows on
//! the display: what each is called by DRM (and so Wayland), and what each
//! GPU does with it.
//!
//! Formats are named as DRM names them: the channels of a pixel read as a
//! little-endian number, from its top bits down (ARGB8888: blue in the low
//! byte, alpha in the top), so the same name is the same bytes everywhere.
//! Formats DRM has no name for (floating point, signed, compressed) are
//! named the same way.
//!
//! Each GPU takes a format as it is, or not at all: what it can render to,
//! sample or both without the CPU (or a shader) moving channels about is
//! in `vc4` and `v3d`, and nothing else is offered on it.
//!
//! * The VC4 (Pi 1-3) renders 32-bit ARGB/XRGB and 16-bit BGR565, and
//!   samples those, BGRA4444, BGRA5551, 8-bit alpha and ETC1. Its texture
//!   unit returns a texel's channels in a fixed order, so formats in other
//!   orders would need the shader to swap them: not taken.
//! * The V3D (Pi 4 and 5) renders 32-bit in either order (R/B swapped as
//!   it stores and loads), 16-bit RGB565 (red at the top: it cannot store
//!   BGR565, its R/B swap has no effect on 16-bit), RGBA4444, RGBA5551,
//!   ABGR1555, R8 and GR88, and 10-bit and half-float colour; and samples
//!   all of those and much more (16 bits a channel, floats, signed, ETC2,
//!   EAC, BC1-3, ASTC), its texture unit putting the channels in order.
//!
//! The shaders' colour is red, green, blue and alpha whatever the format:
//! the hardware converts as it samples and stores.

const std = @import("std");
const texture = @import("texture.zig");
const cl = @import("cl.zig");
const v3d_cl = @import("v3d_cl.zig");

pub const Gpu = enum { vc4, v3d };

pub const Format = enum {
    // --- 32 bits a pixel, 8 a channel ---------------------------------
    /// Blue, green, red, then 8 unused, from the low byte.
    xrgb8888,
    /// The same with alpha in the top byte.
    argb8888,
    /// Red, green, blue, unused, from the low byte.
    xbgr8888,
    abgr8888,
    /// Unused, blue, green, red, from the low byte.
    rgbx8888,
    rgba8888,
    /// Unused, red, green, blue, from the low byte.
    bgrx8888,
    bgra8888,
    // --- 32 bits, 10 a colour channel ------------------------------------
    /// Blue in the low 10 bits, then green, red, and 2 unused (or alpha).
    xrgb2101010,
    argb2101010,
    /// Red in the low 10 bits, then green, blue, and 2 unused (or alpha).
    xbgr2101010,
    abgr2101010,
    // --- 16 bits ------------------------------------------------------------
    /// Red in the top 5 bits, green in the middle 6, blue in the low 5.
    rgb565,
    /// Blue in the top 5 bits, green in the middle 6, red in the low 5.
    bgr565,
    /// 4 bits a channel, from the top: alpha, red, green, blue.
    argb4444,
    abgr4444,
    /// From the top: red, green, blue, alpha.
    rgba4444,
    bgra4444,
    /// 5 bits a colour, then 1 of alpha in the low bit.
    rgba5551,
    bgra5551,
    /// 1 bit of alpha at the top, then 5 bits each of blue, green, red.
    abgr1555,
    /// Red in the low byte, green in the high.
    gr88,
    /// Green in the low byte, red in the high.
    rg88,
    // --- 8 bits -------------------------------------------------------------
    /// Red only (green and blue 0, opaque).
    r8,
    /// Alpha (or coverage) only, black.
    a8,
    /// Grey: the same in red, green and blue, opaque.
    l8,
    // --- 16 bits a channel ------------------------------------------------
    r16,
    gr1616,
    xbgr16161616,
    abgr16161616,
    /// Half floats.
    r16f,
    gr1616f,
    xbgr16161616f,
    abgr16161616f,
    // --- 32-bit floats a channel (sampled without filtering) ----------------
    r32f,
    gr3232f,
    abgr32323232f,
    // --- packed floats --------------------------------------------------------
    /// 11-bit floats for red and green, 10-bit for blue, red in the low bits.
    bgr101111f,
    /// 9 bits of mantissa a channel and a shared 5-bit exponent.
    ebgr5999f,
    // --- signed, -1 to 1 --------------------------------------------------
    r8_snorm,
    gr88_snorm,
    abgr8888_snorm,
    r16_snorm,
    gr1616_snorm,
    abgr16161616_snorm,
    // --- compressed, in blocks ---------------------------------------------
    /// 4x4 blocks of 64 bits.
    etc1,
    etc2_rgb8,
    /// With alpha either 0 or 1.
    etc2_rgb8a1,
    /// With EAC alpha: 128-bit blocks.
    etc2_rgba8,
    eac_r11,
    eac_r11_snorm,
    eac_rg11,
    eac_rg11_snorm,
    /// DXT1, opaque, and with 1-bit alpha.
    bc1_rgb,
    bc1_rgba,
    /// DXT3.
    bc2,
    /// DXT5.
    bc3,
    astc_4x4,
    astc_5x4,
    astc_5x5,
    astc_6x5,
    astc_6x6,
    astc_8x5,
    astc_8x6,
    astc_8x8,
    astc_10x5,
    astc_10x6,
    astc_10x8,
    astc_10x10,
    astc_12x10,
    astc_12x12,

    /// Bytes a pixel, for formats that are not compressed.
    pub fn bytesPerPixel(f: Format) u32 {
        std.debug.assert(!f.compressed());
        return f.elementBytes();
    }

    /// Bytes a pixel, or a block of a compressed format: what textures
    /// are laid out in (a compressed image is laid out as an image of its
    /// blocks).
    pub fn elementBytes(f: Format) u32 {
        return info(f).bytes;
    }

    /// Pixels across and down a block (1 by 1 if not compressed).
    pub fn blockWidth(f: Format) u32 {
        return info(f).block[0];
    }

    pub fn blockHeight(f: Format) u32 {
        return info(f).block[1];
    }

    pub fn compressed(f: Format) bool {
        return f.blockWidth() > 1;
    }

    /// Elements (blocks, or pixels) across and down an image `width` by
    /// `height` pixels.
    pub fn elements(f: Format, width: u32, height: u32) [2]u32 {
        return .{ std.math.divCeil(u32, width, f.blockWidth()) catch unreachable, std.math.divCeil(u32, height, f.blockHeight()) catch unreachable };
    }

    /// Whether its pixels have alpha (not just unused bits).
    pub fn hasAlpha(f: Format) bool {
        return info(f).alpha;
    }

    /// Its DRM (and linux-dmabuf, and wl_shm) four-character code, if DRM
    /// has one.
    pub fn fourcc(f: Format) ?u32 {
        return info(f).fourcc;
    }

    pub fn fromFourcc(c: u32) ?Format {
        inline for (@typeInfo(Format).@"enum".field_values) |value| {
            const f: Format = @enumFromInt(value);
            if (f.fourcc() == c) return f;
        }
        return null;
    }

    /// Whether the GPU can render into it (and so it can be a window's
    /// buffer).
    pub fn renderable(f: Format, gpu: Gpu) bool {
        return switch (gpu) {
            .vc4 => f.vc4().render != null,
            .v3d => f.v3d().render != null,
        };
    }

    /// Whether the GPU can sample it as a texture.
    pub fn sampleable(f: Format, gpu: Gpu) bool {
        return switch (gpu) {
            .vc4 => f.vc4().texture != null,
            .v3d => f.v3d().texture != null,
        };
    }

    /// The GPU's 16-bit opaque format: the cheapest window.
    pub fn opaque16(gpu: Gpu) Format {
        return switch (gpu) {
            .vc4 => .bgr565,
            .v3d => .rgb565,
        };
    }

    /// What the VC4 does with it.
    pub fn vc4(f: Format) Vc4 {
        return switch (f) {
            .xrgb8888, .argb8888 => .{ .texture = .rgba8888, .render = cl.render_config_format_rgba8888, .load_store = cl.loadstore_format_rgba8888 },
            // Stored without dithering, so a buffer loaded back and stored
            // again (when only part of a frame is redrawn) keeps its pixels.
            .bgr565 => .{ .texture = .rgb565, .render = cl.render_config_format_bgr565, .load_store = cl.loadstore_format_bgr565 },
            // The texture unit returns the top 4 bits as a texel's low
            // byte, then the next two, and the low 4 bits as its alpha
            // (found on a Pi 3's GPU); and 5551 likewise.
            .bgra4444 => .{ .texture = .rgba4444 },
            .bgra5551 => .{ .texture = .rgba5551 },
            .a8 => .{ .texture = .alpha },
            .etc1 => .{ .texture = .etc1 },
            else => .{},
        };
    }

    /// What the V3D does with it.
    pub fn v3d(f: Format) V3d {
        const r8 = 0;
        const r8_snorm = 1;
        const rg8 = 2;
        const rg8_snorm = 3;
        const rgba8 = 4;
        const rgba8_snorm = 5;
        const rgb565 = 6;
        const rgba4 = 7;
        const rgb5_a1 = 8;
        const rgb10_a2 = 9;
        const r16 = 10;
        const r16_snorm = 11;
        const rg16 = 12;
        const rg16_snorm = 13;
        const rgba16 = 14;
        const rgba16_snorm = 15;
        const r16f = 16;
        const rg16f = 17;
        const rgba16f = 18;
        const r11f_g11f_b10f = 19;
        const rgb9_e5 = 20;
        const r32f = 29;
        const rg32f = 30;
        const rgba32f = 31;
        // Swizzles: which of what the texture format reads (x, y, z, w:
        // its channels from the low bits; for those whose order is noted
        // otherwise in v3d_packet.xml, as noted) gives red, green, blue
        // and alpha.
        const xyzw: [4]Swizzle = .{ .x, .y, .z, .w };
        const xyz1: [4]Swizzle = .{ .x, .y, .z, .one };
        const zyxw: [4]Swizzle = .{ .z, .y, .x, .w };
        const zyx1: [4]Swizzle = .{ .z, .y, .x, .one };
        const tex = struct {
            fn t(ty: u7, s: [4]Swizzle) ?V3d.Texture {
                return .{ .type = ty, .swizzle = s };
            }
        }.t;
        const rgba8_out: V3d.Render = .{ .format = .rgba8 };
        const rgba8_swapped: V3d.Render = .{ .format = .rgba8, .rb_swap = true };
        const half: v3d_cl.InternalType = .type_16f;
        return switch (f) {
            .xrgb8888 => .{ .texture = tex(rgba8, zyx1), .render = rgba8_swapped },
            .argb8888 => .{ .texture = tex(rgba8, zyxw), .render = rgba8_swapped },
            .xbgr8888 => .{ .texture = tex(rgba8, xyz1), .render = rgba8_out },
            .abgr8888 => .{ .texture = tex(rgba8, xyzw), .render = rgba8_out },
            .rgbx8888 => .{ .texture = tex(rgba8, .{ .w, .z, .y, .one }) },
            .rgba8888 => .{ .texture = tex(rgba8, .{ .w, .z, .y, .x }) },
            .bgrx8888 => .{ .texture = tex(rgba8, .{ .y, .z, .w, .one }) },
            .bgra8888 => .{ .texture = tex(rgba8, .{ .y, .z, .w, .x }) },
            .xrgb2101010 => .{ .texture = tex(rgb10_a2, zyx1), .render = .{ .format = .rgb10_a2, .rb_swap = true, .internal = half, .bpp = .bpp_64 } },
            .argb2101010 => .{ .texture = tex(rgb10_a2, zyxw), .render = .{ .format = .rgb10_a2, .rb_swap = true, .internal = half, .bpp = .bpp_64 } },
            .xbgr2101010 => .{ .texture = tex(rgb10_a2, xyz1), .render = .{ .format = .rgb10_a2, .internal = half, .bpp = .bpp_64 } },
            .abgr2101010 => .{ .texture = tex(rgb10_a2, xyzw), .render = .{ .format = .rgb10_a2, .internal = half, .bpp = .bpp_64 } },
            // RGB565 reads red from the top bits as x (v3d_packet.xml has
            // its channels from the top), as RGB565 has it.
            .rgb565 => .{ .texture = tex(rgb565, xyz1), .render = .{ .format = .bgr565 } },
            .bgr565 => .{ .texture = tex(rgb565, zyx1) },
            // RGBA4 and RGB5_A1 read red from the top bits as x, alpha
            // from the low bits as w.
            .rgba4444 => .{ .texture = tex(rgba4, xyzw), .render = .{ .format = .abgr4444 } },
            .bgra4444 => .{ .texture = tex(rgba4, zyxw) },
            .argb4444 => .{ .texture = tex(rgba4, .{ .y, .z, .w, .x }) },
            .abgr4444 => .{ .texture = tex(rgba4, .{ .w, .z, .y, .x }) },
            .rgba5551 => .{ .texture = tex(rgb5_a1, xyzw), .render = .{ .format = .abgr1555 } },
            .bgra5551 => .{ .texture = tex(rgb5_a1, zyxw) },
            .abgr1555 => .{ .render = .{ .format = .rgba5551 } },
            .gr88 => .{ .texture = tex(rg8, .{ .x, .y, .zero, .one }), .render = .{ .format = .rg8 } },
            .rg88 => .{ .texture = tex(rg8, .{ .y, .x, .zero, .one }) },
            .r8 => .{ .texture = tex(r8, .{ .x, .zero, .zero, .one }), .render = .{ .format = .r8 } },
            .a8 => .{ .texture = tex(r8, .{ .zero, .zero, .zero, .x }) },
            .l8 => .{ .texture = tex(r8, .{ .x, .x, .x, .one }) },
            .r16 => .{ .texture = tex(r16, .{ .x, .zero, .zero, .one }) },
            .gr1616 => .{ .texture = tex(rg16, .{ .x, .y, .zero, .one }) },
            .xbgr16161616 => .{ .texture = tex(rgba16, xyz1) },
            .abgr16161616 => .{ .texture = tex(rgba16, xyzw) },
            .r16f => .{ .texture = tex(r16f, .{ .x, .zero, .zero, .one }), .render = .{ .format = .r16f, .internal = half, .bpp = .bpp_64 } },
            .gr1616f => .{ .texture = tex(rg16f, .{ .x, .y, .zero, .one }), .render = .{ .format = .rg16f, .internal = half, .bpp = .bpp_64 } },
            .xbgr16161616f => .{ .texture = tex(rgba16f, xyz1), .render = .{ .format = .rgba16f, .internal = half, .bpp = .bpp_64 } },
            .abgr16161616f => .{ .texture = tex(rgba16f, xyzw), .render = .{ .format = .rgba16f, .internal = half, .bpp = .bpp_64 } },
            .r32f => .{ .texture = tex(r32f, .{ .x, .zero, .zero, .one }), .filterable = false },
            .gr3232f => .{ .texture = tex(rg32f, .{ .x, .y, .zero, .one }), .filterable = false },
            .abgr32323232f => .{ .texture = tex(rgba32f, xyzw), .filterable = false },
            .bgr101111f => .{ .texture = tex(r11f_g11f_b10f, xyz1), .render = .{ .format = .r11f_g11f_b10f, .internal = half, .bpp = .bpp_64 } },
            .ebgr5999f => .{ .texture = tex(rgb9_e5, xyz1) },
            .r8_snorm => .{ .texture = tex(r8_snorm, .{ .x, .zero, .zero, .one }) },
            .gr88_snorm => .{ .texture = tex(rg8_snorm, .{ .x, .y, .zero, .one }) },
            .abgr8888_snorm => .{ .texture = tex(rgba8_snorm, xyzw) },
            .r16_snorm => .{ .texture = tex(r16_snorm, .{ .x, .zero, .zero, .one }) },
            .gr1616_snorm => .{ .texture = tex(rg16_snorm, .{ .x, .y, .zero, .one }) },
            .abgr16161616_snorm => .{ .texture = tex(rgba16_snorm, xyzw) },
            // ETC2 decodes ETC1 (it is ETC1 with more modes).
            .etc1, .etc2_rgb8 => .{ .texture = tex(32, xyz1) },
            .etc2_rgb8a1 => .{ .texture = tex(33, xyzw) },
            .eac_r11 => .{ .texture = tex(34, .{ .x, .zero, .zero, .one }) },
            .eac_r11_snorm => .{ .texture = tex(35, .{ .x, .zero, .zero, .one }) },
            .eac_rg11 => .{ .texture = tex(36, .{ .x, .y, .zero, .one }) },
            .eac_rg11_snorm => .{ .texture = tex(37, .{ .x, .y, .zero, .one }) },
            .etc2_rgba8 => .{ .texture = tex(38, xyzw) },
            .bc1_rgb => .{ .texture = tex(48, xyz1) },
            .bc1_rgba => .{ .texture = tex(48, xyzw) },
            .bc2 => .{ .texture = tex(49, xyzw) },
            .bc3 => .{ .texture = tex(50, xyzw) },
            .astc_4x4, .astc_5x4, .astc_5x5, .astc_6x5, .astc_6x6, .astc_8x5, .astc_8x6, .astc_8x8, .astc_10x5, .astc_10x6, .astc_10x8, .astc_10x10, .astc_12x10, .astc_12x12 => .{
                .texture = tex(@intCast(64 + @intFromEnum(f) - @intFromEnum(Format.astc_4x4)), xyzw),
            },
        };
    }

    /// The utile (micro-tile), the 64 bytes the tiled layouts are made of:
    /// 8x8 elements of 1 byte, 8x4 of 2, 4x4 of 4, and of 8 bytes 2x4 on
    /// the VC4 (its ETC1) and 4x2 on the V3D, 2x2 of 16.
    pub fn utileWidth(f: Format) u32 {
        return switch (f.elementBytes()) {
            1, 2 => 8,
            4 => 4,
            8 => if (!@inComptime() and texture.use_uif) 4 else 2,
            16 => 2,
            else => unreachable,
        };
    }

    pub fn utileHeight(f: Format) u32 {
        return switch (f.elementBytes()) {
            1 => 8,
            2, 4 => 4,
            8 => if (!@inComptime() and texture.use_uif) 2 else 4,
            16 => 2,
            else => unreachable,
        };
    }
};

/// A texel channel the V3D's texture unit takes for an output channel.
pub const Swizzle = enum(u3) { zero = 0, one = 1, x = 2, y = 3, z = 4, w = 5 };

pub const Vc4 = struct {
    /// Its texture type, if sampled.
    texture: ?texture.Type = null,
    /// How the tile buffer stores it, if rendered to: for the render
    /// configuration, and for load/store packets.
    render: ?u2 = null,
    load_store: ?u2 = null,
};

pub const V3d = struct {
    texture: ?Texture = null,
    /// Whether it may be filtered (32-bit floats may not).
    filterable: bool = true,
    render: ?Render = null,

    pub const Texture = struct {
        /// Its Texture Data Format (v3d_packet.xml).
        type: u7,
        /// Which texel channels give red, green, blue and alpha.
        swizzle: [4]Swizzle,
    };

    pub const Render = struct {
        format: v3d_cl.OutputImageFormat,
        /// Red and blue swapped as the tile buffer is stored and loaded.
        rb_swap: bool = false,
        /// How the tile buffer holds it.
        internal: v3d_cl.InternalType = .type_8,
        bpp: v3d_cl.InternalBpp = .bpp_32,
    };
};

const Info = struct { bytes: u8, block: [2]u8 = .{ 1, 1 }, fourcc: ?u32 = null, alpha: bool = false };

fn info(f: Format) Info {
    return switch (f) {
        .xrgb8888 => .{ .bytes = 4, .fourcc = code("XR24") },
        .argb8888 => .{ .bytes = 4, .fourcc = code("AR24"), .alpha = true },
        .xbgr8888 => .{ .bytes = 4, .fourcc = code("XB24") },
        .abgr8888 => .{ .bytes = 4, .fourcc = code("AB24"), .alpha = true },
        .rgbx8888 => .{ .bytes = 4, .fourcc = code("RX24") },
        .rgba8888 => .{ .bytes = 4, .fourcc = code("RA24"), .alpha = true },
        .bgrx8888 => .{ .bytes = 4, .fourcc = code("BX24") },
        .bgra8888 => .{ .bytes = 4, .fourcc = code("BA24"), .alpha = true },
        .xrgb2101010 => .{ .bytes = 4, .fourcc = code("XR30") },
        .argb2101010 => .{ .bytes = 4, .fourcc = code("AR30"), .alpha = true },
        .xbgr2101010 => .{ .bytes = 4, .fourcc = code("XB30") },
        .abgr2101010 => .{ .bytes = 4, .fourcc = code("AB30"), .alpha = true },
        .rgb565 => .{ .bytes = 2, .fourcc = code("RG16") },
        .bgr565 => .{ .bytes = 2, .fourcc = code("BG16") },
        .argb4444 => .{ .bytes = 2, .fourcc = code("AR12"), .alpha = true },
        .abgr4444 => .{ .bytes = 2, .fourcc = code("AB12"), .alpha = true },
        .rgba4444 => .{ .bytes = 2, .fourcc = code("RA12"), .alpha = true },
        .bgra4444 => .{ .bytes = 2, .fourcc = code("BA12"), .alpha = true },
        .rgba5551 => .{ .bytes = 2, .fourcc = code("RA15"), .alpha = true },
        .bgra5551 => .{ .bytes = 2, .fourcc = code("BA15"), .alpha = true },
        .abgr1555 => .{ .bytes = 2, .fourcc = code("AB15"), .alpha = true },
        .gr88 => .{ .bytes = 2, .fourcc = code("GR88") },
        .rg88 => .{ .bytes = 2, .fourcc = code("RG88") },
        .r8 => .{ .bytes = 1, .fourcc = code("R8  ") },
        .a8 => .{ .bytes = 1, .alpha = true },
        .l8 => .{ .bytes = 1 },
        .r16 => .{ .bytes = 2, .fourcc = code("R16 ") },
        .gr1616 => .{ .bytes = 4, .fourcc = code("GR32") },
        .xbgr16161616 => .{ .bytes = 8, .fourcc = code("XB48") },
        .abgr16161616 => .{ .bytes = 8, .fourcc = code("AB48"), .alpha = true },
        .r16f => .{ .bytes = 2 },
        .gr1616f => .{ .bytes = 4 },
        .xbgr16161616f => .{ .bytes = 8, .fourcc = code("XB4H") },
        .abgr16161616f => .{ .bytes = 8, .fourcc = code("AB4H"), .alpha = true },
        .r32f => .{ .bytes = 4 },
        .gr3232f => .{ .bytes = 8 },
        .abgr32323232f => .{ .bytes = 16, .alpha = true },
        .bgr101111f, .ebgr5999f => .{ .bytes = 4 },
        .r8_snorm => .{ .bytes = 1 },
        .gr88_snorm, .r16_snorm => .{ .bytes = 2 },
        .abgr8888_snorm, .gr1616_snorm => .{ .bytes = 4 },
        .abgr16161616_snorm => .{ .bytes = 8 },
        .etc1, .etc2_rgb8, .eac_r11, .eac_r11_snorm, .bc1_rgb => .{ .bytes = 8, .block = .{ 4, 4 } },
        .etc2_rgb8a1, .bc1_rgba => .{ .bytes = 8, .block = .{ 4, 4 }, .alpha = true },
        .eac_rg11, .eac_rg11_snorm => .{ .bytes = 16, .block = .{ 4, 4 } },
        .etc2_rgba8, .bc2, .bc3 => .{ .bytes = 16, .block = .{ 4, 4 }, .alpha = true },
        .astc_4x4 => .{ .bytes = 16, .block = .{ 4, 4 }, .alpha = true },
        .astc_5x4 => .{ .bytes = 16, .block = .{ 5, 4 }, .alpha = true },
        .astc_5x5 => .{ .bytes = 16, .block = .{ 5, 5 }, .alpha = true },
        .astc_6x5 => .{ .bytes = 16, .block = .{ 6, 5 }, .alpha = true },
        .astc_6x6 => .{ .bytes = 16, .block = .{ 6, 6 }, .alpha = true },
        .astc_8x5 => .{ .bytes = 16, .block = .{ 8, 5 }, .alpha = true },
        .astc_8x6 => .{ .bytes = 16, .block = .{ 8, 6 }, .alpha = true },
        .astc_8x8 => .{ .bytes = 16, .block = .{ 8, 8 }, .alpha = true },
        .astc_10x5 => .{ .bytes = 16, .block = .{ 10, 5 }, .alpha = true },
        .astc_10x6 => .{ .bytes = 16, .block = .{ 10, 6 }, .alpha = true },
        .astc_10x8 => .{ .bytes = 16, .block = .{ 10, 8 }, .alpha = true },
        .astc_10x10 => .{ .bytes = 16, .block = .{ 10, 10 }, .alpha = true },
        .astc_12x10 => .{ .bytes = 16, .block = .{ 12, 10 }, .alpha = true },
        .astc_12x12 => .{ .bytes = 16, .block = .{ 12, 12 }, .alpha = true },
    };
}

fn code(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

/// A 0xAARRGGBB colour as a BGR565 pixel (rounded to the nearest): blue
/// in the top 5 bits, red in the low 5.
pub inline fn toBgr565(argb: u32) u16 {
    const r: u32 = (argb >> 16) & 0xff;
    const g: u32 = (argb >> 8) & 0xff;
    const b: u32 = argb & 0xff;
    return @intCast(((b * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (r * 31 + 127) / 255);
}

/// A BGR565 pixel as 0xffRRGGBB, each channel's bits repeated to fill 8.
pub inline fn fromBgr565(p: u16) u32 {
    const b: u32 = p >> 11;
    const g: u32 = (p >> 5) & 0x3f;
    const r: u32 = p & 0x1f;
    return 0xff000000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
}

pub inline fn toBgr565Vec8(argb: @Vector(8, u32)) @Vector(8, u16) {
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

pub inline fn fromBgr565Vec8(p16: @Vector(8, u16)) @Vector(8, u32) {
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

test "every format the GPUs take is laid out, and DRM codes are each one format" {
    inline for (@typeInfo(Format).@"enum".field_values) |value| {
        const f: Format = @enumFromInt(value);
        _ = f.utileWidth();
        if (f.fourcc()) |c| try testing.expectEqual(@as(?Format, f), Format.fromFourcc(c));
        // What the VC4 renders it samples too.
        if (f.renderable(.vc4)) try testing.expect(f.sampleable(.vc4));
        if (f.vc4().render != null) try testing.expect(f.vc4().load_store != null);
    }
    try testing.expectEqual(Format.bgr565, Format.opaque16(.vc4));
    try testing.expect(Format.opaque16(.v3d).renderable(.v3d));
    try testing.expect(!Format.bgr565.renderable(.v3d));
    try testing.expect(!Format.rgb565.renderable(.vc4));
}

test "formats' codes and sizes" {
    try testing.expectEqual(@as(?Format, .rgb565), Format.fromFourcc(code("RG16")));
    try testing.expectEqual(@as(?u32, null), Format.a8.fourcc());
    try testing.expectEqual(@as(u32, 16), Format.astc_6x5.elementBytes());
    try testing.expectEqual(@as([2]u32, .{ 2, 3 }), Format.astc_6x5.elements(12, 11));
    try testing.expectEqual(@as(?Format, .bgr565), Format.fromFourcc(code("BG16")));
    try testing.expectEqual(@as(?Format, .xrgb8888), Format.fromFourcc(code("XR24")));
    try testing.expectEqual(@as(?Format, null), Format.fromFourcc(code("NV12")));
    try testing.expectEqual(@as(u32, 8), Format.bgr565.utileWidth());
    try testing.expectEqual(@as(u32, 4), Format.xrgb8888.utileWidth());
    try testing.expectEqual(@as(u32, 8), Format.a8.utileHeight());
}

test "BGR565 conversions" {
    try testing.expectEqual(@as(u16, 0x001f), toBgr565(0xffff0000));
    try testing.expectEqual(@as(u16, 0x07e0), toBgr565(0xff00ff00));
    try testing.expectEqual(@as(u16, 0xf800), toBgr565(0xff0000ff));
    try testing.expectEqual(@as(u32, 0xffffffff), fromBgr565(0xffff));
    // Every 565 value survives a round trip, and 8-wide SIMD matches scalar.
    var p: u32 = 0;
    while (p < 0x10000) : (p += 8) {
        var in16: [8]u16 = undefined;
        for (0..8) |i| in16[i] = @intCast(p + i);
        const rgb32: [8]u32 = fromBgr565Vec8(in16);
        const out16: [8]u16 = toBgr565Vec8(rgb32);
        for (0..8) |i| {
            try testing.expectEqual(fromBgr565(in16[i]), rgb32[i]);
            try testing.expectEqual(in16[i], out16[i]);
        }
    }
}
