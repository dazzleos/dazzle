//! Setup's first page: "Hello" in every language, before anyone has said
//! which one they speak. The words fade in, the most spoken first, spread
//! evenly (but not in a grid) over the whole screen, all the same size. Then
//! an outline fades in and out around each in turn, to show they can be
//! picked (there is no language yet to say so in).
//!
//! Picked, the other words fade away, the word moves to the top, and the
//! languages it is "hello" in are listed under it (all its places: English
//! in the United States, the United Kingdom and so on, the most spoken
//! first; and any other language with the same word). Picking one of them
//! is the language; the arrow under the list goes back to the words.
//!
//! Everything moves by the time since it started (or since a word was
//! picked, or the arrow pressed), so the page is made again each frame
//! while anything moves.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");

const Language = locale.Language;

/// A word, and the languages it is "hello" in, the most spoken first.
pub const Word = struct {
    text: []const u8,
    languages: []const Language,
};

/// The words, the most spoken first: each language's "hello", languages
/// sharing one together.
pub const words: []const Word = blk: {
    @setEvalBranchQuota(20000);
    var out: []const Word = &.{};
    for (Language.by_speakers) |l| {
        const seen = for (out) |w| {
            if (std.mem.eql(u8, w.text, l.hello())) break true;
        } else false;
        if (seen) continue;
        var langs: []const Language = &.{};
        for (Language.by_speakers) |m| if (std.mem.eql(u8, m.hello(), l.hello())) {
            langs = langs ++ .{m};
        };
        out = out ++ .{Word{ .text = l.hello(), .languages = langs }};
    }
    break :blk out;
};

pub const max_words = 32;

/// When things happen (ns).
const fade_in_after: u64 = 400 * std.time.ns_per_ms;
/// Between one word starting to fade in and the next.
const fade_in_step: u64 = 450 * std.time.ns_per_ms;
const fade_in_ns: u64 = 900 * std.time.ns_per_ms;
/// After the last word is in, the outline starts; each word's turn.
const hint_after: u64 = 600 * std.time.ns_per_ms;
const hint_turn_ns: u64 = 2400 * std.time.ns_per_ms;
/// A word picked moving to the top (and back), the others fading.
const move_ns: u64 = 600 * std.time.ns_per_ms;
/// The list fading in, after the word starts moving.
const list_after: u64 = 450 * std.time.ns_per_ms;
const list_fade_ns: u64 = 500 * std.time.ns_per_ms;

/// Where the word picked goes: near the top, in the middle.
const top: [2]f32 = .{ 0.5, 0.14 };

const word_size = 56;

pub const State = struct {
    /// Each word's place: across and down, 0 to 1.
    places: [max_words][2]f32 = undefined,
    /// When the words started fading in (null: not yet made).
    start_ns: ?u64 = null,
    /// The word picked, if one is.
    chosen: ?usize = null,
    /// The word last picked, going back to its place (after the arrow).
    returning: ?usize = null,
    /// When the last was picked, or the arrow pressed.
    changed_ns: u64 = 0,

    /// Places the words evenly (rows of three and two, by turns), each a
    /// little off its place, and which word is where shuffled.
    fn place(st: *State, seed: u64) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        const r = prng.random();
        const n = words.len;
        var spots: [max_words][2]f32 = undefined;
        var rows: [max_words]usize = undefined;
        var n_rows: usize = 0;
        var left = n;
        while (left > 0) : (n_rows += 1) {
            const want: usize = if (n_rows % 2 == 0) 3 else 2;
            rows[n_rows] = @min(want, left);
            left -= rows[n_rows];
        }
        var k: usize = 0;
        for (rows[0..n_rows], 0..) |count, row| {
            for (0..count) |i| {
                const across = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(count));
                const down = (@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(n_rows));
                // Within the middle of the screen, a little off.
                spots[k] = .{ 0.12 + 0.76 * across + (r.float(f32) - 0.5) * 0.06, 0.12 + 0.76 * down + (r.float(f32) - 0.5) * 0.06 };
                k += 1;
            }
        }
        r.shuffle([2]f32, spots[0..n]);
        @memcpy(st.places[0..n], spots[0..n]);
    }

    fn pick(st: *State, i: usize, now: u64) void {
        st.chosen = i;
        st.returning = null;
        st.changed_ns = now;
    }

    fn back(st: *State, now: u64) void {
        st.returning = st.chosen;
        st.chosen = null;
        st.changed_ns = now;
    }
};

/// The page, filling the window.
pub const Page = struct {
    state: *State,
    /// A language picked from the list.
    on_pick: ?kete.ValueCallback(Language) = null,

    pub fn build(self: *const Page, cx: *kete.BuildContext) kete.Widget {
        const st = self.state;
        const now = cx.now();
        const a = cx.arena;
        const t = cx.theme();
        if (st.start_ns == null) {
            st.start_ns = now;
            st.place(now);
        }
        const since = now -| st.start_ns.?;
        const since_change = now -| st.changed_ns;
        const moving = clamp01(ratio(since_change, move_ns));
        const eased = kete.Easing.outCubic.lerp(@as(f32, 0), 1, moving);
        const all_in = fade_in_after + fade_in_step * @as(u64, words.len) + fade_in_ns;
        var busy = since < all_in or since_change < move_ns + list_after + list_fade_ns;

        // The outline's turn: which word, and how strongly.
        var hint_word: ?usize = null;
        var hint_alpha: f32 = 0;
        const hint_from = fade_in_after + fade_in_step * @as(u64, words.len) + hint_after;
        if (st.chosen == null and st.returning == null and since >= hint_from) {
            const into = since - hint_from;
            hint_word = @intCast((into / hint_turn_ns) % @as(u64, words.len));
            const phase = ratio(into % hint_turn_ns, hint_turn_ns);
            hint_alpha = if (phase < 0.3) phase / 0.3 else if (phase < 0.65) 1 else if (phase < 0.95) (0.95 - phase) / 0.3 else 0;
            hint_alpha = kete.Easing.inOutSine.lerp(@as(f32, 0), 1, clamp01(hint_alpha));
            busy = true;
        }
        if (st.returning != null and since_change >= move_ns) st.returning = null;

        var layers: std.ArrayList(kete.Widget) = .empty;
        for (words, 0..) |w, i| {
            // Fading in, the most spoken first.
            var alpha = clamp01(ratio(since -| (fade_in_after + fade_in_step * @as(u64, i)), fade_in_ns));
            var at = st.places[i];
            if (st.chosen) |c| {
                if (c == i) at = lerp2(st.places[i], top, eased) else alpha *= 1 - moving;
            } else if (st.returning) |r| {
                if (r == i) at = lerp2(top, st.places[i], eased) else alpha *= moving;
            }
            if (alpha <= 0) continue;
            const outline = if (hint_word == i) hint_alpha else 0;
            var body = cx.make(kete.RoundedBox{
                .border_color = t.primary.withAlpha(outline),
                .border_width = 2,
                .radius = .all(word_size),
                .child = cx.make(kete.Padding{ .padding = .symmetric(28, 10), .child = cx.make(kete.Text{
                    .text = w.text,
                    .wrap = false,
                    .style = .{ .size = word_size, .color = t.on_surface.withAlpha(alpha) },
                }) }),
            });
            // Only the words showing can be picked.
            if (st.chosen == null) {
                const press = a.create(Press) catch continue;
                press.* = .{ .state = st, .word = i, .now = now };
                body = cx.make(kete.Pressable{ .on_press = .of(press, Press.press), .child = body });
            }
            layers.append(a, cx.make(At{ .x = at[0], .y = at[1], .child = body })) catch {};
        }

        // The languages the word picked is "hello" in, and the way back.
        if (st.chosen) |c| {
            const list_alpha = clamp01(ratio(since_change -| list_after, list_fade_ns));
            var rows: std.ArrayList(kete.Widget) = .empty;
            for (words[c].languages) |l| {
                const p = a.create(Pick) catch continue;
                p.* = .{ .page = self, .language = l };
                rows.append(a, cx.make(kete.Pressable{ .on_press = .of(p, Pick.pick), .child = cx.make(kete.SizedBox{
                    .width = 560,
                    .child = cx.make(kete.Padding{ .padding = .symmetric(0, 14), .child = cx.make(kete.Text{
                        .text = l.name(),
                        .text_align = .center,
                        .style = .{ .size = 26, .color = t.on_surface.withAlpha(list_alpha) },
                    }) }),
                }) })) catch {};
            }
            const back = a.create(Back) catch return cx.make(kete.Overlay{ .children = layers.items });
            back.* = .{ .state = st, .now = now };
            rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 16 }, .child = cx.make(kete.Pressable{ .on_press = .of(back, Back.back), .child = cx.make(kete.RoundedBox{
                .border_color = t.outline.withAlpha(list_alpha),
                .border_width = 1.5,
                .radius = .all(28),
                .child = cx.make(kete.SizedBox{ .width = 56, .height = 56, .child = cx.make(kete.Align{ .child = cx.make(kete.Icon{
                    .icon = .arrow_back,
                    .color = t.on_surface.withAlpha(list_alpha),
                }) }) }),
            }) }) })) catch {};
            // Below the word (where it stops).
            layers.append(a, cx.make(At{ .x = 0.5, .y = top[1], .top = word_size, .child = cx.make(kete.Column{
                .fill = false,
                .cross_axis_alignment = .center,
                .children = rows.items,
            }) })) catch {};
        }
        if (busy) cx.requestFrame();
        return cx.make(kete.RoundedBox{ .color = t.surface, .child = cx.make(kete.Overlay{ .children = layers.items }) });
    }
};

/// `child` with its middle at (`x`, `y`) of the area (0 to 1 across and
/// down), or (with `top`) its top that many pixels below `y`; kept on the
/// screen.
const At = struct {
    x: f32,
    y: f32,
    top: ?f32 = null,
    child: ?kete.Widget = null,

    pub fn layout(self: *const At, n: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        const size = c.biggest();
        if (n.childCount() == 0) return size;
        const s = n.child(0).layout(c.loosen());
        const x = size.w * self.x - s.w / 2;
        const y = if (self.top) |below| size.h * self.y + below else size.h * self.y - s.h / 2;
        n.child(0).place(std.math.clamp(x, 0, @max(size.w - s.w, 0)), std.math.clamp(y, 0, @max(size.h - s.h, 0)));
        return size;
    }

    pub fn minSize(_: *const At, n: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        return if (n.childCount() > 0) n.child(0).minSize(c.loosen()) else .{};
    }
};

const Press = struct {
    state: *State,
    word: usize,
    now: u64,

    fn press(p: *Press) void {
        p.state.pick(p.word, p.now);
    }
};

const Back = struct {
    state: *State,
    now: u64,

    fn back(b: *Back) void {
        b.state.back(b.now);
    }
};

const Pick = struct {
    page: *const Page,
    language: Language,

    fn pick(p: *Pick) void {
        if (p.page.on_pick) |f| f.call(p.language);
    }
};

fn ratio(n: u64, d: u64) f32 {
    return @floatCast(@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d)));
}

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

fn lerp2(from: [2]f32, to: [2]f32, k: f32) [2]f32 {
    return .{ from[0] + (to[0] - from[0]) * k, from[1] + (to[1] - from[1]) * k };
}

const testing = std.testing;

test "a word for each language, the most spoken first, with its places in order" {
    try testing.expectEqualStrings("Hello", words[0].text);
    try testing.expectEqual(@as(usize, 5), words[0].languages.len);
    try testing.expectEqual(Language.en_us, words[0].languages[0]);
    try testing.expectEqualStrings("你好", words[1].text);
    try testing.expectEqual(Language.es_mx, words[2].languages[0]);
    var n: usize = 0;
    for (words) |w| n += w.languages.len;
    try testing.expectEqual(Language.by_speakers.len, n);
    try testing.expect(words.len <= max_words);
}

test "words are placed apart, on the screen" {
    var st: State = .{};
    st.place(1234);
    for (st.places[0..words.len], 0..) |p, i| {
        try testing.expect(p[0] > 0.05 and p[0] < 0.95 and p[1] > 0.05 and p[1] < 0.95);
        for (st.places[0..i]) |q| {
            const dx = p[0] - q[0];
            const dy = p[1] - q[1];
            try testing.expect(dx * dx + dy * dy > 0.15 * 0.15);
        }
    }
}
