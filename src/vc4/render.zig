//! Builds DRM_IOCTL_VC4_SUBMIT_CL jobs: one frame (one render target) with
//! any number of draw calls.
//!
//! The kernel refers to buffers by their index in the job's `bo_handles`
//! array, which `Frame` builds from the GEM handles each draw uses, so
//! callers deal in handles only.

const std = @import("std");
const cl = @import("cl.zig");
const compiler = @import("compiler.zig");
const texture = @import("texture.zig");
const device = @import("device.zig");

pub const ShaderBinding = struct {
    /// GEM handle of the shader BO.
    handle: u32,
    /// What each uniform stream word holds (from the compiler).
    layout: []const compiler.UniformKind,
    /// Values for `.user` entries, by index.
    user: []const u32 = &.{},
};

pub const Texture = struct {
    handle: u32,
    config: texture.Config,
};

pub const Attribute = struct {
    /// GEM handle of the vertex buffer.
    handle: u32,
    offset: u32,
    /// Bytes per vertex (up to 64).
    size: u8,
    stride: u8,
    vs_vpm_offset: u8,
    cs_vpm_offset: u8,
};

pub const Indices = struct {
    handle: u32,
    /// Byte offset of the first index.
    offset: u32,
    /// The largest index used, so the kernel can bounds-check attributes.
    max_index: u32,
    type: enum { u8, u16 } = .u16,
};

/// The area of the target that clip space maps to, in pixels with y = 0 at
/// the top.
pub const Viewport = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    /// Viewport half-size in 1/16ths of a pixel, as the vertex shaders and
    /// the clipper want it. Y is negated so that +Y in clip space points up.
    pub fn scale(v: Viewport) [2]f32 {
        return .{
            @as(f32, @floatFromInt(v.width)) / 2.0 * 16.0,
            -@as(f32, @floatFromInt(v.height)) / 2.0 * 16.0,
        };
    }

    pub fn scaleBits(v: Viewport) [2]u32 {
        const s = v.scale();
        return .{ @bitCast(s[0]), @bitCast(s[1]) };
    }
};

pub const Draw = struct {
    fs: ShaderBinding,
    vs: ShaderBinding,
    cs: ShaderBinding,
    fs_num_varyings: u8,
    attributes: []const Attribute,
    vs_attribute_mask: u8,
    vs_attributes_size: u8,
    cs_attribute_mask: u8,
    cs_attributes_size: u8,
    primitive: cl.PrimitiveMode = .triangles,
    /// Vertex count (or index count with `indices`).
    count: u32,
    /// First vertex for array draws.
    first: u32 = 0,
    indices: ?Indices = null,
    config: cl.Bcl.Config = .{},
    /// Defaults to the whole target.
    viewport: ?Viewport = null,
    /// Texture for unit 0 of the fragment shader.
    texture: ?Texture = null,
};

/// A linear B8G8R8A8 colour buffer. Depth lives only in the tile buffer:
/// it is cleared to `clear_z` at the start of each tile and never stored.
pub const Target = struct {
    handle: u32,
    width: u16,
    height: u16,

    /// Byte stride the hardware uses for linear render targets: the width
    /// rounded up to a 4-pixel micro-tile.
    pub fn pitch(width: u16) u32 {
        return std.mem.alignForward(u32, width, 4) * 4;
    }

    pub fn fullViewport(t: Target) Viewport {
        return .{ .x = 0, .y = 0, .width = t.width, .height = t.height };
    }
};

pub const Load = union(enum) {
    /// Start from a solid colour (0xAARRGGBB).
    clear: u32,
    /// Keep the target's current contents.
    keep,
};

pub const max_bos = 64;

pub const Error = error{FrameFull};

/// A frame being recorded. `submit` points into the frame's own buffers,
/// so a Frame must not be moved between `begin` and submission. It is
/// large; keep it in static or heap memory rather than on the stack, and
/// declare it `undefined` (`begin` initialises it) so it costs nothing in
/// the binary.
pub const Frame = struct {
    bcl_buf: [16 * 1024]u8 = undefined,
    bin: cl.Bcl = undefined,
    rec_buf: [16 * 1024]u8 = undefined,
    rec: cl.Writer = undefined,
    rec_count: u32 = 0,
    uniforms: [8 * 1024]u32 = undefined,
    uniforms_len: usize = 0,
    bo_handles: [max_bos]u32 = undefined,
    bo_count: u32 = 0,
    target: Target = undefined,
    load: Load = .keep,
    clear_z: u32 = 0xffffff,
    draws: u32 = 0,
    submit: device.SubmitCl = .{},

    pub fn begin(f: *Frame, target: Target, load: Load) void {
        f.bin = .init(&f.bcl_buf);
        f.rec = .init(&f.rec_buf);
        f.rec_count = 0;
        f.uniforms_len = 0;
        f.bo_count = 0;
        f.target = target;
        f.load = load;
        f.clear_z = 0xffffff;
        f.draws = 0;
        _ = f.index(target.handle) catch unreachable;

        const tiles = f.tileCounts();
        f.bin.tileBinningModeConfig(@intCast(tiles[0]), @intCast(tiles[1]));
        f.bin.startTileBinning();
        f.bin.primitiveListFormat();
    }

    fn tileCounts(f: *const Frame) [2]u16 {
        return .{
            std.math.divCeil(u16, f.target.width, cl.tile_size) catch unreachable,
            std.math.divCeil(u16, f.target.height, cl.tile_size) catch unreachable,
        };
    }

    /// The bo_handles index for a GEM handle, adding it if needed.
    fn index(f: *Frame, handle: u32) Error!u32 {
        for (f.bo_handles[0..f.bo_count], 0..) |h, i| if (h == handle) return @intCast(i);
        if (f.bo_count == max_bos) return error.FrameFull;
        f.bo_handles[f.bo_count] = handle;
        f.bo_count += 1;
        return f.bo_count - 1;
    }

    fn pushUniform(f: *Frame, v: u32) Error!void {
        if (f.uniforms_len == f.uniforms.len) return error.FrameFull;
        f.uniforms[f.uniforms_len] = v;
        f.uniforms_len += 1;
    }

    pub fn draw(f: *Frame, d: Draw) Error!void {
        std.debug.assert(d.attributes.len >= 1 and d.attributes.len <= 8);
        // Worst case control list and shader record space for one draw.
        if (f.bin.w.len + 128 > f.bcl_buf.len or f.rec.len + 128 > f.rec_buf.len) return error.FrameFull;

        const vp = d.viewport orelse f.target.fullViewport();
        const scale = vp.scale();
        // Clip to the viewport (the hardware does guard-band clipping, so
        // primitives would otherwise rasterise outside it) and the target.
        const x0: i32 = @max(vp.x, 0);
        const y0: i32 = @max(vp.y, 0);
        const x1: i32 = @min(vp.x + @as(i32, @intCast(vp.width)), f.target.width);
        const y1: i32 = @min(vp.y + @as(i32, @intCast(vp.height)), f.target.height);
        if (x1 <= x0 or y1 <= y0) return;

        f.bin.clipWindow(@intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0));
        f.bin.configurationBits(d.config);
        f.bin.viewportOffset(@as(f32, @floatFromInt(vp.x)) + @as(f32, @floatFromInt(vp.width)) / 2.0, @as(f32, @floatFromInt(vp.y)) + @as(f32, @floatFromInt(vp.height)) / 2.0);
        f.bin.clipperXyScaling(scale[0], scale[1]);
        f.bin.clipperZScaling(0.5, 0.5);

        // Shader record.
        var attrs: [8]cl.Attribute = undefined;
        for (d.attributes, 0..) |a, i| attrs[i] = .{
            .bo_index = try f.index(a.handle),
            .offset = a.offset,
            .size = a.size,
            .stride = a.stride,
            .vs_vpm_offset = a.vs_vpm_offset,
            .cs_vpm_offset = a.cs_vpm_offset,
        };
        cl.writeShaderRecord(&f.rec, .{
            .flags = cl.shader_flag_fs_single_thread | cl.shader_flag_enable_clipping,
            .fs_num_varyings = d.fs_num_varyings,
            .fs_bo_index = try f.index(d.fs.handle),
            .vs_bo_index = try f.index(d.vs.handle),
            .cs_bo_index = try f.index(d.cs.handle),
            .vs_attribute_mask = d.vs_attribute_mask,
            .vs_attributes_size = d.vs_attributes_size,
            .cs_attribute_mask = d.cs_attribute_mask,
            .cs_attributes_size = d.cs_attributes_size,
            .attributes = attrs[0..d.attributes.len],
        });
        f.rec_count += 1;

        // Uniform streams in shader record order: FS, VS, CS. Each starts
        // with the bo_handles index of every texture it samples, which the
        // kernel uses to relocate P0, followed by the uniform words.
        for ([_]ShaderBinding{ d.fs, d.vs, d.cs }) |s| {
            for (s.layout) |k| if (k == .tex_p0) try f.pushUniform(try f.index(d.texture.?.handle));
            for (s.layout) |k| try f.pushUniform(switch (k) {
                .user => |i| s.user[i],
                .tex_p0 => texture.p0(d.texture.?.config),
                .tex_p1 => texture.p1(d.texture.?.config),
            });
        }

        f.bin.glShaderState(@intCast(d.attributes.len));
        if (d.indices) |ib| {
            f.bin.gemHandles(try f.index(ib.handle), 0);
            f.bin.glIndexedPrimitive(d.primitive, ib.type == .u16, d.count, ib.offset, ib.max_index);
        } else {
            f.bin.glArrayPrimitive(d.primitive, d.count, d.first);
        }
        f.draws += 1;
    }

    /// Completes the frame and returns the ioctl argument.
    pub fn finish(f: *Frame) *device.SubmitCl {
        f.bin.finish();
        const tiles = f.tileCounts();
        f.submit = .{
            .bin_cl = @intFromPtr(&f.bcl_buf),
            .bin_cl_size = @intCast(f.bin.bytes().len),
            .shader_rec = @intFromPtr(&f.rec_buf),
            .shader_rec_size = @intCast(f.rec.len),
            .shader_rec_count = f.rec_count,
            .uniforms = @intFromPtr(&f.uniforms),
            .uniforms_size = @intCast(f.uniforms_len * 4),
            .bo_handles = @intFromPtr(&f.bo_handles),
            .bo_handle_count = f.bo_count,
            .width = f.target.width,
            .height = f.target.height,
            .min_x_tile = 0,
            .min_y_tile = 0,
            .max_x_tile = @intCast(tiles[0] - 1),
            .max_y_tile = @intCast(tiles[1] - 1),
            .color_write = .{
                .hindex = 0,
                .bits = cl.renderConfigBits(.linear, cl.render_config_format_rgba8888),
            },
            // The clear values are always loaded so depth starts cleared;
            // keeping the colour loads it back from the target.
            .clear_color = switch (f.load) {
                .clear => |c| .{ c, c },
                .keep => .{ 0, 0 },
            },
            .clear_z = f.clear_z,
            .flags = device.SubmitCl.flag_use_clear_color,
        };
        if (f.load == .keep) {
            f.submit.color_read = .{
                .hindex = 0,
                .bits = cl.loadStoreBits(.linear, .color, cl.loadstore_format_rgba8888),
            };
        }
        return &f.submit;
    }

    pub fn bcl(f: *const Frame) []const u8 {
        return f.bin.bytes();
    }

    pub fn shaderRecords(f: *const Frame) []const u8 {
        return f.rec_buf[0..f.rec.len];
    }

    pub fn uniformWords(f: *const Frame) []const u32 {
        return f.uniforms[0..f.uniforms_len];
    }

    pub fn handles(f: *const Frame) []const u32 {
        return f.bo_handles[0..f.bo_count];
    }
};

const testing = std.testing;

fn testDraw(fs_layout: []const compiler.UniformKind, vs_layout: []const compiler.UniformKind, attrs: []const Attribute, user: []const u32) Draw {
    return .{
        .fs = .{ .handle = 11, .layout = fs_layout },
        .vs = .{ .handle = 12, .layout = vs_layout, .user = user },
        .cs = .{ .handle = 13, .layout = vs_layout, .user = user },
        .fs_num_varyings = 0,
        .attributes = attrs,
        .vs_attribute_mask = 1,
        .vs_attributes_size = 8,
        .cs_attribute_mask = 1,
        .cs_attributes_size = 8,
        .count = 3,
    };
}

test "uniform streams start with texture handle indices" {
    const fs_layout = [_]compiler.UniformKind{ .{ .tex_p0 = 0 }, .{ .tex_p1 = 0 } };
    const vs_layout = [_]compiler.UniformKind{ .{ .user = 1 }, .{ .user = 0 } };
    const attrs = [_]Attribute{.{ .handle = 14, .offset = 0, .size = 8, .stride = 8, .vs_vpm_offset = 0, .cs_vpm_offset = 0 }};
    const cfg: texture.Config = .{ .width = 64, .height = 64 };
    const f = try testing.allocator.create(Frame);
    defer testing.allocator.destroy(f);
    f.* = .{};
    f.begin(.{ .handle = 10, .width = 640, .height = 480 }, .{ .clear = 0 });
    var d = testDraw(&fs_layout, &vs_layout, &attrs, &.{ 100, 200 });
    d.texture = .{ .handle = 15, .config = cfg };
    try f.draw(d);
    _ = f.finish();
    // bo_handles: target, vertices, fs, vs, cs, texture.
    try testing.expectEqualSlices(u32, &.{ 10, 14, 11, 12, 13, 15 }, f.handles());
    try testing.expectEqualSlices(u32, &.{ 5, texture.p0(cfg), texture.p1(cfg), 200, 100, 200, 100 }, f.uniformWords());
}

test "multiple draws share buffers and add shader records" {
    const layout = [_]compiler.UniformKind{.{ .user = 0 }};
    const attrs = [_]Attribute{.{ .handle = 14, .offset = 0, .size = 8, .stride = 8, .vs_vpm_offset = 0, .cs_vpm_offset = 0 }};
    const f = try testing.allocator.create(Frame);
    defer testing.allocator.destroy(f);
    f.* = .{};
    f.begin(.{ .handle = 10, .width = 128, .height = 64 }, .keep);
    try f.draw(testDraw(&.{}, &layout, &attrs, &.{1}));
    var indexed = testDraw(&.{}, &layout, &attrs, &.{2});
    indexed.indices = .{ .handle = 16, .offset = 0, .max_index = 2 };
    try f.draw(indexed);
    const s = f.finish();
    try testing.expectEqual(@as(u32, 2), s.shader_rec_count);
    try testing.expectEqual(@as(u32, 6), s.bo_handle_count); // target, vbo, fs, vs, cs, ib
    try testing.expectEqual(@as(u32, 0), s.color_read.hindex); // keep loads the target
    const b = f.bcl();
    try testing.expectEqual(@intFromEnum(cl.Packet.flush), b[b.len - 1]);
}
