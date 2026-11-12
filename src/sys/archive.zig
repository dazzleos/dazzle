//! Unpacking what is downloaded: an xz-compressed tar archive of one
//! folder (an app's, or an OS slot's). Only the folder's own files and
//! folders are taken, nothing outside it and no links, so an archive cannot
//! write anywhere else.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The most an archive may hold, unpacked.
pub const max_unpacked = 512 * 1024 * 1024;

/// Unpacks `archive` (the folder `root`, as tar compressed with xz) into
/// `dest`, which must be there: `root/a/b` becomes `dest/a/b`. Files are
/// 0755 if they can be run in the archive, else 0644 (as far as the
/// filesystem keeps modes), and written to the card before this returns.
pub fn extract(gpa: std.mem.Allocator, archive: []const u8, root: []const u8, dest: []const u8) !void {
    var input: std.Io.Reader = .fixed(archive);
    var xz = std.compress.xz.Decompress.init(&input, gpa, &.{}) catch return error.BadArchive;
    defer xz.deinit();

    var tar_buf: [1024]u8 = undefined;
    var xz_reader: XzReader = .{
        .xz = &xz,
        .interface = .{
            .vtable = &.{ .stream = XzReader.stream, .discard = XzReader.discard },
            .buffer = &tar_buf,
            .seek = 0,
            .end = 0,
        },
    };
    var file_name_buf: [256]u8 = undefined;
    var link_name_buf: [256]u8 = undefined;
    var it: std.tar.Iterator = .init(&xz_reader.interface, .{ .file_name_buffer = &file_name_buf, .link_name_buffer = &link_name_buf });
    while (it.next() catch return xzError(&xz)) |f| {
        const name = std.mem.trimEnd(u8, f.name, "/");
        const rel = inside(name, root) orelse return error.BadArchive;
        if (rel.len == 0) {
            if (f.kind != .directory) return error.BadArchive;
            continue;
        }
        var path_buf: [512]u8 = undefined;
        const path = std.mem.printSentinel(&path_buf, "{s}/{s}", .{ dest, rel }, 0) catch return error.BadArchive;
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
                it.streamRemaining(f, &fw.interface) catch return if (fw.failed) error.WriteFailed else xzError(&xz);
                fw.interface.flush() catch return error.WriteFailed;
                _ = try sys.check(linux.fsync(fd));
            },
            // No links: what is downloaded is plain files.
            else => return error.BadArchive,
        }
    }
}

fn xzError(xz: *const std.compress.xz.Decompress) error{ OutOfMemory, BadArchive } {
    if (xz.err) |e| if (e == error.OutOfMemory) return error.OutOfMemory;
    return error.BadArchive;
}

/// Streams decompressed XZ blocks one at a time into `std.tar.Iterator`,
/// reusing `xz.reader.buffer` across blocks and implementing `discard`.
const XzReader = struct {
    xz: *std.compress.xz.Decompress,
    unpacked: usize = 0,
    interface: std.Io.Reader,

    fn fillBlock(self: *XzReader) std.Io.Reader.Error![]const u8 {
        const r = &self.xz.reader;
        while (r.seek == r.end) {
            r.seek = 0;
            r.end = 0;
            _ = try r.vtable.readVec(r, &.{});
            self.unpacked +|= r.end;
            if (self.unpacked > max_unpacked) return error.ReadFailed;
        }
        return r.buffer[r.seek..r.end];
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *XzReader = @alignCast(@fieldParentPtr("interface", r));
        const avail = try self.fillBlock();
        const slice = limit.sliceConst(avail);
        const n = try w.write(slice);
        self.xz.reader.seek += n;
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *XzReader = @alignCast(@fieldParentPtr("interface", r));
        const avail = try self.fillBlock();
        const n = limit.minInt(avail.len);
        self.xz.reader.seek += n;
        return n;
    }
};

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
