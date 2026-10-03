//! Shaders written in Zig, for the vc4 GPU.
//!
//! A shader program is one Zig file with a vertex and a fragment entry
//! point, compiled by Zig to SPIR-V (see `src/shader/gpu.zig`, which shader
//! sources import as "gpu"). The build translates it to the GPU's code with
//! `Program.compile` and embeds the result; apps can also compile SPIR-V
//! when they run. A `Pipeline` draws with a program.
//!
//! * `spirv`: reading SPIR-V modules
//! * `lower`: SPIR-V entry points to the vc4 compiler's builder
//! * `program`: linking, compiling and encoding programs
//! * `pipeline`: drawing with a program and its vertex layout

pub const spirv = @import("spirv.zig");
pub const lower = @import("lower.zig");
pub const program = @import("program.zig");
pub const pipeline = @import("pipeline.zig");

pub const Program = program.Program;
pub const Options = program.Options;
pub const Blend = program.Blend;
pub const Diagnostic = program.Diagnostic;
pub const Pipeline = pipeline.Pipeline;

test {
    _ = spirv;
    _ = lower;
    _ = program;
    _ = pipeline;
    _ = @import("tests.zig");
}
