//! Compiling and linking GLSL shaders into a program.
//!
//! `Shader` holds one parsed shader (glCompileShader). `Program` links a
//! vertex and a fragment shader (glLinkProgram): it merges the uniforms of
//! both stages into one array, assigns attribute locations, matches
//! varyings, and can then lower each hardware stage on demand:
//!
//! * vertex: the GLSL vertex shader, writing position and varyings
//! * coordinate: the same shader reduced to gl_Position, reading only the
//!   attributes position depends on (used by the binner)
//! * fragment: with or without a depth write, depending on whether depth
//!   testing is enabled

const std = @import("std");
const vc4 = @import("vc4");
const lexer = @import("lexer.zig");
const lower = @import("lower.zig");
const parser = @import("parser.zig");

const compiler = vc4.compiler;
pub const Type = parser.Type;
pub const Diagnostic = lexer.Diagnostic;

pub const Stage = enum { vertex, fragment };

/// A human-readable compile or link log, in the usual GL style:
/// `ERROR: 0:<line>: <message>`.
pub const Log = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn text(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }

    pub fn add(l: *Log, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(l.buf[l.len..], fmt ++ "\n", args) catch return;
        l.len += out.len;
    }

    fn addDiag(l: *Log, d: Diagnostic) void {
        l.add("ERROR: 0:{d}:{d}: {s}", .{ d.line, d.column, d.message });
    }
};

pub const Error = error{ CompileFailed, LinkFailed, OutOfMemory };

/// A parsed shader. Owns a copy of its source.
pub const Shader = struct {
    gpa: std.mem.Allocator,
    stage: Stage,
    source: []u8,
    tokens: []lexer.Token,
    ast: parser.Ast,

    pub fn deinit(s: *Shader) void {
        s.ast.deinit(s.gpa);
        s.gpa.free(s.tokens);
        s.gpa.free(s.source);
    }

    fn globals(s: *const Shader, q: parser.Qualifier) GlobalIter {
        return .{ .items = s.ast.globals.items, .q = q };
    }
};

const GlobalIter = struct {
    items: []const parser.Global,
    q: parser.Qualifier,
    i: usize = 0,

    fn next(it: *GlobalIter) ?parser.Global {
        while (it.i < it.items.len) {
            const g = it.items[it.i];
            it.i += 1;
            if (g.qualifier == it.q) return g;
        }
        return null;
    }
};

/// Parses and checks a shader. On failure, `log` explains why.
pub fn compileShader(gpa: std.mem.Allocator, stage: Stage, source: []const u8, log: *Log) Error!Shader {
    const src = try gpa.dupe(u8, source);
    errdefer gpa.free(src);
    const lex = try gpa.create(lexer.Lexer);
    defer gpa.destroy(lex);
    lex.* = .{ .src = src };
    const toks = lex.tokenize() catch |err| {
        log.addDiag(if (err == error.TooManyTokens) .{ .message = "shader is too long" } else lex.diag);
        return error.CompileFailed;
    };
    var s: Shader = .{ .gpa = gpa, .stage = stage, .source = src, .tokens = try gpa.dupe(lexer.Token, toks), .ast = .{ .tokens = &.{} } };
    errdefer gpa.free(s.tokens);
    s.ast.tokens = s.tokens;
    errdefer s.ast.deinit(gpa);
    var diag: Diagnostic = .{};
    parser.parse(gpa, &s.ast, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            log.addDiag(diag);
            return error.CompileFailed;
        },
    };

    // Check semantics against an interface built from the shader's own
    // declarations, so errors are reported at compile time.
    var uniforms: [max_uniform_vars]lower.UniformSlot = undefined;
    var nu: usize = 0;
    var base: u32 = 0;
    var it = s.globals(.uniform);
    while (it.next()) |g| {
        if (nu == uniforms.len) {
            log.add("ERROR: too many uniforms", .{});
            return error.CompileFailed;
        }
        uniforms[nu] = .{ .name = g.name, .type = g.type, .base = base };
        nu += 1;
        base += g.type.components();
    }
    var slots: [max_slots]lower.Slot = undefined;
    var ns: usize = 0;
    var vit = s.globals(if (stage == .vertex) .attribute else .varying);
    while (vit.next()) |g| {
        if (ns == slots.len) {
            log.add("ERROR: too many attributes or varyings", .{});
            return error.CompileFailed;
        }
        slots[ns] = .{ .name = g.name, .type = g.type };
        ns += 1;
    }
    const iface: lower.Interface = .{
        .uniforms = uniforms[0..nu],
        .attributes = if (stage == .vertex) slots[0..ns] else &.{},
        .varyings = if (stage == .fragment) slots[0..ns] else &.{},
        .viewport_uniform = base,
    };
    const scratch = try gpa.create(compiler.Shader);
    defer gpa.destroy(scratch);
    lower.lower(&s.ast, if (stage == .vertex) .vertex else .fragment, &iface, scratch, &diag) catch {
        log.addDiag(diag);
        return error.CompileFailed;
    };
    return s;
}

const max_uniform_vars = 64;
const max_slots = 16;
/// The shader record has room for 8 attribute arrays.
pub const max_attributes = 8;

pub const Uniform = struct {
    name: []const u8,
    type: Type,
    /// First component in the uniform array (samplers have none).
    base: u32,
};

pub const Attribute = struct {
    name: []const u8,
    type: Type,
    location: u32,
    /// Whether the coordinate shader reads it.
    in_coordinate_shader: bool = false,
};

pub const Binding = struct {
    name: []const u8,
    location: u32,
};

pub const Program = struct {
    gpa: std.mem.Allocator,
    vs: Shader,
    fs: Shader,
    uniforms: [max_uniform_vars]Uniform = undefined,
    num_uniforms: usize = 0,
    /// Size of the uniform array in 32-bit words, excluding the hidden
    /// viewport scale that follows it.
    uniform_words: u32 = 0,
    /// Active attributes, sorted by location (the VPM order).
    attributes: [max_attributes]Attribute = undefined,
    num_attributes: usize = 0,
    /// The fragment shader's varyings, in interpolation order.
    varyings: [max_slots]lower.Slot = undefined,
    num_varyings: usize = 0,

    pub fn deinit(p: *Program) void {
        p.vs.deinit();
        p.fs.deinit();
    }

    pub fn uniformList(p: *const Program) []const Uniform {
        return p.uniforms[0..p.num_uniforms];
    }

    pub fn attributeList(p: *const Program) []const Attribute {
        return p.attributes[0..p.num_attributes];
    }

    pub fn varyingList(p: *const Program) []const lower.Slot {
        return p.varyings[0..p.num_varyings];
    }

    /// Index of the hidden viewport scale uniforms (x, then y).
    pub fn viewportUniform(p: *const Program) u32 {
        return p.uniform_words;
    }

    /// Number of scalar varyings passed from the vertex to the fragment
    /// shader.
    pub fn varyingComponents(p: *const Program) u8 {
        var n: u8 = 0;
        for (p.varyingList()) |v| n += v.type.components();
        return n;
    }

    pub fn findUniform(p: *const Program, name: []const u8) ?*const Uniform {
        for (p.uniformList()) |*u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }

    pub fn findAttribute(p: *const Program, name: []const u8) ?*const Attribute {
        for (p.attributeList()) |*a| if (std.mem.eql(u8, a.name, name)) return a;
        return null;
    }

    fn interface(p: *const Program, stage: compiler.Stage, opts: BuildOptions, slots: *[max_attributes]lower.Slot, uniforms: *[max_uniform_vars]lower.UniformSlot) lower.Interface {
        for (p.uniformList(), 0..) |u, i| uniforms[i] = .{ .name = u.name, .type = u.type, .base = u.base };
        var n: usize = 0;
        for (p.attributeList(), 0..) |a, i| {
            if (stage == .coordinate and !a.in_coordinate_shader) continue;
            slots[n] = .{ .name = a.name, .type = a.type, .supplied = if (opts.supplied) |s| s[i] else null };
            n += 1;
        }
        return .{
            .uniforms = uniforms[0..p.num_uniforms],
            .attributes = slots[0..n],
            .varyings = p.varyingList(),
            .viewport_uniform = p.viewportUniform(),
            .depth_write = opts.depth_write,
        };
    }

    pub const BuildOptions = struct {
        /// Fragment shaders: write the fragment's depth for depth testing.
        depth_write: bool = false,
        /// Vertex shaders: components the vertex data supplies for each
        /// attribute in `attributeList` order (all when null).
        supplied: ?[]const u8 = null,
    };

    /// Lowers one hardware stage of the program into `out`.
    pub fn build(p: *const Program, stage: compiler.Stage, opts: BuildOptions, out: *compiler.Shader) error{LinkFailed}!void {
        var slots: [max_attributes]lower.Slot = undefined;
        var uniforms: [max_uniform_vars]lower.UniformSlot = undefined;
        const iface = p.interface(stage, opts, &slots, &uniforms);
        var diag: Diagnostic = .{};
        // Both shaders were checked when they were compiled and linked.
        lower.lower(if (stage == .fragment) &p.fs.ast else &p.vs.ast, stage, &iface, out, &diag) catch return error.LinkFailed;
    }
};

fn typeOf(s: *const Shader, q: parser.Qualifier, name: []const u8) ?Type {
    var it = s.globals(q);
    while (it.next()) |g| if (std.mem.eql(u8, g.name, name)) return g.type;
    return null;
}

/// Links a compiled vertex and fragment shader. The program keeps its own
/// copies, so the shaders may be deleted afterwards.
pub fn link(gpa: std.mem.Allocator, vs: *const Shader, fs: *const Shader, bindings: []const Binding, log: *Log) Error!*Program {
    if (vs.stage != .vertex or fs.stage != .fragment) {
        log.add("ERROR: a program needs one vertex and one fragment shader", .{});
        return error.LinkFailed;
    }
    const p = try gpa.create(Program);
    errdefer gpa.destroy(p);
    p.* = .{ .gpa = gpa, .vs = undefined, .fs = undefined };
    var ignore: Log = .{};
    p.vs = compileShader(gpa, .vertex, vs.source, &ignore) catch return error.LinkFailed;
    errdefer p.vs.deinit();
    p.fs = compileShader(gpa, .fragment, fs.source, &ignore) catch return error.LinkFailed;
    errdefer p.fs.deinit();

    // Uniforms: one array for both stages; samplers take no space.
    for ([_]*const Shader{ &p.vs, &p.fs }) |s| {
        var it = s.globals(.uniform);
        while (it.next()) |g| {
            if (p.findUniform(g.name)) |existing| {
                if (existing.type != g.type) {
                    log.add("ERROR: uniform '{s}' has different types in the vertex and fragment shaders", .{g.name});
                    return error.LinkFailed;
                }
                continue;
            }
            if (p.num_uniforms == max_uniform_vars) {
                log.add("ERROR: too many uniforms", .{});
                return error.LinkFailed;
            }
            p.uniforms[p.num_uniforms] = .{ .name = g.name, .type = g.type, .base = p.uniform_words };
            p.num_uniforms += 1;
            p.uniform_words += g.type.components();
        }
    }

    // Attributes: explicit bindings first, then the lowest free location.
    var it = p.vs.globals(.attribute);
    var used: [max_attributes]bool = @splat(false);
    while (it.next()) |g| {
        if (p.num_attributes == max_attributes) {
            log.add("ERROR: too many attributes (the limit is {d})", .{max_attributes});
            return error.LinkFailed;
        }
        var location: ?u32 = null;
        for (bindings) |b| if (std.mem.eql(u8, b.name, g.name)) {
            location = b.location;
        };
        if (location) |loc| {
            if (loc >= max_attributes or used[loc]) {
                log.add("ERROR: attribute '{s}' is bound to an invalid or used location", .{g.name});
                return error.LinkFailed;
            }
        }
        p.attributes[p.num_attributes] = .{ .name = g.name, .type = g.type, .location = location orelse max_attributes };
        if (location) |loc| used[loc] = true;
        p.num_attributes += 1;
    }
    for (p.attributes[0..p.num_attributes]) |*a| {
        if (a.location != max_attributes) continue;
        a.location = @intCast(std.mem.indexOfScalar(bool, &used, false).?);
        used[a.location] = true;
    }
    std.mem.sort(Attribute, p.attributes[0..p.num_attributes], {}, struct {
        fn lt(_: void, a: Attribute, b: Attribute) bool {
            return a.location < b.location;
        }
    }.lt);
    if (p.num_attributes == 0) {
        log.add("ERROR: the vertex shader has no attributes", .{});
        return error.LinkFailed;
    }

    // Varyings: the fragment shader's, each declared alike in the vertex
    // shader.
    var vit = p.fs.globals(.varying);
    while (vit.next()) |g| {
        const vs_type = typeOf(&p.vs, .varying, g.name) orelse {
            log.add("ERROR: varying '{s}' is not declared in the vertex shader", .{g.name});
            return error.LinkFailed;
        };
        if (vs_type != g.type) {
            log.add("ERROR: varying '{s}' has different types in the two shaders", .{g.name});
            return error.LinkFailed;
        }
        if (p.num_varyings == max_slots) {
            log.add("ERROR: too many varyings", .{});
            return error.LinkFailed;
        }
        p.varyings[p.num_varyings] = .{ .name = g.name, .type = g.type };
        p.num_varyings += 1;
    }
    if (p.varyingComponents() > 32) {
        log.add("ERROR: too many varying components", .{});
        return error.LinkFailed;
    }

    // The coordinate shader only needs the attributes gl_Position depends
    // on: lower it reading all of them and see which are used.
    for (p.attributes[0..p.num_attributes]) |*a| a.in_coordinate_shader = true;
    const cs = try gpa.create(compiler.Shader);
    defer gpa.destroy(cs);
    p.build(.coordinate, .{}, cs) catch {
        log.add("ERROR: internal error lowering the coordinate shader", .{});
        return error.LinkFailed;
    };
    const used_values = compiler.usedValues(cs);
    var vpm_index: usize = 0;
    for (p.attributes[0..p.num_attributes]) |*a| {
        var needed = false;
        for (0..a.type.components()) |_| {
            // Attribute reads are the shader's first instructions, in order.
            while (cs.insts[vpm_index].op != .vpm_read) vpm_index += 1;
            if (used_values[vpm_index]) needed = true;
            vpm_index += 1;
        }
        a.in_coordinate_shader = needed;
    }
    // The hardware needs at least one attribute per shader.
    var any = false;
    for (p.attributeList()) |a| any = any or a.in_coordinate_shader;
    if (!any) p.attributes[0].in_coordinate_shader = true;
    return p;
}

const testing = std.testing;

fn linkSources(vs_src: []const u8, fs_src: []const u8, log: *Log) !*Program {
    var vs = try compileShader(testing.allocator, .vertex, vs_src, log);
    defer vs.deinit();
    var fs = try compileShader(testing.allocator, .fragment, fs_src, log);
    defer fs.deinit();
    return link(testing.allocator, &vs, &fs, &.{}, log);
}

test "link assigns uniforms, attributes and varyings" {
    var log: Log = .{};
    const p = try linkSources(
        \\attribute vec3 pos;
        \\attribute vec2 uv;
        \\attribute vec3 tint;
        \\uniform mat4 mvp;
        \\varying vec2 v_uv;
        \\varying vec3 v_tint;
        \\void main() {
        \\    gl_Position = mvp * vec4(pos, 1.0);
        \\    v_uv = uv;
        \\    v_tint = tint;
        \\}
    ,
        \\precision mediump float;
        \\uniform sampler2D tex;
        \\varying vec2 v_uv;
        \\varying vec3 v_tint;
        \\void main() {
        \\    gl_FragColor = vec4(texture2D(tex, v_uv).rgb * v_tint, 1.0);
        \\}
    , &log);
    defer {
        p.deinit();
        testing.allocator.destroy(p);
    }
    try testing.expectEqual(@as(u32, 16), p.uniform_words);
    try testing.expectEqual(@as(u32, 16), p.findUniform("tex").?.base);
    try testing.expectEqual(@as(usize, 3), p.num_attributes);
    try testing.expectEqual(@as(u8, 5), p.varyingComponents());
    // Only the position feeds gl_Position.
    try testing.expect(p.findAttribute("pos").?.in_coordinate_shader);
    try testing.expect(!p.findAttribute("uv").?.in_coordinate_shader);
    try testing.expect(!p.findAttribute("tint").?.in_coordinate_shader);
}

test "compile errors name the line" {
    var log: Log = .{};
    try testing.expectError(error.CompileFailed, compileShader(testing.allocator, .vertex,
        \\attribute vec4 pos;
        \\void main() {
        \\    gl_Position = pos * 2;
        \\}
    , &log));
    try testing.expect(std.mem.startsWith(u8, log.text(), "ERROR: 0:3:"));
}

test "link errors" {
    var log: Log = .{};
    try testing.expectError(error.LinkFailed, linkSources(
        \\attribute vec4 pos;
        \\void main() { gl_Position = pos; }
    ,
        \\varying vec2 missing;
        \\void main() { gl_FragColor = vec4(missing, 0.0, 1.0); }
    , &log));
    try testing.expect(std.mem.indexOf(u8, log.text(), "missing") != null);
}

test "attributes can supply fewer components than declared" {
    var log: Log = .{};
    const p = try linkSources(
        \\attribute vec4 pos;
        \\void main() { gl_Position = pos; }
    ,
        \\void main() { gl_FragColor = vec4(1.0); }
    , &log);
    defer {
        p.deinit();
        testing.allocator.destroy(p);
    }
    const shader = try testing.allocator.create(compiler.Shader);
    defer testing.allocator.destroy(shader);
    for ([_]u8{ 1, 2, 3, 4 }) |n| {
        try p.build(.vertex, .{ .supplied = &.{n} }, shader);
        var reads: u8 = 0;
        for (shader.insts[0..shader.len]) |inst| reads += @intFromBool(inst.op == .vpm_read);
        try testing.expectEqual(n, reads);
    }
}
