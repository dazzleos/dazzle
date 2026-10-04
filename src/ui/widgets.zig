//! The basic widgets: boxes, padding, alignment, rows and columns, grids,
//! overlays, decoration, and pressing.

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Size = geometry.Size;
const Point = geometry.Point;
const Constraints = geometry.Constraints;
const Insets = geometry.Insets;
const Alignment = geometry.Alignment;
const Widget = widget.Widget;
const Node = widget.Node;
const Context = widget.Context;
const Event = widget.Event;
const Callback = widget.Callback;
const Painter = painter_mod.Painter;

/// Nothing, as small as allowed.
pub const Empty = struct {
    pub fn layout(_: *const Empty, _: *Node, c: Constraints) Size {
        return c.smallest();
    }
};

/// A box of a given width and/or height (within its constraints); the
/// child, if any, is made to fit it.
pub const SizedBox = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    child: ?Widget = null,

    pub fn layout(self: *const SizedBox, n: *Node, c: Constraints) Size {
        var own: Constraints = .{};
        if (self.width) |w| own = .{ .min_w = w, .max_w = w, .min_h = own.min_h, .max_h = own.max_h };
        if (self.height) |h| own = .{ .min_w = own.min_w, .max_w = own.max_w, .min_h = h, .max_h = h };
        const inner = c.enforce(own);
        if (n.childCount() > 0) return n.child(0).layout(inner);
        return inner.constrain(.{ .w = self.width orelse 0, .h = self.height orelse 0 });
    }
};

/// Adds constraints of its own to the child's (within its parent's).
pub const ConstrainedBox = struct {
    constraints: Constraints,
    child: ?Widget = null,

    pub fn layout(self: *const ConstrainedBox, n: *Node, c: Constraints) Size {
        const inner = c.enforce(self.constraints.sanitize());
        if (n.childCount() > 0) return n.child(0).layout(inner);
        return inner.smallest();
    }
};

/// Space around the child.
pub const Padding = struct {
    padding: Insets,
    child: ?Widget = null,

    pub fn layout(self: *const Padding, n: *Node, c: Constraints) Size {
        const p = self.padding;
        if (n.childCount() == 0) return c.constrain(.{ .w = p.horizontal(), .h = p.vertical() });
        const ch = n.child(0);
        const s = ch.layout(c.deflate(p));
        ch.place(p.left, p.top);
        return c.constrain(.{ .w = s.w + p.horizontal(), .h = s.h + p.vertical() });
    }
};

/// Places the child within itself. It is as big as allowed (or a
/// multiple of the child's size, with the factors), or the child's size
/// where unbounded.
pub const Align = struct {
    alignment: Alignment = .center,
    width_factor: ?f32 = null,
    height_factor: ?f32 = null,
    child: ?Widget = null,

    pub fn layout(self: *const Align, n: *Node, c: Constraints) Size {
        const s = if (n.childCount() > 0) n.child(0).layout(c.loosen()) else Size{};
        const size = c.constrain(.{
            .w = if (self.width_factor) |f| s.w * f else if (c.boundedWidth()) c.max_w else s.w,
            .h = if (self.height_factor) |f| s.h * f else if (c.boundedHeight()) c.max_h else s.h,
        });
        if (n.childCount() > 0) {
            const at = self.alignment.place(size, s);
            n.child(0).place(at[0], at[1]);
        }
        return size;
    }
};

/// The child in the middle of the space (an `Align`).
pub const Center = struct {
    width_factor: ?f32 = null,
    height_factor: ?f32 = null,
    child: ?Widget = null,

    pub fn build(self: *const Center, cx: *Context) Widget {
        return cx.make(Align{ .width_factor = self.width_factor, .height_factor = self.height_factor, .child = self.child });
    }
};

pub const MainAxisAlignment = enum { start, center, end, space_between, space_around, space_evenly };
pub const CrossAxisAlignment = enum { start, center, end, stretch };
pub const MainAxisSize = enum {
    /// Just the children.
    min,
    /// All the space there is (if bounded).
    max,
};

/// In a row or column, gives the child a share of the space the others
/// leave (by `flex`). Where the space is unbounded it is like any child.
pub const Expanded = struct {
    flex: f32 = 1,
    child: Widget,
};

pub const Row = Flex(.horizontal);
pub const Column = Flex(.vertical);

pub const Axis = enum { horizontal, vertical };

/// Children one after another, left to right (`Row`) or top to bottom
/// (`Column`).
pub fn Flex(comptime axis: Axis) type {
    return struct {
        const Self = @This();

        children: []const Widget = &.{},
        main_axis_alignment: MainAxisAlignment = .start,
        cross_axis_alignment: CrossAxisAlignment = .center,
        main_axis_size: MainAxisSize = .max,
        /// Space between children.
        spacing: f32 = 0,

        fn main(s: Size) f32 {
            return if (axis == .horizontal) s.w else s.h;
        }

        fn cross(s: Size) f32 {
            return if (axis == .horizontal) s.h else s.w;
        }

        fn constraints(min_main: f32, max_main: f32, min_cross: f32, max_cross: f32) Constraints {
            return if (axis == .horizontal)
                .{ .min_w = min_main, .max_w = max_main, .min_h = min_cross, .max_h = max_cross }
            else
                .{ .min_w = min_cross, .max_w = max_cross, .min_h = min_main, .max_h = max_main };
        }

        fn sized(m: f32, x: f32) Size {
            return if (axis == .horizontal) .{ .w = m, .h = x } else .{ .w = x, .h = m };
        }

        fn flexOf(ch: *const Node) f32 {
            const e = ch.widget.as(Expanded) orelse return 0;
            return if (std.math.isFinite(e.flex) and e.flex > 0) e.flex else 0;
        }

        pub fn layout(self: *const Self, n: *Node, c: Constraints) Size {
            const max_main = if (axis == .horizontal) c.max_w else c.max_h;
            const min_main = if (axis == .horizontal) c.min_w else c.min_h;
            const max_cross = if (axis == .horizontal) c.max_h else c.max_w;
            const min_cross = if (axis == .horizontal) c.min_h else c.min_w;
            const bounded = std.math.isFinite(max_main);
            const stretch = self.cross_axis_alignment == .stretch and std.math.isFinite(max_cross);
            const count = n.childCount();
            const spacing = if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
            const gaps = spacing * @as(f32, @floatFromInt(if (count > 0) count - 1 else 0));
            const cross_min: f32 = if (stretch) max_cross else 0;

            // Children without flex first (all of them, if unbounded).
            var total_flex: f32 = 0;
            var used: f32 = gaps;
            var cross_size: f32 = 0;
            for (n.children.items) |ch| {
                const flex = flexOf(ch);
                if (flex > 0 and bounded) {
                    total_flex += flex;
                    continue;
                }
                const s = ch.layout(constraints(0, geometry.inf, cross_min, max_cross));
                used += main(s);
                cross_size = @max(cross_size, cross(s));
            }
            // Then the rest of the space, shared.
            if (total_flex > 0) {
                const free = @max(max_main - used, 0);
                for (n.children.items) |ch| {
                    const flex = flexOf(ch);
                    if (flex == 0) continue;
                    const share = free * flex / total_flex;
                    const s = ch.layout(constraints(share, share, cross_min, max_cross));
                    used += main(s);
                    cross_size = @max(cross_size, cross(s));
                }
            }

            const main_size = std.math.clamp(if (self.main_axis_size == .max and bounded) max_main else used, min_main, max_main);
            const final_cross = std.math.clamp(if (stretch) max_cross else cross_size, min_cross, max_cross);

            // Where the children go: with too little space, from the start
            // (and they overflow at the end).
            const remaining = main_size - used;
            const k: f32 = @floatFromInt(count);
            var lead: f32 = 0;
            var between: f32 = 0;
            if (remaining > 0) switch (self.main_axis_alignment) {
                .start => {},
                .center => lead = remaining / 2,
                .end => lead = remaining,
                .space_between => between = if (count > 1) remaining / (k - 1) else 0,
                .space_around => {
                    between = remaining / k;
                    lead = between / 2;
                },
                .space_evenly => {
                    between = remaining / (k + 1);
                    lead = between;
                },
            };
            var pos = lead;
            for (n.children.items) |ch| {
                const s = ch.size;
                const off = switch (self.cross_axis_alignment) {
                    .start, .stretch => 0,
                    .center => (final_cross - cross(s)) / 2,
                    .end => final_cross - cross(s),
                };
                if (axis == .horizontal) ch.place(pos, off) else ch.place(off, pos);
                pos += main(s) + spacing + between;
            }
            return sized(main_size, final_cross);
        }
    };
}

/// Children in rows of equal cells, left to right and top to bottom, as
/// many to a row as fit its width (at least one).
pub const Grid = struct {
    children: []const Widget = &.{},
    cell: Size,
    /// Space between cells, across and down.
    spacing: f32 = 0,

    pub fn layout(self: *const Grid, n: *Node, c: Constraints) Size {
        const count = n.childCount();
        const gap = if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
        const cw = @max(self.cell.w, 0);
        const chh = @max(self.cell.h, 0);
        const columns: usize = if (!c.boundedWidth())
            @max(count, 1)
        else
            @max(1, @as(usize, @intFromFloat(@max(@floor((c.max_w + gap) / (cw + gap)), 0))));
        const rows = (count + columns - 1) / columns;
        for (n.children.items, 0..) |ch, i| {
            _ = ch.layout(.tight(.{ .w = cw, .h = chh }));
            const col: f32 = @floatFromInt(i % columns);
            const row: f32 = @floatFromInt(i / columns);
            ch.place(col * (cw + gap), row * (chh + gap));
        }
        const used_columns: f32 = @floatFromInt(@min(columns, count));
        const r: f32 = @floatFromInt(rows);
        return c.constrain(.{
            .w = if (c.boundedWidth()) c.max_w else used_columns * (cw + gap) - (if (count > 0) gap else 0),
            .h = r * (chh + gap) - (if (rows > 0) gap else 0),
        });
    }
};

/// Layers over each other, filling it (later ones on top, and first to
/// get the pointer). Each layer positions its content itself (with
/// `Align`, `Padding` and so on).
pub const Overlay = struct {
    children: []const Widget = &.{},

    pub fn layout(_: *const Overlay, n: *Node, c: Constraints) Size {
        var size = c.biggest();
        // Unbounded: as big as the biggest layer wants.
        if (!c.boundedWidth() or !c.boundedHeight()) {
            var want: Size = .{};
            for (n.children.items) |ch| {
                const s = ch.layout(c.loosen());
                want = .{ .w = @max(want.w, s.w), .h = @max(want.h, s.h) };
            }
            size = c.constrain(.{ .w = if (c.boundedWidth()) c.max_w else want.w, .h = if (c.boundedHeight()) c.max_h else want.h });
        }
        for (n.children.items) |ch| _ = ch.layout(.tight(size));
        return size;
    }
};

pub const Border = struct {
    width: f32 = 1,
    color: gfx.Color,
};

/// A rounded rectangle behind the child: filled, outlined, or both. It is
/// the child's size, or as big as allowed without one.
pub const Decorated = struct {
    color: ?gfx.Color = null,
    border: ?Border = null,
    radius: gfx.Radii = .{},
    child: ?Widget = null,

    pub fn paint(self: *const Decorated, n: *Node, p: *Painter) void {
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        if (self.color) |col| c.fillRoundedRect(r, self.radius, col);
        if (self.border) |b| c.strokeRoundedRect(r, self.radius, b.width, b.color);
    }

    /// Filled, it takes the pointer (what is under it cannot be clicked).
    pub fn hitTest(self: *const Decorated, _: *Node, _: Point) bool {
        return if (self.color) |col| col.a > 0 else false;
    }
};

/// Whether the pointer is over a widget, and pressing it.
pub const Interaction = struct {
    hovered: bool = false,
    pressed: bool = false,
};

pub const btn_left = 0x110;

/// Calls `on_press` when the child is clicked (the left button pressed
/// and released over it), and keeps `interaction` up to date (for widgets
/// that look different when hovered or pressed: give it their state's).
pub const Pressable = struct {
    on_press: ?Callback = null,
    interaction: ?*Interaction = null,
    child: ?Widget = null,

    pub fn event(self: *const Pressable, _: *Node, e: Event) bool {
        var dummy: Interaction = .{};
        const i = self.interaction orelse &dummy;
        switch (e) {
            .enter => i.hovered = true,
            .leave => i.hovered = false,
            .press => |p| {
                if (p.button != btn_left or self.on_press == null) return false;
                i.pressed = true;
                return true;
            },
            .release => |r| {
                i.pressed = false;
                if (r.inside) if (self.on_press) |f| f.call();
                return true;
            },
            else => {},
        }
        return false;
    }
};
