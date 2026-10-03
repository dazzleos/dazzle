//! The device manager: hands input devices to the Stardust user.
//!
//! The kernel creates /dev/input/eventN (one per keyboard, mouse or other
//! input device) owned by root, so the unprivileged shell could not read
//! them. Init forks this process, which drops to the user keeping only
//! CAP_CHOWN, gives the user every event node there already is, and then
//! does the same for each one plugged in later, as the kernel announces it
//! with a uevent.

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
            print("stardust: devices: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    sys.dropPrivilegesKeeping(&.{.chown}) catch |err| {
        print("stardust: devices: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    run() catch |err| print("stardust: devices: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

fn run() !void {
    // Listen first, so no device is missed between the scan and the loop.
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, linux.NETLINK.KOBJECT_UEVENT)));
    var addr: linux.sockaddr.nl = .{ .pid = 0, .groups = 1 };
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)));

    var name_buf: [32]u8 = undefined;
    for (0..max_scanned) |n| {
        const name = std.fmt.bufPrint(&name_buf, "input/event{d}", .{n}) catch continue;
        grant(name, false);
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (linux.errno(rc) != .SUCCESS) continue;
        if (inputDevice(buf[0..rc])) |name| grant(name, true);
    }
}

/// Event nodes looked for at start; the kernel numbers them from 0.
const max_scanned = 32;

/// The device node (relative to /dev) a uevent adds, if it is an input
/// event node.
fn inputDevice(msg: []const u8) ?[]const u8 {
    var action: []const u8 = "";
    var devname: []const u8 = "";
    var fields = std.mem.splitScalar(u8, msg, 0);
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "ACTION=")) action = field["ACTION=".len..];
        if (std.mem.startsWith(u8, field, "DEVNAME=")) devname = field["DEVNAME=".len..];
    }
    if (!std.mem.eql(u8, action, "add") or !std.mem.startsWith(u8, devname, "input/event")) return null;
    return devname;
}

/// Gives the user the device node /dev/`name`.
fn grant(name: []const u8, log: bool) void {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/dev/{s}", .{name}) catch return;
    // devtmpfs creates the node before the uevent goes out, but be lenient.
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const err = linux.errno(linux.chown(path.ptr, sys.user.uid, sys.user.gid));
        if (err == .SUCCESS) break;
        if (err != .NOENT or !log or attempt == 10) {
            if (log or err != .NOENT) print("stardust: devices: cannot chown {s} ({s})\n", .{ path, @tagName(err) });
            return;
        }
        sys.sleepMs(10);
    }
    if (log) print("stardust: devices: {s} is the user's\n", .{path});
}

test "input uevents" {
    const add = "add@/devices/platform/soc/20980000.usb/usb1/1-1/1-1:1.0/0003:046D:C077.0001/input/input0/event0\x00ACTION=add\x00DEVPATH=/devices/x/input/input0/event0\x00SUBSYSTEM=input\x00MAJOR=13\x00MINOR=64\x00DEVNAME=input/event0\x00SEQNUM=812\x00";
    try std.testing.expectEqualStrings("input/event0", inputDevice(add).?);
    const parent = "add@/devices/x/input/input0\x00ACTION=add\x00SUBSYSTEM=input\x00PRODUCT=3/46d/c077/111\x00";
    try std.testing.expect(inputDevice(parent) == null);
    const remove = "remove@/devices/x/event0\x00ACTION=remove\x00DEVNAME=input/event0\x00";
    try std.testing.expect(inputDevice(remove) == null);
    const drm = "add@/devices/x\x00ACTION=add\x00DEVNAME=dri/card0\x00";
    try std.testing.expect(inputDevice(drm) == null);
}
