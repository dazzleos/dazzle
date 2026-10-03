//! Drawing a canvas with the GPU: its batches become draws in a vc4 frame.

const std = @import("std");
const vc4 = @import("vc4");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");

const render = vc4.render;
const compiler = vc4.compiler;

const Stage = struct {
    handle: u32,
    compiled: compiler.Compiled,

    fn binding(s: *const Stage, user: []const u32) render.ShaderBinding {
        return .{ .handle = s.handle, .layout = s.compiled.uniforms(), .user = user };
    }
};

const Program = struct {
    fs: Stage,
    vs: Stage,
    cs: Stage,

    fn init(dev: vc4.Device, c: shaders.Compiled) !Program {
        return .{
            .fs = .{ .handle = try dev.createShaderBo(c.fs.code()), .compiled = c.fs },
            .vs = .{ .handle = try dev.createShaderBo(c.vs.code()), .compiled = c.vs },
            .cs = .{ .handle = try dev.createShaderBo(c.cs.code()), .compiled = c.cs },
        };
    }

    fn deinit(p: *const Program, dev: vc4.Device) void {
        for ([_]u32{ p.fs.handle, p.vs.handle, p.cs.handle }) |h| vc4.drm.gemClose(dev.fd, h);
    }
};

pub const Renderer = struct {
    dev: vc4.Device,
    shape: Program,
    solid: Program,
    /// The frame's vertices; replaced by a bigger one when it fills up.
    vbo: ?vc4.Bo = null,

    pub fn init(dev: vc4.Device) !Renderer {
        const shape = try Program.init(dev, try shaders.compileShape());
        errdefer shape.deinit(dev);
        return .{ .dev = dev, .shape = shape, .solid = try Program.init(dev, try shaders.compileSolid()) };
    }

    pub fn deinit(r: *Renderer) void {
        r.shape.deinit(r.dev);
        r.solid.deinit(r.dev);
        if (r.vbo) |bo| r.dev.destroyBo(bo);
    }

    /// Records the canvas's shapes into `frame` (whose previous use of the
    /// vertex buffer has finished rendering).
    pub fn draw(r: *Renderer, c: *const canvas_mod.Canvas, frame: *render.Frame) !void {
        var bytes: usize = 0;
        for (c.batches.items) |*b| bytes += b.floats.items.len * 4;
        if (bytes == 0) return;
        if (r.vbo == null or r.vbo.?.map.len < bytes) {
            if (r.vbo) |bo| r.dev.destroyBo(bo);
            r.vbo = null;
            r.vbo = try r.dev.createBo(@intCast(std.mem.alignForward(usize, bytes * 2, 64 * 1024)));
        }
        const vbo = r.vbo.?;
        const scale = frame.target.fullViewport().scaleBits();
        var offset: u32 = 0;
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            @memcpy(vbo.map[offset..][0..data.len], data);
            const p = if (b.kind == .shape) &r.shape else &r.solid;
            const stride: u8 = @intCast(canvas_mod.floatsPerVertex(b.kind) * 4);
            const attrs = [_]render.Attribute{
                .{ .handle = vbo.handle, .offset = offset, .size = 8, .stride = stride, .vs_vpm_offset = 0, .cs_vpm_offset = 0 },
                .{ .handle = vbo.handle, .offset = offset + 8, .size = stride - 8, .stride = stride, .vs_vpm_offset = 8, .cs_vpm_offset = 0 },
            };
            try frame.draw(.{
                .fs = p.fs.binding(&.{}),
                .vs = p.vs.binding(&scale),
                .cs = p.cs.binding(&scale),
                .fs_num_varyings = stride / 4 - 2,
                .attributes = &attrs,
                .vs_attribute_mask = 0b11,
                .vs_attributes_size = stride,
                .cs_attribute_mask = 0b01,
                .cs_attributes_size = 8,
                .count = b.vertexCount(),
                .scissor = if (b.clip) |clip| .{
                    .x = @intFromFloat(@floor(clip.x)),
                    .y = @intFromFloat(@floor(clip.y)),
                    .width = @intFromFloat(@max(@ceil(clip.w), 0)),
                    .height = @intFromFloat(@max(@ceil(clip.h), 0)),
                } else null,
            });
            offset += @intCast(std.mem.alignForward(usize, data.len, 16));
        }
    }
};
