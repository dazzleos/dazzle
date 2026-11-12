//! Native Dazzle apps: a window on dazzle-shell that the app renders
//! into with the vc4 API.
//!
//! * `Window`: a Wayland toplevel with the seat's pointer and keyboard, and
//!   up to three buffers shared with the shell
//! * `Gpu`: what a window needs from the GPU (the device, or a fake in
//!   tests)
//! * `Controls`: what the title bar's buttons (and dragging it) do
//! * `Clipboard`: the system's clipboard, for text (`Window.clipboard`)
//! * `ChildEnv`: the environment a child app needs to find the compositor
//!
//!     var dev = try vc4.device.openRender();
//!     const win = try app.Window.open(gpa, .device(&dev), init.environ, .{ .title = "Hello", .size = .{ 640, 480 } });
//!     while (!win.closed) {
//!         try win.poll();
//!         frame.begin(try win.beginFrame(), .{ .clear = 0xff000000 });
//!         // ... frame.draw(...)
//!         try win.present(&frame);
//!     }

const std = @import("std");
const wayland = @import("wayland");

pub const window = @import("window.zig");
pub const clipboard = @import("clipboard.zig");
pub const Clipboard = clipboard.Clipboard;
pub const Window = window.Window;
pub const Gpu = window.Gpu;
pub const InputEvent = window.InputEvent;
pub const TextInputState = window.TextInputState;
pub const CursorShape = wayland.protocol.wp_cursor_shape_device_v1.shape;
pub const TextInputProtocol = wayland.protocol.zwp_text_input_v3;

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

    /// Toggle whether the window fills the entire display (fullscreen).
    pub fn toggleFullscreen(c: *Controls) void {
        c.win.setFullscreen(!c.win.fullscreen);
    }

    /// The title bar was pressed: drag the window (unless it fills the
    /// screen).
    pub fn drag(c: *Controls) void {
        if (!c.win.maximized) c.win.startMove();
    }
};

/// The environment variables a child app needs to find the compositor
/// (`XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`) and, if `default_home` is
/// given, its home folder (`HOME`, from `environ` or `default_home`).
pub const ChildEnv = struct {
    bufs: [3][160]u8 = undefined,
    vars: [3][*:0]const u8 = undefined,
    len: usize = 0,

    pub fn init(env: *ChildEnv, environ: std.process.Environ, default_home: ?[]const u8) []const [*:0]const u8 {
        env.len = 0;
        if (default_home) |fallback| {
            const home = std.process.Environ.getPosix(environ, "HOME") orelse fallback;
            if (std.mem.printSentinel(&env.bufs[env.len], "HOME={s}", .{home}, 0)) |s| {
                env.vars[env.len] = s.ptr;
                env.len += 1;
            } else |_| {}
        }
        for ([_][]const u8{ "XDG_RUNTIME_DIR", "WAYLAND_DISPLAY" }) |name| {
            const value = std.process.Environ.getPosix(environ, name) orelse continue;
            if (std.mem.printSentinel(&env.bufs[env.len], "{s}={s}", .{ name, value }, 0)) |s| {
                env.vars[env.len] = s.ptr;
                env.len += 1;
            } else |_| {}
        }
        return env.vars[0..env.len];
    }
};

test "child environment carries the compositor's socket" {
    const vars = [_:null]?[*:0]const u8{ "XDG_RUNTIME_DIR=/run", "WAYLAND_DISPLAY=wayland-1" };
    const environ: std.process.Environ = .{ .block = .{ .slice = @ptrCast((&vars)[0..vars.len]) } };

    var env: ChildEnv = undefined;
    const with_home = env.init(environ, "/data/user");
    try std.testing.expectEqual(@as(usize, 3), with_home.len);
    try std.testing.expectEqualStrings("HOME=/data/user", std.mem.span(with_home[0]));
    try std.testing.expectEqualStrings("XDG_RUNTIME_DIR=/run", std.mem.span(with_home[1]));
    try std.testing.expectEqualStrings("WAYLAND_DISPLAY=wayland-1", std.mem.span(with_home[2]));

    const wayland_only = env.init(environ, null);
    try std.testing.expectEqual(@as(usize, 2), wayland_only.len);
    try std.testing.expectEqualStrings("XDG_RUNTIME_DIR=/run", std.mem.span(wayland_only[0]));
    try std.testing.expectEqualStrings("WAYLAND_DISPLAY=wayland-1", std.mem.span(wayland_only[1]));
}

test {
    _ = window;
    _ = clipboard;
}
