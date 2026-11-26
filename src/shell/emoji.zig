//! The on-screen keyboard's emoji: every one (emoji_table.zig, from
//! Unicode's), in its groups, a page at a time; a skin tone, for those
//! that have them; and those used most, first (kept in `file`, with the
//! tone, so they are a tap or two away).

const std = @import("std");
const sys = @import("sys");
const table = @import("emoji_table.zig");

/// What the emoji page shows: those used most, or a group.
pub const Tab = enum { frequent, smileys, people, animals, food, travel, activities, objects, symbols, flags };

/// Emoji on a page: three rows of ten.
pub const per_page = 30;
pub const columns = 10;

/// Where those used most, and the tone, are kept.
pub const file = sys.system.apps_dir ++ "/.emoji";

/// How many used are remembered (the most used shown).
const kept = 60;

/// The longest emoji text (a family, a kiss, with tones: some thirty
/// bytes).
pub const max_text = 40;

/// Each group's emoji: where they start in the table, and how many.
const ranges = blk: {
    @setEvalBranchQuota(200_000);
    var r: [std.enums.values(table.Group).len]struct { start: usize, len: usize } = @splat(.{ .start = 0, .len = 0 });
    for (table.all, 0..) |e, i| {
        const g = @intFromEnum(e.group);
        if (r[g].len == 0) r[g].start = i;
        r[g].len += 1;
    }
    break :blk r;
};

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
    tab: Tab = .smileys,
    page: usize = 0,
    /// The skin tone (0: none, the yellow; 1 to 5: light to dark).
    tone: u3 = 0,
    /// The tones being chosen from (in place of the emoji).
    choosing_tone: bool = false,
    used: [kept]Used = undefined,
    used_len: usize = 0,
    clock: u32 = 0,

    /// Those used most first, if any; else the smileys.
    pub fn open(e: *Emoji) void {
        e.tab = if (e.used_len > 0) .frequent else .smileys;
        e.page = 0;
        e.choosing_tone = false;
    }

    pub fn show(e: *Emoji, tab: Tab) void {
        e.tab = tab;
        e.page = 0;
        e.choosing_tone = false;
    }

    /// How many pages the tab has (one, at least).
    pub fn pages(e: *const Emoji) usize {
        const n = switch (e.tab) {
            .frequent => @min(e.used_len, per_page),
            else => ranges[@intFromEnum(e.tab) - 1].len,
        };
        return @max(1, (n + per_page - 1) / per_page);
    }

    pub fn turn(e: *Emoji, forward: bool) void {
        const n = e.pages();
        e.page = if (forward) (e.page + 1) % n else (e.page + n - 1) % n;
    }

    /// `em` in the tone chosen, if it has tones.
    pub fn toned(e: *const Emoji, em: *const table.Emoji) []const u8 {
        if (e.tone == 0) return em.text;
        const tones = em.tones orelse return em.text;
        return tones[e.tone - 1];
    }

    /// The page's emoji (as they type), in `out`; returns how many.
    pub fn shown(e: *const Emoji, out: *[per_page][]const u8) usize {
        if (e.tab == .frequent) {
            var order: [kept]*const Used = undefined;
            for (e.used[0..e.used_len], 0..) |*u, i| order[i] = u;
            std.mem.sort(*const Used, order[0..e.used_len], {}, moreUsed);
            const n = @min(e.used_len, per_page);
            for (order[0..n], 0..) |u, i| out[i] = u.slice();
            return n;
        }
        const r = ranges[@intFromEnum(e.tab) - 1];
        const start = e.page * per_page;
        const n = @min(per_page, r.len -| start);
        for (0..n) |i| out[i] = e.toned(&table.all[r.start + start + i]);
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
                e.tone = std.math.cast(u3, std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue) orelse 0;
                if (e.tone > 5) e.tone = 0;
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

const testing = std.testing;

test "every emoji in a group, a page at a time; in a skin tone if it has them" {
    var e: Emoji = .{};
    e.show(.smileys);
    var out: [per_page][]const u8 = undefined;
    try testing.expectEqual(@as(usize, per_page), e.shown(&out));
    try testing.expectEqualStrings("😀", out[0]);
    // Every one, on some page of some group (but the components).
    var total: usize = 0;
    for (std.enums.values(Tab)[1..]) |tab| {
        e.show(tab);
        for (0..e.pages()) |_| {
            total += e.shown(&out);
            e.turn(true);
        }
        try testing.expectEqual(@as(usize, 0), e.page);
    }
    try testing.expectEqual(table.all.len, total);
    // A waving hand in the tone chosen; a grinning face as it is.
    e.tone = 3;
    const wave = for (&table.all) |*x| {
        if (std.mem.eql(u8, x.text, "👋")) break x;
    } else unreachable;
    try testing.expectEqualStrings("👋🏽", e.toned(wave));
    try testing.expectEqualStrings("😀", e.toned(&table.all[0]));
}

test "those used most first, kept and read back" {
    var e: Emoji = .{ .tone = 2 };
    e.typed("👍");
    e.typed("😂");
    e.typed("😂");
    e.typed("🎉");
    e.open();
    try testing.expectEqual(Tab.frequent, e.tab);
    var out: [per_page][]const u8 = undefined;
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
