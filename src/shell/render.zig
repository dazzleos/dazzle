//! The shell's renderer, on the low-level vc4 API: each frame is one GPU
//! job that clears the screen and draws the bar and the top window as
//! textured quads, then is shown with a page flip.
//!
//! Window contents are textures: clients' dma-bufs used in place (they
//! render in the GPU's T-tiled layout, which the texture unit reads), or
//! copies of shared-memory buffers. The quad shader is shaders/quad.zig.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");
const font = @import("font");
const server = @import("server.zig");
const cursor = @import("cursor.zig");

const shader = @import("shader");

const render = vc4.render;
const texture = vc4.texture;

pub const background = 0xff101830;
const bar_background = 0xff1c2a4a;

/// Frames are large; the shell has one.
var static_frame: render.Frame = undefined;

pub const Window = struct {
    texture: server.Texture,
    /// Where its top left goes, and the area it is clipped to.
    x: i32,
    y: i32,
    clip: server.Rect,
};

/// Records a frame (after `frame.begin`): the bar and the window as quads.
/// `vbo` holds the quads' vertices and must stay untouched until the frame
/// has rendered.
pub fn recordFrame(frame: *render.Frame, quads_pipeline: *shader.Pipeline, vbo: vc4.Bo, bar: ?server.Texture, window: ?Window) !void {
    var quads: usize = 0;
    if (bar) |b| {
        try quad(frame, quads_pipeline, vbo, quads, b, 0, 0, null);
        quads += 1;
    }
    if (window) |w| {
        try quad(frame, quads_pipeline, vbo, quads, w.texture, w.x, w.y, .{ .x = w.clip.x, .y = w.clip.y, .width = w.clip.width, .height = w.clip.height });
        quads += 1;
    }
}

/// Draws a texture 1:1 with its top left at (x, y).
fn quad(frame: *render.Frame, pipeline: *shader.Pipeline, vbo: vc4.Bo, index: usize, t: server.Texture, x: i32, y: i32, scissor: ?render.Viewport) !void {
    // Two triangles, in clip space, with texture coordinates.
    const w: f32 = @floatFromInt(frame.target.width);
    const h: f32 = @floatFromInt(frame.target.height);
    const x0 = @as(f32, @floatFromInt(x)) / w * 2 - 1;
    const x1 = @as(f32, @floatFromInt(x + @as(i32, @intCast(t.width)))) / w * 2 - 1;
    const y0 = 1 - @as(f32, @floatFromInt(y)) / h * 2;
    const y1 = 1 - @as(f32, @floatFromInt(y + @as(i32, @intCast(t.height)))) / h * 2;
    const verts = [6][4]f32{
        .{ x0, y0, 0, 0 }, .{ x0, y1, 0, 1 }, .{ x1, y0, 1, 0 },
        .{ x1, y0, 1, 0 }, .{ x0, y1, 0, 1 }, .{ x1, y1, 1, 1 },
    };
    const offset: u32 = @intCast(index * @sizeOf(@TypeOf(verts)));
    @memcpy(vbo.map[offset..][0..@sizeOf(@TypeOf(verts))], std.mem.asBytes(&verts));
    try pipeline.draw(frame, .{
        .vertices = vbo.handle,
        .vertex_offset = offset,
        .count = 6,
        .scissor = scissor,
        .texture = .{ .handle = t.handle, .config = .{
            .width = t.width,
            .height = t.height,
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .wrap_s = .clamp,
            .wrap_t = .clamp,
        } },
    });
}

/// A buffer the display can show.
const Scanout = struct { bo: vc4.Bo, fb_id: u32 };

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    dev: vc4.Device,
    display: vc4.display.Display,
    width: u32,
    height: u32,
    /// Draws textures as quads.
    quads: shader.Pipeline,
    /// Vertices for this frame's quads.
    vbo: vc4.Bo,
    /// Buffers backing the textures the renderer allocated (shm copies), by
    /// GEM handle. Imported dma-bufs have only a handle.
    owned: std.AutoHashMapUnmanaged(u32, vc4.Bo) = .empty,
    bar: ?server.Texture = null,
    /// The bar's pixels, for showing it on an overlay plane above a
    /// window's buffer; copied into `bar_planes` when needed.
    bar_pixels: []const u32 = &.{},
    bar_size: [2]u32 = .{ 0, 0 },
    bar_dirty: bool = false,
    /// `bar` does not have the latest picture yet.
    bar_texture_stale: bool = false,
    /// Two linear buffers for the bar's overlay, so one can be written
    /// while the other is on the screen.
    bar_planes: [2]?Scanout = .{ null, null },
    bar_shown: u1 = 0,
    /// Framebuffers for clients' buffers shown directly, by GEM handle
    /// (null if the display cannot show that buffer).
    client_fbs: std.AutoHashMapUnmanaged(u32, ?u32) = .empty,
    /// The cursor's picture, once it is shown.
    cursor_bo: ?vc4.Bo = null,
    cursor_move_failed: bool = false,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device, output: vc4.drm.Output) !Renderer {
        const display = try vc4.display.Display.init(dev, output);
        return .{
            .gpa = gpa,
            .dev = dev,
            .display = display,
            .width = display.width,
            .height = display.height,
            .quads = try shader.Pipeline.init(gpa, dev, shader.Program.decode(@embedFile("quad.shader")) catch unreachable, .{
                .vertex_stride = 16,
                .attributes = &.{ .{ .location = 0, .offset = 0 }, .{ .location = 1, .offset = 8 } },
            }),
            .vbo = try dev.createBo(4096),
        };
    }

    pub fn backend(r: *Renderer) server.Backend {
        return .{ .ptr = r, .vtable = &.{
            .importDmabuf = importDmabuf,
            .uploadPixels = uploadPixels,
            .destroyTexture = destroyTexture,
        } };
    }

    fn importDmabuf(ptr: *anyopaque, fd: linux.fd_t, width: u32, height: u32) anyerror!server.Texture {
        const r: *Renderer = @ptrCast(@alignCast(ptr));
        defer sys.close(fd);
        const handle = try vc4.drm.importBuffer(r.dev.fd, fd);
        return .{ .handle = handle, .width = width, .height = height };
    }

    fn uploadPixels(ptr: *anyopaque, existing: ?server.Texture, pixels: []const u8, width: u32, height: u32, stride: u32) anyerror!server.Texture {
        const r: *Renderer = @ptrCast(@alignCast(ptr));
        var t = existing orelse server.Texture{ .handle = 0, .width = 0, .height = 0 };
        if (existing == null or t.width != width or t.height != height) {
            const bo = try r.dev.createBo(texture.imageSize(width, height));
            errdefer r.dev.destroyBo(bo);
            try r.owned.put(r.gpa, bo.handle, bo);
            t = .{ .handle = bo.handle, .width = width, .height = height };
        }
        const bo = r.owned.get(t.handle).?;
        // 32-bit pixels are already in the texture unit's byte order, and
        // rows are a whole number of pixels apart.
        const words = std.mem.bytesAsSlice(u32, pixels[0 .. pixels.len / 4 * 4]);
        texture.uploadRect(bo.map, width, height, .{ .x = 0, .y = 0, .width = width, .height = height }, @alignCast(words), stride / 4);
        return t;
    }

    fn destroyTexture(ptr: *anyopaque, t: server.Texture) void {
        const r: *Renderer = @ptrCast(@alignCast(ptr));
        if (r.client_fbs.fetchRemove(t.handle)) |kv| if (kv.value) |fb| vc4.drm.removeFramebuffer(r.dev.fd, fb);
        if (r.owned.fetchRemove(t.handle)) |kv| {
            r.dev.destroyBo(kv.value);
        } else {
            vc4.drm.gemClose(r.dev.fd, t.handle);
        }
    }

    /// Replaces the bar's picture.
    /// Replaces the bar's picture. It is copied where it is needed when a
    /// frame is drawn: into the overlay plane's buffer, or (when the frame
    /// is composited) a texture.
    pub fn setBar(r: *Renderer, pixels: []const u32, width: u32, height: u32) void {
        r.bar_pixels = pixels;
        r.bar_size = .{ width, height };
        r.bar_dirty = true;
        r.bar_texture_stale = true;
    }

    /// Shows a client's buffer directly on the display's primary plane at
    /// (`x`, `y`), with the bar on an overlay plane above it, so nothing
    /// is composited. Returns null if the display cannot (the buffer is not
    /// T-tiled, or the planes are not available), and the frame must be
    /// composited instead; otherwise whether it is already on the screen,
    /// as `show` does. Only while no flip is pending.
    pub fn showDirect(r: *Renderer, t: server.Texture, x: i32, y: i32) ?bool {
        if (r.display.kms == null) return null;
        if (vc4.render.Target.textureTiling(t.width, t.height) != .t) return null;
        const bar = r.barLayer();
        const fb = r.clientFramebuffer(t, x, y, bar) orelse return null;
        return r.display.queueLayers(windowLayer(fb, t, x, y), bar) catch |err| {
            sys.print("stardust-shell: cannot show the window directly: {s}\n", .{@errorName(err)});
            return null;
        };
    }

    fn windowLayer(fb: u32, t: server.Texture, x: i32, y: i32) vc4.kms.Layer {
        return .{ .fb_id = fb, .src_width = t.width, .src_height = t.height, .x = x, .y = y, .width = t.width, .height = t.height };
    }

    /// A framebuffer for a client's buffer, made (and checked with the
    /// display, with the window at `x`, `y` under `bar`) the first time it
    /// is shown.
    fn clientFramebuffer(r: *Renderer, t: server.Texture, x: i32, y: i32, bar: ?vc4.kms.Layer) ?u32 {
        if (r.client_fbs.get(t.handle)) |fb| return fb;
        // T-tiled images are padded to 32-pixel-wide columns of tiles.
        const pitch = std.mem.alignForward(u32, t.width, 32) * 4;
        var fb: ?u32 = vc4.drm.addFramebufferWithModifier(r.dev.fd, t.handle, t.width, t.height, pitch, vc4.drm.format_xrgb8888, vc4.kms.modifier_t_tiled) catch |err| blk: {
            sys.print("stardust-shell: no framebuffer for a {d}x{d} window: {s}\n", .{ t.width, t.height, @errorName(err) });
            break :blk null;
        };
        if (fb) |id| if (!r.display.canShow(windowLayer(id, t, x, y), bar)) {
            sys.print("stardust-shell: the display cannot show a {d}x{d} window directly\n", .{ t.width, t.height });
            vc4.drm.removeFramebuffer(r.dev.fd, id);
            fb = null;
        };
        r.client_fbs.put(r.gpa, t.handle, fb) catch {
            if (fb) |id| vc4.drm.removeFramebuffer(r.dev.fd, id);
            return null;
        };
        return fb;
    }

    /// The bar as an overlay layer, writing its latest pixels into the
    /// overlay buffer that is not on the screen.
    fn barLayer(r: *Renderer) ?vc4.kms.Layer {
        const w = r.bar_size[0];
        const h = r.bar_size[1];
        if (w == 0 or h == 0) return null;
        if (r.bar_dirty) {
            const next = r.bar_shown +% 1;
            const plane = r.barPlane(next) orelse return null;
            @memcpy(std.mem.bytesAsSlice(u32, plane.bo.map[0 .. w * h * 4]), r.bar_pixels[0 .. w * h]);
            r.bar_shown = next;
            r.bar_dirty = false;
        }
        const plane = r.barPlane(r.bar_shown) orelse return null;
        return .{ .fb_id = plane.fb_id, .src_width = w, .src_height = h, .x = 0, .y = 0, .width = w, .height = h };
    }

    fn barPlane(r: *Renderer, i: u1) ?Scanout {
        if (r.bar_planes[i]) |p| return p;
        const w = r.bar_size[0];
        const h = r.bar_size[1];
        const bo = r.dev.createBo(w * h * 4) catch return null;
        const fb = vc4.drm.addFramebuffer(r.dev.fd, bo.handle, w, h, w * 4, vc4.drm.format_xrgb8888) catch {
            r.dev.destroyBo(bo);
            return null;
        };
        // The first one shown starts with the current bar.
        @memcpy(std.mem.bytesAsSlice(u32, bo.map[0 .. w * h * 4]), r.bar_pixels[0 .. w * h]);
        r.bar_planes[i] = .{ .bo = bo, .fb_id = fb };
        return r.bar_planes[i];
    }

    /// Shows the pointer's arrow on the display's cursor plane, once the
    /// first frame has set the mode.
    pub fn showCursor(r: *Renderer) !void {
        const bytes = cursor.size * cursor.size * 4;
        const bo = try r.dev.createBo(bytes);
        errdefer r.dev.destroyBo(bo);
        cursor.draw(std.mem.bytesAsValue([cursor.size * cursor.size]u32, bo.map[0..bytes]));
        try vc4.drm.setCursor(r.dev.fd, r.display.output.crtc_id, bo.handle, cursor.size, cursor.size);
        r.cursor_bo = bo;
    }

    /// Moves the arrow's tip to (`x`, `y`) on the screen.
    pub fn moveCursor(r: *Renderer, x: i32, y: i32) void {
        if (r.cursor_bo == null) return;
        vc4.drm.moveCursor(r.dev.fd, r.display.output.crtc_id, x - cursor.hotspot[0], y - cursor.hotspot[1]) catch |err| {
            if (!r.cursor_move_failed) sys.print("stardust-shell: cannot move the cursor: {s}\n", .{@errorName(err)});
            r.cursor_move_failed = true;
        };
    }

    /// How long composing a frame took.
    pub const Timing = struct {
        /// Recording the GPU job.
        cpu_ns: u64,
        /// From submitting the job to the GPU finishing it.
        gpu_ns: u64,
    };

    /// Composites a frame into the back buffer, waiting for the GPU. Only
    /// while no flip is pending (`flipPending`).
    pub fn composite(r: *Renderer, window: ?Window) !Timing {
        const t0 = sys.nowNs();
        if (r.bar_texture_stale) {
            r.bar = try uploadPixels(r, r.bar, std.mem.sliceAsBytes(r.bar_pixels), r.bar_size[0], r.bar_size[1], r.bar_size[0] * 4);
            r.bar_texture_stale = false;
        }
        static_frame.begin(r.display.backTarget(), .{ .clear = background });
        try recordFrame(&static_frame, &r.quads, r.vbo, r.bar, window);
        const t1 = sys.nowNs();
        const seqno = try r.dev.submit(static_frame.finish());
        try r.dev.waitSeqno(seqno, std.time.ns_per_s);
        return .{ .cpu_ns = t1 - t0, .gpu_ns = sys.nowNs() - t1 };
    }

    /// Shows the composited frame at the next vertical blank, without
    /// waiting. Returns true if it is already on the screen (the first
    /// frame, which sets the mode); otherwise `handleEvents` reports it.
    pub fn show(r: *Renderer) !bool {
        return r.display.queue();
    }

    pub fn flipPending(r: *const Renderer) bool {
        return r.display.flip_pending;
    }

    /// Handles the display's events; call when its file is readable.
    /// Returns the vertical blank time (microseconds) of a completed flip.
    pub fn handleEvents(r: *Renderer) !?u64 {
        return r.display.handleEvents();
    }
};

/// The bar across the top of the screen: "Stardust", the window title and
/// the time since boot.
pub const Bar = struct {
    font: font.Font,
    cache: font.GlyphCache,
    pixels: []u32,
    width: u32,
    height: u32,
    scale: f32,

    pub fn init(gpa: std.mem.Allocator, f: font.Font, screen_width: u32, screen_height: u32) !Bar {
        const scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        const height: u32 = @intFromFloat(@round(44 * scale));
        return .{
            .font = f,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, @as(usize, screen_width) * height),
            .width = screen_width,
            .height = height,
            .scale = scale,
        };
    }

    pub fn draw(b: *Bar, title: []const u8, uptime_s: u64) !void {
        const canvas: font.Canvas = .{ .pixels = b.pixels, .width = b.width, .height = b.height, .stride = b.width };
        canvas.fill(0, 0, b.width, b.height, bar_background);
        const s = b.scale;
        const baseline = 30 * s;
        const style: font.Style = .{ .font = &b.font, .size = 24 * s, .color = 0xffffffff };
        _ = try font.draw(canvas, &b.cache, style, 20 * s, baseline, "Stardust");
        const dim: font.Style = .{ .font = &b.font, .size = 22 * s, .color = 0xffb8c4dc };
        const w: f32 = @floatFromInt(b.width);
        _ = try font.draw(canvas, &b.cache, dim, (w - font.measure(dim, title)) / 2, baseline, title);
        var buf: [32]u8 = undefined;
        const clock = std.fmt.bufPrint(&buf, "up {d}:{d:0>2}:{d:0>2}", .{ uptime_s / 3600, uptime_s / 60 % 60, uptime_s % 60 }) catch "";
        _ = try font.draw(canvas, &b.cache, dim, w - font.measure(dim, clock) - 20 * s, baseline, clock);
    }
};
