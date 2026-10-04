//! Shader compiler: builds shaders as a list of SSA values and generates
//! QPU code for them.
//!
//! Shaders are straight-line programs (no control flow yet). Each value is
//! produced by exactly one instruction; the builder methods on `Shader`
//! append instructions and return the value they define.
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

pub const Stage = qpu.Stage;

pub const max_insts = 1024;
pub const max_code = 1024;
pub const max_uniforms = 64;

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

    fn hasResult(op: Op) bool {
        return switch (op) {
            .vpm_write, .tlb_z, .tlb_color => false,
            else => true,
        };
    }

    /// Instructions that must be kept even if their result is unused.
    fn hasSideEffects(op: Op) bool {
        return switch (op) {
            .vpm_read, .varying, .tex, .vpm_write, .tlb_z, .tlb_color => true,
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
    pub fn texture(s: *Shader, tex_s: Value, tex_t: Value) Value {
        return s.pushSrcs(.tex, &.{ tex_s, tex_t }, 0);
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

    fn operands(s: *const Shader, i: usize) []const Value {
        return s.insts[i].srcs[0..s.insts[i].nsrc];
    }
};

/// What each word of a shader's uniform stream must contain.
pub const UniformKind = union(enum) {
    /// The caller's uniform with this index.
    user: u32,
    /// Texture config parameter 0 (relocated by the kernel) for a unit.
    tex_p0: u8,
    /// Texture config parameter 1 for a unit.
    tex_p1: u8,
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

    pub fn uniforms(c: *const Compiled) []const UniformKind {
        return c.uniform_buf[0..c.uniform_len];
    }
};

pub const Error = qpu.EncodeError || qpu.ValidationError || qpu_schedule.Error || error{
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
        .tlb_color_load, .tlb_z, .tlb_color => return false,
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
                // Writing T then S each take one config uniform (P0, P1);
                // the S write starts the fetch.
                const s_reg = try g.operand(shader, reg, inst.srcs[0]);
                const t_reg = try g.operand(shader, reg, inst.srcs[1]);
                try g.emit(try qpu.mov(.{ .periph = qpu.W.tmu0_t }, t_reg.src()));
                try g.addUniform(.{ .tex_p0 = 0 });
                try g.emit(try qpu.mov(.{ .periph = qpu.W.tmu0_s }, s_reg.src()));
                try g.addUniform(.{ .tex_p1 = 0 });
                // Threaded: let the other thread run while the texture
                // unit fetches (placed by `placeThreadSwitches`).
                if (threaded) {
                    try g.push(qpu.nop(.thread_switch));
                    g.last_switch = g.out.code_len - 1;
                }
                try g.emit(qpu.nop(.load_tmu0));
                try g.emit(try qpu.mov(dst.dst(), qpu.r(4)));
                g.out.num_texture_samples += 1;
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
            .vpm_write, .tlb_z, .tlb_color => {
                const periph: u6 = switch (inst.op) {
                    .vpm_write => qpu.W.vpm,
                    .tlb_z => qpu.W.tlb_z,
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
    var t = s.texture(u, v);
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

test "each texture sample switches threads, the last one last" {
    var s = Shader.init(.fragment);
    const u = s.varying();
    const v = s.varying();
    const t0 = s.texture(u, v);
    const t1 = s.texture(v, u);
    s.tlbColor(s.fadd(t0, t1));
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
