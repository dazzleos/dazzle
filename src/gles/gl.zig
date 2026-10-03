//! The OpenGL ES 2.0 API: types, constants and the C ABI entry points.
//!
//! Every entry point is exported with the C calling convention under its
//! standard name, so C programs can link against them, and Zig programs can
//! call them directly with the same names (`gl.glClear(gl.GL_COLOR_BUFFER_BIT)`).
//! Calls apply to the context made current with `eglMakeCurrent` and are
//! ignored when there is none.
//!
//! Supported: shaders and programs (GLSL ES 1.00, see glsl/), buffers,
//! float vertex attributes (from buffers or client memory), 2D textures
//! (8-bit RGBA, RGB, luminance and alpha formats; base level only), depth
//! testing, face culling, viewport, scissor, clear, `glDrawArrays` and
//! `glDrawElements` with 8- and 16-bit indices. Only the window surface can
//! be rendered to. Blending, stencil, framebuffer objects, mipmaps, point
//! sprites and `glReadPixels` are not implemented yet; using them records an
//! error or prints a warning once.

const std = @import("std");
const context = @import("context.zig");

pub const GLenum = c_uint;
pub const GLuint = c_uint;
pub const GLint = c_int;
pub const GLsizei = c_int;
pub const GLboolean = u8;
pub const GLbitfield = c_uint;
pub const GLfloat = f32;
pub const GLclampf = f32;
pub const GLbyte = i8;
pub const GLubyte = u8;
pub const GLshort = c_short;
pub const GLushort = c_ushort;
pub const GLchar = u8;
pub const GLintptr = isize;
pub const GLsizeiptr = isize;
pub const GLvoid = anyopaque;

pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;

// Errors.
pub const GL_NO_ERROR: GLenum = 0;
pub const GL_INVALID_ENUM: GLenum = 0x0500;
pub const GL_INVALID_VALUE: GLenum = 0x0501;
pub const GL_INVALID_OPERATION: GLenum = 0x0502;
pub const GL_OUT_OF_MEMORY: GLenum = 0x0505;
pub const GL_INVALID_FRAMEBUFFER_OPERATION: GLenum = 0x0506;

// Clear bits.
pub const GL_DEPTH_BUFFER_BIT: GLbitfield = 0x00000100;
pub const GL_STENCIL_BUFFER_BIT: GLbitfield = 0x00000400;
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;

// Primitives.
pub const GL_POINTS: GLenum = 0x0000;
pub const GL_LINES: GLenum = 0x0001;
pub const GL_LINE_LOOP: GLenum = 0x0002;
pub const GL_LINE_STRIP: GLenum = 0x0003;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_TRIANGLE_STRIP: GLenum = 0x0005;
pub const GL_TRIANGLE_FAN: GLenum = 0x0006;

// Comparison functions.
pub const GL_NEVER: GLenum = 0x0200;
pub const GL_LESS: GLenum = 0x0201;
pub const GL_EQUAL: GLenum = 0x0202;
pub const GL_LEQUAL: GLenum = 0x0203;
pub const GL_GREATER: GLenum = 0x0204;
pub const GL_NOTEQUAL: GLenum = 0x0205;
pub const GL_GEQUAL: GLenum = 0x0206;
pub const GL_ALWAYS: GLenum = 0x0207;

// Faces.
pub const GL_FRONT: GLenum = 0x0404;
pub const GL_BACK: GLenum = 0x0405;
pub const GL_FRONT_AND_BACK: GLenum = 0x0408;
pub const GL_CW: GLenum = 0x0900;
pub const GL_CCW: GLenum = 0x0901;

// Capabilities.
pub const GL_CULL_FACE: GLenum = 0x0B44;
pub const GL_DEPTH_TEST: GLenum = 0x0B71;
pub const GL_STENCIL_TEST: GLenum = 0x0B90;
pub const GL_DITHER: GLenum = 0x0BD0;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SCISSOR_TEST: GLenum = 0x0C11;
pub const GL_POLYGON_OFFSET_FILL: GLenum = 0x8037;
pub const GL_SAMPLE_ALPHA_TO_COVERAGE: GLenum = 0x809E;
pub const GL_SAMPLE_COVERAGE: GLenum = 0x80A0;

// Queries.
pub const GL_CULL_FACE_MODE: GLenum = 0x0B45;
pub const GL_FRONT_FACE: GLenum = 0x0B46;
pub const GL_DEPTH_RANGE: GLenum = 0x0B70;
pub const GL_DEPTH_WRITEMASK: GLenum = 0x0B72;
pub const GL_DEPTH_CLEAR_VALUE: GLenum = 0x0B73;
pub const GL_DEPTH_FUNC: GLenum = 0x0B74;
pub const GL_VIEWPORT: GLenum = 0x0BA2;
pub const GL_SCISSOR_BOX: GLenum = 0x0C10;
pub const GL_COLOR_CLEAR_VALUE: GLenum = 0x0C22;
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
pub const GL_PACK_ALIGNMENT: GLenum = 0x0D05;
pub const GL_MAX_TEXTURE_SIZE: GLenum = 0x0D33;
pub const GL_MAX_VIEWPORT_DIMS: GLenum = 0x0D3A;
pub const GL_SUBPIXEL_BITS: GLenum = 0x0D50;
pub const GL_RED_BITS: GLenum = 0x0D52;
pub const GL_GREEN_BITS: GLenum = 0x0D53;
pub const GL_BLUE_BITS: GLenum = 0x0D54;
pub const GL_ALPHA_BITS: GLenum = 0x0D55;
pub const GL_DEPTH_BITS: GLenum = 0x0D56;
pub const GL_STENCIL_BITS: GLenum = 0x0D57;
pub const GL_ARRAY_BUFFER_BINDING: GLenum = 0x8894;
pub const GL_ELEMENT_ARRAY_BUFFER_BINDING: GLenum = 0x8895;
pub const GL_CURRENT_PROGRAM: GLenum = 0x8B8D;
pub const GL_TEXTURE_BINDING_2D: GLenum = 0x8069;
pub const GL_ACTIVE_TEXTURE: GLenum = 0x84E0;
pub const GL_MAX_VERTEX_ATTRIBS: GLenum = 0x8869;
pub const GL_MAX_VERTEX_UNIFORM_VECTORS: GLenum = 0x8DFB;
pub const GL_MAX_VARYING_VECTORS: GLenum = 0x8DFC;
pub const GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS: GLenum = 0x8B4D;
pub const GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: GLenum = 0x8B4C;
pub const GL_MAX_TEXTURE_IMAGE_UNITS: GLenum = 0x8872;
pub const GL_MAX_FRAGMENT_UNIFORM_VECTORS: GLenum = 0x8DFD;
pub const GL_MAX_RENDERBUFFER_SIZE: GLenum = 0x84E8;
pub const GL_MAX_CUBE_MAP_TEXTURE_SIZE: GLenum = 0x851C;
pub const GL_NUM_COMPRESSED_TEXTURE_FORMATS: GLenum = 0x86A2;
pub const GL_NUM_SHADER_BINARY_FORMATS: GLenum = 0x8DF9;
pub const GL_IMPLEMENTATION_COLOR_READ_TYPE: GLenum = 0x8B9A;
pub const GL_IMPLEMENTATION_COLOR_READ_FORMAT: GLenum = 0x8B9B;

// Strings.
pub const GL_VENDOR: GLenum = 0x1F00;
pub const GL_RENDERER: GLenum = 0x1F01;
pub const GL_VERSION: GLenum = 0x1F02;
pub const GL_EXTENSIONS: GLenum = 0x1F03;
pub const GL_SHADING_LANGUAGE_VERSION: GLenum = 0x8B8C;

// Data types.
pub const GL_BYTE: GLenum = 0x1400;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_SHORT: GLenum = 0x1402;
pub const GL_UNSIGNED_SHORT: GLenum = 0x1403;
pub const GL_INT: GLenum = 0x1404;
pub const GL_UNSIGNED_INT: GLenum = 0x1405;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_FIXED: GLenum = 0x140C;
pub const GL_UNSIGNED_SHORT_4_4_4_4: GLenum = 0x8033;
pub const GL_UNSIGNED_SHORT_5_5_5_1: GLenum = 0x8034;
pub const GL_UNSIGNED_SHORT_5_6_5: GLenum = 0x8363;

// Pixel formats.
pub const GL_DEPTH_COMPONENT: GLenum = 0x1902;
pub const GL_ALPHA: GLenum = 0x1906;
pub const GL_RGB: GLenum = 0x1907;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_LUMINANCE: GLenum = 0x1909;
pub const GL_LUMINANCE_ALPHA: GLenum = 0x190A;

// Buffers.
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_ELEMENT_ARRAY_BUFFER: GLenum = 0x8893;
pub const GL_STREAM_DRAW: GLenum = 0x88E0;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
pub const GL_BUFFER_SIZE: GLenum = 0x8764;
pub const GL_BUFFER_USAGE: GLenum = 0x8765;

// Textures.
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE_CUBE_MAP: GLenum = 0x8513;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_NEAREST: GLenum = 0x2600;
pub const GL_LINEAR: GLenum = 0x2601;
pub const GL_NEAREST_MIPMAP_NEAREST: GLenum = 0x2700;
pub const GL_LINEAR_MIPMAP_NEAREST: GLenum = 0x2701;
pub const GL_NEAREST_MIPMAP_LINEAR: GLenum = 0x2702;
pub const GL_LINEAR_MIPMAP_LINEAR: GLenum = 0x2703;
pub const GL_REPEAT: GLenum = 0x2901;
pub const GL_CLAMP_TO_EDGE: GLenum = 0x812F;
pub const GL_MIRRORED_REPEAT: GLenum = 0x8370;
pub const GL_TEXTURE0: GLenum = 0x84C0;

// Shaders and programs.
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_SHADER_TYPE: GLenum = 0x8B4F;
pub const GL_DELETE_STATUS: GLenum = 0x8B80;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_VALIDATE_STATUS: GLenum = 0x8B83;
pub const GL_INFO_LOG_LENGTH: GLenum = 0x8B84;
pub const GL_ATTACHED_SHADERS: GLenum = 0x8B85;
pub const GL_ACTIVE_UNIFORMS: GLenum = 0x8B86;
pub const GL_ACTIVE_UNIFORM_MAX_LENGTH: GLenum = 0x8B87;
pub const GL_SHADER_SOURCE_LENGTH: GLenum = 0x8B88;
pub const GL_ACTIVE_ATTRIBUTES: GLenum = 0x8B89;
pub const GL_ACTIVE_ATTRIBUTE_MAX_LENGTH: GLenum = 0x8B8A;
pub const GL_SHADER_COMPILER: GLenum = 0x8DFA;

// Uniform and attribute types.
pub const GL_FLOAT_VEC2: GLenum = 0x8B50;
pub const GL_FLOAT_VEC3: GLenum = 0x8B51;
pub const GL_FLOAT_VEC4: GLenum = 0x8B52;
pub const GL_INT_VEC2: GLenum = 0x8B53;
pub const GL_INT_VEC3: GLenum = 0x8B54;
pub const GL_INT_VEC4: GLenum = 0x8B55;
pub const GL_BOOL: GLenum = 0x8B56;
pub const GL_BOOL_VEC2: GLenum = 0x8B57;
pub const GL_BOOL_VEC3: GLenum = 0x8B58;
pub const GL_BOOL_VEC4: GLenum = 0x8B59;
pub const GL_FLOAT_MAT2: GLenum = 0x8B5A;
pub const GL_FLOAT_MAT3: GLenum = 0x8B5B;
pub const GL_FLOAT_MAT4: GLenum = 0x8B5C;
pub const GL_SAMPLER_2D: GLenum = 0x8B5E;
pub const GL_SAMPLER_CUBE: GLenum = 0x8B60;

// Vertex attribute queries.
pub const GL_VERTEX_ATTRIB_ARRAY_ENABLED: GLenum = 0x8622;
pub const GL_VERTEX_ATTRIB_ARRAY_SIZE: GLenum = 0x8623;
pub const GL_VERTEX_ATTRIB_ARRAY_STRIDE: GLenum = 0x8624;
pub const GL_VERTEX_ATTRIB_ARRAY_TYPE: GLenum = 0x8625;
pub const GL_CURRENT_VERTEX_ATTRIB: GLenum = 0x8626;
pub const GL_VERTEX_ATTRIB_ARRAY_NORMALIZED: GLenum = 0x886A;
pub const GL_VERTEX_ATTRIB_ARRAY_POINTER: GLenum = 0x8645;
pub const GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING: GLenum = 0x889F;

// Framebuffers (only the default one exists).
pub const GL_FRAMEBUFFER: GLenum = 0x8D40;
pub const GL_RENDERBUFFER: GLenum = 0x8D41;
pub const GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5;
pub const GL_FRAMEBUFFER_UNSUPPORTED: GLenum = 0x8CDD;

// Hints.
pub const GL_DONT_CARE: GLenum = 0x1100;
pub const GL_FASTEST: GLenum = 0x1101;
pub const GL_NICEST: GLenum = 0x1102;
pub const GL_GENERATE_MIPMAP_HINT: GLenum = 0x8192;

fn ctx() ?*context.Context {
    return context.current;
}

fn cstr(s: [*:0]const GLchar) []const u8 {
    return std.mem.span(s);
}

// --- State ------------------------------------------------------------------

pub export fn glGetError() callconv(.c) GLenum {
    const c = ctx() orelse return GL_NO_ERROR;
    const e = c.err;
    c.err = GL_NO_ERROR;
    return e;
}

pub export fn glEnable(cap: GLenum) callconv(.c) void {
    if (ctx()) |c| c.setCapability(cap, true);
}

pub export fn glDisable(cap: GLenum) callconv(.c) void {
    if (ctx()) |c| c.setCapability(cap, false);
}

pub export fn glIsEnabled(cap: GLenum) callconv(.c) GLboolean {
    const c = ctx() orelse return GL_FALSE;
    return @intFromBool(c.isEnabled(cap));
}

pub export fn glViewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei) callconv(.c) void {
    const c = ctx() orelse return;
    if (width < 0 or height < 0) return c.setError(GL_INVALID_VALUE);
    c.viewport = .{ x, y, width, height };
}

pub export fn glScissor(x: GLint, y: GLint, width: GLsizei, height: GLsizei) callconv(.c) void {
    const c = ctx() orelse return;
    if (width < 0 or height < 0) return c.setError(GL_INVALID_VALUE);
    c.scissor = .{ x, y, width, height };
}

pub export fn glClearColor(r: GLclampf, g: GLclampf, b: GLclampf, a: GLclampf) callconv(.c) void {
    if (ctx()) |c| c.clear_color = .{ r, g, b, a };
}

pub export fn glClearDepthf(d: GLclampf) callconv(.c) void {
    if (ctx()) |c| c.clear_depth = std.math.clamp(d, 0, 1);
}

pub export fn glClearStencil(s: GLint) callconv(.c) void {
    _ = s;
}

pub export fn glClear(mask: GLbitfield) callconv(.c) void {
    if (ctx()) |c| c.clear(mask);
}

pub export fn glDepthFunc(func: GLenum) callconv(.c) void {
    const c = ctx() orelse return;
    if (func < GL_NEVER or func > GL_ALWAYS) return c.setError(GL_INVALID_ENUM);
    c.depth_func = func;
}

pub export fn glDepthMask(flag: GLboolean) callconv(.c) void {
    if (ctx()) |c| c.depth_mask = flag != 0;
}

pub export fn glDepthRangef(near: GLclampf, far: GLclampf) callconv(.c) void {
    const c = ctx() orelse return;
    if (near != 0 or far != 1) c.warnOnce(.depth_range);
}

pub export fn glCullFace(mode: GLenum) callconv(.c) void {
    const c = ctx() orelse return;
    if (mode != GL_FRONT and mode != GL_BACK and mode != GL_FRONT_AND_BACK) return c.setError(GL_INVALID_ENUM);
    c.cull_mode = mode;
}

pub export fn glFrontFace(mode: GLenum) callconv(.c) void {
    const c = ctx() orelse return;
    if (mode != GL_CW and mode != GL_CCW) return c.setError(GL_INVALID_ENUM);
    c.front_face = mode;
}

pub export fn glColorMask(r: GLboolean, g: GLboolean, b: GLboolean, a: GLboolean) callconv(.c) void {
    const c = ctx() orelse return;
    if (r == 0 or g == 0 or b == 0 or a == 0) c.warnOnce(.color_mask);
}

pub export fn glBlendFunc(sfactor: GLenum, dfactor: GLenum) callconv(.c) void {
    _ = sfactor;
    _ = dfactor;
}

pub export fn glBlendFuncSeparate(src_rgb: GLenum, dst_rgb: GLenum, src_alpha: GLenum, dst_alpha: GLenum) callconv(.c) void {
    _ = src_rgb;
    _ = dst_rgb;
    _ = src_alpha;
    _ = dst_alpha;
}

pub export fn glBlendEquation(mode: GLenum) callconv(.c) void {
    _ = mode;
}

pub export fn glBlendEquationSeparate(mode_rgb: GLenum, mode_alpha: GLenum) callconv(.c) void {
    _ = mode_rgb;
    _ = mode_alpha;
}

pub export fn glBlendColor(r: GLclampf, g: GLclampf, b: GLclampf, a: GLclampf) callconv(.c) void {
    _ = r;
    _ = g;
    _ = b;
    _ = a;
}

pub export fn glLineWidth(width: GLfloat) callconv(.c) void {
    const c = ctx() orelse return;
    if (width <= 0) return c.setError(GL_INVALID_VALUE);
    if (width != 1) c.warnOnce(.line_width);
}

pub export fn glPolygonOffset(factor: GLfloat, units: GLfloat) callconv(.c) void {
    _ = factor;
    _ = units;
}

pub export fn glSampleCoverage(value: GLclampf, invert: GLboolean) callconv(.c) void {
    _ = value;
    _ = invert;
}

pub export fn glStencilFunc(func: GLenum, ref: GLint, mask: GLuint) callconv(.c) void {
    _ = func;
    _ = ref;
    _ = mask;
}

pub export fn glStencilMask(mask: GLuint) callconv(.c) void {
    _ = mask;
}

pub export fn glStencilOp(fail: GLenum, zfail: GLenum, zpass: GLenum) callconv(.c) void {
    _ = fail;
    _ = zfail;
    _ = zpass;
}

pub export fn glHint(target: GLenum, mode: GLenum) callconv(.c) void {
    _ = target;
    _ = mode;
}

pub export fn glPixelStorei(pname: GLenum, param: GLint) callconv(.c) void {
    const c = ctx() orelse return;
    if (param != 1 and param != 2 and param != 4 and param != 8) return c.setError(GL_INVALID_VALUE);
    switch (pname) {
        GL_UNPACK_ALIGNMENT => c.unpack_alignment = @intCast(param),
        GL_PACK_ALIGNMENT => {},
        else => c.setError(GL_INVALID_ENUM),
    }
}

/// Rendering is submitted to the GPU at `eglSwapBuffers`; until then there
/// is nothing to flush.
pub export fn glFlush() callconv(.c) void {}

pub export fn glFinish() callconv(.c) void {}

pub export fn glGetString(name: GLenum) callconv(.c) ?[*:0]const GLubyte {
    const c = ctx() orelse return null;
    return switch (name) {
        GL_VENDOR => "Stardust",
        GL_RENDERER => "VideoCore IV (Stardust)",
        GL_VERSION => "OpenGL ES 2.0 Stardust",
        GL_SHADING_LANGUAGE_VERSION => "OpenGL ES GLSL ES 1.00",
        GL_EXTENSIONS => "",
        else => {
            c.setError(GL_INVALID_ENUM);
            return null;
        },
    };
}

pub export fn glGetIntegerv(pname: GLenum, data: [*]GLint) callconv(.c) void {
    const c = ctx() orelse return;
    var buf: [4]GLint = undefined;
    const values = c.getIntegers(pname, &buf) orelse return c.setError(GL_INVALID_ENUM);
    @memcpy(data[0..values.len], values);
}

pub export fn glGetBooleanv(pname: GLenum, data: [*]GLboolean) callconv(.c) void {
    const c = ctx() orelse return;
    if (c.capability(pname)) |on| {
        data[0] = @intFromBool(on.*);
        return;
    }
    if (pname == GL_DEPTH_WRITEMASK) {
        data[0] = @intFromBool(c.depth_mask);
        return;
    }
    var buf: [4]GLint = undefined;
    const values = c.getIntegers(pname, &buf) orelse return c.setError(GL_INVALID_ENUM);
    for (values, 0..) |v, i| data[i] = @intFromBool(v != 0);
}

pub export fn glGetFloatv(pname: GLenum, data: [*]GLfloat) callconv(.c) void {
    const c = ctx() orelse return;
    switch (pname) {
        GL_COLOR_CLEAR_VALUE => @memcpy(data[0..4], &c.clear_color),
        GL_DEPTH_CLEAR_VALUE => data[0] = c.clear_depth,
        GL_DEPTH_RANGE => @memcpy(data[0..2], &[2]f32{ 0, 1 }),
        else => {
            var buf: [4]GLint = undefined;
            const values = c.getIntegers(pname, &buf) orelse return c.setError(GL_INVALID_ENUM);
            for (values, 0..) |v, i| data[i] = @floatFromInt(v);
        },
    }
}

// --- Buffers ----------------------------------------------------------------

pub export fn glGenBuffers(n: GLsizei, buffers: [*]GLuint) callconv(.c) void {
    const c = ctx() orelse return;
    if (n < 0) return c.setError(GL_INVALID_VALUE);
    for (buffers[0..@intCast(n)]) |*b| b.* = c.genBuffer();
}

pub export fn glDeleteBuffers(n: GLsizei, buffers: [*]const GLuint) callconv(.c) void {
    const c = ctx() orelse return;
    if (n < 0) return c.setError(GL_INVALID_VALUE);
    for (buffers[0..@intCast(n)]) |b| c.deleteBuffer(b);
}

pub export fn glIsBuffer(buffer: GLuint) callconv(.c) GLboolean {
    const c = ctx() orelse return GL_FALSE;
    return @intFromBool(c.lookupBuffer(buffer) != null);
}

pub export fn glBindBuffer(target: GLenum, buffer: GLuint) callconv(.c) void {
    if (ctx()) |c| c.bindBuffer(target, buffer);
}

pub export fn glBufferData(target: GLenum, size: GLsizeiptr, data: ?*const anyopaque, usage: GLenum) callconv(.c) void {
    const c = ctx() orelse return;
    if (size < 0) return c.setError(GL_INVALID_VALUE);
    const bytes: ?[]const u8 = if (data) |d| @as([*]const u8, @ptrCast(d))[0..@intCast(size)] else null;
    c.bufferData(target, @intCast(size), bytes, usage);
}

pub export fn glBufferSubData(target: GLenum, offset: GLintptr, size: GLsizeiptr, data: ?*const anyopaque) callconv(.c) void {
    const c = ctx() orelse return;
    if (offset < 0 or size < 0) return c.setError(GL_INVALID_VALUE);
    const d = data orelse return;
    c.bufferSubData(target, @intCast(offset), @as([*]const u8, @ptrCast(d))[0..@intCast(size)]);
}

pub export fn glGetBufferParameteriv(target: GLenum, pname: GLenum, params: [*]GLint) callconv(.c) void {
    const c = ctx() orelse return;
    const b = c.boundBuffer(target) orelse return c.setError(GL_INVALID_OPERATION);
    params[0] = switch (pname) {
        GL_BUFFER_SIZE => @intCast(b.size),
        GL_BUFFER_USAGE => @intCast(b.usage),
        else => return c.setError(GL_INVALID_ENUM),
    };
}

// --- Vertex attributes ------------------------------------------------------

pub export fn glVertexAttribPointer(index: GLuint, size: GLint, @"type": GLenum, normalized: GLboolean, stride: GLsizei, pointer: ?*const anyopaque) callconv(.c) void {
    if (ctx()) |c| c.vertexAttribPointer(index, size, @"type", normalized != 0, stride, pointer);
}

pub export fn glEnableVertexAttribArray(index: GLuint) callconv(.c) void {
    if (ctx()) |c| c.enableAttrib(index, true);
}

pub export fn glDisableVertexAttribArray(index: GLuint) callconv(.c) void {
    if (ctx()) |c| c.enableAttrib(index, false);
}

pub export fn glVertexAttrib1f(index: GLuint, x: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ x, 0, 0, 1 });
}

pub export fn glVertexAttrib2f(index: GLuint, x: GLfloat, y: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ x, y, 0, 1 });
}

pub export fn glVertexAttrib3f(index: GLuint, x: GLfloat, y: GLfloat, z: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ x, y, z, 1 });
}

pub export fn glVertexAttrib4f(index: GLuint, x: GLfloat, y: GLfloat, z: GLfloat, w: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ x, y, z, w });
}

pub export fn glVertexAttrib1fv(index: GLuint, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ v[0], 0, 0, 1 });
}

pub export fn glVertexAttrib2fv(index: GLuint, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ v[0], v[1], 0, 1 });
}

pub export fn glVertexAttrib3fv(index: GLuint, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ v[0], v[1], v[2], 1 });
}

pub export fn glVertexAttrib4fv(index: GLuint, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| c.vertexAttrib(index, .{ v[0], v[1], v[2], v[3] });
}

pub export fn glGetVertexAttribiv(index: GLuint, pname: GLenum, params: [*]GLint) callconv(.c) void {
    const c = ctx() orelse return;
    const a = c.attrib(index) orelse return;
    switch (pname) {
        GL_VERTEX_ATTRIB_ARRAY_ENABLED => params[0] = @intFromBool(a.enabled),
        GL_VERTEX_ATTRIB_ARRAY_SIZE => params[0] = a.size,
        GL_VERTEX_ATTRIB_ARRAY_STRIDE => params[0] = @intCast(a.stride),
        GL_VERTEX_ATTRIB_ARRAY_TYPE => params[0] = GL_FLOAT,
        GL_VERTEX_ATTRIB_ARRAY_NORMALIZED => params[0] = GL_FALSE,
        GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING => params[0] = @intCast(a.buffer),
        GL_CURRENT_VERTEX_ATTRIB => for (a.current, 0..) |v, i| {
            params[i] = @intFromFloat(v);
        },
        else => c.setError(GL_INVALID_ENUM),
    }
}

pub export fn glGetVertexAttribfv(index: GLuint, pname: GLenum, params: [*]GLfloat) callconv(.c) void {
    const c = ctx() orelse return;
    const a = c.attrib(index) orelse return;
    if (pname == GL_CURRENT_VERTEX_ATTRIB) {
        @memcpy(params[0..4], &a.current);
        return;
    }
    var v: [4]GLint = undefined;
    glGetVertexAttribiv(index, pname, &v);
    params[0] = @floatFromInt(v[0]);
}

pub export fn glGetVertexAttribPointerv(index: GLuint, pname: GLenum, pointer: *?*const anyopaque) callconv(.c) void {
    const c = ctx() orelse return;
    const a = c.attrib(index) orelse return;
    if (pname != GL_VERTEX_ATTRIB_ARRAY_POINTER) return c.setError(GL_INVALID_ENUM);
    pointer.* = @ptrFromInt(a.offset);
}

// --- Drawing ----------------------------------------------------------------

pub export fn glDrawArrays(mode: GLenum, first: GLint, count: GLsizei) callconv(.c) void {
    const c = ctx() orelse return;
    if (first < 0 or count < 0) return c.setError(GL_INVALID_VALUE);
    c.draw(mode, @intCast(first), @intCast(count), null);
}

pub export fn glDrawElements(mode: GLenum, count: GLsizei, @"type": GLenum, indices: ?*const anyopaque) callconv(.c) void {
    const c = ctx() orelse return;
    if (count < 0) return c.setError(GL_INVALID_VALUE);
    c.draw(mode, 0, @intCast(count), .{ .type = @"type", .pointer = @intFromPtr(indices) });
}

// --- Textures ---------------------------------------------------------------

pub export fn glGenTextures(n: GLsizei, textures: [*]GLuint) callconv(.c) void {
    const c = ctx() orelse return;
    if (n < 0) return c.setError(GL_INVALID_VALUE);
    for (textures[0..@intCast(n)]) |*t| t.* = c.genTexture();
}

pub export fn glDeleteTextures(n: GLsizei, textures: [*]const GLuint) callconv(.c) void {
    const c = ctx() orelse return;
    if (n < 0) return c.setError(GL_INVALID_VALUE);
    for (textures[0..@intCast(n)]) |t| c.deleteTexture(t);
}

pub export fn glIsTexture(texture: GLuint) callconv(.c) GLboolean {
    const c = ctx() orelse return GL_FALSE;
    return @intFromBool(c.lookupTexture(texture) != null);
}

pub export fn glActiveTexture(texture: GLenum) callconv(.c) void {
    const c = ctx() orelse return;
    if (texture < GL_TEXTURE0 or texture >= GL_TEXTURE0 + context.max_texture_units) return c.setError(GL_INVALID_ENUM);
    c.active_texture = texture - GL_TEXTURE0;
}

pub export fn glBindTexture(target: GLenum, texture: GLuint) callconv(.c) void {
    if (ctx()) |c| c.bindTexture(target, texture);
}

pub export fn glTexImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, @"type": GLenum, pixels: ?*const anyopaque) callconv(.c) void {
    const c = ctx() orelse return;
    if (level < 0 or width < 0 or height < 0 or border != 0) return c.setError(GL_INVALID_VALUE);
    if (internalformat < 0 or @as(GLenum, @intCast(internalformat)) != format) return c.setError(GL_INVALID_OPERATION);
    c.texImage2D(target, @intCast(level), @intCast(width), @intCast(height), format, @"type", if (pixels) |p| @ptrCast(p) else null);
}

pub export fn glTexSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, @"type": GLenum, pixels: ?*const anyopaque) callconv(.c) void {
    const c = ctx() orelse return;
    if (level < 0 or xoffset < 0 or yoffset < 0 or width < 0 or height < 0) return c.setError(GL_INVALID_VALUE);
    const p = pixels orelse return;
    c.texSubImage2D(target, @intCast(level), @intCast(xoffset), @intCast(yoffset), @intCast(width), @intCast(height), format, @"type", @ptrCast(p));
}

pub export fn glTexParameteri(target: GLenum, pname: GLenum, param: GLint) callconv(.c) void {
    if (ctx()) |c| c.texParameter(target, pname, @bitCast(param));
}

pub export fn glTexParameteriv(target: GLenum, pname: GLenum, params: [*]const GLint) callconv(.c) void {
    glTexParameteri(target, pname, params[0]);
}

pub export fn glTexParameterf(target: GLenum, pname: GLenum, param: GLfloat) callconv(.c) void {
    glTexParameteri(target, pname, @intFromFloat(param));
}

pub export fn glTexParameterfv(target: GLenum, pname: GLenum, params: [*]const GLfloat) callconv(.c) void {
    glTexParameterf(target, pname, params[0]);
}

/// Mipmaps are not supported yet: textures always sample the base level, so
/// there is nothing to generate.
pub export fn glGenerateMipmap(target: GLenum) callconv(.c) void {
    const c = ctx() orelse return;
    if (target != GL_TEXTURE_2D) return c.setError(GL_INVALID_ENUM);
}

// --- Shaders and programs ---------------------------------------------------

pub export fn glCreateShader(@"type": GLenum) callconv(.c) GLuint {
    const c = ctx() orelse return 0;
    return c.createShader(@"type");
}

pub export fn glDeleteShader(shader: GLuint) callconv(.c) void {
    if (ctx()) |c| c.deleteShader(shader);
}

pub export fn glIsShader(shader: GLuint) callconv(.c) GLboolean {
    const c = ctx() orelse return GL_FALSE;
    return @intFromBool(c.lookupShader(shader) != null);
}

pub export fn glShaderSource(shader: GLuint, count: GLsizei, strings: [*]const [*]const GLchar, lengths: ?[*]const GLint) callconv(.c) void {
    const c = ctx() orelse return;
    if (count < 0) return c.setError(GL_INVALID_VALUE);
    c.shaderSource(shader, strings[0..@intCast(count)], if (lengths) |l| l[0..@intCast(count)] else null);
}

pub export fn glCompileShader(shader: GLuint) callconv(.c) void {
    if (ctx()) |c| c.compileShader(shader);
}

pub export fn glGetShaderiv(shader: GLuint, pname: GLenum, params: [*]GLint) callconv(.c) void {
    if (ctx()) |c| c.getShaderiv(shader, pname, &params[0]);
}

pub export fn glGetShaderInfoLog(shader: GLuint, buf_size: GLsizei, length: ?*GLsizei, info_log: [*]GLchar) callconv(.c) void {
    const c = ctx() orelse return;
    const s = c.lookupShader(shader) orelse return c.setError(GL_INVALID_VALUE);
    copyString(s.log.text(), buf_size, length, info_log);
}

pub export fn glGetShaderSource(shader: GLuint, buf_size: GLsizei, length: ?*GLsizei, source: [*]GLchar) callconv(.c) void {
    const c = ctx() orelse return;
    const s = c.lookupShader(shader) orelse return c.setError(GL_INVALID_VALUE);
    copyString(s.source, buf_size, length, source);
}

pub export fn glReleaseShaderCompiler() callconv(.c) void {}

pub export fn glCreateProgram() callconv(.c) GLuint {
    const c = ctx() orelse return 0;
    return c.createProgram();
}

pub export fn glDeleteProgram(program: GLuint) callconv(.c) void {
    if (ctx()) |c| c.deleteProgram(program);
}

pub export fn glIsProgram(program: GLuint) callconv(.c) GLboolean {
    const c = ctx() orelse return GL_FALSE;
    return @intFromBool(c.lookupProgram(program) != null);
}

pub export fn glAttachShader(program: GLuint, shader: GLuint) callconv(.c) void {
    if (ctx()) |c| c.attachShader(program, shader);
}

pub export fn glDetachShader(program: GLuint, shader: GLuint) callconv(.c) void {
    if (ctx()) |c| c.detachShader(program, shader);
}

pub export fn glBindAttribLocation(program: GLuint, index: GLuint, name: [*:0]const GLchar) callconv(.c) void {
    if (ctx()) |c| c.bindAttribLocation(program, index, cstr(name));
}

pub export fn glLinkProgram(program: GLuint) callconv(.c) void {
    if (ctx()) |c| c.linkProgram(program);
}

pub export fn glValidateProgram(program: GLuint) callconv(.c) void {
    const c = ctx() orelse return;
    if (c.lookupProgram(program) == null) c.setError(GL_INVALID_VALUE);
}

pub export fn glUseProgram(program: GLuint) callconv(.c) void {
    if (ctx()) |c| c.useProgram(program);
}

pub export fn glGetProgramiv(program: GLuint, pname: GLenum, params: [*]GLint) callconv(.c) void {
    if (ctx()) |c| c.getProgramiv(program, pname, &params[0]);
}

pub export fn glGetProgramInfoLog(program: GLuint, buf_size: GLsizei, length: ?*GLsizei, info_log: [*]GLchar) callconv(.c) void {
    const c = ctx() orelse return;
    const p = c.lookupProgram(program) orelse return c.setError(GL_INVALID_VALUE);
    copyString(p.log.text(), buf_size, length, info_log);
}

pub export fn glGetAttribLocation(program: GLuint, name: [*:0]const GLchar) callconv(.c) GLint {
    const c = ctx() orelse return -1;
    return c.getAttribLocation(program, cstr(name));
}

pub export fn glGetUniformLocation(program: GLuint, name: [*:0]const GLchar) callconv(.c) GLint {
    const c = ctx() orelse return -1;
    return c.getUniformLocation(program, cstr(name));
}

pub export fn glGetActiveAttrib(program: GLuint, index: GLuint, buf_size: GLsizei, length: ?*GLsizei, size: *GLint, @"type": *GLenum, name: [*]GLchar) callconv(.c) void {
    const c = ctx() orelse return;
    const a = c.activeAttrib(program, index) orelse return;
    size.* = 1;
    @"type".* = typeEnum(a.type);
    copyString(a.name, buf_size, length, name);
}

pub export fn glGetActiveUniform(program: GLuint, index: GLuint, buf_size: GLsizei, length: ?*GLsizei, size: *GLint, @"type": *GLenum, name: [*]GLchar) callconv(.c) void {
    const c = ctx() orelse return;
    const u = c.activeUniform(program, index) orelse return;
    size.* = 1;
    @"type".* = typeEnum(u.type);
    copyString(u.name, buf_size, length, name);
}

fn typeEnum(t: context.glsl.Type) GLenum {
    return switch (t) {
        .float => GL_FLOAT,
        .vec2 => GL_FLOAT_VEC2,
        .vec3 => GL_FLOAT_VEC3,
        .vec4 => GL_FLOAT_VEC4,
        .int => GL_INT,
        .bool => GL_BOOL,
        .mat2 => GL_FLOAT_MAT2,
        .mat3 => GL_FLOAT_MAT3,
        .mat4 => GL_FLOAT_MAT4,
        .sampler2D => GL_SAMPLER_2D,
        .void => 0,
    };
}

fn copyString(s: []const u8, buf_size: GLsizei, length: ?*GLsizei, out: [*]GLchar) void {
    if (buf_size <= 0) {
        if (length) |l| l.* = 0;
        return;
    }
    const n = @min(s.len, @as(usize, @intCast(buf_size)) - 1);
    @memcpy(out[0..n], s[0..n]);
    out[n] = 0;
    if (length) |l| l.* = @intCast(n);
}

// --- Uniforms ---------------------------------------------------------------

pub export fn glUniform1f(location: GLint, x: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.uniformFloats(location, 1, &.{x});
}

pub export fn glUniform2f(location: GLint, x: GLfloat, y: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.uniformFloats(location, 2, &.{ x, y });
}

pub export fn glUniform3f(location: GLint, x: GLfloat, y: GLfloat, z: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.uniformFloats(location, 3, &.{ x, y, z });
}

pub export fn glUniform4f(location: GLint, x: GLfloat, y: GLfloat, z: GLfloat, w: GLfloat) callconv(.c) void {
    if (ctx()) |c| c.uniformFloats(location, 4, &.{ x, y, z, w });
}

pub export fn glUniform1fv(location: GLint, count: GLsizei, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformFloats(location, 1, v[0..1]);
}

pub export fn glUniform2fv(location: GLint, count: GLsizei, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformFloats(location, 2, v[0..2]);
}

pub export fn glUniform3fv(location: GLint, count: GLsizei, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformFloats(location, 3, v[0..3]);
}

pub export fn glUniform4fv(location: GLint, count: GLsizei, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformFloats(location, 4, v[0..4]);
}

pub export fn glUniform1i(location: GLint, x: GLint) callconv(.c) void {
    if (ctx()) |c| c.uniformInts(location, 1, &.{x});
}

pub export fn glUniform2i(location: GLint, x: GLint, y: GLint) callconv(.c) void {
    if (ctx()) |c| c.uniformInts(location, 2, &.{ x, y });
}

pub export fn glUniform3i(location: GLint, x: GLint, y: GLint, z: GLint) callconv(.c) void {
    if (ctx()) |c| c.uniformInts(location, 3, &.{ x, y, z });
}

pub export fn glUniform4i(location: GLint, x: GLint, y: GLint, z: GLint, w: GLint) callconv(.c) void {
    if (ctx()) |c| c.uniformInts(location, 4, &.{ x, y, z, w });
}

pub export fn glUniform1iv(location: GLint, count: GLsizei, v: [*]const GLint) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformInts(location, 1, v[0..1]);
}

pub export fn glUniform2iv(location: GLint, count: GLsizei, v: [*]const GLint) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformInts(location, 2, v[0..2]);
}

pub export fn glUniform3iv(location: GLint, count: GLsizei, v: [*]const GLint) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformInts(location, 3, v[0..3]);
}

pub export fn glUniform4iv(location: GLint, count: GLsizei, v: [*]const GLint) callconv(.c) void {
    if (ctx()) |c| if (c.uniformCount(count)) c.uniformInts(location, 4, v[0..4]);
}

pub export fn glUniformMatrix2fv(location: GLint, count: GLsizei, transpose: GLboolean, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| if (c.uniformMatrix(count, transpose)) c.uniformFloats(location, 4, v[0..4]);
}

pub export fn glUniformMatrix3fv(location: GLint, count: GLsizei, transpose: GLboolean, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| if (c.uniformMatrix(count, transpose)) c.uniformFloats(location, 9, v[0..9]);
}

pub export fn glUniformMatrix4fv(location: GLint, count: GLsizei, transpose: GLboolean, v: [*]const GLfloat) callconv(.c) void {
    if (ctx()) |c| if (c.uniformMatrix(count, transpose)) c.uniformFloats(location, 16, v[0..16]);
}

pub export fn glGetUniformfv(program: GLuint, location: GLint, params: [*]GLfloat) callconv(.c) void {
    const c = ctx() orelse return;
    const words = c.uniformValue(program, location) orelse return;
    for (words, 0..) |w, i| params[i] = @bitCast(w);
}

pub export fn glGetUniformiv(program: GLuint, location: GLint, params: [*]GLint) callconv(.c) void {
    const c = ctx() orelse return;
    const words = c.uniformValue(program, location) orelse return;
    for (words, 0..) |w, i| params[i] = @intFromFloat(@as(f32, @bitCast(w)));
}

// --- Framebuffers -----------------------------------------------------------

pub export fn glBindFramebuffer(target: GLenum, framebuffer: GLuint) callconv(.c) void {
    const c = ctx() orelse return;
    if (target != GL_FRAMEBUFFER) return c.setError(GL_INVALID_ENUM);
    if (framebuffer != 0) {
        c.warnOnce(.framebuffer_objects);
        c.setError(GL_INVALID_OPERATION);
    }
}

pub export fn glCheckFramebufferStatus(target: GLenum) callconv(.c) GLenum {
    const c = ctx() orelse return 0;
    if (target != GL_FRAMEBUFFER) {
        c.setError(GL_INVALID_ENUM);
        return 0;
    }
    return GL_FRAMEBUFFER_COMPLETE;
}

pub export fn glReadPixels(x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, @"type": GLenum, pixels: ?*anyopaque) callconv(.c) void {
    _ = .{ x, y, width, height, format, @"type", pixels };
    const c = ctx() orelse return;
    c.warnOnce(.read_pixels);
    c.setError(GL_INVALID_OPERATION);
}

/// Every exported entry point by name, for `eglGetProcAddress`.
pub fn procAddress(name: []const u8) ?*const anyopaque {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(@This()).@"struct".decls) |d| {
        if (comptime std.mem.startsWith(u8, d.name, "gl") and @typeInfo(@TypeOf(@field(@This(), d.name))) == .@"fn") {
            if (std.mem.eql(u8, name, d.name)) return @ptrCast(&@field(@This(), d.name));
        }
    }
    return null;
}

test "procAddress finds entry points" {
    try std.testing.expect(procAddress("glClear") == @as(*const anyopaque, @ptrCast(&glClear)));
    try std.testing.expect(procAddress("glNotAFunction") == null);
}
