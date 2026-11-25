//! Thin helpers over raw Linux system calls.
//!
//! Dazzle talks to the kernel directly through std.os.linux rather than
//! through a C library, so this module provides error mapping and a few
//! wrappers used throughout the program.
//!
//! * `network`: the network manager's protocol, shared by init, setup, settings and the shell
//! * `system`: the system manager's protocol, shared by init, setup and settings
//! * `media`: the media manager's protocol, shared by init and files
//! * `log`: reading the system log, shared by settings and the log server
//! * `apps`: reading and managing installed apps in /data/apps
//! * `gpio`, `i2c`, `serial`: Linux character device interfaces for the 40-pin header
//! * `shell`: the shell's IPC socket protocol (`/os/sockets/shell`)
//! * `files`: saving the user's files (numbered names, atomic writes)
//! * `archive`: tar and xz unpacking
//! * `v4l2`: Video4Linux2 ioctls for cameras and hardware video codecs
//! * `remote`: the remote control setting, written by settings and read by the shell

const std = @import("std");
const linux = std.os.linux;

pub const network = @import("network.zig");
pub const system = @import("system.zig");
pub const media = @import("media.zig");
pub const log = @import("log.zig");
pub const apps = @import("apps.zig");
pub const gpio = @import("gpio.zig");
pub const i2c = @import("i2c.zig");
pub const serial = @import("serial.zig");
pub const shell = @import("shell.zig");
pub const files = @import("files.zig");
pub const remote = @import("remote.zig");
pub const parental = @import("parental.zig");
pub const archive = @import("archive.zig");
pub const v4l2 = @import("v4l2.zig");
pub const evdev = @import("evdev.zig");

test {
    _ = network;
    _ = system;
    _ = media;
    _ = log;
    _ = apps;
    _ = gpio;
    _ = i2c;
    _ = serial;
    _ = shell;
    _ = files;
    _ = remote;
    _ = parental;
    _ = archive;
    _ = v4l2;
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
/// On 32-bit ARM this uses clock_nanosleep_time64, as Dazzle's time
/// functions use the 64-bit time syscalls (the 32-bit ones, which
/// std.os.linux uses there, are in the kernel only for the standard
/// library: see kernel/dazzle.config's CONFIG_COMPAT_32BIT_TIME).
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

/// Sleeps for `us` microseconds.
pub fn sleepUs(us: u32) void {
    sleepNs(@as(u64, us) * std.time.ns_per_us, false);
}

/// Sleeps until `ns` on the monotonic clock (see `nowNs`).
pub fn sleepUntil(ns: u64) void {
    sleepNs(ns, true);
}

fn sleepNs(ns: u64, absolute: bool) void {
    var ts: linux.kernel_timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    const sys_nr = if (@hasField(linux.SYS, "clock_nanosleep_time64"))
        linux.SYS.clock_nanosleep_time64
    else
        linux.SYS.clock_nanosleep;
    const flags: usize = if (absolute) 1 else 0; // TIMER_ABSTIME
    while (true) {
        const rc = linux.syscall4(sys_nr, @intFromEnum(linux.CLOCK.MONOTONIC), flags, @intFromPtr(&ts), if (absolute) 0 else @intFromPtr(&ts));
        if (linux.errno(rc) != .INTR) return;
    }
}

/// Nanoseconds on the monotonic clock. Like sleepMs, uses the 64-bit time
/// syscall on 32-bit targets.
pub fn nowNs() u64 {
    const ts = clockTime(.MONOTONIC);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// The time of day: seconds since 1970 (counting from 1970 at boot until
/// the network manager sets the clock).
pub fn realtimeSec() i64 {
    return clockTime(.REALTIME).sec;
}

/// The time of day, in nanoseconds since 1970.
pub fn realtimeNs() i128 {
    const ts = clockTime(.REALTIME);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Sets the time of day, to `ns` nanoseconds since 1970 (CAP_SYS_TIME).
pub fn setRealtimeNs(ns: i128) Error!void {
    const ts: linux.kernel_timespec = .{ .sec = @intCast(@divFloor(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
    const sys_nr = if (@hasField(linux.SYS, "clock_settime64"))
        linux.SYS.clock_settime64
    else
        linux.SYS.clock_settime;
    _ = try check(linux.syscall2(sys_nr, @intFromEnum(linux.CLOCK.REALTIME), @intFromPtr(&ts)));
}

/// Sets a file's access and modification times to `sec`.`nsec` (since
/// 1970): the file open as `fd` if `path` is null, otherwise `path`
/// (relative to `fd`, which may be AT.FDCWD).
pub fn setFileTimes(fd: linux.fd_t, path: ?[*:0]const u8, sec: i64, nsec: i64) Error!void {
    const times = [2]linux.kernel_timespec{ .{ .sec = sec, .nsec = nsec }, .{ .sec = sec, .nsec = nsec } };
    const sys_nr = if (@hasField(linux.SYS, "utimensat_time64"))
        linux.SYS.utimensat_time64
    else
        linux.SYS.utimensat;
    _ = try check(linux.syscall4(sys_nr, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(path), @intFromPtr(&times), 0));
}

/// A clock's time, by the 64-bit time syscall on 32-bit targets (the
/// kernel has no other: see sleepMs).
fn clockTime(clock: linux.CLOCK) linux.kernel_timespec {
    var ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 };
    const sys_nr = if (@hasField(linux.SYS, "clock_gettime64"))
        linux.SYS.clock_gettime64
    else
        linux.SYS.clock_gettime;
    _ = linux.syscall2(sys_nr, @intFromEnum(clock), @intFromPtr(&ts));
    return ts;
}

test "the time of day, and setting a file's times" {
    // Some time after this was written.
    try std.testing.expect(realtimeSec() > 1_700_000_000);
    try std.testing.expect(@divFloor(realtimeNs(), std.time.ns_per_s) >= realtimeSec() - 1);
    const name = "/tmp/dazzle-sys-times-test";
    const fd = try open(name, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
    defer {
        close(fd);
        _ = linux.unlink(name);
    }
    try setFileTimes(fd, null, 1_000_000_000, 5);
    var st: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MTIME = true }, &st));
    try std.testing.expectEqual(@as(i64, 1_000_000_000), st.mtime.sec);
    try setFileTimes(linux.AT.FDCWD, name, 2_000_000_000, 0);
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MTIME = true }, &st));
    try std.testing.expectEqual(@as(i64, 2_000_000_000), st.mtime.sec);
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

/// Log levels, as the kernel log has them: start a message with one to
/// log it at that level (`print(sys.log_warning ++ "...", ...)`), so the
/// log's readers (Settings) can pick out what went wrong. Without one, a
/// message is a notice.
pub const log_error = "<3>";
pub const log_warning = "<4>";
pub const log_notice = "<5>";

/// Writes formatted text to the kernel log if `logToKmsg` was called,
/// otherwise to stderr (without the level).
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const level = comptime logLevel(fmt);
    const text = fmt[level.len..];
    var buf: [512]u8 = undefined;
    const prefix = if (level.len > 0) level else log_notice;
    @memcpy(buf[0..prefix.len], prefix);
    const msg = std.fmt.bufPrint(buf[prefix.len..], text, args) catch blk: {
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

/// The level a message starts with ("<3>" and so on), if any.
fn logLevel(comptime fmt: []const u8) []const u8 {
    if (fmt.len >= 3 and fmt[0] == '<' and std.ascii.isDigit(fmt[1]) and fmt[2] == '>') return fmt[0..3];
    return "";
}

test "a message's level is what it starts with, else a notice" {
    try std.testing.expectEqualStrings("<3>", comptime logLevel(log_error ++ "dazzle-files: error: {s}\n"));
    try std.testing.expectEqualStrings("<4>", comptime logLevel(log_warning ++ "dazzle: cannot mount {s}\n"));
    // Words in a message do not make it one (nothing is guessed).
    try std.testing.expectEqualStrings("", comptime logLevel("dazzle: system: fork failed ({s})\n"));
    try std.testing.expectEqualStrings("", comptime logLevel("dazzle: mounted {s} at {s}\n"));
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
    kill = 5,
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

/// Memory, in bytes: the system's, and the contiguous pool (CMA) the GPU's
/// buffers come from.
pub const Meminfo = struct { total: u64 = 0, available: u64 = 0, cma_total: u64 = 0, cma_free: u64 = 0 };

/// /proc/meminfo's figures, in bytes.
pub fn parseMeminfo(text: []const u8) Meminfo {
    var out: Meminfo = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        const kb = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        const key = line[0..colon];
        const field: ?*u64 = if (std.mem.eql(u8, key, "MemTotal")) &out.total else if (std.mem.eql(u8, key, "MemAvailable")) &out.available else if (std.mem.eql(u8, key, "CmaTotal")) &out.cma_total else if (std.mem.eql(u8, key, "CmaFree")) &out.cma_free else null;
        if (field) |f| f.* = kb * 1024;
    }
    return out;
}

/// /proc/meminfo's figures now, or null if it cannot be read.
pub fn meminfo() ?Meminfo {
    var buf: [4096]u8 = undefined;
    return parseMeminfo(readFile("/proc/meminfo", &buf) orelse return null);
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
    const shared = std.mem.printSentinel(buf, "{s}/{s}", .{ fonts_dir, name }, 0) catch return fonts_dir;
    if (linux.errno(linux.access(shared, linux.F_OK)) == .SUCCESS) return shared;
    return appFile(buf, name) catch shared;
}

/// The path of a file in the running program's own directory. Each app
/// lives in a directory of its own with the assets it needs (besides the
/// shared fonts in /os/fonts).
pub fn appFile(buf: []u8, name: []const u8) ![:0]const u8 {
    var exe: [512]u8 = undefined;
    const n = try check(linux.readlink("/proc/self/exe", &exe, exe.len));
    const dir = std.fs.path.dirname(exe[0..n]) orelse "/";
    return std.mem.printSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch error.OutOfMemory;
}
