//! The Language page: the language and keyboard layout, and a field to
//! try the keyboard in.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
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
    rows.append(a, cx.make(kete.Text{ .text = "Language", .style = heading })) catch {};
    for (std.enums.values(locale.Language)) |l| rows.append(a, cx.make(kete.RadioRow(locale.Language){
        .value = l,
        .group_value = self.locale.language,
        .on_changed = if (self.actions != null) .of(picker, LocalePick.language) else null,
        .label = l.name(),
    })) catch {};
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = cx.make(kete.Text{ .text = "Keyboard", .style = heading }) })) catch {};
    for (std.enums.values(locale.Keyboard)) |k| rows.append(a, cx.make(kete.RadioRow(locale.Keyboard){
        .value = k,
        .group_value = self.locale.keyboard,
        .on_changed = if (self.actions != null) .of(picker, LocalePick.keyboard) else null,
        .label = k.name(),
    })) catch {};
    rows.append(a, cx.make(kete.Row{ .children = &.{cx.make(kete.TextField{ .placeholder = "Type here to try the keyboard", .width = 360 })} })) catch {};
    return b.page(rows.items);
}

/// Picking a language or keyboard (keeping the other as it is).
const LocalePick = struct {
    actions: ?*Actions,
    current: locale.Settings,

    fn language(p: *LocalePick, l: locale.Language) void {
        if (p.actions) |a| a.locale = .{ .language = l, .keyboard = p.current.keyboard };
    }

    fn keyboard(p: *LocalePick, k: locale.Keyboard) void {
        if (p.actions) |a| a.locale = .{ .language = p.current.language, .keyboard = k };
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
}
