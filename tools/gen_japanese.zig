//! Makes the Japanese language pack's dictionary (languages/ja/) from
//! Mozc's open-source dictionary (src/data/dictionary_oss in
//! https://github.com/google/mozc), for converting kana to kanji a phrase at
//! a time (see src/shell/input_method/conversion.zig). Mozc's dictionary is
//! IPAdic's words (with Google's additions), each with its reading, its
//! parts of speech (left and right ids) and a cost (lower is more likely),
//! and a matrix of costs for one part of speech following another.
//!
//! The dictionary is cut down to the words that cost 6000 or less (about a
//! sixth), with every particle, auxiliary and symbol, and words costing
//! more than 4000 made to cost more still: Mozc holds rare words back in
//! ways this does not (see the conversion), and they otherwise win too often.
//! Corrected misspellings (SPELLING_CORRECTION) are left out. The matrix's
//! costs are kept to a byte each (in 64ths); and which parts of speech join
//! on to the word before, in a phrase (particles, auxiliaries, suffixes).
//!
//! Usage (with a checkout or download of Mozc's dictionary_oss folder):
//!
//!     zig run tools/gen_japanese.zig -- <dictionary_oss> languages/ja
//!     xz -9 -f languages/ja/ja.dict languages/ja/ja.conn
//!
//! It writes ja.dict and ja.conn (see conversion.zig for their layout), and
//! NOTICE, the dictionary's licence (from its README.txt). Run it again for
//! a new version of Mozc's dictionary, and commit what it writes.

const std = @import("std");

const Entry = struct {
    reading: []const u8,
    surface: []const u8,
    lid: u16,
    rid: u16,
    cost: u16,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        const o = std.mem.order(u8, a.reading, b.reading);
        if (o != .eq) return o == .lt;
        return a.cost < b.cost;
    }
};

const max_cost = 6000;
const penalty_from = 4000;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: gen_japanese <dictionary_oss> <output dir>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const src = args[1];
    const out_dir = args[2];

    // Parts of speech, and which join on to the word before.
    const id_text = try cwd.readFileAlloc(init.io, try std.fs.path.join(arena, &.{ src, "id.def" }), arena, .limited(16 << 20));
    var features: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, id_text, "\r\n");
    while (lines.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const id = try std.fmt.parseInt(usize, line[0..sp], 10);
        if (id != features.items.len) return error.IdsOutOfOrder;
        try features.append(arena, line[sp + 1 ..]);
    }
    const n_ids = features.items.len;

    var entries: std.ArrayList(Entry) = .empty;
    var total: usize = 0;
    for (0..10) |i| {
        const path = try std.fmt.allocPrint(arena, "{s}/dictionary0{d}.txt", .{ src, i });
        const text = try cwd.readFileAlloc(init.io, path, arena, .limited(64 << 20));
        var it = std.mem.tokenizeAny(u8, text, "\r\n");
        while (it.next()) |line| {
            total += 1;
            var f = std.mem.splitScalar(u8, line, '\t');
            const reading = f.next() orelse continue;
            const lid = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch continue;
            const rid = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch continue;
            const cost = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            const surface = f.next() orelse continue;
            if (f.next() != null) continue; // SPELLING_CORRECTION and the like
            if (lid >= n_ids or rid >= n_ids) continue;
            const function_word = std.mem.startsWith(u8, features.items[lid], "助詞") or
                std.mem.startsWith(u8, features.items[lid], "助動詞") or
                std.mem.startsWith(u8, features.items[lid], "記号");
            if (cost > max_cost and !function_word) continue;
            if (reading.len > 255 or surface.len > 255) continue;
            const penalised = cost + (cost -| penalty_from);
            try entries.append(arena, .{ .reading = reading, .surface = surface, .lid = lid, .rid = rid, .cost = @intCast(@min(penalised, 65535)) });
        }
    }
    std.mem.sort(Entry, entries.items, {}, Entry.lessThan);

    // ja.dict: "DZJA", version, counts, then the entries (sorted by
    // reading), then the strings, then each part of speech's flags.
    var strings: std.ArrayList(u8) = .empty;
    var string_at: std.StringHashMapUnmanaged(u32) = .empty;
    var dict: std.ArrayList(u8) = .empty;
    try dict.appendSlice(arena, "DZJA");
    try writeInt(arena, &dict, u32, 1);
    try writeInt(arena, &dict, u32, @intCast(entries.items.len));
    try writeInt(arena, &dict, u32, @intCast(n_ids));
    const strings_len_at = dict.items.len;
    try writeInt(arena, &dict, u32, 0);
    for (entries.items) |e| {
        try writeInt(arena, &dict, u32, try intern(arena, &strings, &string_at, e.reading));
        try writeInt(arena, &dict, u32, try intern(arena, &strings, &string_at, e.surface));
        try dict.append(arena, @intCast(e.reading.len));
        try dict.append(arena, @intCast(e.surface.len));
        try writeInt(arena, &dict, u16, e.lid);
        try writeInt(arena, &dict, u16, e.rid);
        try writeInt(arena, &dict, u16, e.cost);
    }
    std.mem.writeInt(u32, dict.items[strings_len_at..][0..4], @intCast(strings.items.len), .little);
    try dict.appendSlice(arena, strings.items);
    for (features.items) |feat| try dict.append(arena, @intFromBool(joinsBefore(feat)));
    try writeFile(init.io, arena, out_dir, "ja.dict", dict.items);

    // ja.conn: "DZJC", the number of ids, then the cost of each right id
    // followed by each left id (rid * n + lid), in 64ths, a byte each.
    const conn_text = try cwd.readFileAlloc(init.io, try std.fs.path.join(arena, &.{ src, "connection_single_column.txt" }), arena, .limited(64 << 20));
    var it = std.mem.tokenizeAny(u8, conn_text, "\r\n");
    const n = try std.fmt.parseInt(usize, it.next() orelse return error.NoMatrix, 10);
    if (n != n_ids) return error.MatrixSize;
    var conn: std.ArrayList(u8) = .empty;
    try conn.appendSlice(arena, "DZJC");
    try writeInt(arena, &conn, u32, @intCast(n));
    var count: usize = 0;
    while (it.next()) |line| : (count += 1) {
        const c = try std.fmt.parseInt(i32, line, 10);
        try conn.append(arena, @intCast(std.math.clamp(@divFloor(c + 32, 64), 0, 255)));
    }
    if (count != n * n) return error.MatrixSize;
    try writeFile(init.io, arena, out_dir, "ja.conn", conn.items);

    // The licence the dictionary comes under: its README's, from "Mozc
    // dictionary is" (or all of it).
    const readme = try cwd.readFileAlloc(init.io, try std.fs.path.join(arena, &.{ src, "README.txt" }), arena, .limited(1 << 20));
    var notice: std.ArrayList(u8) = .empty;
    try notice.appendSlice(arena,
        \\The Japanese language pack's dictionary is made from Mozc's open-source
        \\dictionary (https://github.com/google/mozc, src/data/dictionary_oss) by
        \\tools/gen_japanese.zig. Its README follows, with the licences it is
        \\under.
        \\
        \\
    );
    try notice.appendSlice(arena, readme);
    try writeFile(init.io, arena, out_dir, "NOTICE", notice.items);

    std.debug.print("{d} of {d} entries, {d} parts of speech; ja.dict {d} bytes, ja.conn {d} bytes\n", .{ entries.items.len, total, n_ids, dict.items.len, conn.items.len });
}

/// Whether words of this part of speech join on to the word before, in a
/// phrase: particles, auxiliaries, and verbs', adjectives' and nouns'
/// dependent forms and suffixes (行き|ます, 田中|さん).
fn joinsBefore(feature: []const u8) bool {
    const kinds = [_][]const u8{ "助詞,", "助動詞,", "動詞,非自立", "動詞,接尾", "形容詞,非自立", "形容詞,接尾", "名詞,接尾" };
    for (kinds) |k| if (std.mem.startsWith(u8, feature, k)) return true;
    return false;
}

fn intern(a: std.mem.Allocator, strings: *std.ArrayList(u8), at: *std.StringHashMapUnmanaged(u32), s: []const u8) !u32 {
    const gop = try at.getOrPut(a, s);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(strings.items.len);
        try strings.appendSlice(a, s);
    }
    return gop.value_ptr.*;
}

fn writeInt(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn writeFile(io: std.Io, a: std.mem.Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ dir, name });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
