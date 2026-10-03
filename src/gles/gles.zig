//! OpenGL ES 2.0 and EGL for Stardust, built on the low-level vc4 API.
//!
//! * `gl`: the OpenGL ES 2.0 entry points (C ABI) and constants
//! * `egl`: EGL 1.4 display, surface and context management (C ABI), on
//!   Wayland (with the wayland-egl window API) or directly on the screen
//! * `glsl`: the GLSL ES 1.00 compiler front end (shaders and programs)
//!
//! The entry points are exported under their standard names, so C code can
//! call them as usual; Zig code imports this module and calls the same
//! functions (`gles.gl.glClear`).

pub const gl = @import("gl.zig");
pub const egl = @import("egl.zig");
pub const context = @import("context.zig");

pub const glsl = struct {
    pub const lexer = @import("glsl/lexer.zig");
    pub const parser = @import("glsl/parser.zig");
    pub const lower = @import("glsl/lower.zig");
    pub const program = @import("glsl/program.zig");

    pub const Log = program.Log;
    pub const Shader = program.Shader;
    pub const Program = program.Program;
    pub const compileShader = program.compileShader;
    pub const link = program.link;
};

test {
    _ = gl;
    _ = egl;
    _ = context;
    _ = glsl.lexer;
    _ = glsl.parser;
    _ = glsl.lower;
    _ = glsl.program;
    _ = @import("glsl/shader_tests.zig");
}
