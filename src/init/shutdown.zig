//! Restarting and turning off, by init: every other process is stopped
//! (asked first, then made to), the card's filesystems are unmounted (or
//! at least made read-only), and only then is the computer restarted or
//! turned off. A filesystem left mounted is not clean: the next start
//! goes over its journal first, which on an SD card can take many
//! seconds (the boot screen says "Checking the files" meanwhile).
//!
//! The system manager asks for it (`request`): SIGUSR1 to init to restart,
//! SIGUSR2 to turn off. Init notices in its loop (`requested`) and calls
//! `now`.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const splash = @import("splash.zig");

const print = sys.print;

pub const Kind = enum { restart, power_off };

/// What was asked for, by signal (0: nothing yet).
var asked = std.atomic.Value(u8).init(0);

fn onSignal(sig: linux.SIG) callconv(.c) void {
    asked.store(if (sig == .USR2) 2 else 1, .release);
}

/// In init: notices requests to restart or turn off. The signals
/// interrupt its wait for its children (no SA_RESTART), so it sees them
/// at once.
pub fn listen() void {
    const act: linux.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.USR1, &act, null);
    _ = linux.sigaction(.USR2, &act, null);
}

/// In init: what has been asked for, if anything.
pub fn requested() ?Kind {
    return switch (asked.load(.acquire)) {
        1 => .restart,
        2 => .power_off,
        else => null,
    };
}

/// From another process (the system manager, which may signal init):
/// asks init to restart or turn off. Returns only if it could not ask.
pub fn request(kind: Kind) void {
    const sig: linux.SIG = if (kind == .restart) .USR1 else .USR2;
    if (linux.errno(linux.kill(1, sig)) != .SUCCESS) return;
    // Init stops this process with the others.
    while (true) _ = linux.pause();
}

/// In init: stops everything, puts the card's filesystems away, and
/// restarts or turns off.
pub fn now(kind: Kind) noreturn {
    print("dazzle: {s}: stopping everything\n", .{if (kind == .restart) "restarting" else "turning off"});
    stopAll();
    // The display is free again: say what is happening.
    const screen = splash.start(if (kind == .restart) "Restarting" else "Turning off");
    putAway();
    print("dazzle: {s}\n", .{if (kind == .restart) "restarting" else "turning off"});
    if (screen) |s| {
        // Seen for a moment at least (it is drawn by its own process).
        sys.sleepMs(300);
        _ = s;
    }
    linux.sync();
    _ = linux.reboot(.MAGIC1, .MAGIC2, if (kind == .restart) .RESTART else .POWER_OFF, null);
    print(sys.log_warning ++ "dazzle: cannot {s}\n", .{if (kind == .restart) "restart" else "turn off"});
    while (true) _ = linux.pause();
}

/// Asks every other process to stop, gives them a moment, then makes the
/// rest; and reaps them all.
fn stopAll() void {
    _ = linux.kill(-1, .TERM);
    if (!reapAll(3000)) {
        _ = linux.kill(-1, .KILL);
        _ = reapAll(2000);
    }
}

/// Reaps children until there are none left (true), or `timeout_ms` has
/// passed.
fn reapAll(timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, @ptrCast(&status), linux.W.NOHANG, null);
        switch (linux.errno(rc)) {
            .CHILD => return true,
            .SUCCESS => if (rc != 0) continue,
            else => {},
        }
        if (waited >= timeout_ms) return false;
        sys.sleepMs(20);
        waited += 20;
    }
}

/// Unmounts the card's filesystems and any drives (the last mounted
/// first), or makes them read-only if they cannot be unmounted.
fn putAway() void {
    linux.sync();
    var buf: [8192]u8 = undefined;
    const text = sys.readFile("/proc/mounts", &buf) orelse return;
    var dirs: [32][]const u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const dir = fields.next() orelse continue;
        if (!putsAway(dir) or n == dirs.len) continue;
        dirs[n] = dir;
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{dirs[n]}, 0) catch continue;
        if (linux.errno(linux.umount2(path.ptr, 0)) == .SUCCESS) {
            print("dazzle: unmounted {s}\n", .{path});
            continue;
        }
        const ro = linux.MS.REMOUNT | linux.MS.RDONLY;
        if (linux.errno(linux.mount(null, path.ptr, null, ro, 0)) == .SUCCESS) {
            print("dazzle: made {s} read-only\n", .{path});
        } else print(sys.log_warning ++ "dazzle: cannot put {s} away\n", .{path});
    }
}

/// Whether a mount at `dir` is the card's, or a drive's (not the
/// system's own, in memory).
fn putsAway(dir: []const u8) bool {
    for ([_][]const u8{ "/data", "/boot", "/media/" }) |prefix| {
        if (std.mem.eql(u8, dir, prefix) or (prefix[prefix.len - 1] == '/' and std.mem.startsWith(u8, dir, prefix))) return true;
    }
    return false;
}

test "the card's filesystems and drives are put away, not the system's own" {
    try std.testing.expect(putsAway("/data"));
    try std.testing.expect(putsAway("/boot"));
    try std.testing.expect(putsAway("/media/USB drive"));
    try std.testing.expect(!putsAway("/proc"));
    try std.testing.expect(!putsAway("/dev"));
    try std.testing.expect(!putsAway("/database"));
}
