//! The Display page: the screen's orientation, landscape or portrait. A
//! display the other way (the Touch Display 2 is upright, a monitor wide)
//! is turned a quarter: the shell turns at once, the boot screen from the
//! next start (see `sys.system.Orientation`).

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const sys = @import("sys");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;
const Orientation = sys.system.Orientation;

pub const label = "Display";
pub const icon: kete.IconName = .screen_rotation;

/// The orientation (null: not known), and whether changing it was refused.
pub const Display = struct {
    orientation: ?Orientation = null,
    failed: bool = false,
};

pub const State = struct {
    actions: ?*Actions = null,

    pub fn choose(st: *State, o: Orientation) void {
        if (st.actions) |a| a.orientation = o;
    }
};

pub const OrientationMenu = kete.Select(Orientation);

pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.arena;
    state.actions = self.actions;
    const d = self.display;
    var rows: std.ArrayList(kete.Widget) = .empty;
    const options = a.dupe(OrientationMenu.Option, &.{
        .labeled(.landscape, locale.text("Landscape")),
        .labeled(.portrait, locale.text("Portrait")),
    }) catch &.{};
    rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = a.dupe(kete.Widget, &.{
        b.label(locale.text("Orientation")),
        cx.make(OrientationMenu{
            .options = options,
            .value = d.orientation,
            .on_changed = if (self.actions != null and d.orientation != null) .of(state, State.choose) else null,
        }),
    }) catch &.{} })) catch {};
    if (d.failed) rows.append(a, cx.make(kete.Text{ .text = locale.text("It could not be changed"), .style = .{ .size = 15, .color = t.@"error" } })) catch {};
    return b.page(rows.items);
}

const testing = std.testing;
const font = kete.font;

test "the orientation, chosen" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .display = .{ .orientation = .landscape } };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .display;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "Landscape") != null);
    u.root.?.state(Settings.State).display.choose(.portrait);
    try testing.expectEqual(@as(?Orientation, .portrait), actions.orientation);
    settings.display = .{ .orientation = .portrait };
    u.frame(1920, 960, 2, settings);
    try testing.expect(view.findText(u.root.?, "Portrait") != null);
    try testing.expect(!view.overflows(u.root.?));
}
