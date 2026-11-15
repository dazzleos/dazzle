//! Parental controls' lock screen (see `sys.parental`): while the system
//! manager says the computer is locked (the day's time is up, or it is
//! downtime), the shell hides the windows and the dock and shows this, in
//! the middle of the screen: why, when it may be used again, and a box to
//! type the parent's password in (as dots), which turns parental controls
//! off. All the keys come here meanwhile.
//!
//! And, before then, the warnings: as the time left comes to ten minutes,
//! five and one, a notification says so.

const std = @import("std");
const sys = @import("sys");
const font = @import("font");
const icons = @import("icons");
const locale = @import("locale");
const glass = @import("glass.zig");
const dock = @import("dock.zig");
const remote = @import("remote.zig");

const Parental = sys.system.Parental;

/// Its size (at 1080p; scaled).
const box_width = 560;
const box_height = 340;
const pad = 32;

pub const Lock = struct {
    font: ?font.Font,
    icon_font: ?font.Font,
    cache: font.GlyphCache,
    /// Drawn over black (then its picture), and over white.
    pixels: []u32,
    width: u32,
    height: u32,
    scale: f32,
    theme: dock.Theme = .dark,
    /// The password typed so far.
    typed: [sys.parental.max_password]u8 = undefined,
    len: u8 = 0,
    shift: [2]bool = .{ false, false },
    /// The password tried was not the one.
    wrong: bool = false,

    pub fn init(gpa: std.mem.Allocator, f: ?font.Font, scale: f32) !Lock {
        const w: u32 = @intFromFloat(@round(box_width * scale));
        const h: u32 = @intFromFloat(@round(box_height * scale));
        return .{
            .font = f,
            .icon_font = font.Font.init(icons.font_data) catch null,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, 2 * @as(usize, w) * h),
            .width = w,
            .height = h,
            .scale = scale,
        };
    }

    pub fn deinit(l: *Lock, gpa: std.mem.Allocator) void {
        gpa.free(l.pixels);
        l.cache.deinit();
    }

    pub fn password(l: *const Lock) []const u8 {
        return l.typed[0..l.len];
    }

    /// Forgets what was typed.
    pub fn clear(l: *Lock) void {
        @memset(&l.typed, 0);
        l.len = 0;
    }

    pub const KeyResult = enum { none, changed, submit };

    /// A key pressed or let go (a Linux key code): typed into the box;
    /// Enter, with something typed, to try it.
    pub fn key(l: *Lock, code: u32, pressed: bool) KeyResult {
        switch (code) {
            remote.key_left_shift => l.shift[0] = pressed,
            54 => l.shift[1] = pressed,
            else => {},
        }
        if (!pressed) return .none;
        switch (code) {
            // Enter (and the keypad's).
            28, 96 => return if (l.len > 0) .submit else .none,
            // Backspace.
            14 => {
                if (l.len == 0) return .none;
                l.len -= 1;
                l.wrong = false;
                return .changed;
            },
            // Escape: start again.
            1 => {
                l.clear();
                l.wrong = false;
                return .changed;
            },
            else => {},
        }
        const c = remote.charFor(code, l.shift[0] or l.shift[1]) orelse return .none;
        if (c == '\n' or c == '\t' or l.len == l.typed.len) return .none;
        l.typed[l.len] = c;
        l.len += 1;
        l.wrong = false;
        return .changed;
    }

    /// Draws it as `p` says, at `system_now` (the system's clock).
    pub fn draw(l: *Lock, p: Parental, system_now: i64) void {
        const count = @as(usize, l.width) * l.height;
        const over_black: font.Canvas = .{ .pixels = l.pixels[0..count], .width = l.width, .height = l.height, .stride = l.width };
        const over_white: font.Canvas = .{ .pixels = l.pixels[count .. 2 * count], .width = l.width, .height = l.height, .stride = l.width };
        l.drawContents(over_black, glass.black, p, system_now);
        l.drawContents(over_white, glass.white, p, system_now);
        glass.compose(over_black.pixels, over_white.pixels, l.theme.colors().background);
        glass.cutCorners(over_black, @round(dock.Dock.box_radius * 1.5 * l.scale));
    }

    pub fn picture(l: *const Lock) []const u32 {
        return l.pixels[0 .. @as(usize, l.width) * l.height];
    }

    /// In the middle of a screen `w` by `h`.
    pub fn place(l: *const Lock, w: u32, h: u32) [2]i32 {
        return .{ @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(l.width)), 2), @divTrunc(@as(i32, @intCast(h)) - @as(i32, @intCast(l.height)), 2) };
    }

    fn drawContents(l: *Lock, canvas: font.Canvas, base: u32, p: Parental, system_now: i64) void {
        const s = l.scale;
        const c = l.theme.colors();
        const w: f32 = @floatFromInt(l.width);
        canvas.fill(0, 0, l.width, l.height, base);
        if (l.icon_font) |*f| {
            const size = @round(44 * s);
            var buf: [4]u8 = undefined;
            const text = icons.text(.lock, &buf);
            _ = font.draw(canvas, &l.cache, .{ .font = f, .size = size, .color = c.dot }, @round((w - size) / 2), @round(28 * s) + size, text) catch {};
        }
        const f = if (l.font) |*f| f else return;
        const centred = struct {
            fn at(cv: font.Canvas, cache: *font.GlyphCache, style: font.Style, width: f32, y: f32, text: []const u8) void {
                _ = font.draw(cv, cache, style, @round((width - font.measure(style, text)) / 2), y, text) catch {};
            }
        }.at;
        const title: font.Style = .{ .font = f, .size = @round(26 * s), .color = c.dot };
        const line: font.Style = .{ .font = f, .size = @round(17 * s), .color = dimmed(c.dot) };
        const small: font.Style = .{ .font = f, .size = @round(15 * s), .color = dimmed(c.dot) };
        centred(canvas, &l.cache, title, w, @round(122 * s), switch (p.lock) {
            .downtime => "It is downtime",
            else => "Time is up for today",
        });
        var when_buf: [64]u8 = undefined;
        var buf: [96]u8 = undefined;
        const until = if (p.until) |t|
            std.fmt.bufPrint(&buf, "This computer can be used again {s}", .{whenText(&when_buf, t, p.now(system_now), p.limits.utc_offset)}) catch ""
        else
            "This computer cannot be used again this week";
        centred(canvas, &l.cache, line, w, @round(154 * s), until);
        centred(canvas, &l.cache, small, w, @round(204 * s), "A parent can unlock it with the password");
        // The box, the password in it as dots.
        const bx = @round(pad * s);
        const by = @round(220 * s);
        const bw = w - 2 * bx;
        const bh = @round(46 * s);
        glass.fillRounded(canvas, bx, by, bw, bh, @round(10 * s), if (l.wrong) 0xffe57373 else dimmed(c.dot));
        glass.fillRounded(canvas, bx + @round(2 * s), by + @round(2 * s), bw - @round(4 * s), bh - @round(4 * s), @round(8 * s), base);
        if (l.len == 0) {
            centred(canvas, &l.cache, small, w, by + bh / 2 + small.ascent() / 2, "Password");
        } else {
            const dot = @round(10 * s);
            const step = @round(18 * s);
            const n = @min(@as(f32, @floatFromInt(l.len)), @floor((bw - 2 * dot) / step));
            var x = @round((w - (n - 1) * step - dot) / 2);
            for (0..@intFromFloat(n)) |_| {
                glass.fillRounded(canvas, x, by + (bh - dot) / 2, dot, dot, dot / 2, c.dot);
                x += step;
            }
        }
        centred(canvas, &l.cache, if (l.wrong) .{ .font = f, .size = small.size, .color = 0xffe57373 } else small, w, @round(306 * s), if (l.wrong) "That is not the password" else "Type it, then press Enter");
    }
};

/// When `t` is, from `now` (both seconds since 1970, by the manager's
/// clock): "at 3:30 pm", "tomorrow at 7:00 am", "on Saturday at 7:00 am".
pub fn whenText(buf: []u8, t: i64, now: i64, utc_offset: i16) []const u8 {
    const at = sys.parental.Local.of(t, utc_offset);
    const today = sys.parental.Local.of(now, utc_offset);
    var clock_buf: [16]u8 = undefined;
    const clock = locale.formatClock(&clock_buf, at.second / 3600, at.second / 60 % 60);
    const days = at.day - today.day;
    const names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    return (if (days <= 0)
        std.fmt.bufPrint(buf, "at {s}", .{clock})
    else if (days == 1)
        std.fmt.bufPrint(buf, "tomorrow at {s}", .{clock})
    else
        std.fmt.bufPrint(buf, "on {s} at {s}", .{ names[at.weekday], clock })) catch "";
}

/// The warnings as time runs out, in seconds left.
const warn_at = [_]i64{ 10 * 60, 5 * 60, 60 };

/// What to say as time runs out.
pub const Warning = struct {
    title: []const u8,
    body: []const u8,
};

/// The warnings given so far (how many of `warn_at`), kept by the shell.
pub const Warnings = struct {
    given: u8 = 0,

    /// A warning due at `system_now`, if one is (in `buf`).
    pub fn due(ws: *Warnings, p: Parental, system_now: i64, buf: []u8) ?Warning {
        const lock_at = if (p.on and p.lock == .none) p.lock_at else null;
        const t = lock_at orelse {
            ws.given = 0;
            return null;
        };
        const now = p.now(system_now);
        const left = t - now;
        // More time (a bonus): the warnings start again.
        while (ws.given > 0 and left > warn_at[ws.given - 1] + 30) ws.given -= 1;
        var which: ?usize = null;
        while (ws.given < warn_at.len and left <= warn_at[ws.given]) : (ws.given += 1) which = ws.given;
        _ = which orelse return null;
        if (left <= 0) return null;
        const minutes: i64 = @max(1, @divFloor(left + 30, 60));
        // Downtime starting, or the day's time running out.
        const local = sys.parental.Local.of(t, p.limits.utc_offset);
        const downtime = if (p.limits.downtime) |d| local.minute() == d.start else false;
        const half = buf.len / 2;
        var when_buf: [64]u8 = undefined;
        const title = (if (downtime)
            std.fmt.bufPrint(buf[0..half], "Downtime in {d} minute{s}", .{ minutes, if (minutes == 1) "" else "s" })
        else
            std.fmt.bufPrint(buf[0..half], "{d} minute{s} left today", .{ minutes, if (minutes == 1) "" else "s" })) catch return null;
        const body = std.fmt.bufPrint(buf[half..], "The computer locks {s}", .{whenText(&when_buf, t, now, p.limits.utc_offset)}) catch return null;
        return .{ .title = title, .body = body };
    }
};

/// The colour, a little dimmer.
fn dimmed(c: u32) u32 {
    return (c & 0x00ffffff) | 0xb8000000;
}

const testing = std.testing;

test "the password is typed as the keys say, and Enter tries it" {
    var l = try Lock.init(testing.allocator, null, 1);
    defer l.deinit(testing.allocator);
    const type_ = struct {
        fn in(lk: *Lock, text: []const u8) void {
            for (text) |ch| {
                const k = remote.keyFor(ch).?;
                if (k.shift) _ = lk.key(remote.key_left_shift, true);
                _ = lk.key(k.code, true);
                _ = lk.key(k.code, false);
                if (k.shift) _ = lk.key(remote.key_left_shift, false);
            }
        }
    }.in;
    try testing.expectEqual(Lock.KeyResult.none, l.key(28, true));
    type_(&l, "Pa55 word!");
    try testing.expectEqualStrings("Pa55 word!", l.password());
    try testing.expectEqual(Lock.KeyResult.changed, l.key(14, true));
    try testing.expectEqualStrings("Pa55 word", l.password());
    try testing.expectEqual(Lock.KeyResult.submit, l.key(28, true));
    l.wrong = true;
    _ = l.key(1, true);
    try testing.expectEqual(@as(u8, 0), l.len);
    try testing.expect(!l.wrong);
    // Drawn without a font: the box, at least.
    l.draw(.{ .on = true, .lock = .time, .until = 1794830400 }, 1794800000);
    try testing.expect(l.picture()[(l.height / 2) * l.width + l.width / 2] >> 24 != 0);
    try testing.expectEqual([2]i32{ (1920 - 560) / 2, (1080 - 340) / 2 }, l.place(1920, 1080));
}

test "warnings at ten, five and one minute left; again after a bonus" {
    var ws: Warnings = .{};
    var buf: [192]u8 = undefined;
    const now: i64 = 1_794_787_200; // Monday, 16 November 2026, midnight UTC
    var p: Parental = .{ .on = true, .limits = .{ .downtime = null }, .lock_at = now + 30 * 60 };
    try testing.expect(ws.due(p, now, &buf) == null);
    const w10 = ws.due(p, now + 20 * 60, &buf).?;
    try testing.expectEqualStrings("10 minutes left today", w10.title);
    try testing.expect(ws.due(p, now + 21 * 60, &buf) == null);
    try testing.expectEqualStrings("5 minutes left today", ws.due(p, now + 25 * 60, &buf).?.title);
    try testing.expectEqualStrings("1 minute left today", ws.due(p, now + 29 * 60, &buf).?.title);
    try testing.expect(ws.due(p, now + 29 * 60 + 30, &buf) == null);
    // Twenty minutes more: warned again as it runs out.
    p.lock_at = now + 50 * 60;
    try testing.expect(ws.due(p, now + 30 * 60, &buf) == null);
    try testing.expectEqualStrings("10 minutes left today", ws.due(p, now + 40 * 60, &buf).?.title);
    // Downtime starting.
    var d: Parental = .{ .on = true, .limits = .{ .downtime = .{ .start = 20 * 60, .end = 7 * 60 } }, .lock_at = now + 20 * 3600 };
    var wd: Warnings = .{};
    try testing.expectEqualStrings("Downtime in 5 minutes", (wd.due(d, now + 20 * 3600 - 5 * 60, &buf) orelse return error.NoWarning).title);
    // Locked: none.
    d.lock = .downtime;
    try testing.expect(wd.due(d, now + 21 * 3600, &buf) == null);
}

test "when it may be used again, in words" {
    var buf: [64]u8 = undefined;
    const now: i64 = 1_794_787_200 + 15 * 3600; // Monday 3 pm UTC
    try testing.expect(std.mem.startsWith(u8, whenText(&buf, now + 3600, now, 0), "at "));
    try testing.expect(std.mem.startsWith(u8, whenText(&buf, now + 16 * 3600, now, 0), "tomorrow at "));
    try testing.expect(std.mem.startsWith(u8, whenText(&buf, now + 4 * 86400, now, 0), "on Friday at "));
}
