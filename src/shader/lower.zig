//! Lowering a SPIR-V entry point onto the vc4 compiler's builder, for one
//! hardware stage: vertex, coordinate (the vertex shader reduced to its
//! position, for the binner) or fragment.
//!
//! The compiler makes straight-line code: functions are inlined, local
//! variables (and access chains into them with constant indices) become
//! plain values, vectors become their components, and control flow is
//! predicated, loops unrolled (see "Control flow" below). The fixed-function parts the hardware leaves to the shaders
//! are added here: the vertex's screen-space header (perspective divide and
//! viewport transform), and the fragment's depth write and blending.

const std = @import("std");
const vc4 = @import("vc4");
const spirv = @import("spirv.zig");

const compiler = vc4.compiler;
const Value = compiler.Value;
const Op = spirv.Op;

pub const Blend = enum(u8) {
    /// The fragment's colour replaces what is there.
    none,
    /// Mixed by the fragment's alpha (straight, not premultiplied).
    source_over,
    /// Over what is there, the fragment's colour already multiplied by its
    /// alpha (as a client's buffer with alpha is).
    premultiplied_over,
};

/// An input or output by location, and its number of scalar components.
pub const Slot = struct {
    location: u32,
    components: u8,
    /// Vertex attributes: whether this stage reads it (the coordinate
    /// shader skips those its position does not use).
    read: bool = true,
};

pub const Interface = struct {
    /// Vertex attributes, in the order they are in the VPM.
    attributes: []const Slot = &.{},
    /// Varyings, in the order they are interpolated.
    varyings: []const Slot = &.{},
    /// Words of uniform data; the viewport scale (x, y) follows.
    uniform_words: u32 = 0,
    depth_write: bool = false,
    blend: Blend = .none,
    /// Samples a pixel has: 4 in a multisampled frame, where blending
    /// reads and writes each sample's colour.
    samples: u8 = 1,
};

pub const Error = error{ Unsupported, InvalidSpirv, OutOfMemory };

/// Why lowering failed, with the source line.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    pub fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const out: []const u8 = std.fmt.bufPrint(&d.buf, fmt, args) catch &d.buf;
        d.len = out.len;
    }
};

const Val = union(enum) {
    scalar: Value,
    int: i64,
    boolean: bool,
    /// A boolean known only at run time, per lane: all ones where true.
    mask: Value,
    /// A choice between values known when compiled, made per lane.
    split: *const Lowerer.Split,
    list: []const Val,
    ptr: Ptr,
    /// A texture, by its slot (see compiler.Shader.texture).
    image: u2,
    none,
};

const Ptr = struct {
    slot: *Val,
    path: []const u32,
};

/// GLSL.std.450 extended instructions.
const Glsl = struct {
    const fabs = 4;
    const floor = 8;
    const pow = 26;
    const exp = 27;
    const log = 28;
    const exp2 = 29;
    const log2 = 30;
    const sqrt = 31;
    const inverse_sqrt = 32;
    const fmin = 37;
    const fmax = 40;
    const fclamp = 43;
    const fmix = 46;
    const fma = 50;
    const length = 66;
    const distance = 67;
    const cross = 68;
    const normalize = 69;
    const nmin = 79;
    const nmax = 80;
    const nclamp = 81;
};

const Lowerer = struct {
    a: std.mem.Allocator,
    m: *const spirv.Module,
    s: *compiler.Shader,
    stage: compiler.Stage,
    iface: *const Interface,
    diag: *Diagnostic,
    /// Global variables (as pointers to their slots) and constants.
    globals: std.AutoHashMapUnmanaged(u32, Val) = .empty,
    /// The interface variables of the entry point: id, storage class and
    /// location (or built-in).
    position_slot: ?*Val = null,
    color_slot: ?*Val = null,
    varying_slots: std.AutoHashMapUnmanaged(u32, *Val) = .empty,
    depth: u32 = 0,
    /// The lanes running the code being lowered.
    when: Pred = p_true,
    /// The innermost loop being unrolled (its merge instruction).
    loop: ?spirv.Inst = null,
    /// Predicates made into masks, to make each once.
    masks: std.ArrayList(struct { pred: Pred, mask: Value }) = .empty,

    fn fail(l: *Lowerer, inst: spirv.Inst, comptime fmt: []const u8, args: anytype) Error {
        var where_buf: [128]u8 = undefined;
        var msg_buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "?";
        l.diag.set("{s}: {s}", .{ l.m.where(inst, &where_buf), msg });
        return error.Unsupported;
    }

    fn k(l: *Lowerer, f: f32) Value {
        return l.s.constantF(f);
    }

    // --- Values ---------------------------------------------------------------

    fn zero(l: *Lowerer, type_id: u32) Error!Val {
        return switch (l.m.typeOf(type_id)) {
            .float => .{ .scalar = l.k(0) },
            .int => .{ .int = 0 },
            .bool => .{ .boolean = false },
            .vector => |v| try l.listOf(v.elem, v.len),
            .array => |arr| try l.listOf(arr.elem, arr.len),
            .@"struct" => |members| blk: {
                const out = try l.a.alloc(Val, members.len);
                for (members, out) |t, *o| o.* = try l.zero(t);
                break :blk .{ .list = out };
            },
            else => .none,
        };
    }

    fn listOf(l: *Lowerer, elem: u32, len: u32) Error!Val {
        const out = try l.a.alloc(Val, len);
        for (out) |*o| o.* = try l.zero(elem);
        return .{ .list = out };
    }

    /// A uniform block's contents: each scalar is the uniform word at its
    /// byte offset.
    fn uniformTree(l: *Lowerer, type_id: u32, offset: u32) Error!Val {
        return switch (l.m.typeOf(type_id)) {
            .float, .int => .{ .scalar = l.s.uniform(offset / 4) },
            .vector => |v| blk: {
                const out = try l.a.alloc(Val, v.len);
                for (out, 0..) |*o, i| o.* = try l.uniformTree(v.elem, offset + @as(u32, @intCast(i)) * 4);
                break :blk .{ .list = out };
            },
            .array => |arr| blk: {
                const stride = l.m.decorationsOf(type_id).array_stride orelse l.m.sizeOf(arr.elem);
                const out = try l.a.alloc(Val, arr.len);
                for (out, 0..) |*o, i| o.* = try l.uniformTree(arr.elem, offset + @as(u32, @intCast(i)) * stride);
                break :blk .{ .list = out };
            },
            .@"struct" => |members| blk: {
                const out = try l.a.alloc(Val, members.len);
                for (members, out, 0..) |t, *o, i| o.* = try l.uniformTree(t, offset + (l.m.memberOffset(type_id, @intCast(i)) orelse 0));
                break :blk .{ .list = out };
            },
            else => .none,
        };
    }

    fn slot(l: *Lowerer, v: Val) Error!*Val {
        const p = try l.a.create(Val);
        p.* = v;
        return p;
    }

    /// The scalars of a value, in order.
    fn scalars(l: *Lowerer, v: Val, out: *std.ArrayList(Value)) Error!void {
        switch (try l.materialize(v)) {
            .scalar => |x| try out.append(l.a, x),
            .list => |items| for (items) |item| try l.scalars(item, out),
            .int => |i| try out.append(l.a, l.k(@floatFromInt(i))),
            else => {},
        }
    }

    fn navigate(v: Val, path: []const u32) ?Val {
        var cur = v;
        for (path) |idx| {
            if (cur != .list or idx >= cur.list.len) return null;
            cur = cur.list[idx];
        }
        return cur;
    }

    /// `v` with the value at `path` replaced (copying what it changes, so
    /// values read before stay as they were).
    fn withSet(l: *Lowerer, v: Val, path: []const u32, new: Val) Error!?Val {
        if (path.len == 0) return new;
        if (v != .list or path[0] >= v.list.len) return null;
        const out = try l.a.dupe(Val, v.list);
        out[path[0]] = (try l.withSet(v.list[path[0]], path[1..], new)) orelse return null;
        return .{ .list = out };
    }

    // --- Arithmetic -------------------------------------------------------------

    fn map1(l: *Lowerer, a: Val, comptime f: fn (*Lowerer, Value) Value) Error!Val {
        return switch (a) {
            .scalar => |x| .{ .scalar = f(l, x) },
            .list => |items| blk: {
                const out = try l.a.alloc(Val, items.len);
                for (items, out) |item, *o| o.* = try l.map1(item, f);
                break :blk .{ .list = out };
            },
            else => a,
        };
    }

    fn map2(l: *Lowerer, a: Val, b: Val, comptime f: fn (*Lowerer, Value, Value) Value) Error!Val {
        if (a == .list and b == .list) {
            const out = try l.a.alloc(Val, a.list.len);
            for (a.list, b.list[0..a.list.len], out) |x, y, *o| o.* = try l.map2(x, y, f);
            return .{ .list = out };
        }
        if (a == .list) {
            const out = try l.a.alloc(Val, a.list.len);
            for (a.list, out) |x, *o| o.* = try l.map2(x, b, f);
            return .{ .list = out };
        }
        if (b == .list) {
            const out = try l.a.alloc(Val, b.list.len);
            for (b.list, out) |y, *o| o.* = try l.map2(a, y, f);
            return .{ .list = out };
        }
        return .{ .scalar = f(l, l.asScalar(a), l.asScalar(b)) };
    }

    fn map3(l: *Lowerer, a: Val, b: Val, c: Val, comptime f: fn (*Lowerer, Value, Value, Value) Value) Error!Val {
        if (a == .list) {
            const out = try l.a.alloc(Val, a.list.len);
            for (a.list, out, 0..) |x, *o, i| o.* = try l.map3(x, if (b == .list) b.list[i] else b, if (c == .list) c.list[i] else c, f);
            return .{ .list = out };
        }
        return .{ .scalar = f(l, l.asScalar(a), l.asScalar(b), l.asScalar(c)) };
    }

    fn asScalar(l: *Lowerer, v: Val) Value {
        return switch (v) {
            .scalar => |x| x,
            .int => |i| l.k(@floatFromInt(i)),
            else => l.k(0),
        };
    }

    // Folded when both are known, so float loop counters are too.
    fn add(l: *Lowerer, a: Value, b: Value) Value {
        if (l.constF(a)) |x| if (l.constF(b)) |y| return l.k(x + y);
        return l.s.fadd(a, b);
    }
    fn sub(l: *Lowerer, a: Value, b: Value) Value {
        if (l.constF(a)) |x| if (l.constF(b)) |y| return l.k(x - y);
        return l.s.fsub(a, b);
    }
    fn mul(l: *Lowerer, a: Value, b: Value) Value {
        if (l.constF(a)) |x| if (l.constF(b)) |y| return l.k(x * y);
        return l.s.fmul(a, b);
    }
    fn div(l: *Lowerer, a: Value, b: Value) Value {
        return l.s.fmul(a, l.s.recip(b));
    }
    fn neg(l: *Lowerer, a: Value) Value {
        return l.s.fsub(l.k(0), a);
    }
    fn fabs(l: *Lowerer, a: Value) Value {
        return l.s.binary(.fmaxabs, a, a);
    }
    fn fmin(l: *Lowerer, a: Value, b: Value) Value {
        return l.s.binary(.fmin, a, b);
    }
    fn fmax(l: *Lowerer, a: Value, b: Value) Value {
        return l.s.binary(.fmax, a, b);
    }
    fn clamp(l: *Lowerer, x: Value, lo: Value, hi: Value) Value {
        return l.fmin(l.fmax(x, lo), hi);
    }
    fn mix(l: *Lowerer, x: Value, y: Value, t: Value) Value {
        return l.add(x, l.mul(l.sub(y, x), t));
    }
    fn fma(l: *Lowerer, a: Value, b: Value, c: Value) Value {
        return l.add(l.mul(a, b), c);
    }
    fn rsqrt(l: *Lowerer, a: Value) Value {
        return l.s.unary(.rsqrt, a);
    }
    /// sqrt(x) = 1 / (1 / sqrt(x)), which is 0 at 0.
    fn sqrt(l: *Lowerer, a: Value) Value {
        return l.s.recip(l.s.unary(.rsqrt, a));
    }
    fn exp2(l: *Lowerer, a: Value) Value {
        return l.s.unary(.exp2, a);
    }
    fn log2(l: *Lowerer, a: Value) Value {
        return l.s.unary(.log2, a);
    }
    fn exp(l: *Lowerer, a: Value) Value {
        return l.exp2(l.mul(a, l.k(std.math.log2e)));
    }
    fn log(l: *Lowerer, a: Value) Value {
        return l.mul(l.log2(a), l.k(std.math.ln2));
    }
    fn pow(l: *Lowerer, a: Value, b: Value) Value {
        return l.exp2(l.mul(b, l.log2(a)));
    }

    /// Rounds down: truncated (towards zero, as ftoi does), then one less
    /// in the lanes where that went up (negative numbers with a fraction).
    fn floor(l: *Lowerer, inst: spirv.Inst, v: Val) Error!Val {
        switch (v) {
            .scalar => |x| {
                if (l.constF(x)) |c| return .{ .scalar = l.k(@floor(c)) };
                const t: Val = .{ .scalar = l.s.unary(.itof, l.s.unary(.ftoi, x)) };
                const over = try l.compare(inst, t, v, .gt);
                return l.select(inst, over, .{ .scalar = l.sub(t.scalar, l.k(1)) }, t);
            },
            .list => |items| {
                const out = try l.a.alloc(Val, items.len);
                for (items, out) |item, *o| o.* = try l.floor(inst, item);
                return .{ .list = out };
            },
            else => return l.fail(inst, "floor of a value that is not a float", .{}),
        }
    }

    fn dot(l: *Lowerer, a: Val, b: Val) Error!Value {
        if (a != .list or b != .list) return l.mul(l.asScalar(a), l.asScalar(b));
        var sum = l.mul(l.asScalar(a.list[0]), l.asScalar(b.list[0]));
        for (a.list[1..], b.list[1..]) |x, y| sum = l.add(sum, l.mul(l.asScalar(x), l.asScalar(y)));
        return sum;
    }

    fn glsl(l: *Lowerer, inst: spirv.Inst, number: u32, args: []const Val) Error!Val {
        const need = switch (number) {
            Glsl.fclamp, Glsl.fmix, Glsl.fma, Glsl.nclamp => @as(usize, 3),
            Glsl.pow, Glsl.fmin, Glsl.fmax, Glsl.nmin, Glsl.nmax, Glsl.distance, Glsl.cross => 2,
            else => 1,
        };
        if (args.len < need) return error.InvalidSpirv;
        return switch (number) {
            Glsl.fabs => l.map1(args[0], fabs),
            Glsl.floor => l.floor(inst, args[0]),
            Glsl.sqrt => l.map1(args[0], sqrt),
            Glsl.inverse_sqrt => l.map1(args[0], rsqrt),
            Glsl.exp2 => l.map1(args[0], exp2),
            Glsl.log2 => l.map1(args[0], log2),
            Glsl.exp => l.map1(args[0], exp),
            Glsl.log => l.map1(args[0], log),
            Glsl.pow => l.map2(args[0], args[1], pow),
            Glsl.fmin, Glsl.nmin => l.map2(args[0], args[1], fmin),
            Glsl.fmax, Glsl.nmax => l.map2(args[0], args[1], fmax),
            Glsl.fclamp, Glsl.nclamp => l.map3(args[0], args[1], args[2], clamp),
            Glsl.fmix => l.map3(args[0], args[1], args[2], mix),
            Glsl.fma => l.map3(args[0], args[1], args[2], fma),
            Glsl.length => .{ .scalar = l.sqrt(try l.dot(args[0], args[0])) },
            Glsl.distance => blk: {
                const d = try l.map2(args[0], args[1], sub);
                break :blk .{ .scalar = l.sqrt(try l.dot(d, d)) };
            },
            Glsl.normalize => blk: {
                const inv = l.rsqrt(try l.dot(args[0], args[0]));
                break :blk l.map2(args[0], .{ .scalar = inv }, mul);
            },
            Glsl.cross => blk: {
                const x = args[0].list;
                const y = args[1].list;
                const c = struct {
                    fn f(lw: *Lowerer, p: Val, q: Val, r: Val, t: Val) Value {
                        return lw.sub(lw.mul(lw.asScalar(p), lw.asScalar(q)), lw.mul(lw.asScalar(r), lw.asScalar(t)));
                    }
                }.f;
                const out = try l.a.alloc(Val, 3);
                out[0] = .{ .scalar = c(l, x[1], y[2], x[2], y[1]) };
                out[1] = .{ .scalar = c(l, x[2], y[0], x[0], y[2]) };
                out[2] = .{ .scalar = c(l, x[0], y[1], x[1], y[0]) };
                break :blk .{ .list = out };
            },
            else => l.fail(inst, "the math function {s} is not supported yet", .{glslName(number)}),
        };
    }

    // --- Instructions ---------------------------------------------------------

    fn get(l: *Lowerer, frame: *const std.AutoHashMapUnmanaged(u32, Val), id: u32) Error!Val {
        if (frame.get(id)) |v| return v;
        if (l.globals.get(id)) |v| return v;
        // A constant, evaluated once.
        const inst = l.m.defs.get(id) orelse return error.InvalidSpirv;
        const o = inst.operands;
        const v: Val = switch (inst.op) {
            Op.constant => switch (l.m.typeOf(o[0])) {
                .float => |w| if (w == 32) .{ .scalar = l.k(@bitCast(o[2])) } else return l.fail(inst, "only 32-bit floats are supported", .{}),
                .int => .{ .int = l.m.constantInt(id).? },
                else => return error.InvalidSpirv,
            },
            Op.constant_true => .{ .boolean = true },
            Op.constant_false => .{ .boolean = false },
            Op.constant_composite => blk: {
                const out = try l.a.alloc(Val, o.len - 2);
                for (o[2..], out) |part, *x| x.* = try l.get(frame, part);
                break :blk .{ .list = out };
            },
            Op.constant_null, Op.undef => try l.zero(o[0]),
            else => return l.fail(inst, "unexpected use of id {d}", .{id}),
        };
        try l.globals.put(l.a, id, v);
        return v;
    }

    fn intOf(l: *Lowerer, inst: spirv.Inst, v: Val) Error!u32 {
        return switch (v) {
            .int => |i| @intCast(i),
            else => l.fail(inst, "indices must be constants (dynamic indexing is not supported)", .{}),
        };
    }

    // --- Control flow -----------------------------------------------------------
    //
    // The QPUs run sixteen fragments (or vertices) at once and the compiler
    // has no branches, so control flow is lowered by predication: every
    // block some lane takes is run, under a predicate saying which lanes
    // take it. Stores into variables keep the old value in the other lanes,
    // phis pick the value of the edge each lane came by, and a function's
    // result is that of the return each lane reached. Blocks no lane takes
    // are skipped, and loops are unrolled, so they must stop after a number
    // of iterations known when the shader is compiled.
    //
    // Predicates are kept as formulas over the comparisons that branches
    // test (sums of products, simplified: an if and its else together give
    // back the predicate before them), so code after an if, or a loop with
    // a break, runs unpredicated again. Integers and booleans known when
    // compiled stay known per predicate (`Split`): a loop counter that the
    // lanes leaving the loop stop counting is still known in the loop.

    /// The most times a loop is unrolled.
    const max_iterations = 256;
    /// Predicates with more terms are made into a mask, and kept as that.
    const max_terms = 24;

    /// A comparison's mask, or its negation.
    const Lit = struct { atom: Value, neg: bool };
    /// Lanes where all the literals hold (sorted by atom, each atom once).
    const Term = []const Lit;
    /// Lanes where any of the terms holds: none is false, an empty term
    /// is true.
    const Pred = []const Term;
    const p_false: Pred = &.{};
    const p_true: Pred = &.{&.{}};

    fn isTrue(p: Pred) bool {
        for (p) |t| if (t.len == 0) return true;
        return false;
    }

    fn isFalse(p: Pred) bool {
        return p.len == 0;
    }

    /// A per-lane choice between values known when compiled: `x` in the
    /// lanes where `when` holds, `y` in the others.
    const Split = struct { when: Pred, x: Val, y: Val };

    fn termAnd(l: *Lowerer, a: Term, b: Term) Error!?Term {
        var out: std.ArrayList(Lit) = try .initCapacity(l.a, a.len + b.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.len or j < b.len) {
            if (j == b.len or (i < a.len and @intFromEnum(a[i].atom) < @intFromEnum(b[j].atom))) {
                out.appendAssumeCapacity(a[i]);
                i += 1;
            } else if (i == a.len or @intFromEnum(b[j].atom) < @intFromEnum(a[i].atom)) {
                out.appendAssumeCapacity(b[j]);
                j += 1;
            } else {
                if (a[i].neg != b[j].neg) return null;
                out.appendAssumeCapacity(a[i]);
                i += 1;
                j += 1;
            }
        }
        return out.items;
    }

    /// Whether every literal of `a` is in `b` (so `b` implies `a`).
    fn termSubset(a: Term, b: Term) bool {
        var j: usize = 0;
        for (a) |lit| {
            while (j < b.len and @intFromEnum(b[j].atom) < @intFromEnum(lit.atom)) j += 1;
            if (j == b.len or b[j].atom != lit.atom or b[j].neg != lit.neg) return false;
        }
        return true;
    }

    /// `a` and `b` differ only in the sign of one literal: its index.
    fn complementary(a: Term, b: Term) ?usize {
        if (a.len != b.len) return null;
        var at: ?usize = null;
        for (a, b, 0..) |x, y, i| {
            if (x.atom != y.atom) return null;
            if (x.neg != y.neg) {
                if (at != null) return null;
                at = i;
            }
        }
        return at;
    }

    fn simplify(l: *Lowerer, terms: []Term) Error!Pred {
        var list: std.ArrayList(Term) = .fromOwnedSlice(terms);
        var changed = true;
        while (changed) {
            changed = false;
            outer: for (list.items, 0..) |a, i| {
                if (a.len == 0) return p_true;
                for (list.items, 0..) |b, j| {
                    if (i == j) continue;
                    // a or (a and more) = a
                    if (termSubset(a, b) and (a.len < b.len or i < j)) {
                        _ = list.swapRemove(j);
                        changed = true;
                        break :outer;
                    }
                    // (x and a) or (not x and a) = a
                    if (complementary(a, b)) |at| {
                        const merged = try l.a.alloc(Lit, a.len - 1);
                        @memcpy(merged[0..at], a[0..at]);
                        @memcpy(merged[at..], a[at + 1 ..]);
                        list.items[i] = merged;
                        _ = list.swapRemove(j);
                        changed = true;
                        break :outer;
                    }
                }
            }
        }
        if (list.items.len > max_terms) {
            const m = try l.mask(list.items);
            return l.literal(m, false);
        }
        return list.items;
    }

    fn literal(l: *Lowerer, atom: Value, negated: bool) Error!Pred {
        var a = atom;
        var n = negated;
        // A mask made by negating another is that one's negation.
        while (true) {
            const def = l.s.insts[@intFromEnum(a)];
            if (def.op != .xor or def.nsrc != 2) break;
            const s0 = l.s.insts[@intFromEnum(def.srcs[0])];
            const s1 = l.s.insts[@intFromEnum(def.srcs[1])];
            if (s1.op == .constant and s1.imm == 0xffffffff) {
                a = def.srcs[0];
            } else if (s0.op == .constant and s0.imm == 0xffffffff) {
                a = def.srcs[1];
            } else break;
            n = !n;
        }
        const def = l.s.insts[@intFromEnum(a)];
        if (def.op == .constant) return if ((def.imm != 0) != n) p_true else p_false;
        const term = try l.a.alloc(Lit, 1);
        term[0] = .{ .atom = a, .neg = n };
        const out = try l.a.alloc(Term, 1);
        out[0] = term;
        return out;
    }

    fn pAnd(l: *Lowerer, a: Pred, b: Pred) Error!Pred {
        if (isTrue(a)) return b;
        if (isTrue(b)) return a;
        var out: std.ArrayList(Term) = .empty;
        for (a) |x| for (b) |y| if (try l.termAnd(x, y)) |t| try out.append(l.a, t);
        return l.simplify(out.items);
    }

    fn pOr(l: *Lowerer, a: Pred, b: Pred) Error!Pred {
        if (isFalse(a)) return b;
        if (isFalse(b)) return a;
        const out = try l.a.alloc(Term, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return l.simplify(out);
    }

    fn pNot(l: *Lowerer, p: Pred) Error!Pred {
        var out = p_true;
        for (p) |t| {
            // not (x and y and ...) = not x or not y or ...
            var any = p_false;
            for (t) |lit| any = try l.pOr(any, try l.literal(lit.atom, !lit.neg));
            out = try l.pAnd(out, any);
        }
        return out;
    }

    /// Whether `a` implies `b` (as far as can be told from their terms).
    fn implies(a: Pred, b: Pred) bool {
        for (a) |x| {
            for (b) |y| {
                if (termSubset(y, x)) break;
            } else return false;
        }
        return true;
    }

    /// Whether `a` and `b` never both hold.
    fn disjoint(l: *Lowerer, a: Pred, b: Pred) Error!bool {
        for (a) |x| for (b) |y| if (try l.termAnd(x, y) != null) return false;
        return true;
    }

    fn predEql(a: Pred, b: Pred) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x.len != y.len) return false;
            for (x, y) |p, q| if (p.atom != q.atom or p.neg != q.neg) return false;
        }
        return true;
    }

    fn allOnes(l: *Lowerer) Value {
        return l.s.constant(0xffffffff);
    }

    /// A predicate as a per-lane mask: all ones where it holds.
    fn mask(l: *Lowerer, p: Pred) Error!Value {
        if (isTrue(p)) return l.allOnes();
        if (isFalse(p)) return l.s.constant(0);
        for (l.masks.items) |e| if (predEql(e.pred, p)) return e.mask;
        var any: ?Value = null;
        for (p) |t| {
            var all: ?Value = null;
            for (t) |lit| {
                const m = if (lit.neg) l.s.binary(.xor, lit.atom, l.allOnes()) else lit.atom;
                all = if (all) |x| l.s.binary(.@"and", x, m) else m;
            }
            any = if (any) |x| l.s.binary(.@"or", x, all.?) else all.?;
        }
        try l.masks.append(l.a, .{ .pred = p, .mask = any.? });
        return any.?;
    }

    /// The lanes where a boolean holds.
    fn predOf(l: *Lowerer, v: Val) Error!Pred {
        return switch (v) {
            .boolean => |b| if (b) p_true else p_false,
            .mask => |m| l.literal(m, false),
            .split => |s| l.pOr(try l.pAnd(s.when, try l.predOf(s.x)), try l.pAnd(try l.pNot(s.when), try l.predOf(s.y))),
            else => error.InvalidSpirv,
        };
    }

    /// A boolean holding in the lanes where `p` does.
    fn boolOf(l: *Lowerer, p: Pred) Error!Val {
        if (isTrue(p)) return .{ .boolean = true };
        if (isFalse(p)) return .{ .boolean = false };
        if (p.len == 1 and p[0].len == 1 and !p[0][0].neg) return .{ .mask = p[0][0].atom };
        const s = try l.a.create(Split);
        s.* = .{ .when = p, .x = .{ .boolean = true }, .y = .{ .boolean = false } };
        return .{ .split = s };
    }

    fn isKnown(v: Val) bool {
        return v == .int or v == .boolean or v == .split;
    }

    fn knownEql(a: Val, b: Val) bool {
        return switch (a) {
            .int => |x| b == .int and b.int == x,
            .boolean => |x| b == .boolean and b.boolean == x,
            .split => |x| b == .split and b.split == x,
            else => false,
        };
    }

    /// `x` in the lanes where `p` holds, `y` in the others.
    fn choose(l: *Lowerer, inst: spirv.Inst, p: Pred, x: Val, y: Val) Error!Val {
        if (isTrue(p)) return x;
        if (isFalse(p)) return y;
        if (x == .list and y == .list) {
            if (x.list.len != y.list.len) return error.InvalidSpirv;
            const out = try l.a.alloc(Val, x.list.len);
            for (out, x.list, y.list) |*o, a, b| o.* = try l.choose(inst, p, a, b);
            return .{ .list = out };
        }
        if (isKnown(x) and isKnown(y)) {
            if (knownEql(x, y)) return x;
            const s = try l.a.create(Split);
            s.* = .{ .when = p, .x = x, .y = y };
            return .{ .split = s };
        }
        return switch (x) {
            .ptr => |q| if (y == .ptr and y.ptr.slot == q.slot and std.mem.eql(u32, y.ptr.path, q.path)) x else l.fail(inst, "choosing between pointers at run time is not supported", .{}),
            .image, .none => if (y == .none) x else y,
            .list => l.fail(inst, "choosing between values of different types", .{}),
            else => l.runtimeSelect(try l.mask(p), try l.materialize(x), try l.materialize(y)),
        };
    }

    fn runtimeSelect(l: *Lowerer, m: Value, x: Val, y: Val) Val {
        const boolean = x == .boolean or x == .mask;
        if (boolean) return .{ .mask = l.bitSelect(m, l.maskOf(x), l.maskOf(y)) };
        return .{ .scalar = l.bitSelect(m, l.asScalar(x), l.asScalar(y)) };
    }

    fn maskOf(l: *Lowerer, v: Val) Value {
        return switch (v) {
            .mask => |m| m,
            .boolean => |b| if (b) l.allOnes() else l.s.constant(0),
            else => l.s.constant(0),
        };
    }

    /// `m ? x : y`, bit by bit.
    fn bitSelect(l: *Lowerer, m: Value, x: Value, y: Value) Value {
        if (x == y) return x;
        return l.s.binary(.xor, y, l.s.binary(.@"and", l.s.binary(.xor, x, y), m));
    }

    fn hasSplit(v: Val) bool {
        return switch (v) {
            .split => true,
            .list => |items| for (items) |item| {
                if (hasSplit(item)) break true;
            } else false,
            else => false,
        };
    }

    /// `v` as the lanes running now see it: choices they all make the
    /// same way are made.
    fn resolve(l: *Lowerer, v: Val) Error!Val {
        if (!hasSplit(v)) return v;
        switch (v) {
            .split => |s| {
                if (implies(l.when, s.when)) return l.resolve(s.x);
                if (try l.disjoint(l.when, s.when)) return l.resolve(s.y);
                return v;
            },
            .list => |items| {
                const out = try l.a.alloc(Val, items.len);
                for (items, out) |item, *o| o.* = try l.resolve(item);
                return .{ .list = out };
            },
            else => return v,
        }
    }

    /// `v` with its remaining choices made at run time (integers become
    /// floats, exact to 2^24).
    fn materialize(l: *Lowerer, v: Val) Error!Val {
        if (!hasSplit(v)) return v;
        switch (v) {
            .split => |s| {
                if (implies(l.when, s.when)) return l.materialize(s.x);
                if (try l.disjoint(l.when, s.when)) return l.materialize(s.y);
                return l.runtimeSelect(try l.mask(s.when), try l.materialize(s.x), try l.materialize(s.y));
            },
            .list => |items| {
                const out = try l.a.alloc(Val, items.len);
                for (items, out) |item, *o| o.* = try l.materialize(item);
                return .{ .list = out };
            },
            else => return v,
        }
    }

    /// Applies `f` to each side of a choice (the choice made per lane).
    fn distribute(l: *Lowerer, inst: spirv.Inst, a: Val, b: Val, ctx: anytype, comptime f: fn (*Lowerer, spirv.Inst, Val, Val, @TypeOf(ctx)) Error!Val) Error!?Val {
        if (a == .split) return try l.choose(inst, a.split.when, try f(l, inst, a.split.x, b, ctx), try f(l, inst, a.split.y, b, ctx));
        if (b == .split) return try l.choose(inst, b.split.when, try f(l, inst, a, b.split.x, ctx), try f(l, inst, a, b.split.y, ctx));
        return null;
    }

    fn eachPair(l: *Lowerer, inst: spirv.Inst, a: Val, b: Val, ctx: anytype, comptime f: fn (*Lowerer, spirv.Inst, Val, Val, @TypeOf(ctx)) Error!Val) Error!?Val {
        if (a != .list and b != .list) return null;
        const n = if (a == .list) a.list.len else b.list.len;
        const out = try l.a.alloc(Val, n);
        for (out, 0..) |*o, i| o.* = try f(l, inst, if (a == .list) a.list[i] else a, if (b == .list) b.list[i] else b, ctx);
        return .{ .list = out };
    }

    /// Float constants known when the shader is compiled.
    fn constF(l: *Lowerer, v: Value) ?f32 {
        const def = l.s.insts[@intFromEnum(v)];
        return if (def.op == .constant) @bitCast(def.imm) else null;
    }

    const Cmp = enum { lt, le, gt, ge, eq, ne };

    /// Lanes where x < y (all ones), from the sign of x - y (adding +0
    /// makes -0 into +0).
    fn ltMask(l: *Lowerer, x: Value, y: Value) Value {
        const d = l.s.fadd(l.s.fsub(x, y), l.k(0));
        return l.s.binary(.asr, d, l.allOnes()); // shifts by 31
    }

    /// Lanes where x != y: x - y is non-zero, so it or its negation has
    /// the sign bit set.
    fn neMask(l: *Lowerer, x: Value, y: Value) Value {
        const d = l.s.fadd(l.s.fsub(x, y), l.k(0));
        const nd = l.s.binary(.sub, l.s.constant(0), d);
        return l.s.binary(.asr, l.s.binary(.@"or", d, nd), l.allOnes());
    }

    fn notMask(l: *Lowerer, m: Value) Val {
        return .{ .mask = l.s.binary(.xor, m, l.allOnes()) };
    }

    fn compare(l: *Lowerer, inst: spirv.Inst, a: Val, b: Val, cmp: Cmp) Error!Val {
        if (try l.eachPair(inst, a, b, cmp, compare)) |v| return v;
        if (try l.distribute(inst, a, b, cmp, compare)) |v| return v;
        if ((a != .scalar and a != .int) or (b != .scalar and b != .int)) return error.InvalidSpirv;
        const known: ?[2]f64 = if (a == .int and b == .int)
            .{ @floatFromInt(a.int), @floatFromInt(b.int) }
        else if (l.constF(l.asScalar(a))) |x| if (l.constF(l.asScalar(b))) |y| .{ x, y } else null else null;
        if (known) |xy| return .{ .boolean = switch (cmp) {
            .lt => xy[0] < xy[1],
            .le => xy[0] <= xy[1],
            .gt => xy[0] > xy[1],
            .ge => xy[0] >= xy[1],
            .eq => xy[0] == xy[1],
            .ne => xy[0] != xy[1],
        } };
        const x = l.asScalar(a);
        const y = l.asScalar(b);
        return switch (cmp) {
            .lt => .{ .mask = l.ltMask(x, y) },
            .gt => .{ .mask = l.ltMask(y, x) },
            .ge => l.notMask(l.ltMask(x, y)),
            .le => l.notMask(l.ltMask(y, x)),
            .ne => .{ .mask = l.neMask(x, y) },
            .eq => l.notMask(l.neMask(x, y)),
        };
    }

    const Logic = enum { @"and", @"or", xor, eq };

    fn logic(l: *Lowerer, inst: spirv.Inst, a: Val, b: Val, op: Logic) Error!Val {
        if (try l.eachPair(inst, a, b, op, logic)) |v| return v;
        const p = try l.predOf(a);
        const q = try l.predOf(b);
        return l.boolOf(switch (op) {
            .@"and" => try l.pAnd(p, q),
            .@"or" => try l.pOr(p, q),
            .xor, .eq => blk: {
                const x = try l.pOr(try l.pAnd(p, try l.pNot(q)), try l.pAnd(try l.pNot(p), q));
                break :blk if (op == .xor) x else try l.pNot(x);
            },
        });
    }

    fn logicNot(l: *Lowerer, v: Val) Error!Val {
        if (v == .list) {
            const out = try l.a.alloc(Val, v.list.len);
            for (v.list, out) |item, *o| o.* = try l.logicNot(item);
            return .{ .list = out };
        }
        return l.boolOf(try l.pNot(try l.predOf(v)));
    }

    /// Integers known when the shader is compiled are folded; others (from
    /// a choice made at run time) are floats, exact to 2^24.
    fn intArith(l: *Lowerer, inst: spirv.Inst, a: Val, b: Val, op: u32) Error!Val {
        if (try l.eachPair(inst, a, b, op, intArith)) |v| return v;
        if (try l.distribute(inst, a, b, op, intArith)) |v| return v;
        if (a == .int and b == .int) return .{ .int = switch (op) {
            Op.i_add => a.int +% b.int,
            Op.i_sub => a.int -% b.int,
            else => a.int *% b.int,
        } };
        return switch (op) {
            Op.i_add => l.map2(a, b, add),
            Op.i_sub => l.map2(a, b, sub),
            else => l.map2(a, b, mul),
        };
    }

    fn intToFloat(l: *Lowerer, v: Val) Error!Val {
        return switch (v) {
            .int => |i| .{ .scalar = l.k(@floatFromInt(i)) },
            .list => |items| blk: {
                const out = try l.a.alloc(Val, items.len);
                for (items, out) |item, *o| o.* = try l.intToFloat(item);
                break :blk .{ .list = out };
            },
            else => v,
        };
    }

    fn floatToInt(l: *Lowerer, v: Val) Error!Val {
        return switch (v) {
            .scalar => |x| if (l.constF(x)) |c|
                .{ .int = if (std.math.isFinite(c) and @abs(c) < 0x1p62) @intFromFloat(@trunc(c)) else 0 }
            else
                .{ .scalar = l.s.unary(.itof, l.s.unary(.ftoi, x)) },
            .list => |items| blk: {
                const out = try l.a.alloc(Val, items.len);
                for (items, out) |item, *o| o.* = try l.floatToInt(item);
                break :blk .{ .list = out };
            },
            else => v,
        };
    }

    fn select(l: *Lowerer, inst: spirv.Inst, c: Val, x: Val, y: Val) Error!Val {
        if (c == .list) {
            if (x != .list or y != .list or x.list.len < c.list.len or y.list.len < c.list.len) return error.InvalidSpirv;
            const out = try l.a.alloc(Val, c.list.len);
            for (out, c.list, x.list[0..c.list.len], y.list[0..c.list.len]) |*o, ci, xi, yi| o.* = try l.select(inst, ci, xi, yi);
            return .{ .list = out };
        }
        return l.choose(inst, try l.predOf(c), x, y);
    }

    const Block = struct {
        label: u32,
        /// The instructions after the label, ending with the terminator.
        insts: []const spirv.Inst,
        /// For a loop header, its merge block's label.
        merge: ?u32 = null,
    };

    /// How a block is reached: for which lanes, and its phis' values.
    const Incoming = struct {
        pred: Pred,
        phis: std.AutoHashMapUnmanaged(u32, Val) = .empty,
    };

    const Func = struct {
        blocks: []Block,
        index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        /// Block indices, each after every block with an edge to it (other
        /// than loops' back edges).
        order: []u32,
        incoming: []?Incoming,
        frame: std.AutoHashMapUnmanaged(u32, Val) = .empty,
        returned: Pred = p_false,
        result: Val = .none,

        fn successors(f: *const Func, b: u32, out: *[64]u32) []const u32 {
            const insts = f.blocks[b].insts;
            if (insts.len == 0) return &.{};
            const term = insts[insts.len - 1];
            const o = term.operands;
            var n: usize = 0;
            switch (term.op) {
                Op.branch => {
                    out[0] = o[0];
                    n = 1;
                },
                Op.branch_conditional => {
                    out[0] = o[1];
                    out[1] = o[2];
                    n = 2;
                },
                Op.@"switch" => {
                    out[0] = o[1];
                    n = 1;
                    var i: usize = 3;
                    while (i < o.len and n < out.len) : (i += 2) {
                        out[n] = o[i];
                        n += 1;
                    }
                },
                else => {},
            }
            var m: usize = 0;
            for (out[0..n]) |label| if (f.index.get(label)) |idx| {
                out[m] = idx;
                m += 1;
            };
            return out[0..m];
        }
    };

    /// Lowers a function call, run for the lanes running now; returns its
    /// result.
    fn call(l: *Lowerer, function: u32, args: []const Val) Error!Val {
        const body = l.m.functions.get(function) orelse return error.InvalidSpirv;
        l.depth += 1;
        defer l.depth -= 1;
        if (l.depth > 64) return l.fail(body[0], "recursion is not supported", .{});
        const caller_when = l.when;
        defer l.when = caller_when;

        // Split the body into blocks.
        var blocks: std.ArrayList(Block) = .empty;
        var params: std.ArrayList(u32) = .empty;
        var start: ?usize = null;
        for (body[1..], 1..) |inst, i| switch (inst.op) {
            Op.function_parameter => try params.append(l.a, inst.operands[1]),
            Op.label, Op.function_end => {
                if (start) |s| blocks.items[blocks.items.len - 1].insts = body[s..i];
                if (inst.op == Op.label) {
                    try blocks.append(l.a, .{ .label = inst.operands[0], .insts = &.{} });
                    start = i + 1;
                }
            },
            Op.loop_merge => if (blocks.items.len > 0) {
                blocks.items[blocks.items.len - 1].merge = inst.operands[0];
            },
            else => {},
        };
        if (blocks.items.len == 0 or params.items.len != args.len) return error.InvalidSpirv;

        var f: Func = .{
            .blocks = blocks.items,
            .order = try l.a.alloc(u32, blocks.items.len),
            .incoming = try l.a.alloc(?Incoming, blocks.items.len),
        };
        for (f.blocks, 0..) |b, i| try f.index.put(l.a, b.label, @intCast(i));
        for (params.items, args) |id, v| try f.frame.put(l.a, id, v);
        @memset(f.incoming, null);
        try l.topoOrder(&f);

        f.incoming[0] = .{ .pred = caller_when };
        try l.runBlocks(&f, null, null);
        return f.result;
    }

    /// Reverse postorder of a depth-first walk from the entry: a
    /// topological order once the edges back to blocks still being walked
    /// (loops' back edges) are left out.
    fn topoOrder(l: *Lowerer, f: *Func) Error!void {
        const n = f.blocks.len;
        const state = try l.a.alloc(u8, n);
        @memset(state, 0);
        const Frame = struct { b: u32, next: usize };
        var stack: std.ArrayList(Frame) = .empty;
        var post = n;
        try stack.append(l.a, .{ .b = 0, .next = 0 });
        state[0] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            var buf: [64]u32 = undefined;
            const succ = f.successors(top.b, &buf);
            if (top.next < succ.len) {
                const s = succ[top.next];
                top.next += 1;
                if (state[s] == 0) {
                    state[s] = 1;
                    try stack.append(l.a, .{ .b = s, .next = 0 });
                }
            } else {
                state[top.b] = 2;
                post -= 1;
                f.order[post] = top.b;
                _ = stack.pop();
            }
        }
        // Unreachable blocks are never run.
        f.order = f.order[post..];
    }

    /// Runs the blocks in `members` (all if null) that are reached, in
    /// order. Loop headers run their loop, other than `header`, the loop
    /// being run.
    fn runBlocks(l: *Lowerer, f: *Func, members: ?[]const bool, header: ?u32) Error!void {
        for (f.order) |b| {
            if (members) |m| if (!m[b]) continue;
            const inc = f.incoming[b] orelse continue;
            if (f.blocks[b].merge != null and header != b) {
                try l.runLoop(f, b);
                continue;
            }
            f.incoming[b] = null;
            try l.runBlock(f, b, inc);
        }
    }

    /// Unrolls the loop with header `h` until no lane takes its back edge.
    fn runLoop(l: *Lowerer, f: *Func, h: u32) Error!void {
        const n = f.blocks.len;
        const merge = f.index.get(f.blocks[h].merge.?) orelse return error.InvalidSpirv;
        // The loop's blocks: those reached from the header before its merge
        // block, and not after it.
        const members = try l.a.alloc(bool, n);
        const after = try l.a.alloc(bool, n);
        try l.reach(f, merge, h, null, after);
        try l.reach(f, h, merge, after, members);
        const outer = l.loop;
        defer l.loop = outer;
        l.loop = for (f.blocks[h].insts) |inst| {
            if (inst.op == Op.loop_merge) break inst;
        } else f.blocks[h].insts[0];
        var iterations: usize = 0;
        while (f.incoming[h] != null) : (iterations += 1) {
            if (iterations == max_iterations) return l.loopTooLong();
            try l.runBlocks(f, members, h);
        }
    }

    fn loopTooLong(l: *Lowerer) Error {
        return l.fail(l.loop.?, "loops must stop after a number of iterations known when the shader is compiled (and not too many: they are unrolled)", .{});
    }

    /// Marks the blocks reached from `from` without passing `stop` (or a
    /// block in `exclude`) in `out`.
    fn reach(l: *Lowerer, f: *const Func, from: u32, stop: u32, exclude: ?[]const bool, out: []bool) Error!void {
        @memset(out, false);
        var work: std.ArrayList(u32) = .empty;
        try work.append(l.a, from);
        out[from] = true;
        while (work.pop()) |b| {
            var buf: [64]u32 = undefined;
            for (f.successors(b, &buf)) |s| {
                if (s == stop or s == from or out[s]) continue;
                if (exclude) |e| if (e[s]) continue;
                out[s] = true;
                try work.append(l.a, s);
            }
        }
    }

    /// Notes that the lanes where `when` holds go from block `from` to the
    /// block labelled `to`, and the values its phis then take.
    fn edge(l: *Lowerer, f: *Func, from: u32, to: u32, when: Pred) Error!void {
        if (isFalse(when)) return;
        const t = f.index.get(to) orelse return error.InvalidSpirv;
        const first = f.incoming[t] == null;
        var inc = f.incoming[t] orelse Incoming{ .pred = p_false };
        const block_when = l.when;
        defer l.when = block_when;
        l.when = when;
        for (f.blocks[t].insts) |inst| {
            if (inst.op != Op.phi) break;
            const o = inst.operands;
            var i: usize = 2;
            while (i + 1 < o.len) : (i += 2) {
                if (o[i + 1] != f.blocks[from].label) continue;
                const v = try l.resolve(try l.get(&f.frame, o[i]));
                const old = if (first) null else inc.phis.get(o[1]);
                try inc.phis.put(l.a, o[1], if (old) |y| try l.choose(inst, when, v, y) else v);
                break;
            }
        }
        inc.pred = try l.pOr(inc.pred, when);
        f.incoming[t] = inc;
    }

    fn runBlock(l: *Lowerer, f: *Func, b: u32, inc: Incoming) Error!void {
        l.when = inc.pred;
        const frame = &f.frame;
        for (f.blocks[b].insts) |inst| {
            const o = inst.operands;
            if (l.s.len + 64 > compiler.max_insts) {
                if (l.loop != null) return l.loopTooLong();
                return l.fail(inst, "the shader is too long", .{});
            }
            switch (inst.op) {
                Op.phi => try frame.put(l.a, o[1], inc.phis.get(o[1]) orelse try l.zero(o[0])),
                Op.selection_merge, Op.loop_merge => {},
                Op.branch => try l.edge(f, b, o[0], l.when),
                Op.branch_conditional => {
                    const c = try l.predOf(try l.keep(frame, o[0]));
                    const when = l.when;
                    try l.edge(f, b, o[1], try l.pAnd(when, c));
                    try l.edge(f, b, o[2], try l.pAnd(when, try l.pNot(c)));
                },
                Op.@"switch" => {
                    const sel = try l.keep(frame, o[0]);
                    if (o.len % 2 != 0) return l.fail(inst, "switching on 64-bit integers is not supported", .{});
                    var rest = l.when;
                    var i: usize = 2;
                    while (i + 1 < o.len) : (i += 2) {
                        const hit = try l.predOf(if (sel == .int)
                            Val{ .boolean = @as(u32, @truncate(@as(u64, @bitCast(sel.int)))) == o[i] }
                        else
                            try l.compare(inst, sel, .{ .int = @as(i32, @bitCast(o[i])) }, .eq));
                        try l.edge(f, b, o[i + 1], try l.pAnd(rest, hit));
                        rest = try l.pAnd(rest, try l.pNot(hit));
                    }
                    try l.edge(f, b, o[1], rest);
                },
                Op.@"return" => f.returned = try l.pOr(f.returned, l.when),
                Op.return_value => {
                    const v = try l.keep(frame, o[0]);
                    f.result = if (isFalse(f.returned)) v else try l.choose(inst, l.when, v, f.result);
                    f.returned = try l.pOr(f.returned, l.when);
                },
                Op.@"unreachable" => {},
                Op.kill => return l.fail(inst, "discarding fragments is not supported yet", .{}),
                else => try l.exec(frame, inst),
            }
        }
    }

    /// An operand, with the choices the running lanes make the same way
    /// made, and the others kept.
    fn keep(l: *Lowerer, frame: *const std.AutoHashMapUnmanaged(u32, Val), id: u32) Error!Val {
        return l.resolve(try l.get(frame, id));
    }

    /// An operand as a value at run time.
    fn val(l: *Lowerer, frame: *const std.AutoHashMapUnmanaged(u32, Val), id: u32) Error!Val {
        return l.materialize(try l.get(frame, id));
    }

    /// Lowers an instruction other than control flow, for the lanes
    /// running now.
    fn exec(l: *Lowerer, frame: *std.AutoHashMapUnmanaged(u32, Val), inst: spirv.Inst) Error!void {
        const o = inst.operands;
        switch (inst.op) {
            Op.variable => {
                const ptr_type = l.m.typeOf(o[0]);
                if (ptr_type != .pointer) return error.InvalidSpirv;
                const init: Val = if (o.len > 3) try l.keep(frame, o[3]) else try l.zero(ptr_type.pointer.pointee);
                try frame.put(l.a, o[1], .{ .ptr = .{ .slot = try l.slot(init), .path = &.{} } });
            },
            Op.load => {
                const p = try l.get(frame, o[2]);
                if (p != .ptr) return error.InvalidSpirv;
                const v = navigate(p.ptr.slot.*, p.ptr.path) orelse return l.fail(inst, "loading from outside a variable", .{});
                if (v == .none) return l.fail(inst, "this input or built-in is not supported", .{});
                try frame.put(l.a, o[1], v);
            },
            Op.store => {
                const p = try l.get(frame, o[0]);
                if (p != .ptr) return error.InvalidSpirv;
                var v = try l.keep(frame, o[1]);
                if (!isTrue(l.when)) {
                    const old = navigate(p.ptr.slot.*, p.ptr.path) orelse return l.fail(inst, "storing outside a variable", .{});
                    v = try l.choose(inst, l.when, v, old);
                }
                p.ptr.slot.* = (try l.withSet(p.ptr.slot.*, p.ptr.path, v)) orelse return l.fail(inst, "storing outside a variable", .{});
            },
            Op.access_chain, Op.in_bounds_access_chain, Op.ptr_access_chain, Op.in_bounds_ptr_access_chain => {
                const base = try l.get(frame, o[2]);
                if (base != .ptr) return error.InvalidSpirv;
                var indices = o[3..];
                if (inst.op == Op.ptr_access_chain or inst.op == Op.in_bounds_ptr_access_chain) {
                    if (indices.len == 0 or try l.intOf(inst, try l.keep(frame, indices[0])) != 0)
                        return l.fail(inst, "pointer arithmetic is not supported", .{});
                    indices = indices[1..];
                }
                const path = try l.a.alloc(u32, base.ptr.path.len + indices.len);
                @memcpy(path[0..base.ptr.path.len], base.ptr.path);
                for (indices, path[base.ptr.path.len..]) |idx, *p| p.* = try l.intOf(inst, try l.keep(frame, idx));
                try frame.put(l.a, o[1], .{ .ptr = .{ .slot = base.ptr.slot, .path = path } });
            },
            Op.composite_extract => {
                const v = navigate(try l.keep(frame, o[2]), o[3..]) orelse return error.InvalidSpirv;
                try frame.put(l.a, o[1], v);
            },
            Op.composite_insert => {
                const v = (try l.withSet(try l.keep(frame, o[3]), o[4..], try l.keep(frame, o[2]))) orelse return error.InvalidSpirv;
                try frame.put(l.a, o[1], v);
            },
            Op.composite_construct => {
                var parts: std.ArrayList(Val) = .empty;
                const vector = l.m.typeOf(o[0]) == .vector;
                for (o[2..]) |part| {
                    const v = try l.keep(frame, part);
                    // Vectors may be built from smaller vectors.
                    if (vector and v == .list) try parts.appendSlice(l.a, v.list) else try parts.append(l.a, v);
                }
                try frame.put(l.a, o[1], .{ .list = parts.items });
            },
            Op.vector_shuffle => {
                const x = try l.keep(frame, o[2]);
                const y = try l.keep(frame, o[3]);
                const xs: []const Val = if (x == .list) x.list else &.{x};
                const ys: []const Val = if (y == .list) y.list else &.{y};
                const out = try l.a.alloc(Val, o.len - 4);
                for (o[4..], out) |c, *r| r.* = if (c == 0xffffffff) .{ .scalar = l.k(0) } else if (c < xs.len) xs[c] else ys[c - xs.len];
                try frame.put(l.a, o[1], .{ .list = out });
            },
            // A copy between types laid out differently (a uniform's
            // explicitly laid out array, and the plain one): the same values.
            Op.copy_object, Op.copy_logical => try frame.put(l.a, o[1], try l.keep(frame, o[2])),
            Op.undef => try frame.put(l.a, o[1], try l.zero(o[0])),
            Op.f_add => try frame.put(l.a, o[1], try l.map2(try l.val(frame, o[2]), try l.val(frame, o[3]), add)),
            Op.f_sub => try frame.put(l.a, o[1], try l.map2(try l.val(frame, o[2]), try l.val(frame, o[3]), sub)),
            Op.f_mul, Op.vector_times_scalar => try frame.put(l.a, o[1], try l.map2(try l.val(frame, o[2]), try l.val(frame, o[3]), mul)),
            Op.f_div => try frame.put(l.a, o[1], try l.map2(try l.val(frame, o[2]), try l.val(frame, o[3]), div)),
            Op.f_negate => try frame.put(l.a, o[1], try l.map1(try l.val(frame, o[2]), neg)),
            Op.dot => try frame.put(l.a, o[1], .{ .scalar = try l.dot(try l.val(frame, o[2]), try l.val(frame, o[3])) }),
            Op.convert_s_to_f, Op.convert_u_to_f => try frame.put(l.a, o[1], try l.intToFloat(try l.val(frame, o[2]))),
            Op.convert_f_to_s, Op.convert_f_to_u => try frame.put(l.a, o[1], try l.floatToInt(try l.val(frame, o[2]))),
            Op.u_convert, Op.s_convert => try frame.put(l.a, o[1], try l.keep(frame, o[2])),
            // Between integers of the same width (Zig 0.17 casts loop
            // indices this way): the same value, as for the conversions.
            Op.bitcast => switch (l.m.typeOf(o[0])) {
                .int => try frame.put(l.a, o[1], try l.keep(frame, o[2])),
                else => return l.fail(inst, "bit casts are only supported between integers", .{}),
            },
            Op.i_add, Op.i_sub, Op.i_mul => try frame.put(l.a, o[1], try l.intArith(inst, try l.keep(frame, o[2]), try l.keep(frame, o[3]), inst.op)),
            Op.s_negate => try frame.put(l.a, o[1], try l.intArith(inst, .{ .int = 0 }, try l.keep(frame, o[2]), Op.i_sub)),
            Op.ext_inst => {
                if (l.m.glsl_std_450 == null or o[2] != l.m.glsl_std_450.?) return l.fail(inst, "unknown extended instruction set", .{});
                var args_buf: [4]Val = undefined;
                if (o.len - 4 > args_buf.len) return error.InvalidSpirv;
                for (o[4..], args_buf[0 .. o.len - 4]) |arg, *x| x.* = try l.val(frame, arg);
                try frame.put(l.a, o[1], try l.glsl(inst, o[3], args_buf[0 .. o.len - 4]));
            },
            Op.function_call => {
                const call_args = try l.a.alloc(Val, o.len - 3);
                for (o[3..], call_args) |arg, *x| x.* = try l.keep(frame, arg);
                try frame.put(l.a, o[1], try l.call(o[2], call_args));
            },
            Op.sampled_image => try frame.put(l.a, o[1], try l.val(frame, o[2])),
            Op.image_sample_implicit_lod, Op.image_sample_explicit_lod => {
                if (l.stage != .fragment) return l.fail(inst, "textures can only be sampled in fragment shaders", .{});
                const image = try l.val(frame, o[2]);
                if (image != .image) return l.fail(inst, "sampling something that is not a texture", .{});
                const coord = try l.val(frame, o[3]);
                if (coord != .list or coord.list.len < 2) return l.fail(inst, "texture coordinates must be a Vec2", .{});
                const texel = l.s.texture(image.image, l.asScalar(coord.list[0]), l.asScalar(coord.list[1]));
                // Texels are B, G, R, A.
                const out = try l.a.alloc(Val, 4);
                for (out, [_]u2{ 2, 1, 0, 3 }) |*c, byte| c.* = .{ .scalar = l.s.unpackUnorm8(texel, byte) };
                try frame.put(l.a, o[1], .{ .list = out });
            },
            Op.select => try frame.put(l.a, o[1], try l.select(inst, try l.keep(frame, o[2]), try l.keep(frame, o[3]), try l.keep(frame, o[4]))),
            Op.logical_and, Op.logical_or, Op.logical_not_equal, Op.logical_equal => {
                const op: Logic = switch (inst.op) {
                    Op.logical_and => .@"and",
                    Op.logical_or => .@"or",
                    Op.logical_not_equal => .xor,
                    else => .eq,
                };
                try frame.put(l.a, o[1], try l.logic(inst, try l.keep(frame, o[2]), try l.keep(frame, o[3]), op));
            },
            Op.logical_not => try frame.put(l.a, o[1], try l.logicNot(try l.keep(frame, o[2]))),
            Op.any, Op.all => {
                const v = try l.keep(frame, o[2]);
                var acc: Val = .{ .boolean = inst.op == Op.all };
                for (if (v == .list) v.list else &.{v}) |c| acc = try l.logic(inst, acc, c, if (inst.op == Op.all) .@"and" else .@"or");
                try frame.put(l.a, o[1], acc);
            },
            Op.i_equal...Op.f_unord_greater_than_equal => {
                const cmp: Cmp = switch (inst.op) {
                    Op.i_equal, Op.f_ord_equal, Op.f_unord_equal => .eq,
                    Op.i_not_equal, Op.f_ord_not_equal, Op.f_unord_not_equal => .ne,
                    Op.u_greater_than, Op.s_greater_than, Op.f_ord_greater_than, Op.f_unord_greater_than => .gt,
                    Op.u_greater_than_equal, Op.s_greater_than_equal, Op.f_ord_greater_than_equal, Op.f_unord_greater_than_equal => .ge,
                    Op.u_less_than, Op.s_less_than, Op.f_ord_less_than, Op.f_unord_less_than => .lt,
                    else => .le,
                };
                try frame.put(l.a, o[1], try l.compare(inst, try l.keep(frame, o[2]), try l.keep(frame, o[3]), cmp));
            },
            else => return l.fail(inst, "SPIR-V instruction {d} is not supported", .{inst.op}),
        }
    }
};

pub fn glslName(number: u32) []const u8 {
    return switch (number) {
        1 => "round",
        3 => "trunc",
        6 => "sign",
        8 => "floor",
        9 => "ceil",
        10 => "fract",
        13 => "sin",
        14 => "cos",
        15 => "tan",
        16...25 => "a trigonometric function",
        48 => "step",
        49 => "smoothstep",
        else => "?",
    };
}

/// Lowers the module's entry point for `model` into `shader` as `stage`.
pub fn lower(
    gpa: std.mem.Allocator,
    m: *const spirv.Module,
    entry: spirv.EntryPoint,
    interface_ids: []const u32,
    stage: compiler.Stage,
    iface: *const Interface,
    shader: *compiler.Shader,
    diag: *Diagnostic,
) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    shader.* = compiler.Shader.init(stage);
    var l: Lowerer = .{ .a = arena.allocator(), .m = m, .s = shader, .stage = stage, .iface = iface, .diag = diag };
    const s = shader;

    // Inputs, read up front in the hardware's order: attributes from the
    // VPM, or varyings from the interpolator.
    var input_vals: std.AutoHashMapUnmanaged(u32, Val) = .empty;
    const reads = if (stage == .fragment) iface.varyings else iface.attributes;
    for (reads) |r| {
        const comps = try l.a.alloc(Val, r.components);
        for (comps) |*c| c.* = .{ .scalar = if (!r.read) l.k(0) else if (stage == .fragment) s.varying() else s.vpmRead() };
        try input_vals.put(l.a, r.location, if (r.components == 1) comps[0] else .{ .list = comps });
    }

    // Global variables.
    var it = m.defs.iterator();
    while (it.next()) |e| {
        const inst = e.value_ptr.*;
        if (inst.op != Op.variable) continue;
        const id = e.key_ptr.*;
        const ptr_type = m.typeOf(inst.operands[0]);
        if (ptr_type != .pointer) continue;
        const storage = inst.operands[2];
        if (storage == spirv.StorageClass.function) continue;
        const in_interface = std.mem.indexOfScalar(u32, interface_ids, id) != null;
        const deco = m.decorationsOf(id);
        const pointee = ptr_type.pointer.pointee;
        const value: Val = switch (storage) {
            spirv.StorageClass.input => if (in_interface and deco.location != null) (input_vals.get(deco.location.?) orelse try l.zero(pointee)) else .none,
            spirv.StorageClass.output => try l.zero(pointee),
            spirv.StorageClass.uniform => try l.uniformTree(pointee, 0),
            spirv.StorageClass.uniform_constant => .{
                .image = switch (deco.binding orelse 0) {
                    // gpu.texture's is not bound (the uniforms are at 0);
                    // gpu.texture1's is at 2, and gpu.texture2's at 3.
                    0, 1 => 0,
                    2 => 1,
                    else => 2,
                },
            },
            else => try l.zero(pointee),
        };
        const p = try l.slot(value);
        try l.globals.put(l.a, id, .{ .ptr = .{ .slot = p, .path = &.{} } });
        if (storage == spirv.StorageClass.output and in_interface) {
            if (deco.builtin != null and deco.builtin.? == spirv.BuiltIn.position) l.position_slot = p;
            if (deco.location) |loc| {
                if (stage == .fragment and loc == 0) l.color_slot = p;
                try l.varying_slots.put(l.a, loc, p);
            }
        }
    }

    _ = try l.call(entry.function, &.{});

    switch (stage) {
        .vertex, .coordinate => {
            const pos_slot = l.position_slot orelse return l.fail(m.functions.get(entry.function).?[0], "the vertex shader must write the position", .{});
            var pos: std.ArrayList(Value) = .empty;
            try l.scalars(pos_slot.*, &pos);
            if (pos.items.len != 4) return error.InvalidSpirv;
            if (stage == .coordinate) for (pos.items) |c| s.vpmWrite(c);
            screenHeader(&l, pos.items);
            if (stage == .vertex) for (iface.varyings) |vy| {
                const p = l.varying_slots.get(vy.location) orelse return l.fail(m.functions.get(entry.function).?[0], "the vertex shader does not write location {d}, which the fragment shader reads", .{vy.location});
                var vals: std.ArrayList(Value) = .empty;
                try l.scalars(p.*, &vals);
                for (0..vy.components) |i| s.vpmWrite(if (i < vals.items.len) vals.items[i] else l.k(0));
            };
        },
        .fragment => {
            const p = l.color_slot orelse return l.fail(m.functions.get(entry.function).?[0], "the fragment shader must write a colour at location 0", .{});
            var c: std.ArrayList(Value) = .empty;
            try l.scalars(p.*, &c);
            if (c.items.len != 4) return l.fail(m.functions.get(entry.function).?[0], "the colour output must be a Vec4", .{});
            if (iface.depth_write) s.tlbZ(s.fragZ());
            const rgba = c.items;
            switch (iface.blend) {
                // The render target is B8G8R8A8.
                .none => s.tlbColor(s.packUnorm8888(rgba[2], rgba[1], rgba[0], rgba[3])),
                .source_over, .premultiplied_over => {
                    const alpha = rgba[3];
                    const inv = s.fsub(l.k(1), alpha);
                    const pre = iface.blend == .premultiplied_over;
                    // Straight: the colour times its alpha (and the alpha
                    // itself), plus what is there times the rest.
                    // Premultiplied: the colour as it is.
                    const src = [4]Value{ rgba[2], rgba[1], rgba[0], if (pre) alpha else l.k(1) };
                    const weight = if (pre) l.k(1) else alpha;
                    // Multisampled, each sample is blended with its own
                    // colour: the four read in turn, then written in turn
                    // (as Mesa does).
                    var dsts: [4]Value = undefined;
                    const n: usize = if (iface.samples == 4) 4 else 1;
                    for (dsts[0..n]) |*d| d.* = s.tlbColorLoad();
                    for (dsts[0..n]) |dst| {
                        var out: [4]Value = undefined;
                        for (&out, src, 0..) |*o, x, i| o.* = s.fadd(s.fmul(x, weight), s.fmul(s.unpackUnorm8(dst, @intCast(i)), inv));
                        const px = s.packUnorm8888(out[0], out[1], out[2], out[3]);
                        if (n == 4) s.tlbColorMs(px) else s.tlbColor(px);
                    }
                },
            }
        },
    }
}

/// Perspective divide and viewport transform, then the shaded vertex
/// header: Xs|Ys (12.4 fixed point), Zs and 1/Wc.
///
/// The SFU's reciprocal is only approximate: where a corner lands on the
/// screen would be off by a tenth of a pixel or more across a 1080p
/// screen, so a corner part way along another triangle's edge (as merged
/// faces have) could leave a crack beside it. One Newton-Raphson step,
/// r(2 - wr), makes it as good as a float can be (as Mesa's vc4 does).
fn screenHeader(l: *Lowerer, pos: []const Value) void {
    const s = l.s;
    const rough = s.recip(pos[3]);
    const rcp_w = s.fmul(rough, s.fsub(l.k(2), s.fmul(pos[3], rough)));
    const vp = l.iface.uniform_words;
    const xs = s.fmul(s.fmul(pos[0], s.uniform(vp)), rcp_w);
    const ys = s.fmul(s.fmul(pos[1], s.uniform(vp + 1)), rcp_w);
    const half = l.k(0.5);
    const zs = s.fadd(s.fmul(s.fmul(pos[2], half), rcp_w), half);
    s.vpmWrite(s.packScreenXy(xs, ys));
    s.vpmWrite(zs);
    s.vpmWrite(rcp_w);
}

test "predicates: an if and its else give back what was before, and a loop's breaks all its lanes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var shader: compiler.Shader = .init(.fragment);
    var diag: Diagnostic = .{};
    var l: Lowerer = .{ .a = arena.allocator(), .m = undefined, .s = &shader, .stage = .fragment, .iface = undefined, .diag = &diag };
    var c: [4]Lowerer.Pred = undefined;
    for (&c, 0..) |*p, i| p.* = try l.literal(shader.uniform(@intCast(i)), false);
    const p = c[0];

    // if (c1) ... else ...: P and c1, P and not c1; together, P.
    const then = try l.pAnd(p, c[1]);
    const otherwise = try l.pAnd(p, try l.pNot(c[1]));
    try std.testing.expect(Lowerer.predEql(p, try l.pOr(then, otherwise)));
    try std.testing.expect(try l.disjoint(then, otherwise));
    try std.testing.expect(Lowerer.implies(then, p));
    try std.testing.expect(!Lowerer.implies(p, then));

    // A loop breaking where c1, then c2, then c3, or running out: all.
    var left = Lowerer.p_true;
    var out = Lowerer.p_false;
    for (c[1..]) |b| {
        out = try l.pOr(out, try l.pAnd(left, b));
        left = try l.pAnd(left, try l.pNot(b));
    }
    try std.testing.expect(Lowerer.isTrue(try l.pOr(out, left)));

    // A negated mask is that mask's negation.
    const m = try l.mask(c[1]);
    try std.testing.expect(Lowerer.predEql(try l.pNot(c[1]), try l.literal(shader.binary(.xor, m, l.allOnes()), false)));
}
