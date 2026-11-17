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
//!
//! A rounded window (one whose client asked, with dazzle_decoration_v1)
//! is drawn in pieces: most of it as it is, and its corners blended, cut
//! to its radius, with its shadow in strips around it (shaders/window.zig).
//! It needs no buffer of its own, nor an alpha channel in the client's.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");
const server = @import("server.zig");
const cursor = @import("cursor.zig");

const shader = @import("shader");

const background_mod = @import("background.zig");
const glass = @import("glass.zig");
const kete_panel = @import("kete_panel.zig");

const render = vc4.render;
const texture = vc4.texture;
const etc1 = vc4.etc1;

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
    /// Not a surface: the shaded preview of what a window dragged to an
    /// edge will fill (drawn blended, in `preview_color`).
    preview: bool = false,
    /// The radius of its corners (0: square), and whether it has a shadow,
    /// drawn within `shadow_clip`.
    radius: u16 = 0,
    shadow: bool = false,
    shadow_clip: server.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Less than 1: see-through (a window's old frame, fading out),
    /// without a shadow.
    opacity: f32 = 1,
};

/// A rounded window's shadow: how dark under the window, how far it fades
/// out, and how much lower than the window it is.
pub const shadow_alpha = 0.4;
pub const shadow_blur = 24;
pub const shadow_offset = 6;

/// shaders/window.zig's uniforms.
const RoundedUniforms = extern struct {
    shape: [4]f32,
    shadow: [4]f32,
};

/// The preview's shade: the dark scheme's primary, a third of the way.
pub const preview_color = 0x55d0bcff;

/// The most surfaces a frame draws (windows, their subsurfaces and popups:
/// the vertex buffer holds this many quads besides the panels').
pub const max_windows = 48;

/// A panel's picture, drawn at (`x`, `y`) on the screen (blended, as it
/// is see-through in places): straight, or premultiplied (drawn by the
/// GPU).
pub const PanelQuad = struct { texture: server.Texture, x: i32 = 0, y: i32, premultiplied: bool = false };

/// The programs a frame is drawn with: textures as they are, blended (the
/// snap preview), and rounded windows' corners and shadows.
pub const Pipelines = struct {
    quads: *shader.Pipeline,
    blended: *shader.Pipeline,
    rounded: *shader.Pipeline,
    /// Surfaces with alpha, premultiplied: blended over what is under them.
    premultiplied: *shader.Pipeline,
};

/// Records a frame (after `frame.begin`): the windows (bottom first, at
/// most `max_windows`) and the panels above them as quads. `vbo` holds the
/// quads' vertices and must stay untouched until the frame has rendered.
pub fn recordFrame(frame: *render.Frame, pipelines: Pipelines, preview: server.Texture, image: ?server.Texture, vbo: vc4.Bo, panels: []const ?PanelQuad, windows: []const Window) !void {
    std.debug.assert(windows.len <= max_windows);
    const pipeline = pipelines.quads;
    var quads: usize = 0;
    // The background image, over the colour the frame is cleared to.
    if (image) |bg| {
        try quad(frame, pipeline, vbo, quads, bg, 0, 0, bg.width, bg.height, 0, null);
        quads += 1;
    }
    for (windows) |w| {
        if (w.preview) {
            try quad(frame, pipelines.blended, vbo, quads, preview, w.x, w.y, w.width, w.height, 0, viewportOf(w.clip));
            quads += 1;
            continue;
        }
        const qw = if (w.width != 0) w.width else w.texture.width;
        const qh = if (w.height != 0) w.height else w.texture.height;
        if (w.opacity < 1) {
            try fadingWindow(frame, pipelines.rounded, vbo, quads, w, qw, qh);
            quads += 1;
            continue;
        }
        if (w.radius > 0 and w.transform == 0 and 2 * @as(u32, w.radius) <= @min(qw, qh)) {
            try roundedWindow(frame, pipelines, vbo, &quads, w, qw, qh);
            continue;
        }
        // A surface with alpha (a subsurface over a window, say) is blended;
        // others hide what is under them.
        const p = if (w.texture.format == .argb8888 and !w.texture.compressed) pipelines.premultiplied else pipeline;
        try quad(frame, p, vbo, quads, w.texture, w.x, w.y, qw, qh, w.transform, viewportOf(w.clip));
        quads += 1;
    }
    for (panels) |panel| if (panel) |pq| {
        try quad(frame, if (pq.premultiplied) pipelines.premultiplied else pipelines.blended, vbo, quads, pq.texture, pq.x, pq.y, pq.texture.width, pq.texture.height, 0, null);
        quads += 1;
    };
}

fn viewportOf(r: server.Rect) render.Viewport {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

/// The most quads a window is drawn in: rounded, three pieces of it as it
/// is, four corners, and four strips of shadow.
const max_pieces = 11;

/// A rounded window, `qw` by `qh` on the screen: its middle as it is, its
/// corners cut, and its shadow around it.
fn roundedWindow(frame: *render.Frame, pipelines: Pipelines, vbo: vc4.Bo, quads: *usize, w: Window, qw: u32, qh: u32) !void {
    const fw: f32 = @floatFromInt(qw);
    const fh: f32 = @floatFromInt(qh);
    const radius: i32 = w.radius;
    const ww: i32 = @intCast(qw);
    const wh: i32 = @intCast(qh);
    const uniforms: RoundedUniforms = .{
        .shape = .{ fw / 2, fh / 2, @floatFromInt(radius), 1 },
        .shadow = if (w.shadow) .{ shadow_alpha, shadow_blur, shadow_offset, 0 } else .{ 0, 1, 0, 0 },
    };
    pipelines.rounded.setUniforms(std.mem.asBytes(&uniforms));
    const filter: texture.Filter = if (qw != w.texture.width or qh != w.texture.height) .linear else .nearest;
    const Piece = struct { x: i32, y: i32, w: i32, h: i32 };
    const piece = struct {
        fn draw(f: *render.Frame, pl: *shader.Pipeline, b: vc4.Bo, n: *usize, win: Window, sw: f32, sh: f32, flt: texture.Filter, r: Piece, clip: server.Rect) !void {
            if (r.w <= 0 or r.h <= 0) return;
            // Its texture coordinates, as a part of the window (beyond it,
            // for the shadow).
            const u_0 = @as(f32, @floatFromInt(r.x - win.x)) / sw;
            const u_1 = @as(f32, @floatFromInt(r.x + r.w - win.x)) / sw;
            const v_0 = @as(f32, @floatFromInt(r.y - win.y)) / sh;
            const v_1 = @as(f32, @floatFromInt(r.y + r.h - win.y)) / sh;
            try rect(f, pl, b, n.*, win.texture, r.x, r.y, @intCast(r.w), @intCast(r.h), .{ .{ u_0, v_0 }, .{ u_0, v_1 }, .{ u_1, v_0 }, .{ u_1, v_1 } }, flt, viewportOf(clip));
            n.* += 1;
        }
    }.draw;
    const x = w.x;
    const y = w.y;
    // The shadow, in strips around the window (none under it, where it
    // would not be seen).
    if (w.shadow) {
        const s = shadow_blur + shadow_offset;
        for ([_]Piece{
            .{ .x = x - s, .y = y - s, .w = ww + 2 * s, .h = s },
            .{ .x = x - s, .y = y + wh, .w = ww + 2 * s, .h = s },
            .{ .x = x - s, .y = y, .w = s, .h = wh },
            .{ .x = x + ww, .y = y, .w = s, .h = wh },
        }) |r| try piece(frame, pipelines.rounded, vbo, quads, w, fw, fh, filter, r, w.shadow_clip);
    }
    // All but the corners, as it is.
    for ([_]Piece{
        .{ .x = x, .y = y + radius, .w = ww, .h = wh - 2 * radius },
        .{ .x = x + radius, .y = y, .w = ww - 2 * radius, .h = radius },
        .{ .x = x + radius, .y = y + wh - radius, .w = ww - 2 * radius, .h = radius },
    }) |r| try piece(frame, pipelines.quads, vbo, quads, w, fw, fh, filter, r, w.clip);
    // The corners, cut (over their shadow).
    for ([_]Piece{
        .{ .x = x, .y = y, .w = radius, .h = radius },
        .{ .x = x + ww - radius, .y = y, .w = radius, .h = radius },
        .{ .x = x, .y = y + wh - radius, .w = radius, .h = radius },
        .{ .x = x + ww - radius, .y = y + wh - radius, .w = radius, .h = radius },
    }) |r| try piece(frame, pipelines.rounded, vbo, quads, w, fw, fh, filter, r, w.clip);
}

/// A see-through window, `qw` by `qh` on the screen, in one piece: its
/// corners cut if it is rounded.
fn fadingWindow(frame: *render.Frame, pipeline: *shader.Pipeline, vbo: vc4.Bo, index: usize, w: Window, qw: u32, qh: u32) !void {
    const radius: u32 = if (w.transform == 0 and 2 * @as(u32, w.radius) <= @min(qw, qh)) w.radius else 0;
    const uniforms: RoundedUniforms = .{
        .shape = .{ @as(f32, @floatFromInt(qw)) / 2, @as(f32, @floatFromInt(qh)) / 2, @floatFromInt(radius), std.math.clamp(w.opacity, 0, 1) },
        .shadow = .{ 0, 1, 0, 0 },
    };
    pipeline.setUniforms(std.mem.asBytes(&uniforms));
    const filter: texture.Filter = if (qw != w.texture.width or qh != w.texture.height) .linear else .nearest;
    try rect(frame, pipeline, vbo, index, w.texture, w.x, w.y, qw, qh, quadUvs(w.transform), filter, viewportOf(w.clip));
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
    // Drawn at another size (in the overview, or on its way to its place
    // after its state changed), it is filtered, not sampled.
    const filter: texture.Filter = if (qw != t.width or qh != t.height) .linear else .nearest;
    try rect(frame, pipeline, vbo, index, t, x, y, qw, qh, quadUvs(transform), filter, scissor);
}

/// Draws the rectangle at (x, y), (qw, qh) big, with texture coordinates
/// `uv` at its top left, bottom left, top right and bottom right corners.
/// The screen's row at the top of the frame being drawn: 0, but for a
/// screenshot taken in bands (see `Renderer.capture`), each band's top.
var band_top: i32 = 0;

fn rect(frame: *render.Frame, pipeline: *shader.Pipeline, vbo: vc4.Bo, index: usize, t: server.Texture, x: i32, y_screen: i32, qw: u32, qh: u32, uv: [4][2]f32, filter: texture.Filter, scissor_screen: ?render.Viewport) !void {
    std.debug.assert(index < max_quads);
    const y = y_screen - band_top;
    const scissor: ?render.Viewport = if (scissor_screen) |sc| blk: {
        // In the band (or nothing of it, if it is not).
        const top = @max(sc.y - band_top, 0);
        const bottom = @max(sc.y - band_top + @as(i32, @intCast(sc.height)), top);
        break :blk .{ .x = sc.x, .y = top, .width = sc.width, .height = @intCast(bottom - top) };
    } else null;
    // Two triangles, in clip space, with texture coordinates.
    const w: f32 = @floatFromInt(frame.target.width);
    const h: f32 = @floatFromInt(frame.target.height);
    const x0 = @as(f32, @floatFromInt(x)) / w * 2 - 1;
    const x1 = @as(f32, @floatFromInt(x + @as(i32, @intCast(qw)))) / w * 2 - 1;
    const y0 = 1 - @as(f32, @floatFromInt(y)) / h * 2;
    const y1 = 1 - @as(f32, @floatFromInt(y + @as(i32, @intCast(qh)))) / h * 2;
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
            .type = if (t.compressed) .etc1 else t.format.textureType(),
            .width = t.width,
            .height = t.height,
            .mag_filter = filter,
            .min_filter = filter,
            .wrap_s = .clamp,
            .wrap_t = .clamp,
        } },
    });
}

/// Room for the panels' and windows' quads (each two triangles of four
/// floats per vertex), every window rounded.
const max_quads = 1 + n_panels + max_windows * max_pieces;
const vbo_size = 53248;
comptime {
    std.debug.assert(max_quads * 6 * 4 * @sizeOf(f32) <= vbo_size);
}

/// A buffer the display can show.
const Scanout = struct { bo: vc4.Bo, fb_id: u32 };

/// The shell's own panels on the screen: the dock, the performance
/// overlay, the dock's tooltip and its quick settings, and notifications,
/// drawn on the CPU (as pixels) or the GPU (as a texture; see
/// kete_panel.zig). Each is see-through in
/// places (its pixels' alpha says where), and drawn blended. On an overlay
/// plane, it is in a band if it has one (`setPanelBand`), which the plane
/// fills, with the background drawn behind it; otherwise alone, the
/// display blending it over what is under it.
pub const PanelId = enum {
    dock,
    perf,
    tooltip,
    /// The dock's quick settings.
    quick,
    /// A notification, at the top of the screen.
    notice,
    /// The input method's candidates, by the cursor of the text typed.
    candidates,
    /// Parental controls' lock screen, over everything.
    lock,
};
const n_panels = @typeInfo(PanelId).@"enum".field_names.len;

/// A panel's picture, copied where it is needed when a frame is drawn: into
/// an overlay plane's buffer above a window shown directly, or (when the
/// frame is composited) a texture. A picture drawn by the GPU is a texture
/// already, and is drawn into an overlay plane's buffer by the GPU.
const Panel = struct {
    pixels: []const u32 = &.{},
    /// Drawn by the GPU: its texture (premultiplied), in place of `pixels`.
    gpu_texture: ?u32 = null,
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
    /// On an overlay plane, it is shown in the band across the screen from
    /// here down, over what of the background is there (`setPanelBand`).
    band_y: ?i32 = null,
    /// The overlay buffers' size, and the background they were drawn over.
    plane_size: [2]u32 = .{ 0, 0 },
    band_stamp: u32 = 0,
    /// Its picture copied for the display: uploaded as a texture, or
    /// written into an overlay buffer.
    upload_times: kete_panel.Times = .{},
    plane_times: kete_panel.Times = .{},
};

const n_cursors = @typeInfo(cursor.Shape).@"enum".field_names.len;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    dev: vc4.Device,
    display: vc4.display.Display,
    width: u32,
    height: u32,
    /// Draws textures as quads; and blended, for the panels and the snap
    /// preview (with a little texture of its shade, made when first drawn).
    quads: shader.Pipeline,
    blended: shader.Pipeline,
    rounded: shader.Pipeline,
    premultiplied: shader.Pipeline,
    preview_texture: ?server.Texture = null,
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
    /// The background image over it, if any (`setBackgroundImage`).
    background_image: ?server.Texture = null,
    /// The image's last rows as shown (`Prepared.bottom`), for bands.
    background_bottom: []u32 = &.{},
    /// Changes with the background, for bands to be drawn again.
    band_stamp: u32 = 1,
    /// Whether the GPU decodes ETC1 as `vc4.etc1` lays it out, and in
    /// which byte order (`etc1Order`), once checked.
    etc1_checked: bool = false,
    etc1_order: ?etc1.ByteOrder = null,

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
            .blended = try shader.Pipeline.init(gpa, dev, shader.Program.decode(@embedFile("quad_blend.shader")) catch unreachable, layout),
            .rounded = try shader.Pipeline.init(gpa, dev, shader.Program.decode(@embedFile("window.shader")) catch unreachable, layout),
            .premultiplied = try shader.Pipeline.init(gpa, dev, shader.Program.decode(@embedFile("quad_premultiplied.shader")) catch unreachable, layout),
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
            // Another size: the old one goes.
            if (existing) |old| {
                destroyTexture(r, old);
                t = .{ .handle = 0, .width = 0, .height = 0 };
            }
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

    /// Replaces a panel's picture, shown with its top left at (`x`, `y`).
    /// Its pixels, or its texture, must stay until the next call.
    pub fn setPanelAt(r: *Renderer, id: PanelId, picture: kete_panel.Picture, x: i32, y: i32) void {
        const p = &r.panels[@intFromEnum(id)];
        p.pixels = picture.pixels;
        p.gpu_texture = picture.texture;
        p.width = picture.width;
        p.height = picture.height;
        p.x = x;
        p.y = y;
        p.dirty = true;
        p.texture_stale = picture.texture == null;
    }

    /// The time spent copying panel `id`'s picture for the display: as a
    /// texture, and into overlay buffers.
    pub fn panelTimes(r: *const Renderer, id: PanelId) [2]kete_panel.Times {
        const p = &r.panels[@intFromEnum(id)];
        return .{ p.upload_times, p.plane_times };
    }

    /// Moves a panel, its picture as it is.
    pub fn movePanel(r: *Renderer, id: PanelId, x: i32, y: i32) void {
        const p = &r.panels[@intFromEnum(id)];
        if (p.x == x and p.y == y) return;
        p.x = x;
        p.y = y;
        p.dirty = true;
    }

    /// On an overlay plane, shows a panel in a band across the screen from
    /// `y` to the bottom, over the background there, rather than alone:
    /// one that is see-through can then be (the dock, around a window
    /// shown directly that leaves the band uncovered).
    pub fn setPanelBand(r: *Renderer, id: PanelId, y: ?i32) void {
        r.panels[@intFromEnum(id)].band_y = y;
    }

    /// Hides a panel, or shows it again.
    pub fn setPanelHidden(r: *Renderer, id: PanelId, hidden: bool) void {
        r.panels[@intFromEnum(id)].hidden = hidden;
    }

    /// Hides the panels (under a fullscreen window), or shows them again.
    pub fn hidePanels(r: *Renderer, hidden: bool) void {
        for (&r.panels) |*p| p.hidden = hidden;
    }

    /// The overlay plane each panel is shown on, above a window shown
    /// directly: those that may show over one for long (a notification,
    /// as it fades in and out, too). With any other showing (the tooltip,
    /// the quick settings, the lock screen), the frame is composited.
    const panel_planes = std.enums.directEnumArray(PanelId, ?usize, 0, .{
        .dock = 0,
        .perf = 1,
        .tooltip = null,
        .quick = null,
        .notice = 2,
        .candidates = null,
        .lock = null,
    });

    fn panelLayers(r: *Renderer) ?vc4.kms.Overlays {
        const kms = r.display.kms orelse return null;
        var out: vc4.kms.Overlays = @splat(null);
        for (&r.panels, 0..) |*p, i| {
            if (p.width == 0 or p.height == 0 or p.hidden) continue;
            const plane = panel_planes[i] orelse return null;
            if (plane >= kms.overlays.len or kms.overlays[plane] == null) return null;
            out[plane] = r.panelLayer(p) orelse return null;
        }
        return out;
    }

    /// Shows a client's buffer directly on the display's primary plane at
    /// (`x`, `y`), stretched to `size` (if smaller: the display scales it),
    /// with the panels on overlay planes, so nothing is composited. Returns null if the display cannot (the buffer is not
    /// T-tiled, or the planes are not available), and the frame must be
    /// composited instead; otherwise whether it is already on the screen,
    /// as `show` does. Only while no flip is pending.
    pub fn showDirect(r: *Renderer, t: server.Texture, x: i32, y: i32, size: [2]u32) ?bool {
        if (r.dev.is_v3d or r.display.kms == null) return null;
        if (vc4.render.Target.textureTiling(t.format, t.width, t.height) != .t) return null;
        const panels = r.panelLayers() orelse return null;
        const fb = r.clientFramebuffer(t, x, y, size, panels) orelse return null;
        return r.display.queueLayers(windowLayer(fb, t, x, y, size), panels) catch |err| {
            sys.print(sys.log_warning ++ "dazzle-shell: cannot show the window directly: {s}\n", .{@errorName(err)});
            return null;
        };
    }

    fn windowLayer(fb: u32, t: server.Texture, x: i32, y: i32, size: [2]u32) vc4.kms.Layer {
        return .{ .fb_id = fb, .src_width = t.width, .src_height = t.height, .x = x, .y = y, .width = size[0], .height = size[1] };
    }

    /// A framebuffer for a client's buffer, made (and checked with the
    /// display, with the window at `x`, `y` under `panels`) the first time
    /// it is shown.
    fn clientFramebuffer(r: *Renderer, t: server.Texture, x: i32, y: i32, size: [2]u32, panels: vc4.kms.Overlays) ?u32 {
        if (r.client_fbs.get(t.handle)) |fb| return fb;
        // T-tiled images are padded to whole columns of tiles.
        const pitch = texture.tiledPitch(t.format, t.width, t.height);
        var fb: ?u32 = vc4.drm.addFramebufferWithModifier(r.dev.fd, t.handle, t.width, t.height, pitch, t.format.fourcc(), vc4.kms.modifier_t_tiled) catch |err| blk: {
            sys.print(sys.log_warning ++ "dazzle-shell: no framebuffer for a {d}x{d} window: {s}\n", .{ t.width, t.height, @errorName(err) });
            break :blk null;
        };
        if (fb) |id| if (!r.display.canShow(windowLayer(id, t, x, y, size), panels)) {
            sys.print(sys.log_warning ++ "dazzle-shell: the display cannot show a {d}x{d} window directly at {d}x{d}\n", .{ t.width, t.height, size[0], size[1] });
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
        const size = r.planeSize(p) orelse return null;
        // Made at another size (the panel changed): it is composited.
        if (p.planes[0] != null and !std.meta.eql(size, p.plane_size)) return null;
        if (p.dirty or (p.band_y != null and p.band_stamp != r.band_stamp)) {
            const next = p.shown +% 1;
            const plane = r.panelPlane(p, next, size) orelse return null;
            const started = sys.nowNs();
            r.drawPlane(p, plane);
            p.plane_times.add(sys.nowNs() - started, @as(u64, size[0]) * size[1]);
            p.shown = next;
            p.dirty = false;
        }
        const plane = r.panelPlane(p, p.shown, size) orelse return null;
        const x = if (p.band_y != null) 0 else p.x;
        const y = p.band_y orelse p.y;
        return .{ .fb_id = plane.fb_id, .src_width = size[0], .src_height = size[1], .x = x, .y = y, .width = size[0], .height = size[1] };
    }

    /// An overlay buffer's size: the panel's, or its band's.
    fn planeSize(r: *const Renderer, p: *const Panel) ?[2]u32 {
        const y = p.band_y orelse return .{ p.width, p.height };
        if (y < 0 or y >= r.height) return null;
        return .{ r.width, r.height - @as(u32, @intCast(y)) };
    }

    /// Writes the panel's picture into an overlay buffer: in a band, over
    /// the background there.
    fn drawPlane(r: *Renderer, p: *Panel, plane: Scanout) void {
        if (p.gpu_texture) |handle| return r.drawPlaneGpu(p, plane, handle) catch |err| {
            sys.print(sys.log_warning ++ "dazzle-shell: a panel's overlay is not drawn: {s}\n", .{@errorName(err)});
        };
        const size = p.plane_size;
        // Its rows are `stride` pixels apart (see `panelPlane`).
        const stride = render.Target.pitch(.argb8888, @intCast(size[0])) / 4;
        const dst = std.mem.bytesAsSlice(u32, plane.bo.map[0 .. stride * size[1] * 4]);
        const band_y = p.band_y orelse {
            for (0..size[1]) |row| {
                const line = dst[row * stride ..][0..size[0]];
                const src = p.pixels[row * p.width ..][0..p.width];
                if (alphaPlane(p)) {
                    for (line, src) |*d, s| d.* = glass.premultiply(s);
                } else @memcpy(line, src);
            }
            return;
        };
        p.band_stamp = r.band_stamp;
        const bottom_rows = r.background_bottom.len / r.width;
        for (0..size[1]) |row| {
            const line = dst[row * stride ..][0..size[0]];
            const screen_y = @as(usize, @intCast(band_y)) + row;
            // The background image's row there, or its colour.
            if (screen_y + bottom_rows >= r.height) {
                const from = screen_y + bottom_rows - r.height;
                @memcpy(line, r.background_bottom[from * r.width ..][0..r.width]);
            } else @memset(line, r.background);
            // The panel over it, blended.
            const py = @as(i64, @intCast(screen_y)) - p.y;
            if (py < 0 or py >= p.height) continue;
            for (0..p.width) |px| {
                const sx = @as(i64, p.x) + @as(i64, @intCast(px));
                if (sx < 0 or sx >= size[0]) continue;
                const src = p.pixels[@as(usize, @intCast(py)) * p.width + px];
                const d = &line[@intCast(sx)];
                d.* = over(d.*, src);
            }
        }
    }

    /// Whether a panel's overlay plane has an alpha channel: it is alone,
    /// not in a band.
    fn alphaPlane(p: *const Panel) bool {
        return p.band_y == null;
    }

    /// `src` (0xAARRGGBB, not premultiplied) over the opaque `dst`, as the
    /// GPU blends it.
    fn over(dst: u32, src: u32) u32 {
        const a = src >> 24;
        if (a == 255) return src;
        if (a == 0) return dst;
        var out: u32 = 0xff000000;
        inline for (.{ 0, 8, 16 }) |shift| {
            const sc = src >> shift & 0xff;
            const dc = dst >> shift & 0xff;
            out |= ((sc * a + dc * (255 - a) + 127) / 255) << shift;
        }
        return out;
    }

    /// The panel's texture (drawn by the GPU) drawn into an overlay buffer
    /// by the GPU, as `drawPlane` does on the CPU: alone, as it is
    /// (premultiplied, as the plane takes it), or in a band over the
    /// background (as `composite` draws it there).
    fn drawPlaneGpu(r: *Renderer, p: *Panel, plane: Scanout, handle: u32) !void {
        const size = p.plane_size;
        const band_y = p.band_y;
        if (band_y != null) p.band_stamp = r.band_stamp;
        const top = band_y orelse p.y;
        const left = if (band_y != null) p.x else 0;
        static_frame.begin(.{
            .handle = plane.bo.handle,
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
            .tiling = .linear,
            .format = if (alphaPlane(p)) .argb8888 else .xrgb8888,
        }, .{ .clear = if (band_y != null) r.background else 0 });
        var n: usize = 0;
        if (band_y) |y| if (r.background_image) |bg| {
            try quad(&static_frame, &r.quads, r.vbo, n, bg, 0, -y, bg.width, bg.height, 0, null);
            n += 1;
        };
        const t: server.Texture = .{ .handle = handle, .width = p.width, .height = p.height, .format = .argb8888 };
        try quad(&static_frame, &r.premultiplied, r.vbo, n, t, left, p.y - top, p.width, p.height, 0, null);
        const seqno = try r.dev.submit(static_frame.finish());
        try r.dev.waitSeqno(seqno, std.time.ns_per_s);
    }

    fn panelPlane(r: *Renderer, p: *Panel, i: u1, size: [2]u32) ?Scanout {
        if (p.planes[i]) |plane| return plane;
        // Rows as the GPU draws them (whole micro-tiles across), for a
        // picture it draws.
        const pitch = render.Target.pitch(.argb8888, @intCast(size[0]));
        const bo = r.dev.createBo(pitch * size[1]) catch return null;
        const format = if (alphaPlane(p)) vc4.drm.format_argb8888 else vc4.drm.format_xrgb8888;
        const fb = vc4.drm.addFramebuffer(r.dev.fd, bo.kmsHandle(), size[0], size[1], pitch, format) catch {
            r.dev.destroyBo(bo);
            return null;
        };
        p.planes[i] = .{ .bo = bo, .fb_id = fb };
        p.plane_size = size;
        // The first one shown starts with the current picture.
        r.drawPlane(p, p.planes[i].?);
        return p.planes[i];
    }

    /// The shell's last frame, before it stops (the computer restarting or
    /// turning off): everything but the pointer and a notification, in one
    /// buffer shown alone, so the shutdown screen can show that buffer and
    /// fade from it (see init's splash.zig). Returns once it is on the
    /// screen.
    pub fn showLast(r: *Renderer, windows: []const Window) !void {
        while (r.display.flip_pending) _ = try r.display.handleEvents();
        var quads = try r.panelQuads();
        quads[@intFromEnum(PanelId.notice)] = null;
        static_frame.begin(r.display.backTarget(), .{ .clear = r.background });
        try recordFrame(&static_frame, r.pipelines(), try r.previewTexture(), r.background_image, r.vbo, &quads, windows);
        const seqno = try r.dev.submit(static_frame.finish());
        try r.dev.waitSeqno(seqno, std.time.ns_per_s);
        vc4.drm.setCursor(r.dev.fd, r.display.output.crtc_id, 0, 0, 0) catch {};
        if (r.display.kms) |*k| _ = k.setCover(null);
        if (!try r.display.queue()) while (try r.display.handleEvents() == null) {};
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
        try recordFrame(&static_frame, r.pipelines(), try r.previewTexture(), r.background_image, r.vbo, &quads, windows);
        const t1 = sys.nowNs();
        const seqno = try r.dev.submit(static_frame.finish());
        try r.dev.waitSeqno(seqno, std.time.ns_per_s);
        return .{ .cpu_ns = t1 - t0, .gpu_ns = sys.nowNs() - t1 };
    }

    /// Shows `image` (made by `background.prepare`) over the background
    /// colour, or none; the image's memory is the caller's still.
    pub fn setBackgroundImage(r: *Renderer, image: ?*const background_mod.Prepared) !void {
        if (r.background_image) |old| {
            destroyTexture(r, old);
            r.background_image = null;
        }
        r.gpa.free(r.background_bottom);
        r.background_bottom = &.{};
        r.band_stamp +%= 1;
        const p = image orelse return;
        r.background_bottom = try r.gpa.dupe(u32, p.bottom);
        switch (p.kind) {
            .etc1 => {
                const bo = try r.dev.createBo(@intCast(p.data.len));
                errdefer r.dev.destroyBo(bo);
                @memcpy(bo.map[0..p.data.len], p.data);
                try r.owned.put(r.gpa, bo.handle, bo);
                r.background_image = .{ .handle = bo.handle, .width = p.width, .height = p.height, .compressed = true };
            },
            .rgb565 => r.background_image = try uploadPixels(r, null, p.data, p.width, p.height, p.width * 2, .rgb565),
        }
    }

    /// How a background image is best made for this GPU: ETC1, if it
    /// decodes it as expected (checked once, by drawing a test image and
    /// reading it back), and otherwise RGB565.
    pub fn backgroundKind(r: *Renderer) background_mod.Kind {
        return if (r.etc1Order()) |order| .{ .etc1 = order } else .rgb565;
    }

    fn etc1Order(r: *Renderer) ?etc1.ByteOrder {
        if (r.etc1_checked) return r.etc1_order;
        r.etc1_checked = true;
        // The V3D (a Pi 4's) tiles its textures otherwise.
        if (r.dev.is_v3d) return null;
        for ([_]etc1.ByteOrder{ .standard, .reversed }) |order| {
            const ok = r.etc1Decodes(order) catch |err| {
                sys.print(sys.log_warning ++ "dazzle-shell: cannot check ETC1 textures: {s}\n", .{@errorName(err)});
                return null;
            };
            if (ok) {
                r.etc1_order = order;
                return order;
            }
        }
        sys.print(sys.log_warning ++ "dazzle-shell: the GPU does not decode ETC1 as expected: background images are RGB565\n", .{});
        return null;
    }

    /// Whether a test image in ETC1, laid out in `order`, comes back from
    /// the GPU as it decodes on the CPU. Big enough to be in 4 KB tiles,
    /// as a background is.
    fn etc1Decodes(r: *Renderer, order: etc1.ByteOrder) !bool {
        const n = 128;
        const pixels = try r.gpa.alloc(u32, n * n);
        defer r.gpa.free(pixels);
        for (0..n) |y| for (0..n) |x| {
            pixels[y * n + x] = 0xff000000 | @as(u32, @intCast(x * 2)) << 16 | @as(u32, @intCast(y * 2)) << 8 | @as(u32, @intCast((x ^ y) * 2 & 0xff));
        };
        const nb = etc1.blocksOf(n, n);
        const blocks = try r.gpa.alloc(u64, nb[0] * nb[1]);
        defer r.gpa.free(blocks);
        etc1.encode(pixels, n, n, blocks);
        const size = etc1.imageSize(n, n);
        const tex = try r.dev.createBo(size);
        defer r.dev.destroyBo(tex);
        @memset(tex.map[0..size], 0);
        etc1.upload(tex.map[0..size], n, n, blocks, order);
        const pitch = render.Target.pitch(.xrgb8888, n);
        const target = try r.dev.createBo(pitch * n);
        defer r.dev.destroyBo(target);
        capture_frame.begin(.{ .handle = target.handle, .width = n, .height = n, .tiling = .linear }, .{ .clear = 0 });
        try quad(&capture_frame, &r.quads, r.vbo, 0, .{ .handle = tex.handle, .width = n, .height = n, .compressed = true }, 0, 0, n, n, 0, null);
        const seqno = try r.dev.submit(capture_frame.finish());
        try r.dev.waitSeqno(seqno, std.time.ns_per_s);
        for (0..nb[1]) |by| for (0..nb[0]) |bx| {
            const want = etc1.decodeBlock(blocks[by * nb[0] + bx]);
            for (0..16) |i| {
                const x = bx * 4 + i % 4;
                const y = by * 4 + i / 4;
                const got = std.mem.readInt(u32, target.map[y * pitch + x * 4 ..][0..4], .little);
                if (channelDistance(got, want[i]) > 2) return false;
            }
        };
        return true;
    }

    fn pipelines(r: *Renderer) Pipelines {
        return .{ .quads = &r.quads, .blended = &r.blended, .rounded = &r.rounded, .premultiplied = &r.premultiplied };
    }

    /// A texture of the snap preview's shade (4 by 4, all of it).
    fn previewTexture(r: *Renderer) !server.Texture {
        if (r.preview_texture == null) {
            const pixels: [16]u32 = @splat(preview_color);
            r.preview_texture = try uploadPixels(r, null, std.mem.sliceAsBytes(&pixels), 4, 4, 16, .argb8888);
        }
        return r.preview_texture.?;
    }

    /// The panels as textures, with their latest pictures.
    fn panelQuads(r: *Renderer) ![n_panels]?PanelQuad {
        var quads: [n_panels]?PanelQuad = @splat(null);
        for (&r.panels, &quads) |*p, *q| {
            if (p.width == 0 or p.height == 0 or p.hidden) continue;
            if (p.gpu_texture) |handle| {
                q.* = .{ .texture = .{ .handle = handle, .width = p.width, .height = p.height, .format = .argb8888 }, .x = p.x, .y = p.y, .premultiplied = true };
                continue;
            }
            if (p.texture_stale) {
                const started = sys.nowNs();
                p.texture = try uploadPixels(r, p.texture, std.mem.sliceAsBytes(p.pixels), p.width, p.height, p.width * 4, .argb8888);
                p.upload_times.add(sys.nowNs() - started, @as(u64, p.width) * p.height);
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
    /// How many rows of the screen a screenshot is drawn at a time when
    /// video memory has no room for all of it at once.
    const capture_band = 64;

    /// The screen, drawn again (without a notification on it): all at
    /// once, or, when video memory has no room for a buffer the screen's
    /// size (8 MB at 1080p, in one piece: an app may have most of it), a
    /// band of rows at a time.
    pub fn capture(r: *Renderer, gpa: std.mem.Allocator, windows: []const Window, force_bands: bool) ![]u32 {
        var quads = try r.panelQuads();
        // A notification (perhaps of the last screenshot) is not in it.
        quads[@intFromEnum(PanelId.notice)] = null;
        const pitch = render.Target.pitch(.xrgb8888, @intCast(r.width));
        const pixels = try gpa.alloc(u32, @as(usize, r.width) * r.height);
        errdefer gpa.free(pixels);
        const whole = if (force_bands) null else r.dev.createBo(pitch * r.height) catch null;
        const rows: u32 = if (whole != null) r.height else capture_band;
        if (whole == null) sys.print("dazzle-shell: a screenshot drawn in bands of {d} rows{s}\n", .{ capture_band, if (force_bands) " (as asked)" else " (no room for it all at once)" });
        const bo = whole orelse try r.dev.createBo(pitch * capture_band);
        defer r.dev.destroyBo(bo);
        defer band_top = 0;
        var top: u32 = 0;
        while (top < r.height) : (top += rows) {
            const n = @min(rows, r.height - top);
            band_top = @intCast(top);
            capture_frame.begin(.{ .handle = bo.handle, .width = @intCast(r.width), .height = @intCast(n), .tiling = .linear }, .{ .clear = r.background });
            try recordFrame(&capture_frame, r.pipelines(), try r.previewTexture(), r.background_image, r.vbo, &quads, windows);
            const seqno = try r.dev.submit(capture_frame.finish());
            try r.dev.waitSeqno(seqno, std.time.ns_per_s);
            for (0..n) |y| {
                const row = std.mem.bytesAsSlice(u32, bo.map[y * pitch ..][0 .. r.width * 4]);
                // Windows' buffers need not be opaque where the screen is.
                for (pixels[(top + y) * r.width ..][0..r.width], row) |*out, in| out.* = in | 0xff000000;
            }
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

fn channelDistance(a: u32, b: u32) u32 {
    var most: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const x: i32 = @intCast(a >> shift & 0xff);
        const y: i32 = @intCast(b >> shift & 0xff);
        most = @max(most, @abs(x - y));
    }
    return most;
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const sim = vc4.qpu_sim;

test "a band's panel is blended over the background as the GPU blends it" {
    try testing.expectEqual(@as(u32, 0xff112233), Renderer.over(0xff445566, 0xff112233));
    try testing.expectEqual(@as(u32, 0xff445566), Renderer.over(0xff445566, 0x00112233));
    try testing.expectEqual(@as(u32, 0xff808080), Renderer.over(0xff000000, 0x80ffffff));
}

test "a rounded window's corners are cut, and its shadow fades out around it (shaders/window.zig, in the QPU simulator)" {
    // A window 100 by 60 at (0, 0) on the screen, in a blue-grey, over
    // white.
    const ww = 100;
    const wh = 60;
    const window_color = 0xff3080c0;
    const white = 0xffffffff;
    const program = shader.Program.decode(@embedFile("window.shader")) catch unreachable;
    var decoded_buf: [vc4.compiler.max_code]sim.DecodedInst = undefined;
    const decoded = sim.decodeProgram(program.fs.code(), &decoded_buf);
    var tex_memory: [texture.imageSizeOf(.xrgb8888, 4, 4)]u8 = undefined;
    const tex_pixels: [16]u32 = @splat(window_color);
    texture.uploadRectOf(.xrgb8888, &tex_memory, 4, 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, std.mem.sliceAsBytes(&tex_pixels), 16);
    const cfg: texture.Config = .{ .type = vc4.Format.xrgb8888.textureType(), .width = 4, .height = 4, .mag_filter = .nearest, .min_filter = .nearest, .wrap_s = .clamp, .wrap_t = .clamp };
    const values: RoundedUniforms = .{ .shape = .{ ww / 2, wh / 2, 12, 1 }, .shadow = .{ shadow_alpha, shadow_blur, shadow_offset, 0 } };
    const words = std.mem.bytesAsSlice(u32, std.mem.asBytes(&values));
    var uniforms: [32]u32 = undefined;
    for (program.fs.uniforms(), uniforms[0..program.fs.uniforms().len]) |u, *out| out.* = switch (u) {
        .user => |i| words[i],
        .tex_p0 => texture.p0(cfg),
        .tex_p1 => texture.p1(cfg),
        .constant => |v| v,
    };

    // Pixels (their centres) on the screen, and what each should be.
    const Want = union(enum) { window, grey: [2]u8 };
    const cases = [_]struct { x: f32, y: f32, want: Want }{
        // Inside: the window, also near its square edges and inside the
        // curve of a corner.
        .{ .x = 50.5, .y = 30.5, .want = .window },
        .{ .x = 50.5, .y = 0.5, .want = .window },
        .{ .x = 0.5, .y = 30.5, .want = .window },
        .{ .x = 6.5, .y = 6.5, .want = .window },
        .{ .x = 93.5, .y = 53.5, .want = .window },
        // At the very corner: cut, its shadow behind (a light grey).
        .{ .x = 0.5, .y = 0.5, .want = .{ .grey = .{ 150, 230 } } },
        .{ .x = 99.5, .y = 59.5, .want = .{ .grey = .{ 120, 200 } } },
        // Just under the window, the shadow is darkest; further away, it
        // fades to nothing.
        .{ .x = 50.5, .y = 61.5, .want = .{ .grey = .{ 140, 170 } } },
        .{ .x = 50.5, .y = 75.5, .want = .{ .grey = .{ 175, 245 } } },
        .{ .x = 50.5, .y = 89.5, .want = .{ .grey = .{ 250, 255 } } },
        .{ .x = 50.5, .y = -17.5, .want = .{ .grey = .{ 250, 255 } } },
        .{ .x = 125.5, .y = 30.5, .want = .{ .grey = .{ 250, 255 } } },
    };
    var u_lanes: sim.Vec = undefined;
    var v_lanes: sim.Vec = undefined;
    for (0..sim.lanes) |lane| {
        const c = cases[@min(lane, cases.len - 1)];
        u_lanes[lane] = @bitCast(c.x / ww);
        v_lanes[lane] = @bitCast(c.y / wh);
    }
    const r = try sim.runFragmentDecoded(decoded, .{ .uniforms = &uniforms, .varyings = &.{ u_lanes, v_lanes }, .tlb_color_in = @splat(white), .texture_memory = &tex_memory });
    for (cases, 0..) |c, lane| {
        const px = r.tlb_color.?[lane];
        const red: u8 = @truncate(px >> 16);
        const green: u8 = @truncate(px >> 8);
        const blue: u8 = @truncate(px);
        errdefer std.debug.print("at ({d}, {d}): 0x{x:0>8}\n", .{ c.x, c.y, px });
        switch (c.want) {
            .window => try testing.expect(@abs(@as(i32, red) - 0x30) <= 2 and @abs(@as(i32, green) - 0x80) <= 2 and @abs(@as(i32, blue) - 0xc0) <= 2),
            .grey => |range| {
                try testing.expect(red == green and green == blue);
                try testing.expect(red >= range[0] and red <= range[1]);
            },
        }
    }
}

test "a window fading out is drawn see-through, as much as its opacity (shaders/window.zig, in the QPU simulator)" {
    // A black window 100 by 60, half see-through, over white: grey all
    // over it, its corners square.
    const program = shader.Program.decode(@embedFile("window.shader")) catch unreachable;
    var decoded_buf: [vc4.compiler.max_code]sim.DecodedInst = undefined;
    const decoded = sim.decodeProgram(program.fs.code(), &decoded_buf);
    var tex_memory: [texture.imageSizeOf(.xrgb8888, 4, 4)]u8 = undefined;
    const tex_pixels: [16]u32 = @splat(0xff000000);
    texture.uploadRectOf(.xrgb8888, &tex_memory, 4, 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, std.mem.sliceAsBytes(&tex_pixels), 16);
    const cfg: texture.Config = .{ .type = vc4.Format.xrgb8888.textureType(), .width = 4, .height = 4, .mag_filter = .nearest, .min_filter = .nearest, .wrap_s = .clamp, .wrap_t = .clamp };
    const values: RoundedUniforms = .{ .shape = .{ 50, 30, 0, 0.5 }, .shadow = .{ 0, 1, 0, 0 } };
    const words = std.mem.bytesAsSlice(u32, std.mem.asBytes(&values));
    var uniforms: [32]u32 = undefined;
    for (program.fs.uniforms(), uniforms[0..program.fs.uniforms().len]) |u, *out| out.* = switch (u) {
        .user => |i| words[i],
        .tex_p0 => texture.p0(cfg),
        .tex_p1 => texture.p1(cfg),
        .constant => |v| v,
    };
    const points = [_][2]f32{ .{ 50.5, 30.5 }, .{ 0.5, 0.5 }, .{ 99.5, 59.5 }, .{ 0.5, 59.5 } };
    var u_lanes: sim.Vec = undefined;
    var v_lanes: sim.Vec = undefined;
    for (0..sim.lanes) |lane| {
        const pt = points[@min(lane, points.len - 1)];
        u_lanes[lane] = @bitCast(pt[0] / 100);
        v_lanes[lane] = @bitCast(pt[1] / 60);
    }
    const r = try sim.runFragmentDecoded(decoded, .{ .uniforms = &uniforms, .varyings = &.{ u_lanes, v_lanes }, .tlb_color_in = @splat(0xffffffff), .texture_memory = &tex_memory });
    for (points, 0..) |pt, lane| {
        const px = r.tlb_color.?[lane];
        errdefer std.debug.print("at ({d}, {d}): 0x{x:0>8}\n", .{ pt[0], pt[1], px });
        const red: u8 = @truncate(px >> 16);
        try testing.expect(red >= 0x7c and red <= 0x84);
        try testing.expectEqual(red, @as(u8, @truncate(px)));
    }
}
