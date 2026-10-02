//! Stardust init: the only program in the system image.
//!
//! When started by the kernel as PID 1 it mounts the pseudo filesystems,
//! then brings up the display and renders a triangle with the V3D. It can
//! also be run as an ordinary program on Raspberry Pi OS (from a text
//! console, with no compositor holding the display) for development.

const std = @import("std");
const linux = std.os.linux;
const drm = @import("drm.zig");
const sys = @import("sys.zig");
const triangle = @import("triangle.zig");
const vc4 = @import("vc4.zig");

const print = sys.print;

pub fn main() void {
    const is_init = linux.getpid() == 1;
    print("stardust: starting{s}\n", .{if (is_init) " as init" else ""});
    if (is_init) mountPseudoFilesystems();

    run(is_init) catch |err| print("stardust: error: {s}\n", .{@errorName(err)});

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

/// Opens the vc4 DRM device. Drivers may still be probing when init
/// starts, so poll for a few seconds.
fn openVc4() !linux.fd_t {
    const paths = [_][*:0]const u8{ "/dev/dri/card0", "/dev/dri/card1", "/dev/dri/card2" };
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        for (paths) |path| {
            const fd = sys.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch continue;
            var name_buf: [32]u8 = undefined;
            const name = drm.driverName(fd, &name_buf) catch "";
            if (std.mem.eql(u8, name, "vc4")) {
                print("stardust: opened {s} ({s})\n", .{ path, name });
                return fd;
            }
            sys.close(fd);
        }
        sys.sleepMs(100);
    }
    return error.NoVc4Device;
}

/// HDMI hotplug detection can lag behind the driver binding.
fn waitForOutput(fd: linux.fd_t) !drm.Output {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        return drm.findOutput(fd) catch |err| {
            if (err != error.NoConnectedOutput or attempt == 50) return err;
            sys.sleepMs(100);
            continue;
        };
    }
}

fn run(is_init: bool) !void {
    const fd = try openVc4();
    defer sys.close(fd);
    const dev: vc4.Device = .{ .fd = fd };

    const ident1 = try dev.getParam(.v3d_ident1);
    print("stardust: V3D revision {d}, {d} slices of {d} QPUs\n", .{
        ident1 & 0xf,
        (ident1 >> 4) & 0xf,
        (ident1 >> 8) & 0xf,
    });

    const output = try waitForOutput(fd);
    const mode = output.mode;
    print("stardust: output connector {d} on crtc {d}: {s} {d}x{d}@{d}\n", .{
        output.connector_id, output.crtc_id, mode.nameSlice(), mode.hdisplay, mode.vdisplay, mode.vrefresh,
    });

    const pitch = triangle.Target.pitch(mode.hdisplay);
    const bo = try dev.createBo(pitch * mode.vdisplay);
    defer dev.destroyBo(bo);
    const target: triangle.Target = .{ .bo = bo, .width = mode.hdisplay, .height = mode.vdisplay };

    const tri = try triangle.Triangle.init(dev);
    defer tri.deinit(dev);
    try tri.draw(dev, target, 0xff101830);
    print("stardust: rendered frame\n", .{});

    const fb_id = try drm.addFramebuffer(fd, bo.handle, mode.hdisplay, mode.vdisplay, pitch, drm.format_xrgb8888);
    try drm.setCrtc(fd, output, fb_id);
    print("stardust: displaying triangle\n", .{});

    // Keep the framebuffer alive while it is on screen. When not running as
    // init, the kernel restores the previous display state once we exit.
    if (is_init) while (true) {
        _ = linux.pause();
    };
    sys.sleepMs(10_000);
}

test {
    _ = @import("qpu.zig");
    _ = @import("shaders.zig");
    _ = @import("vc4/cl.zig");
    _ = @import("drm.zig");
    _ = @import("vc4.zig");
    _ = @import("triangle.zig");
}
