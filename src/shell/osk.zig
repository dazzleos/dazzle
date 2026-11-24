//! The on-screen keyboard: for touchscreens, along the bottom of the screen
//! (above the dock) while an app's text field has the keyboard (it enabled
//! `zwp_text_input_v3`) and it was last touched (`Osk.wanted`); typing on a
//! keyboard, or a mouse's button, hides it, as its own key does (until
//! another text field). The windows' work area stops above it.
//!
//! Its keys are kete buttons on its panel, given the shell's touches and
//! pointer. What they type the shell sends the app (`take`): letters and
//! the rest as the text input's text (the app puts it in, whatever its
//! keyboard's layout), Backspace, Enter and Tab as keys. Two pages: the
//! letters (with Shift, for one letter), and the numbers and symbols.

const std = @import("std");
const kete = @import("kete");
const kete_panel = @import("kete_panel.zig");

/// What a key typed, for the shell to send the app.
pub const Typed = union(enum) {
    /// Text (a character, up to 4 bytes of UTF-8).
    text: struct { bytes: [4]u8, len: u3 },
    /// A key (a Linux key code), pressed and let go.
    key: u32,

    pub fn slice(t: *const Typed) []const u8 {
        return switch (t.*) {
            .text => |*x| x.bytes[0..x.len],
            .key => "",
        };
    }
};

// Its keys' icons, chosen as they are made (for kete's icon font, which
// has only those its scan finds).
comptime {
    _ = &[_]kete.IconName{ .keyboard_capslock, .arrow_upward, .backspace, .space_bar, .keyboard_return, .keyboard_hide };
}

/// Linux key codes it sends.
pub const key_backspace = 14;
pub const key_tab = 15;
pub const key_enter = 28;

const Page = enum { letters, symbols };

pub const Osk = struct {
    panel: *kete_panel.Panel,
    /// Shown now (the shell shows its panel, and keeps windows above it).
    shown: bool = false,
    /// Hidden by its own key: until another text field has the keyboard.
    dismissed: bool = false,
    shift: bool = false,
    page: Page = .letters,
    /// Its size (the screen's width), and the screen's.
    width: u32 = 0,
    height: u32 = 0,
    screen_height: u32 = 0,
    scale: f32 = 1,
    /// What was typed since `take`.
    typed: [32]Typed = undefined,
    typed_len: usize = 0,
    /// It changed (a page, Shift), and is to be drawn again.
    changed: bool = true,

    pub fn init(panel: *kete_panel.Panel, screen_width: u32, screen_height: u32, scale: f32) Osk {
        var o: Osk = .{ .panel = panel };
        o.setScreen(screen_width, screen_height, scale);
        return o;
    }

    /// Key rows' height at 1080p (a fingertip at scale 1), and the gaps.
    const key_height = 56;
    const gap = 6;
    const pad = 8;

    /// Sized for a screen `w` by `h`, at `scale` (the dock's): as wide as
    /// the screen, its keys as tall as the dock's icons, but no more than
    /// a third of the screen in all.
    pub fn setScreen(o: *Osk, w: u32, h: u32, scale: f32) void {
        o.width = w;
        o.screen_height = h;
        const natural = (4 * key_height + 3 * gap + 2 * pad) * scale;
        const most: f32 = @as(f32, @floatFromInt(h)) / 3;
        o.scale = if (natural > most) scale * most / natural else scale;
        o.height = @intFromFloat(@round((4 * key_height + 3 * gap + 2 * pad) * o.scale));
        o.changed = true;
    }

    /// Its top, with its bottom at `bottom` (the dock's band's top).
    pub fn top(o: *const Osk, bottom: u32) i32 {
        return @as(i32, @intCast(bottom)) - @as(i32, @intCast(o.height));
    }

    /// Where (`x`, `y`) on the screen is in it (null: not on it), its top
    /// at `at_y`.
    pub fn local(o: *const Osk, x: f64, y: f64, at_y: i32) ?[2]f32 {
        if (!o.shown) return null;
        const ly = y - @as(f64, @floatFromInt(at_y));
        if (x < 0 or ly < 0 or x >= @as(f64, @floatFromInt(o.width)) or ly >= @as(f64, @floatFromInt(o.height))) return null;
        return .{ @floatCast(x), @floatCast(ly) };
    }

    /// Its picture, in `theme`'s colours.
    pub fn draw(o: *Osk, now_ns: u64) kete_panel.Picture {
        o.changed = false;
        return o.panel.draw(o.width, o.height, now_ns, View{ .osk = o });
    }

    /// Whether it wants drawing again.
    pub fn needsDraw(o: *const Osk) bool {
        return o.changed or o.panel.needsFrame();
    }

    /// What was typed since the last call.
    pub fn take(o: *Osk) []const Typed {
        const n = o.typed_len;
        o.typed_len = 0;
        return o.typed[0..n];
    }

    fn push(o: *Osk, t: Typed) void {
        if (o.typed_len < o.typed.len) {
            o.typed[o.typed_len] = t;
            o.typed_len += 1;
        }
    }

    /// A key's character typed (Shift, once, makes a letter a capital).
    fn typeText(o: *Osk, text: []const u8) void {
        var t: Typed = .{ .text = .{ .bytes = undefined, .len = @intCast(@min(text.len, 4)) } };
        @memcpy(t.text.bytes[0..t.text.len], text[0..t.text.len]);
        if (o.shift and t.text.len == 1 and std.ascii.isLower(t.text.bytes[0])) t.text.bytes[0] = std.ascii.toUpper(t.text.bytes[0]);
        if (o.shift) {
            o.shift = false;
            o.changed = true;
        }
        o.push(t);
    }
};

/// A key: what it is, and what pressing it does.
const Key = struct {
    osk: *Osk,
    what: What,
    const What = union(enum) {
        text: []const u8,
        key: u32,
        shift,
        page,
        hide,
    };

    fn press(k: *Key) void {
        const o = k.osk;
        switch (k.what) {
            .text => |t| o.typeText(t),
            .key => |code| o.push(.{ .key = code }),
            .shift => {
                o.shift = !o.shift;
                o.changed = true;
            },
            .page => {
                o.page = if (o.page == .letters) .symbols else .letters;
                o.shift = false;
                o.changed = true;
            },
            .hide => {
                o.dismissed = true;
                o.changed = true;
            },
        }
    }
};

const letter_rows = [_][]const []const u8{
    &.{ "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" },
    &.{ "a", "s", "d", "f", "g", "h", "j", "k", "l" },
    &.{ "z", "x", "c", "v", "b", "n", "m" },
};
const symbol_rows = [_][]const []const u8{
    &.{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
    &.{ "@", "#", "$", "%", "&", "-", "+", "(", ")", "/" },
    &.{ "*", "\"", "'", ":", ";", "!", "?" },
};

/// The keyboard: three rows of characters (the last between Shift, or the
/// page's key, and Backspace), and a row of the page's key, a comma, Space,
/// a full stop, Enter and Hide. Each key's width a share of the row's.
const View = struct {
    osk: *Osk,

    pub fn build(self: *const View, cx: *kete.BuildContext) kete.Widget {
        const o = self.osk;
        const t = cx.theme();
        const a = cx.arena;
        const s = o.scale;
        const rows = if (o.page == .letters) letter_rows else symbol_rows;
        var lines: std.ArrayList(kete.Widget) = .empty;
        for (rows, 0..) |row, i| {
            var keys: std.ArrayList(kete.Widget) = .empty;
            if (i == 1 and o.page == .letters) keys.append(a, spacer(cx, 0.5)) catch {};
            if (i == 2) keys.append(a, if (o.page == .letters)
                keyButton(cx, o, .shift, null, if (o.shift) .keyboard_capslock else .arrow_upward, 1.5, o.shift)
            else
                keyButton(cx, o, .page, "ABC", null, 1.5, false)) catch {};
            for (row) |ch| {
                const shown = if (o.page == .letters and o.shift) upper(cx, ch) else ch;
                keys.append(a, keyButton(cx, o, .{ .text = ch }, shown, null, 1, false)) catch {};
            }
            if (i == 1 and o.page == .letters) keys.append(a, spacer(cx, 0.5)) catch {};
            if (i == 2) keys.append(a, keyButton(cx, o, .{ .key = key_backspace }, null, .backspace, 1.5, false)) catch {};
            lines.append(a, row_of(cx, keys.items, s)) catch {};
        }
        var last: std.ArrayList(kete.Widget) = .empty;
        last.appendSlice(a, &.{
            keyButton(cx, o, .page, if (o.page == .letters) "?123" else "ABC", null, 1.5, false),
            keyButton(cx, o, .{ .text = "," }, ",", null, 1, false),
            keyButton(cx, o, .{ .text = " " }, null, .space_bar, 4, false),
            keyButton(cx, o, .{ .text = "." }, ".", null, 1, false),
            keyButton(cx, o, .{ .key = key_enter }, null, .keyboard_return, 1.5, false),
            keyButton(cx, o, .hide, null, .keyboard_hide, 1, false),
        }) catch {};
        lines.append(a, row_of(cx, last.items, s)) catch {};
        return cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .child = cx.make(kete.Padding{ .padding = .all(Osk.pad * s), .child = cx.make(kete.Column{
                .cross_axis_alignment = .stretch,
                .spacing = Osk.gap * s,
                .children = lines.items,
            }) }),
        });
    }
};

fn row_of(cx: *kete.BuildContext, keys: []const kete.Widget, s: f32) kete.Widget {
    return cx.make(kete.SizedBox{ .height = Osk.key_height * s, .child = cx.make(kete.Row{
        .cross_axis_alignment = .stretch,
        .spacing = Osk.gap * s,
        .children = cx.arena.dupe(kete.Widget, keys) catch &.{},
    }) });
}

fn spacer(cx: *kete.BuildContext, share: f32) kete.Widget {
    return cx.make(kete.Expanded{ .flex = share, .child = cx.make(kete.SizedBox.empty) });
}

fn upper(cx: *kete.BuildContext, ch: []const u8) []const u8 {
    if (ch.len != 1 or !std.ascii.isLower(ch[0])) return ch;
    const out = cx.arena.alloc(u8, 1) catch return ch;
    out[0] = std.ascii.toUpper(ch[0]);
    return out;
}

/// A key `share` of a row's width (a letter's is 1), showing `label` or
/// `icon`; `on` for Shift while it holds.
fn keyButton(cx: *kete.BuildContext, o: *Osk, what: Key.What, label: ?[]const u8, icon: ?kete.IconName, share: f32, on: bool) kete.Widget {
    const t = cx.theme();
    const k = cx.arena.create(Key) catch return spacer(cx, share);
    k.* = .{ .osk = o, .what = what };
    const special = what != .text;
    const face: kete.Widget = if (icon) |i|
        cx.make(kete.Icon{ .icon = i, .size = 26 * o.scale, .color = t.on_surface })
    else
        cx.make(kete.Text{ .text = label orelse "", .style = .{ .size = 24 * o.scale, .color = t.on_surface }, .wrap = false });
    return cx.make(kete.Expanded{ .flex = share, .child = cx.make(kete.Pressable{
        .on_press = .of(k, Key.press),
        .child = cx.make(kete.RoundedBox{
            .color = if (on) t.primary_container else if (special) t.surface_container_highest else t.surface,
            .radius = .all(8 * o.scale),
            .child = cx.make(kete.Align{ .child = face }),
        }),
    }) });
}

const testing = std.testing;

test "keys type text (Shift for one capital), Backspace and Enter as keys, and Hide dismisses it" {
    var o: Osk = .{ .panel = undefined };
    var q: Key = .{ .osk = &o, .what = .{ .text = "q" } };
    var shift: Key = .{ .osk = &o, .what = .shift };
    var back: Key = .{ .osk = &o, .what = .{ .key = key_backspace } };
    var hide: Key = .{ .osk = &o, .what = .hide };
    shift.press();
    q.press();
    q.press();
    back.press();
    const typed = o.take();
    try testing.expectEqual(@as(usize, 3), typed.len);
    try testing.expectEqualStrings("Q", typed[0].slice());
    try testing.expectEqualStrings("q", typed[1].slice());
    try testing.expectEqual(@as(u32, key_backspace), typed[2].key);
    try testing.expectEqual(@as(usize, 0), o.take().len);
    hide.press();
    try testing.expect(o.dismissed);
}

test "sized as tall as the dock's icons, but no more than a third of the screen" {
    var o: Osk = .{ .panel = undefined };
    o.setScreen(1920, 1080, 1);
    try testing.expectEqual(@as(u32, 1920), o.width);
    try testing.expectEqual(@as(u32, 4 * 56 + 3 * 6 + 2 * 8), o.height);
    o.setScreen(1280, 720, 1);
    try testing.expectEqual(@as(u32, 240), o.height);
}
