//! Material 3's selection controls: `Checkbox`, `Radio` and `Switch`.
//!
//! Like Flutter's, they show the value they are given and report a change
//! through `on_changed` (the app's state holds the value, and its next
//! build shows the change). Without `on_changed` they are disabled. With a
//! `label`, the label is beside the control and pressing either toggles
//! it.
//!
//! Each is a `Pressable` around the control's mark (a widget that paints
//! it, with Material's hover and press state layer) and its label.

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const widgets = @import("widgets.zig");
const text = @import("text.zig");
const painter_mod = @import("painter.zig");
const material = @import("material.zig");

const Color = gfx.Color;
const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.Node;
const Callback = widget.Callback;
const ValueCallback = widget.ValueCallback;
const Interaction = widgets.Interaction;
const Painter = painter_mod.Painter;
const Theme = material.Theme;

/// The square a checkbox or radio button takes (Material's touch target).
pub const target = 40;

/// What each control's state keeps from its last build, so a press (which
/// comes between builds) reports the right change.
fn Latest(comptime T: type) type {
    return struct {
        interaction: Interaction = .{},
        value: ?T = null,
        on_changed: ?ValueCallback(T) = null,

        fn update(s: *@This(), value: T, on_changed: ?ValueCallback(T)) void {
            s.value = value;
            s.on_changed = on_changed;
        }
    };
}

/// The state layer's opacity: Material's hover and press tints.
fn layerAlpha(i: Interaction, enabled: bool) f32 {
    if (!enabled) return 0;
    return if (i.pressed) 0.10 else if (i.hovered) 0.08 else 0;
}

/// The control's mark beside its label (if any), pressable as a whole.
fn control(cx: *Context, interaction: *Interaction, on_press: ?Callback, mark: Widget, label: []const u8, gap: f32) Widget {
    const t = cx.theme();
    const content = if (label.len == 0) mark else cx.make(widgets.Row{
        .main_axis_size = .min,
        .spacing = gap,
        .children = &.{
            mark,
            cx.make(widgets.Padding{ .padding = .{ .right = 8 }, .child = cx.make(text.Text{
                .text = label,
                .style = .{ .color = if (on_press != null) t.on_surface else t.on_surface.withAlpha(0.38) },
                .wrap = false,
            }) }),
        },
    });
    return cx.make(widgets.Pressable{ .on_press = on_press, .interaction = interaction, .child = content });
}

pub const Checkbox = struct {
    value: bool,
    /// Called with the new value; without it the checkbox is disabled.
    on_changed: ?ValueCallback(bool) = null,
    label: []const u8 = "",

    pub const State = struct {
        latest: Latest(bool) = .{},

        fn press(s: *State) void {
            if (s.latest.on_changed) |f| f.call(!(s.latest.value orelse false));
        }
    };

    pub fn build(self: *const Checkbox, cx: *Context, state: *State) Widget {
        state.latest.update(self.value, self.on_changed);
        const enabled = self.on_changed != null;
        return control(cx, &state.latest.interaction, if (enabled) .of(state, State.press) else null, cx.make(CheckboxMark{
            .checked = self.value,
            .enabled = enabled,
            .interaction = state.latest.interaction,
        }), self.label, 4);
    }
};

/// A checkbox's box and tick, in its touch target.
pub const CheckboxMark = struct {
    checked: bool,
    enabled: bool = true,
    interaction: Interaction = .{},

    pub const box = 18;

    pub fn layout(_: *const CheckboxMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = target, .h = target });
    }

    pub fn paint(self: *const CheckboxMark, n: *Node, p: *Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        const layer = layerAlpha(self.interaction, self.enabled);
        if (layer > 0) c.fillCircle(mid, target / 2, (if (self.checked) t.primary else t.on_surface).withAlpha(layer));
        const r: gfx.Rect = .{ .x = mid[0] - box / 2, .y = mid[1] - box / 2, .w = box, .h = box };
        const disabled = t.on_surface.withAlpha(0.38);
        if (self.checked) {
            c.fillRoundedRect(r, .all(2), if (self.enabled) t.primary else disabled);
            const tick = if (self.enabled) t.on_primary else t.surface;
            c.strokePolyline(&.{ .{ r.x + 3.5, r.y + 9 }, .{ r.x + 7, r.y + 12.5 }, .{ r.x + 14.5, r.y + 5 } }, false, 2, tick);
        } else {
            c.strokeRoundedRect(r, .all(2), 2, if (self.enabled) t.on_surface_variant else disabled);
        }
    }
};

/// One of a group of radio buttons: selected when `value` is the group's
/// value, and selecting it reports `value`.
pub fn Radio(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        group_value: T,
        /// Called with `value` when it is selected; without it the button is
        /// disabled.
        on_changed: ?ValueCallback(T) = null,
        label: []const u8 = "",

        pub const State = struct {
            latest: Latest(T) = .{},

            fn press(s: *State) void {
                if (s.latest.on_changed) |f| if (s.latest.value) |v| f.call(v);
            }
        };

        pub fn build(self: *const Self, cx: *Context, state: *State) Widget {
            state.latest.update(self.value, self.on_changed);
            const enabled = self.on_changed != null;
            return control(cx, &state.latest.interaction, if (enabled) .of(state, State.press) else null, cx.make(RadioMark{
                .selected = std.meta.eql(self.value, self.group_value),
                .enabled = enabled,
                .interaction = state.latest.interaction,
            }), self.label, 4);
        }
    };
}

/// A radio button's ring and dot, in its touch target.
pub const RadioMark = struct {
    selected: bool,
    enabled: bool = true,
    interaction: Interaction = .{},

    pub fn layout(_: *const RadioMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = target, .h = target });
    }

    pub fn paint(self: *const RadioMark, n: *Node, p: *Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        const layer = layerAlpha(self.interaction, self.enabled);
        if (layer > 0) c.fillCircle(mid, target / 2, (if (self.selected) t.primary else t.on_surface).withAlpha(layer));
        const color = if (!self.enabled) t.on_surface.withAlpha(0.38) else if (self.selected) t.primary else t.on_surface_variant;
        c.strokeCircle(mid, 10, 2, color);
        if (self.selected) c.fillCircle(mid, 5, color);
    }
};

pub const Switch = struct {
    value: bool,
    /// Called with the new value; without it the switch is disabled.
    on_changed: ?ValueCallback(bool) = null,
    label: []const u8 = "",

    /// How long the handle takes to cross.
    pub const travel_ns = 150 * std.time.ns_per_ms;

    pub const State = struct {
        latest: Latest(bool) = .{},
        /// Where the handle is shown: 0 off, 1 on.
        position: ?f32 = null,
        last_ns: u64 = 0,

        fn press(s: *State) void {
            if (s.latest.on_changed) |f| f.call(!(s.latest.value orelse false));
        }
    };

    pub fn build(self: *const Switch, cx: *Context, state: *State) Widget {
        state.latest.update(self.value, self.on_changed);
        // The handle slides to the value.
        const goal: f32 = if (self.value) 1 else 0;
        const now = cx.now();
        var pos = state.position orelse goal;
        const step = @as(f32, @floatFromInt(now -| state.last_ns)) / travel_ns;
        pos = if (pos < goal) @min(pos + step, goal) else @max(pos - step, goal);
        state.position = pos;
        state.last_ns = now;
        if (pos != goal) cx.requestFrame();
        const enabled = self.on_changed != null;
        return control(cx, &state.latest.interaction, if (enabled) .of(state, State.press) else null, cx.make(SwitchMark{
            .position = pos,
            .enabled = enabled,
            .interaction = state.latest.interaction,
        }), self.label, 12);
    }
};

/// A switch's track and handle.
pub const SwitchMark = struct {
    /// 0 off, 1 on (between while it slides).
    position: f32,
    enabled: bool = true,
    interaction: Interaction = .{},

    pub const width = 52;
    pub const height = 32;

    pub fn layout(_: *const SwitchMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = width, .h = target });
    }

    pub fn paint(self: *const SwitchMark, n: *Node, p: *Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const k = std.math.clamp(self.position, 0, 1);
        const track: gfx.Rect = .{ .x = (n.size.w - width) / 2, .y = (n.size.h - height) / 2, .w = width, .h = height };
        const disabled: f32 = if (self.enabled) 1 else 0.38;
        // Off: an outlined track, a small handle in the outline colour.
        // On: a filled track, a bigger handle (bigger still when pressed).
        c.fillRoundedRect(track, .all(height / 2), mix(t.surface_container_highest, t.primary, k).withAlpha(if (self.enabled) 1 else 0.12));
        if (k < 1) c.strokeRoundedRect(track, .all(height / 2), 2, t.outline.withAlpha((1 - k) * disabled));
        const pressed = self.enabled and self.interaction.pressed;
        const radius: f32 = if (pressed) 14 else 8 + 4 * k;
        const center: gfx.Point = .{ track.x + 16 + 20 * k, track.y + height / 2 };
        const layer = layerAlpha(self.interaction, self.enabled);
        if (layer > 0) c.fillCircle(center, 20, (if (k > 0.5) t.primary else t.on_surface).withAlpha(layer));
        c.fillCircle(center, radius, mix(t.outline, t.on_primary, k).withAlpha(disabled));
    }
};

fn mix(a: Color, b: Color, k: f32) Color {
    return .{ .r = a.r + (b.r - a.r) * k, .g = a.g + (b.g - a.g) * k, .b = a.b + (b.b - a.b) * k, .a = a.a + (b.a - a.a) * k };
}
