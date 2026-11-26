//! Makes src/shell/emoji_table.zig from Unicode's emoji-test.txt, for the
//! on-screen keyboard's emoji: each emoji (fully qualified) in Unicode's
//! order, its group, and, for those that have them, its five skin tones
//! (each the same tone throughout: "people holding hands: medium skin
//! tone", not "...: light skin tone, dark skin tone"). The components
//! (the tones and hair styles alone) are left out, and so are those newer
//! than `newest`, which the emoji font (kete's Twemoji Mozilla) does not
//! draw. Run it again for a new version of Unicode's emoji, or of the font:
//!
//!     zig run tools/mkemoji.zig -- /usr/share/unicode/emoji/emoji-test.txt src/shell/emoji_table.zig

const std = @import("std");

const groups = [_]struct { []const u8, []const u8 }{
    .{ "Smileys & Emotion", "smileys" },
    .{ "People & Body", "people" },
    .{ "Animals & Nature", "animals" },
    .{ "Food & Drink", "food" },
    .{ "Travel & Places", "travel" },
    .{ "Activities", "activities" },
    .{ "Objects", "objects" },
    .{ "Symbols", "symbols" },
    .{ "Flags", "flags" },
};

/// The newest emoji (Unicode's emoji version) the font draws.
const newest: f32 = 14.0;

const tone_names = [_][]const u8{ "light skin tone", "medium-light skin tone", "medium skin tone", "medium-dark skin tone", "dark skin tone" };

const Entry = struct { name: []const u8, text: []const u8, group: []const u8, tones: [5]?[]const u8 = @splat(null) };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: mkemoji <emoji-test.txt> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, args[1], arena, .limited(8 << 20));

    var entries: std.ArrayList(Entry) = .empty;
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    var version: []const u8 = "?";
    var group: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, input, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# Version: ")) version = line["# Version: ".len..];
        if (std.mem.startsWith(u8, line, "# group: ")) {
            const g = line["# group: ".len..];
            group = for (groups) |known| {
                if (std.mem.eql(u8, known[0], g)) break known[1];
            } else null;
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;
        const in = group orelse continue;
        // 1F600 ; fully-qualified # 😀 E1.0 grinning face
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[semi + 1 .. hash], " "), "fully-qualified")) continue;
        var rest = std.mem.trim(u8, line[hash + 1 ..], " ");
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const text = rest[0..sp];
        rest = std.mem.trimStart(u8, rest[sp + 1 ..], " ");
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const name = rest[sp2 + 1 ..];
        // "E15.0": newer than the font, it is left out.
        if (rest[0] == 'E') {
            const v = std.fmt.parseFloat(f32, rest[1..sp2]) catch 0;
            if (v > newest) continue;
        }
        if (std.mem.indexOf(u8, name, "skin tone") == null) {
            try by_name.put(arena, name, entries.items.len);
            try entries.append(arena, .{ .name = name, .text = text, .group = in });
            continue;
        }
        // A skin tone of an emoji before it: one tone, the same
        // throughout ("X: light skin tone", or "X, light skin tone" after
        // the people it is of).
        for (tone_names, 0..) |tone, i| {
            if (!std.mem.endsWith(u8, name, tone)) continue;
            const before = name[0 .. name.len - tone.len];
            // ("medium-light skin tone" ends as "light skin tone" does.)
            if (!(std.mem.endsWith(u8, before, ": ") or std.mem.endsWith(u8, before, ", "))) continue;
            const base = before[0 .. before.len - 2];
            if (std.mem.indexOf(u8, base, "skin tone") != null) break;
            const at = by_name.get(base) orelse break;
            entries.items[at].tones[i] = text;
            break;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\//! Made by tools/mkemoji.zig from Unicode's emoji-test.txt: each emoji
        \\//! (fully qualified, up to those the font draws) in Unicode's order,
        \\//! its group, and its five skin tones if it has them.
        \\
        \\pub const Group = enum { smileys, people, animals, food, travel, activities, objects, symbols, flags };
        \\
        \\pub const Emoji = struct {
        \\    text: []const u8,
        \\    group: Group,
        \\    /// Light, medium-light, medium, medium-dark and dark.
        \\    tones: ?[5][]const u8 = null,
        \\};
        \\
        \\pub const all = [_]Emoji{
        \\
    );
    var toned: usize = 0;
    for (entries.items) |e| {
        try out.print(arena, "    .{{ .text = \"{s}\", .group = .{s}", .{ e.text, e.group });
        const complete = for (e.tones) |t| {
            if (t == null) break false;
        } else true;
        if (complete) {
            toned += 1;
            try out.appendSlice(arena, ", .tones = .{ ");
            for (e.tones, 0..) |t, i| try out.print(arena, "{s}\"{s}\"", .{ if (i > 0) ", " else "", t.? });
            try out.appendSlice(arena, " }");
        }
        try out.appendSlice(arena, " },\n");
    }
    try out.appendSlice(arena, "};\n");
    try out.print(arena, "\n/// The version of Unicode's emoji it is made from.\npub const version = \"{s}\";\n", .{version});
    const file = try cwd.createFile(init.io, args[2], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, out.items);
    std.debug.print("{d} emoji, {d} with skin tones\n", .{ entries.items.len, toned });
}
