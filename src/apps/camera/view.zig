//! The Camera window, as widgets: the title bar, the camera's picture as
//! big as fits (on black), and under it a button that takes a photo and a
//! line saying what happened. Without a camera, the picture's place says
//! why there is none.

const ui = @import("ui");
const gfx = @import("gfx");

/// The smallest the window may be.
pub const min_size = [2]u32{ 480, 400 };

/// The size the window opens at: a 4:3 picture 960 wide, under the title bar.
pub const open_size = [2]u32{ 960, 764 };

/// The height of the title bar and the bar under the picture, which the
/// preview leaves room for.
pub const chrome_height = 48 + 72;

pub const Camera = struct {
    /// The latest picture; null if there is none (`message` says why).
    preview: ?*const gfx.Image,
    message: []const u8 = "",
    /// Under the picture: the camera, or the last photo taken.
    status: []const u8 = "",
    /// Takes a photo; null while one cannot be (no camera, or one is being
    /// saved).
    on_shoot: ?ui.Callback = null,
    /// The title bar's buttons (close, and maximize, which shows whether
    /// the window is), and pressing the bar (to move the window).
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub fn build(self: *const Camera, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const picture = if (self.preview) |img|
            cx.make(ui.Center{ .child = cx.make(ui.Image{ .image = img }) })
        else
            cx.make(ui.Center{ .child = cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Column{
                .main_axis_size = .min,
                .spacing = 16,
                .children = &.{
                    cx.make(ui.Icon{ .icon = .no_photography, .size = 64, .color = .rgb(0x938f99) }),
                    cx.make(ui.Text{ .text = self.message, .style = .{ .size = 18, .color = .rgb(0xcac4d0) }, .text_align = .center }),
                },
            }) }) });
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = "Camera",
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
            }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Decorated{ .color = .rgb(0x000000), .child = picture }) }),
            cx.make(ui.SizedBox{ .height = 72, .child = cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16 }, .child = cx.make(ui.Row{
                .spacing = 16,
                .children = &.{
                    cx.make(ui.OutlinedButton{ .label = "Take photo", .icon = .photo_camera, .on_press = self.on_shoot }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Text{
                        .text = self.status,
                        .style = .{ .size = 16, .color = t.on_surface_variant },
                        .wrap = false,
                        .ellipsis = true,
                    }) }),
                },
            }) }) }),
        } });
    }
};

const std = @import("std");
const testing = std.testing;
const font = @import("font");

test "the picture, the button and the status; without a camera, why" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const Shoot = struct {
        shots: u32 = 0,
        fn shoot(s: *@This()) void {
            s.shots += 1;
        }
    };
    var shoot: Shoot = .{};
    var pixels: [64 * 48]u32 = @splat(0xff336699);
    const img = gfx.Image.init(&pixels, 64, 48);
    u.frame(800, 600, 0, Camera{ .preview = &img, .status = "imx219", .on_shoot = .of(&shoot, Shoot.shoot) });
    const Find = struct {
        fn first(node: *ui.Node, comptime T: type) ?*ui.Node {
            if (node.widget.is(T)) return node;
            for (node.children.items) |ch| if (first(ch, T)) |n| return n;
            return null;
        }
    };
    const picture = Find.first(u.root.?, ui.Image).?;
    try testing.expectEqual(@as(f32, 64), picture.size.w);
    const button = Find.first(u.root.?, ui.OutlinedButton).?;
    const at = button.position();
    const p: ui.Point = .{ at[0] + 10, at[1] + 10 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
    try testing.expectEqual(@as(u32, 1), shoot.shots);

    u.frame(800, 600, 1, Camera{ .preview = null, .message = "No camera" });
    try testing.expect(Find.first(u.root.?, ui.Image) == null);
    try testing.expect(Find.first(u.root.?, ui.Icon) != null);
}
