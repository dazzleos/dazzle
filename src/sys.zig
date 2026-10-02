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

pub fn sleepMs(ms: u32) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

/// Writes formatted text to stderr (the serial console when running as
/// PID 1).
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        const trunc = "...(truncated)\n";
        @memcpy(buf[buf.len - trunc.len ..], trunc);
        break :blk &buf;
    };
    var rest: []const u8 = msg;
    while (rest.len > 0) {
        const rc = linux.write(2, rest.ptr, rest.len);
        if (linux.errno(rc) != .SUCCESS) return;
        rest = rest[rc..];
    }
}
