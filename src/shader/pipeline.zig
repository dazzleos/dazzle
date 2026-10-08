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
        return .{
            .gpa = gpa,
            .program = p,
            .fs = .{ .handle = try dev.createShaderBo(p.fs.code()), .compiled = &p.fs },
            .vs = .{ .handle = try dev.createShaderBo(p.vs.code()), .compiled = &p.vs },
            .cs = .{ .handle = try dev.createShaderBo(p.cs.code()), .compiled = &p.cs },
            .values = values,
            .options = options,
            .offsets = offsets,
        };
    }

    pub fn deinit(p: *Pipeline, dev: anytype) void {
        for ([_]u32{ p.fs.handle, p.vs.handle, p.cs.handle }) |h| vc4.drm.gemClose(dev.fd, h);
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
        /// Defaults to the whole target.
        viewport: ?render.Viewport = null,
        scissor: ?render.Viewport = null,
    };

    /// Records a draw into `frame`, with the uniforms as they are now.
    pub fn draw(p: *Pipeline, frame: *render.Frame, d: Draw) !void {
        const prog = p.program;
        if (prog.fs.num_texture_samples > 0 and d.texture == null) return error.NoTexture;
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
        try frame.draw(.{
            .fs = p.fs.binding(p.values),
            .vs = p.vs.binding(p.values),
            .cs = p.cs.binding(p.values),
            .fs_num_varyings = prog.varying_components,
            .fs_threaded = prog.fs.threaded,
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
                .z_updates = prog.options.depth_test,
                .early_z = prog.options.depth_test and p.options.early_z,
            },
            .viewport = viewport,
            .scissor = d.scissor,
            .texture = d.texture,
        });
    }
};
