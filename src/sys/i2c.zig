//! I2C: reading and writing devices on an I2C bus through the kernel's
//! i2c-dev (/dev/i2c-N). Dazzle turns on the bus on the GPIO header (pins 3
//! and 5, GPIO 2 and 3: config.txt's i2c_arm); `headerBus` finds its
//! number.
//!
//! Each transfer is one combined transaction (I2C_RDWR): a register's
//! number written, then its value read, with a repeated start between.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const I2C_RDWR = 0x0707;
const M_RD: u16 = 0x0001;

const Msg = extern struct {
    addr: u16,
    flags: u16,
    len: u16,
    buf: [*]u8,
};

const RdwrData = extern struct {
    msgs: [*]Msg,
    nmsgs: u32,
};

pub const Error = error{
    /// Nothing answered at the address.
    NoDevice,
    AccessDenied,
    Unexpected,
};

/// The bus's number on the header: the BCM283x's I2C controller at
/// 0x7e804000 ("i2c1"); 1 if it cannot be told.
pub fn headerBus() u8 {
    var buf: [128]u8 = undefined;
    var path_buf: [64]u8 = undefined;
    for (0..8) |n| {
        const path = std.mem.printSentinel(&path_buf, "/sys/class/i2c-dev/i2c-{d}/device/of_node", .{n}, 0) catch continue;
        const rc = linux.readlink(path, &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS) continue;
        if (std.mem.indexOf(u8, buf[0..rc], "7e804000") != null) return @intCast(n);
    }
    return 1;
}

pub const Bus = struct {
    fd: linux.fd_t,

    pub fn open(number: u8) !Bus {
        var buf: [32]u8 = undefined;
        const path = std.mem.printSentinel(&buf, "/dev/i2c-{d}", .{number}, 0) catch unreachable;
        return .{ .fd = try sys.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) };
    }

    pub fn close(b: *Bus) void {
        sys.close(b.fd);
    }

    fn transfer(b: *const Bus, msgs: []Msg) Error!void {
        var data: RdwrData = .{ .msgs = msgs.ptr, .nmsgs = @intCast(msgs.len) };
        return switch (linux.errno(linux.ioctl(b.fd, I2C_RDWR, @intFromPtr(&data)))) {
            .SUCCESS => {},
            .NXIO, .REMOTEIO, .IO, .TIMEDOUT => error.NoDevice,
            .ACCES, .PERM => error.AccessDenied,
            else => error.Unexpected,
        };
    }

    /// Writes `bytes` to the device at `addr`.
    pub fn write(b: *const Bus, addr: u7, bytes: []const u8) Error!void {
        var msgs = [_]Msg{.{ .addr = addr, .flags = 0, .len = @intCast(bytes.len), .buf = @constCast(bytes.ptr) }};
        return b.transfer(&msgs);
    }

    /// Reads `out.len` bytes from the device at `addr`.
    pub fn read(b: *const Bus, addr: u7, out: []u8) Error!void {
        var msgs = [_]Msg{.{ .addr = addr, .flags = M_RD, .len = @intCast(out.len), .buf = out.ptr }};
        return b.transfer(&msgs);
    }

    /// Reads `out.len` bytes from register `reg` of the device at `addr`.
    pub fn readRegister(b: *const Bus, addr: u7, reg: u8, out: []u8) Error!void {
        var r = [1]u8{reg};
        var msgs = [_]Msg{
            .{ .addr = addr, .flags = 0, .len = 1, .buf = &r },
            .{ .addr = addr, .flags = M_RD, .len = @intCast(out.len), .buf = out.ptr },
        };
        return b.transfer(&msgs);
    }
};

test "the kernel's structures" {
    // struct i2c_msg: three u16s, then a pointer (8 bytes on 32-bit ARM).
    try std.testing.expectEqual(2 * @sizeOf(usize), @sizeOf(Msg));
}
