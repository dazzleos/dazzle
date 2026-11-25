//! Setup's buttons: large pills, for a touchscreen as much as a mouse,
//! always the same width so Back and Next are in the same places on every
//! page (along the bottom, in the middle).

const kete = @import("kete");

/// How tall a button is (a round one is as wide).
pub const height = 64;
/// How wide one with a label is.
pub const width = 220;
/// Below the buttons, to the window's edge.
pub const margin = 32;

pub const BigButton = struct {
    label: []const u8 = "",
    icon: ?kete.IconName = null,
    trailing_icon: ?kete.IconName = null,
    /// Filled in the primary colour (the way on), rather than outlined.
    filled: bool = false,
    on_press: ?kete.Callback = null,

    pub const State = struct {
        interaction: kete.PointerInteraction = .{},
    };

    pub fn build(self: *const BigButton, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const i = state.interaction;
        const layer: f32 = if (self.on_press == null) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;
        const fg = if (self.filled) t.on_primary else t.primary;
        const bg = if (self.filled)
            blend(t.primary, t.on_primary, layer)
        else if (layer > 0) t.primary.withAlpha(layer) else null;
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
        const round = self.label.len == 0;
        return cx.make(kete.Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(kete.RoundedBox{
                .color = bg,
                .border_color = if (self.filled) null else t.outline,
                .border_width = 1.5,
                .radius = .all(height / 2),
                .child = cx.make(kete.SizedBox{
                    .width = if (round) height else width,
                    .height = height,
                    .child = cx.make(kete.Align{ .child = cx.make(kete.Row{
                        .fill = false,
                        .spacing = 10,
                        .cross_axis_alignment = .center,
                        .children = cx.arena.dupe(kete.Widget, parts[0..n]) catch &.{},
                    }) }),
                }),
            }),
        });
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
