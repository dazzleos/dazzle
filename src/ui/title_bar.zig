//! TitleBar: the bar across the top of an app's window, with its title in
//! the middle and, at the right end, buttons that maximize (or restore) and
//! close it; dragging the bar moves the window. Apps draw their own (the
//! shell draws none), so it goes at the top of the app's widgets:
//!
//!     cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
//!         cx.make(ui.TitleBar{ .title = "Settings", .on_close = .of(app, App.quit) }),
//!         cx.make(ui.Expanded{ .child = content }),
//!     } })

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const widgets = @import("widgets.zig");
const painter_mod = @import("painter.zig");

const Node = widget.Node;
const Context = widget.Context;
const Widget = widget.Widget;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

pub const TitleBar = struct {
    title: []const u8,
    /// Pressing the close button; without it there is none.
    on_close: ?widget.Callback = null,
    /// Pressing the maximize button (which shows whether the window fills
    /// the screen); without it there is none.
    on_maximize: ?widget.Callback = null,
    maximized: bool = true,
    /// A press on the bar itself, to start moving the window.
    on_drag: ?widget.Callback = null,
    /// Sizes are designed for a 1080-pixel screen and scale with this.
    scale: f32 = 1,

    pub const height = 44;

    pub fn build(self: *const TitleBar, cx: *Context) Widget {
        const t = cx.theme();
        const s = self.scale;
        const size = @round(34 * s);
        var buttons: [2]Widget = undefined;
        var n: usize = 0;
        if (self.on_maximize) |f| {
            buttons[n] = cx.make(BarButton{ .on_press = f, .size = size, .icon = if (self.maximized) .restore else .maximize });
            n += 1;
        }
        if (self.on_close) |f| {
            buttons[n] = cx.make(BarButton{ .on_press = f, .size = size, .icon = .close });
            n += 1;
        }
        const row = cx.make(widgets.Align{ .alignment = .center_right, .child = cx.make(widgets.Padding{
            .padding = .{ .right = @round(8 * s) },
            .child = cx.make(widgets.Row{ .spacing = @round(4 * s), .main_axis_size = .min, .children = cx.ui.arena().dupe(Widget, buttons[0..n]) catch &.{} }),
        }) });
        return cx.make(DragArea{ .on_drag = self.on_drag, .child = cx.make(widgets.Decorated{ .color = t.surface_container, .child = cx.make(widgets.SizedBox{
            .height = @round(height * s),
            .child = cx.make(widgets.Overlay{ .children = &.{
                cx.make(widgets.Center{ .child = cx.make(@import("text.zig").Text{ .text = self.title, .style = .{ .size = 22 * s, .color = t.on_surface }, .wrap = false }) }),
                row,
            } }),
        }) }) });
    }
};

/// Calls `on_drag` when pressed (the buttons on it get their presses
/// first). It does not take the pointer: the shell does, to move the
/// window, so the release never comes here.
const DragArea = struct {
    on_drag: ?widget.Callback,
    child: ?Widget = null,

    pub fn event(self: *const DragArea, _: *Node, e: widget.Event) bool {
        switch (e) {
            .press => |p| if (p.button == widgets.btn_left) if (self.on_drag) |f| f.call(),
            else => {},
        }
        return false;
    }
};

pub const Icon = enum { close, maximize, restore };

/// A round button with an icon, highlighted under the pointer.
pub const BarButton = struct {
    on_press: widget.Callback,
    size: f32,
    icon: Icon,

    pub const State = struct {
        interaction: widgets.Interaction = .{},
    };

    pub fn build(self: *const BarButton, cx: *Context, state: *State) Widget {
        return cx.make(widgets.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(Mark{
            .icon = self.icon,
            .size = self.size,
            .hovered = state.interaction.hovered,
            .pressed = state.interaction.pressed,
        }) });
    }
};

const Mark = struct {
    icon: Icon,
    size: f32,
    hovered: bool,
    pressed: bool,

    pub fn layout(self: *const Mark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const Mark, n: *Node, p: *Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        if (self.hovered or self.pressed) c.fillCircle(mid, n.size.w / 2, t.on_surface.withAlpha(if (self.pressed) 0.16 else 0.08));
        const arm = n.size.w * 0.17;
        const width = @max(n.size.w / 17, 1.5);
        const color = t.on_surface_variant;
        switch (self.icon) {
            .close => {
                c.strokePolyline(&.{ .{ mid[0] - arm, mid[1] - arm }, .{ mid[0] + arm, mid[1] + arm } }, false, width, color);
                c.strokePolyline(&.{ .{ mid[0] - arm, mid[1] + arm }, .{ mid[0] + arm, mid[1] - arm } }, false, width, color);
            },
            // A square: fill the screen.
            .maximize => c.strokeRect(.{ .x = mid[0] - arm, .y = mid[1] - arm, .w = 2 * arm, .h = 2 * arm }, width, color),
            // Two squares, one behind the other: back to half the screen.
            .restore => {
                const a = arm * 0.8;
                const o = arm * 0.4;
                c.strokePolyline(&.{ .{ mid[0] - a + o, mid[1] - a - o }, .{ mid[0] + a + o, mid[1] - a - o }, .{ mid[0] + a + o, mid[1] + a - o } }, false, width, color);
                c.strokeRect(.{ .x = mid[0] - a - o, .y = mid[1] - a + o, .w = 2 * a, .h = 2 * a }, width, color);
            },
        }
    }
};

const testing = std.testing;

test "the title bar's buttons, and dragging it" {
    const Ui = @import("runtime.zig").Ui;
    const font = @import("font");
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();
    const App = struct {
        closed: bool = false,
        drags: u32 = 0,
        maximizes: u32 = 0,
        fn close(a: *@This()) void {
            a.closed = true;
        }
        fn drag(a: *@This()) void {
            a.drags += 1;
        }
        fn maximize(a: *@This()) void {
            a.maximizes += 1;
        }
    };
    var app: App = .{};
    u.frame(800, 600, 0, widgets.Column{ .cross_axis_alignment = .stretch, .children = &.{} });
    const Root = struct {
        app: *App,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(widgets.Column{ .cross_axis_alignment = .stretch, .children = &.{
                cx.make(TitleBar{ .title = "Settings", .on_close = .of(self.app, App.close), .on_maximize = .of(self.app, App.maximize), .on_drag = .of(self.app, App.drag) }),
            } });
        }
    };
    u.frame(800, 600, 0, Root{ .app = &app });
    // The bar is across the top, 44 high; the button at its right end.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, widgets.btn_left, true);
    u.pointerButton(at, widgets.btn_left, false);
    try testing.expect(app.closed);
    // Elsewhere on the bar starts a drag (and closes nothing).
    app.closed = false;
    u.pointerMotion(.{ 400, 22 });
    u.pointerButton(.{ 400, 22 }, widgets.btn_left, true);
    try testing.expect(!app.closed);
    try testing.expectEqual(@as(u32, 1), app.drags);
    // The shell takes the pointer for the drag, so no release comes; the
    // next press still works. The maximize button is left of the close
    // button.
    const max_at: geometry.Point = .{ 800 - 8 - 34 - 4 - 17, 22 };
    u.pointerMotion(max_at);
    u.pointerButton(max_at, widgets.btn_left, true);
    u.pointerButton(max_at, widgets.btn_left, false);
    try testing.expectEqual(@as(u32, 1), app.maximizes);
    try testing.expectEqual(@as(u32, 1), app.drags);
}
