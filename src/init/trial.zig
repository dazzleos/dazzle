//! Trying an update, and going back if it does not work. The firmware of
//! the Zero and the 3 A+ has no way to start a slot once (tryboot is only
//! on the Pi 4 and 5), so init does it:
//!
//! 1. Installing (update.zig) writes /boot/trial, "<x> pending", naming
//!    the updated slot, then switches config.txt's os_prefix to it.
//! 2. The updated system's init, first thing, marks the trial "<x> started"
//!    and switches os_prefix back to the other slot: if this start fails
//!    (the system stops, hangs or is turned off), the next start is the
//!    system that was there before. The SoC's watchdog (`Watchdog`, which
//!    runs at every start, not only in a trial) restarts the Pi if the
//!    system hangs.
//! 3. Once the shell has run for `healthy_ns` the update has worked:
//!    os_prefix is switched to it again and the trial ends (`commit`). If
//!    the shell stops before then, init restarts the Pi.
//! 4. The system before, started again with a trial "started" for the
//!    other slot, knows the update did not work: the trial becomes
//!    /boot/trial-failed, which the system manager reports to Settings
//!    (and the next install removes). A trial still "pending" (the power
//!    went while installing) is just removed.
//!
//! A kernel that does not get as far as init is not caught: os_prefix
//! still names its slot. Updates' kernels are built and checked by CI, and
//! that case needs config.txt changed by hand.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const storage = @import("storage.zig");
const slots = @import("slots.zig");

const print = sys.print;

pub const marker = storage.boot_dir ++ "/trial";
pub const failed_marker = storage.boot_dir ++ "/trial-failed";

/// How long the shell must run for an update to have worked.
pub const healthy_ns = 60 * std.time.ns_per_s;

pub const State = enum { pending, started };

pub const Trial = struct {
    slot: u8,
    state: State,

    pub fn parse(text: []const u8) ?Trial {
        var f = std.mem.tokenizeAny(u8, text, " \n");
        const s = f.next() orelse return null;
        if (s.len != 1 or (s[0] != 'a' and s[0] != 'b')) return null;
        return .{ .slot = s[0], .state = std.meta.stringToEnum(State, f.next() orelse return null) orelse return null };
    }
};

/// The trial on the card, if there is one.
pub fn read() ?Trial {
    var buf: [32]u8 = undefined;
    return Trial.parse(sys.readFile(marker, &buf) orelse return null);
}

/// Writes the trial (the boot partition must be writable): as trial.new,
/// then renamed over it.
pub fn write(t: Trial) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{c} {s}\n", .{ t.slot, @tagName(t.state) }) catch unreachable;
    const tmp = marker ++ ".new";
    _ = linux.unlink(tmp);
    const fd = try sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
    {
        defer sys.close(fd);
        var at: usize = 0;
        while (at < text.len) at += try sys.check(linux.write(fd, text[at..].ptr, text.len - at));
        _ = try sys.check(linux.fsync(fd));
    }
    _ = try sys.check(linux.rename(tmp, marker));
}

/// What init does with a trial at boot (with /boot mounted).
pub const Outcome = enum {
    /// No trial.
    none,
    /// This start is the updated system's trial.
    trying,
    /// The update did not work: this is the system before, again.
    failed,
};

/// Looks at the trial, as above, for the system running from `running`.
pub fn atBoot(running: ?u8) Outcome {
    const t = read() orelse return .none;
    const slot = running orelse return .none;
    slots.remount(false) catch |err| {
        print(sys.log_warning ++ "dazzle: trial: cannot write the boot partition: {s}\n", .{@errorName(err)});
        return .none;
    };
    defer slots.remount(true) catch {};
    if (t.slot == slot) {
        // The updated system: the next start is the one before, unless
        // this one works.
        write(.{ .slot = slot, .state = .started }) catch |err| print(sys.log_warning ++ "dazzle: trial: cannot mark it started: {s}\n", .{@errorName(err)});
        slots.startNext(slots.other(slot)) catch |err| print(sys.log_warning ++ "dazzle: trial: cannot keep the system before: {s}\n", .{@errorName(err)});
        print("dazzle: trying the update in OS slot {c}\n", .{std.ascii.toUpper(slot)});
        return .trying;
    }
    // The system before. (os_prefix already names it: the trial changed it.)
    if (t.state == .pending) {
        _ = linux.unlink(marker);
        return .none;
    }
    _ = linux.unlink(failed_marker);
    _ = linux.rename(marker, failed_marker);
    slots.startNext(slot) catch {};
    print(sys.log_error ++ "dazzle: the update in OS slot {c} did not work: back to slot {c}\n", .{ std.ascii.toUpper(t.slot), std.ascii.toUpper(slot) });
    return .failed;
}

/// The update has worked: it starts from now on.
pub fn commit(running: u8) void {
    slots.remount(false) catch |err| {
        print(sys.log_warning ++ "dazzle: trial: cannot write the boot partition: {s}\n", .{@errorName(err)});
        return;
    };
    defer slots.remount(true) catch {};
    slots.startNext(running) catch |err| {
        print(sys.log_warning ++ "dazzle: trial: cannot keep the update: {s}\n", .{@errorName(err)});
        return;
    };
    _ = linux.unlink(marker);
    print("dazzle: the update in OS slot {c} works: it starts from now on\n", .{std.ascii.toUpper(running)});
}

/// Restarts the computer (into the system before, during a trial).
pub fn restart() noreturn {
    print("dazzle: restarting\n", .{});
    linux.sync();
    _ = linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
    while (true) _ = linux.pause();
}

/// The SoC's watchdog, kept fed by a child process for as long as the
/// system runs: if the system hangs, it stops being fed and the Pi
/// restarts.
pub const Watchdog = struct {
    pid: linux.pid_t,
    /// Closing it stops the watchdog.
    stop: linux.fd_t,

    const device = "/dev/watchdog";
    /// The feeder's exit status when there is no watchdog to feed (in
    /// QEMU, say): it is not started again.
    pub const absent = 2;
    /// As long as the BCM2835's allows (about 16 s).
    const timeout_s = 15;
    const feed_ms = 4000;

    pub fn start() ?Watchdog {
        var fds: [2]linux.fd_t = undefined;
        _ = sys.check(linux.pipe2(&fds, .{ .CLOEXEC = true })) catch return null;
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) {
            sys.close(fds[0]);
            sys.close(fds[1]);
            return null;
        }
        if (rc == 0) {
            sys.close(fds[1]);
            if (!feed(fds[0])) linux.exit(absent);
            linux.exit(0);
        }
        sys.close(fds[0]);
        return .{ .pid = @intCast(rc), .stop = fds[1] };
    }

    /// Feeds the watchdog until `stop` is closed; false if there is none.
    fn feed(stop: linux.fd_t) bool {
        const fd = sys.open(device, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }) catch |err| {
            print(sys.log_warning ++ "dazzle: no watchdog ({s})\n", .{@errorName(err)});
            return false;
        };
        // Out of memory, the kernel kills a process to free some: never
        // this one (which would restart the Pi, though the system might
        // well go on).
        if (sys.open("/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY, .CLOEXEC = true })) |adj| {
            _ = linux.write(adj, "-1000", 5);
            sys.close(adj);
        } else |_| {}
        // WDIOC_SETTIMEOUT: _IOWR('W', 6, int).
        var timeout: c_int = timeout_s;
        _ = linux.ioctl(fd, linux.IOCTL.IOWR('W', 6, c_int), @intFromPtr(&timeout));
        while (true) {
            var pfd = [_]linux.pollfd{.{ .fd = stop, .events = linux.POLL.IN, .revents = 0 }};
            if (linux.poll(&pfd, 1, feed_ms) != 0) break;
            _ = linux.write(fd, "1", 1);
        }
        // The magic close: the watchdog stops.
        _ = linux.write(fd, "V", 1);
        sys.close(fd);
        return true;
    }

    /// Stops the watchdog.
    pub fn end(w: Watchdog) void {
        sys.close(w.stop);
    }
};

test "the trial on the card" {
    try std.testing.expectEqual(Trial{ .slot = 'b', .state = .pending }, Trial.parse("b pending\n").?);
    try std.testing.expectEqual(Trial{ .slot = 'a', .state = .started }, Trial.parse("a started").?);
    try std.testing.expect(Trial.parse("c started") == null);
    try std.testing.expect(Trial.parse("b") == null);
    try std.testing.expect(Trial.parse("b done") == null);
}
