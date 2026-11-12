//! The Appearance page: system colour scheme (Dark or Light), and the
//! desktop's background colour (the same in either), picked from swatches.

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

    // A swatch of each colour, in rows of four under its label; the one
    // chosen is ringed, as a radio button is.
    const backgrounds = comptime std.enums.values(ui.theme.Background);
    var swatch_rows: [(backgrounds.len + swatches_per_row - 1) / swatches_per_row]ui.Widget = undefined;
    inline for (&swatch_rows, 0..) |*row, r| {
        const from = r * swatches_per_row;
        const in_row = backgrounds[from..@min(from + swatches_per_row, backgrounds.len)];
        var swatches: [in_row.len]ui.Widget = undefined;
        inline for (in_row, &swatches) |bg, *sw| {
            sw.* = swatch(cx, bg, self.appearance.background == bg, if (self.actions != null) .of(state, State.setBackground(bg)) else null);
        }
        row.* = cx.make(ui.Row{ .spacing = 8, .children = a.dupe(ui.Widget, &swatches) catch &.{} });
    }
    rows.append(a, cx.make(ui.Column{
        .cross_axis_alignment = .start,
        .spacing = 8,
        .children = &.{
            b.label("Background"),
            cx.make(ui.Column{ .cross_axis_alignment = .start, .spacing = 4, .children = a.dupe(ui.Widget, &swatch_rows) catch &.{} }),
        },
    })) catch {};

    return b.page(rows.items);
}

const swatches_per_row = 4;
const swatch_size = ui.Size{ .w = 64, .h = 44 };
/// The ring around the chosen swatch, and the gap inside it.
const ring = 3;
const ring_gap = 3;

/// A button filled with `bg`'s colour, named by its tooltip, and ringed in
/// the theme's primary colour when it is the one chosen.
fn swatch(cx: *ui.Context, bg: ui.theme.Background, chosen: bool, on_press: ?ui.Callback) ui.Widget {
    const t = cx.theme();
    const outer = 12 + ring + ring_gap;
    return cx.make(ui.Tooltip{
        .text = bg.name(),
        .child = cx.make(ui.Pressable{
            .on_press = on_press,
            .child = cx.make(ui.SizedBox{
                .width = swatch_size.w + 2 * (ring + ring_gap),
                .height = swatch_size.h + 2 * (ring + ring_gap),
                .child = cx.make(ui.Decorated{
                    .border = if (chosen) .{ .width = ring, .color = t.primary } else null,
                    .radius = .all(outer),
                    .child = cx.make(ui.Padding{
                        .padding = .all(ring + ring_gap),
                        .child = cx.make(ui.Decorated{
                            .color = .argb(bg.argb()),
                            // Dark on a dark page: an outline shows where it is.
                            .border = .{ .width = 1, .color = t.outline },
                            .radius = .all(12),
                        }),
                    }),
                }),
            }),
        }),
    });
}

/// The swatch of `bg`, by its tooltip.
fn findSwatch(n: *ui.Node, bg: ui.theme.Background) ?*ui.Node {
    if (n.widget.as(ui.Tooltip)) |tip| if (std.mem.eql(u8, tip.text, bg.name())) return n;
    for (n.children.items) |ch| if (findSwatch(ch, bg)) |f| return f;
    return null;
}

/// Whether the swatch of `bg` is ringed (chosen).
fn ringed(n: *ui.Node, bg: ui.theme.Background) bool {
    var at = findSwatch(n, bg).?;
    while (!at.widget.is(ui.Decorated)) at = at.children.items[0];
    return at.widget.as(ui.Decorated).?.border != null;
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

    // Eight colours, in two rows of four; navy is chosen to start with.
    try testing.expect(view.findText(u.root.?, "Background") != null);
    const swatch_row = view.up(findSwatch(u.root.?, .navy).?, ui.Row).?;
    try testing.expectEqual(@as(usize, 4), swatch_row.children.items.len);
    try testing.expectEqual(@as(usize, 2), swatch_row.parent.?.children.items.len);
    try testing.expect(ringed(u.root.?, .navy));
    try testing.expect(!ringed(u.root.?, .plum));

    // Picking a background keeps the theme, and rings the one picked.
    view.click(u, findSwatch(u.root.?, .plum).?.child(0));
    try testing.expectEqual(ui.theme.Background.plum, actions.appearance.?.background);
    try testing.expectEqual(ui.theme.Mode.dark, actions.appearance.?.theme);
    frame_no += 1;
    u.frame(1280, 720, frame_no, Settings{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .appearance = actions.appearance.?,
    });
    try testing.expect(ringed(u.root.?, .plum));
    try testing.expect(!ringed(u.root.?, .navy));
}
