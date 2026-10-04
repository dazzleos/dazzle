//! The demo's window, as widgets: its title bar, and under it the rings and
//! the spinning solid behind a column with the statistics, buttons for the solid's speed, radio
//! buttons to choose the Platonic solid, and switches for lighting and
//! texture.
//!
//! The solid and the rings are widgets that paint themselves: the solid
//! draws straight into the GPU frame, the rings on the canvas.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const vc4 = @import("vc4");
const solids = @import("solids.zig");
const rings_mod = @import("rings.zig");

const Shape = solids.Shape;

pub const title_color = gfx.Color.argb(0xffffffff);
pub const text_color = gfx.Color.argb(0xffd8e0f0);
pub const dim_color = gfx.Color.argb(0xff8090b0);

/// Lines of statistics under the title.
pub const lines = 5;

pub const Demo = struct {
    /// Null in tests (nothing is drawn where it would be).
    solids: ?*solids.Solids,
    rings: *rings_mod.Rings,
    status: [lines][]const u8,
    /// Sizes are designed for 1080 pixels high and scale with the window.
    scale: f32,
    /// The title bar's close button; and the title bar's scale (the
    /// screen's, so every app's title bar is the same).
    on_close: ?ui.Callback = null,
    bar_scale: f32 = 1,

    pub const State = struct {
        /// The solid's rotation, in seconds at normal speed.
        time: f32 = 0,
        shape: Shape = .cube,
        look: solids.Look = .{},
        last_ns: ?u64 = null,
        speed: f32 = 1,
        paused: bool = false,

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
    };

    pub fn build(self: *const Demo, cx: *ui.Context, state: *State) ui.Widget {
        const now = cx.now();
        if (state.last_ns) |last| if (!state.paused) {
            state.time += @as(f32, @floatFromInt(now -| last)) / std.time.ns_per_s * state.speed;
        };
        state.last_ns = now;
        // Frames while something moves: the solid, or rings fading.
        if (!state.paused or self.rings.len > 0) cx.requestFrame();

        const s = self.scale;
        const title = 52 * s;
        const small = 28 * s;

        var status: [lines]ui.Widget = undefined;
        for (&status, self.status, 0..) |*w, line, i| {
            w.* = cx.make(ui.Text{ .text = line, .style = .{ .size = small, .color = if (i == 0) text_color else dim_color }, .wrap = false });
        }
        const speed = if (state.paused) "Paused" else cx.fmt("Spinning at {d}×", .{state.speed});
        var radios: [solids.shapes.len]ui.Widget = undefined;
        for (&radios, solids.shapes) |*w, shape| {
            w.* = cx.make(ui.Radio(Shape){ .value = shape, .group_value = state.shape, .on_changed = .of(state, State.choose), .label = shape.name() });
        }

        const content = cx.make(ui.Overlay{ .children = &.{
            cx.make(RingsView{ .rings = self.rings, .now = now, .unit = s }),
            cx.make(SolidView{ .solids = self.solids, .time = state.time, .shape = state.shape, .look = state.look }),
            cx.make(ui.Padding{ .padding = .all(@floor(24 * s)), .child = cx.make(ui.Column{
                .cross_axis_alignment = .start,
                .main_axis_size = .min,
                .spacing = 6 * s,
                .children = &.{
                    cx.make(ui.Text{ .text = "Stardust", .style = .{ .size = title, .color = title_color }, .wrap = false }),
                    status[0],
                    status[1],
                    status[2],
                    status[3],
                    status[4],
                    cx.make(ui.SizedBox{ .height = 10 * s }),
                    cx.make(ui.Row{ .spacing = 8, .main_axis_size = .min, .children = &.{
                        cx.make(ui.OutlinedButton{ .label = "Slower", .on_press = .of(state, State.slower) }),
                        cx.make(ui.OutlinedButton{ .label = if (state.paused) "Resume" else "Pause", .on_press = .of(state, State.pause) }),
                        cx.make(ui.OutlinedButton{ .label = "Faster", .on_press = .of(state, State.faster) }),
                        cx.make(ui.Padding{ .padding = .{ .left = 8 }, .child = cx.make(ui.Text{ .text = speed, .style = .{ .size = 18 * s, .color = dim_color }, .wrap = false }) }),
                    } }),
                    cx.make(ui.SizedBox{ .height = 10 * s }),
                    cx.make(ui.Text{ .text = cx.fmt("{s}  ·  {d} triangles", .{ state.shape.name(), state.shape.triangles() }), .style = .{ .size = 18 * s, .color = dim_color }, .wrap = false }),
                    radios[0],
                    radios[1],
                    radios[2],
                    radios[3],
                    radios[4],
                    cx.make(ui.SizedBox{ .height = 4 * s }),
                    cx.make(ui.Switch{ .value = state.look.lighting, .on_changed = .of(state, State.setLighting), .label = "Lighting" }),
                    cx.make(ui.Switch{ .value = state.look.texturing, .on_changed = .of(state, State.setTexturing), .label = "Texture" }),
                },
            }) }),
        } });
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{ .title = "Demo", .on_close = self.on_close, .scale = self.bar_scale }),
            cx.make(ui.Expanded{ .child = content }),
        } });
    }
};

/// The spinning solid, filling its space, drawn straight into the frame.
pub const SolidView = struct {
    solids: ?*solids.Solids,
    time: f32,
    shape: Shape,
    look: solids.Look,

    pub fn paint(self: *const SolidView, n: *ui.Node, p: *ui.Painter) void {
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

    fn draw(self: *const SolidView, frame: *vc4.render.Frame, area: ui.GpuArea) anyerror!void {
        try self.solids.?.draw(frame, area.viewport, area.scissor, self.time, self.shape, self.look);
    }
};

/// The rings where the pointer clicked, over the whole window.
pub const RingsView = struct {
    rings: *rings_mod.Rings,
    now: u64,
    unit: f32,

    pub fn paint(self: *const RingsView, _: *ui.Node, p: *ui.Painter) void {
        self.rings.draw(p.canvas(), self.now, self.unit);
    }
};

// --- Tests -------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");

fn findNode(n: *ui.Node, comptime T: type) ?*ui.Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findNode(ch, T)) |f| return f;
    return null;
}

test "the panel fits beside the solids in the shell's window, without overflowing" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const status = [lines][]const u8{ "60.0 fps  ·  1920×1036", "GPU 6.50 ms per frame", "CPU 0.50 ms per frame", "Pointer 1919, 1035  ·  last key Backspace", "62 °C  ·  CPU speed 100%  ·  busy 45%" };
    for ([_][2]u32{ .{ 1920, 1036 }, .{ 1920, 1080 } }) |size| {
        const scale = @min(@as(f32, @floatFromInt(size[0])) / 1920, @as(f32, @floatFromInt(size[1])) / 1080);
        u.frame(size[0], size[1], 0, Demo{ .solids = null, .rings = &rings, .status = status, .scale = scale });
        // The panel: the column in the content (under the title bar).
        const col = findNode(findNode(u.root.?, ui.Expanded).?, ui.Column).?;
        const Check = struct {
            fn none(n: *ui.Node) !void {
                try testing.expect(!n.overflow.any());
                for (n.children.items) |ch| try none(ch);
            }
        };
        try Check.none(u.root.?);
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
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const demo: Demo = .{ .solids = null, .rings = &rings, .status = @splat(""), .scale = 1 };
    u.frame(1920, 1080, 0, demo);
    var buttons: [3]*ui.Node = undefined;
    var n: usize = 0;
    const Collect = struct {
        fn f(node: *ui.Node, out: []*ui.Node, k: *usize) void {
            if (node.widget.is(ui.OutlinedButton) and k.* < out.len) {
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
        const p: ui.Point = .{ at[0] + 10, at[1] + 10 };
        u.pointerMotion(p);
        u.pointerButton(p, ui.widgets.btn_left, true);
        u.pointerButton(p, ui.widgets.btn_left, false);
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
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const demo: Demo = .{ .solids = null, .rings = &rings, .status = @splat(""), .scale = 1 };
    u.frame(1920, 1080, 0, demo);
    const Collect = struct {
        fn all(node: *ui.Node, comptime T: type, out: []*ui.Node, k: *usize) void {
            if (node.widget.is(T) and k.* < out.len) {
                out[k.*] = node;
                k.* += 1;
            }
            for (node.children.items) |ch| all(ch, T, out, k);
        }
    };
    var radios: [5]*ui.Node = undefined;
    var n: usize = 0;
    Collect.all(u.root.?, ui.Radio(Shape), &radios, &n);
    try testing.expectEqual(@as(usize, 5), n);
    var switches: [2]*ui.Node = undefined;
    n = 0;
    Collect.all(u.root.?, ui.Switch, &switches, &n);
    try testing.expectEqual(@as(usize, 2), n);
    for ([_]*ui.Node{ radios[4], switches[0], switches[1], switches[1] }) |w| {
        const at = w.position();
        const p: ui.Point = .{ at[0] + 10, at[1] + 20 };
        u.pointerMotion(p);
        u.pointerButton(p, ui.widgets.btn_left, true);
        u.pointerButton(p, ui.widgets.btn_left, false);
        u.frame(1920, 1080, 0, demo);
    }
    const st = u.root.?.state(Demo.State);
    try testing.expectEqual(Shape.icosahedron, st.shape);
    try testing.expect(!st.look.lighting);
    try testing.expect(st.look.texturing);
}

test "while paused and still, frames change nothing and none are asked for" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const demo: Demo = .{ .solids = null, .rings = &rings, .status = @splat("same"), .scale = 1 };
    u.frame(1920, 1080, 0, demo);
    u.root.?.state(Demo.State).paused = true;
    u.frame(1920, 1080, 1, demo);
    u.frame(1920, 1080, 2, demo);
    try testing.expect(!u.changed());
    try testing.expect(!u.needs_frame);
}
