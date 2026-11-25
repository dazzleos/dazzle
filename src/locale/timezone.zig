//! Time zones: local time from the system's time (UTC), by the zone's rule
//! as the tz database gives it (a POSIX TZ string, from timezones.zig):
//!
//!     NZST-12NZDT,M9.5.0,M4.1.0/3
//!
//! Standard time is called NZST and is 12 hours ahead of UTC (POSIX counts
//! west of Greenwich as positive); daylight saving time, NZDT, an hour
//! ahead of that, from 2 am on the last Sunday of September (month 9,
//! week 5, day 0) to 3 am on the first Sunday of April. A zone without
//! daylight saving time is its standard part alone ("JST-9"); a name may
//! be quoted ("<+0530>-5:30").
//!
//! The rule is the zone's now and from now on: dates long past may be off
//! (a country that has changed its offset), and so may Morocco's now (its
//! changes for Ramadan are dated, year by year, rather than in a rule).

const std = @import("std");
const table = @import("timezones.zig");

/// A time zone, by its place in `table.zones`.
pub const TimeZone = enum(u16) {
    utc = 0,
    _,

    /// All of them, by name (Area/City).
    pub const count = table.zones.len;

    pub fn all() []const table.Zone {
        return &table.zones;
    }

    /// Its tz database name ("Pacific/Auckland").
    pub fn name(z: TimeZone) []const u8 {
        return table.zones[@intFromEnum(z)].name;
    }

    /// Where its place is (zone.tab's: in degrees north and east), if it
    /// has one (UTC has none).
    pub fn place(z: TimeZone) ?struct { lat: f32, lon: f32 } {
        const zone = table.zones[@intFromEnum(z)];
        if (!zone.located) return null;
        return .{ .lat = zone.lat, .lon = zone.lon };
    }

    /// "Auckland (Pacific)", "Buenos Aires (America/Argentina)": its city,
    /// then its area, for people to read.
    pub fn label(z: TimeZone, buf: []u8) []const u8 {
        const n = z.name();
        const slash = std.mem.lastIndexOfScalar(u8, n, '/') orelse return n;
        const out = std.fmt.bufPrint(buf, "{s} ({s})", .{ n[slash + 1 ..], n[0..slash] }) catch return n;
        std.mem.replaceScalar(u8, out, '_', ' ');
        return out;
    }

    /// Its area: "Pacific", "America" (for "America/Argentina/Buenos_Aires"
    /// too), or "UTC".
    pub fn area(z: TimeZone) []const u8 {
        const n = z.name();
        return n[0 .. std.mem.indexOfScalar(u8, n, '/') orelse n.len];
    }

    /// Its city (with the region in an area, if any), for people to read:
    /// "Auckland", "Argentina/Buenos Aires"; "UTC" for UTC.
    pub fn city(z: TimeZone, buf: []u8) []const u8 {
        const n = z.name();
        const slash = std.mem.indexOfScalar(u8, n, '/') orelse return n;
        const rest = n[slash + 1 ..];
        if (rest.len > buf.len) return rest;
        const out = buf[0..rest.len];
        @memcpy(out, rest);
        std.mem.replaceScalar(u8, out, '_', ' ');
        return out;
    }

    /// The zones in `area_name`, in order: from `first`, `count` of them
    /// (the table is sorted by name, so an area's are together).
    pub fn inArea(area_name: []const u8) struct { first: u16, count: u16 } {
        var first: ?u16 = null;
        var n: u16 = 0;
        for (table.zones, 0..) |_, i| {
            const z: TimeZone = @enumFromInt(i);
            if (!std.mem.eql(u8, z.area(), area_name)) continue;
            if (first == null) first = @intCast(i);
            n += 1;
        }
        return .{ .first = first orelse 0, .count = n };
    }

    /// The areas, in order: UTC, then Africa, America and so on.
    pub const areas = blk: {
        @setEvalBranchQuota(100_000);
        var list: []const []const u8 = &.{};
        for (0..table.zones.len) |i| {
            const n = table.zones[i].name;
            const a = n[0 .. std.mem.indexOfScalar(u8, n, '/') orelse n.len];
            const seen = for (list) |have| {
                if (std.mem.eql(u8, have, a)) break true;
            } else false;
            if (!seen) list = list ++ .{a};
        }
        const out: [list.len][]const u8 = list[0..list.len].*;
        break :blk out;
    };

    pub fn fromName(n: []const u8) ?TimeZone {
        for (table.zones, 0..) |z, i| if (std.mem.eql(u8, z.name, n)) return @enumFromInt(i);
        return null;
    }

    /// Seconds ahead of UTC at `t` (seconds since 1970, UTC).
    pub fn offsetAt(z: TimeZone, t: i64) i32 {
        const r = Rule.parse(table.zones[@intFromEnum(z)].rule) orelse return 0;
        return r.offsetAt(t);
    }

    /// Seconds ahead of UTC in standard time (summer time left out).
    pub fn standardOffset(z: TimeZone) i32 {
        const r = Rule.parse(table.zones[@intFromEnum(z)].rule) orelse return 0;
        return r.std_offset;
    }

    /// The local time at `t` (seconds since 1970, UTC).
    pub fn local(z: TimeZone, t: i64) Local {
        return .of(t + z.offsetAt(t));
    }
};

/// A time on the clock and calendar.
pub const Local = struct {
    year: u16,
    /// 1 to 12, and 1 to 31.
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    /// 0: Sunday.
    weekday: u3,

    /// The time `t` (seconds since 1970) is, as if it were UTC.
    pub fn of(t: i64) Local {
        const days = @divFloor(t, std.time.s_per_day);
        const secs: u32 = @intCast(@mod(t, std.time.s_per_day));
        const yd = (std.time.epoch.EpochDay{ .day = @intCast(@max(days, 0)) }).calculateYearDay();
        const md = yd.calculateMonthDay();
        return .{
            .year = yd.year,
            .month = @intFromEnum(md.month),
            .day = md.day_index + 1,
            .hour = @intCast(secs / 3600),
            .minute = @intCast(secs / 60 % 60),
            .second = @intCast(secs % 60),
            // 1 January 1970 was a Thursday.
            .weekday = @intCast(@mod(days + 4, 7)),
        };
    }
};

/// A zone's rule (see above), parsed.
pub const Rule = struct {
    /// Seconds ahead of UTC in standard time, and in daylight saving time.
    std_offset: i32,
    dst_offset: i32,
    /// When daylight saving time starts and ends (in local time, standard
    /// and daylight respectively); null: there is none.
    start: ?Change = null,
    end: ?Change = null,

    /// A day of the year, and a time on it (seconds; may be negative, or
    /// more than a day).
    pub const Change = struct {
        day: Day,
        time: i32 = 2 * 3600,

        /// When it is in `year`, in UTC, the clocks then `offset` seconds
        /// ahead of it.
        fn utcIn(c: Change, year: u16, offset: i32) i64 {
            return c.day.startIn(year) + c.time - offset;
        }
    };

    pub const Day = union(enum) {
        /// Mm.w.d: day `d` (0: Sunday) of week `w` (5: the last) of month `m`.
        month_week: struct { month: u8, week: u8, weekday: u8 },
        /// Jn: day 1 to 365, never counting 29 February.
        julian: u16,
        /// n: day 0 to 365, counting 29 February.
        zero_based: u16,

        /// When the day starts in `year`, in seconds since 1970 (as if it
        /// were UTC).
        fn startIn(day: Day, year: u16) i64 {
            return switch (day) {
                .zero_based => |n| Rule.dayStart(year, n),
                .julian => |n| blk: {
                    // February's 29th not counted: from March, a day later in a
                    // leap year.
                    const leap = std.time.epoch.isLeapYear(year);
                    break :blk Rule.dayStart(year, n - 1 + @as(u32, if (leap and n >= 60) 1 else 0));
                },
                .month_week => |mw| blk: {
                    const first = Rule.monthStart(year, mw.month);
                    const first_start = Rule.dayStart(year, first);
                    const first_weekday: u32 = @intCast(@mod(@divFloor(first_start, std.time.s_per_day) + 4, 7));
                    var d: u32 = (mw.weekday + 7 - first_weekday) % 7 + (@as(u32, mw.week) - 1) * 7;
                    const in_month = std.time.epoch.getDaysInMonth(year, @enumFromInt(mw.month));
                    // Week 5: the last such day, whichever week that is.
                    while (d >= in_month) d -= 7;
                    break :blk Rule.dayStart(year, first + d);
                },
            };
        }
    };

    pub fn parse(text: []const u8) ?Rule {
        var p: Parser = .{ .s = text };
        p.skipName() orelse return null;
        const std_west = p.offset() orelse return null;
        var r: Rule = .{ .std_offset = -std_west, .dst_offset = -std_west };
        if (p.done()) return r;
        p.skipName() orelse return null;
        // Daylight saving time is an hour ahead, unless it says.
        r.dst_offset = if (p.peek() != ',' and !p.done()) -(p.offset() orelse return null) else r.std_offset + 3600;
        if (p.done()) return null;
        if (!p.eat(',')) return null;
        r.start = p.change() orelse return null;
        if (!p.eat(',')) return null;
        r.end = p.change() orelse return null;
        if (!p.done()) return null;
        return r;
    }

    pub fn offsetAt(r: Rule, t: i64) i32 {
        const start = r.start orelse return r.std_offset;
        const end = r.end orelse return r.std_offset;
        // The year, by standard time.
        const year = Local.of(t + r.std_offset).year;
        // The changes, in UTC: the start in standard time, the end in
        // daylight saving time.
        const on = start.utcIn(year, r.std_offset);
        const off = end.utcIn(year, r.dst_offset);
        const dst = if (on < off) (t >= on and t < off) else !(t >= off and t < on);
        return if (dst) r.dst_offset else r.std_offset;
    }


    const Parser = struct {
        s: []const u8,
        i: usize = 0,

        fn done(p: *const Parser) bool {
            return p.i >= p.s.len;
        }

        fn peek(p: *const Parser) u8 {
            return if (p.done()) 0 else p.s[p.i];
        }

        fn eat(p: *Parser, c: u8) bool {
            if (p.peek() != c) return false;
            p.i += 1;
            return true;
        }

        /// A zone's abbreviation: letters, or anything quoted in <>.
        fn skipName(p: *Parser) ?void {
            if (p.eat('<')) {
                const close = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return null;
                p.i = close + 1;
                return;
            }
            const from = p.i;
            while (std.ascii.isAlphabetic(p.peek())) p.i += 1;
            if (p.i - from < 3) return null;
        }

        fn number(p: *Parser) ?i32 {
            const from = p.i;
            while (std.ascii.isDigit(p.peek())) p.i += 1;
            return std.fmt.parseInt(i32, p.s[from..p.i], 10) catch null;
        }

        /// [+-]hh[:mm[:ss]], in seconds.
        fn offset(p: *Parser) ?i32 {
            const sign: i32 = if (p.eat('-')) -1 else blk: {
                _ = p.eat('+');
                break :blk 1;
            };
            var secs = (p.number() orelse return null) * 3600;
            if (p.eat(':')) {
                secs += (p.number() orelse return null) * 60;
                if (p.eat(':')) secs += p.number() orelse return null;
            }
            return sign * secs;
        }

        fn change(p: *Parser) ?Change {
            var c: Change = .{ .day = undefined };
            if (p.eat('M')) {
                const m = p.number() orelse return null;
                if (!p.eat('.')) return null;
                const w = p.number() orelse return null;
                if (!p.eat('.')) return null;
                const d = p.number() orelse return null;
                if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return null;
                c.day = .{ .month_week = .{ .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(d) } };
            } else if (p.eat('J')) {
                const n = p.number() orelse return null;
                if (n < 1 or n > 365) return null;
                c.day = .{ .julian = @intCast(n) };
            } else {
                const n = p.number() orelse return null;
                if (n > 365) return null;
                c.day = .{ .zero_based = @intCast(n) };
            }
            if (p.eat('/')) c.time = p.offset() orelse return null;
            return c;
        }
    };

    /// When the day starts, in seconds since 1970 (as if it were UTC).
    fn dayStart(year: u16, day_of_year: u32) i64 {
        var days: i64 = 0;
        var y: u16 = 1970;
        while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
        return (days + day_of_year) * std.time.s_per_day;
    }

    fn monthStart(year: u16, month: u8) u32 {
        var d: u32 = 0;
        var m: u8 = 1;
        while (m < month) : (m += 1) d += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
        return d;
    }
};

const testing = std.testing;

test "every zone's rule is understood" {
    for (table.zones) |z| {
        if (Rule.parse(z.rule) == null) {
            std.debug.print("not understood: {s} {s}\n", .{ z.name, z.rule });
            return error.TestUnexpectedResult;
        }
    }
}

test "New Zealand: daylight saving time from the last Sunday of September to the first of April" {
    const nz = TimeZone.fromName("Pacific/Auckland").?;
    // 16 November 2026, midnight UTC: 1 pm in Auckland (NZDT, +13).
    const t: i64 = 1_794_787_200;
    try testing.expectEqual(@as(i32, 13 * 3600), nz.offsetAt(t));
    const l = nz.local(t);
    try testing.expectEqual(@as(u8, 13), l.hour);
    try testing.expectEqual(@as(u8, 16), l.day);
    // 1 July 2026: winter, NZST (+12).
    try testing.expectEqual(@as(i32, 12 * 3600), nz.offsetAt(1_782_864_000));
    // 27 September 2026, the last Sunday: 2 am NZST (26 September, 14:00
    // UTC) becomes 3 am.
    const change: i64 = 1_790_431_200;
    try testing.expectEqual(@as(i32, 12 * 3600), nz.offsetAt(change - 1));
    try testing.expectEqual(@as(i32, 13 * 3600), nz.offsetAt(change));
}

test "London, New York, India and Lord Howe Island" {
    const t: i64 = 1_794_787_200; // 16 November 2026: winter in the north
    const summer: i64 = 1_782_864_000; // 1 July 2026
    try testing.expectEqual(@as(i32, 0), TimeZone.fromName("Europe/London").?.offsetAt(t));
    try testing.expectEqual(@as(i32, 3600), TimeZone.fromName("Europe/London").?.offsetAt(summer));
    try testing.expectEqual(@as(i32, -5 * 3600), TimeZone.fromName("America/New_York").?.offsetAt(t));
    try testing.expectEqual(@as(i32, -4 * 3600), TimeZone.fromName("America/New_York").?.offsetAt(summer));
    try testing.expectEqual(@as(i32, 5 * 3600 + 1800), TimeZone.fromName("Asia/Kolkata").?.offsetAt(t));
    // Half an hour of daylight saving time.
    try testing.expectEqual(@as(i32, 11 * 3600), TimeZone.fromName("Australia/Lord_Howe").?.offsetAt(t));
    try testing.expectEqual(@as(i32, 10 * 3600 + 1800), TimeZone.fromName("Australia/Lord_Howe").?.offsetAt(summer));
    try testing.expectEqual(@as(i32, 0), TimeZone.utc.offsetAt(t));
}

test "areas, and the zones in each" {
    try testing.expectEqualStrings("UTC", TimeZone.areas[0]);
    try testing.expectEqualStrings("Africa", TimeZone.areas[1]);
    const pacific = TimeZone.inArea("Pacific");
    try testing.expect(pacific.count > 20);
    for (0..pacific.count) |i| try testing.expectEqualStrings("Pacific", @as(TimeZone, @enumFromInt(pacific.first + i)).area());
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Argentina/Buenos Aires", TimeZone.fromName("America/Argentina/Buenos_Aires").?.city(&buf));
    try testing.expectEqual(@as(u16, 1), TimeZone.inArea("UTC").count);
}

test "names for people to read" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Buenos Aires (America/Argentina)", TimeZone.fromName("America/Argentina/Buenos_Aires").?.label(&buf));
    try testing.expectEqualStrings("UTC", TimeZone.utc.label(&buf));
}

test "zones' places" {
    const auckland = TimeZone.fromName("Pacific/Auckland").?.place().?;
    try testing.expectApproxEqAbs(@as(f32, -36.87), auckland.lat, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 174.77), auckland.lon, 0.01);
    try testing.expect(TimeZone.utc.place() == null);
    // Every other zone has one, on the Earth.
    for (1..TimeZone.count) |i| {
        const p = @as(TimeZone, @enumFromInt(i)).place().?;
        try testing.expect(p.lat >= -90 and p.lat <= 90 and p.lon >= -180 and p.lon <= 180);
    }
}
