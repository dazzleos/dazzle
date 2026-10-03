//! Shaders for the demos, written against the compiler's builder API.
//!
//! Each vertex/coordinate shader pair reads the same attribute layout. The
//! comments give the GLSL each program corresponds to.

const compiler = @import("compiler.zig");

const Shader = compiler.Shader;
const Value = compiler.Value;

/// Writes the shaded-vertex header every vertex shader starts its output
/// with: Xs|Ys (12.4 fixed point screen offsets), Zs and 1/Wc.
fn writeScreenHeader(s: *Shader, xs: Value, ys: Value, zs: Value, rcp_w: Value) void {
    s.vpmWrite(s.packScreenXy(xs, ys));
    s.vpmWrite(zs);
    s.vpmWrite(rcp_w);
}

// --- Flat-shaded triangle (same as the hand-written shaders.zig) -------------
//
// attribute vec2 pos; attribute vec3 color; varying vec3 v_color;
// gl_Position = vec4(pos, 0, 1); v_color = color;
// gl_FragColor = vec4(v_color, 1);
//
// Uniforms: 0 = viewport x scale, 1 = viewport y scale (1/16 px units).

pub const triangle = struct {
    pub fn vertex() Shader {
        var s = Shader.init(.vertex);
        const x = s.vpmRead();
        const y = s.vpmRead();
        const r = s.vpmRead();
        const g = s.vpmRead();
        const b = s.vpmRead();
        writeScreenHeader(&s, s.fmul(x, s.uniform(0)), s.fmul(y, s.uniform(1)), s.constantF(0.5), s.constantF(1.0));
        s.vpmWrite(r);
        s.vpmWrite(g);
        s.vpmWrite(b);
        return s;
    }

    pub fn coordinate() Shader {
        var s = Shader.init(.coordinate);
        const x = s.vpmRead();
        const y = s.vpmRead();
        s.vpmWrite(x);
        s.vpmWrite(y);
        s.vpmWrite(s.constantF(0.0));
        s.vpmWrite(s.constantF(1.0));
        writeScreenHeader(&s, s.fmul(x, s.uniform(0)), s.fmul(y, s.uniform(1)), s.constantF(0.5), s.constantF(1.0));
        return s;
    }

    pub fn fragment() Shader {
        var s = Shader.init(.fragment);
        const r = s.varying();
        const g = s.varying();
        const b = s.varying();
        // B8G8R8A8 render target: blue is byte 0.
        s.tlbColor(s.packUnorm8888(b, g, r, s.constantF(1.0)));
        return s;
    }
};

// --- Spinning triangle ---------------------------------------------------------
//
// uniform mat2 m; uniform vec2 viewport_scale;
// gl_Position = vec4(m * pos, 0, 1);
//
// Uniforms: 0-3 = m (column-major: m00, m10, m01, m11), 4 = viewport x
// scale, 5 = viewport y scale. The fragment shader is triangle.fragment.

pub const spin = struct {
    pub const num_uniforms = 6;

    fn transform(s: *Shader, x: Value, y: Value) [2]Value {
        const cx = s.fadd(s.fmul(x, s.uniform(0)), s.fmul(y, s.uniform(2)));
        const cy = s.fadd(s.fmul(x, s.uniform(1)), s.fmul(y, s.uniform(3)));
        return .{ cx, cy };
    }

    pub fn vertex() Shader {
        var s = Shader.init(.vertex);
        const x = s.vpmRead();
        const y = s.vpmRead();
        const r = s.vpmRead();
        const g = s.vpmRead();
        const b = s.vpmRead();
        const c = transform(&s, x, y);
        writeScreenHeader(&s, s.fmul(c[0], s.uniform(4)), s.fmul(c[1], s.uniform(5)), s.constantF(0.5), s.constantF(1.0));
        s.vpmWrite(r);
        s.vpmWrite(g);
        s.vpmWrite(b);
        return s;
    }

    pub fn coordinate() Shader {
        var s = Shader.init(.coordinate);
        const x = s.vpmRead();
        const y = s.vpmRead();
        const c = transform(&s, x, y);
        s.vpmWrite(c[0]);
        s.vpmWrite(c[1]);
        s.vpmWrite(s.constantF(0.0));
        s.vpmWrite(s.constantF(1.0));
        writeScreenHeader(&s, s.fmul(c[0], s.uniform(4)), s.fmul(c[1], s.uniform(5)), s.constantF(0.5), s.constantF(1.0));
        return s;
    }
};

// --- Textured, depth-tested cube ----------------------------------------------
//
// uniform mat4 mvp; uniform vec2 viewport_scale; uniform sampler2D tex;
// attribute vec3 pos; attribute vec2 uv; attribute vec3 tint;
// gl_Position = mvp * vec4(pos, 1); v_uv = uv; v_tint = tint;
// gl_FragColor = vec4(texture2D(tex, v_uv).rgb * v_tint, 1);
//
// Uniforms: 0-15 = mvp (column-major), 16 = viewport x scale, 17 =
// viewport y scale. Depth range [0, 1].

pub const cube = struct {
    pub const num_uniforms = 18;
    /// Attribute words: position (3), texture coordinate (2), tint (3).
    pub const words_per_vertex = 8;
    pub const num_varyings = 5;

    /// Clip-space position: mvp * vec4(x, y, z, 1).
    fn clipPosition(s: *Shader, x: Value, y: Value, z: Value) [4]Value {
        var out: [4]Value = undefined;
        for (&out, 0..) |*o, row| {
            const r: u32 = @intCast(row);
            o.* = s.fadd(
                s.fadd(s.fmul(x, s.uniform(0 + r)), s.fmul(y, s.uniform(4 + r))),
                s.fadd(s.fmul(z, s.uniform(8 + r)), s.uniform(12 + r)),
            );
        }
        return out;
    }

    /// Perspective divide and viewport transform; writes the shaded vertex
    /// header.
    fn screenHeader(s: *Shader, c: [4]Value) void {
        const rcp_w = s.recip(c[3]);
        const xs = s.fmul(s.fmul(c[0], s.uniform(16)), rcp_w);
        const ys = s.fmul(s.fmul(c[1], s.uniform(17)), rcp_w);
        const half = s.constantF(0.5);
        const zs = s.fadd(s.fmul(s.fmul(c[2], half), rcp_w), half);
        writeScreenHeader(s, xs, ys, zs, rcp_w);
    }

    pub fn vertex() Shader {
        var s = Shader.init(.vertex);
        var attr: [words_per_vertex]Value = undefined;
        for (&attr) |*a| a.* = s.vpmRead();
        screenHeader(&s, clipPosition(&s, attr[0], attr[1], attr[2]));
        for (attr[3..]) |a| s.vpmWrite(a); // u, v, tint r, g, b
        return s;
    }

    pub fn coordinate() Shader {
        var s = Shader.init(.coordinate);
        const x = s.vpmRead();
        const y = s.vpmRead();
        const z = s.vpmRead();
        const c = clipPosition(&s, x, y, z);
        for (c) |v| s.vpmWrite(v);
        screenHeader(&s, c);
        return s;
    }

    pub fn fragment() Shader {
        var s = Shader.init(.fragment);
        const u = s.varying();
        const v = s.varying();
        const tint = [3]Value{ s.varying(), s.varying(), s.varying() };
        const texel = s.texture(u, v);
        // Texels and the render target are both stored B, G, R, A.
        const b = s.fmul(s.unpackUnorm8(texel, 0), tint[2]);
        const g = s.fmul(s.unpackUnorm8(texel, 1), tint[1]);
        const r = s.fmul(s.unpackUnorm8(texel, 2), tint[0]);
        s.tlbZ(s.fragZ());
        s.tlbColor(s.packUnorm8888(b, g, r, s.constantF(1.0)));
        return s;
    }
};

// --- Tests ---------------------------------------------------------------------

const std = @import("std");
const qpu = @import("qpu.zig");
const sim = @import("qpu_sim.zig");
const shaders = @import("shaders.zig");
const texture = @import("vc4/texture.zig");
const testing = std.testing;

/// Builds a shader's uniform stream from its layout.
fn uniformStream(buf: []u32, c: *const compiler.Compiled, user: []const u32, tex: [2]u32) []const u32 {
    for (c.uniforms(), 0..) |k, i| buf[i] = switch (k) {
        .user => |idx| user[idx],
        .tex_p0 => tex[0],
        .tex_p1 => tex[1],
    };
    return buf[0..c.uniforms().len];
}

fn f2u(v: f32) u32 {
    return @bitCast(v);
}
fn u2f(v: u32) f32 {
    return @bitCast(v);
}

fn lane(comptime base: f32, comptime step: f32) sim.Vec {
    var v: sim.Vec = undefined;
    for (&v, 0..) |*e, i| e.* = f2u(base + step * @as(f32, @floatFromInt(i)));
    return v;
}

fn expectSameRun(a: sim.Result, b: sim.Result) !void {
    try testing.expectEqual(a.vpm_out_len, b.vpm_out_len);
    for (a.vpmOut(), b.vpmOut()) |va, vb| try testing.expectEqualSlices(u32, &va, &vb);
    try testing.expectEqual(a.tlb_color, b.tlb_color);
}

test "compiled triangle shaders match the hand-written ones" {
    const user = [_]u32{ f2u(960.0 * 16.0), f2u(-540.0 * 16.0) };
    var buf: [64]u32 = undefined;
    const attrs = [_]sim.Vec{ lane(-1, 0.125), lane(0.9, -0.1), lane(0, 0.06), lane(1, -0.06), lane(0.5, 0) };

    const vs = try compiler.compile(&triangle.vertex());
    const hand_vs = try shaders.vertex();
    try expectSameRun(
        try sim.run(hand_vs.code(), .{ .uniforms = &user, .vpm_in = &attrs }),
        try sim.run(vs.code(), .{ .uniforms = uniformStream(&buf, &vs, &user, .{ 0, 0 }), .vpm_in = &attrs }),
    );

    const cs = try compiler.compile(&triangle.coordinate());
    const hand_cs = try shaders.coordinate();
    try expectSameRun(
        try sim.run(hand_cs.code(), .{ .uniforms = &user, .vpm_in = attrs[0..2] }),
        try sim.run(cs.code(), .{ .uniforms = uniformStream(&buf, &cs, &user, .{ 0, 0 }), .vpm_in = attrs[0..2] }),
    );

    const fs = try compiler.compile(&triangle.fragment());
    const hand_fs = try shaders.fragment();
    const vary = attrs[2..5];
    try expectSameRun(
        try sim.run(hand_fs.code(), .{ .varyings = vary, .frag_w = sim.splatF(3.0) }),
        try sim.run(fs.code(), .{ .varyings = vary, .frag_w = sim.splatF(3.0) }),
    );
}

test "compiled triangle shaders are no longer than the hand-written ones" {
    try testing.expect((try compiler.compile(&triangle.vertex())).code().len <= (try shaders.vertex()).len);
    try testing.expect((try compiler.compile(&triangle.coordinate())).code().len <= (try shaders.coordinate()).len);
    try testing.expect((try compiler.compile(&triangle.fragment())).code().len <= (try shaders.fragment()).len);
}

test "shaders consume exactly the uniforms in their layout" {
    var user: [cube.num_uniforms]u32 = undefined;
    for (&user, 0..) |*e, i| e.* = f2u(@floatFromInt(i + 1));
    var buf: [64]u32 = undefined;
    const attrs = [_]sim.Vec{lane(0.1, 0.01)} ** 8;
    inline for (.{ cube.vertex, cube.coordinate, spin.vertex, spin.coordinate }) |f| {
        const c = try compiler.compile(&f());
        const stream = uniformStream(&buf, &c, &user, .{ 0, 0 });
        const r = try sim.run(c.code(), .{ .uniforms = stream, .vpm_in = attrs[0..c.num_vpm_reads] });
        try testing.expectEqual(stream.len, r.uniforms_read);
    }
}

test "spinning triangle vertex shader" {
    const angle: f32 = 0.7;
    const m = [4]f32{ @cos(angle), @sin(angle), -@sin(angle), @cos(angle) };
    const scale = [2]f32{ 640 * 16, -360 * 16 };
    const user = [_]u32{ f2u(m[0]), f2u(m[1]), f2u(m[2]), f2u(m[3]), f2u(scale[0]), f2u(scale[1]) };
    var buf: [64]u32 = undefined;
    const attrs = [_]sim.Vec{ lane(-1, 0.125), lane(0.9, -0.1), lane(0, 0.06), lane(1, -0.06), lane(0.5, 0) };
    const vs = try compiler.compile(&spin.vertex());
    const r = try sim.run(vs.code(), .{ .uniforms = uniformStream(&buf, &vs, &user, .{ 0, 0 }), .vpm_in = &attrs });
    try testing.expectEqual(@as(usize, 6), r.vpm_out_len);
    for (0..sim.lanes) |i| {
        const x = u2f(attrs[0][i]);
        const y = u2f(attrs[1][i]);
        const cx = x * m[0] + y * m[2];
        const cy = x * m[1] + y * m[3];
        try testing.expectEqual(sim.packScreenXy(cx * scale[0], cy * scale[1]), r.vpm_out[0][i]);
        try testing.expectEqual(attrs[4][i], r.vpm_out[5][i]);
    }
    const cs = try compiler.compile(&spin.coordinate());
    const rc = try sim.run(cs.code(), .{ .uniforms = uniformStream(&buf, &cs, &user, .{ 0, 0 }), .vpm_in = attrs[0..2] });
    try testing.expectEqual(@as(usize, 7), rc.vpm_out_len);
}

fn testMvp() [16]f32 {
    // A perspective-ish matrix with every element non-zero.
    var m: [16]f32 = undefined;
    for (&m, 0..) |*e, i| e.* = 0.1 * @as(f32, @floatFromInt(i + 1)) * (if (i % 3 == 0) @as(f32, -1.0) else 1.0);
    m[15] = 4.0; // keep w positive
    return m;
}

test "cube vertex and coordinate shaders" {
    const m = testMvp();
    var user: [cube.num_uniforms]u32 = undefined;
    for (m, 0..) |e, i| user[i] = f2u(e);
    user[16] = f2u(400 * 16);
    user[17] = f2u(-300 * 16);
    var buf: [64]u32 = undefined;
    const attrs = [_]sim.Vec{
        lane(-1, 0.13), lane(1, -0.12), lane(-0.5, 0.07), // position
        lane(0, 0.06), lane(1, -0.05), // uv
        lane(0.2, 0.0), lane(0.4, 0.01), lane(0.6, 0.02), // tint
    };
    const vs = try compiler.compile(&cube.vertex());
    try testing.expectEqual(@as(u32, cube.words_per_vertex), vs.num_vpm_reads);
    const r = try sim.run(vs.code(), .{ .uniforms = uniformStream(&buf, &vs, &user, .{ 0, 0 }), .vpm_in = &attrs });
    try testing.expectEqual(@as(usize, 3 + cube.num_varyings), r.vpm_out_len);

    const cs = try compiler.compile(&cube.coordinate());
    const rc = try sim.run(cs.code(), .{ .uniforms = uniformStream(&buf, &cs, &user, .{ 0, 0 }), .vpm_in = attrs[0..3] });
    try testing.expectEqual(@as(usize, 7), rc.vpm_out_len);

    for (0..sim.lanes) |i| {
        const p = [4]f32{ u2f(attrs[0][i]), u2f(attrs[1][i]), u2f(attrs[2][i]), 1.0 };
        var c: [4]f32 = undefined;
        for (&c, 0..) |*o, row| o.* = p[0] * m[row] + p[1] * m[4 + row] + p[2] * m[8 + row] + p[3] * m[12 + row];
        const rw = 1.0 / c[3];
        for (0..4) |k| try testing.expectApproxEqRel(c[k], u2f(rc.vpm_out[k][i]), 1e-5);
        // Screen coordinates are truncated to 1/16 px, so allow one unit for
        // the different order the shader sums the matrix terms in.
        const xy = r.vpm_out[0][i];
        const got_x: i16 = @bitCast(@as(u16, @truncate(xy)));
        const got_y: i16 = @bitCast(@as(u16, @truncate(xy >> 16)));
        try testing.expect(@abs(@as(f32, @floatFromInt(got_x)) - @trunc(c[0] * 400 * 16 * rw)) <= 1);
        try testing.expect(@abs(@as(f32, @floatFromInt(got_y)) - @trunc(c[1] * -300 * 16 * rw)) <= 1);
        try testing.expectApproxEqRel(c[2] * 0.5 * rw + 0.5, u2f(r.vpm_out[1][i]), 1e-5);
        try testing.expectApproxEqRel(rw, u2f(r.vpm_out[2][i]), 1e-6);
        for (0..cube.num_varyings) |k| try testing.expectEqual(attrs[3 + k][i], r.vpm_out[3 + k][i]);
        // The coordinate shader's header matches the vertex shader's.
        for (0..3) |k| try testing.expectEqual(r.vpm_out[k][i], rc.vpm_out[4 + k][i]);
    }
}

test "cube fragment shader samples and tints the texture" {
    const w = 64;
    const h = 64;
    var pixels: [w * h]u32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = 0xff000000 | @as(u32, @intCast(i * 2654435761 % 0xffffff));
    var memory: [texture.imageSize(w, h)]u8 = undefined;
    texture.upload(&memory, &pixels, w, h);
    const cfg: texture.Config = .{ .width = w, .height = h, .mag_filter = .nearest, .min_filter = .nearest };

    const fs = try compiler.compile(&cube.fragment());
    try testing.expectEqual(@as(u32, 1), fs.num_texture_samples);
    var buf: [8]u32 = undefined;
    const stream = uniformStream(&buf, &fs, &.{}, .{ texture.p0(cfg), texture.p1(cfg) });
    try testing.expectEqual(@as(usize, 2), stream.len);

    const varyings = [_]sim.Vec{
        lane(0.5 / 64.0, 3.0 / 64.0), lane(10.5 / 64.0, 2.0 / 64.0), // texel centres
        lane(1.0, 0),                 lane(0.5, 0),
        lane(0.25, 0),
    };
    const r = try sim.run(fs.code(), .{ .uniforms = stream, .varyings = &varyings, .frag_w = sim.splatF(1.5), .frag_z = sim.splat(0x123456), .texture_memory = &memory });
    try testing.expectEqual(@as(usize, 1), r.texture_samples);
    try testing.expectEqualSlices(u32, &sim.splat(0x123456), &r.tlb_z.?);
    for (0..sim.lanes) |i| {
        const x: usize = 3 * i;
        const y: usize = 10 + 2 * i;
        const t = pixels[y * w + x];
        const ch = struct {
            fn f(v: u32, s: u5) f32 {
                return @as(f32, @floatFromInt((v >> s) & 0xff)) / 255.0;
            }
        }.f;
        try testing.expectEqual(sim.packColor(ch(t, 16) * 1.0, ch(t, 8) * 0.5, ch(t, 0) * 0.25, 1.0), r.tlb_color.?[i]);
    }
}
