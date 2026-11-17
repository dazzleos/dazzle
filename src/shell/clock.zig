//! The time as the shell shows it: in the dock (the time) and at the top
//! of its quick settings (the time and the date), in the computer's time
//! zone and the ways of its language (`locale.current`).
//!
//! A Raspberry Pi has no clock that keeps time while it is off: it starts
//! in 1970, until the network sets the time. A time before Dazzle was built
//! cannot be right, so until then it is not known, and shows as "--:--".

const std = @import("std");
const locale = @import("locale");
const build_info = @import("build_info");

pub const TimeZone = locale.TimeZone;

/// The time on the clock: what it shows, as of `now` (seconds since 1970,
/// UTC) in `zone`.
pub const Time = struct {
    local: locale.timezone.Local,
    /// The minute it is (minutes since 1970, UTC): the clock changes when
    /// it does.
    minute: i64,
    /// The time is right (the clock has been set).
    known: bool = true,

    pub fn at(now: i64, zone: TimeZone) Time {
        return atKnowing(now, zone, @intCast(build_info.commit_time));
    }

    /// As at `now`, the time known if it is no earlier than `earliest`.
    pub fn atKnowing(now: i64, zone: TimeZone, earliest: i64) Time {
        return .{ .local = zone.local(now), .minute = @divFloor(now, 60), .known = now >= earliest };
    }

    /// "14:05", or "2:05 PM"; "--:--" if the time is not known.
    pub fn timeText(t: Time, buf: []u8) []const u8 {
        if (!t.known) return "--:--";
        return locale.formatClock(buf, t.local.hour, t.local.minute);
    }

    /// "Monday, 16 November 2026", "Monday, November 16, 2026" or "lunes,
    /// 16 de noviembre de 2026".
    pub fn dateText(t: Time, buf: []u8) []const u8 {
        if (!t.known) return "";
        return locale.formatFullDate(buf, t.local.weekday, t.local.day, t.local.month, t.local.year);
    }
};

/// The widest the time gets (its digits all as wide as a 0, which they
/// are in most fonts), for room to be kept for it.
pub fn widestText(buf: []u8) []const u8 {
    return locale.formatClock(buf, 0, 0);
}

const testing = std.testing;

test "the time and date, in the zone and the language's ways" {
    const nz = TimeZone.fromName("Pacific/Auckland").?;
    // Monday 16 November 2026, 1:05 am UTC: 2:05 pm in Auckland.
    const t: Time = .atKnowing(1_794_787_200 + 3600 + 300, nz, 0);
    var buf: [64]u8 = undefined;
    const was = locale.current;
    defer locale.current = was;
    locale.current = .en_gb;
    try testing.expectEqualStrings("14:05", t.timeText(&buf));
    try testing.expectEqualStrings("Monday, 16 November 2026", t.dateText(&buf));
    locale.current = .en_us;
    try testing.expectEqualStrings("2:05 PM", t.timeText(&buf));
    try testing.expectEqualStrings("Monday, November 16, 2026", t.dateText(&buf));
    try testing.expectEqualStrings("12:00 AM", widestText(&buf));
    locale.current = .es_mx;
    try testing.expectEqualStrings("2:05 p. m.", t.timeText(&buf));
    try testing.expectEqualStrings("lunes, 16 de noviembre de 2026", t.dateText(&buf));
    locale.current = .es_es;
    try testing.expectEqualStrings("14:05", t.timeText(&buf));
    // The minute it is, whatever the zone.
    try testing.expectEqual(t.minute, Time.at(1_794_787_200 + 3600 + 300, .utc).minute);
}

test "before the clock is set (1970, before Dazzle was built): not known" {
    const nz = TimeZone.fromName("Pacific/Auckland").?;
    var buf: [64]u8 = undefined;
    const booted: Time = .atKnowing(30, nz, 1_794_787_200);
    try testing.expect(!booted.known);
    try testing.expectEqualStrings("--:--", booted.timeText(&buf));
    try testing.expectEqualStrings("", booted.dateText(&buf));
    // Set: shown, and a new minute (the clock is drawn again).
    const set: Time = .atKnowing(1_794_787_200 + 3600, nz, 1_794_787_200);
    try testing.expect(set.known and set.minute != booted.minute);
    try testing.expect(!std.mem.eql(u8, "--:--", set.timeText(&buf)));
    // The time now is after the build.
    try testing.expect(Time.at(@intCast(@divFloor(std.Io.Timestamp.now(testing.io, .real).nanoseconds, std.time.ns_per_s)), nz).known);
}
