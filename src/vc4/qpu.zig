//! Instruction encoding for the VideoCore IV QPU (the shader processor in the
//! BCM2835 V3D block).
//!
//! Every QPU instruction is 64 bits and normally issues one operation on the
//! "add" ALU and one on the "mul" ALU in parallel. Both ALUs share two read
//! ports: one on physical register file A and one on register file B, plus
//! the accumulators r0-r5. This module turns a structured description of an
//! instruction into its binary encoding and rejects encodings the hardware
//! cannot express (e.g. reading two different regfile A registers).
//!
//! Reference: "VideoCore IV 3D Architecture Reference Guide" (Broadcom, 2013),
//! section 3, and the kernel's drivers/gpu/drm/vc4/vc4_qpu_defines.h.

const std = @import("std");

pub const Inst = u64;

pub const Sig = enum(u4) {
    breakpoint = 0,
    none = 1,
    thread_switch = 2,
    prog_end = 3,
    wait_scoreboard = 4,
    scoreboard_unlock = 5,
    last_thread_switch = 6,
    coverage_load = 7,
    color_load = 8,
    color_load_end = 9,
    load_tmu0 = 10,
    load_tmu1 = 11,
    alpha_mask_load = 12,
    small_imm = 13,
    load_imm = 14,
    branch = 15,
};

pub const AddOp = enum(u5) {
    nop = 0,
    fadd = 1,
    fsub = 2,
    fmin = 3,
    fmax = 4,
    fminabs = 5,
    fmaxabs = 6,
    ftoi = 7,
    itof = 8,
    add = 12,
    sub = 13,
    shr = 14,
    asr = 15,
    ror = 16,
    shl = 17,
    min = 18,
    max = 19,
    @"and" = 20,
    @"or" = 21,
    xor = 22,
    not = 23,
    clz = 24,
    v8adds = 30,
    v8subs = 31,
};

pub const MulOp = enum(u3) {
    nop = 0,
    fmul = 1,
    mul24 = 2,
    v8muld = 3,
    v8min = 4,
    v8max = 5,
    v8adds = 6,
    v8subs = 7,
};

pub const Cond = enum(u3) {
    never = 0,
    always = 1,
    zs = 2,
    zc = 3,
    ns = 4,
    nc = 5,
    cs = 6,
    cc = 7,
};

/// ALU input multiplexer selection.
pub const Mux = enum(u3) { r0, r1, r2, r3, r4, r5, a, b };

/// Special read addresses (values >= 32 of the raddr_a / raddr_b fields).
pub const R = struct {
    /// Fragment shader payload: W on regfile A, Z on regfile B.
    pub const frag_payload_zw = 15;
    pub const unif = 32;
    pub const vary = 35;
    pub const elem_qpu = 38;
    pub const nop = 39;
    pub const xy_pixel_coord = 41;
    pub const ms_rev_flags = 42;
    pub const vpm = 48;
    pub const vpm_ld_busy = 49;
    pub const vpm_ld_wait = 50;
    pub const mutex_acquire = 51;
};

/// Write addresses (values >= 32 of the waddr_add / waddr_mul fields).
pub const W = struct {
    pub const acc0 = 32;
    pub const tmu_noswap = 36;
    pub const acc5 = 37;
    pub const host_int = 38;
    pub const nop = 39;
    pub const uniforms_address = 40;
    pub const quad_xy = 41;
    pub const ms_flags = 42;
    pub const tlb_stencil_setup = 43;
    pub const tlb_z = 44;
    pub const tlb_color_ms = 45;
    pub const tlb_color_all = 46;
    pub const tlb_alpha_mask = 47;
    pub const vpm = 48;
    /// VPM read setup on regfile A, VPM write setup on regfile B.
    pub const vpmvcd_setup = 49;
    pub const vpm_addr = 50;
    pub const mutex_release = 51;
    pub const sfu_recip = 52;
    pub const sfu_recipsqrt = 53;
    pub const sfu_exp = 54;
    pub const sfu_log = 55;
    pub const tmu0_s = 56;
    pub const tmu0_t = 57;
    pub const tmu0_r = 58;
    pub const tmu0_b = 59;
    pub const tmu1_s = 60;
    pub const tmu1_t = 61;
    pub const tmu1_r = 62;
    pub const tmu1_b = 63;
};

/// Pack modes applied to the result written to regfile A (PM = 0).
pub const PackA = enum(u4) {
    none = 0,
    @"16a" = 1,
    @"16b" = 2,
    @"8888" = 3,
    @"8a" = 4,
    @"8b" = 5,
    @"8c" = 6,
    @"8d" = 7,
    @"32_sat" = 8,
    @"16a_sat" = 9,
    @"16b_sat" = 10,
    @"8888_sat" = 11,
    @"8a_sat" = 12,
    @"8b_sat" = 13,
    @"8c_sat" = 14,
    @"8d_sat" = 15,
};

/// Pack modes applied to the mul ALU result (PM = 1). These convert a float
/// in [0, 1] to an 8-bit unorm value, leaving the other bytes of the
/// destination untouched.
pub const PackMul = enum(u4) {
    none = 0,
    @"8888" = 3,
    @"8a" = 4,
    @"8b" = 5,
    @"8c" = 6,
    @"8d" = 7,
};

pub const Pack = union(enum) {
    none,
    regfile_a: PackA,
    mul: PackMul,
};

/// Unpack modes for values read from regfile A (PM = 0) or r4 (PM = 1).
/// The 8-bit modes produce a [0, 1] float for float operations and a
/// zero-extended integer otherwise.
pub const UnpackMode = enum(u3) {
    none = 0,
    @"16a" = 1,
    @"16b" = 2,
    @"8d_rep" = 3,
    @"8a" = 4,
    @"8b" = 5,
    @"8c" = 6,
    @"8d" = 7,
};

pub const Unpack = union(enum) {
    none,
    regfile_a: UnpackMode,
    r4: UnpackMode,
};

/// An ALU source operand.
pub const Src = union(enum) {
    /// Accumulator r0-r5.
    acc: u3,
    /// Read address on regfile A (0-31 physical registers, or an `R` value).
    a: u6,
    /// Read address on regfile B (0-31 physical registers, or an `R` value).
    b: u6,
    /// Small immediate, already encoded (see `smallImmInt`/`smallImmFloat`).
    imm: u6,
};

/// An ALU destination.
pub const Dst = union(enum) {
    nop,
    /// Accumulator r0-r3 or r5 (r4 is read-only).
    acc: u3,
    /// Physical register (0-31) or file-specific peripheral on regfile A.
    a: u6,
    /// Physical register (0-31) or file-specific peripheral on regfile B.
    b: u6,
    /// A peripheral write address that means the same on either file.
    periph: u6,

    fn waddr(d: Dst) u6 {
        return switch (d) {
            .nop => W.nop,
            .acc => |n| W.acc0 + @as(u6, n),
            .a, .b, .periph => |n| n,
        };
    }

    const File = enum { any, a, b };

    fn file(d: Dst) File {
        return switch (d) {
            .nop, .acc, .periph => .any,
            .a => .a,
            .b => .b,
        };
    }
};

// Convenience constructors.
pub fn r(n: u3) Src {
    return .{ .acc = n };
}
pub fn ra(n: u6) Src {
    return .{ .a = n };
}
pub fn rb(n: u6) Src {
    return .{ .b = n };
}
pub const unif: Src = .{ .a = R.unif };
pub const vpm_read: Src = .{ .a = R.vpm };
/// Varyings can be read from either file; regfile B leaves regfile A free
/// for the fragment W payload, which only lives on A.
pub const vary: Src = .{ .b = R.vary };
pub const frag_w: Src = .{ .a = R.frag_payload_zw };
pub const frag_z: Src = .{ .b = R.frag_payload_zw };

pub fn wr(n: u3) Dst {
    std.debug.assert(n != 4);
    return .{ .acc = n };
}
pub fn wa(n: u6) Dst {
    return .{ .a = n };
}
pub fn wb(n: u6) Dst {
    return .{ .b = n };
}
pub const vpm_write: Dst = .{ .periph = W.vpm };
pub const vpm_read_setup: Dst = .{ .a = W.vpmvcd_setup };
pub const vpm_write_setup: Dst = .{ .b = W.vpmvcd_setup };
pub const tlb_color_all: Dst = .{ .periph = W.tlb_color_all };
pub const tlb_z: Dst = .{ .periph = W.tlb_z };

/// Encodes an integer in [-16, 15] as a small immediate.
pub fn smallImmInt(i: i5) Src {
    return .{ .imm = @as(u5, @bitCast(i)) };
}

/// Encodes one of the floats the small immediate field can represent:
/// 2^n for n in [-8, 7].
pub fn smallImmFloat(comptime f: f32) Src {
    const bits: u32 = @bitCast(f);
    const exp: i32 = @as(i32, @intCast((bits >> 23) & 0xff)) - 127;
    if (bits & 0x807fffff != 0 or exp < -8 or exp > 7)
        @compileError("float is not representable as a QPU small immediate");
    return .{ .imm = if (exp >= 0) @intCast(32 + exp) else @intCast(48 + exp) };
}

pub const AddInst = struct {
    op: AddOp = .nop,
    dst: Dst = .nop,
    a: Src = .{ .acc = 0 },
    b: Src = .{ .acc = 0 },
    cond: Cond = .always,
};

pub const MulInst = struct {
    op: MulOp = .nop,
    dst: Dst = .nop,
    a: Src = .{ .acc = 0 },
    b: Src = .{ .acc = 0 },
    cond: Cond = .always,
};

pub const Alu = struct {
    add: AddInst = .{},
    mul: MulInst = .{},
    sig: Sig = .none,
    /// Set flags from the add result (or the mul result if add is a nop).
    sf: bool = false,
    pack: Pack = .none,
    unpack: Unpack = .none,
};

pub const EncodeError = error{
    /// Two operands need different addresses on the same register file.
    ReadPortConflict,
    /// The add and mul destinations need the same register file.
    WritePortConflict,
    /// Regfile A packing was requested but the result is not written to A.
    PackNeedsRegfileA,
    /// A small immediate was used without the small immediate signal, or
    /// together with a signal that reuses the field.
    BadSmallImmediate,
    /// The pack and unpack modes need different values of the PM bit.
    PackUnpackConflict,
};

const Ports = struct {
    raddr_a: ?u6 = null,
    raddr_b: ?u6 = null,
    small_imm: bool = false,

    fn mux(p: *Ports, s: Src) EncodeError!Mux {
        switch (s) {
            .acc => |n| return @enumFromInt(n),
            .a => |addr| {
                if (p.raddr_a) |cur| if (cur != addr) return error.ReadPortConflict;
                p.raddr_a = addr;
                return .a;
            },
            .b => |addr| {
                if (p.small_imm) return error.ReadPortConflict;
                if (p.raddr_b) |cur| if (cur != addr) return error.ReadPortConflict;
                p.raddr_b = addr;
                return .b;
            },
            .imm => |v| {
                if (p.raddr_b) |cur| if (!p.small_imm or cur != v) return error.ReadPortConflict;
                p.raddr_b = v;
                p.small_imm = true;
                return .b;
            },
        }
    }
};

fn field(v: u64, comptime shift: u6) u64 {
    return v << shift;
}

/// Encodes an ALU instruction.
pub fn alu(i: Alu) EncodeError!Inst {
    var ports: Ports = .{};
    const add_a = try ports.mux(i.add.a);
    const add_b = try ports.mux(i.add.b);
    const mul_a = try ports.mux(i.mul.a);
    const mul_b = try ports.mux(i.mul.b);

    var sig = i.sig;
    if (ports.small_imm) {
        if (sig != .none and sig != .small_imm) return error.BadSmallImmediate;
        sig = .small_imm;
    } else if (sig == .small_imm) return error.BadSmallImmediate;

    // WS=0: add writes regfile A and mul writes regfile B. WS=1 swaps them.
    const add_file = i.add.dst.file();
    const mul_file = i.mul.dst.file();
    const ws = add_file == .b or mul_file == .a;
    if (ws and (add_file == .a or mul_file == .b)) return error.WritePortConflict;

    var pm = false;
    var pack: u4 = 0;
    switch (i.pack) {
        .none => {},
        .mul => |m| {
            pm = true;
            pack = @intFromEnum(m);
        },
        .regfile_a => |m| {
            // Applies to whichever ALU writes regfile A.
            const a_dst = if (ws) i.mul.dst else i.add.dst;
            if (a_dst != .a) return error.PackNeedsRegfileA;
            pack = @intFromEnum(m);
        },
    }

    var unpack: u3 = 0;
    switch (i.unpack) {
        .none => {},
        .regfile_a => |m| {
            if (pm) return error.PackUnpackConflict;
            unpack = @intFromEnum(m);
        },
        .r4 => |m| {
            if (i.pack == .regfile_a) return error.PackUnpackConflict;
            pm = true;
            unpack = @intFromEnum(m);
        },
    }

    const cond_add: Cond = if (i.add.op == .nop) .never else i.add.cond;
    const cond_mul: Cond = if (i.mul.op == .nop) .never else i.mul.cond;

    return field(@intFromEnum(sig), 60) |
        field(unpack, 57) |
        field(@intFromBool(pm), 56) |
        field(pack, 52) |
        field(@intFromEnum(cond_add), 49) |
        field(@intFromEnum(cond_mul), 46) |
        field(@intFromBool(i.sf), 45) |
        field(@intFromBool(ws), 44) |
        field(i.add.dst.waddr(), 38) |
        field(i.mul.dst.waddr(), 32) |
        field(@intFromEnum(i.mul.op), 29) |
        field(@intFromEnum(i.add.op), 24) |
        field(ports.raddr_a orelse R.nop, 18) |
        field(ports.raddr_b orelse R.nop, 12) |
        field(@intFromEnum(add_a), 9) |
        field(@intFromEnum(add_b), 6) |
        field(@intFromEnum(mul_a), 3) |
        field(@intFromEnum(mul_b), 0);
}

pub const LoadImm = struct {
    add_dst: Dst = .nop,
    mul_dst: Dst = .nop,
    value: u32,
};

/// Encodes a 32-bit immediate load into one or two destinations.
pub fn loadImm(i: LoadImm) EncodeError!Inst {
    const add_file = i.add_dst.file();
    const mul_file = i.mul_dst.file();
    const ws = add_file == .b or mul_file == .a;
    if (ws and (add_file == .a or mul_file == .b)) return error.WritePortConflict;
    const cond_add: Cond = if (i.add_dst == .nop) .never else .always;
    const cond_mul: Cond = if (i.mul_dst == .nop) .never else .always;
    return field(@intFromEnum(Sig.load_imm), 60) |
        field(@intFromEnum(cond_add), 49) |
        field(@intFromEnum(cond_mul), 46) |
        field(@intFromBool(ws), 44) |
        field(i.add_dst.waddr(), 38) |
        field(i.mul_dst.waddr(), 32) |
        i.value;
}

/// A no-op with an optional signal.
pub fn nop(sig: Sig) Inst {
    return alu(.{ .sig = sig }) catch unreachable;
}

/// `dst = src` using the add ALU (encoded as `or dst, src, src`).
pub fn mov(dst: Dst, src: Src) EncodeError!Inst {
    return alu(.{ .add = .{ .op = .@"or", .dst = dst, .a = src, .b = src } });
}

// --- Decoding helpers ---------------------------------------------------------

pub fn getSig(i: Inst) Sig {
    return @enumFromInt(@as(u4, @truncate(i >> 60)));
}
pub fn getWaddrAdd(i: Inst) u6 {
    return @truncate(i >> 38);
}
pub fn getWaddrMul(i: Inst) u6 {
    return @truncate(i >> 32);
}
pub fn getWs(i: Inst) bool {
    return (i >> 44) & 1 != 0;
}
pub fn getRaddrA(i: Inst) u6 {
    return @truncate(i >> 18);
}
pub fn getRaddrB(i: Inst) u6 {
    return @truncate(i >> 12);
}
pub fn getAddOp(i: Inst) AddOp {
    return @enumFromInt(@as(u5, @truncate(i >> 24)));
}
pub fn getMulOp(i: Inst) MulOp {
    return @enumFromInt(@as(u3, @truncate(i >> 29)));
}

fn getMux(i: Inst, comptime shift: u6) Mux {
    return @enumFromInt(@as(u3, @truncate(i >> shift)));
}

/// Whether the instruction reads the given regfile A / B address through
/// one of its ALU inputs.
pub fn readsFile(i: Inst, file: Mux, addr: u6) bool {
    const sig = getSig(i);
    if (sig == .load_imm or sig == .branch) return false;
    if (file == .b and sig == .small_imm) return false;
    const raddr = if (file == .a) getRaddrA(i) else getRaddrB(i);
    if (raddr != addr) return false;
    const add_op = getAddOp(i);
    const mul_op = getMulOp(i);
    if (add_op != .nop and (getMux(i, 9) == file or getMux(i, 6) == file)) return true;
    if (mul_op != .nop and (getMux(i, 3) == file or getMux(i, 0) == file)) return true;
    return false;
}

/// Whether the instruction reads accumulator `n` through one of its ALU
/// inputs.
pub fn readsAccumulator(i: Inst, n: u3) bool {
    const sig = getSig(i);
    if (sig == .load_imm or sig == .branch) return false;
    const mux: Mux = @enumFromInt(n);
    if (getAddOp(i) != .nop and (getMux(i, 9) == mux or getMux(i, 6) == mux)) return true;
    if (getMulOp(i) != .nop and (getMux(i, 3) == mux or getMux(i, 0) == mux)) return true;
    return false;
}

fn readsAnyFile(i: Inst, addr: u6) bool {
    return readsFile(i, .a, addr) or readsFile(i, .b, addr);
}

pub fn writesAddr(i: Inst, addr: u6) bool {
    if (getSig(i) == .branch) return false;
    return getWaddrAdd(i) == addr or getWaddrMul(i) == addr;
}

fn isTlbAccess(i: Inst) bool {
    const sig = getSig(i);
    if (sig == .color_load or sig == .color_load_end or sig == .coverage_load or
        sig == .alpha_mask_load) return true;
    inline for (.{ W.tlb_stencil_setup, W.tlb_z, W.tlb_color_ms, W.tlb_color_all, W.tlb_alpha_mask }) |w|
        if (writesAddr(i, w)) return true;
    return false;
}

// --- Instruction pairing -------------------------------------------------------

fn activeMuxes(i: Inst, buf: *[4]Mux) []const Mux {
    var n: usize = 0;
    if (getAddOp(i) != .nop) {
        buf[n] = getMux(i, 9);
        buf[n + 1] = getMux(i, 6);
        n += 2;
    }
    if (getMulOp(i) != .nop) {
        buf[n] = getMux(i, 3);
        buf[n + 1] = getMux(i, 0);
        n += 2;
    }
    return buf[0..n];
}

fn usesMux(i: Inst, m: Mux) bool {
    var buf: [4]Mux = undefined;
    return std.mem.indexOfScalar(Mux, activeMuxes(i, &buf), m) != null;
}

/// Write addresses whose meaning depends on the register file.
fn fileSpecific(waddr: u6) bool {
    return waddr < 32 or waddr == W.quad_xy or waddr == W.ms_flags or
        waddr == W.vpmvcd_setup or waddr == W.vpm_addr;
}

/// Accesses to the units of which an instruction may only use one: TMU,
/// TLB, SFU, VPM, varyings, setup registers and the like.
fn usesPeripheral(i: Inst) bool {
    for ([_]u6{ getWaddrAdd(i), getWaddrMul(i) }) |w| {
        if (w >= 36 and w != W.acc5 and w != W.nop) return true;
    }
    const sig = getSig(i);
    const addr_a = getRaddrA(i);
    const addr_b = getRaddrB(i);
    if (usesMux(i, .a) and (addr_a == R.vary or addr_a == R.vpm)) return true;
    if (sig != .small_imm and usesMux(i, .b) and (addr_b == R.vary or addr_b == R.vpm)) return true;
    return false;
}

const pm_pack_unpack_mask: u64 = 0xf << 52 | 1 << 56 | 7 << 57;

/// Combines an instruction that only uses the add ALU with one that only
/// uses the mul ALU, if one instruction can encode both. Both must be
/// plain ALU instructions (no signal other than a small immediate).
pub fn merge(x: Inst, y: Inst) ?Inst {
    const x_add = getAddOp(x) != .nop;
    const x_mul = getMulOp(x) != .nop;
    const y_add = getAddOp(y) != .nop;
    const y_mul = getMulOp(y) != .nop;
    const a, const m = if (x_add and !x_mul and y_mul and !y_add)
        .{ x, y }
    else if (y_add and !y_mul and x_mul and !x_add)
        .{ y, x }
    else
        return null;

    const sig_a = getSig(a);
    const sig_m = getSig(m);
    if ((sig_a != .none and sig_a != .small_imm) or (sig_m != .none and sig_m != .small_imm)) return null;
    if (usesPeripheral(a) and usesPeripheral(m)) return null;
    // Flags come from the add result when the add ALU is in use.
    if (m & (1 << 45) != 0) return null;

    // Shared read ports.
    var raddr_a: u64 = R.nop;
    var raddr_b: u64 = R.nop;
    var small_imm = false;
    for ([_]Inst{ a, m }) |i| {
        if (usesMux(i, .a)) {
            if (raddr_a != R.nop and raddr_a != getRaddrA(i)) return null;
            raddr_a = getRaddrA(i);
        }
        if (usesMux(i, .b)) {
            const imm = getSig(i) == .small_imm;
            if (raddr_b != R.nop and (raddr_b != getRaddrB(i) or small_imm != imm)) return null;
            raddr_b = getRaddrB(i);
            small_imm = imm;
        }
    }

    // Pack and unpack share the PM bit and fields: at most one instruction
    // may use them, and an unpack must not affect the other's inputs.
    const pa = a & pm_pack_unpack_mask;
    const pmm = m & pm_pack_unpack_mask;
    if (pa != 0 and pmm != 0) return null;
    const packer = if (pa != 0) a else m;
    const other = if (pa != 0) m else a;
    if (pa | pmm != 0) {
        const unpack = (packer >> 57) & 7;
        const pm = (packer >> 56) & 1 != 0;
        if (unpack != 0) {
            if (!pm and usesMux(other, .a)) return null;
            if (pm and usesMux(other, .r4)) return null;
        }
    }

    // One write swap bit for both destinations.
    const a_needs: ?bool = if (fileSpecific(getWaddrAdd(a))) getWs(a) else null; // true: add writes B
    const m_needs: ?bool = if (fileSpecific(getWaddrMul(m))) getWs(m) else null; // true: mul writes A
    var ws = false;
    if (a_needs) |v| ws = v;
    if (m_needs) |v| {
        if (a_needs != null and a_needs.? != v) return null;
        ws = v;
    }
    // A regfile A pack applies to whichever result goes to regfile A.
    if (pa | pmm != 0 and (packer >> 56) & 1 == 0 and (packer >> 52) & 0xf != 0) {
        const packs_add = packer == a;
        if (packs_add == ws) return null; // the packed result would go to B
    }

    const add_fields: u64 = 0b111 << 49 | 0b111111 << 38 | 0b11111 << 24 | 0b111 << 9 | 0b111 << 6 | 1 << 45;
    const mul_fields: u64 = 0b111 << 46 | 0b111111 << 32 | 0b111 << 29 | 0b111 << 3 | 0b111;
    const sig: Sig = if (small_imm) .small_imm else .none;
    return field(@intFromEnum(sig), 60) |
        (pa | pmm) |
        field(@intFromBool(ws), 44) |
        (a & add_fields) |
        (m & mul_fields) |
        field(raddr_a, 18) |
        field(raddr_b, 12);
}

test "merge pairs an add and a mul" {
    const add = try alu(.{ .add = .{ .op = .fadd, .dst = wr(0), .a = r(1), .b = ra(5) } });
    const mul = try alu(.{ .mul = .{ .op = .fmul, .dst = wr(2), .a = r(1), .b = rb(7) } });
    const both = try alu(.{
        .add = .{ .op = .fadd, .dst = wr(0), .a = r(1), .b = ra(5) },
        .mul = .{ .op = .fmul, .dst = wr(2), .a = r(1), .b = rb(7) },
    });
    try testing.expectEqual(both, merge(add, mul).?);
    try testing.expectEqual(both, merge(mul, add).?);
}

test "merge rejects conflicts" {
    const add_a5 = try alu(.{ .add = .{ .op = .fadd, .dst = wr(0), .a = r(1), .b = ra(5) } });
    const mul_a6 = try alu(.{ .mul = .{ .op = .fmul, .dst = wr(2), .a = r(1), .b = ra(6) } });
    try testing.expectEqual(@as(?Inst, null), merge(add_a5, mul_a6)); // read port
    const add_wa = try mov(wa(1), r(0));
    const mul_wa = try alu(.{ .mul = .{ .op = .fmul, .dst = wa(2), .a = r(1), .b = r(1) } });
    try testing.expectEqual(@as(?Inst, null), merge(add_wa, mul_wa)); // both write regfile A
    const add_imm = try alu(.{ .add = .{ .op = .fadd, .dst = wr(0), .a = r(1), .b = smallImmFloat(1.0) } });
    const mul_imm = try alu(.{ .mul = .{ .op = .fmul, .dst = wr(2), .a = r(1), .b = smallImmFloat(2.0) } });
    try testing.expectEqual(@as(?Inst, null), merge(add_imm, mul_imm)); // different immediates
    const vpm = try mov(vpm_write, r(0));
    const sfu = try alu(.{ .mul = .{ .op = .fmul, .dst = .{ .periph = W.sfu_recip }, .a = r(1), .b = r(1) } });
    try testing.expectEqual(@as(?Inst, null), merge(vpm, sfu)); // two peripherals
    const unpack = try alu(.{ .add = .{ .op = .fmax, .dst = wr(0), .a = ra(3), .b = ra(3) }, .unpack = .{ .regfile_a = .@"8a" } });
    const reads_a = try alu(.{ .mul = .{ .op = .fmul, .dst = wr(1), .a = ra(3), .b = r(2) } });
    try testing.expectEqual(@as(?Inst, null), merge(unpack, reads_a)); // unpack would apply to both
}

test "merge picks the write swap bit" {
    const add_wb = try mov(wb(4), r(0));
    const mul_wa = try alu(.{ .mul = .{ .op = .fmul, .dst = wa(2), .a = r(1), .b = r(1) } });
    const merged = merge(add_wb, mul_wa).?;
    try testing.expect(getWs(merged));
    const mul_acc = try alu(.{ .mul = .{ .op = .fmul, .dst = wr(1), .a = r(1), .b = r(1) } });
    try testing.expect(getWs(merge(add_wb, mul_acc).?));
}

// --- Programs -------------------------------------------------------------------

pub const Stage = enum { vertex, coordinate, fragment };

pub const ValidationError = error{
    MissingProgramEnd,
    ReadAfterWriteHazard,
    FixedFunctionInThreadEnd,
    PhysicalWriteInThreadEnd,
    ScoreboardWaitTooEarly,
};

pub const Diagnostic = struct {
    ip: usize = 0,
};

/// Checks a program against the instruction restrictions in section 3 of the
/// reference guide that are easy to get wrong when writing QPU code by hand.
/// The kernel validates memory safety on its own; this catches programs the
/// kernel would accept but the hardware would execute incorrectly.
pub fn validate(code: []const Inst, stage: Stage, diag: ?*Diagnostic) ValidationError!void {
    var d: Diagnostic = .{};
    defer if (diag) |p| {
        p.* = d;
    };

    // "An instruction must not read from a location in physical regfile A or
    // B that was written to by the previous instruction."
    for (code[0..code.len -| 1], code[1..], 1..) |prev, cur, ip| {
        d.ip = ip;
        if (getSig(prev) == .branch) continue;
        const waddr_add = getWaddrAdd(prev);
        const waddr_mul = getWaddrMul(prev);
        const ws = getWs(prev);
        const wa_addr = if (ws) waddr_mul else waddr_add;
        const wb_addr = if (ws) waddr_add else waddr_mul;
        if ((wa_addr < 32 and readsFile(cur, .a, wa_addr)) or
            (wb_addr < 32 and readsFile(cur, .b, wb_addr)))
            return error.ReadAfterWriteHazard;
    }

    // "A scoreboard wait must not occur in the first two instructions of a
    // fragment shader."
    if (stage == .fragment) {
        for (code[0..@min(2, code.len)], 0..) |i, ip| {
            d.ip = ip;
            if (isTlbAccess(i) or getSig(i) == .wait_scoreboard)
                return error.ScoreboardWaitTooEarly;
        }
    }

    for (code, 0..) |i, ip| {
        if (getSig(i) != .prog_end) continue;
        d.ip = ip;
        if (ip + 2 >= code.len) return error.MissingProgramEnd;
        // "The Thread End instruction must not write to either physical
        // regfile A or B."
        if (getWaddrAdd(i) < 32 or getWaddrMul(i) < 32) return error.PhysicalWriteInThreadEnd;
        // "The last three instructions of any program (Thread End plus the
        // following two delay-slot instructions) must not do varyings read,
        // uniforms read or any kind of VPM, VDR, or VDW read or write."
        for (code[ip .. ip + 3], ip..) |t, tip| {
            d.ip = tip;
            if (writesAddr(t, W.vpm) or writesAddr(t, W.vpmvcd_setup) or
                readsAnyFile(t, R.vary) or readsAnyFile(t, R.unif) or readsAnyFile(t, R.vpm))
                return error.FixedFunctionInThreadEnd;
        }
        return;
    }
    d.ip = code.len;
    return error.MissingProgramEnd;
}

/// A fixed-capacity buffer of QPU instructions.
pub fn Program(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        insts: [capacity]Inst = undefined,
        len: usize = 0,

        pub fn emit(p: *Self, i: Inst) void {
            p.insts[p.len] = i;
            p.len += 1;
        }

        /// Appends the thread end sequence: a program end signal followed by
        /// its two delay slots. Fragment shaders also release the tile buffer
        /// scoreboard in the final slot.
        pub fn end(p: *Self, stage: Stage) void {
            p.emit(nop(.prog_end));
            p.emit(nop(.none));
            p.emit(nop(if (stage == .fragment) .scoreboard_unlock else .none));
        }

        pub fn code(p: *const Self) []const Inst {
            return p.insts[0..p.len];
        }
    };
}

// --- Disassembly -----------------------------------------------------------------

fn srcName(buf: []u8, i: Inst, mux: Mux) []const u8 {
    return switch (mux) {
        .r0, .r1, .r2, .r3, .r4, .r5 => std.fmt.bufPrint(buf, "r{d}", .{@intFromEnum(mux)}) catch "?",
        .a => regName(buf, 'a', getRaddrA(i)),
        .b => if (getSig(i) == .small_imm)
            std.fmt.bufPrint(buf, "imm{d}", .{getRaddrB(i)}) catch "?"
        else
            regName(buf, 'b', getRaddrB(i)),
    };
}

fn regName(buf: []u8, file: u8, addr: u6) []const u8 {
    if (addr < 32) {
        if (addr == R.frag_payload_zw) return if (file == 'a') "frag_w" else "frag_z";
        return std.fmt.bufPrint(buf, "r{c}{d}", .{ file, addr }) catch "?";
    }
    return switch (addr) {
        R.unif => "unif",
        R.vary => "vary",
        R.elem_qpu => "elem",
        R.nop => "-",
        R.xy_pixel_coord => if (file == 'a') "x_coord" else "y_coord",
        R.vpm => "vpm",
        else => std.fmt.bufPrint(buf, "r{c}?{d}", .{ file, addr }) catch "?",
    };
}

fn dstName(buf: []u8, addr: u6, file: u8) []const u8 {
    if (addr < 32) return std.fmt.bufPrint(buf, "r{c}{d}", .{ file, addr }) catch "?";
    return switch (addr) {
        32...35 => std.fmt.bufPrint(buf, "r{d}", .{addr - 32}) catch "?",
        W.acc5 => "r5",
        W.nop => "-",
        W.uniforms_address => "unif_addr",
        W.tlb_z => "tlb_z",
        W.tlb_color_all => "tlb_c",
        W.tlb_color_ms => "tlb_c_ms",
        W.vpm => "vpm",
        W.vpmvcd_setup => if (file == 'a') "vr_setup" else "vw_setup",
        W.sfu_recip => "sfu_recip",
        W.sfu_recipsqrt => "sfu_rsqrt",
        W.sfu_exp => "sfu_exp",
        W.sfu_log => "sfu_log",
        W.tmu0_s => "tmu0_s",
        W.tmu0_t => "tmu0_t",
        W.tmu0_r => "tmu0_r",
        W.tmu0_b => "tmu0_b",
        W.tmu1_s => "tmu1_s",
        W.tmu1_t => "tmu1_t",
        else => std.fmt.bufPrint(buf, "w{c}?{d}", .{ file, addr }) catch "?",
    };
}

/// Formats one instruction in a Mesa-like assembly syntax for debugging.
pub fn disassemble(buf: []u8, i: Inst) []const u8 {
    var b0: [16]u8 = undefined;
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    var b4: [16]u8 = undefined;
    var b5: [16]u8 = undefined;
    const sig = getSig(i);
    const ws = getWs(i);
    const add_file: u8 = if (ws) 'b' else 'a';
    const mul_file: u8 = if (ws) 'a' else 'b';
    const pack: u4 = @truncate(i >> 52);
    const pm = (i >> 56) & 1 != 0;
    const pack_s: []const u8 = if (pack == 0) "" else if (pm) ".pm" else ".pack";

    if (sig == .load_imm) {
        return std.fmt.bufPrint(buf, "load_imm {s}, {s}, 0x{x:0>8}", .{
            dstName(&b0, getWaddrAdd(i), add_file),
            dstName(&b1, getWaddrMul(i), mul_file),
            @as(u32, @truncate(i)),
        }) catch buf;
    }
    if (sig == .branch) {
        return std.fmt.bufPrint(buf, "branch 0x{x:0>16}", .{i}) catch buf;
    }

    const sig_s: []const u8 = switch (sig) {
        .none, .small_imm => "",
        else => @tagName(sig),
    };
    const unpack: UnpackMode = @enumFromInt(@as(u3, @truncate(i >> 57)));
    const unpack_s: []const u8 = if (unpack == .none) "" else if (pm) " unpack.r4" else " unpack.a";
    return std.fmt.bufPrint(buf, "{s} {s}{s}, {s}, {s} ; {s} {s}, {s}, {s} {s}{s}{s}{s}", .{
        @tagName(getAddOp(i)),
        dstName(&b0, getWaddrAdd(i), add_file),
        if (!ws and !pm) pack_s else "",
        srcName(&b1, i, getMux(i, 9)),
        srcName(&b2, i, getMux(i, 6)),
        @tagName(getMulOp(i)),
        dstName(&b3, getWaddrMul(i), mul_file),
        srcName(&b4, i, getMux(i, 3)),
        srcName(&b5, i, getMux(i, 0)),
        if (pm or ws) pack_s else "",
        sig_s,
        unpack_s,
        if (unpack == .none) "" else @tagName(unpack),
    }) catch buf;
}

// --- Tests -----------------------------------------------------------------------

const testing = std.testing;

test "nop matches the canonical encoding" {
    // Mesa's qpu_NOP(): add/mul nop, waddr/raddr nop, signal none.
    try testing.expectEqual(@as(Inst, 0x100009e7_009e7000), nop(.none));
    try testing.expectEqual(@as(Inst, 0x300009e7_009e7000), nop(.prog_end));
}

test "mov from VPM" {
    // or r0, vpm, vpm (as emitted by Mesa for a VPM read).
    // Mesa's dumps print this as "0x15c27d80, 0x10020827" (low word first).
    try testing.expectEqual(@as(Inst, 0x10020827_15c27d80), try mov(wr(0), vpm_read));
}

test "load immediate into VPM write setup selects regfile B" {
    const i = try loadImm(.{ .add_dst = vpm_write_setup, .value = 0x1a00 });
    try testing.expect(getWs(i));
    try testing.expectEqual(@as(u6, W.vpmvcd_setup), getWaddrAdd(i));
    try testing.expectEqual(@as(u32, 0x1a00), @as(u32, @truncate(i)));
}

test "read port conflicts are rejected" {
    try testing.expectError(error.ReadPortConflict, alu(.{
        .mul = .{ .op = .fmul, .dst = wr(0), .a = ra(1), .b = ra(2) },
    }));
    try testing.expectError(error.ReadPortConflict, alu(.{
        .mul = .{ .op = .fmul, .dst = wr(0), .a = rb(1), .b = smallImmFloat(1.0) },
    }));
    // The same register on both inputs only uses one port.
    _ = try alu(.{ .mul = .{ .op = .fmul, .dst = wr(0), .a = ra(1), .b = ra(1) } });
}

test "small immediates" {
    try testing.expectEqual(@as(u6, 32), smallImmFloat(1.0).imm);
    try testing.expectEqual(@as(u6, 39), smallImmFloat(128.0).imm);
    try testing.expectEqual(@as(u6, 47), smallImmFloat(0.5).imm);
    try testing.expectEqual(@as(u6, 40), smallImmFloat(1.0 / 256.0).imm);
    try testing.expectEqual(@as(u6, 31), smallImmInt(-1).imm);
    const i = try alu(.{ .mul = .{ .op = .fmul, .dst = wr(1), .a = r(0), .b = smallImmFloat(1.0) } });
    try testing.expectEqual(Sig.small_imm, getSig(i));
    try testing.expectEqual(@as(u6, 32), getRaddrB(i));
}

test "regfile A pack requires an A destination" {
    try testing.expectError(error.PackNeedsRegfileA, alu(.{
        .add = .{ .op = .ftoi, .dst = wr(0), .a = r(0), .b = r(0) },
        .pack = .{ .regfile_a = .@"16a" },
    }));
    const i = try alu(.{
        .add = .{ .op = .ftoi, .dst = wa(1), .a = r(0), .b = r(0) },
        .pack = .{ .regfile_a = .@"16a" },
    });
    try testing.expectEqual(@as(u64, 1), (i >> 52) & 0xf);
}

test "write port conflicts are rejected" {
    try testing.expectError(error.WritePortConflict, alu(.{
        .add = .{ .op = .fadd, .dst = wa(0), .a = r(0), .b = r(1) },
        .mul = .{ .op = .fmul, .dst = wa(1), .a = r(0), .b = r(1) },
    }));
    // Add to B and mul to A is expressible with the write swap bit.
    const i = try alu(.{
        .add = .{ .op = .fadd, .dst = wb(0), .a = r(0), .b = r(1) },
        .mul = .{ .op = .fmul, .dst = wa(1), .a = r(0), .b = r(1) },
    });
    try testing.expect(getWs(i));
}

test "validator catches read-after-write on physical registers" {
    const code = [_]Inst{
        try mov(wa(3), r(0)),
        try mov(wr(1), ra(3)),
        nop(.prog_end),
        nop(.none),
        nop(.none),
    };
    var diag: Diagnostic = .{};
    try testing.expectError(error.ReadAfterWriteHazard, validate(&code, .vertex, &diag));
    try testing.expectEqual(@as(usize, 1), diag.ip);
}

test "validator catches VPM access in thread end" {
    const code = [_]Inst{
        try mov(wr(1), r(0)),
        nop(.prog_end),
        try mov(vpm_write, r(0)),
        nop(.none),
    };
    try testing.expectError(error.FixedFunctionInThreadEnd, validate(&code, .vertex, null));
}
