//! What every setup page has: a title, near the top in the middle, large;
//! and large Back and Next buttons, the same width, along the bottom in the
//! middle (Finish, on the last page, in Dazzle's colours, as on its
//! website). Each in the same place on every page, the Hello page's too.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");

/// Above the title, to the window's edge; how tall its line is; and its
/// text's size.
pub const title_top = 40;
pub const title_height = 96;
pub const title_size = 56;
/// Where the middle of the title is, down from the window's top.
pub const title_middle = title_top + title_height / 2;

/// How tall a button is (a round one is as wide).
pub const height = 64;
/// How wide one with a label is.
pub const width = 220;
/// Below the buttons, to the window's edge.
pub const margin = 32;
/// Between the buttons and what is above them.
pub const above_buttons = 24;

/// Dazzle's colours: its website's, from sky to violet, and the dark text
/// on them.
const sky = kete.Color.rgb(0x7cc4ff);
const violet = kete.Color.rgb(0xb394ff);
const ink = kete.Color.rgb(0x0b1020);

/// A page's title: in the middle of its line, large (smaller if it does
/// not fit across).
pub const Title = struct {
    text: []const u8,

    pub fn build(self: *const Title, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.SizedBox{ .height = title_height, .child = cx.make(kete.Align{ .child = cx.make(kete.ScaleDown{
            .child = cx.make(kete.Text{ .text = self.text, .wrap = false, .style = .{ .size = title_size } }),
        }) }) });
    }
};

/// Back and Next (or Finish, on the last page), along the bottom.
pub fn buttons(cx: *kete.BuildContext, on_back: ?kete.Callback, next_label: []const u8, on_next: ?kete.Callback, last: bool) kete.Widget {
    return cx.make(kete.Row{ .spacing = 24, .main_axis_alignment = .center, .children = cx.arena.dupe(kete.Widget, &.{
        cx.make(BigButton{ .label = locale.text("Back"), .icon = .arrow_back, .on_press = on_back }),
        if (last)
            cx.make(BigButton{ .label = next_label, .look = .dazzle, .icon = .check, .on_press = on_next })
        else
            cx.make(BigButton{ .label = next_label, .look = .filled, .trailing_icon = .arrow_forward, .on_press = on_next }),
    }) catch &.{} });
}

pub const BigButton = struct {
    label: []const u8 = "",
    icon: ?kete.IconName = null,
    trailing_icon: ?kete.IconName = null,
    look: Look = .outlined,
    on_press: ?kete.Callback = null,

    pub const Look = enum {
        /// An outline (the way back).
        outlined,
        /// Filled in the primary colour (the way on).
        filled,
        /// In Dazzle's colours (the way in, at the end).
        dazzle,
    };

    pub const State = struct {
        interaction: kete.PointerInteraction = .{},
    };

    pub fn build(self: *const BigButton, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const i = state.interaction;
        const layer: f32 = if (self.on_press == null) 0 else if (i.pressed) 0.16 else if (i.hovered) 0.08 else 0;
        const fg = switch (self.look) {
            .outlined => t.primary,
            .filled => t.on_primary,
            .dazzle => ink,
        };
        var parts: [3]kete.Widget = undefined;
        var n: usize = 0;
        if (self.icon) |ic| {
            parts[n] = cx.make(kete.Icon{ .icon = ic, .size = 28, .color = fg });
            n += 1;
        }
        if (self.label.len > 0) {
            parts[n] = cx.make(kete.Text{ .text = self.label, .wrap = false, .ellipsis = true, .style = .{ .size = 24, .color = fg } });
            n += 1;
        }
        if (self.trailing_icon) |ic| {
            parts[n] = cx.make(kete.Icon{ .icon = ic, .size = 28, .color = fg });
            n += 1;
        }
        const content = cx.make(kete.Align{ .child = cx.make(kete.Row{
            .fill = false,
            .spacing = 10,
            .cross_axis_alignment = .center,
            .children = cx.arena.dupe(kete.Widget, parts[0..n]) catch &.{},
        }) });
        const size: [2]f32 = .{ if (self.label.len == 0) height else width, height };
        const face = switch (self.look) {
            .outlined => cx.make(kete.RoundedBox{
                .color = if (layer > 0) t.primary.withAlpha(layer) else null,
                .border_color = t.outline,
                .border_width = 1.5,
                .radius = .all(height / 2),
                .child = content,
            }),
            .filled => cx.make(kete.RoundedBox{
                .color = blend(t.primary, t.on_primary, layer),
                .radius = .all(height / 2),
                .child = content,
            }),
            .dazzle => cx.make(kete.Overlay{ .children = cx.arena.dupe(kete.Widget, &.{
                cx.make(Shaded{ .light = layer }),
                content,
            }) catch &.{} }),
        };
        return cx.make(kete.Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(kete.SizedBox{ .width = size[0], .height = size[1], .child = face }),
        });
    }
};

/// How tall a `Choice` is.
pub const choice_height = 52;

/// One of a few to choose from (a page's keyboards): a pill as large as
/// its label, filled when chosen (with a tick), outlined when not; or, with
/// no `selected`, a button that shows more of them.
pub const Choice = struct {
    label: []const u8,
    icon: ?kete.IconName = null,
    selected: bool = false,
    on_press: ?kete.Callback = null,

    pub const State = struct {
        interaction: kete.PointerInteraction = .{},
    };

    pub fn build(self: *const Choice, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const i = state.interaction;
        const layer: f32 = if (self.on_press == null) 0 else if (i.pressed) 0.16 else if (i.hovered) 0.08 else 0;
        const fg = if (self.selected) t.on_primary_container else t.on_surface;
        const icon = if (self.selected) .check else self.icon;
        var parts: [2]kete.Widget = undefined;
        var n: usize = 0;
        if (icon) |ic| {
            parts[n] = cx.make(kete.Icon{ .icon = ic, .size = 24, .color = if (self.selected) fg else t.primary });
            n += 1;
        }
        parts[n] = cx.make(kete.Text{ .text = self.label, .wrap = false, .style = .{ .size = 20, .color = fg } });
        n += 1;
        return cx.make(kete.Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(kete.RoundedBox{
                .color = if (self.selected) blend(t.primary_container, t.on_primary_container, layer) else if (layer > 0) t.primary.withAlpha(layer) else null,
                .border_color = if (self.selected) null else t.outline,
                .border_width = 1.5,
                .radius = .all(choice_height / 2),
                .child = cx.make(kete.SizedBox{ .height = choice_height, .child = cx.make(kete.Padding{
                    .padding = .symmetric(24, 0),
                    .child = cx.make(kete.Align{ .width_factor = 1, .child = cx.make(kete.Row{
                        .fill = false,
                        .spacing = 10,
                        .cross_axis_alignment = .center,
                        .children = cx.arena.dupe(kete.Widget, parts[0..n]) catch &.{},
                    }) }),
                }) }),
            }),
        });
    }
};

/// A pill shaded from sky to violet across, lightened by `light` (hovered
/// or pressed).
const Shaded = struct {
    light: f32 = 0,

    /// Points around each round end.
    const arc = 16;

    pub fn layout(_: *const Shaded, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        return c.constrain(.{ .w = c.max_w, .h = c.max_h });
    }

    pub fn paint(self: *const Shaded, n: *kete.WidgetNode, p: *kete.Painter) void {
        const w = n.size.w;
        const h = n.size.h;
        if (w <= 0 or h <= 0) return;
        const a = n.ui.arena();
        const c = p.canvas();
        const r = h / 2;
        // Around the pill (clockwise from the top of its right end), and
        // which way is out at each point.
        var ring: [2 * (arc + 1)][2]f32 = undefined;
        var out: [2 * (arc + 1)][2]f32 = undefined;
        for (0..2) |end| for (0..arc + 1) |k| {
            const turn = std.math.pi * (@as(f32, @floatFromInt(k)) / arc + @as(f32, @floatFromInt(end)) - 0.5);
            const d: [2]f32 = .{ @cos(turn), @sin(turn) };
            const middle_x = if (end == 0) w - r else r;
            ring[end * (arc + 1) + k] = .{ middle_x + d[0] * r, r + d[1] * r };
            out[end * (arc + 1) + k] = d;
        };
        // Violet, then sky over it, fading out across (from the middle, in
        // a fan: the fade is even across, so it is exact). The sky's edge
        // is not smoothed: it is kept just inside the violet's, which is.
        const box: kete.gfx.Rect = .{ .x = 0, .y = 0, .w = w, .h = h };
        c.fillRoundedRect(box, .all(r), violet);
        const fan = a.alloc([3]f32, ring.len * 3) catch return;
        const mid: [3]f32 = .{ w / 2, h / 2, 0.5 };
        for (0..ring.len) |k| {
            const j = (k + 1) % ring.len;
            const p0: [2]f32 = .{ ring[k][0] - out[k][0] * 0.75, ring[k][1] - out[k][1] * 0.75 };
            const p1: [2]f32 = .{ ring[j][0] - out[j][0] * 0.75, ring[j][1] - out[j][1] * 0.75 };
            fan[k * 3 ..][0..3].* = .{ mid, .{ p0[0], p0[1], 1 - p0[0] / w }, .{ p1[0], p1[1], 1 - p1[0] / w } };
        }
        c.fillShaded(fan, sky);
        if (self.light > 0) c.fillRoundedRect(box, .all(r), kete.Color.rgb(0xffffff).withAlpha(self.light));
    }
};

fn blend(base: kete.Color, top: kete.Color, a: f32) kete.Color {
    return .{
        .r = base.r * (1 - a) + top.r * a,
        .g = base.g * (1 - a) + top.g * a,
        .b = base.b * (1 - a) + top.b * a,
        .a = base.a,
    };
}
