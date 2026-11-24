//! Keeps the log of each start on the card, in /data/system/log (and the
//! start before's in /data/system/log.previous), so that a start that goes
//! wrong with nothing on the screen can be looked into afterwards: the
//! card can be read on another computer.
//!
//! A child process copies the kernel's log (which has init's messages, and
//! every program's) from the start of this boot, then each new message as
//! it comes, writing it to the card within a second. It needs /data, so
//! a start that stops before init mounts it leaves nothing here.
//!
//! When a slot tried (see trial.zig) did not start properly, its log (the
//! start before's) is also kept as `sys.system.failed_start_log`, which
//! Settings shows, until the next trial: if it is that trial's.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const logserver = @import("logserver.zig");
const trial = @import("trial.zig");

const print = sys.print;

pub const file = sys.system.config_dir ++ "/log";
pub const previous_file = sys.system.config_dir ++ "/log.previous";

/// The most kept of one start: a program that logs without end must not
/// fill the card (or wear it out).
const max_bytes = 4 * 1024 * 1024;
/// How long a message may wait before it is on the card.
const sync_ms = 1000;

/// Starts keeping the log (with /data mounted); `failed`: the start before
/// was a trial that did not work (its log is kept). Returns the process's
/// PID.
pub fn start(failed: bool) ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print(sys.log_warning ++ "dazzle: boot log: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    keep(failed) catch |err| print(sys.log_warning ++ "dazzle: boot log: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

fn keep(failed: bool) !void {
    _ = linux.rename(file, previous_file);
    if (failed) keepFailed() catch |err| print(sys.log_warning ++ "dazzle: boot log: cannot keep the failed start's: {s}\n", .{@errorName(err)});
    const fd = try sys.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true });
    // Anyone's to read, on another computer too: the log server (when on)
    // serves the same to the network.
    _ = linux.fchmod(fd, 0o644);
    const kmsg = try sys.open("/dev/kmsg", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
    // The files are open: nothing more needs root.
    try sys.dropPrivilegesKeeping(&.{});

    var record: [8192]u8 = undefined;
    var line: [8192 + 32]u8 = undefined;
    var kept: usize = 0;
    var unsynced = false;
    var last_sync: u64 = 0;
    while (true) {
        const rc = linux.read(kmsg, &record, record.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const text = logserver.formatRecord(&line, record[0..rc]) orelse continue;
                if (kept + text.len > max_bytes) {
                    try writeAll(fd, "[the log is full: the rest of this start is not kept]\n");
                    _ = linux.fsync(fd);
                    return;
                }
                try writeAll(fd, text);
                kept += text.len;
                unsynced = true;
                continue;
            },
            // The ring buffer overwrote records not read yet; the next read
            // continues from the oldest remaining one.
            .PIPE, .INTR => continue,
            // All read: on to the card, then wait for more.
            .AGAIN => {},
            else => |e| return sys.errorFromErrno(e),
        }
        var timeout: i32 = -1;
        if (unsynced) {
            const since_ms = (sys.nowNs() -| last_sync) / std.time.ns_per_ms;
            if (since_ms >= sync_ms) {
                _ = linux.fsync(fd);
                unsynced = false;
                last_sync = sys.nowNs();
            } else timeout = @intCast(sync_ms - since_ms);
        }
        var fds = [_]linux.pollfd{.{ .fd = kmsg, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&fds, fds.len, timeout);
    }
}

/// The start before's log, as the failed start's: if it is the trial's
/// (it got as far as saying so); otherwise there is none (it stopped
/// before keeping one).
fn keepFailed() !void {
    _ = linux.unlink(sys.system.failed_start_log);
    const gpa = std.heap.page_allocator;
    const log = try sys.readFileAlloc(gpa, previous_file, max_bytes + 4096);
    defer gpa.free(log);
    if (std.mem.indexOf(u8, log, trial.trying_text) == null) return;
    const out = try sys.open(sys.system.failed_start_log, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
    defer sys.close(out);
    _ = linux.fchmod(out, 0o644);
    try writeAll(out, log);
    _ = linux.fsync(out);
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR, .AGAIN => continue,
            else => |e| return sys.errorFromErrno(e),
        }
    }
}
