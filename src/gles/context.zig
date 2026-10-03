//! OpenGL ES 2.0 context state, and how GL calls turn into vc4 frames.
//!
//! Draws are recorded into one `render.Frame` per rendered frame and
//! submitted at `eglSwapBuffers` (or earlier, if the frame fills up or is
//! cleared part way through). The GPU only reads buffers, textures and
//! shaders while a frame runs, and frames are waited for, so an object that
//! is still referenced by the frame being recorded is replaced rather than
//! overwritten when the app changes it, and the old GPU memory is freed
//! once the frame is done.
//!
//! Programs are compiled to QPU code lazily, per combination of the
//! state the hardware shaders depend on (whether depth testing is on, and
//! how many components each vertex attribute supplies).
//!
//! The context talks to the GPU through `Backend`, so the GL layer can be
//! tested on the host without one.

const std = @import("std");
const sys = @import("sys");
const vc4 = @import("vc4");
pub const glsl = @import("glsl/program.zig");
const gl = @import("gl.zig");

const cl = vc4.cl;
const compiler = vc4.compiler;
const render = vc4.render;
const texture = vc4.texture;
const Allocator = std.mem.Allocator;

pub const max_vertex_attribs = glsl.max_attributes;
pub const max_texture_units = 8;
pub const max_texture_size = 2048;
const max_buffers = 256;
const max_textures = 64;
/// Shaders and programs share one name space.
const max_glsl_objects = 64;
const max_variants = 4;
const stream_size = 256 * 1024;

/// The context made current by EGL.
pub var current: ?*Context = null;

/// Access to the GPU.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBo: *const fn (ptr: *anyopaque, size: u32) anyerror!vc4.Bo,
        destroyBo: *const fn (ptr: *anyopaque, bo: vc4.Bo) void,
        createShader: *const fn (ptr: *anyopaque, code: []const vc4.qpu.Inst) anyerror!u32,
        destroyShader: *const fn (ptr: *anyopaque, handle: u32) void,
        /// Submits a finished frame and waits for it to complete.
        run: *const fn (ptr: *anyopaque, frame: *render.Frame) anyerror!void,
    };

    fn createBo(b: Backend, size: u32) !vc4.Bo {
        return b.vtable.createBo(b.ptr, size);
    }
    fn destroyBo(b: Backend, bo: vc4.Bo) void {
        b.vtable.destroyBo(b.ptr, bo);
    }
    fn createShader(b: Backend, code: []const vc4.qpu.Inst) !u32 {
        return b.vtable.createShader(b.ptr, code);
    }
    fn destroyShader(b: Backend, handle: u32) void {
        b.vtable.destroyShader(b.ptr, handle);
    }
    fn run(b: Backend, frame: *render.Frame) !void {
        return b.vtable.run(b.ptr, frame);
    }
};

const Buffer = struct {
    live: bool = false,
    bo: ?vc4.Bo = null,
    size: u32 = 0,
    usage: gl.GLenum = gl.GL_STATIC_DRAW,
    /// The frame serial this buffer was last drawn with.
    serial: u32 = 0,
};

const Texture = struct {
    live: bool = false,
    bo: ?vc4.Bo = null,
    width: u32 = 0,
    height: u32 = 0,
    min_filter: gl.GLenum = gl.GL_NEAREST_MIPMAP_LINEAR,
    mag_filter: gl.GLenum = gl.GL_LINEAR,
    wrap_s: gl.GLenum = gl.GL_REPEAT,
    wrap_t: gl.GLenum = gl.GL_REPEAT,
    serial: u32 = 0,

    fn config(t: *const Texture) texture.Config {
        return .{
            .width = t.width,
            .height = t.height,
            .min_filter = switch (t.min_filter) {
                // Without mipmaps, the mipmapped filters use the base level.
                gl.GL_NEAREST, gl.GL_NEAREST_MIPMAP_NEAREST, gl.GL_NEAREST_MIPMAP_LINEAR => .nearest,
                else => .linear,
            },
            .mag_filter = if (t.mag_filter == gl.GL_NEAREST) .nearest else .linear,
            .wrap_s = wrap(t.wrap_s),
            .wrap_t = wrap(t.wrap_t),
        };
    }

    fn wrap(w: gl.GLenum) texture.Wrap {
        return switch (w) {
            gl.GL_CLAMP_TO_EDGE => .clamp,
            gl.GL_MIRRORED_REPEAT => .mirror,
            else => .repeat,
        };
    }
};

pub const ShaderObject = struct {
    stage: glsl.Stage,
    source: []u8 = &.{},
    compiled: ?glsl.Shader = null,
    log: glsl.Log = .{},
    /// Programs it is attached to.
    attached: u32 = 0,
    delete_pending: bool = false,
};

const Stage = struct {
    handle: u32,
    compiled: compiler.Compiled,

    fn binding(s: *const Stage, user: []const u32) render.ShaderBinding {
        return .{ .handle = s.handle, .layout = s.compiled.uniforms(), .user = user };
    }
};

/// The hardware shaders for one program and state combination.
const Variant = struct {
    depth_write: bool,
    supplied: [max_vertex_attribs]u8,
    fs: Stage,
    vs: Stage,
    cs: Stage,
};

pub const ProgramObject = struct {
    vs: u32 = 0,
    fs: u32 = 0,
    /// From glBindAttribLocation; names are owned.
    bindings: std.ArrayList(glsl.Binding) = .empty,
    linked: ?*glsl.Program = null,
    log: glsl.Log = .{},
    /// The uniform array, plus the viewport scale.
    values: []u32 = &.{},
    /// The texture unit for each sampler uniform, by uniform index.
    units: [64]u8 = @splat(0),
    variants: [max_variants]?*Variant = @splat(null),
    next_variant: u8 = 0,
    delete_pending: bool = false,
};

const GlslObject = union(enum) {
    free,
    shader: *ShaderObject,
    program: *ProgramObject,
};

const VertexAttrib = struct {
    enabled: bool = false,
    size: c_int = 4,
    stride: u32 = 0,
    /// Buffer name, or 0 for client memory.
    buffer: u32 = 0,
    /// Byte offset into the buffer, or the client pointer.
    offset: usize = 0,
    current: [4]f32 = .{ 0, 0, 0, 1 },
};

const Garbage = union(enum) {
    bo: vc4.Bo,
    shader: u32,
};

pub const Warning = enum {
    blend,
    stencil,
    color_mask,
    depth_range,
    line_width,
    points,
    attrib_type,
    texture_format,
    mipmaps,
    multiple_samplers,
    partial_clear,
    framebuffer_objects,
    read_pixels,
    frame_split,
    polygon_offset,
};

pub const Elements = struct {
    type: gl.GLenum,
    /// Offset into the element array buffer, or a client pointer.
    pointer: usize,
};

pub const Context = struct {
    gpa: Allocator,
    backend: Backend,

    /// The surface's back buffer, set by EGL.
    target: ?render.Target = null,
    frame: render.Frame = undefined,
    frame_open: bool = false,
    /// How the next frame starts.
    next_load: render.Load = .keep,
    next_clear_z: u32 = 0xffffff,
    /// Incremented after each submitted frame; objects drawn in the open
    /// frame carry the current value.
    serial: u32 = 1,
    garbage: std.ArrayList(Garbage) = .empty,
    /// Per-frame copies of client vertex data, indices and constant
    /// attributes.
    stream: ?vc4.Bo = null,
    stream_used: u32 = 0,
    /// A 1x1 opaque black texture for samplers with no usable texture.
    black: ?vc4.Bo = null,

    err: gl.GLenum = gl.GL_NO_ERROR,
    warned: std.EnumSet(Warning) = .initEmpty(),

    clear_color: [4]f32 = .{ 0, 0, 0, 0 },
    clear_depth: f32 = 1,
    viewport: [4]c_int = .{ 0, 0, 0, 0 },
    scissor: [4]c_int = .{ 0, 0, 0, 0 },
    depth_test: bool = false,
    cull_face: bool = false,
    scissor_test: bool = false,
    blend: bool = false,
    stencil_test: bool = false,
    dither: bool = true,
    polygon_offset_fill: bool = false,
    sample_alpha_to_coverage: bool = false,
    sample_coverage: bool = false,
    cull_mode: gl.GLenum = gl.GL_BACK,
    front_face: gl.GLenum = gl.GL_CCW,
    depth_func: gl.GLenum = gl.GL_LESS,
    depth_mask: bool = true,
    unpack_alignment: u32 = 4,

    array_buffer: u32 = 0,
    element_array_buffer: u32 = 0,
    attribs: [max_vertex_attribs]VertexAttrib = undefined,
    active_texture: u32 = 0,
    texture_units: [max_texture_units]u32 = @splat(0),
    program: u32 = 0,

    // Initialised by `create` (a default value would be stored in the
    // binary).
    buffers: [max_buffers]Buffer = undefined,
    textures: [max_textures]Texture = undefined,
    glsl_objects: [max_glsl_objects]GlslObject = undefined,

    /// Creates a context. It is large (it holds a frame), so it lives on
    /// the heap.
    pub fn create(gpa: Allocator, backend: Backend) !*Context {
        const c = try gpa.create(Context);
        c.* = .{ .gpa = gpa, .backend = backend };
        @memset(&c.attribs, .{});
        @memset(&c.buffers, .{});
        @memset(&c.textures, .{});
        @memset(&c.glsl_objects, .free);
        return c;
    }

    pub fn destroy(c: *Context) void {
        for (&c.glsl_objects, 1..) |*o, name| switch (o.*) {
            .free => {},
            .program => {
                c.freeProgram(@intCast(name));
            },
            .shader => {},
        };
        for (&c.glsl_objects) |*o| switch (o.*) {
            .shader => |s| {
                c.freeShader(s);
                o.* = .free;
            },
            else => {},
        };
        for (&c.buffers) |*b| if (b.bo) |bo| c.backend.destroyBo(bo);
        for (&c.textures) |*t| if (t.bo) |bo| c.backend.destroyBo(bo);
        if (c.stream) |bo| c.backend.destroyBo(bo);
        if (c.black) |bo| c.backend.destroyBo(bo);
        c.collectGarbage();
        c.garbage.deinit(c.gpa);
        if (current == c) current = null;
        c.gpa.destroy(c);
    }

    pub fn setError(c: *Context, e: gl.GLenum) void {
        if (c.err == gl.GL_NO_ERROR) c.err = e;
    }

    pub fn warnOnce(c: *Context, comptime w: Warning) void {
        if (c.warned.contains(w)) return;
        c.warned.insert(w);
        const what = switch (w) {
            .blend => "blending is not supported yet; drawing opaquely",
            .stencil => "the stencil test is not supported yet",
            .color_mask => "colour masks are not supported yet",
            .depth_range => "glDepthRangef is not supported yet",
            .line_width => "only 1 pixel wide lines are supported",
            .points => "points are not supported yet",
            .attrib_type => "only GL_FLOAT vertex attributes are supported",
            .texture_format => "only GL_UNSIGNED_BYTE RGBA, RGB, LUMINANCE, LUMINANCE_ALPHA and ALPHA textures are supported",
            .mipmaps => "mipmaps are not supported yet; textures use the base level",
            .multiple_samplers => "only one texture per draw is supported yet",
            .partial_clear => "clears are not limited by the scissor box yet",
            .framebuffer_objects => "framebuffer objects are not supported yet",
            .read_pixels => "glReadPixels is not supported yet",
            .frame_split => "a frame was split into several GPU jobs; depth values do not carry over between them",
            .polygon_offset => "polygon offset is not supported yet",
        };
        sys.print("stardust gl: {s}\n", .{what});
    }

    // --- Frames ---------------------------------------------------------------

    /// Points the context at a new surface back buffer. Any recorded
    /// rendering must have been submitted.
    pub fn setTarget(c: *Context, target: render.Target) void {
        std.debug.assert(!c.frame_open);
        c.target = target;
    }

    fn openFrame(c: *Context) *render.Frame {
        if (!c.frame_open) {
            c.frame.begin(c.target.?, c.next_load);
            c.frame.clear_z = c.next_clear_z;
            c.frame_open = true;
            c.next_load = .keep;
            c.next_clear_z = 0xffffff;
        }
        return &c.frame;
    }

    /// Submits everything recorded so far and waits for the GPU. A pending
    /// clear with no draws is still carried out.
    pub fn submit(c: *Context) void {
        if (c.target == null) return;
        if (!c.frame_open) {
            if (c.next_load == .keep) return;
            _ = c.openFrame();
        }
        _ = c.frame.finish();
        c.frame_open = false;
        c.backend.run(&c.frame) catch |e| {
            sys.print("stardust gl: GPU job failed: {s}\n", .{@errorName(e)});
            c.setError(gl.GL_OUT_OF_MEMORY);
        };
        c.serial +%= 1;
        c.stream_used = 0;
        c.collectGarbage();
    }

    fn collectGarbage(c: *Context) void {
        for (c.garbage.items) |g| switch (g) {
            .bo => |bo| c.backend.destroyBo(bo),
            .shader => |h| c.backend.destroyShader(h),
        };
        c.garbage.clearRetainingCapacity();
    }

    /// Frees a buffer object once the open frame no longer needs it.
    fn retireBo(c: *Context, bo: vc4.Bo, serial: u32) void {
        if (c.frame_open and serial == c.serial) {
            c.garbage.append(c.gpa, .{ .bo = bo }) catch {
                // Without room to defer it, wait for the frame instead.
                c.splitFrame();
                c.backend.destroyBo(bo);
            };
        } else {
            c.backend.destroyBo(bo);
        }
    }

    fn retireShader(c: *Context, handle: u32) void {
        if (c.frame_open) {
            c.garbage.append(c.gpa, .{ .shader = handle }) catch {
                c.splitFrame();
                c.backend.destroyShader(handle);
            };
        } else {
            c.backend.destroyShader(handle);
        }
    }

    /// Submits the frame part way through, keeping its colour.
    fn splitFrame(c: *Context) void {
        if (!c.frame_open) return;
        c.warnOnce(.frame_split);
        c.submit();
    }

    pub fn clear(c: *Context, mask: gl.GLbitfield) void {
        if (mask & ~(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT | gl.GL_STENCIL_BUFFER_BIT) != 0)
            return c.setError(gl.GL_INVALID_VALUE);
        if (c.target == null) return;
        if (c.scissor_test) c.warnOnce(.partial_clear);
        const color = mask & gl.GL_COLOR_BUFFER_BIT != 0;
        const depth = mask & gl.GL_DEPTH_BUFFER_BIT != 0;
        if (!color and !depth) return;
        // Clears happen at the start of a frame (the hardware loads the
        // clear values into each tile), so a clear after drawing starts a
        // new GPU job.
        // That job loads the colour back but always starts with cleared
        // depth, which is only a problem if depth was meant to be kept.
        if (c.frame_open) {
            if (!depth) c.warnOnce(.frame_split);
            c.submit();
        }
        if (color) c.next_load = .{ .clear = packColor(c.clear_color) };
        // Depth starts cleared in every frame; only the value can change.
        c.next_clear_z = @intFromFloat(c.clear_depth * 0xffffff);
    }

    // --- Capabilities and queries -----------------------------------------

    pub fn capability(c: *Context, cap: gl.GLenum) ?*bool {
        return switch (cap) {
            gl.GL_DEPTH_TEST => &c.depth_test,
            gl.GL_CULL_FACE => &c.cull_face,
            gl.GL_SCISSOR_TEST => &c.scissor_test,
            gl.GL_BLEND => &c.blend,
            gl.GL_STENCIL_TEST => &c.stencil_test,
            gl.GL_DITHER => &c.dither,
            gl.GL_POLYGON_OFFSET_FILL => &c.polygon_offset_fill,
            gl.GL_SAMPLE_ALPHA_TO_COVERAGE => &c.sample_alpha_to_coverage,
            gl.GL_SAMPLE_COVERAGE => &c.sample_coverage,
            else => null,
        };
    }

    pub fn setCapability(c: *Context, cap: gl.GLenum, on: bool) void {
        const p = c.capability(cap) orelse return c.setError(gl.GL_INVALID_ENUM);
        p.* = on;
        if (on) switch (cap) {
            gl.GL_BLEND => c.warnOnce(.blend),
            gl.GL_STENCIL_TEST => c.warnOnce(.stencil),
            gl.GL_POLYGON_OFFSET_FILL => c.warnOnce(.polygon_offset),
            else => {},
        };
    }

    pub fn isEnabled(c: *Context, cap: gl.GLenum) bool {
        const p = c.capability(cap) orelse {
            c.setError(gl.GL_INVALID_ENUM);
            return false;
        };
        return p.*;
    }

    pub fn getIntegers(c: *Context, pname: gl.GLenum, buf: *[4]c_int) ?[]const c_int {
        const one = struct {
            fn f(b: *[4]c_int, v: anytype) []const c_int {
                b[0] = @intCast(v);
                return b[0..1];
            }
        }.f;
        if (c.capability(pname)) |p| return one(buf, @intFromBool(p.*));
        return switch (pname) {
            gl.GL_VIEWPORT => &c.viewport,
            gl.GL_SCISSOR_BOX => &c.scissor,
            gl.GL_MAX_VIEWPORT_DIMS => blk: {
                buf.* = .{ max_texture_size, max_texture_size, 0, 0 };
                break :blk buf[0..2];
            },
            gl.GL_MAX_TEXTURE_SIZE, gl.GL_MAX_RENDERBUFFER_SIZE => one(buf, max_texture_size),
            gl.GL_MAX_CUBE_MAP_TEXTURE_SIZE => one(buf, 0),
            gl.GL_MAX_VERTEX_ATTRIBS => one(buf, max_vertex_attribs),
            gl.GL_MAX_VERTEX_UNIFORM_VECTORS, gl.GL_MAX_FRAGMENT_UNIFORM_VECTORS => one(buf, 16),
            gl.GL_MAX_VARYING_VECTORS => one(buf, 8),
            gl.GL_MAX_TEXTURE_IMAGE_UNITS, gl.GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS => one(buf, max_texture_units),
            gl.GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS => one(buf, 0),
            gl.GL_NUM_COMPRESSED_TEXTURE_FORMATS, gl.GL_NUM_SHADER_BINARY_FORMATS => one(buf, 0),
            gl.GL_SUBPIXEL_BITS => one(buf, 4),
            gl.GL_RED_BITS, gl.GL_GREEN_BITS, gl.GL_BLUE_BITS => one(buf, 8),
            gl.GL_ALPHA_BITS => one(buf, 8),
            gl.GL_STENCIL_BITS => one(buf, 0),
            gl.GL_DEPTH_BITS => one(buf, 24),
            gl.GL_DEPTH_FUNC => one(buf, c.depth_func),
            gl.GL_DEPTH_WRITEMASK => one(buf, @intFromBool(c.depth_mask)),
            gl.GL_CULL_FACE_MODE => one(buf, c.cull_mode),
            gl.GL_FRONT_FACE => one(buf, c.front_face),
            gl.GL_UNPACK_ALIGNMENT => one(buf, c.unpack_alignment),
            gl.GL_PACK_ALIGNMENT => one(buf, 4),
            gl.GL_ARRAY_BUFFER_BINDING => one(buf, c.array_buffer),
            gl.GL_ELEMENT_ARRAY_BUFFER_BINDING => one(buf, c.element_array_buffer),
            gl.GL_CURRENT_PROGRAM => one(buf, c.program),
            gl.GL_ACTIVE_TEXTURE => one(buf, gl.GL_TEXTURE0 + c.active_texture),
            gl.GL_TEXTURE_BINDING_2D => one(buf, c.texture_units[c.active_texture]),
            gl.GL_IMPLEMENTATION_COLOR_READ_FORMAT => one(buf, gl.GL_RGBA),
            gl.GL_IMPLEMENTATION_COLOR_READ_TYPE => one(buf, gl.GL_UNSIGNED_BYTE),
            gl.GL_SHADER_COMPILER => one(buf, 1),
            else => null,
        };
    }

    // --- Buffers --------------------------------------------------------------

    pub fn genBuffer(c: *Context) u32 {
        for (c.buffers[1..], 1..) |*b, i| if (!b.live) {
            b.* = .{ .live = true };
            return @intCast(i);
        };
        c.setError(gl.GL_OUT_OF_MEMORY);
        return 0;
    }

    pub fn lookupBuffer(c: *Context, name: u32) ?*Buffer {
        if (name == 0 or name >= max_buffers or !c.buffers[name].live) return null;
        return &c.buffers[name];
    }

    pub fn deleteBuffer(c: *Context, name: u32) void {
        const b = c.lookupBuffer(name) orelse return;
        if (b.bo) |bo| c.retireBo(bo, b.serial);
        b.* = .{};
        if (c.array_buffer == name) c.array_buffer = 0;
        if (c.element_array_buffer == name) c.element_array_buffer = 0;
        for (&c.attribs) |*a| if (a.buffer == name) {
            a.buffer = 0;
        };
    }

    fn bufferBinding(c: *Context, target: gl.GLenum) ?*u32 {
        return switch (target) {
            gl.GL_ARRAY_BUFFER => &c.array_buffer,
            gl.GL_ELEMENT_ARRAY_BUFFER => &c.element_array_buffer,
            else => null,
        };
    }

    pub fn bindBuffer(c: *Context, target: gl.GLenum, name: u32) void {
        const binding = c.bufferBinding(target) orelse return c.setError(gl.GL_INVALID_ENUM);
        if (name != 0 and c.lookupBuffer(name) == null) {
            // Binding an unused name creates the buffer.
            if (name >= max_buffers) return c.setError(gl.GL_OUT_OF_MEMORY);
            c.buffers[name] = .{ .live = true };
        }
        binding.* = name;
    }

    pub fn boundBuffer(c: *Context, target: gl.GLenum) ?*Buffer {
        const binding = c.bufferBinding(target) orelse return null;
        return c.lookupBuffer(binding.*);
    }

    pub fn bufferData(c: *Context, target: gl.GLenum, size: u32, data: ?[]const u8, usage: gl.GLenum) void {
        if (c.bufferBinding(target) == null) return c.setError(gl.GL_INVALID_ENUM);
        if (usage != gl.GL_STREAM_DRAW and usage != gl.GL_STATIC_DRAW and usage != gl.GL_DYNAMIC_DRAW)
            return c.setError(gl.GL_INVALID_ENUM);
        const b = c.boundBuffer(target) orelse return c.setError(gl.GL_INVALID_OPERATION);
        const in_use = c.frame_open and b.serial == c.serial;
        if (b.bo) |bo| if (in_use or bo.map.len < size) {
            c.retireBo(bo, b.serial);
            b.bo = null;
        };
        b.size = size;
        b.usage = usage;
        if (size == 0) return;
        if (b.bo == null) b.bo = c.backend.createBo(size) catch return c.setError(gl.GL_OUT_OF_MEMORY);
        if (data) |d| @memcpy(b.bo.?.map[0..size], d);
    }

    pub fn bufferSubData(c: *Context, target: gl.GLenum, offset: u32, data: []const u8) void {
        if (c.bufferBinding(target) == null) return c.setError(gl.GL_INVALID_ENUM);
        const b = c.boundBuffer(target) orelse return c.setError(gl.GL_INVALID_OPERATION);
        if (offset + data.len > b.size) return c.setError(gl.GL_INVALID_VALUE);
        if (data.len == 0) return;
        if (c.frame_open and b.serial == c.serial) {
            // The open frame still reads the old contents: copy them.
            const old = b.bo.?;
            const bo = c.backend.createBo(@intCast(old.map.len)) catch return c.setError(gl.GL_OUT_OF_MEMORY);
            @memcpy(bo.map[0..b.size], old.map[0..b.size]);
            c.retireBo(old, b.serial);
            b.bo = bo;
        }
        @memcpy(b.bo.?.map[offset..][0..data.len], data);
    }

    // --- Vertex attributes ----------------------------------------------------

    pub fn attrib(c: *Context, index: u32) ?*VertexAttrib {
        if (index >= max_vertex_attribs) {
            c.setError(gl.GL_INVALID_VALUE);
            return null;
        }
        return &c.attribs[index];
    }

    pub fn vertexAttribPointer(c: *Context, index: u32, size: c_int, ty: gl.GLenum, normalized: bool, stride: c_int, pointer: ?*const anyopaque) void {
        _ = normalized;
        const a = c.attrib(index) orelse return;
        if (size < 1 or size > 4 or stride < 0) return c.setError(gl.GL_INVALID_VALUE);
        if (ty != gl.GL_FLOAT) {
            c.warnOnce(.attrib_type);
            return c.setError(gl.GL_INVALID_ENUM);
        }
        a.size = size;
        a.stride = @intCast(stride);
        a.buffer = c.array_buffer;
        a.offset = @intFromPtr(pointer);
    }

    pub fn enableAttrib(c: *Context, index: u32, on: bool) void {
        const a = c.attrib(index) orelse return;
        a.enabled = on;
    }

    pub fn vertexAttrib(c: *Context, index: u32, v: [4]f32) void {
        const a = c.attrib(index) orelse return;
        a.current = v;
    }

    // --- Textures -------------------------------------------------------------

    pub fn genTexture(c: *Context) u32 {
        for (c.textures[1..], 1..) |*t, i| if (!t.live) {
            t.* = .{ .live = true };
            return @intCast(i);
        };
        c.setError(gl.GL_OUT_OF_MEMORY);
        return 0;
    }

    pub fn lookupTexture(c: *Context, name: u32) ?*Texture {
        if (name == 0 or name >= max_textures or !c.textures[name].live) return null;
        return &c.textures[name];
    }

    pub fn deleteTexture(c: *Context, name: u32) void {
        const t = c.lookupTexture(name) orelse return;
        if (t.bo) |bo| c.retireBo(bo, t.serial);
        t.* = .{};
        for (&c.texture_units) |*u| if (u.* == name) {
            u.* = 0;
        };
    }

    pub fn bindTexture(c: *Context, target: gl.GLenum, name: u32) void {
        if (target != gl.GL_TEXTURE_2D) return c.setError(gl.GL_INVALID_ENUM);
        if (name != 0 and c.lookupTexture(name) == null) {
            if (name >= max_textures) return c.setError(gl.GL_OUT_OF_MEMORY);
            c.textures[name] = .{ .live = true };
        }
        c.texture_units[c.active_texture] = name;
    }

    fn boundTexture(c: *Context, target: gl.GLenum) ?*Texture {
        if (target != gl.GL_TEXTURE_2D) {
            c.setError(gl.GL_INVALID_ENUM);
            return null;
        }
        return c.lookupTexture(c.texture_units[c.active_texture]) orelse {
            // Texture 0 cannot be changed here.
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        };
    }

    pub fn texParameter(c: *Context, target: gl.GLenum, pname: gl.GLenum, param: gl.GLenum) void {
        const t = c.boundTexture(target) orelse return;
        switch (pname) {
            gl.GL_TEXTURE_MIN_FILTER => switch (param) {
                gl.GL_NEAREST, gl.GL_LINEAR => t.min_filter = param,
                gl.GL_NEAREST_MIPMAP_NEAREST, gl.GL_LINEAR_MIPMAP_NEAREST, gl.GL_NEAREST_MIPMAP_LINEAR, gl.GL_LINEAR_MIPMAP_LINEAR => {
                    c.warnOnce(.mipmaps);
                    t.min_filter = param;
                },
                else => c.setError(gl.GL_INVALID_ENUM),
            },
            gl.GL_TEXTURE_MAG_FILTER => switch (param) {
                gl.GL_NEAREST, gl.GL_LINEAR => t.mag_filter = param,
                else => c.setError(gl.GL_INVALID_ENUM),
            },
            gl.GL_TEXTURE_WRAP_S, gl.GL_TEXTURE_WRAP_T => switch (param) {
                gl.GL_REPEAT, gl.GL_CLAMP_TO_EDGE, gl.GL_MIRRORED_REPEAT => {
                    if (pname == gl.GL_TEXTURE_WRAP_S) t.wrap_s = param else t.wrap_t = param;
                },
                else => c.setError(gl.GL_INVALID_ENUM),
            },
            else => c.setError(gl.GL_INVALID_ENUM),
        }
    }

    fn bytesPerPixel(c: *Context, format: gl.GLenum, ty: gl.GLenum) ?u32 {
        const bpp: u32 = switch (format) {
            gl.GL_RGBA => 4,
            gl.GL_RGB => 3,
            gl.GL_LUMINANCE_ALPHA => 2,
            gl.GL_LUMINANCE, gl.GL_ALPHA => 1,
            else => {
                c.setError(gl.GL_INVALID_ENUM);
                return null;
            },
        };
        if (ty != gl.GL_UNSIGNED_BYTE) {
            c.warnOnce(.texture_format);
            c.setError(gl.GL_INVALID_ENUM);
            return null;
        }
        return bpp;
    }

    pub fn texImage2D(c: *Context, target: gl.GLenum, level: u32, width: u32, height: u32, format: gl.GLenum, ty: gl.GLenum, pixels: ?[*]const u8) void {
        const t = c.boundTexture(target) orelse return;
        const bpp = c.bytesPerPixel(format, ty) orelse return;
        if (width > max_texture_size or height > max_texture_size) return c.setError(gl.GL_INVALID_VALUE);
        if (level > 0) return c.warnOnce(.mipmaps);
        if (t.bo) |bo| {
            c.retireBo(bo, t.serial);
            t.bo = null;
        }
        t.width = width;
        t.height = height;
        if (width == 0 or height == 0) return;
        const bo = c.backend.createBo(texture.imageSize(width, height)) catch return c.setError(gl.GL_OUT_OF_MEMORY);
        t.bo = bo;
        const tmp = c.gpa.alloc(u32, width * height) catch return c.setError(gl.GL_OUT_OF_MEMORY);
        defer c.gpa.free(tmp);
        if (pixels) |p| {
            convertPixels(tmp, p, width, height, format, bpp, c.unpack_alignment);
        } else {
            @memset(tmp, 0);
        }
        texture.upload(bo.map, tmp, width, height);
    }

    pub fn texSubImage2D(c: *Context, target: gl.GLenum, level: u32, x: u32, y: u32, width: u32, height: u32, format: gl.GLenum, ty: gl.GLenum, pixels: [*]const u8) void {
        const t = c.boundTexture(target) orelse return;
        const bpp = c.bytesPerPixel(format, ty) orelse return;
        if (level > 0) return c.warnOnce(.mipmaps);
        if (x + width > t.width or y + height > t.height) return c.setError(gl.GL_INVALID_VALUE);
        if (width == 0 or height == 0) return;
        if (c.frame_open and t.serial == c.serial) {
            const old = t.bo.?;
            const bo = c.backend.createBo(@intCast(old.map.len)) catch return c.setError(gl.GL_OUT_OF_MEMORY);
            @memcpy(bo.map, old.map);
            c.retireBo(old, t.serial);
            t.bo = bo;
        }
        const row_stride = std.mem.alignForward(u32, width * bpp, c.unpack_alignment);
        const map = t.bo.?.map;
        for (0..height) |row| for (0..width) |col| {
            const px = pixel(pixels + row * row_stride + col * bpp, format);
            const off = texture.texelOffset(t.width, t.height, x + @as(u32, @intCast(col)), y + @as(u32, @intCast(row)));
            std.mem.writeInt(u32, map[off..][0..4], px, .little);
        };
    }

    // --- Shaders and programs ------------------------------------------------

    fn newGlslObject(c: *Context, obj: GlslObject) u32 {
        for (&c.glsl_objects, 1..) |*o, name| if (o.* == .free) {
            o.* = obj;
            return @intCast(name);
        };
        return 0;
    }

    pub fn lookupShader(c: *Context, name: u32) ?*ShaderObject {
        if (name == 0 or name > max_glsl_objects) return null;
        return switch (c.glsl_objects[name - 1]) {
            .shader => |s| s,
            else => null,
        };
    }

    pub fn lookupProgram(c: *Context, name: u32) ?*ProgramObject {
        if (name == 0 or name > max_glsl_objects) return null;
        return switch (c.glsl_objects[name - 1]) {
            .program => |p| p,
            else => null,
        };
    }

    /// Like lookupShader, but records the error GL requires for a bad name.
    fn shaderArg(c: *Context, name: u32) ?*ShaderObject {
        if (c.lookupShader(name)) |s| return s;
        c.setError(if (c.lookupProgram(name) != null) gl.GL_INVALID_OPERATION else gl.GL_INVALID_VALUE);
        return null;
    }

    fn programArg(c: *Context, name: u32) ?*ProgramObject {
        if (c.lookupProgram(name)) |p| return p;
        c.setError(if (c.lookupShader(name) != null) gl.GL_INVALID_OPERATION else gl.GL_INVALID_VALUE);
        return null;
    }

    pub fn createShader(c: *Context, ty: gl.GLenum) u32 {
        const stage: glsl.Stage = switch (ty) {
            gl.GL_VERTEX_SHADER => .vertex,
            gl.GL_FRAGMENT_SHADER => .fragment,
            else => {
                c.setError(gl.GL_INVALID_ENUM);
                return 0;
            },
        };
        const s = c.gpa.create(ShaderObject) catch {
            c.setError(gl.GL_OUT_OF_MEMORY);
            return 0;
        };
        s.* = .{ .stage = stage };
        const name = c.newGlslObject(.{ .shader = s });
        if (name == 0) {
            c.gpa.destroy(s);
            c.setError(gl.GL_OUT_OF_MEMORY);
        }
        return name;
    }

    fn freeShader(c: *Context, s: *ShaderObject) void {
        if (s.compiled) |*cs| cs.deinit();
        c.gpa.free(s.source);
        c.gpa.destroy(s);
    }

    pub fn deleteShader(c: *Context, name: u32) void {
        if (name == 0) return;
        const s = c.shaderArg(name) orelse return;
        if (s.attached > 0) {
            s.delete_pending = true;
            return;
        }
        c.freeShader(s);
        c.glsl_objects[name - 1] = .free;
    }

    pub fn shaderSource(c: *Context, name: u32, strings: []const [*]const u8, lengths: ?[]const c_int) void {
        const s = c.shaderArg(name) orelse return;
        var total: usize = 0;
        for (strings, 0..) |str, i| total += sourceLength(str, lengths, i);
        const buf = c.gpa.alloc(u8, total) catch return c.setError(gl.GL_OUT_OF_MEMORY);
        var at: usize = 0;
        for (strings, 0..) |str, i| {
            const n = sourceLength(str, lengths, i);
            @memcpy(buf[at..][0..n], str[0..n]);
            at += n;
        }
        c.gpa.free(s.source);
        s.source = buf;
    }

    fn sourceLength(str: [*]const u8, lengths: ?[]const c_int, i: usize) usize {
        if (lengths) |l| if (l[i] >= 0) return @intCast(l[i]);
        return std.mem.len(@as([*:0]const u8, @ptrCast(str)));
    }

    pub fn compileShader(c: *Context, name: u32) void {
        const s = c.shaderArg(name) orelse return;
        if (s.compiled) |*cs| cs.deinit();
        s.compiled = null;
        s.log = .{};
        s.compiled = glsl.compileShader(c.gpa, s.stage, s.source, &s.log) catch |e| {
            if (e == error.OutOfMemory) c.setError(gl.GL_OUT_OF_MEMORY);
            return;
        };
    }

    pub fn getShaderiv(c: *Context, name: u32, pname: gl.GLenum, out: *c_int) void {
        const s = c.shaderArg(name) orelse return;
        out.* = switch (pname) {
            gl.GL_SHADER_TYPE => if (s.stage == .vertex) gl.GL_VERTEX_SHADER else gl.GL_FRAGMENT_SHADER,
            gl.GL_DELETE_STATUS => @intFromBool(s.delete_pending),
            gl.GL_COMPILE_STATUS => @intFromBool(s.compiled != null),
            gl.GL_INFO_LOG_LENGTH => lengthWithNul(s.log.text()),
            gl.GL_SHADER_SOURCE_LENGTH => lengthWithNul(s.source),
            else => return c.setError(gl.GL_INVALID_ENUM),
        };
    }

    pub fn createProgram(c: *Context) u32 {
        const p = c.gpa.create(ProgramObject) catch {
            c.setError(gl.GL_OUT_OF_MEMORY);
            return 0;
        };
        p.* = .{};
        const name = c.newGlslObject(.{ .program = p });
        if (name == 0) {
            c.gpa.destroy(p);
            c.setError(gl.GL_OUT_OF_MEMORY);
        }
        return name;
    }

    /// Frees a program's link results and hardware shaders.
    fn unlink(c: *Context, p: *ProgramObject) void {
        for (&p.variants) |*v| if (v.*) |variant| {
            c.retireShader(variant.fs.handle);
            c.retireShader(variant.vs.handle);
            c.retireShader(variant.cs.handle);
            c.gpa.destroy(variant);
            v.* = null;
        };
        if (p.linked) |l| {
            l.deinit();
            c.gpa.destroy(l);
            p.linked = null;
        }
        c.gpa.free(p.values);
        p.values = &.{};
    }

    fn freeProgram(c: *Context, name: u32) void {
        const p = c.lookupProgram(name).?;
        c.unlink(p);
        for ([_]u32{ p.vs, p.fs }) |s| if (s != 0) c.release(s);
        for (p.bindings.items) |b| c.gpa.free(b.name);
        p.bindings.deinit(c.gpa);
        c.gpa.destroy(p);
        c.glsl_objects[name - 1] = .free;
        if (c.program == name) c.program = 0;
    }

    /// Drops a program's reference to a shader.
    fn release(c: *Context, name: u32) void {
        const s = c.lookupShader(name).?;
        s.attached -= 1;
        if (s.attached == 0 and s.delete_pending) {
            c.freeShader(s);
            c.glsl_objects[name - 1] = .free;
        }
    }

    pub fn deleteProgram(c: *Context, name: u32) void {
        if (name == 0) return;
        const p = c.programArg(name) orelse return;
        if (c.program == name) {
            // The current program lives on until another is used.
            p.delete_pending = true;
            return;
        }
        c.freeProgram(name);
    }

    pub fn attachShader(c: *Context, program: u32, shader: u32) void {
        const p = c.programArg(program) orelse return;
        const s = c.shaderArg(shader) orelse return;
        const slot = if (s.stage == .vertex) &p.vs else &p.fs;
        if (slot.* != 0) return c.setError(gl.GL_INVALID_OPERATION);
        slot.* = shader;
        s.attached += 1;
    }

    pub fn detachShader(c: *Context, program: u32, shader: u32) void {
        const p = c.programArg(program) orelse return;
        _ = c.shaderArg(shader) orelse return;
        if (p.vs == shader) {
            p.vs = 0;
        } else if (p.fs == shader) {
            p.fs = 0;
        } else return c.setError(gl.GL_INVALID_OPERATION);
        c.release(shader);
    }

    pub fn bindAttribLocation(c: *Context, program: u32, index: u32, name: []const u8) void {
        const p = c.programArg(program) orelse return;
        if (index >= max_vertex_attribs) return c.setError(gl.GL_INVALID_VALUE);
        if (std.mem.startsWith(u8, name, "gl_")) return c.setError(gl.GL_INVALID_OPERATION);
        for (p.bindings.items) |*b| if (std.mem.eql(u8, b.name, name)) {
            b.location = index;
            return;
        };
        const owned = c.gpa.dupe(u8, name) catch return c.setError(gl.GL_OUT_OF_MEMORY);
        p.bindings.append(c.gpa, .{ .name = owned, .location = index }) catch {
            c.gpa.free(owned);
            c.setError(gl.GL_OUT_OF_MEMORY);
        };
    }

    pub fn linkProgram(c: *Context, name: u32) void {
        const p = c.programArg(name) orelse return;
        c.unlink(p);
        p.log = .{};
        p.units = @splat(0);
        const vs = if (c.lookupShader(p.vs)) |s| s.compiled else null;
        const fs = if (c.lookupShader(p.fs)) |s| s.compiled else null;
        if (vs == null or fs == null) {
            p.log.add("ERROR: a program needs a compiled vertex and fragment shader", .{});
            return;
        }
        const linked = glsl.link(c.gpa, &vs.?, &fs.?, p.bindings.items, &p.log) catch |e| {
            if (e == error.OutOfMemory) c.setError(gl.GL_OUT_OF_MEMORY);
            return;
        };
        p.values = c.gpa.alloc(u32, linked.uniform_words + 2) catch {
            linked.deinit();
            c.gpa.destroy(linked);
            return c.setError(gl.GL_OUT_OF_MEMORY);
        };
        @memset(p.values, 0);
        p.linked = linked;
    }

    pub fn useProgram(c: *Context, name: u32) void {
        if (name != 0) {
            const p = c.programArg(name) orelse return;
            if (p.linked == null) return c.setError(gl.GL_INVALID_OPERATION);
        }
        const old = c.program;
        c.program = name;
        if (old != 0 and old != name) if (c.lookupProgram(old)) |p| if (p.delete_pending) c.freeProgram(old);
    }

    pub fn getProgramiv(c: *Context, name: u32, pname: gl.GLenum, out: *c_int) void {
        const p = c.programArg(name) orelse return;
        out.* = switch (pname) {
            gl.GL_DELETE_STATUS => @intFromBool(p.delete_pending),
            gl.GL_LINK_STATUS, gl.GL_VALIDATE_STATUS => @intFromBool(p.linked != null),
            gl.GL_INFO_LOG_LENGTH => lengthWithNul(p.log.text()),
            gl.GL_ATTACHED_SHADERS => @as(c_int, @intFromBool(p.vs != 0)) + @intFromBool(p.fs != 0),
            gl.GL_ACTIVE_ATTRIBUTES => if (p.linked) |l| @intCast(l.num_attributes) else 0,
            gl.GL_ACTIVE_UNIFORMS => if (p.linked) |l| @intCast(l.num_uniforms) else 0,
            gl.GL_ACTIVE_ATTRIBUTE_MAX_LENGTH => blk: {
                var n: usize = 0;
                if (p.linked) |l| for (l.attributeList()) |a| {
                    n = @max(n, a.name.len + 1);
                };
                break :blk @intCast(n);
            },
            gl.GL_ACTIVE_UNIFORM_MAX_LENGTH => blk: {
                var n: usize = 0;
                if (p.linked) |l| for (l.uniformList()) |u| {
                    n = @max(n, u.name.len + 1);
                };
                break :blk @intCast(n);
            },
            else => return c.setError(gl.GL_INVALID_ENUM),
        };
    }

    fn linkedArg(c: *Context, name: u32) ?*glsl.Program {
        const p = c.programArg(name) orelse return null;
        return p.linked orelse {
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        };
    }

    pub fn getAttribLocation(c: *Context, program: u32, name: []const u8) c_int {
        const l = c.linkedArg(program) orelse return -1;
        const a = l.findAttribute(name) orelse return -1;
        return @intCast(a.location);
    }

    pub fn getUniformLocation(c: *Context, program: u32, name: []const u8) c_int {
        const l = c.linkedArg(program) orelse return -1;
        // "name[0]" names the first element of an array; there are none
        // yet, but accept the form.
        const base = if (std.mem.endsWith(u8, name, "[0]")) name[0 .. name.len - 3] else name;
        const u = l.findUniform(base) orelse return -1;
        return @intCast(u - &l.uniforms[0]);
    }

    pub fn activeAttrib(c: *Context, program: u32, index: u32) ?*const glsl.Attribute {
        const l = c.linkedArg(program) orelse return null;
        if (index >= l.num_attributes) {
            c.setError(gl.GL_INVALID_VALUE);
            return null;
        }
        return &l.attributes[index];
    }

    pub fn activeUniform(c: *Context, program: u32, index: u32) ?*const glsl.Uniform {
        const l = c.linkedArg(program) orelse return null;
        if (index >= l.num_uniforms) {
            c.setError(gl.GL_INVALID_VALUE);
            return null;
        }
        return &l.uniforms[index];
    }

    // --- Uniforms -------------------------------------------------------------

    /// GLSL arrays are not supported, so every uniform takes a count of 1.
    pub fn uniformCount(c: *Context, count: c_int) bool {
        if (count < 0) {
            c.setError(gl.GL_INVALID_VALUE);
            return false;
        }
        if (count == 0) return false;
        return true;
    }

    pub fn uniformMatrix(c: *Context, count: c_int, transpose: u8) bool {
        if (transpose != 0) {
            c.setError(gl.GL_INVALID_VALUE);
            return false;
        }
        return c.uniformCount(count);
    }

    /// The current program's uniform at `location`, if it takes `n`
    /// components.
    fn uniformTarget(c: *Context, location: c_int, n: u32) ?struct { p: *ProgramObject, u: *const glsl.Uniform, index: usize } {
        if (location == -1) return null;
        const p = c.lookupProgram(c.program) orelse {
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        };
        const l = p.linked orelse {
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        };
        if (location < 0 or location >= l.num_uniforms) {
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        }
        const index: usize = @intCast(location);
        const u = &l.uniforms[index];
        const comps: u32 = if (u.type == .sampler2D) 1 else u.type.components();
        if (comps != n) {
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        }
        return .{ .p = p, .u = u, .index = index };
    }

    pub fn uniformFloats(c: *Context, location: c_int, n: u32, v: []const f32) void {
        const t = c.uniformTarget(location, n) orelse return;
        if (t.u.type == .sampler2D or t.u.type == .int) return c.setError(gl.GL_INVALID_OPERATION);
        for (v[0..n], 0..) |x, i| t.p.values[t.u.base + i] = @bitCast(if (t.u.type == .bool) @as(f32, if (x != 0) 1 else 0) else x);
    }

    pub fn uniformInts(c: *Context, location: c_int, n: u32, v: []const c_int) void {
        const t = c.uniformTarget(location, n) orelse return;
        switch (t.u.type) {
            .sampler2D => {
                if (v[0] < 0 or v[0] >= max_texture_units) return c.setError(gl.GL_INVALID_VALUE);
                t.p.units[t.index] = @intCast(v[0]);
            },
            // Integers and booleans are held as floats in the shaders.
            .int, .bool => for (v[0..n], 0..) |x, i| {
                const f: f32 = if (t.u.type == .bool) @floatFromInt(@intFromBool(x != 0)) else @floatFromInt(x);
                t.p.values[t.u.base + i] = @bitCast(f);
            },
            else => c.setError(gl.GL_INVALID_OPERATION),
        }
    }

    pub fn uniformValue(c: *Context, program: u32, location: c_int) ?[]const u32 {
        const p = c.programArg(program) orelse return null;
        const l = p.linked orelse {
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        };
        if (location < 0 or location >= l.num_uniforms) {
            c.setError(gl.GL_INVALID_OPERATION);
            return null;
        }
        const u = &l.uniforms[@intCast(location)];
        if (u.type == .sampler2D) return null;
        return p.values[u.base..][0..u.type.components()];
    }

    // --- Drawing --------------------------------------------------------------

    /// Copies data into this frame's stream buffer.
    fn streamCopy(c: *Context, data: []const u8) ?struct { handle: u32, offset: u32 } {
        const size: u32 = @intCast(data.len);
        if (c.stream == null or c.stream_used + size > c.stream.?.map.len) {
            if (c.stream) |old| c.retireBo(old, c.serial);
            c.stream = null;
            c.stream_used = 0;
            c.stream = c.backend.createBo(@max(stream_size, std.mem.alignForward(u32, size, 4096))) catch {
                c.setError(gl.GL_OUT_OF_MEMORY);
                return null;
            };
        }
        const offset = c.stream_used;
        @memcpy(c.stream.?.map[offset..][0..size], data);
        c.stream_used = std.mem.alignForward(u32, offset + size, 16);
        return .{ .handle = c.stream.?.handle, .offset = offset };
    }

    fn markUsed(c: *Context, serial: *u32) void {
        serial.* = c.serial;
    }

    fn variantFor(c: *Context, p: *ProgramObject, depth_write: bool, supplied: []const u8) ?*Variant {
        var key: [max_vertex_attribs]u8 = @splat(0);
        @memcpy(key[0..supplied.len], supplied);
        for (p.variants) |v| if (v) |variant| {
            if (variant.depth_write == depth_write and std.mem.eql(u8, &variant.supplied, &key)) return variant;
        };
        const l = p.linked.?;
        const variant = c.gpa.create(Variant) catch {
            c.setError(gl.GL_OUT_OF_MEMORY);
            return null;
        };
        variant.depth_write = depth_write;
        variant.supplied = key;
        const shader = c.gpa.create(compiler.Shader) catch {
            c.gpa.destroy(variant);
            c.setError(gl.GL_OUT_OF_MEMORY);
            return null;
        };
        defer c.gpa.destroy(shader);
        const stages = [_]struct { compiler.Stage, *Stage }{
            .{ .fragment, &variant.fs },
            .{ .vertex, &variant.vs },
            .{ .coordinate, &variant.cs },
        };
        var done: usize = 0;
        for (stages) |s| {
            const ok = blk: {
                l.build(s[0], .{ .depth_write = depth_write, .supplied = supplied }, shader) catch break :blk false;
                s[1].compiled = compiler.compile(shader) catch |e| {
                    sys.print("stardust gl: compiling the {s} shader failed: {s}\n", .{ @tagName(s[0]), @errorName(e) });
                    break :blk false;
                };
                s[1].handle = c.backend.createShader(s[1].compiled.code()) catch |e| {
                    sys.print("stardust gl: the kernel rejected the {s} shader: {s}\n", .{ @tagName(s[0]), @errorName(e) });
                    break :blk false;
                };
                break :blk true;
            };
            if (!ok) {
                for (stages[0..done]) |d| c.backend.destroyShader(d[1].handle);
                c.gpa.destroy(variant);
                c.setError(gl.GL_OUT_OF_MEMORY);
                return null;
            }
            done += 1;
        }
        // Replace the oldest variant when all slots are full.
        const slot = &p.variants[p.next_variant];
        if (slot.*) |old| {
            c.retireShader(old.fs.handle);
            c.retireShader(old.vs.handle);
            c.retireShader(old.cs.handle);
            c.gpa.destroy(old);
        }
        slot.* = variant;
        p.next_variant = (p.next_variant + 1) % max_variants;
        return variant;
    }

    fn blackTexture(c: *Context) ?render.Texture {
        if (c.black == null) {
            const bo = c.backend.createBo(texture.imageSize(1, 1)) catch {
                c.setError(gl.GL_OUT_OF_MEMORY);
                return null;
            };
            texture.upload(bo.map, &.{0xff000000}, 1, 1);
            c.black = bo;
        }
        return .{ .handle = c.black.?.handle, .config = .{ .width = 1, .height = 1 } };
    }

    /// The texture the program's sampler reads.
    fn drawTexture(c: *Context, p: *ProgramObject) ?render.Texture {
        const l = p.linked.?;
        var unit: ?u8 = null;
        for (l.uniformList(), 0..) |u, i| if (u.type == .sampler2D) {
            if (unit != null and unit.? != p.units[i]) c.warnOnce(.multiple_samplers);
            if (unit == null) unit = p.units[i];
        };
        if (unit) |un| if (c.lookupTexture(c.texture_units[un])) |t| if (t.bo) |bo| {
            c.markUsed(&t.serial);
            return .{ .handle = bo.handle, .config = t.config() };
        };
        return c.blackTexture();
    }

    fn primitive(mode: gl.GLenum) ?cl.PrimitiveMode {
        return switch (mode) {
            gl.GL_LINES => .lines,
            gl.GL_LINE_LOOP => .line_loop,
            gl.GL_LINE_STRIP => .line_strip,
            gl.GL_TRIANGLES => .triangles,
            gl.GL_TRIANGLE_STRIP => .triangle_strip,
            gl.GL_TRIANGLE_FAN => .triangle_fan,
            else => null,
        };
    }

    fn compareFunc(func: gl.GLenum) cl.CompareFunc {
        return @enumFromInt(func - gl.GL_NEVER);
    }

    /// A GL rectangle (y = 0 at the bottom) in target coordinates.
    fn targetRect(c: *const Context, r: [4]c_int) render.Viewport {
        return .{
            .x = r[0],
            .y = @as(i32, c.target.?.height) - (r[1] + r[3]),
            .width = @intCast(r[2]),
            .height = @intCast(r[3]),
        };
    }

    pub fn draw(c: *Context, mode: gl.GLenum, first: u32, count: u32, elements: ?Elements) void {
        if (mode == gl.GL_POINTS) {
            c.warnOnce(.points);
            return;
        }
        const prim = primitive(mode) orelse return c.setError(gl.GL_INVALID_ENUM);
        const p = c.lookupProgram(c.program) orelse return;
        const l = p.linked orelse return c.setError(gl.GL_INVALID_OPERATION);
        if (c.target == null or count == 0) return;
        if (c.viewport[2] == 0 or c.viewport[3] == 0) return;

        // Make sure the whole draw fits in the frame before copying data
        // into the stream buffer, which resets when a frame is submitted.
        if (c.frame_open) {
            var words: usize = 0;
            if (p.variants[0]) |v| words = v.fs.compiled.uniform_len + v.vs.compiled.uniform_len + v.cs.compiled.uniform_len + 2;
            if (!c.frame.hasRoom(@max(words, 2 * p.values.len + 64))) c.splitFrame();
        }

        var max_index: u32 = first + count - 1;
        var indices: ?render.Indices = null;
        if (elements) |e| {
            const index_size: u32 = switch (e.type) {
                gl.GL_UNSIGNED_BYTE => 1,
                gl.GL_UNSIGNED_SHORT => 2,
                else => return c.setError(gl.GL_INVALID_ENUM),
            };
            const bytes = count * index_size;
            var handle: u32 = undefined;
            var offset: u32 = undefined;
            var data: []const u8 = undefined;
            if (c.lookupBuffer(c.element_array_buffer)) |b| {
                if (e.pointer + bytes > b.size or e.pointer % index_size != 0) return c.setError(gl.GL_INVALID_OPERATION);
                c.markUsed(&b.serial);
                handle = b.bo.?.handle;
                offset = @intCast(e.pointer);
                data = b.bo.?.map[offset..][0..bytes];
            } else {
                if (e.pointer == 0) return c.setError(gl.GL_INVALID_OPERATION);
                data = @as([*]const u8, @ptrFromInt(e.pointer))[0..bytes];
                const s = c.streamCopy(data) orelse return;
                handle = s.handle;
                offset = s.offset;
            }
            max_index = 0;
            if (index_size == 1) {
                for (data) |i| max_index = @max(max_index, i);
            } else {
                for (0..count) |i| max_index = @max(max_index, std.mem.readInt(u16, data[i * 2 ..][0..2], .little));
            }
            indices = .{ .handle = handle, .offset = offset, .max_index = max_index, .type = if (index_size == 1) .u8 else .u16 };
        }

        // Vertex attributes, in the program's VPM order.
        var attrs: [max_vertex_attribs]render.Attribute = undefined;
        var supplied: [max_vertex_attribs]u8 = undefined;
        var vs_size: u8 = 0;
        var cs_size: u8 = 0;
        var cs_mask: u8 = 0;
        const list = l.attributeList();
        for (list, 0..) |a, i| {
            const va = &c.attribs[a.location];
            const declared = a.type.components();
            var comps: u8 = declared;
            var handle: u32 = undefined;
            var offset: u32 = undefined;
            var stride: u32 = 0;
            if (va.enabled) {
                // Fetch only what the shader reads; it fills in the rest.
                comps = @min(@as(u8, @intCast(va.size)), declared);
                stride = if (va.stride != 0) va.stride else @as(u32, @intCast(va.size)) * 4;
                if (stride > 255) return c.setError(gl.GL_INVALID_VALUE);
                const span = stride * max_index + comps * 4;
                if (c.lookupBuffer(va.buffer)) |b| {
                    if (va.offset + span > b.size) return c.setError(gl.GL_INVALID_OPERATION);
                    c.markUsed(&b.serial);
                    handle = b.bo.?.handle;
                    offset = @intCast(va.offset);
                } else {
                    if (va.offset == 0) return c.setError(gl.GL_INVALID_OPERATION);
                    const s = c.streamCopy(@as([*]const u8, @ptrFromInt(va.offset))[0..span]) orelse return;
                    handle = s.handle;
                    offset = s.offset;
                }
            } else {
                const s = c.streamCopy(std.mem.sliceAsBytes(va.current[0..declared])) orelse return;
                handle = s.handle;
                offset = s.offset;
            }
            supplied[i] = comps;
            attrs[i] = .{
                .handle = handle,
                .offset = offset,
                .size = comps * 4,
                .stride = @intCast(stride),
                .vs_vpm_offset = vs_size,
                .cs_vpm_offset = if (a.in_coordinate_shader) cs_size else 0,
            };
            vs_size += comps * 4;
            if (a.in_coordinate_shader) {
                cs_mask |= @as(u8, 1) << @intCast(i);
                cs_size += comps * 4;
            }
        }

        const variant = c.variantFor(p, c.depth_test, supplied[0..list.len]) orelse return;
        const tex: ?render.Texture = if (variant.fs.compiled.num_texture_samples > 0) (c.drawTexture(p) orelse return) else null;

        const viewport = c.targetRect(c.viewport);
        const scale = viewport.scaleBits();
        const vp = l.viewportUniform();
        p.values[vp] = scale[0];
        p.values[vp + 1] = scale[1];

        const cull_front = c.cull_face and c.cull_mode != gl.GL_BACK;
        const cull_back = c.cull_face and c.cull_mode != gl.GL_FRONT;
        const frame = c.openFrame();
        frame.draw(.{
            .fs = variant.fs.binding(p.values),
            .vs = variant.vs.binding(p.values),
            .cs = variant.cs.binding(p.values),
            .fs_num_varyings = l.varyingComponents(),
            .attributes = attrs[0..list.len],
            .vs_attribute_mask = @intCast((@as(u16, 1) << @intCast(list.len)) - 1),
            .vs_attributes_size = vs_size,
            .cs_attribute_mask = cs_mask,
            .cs_attributes_size = cs_size,
            .primitive = prim,
            .count = count,
            .first = first,
            .indices = indices,
            .config = .{
                .enable_forward_facing = !cull_front,
                .enable_reverse_facing = !cull_back,
                // The hardware takes the winding of front faces on screen,
                // where y points down: counter-clockwise in GL is
                // clockwise there (Mesa's vc4 driver does the same for
                // window surfaces).
                .clockwise_primitives = c.front_face == gl.GL_CCW,
                .depth_func = if (c.depth_test) compareFunc(c.depth_func) else .always,
                .z_updates = c.depth_test and c.depth_mask,
            },
            .viewport = viewport,
            .scissor = if (c.scissor_test) c.targetRect(c.scissor) else null,
            .texture = tex,
        }) catch {
            c.setError(gl.GL_OUT_OF_MEMORY);
        };
    }
};

fn lengthWithNul(s: []const u8) c_int {
    return if (s.len == 0) 0 else @intCast(s.len + 1);
}

/// GL clear colour to the 0xAARRGGBB the hardware takes.
pub fn packColor(rgba: [4]f32) u32 {
    var out: u32 = 0;
    for ([_]u5{ 16, 8, 0, 24 }, rgba) |shift, v| {
        const byte: u32 = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        out |= byte << shift;
    }
    return out;
}

/// One GL pixel as the 0xAARRGGBB word the texture unit reads.
fn pixel(p: [*]const u8, format: gl.GLenum) u32 {
    const rgba: [4]u8 = switch (format) {
        gl.GL_RGBA => .{ p[0], p[1], p[2], p[3] },
        gl.GL_RGB => .{ p[0], p[1], p[2], 255 },
        gl.GL_LUMINANCE_ALPHA => .{ p[0], p[0], p[0], p[1] },
        gl.GL_LUMINANCE => .{ p[0], p[0], p[0], 255 },
        gl.GL_ALPHA => .{ 0, 0, 0, p[0] },
        else => unreachable,
    };
    return @as(u32, rgba[3]) << 24 | @as(u32, rgba[0]) << 16 | @as(u32, rgba[1]) << 8 | rgba[2];
}

fn convertPixels(dst: []u32, src: [*]const u8, width: u32, height: u32, format: gl.GLenum, bpp: u32, alignment: u32) void {
    const row_stride = std.mem.alignForward(u32, width * bpp, alignment);
    for (0..height) |y| for (0..width) |x| {
        dst[y * width + x] = pixel(src + y * row_stride + x * bpp, format);
    };
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

/// A GPU stand-in: buffers in host memory, shaders checked by the QPU
/// validator, frames recorded.
pub const FakeGpu = struct {
    gpa: Allocator,
    next_handle: u32 = 1,
    live_bos: u32 = 0,
    live_shaders: u32 = 0,
    frames: u32 = 0,
    draws: u32 = 0,
    last_clear: ?u32 = null,
    last_bcl_len: usize = 0,
    last_uniforms: [256]u32 = undefined,
    last_uniforms_len: usize = 0,
    last_submit: vc4.SubmitCl = .{},

    pub fn backend(g: *FakeGpu) Backend {
        return .{ .ptr = g, .vtable = &.{
            .createBo = createBo,
            .destroyBo = destroyBo,
            .createShader = createShader,
            .destroyShader = destroyShader,
            .run = run,
        } };
    }

    fn createBo(ptr: *anyopaque, size: u32) anyerror!vc4.Bo {
        const g: *FakeGpu = @ptrCast(@alignCast(ptr));
        const mem = try g.gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), std.mem.alignForward(u32, size, 4096));
        @memset(mem, 0);
        g.next_handle += 1;
        g.live_bos += 1;
        return .{ .handle = g.next_handle, .map = mem };
    }

    fn destroyBo(ptr: *anyopaque, bo: vc4.Bo) void {
        const g: *FakeGpu = @ptrCast(@alignCast(ptr));
        g.gpa.free(bo.map);
        g.live_bos -= 1;
    }

    fn createShader(ptr: *anyopaque, code: []const vc4.qpu.Inst) anyerror!u32 {
        const g: *FakeGpu = @ptrCast(@alignCast(ptr));
        g.next_handle += 1;
        g.live_shaders += 1;
        _ = code;
        return g.next_handle;
    }

    fn destroyShader(ptr: *anyopaque, handle: u32) void {
        const g: *FakeGpu = @ptrCast(@alignCast(ptr));
        _ = handle;
        g.live_shaders -= 1;
    }

    fn run(ptr: *anyopaque, frame: *render.Frame) anyerror!void {
        const g: *FakeGpu = @ptrCast(@alignCast(ptr));
        g.frames += 1;
        g.draws += frame.draws;
        g.last_clear = switch (frame.load) {
            .clear => |col| col,
            .keep => null,
        };
        g.last_bcl_len = frame.submit.bin_cl_size;
        const u = frame.uniformWords();
        g.last_uniforms_len = @min(u.len, g.last_uniforms.len);
        @memcpy(g.last_uniforms[0..g.last_uniforms_len], u[0..g.last_uniforms_len]);
        g.last_submit = frame.submit;
    }
};

const TestContext = struct {
    gpu: *FakeGpu,
    c: *Context,

    fn init() !TestContext {
        const gpu = try testing.allocator.create(FakeGpu);
        gpu.* = .{ .gpa = testing.allocator };
        const c = try Context.create(testing.allocator, gpu.backend());
        c.setTarget(.{ .handle = 1, .width = 320, .height = 240 });
        c.viewport = .{ 0, 0, 320, 240 };
        c.scissor = c.viewport;
        current = c;
        return .{ .gpu = gpu, .c = c };
    }

    fn deinit(t: TestContext) void {
        t.c.destroy();
        // Everything the context created has been freed.
        testing.expectEqual(@as(u32, 0), t.gpu.live_bos) catch @panic("leaked buffer objects");
        testing.expectEqual(@as(u32, 0), t.gpu.live_shaders) catch @panic("leaked shaders");
        testing.allocator.destroy(t.gpu);
    }
};

fn testProgram(vs_src: [*:0]const u8, fs_src: [*:0]const u8) !u32 {
    const vs = gl.glCreateShader(gl.GL_VERTEX_SHADER);
    gl.glShaderSource(vs, 1, &[_][*]const u8{vs_src}, null);
    gl.glCompileShader(vs);
    const fs = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
    gl.glShaderSource(fs, 1, &[_][*]const u8{fs_src}, null);
    gl.glCompileShader(fs);
    const prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glBindAttribLocation(prog, 0, "pos");
    gl.glLinkProgram(prog);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);
    var status: c_int = 0;
    gl.glGetProgramiv(prog, gl.GL_LINK_STATUS, @ptrCast(&status));
    if (status == 0) {
        std.debug.print("{s}\n", .{current.?.lookupProgram(prog).?.log.text()});
        return error.LinkFailed;
    }
    return prog;
}

const tri_vs =
    \\attribute vec2 pos;
    \\attribute vec3 color;
    \\uniform float scale;
    \\varying vec3 v_color;
    \\void main() {
    \\    gl_Position = vec4(pos * scale, 0.0, 1.0);
    \\    v_color = color;
    \\}
;
const tri_fs =
    \\precision mediump float;
    \\varying vec3 v_color;
    \\void main() { gl_FragColor = vec4(v_color, 1.0); }
;

test "clear only submits a rendering pass" {
    const t = try TestContext.init();
    defer t.deinit();
    gl.glClearColor(1, 0.5, 0, 1);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
    t.c.submit();
    try testing.expectEqual(@as(u32, 1), t.gpu.frames);
    try testing.expectEqual(@as(?u32, 0xffff8000), t.gpu.last_clear);
    try testing.expectEqual(@as(u32, 0), t.gpu.last_submit.bin_cl_size);
    // Nothing to do without a clear or draws.
    t.c.submit();
    try testing.expectEqual(@as(u32, 1), t.gpu.frames);
    try testing.expectEqual(gl.GL_NO_ERROR, gl.glGetError());
}

test "client-side arrays and a disabled attribute" {
    const t = try TestContext.init();
    defer t.deinit();
    const prog = try testProgram(tri_vs, tri_fs);
    gl.glUseProgram(prog);
    try testing.expectEqual(@as(c_int, 0), gl.glGetAttribLocation(prog, "pos"));
    const loc = gl.glGetUniformLocation(prog, "scale");
    try testing.expect(loc >= 0);
    gl.glUniform1f(loc, 0.5);
    const verts = [_]f32{ 0, 1, -1, -1, 1, -1 };
    gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 0, &verts);
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttrib3f(@intCast(gl.glGetAttribLocation(prog, "color")), 1, 0, 0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);
    try testing.expectEqual(gl.GL_NO_ERROR, gl.glGetError());
    t.c.submit();
    try testing.expectEqual(@as(u32, 1), t.gpu.draws);
    // The vertex shader's uniform stream carries the scale and viewport.
    const u = t.gpu.last_uniforms[0..t.gpu.last_uniforms_len];
    try testing.expect(std.mem.indexOfScalar(u32, u, @bitCast(@as(f32, 0.5))) != null);
    try testing.expect(std.mem.indexOfScalar(u32, u, @bitCast(@as(f32, 160 * 16))) != null);
    gl.glDeleteProgram(prog);
}

test "buffers, indices, textures and depth" {
    const t = try TestContext.init();
    defer t.deinit();
    const prog = try testProgram(
        \\attribute vec3 pos;
        \\attribute vec2 uv;
        \\uniform mat4 mvp;
        \\varying vec2 v_uv;
        \\void main() { gl_Position = mvp * vec4(pos, 1.0); v_uv = uv; }
    ,
        \\precision mediump float;
        \\uniform sampler2D tex;
        \\varying vec2 v_uv;
        \\void main() { gl_FragColor = texture2D(tex, v_uv); }
    );
    gl.glUseProgram(prog);
    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    gl.glUniformMatrix4fv(gl.glGetUniformLocation(prog, "mvp"), 1, gl.GL_FALSE, &identity);
    gl.glUniform1i(gl.glGetUniformLocation(prog, "tex"), 0);

    var bufs: [2]u32 = undefined;
    gl.glGenBuffers(2, &bufs);
    const verts = [_]f32{ -1, -1, 0, 0, 0, 1, -1, 0, 1, 0, 1, 1, 0, 1, 1, -1, 1, 0, 0, 1 };
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, bufs[0]);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.GL_STATIC_DRAW);
    const idx = [_]u16{ 0, 1, 2, 0, 2, 3 };
    gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, bufs[1]);
    gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(idx)), &idx, gl.GL_STATIC_DRAW);
    const uv: u32 = @intCast(gl.glGetAttribLocation(prog, "uv"));
    gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, 20, null);
    gl.glVertexAttribPointer(uv, 2, gl.GL_FLOAT, gl.GL_FALSE, 20, @ptrFromInt(12));
    gl.glEnableVertexAttribArray(0);
    gl.glEnableVertexAttribArray(uv);

    var tex: u32 = 0;
    gl.glGenTextures(1, @ptrCast(&tex));
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 255, 255, 255, 255 };
    // Two RGB rows of 2 pixels are 6 bytes, padded to 8 by the default
    // unpack alignment.
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGB, 2, 2, 0, gl.GL_RGB, gl.GL_UNSIGNED_BYTE, &rgb);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    const map = t.c.lookupTexture(tex).?.bo.?.map;
    try testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, map[texture.texelOffset(2, 2, 0, 0)..][0..4], .little));
    try testing.expectEqual(@as(u32, 0xff00ff00), std.mem.readInt(u32, map[texture.texelOffset(2, 2, 1, 0)..][0..4], .little));
    try testing.expectEqual(@as(u32, 0xff0000ff), std.mem.readInt(u32, map[texture.texelOffset(2, 2, 0, 1)..][0..4], .little));
    try testing.expectEqual(@as(u32, 0xffffffff), std.mem.readInt(u32, map[texture.texelOffset(2, 2, 1, 1)..][0..4], .little));

    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glEnable(gl.GL_CULL_FACE);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
    gl.glDrawElements(gl.GL_TRIANGLES, 6, gl.GL_UNSIGNED_SHORT, null);
    try testing.expectEqual(gl.GL_NO_ERROR, gl.glGetError());

    // Changing a buffer the open frame uses replaces it.
    const old_handle = t.c.lookupBuffer(bufs[0]).?.bo.?.handle;
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, bufs[0]);
    gl.glBufferSubData(gl.GL_ARRAY_BUFFER, 0, 4, &verts);
    try testing.expect(t.c.lookupBuffer(bufs[0]).?.bo.?.handle != old_handle);
    gl.glDrawElements(gl.GL_TRIANGLES, 3, gl.GL_UNSIGNED_SHORT, @ptrFromInt(6));
    t.c.submit();
    try testing.expectEqual(@as(u32, 2), t.gpu.draws);
    try testing.expectEqual(gl.GL_NO_ERROR, gl.glGetError());

    // Errors.
    gl.glDrawElements(gl.GL_TRIANGLES, 3, gl.GL_UNSIGNED_INT, null);
    try testing.expectEqual(gl.GL_INVALID_ENUM, gl.glGetError());
    gl.glDrawElements(gl.GL_TRIANGLES, 12, gl.GL_UNSIGNED_SHORT, null);
    try testing.expectEqual(gl.GL_INVALID_OPERATION, gl.glGetError());
    gl.glUniform1f(gl.glGetUniformLocation(prog, "mvp"), 1);
    try testing.expectEqual(gl.GL_INVALID_OPERATION, gl.glGetError());

    gl.glDeleteTextures(1, @ptrCast(&tex));
    gl.glDeleteBuffers(2, &bufs);
    gl.glUseProgram(0);
    gl.glDeleteProgram(prog);
}

test "compile errors are reported in the info log" {
    const t = try TestContext.init();
    defer t.deinit();
    const s = gl.glCreateShader(gl.GL_VERTEX_SHADER);
    gl.glShaderSource(s, 1, &[_][*]const u8{"void main() { gl_Position = 1; }"}, null);
    gl.glCompileShader(s);
    var status: c_int = 1;
    gl.glGetShaderiv(s, gl.GL_COMPILE_STATUS, @ptrCast(&status));
    try testing.expectEqual(@as(c_int, 0), status);
    var log: [256]u8 = undefined;
    var len: c_int = 0;
    gl.glGetShaderInfoLog(s, log.len, &len, &log);
    try testing.expect(std.mem.startsWith(u8, log[0..@intCast(len)], "ERROR: 0:1:"));
    gl.glDeleteShader(s);
    try testing.expectEqual(gl.GL_FALSE, gl.glIsShader(s));
}

test "packColor" {
    try testing.expectEqual(@as(u32, 0xff336699), packColor(.{ 0.2, 0.4, 0.6, 1 }));
}
