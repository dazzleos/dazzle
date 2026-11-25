//! A board, drawn as line art in the theme's colours (see board.zig): its
//! outline and mounting holes, and its parts, the chips a little heavier
//! than the connectors, and what is under the board fainter. The part
//! under the pointer is lit, and the one picked is filled in; clicking (or
//! tapping) a part picks it.
//!
//! When the GPIO header is picked, its pins are drawn horizontally below
//! the description with a colour key, and clicking any pin shows what it
//! is and (for configurable GPIO pins) a menu button to set its mode.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const gfx = kete.gfx;
const locale = @import("locale");
const info = @import("info.zig");
const board = @import("board.zig");
const usb = @import("usb.zig");
const gpio = @import("gpio.zig");
const view = @import("view.zig");

const Color = gfx.Color;
const Pin = gpio.Pin;
const Mode = gpio.Mode;
const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;

pub const label = "Board";
pub const icon: kete.IconName = .developer_board;

const default_pins: gpio.Pins = .{ .opened = true };

/// The colours of the header's pins, by what they are.
const red: Color = .rgb(0xe53935);
const orange: Color = .rgb(0xfb8c00);
const grey: Color = .rgb(0x616161);
const green: Color = .rgb(0x43a047);
const blue: Color = .rgb(0x1e88e5);
const purple: Color = .rgb(0x8e24aa);

pub const State = struct {
    /// The part of the board picked (an index into its parts), if one is.
    part: ?usize = null,
    /// Select the GPIO header when `part` has not been picked yet.
    select_gpio: bool = false,
    /// The header pin picked (0-indexed into the board's header).
    /// Pin 11 (index 10) is GPIO 17.
    pin: usize = 10,
    dismissed: bool = false,
    last_err_buf: [128]u8 = undefined,
    last_err_len: u8 = 0,

    pub fn dismiss(st: *State) void {
        st.dismissed = true;
    }
};

/// The board, drawn, and about the part picked on it.
pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.arena;
    const model = self.system.model.slice();
    var rows: std.ArrayList(kete.Widget) = .empty;
    rows.append(a, b.value(view.orUnknown(model))) catch {};
    if (self.system.serial.len > 0) rows.append(a, cx.make(kete.Text{ .text = kete_vc4.textf(cx, "Serial: {s}", .{self.system.serial.slice()}), .style = .{ .size = 16, .color = t.on_surface_variant } })) catch {};
    const drawing = board.forModel(model) orelse {
        rows.append(a, b.value(locale.text("There is no drawing of this board"))) catch {};
        return b.scroll(.board, b.page(rows.items));
    };
    // The processor (or the GPIO header when asked for), until something
    // else is picked.
    const picked = state.part orelse if (state.select_gpio) for (drawing.parts, 0..) |part, i| {
        if (part.kind == .gpio or part.kind == .gpio_holes) break i;
    } else 0 else for (drawing.parts, 0..) |part, i| {
        if (part.kind == .soc or part.kind == .soc_with_ram) break i;
    } else 0;
    const part = &drawing.parts[@min(picked, drawing.parts.len - 1)];
    const about = board.describe(part);
    rows.appendSlice(a, &.{
        cx.make(kete.Padding{ .padding = .symmetric(0, 8), .child = cx.make(kete.Align{ .alignment = .center_left, .child = cx.make(BoardView{
            .board = drawing,
            .selected = picked,
            .on_select = partPicker(state),
            // As many pixels a millimetre as a credit-card-sized board
            // has: a bigger one (the Pi 400, a keyboard) is drawn bigger.
            .max_width = @max(260, drawing.width * 3),
            .max_height = @max(170, drawing.height * 3),
        }) }) }),
        cx.make(kete.Text{ .text = if (part.chip.len > 0) kete_vc4.textf(cx, "{s}: {s}", .{ about.title, part.chip }) else about.title, .style = .{ .size = 20, .color = t.on_surface } }),
        cx.make(kete.Text{ .text = cx.fmt("{s}{s}", .{ about.about, if (part.underside) " (underneath the board)" else "" }), .style = .{ .size = 16, .color = t.on_surface_variant } }),
    }) catch {};
    // What it is doing now, where that is known.
    const u = self.usage;
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var card_buf: [64]u8 = undefined;
    const now: ?[]const u8 = switch (part.kind) {
        .soc => if (u.cpu_busy) |busy| (if (u.temperature) |c| kete_vc4.textf(cx, "{d:.0}% busy, at {s}", .{ busy, locale.formatTemperature(&b1, c) }) else kete_vc4.textf(cx, "{d:.0}% busy", .{busy})) else null,
        .soc_with_ram => if (u.cpu_busy) |busy| kete_vc4.textf(cx, "{d:.0}% busy; {s} of {s} of memory in use", .{ busy, info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) }) else null,
        .ram => kete_vc4.textf(cx, "{s} of {s} in use", .{ info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) }),
        .micro_sd, .sd, .emmc => if (self.system.card.bytes > 0) cx.fmt("{s}", .{self.system.card.describe(&card_buf)}) else null,
        .usb, .usb_double, .usb_otg => if (self.usb.len == 0) locale.text("Nothing is plugged in") else null,
        else => null,
    };
    if (now) |text| rows.append(a, cx.make(kete.Text{ .text = text, .style = .{ .size = 16, .color = t.on_surface } })) catch {};
    if (part.kind == .usb or part.kind == .usb_double or part.kind == .usb_otg) {
        for (self.usb.slice()) |*d| {
            var name_buf: [64]u8 = undefined;
            var speed_buf: [16]u8 = undefined;
            var detail: std.ArrayList(u8) = .empty;
            detail.appendSlice(a, d.kind.label()) catch {};
            if (d.manufacturer.len > 0) detail.print(a, "  \u{b7}  {s}", .{d.manufacturer.slice()}) catch {};
            const speed = usb.formatSpeed(&speed_buf, d.speed_mbps);
            if (speed.len > 0) detail.print(a, "  \u{b7}  {s}", .{speed}) catch {};
            if (d.built_in) detail.appendSlice(a, "  \u{b7}  Part of the board") catch {};
            rows.append(a, cx.make(kete.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = &.{
                cx.make(kete.Icon{ .icon = usbIcon(d.kind), .size = 28, .color = t.on_surface_variant }),
                cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = &.{
                    cx.make(kete.Text{ .text = cx.fmt("{s}", .{d.name(&name_buf)}), .style = .{ .size = 18 }, .wrap = false, .ellipsis = true }),
                    cx.make(kete.Text{ .text = detail.items, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
                } }) }),
            } })) catch {};
        }
    }
    var err_msg: []const u8 = "";
    if (part.kind == .gpio or part.kind == .gpio_holes) {
        appendGpioSection(self, cx, state, model, &rows);
        const pins = self.gpio orelse &default_pins;
        if (pins.set_failure) |why| {
            err_msg = why;
        } else if (pins.last_error) |why| {
            err_msg = kete_vc4.textf(cx, "It could not be set up: {s}", .{why});
        }
    }
    if (err_msg.len == 0) {
        state.dismissed = false;
        state.last_err_len = 0;
    } else if (!std.mem.eql(u8, state.last_err_buf[0..state.last_err_len], err_msg)) {
        const n: u8 = @intCast(@min(err_msg.len, state.last_err_buf.len));
        @memcpy(state.last_err_buf[0..n], err_msg[0..n]);
        state.last_err_len = n;
        state.dismissed = false;
    }
    return cx.make(kete.Snackbar{
        .message = if (state.dismissed) "" else err_msg,
        .on_dismiss = .of(state, State.dismiss),
        .child = b.scroll(.board, b.page(rows.items)),
    });
}

fn appendGpioSection(
    self: *const Settings,
    cx: *kete.BuildContext,
    state: *State,
    model: []const u8,
    rows: *std.ArrayList(kete.Widget),
) void {
    const t = cx.theme();
    const a = cx.arena;
    const pins = self.gpio orelse &default_pins;
    if (pins.read_failure) |why| {
        rows.append(a, cx.make(kete.Text{ .text = why, .style = .{ .size = 16, .color = t.on_surface } })) catch {};
        return;
    }
    const header = gpio.headerFor(model) orelse return;
    const picked_idx = @min(state.pin, header.len - 1);
    state.pin = picked_idx;

    // Horizontal 2-row pin diagram (pin 1 at top-left, pin 2 below it).
    var top_row: std.ArrayList(kete.Widget) = .empty;
    var bottom_row: std.ArrayList(kete.Widget) = .empty;
    var i: usize = 0;
    while (i + 1 < header.len) : (i += 2) {
        top_row.append(a, pinDot(cx, state, pins, header[i], i, picked_idx == i)) catch {};
        bottom_row.append(a, pinDot(cx, state, pins, header[i + 1], i + 1, picked_idx == i + 1)) catch {};
    }
    // The pins as they are on the board, in Arabic too.
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 6 }, .child = cx.make(kete.LeftToRight{ .child = cx.make(kete.Column{
        .cross_axis_alignment = .start,
        .fill = false,
        .spacing = 3,
        .children = &.{
            cx.make(kete.Row{ .fill = false, .spacing = 3, .children = top_row.items }),
            cx.make(kete.Row{ .fill = false, .spacing = 3, .children = bottom_row.items }),
        },
    }) }) })) catch {};

    // Key for the pin colours.
    rows.append(a, pinColourKey(cx)) catch {};

    // Selected pin description and mode menu below.
    rows.append(a, pinDetail(self, cx, state, pins, header[picked_idx], picked_idx + 1)) catch {};
}

fn pinDot(
    cx: *kete.BuildContext,
    state: *State,
    pins: *const gpio.Pins,
    pin: Pin,
    index: usize,
    picked: bool,
) kete.Widget {
    const t = cx.theme();
    const colour: Color, const filled: bool = switch (pin) {
        .power_5v => .{ red, true },
        .power_3v3 => .{ orange, true },
        .ground => .{ grey, true },
        .gpio => |g| blk: {
            const l = &pins.lines[g];
            break :blk switch (l.function) {
                .output => .{ green, l.high },
                .input => .{ blue, l.high },
                else => .{ purple, true },
            };
        },
    };
    const size = 20;
    const body = cx.make(kete.SizedBox{ .width = size, .height = size, .child = cx.make(kete.RoundedBox{
        .color = if (filled) colour else null,
        .border_width = if (picked) 3 else 2,
        .border_color = if (picked) t.on_surface else colour,
        .radius = .all(size / 2),
        .child = cx.make(kete.Align{ .child = cx.make(kete.Text{
            .text = cx.fmt("{d}", .{index + 1}),
            .style = .{ .size = 9, .color = if (filled) .rgb(0xffffff) else t.on_surface },
            .wrap = false,
        }) }),
    }) });
    const pick = cx.arena.create(PickHeaderPin) catch return body;
    pick.* = .{ .state = state, .index = index };
    return cx.make(kete.Pressable{ .on_press = .of(pick, PickHeaderPin.press), .child = body });
}

const PickHeaderPin = struct {
    state: *State,
    index: usize,

    fn press(p: *PickHeaderPin) void {
        p.state.pin = p.index;
    }
};

fn pinColourKey(cx: *kete.BuildContext) kete.Widget {
    const t = cx.theme();
    const a = cx.arena;
    const entries = [_]struct { Color, []const u8 }{
        .{ red, "5V" },
        .{ orange, "3.3V" },
        .{ grey, locale.text("Ground") },
        .{ blue, locale.text("Input") },
        .{ green, locale.text("Output") },
        .{ purple, locale.text("Other") },
    };
    var items: std.ArrayList(kete.Widget) = .empty;
    for (entries) |e| {
        items.append(a, cx.make(kete.Row{ .fill = false, .cross_axis_alignment = .center, .spacing = 6, .children = &.{
            cx.make(kete.SizedBox{ .width = 12, .height = 12, .child = cx.make(kete.RoundedBox{
                .color = e[0],
                .radius = .all(6),
            }) }),
            cx.make(kete.Text{ .text = e[1], .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false }),
        } })) catch {};
    }
    return cx.make(kete.Row{ .fill = false, .cross_axis_alignment = .center, .spacing = 14, .children = items.items });
}

fn gpioDoing(cx: *kete.BuildContext, pins: *const gpio.Pins, g: u6) []const u8 {
    const l = &pins.lines[g];
    const level = if (l.high) "high" else "low";
    return switch (l.function) {
        .output => kete_vc4.textf(cx, "Output, {s}", .{level}),
        .input => kete_vc4.textf(cx, "Input, {s}", .{level}),
        else => |f| if (pins.altName(g, f.alt().?)) |n| n else kete_vc4.textf(cx, "Alternate function {d}", .{f.alt().?}),
    };
}

fn pinDetail(
    self: *const Settings,
    cx: *kete.BuildContext,
    state: *State,
    pins: *const gpio.Pins,
    pin: Pin,
    pin_num: usize,
) kete.Widget {
    const t = cx.theme();
    const a = cx.arena;
    var rows: std.ArrayList(kete.Widget) = .empty;
    switch (pin) {
        .power_5v => {
            rows.append(a, cx.make(kete.Text{ .text = kete_vc4.textf(cx, "5V, pin {d}", .{pin_num}), .style = .{ .size = 18, .color = t.on_surface } })) catch {};
            rows.append(a, cx.make(kete.Text{ .text = locale.text("5 V power from the board's power supply"), .style = .{ .size = 16, .color = t.on_surface_variant } })) catch {};
        },
        .power_3v3 => {
            rows.append(a, cx.make(kete.Text{ .text = kete_vc4.textf(cx, "3.3V, pin {d}", .{pin_num}), .style = .{ .size = 18, .color = t.on_surface } })) catch {};
            rows.append(a, cx.make(kete.Text{ .text = locale.text("3.3 V power from the board"), .style = .{ .size = 16, .color = t.on_surface_variant } })) catch {};
        },
        .ground => {
            rows.append(a, cx.make(kete.Text{ .text = kete_vc4.textf(cx, "Ground, pin {d}", .{pin_num}), .style = .{ .size = 18, .color = t.on_surface } })) catch {};
            rows.append(a, cx.make(kete.Text{ .text = locale.text("Ground (0 V)"), .style = .{ .size = 16, .color = t.on_surface_variant } })) catch {};
        },
        .gpio => |g| {
            const l = &pins.lines[g];
            const title = if (gpio.usualName(g)) |u|
                kete_vc4.textf(cx, "GPIO {d} ({s}), pin {d}", .{ g, u, pin_num })
            else
                kete_vc4.textf(cx, "GPIO {d}, pin {d}", .{ g, pin_num });
            rows.append(a, cx.make(kete.Text{ .text = title, .style = .{ .size = 18, .color = t.on_surface } })) catch {};
            rows.append(a, cx.make(kete.Text{ .text = gpioDoing(cx, pins, g), .style = .{ .size = 16, .color = t.on_surface } })) catch {};
            if (l.function.alt() != null) rows.append(a, cx.make(kete.Text{
                .text = kete_vc4.textf(cx, "It is {s} now", .{if (l.high) "high" else "low"}),
                .style = .{ .size = 16, .color = t.on_surface_variant },
            })) catch {};
            if (l.used) {
                const who = l.consumer();
                rows.append(a, cx.make(kete.Text{
                    .text = if (who.len > 0) kete_vc4.textf(cx, "In use by {s}, so it cannot be changed here", .{who}) else locale.text("In use by the system, so it cannot be changed here"),
                    .style = .{ .size = 15, .color = t.on_surface_variant },
                })) catch {};
            } else {
                const pick: ?*PinPick = if (self.actions) |acts| blk: {
                    const p = a.create(PinPick) catch break :blk null;
                    p.* = .{ .actions = acts, .state = state, .pin = g };
                    break :blk p;
                } else null;
                rows.append(a, cx.make(kete.Row{ .fill = false, .children = &.{
                    cx.make(PinModeMenu{
                        .options = modeOptions(a),
                        .value = pins.mode(g),
                        .placeholder = locale.text("Set mode"),
                        .on_changed = if (pick) |p| .of(p, PinPick.set) else null,
                    }),
                } })) catch {};
            }
        },
    }
    return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 6, .children = rows.items });
}

/// Menu button for configuring a GPIO pin's mode.
pub const PinModeMenu = kete.Select(Mode);

/// The modes a pin can be set to, in the system's language (in `a`).
fn modeOptions(a: std.mem.Allocator) []const PinModeMenu.Option {
    return a.dupe(PinModeMenu.Option, &.{
        .labeled(.input, locale.text("Input")),
        .labeled(.input_pull_up, locale.text("Input, pulled up")),
        .labeled(.input_pull_down, locale.text("Input, pulled down")),
        .labeled(.output_low, locale.text("Output, low")),
        .labeled(.output_high, locale.text("Output, high")),
    }) catch &.{};
}

const PinPick = struct {
    actions: *Actions,
    state: *State,
    pin: u6,

    fn set(p: *PinPick, m: Mode) void {
        p.state.dismissed = false;
        p.actions.gpio = .{ .pin = p.pin, .mode = m };
    }
};

fn usbIcon(k: usb.Kind) kete.IconName {
    return switch (k) {
        .keyboard => .keyboard,
        .mouse => .mouse,
        .input => .sports_esports,
        .storage => .usb,
        .hub => .device_hub,
        .network => .lan,
        .wireless => .wifi,
        .audio => .headphones,
        .camera => .videocam,
        .printer => .print,
        .other => .usb,
    };
}

/// Picking a part of the board.
fn partPicker(state: *State) ?kete.ValueCallback(usize) {
    return .of(state, struct {
        fn set(st: *State, i: usize) void {
            st.part = i;
        }
    }.set);
}

/// Line widths, in pixels whatever the drawing's size.
const line: f32 = 1.25;
const heavy: f32 = 1.75;

pub const BoardView = struct {
    board: *const board.Board,
    selected: ?usize = null,
    on_select: ?kete.ValueCallback(usize) = null,
    /// The biggest it is drawn.
    max_width: f32 = 260,
    max_height: f32 = 170,

    pub const State = struct {
        hovered: ?usize = null,
    };

    /// The least it needs: as a credit-card-sized board is drawn (so a
    /// big one does not make the window wider than it has to be: it is
    /// drawn as big as there is room for).
    pub fn minSize(self: *const BoardView, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        const r = self.board.bounds();
        const w = @min(260, self.max_width);
        return c.constrain(.{ .w = w, .h = @min(w * r.h / r.w, self.max_height) });
    }

    pub fn layout(self: *const BoardView, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        const r = self.board.bounds();
        const w = @min(if (std.math.isFinite(c.max_w)) c.max_w else self.max_width, self.max_width);
        const h = @min(w * r.h / r.w, self.max_height);
        return c.constrain(.{ .w = w * @min(1, h / (w * r.h / r.w)), .h = h });
    }

    /// Millimetres to the widget's pixels: the scale, and where the
    /// board's origin is.
    fn transform(self: *const BoardView, size: kete.Size) struct { scale: f32, x: f32, y: f32 } {
        const r = self.board.bounds();
        const scale = @min(size.w / r.w, size.h / r.h);
        // Centred.
        const x = (size.w - r.w * scale) / 2 - r.x * scale;
        const y = (size.h - r.h * scale) / 2 - r.y * scale;
        return .{ .scale = scale, .x = x, .y = y };
    }

    pub fn event(self: *const BoardView, n: *kete.WidgetNode, e: kete.Event) bool {
        const st = n.state(BoardView.State);
        const t = self.transform(n.size);
        const partAt = struct {
            fn f(v: *const BoardView, tr: @TypeOf(t), p: kete.Point) ?usize {
                return v.board.partAt(.{ (p[0] - tr.x) / tr.scale, (p[1] - tr.y) / tr.scale });
            }
        }.f;
        switch (e) {
            .motion => |p| {
                const h = partAt(self, t, p);
                if (h != st.hovered) {
                    st.hovered = h;
                    n.ui.needs_frame = true;
                }
            },
            .leave => if (st.hovered != null) {
                st.hovered = null;
                n.ui.needs_frame = true;
            },
            .press => |p| return p.button == .left,
            .release => |r| if (r.inside) if (partAt(self, t, r.pos)) |i| if (self.on_select) |f| f.call(i),
            else => {},
        }
        return false;
    }

    pub fn paint(self: *const BoardView, n: *kete.WidgetNode, p: *kete.Painter) void {
        const theme = n.theme();
        const t = self.transform(n.size);
        const b = self.board;
        const s = t.scale;
        const st = n.state(BoardView.State);
        const ink = theme.on_surface_variant;
        const map = struct {
            fn f(tr: @TypeOf(t), r: board.Rect) gfx.Rect {
                return .{ .x = tr.x + r.x * tr.scale, .y = tr.y + r.y * tr.scale, .w = r.w * tr.scale, .h = r.h * tr.scale };
            }
        }.f;

        // The board, with its notches cut into the edge.
        const outline = map(t, .{ .x = 0, .y = 0, .w = b.width, .h = b.height });
        var c = p.canvas();
        c.fillRoundedRect(outline, .all(b.corner * s), theme.on_surface.withAlpha(0.04));
        c.strokeRoundedRect(outline, .all(b.corner * s), heavy, ink);
        if (b.notches.len > 0) {
            const old = p.clipTo(outline.outset(heavy));
            c = p.canvas();
            for (b.notches) |notch| {
                const center: gfx.Point = .{ t.x + notch.x * s, t.y + notch.y * s };
                c.fillCircle(center, notch.r * s + heavy / 2, theme.surface);
                c.strokeCircle(center, notch.r * s, heavy, ink);
            }
            p.restoreClip(old);
            c = p.canvas();
        }
        for (b.holes) |h| c.strokeCircle(.{ t.x + h[0] * s, t.y + h[1] * s }, b.hole_diameter / 2 * s, line, ink);

        // What is under the board, faint; then what is on it.
        for (b.parts) |part| if (part.underside) drawPart(c, &part, map(t, part.rect), s, ink.withAlpha(0.35));
        for (b.parts, 0..) |part, i| if (!part.underside) {
            const pr = map(t, part.rect);
            if (partOverhangsBoard(b, &part)) {
                fillOverhangingPart(c, &part, pr, s, theme.surface, theme.on_surface.withAlpha(0.04));
            }
            const part_ink = if (st.hovered == i or self.selected == i) theme.primary else ink;
            drawPart(c, &part, pr, s, part_ink);
        };

        // Lit under the pointer, filled in when picked.
        if (st.hovered) |i| c.fillRoundedRect(map(t, b.parts[i].rect), partRadius(&b.parts[i], s), theme.primary.withAlpha(0.22));
        if (self.selected) |i| if (i < b.parts.len) {
            const r = map(t, b.parts[i].rect);
            const rad = partRadius(&b.parts[i], s);
            c.fillRoundedRect(r, rad, theme.primary.withAlpha(0.35));
            c.strokeRoundedRect(r, rad, heavy, theme.primary);
        };
    }
};

fn partOverhangsBoard(b: *const board.Board, part: *const board.Part) bool {
    if (part.underside) return false;
    const r = part.rect;
    return r.x < 0 or r.y < 0 or (r.x + r.w) > b.width or (r.y + r.h) > b.height;
}

fn partRadius(part: *const board.Part, s: f32) kete.CornerRadii {
    return switch (part.kind) {
        .gpio => .all(0),
        .act_led, .pwr_led => .all(0.25 * s),
        .antenna, .camera, .display, .camera_display, .pcie => .all(0.3 * s),
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .micro_hdmi, .power, .usb_c_power, .power_button, .usb_otg, .micro_sd, .sd => .all(0.4 * s),
        else => .all(0.6 * s),
    };
}

fn fillOverhangingPart(c: *gfx.Canvas, part: *const board.Part, r: gfx.Rect, s: f32, surface_bg: Color, board_tint: Color) void {
    if (part.kind == .composite) {
        const body: gfx.Rect = .{ .x = r.x, .y = r.y + r.h * 0.45, .w = r.w, .h = r.h * 0.55 };
        const barrel: gfx.Rect = .{ .x = r.x + r.w * 0.2, .y = r.y, .w = r.w * 0.6, .h = r.h * 0.45 };
        c.fillRoundedRect(body, .all(0.6 * s), surface_bg);
        c.fillRoundedRect(body, .all(0.6 * s), board_tint);
        c.fillRoundedRect(barrel, .all(0.4 * s), surface_bg);
        c.fillRoundedRect(barrel, .all(0.4 * s), board_tint);
        return;
    }
    const rad = partRadius(part, s);
    c.fillRoundedRect(r, rad, surface_bg);
    c.fillRoundedRect(r, rad, board_tint);
}

/// A part, as lines: its outline, and what makes it recognisable (a
/// connector's opening, a header's pins, a chip's pin 1).
fn drawPart(c: *gfx.Canvas, part: *const board.Part, r: gfx.Rect, s: f32, ink: Color) void {
    const radius: kete.CornerRadii = .all(0.6 * s);
    switch (part.kind) {
        .soc, .soc_with_ram, .ram, .usb_ethernet, .usb_controller, .southbridge, .ethernet_phy, .wireless, .pmic, .emmc => {
            c.strokeRoundedRect(r, radius, heavy, ink);
            if (part.lidded) {
                c.strokeRoundedRect(r.outset(-1.2 * s), radius, line, ink);
            } else if (r.w > 3 * s) {
                // Pin 1.
                c.fillCircle(.{ r.x + 1.4 * s, r.y + 1.4 * s }, @max(1, 0.4 * s), ink);
            }
        },
        .wireless_can => {
            c.strokeRoundedRect(r, radius, line, ink);
            c.strokeRoundedRect(r.outset(-1 * s), radius, line, ink.withAlpha(ink.a * 0.5));
        },
        .antenna => c.strokeRoundedRect(r, .all(0.3 * s), line, ink),
        .gpio, .gpio_holes => {
            if (part.kind == .gpio) c.strokeRect(r, line, ink);
            const pitch = 2.54 * s;
            for (0..part.pins[1]) |row| for (0..part.pins[0]) |col| {
                const center: gfx.Point = .{ r.x + (@as(f32, @floatFromInt(col)) + 0.5) * pitch, r.y + (@as(f32, @floatFromInt(row)) + 0.5) * pitch };
                if (part.kind == .gpio) c.fillCircle(center, @max(0.75, 0.35 * s), ink) else c.strokeCircle(center, @max(1, 0.6 * s), line, ink);
            };
        },
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .micro_hdmi, .power, .usb_c_power, .power_button, .usb_otg, .micro_sd, .sd => {
            c.strokeRoundedRect(r, .all(0.4 * s), line, ink);
            // The opening, along the edge it faces.
            const e = part.faces orelse return;
            const ports: usize = if (part.kind == .usb_double) 2 else 1;
            const depth = switch (part.kind) {
                .ethernet, .usb, .usb_double => 3 * s,
                else => 1.2 * s,
            };
            for (0..ports) |i| {
                const f: f32 = @floatFromInt(i);
                const across: f32 = @floatFromInt(ports);
                const slot: gfx.Rect = switch (e) {
                    .left, .right => .{ .x = if (e == .right) r.x + r.w - depth - 0.8 * s else r.x + 0.8 * s, .y = r.y + r.h * (0.2 + f) / across, .w = depth, .h = r.h * 0.6 / across },
                    .top, .bottom => .{ .x = r.x + r.w * 0.2, .y = if (e == .bottom) r.y + r.h - depth - 0.8 * s else r.y + 0.8 * s, .w = r.w * 0.6, .h = depth },
                };
                c.strokeRect(slot, line, ink);
            }
        },
        .audio => {
            c.strokeRoundedRect(r, .all(0.6 * s), line, ink);
            const e = part.faces orelse return;
            const center: gfx.Point = switch (e) {
                .bottom => .{ r.x + r.w / 2, r.y + r.h - 2 * s },
                .top => .{ r.x + r.w / 2, r.y + 2 * s },
                .left => .{ r.x + 2 * s, r.y + r.h / 2 },
                .right => .{ r.x + r.w - 2 * s, r.y + r.h / 2 },
            };
            c.strokeCircle(center, 1.2 * s, line, ink);
        },
        .composite => {
            c.strokeRoundedRect(.{ .x = r.x, .y = r.y + r.h * 0.45, .w = r.w, .h = r.h * 0.55 }, .all(0.6 * s), line, ink);
            c.strokeRoundedRect(.{ .x = r.x + r.w * 0.2, .y = r.y, .w = r.w * 0.6, .h = r.h * 0.45 }, .all(0.4 * s), line, ink);
        },
        .camera, .display, .camera_display, .pcie => {
            c.strokeRoundedRect(r, .all(0.3 * s), line, ink);
            // The ribbon slot along it.
            const slot: gfx.Rect = if (r.w > r.h)
                .{ .x = r.x + 1.2 * s, .y = r.y + r.h * 0.35, .w = r.w - 2.4 * s, .h = r.h * 0.3 }
            else
                .{ .x = r.x + r.w * 0.35, .y = r.y + 1.2 * s, .w = r.w * 0.3, .h = r.h - 2.4 * s };
            c.fillRect(slot, ink);
        },
        .act_led, .pwr_led => {
            c.strokeRoundedRect(r, .all(0.25 * s), line, ink);
            const lens: gfx.Rect = .{
                .x = r.x + r.w * 0.25,
                .y = r.y + r.h * 0.2,
                .w = r.w * 0.5,
                .h = r.h * 0.6,
            };
            c.strokeRoundedRect(lens, .all(0.15 * s), line, ink.withAlpha(ink.a * 0.75));
        },
        .edge => {
            // The contacts.
            const pitch = 1.2 * s;
            var x = r.x + pitch / 2;
            while (x <= r.x + r.w) : (x += pitch) c.fillRect(.{ .x = x, .y = r.y + 0.3 * s, .w = line, .h = r.h - 0.6 * s }, ink);
        },
    }
}

const testing = std.testing;
const font = kete.font;

test "the board, drawn: picking a part says what it is" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var d = view.sample();
    const wifi = view.sampleWifi();
    d.sys.model = .of("Raspberry Pi 3 Model B Plus Rev 1.3");
    var n: u64 = 0;
    const draw = struct {
        fn frame(uu: *kete.ui.WindowUi, dd: anytype, w: *const info.manager.Report, nn: *u64, size: [2]u32) void {
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Settings{ .commit = "574d538", .system = &dd.sys, .usage = dd.usage, .network = &dd.net, .manager = w, .apps = view.sample_apps });
        }
    }.frame;
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    u.root.?.state(Settings.State).page = .board;
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    // The processor to begin with.
    try testing.expect(view.findText(u.root.?, "Processor and graphics: BCM2837B0") != null);
    try testing.expect(view.findText(u.root.?, "23% busy, at 48.3 °C") != null);

    // Clicking the Ethernet port.
    const bv = view.findType(u.root.?, BoardView).?;
    const drawing = board.forModel("Raspberry Pi 3 Model B Plus Rev 1.3").?;
    const r = drawing.bounds();
    const scale = @min(bv.size.w / r.w, bv.size.h / r.h);
    const origin = bv.position();
    const x0 = origin[0] + (bv.size.w - r.w * scale) / 2 - r.x * scale;
    const y0 = origin[1] + (bv.size.h - r.h * scale) / 2 - r.y * scale;
    const p: kete.Point = .{ x0 + 76 * scale, y0 + 45 * scale };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    try testing.expect(view.findText(u.root.?, "Ethernet") != null);
    try testing.expect(view.findText(u.root.?, "The wired network") != null);

    // Clicking the microSD card (underneath): how big it is, and who made
    // it.
    const sd = for (drawing.parts) |part| {
        if (part.kind == .micro_sd) break part.rect;
    } else unreachable;
    const sd_pt: kete.Point = .{ x0 + (sd.x + sd.w / 2) * scale, y0 + (sd.y + sd.h / 2) * scale };
    u.pointerMotion(sd_pt);
    u.pointerButton(sd_pt, .left, true);
    u.pointerButton(sd_pt, .left, false);
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    try testing.expect(view.findText(u.root.?, "microSD card") != null);
    try testing.expect(view.findText(u.root.?, "32 GB, made by SanDisk") != null);

    // Clicking a USB connector shows plugged-in USB devices, or "Nothing is plugged in".
    const usb_pt: kete.Point = .{ x0 + 78 * scale, y0 + 9 * scale };
    u.pointerMotion(usb_pt);
    u.pointerButton(usb_pt, .left, true);
    u.pointerButton(usb_pt, .left, false);
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    try testing.expect(view.findText(u.root.?, "USB") != null);
    try testing.expect(view.findText(u.root.?, "Nothing is plugged in") != null);

    var devices: usb.Devices = .{};
    devices.items[0] = .{ .kind = .keyboard, .speed_mbps = 1.5, .vendor_id = 0x046d, .product_id = 0xc31c };
    devices.items[0].product.set("USB Keyboard");
    devices.items[0].manufacturer.set("Logitech");
    devices.items[1] = .{ .kind = .storage, .speed_mbps = 480, .vendor_id = 0x0781, .product_id = 0x5567 };
    devices.items[2] = .{ .kind = .network, .speed_mbps = 480, .built_in = true, .vendor_id = 0x0424, .product_id = 0xec00 };
    devices.len = 3;
    n += 1;
    u.frame(1600, 900, n, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = view.sample_apps, .usb = &devices });
    try testing.expect(view.findText(u.root.?, "USB Keyboard") != null);
    try testing.expect(view.findText(u.root.?, "Keyboard  \u{b7}  Logitech  \u{b7}  1.5 Mb/s") != null);
    try testing.expect(view.findText(u.root.?, "USB device 0781:5567") != null);
    try testing.expect(view.findText(u.root.?, "Network adapter  \u{b7}  480 Mb/s  \u{b7}  Part of the board") != null);

    // Every board fits, at every size.
    for ([_][]const u8{ "Raspberry Pi Model B Rev 2", "Raspberry Pi Zero 2 W Rev 1.0", "Raspberry Pi Compute Module 3 Rev 1.0", "Raspberry Pi 4 Model B Rev 1.4", "Raspberry Pi Compute Module 4 Rev 1.0", "Raspberry Pi 5 Model B Rev 1.0", "Raspberry Pi Compute Module 5 Rev 1.0", "Something else" }) |model| {
        d.sys.model = .of(model);
        for (view.test_sizes) |size| {
            draw(u, &d, &wifi, &n, size);
            try testing.expect(!view.overflows(u.root.?));
        }
    }
    try testing.expect(view.findText(u.root.?, "There is no drawing of this board") != null);
}

test "selecting the GPIO header shows the horizontal pin diagram, colour key, and pin mode menu" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var d = view.sample();
    var actions: Actions = .{};
    var pins: gpio.Pins = .{ .opened = true, .chip = .{ .fd = -1 } };
    pins.lines[17] = .{ .function = .output, .high = true };
    pins.lines[4] = .{ .function = .input, .high = true };
    pins.lines[14] = .{ .function = .alt0, .used = true };
    @memcpy(pins.lines[14].consumer_buf[0..6], "serial");
    pins.lines[14].consumer_len = 6;
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .gpio = &pins };

    d.sys.model = .of("Raspberry Pi 3 Model B Plus Rev 1.3");
    u.frame(1600, 900, 1, settings);
    u.root.?.state(Settings.State).page = .board;
    u.frame(1600, 900, 2, settings);

    // Click the GPIO header on the board drawing.
    const bv = view.findType(u.root.?, BoardView).?;
    const drawing = board.forModel("Raspberry Pi 3 Model B Plus Rev 1.3").?;
    const r = drawing.bounds();
    const scale = @min(bv.size.w / r.w, bv.size.h / r.h);
    const origin = bv.position();
    const x0 = origin[0] + (bv.size.w - r.w * scale) / 2 - r.x * scale;
    const y0 = origin[1] + (bv.size.h - r.h * scale) / 2 - r.y * scale;
    const gpio_pt: kete.Point = .{ x0 + 32.5 * scale, y0 + 3.5 * scale };
    u.pointerMotion(gpio_pt);
    u.pointerButton(gpio_pt, .left, true);
    u.pointerButton(gpio_pt, .left, false);

    // Every board with a header fits at every window size when the GPIO header is selected.
    for ([_][]const u8{ "Raspberry Pi 3 Model B Plus Rev 1.3", "Raspberry Pi Model B Rev 1", "Raspberry Pi Zero W Rev 1.1" }) |model| {
        d.sys.model = .of(model);
        _ = view.showGpio(u);
        for (view.test_sizes) |size| {
            u.frame(size[0], size[1], 3, settings);
            try testing.expect(!view.overflows(u.root.?));
        }
    }
    d.sys.model = .of("Raspberry Pi 3 Model B Plus Rev 1.3");
    _ = view.showGpio(u);
    u.frame(1600, 900, 4, settings);

    // Header description and colour key are shown.
    try testing.expect(view.findText(u.root.?, "GPIO header") != null);
    try testing.expect(view.findText(u.root.?, "5V") != null);
    try testing.expect(view.findText(u.root.?, "3.3V") != null);
    try testing.expect(view.findText(u.root.?, "Ground") != null);
    try testing.expect(view.findText(u.root.?, "Input") != null);
    try testing.expect(view.findText(u.root.?, "Output") != null);
    try testing.expect(view.findText(u.root.?, "Other") != null);

    // Pin 11 (GPIO 17) is selected to start with, showing a menu button with "Output, high".
    try testing.expect(view.findText(u.root.?, "GPIO 17, pin 11") != null);
    try testing.expect(view.findType(u.root.?, PinModeMenu) != null);
    view.click(u, view.findType(u.root.?, PinModeMenu).?);
    u.frame(1600, 900, 5, settings);
    try testing.expect(u.menu_root != null);
    view.click(u, view.findText(u.menu_root.?, "Output, low").?);
    try testing.expectEqual(Actions.GpioChange{ .pin = 17, .mode = .output_low }, actions.gpio.?);

    // Selecting Pin 2 (5V) shows its description without a mode menu.
    view.click(u, view.up(view.findText(u.root.?, "2").?, kete.Pressable).?);
    u.frame(1600, 900, 6, settings);
    try testing.expect(view.findText(u.root.?, "5V, pin 2") != null);
    try testing.expect(view.findText(u.root.?, "5 V power from the board's power supply") != null);
    try testing.expect(view.findType(u.root.?, PinModeMenu) == null);

    // Selecting Pin 8 (GPIO 14, TXD, in use by serial) shows its description and cannot be configured.
    view.click(u, view.up(view.findText(u.root.?, "8").?, kete.Pressable).?);
    u.frame(1600, 900, 7, settings);
    try testing.expect(view.findText(u.root.?, "GPIO 14 (TXD), pin 8") != null);
    try testing.expect(view.findText(u.root.?, "UART 0 transmit") != null);
    try testing.expect(view.findText(u.root.?, "In use by serial, so it cannot be changed here") != null);
    try testing.expect(view.findType(u.root.?, PinModeMenu) == null);

    // Selecting Pin 7 (GPIO 4, GPCLK0) shows its description and can be configured via the menu button.
    view.click(u, view.up(view.findText(u.root.?, "7").?, kete.Pressable).?);
    u.frame(1600, 900, 8, settings);
    try testing.expect(view.findText(u.root.?, "GPIO 4 (GPCLK0), pin 7") != null);
    view.click(u, view.findType(u.root.?, PinModeMenu).?);
    u.frame(1600, 900, 9, settings);
    view.click(u, view.findText(u.menu_root.?, "Input, pulled down").?);
    try testing.expectEqual(Actions.GpioChange{ .pin = 4, .mode = .input_pull_down }, actions.gpio.?);

    // When the pins cannot be read, the failure is shown.
    pins.read_failure = "Not allowed to use the GPIO";
    u.frame(1600, 900, 10, settings);
    try testing.expect(view.findText(u.root.?, "Not allowed to use the GPIO") != null);
}

test "a big board (the Pi 400) is drawn as wide as the page has room for, no wider" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var d = view.sample();
    const wifi = view.sampleWifi();
    d.sys.model = .of("Raspberry Pi 400 Rev 1.0");
    for ([_][2]u32{ .{ 900, 430 }, .{ 900, 430 }, .{ 1600, 900 } }, 0..) |size, i| {
        if (i == 1) u.root.?.state(Settings.State).page = .board;
        u.frame(size[0], size[1], i + 1, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = view.sample_apps });
        if (i == 0) continue;
        const bv = view.findType(u.root.?, BoardView).?;
        try testing.expect(bv.position()[0] + bv.size.w <= @as(f32, @floatFromInt(size[0])));
        // It does not make the window's least width more than the
        // smaller boards do.
        try testing.expect(bv.minSize(.{}).w <= 260);
    }
}
