//! Material 3: the theme (colours and text sizes) and components made
//! from the basic widgets.

const std = @import("std");
const gfx = @import("gfx");
const widget = @import("widget.zig");
const widgets = @import("widgets.zig");
const text = @import("text.zig");

const Color = gfx.Color;
const Widget = widget.Widget;
const Context = widget.Context;
const Callback = widget.Callback;

/// A Material 3 colour scheme, and text sizes in pixels.
pub const Theme = struct {
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    secondary_container: Color,
    surface: Color,
    surface_container: Color,
    on_surface: Color,
    on_surface_variant: Color,
    outline: Color,
    outline_variant: Color,
    @"error": Color,
    body_size: f32 = 14,
    label_size: f32 = 14,
    title_size: f32 = 22,

    /// The baseline light scheme.
    pub const light: Theme = .{
        .primary = .rgb(0x6750a4),
        .on_primary = .rgb(0xffffff),
        .primary_container = .rgb(0xeaddff),
        .on_primary_container = .rgb(0x21005d),
        .secondary_container = .rgb(0xe8def8),
        .surface = .rgb(0xfef7ff),
        .surface_container = .rgb(0xf3edf7),
        .on_surface = .rgb(0x1d1b20),
        .on_surface_variant = .rgb(0x49454f),
        .outline = .rgb(0x79747e),
        .outline_variant = .rgb(0xcac4d0),
        .@"error" = .rgb(0xb3261e),
    };

    /// The baseline dark scheme.
    pub const dark: Theme = .{
        .primary = .rgb(0xd0bcff),
        .on_primary = .rgb(0x381e72),
        .primary_container = .rgb(0x4f378b),
        .on_primary_container = .rgb(0xeaddff),
        .secondary_container = .rgb(0x4a4458),
        .surface = .rgb(0x141218),
        .surface_container = .rgb(0x211f26),
        .on_surface = .rgb(0xe6e0e9),
        .on_surface_variant = .rgb(0xcac4d0),
        .outline = .rgb(0x938f99),
        .outline_variant = .rgb(0x49454f),
        .@"error" = .rgb(0xf2b8b5),
    };
};

/// A pill-shaped button with an outline: a `Pressable` around a
/// `Decorated` outline (with Material's hover and press tint), sized and
/// padded, with its label in the middle.
pub const OutlinedButton = struct {
    /// The label (or give a `child` instead).
    label: []const u8 = "",
    child: ?Widget = null,
    /// Without it the button is disabled.
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: widgets.Interaction = .{},
    };

    pub const height = 40;
    pub const padding = 24;

    pub fn build(self: *const OutlinedButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null;
        const i = state.interaction;
        // State layers: the label's colour over the button.
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.10 else if (i.hovered) 0.08 else 0;
        const label_color = if (enabled) t.primary else t.on_surface.withAlpha(0.38);
        const border = if (enabled) t.outline else t.on_surface.withAlpha(0.12);
        const content = self.child orelse cx.make(text.Text{
            .text = self.label,
            .style = .{ .size = t.label_size, .color = label_color },
            .wrap = false,
        });
        return cx.make(widgets.Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(widgets.Decorated{
                .color = if (layer > 0) t.primary.withAlpha(layer) else null,
                .border = .{ .width = 1, .color = border },
                .radius = .all(height / 2),
                .child = cx.make(widgets.ConstrainedBox{
                    .constraints = .{ .min_w = 48, .min_h = height },
                    .child = cx.make(widgets.Padding{
                        .padding = .symmetric(padding, 0),
                        .child = cx.make(widgets.Center{ .width_factor = 1, .height_factor = 1, .child = content }),
                    }),
                }),
            }),
        });
    }
};
