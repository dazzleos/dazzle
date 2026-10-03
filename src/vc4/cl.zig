//! Builders for V3D control lists and the structures they reference.
//!
//! With vc4, userspace only writes the *binning* control list (BCL). The
//! kernel generates the rendering control list itself from the surface
//! description in `drm_vc4_submit_cl`, after validating everything.
//!
//! Packet layouts: kernel drivers/gpu/drm/vc4/vc4_packet.h and Mesa's
//! src/broadcom/cle/v3d_packet_v21.xml.

const std = @import("std");

pub const Packet = enum(u8) {
    halt = 0,
    nop = 1,
    flush = 4,
    flush_all = 5,
    start_tile_binning = 6,
    increment_semaphore = 7,
    gl_indexed_primitive = 32,
    gl_array_primitive = 33,
    primitive_list_format = 56,
    gl_shader_state = 64,
    configuration_bits = 96,
    flat_shade_flags = 97,
    point_size = 98,
    line_width = 99,
    depth_offset = 101,
    clip_window = 102,
    viewport_offset = 103,
    clipper_xy_scaling = 105,
    clipper_z_scaling = 106,
    tile_binning_mode_config = 112,
    /// Not a hardware packet: tells the kernel which bo_handles entries the
    /// following indexed primitive's index buffer uses.
    gem_handles = 254,
};

pub const PrimitiveMode = enum(u8) {
    points = 0,
    lines = 1,
    line_loop = 2,
    line_strip = 3,
    triangles = 4,
    triangle_strip = 5,
    triangle_fan = 6,
};

pub const CompareFunc = enum(u3) { never, less, equal, lequal, greater, notequal, gequal, always };

/// Tiles are 64x64 pixels without multisampling.
pub const tile_size = 64;

/// A little-endian byte stream in a caller-provided buffer.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }

    pub fn u8_(w: *Writer, v: u8) void {
        w.buf[w.len] = v;
        w.len += 1;
    }

    pub fn u16_(w: *Writer, v: u16) void {
        std.mem.writeInt(u16, w.buf[w.len..][0..2], v, .little);
        w.len += 2;
    }

    pub fn u32_(w: *Writer, v: u32) void {
        std.mem.writeInt(u32, w.buf[w.len..][0..4], v, .little);
        w.len += 4;
    }

    pub fn f32_(w: *Writer, v: f32) void {
        w.u32_(@bitCast(v));
    }

    pub fn packet(w: *Writer, p: Packet) void {
        w.u8_(@intFromEnum(p));
    }
};

/// Binning control list builder.
pub const Bcl = struct {
    w: Writer,

    pub fn init(buf: []u8) Bcl {
        return .{ .w = .init(buf) };
    }

    pub fn bytes(b: *const Bcl) []const u8 {
        return b.w.bytes();
    }

    /// Must come first. The kernel allocates the tile state and tile
    /// allocation memory and fills in their addresses and the flags.
    pub fn tileBinningModeConfig(b: *Bcl, width_tiles: u8, height_tiles: u8) void {
        b.w.packet(.tile_binning_mode_config);
        b.w.u32_(0); // tile allocation memory address
        b.w.u32_(0); // tile allocation memory size
        b.w.u32_(0); // tile state data array address
        b.w.u8_(width_tiles);
        b.w.u8_(height_tiles);
        b.w.u8_(0); // flags
    }

    pub fn startTileBinning(b: *Bcl) void {
        b.w.packet(.start_tile_binning);
    }

    /// Sets the format the binner uses when writing primitives into the
    /// per-tile lists.
    pub fn primitiveListFormat(b: *Bcl) void {
        b.w.packet(.primitive_list_format);
        b.w.u8_(0x12); // 16-bit index, triangles list
    }

    pub fn clipWindow(b: *Bcl, left: u16, bottom: u16, width: u16, height: u16) void {
        b.w.packet(.clip_window);
        b.w.u16_(left);
        b.w.u16_(bottom);
        b.w.u16_(width);
        b.w.u16_(height);
    }

    pub const Config = struct {
        enable_forward_facing: bool = true,
        enable_reverse_facing: bool = true,
        clockwise_primitives: bool = false,
        depth_func: CompareFunc = .always,
        z_updates: bool = false,
        early_z: bool = false,
        early_z_updates: bool = true,
    };

    pub fn configurationBits(b: *Bcl, c: Config) void {
        b.w.packet(.configuration_bits);
        b.w.u8_(@as(u8, @intFromBool(c.enable_forward_facing)) |
            @as(u8, @intFromBool(c.enable_reverse_facing)) << 1 |
            @as(u8, @intFromBool(c.clockwise_primitives)) << 2);
        b.w.u8_(@as(u8, @intFromEnum(c.depth_func)) << 4 |
            @as(u8, @intFromBool(c.z_updates)) << 7);
        b.w.u8_(@as(u8, @intFromBool(c.early_z)) |
            @as(u8, @intFromBool(c.early_z_updates)) << 1);
    }

    /// Viewport centre in pixels; stored as signed 12.4 fixed point.
    pub fn viewportOffset(b: *Bcl, x: f32, y: f32) void {
        b.w.packet(.viewport_offset);
        b.w.u16_(@bitCast(@as(i16, @intFromFloat(x * 16.0))));
        b.w.u16_(@bitCast(@as(i16, @intFromFloat(y * 16.0))));
    }

    pub fn clipperXyScaling(b: *Bcl, half_width_16ths: f32, half_height_16ths: f32) void {
        b.w.packet(.clipper_xy_scaling);
        b.w.f32_(half_width_16ths);
        b.w.f32_(half_height_16ths);
    }

    pub fn clipperZScaling(b: *Bcl, scale: f32, offset: f32) void {
        b.w.packet(.clipper_z_scaling);
        b.w.f32_(scale);
        b.w.f32_(offset);
    }

    /// Selects the next shader record. The kernel assigns records in order,
    /// so the payload only carries the attribute count (0 means 8).
    pub fn glShaderState(b: *Bcl, num_attributes: u4) void {
        std.debug.assert(num_attributes >= 1 and num_attributes <= 8);
        b.w.packet(.gl_shader_state);
        b.w.u32_(num_attributes & 7);
    }

    /// Sets the buffers the next indexed primitive reads indices from, by
    /// bo_handles index (the second is unused by the kernel today).
    pub fn gemHandles(b: *Bcl, index0: u32, index1: u32) void {
        b.w.packet(.gem_handles);
        b.w.u32_(index0);
        b.w.u32_(index1);
    }

    /// Draws using 8- or 16-bit indices from the buffer set by
    /// `gemHandles`, starting at byte `offset`.
    pub fn glIndexedPrimitive(b: *Bcl, mode: PrimitiveMode, u16_indices: bool, count: u32, offset: u32, max_index: u32) void {
        b.w.packet(.gl_indexed_primitive);
        b.w.u8_(@intFromEnum(mode) | @as(u8, @intFromBool(u16_indices)) << 4);
        b.w.u32_(count);
        b.w.u32_(offset);
        b.w.u32_(max_index);
    }

    pub fn glArrayPrimitive(b: *Bcl, mode: PrimitiveMode, count: u32, first: u32) void {
        b.w.packet(.gl_array_primitive);
        b.w.u8_(@intFromEnum(mode));
        b.w.u32_(count);
        b.w.u32_(first);
    }

    /// Ends binning: the semaphore lets rendering start once the FLUSH has
    /// terminated every tile list. The kernel requires exactly this tail.
    pub fn finish(b: *Bcl) void {
        b.w.packet(.increment_semaphore);
        b.w.packet(.flush);
    }
};

pub const shader_flag_fs_single_thread = 1 << 0;
pub const shader_flag_vs_point_size = 1 << 1;
pub const shader_flag_enable_clipping = 1 << 2;

pub const Attribute = struct {
    /// Index of the vertex buffer in `bo_handles`.
    bo_index: u32,
    offset: u32,
    size: u8,
    stride: u8,
    vs_vpm_offset: u8,
    cs_vpm_offset: u8,
};

pub const ShaderRecord = struct {
    flags: u16,
    fs_num_varyings: u8,
    /// Indices of the shader BOs in `bo_handles`. Code must start at offset
    /// 0 of each BO.
    fs_bo_index: u32,
    vs_bo_index: u32,
    cs_bo_index: u32,
    /// Bit i set if attribute i is loaded into the VPM for that shader.
    vs_attribute_mask: u8,
    vs_attributes_size: u8,
    cs_attribute_mask: u8,
    cs_attributes_size: u8,
    attributes: []const Attribute,
};

/// Appends a shader record in the form the kernel expects: one u32 BO index
/// per relocation (FS, VS, CS, then each attribute), followed by the
/// hardware record with addresses replaced by offsets within those BOs.
pub fn writeShaderRecord(w: *Writer, rec: ShaderRecord) void {
    std.debug.assert(rec.attributes.len >= 1 and rec.attributes.len <= 8);
    w.u32_(rec.fs_bo_index);
    w.u32_(rec.vs_bo_index);
    w.u32_(rec.cs_bo_index);
    for (rec.attributes) |a| w.u32_(a.bo_index);

    w.u16_(rec.flags);
    w.u8_(0); // FS number of uniforms (unused)
    w.u8_(rec.fs_num_varyings);
    w.u32_(0); // FS code offset
    w.u32_(0); // FS uniforms address (filled in by the kernel)
    w.u16_(0); // VS number of uniforms (unused)
    w.u8_(rec.vs_attribute_mask);
    w.u8_(rec.vs_attributes_size);
    w.u32_(0); // VS code offset
    w.u32_(0); // VS uniforms address
    w.u16_(0); // CS number of uniforms (unused)
    w.u8_(rec.cs_attribute_mask);
    w.u8_(rec.cs_attributes_size);
    w.u32_(0); // CS code offset
    w.u32_(0); // CS uniforms address
    for (rec.attributes) |a| {
        w.u32_(a.offset);
        w.u8_(a.size - 1);
        w.u8_(a.stride);
        w.u8_(a.vs_vpm_offset);
        w.u8_(a.cs_vpm_offset);
    }
}

// --- Render target bits (drm_vc4_submit_rcl_surface.bits) --------------------

pub const Tiling = enum(u2) { linear = 0, t = 1, lt = 2 };

pub const render_config_format_bgr565_dithered = 0;
pub const render_config_format_rgba8888 = 1;
pub const render_config_format_bgr565 = 2;

pub const LoadStoreBuffer = enum(u3) { none = 0, color = 1, zs = 2, z = 3, vg_mask = 4, full = 5 };
pub const loadstore_format_rgba8888 = 0;
pub const loadstore_format_bgr565_dither = 1;
pub const loadstore_format_bgr565 = 2;

/// Bits for `color_read` and the Z/S surfaces, which use the general tile
/// buffer load/store packet layout.
pub fn loadStoreBits(tiling: Tiling, buffer: LoadStoreBuffer, format: u2) u16 {
    return @as(u16, format) << 8 | @as(u16, @intFromEnum(tiling)) << 4 | @intFromEnum(buffer);
}

/// Bits for `color_write`, which uses the render config packet layout.
pub fn renderConfigBits(tiling: Tiling, format: u2) u16 {
    return @as(u16, @intFromEnum(tiling)) << 6 | @as(u16, format) << 2;
}

const testing = std.testing;

test "packet sizes match the kernel's table" {
    var buf: [64]u8 = undefined;
    const Case = struct { p: Packet, size: usize };
    inline for (.{
        Case{ .p = .tile_binning_mode_config, .size = 16 },
        Case{ .p = .clip_window, .size = 9 },
        Case{ .p = .configuration_bits, .size = 4 },
        Case{ .p = .viewport_offset, .size = 5 },
        Case{ .p = .clipper_xy_scaling, .size = 9 },
        Case{ .p = .clipper_z_scaling, .size = 9 },
        Case{ .p = .gl_shader_state, .size = 5 },
        Case{ .p = .gl_array_primitive, .size = 10 },
        Case{ .p = .primitive_list_format, .size = 2 },
        Case{ .p = .gl_indexed_primitive, .size = 14 },
        Case{ .p = .gem_handles, .size = 9 },
    }) |c| {
        var b: Bcl = .init(&buf);
        switch (c.p) {
            .tile_binning_mode_config => b.tileBinningModeConfig(1, 1),
            .clip_window => b.clipWindow(0, 0, 1, 1),
            .configuration_bits => b.configurationBits(.{}),
            .viewport_offset => b.viewportOffset(1, 1),
            .clipper_xy_scaling => b.clipperXyScaling(1, 1),
            .clipper_z_scaling => b.clipperZScaling(1, 1),
            .gl_shader_state => b.glShaderState(1),
            .gl_array_primitive => b.glArrayPrimitive(.triangles, 3, 0),
            .primitive_list_format => b.primitiveListFormat(),
            .gl_indexed_primitive => b.glIndexedPrimitive(.triangles, true, 3, 0, 2),
            .gem_handles => b.gemHandles(1, 0),
            else => unreachable,
        }
        try testing.expectEqual(c.size, b.bytes().len);
        try testing.expectEqual(@intFromEnum(c.p), b.bytes()[0]);
    }
}

test "shader record size" {
    var buf: [128]u8 = undefined;
    var w: Writer = .init(&buf);
    const attrs = [_]Attribute{
        .{ .bo_index = 4, .offset = 0, .size = 8, .stride = 20, .vs_vpm_offset = 0, .cs_vpm_offset = 0 },
        .{ .bo_index = 4, .offset = 8, .size = 12, .stride = 20, .vs_vpm_offset = 8, .cs_vpm_offset = 0 },
    };
    writeShaderRecord(&w, .{
        .flags = 0,
        .fs_num_varyings = 3,
        .fs_bo_index = 1,
        .vs_bo_index = 2,
        .cs_bo_index = 3,
        .vs_attribute_mask = 3,
        .vs_attributes_size = 20,
        .cs_attribute_mask = 1,
        .cs_attributes_size = 8,
        .attributes = &attrs,
    });
    // 5 relocation indices + gl_shader_rec_size() = 36 + 8 * attributes.
    try testing.expectEqual(5 * 4 + 36 + 8 * 2, w.len);
}
