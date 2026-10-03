//! Thin helpers over raw Linux system calls.
//!
//! Stardust talks to the kernel directly through std.os.linux rather than
//! through a C library, so this module provides error mapping and a few
//! wrappers used throughout the program.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    AccessDenied,
    NoDevice,
    NotFound,
    InvalidArgument,
    OutOfMemory,
    Busy,
    TimedOut,
    Unexpected,
};

pub fn errorFromErrno(e: linux.E) Error {
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NODEV, .NXIO => error.NoDevice,
        .NOENT => error.NotFound,
        .INVAL => error.InvalidArgument,
        .NOMEM, .NOSPC => error.OutOfMemory,
        .BUSY => error.Busy,
        .TIME, .TIMEDOUT => error.TimedOut,
        else => error.Unexpected,
    };
}

/// Converts a raw syscall return value into an error union.
pub fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => |e| errorFromErrno(e),
    };
}

pub fn open(path: [*:0]const u8, flags: linux.O) Error!linux.fd_t {
    return @intCast(try check(linux.open(path, flags, 0)));
}

pub fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

/// Sleeps on the monotonic clock.
///
/// On 32-bit ARM this uses clock_nanosleep_time64: the Stardust kernel is
/// built without CONFIG_COMPAT_32BIT_TIME, so the older 32-bit time
/// syscalls (nanosleep, clock_nanosleep) that std.os.linux uses there fail
/// with ENOSYS.
pub fn sleepMs(ms: u32) void {
    var ts: linux.kernel_timespec = .{
        .sec = ms / 1000,
        .nsec = @as(i64, ms % 1000) * std.time.ns_per_ms,
    };
    const sys_nr = if (@hasField(linux.SYS, "clock_nanosleep_time64"))
        linux.SYS.clock_nanosleep_time64
    else
        linux.SYS.clock_nanosleep;
    while (true) {
        const rc = linux.syscall4(sys_nr, @intFromEnum(linux.CLOCK.MONOTONIC), 0, @intFromPtr(&ts), @intFromPtr(&ts));
        if (linux.errno(rc) != .INTR) return;
    }
}

var kmsg_fd: ?linux.fd_t = null;

/// Sends `print` output to the kernel log (/dev/kmsg) instead of stderr.
/// The kernel still echoes it to the console, and the log server can then
/// serve init's messages together with the kernel's.
pub fn logToKmsg() void {
    kmsg_fd = open("/dev/kmsg", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }) catch null;
}

/// Writes formatted text to the kernel log if `logToKmsg` was called,
/// otherwise to stderr.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    // "<5>" is the notice log level; it is ignored when writing to stderr.
    const prefix = "<5>";
    @memcpy(buf[0..prefix.len], prefix);
    const msg = std.fmt.bufPrint(buf[prefix.len..], fmt, args) catch blk: {
        const trunc = "...(truncated)\n";
        @memcpy(buf[buf.len - trunc.len ..], trunc);
        break :blk buf[prefix.len..];
    };
    if (kmsg_fd) |fd| {
        // Each write to /dev/kmsg is one log record.
        _ = linux.write(fd, &buf, prefix.len + msg.len);
        return;
    }
    var rest: []const u8 = msg;
    while (rest.len > 0) {
        const rc = linux.write(2, rest.ptr, rest.len);
        if (linux.errno(rc) != .SUCCESS) return;
        rest = rest[rc..];
    }
}
