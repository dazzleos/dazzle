//! AudioPlayer: displays a central audio card for an `audio.Player` with a
//! transport bar below (Play/Pause/Replay button, interactive seek bar, and
//! elapsed / total time readout), matching `VideoPlayer`.
//!
//!     cx.make(ui.AudioPlayer{ .player = player })

const std = @import("std");
const audio = @import("audio");
const video = @import("video");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const Center = @import("center.zig").Center;
const Column = @import("flex.zig").Column;
const Decorated = @import("decorated.zig").Decorated;
const Expanded = @import("expanded.zig").Expanded;
const Icon = @import("icon.zig").Icon;
const OutlinedButton = @import("outlined_button.zig").OutlinedButton;
const Padding = @import("padding.zig").Padding;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;
const icons = @import("icons");

const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.Node;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

pub const AudioPlayer = struct {
    player: *audio.Player,
    title: []const u8 = "",

    pub const State = struct {
        player: ?*audio.Player = null,

        fn onTogglePlay(st: *State) void {
            if (st.player) |p| p.togglePlay();
        }
    };

    pub fn build(self: *const AudioPlayer, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const p = self.player;
        state.player = p;

        var pos_buf: [32]u8 = undefined;
        var dur_buf: [32]u8 = undefined;
        const pos_str = video.formatDuration(&pos_buf, p.positionMs() * 1000);
        const dur_str = video.formatDuration(&dur_buf, p.durationMs() * 1000);

        var fmt_buf: [64]u8 = undefined;
        const fmt_str = cx.arena.dupe(u8, p.header.describe(&fmt_buf)) catch "WAV audio";

        const label = if (p.playing) "Pause" else if (p.ended) "Replay" else "Play";
        const play_icon: icons.Icon = if (p.playing)
            .pause
        else if (p.ended)
            .restart_alt
        else
            .play_arrow;

        const disc = cx.make(Decorated{
            .color = t.primary_container,
            .radius = .all(48),
            .child = cx.make(SizedBox{
                .width = 96,
                .height = 96,
                .child = cx.make(Center{
                    .child = cx.make(Icon{
                        .icon = .music_note,
                        .size = 48,
                        .color = t.on_primary_container,
                    }),
                }),
            }),
        });

        const card_children: []const Widget = if (self.title.len > 0)
            &.{
                disc,
                cx.make(Text{
                    .text = self.title,
                    .style = .{ .size = 20, .color = t.on_surface },
                    .wrap = false,
                    .ellipsis = true,
                }),
                cx.make(Text{
                    .text = fmt_str,
                    .style = .{ .size = 15, .color = t.on_surface_variant },
                    .wrap = false,
                    .ellipsis = true,
                }),
            }
        else
            &.{
                disc,
                cx.make(Text{
                    .text = fmt_str,
                    .style = .{ .size = 16, .color = t.on_surface_variant },
                    .wrap = false,
                    .ellipsis = true,
                }),
            };

        const artwork = cx.make(Center{
            .child = cx.make(Column{
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .spacing = 12,
                .children = card_children,
            }),
        });

        return cx.make(Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(Expanded{ .child = artwork }),
                cx.make(SizedBox{
                    .height = 64,
                    .child = cx.make(Padding{
                        .padding = .{ .left = 16, .right = 16 },
                        .child = cx.make(Row{
                            .spacing = 16,
                            .children = &.{
                                cx.make(OutlinedButton{
                                    .label = label,
                                    .icon = play_icon,
                                    .on_press = .of(state, State.onTogglePlay),
                                }),
                                cx.make(Expanded{
                                    .child = cx.make(AudioSeekBar{ .player = p }),
                                }),
                                cx.make(Text{
                                    .text = cx.fmt("{s} / {s}", .{ pos_str, dur_str }),
                                    .style = .{ .size = 15, .color = t.on_surface_variant },
                                    .wrap = false,
                                }),
                            },
                        }),
                    }),
                }),
            },
        });
    }
};

pub const AudioSeekBar = struct {
    player: *audio.Player,

    pub const State = struct {
        dragging: bool = false,
    };

    pub fn build(self: *const AudioSeekBar, cx: *Context, state: *State) Widget {
        return cx.make(SeekTrack{ .player = self.player, .state = state });
    }
};

pub const SeekTrack = struct {
    player: *audio.Player,
    state: *AudioSeekBar.State,

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
        const frac = self.player.progress();
        const fill_w = track_w * frac;

        c.fillRoundedRect(.{ .x = pad, .y = track_y, .w = track_w, .h = track_h }, .all(3), t.surface_container_highest);
        if (fill_w > 0) {
            c.fillRoundedRect(.{ .x = pad, .y = track_y, .w = fill_w, .h = track_h }, .all(3), t.primary);
        }
        const thumb_r: f32 = 7;
        const thumb_x = pad + fill_w - thumb_r;
        const thumb_y = @round(n.size.h / 2) - thumb_r;
        c.fillRoundedRect(.{ .x = thumb_x, .y = thumb_y, .w = thumb_r * 2, .h = thumb_r * 2 }, .all(thumb_r), t.primary);
    }

    pub fn event(self: *const SeekTrack, n: *Node, e: Event) bool {
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
        const target: u64 = @intFromFloat(@round(frac * @as(f32, @floatFromInt(self.player.durationMs()))));
        self.player.seekMs(target);
    }
};

test "AudioPlayer renders transport bar and toggles play" {
    const testing = std.testing;
    const font = @import("font");
    const Ui = @import("ui.zig").Ui;

    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();

    var wav_bytes: [44 + 4800 * 4]u8 = @splat(0);
    audio.wav.writePcm16Header(wav_bytes[0..44], 4800, 2, 4800);
    var player = audio.Player.openBytes(&wav_bytes).?;
    defer player.close();

    u.frame(640, 400, 1, AudioPlayer{ .player = &player, .title = "chime.wav" });
    try testing.expect(player.playing);
}
