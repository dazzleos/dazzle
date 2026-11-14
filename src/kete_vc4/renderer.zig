//! Kete's canvases drawn by the GPU: a `kete.gfx.Renderer` that turns
//! their batches into draws in a vc4 frame, with Dazzle's shaders (kete's
//! batches have the same kinds and vertex layouts as Dazzle's own).
//!
//! It draws straight into the window's buffer (`renderDmabuf`): the
//! window (`window.zig`) gives it as a `DmabufTarget` whose `id` is the
//! buffer's GEM handle on the same device, so there is nothing to import.
//! Draws of the app's own (`kete.gfx.GpuDraw`) are given the
//! `vc4.render.Frame` (see `Vc4Area`).
//!
//! It waits for the GPU to finish each frame, unless `pipelined`: then a
//! frame is handed to the GPU and left with it (`pending`, which the
//! window keeps in flight, showing it once the next is handed over), so
//! the next is recorded while the GPU renders it. Its buffers take turns
//! for that: the previous frame's vertices and glyph texture are left
//! alone while the GPU may still read them.

const std = @import("std");
const kete = @import("kete");
const vc4 = @import("vc4");
const shader = @import("shader");
const app = @import("app");
const dazzle_gfx = @import("gfx");
const sys = @import("sys");

const kgfx = kete.gfx;
const render = vc4.render;
const shaders = dazzle_gfx.shaders;
const atlas_mod = kgfx.atlas;
const Canvas = kgfx.Canvas;

comptime {
    // The batches' vertices are laid out as Dazzle's shaders take them.
    std.debug.assert(kgfx.shaders.shape_floats == shaders.shape_floats);
    std.debug.assert(kgfx.shaders.solid_floats == shaders.solid_floats);
    std.debug.assert(kgfx.shaders.text_floats == shaders.text_floats);
    std.debug.assert(atlas_mod.width == dazzle_gfx.atlas.width and atlas_mod.height == dazzle_gfx.atlas.height);
}

/// A DRM format modifier for the buffers the texture unit reads (T or LT
/// tiled, as `render.Target.textureTiling` says for their size): Broadcom's
/// VC4 T-tiled modifier.
pub const tiled_modifier: u64 = (0x07 << 56) | 1;

/// The frames drawn: how many, the time spent recording their draws (on
/// the CPU) and drawing them (from handing them to the GPU to its
/// finishing; with `pipelined`, only handing them over), and how many
/// pixels they redrew.
pub const Stats = struct {
    frames: u32 = 0,
    cpu_ns: u64 = 0,
    gpu_ns: u64 = 0,
    pixels: f64 = 0,
};

pub const Renderer = struct {
    dev: vc4.Device,
    gpu: app.Gpu,
    gpa: std.mem.Allocator,
    shape: shader.Pipeline,
    solid: shader.Pipeline,
    @"opaque": shader.Pipeline,
    text: shader.Pipeline,
    image: shader.Pipeline,
    /// The images' textures, by image id; those no frame draws are freed.
    images: std.AutoHashMapUnmanaged(u64, ImageTexture) = .empty,
    /// The frame's vertices; replaced by a bigger one when it fills up.
    vbo: ?vc4.Bo = null,
    /// Where the next canvas's vertices go.
    cursor: u32 = 0,
    /// The glyph atlas's texture, the atlas last uploaded to it, and the
    /// rows of it not uploaded yet.
    atlas_bo: ?vc4.Bo = null,
    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    /// The frame being recorded (large: kept here, not on the stack).
    frame: *render.Frame,
    /// What drawing the frames took, since the app last took it (`takeStats`).
    stats: Stats = .{},
    /// Frames are drawn 4x multisampled (antialiased; see
    /// `render.Frame.beginMultisampled`).
    multisampled: bool = false,
    /// Frames are left with the GPU rather than waited for (see above):
    /// set with `setPipelined`.
    pipelined: bool = false,
    /// The frame last handed to the GPU and not waited for (`Gpu.submit`'s
    /// number), for the window to keep in flight.
    pending: ?u64 = null,
    /// With `pipelined`: the previous frame's vertices and glyph texture
    /// (and the rows of it not uploaded yet), taking turns with this one's.
    other_vbo: ?vc4.Bo = null,
    other_atlas_bo: ?vc4.Bo = null,
    other_atlas_stale: ?atlas_mod.Rect = null,
    /// The frame being drawn is a window's that does not fill the screen
    /// or the work area, and has no shadow (see `Window.beginDmabufFrame`):
    /// a 1-pixel border is drawn along its edges, in `border_color` (the
    /// theme's outline variant), so windows over each other do not run
    /// together.
    outline: bool = false,
    border_color: kgfx.Color = .rgb(0x49454f),
    /// The window's buffer's pixels to each of its own (less than 1 when
    /// it draws a smaller buffer, which the shell stretches): what kete
    /// lays out at the window's size is drawn this much smaller. Set for
    /// each frame (see `Window.beginDmabufFrame`).
    scale: f32 = 1,
    border: Canvas,

    const ImageTexture = struct {
        bo: vc4.Bo,
        /// The image's `version` when it was uploaded.
        version: u64,
    };

    pub const backend: kgfx.RenderBackend = .custom;

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device, gpu: app.Gpu) !Renderer {
        var shape = try shader.Pipeline.init(gpa, dev, shaders.shape(), shaders.shape_layout);
        errdefer shape.deinit(dev);
        var solid = try shader.Pipeline.init(gpa, dev, shaders.solid(), shaders.solid_layout);
        errdefer solid.deinit(dev);
        var opaque_solid = try shader.Pipeline.init(gpa, dev, shaders.opaqueSolid(), shaders.solid_layout);
        errdefer opaque_solid.deinit(dev);
        var text = try shader.Pipeline.init(gpa, dev, shaders.text(), shaders.text_layout);
        errdefer text.deinit(dev);
        var image = try shader.Pipeline.init(gpa, dev, shaders.image(), shaders.text_layout);
        errdefer image.deinit(dev);
        const frame = try gpa.create(render.Frame);
        return .{ .dev = dev, .gpu = gpu, .gpa = gpa, .shape = shape, .solid = solid, .@"opaque" = opaque_solid, .text = text, .image = image, .frame = frame, .border = .init(gpa) };
    }

    pub fn deinit(r: *Renderer) void {
        r.shape.deinit(r.dev);
        r.solid.deinit(r.dev);
        r.@"opaque".deinit(r.dev);
        r.text.deinit(r.dev);
        r.image.deinit(r.dev);
        var it = r.images.valueIterator();
        while (it.next()) |t| r.dev.destroyBo(t.bo);
        r.images.deinit(r.gpa);
        if (r.vbo) |bo| r.dev.destroyBo(bo);
        if (r.other_vbo) |bo| r.dev.destroyBo(bo);
        if (r.atlas_bo) |bo| r.dev.destroyBo(bo);
        if (r.other_atlas_bo) |bo| r.dev.destroyBo(bo);
        r.gpa.destroy(r.frame);
        r.border.deinit();
    }

    pub fn renderer(r: *Renderer) kgfx.Renderer {
        return .of(r);
    }

    /// Leaves frames with the GPU (see above), if it can say when they are
    /// done; true if it now does.
    pub fn setPipelined(r: *Renderer, on: bool) bool {
        r.pipelined = on and r.gpu.vtable.submit != null and r.gpu.vtable.wait != null;
        return r.pipelined;
    }

    /// Makes room for the canvases a frame draws, and uploads the glyphs
    /// their text added to the atlas, and their images. The previous frame
    /// must have finished rendering, unless `pipelined`.
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

    /// Gives each image drawn a texture (uploaded again when its pixels
    /// change), and frees those of images no longer drawn (or reuses their
    /// buffers for new images of the same size).
    fn uploadImages(r: *Renderer, canvases: []const *const Canvas) !void {
        var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer used.deinit(r.gpa);
        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            try used.put(r.gpa, img.id, {});
        };
        var stale_ids: std.ArrayList(u64) = .empty;
        defer stale_ids.deinit(r.gpa);
        var it = r.images.iterator();
        while (it.next()) |e| if (!used.contains(e.key_ptr.*)) try stale_ids.append(r.gpa, e.key_ptr.*);
        var stale: std.ArrayList(vc4.Bo) = .empty;
        defer {
            for (stale.items) |bo| r.dev.destroyBo(bo);
            stale.deinit(r.gpa);
        }
        try stale.ensureTotalCapacity(r.gpa, stale_ids.items.len);
        for (stale_ids.items) |id| stale.appendAssumeCapacity(r.images.fetchRemove(id).?.value.bo);

        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            if (r.images.getPtr(img.id)) |t| {
                if (t.version == img.version) continue;
                // Its pixels changed in place: the same texture, again; or,
                // with a frame in flight that may be drawing it, another
                // (the kernel keeps the old one until it is done).
                if (r.pipelined) {
                    const bo = try r.dev.createBo(t.bo.map.len);
                    r.dev.destroyBo(t.bo);
                    t.bo = bo;
                }
                vc4.texture.upload(t.bo.map, img.pixels, img.width, img.height);
                t.version = img.version;
                continue;
            }
            const size = vc4.texture.imageSize(img.width, img.height);
            const bo = r.takeStaleBo(&stale, size) orelse try r.dev.createBo(size);
            errdefer r.dev.destroyBo(bo);
            vc4.texture.upload(bo.map, img.pixels, img.width, img.height);
            try r.images.put(r.gpa, img.id, .{ .bo = bo, .version = img.version });
        };
    }

    /// A buffer of an image no longer drawn, for a new one the same size
    /// (not with a frame in flight, which may still be drawing it).
    fn takeStaleBo(r: *const Renderer, stale: *std.ArrayList(vc4.Bo), size: u32) ?vc4.Bo {
        if (r.pipelined) return null;
        for (stale.items, 0..) |bo, i| {
            if (bo.map.len == size) return stale.swapRemove(i);
        }
        return null;
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

    /// Records a canvas (one of those given to `prepare`) into `frame`
    /// (kete's `Renderer.record`). The frame's `damage` is set with
    /// `render.Frame.limitTo` by whoever began it.
    pub fn record(r: *Renderer, c: *const Canvas, frame: *render.Frame, damage: ?[]const kgfx.Viewport) !void {
        _ = damage;
        try r.recordCanvas(c, frame);
    }

    /// `v` (laid out at the window's size) in the buffer being drawn.
    pub fn scaled(r: *const Renderer, v: kgfx.Viewport) render.Viewport {
        return scaledViewport(v, r.scale);
    }

    /// Records a canvas into `frame`, leaving out batches outside the parts
    /// being rendered (see `render.Frame.limitTo`). When the frame fills
    /// up, it is rendered and drawing goes on.
    fn recordCanvas(r: *Renderer, c: *const Canvas, frame: *render.Frame) !void {
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            if (!frame.covers(scissor(area, r.scale))) continue;
            const vbo = r.vbo orelse return error.NotPrepared;
            if (!frame.hasRoom(max_uniform_words)) {
                try r.gpu.vtable.run(r.gpu.ptr, frame);
                frame.again();
            }
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
                        // Drawn smaller, smoothly.
                        .mag_filter = if (r.scale < 1) .linear else .nearest,
                        .min_filter = if (r.scale < 1) .linear else .nearest,
                        .wrap_s = .clamp,
                        .wrap_t = .clamp,
                    },
                },
                // Scaled smoothly, unless the image says not to.
                .image => blk: {
                    const img = b.image orelse continue;
                    const t = r.images.get(img.id) orelse return error.NotPrepared;
                    var config: vc4.texture.Config = .{ .width = img.width, .height = img.height, .wrap_s = .clamp, .wrap_t = .clamp };
                    if (img.nearest) {
                        config.mag_filter = .nearest;
                        config.min_filter = .nearest;
                    }
                    break :blk .{ .handle = t.bo.handle, .config = config };
                },
                else => null,
            };
            try p.draw(frame, .{
                .vertices = vbo.handle,
                .vertex_offset = offset,
                .count = b.vertexCount(),
                .texture = texture,
                .scissor = if (b.clip) |clip| scissor(clip, r.scale) else null,
            });
        }
    }

    /// Draws a frame's segments straight into the window's buffer (see
    /// `window.zig`), only in the tiles `damage` touches, and waits for
    /// the GPU to finish it. The tiles drawn are cleared first, whole, so
    /// `clear_rects` (the parts nothing opaque covers) are cleared too.
    pub fn renderDmabuf(
        r: *Renderer,
        canvases: []const *const Canvas,
        segments: []const kgfx.Segment,
        target: *const kgfx.DmabufTarget,
        clear: u32,
        clear_rects: []const kgfx.Viewport,
        damage: []const kgfx.Viewport,
    ) !void {
        _ = clear_rects;
        const started = sys.nowNs();
        const frame = r.frame;
        if (r.multisampled) frame.beginMultisampled(try targetOf(target), clear) else frame.begin(try targetOf(target), .{ .clear = clear });
        var vps: [kgfx.frame.Damage.max_rects]render.Viewport = undefined;
        const n = @min(damage.len, vps.len);
        for (damage[0..n], vps[0..n]) |d, *v| v.* = viewport(d);
        // More than it can say, or drawn smaller: all of it.
        frame.limitTo(if (n == damage.len and r.scale == 1) vps[0..n] else null);
        // The window's border, over what it shows.
        const outlined = r.outline and target.width > 2 and target.height > 2;
        r.outline = false;
        if (outlined) {
            const w: f32 = @floatFromInt(target.width);
            const h: f32 = @floatFromInt(target.height);
            r.border.begin(target.width, target.height);
            r.border.fillRect(.{ .x = 0, .y = 0, .w = w, .h = 1 }, r.border_color);
            r.border.fillRect(.{ .x = 0, .y = h - 1, .w = w, .h = 1 }, r.border_color);
            r.border.fillRect(.{ .x = 0, .y = 1, .w = 1, .h = h - 2 }, r.border_color);
            r.border.fillRect(.{ .x = w - 1, .y = 1, .w = 1, .h = h - 2 }, r.border_color);
        }
        const all = try r.gpa.alloc(*const Canvas, canvases.len + 1);
        defer r.gpa.free(all);
        @memcpy(all[0..canvases.len], canvases);
        all[canvases.len] = &r.border;
        try r.prepare(if (outlined) all else canvases);
        for (segments) |s| switch (s) {
            .canvas => |c| try r.recordCanvas(c, frame),
            .gpu => |g| if (frame.covers(r.scaled(g.area.scissor orelse g.area.viewport))) try g.f(g.ctx, frame, g.area),
        };
        if (outlined) try r.recordCanvas(&r.border, frame);
        const issued = sys.nowNs();
        if (r.pipelined) {
            r.pending = try r.gpu.vtable.submit.?(r.gpu.ptr, frame);
        } else try r.gpu.vtable.run(r.gpu.ptr, frame);
        r.stats.frames += 1;
        r.stats.cpu_ns += issued - started;
        r.stats.gpu_ns += sys.nowNs() - issued;
        if (n == damage.len) {
            for (damage) |d| r.stats.pixels += @as(f64, @floatFromInt(d.width)) * @as(f64, @floatFromInt(d.height));
        } else r.stats.pixels += @as(f64, @floatFromInt(target.width)) * @as(f64, @floatFromInt(target.height));
    }

    /// What drawing took since the last call.
    pub fn takeStats(r: *Renderer) Stats {
        defer r.stats = .{};
        return r.stats;
    }
};

/// The vc4 render target a window's buffer is (see `window.zig`).
fn targetOf(t: *const kgfx.DmabufTarget) !render.Target {
    const format = vc4.Format.fromFourcc(t.fourcc) orelse return error.UnsupportedFormat;
    return .{
        .handle = @intCast(t.id),
        .width = @intCast(t.width),
        .height = @intCast(t.height),
        .tiling = if (t.modifier == tiled_modifier) render.Target.textureTiling(format, t.width, t.height) else .linear,
        .format = format,
    };
}

pub fn viewport(v: kgfx.Viewport) render.Viewport {
    return .{ .x = v.x, .y = v.y, .width = v.width, .height = v.height };
}

/// `v` (laid out at the window's size) in the window's buffer, if that is
/// smaller (`scale`).
pub fn scaledViewport(v: kgfx.Viewport, scale: f32) render.Viewport {
    if (scale == 1) return viewport(v);
    const x0 = @round(@as(f32, @floatFromInt(v.x)) * scale);
    const y0 = @round(@as(f32, @floatFromInt(v.y)) * scale);
    const x1 = @round(@as(f32, @floatFromInt(v.x + @as(i32, @intCast(v.width)))) * scale);
    const y1 = @round(@as(f32, @floatFromInt(v.y + @as(i32, @intCast(v.height)))) * scale);
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .width = @intFromFloat(@max(x1 - x0, 0)), .height = @intFromFloat(@max(y1 - y0, 0)) };
}

/// More than any of the canvas shaders' draws uses.
const max_uniform_words = 256;

fn scissor(clip: kgfx.Rect, scale: f32) render.Viewport {
    const x0 = @floor(@max(clip.x * scale, 0));
    const y0 = @floor(@max(clip.y * scale, 0));
    const x1 = @max(@ceil((clip.x + clip.w) * scale), x0);
    const y1 = @max(@ceil((clip.y + clip.h) * scale), y0);
    return .{ .x = @intFromFloat(@min(x0, 1e6)), .y = @intFromFloat(@min(y0, 1e6)), .width = @intFromFloat(@min(x1 - x0, 1e6)), .height = @intFromFloat(@min(y1 - y0, 1e6)) };
}
