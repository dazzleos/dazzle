//! The statistics overlay in the top left corner: text drawn by the CPU
//! with the font renderer into a texture, shown as an opaque quad on top of
//! the scene. The panel's background is the scene's clear colour, so the
//! text appears to sit directly on the background (the GL layer has no
//! blending yet, so the quad cannot be translucent).

const std = @import("std");
const font = @import("font");
const gles = @import("gles");
const cube = @import("cube.zig");

const gl = gles.gl;

const vertex_shader =
    \\attribute vec2 pos;
    \\attribute vec2 uv;
    \\varying vec2 v_uv;
    \\void main() {
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\    v_uv = uv;
    \\}
;

const fragment_shader =
    \\precision mediump float;
    \\uniform sampler2D tex;
    \\varying vec2 v_uv;
    \\void main() {
    \\    gl_FragColor = texture2D(tex, v_uv);
    \\}
;

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
    rgba: []u8,
    program: gl.GLuint,
    texture: gl.GLuint,
    /// The quad as a triangle strip of (x, y, u, v) in clip space.
    quad: [16]f32,

    /// Lines of text the panel holds, below the title.
    pub const lines = 4;

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

    pub fn init(gpa: std.mem.Allocator, f: *const font.Font, screen_width: u32, screen_height: u32, background: u32) !Hud {
        const scale = scaleFor(screen_width, screen_height);
        const r = rect(screen_width, screen_height);
        const width = r[2];
        const height = r[3];
        const margin: f32 = @floatFromInt(r[0]);
        const program = try cube.buildProgram(vertex_shader, fragment_shader, &.{ "pos", "uv" });
        gl.glUseProgram(program);
        gl.glUniform1i(gl.glGetUniformLocation(program, "tex"), 0);
        var texture: gl.GLuint = 0;
        gl.glGenTextures(1, @ptrCast(&texture));

        // Pixel rectangle to clip space; texture row 0 is the panel's top.
        const sw: f32 = @floatFromInt(screen_width);
        const sh: f32 = @floatFromInt(screen_height);
        const x0 = margin / sw * 2 - 1;
        const x1 = (margin + @as(f32, @floatFromInt(width))) / sw * 2 - 1;
        const y0 = 1 - margin / sh * 2;
        const y1 = 1 - (margin + @as(f32, @floatFromInt(height))) / sh * 2;
        return .{
            .gpa = gpa,
            .font = f,
            .cache = font.GlyphCache.init(gpa),
            .background = background,
            .screen = .{ screen_width, screen_height },
            .width = width,
            .height = height,
            .scale = scale,
            .pixels = try gpa.alloc(u32, @as(usize, width) * height),
            .rgba = try gpa.alloc(u8, @as(usize, width) * height * 4),
            .program = program,
            .texture = texture,
            .quad = .{
                x0, y0, 0, 0,
                x0, y1, 0, 1,
                x1, y0, 1, 0,
                x1, y1, 1, 1,
            },
        };
    }

    /// Redraws the panel with new text and uploads it.
    pub fn update(h: *Hud, text: [lines][]const u8) !void {
        const canvas: font.Canvas = .{ .pixels = h.pixels, .width = h.width, .height = h.height, .stride = h.width };
        canvas.fill(0, 0, h.width, h.height, h.background);
        const s = h.scale;
        _ = try font.draw(canvas, &h.cache, .{ .font = h.font, .size = 52 * s, .color = title_color }, 0, 52 * s, "Stardust");
        for (text, 0..) |line, i| {
            const color: u32 = if (i == 0) text_color else dim_color;
            _ = try font.draw(canvas, &h.cache, .{ .font = h.font, .size = 28 * s, .color = color }, 0, (100 + @as(f32, @floatFromInt(i)) * 40) * s, line);
        }
        for (h.pixels, 0..) |p, i| h.rgba[i * 4 ..][0..4].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24) };
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, h.texture);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(h.width), @intCast(h.height), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, h.rgba.ptr);
        // One texel per pixel.
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    }

    /// Draws the panel over whatever is on screen.
    pub fn draw(h: *const Hud) void {
        gl.glUseProgram(h.program);
        gl.glDisable(gl.GL_DEPTH_TEST);
        gl.glDisable(gl.GL_CULL_FACE);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 16, &h.quad);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 16, &h.quad[2]);
        gl.glEnableVertexAttribArray(0);
        gl.glEnableVertexAttribArray(1);
        gl.glDisableVertexAttribArray(2);
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, h.texture);
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
    }
};

test "the cube never reaches the panel" {
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 }, .{ 640, 480 } }) |size| {
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
