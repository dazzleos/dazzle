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
    @"opaque": shader.Pipeline,
    text: shader.Pipeline,
    image: shader.Pipeline,
    gpa: std.mem.Allocator,
    /// The images' textures, by image id; those no frame draws are freed.
    images: std.AutoHashMapUnmanaged(u64, vc4.Bo) = .empty,
    /// The frame's vertices; replaced by a bigger one when it fills up.
    vbo: ?vc4.Bo = null,
    /// With `pipelined`: the previous frame's, which the GPU may still be
    /// drawing from while this one is recorded. The two take turns.
    other_vbo: ?vc4.Bo = null,
    /// The previous frame may still be rendering when the next is
    /// prepared (see app.Window.setPipelined). Its vertices and glyph
    /// texture are left alone: each frame has its own, taking turns, and a
    /// glyph texture catches up on the glyphs added since its last turn.
    /// (Images no longer drawn are freed, but the kernel keeps a buffer a
    /// frame uses until it is done.)
    pipelined: bool = false,
    /// Where the next canvas's vertices go.
    cursor: u32 = 0,
    /// The glyph atlas's texture, and the atlas last uploaded to it; and
    /// the rows of it not uploaded yet.
    atlas_bo: ?vc4.Bo = null,
    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    /// With `pipelined`: the previous frame's glyph texture, and its rows
    /// not uploaded yet.
    other_atlas_bo: ?vc4.Bo = null,
    other_atlas_stale: ?atlas_mod.Rect = null,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !Renderer {
        var shape = try shader.Pipeline.init(gpa, dev, shaders.shape(), shaders.shape_layout);
        errdefer shape.deinit(dev);
        var solid = try shader.Pipeline.init(gpa, dev, shaders.solid(), shaders.solid_layout);
        errdefer solid.deinit(dev);
        var opaque_solid = try shader.Pipeline.init(gpa, dev, shaders.opaqueSolid(), shaders.solid_layout);
        errdefer opaque_solid.deinit(dev);
        var text = try shader.Pipeline.init(gpa, dev, shaders.text(), shaders.text_layout);
        errdefer text.deinit(dev);
        return .{ .dev = dev, .gpa = gpa, .shape = shape, .solid = solid, .@"opaque" = opaque_solid, .text = text, .image = try shader.Pipeline.init(gpa, dev, shaders.image(), shaders.text_layout) };
    }

    pub fn deinit(r: *Renderer) void {
        r.shape.deinit(r.dev);
        r.solid.deinit(r.dev);
        r.@"opaque".deinit(r.dev);
        r.text.deinit(r.dev);
        r.image.deinit(r.dev);
        var it = r.images.valueIterator();
        while (it.next()) |bo| r.dev.destroyBo(bo.*);
        r.images.deinit(r.gpa);
        if (r.vbo) |bo| r.dev.destroyBo(bo);
        if (r.other_vbo) |bo| r.dev.destroyBo(bo);
        if (r.atlas_bo) |bo| r.dev.destroyBo(bo);
        if (r.other_atlas_bo) |bo| r.dev.destroyBo(bo);
    }

    /// Records one canvas's shapes into `frame` (whose previous use of the
    /// renderer's buffers has finished rendering).
    pub fn draw(r: *Renderer, c: *const Canvas, frame: *render.Frame) !void {
        try r.prepare(&.{c});
        try r.record(c, frame, null);
    }

    /// Makes room for the canvases a frame draws, and uploads the glyphs
    /// their text added to the atlas. The previous frame must have
    /// finished rendering, unless `pipelined`.
    pub fn prepare(r: *Renderer, canvases: []const *const Canvas) !void {
        if (r.pipelined) {
            std.mem.swap(?vc4.Bo, &r.vbo, &r.other_vbo);
            std.mem.swap(?vc4.Bo, &r.atlas_bo, &r.other_atlas_bo);
            std.mem.swap(?atlas_mod.Rect, &r.atlas_stale, &r.other_atlas_stale);
        }
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
        try r.uploadImages(canvases);
    }

    /// Gives each image drawn a texture (uploaded once), and frees those of
    /// images no longer drawn.
    fn uploadImages(r: *Renderer, canvases: []const *const Canvas) !void {
        var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer used.deinit(r.gpa);
        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            try used.put(r.gpa, img.id, {});
            if (r.images.contains(img.id)) continue;
            const bo = try r.dev.createBo(vc4.texture.imageSize(img.width, img.height));
            errdefer r.dev.destroyBo(bo);
            vc4.texture.upload(bo.map, img.pixels, img.width, img.height);
            try r.images.put(r.gpa, img.id, bo);
        };
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(r.gpa);
        var it = r.images.iterator();
        while (it.next()) |e| if (!used.contains(e.key_ptr.*)) try stale.append(r.gpa, e.key_ptr.*);
        for (stale.items) |id| r.dev.destroyBo(r.images.fetchRemove(id).?.value);
    }

    fn upload(r: *Renderer, a: *atlas_mod.Atlas) !void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        if (r.atlas_bo == null) {
            r.atlas_bo = try r.dev.createBo(vc4.texture.imageSizeOf(.a8, w, h));
            r.atlas_stale = all;
        }
        // Another atlas (or the first): all of it.
        if (r.atlas != a) {
            r.atlas = a;
            a.dirty = all;
        }
        // What changed, for this texture and (taking turns) the other.
        if (a.dirty) |d| {
            r.atlas_stale = merge(r.atlas_stale, d);
            r.other_atlas_stale = merge(r.other_atlas_stale, d);
            a.dirty = null;
        }
        const d = r.atlas_stale orelse return;
        // Whole micro-tiles' rows, so uploads stay aligned.
        const uh = vc4.Format.a8.utileHeight();
        const y0: u32 = d.y0 / uh * uh;
        const y1: u32 = @min(std.mem.alignForward(u32, d.y1, uh), h);
        vc4.texture.uploadRectOf(.a8, r.atlas_bo.?.map, w, h, .{ .x = 0, .y = y0, .width = w, .height = y1 - y0 }, a.pixels[y0 * w .. y1 * w], w);
        r.atlas_stale = null;
    }

    fn merge(a: ?atlas_mod.Rect, b: atlas_mod.Rect) atlas_mod.Rect {
        const x = a orelse return b;
        return .{ .x0 = @min(x.x0, b.x0), .y0 = @min(x.y0, b.y0), .x1 = @max(x.x1, b.x1), .y1 = @max(x.y1, b.y1) };
    }

    /// Records a canvas (one of those given to `prepare`) into `frame`.
    /// Batches outside the parts of the frame being rendered (see
    /// `render.Frame.limitTo`) are left out. When the frame fills up,
    /// `flush` renders it and drawing goes on; without it, that is
    /// `error.FrameFull`.
    pub fn record(r: *Renderer, c: *const Canvas, frame: *render.Frame, flush: ?render.Flush) !void {
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            if (!frame.covers(scissor(area))) continue;
            const vbo = r.vbo orelse return error.NotPrepared;
            if (flush) |fl| if (!frame.hasRoom(max_uniform_words)) try fl.flush(frame);
            const offset = r.cursor;
            if (offset + data.len > vbo.map.len) return error.NotPrepared;
            @memcpy(vbo.map[offset..][0..data.len], data);
            r.cursor += @intCast(std.mem.alignForward(usize, data.len, 16));
            const p = switch (b.kind) {
                .shape => &r.shape,
                .solid => &r.solid,
                .@"opaque" => &r.@"opaque",
                .text => &r.text,
                .image => &r.image,
            };
            const texture: ?render.Texture = switch (b.kind) {
                .text => .{
                    .handle = (r.atlas_bo orelse return error.NotPrepared).handle,
                    .config = .{
                        .type = vc4.Format.a8.textureType(),
                        .width = atlas_mod.width,
                        .height = atlas_mod.height,
                        .mag_filter = .nearest,
                        .min_filter = .nearest,
                        .wrap_s = .clamp,
                        .wrap_t = .clamp,
                    },
                },
                // Scaled smoothly.
                .image => .{
                    .handle = (r.images.get((b.image orelse continue).id) orelse return error.NotPrepared).handle,
                    .config = .{ .width = b.image.?.width, .height = b.image.?.height, .wrap_s = .clamp, .wrap_t = .clamp },
                },
                else => null,
            };
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

/// More than any of the canvas shaders' draws uses.
const max_uniform_words = 256;

fn scissor(clip: canvas_mod.Rect) render.Viewport {
    const x0 = @floor(@max(clip.x, 0));
    const y0 = @floor(@max(clip.y, 0));
    const x1 = @max(@ceil(clip.x + clip.w), x0);
    const y1 = @max(@ceil(clip.y + clip.h), y0);
    return .{ .x = @intFromFloat(@min(x0, 1e6)), .y = @intFromFloat(@min(y0, 1e6)), .width = @intFromFloat(@min(x1 - x0, 1e6)), .height = @intFromFloat(@min(y1 - y0, 1e6)) };
}
