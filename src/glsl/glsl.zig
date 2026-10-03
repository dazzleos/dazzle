//! GLSL ES 1.00 shaders for the vc4 API, until shaders are written in Zig.
//!
//! * `program`: compiling and linking a vertex and a fragment shader, and
//!   lowering each hardware stage to the vc4 compiler's builder API
//! * `Pipeline`: a linked program compiled for the GPU, with its render
//!   state, recording draws into a `vc4.render.Frame`
//!
//!     var cube = try glsl.Pipeline.init(gpa, dev, vs_source, fs_source, .{
//!         .vertex_stride = @sizeOf(Vertex),
//!         .attributes = &.{ .{ .name = "pos", .offset = 0 }, ... },
//!         .depth_test = true,
//!     });
//!     try cube.set("mvp", matrix);
//!     try cube.draw(&frame, .{ .vertices = vbo.handle, .count = 36, ... });

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const lower = @import("lower.zig");
pub const program = @import("program.zig");
pub const pipeline = @import("pipeline.zig");

pub const Log = program.Log;
pub const Shader = program.Shader;
pub const Program = program.Program;
pub const compileShader = program.compileShader;
pub const link = program.link;
pub const Pipeline = pipeline.Pipeline;

test {
    _ = lexer;
    _ = parser;
    _ = lower;
    _ = program;
    _ = pipeline;
    _ = @import("shader_tests.zig");
}
