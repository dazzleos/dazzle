//! LazyGrid: kete's `Grid` (many items the same size, only those that
//! show made), and a list too: with an infinite cell width, one column of
//! items as wide as it. `keep` makes an item even when it does not show
//! (one a scroll view is to reveal). Dazzle's apps' lists, from Dazzle's
//! own toolkit, on kete.
//!
//!     cx.make(kete.ScrollView{ .child = cx.make(kete_vc4.LazyGrid{
//!         .count = files.len,
//!         .cell = .{ .w = 128, .h = 124 },
//!         .item = .of(view, View.tile),
//!     }) })
//!
//! The items made are those of the frame before (so they are built with
//! the rest of the tree); if the scroll view shows other rows once laid
//! out, they are made then. Items are matched to their nodes by index,
//! unless the item has a key.

const std = @import("std");
const kete = @import("kete");

const Size = kete.Size;
const Rect = kete.Rect;
const Constraints = kete.Constraints;
const Widget = kete.Widget;
const Node = kete.WidgetNode;
const Context = kete.BuildContext;

pub const LazyGrid = struct {
    count: usize,
    cell: Size,
    /// Space between cells, across and down.
    spacing: f32 = 0,
    item: ItemBuilder,
    /// Rows made beyond those in view, above and below, so a little
    /// scrolling needs nothing made.
    extra_rows: usize = 1,
    /// An item made even when it does not show: one a scroll view is to
    /// reveal (see `ScrollView.reveal`), say.
    keep: ?usize = null,

    /// Makes item `index` (in the frame's arena, with `cx.make`).
    pub const ItemBuilder = struct {
        ctx: *const anyopaque,
        f: *const fn (*const anyopaque, *Context, usize) Widget,

        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context, usize) Widget) ItemBuilder {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .f = struct {
                fn call(ctx: *const anyopaque, cx: *Context, i: usize) Widget {
                    return f(@as(P, @ptrCast(@alignCast(@constCast(ctx)))), cx, i);
                }
            }.call };
        }
    };

    pub const State = struct {
        /// The items made: from `first` up to `end`, and `kept` (made even
        /// though it does not show).
        first: usize = 0,
        end: usize = 0,
        kept: ?usize = null,
    };

    /// The items made with the rest of the tree: those of the last frame
    /// (and the item to keep).
    pub fn children(self: *const LazyGrid, cx: *Context, n: *Node) []const Widget {
        const st = n.state(State);
        st.end = @min(st.end, self.count);
        st.first = @min(st.first, st.end);
        st.kept = self.extra(st.first, st.end);
        return self.make(cx, st.*);
    }

    /// The item to keep, if it is not among those from `first` to `end`.
    fn extra(self: *const LazyGrid, first: usize, end: usize) ?usize {
        const k = self.keep orelse return null;
        return if (k < self.count and (k < first or k >= end)) k else null;
    }

    fn make(self: *const LazyGrid, cx: *Context, st: State) []const Widget {
        const len = st.end - st.first + @intFromBool(st.kept != null);
        const out = cx.arena.alloc(Widget, len) catch return &.{};
        for (out, 0..) |*w, k| {
            const i = self.index(st, k);
            const item = self.item.f(self.item.ctx, cx, i);
            w.* = if (item.key == null) item.withKey(i) else item;
        }
        return out;
    }

    /// The index of the `k`th item made.
    fn index(_: *const LazyGrid, st: State, k: usize) usize {
        return if (k < st.end - st.first) st.first + k else st.kept.?;
    }

    fn gap(self: *const LazyGrid) f32 {
        return if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
    }

    /// A list: one column, its items as wide as it.
    fn isList(self: *const LazyGrid) bool {
        return !std.math.isFinite(self.cell.w);
    }

    fn columns(self: *const LazyGrid, width: f32) usize {
        if (self.isList()) return 1;
        if (!std.math.isFinite(width)) return @max(self.count, 1);
        const cw = @max(self.cell.w, 0);
        return @max(1, @as(usize, @intFromFloat(@max(@floor((width + self.gap()) / (cw + self.gap())), 0))));
    }

    pub fn layout(self: *const LazyGrid, n: *Node, c: Constraints) Size {
        const cols = self.columns(c.max_w);
        const rows = (self.count + cols - 1) / cols;
        const cw = if (self.isList()) 0 else @max(self.cell.w, 0);
        const ch = @max(self.cell.h, 0);
        const used: f32 = @floatFromInt(@min(cols, self.count));
        const r: f32 = @floatFromInt(rows);
        const content: Size = .{
            .w = if (c.boundedWidth()) c.max_w else used * (cw + self.gap()) - (if (self.count > 0) self.gap() else 0),
            .h = r * (ch + self.gap()) - (if (rows > 0) self.gap() else 0),
        };
        const size = c.constrain(content);
        n.size = size;
        self.place(n, cols);
        // In a scroll view, it says what shows once it is laid out (see
        // `realize`); otherwise all of it is made, like a `Grid`'s.
        if (n.ui.scrolling == 0) self.realize(n, .{ .x = 0, .y = 0, .w = content.w, .h = content.h });
        return size;
    }

    /// Lays out the items made, each in its cell.
    fn place(self: *const LazyGrid, n: *Node, cols: usize) void {
        const st = n.state(State);
        const cell: Size = .{ .w = if (self.isList()) n.size.w else @max(self.cell.w, 0), .h = @max(self.cell.h, 0) };
        for (n.children.items, 0..) |child, k| {
            const i = self.index(st.*, k);
            _ = child.layout(.tight(cell));
            const col: f32 = @floatFromInt(i % cols);
            const row: f32 = @floatFromInt(i / cols);
            child.place(col * (cell.w + self.gap()), row * (cell.h + self.gap()));
        }
    }

    /// `visible` (relative to the grid) is what shows: the items in the
    /// rows it covers are made, if they are not already, and laid out.
    pub fn realize(self: *const LazyGrid, n: *Node, visible: Rect) void {
        const cols = self.columns(n.size.w);
        const pitch = @max(self.cell.h, 0) + self.gap();
        var want: State = .{};
        if (visible.h > 0 and visible.w > 0 and pitch > 0 and visible.y + visible.h > 0) {
            const top: usize = @intFromFloat(@max(@floor(visible.y / pitch), 0));
            const bottom: usize = @intFromFloat(@max(@ceil((visible.y + visible.h) / pitch), 0));
            want.first = @min((top -| self.extra_rows) * cols, self.count);
            want.end = @min((bottom + self.extra_rows) * cols, self.count);
        }
        want.kept = self.extra(want.first, want.end);
        const len = want.end - want.first + @intFromBool(want.kept != null);
        const st = n.state(State);
        if (std.meta.eql(st.*, want) and n.children.items.len == len) return;
        st.* = want;
        var cx: Context = .{ .ui = n.ui, .arena = n.ui.arena(), .node = n, .theme_ptr = n.theme_ptr };
        n.reconcile(self.make(&cx, want));
        if (n.children.items.len != len) {
            // Out of memory: none rather than the wrong ones.
            n.reconcile(&.{});
            st.* = .{};
        }
        self.place(n, cols);
    }
};

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

fn find(n: *Node, comptime T: type) ?*Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (find(ch, T)) |f| return f;
    return null;
}

const red: kete.Color = .rgb(0xff0000);
const blue: kete.Color = .rgb(0x0000ff);

const LazyItems = struct {
    pressed: ?usize = null,
    made: usize = 0,

    const Press = struct {
        items: *LazyItems,
        i: usize,
        fn f(p: *const Press) void {
            p.items.pressed = p.i;
        }
    };

    fn item(items: *LazyItems, cx: *Context, i: usize) Widget {
        items.made += 1;
        const p = cx.arena.create(Press) catch unreachable;
        p.* = .{ .items = items, .i = i };
        return cx.make(kete.Pressable{ .on_press = .of(p, Press.f), .child = cx.make(kete.RoundedBox{ .color = if (i % 2 == 0) red else blue }) });
    }

    /// Item `i`, keyed 1000 + i for the scroll view to reveal.
    fn row(items: *LazyItems, cx: *Context, i: usize) Widget {
        return item(items, cx, i).withKey(1000 + @as(u64, i));
    }
};

const LazyApp = struct {
    items: *LazyItems,
    in_scroll_view: bool = true,
    pub fn build(self: *const @This(), cx: *Context) Widget {
        const grid = cx.make(LazyGrid{ .count = 100, .cell = .{ .w = 50, .h = 40 }, .spacing = 10, .item = .of(self.items, LazyItems.item) });
        return cx.make(kete.Align{ .alignment = .top_left, .child = cx.make(kete.SizedBox{ .width = 200, .height = 300, .child = if (self.in_scroll_view) cx.make(kete.ScrollView{ .child = grid }) else grid }) });
    }
};

test "a lazy grid makes only the rows that show, as it scrolls" {
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var items: LazyItems = .{};
    u.frame(400, 400, 0, LazyApp{ .items = &items });
    const view = find(u.root.?, kete.ScrollView).?;
    const grid = find(view, LazyGrid).?;
    // Rows 0 to 5 show (300 of 50 each), and one more is made, three to a row.
    try testing.expectEqual(@as(usize, 21), grid.childCount());
    try testing.expectEqual(kete.Point{ 60, 50 }, grid.child(4).offset);
    try testing.expectEqual(kete.Size{ .w = 50, .h = 40 }, grid.child(4).size);
    // The next frame makes the same ones, with the rest of the tree.
    items.made = 0;
    u.frame(400, 400, 1, LazyApp{ .items = &items });
    try testing.expectEqual(@as(usize, 21), items.made);

    // Scrolled to 1000: rows 20 to 25 show; 19 to 26 are made.
    _ = view.state(kete.ScrollView.State).scrollTo(1000);
    u.frame(400, 400, 2, LazyApp{ .items = &items });
    try testing.expectEqual(@as(usize, 24), grid.childCount());
    try testing.expectEqual(@as(?u64, 57), grid.child(0).widget.key);
    try testing.expectEqual(kete.Point{ 0, 19 * 50 }, grid.child(0).offset);
    // Pressing one presses the right item.
    u.pointerMotion(.{ 70, 15 });
    u.pointerButton(.{ 70, 15 }, .left, true);
    u.pointerButton(.{ 70, 15 }, .left, false);
    try testing.expectEqual(@as(?usize, 61), items.pressed);

    // Not in a scroll view: all of it shows.
    u.frame(400, 400, 3, LazyApp{ .items = &items, .in_scroll_view = false });
    try testing.expectEqual(@as(usize, 100), find(u.root.?, LazyGrid).?.childCount());
}

const LazyList = struct {
    items: *LazyItems,
    reveal: ?usize = null,
    pub fn build(self: *const @This(), cx: *Context) Widget {
        const list = cx.make(LazyGrid{ .count = 100, .cell = .{ .w = std.math.inf(f32), .h = 30 }, .item = .of(self.items, LazyItems.row), .keep = self.reveal });
        return cx.make(kete.Align{ .alignment = .top_left, .child = cx.make(kete.SizedBox{ .width = 200, .height = 300, .child = cx.make(kete.ScrollView{
            .reveal = if (self.reveal) |r| 1000 + @as(u64, r) else null,
            .child = list,
        }) }) });
    }
};

test "a lazy list's items are as wide as it, and one far down can be revealed" {
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var items: LazyItems = .{};
    u.frame(400, 400, 0, LazyList{ .items = &items });
    const view = find(u.root.?, kete.ScrollView).?;
    const list = find(view, LazyGrid).?;
    // One column, each row as wide as the list: ten rows show, and one
    // more is made.
    try testing.expectEqual(@as(usize, 11), list.childCount());
    try testing.expectEqual(list.size.w, list.child(3).size.w);
    try testing.expectEqual(@as(f32, 30), list.child(3).size.h);
    try testing.expectEqual(kete.Point{ 0, 90 }, list.child(3).offset);
    try testing.expectEqual(@as(f32, 3000), list.size.h);

    // Revealing row 80, which is not made: it is kept, so the scroll view
    // finds it and scrolls to it, and the rows around it are made.
    u.frame(400, 400, 1, LazyList{ .items = &items, .reveal = 80 });
    const st = view.state(kete.ScrollView.State);
    try testing.expectEqual(@as(f32, 81 * 30 - 300), st.offset);
    var made = false;
    for (list.children.items) |ch| if (ch.widget.key == 1000 + 80) {
        try testing.expectEqual(kete.Point{ 0, 80 * 30 }, ch.offset);
        made = true;
    };
    try testing.expect(made);
    // Scrolled back to the top, row 80 is still made (and kept last).
    _ = st.scrollTo(0);
    u.frame(400, 400, 2, LazyList{ .items = &items, .reveal = 80 });
    try testing.expectEqual(@as(usize, 12), list.childCount());
    try testing.expectEqual(@as(?u64, 1000 + 80), list.child(11).widget.key);
    try testing.expectEqual(kete.Point{ 0, 80 * 30 }, list.child(11).offset);
}
