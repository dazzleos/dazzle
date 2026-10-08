//! A functional simulator for the subset of the QPU instruction set that
//! Dazzle generates. It runs a shader on 16 SIMD lanes and records what
//! it writes to the VPM, the tile buffer and the texture unit, so shaders
//! can be tested on the build machine instead of on a Raspberry Pi.
//!
//! The model is deliberately simple: no timing, every result is visible to
//! the next instruction, and the hardware's scheduling rules are left to
//! `qpu.validate`. Anything outside the supported subset is an error
//! rather than a silent approximation.

const std = @import("std");
const qpu = @import("qpu.zig");
const texture = @import("texture.zig");
const pixel = @import("format.zig");

pub const lanes = 16;
pub const Vec = [lanes]u32;

pub fn splat(v: u32) Vec {
    return @splat(v);
}

pub fn splatF(v: f32) Vec {
    return @splat(@bitCast(v));
}

pub const Env = struct {
    /// The uniform stream, as the kernel would hand it to the shader.
    uniforms: []const u32 = &.{},
    /// Vertex and coordinate shaders: the attribute words loaded into the
    /// VPM, one vector (all lanes) per word.
    vpm_in: []const Vec = &.{},
    /// Fragment shaders: the final interpolated value of each varying.
    varyings: []const Vec = &.{},
    frag_w: Vec = splatF(1.0),
    frag_z: Vec = splat(0),
    /// Memory texture unit 0 samples from; P0's offset indexes into it.
    texture_memory: []const u8 = &.{},
    /// And texture unit 1.
    texture_memory1: []const u8 = &.{},
    /// Or, for shaders that sample several textures on a unit: each
    /// texture's memory, at `texture_base` times its index (the address
    /// the kernel relocates P0 by, as if each buffer were there).
    textures: []const []const u8 = &.{},
    /// Fragment shaders: the packed colours the tile buffer holds, which a
    /// colour load reads.
    tlb_color_in: Vec = splat(0),
};

pub const max_vpm_out = 32;

pub const Result = struct {
    vpm_out: [max_vpm_out]Vec = undefined,
    vpm_out_len: usize = 0,
    tlb_color: ?Vec = null,
    /// Multisampled: each sample's colour, as written in turn.
    tlb_color_samples: [4]Vec = undefined,
    tlb_samples: usize = 0,
    /// Times the tile buffer's colour was read.
    color_loads: usize = 0,
    tlb_z: ?Vec = null,
    uniforms_read: usize = 0,
    varyings_read: usize = 0,
    vpm_words_read: usize = 0,
    texture_samples: usize = 0,
    instructions: usize = 0,

    pub fn vpmOut(r: *const Result) []const Vec {
        return r.vpm_out[0..r.vpm_out_len];
    }
};

pub const Error = error{
    Unsupported,
    UniformUnderflow,
    VaryingUnderflow,
    VpmUnderflow,
    VpmOverflow,
    TmuUnderflow,
    MissingProgramEnd,
};

/// The constant term the simulated interpolator hands back in r5. Varyings
/// are split as (value - C) / W read from the varying port plus C in r5, so
/// a shader only reconstructs the right value if it computes vary * W + C.
const varying_c: f32 = 0.25;

const State = struct {
    ra: [32]Vec = std.mem.zeroes([32]Vec),
    rb: [32]Vec = std.mem.zeroes([32]Vec),
    acc: [6]Vec = std.mem.zeroes([6]Vec),
    zero: [lanes]bool = @splat(false),
    neg: [lanes]bool = @splat(false),
    vpm_read_left: u32 = 0,
    /// Each texture unit's.
    tmu: [2]Tmu = .{ .{}, .{} },

    const Tmu = struct {
        params: [4]u32 = undefined,
        param_count: usize = 0,
        coord_t: Vec = splat(0),
        fifo: [4]Vec = undefined,
        fifo_len: usize = 0,
    };
};

fn f(v: u32) f32 {
    return @bitCast(v);
}

fn u(v: f32) u32 {
    return @bitCast(v);
}

fn isFloatInputAdd(op: qpu.AddOp) bool {
    return switch (op) {
        .fadd, .fsub, .fmin, .fmax, .fminabs, .fmaxabs, .ftoi => true,
        else => false,
    };
}

fn isFloatInputMul(op: qpu.MulOp) bool {
    return op == .fmul;
}

/// Regfile A / r4 unpack of one value. 8-bit unpacks give a [0, 1] float
/// for float operations and a zero-extended integer otherwise.
fn unpack(v: u32, mode: u3, float_input: bool) Error!u32 {
    return switch (mode) {
        0 => v,
        4, 5, 6, 7 => blk: {
            const byte: u8 = @truncate(v >> (@as(u5, mode - 4) * 8));
            break :blk if (float_input) u(@as(f32, @floatFromInt(byte)) / 255.0) else byte;
        },
        else => error.Unsupported,
    };
}

fn ftoi(x: f32) u32 {
    if (std.math.isNan(x)) return 0;
    const clamped = std.math.clamp(x, -2147483648.0, 2147483520.0);
    return @bitCast(@as(i32, @intFromFloat(@trunc(clamped))));
}

fn addOp(op: qpu.AddOp, a: u32, b: u32) Error!u32 {
    const ai: i32 = @bitCast(a);
    const bi: i32 = @bitCast(b);
    return switch (op) {
        .nop => 0,
        .fadd => u(f(a) + f(b)),
        .fsub => u(f(a) - f(b)),
        .fmin => u(@min(f(a), f(b))),
        .fmax => u(@max(f(a), f(b))),
        .fminabs => u(@min(@abs(f(a)), @abs(f(b)))),
        .fmaxabs => u(@max(@abs(f(a)), @abs(f(b)))),
        .ftoi => ftoi(f(a)),
        .itof => u(@floatFromInt(ai)),
        .add => a +% b,
        .sub => a -% b,
        .shr => a >> @truncate(b),
        .asr => @bitCast(ai >> @truncate(b)),
        .shl => a << @truncate(b),
        .min => @bitCast(@min(ai, bi)),
        .max => @bitCast(@max(ai, bi)),
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
        .not => ~a,
        else => error.Unsupported,
    };
}

fn mulOp(op: qpu.MulOp, a: u32, b: u32) Error!u32 {
    return switch (op) {
        .nop => 0,
        .fmul => u(f(a) * f(b)),
        .mul24 => (a & 0xffffff) *% (b & 0xffffff),
        else => error.Unsupported,
    };
}

fn smallImm(v: u6) u32 {
    return switch (v) {
        0...15 => v,
        16...31 => @bitCast(@as(i32, v) - 32),
        32...39 => u(std.math.pow(f32, 2.0, @floatFromInt(@as(i32, v) - 32))),
        40...47 => u(std.math.pow(f32, 2.0, @floatFromInt(@as(i32, v) - 48))),
        else => 0, // vector rotates; not used
    };
}

/// Float to 8-bit unorm, as the mul unit's color pack does.
fn unorm8(x: f32) u8 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return @intFromFloat(@round(c * 255.0));
}

fn condPasses(cond: qpu.Cond, s: *const State, lane: usize) bool {
    return switch (cond) {
        .never => false,
        .always => true,
        .zs => s.zero[lane],
        .zc => !s.zero[lane],
        .ns => s.neg[lane],
        .nc => !s.neg[lane],
        .cs, .cc => false,
    };
}

pub fn run(code: []const qpu.Inst, env: Env) Error!Result {
    var s: State = .{};
    var r: Result = .{};
    s.ra[qpu.R.frag_payload_zw] = env.frag_w;
    s.rb[qpu.R.frag_payload_zw] = env.frag_z;

    var end_at: ?usize = null;
    // Where a thread switch takes effect (after its two delay slots).
    var switch_at: ?usize = null;
    var ip: usize = 0;
    while (ip < code.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        if (switch_at == ip) {
            // The other thread ran meanwhile: accumulators and flags are
            // undefined. Fill them with garbage, so code that keeps a
            // value in one across a switch gives wrong results.
            for (&s.acc) |*a| a.* = splat(0x7fc0dead);
            switch_at = null;
        }
        const inst = code[ip];
        r.instructions += 1;
        const sig = qpu.getSig(inst);
        if (sig == .branch) return error.Unsupported;

        const ws = qpu.getWs(inst);
        const cond_add: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 49)));
        const cond_mul: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 46)));
        const pm = (inst >> 56) & 1 != 0;
        const pack: u4 = @truncate(inst >> 52);
        const unpack_mode: u3 = @truncate(inst >> 57);

        var add_result: Vec = undefined;
        var mul_result: Vec = undefined;
        // Immediate loads use the ALU fields for their value.
        const add_op: qpu.AddOp = if (sig == .load_imm) .nop else qpu.getAddOp(inst);
        const mul_op: qpu.MulOp = if (sig == .load_imm) .nop else qpu.getMulOp(inst);

        if (sig == .load_imm) {
            if (pack != 0 or pm) return error.Unsupported;
            add_result = splat(@truncate(inst));
            mul_result = add_result;
        } else {
            // Register file reads. Each read of a FIFO-like port pops once
            // per instruction, however many inputs use it.
            const raddr_a = qpu.getRaddrA(inst);
            const raddr_b = qpu.getRaddrB(inst);
            var va: Vec = try readPort(&s, &r, env, raddr_a, .a);
            const vb: Vec = if (sig == .small_imm)
                splat(smallImm(raddr_b))
            else
                try readPort(&s, &r, env, raddr_b, .b);
            const old_r4 = s.acc[4];
            const reads_vary = (raddr_a == qpu.R.vary) or (sig != .small_imm and raddr_b == qpu.R.vary);

            const muxes = [4]qpu.Mux{
                @enumFromInt(@as(u3, @truncate(inst >> 9))),
                @enumFromInt(@as(u3, @truncate(inst >> 6))),
                @enumFromInt(@as(u3, @truncate(inst >> 3))),
                @enumFromInt(@as(u3, @truncate(inst))),
            };
            for (0..lanes) |lane| {
                var in: [4]u32 = undefined;
                for (muxes, 0..) |m, i| {
                    const float_input = if (i < 2) isFloatInputAdd(add_op) else isFloatInputMul(mul_op);
                    in[i] = switch (m) {
                        .r0, .r1, .r2, .r3, .r5 => s.acc[@intFromEnum(m)][lane],
                        .r4 => if (pm) try unpack(old_r4[lane], unpack_mode, float_input) else old_r4[lane],
                        .a => if (!pm and raddr_a < 32) try unpack(va[lane], unpack_mode, float_input) else va[lane],
                        .b => vb[lane],
                    };
                }
                add_result[lane] = try addOp(add_op, in[0], in[1]);
                mul_result[lane] = try mulOp(mul_op, in[2], in[3]);
            }
            va = undefined;

            if (inst & (1 << 45) != 0) {
                const flags_from = if (add_op != .nop) add_result else mul_result;
                for (0..lanes) |lane| {
                    s.zero[lane] = flags_from[lane] == 0;
                    s.neg[lane] = @as(i32, @bitCast(flags_from[lane])) < 0;
                }
            }
            // The interpolator loads the constant term into r5.
            if (reads_vary) s.acc[5] = splatF(varying_c);
        }

        const waddr_add = qpu.getWaddrAdd(inst);
        const waddr_mul = qpu.getWaddrMul(inst);
        // Regfile A pack applies to whichever result goes to regfile A.
        const a_pack: u4 = if (!pm) pack else 0;
        const mul_pack: u4 = if (pm) pack else 0;
        try write(&s, &r, env, waddr_add, if (ws) .b else .a, add_result, cond_add, if (!ws) a_pack else 0, 0);
        try write(&s, &r, env, waddr_mul, if (ws) .a else .b, mul_result, cond_mul, if (ws) a_pack else 0, mul_pack);

        switch (sig) {
            .load_tmu0, .load_tmu1 => {
                const t = &s.tmu[if (sig == .load_tmu0) 0 else 1];
                if (t.fifo_len == 0) return error.TmuUnderflow;
                s.acc[4] = t.fifo[0];
                std.mem.copyForwards(Vec, t.fifo[0 .. t.fifo_len - 1], t.fifo[1..t.fifo_len]);
                t.fifo_len -= 1;
            },
            .color_load => {
                s.acc[4] = env.tlb_color_in;
                r.color_loads += 1;
            },
            .prog_end => end_at = ip + 2,
            .thread_switch, .last_thread_switch => switch_at = ip + 3,
            .none, .small_imm, .load_imm, .scoreboard_unlock, .wait_scoreboard => {},
            else => return error.Unsupported,
        }
    }
    if (end_at == null) return error.MissingProgramEnd;
    return r;
}

const File = enum { a, b };

fn readPort(s: *State, r: *Result, env: Env, raddr: u6, file: File) Error!Vec {
    if (raddr < 32) return if (file == .a) s.ra[raddr] else s.rb[raddr];
    switch (raddr) {
        qpu.R.nop => return splat(0),
        qpu.R.unif => {
            if (r.uniforms_read >= env.uniforms.len) return error.UniformUnderflow;
            defer r.uniforms_read += 1;
            return splat(env.uniforms[r.uniforms_read]);
        },
        qpu.R.vary => {
            if (r.varyings_read >= env.varyings.len) return error.VaryingUnderflow;
            defer r.varyings_read += 1;
            var v: Vec = undefined;
            for (&v, env.varyings[r.varyings_read], env.frag_w) |*out, value, w|
                out.* = u((f(value) - varying_c) / f(w));
            return v;
        },
        qpu.R.vpm => {
            if (s.vpm_read_left == 0 or r.vpm_words_read >= env.vpm_in.len) return error.VpmUnderflow;
            s.vpm_read_left -= 1;
            defer r.vpm_words_read += 1;
            return env.vpm_in[r.vpm_words_read];
        },
        qpu.R.elem_qpu => {
            var v: Vec = undefined;
            for (&v, 0..) |*e, i| e.* = @intCast(i);
            return v;
        },
        else => return error.Unsupported,
    }
}

fn write(s: *State, r: *Result, env: Env, waddr: u6, file: File, value: Vec, cond: qpu.Cond, a_pack: u4, mul_pack: u4) Error!void {
    if (waddr == qpu.W.nop or cond == .never) return;
    const is_register = waddr < 32 or (waddr >= qpu.W.acc0 and waddr <= qpu.W.acc0 + 3) or waddr == qpu.W.acc5;
    if (cond != .always and !is_register) return error.Unsupported; // conditional peripheral writes

    const dst: ?*Vec = switch (waddr) {
        0...31 => if (file == .a) &s.ra[waddr] else &s.rb[waddr],
        qpu.W.acc0...qpu.W.acc0 + 3 => &s.acc[waddr - qpu.W.acc0],
        qpu.W.acc5 => &s.acc[5],
        else => null,
    };
    if (dst) |d| {
        if (a_pack != 0 and (file != .a or waddr >= 32)) return error.Unsupported;
        for (0..lanes) |lane| {
            if (!condPasses(cond, s, lane)) continue;
            const v = value[lane];
            d[lane] = switch (a_pack) {
                0 => switch (mul_pack) {
                    0 => v,
                    4, 5, 6, 7 => blk: {
                        const shift: u5 = @as(u5, @intCast(mul_pack - 4)) * 8;
                        const mask = @as(u32, 0xff) << shift;
                        break :blk (d[lane] & ~mask) | (@as(u32, unorm8(f(v))) << shift);
                    },
                    3 => @as(u32, unorm8(f(v))) * 0x01010101,
                    else => return error.Unsupported,
                },
                1 => (d[lane] & 0xffff0000) | (v & 0xffff),
                2 => (d[lane] & 0x0000ffff) | (v << 16),
                else => return error.Unsupported,
            };
        }
        return;
    }
    if (a_pack != 0 or mul_pack != 0) return error.Unsupported;

    switch (waddr) {
        qpu.W.vpm => {
            if (r.vpm_out_len >= max_vpm_out) return error.VpmOverflow;
            r.vpm_out[r.vpm_out_len] = value;
            r.vpm_out_len += 1;
        },
        qpu.W.vpmvcd_setup => {
            const v = value[0];
            // Only horizontal 32-bit accesses with stride 1 are modelled.
            if (v & 0xff00 != 0x1a00) return error.Unsupported;
            if (file == .a) {
                const n: u32 = (v >> 20) & 0xf;
                s.vpm_read_left = if (n == 0) 16 else n;
            } else if (v & 0xff != 0) return error.Unsupported;
        },
        qpu.W.tlb_color_all => r.tlb_color = value,
        // A sample's colour, in turn (the simulated tile buffer's samples
        // all start as tlb_color_in).
        qpu.W.tlb_color_ms => {
            if (r.tlb_samples < r.tlb_color_samples.len) r.tlb_color_samples[r.tlb_samples] = value;
            r.tlb_samples += 1;
            r.tlb_color = value;
        },
        qpu.W.tlb_z => r.tlb_z = value,
        qpu.W.sfu_recip, qpu.W.sfu_recipsqrt, qpu.W.sfu_exp, qpu.W.sfu_log => {
            for (&s.acc[4], value) |*o, v| o.* = u(switch (waddr) {
                qpu.W.sfu_recip => 1.0 / f(v),
                qpu.W.sfu_recipsqrt => 1.0 / @sqrt(f(v)),
                qpu.W.sfu_exp => std.math.exp2(f(v)),
                else => std.math.log2(f(v)),
            });
        },
        qpu.W.tmu0_s, qpu.W.tmu0_t, qpu.W.tmu1_s, qpu.W.tmu1_t => {
            // Each TMU write takes the next uniform as a texture config
            // parameter (P0, then P1, ...).
            const unit: usize = if (waddr == qpu.W.tmu0_s or waddr == qpu.W.tmu0_t) 0 else 1;
            const t = &s.tmu[unit];
            if (r.uniforms_read >= env.uniforms.len) return error.UniformUnderflow;
            if (t.param_count == t.params.len) return error.Unsupported;
            t.params[t.param_count] = env.uniforms[r.uniforms_read];
            t.param_count += 1;
            r.uniforms_read += 1;
            if (waddr == qpu.W.tmu0_t or waddr == qpu.W.tmu1_t) {
                t.coord_t = value;
                return;
            }
            if (t.param_count < 2 or t.fifo_len == t.fifo.len) return error.Unsupported;
            var memory = if (unit == 0) env.texture_memory else env.texture_memory1;
            var p0 = t.params[0];
            if (env.textures.len > 0) {
                const i = p0 / texture_base;
                if (i >= env.textures.len) return error.Unsupported;
                memory = env.textures[i];
                p0 -= i * texture_base;
            }
            var texel: Vec = undefined;
            for (&texel, value, t.coord_t) |*o, sc, tc|
                o.* = try sample(memory, p0, t.params[1], f(sc), f(tc));
            t.fifo[t.fifo_len] = texel;
            t.fifo_len += 1;
            t.param_count = 0;
            t.coord_t = splat(0);
            r.texture_samples += 1;
        },
        else => return error.Unsupported,
    }
}

/// Where `Env.textures` are, one after another.
pub const texture_base: u32 = 1 << 28;

/// Sampling of an RGBA8888, RGB565 or ALPHA texture, with repeat or
/// clamp wrapping. A 32-bit texel comes back as it is in memory; an RGB565
/// one with red in the low byte, then green and blue (each widened to 8
/// bits), and opaque: the order Mesa's vc4 driver expects (its B5G6R5
/// swizzle is XYZ1); an ALPHA one in the top byte, with the rest 0 (its A8
/// swizzle is 000W).
///
/// Only level 0 is sampled (which mipmap level the hardware picks depends
/// on the neighbouring pixels, which the simulator does not have), with the
/// magnification filter: nearest, or bilinear.
fn sample(memory: []const u8, p0: u32, p1: u32, s: f32, t: f32) Error!u32 {
    const p = texture.decodeConfig(p0, p1);
    const cpp: u32 = switch (p.type) {
        .rgba8888 => 4,
        .rgb565 => 2,
        .alpha => 1,
        else => return error.Unsupported,
    };
    const w: f32 = @floatFromInt(p.width);
    const h: f32 = @floatFromInt(p.height);
    if (p.mag_filter == .nearest) return fetch(memory, p, cpp, try wrap(@floor(s * w), p.width, p.wrap_s), try wrap(@floor(t * h), p.height, p.wrap_t));
    // Bilinear: the four texels around the point, by how near each is.
    const fx = s * w - 0.5;
    const fy = t * h - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const ax = fx - x0;
    const ay = fy - y0;
    var out: u32 = 0;
    var c: [4]u32 = undefined;
    for (0..4) |k| {
        const x = try wrap(x0 + @as(f32, @floatFromInt(k & 1)), p.width, p.wrap_s);
        const y = try wrap(y0 + @as(f32, @floatFromInt(k >> 1)), p.height, p.wrap_t);
        c[k] = try fetch(memory, p, cpp, x, y);
    }
    for (0..4) |byte| {
        const sh: u5 = @intCast(byte * 8);
        var v: f32 = 0;
        for (c, [4]f32{ (1 - ax) * (1 - ay), ax * (1 - ay), (1 - ax) * ay, ax * ay }) |cc, k| v += @as(f32, @floatFromInt(cc >> sh & 0xff)) * k;
        out |= @as(u32, @intFromFloat(@round(v))) << sh;
    }
    return out;
}

fn fetch(memory: []const u8, p: texture.Config, cpp: u32, x: u32, y: u32) Error!u32 {
    const offset = p.offset + referenceTexelOffsetOf(cpp, p.width, p.height, x, y);
    if (offset + cpp > memory.len) return error.Unsupported;
    if (cpp == 4) return std.mem.readInt(u32, memory[offset..][0..4], .little);
    if (cpp == 1) return @as(u32, memory[offset]) << 24;
    const argb = pixel.fromRgb565(std.mem.readInt(u16, memory[offset..][0..2], .little));
    // 0xffRRGGBB to bytes R, G, B, A.
    return 0xff000000 | (argb & 0xff) << 16 | (argb & 0xff00) | ((argb >> 16) & 0xff);
}

/// A texel's column (or row), wrapped into the texture.
fn wrap(coord: f32, size: u32, mode: texture.Wrap) Error!u32 {
    const n: i64 = size;
    const i: i64 = @intFromFloat(std.math.clamp(coord, -1e9, 1e9));
    return switch (mode) {
        .repeat => @intCast(@mod(i, n)),
        .clamp => @intCast(std.math.clamp(i, 0, n - 1)),
        else => error.Unsupported,
    };
}

/// Byte offset of texel (x, y) in a 32-bit-per-pixel texture.
pub fn referenceTexelOffset(width: u32, height: u32, x: u32, y: u32) u32 {
    return referenceTexelOffsetOf(4, width, height, x, y);
}

/// Byte offset of texel (x, y) in a texture of `cpp` bytes per pixel (4,
/// 2 or 1), written directly from the layout description in the VideoCore
/// IV reference guide (section 4) as an independent check on
/// vc4/texture.zig:
///
/// * Micro-tiles ("utiles") are 64 bytes: 4x4 pixels of 32 bits, 8x4 of
///   16, 8x8 of 8, in raster order.
/// * Small images (LT, at most 4 utiles across or down) are a raster-order
///   grid of utiles.
/// * T images are 4 KB tiles of 8x8 utiles in rows, alternate rows running
///   right to left. Each tile is four 1 KB sub-tiles of 4x4 utiles: in
///   even tile rows they are stored bottom-left, top-left, top-right,
///   bottom-right; in odd rows top-right, bottom-right, bottom-left,
///   top-left, where "bottom" is the lower address (y = 0). Sub-tiles are
///   4x4 raster-order grids of utiles.
pub fn referenceTexelOffsetOf(cpp: u32, width: u32, height: u32, x: u32, y: u32) u32 {
    const uw: u32 = if (cpp == 4) 4 else 8;
    const uh: u32 = if (cpp == 1) 8 else 4;
    const in_utile = ((y % uh) * uw + (x % uw)) * cpp;
    if (width <= 4 * uw or height <= 4 * uh) {
        const utiles_per_row = (width + uw - 1) / uw;
        return ((y / uh) * utiles_per_row + x / uw) * 64 + in_utile;
    }
    const tile_w = 8 * uw;
    const tile_h = 8 * uh;
    const tiles_per_row = (width + tile_w - 1) / tile_w;
    const tile_row = y / tile_h;
    const tile_col = if (tile_row % 2 == 0) x / tile_w else tiles_per_row - 1 - x / tile_w;
    const tile_base = (tile_row * tiles_per_row + tile_col) * 4096;

    // Sub-tile position in the tile: (column, row) with row 0 = bottom.
    const sub_col = (x / (4 * uw)) % 2;
    const sub_row = (y / (4 * uh)) % 2;
    const Pos = struct { col: u32, row: u32 };
    const even = [4]Pos{ .{ .col = 0, .row = 0 }, .{ .col = 0, .row = 1 }, .{ .col = 1, .row = 1 }, .{ .col = 1, .row = 0 } };
    const odd = [4]Pos{ .{ .col = 1, .row = 1 }, .{ .col = 1, .row = 0 }, .{ .col = 0, .row = 0 }, .{ .col = 0, .row = 1 } };
    const order = if (tile_row % 2 == 0) &even else &odd;
    var sub_index: u32 = 0;
    for (order, 0..) |pos, i| {
        if (pos.col == sub_col and pos.row == sub_row) sub_index = @intCast(i);
    }
    const utile_in_sub = ((y / uh) % 4) * 4 + (x / uw) % 4;
    return tile_base + sub_index * 1024 + utile_in_sub * 64 + in_utile;
}

// --- Tests ---------------------------------------------------------------------
//
// The hand-written triangle shaders are known to render correctly on a Pi
// Zero, so running them here checks the simulator itself.

const testing = std.testing;
const shaders = @import("reference_shaders.zig");

fn lanesF(comptime gen: fn (usize) f32) Vec {
    var v: Vec = undefined;
    for (&v, 0..) |*e, i| e.* = u(gen(i));
    return v;
}

fn xs(i: usize) f32 {
    return -1.0 + @as(f32, @floatFromInt(i)) / 8.0;
}
fn ys(i: usize) f32 {
    return 0.9 - @as(f32, @floatFromInt(i)) / 10.0;
}
fn rs(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) / 15.0;
}
fn gs(i: usize) f32 {
    return 1.0 - @as(f32, @floatFromInt(i)) / 15.0;
}
fn bs(_: usize) f32 {
    return 0.5;
}

pub fn packScreenXy(x: f32, y: f32) u32 {
    return (ftoi(x) & 0xffff) | (ftoi(y) << 16);
}

test "hand-written vertex shader" {
    const vs = try shaders.vertex();
    const x_scale: f32 = 960.0 * 16.0;
    const y_scale: f32 = -540.0 * 16.0;
    const inputs = [_]Vec{ lanesF(xs), lanesF(ys), lanesF(rs), lanesF(gs), lanesF(bs) };
    const r = try run(vs.code(), .{ .uniforms = &.{ u(x_scale), u(y_scale) }, .vpm_in = &inputs });
    try testing.expectEqual(@as(usize, 6), r.vpm_out_len);
    try testing.expectEqual(@as(usize, 2), r.uniforms_read);
    for (0..lanes) |i| {
        try testing.expectEqual(packScreenXy(xs(i) * x_scale, ys(i) * y_scale), r.vpm_out[0][i]);
        try testing.expectEqual(u(0.5), r.vpm_out[1][i]);
        try testing.expectEqual(u(1.0), r.vpm_out[2][i]);
        try testing.expectEqual(u(rs(i)), r.vpm_out[3][i]);
        try testing.expectEqual(u(gs(i)), r.vpm_out[4][i]);
        try testing.expectEqual(u(bs(i)), r.vpm_out[5][i]);
    }
}

test "hand-written coordinate shader" {
    const cs = try shaders.coordinate();
    const inputs = [_]Vec{ lanesF(xs), lanesF(ys) };
    const r = try run(cs.code(), .{ .uniforms = &.{ u(100.0), u(-50.0) }, .vpm_in = &inputs });
    try testing.expectEqual(@as(usize, 7), r.vpm_out_len);
    for (0..lanes) |i| {
        try testing.expectEqual(u(xs(i)), r.vpm_out[0][i]);
        try testing.expectEqual(u(ys(i)), r.vpm_out[1][i]);
        try testing.expectEqual(u(0.0), r.vpm_out[2][i]);
        try testing.expectEqual(u(1.0), r.vpm_out[3][i]);
        try testing.expectEqual(packScreenXy(xs(i) * 100.0, ys(i) * -50.0), r.vpm_out[4][i]);
    }
}

pub fn packColor(r: f32, g: f32, b: f32, a: f32) u32 {
    return @as(u32, unorm8(a)) << 24 | @as(u32, unorm8(r)) << 16 | @as(u32, unorm8(g)) << 8 | unorm8(b);
}

test "hand-written fragment shader" {
    const fs = try shaders.fragment();
    const varyings = [_]Vec{ lanesF(rs), lanesF(gs), lanesF(bs) };
    const r = try run(fs.code(), .{ .varyings = &varyings, .frag_w = splatF(2.0) });
    try testing.expectEqual(@as(usize, 3), r.varyings_read);
    for (0..lanes) |i| try testing.expectEqual(packColor(rs(i), gs(i), bs(i), 1.0), r.tlb_color.?[i]);
}

test "a compiled shader blends with the tile buffer" {
    const compiler = @import("compiler.zig");
    // out = src * a + dst * (1 - a), per channel, with src from uniforms:
    // blue-ish at 25% over whatever the tile holds.
    var s = compiler.Shader.init(.fragment);
    const dst = s.tlbColorLoad();
    const alpha = s.uniform(3);
    const inv = s.fsub(s.constantF(1.0), alpha);
    var out: [4]compiler.Value = undefined;
    for (0..4) |c| {
        const d = s.unpackUnorm8(dst, @intCast(c));
        const src = if (c == 3) s.constantF(1.0) else s.uniform(@intCast(c));
        out[c] = s.fadd(s.fmul(src, alpha), s.fmul(d, inv));
    }
    s.tlbColor(s.packUnorm8888(out[0], out[1], out[2], out[3]));
    const compiled = try compiler.compile(&s);
    try qpu.validate(compiled.code(), .fragment, null);

    // The uniform stream in the order the code reads it.
    const values = [4]f32{ 1.0, 0.5, 0.0, 0.25 }; // B, G, R, alpha
    var uniforms: [compiler.max_uniforms]u32 = undefined;
    for (compiled.uniforms(), 0..) |k, i| uniforms[i] = @bitCast(values[k.user]);
    // Lane i's tile holds grey level 16 * i.
    var tile: Vec = undefined;
    for (&tile, 0..) |*t, i| {
        const g: u32 = @intCast(16 * i);
        t.* = 0xff000000 | g << 16 | g << 8 | g;
    }
    const r = try run(compiled.code(), .{ .uniforms = uniforms[0..compiled.uniforms().len], .tlb_color_in = tile });
    for (0..lanes) |i| {
        const g: f32 = @as(f32, @floatFromInt(16 * i)) / 255;
        const want = packColor(g * 0.75, 0.5 * 0.25 + g * 0.75, 0.25 + g * 0.75, 1.0);
        const got = r.tlb_color.?[i];
        // Within one step per channel (rounding).
        for (0..4) |c| {
            const shift: u5 = @intCast(c * 8);
            const diff = @as(i32, @intCast((got >> shift) & 0xff)) - @as(i32, @intCast((want >> shift) & 0xff));
            try testing.expect(diff >= -1 and diff <= 1);
        }
    }
}
