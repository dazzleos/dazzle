//! Lowering a SPIR-V entry point onto the vc4 compiler's builder, for one
//! hardware stage: vertex, coordinate (the vertex shader reduced to its
//! position, for the binner) or fragment.
//!
//! Shaders are straight-line code, as the compiler has no branches yet:
//! functions are inlined, local variables (and access chains into them with
//! constant indices) become plain values, and vectors become their
//! components. The fixed-function parts the hardware leaves to the shaders
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
    list: []const Val,
    ptr: Ptr,
    image,
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
        switch (v) {
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

    fn add(l: *Lowerer, a: Value, b: Value) Value {
        return l.s.fadd(a, b);
    }
    fn sub(l: *Lowerer, a: Value, b: Value) Value {
        return l.s.fsub(a, b);
    }
    fn mul(l: *Lowerer, a: Value, b: Value) Value {
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

    /// Lowers a function call; returns its result.
    fn call(l: *Lowerer, function: u32, args: []const Val) Error!Val {
        const body = l.m.functions.get(function) orelse return error.InvalidSpirv;
        l.depth += 1;
        defer l.depth -= 1;
        if (l.depth > 64) return l.fail(body[0], "recursion is not supported", .{});
        var frame: std.AutoHashMapUnmanaged(u32, Val) = .empty;
        var next_arg: usize = 0;
        var labels: usize = 0;
        for (body[1..]) |inst| {
            const o = inst.operands;
            switch (inst.op) {
                Op.function_parameter => {
                    if (next_arg >= args.len) return error.InvalidSpirv;
                    try frame.put(l.a, o[1], args[next_arg]);
                    next_arg += 1;
                },
                Op.label => {
                    labels += 1;
                    if (labels > 1) return l.fail(inst, "branches (if, loops, switch) are not supported yet", .{});
                },
                Op.@"return", Op.function_end => return .none,
                Op.return_value => return l.get(&frame, o[0]),
                Op.variable => {
                    const ptr_type = l.m.typeOf(o[0]);
                    if (ptr_type != .pointer) return error.InvalidSpirv;
                    const init: Val = if (o.len > 3) try l.get(&frame, o[3]) else try l.zero(ptr_type.pointer.pointee);
                    try frame.put(l.a, o[1], .{ .ptr = .{ .slot = try l.slot(init), .path = &.{} } });
                },
                Op.load => {
                    const p = try l.get(&frame, o[2]);
                    if (p != .ptr) return error.InvalidSpirv;
                    const v = navigate(p.ptr.slot.*, p.ptr.path) orelse return l.fail(inst, "loading from outside a variable", .{});
                    if (v == .none) return l.fail(inst, "this input or built-in is not supported", .{});
                    try frame.put(l.a, o[1], v);
                },
                Op.store => {
                    const p = try l.get(&frame, o[0]);
                    if (p != .ptr) return error.InvalidSpirv;
                    const v = try l.get(&frame, o[1]);
                    p.ptr.slot.* = (try l.withSet(p.ptr.slot.*, p.ptr.path, v)) orelse return l.fail(inst, "storing outside a variable", .{});
                },
                Op.access_chain, Op.in_bounds_access_chain, Op.ptr_access_chain, Op.in_bounds_ptr_access_chain => {
                    const base = try l.get(&frame, o[2]);
                    if (base != .ptr) return error.InvalidSpirv;
                    var indices = o[3..];
                    if (inst.op == Op.ptr_access_chain or inst.op == Op.in_bounds_ptr_access_chain) {
                        if (indices.len == 0 or try l.intOf(inst, try l.get(&frame, indices[0])) != 0)
                            return l.fail(inst, "pointer arithmetic is not supported", .{});
                        indices = indices[1..];
                    }
                    const path = try l.a.alloc(u32, base.ptr.path.len + indices.len);
                    @memcpy(path[0..base.ptr.path.len], base.ptr.path);
                    for (indices, path[base.ptr.path.len..]) |idx, *p| p.* = try l.intOf(inst, try l.get(&frame, idx));
                    try frame.put(l.a, o[1], .{ .ptr = .{ .slot = base.ptr.slot, .path = path } });
                },
                Op.composite_extract => {
                    const v = navigate(try l.get(&frame, o[2]), o[3..]) orelse return error.InvalidSpirv;
                    try frame.put(l.a, o[1], v);
                },
                Op.composite_insert => {
                    const v = (try l.withSet(try l.get(&frame, o[3]), o[4..], try l.get(&frame, o[2]))) orelse return error.InvalidSpirv;
                    try frame.put(l.a, o[1], v);
                },
                Op.composite_construct => {
                    var parts: std.ArrayList(Val) = .empty;
                    const vector = l.m.typeOf(o[0]) == .vector;
                    for (o[2..]) |part| {
                        const v = try l.get(&frame, part);
                        // Vectors may be built from smaller vectors.
                        if (vector and v == .list) try parts.appendSlice(l.a, v.list) else try parts.append(l.a, v);
                    }
                    try frame.put(l.a, o[1], .{ .list = parts.items });
                },
                Op.vector_shuffle => {
                    const x = try l.get(&frame, o[2]);
                    const y = try l.get(&frame, o[3]);
                    const xs: []const Val = if (x == .list) x.list else &.{x};
                    const ys: []const Val = if (y == .list) y.list else &.{y};
                    const out = try l.a.alloc(Val, o.len - 4);
                    for (o[4..], out) |c, *r| r.* = if (c == 0xffffffff) .{ .scalar = l.k(0) } else if (c < xs.len) xs[c] else ys[c - xs.len];
                    try frame.put(l.a, o[1], .{ .list = out });
                },
                Op.copy_object => try frame.put(l.a, o[1], try l.get(&frame, o[2])),
                Op.undef => try frame.put(l.a, o[1], try l.zero(o[0])),
                Op.f_add => try frame.put(l.a, o[1], try l.map2(try l.get(&frame, o[2]), try l.get(&frame, o[3]), add)),
                Op.f_sub => try frame.put(l.a, o[1], try l.map2(try l.get(&frame, o[2]), try l.get(&frame, o[3]), sub)),
                Op.f_mul, Op.vector_times_scalar => try frame.put(l.a, o[1], try l.map2(try l.get(&frame, o[2]), try l.get(&frame, o[3]), mul)),
                Op.f_div => try frame.put(l.a, o[1], try l.map2(try l.get(&frame, o[2]), try l.get(&frame, o[3]), div)),
                Op.f_negate => try frame.put(l.a, o[1], try l.map1(try l.get(&frame, o[2]), neg)),
                Op.dot => try frame.put(l.a, o[1], .{ .scalar = try l.dot(try l.get(&frame, o[2]), try l.get(&frame, o[3])) }),
                Op.convert_s_to_f, Op.convert_u_to_f => {
                    const v = try l.get(&frame, o[2]);
                    if (v != .int) return l.fail(inst, "integer arithmetic is not supported yet", .{});
                    try frame.put(l.a, o[1], .{ .scalar = l.k(@floatFromInt(v.int)) });
                },
                Op.i_add, Op.i_sub, Op.i_mul => {
                    const x = try l.get(&frame, o[2]);
                    const y = try l.get(&frame, o[3]);
                    if (x != .int or y != .int) return l.fail(inst, "integer arithmetic is not supported yet", .{});
                    try frame.put(l.a, o[1], .{ .int = switch (inst.op) {
                        Op.i_add => x.int +% y.int,
                        Op.i_sub => x.int -% y.int,
                        else => x.int *% y.int,
                    } });
                },
                Op.ext_inst => {
                    if (l.m.glsl_std_450 == null or o[2] != l.m.glsl_std_450.?) return l.fail(inst, "unknown extended instruction set", .{});
                    var args_buf: [4]Val = undefined;
                    if (o.len - 4 > args_buf.len) return error.InvalidSpirv;
                    for (o[4..], args_buf[0 .. o.len - 4]) |arg, *x| x.* = try l.get(&frame, arg);
                    try frame.put(l.a, o[1], try l.glsl(inst, o[3], args_buf[0 .. o.len - 4]));
                },
                Op.function_call => {
                    const call_args = try l.a.alloc(Val, o.len - 3);
                    for (o[3..], call_args) |arg, *x| x.* = try l.get(&frame, arg);
                    try frame.put(l.a, o[1], try l.call(o[2], call_args));
                },
                Op.sampled_image => try frame.put(l.a, o[1], .image),
                Op.image_sample_implicit_lod, Op.image_sample_explicit_lod => {
                    if (l.stage != .fragment) return l.fail(inst, "textures can only be sampled in fragment shaders", .{});
                    const coord = try l.get(&frame, o[3]);
                    if (coord != .list or coord.list.len < 2) return l.fail(inst, "texture coordinates must be a Vec2", .{});
                    const texel = l.s.texture(l.asScalar(coord.list[0]), l.asScalar(coord.list[1]));
                    // Texels are B, G, R, A.
                    const out = try l.a.alloc(Val, 4);
                    for (out, [_]u2{ 2, 1, 0, 3 }) |*c, byte| c.* = .{ .scalar = l.s.unpackUnorm8(texel, byte) };
                    try frame.put(l.a, o[1], .{ .list = out });
                },
                Op.select, Op.branch, Op.branch_conditional, Op.selection_merge, Op.loop_merge, Op.@"switch", Op.phi => return l.fail(inst, "branches and selects (if, @select, comparisons) are not supported yet", .{}),
                Op.kill => return l.fail(inst, "discarding fragments is not supported yet", .{}),
                Op.@"unreachable" => return .none,
                else => {
                    if (inst.op >= 164 and inst.op <= 191) return l.fail(inst, "comparisons are not supported yet", .{});
                    return l.fail(inst, "SPIR-V instruction {d} is not supported", .{inst.op});
                },
            }
        }
        return .none;
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
            spirv.StorageClass.uniform_constant => .image,
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
                .source_over => {
                    const dst = s.tlbColorLoad();
                    const alpha = rgba[3];
                    const inv = s.fsub(l.k(1), alpha);
                    const src = [4]Value{ rgba[2], rgba[1], rgba[0], l.k(1) };
                    var out: [4]Value = undefined;
                    for (&out, src, 0..) |*o, x, i| o.* = s.fadd(s.fmul(x, alpha), s.fmul(s.unpackUnorm8(dst, @intCast(i)), inv));
                    s.tlbColor(s.packUnorm8888(out[0], out[1], out[2], out[3]));
                },
            }
        },
    }
}

/// Perspective divide and viewport transform, then the shaded vertex
/// header: Xs|Ys (12.4 fixed point), Zs and 1/Wc.
fn screenHeader(l: *Lowerer, pos: []const Value) void {
    const s = l.s;
    const rcp_w = s.recip(pos[3]);
    const vp = l.iface.uniform_words;
    const xs = s.fmul(s.fmul(pos[0], s.uniform(vp)), rcp_w);
    const ys = s.fmul(s.fmul(pos[1], s.uniform(vp + 1)), rcp_w);
    const half = l.k(0.5);
    const zs = s.fadd(s.fmul(s.fmul(pos[2], half), rcp_w), half);
    s.vpmWrite(s.packScreenXy(xs, ys));
    s.vpmWrite(zs);
    s.vpmWrite(rcp_w);
}
