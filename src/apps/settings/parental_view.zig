//! The Parental controls page (see `sys.parental`; the system manager
//! keeps them). While they are off: how long the computer may be used on
//! weekdays and at weekends, downtime, and whether apps may
//! be installed or removed; turning them on asks for a password, twice.
//! While they are on: not those, but how today goes, for whoever is using
//! it to see (the time used, what is left, when it locks), and for a
//! parent, with the password, more time today or turning them off.

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const locale = @import("locale");
const info = @import("info.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;
const Limits = sys.parental.Limits;
const Password = info.Str(sys.parental.max_password);

pub const label = "Parental";
pub const icon: kete.IconName = .family_restroom;

/// What a parent asks for, with the password.
pub const ParentalOn = struct { password: Password, limits: Limits };
pub const Bonus = struct { password: Password, minutes: u16 };

pub const State = struct {
    /// Where the forms' requests go (the window's, as the page is built).
    actions: ?*Actions = null,
    /// The limits being chosen (from the system manager's, the first time
    /// the page shows).
    draft: Limits = .{},
    have_draft: bool = false,
    form: Form = .none,
    password: Password = .{},
    again: Password = .{},
    /// The passwords given were not the same (or none was).
    mismatch: bool = false,
    bonus: u16 = 30,
    /// Each form's fields start empty.
    form_id: u32 = 0,

    pub const Form = enum { none, turn_on, turn_off, bonus };

    fn open(st: *State, f: Form) void {
        st.form = f;
        st.password = .{};
        st.again = .{};
        st.mismatch = false;
        st.form_id +%= 1;
    }

    fn openTurnOn(st: *State) void {
        st.open(.turn_on);
    }

    fn openTurnOff(st: *State) void {
        st.open(.turn_off);
    }

    fn openBonus(st: *State) void {
        st.open(.bonus);
    }

    fn cancel(st: *State) void {
        st.open(.none);
    }

    fn setPassword(st: *State, text: []const u8) void {
        st.password.set(text);
        st.mismatch = false;
    }

    fn setAgain(st: *State, text: []const u8) void {
        st.again.set(text);
        st.mismatch = false;
    }

    fn setOn(st: *State, on: bool) void {
        if (on) st.open(.turn_on) else st.open(.none);
    }
};

/// Durations to choose from, in minutes (0: not at all; null: unlimited).
const durations = [_]?u16{ 0, 30, 60, 90, 120, 150, 180, 240, 300, 360, 480, null };
const bonuses = [_]u16{ 15, 30, 60, 120 };

pub fn build(self: *const Settings, b: Builder, st: *State) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.arena;
    st.actions = self.actions;
    const p = self.parental orelse return b.page(&.{b.value("Asking the system…")});
    if (!st.have_draft) {
        st.draft = p.limits;
        st.have_draft = true;
    }
    var rows: std.ArrayList(kete.Widget) = .empty;
    if (self.parental_wrong) rows.append(a, cx.make(kete.Text{ .text = "That is not the password", .style = .{ .size = 16, .color = t.@"error" } })) catch {};
    if (p.on) {
        // How today goes, for whoever uses it to see: how much of the
        // day's time is used, what is left (more with the password), and
        // when downtime comes; and turning parental controls off.
        const now = p.now(sys.realtimeSec());
        rows.append(a, cx.make(kete.Text{ .text = "Parental controls", .style = .{ .size = 24, .color = t.on_surface }, .wrap = false })) catch {};
        if (p.allowed) |allowed| {
            const fraction: f32 = if (allowed == 0) 1 else @min(1, @as(f32, @floatFromInt(p.used)) / @as(f32, @floatFromInt(allowed)));
            rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = a.dupe(kete.Widget, &.{
                cx.make(kete.Expanded{ .child = cx.make(kete.ProgressBar{ .value = fraction, .height = 10 }) }),
                cx.make(kete.Text{ .text = cx.fmt("{d:.0}%", .{fraction * 100}), .style = .{ .size = 18, .color = t.on_surface }, .wrap = false }),
            }) catch &.{} })) catch {};
        }
        var buf: [64]u8 = undefined;
        const remaining = if (p.allowed) |allowed| cx.fmt("{s} remaining today", .{durationAnd(&buf, allowed -| p.used)}) else "No limit today";
        rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.Expanded{ .child = b.value(remaining) }),
            cx.make(kete.OutlinedButton{ .label = "Add time", .icon = .add, .on_press = if (self.actions != null) .of(st, State.openBonus) else null }),
        }) catch &.{} })) catch {};
        if (p.limits.downtime) |d| if (p.lock != .downtime) {
            const local = sys.parental.Local.of(now, sys.parental.utc_offset);
            const secs = @mod(@as(i64, d.start) * 60 - local.second, std.time.s_per_day);
            var dbuf: [64]u8 = undefined;
            rows.append(a, b.value(cx.fmt("Downtime in {s}", .{durationAnd(&dbuf, @intCast(@divFloor(secs + 59, 60)))}))) catch {};
        };
        rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
            cx.make(kete.OutlinedButton{ .label = "Turn off parental controls", .on_press = if (self.actions != null) .of(st, State.openTurnOff) else null }),
        }) catch &.{} }) })) catch {};
        return b.page(rows.items);
    }
    // Off: the limits to choose, and turning them on.
    // Titles, each with its switch at the right.
    rows.append(a, titleRow(cx, "Parental controls", 24, st.form == .turn_on, if (self.actions != null) .of(st, State.setOn) else null)) catch {};
    const limited = st.draft.weekday != null or st.draft.weekend != null;
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = titleRow(cx, "Daily limits", 20, limited, .of(st, setLimited)) })) catch {};
    if (limited) {
        rows.append(a, choiceRow(b, "Weekdays", durationOptions(cx), indexOfDuration(st.draft.weekday), .of(st, setWeekday))) catch {};
        rows.append(a, choiceRow(b, "Weekends", durationOptions(cx), indexOfDuration(st.draft.weekend), .of(st, setWeekend))) catch {};
    }
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 20 }, .child = titleRow(cx, "Downtime", 20, st.draft.downtime != null, .of(st, setDowntime)) })) catch {};
    if (st.draft.downtime) |d| {
        rows.append(a, choiceRow(b, "From", timeOptions(cx), d.start / 30, .of(st, setDowntimeStart))) catch {};
        rows.append(a, choiceRow(b, "To", timeOptions(cx), d.end / 30, .of(st, setDowntimeEnd))) catch {};
    }
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 20 }, .child = titleRow(cx, "Stop apps being installed or removed", 18, st.draft.block_software, .of(st, setBlockSoftware)) })) catch {};
    return b.page(rows.items);
}

/// The page's window with the password asked for over it, as a parent
/// turns parental controls on or off, or gives more time (a modal dialog).
pub fn withDialog(self: *const Settings, b: Builder, st: *State, child: kete.Widget) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.arena;
    if (st.form == .none or self.actions == null) return child;
    var items: std.ArrayList(kete.Widget) = .empty;
    const go: kete.Callback = switch (st.form) {
        .turn_on => .of(st, submitTurnOn),
        .turn_off => .of(st, submitTurnOff),
        else => .of(st, submitBonus),
    };
    if (st.form == .bonus) {
        const opts = a.alloc(kete.MenuItem, bonuses.len) catch return child;
        for (opts, bonuses) |*o, m| {
            var buf: [32]u8 = undefined;
            o.* = .{ .label = cx.fmt("{s}", .{duration(&buf, m)}) };
        }
        items.append(a, cx.make(kete.DropdownMenu{ .options = opts, .selected = std.mem.indexOfScalar(u16, &bonuses, st.bonus), .on_selected = .of(st, setBonus), .width = 320 })) catch {};
    }
    const key = @as(u64, st.form_id) << 8 | 0x7a000000;
    items.append(a, cx.make(kete.TextField{ .placeholder = "Password", .obscure = true, .max_len = sys.parental.max_password, .width = 320, .initial = st.password.slice(), .on_changed = .of(st, State.setPassword), .on_submit = go, .autofocus = true }).withKey(key)) catch {};
    if (st.form == .turn_on) items.append(a, cx.make(kete.TextField{ .placeholder = "Password again", .obscure = true, .max_len = sys.parental.max_password, .width = 320, .initial = st.again.slice(), .on_changed = .of(st, State.setAgain), .on_submit = go }).withKey(key | 1)) catch {};
    if (st.mismatch) items.append(a, cx.make(kete.Text{ .text = if (st.form == .turn_on) "Give the same password twice" else "Give the password", .style = .{ .size = 15, .color = t.@"error" } })) catch {};
    return cx.make(kete.Dialog{
        .icon = .lock,
        .title = switch (st.form) {
            .turn_on => "Turn on parental controls",
            .turn_off => "Turn off parental controls",
            else => "More time today",
        },
        .description = switch (st.form) {
            .turn_on => "Choose a password for a parent to unlock with. It is asked for each time parental controls are turned on.",
            .turn_off => "Give the parent's password.",
            else => "How much more time, and the parent's password.",
        },
        .content = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 10, .children = items.items }),
        .confirm_label = switch (st.form) {
            .turn_on => "Turn on",
            .turn_off => "Turn off",
            else => "Give it",
        },
        .on_confirm = go,
        .dismiss_label = "Cancel",
        .on_dismiss = .of(st, State.cancel),
        .width = 400,
        .child = child,
    });
}

/// A title, its switch at the right.
fn titleRow(cx: *kete.BuildContext, text: []const u8, size: f32, value: bool, on_changed: ?kete.ValueCallback(bool)) kete.Widget {
    return cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = cx.arena.dupe(kete.Widget, &.{
        cx.make(kete.Text{ .text = text, .style = .{ .size = size, .color = cx.theme().on_surface }, .wrap = false }),
        cx.make(kete.Expanded{ .child = cx.make(kete.SizedBox.empty) }),
        cx.make(kete.Switch{ .value = value, .on_changed = on_changed }),
    }) catch &.{} });
}

fn choiceRow(b: Builder, name: []const u8, options: []const kete.MenuItem, selected: ?usize, on: kete.ValueCallback(usize)) kete.Widget {
    const cx = b.cx;
    return cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = cx.arena.dupe(kete.Widget, &.{
        b.label(name),
        cx.make(kete.DropdownMenu{ .options = options, .selected = selected, .on_selected = on, .width = 220 }),
    }) catch &.{} });
}

fn submitTurnOn(st: *State) void {
    const actions = st.actions orelse return;
    if (st.password.len == 0 or !std.mem.eql(u8, st.password.slice(), st.again.slice())) {
        st.mismatch = true;
        return;
    }
    actions.parental_on = .{ .password = st.password, .limits = st.draft };
    st.open(.none);
}

fn submitTurnOff(st: *State) void {
    const actions = st.actions orelse return;
    if (st.password.len == 0) {
        st.mismatch = true;
        return;
    }
    actions.parental_off = st.password;
    st.open(.none);
}

fn submitBonus(st: *State) void {
    const actions = st.actions orelse return;
    if (st.password.len == 0) {
        st.mismatch = true;
        return;
    }
    actions.parental_bonus = .{ .password = st.password, .minutes = st.bonus };
    st.open(.none);
}

/// Daily limits, or none (the time unlimited).
fn setLimited(st: *State, on: bool) void {
    st.draft.weekday = if (on) 120 else null;
    st.draft.weekend = if (on) 180 else null;
}

fn setWeekday(st: *State, i: usize) void {
    if (i < durations.len) st.draft.weekday = durations[i];
}

fn setWeekend(st: *State, i: usize) void {
    if (i < durations.len) st.draft.weekend = durations[i];
}

fn setDowntime(st: *State, on: bool) void {
    st.draft.downtime = if (on) .{ .start = 20 * 60, .end = 7 * 60 } else null;
}

fn setDowntimeStart(st: *State, i: usize) void {
    if (st.draft.downtime) |*d| d.start = @intCast(@min(i, 47) * 30);
}

fn setDowntimeEnd(st: *State, i: usize) void {
    if (st.draft.downtime) |*d| d.end = @intCast(@min(i, 47) * 30);
}

fn setBlockSoftware(st: *State, on: bool) void {
    st.draft.block_software = on;
}

fn setBonus(st: *State, i: usize) void {
    if (i < bonuses.len) st.bonus = bonuses[i];
}

fn indexOfDuration(m: ?u16) ?usize {
    for (durations, 0..) |d, i| if (d == m) return i;
    return null;
}

fn durationOptions(cx: *kete.BuildContext) []const kete.MenuItem {
    const opts = cx.arena.alloc(kete.MenuItem, durations.len) catch return &.{};
    for (opts, durations) |*o, d| {
        var buf: [32]u8 = undefined;
        o.* = .{ .label = cx.fmt("{s}", .{limitText(&buf, d)}) };
    }
    return opts;
}

/// Every half hour of the day.
fn timeOptions(cx: *kete.BuildContext) []const kete.MenuItem {
    const opts = cx.arena.alloc(kete.MenuItem, 48) catch return &.{};
    for (opts, 0..) |*o, i| {
        var buf: [16]u8 = undefined;
        o.* = .{ .label = cx.fmt("{s}", .{clockOf(&buf, @intCast(i * 30))}) };
    }
    return opts;
}

/// "Unlimited", "Not allowed", "45 minutes", "1 hour", "2 hours 30 minutes".
fn limitText(buf: []u8, m: ?u16) []const u8 {
    const minutes = m orelse return "Unlimited";
    if (minutes == 0) return "Not allowed";
    return duration(buf, minutes);
}

/// "1 hour and 18 minutes", "45 minutes", "2 hours".
fn durationAnd(buf: []u8, minutes: u32) []const u8 {
    const h = minutes / 60;
    const m = minutes % 60;
    if (h == 0 or m == 0) return duration(buf, minutes);
    return std.fmt.bufPrint(buf, "{d} hour{s} and {d} minute{s}", .{ h, if (h == 1) "" else "s", m, if (m == 1) "" else "s" }) catch "";
}

fn duration(buf: []u8, minutes: u32) []const u8 {
    const h = minutes / 60;
    const m = minutes % 60;
    return (if (h == 0)
        std.fmt.bufPrint(buf, "{d} minute{s}", .{ m, if (m == 1) "" else "s" })
    else if (m == 0)
        std.fmt.bufPrint(buf, "{d} hour{s}", .{ h, if (h == 1) "" else "s" })
    else
        std.fmt.bufPrint(buf, "{d} hour{s} {d} minute{s}", .{ h, if (h == 1) "" else "s", m, if (m == 1) "" else "s" })) catch "";
}

fn clockOf(buf: []u8, minute_of_day: u16) []const u8 {
    return locale.formatClock(buf, minute_of_day / 60, minute_of_day % 60);
}

/// "at 7:30 pm", "tomorrow at 7:00 am", "on Saturday at 7:00 am".
fn when(buf: []u8, t: i64, now: i64, utc_offset: i16) []const u8 {
    const at = sys.parental.Local.of(t, utc_offset);
    const today = sys.parental.Local.of(now, utc_offset);
    var clock_buf: [16]u8 = undefined;
    const clock = clockOf(&clock_buf, at.minute());
    const names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const days = at.day - today.day;
    return (if (days <= 0)
        std.fmt.bufPrint(buf, "At {s}", .{clock})
    else if (days == 1)
        std.fmt.bufPrint(buf, "Tomorrow at {s}", .{clock})
    else
        std.fmt.bufPrint(buf, "On {s} at {s}", .{ names[at.weekday], clock })) catch "";
}

const testing = std.testing;
const font = kete.font;

test "off: the limits are chosen, and turning on asks for the password twice" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .parental = .{} };
    u.frame(1600, 900, 0, settings);
    _ = view.showPage(u, .parental);
    u.frame(1600, 900, 1, settings);
    try testing.expect(view.findText(u.root.?, "Weekdays") != null);
    try testing.expect(view.findText(u.root.?, "2 hours") != null);
    try testing.expect(view.findText(u.root.?, "Stop apps being installed or removed") != null);
    // Turned on: the form, which wants the same password twice.
    const st = &view.settingsState(u).?.parental;
    st.setOn(true);
    u.frame(1600, 900, 2, settings);
    try testing.expect(view.findText(u.root.?, "Turn on parental controls") != null);
    try testing.expect(view.findType(u.root.?, kete.Dialog) != null);
    st.setPassword("sesame");
    st.setAgain("sesamE");
    submitTurnOn(st);
    try testing.expect(st.mismatch and actions.parental_on == null);
    st.setAgain("sesame");
    setWeekday(st, 2);
    submitTurnOn(st);
    try testing.expectEqualStrings("sesame", actions.parental_on.?.password.slice());
    try testing.expectEqual(@as(?u16, 60), actions.parental_on.?.limits.weekday);
    try testing.expectEqual(State.Form.none, st.form);
}

test "on: today's use, not the settings; a parent turns them off or gives more time" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const now = sys.realtimeSec();
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .parental = .{
        .on = true,
        .limits = .{ .weekday = 120, .weekend = 120, .downtime = null },
        .used = 42,
        .allowed = 150,
        .bonus = 30,
        .lock_at = now + 108 * 60,
    } };
    u.frame(1600, 900, 0, settings);
    _ = view.showPage(u, .parental);
    u.frame(1600, 900, 1, settings);
    // 42 of 150 minutes: 28%, an hour and 48 minutes left.
    try testing.expect(view.findText(u.root.?, "28%") != null);
    try testing.expect(view.findText(u.root.?, "1 hour and 48 minutes remaining today") != null);
    try testing.expect(view.findText(u.root.?, "Add time") != null);
    try testing.expect(view.findText(u.root.?, "Turn off parental controls") != null);
    try testing.expect(view.findText(u.root.?, "Weekdays") == null);
    try testing.expect(view.findType(u.root.?, kete.DropdownMenu) == null);
    try testing.expect(view.findText(u.root.?, "Stop apps being installed or removed") == null);
    const st = &view.settingsState(u).?.parental;
    st.openBonus();
    setBonus(st, 2);
    st.setPassword("sesame");
    submitBonus(st);
    try testing.expectEqual(@as(u16, 60), actions.parental_bonus.?.minutes);
    st.openTurnOff();
    submitTurnOff(st);
    try testing.expect(st.mismatch and actions.parental_off == null);
    st.setPassword("sesame");
    submitTurnOff(st);
    try testing.expectEqualStrings("sesame", actions.parental_off.?.slice());
}

test "words for durations and limits" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Unlimited", limitText(&buf, null));
    try testing.expectEqualStrings("Not allowed", limitText(&buf, 0));
    try testing.expectEqualStrings("1 hour", duration(&buf, 60));
    try testing.expectEqualStrings("2 hours 30 minutes", duration(&buf, 150));
    try testing.expectEqualStrings("1 minute", duration(&buf, 1));
    try testing.expectEqualStrings("1 hour and 1 minute", durationAnd(&buf, 61));
    try testing.expectEqualStrings("2 hours", durationAnd(&buf, 120));
}
