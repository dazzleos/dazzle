//! Stardust's low-level graphics API for the VideoCore IV (BCM2835 V3D),
//! through the kernel's vc4 DRM driver.
//!
//! The shell and native apps draw with it directly (with shaders built with
//! the compiler API, or written in Zig with the `shader` module):
//!
//! * `device`: GPU buffers, shader upload and job submission
//! * `compiler`: build shaders as SSA values and compile them to QPU code
//! * `render`: assemble a draw job (control list, shader record, uniforms)
//! * `texture`: texture memory layout and sampler configuration
//! * `display`: double-buffered scanout with page flips
//! * `drm`: mode setting and other DRM core ioctls
//! * `kms`: atomic mode setting, showing buffers on the display's planes
//!
//! Lower-level pieces (`qpu` instruction encoding, `qpu_schedule`, the
//! `qpu_sim` simulator and `cl` control list packets) are exported for
//! tools and tests.

pub const device = @import("device.zig");
pub const compiler = @import("compiler.zig");
pub const render = @import("render.zig");
pub const texture = @import("texture.zig");
pub const display = @import("display.zig");
pub const drm = @import("drm.zig");
pub const kms = @import("kms.zig");
pub const cl = @import("cl.zig");
pub const qpu = @import("qpu.zig");
pub const qpu_schedule = @import("qpu_schedule.zig");
pub const qpu_sim = @import("qpu_sim.zig");
/// Hand-written triangle shaders, known to work on hardware. Used as a
/// reference by tests and by the triangle demo.
pub const reference_shaders = @import("reference_shaders.zig");

pub const Device = device.Device;
pub const Bo = device.Bo;
pub const SubmitCl = device.SubmitCl;

test {
    _ = device;
    _ = compiler;
    _ = render;
    _ = texture;
    _ = display;
    _ = drm;
    _ = kms;
    _ = cl;
    _ = qpu;
    _ = qpu_schedule;
    _ = qpu_sim;
    _ = reference_shaders;
}
