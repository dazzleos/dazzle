//! VideoCore VI (V3D 4.2) and VideoCore VII (V3D 7.1) 64-bit QPU instruction
//! encoding.
//!
//! Mirrors Mesa's `src/broadcom/qpu/qpu_instr.h` and `qpu_pack.c` for V3D 4.2
//! (`devinfo->ver == 42`) and V3D 7.1 (`devinfo->ver == 71`).

const std = @import("std");

pub const Inst = u64;

pub const EncodeError = error{
    InvalidSignal,
    InvalidFlags,
    InvalidOpcode,
    InvalidPack,
};

pub const Sig = packed struct(u17) {
    thrsw: bool = false,
    ldunif: bool = false,
    ldunifa: bool = false,
    ldunifrf: bool = false,
    ldunifarf: bool = false,
    ldtmu: bool = false,
    ldvary: bool = false,
    ldvpm: bool = false,
    ldtlb: bool = false,
    ldtlbu: bool = false,
    ucb: bool = false,
    rotate: bool = false,
    wrtmuc: bool = false,
    small_imm_a: bool = false,
    small_imm_b: bool = false,
    small_imm_c: bool = false,
    small_imm_d: bool = false,

    pub fn writesAddress(sig: Sig) bool {
        return sig.ldunifrf or sig.ldunifarf or sig.ldtmu or sig.ldvary or
            sig.ldvpm or sig.ldtlb or sig.ldtlbu;
    }
};

const v3d42_sig_map = [32]?Sig{
    .{}, // 0
    .{ .thrsw = true }, // 1
    .{ .ldunif = true }, // 2
    .{ .thrsw = true, .ldunif = true }, // 3
    .{ .ldtmu = true }, // 4
    .{ .thrsw = true, .ldtmu = true }, // 5
    .{ .ldtmu = true, .ldunif = true }, // 6
    .{ .thrsw = true, .ldtmu = true, .ldunif = true }, // 7
    .{ .ldvary = true }, // 8
    .{ .thrsw = true, .ldvary = true }, // 9
    .{ .ldvary = true, .ldunif = true }, // 10
    .{ .thrsw = true, .ldvary = true, .ldunif = true }, // 11
    .{ .ldunifrf = true }, // 12
    .{ .thrsw = true, .ldunifrf = true }, // 13
    .{ .small_imm_b = true, .ldvary = true }, // 14
    .{ .small_imm_b = true }, // 15
    .{ .ldtlb = true }, // 16
    .{ .ldtlbu = true }, // 17
    .{ .wrtmuc = true }, // 18
    .{ .thrsw = true, .wrtmuc = true }, // 19
    .{ .ldvary = true, .wrtmuc = true }, // 20
    .{ .thrsw = true, .ldvary = true, .wrtmuc = true }, // 21
    .{ .ucb = true }, // 22
    .{ .rotate = true }, // 23
    .{ .ldunifa = true }, // 24
    .{ .ldunifarf = true }, // 25
    null, // 26
    null, // 27
    null, // 28
    null, // 29
    null, // 30
    .{ .small_imm_b = true, .ldtmu = true }, // 31
};

const v3d71_sig_map = [32]?Sig{
    .{}, // 0
    .{ .thrsw = true }, // 1
    .{ .ldunif = true }, // 2
    .{ .thrsw = true, .ldunif = true }, // 3
    .{ .ldtmu = true }, // 4
    .{ .thrsw = true, .ldtmu = true }, // 5
    .{ .ldtmu = true, .ldunif = true }, // 6
    .{ .thrsw = true, .ldtmu = true, .ldunif = true }, // 7
    .{ .ldvary = true }, // 8
    .{ .thrsw = true, .ldvary = true }, // 9
    .{ .ldvary = true, .ldunif = true }, // 10
    .{ .thrsw = true, .ldvary = true, .ldunif = true }, // 11
    .{ .ldunifrf = true }, // 12
    .{ .thrsw = true, .ldunifrf = true }, // 13
    .{ .small_imm_a = true }, // 14
    .{ .small_imm_b = true }, // 15
    .{ .ldtlb = true }, // 16
    .{ .ldtlbu = true }, // 17
    .{ .wrtmuc = true }, // 18
    .{ .thrsw = true, .wrtmuc = true }, // 19
    .{ .ldvary = true, .wrtmuc = true }, // 20
    .{ .thrsw = true, .ldvary = true, .wrtmuc = true }, // 21
    .{ .ucb = true }, // 22
    .{ .rotate = true }, // 23
    .{ .ldunifa = true }, // 24
    .{ .ldunifarf = true }, // 25
    null, // 26
    null, // 27
    null, // 28
    null, // 29
    .{ .small_imm_c = true }, // 30
    .{ .small_imm_d = true }, // 31
};

pub fn packSig(sig: Sig) ?u5 {
    for (v3d42_sig_map, 0..) |entry, i| {
        if (entry) |e| if (e == sig) return @intCast(i);
    }
    return null;
}

pub fn packSig71(sig: Sig) ?u5 {
    for (v3d71_sig_map, 0..) |entry, i| {
        if (entry) |e| if (e == sig) return @intCast(i);
    }
    return null;
}

pub const Cond = enum(u3) {
    none = 0,
    ifa = 1,
    ifb = 2,
    ifna = 3,
    ifnb = 4,
};

pub const Pf = enum(u2) {
    none = 0,
    pushz = 1,
    pushn = 2,
    pushc = 3,
};

pub const Uf = enum(u4) {
    none = 0,
    andz = 1,
    andnz = 2,
    nornz = 3,
    norz = 4,
    andn = 5,
    andnn = 6,
    nornn = 7,
    norn = 8,
    andc = 9,
    andnc = 10,
    nornc = 11,
    norc = 12,
};

pub const Flags = struct {
    ac: Cond = .none,
    mc: Cond = .none,
    apf: Pf = .none,
    mpf: Pf = .none,
    auf: Uf = .none,
    muf: Uf = .none,
};

pub fn packFlags(cond: Flags) ?u7 {
    const AC: u8 = 1 << 0;
    const MC: u8 = 1 << 1;
    const APF: u8 = 1 << 2;
    const MPF: u8 = 1 << 3;
    const AUF: u8 = 1 << 4;
    const MUF: u8 = 1 << 5;

    const Entry = struct { present: u8, bits: u7 };
    const table = [_]Entry{
        .{ .present = 0, .bits = 0 },
        .{ .present = APF, .bits = 0 },
        .{ .present = AUF, .bits = 0 },
        .{ .present = MPF, .bits = 1 << 4 },
        .{ .present = MUF, .bits = 1 << 4 },
        .{ .present = AC, .bits = 1 << 5 },
        .{ .present = AC | MPF, .bits = 1 << 5 },
        .{ .present = MC, .bits = (1 << 5) | (1 << 4) },
        .{ .present = MC | APF, .bits = (1 << 5) | (1 << 4) },
        .{ .present = MC | AC, .bits = 1 << 6 },
        .{ .present = MC | AUF, .bits = 1 << 6 },
    };

    var present: u8 = 0;
    if (cond.ac != .none) present |= AC;
    if (cond.mc != .none) present |= MC;
    if (cond.apf != .none) present |= APF;
    if (cond.mpf != .none) present |= MPF;
    if (cond.auf != .none) present |= AUF;
    if (cond.muf != .none) present |= MUF;

    for (table) |row| {
        if (row.present != present) continue;
        var out: u7 = row.bits;
        out |= @intFromEnum(cond.apf);
        out |= @intFromEnum(cond.mpf);
        if (present & AUF != 0) out |= @as(u7, @intFromEnum(cond.auf) - @intFromEnum(Uf.andz) + 4);
        if (present & MUF != 0) out |= @as(u7, @intFromEnum(cond.muf) - @intFromEnum(Uf.andz) + 4);
        if (present & AC != 0) {
            const c: u7 = @intFromEnum(cond.ac) - @intFromEnum(Cond.ifa);
            out |= if (out & (1 << 6) != 0) c else c << 2;
        }
        if (present & MC != 0) {
            const c: u7 = @intFromEnum(cond.mc) - @intFromEnum(Cond.ifa);
            out |= if (out & (1 << 6) != 0) c << 4 else c << 2;
        }
        return out;
    }
    return null;
}

/// Magic write addresses (`waddr` when `magic_write` is true, or `sig_addr`
/// when `sig_magic` is true).
pub const W = struct {
    pub const r0: u6 = 0;
    pub const r1: u6 = 1;
    pub const r2: u6 = 2;
    pub const r3: u6 = 3;
    pub const r4: u6 = 4;
    pub const r5: u6 = 5;
    pub const nop: u6 = 6;
    pub const tlb: u6 = 7;
    pub const tlbu: u6 = 8;
    pub const unifa: u6 = 9;
    pub const tmul: u6 = 10;
    pub const tmud: u6 = 11;
    pub const tmua: u6 = 12;
    pub const tmuau: u6 = 13;
    pub const vpm: u6 = 14;
    pub const vpmu: u6 = 15;
    pub const sync: u6 = 16;
    pub const syncu: u6 = 17;
    pub const syncb: u6 = 18;
    pub const recip: u6 = 19;
    pub const rsqrt: u6 = 20;
    pub const exp: u6 = 21;
    pub const log: u6 = 22;
    pub const sin: u6 = 23;
    pub const rsqrt2: u6 = 24;
    pub const tmuc: u6 = 32;
    pub const tmus: u6 = 33;
    pub const tmut: u6 = 34;
    pub const tmur: u6 = 35;
    pub const tmui: u6 = 36;
    pub const tmub: u6 = 37;
    pub const tmudref: u6 = 38;
    pub const tmuoff: u6 = 39;
    pub const tmuscm: u6 = 40;
    pub const tmusf: u6 = 41;
    pub const tmuslod: u6 = 42;
    pub const r5rep: u6 = 55;
};

pub const Mux = enum(u3) {
    r0 = 0,
    r1 = 1,
    r2 = 2,
    r3 = 3,
    r4 = 4,
    r5 = 5,
    a = 6,
    b = 7,
};

pub const OutputPack = enum(u2) {
    none = 0,
    l = 1,
    h = 2,
};

pub const InputUnpack = enum {
    none,
    abs,
    l,
    h,
    replicate_32f_16,
    replicate_l_16,
    replicate_h_16,
    swap_16,

    fn packFloat32(u: InputUnpack) ?u2 {
        return switch (u) {
            .abs => 0,
            .none => 1,
            .l => 2,
            .h => 3,
            else => null,
        };
    }

    fn packFloat16(u: InputUnpack) ?u3 {
        return switch (u) {
            .none => 0,
            .replicate_32f_16 => 1,
            .replicate_l_16 => 2,
            .replicate_h_16 => 3,
            .swap_16 => 4,
            else => null,
        };
    }
};

pub const Input = struct {
    mux: Mux = .r0,
    unpack: InputUnpack = .none,
};

pub const Input71 = struct {
    raddr: u6 = 0,
    imm: bool = false,
    unpack: InputUnpack = .none,

    pub fn rf(addr: u6) Input71 {
        return .{ .raddr = addr };
    }

    pub fn immVal(index: u6) Input71 {
        return .{ .raddr = index, .imm = true };
    }
};

pub const Dst = struct {
    waddr: u6 = W.nop,
    magic: bool = true,

    pub const nop: Dst = .{ .waddr = W.nop, .magic = true };

    pub fn rf(addr: u6) Dst {
        return .{ .waddr = addr, .magic = false };
    }

    pub fn r(acc: u3) Dst {
        std.debug.assert(acc <= 5);
        return .{ .waddr = acc, .magic = true };
    }

    pub fn magicAddr(waddr: u6) Dst {
        return .{ .waddr = waddr, .magic = true };
    }
};

pub const AddOp = enum {
    fadd,
    faddnf,
    vfpack,
    add,
    sub,
    fsub,
    min,
    max,
    umin,
    umax,
    shl,
    shr,
    asr,
    ror,
    fmin,
    fmax,
    vfmin,
    @"and",
    @"or",
    xor,
    vadd,
    vsub,
    not,
    neg,
    flapush,
    flbpush,
    flpop,
    recip,
    setmsf,
    setrevf,
    nop,
    tidx,
    eidx,
    lr,
    vfla,
    vflna,
    vflb,
    vflnb,
    fxcd,
    xcd,
    fycd,
    ycd,
    msf,
    revf,
    iid,
    sampid,
    barrierid,
    tmuwt,
    vpmwt,
    flafirst,
    flnafirst,
    ldvpmv_in,
    ldvpmv_out,
    ldvpmd_in,
    ldvpmd_out,
    ldvpmp,
    rsqrt,
    exp,
    log,
    sin,
    rsqrt2,
    ldvpmg_in,
    ldvpmg_out,
    fcmp,
    vfmax,
    fround,
    ftoin,
    ftrunc,
    ftoiz,
    ffloor,
    ftouz,
    fceil,
    ftoc,
    fdx,
    fdy,
    stvpmv,
    stvpmd,
    stvpmp,
    itof,
    clz,
    utof,
    mov,

    pub fn numSrc(op: AddOp) u2 {
        return switch (op) {
            .nop, .tidx, .eidx, .lr, .vfla, .vflna, .vflb, .vflnb, .fxcd, .xcd, .fycd, .ycd, .msf, .revf, .iid, .sampid, .barrierid, .tmuwt, .vpmwt, .flafirst, .flnafirst => 0,
            .not, .neg, .flapush, .flbpush, .flpop, .recip, .setmsf, .setrevf, .ldvpmv_in, .ldvpmv_out, .ldvpmd_in, .ldvpmd_out, .ldvpmp, .rsqrt, .exp, .log, .sin, .rsqrt2, .fround, .ftoin, .ftrunc, .ftoiz, .ffloor, .ftouz, .fceil, .ftoc, .fdx, .fdy, .itof, .clz, .utof, .mov => 1,
            else => 2,
        };
    }

    fn desc(op: AddOp) struct { opcode: u8, mux_b: u3 = 0, mux_a: u3 = 0 } {
        return switch (op) {
            .fadd, .faddnf => .{ .opcode = 0 },
            .vfpack => .{ .opcode = 53 },
            .add => .{ .opcode = 56 },
            .sub => .{ .opcode = 60 },
            .fsub => .{ .opcode = 64 },
            .min => .{ .opcode = 120 },
            .max => .{ .opcode = 121 },
            .umin => .{ .opcode = 122 },
            .umax => .{ .opcode = 123 },
            .shl => .{ .opcode = 124 },
            .shr => .{ .opcode = 125 },
            .asr => .{ .opcode = 126 },
            .ror => .{ .opcode = 127 },
            .fmin, .fmax => .{ .opcode = 128 },
            .vfmin => .{ .opcode = 176 },
            .@"and" => .{ .opcode = 181 },
            .@"or" => .{ .opcode = 182 },
            .xor => .{ .opcode = 183 },
            .vadd => .{ .opcode = 184 },
            .vsub => .{ .opcode = 185 },
            .not => .{ .opcode = 186, .mux_b = 0 },
            .neg => .{ .opcode = 186, .mux_b = 1 },
            .flapush => .{ .opcode = 186, .mux_b = 2 },
            .flbpush => .{ .opcode = 186, .mux_b = 3 },
            .flpop => .{ .opcode = 186, .mux_b = 4 },
            .recip => .{ .opcode = 186, .mux_b = 5 },
            .setmsf => .{ .opcode = 186, .mux_b = 6 },
            .setrevf => .{ .opcode = 186, .mux_b = 7 },
            .nop => .{ .opcode = 187, .mux_b = 0, .mux_a = 0 },
            .tidx => .{ .opcode = 187, .mux_b = 0, .mux_a = 1 },
            .eidx => .{ .opcode = 187, .mux_b = 0, .mux_a = 2 },
            .lr => .{ .opcode = 187, .mux_b = 0, .mux_a = 3 },
            .vfla => .{ .opcode = 187, .mux_b = 0, .mux_a = 4 },
            .vflna => .{ .opcode = 187, .mux_b = 0, .mux_a = 5 },
            .vflb => .{ .opcode = 187, .mux_b = 0, .mux_a = 6 },
            .vflnb => .{ .opcode = 187, .mux_b = 0, .mux_a = 7 },
            .fxcd => .{ .opcode = 187, .mux_b = 1, .mux_a = 0 },
            .xcd => .{ .opcode = 187, .mux_b = 1, .mux_a = 3 },
            .fycd => .{ .opcode = 187, .mux_b = 1, .mux_a = 4 },
            .ycd => .{ .opcode = 187, .mux_b = 1, .mux_a = 7 },
            .msf => .{ .opcode = 187, .mux_b = 2, .mux_a = 0 },
            .revf => .{ .opcode = 187, .mux_b = 2, .mux_a = 1 },
            .iid => .{ .opcode = 187, .mux_b = 2, .mux_a = 2 },
            .sampid => .{ .opcode = 187, .mux_b = 2, .mux_a = 3 },
            .barrierid => .{ .opcode = 187, .mux_b = 2, .mux_a = 4 },
            .tmuwt => .{ .opcode = 187, .mux_b = 2, .mux_a = 5 },
            .vpmwt => .{ .opcode = 187, .mux_b = 2, .mux_a = 6 },
            .flafirst => .{ .opcode = 187, .mux_b = 2, .mux_a = 7 },
            .flnafirst => .{ .opcode = 187, .mux_b = 3, .mux_a = 0 },
            .ldvpmv_in, .ldvpmv_out => .{ .opcode = 188, .mux_b = 0 },
            .ldvpmd_in, .ldvpmd_out => .{ .opcode = 188, .mux_b = 1 },
            .ldvpmp => .{ .opcode = 188, .mux_b = 2 },
            .rsqrt => .{ .opcode = 188, .mux_b = 3 },
            .exp => .{ .opcode = 188, .mux_b = 4 },
            .log => .{ .opcode = 188, .mux_b = 5 },
            .sin => .{ .opcode = 188, .mux_b = 6 },
            .rsqrt2 => .{ .opcode = 188, .mux_b = 7 },
            .ldvpmg_in, .ldvpmg_out => .{ .opcode = 189 },
            .fcmp => .{ .opcode = 192 },
            .vfmax => .{ .opcode = 240 },
            .fround => .{ .opcode = 245, .mux_b = 0 },
            .ftoin => .{ .opcode = 245, .mux_b = 3 },
            .ftrunc => .{ .opcode = 245, .mux_b = 4 },
            .ftoiz => .{ .opcode = 245, .mux_b = 7 },
            .ffloor => .{ .opcode = 246, .mux_b = 0 },
            .ftouz => .{ .opcode = 246, .mux_b = 3 },
            .fceil => .{ .opcode = 246, .mux_b = 4 },
            .ftoc => .{ .opcode = 246, .mux_b = 7 },
            .fdx => .{ .opcode = 247, .mux_b = 0 },
            .fdy => .{ .opcode = 247, .mux_b = 4 },
            .stvpmv, .stvpmd, .stvpmp => .{ .opcode = 248 },
            .itof => .{ .opcode = 252, .mux_b = 0 },
            .clz => .{ .opcode = 252, .mux_b = 3 },
            .utof => .{ .opcode = 252, .mux_b = 4 },
            .mov => .{ .opcode = 249, .mux_b = 0 },
        };
    }

    fn desc71(op: AddOp) struct { opcode: u8, raddr_b: u6 = 0, raddr_a: u6 = 0 } {
        return switch (op) {
            .fadd, .faddnf => .{ .opcode = 0 },
            .vfpack => .{ .opcode = 53 },
            .add => .{ .opcode = 56 },
            .sub => .{ .opcode = 60 },
            .fsub => .{ .opcode = 64 },
            .min => .{ .opcode = 120 },
            .max => .{ .opcode = 121 },
            .umin => .{ .opcode = 122 },
            .umax => .{ .opcode = 123 },
            .shl => .{ .opcode = 124 },
            .shr => .{ .opcode = 125 },
            .asr => .{ .opcode = 126 },
            .ror => .{ .opcode = 127 },
            .fmin, .fmax => .{ .opcode = 128 },
            .vfmin => .{ .opcode = 176 },
            .@"and" => .{ .opcode = 181 },
            .@"or" => .{ .opcode = 182 },
            .xor => .{ .opcode = 183 },
            .vadd => .{ .opcode = 184 },
            .vsub => .{ .opcode = 185 },
            .not => .{ .opcode = 186, .raddr_b = 0 },
            .neg => .{ .opcode = 186, .raddr_b = 1 },
            .flapush => .{ .opcode = 186, .raddr_b = 2 },
            .flbpush => .{ .opcode = 186, .raddr_b = 3 },
            .flpop => .{ .opcode = 186, .raddr_b = 4 },
            .setmsf => .{ .opcode = 186, .raddr_b = 6 },
            .setrevf => .{ .opcode = 186, .raddr_b = 7 },
            .nop => .{ .opcode = 187, .raddr_b = 0 },
            .tidx => .{ .opcode = 187, .raddr_b = 1 },
            .eidx => .{ .opcode = 187, .raddr_b = 2 },
            .lr => .{ .opcode = 187, .raddr_b = 3 },
            .vfla => .{ .opcode = 187, .raddr_b = 4 },
            .vflna => .{ .opcode = 187, .raddr_b = 5 },
            .vflb => .{ .opcode = 187, .raddr_b = 6 },
            .vflnb => .{ .opcode = 187, .raddr_b = 7 },
            .fxcd => .{ .opcode = 187, .raddr_b = 8 },
            .xcd => .{ .opcode = 187, .raddr_b = 9 },
            .fycd => .{ .opcode = 187, .raddr_b = 10 },
            .ycd => .{ .opcode = 187, .raddr_b = 11 },
            .msf => .{ .opcode = 187, .raddr_b = 12 },
            .revf => .{ .opcode = 187, .raddr_b = 13 },
            .iid => .{ .opcode = 187, .raddr_b = 14 },
            .tmuwt => .{ .opcode = 187, .raddr_b = 15 },
            .vpmwt => .{ .opcode = 187, .raddr_b = 16 },
            .sampid => .{ .opcode = 187, .raddr_b = 17 },
            .barrierid => .{ .opcode = 187, .raddr_b = 18 },
            .flafirst => .{ .opcode = 187, .raddr_b = 19 },
            .flnafirst => .{ .opcode = 187, .raddr_b = 20 },
            .ldvpmv_in, .ldvpmv_out => .{ .opcode = 188, .raddr_b = 0 },
            .ldvpmd_in, .ldvpmd_out => .{ .opcode = 188, .raddr_b = 1 },
            .ldvpmp => .{ .opcode = 188, .raddr_b = 2 },
            .clz => .{ .opcode = 188, .raddr_b = 16 },
            .itof => .{ .opcode = 188, .raddr_b = 20 },
            .utof => .{ .opcode = 188, .raddr_b = 24 },
            .recip => .{ .opcode = 188, .raddr_b = 32 },
            .rsqrt => .{ .opcode = 188, .raddr_b = 33 },
            .exp => .{ .opcode = 188, .raddr_b = 34 },
            .log => .{ .opcode = 188, .raddr_b = 35 },
            .sin => .{ .opcode = 188, .raddr_b = 36 },
            .rsqrt2 => .{ .opcode = 188, .raddr_b = 37 },
            .ldvpmg_in, .ldvpmg_out => .{ .opcode = 189 },
            .stvpmv, .stvpmd, .stvpmp => .{ .opcode = 190 },
            .fcmp => .{ .opcode = 192 },
            .vfmax => .{ .opcode = 240 },
            .fround => .{ .opcode = 245, .raddr_b = 0 },
            .ftrunc => .{ .opcode = 245, .raddr_b = 1 },
            .ffloor => .{ .opcode = 245, .raddr_b = 2 },
            .fceil => .{ .opcode = 245, .raddr_b = 3 },
            .fdx => .{ .opcode = 245, .raddr_b = 4 },
            .fdy => .{ .opcode = 245, .raddr_b = 5 },
            .ftoin => .{ .opcode = 245, .raddr_b = 12 },
            .ftoiz => .{ .opcode = 245, .raddr_b = 13 },
            .ftouz => .{ .opcode = 245, .raddr_b = 14 },
            .ftoc => .{ .opcode = 245, .raddr_b = 15 },
            .mov => .{ .opcode = 249, .raddr_b = 0 },
        };
    }
};

pub const MulOp = enum {
    add,
    sub,
    umul24,
    vfmul,
    smul24,
    multop,
    fmov,
    mov,
    nop,
    fmul,

    pub fn numSrc(op: MulOp) u2 {
        return switch (op) {
            .nop => 0,
            .fmov, .mov => 1,
            else => 2,
        };
    }

    fn desc(op: MulOp) struct { opcode: u6, mux_b: u3 = 0, mux_a: u3 = 0 } {
        return switch (op) {
            .add => .{ .opcode = 1 },
            .sub => .{ .opcode = 2 },
            .umul24 => .{ .opcode = 3 },
            .vfmul => .{ .opcode = 4 },
            .smul24 => .{ .opcode = 9 },
            .multop => .{ .opcode = 10 },
            .fmov => .{ .opcode = 14 },
            .nop => .{ .opcode = 15, .mux_b = 4, .mux_a = 0 },
            .mov => .{ .opcode = 15, .mux_b = 7 },
            .fmul => .{ .opcode = 16 },
        };
    }

    fn desc71(op: MulOp) struct { opcode: u6, raddr_d: u6 = 0, raddr_c: u6 = 0 } {
        return switch (op) {
            .add => .{ .opcode = 1 },
            .sub => .{ .opcode = 2 },
            .umul24 => .{ .opcode = 3 },
            .vfmul => .{ .opcode = 4 },
            .smul24 => .{ .opcode = 9 },
            .multop => .{ .opcode = 10 },
            .fmov => .{ .opcode = 12 },
            .mov => .{ .opcode = 14, .raddr_d = 0 },
            .nop => .{ .opcode = 14, .raddr_d = 63, .raddr_c = 0 },
            .fmul => .{ .opcode = 16 },
        };
    }
};

pub const AluAdd = struct {
    op: AddOp = .nop,
    dst: Dst = .nop,
    a: Input = .{},
    b: Input = .{},
    output_pack: OutputPack = .none,
};

pub const AluMul = struct {
    op: MulOp = .nop,
    dst: Dst = .nop,
    a: Input = .{},
    b: Input = .{},
    output_pack: OutputPack = .none,
};

pub const Alu = struct {
    sig: Sig = .{},
    sig_addr: u6 = W.nop,
    sig_magic: bool = false,
    raddr_a: u6 = 0,
    raddr_b: u6 = 0,
    flags: Flags = .{},
    add: AluAdd = .{},
    mul: AluMul = .{},
};

pub const AluAdd71 = struct {
    op: AddOp = .nop,
    dst: Dst = .nop,
    a: Input71 = .{},
    b: Input71 = .{},
    output_pack: OutputPack = .none,
};

pub const AluMul71 = struct {
    op: MulOp = .nop,
    dst: Dst = .nop,
    a: Input71 = .{},
    b: Input71 = .{},
    output_pack: OutputPack = .none,
};

pub const Alu71 = struct {
    sig: Sig = .{},
    sig_addr: u6 = W.nop,
    sig_magic: bool = false,
    flags: Flags = .{},
    add: AluAdd71 = .{},
    mul: AluMul71 = .{},
};

const MA_BIT: u64 = 1 << 44;
const MM_BIT: u64 = 1 << 45;

fn packAdd(a: AluAdd) EncodeError!u64 {
    var waddr: u6 = a.dst.waddr;
    var mux_a: u3 = @intFromEnum(a.a.mux);
    var mux_b: u3 = @intFromEnum(a.b.mux);
    const nsrc = a.op.numSrc();
    const d = a.op.desc();
    var opcode: u8 = d.opcode;

    if (nsrc < 2) mux_b = d.mux_b;
    if (nsrc < 1) mux_a = d.mux_a;

    var no_magic_write = false;
    var extra_ma = false;
    switch (a.op) {
        .stvpmv => {
            waddr = 0;
            no_magic_write = true;
        },
        .stvpmd => {
            waddr = 1;
            no_magic_write = true;
        },
        .stvpmp => {
            waddr = 2;
            no_magic_write = true;
        },
        .ldvpmv_in, .ldvpmd_in, .ldvpmp, .ldvpmg_in => {
            if (a.dst.magic) return error.InvalidOpcode;
        },
        .ldvpmv_out, .ldvpmd_out, .ldvpmg_out => {
            if (a.dst.magic) return error.InvalidOpcode;
            extra_ma = true;
        },
        else => {},
    }

    switch (a.op) {
        .fadd, .faddnf, .fsub, .fmin, .fmax, .fcmp => {
            const out_pack: u8 = @intFromEnum(a.output_pack);
            opcode |= out_pack << 4;
            var a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            var b_unp: u8 = a.b.unpack.packFloat32() orelse return error.InvalidPack;
            const ordering = (@as(u16, a_unp) * 8 + mux_a) > (@as(u16, b_unp) * 8 + mux_b);
            if (((a.op == .fmin or a.op == .fadd) and ordering) or
                ((a.op == .fmax or a.op == .faddnf) and !ordering))
            {
                std.mem.swap(u8, &a_unp, &b_unp);
                std.mem.swap(u3, &mux_a, &mux_b);
            }
            opcode |= (a_unp << 2) | b_unp;
        },
        .vfpack => {
            if (a.a.unpack == .abs or a.b.unpack == .abs) return error.InvalidPack;
            const a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            const b_unp: u8 = a.b.unpack.packFloat32() orelse return error.InvalidPack;
            opcode = (opcode & ~@as(u8, 0xf)) | (a_unp << 2) | b_unp;
        },
        .ffloor, .fround, .ftrunc, .fceil, .fdx, .fdy => {
            mux_b |= @intFromEnum(a.output_pack);
            const a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            if (a_unp == 0) return error.InvalidPack;
            opcode = (opcode & ~@as(u8, 0x3 << 2)) | (a_unp << 2);
        },
        .ftoin, .ftoiz, .ftouz, .ftoc => {
            if (a.output_pack != .none) return error.InvalidPack;
            const a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            if (a_unp == 0) return error.InvalidPack;
            opcode |= a_unp << 2;
        },
        .itof, .utof => {
            if (a.a.unpack != .none) return error.InvalidPack;
            mux_b |= @intFromEnum(a.output_pack);
        },
        .vfmin, .vfmax => {
            if (a.output_pack != .none or a.b.unpack != .none) return error.InvalidPack;
            const a_unp: u8 = a.a.unpack.packFloat16() orelse return error.InvalidPack;
            opcode |= a_unp;
        },
        else => {
            if (a.op != .nop and (a.output_pack != .none or a.a.unpack != .none or a.b.unpack != .none))
                return error.InvalidPack;
        },
    }

    var bits: u64 = 0;
    bits |= @as(u64, mux_a) << 12;
    bits |= @as(u64, mux_b) << 15;
    bits |= @as(u64, opcode) << 24;
    bits |= @as(u64, waddr) << 32;
    if (extra_ma or (a.dst.magic and !no_magic_write)) bits |= MA_BIT;
    return bits;
}

fn packMul(m: AluMul) EncodeError!u64 {
    var mux_a: u3 = @intFromEnum(m.a.mux);
    var mux_b: u3 = @intFromEnum(m.b.mux);
    const nsrc = m.op.numSrc();
    const d = m.op.desc();
    var opcode: u6 = d.opcode;

    if (nsrc < 2) mux_b = d.mux_b;
    if (nsrc < 1) mux_a = d.mux_a;

    switch (m.op) {
        .fmul => {
            const out_pack: u6 = @intFromEnum(m.output_pack);
            opcode += out_pack << 4;
            const a_unp: u6 = m.a.unpack.packFloat32() orelse return error.InvalidPack;
            const b_unp: u6 = m.b.unpack.packFloat32() orelse return error.InvalidPack;
            opcode |= (a_unp << 2) | b_unp;
        },
        .fmov => {
            const out_pack: u3 = @intFromEnum(m.output_pack);
            opcode |= @intCast((out_pack >> 1) & 1);
            mux_b = (out_pack & 1) << 2;
            const a_unp: u3 = m.a.unpack.packFloat32() orelse return error.InvalidPack;
            mux_b |= a_unp;
        },
        .vfmul => {
            if (m.output_pack != .none or m.b.unpack != .none) return error.InvalidPack;
            const a_unp: u6 = m.a.unpack.packFloat16() orelse return error.InvalidPack;
            if (m.a.unpack == .swap_16)
                opcode = 8
            else
                opcode |= (a_unp + 4) & 7;
        },
        else => {
            if (m.op != .nop and (m.output_pack != .none or m.a.unpack != .none or m.b.unpack != .none))
                return error.InvalidPack;
        },
    }

    var bits: u64 = 0;
    bits |= @as(u64, mux_a) << 18;
    bits |= @as(u64, mux_b) << 21;
    bits |= @as(u64, opcode) << 58;
    bits |= @as(u64, m.dst.waddr) << 38;
    if (m.dst.magic) bits |= MM_BIT;
    return bits;
}

pub fn alu(a: Alu) EncodeError!Inst {
    const sig = packSig(a.sig) orelse return error.InvalidSignal;
    var packed_inst: u64 = @as(u64, sig) << 53;
    packed_inst |= @as(u64, a.raddr_a) << 6;
    packed_inst |= @as(u64, a.raddr_b) << 0;
    packed_inst |= try packAdd(a.add);
    packed_inst |= try packMul(a.mul);

    var cond: u7 = 0;
    if (a.sig.writesAddress()) {
        cond = a.sig_addr;
        if (a.sig_magic) cond |= 1 << 6;
    } else {
        cond = packFlags(a.flags) orelse return error.InvalidFlags;
    }
    packed_inst |= @as(u64, cond) << 46;
    return packed_inst;
}

pub fn nop() Inst {
    return alu(.{}) catch unreachable;
}

pub fn thrsw() Inst {
    return alu(.{ .sig = .{ .thrsw = true } }) catch unreachable;
}

pub fn wrtmuc() Inst {
    return alu(.{ .sig = .{ .wrtmuc = true } }) catch unreachable;
}

pub fn ldunifrf(dst: Dst) Inst {
    return alu(.{
        .sig = .{ .ldunifrf = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldvary(dst: Dst) Inst {
    return alu(.{
        .sig = .{ .ldvary = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldtmu(dst: Dst) Inst {
    return alu(.{
        .sig = .{ .ldtmu = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldtlbu(dst: Dst) Inst {
    return alu(.{
        .sig = .{ .ldtlbu = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldtlb(dst: Dst) Inst {
    return alu(.{
        .sig = .{ .ldtlb = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

const small_immediates = [48]u32{
    0,                           1,                           2,                           3,
    4,                           5,                           6,                           7,
    8,                           9,                           10,                          11,
    12,                          13,                          14,                          15,
    @bitCast(@as(i32, -16)),     @bitCast(@as(i32, -15)),     @bitCast(@as(i32, -14)),     @bitCast(@as(i32, -13)),
    @bitCast(@as(i32, -12)),     @bitCast(@as(i32, -11)),     @bitCast(@as(i32, -10)),     @bitCast(@as(i32, -9)),
    @bitCast(@as(i32, -8)),      @bitCast(@as(i32, -7)),      @bitCast(@as(i32, -6)),      @bitCast(@as(i32, -5)),
    @bitCast(@as(i32, -4)),      @bitCast(@as(i32, -3)),      @bitCast(@as(i32, -2)),      @bitCast(@as(i32, -1)),
    0x3b800000, // 2.0^-8
    0x3c000000, // 2.0^-7
    0x3c800000, // 2.0^-6
    0x3d000000, // 2.0^-5
    0x3d800000, // 2.0^-4
    0x3e000000, // 2.0^-3
    0x3e800000, // 2.0^-2
    0x3f000000, // 2.0^-1
    0x3f800000, // 2.0^0 (1.0)
    0x40000000, // 2.0^1 (2.0)
    0x40800000, // 2.0^2 (4.0)
    0x41000000, // 2.0^3 (8.0)
    0x41800000, // 2.0^4 (16.0)
    0x42000000, // 2.0^5 (32.0)
    0x42800000, // 2.0^6 (64.0)
    0x43000000, // 2.0^7 (128.0)
};

pub fn encodeSmallImm(bits: u32) ?u6 {
    for (small_immediates, 0..) |v, i| {
        if (v == bits) return @intCast(i);
    }
    return null;
}

test "V3D 4.2 QPU instruction packing matches Mesa qpu_pack" {
    // Plain NOP: add=187 (nop), mul=15 (nop, mux_b=4), waddr_a=6 (MA), waddr_m=6 (MM).
    const n = nop();
    try std.testing.expectEqual(@as(u6, 15), @as(u6, @truncate(n >> 58)));
    try std.testing.expectEqual(@as(u5, 0), @as(u5, @truncate(n >> 53)));
    try std.testing.expectEqual(@as(u8, 187), @as(u8, @truncate(n >> 24)));
    try std.testing.expect(n & MA_BIT != 0);
    try std.testing.expect(n & MM_BIT != 0);

    // THRSW signal sets sig=1.
    const t = thrsw();
    try std.testing.expectEqual(@as(u5, 1), @as(u5, @truncate(t >> 53)));

    // ldunifrf rf3 sets sig=12, cond=3 (sig_magic=false).
    const u = ldunifrf(.rf(3));
    try std.testing.expectEqual(@as(u5, 12), @as(u5, @truncate(u >> 53)));
    try std.testing.expectEqual(@as(u7, 3), @as(u7, @truncate(u >> 46)));

    // ldvary r3 sets sig=8, cond=3 | (1 << 6) (sig_magic=true).
    const v = ldvary(.r(3));
    try std.testing.expectEqual(@as(u5, 8), @as(u5, @truncate(v >> 53)));
    try std.testing.expectEqual(@as(u7, 3 | (1 << 6)), @as(u7, @truncate(v >> 46)));

    // fadd swaps operands if (a_unpack*8 + mux_a) > (b_unpack*8 + mux_b).
    const fa = try alu(.{ .add = .{
        .op = .fadd,
        .dst = .rf(4),
        .a = .{ .mux = .b },
        .b = .{ .mux = .r0 },
    } });
    // After swap, mux_a should be .r0 (0) and mux_b should be .b (7).
    try std.testing.expectEqual(@as(u3, 0), @as(u3, @truncate(fa >> 12)));
    try std.testing.expectEqual(@as(u3, 7), @as(u3, @truncate(fa >> 15)));
}

fn packAdd71(a: AluAdd71, sig: *Sig) EncodeError!u64 {
    var waddr: u6 = a.dst.waddr;
    var raddr_a: u6 = a.a.raddr;
    var raddr_b: u6 = a.b.raddr;
    const nsrc = a.op.numSrc();
    const d = a.op.desc71();
    var opcode: u8 = d.opcode;
    var imm_a: bool = (nsrc >= 1 and a.a.imm) or sig.small_imm_a;
    var imm_b: bool = (nsrc >= 2 and a.b.imm) or sig.small_imm_b;

    if (nsrc < 2) raddr_b = d.raddr_b;
    if (nsrc < 1) raddr_a = d.raddr_a;

    var no_magic_write = false;
    var extra_ma = false;
    switch (a.op) {
        .stvpmv => {
            waddr = 0;
            no_magic_write = true;
        },
        .stvpmd => {
            waddr = 1;
            no_magic_write = true;
        },
        .stvpmp => {
            waddr = 2;
            no_magic_write = true;
        },
        .ldvpmv_in, .ldvpmd_in, .ldvpmp, .ldvpmg_in => {
            if (a.dst.magic) return error.InvalidOpcode;
        },
        .ldvpmv_out, .ldvpmd_out, .ldvpmg_out => {
            if (a.dst.magic) return error.InvalidOpcode;
            extra_ma = true;
        },
        else => {},
    }

    switch (a.op) {
        .fadd, .faddnf, .fsub, .fmin, .fmax, .fcmp => {
            const out_pack: u8 = @intFromEnum(a.output_pack);
            opcode |= out_pack << 4;
            var a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            var b_unp: u8 = a.b.unpack.packFloat32() orelse return error.InvalidPack;
            const ordering = (@as(u16, a_unp) * 64 + raddr_a) > (@as(u16, b_unp) * 64 + raddr_b);
            if (((a.op == .fmin or a.op == .fadd) and ordering) or
                ((a.op == .fmax or a.op == .faddnf) and !ordering))
            {
                std.mem.swap(u8, &a_unp, &b_unp);
                std.mem.swap(u6, &raddr_a, &raddr_b);
                std.mem.swap(bool, &imm_a, &imm_b);
            }
            opcode |= (a_unp << 2) | b_unp;
        },
        .vfpack => {
            if (a.a.unpack == .abs or a.b.unpack == .abs) return error.InvalidPack;
            const a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            const b_unp: u8 = a.b.unpack.packFloat32() orelse return error.InvalidPack;
            opcode = (opcode & ~@as(u8, 0xf)) | (a_unp << 2) | b_unp;
        },
        .ffloor, .fround, .ftrunc, .fceil, .fdx, .fdy => {
            raddr_b |= @as(u6, @intFromEnum(a.output_pack)) << 4;
            const a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            if (a_unp == 0) return error.InvalidPack;
            opcode = (opcode & ~@as(u8, 0x3)) | a_unp;
        },
        .ftoin, .ftoiz, .ftouz, .ftoc => {
            if (a.output_pack != .none) return error.InvalidPack;
            const a_unp: u8 = a.a.unpack.packFloat32() orelse return error.InvalidPack;
            if (a_unp == 0) return error.InvalidPack;
            opcode = (opcode & ~@as(u8, 0x3)) | a_unp;
        },
        .itof, .utof => {
            if (a.a.unpack != .none) return error.InvalidPack;
            raddr_b |= @intFromEnum(a.output_pack);
        },
        .vfmin, .vfmax => {
            if (a.output_pack != .none or a.b.unpack != .none) return error.InvalidPack;
            const a_unp: u8 = a.a.unpack.packFloat16() orelse return error.InvalidPack;
            opcode |= a_unp;
        },
        else => {
            if (a.op != .nop and (a.output_pack != .none or a.a.unpack != .none or a.b.unpack != .none))
                return error.InvalidPack;
        },
    }

    sig.small_imm_a = imm_a;
    sig.small_imm_b = imm_b;

    var bits: u64 = 0;
    bits |= @as(u64, raddr_b) << 0;
    bits |= @as(u64, raddr_a) << 6;
    bits |= @as(u64, opcode) << 24;
    bits |= @as(u64, waddr) << 32;
    if (extra_ma or (a.dst.magic and !no_magic_write)) bits |= MA_BIT;
    return bits;
}

fn packMul71(m: AluMul71, sig: *Sig) EncodeError!u64 {
    var raddr_c: u6 = m.a.raddr;
    var raddr_d: u6 = m.b.raddr;
    const nsrc = m.op.numSrc();
    const d = m.op.desc71();
    var opcode: u6 = d.opcode;

    if (nsrc >= 1 and m.a.imm) sig.small_imm_c = true;
    if (nsrc >= 2 and m.b.imm) sig.small_imm_d = true;

    if (nsrc < 2) raddr_d = d.raddr_d;
    if (nsrc < 1) raddr_c = d.raddr_c;

    switch (m.op) {
        .fmul => {
            const out_pack: u6 = @intFromEnum(m.output_pack);
            opcode += out_pack << 4;
            const a_unp: u6 = m.a.unpack.packFloat32() orelse return error.InvalidPack;
            const b_unp: u6 = m.b.unpack.packFloat32() orelse return error.InvalidPack;
            opcode |= (a_unp << 2) | b_unp;
        },
        .fmov => {
            const out_pack: u6 = @intFromEnum(m.output_pack);
            opcode |= out_pack;
            const a_unp: u6 = m.a.unpack.packFloat32() orelse return error.InvalidPack;
            raddr_d = a_unp << 4;
        },
        .vfmul => {
            if (m.output_pack != .none or m.b.unpack != .none) return error.InvalidPack;
            const a_unp: u6 = m.a.unpack.packFloat16() orelse return error.InvalidPack;
            if (m.a.unpack == .swap_16)
                opcode = 8
            else
                opcode |= (a_unp + 4) & 7;
        },
        else => {
            if (m.op != .nop and (m.output_pack != .none or m.a.unpack != .none or m.b.unpack != .none))
                return error.InvalidPack;
        },
    }

    var bits: u64 = 0;
    bits |= @as(u64, raddr_d) << 12;
    bits |= @as(u64, raddr_c) << 18;
    bits |= @as(u64, opcode) << 58;
    bits |= @as(u64, m.dst.waddr) << 38;
    if (m.dst.magic) bits |= MM_BIT;
    return bits;
}

pub fn alu71(a: Alu71) EncodeError!Inst {
    var sig_s = a.sig;
    const add_bits = try packAdd71(a.add, &sig_s);
    const mul_bits = try packMul71(a.mul, &sig_s);
    const sig = packSig71(sig_s) orelse return error.InvalidSignal;
    var packed_inst: u64 = @as(u64, sig) << 53;
    packed_inst |= add_bits;
    packed_inst |= mul_bits;

    var cond: u7 = 0;
    if (sig_s.writesAddress()) {
        cond = a.sig_addr;
        if (a.sig_magic) cond |= 1 << 6;
    } else {
        cond = packFlags(a.flags) orelse return error.InvalidFlags;
    }
    packed_inst |= @as(u64, cond) << 46;
    return packed_inst;
}

pub fn nop71() Inst {
    return alu71(.{}) catch unreachable;
}

pub fn thrsw71() Inst {
    return alu71(.{ .sig = .{ .thrsw = true } }) catch unreachable;
}

pub fn wrtmuc71() Inst {
    return alu71(.{ .sig = .{ .wrtmuc = true } }) catch unreachable;
}

pub fn ldunifrf71(dst: Dst) Inst {
    return alu71(.{
        .sig = .{ .ldunifrf = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldvary71(dst: Dst) Inst {
    return alu71(.{
        .sig = .{ .ldvary = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldtmu71(dst: Dst) Inst {
    return alu71(.{
        .sig = .{ .ldtmu = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldtlbu71(dst: Dst) Inst {
    return alu71(.{
        .sig = .{ .ldtlbu = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

pub fn ldtlb71(dst: Dst) Inst {
    return alu71(.{
        .sig = .{ .ldtlb = true },
        .sig_addr = dst.waddr,
        .sig_magic = dst.magic,
    }) catch unreachable;
}

test "V3D 7.1 QPU instruction packing matches Mesa qpu_pack" {
    // Plain NOP on V3D 7.1: add=187 (raddr_b=0), mul=14 (raddr_d=63, raddr_c=0).
    const n = nop71();
    try std.testing.expectEqual(@as(u6, 14), @as(u6, @truncate(n >> 58)));
    try std.testing.expectEqual(@as(u6, 63), @as(u6, @truncate(n >> 12)));
    try std.testing.expectEqual(@as(u6, 0), @as(u6, @truncate(n >> 18)));
    try std.testing.expectEqual(@as(u8, 187), @as(u8, @truncate(n >> 24)));
    try std.testing.expect(n & MA_BIT != 0);
    try std.testing.expect(n & MM_BIT != 0);

    // fadd on V3D 7.1 swaps operands if (a_unpack*64 + raddr_a) > (b_unpack*64 + raddr_b).
    const fa = try alu71(.{ .add = .{
        .op = .fadd,
        .dst = .rf(4),
        .a = .{ .raddr = 10 },
        .b = .{ .raddr = 3 },
    } });
    try std.testing.expectEqual(@as(u6, 3), @as(u6, @truncate(fa >> 6)));
    try std.testing.expectEqual(@as(u6, 10), @as(u6, @truncate(fa >> 0)));

    // SFU recip on V3D 7.1: opcode=188, raddr_b=32.
    const rcp = try alu71(.{ .add = .{
        .op = .recip,
        .dst = .rf(5),
        .a = .{ .raddr = 4 },
    } });
    try std.testing.expectEqual(@as(u8, 188), @as(u8, @truncate(rcp >> 24)));
    try std.testing.expectEqual(@as(u6, 4), @as(u6, @truncate(rcp >> 6)));
    try std.testing.expectEqual(@as(u6, 32), @as(u6, @truncate(rcp >> 0)));
}

