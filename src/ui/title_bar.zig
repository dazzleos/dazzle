//! TitleBar: the bar across the top of an app's window, with its title in
//! the middle and a button at the right end that closes it. Apps draw their
//! own (the shell draws none), so it goes at the top of the app's widgets:
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
    /// Sizes are designed for a 1080-pixel screen and scale with this.
    scale: f32 = 1,

    pub const height = 44;

    pub fn build(self: *const TitleBar, cx: *Context) Widget {
        const t = cx.theme();
        const s = self.scale;
        const close: Widget = if (self.on_close) |f|
            cx.make(widgets.Align{ .alignment = .center_right, .child = cx.make(widgets.Padding{
                .padding = .{ .right = @round(8 * s) },
                .child = cx.make(CloseButton{ .on_press = f, .size = @round(34 * s) }),
            }) })
        else
            cx.make(widgets.Empty{});
        return cx.make(widgets.Decorated{ .color = t.surface_container, .child = cx.make(widgets.SizedBox{
            .height = @round(height * s),
            .child = cx.make(widgets.Overlay{ .children = &.{
                cx.make(widgets.Center{ .child = cx.make(@import("text.zig").Text{ .text = self.title, .style = .{ .size = 22 * s, .color = t.on_surface }, .wrap = false }) }),
                close,
            } }),
        }) });
    }
};

/// A round button with a cross, highlighted under the pointer.
pub const CloseButton = struct {
    on_press: widget.Callback,
    size: f32,

    pub const State = struct {
        interaction: widgets.Interaction = .{},
    };

    pub fn build(self: *const CloseButton, cx: *Context, state: *State) Widget {
        return cx.make(widgets.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(CloseMark{
            .size = self.size,
            .hovered = state.interaction.hovered,
            .pressed = state.interaction.pressed,
        }) });
    }
};

const CloseMark = struct {
    size: f32,
    hovered: bool,
    pressed: bool,

    pub fn layout(self: *const CloseMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const CloseMark, n: *Node, p: *Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        if (self.hovered or self.pressed) c.fillCircle(mid, n.size.w / 2, t.on_surface.withAlpha(if (self.pressed) 0.16 else 0.08));
        const arm = n.size.w * 0.17;
        const width = @max(n.size.w / 17, 1.5);
        c.strokePolyline(&.{ .{ mid[0] - arm, mid[1] - arm }, .{ mid[0] + arm, mid[1] + arm } }, false, width, t.on_surface_variant);
        c.strokePolyline(&.{ .{ mid[0] - arm, mid[1] + arm }, .{ mid[0] + arm, mid[1] - arm } }, false, width, t.on_surface_variant);
    }
};

const testing = std.testing;

test "the title bar's close button closes" {
    const Ui = @import("runtime.zig").Ui;
    const font = @import("font");
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();
    const App = struct {
        closed: bool = false,
        fn close(a: *@This()) void {
            a.closed = true;
        }
    };
    var app: App = .{};
    u.frame(800, 600, 0, widgets.Column{ .cross_axis_alignment = .stretch, .children = &.{} });
    const Root = struct {
        app: *App,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(widgets.Column{ .cross_axis_alignment = .stretch, .children = &.{
                cx.make(TitleBar{ .title = "Settings", .on_close = .of(self.app, App.close) }),
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
    // Elsewhere on the bar does nothing.
    app.closed = false;
    u.pointerMotion(.{ 400, 22 });
    u.pointerButton(.{ 400, 22 }, widgets.btn_left, true);
    u.pointerButton(.{ 400, 22 }, widgets.btn_left, false);
    try testing.expect(!app.closed);
}
