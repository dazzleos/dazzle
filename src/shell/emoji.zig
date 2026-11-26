//! The on-screen keyboard's emoji: found by name, as it is typed (every
//! emoji there is: emoji_table.zig, from Unicode's), a few at a time,
//! large; with nothing typed, those used most. A skin tone, for those that
//! have them. Those used, and the tone, are kept in `file`.

const std = @import("std");
const sys = @import("sys");
const table = @import("emoji_table.zig");

/// The most emoji shown at once.
pub const shown_max = 8;

/// Where those used most, and the tone, are kept.
pub const file = sys.system.apps_dir ++ "/.emoji";

/// How many used are remembered (the most used shown).
const kept = 60;

/// The longest emoji text (a family, a kiss, with tones: some thirty
/// bytes).
pub const max_text = 40;

/// The longest name typed.
pub const max_query = 32;

const Used = struct {
    text: [max_text]u8 = undefined,
    len: u8 = 0,
    count: u32 = 0,
    /// When it was last used (a count of uses of any).
    last: u32 = 0,

    fn slice(u: *const Used) []const u8 {
        return u.text[0..u.len];
    }
};

pub const Emoji = struct {
    /// The skin tone (0: none, the yellow; 1 to 5: light to dark).
    tone: u3 = 0,
    /// The tones being chosen from (in place of the emoji).
    choosing_tone: bool = false,
    /// The name typed so far.
    query_buf: [max_query]u8 = undefined,
    query_len: u8 = 0,
    used: [kept]Used = undefined,
    used_len: usize = 0,
    clock: u32 = 0,

    pub fn query(e: *const Emoji) []const u8 {
        return e.query_buf[0..e.query_len];
    }

    /// `text` typed onto the name (in small letters).
    pub fn add(e: *Emoji, text: []const u8) void {
        for (text) |c| {
            if (e.query_len == max_query) return;
            // Not a space first.
            if (c == ' ' and e.query_len == 0) continue;
            e.query_buf[e.query_len] = std.ascii.toLower(c);
            e.query_len += 1;
        }
    }

    /// The name's last letter taken away; false if there was none.
    pub fn erase(e: *Emoji) bool {
        if (e.query_len == 0) return false;
        e.query_len -= 1;
        return true;
    }

    pub fn clear(e: *Emoji) void {
        e.query_len = 0;
        e.choosing_tone = false;
    }

    /// `em` in the tone chosen, if it has tones.
    pub fn toned(e: *const Emoji, em: *const table.Emoji) []const u8 {
        if (e.tone == 0) return em.text;
        const tones = em.tones orelse return em.text;
        return tones[e.tone - 1];
    }

    /// The emoji to show (as they type), in `out`; returns how many: those
    /// the name finds, or with none typed, those used most.
    pub fn shown(e: *const Emoji, out: *[shown_max][]const u8) usize {
        if (e.query_len == 0) {
            var order: [kept]*const Used = undefined;
            for (e.used[0..e.used_len], 0..) |*u, i| order[i] = u;
            std.mem.sort(*const Used, order[0..e.used_len], {}, moreUsed);
            const n = @min(e.used_len, shown_max);
            for (order[0..n], 0..) |u, i| out[i] = u.slice();
            return n;
        }
        var found: [shown_max]*const table.Emoji = undefined;
        const n = search(std.mem.trimEnd(u8, e.query(), " "), &found);
        for (found[0..n], 0..) |em, i| out[i] = e.toned(em);
        return n;
    }

    fn moreUsed(_: void, a: *const Used, b: *const Used) bool {
        if (a.count != b.count) return a.count > b.count;
        return a.last > b.last;
    }

    /// `text` was typed: used once more (the least used, longest ago,
    /// forgotten for it if there is no room).
    pub fn typed(e: *Emoji, text: []const u8) void {
        if (text.len == 0 or text.len > max_text) return;
        e.clock +%= 1;
        for (e.used[0..e.used_len]) |*u| if (std.mem.eql(u8, u.slice(), text)) {
            u.count +|= 1;
            u.last = e.clock;
            return;
        };
        var slot: *Used = undefined;
        if (e.used_len < kept) {
            slot = &e.used[e.used_len];
            e.used_len += 1;
        } else {
            slot = &e.used[0];
            for (e.used[1..]) |*u| if (moreUsed({}, slot, u)) {
                slot = u;
            };
        }
        slot.* = .{ .len = @intCast(text.len), .count = 1, .last = e.clock };
        @memcpy(slot.text[0..text.len], text);
    }

    /// The tone and those used, as `file` keeps them: "tone 3", then a
    /// line each: its uses, when last used, and it.
    pub fn format(e: *const Emoji, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print("tone {d}\n", .{e.tone}) catch return "";
        for (e.used[0..e.used_len]) |*u| w.print("{d} {d} {s}\n", .{ u.count, u.last, u.slice() }) catch break;
        return w.buffered();
    }

    pub fn parse(text: []const u8) Emoji {
        var e: Emoji = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const first = f.next() orelse continue;
            if (std.mem.eql(u8, first, "tone")) {
                const v = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
                e.tone = if (v <= 5) @intCast(v) else 0;
                continue;
            }
            const count = std.fmt.parseInt(u32, first, 10) catch continue;
            const last = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            const t = f.rest();
            if (t.len == 0 or t.len > max_text or e.used_len == kept) continue;
            // Only one there is (as the font draws), in any tone.
            if (!known(t)) continue;
            const u = &e.used[e.used_len];
            u.* = .{ .len = @intCast(t.len), .count = count, .last = last };
            @memcpy(u.text[0..t.len], t);
            e.used_len += 1;
            e.clock = @max(e.clock, last);
        }
        return e;
    }

    fn known(text: []const u8) bool {
        for (&table.all) |*em| {
            if (std.mem.eql(u8, em.text, text)) return true;
            if (em.tones) |tones| for (tones) |t| if (std.mem.eql(u8, t, text)) return true;
        }
        return false;
    }

    pub const max_file = 16 + kept * (2 * 11 + max_text + 3);

    pub fn load(path: [:0]const u8) Emoji {
        var buf: [max_file]u8 = undefined;
        return parse(sys.readFile(path, &buf) orelse return .{});
    }

    pub fn save(e: *const Emoji, path: [:0]const u8) void {
        var buf: [max_file]u8 = undefined;
        const text = e.format(&buf);
        if (text.len == 0) return;
        _ = std.os.linux.unlink(path);
        sys.files.writeNew(path, text) catch {};
    }
};

/// Up to `out.len` emoji whose names `q` finds, best first: a name it is,
/// then a name starting with it, a word of a name starting with it, and
/// (for three letters or more) a name with it in; each in Unicode's order
/// (the commonest first). Names are matched without their spaces and
/// punctuation ("thumbsup" is "thumbs up"), in small letters. Returns how
/// many.
pub fn search(q: []const u8, out: []*const table.Emoji) usize {
    if (q.len == 0) return 0;
    var n: usize = 0;
    for (0..4) |rank| {
        if (rank == 3 and q.len < 3) break;
        for (&table.all) |*em| {
            if (n == out.len) return n;
            if (rankOf(em.name, q) != rank) continue;
            out[n] = em;
            n += 1;
        }
    }
    return n;
}

/// `name` in small letters, without spaces and punctuation, in `buf`.
fn compact(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c < 0x80) continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

/// How well `q` (small letters) finds `name` (0: best; 4: not at all).
fn rankOf(name: []const u8, q: []const u8) u3 {
    var buf: [96]u8 = undefined;
    const whole = compact(&buf, name);
    if (std.mem.eql(u8, whole, q)) return 0;
    if (std.mem.startsWith(u8, whole, q)) return 1;
    var i: usize = 1;
    while (i < name.len) : (i += 1) {
        const before = name[i - 1];
        if (before != ' ' and before != '-' and before != ':') continue;
        var rest_buf: [96]u8 = undefined;
        if (std.mem.startsWith(u8, compact(&rest_buf, name[i..]), q)) return 2;
    }
    if (std.mem.indexOf(u8, whole, q) != null) return 3;
    return 4;
}

const testing = std.testing;

test "emoji found by name, best first, in the skin tone" {
    var found: [shown_max]*const table.Emoji = undefined;
    // A name it is, first; then those starting with it.
    var n = search("thumbsup", &found);
    try testing.expect(n >= 1);
    try testing.expectEqualStrings("👍", found[0].text);
    n = search("cat", &found);
    try testing.expectEqualStrings("cat", found[0].name);
    // A word of a name.
    n = search("pizz", &found);
    try testing.expectEqualStrings("🍕", found[0].text);
    // A name's later words, run together.
    n = search("facewithtears", &found);
    try testing.expectEqualStrings("😂", found[0].text);
    try testing.expectEqual(@as(usize, 0), search("zzqx", &found));
    // As typed: the tone for those that have them.
    var e: Emoji = .{ .tone = 3 };
    e.add("WAVING");
    e.add("hand");
    try testing.expectEqualStrings("wavinghand", e.query());
    var out: [shown_max][]const u8 = undefined;
    try testing.expect(e.shown(&out) >= 1);
    try testing.expectEqualStrings("👋🏽", out[0]);
    try testing.expect(e.erase());
    e.clear();
    try testing.expect(!e.erase());
}

test "those used most, with nothing typed; kept and read back" {
    var e: Emoji = .{ .tone = 2 };
    e.typed("👍");
    e.typed("😂");
    e.typed("😂");
    e.typed("🎉");
    var out: [shown_max][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), e.shown(&out));
    try testing.expectEqualStrings("😂", out[0]);
    // The same uses: the latest first.
    try testing.expectEqualStrings("🎉", out[1]);
    var buf: [Emoji.max_file]u8 = undefined;
    const back = Emoji.parse(e.format(&buf));
    try testing.expectEqual(@as(u3, 2), back.tone);
    try testing.expectEqual(@as(usize, 3), back.used_len);
    // One not in the table (one the font does not draw) is not read.
    try testing.expectEqual(@as(usize, 1), Emoji.parse("tone 0\n1 1 🫷\n2 2 👋🏽\n").used_len);
    // Full, the least used is forgotten for a new one.
    var full: Emoji = .{};
    for (table.all[0..kept], 0..) |em, i| {
        full.typed(em.text);
        if (i > 0) full.typed(em.text);
    }
    full.typed("🎉");
    try testing.expectEqual(@as(usize, kept), full.used_len);
    for (full.used[0..full.used_len]) |*u| try testing.expect(!std.mem.eql(u8, u.slice(), table.all[0].text));
}
