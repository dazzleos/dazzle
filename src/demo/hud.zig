//! The statistics overlay in the top left corner: text drawn by the CPU
//! with the font renderer into a texture, shown as an opaque quad on top of
//! the scene. The panel's background is the scene's clear colour, so the
//! text appears to sit directly on the background (the quad is drawn
//! without blending, so it cannot be translucent).

const std = @import("std");
const font = @import("font");
const vc4 = @import("vc4");
const shader = @import("shader");
const cube = @import("cube.zig");

pub const title_color = 0xffffffff;
pub const text_color = 0xffd8e0f0;
pub const dim_color = 0xff8090b0;

pub const Hud = struct {
    gpa: std.mem.Allocator,
    font: *const font.Font,
    cache: font.GlyphCache,
    background: u32,
    /// Display size and the panel's size, in pixels.
    screen: [2]u32,
    width: u32,
    height: u32,
    scale: f32,
    pixels: []u32,
    /// Hashes of the text in each band (the title, then each line), so
    /// only changed lines are redrawn and uploaded; 0 = not drawn.
    drawn: [lines + 1]u64 = @splat(0),
    dev: vc4.Device,
    pipeline: shader.Pipeline,
    /// The panel's pixels in the texture unit's tiled layout.
    texture: ?vc4.Bo = null,
    /// The quad as a triangle strip of (x, y, u, v) in clip space.
    quad: vc4.Bo,

    /// Small text after the title.
    subtitle: []const u8 = "",

    /// Lines of text the panel holds, below the title.
    pub const lines = 6;

    /// Sizes are designed for 1920x1080 and scale with the display (by its
    /// narrower dimension, so the panel stays clear of the cube on 4:3).
    fn scaleFor(screen_width: u32, screen_height: u32) f32 {
        return @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
    }

    /// Where the panel goes: x, y, width and height in pixels.
    pub fn rect(screen_width: u32, screen_height: u32) [4]u32 {
        const scale = scaleFor(screen_width, screen_height);
        const margin: u32 = @intFromFloat(@floor(24 * scale));
        return .{ margin, margin, @intFromFloat(@ceil(560 * scale)), @intFromFloat(@ceil((96 + lines * 40) * scale)) };
    }

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device, f: *const font.Font, screen_width: u32, screen_height: u32, background: u32) !Hud {
        const program = shader.Program.decode(@embedFile("hud.shader")) catch unreachable;
        var pipeline = try shader.Pipeline.init(gpa, dev, program, .{
            .vertex_stride = 16,
            .attributes = &.{ .{ .location = 0, .offset = 0 }, .{ .location = 1, .offset = 8 } },
            .primitive = .triangle_strip,
        });
        errdefer pipeline.deinit(dev);
        const quad = try dev.createBo(4096);
        var h: Hud = .{
            .gpa = gpa,
            .font = f,
            .cache = font.GlyphCache.init(gpa),
            .background = background,
            .screen = .{ 0, 0 },
            .width = 0,
            .height = 0,
            .scale = 1,
            .pixels = &.{},
            .dev = dev,
            .pipeline = pipeline,
            .quad = quad,
        };
        try h.resize(screen_width, screen_height);
        return h;
    }

    /// Lays the panel out for a new screen (or window) size.
    pub fn resize(h: *Hud, screen_width: u32, screen_height: u32) !void {
        if (h.screen[0] == screen_width and h.screen[1] == screen_height) return;
        const r = rect(screen_width, screen_height);
        h.gpa.free(h.pixels);
        h.pixels = try h.gpa.alloc(u32, @as(usize, r[2]) * r[3]);
        if (h.texture) |t| h.dev.destroyBo(t);
        h.texture = try h.dev.createBo(vc4.texture.imageSize(r[2], r[3]));
        h.drawn = @splat(0);
        h.screen = .{ screen_width, screen_height };
        h.width = r[2];
        h.height = r[3];
        h.scale = scaleFor(screen_width, screen_height);

        // Pixel rectangle to clip space; texture row 0 is the panel's top.
        const margin: f32 = @floatFromInt(r[0]);
        const sw: f32 = @floatFromInt(screen_width);
        const sh: f32 = @floatFromInt(screen_height);
        const x0 = margin / sw * 2 - 1;
        const x1 = (margin + @as(f32, @floatFromInt(h.width))) / sw * 2 - 1;
        const y0 = 1 - margin / sh * 2;
        const y1 = 1 - (margin + @as(f32, @floatFromInt(h.height))) / sh * 2;
        const quad = [16]f32{
            x0, y0, 0, 0,
            x0, y1, 0, 1,
            x1, y0, 1, 0,
            x1, y1, 1, 1,
        };
        @memcpy(h.quad.map[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    }

    /// The rows of band `i` (0 = the title, then each line): from 30 above
    /// a line's baseline to 10 below, which holds its ascenders and
    /// descenders.
    fn band(h: *const Hud, i: usize) [2]u32 {
        const s = h.scale;
        const top: f32 = if (i == 0) 0 else (70 + @as(f32, @floatFromInt(i - 1)) * 40) * s;
        const bottom: f32 = if (i == lines) @floatFromInt(h.height) else (70 + @as(f32, @floatFromInt(i)) * 40) * s;
        return .{ @intFromFloat(@floor(top)), @min(@as(u32, @intFromFloat(@floor(bottom))), h.height) };
    }

    /// Redraws and uploads the lines whose text changed.
    pub fn update(h: *Hud, text: [lines][]const u8) !void {
        const s = h.scale;
        var dirty: ?[2]u32 = null;
        for (0..lines + 1) |i| {
            const str = if (i == 0) "Stardust" else text[i - 1];
            const hash = std.hash.Wyhash.hash(if (i == 0) std.hash.Wyhash.hash(0, h.subtitle) else 0, str) | 1;
            if (hash == h.drawn[i]) continue;
            h.drawn[i] = hash;
            const rows = h.band(i);
            if (rows[1] <= rows[0]) continue;
            // Draw into the band alone, so glyphs cannot reach other lines.
            const canvas: font.Canvas = .{
                .pixels = h.pixels[rows[0] * h.width .. rows[1] * h.width],
                .width = h.width,
                .height = rows[1] - rows[0],
                .stride = h.width,
            };
            canvas.fill(0, 0, h.width, rows[1] - rows[0], h.background);
            const baseline = (if (i == 0) 52 else 100 + @as(f32, @floatFromInt(i - 1)) * 40) * s - @as(f32, @floatFromInt(rows[0]));
            const style: font.Style = if (i == 0)
                .{ .font = h.font, .size = 52 * s, .color = title_color }
            else
                .{ .font = h.font, .size = 28 * s, .color = if (i == 1) text_color else dim_color };
            _ = try font.draw(canvas, &h.cache, style, 0, baseline, str);
            if (i == 0 and h.subtitle.len > 0) {
                const x = font.measure(style, str) + 16 * s;
                _ = try font.draw(canvas, &h.cache, .{ .font = h.font, .size = 28 * s, .color = dim_color }, x, baseline, h.subtitle);
            }
            dirty = if (dirty) |d| .{ @min(d[0], rows[0]), @max(d[1], rows[1]) } else rows;
        }
        const d = dirty orelse return;
        // The canvas's 0xAARRGGBB words are the texture's B, G, R, A bytes,
        // so only the changed rows are tiled into it. The previous frame has
        // finished rendering, so the GPU is not reading it.
        vc4.texture.uploadRect(h.texture.?.map, h.width, h.height, .{ .x = 0, .y = d[0], .width = h.width, .height = d[1] - d[0] }, h.pixels[d[0] * h.width .. d[1] * h.width], h.width);
    }

    /// Draws the panel over whatever is in the frame.
    pub fn draw(h: *Hud, frame: *vc4.render.Frame) !void {
        try h.pipeline.draw(frame, .{
            .vertices = h.quad.handle,
            .count = 4,
            // One texel per pixel.
            .texture = .{ .handle = h.texture.?.handle, .config = .{
                .width = h.width,
                .height = h.height,
                .mag_filter = .nearest,
                .min_filter = .nearest,
                .wrap_s = .clamp,
                .wrap_t = .clamp,
            } },
        });
    }
};

test "the cube never reaches the panel" {
    // Full screens, and windows below the shell's bar.
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 }, .{ 640, 480 }, .{ 1920, 1036 }, .{ 1280, 691 } }) |size| {
        const w: f32 = @floatFromInt(size[0]);
        const h: f32 = @floatFromInt(size[1]);
        const r = Hud.rect(size[0], size[1]);
        // The panel's nearest point to the centre of the screen is its
        // bottom right corner; the cube must stay within a circle around
        // the centre that does not reach it.
        const clear = std.math.hypot(w / 2 - @as(f32, @floatFromInt(r[0] + r[2])), h / 2 - @as(f32, @floatFromInt(r[1] + r[3])));
        var t: f32 = 0;
        while (t < 20) : (t += 0.01) {
            const m = cube.mvp(size[0], size[1], t);
            for (0..8) |i| {
                const p = [3]f32{ if (i & 1 != 0) 1 else -1, if (i & 2 != 0) 1 else -1, if (i & 4 != 0) 1 else -1 };
                const cw = p[0] * m[3] + p[1] * m[7] + p[2] * m[11] + m[15];
                const x = (p[0] * m[0] + p[1] * m[4] + p[2] * m[8] + m[12]) / cw * w / 2;
                const y = (p[0] * m[1] + p[1] * m[5] + p[2] * m[9] + m[13]) / cw * h / 2;
                try std.testing.expect(std.math.hypot(x, y) < clear);
            }
        }
    }
}
