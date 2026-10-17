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
const VecU = @Vector(lanes, u32);
const VecI = @Vector(lanes, i32);
const VecF = @Vector(lanes, f32);
const VecB = @Vector(lanes * 4, u8);
const VecU16 = @Vector(lanes * 4, u16);

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
    frag_x: Vec = splat(0),
    frag_y: Vec = splat(0),
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

pub const FragResult = struct {
    tlb_color: ?Vec = null,
    tlb_z: ?Vec = null,
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
    ra: [32]Vec = undefined,
    rb: [32]Vec = undefined,
    ra_init: u32 = 0,
    rb_init: u32 = 0,
    /// Indices 0..5 are accumulators r0..r5; index 6 is mux .a; index 7 is mux .b.
    acc: [8]Vec = undefined,
    zero: [lanes]bool = @splat(false),
    neg: [lanes]bool = @splat(false),
    vpm_read_left: u32 = 0,
    uniforms_read: usize = 0,
    varyings_read: usize = 0,
    vpm_words_read: usize = 0,
    /// Each texture unit's.
    tmu: [2]Tmu = .{ .{}, .{} },

    const Tmu = struct {
        params: [4]u32 = undefined,
        param_count: usize = 0,
        coord_t: Vec = undefined,
        has_coord_t: bool = false,
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

/// Regfile A / r4 unpack across all 16 lanes. 8-bit unpacks give a [0, 1]
/// float for float operations and a zero-extended integer otherwise.
fn unpackVec(v: Vec, mode: u3, float_input: bool) Error!Vec {
    if (mode == 0) return v;
    const vu: VecU = v;
    return switch (mode) {
        0 => unreachable,
        4, 5, 6, 7 => blk: {
            const shift: u5 = @as(u5, mode - 4) * 8;
            const bytes: VecU = (vu >> @as(@Vector(lanes, u5), @splat(shift))) & @as(VecU, @splat(0xff));
            if (float_input) {
                const vf: VecF = @floatFromInt(bytes);
                break :blk @bitCast(vf * @as(VecF, @splat(1.0 / 255.0)));
            }
            break :blk bytes;
        },
        else => error.Unsupported,
    };
}

fn ftoi(x: f32) u32 {
    if (std.math.isNan(x)) return 0;
    const clamped = std.math.clamp(x, -2147483648.0, 2147483520.0);
    return @bitCast(@as(i32, @intFromFloat(@trunc(clamped))));
}

inline fn v8muldVec(au: VecU, bu: VecU) Vec {
    const ab: VecB = @bitCast(au);
    const bb: VecB = @bitCast(bu);
    const prod: VecU16 = @as(VecU16, ab) * @as(VecU16, bb) + @as(VecU16, @splat(127));
    const div255: VecU16 = (prod + @as(VecU16, @splat(1)) + (prod >> @as(@Vector(lanes * 4, u4), @splat(8)))) >> @as(@Vector(lanes * 4, u4), @splat(8));
    const res_b: VecB = @truncate(div255);
    return @bitCast(res_b);
}

fn addOpVec(op: qpu.AddOp, a: Vec, b: Vec) Vec {
    const au: VecU = a;
    const bu: VecU = b;
    const ai: VecI = @bitCast(au);
    const bi: VecI = @bitCast(bu);
    const af: VecF = @bitCast(au);
    const bf: VecF = @bitCast(bu);
    return switch (op) {
        .nop => splat(0),
        .fadd => @bitCast(af + bf),
        .fsub => @bitCast(af - bf),
        .fmin => @bitCast(@min(af, bf)),
        .fmax => @bitCast(@max(af, bf)),
        .fminabs => @bitCast(@min(@abs(af), @abs(bf))),
        .fmaxabs => @bitCast(@max(@abs(af), @abs(bf))),
        .ftoi => blk: {
            var res: Vec = undefined;
            for (0..lanes) |l| res[l] = ftoi(f(a[l]));
            break :blk res;
        },
        .itof => blk: {
            const vf: VecF = @floatFromInt(ai);
            break :blk @bitCast(vf);
        },
        .add => au +% bu,
        .sub => au -% bu,
        .shr => au >> @as(@Vector(lanes, u5), @truncate(bu)),
        .asr => @bitCast(ai >> @as(@Vector(lanes, u5), @truncate(bu))),
        .ror => blk: {
            const sh: @Vector(lanes, u5) = @truncate(bu);
            const neg_sh: @Vector(lanes, u5) = @as(@Vector(lanes, u5), @splat(0)) -% sh;
            break :blk (au >> sh) | (au << neg_sh);
        },
        .shl => au << @as(@Vector(lanes, u5), @truncate(bu)),
        .min => @bitCast(@min(ai, bi)),
        .max => @bitCast(@max(ai, bi)),
        .@"and" => au & bu,
        .@"or" => au | bu,
        .xor => au ^ bu,
        .not => ~au,
        .clz => @clz(au),
        .v8adds => @bitCast(@as(VecB, @bitCast(au)) +| @as(VecB, @bitCast(bu))),
        .v8subs => @bitCast(@as(VecB, @bitCast(au)) -| @as(VecB, @bitCast(bu))),
    };
}

fn mulOpVec(op: qpu.MulOp, a: Vec, b: Vec) Vec {
    const au: VecU = a;
    const bu: VecU = b;
    const af: VecF = @bitCast(au);
    const bf: VecF = @bitCast(bu);
    return switch (op) {
        .nop => splat(0),
        .fmul => @bitCast(af * bf),
        .mul24 => (au & @as(VecU, @splat(0xffffff))) *% (bu & @as(VecU, @splat(0xffffff))),
        .v8muld => v8muldVec(au, bu),
        .v8min => @bitCast(@min(@as(VecB, @bitCast(au)), @as(VecB, @bitCast(bu)))),
        .v8max => @bitCast(@max(@as(VecB, @bitCast(au)), @as(VecB, @bitCast(bu)))),
        .v8adds => @bitCast(@as(VecB, @bitCast(au)) +| @as(VecB, @bitCast(bu))),
        .v8subs => @bitCast(@as(VecB, @bitCast(au)) -| @as(VecB, @bitCast(bu))),
    };
}

pub fn smallImm(v: u6) u32 {
    return switch (v) {
        0...15 => v,
        16...31 => @bitCast(@as(i32, v) - 32),
        32...39 => @as(u32, (@as(u32, 127) + @as(u32, v - 32)) << 23),
        40...47 => @as(u32, (@as(u32, 127) - @as(u32, 48 - v)) << 23),
        else => 0, // vector rotates; not used
    };
}

/// Float to 8-bit unorm, as the mul unit's color pack does.
fn unorm8(x: f32) u8 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return @intFromFloat(@round(c * 255.0));
}

inline fn unorm8Vec(v: Vec) VecU {
    const vf: VecF = @bitCast(v);
    const clamped = @min(@max(vf, @as(VecF, @splat(0.0))), @as(VecF, @splat(1.0)));
    const scaled = @round(clamped * @as(VecF, @splat(255.0)));
    return @intFromFloat(scaled);
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

pub const File = enum(u1) { a = 0, b = 1 };

pub const DecodedInst = struct {
    imm_or_small: u32 = 0,
    sig: qpu.Sig = .none,
    add_op: qpu.AddOp = .nop,
    mul_op: qpu.MulOp = .nop,
    raddr_a: u6 = qpu.R.nop,
    raddr_b: u6 = qpu.R.nop,
    waddr_add: u6 = qpu.W.nop,
    waddr_mul: u6 = qpu.W.nop,
    cond_add: qpu.Cond = .never,
    cond_mul: qpu.Cond = .never,
    add_file: File = .a,
    mul_file: File = .b,
    mux0: qpu.Mux = .r0,
    mux1: qpu.Mux = .r0,
    mux2: qpu.Mux = .r0,
    mux3: qpu.Mux = .r0,
    unpack_r4: u3 = 0,
    unpack_a: u3 = 0,
    add_pack_a: u4 = 0,
    mul_pack_a: u4 = 0,
    mul_pack_m: u4 = 0,
    flags: u8 = 0,

    pub const FLAG_SF: u8 = 1 << 0;
    pub const FLAG_READS_VARY: u8 = 1 << 1;
    pub const FLAG_FETCH_A: u8 = 1 << 2;
    pub const FLAG_FETCH_B: u8 = 1 << 3;
    pub const FLAG_FLT_ADD: u8 = 1 << 4;
    pub const FLAG_FLT_MUL: u8 = 1 << 5;
    pub const FLAG_HAS_UNPACK: u8 = 1 << 6;
    pub const FLAG_BAD_LOAD_IMM: u8 = 1 << 7;
};

pub fn decodeInst(inst: qpu.Inst) DecodedInst {
    const sig = qpu.getSig(inst);
    if (sig == .branch) {
        return .{ .sig = .branch };
    }

    const ws = qpu.getWs(inst);
    const cond_add: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 49)));
    const cond_mul: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 46)));
    const pm = (inst >> 56) & 1 != 0;
    const pack: u4 = @truncate(inst >> 52);
    const unpack_mode: u3 = @truncate(inst >> 57);
    const add_op: qpu.AddOp = if (sig == .load_imm) .nop else qpu.getAddOp(inst);
    const mul_op: qpu.MulOp = if (sig == .load_imm) .nop else qpu.getMulOp(inst);
    const raddr_a = qpu.getRaddrA(inst);
    const raddr_b = qpu.getRaddrB(inst);
    const mux0: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst >> 9)));
    const mux1: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst >> 6)));
    const mux2: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst >> 3)));
    const mux3: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst)));

    const uses_a = raddr_a != qpu.R.nop or mux0 == .a or mux1 == .a or mux2 == .a or mux3 == .a;
    const uses_b = sig != .small_imm and (raddr_b != qpu.R.nop or mux0 == .b or mux1 == .b or mux2 == .b or mux3 == .b);

    const waddr_add_raw = qpu.getWaddrAdd(inst);
    const waddr_mul_raw = qpu.getWaddrMul(inst);
    const a_pack: u4 = if (!pm) pack else 0;
    const mul_pack: u4 = if (pm) pack else 0;
    const unpack_r4: u3 = if (pm) unpack_mode else 0;
    const unpack_a: u3 = if (!pm and raddr_a < 32) unpack_mode else 0;

    var flags: u8 = 0;
    if ((inst & (1 << 45)) != 0) flags |= DecodedInst.FLAG_SF;
    if ((raddr_a == qpu.R.vary) or (sig != .small_imm and raddr_b == qpu.R.vary)) {
        flags |= DecodedInst.FLAG_READS_VARY;
    }
    if (uses_a) flags |= DecodedInst.FLAG_FETCH_A;
    if (uses_b) flags |= DecodedInst.FLAG_FETCH_B;
    if (isFloatInputAdd(add_op)) flags |= DecodedInst.FLAG_FLT_ADD;
    if (isFloatInputMul(mul_op)) flags |= DecodedInst.FLAG_FLT_MUL;
    if (unpack_r4 != 0 or unpack_a != 0) flags |= DecodedInst.FLAG_HAS_UNPACK;
    if (sig == .load_imm and (pack != 0 or pm)) flags |= DecodedInst.FLAG_BAD_LOAD_IMM;

    return .{
        .imm_or_small = if (sig == .load_imm)
            @truncate(inst)
        else if (sig == .small_imm)
            smallImm(raddr_b)
        else
            0,
        .sig = sig,
        .add_op = add_op,
        .mul_op = mul_op,
        .raddr_a = raddr_a,
        .raddr_b = raddr_b,
        .waddr_add = if (cond_add != .never) waddr_add_raw else qpu.W.nop,
        .waddr_mul = if (cond_mul != .never) waddr_mul_raw else qpu.W.nop,
        .cond_add = cond_add,
        .cond_mul = cond_mul,
        .add_file = if (ws) .b else .a,
        .mul_file = if (ws) .a else .b,
        .mux0 = mux0,
        .mux1 = mux1,
        .mux2 = mux2,
        .mux3 = mux3,
        .unpack_r4 = unpack_r4,
        .unpack_a = unpack_a,
        .add_pack_a = if (!ws) a_pack else 0,
        .mul_pack_a = if (ws) a_pack else 0,
        .mul_pack_m = mul_pack,
        .flags = flags,
    };
}

pub fn decodeProgram(code: []const qpu.Inst, out_buf: []DecodedInst) []const DecodedInst {
    const len = @min(code.len, out_buf.len);
    for (0..len) |i| {
        out_buf[i] = decodeInst(code[i]);
    }
    return out_buf[0..len];
}

inline fn resolveMuxSlow(
    m: qpu.Mux,
    s: *const State,
    unpack_r4: u3,
    unpack_a: u3,
    float_input: bool,
) Error!Vec {
    return switch (m) {
        .r4 => if (unpack_r4 != 0) try unpackVec(s.acc[4], unpack_r4, float_input) else s.acc[4],
        .a => if (unpack_a != 0) try unpackVec(s.acc[6], unpack_a, float_input) else s.acc[6],
        else => s.acc[@intFromEnum(m)],
    };
}

pub fn run(code: []const qpu.Inst, env: Env) Error!Result {
    var decoded_buf: [2048]DecodedInst = undefined;
    const decoded = decodeProgram(code, &decoded_buf);
    return runDecoded(decoded, env);
}

pub fn runDecoded(decoded: []const DecodedInst, env: Env) Error!Result {
    var r: Result = .{};
    try executeDecoded(Result, decoded, &env, &r);
    return r;
}

pub fn runFragmentDecoded(decoded: []const DecodedInst, env: Env) Error!FragResult {
    var r: FragResult = .{};
    try executeDecoded(FragResult, decoded, &env, &r);
    return r;
}

fn executeDecoded(comptime RType: type, decoded: []const DecodedInst, env: *const Env, r: *RType) Error!void {
    var s: State = .{};
    @memset(s.acc[0..6], splat(0));
    s.ra[qpu.R.frag_payload_zw] = env.frag_w;
    s.rb[qpu.R.frag_payload_zw] = env.frag_z;
    s.ra_init = @as(u32, 1) << qpu.R.frag_payload_zw;
    s.rb_init = @as(u32, 1) << qpu.R.frag_payload_zw;

    var end_at: ?usize = null;
    // Where a thread switch takes effect (after its two delay slots).
    var switch_at: ?usize = null;
    var ip: usize = 0;
    while (ip < decoded.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        if (switch_at == ip) {
            // The other thread ran meanwhile: accumulators and flags are
            // undefined. Fill them with garbage, so code that keeps a
            // value in one across a switch gives wrong results.
            for (s.acc[0..6]) |*a| a.* = splat(0x7fc0dead);
            switch_at = null;
        }
        const d = decoded[ip];
        if (@hasField(RType, "instructions")) r.instructions += 1;
        if (d.sig == .branch) return error.Unsupported;

        var add_result: Vec = undefined;
        var mul_result: Vec = undefined;

        if (d.sig == .load_imm) {
            if ((d.flags & DecodedInst.FLAG_BAD_LOAD_IMM) != 0) return error.Unsupported;
            add_result = splat(d.imm_or_small);
            mul_result = add_result;
        } else {
            // Register file reads. Each read of a FIFO-like port pops once
            // per instruction, however many inputs use it.
            s.acc[6] = if ((d.flags & DecodedInst.FLAG_FETCH_A) != 0)
                try readPort(&s, env, d.raddr_a, .a)
            else
                splat(0);
            if (d.sig == .small_imm) {
                s.acc[7] = splat(d.imm_or_small);
            } else {
                s.acc[7] = if ((d.flags & DecodedInst.FLAG_FETCH_B) != 0)
                    try readPort(&s, env, d.raddr_b, .b)
                else
                    splat(0);
            }

            if ((d.flags & DecodedInst.FLAG_HAS_UNPACK) == 0) {
                add_result = if (d.add_op != .nop)
                    addOpVec(d.add_op, s.acc[@intFromEnum(d.mux0)], s.acc[@intFromEnum(d.mux1)])
                else
                    splat(0);
                mul_result = if (d.mul_op != .nop)
                    mulOpVec(d.mul_op, s.acc[@intFromEnum(d.mux2)], s.acc[@intFromEnum(d.mux3)])
                else
                    splat(0);
            } else {
                if (d.add_op != .nop) {
                    const flt_add = (d.flags & DecodedInst.FLAG_FLT_ADD) != 0;
                    const in0 = try resolveMuxSlow(d.mux0, &s, d.unpack_r4, d.unpack_a, flt_add);
                    const in1 = if (d.mux1 == d.mux0) in0 else try resolveMuxSlow(d.mux1, &s, d.unpack_r4, d.unpack_a, flt_add);
                    add_result = addOpVec(d.add_op, in0, in1);
                } else {
                    add_result = splat(0);
                }

                if (d.mul_op != .nop) {
                    const flt_mul = (d.flags & DecodedInst.FLAG_FLT_MUL) != 0;
                    const in2 = try resolveMuxSlow(d.mux2, &s, d.unpack_r4, d.unpack_a, flt_mul);
                    const in3 = if (d.mux3 == d.mux2) in2 else try resolveMuxSlow(d.mux3, &s, d.unpack_r4, d.unpack_a, flt_mul);
                    mul_result = mulOpVec(d.mul_op, in2, in3);
                } else {
                    mul_result = splat(0);
                }
            }

            if ((d.flags & DecodedInst.FLAG_SF) != 0) {
                const flags_from: VecI = @bitCast(if (d.add_op != .nop) add_result else mul_result);
                s.zero = flags_from == @as(VecI, @splat(0));
                s.neg = flags_from < @as(VecI, @splat(0));
            }
            // The interpolator loads the constant term into r5.
            if ((d.flags & DecodedInst.FLAG_READS_VARY) != 0) s.acc[5] = splatF(varying_c);
        }

        if (d.waddr_add != qpu.W.nop) {
            try write(RType, &s, r, env, d.waddr_add, d.add_file, add_result, d.cond_add, d.add_pack_a, 0);
        }
        if (d.waddr_mul != qpu.W.nop) {
            try write(RType, &s, r, env, d.waddr_mul, d.mul_file, mul_result, d.cond_mul, d.mul_pack_a, d.mul_pack_m);
        }

        switch (d.sig) {
            .load_tmu0, .load_tmu1 => {
                const t = &s.tmu[if (d.sig == .load_tmu0) 0 else 1];
                if (t.fifo_len == 0) return error.TmuUnderflow;
                s.acc[4] = t.fifo[0];
                std.mem.copyForwards(Vec, t.fifo[0 .. t.fifo_len - 1], t.fifo[1..t.fifo_len]);
                t.fifo_len -= 1;
            },
            .color_load => {
                s.acc[4] = env.tlb_color_in;
                if (@hasField(RType, "color_loads")) r.color_loads += 1;
            },
            .prog_end => end_at = ip + 2,
            .thread_switch, .last_thread_switch => switch_at = ip + 3,
            .none, .small_imm, .load_imm, .scoreboard_unlock, .wait_scoreboard => {},
            else => return error.Unsupported,
        }
    }
    if (@hasField(RType, "uniforms_read")) {
        r.uniforms_read = s.uniforms_read;
        r.varyings_read = s.varyings_read;
        r.vpm_words_read = s.vpm_words_read;
    }
    if (end_at == null) return error.MissingProgramEnd;
}

fn readPort(s: *State, env: *const Env, raddr: u6, file: File) Error!Vec {
    if (raddr < 32) {
        const bit = @as(u32, 1) << @intCast(raddr);
        if (file == .a) {
            return if ((s.ra_init & bit) != 0) s.ra[raddr] else splat(0);
        } else {
            return if ((s.rb_init & bit) != 0) s.rb[raddr] else splat(0);
        }
    }
    switch (raddr) {
        qpu.R.nop => return splat(0),
        qpu.R.unif => {
            if (s.uniforms_read >= env.uniforms.len) return error.UniformUnderflow;
            defer s.uniforms_read += 1;
            return splat(env.uniforms[s.uniforms_read]);
        },
        qpu.R.vary => {
            if (s.varyings_read >= env.varyings.len) return error.VaryingUnderflow;
            defer s.varyings_read += 1;
            const val_f: VecF = @bitCast(env.varyings[s.varyings_read]);
            const w_f: VecF = @bitCast(env.frag_w);
            const c_f: VecF = @splat(varying_c);
            return @bitCast((val_f - c_f) / w_f);
        },
        qpu.R.vpm => {
            if (s.vpm_read_left == 0 or s.vpm_words_read >= env.vpm_in.len) return error.VpmUnderflow;
            s.vpm_read_left -= 1;
            defer s.vpm_words_read += 1;
            return env.vpm_in[s.vpm_words_read];
        },
        qpu.R.elem_qpu => {
            return .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        },
        else => return error.Unsupported,
    }
}

fn write(comptime RType: type, s: *State, r: *RType, env: *const Env, waddr: u6, file: File, value: Vec, cond: qpu.Cond, a_pack: u4, mul_pack: u4) Error!void {
    if (waddr == qpu.W.nop or cond == .never) return;
    const is_register = waddr < 32 or (waddr >= qpu.W.acc0 and waddr <= qpu.W.acc0 + 3) or waddr == qpu.W.acc5;
    if (cond != .always and !is_register) return error.Unsupported; // conditional peripheral writes

    const dst: ?*Vec = switch (waddr) {
        0...31 => blk: {
            const bit = @as(u32, 1) << @intCast(waddr);
            if (file == .a) {
                if ((s.ra_init & bit) == 0) {
                    s.ra_init |= bit;
                    if (cond != .always or a_pack != 0 or mul_pack != 0) {
                        s.ra[waddr] = splat(0);
                    }
                }
                break :blk &s.ra[waddr];
            } else {
                if ((s.rb_init & bit) == 0) {
                    s.rb_init |= bit;
                    if (cond != .always or a_pack != 0 or mul_pack != 0) {
                        s.rb[waddr] = splat(0);
                    }
                }
                break :blk &s.rb[waddr];
            }
        },
        qpu.W.acc0...qpu.W.acc0 + 3 => &s.acc[waddr - qpu.W.acc0],
        qpu.W.acc5 => &s.acc[5],
        else => null,
    };
    if (dst) |d| {
        if (a_pack != 0 and (file != .a or waddr >= 32)) return error.Unsupported;
        if (cond == .always) {
            if (a_pack == 0) {
                switch (mul_pack) {
                    0 => {
                        d.* = value;
                        return;
                    },
                    3 => {
                        d.* = unorm8Vec(value) *% @as(VecU, @splat(0x01010101));
                        return;
                    },
                    4, 5, 6, 7 => {
                        const shift: u5 = @as(u5, @intCast(mul_pack - 4)) * 8;
                        const mask: VecU = @splat(@as(u32, 0xff) << shift);
                        const dv: VecU = d.*;
                        d.* = (dv & ~mask) | (unorm8Vec(value) << @as(@Vector(lanes, u5), @splat(shift)));
                        return;
                    },
                    else => return error.Unsupported,
                }
            }
            const dv: VecU = d.*;
            const vv: VecU = value;
            switch (a_pack) {
                1 => {
                    d.* = (dv & @as(VecU, @splat(0xffff0000))) | (vv & @as(VecU, @splat(0x0000ffff)));
                    return;
                },
                2 => {
                    d.* = (dv & @as(VecU, @splat(0x0000ffff))) | (vv << @as(@Vector(lanes, u5), @splat(16)));
                    return;
                },
                else => return error.Unsupported,
            }
        }
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
            if (@hasField(RType, "vpm_out")) {
                if (r.vpm_out_len >= max_vpm_out) return error.VpmOverflow;
                r.vpm_out[r.vpm_out_len] = value;
                r.vpm_out_len += 1;
            }
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
            if (@hasField(RType, "tlb_color_samples")) {
                if (r.tlb_samples < r.tlb_color_samples.len) r.tlb_color_samples[r.tlb_samples] = value;
                r.tlb_samples += 1;
            }
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
            if (s.uniforms_read >= env.uniforms.len) return error.UniformUnderflow;
            if (t.param_count == t.params.len) return error.Unsupported;
            t.params[t.param_count] = env.uniforms[s.uniforms_read];
            t.param_count += 1;
            s.uniforms_read += 1;
            if (waddr == qpu.W.tmu0_t or waddr == qpu.W.tmu1_t) {
                t.coord_t = value;
                t.has_coord_t = true;
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
            const cfg = texture.decodeConfig(p0, t.params[1]);
            const pt = try PrecomputedTex.init(cfg);
            var texel: Vec = undefined;
            var prev_sc: u32 = 0;
            var prev_tc: u32 = 0;
            var prev_out: u32 = 0;
            const has_t = t.has_coord_t;
            for (0..lanes) |lane| {
                const sc = value[lane];
                const tc = if (has_t) t.coord_t[lane] else 0;
                if (lane > 0 and sc == prev_sc and tc == prev_tc) {
                    texel[lane] = prev_out;
                    continue;
                }
                const sampled = try pt.sample(memory, f(sc), f(tc));
                texel[lane] = sampled;
                prev_sc = sc;
                prev_tc = tc;
                prev_out = sampled;
            }
            t.fifo[t.fifo_len] = texel;
            t.fifo_len += 1;
            t.param_count = 0;
            t.has_coord_t = false;
            if (@hasField(RType, "texture_samples")) r.texture_samples += 1;
        },
        else => return error.Unsupported,
    }
}

/// Where `Env.textures` are, one after another.
pub const texture_base: u32 = 1 << 28;

const PrecomputedTex = struct {
    cfg: texture.Config,
    base_off: u32,
    cpp: u32,
    fw: f32,
    fh: f32,
    uw_shift: u5,
    uh_shift: u5,
    uw_mask: u32,
    uh_mask: u32,
    cpp_shift: u5,
    utile_row_stride: u32,
    alpha_or_mask32: u32,
    alpha_or_mask64: u64,
    is_small_microtile: bool,
    utiles_per_row: u32,
    tile_w_shift: u5,
    tile_h_shift: u5,
    tiles_per_row: u32,

    inline fn init(p: texture.Config) Error!PrecomputedTex {
        const cpp: u32 = switch (p.type) {
            .rgba8888, .rgbx8888, .rgba32r => 4,
            .rgb565 => 2,
            .alpha, .luminance => 1,
            else => return error.Unsupported,
        };
        const uw_shift: u5 = if (cpp == 4) 2 else 3;
        const uh_shift: u5 = if (cpp == 1) 3 else 2;
        const uw: u32 = @as(u32, 1) << uw_shift;
        const uh: u32 = @as(u32, 1) << uh_shift;
        const cpp_shift: u5 = switch (cpp) {
            4 => 2,
            2 => 1,
            else => 0,
        };
        const tile_w_shift: u5 = uw_shift + 3;
        const tile_h_shift: u5 = uh_shift + 3;
        const tile_w: u32 = @as(u32, 1) << tile_w_shift;
        return .{
            .cfg = p,
            .base_off = p.offset & 0x1FFFFFFF,
            .cpp = cpp,
            .fw = @floatFromInt(p.width),
            .fh = @floatFromInt(p.height),
            .uw_shift = uw_shift,
            .uh_shift = uh_shift,
            .uw_mask = uw - 1,
            .uh_mask = uh - 1,
            .cpp_shift = cpp_shift,
            .utile_row_stride = if (p.type == .rgba32r) (p.width << 2) else (@as(u32, 1) << (uw_shift + cpp_shift)),
            .alpha_or_mask32 = if (p.type == .rgbx8888) 0xff000000 else 0,
            .alpha_or_mask64 = if (p.type == .rgbx8888) 0xff000000_ff000000 else 0,
            .is_small_microtile = (p.width <= (uw << 2) or p.height <= (uh << 2)),
            .utiles_per_row = (p.width + uw - 1) >> uw_shift,
            .tile_w_shift = tile_w_shift,
            .tile_h_shift = tile_h_shift,
            .tiles_per_row = (p.width + tile_w - 1) >> tile_w_shift,
        };
    }

    inline fn texelOffset(pt: *const PrecomputedTex, x: u32, y: u32) u32 {
        if (pt.cfg.type == .rgba32r) {
            return (y * pt.cfg.width + x) << 2;
        }
        const in_utile = (((y & pt.uh_mask) << pt.uw_shift) | (x & pt.uw_mask)) << pt.cpp_shift;
        if (pt.is_small_microtile) {
            return (((y >> pt.uh_shift) * pt.utiles_per_row + (x >> pt.uw_shift)) << 6) + in_utile;
        }
        const tile_row = y >> pt.tile_h_shift;
        const tile_col = if ((tile_row & 1) == 0) (x >> pt.tile_w_shift) else pt.tiles_per_row - 1 - (x >> pt.tile_w_shift);
        const tile_base = (tile_row * pt.tiles_per_row + tile_col) << 12;

        const sub_col = (x >> (pt.uw_shift + 2)) & 1;
        const sub_row = (y >> (pt.uh_shift + 2)) & 1;
        const stile_index = (sub_row << 1) | sub_col;
        const even_map = [4]u32{ 0, 3, 1, 2 };
        const odd_map = [4]u32{ 2, 1, 3, 0 };
        const sub_index = if ((tile_row & 1) == 0) even_map[stile_index] else odd_map[stile_index];
        const utile_in_sub = (((y >> pt.uh_shift) & 3) << 2) | ((x >> pt.uw_shift) & 3);
        return tile_base + (sub_index << 10) + (utile_in_sub << 6) + in_utile;
    }

    inline fn fetchFromOffset(pt: *const PrecomputedTex, memory: []const u8, offset: u32) Error!u32 {
        if (offset + pt.cpp > memory.len) return error.Unsupported;
        if (pt.cpp == 4) {
            return std.mem.readInt(u32, memory[offset..][0..4], .little) | pt.alpha_or_mask32;
        }
        if (pt.cpp == 1) {
            if (pt.cfg.type == .luminance) {
                const l: u32 = memory[offset];
                return 0xff000000 | (l * 0x010101);
            }
            return @as(u32, memory[offset]) << 24;
        }
        return pixel.fromRgb565(std.mem.readInt(u16, memory[offset..][0..2], .little));
    }

    inline fn fetchPairFromOffset(pt: *const PrecomputedTex, memory: []const u8, offset: u32) Error![2]u32 {
        if (offset + (pt.cpp << 1) > memory.len) return error.Unsupported;
        if (pt.cpp == 4) {
            const pair = std.mem.readInt(u64, memory[offset..][0..8], .little) | pt.alpha_or_mask64;
            return .{ @truncate(pair), @truncate(pair >> 32) };
        }
        if (pt.cpp == 1) {
            const b0: u32 = memory[offset];
            const b1: u32 = memory[offset + 1];
            if (pt.cfg.type == .luminance) {
                return .{ 0xff000000 | (b0 * 0x010101), 0xff000000 | (b1 * 0x010101) };
            }
            return .{ b0 << 24, b1 << 24 };
        }
        const raw = std.mem.readInt(u32, memory[offset..][0..4], .little);
        return .{ pixel.fromRgb565(@truncate(raw)), pixel.fromRgb565(@truncate(raw >> 16)) };
    }

    inline fn fetchAt(pt: *const PrecomputedTex, memory: []const u8, x: u32, y: u32) Error!u32 {
        return pt.fetchFromOffset(memory, pt.base_off + pt.texelOffset(x, y));
    }

    inline fn sample(pt: *const PrecomputedTex, memory: []const u8, s: f32, t: f32) Error!u32 {
        const p = pt.cfg;
        if (p.mag_filter == .nearest) {
            const fx = @floor(s * pt.fw);
            const fy = @floor(t * pt.fh);
            const wx: u32 = if (fx >= 0.0 and fx < pt.fw) @intFromFloat(fx) else try wrap(fx, p.width, p.wrap_s);
            const wy: u32 = if (fy >= 0.0 and fy < pt.fh) @intFromFloat(fy) else try wrap(fy, p.height, p.wrap_t);
            return pt.fetchAt(memory, wx, wy);
        }
        const fx = s * pt.fw - 0.5;
        const fy = t * pt.fh - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        var wx0: u32 = undefined;
        var wx1: u32 = undefined;
        if (x0 >= 0.0 and x0 + 1.0 < pt.fw) {
            wx0 = @intFromFloat(x0);
            wx1 = wx0 + 1;
        } else {
            wx0 = try wrap(x0, p.width, p.wrap_s);
            wx1 = try wrap(x0 + 1.0, p.width, p.wrap_s);
        }
        var wy0: u32 = undefined;
        var wy1: u32 = undefined;
        if (y0 >= 0.0 and y0 + 1.0 < pt.fh) {
            wy0 = @intFromFloat(y0);
            wy1 = wy0 + 1;
        } else {
            wy0 = try wrap(y0, p.height, p.wrap_t);
            wy1 = try wrap(y0 + 1.0, p.height, p.wrap_t);
        }

        const same_utile_x = (wx1 == wx0 + 1) and (p.type == .rgba32r or (wx0 & pt.uw_mask) != pt.uw_mask);
        const same_utile_y = (wy1 == wy0 + 1) and (p.type == .rgba32r or (wy0 & pt.uh_mask) != pt.uh_mask);

        var c00: u32 = undefined;
        var c10: u32 = undefined;
        var c01: u32 = undefined;
        var c11: u32 = undefined;

        if (same_utile_x and same_utile_y) {
            const off00 = pt.base_off + pt.texelOffset(wx0, wy0);
            const row0 = try pt.fetchPairFromOffset(memory, off00);
            const row1 = try pt.fetchPairFromOffset(memory, off00 + pt.utile_row_stride);
            c00 = row0[0];
            c10 = row0[1];
            c01 = row1[0];
            c11 = row1[1];
        } else if (same_utile_x) {
            const row0 = try pt.fetchPairFromOffset(memory, pt.base_off + pt.texelOffset(wx0, wy0));
            const row1 = if (wy1 == wy0) row0 else try pt.fetchPairFromOffset(memory, pt.base_off + pt.texelOffset(wx0, wy1));
            c00 = row0[0];
            c10 = row0[1];
            c01 = row1[0];
            c11 = row1[1];
        } else if (same_utile_y) {
            const off00 = pt.base_off + pt.texelOffset(wx0, wy0);
            c00 = try pt.fetchFromOffset(memory, off00);
            c01 = try pt.fetchFromOffset(memory, off00 + pt.utile_row_stride);
            if (wx1 == wx0) {
                c10 = c00;
                c11 = c01;
            } else {
                const off10 = pt.base_off + pt.texelOffset(wx1, wy0);
                c10 = try pt.fetchFromOffset(memory, off10);
                c11 = try pt.fetchFromOffset(memory, off10 + pt.utile_row_stride);
            }
        } else {
            c00 = try pt.fetchAt(memory, wx0, wy0);
            if (wx0 == wx1 and wy0 == wy1) return c00;
            c10 = if (wx1 == wx0) c00 else try pt.fetchAt(memory, wx1, wy0);
            c01 = if (wy1 == wy0) c00 else try pt.fetchAt(memory, wx0, wy1);
            c11 = if (wx1 == wx0) c01 else if (wy1 == wy0) c10 else try pt.fetchAt(memory, wx1, wy1);
        }

        if (c00 == c10 and c00 == c01 and c00 == c11) return c00;
        const ax = fx - x0;
        const ay = fy - y0;
        const w00 = (1.0 - ax) * (1.0 - ay);
        const w10 = ax * (1.0 - ay);
        const w01 = (1.0 - ax) * ay;
        const w11 = ax * ay;
        const V4U8 = @Vector(4, u8);
        const V4F = @Vector(4, f32);
        const v00: V4F = @floatFromInt(@as(V4U8, @bitCast(c00)));
        const v10: V4F = @floatFromInt(@as(V4U8, @bitCast(c10)));
        const v01: V4F = @floatFromInt(@as(V4U8, @bitCast(c01)));
        const v11: V4F = @floatFromInt(@as(V4U8, @bitCast(c11)));
        const blended = @round(
            v00 * @as(V4F, @splat(w00)) +
                v10 * @as(V4F, @splat(w10)) +
                v01 * @as(V4F, @splat(w01)) +
                v11 * @as(V4F, @splat(w11)),
        );
        const out_bytes: V4U8 = @intFromFloat(blended);
        return @bitCast(out_bytes);
    }
};

/// Sampling of an RGBA8888, RGB565 or ALPHA texture, with repeat or
/// clamp wrapping. A 32-bit texel comes back as it is in memory; an RGB565
/// one with its top 5 bits (blue) in the low byte, then green and red (each
/// widened to 8 bits), and opaque, in the same order as a 32-bit texel; an
/// ALPHA one in the top byte, with the rest 0 (its A8 swizzle is 000W).
///
/// Only level 0 is sampled (which mipmap level the hardware picks depends
/// on the neighbouring pixels, which the simulator does not have), with the
/// magnification filter: nearest, or bilinear.
pub fn sample(memory: []const u8, p0: u32, p1: u32, s: f32, t: f32) Error!u32 {
    const pt = try PrecomputedTex.init(texture.decodeConfig(p0, p1));
    return pt.sample(memory, s, t);
}

/// A texel's column (or row), wrapped into the texture.
fn wrap(coord: f32, size: u32, mode: texture.Wrap) Error!u32 {
    const n: i64 = @max(size, 1);
    const i: i64 = if (std.math.isNan(coord)) 0 else @intFromFloat(std.math.clamp(coord, -1e9, 1e9));
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
    const uw_shift: u5 = if (cpp == 4) 2 else 3;
    const uh_shift: u5 = if (cpp == 1) 3 else 2;
    const uw: u32 = @as(u32, 1) << uw_shift;
    const uh: u32 = @as(u32, 1) << uh_shift;
    const cpp_shift: u5 = switch (cpp) {
        4 => 2,
        2 => 1,
        else => 0,
    };
    const in_utile = (((y & (uh - 1)) << uw_shift) | (x & (uw - 1))) << cpp_shift;
    if (width <= (uw << 2) or height <= (uh << 2)) {
        const utiles_per_row = (width + uw - 1) >> uw_shift;
        return (((y >> uh_shift) * utiles_per_row + (x >> uw_shift)) << 6) + in_utile;
    }
    const tile_w_shift: u5 = uw_shift + 3;
    const tile_h_shift: u5 = uh_shift + 3;
    const tile_w: u32 = @as(u32, 1) << tile_w_shift;
    const tiles_per_row = (width + tile_w - 1) >> tile_w_shift;
    const tile_row = y >> tile_h_shift;
    const tile_col = if ((tile_row & 1) == 0) (x >> tile_w_shift) else tiles_per_row - 1 - (x >> tile_w_shift);
    const tile_base = (tile_row * tiles_per_row + tile_col) << 12;

    const sub_col = (x >> (uw_shift + 2)) & 1;
    const sub_row = (y >> (uh_shift + 2)) & 1;
    const stile_index = (sub_row << 1) | sub_col;
    const even_map = [4]u32{ 0, 3, 1, 2 };
    const odd_map = [4]u32{ 2, 1, 3, 0 };
    const sub_index = if ((tile_row & 1) == 0) even_map[stile_index] else odd_map[stile_index];
    const utile_in_sub = (((y >> uh_shift) & 3) << 2) | ((x >> uw_shift) & 3);
    return tile_base + (sub_index << 10) + (utile_in_sub << 6) + in_utile;
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

test "QPU TMU bilinear same-utile and cross-utile sampling" {
    var mem: [4096]u8 = @splat(0);
    const cfg: texture.Config = .{
        .offset = 0,
        .width = 8,
        .height = 8,
        .type = .rgba8888,
        .mag_filter = .linear,
        .min_filter = .linear,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
    };
    const pt = try PrecomputedTex.init(cfg);
    for (0..8) |y| {
        for (0..8) |x| {
            const off = pt.texelOffset(@intCast(x), @intCast(y));
            const color: u32 = 0xff000000 |
                (@as(u32, @intCast(x * 30)) << 16) |
                (@as(u32, @intCast(y * 30)) << 8) |
                @as(u32, @intCast((x + y) * 15));
            std.mem.writeInt(u32, mem[off..][0..4], color, .little);
        }
    }

    // Same-utile sample: between (1, 1) and (2, 2) at midpoint -> s = 2.0/8.0, t = 2.0/8.0
    const s_same = try pt.sample(&mem, 2.0 / 8.0, 2.0 / 8.0);
    // Expected average of (1,1), (2,1), (1,2), (2,2): R = 45, G = 45, B = 45, A = 255
    try std.testing.expectEqual(@as(u32, 0xff2d2d2d), s_same);

    // Cross-utile X & Y sample: between (3, 3) and (4, 4) at midpoint -> s = 4.0/8.0, t = 4.0/8.0
    const s_cross = try pt.sample(&mem, 4.0 / 8.0, 4.0 / 8.0);
    // Expected average of (3,3), (4,3), (3,4), (4,4): R = 105, G = 105, B = 105, A = 255
    try std.testing.expectEqual(@as(u32, 0xff696969), s_cross);
}

test "QPU vectorized v8muld, v8min, v8max, v8adds, v8subs, and shifts" {
    // Exhaustively verify v8muldVec matches (a * b + 127) / 255 for all 65,536 byte pairs
    var a_vec: Vec = undefined;
    var b_vec: Vec = undefined;
    var pair: u32 = 0;
    while (pair < 65536) : (pair += 64) {
        for (0..lanes) |l| {
            var aw: u32 = 0;
            var bw: u32 = 0;
            inline for (0..4) |bi| {
                const idx = pair + @as(u32, @intCast(l * 4 + bi));
                const a8: u32 = idx & 0xff;
                const b8: u32 = (idx >> 8) & 0xff;
                aw |= a8 << @intCast(bi * 8);
                bw |= b8 << @intCast(bi * 8);
            }
            a_vec[l] = aw;
            b_vec[l] = bw;
        }
        const got = mulOpVec(.v8muld, a_vec, b_vec);
        for (0..lanes) |l| {
            var exp: u32 = 0;
            inline for (0..4) |bi| {
                const idx = pair + @as(u32, @intCast(l * 4 + bi));
                const a8: u32 = idx & 0xff;
                const b8: u32 = (idx >> 8) & 0xff;
                exp |= ((a8 * b8 + 127) / 255) << @intCast(bi * 8);
            }
            try std.testing.expectEqual(exp, got[l]);
        }
    }

    const va = splat(0xf080_1005);
    const vb = splat(0x2090_0810);
    try std.testing.expectEqual(@as(u32, 0xffff_1815), addOpVec(.v8adds, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0xd000_0800), addOpVec(.v8subs, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0x2080_0805), mulOpVec(.v8min, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0xf090_1010), mulOpVec(.v8max, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0x05f0_8010), addOpVec(.ror, va, splat(8))[0]);
}
