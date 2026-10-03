//! Instruction scheduler for straight-line QPU code.
//!
//! Takes a program in which every instruction uses at most one ALU and
//! instructions run in order (as code generation produces it, without
//! hazard NOPs), and reorders it to:
//!
//! * satisfy latencies: a physical register can be read two instructions
//!   after it is written, an accumulator one after, and an SFU result in r4
//!   three after;
//! * pair an add-ALU instruction with a mul-ALU instruction where one
//!   instruction can encode both (`qpu.merge`);
//! * fill latency gaps with independent work instead of NOPs.
//!
//! Ordering of the hardware's FIFO-like ports is preserved: uniform reads
//! (including the implicit ones by TMU writes), varyings, VPM reads and
//! writes, texture requests and results, and tile buffer writes.
//!
//! This is classic list scheduling over a dependency graph, choosing the
//! ready instruction with the longest path to the end of the program first.

const std = @import("std");
const qpu = @import("qpu.zig");

pub const max_insts = 512;
const max_edges = 8192;
const max_readers = 64;

pub const Error = error{ TooManyInstructions, TooManyDependencies };

const Edge = struct { from: u16, latency: u8 };

/// Resources tracked for dependencies.
const Res = struct {
    const phys_a = 0; // 0..31
    const phys_b = 32; // 32..63
    const acc = 64; // r0..r5 at 64..69
    const r4 = acc + 4;
    const r5 = acc + 5;
    const unif = 70; // uniform stream, also consumed by TMU writes
    const vary = 71;
    const vpm_read = 72;
    const vpm_write = 73;
    const tmu = 74;
    const tlb = 75;
    const flags = 76;
    const count = 77;
};

const Access = struct {
    reads: [8]u8 = undefined,
    nreads: usize = 0,
    writes: [6]Write = undefined,
    nwrites: usize = 0,

    const Write = struct { res: u8, latency: u8 };

    fn read(a: *Access, res: u8) void {
        a.reads[a.nreads] = res;
        a.nreads += 1;
    }
    fn write(a: *Access, res: u8, latency: u8) void {
        a.writes[a.nwrites] = .{ .res = res, .latency = latency };
        a.nwrites += 1;
    }
};

fn readPort(acc: *Access, addr: u6, file: qpu.Mux) void {
    if (addr < 32) {
        acc.read(if (file == .a) Res.phys_a + @as(u8, addr) else Res.phys_b + @as(u8, addr));
        return;
    }
    switch (addr) {
        qpu.R.unif => acc.write(Res.unif, 1),
        qpu.R.vary => {
            acc.write(Res.vary, 1);
            acc.write(Res.r5, 1);
        },
        qpu.R.vpm => acc.write(Res.vpm_read, 1),
        else => {},
    }
}

fn writeAddr(acc: *Access, waddr: u6, file: qpu.Mux) void {
    switch (waddr) {
        0...31 => acc.write(if (file == .a) Res.phys_a + @as(u8, waddr) else Res.phys_b + @as(u8, waddr), 2),
        qpu.W.acc0...qpu.W.acc0 + 3 => acc.write(Res.acc + @as(u8, waddr - qpu.W.acc0), 1),
        qpu.W.acc5 => acc.write(Res.r5, 1),
        qpu.W.nop => {},
        qpu.W.vpm => {
            // Outputs may overwrite the VPM area the inputs were loaded
            // into, so all reads come first.
            acc.read(Res.vpm_read);
            acc.write(Res.vpm_write, 1);
        },
        qpu.W.vpmvcd_setup => if (file == .a) acc.write(Res.vpm_read, 1) else acc.write(Res.vpm_write, 1),
        qpu.W.tlb_z, qpu.W.tlb_color_all, qpu.W.tlb_color_ms, qpu.W.tlb_stencil_setup, qpu.W.tlb_alpha_mask => acc.write(Res.tlb, 1),
        qpu.W.sfu_recip, qpu.W.sfu_recipsqrt, qpu.W.sfu_exp, qpu.W.sfu_log => acc.write(Res.r4, 3),
        qpu.W.tmu0_s...qpu.W.tmu1_b => {
            acc.write(Res.tmu, 1);
            acc.write(Res.unif, 1);
        },
        else => {
            // Anything else is ordered against every port.
            inline for (.{ Res.unif, Res.vary, Res.vpm_read, Res.vpm_write, Res.tmu, Res.tlb }) |r| acc.write(r, 1);
        },
    }
}

fn accesses(i: qpu.Inst) Access {
    var a: Access = .{};
    const sig = qpu.getSig(i);
    const ws = qpu.getWs(i);
    if (sig != .load_imm) {
        var muxes: [4]qpu.Mux = undefined;
        var n: usize = 0;
        if (qpu.getAddOp(i) != .nop) {
            muxes[n] = @enumFromInt(@as(u3, @truncate(i >> 9)));
            muxes[n + 1] = @enumFromInt(@as(u3, @truncate(i >> 6)));
            n += 2;
        }
        if (qpu.getMulOp(i) != .nop) {
            muxes[n] = @enumFromInt(@as(u3, @truncate(i >> 3)));
            muxes[n + 1] = @enumFromInt(@as(u3, @truncate(i)));
            n += 2;
        }
        var read_a = false;
        var read_b = false;
        for (muxes[0..n]) |m| switch (m) {
            .a => read_a = true,
            .b => read_b = true,
            else => |acc_mux| {
                const res = Res.acc + @as(u8, @intFromEnum(acc_mux));
                if (std.mem.indexOfScalar(u8, a.reads[0..a.nreads], res) == null) a.read(res);
            },
        };
        if (read_a) readPort(&a, qpu.getRaddrA(i), .a);
        if (read_b and sig != .small_imm) readPort(&a, qpu.getRaddrB(i), .b);
    }
    writeAddr(&a, qpu.getWaddrAdd(i), if (ws) .b else .a);
    writeAddr(&a, qpu.getWaddrMul(i), if (ws) .a else .b);
    switch (sig) {
        .load_tmu0, .load_tmu1 => {
            a.write(Res.tmu, 1);
            a.write(Res.r4, 1);
        },
        else => {},
    }
    const cond_add: qpu.Cond = @enumFromInt(@as(u3, @truncate(i >> 49)));
    const cond_mul: qpu.Cond = @enumFromInt(@as(u3, @truncate(i >> 46)));
    const conditional = (cond_add != .always and cond_add != .never) or (cond_mul != .always and cond_mul != .never);
    if (conditional) a.read(Res.flags);
    if (i & (1 << 45) != 0 and sig != .branch) a.write(Res.flags, 1);
    return a;
}

/// Whether an instruction does nothing at all (a hazard NOP).
fn isPlainNop(i: qpu.Inst) bool {
    return qpu.getSig(i) == .none and qpu.getAddOp(i) == .nop and qpu.getMulOp(i) == .nop and
        qpu.getWaddrAdd(i) == qpu.W.nop and qpu.getWaddrMul(i) == qpu.W.nop;
}

const Graph = struct {
    insts: [max_insts]qpu.Inst = undefined,
    n: usize = 0,
    edges: [max_edges]Edge = undefined,
    nedges: usize = 0,
    /// Edges into node i are edges[edge_start[i]..edge_start[i + 1]].
    edge_start: [max_insts + 1]u16 = undefined,

    fn addEdge(g: *Graph, from: u16, latency: u8) Error!void {
        // Merge duplicates from the same node, keeping the larger latency.
        const start = g.edge_start[g.n];
        for (g.edges[start..g.nedges]) |*e| if (e.from == from) {
            e.latency = @max(e.latency, latency);
            return;
        };
        if (g.nedges == max_edges) return error.TooManyDependencies;
        g.edges[g.nedges] = .{ .from = from, .latency = latency };
        g.nedges += 1;
    }

    fn preds(g: *const Graph, i: usize) []const Edge {
        return g.edges[g.edge_start[i]..g.edge_start[i + 1]];
    }
};

fn buildGraph(g: *Graph, code: []const qpu.Inst) Error!void {
    var last_writer: [Res.count]?u16 = @splat(null);
    var last_latency: [Res.count]u8 = @splat(0);
    var readers: [Res.count][max_readers]u16 = undefined;
    var nreaders: [Res.count]usize = @splat(0);

    for (code) |inst| {
        if (isPlainNop(inst)) continue;
        if (g.n == max_insts) return error.TooManyInstructions;
        const id: u16 = @intCast(g.n);
        g.insts[g.n] = inst;
        g.edge_start[g.n] = @intCast(g.nedges);
        const a = accesses(inst);

        // Read after write: wait for the value.
        for (a.reads[0..a.nreads]) |r| if (last_writer[r]) |w| try g.addEdge(w, last_latency[r]);
        for (a.writes[0..a.nwrites]) |w| {
            // Write after write: stay in order (and keep r4 writers apart).
            if (last_writer[w.res]) |p| try g.addEdge(p, @max(1, if (w.res == Res.r4) last_latency[w.res] else 1));
            // Write after read: may share an instruction with the reader,
            // which sees the old value.
            for (readers[w.res][0..nreaders[w.res]]) |rd| try g.addEdge(rd, 0);
        }
        for (a.reads[0..a.nreads]) |r| {
            if (nreaders[r] == max_readers) {
                // Too many readers to track: order this one after them all
                // by treating it as a write.
                for (readers[r][0..nreaders[r]]) |rd| try g.addEdge(rd, 1);
                nreaders[r] = 0;
            }
            readers[r][nreaders[r]] = id;
            nreaders[r] += 1;
        }
        for (a.writes[0..a.nwrites]) |w| {
            last_writer[w.res] = id;
            last_latency[w.res] = w.latency;
            nreaders[w.res] = 0;
        }
        g.n += 1;
    }
    g.edge_start[g.n] = @intCast(g.nedges);
}

pub const Result = struct {
    code: [max_insts]qpu.Inst = undefined,
    len: usize = 0,

    pub fn slice(r: *const Result) []const qpu.Inst {
        return r.code[0..r.len];
    }
};

/// Schedules `code` (the program body, without the thread end sequence).
pub fn schedule(code: []const qpu.Inst, stage: qpu.Stage) Error!Result {
    var g: Graph = .{};
    try buildGraph(&g, code);
    const n = g.n;

    // Priority: the longest latency-weighted path to the end of the program.
    var priority: [max_insts]u32 = @splat(1);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        for (g.preds(i)) |e| priority[e.from] = @max(priority[e.from], priority[i] + e.latency);
    }

    var cycle_of: [max_insts]?u32 = @splat(null);
    var out: Result = .{};
    var scheduled: usize = 0;
    var cycle: u32 = 0;
    while (scheduled < n) : (cycle += 1) {
        if (out.len == max_insts) return error.TooManyInstructions;
        const first = pickReady(&g, &cycle_of, &priority, cycle, null);
        if (first) |f| {
            cycle_of[f] = cycle;
            scheduled += 1;
            var inst = g.insts[f];
            // Try to pair it with another ready instruction.
            var best: ?usize = null;
            var best_inst: qpu.Inst = 0;
            for (0..n) |c| {
                if (cycle_of[c] != null or !isReady(&g, &cycle_of, c, cycle)) continue;
                const merged = qpu.merge(inst, g.insts[c]) orelse continue;
                if (best == null or priority[c] > priority[best.?]) {
                    best = c;
                    best_inst = merged;
                }
            }
            if (best) |b| {
                cycle_of[b] = cycle;
                scheduled += 1;
                inst = best_inst;
            }
            out.code[out.len] = inst;
        } else {
            out.code[out.len] = qpu.nop(.none);
        }
        out.len += 1;
    }

    // A fragment shader must not touch the tile buffer in its first two
    // instructions; shift the program down if it does.
    if (stage == .fragment) {
        var shift: usize = 0;
        for (out.code[0..@min(2, out.len)], 0..) |inst, ip| {
            if (touchesTlb(inst)) shift = 2 - ip;
        }
        if (shift > 0) {
            if (out.len + shift > max_insts) return error.TooManyInstructions;
            std.mem.copyBackwards(qpu.Inst, out.code[shift .. out.len + shift], out.code[0..out.len]);
            for (out.code[0..shift]) |*c| c.* = qpu.nop(.none);
            out.len += shift;
        }
    }
    return out;
}

fn touchesTlb(i: qpu.Inst) bool {
    inline for (.{ qpu.W.tlb_z, qpu.W.tlb_color_all, qpu.W.tlb_color_ms, qpu.W.tlb_stencil_setup, qpu.W.tlb_alpha_mask }) |w|
        if (qpu.writesAddr(i, w)) return true;
    return false;
}

fn isReady(g: *const Graph, cycle_of: *const [max_insts]?u32, node: usize, cycle: u32) bool {
    for (g.preds(node)) |e| {
        const c = cycle_of[e.from] orelse return false;
        if (c + e.latency > cycle) return false;
    }
    return true;
}

fn pickReady(g: *const Graph, cycle_of: *const [max_insts]?u32, priority: *const [max_insts]u32, cycle: u32, exclude: ?usize) ?usize {
    var best: ?usize = null;
    for (0..g.n) |c| {
        if (cycle_of[c] != null or c == exclude) continue;
        if (!isReady(g, cycle_of, c, cycle)) continue;
        if (best == null or priority[c] > priority[best.?]) best = c;
    }
    return best;
}

const testing = std.testing;

test "independent add and mul are paired" {
    const code = [_]qpu.Inst{
        try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(0), .a = qpu.r(1), .b = qpu.r(2) } }),
        try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = qpu.r(2) } }),
    };
    const r = try schedule(&code, .vertex);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "register file latency is respected" {
    const code = [_]qpu.Inst{
        try qpu.mov(qpu.wa(1), qpu.r(0)),
        try qpu.mov(qpu.wr(2), qpu.ra(1)),
    };
    const r = try schedule(&code, .vertex);
    try testing.expectEqual(@as(usize, 3), r.len); // a NOP between them
    const full = [_]qpu.Inst{ r.code[0], r.code[1], r.code[2], qpu.nop(.prog_end), qpu.nop(.none), qpu.nop(.none) };
    try qpu.validate(&full, .vertex, null);
}

test "uniform reads keep their order" {
    const code = [_]qpu.Inst{
        try qpu.mov(qpu.wr(0), qpu.unif),
        try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = qpu.unif, .b = qpu.r(2) } }),
    };
    const r = try schedule(&code, .vertex);
    try testing.expectEqual(@as(usize, 2), r.len); // not merged: one uniform per instruction
    try testing.expectEqual(code[0], r.code[0]);
}
