//! The demo's window, as kete widgets: the rings and
//! the spinning solid behind a column with the statistics, buttons for the solid's speed, radio
//! buttons to choose the Platonic solid, and switches for lighting and
//! texture.
//!
//! The solid and the rings are widgets that paint themselves: the solid
//! draws straight into the GPU frame, the rings on the canvas.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const locale = @import("locale");
const gfx = kete.gfx;
const vc4 = @import("vc4");
const solids = @import("solids.zig");
const rings_mod = @import("rings.zig");

const Shape = solids.Shape;

pub const text_color = gfx.Color.argb(0xffd8e0f0);
pub const dim_color = gfx.Color.argb(0xff8090b0);

/// Lines of statistics at the top of the panel.
pub const lines = 5;

/// The smallest the window may be: the panel's widest row, and a few of
/// its rows (it scrolls in a window shorter than it). Everything is the
/// same size in pixels whatever the window's size; the solid fills what
/// there is.
pub const min_size = [2]u32{ 560, 420 };

/// The size the window opens at: the shape beside its controls.
pub const open_size = [2]u32{ 960, 700 };

pub const Demo = struct {
    /// Null in tests (nothing is drawn where it would be).
    solids: ?*solids.Solids,
    rings: *rings_mod.Rings,
    status: [lines][]const u8,

    pub const State = struct {
        /// The solid's rotation, in seconds at normal speed.
        time: f32 = 0,
        shape: Shape = .cube,
        look: solids.Look = .{},
        last_ns: ?u64 = null,
        speed: f32 = 1,
        paused: bool = false,
        /// The window's buffers are RGB565, half the memory of 32-bit ones
        /// (main.zig asks for them).
        colour_16: bool = true,

        fn slower(s: *State) void {
            s.speed = @max(s.speed / 2, 0.125);
            s.paused = false;
        }
        fn faster(s: *State) void {
            s.speed = @min(s.speed * 2, 8);
            s.paused = false;
        }
        fn pause(s: *State) void {
            s.paused = !s.paused;
        }
        fn choose(s: *State, shape: Shape) void {
            s.shape = shape;
        }
        fn setLighting(s: *State, on: bool) void {
            s.look.lighting = on;
        }
        fn setTexturing(s: *State, on: bool) void {
            s.look.texturing = on;
        }
        fn setColour16(s: *State, on: bool) void {
            s.colour_16 = on;
        }
    };

    pub fn build(self: *const Demo, cx: *kete.BuildContext, state: *State) kete.Widget {
        const now = cx.now();
        if (state.last_ns) |last| if (!state.paused) {
            state.time += @as(f32, @floatFromInt(now -| last)) / std.time.ns_per_s * state.speed;
        };
        state.last_ns = now;
        // Frames while something moves: the solid, or rings fading.
        if (!state.paused or self.rings.len > 0) cx.requestFrame();

        const small = 28;

        var status: [lines]kete.Widget = undefined;
        for (&status, self.status, 0..) |*w, line, i| {
            w.* = cx.make(kete.Text{ .text = line, .style = .{ .size = small, .color = if (i == 0) text_color else dim_color }, .wrap = false });
        }
        const speed = if (state.paused) "Paused" else cx.fmt("Spinning at {d}×", .{state.speed});
        var radios: [solids.shapes.len]kete.Widget = undefined;
        for (&radios, solids.shapes) |*w, shape| {
            w.* = cx.make(kete.RadioRow(Shape){ .value = shape, .group_value = state.shape, .on_changed = .of(state, State.choose), .label = shape.name() });
        }

        return cx.make(RingsView{
            .rings = self.rings,
            .now = now,
            .child = cx.make(kete.Overlay{
                .children = &.{
                    cx.make(SolidView{ .solids = self.solids, .time = state.time, .shape = state.shape, .look = state.look }),
                    // The panel scrolls if the window is too small for it.
                    cx.make(kete.ScrollView{ .child = cx.make(kete.Padding{ .padding = .all(24), .child = cx.make(kete.Column{
                        .cross_axis_alignment = .start,
                        .fill = false,
                        .spacing = 6,
                        .children = &.{
                            status[0],
                            status[1],
                            status[2],
                            status[3],
                            status[4],
                            cx.make(kete.SizedBox{ .height = 10 }),
                            cx.make(kete.Row{ .spacing = 8, .fill = false, .children = &.{
                                cx.make(kete.OutlinedButton{ .label = "Slower", .icon = .fast_rewind, .on_press = .of(state, State.slower) }),
                                cx.make(kete.OutlinedButton{ .label = if (state.paused) "Resume" else "Pause", .icon = if (state.paused) .play_arrow else .pause, .on_press = .of(state, State.pause) }),
                                cx.make(kete.OutlinedButton{ .label = "Faster", .icon = .fast_forward, .on_press = .of(state, State.faster) }),
                                cx.make(kete.Padding{ .padding = .{ .left = 8 }, .child = cx.make(kete.Text{ .text = speed, .style = .{ .size = 18, .color = dim_color }, .wrap = false }) }),
                            } }),
                            cx.make(kete.SizedBox{ .height = 10 }),
                            cx.make(kete.Text{ .text = cx.fmt("{s}  ·  {d} triangles", .{ state.shape.name(), state.shape.triangles() }), .style = .{ .size = 18, .color = dim_color }, .wrap = false }),
                            radios[0],
                            radios[1],
                            radios[2],
                            radios[3],
                            radios[4],
                            cx.make(kete.SizedBox{ .height = 4 }),
                            cx.make(kete.SwitchRow{ .value = state.look.lighting, .on_changed = .of(state, State.setLighting), .label = "Lighting" }),
                            cx.make(kete.SwitchRow{ .value = state.look.texturing, .on_changed = .of(state, State.setTexturing), .label = "Texture" }),
                            cx.make(kete.SwitchRow{ .value = state.colour_16, .on_changed = .of(state, State.setColour16), .label = locale.text("16-bit colour") }),
                        },
                    }) }) }),
                },
            }),
        });
    }
};

/// The spinning solid, filling its space, drawn straight into the frame.
pub const SolidView = struct {
    solids: ?*solids.Solids,
    time: f32,
    shape: Shape,
    look: solids.Look,

    pub fn paint(self: *const SolidView, n: *kete.WidgetNode, p: *kete.Painter) void {
        if (self.solids == null) return;
        // It draws within the projection of its bounding sphere, and draws
        // the same while its time, shape and look are the same (so nothing
        // is redrawn while it is paused).
        const b = solids.screenBounds(@intFromFloat(@max(n.size.w, 1)), @intFromFloat(@max(n.size.h, 1)));
        var key = std.hash.Wyhash.init(0);
        key.update(std.mem.asBytes(&self.time));
        key.update(std.mem.asBytes(&self.shape));
        key.update(std.mem.asBytes(&self.look));
        p.gpuWith(.{ .bounds = .{ .x = b[0], .y = b[1], .w = b[2], .h = b[3] }, .key = key.final() }, self, draw);
    }

    fn draw(self: *const SolidView, frame: *vc4.render.Frame, area: kete.gfx.GpuArea) anyerror!void {
        const scissor = if (area.scissor) |sc| kete_vc4.renderer.viewport(sc) else null;
        try self.solids.?.draw(frame, kete_vc4.renderer.viewport(area.viewport), scissor, self.time, self.shape, self.look);
    }
};

/// The rings where the pointer clicked (with any button), behind the
/// content and clipped to it.
pub const RingsView = struct {
    rings: *rings_mod.Rings,
    now: u64,
    child: ?kete.Widget = null,

    pub const clips_children = true;

    pub fn paint(self: *const RingsView, _: *kete.WidgetNode, p: *kete.Painter) void {
        self.rings.draw(p.canvas(), self.now);
    }

    /// A press anywhere in it (on a control too) starts a ring there; the
    /// press still goes on to whatever is under it.
    pub fn event(self: *const RingsView, n: *kete.WidgetNode, e: kete.Event) bool {
        switch (e) {
            .press => |pr| {
                self.rings.add(@import("sys").nowNs(), pr.pos[0], pr.pos[1], .argb(buttonColor(pr.button)));
                n.ui.needs_frame = true;
            },
            else => {},
        }
        return false;
    }
};

pub fn buttonColor(button: kete.PointerButton) u32 {
    return switch (button) {
        .left => 0xff60d0ff,
        .right => 0xffffa040,
        .middle => 0xff80ff80,
        else => 0xffffffff,
    };
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;
const font = kete.font;

fn findNode(n: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findNode(ch, T)) |f| return f;
    return null;
}

test "the panel fits beside the solids in the shell's window, without overflowing" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const status = [lines][]const u8{ "60.0 fps  ·  1920×1036", "GPU 6.50 ms per frame", "CPU 0.50 ms per frame", "Pointer 1919, 1035  ·  last key Backspace", "62 °C  ·  CPU speed 100%  ·  busy 45%" };
    // Maximized, full screen, restored to half the size, and from the
    // smallest it may be to as wide or tall as a screen.
    for ([_][2]u32{ .{ 1920, 1036 }, .{ 1920, 1080 }, .{ 960, 518 }, min_size, .{ min_size[0], 1036 }, .{ 1920, min_size[1] }, .{ 1280, 668 } }) |size| {
        u.frame(size[0], size[1], 0, Demo{ .solids = null, .rings = &rings, .status = status });
        // The panel: the column in the content.
        const col = findNode(findNode(u.root.?, kete.ScrollView).?, kete.Column).?;
        const Check = struct {
            fn none(n: *kete.WidgetNode) !void {
                try testing.expect(!n.overflow.any());
                for (n.children.items) |ch| try none(ch);
            }
        };
        try Check.none(u.root.?);
        // Smaller, the solid is smaller and may go behind the panel.
        if (size[0] < 1920 or size[1] < 1036) continue;
        // The panel's widest child, against every solid's left edge.
        var right: f32 = 0;
        for (col.children.items) |ch| right = @max(right, ch.position()[0] + ch.size.w);
        const w: f32 = @floatFromInt(size[0]);
        for (solids.shapes) |shape| {
            const m = try solids.mesh(testing.allocator, shape);
            defer m.deinit(testing.allocator);
            var t: f32 = 0;
            while (t < 20) : (t += 0.05) {
                const mat = solids.mvp(size[0], size[1], t);
                for (m.vertices) |v| {
                    const p = v.pos;
                    const cw = p[0] * mat[3] + p[1] * mat[7] + p[2] * mat[11] + mat[15];
                    const x = ((p[0] * mat[0] + p[1] * mat[4] + p[2] * mat[8] + mat[12]) / cw + 1) / 2 * w;
                    try testing.expect(x > right);
                }
            }
        }
    }
}

test "the speed buttons" {
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const demo: Demo = .{ .solids = null, .rings = &rings, .status = @splat("") };
    u.frame(1920, 1080, 0, demo);
    var buttons: [3]*kete.WidgetNode = undefined;
    var n: usize = 0;
    const Collect = struct {
        fn f(node: *kete.WidgetNode, out: []*kete.WidgetNode, k: *usize) void {
            if (node.widget.is(kete.OutlinedButton) and k.* < out.len) {
                out[k.*] = node;
                k.* += 1;
            }
            for (node.children.items) |ch| f(ch, out, k);
        }
    };
    Collect.f(u.root.?, &buttons, &n);
    try testing.expectEqual(@as(usize, 3), n);
    for ([_]usize{ 2, 2, 0, 1 }) |b| {
        const at = buttons[b].position();
        const p: kete.Point = .{ at[0] + 10, at[1] + 10 };
        u.pointerMotion(p);
        u.pointerButton(p, .left, true);
        u.pointerButton(p, .left, false);
    }
    const st = u.root.?.state(Demo.State);
    try testing.expectEqual(@as(f32, 2), st.speed);
    try testing.expect(st.paused);
    // Paused, time stands still.
    u.frame(1920, 1080, std.time.ns_per_s, demo);
    u.frame(1920, 1080, 2 * std.time.ns_per_s, demo);
    try testing.expectEqual(@as(f32, 0), u.root.?.state(Demo.State).time);
}

test "the radio buttons choose the solid, and the switches its look" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const demo: Demo = .{ .solids = null, .rings = &rings, .status = @splat("") };
    u.frame(1920, 1080, 0, demo);
    const Collect = struct {
        fn all(node: *kete.WidgetNode, comptime T: type, out: []*kete.WidgetNode, k: *usize) void {
            if (node.widget.is(T) and k.* < out.len) {
                out[k.*] = node;
                k.* += 1;
            }
            for (node.children.items) |ch| all(ch, T, out, k);
        }
    };
    var radios: [5]*kete.WidgetNode = undefined;
    var n: usize = 0;
    Collect.all(u.root.?, kete.RadioRow(Shape), &radios, &n);
    try testing.expectEqual(@as(usize, 5), n);
    var switches: [3]*kete.WidgetNode = undefined;
    n = 0;
    Collect.all(u.root.?, kete.SwitchRow, &switches, &n);
    try testing.expectEqual(@as(usize, 3), n);
    for ([_]*kete.WidgetNode{ radios[4], switches[0], switches[1], switches[1], switches[2] }) |w| {
        const at = w.position();
        const p: kete.Point = .{ at[0] + 10, at[1] + 20 };
        u.pointerMotion(p);
        u.pointerButton(p, .left, true);
        u.pointerButton(p, .left, false);
        u.frame(1920, 1080, 0, demo);
    }
    const st = u.root.?.state(Demo.State);
    try testing.expectEqual(Shape.icosahedron, st.shape);
    try testing.expect(!st.look.lighting);
    try testing.expect(st.look.texturing);
    try testing.expect(!st.colour_16);
}

test "while paused and still, frames change nothing and none are asked for" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const demo: Demo = .{ .solids = null, .rings = &rings, .status = @splat("same") };
    u.frame(1920, 1080, 0, demo);
    u.root.?.state(Demo.State).paused = true;
    u.frame(1920, 1080, 1, demo);
    u.frame(1920, 1080, 2, demo);
    try testing.expect(!u.changed());
    try testing.expect(!u.needs_frame);
}

test "clicks make rings where they are, in the button's colour" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const status: [lines][]const u8 = @splat("");
    u.frame(1920, 1036, 0, Demo{ .solids = null, .rings = &rings, .status = status });
    u.pointerMotion(.{ 1500, 300 });
    u.pointerButton(.{ 1500, 300 }, .right, true);
    u.pointerButton(.{ 1500, 300 }, .right, false);
    try testing.expectEqual(@as(usize, 1), rings.len);
    try testing.expectEqual(gfx.Point{ 1500, 300 }, rings.rings[0].center);
    try testing.expectEqual(gfx.Color.argb(buttonColor(.right)), rings.rings[0].color);
}
