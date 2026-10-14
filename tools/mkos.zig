//! Packs the system for updating: one OS slot's files (the kernel, device
//! trees, overlays, initramfs and version, but not its command line, which
//! says which slot it is) as a tar archive of the folder "os" (the build
//! compresses it with xz); and the manifest describing it, os.json (in the
//! same item format as apps.json), both published beside the image with
//! icon.png. Settings downloads the manifest and icon, and the archive by
//! its "file" if the system is newer than both slots', checking its size,
//! SHA-256 and Ed25519 signature; the system manager installs it (src/init/update.zig).
//!
//!     {
//!       "name": "dazzle",
//!       "title": "Dazzle",
//!       "description": "The operating system",
//!       "version": "<Dazzle's commit>-<the kernel's commit>",
//!       "time": <the later of when they were made, in seconds since 1970>,
//!       "icon": "icon.png",
//!       "file": "dazzle-os.tar.xz",
//!       "size": 4123456,
//!       "sha256": "<64 hex digits>",
//!       "signature": "<128 hex digits>"
//!     }
//!
//! Usage: mkos pack <output.tar> [<name in the slot>=<file>]...
//!        mkos manifest [--key=<64-hex-seed>] <os.json> <version file> <archive>
//!
//! The version file is the slot's ("<time> <version>").

const std = @import("std");
const mkapp = @import("mkapp.zig");
const mkcatalogue = @import("mkcatalogue.zig");

pub const Manifest = mkcatalogue.App;

pub const archive_name = "dazzle-os.tar.xz";
pub const icon_name = "icon.png";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cwd = std.Io.Dir.cwd();
    if (args.len >= 3 and std.mem.eql(u8, args[1], "pack")) {
        var files: std.ArrayList(mkapp.Entry) = .empty;
        for (args[3..]) |spec| {
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadArgument;
            try files.append(arena, .{
                .path = spec[0..eq],
                .data = try cwd.readFileAlloc(init.io, spec[eq + 1 ..], arena, .limited(256 << 20)),
                .mode = 0o644,
            });
        }
        try writeFile(init.io, args[2], try pack(arena, files.items));
    } else if (args.len >= 5 and std.mem.eql(u8, args[1], "manifest")) {
        var base: usize = 2;
        var seed: [32]u8 = mkcatalogue.default_seed;
        if (base < args.len and std.mem.startsWith(u8, args[base], "--key=")) {
            seed = try mkcatalogue.parseSeed(args[base]["--key=".len..]);
            base += 1;
        }
        if (args.len != base + 3) {
            std.debug.print("usage: mkos pack <output.tar> [<name in the slot>=<file>]...\n       mkos manifest [--key=<64-hex-seed>] <os.json> <version file> <archive>\n", .{});
            std.process.exit(2);
        }
        const kp = mkcatalogue.keyPair(seed);
        const archive = try cwd.readFileAlloc(init.io, args[base + 2], arena, .limited(256 << 20));
        const version = try cwd.readFileAlloc(init.io, args[base + 1], arena, .limited(256));
        var fields = std.mem.tokenizeAny(u8, version, " \n");
        const time = try std.fmt.parseInt(u64, fields.next() orelse return error.BadVersion, 10);
        const m: Manifest = .{
            .name = "dazzle",
            .title = "Dazzle",
            .description = "The operating system",
            .version = fields.next() orelse return error.BadVersion,
            .time = time,
            .icon = icon_name,
            .file = archive_name,
            .size = archive.len,
            .sha256 = try mkcatalogue.hexSha256(arena, archive),
            .signature = try mkcatalogue.hexSignature(arena, archive, kp),
        };
        try writeFile(init.io, args[base], try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(m, .{ .whitespace = .indent_2 })}));
    } else {
        std.debug.print("usage: mkos pack <output.tar> [<name in the slot>=<file>]...\n       mkos manifest [--key=<64-hex-seed>] <os.json> <version file> <archive>\n", .{});
        std.process.exit(2);
    }
}

/// The archive: the folder "os", its folders (overlays/), then its files.
pub fn pack(gpa: std.mem.Allocator, files: []const mkapp.Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var w: std.tar.Writer = .{ .underlying_writer = &out.writer };
    try w.setRoot("os");
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(gpa);
    for (files) |f| if (std.mem.lastIndexOfScalar(u8, f.path, '/')) |slash| {
        const dir = f.path[0..slash];
        for (dirs.items) |d| {
            if (std.mem.eql(u8, d, dir)) break;
        } else {
            try dirs.append(gpa, dir);
            try w.writeDir(dir, .{});
        }
    };
    for (files) |f| try w.writeFileBytes(f.path, f.data, .{ .mode = f.mode });
    try w.finishPedantically();
    return out.toOwnedSlice();
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

test "the system's archive unpacks to the folder os, with its overlays" {
    _ = mkcatalogue;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tar = try pack(arena.allocator(), &.{
        .{ .path = "zImage", .data = "kernel", .mode = 0o644 },
        .{ .path = "overlays/imx219.dtbo", .data = "overlay", .mode = 0o644 },
        .{ .path = "version", .data = "1791331200 de14aa2\n", .mode = 0o644 },
    });
    var reader: std.Io.Reader = .fixed(tar);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    const want = [_][]const u8{ "os", "os/overlays", "os/zImage", "os/overlays/imx219.dtbo", "os/version" };
    var seen: usize = 0;
    while (try it.next()) |f| : (seen += 1) try std.testing.expectEqualStrings(want[seen], std.mem.trimEnd(u8, f.name, "/"));
    try std.testing.expectEqual(want.len, seen);
}

