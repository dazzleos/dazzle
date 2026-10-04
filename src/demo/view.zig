//! The demo's window, as widgets: the rings and the cube behind a column
//! with the statistics, buttons for the cube's speed, and the shape
//! showcase.
//!
//! The cube, the rings and the showcase are widgets that paint themselves:
//! the cube draws straight into the GPU frame, the others on the canvas.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const vc4 = @import("vc4");
const cube_mod = @import("cube.zig");
const rings_mod = @import("rings.zig");
const shapes = @import("shapes.zig");

pub const title_color = gfx.Color.argb(0xffffffff);
pub const text_color = gfx.Color.argb(0xffd8e0f0);
pub const dim_color = gfx.Color.argb(0xff8090b0);

/// Lines of statistics under the title.
pub const lines = 6;

pub const Demo = struct {
    /// Null in tests (nothing is drawn where it would be).
    cube: ?*cube_mod.Cube,
    rings: *rings_mod.Rings,
    subtitle: []const u8,
    status: [lines][]const u8,
    /// Sizes are designed for 1080 pixels high and scale with the window.
    scale: f32,

    pub const State = struct {
        /// The cube's rotation, in seconds at normal speed.
        time: f32 = 0,
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
    };

    pub fn build(self: *const Demo, cx: *ui.Context, state: *State) ui.Widget {
        const now = cx.now();
        if (state.last_ns) |last| if (!state.paused) {
            state.time += @as(f32, @floatFromInt(now -| last)) / std.time.ns_per_s * state.speed;
        };
        state.last_ns = now;
        cx.requestFrame();

        const s = self.scale;
        const title = 52 * s;
        const small = 28 * s;
        // Bottom-aligned, the subtitle sits lower than the title by the
        // difference in their descents: lift it to share the baseline.
        const descent: f32 = if (cx.ui.font) |f| -@as(f32, @floatFromInt(f.descender)) / @as(f32, @floatFromInt(f.units_per_em)) else 0;

        var status: [lines]ui.Widget = undefined;
        for (&status, self.status, 0..) |*w, line, i| {
            w.* = cx.make(ui.Text{ .text = line, .style = .{ .size = small, .color = if (i == 0) text_color else dim_color }, .wrap = false });
        }
        const speed = if (state.paused) "Paused" else cx.fmt("Spinning at {d}×", .{state.speed});

        return cx.make(ui.Overlay{ .children = &.{
            cx.make(RingsView{ .rings = self.rings, .now = now, .unit = s }),
            cx.make(CubeView{ .cube = self.cube, .time = state.time }),
            cx.make(ui.Padding{ .padding = .all(@floor(24 * s)), .child = cx.make(ui.Column{
                .cross_axis_alignment = .start,
                .main_axis_size = .min,
                .spacing = 6 * s,
                .children = &.{
                    cx.make(ui.Row{ .cross_axis_alignment = .end, .spacing = 16 * s, .main_axis_size = .min, .children = &.{
                        cx.make(ui.Text{ .text = "Stardust", .style = .{ .size = title, .color = title_color }, .wrap = false }),
                        cx.make(ui.Padding{ .padding = .{ .bottom = (title - small) * descent }, .child = cx.make(ui.Text{ .text = self.subtitle, .style = .{ .size = small, .color = dim_color }, .wrap = false }) }),
                    } }),
                    status[0],
                    status[1],
                    status[2],
                    status[3],
                    status[4],
                    status[5],
                    cx.make(ui.SizedBox{ .height = 10 * s }),
                    cx.make(ui.Row{ .spacing = 8, .main_axis_size = .min, .children = &.{
                        cx.make(ui.OutlinedButton{ .label = "Slower", .on_press = .of(state, State.slower) }),
                        cx.make(ui.OutlinedButton{ .label = if (state.paused) "Resume" else "Pause", .on_press = .of(state, State.pause) }),
                        cx.make(ui.OutlinedButton{ .label = "Faster", .on_press = .of(state, State.faster) }),
                        cx.make(ui.Padding{ .padding = .{ .left = 8 }, .child = cx.make(ui.Text{ .text = speed, .style = .{ .size = 18 * s, .color = dim_color }, .wrap = false }) }),
                    } }),
                    cx.make(ui.SizedBox{ .height = 10 * s }),
                    cx.make(ShowcaseView{}),
                },
            }) }),
        } });
    }
};

/// The spinning cube, filling its space, drawn straight into the frame.
pub const CubeView = struct {
    cube: ?*cube_mod.Cube,
    time: f32,

    pub fn paint(self: *const CubeView, _: *ui.Node, p: *ui.Painter) void {
        if (self.cube != null) p.gpu(self, draw);
    }

    fn draw(self: *const CubeView, frame: *vc4.render.Frame, area: ui.GpuArea) anyerror!void {
        try self.cube.?.draw(frame, area.viewport, area.scissor, self.time);
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

/// The 2D canvas's shape showcase (see shapes.zig), at its own size.
pub const ShowcaseView = struct {
    pub fn layout(_: *const ShowcaseView, _: *ui.Node, c: ui.Constraints) ui.Size {
        return c.constrain(.{ .w = shapes.size[0], .h = shapes.size[1] });
    }

    pub fn paint(_: *const ShowcaseView, _: *ui.Node, p: *ui.Painter) void {
        shapes.draw(p.canvas(), p.origin);
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

test "the panel fits beside the cube in the shell's window, without overflowing" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const status = [lines][]const u8{ "192.168.1.20  (eth0)", "60.0 fps  ·  1920×1036  ·  12 triangles", "GPU 6.50 ms per frame", "CPU 0.50 ms per frame", "Pointer 1919, 1035  ·  last key Backspace", "62 °C  ·  CPU speed 100%  ·  busy 45%" };
    for ([_][2]u32{ .{ 1920, 1036 }, .{ 1920, 1080 } }) |size| {
        const scale = @min(@as(f32, @floatFromInt(size[0])) / 1920, @as(f32, @floatFromInt(size[1])) / 1080);
        u.frame(size[0], size[1], 0, Demo{ .cube = null, .rings = &rings, .subtitle = "build 0123abc-dirty", .status = status, .scale = scale });
        const col = findNode(u.root.?, ui.Column).?;
        const Check = struct {
            fn none(n: *ui.Node) !void {
                try testing.expect(!n.overflow.any());
                for (n.children.items) |ch| try none(ch);
            }
        };
        try Check.none(u.root.?);
        // The panel's widest child, against the cube's left edge.
        var right: f32 = 0;
        for (col.children.items) |ch| right = @max(right, ch.position()[0] + ch.size.w);
        const w: f32 = @floatFromInt(size[0]);
        var t: f32 = 0;
        while (t < 20) : (t += 0.01) {
            const m = cube_mod.mvp(size[0], size[1], t);
            for (0..8) |i| {
                const p = [3]f32{ if (i & 1 != 0) 1 else -1, if (i & 2 != 0) 1 else -1, if (i & 4 != 0) 1 else -1 };
                const cw = p[0] * m[3] + p[1] * m[7] + p[2] * m[11] + m[15];
                const x = ((p[0] * m[0] + p[1] * m[4] + p[2] * m[8] + m[12]) / cw + 1) / 2 * w;
                try testing.expect(x > right);
            }
        }
    }
}

test "the speed buttons" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    var rings: rings_mod.Rings = .{};
    const demo: Demo = .{ .cube = null, .rings = &rings, .subtitle = "", .status = @splat(""), .scale = 1 };
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
