//! The GPIO page's content: the board's header, pin by pin as it is laid
//! out (pin 1 at the top left), each GPIO pin saying what it is doing; and
//! the pin picked, with how to set it up. Boards without a header (the
//! Compute Modules) list their GPIO pins instead.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const gpio = @import("gpio.zig");

const Pin = gpio.Pin;
const Mode = gpio.Mode;

/// The colours of the header's pins, by what they are.
const red: gfx.Color = .rgb(0xe53935);
const orange: gfx.Color = .rgb(0xfb8c00);
const grey: gfx.Color = .rgb(0x616161);
const green: gfx.Color = .rgb(0x43a047);
const blue: gfx.Color = .rgb(0x1e88e5);
const purple: gfx.Color = .rgb(0x8e24aa);

pub const GpioPage = struct {
    pins: *const gpio.Pins,
    /// The header (null: none, the pins are listed).
    header: ?[]const Pin,
    /// The GPIO pin picked.
    picked: u6,
    on_pick: ?ui.ValueCallback(usize) = null,
    /// Sets the picked pin up; none if it cannot be.
    on_mode: ?ui.ValueCallback(Mode) = null,

    pub fn build(self: *const GpioPage, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        if (self.pins.read_failure) |why| return cx.make(ui.Text{ .text = why, .style = .{ .size = 18, .color = t.on_surface } });
        const a = cx.ui.arena();
        var rows: std.ArrayList(ui.Widget) = .empty;
        if (self.header) |h| {
            var i: usize = 0;
            while (i + 1 < h.len) : (i += 2) rows.append(a, cx.make(ui.Row{ .spacing = 6, .cross_axis_alignment = .center, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Align{ .alignment = .center_right, .child = self.pinLabel(cx, h[i], true) }) }),
                self.dot(cx, h[i], i + 1),
                self.dot(cx, h[i + 1], i + 2),
                cx.make(ui.Expanded{ .child = cx.make(ui.Align{ .alignment = .center_left, .child = self.pinLabel(cx, h[i + 1], false) }) }),
            } })) catch {};
        } else {
            for (0..46) |g| rows.append(a, cx.make(ui.Row{ .spacing = 8, .cross_axis_alignment = .center, .children = &.{
                self.dot(cx, .{ .gpio = @intCast(g) }, null),
                self.pinLabel(cx, .{ .gpio = @intCast(g) }, false),
            } })) catch {};
        }
        const pins = cx.make(ui.SizedBox{ .width = 440, .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = rows.items }) });
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 16, .children = &.{
            cx.make(ui.Text{ .text = "Pick a GPIO pin to see what it does, and to set it up. Inputs are read as they change.", .style = .{ .size = 15, .color = t.on_surface_variant } }),
            cx.make(SideBySide{ .children = &.{ pins, cx.make(ui.SizedBox{ .width = 340, .child = self.detail(cx) }) } }),
        } });
    }

    /// A pin, round, with its number (if it is on the header) and the
    /// colour of what it is: power, ground, or a GPIO pin by what it does.
    fn dot(self: *const GpioPage, cx: *ui.Context, pin: Pin, number: ?usize) ui.Widget {
        const t = cx.theme();
        const colour: gfx.Color, const filled: bool = switch (pin) {
            .power_5v => .{ red, true },
            .power_3v3 => .{ orange, true },
            .ground => .{ grey, true },
            .gpio => |g| blk: {
                const l = &self.pins.lines[g];
                break :blk switch (l.function) {
                    .output => .{ green, l.high },
                    .input => .{ blue, l.high },
                    else => .{ purple, true },
                };
            },
        };
        const picked = pin == .gpio and pin.gpio == self.picked;
        const body = cx.make(ui.SizedBox{ .width = 26, .height = 26, .child = cx.make(ui.Decorated{
            .color = if (filled) colour else null,
            .border = if (picked) .{ .width = 3, .color = t.on_surface } else .{ .width = 2, .color = colour },
            .radius = .all(13),
            .child = if (number) |n| cx.make(ui.Center{ .child = cx.make(ui.Text{
                .text = cx.fmt("{d}", .{n}),
                .style = .{ .size = 11, .color = if (filled) .rgb(0xffffff) else t.on_surface },
                .wrap = false,
            }) }) else null,
        }) });
        return switch (pin) {
            .gpio => |g| cx.make(ui.Pressable{ .on_press = self.pickCallback(cx, g), .child = body }),
            else => body,
        };
    }

    /// What a pin is: "5V", "Ground", or "GPIO 17" and what it is doing.
    fn pinLabel(self: *const GpioPage, cx: *ui.Context, pin: Pin, left: bool) ui.Widget {
        const t = cx.theme();
        const plain: ui.TextStyle = .{ .size = 14, .color = t.on_surface_variant };
        switch (pin) {
            .power_5v => return cx.make(ui.Text{ .text = "5V", .style = plain, .wrap = false }),
            .power_3v3 => return cx.make(ui.Text{ .text = "3.3V", .style = plain, .wrap = false }),
            .ground => return cx.make(ui.Text{ .text = "Ground", .style = plain, .wrap = false }),
            .gpio => |g| {
                const name = if (gpio.usualName(g)) |u| cx.fmt("GPIO {d} ({s})", .{ g, u }) else cx.fmt("GPIO {d}", .{g});
                const picked = g == self.picked;
                const text = cx.make(ui.Column{ .cross_axis_alignment = if (left) .end else .start, .main_axis_size = .min, .children = &.{
                    cx.make(ui.Text{ .text = name, .style = .{ .size = 14, .color = if (picked) t.primary else t.on_surface }, .wrap = false }),
                    cx.make(ui.Text{ .text = self.doing(cx, g, true), .style = .{ .size = 12, .color = t.on_surface_variant }, .wrap = false }),
                } });
                return cx.make(ui.Pressable{ .on_press = self.pickCallback(cx, g), .child = text });
            },
        }
    }

    /// What a GPIO pin is doing: "Output, high", "Input, low", or its
    /// alternate function.
    fn doing(self: *const GpioPage, cx: *ui.Context, g: u6, short: bool) []const u8 {
        const l = &self.pins.lines[g];
        const level = if (l.high) "high" else "low";
        return switch (l.function) {
            .output => cx.fmt("Output, {s}", .{level}),
            .input => cx.fmt("Input, {s}", .{level}),
            else => |f| if (self.pins.altName(g, f.alt().?)) |n| n else if (short) cx.fmt("Function {d}", .{f.alt().?}) else cx.fmt("Alternate function {d}", .{f.alt().?}),
        };
    }

    /// The pin picked: what it does, who has it, and how to set it up.
    fn detail(self: *const GpioPage, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const g = self.picked;
        const p = self.pins;
        const l = &p.lines[g];
        const a = cx.ui.arena();
        var rows: std.ArrayList(ui.Widget) = .empty;
        const on_pin = if (self.header) |h| for (h, 1..) |pin, n| {
            if (pin == .gpio and pin.gpio == g) break n;
        } else null else null;
        rows.append(a, cx.make(ui.Text{
            .text = if (on_pin) |n| cx.fmt("GPIO {d}, pin {d}", .{ g, n }) else cx.fmt("GPIO {d}", .{g}),
            .style = .{ .size = 20, .color = t.on_surface },
        })) catch {};
        rows.append(a, cx.make(ui.Text{ .text = self.doing(cx, g, false), .style = .{ .size = 16, .color = t.on_surface } })) catch {};
        if (l.function.alt() != null) rows.append(a, cx.make(ui.Text{
            .text = cx.fmt("It is {s} now", .{if (l.high) "high" else "low"}),
            .style = .{ .size = 16, .color = t.on_surface_variant },
        })) catch {};
        if (l.used) {
            const who = l.consumer();
            rows.append(a, cx.make(ui.Text{
                .text = if (who.len > 0) cx.fmt("In use by {s}, so it cannot be changed here", .{who}) else "In use by the system, so it cannot be changed here",
                .style = .{ .size = 15, .color = t.on_surface_variant },
            })) catch {};
        } else {
            const current = p.mode(g);
            const modes = [_]struct { Mode, []const u8 }{
                .{ .input, "Input" },
                .{ .input_pull_up, "Input, pulled up" },
                .{ .input_pull_down, "Input, pulled down" },
                .{ .output_low, "Output, low" },
                .{ .output_high, "Output, high" },
            };
            const set: ?*ModeSet = if (self.on_mode) |f| blk: {
                const ms = a.create(ModeSet) catch break :blk null;
                ms.* = .{ .f = f };
                break :blk ms;
            } else null;
            for (modes) |m| rows.append(a, cx.make(ui.Radio(?Mode){
                .value = m[0],
                .group_value = current,
                .label = m[1],
                .on_changed = if (set) |ms| .of(ms, ModeSet.set) else null,
            })) catch {};
            if (l.function == .input and current == null) rows.append(a, cx.make(ui.Text{
                .text = "Its pull (up, down or none) is not known until it is set here",
                .style = .{ .size = 14, .color = t.on_surface_variant },
            })) catch {};
            if (p.set_failure) |why| rows.append(a, cx.make(ui.Text{ .text = why, .style = .{ .size = 15, .color = t.@"error" } })) catch {};
        }
        if (p.last_pin == g) if (p.last_error) |why| rows.append(a, cx.make(ui.Text{
            .text = cx.fmt("It could not be set up: {s}", .{why}),
            .style = .{ .size = 15, .color = t.@"error" },
        })) catch {};
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 6, .children = rows.items });
    }

    fn pickCallback(self: *const GpioPage, cx: *ui.Context, g: u6) ?ui.Callback {
        const f = self.on_pick orelse return null;
        const p = cx.ui.arena().create(PickPin) catch return null;
        p.* = .{ .f = f, .pin = g };
        return .of(p, PickPin.press);
    }
};

const PickPin = struct {
    f: ui.ValueCallback(usize),
    pin: u6,

    fn press(p: *PickPin) void {
        p.f.call(p.pin);
    }
};

/// Choosing a mode (the radio buttons' values are optional, as the pin's
/// may not be known).
const ModeSet = struct {
    f: ui.ValueCallback(Mode),

    fn set(s: *ModeSet, m: ?Mode) void {
        if (m) |mode| s.f.call(mode);
    }
};

/// Two children side by side, at the top, if there is room; else one
/// above the other.
const SideBySide = struct {
    children: []const ui.Widget,
    gap: f32 = 32,

    pub fn layout(self: *const SideBySide, n: *ui.Node, c: ui.Constraints) ui.Size {
        const loose = c.loosen();
        const a = n.child(0).layout(.{ .max_w = loose.max_w, .max_h = std.math.inf(f32) });
        const b = n.child(1).layout(.{ .max_w = loose.max_w, .max_h = std.math.inf(f32) });
        const fits = !c.boundedWidth() or a.w + self.gap + b.w <= c.max_w;
        n.child(0).place(0, 0);
        if (fits) {
            n.child(1).place(a.w + self.gap, 0);
            return c.constrain(.{ .w = a.w + self.gap + b.w, .h = @max(a.h, b.h) });
        }
        n.child(1).place(0, a.h + self.gap);
        return c.constrain(.{ .w = @max(a.w, b.w), .h = a.h + self.gap + b.h });
    }
};
