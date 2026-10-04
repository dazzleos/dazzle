//! Drawing canvases with the GPU: their batches become draws in a vc4
//! frame.
//!
//! A frame can draw several canvases, with other draws between them (a 3D
//! view between two layers of 2D, say): `prepare` takes them all, then
//! `record` draws each in turn. `draw` does both for a single canvas.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");

const render = vc4.render;
const Canvas = canvas_mod.Canvas;

pub const Renderer = struct {
    dev: vc4.Device,
    shape: shader.Pipeline,
    solid: shader.Pipeline,
    text: shader.Pipeline,
    /// The frame's vertices; replaced by a bigger one when it fills up.
    vbo: ?vc4.Bo = null,
    /// Where the next canvas's vertices go.
    cursor: u32 = 0,
    /// The glyph atlas's texture, and the atlas last uploaded to it.
    atlas_bo: ?vc4.Bo = null,
    atlas: ?*atlas_mod.Atlas = null,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !Renderer {
        var shape = try shader.Pipeline.init(gpa, dev, shaders.shape(), shaders.shape_layout);
        errdefer shape.deinit(dev);
        var solid = try shader.Pipeline.init(gpa, dev, shaders.solid(), shaders.solid_layout);
        errdefer solid.deinit(dev);
        return .{ .dev = dev, .shape = shape, .solid = solid, .text = try shader.Pipeline.init(gpa, dev, shaders.text(), shaders.text_layout) };
    }

    pub fn deinit(r: *Renderer) void {
        r.shape.deinit(r.dev);
        r.solid.deinit(r.dev);
        r.text.deinit(r.dev);
        if (r.vbo) |bo| r.dev.destroyBo(bo);
        if (r.atlas_bo) |bo| r.dev.destroyBo(bo);
    }

    /// Records one canvas's shapes into `frame` (whose previous use of the
    /// renderer's buffers has finished rendering).
    pub fn draw(r: *Renderer, c: *const Canvas, frame: *render.Frame) !void {
        try r.prepare(&.{c});
        try r.record(c, frame);
    }

    /// Makes room for the canvases a frame draws, and uploads the glyphs
    /// their text added to the atlas. The previous frame must have
    /// finished rendering.
    pub fn prepare(r: *Renderer, canvases: []const *const Canvas) !void {
        var bytes: usize = 0;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        r.cursor = 0;
        if (bytes > 0 and (r.vbo == null or r.vbo.?.map.len < bytes)) {
            if (r.vbo) |bo| r.dev.destroyBo(bo);
            r.vbo = null;
            r.vbo = try r.dev.createBo(@intCast(std.mem.alignForward(usize, bytes * 2, 64 * 1024)));
        }
        for (canvases) |c| if (c.atlas) |a| try r.upload(a);
    }

    fn upload(r: *Renderer, a: *atlas_mod.Atlas) !void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        if (r.atlas_bo == null) r.atlas_bo = try r.dev.createBo(vc4.texture.imageSize(w, h));
        // Another atlas (or the first): all of it.
        if (r.atlas != a) {
            r.atlas = a;
            a.dirty = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        }
        const d = a.dirty orelse return;
        // Whole micro-tiles' rows, so uploads stay aligned.
        const y0: u32 = d.y0 / 4 * 4;
        const y1: u32 = @min(std.mem.alignForward(u32, d.y1, 4), h);
        vc4.texture.uploadRect(r.atlas_bo.?.map, w, h, .{ .x = 0, .y = y0, .width = w, .height = y1 - y0 }, a.pixels[y0 * w .. y1 * w], w);
        a.dirty = null;
    }

    /// Records a canvas (one of those given to `prepare`) into `frame`.
    pub fn record(r: *Renderer, c: *const Canvas, frame: *render.Frame) !void {
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const vbo = r.vbo orelse return error.NotPrepared;
            const offset = r.cursor;
            if (offset + data.len > vbo.map.len) return error.NotPrepared;
            @memcpy(vbo.map[offset..][0..data.len], data);
            r.cursor += @intCast(std.mem.alignForward(usize, data.len, 16));
            const p = switch (b.kind) {
                .shape => &r.shape,
                .solid => &r.solid,
                .text => &r.text,
            };
            const texture: ?render.Texture = if (b.kind == .text) .{
                .handle = (r.atlas_bo orelse return error.NotPrepared).handle,
                .config = .{
                    .width = atlas_mod.width,
                    .height = atlas_mod.height,
                    .mag_filter = .nearest,
                    .min_filter = .nearest,
                    .wrap_s = .clamp,
                    .wrap_t = .clamp,
                },
            } else null;
            try p.draw(frame, .{
                .vertices = vbo.handle,
                .vertex_offset = offset,
                .count = b.vertexCount(),
                .texture = texture,
                .scissor = if (b.clip) |clip| scissor(clip) else null,
            });
        }
    }
};

fn scissor(clip: canvas_mod.Rect) render.Viewport {
    const x0 = @floor(@max(clip.x, 0));
    const y0 = @floor(@max(clip.y, 0));
    const x1 = @max(@ceil(clip.x + clip.w), x0);
    const y1 = @max(@ceil(clip.y + clip.h), y0);
    return .{ .x = @intFromFloat(@min(x0, 1e6)), .y = @intFromFloat(@min(y0, 1e6)), .width = @intFromFloat(@min(x1 - x0, 1e6)), .height = @intFromFloat(@min(y1 - y0, 1e6)) };
}
