//! Drawing a canvas with the GPU: its batches become draws in a vc4 frame.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");

const render = vc4.render;

pub const Renderer = struct {
    dev: vc4.Device,
    shape: shader.Pipeline,
    solid: shader.Pipeline,
    /// The frame's vertices; replaced by a bigger one when it fills up.
    vbo: ?vc4.Bo = null,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !Renderer {
        var shape = try shader.Pipeline.init(gpa, dev, shaders.shape(), shaders.shape_layout);
        errdefer shape.deinit(dev);
        return .{ .dev = dev, .shape = shape, .solid = try shader.Pipeline.init(gpa, dev, shaders.solid(), shaders.solid_layout) };
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
        var offset: u32 = 0;
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            @memcpy(vbo.map[offset..][0..data.len], data);
            const p = if (b.kind == .shape) &r.shape else &r.solid;
            try p.draw(frame, .{
                .vertices = vbo.handle,
                .vertex_offset = offset,
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
