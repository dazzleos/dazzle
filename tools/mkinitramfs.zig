//! Builds the initramfs: a "newc" cpio archive containing the directories
//! the init program mounts over, a /dev/console node (the kernel opens it
//! for PID 1's stdio before devtmpfs is mounted), the init binary, the
//! shell, and the font every program shares: one OS slot's system. The
//! apps are not in it: there is one copy of them on the card's boot
//! partition, whatever the slot, which init copies to /data/apps (where
//! more are installed) and shows at /apps.
//! Dazzle's own files are in /os; everything is owned by root, but for
//! /os/sockets (the Dazzle user's, for its programs' sockets):
//!
//!     /os/init                                  dazzle-init (rdinit=/os/init)
//!     /os/shell/dazzle-shell
//!     /os/shell/<program>                       the shell's own apps
//!     /os/fonts/FiraSans-Regular.ttf            the font, shared
//!     /os/fonts/FiraSans-OFL.txt                its licence
//!     /os/firmware/brcm/...                     the Wi-Fi chips' firmware
//!                                               (firmware_class.path=/os/firmware)
//!     /os/certs/ca-certificates.pem             the certificate authorities
//!                                               HTTPS trusts (Mozilla's)
//!     /os/sockets/                              (empty)
//!     /etc/resolv.conf                          (empty; the user's: the
//!                                               network manager writes it)
//!     /dev, /proc, /sys, /data, /boot, /apps    mount points
//!
//! The shell's own apps (dazzle-settings, dazzle-setup), which cannot be
//! removed, go beside it: --shell=<binary>. Other files are given as
//! --file=<path in the archive>=<file>.
//!
//! Usage: mkinitramfs <output.cpio> <init-binary> <shell-binary> <font> <font-license> [--shell=<binary> | --file=<path>=<file>]...

const std = @import("std");

const Entry = struct {
    name: []const u8,
    mode: u32,
    data: []const u8 = "",
    rdev_major: u32 = 0,
    rdev_minor: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
};

/// The Dazzle user (sys.user).
const user_id = 1000;

const S_IFDIR = 0o040000;
const S_IFREG = 0o100000;
const S_IFCHR = 0o020000;

fn writeEntry(out: *std.ArrayList(u8), gpa: std.mem.Allocator, ino: u32, e: Entry) !void {
    var header: [110]u8 = undefined;
    _ = try std.fmt.bufPrint(&header, "070701" ++ "{x:0>8}" ** 13, .{
        ino,
        e.mode,
        e.uid,
        e.gid,
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
        std.debug.print("usage: {s} <output.cpio> <init-binary> <shell-binary> <font> <font-license> [--shell=<binary> | --file=<path>=<file>]...\n", .{args[0]});
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
        .{ .name = "data", .mode = S_IFDIR | 0o755 },
        .{ .name = "os", .mode = S_IFDIR | 0o755 },
        .{ .name = "os/init", .mode = S_IFREG | 0o755, .data = init_bin },
        .{ .name = "os/shell", .mode = S_IFDIR | 0o755 },
        .{ .name = "os/shell/dazzle-shell", .mode = S_IFREG | 0o755, .data = shell_bin },
        .{ .name = "os/fonts", .mode = S_IFDIR | 0o755 },
        .{ .name = "os/fonts/FiraSans-Regular.ttf", .mode = S_IFREG | 0o644, .data = font },
        .{ .name = "os/fonts/FiraSans-OFL.txt", .mode = S_IFREG | 0o644, .data = font_license },
        .{ .name = "os/sockets", .mode = S_IFDIR | 0o700, .uid = user_id, .gid = user_id },
        // The name servers, which the network manager (the user, with
        // network privileges) writes there as it learns them.
        .{ .name = "etc", .mode = S_IFDIR | 0o755 },
        .{ .name = "etc/resolv.conf", .mode = S_IFREG | 0o644, .uid = user_id, .gid = user_id, .data = "" },
        .{ .name = "boot", .mode = S_IFDIR | 0o755 },
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
        // One of the shell's own apps, beside it.
        if (std.mem.startsWith(u8, path, "--shell=")) {
            const bin_path = path["--shell=".len..];
            const bin = try cwd.readFileAlloc(io, bin_path, arena, .limited(64 * 1024 * 1024));
            try entries.append(arena, .{ .name = try std.fmt.allocPrint(arena, "os/shell/{s}", .{std.fs.path.basename(bin_path)}), .mode = S_IFREG | 0o755, .data = bin });
            continue;
        }
        std.debug.print("mkinitramfs: unknown argument {s}\n", .{path});
        return error.BadArgument;
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
