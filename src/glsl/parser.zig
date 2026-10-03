//! Parser for the supported subset of GLSL ES 1.00, producing an AST.
//!
//! Supported: global `attribute`, `uniform`, `varying` and `const`
//! declarations, `precision` statements, and a `void main()` function
//! containing local declarations, assignments and expression statements.
//! Other functions, control flow, arrays and structs are rejected with a
//! clear error for now.

const std = @import("std");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const Tag = lexer.Tag;

pub const Type = enum {
    void,
    bool,
    int,
    float,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,
    mat4,
    sampler2D,

    pub fn fromName(name: []const u8) ?Type {
        return std.meta.stringToEnum(Type, name);
    }

    /// Number of scalar components.
    pub fn components(t: Type) u8 {
        return switch (t) {
            .void, .sampler2D => 0,
            .bool, .int, .float => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            .mat2 => 4,
            .mat3 => 9,
            .mat4 => 16,
        };
    }

    pub fn isVector(t: Type) bool {
        return t == .vec2 or t == .vec3 or t == .vec4;
    }

    pub fn isMatrix(t: Type) bool {
        return t == .mat2 or t == .mat3 or t == .mat4;
    }

    /// Columns (and rows) of a square matrix.
    pub fn matrixSize(t: Type) u8 {
        return switch (t) {
            .mat2 => 2,
            .mat3 => 3,
            .mat4 => 4,
            else => 0,
        };
    }

    pub fn vector(n: u8) Type {
        return switch (n) {
            1 => .float,
            2 => .vec2,
            3 => .vec3,
            4 => .vec4,
            else => unreachable,
        };
    }
};

pub const Qualifier = enum { none, attribute, uniform, varying, @"const" };

pub const ExprIndex = u32;

pub const Range = struct { start: u32, len: u32 };

pub const Expr = union(enum) {
    float_lit: f32,
    int_lit: i32,
    bool_lit: bool,
    ident: []const u8,
    binary: struct { op: Tag, lhs: ExprIndex, rhs: ExprIndex },
    unary: struct { op: Tag, operand: ExprIndex },
    /// Function call or type constructor; args index `extra`.
    call: struct { callee: []const u8, args: Range },
    field: struct { operand: ExprIndex, name: []const u8 },
    index: struct { operand: ExprIndex, index: ExprIndex },
    assign: struct { op: Tag, lhs: ExprIndex, rhs: ExprIndex },
};

pub const Stmt = union(enum) {
    decl: struct { type: Type, is_const: bool, name: []const u8, init: ?ExprIndex, token: u32 },
    expr: ExprIndex,
    /// Statements are indexed by `extra`.
    block: Range,
    @"return",
};

pub const Global = struct {
    qualifier: Qualifier,
    type: Type,
    name: []const u8,
    init: ?ExprIndex,
    token: u32,
};

pub const Ast = struct {
    tokens: []const Token,
    exprs: std.ArrayList(Expr) = .empty,
    /// Token index of each expression, for error messages.
    expr_tokens: std.ArrayList(u32) = .empty,
    stmts: std.ArrayList(Stmt) = .empty,
    extra: std.ArrayList(u32) = .empty,
    globals: std.ArrayList(Global) = .empty,
    /// Statements of main(), indexing `extra`.
    main_body: ?Range = null,

    pub fn deinit(a: *Ast, gpa: std.mem.Allocator) void {
        a.exprs.deinit(gpa);
        a.expr_tokens.deinit(gpa);
        a.stmts.deinit(gpa);
        a.extra.deinit(gpa);
        a.globals.deinit(gpa);
    }

    pub fn list(a: *const Ast, r: Range) []const u32 {
        return a.extra.items[r.start..][0..r.len];
    }
};

pub const Diagnostic = lexer.Diagnostic;

pub const Error = error{ SyntaxError, OutOfMemory };

const Parser = struct {
    gpa: std.mem.Allocator,
    ast: *Ast,
    pos: u32 = 0,
    diag: *Diagnostic,

    fn tok(p: *const Parser) Token {
        return p.ast.tokens[p.pos];
    }

    fn fail(p: *Parser, message: []const u8) Error {
        const t = p.tok();
        p.diag.* = .{ .line = t.line, .column = t.column, .message = message };
        return error.SyntaxError;
    }

    fn eat(p: *Parser, tag: Tag) bool {
        if (p.tok().tag != tag) return false;
        p.pos += 1;
        return true;
    }

    fn expect(p: *Parser, tag: Tag, message: []const u8) Error!Token {
        const t = p.tok();
        if (t.tag != tag) return p.fail(message);
        p.pos += 1;
        return t;
    }

    fn isKeyword(p: *const Parser, word: []const u8) bool {
        const t = p.tok();
        return t.tag == .identifier and std.mem.eql(u8, t.text, word);
    }

    fn eatKeyword(p: *Parser, word: []const u8) bool {
        if (!p.isKeyword(word)) return false;
        p.pos += 1;
        return true;
    }

    fn eatPrecision(p: *Parser) bool {
        return p.eatKeyword("lowp") or p.eatKeyword("mediump") or p.eatKeyword("highp");
    }

    fn addExpr(p: *Parser, e: Expr, token: u32) Error!ExprIndex {
        try p.ast.exprs.append(p.gpa, e);
        try p.ast.expr_tokens.append(p.gpa, token);
        return @intCast(p.ast.exprs.items.len - 1);
    }

    fn typeName(p: *Parser) Error!Type {
        const t = try p.expect(.identifier, "expected a type");
        if (Type.fromName(t.text)) |ty| return ty;
        p.pos -= 1;
        if (std.mem.startsWith(u8, t.text, "ivec") or std.mem.startsWith(u8, t.text, "bvec") or
            std.mem.eql(u8, t.text, "samplerCube") or std.mem.eql(u8, t.text, "struct"))
            return p.fail("this type is not supported yet");
        return p.fail("expected a type");
    }

    fn translationUnit(p: *Parser) Error!void {
        while (p.tok().tag != .eof) {
            if (p.eatKeyword("precision")) {
                _ = p.eatPrecision() or return p.fail("expected a precision qualifier");
                _ = try p.typeName();
                _ = try p.expect(.semicolon, "expected ';'");
                continue;
            }
            var qualifier: Qualifier = .none;
            if (p.eatKeyword("attribute")) qualifier = .attribute else if (p.eatKeyword("uniform")) qualifier = .uniform else if (p.eatKeyword("varying")) qualifier = .varying else if (p.eatKeyword("const")) qualifier = .@"const" else if (p.eatKeyword("invariant")) return p.fail("invariant is not supported yet");
            _ = p.eatPrecision();
            const type_tok = p.pos;
            const ty = try p.typeName();
            const name_tok = p.pos;
            const name = (try p.expect(.identifier, "expected a name")).text;
            if (p.tok().tag == .l_paren) {
                if (qualifier != .none) return p.fail("functions cannot have storage qualifiers");
                try p.function(ty, name, type_tok);
                continue;
            }
            try p.globalDeclarators(qualifier, ty, name, name_tok);
        }
        if (p.ast.main_body == null) return p.fail("missing main() function");
    }

    fn globalDeclarators(p: *Parser, qualifier: Qualifier, ty: Type, first_name: []const u8, first_tok: u32) Error!void {
        var name = first_name;
        var name_tok = first_tok;
        while (true) {
            if (p.tok().tag == .l_bracket) return p.fail("arrays are not supported yet");
            var init: ?ExprIndex = null;
            if (p.eat(.equal)) {
                if (qualifier != .@"const" and qualifier != .none) return p.fail("only const globals can have an initializer");
                init = try p.assignment();
            }
            if (qualifier == .@"const" and init == null) return p.fail("const variables need an initializer");
            try p.ast.globals.append(p.gpa, .{ .qualifier = qualifier, .type = ty, .name = name, .init = init, .token = name_tok });
            if (p.eat(.comma)) {
                name_tok = p.pos;
                name = (try p.expect(.identifier, "expected a name")).text;
                continue;
            }
            _ = try p.expect(.semicolon, "expected ';'");
            return;
        }
    }

    fn function(p: *Parser, ret: Type, name: []const u8, type_tok: u32) Error!void {
        if (!std.mem.eql(u8, name, "main")) {
            p.pos = type_tok;
            return p.fail("functions other than main() are not supported yet");
        }
        if (ret != .void) return p.fail("main() must return void");
        _ = try p.expect(.l_paren, "expected '('");
        _ = p.eatKeyword("void");
        _ = try p.expect(.r_paren, "main() takes no parameters");
        if (p.ast.main_body != null) return p.fail("main() is defined twice");
        p.ast.main_body = try p.block();
    }

    fn block(p: *Parser) Error!Range {
        _ = try p.expect(.l_brace, "expected '{'");
        var items: std.ArrayList(u32) = .empty;
        defer items.deinit(p.gpa);
        while (!p.eat(.r_brace)) {
            if (p.tok().tag == .eof) return p.fail("expected '}'");
            try p.statement(&items);
        }
        const start: u32 = @intCast(p.ast.extra.items.len);
        try p.ast.extra.appendSlice(p.gpa, items.items);
        return .{ .start = start, .len = @intCast(items.items.len) };
    }

    fn addStmt(p: *Parser, items: *std.ArrayList(u32), s: Stmt) Error!void {
        try p.ast.stmts.append(p.gpa, s);
        try items.append(p.gpa, @intCast(p.ast.stmts.items.len - 1));
    }

    fn statement(p: *Parser, items: *std.ArrayList(u32)) Error!void {
        if (p.tok().tag == .l_brace) return p.addStmt(items, .{ .block = try p.block() });
        if (p.tok().tag == .semicolon) {
            p.pos += 1;
            return;
        }
        inline for (.{ "if", "for", "while", "do", "discard", "break", "continue" }) |kw| {
            if (p.isKeyword(kw)) return p.fail("control flow (" ++ kw ++ ") is not supported yet");
        }
        if (p.eatKeyword("return")) {
            if (p.tok().tag != .semicolon) return p.fail("main() cannot return a value");
            p.pos += 1;
            return p.addStmt(items, .@"return");
        }
        const is_const = p.eatKeyword("const");
        _ = p.eatPrecision();
        const t = p.tok();
        if (is_const or (t.tag == .identifier and Type.fromName(t.text) != null and
            p.ast.tokens[p.pos + 1].tag == .identifier))
        {
            const ty = try p.typeName();
            while (true) {
                const name_tok = p.pos;
                const name = (try p.expect(.identifier, "expected a name")).text;
                if (p.tok().tag == .l_bracket) return p.fail("arrays are not supported yet");
                const init: ?ExprIndex = if (p.eat(.equal)) try p.assignment() else null;
                if (is_const and init == null) return p.fail("const variables need an initializer");
                try p.addStmt(items, .{ .decl = .{ .type = ty, .is_const = is_const, .name = name, .init = init, .token = name_tok } });
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.semicolon, "expected ';'");
            return;
        }
        const e = try p.expression();
        _ = try p.expect(.semicolon, "expected ';'");
        try p.addStmt(items, .{ .expr = e });
    }

    fn expression(p: *Parser) Error!ExprIndex {
        const e = try p.assignment();
        if (p.tok().tag == .comma) return p.fail("the comma operator is not supported");
        return e;
    }

    fn assignment(p: *Parser) Error!ExprIndex {
        const start = p.pos;
        const lhs = try p.binary(0);
        const op = p.tok().tag;
        switch (op) {
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal => {
                p.pos += 1;
                const rhs = try p.assignment();
                return p.addExpr(.{ .assign = .{ .op = op, .lhs = lhs, .rhs = rhs } }, start);
            },
            .question => return p.fail("the ?: operator is not supported yet"),
            else => return lhs,
        }
    }

    fn precedence(tag: Tag) ?u8 {
        return switch (tag) {
            .or_or => 1,
            .and_and => 2,
            .equal_equal, .bang_equal => 3,
            .less, .greater, .less_equal, .greater_equal => 4,
            .plus, .minus => 5,
            .star, .slash => 6,
            else => null,
        };
    }

    fn binary(p: *Parser, min_prec: u8) Error!ExprIndex {
        var lhs = try p.unary();
        while (true) {
            const op = p.tok().tag;
            const prec = precedence(op) orelse return lhs;
            if (prec <= min_prec) return lhs;
            const op_tok = p.pos;
            p.pos += 1;
            const rhs = try p.binary(prec);
            lhs = try p.addExpr(.{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } }, op_tok);
        }
    }

    fn unary(p: *Parser) Error!ExprIndex {
        const t = p.tok();
        switch (t.tag) {
            .minus, .plus, .bang => {
                const start = p.pos;
                p.pos += 1;
                const operand = try p.unary();
                return p.addExpr(.{ .unary = .{ .op = t.tag, .operand = operand } }, start);
            },
            .plus_plus, .minus_minus => return p.fail("++ and -- are not supported yet"),
            else => return p.postfix(),
        }
    }

    fn postfix(p: *Parser) Error!ExprIndex {
        var e = try p.primary();
        while (true) {
            const start = p.pos;
            if (p.eat(.dot)) {
                const name = (try p.expect(.identifier, "expected a field or swizzle")).text;
                e = try p.addExpr(.{ .field = .{ .operand = e, .name = name } }, start);
            } else if (p.eat(.l_bracket)) {
                const index = try p.expression();
                _ = try p.expect(.r_bracket, "expected ']'");
                e = try p.addExpr(.{ .index = .{ .operand = e, .index = index } }, start);
            } else if (p.tok().tag == .plus_plus or p.tok().tag == .minus_minus) {
                return p.fail("++ and -- are not supported yet");
            } else return e;
        }
    }

    fn primary(p: *Parser) Error!ExprIndex {
        const t = p.tok();
        const start = p.pos;
        switch (t.tag) {
            .float_literal => {
                p.pos += 1;
                const v = std.fmt.parseFloat(f32, t.text) catch return p.fail("invalid float literal");
                return p.addExpr(.{ .float_lit = v }, start);
            },
            .int_literal => {
                p.pos += 1;
                const v = std.fmt.parseInt(i32, t.text, 0) catch return p.fail("invalid integer literal");
                return p.addExpr(.{ .int_lit = v }, start);
            },
            .l_paren => {
                p.pos += 1;
                const e = try p.expression();
                _ = try p.expect(.r_paren, "expected ')'");
                return e;
            },
            .identifier => {
                p.pos += 1;
                if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false"))
                    return p.addExpr(.{ .bool_lit = t.text[0] == 't' }, start);
                if (p.eat(.l_paren)) {
                    var args: std.ArrayList(u32) = .empty;
                    defer args.deinit(p.gpa);
                    if (!p.eat(.r_paren)) {
                        _ = p.eatKeyword("void");
                        while (true) {
                            try args.append(p.gpa, try p.assignment());
                            if (p.eat(.r_paren)) break;
                            _ = try p.expect(.comma, "expected ',' or ')'");
                        }
                    }
                    const args_start: u32 = @intCast(p.ast.extra.items.len);
                    try p.ast.extra.appendSlice(p.gpa, args.items);
                    return p.addExpr(.{ .call = .{ .callee = t.text, .args = .{ .start = args_start, .len = @intCast(args.items.len) } } }, start);
                }
                return p.addExpr(.{ .ident = t.text }, start);
            },
            else => return p.fail("expected an expression"),
        }
    }
};

/// Parses tokens into `ast`. On a syntax error `diag` says where and why.
pub fn parse(gpa: std.mem.Allocator, ast: *Ast, diag: *Diagnostic) Error!void {
    var p: Parser = .{ .gpa = gpa, .ast = ast, .diag = diag };
    try p.translationUnit();
}

const testing = std.testing;

fn parseSource(src: []const u8, ast: *Ast, diag: *Diagnostic) !void {
    const l = try testing.allocator.create(lexer.Lexer);
    defer testing.allocator.destroy(l);
    l.* = .{ .src = src };
    const tokens = l.tokenize() catch |err| {
        diag.* = l.diag;
        return err;
    };
    // The AST refers to token text in the source, but the token array
    // lives in the lexer; copy it.
    ast.tokens = try testing.allocator.dupe(Token, tokens);
    try parse(testing.allocator, ast, diag);
}

test "parse a vertex shader" {
    var ast: Ast = .{ .tokens = &.{} };
    defer {
        testing.allocator.free(ast.tokens);
        ast.deinit(testing.allocator);
    }
    var diag: Diagnostic = .{};
    try parseSource(
        \\precision mediump float;
        \\attribute vec3 pos;
        \\uniform mat4 mvp;
        \\varying vec2 uv, other;
        \\void main() {
        \\    vec4 p = mvp * vec4(pos, 1.0);
        \\    gl_Position = p;
        \\    uv = p.xy * 0.5 + 0.5;
        \\}
    , &ast, &diag);
    try testing.expectEqual(@as(usize, 4), ast.globals.items.len);
    try testing.expectEqual(Qualifier.varying, ast.globals.items[3].qualifier);
    try testing.expectEqual(@as(u32, 3), ast.main_body.?.len);
}

test "unsupported features give errors" {
    const cases = [_][]const u8{
        "void main() { if (true) {} }",
        "float f() { return 1.0; } void main() {}",
        "uniform float a[4]; void main() {}",
        "void main() { float x = 1.0 ? 2.0 : 3.0; }",
    };
    for (cases) |src| {
        var ast: Ast = .{ .tokens = &.{} };
        defer {
            testing.allocator.free(ast.tokens);
            ast.deinit(testing.allocator);
        }
        var diag: Diagnostic = .{};
        try testing.expectError(error.SyntaxError, parseSource(src, &ast, &diag));
        try testing.expect(diag.message.len > 0);
    }
}
