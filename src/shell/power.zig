//! The power menu, as Raspberry Pi's desktop has it: a dialog in the
//! middle of the screen, over everything, the rest dimmed, shown by the
//! power button (the Pi 5's, the Pi 500's power key, the Pi 400's Fn+F10:
//! KEY_POWER) or the dock's quick settings. It powers the computer off or
//! restarts it; pressing the power button again while it shows powers off.
//! Its X, Escape, or a press outside it, closes it.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const kete_panel = @import("kete_panel.zig");

pub const Choice = enum { power_off, restart, cancel };

/// What was picked in it, for the shell to do.
const Picked = struct {
    choice: ?Choice = null,

    fn powerOff(p: *Picked) void {
        p.choice = .power_off;
    }

    fn restart(p: *Picked) void {
        p.choice = .restart;
    }

    fn cancel(p: *Picked) void {
        p.choice = .cancel;
    }
};

/// The dialog's width.
const card_width = 400;

/// The menu, as kete widgets: the screen dimmed (pressed, it cancels), and
/// the dialog: its X, what it asks, and its buttons.
pub const View = struct {
    picked: *Picked,

    pub fn build(self: *const View, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const card = cx.make(Blocker{ .child = cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .border_width = 1,
            .border_color = t.outline_variant,
            .radius = .all(24),
            .child = cx.make(kete.SizedBox{ .width = card_width, .child = cx.make(kete.Padding{
                .padding = .{ .left = 24, .right = 12, .top = 12, .bottom = 28 },
                .child = cx.make(kete.Column{
                    .fill = false,
                    .cross_axis_alignment = .stretch,
                    .children = cx.makeAll(.{
                        kete.Row{ .main_axis_alignment = .end, .children = cx.makeAll(.{
                            kete.IconButton{ .icon = .close, .on_press = .of(self.picked, Picked.cancel) },
                        }) },
                        kete.Padding{ .padding = .{ .right = 12 }, .child = cx.make(kete.Column{
                            .fill = false,
                            .spacing = 10,
                            .cross_axis_alignment = .center,
                            .children = cx.makeAll(.{
                                kete.Icon{ .icon = .power_settings_new, .size = 40, .color = t.primary },
                                kete.Text{ .text = locale.text("Power off this computer?"), .style = .{ .size = 24, .color = t.on_surface }, .wrap = false },
                                kete.SizedBox{ .height = 10 },
                                kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
                                    kete.OutlinedButton{ .label = locale.text("Restart"), .icon = .restart_alt, .on_press = .of(self.picked, Picked.restart) },
                                    kete.FilledButton{ .label = locale.text("Power off"), .icon = .power_settings_new, .on_press = .of(self.picked, Picked.powerOff) },
                                }) },
                            }),
                        }) },
                    }),
                }),
            }) }),
        }) });
        return cx.make(kete.Overlay{ .children = cx.makeAll(.{
            Scrim{ .on_press = .of(self.picked, Picked.cancel), .child = cx.make(kete.RoundedBox{ .color = .argb(0x88000000) }) },
            kete.Align.center(card),
        }) });
    }
};

/// The dimmed screen around the dialog: it takes the pointer, and a press
/// on it (let go there) cancels.
const Scrim = struct {
    on_press: ?kete.Callback = null,
    child: ?kete.Widget = null,

    pub fn event(self: *const Scrim, n: *kete.WidgetNode, e: kete.Event) bool {
        switch (e) {
            .press => |pr| return pr.button == .left,
            .release => |rel| {
                if (rel.button == .left and rel.inside) if (self.on_press) |cb| {
                    cb.call();
                    n.ui.needs_frame = true;
                };
                return true;
            },
            .scroll => return true,
            else => return false,
        }
    }
};

/// The dialog: presses on it are not the scrim's.
const Blocker = struct {
    child: ?kete.Widget = null,

    pub fn event(_: *const Blocker, _: *kete.WidgetNode, e: kete.Event) bool {
        return switch (e) {
            .press, .release, .scroll => true,
            else => false,
        };
    }
};

/// The menu as the shell has it: its panel (kete's, as big as the
/// screen), and whether it shows.
pub const Menu = struct {
    panel: *kete_panel.Panel,
    shown: bool = false,
    picked: Picked = .{},

    pub fn open(m: *Menu) void {
        m.shown = true;
        m.picked = .{};
        m.panel.followTheme();
    }

    pub fn close(m: *Menu) void {
        m.shown = false;
        m.picked = .{};
    }

    /// What was picked since it was last asked (and forgets it).
    pub fn take(m: *Menu) ?Choice {
        defer m.picked = .{};
        return m.picked.choice;
    }

    /// Its picture, over a screen `w` by `h`.
    pub fn draw(m: *Menu, w: u32, h: u32, now_ns: u64) kete_panel.Picture {
        return m.panel.draw(w, h, now_ns, View{ .picked = &m.picked });
    }
};
