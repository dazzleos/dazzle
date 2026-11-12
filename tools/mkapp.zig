//! Packs an app for downloading: a tar archive of its folder, as it goes
//! in /apps (the build compresses it with xz). The program (and any
//! `--exe=` file) is executable; the other files are not. Times are 0, so
//! the same app makes the same archive.
//!
//! Usage: mkapp <output.tar> <name> <program> [--exe=<name>=<file> | --dir=<prefix>=<dir> | --exclude=<prefix> | <file name>=<file>]...
//!
//! The archive holds <name>/<name> (the program) and <name>/<file name>
//! for each other file or directory entry.

const std = @import("std");
const linux = std.os.linux;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: mkapp <output.tar> <name> <program> [--exe=<name>=<file> | --dir=<prefix>=<dir> | --exclude=<prefix> | <file name>=<file>]...\n", .{});
        std.process.exit(2);
    }
    const name = args[2];
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList(Entry) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;
    try files.append(arena, .{
        .path = name,
        .data = try cwd.readFileAlloc(init.io, args[3], arena, .limited(256 << 20)),
        .mode = 0o755,
    });
    for (args[4..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try excludes.append(arena, arg["--exclude=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dir=")) {
            const spec = arg["--dir=".len..];
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadArgument;
            try walkDir(init.io, arena, spec[0..eq], spec[eq + 1 ..], excludes.items, &files);
            continue;
        }
        const is_exe = std.mem.startsWith(u8, arg, "--exe=");
        const spec = if (is_exe) arg["--exe=".len..] else arg;
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadArgument;
        try files.append(arena, .{
            .path = spec[0..eq],
            .data = try cwd.readFileAlloc(init.io, spec[eq + 1 ..], arena, .limited(256 << 20)),
            .mode = if (is_exe) 0o755 else 0o644,
        });
    }
    const tar = try pack(arena, name, files.items);
    const file = try cwd.createFile(init.io, args[1], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, tar);
}

fn isExcluded(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |ex| {
        if (std.mem.eql(u8, path, ex)) return true;
        if (std.mem.startsWith(u8, path, ex) and path.len > ex.len and path[ex.len] == '/') return true;
    }
    return false;
}

const Child = struct {
    name: []const u8,
    is_dir: bool,

    fn lessThan(_: void, a: Child, b: Child) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

fn walkDir(
    io: std.Io,
    arena: std.mem.Allocator,
    dest_prefix: []const u8,
    src_dir: []const u8,
    excludes: []const []const u8,
    files: *std.ArrayList(Entry),
) !void {
    const src_z = try arena.dupeSentinel(u8, src_dir, 0);
    const rc = linux.open(src_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenDirFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var children: std.ArrayList(Child) = .empty;
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadDirFailed;
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const kind = buf[at + 18];
            const entry_name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
            if (kind != 4 and kind != 8) continue;
            try children.append(arena, .{
                .name = try arena.dupe(u8, entry_name),
                .is_dir = kind == 4,
            });
        }
    }
    std.mem.sort(Child, children.items, {}, Child.lessThan);

    const cwd = std.Io.Dir.cwd();
    for (children.items) |child| {
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest_prefix, child.name });
        if (isExcluded(rel, excludes)) continue;
        const src_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_dir, child.name });
        if (child.is_dir) {
            try walkDir(io, arena, rel, src_path, excludes, files);
        } else {
            try files.append(arena, .{
                .path = rel,
                .data = try cwd.readFileAlloc(io, src_path, arena, .limited(256 << 20)),
                .mode = 0o644,
            });
        }
    }
}

pub const Entry = struct { path: []const u8, data: []const u8, mode: u32 };

/// The archive: the folder `name`, its subfolders, then each file in it.
pub fn pack(gpa: std.mem.Allocator, name: []const u8, files: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var w: std.tar.Writer = .{ .underlying_writer = &out.writer };
    // The folder, its subfolders, and the files in it.
    try w.setRoot(name);
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer dirs.deinit(gpa);
    for (files) |f| {
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, f.path, pos, '/')) |slash| : (pos = slash + 1) {
            const dir = f.path[0..slash];
            const gop = try dirs.getOrPut(gpa, dir);
            if (!gop.found_existing) try w.writeDir(dir, .{});
        }
    }
    for (files) |f| try w.writeFileBytes(f.path, f.data, .{ .mode = f.mode });
    try w.finishPedantically();
    return out.toOwnedSlice();
}

test "an app's archive unpacks to its folder, with subfolders and executables" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tar = try pack(arena.allocator(), "dazzle-develop", &.{
        .{ .path = "dazzle-develop", .data = "\x7fELF", .mode = 0o755 },
        .{ .path = "dazzle-develop.icon", .data = "code\n", .mode = 0o644 },
        .{ .path = "zig/zig", .data = "\x7fELF", .mode = 0o755 },
        .{ .path = "zig/lib/std/std.zig", .data = "pub const os = 1;\n", .mode = 0o644 },
    });
    var reader: std.Io.Reader = .fixed(tar);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    const want = [_]struct { name: []const u8, kind: std.tar.FileKind, mode: u32 }{
        .{ .name = "dazzle-develop", .kind = .directory, .mode = 0o755 },
        .{ .name = "dazzle-develop/zig", .kind = .directory, .mode = 0o755 },
        .{ .name = "dazzle-develop/zig/lib", .kind = .directory, .mode = 0o755 },
        .{ .name = "dazzle-develop/zig/lib/std", .kind = .directory, .mode = 0o755 },
        .{ .name = "dazzle-develop/dazzle-develop", .kind = .file, .mode = 0o755 },
        .{ .name = "dazzle-develop/dazzle-develop.icon", .kind = .file, .mode = 0o644 },
        .{ .name = "dazzle-develop/zig/zig", .kind = .file, .mode = 0o755 },
        .{ .name = "dazzle-develop/zig/lib/std/std.zig", .kind = .file, .mode = 0o644 },
    };
    var seen: usize = 0;
    while (try it.next()) |f| : (seen += 1) {
        try std.testing.expectEqualStrings(want[seen].name, std.mem.trimEnd(u8, f.name, "/"));
        try std.testing.expectEqual(want[seen].kind, f.kind);
        if (f.kind == .file) try std.testing.expectEqual(want[seen].mode, f.mode & 0o777);
    }
    try std.testing.expectEqual(want.len, seen);
}

