//! The Appearance page: system colour scheme (Dark or Light), and the
//! desktop's background colour (the same in either), picked from swatches.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const ui_theme = @import("ui").theme;
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;

pub const label = "Appearance";
pub const icon: kete.IconName = .palette;

pub const State = struct {
    appearance: ui_theme.Settings = .{},
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

    fn setBackground(comptime bg: ui_theme.Background) fn (*State) void {
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

pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const a = cx.arena;

    state.appearance = self.appearance;
    state.actions = self.actions;

    var rows: std.ArrayList(kete.Widget) = .empty;

    const theme_bar = cx.make(kete.PillBar{
        .children = &.{
            cx.make(kete.PillButton{
                .label = "Dark",
                .icon = .dark_mode,
                .selected = self.appearance.theme == .dark,
                .first = true,
                .on_press = if (self.actions != null) .of(state, State.setDark) else null,
            }),
            cx.make(kete.PillButton{
                .label = "Light",
                .icon = .light_mode,
                .selected = self.appearance.theme == .light,
                .last = true,
                .on_press = if (self.actions != null) .of(state, State.setLight) else null,
            }),
        },
    });

    rows.append(a, cx.make(kete.Row{
        .cross_axis_alignment = .center,
        .spacing = 12,
        .children = &.{
            b.label("Theme"),
            theme_bar,
        },
    })) catch {};

    // A swatch of each colour, in rows of four under its label; the one
    // chosen is ringed, as a radio button is.
    const backgrounds = comptime std.enums.values(ui_theme.Background);
    var swatch_rows: [(backgrounds.len + swatches_per_row - 1) / swatches_per_row]kete.Widget = undefined;
    inline for (&swatch_rows, 0..) |*row, r| {
        const from = r * swatches_per_row;
        const in_row = backgrounds[from..@min(from + swatches_per_row, backgrounds.len)];
        var swatches: [in_row.len]kete.Widget = undefined;
        inline for (in_row, &swatches) |bg, *sw| {
            sw.* = swatch(cx, bg, self.appearance.background == bg, if (self.actions != null) .of(state, State.setBackground(bg)) else null);
        }
        row.* = cx.make(kete.Row{ .spacing = 8, .children = a.dupe(kete.Widget, &swatches) catch &.{} });
    }
    rows.append(a, cx.make(kete.Column{
        .cross_axis_alignment = .start,
        .spacing = 8,
        .children = &.{
            b.label("Background"),
            cx.make(kete.Column{ .cross_axis_alignment = .start, .spacing = 4, .children = a.dupe(kete.Widget, &swatch_rows) catch &.{} }),
        },
    })) catch {};

    return b.page(rows.items);
}

const swatches_per_row = 4;
const swatch_size = kete.Size{ .w = 64, .h = 44 };
/// The ring around the chosen swatch, and the gap inside it.
const ring = 3;
const ring_gap = 3;

/// A button filled with `bg`'s colour, named by its tooltip, and ringed in
/// the theme's primary colour when it is the one chosen.
fn swatch(cx: *kete.BuildContext, bg: ui_theme.Background, chosen: bool, on_press: ?kete.Callback) kete.Widget {
    const t = cx.theme();
    const outer = 12 + ring + ring_gap;
    return cx.make(kete.Tooltip{
        .text = bg.name(),
        .child = cx.make(kete.Pressable{
            .on_press = on_press,
            .child = cx.make(kete.SizedBox{
                .width = swatch_size.w + 2 * (ring + ring_gap),
                .height = swatch_size.h + 2 * (ring + ring_gap),
                .child = cx.make(kete.RoundedBox{
                    .border_width = if (chosen) ring else 0,
                    .border_color = if (chosen) t.primary else null,
                    .radius = .all(outer),
                    .child = cx.make(kete.Padding{
                        .padding = .all(ring + ring_gap),
                        .child = cx.make(kete.RoundedBox{
                            .color = .argb(bg.argb()),
                            // Dark on a dark page: an outline shows where it is.
                            .border_width = 1,
                            .border_color = t.outline,
                            .radius = .all(12),
                        }),
                    }),
                }),
            }),
        }),
    });
}

/// The swatch of `bg`, by its tooltip.
fn findSwatch(n: *kete.WidgetNode, bg: ui_theme.Background) ?*kete.WidgetNode {
    if (n.widget.as(kete.Tooltip)) |tip| if (std.mem.eql(u8, tip.text, bg.name())) return n;
    for (n.children.items) |ch| if (findSwatch(ch, bg)) |f| return f;
    return null;
}

/// Whether the swatch of `bg` is ringed (chosen).
fn ringed(n: *kete.WidgetNode, bg: ui_theme.Background) bool {
    var at = findSwatch(n, bg).?;
    while (!at.widget.is(kete.RoundedBox)) at = at.children.items[0];
    return at.widget.as(kete.RoundedBox).?.border_color != null;
}

const testing = std.testing;
const font = kete.font;

test "Appearance page toggles between Dark and Light theme" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    const d = view.sample();
    var appearance: ui_theme.Settings = .{ .theme = .dark };
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
    view.click(u, view.up(view.findText(u.root.?, "Light").?, kete.Pressable).?);
    try testing.expectEqual(ui_theme.Mode.light, actions.appearance.?.theme);
    appearance = actions.appearance.?;
    u.theme = kete_vc4.themeMode(appearance.theme).scheme();
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
    try testing.expectEqual(kete.Theme.light.surface, u.theme.surface);

    // Clicking Dark sets actions.appearance.theme = .dark.
    view.click(u, view.up(view.findText(u.root.?, "Dark").?, kete.Pressable).?);
    try testing.expectEqual(ui_theme.Mode.dark, actions.appearance.?.theme);

    // Eight colours, in two rows of four; navy is chosen to start with.
    try testing.expect(view.findText(u.root.?, "Background") != null);
    const swatch_row = view.up(findSwatch(u.root.?, .navy).?, kete.Row).?;
    try testing.expectEqual(@as(usize, 4), swatch_row.children.items.len);
    try testing.expectEqual(@as(usize, 2), swatch_row.parent.?.children.items.len);
    try testing.expect(ringed(u.root.?, .navy));
    try testing.expect(!ringed(u.root.?, .plum));

    // Picking a background keeps the theme, and rings the one picked.
    view.click(u, findSwatch(u.root.?, .plum).?.child(0));
    try testing.expectEqual(ui_theme.Background.plum, actions.appearance.?.background);
    try testing.expectEqual(ui_theme.Mode.dark, actions.appearance.?.theme);
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
