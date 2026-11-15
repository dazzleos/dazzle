//! Parental controls: how long the computer may be used each day (one
//! limit on weekdays, another at weekends), extra time given for today,
//! times it may not be used at all (downtime, such as the night), and
//! whether software may be installed or removed. When the time is up, or
//! downtime starts, the computer is locked until it may be used again, or
//! until a parent unlocks it with the password (which turns parental
//! controls off).
//!
//! The system manager keeps them (src/init/system.zig), in
//! /data/system/parental, which only it can write: apps cannot change
//! them, and restarting the computer does not get round them. It counts
//! the time used, and says in its report whether the computer is locked
//! (see `sys.system`); Settings sets them up, and the shell warns as time
//! runs out and shows the lock.
//!
//! The password is not kept: only a salted hash of it (PBKDF2), checked
//! when it is given. It is set each time parental controls are turned
//! on, so it is not long forgotten.
//!
//! Times of day are local: the clock is UTC, and `Limits.utc_offset` says
//! how far ahead the place is. The clock is only set once the computer is
//! on the network; until then the manager goes on from the last time it
//! saw (see `Usage.wall`), so turning the network off does not stop the
//! day, or the night, coming.

const std = @import("std");
const sys = @import("sys.zig");

pub const file = sys.system.config_dir ++ "/parental";

/// The longest password, in bytes.
pub const max_password = 64;

/// PBKDF2's rounds: slow enough that guessing is slow, quick enough on a
/// Pi Zero.
const rounds = 20_000;

/// Times of day as minutes since midnight (0 to 1439).
pub const Downtime = struct {
    start: u16,
    end: u16,

    /// Whether minute `m` of the day is in it (it may run past midnight).
    pub fn contains(d: Downtime, m: u16) bool {
        if (d.start == d.end) return false;
        return if (d.start < d.end) m >= d.start and m < d.end else m >= d.start or m < d.end;
    }
};

/// What a parent chooses.
pub const Limits = struct {
    /// Minutes a day on weekdays, and on Saturdays and Sundays (null: as
    /// long as they like).
    weekday: ?u16 = 120,
    weekend: ?u16 = 180,
    /// When it may not be used (null: any time).
    downtime: ?Downtime = .{ .start = 20 * 60, .end = 7 * 60 },
    /// Apps may not be installed or removed.
    block_software: bool = true,
    /// How far the local time is ahead of UTC, in minutes.
    utc_offset: i16 = 0,

    /// The most minutes a day can have.
    pub const most_minutes = 24 * 60;

    pub fn valid(l: Limits) bool {
        if (l.weekday) |m| if (m > most_minutes) return false;
        if (l.weekend) |m| if (m > most_minutes) return false;
        if (l.downtime) |d| if (d.start >= most_minutes or d.end >= most_minutes) return false;
        return l.utc_offset >= -14 * 60 and l.utc_offset <= 14 * 60;
    }

    /// The minutes allowed on `weekday` (0: Sunday).
    pub fn minutesOn(l: Limits, weekday: u3) ?u16 {
        return if (weekday == 0 or weekday == 6) l.weekend else l.weekday;
    }

    /// "<weekday> <weekend> <downtime start> <downtime end> <software>
    /// <utc offset>", "-" for none, as requests and reports say them.
    pub fn write(l: Limits, w: *std.Io.Writer) !void {
        try writeOpt(w, l.weekday);
        try w.writeByte(' ');
        try writeOpt(w, l.weekend);
        try w.writeByte(' ');
        try writeOpt(w, if (l.downtime) |d| d.start else null);
        try w.writeByte(' ');
        try writeOpt(w, if (l.downtime) |d| d.end else null);
        try w.print(" {s} {d}", .{ if (l.block_software) "block" else "allow", l.utc_offset });
    }

    pub fn parse(f: *std.mem.TokenIterator(u8, .any)) ?Limits {
        const weekday = parseOpt(f.next() orelse return null) orelse return null;
        const weekend = parseOpt(f.next() orelse return null) orelse return null;
        const start = parseOpt(f.next() orelse return null) orelse return null;
        const end = parseOpt(f.next() orelse return null) orelse return null;
        const software = f.next() orelse return null;
        const l: Limits = .{
            .weekday = weekday.value,
            .weekend = weekend.value,
            .downtime = if (start.value != null and end.value != null) .{ .start = start.value.?, .end = end.value.? } else null,
            .block_software = if (std.mem.eql(u8, software, "block")) true else if (std.mem.eql(u8, software, "allow")) false else return null,
            .utc_offset = std.fmt.parseInt(i16, f.next() orelse return null, 10) catch return null,
        };
        return if (l.valid()) l else null;
    }
};

fn writeOpt(w: *std.Io.Writer, v: ?u16) !void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeByte('-');
}

/// "-" (none) or a number; null if neither.
fn parseOpt(s: []const u8) ?struct { value: ?u16 } {
    if (std.mem.eql(u8, s, "-")) return .{ .value = null };
    return .{ .value = std.fmt.parseInt(u16, s, 10) catch return null };
}

/// A password, as given (in hex in requests, so any bytes will do).
pub const Password = struct {
    buf: [max_password]u8 = undefined,
    len: u8 = 0,

    pub fn of(text: []const u8) ?Password {
        if (text.len == 0 or text.len > max_password) return null;
        var p: Password = .{ .len = @intCast(text.len) };
        @memcpy(p.buf[0..text.len], text);
        return p;
    }

    pub fn slice(p: *const Password) []const u8 {
        return p.buf[0..p.len];
    }

    /// In hex, as requests carry it.
    pub fn hex(p: *const Password, buf: *[2 * max_password]u8) []const u8 {
        const digits = "0123456789abcdef";
        for (p.slice(), 0..) |c, i| {
            buf[2 * i] = digits[c >> 4];
            buf[2 * i + 1] = digits[c & 15];
        }
        return buf[0 .. 2 * @as(usize, p.len)];
    }

    pub fn fromHex(text: []const u8) ?Password {
        if (text.len == 0 or text.len % 2 != 0 or text.len > 2 * max_password) return null;
        var p: Password = .{ .len = @intCast(text.len / 2) };
        _ = std.fmt.hexToBytes(p.buf[0..p.len], text) catch return null;
        return p;
    }
};

/// What is kept: the limits, the password's hash, and today's use.
pub const State = struct {
    on: bool = false,
    limits: Limits = .{},
    salt: [16]u8 = @splat(0),
    hash: [32]u8 = @splat(0),
    usage: Usage = .{},

    /// Turns parental controls on with `limits`, and `password` (from now
    /// on, the one that unlocks).
    pub fn enable(s: *State, password: []const u8, limits: Limits, salt: [16]u8) void {
        s.on = true;
        s.limits = limits;
        s.salt = salt;
        s.hash = hashOf(password, salt);
    }

    /// Whether `password` is the one set.
    pub fn check(s: *const State, password: []const u8) bool {
        const h = hashOf(password, s.salt);
        return std.crypto.timing_safe.eql([32]u8, h, s.hash);
    }

    pub fn write(s: *const State, w: *std.Io.Writer) !void {
        try w.print("on {s}\nlimits ", .{if (s.on) "yes" else "no"});
        try s.limits.write(w);
        try w.print("\nsalt {x}\nhash {x}\n", .{ s.salt, s.hash });
        try w.print("day {d} {d} {d} {d}\n", .{ s.usage.day, s.usage.used_ms, s.usage.bonus, s.usage.wall });
    }

    pub fn parse(text: []const u8) State {
        var s: State = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeAny(u8, line, " \t\r");
            const kind = f.next() orelse continue;
            if (std.mem.eql(u8, kind, "on")) {
                s.on = std.mem.eql(u8, f.next() orelse "", "yes");
            } else if (std.mem.eql(u8, kind, "limits")) {
                if (Limits.parse(&f)) |l| s.limits = l;
            } else if (std.mem.eql(u8, kind, "salt")) {
                _ = std.fmt.hexToBytes(&s.salt, f.next() orelse continue) catch {};
            } else if (std.mem.eql(u8, kind, "hash")) {
                _ = std.fmt.hexToBytes(&s.hash, f.next() orelse continue) catch {};
            } else if (std.mem.eql(u8, kind, "day")) {
                s.usage.day = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
                s.usage.used_ms = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch 0;
                s.usage.bonus = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch 0;
                s.usage.wall = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch 0;
            }
        }
        // Turned on without a password: not really.
        if (std.mem.allEqual(u8, &s.hash, 0)) s.on = false;
        return s;
    }

    /// How it stands at `now` (seconds since 1970).
    pub fn status(s: *const State, now: i64) Status {
        if (!s.on) return .{};
        return statusOf(s.limits, s.usage, now);
    }
};

/// Today's use.
pub const Usage = struct {
    /// The local day it is for (days since 1970).
    day: i32 = std.math.minInt(i32),
    /// Used, in milliseconds.
    used_ms: u32 = 0,
    /// Extra minutes given for today.
    bonus: u16 = 0,
    /// The last time the manager saw (seconds since 1970): time does not
    /// go back before it, even with the clock not set.
    wall: i64 = 0,

    /// Starts a new day's count, if `day` is not the one counted.
    pub fn roll(u: *Usage, day: i32) void {
        if (u.day == day) return;
        u.* = .{ .day = day, .wall = u.wall };
    }

    pub fn usedOn(u: Usage, day: i32) u32 {
        return if (u.day == day) u.used_ms / 1000 else 0;
    }

    pub fn bonusOn(u: Usage, day: i32) u16 {
        return if (u.day == day) u.bonus else 0;
    }
};

/// A moment in local time.
pub const Local = struct {
    /// Days since 1970 (local).
    day: i32,
    /// Seconds into the day.
    second: u32,
    /// 0: Sunday.
    weekday: u3,

    pub fn of(now: i64, utc_offset: i16) Local {
        const t = now + @as(i64, utc_offset) * 60;
        const day: i32 = @intCast(@divFloor(t, std.time.s_per_day));
        return .{
            .day = day,
            .second = @intCast(@mod(t, std.time.s_per_day)),
            // 1 January 1970 was a Thursday.
            .weekday = @intCast(@mod(@as(i64, day) + 4, 7)),
        };
    }

    pub fn minute(l: Local) u16 {
        return @intCast(l.second / 60);
    }
};

pub const Lock = enum {
    none,
    /// The day's time is used up.
    time,
    /// It is downtime.
    downtime,
};

pub const Status = struct {
    lock: Lock = .none,
    /// While not locked: when it will be (seconds since 1970), if ever
    /// (time running out, or downtime starting, while it is used).
    lock_at: ?i64 = null,
    /// While locked: when it may be used again, if ever.
    until: ?i64 = null,
    /// Seconds used today, and the minutes it may be used today (null:
    /// no limit).
    used: u32 = 0,
    allowed: ?u32 = null,
};

fn statusOf(l: Limits, u: Usage, now: i64) Status {
    const local = Local.of(now, l.utc_offset);
    const used = u.usedOn(local.day);
    const allowed: ?u32 = if (l.minutesOn(local.weekday)) |m| @as(u32, m) + u.bonusOn(local.day) else null;
    var s: Status = .{ .used = used, .allowed = allowed };
    if (l.downtime) |d| if (d.contains(local.minute())) {
        s.lock = .downtime;
        s.until = availableFrom(l, now + secondsUntil(local, d.end));
        return s;
    };
    if (allowed) |a| if (used >= a * 60) {
        s.lock = .time;
        s.until = availableFrom(l, startOfNextDay(now, local));
        return s;
    };
    // While used: the time left, or downtime, whichever comes first.
    var at: ?i64 = if (allowed) |a| now + (a * 60 - used) else null;
    if (l.downtime) |d| {
        const down = now + secondsUntil(local, d.start);
        at = if (at) |t| @min(t, down) else down;
    }
    s.lock_at = at;
    return s;
}

/// Seconds from `local` to the next time it is minute `m` of a day.
fn secondsUntil(local: Local, m: u16) i64 {
    return @mod(@as(i64, m) * 60 - local.second, std.time.s_per_day);
}

fn startOfNextDay(now: i64, local: Local) i64 {
    return now + (std.time.s_per_day - local.second);
}

/// The first time from `t` (a start of a day, or the end of downtime) at
/// which it may be used: not in downtime, on a day with some time; null
/// if not within a week.
fn availableFrom(l: Limits, from: i64) ?i64 {
    var t = from;
    for (0..8) |_| {
        const local = Local.of(t, l.utc_offset);
        if (l.downtime) |d| if (d.contains(local.minute())) {
            t += secondsUntil(local, d.end);
            continue;
        };
        if (l.minutesOn(local.weekday)) |m| if (m == 0) {
            t = startOfNextDay(t, local);
            continue;
        };
        return t;
    }
    return null;
}

/// The password's hash with `salt`.
pub fn hashOf(password: []const u8, salt: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&out, password, &salt, rounds, std.crypto.auth.hmac.sha2.HmacSha256) catch unreachable;
    return out;
}

/// A new salt, at random.
pub fn freshSalt() [16]u8 {
    var bytes: [16]u8 = undefined;
    var at: usize = 0;
    while (at < bytes.len) {
        const rc = std.os.linux.getrandom(bytes[at..].ptr, bytes.len - at, 0);
        if (std.os.linux.errno(rc) == .SUCCESS) at += rc;
    }
    return bytes;
}

/// Before 2020, the clock has not been set (it counts from 1970 at boot).
pub fn clockSet(now: i64) bool {
    return now >= 1_577_836_800;
}

// --- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

/// Monday 16 November 2026, at `h`:`m` UTC.
fn monday(h: i64, m: i64) i64 {
    return 1_794_787_200 + h * 3600 + m * 60;
}

test "local days, weekdays and minutes" {
    const l = Local.of(monday(10, 30), 0);
    try testing.expectEqual(@as(u3, 1), l.weekday);
    try testing.expectEqual(@as(u16, 630), l.minute());
    // Sydney, eleven hours ahead: already the evening.
    const syd = Local.of(monday(10, 30), 11 * 60);
    try testing.expectEqual(@as(u16, 21 * 60 + 30), syd.minute());
    try testing.expectEqual(l.day, syd.day);
    // Late on Sunday in UTC is Monday morning in Sydney.
    const sunday = Local.of(monday(-1, 0), 11 * 60);
    try testing.expectEqual(@as(u3, 1), sunday.weekday);
    try testing.expectEqual(@as(u3, 0), Local.of(monday(-1, 0), 0).weekday);
}

test "downtime, across midnight or not" {
    const night: Downtime = .{ .start = 20 * 60, .end = 7 * 60 };
    try testing.expect(night.contains(22 * 60) and night.contains(3 * 60) and !night.contains(12 * 60) and !night.contains(7 * 60));
    const lunch: Downtime = .{ .start = 12 * 60, .end = 13 * 60 };
    try testing.expect(lunch.contains(12 * 60 + 30) and !lunch.contains(13 * 60));
}

test "the day's time runs out, and comes again the next morning, after downtime" {
    var s: State = .{};
    s.enable("sesame", .{ .weekday = 60, .weekend = 120, .downtime = .{ .start = 20 * 60, .end = 7 * 60 } }, @splat(7));
    const now = monday(10, 0);
    const local = Local.of(now, 0);
    s.usage.roll(local.day);
    // Fresh: locks in an hour.
    var st = s.status(now);
    try testing.expectEqual(Lock.none, st.lock);
    try testing.expectEqual(@as(?i64, now + 3600), st.lock_at);
    // Fifty minutes used: ten left.
    s.usage.used_ms = 50 * 60 * 1000;
    try testing.expectEqual(@as(?i64, now + 600), s.status(now).lock_at);
    // Used up: locked until 7:00 tomorrow (midnight is downtime).
    s.usage.used_ms = 60 * 60 * 1000;
    st = s.status(now);
    try testing.expectEqual(Lock.time, st.lock);
    try testing.expectEqual(@as(?i64, monday(24 + 7, 0)), st.until);
    // Bonus time: twenty minutes more.
    s.usage.bonus = 20;
    st = s.status(now);
    try testing.expectEqual(Lock.none, st.lock);
    try testing.expectEqual(@as(?i64, now + 1200), st.lock_at);
    // Evening, with time left: locks when downtime starts.
    s.usage.used_ms = 0;
    try testing.expectEqual(@as(?i64, monday(20, 0)), s.status(monday(19, 30)).lock_at);
    // Downtime: locked till 7:00.
    st = s.status(monday(23, 0));
    try testing.expectEqual(Lock.downtime, st.lock);
    try testing.expectEqual(@as(?i64, monday(24 + 7, 0)), st.until);
    // A new day: the count starts again.
    s.usage.used_ms = 60 * 60 * 1000;
    const tomorrow = monday(24 + 9, 0);
    try testing.expectEqual(Lock.none, s.status(tomorrow).lock);
    s.usage.roll(Local.of(tomorrow, 0).day);
    try testing.expectEqual(@as(u32, 0), s.usage.used_ms);
    // Off: never locked.
    s.on = false;
    try testing.expectEqual(Lock.none, s.status(monday(23, 0)).lock);
}

test "no time on weekdays: available again on Saturday" {
    var s: State = .{};
    s.enable("x", .{ .weekday = 0, .weekend = 60, .downtime = null }, @splat(1));
    const st = s.status(monday(12, 0));
    try testing.expectEqual(Lock.time, st.lock);
    // Saturday, midnight.
    try testing.expectEqual(@as(?i64, monday(5 * 24, 0)), st.until);
    // No limits at all: never locks.
    s.limits = .{ .weekday = null, .weekend = null, .downtime = null };
    try testing.expect(s.status(monday(12, 0)).lock_at == null);
}

test "the password: only its hash is kept, and only it unlocks" {
    var s: State = .{};
    s.enable("correct horse", .{}, freshSalt());
    try testing.expect(s.check("correct horse"));
    try testing.expect(!s.check("correct horsE"));
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.write(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "horse") == null);
    const back = State.parse(w.buffered());
    try testing.expect(back.on and back.check("correct horse"));
    try testing.expectEqual(s.limits, back.limits);
    // In hex, as requests carry it.
    var hex_buf: [2 * max_password]u8 = undefined;
    const p = Password.of("pa ss").?;
    try testing.expectEqualStrings("7061207373", p.hex(&hex_buf));
    try testing.expectEqualStrings("pa ss", Password.fromHex("7061207373").?.slice());
    try testing.expect(Password.fromHex("7") == null);
    // On, but with no password: off.
    try testing.expect(!State.parse("on yes\n").on);
}

test "limits, as requests and reports say them" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const l: Limits = .{ .weekday = 90, .weekend = null, .downtime = .{ .start = 1260, .end = 420 }, .block_software = false, .utc_offset = -300 };
    try l.write(&w);
    try testing.expectEqualStrings("90 - 1260 420 allow -300", w.buffered());
    var f = std.mem.tokenizeAny(u8, w.buffered(), " ");
    try testing.expectEqual(l, Limits.parse(&f).?);
    var bad = std.mem.tokenizeAny(u8, "90 - 1500 420 allow 0", " ");
    try testing.expect(Limits.parse(&bad) == null);
}
