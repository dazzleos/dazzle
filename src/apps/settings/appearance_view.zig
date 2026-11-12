//! The Appearance page: system colour scheme (Dark or Light), and the
//! desktop's background colour (the same in either).

const std = @import("std");
const ui = @import("ui");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;

pub const label = "Appearance";
pub const icon: ui.icons.Icon = .palette;

pub const State = struct {
    appearance: ui.theme.Settings = .{},
    actions: ?*Actions = null,

    fn setDark(st: *State) void {
        const acts = st.actions orelse return;
        var next = acts.appearance orelse st.appearance;
        next.theme = .dark;
        acts.appearance = next;
    }

    fn setLight(st: *State) void {
        const acts = st.actions orelse return;
        var next = acts.appearance orelse st.appearance;
        next.theme = .light;
        acts.appearance = next;
    }

    fn setBackground(comptime bg: ui.theme.Background) fn (*State) void {
        return struct {
            fn set(st: *State) void {
                const acts = st.actions orelse return;
                var next = acts.appearance orelse st.appearance;
                next.background = bg;
                acts.appearance = next;
            }
        }.set;
    }
};

pub fn build(self: *const Settings, b: Builder, state: *State) ui.Widget {
    const cx = b.cx;
    const a = cx.ui.arena();

    state.appearance = self.appearance;
    state.actions = self.actions;

    var rows: std.ArrayList(ui.Widget) = .empty;

    const theme_bar = cx.make(ui.PillBar{
        .children = &.{
            cx.make(ui.PillButton{
                .label = "Dark",
                .icon = .dark_mode,
                .selected = self.appearance.theme == .dark,
                .first = true,
                .on_press = if (self.actions != null) .of(state, State.setDark) else null,
            }),
            cx.make(ui.PillButton{
                .label = "Light",
                .icon = .light_mode,
                .selected = self.appearance.theme == .light,
                .last = true,
                .on_press = if (self.actions != null) .of(state, State.setLight) else null,
            }),
        },
    });

    rows.append(a, cx.make(ui.Row{
        .cross_axis_alignment = .center,
        .spacing = 12,
        .children = &.{
            b.label("Theme"),
            theme_bar,
        },
    })) catch {};

    const backgrounds = comptime std.enums.values(ui.theme.Background);
    var pills: [backgrounds.len]ui.Widget = undefined;
    inline for (backgrounds, &pills, 0..) |bg, *pill, i| {
        pill.* = cx.make(ui.PillButton{
            .label = bg.name(),
            .selected = self.appearance.background == bg,
            .first = i == 0,
            .last = i == backgrounds.len - 1,
            .on_press = if (self.actions != null) .of(state, State.setBackground(bg)) else null,
        });
    }
    // Under its label: five do not fit beside it in the smallest window.
    rows.append(a, cx.make(ui.Column{
        .cross_axis_alignment = .start,
        .spacing = 8,
        .children = &.{
            b.label("Background"),
            cx.make(ui.PillBar{ .children = a.dupe(ui.Widget, &pills) catch &.{} }),
        },
    })) catch {};

    return b.page(rows.items);
}

const testing = std.testing;
const font = @import("font");

test "Appearance page toggles between Dark and Light theme" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();

    const d = view.sample();
    var appearance: ui.theme.Settings = .{ .theme = .dark };
    var actions: Actions = .{};

    var frame_no: u64 = 1;
    u.frame(1280, 720, frame_no, Settings{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .appearance = appearance,
    });
    _ = view.showPage(u, .appearance);
    frame_no += 1;
    u.frame(1280, 720, frame_no, Settings{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .appearance = appearance,
    });

    try testing.expect(view.findText(u.root.?, "Theme") != null);
    try testing.expect(view.findText(u.root.?, "Dark") != null);
    try testing.expect(view.findText(u.root.?, "Light") != null);

    // Clicking Light sets actions.appearance.theme = .light.
    view.click(u, view.up(view.findText(u.root.?, "Light").?, ui.Pressable).?);
    try testing.expectEqual(ui.theme.Mode.light, actions.appearance.?.theme);
    appearance = actions.appearance.?;
    u.theme = appearance.theme.scheme();
    actions = .{};

    frame_no += 1;
    u.frame(1280, 720, frame_no, Settings{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .appearance = appearance,
    });
    try testing.expectEqual(ui.Theme.light.surface, u.theme.surface);

    // Clicking Dark sets actions.appearance.theme = .dark.
    view.click(u, view.up(view.findText(u.root.?, "Dark").?, ui.Pressable).?);
    try testing.expectEqual(ui.theme.Mode.dark, actions.appearance.?.theme);

    // Picking a background keeps the theme.
    try testing.expect(view.findText(u.root.?, "Background") != null);
    view.click(u, view.up(view.findText(u.root.?, "Navy").?, ui.Pressable).?);
    try testing.expectEqual(ui.theme.Background.navy, actions.appearance.?.background);
    try testing.expectEqual(ui.theme.Mode.dark, actions.appearance.?.theme);
}
