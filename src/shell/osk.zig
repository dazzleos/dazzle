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
//! keyboard's layout), Backspace, Enter and Tab as keys. Its pages are as
//! Android's keyboards have them: the letters (with Shift, for one letter);
//! the numbers and symbols, and more symbols (=\< where Shift is: every
//! ASCII one between them); and emoji, found by typing their names (the
//! letters, without spaces, beside a few large emoji the name finds; with none typed,
//! those used most), in a skin tone (see emoji.zig).

const std = @import("std");
const kete = @import("kete");
const kete_panel = @import("kete_panel.zig");
const key_light = @import("kete_vc4").key_light;
const emoji_mod = @import("emoji.zig");

/// What a key typed, for the shell to send the app.
pub const Typed = union(enum) {
    /// Text (a character, or an emoji: up to `emoji_mod.max_text` bytes of
    /// UTF-8).
    text: struct { bytes: [emoji_mod.max_text]u8, len: u8 },
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

const Page = enum { letters, symbols, more_symbols, emoji };

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
    /// (Room for every key of every page: none shares one. The emoji's
    /// are by where they are on the page.)
    lights: [200]Light = @splat(.{}),
    /// The emoji page's (and where it keeps those used, and the tone:
    /// none in tests).
    emoji: emoji_mod.Emoji = .{},
    emoji_file: ?[:0]const u8 = null,

    /// How far up it is (0: off the screen, 1: all of it shown), and its
    /// way there (`slideTo`).
    slide: f32 = 0,
    slide_from: f32 = 0,
    slide_start: ?u64 = null,

    /// How long it takes to slide up or down (as the dock does).
    pub const slide_ns = 200 * std.time.ns_per_ms;

    const Light = struct { id: u32 = 0, key: key_light.Key = .{} };

    /// Key `id`'s light: its own, kept for it from when it is first made
    /// (null if there is no room: it is not lit).
    fn lightFor(o: *Osk, id: u32) ?*key_light.Key {
        for (&o.lights) |*l| {
            if (l.id == id) return &l.key;
            if (l.id == 0) {
                l.* = .{ .id = id };
                return &l.key;
            }
        }
        return null;
    }

    pub fn init(panel: *kete_panel.Panel, screen_width: u32, screen_height: u32, scale: f32) Osk {
        var o: Osk = .{ .panel = panel, .emoji = .load(emoji_mod.file), .emoji_file = emoji_mod.file };
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

    /// The emoji's keys' lights: let go, for the page's new emoji.
    fn unlightEmoji(o: *Osk) void {
        for (&o.lights) |*l| if (l.id >= emoji_light and l.id < emoji_light + emoji_mod.shown_max) {
            l.key = .{};
        };
    }

    fn saveEmoji(o: *const Osk) void {
        if (o.emoji_file) |path| o.emoji.save(path);
    }

    /// A key's character typed (Shift, once, makes a letter a capital).
    fn typeText(o: *Osk, text: []const u8) void {
        var t: Typed = .{ .text = .{ .bytes = undefined, .len = @intCast(@min(text.len, emoji_mod.max_text)) } };
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
        /// To that page.
        page: Page,
        hide,
        /// An emoji, at `slot` on the emoji page.
        emoji: struct { text: []const u8, slot: u8 },
        /// The skin tones, to choose one.
        tones,
        tone: u3,

        /// Which key it is (never 0), whichever page it is on.
        fn id(w: What) u32 {
            return switch (w) {
                .text => |t| 0x1000_0000 | @as(u32, @truncate(std.hash.Wyhash.hash(0, t))) >> 4,
                .key => |code| 0x100 + code,
                .shift => 1,
                .hide => 3,
                .page => |pg| 0x10 + @as(u32, @intFromEnum(pg)),
                .emoji => |em| emoji_light + em.slot,
                .tones => 0x32,
                .tone => |v| 0x40 + @as(u32, v),
            };
        }
    };

    fn press(k: *Key) void {
        if (k.light) |l| l.pressed();
        const o = k.osk;
        switch (k.what) {
            // On the emoji page, letters (and Space) type an emoji's name,
            // and Backspace takes them away (then the app's text).
            .text => |t| if (o.page == .emoji) {
                o.emoji.add(t);
                o.unlightEmoji();
                o.changed = true;
            } else o.typeText(t),
            .key => |code| if (o.page == .emoji and code == key_backspace and o.emoji.erase()) {
                o.unlightEmoji();
                o.changed = true;
            } else o.push(.{ .key = code }),
            .shift => {
                o.shift = !o.shift;
                o.changed = true;
            },
            .page => |pg| {
                o.page = pg;
                o.shift = false;
                o.changed = true;
                o.emoji.clear();
                o.unlightEmoji();
            },
            // Typed: the name is done with.
            .emoji => |em| {
                o.typeText(em.text);
                o.emoji.typed(em.text);
                o.saveEmoji();
                o.emoji.clear();
                o.changed = true;
            },
            .tones => {
                o.emoji.choosing_tone = !o.emoji.choosing_tone;
                o.changed = true;
            },
            .tone => |v| {
                o.emoji.tone = v;
                o.emoji.choosing_tone = false;
                o.saveEmoji();
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
/// The emoji keys' lights' ids, by their place on the page.
const emoji_light: u32 = 0x1000;

/// The skin tones, on a hand.
const tone_faces = [_][]const u8{ "✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿" };

const symbol_rows = [_][]const []const u8{
    &.{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
    &.{ "@", "#", "$", "_", "&", "-", "+", "(", ")", "/" },
    &.{ "*", "\"", "'", ":", ";", "!", "?" },
};
const more_symbol_rows = [_][]const []const u8{
    &.{ "~", "`", "|", "\\", "^", "{", "}", "[", "]", "%" },
    &.{ "<", ">", "=", "€", "£", "¥", "°", "•", "×", "÷" },
    &.{ "©", "®", "™", "§", "¶", "¢", "…" },
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
            .more_symbols => more_symbol_rows,
            .emoji => return emojiView(cx, o),
        };
        var lines: std.ArrayList(kete.Widget) = .empty;
        for (rows, 0..) |row, i| {
            var keys: std.ArrayList(kete.Widget) = .empty;
            if (i == 1 and o.page == .letters) keys.append(a, spacer(cx, 0.5)) catch {};
            // Where Shift is: the other page of symbols.
            if (i == 2) keys.append(a, switch (o.page) {
                .letters => keyButton(cx, o, .shift, null, if (o.shift) .keyboard_capslock else .arrow_upward, 1.5, o.shift),
                .symbols => keyButton(cx, o, .{ .page = .more_symbols }, "=\\<", null, 1.5, false),
                .more_symbols => keyButton(cx, o, .{ .page = .symbols }, "?123", null, 1.5, false),
                .emoji => spacer(cx, 1.5),
            }) catch {};
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
            if (o.page == .letters) keyButton(cx, o, .{ .page = .symbols }, "?123", null, 1.5, false) else keyButton(cx, o, .{ .page = .letters }, "ABC", null, 1.5, false),
            if (o.page == .emoji) spacer(cx, 1) else keyButton(cx, o, .{ .page = .emoji }, null, .emoji_emotions, 1, false),
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

/// The emoji page: on the left, the letters to type an emoji's name
/// (with the skin tones' key where Shift is, and Backspace), and Space;
/// on the right, the name typed, and the emoji it finds, large (with none
/// typed, those used most), or the tones to choose one from.
fn emojiView(cx: *kete.BuildContext, o: *Osk) kete.Widget {
    const t = cx.theme();
    const a = cx.arena;
    const s = o.scale;
    const e = &o.emoji;
    const k: f32 = Osk.key_height * s;
    const g: f32 = Osk.gap * s;

    var left: std.ArrayList(kete.Widget) = .empty;
    for (letter_rows, 0..) |row, i| {
        var keys: std.ArrayList(kete.Widget) = .empty;
        if (i == 1) keys.append(a, spacer(cx, 0.5)) catch {};
        if (i == 2) keys.append(a, keyButton(cx, o, .tones, tone_faces[e.tone], null, 1.5, e.choosing_tone)) catch {};
        for (row) |ch| keys.append(a, keyButton(cx, o, .{ .text = ch }, ch, null, 1, false)) catch {};
        if (i == 1) keys.append(a, spacer(cx, 0.5)) catch {};
        if (i == 2) keys.append(a, keyButton(cx, o, .{ .key = key_backspace }, null, .backspace, 1.5, false)) catch {};
        left.append(a, rowHeight(cx, keys.items, k, g)) catch {};
    }
    var last: std.ArrayList(kete.Widget) = .empty;
    // (No Space: names are matched without theirs.)
    last.append(a, keyButton(cx, o, .{ .page = .letters }, "ABC", null, 1, false)) catch {};
    if (!o.always) last.append(a, keyButton(cx, o, .hide, null, .keyboard_hide, 1.5, false)) catch {};
    left.append(a, rowHeight(cx, last.items, k, g)) catch {};

    // The name typed (or what to do), as a field shows it.
    const q = e.query();
    const name = cx.make(kete.SizedBox{ .height = k, .child = cx.make(kete.RoundedBox{
        .color = t.surface,
        .border_width = 1,
        .border_color = t.outline_variant,
        .radius = .all(8 * s),
        .child = cx.make(kete.Padding{ .padding = .symmetric(12 * s, 0), .child = cx.make(kete.Align{ .alignment = .center_left, .child = cx.make(kete.Text{
            .text = if (q.len > 0) q else if (e.choosing_tone) "Choose a skin tone" else "Type an emoji's name",
            .style = .{ .size = 20 * s, .color = if (q.len > 0) t.on_surface else t.on_surface_variant },
            .wrap = false,
            .ellipsis = true,
        }) }) }),
    }) });
    // Two rows of four, as tall as the keys' other three rows.
    const big_h = (3 * k + g) / 2;
    var grid: std.ArrayList(kete.Widget) = .empty;
    var faces: [emoji_mod.shown_max][]const u8 = undefined;
    var n: usize = 0;
    if (e.choosing_tone) {
        for (tone_faces, 0..) |face, v| faces[v] = face;
        n = tone_faces.len;
    } else n = e.shown(&faces);
    for (0..2) |r| {
        var keys: std.ArrayList(kete.Widget) = .empty;
        for (0..4) |c| {
            const i = r * 4 + c;
            keys.append(a, if (i >= n)
                spacer(cx, 1)
            else if (e.choosing_tone)
                bigKey(cx, o, .{ .tone = @intCast(i) }, faces[i], e.tone == i)
            else
                bigKey(cx, o, .{ .emoji = .{ .text = faces[i], .slot = @intCast(i) } }, faces[i], false)) catch {};
        }
        grid.append(a, rowHeight(cx, keys.items, big_h, g)) catch {};
    }
    var right: std.ArrayList(kete.Widget) = .empty;
    right.append(a, name) catch {};
    right.appendSlice(a, grid.items) catch {};

    return cx.make(kete.RoundedBox{
        .color = t.surface_container,
        .child = cx.make(kete.Padding{ .padding = .all(Osk.pad * s), .child = cx.make(kete.Row{
            .cross_axis_alignment = .stretch,
            .spacing = 2 * g,
            .children = cx.makeAll(.{
                kete.Expanded{ .flex = 10, .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .spacing = g, .children = left.items }) },
                kete.Expanded{ .flex = 5, .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .spacing = g, .children = right.items }) },
            }),
        }) }),
    });
}

/// A key on the emoji page's right: an emoji (or a tone), large.
fn bigKey(cx: *kete.BuildContext, o: *Osk, what: Key.What, face: []const u8, on: bool) kete.Widget {
    return keySized(cx, o, what, face, null, 1, on, 44 * o.scale);
}

/// A row of keys `height` high, `gap` apart.
fn rowHeight(cx: *kete.BuildContext, keys: []const kete.Widget, height: f32, gap: f32) kete.Widget {
    return cx.make(kete.SizedBox{ .height = height, .child = cx.make(kete.Row{
        .cross_axis_alignment = .stretch,
        .spacing = gap,
        .children = cx.arena.dupe(kete.Widget, keys) catch &.{},
    }) });
}

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
    return keySized(cx, o, what, label, icon, share, on, 24 * o.scale);
}

/// A key, its label `size` high.
fn keySized(cx: *kete.BuildContext, o: *Osk, what: Key.What, label: ?[]const u8, icon: ?kete.IconName, share: f32, on: bool, size: f32) kete.Widget {
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
        cx.make(kete.Text{ .text = label orelse "", .style = .{ .size = size, .color = t.on_surface }, .wrap = false });
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

test "each key its own light, on every page" {
    var o: Osk = .{ .panel = undefined };
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(testing.allocator);
    for ([_][]const []const []const u8{ &letter_rows, &symbol_rows, &more_symbol_rows }) |rows| for (rows) |row| for (row) |ch| {
        const id = (Key.What{ .text = ch }).id();
        try testing.expect(std.mem.indexOfScalar(u32, ids.items, id) == null);
        try ids.append(testing.allocator, id);
        try testing.expect(o.lightFor(id) != null);
    };
    // The same key, the same light; others, others.
    try testing.expectEqual(o.lightFor((Key.What{ .text = "q" }).id()), o.lightFor((Key.What{ .text = "q" }).id()));
    try testing.expect(o.lightFor((Key.What{ .text = "q" }).id()) != o.lightFor((Key.What{ .text = "*" }).id()));
}

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
