//! The time as the shell shows it: in the dock (the time) and at the top
//! of its quick settings (the time and the date), in the computer's time
//! zone and the ways of its language (`locale.current`).

const std = @import("std");
const locale = @import("locale");

pub const TimeZone = locale.TimeZone;

/// The time on the clock: what it shows, as of `now` (seconds since 1970,
/// UTC) in `zone`.
pub const Time = struct {
    local: locale.timezone.Local,
    /// The minute it is (minutes since 1970, UTC): the clock changes when
    /// it does.
    minute: i64,

    pub fn at(now: i64, zone: TimeZone) Time {
        return .{ .local = zone.local(now), .minute = @divFloor(now, 60) };
    }

    /// "14:05", or "2:05 PM".
    pub fn timeText(t: Time, buf: []u8) []const u8 {
        return locale.formatClock(buf, t.local.hour, t.local.minute);
    }

    /// "Monday, 16 November 2026", "Monday, November 16, 2026" or "lunes,
    /// 16 de noviembre de 2026".
    pub fn dateText(t: Time, buf: []u8) []const u8 {
        var date_buf: [40]u8 = undefined;
        const date = locale.formatLongDate(&date_buf, t.local.day, t.local.month, t.local.year);
        return std.fmt.bufPrint(buf, "{s}, {s}", .{ locale.weekdayName(t.local.weekday), date }) catch "";
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
    const t: Time = .at(1_794_787_200 + 3600 + 300, nz);
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
