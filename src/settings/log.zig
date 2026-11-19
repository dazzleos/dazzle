//! The system log, for the Log page: the newest messages (the last
//! `max_lines`), read from /dev/kmsg (see `sys.log`) while the page shows.
//! The first read has everything since the system started that the kernel
//! still keeps; each later one what has come since.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const max_lines = 400;
/// The longest a message is kept (longer ones are cut short).
pub const max_text = 200;

pub const Line = struct {
    level: sys.log.Level,
    usec: u64,
    buf: [max_text]u8 = undefined,
    len: u8 = 0,

    pub fn text(l: *const Line) []const u8 {
        return l.buf[0..l.len];
    }
};

pub const Log = struct {
    fd: ?linux.fd_t = null,
    /// A ring of the newest lines: `count` of them, the oldest at `start`.
    lines: [max_lines]Line = undefined,
    start: usize = 0,
    count: usize = 0,
    /// It could not be read (and why).
    failed: bool = false,

    pub fn deinit(l: *Log) void {
        if (l.fd) |fd| sys.close(fd);
        l.fd = null;
    }

    /// Reads what has come since. Returns whether anything did.
    pub fn poll(l: *Log) bool {
        return l.pollFrom(sys.log.path);
    }

    pub fn pollFrom(l: *Log, path: [*:0]const u8) bool {
        const fd = l.fd orelse blk: {
            const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }) catch {
                l.failed = true;
                return false;
            };
            l.fd = fd;
            break :blk fd;
        };
        var any = false;
        var record: [8192]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &record, record.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    l.add(record[0..rc]);
                    any = true;
                },
                // Records were overwritten before they were read: on from
                // the oldest left.
                .PIPE, .INTR => continue,
                else => break,
            }
        }
        return any;
    }

    /// Adds a record (as /dev/kmsg gives it), dropping the oldest line if
    /// there are `max_lines`.
    pub fn add(l: *Log, record: []const u8) void {
        var line: Line = undefined;
        const r = sys.log.parse(&line.buf, record) orelse return;
        line.level = r.level;
        line.usec = r.usec;
        line.len = @intCast(r.text.len);
        if (l.count < max_lines) {
            l.lines[(l.start + l.count) % max_lines] = line;
            l.count += 1;
        } else {
            l.lines[l.start] = line;
            l.start = (l.start + 1) % max_lines;
        }
    }

    /// The `i`th newest line (0: the newest).
    pub fn newest(l: *const Log, i: usize) *const Line {
        return &l.lines[(l.start + l.count - 1 - i) % max_lines];
    }
};

/// "12.345": seconds since the system started, to the millisecond; with
/// minutes and hours after a minute ("3:05.120", "1:02:03.004").
pub fn formatUptime(buf: []u8, usec: u64) []const u8 {
    const ms = usec / 1000;
    const s = ms / 1000;
    if (s < 60) return std.fmt.bufPrint(buf, "{d}.{d:0>3}", .{ s, ms % 1000 }) catch "";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d:0>3}", .{ s / 60, s % 60, ms % 1000 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>3}", .{ s / 3600, s / 60 % 60, s % 60, ms % 1000 }) catch "";
}

const testing = std.testing;

test "the newest lines are kept" {
    var l: Log = .{};
    var buf: [64]u8 = undefined;
    for (0..max_lines + 5) |i| l.add(try std.fmt.bufPrint(&buf, "6,{d},{d},-;line {d}\n", .{ i, i * 1000, i }));
    try testing.expectEqual(@as(usize, max_lines), l.count);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "line {d}", .{max_lines + 4}), l.newest(0).text());
    try testing.expectEqualStrings("line 5", l.newest(max_lines - 1).text());
    l.add("3,999,1,-;" ++ &@as([300]u8, @splat('x')) ++ "\n");
    try testing.expectEqual(sys.log.Level.@"error", l.newest(0).level);
    try testing.expectEqual(@as(usize, max_text), l.newest(0).text().len);
    // Not a record: nothing.
    l.add("nonsense");
    try testing.expectEqual(sys.log.Level.@"error", l.newest(0).level);
    var none: Log = .{};
    try testing.expect(!none.pollFrom("/nonexistent/kmsg"));
    try testing.expect(none.failed);
}

test "times since starting" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("12.345", formatUptime(&buf, 12_345_678));
    try testing.expectEqualStrings("0.000", formatUptime(&buf, 0));
    try testing.expectEqualStrings("3:05.120", formatUptime(&buf, 185_120_000));
    try testing.expectEqualStrings("1:02:03.004", formatUptime(&buf, 3_723_004_000));
}
