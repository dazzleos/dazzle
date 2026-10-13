//! Snackbar: Material 3's brief notification bar at the bottom of the
//! window, with a message, an optional action button and a dismiss button.

const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const Decorated = @import("decorated.zig").Decorated;
const Empty = @import("empty.zig").Empty;
const Expanded = @import("expanded.zig").Expanded;
const IconButton = @import("icon_button.zig").IconButton;
const Overlay = @import("overlay.zig").Overlay;
const Padding = @import("padding.zig").Padding;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;
const TextButton = @import("button.zig").TextButton;

const Widget = widget.Widget;
const Context = widget.Context;
const Callback = widget.Callback;

pub const Snackbar = struct {
    message: []const u8,
    action_label: []const u8 = "",
    on_action: ?Callback = null,
    on_dismiss: ?Callback = null,
    width: ?f32 = null,
    /// Optional content to overlay the snackbar at the bottom of.
    child: ?Widget = null,

    pub const min_height = 48;

    pub fn build(self: *const Snackbar, cx: *Context) Widget {
        if (self.message.len == 0) {
            if (self.child) |under| return cx.make(Overlay{ .children = &.{under} });
            return cx.make(Empty{});
        }
        const t = cx.theme();

        var items: [3]Widget = undefined;
        var count: usize = 0;

        const msg = cx.make(Text{
            .text = self.message,
            .style = .{ .size = t.body_size, .color = t.on_surface },
            .wrap = false,
            .ellipsis = true,
        });
        items[count] = if (self.width != null) cx.make(Expanded{ .child = msg }) else msg;
        count += 1;

        if (self.action_label.len > 0) {
            items[count] = cx.make(TextButton{
                .label = self.action_label,
                .on_press = self.on_action,
            });
            count += 1;
        }

        if (self.on_dismiss) |dismiss| {
            items[count] = cx.make(IconButton{
                .icon = .close,
                .size = 32,
                .icon_size = 18,
                .on_press = dismiss,
            });
            count += 1;
        }

        const right_pad: f32 = if (self.on_dismiss != null or self.action_label.len > 0) 8 else 16;
        const row = cx.make(Padding{
            .padding = .{ .left = 16, .right = right_pad, .top = 4, .bottom = 4 },
            .child = cx.make(Row{
                .spacing = 8,
                .main_axis_size = if (self.width != null) .max else .min,
                .cross_axis_alignment = .center,
                .children = items[0..count],
            }),
        });

        const sized = if (self.width) |w|
            cx.make(SizedBox{ .width = w, .child = cx.make(ConstrainedBox{ .constraints = .{ .min_h = min_height }, .child = row }) })
        else
            cx.make(ConstrainedBox{ .constraints = .{ .min_w = 240, .min_h = min_height }, .child = row });

        const bar = cx.make(Decorated{
            .color = t.surface_container_highest,
            .border = .{ .width = 1, .color = t.outline_variant },
            .radius = .all(8),
            .child = sized,
        });

        if (self.child) |under| {
            return cx.make(Overlay{
                .children = &.{
                    under,
                    cx.make(Align{
                        .alignment = .bottom_center,
                        .child = cx.make(Padding{ .padding = .all(16), .child = bar }),
                    }),
                },
            });
        }
        return bar;
    }
};
