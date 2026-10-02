//! Draws a single colour-interpolated triangle with the V3D.

const std = @import("std");
const cl = @import("vc4/cl.zig");
const drm = @import("drm.zig");
const shaders = @import("shaders.zig");
const vc4 = @import("vc4.zig");

/// A linear B8G8R8A8 colour buffer to render into.
pub const Target = struct {
    bo: vc4.Bo,
    width: u16,
    height: u16,

    /// Byte stride the hardware uses for linear (raster) render targets:
    /// the width rounded up to a 4-pixel micro-tile.
    pub fn pitch(width: u16) u32 {
        return std.mem.alignForward(u32, width, 4) * 4;
    }
};

const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};

const vertices = [_]Vertex{
    .{ .x = 0.0, .y = 0.8, .r = 1.0, .g = 0.0, .b = 0.0 },
    .{ .x = -0.8, .y = -0.8, .r = 0.0, .g = 1.0, .b = 0.0 },
    .{ .x = 0.8, .y = -0.8, .r = 0.0, .g = 0.0, .b = 1.0 },
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == shaders.attributes.stride);
}

/// Indices into the submit's `bo_handles` array.
const bo_index = struct {
    const target = 0;
    const fs = 1;
    const vs = 2;
    const cs = 3;
    const vertices = 4;
};

pub const Triangle = struct {
    fs: u32,
    vs: u32,
    cs: u32,
    vbo: vc4.Bo,

    /// Generates the shaders, uploads them (the kernel validates them at
    /// this point) and fills a vertex buffer.
    pub fn init(dev: vc4.Device) !Triangle {
        const fs_code = try shaders.fragment();
        const vs_code = try shaders.vertex();
        const cs_code = try shaders.coordinate();

        const fs = dev.createShaderBo(fs_code.code()) catch |err| return reject("fragment", err);
        errdefer drm.gemClose(dev.fd, fs);
        const vs = dev.createShaderBo(vs_code.code()) catch |err| return reject("vertex", err);
        errdefer drm.gemClose(dev.fd, vs);
        const cs = dev.createShaderBo(cs_code.code()) catch |err| return reject("coordinate", err);
        errdefer drm.gemClose(dev.fd, cs);

        const vbo = try dev.createBo(4096);
        @memcpy(vbo.map[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));

        return .{ .fs = fs, .vs = vs, .cs = cs, .vbo = vbo };
    }

    fn reject(stage: []const u8, err: anyerror) anyerror {
        @import("sys.zig").print("stardust: kernel rejected the {s} shader ({s})\n", .{ stage, @errorName(err) });
        return err;
    }

    pub fn deinit(t: Triangle, dev: vc4.Device) void {
        dev.destroyBo(t.vbo);
        drm.gemClose(dev.fd, t.fs);
        drm.gemClose(dev.fd, t.vs);
        drm.gemClose(dev.fd, t.cs);
    }

    /// Clears `target` to `clear_color` (0xAARRGGBB), draws the triangle
    /// over it and waits for the GPU to finish.
    pub fn draw(t: Triangle, dev: vc4.Device, target: Target, clear_color: u32) !void {
        var job: Job = undefined;
        job.build(.{ .target = target.bo.handle, .fs = t.fs, .vs = t.vs, .cs = t.cs, .vertices = t.vbo.handle }, target.width, target.height, clear_color);
        const seqno = try dev.submit(&job.submit);
        try dev.waitSeqno(seqno, std.time.ns_per_s);
    }
};

/// GEM handles of the buffers a job references.
pub const Handles = struct {
    target: u32,
    fs: u32,
    vs: u32,
    cs: u32,
    vertices: u32,
};

/// Everything passed to DRM_IOCTL_VC4_SUBMIT_CL for one frame. `submit`
/// points into the other fields, so a Job must not be moved after `build`.
pub const Job = struct {
    bcl_buf: [128]u8,
    bcl_len: usize,
    rec_buf: [128]u8,
    rec_len: usize,
    uniforms: [2]shaders.VertexUniforms,
    bo_handles: [5]u32,
    submit: vc4.SubmitCl,

    pub fn bcl(job: *const Job) []const u8 {
        return job.bcl_buf[0..job.bcl_len];
    }

    pub fn shaderRecords(job: *const Job) []const u8 {
        return job.rec_buf[0..job.rec_len];
    }

    pub fn build(job: *Job, handles: Handles, target_width: u16, target_height: u16, clear_color: u32) void {
        const width: f32 = @floatFromInt(target_width);
        const height: f32 = @floatFromInt(target_height);
        const tiles_x = std.math.divCeil(u16, target_width, cl.tile_size) catch unreachable;
        const tiles_y = std.math.divCeil(u16, target_height, cl.tile_size) catch unreachable;

        // Clip-space [-1, 1] maps to [-w/2, w/2] around the viewport centre.
        // Y is negated because the framebuffer's first row is the top.
        const x_scale = width / 2.0 * 16.0;
        const y_scale = -height / 2.0 * 16.0;

        var b: cl.Bcl = .init(&job.bcl_buf);
        b.tileBinningModeConfig(@intCast(tiles_x), @intCast(tiles_y));
        b.startTileBinning();
        b.primitiveListFormat();
        b.clipWindow(0, 0, target_width, target_height);
        b.configurationBits(.{});
        b.viewportOffset(width / 2.0, height / 2.0);
        b.clipperXyScaling(x_scale, y_scale);
        b.clipperZScaling(0.5, 0.5);
        b.glShaderState(2);
        b.glArrayPrimitive(.triangles, vertices.len, 0);
        b.finish();
        job.bcl_len = b.bytes().len;

        const attrs = shaders.attributes;
        const attributes = [_]cl.Attribute{
            .{
                .bo_index = bo_index.vertices,
                .offset = attrs.position_offset,
                .size = attrs.position_size,
                .stride = attrs.stride,
                .vs_vpm_offset = 0,
                .cs_vpm_offset = 0,
            },
            .{
                .bo_index = bo_index.vertices,
                .offset = attrs.color_offset,
                .size = attrs.color_size,
                .stride = attrs.stride,
                .vs_vpm_offset = attrs.position_size,
                .cs_vpm_offset = 0, // not loaded by the CS
            },
        };
        var rec: cl.Writer = .init(&job.rec_buf);
        cl.writeShaderRecord(&rec, .{
            .flags = cl.shader_flag_fs_single_thread | cl.shader_flag_enable_clipping,
            .fs_num_varyings = shaders.num_varyings,
            .fs_bo_index = bo_index.fs,
            .vs_bo_index = bo_index.vs,
            .cs_bo_index = bo_index.cs,
            .vs_attribute_mask = 0b11,
            .vs_attributes_size = attrs.position_size + attrs.color_size,
            .cs_attribute_mask = 0b01,
            .cs_attributes_size = attrs.position_size,
            .attributes = &attributes,
        });
        job.rec_len = rec.len;

        // Uniform streams in shader record order: FS (none), VS, CS.
        const vertex_uniforms: shaders.VertexUniforms = .{ .x_scale = x_scale, .y_scale = y_scale };
        job.uniforms = .{ vertex_uniforms, vertex_uniforms };

        job.bo_handles = undefined;
        job.bo_handles[bo_index.target] = handles.target;
        job.bo_handles[bo_index.fs] = handles.fs;
        job.bo_handles[bo_index.vs] = handles.vs;
        job.bo_handles[bo_index.cs] = handles.cs;
        job.bo_handles[bo_index.vertices] = handles.vertices;

        job.submit = .{
            .bin_cl = @intFromPtr(&job.bcl_buf),
            .bin_cl_size = @intCast(job.bcl_len),
            .shader_rec = @intFromPtr(&job.rec_buf),
            .shader_rec_size = @intCast(job.rec_len),
            .shader_rec_count = 1,
            .uniforms = @intFromPtr(&job.uniforms),
            .uniforms_size = @sizeOf(@TypeOf(job.uniforms)),
            .bo_handles = @intFromPtr(&job.bo_handles),
            .bo_handle_count = job.bo_handles.len,
            .width = target_width,
            .height = target_height,
            .min_x_tile = 0,
            .min_y_tile = 0,
            .max_x_tile = @intCast(tiles_x - 1),
            .max_y_tile = @intCast(tiles_y - 1),
            .color_write = .{
                .hindex = bo_index.target,
                .bits = cl.renderConfigBits(.linear, cl.render_config_format_rgba8888),
            },
            .clear_color = .{ clear_color, clear_color },
            .flags = vc4.SubmitCl.flag_use_clear_color,
        };
    }
};

test "1080p job layout" {
    var job: Job = undefined;
    job.build(.{ .target = 10, .fs = 11, .vs = 12, .cs = 13, .vertices = 14 }, 1920, 1080, 0xff000000);
    try std.testing.expectEqual(@as(u8, 29), job.submit.max_x_tile); // 30 tiles
    try std.testing.expectEqual(@as(u8, 16), job.submit.max_y_tile); // 17 tiles
    // The kernel requires the bin CL to end with INCREMENT_SEMAPHORE, FLUSH.
    const b = job.bcl();
    try std.testing.expectEqual(@intFromEnum(cl.Packet.increment_semaphore), b[b.len - 2]);
    try std.testing.expectEqual(@intFromEnum(cl.Packet.flush), b[b.len - 1]);
    try std.testing.expectEqual(@as(u32, 16), job.submit.uniforms_size);
}
