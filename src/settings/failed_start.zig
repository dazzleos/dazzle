//! Why an OS slot did not start properly, from its log
//! (`sys.system.failed_start_log`, kept by init's bootlog.zig): how long it
//! ran, the lines that say something went wrong (but not those this start
//! says too: what every start logs, such as firmware the Pi does without),
//! and its last lines.

const std = @import("std");
const sys = @import("sys");

/// The most lines shown of each kind.
pub const max_notable = 24;
pub const max_tail = 12;

pub const Summary = struct {
    /// The log (its lines are slices of it).
    text: []u8,
    /// How long the start ran, by its last line (microseconds since the
    /// kernel started).
    ran_us: ?u64 = null,
    notable: [max_notable][]const u8 = undefined,
    notable_len: usize = 0,
    /// How many more lines like those there were.
    notable_more: usize = 0,
    tail: [max_tail][]const u8 = undefined,
    tail_len: usize = 0,

    pub fn notableLines(s: *const Summary) []const []const u8 {
        return s.notable[0..s.notable_len];
    }

    pub fn tailLines(s: *const Summary) []const []const u8 {
        return s.tail[0..s.tail_len];
    }

    pub fn deinit(s: *Summary, gpa: std.mem.Allocator) void {
        gpa.free(s.text);
    }
};

/// Reads the failed start's log; null if there is none (it stopped
/// before keeping one). This start's log (`sys.system.config_dir/log`)
/// says what is usual.
pub fn load(gpa: std.mem.Allocator) ?Summary {
    const text = sys.readFileAlloc(gpa, sys.system.failed_start_log, 8 * 1024 * 1024) catch return null;
    const usual = sys.readFileAlloc(gpa, sys.system.config_dir ++ "/log", 8 * 1024 * 1024) catch null;
    defer if (usual) |u| gpa.free(u);
    return summarize(text, usual orelse "");
}

/// The summary of `text` (which it keeps); the lines that are in `usual`
/// too (another start's log) are not among those that say what went
/// wrong.
pub fn summarize(text: []u8, usual: []const u8) Summary {
    var s: Summary = .{ .text = text };
    var lines = std.mem.splitScalar(u8, text, '\n');
    // The last lines, in a ring.
    var ring: [max_tail][]const u8 = undefined;
    var seen: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (line.len == 0) continue;
        if (stamp(line)) |us| s.ran_us = @max(s.ran_us orelse 0, us);
        ring[seen % max_tail] = line;
        seen += 1;
        if (notable(message(line)) and !logs(usual, message(line))) {
            if (s.notable_len < max_notable) {
                s.notable[s.notable_len] = line;
                s.notable_len += 1;
            } else s.notable_more += 1;
        }
    }
    const n = @min(seen, max_tail);
    for (0..n) |i| s.tail[i] = ring[(seen - n + i) % max_tail];
    s.tail_len = n;
    return s;
}

/// Whether `log` has a line saying `text` (at any time).
fn logs(log: []const u8, text: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, log, at, text)) |i| {
        at = i + 1;
        const end = i + text.len;
        if ((end == log.len or log[end] == '\n' or log[end] == '\r') and i >= 2 and log[i - 1] == ' ' and log[i - 2] == ']') return true;
    }
    return false;
}

/// A line's time: "[   12.345678] text" is 12345678 µs.
fn stamp(line: []const u8) ?u64 {
    if (line.len < 3 or line[0] != '[') return null;
    const end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    const t = std.mem.trim(u8, line[1..end], " ");
    const dot = std.mem.indexOfScalar(u8, t, '.') orelse return null;
    const secs = std.fmt.parseInt(u64, t[0..dot], 10) catch return null;
    const frac = t[dot + 1 ..];
    if (frac.len == 0 or frac.len > 6) return null;
    var us = std.fmt.parseInt(u64, frac, 10) catch return null;
    for (frac.len..6) |_| us *= 10;
    return secs * std.time.us_per_s + us;
}

/// A line without its time.
pub fn message(line: []const u8) []const u8 {
    if (line.len > 0 and line[0] == '[') if (std.mem.indexOfScalar(u8, line, ']')) |end| return std.mem.trimStart(u8, line[end + 1 ..], " ");
    return line;
}

/// Words that say something went wrong.
const signs = [_][]const u8{
    "error",  "fail",     "cannot",  "can't",   "unable",   "panic",  "oops",
    "bug:",   "segfault", "killed",  "signal",  "exited",   "denied", "timed out",
    "timeout", "not work", "did not", "corrupt", "warning",  "no such", "out of memory",
    "unhandled", "abort",  "invalid", "refused",
};

fn notable(text: []const u8) bool {
    var lower: [512]u8 = undefined;
    const l = std.ascii.lowerString(&lower, text[0..@min(text.len, lower.len)]);
    for (signs) |w| if (std.mem.indexOf(u8, l, w) != null) return true;
    return false;
}

const testing = std.testing;

test "a failed start's log, summarized" {
    const log =
        \\[    0.000000] Booting Linux on physical CPU 0x0
        \\[    1.200000] mmc0: new high speed SDHC card
        \\[    1.300000] unicam: error: already registered
        \\[    2.500000] dazzle: starting as init (build abc)
        \\[    2.600000] dazzle: trying OS slot B: if its shell does not run, slot A starts next
        \\[    3.100000] dazzle-shell: cannot open /dev/dri/card0: NotFound
        \\[    3.150000] dazzle: shell exited with status 1
        \\[    3.200000] dazzle: OS slot B does not work: restarting into the system before
        \\
    ;
    const text = try testing.allocator.dupe(u8, log);
    // What every start says is not what went wrong.
    var s = summarize(text, "[    1.000000] mmc0: new high speed SDHC card\n[    0.900000] unicam: error: already registered\n");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 3_200_000), s.ran_us);
    try testing.expectEqual(@as(usize, 3), s.notable_len);
    try testing.expectEqualStrings("[    3.100000] dazzle-shell: cannot open /dev/dri/card0: NotFound", s.notableLines()[0]);
    try testing.expectEqual(@as(usize, 8), s.tail_len);
    try testing.expectEqualStrings("[    0.000000] Booting Linux on physical CPU 0x0", s.tailLines()[0]);
    try testing.expectEqualStrings("dazzle: shell exited with status 1", message(s.notableLines()[1]));
    try testing.expectEqual(@as(?u64, 12_340_000), stamp("[   12.34] x"));
    try testing.expect(stamp("no time") == null);
}

test "only the last lines are kept" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..40) |i| try buf.print(testing.allocator, "[{d:>5}.000000] line {d}\n", .{ i, i });
    var s = summarize(try buf.toOwnedSlice(testing.allocator), "");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, max_tail), s.tail_len);
    try testing.expectEqualStrings("line 28", message(s.tailLines()[0]));
    try testing.expectEqualStrings("line 39", message(s.tailLines()[max_tail - 1]));
    try testing.expectEqual(@as(usize, 0), s.notable_len);
}
