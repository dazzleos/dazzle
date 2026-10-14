//! VideoPlayer: displays a `video.Player`'s decoded frames on a dark
//! canvas with a transport bar below (Play/Pause/Replay button,
//! interactive seek bar, and elapsed / total time readout).
//!
//!     cx.make(ui.VideoPlayer{ .player = player })

const std = @import("std");
const sys = @import("sys");
const video = @import("video");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const center = @import("center.zig");
const padding = @import("padding.zig");
const flex = @import("flex.zig");
const expanded = @import("expanded.zig");
const decorated = @import("decorated.zig");
const sized_box = @import("sized_box.zig");
const image = @import("image.zig");
const icon_mod = @import("icon.zig");
const text = @import("text.zig");
const spinner = @import("spinner.zig");
const outlined_button = @import("outlined_button.zig");
const icons = @import("icons");

const Context = widget.Context;
const Widget = widget.Widget;
const Node = widget.Node;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

const VideoAct = struct {
    player: *video.Player,

    fn toggle(a: *const VideoAct) void {
        a.player.togglePlay(sys.nowNs());
    }
};

pub const VideoPlayer = struct {
    player: *video.Player,

    pub fn build(self: *const VideoPlayer, cx: *Context) Widget {
        const player = self.player;
        const t = cx.theme();
        const picture = if (player.image) |*img|
            cx.make(center.Center{ .child = cx.make(image.Image{ .image = img }) })
        else if (player.hw_unavailable)
            cx.make(center.Center{ .child = cx.make(padding.Padding{ .padding = .all(24), .child = cx.make(flex.Column{
                .main_axis_size = .min,
                .spacing = 16,
                .children = &.{
                    cx.make(icon_mod.Icon{ .icon = .videocam, .size = 64, .color = .rgb(0x938f99) }),
                    cx.make(text.Text{
                        .text = "Hardware video decoder not available",
                        .style = .{ .size = 18, .color = .rgb(0xcac4d0) },
                        .text_align = .center,
                    }),
                },
            }) }) })
        else
            cx.make(center.Center{ .child = cx.make(spinner.Spinner{ .size = 32 }) });

        var pos_buf: [32]u8 = undefined;
        var dur_buf: [32]u8 = undefined;
        const pos_str = video.formatDuration(&pos_buf, player.position_us);
        const dur_str = video.formatDuration(&dur_buf, player.stream.duration_us);
        const act = cx.ui.arena().create(VideoAct) catch null;
        if (act) |a| a.* = .{ .player = player };

        const label = if (player.playing) "Pause" else if (player.finished) "Replay" else "Play";
        const ic: icons.Icon = if (player.playing) .pause else if (player.finished) .restart_alt else .play_arrow;

        return cx.make(flex.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(expanded.Expanded{ .child = cx.make(decorated.Decorated{ .color = .rgb(0x000000), .child = picture }) }),
            cx.make(sized_box.SizedBox{ .height = 64, .child = cx.make(padding.Padding{ .padding = .{ .left = 16, .right = 16 }, .child = cx.make(flex.Row{
                .spacing = 16,
                .children = &.{
                    cx.make(outlined_button.OutlinedButton{
                        .label = label,
                        .icon = ic,
                        .on_press = if (player.decoder != null and act != null) .of(act.?, VideoAct.toggle) else null,
                    }),
                    cx.make(expanded.Expanded{ .child = cx.make(SeekBar{ .player = player }) }),
                    cx.make(text.Text{
                        .text = cx.fmt("{s} / {s}", .{ pos_str, dur_str }),
                        .style = .{ .size = 15, .color = t.on_surface_variant },
                        .wrap = false,
                    }),
                },
            }) }) }),
        } });
    }
};

/// Interactive progress and seek bar for a `video.Player`.
pub const SeekBar = struct {
    player: *video.Player,

    pub const State = struct {
        dragging: bool = false,
    };

    pub fn build(self: *const SeekBar, cx: *Context, state: *State) Widget {
        return cx.make(SeekTrack{ .player = self.player, .state = state });
    }
};

pub const SeekTrack = struct {
    player: *video.Player,
    state: *SeekBar.State,

    pub fn layout(_: *const SeekTrack, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = c.max_w, .h = 32 });
    }

    pub fn paint(self: *const SeekTrack, n: *Node, p: *Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const pad: f32 = 8;
        const track_w = @max(n.size.w - pad * 2, 0);
        const track_h: f32 = 6;
        const track_y = @round((n.size.h - track_h) / 2);
        const dur = self.player.stream.duration_us;
        const frac: f32 = if (dur > 0)
            std.math.clamp(@as(f32, @floatFromInt(self.player.position_us)) / @as(f32, @floatFromInt(dur)), 0, 1)
        else
            0;
        const fill_w = track_w * frac;

        c.fillRoundedRect(.{ .x = pad, .y = track_y, .w = track_w, .h = track_h }, .all(3), t.surface_container_highest);
        if (fill_w > 0) {
            c.fillRoundedRect(.{ .x = pad, .y = track_y, .w = fill_w, .h = track_h }, .all(3), t.primary);
        }
        const thumb_r: f32 = 7;
        const thumb_x = pad + fill_w - thumb_r;
        const thumb_y = @round(n.size.h / 2) - thumb_r;
        c.fillRoundedRect(.{ .x = thumb_x, .y = thumb_y, .w = thumb_r * 2, .h = thumb_r * 2 }, .all(thumb_r), if (self.player.decoder != null) t.primary else t.outline);
    }

    pub fn cursor(self: *const SeekTrack, _: *Node, _: geometry.Point) ?widget.Cursor {
        if (self.player.decoder == null and !self.player.hw_unavailable) return null;
        return if (self.state.dragging) .grabbing else .pointer;
    }

    pub fn event(self: *const SeekTrack, n: *Node, e: Event) bool {
        if (self.player.decoder == null and !self.player.hw_unavailable) return false;
        switch (e) {
            .press => |pr| {
                if (pr.button != widget.btn_left) return false;
                self.state.dragging = true;
                self.seekAt(n, pr.pos[0]);
                return true;
            },
            .motion => |pos| if (self.state.dragging) {
                self.seekAt(n, pos[0]);
                return true;
            },
            .release => |rel| if (self.state.dragging) {
                self.state.dragging = false;
                if (!(rel.pos[0] == -1 and rel.pos[1] == -1 and !rel.inside)) self.seekAt(n, rel.pos[0]);
                return true;
            },
            else => {},
        }
        return false;
    }

    fn seekAt(self: *const SeekTrack, n: *Node, x: f32) void {
        const pad: f32 = 8;
        const track_w = @max(n.size.w - pad * 2, 1);
        const frac = std.math.clamp((x - pad) / track_w, 0, 1);
        const target: u64 = @intFromFloat(@round(frac * @as(f32, @floatFromInt(self.player.stream.duration_us))));
        self.player.seekTo(target, sys.nowNs());
    }
};
