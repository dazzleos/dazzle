//! Builds the initramfs: a "newc" cpio archive containing the directories
//! the init program mounts over, a /dev/console node (the kernel opens it
//! for PID 1's stdio before devtmpfs is mounted), the init binary, the
//! shell, and the apps (which the shell's dock lists), each in a directory
//! of its own with everything it needs (the system provides nothing else).
//! Everything is owned by root:
//!
//!     /init                                     dazzle-init
//!     /shell/dazzle-shell
//!     /shell/FiraSans-Regular.ttf
//!     /shell/FiraSans-OFL.txt
//!     /apps/<app>/<app>                         for each app binary
//!     /apps/<app>/FiraSans-Regular.ttf
//!     /apps/<app>/FiraSans-OFL.txt
//!     /dev, /proc, /sys                         mount points
//!
//!     /lib/firmware/brcm/...                    the Wi-Fi chips' firmware
//!
//! An app is named after its binary (dazzle-demo, dazzle-settings).
//! Other files are given as --file=<path in the archive>=<file>.
//!
//! Usage: mkinitramfs <output.cpio> <init-binary> <shell-binary> <font> <font-license> [<app-binary> | --file=<path>=<file>]...

const std = @import("std");

const Entry = struct {
    name: []const u8,
    mode: u32,
    data: []const u8 = "",
    rdev_major: u32 = 0,
    rdev_minor: u32 = 0,
};

const S_IFDIR = 0o040000;
const S_IFREG = 0o100000;
const S_IFCHR = 0o020000;

fn writeEntry(out: *std.ArrayList(u8), gpa: std.mem.Allocator, ino: u32, e: Entry) !void {
    var header: [110]u8 = undefined;
    _ = try std.fmt.bufPrint(&header, "070701" ++ "{x:0>8}" ** 13, .{
        ino,
        e.mode,
        0, // uid
        0, // gid
        if (e.mode & S_IFDIR != 0) @as(u32, 2) else 1, // nlink
        0, // mtime: fixed so builds are reproducible
        @as(u32, @intCast(e.data.len)),
        0, // devmajor
        0, // devminor
        e.rdev_major,
        e.rdev_minor,
        @as(u32, @intCast(e.name.len + 1)),
        0, // check
    });
    try out.appendSlice(gpa, &header);
    try out.appendSlice(gpa, e.name);
    try out.append(gpa, 0);
    try out.appendNTimes(gpa, 0, pad4(out.items.len));
    try out.appendSlice(gpa, e.data);
    try out.appendNTimes(gpa, 0, pad4(out.items.len));
}

fn pad4(len: usize) usize {
    return std.mem.alignForward(usize, len, 4) - len;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 6) {
        std.debug.print("usage: {s} <output.cpio> <init-binary> <shell-binary> <font> <font-license> [<app-binary> | --file=<path>=<file>]...\n", .{args[0]});
        std.process.exit(2);
    }
    const arena = init.arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const init_bin = try cwd.readFileAlloc(io, args[2], gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(init_bin);
    const shell_bin = try cwd.readFileAlloc(io, args[3], gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(shell_bin);
    const font = try cwd.readFileAlloc(io, args[4], gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(font);
    const font_license = try cwd.readFileAlloc(io, args[5], gpa, .limited(1024 * 1024));
    defer gpa.free(font_license);

    var entries: std.ArrayList(Entry) = .empty;
    try entries.appendSlice(arena, &.{
        .{ .name = "dev", .mode = S_IFDIR | 0o755 },
        .{ .name = "dev/console", .mode = S_IFCHR | 0o600, .rdev_major = 5, .rdev_minor = 1 },
        .{ .name = "proc", .mode = S_IFDIR | 0o755 },
        .{ .name = "sys", .mode = S_IFDIR | 0o755 },
        .{ .name = "init", .mode = S_IFREG | 0o755, .data = init_bin },
        .{ .name = "shell", .mode = S_IFDIR | 0o755 },
        .{ .name = "shell/dazzle-shell", .mode = S_IFREG | 0o755, .data = shell_bin },
        .{ .name = "shell/FiraSans-Regular.ttf", .mode = S_IFREG | 0o644, .data = font },
        .{ .name = "shell/FiraSans-OFL.txt", .mode = S_IFREG | 0o644, .data = font_license },
        .{ .name = "apps", .mode = S_IFDIR | 0o755 },
    });
    for (args[6..]) |path| {
        // Another file: --file=<path in the archive>=<file>, its
        // directories made as needed.
        if (std.mem.startsWith(u8, path, "--file=")) {
            const spec = path["--file=".len..];
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadFileArgument;
            const dest = spec[0..eq];
            var parent: usize = 0;
            while (std.mem.indexOfScalarPos(u8, dest, parent, '/')) |slash| : (parent = slash + 1) {
                const dir = dest[0..slash];
                for (entries.items) |e| {
                    if (std.mem.eql(u8, e.name, dir)) break;
                } else try entries.append(arena, .{ .name = dir, .mode = S_IFDIR | 0o755 });
            }
            const data = try cwd.readFileAlloc(io, spec[eq + 1 ..], arena, .limited(16 * 1024 * 1024));
            try entries.append(arena, .{ .name = dest, .mode = S_IFREG | 0o644, .data = data });
            continue;
        }
        const name = std.fs.path.basename(path);
        const bin = try cwd.readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024));
        try entries.appendSlice(arena, &.{
            .{ .name = try std.fmt.allocPrint(arena, "apps/{s}", .{name}), .mode = S_IFDIR | 0o755 },
            .{ .name = try std.fmt.allocPrint(arena, "apps/{s}/{s}", .{ name, name }), .mode = S_IFREG | 0o755, .data = bin },
            .{ .name = try std.fmt.allocPrint(arena, "apps/{s}/FiraSans-Regular.ttf", .{name}), .mode = S_IFREG | 0o644, .data = font },
            .{ .name = try std.fmt.allocPrint(arena, "apps/{s}/FiraSans-OFL.txt", .{name}), .mode = S_IFREG | 0o644, .data = font_license },
        });
    }
    try entries.append(arena, .{ .name = "TRAILER!!!", .mode = 0 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (entries.items, 1..) |e, ino| try writeEntry(&out, gpa, @intCast(ino), e);
    // Pad the archive to a 512-byte block like cpio(1) does.
    try out.appendNTimes(gpa, 0, std.mem.alignForward(usize, out.items.len, 512) - out.items.len);

    const file = try cwd.createFile(io, args[1], .{});
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);
}
