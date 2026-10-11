//! A board, drawn as line art in the theme's colours (see board.zig): its
//! outline and mounting holes, and its parts, the chips a little heavier
//! than the connectors, and what is under the board fainter. The part
//! under the pointer is lit, and the one picked is filled in; clicking (or
//! tapping) a part picks it.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const board = @import("board.zig");

const Color = gfx.Color;

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
        const st = n.state(State);
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
        const st = n.state(State);
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
        .soc, .soc_with_ram, .ram, .usb_ethernet, .usb_controller, .ethernet_phy, .wireless, .pmic, .emmc => {
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
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .micro_hdmi, .power, .usb_c_power, .usb_otg, .micro_sd, .sd => {
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
        .camera, .display => {
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
