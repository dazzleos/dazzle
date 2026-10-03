//! OpenGL ES 2.0 for Stardust, built on the low-level vc4 API.
//!
//! * `glsl`: the GLSL ES 1.00 compiler front end (shaders and programs)

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
    _ = glsl.lexer;
    _ = glsl.parser;
    _ = glsl.lower;
    _ = glsl.program;
}
