//! The device manager: hands input devices, the camera, audio, the GPIO,
//! I2C and serial ports to the Dazzle user.
//!
//! The kernel creates /dev/input/eventN (one per keyboard, mouse or other
//! input device) owned by root, so the unprivileged shell could not read
//! them; likewise the camera's nodes (/dev/videoN, /dev/v4l-subdevN,
//! /dev/mediaN), which the Camera app uses, the ALSA audio nodes
//! (/dev/snd/controlCN, /dev/snd/pcmCNDNp, /dev/snd/pcmCNDNc,
//! /dev/snd/timer), which Settings and media playback use, the GPIO's
//! (/dev/gpiochipN, and /dev/gpiomem, its registers), which Settings uses,
//! and the I2C buses and serial ports (/dev/i2c-N, /dev/ttyUSBN,
//! /dev/ttyACMN and the header's UART), which the Data Logger reads. Init
//! forks this process, which drops to the user keeping only CAP_CHOWN,
//! gives the user every such node there already is, and then does the same
//! for each one that comes later (plugged in, or probed late), as the
//! kernel announces it with a uevent.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const print = sys.print;

/// Starts the device manager. Returns its PID, or null if it could not be
/// started.
pub fn start() ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print(sys.log_error ++ "dazzle: devices: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    sys.dropPrivilegesKeeping(&.{.chown}) catch |err| {
        print(sys.log_warning ++ "dazzle: devices: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    run() catch |err| print("dazzle: devices: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

fn run() !void {
    // Listen first, so no device is missed between the scan and the loop.
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, linux.NETLINK.KOBJECT_UEVENT)));
    var addr: linux.sockaddr.nl = .{ .pid = 0, .groups = 1 };
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)));

    var name_buf: [32]u8 = undefined;
    for (user_devices) |prefix| for (0..max_scanned) |n| {
        const name = std.fmt.bufPrint(&name_buf, "{s}{d}", .{ prefix, n }) catch continue;
        grant(name, false);
    };
    for (0..8) |card| for (0..4) |dev| for ([_]u8{ 'p', 'c' }) |dir| {
        const name = std.fmt.bufPrint(&name_buf, "snd/pcmC{d}D{d}{c}", .{ card, dev, dir }) catch continue;
        grant(name, false);
    };
    for (single_devices) |name| grant(name, false);

    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (linux.errno(rc) != .SUCCESS) continue;
        if (userDevice(buf[0..rc])) |name| grant(name, true);
    }
}

/// Nodes of each kind looked for at start; the kernel numbers them from 0.
const max_scanned = 32;

/// The device nodes the user gets (relative to /dev, without their
/// numbers): input events, the camera's, GPIO, I2C, serial and audio.
const user_devices = [_][]const u8{ "input/event", "video", "v4l-subdev", "media", "gpiochip", "gpiomem", "i2c-", "ttyUSB", "ttyACM", "ttyAMA", "ttyS", "snd/controlC" };

/// Device nodes the user gets that are not numbered.
const single_devices = [_][]const u8{ "gpiomem", "snd/timer" };

/// Whether `devname` is an ALSA PCM node (`snd/pcmC<card>D<dev><p|c>`).
fn isSndPcm(devname: []const u8) bool {
    if (!std.mem.startsWith(u8, devname, "snd/pcmC")) return false;
    const rest = devname["snd/pcmC".len..];
    if (rest.len < 4) return false;
    const stream = rest[rest.len - 1];
    if (stream != 'p' and stream != 'c') return false;
    const mid = rest[0 .. rest.len - 1];
    const d_pos = std.mem.indexOfScalar(u8, mid, 'D') orelse return false;
    if (d_pos == 0 or d_pos + 1 >= mid.len) return false;
    for (mid[0..d_pos]) |c| if (!std.ascii.isDigit(c)) return false;
    for (mid[d_pos + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The device node (relative to /dev) a uevent adds, if it is one the
/// user gets.
fn userDevice(msg: []const u8) ?[]const u8 {
    var action: []const u8 = "";
    var devname: []const u8 = "";
    var fields = std.mem.splitScalar(u8, msg, 0);
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "ACTION=")) action = field["ACTION=".len..];
        if (std.mem.startsWith(u8, field, "DEVNAME=")) devname = field["DEVNAME=".len..];
    }
    if (!std.mem.eql(u8, action, "add")) return null;
    for (single_devices) |name| if (std.mem.eql(u8, devname, name)) return devname;
    if (isSndPcm(devname)) return devname;
    for (user_devices) |prefix| {
        if (devname.len > prefix.len and std.mem.startsWith(u8, devname, prefix) and std.ascii.isDigit(devname[prefix.len])) return devname;
    }
    return null;
}

/// Gives the user the device node /dev/`name`.
fn grant(name: []const u8, log: bool) void {
    var path_buf: [64]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/dev/{s}", .{name}, 0) catch return;
    // devtmpfs creates the node before the uevent goes out, but be lenient.
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const err = linux.errno(linux.chown(path.ptr, sys.user.uid, sys.user.gid));
        if (err == .SUCCESS) break;
        if (err != .NOENT or !log or attempt == 10) {
            if (log or err != .NOENT) print(sys.log_warning ++ "dazzle: devices: cannot chown {s} ({s})\n", .{ path, @tagName(err) });
            return;
        }
        sys.sleepMs(10);
    }
    if (log) print("dazzle: devices: {s} is the user's\n", .{path});
}

test "the camera's and audio uevents" {
    const video = "add@/devices/platform/soc/20801000.csi/video4linux/video0\x00ACTION=add\x00SUBSYSTEM=video4linux\x00DEVNAME=video0\x00SEQNUM=900\x00";
    try std.testing.expectEqualStrings("video0", userDevice(video).?);
    const subdev = "add@/devices/x\x00ACTION=add\x00DEVNAME=v4l-subdev1\x00";
    try std.testing.expectEqualStrings("v4l-subdev1", userDevice(subdev).?);
    const media = "add@/devices/x\x00ACTION=add\x00DEVNAME=media0\x00";
    try std.testing.expectEqualStrings("media0", userDevice(media).?);
    try std.testing.expectEqualStrings("gpiochip0", userDevice("add@/x\x00ACTION=add\x00DEVNAME=gpiochip0\x00").?);
    try std.testing.expectEqualStrings("i2c-1", userDevice("add@/x\x00ACTION=add\x00DEVNAME=i2c-1\x00").?);
    try std.testing.expectEqualStrings("ttyUSB0", userDevice("add@/x\x00ACTION=add\x00DEVNAME=ttyUSB0\x00").?);
    try std.testing.expect(userDevice("add@/x\x00ACTION=add\x00DEVNAME=tty1\x00") == null);
    try std.testing.expectEqualStrings("gpiomem", userDevice("add@/x\x00ACTION=add\x00DEVNAME=gpiomem\x00").?);
    try std.testing.expectEqualStrings("snd/controlC0", userDevice("add@/x\x00ACTION=add\x00DEVNAME=snd/controlC0\x00").?);
    try std.testing.expectEqualStrings("snd/pcmC0D0p", userDevice("add@/x\x00ACTION=add\x00DEVNAME=snd/pcmC0D0p\x00").?);
    try std.testing.expectEqualStrings("snd/pcmC1D0c", userDevice("add@/x\x00ACTION=add\x00DEVNAME=snd/pcmC1D0c\x00").?);
    try std.testing.expectEqualStrings("snd/timer", userDevice("add@/x\x00ACTION=add\x00DEVNAME=snd/timer\x00").?);
    try std.testing.expect(userDevice("add@/x\x00ACTION=add\x00DEVNAME=snd/seq\x00") == null);
    // Not "videofoo", nor others.
    try std.testing.expect(userDevice("add@/x\x00ACTION=add\x00DEVNAME=videofoo\x00") == null);
    try std.testing.expect(userDevice("add@/x\x00ACTION=add\x00DEVNAME=mmcblk0\x00") == null);
}

test "input uevents" {
    const add = "add@/devices/platform/soc/20980000.usb/usb1/1-1/1-1:1.0/0003:046D:C077.0001/input/input0/event0\x00ACTION=add\x00DEVPATH=/devices/x/input/input0/event0\x00SUBSYSTEM=input\x00MAJOR=13\x00MINOR=64\x00DEVNAME=input/event0\x00SEQNUM=812\x00";
    try std.testing.expectEqualStrings("input/event0", userDevice(add).?);
    const parent = "add@/devices/x/input/input0\x00ACTION=add\x00SUBSYSTEM=input\x00PRODUCT=3/46d/c077/111\x00";
    try std.testing.expect(userDevice(parent) == null);
    const remove = "remove@/devices/x/event0\x00ACTION=remove\x00DEVNAME=input/event0\x00";
    try std.testing.expect(userDevice(remove) == null);
    const drm = "add@/devices/x\x00ACTION=add\x00DEVNAME=dri/card0\x00";
    try std.testing.expect(userDevice(drm) == null);
}
