//! The on-screen keyboard: for touchscreens, along the bottom of the screen
//! while an app's text field has the keyboard (it enabled
//! `zwp_text_input_v3`) and it was last touched (`Osk.wanted`); typing on a
//! keyboard, or a mouse's button, hides it, as its own key and a swipe
//! down on it do (until another text field). It slides up from the
//! bottom, over the dock (which slides down out of its way), and back down
//! when hidden. The windows' work area stops above it.
//!
//! Its keys are kete buttons on its panel, given the shell's touches and
//! pointer. What they type the shell sends the app (`take`): letters and
//! the rest as the text input's text (the app puts it in, whatever its
//! keyboard's layout), Backspace, Enter and Tab as keys. Three pages: the
//! letters (with Shift, for one letter), the numbers and symbols, and
//! emoji (each one character).

const std = @import("std");
const kete = @import("kete");
const kete_panel = @import("kete_panel.zig");
const key_light = @import("kete_vc4").key_light;

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
    _ = &[_]kete.IconName{ .keyboard_capslock, .arrow_upward, .backspace, .space_bar, .keyboard_return, .keyboard_hide, .emoji_emotions };
}

/// Linux key codes it sends.
pub const key_backspace = 14;
pub const key_tab = 15;
pub const key_enter = 28;

const Page = enum { letters, symbols, emoji };

/// Slow at the start and the end (as the dock's slide).
fn easeInOut(t: f32) f32 {
    return if (t < 0.5) 2 * t * t else 1 - (-2 * t + 2) * (-2 * t + 2) / 2;
}

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
    /// Always shown (on the touchscreen beside a monitor): it has no key
    /// to hide it.
    always: bool = false,
    /// Each key's light (as setup's keyboard picture lights its keys):
    /// held, and let go, fading. By which key it is (`Key.What.id`).
    lights: [40]Light = @splat(.{}),

    /// How far up it is (0: off the screen, 1: all of it shown), and its
    /// way there (`slideTo`).
    slide: f32 = 0,
    slide_from: f32 = 0,
    slide_start: ?u64 = null,

    /// How long it takes to slide up or down (as the dock does).
    pub const slide_ns = 200 * std.time.ns_per_ms;

    const Light = struct { id: u32 = 0, key: key_light.Key = .{} };

    /// Key `id`'s light: its own, or one no key is lit by now.
    fn lightFor(o: *Osk, id: u32) *key_light.Key {
        for (&o.lights) |*l| if (l.id == id) return &l.key;
        var oldest = &o.lights[0];
        for (&o.lights) |*l| {
            if (l.id == 0) {
                oldest = l;
                break;
            }
            if (!l.key.interaction.pressed and l.key.let_go_ns < oldest.key.let_go_ns) oldest = l;
        }
        oldest.* = .{ .id = id };
        return &oldest.key;
    }

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

    /// Its top when all of it is shown (where the windows' work area
    /// ends).
    pub fn restTop(o: *const Osk) u32 {
        return o.screen_height -| o.height;
    }

    /// Its top now, as far up as it has slid.
    pub fn top(o: *const Osk) i32 {
        const up = easeInOut(o.slide) * @as(f32, @floatFromInt(o.height));
        return @as(i32, @intCast(o.screen_height)) - @as(i32, @intFromFloat(@round(up)));
    }

    /// Shows it (sliding up) or hides it (sliding down), from where it is,
    /// at `now`.
    pub fn slideTo(o: *Osk, show: bool, now: u64) void {
        o.shown = show;
        o.slide_from = o.slide;
        o.slide_start = now;
    }

    /// Moves it along its way, at `now`; returns whether it moved.
    pub fn animate(o: *Osk, now: u64) bool {
        const start = o.slide_start orelse return false;
        const k: f32 = @floatCast(@min(@as(f64, @floatFromInt(now -| start)) / slide_ns, 1));
        const to: f32 = if (o.shown) 1 else 0;
        o.slide = o.slide_from + (to - o.slide_from) * k;
        if (k >= 1) o.slide_start = null;
        return true;
    }

    /// Any of it on the screen.
    pub fn visible(o: *const Osk) bool {
        return o.shown or o.slide > 0;
    }

    /// Where (`x`, `y`) on the screen is in it (null: not on it), where
    /// it is now.
    pub fn local(o: *const Osk, x: f64, y: f64) ?[2]f32 {
        if (!o.shown) return null;
        const ly = y - @as(f64, @floatFromInt(o.top()));
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

    /// Whether a touch on it from `from` to `to` (in it) is a swipe down,
    /// which hides it: down by a key's height, more than across.
    pub fn swipedDown(o: *const Osk, from: [2]f32, to: [2]f32) bool {
        const dy = to[1] - from[1];
        const dx = @abs(to[0] - from[0]);
        return dy >= key_height * o.scale and dy > 2 * dx;
    }

    /// Whether a key has done something the shell is yet to deal with:
    /// typed (see `take`), or hidden it.
    pub fn pending(o: *const Osk) bool {
        return o.typed_len > 0 or (o.shown and o.dismissed);
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
    light: ?*key_light.Key = null,
    const What = union(enum) {
        text: []const u8,
        key: u32,
        shift,
        page,
        emoji,
        hide,

        /// Which key it is (never 0), whichever page it is on.
        fn id(w: What) u32 {
            return switch (w) {
                .text => |t| 0x1000_0000 | @as(u32, @truncate(std.hash.Wyhash.hash(0, t))) >> 4,
                .key => |code| 0x100 + code,
                .shift => 1,
                .page => 2,
                .hide => 3,
                .emoji => 4,
            };
        }
    };

    fn press(k: *Key) void {
        if (k.light) |l| l.pressed();
        const o = k.osk;
        switch (k.what) {
            .text => |t| o.typeText(t),
            .key => |code| o.push(.{ .key = code }),
            .shift => {
                o.shift = !o.shift;
                o.changed = true;
            },
            .emoji => {
                o.page = .emoji;
                o.shift = false;
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
/// Emoji, each one character (a key types up to four bytes).
const emoji_rows = [_][]const []const u8{
    &.{ "😀", "😂", "😊", "😍", "😘", "😉", "😎", "🤔", "😢", "😭" },
    &.{ "😅", "🙂", "🙃", "😴", "😡", "🥳", "🤗", "😮", "👍", "👎" },
    &.{ "👏", "🙏", "💪", "👋", "🎉", "🔥", "💯" },
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
        const rows = switch (o.page) {
            .letters => letter_rows,
            .symbols => symbol_rows,
            .emoji => emoji_rows,
        };
        var lines: std.ArrayList(kete.Widget) = .empty;
        for (rows, 0..) |row, i| {
            var keys: std.ArrayList(kete.Widget) = .empty;
            if (i == 1 and o.page == .letters) keys.append(a, spacer(cx, 0.5)) catch {};
            if (i == 2) keys.append(a, if (o.page == .letters)
                keyButton(cx, o, .shift, null, if (o.shift) .keyboard_capslock else .arrow_upward, 1.5, o.shift)
            else
                spacer(cx, 1.5)) catch {};
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
            if (o.page == .emoji) spacer(cx, 1) else keyButton(cx, o, .emoji, null, .emoji_emotions, 1, false),
            keyButton(cx, o, .{ .text = "," }, ",", null, 1, false),
            keyButton(cx, o, .{ .text = " " }, null, .space_bar, if (o.always) 4 else 3, false),
            keyButton(cx, o, .{ .text = "." }, ".", null, 1, false),
            keyButton(cx, o, .{ .key = key_enter }, null, .keyboard_return, 1.5, false),
        }) catch {};
        if (!o.always) last.append(a, keyButton(cx, o, .hide, null, .keyboard_hide, 1, false)) catch {};
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
    const light: ?*key_light.Key = o.lightFor(what.id());
    k.* = .{ .osk = o, .what = what, .light = light };
    const special = what != .text;
    const g = if (light) |l| l.glow(cx) else 0;
    const base = if (on) t.primary_container else if (special) t.surface_container_highest else t.surface;
    const face: kete.Widget = if (icon) |i|
        cx.make(kete.Icon{ .icon = i, .size = 26 * o.scale, .color = t.on_surface })
    else
        cx.make(kete.Text{ .text = label orelse "", .style = .{ .size = 24 * o.scale, .color = t.on_surface }, .wrap = false });
    return cx.make(kete.Expanded{ .flex = share, .child = cx.make(kete.Pressable{
        .on_press = .of(k, Key.press),
        .interaction = if (light) |l| &l.interaction else null,
        .child = cx.make(kete.RoundedBox{
            .color = key_light.face(t, base, g),
            .border_width = 1,
            .border_color = key_light.border(t, g),
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

test "slides up from the bottom of the screen, and back down" {
    var o: Osk = .{ .panel = undefined };
    o.setScreen(720, 1280, 1);
    try testing.expectEqual(@as(i32, 1280), o.top());
    try testing.expect(!o.visible());
    o.slideTo(true, 1000);
    try testing.expect(o.local(10, 1279) != null or o.top() == 1280);
    try testing.expect(o.animate(1000 + Osk.slide_ns / 2));
    try testing.expect(o.top() < 1280 and o.top() > @as(i32, @intCast(o.restTop())));
    try testing.expect(o.animate(1000 + Osk.slide_ns));
    try testing.expectEqual(@as(i32, @intCast(o.restTop())), o.top());
    try testing.expect(!o.animate(1000 + 2 * Osk.slide_ns));
    try testing.expect(o.local(10, @floatFromInt(o.restTop() + 1)) != null);
    o.slideTo(false, 5000);
    try testing.expect(o.visible());
    _ = o.animate(5000 + Osk.slide_ns);
    try testing.expect(!o.visible());
    try testing.expectEqual(@as(i32, 1280), o.top());
}

test "a swipe down hides it; a key pressed and wobbled does not" {
    var o: Osk = .{ .panel = undefined };
    o.setScreen(720, 1280, 1);
    try testing.expect(o.swipedDown(.{ 100, 20 }, .{ 110, 20 + Osk.key_height * o.scale }));
    try testing.expect(!o.swipedDown(.{ 100, 20 }, .{ 104, 26 }));
    try testing.expect(!o.swipedDown(.{ 100, 20 }, .{ 300, 90 }));
    try testing.expect(!o.swipedDown(.{ 100, 120 }, .{ 100, 20 }));
}
