//! Where a popup goes (xdg_positioner): a rectangle of its parent to
//! anchor it to, the point of that rectangle to anchor at, the direction
//! the popup extends from there (its gravity), an offset, and what may be
//! done when it would not fit the area it must be in (the work area): flip
//! it to the other side of the anchor, slide it, or make it smaller, on
//! each axis, in that order, as xdg-shell says.

const std = @import("std");
const p = @import("wayland").protocol;

pub const Positioner = struct {
    width: i32 = 0,
    height: i32 = 0,
    anchor_rect: [4]i32 = .{ 0, 0, 0, 0 },
    anchor: u32 = 0,
    gravity: u32 = 0,
    offset: [2]i32 = .{ 0, 0 },
    /// What may be done to make it fit (`adjust`'s bits).
    constraint_adjustment: u32 = 0,
    /// Placed again when its parent moves.
    reactive: bool = false,
};

/// xdg_positioner.constraint_adjustment's bits.
pub const adjust = struct {
    pub const slide_x = 1;
    pub const slide_y = 2;
    pub const flip_x = 4;
    pub const flip_y = 8;
    pub const resize_x = 16;
    pub const resize_y = 32;
};

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Which way an anchor or gravity points, across and down: -1, 0 or 1.
fn direction(value: u32) [2]i32 {
    const a = p.xdg_positioner.anchor;
    return switch (value) {
        a.top => .{ 0, -1 },
        a.bottom => .{ 0, 1 },
        a.left => .{ -1, 0 },
        a.right => .{ 1, 0 },
        a.top_left => .{ -1, -1 },
        a.bottom_left => .{ -1, 1 },
        a.top_right => .{ 1, -1 },
        a.bottom_right => .{ 1, 1 },
        else => .{ 0, 0 },
    };
}

/// Where the popup starts on one axis: the anchor point (`dir_anchor` of
/// the rectangle from `start`, `len` long), then extending from it the
/// way `dir_gravity` says (centred on it for neither way), offset.
fn axisStart(start: i32, len: i32, size: i32, dir_anchor: i32, dir_gravity: i32, offset: i32) i32 {
    const point = start + @divTrunc(len * (dir_anchor + 1), 2);
    return point - @divTrunc(size * (1 - dir_gravity), 2) + offset;
}

/// One axis: its start and size, placed and then adjusted to fit between
/// `lo` and `hi` as `flip`, `slide` and `resize` allow.
fn axis(start: i32, len: i32, size: i32, dir_anchor: i32, dir_gravity: i32, offset: i32, lo: i32, hi: i32, flip: bool, slide: bool, resize: bool) [2]i32 {
    var at = axisStart(start, len, size, dir_anchor, dir_gravity, offset);
    var n = size;
    const fits = struct {
        fn f(a: i32, s: i32, l: i32, h: i32) bool {
            return a >= l and a + s <= h;
        }
    }.f;
    if (fits(at, n, lo, hi)) return .{ at, n };
    // Flipped to the other side of the anchor (and the offset with it),
    // if that fits.
    if (flip) {
        const flipped = axisStart(start, len, size, -dir_anchor, -dir_gravity, -offset);
        if (fits(flipped, n, lo, hi)) return .{ flipped, n };
    }
    // Slid back in, the start edge first if it cannot all fit.
    if (slide) {
        if (at + n > hi) at = hi - n;
        if (at < lo) at = lo;
        if (fits(at, n, lo, hi)) return .{ at, n };
    }
    // Made smaller: what is outside is cut off (at least a pixel stays).
    if (resize) {
        if (at < lo) {
            n -= lo - at;
            at = lo;
        }
        if (at + n > hi) n = hi - at;
        if (n < 1) n = 1;
    }
    return .{ at, n };
}

/// Where the popup goes, relative to its parent; `area` (relative to the
/// parent too) is where it must be, if known.
pub fn place(pos: Positioner, area: ?Rect) Rect {
    const anchor = direction(pos.anchor);
    const gravity = direction(pos.gravity);
    const r = pos.anchor_rect;
    const a = area orelse Rect{ .x = std.math.minInt(i32) / 2, .y = std.math.minInt(i32) / 2, .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) };
    const adj = pos.constraint_adjustment;
    const x = axis(r[0], r[2], pos.width, anchor[0], gravity[0], pos.offset[0], a.x, a.x +| a.w, adj & adjust.flip_x != 0, adj & adjust.slide_x != 0, adj & adjust.resize_x != 0);
    const y = axis(r[1], r[3], pos.height, anchor[1], gravity[1], pos.offset[1], a.y, a.y +| a.h, adj & adjust.flip_y != 0, adj & adjust.slide_y != 0, adj & adjust.resize_y != 0);
    return .{ .x = x[0], .y = y[0], .w = x[1], .h = y[1] };
}

const testing = std.testing;
const A = p.xdg_positioner.anchor;

test "a popup goes from its anchor the way its gravity says" {
    // Under the bottom left of a 40x10 rectangle at 20,30, extending down
    // and right.
    const pos: Positioner = .{ .width = 100, .height = 50, .anchor_rect = .{ 20, 30, 40, 10 }, .anchor = A.bottom_left, .gravity = A.bottom_right };
    try testing.expectEqual(Rect{ .x = 20, .y = 40, .w = 100, .h = 50 }, place(pos, null));
    // Centred on the middle of the rectangle, with neither.
    try testing.expectEqual(Rect{ .x = -10, .y = 10, .w = 100, .h = 50 }, place(.{ .width = 100, .height = 50, .anchor_rect = .{ 20, 30, 40, 10 } }, null));
    // Up and left from the top right, offset.
    try testing.expectEqual(Rect{ .x = -45, .y = -15, .w = 100, .h = 50 }, place(.{ .width = 100, .height = 50, .anchor_rect = .{ 20, 30, 40, 10 }, .anchor = A.top_right, .gravity = A.top_left, .offset = .{ -5, 5 } }, null));
}

test "a popup that would not fit is flipped, slid or made smaller, as allowed" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    // A menu from a button near the bottom right corner: down and right
    // would go off both edges.
    var pos: Positioner = .{ .width = 200, .height = 150, .anchor_rect = .{ 700, 540, 60, 30 }, .anchor = A.bottom_left, .gravity = A.bottom_right };
    // Nothing allowed: it stays where it was put.
    try testing.expectEqual(Rect{ .x = 700, .y = 570, .w = 200, .h = 150 }, place(pos, area));
    // Flipped: up from the top and left from the right of the button.
    pos.constraint_adjustment = adjust.flip_x | adjust.flip_y;
    try testing.expectEqual(Rect{ .x = 560, .y = 390, .w = 200, .h = 150 }, place(pos, area));
    // Slid: in, against the edges.
    pos.constraint_adjustment = adjust.slide_x | adjust.slide_y;
    try testing.expectEqual(Rect{ .x = 600, .y = 450, .w = 200, .h = 150 }, place(pos, area));
    // Made smaller: cut at the edges.
    pos.constraint_adjustment = adjust.resize_x | adjust.resize_y;
    try testing.expectEqual(Rect{ .x = 700, .y = 570, .w = 100, .h = 30 }, place(pos, area));
    // A flip that would not fit either is not done; sliding is next.
    pos = .{ .width = 300, .height = 50, .anchor_rect = .{ 100, 0, 600, 10 }, .anchor = A.right, .gravity = A.right, .constraint_adjustment = adjust.flip_x | adjust.slide_x };
    try testing.expectEqual(Rect{ .x = 500, .y = -20, .w = 300, .h = 50 }, place(pos, area));
    // Too big to slide all in: its start edge shows; then cut.
    pos = .{ .width = 900, .height = 50, .anchor_rect = .{ 100, 100, 0, 0 }, .anchor = A.bottom_right, .gravity = A.bottom_right, .constraint_adjustment = adjust.slide_x | adjust.resize_x };
    try testing.expectEqual(Rect{ .x = 0, .y = 100, .w = 800, .h = 50 }, place(pos, area));
}
