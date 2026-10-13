//! Control List (BCL / RCL) packet and state record encoders for V3D 4.2
//! (VideoCore VI, BCM2711).
//!
//! Mirrors Mesa's `src/broadcom/cle/v3d_packet.xml` (ver = 42),
//! `src/gallium/drivers/v3d/v3dx_rcl.c`, `v3dx_emit.c`, `v3dx_draw.c`, and
//! `v3dx_state.c`. Unlike V3D 2.1 (`cl.zig`), V3D 4.2 uses an MMU and
//! userspace writes 32-bit GPU virtual addresses directly into the BCL, RCL,
//! shader records, attribute records, and texture/sampler state records.

const std = @import("std");
const cl = @import("cl.zig");
const Format = @import("format.zig").Format;
const texture = @import("texture.zig");

pub const Packet = enum(u8) {
    halt = 0,
    nop = 1,
    flush = 4,
    flush_all_state = 5,
    start_tile_binning = 6,
    increment_semaphore = 7,
    wait_on_semaphore = 8,
    end_of_rendering = 13,
    branch_to_auto_chained_sub_list = 15,
    branch = 16,
    branch_to_sub_list = 17,
    return_from_sub_list = 18,
    flush_vcd_cache = 19,
    start_address_of_generic_tile_list = 20,
    branch_to_implicit_tile_list = 21,
    supertile_coordinates = 23,
    clear_tile_buffers = 25,
    end_of_loads = 26,
    end_of_tile_marker = 27,
    store_tile_buffer_general = 29,
    load_tile_buffer_general = 30,
    indexed_prim_list = 32,
    vertex_array_prims = 36,
    index_buffer_setup = 44,
    set_instanceid = 54,
    prim_list_format = 56,
    gl_shader_state = 64,
    vcm_cache_size = 71,
    transform_feedback_specs = 74,
    blend_enables = 83,
    blend_cfg = 84,
    blend_constant_color = 86,
    color_write_masks = 87,
    zero_all_centroid_flags = 88,
    sample_state = 91,
    occlusion_query_counter = 92,
    cfg_bits = 96,
    zero_all_flat_shade_flags = 97,
    zero_all_non_perspective_flags = 99,
    point_size = 104,
    line_width = 105,
    clip_window = 107,
    viewport_offset = 108,
    clipper_z_min_max_clipping_planes = 109,
    clipper_xy_scaling = 110,
    clipper_z_scale_and_offset = 111,
    number_of_layers = 119,
    tile_binning_mode_cfg = 120,
    tile_rendering_mode_cfg = 121,
    multicore_rendering_supertile_cfg = 122,
    multicore_rendering_tile_list_set_base = 123,
    tile_coordinates = 124,
    tile_coordinates_implicit = 125,
    tile_list_initial_block_size = 126,
};

pub const MemoryFormat = enum(u3) {
    raster = 0,
    lineartile = 1,
    ub_linear_1_uif_wide = 2,
    ub_linear_2_uif_wide = 3,
    uif_no_xor = 4,
    uif_xor = 5,
};

pub const OutputImageFormat = enum(u6) {
    srgb8_alpha8 = 0,
    bgr565 = 7,
    rgba16f = 18,
    rgba8 = 27,
    d24s8 = 43,
};

pub const InternalType = enum(u4) {
    type_8i = 0,
    type_8ui = 1,
    type_8 = 2,
    type_16i = 4,
    type_16ui = 5,
    type_16f = 6,
    type_32i = 8,
    type_32ui = 9,
    type_32f = 10,
};

pub const InternalBpp = enum(u2) {
    bpp_32 = 0,
    bpp_64 = 1,
    bpp_128 = 2,
};

pub const InternalDepthType = enum(u4) {
    depth_32f = 0,
    depth_24 = 1,
    depth_16 = 2,
};

pub const DecimateMode = enum(u2) {
    sample_0 = 0,
    mode_4x = 1,
    all_samples = 3,
};

pub const Buffer = enum(u4) {
    render_target_0 = 0,
    none = 8,
    z = 9,
    stencil = 10,
    z_stencil = 11,
};

/// Returns the V3D 4.2 `OutputImageFormat` and whether R and B must be swapped
/// when loading/storing the tile buffer.
pub fn outputFormat(format: Format) struct { fmt: OutputImageFormat, rb_swap: bool } {
    return switch (format) {
        // 0xAARRGGBB in little-endian memory has B in bits 0..7 and R in bits
        // 16..23; V3D_OUTPUT_IMAGE_FORMAT_RGBA8 has R in bits 0..7, so R/B swap
        // converts between the two.
        .xrgb8888, .argb8888 => .{ .fmt = .rgba8, .rb_swap = true },
        // V3D_OUTPUT_IMAGE_FORMAT_BGR565 has B in bits 0..4, G in 5..10, and
        // R in 11..15; R/B swap puts B in bits 11..15 and R in 0..4 (DRM_FORMAT_BGR565),
        // matching VC4.
        .rgb565 => .{ .fmt = .bgr565, .rb_swap = true },
        .a8 => unreachable,
    };
}

/// Converts a `cl.Tiling` for a target of `(width, height)` in `format` to the
/// V3D 4.2 `MemoryFormat` and `height_in_ub_or_stride` parameter.
pub fn targetLayout(format: Format, tiling: cl.Tiling, width: u16, height: u16) struct {
    mem_format: MemoryFormat,
    height_in_ub_or_stride: u20,
    uif_padded_height_in_ub: u13,
    implicit_padded_height_in_ub: u13,
} {
    if (tiling == .linear) {
        const stride = std.mem.alignForward(u32, width, format.utileWidth()) * format.bytesPerPixel();
        return .{
            .mem_format = .raster,
            .height_in_ub_or_stride = @intCast(stride),
            .uif_padded_height_in_ub = 0,
            .implicit_padded_height_in_ub = 0,
        };
    }
    const ub_h = format.utileHeight() * 2;
    const slice = texture.uifSlice(format, width, height);
    const padded_ub: u13 = @intCast(slice.padded_height / ub_h);
    const implicit_ub: u13 = @intCast(std.mem.alignForward(u32, height, ub_h) / ub_h);
    const mem_format: MemoryFormat = switch (slice.tiling) {
        .raster => .raster,
        .lineartile => .lineartile,
        .ublinear_1_column => .ub_linear_1_uif_wide,
        .ublinear_2_column => .ub_linear_2_uif_wide,
        .uif_no_xor => .uif_no_xor,
        .uif_xor => .uif_xor,
    };
    return .{
        .mem_format = mem_format,
        .height_in_ub_or_stride = padded_ub,
        .uif_padded_height_in_ub = padded_ub,
        .implicit_padded_height_in_ub = implicit_ub,
    };
}

/// Converts a floating-point coordinate to V3D 4.2's `(coarse: i10, fine: u22)`
/// `u14.8` fixed-point representation (see `v3dx_emit.c` `VIEWPORT_OFFSET`).
fn viewportCoord(v: f32) struct { fine: u22, coarse: u10 } {
    var fine_f = v;
    var coarse: i32 = 0;
    if (fine_f < 0) {
        const blocks: i32 = @intFromFloat(@ceil(-fine_f / 64.0));
        fine_f += 64.0 * @as(f32, @floatFromInt(blocks));
        coarse -= blocks;
    }
    const fine_fixed: u32 = @intFromFloat(@round(fine_f * 256.0));
    const coarse_u10: u10 = @bitCast(@as(i10, @intCast(coarse)));
    return .{ .fine = @intCast(fine_fixed & 0x3fffff), .coarse = coarse_u10 };
}

/// Binning Control List (BCL) writer for V3D 4.2.
pub const Bcl = struct {
    w: cl.Writer,

    pub fn init(buf: []u8) Bcl {
        return .{ .w = .init(buf) };
    }

    pub fn bytes(b: *const Bcl) []const u8 {
        return b.w.bytes();
    }

    pub fn numberOfLayers(b: *Bcl, layers: u8) void {
        b.w.u8_(@intFromEnum(Packet.number_of_layers));
        b.w.u8_(layers - 1);
    }

    /// Emits `TILE_BINNING_MODE_CFG`, `FLUSH_VCD_CACHE`,
    /// `OCCLUSION_QUERY_COUNTER`, and `START_TILE_BINNING`, plus initial state
    /// resets (`TRANSFORM_FEEDBACK_SPECS`, `BLEND_ENABLES`, `COLOR_WRITE_MASKS`,
    /// `ZERO_ALL_FLAT_SHADE_FLAGS`, `ZERO_ALL_NON_PERSPECTIVE_FLAGS`,
    /// `ZERO_ALL_CENTROID_FLAGS`, `SAMPLE_STATE`).
    pub fn startBinning(b: *Bcl, width: u16, height: u16, msaa: bool, v3d_ver: u8) void {
        b.numberOfLayers(1);

        // Packet 120: Tile Binning Mode Cfg (8 bytes payload).
        // On V3D 4.2: bit 14 = multisample_mode_4x.
        // On V3D 7.1: bits 8..10 = log2_tile_width (3 -> 64), bits 11..13 = log2_tile_height (3 -> 64, 2 -> 32).
        b.w.u8_(@intFromEnum(Packet.tile_binning_mode_cfg));
        const flags: u32 = if (v3d_ver >= 71)
            (@as(u32, 3) << 8) | (@as(u32, if (msaa) 2 else 3) << 11)
        else if (msaa)
            (1 << 14)
        else
            0;
        b.w.u32_(flags);
        b.w.u16_(width - 1);
        b.w.u16_(height - 1);

        b.w.u8_(@intFromEnum(Packet.flush_vcd_cache));

        // Packet 92: Occlusion Query Counter (0 = disabled).
        b.w.u8_(@intFromEnum(Packet.occlusion_query_counter));
        b.w.u32_(0);

        b.w.u8_(@intFromEnum(Packet.start_tile_binning));

        // Transform feedback disabled.
        b.w.u8_(@intFromEnum(Packet.transform_feedback_specs));
        b.w.u8_(0);

        // Hardware blend disabled (Dazzle shaders blend in QPU code via TLB
        // color reads, or write opaque colors).
        b.w.u8_(@intFromEnum(Packet.blend_enables));
        b.w.u8_(0);

        // Packet 87: Color Write Masks (0 = all channels enabled).
        b.w.u8_(@intFromEnum(Packet.color_write_masks));
        b.w.u32_(0);

        // Varying interpolation flags: all perspective, non-centroid, smooth.
        b.w.u8_(@intFromEnum(Packet.zero_all_flat_shade_flags));
        b.w.u8_(@intFromEnum(Packet.zero_all_non_perspective_flags));
        b.w.u8_(@intFromEnum(Packet.zero_all_centroid_flags));

        // Packet 91: Sample State (mask = 0xf, coverage = 1.0 in f187 = 0x3f80).
        b.w.u8_(@intFromEnum(Packet.sample_state));
        b.w.u16_(0x000f);
        b.w.u16_(0x3f80);

        // Default line width = 1.0f.
        b.w.u8_(@intFromEnum(Packet.line_width));
        b.w.f32_(1.0);
    }

    pub fn clipWindow(b: *Bcl, x: u16, y: u16, width: u16, height: u16) void {
        b.w.u8_(@intFromEnum(Packet.clip_window));
        b.w.u16_(x);
        b.w.u16_(y);
        b.w.u16_(width);
        b.w.u16_(height);
    }

    pub fn cfgBits(b: *Bcl, c: cl.Bcl.Config, msaa: bool, v3d_ver: u8) void {
        // Packet 96: Cfg Bits (3 bytes payload = 24 bits).
        var bits: u32 = 0;
        if (c.enable_forward_facing) bits |= 1 << 0;
        if (c.enable_reverse_facing) bits |= 1 << 1;
        if (c.clockwise_primitives) bits |= 1 << 2;
        if (msaa) bits |= 1 << 6;
        bits |= @as(u32, @intFromEnum(c.depth_func)) << 12;
        if (c.z_updates) bits |= 1 << 15;
        if (v3d_ver >= 71) {
            // V3D_Z_CLIP_MODE_MIN_ONE_TO_ONE (1) in bits 22..23
            bits |= 1 << 22;
        } else {
            if (c.early_z) bits |= 1 << 16;
            if (c.early_z_updates) bits |= 1 << 17;
        }
        b.w.u8_(@intFromEnum(Packet.cfg_bits));
        b.w.u8_(@truncate(bits));
        b.w.u8_(@truncate(bits >> 8));
        b.w.u8_(@truncate(bits >> 16));

        // Hardware workaround: emit POINT_SIZE between draws to flush
        // the binner FIFO (`v3dx_emit.c`).
        b.w.u8_(@intFromEnum(Packet.point_size));
        b.w.f32_(1.0);
    }

    /// Emits `CLIPPER_XY_SCALING`, `CLIPPER_Z_SCALE_AND_OFFSET`,
    /// `CLIPPER_Z_MIN_MAX_CLIPPING_PLANES`, and `VIEWPORT_OFFSET`.
    /// Note that `half_width_16ths` and `half_height_16ths` are in 1/16ths of
    /// a pixel (from `render.Viewport.scale()`), whereas `CLIPPER_XY_SCALING`
    /// takes 1/256ths of a pixel (`* 16.0`) on V3D 4.2 and 1/64ths (`* 4.0`) on V3D 7.1.
    pub fn viewport(b: *Bcl, center_x: f32, center_y: f32, half_width_16ths: f32, half_height_16ths: f32, v3d_ver: u8) void {
        const xy_mul: f32 = if (v3d_ver >= 71) 4.0 else 16.0;
        b.w.u8_(@intFromEnum(Packet.clipper_xy_scaling));
        b.w.f32_(half_width_16ths * xy_mul);
        b.w.f32_(half_height_16ths * xy_mul);

        b.w.u8_(@intFromEnum(Packet.clipper_z_scale_and_offset));
        b.w.f32_(0.5);
        b.w.f32_(0.5);

        b.w.u8_(@intFromEnum(Packet.clipper_z_min_max_clipping_planes));
        b.w.f32_(0.0);
        b.w.f32_(1.0);

        const vx = viewportCoord(center_x);
        const vy = viewportCoord(center_y);
        const word0: u32 = @as(u32, vx.fine) | (@as(u32, vx.coarse) << 22);
        const word1: u32 = @as(u32, vy.fine) | (@as(u32, vy.coarse) << 22);
        b.w.u8_(@intFromEnum(Packet.viewport_offset));
        b.w.u32_(word0);
        b.w.u32_(word1);
    }

    pub fn vcmCacheSize(b: *Bcl, bin_batches: u4, render_batches: u4) void {
        b.w.u8_(@intFromEnum(Packet.vcm_cache_size));
        b.w.u8_(@as(u8, bin_batches) | (@as(u8, render_batches) << 4));
    }

    /// `shader_rec_addr` must be 32-byte aligned.
    pub fn glShaderState(b: *Bcl, shader_rec_addr: u32, num_attributes: u5) void {
        std.debug.assert(shader_rec_addr & 0x1f == 0);
        b.w.u8_(@intFromEnum(Packet.gl_shader_state));
        b.w.u32_(shader_rec_addr | @as(u32, num_attributes));
    }

    pub fn indexBufferSetup(b: *Bcl, addr: u32, size: u32) void {
        b.w.u8_(@intFromEnum(Packet.index_buffer_setup));
        b.w.u32_(addr);
        b.w.u32_(size);
    }

    pub fn indexedPrimList(b: *Bcl, mode: cl.PrimitiveMode, index_16bit: bool, count: u32, index_offset: u32) void {
        b.w.u8_(@intFromEnum(Packet.indexed_prim_list));
        const index_type: u8 = if (index_16bit) 1 else 0;
        b.w.u8_(@intFromEnum(mode) | (index_type << 6));
        b.w.u32_(count & 0x7fffffff);
        b.w.u32_(index_offset);
    }

    pub fn vertexArrayPrims(b: *Bcl, mode: cl.PrimitiveMode, count: u32, first: u32) void {
        b.w.u8_(@intFromEnum(Packet.vertex_array_prims));
        b.w.u8_(@intFromEnum(mode));
        b.w.u32_(count);
        b.w.u32_(first);
    }

    pub fn finish(b: *Bcl) void {
        b.w.u8_(@intFromEnum(Packet.flush));
    }
};

/// Rendering Control List (RCL) writer for V3D 4.2 and V3D 7.1.
pub const Rcl = struct {
    w: cl.Writer,

    pub fn init(buf: []u8) Rcl {
        return .{ .w = .init(buf) };
    }

    pub fn bytes(r: *const Rcl) []const u8 {
        return r.w.bytes();
    }

    pub fn tileRenderingModeCfgCommon(
        r: *Rcl,
        width: u16,
        height: u16,
        msaa: bool,
        early_z: bool,
        early_zs_clear: bool,
        v3d_ver: u8,
    ) void {
        // Packet 121 sub-id 0: Tile Rendering Mode Cfg (Common) (8 bytes payload).
        const word0: u32 = 0 |
            (@as(u32, width) << 8) |
            (@as(u32, height & 0xff) << 24);
        var word1: u32 = @as(u32, height >> 8);
        if (msaa) word1 |= 1 << (42 - 32);
        if (!early_z) word1 |= 1 << (46 - 32);
        word1 |= @as(u32, @intFromEnum(InternalDepthType.depth_24)) << (47 - 32);
        if (early_zs_clear) word1 |= 1 << (51 - 32);
        if (v3d_ver >= 71) {
            word1 |= (@as(u32, 3) << (52 - 32)) | (@as(u32, if (msaa) 2 else 3) << (55 - 32));
        }

        r.w.u8_(@intFromEnum(Packet.tile_rendering_mode_cfg));
        r.w.u32_(word0);
        r.w.u32_(word1);
    }

    /// Converts 0xAARRGGBB to the 32-bit internal RGBA8 clear word expected by
    /// V3D 4.2/7.1 (`v3dx_rcl.c` / `u_pack_color`), where R is in bits 0..7, G in
    /// 8..15, B in 16..23, and A in 24..31.
    pub fn packClearColor(argb: u32) u32 {
        const a = (argb >> 24) & 0xff;
        const r_ch = (argb >> 16) & 0xff;
        const g_ch = (argb >> 8) & 0xff;
        const b_ch = argb & 0xff;
        return r_ch | (g_ch << 8) | (b_ch << 16) | (a << 24);
    }

    pub fn tileRenderingModeCfgClearColorsPart1(r: *Rcl, clear_rgba: u32) void {
        // Packet 121 sub-id 3: Clear Colors Part1 (8 bytes payload).
        r.w.u8_(@intFromEnum(Packet.tile_rendering_mode_cfg));
        r.w.u8_(3);
        r.w.u32_(clear_rgba);
        r.w.u16_(0);
        r.w.u8_(0);
    }

    pub fn tileRenderingModeCfgClearColorsPart3(r: *Rcl, uif_padded_height_in_ub: u13) void {
        // Packet 121 sub-id 5: Clear Colors Part3 (8 bytes payload).
        r.w.u8_(@intFromEnum(Packet.tile_rendering_mode_cfg));
        r.w.u32_(5);
        r.w.u32_(@as(u32, uif_padded_height_in_ub) << (40 - 32));
    }

    pub fn tileRenderingModeCfgColor(r: *Rcl) void {
        // Packet 121 sub-id 1: Tile Rendering Mode Cfg (Color) (8 bytes payload).
        const word0: u32 = 1 | (@as(u32, @intFromEnum(InternalType.type_8)) << 6);
        r.w.u8_(@intFromEnum(Packet.tile_rendering_mode_cfg));
        r.w.u32_(word0);
        r.w.u32_(0);
    }

    /// V3D 7.1 `Tile Rendering Mode Cfg (Render Target Part1)` (`sub-id = 2`),
    /// which replaces `Clear Colors Part1` and `Color` on V3D 7.1.
    pub fn tileRenderingModeCfgRenderTargetPart1(r: *Rcl, clear_rgba: u32) void {
        // bits 0..2: sub-id = 2
        // bits 3..5: render_target_number = 0
        // bits 7..17: base_address = 0
        // bits 18..24: stride - 1 = (64 / 2) - 1 = 31
        // bits 25..26: internal_bpp = 0 (32bpp)
        // bits 27..31: internal_type_and_clamping = 4 (V3D_RENDER_TARGET_TYPE_CLAMP_8)
        // bits 32..63: clear_color_low_bits
        const word0: u32 = 2 | (@as(u32, 31) << 18) | (@as(u32, 4) << 27);
        r.w.u8_(@intFromEnum(Packet.tile_rendering_mode_cfg));
        r.w.u32_(word0);
        r.w.u32_(clear_rgba);
    }

    pub fn tileRenderingModeCfgZsClearValues(r: *Rcl, clear_z: f32, clear_s: u8, v3d_ver: u8) void {
        // Packet 121: Tile Rendering Mode Cfg (ZS Clear Values).
        // sub-id = 2 on V3D 4.2, sub-id = 1 on V3D 7.1.
        r.w.u8_(@intFromEnum(Packet.tile_rendering_mode_cfg));
        r.w.u8_(if (v3d_ver >= 71) 1 else 2);
        r.w.u8_(clear_s);
        r.w.f32_(clear_z);
        r.w.u16_(0);
    }

    pub fn tileListInitialBlockSize(r: *Rcl) void {
        // Packet 126: use_auto_chained_tile_lists = 1 (bit 2), 64b = 0 (bits 0..1).
        r.w.u8_(@intFromEnum(Packet.tile_list_initial_block_size));
        r.w.u8_(1 << 2);
    }

    pub fn multicoreRenderingTileListSetBase(r: *Rcl, tile_alloc_addr: u32) void {
        std.debug.assert(tile_alloc_addr & 0x3f == 0);
        r.w.u8_(@intFromEnum(Packet.multicore_rendering_tile_list_set_base));
        r.w.u32_(tile_alloc_addr);
    }

    pub fn multicoreRenderingSupertileCfg(r: *Rcl, tiles_x: u12, tiles_y: u12) void {
        const word0: u32 = (@as(u32, tiles_x) << 16) | (@as(u32, tiles_y) << 24);
        const word1: u32 = @as(u32, tiles_x) | (@as(u32, tiles_y) << 12);
        r.w.u8_(@intFromEnum(Packet.multicore_rendering_supertile_cfg));
        r.w.u32_(word0);
        r.w.u32_(word1);
    }

    pub fn tileCoordinates(r: *Rcl, col: u12, row: u12) void {
        const v: u32 = @as(u32, col) | (@as(u32, row) << 12);
        r.w.u8_(@intFromEnum(Packet.tile_coordinates));
        r.w.u8_(@truncate(v));
        r.w.u8_(@truncate(v >> 8));
        r.w.u8_(@truncate(v >> 16));
    }

    pub fn tileCoordinatesImplicit(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.tile_coordinates_implicit));
    }

    pub fn endOfLoads(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.end_of_loads));
    }

    pub fn endOfTileMarker(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.end_of_tile_marker));
    }

    pub fn flushVcdCache(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.flush_vcd_cache));
    }

    pub fn clearTileBuffers(r: *Rcl, clear_color: bool, clear_zs: bool, v3d_ver: u8) void {
        r.w.u8_(@intFromEnum(Packet.clear_tile_buffers));
        if (v3d_ver < 71) {
            var bits: u8 = 0;
            if (clear_color) bits |= 1 << 0;
            if (clear_zs) bits |= 1 << 1;
            r.w.u8_(bits);
        }
    }

    pub fn storeTileBufferGeneralNone(r: *Rcl) void {
        // Packet 29: Store Tile Buffer General (12 bytes payload), buffer = NONE (8).
        r.w.u8_(@intFromEnum(Packet.store_tile_buffer_general));
        r.w.u32_(@intFromEnum(Buffer.none));
        r.w.u32_(0);
        r.w.u32_(0);
    }

    pub fn storeTileBufferGeneralColor(
        r: *Rcl,
        addr: u32,
        format: Format,
        tiling: cl.Tiling,
        width: u16,
        height: u16,
        msaa: bool,
    ) void {
        const out = outputFormat(format);
        const layout = targetLayout(format, tiling, width, height);
        const decimate: DecimateMode = if (msaa) .mode_4x else .sample_0;
        const stride_val: u32 = layout.height_in_ub_or_stride;
        var word0: u32 = @intFromEnum(Buffer.render_target_0) |
            (@as(u32, @intFromEnum(layout.mem_format)) << 4) |
            (@as(u32, @intFromEnum(decimate)) << 10) |
            (@as(u32, @intFromEnum(out.fmt)) << 12) |
            ((stride_val & 0xf) << 28);
        if (out.rb_swap) word0 |= 1 << 20;
        const word1: u32 = (stride_val >> 4) | (@as(u32, height) << 16);
        r.w.u8_(@intFromEnum(Packet.store_tile_buffer_general));
        r.w.u32_(word0);
        r.w.u32_(word1);
        r.w.u32_(addr);
    }

    pub fn loadTileBufferGeneralColor(
        r: *Rcl,
        addr: u32,
        format: Format,
        tiling: cl.Tiling,
        width: u16,
        height: u16,
    ) void {
        const out = outputFormat(format);
        const layout = targetLayout(format, tiling, width, height);
        const stride_val: u32 = layout.height_in_ub_or_stride;
        var word0: u32 = @intFromEnum(Buffer.render_target_0) |
            (@as(u32, @intFromEnum(layout.mem_format)) << 4) |
            (@as(u32, @intFromEnum(DecimateMode.sample_0)) << 10) |
            (@as(u32, @intFromEnum(out.fmt)) << 12) |
            ((stride_val & 0xf) << 28);
        if (format == .xrgb8888 or format == .rgb565) word0 |= 1 << 18; // force_alpha_1
        if (out.rb_swap) word0 |= 1 << 20;
        const word1: u32 = (stride_val >> 4) | (@as(u32, height) << 16);
        r.w.u8_(@intFromEnum(Packet.load_tile_buffer_general));
        r.w.u32_(word0);
        r.w.u32_(word1);
        r.w.u32_(addr);
    }

    pub fn primListFormatTriangles(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.prim_list_format));
        r.w.u8_(2); // LIST_TRIANGLES
    }

    pub fn setInstanceId(r: *Rcl, id: u32) void {
        r.w.u8_(@intFromEnum(Packet.set_instanceid));
        r.w.u32_(id);
    }

    pub fn branchToImplicitTileList(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.branch_to_implicit_tile_list));
        r.w.u8_(0);
    }

    pub fn returnFromSubList(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.return_from_sub_list));
    }

    pub fn startAddressOfGenericTileList(r: *Rcl, start_addr: u32, end_addr: u32) void {
        r.w.u8_(@intFromEnum(Packet.start_address_of_generic_tile_list));
        r.w.u32_(start_addr);
        r.w.u32_(end_addr);
    }

    pub fn supertileCoordinates(r: *Rcl, col: u8, row: u8) void {
        r.w.u8_(@intFromEnum(Packet.supertile_coordinates));
        r.w.u8_(col);
        r.w.u8_(row);
    }

    pub fn endOfRendering(r: *Rcl) void {
        r.w.u8_(@intFromEnum(Packet.end_of_rendering));
    }
};

pub const AttributeRecord = struct {
    addr: u32,
    /// Number of float components (1..4).
    components: u3,
    stride: u32,
    read_by_cs: bool,
    read_by_vs: bool = true,
};

pub const ShaderRecord = struct {
    fs_code_addr: u32,
    fs_uniforms_addr: u32,
    vs_code_addr: u32,
    vs_uniforms_addr: u32,
    cs_code_addr: u32,
    cs_uniforms_addr: u32,
    default_attr_addr: u32,
    fs_num_varyings: u8,
    attributes: []const AttributeRecord,
};

/// Writes a 36-byte V3D 4.2 `GL Shader State Record` followed by `N` 16-byte
/// `GL Shader State Attribute Record`s into `w` (`v3d_packet.xml` ver = 42).
pub fn writeShaderStateRecord(w: *cl.Writer, rec: ShaderRecord) void {
    const flags: u32 = (1 << 1) | (1 << 18);
    w.u8_(@truncate(flags));
    w.u8_(@truncate(flags >> 8));
    w.u8_(@truncate(flags >> 16));
    w.u8_(rec.fs_num_varyings);

    w.u8_(1 | (1 << 4));
    w.u8_(1);
    w.u8_(1 | (1 << 4));
    w.u8_(1);

    w.u32_(rec.default_attr_addr);

    const shader_mode_bits: u32 = (1 << 0) | (1 << 1) | (1 << 2);
    w.u32_((rec.fs_code_addr & ~@as(u32, 7)) | shader_mode_bits);
    w.u32_(rec.fs_uniforms_addr);

    w.u32_((rec.vs_code_addr & ~@as(u32, 7)) | shader_mode_bits);
    w.u32_(rec.vs_uniforms_addr);

    w.u32_((rec.cs_code_addr & ~@as(u32, 7)) | shader_mode_bits);
    w.u32_(rec.cs_uniforms_addr);

    writeAttributeRecords(w, rec.attributes);
}

/// Writes a 32-byte V3D 7.1 `GL Shader State Record` followed by `N` 16-byte
/// `GL Shader State Attribute Record`s into `w` (`v3d_packet.xml` ver = 71).
/// On BCM2712 D0 (`has_draw_index = true`), `enable_clipping` and subsequent
/// flags in bytes 0..2 are shifted left by 2 bits.
pub fn writeShaderStateRecord71(w: *cl.Writer, rec: ShaderRecord, has_draw_index: bool) void {
    const flags: u32 = if (has_draw_index)
        (1 << 3) | (1 << 20)
    else
        (1 << 1) | (1 << 18);
    w.u8_(@truncate(flags));
    w.u8_(@truncate(flags >> 8));
    w.u8_(@truncate(flags >> 16));
    w.u8_(rec.fs_num_varyings);

    w.u8_(1 | (1 << 4));
    w.u8_(0); // cs_input_vpm_segment_size = 0 on V3D 7.1
    w.u8_(1 | (1 << 4));
    w.u8_(0); // vs_input_vpm_segment_size = 0 on V3D 7.1

    // Note: V3D 7.1 omits the 4-byte `address_of_default_attribute_values` field
    // and only uses bits 0..1 (`0x3`) for shader mode bits.
    const shader_mode_bits: u32 = (1 << 0) | (1 << 1);
    w.u32_((rec.fs_code_addr & ~@as(u32, 7)) | shader_mode_bits);
    w.u32_(rec.fs_uniforms_addr);

    w.u32_((rec.vs_code_addr & ~@as(u32, 7)) | shader_mode_bits);
    w.u32_(rec.vs_uniforms_addr);

    w.u32_((rec.cs_code_addr & ~@as(u32, 7)) | shader_mode_bits);
    w.u32_(rec.cs_uniforms_addr);

    writeAttributeRecords(w, rec.attributes);
}

fn writeAttributeRecords(w: *cl.Writer, attributes: []const AttributeRecord) void {
    var any_cs = false;
    for (attributes) |a| {
        if (a.read_by_cs) any_cs = true;
    }
    for (attributes, 0..) |a, i| {
        w.u32_(a.addr);
        const vec_size: u8 = @intCast(a.components & 3);
        const attr_type: u8 = 2; // ATTRIBUTE_FLOAT
        w.u8_(vec_size | (attr_type << 2));
        const force_cs = !any_cs and (i == attributes.len - 1);
        const cs_vals: u8 = if (a.read_by_cs or force_cs) a.components else 0;
        const vs_vals: u8 = if (a.read_by_vs) a.components else 0;
        w.u8_(cs_vals | (vs_vals << 4));
        w.u16_(0);
        w.u32_(a.stride);
        w.u32_(0xffffff);
    }
}

/// Writes a 24-byte (6-word, 32-byte aligned) V3D 4.2 `Texture Shader State`
/// struct (`v3d_packet.xml` ver = 42).
pub fn packTextureShaderState(tex_base_addr: u32, cfg: texture.Config) [6]u32 {
    const addr = tex_base_addr + cfg.offset;
    std.debug.assert(addr & 0x3f == 0);
    // Texture Data Formats (`v3d_packet.xml` lines 341-347):
    // R8 = 0, RGBA8 = 4, RGB565 = 6.
    const tex_type: u32 = switch (cfg.type) {
        .rgba8888, .rgbx8888 => 4,
        .rgb565 => 6,
        .alpha, .luminance => 0,
        else => unreachable,
    };
    const fmt: Format = switch (cfg.type) {
        .rgba8888, .rgbx8888 => .argb8888,
        .rgb565 => .rgb565,
        .alpha, .luminance => .a8,
        else => unreachable,
    };
    // Swizzle values (`v3d_packet.xml` lines 1611-1616):
    // 0 = Zero, 1 = One, 2 = Red (ch0), 3 = Green (ch1), 4 = Blue (ch2), 5 = Alpha (ch3).
    // Note: `compileV3d` assigns the 4 `ldtmu` words to `(ch[2], ch[1], ch[0], ch[3])`:
    //   word 0 (R output) -> ch[2]
    //   word 1 (G output) -> ch[1]
    //   word 2 (B output) -> ch[0]
    //   word 3 (A output) -> ch[3]
    const swiz: struct { r: u32, g: u32, b: u32, a: u32 } = switch (cfg.type) {
        // Memory is 0xAARRGGBB (little-endian [B, G, R, A]); RGBA8 reads byte 0 as Red(2),
        // byte 1 as Green(3), byte 2 as Blue(4), byte 3 as Alpha(5).
        // We want `ch[0]` (word 2 / B output) = byte 0 (Red=2),
        //         `ch[1]` (word 1 / G output) = byte 1 (Green=3),
        //         `ch[2]` (word 0 / R output) = byte 2 (Blue=4),
        //         `ch[3]` (word 3 / A output) = byte 3 (Alpha=5).
        .rgba8888, .rgbx8888 => .{ .r = 4, .g = 3, .b = 2, .a = 5 },
        // Format.rgb565 (DRM_FORMAT_BGR565) has R in bits 0..4 (which V3D's
        // RGB565 texture format reads as Blue(4)), G in bits 5..10 (Green(3)),
        // and B in bits 11..15 (Red(2)): `ch[0]` (B output) = Red(2), `ch[1]` = Green(3),
        // `ch[2]` (R output) = Blue(4), `ch[3]` = One(1).
        .rgb565 => .{ .r = 4, .g = 3, .b = 2, .a = 1 },
        // Alpha textures (`.alpha`, R8) are read by shaders via `unpack_unorm8(3)`
        // (`ch[3]` = word 3 = A output).
        .alpha, .luminance => .{ .r = 0, .g = 0, .b = 0, .a = 2 },
        else => unreachable,
    };

    const slice = texture.uifSlice(fmt, cfg.width, cfg.height);
    const ub_pad: u32 = slice.ub_pad;
    const xor_enable: u32 = @intFromBool(slice.tiling == .uif_xor);
    const strictly_uif: u32 = @intFromBool(slice.tiling == .uif_xor or slice.tiling == .uif_no_xor);

    const w: u32 = cfg.width;
    const h: u32 = cfg.height;
    const d: u32 = 1;
    const max_level: u32 = cfg.mip_levels;

    // Bit layout (`v3d_packet.xml` lines 1600-1639):
    // bits 0..31 (word 0): texture_base_pointer (bits 6..31) | flags (bits 0..5 = 0)
    // bits 32..57 (word 1 bits 0..25): array_stride = 0
    // bits 58..71 (word 1 bits 26..31, word 2 bits 0..7): image_width (14 bits)
    // bits 72..85 (word 2 bits 8..21): image_height (14 bits)
    // bits 86..99 (word 2 bits 22..31, word 3 bits 0..3): image_depth (14 bits)
    // bits 100..106 (word 3 bits 4..10): texture_type (7 bits)
    // bit 107 (word 3 bit 11): extended = 0
    // bits 108..110 (word 3 bits 12..14): swizzle_r
    // bits 111..113 (word 3 bits 15..17): swizzle_g
    // bits 114..116 (word 3 bits 18..20): swizzle_b
    // bits 117..119 (word 3 bits 21..23): swizzle_a
    // bits 120..123 (word 3 bits 24..27): max_level
    // bits 124..127 (word 3 bits 28..31): base_level = 0
    // bits 128..131 (word 4 bits 0..3): level_0_ub_pad (4 bits)
    // bit 132 (word 4 bit 4): level_0_xor_enable
    // bit 134 (word 4 bit 6): level_0_is_strictly_uif
    // bit 135 (word 4 bit 7): uif_xor_disable = 0
    const word0 = addr;
    const word1 = (w & 0x3f) << 26;
    const word2 = ((w >> 6) & 0xff) | ((h & 0x3fff) << 8) | ((d & 0x3ff) << 22);
    const word3 = ((d >> 10) & 0xf) |
        ((tex_type & 0x7f) << 4) |
        (swiz.r << 12) |
        (swiz.g << 15) |
        (swiz.b << 18) |
        (swiz.a << 21) |
        ((max_level & 0xf) << 24);
    const word4 = (ub_pad & 0xf) | (xor_enable << 4) | (strictly_uif << 6);
    return .{ word0, word1, word2, word3, word4, 0 };
}

/// Writes a 24-byte (6-word, 8-byte aligned) V3D 4.2 `Sampler State` struct
/// (`v3d_packet.xml` lines 1717-1742).
pub fn packSamplerState(cfg: texture.Config) [6]u32 {
    // Wrap Mode (`v3d_packet.xml` lines 87-93):
    // REPEAT = 0, CLAMP = 1, MIRROR = 2, BORDER = 3.
    const wrap_s: u32 = switch (cfg.wrap_s) {
        .repeat => 0,
        .clamp => 1,
        .mirror => 2,
        .border => 3,
    };
    const wrap_t: u32 = switch (cfg.wrap_t) {
        .repeat => 0,
        .clamp => 1,
        .mirror => 2,
        .border => 3,
    };
    const mag_nearest: u32 = @intFromBool(cfg.mag_filter == .nearest);
    const min_nearest: u32 = @intFromBool(cfg.min_filter == .nearest);
    const mip_nearest: u32 = @intFromBool(cfg.mip_filter != .linear);
    const max_lod_fixed: u32 = if (cfg.mip_filter != .none) @as(u32, cfg.mip_levels) << 8 else 0;

    // word 0:
    // bit 0: mag_filter_nearest
    // bit 1: min_filter_nearest
    // bit 2: mip_filter_nearest
    // bit 7: srgb_disable = 0
    // bits 8..19: min_lod = 0
    // bits 20..31: max_lod (u4.8 fixed point)
    const word0: u32 = mag_nearest | (min_nearest << 1) | (mip_nearest << 2) | ((max_lod_fixed & 0xfff) << 20);
    // word 1:
    // bits 0..15: fixed_bias = 0
    // bits 16..18 (bits 48..50): wrap_s
    // bits 19..21 (bits 51..53): wrap_t
    // bits 22..24 (bits 54..56): wrap_r = 1 (clamp)
    const word1: u32 = (wrap_s << 16) | (wrap_t << 19) | (1 << 22);
    return .{ word0, word1, 0, 0, 0, 0 };
}

/// Encodes V3D 4.2 `TMU Config Parameter 0` (32-byte aligned texture state
/// address | 4-bit `return_words_of_texture_data` mask = `0xf`).
pub fn tmuConfigP0(tex_state_addr: u32) u32 {
    std.debug.assert(tex_state_addr & 0x1f == 0);
    return tex_state_addr | 0xf;
}

/// Encodes V3D 4.2 `TMU Config Parameter 1` (8-byte aligned sampler state
/// address | `output_type_32_bit = 1`).
pub fn tmuConfigP1(sampler_state_addr: u32) u32 {
    std.debug.assert(sampler_state_addr & 0x7 == 0);
    return sampler_state_addr | 1;
}

const testing = std.testing;

test "V3D 4.2 and V3D 7.1 BCL and RCL packet encoding" {
    var bcl_buf: [256]u8 = undefined;
    var bcl = Bcl.init(&bcl_buf);
    bcl.startBinning(640, 480, false, 42);
    bcl.finish();
    const b = bcl.bytes();
    try testing.expectEqual(@intFromEnum(Packet.number_of_layers), b[0]);
    try testing.expectEqual(@as(u8, 0), b[1]);
    try testing.expectEqual(@intFromEnum(Packet.tile_binning_mode_cfg), b[2]);
    try testing.expectEqual(@intFromEnum(Packet.flush), b[b.len - 1]);

    var rcl_buf: [256]u8 = undefined;
    var rcl = Rcl.init(&rcl_buf);
    rcl.tileRenderingModeCfgCommon(640, 480, false, false, true, 42);
    rcl.tileRenderingModeCfgClearColorsPart1(Rcl.packClearColor(0xff112233));
    rcl.tileRenderingModeCfgColor();
    rcl.tileRenderingModeCfgZsClearValues(1.0, 0, 42);
    rcl.endOfRendering();
    try testing.expectEqual(@as(u32, 0xff332211), Rcl.packClearColor(0xff112233));
    try testing.expectEqual(@intFromEnum(Packet.end_of_rendering), rcl.bytes()[rcl.bytes().len - 1]);

    // V3D 7.1 RCL
    var rcl71 = Rcl.init(&rcl_buf);
    rcl71.tileRenderingModeCfgCommon(640, 480, false, false, true, 71);
    rcl71.tileRenderingModeCfgRenderTargetPart1(Rcl.packClearColor(0xff112233));
    rcl71.tileRenderingModeCfgZsClearValues(1.0, 0, 71);
    rcl71.clearTileBuffers(true, true, 71);
    rcl71.endOfRendering();
    try testing.expectEqual(@intFromEnum(Packet.end_of_rendering), rcl71.bytes()[rcl71.bytes().len - 1]);
}

test "V3D 4.2 texture and sampler state packing" {
    const tex = packTextureShaderState(0x1000, .{ .width = 256, .height = 128, .type = .rgba8888 });
    try testing.expectEqual(@as(u32, 0x1000), tex[0]);
    const samp = packSamplerState(.{ .width = 256, .height = 128, .mag_filter = .nearest, .min_filter = .nearest });
    try testing.expectEqual(@as(u32, 0x7), samp[0] & 0x7);
    try testing.expectEqual(@as(u32, 0x100f), tmuConfigP0(0x1000));
    try testing.expectEqual(@as(u32, 0x2001), tmuConfigP1(0x2000));
}

