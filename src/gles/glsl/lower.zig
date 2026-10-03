//! Lowers a parsed GLSL shader to the vc4 compiler's SSA builder.
//!
//! Every GLSL value becomes one compiler value per scalar component
//! (vectors and matrices are split up), so code generation and register
//! allocation work on scalars. Constants are folded as values are built,
//! which removes things like `x * 1.0` and the perspective divide when w is
//! a constant 1.
//!
//! The linker (program.zig) supplies the interface: where each uniform
//! lives in the uniform array, which attributes to read and in what order,
//! and the varyings the fragment shader expects.

const std = @import("std");
const vc4 = @import("vc4");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const compiler = vc4.compiler;
const Value = compiler.Value;
const Type = parser.Type;
const Ast = parser.Ast;
const ExprIndex = parser.ExprIndex;

pub const Diagnostic = lexer.Diagnostic;
pub const Error = error{SemanticError};

pub const UniformSlot = struct {
    name: []const u8,
    type: Type,
    /// Index of the first component in the program's uniform array
    /// (unused for samplers).
    base: u32,
};

pub const Slot = struct {
    name: []const u8,
    type: Type,
};

pub const Interface = struct {
    uniforms: []const UniformSlot,
    /// Vertex and coordinate shaders: the attributes to read from the VPM,
    /// in order. Attributes the shader declares but that are not listed
    /// read as zero (the coordinate shader omits those it does not need).
    attributes: []const Slot = &.{},
    /// The fragment shader's varyings, in the order they are interpolated.
    varyings: []const Slot,
    /// Index of the viewport scale uniforms (x, then y).
    viewport_uniform: u32,
    /// Fragment shaders: write the fragment's depth for depth testing.
    depth_write: bool = false,
};

const Val = struct {
    ty: Type,
    c: [16]Value = undefined,
    /// For sampler values: the uniform's name.
    sampler: []const u8 = "",

    fn n(v: Val) u8 {
        return v.ty.components();
    }
};

const VarKind = enum { attribute, uniform, varying_in, varying_out, local, constant, output };

const Var = struct {
    name: []const u8,
    ty: Type,
    kind: VarKind,
    val: Val,
    written: bool,
    uniform_base: u32 = 0,
};

const max_vars = 256;

const Lowerer = struct {
    s: *compiler.Shader,
    ast: *const Ast,
    stage: compiler.Stage,
    iface: *const Interface,
    diag: *Diagnostic,
    vars: [max_vars]Var = undefined,
    nvars: usize = 0,
    /// First variable of the innermost block scope.
    scope_start: usize = 0,

    fn failAt(l: *Lowerer, token: u32, message: []const u8) Error {
        const t = l.ast.tokens[@min(token, l.ast.tokens.len - 1)];
        l.diag.* = .{ .line = t.line, .column = t.column, .message = message };
        return error.SemanticError;
    }

    fn fail(l: *Lowerer, e: ExprIndex, message: []const u8) Error {
        return l.failAt(l.ast.expr_tokens.items[e], message);
    }

    fn lookup(l: *Lowerer, name: []const u8) ?*Var {
        var i = l.nvars;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, l.vars[i].name, name)) return &l.vars[i];
        }
        return null;
    }

    fn declare(l: *Lowerer, token: u32, v: Var, scope_start: usize) Error!*Var {
        for (l.vars[scope_start..l.nvars]) |existing| {
            if (std.mem.eql(u8, existing.name, v.name)) return l.failAt(token, "redefinition of a variable");
        }
        if (std.mem.startsWith(u8, v.name, "gl_")) return l.failAt(token, "names starting with gl_ are reserved");
        if (l.nvars == max_vars) return l.failAt(token, "too many variables");
        l.vars[l.nvars] = v;
        l.nvars += 1;
        return &l.vars[l.nvars - 1];
    }

    // --- Scalar operations with constant folding --------------------------------

    fn constOf(l: *const Lowerer, v: Value) ?f32 {
        const inst = l.s.insts[@intFromEnum(v)];
        return if (inst.op == .constant) @bitCast(inst.imm) else null;
    }

    fn k(l: *Lowerer, x: f32) Value {
        return l.s.constantF(x);
    }

    fn add(l: *Lowerer, a: Value, b: Value) Value {
        const ca = l.constOf(a);
        const cb = l.constOf(b);
        if (ca != null and cb != null) return l.k(ca.? + cb.?);
        if (ca != null and ca.? == 0) return b;
        if (cb != null and cb.? == 0) return a;
        return l.s.fadd(a, b);
    }

    fn sub(l: *Lowerer, a: Value, b: Value) Value {
        const ca = l.constOf(a);
        const cb = l.constOf(b);
        if (ca != null and cb != null) return l.k(ca.? - cb.?);
        if (cb != null and cb.? == 0) return a;
        return l.s.fsub(a, b);
    }

    fn mul(l: *Lowerer, a: Value, b: Value) Value {
        const ca = l.constOf(a);
        const cb = l.constOf(b);
        if (ca != null and cb != null) return l.k(ca.? * cb.?);
        if (ca != null and ca.? == 1) return b;
        if (cb != null and cb.? == 1) return a;
        return l.s.fmul(a, b);
    }

    fn unaryOp(l: *Lowerer, op: compiler.Op, a: Value, comptime fold: fn (f32) f32) Value {
        if (l.constOf(a)) |c| return l.k(fold(c));
        return l.s.unary(op, a);
    }

    fn recip(l: *Lowerer, a: Value) Value {
        return l.unaryOp(.recip, a, struct {
            fn f(x: f32) f32 {
                return 1.0 / x;
            }
        }.f);
    }
    fn rsqrt(l: *Lowerer, a: Value) Value {
        return l.unaryOp(.rsqrt, a, struct {
            fn f(x: f32) f32 {
                return 1.0 / @sqrt(x);
            }
        }.f);
    }
    fn exp2(l: *Lowerer, a: Value) Value {
        return l.unaryOp(.exp2, a, struct {
            fn f(x: f32) f32 {
                return std.math.exp2(x);
            }
        }.f);
    }
    fn log2(l: *Lowerer, a: Value) Value {
        return l.unaryOp(.log2, a, struct {
            fn f(x: f32) f32 {
                return std.math.log2(x);
            }
        }.f);
    }

    fn binop(l: *Lowerer, op: compiler.Op, a: Value, b: Value, comptime fold: fn (f32, f32) f32) Value {
        if (l.constOf(a)) |ca| if (l.constOf(b)) |cb| return l.k(fold(ca, cb));
        return l.s.binary(op, a, b);
    }

    fn fmin(l: *Lowerer, a: Value, b: Value) Value {
        return l.binop(.fmin, a, b, struct {
            fn f(x: f32, y: f32) f32 {
                return @min(x, y);
            }
        }.f);
    }
    fn fmax(l: *Lowerer, a: Value, b: Value) Value {
        return l.binop(.fmax, a, b, struct {
            fn f(x: f32, y: f32) f32 {
                return @max(x, y);
            }
        }.f);
    }
    fn fabs(l: *Lowerer, a: Value) Value {
        return l.binop(.fmaxabs, a, a, struct {
            fn f(x: f32, _: f32) f32 {
                return @abs(x);
            }
        }.f);
    }

    /// Balanced sum, matching the order hand-written code tends to use:
    /// ((a + b) + (c + d)).
    fn sum(l: *Lowerer, terms: []const Value) Value {
        if (terms.len == 1) return terms[0];
        const half = terms.len / 2;
        return l.add(l.sum(terms[0..half]), l.sum(terms[half..]));
    }

    // --- Values ------------------------------------------------------------------

    fn scalar(ty: Type, v: Value) Val {
        var r: Val = .{ .ty = ty };
        r.c[0] = v;
        return r;
    }

    fn broadcast(l: *Lowerer, e: ExprIndex, v: Val, ty: Type) Error!Val {
        if (v.ty == ty) return v;
        if (v.ty != .float) return l.fail(e, "type mismatch");
        var r: Val = .{ .ty = ty };
        for (r.c[0..ty.components()]) |*c| c.* = v.c[0];
        return r;
    }

    fn requireFloatish(l: *Lowerer, e: ExprIndex, v: Val) Error!void {
        switch (v.ty) {
            .float, .vec2, .vec3, .vec4, .mat2, .mat3, .mat4 => {},
            .int => return l.fail(e, "integer arithmetic is not supported (GLSL ES has no implicit int to float conversion; write 1.0 rather than 1)"),
            else => return l.fail(e, "operand must be a float, vector or matrix"),
        }
    }

    fn arithmetic(l: *Lowerer, e: ExprIndex, op: lexer.Tag, a: Val, b: Val) Error!Val {
        try l.requireFloatish(e, a);
        try l.requireFloatish(e, b);
        if (op == .star) {
            if (a.ty.isMatrix() and b.ty == a.ty) return l.matMul(a, b);
            if (a.ty.isMatrix() and b.ty.isVector()) {
                if (b.n() != a.ty.matrixSize()) return l.fail(e, "matrix and vector sizes differ");
                return l.matVec(a, b);
            }
            if (a.ty.isVector() and b.ty.isMatrix()) {
                if (a.n() != b.ty.matrixSize()) return l.fail(e, "vector and matrix sizes differ");
                return l.vecMat(a, b);
            }
        }
        const ty = if (a.ty == .float) b.ty else a.ty;
        if (a.ty != .float and b.ty != .float and a.ty != b.ty) return l.fail(e, "type mismatch");
        const x = try l.broadcast(e, a, ty);
        const y = try l.broadcast(e, b, ty);
        var r: Val = .{ .ty = ty };
        for (0..ty.components()) |i| r.c[i] = switch (op) {
            .plus => l.add(x.c[i], y.c[i]),
            .minus => l.sub(x.c[i], y.c[i]),
            .star => l.mul(x.c[i], y.c[i]),
            .slash => l.mul(x.c[i], l.recip(y.c[i])),
            else => unreachable,
        };
        return r;
    }

    fn matVec(l: *Lowerer, m: Val, v: Val) Val {
        const size = m.ty.matrixSize();
        var r: Val = .{ .ty = Type.vector(size) };
        for (0..size) |row| {
            var terms: [4]Value = undefined;
            for (0..size) |col| terms[col] = l.mul(v.c[col], m.c[col * size + row]);
            r.c[row] = l.sum(terms[0..size]);
        }
        return r;
    }

    fn vecMat(l: *Lowerer, v: Val, m: Val) Val {
        const size = m.ty.matrixSize();
        var r: Val = .{ .ty = Type.vector(size) };
        for (0..size) |col| {
            var terms: [4]Value = undefined;
            for (0..size) |row| terms[row] = l.mul(v.c[row], m.c[col * size + row]);
            r.c[col] = l.sum(terms[0..size]);
        }
        return r;
    }

    fn matMul(l: *Lowerer, a: Val, b: Val) Val {
        const size = a.ty.matrixSize();
        var r: Val = .{ .ty = a.ty };
        for (0..size) |col| for (0..size) |row| {
            var terms: [4]Value = undefined;
            for (0..size) |kk| terms[kk] = l.mul(a.c[kk * size + row], b.c[col * size + kk]);
            r.c[col * size + row] = l.sum(terms[0..size]);
        };
        return r;
    }

    fn dot(l: *Lowerer, a: Val, b: Val) Value {
        var terms: [4]Value = undefined;
        for (0..a.n()) |i| terms[i] = l.mul(a.c[i], b.c[i]);
        return l.sum(terms[0..a.n()]);
    }

    // --- Expressions -------------------------------------------------------------

    fn expr(l: *Lowerer, e: ExprIndex) Error!Val {
        switch (l.ast.exprs.items[e]) {
            .float_lit => |v| return scalar(.float, l.k(v)),
            .int_lit => |v| return scalar(.int, l.k(@floatFromInt(v))),
            .bool_lit => |v| return scalar(.bool, l.k(if (v) 1 else 0)),
            .ident => |name| return l.readVar(e, name),
            .unary => |u| {
                const v = try l.expr(u.operand);
                if (u.op == .bang) return l.fail(e, "boolean operators are not supported yet");
                if (u.op == .plus) return v;
                if (v.ty == .int) {
                    if (l.constOf(v.c[0])) |c| return scalar(.int, l.k(-c));
                }
                try l.requireFloatish(e, v);
                var r: Val = .{ .ty = v.ty };
                for (0..v.n()) |i| r.c[i] = l.sub(l.k(0), v.c[i]);
                return r;
            },
            .binary => |b| switch (b.op) {
                .plus, .minus, .star, .slash => return l.arithmetic(e, b.op, try l.expr(b.lhs), try l.expr(b.rhs)),
                else => return l.fail(e, "comparison and logical operators are not supported yet"),
            },
            .call => |c| {
                if (Type.fromName(c.callee)) |ty| return l.construct(e, ty, l.ast.list(c.args));
                return l.builtin(e, c.callee, l.ast.list(c.args));
            },
            .field => |f| return l.swizzle(e, try l.expr(f.operand), f.name),
            .index => |ix| return l.index(e, try l.expr(ix.operand), ix.index),
            .assign => |a| return l.assign(e, a.op, a.lhs, a.rhs),
        }
    }

    fn readVar(l: *Lowerer, e: ExprIndex, name: []const u8) Error!Val {
        const v = l.lookup(name) orelse {
            if (std.mem.startsWith(u8, name, "gl_")) return l.fail(e, "this built-in variable is not supported");
            return l.fail(e, "undeclared identifier");
        };
        switch (v.kind) {
            .uniform => {
                if (v.ty == .sampler2D) return .{ .ty = .sampler2D, .sampler = v.name };
                // Read uniforms at each use: a uniform read only once can be
                // fed straight into the instruction that needs it.
                var r: Val = .{ .ty = v.ty };
                for (0..v.ty.components()) |i| r.c[i] = l.s.uniform(v.uniform_base + @as(u32, @intCast(i)));
                return r;
            },
            .varying_out, .output, .local => if (!v.written) return l.fail(e, "variable is read before it is written"),
            else => {},
        }
        return v.val;
    }

    fn construct(l: *Lowerer, e: ExprIndex, ty: Type, args: []const u32) Error!Val {
        if (ty == .void or ty == .sampler2D) return l.fail(e, "cannot construct this type");
        if (args.len == 0) return l.fail(e, "constructor needs arguments");
        var comps: [32]Value = undefined;
        var ncomps: usize = 0;
        var single: ?Val = null;
        const needed = ty.components();
        for (args, 0..) |arg, i| {
            const v = try l.expr(arg);
            if (v.ty == .sampler2D or v.ty == .void) return l.fail(arg, "invalid constructor argument");
            if (args.len == 1) single = v;
            if (i > 0 and ncomps >= needed) return l.fail(arg, "too many arguments to constructor");
            for (v.c[0..v.n()]) |c| {
                if (ncomps == comps.len) return l.fail(arg, "too many components");
                comps[ncomps] = c;
                ncomps += 1;
            }
        }
        var r: Val = .{ .ty = ty };
        switch (ty) {
            .float, .bool => r.c[0] = comps[0],
            .int => {
                const c = l.constOf(comps[0]) orelse return l.fail(e, "int() of a non-constant is not supported");
                r.c[0] = l.k(@trunc(c));
            },
            .vec2, .vec3, .vec4 => {
                if (ncomps == 1) {
                    for (r.c[0..needed]) |*c| c.* = comps[0];
                } else {
                    if (ncomps < needed) return l.fail(e, "not enough components for constructor");
                    @memcpy(r.c[0..needed], comps[0..needed]);
                }
            },
            .mat2, .mat3, .mat4 => {
                const size = ty.matrixSize();
                if (single) |sv| if (sv.ty == .float or sv.ty == .int) {
                    for (0..size) |col| for (0..size) |row| {
                        r.c[col * size + row] = if (col == row) comps[0] else l.k(0);
                    };
                    return r;
                };
                if (single) |sv| if (sv.ty.isMatrix()) {
                    // Resize: copy the overlap, identity elsewhere.
                    const src = sv.ty.matrixSize();
                    for (0..size) |col| for (0..size) |row| {
                        r.c[col * size + row] = if (col < src and row < src) sv.c[col * src + row] else l.k(if (col == row) 1 else 0);
                    };
                    return r;
                };
                if (ncomps != needed) return l.fail(e, "wrong number of components for matrix constructor");
                @memcpy(r.c[0..needed], comps[0..needed]);
            },
            else => unreachable,
        }
        return r;
    }

    fn swizzleIndices(name: []const u8, n: u8, out: *[4]u8) ?usize {
        if (name.len == 0 or name.len > 4) return null;
        const sets = [_][]const u8{ "xyzw", "rgba", "stpq" };
        for (sets) |set| {
            if (std.mem.indexOfScalar(u8, set, name[0]) == null) continue;
            for (name, 0..) |ch, i| {
                const idx = std.mem.indexOfScalar(u8, set, ch) orelse return null;
                if (idx >= n) return null;
                out[i] = @intCast(idx);
            }
            return name.len;
        }
        return null;
    }

    fn swizzle(l: *Lowerer, e: ExprIndex, v: Val, name: []const u8) Error!Val {
        if (!v.ty.isVector()) return l.fail(e, "swizzles need a vector");
        var idx: [4]u8 = undefined;
        const len = swizzleIndices(name, v.n(), &idx) orelse return l.fail(e, "invalid swizzle");
        var r: Val = .{ .ty = Type.vector(@intCast(len)) };
        for (idx[0..len], 0..) |src, i| r.c[i] = v.c[src];
        return r;
    }

    fn constIndex(l: *Lowerer, ie: ExprIndex, limit: u8) Error!u8 {
        const iv = try l.expr(ie);
        if (iv.ty != .int) return l.fail(ie, "index must be an integer");
        const c = l.constOf(iv.c[0]) orelse return l.fail(ie, "index must be a constant");
        if (c < 0 or c >= @as(f32, @floatFromInt(limit))) return l.fail(ie, "index out of range");
        return @intFromFloat(c);
    }

    fn index(l: *Lowerer, e: ExprIndex, v: Val, ie: ExprIndex) Error!Val {
        if (v.ty.isMatrix()) {
            const size = v.ty.matrixSize();
            const col = try l.constIndex(ie, size);
            var r: Val = .{ .ty = Type.vector(size) };
            @memcpy(r.c[0..size], v.c[col * size ..][0..size]);
            return r;
        }
        if (v.ty.isVector()) return scalar(.float, v.c[try l.constIndex(ie, v.n())]);
        return l.fail(e, "only vectors and matrices can be indexed");
    }

    fn arity(l: *Lowerer, e: ExprIndex, args: []const u32, n: usize) Error!void {
        if (args.len != n) return l.fail(e, "wrong number of arguments");
    }

    fn builtin(l: *Lowerer, e: ExprIndex, name: []const u8, args: []const u32) Error!Val {
        var a: [3]Val = undefined;
        if (args.len > 3) return l.fail(e, "too many arguments");
        for (args, 0..) |arg, i| a[i] = try l.expr(arg);

        const Unary = enum { radians, degrees, abs, sqrt, inversesqrt, exp2, log2, exp, log };
        if (std.meta.stringToEnum(Unary, name)) |f| {
            try l.arity(e, args, 1);
            try l.requireFloatish(args[0], a[0]);
            if (a[0].ty.isMatrix()) return l.fail(args[0], "argument must be a float or vector");
            var r: Val = .{ .ty = a[0].ty };
            for (0..a[0].n()) |i| {
                const x = a[0].c[i];
                r.c[i] = switch (f) {
                    .radians => l.mul(x, l.k(std.math.pi / 180.0)),
                    .degrees => l.mul(x, l.k(180.0 / std.math.pi)),
                    .abs => l.fabs(x),
                    .sqrt => l.recip(l.rsqrt(x)),
                    .inversesqrt => l.rsqrt(x),
                    .exp2 => l.exp2(x),
                    .log2 => l.log2(x),
                    .exp => l.exp2(l.mul(x, l.k(std.math.log2e))),
                    .log => l.mul(l.log2(x), l.k(std.math.ln2)),
                };
            }
            return r;
        }

        const Binary = enum { min, max, pow };
        if (std.meta.stringToEnum(Binary, name)) |f| {
            try l.arity(e, args, 2);
            try l.requireFloatish(args[0], a[0]);
            try l.requireFloatish(args[1], a[1]);
            const y = try l.broadcast(args[1], a[1], a[0].ty);
            var r: Val = .{ .ty = a[0].ty };
            for (0..a[0].n()) |i| r.c[i] = switch (f) {
                .min => l.fmin(a[0].c[i], y.c[i]),
                .max => l.fmax(a[0].c[i], y.c[i]),
                .pow => l.exp2(l.mul(l.log2(a[0].c[i]), y.c[i])),
            };
            return r;
        }

        if (std.mem.eql(u8, name, "clamp") or std.mem.eql(u8, name, "mix")) {
            try l.arity(e, args, 3);
            for (0..3) |i| try l.requireFloatish(args[i], a[i]);
            const b = try l.broadcast(args[1], a[1], a[0].ty);
            const t = try l.broadcast(args[2], a[2], a[0].ty);
            var r: Val = .{ .ty = a[0].ty };
            for (0..a[0].n()) |i| r.c[i] = if (name[0] == 'c')
                l.fmin(l.fmax(a[0].c[i], b.c[i]), t.c[i])
            else
                l.add(a[0].c[i], l.mul(l.sub(b.c[i], a[0].c[i]), t.c[i]));
            return r;
        }

        if (std.mem.eql(u8, name, "dot") or std.mem.eql(u8, name, "distance")) {
            try l.arity(e, args, 2);
            if (a[0].ty != a[1].ty or !(a[0].ty == .float or a[0].ty.isVector())) return l.fail(e, "arguments must be floats or vectors of the same size");
            if (name[0] == 'd' and name[1] == 'o') return scalar(.float, l.dot(a[0], a[1]));
            const diff = try l.arithmetic(e, .minus, a[0], a[1]);
            return scalar(.float, l.recip(l.rsqrt(l.dot(diff, diff))));
        }

        if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "normalize")) {
            try l.arity(e, args, 1);
            if (!(a[0].ty == .float or a[0].ty.isVector())) return l.fail(e, "argument must be a float or vector");
            const inv_len = l.rsqrt(l.dot(a[0], a[0]));
            if (name[0] == 'l') return scalar(.float, l.recip(inv_len));
            var r: Val = .{ .ty = a[0].ty };
            for (0..a[0].n()) |i| r.c[i] = l.mul(a[0].c[i], inv_len);
            return r;
        }

        if (std.mem.eql(u8, name, "cross")) {
            try l.arity(e, args, 2);
            if (a[0].ty != .vec3 or a[1].ty != .vec3) return l.fail(e, "cross() takes two vec3s");
            var r: Val = .{ .ty = .vec3 };
            for (0..3) |i| {
                const j = (i + 1) % 3;
                const kk = (i + 2) % 3;
                r.c[i] = l.sub(l.mul(a[0].c[j], a[1].c[kk]), l.mul(a[0].c[kk], a[1].c[j]));
            }
            return r;
        }

        if (std.mem.eql(u8, name, "texture2D")) {
            if (l.stage != .fragment) return l.fail(e, "texture sampling in vertex shaders is not supported yet");
            if (args.len == 3) return l.fail(e, "texture2D() with a bias is not supported yet");
            try l.arity(e, args, 2);
            if (a[0].ty != .sampler2D) return l.fail(args[0], "first argument must be a sampler2D");
            if (a[1].ty != .vec2) return l.fail(args[1], "texture coordinate must be a vec2");
            const texel = l.s.texture(a[1].c[0], a[1].c[1]);
            // Texels are stored B, G, R, A.
            var r: Val = .{ .ty = .vec4 };
            r.c[0] = l.s.unpackUnorm8(texel, 2);
            r.c[1] = l.s.unpackUnorm8(texel, 1);
            r.c[2] = l.s.unpackUnorm8(texel, 0);
            r.c[3] = l.s.unpackUnorm8(texel, 3);
            return r;
        }

        const known = [_][]const u8{ "sin", "cos", "tan", "asin", "acos", "atan", "sign", "floor", "ceil", "fract", "mod", "step", "smoothstep", "reflect", "refract", "faceforward", "matrixCompMult", "lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual", "equal", "notEqual", "any", "all", "not", "texture2DProj", "texture2DLod", "texture2DProjLod", "textureCube", "textureCubeLod" };
        for (known) |kn| if (std.mem.eql(u8, name, kn)) return l.fail(e, "this built-in function is not supported yet");
        return l.fail(e, "unknown function");
    }

    // --- Assignment ----------------------------------------------------------------

    const Target = struct {
        v: *Var,
        /// Component indices written.
        comps: [16]u8,
        n: u8,
        ty: Type,
    };

    fn target(l: *Lowerer, e: ExprIndex) Error!Target {
        switch (l.ast.exprs.items[e]) {
            .ident => |name| {
                const v = l.lookup(name) orelse return l.fail(e, "undeclared identifier");
                switch (v.kind) {
                    .local, .varying_out, .output => {},
                    .constant => return l.fail(e, "cannot assign to a constant"),
                    else => return l.fail(e, "cannot assign to this variable"),
                }
                var t: Target = .{ .v = v, .comps = undefined, .n = v.ty.components(), .ty = v.ty };
                for (0..t.n) |i| t.comps[i] = @intCast(i);
                return t;
            },
            .field => |f| {
                var t = try l.target(f.operand);
                if (!t.ty.isVector()) return l.fail(e, "swizzles need a vector");
                var idx: [4]u8 = undefined;
                const len = swizzleIndices(f.name, t.n, &idx) orelse return l.fail(e, "invalid swizzle");
                for (idx[0..len], 0..) |a, i| for (idx[0..i]) |b| if (a == b) return l.fail(e, "swizzle assigns a component twice");
                var comps: [16]u8 = undefined;
                for (idx[0..len], 0..) |src, i| comps[i] = t.comps[src];
                t.comps = comps;
                t.n = @intCast(len);
                t.ty = Type.vector(@intCast(len));
                return t;
            },
            .index => |ix| {
                var t = try l.target(ix.operand);
                if (t.ty.isMatrix()) {
                    const size = t.ty.matrixSize();
                    const col = try l.constIndex(ix.index, size);
                    var comps: [16]u8 = undefined;
                    for (0..size) |i| comps[i] = t.comps[col * size + i];
                    t.comps = comps;
                    t.n = size;
                    t.ty = Type.vector(size);
                } else if (t.ty.isVector()) {
                    const i = try l.constIndex(ix.index, t.n);
                    t.comps[0] = t.comps[i];
                    t.n = 1;
                    t.ty = .float;
                } else return l.fail(e, "only vectors and matrices can be indexed");
                return t;
            },
            else => return l.fail(e, "cannot assign to this expression"),
        }
    }

    fn assign(l: *Lowerer, e: ExprIndex, op: lexer.Tag, lhs: ExprIndex, rhs: ExprIndex) Error!Val {
        const t = try l.target(lhs);
        var value = try l.expr(rhs);
        if (op != .equal) {
            if (!t.v.written) return l.fail(lhs, "variable is read before it is written");
            var cur: Val = .{ .ty = t.ty };
            for (0..t.n) |i| cur.c[i] = t.v.val.c[t.comps[i]];
            const arith: lexer.Tag = switch (op) {
                .plus_equal => .plus,
                .minus_equal => .minus,
                .star_equal => .star,
                .slash_equal => .slash,
                else => unreachable,
            };
            value = try l.arithmetic(e, arith, cur, value);
        }
        if (value.ty != t.ty) return l.fail(e, "type mismatch in assignment");
        // A partial write to a variable that was never written leaves the
        // other components zero.
        if (!t.v.written) {
            for (0..t.v.ty.components()) |i| t.v.val.c[i] = l.k(0);
        }
        for (0..t.n) |i| t.v.val.c[t.comps[i]] = value.c[i];
        t.v.written = true;
        return value;
    }

    // --- Statements ------------------------------------------------------------

    /// Returns false after a return statement.
    fn stmt(l: *Lowerer, si: u32) Error!bool {
        switch (l.ast.stmts.items[si]) {
            .decl => |d| {
                if (d.type == .void or d.type == .sampler2D) return l.failAt(d.token, "invalid type for a local variable");
                var v: Var = .{ .name = d.name, .ty = d.type, .kind = if (d.is_const) .constant else .local, .val = .{ .ty = d.type }, .written = false };
                if (d.init) |ie| {
                    const iv = try l.expr(ie);
                    if (iv.ty != d.type) return l.fail(ie, "initializer type does not match (GLSL ES has no implicit conversions)");
                    v.val = iv;
                    v.written = true;
                }
                _ = try l.declare(d.token, v, l.scope_start);
                return true;
            },
            .expr => |ei| {
                _ = try l.expr(ei);
                return true;
            },
            .block => |r| return l.block(r),
            .@"return" => return false,
        }
    }

    fn block(l: *Lowerer, r: parser.Range) Error!bool {
        const saved_vars = l.nvars;
        const saved_scope = l.scope_start;
        l.scope_start = l.nvars;
        defer {
            l.nvars = saved_vars;
            l.scope_start = saved_scope;
        }
        for (l.ast.list(r)) |si| if (!try l.stmt(si)) return false;
        return true;
    }

    // --- Shader structure --------------------------------------------------------

    fn uniformBase(l: *Lowerer, g: parser.Global) Error!u32 {
        for (l.iface.uniforms) |u| if (std.mem.eql(u8, u.name, g.name)) {
            if (u.type != g.type) return l.failAt(g.token, "uniform declared with different types in the two shaders");
            return u.base;
        };
        return l.failAt(g.token, "uniform missing from the program interface");
    }

    fn run(l: *Lowerer) Error!void {
        const s = l.s;
        const is_vertex = l.stage != .fragment;

        // Attributes, in VPM order.
        if (is_vertex) {
            for (l.iface.attributes) |a| {
                var v: Val = .{ .ty = a.type };
                for (0..a.type.components()) |i| v.c[i] = s.vpmRead();
                l.vars[l.nvars] = .{ .name = a.name, .ty = a.type, .kind = .attribute, .val = v, .written = true };
                l.nvars += 1;
            }
        } else {
            for (l.iface.varyings) |vy| {
                var v: Val = .{ .ty = vy.type };
                for (0..vy.type.components()) |i| v.c[i] = s.varying();
                l.vars[l.nvars] = .{ .name = vy.name, .ty = vy.type, .kind = .varying_in, .val = v, .written = true };
                l.nvars += 1;
            }
        }

        for (l.ast.globals.items) |g| {
            switch (g.qualifier) {
                .attribute => {
                    if (!is_vertex) return l.failAt(g.token, "attributes are only allowed in vertex shaders");
                    if (g.type == .sampler2D or g.type == .bool or g.type == .int or g.type.isMatrix())
                        return l.failAt(g.token, "attributes must be float or vector types");
                    if (l.lookup(g.name) == null) {
                        // Not read by this stage: the value is never needed.
                        var v: Val = .{ .ty = g.type };
                        for (0..g.type.components()) |i| v.c[i] = l.k(0);
                        _ = try l.declare(g.token, .{ .name = g.name, .ty = g.type, .kind = .attribute, .val = v, .written = true }, 0);
                    }
                },
                .uniform => _ = try l.declare(g.token, .{ .name = g.name, .ty = g.type, .kind = .uniform, .val = .{ .ty = g.type }, .written = true, .uniform_base = try l.uniformBase(g) }, 0),
                .varying => {
                    if (g.type == .sampler2D or g.type == .bool or g.type == .int) return l.failAt(g.token, "varyings must be float, vector or matrix types");
                    if (is_vertex) {
                        _ = try l.declare(g.token, .{ .name = g.name, .ty = g.type, .kind = .varying_out, .val = .{ .ty = g.type }, .written = false }, 0);
                    } else if (l.lookup(g.name) == null) {
                        return l.failAt(g.token, "varying missing from the program interface");
                    }
                },
                .@"const", .none => {
                    if (g.qualifier == .none) return l.failAt(g.token, "global variables must be const, attribute, uniform or varying");
                    const iv = try l.expr(g.init.?);
                    if (iv.ty != g.type) return l.fail(g.init.?, "initializer type does not match");
                    _ = try l.declare(g.token, .{ .name = g.name, .ty = g.type, .kind = .constant, .val = iv, .written = true }, 0);
                },
            }
        }

        // Built-in outputs.
        const out_name = if (is_vertex) "gl_Position" else "gl_FragColor";
        l.vars[l.nvars] = .{ .name = out_name, .ty = .vec4, .kind = .output, .val = .{ .ty = .vec4 }, .written = false };
        const out_index = l.nvars;
        l.nvars += 1;

        l.scope_start = l.nvars;
        const body = l.ast.main_body.?;
        for (l.ast.list(body)) |si| if (!try l.stmt(si)) break;

        const out = l.vars[out_index];
        if (!out.written) {
            const last = l.ast.tokens.len - 1;
            return l.failAt(@intCast(last), if (is_vertex) "the vertex shader must write gl_Position" else "the fragment shader must write gl_FragColor");
        }

        switch (l.stage) {
            .vertex => {
                l.screenHeader(out.val);
                for (l.iface.varyings) |vy| {
                    const v = l.lookup(vy.name);
                    for (0..vy.type.components()) |i| {
                        s.vpmWrite(if (v != null and v.?.written) v.?.val.c[i] else l.k(0));
                    }
                }
            },
            .coordinate => {
                for (out.val.c[0..4]) |c| s.vpmWrite(c);
                l.screenHeader(out.val);
            },
            .fragment => {
                if (l.iface.depth_write) s.tlbZ(s.fragZ());
                // The render target is B8G8R8A8.
                const c = out.val.c;
                s.tlbColor(s.packUnorm8888(c[2], c[1], c[0], c[3]));
            },
        }
    }

    /// Perspective divide and viewport transform, then the shaded vertex
    /// header: Xs|Ys (12.4 fixed point), Zs and 1/Wc.
    fn screenHeader(l: *Lowerer, pos: Val) void {
        const s = l.s;
        const rcp_w = l.recip(pos.c[3]);
        const vp = l.iface.viewport_uniform;
        const xs = l.mul(l.mul(pos.c[0], s.uniform(vp)), rcp_w);
        const ys = l.mul(l.mul(pos.c[1], s.uniform(vp + 1)), rcp_w);
        const half = l.k(0.5);
        const zs = l.add(l.mul(l.mul(pos.c[2], half), rcp_w), half);
        s.vpmWrite(s.packScreenXy(xs, ys));
        s.vpmWrite(zs);
        s.vpmWrite(rcp_w);
    }
};

/// Lowers `ast` for `stage` into `shader` (which must be empty).
pub fn lower(ast: *const Ast, stage: compiler.Stage, iface: *const Interface, shader: *compiler.Shader, diag: *Diagnostic) Error!void {
    shader.* = compiler.Shader.init(stage);
    var l: Lowerer = .{ .s = shader, .ast = ast, .stage = stage, .iface = iface, .diag = diag };
    try l.run();
}
