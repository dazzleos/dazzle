//! The textured cube again, this time through OpenGL ES 2.0 and EGL,
//! written the way a C program would be: EGL setup, shaders compiled from
//! GLSL source, vertex and index buffers, a texture, then a frame loop of
//! glClear, glDrawElements and eglSwapBuffers.
//!
//! Unlike the vc4 cube it draws indexed geometry with back-face culling.

const std = @import("std");
const sys = @import("sys");
const gles = @import("gles");
const demos = @import("demos.zig");

const gl = gles.gl;
const egl = gles.egl;

const vertex_shader =
    \\attribute vec3 pos;
    \\attribute vec2 uv;
    \\attribute vec3 tint;
    \\uniform mat4 mvp;
    \\varying vec2 v_uv;
    \\varying vec3 v_tint;
    \\void main() {
    \\    gl_Position = mvp * vec4(pos, 1.0);
    \\    v_uv = uv;
    \\    v_tint = tint;
    \\}
;

const fragment_shader =
    \\precision mediump float;
    \\uniform sampler2D tex;
    \\varying vec2 v_uv;
    \\varying vec3 v_tint;
    \\void main() {
    \\    gl_FragColor = vec4(texture2D(tex, v_uv).rgb * v_tint, 1.0);
    \\}
;

const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    tint: [3]f32,
};

/// Four corners per face, wound counter-clockwise seen from outside.
const vertices = blk: {
    const Face = struct { n: [3]f32, u: [3]f32, v: [3]f32, tint: [3]f32 };
    const faces = [6]Face{
        .{ .n = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .tint = .{ 1, 0, 0 } },
        .{ .n = .{ 0, 0, -1 }, .u = .{ -1, 0, 0 }, .v = .{ 0, 1, 0 }, .tint = .{ 0, 1, 0 } },
        .{ .n = .{ 1, 0, 0 }, .u = .{ 0, 0, -1 }, .v = .{ 0, 1, 0 }, .tint = .{ 0, 0, 1 } },
        .{ .n = .{ -1, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 }, .tint = .{ 1, 1, 0 } },
        .{ .n = .{ 0, 1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, -1 }, .tint = .{ 1, 0, 1 } },
        .{ .n = .{ 0, -1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 }, .tint = .{ 0, 1, 1 } },
    };
    const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    var out: [24]Vertex = undefined;
    for (faces, 0..) |f, fi| for (corners, 0..) |c, ci| {
        var p: [3]f32 = undefined;
        for (&p, 0..) |*e, k| e.* = f.n[k] + c[0] * f.u[k] + c[1] * f.v[k];
        out[fi * 4 + ci] = .{ .pos = p, .uv = .{ c[0] + 1, c[1] + 1 }, .tint = f.tint };
    };
    break :blk out;
};

const indices = blk: {
    var out: [36]u16 = undefined;
    for (0..6) |f| for ([_]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |corner, i| {
        out[f * 6 + i] = @intCast(f * 4 + corner);
    };
    break :blk out;
};

const texture_size = 128;
var texture_pixels: [texture_size * texture_size * 4]u8 = undefined;

fn compileShader(kind: gl.GLenum, source: [*:0]const u8) !gl.GLuint {
    const shader = gl.glCreateShader(kind);
    gl.glShaderSource(shader, 1, &[_][*]const u8{source}, null);
    gl.glCompileShader(shader);
    var status: gl.GLint = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, @ptrCast(&status));
    if (status == 0) {
        var log: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(shader, log.len, &len, &log);
        sys.print("glcube: shader compile failed:\n{s}\n", .{log[0..@intCast(len)]});
        return error.ShaderCompileFailed;
    }
    return shader;
}

fn buildProgram() !gl.GLuint {
    const vs = try compileShader(gl.GL_VERTEX_SHADER, vertex_shader);
    defer gl.glDeleteShader(vs);
    const fs = try compileShader(gl.GL_FRAGMENT_SHADER, fragment_shader);
    defer gl.glDeleteShader(fs);
    const program = gl.glCreateProgram();
    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, fs);
    gl.glBindAttribLocation(program, 0, "pos");
    gl.glBindAttribLocation(program, 1, "uv");
    gl.glBindAttribLocation(program, 2, "tint");
    gl.glLinkProgram(program);
    var status: gl.GLint = 0;
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, @ptrCast(&status));
    if (status == 0) {
        var log: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;
        gl.glGetProgramInfoLog(program, log.len, &len, &log);
        sys.print("glcube: program link failed:\n{s}\n", .{log[0..@intCast(len)]});
        return error.ProgramLinkFailed;
    }
    return program;
}

/// Runs the demo until the process is stopped.
pub fn run() !void {
    const dpy = egl.eglGetDisplay(egl.EGL_DEFAULT_DISPLAY);
    if (egl.eglInitialize(dpy, null, null) == egl.EGL_FALSE) return error.EglInitializeFailed;
    defer _ = egl.eglTerminate(dpy);

    const config_attribs = [_]egl.EGLint{
        egl.EGL_RED_SIZE,        8,
        egl.EGL_GREEN_SIZE,      8,
        egl.EGL_BLUE_SIZE,       8,
        egl.EGL_DEPTH_SIZE,      24,
        egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
        egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_ES2_BIT,
        egl.EGL_NONE,
    };
    var config: egl.EGLConfig = null;
    var num_configs: egl.EGLint = 0;
    if (egl.eglChooseConfig(dpy, &config_attribs, @ptrCast(&config), 1, &num_configs) == egl.EGL_FALSE or num_configs == 0)
        return error.NoEglConfig;
    _ = egl.eglBindAPI(egl.EGL_OPENGL_ES_API);

    const surface = egl.eglCreateWindowSurface(dpy, config, 0, null);
    if (surface == egl.EGL_NO_SURFACE) return error.EglSurfaceFailed;
    defer _ = egl.eglDestroySurface(dpy, surface);
    const context_attribs = [_]egl.EGLint{ egl.EGL_CONTEXT_CLIENT_VERSION, 2, egl.EGL_NONE };
    const context = egl.eglCreateContext(dpy, config, egl.EGL_NO_CONTEXT, &context_attribs);
    if (context == egl.EGL_NO_CONTEXT) return error.EglContextFailed;
    defer _ = egl.eglDestroyContext(dpy, context);
    if (egl.eglMakeCurrent(dpy, surface, surface, context) == egl.EGL_FALSE) return error.EglMakeCurrentFailed;
    defer _ = egl.eglMakeCurrent(dpy, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);

    var width: egl.EGLint = 0;
    var height: egl.EGLint = 0;
    _ = egl.eglQuerySurface(dpy, surface, egl.EGL_WIDTH, &width);
    _ = egl.eglQuerySurface(dpy, surface, egl.EGL_HEIGHT, &height);
    sys.print("glcube: {s} on {s}, {d}x{d}\n", .{
        std.mem.span(gl.glGetString(gl.GL_VERSION).?),
        std.mem.span(gl.glGetString(gl.GL_RENDERER).?),
        width,
        height,
    });

    const program = try buildProgram();
    defer gl.glDeleteProgram(program);
    gl.glUseProgram(program);
    const mvp_location = gl.glGetUniformLocation(program, "mvp");
    gl.glUniform1i(gl.glGetUniformLocation(program, "tex"), 0);

    var buffers: [2]gl.GLuint = undefined;
    gl.glGenBuffers(2, &buffers);
    defer gl.glDeleteBuffers(2, &buffers);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffers[0]);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.GL_STATIC_DRAW);
    gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
    gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, gl.GL_STATIC_DRAW);
    gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "pos")));
    gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "uv")));
    gl.glVertexAttribPointer(2, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "tint")));
    for (0..3) |i| gl.glEnableVertexAttribArray(@intCast(i));

    // The same white and dark grey checkerboard as the vc4 cube.
    for (0..texture_size) |y| for (0..texture_size) |x| {
        const v: u8 = if (((x / 16) + (y / 16)) % 2 == 0) 0xff else 0x40;
        texture_pixels[(y * texture_size + x) * 4 ..][0..4].* = .{ v, v, v, 0xff };
    };
    var texture: gl.GLuint = 0;
    gl.glGenTextures(1, @ptrCast(&texture));
    defer gl.glDeleteTextures(1, @ptrCast(&texture));
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, texture_size, texture_size, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &texture_pixels);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glEnable(gl.GL_CULL_FACE);
    gl.glCullFace(gl.GL_BACK);
    gl.glFrontFace(gl.GL_CCW);
    gl.glViewport(0, 0, width, height);
    gl.glClearColor(16.0 / 255.0, 24.0 / 255.0, 48.0 / 255.0, 1.0);

    const err = gl.glGetError();
    if (err != gl.GL_NO_ERROR) sys.print("glcube: GL error 0x{x} during setup\n", .{err});

    const start = sys.nowNs();
    var stats: demos.FrameStats = .init(start);
    while (true) {
        const now = sys.nowNs();
        const t: f32 = @floatCast(@as(f64, @floatFromInt(now - start)) / std.time.ns_per_s);

        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
        const mvp = demos.Cube.mvp(@intCast(width), @intCast(height), t);
        gl.glUniformMatrix4fv(mvp_location, 1, gl.GL_FALSE, &mvp);
        gl.glDrawElements(gl.GL_TRIANGLES, indices.len, gl.GL_UNSIGNED_SHORT, null);
        if (egl.eglSwapBuffers(dpy, surface) == egl.EGL_FALSE) return error.EglSwapBuffersFailed;
        // The swap renders, waits for the GPU and then for the flip, so
        // only the frame time as a whole is meaningful here.
        stats.frame(0);
    }
}

test "every face is wound counter-clockwise seen from outside" {
    for (0..12) |tri| {
        const a = vertices[indices[tri * 3]].pos;
        const b = vertices[indices[tri * 3 + 1]].pos;
        const c = vertices[indices[tri * 3 + 2]].pos;
        const e1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const e2 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const n = [3]f32{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        // The normal points the same way as the face centre.
        const centre = [3]f32{ (a[0] + c[0]) / 2, (a[1] + c[1]) / 2, (a[2] + c[2]) / 2 };
        try std.testing.expect(n[0] * centre[0] + n[1] * centre[1] + n[2] * centre[2] > 0);
    }
}
