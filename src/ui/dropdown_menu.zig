//! DropdownMenu and Select: Material 3's dropdown selector, showing the
//! chosen option in an outlined field with an arrow and opening a `Menu`
//! below it when pressed.

const std = @import("std");
const icons = @import("icons");
const widget = @import("widget.zig");
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const Decorated = @import("decorated.zig").Decorated;
const Expanded = @import("expanded.zig").Expanded;
const Icon = @import("icon.zig").Icon;
const Interaction = @import("pressable.zig").Interaction;
const MenuItem = @import("menu.zig").Item;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.Node;
const ValueCallback = widget.ValueCallback;

pub const DropdownMenu = struct {
    options: []const []const u8,
    selected: usize = 0,
    /// Called with the chosen index; without it the dropdown is disabled.
    on_selected: ?ValueCallback(usize) = null,
    placeholder: []const u8 = "",
    icon: ?icons.Icon = null,
    width: ?f32 = null,

    pub const height = 40;
    pub const max_options = 32;

    const Pick = struct {
        state: *State,
        index: usize,

        fn choose(p: *Pick) void {
            if (p.state.on_selected) |cb| cb.call(p.index);
        }
    };

    pub const State = struct {
        interaction: Interaction = .{},
        node: ?*Node = null,
        on_selected: ?ValueCallback(usize) = null,
        labels: [max_options][]const u8 = undefined,
        picks: [max_options]Pick = undefined,
        len: usize = 0,

        fn open(st: *State) void {
            const n = st.node orelse return;
            if (st.len == 0) return;
            var items: [max_options]MenuItem = undefined;
            for (st.labels[0..st.len], st.picks[0..st.len], items[0..st.len], 0..) |label, *pick, *item, i| {
                pick.* = .{ .state = st, .index = i };
                item.* = .{ .label = label, .on_press = .of(pick, Pick.choose) };
            }
            const pos = n.position();
            n.ui.openMenu(n, .{ pos[0], pos[1] + n.size.h }, items[0..st.len]);
        }
    };

    pub fn build(self: *const DropdownMenu, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_selected != null and self.options.len > 0;
        state.node = cx.node;
        state.on_selected = self.on_selected;
        state.len = @min(self.options.len, max_options);
        for (self.options[0..state.len], state.labels[0..state.len]) |opt, *dst| dst.* = opt;

        const i = state.interaction;
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;
        const fg = if (enabled) t.on_surface else t.on_surface.withAlpha(0.38);
        const icon_color = if (enabled) t.on_surface_variant else t.on_surface.withAlpha(0.38);
        const border = if (enabled) t.outline else t.on_surface.withAlpha(0.12);
        const current_label = if (self.selected < self.options.len) self.options[self.selected] else self.placeholder;

        const label_widget = if (self.width != null)
            cx.make(Expanded{ .child = cx.make(Text{
                .text = current_label,
                .style = .{ .size = t.label_size, .color = fg },
                .wrap = false,
                .ellipsis = true,
            }) })
        else
            cx.make(Text{
                .text = current_label,
                .style = .{ .size = t.label_size, .color = fg },
                .wrap = false,
            });
        const arrow = cx.make(Icon{ .icon = .expand_more, .size = 20, .color = icon_color });

        const row = if (self.icon) |leading|
            cx.make(Row{
                .spacing = 8,
                .main_axis_size = if (self.width != null) .max else .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(Icon{ .icon = leading, .size = 18, .color = icon_color }),
                    label_widget,
                    arrow,
                },
            })
        else
            cx.make(Row{
                .spacing = 8,
                .main_axis_size = if (self.width != null) .max else .min,
                .cross_axis_alignment = .center,
                .children = &.{ label_widget, arrow },
            });

        const padded = cx.make(Padding{
            .padding = .{ .left = 16, .right = 12 },
            .child = cx.make(@import("center.zig").Center{
                .width_factor = if (self.width != null) null else 1,
                .height_factor = 1,
                .child = row,
            }),
        });
        const box = if (self.width) |w|
            cx.make(ConstrainedBox{ .constraints = .{ .min_w = w, .max_w = w, .min_h = height }, .child = padded })
        else
            cx.make(ConstrainedBox{ .constraints = .{ .min_w = 96, .min_h = height }, .child = padded });

        return cx.make(Pressable{
            .on_press = if (enabled) .of(state, State.open) else null,
            .interaction = &state.interaction,
            .child = cx.make(Decorated{
                .color = if (layer > 0) t.on_surface.withAlpha(layer) else null,
                .border = .{ .width = 1, .color = border },
                .radius = .all(8),
                .child = box,
            }),
        });
    }
};

/// A typed dropdown selector for a value of type `T` (such as an enum).
pub fn Select(comptime T: type) type {
    return struct {
        pub const Option = struct {
            value: T,
            label: []const u8,
        };

        options: []const Option,
        value: T,
        on_changed: ?ValueCallback(T) = null,
        icon: ?icons.Icon = null,
        width: ?f32 = null,

        pub const State = struct {
            values: [DropdownMenu.max_options]T = undefined,
            len: usize = 0,
            on_changed: ?ValueCallback(T) = null,

            fn pick(st: *State, idx: usize) void {
                if (idx < st.len) {
                    if (st.on_changed) |cb| cb.call(st.values[idx]);
                }
            }
        };

        pub fn build(self: *const @This(), cx: *Context, state: *State) Widget {
            state.len = @min(self.options.len, DropdownMenu.max_options);
            state.on_changed = self.on_changed;
            const labels = cx.arena.alloc([]const u8, state.len) catch return cx.make(@import("empty.zig").Empty{});
            var selected: usize = 0;
            for (self.options[0..state.len], labels, 0..) |opt, *lbl, i| {
                lbl.* = opt.label;
                state.values[i] = opt.value;
                if (std.meta.eql(opt.value, self.value)) selected = i;
            }
            return cx.make(DropdownMenu{
                .options = labels,
                .selected = selected,
                .on_selected = if (self.on_changed != null) .of(state, State.pick) else null,
                .icon = self.icon,
                .width = self.width,
            });
        }
    };
}
