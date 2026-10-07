//! Packs an app for downloading: a tar archive of its folder, as it goes
//! in /apps (the build compresses it with xz). The program is executable;
//! the other files are not. Times are 0, so the same app makes the same
//! archive.
//!
//! Usage: mkapp <output.tar> <name> <program> [<file name>=<file>]...
//!
//! The archive holds <name>/<name> (the program) and <name>/<file name>
//! for each other file.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: mkapp <output.tar> <name> <program> [<file name>=<file>]...\n", .{});
        std.process.exit(2);
    }
    const name = args[2];
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList(Entry) = .empty;
    try files.append(arena, .{
        .path = name,
        .data = try cwd.readFileAlloc(init.io, args[3], arena, .limited(256 << 20)),
        .mode = 0o755,
    });
    for (args[4..]) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadArgument;
        try files.append(arena, .{
            .path = spec[0..eq],
            .data = try cwd.readFileAlloc(init.io, spec[eq + 1 ..], arena, .limited(256 << 20)),
            .mode = 0o644,
        });
    }
    const tar = try pack(arena, name, files.items);
    const file = try cwd.createFile(init.io, args[1], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, tar);
}

pub const Entry = struct { path: []const u8, data: []const u8, mode: u32 };

/// The archive: the folder `name`, then each file in it.
pub fn pack(gpa: std.mem.Allocator, name: []const u8, files: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var w: std.tar.Writer = .{ .underlying_writer = &out.writer };
    // The folder, and the files in it.
    try w.setRoot(name);
    for (files) |f| try w.writeFileBytes(f.path, f.data, .{ .mode = f.mode });
    try w.finishPedantically();
    return out.toOwnedSlice();
}

test "an app's archive unpacks to its folder" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tar = try pack(arena.allocator(), "dazzle-notes", &.{
        .{ .path = "dazzle-notes", .data = "\x7fELF", .mode = 0o755 },
        .{ .path = "dazzle-notes.icon", .data = "description\n", .mode = 0o644 },
    });
    var reader: std.Io.Reader = .fixed(tar);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var seen: usize = 0;
    while (try it.next()) |f| {
        switch (seen) {
            0 => try std.testing.expectEqualStrings("dazzle-notes", f.name),
            1 => {
                try std.testing.expectEqualStrings("dazzle-notes/dazzle-notes", f.name);
                try std.testing.expectEqual(@as(u32, 0o755), f.mode & 0o777);
            },
            2 => try std.testing.expectEqualStrings("dazzle-notes/dazzle-notes.icon", f.name),
            else => {},
        }
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}
