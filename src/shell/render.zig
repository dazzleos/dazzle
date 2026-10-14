//! The shell's renderer, on the low-level vc4 API: each frame is one GPU
//! job that clears the screen and draws the panels (the dock) and the top
//! window as textured quads, then is shown with a page flip. A window the
//! size of the work area is shown directly instead, with the panels on
//! overlay planes; a fullscreen window the size of the screen alone, on
//! the display's primary plane.
//!
//! Window contents are textures: clients' dma-bufs used in place (they
//! render in the GPU's T-tiled layout, which the texture unit reads), or
//! copies of shared-memory buffers, in 32-bit or RGB565 pixels. The quad
//! shader is shaders/quad.zig.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");
const server = @import("server.zig");
const cursor = @import("cursor.zig");

const shader = @import("shader");

const render = vc4.render;
const texture = vc4.texture;

pub const background = 0xff101830;

/// Frames are large; the shell has one (and one for screenshots).
var static_frame: render.Frame = undefined;
var capture_frame: render.Frame = undefined;

pub const Window = struct {
    texture: server.Texture,
    /// Where its top left goes, its logical size (0 = texture size),
    /// buffer transform, and the area it is clipped to.
    x: i32,
    y: i32,
    width: u32 = 0,
    height: u32 = 0,
    transform: u3 = 0,
    clip: server.Rect,
};

/// The most surfaces a frame draws (windows, their subsurfaces and popups:
/// the vertex buffer holds this many quads besides the panels').
pub const max_windows = 48;

/// A panel's picture, drawn at (`x`, `y`) on the screen.
pub const PanelQuad = struct { texture: server.Texture, x: i32 = 0, y: i32 };

/// Records a frame (after `frame.begin`): the windows (bottom first, at
/// most `max_windows`) and the panels above them as quads. `vbo` holds the
/// quads' vertices and must stay untouched until the frame has rendered.
pub fn recordFrame(frame: *render.Frame, pipeline: *shader.Pipeline, vbo: vc4.Bo, panels: []const ?PanelQuad, windows: []const Window) !void {
    std.debug.assert(windows.len <= max_windows);
    var quads: usize = 0;
    for (windows) |w| {
        const qw = if (w.width != 0) w.width else w.texture.width;
        const qh = if (w.height != 0) w.height else w.texture.height;
        try quad(frame, pipeline, vbo, quads, w.texture, w.x, w.y, qw, qh, w.transform, .{ .x = w.clip.x, .y = w.clip.y, .width = w.clip.width, .height = w.clip.height });
        quads += 1;
    }
    for (panels) |panel| if (panel) |pq| {
        try quad(frame, pipeline, vbo, quads, pq.texture, pq.x, pq.y, pq.texture.width, pq.texture.height, 0, null);
        quads += 1;
    };
}

fn quadUvs(transform: u3) [4][2]f32 {
    const rot: [4][2]f32 = switch (@as(u2, @truncate(transform))) {
        0 => .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } },
        1 => .{ .{ 1, 0 }, .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 } },
        2 => .{ .{ 1, 1 }, .{ 1, 0 }, .{ 0, 1 }, .{ 0, 0 } },
        3 => .{ .{ 0, 1 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 0 } },
    };
    if (transform & 4 == 0) return rot;
    return .{ rot[2], rot[3], rot[0], rot[1] };
}

/// Draws a texture with its top left at (x, y) and logical size (qw, qh).
fn quad(frame: *render.Frame, pipeline: *shader.Pipeline, vbo: vc4.Bo, index: usize, t: server.Texture, x: i32, y: i32, qw: u32, qh: u32, transform: u3, scissor: ?render.Viewport) !void {
    // Two triangles, in clip space, with texture coordinates.
    const w: f32 = @floatFromInt(frame.target.width);
    const h: f32 = @floatFromInt(frame.target.height);
    const x0 = @as(f32, @floatFromInt(x)) / w * 2 - 1;
    const x1 = @as(f32, @floatFromInt(x + @as(i32, @intCast(qw)))) / w * 2 - 1;
    const y0 = 1 - @as(f32, @floatFromInt(y)) / h * 2;
    const y1 = 1 - @as(f32, @floatFromInt(y + @as(i32, @intCast(qh)))) / h * 2;
    const uv = quadUvs(transform);
    const verts = [6][4]f32{
        .{ x0, y0, uv[0][0], uv[0][1] }, .{ x0, y1, uv[1][0], uv[1][1] }, .{ x1, y0, uv[2][0], uv[2][1] },
        .{ x1, y0, uv[2][0], uv[2][1] }, .{ x0, y1, uv[1][0], uv[1][1] }, .{ x1, y1, uv[3][0], uv[3][1] },
    };
    const offset: u32 = @intCast(index * @sizeOf(@TypeOf(verts)));
    @memcpy(vbo.map[offset..][0..@sizeOf(@TypeOf(verts))], std.mem.asBytes(&verts));
    try pipeline.draw(frame, .{
        .vertices = vbo.handle,
        .vertex_offset = offset,
        .count = 6,
        .scissor = scissor,
        .texture = .{ .handle = t.handle, .config = .{
            .type = t.format.textureType(),
            .width = t.width,
            .height = t.height,
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .wrap_s = .clamp,
            .wrap_t = .clamp,
        } },
    });
}

/// Room for the panels' and windows' quads (each two triangles of four
/// floats per vertex).
const vbo_size = 8192;
comptime {
    std.debug.assert((n_panels + max_windows) * 6 * 4 * @sizeOf(f32) <= vbo_size);
}

/// A buffer the display can show.
const Scanout = struct { bo: vc4.Bo, fb_id: u32 };

/// The shell's own panels on the screen, drawn on the CPU.
pub const PanelId = enum { dock, perf };
const n_panels = @typeInfo(PanelId).@"enum".fields.len;

/// A panel's picture, copied where it is needed when a frame is drawn: into
/// an overlay plane's buffer above a window shown directly, or (when the
/// frame is composited) a texture.
const Panel = struct {
    pixels: []const u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    texture: ?server.Texture = null,
    /// `texture` does not have the latest picture yet.
    texture_stale: bool = false,
    /// The overlay buffer on the screen does not have it yet.
    dirty: bool = false,
    /// Two linear buffers for the overlay, so one can be written while the
    /// other is on the screen.
    planes: [2]?Scanout = .{ null, null },
    shown: u1 = 0,
    /// Not shown (under a fullscreen window, or toggled off).
    hidden: bool = false,
};

const n_cursors = @typeInfo(cursor.Shape).@"enum".fields.len;

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
    panels: [n_panels]Panel = @splat(.{}),
    /// Framebuffers for clients' buffers shown directly, by GEM handle
    /// (null if the display cannot show that buffer).
    client_fbs: std.AutoHashMapUnmanaged(u32, ?u32) = .empty,
    /// The cursor's pictures, made when first shown, and the one shown.
    cursor_bos: [n_cursors]?vc4.Bo = @splat(null),
    cursor_shape: ?cursor.Shape = null,
    cursor_move_failed: bool = false,
    background: u32 = background,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device, output: vc4.drm.Output) !Renderer {
        // The screen stays 32-bit: it is what everything is composited
        // into, and screenshots are taken from.
        const display = try vc4.display.Display.init(dev, output, .xrgb8888);
        const layout: shader.pipeline.Options = .{
            .vertex_stride = 16,
            .attributes = &.{ .{ .location = 0, .offset = 0 }, .{ .location = 1, .offset = 8 } },
        };
        return .{
            .gpa = gpa,
            .dev = dev,
            .display = display,
            .width = display.width,
            .height = display.height,
            .quads = try shader.Pipeline.init(gpa, dev, shader.Program.decode(@embedFile("quad.shader")) catch unreachable, layout),
            .vbo = try dev.createBo(vbo_size),
        };
    }

    pub fn backend(r: *Renderer) server.Backend {
        return .{ .ptr = r, .vtable = &.{
            .importDmabuf = importDmabuf,
            .uploadPixels = uploadPixels,
            .destroyTexture = destroyTexture,
        } };
    }

    fn importDmabuf(ptr: *anyopaque, fd: linux.fd_t, width: u32, height: u32, format: vc4.Format) anyerror!server.Texture {
        const r: *Renderer = @ptrCast(@alignCast(ptr));
        defer sys.close(fd);
        const handle = try r.dev.importBuffer(fd);
        return .{ .handle = handle, .width = width, .height = height, .format = format };
    }

    fn uploadPixels(ptr: *anyopaque, existing: ?server.Texture, pixels: []const u8, width: u32, height: u32, stride: u32, format: vc4.Format) anyerror!server.Texture {
        const r: *Renderer = @ptrCast(@alignCast(ptr));
        var t = existing orelse server.Texture{ .handle = 0, .width = 0, .height = 0 };
        if (existing == null or t.width != width or t.height != height or t.format != format) {
            const bo = try r.dev.createBo(texture.imageSizeOf(format, width, height));
            errdefer r.dev.destroyBo(bo);
            try r.owned.put(r.gpa, bo.handle, bo);
            t = .{ .handle = bo.handle, .width = width, .height = height, .format = format };
        }
        const bo = r.owned.get(t.handle).?;
        // Pixels are already in the texture unit's byte order.
        texture.uploadRectOf(format, bo.map, width, height, .{ .x = 0, .y = 0, .width = width, .height = height }, pixels, stride);
        return t;
    }

    fn destroyTexture(ptr: *anyopaque, t: server.Texture) void {
        const r: *Renderer = @ptrCast(@alignCast(ptr));
        if (r.client_fbs.fetchRemove(t.handle)) |kv| if (kv.value) |fb| vc4.drm.removeFramebuffer(r.dev.fd, fb);
        if (r.owned.fetchRemove(t.handle)) |kv| {
            r.dev.destroyBo(kv.value);
        } else {
            r.dev.closeHandle(t.handle);
        }
    }

    /// Replaces a panel's picture, `width` by `height` pixels shown with
    /// its top at `y`. The pixels must stay until the next call.
    pub fn setPanel(r: *Renderer, id: PanelId, pixels: []const u32, width: u32, height: u32, y: i32) void {
        r.setPanelAt(id, pixels, width, height, 0, y);
    }

    /// Replaces a panel's picture, `width` by `height` pixels shown with
    /// its top left at (`x`, `y`). The pixels must stay until the next call.
    pub fn setPanelAt(r: *Renderer, id: PanelId, pixels: []const u32, width: u32, height: u32, x: i32, y: i32) void {
        const p = &r.panels[@intFromEnum(id)];
        p.pixels = pixels;
        p.width = width;
        p.height = height;
        p.x = x;
        p.y = y;
        p.dirty = true;
        p.texture_stale = true;
    }

    /// Hides a panel, or shows it again.
    pub fn setPanelHidden(r: *Renderer, id: PanelId, hidden: bool) void {
        r.panels[@intFromEnum(id)].hidden = hidden;
    }

    /// Hides the panels (under a fullscreen window), or shows them again.
    pub fn hidePanels(r: *Renderer, hidden: bool) void {
        for (&r.panels) |*p| p.hidden = hidden;
    }

    fn panelLayers(r: *Renderer) ?vc4.kms.Overlays {
        const kms = r.display.kms orelse return null;
        var out: vc4.kms.Overlays = @splat(null);
        for (&r.panels, 0..) |*p, i| {
            if (p.width == 0 or p.height == 0 or p.hidden) continue;
            if (kms.overlays[i] == null) return null;
            out[i] = r.panelLayer(p) orelse return null;
        }
        return out;
    }

    /// Shows a client's buffer directly on the display's primary plane at
    /// (`x`, `y`), with the panels on overlay planes, so nothing
    /// is composited. Returns null if the display cannot (the buffer is not
    /// T-tiled, or the planes are not available), and the frame must be
    /// composited instead; otherwise whether it is already on the screen,
    /// as `show` does. Only while no flip is pending.
    pub fn showDirect(r: *Renderer, t: server.Texture, x: i32, y: i32) ?bool {
        if (r.dev.is_v3d or r.display.kms == null) return null;
        if (vc4.render.Target.textureTiling(t.format, t.width, t.height) != .t) return null;
        const panels = r.panelLayers() orelse return null;
        const fb = r.clientFramebuffer(t, x, y, panels) orelse return null;
        return r.display.queueLayers(windowLayer(fb, t, x, y), panels) catch |err| {
            sys.print(sys.log_warning ++ "dazzle-shell: cannot show the window directly: {s}\n", .{@errorName(err)});
            return null;
        };
    }

    fn windowLayer(fb: u32, t: server.Texture, x: i32, y: i32) vc4.kms.Layer {
        return .{ .fb_id = fb, .src_width = t.width, .src_height = t.height, .x = x, .y = y, .width = t.width, .height = t.height };
    }

    /// A framebuffer for a client's buffer, made (and checked with the
    /// display, with the window at `x`, `y` under `panels`) the first time
    /// it is shown.
    fn clientFramebuffer(r: *Renderer, t: server.Texture, x: i32, y: i32, panels: vc4.kms.Overlays) ?u32 {
        if (r.client_fbs.get(t.handle)) |fb| return fb;
        // T-tiled images are padded to whole columns of tiles.
        const pitch = texture.tiledPitch(t.format, t.width, t.height);
        var fb: ?u32 = vc4.drm.addFramebufferWithModifier(r.dev.fd, t.handle, t.width, t.height, pitch, t.format.fourcc(), vc4.kms.modifier_t_tiled) catch |err| blk: {
            sys.print(sys.log_warning ++ "dazzle-shell: no framebuffer for a {d}x{d} window: {s}\n", .{ t.width, t.height, @errorName(err) });
            break :blk null;
        };
        if (fb) |id| if (!r.display.canShow(windowLayer(id, t, x, y), panels)) {
            sys.print(sys.log_warning ++ "dazzle-shell: the display cannot show a {d}x{d} window directly\n", .{ t.width, t.height });
            vc4.drm.removeFramebuffer(r.dev.fd, id);
            fb = null;
        };
        r.client_fbs.put(r.gpa, t.handle, fb) catch {
            if (fb) |id| vc4.drm.removeFramebuffer(r.dev.fd, id);
            return null;
        };
        return fb;
    }

    /// A panel as an overlay layer, writing its latest pixels into the
    /// overlay buffer that is not on the screen.
    fn panelLayer(r: *Renderer, p: *Panel) ?vc4.kms.Layer {
        if (p.dirty) {
            const next = p.shown +% 1;
            const plane = r.panelPlane(p, next) orelse return null;
            @memcpy(std.mem.bytesAsSlice(u32, plane.bo.map[0 .. p.width * p.height * 4]), p.pixels[0 .. p.width * p.height]);
            p.shown = next;
            p.dirty = false;
        }
        const plane = r.panelPlane(p, p.shown) orelse return null;
        return .{ .fb_id = plane.fb_id, .src_width = p.width, .src_height = p.height, .x = p.x, .y = p.y, .width = p.width, .height = p.height };
    }

    fn panelPlane(r: *Renderer, p: *Panel, i: u1) ?Scanout {
        if (p.planes[i]) |plane| return plane;
        const bo = r.dev.createBo(p.width * p.height * 4) catch return null;
        const fb = vc4.drm.addFramebuffer(r.dev.fd, bo.kmsHandle(), p.width, p.height, p.width * 4, vc4.drm.format_xrgb8888) catch {
            r.dev.destroyBo(bo);
            return null;
        };
        // The first one shown starts with the current picture.
        @memcpy(std.mem.bytesAsSlice(u32, bo.map[0 .. p.width * p.height * 4]), p.pixels[0 .. p.width * p.height]);
        p.planes[i] = .{ .bo = bo, .fb_id = fb };
        return p.planes[i];
    }

    /// Shows the pointer as `shape` on the display's cursor plane, once the
    /// first frame has set the mode. Move it afterwards (`moveCursor`):
    /// shapes' hotspots differ.
    pub fn showCursor(r: *Renderer, shape: cursor.Shape) !void {
        if (r.cursor_shape == shape) return;
        const slot = &r.cursor_bos[@intFromEnum(shape)];
        if (slot.* == null) {
            const bytes = cursor.size * cursor.size * 4;
            const bo = try r.dev.createBo(bytes);
            cursor.draw(std.mem.bytesAsValue([cursor.size * cursor.size]u32, bo.map[0..bytes]), shape);
            slot.* = bo;
        }
        try vc4.drm.setCursor(r.dev.fd, r.display.output.crtc_id, slot.*.?.kmsHandle(), cursor.size, cursor.size);
        r.cursor_shape = shape;
    }

    /// Moves the pointer's hotspot to (`x`, `y`) on the screen.
    pub fn moveCursor(r: *Renderer, x: i32, y: i32) void {
        const shape = r.cursor_shape orelse return;
        const hot = cursor.hotspot(shape);
        vc4.drm.moveCursor(r.dev.fd, r.display.output.crtc_id, x - hot[0], y - hot[1]) catch |err| {
            if (!r.cursor_move_failed) sys.print(sys.log_warning ++ "dazzle-shell: cannot move the cursor: {s}\n", .{@errorName(err)});
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
    pub fn composite(r: *Renderer, windows: []const Window) !Timing {
        const t0 = sys.nowNs();
        const quads = try r.panelQuads();
        static_frame.begin(r.display.backTarget(), .{ .clear = r.background });
        try recordFrame(&static_frame, &r.quads, r.vbo, &quads, windows);
        const t1 = sys.nowNs();
        const seqno = try r.dev.submit(static_frame.finish());
        try r.dev.waitSeqno(seqno, std.time.ns_per_s);
        return .{ .cpu_ns = t1 - t0, .gpu_ns = sys.nowNs() - t1 };
    }

    /// The panels as textures, with their latest pictures.
    fn panelQuads(r: *Renderer) ![n_panels]?PanelQuad {
        var quads: [n_panels]?PanelQuad = @splat(null);
        for (&r.panels, &quads) |*p, *q| {
            if (p.width == 0 or p.height == 0 or p.hidden) continue;
            if (p.texture_stale) {
                p.texture = try uploadPixels(r, p.texture, std.mem.sliceAsBytes(p.pixels), p.width, p.height, p.width * 4, .xrgb8888);
                p.texture_stale = false;
            }
            q.* = .{ .texture = p.texture.?, .x = p.x, .y = p.y };
        }
        return quads;
    }

    /// What the screen shows (the panels and `windows`, as `composite`
    /// draws them; the cursor is left out), drawn again into a buffer of
    /// its own and read back: `width` by `height` pixels, 0xffRRGGBB, in
    /// `gpa`. Waits for the GPU; only while no frame is being drawn.
    pub fn capture(r: *Renderer, gpa: std.mem.Allocator, windows: []const Window) ![]u32 {
        const quads = try r.panelQuads();
        const pitch = render.Target.pitch(.xrgb8888, @intCast(r.width));
        const bo = try r.dev.createBo(pitch * r.height);
        defer r.dev.destroyBo(bo);
        capture_frame.begin(.{ .handle = bo.handle, .width = @intCast(r.width), .height = @intCast(r.height), .tiling = .linear }, .{ .clear = r.background });
        try recordFrame(&capture_frame, &r.quads, r.vbo, &quads, windows);
        const seqno = try r.dev.submit(capture_frame.finish());
        try r.dev.waitSeqno(seqno, std.time.ns_per_s);
        const pixels = try gpa.alloc(u32, @as(usize, r.width) * r.height);
        for (0..r.height) |y| {
            const row = std.mem.bytesAsSlice(u32, bo.map[y * pitch ..][0 .. r.width * 4]);
            // Windows' buffers need not be opaque where the screen is.
            for (pixels[y * r.width ..][0..r.width], row) |*out, in| out.* = in | 0xff000000;
        }
        return pixels;
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
