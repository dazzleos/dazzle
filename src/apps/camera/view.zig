//! The Camera window, as kete widgets: the camera's picture as
//! big as fits (on black), and under it buttons to take a photo or record a
//! video and a line saying what happened. Without a camera, the picture's
//! place says why there is none.

const kete = @import("kete");
const gfx = kete.gfx;

/// The smallest the window may be.
pub const min_size = [2]u32{ 480, 400 };

/// The size the window opens at: a 4:3 picture 960 wide, under the title
/// bar (kete's).
pub const open_size = [2]u32{ 960, 764 };

/// The height of the title bar and the bar under the picture, which the
/// preview leaves room for.
pub const chrome_height = kete.ui.TitleBar.height + 72;

pub const Camera = struct {
    /// The latest picture; null if there is none (`message` says why).
    preview: ?*const gfx.Image,
    message: []const u8 = "",
    /// Under the picture: the camera, or active recording/saving state.
    status: []const u8 = "",
    /// Brief notification or error shown in a snackbar over the picture.
    notice: []const u8 = "",
    on_dismiss: ?kete.Callback = null,
    /// Takes a photo; null while one cannot be (no camera, or one is being
    /// saved).
    on_shoot: ?kete.Callback = null,
    /// Starts or stops recording a video; null without a camera.
    on_record: ?kete.Callback = null,
    /// Whether a video is currently being recorded.
    recording: bool = false,

    pub fn build(self: *const Camera, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const picture = if (self.preview) |img|
            cx.make(kete.Align{ .child = cx.make(kete.Image{ .source = .{ .image = img } }) })
        else
            cx.make(kete.Align{ .child = cx.make(kete.Padding{ .padding = .all(24), .child = cx.make(kete.Column{
                .fill = false,
                .spacing = 16,
                .children = &.{
                    cx.make(kete.Icon{ .icon = .no_photography, .size = 64, .color = .rgb(0x938f99) }),
                    cx.make(kete.Text{ .text = self.message, .style = .{ .size = 18, .color = .rgb(0xcac4d0) }, .text_align = .center }),
                },
            }) }) });
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(kete.Expanded{ .child = cx.make(kete.Snackbar{
                .message = self.notice,
                .on_dismiss = self.on_dismiss,
                .child = cx.make(kete.RoundedBox{ .color = .rgb(0x000000), .child = picture }),
            }) }),
            cx.make(kete.SizedBox{ .height = 72, .child = cx.make(kete.Padding{ .padding = .{ .left = 16, .right = 16 }, .child = cx.make(kete.Row{
                .spacing = 16,
                .children = &.{
                    cx.make(kete.OutlinedButton{ .label = "Take photo", .icon = .photo_camera, .on_press = self.on_shoot }),
                    cx.make(kete.OutlinedButton{
                        .label = if (self.recording) "Stop" else "Record video",
                        .icon = if (self.recording) .stop else .videocam,
                        .on_press = self.on_record,
                    }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.Text{
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
const font = kete.font;

test "the picture, the photo and video buttons, and the status; without a camera, why" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const Actions = struct {
        shots: u32 = 0,
        records: u32 = 0,
        fn shoot(s: *@This()) void {
            s.shots += 1;
        }
        fn record(s: *@This()) void {
            s.records += 1;
        }
    };
    var actions: Actions = .{};
    var pixels: [64 * 48]u32 = @splat(0xff336699);
    const img = kete.gfx.Image.init(&pixels, 64, 48);
    u.frame(800, 600, 0, Camera{
        .preview = &img,
        .status = "imx219",
        .on_shoot = .of(&actions, Actions.shoot),
        .on_record = .of(&actions, Actions.record),
    });
    const Find = struct {
        fn first(node: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
            if (node.widget.is(T)) return node;
            for (node.children.items) |ch| if (first(ch, T)) |n| return n;
            return null;
        }
        fn nth(node: *kete.WidgetNode, comptime T: type, want: usize, seen: *usize) ?*kete.WidgetNode {
            if (node.widget.is(T)) {
                if (seen.* == want) return node;
                seen.* += 1;
            }
            for (node.children.items) |ch| if (nth(ch, T, want, seen)) |n| return n;
            return null;
        }
    };
    const picture = Find.first(u.root.?, kete.Image).?;
    try testing.expectEqual(@as(f32, 64), picture.size.w);
    const button = Find.first(u.root.?, kete.OutlinedButton).?;
    const at = button.position();
    const p: kete.Point = .{ at[0] + 10, at[1] + 10 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
    try testing.expectEqual(@as(u32, 1), actions.shots);

    var seen: usize = 0;
    const rec_btn = Find.nth(u.root.?, kete.OutlinedButton, 1, &seen).?;
    const rec_at = rec_btn.position();
    const rp: kete.Point = .{ rec_at[0] + 10, rec_at[1] + 10 };
    u.pointerMotion(rp);
    u.pointerButton(rp, .left, true);
    u.pointerButton(rp, .left, false);
    try testing.expectEqual(@as(u32, 1), actions.records);

    u.frame(800, 600, 1, Camera{ .preview = null, .message = "No camera" });
    try testing.expect(Find.first(u.root.?, kete.Image) == null);
    try testing.expect(Find.first(u.root.?, kete.Icon) != null);
}
