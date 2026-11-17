//! The Language page: the language and keyboard layout (and a field to
//! try the keyboard in), and the time zone.

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

pub fn build(self: *const Settings, b: Builder) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.arena;
    const picker = a.create(LocalePick) catch return cx.make(kete.SizedBox.empty);
    picker.* = .{ .actions = self.actions, .current = self.locale };
    var rows: std.ArrayList(kete.Widget) = .empty;
    const heading: kete.TextStyle = .{ .size = 18, .color = t.on_surface_variant };
    rows.append(a, cx.make(kete.Text{ .text = locale.text("Language"), .style = heading })) catch {};
    rows.append(a, cx.make(kete.SizedBox{ .width = 380, .child = cx.make(kete_vc4.LanguagePicker{
        .language = self.locale.language,
        .on_changed = if (self.actions != null) .of(picker, LocalePick.language) else null,
        .height = 240,
    }) })) catch {};
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = cx.make(kete.Text{ .text = locale.text("Keyboard"), .style = heading }) })) catch {};
    for (std.enums.values(locale.Keyboard)) |k| rows.append(a, cx.make(kete.RadioRow(locale.Keyboard){
        .value = k,
        .group_value = self.locale.keyboard,
        .on_changed = if (self.actions != null) .of(picker, LocalePick.keyboard) else null,
        .label = k.name(),
    })) catch {};
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
                .on_press = if (self.actions != null) .of(picker, LocalePick.installPack) else null,
            })) catch {},
            .installing => line.append(a, cx.make(kete.Text{ .text = locale.text("Installing…"), .style = .{ .size = 15, .color = t.on_surface } })) catch {},
            else => {},
        }
        rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = line.items })) catch {};
    }
    rows.append(a, cx.make(kete.Row{ .children = &.{cx.make(kete.TextField{ .placeholder = locale.text("Type here to try the keyboard"), .width = 360 })} })) catch {};
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = cx.make(kete.Text{ .text = locale.text("Time zone"), .style = heading }) })) catch {};
    rows.append(a, cx.make(kete_vc4.TimeZonePicker{
        .zone = self.locale.timezone,
        .on_changed = if (self.actions != null) .of(picker, LocalePick.timezone) else null,
    })) catch {};
    return b.page(rows.items);
}

/// Picking a language or keyboard (keeping the other as it is).
const LocalePick = struct {
    actions: ?*Actions,
    current: locale.Settings,

    fn language(p: *LocalePick, l: locale.Language) void {
        if (p.actions) |a| a.locale = .{ .language = l, .keyboard = p.current.keyboard, .timezone = p.current.timezone };
    }

    fn installPack(p: *LocalePick) void {
        if (p.actions) |a| a.install_language_pack = true;
    }

    fn keyboard(p: *LocalePick, k: locale.Keyboard) void {
        if (p.actions) |a| a.locale = .{ .language = p.current.language, .keyboard = k, .timezone = p.current.timezone };
    }

    fn timezone(p: *LocalePick, z: locale.TimeZone) void {
        if (p.actions) |a| a.locale = .{ .language = p.current.language, .keyboard = p.current.keyboard, .timezone = z };
    }
};

const testing = std.testing;
const font = kete.font;

test "the language and keyboard: picking one keeps the other" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .locale = .{ .language = .en_gb, .keyboard = .gb } };
    u.frame(1600, 900, 0, settings);
    u.root.?.state(Settings.State).page = .language;
    u.frame(1600, 900, 1, settings);
    try testing.expect(view.findText(u.root.?, "English (Canada)") != null);
    view.click(u, view.findText(u.root.?, "English (Canada)").?);
    try testing.expectEqual(locale.Settings{ .language = .en_ca, .keyboard = .gb }, actions.locale.?);
    view.click(u, view.findText(u.root.?, "English (US)").?);
    try testing.expectEqual(locale.Settings{ .language = .en_gb, .keyboard = .us }, actions.locale.?);
    try testing.expect(view.findType(u.root.?, kete.TextField) != null);
    // The time zone, by area and city.
    try testing.expect(view.findText(u.root.?, "Time zone") != null);
    try testing.expect(view.findType(u.root.?, kete_vc4.TimeZonePicker) != null);
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
