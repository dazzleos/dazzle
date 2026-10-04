//! Tests of Stardust's shader programs, as the build compiled them: run in
//! the QPU simulator and checked against the same maths done here, and
//! compiled again from their SPIR-V, as an app compiling shaders when it
//! runs would.

const std = @import("std");
const vc4 = @import("vc4");
const program_mod = @import("program.zig");

const Program = program_mod.Program;
const compiler = vc4.compiler;
const sim = vc4.qpu_sim;
const texture = vc4.texture;
const testing = std.testing;

const programs = [_]struct { name: []const u8, program: []const u8, spirv: []const u8 }{
    .{ .name = "shape", .program = @embedFile("shape.shader"), .spirv = @embedFile("shape.spv") },
    .{ .name = "solid", .program = @embedFile("solid.shader"), .spirv = @embedFile("solid.spv") },
    .{ .name = "text", .program = @embedFile("text.shader"), .spirv = @embedFile("text.spv") },
    .{ .name = "cube", .program = @embedFile("cube.shader"), .spirv = @embedFile("cube.spv") },
    .{ .name = "quad", .program = @embedFile("quad.shader"), .spirv = @embedFile("quad.spv") },
};

fn load(comptime name: []const u8) !Program {
    return Program.decode(@embedFile(name ++ ".shader"));
}

test "compiling a program's SPIR-V gives what the build embedded" {
    for (programs) |p| {
        const built = try Program.decode(p.program);
        var diag: program_mod.Diagnostic = .{};
        const compiled = Program.compile(testing.allocator, p.spirv, built.options, &diag) catch |err| {
            std.debug.print("{s}: {s}\n", .{ p.name, diag.message() });
            return err;
        };
        const bytes = try compiled.encode(testing.allocator);
        defer testing.allocator.free(bytes);
        try testing.expectEqualSlices(u8, p.program, bytes);
    }
}

test "every program passes the hardware rules" {
    for (programs) |p| {
        const prog = try Program.decode(p.program);
        for ([_]compiler.Compiled{ prog.fs, prog.vs, prog.cs }) |c| try vc4.qpu.validate(c.code(), c.stage, null);
    }
}

test "damaged programs are rejected" {
    const good = programs[0].program;
    try testing.expectError(error.BadProgram, Program.decode(good[0 .. good.len / 2]));
    try testing.expectError(error.BadProgram, Program.decode("SDSH"));
    try testing.expectError(error.BadProgram, Program.decode("not a program"));
}

/// A shader's uniform stream: the program's uniform words then the
/// viewport scale (`user`), and the texture's configuration.
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

fn lane(base: f32, step: f32) sim.Vec {
    var v: sim.Vec = undefined;
    for (&v, 0..) |*e, i| e.* = f2u(base + step * @as(f32, @floatFromInt(i)));
    return v;
}

test "cube vertex and coordinate shaders" {
    const p = try load("cube");
    try testing.expectEqual(@as(u32, 16), p.uniform_words);
    // A perspective-ish matrix with every element non-zero.
    var m: [16]f32 = undefined;
    for (&m, 0..) |*e, i| e.* = 0.1 * @as(f32, @floatFromInt(i + 1)) * (if (i % 3 == 0) @as(f32, -1.0) else 1.0);
    m[15] = 4.0; // keep w positive
    var user: [18]u32 = undefined;
    for (m, 0..) |e, i| user[i] = f2u(e);
    user[16] = f2u(400 * 16);
    user[17] = f2u(-300 * 16);
    var buf: [64]u32 = undefined;
    const attrs = [_]sim.Vec{
        lane(-1, 0.13), lane(1, -0.12), lane(-0.5, 0.07), // position
        lane(0, 0.06), lane(1, -0.05), // uv
        lane(0.2, 0.0), lane(0.4, 0.01), lane(0.6, 0.02), // tint
    };
    try testing.expectEqual(@as(u32, 8), p.vs.num_vpm_reads);
    const vs_unif = uniformStream(&buf, &p.vs, &user, .{ 0, 0 });
    const r = try sim.run(p.vs.code(), .{ .uniforms = vs_unif, .vpm_in = &attrs });
    try testing.expectEqual(vs_unif.len, r.uniforms_read);
    try testing.expectEqual(@as(usize, 3 + 5), r.vpm_out_len);

    // The coordinate shader reads the position alone.
    try testing.expectEqual(@as(u32, 3), p.cs.num_vpm_reads);
    const cs_unif = uniformStream(&buf, &p.cs, &user, .{ 0, 0 });
    const rc = try sim.run(p.cs.code(), .{ .uniforms = cs_unif, .vpm_in = attrs[0..3] });
    try testing.expectEqual(cs_unif.len, rc.uniforms_read);
    try testing.expectEqual(@as(usize, 7), rc.vpm_out_len);

    for (0..sim.lanes) |i| {
        const pos = [4]f32{ u2f(attrs[0][i]), u2f(attrs[1][i]), u2f(attrs[2][i]), 1.0 };
        var c: [4]f32 = undefined;
        for (&c, 0..) |*o, row| o.* = pos[0] * m[row] + pos[1] * m[4 + row] + pos[2] * m[8 + row] + pos[3] * m[12 + row];
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
        for (0..5) |k| try testing.expectEqual(attrs[3 + k][i], r.vpm_out[3 + k][i]);
        // The coordinate shader's header matches the vertex shader's.
        for (0..3) |k| try testing.expectEqual(r.vpm_out[k][i], rc.vpm_out[4 + k][i]);
    }
}

/// A texture of distinct, arbitrary texels, and where they are.
const TestTexture = struct {
    const w = 64;
    const h = 64;
    pixels: [w * h]u32,
    memory: [texture.imageSize(w, h)]u8,
    cfg: texture.Config,

    fn init(t: *TestTexture) void {
        t.cfg = .{ .width = w, .height = h, .mag_filter = .nearest, .min_filter = .nearest };
        for (&t.pixels, 0..) |*p, i| p.* = @truncate(i *% 2654435761);
        texture.upload(&t.memory, &t.pixels, w, h);
    }

    /// Texel centres: lane i samples (3i, 10 + 2i).
    const u = [2]f32{ 0.5 / 64.0, 3.0 / 64.0 };
    const v = [2]f32{ 10.5 / 64.0, 2.0 / 64.0 };

    fn at(t: *const TestTexture, i: usize) u32 {
        return t.pixels[(10 + 2 * i) * w + 3 * i];
    }
};

test "cube fragment shader samples and tints the texture, and keeps the depth" {
    const p = try load("cube");
    var tex: TestTexture = undefined;
    tex.init();
    try testing.expectEqual(@as(u32, 1), p.fs.num_texture_samples);
    var buf: [8]u32 = undefined;
    const stream = uniformStream(&buf, &p.fs, &.{}, .{ texture.p0(tex.cfg), texture.p1(tex.cfg) });
    const varyings = [_]sim.Vec{
        lane(TestTexture.u[0], TestTexture.u[1]), lane(TestTexture.v[0], TestTexture.v[1]),
        lane(1.0, 0),                             lane(0.5, 0),
        lane(0.25, 0),
    };
    const r = try sim.run(p.fs.code(), .{ .uniforms = stream, .varyings = &varyings, .frag_w = sim.splatF(1.5), .frag_z = sim.splat(0x123456), .texture_memory = &tex.memory });
    try testing.expectEqual(@as(usize, 1), r.texture_samples);
    try testing.expectEqualSlices(u32, &sim.splat(0x123456), &r.tlb_z.?);
    for (0..sim.lanes) |i| {
        const t = tex.at(i);
        const ch = struct {
            fn f(x: u32, s: u5) f32 {
                return @as(f32, @floatFromInt((x >> s) & 0xff)) / 255.0;
            }
        }.f;
        try testing.expectEqual(sim.packColor(ch(t, 16) * 1.0, ch(t, 8) * 0.5, ch(t, 0) * 0.25, 1.0), r.tlb_color.?[i]);
    }
}

test "the shell's textured quads copy texels exactly" {
    var tex: TestTexture = undefined;
    tex.init();
    inline for (.{"quad"}) |name| {
        const p = try load(name);
        try testing.expect(!p.options.depth_test);
        var buf: [8]u32 = undefined;
        const stream = uniformStream(&buf, &p.fs, &.{}, .{ texture.p0(tex.cfg), texture.p1(tex.cfg) });
        const varyings = [_]sim.Vec{ lane(TestTexture.u[0], TestTexture.u[1]), lane(TestTexture.v[0], TestTexture.v[1]) };
        const r = try sim.run(p.fs.code(), .{ .uniforms = stream, .varyings = &varyings, .texture_memory = &tex.memory });
        try testing.expect(r.tlb_z == null);
        for (0..sim.lanes) |i| try testing.expectEqual(tex.at(i), r.tlb_color.?[i]);
    }
}
