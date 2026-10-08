//! Thin helpers over raw Linux system calls.
//!
//! Dazzle talks to the kernel directly through std.os.linux rather than
//! through a C library, so this module provides error mapping and a few
//! wrappers used throughout the program.
//!
//! * `network`: the network manager's protocol, shared by init and settings
//! * `system`: the system manager's protocol, shared by init and setup
//! * `media`: the media manager's protocol, shared by init and files
//! * `files`: saving the user's files (numbered names, new files)

const std = @import("std");
const linux = std.os.linux;

pub const network = @import("network.zig");
pub const system = @import("system.zig");
pub const media = @import("media.zig");
pub const log = @import("log.zig");
pub const files = @import("files.zig");
pub const archive = @import("archive.zig");

test {
    _ = network;
    _ = system;
    _ = media;
    _ = log;
    _ = files;
    _ = archive;
}

pub const Error = error{
    AccessDenied,
    NoDevice,
    NotFound,
    InvalidArgument,
    OutOfMemory,
    Busy,
    TimedOut,
    /// Something of that name is there already.
    Exists,
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
        .EXIST => error.Exists,
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
/// On 32-bit ARM this uses clock_nanosleep_time64: the Dazzle kernel is
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
    // The log level ("<5>": notice), which is ignored when writing to
    // stderr. What says something failed is a warning or an error, so the
    // log's readers (Settings) can pick those out.
    const prefix = comptime levelPrefix(fmt);
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

/// The log level a message is written at, from what it says: "error:"
/// or "failed" an error, "cannot" a warning, else a notice.
fn levelPrefix(comptime fmt: []const u8) []const u8 {
    @setEvalBranchQuota(20 * fmt.len + 1000);
    if (std.mem.indexOf(u8, fmt, "error:") != null or std.mem.indexOf(u8, fmt, " failed") != null) return "<3>";
    if (std.mem.indexOf(u8, fmt, "cannot ") != null) return "<4>";
    return "<5>";
}

test "messages that say something failed are warnings or errors" {
    try std.testing.expectEqualStrings("<3>", comptime levelPrefix("dazzle-files: error: {s}\n"));
    try std.testing.expectEqualStrings("<3>", comptime levelPrefix("dazzle: system: fork failed ({s})\n"));
    try std.testing.expectEqualStrings("<4>", comptime levelPrefix("dazzle: cannot mount {s}\n"));
    try std.testing.expectEqualStrings("<5>", comptime levelPrefix("dazzle: mounted {s} at {s}\n"));
}

/// Dazzle has a single user, which everything but init runs as.
pub const user = struct {
    pub const uid: linux.uid_t = 1000;
    pub const gid: linux.gid_t = 1000;
    pub const name = "dazzle";
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
    dac_override = 1,
    dac_read_search = 2,
    net_bind_service = 10,
    net_admin = 12,
    net_raw = 13,
    sys_admin = 21,
    sys_boot = 22,
    sys_time = 25,
};

/// For a server: a client that hangs up before it has its answer must not
/// stop the server (writing to its socket then raises SIGPIPE, which would).
pub fn ignoreBrokenPipes() void {
    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &ignore, null);
}

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

/// The space on the filesystem holding `path`, in bytes, and its type.
pub const DiskSpace = struct { kind: u32, total: u64, free: u64 };

pub fn diskSpace(path: [*:0]const u8) ?DiskSpace {
    if (@sizeOf(usize) == 4) {
        // struct statfs64, as 32-bit ARM packs it (84 bytes).
        const Statfs64 = extern struct { kind: u32, bsize: u32, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64, fsid: [2]i32, namelen: u32, frsize: u32, flags: u32, spare: [4]u32 };
        var st: Statfs64 = undefined;
        _ = check(linux.syscall3(.statfs64, @intFromPtr(path), 84, @intFromPtr(&st))) catch return null;
        return .{ .kind = st.kind, .total = st.blocks * st.bsize, .free = st.bavail * st.bsize };
    }
    // struct statfs, with words for most fields.
    const Statfs = extern struct { kind: isize, bsize: isize, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64, fsid: [2]i32, namelen: isize, frsize: isize, flags: isize, spare: [4]isize };
    var st: Statfs = undefined;
    _ = check(linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&st))) catch return null;
    const bsize: u64 = @intCast(st.bsize);
    return .{ .kind = @truncate(@as(usize, @bitCast(st.kind))), .total = st.blocks * bsize, .free = st.bavail * bsize };
}

test "disk space" {
    const root = diskSpace("/").?;
    try std.testing.expect(root.total > 0 and root.free <= root.total);
    try std.testing.expect(diskSpace("/nonexistent") == null);
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

/// Where Dazzle's fonts are, shared by every program.
pub const fonts_dir = "/os/fonts";

/// The path of the font file `name`: in /os/fonts, or (run elsewhere, as on
/// Raspberry Pi OS) beside the running program.
pub fn fontFile(buf: []u8, name: []const u8) [:0]const u8 {
    const shared = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ fonts_dir, name }) catch return fonts_dir;
    if (linux.errno(linux.access(shared, linux.F_OK)) == .SUCCESS) return shared;
    return appFile(buf, name) catch shared;
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
