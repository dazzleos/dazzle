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

/// Nanoseconds on the monotonic clock. Like sleepMs, uses the 64-bit time
/// syscall on 32-bit targets.
pub fn nowNs() u64 {
    var ts: linux.kernel_timespec = undefined;
    const sys_nr = if (@hasField(linux.SYS, "clock_gettime64"))
        linux.SYS.clock_gettime64
    else
        linux.SYS.clock_gettime;
    _ = linux.syscall2(sys_nr, @intFromEnum(linux.CLOCK.MONOTONIC), @intFromPtr(&ts));
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Reads the kernel command line into `buf`.
pub fn readCmdline(buf: []u8) []const u8 {
    const fd = open("/proc/cmdline", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return "";
    defer close(fd);
    const n = check(linux.read(fd, buf.ptr, buf.len)) catch return "";
    return buf[0..n];
}

/// The value of `key=value` on a kernel command line, if present.
pub fn cmdlineValue(cmdline: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, cmdline, " \t\n");
    while (it.next()) |arg| {
        if (arg.len > key.len and std.mem.startsWith(u8, arg, key) and arg[key.len] == '=')
            return arg[key.len + 1 ..];
    }
    return null;
}

test "cmdline values" {
    const c = "console=ttyAMA0 stardust.demo=spin stardust.httpport=8080\n";
    try std.testing.expectEqualStrings("spin", cmdlineValue(c, "stardust.demo").?);
    try std.testing.expectEqualStrings("8080", cmdlineValue(c, "stardust.httpport").?);
    try std.testing.expectEqual(@as(?[]const u8, null), cmdlineValue(c, "stardust"));
}

var kmsg_fd: ?linux.fd_t = null;

/// Sends `print` output to the kernel log (/dev/kmsg) instead of stderr.
/// The kernel still echoes it to the console, and the log server can then
/// serve init's messages together with the kernel's.
pub fn logToKmsg() void {
    kmsg_fd = open("/dev/kmsg", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }) catch null;
}

/// The kernel log descriptor `print` writes to, if any.
pub fn kmsgFd() ?linux.fd_t {
    return kmsg_fd;
}

/// Sends `print` output to the kernel log if stderr is /dev/kmsg, as it is
/// for programs started by init. (Opening /dev/kmsg for writing needs root;
/// an inherited descriptor does not.)
pub fn logToKmsgIfStderr() void {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(2, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return;
    // /dev/kmsg is character device 1:11.
    if (stx.mode & linux.S.IFMT == linux.S.IFCHR and stx.rdev_major == 1 and stx.rdev_minor == 11) kmsg_fd = 2;
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

/// Stardust has a single user, which everything but init runs as.
pub const user = struct {
    pub const uid: linux.uid_t = 1000;
    pub const gid: linux.gid_t = 1000;
    pub const name = "stardust";
};

/// Switches a root process to the user: no supplementary groups, then the
/// group, then the user ID (after which the others cannot be changed).
pub fn dropPrivileges() Error!void {
    return dropPrivilegesKeeping(&.{});
}

/// Capabilities (see capability.h) a process can keep when it drops to the
/// user.
pub const Capability = enum(u5) {
    chown = 0,
    net_bind_service = 10,
    net_admin = 12,
    net_raw = 13,
};

/// Like `dropPrivileges`, but keeps the given capabilities and no others.
pub fn dropPrivilegesKeeping(caps: []const Capability) Error!void {
    const pr_set_keepcaps = 8;
    if (caps.len > 0) _ = try check(linux.prctl(pr_set_keepcaps, 1, 0, 0, 0));
    const no_groups = [_]linux.gid_t{};
    _ = try check(linux.setgroups(0, &no_groups));
    _ = try check(linux.setgid(user.gid));
    _ = try check(linux.setuid(user.uid));
    // Without CONFIG_MULTIUSER the calls above are not even available;
    // make sure the switch really happened.
    if (linux.getuid() != user.uid or linux.geteuid() != user.uid) return error.Unexpected;
    if (caps.len == 0) return;

    // Keep only the wanted capabilities, and make them effective (changing
    // user clears the effective set).
    var mask: u32 = 0;
    for (caps) |c| mask |= @as(u32, 1) << @intFromEnum(c);
    const Header = extern struct { version: u32, pid: i32 };
    const Data = extern struct { effective: u32, permitted: u32, inheritable: u32 };
    var header: Header = .{ .version = 0x20080522, .pid = 0 }; // _LINUX_CAPABILITY_VERSION_3
    const data = [2]Data{ .{ .effective = mask, .permitted = mask, .inheritable = 0 }, .{ .effective = 0, .permitted = 0, .inheritable = 0 } };
    _ = try check(linux.syscall2(.capset, @intFromPtr(&header), @intFromPtr(&data)));
}

/// Reads a small file (such as a sysfs attribute) into `buf`. Returns null
/// if it cannot be read.
pub fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return null;
    defer close(fd);
    const n = check(linux.read(fd, buf.ptr, buf.len)) catch return null;
    return buf[0..n];
}

/// Reads a whole file into memory from `gpa`.
pub fn readFileAlloc(gpa: std.mem.Allocator, path: [*:0]const u8, max_size: usize) ![]u8 {
    const fd = try open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer close(fd);
    var stx: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx));
    if (stx.size > max_size) return error.OutOfMemory;
    const buf = try gpa.alloc(u8, @intCast(stx.size));
    errdefer gpa.free(buf);
    var at: usize = 0;
    while (at < buf.len) {
        const n = try check(linux.read(fd, buf[at..].ptr, buf.len - at));
        if (n == 0) return error.Unexpected;
        at += n;
    }
    return buf;
}

/// The path of a file in the running program's own directory. Each app
/// lives in a directory of its own with everything it needs (the system
/// provides no shared files).
pub fn appFile(buf: []u8, name: []const u8) ![:0]const u8 {
    var exe: [512]u8 = undefined;
    const n = try check(linux.readlink("/proc/self/exe", &exe, exe.len));
    const dir = std.fs.path.dirname(exe[0..n]) orelse "/";
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch error.OutOfMemory;
}
