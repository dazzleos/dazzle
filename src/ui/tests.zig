//! Tests of the toolkit: layouts (sensible and not), state, input, and
//! what is painted (drawn on the CPU with the real shaders).

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const vc4 = @import("vc4");
const ui = @import("ui.zig");

const testing = std.testing;
const Widget = ui.Widget;
const Context = ui.Context;
const Node = ui.Node;

const fira_data = @embedFile("FiraSans-Regular.ttf");

/// The first node (depth first) whose widget is a `T`.
fn find(n: *Node, comptime T: type) ?*Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (find(ch, T)) |f| return f;
    return null;
}

fn findAll(n: *Node, comptime T: type, out: *std.ArrayList(*Node)) !void {
    if (n.widget.is(T)) try out.append(testing.allocator, n);
    for (n.children.items) |ch| try findAll(ch, T, out);
}

const Image = struct {
    pixels: []u32,
    img: gfx.preview.Image,

    fn init(u: *ui.Ui, w: u32, h: u32) !Image {
        const pixels = try testing.allocator.alloc(u32, w * h);
        @memset(pixels, 0xff000000);
        const img: gfx.preview.Image = .{ .pixels = pixels, .width = w, .height = h };
        try u.preview(img);
        return .{ .pixels = pixels, .img = img };
    }

    fn deinit(i: Image) void {
        testing.allocator.free(i.pixels);
    }

    fn at(i: Image, x: u32, y: u32) u32 {
        return i.img.at(x, y);
    }
};

fn channels(px: u32) [3]u8 {
    return .{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
}

fn isYellow(px: u32) bool {
    const c = channels(px);
    return c[0] > 150 and c[1] > 150 and c[2] < 100;
}

const red = gfx.Color.rgb(0xff0000);
const blue = gfx.Color.rgb(0x0000ff);

/// A root made by a function, for tests.
fn Root(comptime f: fn (*Context) Widget) type {
    return struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return f(cx);
        }
    };
}

test "an overflowing row is clipped, and striped along the edge it overflows" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 100, .height = 40, .child = cx.make(ui.Row{ .children = &.{
                cx.make(ui.SizedBox{ .width = 80, .child = cx.make(ui.Decorated{ .color = red }) }),
                cx.make(ui.SizedBox{ .width = 80, .child = cx.make(ui.Decorated{ .color = blue }) }),
            } }) }) });
        }
    }.f;
    u.frame(200, 60, 0, Root(build){});
    const row = find(u.root.?, ui.Row).?;
    try testing.expectEqual(@as(f32, 60), row.overflow.right);
    try testing.expectEqual(@as(f32, 0), row.overflow.bottom);
    const img = try Image.init(u, 200, 60);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(40, 20));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(85, 20));
    // The stripes along the right edge: some yellow there, none before.
    var yellow: u32 = 0;
    for (0..40) |y| for (92..100) |x| {
        yellow += @intFromBool(isYellow(img.at(@intCast(x), @intCast(y))));
    };
    try testing.expect(yellow > 40);
    // Nothing past the row.
    for (0..60) |y| try testing.expectEqual(@as(u32, 0xff000000), img.at(120, @intCast(y)));
    for (0..200) |x| try testing.expectEqual(@as(u32, 0xff000000), img.at(@intCast(x), 50));
}

/// A widget whose layout returns nonsense.
const Nonsense = struct {
    pub fn layout(_: *const Nonsense, _: *Node, _: ui.Constraints) ui.Size {
        return .{ .w = std.math.nan(f32), .h = -std.math.inf(f32) };
    }
};

test "layouts that make no sense still lay out" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Column{
                .children = &.{
                    // A column in a column: unbounded height, where Expanded
                    // has no space to share.
                    cx.make(ui.Column{ .children = &.{
                        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = "Expanded in unbounded space" }) }),
                        cx.make(Nonsense{}),
                    } }),
                    // A row in a row: unbounded width.
                    cx.make(ui.Row{ .children = &.{cx.make(ui.Row{ .children = &.{cx.make(ui.Text{ .text = "Row in a row" })} })} }),
                    cx.make(ui.SizedBox{ .width = -5, .height = std.math.nan(f32) }),
                    cx.make(ui.Padding{ .padding = .all(1000), .child = cx.make(ui.Text{ .text = "Padded away" }) }),
                    cx.make(ui.Center{ .child = cx.make(ui.Overlay{}) }),
                },
            });
        }
    }.f;
    u.frame(300, 200, 0, Root(build){});
    // Everything got a finite size, and the column says it overflows.
    const Check = struct {
        fn all(n: *Node) !void {
            try testing.expect(std.math.isFinite(n.size.w) and n.size.w >= 0);
            try testing.expect(std.math.isFinite(n.size.h) and n.size.h >= 0);
            for (n.children.items) |ch| try all(ch);
        }
    };
    try Check.all(u.root.?);
    try testing.expect(u.root.?.child(0).overflow.bottom > 0);
    const img = try Image.init(u, 300, 200);
    img.deinit();
}

const Counter = struct {
    pub const State = struct {
        count: u32 = 0,
        fn add(s: *State) void {
            s.count += 1;
        }
    };

    pub fn build(_: *const Counter, cx: *Context, state: *State) Widget {
        return cx.make(ui.Column{ .children = &.{
            cx.make(ui.Text{ .text = cx.fmt("Count {d}", .{state.count}) }),
            cx.make(ui.OutlinedButton{ .label = "Add", .on_press = .of(state, State.add) }),
            cx.make(ui.OutlinedButton{ .label = "Disabled" }),
        } });
    }
};

fn click(u: *ui.Ui, n: *Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.widgets.btn_left, true);
    u.pointerButton(p, ui.widgets.btn_left, false);
}

test "buttons call back, state lasts between frames, and hovering tints" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    u.frame(300, 200, 0, Counter{});
    var buttons: std.ArrayList(*Node) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(u.root.?, ui.OutlinedButton, &buttons);
    try testing.expectEqual(@as(usize, 2), buttons.items.len);
    // Material's size, centred in the column.
    try testing.expectEqual(@as(f32, 40), buttons.items[0].size.h);

    click(u, buttons.items[0]);
    click(u, buttons.items[0]);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    u.frame(300, 200, 1, Counter{});
    try testing.expectEqualStrings("Count 2", find(u.root.?, ui.Text).?.widget.as(ui.Text).?.text);
    // Still over the button: tinted.
    try testing.expect(find(buttons.items[0], ui.Decorated).?.widget.as(ui.Decorated).?.color != null);

    // The disabled button does nothing, and is not tinted.
    click(u, buttons.items[1]);
    u.frame(300, 200, 2, Counter{});
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    try testing.expect(find(buttons.items[1], ui.Decorated).?.widget.as(ui.Decorated).?.color == null);

    // Pressing, moving off and releasing is not a click.
    const b = buttons.items[0];
    const at = b.position();
    u.pointerMotion(.{ at[0] + 5, at[1] + 20 });
    u.pointerButton(.{ at[0] + 5, at[1] + 20 }, ui.widgets.btn_left, true);
    u.pointerMotion(.{ 299, 199 });
    u.pointerButton(.{ 299, 199 }, ui.widgets.btn_left, false);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
}

var freed: u32 = 0;

const Keeper = struct {
    id: u32,
    pub const State = struct {
        id: u32,
        pub fn deinit(_: *State) void {
            freed += 1;
        }
    };
    pub fn initState(self: *const Keeper) State {
        return .{ .id = self.id };
    }
    pub fn build(_: *const Keeper, cx: *Context, _: *State) Widget {
        return cx.make(ui.SizedBox{ .width = 10, .height = 10 });
    }
};

const Keepers = struct {
    ids: []const u32,
    pub fn build(self: *const Keepers, cx: *Context) Widget {
        var children = cx.arena.alloc(Widget, self.ids.len) catch return cx.make(ui.Empty{});
        for (self.ids, 0..) |id, i| children[i] = cx.make(Keeper{ .id = id }).withKey(id);
        return cx.make(ui.Column{ .children = children });
    }
};

test "keys keep state when siblings come and go, and dropped state is freed" {
    const u = try ui.Ui.create(testing.allocator, null);
    freed = 0;
    u.frame(100, 100, 0, Keepers{ .ids = &.{ 1, 2, 3 } });
    u.frame(100, 100, 0, Keepers{ .ids = &.{ 3, 1 } });
    var keepers: std.ArrayList(*Node) = .empty;
    defer keepers.deinit(testing.allocator);
    try findAll(u.root.?, Keeper, &keepers);
    try testing.expectEqual(@as(u32, 3), keepers.items[0].state(Keeper.State).id);
    try testing.expectEqual(@as(u32, 1), keepers.items[1].state(Keeper.State).id);
    try testing.expectEqual(@as(u32, 1), freed);
    u.destroy();
    try testing.expectEqual(@as(u32, 3), freed);
}

test "text wraps to fit, and a word that cannot is marked" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{
                .width = 70,
                .child = cx.make(ui.Text{ .text = "Some words then Supercalifragilistic", .style = .{ .size = 14 } }),
            }) });
        }
    }.f;
    u.frame(200, 200, 0, Root(build){});
    const t = find(u.root.?, ui.Text).?;
    const line = (font.Style{ .font = &fira, .size = 14 }).lineHeight();
    try testing.expect(t.size.h > 2.5 * line);
    try testing.expect(t.overflow.right > 0);
    const img = try Image.init(u, 200, 200);
    defer img.deinit();
    // Text was drawn.
    var lit: u32 = 0;
    for (img.pixels) |px| lit += @intFromBool(channels(px)[2] > 128);
    try testing.expect(lit > 50);
}

test "an overlay's top layer takes the pointer where it has something" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const S = struct {
        var below: u32 = 0;
        var above: u32 = 0;
        fn addBelow(_: *const u8) void {
            below += 1;
        }
        fn addAbove(_: *const u8) void {
            above += 1;
        }
        const token: u8 = 0;
        fn f(cx: *Context) Widget {
            return cx.make(ui.Overlay{ .children = &.{
                cx.make(ui.Pressable{ .on_press = .of(&token, addBelow) }),
                cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 50, .height = 50, .child = cx.make(ui.Pressable{ .on_press = .of(&token, addAbove) }) }) }),
            } });
        }
    };
    u.frame(200, 200, 0, Root(S.f){});
    for ([_]ui.Point{ .{ 10, 10 }, .{ 100, 100 }, .{ 20, 40 } }) |p| {
        u.pointerMotion(p);
        u.pointerButton(p, ui.widgets.btn_left, true);
        u.pointerButton(p, ui.widgets.btn_left, false);
    }
    try testing.expectEqual(@as(u32, 2), S.above);
    try testing.expectEqual(@as(u32, 1), S.below);
}

/// Draws straight to the GPU.
const GpuView = struct {
    fn draw(_: *const GpuView, _: *vc4.render.Frame, _: ui.GpuArea) anyerror!void {}
    pub fn paint(self: *const GpuView, _: *Node, p: *ui.Painter) void {
        p.gpu(self, draw);
    }
};

test "GPU draws go between the 2D layers, in the tree's order" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Overlay{ .children = &.{
                cx.make(ui.Decorated{ .color = red }),
                cx.make(ui.Padding{ .padding = .all(10), .child = cx.make(GpuView{}) }),
                cx.make(ui.Center{ .child = cx.make(ui.Text{ .text = "Over" }) }),
            } });
        }
    }.f;
    u.frame(200, 100, 0, Root(build){});
    const segs = u.segments.items;
    try testing.expectEqual(@as(usize, 3), segs.len);
    try testing.expect(segs[0] == .canvas and segs[1] == .gpu and segs[2] == .canvas);
    try testing.expectEqual(vc4.render.Viewport{ .x = 10, .y = 10, .width = 180, .height = 80 }, segs[1].gpu.area.viewport);
    try testing.expect(segs[1].gpu.area.scissor == null);
}

test "rows and columns align and space their children" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Column{ .children = &.{
                cx.make(ui.Row{ .main_axis_alignment = .center, .spacing = 10, .children = &.{
                    cx.make(ui.SizedBox{ .width = 20, .height = 10 }),
                    cx.make(ui.SizedBox{ .width = 30, .height = 20 }),
                } }),
                cx.make(ui.Row{ .main_axis_alignment = .space_between, .cross_axis_alignment = .end, .children = &.{
                    cx.make(ui.SizedBox{ .width = 20, .height = 10 }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.SizedBox{ .height = 5 }) }),
                    cx.make(ui.SizedBox{ .width = 30, .height = 20 }),
                } }),
            } });
        }
    }.f;
    u.frame(200, 100, 0, Root(build){});
    const col = u.root.?.child(0);
    const r1 = col.child(0);
    // 20 + 10 + 30 = 60 wide, centred in 200; the small box centred
    // across.
    try testing.expectEqual(ui.Point{ 70, 5 }, r1.child(0).offset);
    try testing.expectEqual(ui.Point{ 100, 0 }, r1.child(1).offset);
    try testing.expectEqual(@as(f32, 20), r1.size.h);
    const r2 = col.child(1);
    try testing.expectEqual(@as(f32, 150), r2.child(1).size.w);
    try testing.expectEqual(ui.Point{ 170, 0 }, r2.child(2).offset);
    try testing.expectEqual(ui.Point{ 20, 15 }, r2.child(1).offset);
}

const Choice = enum { a, b, c };

const Controls = struct {
    pub const State = struct {
        checked: bool = false,
        on: bool = false,
        choice: Choice = .a,
        fn setChecked(s: *State, v: bool) void {
            s.checked = v;
        }
        fn setOn(s: *State, v: bool) void {
            s.on = v;
        }
        fn choose(s: *State, v: Choice) void {
            s.choice = v;
        }
    };

    pub fn build(_: *const Controls, cx: *Context, state: *State) Widget {
        return cx.make(ui.Column{ .cross_axis_alignment = .start, .children = &.{
            cx.make(ui.Checkbox{ .value = state.checked, .on_changed = .of(state, State.setChecked), .label = "Check" }),
            cx.make(ui.Switch{ .value = state.on, .on_changed = .of(state, State.setOn), .label = "Switch" }),
            cx.make(ui.Radio(Choice){ .value = .a, .group_value = state.choice, .on_changed = .of(state, State.choose), .label = "A" }),
            cx.make(ui.Radio(Choice){ .value = .b, .group_value = state.choice, .on_changed = .of(state, State.choose), .label = "B" }),
            cx.make(ui.Radio(Choice){ .value = .c, .group_value = state.choice, .label = "C (disabled)" }),
            cx.make(ui.Checkbox{ .value = true }),
        } });
    }
};

fn clickAt(u: *ui.Ui, p: ui.Point) void {
    u.pointerMotion(p);
    u.pointerButton(p, ui.widgets.btn_left, true);
    u.pointerButton(p, ui.widgets.btn_left, false);
}

test "checkboxes, switches and radio buttons report changes, and their labels press them" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    u.frame(400, 400, 0, Controls{});
    var items: std.ArrayList(*Node) = .empty;
    defer items.deinit(testing.allocator);
    try findAll(u.root.?, ui.Pressable, &items);
    try testing.expectEqual(@as(usize, 6), items.items.len);
    for (items.items[0..5]) |n| try testing.expectEqual(@as(f32, 40), n.size.h);
    const st = u.root.?.state(Controls.State);

    // The box itself, then the label.
    click(u, find(items.items[0], ui.controls.CheckboxMark).?);
    try testing.expect(st.checked);
    u.frame(400, 400, 1, Controls{});
    const label = find(items.items[0], ui.Text).?;
    click(u, label);
    try testing.expect(!st.checked);
    u.frame(400, 400, 2, Controls{});

    // The switch slides over, asking for frames until it is there.
    click(u, items.items[1]);
    try testing.expect(st.on);
    u.frame(400, 400, 3, Controls{});
    try testing.expect(u.needs_frame);
    u.frame(400, 400, 3 + ui.Switch.travel_ns / 2, Controls{});
    const mark = find(items.items[1], ui.controls.SwitchMark).?.widget.as(ui.controls.SwitchMark).?;
    try testing.expect(mark.position > 0.3 and mark.position < 0.7);
    u.frame(400, 400, 3 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expectEqual(@as(f32, 1), find(items.items[1], ui.controls.SwitchMark).?.widget.as(ui.controls.SwitchMark).?.position);
    u.frame(400, 400, 4 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expect(!u.needs_frame);

    // Radio buttons: choosing B selects it; C is disabled.
    click(u, items.items[3]);
    try testing.expectEqual(Choice.b, st.choice);
    click(u, items.items[4]);
    try testing.expectEqual(Choice.b, st.choice);
    u.frame(400, 400, 5 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expect(!find(items.items[2], ui.controls.RadioMark).?.widget.as(ui.controls.RadioMark).?.selected);
    try testing.expect(find(items.items[3], ui.controls.RadioMark).?.widget.as(ui.controls.RadioMark).?.selected);

    // A disabled checkbox ignores clicks (and draws without failing).
    click(u, items.items[5]);
    const img = try Image.init(u, 400, 400);
    img.deinit();
}

const Label = struct {
    text: []const u8,
    pub fn build(self: *const Label, cx: *Context) Widget {
        return cx.make(ui.Column{ .cross_axis_alignment = .start, .children = &.{
            cx.make(ui.Text{ .text = "Static title" }),
            cx.make(ui.Text{ .text = self.text }),
            cx.make(ui.OutlinedButton{ .label = "Button", .on_press = .of(&dummy_count, addDummy) }),
        } });
    }
};

var dummy_count: u32 = 0;
fn addDummy(c: *u32) void {
    c.* += 1;
}

fn within(r: ui.Rect, outer: ui.Rect) bool {
    return r.x >= outer.x and r.y >= outer.y and r.x + r.w <= outer.x + outer.w and r.y + r.h <= outer.y + outer.h;
}

test "only what changed is damaged" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    u.frame(300, 200, 0, Label{ .text = "One" });
    // The first frame: everything.
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 300, .h = 200 }, u.damaged()[0]);
    // The same again: nothing.
    u.frame(300, 200, 1, Label{ .text = "One" });
    try testing.expect(!u.changed());
    try testing.expect(u.repaint(1).isEmpty());

    // New text: only around it.
    u.frame(300, 200, 2, Label{ .text = "Two" });
    try testing.expect(u.changed());
    var texts: std.ArrayList(*Node) = .empty;
    defer texts.deinit(testing.allocator);
    try findAll(u.root.?, ui.Text, &texts);
    const second = texts.items[1];
    const at = second.position();
    // Glyphs can reach an em around the text's box.
    const near: ui.Rect = .{ .x = at[0] - 20, .y = at[1] - 30, .w = second.size.w + 60, .h = second.size.h + 50 };
    for (u.damaged()) |r| try testing.expect(within(r, near));
    const first = texts.items[0];
    for (u.damaged()) |r| try testing.expect(r.y > first.position()[1]);

    // Hovering the button: only the button.
    const button = find(u.root.?, ui.OutlinedButton).?;
    const b = button.position();
    u.pointerMotion(.{ b[0] + 10, b[1] + 10 });
    u.frame(300, 200, 3, Label{ .text = "Two" });
    const box: ui.Rect = .{ .x = b[0] - 2, .y = b[1] - 2, .w = button.size.w + 4, .h = button.size.h + 4 };
    try testing.expect(u.changed());
    for (u.damaged()) |r| try testing.expect(within(r, box));
    // The buffer from two frames ago also needs the text's change.
    try testing.expect(u.repaint(2).len >= 1);
    var covers_text = false;
    for (u.repaint(2).slice()) |r| covers_text = covers_text or r.intersects(.{ .x = at[0], .y = at[1], .w = second.size.w, .h = second.size.h });
    try testing.expect(covers_text);
}

const Maybe = struct {
    show: bool,
    pub fn build(self: *const Maybe, cx: *Context) Widget {
        return cx.make(ui.Column{ .children = if (self.show) &.{
            cx.make(ui.SizedBox{ .width = 50, .height = 20, .child = cx.make(ui.Decorated{ .color = red }) }),
        } else &.{} });
    }
};

test "a removed widget damages where it was" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    u.frame(200, 100, 0, Maybe{ .show = true });
    u.frame(200, 100, 1, Maybe{ .show = true });
    try testing.expect(!u.changed());
    u.frame(200, 100, 2, Maybe{ .show = false });
    try testing.expect(u.changed());
    for (u.damaged()) |r| try testing.expect(within(r, .{ .x = 74, .y = 0, .w = 52, .h = 22 }));
}

const Keyed = struct {
    key: ?u64,
    fn draw(_: *const Keyed, _: *vc4.render.Frame, _: ui.GpuArea) anyerror!void {}
    pub fn paint(self: *const Keyed, _: *Node, p: *ui.Painter) void {
        p.gpuWith(.{ .key = self.key, .bounds = .{ .x = 10, .y = 10, .w = 20, .h = 20 } }, self, draw);
    }
};

test "GPU draws are damaged every frame, unless their key stays the same" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    u.frame(100, 100, 0, Keyed{ .key = null });
    u.frame(100, 100, 1, Keyed{ .key = null });
    try testing.expectEqual(ui.Rect{ .x = 10, .y = 10, .w = 20, .h = 20 }, u.damaged()[0]);
    u.frame(100, 100, 2, Keyed{ .key = 7 });
    u.frame(100, 100, 3, Keyed{ .key = 7 });
    try testing.expect(!u.changed());
    u.frame(100, 100, 4, Keyed{ .key = 8 });
    try testing.expectEqual(ui.Rect{ .x = 10, .y = 10, .w = 20, .h = 20 }, u.damaged()[0]);
}

test "a grid puts as many cells in a row as fit" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            var cells: [7]Widget = undefined;
            for (&cells) |*c| c.* = cx.make(ui.Decorated{ .color = red });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 250, .child = cx.make(ui.Grid{ .cell = .{ .w = 60, .h = 40 }, .spacing = 10, .children = &cells }) }) });
        }
    }.f;
    u.frame(400, 300, 0, Root(build){});
    var cells: std.ArrayList(*Node) = .empty;
    defer cells.deinit(testing.allocator);
    try findAll(u.root.?, ui.Decorated, &cells);
    // 250 wide: three 60-wide cells with 10 between (four would need 270).
    try testing.expectEqual(@as(usize, 7), cells.items.len);
    try testing.expectEqual(ui.Point{ 140, 0 }, cells.items[2].offset);
    try testing.expectEqual(ui.Point{ 0, 50 }, cells.items[3].offset);
    try testing.expectEqual(ui.Point{ 0, 100 }, cells.items[6].offset);
    try testing.expectEqual(ui.Size{ .w = 60, .h = 40 }, cells.items[6].size);
    const grid = find(u.root.?, ui.Grid).?;
    try testing.expectEqual(ui.Size{ .w = 250, .h = 140 }, grid.size);
}

test "a scroll view scrolls with the wheel and its bar, and paints only what shows" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows, 0..) |*r, i| r.* = cx.make(ui.SizedBox{ .height = 50, .child = cx.make(ui.Decorated{ .color = if (i % 2 == 0) red else blue }) });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    }.f;
    u.frame(400, 400, 0, Root(build){});
    const view = find(u.root.?, ui.ScrollView).?;
    const column = view.child(0);
    const st = view.state(ui.ScrollView.State);
    // Too tall: the bar takes its width, and nothing counts as overflow.
    try testing.expectEqual(ui.Size{ .w = 200, .h = 300 }, view.size);
    try testing.expectEqual(@as(f32, 188), column.size.w);
    try testing.expectEqual(@as(f32, 1000), st.content);
    try testing.expect(!view.overflow.any());
    // Rows below the view are not painted.
    try testing.expect(column.child(5).paint.valid);
    try testing.expect(!column.child(6).paint.valid);

    // The wheel: a notch (15 pixels) scrolls three times that.
    u.pointerScroll(.{ 100, 100 }, 0, 15);
    try testing.expect(u.needs_frame);
    u.frame(400, 400, 1, Root(build){});
    try testing.expectEqual(@as(f32, 45), st.offset);
    try testing.expectEqual(ui.Point{ 0, -45 }, column.offset);
    try testing.expect(u.changed());
    // No further than the end, and no further back than the top.
    u.pointerScroll(.{ 100, 100 }, 0, 10000);
    u.frame(400, 400, 2, Root(build){});
    try testing.expectEqual(@as(f32, 700), st.offset);
    try testing.expect(!column.child(0).paint.valid);
    try testing.expect(column.child(19).paint.valid);
    u.pointerScroll(.{ 100, 100 }, 0, -10000);
    u.frame(400, 400, 3, Root(build){});
    try testing.expectEqual(@as(f32, 0), st.offset);
    // At the top already, the wheel up is not taken.
    u.needs_frame = false;
    u.pointerScroll(.{ 100, 100 }, 0, -15);
    try testing.expect(!u.needs_frame);

    // Pressing the bar below the thumb (90 tall: 300 of 1000) jumps there,
    // centred on the pointer; dragging moves it.
    u.pointerMotion(.{ 194, 255 });
    u.pointerButton(.{ 194, 255 }, ui.widgets.btn_left, true);
    // The thumb's top at 210 of the 210 it can travel: the end.
    try testing.expectEqual(@as(f32, 700), st.offset);
    u.pointerMotion(.{ 194, 150 });
    try testing.expectEqual(@as(f32, 350), st.offset);
    u.pointerButton(.{ 194, 150 }, ui.widgets.btn_left, false);
    try testing.expect(st.grab == null);
    u.frame(400, 400, 4, Root(build){});
    try testing.expectEqual(ui.Point{ 0, -350 }, column.offset);

    // Content that fits needs no bar, and does not scroll.
    const short = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.SizedBox{ .height = 100, .child = cx.make(ui.Decorated{ .color = red }) }),
            }) }) });
        }
    }.f;
    u.frame(400, 400, 5, Root(short){});
    const v2 = find(u.root.?, ui.ScrollView).?;
    try testing.expectEqual(@as(f32, 200), v2.child(0).size.w);
    try testing.expectEqual(@as(f32, 0), v2.state(ui.ScrollView.State).offset);
}

test "a scroll view scrolls to the widget it is told to reveal, once" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const Reveal = struct {
        target: ?u64,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows, 0..) |*r, i| r.* = cx.make(ui.SizedBox{ .height = 50, .child = cx.make(ui.Decorated{ .color = red }) }).withKey(i);
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .reveal = self.target,
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    };
    u.frame(400, 400, 0, Reveal{ .target = 12 });
    const st = find(u.root.?, ui.ScrollView).?.state(ui.ScrollView.State);
    // Row 12 (600 to 650) at the bottom of the view.
    try testing.expectEqual(@as(f32, 350), st.offset);
    // Scrolled away, it stays away until another is revealed.
    _ = st.scrollTo(0);
    u.frame(400, 400, 1, Reveal{ .target = 12 });
    try testing.expectEqual(@as(f32, 0), st.offset);
    u.frame(400, 400, 2, Reveal{ .target = 19 });
    try testing.expectEqual(@as(f32, 700), st.offset);
    // Above the view: at its top.
    u.frame(400, 400, 3, Reveal{ .target = 2 });
    try testing.expectEqual(@as(f32, 100), st.offset);
}
