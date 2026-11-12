//! The Sound page: output device selection, master volume slider, mute toggle,
//! and a test chime button.

const std = @import("std");
const kete = @import("kete");
const audio = @import("audio");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;

pub const label = "Sound";
pub const icon: kete.IconName = .volume_up;

pub const State = struct {
    picks: [audio.max_devices]Pick = undefined,
    sound: audio.Settings = .{},
    actions: ?*Actions = null,

    const Pick = struct {
        actions: ?*Actions = null,
        id: [16]u8 = @splat(0),
        len: u8 = 0,
        current: audio.Settings = .{},

        fn press(p: *Pick) void {
            if (p.actions) |a| {
                var s = a.sound orelse p.current;
                s.setOutput(p.id[0..p.len]);
                a.sound = s;
            }
        }
    };

    fn onVolumeChange(st: *State, v: f32) void {
        const acts = st.actions orelse return;
        const pct: u8 = @intFromFloat(@round(std.math.clamp(v, 0.0, 100.0)));
        var next = acts.sound orelse st.sound;
        next.volume = pct;
        if (pct > 0 and next.muted) next.muted = false;
        acts.sound = next;
    }

    fn onToggleMute(st: *State) void {
        const acts = st.actions orelse return;
        var next = acts.sound orelse st.sound;
        next.muted = !next.muted;
        acts.sound = next;
    }

    fn onTestSound(st: *State) void {
        const acts = st.actions orelse return;
        acts.test_sound = true;
    }
};

pub fn deviceIcon(kind: audio.Kind) kete.IconName {
    return switch (kind) {
        .headphones => .headphones,
        .hdmi => .tv,
        .usb => .usb,
        .speaker => .speaker,
    };
}

pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.arena;

    state.sound = self.sound;
    state.actions = self.actions;

    var rows: std.ArrayList(kete.Widget) = .empty;

    // Volume row: mute button, slider, and percentage readout.
    const vol_icon: kete.IconName = if (self.sound.muted or self.sound.volume == 0)
        .volume_off
    else if (self.sound.volume < 50)
        .volume_down
    else
        .volume_up;

    const vol_label = if (self.sound.muted)
        "Muted"
    else
        cx.fmt("{d}%", .{self.sound.volume});

    const vol_controls = cx.make(kete.Row{
        .cross_axis_alignment = .center,
        .spacing = 8,
        .children = &.{
            cx.make(kete.IconButton{
                .icon = vol_icon,
                .selected = !self.sound.muted and self.sound.volume > 0,
                .on_press = if (self.actions != null) .of(state, State.onToggleMute) else null,
            }),
            cx.make(kete.Expanded{
                .child = cx.make(kete.Slider{
                    .value = @floatFromInt(self.sound.volume),
                    .min = 0,
                    .max = 100,
                    .on_changed = if (self.actions != null) .of(state, State.onVolumeChange) else null,
                }),
            }),
            cx.make(kete.SizedBox{
                .width = 64,
                .child = cx.make(kete.Text{
                    .text = vol_label,
                    .style = .{
                        .size = 18,
                        .color = if (self.sound.muted) t.on_surface_variant else t.on_surface,
                    },
                    .wrap = false,
                }),
            }),
        },
    });

    rows.append(a, cx.make(kete.Row{
        .cross_axis_alignment = .center,
        .spacing = 12,
        .children = &.{
            b.label("Volume"),
            cx.make(kete.Expanded{ .child = vol_controls }),
        },
    })) catch {};

    // Output devices row.
    const devs = self.audio_devices.slice();
    if (devs.len == 0) {
        rows.append(a, b.item("Output", "No audio output devices found")) catch {};
    } else {
        const active = audio.activeDevice(self.audio_devices, &self.sound);
        var dev_rows: std.ArrayList(kete.Widget) = .empty;
        for (devs, 0..) |*dev, idx| {
            const selected = if (active) |act| std.mem.eql(u8, act.id(), dev.id()) and act.card == dev.card else idx == 0;
            const pick = &state.picks[idx];
            pick.* = .{
                .actions = self.actions,
                .current = self.sound,
            };
            pick.len = @intCast(@min(dev.id().len, pick.id.len));
            @memcpy(pick.id[0..pick.len], dev.id()[0..pick.len]);

            const fg = if (selected) t.on_surface else t.on_surface_variant;
            const bg = if (selected) t.secondary_container else t.surface_container;

            const item_row = cx.make(kete.RoundedBox{
                .color = bg,
                .radius = .all(10),
                .child = cx.make(kete.Padding{
                    .padding = .symmetric(12, 10),
                    .child = cx.make(kete.Row{
                        .cross_axis_alignment = .center,
                        .spacing = 10,
                        .children = &.{
                            cx.make(kete.Icon{ .icon = deviceIcon(dev.kind), .size = 22, .color = fg }),
                            cx.make(kete.Expanded{
                                .child = cx.make(kete.Text{
                                    .text = dev.name(),
                                    .style = .{ .size = 18, .color = fg },
                                    .wrap = false,
                                    .ellipsis = true,
                                }),
                            }),
                            if (selected)
                                cx.make(kete.Icon{ .icon = .check, .size = 20, .color = fg })
                            else
                                cx.make(kete.SizedBox.empty),
                        },
                    }),
                }),
            });

            dev_rows.append(a, cx.make(kete.Pressable{
                .on_press = if (self.actions != null and devs.len > 1) .of(pick, State.Pick.press) else null,
                .child = item_row,
            }).withKey(idx)) catch {};
        }

        dev_rows.append(a, cx.make(kete.Row{
            .children = &.{
                cx.make(kete.OutlinedButton{
                    .label = "Test sound",
                    .icon = .volume_up,
                    .on_press = if (self.actions != null) .of(state, State.onTestSound) else null,
                }),
            },
        })) catch {};

        rows.append(a, cx.make(kete.Row{
            .cross_axis_alignment = .start,
            .spacing = 12,
            .children = &.{
                b.label("Output"),
                cx.make(kete.Expanded{
                    .child = cx.make(kete.Column{
                        .cross_axis_alignment = .stretch,
                        .fill = false,
                        .spacing = 8,
                        .children = dev_rows.items,
                    }),
                }),
            },
        })) catch {};
    }

    return b.page(rows.items);
}

const testing = std.testing;
const font = kete.font;

pub fn sampleDevices() audio.Devices {
    var d: audio.Devices = .{};
    d.items[0] = audio.Device.init(0, 0, "Headphones", "Headphones", .headphones);
    d.items[1] = audio.Device.init(1, 0, "vc4hdmi", "HDMI", .hdmi);
    d.len = 2;
    return d;
}

test "Sound page shows output devices, adjusts volume, toggles mute and triggers test sound" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    const d = view.sample();
    const devs = sampleDevices();
    var sound: audio.Settings = .{ .volume = 75, .muted = false };
    sound.setOutput("Headphones");
    var actions: Actions = .{};

    var frame_no: u64 = 1;
    u.frame(1280, 720, frame_no, Settings{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .sound = sound,
        .audio_devices = &devs,
    });
    _ = view.showPage(u, .sound);
    frame_no += 1;
    u.frame(1280, 720, frame_no, Settings{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .sound = sound,
        .audio_devices = &devs,
    });

    try testing.expect(view.findText(u.root.?, "75%") != null);
    try testing.expect(view.findText(u.root.?, "Headphones") != null);
    try testing.expect(view.findText(u.root.?, "HDMI") != null);

    // Selecting HDMI updates actions.sound.output.
    view.click(u, view.up(view.findText(u.root.?, "HDMI").?, kete.Pressable).?);
    try testing.expectEqualStrings("vc4hdmi", actions.sound.?.output());
    sound = actions.sound.?;
    actions = .{};

    // Clicking Test sound sets actions.test_sound.
    frame_no += 1;
    u.frame(1280, 720, frame_no, Settings{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .sound = sound,
        .audio_devices = &devs,
    });
    view.click(u, view.up(view.findText(u.root.?, "Test sound").?, kete.OutlinedButton).?);
    try testing.expect(actions.test_sound);
    actions = .{};

    // Clicking the mute icon button toggles mute.
    view.click(u, view.findType(u.root.?, kete.IconButton).?);
    try testing.expect(actions.sound.?.muted);
}
