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
const kete = @import("kete");
const locale = @import("locale");
const kete_panel = @import("kete_panel.zig");

const Parental = sys.system.Parental;

/// The password typed into the lock screen, and how trying it went.
pub const Entry = struct {
    typed: [sys.parental.max_password]u8 = undefined,
    len: u8 = 0,
    /// The password tried was not the one.
    wrong: bool = false,
    /// Enter was pressed, for the shell to try it.
    submitted: bool = false,
    /// A new field each time (empty, after a try).
    field: u32 = 0,

    pub fn password(e: *const Entry) []const u8 {
        return e.typed[0..e.len];
    }

    /// Forgets what was typed (a new, empty field).
    pub fn clear(e: *Entry) void {
        @memset(&e.typed, 0);
        e.len = 0;
        e.submitted = false;
        e.field +%= 1;
    }

    fn changed(e: *Entry, text: []const u8) void {
        e.len = @intCast(@min(text.len, e.typed.len));
        @memcpy(e.typed[0..e.len], text[0..e.len]);
        e.wrong = false;
    }

    fn submit(e: *Entry) void {
        if (e.len > 0) e.submitted = true;
    }
};

/// The lock screen's size (it is drawn as a panel, in the middle of the
/// screen).
pub const width = 560;
pub const height = 340;

/// The lock screen, as kete widgets: why it is locked, when it may be
/// used again, and the password's field.
pub const View = struct {
    parental: Parental,
    /// The system's clock, and the time zone.
    system_now: i64,
    zone: sys.parental.TimeZone = .utc,
    entry: *Entry,

    pub fn build(self: *const View, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const p = self.parental;
        var when_buf: [64]u8 = undefined;
        const until = if (p.until) |at|
            cx.fmt("This computer can be used again {s}", .{whenText(&when_buf, at, p.now(self.system_now), self.zone)})
        else
            "This computer cannot be used again this week";
        var rows: std.ArrayList(kete.Widget) = .empty;
        const a = cx.arena;
        rows.appendSlice(a, &.{
            cx.make(kete.Icon{ .icon = .lock, .size = 44, .color = t.primary }),
            cx.make(kete.Text{ .text = switch (p.lock) {
                .downtime => "It is downtime",
                else => "Time is up for today",
            }, .style = .{ .size = 26, .color = t.on_surface }, .wrap = false }),
            cx.make(kete.Text{ .text = until, .style = .{ .size = 17, .color = t.on_surface_variant }, .wrap = false }),
            cx.make(kete.SizedBox{ .height = 8 }),
            cx.make(kete.Text{ .text = "A parent can unlock it with the password", .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false }),
            cx.make(kete.TextField{
                .placeholder = "Password",
                .obscure = true,
                .max_len = sys.parental.max_password,
                .width = 400,
                .autofocus = true,
                .on_changed = .of(self.entry, Entry.changed),
                .on_submit = .of(self.entry, Entry.submit),
            }).withKey(@as(u64, self.entry.field) | 0x10c0_0000),
        }) catch {};
        if (self.entry.wrong) rows.append(a, cx.make(kete.Text{ .text = "That is not the password", .style = .{ .size = 15, .color = t.@"error" }, .wrap = false })) catch {};
        return cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .border_width = 1,
            .border_color = t.outline_variant,
            .radius = .all(24),
            .child = cx.make(kete.Padding{ .padding = .all(28), .child = cx.make(kete.Column{
                .fill = false,
                .spacing = 10,
                .cross_axis_alignment = .center,
                .children = rows.items,
            }) }),
        });
    }
};

/// The lock screen as the shell has it: its panel (kete's), and the
/// password typed.
pub const Screen = struct {
    panel: *kete_panel.Panel,
    entry: Entry = .{},
    /// The computer's time zone (the system's report says).
    zone: sys.parental.TimeZone = .utc,

    /// Its picture, as `p` says, `width` by `height`.
    pub fn draw(s: *Screen, p: Parental) kete_panel.Picture {
        return s.panel.draw(width, height, sys.nowNs(), View{ .parental = p, .system_now = sys.realtimeSec(), .zone = s.zone, .entry = &s.entry });
    }

    /// In the middle of a screen `w` by `h`.
    pub fn place(w: u32, h: u32) [2]i32 {
        return .{ @divTrunc(@as(i32, @intCast(w)) - width, 2), @divTrunc(@as(i32, @intCast(h)) - height, 2) };
    }
};

/// When `t` is, from `now` (both seconds since 1970, by the manager's
/// clock), in `zone`: "at 3:30 pm", "tomorrow at 7:00 am", "on Saturday at
/// 7:00 am".
pub fn whenText(buf: []u8, t: i64, now: i64, zone: sys.parental.TimeZone) []const u8 {
    const at = sys.parental.Local.in(t, zone);
    const today = sys.parental.Local.in(now, zone);
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

    /// When the next warning is due (seconds since 1970, by the system's
    /// clock), if one is to come.
    pub fn nextAt(ws: *const Warnings, p: Parental, system_now: i64) ?i64 {
        const t = if (p.on and p.lock == .none) p.lock_at orelse return null else return null;
        if (ws.given >= warn_at.len) return null;
        // `lock_at` is by the manager's clock: back to the system's.
        return (t - warn_at[ws.given]) - (p.now(system_now) - system_now);
    }

    /// A warning due at `system_now`, if one is (in `buf`), in `zone`.
    pub fn due(ws: *Warnings, p: Parental, system_now: i64, zone: sys.parental.TimeZone, buf: []u8) ?Warning {
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
        const local = sys.parental.Local.in(t, zone);
        const downtime = if (p.limits.downtime) |d| local.minute() == d.start else false;
        const half = buf.len / 2;
        var when_buf: [64]u8 = undefined;
        const title = (if (downtime)
            std.fmt.bufPrint(buf[0..half], "Downtime in {d} minute{s}", .{ minutes, if (minutes == 1) "" else "s" })
        else
            std.fmt.bufPrint(buf[0..half], "{d} minute{s} left today", .{ minutes, if (minutes == 1) "" else "s" })) catch return null;
        const body = std.fmt.bufPrint(buf[half..], "The computer locks {s}", .{whenText(&when_buf, t, now, zone)}) catch return null;
        return .{ .title = title, .body = body };
    }
};

const testing = std.testing;

test "the lock screen: typed by the keyboard's layout, Enter tries it" {
    const kit = try kete_panel.Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    const p = try kit.panel();
    defer p.destroy();
    p.setKeyboard(.gb);
    var entry: Entry = .{};
    const view: View = .{ .parental = .{ .on = true, .lock = .time, .until = 1794830400 }, .system_now = 1794800000, .entry = &entry };
    _ = p.draw(width, height, 0, view);
    _ = p.draw(width, height, 1, view);
    // Shift and 3: on a UK keyboard, a pound sign.
    for ([_][2]u32{ .{ 42, 1 }, .{ 4, 1 }, .{ 4, 0 }, .{ 42, 0 }, .{ 30, 1 }, .{ 30, 0 } }) |k| p.key(k[0], k[1] == 1);
    _ = p.draw(width, height, 2, view);
    try testing.expectEqualStrings("£a", entry.password());
    try testing.expect(!entry.submitted);
    p.key(28, true);
    p.key(28, false);
    try testing.expect(entry.submitted);
    // A try: the field empties.
    entry.clear();
    entry.wrong = true;
    const px = p.draw(width, height, 3, view).pixels;
    try testing.expectEqual(@as(usize, width * height), px.len);
    try testing.expect(px[(height / 2) * width + width / 2] >> 24 == 0xff);
    try testing.expectEqual(@as(u8, 0), entry.len);
}

test "warnings at ten, five and one minute left; again after a bonus" {
    var ws: Warnings = .{};
    var buf: [192]u8 = undefined;
    const now: i64 = 1_794_787_200; // Monday, 16 November 2026, midnight UTC
    var p: Parental = .{ .on = true, .limits = .{ .downtime = null }, .lock_at = now + 30 * 60 };
    try testing.expect(ws.due(p, now, .utc, &buf) == null);
    const w10 = ws.due(p, now + 20 * 60, .utc, &buf).?;
    try testing.expectEqualStrings("10 minutes left today", w10.title);
    try testing.expect(ws.due(p, now + 21 * 60, .utc, &buf) == null);
    try testing.expectEqualStrings("5 minutes left today", ws.due(p, now + 25 * 60, .utc, &buf).?.title);
    try testing.expectEqualStrings("1 minute left today", ws.due(p, now + 29 * 60, .utc, &buf).?.title);
    try testing.expect(ws.due(p, now + 29 * 60 + 30, .utc, &buf) == null);
    // Twenty minutes more: warned again as it runs out.
    p.lock_at = now + 50 * 60;
    try testing.expect(ws.due(p, now + 30 * 60, .utc, &buf) == null);
    try testing.expectEqualStrings("10 minutes left today", ws.due(p, now + 40 * 60, .utc, &buf).?.title);
    // Downtime starting.
    var d: Parental = .{ .on = true, .limits = .{ .downtime = .{ .start = 20 * 60, .end = 7 * 60 } }, .lock_at = now + 20 * 3600 };
    var wd: Warnings = .{};
    try testing.expectEqualStrings("Downtime in 5 minutes", (wd.due(d, now + 20 * 3600 - 5 * 60, .utc, &buf) orelse return error.NoWarning).title);
    // Locked: none.
    d.lock = .downtime;
    try testing.expect(wd.due(d, now + 21 * 3600, .utc, &buf) == null);
}

test "the next warning's time" {
    var ws: Warnings = .{};
    var buf: [192]u8 = undefined;
    const now: i64 = 1_794_787_200;
    const p: Parental = .{ .on = true, .limits = .{ .downtime = null }, .lock_at = now + 30 * 60 };
    try testing.expectEqual(@as(?i64, now + 20 * 60), ws.nextAt(p, now));
    _ = ws.due(p, now + 20 * 60, .utc, &buf);
    try testing.expectEqual(@as(?i64, now + 25 * 60), ws.nextAt(p, now + 20 * 60));
    try testing.expect(ws.nextAt(.{}, now) == null);
}

test "when it may be used again, in words" {
    var buf: [64]u8 = undefined;
    const now: i64 = 1_794_787_200 + 15 * 3600; // Monday 3 pm UTC
    try testing.expect(std.mem.startsWith(u8, whenText(&buf, now + 3600, now, .utc), "at "));
    try testing.expect(std.mem.startsWith(u8, whenText(&buf, now + 16 * 3600, now, .utc), "tomorrow at "));
    try testing.expect(std.mem.startsWith(u8, whenText(&buf, now + 4 * 86400, now, .utc), "on Friday at "));
}
