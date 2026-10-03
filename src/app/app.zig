//! Native Stardust apps: a window on stardust-shell that the app renders
//! into with the vc4 API.
//!
//! * `Window`: a Wayland toplevel with the seat's pointer and keyboard, and
//!   up to three buffers shared with the shell
//! * `Gpu`: what a window needs from the GPU (the device, or a fake in
//!   tests)
//!
//!     const dev = try vc4.device.openRender();
//!     const win = try app.Window.open(gpa, .device(&dev), socket_path, "Hello");
//!     while (!win.closed) {
//!         try win.poll();
//!         frame.begin(try win.beginFrame(), .{ .clear = 0xff000000 });
//!         // ... frame.draw(...)
//!         try win.present(&frame);
//!     }

pub const window = @import("window.zig");
pub const Window = window.Window;
pub const Gpu = window.Gpu;
pub const InputEvent = window.InputEvent;

test {
    _ = window;
}
