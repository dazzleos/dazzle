//! Writes the app catalogue, apps.json: the apps that can be installed,
//! published beside the image and their archives (each made by mkapp, and
//! compressed). Settings downloads it, and an app's archive from the same
//! place by its "file", checking its size and SHA-256.
//!
//!     {
//!       "version": "<the commit they were built from>",
//!       "apps": [
//!         {
//!           "name": "dazzle-demo",
//!           "title": "Demo",
//!           "description": "A spinning 3D shape, showing off the graphics",
//!           "icon": "view_in_ar",
//!           "file": "dazzle-demo.tar.xz",
//!           "size": 104321,
//!           "sha256": "<64 hex digits>"
//!         }
//!       ]
//!     }
//!
//! Usage: mkcatalogue <apps.json> <version> (<name> <title> <description> <icon> <archive>)...

const std = @import("std");

pub const App = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    icon: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const Catalogue = struct {
    version: []const u8,
    apps: []const App,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or (args.len - 3) % 5 != 0) {
        std.debug.print("usage: mkcatalogue <apps.json> <version> (<name> <title> <description> <icon> <archive>)...\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var apps: std.ArrayList(App) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 5) {
        const archive = try cwd.readFileAlloc(init.io, args[i + 4], arena, .limited(256 << 20));
        try apps.append(arena, .{
            .name = args[i],
            .title = args[i + 1],
            .description = args[i + 2],
            .icon = args[i + 3],
            .file = try std.fmt.allocPrint(arena, "{s}.tar.xz", .{args[i]}),
            .size = archive.len,
            .sha256 = try hexSha256(arena, archive),
        });
    }
    const json = try write(arena, .{ .version = args[2], .apps = apps.items });
    const file = try cwd.createFile(init.io, args[1], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, json);
}

pub fn hexSha256(gpa: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.allocPrint(gpa, "{x}", .{&digest});
}

pub fn write(gpa: std.mem.Allocator, c: Catalogue) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(c, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

test "the catalogue: each app, with its archive's size and digest" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try write(a, .{ .version = "abc1234", .apps = &.{.{
        .name = "dazzle-demo",
        .title = "Demo",
        .description = "Spins",
        .icon = "view_in_ar",
        .file = "dazzle-demo.tar.xz",
        .size = 3,
        .sha256 = try hexSha256(a, "abc"),
    }} });
    const back = try std.json.parseFromSliceLeaky(Catalogue, a, json, .{});
    try std.testing.expectEqualStrings("abc1234", back.version);
    try std.testing.expectEqualStrings("Demo", back.apps[0].title);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", back.apps[0].sha256);
}
