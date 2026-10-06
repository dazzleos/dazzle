//! Native Dazzle apps: a window on dazzle-shell that the app renders
//! into with the vc4 API.
//!
//! * `Window`: a Wayland toplevel with the seat's pointer and keyboard, and
//!   up to three buffers shared with the shell
//! * `Gpu`: what a window needs from the GPU (the device, or a fake in
//!   tests)
//! * `Controls`: what the title bar's buttons (and dragging it) do
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

/// What an app's title bar does to its window (for the toolkit's TitleBar:
/// `.on_close = .of(&controls, app.Controls.close)`, and so on).
pub const Controls = struct {
    win: *Window,
    /// The close button was pressed: the app should end.
    quit: bool = false,

    pub fn close(c: *Controls) void {
        c.quit = true;
    }

    /// The maximize button: fill the screen, or go back to the window's
    /// own size.
    pub fn toggleMaximized(c: *Controls) void {
        c.win.setMaximized(!c.win.maximized);
    }

    /// The title bar was pressed: drag the window (unless it fills the
    /// screen).
    pub fn drag(c: *Controls) void {
        if (!c.win.maximized) c.win.startMove();
    }
};

test {
    _ = window;
}
