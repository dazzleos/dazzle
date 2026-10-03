//! The spinning cube: a textured, tinted cube drawn with OpenGL ES 2.0, as
//! a C program would draw it: GLSL shaders, vertex and index buffers, a
//! texture, depth testing and back-face culling.

const std = @import("std");
const sys = @import("sys");
const gles = @import("gles");

const gl = gles.gl;

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

/// Four corners per face, wound counter-clockwise seen from outside. The
/// tints are pure primaries and secondaries, so colour errors stand out.
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
    // Texture coordinates run 0..2 so the checkerboard repeats twice per face.
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

pub const triangles = indices.len / 3;

const texture_size = 128;
var texture_pixels: [texture_size * texture_size * 4]u8 = undefined;

pub fn compileShader(kind: gl.GLenum, source: [*:0]const u8) !gl.GLuint {
    const shader = gl.glCreateShader(kind);
    gl.glShaderSource(shader, 1, &[_][*]const u8{source}, null);
    gl.glCompileShader(shader);
    var status: gl.GLint = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, @ptrCast(&status));
    if (status == 0) {
        var log: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(shader, log.len, &len, &log);
        sys.print("stardust: shader compile failed:\n{s}\n", .{log[0..@intCast(len)]});
        return error.ShaderCompileFailed;
    }
    return shader;
}

/// Compiles and links a program, binding `attributes` to locations 0, 1, ...
pub fn buildProgram(vs_source: [*:0]const u8, fs_source: [*:0]const u8, attributes: []const [*:0]const u8) !gl.GLuint {
    const vs = try compileShader(gl.GL_VERTEX_SHADER, vs_source);
    defer gl.glDeleteShader(vs);
    const fs = try compileShader(gl.GL_FRAGMENT_SHADER, fs_source);
    defer gl.glDeleteShader(fs);
    const program = gl.glCreateProgram();
    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, fs);
    for (attributes, 0..) |name, i| gl.glBindAttribLocation(program, @intCast(i), name);
    gl.glLinkProgram(program);
    var status: gl.GLint = 0;
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, @ptrCast(&status));
    if (status == 0) {
        var log: [1024]u8 = undefined;
        var len: gl.GLsizei = 0;
        gl.glGetProgramInfoLog(program, log.len, &len, &log);
        sys.print("stardust: program link failed:\n{s}\n", .{log[0..@intCast(len)]});
        return error.ProgramLinkFailed;
    }
    return program;
}

pub const Cube = struct {
    program: gl.GLuint,
    mvp_location: gl.GLint,
    vbo: gl.GLuint,
    ibo: gl.GLuint,
    texture: gl.GLuint,

    pub fn init() !Cube {
        const program = try buildProgram(vertex_shader, fragment_shader, &.{ "pos", "uv", "tint" });
        gl.glUseProgram(program);
        gl.glUniform1i(gl.glGetUniformLocation(program, "tex"), 0);

        var buffers: [2]gl.GLuint = undefined;
        gl.glGenBuffers(2, &buffers);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffers[0]);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.GL_STATIC_DRAW);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
        gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, gl.GL_STATIC_DRAW);

        // A white and dark grey checkerboard: with the pure face tints,
        // white squares show each tint at full strength.
        for (0..texture_size) |y| for (0..texture_size) |x| {
            const v: u8 = if (((x / 16) + (y / 16)) % 2 == 0) 0xff else 0x40;
            texture_pixels[(y * texture_size + x) * 4 ..][0..4].* = .{ v, v, v, 0xff };
        };
        var texture: gl.GLuint = 0;
        gl.glGenTextures(1, @ptrCast(&texture));
        gl.glBindTexture(gl.GL_TEXTURE_2D, texture);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, texture_size, texture_size, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &texture_pixels);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

        return .{
            .program = program,
            .mvp_location = gl.glGetUniformLocation(program, "mvp"),
            .vbo = buffers[0],
            .ibo = buffers[1],
            .texture = texture,
        };
    }

    /// Draws the cube at `time` seconds into its rotation.
    pub fn draw(c: *const Cube, width: u32, height: u32, time: f32) void {
        gl.glUseProgram(c.program);
        gl.glEnable(gl.GL_DEPTH_TEST);
        gl.glEnable(gl.GL_CULL_FACE);
        gl.glCullFace(gl.GL_BACK);
        gl.glFrontFace(gl.GL_CCW);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, c.vbo);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, c.ibo);
        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "pos")));
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "uv")));
        gl.glVertexAttribPointer(2, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "tint")));
        for (0..3) |i| gl.glEnableVertexAttribArray(@intCast(i));
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, c.texture);
        const m = mvp(width, height, time);
        gl.glUniformMatrix4fv(c.mvp_location, 1, gl.GL_FALSE, &m);
        gl.glDrawElements(gl.GL_TRIANGLES, indices.len, gl.GL_UNSIGNED_SHORT, null);
    }
};

// --- Matrices (column-major, as GL expects) ----------------------------------

pub const Mat4 = [16]f32;

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[col * 4 + k];
        out[col * 4 + row] = sum;
    };
    return out;
}

pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy / 2.0);
    var m: Mat4 = @splat(0);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = 2 * far * near / (near - far);
    return m;
}

pub fn translation(x: f32, y: f32, z: f32) Mat4 {
    var m: Mat4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    m[12] = x;
    m[13] = y;
    m[14] = z;
    return m;
}

pub fn rotationX(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 };
}

pub fn rotationY(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 };
}

pub fn mvp(width: u32, height: u32, time: f32) Mat4 {
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const model = mul(rotationX(time * 0.7), rotationY(time));
    // Far enough back that the cube clears the statistics in the corner
    // (see hud.zig's test).
    const view = translation(0, 0, -6);
    return mul(perspective(std.math.degreesToRadians(50.0), aspect, 1.0, 20.0), mul(view, model));
}

const testing = std.testing;

test "every face is wound counter-clockwise seen from outside" {
    for (0..triangles) |tri| {
        const a = vertices[indices[tri * 3]].pos;
        const b = vertices[indices[tri * 3 + 1]].pos;
        const c = vertices[indices[tri * 3 + 2]].pos;
        const e1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const e2 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const n = [3]f32{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        const centre = [3]f32{ (a[0] + c[0]) / 2, (a[1] + c[1]) / 2, (a[2] + c[2]) / 2 };
        try testing.expect(n[0] * centre[0] + n[1] * centre[1] + n[2] * centre[2] > 0);
    }
}

test "the cube stays in front of the camera" {
    for ([_]f32{ 0, 1, 2.5, 4 }) |t| {
        const m = mvp(1920, 1080, t);
        for (vertices) |v| {
            const w = v.pos[0] * m[3] + v.pos[1] * m[7] + v.pos[2] * m[11] + m[15];
            try testing.expect(w > 2.0);
        }
    }
}
