//! Kana to kanji a phrase at a time, with the Japanese language pack's
//! dictionary (made from Mozc's by tools/gen_japanese.zig): what was typed,
//! in hiragana, is split into the words it most likely is (the cheapest
//! path through the words whose readings follow on from each other, adding
//! each word's cost and the cost of each word following the one before,
//! by their parts of speech), as Mozc's converter does at heart (without
//! its learning, rewriting and the rest). The words are grouped into
//! phrases (bunsetsu: a word and the particles, auxiliaries and suffixes
//! that join on to it, 行き|ます), which are what the user goes between,
//! makes longer or shorter, and picks other words for.
//!
//! ja.dict: "DZJA", version (1), the number of entries, the number of
//! parts of speech and the length of the strings (u32 each, little endian);
//! then the entries, sorted by reading, then cost: each the offsets of its
//! reading and its surface (how it is written) in the strings (u32), their
//! lengths (u8), its left and right parts of speech and its cost (u16);
//! then the strings (UTF-8); then a byte for each part of speech, 1 if it
//! joins on to the word before in a phrase.
//!
//! ja.conn: "DZJC", the number of parts of speech (n, u32), then a byte for
//! each right part of speech (of a word) and left one (of the word after
//! it), at rid * n + lid: the cost of that, in 64ths.

const std = @import("std");

pub const Dictionary = struct {
    entries: []const u8,
    strings: []const u8,
    joins: []const u8,
    conn: []const u8,
    n_ids: usize,
    n_entries: usize,

    const entry_size = 16;

    pub const Entry = struct {
        reading: []const u8,
        surface: []const u8,
        lid: u16,
        rid: u16,
        cost: u16,
    };

    /// The dictionary in `dict` and `conn` (ja.dict and ja.conn, which
    /// must last as long as it does).
    pub fn init(dict: []const u8, conn: []const u8) !Dictionary {
        if (dict.len < 20 or !std.mem.eql(u8, dict[0..4], "DZJA")) return error.NotADictionary;
        if (std.mem.readInt(u32, dict[4..8], .little) != 1) return error.UnknownVersion;
        const n_entries = std.mem.readInt(u32, dict[8..12], .little);
        const n_ids = std.mem.readInt(u32, dict[12..16], .little);
        const strings_len = std.mem.readInt(u32, dict[16..20], .little);
        const entries_end = 20 + @as(usize, n_entries) * entry_size;
        if (dict.len != entries_end + strings_len + n_ids) return error.NotADictionary;
        if (conn.len != 8 + @as(usize, n_ids) * n_ids or !std.mem.eql(u8, conn[0..4], "DZJC") or std.mem.readInt(u32, conn[4..8], .little) != n_ids) return error.NotAMatrix;
        return .{
            .entries = dict[20..entries_end],
            .strings = dict[entries_end..][0..strings_len],
            .joins = dict[entries_end + strings_len ..],
            .conn = conn[8..],
            .n_ids = n_ids,
            .n_entries = n_entries,
        };
    }

    pub fn entry(d: *const Dictionary, i: usize) Entry {
        const e = d.entries[i * entry_size ..][0..entry_size];
        const r_off = std.mem.readInt(u32, e[0..4], .little);
        const s_off = std.mem.readInt(u32, e[4..8], .little);
        return .{
            .reading = d.strings[r_off..][0..e[8]],
            .surface = d.strings[s_off..][0..e[9]],
            .lid = std.mem.readInt(u16, e[10..12], .little),
            .rid = std.mem.readInt(u16, e[12..14], .little),
            .cost = std.mem.readInt(u16, e[14..16], .little),
        };
    }

    fn readingOf(d: *const Dictionary, i: usize) []const u8 {
        const e = d.entries[i * entry_size ..][0..entry_size];
        return d.strings[std.mem.readInt(u32, e[0..4], .little)..][0..e[8]];
    }

    /// The entries read as `reading`: their indices, cheapest first.
    pub fn lookup(d: *const Dictionary, reading: []const u8) struct { start: usize, end: usize } {
        var lo: usize = 0;
        var hi: usize = d.n_entries;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (std.mem.order(u8, d.readingOf(mid), reading) == .lt) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < d.n_entries and std.mem.eql(u8, d.readingOf(end), reading)) end += 1;
        return .{ .start = lo, .end = end };
    }

    /// The cost of a word of right part of speech `rid` being followed by
    /// one of left part of speech `lid`.
    pub fn connection(d: *const Dictionary, rid: u16, lid: u16) u32 {
        if (rid >= d.n_ids or lid >= d.n_ids) return 0;
        return @as(u32, d.conn[@as(usize, rid) * d.n_ids + lid]) * 64;
    }

    fn joinsBefore(d: *const Dictionary, lid: u16) bool {
        return lid < d.joins.len and d.joins[lid] != 0;
    }
};

/// A phrase: where it is in what was typed (bytes), and what it is now.
pub const Segment = struct {
    start: usize,
    end: usize,
    /// Its first word's reading ends here; the rest (particles and the
    /// like) are written `tail`.
    head_end: usize,
    tail: []const u8,
    text: []const u8,
};

/// A word in the cheapest path: where it is, and how it is written.
const Word = struct { start: usize, end: usize, surface: []const u8, lid: u16 };

/// The most characters a word's reading has.
const max_word_bytes = 16 * 3;
/// What a character no word starts with costs, as itself.
const unknown_cost = 10000;
/// The part of speech it has (a common noun).
const unknown_id = 1851;

pub const Conversion = struct {
    arena: std.heap.ArenaAllocator,
    dict: *const Dictionary,
    kana: []const u8,
    segments: std.ArrayList(Segment) = .empty,

    /// `kana` (hiragana, as typed) converted, a phrase at a time.
    pub fn init(gpa: std.mem.Allocator, dict: *const Dictionary, kana: []const u8) !Conversion {
        var c: Conversion = .{ .arena = .init(gpa), .dict = dict, .kana = undefined };
        errdefer c.arena.deinit();
        c.kana = try c.arena.allocator().dupe(u8, kana);
        try c.convertFrom(0, null);
        return c;
    }

    pub fn deinit(c: *Conversion) void {
        c.arena.deinit();
    }

    /// All of it, as it is now.
    pub fn text(c: *const Conversion, buf: []u8) []const u8 {
        var len: usize = 0;
        for (c.segments.items) |s| {
            const n = @min(s.text.len, buf.len - len);
            @memcpy(buf[len..][0..n], s.text[0..n]);
            len += n;
        }
        return buf[0..len];
    }

    /// Where phrase `i` is in `text`, in bytes.
    pub fn span(c: *const Conversion, i: usize) struct { begin: usize, end: usize } {
        var at: usize = 0;
        for (c.segments.items[0..i]) |s| at += s.text.len;
        return .{ .begin = at, .end = at + c.segments.items[i].text.len };
    }

    /// Phrase `i` made `chars` characters longer (or shorter), the phrases
    /// after it converted again. False if it cannot be.
    pub fn resize(c: *Conversion, i: usize, longer: bool) !bool {
        const s = c.segments.items[i];
        const new_end = if (longer) nextChar(c.kana, s.end) orelse return false else prevChar(c.kana, s.end);
        if (new_end <= s.start) return false;
        c.segments.shrinkRetainingCapacity(i);
        try c.convertFrom(s.start, new_end);
        return true;
    }

    /// Phrase `i` written as `choice` (one of its `candidates`).
    pub fn choose(c: *Conversion, i: usize, choice: []const u8) void {
        c.segments.items[i].text = choice;
    }

    /// What phrase `i` can be written as, the most likely first (and as it
    /// is now): its first word's readings with the rest as it is, then in
    /// hiragana, then katakana. At most `out.len`.
    pub fn candidates(c: *Conversion, i: usize, out: [][]const u8) ![][]const u8 {
        const a = c.arena.allocator();
        const s = c.segments.items[i];
        var n: usize = 0;
        const add = struct {
            fn add(o: [][]const u8, len: *usize, t: []const u8) void {
                if (len.* == o.len or t.len == 0) return;
                for (o[0..len.*]) |had| if (std.mem.eql(u8, had, t)) return;
                o[len.*] = t;
                len.* += 1;
            }
        }.add;
        add(out, &n, s.text);
        const r = c.dict.lookup(c.kana[s.start..s.head_end]);
        for (r.start..r.end) |e| add(out, &n, try std.mem.concat(a, u8, &.{ c.dict.entry(e).surface, s.tail }));
        const hira = c.kana[s.start..s.end];
        add(out, &n, hira);
        add(out, &n, try katakana(a, hira));
        return out[0..n];
    }

    /// Converts from `start` to the end, phrases after any before it; with
    /// the first phrase ending at `first_end`, if given.
    fn convertFrom(c: *Conversion, start: usize, first_end: ?usize) !void {
        const a = c.arena.allocator();
        if (first_end) |e| {
            // All of it one phrase: its words, together.
            const words = try c.cheapest(start, e);
            try c.addPhrase(words);
            if (e < c.kana.len) try c.addPhrases(try c.cheapest(e, c.kana.len));
        } else try c.addPhrases(try c.cheapest(start, c.kana.len));
        _ = a;
    }

    fn addPhrases(c: *Conversion, words: []const Word) !void {
        var i: usize = 0;
        while (i < words.len) {
            var j = i + 1;
            while (j < words.len and c.dict.joinsBefore(words[j].lid)) j += 1;
            try c.addPhrase(words[i..j]);
            i = j;
        }
    }

    fn addPhrase(c: *Conversion, words: []const Word) !void {
        if (words.len == 0) return;
        const a = c.arena.allocator();
        var tail: std.ArrayList(u8) = .empty;
        for (words[1..]) |w| try tail.appendSlice(a, w.surface);
        try c.segments.append(a, .{
            .start = words[0].start,
            .end = words[words.len - 1].end,
            .head_end = words[0].end,
            .tail = tail.items,
            .text = try std.mem.concat(a, u8, &.{ words[0].surface, tail.items }),
        });
    }

    /// The cheapest words for kana[from..to].
    fn cheapest(c: *Conversion, from: usize, to: usize) ![]Word {
        const a = c.arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(c.arena.child_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const Node = struct { word: Word, rid: u16, cost: u32, prev: ?u32 };
        var nodes: std.ArrayList(Node) = .empty;
        // The nodes ending at each byte.
        const ends = try sa.alloc(std.ArrayList(u32), to - from + 1);
        for (ends) |*e| e.* = .empty;
        const kana = c.kana;
        const d = c.dict;
        var i = from;
        while (i < to) : (i = nextChar(kana, i) orelse to) {
            const before = ends[i - from].items;
            if (i != from and before.len == 0) continue;
            // Each word starting here: the dictionary's, and the character
            // itself.
            var j = nextChar(kana, i) orelse to;
            var first = true;
            while (j <= to and j - i <= max_word_bytes) : (j = nextChar(kana, j) orelse to + 1) {
                const r = d.lookup(kana[i..j]);
                var words_here: usize = r.end - r.start;
                if (first) words_here += 1;
                for (0..words_here) |k| {
                    const w: Word, const rid: u16, const cost: u32 = if (r.start + k < r.end) blk: {
                        const e = d.entry(r.start + k);
                        break :blk .{ .{ .start = i, .end = j, .surface = e.surface, .lid = e.lid }, e.rid, e.cost };
                    } else .{ .{ .start = i, .end = j, .surface = kana[i..j], .lid = unknown_id }, unknown_id, unknown_cost };
                    var best: u32 = std.math.maxInt(u32);
                    var best_prev: ?u32 = null;
                    if (i == from) {
                        best = d.connection(0, w.lid);
                    } else for (before) |p| {
                        const total = nodes.items[p].cost + d.connection(nodes.items[p].rid, w.lid);
                        if (total < best) {
                            best = total;
                            best_prev = p;
                        }
                    }
                    try nodes.append(sa, .{ .word = w, .rid = rid, .cost = best + cost, .prev = best_prev });
                    try ends[j - from].append(sa, @intCast(nodes.items.len - 1));
                }
                first = false;
                if (j == to) break;
            }
        }
        // The cheapest to the end.
        var best: u32 = std.math.maxInt(u32);
        var last: ?u32 = null;
        for (ends[to - from].items) |p| {
            const total = nodes.items[p].cost + d.connection(nodes.items[p].rid, 0);
            if (total < best) {
                best = total;
                last = p;
            }
        }
        var count: usize = 0;
        var at = last;
        while (at) |p| : (at = nodes.items[p].prev) count += 1;
        const out = try a.alloc(Word, count);
        at = last;
        var k = count;
        while (at) |p| : (at = nodes.items[p].prev) {
            k -= 1;
            const w = nodes.items[p].word;
            out[k] = .{ .start = w.start, .end = w.end, .surface = try a.dupe(u8, w.surface), .lid = w.lid };
        }
        return out;
    }
};

fn nextChar(s: []const u8, i: usize) ?usize {
    if (i >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @min(s.len, i + len);
}

fn prevChar(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (s[j] & 0xc0 != 0x80) break;
    }
    return j;
}

/// Hiragana as katakana.
pub fn katakana(a: std.mem.Allocator, h: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = (std.unicode.Utf8View.init(h) catch return h).iterator();
    while (it.nextCodepoint()) |ch| {
        const k: u21 = if (ch >= 0x3041 and ch <= 0x3096) ch + 0x60 else ch;
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(k, &buf);
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

const testing = std.testing;

fn testDictionary() !Dictionary {
    return Dictionary.init(@embedFile("ja.dict"), @embedFile("ja.conn"));
}

test "sentences converted, a phrase at a time" {
    const d = try testDictionary();
    var buf: [256]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "わたしはがっこうにいきます", "私は学校に行きます" },
        .{ "きょうはいいてんきですね", "今日はいい天気ですね" },
        .{ "にほんごをべんきょうしています", "日本語を勉強しています" },
        .{ "せっていをかえてください", "設定を変えてください" },
        .{ "ねっとわーくにせつぞくできません", "ネットワークに接続できません" },
    };
    for (cases) |c| {
        var conv = try Conversion.init(testing.allocator, &d, c[0]);
        defer conv.deinit();
        try testing.expectEqualStrings(c[1], conv.text(&buf));
    }
    // Its phrases: 私は|学校に|行きます.
    var conv = try Conversion.init(testing.allocator, &d, "わたしはがっこうにいきます");
    defer conv.deinit();
    try testing.expectEqual(@as(usize, 3), conv.segments.items.len);
    try testing.expectEqualStrings("私は", conv.segments.items[0].text);
    try testing.expectEqualStrings("行きます", conv.segments.items[2].text);
    try testing.expectEqual(@as(usize, "私は".len), conv.span(1).begin);
}

test "a phrase's candidates, and made shorter or longer" {
    const d = try testDictionary();
    var conv = try Conversion.init(testing.allocator, &d, "しゃしんをとりました");
    defer conv.deinit();
    // 撮りました is among the last phrase's candidates.
    var out: [32][]const u8 = undefined;
    const last = conv.segments.items.len - 1;
    const cands = try conv.candidates(last, &out);
    var found = false;
    for (cands) |c| found = found or std.mem.eql(u8, c, "撮りました");
    try testing.expect(found);
    conv.choose(last, "撮りました");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("写真を撮りました", conv.text(&buf));
    // The first phrase (写真を) one character shorter: しゃしん|を…, the
    // rest converted again.
    try testing.expect(try conv.resize(0, false));
    try testing.expectEqualStrings("しゃしん", conv.kana[conv.segments.items[0].start..conv.segments.items[0].end]);
    try testing.expectEqualStrings("写真", conv.segments.items[0].text);
    try testing.expect(conv.segments.items.len >= 2);
    // Not shorter than a character.
    var one = try Conversion.init(testing.allocator, &d, "き");
    defer one.deinit();
    try testing.expect(!try one.resize(0, false));
    try testing.expect(!try one.resize(0, true));
}
