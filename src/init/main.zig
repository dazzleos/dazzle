//! Stardust init: the only program in the system image.
//!
//! When started by the kernel as PID 1 it mounts the pseudo filesystems,
//! starts the network log server, then brings up the display and renders a
//! triangle with the V3D. It can
//! also be run as an ordinary program on Raspberry Pi OS (from a text
//! console, with no compositor holding the display) for development.

const std = @import("std");
const vc4 = @import("vc4");
const linux = std.os.linux;
const drm = vc4.drm;
const logserver = @import("logserver.zig");
const sys = @import("sys");
const demos = @import("demos.zig");
const glcube = @import("glcube.zig");
const display_mod = vc4.display;

const print = sys.print;

pub fn main() void {
    const is_init = linux.getpid() == 1;
    if (is_init) {
        mountPseudoFilesystems();
        sys.logToKmsg();
    }
    print("stardust: starting{s}\n", .{if (is_init) " as init" else ""});
    // Start serving the log before touching the GPU, so it stays readable
    // if a GPU job hangs.
    if (is_init) logserver.start();

    run(is_init) catch |err| {
        print("stardust: error: {s}\n", .{@errorName(err)});
        if (err == error.NoVc4Device)
            print("stardust: the vc4 driver did not create a DRM device; look for vc4, hdmi or v3d errors earlier in the log\n", .{});
    };

    // PID 1 must never exit; the kernel panics if it does.
    if (is_init) while (true) {
        _ = linux.pause();
    };
}

fn mountPseudoFilesystems() void {
    const mounts = [_]struct { src: [*:0]const u8, dir: [*:0]const u8, fstype: [*:0]const u8, flags: u32 }{
        .{ .src = "proc", .dir = "/proc", .fstype = "proc", .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC },
        .{ .src = "sysfs", .dir = "/sys", .fstype = "sysfs", .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC },
        .{ .src = "devtmpfs", .dir = "/dev", .fstype = "devtmpfs", .flags = linux.MS.NOSUID },
    };
    for (mounts) |m| {
        _ = linux.mkdir(m.dir, 0o755);
        _ = sys.check(linux.mount(m.src, m.dir, m.fstype, m.flags, 0)) catch |err|
            print("stardust: mount {s}: {s}\n", .{ m.dir, @errorName(err) });
    }
}

/// The demos: the vc4 API ones, and the same cube through OpenGL ES.
const DemoName = enum { triangle, spin, cube, glcube };

fn run(is_init: bool) !void {
    var cmdline_buf: [1024]u8 = undefined;
    const name = demoFromCmdline(sys.readCmdline(&cmdline_buf));
    print("stardust: demo {s} (choose with stardust.demo=triangle|spin|cube|glcube)\n", .{@tagName(name)});

    // When not running as init, stop after a while; the kernel restores the
    // previous display state once we exit.
    const run_ns: ?u64 = if (is_init) null else 10 * std.time.ns_per_s;

    const kind: demos.Kind = switch (name) {
        .glcube => return glcube.run(run_ns),
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
        if (run_ns) |ns| sys.sleepMs(@intCast(ns / std.time.ns_per_ms));
        while (is_init) _ = linux.pause();
        return;
    }

    // Frame loop: render into the back buffer, then flip at vertical blank.
    var stats: demos.FrameStats = .init(sys.nowNs());
    while (true) {
        const now = sys.nowNs();
        if (run_ns) |ns| if (now - start >= ns) return;
        const t: f32 = @floatCast(@as(f64, @floatFromInt(now - start)) / std.time.ns_per_s);
        try demo.draw(dev, display.backTarget(), t);
        const render_ns = sys.nowNs() - now;
        try display.present();
        stats.frame(render_ns);
    }
}

fn demoFromCmdline(cmdline: []const u8) DemoName {
    const name = sys.cmdlineValue(cmdline, "stardust.demo") orelse return .cube;
    return std.meta.stringToEnum(DemoName, name) orelse blk: {
        print("stardust: unknown demo '{s}', using cube\n", .{name});
        break :blk .cube;
    };
}

test {
    _ = @import("demos.zig");
    _ = @import("glcube.zig");
    _ = @import("logserver.zig");
    _ = @import("programs.zig");
}
