//! A GLSL program compiled for the GPU, with the render state it is drawn
//! with: what native Stardust apps use to draw with GLSL shaders on the
//! vc4 API.
//!
//! The three hardware shaders (coordinate, vertex and fragment) are built
//! once, for one interleaved vertex layout. Uniforms are set by name and
//! copied into the frame with each draw, so they can change between draws.

const std = @import("std");
const sys = @import("sys");
const vc4 = @import("vc4");
const program = @import("program.zig");

const cl = vc4.cl;
const compiler = vc4.compiler;
const render = vc4.render;

pub const Cull = enum { none, back, front };

/// Where an attribute is in each vertex.
pub const VertexField = struct {
    name: []const u8,
    /// Byte offset in the vertex.
    offset: u8,
};

pub const Options = struct {
    /// Bytes from one vertex to the next.
    vertex_stride: u8,
    /// Every attribute the vertex shader reads (floats, as many as its
    /// type has components).
    attributes: []const VertexField,
    /// Test against (and write) the tile buffer's depth, keeping the
    /// nearest fragment.
    depth_test: bool = false,
    cull: Cull = .none,
    primitive: cl.PrimitiveMode = .triangles,
};

const Stage = struct {
    handle: u32,
    compiled: compiler.Compiled,

    fn init(dev: vc4.Device, gpa: std.mem.Allocator, p: *const program.Program, stage: compiler.Stage, depth_write: bool) !Stage {
        const shader = try gpa.create(compiler.Shader);
        defer gpa.destroy(shader);
        try p.build(stage, .{ .depth_write = depth_write }, shader);
        const compiled = try compiler.compile(shader);
        return .{ .handle = try dev.createShaderBo(compiled.code()), .compiled = compiled };
    }

    fn binding(s: *const Stage, user: []const u32) render.ShaderBinding {
        return .{ .handle = s.handle, .layout = s.compiled.uniforms(), .user = user };
    }
};

/// One attribute's place in the vertex and in the shaders' input.
const Input = struct {
    offset: u8,
    components: u8,
    in_coordinate_shader: bool,
};

pub const Pipeline = struct {
    gpa: std.mem.Allocator,
    linked: *program.Program,
    fs: Stage,
    vs: Stage,
    cs: Stage,
    /// The uniform array, then the viewport scale.
    values: []u32,
    options: Options,
    inputs: [program.max_attributes]Input,
    num_inputs: usize,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device, vs_source: []const u8, fs_source: []const u8, options: Options) !Pipeline {
        var log: program.Log = .{};
        var vs = program.compileShader(gpa, .vertex, vs_source, &log) catch |err| return report("vertex shader", err, &log);
        defer vs.deinit();
        var fs = program.compileShader(gpa, .fragment, fs_source, &log) catch |err| return report("fragment shader", err, &log);
        defer fs.deinit();
        const linked = program.link(gpa, &vs, &fs, &.{}, &log) catch |err| return report("program", err, &log);
        errdefer {
            linked.deinit();
            gpa.destroy(linked);
        }

        var p: Pipeline = .{
            .gpa = gpa,
            .linked = linked,
            .fs = undefined,
            .vs = undefined,
            .cs = undefined,
            .values = undefined,
            .options = options,
            .inputs = undefined,
            .num_inputs = 0,
        };
        // The vertex layout, in the program's attribute order.
        for (linked.attributeList()) |a| {
            const field = for (options.attributes) |f| {
                if (std.mem.eql(u8, f.name, a.name)) break f;
            } else {
                sys.print("stardust: the vertex layout has no attribute '{s}'\n", .{a.name});
                return error.MissingAttribute;
            };
            p.inputs[p.num_inputs] = .{ .offset = field.offset, .components = a.type.components(), .in_coordinate_shader = a.in_coordinate_shader };
            p.num_inputs += 1;
        }

        p.values = try gpa.alloc(u32, linked.uniform_words + 2);
        errdefer gpa.free(p.values);
        @memset(p.values, 0);
        p.fs = try Stage.init(dev, gpa, linked, .fragment, options.depth_test);
        p.vs = try Stage.init(dev, gpa, linked, .vertex, false);
        p.cs = try Stage.init(dev, gpa, linked, .coordinate, false);
        return p;
    }

    fn report(what: []const u8, err: anyerror, log: *const program.Log) anyerror {
        sys.print("stardust: the {s} does not compile:\n{s}", .{ what, log.text() });
        return err;
    }

    /// Sets a uniform: a float, or an array of floats for vectors and
    /// (column-major) matrices.
    pub fn set(p: *Pipeline, name: []const u8, value: anytype) !void {
        const u = p.linked.findUniform(name) orelse return error.NoSuchUniform;
        const words: []const f32 = switch (@typeInfo(@TypeOf(value))) {
            .float, .comptime_float => &.{@as(f32, value)},
            .array => &value,
            .pointer => value,
            else => @compileError("uniforms are floats or arrays of floats"),
        };
        if (words.len != u.type.components()) return error.WrongUniformSize;
        for (words, p.values[u.base..][0..words.len]) |f, *w| w.* = @bitCast(f);
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
        if (p.fs.compiled.num_texture_samples > 0 and d.texture == null) return error.NoTexture;
        var attrs: [program.max_attributes]render.Attribute = undefined;
        var vs_size: u8 = 0;
        var cs_size: u8 = 0;
        var cs_mask: u8 = 0;
        for (p.inputs[0..p.num_inputs], 0..) |in, i| {
            const size = in.components * 4;
            attrs[i] = .{
                .handle = d.vertices,
                .offset = d.vertex_offset + in.offset,
                .size = size,
                .stride = p.options.vertex_stride,
                .vs_vpm_offset = vs_size,
                .cs_vpm_offset = if (in.in_coordinate_shader) cs_size else 0,
            };
            vs_size += size;
            if (in.in_coordinate_shader) {
                cs_mask |= @as(u8, 1) << @intCast(i);
                cs_size += size;
            }
        }
        const viewport = d.viewport orelse frame.target.fullViewport();
        const scale = viewport.scaleBits();
        const vp = p.linked.viewportUniform();
        p.values[vp] = scale[0];
        p.values[vp + 1] = scale[1];
        const cull = p.options.cull;
        try frame.draw(.{
            .fs = p.fs.binding(p.values),
            .vs = p.vs.binding(p.values),
            .cs = p.cs.binding(p.values),
            .fs_num_varyings = p.linked.varyingComponents(),
            .attributes = attrs[0..p.num_inputs],
            .vs_attribute_mask = @intCast((@as(u16, 1) << @intCast(p.num_inputs)) - 1),
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
                // Front faces wind counter-clockwise in clip space, as in
                // GL; on the screen, where y points down, that is
                // clockwise.
                .clockwise_primitives = true,
                .depth_func = if (p.options.depth_test) .less else .always,
                .z_updates = p.options.depth_test,
            },
            .viewport = viewport,
            .scissor = d.scissor,
            .texture = d.texture,
        });
    }

    pub fn deinit(p: *Pipeline, dev: vc4.Device) void {
        for ([_]*Stage{ &p.fs, &p.vs, &p.cs }) |s| {
            vc4.drm.gemClose(dev.fd, s.handle);
        }
        p.gpa.free(p.values);
        p.linked.deinit();
        p.gpa.destroy(p.linked);
    }
};
