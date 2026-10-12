//! A board, drawn as line art in the theme's colours (see board.zig): its
//! outline and mounting holes, and its parts, the chips a little heavier
//! than the connectors, and what is under the board fainter. The part
//! under the pointer is lit, and the one picked is filled in; clicking (or
//! tapping) a part picks it.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const locale = @import("locale");
const info = @import("info.zig");
const board = @import("board.zig");
const usb = @import("usb.zig");
const view = @import("view.zig");

const Color = gfx.Color;
const Settings = view.Settings;
const Builder = view.Builder;

pub const label = "Board";
pub const icon: ui.icons.Icon = .developer_board;

pub const State = struct {
    /// The part of the board picked (an index into its parts), if one is.
    part: ?usize = null,
};

/// The board, drawn, and about the part picked on it.
pub fn build(self: *const Settings, b: Builder, state: *State) ui.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const a = cx.ui.arena();
    const model = self.system.model.slice();
    var rows: std.ArrayList(ui.Widget) = .empty;
    rows.append(a, b.value(view.orUnknown(model))) catch {};
    if (self.system.serial.len > 0) rows.append(a, cx.make(ui.Text{ .text = cx.fmt("Serial: {s}", .{self.system.serial.slice()}), .style = .{ .size = 16, .color = t.on_surface_variant } })) catch {};
    const drawing = board.forModel(model) orelse {
        rows.append(a, b.value("There is no drawing of this board")) catch {};
        return b.page(rows.items);
    };
    // The processor, until something else is picked.
    const picked = state.part orelse for (drawing.parts, 0..) |part, i| {
        if (part.kind == .soc or part.kind == .soc_with_ram) break i;
    } else 0;
    const part = &drawing.parts[@min(picked, drawing.parts.len - 1)];
    const about = board.describe(part);
    rows.appendSlice(a, &.{
        cx.make(ui.Padding{ .padding = .symmetric(0, 8), .child = cx.make(ui.Align{ .alignment = .center_left, .child = cx.make(BoardView{ .board = drawing, .selected = picked, .on_select = partPicker(state) }) }) }),
        cx.make(ui.Text{ .text = if (part.chip.len > 0) cx.fmt("{s}: {s}", .{ about.title, part.chip }) else about.title, .style = .{ .size = 20, .color = t.on_surface } }),
        cx.make(ui.Text{ .text = cx.fmt("{s}{s}", .{ about.about, if (part.underside) " (underneath the board)" else "" }), .style = .{ .size = 16, .color = t.on_surface_variant } }),
    }) catch {};
    // What it is doing now, where that is known.
    const u = self.usage;
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const now: ?[]const u8 = switch (part.kind) {
        .soc => if (u.cpu_busy) |busy| (if (u.temperature) |c| cx.fmt("{d:.0}% busy, at {s}", .{ busy, locale.formatTemperature(&b1, c) }) else cx.fmt("{d:.0}% busy", .{busy})) else null,
        .soc_with_ram => if (u.cpu_busy) |busy| cx.fmt("{d:.0}% busy; {s} of {s} of memory in use", .{ busy, info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) }) else null,
        .ram => cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) }),
        .micro_sd, .sd, .emmc => if (u.storage.user + u.storage.apps > 0) cx.fmt("{s} of your files and {s} of apps", .{ info.formatBytes(&b1, u.storage.user), info.formatBytes(&b2, u.storage.apps) }) else null,
        .usb, .usb_double, .usb_otg => if (self.usb.len == 0) "Nothing is plugged in" else null,
        else => null,
    };
    if (now) |text| rows.append(a, cx.make(ui.Text{ .text = text, .style = .{ .size = 16, .color = t.on_surface } })) catch {};
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
            rows.append(a, cx.make(ui.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = &.{
                cx.make(ui.Icon{ .icon = usbIcon(d.kind), .size = 28, .color = t.on_surface_variant }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                    cx.make(ui.Text{ .text = cx.fmt("{s}", .{d.name(&name_buf)}), .style = .{ .size = 18 }, .wrap = false, .ellipsis = true }),
                    cx.make(ui.Text{ .text = detail.items, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
                } }) }),
            } })) catch {};
        }
    }
    return b.page(rows.items);
}

fn usbIcon(k: usb.Kind) ui.icons.Icon {
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
fn partPicker(state: *State) ?ui.ValueCallback(usize) {
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
    on_select: ?ui.ValueCallback(usize) = null,
    /// The biggest it is drawn.
    max_width: f32 = 260,
    max_height: f32 = 170,

    pub const State = struct {
        hovered: ?usize = null,
    };

    pub fn layout(self: *const BoardView, _: *ui.Node, c: ui.Constraints) ui.Size {
        const r = self.board.bounds();
        const w = @min(if (std.math.isFinite(c.max_w)) c.max_w else self.max_width, self.max_width);
        const h = @min(w * r.h / r.w, self.max_height);
        return c.constrain(.{ .w = w * @min(1, h / (w * r.h / r.w)), .h = h });
    }

    /// Millimetres to the widget's pixels: the scale, and where the
    /// board's origin is.
    fn transform(self: *const BoardView, size: ui.Size) struct { scale: f32, x: f32, y: f32 } {
        const r = self.board.bounds();
        const scale = @min(size.w / r.w, size.h / r.h);
        // Centred.
        const x = (size.w - r.w * scale) / 2 - r.x * scale;
        const y = (size.h - r.h * scale) / 2 - r.y * scale;
        return .{ .scale = scale, .x = x, .y = y };
    }

    pub fn event(self: *const BoardView, n: *ui.Node, e: ui.Event) bool {
        const st = n.state(BoardView.State);
        const t = self.transform(n.size);
        const partAt = struct {
            fn f(v: *const BoardView, tr: @TypeOf(t), p: ui.Point) ?usize {
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
            .press => |p| return p.button == ui.btn_left,
            .release => |r| if (r.inside) if (partAt(self, t, r.pos)) |i| if (self.on_select) |f| f.call(i),
            else => {},
        }
        return false;
    }

    pub fn paint(self: *const BoardView, n: *ui.Node, p: *ui.Painter) void {
        const theme = &n.ui.theme;
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
        for (b.parts) |part| if (!part.underside) drawPart(c, &part, map(t, part.rect), s, ink);

        // Lit under the pointer, filled in when picked.
        if (st.hovered) |i| c.fillRoundedRect(map(t, b.parts[i].rect), .all(0.6 * s), theme.primary.withAlpha(0.18));
        if (self.selected) |i| if (i < b.parts.len) {
            const r = map(t, b.parts[i].rect);
            c.fillRoundedRect(r, .all(0.6 * s), theme.primary.withAlpha(0.35));
            c.strokeRoundedRect(r, .all(0.6 * s), heavy, theme.primary);
        };
    }
};

/// A part, as lines: its outline, and what makes it recognisable (a
/// connector's opening, a header's pins, a chip's pin 1).
fn drawPart(c: *gfx.Canvas, part: *const board.Part, r: gfx.Rect, s: f32, ink: Color) void {
    const radius: gfx.Radii = .all(0.6 * s);
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
            c.strokeRoundedRect(r, .all(0.4 * s), line, ink);
            // The latch along it.
            if (r.h > r.w) {
                c.fillRect(.{ .x = r.x + r.w / 2 - line / 2, .y = r.y + 1.5 * s, .w = line, .h = r.h - 3 * s }, ink);
            } else {
                c.fillRect(.{ .x = r.x + 1.5 * s, .y = r.y + r.h / 2 - line / 2, .w = r.w - 3 * s, .h = line }, ink);
            }
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
const font = @import("font");

test "the board, drawn: picking a part says what it is" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var d = view.sample();
    const wifi = view.sampleWifi();
    d.sys.model = .of("Raspberry Pi 3 Model B Plus Rev 1.3");
    var n: u64 = 0;
    const draw = struct {
        fn frame(uu: *ui.Ui, dd: anytype, w: *const info.manager.Report, nn: *u64, size: [2]u32) void {
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
    const p: ui.Point = .{ x0 + 76 * scale, y0 + 45 * scale };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    try testing.expect(view.findText(u.root.?, "Ethernet") != null);
    try testing.expect(view.findText(u.root.?, "The wired network") != null);

    // Clicking a USB connector shows plugged-in USB devices, or "Nothing is plugged in".
    const usb_pt: ui.Point = .{ x0 + 78 * scale, y0 + 9 * scale };
    u.pointerMotion(usb_pt);
    u.pointerButton(usb_pt, ui.btn_left, true);
    u.pointerButton(usb_pt, ui.btn_left, false);
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
