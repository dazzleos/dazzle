//! Drawing with a compiled program: its shaders uploaded to the GPU, the
//! vertex layout, and the render state, recording draws into a vc4 frame.

const std = @import("std");
const vc4 = @import("vc4");
const program_mod = @import("program.zig");

const cl = vc4.cl;
const compiler = vc4.compiler;
const render = vc4.render;
const Program = program_mod.Program;

pub const Cull = enum { none, back, front };

/// Where an attribute (by location) is in each vertex.
pub const VertexField = struct {
    location: u32,
    /// Byte offset in the vertex.
    offset: u8,
};

pub const Options = struct {
    /// Bytes from one vertex to the next.
    vertex_stride: u8,
    /// Every input of the vertex shader (floats, as many as its type has).
    attributes: []const VertexField,
    cull: Cull = .none,
    primitive: cl.PrimitiveMode = .triangles,
    /// With depth testing: reject hidden fragments before they are shaded
    /// (the hardware's early Z), which saves shading what is drawn behind
    /// what was drawn before. Every draw in the frame that tests depth must
    /// then test it the same way (less), as all programs here do.
    early_z: bool = false,
    /// With depth testing: whether what is drawn is kept in the depth
    /// buffer. See-through things drawn after the rest (plants, whose
    /// tiles are partly clear) can leave it out, so their clear parts hide
    /// nothing drawn after them.
    depth_write: bool = true,
};

const Stage = struct {
    handle: u32,
    compiled: *const compiler.Compiled,

    fn binding(s: *const Stage, user: []const u32) render.ShaderBinding {
        return .{ .handle = s.handle, .layout = s.compiled.uniforms(), .user = user };
    }
};

pub const Pipeline = struct {
    gpa: std.mem.Allocator,
    program: *Program,
    fs: Stage,
    /// For multisampled frames, if the program blends (see Program.fs_ms).
    fs_ms: ?Stage,
    vs: Stage,
    cs: Stage,
    /// The uniform words, then the viewport scale.
    values: []u32,
    options: Options,
    offsets: [program_mod.max_attributes]u8,

    pub fn init(gpa: std.mem.Allocator, dev: anytype, program: Program, options: Options) !Pipeline {
        const p = try gpa.create(Program);
        errdefer gpa.destroy(p);
        p.* = program;
        var offsets: [program_mod.max_attributes]u8 = undefined;
        for (p.attributeList(), 0..) |a, i| {
            const field = for (options.attributes) |f| {
                if (f.location == a.location) break f;
            } else return error.MissingAttribute;
            offsets[i] = field.offset;
        }
        const values = try gpa.alloc(u32, p.uniform_words + 2);
        errdefer gpa.free(values);
        @memset(values, 0);
        const Dev = switch (@typeInfo(@TypeOf(dev))) {
            .pointer => |ptr| ptr.child,
            else => @TypeOf(dev),
        };
        const is_v3d = if (@hasField(Dev, "is_v3d")) dev.is_v3d else false;
        const v3d_ver: u8 = if (@hasField(Dev, "v3d_ver")) dev.v3d_ver else 42;
        const is_v3d71 = is_v3d and v3d_ver >= 71;
        const fs_c = if (is_v3d71) &p.v3d71_fs else if (is_v3d) &p.v3d_fs else &p.fs;
        const fs_ms_c = if (is_v3d71) &p.v3d71_fs_ms else if (is_v3d) &p.v3d_fs_ms else &p.fs_ms;
        const vs_c = if (is_v3d71) &p.v3d71_vs else if (is_v3d) &p.v3d_vs else &p.vs;
        const cs_c = if (is_v3d71) &p.v3d71_cs else if (is_v3d) &p.v3d_cs else &p.cs;
        return .{
            .gpa = gpa,
            .program = p,
            .fs = .{ .handle = try dev.createShaderBo(fs_c.code()), .compiled = fs_c },
            .fs_ms = if (p.has_fs_ms) .{ .handle = try dev.createShaderBo(fs_ms_c.code()), .compiled = fs_ms_c } else null,
            .vs = .{ .handle = try dev.createShaderBo(vs_c.code()), .compiled = vs_c },
            .cs = .{ .handle = try dev.createShaderBo(cs_c.code()), .compiled = cs_c },
            .values = values,
            .options = options,
            .offsets = offsets,
        };
    }

    pub fn deinit(p: *Pipeline, dev: anytype) void {
        const Dev = switch (@typeInfo(@TypeOf(dev))) {
            .pointer => |ptr| ptr.child,
            else => @TypeOf(dev),
        };
        for ([_]u32{ p.fs.handle, p.vs.handle, p.cs.handle }) |h| {
            if (@hasDecl(Dev, "destroyShaderBo")) dev.destroyShaderBo(h) else vc4.drm.gemClose(dev.fd, h);
        }
        if (p.fs_ms) |ms| {
            if (@hasDecl(Dev, "destroyShaderBo")) dev.destroyShaderBo(ms.handle) else vc4.drm.gemClose(dev.fd, ms.handle);
        }
        p.gpa.free(p.values);
        p.gpa.destroy(p.program);
    }

    /// Sets the uniform block: the bytes of the shader's uniforms struct.
    pub fn setUniforms(p: *Pipeline, bytes: []const u8) void {
        const n = @min(bytes.len / 4, p.program.uniform_words);
        for (p.values[0..n], 0..) |*w, i| w.* = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    }

    pub const Draw = struct {
        /// GEM handle of the buffer holding the vertices.
        vertices: u32,
        /// Byte offset of vertex 0 in it.
        vertex_offset: u32 = 0,
        /// Vertex count, or index count with `indices`.
        count: u32,
        first: u32 = 0,
        indices: ?render.Indices = null,
        /// For fragment shaders that sample a texture.
        texture: ?render.Texture = null,
        /// For those that sample a second (`gpu.texture1`), and a third.
        texture1: ?render.Texture = null,
        texture2: ?render.Texture = null,
        /// Defaults to the whole target.
        viewport: ?render.Viewport = null,
        scissor: ?render.Viewport = null,
    };

    /// Records a draw into `frame`, with the uniforms as they are now.
    pub fn draw(p: *Pipeline, frame: *render.Frame, d: Draw) !void {
        const prog = p.program;
        const slots = prog.fs.textureSlots();
        for ([_]?render.Texture{ d.texture, d.texture1, d.texture2 }, 0..) |t, i| {
            if (slots >> @intCast(i) & 1 != 0 and t == null) return error.NoTexture;
        }
        var attrs: [program_mod.max_attributes]render.Attribute = undefined;
        var vs_size: u8 = 0;
        var cs_size: u8 = 0;
        var cs_mask: u8 = 0;
        for (prog.attributeList(), 0..) |a, i| {
            const size = a.components * 4;
            attrs[i] = .{
                .handle = d.vertices,
                .offset = d.vertex_offset + p.offsets[i],
                .size = size,
                .stride = p.options.vertex_stride,
                .vs_vpm_offset = vs_size,
                .cs_vpm_offset = if (a.in_coordinate_shader) cs_size else 0,
            };
            vs_size += size;
            if (a.in_coordinate_shader) {
                cs_mask |= @as(u8, 1) << @intCast(i);
                cs_size += size;
            }
        }
        const viewport = d.viewport orelse frame.target.fullViewport();
        const scale = viewport.scaleBits();
        p.values[prog.uniform_words] = scale[0];
        p.values[prog.uniform_words + 1] = scale[1];
        const cull = p.options.cull;
        const fs = if (frame.msaa) p.fs_ms orelse p.fs else p.fs;
        try frame.draw(.{
            .fs = fs.binding(p.values),
            .vs = p.vs.binding(p.values),
            .cs = p.cs.binding(p.values),
            .fs_num_varyings = prog.varying_components,
            .fs_threaded = fs.compiled.threaded,
            .attributes = attrs[0..prog.num_attributes],
            .vs_attribute_mask = @intCast((@as(u16, 1) << @intCast(prog.num_attributes)) - 1),
            .vs_attributes_size = vs_size,
            .cs_attribute_mask = cs_mask,
            .cs_attributes_size = cs_size,
            .primitive = p.options.primitive,
            .count = d.count,
            .first = d.first,
            .indices = d.indices,
            .config = .{
                .enable_forward_facing = cull != .front,
                .enable_reverse_facing = cull != .back,
                // Front faces wind counter-clockwise in clip space; on the
                // screen, where y points down, that is clockwise.
                .clockwise_primitives = true,
                .depth_func = if (prog.options.depth_test) .less else .always,
                .z_updates = prog.options.depth_test and p.options.depth_write,
                .early_z = prog.options.depth_test and p.options.early_z,
                .early_z_updates = p.options.depth_write,
            },
            .viewport = viewport,
            .scissor = d.scissor,
            .texture = d.texture,
            .texture1 = d.texture1,
            .texture2 = d.texture2,
        });
    }
};
