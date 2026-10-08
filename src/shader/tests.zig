//! Tests of Dazzle's shader programs, as the build compiled them: run in
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
const pixel = vc4.format;
const testing = std.testing;

const programs = [_]struct { name: []const u8, program: []const u8, spirv: []const u8 }{
    .{ .name = "shape", .program = @embedFile("shape.shader"), .spirv = @embedFile("shape.spv") },
    .{ .name = "solid", .program = @embedFile("solid.shader"), .spirv = @embedFile("solid.spv") },
    .{ .name = "opaque", .program = @embedFile("opaque.shader"), .spirv = @embedFile("opaque.spv") },
    .{ .name = "text", .program = @embedFile("text.shader"), .spirv = @embedFile("text.spv") },
    .{ .name = "polyhedron", .program = @embedFile("polyhedron.shader"), .spirv = @embedFile("polyhedron.spv") },
    .{ .name = "quad", .program = @embedFile("quad.shader"), .spirv = @embedFile("quad.spv") },
    .{ .name = "quad_rgb565", .program = @embedFile("quad_rgb565.shader"), .spirv = @embedFile("quad_rgb565.spv") },
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

test "programs that sample textures have threaded fragment shaders" {
    for (programs) |p| {
        const prog = try Program.decode(p.program);
        const samples = prog.fs.num_texture_samples > 0;
        try testing.expectEqual(samples, prog.fs.threaded);
        try testing.expect(!prog.vs.threaded and !prog.cs.threaded);
    }
}

test "every program passes the hardware rules" {
    for (programs) |p| {
        const prog = try Program.decode(p.program);
        for ([_]compiler.Compiled{ prog.fs, prog.vs, prog.cs }) |c| try vc4.qpu.validate(c.code(), c.stage, null);
        if (prog.has_fs_ms) try vc4.qpu.validate(prog.fs_ms.code(), .fragment, null);
    }
}

test "multisampled, blending reads each sample, blends it and writes it, as one sample is" {
    for (programs) |p| {
        const prog = try Program.decode(p.program);
        // Only programs that blend have (and need) a multisampled shader.
        try testing.expectEqual(prog.options.blend != .none, prog.has_fs_ms);
        if (!prog.has_fs_ms) continue;
        var user: [64]u32 = undefined;
        for (&user, 0..) |*w, i| w.* = f2u(0.1 + @as(f32, @floatFromInt(i % 7)) * 0.1);
        var tex: TestTexture = undefined;
        tex.init();
        var varyings: [16]sim.Vec = undefined;
        for (&varyings, 0..) |*v, k| {
            var vals: [sim.lanes]f32 = undefined;
            for (&vals, 0..) |*x, l| x.* = 0.05 + @as(f32, @floatFromInt((l * 3 + k * 5) % 17)) / 20;
            v.* = lanes(vals);
        }
        const nv = prog.fs.num_varyings;
        const cfg = [2]u32{ texture.p0(tex.cfg), texture.p1(tex.cfg) };
        var buf: [64]u32 = undefined;
        var buf_ms: [64]u32 = undefined;
        const one = try sim.run(prog.fs.code(), .{ .uniforms = uniformStream(&buf, &prog.fs, &user, cfg), .varyings = varyings[0..nv], .tlb_color_in = sim.splat(0xff336699), .texture_memory = &tex.memory });
        const ms = try sim.run(prog.fs_ms.code(), .{ .uniforms = uniformStream(&buf_ms, &prog.fs_ms, &user, cfg), .varyings = varyings[0..nv], .tlb_color_in = sim.splat(0xff336699), .texture_memory = &tex.memory });
        try testing.expectEqual(@as(usize, 1), one.color_loads);
        try testing.expectEqual(@as(usize, 4), ms.color_loads);
        try testing.expectEqual(@as(usize, 4), ms.tlb_samples);
        for (ms.tlb_color_samples) |sample| try testing.expectEqual(one.tlb_color.?, sample);
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

/// The polyhedron shader's uniforms: the matrix, a rotation of 0.6
/// radians about z, lighting and texturing, then the viewport scale.
fn polyhedronUniforms(m: [16]f32, lighting: f32, texturing: f32) [34]u32 {
    var user: [34]u32 = undefined;
    for (m, 0..) |e, i| user[i] = f2u(e);
    const c = @cos(@as(f32, 0.6));
    const s = @sin(@as(f32, 0.6));
    const rotation = [12]f32{ c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0 };
    for (rotation, 0..) |e, i| user[16 + i] = f2u(e);
    for ([4]f32{ lighting, texturing, 0, 0 }, 0..) |e, i| user[28 + i] = f2u(e);
    user[32] = f2u(400 * 16);
    user[33] = f2u(-300 * 16);
    return user;
}

test "polyhedron vertex and coordinate shaders" {
    const p = try load("polyhedron");
    try testing.expectEqual(@as(u32, 32), p.uniform_words);
    // A perspective-ish matrix with every element non-zero.
    var m: [16]f32 = undefined;
    for (&m, 0..) |*e, i| e.* = 0.1 * @as(f32, @floatFromInt(i + 1)) * (if (i % 3 == 0) @as(f32, -1.0) else 1.0);
    m[15] = 4.0; // keep w positive
    const user = polyhedronUniforms(m, 1, 1);
    var buf: [64]u32 = undefined;
    const attrs = [_]sim.Vec{
        lane(-1, 0.13), lane(1, -0.12), lane(-0.5, 0.07), // position
        lane(0, 0.06), lane(1, -0.05), // uv
        lane(0.2, 0.0), lane(0.4, 0.01), lane(0.6, 0.02), // tint
        lane(-1, 0.125), lane(0.3, 0), lane(0.5, -0.06), // normal (not unit; the shader takes it as it is)
    };
    try testing.expectEqual(@as(u32, 11), p.vs.num_vpm_reads);
    const vs_unif = uniformStream(&buf, &p.vs, &user, .{ 0, 0 });
    const r = try sim.run(p.vs.code(), .{ .uniforms = vs_unif, .vpm_in = &attrs });
    try testing.expectEqual(vs_unif.len, r.uniforms_read);
    try testing.expectEqual(@as(usize, 3 + 6), r.vpm_out_len);
    // Unlit, the shade is 1.
    const unlit_user = polyhedronUniforms(m, 0, 1);
    const unlit = try sim.run(p.vs.code(), .{ .uniforms = uniformStream(&buf, &p.vs, &unlit_user, .{ 0, 0 }), .vpm_in = &attrs });
    for (0..sim.lanes) |i| try testing.expectApproxEqAbs(@as(f32, 1), u2f(unlit.vpm_out[8][i]), 1e-6);

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
        // The normal, rotated, lit from the fixed direction.
        const n = [3]f32{ u2f(attrs[8][i]), u2f(attrs[9][i]), u2f(attrs[10][i]) };
        const co = @cos(@as(f32, 0.6));
        const si = @sin(@as(f32, 0.6));
        const rn = [3]f32{ co * n[0] - si * n[1], si * n[0] + co * n[1], n[2] };
        const diffuse = @max(rn[0] * -0.35 + rn[1] * 0.55 + rn[2] * 0.76, 0);
        try testing.expectApproxEqAbs(0.3 + 0.7 * diffuse, u2f(r.vpm_out[8][i]), 1e-5);
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

test "polyhedron fragment shader tints and shades the texture (or white), and keeps the depth" {
    const p = try load("polyhedron");
    var tex: TestTexture = undefined;
    tex.init();
    try testing.expectEqual(@as(u32, 1), p.fs.num_texture_samples);
    const varyings = [_]sim.Vec{
        lane(TestTexture.u[0], TestTexture.u[1]), lane(TestTexture.v[0], TestTexture.v[1]),
        lane(1.0, 0),                             lane(0.5, 0),
        lane(0.25, 0),                            lane(0.8, 0),
    };
    const ch = struct {
        fn f(x: u32, s: u5) f32 {
            return @as(f32, @floatFromInt((x >> s) & 0xff)) / 255.0;
        }
    }.f;
    for ([_]f32{ 1, 0 }) |texturing| {
        const user = polyhedronUniforms(@splat(0), 1, texturing);
        var buf: [8]u32 = undefined;
        const stream = uniformStream(&buf, &p.fs, &user, .{ texture.p0(tex.cfg), texture.p1(tex.cfg) });
        const r = try sim.run(p.fs.code(), .{ .uniforms = stream, .varyings = &varyings, .frag_w = sim.splatF(1.5), .frag_z = sim.splat(0x123456), .texture_memory = &tex.memory });
        try testing.expectEqual(stream.len, r.uniforms_read);
        try testing.expectEqualSlices(u32, &sim.splat(0x123456), &r.tlb_z.?);
        for (0..sim.lanes) |i| {
            const t = tex.at(i);
            const c = if (texturing == 1) [3]f32{ ch(t, 16), ch(t, 8), ch(t, 0) } else [3]f32{ 1, 1, 1 };
            const want = sim.packColor(c[0] * 1.0 * 0.8, c[1] * 0.5 * 0.8, c[2] * 0.25 * 0.8, 1.0);
            // The shader's sums round differently: within one level.
            for ([_]u5{ 0, 8, 16 }) |sh| {
                const d = @as(i32, @intCast(want >> sh & 0xff)) - @as(i32, @intCast(r.tlb_color.?[i] >> sh & 0xff));
                try testing.expect(d >= -1 and d <= 1);
            }
        }
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

test "the shell's RGB565 quads give the tile buffer each texel's colour, blue first" {
    const w = 64;
    const h = 64;
    var pixels: [w * h]u16 = undefined;
    for (&pixels, 0..) |*px, i| px.* = @truncate(i *% 2654435761 >> 7);
    var memory: [texture.imageSizeOf(.rgb565, w, h)]u8 = undefined;
    texture.uploadRectOf(.rgb565, &memory, w, h, .{ .x = 0, .y = 0, .width = w, .height = h }, std.mem.sliceAsBytes(&pixels), w * 2);
    const cfg: texture.Config = .{ .type = .rgb565, .width = w, .height = h, .mag_filter = .nearest, .min_filter = .nearest };
    const p = try load("quad_rgb565");
    var buf: [8]u32 = undefined;
    const stream = uniformStream(&buf, &p.fs, &.{}, .{ texture.p0(cfg), texture.p1(cfg) });
    const varyings = [_]sim.Vec{ lane(TestTexture.u[0], TestTexture.u[1]), lane(TestTexture.v[0], TestTexture.v[1]) };
    const r = try sim.run(p.fs.code(), .{ .uniforms = stream, .varyings = &varyings, .texture_memory = &memory });
    for (0..sim.lanes) |i| {
        // What a 32-bit target holds for it: 0xffRRGGBB, blue in the low
        // byte, which the tile buffer stores back as the same RGB565 pixel.
        const texel = pixels[(10 + 2 * i) * w + 3 * i];
        try testing.expectEqual(pixel.fromRgb565(texel), r.tlb_color.?[i]);
        try testing.expectEqual(texel, pixel.toRgb565(r.tlb_color.?[i]));
    }
}

fn lanes(values: [sim.lanes]f32) sim.Vec {
    var v: sim.Vec = undefined;
    for (&v, values) |*e, x| e.* = f2u(x);
    return v;
}

/// What testdata/flow.zig's fragment shader works out, done here.
fn flowColor(c: [4]f32) [4]f32 {
    var r = c[0];
    if (c[1] < 0.25) {
        r = 1;
    } else if (c[1] < 0.5) {
        r *= 0.5;
    } else if (c[1] == 0.5) {
        r = 0.75;
    } else {
        r = 0;
    }
    const x = if (c[2] >= c[3]) c[2] else c[3];
    const g: f32 = if (x < 0.25) 0 else if (x < 0.5) 0.25 else if (x >= 0.75) 1 else 0.5;
    var steps: f32 = 0;
    for (0..4) |i| {
        if (c[0] + @as(f32, @floatFromInt(i)) * 0.25 > 1) break;
        steps += 0.125;
    }
    const sum = 0.5 * c[1] + 0.25 * c[1] + 0.125 * c[1];
    const k: u32 = @intFromFloat(c[3] * 3);
    const pick: f32 = switch (k) {
        0 => 0.25,
        1 => 0.5,
        else => 0.125,
    };
    const sel = [2]f32{ if (c[2] > 0.5) 0.25 else 0, if (c[3] > 0.5) 0.25 else 0 };
    return .{ r, g, steps + sum * 0.5, pick + sel[0] + sel[1] };
}

test "control flow: each fragment takes its own way through ifs, returns, loops and switches" {
    var diag: program_mod.Diagnostic = .{};
    const p = Program.compile(testing.allocator, @embedFile("flow.spv"), .{}, &diag) catch |err| {
        std.debug.print("{s}\n", .{diag.message()});
        return err;
    };
    var in: [4][sim.lanes]f32 = undefined;
    for (0..sim.lanes) |i| {
        const f: f32 = @floatFromInt(i);
        in[0][i] = 0.05 + f * 0.06;
        in[1][i] = ([4]f32{ 0.1, 0.3, 0.5, 0.7 })[i % 4];
        in[2][i] = ([4]f32{ 0.1, 0.3, 0.6, 0.9 })[(i / 4) % 4];
        in[3][i] = ([5]f32{ 0.2, 0.45, 0.7, 0.95, 0.05 })[i % 5];
    }
    const varyings = [_]sim.Vec{ lanes(in[0]), lanes(in[1]), lanes(in[2]), lanes(in[3]) };
    var buf: [8]u32 = undefined;
    const stream = uniformStream(&buf, &p.fs, &.{}, .{ 0, 0 });
    const r = try sim.run(p.fs.code(), .{ .uniforms = stream, .varyings = &varyings });
    for (0..sim.lanes) |i| {
        const want = flowColor(.{ in[0][i], in[1][i], in[2][i], in[3][i] });
        const packed_want = sim.packColor(want[0], want[1], want[2], want[3]);
        for ([_]u5{ 0, 8, 16, 24 }) |sh| {
            const d = @as(i32, @intCast(packed_want >> sh & 0xff)) - @as(i32, @intCast(r.tlb_color.?[i] >> sh & 0xff));
            if (d < -1 or d > 1) {
                std.debug.print("lane {d}: in {any}, want {any} ({x}), got {x}\n", .{ i, .{ in[0][i], in[1][i], in[2][i], in[3][i] }, want, packed_want, r.tlb_color.?[i] });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "two textures: unit 0's and unit 1's, each with its own config and memory" {
    var diag: program_mod.Diagnostic = .{};
    const p = Program.compile(testing.allocator, @embedFile("two_textures.spv"), .{}, &diag) catch |err| {
        std.debug.print("{s}\n", .{diag.message()});
        return err;
    };
    try testing.expect(p.fs.samples_unit1);
    try testing.expectEqual(@as(u32, 2), p.fs.num_texture_samples);
    var units: [2]bool = .{ false, false };
    for (p.fs.uniforms()) |k| switch (k) {
        .tex_p0 => |u| units[u] = true,
        else => {},
    };
    try testing.expect(units[0] and units[1]);
    try vc4.qpu.validate(p.fs.code(), .fragment, null);
    var a: TestTexture = undefined;
    a.init();
    var b: TestTexture = undefined;
    b.init();
    // Unit 1's texels: the same, turned around (so they differ from unit
    // 0's at each place).
    std.mem.reverse(u32, &b.pixels);
    texture.upload(&b.memory, &b.pixels, TestTexture.w, TestTexture.h);
    b.cfg.offset = 0;
    var buf: [8]u32 = undefined;
    const stream = uniformStream(&buf, &p.fs, &.{}, .{ texture.p0(a.cfg), texture.p1(a.cfg) });
    const varyings = [_]sim.Vec{ lane(TestTexture.u[0], TestTexture.u[1]), lane(TestTexture.v[0], TestTexture.v[1]) };
    const r = try sim.run(p.fs.code(), .{ .uniforms = stream, .varyings = &varyings, .texture_memory = &a.memory, .texture_memory1 = &b.memory });
    try testing.expectEqual(@as(usize, 2), r.texture_samples);
    for (0..sim.lanes) |i| {
        const ta = a.at(i);
        const tb = b.pixels[(10 + 2 * i) * TestTexture.w + 3 * i];
        // Texels and the tile buffer are both B, G, R, A from the low
        // byte: the colour scaled by unit 1's red.
        const k = @as(f32, @floatFromInt(tb >> 16 & 0xff)) / 255;
        for ([_]u5{ 0, 8, 16 }) |sh| {
            const want: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(ta >> sh & 0xff)) / 255 * k * 255));
            const got = r.tlb_color.?[i] >> sh & 0xff;
            try testing.expect(@abs(@as(i32, @intCast(got)) - @as(i32, @intCast(want))) <= 1);
        }
    }
}

test "loops whose number of iterations is not known when compiled are reported" {
    var diag: program_mod.Diagnostic = .{};
    try testing.expectError(error.Unsupported, Program.compile(testing.allocator, @embedFile("endless.spv"), .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "endless.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "loops must stop") != null);
}
