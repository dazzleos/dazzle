//! Reading SPIR-V modules: the instructions, what defines each id, the
//! decorations, the types, and the entry points.
//!
//! Reference: the SPIR-V specification, unified (version 1.0 features).

const std = @import("std");

pub const magic = 0x07230203;

/// The opcodes Stardust reads.
pub const Op = struct {
    pub const undef = 1;
    pub const name = 5;
    pub const member_name = 6;
    pub const string = 7;
    pub const line = 8;
    pub const ext_inst_import = 11;
    pub const ext_inst = 12;
    pub const entry_point = 15;
    pub const type_void = 19;
    pub const type_bool = 20;
    pub const type_int = 21;
    pub const type_float = 22;
    pub const type_vector = 23;
    pub const type_matrix = 24;
    pub const type_image = 25;
    pub const type_sampler = 26;
    pub const type_sampled_image = 27;
    pub const type_array = 28;
    pub const type_runtime_array = 29;
    pub const type_struct = 30;
    pub const type_pointer = 32;
    pub const type_function = 33;
    pub const constant_true = 41;
    pub const constant_false = 42;
    pub const constant = 43;
    pub const constant_composite = 44;
    pub const constant_null = 46;
    pub const function = 54;
    pub const function_parameter = 55;
    pub const function_end = 56;
    pub const function_call = 57;
    pub const variable = 59;
    pub const load = 61;
    pub const store = 62;
    pub const access_chain = 65;
    pub const in_bounds_access_chain = 66;
    pub const ptr_access_chain = 67;
    pub const in_bounds_ptr_access_chain = 70;
    pub const decorate = 71;
    pub const member_decorate = 72;
    pub const decoration_group = 73;
    pub const vector_shuffle = 79;
    pub const composite_construct = 80;
    pub const composite_extract = 81;
    pub const composite_insert = 82;
    pub const copy_object = 83;
    pub const sampled_image = 86;
    pub const image_sample_implicit_lod = 87;
    pub const image_sample_explicit_lod = 88;
    pub const convert_f_to_u = 109;
    pub const convert_f_to_s = 110;
    pub const convert_s_to_f = 111;
    pub const convert_u_to_f = 112;
    pub const u_convert = 113;
    pub const s_convert = 114;
    pub const f_convert = 115;
    pub const bitcast = 124;
    pub const s_negate = 126;
    pub const f_negate = 127;
    pub const i_add = 128;
    pub const f_add = 129;
    pub const i_sub = 130;
    pub const f_sub = 131;
    pub const i_mul = 132;
    pub const f_mul = 133;
    pub const f_div = 136;
    pub const vector_times_scalar = 142;
    pub const dot = 148;
    pub const select = 169;
    pub const phi = 245;
    pub const loop_merge = 246;
    pub const selection_merge = 247;
    pub const label = 248;
    pub const branch = 249;
    pub const branch_conditional = 250;
    pub const @"switch" = 251;
    pub const kill = 252;
    pub const @"return" = 253;
    pub const return_value = 254;
    pub const @"unreachable" = 255;
    pub const no_line = 317;
};

pub const Decoration = struct {
    pub const block = 2;
    pub const array_stride = 6;
    pub const builtin = 11;
    pub const location = 30;
    pub const binding = 33;
    pub const descriptor_set = 34;
    pub const offset = 35;
};

pub const BuiltIn = struct {
    pub const position = 0;
};

pub const StorageClass = struct {
    pub const uniform_constant = 0;
    pub const input = 1;
    pub const uniform = 2;
    pub const output = 3;
    pub const private = 6;
    pub const function = 7;
};

pub const ExecutionModel = struct {
    pub const vertex = 0;
    pub const fragment = 4;
};

pub const Inst = struct {
    op: u16,
    /// The words after the opcode word.
    operands: []const u32,
    /// Where it is, for messages: the source line from the last OpLine.
    file: u32 = 0,
    line: u32 = 0,
};

pub const Type = union(enum) {
    void,
    bool,
    int: struct { width: u32, signed: bool },
    float: u32,
    vector: struct { elem: u32, len: u32 },
    array: struct { elem: u32, len: u32 },
    @"struct": []const u32,
    pointer: struct { storage: u32, pointee: u32 },
    image,
    sampled_image,
    function,
    other,
};

pub const EntryPoint = struct {
    model: u32,
    function: u32,
    name: []const u8,
    /// The input and output variables it uses.
    interface: []const u32,
};

pub const Decorations = struct {
    location: ?u32 = null,
    builtin: ?u32 = null,
    binding: ?u32 = null,
    set: ?u32 = null,
    array_stride: ?u32 = null,
};

pub const Error = error{ InvalidSpirv, OutOfMemory };

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    insts: []Inst,
    /// The instruction defining each result id.
    defs: std.AutoHashMapUnmanaged(u32, Inst) = .empty,
    decorations: std.AutoHashMapUnmanaged(u32, Decorations) = .empty,
    /// Byte offsets of struct members, by (struct id << 16 | member).
    member_offsets: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Function bodies (from OpFunction to OpFunctionEnd), by function id.
    functions: std.AutoHashMapUnmanaged(u32, []const Inst) = .empty,
    /// File names (OpString), by id.
    strings: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    entry_points: std.ArrayList(EntryPoint) = .empty,
    /// The id of the GLSL.std.450 extended instruction set, if imported.
    glsl_std_450: ?u32 = null,

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Module {
        var m: Module = .{ .arena = .init(gpa), .insts = &.{} };
        errdefer m.deinit();
        const a = m.arena.allocator();
        if (bytes.len < 20 or bytes.len % 4 != 0) return error.InvalidSpirv;
        const words = try a.alloc(u32, bytes.len / 4);
        for (words, 0..) |*w, i| w.* = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        if (words[0] != magic) return error.InvalidSpirv;

        var list: std.ArrayList(Inst) = .empty;
        var at: usize = 5;
        var file: u32 = 0;
        var line: u32 = 0;
        while (at < words.len) {
            const count = words[at] >> 16;
            const op: u16 = @truncate(words[at]);
            if (count == 0 or at + count > words.len) return error.InvalidSpirv;
            const inst: Inst = .{ .op = op, .operands = words[at + 1 .. at + count], .file = file, .line = line };
            switch (op) {
                Op.line => {
                    if (inst.operands.len >= 2) {
                        file = inst.operands[0];
                        line = inst.operands[1];
                    }
                },
                Op.no_line => line = 0,
                else => try list.append(a, inst),
            }
            at += count;
        }
        m.insts = list.items;

        var fn_start: ?usize = null;
        for (m.insts, 0..) |inst, i| {
            if (resultId(inst)) |id| try m.defs.put(a, id, inst);
            const o = inst.operands;
            switch (inst.op) {
                Op.ext_inst_import => if (std.mem.eql(u8, literalString(o[1..]), "GLSL.std.450")) {
                    m.glsl_std_450 = o[0];
                },
                Op.string => try m.strings.put(a, o[0], literalString(o[1..])),
                Op.entry_point => {
                    const name = literalString(o[2..]);
                    const name_words = name.len / 4 + 1;
                    try m.entry_points.append(a, .{ .model = o[0], .function = o[1], .name = name, .interface = o[@min(2 + name_words, o.len)..] });
                },
                Op.decorate => {
                    if (o.len < 2) return error.InvalidSpirv;
                    const d = try m.decorations.getOrPut(a, o[0]);
                    if (!d.found_existing) d.value_ptr.* = .{};
                    const value: ?u32 = if (o.len > 2) o[2] else null;
                    switch (o[1]) {
                        Decoration.location => d.value_ptr.location = value,
                        Decoration.builtin => d.value_ptr.builtin = value,
                        Decoration.binding => d.value_ptr.binding = value,
                        Decoration.descriptor_set => d.value_ptr.set = value,
                        Decoration.array_stride => d.value_ptr.array_stride = value,
                        else => {},
                    }
                },
                Op.member_decorate => if (o.len >= 4 and o[2] == Decoration.offset) {
                    try m.member_offsets.put(a, @as(u64, o[0]) << 16 | o[1], o[3]);
                },
                Op.function => fn_start = i,
                Op.function_end => {
                    const start = fn_start orelse return error.InvalidSpirv;
                    try m.functions.put(a, m.insts[start].operands[1], m.insts[start .. i + 1]);
                    fn_start = null;
                },
                else => {},
            }
        }
        return m;
    }

    pub fn deinit(m: *Module) void {
        m.arena.deinit();
    }

    pub fn typeOf(m: *const Module, id: u32) Type {
        const inst = m.defs.get(id) orelse return .other;
        const o = inst.operands;
        return switch (inst.op) {
            Op.type_void => .void,
            Op.type_bool => .bool,
            Op.type_int => .{ .int = .{ .width = o[1], .signed = o[2] != 0 } },
            Op.type_float => .{ .float = o[1] },
            Op.type_vector => .{ .vector = .{ .elem = o[1], .len = o[2] } },
            Op.type_array => .{ .array = .{ .elem = o[1], .len = @intCast(m.constantInt(o[2]) orelse 0) } },
            Op.type_struct => .{ .@"struct" = o[1..] },
            Op.type_pointer => .{ .pointer = .{ .storage = o[1], .pointee = o[2] } },
            Op.type_image => .image,
            Op.type_sampled_image => .sampled_image,
            Op.type_function => .function,
            else => .other,
        };
    }

    /// The value of an integer constant.
    pub fn constantInt(m: *const Module, id: u32) ?i64 {
        const inst = m.defs.get(id) orelse return null;
        if (inst.op != Op.constant) return null;
        const t = m.typeOf(inst.operands[0]);
        if (t != .int) return null;
        const lo = inst.operands[2];
        if (t.int.width > 32 and inst.operands.len > 3) return @bitCast(@as(u64, inst.operands[3]) << 32 | lo);
        return if (t.int.signed) @as(i32, @bitCast(lo)) else lo;
    }

    pub fn decorationsOf(m: *const Module, id: u32) Decorations {
        return m.decorations.get(id) orelse .{};
    }

    pub fn memberOffset(m: *const Module, struct_id: u32, member: u32) ?u32 {
        return m.member_offsets.get(@as(u64, struct_id) << 16 | member);
    }

    /// The number of scalars in a vector (1 for a scalar).
    pub fn components(m: *const Module, type_id: u32) u32 {
        return switch (m.typeOf(type_id)) {
            .vector => |v| v.len,
            else => 1,
        };
    }

    /// The size in bytes of a type laid out as Zig's extern structs are.
    pub fn sizeOf(m: *const Module, type_id: u32) u32 {
        return switch (m.typeOf(type_id)) {
            .float => |w| w / 8,
            .int => |i| i.width / 8,
            .bool => 4,
            .vector => |v| m.sizeOf(v.elem) * (if (v.len == 3) 4 else v.len),
            .array => |arr| (m.decorationsOf(type_id).array_stride orelse m.sizeOf(arr.elem)) * arr.len,
            .@"struct" => |members| blk: {
                var end: u32 = 0;
                for (members, 0..) |t, i| end = @max(end, (m.memberOffset(type_id, @intCast(i)) orelse end) + m.sizeOf(t));
                break :blk end;
            },
            else => 0,
        };
    }

    /// "file:line" for an instruction, for messages.
    pub fn where(m: *const Module, inst: Inst, buf: []u8) []const u8 {
        const file = m.strings.get(inst.file) orelse "shader";
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ std.fs.path.basename(file), inst.line }) catch "shader";
    }
};

/// A literal string operand (nul-terminated, padded to words).
pub fn literalString(words: []const u32) []const u8 {
    const bytes = std.mem.sliceAsBytes(words);
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

/// The result id an instruction defines, if any.
pub fn resultId(inst: Inst) ?u32 {
    const o = inst.operands;
    const first = switch (inst.op) {
        Op.ext_inst_import, Op.string, Op.label, Op.decoration_group => true,
        Op.type_void...Op.type_function => true,
        else => false,
    };
    if (first) return if (o.len > 0) o[0] else null;
    const typed = switch (inst.op) {
        Op.undef, Op.ext_inst, Op.constant_true, Op.constant_false, Op.constant, Op.constant_composite, Op.constant_null => true,
        Op.function, Op.function_parameter, Op.function_call, Op.variable, Op.load => true,
        Op.access_chain, Op.in_bounds_access_chain, Op.ptr_access_chain, Op.in_bounds_ptr_access_chain => true,
        Op.vector_shuffle...Op.copy_object, Op.sampled_image...Op.image_sample_explicit_lod => true,
        // Conversions, arithmetic, comparisons and logic.
        Op.convert_f_to_u...230 => true,
        Op.phi => true,
        else => false,
    };
    return if (typed and o.len > 1) o[1] else null;
}
