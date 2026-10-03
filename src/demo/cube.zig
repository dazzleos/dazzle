//! The spinning cube: textured, tinted, depth-tested and back-face culled,
//! drawn with the vc4 API and its shader (shaders/cube.zig).

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");

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

pub const Cube = struct {
    pipeline: shader.Pipeline,
    vbo: vc4.Bo,
    ibo: vc4.Bo,
    texture: vc4.Bo,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !Cube {
        const program = shader.Program.decode(@embedFile("cube.shader")) catch unreachable;
        var pipeline = try shader.Pipeline.init(gpa, dev, program, .{
            .vertex_stride = @sizeOf(Vertex),
            .attributes = &.{
                .{ .location = 0, .offset = @offsetOf(Vertex, "pos") },
                .{ .location = 1, .offset = @offsetOf(Vertex, "uv") },
                .{ .location = 2, .offset = @offsetOf(Vertex, "tint") },
            },
            .cull = .back,
        });
        errdefer pipeline.deinit(dev);
        const vbo = try dev.createBo(@sizeOf(@TypeOf(vertices)));
        errdefer dev.destroyBo(vbo);
        @memcpy(vbo.map[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
        const ibo = try dev.createBo(@sizeOf(@TypeOf(indices)));
        errdefer dev.destroyBo(ibo);
        @memcpy(ibo.map[0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));

        // A white and dark grey checkerboard: with the pure face tints,
        // white squares show each tint at full strength.
        var pixels: [texture_size * texture_size]u32 = undefined;
        for (0..texture_size) |y| for (0..texture_size) |x| {
            pixels[y * texture_size + x] = if (((x / 16) + (y / 16)) % 2 == 0) 0xffffffff else 0xff404040;
        };
        const texture = try dev.createBo(vc4.texture.imageSize(texture_size, texture_size));
        vc4.texture.upload(texture.map, &pixels, texture_size, texture_size);
        return .{ .pipeline = pipeline, .vbo = vbo, .ibo = ibo, .texture = texture };
    }

    /// Draws the cube at `time` seconds into its rotation.
    pub fn draw(c: *Cube, frame: *vc4.render.Frame, width: u32, height: u32, time: f32) !void {
        const m = mvp(width, height, time);
        c.pipeline.setUniforms(std.mem.asBytes(&m));
        try c.pipeline.draw(frame, .{
            .vertices = c.vbo.handle,
            .count = indices.len,
            .indices = .{ .handle = c.ibo.handle, .offset = 0, .max_index = vertices.len - 1 },
            .texture = .{ .handle = c.texture.handle, .config = .{ .width = texture_size, .height = texture_size } },
        });
    }
};

// --- Matrices (column-major, as the shader expects) --------------------------------

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
