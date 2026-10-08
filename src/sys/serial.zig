//! Serial ports: USB serial adapters (/dev/ttyUSBN, /dev/ttyACMN) and the
//! UART on the GPIO header (pins 8 and 10, GPIO 14 and 15: /dev/ttyAMA0,
//! or /dev/ttyS0, the mini UART, on the boards with Bluetooth; the kernel's
//! console writes there too). A port is opened raw (no line editing or
//! echo), 8 data bits, no parity, one stop bit, at any speed (termios2).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The ports there are, by device name ("ttyUSB0").
pub const Ports = struct {
    names: [8][12]u8 = undefined,
    lens: [8]u8 = @splat(0),
    count: usize = 0,

    pub fn name(p: *const Ports, i: usize) []const u8 {
        return p.names[i][0..p.lens[i]];
    }

    fn add(p: *Ports, n: []const u8) void {
        if (p.count == p.names.len or n.len > 12) return;
        @memcpy(p.names[p.count][0..n.len], n);
        p.lens[p.count] = @intCast(n.len);
        p.count += 1;
    }
};

/// The header's UART device, and the adapters plugged in.
pub fn ports() Ports {
    var p: Ports = .{};
    var buf: [32]u8 = undefined;
    // The header's: the PL011 if it is on the header (not talking to
    // Bluetooth), else the mini UART. /proc/device-tree's aliases say.
    var alias_buf: [64]u8 = undefined;
    const serial0 = sys.readFile("/proc/device-tree/aliases/serial0", &alias_buf) orelse "";
    p.add(if (std.mem.indexOf(u8, serial0, "7e215040") != null) "ttyS0" else "ttyAMA0");
    for ([_][]const u8{ "ttyUSB", "ttyACM" }) |prefix| for (0..4) |n| {
        const dev = std.fmt.bufPrintZ(&buf, "/dev/{s}{d}", .{ prefix, n }) catch continue;
        if (linux.access(dev, linux.F_OK) == 0) p.add(dev["/dev/".len..]);
    };
    return p;
}

/// Whether the port is the header's UART.
pub fn isHeader(name: []const u8) bool {
    return std.mem.eql(u8, name, "ttyAMA0") or std.mem.eql(u8, name, "ttyS0");
}

const Termios2 = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [19]u8,
    ispeed: u32,
    ospeed: u32,
};

const TCGETS2 = linux.IOCTL.IOR('T', 0x2A, Termios2);
const TCSETS2 = linux.IOCTL.IOW('T', 0x2B, Termios2);
const CBAUD: u32 = 0o010017;
const BOTHER: u32 = 0o010000;
const CS8: u32 = 0o000060;
const CREAD: u32 = 0o000200;
const CLOCAL: u32 = 0o004000;
const VTIME = 5;
const VMIN = 6;

pub const Port = struct {
    fd: linux.fd_t,

    /// Opens /dev/`name` at `baud`, for reading without waiting.
    pub fn open(name: []const u8, baud: u32) !Port {
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buf, "/dev/{s}", .{name});
        const fd = try sys.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true, .CLOEXEC = true });
        errdefer sys.close(fd);
        var t: Termios2 = undefined;
        _ = try sys.check(linux.ioctl(fd, TCGETS2, @intFromPtr(&t)));
        t.iflag = 0;
        t.oflag = 0;
        t.lflag = 0;
        t.cflag = (t.cflag & ~(CBAUD | 0o000060 | 0o000400 | 0o000100)) | BOTHER | CS8 | CREAD | CLOCAL;
        t.ispeed = baud;
        t.ospeed = baud;
        t.cc[VMIN] = 0;
        t.cc[VTIME] = 0;
        _ = try sys.check(linux.ioctl(fd, TCSETS2, @intFromPtr(&t)));
        return .{ .fd = fd };
    }

    pub fn close(p: *Port) void {
        sys.close(p.fd);
    }

    /// What has come since (none: nothing yet).
    pub fn read(p: *const Port, out: []u8) usize {
        const rc = linux.read(p.fd, out.ptr, out.len);
        return if (linux.errno(rc) == .SUCCESS) rc else 0;
    }
};

test "termios2 is the kernel's" {
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(Termios2));
    try std.testing.expectEqual(@as(u32, 0x802c542a), TCGETS2);
    try std.testing.expectEqual(@as(u32, 0x402c542b), TCSETS2);
}
