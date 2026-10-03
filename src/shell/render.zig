//! The shell's renderer, on the low-level vc4 API: each frame is one GPU
//! job that clears the screen and draws the bar and the top window as
//! textured quads, then is shown with a page flip.
//!
//! Window contents are textures: clients' dma-bufs used in place (they
//! render in the GPU's T-tiled layout, which the texture unit reads), or
//! copies of shared-memory buffers. The quad shaders are written with the
//! compiler's builder API.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");
const font = @import("font");
const server = @import("server.zig");
const cursor = @import("cursor.zig");

const compiler = vc4.compiler;
const render = vc4.render;
const texture = vc4.texture;
const Shader = compiler.Shader;
const Value = compiler.Value;

pub const background = 0xff101830;
const bar_background = 0xff1c2a4a;

// --- Shaders ------------------------------------------------------------------
//
// attribute vec2 pos; attribute vec2 uv; varying vec2 v_uv;
// gl_Position = vec4(pos, 0, 1); v_uv = uv;
// gl_FragColor = texture2D(tex, v_uv);
//
// Uniforms: 0 = viewport x scale, 1 = viewport y scale (1/16 px units).

fn writeScreenHeader(s: *Shader, x: Value, y: Value) void {
    s.vpmWrite(s.packScreenXy(s.fmul(x, s.uniform(0)), s.fmul(y, s.uniform(1))));
    s.vpmWrite(s.constantF(0.5)); // Zs
    s.vpmWrite(s.constantF(1.0)); // 1/Wc
}

pub fn quadVertex() Shader {
    var s = Shader.init(.vertex);
    const x = s.vpmRead();
    const y = s.vpmRead();
    const u = s.vpmRead();
    const v = s.vpmRead();
    writeScreenHeader(&s, x, y);
    s.vpmWrite(u);
    s.vpmWrite(v);
    return s;
}

pub fn quadCoordinate() Shader {
    var s = Shader.init(.coordinate);
    const x = s.vpmRead();
    const y = s.vpmRead();
    s.vpmWrite(x);
    s.vpmWrite(y);
    s.vpmWrite(s.constantF(0.0));
    s.vpmWrite(s.constantF(1.0));
    writeScreenHeader(&s, x, y);
    return s;
}

pub fn quadFragment() Shader {
    var s = Shader.init(.fragment);
    const u = s.varying();
    const v = s.varying();
    // Textures and the render target are both stored B, G, R, A, so texels
    // go straight to the tile buffer.
    s.tlbColor(s.texture(u, v));
    return s;
}

pub const Program = struct {
    handle: u32,
    compiled: compiler.Compiled,

    pub fn init(dev: vc4.Device, shader: Shader) !Program {
        const compiled = try compiler.compile(&shader);
        return .{ .handle = try dev.createShaderBo(compiled.code()), .compiled = compiled };
    }

    fn binding(p: *const Program, user: []const u32) render.ShaderBinding {
        return .{ .handle = p.handle, .layout = p.compiled.uniforms(), .user = user };
    }
};

/// Frames are large; the shell has one.
var static_frame: render.Frame = undefined;

/// The quad program's three stages.
pub const Programs = struct {
    fs: Program,
    vs: Program,
    cs: Program,
};

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
pub fn recordFrame(frame: *render.Frame, programs: *const Programs, vbo: vc4.Bo, bar: ?server.Texture, window: ?Window) !void {
    const scale = frame.target.fullViewport().scaleBits();
    var quads: usize = 0;
    if (bar) |b| {
        try quad(frame, programs, vbo, &scale, quads, b, 0, 0, null);
        quads += 1;
    }
    if (window) |w| {
        try quad(frame, programs, vbo, &scale, quads, w.texture, w.x, w.y, .{ .x = w.clip.x, .y = w.clip.y, .width = w.clip.width, .height = w.clip.height });
        quads += 1;
    }
}

/// Draws a texture 1:1 with its top left at (x, y).
fn quad(frame: *render.Frame, programs: *const Programs, vbo: vc4.Bo, scale: *const [2]u32, index: usize, t: server.Texture, x: i32, y: i32, scissor: ?render.Viewport) !void {
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
    const attrs = [_]render.Attribute{
        .{ .handle = vbo.handle, .offset = offset, .size = 8, .stride = 16, .vs_vpm_offset = 0, .cs_vpm_offset = 0 },
        .{ .handle = vbo.handle, .offset = offset + 8, .size = 8, .stride = 16, .vs_vpm_offset = 8, .cs_vpm_offset = 0 },
    };
    try frame.draw(.{
        .fs = programs.fs.binding(&.{}),
        .vs = programs.vs.binding(scale),
        .cs = programs.cs.binding(scale),
        .fs_num_varyings = 2,
        .attributes = &attrs,
        .vs_attribute_mask = 0b11,
        .vs_attributes_size = 16,
        .cs_attribute_mask = 0b01,
        .cs_attributes_size = 8,
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

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    dev: vc4.Device,
    display: vc4.display.Display,
    width: u32,
    height: u32,
    programs: Programs,
    /// Vertices for this frame's quads.
    vbo: vc4.Bo,
    /// Buffers backing the textures the renderer allocated (shm copies), by
    /// GEM handle. Imported dma-bufs have only a handle.
    owned: std.AutoHashMapUnmanaged(u32, vc4.Bo) = .empty,
    bar: ?server.Texture = null,
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
            .programs = .{
                .fs = try Program.init(dev, quadFragment()),
                .vs = try Program.init(dev, quadVertex()),
                .cs = try Program.init(dev, quadCoordinate()),
            },
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
        if (r.owned.fetchRemove(t.handle)) |kv| {
            r.dev.destroyBo(kv.value);
        } else {
            vc4.drm.gemClose(r.dev.fd, t.handle);
        }
    }

    /// Replaces the bar's picture.
    pub fn setBar(r: *Renderer, pixels: []const u32, width: u32, height: u32) !void {
        r.bar = try uploadPixels(r, r.bar, std.mem.sliceAsBytes(pixels), width, height, width * 4);
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
        static_frame.begin(r.display.backTarget(), .{ .clear = background });
        try recordFrame(&static_frame, &r.programs, r.vbo, r.bar, window);
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
