//! Shader compiler: builds shaders as a list of SSA values and generates
//! QPU code for them.
//!
//! Shaders are straight-line programs (the shader lowering predicates
//! control flow before it gets here). Each value is produced by exactly
//! one instruction; the builder methods on `Shader` append instructions
//! and return the value they define.
//!
//! Compilation runs these passes:
//!
//! 1. Dead code elimination, keeping instructions with side effects
//!    (FIFO reads, texture fetches, outputs).
//! 2. Operand folding: constants that fit the small immediate field and
//!    uniforms used once are read directly by their consumer instead of
//!    being loaded into a register.
//! 3. Linear-scan register allocation over the accumulators r0-r2 and the
//!    two 32-entry register files. r3 is kept free for fixing up read port
//!    conflicts, r4 and r5 are written by the hardware, and ra14/rb14 and
//!    ra15/rb15 are left alone (the latter hold the fragment W and Z
//!    payload).
//! 4. Code generation, one ALU operation per instruction, inserting NOPs
//!    where the hardware would otherwise read a stale value.
//!
//! The uniform stream layout comes out of code generation, since it is
//! defined by the order in which instructions read uniforms. Texture
//! fetches consume two uniforms implicitly (the P0 and P1 config words).

const std = @import("std");
const qpu = @import("qpu.zig");
const qpu_schedule = @import("qpu_schedule.zig");
const v3d_qpu = @import("v3d_qpu.zig");

pub const Stage = qpu.Stage;

pub const max_insts = 1024;
pub const max_code = 2048;
pub const max_uniforms = 128;

/// An SSA value: the index of the instruction that defines it.
pub const Value = enum(u16) { _ };

pub const Op = enum {
    /// Reads a uniform; `imm` is the caller's uniform index.
    uniform,
    /// A 32-bit constant; `imm` holds its bits.
    constant,
    /// Next attribute word from the VPM (vertex and coordinate shaders).
    vpm_read,
    /// Next perspective-correct varying (fragment shaders).
    varying,
    /// The fragment's depth, already in the format the tile buffer expects.
    frag_z,
    /// The fragment's W.
    frag_w,

    // Add ALU
    fadd,
    fsub,
    fmin,
    fmax,
    /// max(|a|, |b|); abs(x) is fmaxabs(x, x).
    fmaxabs,
    ftoi,
    itof,
    add,
    sub,
    shl,
    shr,
    asr,
    @"and",
    @"or",
    xor,
    min,
    max,
    // Mul ALU
    fmul,
    // Special function unit
    recip,
    rsqrt,
    exp2,
    log2,

    /// Byte `imm` of a packed 8888 value as a float in [0, 1].
    unpack_unorm8,
    /// Four floats in [0, 1] packed as 8-bit unorm bytes 0 to 3.
    pack_unorm8888,
    /// Two floats in 1/16ths of a pixel packed as the int16 X|Y pair the
    /// hardware expects for screen coordinates.
    pack_screen_xy,
    /// Samples texture unit 0 at (s, t); the result is a packed 8888 texel.
    tex,
    /// The colour already in the tile buffer at this fragment (fragment
    /// shaders), as a packed 8888 value: what blending mixes with.
    tlb_color_load,

    // Outputs
    vpm_write,
    tlb_z,
    tlb_color,
    /// A colour for the next sample of the fragment (multisampled frames:
    /// four, in turn).
    tlb_color_ms,

    fn hasResult(op: Op) bool {
        return switch (op) {
            .vpm_write, .tlb_z, .tlb_color, .tlb_color_ms => false,
            else => true,
        };
    }

    /// Instructions that must be kept even if their result is unused.
    fn hasSideEffects(op: Op) bool {
        return switch (op) {
            .vpm_read, .varying, .tex, .vpm_write, .tlb_z, .tlb_color, .tlb_color_ms => true,
            else => false,
        };
    }

    fn addOp(op: Op) ?qpu.AddOp {
        return switch (op) {
            .fadd => .fadd,
            .fsub => .fsub,
            .fmin => .fmin,
            .fmax => .fmax,
            .fmaxabs => .fmaxabs,
            .ftoi => .ftoi,
            .itof => .itof,
            .add => .add,
            .sub => .sub,
            .shl => .shl,
            .shr => .shr,
            .asr => .asr,
            .@"and" => .@"and",
            .@"or" => .@"or",
            .xor => .xor,
            .min => .min,
            .max => .max,
            else => null,
        };
    }

    fn sfuWaddr(op: Op) ?u6 {
        return switch (op) {
            .recip => qpu.W.sfu_recip,
            .rsqrt => qpu.W.sfu_recipsqrt,
            .exp2 => qpu.W.sfu_exp,
            .log2 => qpu.W.sfu_log,
            else => null,
        };
    }

    fn isAlu(op: Op) bool {
        return op == .fmul or op.addOp() != null;
    }
};

pub const Inst = struct {
    op: Op,
    srcs: [4]Value = undefined,
    nsrc: u3 = 0,
    imm: u32 = 0,
};

pub const Shader = struct {
    stage: Stage,
    insts: [max_insts]Inst = undefined,
    len: usize = 0,

    pub fn init(stage: Stage) Shader {
        return .{ .stage = stage };
    }

    fn push(s: *Shader, inst: Inst) Value {
        std.debug.assert(s.len < max_insts);
        s.insts[s.len] = inst;
        s.len += 1;
        return @enumFromInt(s.len - 1);
    }

    fn pushSrcs(s: *Shader, op: Op, srcs: []const Value, imm: u32) Value {
        var inst: Inst = .{ .op = op, .nsrc = @intCast(srcs.len), .imm = imm };
        @memcpy(inst.srcs[0..srcs.len], srcs);
        return s.push(inst);
    }

    pub fn uniform(s: *Shader, index: u32) Value {
        return s.push(.{ .op = .uniform, .imm = index });
    }
    pub fn constant(s: *Shader, bits: u32) Value {
        return s.push(.{ .op = .constant, .imm = bits });
    }
    pub fn constantF(s: *Shader, v: f32) Value {
        return s.constant(@bitCast(v));
    }
    pub fn vpmRead(s: *Shader) Value {
        std.debug.assert(s.stage != .fragment);
        return s.push(.{ .op = .vpm_read });
    }
    pub fn varying(s: *Shader) Value {
        std.debug.assert(s.stage == .fragment);
        return s.push(.{ .op = .varying });
    }
    pub fn fragZ(s: *Shader) Value {
        return s.push(.{ .op = .frag_z });
    }
    pub fn fragW(s: *Shader) Value {
        return s.push(.{ .op = .frag_w });
    }
    pub fn binary(s: *Shader, op: Op, a: Value, b: Value) Value {
        std.debug.assert(op.isAlu());
        return s.pushSrcs(op, &.{ a, b }, 0);
    }
    pub fn unary(s: *Shader, op: Op, a: Value) Value {
        return s.pushSrcs(op, &.{a}, 0);
    }
    pub fn fadd(s: *Shader, a: Value, b: Value) Value {
        return s.binary(.fadd, a, b);
    }
    pub fn fsub(s: *Shader, a: Value, b: Value) Value {
        return s.binary(.fsub, a, b);
    }
    pub fn fmul(s: *Shader, a: Value, b: Value) Value {
        return s.binary(.fmul, a, b);
    }
    pub fn recip(s: *Shader, a: Value) Value {
        return s.unary(.recip, a);
    }
    pub fn unpackUnorm8(s: *Shader, packed_value: Value, byte: u2) Value {
        return s.pushSrcs(.unpack_unorm8, &.{packed_value}, byte);
    }
    pub fn packUnorm8888(s: *Shader, b0: Value, b1: Value, b2: Value, b3: Value) Value {
        return s.pushSrcs(.pack_unorm8888, &.{ b0, b1, b2, b3 }, 0);
    }
    pub fn packScreenXy(s: *Shader, x: Value, y: Value) Value {
        return s.pushSrcs(.pack_screen_xy, &.{ x, y }, 0);
    }
    /// Samples the draw's texture `slot` (0 to 2) at (s, t). Each sample
    /// carries its texture's config, so a texture unit can sample several
    /// textures: the slots take turns between the two units (0 and 2 on
    /// unit 0, 1 on unit 1), so that two different textures can be fetched
    /// at once.
    pub fn texture(s: *Shader, slot: u2, tex_s: Value, tex_t: Value) Value {
        return s.pushSrcs(.tex, &.{ tex_s, tex_t }, slot);
    }
    /// The colour the tile buffer holds at this fragment, packed like
    /// `tlbColor`'s input (fragment shaders). Read it to blend.
    pub fn tlbColorLoad(s: *Shader) Value {
        std.debug.assert(s.stage == .fragment);
        return s.push(.{ .op = .tlb_color_load });
    }
    pub fn vpmWrite(s: *Shader, v: Value) void {
        _ = s.pushSrcs(.vpm_write, &.{v}, 0);
    }
    pub fn tlbZ(s: *Shader, v: Value) void {
        _ = s.pushSrcs(.tlb_z, &.{v}, 0);
    }
    pub fn tlbColor(s: *Shader, v: Value) void {
        _ = s.pushSrcs(.tlb_color, &.{v}, 0);
    }
    /// Writes the colour of the fragment's next sample (in a multisampled
    /// frame: each of the four, in turn, after reading each of them with
    /// `tlbColorLoad`).
    pub fn tlbColorMs(s: *Shader, v: Value) void {
        _ = s.pushSrcs(.tlb_color_ms, &.{v}, 0);
    }

    fn operands(s: *const Shader, i: usize) []const Value {
        return s.insts[i].srcs[0..s.insts[i].nsrc];
    }
};

/// What each word of a shader's uniform stream must contain.
pub const UniformKind = union(enum) {
    /// The caller's uniform with this index.
    user: u32,
    /// Texture config parameter 0 (relocated by the kernel) for a texture
    /// slot.
    tex_p0: u8,
    /// Texture config parameter 1 for a texture slot.
    tex_p1: u8,
    /// A literal 32-bit immediate word (V3D 4.2 constant uniform).
    constant: u32,
};

pub const Compiled = struct {
    stage: Stage,
    code_buf: [max_code]qpu.Inst = undefined,
    code_len: usize = 0,
    uniform_buf: [max_uniforms]UniformKind = undefined,
    uniform_len: usize = 0,
    num_vpm_reads: u32 = 0,
    num_vpm_writes: u32 = 0,
    num_varyings: u32 = 0,
    num_texture_samples: u32 = 0,
    /// A fragment shader that runs two threads per QPU (see
    /// `Options.threaded`): its draws must say so in their shader record.
    threaded: bool = false,

    pub fn code(c: *const Compiled) []const qpu.Inst {
        return c.code_buf[0..c.code_len];
    }

    /// The texture slots it samples, a bit each (a draw must give them).
    pub fn textureSlots(c: *const Compiled) u4 {
        var slots: u4 = 0;
        for (c.uniforms()) |k| switch (k) {
            .tex_p0 => |slot| slots |= @as(u4, 1) << @intCast(slot),
            else => {},
        };
        return slots;
    }

    pub fn uniforms(c: *const Compiled) []const UniformKind {
        return c.uniform_buf[0..c.uniform_len];
    }
};

pub const Error = qpu.EncodeError || qpu.ValidationError || qpu_schedule.Error || v3d_qpu.EncodeError || error{
    OutOfRegisters,
    /// `Options.threaded` was true for a shader that cannot be threaded.
    CannotThread,
    ProgramTooLong,
    TooManyUniforms,
};

const Reg = union(enum) {
    none,
    acc: u3,
    a: u5,
    b: u5,
    /// Read directly from the uniform port.
    unif,
    /// Encoded small immediate.
    imm: u6,

    fn src(r: Reg) qpu.Src {
        return switch (r) {
            .acc => |n| qpu.r(n),
            .a => |n| qpu.ra(n),
            .b => |n| qpu.rb(n),
            .unif => qpu.unif,
            .imm => |v| .{ .imm = v },
            .none => unreachable,
        };
    }

    fn dst(r: Reg) qpu.Dst {
        return switch (r) {
            .none => .nop,
            .acc => |n| qpu.wr(n),
            .a => |n| qpu.wa(n),
            .b => |n| qpu.wb(n),
            .unif, .imm => unreachable,
        };
    }

    fn file(r: Reg) ?qpu.Mux {
        return switch (r) {
            .a, .unif => .a,
            .b, .imm => .b,
            else => null,
        };
    }
};

const one_bits: u32 = @bitCast(@as(f32, 1.0));

fn encodeSmallImm(bits: u32) ?u6 {
    const i: i32 = @bitCast(bits);
    if (i >= 0 and i <= 15) return @intCast(i);
    if (i >= -16 and i < 0) return @intCast(i + 32);
    const fv: f32 = @bitCast(bits);
    inline for (0..16) |k| {
        const e: i32 = @as(i32, k) - 8;
        if (fv == std.math.pow(f32, 2.0, @floatFromInt(e)))
            return if (e >= 0) @intCast(32 + e) else @intCast(48 + e);
    }
    return null;
}

const Allocator = struct {
    acc_free: [3]bool = @splat(true),

    a_free: [32]bool = blk: {
        var f: [32]bool = @splat(true);
        f[14] = false;
        f[15] = false;
        break :blk f;
    },
    b_free: [32]bool = blk: {
        var f: [32]bool = @splat(true);
        f[14] = false;
        f[15] = false;
        break :blk f;
    },

    /// For a threaded shader: each thread has only the lower half of each
    /// register file.
    fn halve(al: *Allocator) void {
        for (al.a_free[16..]) |*f| f.* = false;
        for (al.b_free[16..]) |*f| f.* = false;
    }

    fn take(al: *Allocator, comptime field: []const u8) ?u5 {
        const arr = &@field(al, field);
        for (arr, 0..) |*free, n| if (free.*) {
            free.* = false;
            return @intCast(n);
        };
        return null;
    }

    fn release(al: *Allocator, r: Reg) void {
        switch (r) {
            .acc => |n| al.acc_free[n] = true,
            .a => |n| al.a_free[n] = true,
            .b => |n| al.b_free[n] = true,
            else => {},
        }
    }
};

const Class = enum { any, a_only };

pub const Options = struct {
    /// Reorder and pair instructions (see qpu_schedule.zig). Without it,
    /// code runs one operation per instruction with NOPs for hazards.
    schedule: bool = true,
    /// Run a fragment shader two threads per QPU: after each texture
    /// request the QPU switches to the other thread while the texture unit
    /// fetches, hiding its latency. Each thread then has half the register
    /// files, and no value may stay in an accumulator across a switch.
    /// Null (the default) threads fragment shaders that sample textures,
    /// falling back to one thread if the registers run out.
    threaded: ?bool = null,
};

/// Whether a fragment shader can be threaded: it samples a texture, and
/// touches the tile buffer only after its last sample (the last thread
/// switch must come before the scoreboard is taken).
fn canThread(shader: *const Shader, live: *const [max_insts]bool) bool {
    if (shader.stage != .fragment) return false;
    var last_tex: ?usize = null;
    for (0..shader.len) |j| if (live[j] and shader.insts[j].op == .tex) {
        last_tex = j;
    };
    const t = last_tex orelse return false;
    for (0..t) |j| if (live[j]) switch (shader.insts[j].op) {
        .tlb_color_load, .tlb_z, .tlb_color, .tlb_color_ms => return false,
        else => {},
    };
    return true;
}

fn liveness(shader: *const Shader, live: *[max_insts]bool, uses: *[max_insts]u16, last_use: *[max_insts]u16) void {
    var i: usize = shader.len;
    while (i > 0) {
        i -= 1;
        if (shader.insts[i].op.hasSideEffects()) live[i] = true;
        if (!live[i]) continue;
        for (shader.operands(i)) |v| {
            const d = @intFromEnum(v);
            live[d] = true;
            uses[d] += 1;
            last_use[d] = @max(last_use[d], @as(u16, @intCast(i)));
        }
    }
}

/// Whether each value is read by an instruction that contributes to the
/// shader's outputs.
pub fn usedValues(shader: *const Shader) [max_insts]bool {
    var live: [max_insts]bool = @splat(false);
    var uses: [max_insts]u16 = @splat(0);
    var last_use: [max_insts]u16 = @splat(0);
    liveness(shader, &live, &uses, &last_use);
    var used: [max_insts]bool = undefined;
    for (&used, uses) |*u, n| u.* = n > 0;
    return used;
}

pub fn compile(shader: *const Shader) Error!Compiled {
    return compileWithOptions(shader, .{});
}

pub fn compileWithOptions(shader: *const Shader, options: Options) Error!Compiled {
    if (options.threaded orelse true) {
        var live: [max_insts]bool = @splat(false);
        var uses: [max_insts]u16 = @splat(0);
        var last_use: [max_insts]u16 = @splat(0);
        liveness(shader, &live, &uses, &last_use);
        if (canThread(shader, &live)) {
            if (compileThreaded(shader, options, true)) |c| return c else |err| {
                // Half the registers were not enough: one thread, then.
                if (err != error.OutOfRegisters or options.threaded != null) return err;
            }
        } else if (options.threaded == true) return error.CannotThread;
    }
    return compileThreaded(shader, options, false);
}

fn compileThreaded(shader: *const Shader, options: Options, threaded: bool) Error!Compiled {
    const n = shader.len;
    var live: [max_insts]bool = @splat(false);
    var uses: [max_insts]u16 = @splat(0);
    var last_use: [max_insts]u16 = @splat(0);
    var class: [max_insts]Class = @splat(.any);
    var reg: [max_insts]Reg = @splat(.none);

    // 1. Liveness: keep side effects and their inputs.
    liveness(shader, &live, &uses, &last_use);

    // 2. Operand folding and register class constraints.
    var folded: [max_insts]bool = @splat(false);
    for (0..n) |j| {
        if (!live[j]) continue;
        const inst = shader.insts[j];
        switch (inst.op) {
            .pack_screen_xy, .tex, .tlb_color_load => class[j] = .a_only,
            .unpack_unorm8 => class[@intFromEnum(inst.srcs[0])] = .a_only,
            else => {},
        }
        if (!inst.op.isAlu() and inst.op != .vpm_write) continue;
        // At most one operand can come from the uniform port and one from
        // the small immediate field per instruction.
        var used_unif = false;
        var used_imm: ?u32 = null;
        for (shader.operands(j)) |v| {
            const d = @intFromEnum(v);
            const def = shader.insts[d];
            if (def.op == .uniform and uses[d] == 1 and !used_unif) {
                folded[d] = true;
                used_unif = true;
            } else if (def.op == .constant and encodeSmallImm(def.imm) != null and
                (used_imm == null or used_imm.? == def.imm))
            {
                used_imm = def.imm;
            }
        }
    }
    // Constants are only materialised if some use cannot take them as an
    // immediate; decided per use during code generation, so count register
    // uses here.
    var reg_uses: [max_insts]u16 = @splat(0);
    for (0..n) |j| {
        if (!live[j]) continue;
        const inst = shader.insts[j];
        var used_imm: ?u32 = null;
        for (shader.operands(j)) |v| {
            const d = @intFromEnum(v);
            const def = shader.insts[d];
            if (folded[d]) continue;
            if (def.op == .constant and (inst.op.isAlu() or inst.op == .vpm_write)) {
                if (encodeSmallImm(def.imm)) |_| if (used_imm == null or used_imm.? == def.imm) {
                    used_imm = def.imm;
                    continue;
                };
            }
            // The colour pack multiplies each channel by the immediate 1.0,
            // so a constant 1.0 channel can use the same immediate.
            if (def.op == .constant and inst.op == .pack_unorm8888 and def.imm == one_bits) continue;
            reg_uses[d] += 1;
        }
    }

    // Register file preferences: a value read together with a uniform
    // (regfile A port) is better in regfile B, and one read together with a
    // small immediate (regfile B port) is better in regfile A, saving a
    // move to resolve the read port conflict.
    const FilePref = enum { none, a, b };
    var pref: [max_insts]FilePref = @splat(.none);
    for (0..n) |j| {
        if (!live[j]) continue;
        const inst = shader.insts[j];
        if (inst.op == .pack_unorm8888) {
            for (shader.operands(j)) |v| pref[@intFromEnum(v)] = .a;
            continue;
        }
        if (!inst.op.isAlu() or inst.nsrc != 2) continue;
        for (0..2) |k| {
            const other = @intFromEnum(inst.srcs[1 - k]);
            const me = @intFromEnum(inst.srcs[k]);
            if (other == me) continue;
            if (folded[other]) pref[me] = .b;
            if (shader.insts[other].op == .constant and reg_uses[other] == 0) pref[me] = .a;
        }
    }

    // 3. Register allocation, in program order. A value's register is freed
    // after the instruction holding its last use, so a destination never
    // shares a register with one of its own sources.
    var al: Allocator = .{};
    if (threaded) al.halve();
    // Thread switches come after texture requests: accumulators do not
    // survive them.
    var crosses_switch: [max_insts]bool = @splat(false);
    if (threaded) {
        for (0..n) |t| if (live[t] and shader.insts[t].op == .tex) {
            for (0..t) |d| if (live[d] and last_use[d] > t) {
                crosses_switch[d] = true;
            };
        };
    }
    var next_file_a = true;
    var active: [max_insts]bool = @splat(false);
    for (0..n) |j| {
        // Free values whose last use was before this instruction.
        for (0..j) |d| {
            if (active[d] and last_use[d] < j) {
                al.release(reg[d]);
                active[d] = false;
            }
        }
        if (!live[j] or !shader.insts[j].op.hasResult()) continue;
        const op = shader.insts[j].op;
        switch (op) {
            .frag_z => {
                reg[j] = .{ .b = qpu.R.frag_payload_zw };
                continue;
            },
            .frag_w => {
                reg[j] = .{ .a = qpu.R.frag_payload_zw };
                continue;
            },
            else => {},
        }
        if (folded[j]) {
            reg[j] = .unif;
            continue;
        }
        const needs_reg = if (op == .constant) reg_uses[j] > 0 else uses[j] > 0;
        if (!needs_reg) {
            if (op == .constant) {
                if (encodeSmallImm(shader.insts[j].imm)) |v| reg[j] = .{ .imm = v };
            }
            continue; // result discarded
        }
        const span = last_use[j] - j;
        var r: ?Reg = null;
        const acc_ok = class[j] == .any and !crosses_switch[j];
        if (acc_ok and span <= 4) {
            if (al.take("acc_free")) |a| r = .{ .acc = @intCast(a) };
        }
        if (r == null) {
            const prefer_a = class[j] == .a_only or switch (pref[j]) {
                .a => true,
                .b => false,
                .none => next_file_a,
            };
            if (prefer_a) {
                if (al.take("a_free")) |a| r = .{ .a = a };
            }
            if (r == null and class[j] == .any) {
                if (al.take("b_free")) |b| r = .{ .b = b };
            }
            if (r == null and class[j] == .any and !prefer_a) {
                if (al.take("a_free")) |a| r = .{ .a = a };
            }
            if (r == null and acc_ok) {
                if (al.take("acc_free")) |a| r = .{ .acc = @intCast(a) };
            }
            next_file_a = !next_file_a;
        }
        reg[j] = r orelse return error.OutOfRegisters;
        active[j] = true;
    }

    // 4. Code generation.
    var g: Gen = .{ .stage = shader.stage, .out = .{ .stage = shader.stage, .threaded = threaded } };
    for (0..n) |j| {
        if (!live[j]) continue;
        switch (shader.insts[j].op) {
            .vpm_read => g.out.num_vpm_reads += 1,
            .vpm_write => g.out.num_vpm_writes += 1,
            else => {},
        }
    }
    if (g.out.num_vpm_writes > 0)
        try g.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = vpmSetup(0, 0) }));
    var vpm_reads_left = g.out.num_vpm_reads;
    var tex: TexRequests = .{};
    var vpm_fifo: u32 = 0;
    var vpm_addr: u32 = 0;

    for (0..n) |j| {
        if (!live[j]) continue;
        const inst = shader.insts[j];
        const dst = reg[j];
        switch (inst.op) {
            .frag_z, .frag_w => {},
            .uniform => if (dst != .unif) {
                try g.emit(try qpu.mov(dst.dst(), qpu.unif));
                try g.addUniform(.{ .user = inst.imm });
            },
            .constant => switch (dst) {
                .acc, .a, .b => try g.emit(try qpu.loadImm(.{ .add_dst = dst.dst(), .value = inst.imm })),
                else => {},
            },
            .vpm_read => {
                if (vpm_fifo == 0) {
                    vpm_fifo = @min(vpm_reads_left, 16);
                    try g.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = vpmSetup(@truncate(vpm_fifo), vpm_addr) }));
                    vpm_addr += vpm_fifo;
                    vpm_reads_left -= vpm_fifo;
                }
                vpm_fifo -= 1;
                try g.emit(try qpu.mov(dst.dst(), qpu.vpm_read));
            },
            .varying => {
                // The varying port returns the partially interpolated value
                // and loads the constant term into r5.
                try g.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.vary, .b = qpu.frag_w } }));
                try g.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = dst.dst(), .a = qpu.r(3), .b = qpu.r(5) } }));
                g.out.num_varyings += 1;
            },
            .fadd, .fsub, .fmin, .fmax, .fmaxabs, .ftoi, .itof, .add, .sub, .shl, .shr, .asr, .@"and", .@"or", .xor, .min, .max, .fmul => {
                const srcs = shader.operands(j);
                var a = try g.operand(shader, reg, srcs[0]);
                var b = if (srcs.len > 1) try g.operand(shader, reg, srcs[1]) else a;
                try g.resolveConflict(&a, &b);
                const ai = if (inst.op == .fmul)
                    qpu.Alu{ .mul = .{ .op = .fmul, .dst = dst.dst(), .a = a.src(), .b = b.src() } }
                else
                    qpu.Alu{ .add = .{ .op = inst.op.addOp().?, .dst = dst.dst(), .a = a.src(), .b = b.src() } };
                try g.emit(try qpu.alu(ai));
                for (srcs) |v| if (reg[@intFromEnum(v)] == .unif) {
                    try g.addUniform(.{ .user = shader.insts[@intFromEnum(v)].imm });
                };
            },
            .recip, .rsqrt, .exp2, .log2 => {
                const a = try g.operand(shader, reg, inst.srcs[0]);
                try g.emit(try qpu.mov(.{ .periph = inst.op.sfuWaddr().? }, a.src()));
                g.sfu_ip = g.out.code_len - 1;
                try g.emit(try qpu.mov(dst.dst(), qpu.r(4)));
            },
            .unpack_unorm8 => {
                const a = reg[@intFromEnum(inst.srcs[0])];
                const mode: qpu.UnpackMode = @enumFromInt(@as(u3, 4) + @as(u3, @intCast(inst.imm)));
                // A float move (fmax x, x) applies the float conversion.
                try g.emit(try qpu.alu(.{
                    .add = .{ .op = .fmax, .dst = dst.dst(), .a = a.src(), .b = a.src() },
                    .unpack = .{ .regfile_a = mode },
                }));
            },
            .pack_unorm8888 => {
                const modes = [4]qpu.PackMul{ .@"8a", .@"8b", .@"8c", .@"8d" };
                for (shader.operands(j), modes) |v, mode| {
                    var a = try g.operand(shader, reg, v);
                    var one: Reg = .{ .imm = encodeSmallImm(@bitCast(@as(f32, 1.0))).? };
                    try g.resolveConflict(&a, &one);
                    try g.emit(try qpu.alu(.{
                        .mul = .{ .op = .fmul, .dst = dst.dst(), .a = a.src(), .b = one.src() },
                        .pack = .{ .mul = mode },
                    }));
                }
            },
            .pack_screen_xy => {
                const modes = [2]qpu.PackA{ .@"16a", .@"16b" };
                for (shader.operands(j), modes) |v, mode| {
                    const a = try g.operand(shader, reg, v);
                    try g.emit(try qpu.alu(.{
                        .add = .{ .op = .ftoi, .dst = dst.dst(), .a = a.src(), .b = a.src() },
                        .pack = .{ .regfile_a = mode },
                    }));
                }
            },
            .tex => {
                // Fetches overlap: with this one, request the later ones
                // whose coordinates are already worked out, so the texture
                // units fetch them all while this one is waited for. Each
                // unit returns its results in the order they were asked
                // for, so once one of a unit's cannot be asked for yet,
                // none after it is; and each unit holds only so many.
                if (!tex.requested[j]) try tex.request(&g, shader, reg, j);
                var blocked: [2]bool = .{ false, false };
                for (j + 1..n) |k| {
                    const later = shader.insts[k];
                    if (!live[k] or later.op != .tex or tex.requested[k]) continue;
                    const u = later.imm & 1;
                    if (blocked[u]) continue;
                    var ready = tex.outstanding[u] < tex_fifo_depth(threaded);
                    for (later.srcs[0..2]) |v| {
                        if (@intFromEnum(v) >= j or reg[@intFromEnum(v)] == .unif) ready = false;
                    }
                    if (ready) try tex.request(&g, shader, reg, k) else blocked[u] = true;
                }
                // Threaded: let the other thread run while the texture
                // unit fetches (placed by `placeThreadSwitches`); fetches
                // asked for before the switch are waited for with this
                // one, and need no switch of their own.
                const unit = inst.imm & 1;
                if (threaded and !tex.covered[j]) {
                    try g.push(qpu.nop(.thread_switch));
                    g.last_switch = g.out.code_len - 1;
                    for (0..n) |k| if (tex.requested[k]) {
                        tex.covered[k] = true;
                    };
                }
                try g.emit(qpu.nop(if (unit == 0) .load_tmu0 else .load_tmu1));
                try g.emit(try qpu.mov(dst.dst(), qpu.r(4)));
                tex.outstanding[unit] -= 1;
            },
            .tlb_color_load => {
                // Reading the tile buffer needs the scoreboard (writes wait
                // for it implicitly; reads do not).
                if (!g.scoreboard_waited) {
                    try g.emit(qpu.nop(.wait_scoreboard));
                    g.scoreboard_waited = true;
                }
                try g.emit(qpu.nop(.color_load));
                try g.emit(try qpu.mov(dst.dst(), qpu.r(4)));
            },
            .vpm_write, .tlb_z, .tlb_color, .tlb_color_ms => {
                const periph: u6 = switch (inst.op) {
                    .vpm_write => qpu.W.vpm,
                    .tlb_z => qpu.W.tlb_z,
                    .tlb_color_ms => qpu.W.tlb_color_ms,
                    else => qpu.W.tlb_color_all,
                };
                const a = try g.operand(shader, reg, inst.srcs[0]);
                try g.emit(try qpu.mov(.{ .periph = periph }, a.src()));
                if (a == .unif) try g.addUniform(.{ .user = shader.insts[@intFromEnum(inst.srcs[0])].imm });
            },
        }
    }

    // The last switch says it is the last: the QPU then runs this thread
    // to its end before the other takes the scoreboard.
    if (g.last_switch) |ip| g.out.code_buf[ip] = qpu.nop(.last_thread_switch);
    try placeThreadSwitches(&g.out, shader.stage, options.schedule);

    // Thread end and its two delay slots; fragment shaders release the tile
    // buffer scoreboard in the last one.
    if (g.out.code_len + 3 > max_code) return error.ProgramTooLong;
    g.out.code_buf[g.out.code_len..][0..3].* = .{ qpu.nop(.prog_end), qpu.nop(.none), qpu.nop(if (shader.stage == .fragment) .scoreboard_unlock else .none) };
    g.out.code_len += 3;
    try qpu.validate(g.out.code(), shader.stage, null);
    return g.out;
}

/// VPM setup word for horizontal, 32-bit, stride 1 accesses.
fn vpmSetup(count: u4, addr: u32) u32 {
    return @as(u32, count) << 20 | 1 << 12 | 1 << 11 | 2 << 8 | (addr & 0xff);
}

/// How many fetches a texture unit holds for a QPU: 4, or 2 for each of a
/// threaded shader's two threads.
fn tex_fifo_depth(threaded: bool) u8 {
    return if (threaded) 2 else 4;
}

/// The texture fetches asked for ahead of when their results are read.
const TexRequests = struct {
    requested: [max_insts]bool = @splat(false),
    /// Asked for before a thread switch, so already waited for.
    covered: [max_insts]bool = @splat(false),
    /// Asked for and not yet read, on each unit.
    outstanding: [2]u8 = .{ 0, 0 },

    /// Asks for fetch `j`: writing T then S each take one config uniform
    /// (P0, P1); the S write starts the fetch.
    fn request(t: *TexRequests, g: *Gen, shader: *const Shader, reg: [max_insts]Reg, j: usize) Error!void {
        const inst = shader.insts[j];
        const slot: u8 = @intCast(inst.imm);
        const unit = slot & 1;
        const s_reg = try g.operand(shader, reg, inst.srcs[0]);
        const t_reg = try g.operand(shader, reg, inst.srcs[1]);
        try g.emit(try qpu.mov(.{ .periph = if (unit == 0) qpu.W.tmu0_t else qpu.W.tmu1_t }, t_reg.src()));
        try g.addUniform(.{ .tex_p0 = slot });
        try g.emit(try qpu.mov(.{ .periph = if (unit == 0) qpu.W.tmu0_s else qpu.W.tmu1_s }, s_reg.src()));
        try g.addUniform(.{ .tex_p1 = slot });
        t.requested[j] = true;
        t.outstanding[unit] += 1;
        g.out.num_texture_samples += 1;
    }
};

const Gen = struct {
    stage: Stage,
    out: Compiled = .{ .stage = .vertex },
    /// Index of the last SFU write, whose result appears in r4 two
    /// instructions later.
    sfu_ip: ?usize = null,
    /// A fragment shader has waited for the tile buffer scoreboard.
    scoreboard_waited: bool = false,
    /// Where the last thread switch marker is (threaded shaders).
    last_switch: ?usize = null,

    fn addUniform(g: *Gen, k: UniformKind) Error!void {
        if (g.out.uniform_len == max_uniforms) return error.TooManyUniforms;
        g.out.uniform_buf[g.out.uniform_len] = k;
        g.out.uniform_len += 1;
    }

    /// The register (or port, or immediate) to read value `v` from.
    fn operand(g: *Gen, shader: *const Shader, reg: [max_insts]Reg, v: Value) Error!Reg {
        _ = g;
        const d = @intFromEnum(v);
        const r = reg[d];
        if (r == .none and shader.insts[d].op == .constant) {
            if (encodeSmallImm(shader.insts[d].imm)) |imm| return .{ .imm = imm };
        }
        std.debug.assert(r != .none);
        return r;
    }

    /// Two operands that need different addresses on the same register
    /// file cannot be read by one instruction: move one of them to r3.
    /// A register operand is moved in preference to a small immediate or a
    /// uniform, which would cost an extra instruction or be read early.
    fn resolveConflict(g: *Gen, a: *Reg, b: *Reg) Error!void {
        const fa = a.file() orelse return;
        const fb = b.file() orelse return;
        if (fa != fb or std.meta.eql(a.*, b.*)) return;
        const victim = if (b.* == .imm or b.* == .unif) a else b;
        try g.emit(try qpu.mov(qpu.wr(3), victim.src()));
        victim.* = .{ .acc = 3 };
    }

    /// Appends an instruction, first inserting NOPs for read-after-write
    /// hazards on the physical register files and for SFU results that are
    /// not ready yet.
    fn emit(g: *Gen, inst: qpu.Inst) Error!void {
        const o = &g.out;
        if (o.code_len > 0) {
            const prev = o.code_buf[o.code_len - 1];
            const ws = qpu.getWs(prev);
            const wa = if (ws) qpu.getWaddrMul(prev) else qpu.getWaddrAdd(prev);
            const wb = if (ws) qpu.getWaddrAdd(prev) else qpu.getWaddrMul(prev);
            if ((wa < 32 and qpu.readsFile(inst, .a, wa)) or (wb < 32 and qpu.readsFile(inst, .b, wb)))
                try g.push(qpu.nop(.none));
        }
        if (g.sfu_ip) |sfu| {
            // r4 must not be read, and nothing else may write it, in the
            // two instructions after an SFU write.
            const touches_r4 = qpu.readsAccumulator(inst, 4) or qpu.getSig(inst) == .load_tmu0 or
                qpu.getSig(inst) == .load_tmu1 or qpu.getSig(inst) == .color_load or sfuWrite(inst);
            if (touches_r4) {
                while (o.code_len < sfu + 3) try g.push(qpu.nop(.none));
                g.sfu_ip = null;
            }
        }
        // A fragment shader must not touch the tile buffer in its first two
        // instructions.
        if (g.stage == .fragment and isTlb(inst)) {
            while (o.code_len < 2) try g.push(qpu.nop(.none));
        }
        try g.push(inst);
    }

    fn push(g: *Gen, inst: qpu.Inst) Error!void {
        const o = &g.out;
        if (o.code_len + 3 >= max_code) return error.ProgramTooLong;
        o.code_buf[o.code_len] = inst;
        o.code_len += 1;
    }
};

/// Schedules the code between thread switches separately (nothing moves
/// across a switch: accumulators and flags do not survive it), and fits
/// each switch's signal into one of the last three instructions before it,
/// so that it takes effect, after its two delay slots, just where the code
/// after it starts.
fn placeThreadSwitches(out: *Compiled, stage: Stage, schedule: bool) Error!void {
    var body: [max_code]qpu.Inst = undefined;
    const code = out.code();
    @memcpy(body[0..code.len], code);
    const src = body[0..code.len];
    out.code_len = 0;
    var start: usize = 0;
    var first = true;
    var ip: usize = 0;
    while (ip <= src.len) : (ip += 1) {
        const at_end = ip == src.len;
        const sig: ?qpu.Sig = if (at_end) null else qpu.getSig(src[ip]);
        if (!at_end and sig != .thread_switch and sig != .last_thread_switch) continue;
        const segment_start = out.code_len;
        const piece = src[start..ip];
        if (schedule and piece.len > 0) {
            const sched = try qpu_schedule.scheduleSegment(piece, stage, first);
            try appendSegment(out, sched.slice());
        } else try appendSegment(out, piece);
        first = false;
        start = ip + 1;
        if (at_end) break;
        // The signal: in the latest of the segment's last three
        // instructions that has no signal of its own, or a NOP; then NOPs
        // until it takes effect.
        var at: ?usize = null;
        var k = out.code_len;
        while (k > segment_start and k + 3 > out.code_len) {
            k -= 1;
            if (qpu.getSig(out.code_buf[k]) == .none) at = k;
        }
        const sig_ip = at orelse blk: {
            if (out.code_len == max_code) return error.ProgramTooLong;
            out.code_buf[out.code_len] = qpu.nop(.none);
            out.code_len += 1;
            break :blk out.code_len - 1;
        };
        out.code_buf[sig_ip] = setSig(out.code_buf[sig_ip], sig.?);
        while (out.code_len < sig_ip + 3) {
            if (out.code_len == max_code) return error.ProgramTooLong;
            out.code_buf[out.code_len] = qpu.nop(.none);
            out.code_len += 1;
        }
    }
    if (out.code_len + 3 > max_code) return error.ProgramTooLong;
}

/// Appends code, with a NOP first if it would read a register the previous
/// instruction wrote.
fn appendSegment(out: *Compiled, code: []const qpu.Inst) Error!void {
    if (code.len == 0) return;
    if (out.code_len > 0 and hazard(out.code_buf[out.code_len - 1], code[0])) {
        if (out.code_len == max_code) return error.ProgramTooLong;
        out.code_buf[out.code_len] = qpu.nop(.none);
        out.code_len += 1;
    }
    if (out.code_len + code.len > max_code) return error.ProgramTooLong;
    @memcpy(out.code_buf[out.code_len..][0..code.len], code);
    out.code_len += code.len;
}

fn hazard(prev: qpu.Inst, cur: qpu.Inst) bool {
    var pair = [_]qpu.Inst{ prev, cur, qpu.nop(.prog_end), qpu.nop(.none), qpu.nop(.none) };
    qpu.validate(&pair, .vertex, null) catch |e| return e == error.ReadAfterWriteHazard;
    return false;
}

fn setSig(inst: qpu.Inst, sig: qpu.Sig) qpu.Inst {
    return (inst & ~(@as(qpu.Inst, 0xf) << 60)) | (@as(qpu.Inst, @intFromEnum(sig)) << 60);
}

fn sfuWrite(inst: qpu.Inst) bool {
    inline for (.{ qpu.W.sfu_recip, qpu.W.sfu_recipsqrt, qpu.W.sfu_exp, qpu.W.sfu_log }) |w|
        if (qpu.writesAddr(inst, w)) return true;
    return false;
}

fn isTlb(inst: qpu.Inst) bool {
    const sig = qpu.getSig(inst);
    if (sig == .wait_scoreboard or sig == .color_load) return true;
    return qpu.writesAddr(inst, qpu.W.tlb_z) or qpu.writesAddr(inst, qpu.W.tlb_color_all) or
        qpu.writesAddr(inst, qpu.W.tlb_color_ms) or qpu.writesAddr(inst, qpu.W.tlb_stencil_setup);
}

/// Whether an instruction starts a texture fetch (writes a unit's S).
fn writesTmuS(i: qpu.Inst) bool {
    for ([_]u6{ qpu.getWaddrAdd(i), qpu.getWaddrMul(i) }) |w| {
        if (w == qpu.W.tmu0_s or w == qpu.W.tmu1_s) return true;
    }
    return false;
}

fn countSig(code: []const qpu.Inst, sig: qpu.Sig) usize {
    var n: usize = 0;
    for (code) |i| n += @intFromBool(qpu.getSig(i) == sig);
    return n;
}

/// Whether any instruction reads or writes the upper half of a register
/// file (which a threaded shader's other thread owns).
fn usesUpperHalf(code: []const qpu.Inst) bool {
    for (code) |i| {
        const sig = qpu.getSig(i);
        if (sig == .load_imm or sig == .branch) {
            if (qpu.getWaddrAdd(i) >= 16 and qpu.getWaddrAdd(i) < 32) return true;
            if (qpu.getWaddrMul(i) >= 16 and qpu.getWaddrMul(i) < 32) return true;
            continue;
        }
        for ([_]u6{ qpu.getWaddrAdd(i), qpu.getWaddrMul(i) }) |w| if (w >= 16 and w < 32) return true;
        const raddr_a: u6 = @truncate(i >> 18);
        const raddr_b: u6 = @truncate(i >> 12);
        if (raddr_a >= 16 and raddr_a < 32) return true;
        if (sig != .small_imm and raddr_b >= 16 and raddr_b < 32) return true;
    }
    return false;
}

/// A fragment shader that samples a texture at its varyings, with `extra`
/// more varyings added to the result (live across the sample).
fn texturedShader(extra: usize) Shader {
    var s = Shader.init(.fragment);
    const u = s.varying();
    const v = s.varying();
    var keep: [40]Value = undefined;
    for (keep[0..extra]) |*k| k.* = s.varying();
    var t = s.texture(0, u, v);
    for (keep[0..extra]) |k| t = s.fadd(t, k);
    s.tlbColor(t);
    return s;
}

test "fragment shaders that sample textures run threaded" {
    const sim = @import("qpu_sim.zig");
    const texture = @import("texture.zig");
    var s = texturedShader(3);
    const c = try compile(&s);
    try std.testing.expect(c.threaded);
    // One switch, the last, and none of the other thread's registers.
    try std.testing.expectEqual(@as(usize, 1), countSig(c.code(), .last_thread_switch));
    try std.testing.expectEqual(@as(usize, 0), countSig(c.code(), .thread_switch));
    try std.testing.expect(!usesUpperHalf(c.code()));
    // Values kept across the switch survive it (the simulator trashes the
    // accumulators there): the same as one thread.
    const single = try compileWithOptions(&s, .{ .threaded = false });
    try std.testing.expect(!single.threaded);
    var pixels: [16 * 16]u32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @truncate(i *% 2654435761);
    var memory: [texture.imageSize(16, 16)]u8 = undefined;
    texture.upload(&memory, &pixels, 16, 16);
    const cfg: texture.Config = .{ .width = 16, .height = 16, .mag_filter = .nearest, .min_filter = .nearest };
    const unif = [_]u32{ texture.p0(cfg), texture.p1(cfg) };
    var vary: [5]sim.Vec = undefined;
    for (&vary, 0..) |*v, k| {
        for (v, 0..) |*e, lane| e.* = @bitCast((@as(f32, @floatFromInt(lane)) + 0.5) / 16 + @as(f32, @floatFromInt(k)) * 0.01);
    }
    const a = try sim.run(c.code(), .{ .uniforms = &unif, .varyings = &vary, .texture_memory = &memory });
    const b = try sim.run(single.code(), .{ .uniforms = &unif, .varyings = &vary, .texture_memory = &memory });
    try std.testing.expectEqual(b.tlb_color.?, a.tlb_color.?);
}

test "shaders without textures, or needing more registers, run one thread" {
    var plain = Shader.init(.fragment);
    plain.tlbColor(plain.varying());
    try std.testing.expect(!(try compile(&plain)).threaded);
    try std.testing.expectError(error.CannotThread, compileWithOptions(&plain, .{ .threaded = true }));
    // 36 values across the switch: more than half the registers hold.
    var big = texturedShader(36);
    const c = try compile(&big);
    try std.testing.expect(!c.threaded);
    try std.testing.expectEqual(@as(usize, 0), countSig(c.code(), .last_thread_switch));
}

test "texture samples are asked for together, and waited for with one thread switch" {
    var s = Shader.init(.fragment);
    const u = s.varying();
    const v = s.varying();
    const t0 = s.texture(0, u, v);
    const t1 = s.texture(1, v, u);
    const t2 = s.texture(2, u, u);
    s.tlbColor(s.fadd(s.fadd(t0, t1), t2));
    const c = try compile(&s);
    try std.testing.expect(c.threaded);
    try std.testing.expectEqual(@as(usize, 0), countSig(c.code(), .thread_switch));
    try std.testing.expectEqual(@as(usize, 1), countSig(c.code(), .last_thread_switch));
    // All three are asked for before the first result is read.
    var first_load: ?usize = null;
    var last_request: usize = 0;
    for (c.code(), 0..) |i, ip| {
        const sig = qpu.getSig(i);
        if (first_load == null and (sig == .load_tmu0 or sig == .load_tmu1)) first_load = ip;
        if (writesTmuS(i)) last_request = ip;
    }
    try std.testing.expect(last_request < first_load.?);
    // In order, their config uniforms: slot 0's, 1's, then 2's.
    const want = [_]UniformKind{ .{ .tex_p0 = 0 }, .{ .tex_p1 = 0 }, .{ .tex_p0 = 1 }, .{ .tex_p1 = 1 }, .{ .tex_p0 = 2 }, .{ .tex_p1 = 2 } };
    try std.testing.expectEqualSlices(UniformKind, &want, c.uniforms());
}

test "a texture unit's fetches stay within what it holds for a thread" {
    var s = Shader.init(.fragment);
    const u = s.varying();
    var sum = s.texture(0, u, u);
    for (0..3) |_| sum = s.fadd(sum, s.texture(0, u, u));
    s.tlbColor(sum);
    const c = try compile(&s);
    try std.testing.expect(c.threaded);
    var outstanding: i32 = 0;
    for (c.code()) |i| {
        if (writesTmuS(i)) outstanding += 1;
        if (qpu.getSig(i) == .load_tmu0) outstanding -= 1;
        try std.testing.expect(outstanding <= tex_fifo_depth(true));
    }
}

test "a sample whose place comes from another's waits for it, switching threads again" {
    var s = Shader.init(.fragment);
    const u = s.varying();
    const v = s.varying();
    const t0 = s.texture(0, u, v);
    const t1 = s.texture(0, t0, u);
    s.tlbColor(t1);
    const c = try compile(&s);
    try std.testing.expect(c.threaded);
    try std.testing.expectEqual(@as(usize, 1), countSig(c.code(), .thread_switch));
    try std.testing.expectEqual(@as(usize, 1), countSig(c.code(), .last_thread_switch));
    // At least three instructions apart (the kernel's rule).
    var last: ?usize = null;
    for (c.code(), 0..) |i, ip| {
        const sig = qpu.getSig(i);
        if (sig != .thread_switch and sig != .last_thread_switch) continue;
        if (last) |l| try std.testing.expect(ip >= l + 3);
        last = ip;
    }
}

// --- VideoCore VI (V3D 4.2) Compiler -----------------------------------------

pub fn compileV3d(shader: *const Shader) Error!Compiled {
    const n = shader.len;

    // On V3D 4.2, coordinate shaders only write pos[0..3] (VPM 0..3) and
    // Xs, Ys (VPM 4..5), not Zs or 1/Wc. Ignore the Zs and 1/Wc vpm_writes
    // in coordinate shaders before computing liveness.
    var skip_inst: [max_insts]bool = @splat(false);
    var cs_xy_inst: ?usize = null;
    var vs_xy_inst: ?usize = null;
    {
        var vpm_w_idx: u32 = 0;
        for (0..n) |j| {
            if (shader.insts[j].op == .vpm_write) {
                if (shader.stage == .coordinate) {
                    if (vpm_w_idx == 4) cs_xy_inst = @intFromEnum(shader.insts[j].srcs[0]);
                    if (vpm_w_idx >= 5) skip_inst[j] = true;
                } else if (shader.stage == .vertex) {
                    if (vpm_w_idx == 0) vs_xy_inst = @intFromEnum(shader.insts[j].srcs[0]);
                }
                vpm_w_idx += 1;
            }
        }
    }

    var live: [max_insts]bool = @splat(false);
    var uses: [max_insts]u16 = @splat(0);
    var first_use: [max_insts]u16 = @splat(std.math.maxInt(u16));
    var last_use: [max_insts]u16 = @splat(0);
    {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            if (skip_inst[i]) continue;
            if (shader.insts[i].op.hasSideEffects()) live[i] = true;
            if (!live[i]) continue;
            // `pack_unorm8888` and `pack_screen_xy` emit no code at `i`; their
            // operands are read at the consumer instruction (`tlb_color`,
            // `tlb_color_ms`, `vpm_write`).
            const inst = shader.insts[i];
            if (inst.op == .tlb_color or inst.op == .tlb_color_ms or inst.op == .vpm_write) {
                const src_idx = @intFromEnum(inst.srcs[0]);
                const src_inst = shader.insts[src_idx];
                if (src_inst.op == .pack_unorm8888 or src_inst.op == .pack_screen_xy) {
                    live[src_idx] = true;
                    for (shader.operands(src_idx)) |v| {
                        const d = @intFromEnum(v);
                        live[d] = true;
                        uses[d] += 1;
                        first_use[d] = @min(first_use[d], @as(u16, @intCast(i)));
                        last_use[d] = @max(last_use[d], @as(u16, @intCast(i)));
                    }
                    continue;
                }
            }
            if (inst.op == .pack_unorm8888 or inst.op == .pack_screen_xy) continue;
            for (shader.operands(i)) |v| {
                const d = @intFromEnum(v);
                live[d] = true;
                uses[d] += 1;
                first_use[d] = @min(first_use[d], @as(u16, @intCast(i)));
                last_use[d] = @max(last_use[d], @as(u16, @intCast(i)));
            }
        }
    }

    // Track per-channel liveness for `.tex` and `.tlb_color_load` results,
    // which are unpacked via `.unpack_unorm8`.
    var tex_ch_used: [max_insts][4]bool = @splat(.{ false, false, false, false });
    var tex_ch_last_use: [max_insts][4]u16 = @splat(.{ 0, 0, 0, 0 });
    var tex_ch_active: [max_insts][4]bool = @splat(.{ false, false, false, false });
    for (0..n) |j| {
        if (!live[j] or skip_inst[j]) continue;
        const inst = shader.insts[j];
        if (inst.op == .unpack_unorm8) {
            const src_idx = @intFromEnum(inst.srcs[0]);
            const src_op = shader.insts[src_idx].op;
            if (src_op == .tex or src_op == .tlb_color_load) {
                const byte: u2 = @intCast(inst.imm);
                tex_ch_used[src_idx][byte] = true;
                tex_ch_last_use[src_idx][byte] = @max(tex_ch_last_use[src_idx][byte], last_use[j]);
            }
        }
    }

    // Allocate unified RF registers (rf3..rf63; rf0=frag_w, rf2=frag_z, rf1=scratch).
    var rf_free: [64]bool = @splat(true);
    rf_free[0] = false;
    rf_free[1] = false;
    rf_free[2] = false;

    const takeRf = struct {
        fn f(free: *[64]bool) Error!u6 {
            for (free, 0..) |*slot, idx| if (slot.*) {
                slot.* = false;
                return @intCast(idx);
            };
            return error.OutOfRegisters;
        }
    }.f;

    const isDeferredUnifOrConst = struct {
        fn f(s: *const Shader, d: usize) bool {
            const op = s.insts[d].op;
            if (op == .uniform) return true;
            if (op == .constant) return v3d_qpu.encodeSmallImm(s.insts[d].imm) == null;
            return false;
        }
    }.f;

    // If a live ALU instruction `j` has a single use (`uses[j] == 1`) at the
    // immediately following live instruction `next_live`, and `next_live` is
    // also an ALU instruction, keep `j`'s result in accumulator `r2` instead
    // of allocating an RF register or emitting an RF-to-accumulator move.
    var use_r2: [max_insts]bool = @splat(false);
    {
        var prev_live: ?usize = null;
        for (0..n) |j| {
            if (!live[j] or skip_inst[j]) continue;
            const op = shader.insts[j].op;
            if (op == .uniform or op == .constant or op == .pack_unorm8888 or op == .pack_screen_xy or op == .unpack_unorm8) continue;
            if (prev_live) |p| {
                if (shader.insts[p].op.isAlu() and uses[p] == 1 and last_use[p] == j and op.isAlu()) {
                    use_r2[p] = true;
                }
            }
            prev_live = j;
        }
    }

    var rf_reg: [max_insts]u6 = @splat(0);
    var has_rf: [max_insts]bool = @splat(false);
    var active_rf: [max_insts]bool = @splat(false);
    var tex_ch_rf: [max_insts][4]u6 = @splat(.{ 0, 0, 0, 0 });
    var has_tex_ch: [max_insts]bool = @splat(false);

    for (0..n) |j| {
        for (0..n) |d| {
            if (active_rf[d] and last_use[d] < j) {
                if (has_rf[d] and rf_reg[d] >= 3) {
                    rf_free[rf_reg[d]] = true;
                }
                active_rf[d] = false;
            }
            if (has_tex_ch[d]) {
                for (0..4) |ch| {
                    if (tex_ch_active[d][ch] and tex_ch_last_use[d][ch] < j) {
                        rf_free[tex_ch_rf[d][ch]] = true;
                        tex_ch_active[d][ch] = false;
                    }
                }
            }
        }
        if (!live[j] or skip_inst[j]) continue;

        // Materialize any `.uniform` or non-small-imm `.constant` whose first
        // use is at instruction `j`.
        for (0..j) |d| {
            if (live[d] and !skip_inst[d] and isDeferredUnifOrConst(shader, d) and first_use[d] == j) {
                rf_reg[d] = try takeRf(&rf_free);
                has_rf[d] = true;
                active_rf[d] = true;
            }
        }

        if (!shader.insts[j].op.hasResult()) continue;
        const inst = shader.insts[j];
        switch (inst.op) {
            .frag_w => {
                rf_reg[j] = 0;
                has_rf[j] = true;
            },
            .frag_z => {
                rf_reg[j] = 2;
                has_rf[j] = true;
            },
            .uniform, .constant, .pack_unorm8888, .pack_screen_xy => {},
            .tex, .tlb_color_load => {
                for (0..4) |ch| {
                    if (tex_ch_used[j][ch]) {
                        tex_ch_rf[j][ch] = try takeRf(&rf_free);
                        tex_ch_active[j][ch] = true;
                    } else {
                        tex_ch_rf[j][ch] = 1; // scratch rf1 for unused channel
                    }
                }
                has_tex_ch[j] = true;
            },
            .unpack_unorm8 => {
                const src_idx = @intFromEnum(inst.srcs[0]);
                const byte: u2 = @intCast(inst.imm);
                if (has_tex_ch[src_idx]) {
                    rf_reg[j] = tex_ch_rf[src_idx][byte];
                    has_rf[j] = true;
                } else {
                    rf_reg[j] = try takeRf(&rf_free);
                    has_rf[j] = true;
                    active_rf[j] = true;
                }
            },
            else => {
                if (uses[j] > 0 and !use_r2[j]) {
                    rf_reg[j] = try takeRf(&rf_free);
                    has_rf[j] = true;
                    active_rf[j] = true;
                }
            },
        }
    }

    var out: Compiled = .{
        .stage = shader.stage,
        .threaded = true,
    };
    var last_rf_write: ?u6 = null;

    const pushRaw = struct {
        fn f(o: *Compiled, last_w: *?u6, inst: v3d_qpu.Inst, written_rf: ?u6) Error!void {
            if (o.code_len >= max_code) return error.ProgramTooLong;
            o.code_buf[o.code_len] = inst;
            o.code_len += 1;
            last_w.* = written_rf;
        }
    }.f;

    const pushAlu = struct {
        fn f(o: *Compiled, last_w: *?u6, a: v3d_qpu.Alu) Error!void {
            const reads_a = (a.add.op != .nop and (a.add.a.mux == .a or (a.add.op.numSrc() > 1 and a.add.b.mux == .a))) or
                (a.mul.op != .nop and (a.mul.a.mux == .a or (a.mul.op.numSrc() > 1 and a.mul.b.mux == .a)));
            if (reads_a and last_w.* != null and last_w.*.? == a.raddr_a) {
                try pushRaw(o, last_w, v3d_qpu.nop(), null);
            }
            var written: ?u6 = null;
            if (!a.add.dst.magic) written = a.add.dst.waddr;
            if (!a.mul.dst.magic) written = a.mul.dst.waddr;
            if (a.sig.ldunifrf or a.sig.ldtmu) {
                if (!a.sig_magic) written = a.sig_addr;
            }
            try pushRaw(o, last_w, try v3d_qpu.alu(a), written);
        }
    }.f;

    const push = struct {
        fn f(o: *Compiled, last_w: *?u6, inst: v3d_qpu.Inst) Error!void {
            // Check if this pre-packed instruction writes to an RF register via sig_addr
            const sig: u5 = @truncate(inst >> 53);
            var written: ?u6 = null;
            if (sig == 12 or sig == 4) { // ldunifrf or ldtmu
                const cond: u7 = @truncate(inst >> 46);
                if (cond & (1 << 6) == 0) written = @truncate(cond);
            }
            try pushRaw(o, last_w, inst, written);
        }
    }.f;

    const addUnif = struct {
        fn f(o: *Compiled, k: UniformKind) Error!void {
            if (o.uniform_len >= max_uniforms) return error.TooManyUniforms;
            o.uniform_buf[o.uniform_len] = k;
            o.uniform_len += 1;
        }
    }.f;

    // Helper: load SSA value `v` into accumulator `acc` (0 or 1).
    const loadToAcc = struct {
        fn f(o: *Compiled, last_w: *?u6, s: *const Shader, r_reg: *const [max_insts]u6, r2_map: *const [max_insts]bool, v: Value, acc: u3) Error!v3d_qpu.Mux {
            const d = @intFromEnum(v);
            if (r2_map[d]) return .r2;
            const def = s.insts[d];
            if (def.op == .constant) {
                if (v3d_qpu.encodeSmallImm(def.imm)) |imm| {
                    try pushAlu(o, last_w, .{
                        .sig = .{ .small_imm_b = true },
                        .raddr_b = imm,
                        .mul = .{
                            .op = .mov,
                            .dst = .r(acc),
                            .a = .{ .mux = .b },
                        },
                    });
                    return @enumFromInt(acc);
                }
            }
            const rf = r_reg[d];
            try pushAlu(o, last_w, .{
                .raddr_a = rf,
                .mul = .{
                    .op = .mov,
                    .dst = .r(acc),
                    .a = .{ .mux = .a },
                },
            });
            return @enumFromInt(acc);
        }
    }.f;

    // Prepare single operand for an ALU instruction: returns (raddr_a, sig, raddr_b, mux).
    const prepUnary = struct {
        fn f(s: *const Shader, r_reg: *const [max_insts]u6, r2_map: *const [max_insts]bool, v: Value) struct { raddr_a: u6, sig: v3d_qpu.Sig, raddr_b: u6, mux: v3d_qpu.Mux } {
            const d = @intFromEnum(v);
            if (r2_map[d]) {
                return .{ .raddr_a = 0, .sig = .{}, .raddr_b = 0, .mux = .r2 };
            }
            const def = s.insts[d];
            if (def.op == .constant) {
                if (v3d_qpu.encodeSmallImm(def.imm)) |imm| {
                    return .{ .raddr_a = 0, .sig = .{ .small_imm_b = true }, .raddr_b = imm, .mux = .b };
                }
            }
            return .{ .raddr_a = r_reg[d], .sig = .{}, .raddr_b = 0, .mux = .a };
        }
    }.f;

    // Prepare two operands for a binary ALU instruction, emitting at most one `mov` to `r0` if needed.
    const prepBinary = struct {
        fn f(o: *Compiled, last_w: *?u6, s: *const Shader, r_reg: *const [max_insts]u6, r2_map: *const [max_insts]bool, v0: Value, v1: Value) Error!struct { raddr_a: u6, sig: v3d_qpu.Sig, raddr_b: u6, mux_a: v3d_qpu.Mux, mux_b: v3d_qpu.Mux } {
            const op0 = prepUnary(s, r_reg, r2_map, v0);
            if (v0 == v1) {
                return .{ .raddr_a = op0.raddr_a, .sig = op0.sig, .raddr_b = op0.raddr_b, .mux_a = op0.mux, .mux_b = op0.mux };
            }
            const op1 = prepUnary(s, r_reg, r2_map, v1);
            // If either operand is already in r2, there is no port conflict with the other operand!
            if (op0.mux == .r2) {
                return .{ .raddr_a = op1.raddr_a, .sig = op1.sig, .raddr_b = op1.raddr_b, .mux_a = .r2, .mux_b = op1.mux };
            }
            if (op1.mux == .r2) {
                return .{ .raddr_a = op0.raddr_a, .sig = op0.sig, .raddr_b = op0.raddr_b, .mux_a = op0.mux, .mux_b = .r2 };
            }
            if (op0.mux == .a and op1.mux == .b) {
                return .{ .raddr_a = op0.raddr_a, .sig = op1.sig, .raddr_b = op1.raddr_b, .mux_a = .a, .mux_b = .b };
            }
            if (op0.mux == .b and op1.mux == .a) {
                return .{ .raddr_a = op1.raddr_a, .sig = op0.sig, .raddr_b = op0.raddr_b, .mux_a = .b, .mux_b = .a };
            }
            if (op0.mux == .a and op1.mux == .a and op0.raddr_a == op1.raddr_a) {
                return .{ .raddr_a = op0.raddr_a, .sig = .{}, .raddr_b = 0, .mux_a = .a, .mux_b = .a };
            }
            if (op0.mux == .b and op1.mux == .b and op0.raddr_b == op1.raddr_b) {
                return .{ .raddr_a = 0, .sig = op0.sig, .raddr_b = op0.raddr_b, .mux_a = .b, .mux_b = .b };
            }
            // If op0 was just written to RF (`last_w`), load v1 into r0 first so op0's RF write delay slot is hidden!
            if (op0.mux == .a and last_w.* != null and op0.raddr_a == last_w.*.? and (op1.mux != .a or op1.raddr_a != last_w.*.?)) {
                const m1 = try loadToAcc(o, last_w, s, r_reg, r2_map, v1, 0);
                return .{ .raddr_a = op0.raddr_a, .sig = op0.sig, .raddr_b = op0.raddr_b, .mux_a = op0.mux, .mux_b = m1 };
            }
            const m0 = try loadToAcc(o, last_w, s, r_reg, r2_map, v0, 0);
            return .{ .raddr_a = op1.raddr_a, .sig = op1.sig, .raddr_b = op1.raddr_b, .mux_a = m0, .mux_b = op1.mux };
        }
    }.f;

    var vpm_read_idx: u32 = 0;
    var vpm_write_idx: u32 = 0;
    var tlb_locked = false;
    var tlb_load_sample: u32 = 0;
    var tlb_write_sample: u32 = 0;
    var r4_zeroed = false;
    var tex_requested: [max_insts]bool = @splat(false);
    var tex_covered: [max_insts]bool = @splat(false);
    var tex_outstanding: u8 = 0;
    const is_msaa_blend = blk: {
        for (0..n) |j| if (live[j] and shader.insts[j].op == .tlb_color_ms) break :blk true;
        break :blk false;
    };

    const requestTex42 = struct {
        fn f(
            o: *Compiled,
            last_w: *?u6,
            s: *const Shader,
            r_reg: *const [max_insts]u6,
            r2_map: *const [max_insts]bool,
            r4_zero: *bool,
            req: *[max_insts]bool,
            out_cnt: *u8,
            idx: usize,
        ) Error!void {
            const t_inst = s.insts[idx];
            const slot: u8 = @intCast(t_inst.imm);
            if (!r4_zero.*) {
                // r4 bit 0 of per-pixel mask must be 0 -> active.
                try pushAlu(o, last_w, .{
                    .sig = .{ .small_imm_b = true },
                    .raddr_b = 0,
                    .mul = .{
                        .op = .mov,
                        .dst = .r(4),
                        .a = .{ .mux = .b },
                    },
                });
                r4_zero.* = true;
            }
            // Emit wrtmuc for P0 first (also hides any RF write delay on u_t).
            try push(o, last_w, v3d_qpu.wrtmuc());
            try addUnif(o, .{ .tex_p0 = slot });
            const u_t = prepUnary(s, r_reg, r2_map, t_inst.srcs[1]);
            const fold_p1 = u_t.sig == (v3d_qpu.Sig{});
            try pushAlu(o, last_w, .{
                .sig = if (fold_p1) .{ .wrtmuc = true } else u_t.sig,
                .raddr_a = u_t.raddr_a,
                .raddr_b = u_t.raddr_b,
                .mul = .{
                    .op = .mov,
                    .dst = .magicAddr(v3d_qpu.W.tmut),
                    .a = .{ .mux = u_t.mux },
                },
            });
            if (!fold_p1) {
                try push(o, last_w, v3d_qpu.wrtmuc());
            }
            try addUnif(o, .{ .tex_p1 = slot });
            const u_s = prepUnary(s, r_reg, r2_map, t_inst.srcs[0]);
            try pushAlu(o, last_w, .{
                .sig = u_s.sig,
                .raddr_a = u_s.raddr_a,
                .raddr_b = u_s.raddr_b,
                .mul = .{
                    .op = .mov,
                    .dst = .magicAddr(v3d_qpu.W.tmus),
                    .a = .{ .mux = u_s.mux },
                },
            });
            req[idx] = true;
            out_cnt.* += 1;
            o.num_texture_samples += 1;
        }
    }.f;

    const ensureTlbLocked = struct {
        fn f(o: *Compiled, last_w: *?u6, locked: *bool) Error!void {
            if (locked.*) return;
            locked.* = true;
            // Enter final thread section (locks scoreboard on V3D 4.2):
            // two back-to-back THRSW signals followed by two delay slots.
            try push(o, last_w, v3d_qpu.thrsw());
            try push(o, last_w, v3d_qpu.thrsw());
            try push(o, last_w, v3d_qpu.nop());
            try push(o, last_w, v3d_qpu.nop());
        }
    }.f;

    for (0..n) |j| {
        if (!live[j] or skip_inst[j]) continue;

        // Emit deferred `.uniform` and non-small-imm `.constant` loads whose
        // first use is at instruction `j`.
        for (0..j) |d| {
            if (live[d] and !skip_inst[d] and isDeferredUnifOrConst(shader, d) and first_use[d] == j) {
                const def = shader.insts[d];
                try push(&out, &last_rf_write, v3d_qpu.ldunifrf(.rf(rf_reg[d])));
                if (def.op == .uniform) {
                    try addUnif(&out, .{ .user = def.imm });
                } else {
                    try addUnif(&out, .{ .constant = def.imm });
                }
            }
        }

        const inst = shader.insts[j];
        const dst_rf = rf_reg[j];
        const dst: v3d_qpu.Dst = if (use_r2[j]) .r(2) else if (has_rf[j]) .rf(dst_rf) else .nop;

        switch (inst.op) {
            .frag_w, .frag_z, .uniform, .constant, .pack_unorm8888, .pack_screen_xy, .unpack_unorm8 => {},
            .vpm_read => {
                const imm = v3d_qpu.encodeSmallImm(vpm_read_idx) orelse blk: {
                    try push(&out, &last_rf_write, v3d_qpu.ldunifrf(.rf(1)));
                    try addUnif(&out, .{ .constant = vpm_read_idx });
                    break :blk null;
                };
                if (imm) |enc| {
                    try pushAlu(&out, &last_rf_write, .{
                        .sig = .{ .small_imm_b = true },
                        .raddr_b = enc,
                        .add = .{
                            .op = .ldvpmv_in,
                            .dst = dst,
                            .a = .{ .mux = .b },
                        },
                    });
                } else {
                    try pushAlu(&out, &last_rf_write, .{
                        .raddr_a = 1,
                        .add = .{
                            .op = .ldvpmv_in,
                            .dst = dst,
                            .a = .{ .mux = .a },
                        },
                    });
                }
                vpm_read_idx += 1;
                out.num_vpm_reads += 1;
            },
            .varying => {
                // ldvary r3 writes (A*x + B*y) to r3 on the next cycle and C to r5
                // after 1 instruction delay. Multiply r3 by rf0 (payload W) in that
                // delay slot, then add r5!
                try push(&out, &last_rf_write, v3d_qpu.ldvary(.r(3)));
                try pushAlu(&out, &last_rf_write, .{
                    .raddr_a = 0, // rf0 = payload W
                    .mul = .{
                        .op = .fmul,
                        .dst = .r(3),
                        .a = .{ .mux = .r3 },
                        .b = .{ .mux = .a },
                    },
                });
                try pushAlu(&out, &last_rf_write, .{
                    .add = .{
                        .op = .fadd,
                        .dst = dst,
                        .a = .{ .mux = .r3 },
                        .b = .{ .mux = .r5 },
                    },
                });
                out.num_varyings += 1;
            },
            .fmaxabs => {
                const b_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, &use_r2, inst.srcs[0], inst.srcs[1]);
                try pushAlu(&out, &last_rf_write, .{
                    .sig = b_op.sig,
                    .raddr_a = b_op.raddr_a,
                    .raddr_b = b_op.raddr_b,
                    .add = .{
                        .op = .fmax,
                        .dst = dst,
                        .a = .{ .mux = b_op.mux_a, .unpack = .abs },
                        .b = .{ .mux = b_op.mux_b, .unpack = .abs },
                    },
                });
            },
            .ftoi, .itof => {
                const u_op = prepUnary(shader, &rf_reg, &use_r2, inst.srcs[0]);
                try pushAlu(&out, &last_rf_write, .{
                    .sig = u_op.sig,
                    .raddr_a = u_op.raddr_a,
                    .raddr_b = u_op.raddr_b,
                    .add = .{
                        .op = if (inst.op == .ftoi) .ftoiz else .itof,
                        .dst = dst,
                        .a = .{ .mux = u_op.mux },
                    },
                });
            },
            .fadd, .fsub, .fmin, .fmax, .add, .sub, .shl, .shr, .asr, .@"and", .@"or", .xor, .min, .max, .fmul => {
                const b_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, &use_r2, inst.srcs[0], inst.srcs[1]);
                if (inst.op == .fmul) {
                    try pushAlu(&out, &last_rf_write, .{
                        .sig = b_op.sig,
                        .raddr_a = b_op.raddr_a,
                        .raddr_b = b_op.raddr_b,
                        .mul = .{
                            .op = .fmul,
                            .dst = dst,
                            .a = .{ .mux = b_op.mux_a },
                            .b = .{ .mux = b_op.mux_b },
                        },
                    });
                } else {
                    const v3d_op: v3d_qpu.AddOp = switch (inst.op) {
                        .fadd => .fadd,
                        .fsub => .fsub,
                        .fmin => .fmin,
                        .fmax => .fmax,
                        .add => .add,
                        .sub => .sub,
                        .shl => .shl,
                        .shr => .shr,
                        .asr => .asr,
                        .@"and" => .@"and",
                        .@"or" => .@"or",
                        .xor => .xor,
                        .min => .min,
                        .max => .max,
                        else => unreachable,
                    };
                    try pushAlu(&out, &last_rf_write, .{
                        .sig = b_op.sig,
                        .raddr_a = b_op.raddr_a,
                        .raddr_b = b_op.raddr_b,
                        .add = .{
                            .op = v3d_op,
                            .dst = dst,
                            .a = .{ .mux = b_op.mux_a },
                            .b = .{ .mux = b_op.mux_b },
                        },
                    });
                }
            },
            .recip, .rsqrt, .exp2, .log2 => {
                // V3D 4.2 SFU ALU instructions write to dst after 2 delay slots.
                const u_op = prepUnary(shader, &rf_reg, &use_r2, inst.srcs[0]);
                const v3d_op: v3d_qpu.AddOp = switch (inst.op) {
                    .recip => .recip,
                    .rsqrt => .rsqrt,
                    .exp2 => .exp,
                    .log2 => .log,
                    else => unreachable,
                };
                try pushAlu(&out, &last_rf_write, .{
                    .sig = u_op.sig,
                    .raddr_a = u_op.raddr_a,
                    .raddr_b = u_op.raddr_b,
                    .add = .{
                        .op = v3d_op,
                        .dst = dst,
                        .a = .{ .mux = u_op.mux },
                    },
                });
                try push(&out, &last_rf_write, v3d_qpu.nop());
                try push(&out, &last_rf_write, v3d_qpu.nop());
            },
            .tex => {
                // In 4-way threaded mode, the per-thread TMU result FIFO holds
                // up to 2 four-component RGBA lookups (8 words). Queue a second
                // ready lookup before switching threads so both fetch in parallel.
                if (!tex_requested[j]) {
                    try requestTex42(&out, &last_rf_write, shader, &rf_reg, &use_r2, &r4_zeroed, &tex_requested, &tex_outstanding, j);
                }
                for (j + 1..n) |k| {
                    if (tex_outstanding >= 2) break;
                    const later = shader.insts[k];
                    if (!live[k] or skip_inst[k] or later.op != .tex or tex_requested[k]) continue;
                    var ready = true;
                    for (later.srcs[0..2]) |v| {
                        const vi = @intFromEnum(v);
                        if (vi >= j or use_r2[vi] or (isDeferredUnifOrConst(shader, vi) and first_use[vi] > j)) ready = false;
                    }
                    if (!ready) break;
                    try requestTex42(&out, &last_rf_write, shader, &rf_reg, &use_r2, &r4_zeroed, &tex_requested, &tex_outstanding, k);
                }
                if (!tex_covered[j]) {
                    try push(&out, &last_rf_write, v3d_qpu.thrsw());
                    try push(&out, &last_rf_write, v3d_qpu.nop());
                    try push(&out, &last_rf_write, v3d_qpu.nop());
                    for (0..n) |k| if (tex_requested[k]) {
                        tex_covered[k] = true;
                    };
                }
                // Read 4 RGBA float32 channels via ldtmu; lower.zig maps
                // unpack_unorm8(2)->R, (1)->G, (0)->B, (3)->A!
                // Hardware returns R, G, B, A in order, so store R into ch[2],
                // G into ch[1], B into ch[0], A into ch[3]!
                const ch = tex_ch_rf[j];
                for ([4]u6{ ch[2], ch[1], ch[0], ch[3] }) |c_rf| {
                    try push(&out, &last_rf_write, v3d_qpu.ldtmu(.rf(c_rf)));
                }
                tex_outstanding -= 1;
            },
            .tlb_color_load => {
                try ensureTlbLocked(&out, &last_rf_write, &tlb_locked);
                // On first sample, use ldtlbu if MSAA (to set PER_SAMPLE), or ldtlb if single-sample.
                if (is_msaa_blend and tlb_load_sample == 0) {
                    try push(&out, &last_rf_write, v3d_qpu.ldtlbu(.r(1)));
                    // TLB config for 4xf16 color load per-sample: 0xfffffffb
                    try addUnif(&out, .{ .constant = 0xfffffffb });
                } else {
                    try push(&out, &last_rf_write, v3d_qpu.ldtlb(.r(1)));
                }
                try push(&out, &last_rf_write, v3d_qpu.ldtlb(.r(2)));
                // Unpack r1.l (R), r1.h (G), r2.l (B), r2.h (A) into ch[2], ch[1], ch[0], ch[3]
                // because lower.zig expects unpack_unorm8(0)=B, (1)=G, (2)=R, (3)=A!
                const ch = tex_ch_rf[j];
                const unpacks = [4]struct { mux: v3d_qpu.Mux, unp: v3d_qpu.InputUnpack, rf: u6, used: bool }{
                    .{ .mux = .r1, .unp = .l, .rf = ch[2], .used = tex_ch_used[j][2] }, // R
                    .{ .mux = .r1, .unp = .h, .rf = ch[1], .used = tex_ch_used[j][1] }, // G
                    .{ .mux = .r2, .unp = .l, .rf = ch[0], .used = tex_ch_used[j][0] }, // B
                    .{ .mux = .r2, .unp = .h, .rf = ch[3], .used = tex_ch_used[j][3] }, // A
                };
                for (unpacks) |u| {
                    if (!u.used) continue;
                    try pushAlu(&out, &last_rf_write, .{
                        .mul = .{
                            .op = .fmov,
                            .dst = .rf(u.rf),
                            .a = .{ .mux = u.mux, .unpack = u.unp },
                        },
                    });
                }
                tlb_load_sample += 1;
            },
            .tlb_z => {
                try ensureTlbLocked(&out, &last_rf_write, &tlb_locked);
                try pushAlu(&out, &last_rf_write, .{
                    .raddr_a = 2, // rf2 = payload Z
                    .mul = .{
                        .op = .mov,
                        .dst = .magicAddr(v3d_qpu.W.tlbu),
                        .a = .{ .mux = .a },
                    },
                });
                try addUnif(&out, .{ .constant = 0xffffff8c });
            },
            .tlb_color, .tlb_color_ms => {
                try ensureTlbLocked(&out, &last_rf_write, &tlb_locked);
                const pack_idx = @intFromEnum(inst.srcs[0]);
                const pack_inst = shader.insts[pack_idx];
                // lower.zig passes (B, G, R, A) as (srcs[0], srcs[1], srcs[2], srcs[3]) to pack_unorm8888.
                // V3D 4.2 TLB expects (R, G) in the first vfpack and (B, A) in the second vfpack!
                const r_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[2] else inst.srcs[0];
                const g_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[1] else inst.srcs[0];
                const b_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[0] else inst.srcs[0];
                const a_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[3] else inst.srcs[0];

                const rg_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, &use_r2, r_val, g_val);
                const use_tlbu = (inst.op == .tlb_color_ms and tlb_write_sample == 0 and tlb_load_sample == 0);
                try pushAlu(&out, &last_rf_write, .{
                    .sig = rg_op.sig,
                    .raddr_a = rg_op.raddr_a,
                    .raddr_b = rg_op.raddr_b,
                    .add = .{
                        .op = .vfpack,
                        .dst = .magicAddr(if (use_tlbu) v3d_qpu.W.tlbu else v3d_qpu.W.tlb),
                        .a = .{ .mux = rg_op.mux_a },
                        .b = .{ .mux = rg_op.mux_b },
                    },
                });
                if (use_tlbu) {
                    try addUnif(&out, .{ .constant = 0xfffffffb });
                }

                const ba_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, &use_r2, b_val, a_val);
                try pushAlu(&out, &last_rf_write, .{
                    .sig = ba_op.sig,
                    .raddr_a = ba_op.raddr_a,
                    .raddr_b = ba_op.raddr_b,
                    .add = .{
                        .op = .vfpack,
                        .dst = .magicAddr(v3d_qpu.W.tlb),
                        .a = .{ .mux = ba_op.mux_a },
                        .b = .{ .mux = ba_op.mux_b },
                    },
                });
                tlb_write_sample += 1;
            },
            .vpm_write => {
                const src_idx = @intFromEnum(inst.srcs[0]);
                if (src_idx == cs_xy_inst or src_idx == vs_xy_inst) {
                    // On V3D 4.2, Xs and Ys are written as two separate VPM words in
                    // 24.8 fixed-point: ftoiz(ffloor(xs * 16.0)) and ftoiz(ffloor(ys * 16.0)),
                    // since lower.zig's xs and ys are already in 1/16ths of a pixel (.4)!
                    const xy_inst = shader.insts[src_idx];
                    const imm16 = v3d_qpu.encodeSmallImm(@bitCast(@as(f32, 16.0))).?;
                    for (xy_inst.srcs[0..2]) |coord_val| {
                        const mux_c = try loadToAcc(&out, &last_rf_write, shader, &rf_reg, &use_r2, coord_val, 0);
                        // r0 = coord * 16.0
                        try pushAlu(&out, &last_rf_write, .{
                            .sig = .{ .small_imm_b = true },
                            .raddr_b = imm16,
                            .mul = .{
                                .op = .fmul,
                                .dst = .r(0),
                                .a = .{ .mux = mux_c },
                                .b = .{ .mux = .b },
                            },
                        });
                        // r0 = ffloor(r0)
                        try pushAlu(&out, &last_rf_write, .{
                            .add = .{
                                .op = .ffloor,
                                .dst = .r(0),
                                .a = .{ .mux = .r0 },
                            },
                        });
                        // r0 = ftoiz(r0)
                        try pushAlu(&out, &last_rf_write, .{
                            .add = .{
                                .op = .ftoiz,
                                .dst = .r(0),
                                .a = .{ .mux = .r0 },
                            },
                        });
                        const idx_imm = v3d_qpu.encodeSmallImm(vpm_write_idx).?;
                        try pushAlu(&out, &last_rf_write, .{
                            .sig = .{ .small_imm_b = true },
                            .raddr_b = idx_imm,
                            .add = .{
                                .op = .stvpmv,
                                .a = .{ .mux = .b },
                                .b = .{ .mux = .r0 },
                            },
                        });
                        vpm_write_idx += 1;
                        out.num_vpm_writes += 1;
                    }
                } else {
                    const mux_v = try loadToAcc(&out, &last_rf_write, shader, &rf_reg, &use_r2, inst.srcs[0], 0);
                    const idx_imm = v3d_qpu.encodeSmallImm(vpm_write_idx) orelse blk: {
                        try push(&out, &last_rf_write, v3d_qpu.ldunifrf(.rf(1)));
                        try addUnif(&out, .{ .constant = vpm_write_idx });
                        break :blk null;
                    };
                    if (idx_imm) |enc| {
                        try pushAlu(&out, &last_rf_write, .{
                            .sig = .{ .small_imm_b = true },
                            .raddr_b = enc,
                            .add = .{
                                .op = .stvpmv,
                                .a = .{ .mux = .b },
                                .b = .{ .mux = mux_v },
                            },
                        });
                    } else {
                        try pushAlu(&out, &last_rf_write, .{
                            .raddr_a = 1,
                            .add = .{
                                .op = .stvpmv,
                                .a = .{ .mux = .a },
                                .b = .{ .mux = mux_v },
                            },
                        });
                    }
                    vpm_write_idx += 1;
                    out.num_vpm_writes += 1;
                }
            },
        }
    }

    if (shader.stage != .fragment) {
        try pushAlu(&out, &last_rf_write, .{
            .add = .{ .op = .vpmwt },
        });
    }

    // Program end: thrsw + 2 delay slots
    try push(&out, &last_rf_write, v3d_qpu.thrsw());
    try push(&out, &last_rf_write, v3d_qpu.nop());
    try push(&out, &last_rf_write, v3d_qpu.nop());

    return out;
}

test "compileV3d compiles fragment, vertex, and coordinate shaders" {
    var fs = Shader.init(.fragment);
    const u = fs.varying();
    const v = fs.varying();
    const texel = fs.texture(0, u, v);
    const r = fs.unpackUnorm8(texel, 2);
    const g = fs.unpackUnorm8(texel, 1);
    const b = fs.unpackUnorm8(texel, 0);
    const a = fs.unpackUnorm8(texel, 3);
    fs.tlbZ(fs.fragZ());
    fs.tlbColor(fs.packUnorm8888(b, g, r, a));
    const c_fs = try compileV3d(&fs);
    try std.testing.expectEqual(@as(u32, 2), c_fs.num_varyings);
    try std.testing.expectEqual(@as(u32, 1), c_fs.num_texture_samples);
    try std.testing.expect(c_fs.code().len > 0);
}

// --- VideoCore VII (V3D 7.1) Compiler ----------------------------------------

pub fn compileV3d71(shader: *const Shader) Error!Compiled {
    const n = shader.len;

    // On V3D 7.1, coordinate shaders only write pos[0..3] (VPM 0..3) and
    // Xs, Ys (VPM 4..5), not Zs or 1/Wc. Ignore the Zs and 1/Wc vpm_writes
    // in coordinate shaders before computing liveness.
    var skip_inst: [max_insts]bool = @splat(false);
    var cs_xy_inst: ?usize = null;
    var vs_xy_inst: ?usize = null;
    {
        var vpm_w_idx: u32 = 0;
        for (0..n) |j| {
            if (shader.insts[j].op == .vpm_write) {
                if (shader.stage == .coordinate) {
                    if (vpm_w_idx == 4) cs_xy_inst = @intFromEnum(shader.insts[j].srcs[0]);
                    if (vpm_w_idx >= 5) skip_inst[j] = true;
                } else if (shader.stage == .vertex) {
                    if (vpm_w_idx == 0) vs_xy_inst = @intFromEnum(shader.insts[j].srcs[0]);
                }
                vpm_w_idx += 1;
            }
        }
    }

    var live: [max_insts]bool = @splat(false);
    var uses: [max_insts]u16 = @splat(0);
    var first_use: [max_insts]u16 = @splat(std.math.maxInt(u16));
    var last_use: [max_insts]u16 = @splat(0);
    {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            if (skip_inst[i]) continue;
            if (shader.insts[i].op.hasSideEffects()) live[i] = true;
            if (!live[i]) continue;
            const inst = shader.insts[i];
            if (inst.op == .tlb_color or inst.op == .tlb_color_ms or inst.op == .vpm_write) {
                const src_idx = @intFromEnum(inst.srcs[0]);
                const src_inst = shader.insts[src_idx];
                if (src_inst.op == .pack_unorm8888 or src_inst.op == .pack_screen_xy) {
                    live[src_idx] = true;
                    for (shader.operands(src_idx)) |v| {
                        const d = @intFromEnum(v);
                        live[d] = true;
                        uses[d] += 1;
                        first_use[d] = @min(first_use[d], @as(u16, @intCast(i)));
                        last_use[d] = @max(last_use[d], @as(u16, @intCast(i)));
                    }
                    continue;
                }
            }
            if (inst.op == .pack_unorm8888 or inst.op == .pack_screen_xy) continue;
            for (shader.operands(i)) |v| {
                const d = @intFromEnum(v);
                live[d] = true;
                uses[d] += 1;
                first_use[d] = @min(first_use[d], @as(u16, @intCast(i)));
                last_use[d] = @max(last_use[d], @as(u16, @intCast(i)));
            }
        }
    }

    var tex_ch_used: [max_insts][4]bool = @splat(.{ false, false, false, false });
    var tex_ch_last_use: [max_insts][4]u16 = @splat(.{ 0, 0, 0, 0 });
    var tex_ch_active: [max_insts][4]bool = @splat(.{ false, false, false, false });
    for (0..n) |j| {
        if (!live[j] or skip_inst[j]) continue;
        const inst = shader.insts[j];
        if (inst.op == .unpack_unorm8) {
            const src_idx = @intFromEnum(inst.srcs[0]);
            const src_op = shader.insts[src_idx].op;
            if (src_op == .tex or src_op == .tlb_color_load) {
                const byte: u2 = @intCast(inst.imm);
                tex_ch_used[src_idx][byte] = true;
                tex_ch_last_use[src_idx][byte] = @max(tex_ch_last_use[src_idx][byte], last_use[j]);
            }
        }
    }

    // Allocate unified RF registers (rf5..rf63; rf0=implicit ldvary C/tmu mask,
    // rf1=scratch1, rf2=frag_z, rf3=frag_w, rf4=scratch2).
    var rf_free: [64]bool = @splat(true);
    for (0..5) |r_idx| rf_free[r_idx] = false;

    const takeRf = struct {
        fn f(free: *[64]bool) Error!u6 {
            for (free, 0..) |*slot, idx| if (slot.*) {
                slot.* = false;
                return @intCast(idx);
            };
            return error.OutOfRegisters;
        }
    }.f;

    const isDeferredUnifOrConst = struct {
        fn f(s: *const Shader, d: usize) bool {
            const op = s.insts[d].op;
            if (op == .uniform) return true;
            if (op == .constant) return v3d_qpu.encodeSmallImm(s.insts[d].imm) == null;
            return false;
        }
    }.f;

    var rf_reg: [max_insts]u6 = @splat(0);
    var has_rf: [max_insts]bool = @splat(false);
    var active_rf: [max_insts]bool = @splat(false);
    var tex_ch_rf: [max_insts][4]u6 = @splat(.{ 0, 0, 0, 0 });
    var has_tex_ch: [max_insts]bool = @splat(false);

    for (0..n) |j| {
        for (0..n) |d| {
            if (active_rf[d] and last_use[d] < j) {
                if (has_rf[d] and rf_reg[d] >= 5) {
                    rf_free[rf_reg[d]] = true;
                }
                active_rf[d] = false;
            }
            if (has_tex_ch[d]) {
                for (0..4) |ch| {
                    if (tex_ch_active[d][ch] and tex_ch_last_use[d][ch] < j) {
                        rf_free[tex_ch_rf[d][ch]] = true;
                        tex_ch_active[d][ch] = false;
                    }
                }
            }
        }
        if (!live[j] or skip_inst[j]) continue;

        for (0..j) |d| {
            if (live[d] and !skip_inst[d] and isDeferredUnifOrConst(shader, d) and first_use[d] == j) {
                rf_reg[d] = try takeRf(&rf_free);
                has_rf[d] = true;
                active_rf[d] = true;
            }
        }

        if (!shader.insts[j].op.hasResult()) continue;
        const inst = shader.insts[j];
        switch (inst.op) {
            .frag_w => {
                rf_reg[j] = 3; // rf3 = payload W on V3D 7.1
                has_rf[j] = true;
            },
            .frag_z => {
                rf_reg[j] = 2; // rf2 = payload Z on V3D 7.1
                has_rf[j] = true;
            },
            .uniform, .constant, .pack_unorm8888, .pack_screen_xy => {},
            .tex, .tlb_color_load => {
                for (0..4) |ch| {
                    if (tex_ch_used[j][ch]) {
                        tex_ch_rf[j][ch] = try takeRf(&rf_free);
                        tex_ch_active[j][ch] = true;
                    } else {
                        tex_ch_rf[j][ch] = 1; // scratch rf1 for unused channel
                    }
                }
                has_tex_ch[j] = true;
            },
            .unpack_unorm8 => {
                const src_idx = @intFromEnum(inst.srcs[0]);
                const byte: u2 = @intCast(inst.imm);
                if (has_tex_ch[src_idx]) {
                    rf_reg[j] = tex_ch_rf[src_idx][byte];
                    has_rf[j] = true;
                } else {
                    rf_reg[j] = try takeRf(&rf_free);
                    has_rf[j] = true;
                    active_rf[j] = true;
                }
            },
            else => {
                if (uses[j] > 0) {
                    rf_reg[j] = try takeRf(&rf_free);
                    has_rf[j] = true;
                    active_rf[j] = true;
                }
            },
        }
    }

    var out: Compiled = .{
        .stage = shader.stage,
        .threaded = true,
    };
    var last_rf_write: ?u6 = null;

    const pushRaw = struct {
        fn f(o: *Compiled, last_w: *?u6, inst: v3d_qpu.Inst, written_rf: ?u6) Error!void {
            if (o.code_len >= max_code) return error.ProgramTooLong;
            o.code_buf[o.code_len] = inst;
            o.code_len += 1;
            last_w.* = written_rf;
        }
    }.f;

    const pushAlu = struct {
        fn f(o: *Compiled, last_w: *?u6, a: v3d_qpu.Alu71) Error!void {
            if (last_w.*) |lw| {
                const add_nsrc = a.add.op.numSrc();
                const mul_nsrc = a.mul.op.numSrc();
                const reads_lw = (add_nsrc >= 1 and !a.add.a.imm and a.add.a.raddr == lw) or
                    (add_nsrc >= 2 and !a.add.b.imm and a.add.b.raddr == lw) or
                    (mul_nsrc >= 1 and !a.mul.a.imm and a.mul.a.raddr == lw) or
                    (mul_nsrc >= 2 and !a.mul.b.imm and a.mul.b.raddr == lw);
                if (reads_lw) {
                    try pushRaw(o, last_w, v3d_qpu.nop71(), null);
                }
            }
            var written: ?u6 = null;
            if (!a.add.dst.magic) written = a.add.dst.waddr;
            if (!a.mul.dst.magic) written = a.mul.dst.waddr;
            if (a.sig.writesAddress() and !a.sig_magic) {
                written = a.sig_addr;
            }
            try pushRaw(o, last_w, try v3d_qpu.alu71(a), written);
        }
    }.f;

    const push = struct {
        fn f(o: *Compiled, last_w: *?u6, inst: v3d_qpu.Inst) Error!void {
            const sig: u5 = @truncate(inst >> 53);
            var written: ?u6 = null;
            // ldunifrf (12), ldtmu (4), ldvary (8), ldtlbu (9), ldtlb (10)
            if (sig == 12 or sig == 4 or sig == 8 or sig == 9 or sig == 10) {
                const cond: u7 = @truncate(inst >> 46);
                if (cond & (1 << 6) == 0) written = @truncate(cond);
            }
            try pushRaw(o, last_w, inst, written);
        }
    }.f;

    const addUnif = struct {
        fn f(o: *Compiled, k: UniformKind) Error!void {
            if (o.uniform_len >= max_uniforms) return error.TooManyUniforms;
            o.uniform_buf[o.uniform_len] = k;
            o.uniform_len += 1;
        }
    }.f;

    const prepUnary = struct {
        fn f(s: *const Shader, r_reg: *const [max_insts]u6, v: Value) v3d_qpu.Input71 {
            const d = @intFromEnum(v);
            const def = s.insts[d];
            if (def.op == .constant) {
                if (v3d_qpu.encodeSmallImm(def.imm)) |imm| {
                    return .immVal(imm);
                }
            }
            return .rf(r_reg[d]);
        }
    }.f;

    const prepBinary = struct {
        fn f(o: *Compiled, last_w: *?u6, s: *const Shader, r_reg: *const [max_insts]u6, v0: Value, v1: Value) Error!struct { a: v3d_qpu.Input71, b: v3d_qpu.Input71 } {
            var in0 = prepUnary(s, r_reg, v0);
            if (v0 == v1) {
                if (in0.imm) {
                    try pushAlu(o, last_w, .{
                        .mul = .{
                            .op = .mov,
                            .dst = .rf(1),
                            .a = in0,
                        },
                    });
                    return .{ .a = .rf(1), .b = .rf(1) };
                }
                return .{ .a = in0, .b = in0 };
            }
            var in1 = prepUnary(s, r_reg, v1);
            // At most one small immediate per instruction, and when v0 != v1 we must
            // ensure in0.raddr != in1.raddr so fadd/fmin/fmax operand ordering is strict.
            if (in0.imm and (in1.imm or in0.raddr == in1.raddr)) {
                try pushAlu(o, last_w, .{
                    .mul = .{
                        .op = .mov,
                        .dst = .rf(1),
                        .a = in0,
                    },
                });
                in0 = .rf(1);
            } else if (in1.imm and in0.raddr == in1.raddr) {
                try pushAlu(o, last_w, .{
                    .mul = .{
                        .op = .mov,
                        .dst = .rf(1),
                        .a = in1,
                    },
                });
                in1 = .rf(1);
            }
            return .{ .a = in0, .b = in1 };
        }
    }.f;

    var vpm_read_idx: u32 = 0;
    var vpm_write_idx: u32 = 0;
    var tlb_locked = false;
    var tlb_load_sample: u32 = 0;
    var tlb_write_sample: u32 = 0;
    var rf0_zeroed = false;
    var tex_requested: [max_insts]bool = @splat(false);
    var tex_covered: [max_insts]bool = @splat(false);
    var tex_outstanding: u8 = 0;
    const PendingVary = struct { tmp_rf: u6, dst: v3d_qpu.Dst };
    var pending_vary: ?PendingVary = null;
    const is_msaa_blend = blk: {
        for (0..n) |j| if (live[j] and shader.insts[j].op == .tlb_color_ms) break :blk true;
        break :blk false;
    };

    const requestTex71 = struct {
        fn f(
            o: *Compiled,
            last_w: *?u6,
            s: *const Shader,
            r_reg: *const [max_insts]u6,
            rf0_zero: *bool,
            req: *[max_insts]bool,
            out_cnt: *u8,
            idx: usize,
        ) Error!void {
            const t_inst = s.insts[idx];
            const slot: u8 = @intCast(t_inst.imm);
            if (!rf0_zero.*) {
                // Clear rf0 (per-pixel TMU mask on V3D 7.1, bit 0 = 0 -> active).
                try pushAlu(o, last_w, .{
                    .mul = .{
                        .op = .mov,
                        .dst = .rf(0),
                        .a = .immVal(0),
                    },
                });
                rf0_zero.* = true;
            }
            // Emit wrtmuc for P0 first (also hides any RF write delay on u_t).
            try push(o, last_w, v3d_qpu.wrtmuc71());
            try addUnif(o, .{ .tex_p0 = slot });
            const u_t = prepUnary(s, r_reg, t_inst.srcs[1]);
            const fold_p1 = !u_t.imm;
            try pushAlu(o, last_w, .{
                .sig = if (fold_p1) .{ .wrtmuc = true } else .{},
                .mul = .{
                    .op = .mov,
                    .dst = .magicAddr(v3d_qpu.W.tmut),
                    .a = u_t,
                },
            });
            if (!fold_p1) {
                try push(o, last_w, v3d_qpu.wrtmuc71());
            }
            try addUnif(o, .{ .tex_p1 = slot });
            const u_s = prepUnary(s, r_reg, t_inst.srcs[0]);
            try pushAlu(o, last_w, .{
                .mul = .{
                    .op = .mov,
                    .dst = .magicAddr(v3d_qpu.W.tmus),
                    .a = u_s,
                },
            });
            req[idx] = true;
            out_cnt.* += 1;
            o.num_texture_samples += 1;
        }
    }.f;

    const ensureTlbLocked = struct {
        fn f(o: *Compiled, last_w: *?u6, locked: *bool) Error!void {
            if (locked.*) return;
            locked.* = true;
            try push(o, last_w, v3d_qpu.thrsw71());
            try push(o, last_w, v3d_qpu.thrsw71());
            try push(o, last_w, v3d_qpu.nop71());
            try push(o, last_w, v3d_qpu.nop71());
        }
    }.f;

    for (0..n) |j| {
        if (!live[j] or skip_inst[j]) continue;

        for (0..j) |d| {
            if (live[d] and !skip_inst[d] and isDeferredUnifOrConst(shader, d) and first_use[d] == j) {
                const def = shader.insts[d];
                try push(&out, &last_rf_write, v3d_qpu.ldunifrf71(.rf(rf_reg[d])));
                if (def.op == .uniform) {
                    try addUnif(&out, .{ .user = def.imm });
                } else {
                    try addUnif(&out, .{ .constant = def.imm });
                }
            }
        }

        const inst = shader.insts[j];
        const dst_rf = rf_reg[j];
        const dst: v3d_qpu.Dst = if (has_rf[j]) .rf(dst_rf) else .nop;

        if (inst.op != .varying and inst.op != .frag_w and inst.op != .frag_z and
            inst.op != .uniform and inst.op != .constant and inst.op != .pack_unorm8888 and
            inst.op != .pack_screen_xy and inst.op != .unpack_unorm8)
        {
            if (pending_vary) |pv| {
                try pushAlu(&out, &last_rf_write, .{
                    .add = .{
                        .op = .fadd,
                        .dst = pv.dst,
                        .a = .rf(pv.tmp_rf),
                        .b = .rf(0),
                    },
                });
                pending_vary = null;
            }
        }

        switch (inst.op) {
            .frag_w, .frag_z, .uniform, .constant, .pack_unorm8888, .pack_screen_xy, .unpack_unorm8 => {},
            .vpm_read => {
                if (v3d_qpu.encodeSmallImm(vpm_read_idx)) |enc| {
                    try pushAlu(&out, &last_rf_write, .{
                        .add = .{
                            .op = .ldvpmv_in,
                            .dst = dst,
                            .a = .immVal(enc),
                        },
                    });
                } else {
                    try push(&out, &last_rf_write, v3d_qpu.ldunifrf71(.rf(1)));
                    try addUnif(&out, .{ .constant = vpm_read_idx });
                    try pushAlu(&out, &last_rf_write, .{
                        .add = .{
                            .op = .ldvpmv_in,
                            .dst = dst,
                            .a = .rf(1),
                        },
                    });
                }
                vpm_read_idx += 1;
                out.num_vpm_reads += 1;
            },
            .varying => {
                // On V3D 7.1, ldvary rf_tmp writes (A*x + B*y) to rf_tmp and C
                // to rf0 after a 1-instruction delay. When consecutive varyings
                // run, issue the next ldvary in the previous fmul's delay slot
                // and the previous fadd in the new ldvary's delay slot.
                rf0_zeroed = false;
                if (pending_vary) |pv| {
                    const cur_tmp: u6 = if (pv.tmp_rf == 1) 4 else 1;
                    try push(&out, &last_rf_write, v3d_qpu.ldvary71(.rf(cur_tmp)));
                    try pushAlu(&out, &last_rf_write, .{
                        .add = .{
                            .op = .fadd,
                            .dst = pv.dst,
                            .a = .rf(pv.tmp_rf),
                            .b = .rf(0),
                        },
                    });
                    try pushAlu(&out, &last_rf_write, .{
                        .mul = .{
                            .op = .fmul,
                            .dst = .rf(cur_tmp),
                            .a = .rf(cur_tmp),
                            .b = .rf(3), // rf3 = payload W on V3D 7.1
                        },
                    });
                    pending_vary = .{ .tmp_rf = cur_tmp, .dst = dst };
                } else {
                    try push(&out, &last_rf_write, v3d_qpu.ldvary71(.rf(1)));
                    try push(&out, &last_rf_write, v3d_qpu.nop71());
                    try pushAlu(&out, &last_rf_write, .{
                        .mul = .{
                            .op = .fmul,
                            .dst = .rf(1),
                            .a = .rf(1),
                            .b = .rf(3), // rf3 = payload W on V3D 7.1
                        },
                    });
                    pending_vary = .{ .tmp_rf = 1, .dst = dst };
                }
                out.num_varyings += 1;
            },
            .fmaxabs => {
                const b_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, inst.srcs[0], inst.srcs[1]);
                var a_in = b_op.a;
                var b_in = b_op.b;
                a_in.unpack = .abs;
                b_in.unpack = .abs;
                try pushAlu(&out, &last_rf_write, .{
                    .add = .{
                        .op = .fmax,
                        .dst = dst,
                        .a = a_in,
                        .b = b_in,
                    },
                });
            },
            .ftoi, .itof => {
                const u_in = prepUnary(shader, &rf_reg, inst.srcs[0]);
                try pushAlu(&out, &last_rf_write, .{
                    .add = .{
                        .op = if (inst.op == .ftoi) .ftoiz else .itof,
                        .dst = dst,
                        .a = u_in,
                    },
                });
            },
            .fadd, .fsub, .fmin, .fmax, .add, .sub, .shl, .shr, .asr, .@"and", .@"or", .xor, .min, .max, .fmul => {
                const b_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, inst.srcs[0], inst.srcs[1]);
                if (inst.op == .fmul) {
                    try pushAlu(&out, &last_rf_write, .{
                        .mul = .{
                            .op = .fmul,
                            .dst = dst,
                            .a = b_op.a,
                            .b = b_op.b,
                        },
                    });
                } else {
                    const v3d_op: v3d_qpu.AddOp = switch (inst.op) {
                        .fadd => .fadd,
                        .fsub => .fsub,
                        .fmin => .fmin,
                        .fmax => .fmax,
                        .add => .add,
                        .sub => .sub,
                        .shl => .shl,
                        .shr => .shr,
                        .asr => .asr,
                        .@"and" => .@"and",
                        .@"or" => .@"or",
                        .xor => .xor,
                        .min => .min,
                        .max => .max,
                        else => unreachable,
                    };
                    try pushAlu(&out, &last_rf_write, .{
                        .add = .{
                            .op = v3d_op,
                            .dst = dst,
                            .a = b_op.a,
                            .b = b_op.b,
                        },
                    });
                }
            },
            .recip, .rsqrt, .exp2, .log2 => {
                // On V3D 7.1, SFU operations are direct 1-src ADD ALU instructions.
                const u_in = prepUnary(shader, &rf_reg, inst.srcs[0]);
                const v3d_op: v3d_qpu.AddOp = switch (inst.op) {
                    .recip => .recip,
                    .rsqrt => .rsqrt,
                    .exp2 => .exp,
                    .log2 => .log,
                    else => unreachable,
                };
                try pushAlu(&out, &last_rf_write, .{
                    .add = .{
                        .op = v3d_op,
                        .dst = dst,
                        .a = u_in,
                    },
                });
            },
            .tex => {
                if (!tex_requested[j]) {
                    try requestTex71(&out, &last_rf_write, shader, &rf_reg, &rf0_zeroed, &tex_requested, &tex_outstanding, j);
                }
                for (j + 1..n) |k| {
                    if (tex_outstanding >= 2) break;
                    const later = shader.insts[k];
                    if (!live[k] or skip_inst[k] or later.op != .tex or tex_requested[k]) continue;
                    var ready = true;
                    for (later.srcs[0..2]) |v| {
                        const vi = @intFromEnum(v);
                        if (vi >= j or (isDeferredUnifOrConst(shader, vi) and first_use[vi] > j)) ready = false;
                    }
                    if (!ready) break;
                    try requestTex71(&out, &last_rf_write, shader, &rf_reg, &rf0_zeroed, &tex_requested, &tex_outstanding, k);
                }
                if (!tex_covered[j]) {
                    try push(&out, &last_rf_write, v3d_qpu.thrsw71());
                    try push(&out, &last_rf_write, v3d_qpu.nop71());
                    try push(&out, &last_rf_write, v3d_qpu.nop71());
                    for (0..n) |k| if (tex_requested[k]) {
                        tex_covered[k] = true;
                    };
                }
                // Read 4 RGBA float32 channels via ldtmu
                const ch = tex_ch_rf[j];
                for ([4]u6{ ch[2], ch[1], ch[0], ch[3] }) |c_rf| {
                    try push(&out, &last_rf_write, v3d_qpu.ldtmu71(.rf(c_rf)));
                }
                tex_outstanding -= 1;
            },
            .tlb_color_load => {
                try ensureTlbLocked(&out, &last_rf_write, &tlb_locked);
                if (is_msaa_blend and tlb_load_sample == 0) {
                    try push(&out, &last_rf_write, v3d_qpu.ldtlbu71(.rf(1)));
                    try addUnif(&out, .{ .constant = 0xfffffffb });
                } else {
                    try push(&out, &last_rf_write, v3d_qpu.ldtlb71(.rf(1)));
                }
                try push(&out, &last_rf_write, v3d_qpu.ldtlb71(.rf(4)));
                const ch = tex_ch_rf[j];
                const unpacks = [4]struct { src_rf: u6, unp: v3d_qpu.InputUnpack, rf: u6, used: bool }{
                    .{ .src_rf = 1, .unp = .l, .rf = ch[2], .used = tex_ch_used[j][2] }, // R
                    .{ .src_rf = 1, .unp = .h, .rf = ch[1], .used = tex_ch_used[j][1] }, // G
                    .{ .src_rf = 4, .unp = .l, .rf = ch[0], .used = tex_ch_used[j][0] }, // B
                    .{ .src_rf = 4, .unp = .h, .rf = ch[3], .used = tex_ch_used[j][3] }, // A
                };
                for (unpacks) |u| {
                    if (!u.used) continue;
                    try pushAlu(&out, &last_rf_write, .{
                        .mul = .{
                            .op = .fmov,
                            .dst = .rf(u.rf),
                            .a = .{ .raddr = u.src_rf, .unpack = u.unp },
                        },
                    });
                }
                tlb_load_sample += 1;
            },
            .tlb_z => {
                try ensureTlbLocked(&out, &last_rf_write, &tlb_locked);
                try pushAlu(&out, &last_rf_write, .{
                    .mul = .{
                        .op = .mov,
                        .dst = .magicAddr(v3d_qpu.W.tlbu),
                        .a = .rf(2), // rf2 = payload Z
                    },
                });
                try addUnif(&out, .{ .constant = 0xffffff8c });
            },
            .tlb_color, .tlb_color_ms => {
                try ensureTlbLocked(&out, &last_rf_write, &tlb_locked);
                const pack_idx = @intFromEnum(inst.srcs[0]);
                const pack_inst = shader.insts[pack_idx];
                const r_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[2] else inst.srcs[0];
                const g_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[1] else inst.srcs[0];
                const b_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[0] else inst.srcs[0];
                const a_val: Value = if (pack_inst.op == .pack_unorm8888) pack_inst.srcs[3] else inst.srcs[0];

                const rg_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, r_val, g_val);
                const use_tlbu = (inst.op == .tlb_color_ms and tlb_write_sample == 0 and tlb_load_sample == 0);
                try pushAlu(&out, &last_rf_write, .{
                    .add = .{
                        .op = .vfpack,
                        .dst = .magicAddr(if (use_tlbu) v3d_qpu.W.tlbu else v3d_qpu.W.tlb),
                        .a = rg_op.a,
                        .b = rg_op.b,
                    },
                });
                if (use_tlbu) {
                    try addUnif(&out, .{ .constant = 0xfffffffb });
                }

                const ba_op = try prepBinary(&out, &last_rf_write, shader, &rf_reg, b_val, a_val);
                try pushAlu(&out, &last_rf_write, .{
                    .add = .{
                        .op = .vfpack,
                        .dst = .magicAddr(v3d_qpu.W.tlb),
                        .a = ba_op.a,
                        .b = ba_op.b,
                    },
                });
                tlb_write_sample += 1;
            },
            .vpm_write => {
                const src_idx = @intFromEnum(inst.srcs[0]);
                if (src_idx == cs_xy_inst or src_idx == vs_xy_inst) {
                    const xy_inst = shader.insts[src_idx];
                    const imm16 = v3d_qpu.encodeSmallImm(@bitCast(@as(f32, 16.0))).?;
                    for (xy_inst.srcs[0..2]) |coord_val| {
                        var coord_in = prepUnary(shader, &rf_reg, coord_val);
                        if (coord_in.imm) {
                            try pushAlu(&out, &last_rf_write, .{
                                .mul = .{
                                    .op = .mov,
                                    .dst = .rf(1),
                                    .a = coord_in,
                                },
                            });
                            coord_in = .rf(1);
                        }
                        // rf1 = coord * 16.0
                        try pushAlu(&out, &last_rf_write, .{
                            .mul = .{
                                .op = .fmul,
                                .dst = .rf(1),
                                .a = coord_in,
                                .b = .immVal(imm16),
                            },
                        });
                        // rf1 = ffloor(rf1)
                        try pushAlu(&out, &last_rf_write, .{
                            .add = .{
                                .op = .ffloor,
                                .dst = .rf(1),
                                .a = .rf(1),
                            },
                        });
                        // rf1 = ftoiz(rf1)
                        try pushAlu(&out, &last_rf_write, .{
                            .add = .{
                                .op = .ftoiz,
                                .dst = .rf(1),
                                .a = .rf(1),
                            },
                        });
                        const idx_imm = v3d_qpu.encodeSmallImm(vpm_write_idx).?;
                        try pushAlu(&out, &last_rf_write, .{
                            .add = .{
                                .op = .stvpmv,
                                .a = .immVal(idx_imm),
                                .b = .rf(1),
                            },
                        });
                        vpm_write_idx += 1;
                        out.num_vpm_writes += 1;
                    }
                } else {
                    var val_in = prepUnary(shader, &rf_reg, inst.srcs[0]);
                    if (val_in.imm) {
                        try pushAlu(&out, &last_rf_write, .{
                            .mul = .{
                                .op = .mov,
                                .dst = .rf(4),
                                .a = val_in,
                            },
                        });
                        val_in = .rf(4);
                    }
                    if (v3d_qpu.encodeSmallImm(vpm_write_idx)) |enc| {
                        try pushAlu(&out, &last_rf_write, .{
                            .add = .{
                                .op = .stvpmv,
                                .a = .immVal(enc),
                                .b = val_in,
                            },
                        });
                    } else {
                        try push(&out, &last_rf_write, v3d_qpu.ldunifrf71(.rf(1)));
                        try addUnif(&out, .{ .constant = vpm_write_idx });
                        try pushAlu(&out, &last_rf_write, .{
                            .add = .{
                                .op = .stvpmv,
                                .a = .rf(1),
                                .b = val_in,
                            },
                        });
                    }
                    vpm_write_idx += 1;
                    out.num_vpm_writes += 1;
                }
            },
        }
    }

    if (pending_vary) |pv| {
        try pushAlu(&out, &last_rf_write, .{
            .add = .{
                .op = .fadd,
                .dst = pv.dst,
                .a = .rf(pv.tmp_rf),
                .b = .rf(0),
            },
        });
    }

    if (shader.stage != .fragment) {
        try pushAlu(&out, &last_rf_write, .{
            .add = .{ .op = .vpmwt },
        });
    }

    // Program end: thrsw + 2 delay slots
    try push(&out, &last_rf_write, v3d_qpu.thrsw71());
    try push(&out, &last_rf_write, v3d_qpu.nop71());
    try push(&out, &last_rf_write, v3d_qpu.nop71());

    return out;
}

test "compileV3d71 compiles fragment, vertex, and coordinate shaders" {
    var fs = Shader.init(.fragment);
    const u = fs.varying();
    const v = fs.varying();
    const texel = fs.texture(0, u, v);
    const r = fs.unpackUnorm8(texel, 2);
    const g = fs.unpackUnorm8(texel, 1);
    const b = fs.unpackUnorm8(texel, 0);
    const a = fs.unpackUnorm8(texel, 3);
    fs.tlbZ(fs.fragZ());
    fs.tlbColor(fs.packUnorm8888(b, g, r, a));
    const c_fs = try compileV3d71(&fs);
    try std.testing.expectEqual(@as(u32, 2), c_fs.num_varyings);
    try std.testing.expectEqual(@as(u32, 1), c_fs.num_texture_samples);
    try std.testing.expect(c_fs.code().len > 0);
}

