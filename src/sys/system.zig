//! The system manager's protocol. On the first run, init runs the manager
//! (src/init/system.zig), which prepares the SD card's free space for files
//! and sets the computer's name; it listens on a socket, /system, and
//! answers only the setup app, checked by the program the connecting
//! process runs.
//!
//! A client connects, sends a request and reads the report until the
//! manager closes the connection. The requests are:
//!
//!     status
//!     prepare                  give the card's free space a filesystem
//!     finish <hostname>        name the computer, and finish setting up
//!
//! and the report:
//!
//!     storage preparing 42
//!     hostname awesome-elephant
//!     end
//!
//! "storage" is how the card's free space is: "none" (there is no card),
//! "unprepared", "preparing" with how far it has got (in percent),
//! "ready", or "failed" with why. A client the manager does not serve gets
//! "denied\n".

const std = @import("std");

/// The manager's socket.
pub const socket_path = "/system";

/// The only program the manager answers.
pub const allowed_program = "/shell/dazzle-setup";

/// Where the card's free space is mounted, and the files in it.
pub const data_dir = "/data";
/// The system's settings (owned by root).
pub const config_dir = "/data/system";
/// The computer's name.
pub const hostname_file = "/data/system/hostname";
/// There once setup has finished.
pub const setup_done_file = "/data/system/setup-done";
/// The user's files.
pub const user_dir = "/data/user";

pub const StorageState = enum { none, unprepared, preparing, ready, failed };

pub const Failure = enum {
    none,
    /// Too little space after the system's partition.
    too_small,
    /// The partition table has no room for another partition.
    no_room,
    /// Reading or writing the card failed.
    io,
    /// The new filesystem could not be mounted.
    mount,

    pub fn label(f: Failure) []const u8 {
        return switch (f) {
            .none => "",
            .too_small => "there is too little free space on the card",
            .no_room => "the card's partition table is full",
            .io => "the card could not be written",
            .mount => "the new filesystem could not be used",
        };
    }
};

pub const Request = union(enum) {
    status,
    prepare,
    finish: Hostname,

    pub fn parse(line: []const u8) ?Request {
        var f = std.mem.tokenizeAny(u8, line, " \n");
        const kind = f.next() orelse return null;
        if (std.mem.eql(u8, kind, "status")) return .status;
        if (std.mem.eql(u8, kind, "prepare")) return .prepare;
        if (std.mem.eql(u8, kind, "finish")) return .{ .finish = Hostname.parse(f.next() orelse return null) orelse return null };
        return null;
    }
};

/// A computer's name: 1 to 63 lowercase letters, digits and hyphens, not
/// starting or ending with a hyphen (a DNS label).
pub const Hostname = struct {
    buf: [63]u8 = undefined,
    len: u8 = 0,

    pub fn slice(h: *const Hostname) []const u8 {
        return h.buf[0..h.len];
    }

    pub fn parse(s: []const u8) ?Hostname {
        if (s.len == 0 or s.len > 63 or s[0] == '-' or s[s.len - 1] == '-') return null;
        for (s) |c| switch (c) {
            'a'...'z', '0'...'9', '-' => {},
            else => return null,
        };
        var h: Hostname = .{ .len = @intCast(s.len) };
        @memcpy(h.buf[0..s.len], s);
        return h;
    }
};

pub const Report = struct {
    storage: StorageState = .none,
    /// How far preparing has got, in percent.
    progress: u8 = 0,
    failure: Failure = .none,
    hostname: Hostname = .{},
    /// The manager refused the client.
    denied: bool = false,

    pub fn write(r: *const Report, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print("storage {s}", .{@tagName(r.storage)}) catch {};
        switch (r.storage) {
            .preparing => w.print(" {d}", .{r.progress}) catch {},
            .failed => w.print(" {s}", .{@tagName(r.failure)}) catch {},
            else => {},
        }
        w.print("\nhostname {s}\nend\n", .{if (r.hostname.len > 0) r.hostname.slice() else "-"}) catch {};
        return w.buffered();
    }

    /// Reads a report; null if it is incomplete (no "end").
    pub fn parse(text: []const u8) ?Report {
        var r: Report = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const kind = f.next() orelse continue;
            if (std.mem.eql(u8, kind, "end")) return r;
            if (std.mem.eql(u8, kind, "denied")) {
                r.denied = true;
                return r;
            } else if (std.mem.eql(u8, kind, "storage")) {
                r.storage = std.meta.stringToEnum(StorageState, f.next() orelse continue) orelse .none;
                const extra = f.next() orelse continue;
                switch (r.storage) {
                    .preparing => r.progress = std.fmt.parseInt(u8, extra, 10) catch 0,
                    .failed => r.failure = std.meta.stringToEnum(Failure, extra) orelse .io,
                    else => {},
                }
            } else if (std.mem.eql(u8, kind, "hostname")) {
                r.hostname = Hostname.parse(f.next() orelse continue) orelse .{};
            }
        }
        return null;
    }
};

const testing = std.testing;

test "hostnames" {
    try testing.expectEqualStrings("awesome-elephant", Hostname.parse("awesome-elephant").?.slice());
    try testing.expect(Hostname.parse("pi4") != null);
    try testing.expect(Hostname.parse("") == null);
    try testing.expect(Hostname.parse("-pi") == null);
    try testing.expect(Hostname.parse("pi-") == null);
    try testing.expect(Hostname.parse("My-Pi") == null);
    try testing.expect(Hostname.parse("pi.local") == null);
    try testing.expect(Hostname.parse("a" ** 64) == null);
}

test "requests and reports go through the socket" {
    try testing.expect(Request.parse("status\n").? == .status);
    try testing.expect(Request.parse("prepare\n").? == .prepare);
    try testing.expectEqualStrings("dazzle", Request.parse("finish dazzle\n").?.finish.slice());
    try testing.expect(Request.parse("finish Bad!\n") == null);
    try testing.expect(Request.parse("reboot\n") == null);

    var r: Report = .{ .storage = .preparing, .progress = 42, .hostname = Hostname.parse("awesome-elephant").? };
    var buf: [256]u8 = undefined;
    const text = r.write(&buf);
    try testing.expectEqualStrings("storage preparing 42\nhostname awesome-elephant\nend\n", text);
    const back = Report.parse(text).?;
    try testing.expectEqual(StorageState.preparing, back.storage);
    try testing.expectEqual(@as(u8, 42), back.progress);
    try testing.expectEqualStrings("awesome-elephant", back.hostname.slice());
    r = .{ .storage = .failed, .failure = .too_small };
    const failed = Report.parse(r.write(&buf)).?;
    try testing.expectEqual(Failure.too_small, failed.failure);
    try testing.expectEqual(@as(u8, 0), failed.hostname.len);
    try testing.expect(Report.parse("denied\n").?.denied);
    try testing.expect(Report.parse("storage ready\n") == null);
}
