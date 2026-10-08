//! The system log: the kernel's (/dev/kmsg), which has init's messages and
//! every program's (see `sys.print`). Each record /dev/kmsg gives is
//! "<priority>,<sequence>,<microseconds>,<flags>;<text>\n", then optional
//! " KEY=value" lines; the kernel escapes bytes outside printable ASCII
//! (and backslashes) as "\xNN".

const std = @import("std");

pub const path = "/dev/kmsg";

/// How serious a message is (syslog's levels).
pub const Level = enum(u3) {
    emergency,
    alert,
    critical,
    @"error",
    warning,
    notice,
    info,
    debug,

    /// A warning or worse.
    pub fn problem(l: Level) bool {
        return @intFromEnum(l) <= @intFromEnum(Level.warning);
    }
};

pub const Record = struct {
    level: Level,
    sequence: u64,
    /// Since the system started.
    usec: u64,
    /// The message, unescaped (UTF-8 such as "°C" as it was written).
    text: []const u8,
};

/// Parses a record, its text unescaped into `out` (cut short if it does
/// not fit). Null if it is not one.
pub fn parse(out: []u8, record: []const u8) ?Record {
    const semi = std.mem.indexOfScalar(u8, record, ';') orelse return null;
    var fields = std.mem.splitScalar(u8, record[0..semi], ',');
    const prio = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const sequence = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const usec = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const body = record[semi + 1 ..];
    const text = body[0 .. std.mem.indexOfScalar(u8, body, '\n') orelse body.len];
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        if (text[i] == '\\' and i + 4 <= text.len and text[i + 1] == 'x') {
            if (std.fmt.parseInt(u8, text[i + 2 .. i + 4], 16)) |byte| {
                out[n] = byte;
                n += 1;
                i += 4;
                continue;
            } else |_| {}
        }
        out[n] = text[i];
        n += 1;
        i += 1;
    }
    return .{ .level = @enumFromInt(prio & 7), .sequence = sequence, .usec = usec, .text = out[0..n] };
}

const testing = std.testing;

test "records" {
    var buf: [128]u8 = undefined;
    const r = parse(&buf, "5,512,3000042,-;dazzle: starting as init\n SUBSYSTEM=foo\n").?;
    try testing.expectEqual(Level.notice, r.level);
    try testing.expectEqual(@as(u64, 512), r.sequence);
    try testing.expectEqual(@as(u64, 3000042), r.usec);
    try testing.expectEqualStrings("dazzle: starting as init", r.text);
    try testing.expect(parse(&buf, "garbage") == null);
    // Escaped UTF-8 and backslashes are decoded; the facility is not the level.
    const e = parse(&buf, "27,900,6845023,-;dazzle: SoC 36 \\xc2\\xb0C, C:\\x5cdir\n").?;
    try testing.expectEqual(Level.@"error", e.level);
    try testing.expect(e.level.problem());
    try testing.expectEqualStrings("dazzle: SoC 36 °C, C:\\dir", e.text);
    // Cut short to fit.
    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("dazzle", parse(&small, "6,1,1,-;dazzle: hello\n").?.text);
}
