//! A touchscreen beside a monitor: with a monitor on HDMI and a display on
//! the DSI connector (the Touch Display 2) both there, the desktop is on
//! the monitor, and the touchscreen is its keyboard and touchpad. The
//! on-screen keyboard is along its bottom, always (its keys type into the
//! app with the keyboard, as they do on a touchscreen alone), and the rest
//! of it is a touchpad that moves the monitor's pointer (`Touchpad`).
//!
//! It has a renderer of its own (the touchscreen is a second display,
//! on its own CRTC), which draws only its two panels.

const std = @import("std");
const kete = @import("kete");
const render = @import("render.zig");
const kete_panel = @import("kete_panel.zig");
const input = @import("input.zig");
const sys = @import("sys");

const evdev = sys.evdev;

/// The touchpad: fingers on it move the pointer, and click and scroll.
///
/// * One finger moved: the pointer moves with it (`gain` times as far).
/// * One finger tapped (down and up again soon, without moving): a click.
/// * Two fingers moved: they scroll (down, the page goes up, as on a
///   touchscreen).
/// * Two fingers tapped: a right click.
/// * Tapped, then down again soon and moved: a drag (the left button held
///   until the finger is let go), as a laptop's touchpad does.
pub const Touchpad = struct {
    touches: [2]?Touch = .{ null, null },
    /// The most fingers down at once since the first went down.
    most: u8 = 0,
    /// Whether they moved further than a tap.
    moved: bool = false,
    first_down_ns: u64 = 0,
    /// Motion not moved yet (a fraction of a pixel).
    left_over: [2]f64 = .{ 0, 0 },
    /// How far the pointer moves for a finger's pixel.
    gain: f64 = 2,
    /// When the last one-finger tap was let go (0: none since), and
    /// whether the finger down now is dragging (the left button held).
    tapped_ns: u64 = 0,
    dragging: bool = false,

    const Touch = struct { id: i32, at: [2]f64, from: [2]f64 };

    /// A tap is let go within this long...
    pub const tap_ns = 250 * std.time.ns_per_ms;
    /// ... having moved no further than this (pixels).
    pub const tap_slop = 12;

    /// The events touch `id` going down at (x, y) (touchpad pixels) makes,
    /// in `out`: the left button pressed, if it is down again soon after a
    /// tap (a drag).
    pub fn down(p: *Touchpad, id: i32, x: f64, y: f64, now: u64, out: *Out) void {
        if (p.count() == 0) {
            p.most = 0;
            p.moved = false;
            p.first_down_ns = now;
            if (p.tapped_ns != 0 and now -| p.tapped_ns <= tap_ns) {
                p.dragging = true;
                out.add(.{ .button = .{ .code = evdev.btn_left, .pressed = true } });
            }
            p.tapped_ns = 0;
        }
        for (&p.touches) |*slot| if (slot.* == null) {
            slot.* = .{ .id = id, .at = .{ x, y }, .from = .{ x, y } };
            break;
        };
        p.most = @max(p.most, p.count());
    }

    /// Touch `id` moved to (x, y): the pointer's motion (one finger), or
    /// scrolling (two), in `out`.
    pub fn motion(p: *Touchpad, id: i32, x: f64, y: f64, out: *Out) void {
        const t = p.find(id) orelse return;
        const dx = x - t.at[0];
        const dy = y - t.at[1];
        t.at = .{ x, y };
        if (@abs(x - t.from[0]) > tap_slop or @abs(y - t.from[1]) > tap_slop) p.moved = true;
        switch (p.count()) {
            1 => {
                p.left_over[0] += dx * p.gain;
                p.left_over[1] += dy * p.gain;
                const mx = @trunc(p.left_over[0]);
                const my = @trunc(p.left_over[1]);
                p.left_over[0] -= mx;
                p.left_over[1] -= my;
                if (mx != 0 or my != 0) out.add(.{ .motion = .{ @intFromFloat(mx), @intFromFloat(my) } });
            },
            // Each finger scrolls half (both move).
            2 => if (dy != 0) out.add(.{ .axis = .{ .axis = 0, .value = -dy / 2 } }),
            else => {},
        }
    }

    /// Touch `id` let go: a click, if it was a tap (a right click with two
    /// fingers).
    pub fn up(p: *Touchpad, id: i32, now: u64, out: *Out) void {
        for (&p.touches) |*slot| if (slot.*) |t| if (t.id == id) {
            slot.* = null;
        };
        if (p.count() != 0) return;
        // A drag ends: the button let go.
        if (p.dragging) {
            p.dragging = false;
            out.add(.{ .button = .{ .code = evdev.btn_left, .pressed = false } });
            return;
        }
        if (p.moved or now -| p.first_down_ns > tap_ns) return;
        const button: u32 = if (p.most >= 2) evdev.btn_right else evdev.btn_left;
        out.add(.{ .button = .{ .code = button, .pressed = true } });
        out.add(.{ .button = .{ .code = button, .pressed = false } });
        if (p.most == 1) p.tapped_ns = now;
    }

    fn count(p: *const Touchpad) u8 {
        var n: u8 = 0;
        for (p.touches) |t| n += @intFromBool(t != null);
        return n;
    }

    fn find(p: *Touchpad, id: i32) ?*Touch {
        for (&p.touches) |*slot| if (slot.*) |*t| if (t.id == id) return t;
        return null;
    }
};

/// The events a touch makes.
pub const Out = struct {
    events: [4]input.Event = undefined,
    len: usize = 0,

    fn add(o: *Out, e: input.Event) void {
        if (o.len == o.events.len) return;
        o.events[o.len] = e;
        o.len += 1;
    }

    pub fn slice(o: *const Out) []const input.Event {
        return o.events[0..o.len];
    }
};

pub const Companion = struct {
    renderer: render.Renderer,
    /// Where the touchpad's hint is drawn.
    panel: *kete_panel.Panel,
    pad: Touchpad = .{},
    /// The touchpad's height: the screen's, but for the keyboard below it.
    pad_height: u32 = 0,
    /// Something changed: drawn and shown again.
    dirty: bool = true,
    /// Where the touch on the keyboard last was (in it): a touch let go
    /// says no place, and lets go there.
    key_touch_at: [2]f32 = .{ 0, 0 },
    /// When the last frame was queued (for `serviceFlip`).
    queued_ns: u64 = 0,
    /// A flip's event did not come (said once).
    flip_warned: bool = false,

    /// How long a frame may take to reach the touchscreen before it is
    /// taken as shown anyway (so a flip whose event never comes does not
    /// stop it being drawn again).
    pub const flip_timeout_ns = 200 * std.time.ns_per_ms;

    /// Whether the last frame has reached the touchscreen (reading the
    /// DRM file's events, if there are any, without waiting).
    pub fn serviceFlip(c: *Companion, now: u64) bool {
        const r = &c.renderer;
        if (!r.flipPending()) return true;
        _ = r.handleEvents() catch null;
        if (!r.flipPending()) return true;
        if (now -| c.queued_ns < flip_timeout_ns) return false;
        if (!c.flip_warned) {
            c.flip_warned = true;
            sys.print(sys.log_warning ++ "dazzle-shell: the touchscreen's frame was not said to be shown: taken as shown\n", .{});
        }
        r.display.assumeFlipped();
        return true;
    }

    /// The touchscreen's size (turned, if it is used on its side).
    pub fn width(c: *const Companion) u32 {
        return c.renderer.width;
    }

    pub fn height(c: *const Companion) u32 {
        return c.renderer.height;
    }

    /// Sizes the touchpad above a keyboard `keyboard_height` high.
    pub fn layout(c: *Companion, keyboard_height: u32) void {
        c.pad_height = c.height() -| keyboard_height;
        c.dirty = true;
    }

    /// Where a touch at (x, y) (0 to 1 across and down the touchscreen
    /// panel, as it reports them) is on the touchscreen as it is used.
    pub fn place(c: *const Companion, x: f64, y: f64) [2]f64 {
        const at = c.renderer.turn.toScreen(x, y);
        return .{ at[0] * @as(f64, @floatFromInt(c.width() - 1)), at[1] * @as(f64, @floatFromInt(c.height() - 1)) };
    }

    /// The other way: where (x, y) on the touchscreen as it is used is, as
    /// the touchscreen panel reports it (0 to 1).
    pub fn unplace(c: *const Companion, at: [2]f64) [2]f64 {
        const tx = at[0] / @as(f64, @floatFromInt(c.width() - 1));
        const ty = at[1] / @as(f64, @floatFromInt(c.height() - 1));
        return c.renderer.turn.fromScreen(tx, ty);
    }

    /// Whether (x, y) (touchscreen pixels) is on the touchpad.
    pub fn onPad(c: *const Companion, at: [2]f64) bool {
        return at[1] < @as(f64, @floatFromInt(c.pad_height));
    }

    /// Draws the touchpad, and the keyboard below it (`keyboard`), and
    /// shows them (once the last frame is shown: `serviceFlip`).
    pub fn show(c: *Companion, keyboard: kete_panel.Picture, now: u64) !void {
        const r = &c.renderer;
        std.debug.assert(!r.flipPending());
        c.queued_ns = now;
        r.setPanelAt(.touchpad, c.panel.draw(c.width(), c.pad_height, now, View{}), 0, 0);
        r.setPanelAt(.keyboard, keyboard, 0, @intCast(c.pad_height));
        _ = try r.composite(&.{});
        _ = try r.show();
        c.dirty = false;
    }
};

/// The touchpad: an outline, and what it does.
const View = struct {
    pub fn build(_: *const View, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        return cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .radius = .all(24),
            .child = cx.make(kete.Align{ .alignment = .center, .child = cx.make(kete.Column{
                .fill = false,
                .cross_axis_alignment = .center,
                .spacing = 8,
                .children = cx.arena.dupe(kete.Widget, &.{
                    cx.make(kete.Text{ .text = "Touchpad", .style = .{ .size = 22, .color = t.on_surface } }),
                    cx.make(kete.Text{ .text = "Tap to click, two fingers to scroll", .style = .{ .size = 16, .color = t.on_surface_variant } }),
                    cx.make(kete.Text{ .text = "Tap with two fingers to right-click", .style = .{ .size = 16, .color = t.on_surface_variant } }),
                    cx.make(kete.Text{ .text = "Tap, then touch again and slide to drag", .style = .{ .size = 16, .color = t.on_surface_variant } }),
                }) catch &.{},
            }) }),
        }) });
    }
};

const testing = std.testing;

test "a finger moved moves the pointer; tapped, it clicks" {
    var p: Touchpad = .{};
    var out: Out = .{};
    p.down(1, 100, 100, 0, &out);
    p.motion(1, 103, 101.25, &out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual([2]i32{ 6, 2 }, out.events[0].motion);
    // The half pixel left over goes with the next.
    out = .{};
    p.motion(1, 103, 101.5, &out);
    try testing.expectEqual([2]i32{ 0, 1 }, out.events[0].motion);
    out = .{};
    p.up(1, 100 * std.time.ns_per_ms, &out);
    // It moved less than a tap may, and was let go soon: a click.
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u32, evdev.btn_left), out.events[0].button.code);

    // Moved further than a tap: no click.
    p = .{};
    out = .{};
    p.down(1, 100, 100, 0, &out);
    p.motion(1, 150, 100, &out);
    out = .{};
    p.up(1, 100 * std.time.ns_per_ms, &out);
    try testing.expectEqual(@as(usize, 0), out.len);

    // Held too long: no click.
    p.down(1, 100, 100, 0, &out);
    out = .{};
    p.up(1, 2 * Touchpad.tap_ns, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "tapped, then down again and moved: a drag" {
    var p: Touchpad = .{};
    var out: Out = .{};
    p.down(1, 100, 100, 0, &out);
    p.up(1, 100 * std.time.ns_per_ms, &out);
    try testing.expectEqual(@as(usize, 2), out.len);
    // Down again soon: the button held while it moves, let go with it.
    out = .{};
    p.down(1, 100, 100, 200 * std.time.ns_per_ms, &out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(out.events[0].button.pressed);
    out = .{};
    p.motion(1, 140, 100, &out);
    try testing.expectEqual([2]i32{ 80, 0 }, out.events[0].motion);
    out = .{};
    p.up(1, 900 * std.time.ns_per_ms, &out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(!out.events[0].button.pressed);
    // Down again later than that: no drag.
    out = .{};
    p.down(1, 100, 100, 2 * std.time.ns_per_s, &out);
    p.up(1, 2 * std.time.ns_per_s + 50 * std.time.ns_per_ms, &out);
    out = .{};
    p.down(1, 100, 100, 3 * std.time.ns_per_s, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "two fingers scroll, and tapped, right-click" {
    var p: Touchpad = .{};
    var out: Out = .{};
    p.down(1, 100, 100, 0, &out);
    p.down(2, 150, 100, 0, &out);
    p.motion(1, 100, 80, &out);
    try testing.expectEqual(@as(f64, 10), out.events[0].axis.value);
    p = .{};
    out = .{};
    p.down(1, 100, 100, 0, &out);
    p.down(2, 150, 100, 0, &out);
    p.up(1, 50 * std.time.ns_per_ms, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
    p.up(2, 60 * std.time.ns_per_ms, &out);
    try testing.expectEqual(@as(u32, evdev.btn_right), out.events[0].button.code);
}
