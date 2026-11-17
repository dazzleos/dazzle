//! A keyboard layout as the keys look: each key where it is on the
//! keyboard (ANSI's shape, or ISO's, with its key beside the left Shift and
//! its tall Enter, as the layout has them), with what it types: a letter's
//! capital, or what it types and, above, with Shift. Dead keys show their
//! accents. Always left to right, as the keyboard is.
//!
//! And choosing a keyboard, as Settings does: a field to search for it (by
//! its name or code), and those that match, one to choose.
//!
//!     cx.make(kete_vc4.KeyboardPicture{ .keyboard = .gb })

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const Keyboard = locale.Keyboard;

pub const KeyboardPicture = struct {
    keyboard: Keyboard,
    /// A key's width (and height), in pixels.
    unit: f32 = 26,

    /// A key: its Linux key code (0: one that types nothing, drawn
    /// blank), and how wide it is, in keys.
    const Slot = struct { code: u8, width: f32 = 1 };

    pub fn build(self: *const KeyboardPicture, cx: *kete.BuildContext) kete.Widget {
        const a = cx.arena;
        const iso = for (self.keyboard.keys()) |k| {
            if (k.code == 86) break true;
        } else false;
        // Each row is 15 keys wide.
        const rows = [_][]const Slot{
            &(numbers ++ [_]Slot{.{ .code = 0, .width = 2 }}),
            if (iso) &([_]Slot{.{ .code = 0, .width = 1.5 }} ++ top ++ [_]Slot{.{ .code = 0, .width = 1.5 }}) else &([_]Slot{.{ .code = 0, .width = 1.5 }} ++ top ++ [_]Slot{.{ .code = 43, .width = 1.5 }}),
            if (iso) &([_]Slot{.{ .code = 0, .width = 1.75 }} ++ home ++ [_]Slot{ .{ .code = 43 }, .{ .code = 0, .width = 1.25 } }) else &([_]Slot{.{ .code = 0, .width = 1.75 }} ++ home ++ [_]Slot{.{ .code = 0, .width = 2.25 }}),
            if (iso) &([_]Slot{ .{ .code = 0, .width = 1.25 }, .{ .code = 86 } } ++ bottom ++ [_]Slot{.{ .code = 0, .width = 2.75 }}) else &([_]Slot{.{ .code = 0, .width = 2.25 }} ++ bottom ++ [_]Slot{.{ .code = 0, .width = 2.75 }}),
            &[_]Slot{ .{ .code = 0, .width = 4 }, .{ .code = 57, .width = 7 }, .{ .code = 0, .width = 4 } },
        };
        const gap: f32 = 3;
        const out = a.alloc(kete.Widget, rows.len) catch return cx.make(kete.SizedBox.empty);
        for (rows, out) |row, *w| {
            const keys = a.alloc(kete.Widget, row.len) catch return cx.make(kete.SizedBox.empty);
            for (row, keys) |slot, *kw| kw.* = self.key(cx, slot, gap);
            w.* = cx.make(kete.Row{ .fill = false, .spacing = gap, .children = keys });
        }
        return cx.make(kete.LeftToRight{ .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = gap, .children = out }) });
    }

    const numbers = [_]Slot{.{ .code = 41 }} ++ codes(2, 12);
    const top = codes(16, 12);
    const home = codes(30, 11);
    const bottom = codes(44, 10);

    fn codes(comptime first: u8, comptime n: usize) [n]Slot {
        var out: [n]Slot = undefined;
        for (&out, 0..) |*s, i| s.* = .{ .code = first + i };
        return out;
    }

    fn key(self: *const KeyboardPicture, cx: *kete.BuildContext, slot: Slot, gap: f32) kete.Widget {
        const t = cx.theme();
        const u = self.unit;
        // As wide as its keys, with the gaps between them.
        const width = slot.width * u + (slot.width - 1) * gap;
        const found: ?locale.Key = for (self.keyboard.keys()) |k| {
            if (k.code == slot.code and slot.code != 57) break k;
        } else null;
        var label: kete.Widget = cx.make(kete.SizedBox.empty);
        if (found) |k| {
            const plain = shown(k.plain);
            const shifted = shown(k.shifted);
            label = if (k.capsLetter() or k.plain == k.shifted)
                cx.make(kete.Align.center(text(cx, shifted, u * 0.45, t.on_surface)))
            else
                cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .center, .children = cx.arena.dupe(kete.Widget, &.{
                    text(cx, shifted, u * 0.32, t.on_surface_variant),
                    text(cx, plain, u * 0.4, t.on_surface),
                }) catch &.{} });
        }
        return cx.make(kete.RoundedBox{
            .color = if (found != null) t.surface_container_highest else t.surface_container,
            .border_width = 1,
            .border_color = t.outline_variant,
            .radius = .all(u * 0.15),
            .child = cx.make(kete.SizedBox{ .width = width, .height = u, .child = label }),
        });
    }

    fn text(cx: *kete.BuildContext, c: u21, size: f32, color: kete.gfx.Color) kete.Widget {
        var buf: [8]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch 0;
        // A combining mark alone on a key: after a dotted circle, as such
        // marks are shown.
        const s = if (n > 0 and isMark(c)) cx.fmt("◌{s}", .{buf[0..n]}) else cx.arena.dupe(u8, buf[0..n]) catch "";
        return cx.make(kete.Text{ .text = s, .style = .{ .size = size, .color = color }, .wrap = false });
    }

    /// What a key's character shows as: a dead key's accent as it is
    /// written alone.
    fn shown(c: u21) u21 {
        return if (locale.isDead(c)) locale.spacing(c) else c;
    }

    fn isMark(c: u21) bool {
        return (c >= 0x064b and c <= 0x065f) or c == 0x0670;
    }
};

/// Choosing a keyboard: a search field, and the keyboards that match it.
pub const KeyboardPicker = struct {
    keyboard: Keyboard,
    /// Called with the keyboard chosen; without it, the choices are
    /// disabled.
    on_changed: ?kete.ValueCallback(Keyboard) = null,
    /// How tall the list is (it scrolls if they do not all fit).
    height: f32 = 220,

    pub const State = struct {
        query_buf: [64]u8 = undefined,
        query_len: u8 = 0,

        fn setQuery(st: *State, q: []const u8) void {
            st.query_len = @intCast(@min(q.len, st.query_buf.len));
            @memcpy(st.query_buf[0..st.query_len], q[0..st.query_len]);
        }

        fn query(st: *const State) []const u8 {
            return st.query_buf[0..st.query_len];
        }
    };

    pub fn build(self: *const KeyboardPicker, cx: *kete.BuildContext, st: *State) kete.Widget {
        const a = cx.arena;
        var rows: std.ArrayList(kete.Widget) = .empty;
        for (std.enums.values(Keyboard)) |k| {
            if (!matches(k, st.query())) continue;
            rows.append(a, cx.make(kete.RadioRow(Keyboard){ .value = k, .group_value = self.keyboard, .on_changed = self.on_changed, .label = k.name() })) catch {};
        }
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 8, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.TextField{ .placeholder = locale.text("Search"), .on_changed = .of(st, State.setQuery), .width = std.math.inf(f32) }),
            cx.make(kete.SizedBox{ .height = self.height, .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Column{
                .cross_axis_alignment = .start,
                .fill = false,
                .children = rows.items,
            }) }) }),
        }) catch &.{} });
    }

    /// Whether `k`'s name or code has `q` in it (in any case).
    pub fn matches(k: Keyboard, q: []const u8) bool {
        if (q.len == 0) return true;
        return std.ascii.findIgnoreCase(k.name(), q) != null or std.ascii.findIgnoreCase(k.code(), q) != null;
    }
};

const testing = std.testing;

test "keyboards found by their names and codes" {
    try testing.expect(KeyboardPicker.matches(.de, "qwertz"));
    try testing.expect(KeyboardPicker.matches(.fr, "AZERTY"));
    try testing.expect(KeyboardPicker.matches(.gb, "gb"));
    try testing.expect(!KeyboardPicker.matches(.us, "azerty"));
}
