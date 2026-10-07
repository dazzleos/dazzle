//! A board, drawn (see board.zig): the board in green with its mounting
//! holes, the chips black (or metal, with a heat spreader or a can), the
//! connectors in metal or plastic with their openings, and what is under
//! the board as outlines. The part under the pointer is lit, and the one
//! picked is outlined; clicking (or tapping) a part picks it.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const board = @import("board.zig");

const Color = gfx.Color;

const pcb = Color.argb(0xff1f7a4a);
const pcb_edge = Color.argb(0xff2f9a62);
const gold = Color.argb(0xffd9b45a);
const metal = Color.argb(0xffbfc4c9);
const metal_dark = Color.argb(0xff8d939a);
const plastic = Color.argb(0xff26282b);
const opening = Color.argb(0xff151617);
const chip_black = Color.argb(0xff222324);
const latch = Color.argb(0xffe8e4d8);
const yellow = Color.argb(0xffe6c229);
const copper = Color.argb(0xffc9824a);

pub const BoardView = struct {
    board: *const board.Board,
    selected: ?usize = null,
    on_select: ?ui.ValueCallback(usize) = null,
    /// The tallest it is drawn.
    max_height: f32 = 360,

    pub const State = struct {
        hovered: ?usize = null,
    };

    pub fn layout(self: *const BoardView, _: *ui.Node, c: ui.Constraints) ui.Size {
        const r = self.board.bounds();
        const w = if (std.math.isFinite(c.max_w)) c.max_w else 600;
        const h = @min(w * r.h / r.w, self.max_height);
        return c.constrain(.{ .w = w, .h = h });
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
        const c = p.canvas();
        const theme = &n.ui.theme;
        const t = self.transform(n.size);
        const b = self.board;
        const s = t.scale;
        const map = struct {
            fn f(tr: @TypeOf(t), r: board.Rect) gfx.Rect {
                return .{ .x = tr.x + r.x * tr.scale, .y = tr.y + r.y * tr.scale, .w = r.w * tr.scale, .h = r.h * tr.scale };
            }
        }.f;
        const st = n.state(State);

        // Underneath: outlines, showing through the board.
        for (b.parts, 0..) |part, i| if (part.underside) {
            const r = map(t, part.rect);
            c.fillRoundedRect(r, .all(0.8 * s), theme.on_surface.withAlpha(if (st.hovered == i) 0.18 else 0.06));
        };

        // The board, its notches and holes cut out (in the background's
        // colour).
        const outline = map(t, .{ .x = 0, .y = 0, .w = b.width, .h = b.height });
        c.fillRoundedRect(outline, .all(b.corner * s), pcb_edge);
        c.fillRoundedRect(outline.outset(-0.4 * s), .all(@max(0, b.corner - 0.4) * s), pcb);
        for (b.notches) |notch| c.fillCircle(.{ t.x + notch.x * s, t.y + notch.y * s }, notch.r * s, theme.surface_container);
        for (b.holes) |h| {
            const center: gfx.Point = .{ t.x + h[0] * s, t.y + h[1] * s };
            c.fillCircle(center, (b.hole_diameter / 2 + 1.2) * s, gold);
            c.fillCircle(center, b.hole_diameter / 2 * s, theme.surface_container);
        }

        // The underside's outlines over the board.
        for (b.parts) |part| if (part.underside) {
            c.strokeRoundedRect(map(t, part.rect), .all(0.8 * s), @max(1, 0.3 * s), Color.argb(0xffb8e0c8).withAlpha(0.6));
        };

        // What is on top.
        for (b.parts) |part| if (!part.underside) drawPart(c, &part, map(t, part.rect), s);

        // Lit under the pointer, outlined when picked.
        if (st.hovered) |i| {
            const r = map(t, b.parts[i].rect);
            c.fillRoundedRect(r, .all(0.8 * s), theme.primary.withAlpha(0.25));
        }
        if (self.selected) |i| if (i < b.parts.len) {
            const r = map(t, b.parts[i].rect).outset(2);
            c.strokeRoundedRect(r, .all(0.8 * s + 2), 3, theme.primary);
        };
    }
};

fn drawPart(c: *gfx.Canvas, part: *const board.Part, r: gfx.Rect, s: f32) void {
    const radius: gfx.Radii = .all(0.6 * s);
    switch (part.kind) {
        .soc, .soc_with_ram, .ram, .usb_ethernet, .wireless, .pmic, .emmc => {
            if (part.lidded) {
                c.fillRoundedRect(r.outset(0.6 * s), radius, chip_black);
                c.fillRoundedRect(r, radius, metal);
                c.strokeRoundedRect(r, radius, @max(1, 0.25 * s), metal_dark);
            } else {
                c.fillRoundedRect(r, radius, chip_black);
                // Pin 1.
                c.fillCircle(.{ r.x + 1.2 * s, r.y + 1.2 * s }, 0.45 * s, Color.argb(0xff4a4c4f));
            }
        },
        .wireless_can => {
            c.fillRoundedRect(r, radius, metal);
            c.strokeRoundedRect(r, radius, @max(1, 0.25 * s), metal_dark);
        },
        .antenna => c.fillRoundedRect(r, .all(0.3 * s), copper),
        .gpio, .gpio_holes => {
            if (part.kind == .gpio) c.fillRect(r, plastic);
            const cols: usize = part.pins[0];
            const rows: usize = part.pins[1];
            const pitch = 2.54 * s;
            for (0..rows) |row| for (0..cols) |col| {
                const center: gfx.Point = .{ r.x + (@as(f32, @floatFromInt(col)) + 0.5) * pitch, r.y + (@as(f32, @floatFromInt(row)) + 0.5) * pitch };
                if (part.kind == .gpio) {
                    c.fillRect(.{ .x = center[0] - 0.32 * s, .y = center[1] - 0.32 * s, .w = 0.64 * s, .h = 0.64 * s }, gold);
                } else {
                    c.fillCircle(center, 0.85 * s, gold);
                    c.fillCircle(center, 0.5 * s, pcb.withAlpha(1));
                }
            };
        },
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .power, .usb_otg, .micro_sd => {
            c.fillRoundedRect(r, .all(0.4 * s), metal);
            c.strokeRoundedRect(r, .all(0.4 * s), @max(1, 0.2 * s), metal_dark);
            // The opening, along the edge it faces.
            const ports: usize = if (part.kind == .usb_double) 2 else 1;
            const e = part.faces orelse return;
            const depth = switch (part.kind) {
                .ethernet, .usb, .usb_double => 3.5 * s,
                else => 1.6 * s,
            };
            for (0..ports) |i| {
                const f: f32 = @floatFromInt(i);
                const across: f32 = @floatFromInt(ports);
                const slot: gfx.Rect = switch (e) {
                    .left, .right => .{ .x = if (e == .right) r.x + r.w - depth else r.x, .y = r.y + r.h * (0.15 + f) / across, .w = depth, .h = r.h * 0.7 / across },
                    .top, .bottom => .{ .x = r.x + r.w * 0.15, .y = if (e == .bottom) r.y + r.h - depth else r.y, .w = r.w * 0.7, .h = depth },
                };
                c.fillRect(slot, opening);
            }
        },
        .audio => {
            c.fillRoundedRect(r, .all(0.6 * s), plastic);
            const e = part.faces orelse return;
            const center: gfx.Point = switch (e) {
                .bottom => .{ r.x + r.w / 2, r.y + r.h - 1.6 * s },
                .top => .{ r.x + r.w / 2, r.y + 1.6 * s },
                .left => .{ r.x + 1.6 * s, r.y + r.h / 2 },
                .right => .{ r.x + r.w - 1.6 * s, r.y + r.h / 2 },
            };
            c.fillCircle(center, 1.4 * s, metal);
            c.fillCircle(center, 0.9 * s, opening);
        },
        .composite => {
            // A yellow body, and the metal barrel out past the edge.
            c.fillRoundedRect(.{ .x = r.x, .y = r.y + r.h * 0.45, .w = r.w, .h = r.h * 0.55 }, .all(0.6 * s), yellow);
            c.fillRoundedRect(.{ .x = r.x + r.w * 0.2, .y = r.y, .w = r.w * 0.6, .h = r.h * 0.5 }, .all(0.4 * s), metal);
        },
        .camera, .display => {
            c.fillRoundedRect(r, .all(0.4 * s), plastic);
            // The latch along it.
            const inset = 0.8 * s;
            if (r.h > r.w) {
                c.fillRect(.{ .x = r.x + inset, .y = r.y + 1.5 * s, .w = r.w - 2 * inset, .h = r.h - 3 * s }, latch);
            } else {
                c.fillRect(.{ .x = r.x + 1.5 * s, .y = r.y + inset, .w = r.w - 3 * s, .h = r.h - 2 * inset }, latch);
            }
        },
        .sd => {},
        .edge => {
            // Gold contacts.
            const pitch = 0.6 * s;
            var x = r.x + pitch / 2;
            while (x + pitch / 2 <= r.x + r.w) : (x += pitch) c.fillRect(.{ .x = x, .y = r.y, .w = pitch * 0.55, .h = r.h }, gold);
        },
    }
}
