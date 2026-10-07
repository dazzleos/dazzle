//! Unpacking what is downloaded: an xz-compressed tar archive of one
//! folder (an app's, or an OS slot's). Only the folder's own files and
//! folders are taken, nothing outside it and no links, so an archive cannot
//! write anywhere else.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The most an archive may hold, unpacked: it is unpacked in memory.
pub const max_unpacked = 64 * 1024 * 1024;

/// Unpacks `archive` (the folder `root`, as tar compressed with xz) into
/// `dest`, which must be there: `root/a/b` becomes `dest/a/b`. Files are
/// 0755 if they can be run in the archive, else 0644 (as far as the
/// filesystem keeps modes), and written to the card before this returns.
pub fn extract(gpa: std.mem.Allocator, archive: []const u8, root: []const u8, dest: []const u8) !void {
    var input: std.Io.Reader = .fixed(archive);
    var xz = std.compress.xz.Decompress.init(&input, gpa, &.{}) catch return error.BadArchive;
    defer xz.deinit();
    var tar: std.Io.Writer.Allocating = .init(gpa);
    defer tar.deinit();
    _ = xz.reader.streamRemaining(&tar.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else error.BadArchive;
    if (tar.written().len > max_unpacked) return error.BadArchive;

    var tar_reader: std.Io.Reader = .fixed(tar.written());
    var file_name_buf: [256]u8 = undefined;
    var link_name_buf: [256]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_reader, .{ .file_name_buffer = &file_name_buf, .link_name_buffer = &link_name_buf });
    while (it.next() catch return error.BadArchive) |f| {
        const name = std.mem.trimEnd(u8, f.name, "/");
        const rel = inside(name, root) orelse return error.BadArchive;
        if (rel.len == 0) {
            if (f.kind != .directory) return error.BadArchive;
            continue;
        }
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dest, rel }) catch return error.BadArchive;
        switch (f.kind) {
            .directory => switch (linux.errno(linux.mkdir(path, 0o755))) {
                .SUCCESS, .EXIST => {},
                else => |e| return sys.errorFromErrno(e),
            },
            .file => {
                const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
                defer sys.close(fd);
                _ = linux.fchmod(fd, if (f.mode & 0o100 != 0) 0o755 else 0o644);
                var w_buf: [16 * 1024]u8 = undefined;
                var fw: FdWriter = .{ .fd = fd, .interface = .{ .vtable = &.{ .drain = FdWriter.drain }, .buffer = &w_buf } };
                it.streamRemaining(f, &fw.interface) catch return if (fw.failed) error.WriteFailed else error.BadArchive;
                fw.interface.flush() catch return error.WriteFailed;
                _ = try sys.check(linux.fsync(fd));
            },
            // No links: what is downloaded is plain files.
            else => return error.BadArchive,
        }
    }
}

/// `name` relative to the folder `root` ("" for the folder itself); null
/// if it is not in it, or has "." or ".." in it.
fn inside(name: []const u8, root: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, root)) return null;
    if (name.len == root.len) return "";
    if (name[root.len] != '/') return null;
    const rel = name[root.len + 1 ..];
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return null;
    return rel;
}

/// A writer to a file descriptor.
const FdWriter = struct {
    fd: linux.fd_t,
    interface: std.Io.Writer,
    failed: bool = false,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("interface", w);
        try self.writeAll(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.writeAll(d);
            n += d.len;
        }
        for (0..splat) |_| try self.writeAll(data[data.len - 1]);
        return n + data[data.len - 1].len * splat;
    }

    fn writeAll(self: *FdWriter, bytes: []const u8) std.Io.Writer.Error!void {
        var at: usize = 0;
        while (at < bytes.len) at += sys.check(linux.write(self.fd, bytes[at..].ptr, bytes.len - at)) catch {
            self.failed = true;
            return error.WriteFailed;
        };
    }
};

/// Whether `data`'s SHA-256 is `hex` (in hex, either case).
pub fn sha256Is(data: []const u8, hex: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var mine: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&mine, "{x}", .{&digest}) catch unreachable;
    return std.ascii.eqlIgnoreCase(&mine, hex);
}

const testing = std.testing;

test "only what is in the archive's folder" {
    try testing.expectEqualStrings("", inside("os", "os").?);
    try testing.expectEqualStrings("zImage", inside("os/zImage", "os").?);
    try testing.expectEqualStrings("overlays/imx219.dtbo", inside("os/overlays/imx219.dtbo", "os").?);
    try testing.expect(inside("osx/zImage", "os") == null);
    try testing.expect(inside("other/zImage", "os") == null);
    try testing.expect(inside("os/../etc", "os") == null);
    try testing.expect(inside("os//x", "os") == null);
    try testing.expect(inside("os/./x", "os") == null);
}
