//! GLSL ES 1.00 tokenizer with a minimal preprocessor.
//!
//! The preprocessor supports what real shaders commonly use: `#version`,
//! `#extension` and `#pragma` (ignored), object-like `#define` and
//! `#undef`, and conditional blocks with `#ifdef`, `#ifndef`, `#if`
//! (`0`, `1` or `defined(NAME)`), `#else` and `#endif`. `GL_ES` is
//! predefined, as the specification requires.

const std = @import("std");

pub const Tag = enum {
    eof,
    identifier,
    int_literal,
    float_literal,
    // Punctuation and operators.
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    dot,
    comma,
    semicolon,
    colon,
    question,
    plus,
    minus,
    star,
    slash,
    bang,
    equal,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    equal_equal,
    bang_equal,
    less,
    greater,
    less_equal,
    greater_equal,
    and_and,
    or_or,
    plus_plus,
    minus_minus,
};

pub const Token = struct {
    tag: Tag,
    text: []const u8,
    line: u32,
    column: u32,
};

pub const max_tokens = 8192;
const max_defines = 64;

pub const Error = error{ SyntaxError, TooManyTokens };

pub const Diagnostic = struct {
    line: u32 = 0,
    column: u32 = 0,
    message: []const u8 = "",
};

const Define = struct { name: []const u8, value: []const u8 };

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    tokens: [max_tokens]Token = undefined,
    len: usize = 0,
    defines: [max_defines]Define = undefined,
    ndefines: usize = 0,
    diag: Diagnostic = .{},

    fn fail(l: *Lexer, message: []const u8) Error {
        l.diag = .{ .line = l.line, .column = @intCast(l.pos - l.line_start + 1), .message = message };
        return error.SyntaxError;
    }

    fn lookupDefine(l: *const Lexer, name: []const u8) ?[]const u8 {
        for (l.defines[0..l.ndefines]) |d| if (std.mem.eql(u8, d.name, name)) return d.value;
        return null;
    }

    fn push(l: *Lexer, tag: Tag, text: []const u8, column: u32) Error!void {
        if (l.len == max_tokens) return error.TooManyTokens;
        l.tokens[l.len] = .{ .tag = tag, .text = text, .line = l.line, .column = column };
        l.len += 1;
    }

    pub fn tokenize(l: *Lexer) Error![]const Token {
        l.defines[0] = .{ .name = "GL_ES", .value = "1" };
        l.ndefines = 1;
        // Stack of conditional states: whether the enclosing block is
        // active, and whether this block's branch has been taken.
        var cond_active: [16]bool = undefined;
        var cond_taken: [16]bool = undefined;
        var depth: usize = 0;
        var at_line_start = true;

        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '\n') {
                l.pos += 1;
                l.line += 1;
                l.line_start = l.pos;
                at_line_start = true;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r') {
                l.pos += 1;
                continue;
            }
            if (c == '/' and l.peek(1) == '/') {
                while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
                continue;
            }
            if (c == '/' and l.peek(1) == '*') {
                l.pos += 2;
                while (l.pos < l.src.len and !(l.src[l.pos] == '*' and l.peek(1) == '/')) {
                    if (l.src[l.pos] == '\n') {
                        l.line += 1;
                        l.line_start = l.pos + 1;
                    }
                    l.pos += 1;
                }
                if (l.pos >= l.src.len) return l.fail("unterminated comment");
                l.pos += 2;
                continue;
            }
            const active = depth == 0 or cond_active[depth - 1];
            if (c == '#') {
                if (!at_line_start) return l.fail("'#' must start a line");
                l.pos += 1;
                const directive = l.word();
                const rest = l.restOfLine();
                if (std.mem.eql(u8, directive, "ifdef") or std.mem.eql(u8, directive, "ifndef") or std.mem.eql(u8, directive, "if")) {
                    if (depth == cond_active.len) return l.fail("conditionals nested too deeply");
                    var value: bool = undefined;
                    if (std.mem.eql(u8, directive, "if")) {
                        value = l.evalIf(rest) orelse return l.fail("unsupported #if expression");
                    } else {
                        value = l.lookupDefine(rest) != null;
                        if (directive[2] == 'n') value = !value;
                    }
                    cond_active[depth] = active and value;
                    cond_taken[depth] = value;
                    depth += 1;
                } else if (std.mem.eql(u8, directive, "else")) {
                    if (depth == 0) return l.fail("#else without #if");
                    const outer = depth == 1 or cond_active[depth - 2];
                    cond_active[depth - 1] = outer and !cond_taken[depth - 1];
                    cond_taken[depth - 1] = true;
                } else if (std.mem.eql(u8, directive, "endif")) {
                    if (depth == 0) return l.fail("#endif without #if");
                    depth -= 1;
                } else if (!active) {
                    // Directives in skipped blocks are ignored.
                } else if (std.mem.eql(u8, directive, "define")) {
                    var it = std.mem.tokenizeAny(u8, rest, " \t");
                    const name = it.next() orelse return l.fail("#define needs a name");
                    if (std.mem.indexOfScalar(u8, name, '(') != null) return l.fail("function-like macros are not supported");
                    if (l.ndefines == max_defines) return l.fail("too many #defines");
                    l.defines[l.ndefines] = .{ .name = name, .value = std.mem.trim(u8, rest[name.len..], " \t") };
                    l.ndefines += 1;
                } else if (std.mem.eql(u8, directive, "undef")) {
                    for (l.defines[0..l.ndefines], 0..) |d, i| if (std.mem.eql(u8, d.name, rest)) {
                        l.defines[i] = l.defines[l.ndefines - 1];
                        l.ndefines -= 1;
                        break;
                    };
                } else if (std.mem.eql(u8, directive, "version")) {
                    if (!std.mem.eql(u8, std.mem.trim(u8, rest, " \t"), "100")) return l.fail("only #version 100 is supported");
                } else if (std.mem.eql(u8, directive, "extension") or std.mem.eql(u8, directive, "pragma") or directive.len == 0) {
                    // Ignored.
                } else if (std.mem.eql(u8, directive, "error")) {
                    return l.fail("#error");
                } else {
                    return l.fail("unsupported preprocessor directive");
                }
                continue;
            }
            at_line_start = false;
            if (!active) {
                l.pos += 1;
                continue;
            }
            try l.token();
        }
        if (depth != 0) return l.fail("missing #endif");
        try l.push(.eof, "", @intCast(l.pos - l.line_start + 1));
        return l.tokens[0..l.len];
    }

    fn peek(l: *const Lexer, off: usize) u8 {
        return if (l.pos + off < l.src.len) l.src[l.pos + off] else 0;
    }

    fn word(l: *Lexer) []const u8 {
        while (l.pos < l.src.len and (l.src[l.pos] == ' ' or l.src[l.pos] == '\t')) l.pos += 1;
        const start = l.pos;
        while (l.pos < l.src.len and (std.ascii.isAlphanumeric(l.src[l.pos]) or l.src[l.pos] == '_')) l.pos += 1;
        return l.src[start..l.pos];
    }

    fn restOfLine(l: *Lexer) []const u8 {
        const start = l.pos;
        while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
        var text = l.src[start..l.pos];
        if (std.mem.indexOf(u8, text, "//")) |i| text = text[0..i];
        return std.mem.trim(u8, text, " \t\r");
    }

    fn evalIf(l: *const Lexer, expr: []const u8) ?bool {
        if (std.mem.eql(u8, expr, "0")) return false;
        if (std.mem.eql(u8, expr, "1")) return true;
        if (std.mem.startsWith(u8, expr, "defined")) {
            const inner = std.mem.trim(u8, expr["defined".len..], " \t()");
            return l.lookupDefine(inner) != null;
        }
        if (l.lookupDefine(expr)) |v| return !std.mem.eql(u8, v, "0");
        return null;
    }

    fn token(l: *Lexer) Error!void {
        const start = l.pos;
        const column: u32 = @intCast(start - l.line_start + 1);
        const c = l.src[l.pos];
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (l.pos < l.src.len and (std.ascii.isAlphanumeric(l.src[l.pos]) or l.src[l.pos] == '_')) l.pos += 1;
            const name = l.src[start..l.pos];
            if (l.lookupDefine(name)) |value| {
                // Object-like macro: tokenize the replacement text.
                if (value.len == 0) return;
                var sub: Lexer = .{ .src = value, .line = l.line };
                var sub_tokens: [64]Token = undefined;
                var n: usize = 0;
                while (sub.pos < sub.src.len) {
                    if (sub.src[sub.pos] == ' ' or sub.src[sub.pos] == '\t') {
                        sub.pos += 1;
                        continue;
                    }
                    try sub.token();
                    if (n == sub_tokens.len) return l.fail("macro too long");
                    sub_tokens[n] = sub.tokens[sub.len - 1];
                    n += 1;
                }
                for (sub_tokens[0..n]) |t| try l.push(t.tag, t.text, column);
                return;
            }
            return l.push(.identifier, name, column);
        }
        if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(l.peek(1)))) {
            var is_float = false;
            if (c == '0' and (l.peek(1) == 'x' or l.peek(1) == 'X')) {
                l.pos += 2;
                while (l.pos < l.src.len and std.ascii.isHex(l.src[l.pos])) l.pos += 1;
            } else {
                while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '.') {
                    is_float = true;
                    l.pos += 1;
                    while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
                }
                if (l.pos < l.src.len and (l.src[l.pos] == 'e' or l.src[l.pos] == 'E')) {
                    is_float = true;
                    l.pos += 1;
                    if (l.pos < l.src.len and (l.src[l.pos] == '+' or l.src[l.pos] == '-')) l.pos += 1;
                    const exp_start = l.pos;
                    while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
                    if (l.pos == exp_start) return l.fail("missing exponent");
                }
            }
            return l.push(if (is_float) .float_literal else .int_literal, l.src[start..l.pos], column);
        }
        const two = [2]u8{ c, l.peek(1) };
        const pairs = .{
            .{ "+=", Tag.plus_equal },  .{ "-=", Tag.minus_equal },   .{ "*=", Tag.star_equal },
            .{ "/=", Tag.slash_equal }, .{ "==", Tag.equal_equal },   .{ "!=", Tag.bang_equal },
            .{ "<=", Tag.less_equal },  .{ ">=", Tag.greater_equal }, .{ "&&", Tag.and_and },
            .{ "||", Tag.or_or },       .{ "++", Tag.plus_plus },     .{ "--", Tag.minus_minus },
        };
        inline for (pairs) |p| {
            if (std.mem.eql(u8, &two, p[0])) {
                l.pos += 2;
                return l.push(p[1], l.src[start..l.pos], column);
            }
        }
        const tag: Tag = switch (c) {
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            '.' => .dot,
            ',' => .comma,
            ';' => .semicolon,
            ':' => .colon,
            '?' => .question,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '!' => .bang,
            '=' => .equal,
            '<' => .less,
            '>' => .greater,
            else => return l.fail("unexpected character"),
        };
        l.pos += 1;
        return l.push(tag, l.src[start..l.pos], column);
    }
};

const testing = std.testing;

fn tagsOf(src: []const u8, out: []Tag) ![]Tag {
    const l = try testing.allocator.create(Lexer);
    defer testing.allocator.destroy(l);
    l.* = .{ .src = src };
    const toks = try l.tokenize();
    for (toks, 0..) |t, i| out[i] = t.tag;
    return out[0..toks.len];
}

test "tokens" {
    var buf: [32]Tag = undefined;
    try testing.expectEqualSlices(Tag, &.{ .identifier, .identifier, .equal, .float_literal, .star, .int_literal, .semicolon, .eof }, try tagsOf("vec4 c = 1.5e-1 * 2; // comment", &buf));
    try testing.expectEqualSlices(Tag, &.{ .identifier, .plus_equal, .float_literal, .eof }, try tagsOf("a /* x\ny */ += .5", &buf));
}

test "preprocessor" {
    var buf: [32]Tag = undefined;
    const src =
        \\#version 100
        \\#ifdef GL_ES
        \\precision mediump float;
        \\#else
        \\garbage @
        \\#endif
        \\#define SCALE 2.0
        \\#if 0
        \\nope
        \\#endif
        \\float x = SCALE;
    ;
    try testing.expectEqualSlices(Tag, &.{
        .identifier, .identifier, .identifier, .semicolon,
        .identifier, .identifier, .equal,      .float_literal,
        .semicolon,  .eof,
    }, try tagsOf(src, &buf));
}

test "errors report a position" {
    const l = try testing.allocator.create(Lexer);
    defer testing.allocator.destroy(l);
    l.* = .{ .src = "float x;\n  @" };
    try testing.expectError(error.SyntaxError, l.tokenize());
    try testing.expectEqual(@as(u32, 2), l.diag.line);
    try testing.expectEqual(@as(u32, 3), l.diag.column);
}
