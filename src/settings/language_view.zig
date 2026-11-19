//! The Language page: the language and keyboard layout chosen, each with a
//! button to change it (in a dialog: the list to choose from, with a field
//! to search it), and a picture of the keyboard's keys (and a field to try
//! it in); and the time zone.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const kete_vc4 = @import("kete_vc4");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;

pub const label = "Language";
pub const icon: kete.IconName = .language;

pub fn build(self: *const Settings, b: Builder, st: *State) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.arena;
    st.current = self.locale;
    st.actions = self.actions;
    const picker = a.create(LocalePick) catch return cx.make(kete.SizedBox.empty);
    picker.* = .{ .actions = self.actions, .current = self.locale };
    var rows: std.ArrayList(kete.Widget) = .empty;
    const heading: kete.TextStyle = .{ .size = 18, .color = t.on_surface_variant };
    const can = self.actions != null;
    rows.append(a, cx.make(kete.Text{ .text = locale.text("Language"), .style = heading })) catch {};
    rows.append(a, chosenRow(cx, self.locale.language.name(), if (can) .of(st, State.openLanguage) else null)) catch {};
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = cx.make(kete.Text{ .text = locale.text("Keyboard"), .style = heading }) })) catch {};
    rows.append(a, chosenRow(cx, self.locale.keyboard.name(), if (can) .of(st, State.openKeyboard) else null)) catch {};
    rows.append(a, cx.make(kete_vc4.KeyboardPicture{ .keyboard = self.locale.keyboard })) catch {};
    // Its language pack: basic input until it is installed.
    if (self.language_pack != .none) {
        const installed = self.language_pack == .installed;
        var line: std.ArrayList(kete.Widget) = .empty;
        line.append(a, cx.make(kete.Text{
            .text = if (installed) locale.text("Its language pack is installed") else locale.text("Basic input until its language pack is installed"),
            .style = .{ .size = 15, .color = t.on_surface_variant },
        })) catch {};
        switch (self.language_pack) {
            .offered => line.append(a, cx.make(kete.OutlinedButton{
                .label = locale.text("Install"),
                .on_press = if (can) .of(picker, LocalePick.installPack) else null,
            })) catch {},
            .installing => line.append(a, cx.make(kete.Text{ .text = locale.text("Installing…"), .style = .{ .size = 15, .color = t.on_surface } })) catch {},
            else => {},
        }
        rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = line.items })) catch {};
    }
    rows.append(a, cx.make(kete.Row{ .children = &.{cx.make(kete.TextField{ .placeholder = locale.text("Type here to try the keyboard"), .width = 360 })} })) catch {};
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = cx.make(kete.Text{ .text = locale.text("Time zone"), .style = heading }) })) catch {};
    var zone_buf: [96]u8 = undefined;
    rows.append(a, chosenRow(cx, a.dupe(u8, self.locale.timezone.label(&zone_buf)) catch "", if (can) .of(st, State.openTimeZone) else null)) catch {};
    return b.page(rows.items);
}

/// What is chosen, and a button to change it.
fn chosenRow(cx: *kete.BuildContext, name: []const u8, on_change: ?kete.Callback) kete.Widget {
    return cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = cx.arena.dupe(kete.Widget, &.{
        cx.make(kete.Text{ .text = name, .style = .{ .size = 16, .color = cx.theme().on_surface }, .wrap = false }),
        cx.make(kete.OutlinedButton{ .label = locale.text("Change"), .on_press = on_change }),
    }) catch &.{} });
}

/// The page's state: the dialog open to change the language or the
/// keyboard, and what is picked in it (put in place with Apply).
pub const State = struct {
    dialog: enum { none, language, keyboard, timezone } = .none,
    language: locale.Language = .en_gb,
    keyboard: locale.Keyboard = .us,
    timezone: locale.TimeZone = .utc,
    /// As last built.
    current: locale.Settings = .{},
    actions: ?*Actions = null,

    fn openLanguage(st: *State) void {
        st.language = st.current.language;
        st.dialog = .language;
    }

    fn openKeyboard(st: *State) void {
        st.keyboard = st.current.keyboard;
        st.dialog = .keyboard;
    }

    fn openTimeZone(st: *State) void {
        st.timezone = st.current.timezone;
        st.dialog = .timezone;
    }

    fn pickTimeZone(st: *State, z: locale.TimeZone) void {
        st.timezone = z;
    }

    fn pickLanguage(st: *State, l: locale.Language) void {
        st.language = l;
    }

    fn pickKeyboard(st: *State, k: locale.Keyboard) void {
        st.keyboard = k;
    }

    fn apply(st: *State) void {
        var l = st.current;
        switch (st.dialog) {
            .language => l.language = st.language,
            .keyboard => l.keyboard = st.keyboard,
            .timezone => l.timezone = st.timezone,
            .none => {},
        }
        if (st.actions) |a| if (!std.meta.eql(l, st.current)) {
            a.locale = l;
        };
        st.dialog = .none;
    }

    fn cancel(st: *State) void {
        st.dialog = .none;
    }
};

/// The page with the dialog changing the language or keyboard over it, if
/// one is open.
pub fn withDialog(self: *const Settings, b: Builder, st: *State, child: kete.Widget) kete.Widget {
    const cx = b.cx;
    if (st.dialog == .none or self.actions == null) return child;
    const content = switch (st.dialog) {
        .language => cx.make(kete_vc4.LanguagePicker{ .language = st.language, .on_changed = .of(st, State.pickLanguage), .height = 280 }),
        .timezone => cx.make(kete_vc4.TimeZoneMap{ .zone = st.timezone, .on_changed = .of(st, State.pickTimeZone), .width = 560 }),
        else => cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = cx.arena.dupe(kete.Widget, &.{
            cx.make(kete_vc4.KeyboardPicker{ .keyboard = st.keyboard, .on_changed = .of(st, State.pickKeyboard), .height = 200 }),
            cx.make(kete_vc4.KeyboardPicture{ .keyboard = st.keyboard, .unit = 24 }),
        }) catch &.{} }),
    };
    return cx.make(kete.Dialog{
        .icon = switch (st.dialog) {
            .language => .language,
            .timezone => null,
            else => .keyboard,
        },
        .title = switch (st.dialog) {
            .language => locale.text("Language"),
            .timezone => locale.text("Time zone"),
            else => locale.text("Keyboard"),
        },
        .content = content,
        .confirm_label = locale.text("Apply"),
        .on_confirm = .of(st, State.apply),
        .dismiss_label = locale.text("Cancel"),
        .on_dismiss = .of(st, State.cancel),
        .width = switch (st.dialog) {
            .language => 440,
            .timezone => 608,
            else => 480,
        },
        .child = child,
    });
}

/// Asking for the keyboard's language pack.
const LocalePick = struct {
    actions: ?*Actions,
    current: locale.Settings,

    fn installPack(p: *LocalePick) void {
        if (p.actions) |a| a.install_language_pack = true;
    }
};

const testing = std.testing;
const font = kete.font;

test "the language and keyboard: changed in a dialog, keeping the other" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .locale = .{ .language = .en_gb, .keyboard = .gb } };
    u.frame(1600, 900, 0, settings);
    u.root.?.state(Settings.State).page = .language;
    u.frame(1600, 900, 1, settings);
    // The names chosen, the keyboard's keys, and no lists until Change.
    try testing.expect(view.findText(u.root.?, "English (United Kingdom)") != null);
    try testing.expect(view.findText(u.root.?, "English (Canada)") == null);
    try testing.expect(view.findType(u.root.?, kete_vc4.KeyboardPicture) != null);
    // Change the language: a dialog with the list; picked, then Apply.
    view.click(u, view.up(view.findText(u.root.?, "Change").?, kete.OutlinedButton).?);
    u.frame(1600, 900, 2, settings);
    try testing.expect(view.findType(u.root.?, kete.Dialog) != null);
    view.click(u, view.findText(u.root.?, "English (Canada)").?);
    u.frame(1600, 900, 3, settings);
    try testing.expect(actions.locale == null);
    view.click(u, view.up(view.findText(u.root.?, "Apply").?, kete.FilledButton).?);
    try testing.expectEqual(locale.Settings{ .language = .en_ca, .keyboard = .gb }, actions.locale.?);
    actions.locale = null;
    u.frame(1600, 900, 4, settings);
    try testing.expect(view.findType(u.root.?, kete.Dialog) == null);
    // Change the keyboard (the second Change), and Cancel: nothing.
    const second = view.findType(view.up(view.findText(u.root.?, "English (UK)").?, kete.Row).?, kete.OutlinedButton).?;
    view.click(u, second);
    u.frame(1600, 900, 5, settings);
    view.click(u, view.findText(u.root.?, "English (US)").?);
    u.frame(1600, 900, 6, settings);
    view.click(u, view.up(view.findText(u.root.?, "Cancel").?, kete.TextButton).?);
    try testing.expect(actions.locale == null);
    // Again, and Apply.
    u.frame(1600, 900, 7, settings);
    view.click(u, view.findType(view.up(view.findText(u.root.?, "English (UK)").?, kete.Row).?, kete.OutlinedButton).?);
    u.frame(1600, 900, 8, settings);
    view.click(u, view.findText(u.root.?, "English (US)").?);
    u.frame(1600, 900, 9, settings);
    view.click(u, view.up(view.findText(u.root.?, "Apply").?, kete.FilledButton).?);
    try testing.expectEqual(locale.Settings{ .language = .en_gb, .keyboard = .us }, actions.locale.?);
    try testing.expect(view.findType(u.root.?, kete.TextField) != null);
    // The time zone, by name; changed on the map.
    try testing.expect(view.findText(u.root.?, "Time zone") != null);
    try testing.expect(view.findText(u.root.?, "UTC") != null);
}

test "a keyboard's language pack: Install, then installed" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .locale = .{ .language = .en_gb, .keyboard = .romaji }, .language_pack = .offered };
    u.frame(1600, 1600, 0, settings);
    u.root.?.state(Settings.State).page = .language;
    u.frame(1600, 1600, 1, settings);
    try testing.expect(view.findText(u.root.?, "Basic input until its language pack is installed") != null);
    view.click(u, view.up(view.findText(u.root.?, "Install").?, kete.OutlinedButton).?);
    try testing.expect(actions.install_language_pack);
    settings.language_pack = .installed;
    u.frame(1600, 1600, 2, settings);
    try testing.expect(view.findText(u.root.?, "Its language pack is installed") != null);
    try testing.expect(view.findText(u.root.?, "Install") == null);
    // None for a keyboard without one.
    settings.language_pack = .none;
    u.frame(1600, 1600, 3, settings);
    try testing.expect(view.findText(u.root.?, "Its language pack is installed") == null);
}

test "the time zone: changed on a map" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .locale = .{ .language = .en_gb, .keyboard = .gb } };
    u.frame(1600, 1000, 0, settings);
    u.root.?.state(Settings.State).page = .language;
    u.frame(1600, 1000, 1, settings);
    // Its Change: the third.
    view.click(u, view.findType(view.up(view.findText(u.root.?, "UTC").?, kete.Row).?, kete.OutlinedButton).?);
    u.frame(1600, 1000, 2, settings);
    const map = view.findType(u.root.?, kete_vc4.TimeZoneMap.Map).?;
    // Auckland, clicked on the map, then Apply.
    const auckland = locale.TimeZone.fromName("Pacific/Auckland").?;
    const pl = auckland.place().?;
    const q = kete_vc4.TimeZoneMap.Map.at(map.size, pl.lat, pl.lon);
    view.clickAt(u, .{ map.position()[0] + q[0], map.position()[1] + q[1] });
    u.frame(1600, 1000, 3, settings);
    try testing.expect(view.findText(u.root.?, "Auckland (Pacific)") != null);
    view.click(u, view.up(view.findText(u.root.?, "Apply").?, kete.FilledButton).?);
    try testing.expectEqual(auckland, actions.locale.?.timezone);
    try testing.expectEqual(locale.Language.en_gb, actions.locale.?.language);
}
