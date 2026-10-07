//! Saving the user's files: names numbered after those already there
//! ("Screenshot 3.png", "Photo 12.png"), writing a new file whole, and
//! removing a directory with what is in it.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// "<dir>/<prefix> N.<ext>" for the first N not taken (a number is taken
/// by any file starting "<prefix> N" and a space or dot, so files renamed
/// "Screenshot 3 of the dock.png", say, keep theirs).
pub fn numberedName(buf: []u8, dir: []const u8, prefix: []const u8, ext: []const u8) ?[:0]const u8 {
    var n: u32 = 1;
    while (n < 100_000) : (n += 1) {
        if (taken(dir, prefix, n)) continue;
        return std.fmt.bufPrintZ(buf, "{s}/{s} {d}.{s}", .{ dir, prefix, n, ext }) catch null;
    }
    return null;
}

/// Whether a file numbered `n` is in `dir`.
fn taken(dir: []const u8, prefix: []const u8, n: u32) bool {
    var z: [256]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch return false;
    const fd = sys.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return false;
    defer sys.close(fd);
    var numbered_buf: [64]u8 = undefined;
    const numbered = std.fmt.bufPrint(&numbered_buf, "{s} {d}", .{ prefix, n }) catch return false;
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const len = sys.check(linux.getdents64(fd, &buf, buf.len)) catch return false;
        if (len == 0) return false;
        var at: usize = 0;
        while (at < len) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (std.mem.startsWith(u8, name, numbered) and name.len > numbered.len and (name[numbered.len] == ' ' or name[numbered.len] == '.')) return true;
        }
    }
}

/// Writes `data` to `path`, a file that must not be there yet, readable by
/// all.
pub fn writeNew(path: [:0]const u8, data: []const u8) sys.Error!void {
    const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
    defer sys.close(fd);
    _ = linux.fchmod(fd, 0o644);
    var at: usize = 0;
    while (at < data.len) at += try sys.check(linux.write(fd, data[at..].ptr, data.len - at));
}

/// Removes a directory and what is in it, if it is there.
pub fn removeTree(path: [:0]const u8) void {
    // Removing entries while reading a directory can skip some (on FAT,
    // say): another pass takes those.
    for (0..8) |_| {
        const dir = sys.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch {
            _ = linux.unlink(path);
            return;
        };
        var buf: [2048]u8 align(8) = undefined;
        while (true) {
            const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch break;
            if (n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                const kind = buf[at + 18];
                const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
                at += reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                var child_buf: [512]u8 = undefined;
                const child = std.fmt.bufPrintZ(&child_buf, "{s}/{s}", .{ path, name }) catch continue;
                if (kind == 4) removeTree(child) else _ = linux.unlink(child);
            }
        }
        sys.close(dir);
        if (linux.errno(linux.rmdir(path)) != .NOTEMPTY) return;
    }
}

const testing = std.testing;

test "names are numbered, after those already there" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/dazzle-names-test-{d}", .{linux.getpid()});
    var z: [128]u8 = undefined;
    _ = linux.mkdir(try std.fmt.bufPrintZ(&z, "{s}", .{dir}), 0o755);
    defer _ = linux.rmdir(std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch unreachable);
    var buf: [256]u8 = undefined;
    const first = numberedName(&buf, dir, "Screenshot", "png").?;
    try testing.expect(std.mem.endsWith(u8, first, "/Screenshot 1.png"));
    var made: [3][128]u8 = undefined;
    const names = [_][:0]const u8{
        try std.fmt.bufPrintZ(&made[0], "{s}/Screenshot 1.png", .{dir}),
        try std.fmt.bufPrintZ(&made[1], "{s}/Screenshot 2 of the dock.png", .{dir}),
        try std.fmt.bufPrintZ(&made[2], "{s}/Photo 1.png", .{dir}),
    };
    defer for (names) |p| {
        _ = linux.unlink(p);
    };
    try writeNew(names[0], "png");
    try testing.expectError(error.Unexpected, writeNew(names[0], "again"));
    for (names[1..]) |p| try writeNew(p, "");
    try testing.expect(std.mem.endsWith(u8, numberedName(&buf, dir, "Screenshot", "png").?, "/Screenshot 3.png"));
    try testing.expect(std.mem.endsWith(u8, numberedName(&buf, dir, "Photo", "png").?, "/Photo 2.png"));
}
