//! A shader program compiled for the GPU from SPIR-V: the vertex and
//! fragment entry points of one module, linked by location, lowered to the
//! three hardware shaders (coordinate, vertex, fragment).
//!
//! Programs are compiled when Dazzle is built (see tools/shaderc.zig) and
//! embedded in the programs that use them, as `encode` writes them; they can
//! also be compiled when an app runs, from SPIR-V it loads.

const std = @import("std");
const vc4 = @import("vc4");
const spirv = @import("spirv.zig");
const lower = @import("lower.zig");

const compiler = vc4.compiler;

pub const Blend = lower.Blend;
pub const Diagnostic = lower.Diagnostic;

pub const max_attributes = 8;
pub const max_varyings = 16;

/// Render state that changes the fragment shader's code.
pub const Options = struct {
    /// Test against (and write) the tile buffer's depth.
    depth_test: bool = false,
    blend: Blend = .none,
};

pub const Attribute = struct {
    location: u32,
    /// Floats it has (1 to 4).
    components: u8,
    /// Whether the coordinate shader reads it (the position depends on it).
    in_coordinate_shader: bool,
};

pub const Error = lower.Error || spirv.Error || compiler.Error || error{ LinkFailed, BadProgram };

pub const Program = struct {
    fs: compiler.Compiled,
    vs: compiler.Compiled,
    cs: compiler.Compiled,
    attributes: [max_attributes]Attribute = undefined,
    num_attributes: u8 = 0,
    /// Scalars passed from the vertex to the fragment shader.
    varying_components: u8 = 0,
    /// Words of uniform data; the viewport scale follows them.
    uniform_words: u32 = 0,
    options: Options = .{},

    pub fn attributeList(p: *const Program) []const Attribute {
        return p.attributes[0..p.num_attributes];
    }

    /// Compiles a SPIR-V module with one vertex and one fragment entry
    /// point. On failure, `diag` says why.
    pub fn compile(gpa: std.mem.Allocator, spirv_bytes: []const u8, options: Options, diag: *Diagnostic) Error!Program {
        var m = try spirv.Module.parse(gpa, spirv_bytes);
        defer m.deinit();
        var vertex: ?spirv.EntryPoint = null;
        var fragment: ?spirv.EntryPoint = null;
        for (m.entry_points.items) |e| switch (e.model) {
            spirv.ExecutionModel.vertex => vertex = e,
            spirv.ExecutionModel.fragment => fragment = e,
            else => {},
        };
        const vs_entry = vertex orelse return link(diag, "no vertex shader (export fn ... callconv(.spirv_vertex))", .{});
        const fs_entry = fragment orelse return link(diag, "no fragment shader (export fn ... callconv(.spirv_fragment))", .{});

        var p: Program = .{ .fs = undefined, .vs = undefined, .cs = undefined, .options = options };

        // Attributes: the vertex shader's inputs, by location.
        var attrs: [max_attributes]lower.Slot = undefined;
        var n_attrs: usize = 0;
        for (vs_entry.interface) |id| if (interfaceSlot(&m, id, spirv.StorageClass.input)) |slot| {
            if (n_attrs == attrs.len) return link(diag, "too many vertex inputs (at most {d})", .{max_attributes});
            attrs[n_attrs] = slot;
            n_attrs += 1;
        };
        std.mem.sort(lower.Slot, attrs[0..n_attrs], {}, byLocation);

        // Varyings: the fragment shader's inputs, by location; the vertex
        // shader must write each.
        var varyings: [max_varyings]lower.Slot = undefined;
        var n_vary: usize = 0;
        for (fs_entry.interface) |id| if (interfaceSlot(&m, id, spirv.StorageClass.input)) |slot| {
            if (n_vary == varyings.len) return link(diag, "too many fragment inputs", .{});
            varyings[n_vary] = slot;
            n_vary += 1;
        };
        std.mem.sort(lower.Slot, varyings[0..n_vary], {}, byLocation);
        for (varyings[0..n_vary]) |vy| {
            const out = for (vs_entry.interface) |id| {
                if (interfaceSlot(&m, id, spirv.StorageClass.output)) |o| if (o.location == vy.location) break o;
            } else return link(diag, "the fragment shader reads location {d}, which the vertex shader does not write", .{vy.location});
            if (out.components != vy.components) return link(diag, "location {d} has {d} components in the vertex shader and {d} in the fragment shader", .{ vy.location, out.components, vy.components });
            p.varying_components += vy.components;
        }

        // Uniforms: one block (binding 0), shared by both stages.
        var it = m.defs.iterator();
        while (it.next()) |e| {
            const inst = e.value_ptr.*;
            if (inst.op != spirv.Op.variable or inst.operands[2] != spirv.StorageClass.uniform) continue;
            const t = m.typeOf(inst.operands[0]);
            p.uniform_words = @max(p.uniform_words, (m.sizeOf(t.pointer.pointee) + 3) / 4);
        }

        var iface: lower.Interface = .{
            .attributes = attrs[0..n_attrs],
            .varyings = varyings[0..n_vary],
            .uniform_words = p.uniform_words,
            .depth_write = options.depth_test,
            .blend = options.blend,
        };
        const shader = try gpa.create(compiler.Shader);
        defer gpa.destroy(shader);

        try lower.lower(gpa, &m, fs_entry, fs_entry.interface, .fragment, &iface, shader, diag);
        p.fs = try compiler.compile(shader);
        try lower.lower(gpa, &m, vs_entry, vs_entry.interface, .vertex, &iface, shader, diag);
        p.vs = try compiler.compile(shader);

        // The coordinate shader only reads the attributes its position
        // depends on: lower it reading all, see which reads reach an
        // output, and lower it again reading those.
        try lower.lower(gpa, &m, vs_entry, vs_entry.interface, .coordinate, &iface, shader, diag);
        const used = usedVpmReads(shader);
        var coord_attrs: [max_attributes]lower.Slot = undefined;
        var read_index: usize = 0;
        for (attrs[0..n_attrs], coord_attrs[0..n_attrs], 0..) |a, *c, i| {
            var any = false;
            for (0..a.components) |_| {
                if (read_index < used.len and used[read_index]) any = true;
                read_index += 1;
            }
            c.* = a;
            c.read = any;
            p.attributes[i] = .{ .location = a.location, .components = a.components, .in_coordinate_shader = any };
        }
        p.num_attributes = @intCast(n_attrs);
        iface.attributes = coord_attrs[0..n_attrs];
        try lower.lower(gpa, &m, vs_entry, vs_entry.interface, .coordinate, &iface, shader, diag);
        p.cs = try compiler.compile(shader);
        return p;
    }

    // --- Encoding ---------------------------------------------------------------

    const format_magic = "SDSH";
    const format_version: u32 = 2;

    /// The program as bytes, for embedding (see `decode`).
    pub fn encode(p: *const Program, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, format_magic);
        try putInt(&out, gpa, format_version);
        try putInt(&out, gpa, @intFromBool(p.options.depth_test));
        try putInt(&out, gpa, @intFromEnum(p.options.blend));
        try putInt(&out, gpa, p.uniform_words);
        try putInt(&out, gpa, p.varying_components);
        try putInt(&out, gpa, p.num_attributes);
        for (p.attributeList()) |a| {
            try putInt(&out, gpa, a.location);
            try putInt(&out, gpa, a.components);
            try putInt(&out, gpa, @intFromBool(a.in_coordinate_shader));
        }
        for ([_]*const compiler.Compiled{ &p.fs, &p.vs, &p.cs }) |c| {
            try putInt(&out, gpa, @intFromEnum(c.stage));
            try putInt(&out, gpa, c.num_vpm_reads);
            try putInt(&out, gpa, c.num_vpm_writes);
            try putInt(&out, gpa, c.num_varyings);
            try putInt(&out, gpa, c.num_texture_samples);
            try putInt(&out, gpa, @intFromBool(c.threaded));
            try putInt(&out, gpa, @intCast(c.code_len));
            for (c.code()) |inst| {
                try putInt(&out, gpa, @truncate(inst));
                try putInt(&out, gpa, @truncate(inst >> 32));
            }
            try putInt(&out, gpa, @intCast(c.uniform_len));
            for (c.uniforms()) |u| {
                const tag: u32, const value: u32 = switch (u) {
                    .user => |x| .{ 0, x },
                    .tex_p0 => |x| .{ 1, x },
                    .tex_p1 => |x| .{ 2, x },
                };
                try putInt(&out, gpa, tag);
                try putInt(&out, gpa, value);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Reads a program `encode` wrote.
    pub fn decode(bytes: []const u8) error{BadProgram}!Program {
        var r: Reader = .{ .bytes = bytes };
        if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], format_magic)) return error.BadProgram;
        r.at = 4;
        if (try r.int() != format_version) return error.BadProgram;
        var p: Program = .{ .fs = undefined, .vs = undefined, .cs = undefined };
        p.options.depth_test = try r.int() != 0;
        p.options.blend = std.enums.fromInt(Blend, try r.int()) orelse return error.BadProgram;
        p.uniform_words = try r.int();
        p.varying_components = @intCast(try r.int());
        const n = try r.int();
        if (n > max_attributes) return error.BadProgram;
        p.num_attributes = @intCast(n);
        for (p.attributes[0..n]) |*a| a.* = .{ .location = try r.int(), .components = @intCast(try r.int()), .in_coordinate_shader = try r.int() != 0 };
        for ([_]*compiler.Compiled{ &p.fs, &p.vs, &p.cs }) |c| {
            c.* = .{ .stage = std.enums.fromInt(compiler.Stage, try r.int()) orelse return error.BadProgram };
            c.num_vpm_reads = try r.int();
            c.num_vpm_writes = try r.int();
            c.num_varyings = try r.int();
            c.num_texture_samples = try r.int();
            c.threaded = try r.int() != 0;
            const code_len = try r.int();
            if (code_len > c.code_buf.len) return error.BadProgram;
            for (c.code_buf[0..code_len]) |*inst| {
                const lo = try r.int();
                inst.* = @as(u64, try r.int()) << 32 | lo;
            }
            c.code_len = code_len;
            const unif_len = try r.int();
            if (unif_len > c.uniform_buf.len) return error.BadProgram;
            for (c.uniform_buf[0..unif_len]) |*u| {
                const tag = try r.int();
                const value = try r.int();
                u.* = switch (tag) {
                    0 => .{ .user = value },
                    1 => .{ .tex_p0 = @intCast(value) },
                    2 => .{ .tex_p1 = @intCast(value) },
                    else => return error.BadProgram,
                };
            }
            c.uniform_len = unif_len;
        }
        return p;
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn int(r: *Reader) error{BadProgram}!u32 {
        if (r.at + 4 > r.bytes.len) return error.BadProgram;
        defer r.at += 4;
        return std.mem.readInt(u32, r.bytes[r.at..][0..4], .little);
    }
};

fn putInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn link(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set(fmt, args);
    return error.LinkFailed;
}

fn byLocation(_: void, a: lower.Slot, b: lower.Slot) bool {
    return a.location < b.location;
}

/// An input or output variable of the entry point with a location.
fn interfaceSlot(m: *const spirv.Module, id: u32, storage: u32) ?lower.Slot {
    const inst = m.defs.get(id) orelse return null;
    if (inst.op != spirv.Op.variable or inst.operands[2] != storage) return null;
    const location = m.decorationsOf(id).location orelse return null;
    const t = m.typeOf(inst.operands[0]);
    return .{ .location = location, .components = @intCast(m.components(t.pointer.pointee)) };
}

/// Which VPM reads (in order) feed the shader's outputs.
fn usedVpmReads(shader: *const compiler.Shader) []const bool {
    const S = struct {
        var live: [compiler.max_insts]bool = undefined;
        var used: [64]bool = undefined;
    };
    const insts = shader.insts[0..shader.len];
    @memset(S.live[0..insts.len], false);
    var i = insts.len;
    while (i > 0) {
        i -= 1;
        const inst = insts[i];
        if (inst.op == .vpm_write) S.live[i] = true;
        if (!S.live[i]) continue;
        for (inst.srcs[0..inst.nsrc]) |src| S.live[@intFromEnum(src)] = true;
    }
    var n: usize = 0;
    for (insts, 0..) |inst, j| if (inst.op == .vpm_read and n < S.used.len) {
        S.used[n] = S.live[j];
        n += 1;
    };
    return S.used[0..n];
}
