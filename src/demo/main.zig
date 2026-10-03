//! The Stardust demo program: draws one of the demo scenes on the GPU.
//!
//! Init starts it as the unprivileged Stardust user, with the demo named on
//! the kernel command line (`stardust.demo=`) and stdout and stderr going
//! to the kernel log. It can also be run by hand, on Stardust or on
//! Raspberry Pi OS (from a text console, with no compositor holding the
//! display, as a user who can open /dev/dri/card*):
//!
//!     stardust-demo [triangle|spin|cube|glcube]
//!
//! It runs until it is stopped; the kernel restores the previous display
//! state when it exits.

const std = @import("std");
const vc4 = @import("vc4");
const linux = std.os.linux;
const drm = vc4.drm;
const sys = @import("sys");
const demos = @import("demos.zig");
const glcube = @import("glcube.zig");
const textdemo = @import("textdemo.zig");
const font = @import("font");
const display_mod = vc4.display;

const print = sys.print;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    const name = if (args.next()) |arg| std.meta.stringToEnum(DemoName, arg) orelse {
        print("usage: stardust-demo [triangle|spin|cube|glcube|text [font.ttf]]\n", .{});
        return 2;
    } else .cube;
    const font_path: [*:0]const u8 = args.next() orelse font.system_font_path;
    print("stardust: demo {s} running as uid {d}\n", .{ @tagName(name), linux.getuid() });

    run(name, font_path) catch |err| {
        print("stardust: error: {s}\n", .{@errorName(err)});
        if (err == error.NoVc4Device)
            print("stardust: the vc4 driver did not create a DRM device; look for vc4, hdmi or v3d errors earlier in the log\n", .{});
        if (err == error.AccessDenied)
            print("stardust: no permission to use the GPU; init gives the Stardust user access to /dev/dri\n", .{});
        return 1;
    };
    return 0;
}

/// The demos: the vc4 API ones, the same cube through OpenGL ES, and text.
pub const DemoName = enum { triangle, spin, cube, glcube, text };

fn run(name: DemoName, font_path: [*:0]const u8) !void {
    const kind: demos.Kind = switch (name) {
        .glcube => return glcube.run(),
        .text => return textdemo.run(font_path),
        inline else => |n| @field(demos.Kind, @tagName(n)),
    };

    const dev = try vc4.device.open();
    defer sys.close(dev.fd);
    const fd = dev.fd;

    const ident1 = try dev.getParam(.v3d_ident1);
    print("stardust: V3D revision {d}, {d} slices of {d} QPUs\n", .{
        ident1 & 0xf,
        (ident1 >> 4) & 0xf,
        (ident1 >> 8) & 0xf,
    });

    const output = try drm.waitForOutput(fd);
    const mode = output.mode;
    print("stardust: output connector {d} on crtc {d}: {s} {d}x{d}@{d}\n", .{
        output.connector_id, output.crtc_id, mode.nameSlice(), mode.hdisplay, mode.vdisplay, mode.vrefresh,
    });

    var display = try display_mod.Display.init(dev, output);
    const demo = try demos.Demo.init(kind, dev);
    print("stardust: shaders compiled and uploaded\n", .{});

    const start = sys.nowNs();
    try demo.draw(dev, display.backTarget(), 0);
    try display.present();
    print("stardust: displaying {s}\n", .{@tagName(kind)});

    if (!demo.animated()) {
        // Keep the device open (and so the picture up) until stopped.
        while (true) _ = linux.pause();
    }

    // Frame loop: render into the back buffer, then flip at vertical blank.
    var stats: demos.FrameStats = .init(sys.nowNs());
    while (true) {
        const now = sys.nowNs();
        const t: f32 = @floatCast(@as(f64, @floatFromInt(now - start)) / std.time.ns_per_s);
        try demo.draw(dev, display.backTarget(), t);
        const render_ns = sys.nowNs() - now;
        try display.present();
        stats.frame(render_ns);
    }
}

test {
    _ = @import("demos.zig");
    _ = @import("glcube.zig");
    _ = @import("textdemo.zig");
    _ = @import("programs.zig");
}
