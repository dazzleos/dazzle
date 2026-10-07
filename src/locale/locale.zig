//! Languages and keyboards: which the computer uses (`Settings`, kept in
//! /data/system/locale and chosen in setup and Settings), and what they
//! mean for the apps: the keys' characters (`Keyboard.char`), how dates,
//! times and temperatures are written, and the words that differ between
//! languages (`text`).
//!
//! Dazzle's text is written in British English; a language that writes
//! something differently says so in its table (see `text`).
//!
//!     locale.current = locale.load().language;
//!     const label = locale.text("16-bit colour");

const std = @import("std");
const linux = std.os.linux;

pub const Language = enum {
    en_us,
    en_gb,
    en_au,
    en_nz,
    en_ca,

    /// Its code, as BCP 47 writes it: "en-GB".
    pub fn code(l: Language) []const u8 {
        return switch (l) {
            .en_us => "en-US",
            .en_gb => "en-GB",
            .en_au => "en-AU",
            .en_nz => "en-NZ",
            .en_ca => "en-CA",
        };
    }

    pub fn fromCode(text_: []const u8) ?Language {
        for (std.enums.values(Language)) |l| if (std.ascii.eqlIgnoreCase(l.code(), text_)) return l;
        return null;
    }

    /// Its name, in itself.
    pub fn name(l: Language) []const u8 {
        return switch (l) {
            .en_us => "English (United States)",
            .en_gb => "English (United Kingdom)",
            .en_au => "English (Australia)",
            .en_nz => "English (New Zealand)",
            .en_ca => "English (Canada)",
        };
    }

    /// The keyboard most people there have.
    pub fn keyboard(l: Language) Keyboard {
        return switch (l) {
            .en_gb => .gb,
            else => .us,
        };
    }

    pub const Clock = enum {
        /// 18:05
        @"24_hour",
        /// 6:05 PM
        @"12_hour_upper",
        /// 6:05 pm
        @"12_hour_lower",
    };

    pub fn clock(l: Language) Clock {
        return switch (l) {
            .en_gb => .@"24_hour",
            .en_us, .en_ca => .@"12_hour_upper",
            .en_au, .en_nz => .@"12_hour_lower",
        };
    }

    /// Dates with the month first: "Oct 7" rather than "7 Oct".
    pub fn monthFirst(l: Language) bool {
        return l == .en_us or l == .en_ca;
    }

    /// Temperatures in Fahrenheit.
    pub fn fahrenheit(l: Language) bool {
        return l == .en_us;
    }
};

/// The keyboard layouts: which character each key types (by Linux key
/// code), alone, with Shift, and with AltGr (the right Alt).
pub const Keyboard = enum {
    us,
    gb,

    pub fn name(k: Keyboard) []const u8 {
        return switch (k) {
            .us => "English (US)",
            .gb => "English (UK)",
        };
    }

    /// Its XKB name.
    pub fn code(k: Keyboard) []const u8 {
        return @tagName(k);
    }

    pub fn fromCode(text_: []const u8) ?Keyboard {
        return std.meta.stringToEnum(Keyboard, text_);
    }

    /// The keys that type characters, and what they type.
    pub fn keys(k: Keyboard) []const Key {
        return switch (k) {
            .us => &us_keys,
            .gb => &gb_keys,
        };
    }

    /// The character a key types, if it types one. Caps Lock shifts
    /// letters only.
    pub fn char(k: Keyboard, key_code: u32, shift: bool, caps: bool, altgr: bool) ?u21 {
        for (k.keys()) |key| if (key.code == key_code) {
            if (altgr) return key.altgr;
            const letter = key.plain >= 'a' and key.plain <= 'z';
            const up = if (letter) shift != caps else shift;
            return if (up) key.shifted else key.plain;
        };
        return null;
    }
};

pub const Key = struct {
    code: u8,
    plain: u21,
    shifted: u21,
    altgr: ?u21 = null,
};

/// The keys of a US keyboard's rows, by Linux key code.
fn row(comptime first: u8, comptime plain: []const u8, comptime shifted: []const u8) [plain.len]Key {
    var out: [plain.len]Key = undefined;
    for (&out, plain, shifted, 0..) |*k, p, s, i| k.* = .{ .code = first + i, .plain = p, .shifted = s };
    return out;
}

const us_keys = row(2, "1234567890-=", "!@#$%^&*()_+") ++
    row(16, "qwertyuiop[]", "QWERTYUIOP{}") ++
    row(30, "asdfghjkl;'`", "ASDFGHJKL:\"~") ++
    [_]Key{.{ .code = 43, .plain = '\\', .shifted = '|' }} ++
    row(44, "zxcvbnm,./", "ZXCVBNM<>?") ++
    [_]Key{
        .{ .code = 57, .plain = ' ', .shifted = ' ' },
        // The key beside the left Shift, on keyboards that have one.
        .{ .code = 86, .plain = '<', .shifted = '>' },
    };

/// A UK keyboard: the US one with ", £, @, ¬ and # where the UK has them,
/// the extra key beside the left Shift, and the euro on AltGr+4.
const gb_keys = blk: {
    var keys = us_keys;
    for (&keys) |*k| switch (k.code) {
        3 => k.shifted = '"',
        4 => k.shifted = '£',
        5 => k.altgr = '€',
        40 => k.shifted = '@',
        41 => {
            k.shifted = '¬';
            k.altgr = '¦';
        },
        43 => {
            k.plain = '#';
            k.shifted = '~';
        },
        86 => {
            k.plain = '\\';
            k.shifted = '|';
        },
        else => {},
    };
    break :blk keys;
};

// --- The choice, kept ------------------------------------------------------------

/// Where the choice is kept (written by the system manager, readable by
/// everyone).
pub const settings_file = "/data/system/locale";

pub const Settings = struct {
    language: Language = .en_us,
    keyboard: Keyboard = .us,

    /// "language en-GB\nkeyboard gb\n"; what is missing or not known stays
    /// as it is by default.
    pub fn parse(text_: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeScalar(u8, text_, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const key = f.next() orelse continue;
            const value = f.next() orelse continue;
            if (std.mem.eql(u8, key, "language")) {
                if (Language.fromCode(value)) |l| s.language = l;
            } else if (std.mem.eql(u8, key, "keyboard")) {
                if (Keyboard.fromCode(value)) |k| s.keyboard = k;
            }
        }
        return s;
    }

    pub fn write(s: Settings, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "language {s}\nkeyboard {s}\n", .{ s.language.code(), s.keyboard.code() }) catch "";
    }
};

/// The settings kept (the defaults, if there are none yet).
pub fn load() Settings {
    return loadFrom(settings_file);
}

pub fn loadFrom(path: [*:0]const u8) Settings {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return .{};
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [256]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return .{};
    return Settings.parse(buf[0..n]);
}

// --- What the app shows -------------------------------------------------------------

/// The language the app's text and formats are in (apps set it from the
/// settings: British English, the text's own, until they do).
pub var current: Language = .en_gb;

/// `s` (Dazzle's British English) in the current language.
pub fn text(comptime s: []const u8) []const u8 {
    const us = comptime lookup(&us_spelling, s);
    return switch (current) {
        .en_us => us,
        else => s,
    };
}

fn lookup(table: []const [2][]const u8, comptime s: []const u8) []const u8 {
    for (table) |pair| if (std.mem.eql(u8, pair[0], s)) return pair[1];
    return s;
}

/// American spelling, where it differs (Canada spells as Britain does).
const us_spelling = [_][2][]const u8{
    .{ "colour", "color" },
    .{ "16-bit colour", "16-bit color" },
};

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// A time of day: "18:05", "6:05 PM" or "6:05 pm".
pub fn formatClock(buf: []u8, hour: u32, minute: u32) []const u8 {
    const h12 = if (hour % 12 == 0) 12 else hour % 12;
    return switch (current.clock()) {
        .@"24_hour" => std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }),
        .@"12_hour_upper" => std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, minute, if (hour < 12) "AM" else "PM" }),
        .@"12_hour_lower" => std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, minute, if (hour < 12) "am" else "pm" }),
    } catch "";
}

/// A date: "7 Oct" or "Oct 7", with the year ("7 Oct 2025", "Oct 7,
/// 2025") if `year` is given.
pub fn formatDate(buf: []u8, day: u32, month: u32, year: ?u32) []const u8 {
    const m = months[@min(month, 12) -| 1];
    if (current.monthFirst()) {
        if (year) |y| return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ m, day, y }) catch "";
        return std.fmt.bufPrint(buf, "{s} {d}", .{ m, day }) catch "";
    }
    if (year) |y| return std.fmt.bufPrint(buf, "{d} {s} {d}", .{ day, m, y }) catch "";
    return std.fmt.bufPrint(buf, "{d} {s}", .{ day, m }) catch "";
}

/// A date in full: "7 October 2026", or "October 7, 2026".
pub fn formatLongDate(buf: []u8, day: u32, month: u32, year: u32) []const u8 {
    const names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    const m = names[@min(month, 12) -| 1];
    if (current.monthFirst()) return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ m, day, year }) catch "";
    return std.fmt.bufPrint(buf, "{d} {s} {d}", .{ day, m, year }) catch "";
}

/// When something happened, against `now` (both in seconds since 1970, in
/// UTC, the only time the system has): "Today, 10:32", "Yesterday, 6:05
/// PM", "7 Oct" this year, else "7 Oct 2025" (in the current language's
/// ways).
pub fn formatWhen(buf: []u8, secs: i64, now: i64) []const u8 {
    if (secs <= 0) return "";
    const day_secs = std.time.s_per_day;
    const day = @divFloor(secs, day_secs);
    const today = @divFloor(now, day_secs);
    const in_day: u32 = @intCast(@mod(secs, day_secs));
    if (day == today or day == today - 1) {
        var clock_buf: [16]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}, {s}", .{ if (day == today) "Today" else "Yesterday", formatClock(&clock_buf, in_day / 3600, in_day / 60 % 60) }) catch "";
    }
    const date = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
    const md = date.calculateMonthDay();
    const this_year = (std.time.epoch.EpochDay{ .day = @intCast(@max(today, 0)) }).calculateYearDay().year;
    return formatDate(buf, md.day_index + 1, @intFromEnum(md.month), if (date.year == this_year) null else date.year);
}

/// A temperature, given in Celsius: "48.3 °C", or "118.9 °F".
pub fn formatTemperature(buf: []u8, celsius: f32) []const u8 {
    if (current.fahrenheit()) return std.fmt.bufPrint(buf, "{d:.1} °F", .{celsius * 9 / 5 + 32}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} °C", .{celsius}) catch "";
}

// --- Tests -------------------------------------------------------------------------

const testing = std.testing;

test "keyboards" {
    // US.
    try testing.expectEqual(@as(?u21, 'a'), Keyboard.us.char(30, false, false, false));
    try testing.expectEqual(@as(?u21, 'A'), Keyboard.us.char(30, true, false, false));
    try testing.expectEqual(@as(?u21, 'A'), Keyboard.us.char(30, false, true, false));
    try testing.expectEqual(@as(?u21, '1'), Keyboard.us.char(2, false, true, false));
    try testing.expectEqual(@as(?u21, '@'), Keyboard.us.char(3, true, false, false));
    try testing.expectEqual(@as(?u21, '#'), Keyboard.us.char(4, true, false, false));
    try testing.expectEqual(@as(?u21, '"'), Keyboard.us.char(40, true, false, false));
    try testing.expectEqual(@as(?u21, '\\'), Keyboard.us.char(43, false, false, false));
    try testing.expectEqual(@as(?u21, ' '), Keyboard.us.char(57, false, false, false));
    try testing.expectEqual(@as(?u21, null), Keyboard.us.char(1, false, false, false));
    try testing.expectEqual(@as(?u21, null), Keyboard.us.char(5, false, false, true));
    // UK.
    try testing.expectEqual(@as(?u21, '"'), Keyboard.gb.char(3, true, false, false));
    try testing.expectEqual(@as(?u21, '£'), Keyboard.gb.char(4, true, false, false));
    try testing.expectEqual(@as(?u21, '€'), Keyboard.gb.char(5, false, false, true));
    try testing.expectEqual(@as(?u21, '@'), Keyboard.gb.char(40, true, false, false));
    try testing.expectEqual(@as(?u21, '¬'), Keyboard.gb.char(41, true, false, false));
    try testing.expectEqual(@as(?u21, '#'), Keyboard.gb.char(43, false, false, false));
    try testing.expectEqual(@as(?u21, '~'), Keyboard.gb.char(43, true, false, false));
    try testing.expectEqual(@as(?u21, '\\'), Keyboard.gb.char(86, false, false, false));
    try testing.expectEqual(@as(?u21, 'q'), Keyboard.gb.char(16, false, false, false));
}

test "settings, kept as text" {
    var buf: [64]u8 = undefined;
    const s: Settings = .{ .language = .en_nz, .keyboard = .gb };
    try testing.expectEqualStrings("language en-NZ\nkeyboard gb\n", s.write(&buf));
    try testing.expectEqual(s, Settings.parse(s.write(&buf)));
    try testing.expectEqual(Settings{}, Settings.parse("language xx-XX\nkeyboard dvorak\nnonsense\n"));
    try testing.expectEqual(Language.en_ca, Settings.parse("language en-ca").language);
    try testing.expectEqual(Settings{}, loadFrom("/nonexistent/locale"));
}

test "dates, times and temperatures, in each language" {
    defer current = .en_gb;
    var buf: [32]u8 = undefined;
    // 2026-10-07 10:32 UTC.
    const now = 1791331200 + 10 * 3600 + 32 * 60;
    current = .en_gb;
    try testing.expectEqualStrings("Today, 10:32", formatWhen(&buf, now, now));
    try testing.expectEqualStrings("Yesterday, 18:05", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("1 Jan", formatWhen(&buf, 1767225600, now));
    try testing.expectEqualStrings("31 Dec 2025", formatWhen(&buf, 1767225600 - 60, now));
    try testing.expectEqualStrings("48.3 °C", formatTemperature(&buf, 48.3));
    try testing.expectEqualStrings("colour", text("colour"));
    try testing.expectEqualStrings("7 October 2026", formatLongDate(&buf, 7, 10, 2026));
    current = .en_us;
    try testing.expectEqualStrings("Today, 10:32 AM", formatWhen(&buf, now, now));
    try testing.expectEqualStrings("Yesterday, 6:05 PM", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("Today, 12:00 AM", formatWhen(&buf, 1791331200, now));
    try testing.expectEqualStrings("Jan 1", formatWhen(&buf, 1767225600, now));
    try testing.expectEqualStrings("Dec 31, 2025", formatWhen(&buf, 1767225600 - 60, now));
    try testing.expectEqualStrings("October 7, 2026", formatLongDate(&buf, 7, 10, 2026));
    try testing.expectEqualStrings("118.9 °F", formatTemperature(&buf, 48.3));
    try testing.expectEqualStrings("color", text("colour"));
    current = .en_nz;
    try testing.expectEqualStrings("Yesterday, 6:05 pm", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("7 Oct", formatDate(&buf, 7, 10, null));
    current = .en_ca;
    try testing.expectEqualStrings("Oct 7", formatDate(&buf, 7, 10, null));
    try testing.expectEqualStrings("colour", text("colour"));
    try testing.expectEqualStrings("", formatWhen(&buf, 0, now));
}

test "languages" {
    try testing.expectEqual(Language.en_gb, Language.fromCode("en-GB").?);
    try testing.expect(Language.fromCode("fr-FR") == null);
    try testing.expectEqual(Keyboard.gb, Language.en_gb.keyboard());
    try testing.expectEqual(Keyboard.us, Language.en_au.keyboard());
}
