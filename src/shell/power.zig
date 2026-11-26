//! The power menu, as Raspberry Pi's desktop has it: shown in the middle
//! of the screen, over everything, by the power button (the Pi 5's, the Pi
//! 500's power key, the Pi 400's Fn+F10: KEY_POWER) or the dock's quick
//! settings. It powers the computer off or restarts it; pressing the power
//! button again while it shows powers off; Escape, or Cancel, closes it.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const kete_panel = @import("kete_panel.zig");

/// Its size (it is drawn as a panel, in the middle of the screen).
pub const width = 460;
pub const height = 230;

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

/// The menu, as kete widgets: what it asks, and its buttons.
pub const View = struct {
    picked: *Picked,

    pub fn build(self: *const View, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        return cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .border_width = 1,
            .border_color = t.outline_variant,
            .radius = .all(24),
            .child = cx.make(kete.Padding{ .padding = .all(28), .child = cx.make(kete.Column{
                .fill = false,
                .spacing = 10,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    kete.Icon{ .icon = .power_settings_new, .size = 40, .color = t.primary },
                    kete.Text{ .text = locale.text("Power off this computer?"), .style = .{ .size = 24, .color = t.on_surface }, .wrap = false },
                    kete.Text{ .text = locale.text("Press the power button again to power off"), .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false },
                    kete.SizedBox{ .height = 8 },
                    kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
                        kete.TextButton{ .label = locale.text("Cancel"), .on_press = .of(self.picked, Picked.cancel) },
                        kete.OutlinedButton{ .label = locale.text("Restart"), .icon = .restart_alt, .on_press = .of(self.picked, Picked.restart) },
                        kete.FilledButton{ .label = locale.text("Power off"), .icon = .power_settings_new, .on_press = .of(self.picked, Picked.powerOff) },
                    }) },
                }),
            }) }),
        });
    }
};

/// The menu as the shell has it: its panel (kete's), and whether it shows.
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

    /// Its picture, `width` by `height`.
    pub fn draw(m: *Menu, now_ns: u64) kete_panel.Picture {
        return m.panel.draw(width, height, now_ns, View{ .picked = &m.picked });
    }

    /// In the middle of a screen `w` by `h`.
    pub fn place(w: u32, h: u32) [2]i32 {
        return .{ @divTrunc(@as(i32, @intCast(w)) - width, 2), @divTrunc(@as(i32, @intCast(h)) - height, 2) };
    }

    /// Where (`x`, `y`) on a screen `w` by `h` is in it.
    pub fn local(x: f64, y: f64, w: u32, h: u32) [2]f32 {
        const at = place(w, h);
        return .{ @floatCast(x - @as(f64, @floatFromInt(at[0]))), @floatCast(y - @as(f64, @floatFromInt(at[1]))) };
    }
};
