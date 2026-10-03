//! Builds DRM_IOCTL_VC4_SUBMIT_CL jobs for one draw call.
//!
//! A job references buffers by their index in a caller-supplied list of GEM
//! handles (`bo_handles`), which is how the kernel relocates addresses.

const std = @import("std");
const cl = @import("cl.zig");
const compiler = @import("compiler.zig");
const texture = @import("texture.zig");
const vc4 = @import("device.zig");

pub const ShaderBinding = struct {
    /// Index of the shader BO in `bo_handles`.
    bo_index: u32,
    /// What each uniform stream word holds (from the compiler).
    layout: []const compiler.UniformKind,
    /// Values for `.user` entries, by index.
    user: []const u32 = &.{},
};

pub const Texture = struct {
    bo_index: u32,
    config: texture.Config,
};

pub const Draw = struct {
    fs: ShaderBinding,
    vs: ShaderBinding,
    cs: ShaderBinding,
    fs_num_varyings: u8,
    attributes: []const cl.Attribute,
    vs_attribute_mask: u8,
    vs_attributes_size: u8,
    cs_attribute_mask: u8,
    cs_attributes_size: u8,
    vertex_count: u32,
    config: cl.Bcl.Config = .{},
    /// Texture for unit 0 of the fragment shader.
    texture: ?Texture = null,
};

/// A linear B8G8R8A8 colour buffer. Depth lives only in the tile buffer:
/// it is cleared to `clear_z` before each tile and never stored.
pub const Target = struct {
    bo_index: u32,
    width: u16,
    height: u16,
    clear_color: u32,
    clear_z: u32 = 0xffffff,

    /// Byte stride the hardware uses for linear render targets: the width
    /// rounded up to a 4-pixel micro-tile.
    pub fn pitch(width: u16) u32 {
        return std.mem.alignForward(u32, width, 4) * 4;
    }
};

pub const max_bos = 16;

/// Everything passed to the submit ioctl. `submit` points into the other
/// fields, so a Job must not be moved after `build`.
pub const Job = struct {
    bcl_buf: [128]u8,
    bcl_len: usize,
    rec_buf: [160]u8,
    rec_len: usize,
    uniforms: [192]u32,
    uniforms_len: usize,
    bo_handles: [max_bos]u32,
    submit: vc4.SubmitCl,

    pub fn bcl(job: *const Job) []const u8 {
        return job.bcl_buf[0..job.bcl_len];
    }

    pub fn shaderRecords(job: *const Job) []const u8 {
        return job.rec_buf[0..job.rec_len];
    }

    pub fn uniformWords(job: *const Job) []const u32 {
        return job.uniforms[0..job.uniforms_len];
    }

    pub fn build(job: *Job, handles: []const u32, target: Target, draw: Draw) void {
        std.debug.assert(handles.len <= max_bos);
        const width: f32 = @floatFromInt(target.width);
        const height: f32 = @floatFromInt(target.height);
        const tiles_x = std.math.divCeil(u16, target.width, cl.tile_size) catch unreachable;
        const tiles_y = std.math.divCeil(u16, target.height, cl.tile_size) catch unreachable;

        var b: cl.Bcl = .init(&job.bcl_buf);
        b.tileBinningModeConfig(@intCast(tiles_x), @intCast(tiles_y));
        b.startTileBinning();
        b.primitiveListFormat();
        b.clipWindow(0, 0, target.width, target.height);
        b.configurationBits(draw.config);
        b.viewportOffset(width / 2.0, height / 2.0);
        // Clip space [-1, 1] maps to [-w/2, w/2] around the centre, with Y
        // negated because the first row of the framebuffer is the top.
        b.clipperXyScaling(width / 2.0 * 16.0, -height / 2.0 * 16.0);
        b.clipperZScaling(0.5, 0.5);
        b.glShaderState(@intCast(draw.attributes.len));
        b.glArrayPrimitive(.triangles, draw.vertex_count, 0);
        b.finish();
        job.bcl_len = b.bytes().len;

        var rec: cl.Writer = .init(&job.rec_buf);
        cl.writeShaderRecord(&rec, .{
            .flags = cl.shader_flag_fs_single_thread | cl.shader_flag_enable_clipping,
            .fs_num_varyings = draw.fs_num_varyings,
            .fs_bo_index = draw.fs.bo_index,
            .vs_bo_index = draw.vs.bo_index,
            .cs_bo_index = draw.cs.bo_index,
            .vs_attribute_mask = draw.vs_attribute_mask,
            .vs_attributes_size = draw.vs_attributes_size,
            .cs_attribute_mask = draw.cs_attribute_mask,
            .cs_attributes_size = draw.cs_attributes_size,
            .attributes = draw.attributes,
        });
        job.rec_len = rec.len;

        // Uniform streams in shader record order: FS, VS, CS. Each starts
        // with the bo_handles index of every texture it samples, which the
        // kernel uses to relocate P0, followed by the uniform words.
        job.uniforms_len = 0;
        for ([_]ShaderBinding{ draw.fs, draw.vs, draw.cs }) |s| {
            for (s.layout) |k| if (k == .tex_p0) job.pushUniform(draw.texture.?.bo_index);
            for (s.layout) |k| job.pushUniform(switch (k) {
                .user => |i| s.user[i],
                .tex_p0 => texture.p0(draw.texture.?.config),
                .tex_p1 => texture.p1(draw.texture.?.config),
            });
        }

        @memcpy(job.bo_handles[0..handles.len], handles);

        job.submit = .{
            .bin_cl = @intFromPtr(&job.bcl_buf),
            .bin_cl_size = @intCast(job.bcl_len),
            .shader_rec = @intFromPtr(&job.rec_buf),
            .shader_rec_size = @intCast(job.rec_len),
            .shader_rec_count = 1,
            .uniforms = @intFromPtr(&job.uniforms),
            .uniforms_size = @intCast(job.uniforms_len * 4),
            .bo_handles = @intFromPtr(&job.bo_handles),
            .bo_handle_count = @intCast(handles.len),
            .width = target.width,
            .height = target.height,
            .min_x_tile = 0,
            .min_y_tile = 0,
            .max_x_tile = @intCast(tiles_x - 1),
            .max_y_tile = @intCast(tiles_y - 1),
            .color_write = .{
                .hindex = target.bo_index,
                .bits = cl.renderConfigBits(.linear, cl.render_config_format_rgba8888),
            },
            .clear_color = .{ target.clear_color, target.clear_color },
            .clear_z = target.clear_z,
            .flags = vc4.SubmitCl.flag_use_clear_color,
        };
    }

    fn pushUniform(job: *Job, v: u32) void {
        job.uniforms[job.uniforms_len] = v;
        job.uniforms_len += 1;
    }
};

test "uniform streams start with texture handle indices" {
    const fs_layout = [_]compiler.UniformKind{ .{ .tex_p0 = 0 }, .{ .tex_p1 = 0 } };
    const vs_layout = [_]compiler.UniformKind{ .{ .user = 1 }, .{ .user = 0 } };
    const attrs = [_]cl.Attribute{.{ .bo_index = 4, .offset = 0, .size = 8, .stride = 8, .vs_vpm_offset = 0, .cs_vpm_offset = 0 }};
    const cfg: texture.Config = .{ .width = 64, .height = 64 };
    var job: Job = undefined;
    job.build(&.{ 10, 11, 12, 13, 14, 15 }, .{ .bo_index = 0, .width = 640, .height = 480, .clear_color = 0 }, .{
        .fs = .{ .bo_index = 1, .layout = &fs_layout },
        .vs = .{ .bo_index = 2, .layout = &vs_layout, .user = &.{ 100, 200 } },
        .cs = .{ .bo_index = 3, .layout = &vs_layout, .user = &.{ 100, 200 } },
        .fs_num_varyings = 0,
        .attributes = &attrs,
        .vs_attribute_mask = 1,
        .vs_attributes_size = 8,
        .cs_attribute_mask = 1,
        .cs_attributes_size = 8,
        .vertex_count = 3,
        .texture = .{ .bo_index = 5, .config = cfg },
    });
    try std.testing.expectEqualSlices(u32, &.{ 5, texture.p0(cfg), texture.p1(cfg), 200, 100, 200, 100 }, job.uniformWords());
    try std.testing.expectEqual(@as(u32, 6), job.submit.bo_handle_count);
}
