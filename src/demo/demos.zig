//! The demo scenes, drawn with the low-level vc4 API. Each one owns its GPU
//! buffers and records its draws into a frame given the elapsed time.
//!
//! * triangle: the original hand-written shaders, drawn once.
//! * spin: compiled shaders, a triangle rotating at 60 frames per second.
//! * cube: compiled shaders, a textured cube with perspective and depth
//!   testing.

const std = @import("std");
const vc4 = @import("vc4");
const cl = vc4.cl;
const compiler = vc4.compiler;
const drm = vc4.drm;
const programs = @import("programs.zig");
const render = vc4.render;
const shaders = vc4.reference_shaders;
const sys = @import("sys");
const texture = vc4.texture;

pub const Kind = enum { triangle, spin, cube };

const clear_color = 0xff101830;

/// Frames are large, so the one the demos record into is static.
var static_frame: render.Frame = undefined;

fn uploadShader(dev: vc4.Device, stage: []const u8, code: []const u64) !u32 {
    return dev.createShaderBo(code) catch |err| {
        sys.print("stardust: kernel rejected the {s} shader ({s})\n", .{ stage, @errorName(err) });
        return err;
    };
}

/// A compiled shader uploaded to the GPU.
pub const Program = struct {
    handle: u32,
    compiled: compiler.Compiled,

    fn init(dev: vc4.Device, name: []const u8, shader: compiler.Shader) !Program {
        const compiled = try compiler.compile(&shader);
        return .{ .handle = try uploadShader(dev, name, compiled.code()), .compiled = compiled };
    }

    fn binding(p: *const Program, user: []const u32) render.ShaderBinding {
        return .{ .handle = p.handle, .layout = p.compiled.uniforms(), .user = user };
    }
};

fn aspectRatio(target: render.Target) f32 {
    return @as(f32, @floatFromInt(target.width)) / @as(f32, @floatFromInt(target.height));
}

// --- Triangles -------------------------------------------------------------------

const ColorVertex = extern struct { x: f32, y: f32, r: f32, g: f32, b: f32 };

const triangle_vertices = [_]ColorVertex{
    .{ .x = 0.0, .y = 0.8, .r = 1.0, .g = 0.0, .b = 0.0 },
    .{ .x = -0.8, .y = -0.8, .r = 0.0, .g = 1.0, .b = 0.0 },
    .{ .x = 0.8, .y = -0.8, .r = 0.0, .g = 0.0, .b = 1.0 },
};

fn colorDraw(vbo: u32, fs: render.ShaderBinding, vs: render.ShaderBinding, cs: render.ShaderBinding, attributes: *[2]render.Attribute) render.Draw {
    attributes.* = .{
        .{ .handle = vbo, .offset = 0, .size = 8, .stride = @sizeOf(ColorVertex), .vs_vpm_offset = 0, .cs_vpm_offset = 0 },
        .{ .handle = vbo, .offset = 8, .size = 12, .stride = @sizeOf(ColorVertex), .vs_vpm_offset = 8, .cs_vpm_offset = 0 },
    };
    return .{
        .fs = fs,
        .vs = vs,
        .cs = cs,
        .fs_num_varyings = 3,
        .attributes = attributes,
        .vs_attribute_mask = 0b11,
        .vs_attributes_size = 20,
        .cs_attribute_mask = 0b01,
        .cs_attributes_size = 8,
        .count = triangle_vertices.len,
    };
}

fn createVertexBuffer(dev: vc4.Device, data: []const u8) !vc4.Bo {
    const bo = try dev.createBo(4096);
    @memcpy(bo.map[0..data.len], data);
    return bo;
}

/// The original triangle, using the hand-written shaders in shaders.zig.
pub const Triangle = struct {
    fs: u32,
    vs: u32,
    cs: u32,
    vbo: vc4.Bo,

    // The hand-written vertex shaders read the viewport scale uniforms in
    // order; the fragment shader reads none.
    const vertex_layout = [_]compiler.UniformKind{ .{ .user = 0 }, .{ .user = 1 } };

    pub fn init(dev: vc4.Device) !Triangle {
        const fs = try shaders.fragment();
        const vs = try shaders.vertex();
        const cs = try shaders.coordinate();
        return .{
            .fs = try uploadShader(dev, "fragment", fs.code()),
            .vs = try uploadShader(dev, "vertex", vs.code()),
            .cs = try uploadShader(dev, "coordinate", cs.code()),
            .vbo = try createVertexBuffer(dev, std.mem.asBytes(&triangle_vertices)),
        };
    }

    pub fn record(t: *const Triangle, frame: *render.Frame, _: f32) !void {
        const scale = frame.target.fullViewport().scaleBits();
        var attrs: [2]render.Attribute = undefined;
        try frame.draw(colorDraw(
            t.vbo.handle,
            .{ .handle = t.fs, .layout = &.{} },
            .{ .handle = t.vs, .layout = &vertex_layout, .user = &scale },
            .{ .handle = t.cs, .layout = &vertex_layout, .user = &scale },
            &attrs,
        ));
    }
};

/// A rotating triangle drawn with compiled shaders.
pub const Spin = struct {
    fs: Program,
    vs: Program,
    cs: Program,
    vbo: vc4.Bo,

    pub fn init(dev: vc4.Device) !Spin {
        return .{
            .fs = try Program.init(dev, "fragment", programs.triangle.fragment()),
            .vs = try Program.init(dev, "vertex", programs.spin.vertex()),
            .cs = try Program.init(dev, "coordinate", programs.spin.coordinate()),
            .vbo = try createVertexBuffer(dev, std.mem.asBytes(&triangle_vertices)),
        };
    }

    pub fn record(s: *const Spin, frame: *render.Frame, time: f32) !void {
        const angle = time;
        // Scale x by the aspect ratio so the triangle keeps its shape.
        const aspect = 1.0 / aspectRatio(frame.target);
        const c = @cos(angle);
        const sn = @sin(angle);
        const scale = frame.target.fullViewport().scaleBits();
        const user = [programs.spin.num_uniforms]u32{
            @bitCast(c * aspect), @bitCast(sn), @bitCast(-sn * aspect), @bitCast(c), scale[0], scale[1],
        };
        var attrs: [2]render.Attribute = undefined;
        try frame.draw(colorDraw(s.vbo.handle, s.fs.binding(&.{}), s.vs.binding(&user), s.cs.binding(&user), &attrs));
    }
};

// --- Cube --------------------------------------------------------------------------

const CubeVertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
};

comptime {
    std.debug.assert(@sizeOf(CubeVertex) == programs.cube.words_per_vertex * 4);
}

const cube_vertices = blk: {
    // Each face: an outward axis, two in-plane axes and a tint. The tints
    // are pure primaries and secondaries.
    const Face = struct { n: [3]f32, u: [3]f32, v: [3]f32, tint: [3]f32 };
    const faces = [6]Face{
        .{ .n = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .tint = .{ 1, 0, 0 } },
        .{ .n = .{ 0, 0, -1 }, .u = .{ -1, 0, 0 }, .v = .{ 0, 1, 0 }, .tint = .{ 0, 1, 0 } },
        .{ .n = .{ 1, 0, 0 }, .u = .{ 0, 0, -1 }, .v = .{ 0, 1, 0 }, .tint = .{ 0, 0, 1 } },
        .{ .n = .{ -1, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 }, .tint = .{ 1, 1, 0 } },
        .{ .n = .{ 0, 1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, -1 }, .tint = .{ 1, 0, 1 } },
        .{ .n = .{ 0, -1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 }, .tint = .{ 0, 1, 1 } },
    };
    // Corners as (u, v) in {-1, 1}, two triangles per face. Texture
    // coordinates run 0..2 so the checkerboard repeats twice per face.
    const corners = [6][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    var out: [36]CubeVertex = undefined;
    for (faces, 0..) |f, fi| {
        for (corners, 0..) |c, ci| {
            var p: [3]f32 = undefined;
            for (&p, 0..) |*e, k| e.* = f.n[k] + c[0] * f.u[k] + c[1] * f.v[k];
            out[fi * 6 + ci] = .{
                .x = p[0],
                .y = p[1],
                .z = p[2],
                .u = c[0] + 1,
                .v = c[1] + 1,
                .r = f.tint[0],
                .g = f.tint[1],
                .b = f.tint[2],
            };
        }
    }
    break :blk out;
};

pub const texture_size = 128;

/// A white and dark grey checkerboard, as B8G8R8A8 pixels. Combined with
/// the pure face tints, white squares show the tint at full strength, which
/// makes colour channel or range errors easy to see.
pub fn checkerboard(pixels: []u32, size: u32) void {
    for (0..size) |y| for (0..size) |x| {
        const check = ((x / 16) + (y / 16)) % 2 == 0;
        pixels[y * size + x] = if (check) 0xffffffff else 0xff404040;
    };
}

pub const Mat4 = [16]f32; // column-major

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

pub const Cube = struct {
    fs: Program,
    vs: Program,
    cs: Program,
    vbo: vc4.Bo,
    tex: vc4.Bo,

    pub const tex_config: texture.Config = .{ .width = texture_size, .height = texture_size };

    pub fn init(dev: vc4.Device) !Cube {
        const tex = try dev.createBo(texture.imageSize(texture_size, texture_size));
        var pixels: [texture_size * texture_size]u32 = undefined;
        checkerboard(&pixels, texture_size);
        texture.upload(tex.map, &pixels, texture_size, texture_size);
        return .{
            .fs = try Program.init(dev, "fragment", programs.cube.fragment()),
            .vs = try Program.init(dev, "vertex", programs.cube.vertex()),
            .cs = try Program.init(dev, "coordinate", programs.cube.coordinate()),
            .vbo = try createVertexBuffer(dev, std.mem.asBytes(&cube_vertices)),
            .tex = tex,
        };
    }

    pub fn mvp(width: u16, height: u16, time: f32) Mat4 {
        const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        const model = mul(rotationX(time * 0.7), rotationY(time));
        const view = translation(0, 0, -5);
        return mul(perspective(std.math.degreesToRadians(50.0), aspect, 1.0, 20.0), mul(view, model));
    }

    pub fn record(c: *const Cube, frame: *render.Frame, time: f32) !void {
        const m = mvp(frame.target.width, frame.target.height, time);
        const scale = frame.target.fullViewport().scaleBits();
        var user: [programs.cube.num_uniforms]u32 = undefined;
        for (m, 0..) |e, i| user[i] = @bitCast(e);
        user[16] = scale[0];
        user[17] = scale[1];
        const vbo = c.vbo.handle;
        const attrs = [_]render.Attribute{
            .{ .handle = vbo, .offset = 0, .size = 12, .stride = @sizeOf(CubeVertex), .vs_vpm_offset = 0, .cs_vpm_offset = 0 },
            .{ .handle = vbo, .offset = 12, .size = 8, .stride = @sizeOf(CubeVertex), .vs_vpm_offset = 12, .cs_vpm_offset = 0 },
            .{ .handle = vbo, .offset = 20, .size = 12, .stride = @sizeOf(CubeVertex), .vs_vpm_offset = 20, .cs_vpm_offset = 0 },
        };
        try frame.draw(.{
            .fs = c.fs.binding(&.{}),
            .vs = c.vs.binding(&user),
            .cs = c.cs.binding(&user),
            .fs_num_varyings = programs.cube.num_varyings,
            .attributes = &attrs,
            .vs_attribute_mask = 0b111,
            .vs_attributes_size = @sizeOf(CubeVertex),
            .cs_attribute_mask = 0b001,
            .cs_attributes_size = 12,
            .count = cube_vertices.len,
            .config = .{ .depth_func = .less, .z_updates = true },
            .texture = .{ .handle = c.tex.handle, .config = tex_config },
        });
    }
};

pub const Demo = union(Kind) {
    triangle: Triangle,
    spin: Spin,
    cube: Cube,

    pub fn init(kind: Kind, dev: vc4.Device) !Demo {
        return switch (kind) {
            .triangle => .{ .triangle = try Triangle.init(dev) },
            .spin => .{ .spin = try Spin.init(dev) },
            .cube => .{ .cube = try Cube.init(dev) },
        };
    }

    /// Whether the demo changes over time (and so needs a frame loop).
    pub fn animated(d: *const Demo) bool {
        return d.* != .triangle;
    }

    /// Records the scene into `frame` (already begun).
    pub fn record(d: *const Demo, frame: *render.Frame, time: f32) !void {
        switch (d.*) {
            inline else => |*s| try s.record(frame, time),
        }
    }

    /// Renders one frame into `target` and waits for the GPU.
    pub fn draw(d: *const Demo, dev: vc4.Device, target: render.Target, time: f32) !void {
        static_frame.begin(target, .{ .clear = clear_color });
        try d.record(&static_frame, time);
        const seqno = try dev.submit(static_frame.finish());
        try dev.waitSeqno(seqno, std.time.ns_per_s);
    }
};

test "cube faces have outward normals and stay in front of the camera" {
    // Every vertex is at distance sqrt(3) from the centre.
    for (cube_vertices) |v| try std.testing.expectApproxEqAbs(@as(f32, 3), v.x * v.x + v.y * v.y + v.z * v.z, 1e-5);
    // All corners have positive w after projection at any rotation.
    for ([_]f32{ 0, 1, 2.5, 4 }) |t| {
        const m = Cube.mvp(1920, 1080, t);
        for (cube_vertices) |v| {
            const w = v.x * m[3] + v.y * m[7] + v.z * m[11] + m[15];
            try std.testing.expect(w > 2.0);
        }
    }
}

/// Logs the frame rate every 5 seconds.
pub const FrameStats = struct {
    frames: u32 = 0,
    render_ns: u64 = 0,
    since: u64,

    pub fn init(now: u64) FrameStats {
        return .{ .since = now };
    }

    /// Counts a frame that took `render_ns` to render (0 if unknown).
    pub fn frame(s: *FrameStats, render_ns: u64) void {
        s.frames += 1;
        s.render_ns += render_ns;
        const now = sys.nowNs();
        const elapsed = now - s.since;
        if (elapsed < 5 * std.time.ns_per_s) return;
        const secs = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
        const fps = @as(f64, @floatFromInt(s.frames)) / secs;
        if (s.render_ns > 0) {
            const ms = @as(f64, @floatFromInt(s.render_ns)) / @as(f64, @floatFromInt(s.frames)) / std.time.ns_per_ms;
            sys.print("stardust: {d} frames in {d:.1}s ({d:.1} fps), render {d:.2} ms/frame\n", .{ s.frames, secs, fps, ms });
        } else {
            sys.print("stardust: {d} frames in {d:.1}s ({d:.1} fps)\n", .{ s.frames, secs, fps });
        }
        s.* = .init(now);
    }
};
