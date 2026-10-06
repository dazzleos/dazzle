//! Screenshots: Print Screen saves the screen as a PNG file in the user's
//! Screenshots folder (/data/user/Screenshots), named "Screenshot 1.png",
//! "Screenshot 2.png" and so on.
//!
//! The pixels are read back from the GPU in the shell (see
//! `render.Renderer.capture`); a child process compresses and writes them,
//! so the shell goes on drawing meanwhile.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const png = @import("png.zig");

/// Print Screen (KEY_SYSRQ, a Linux key code).
pub const key_print = 99;

/// Where screenshots go.
pub const folder = sys.system.user_dir ++ "/Screenshots";

/// Saves `pixels` (`width` by `height`) in `dir` as the next unused
/// "Screenshot N.png", in a child process. Takes `pixels` (allocated with
/// `gpa`).
pub fn save(gpa: std.mem.Allocator, dir: []const u8, pixels: []u32, width: u32, height: u32) void {
    defer gpa.free(pixels);
    var dir_buf: [256]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir}) catch return;
    _ = linux.mkdir(dir_z, 0o755);
    var path_buf: [512]u8 = undefined;
    const path = nextName(&path_buf, dir) orelse {
        sys.print("dazzle-shell: no name for a screenshot in {s}\n", .{dir});
        return;
    };
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) {
            sys.print("dazzle-shell: saving a screenshot as {s}\n", .{path});
            return;
        },
        else => |e| {
            sys.print("dazzle-shell: cannot save a screenshot ({s})\n", .{@tagName(e)});
            return;
        },
    }
    // The child: encode, write, and go.
    const ok = write(gpa, path, pixels, width, height);
    if (ok) sys.print("dazzle-shell: saved {s}\n", .{path});
    linux.exit(if (ok) 0 else 1);
}

fn write(gpa: std.mem.Allocator, path: [:0]const u8, pixels: []const u32, width: u32, height: u32) bool {
    const data = png.encode(gpa, pixels, width, height) catch |err| {
        sys.print("dazzle-shell: cannot make a screenshot: {s}\n", .{@errorName(err)});
        return false;
    };
    const fd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }) catch |err| {
        sys.print("dazzle-shell: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer sys.close(fd);
    _ = linux.fchmod(fd, 0o644);
    var at: usize = 0;
    while (at < data.len) {
        const n = sys.check(linux.write(fd, data[at..].ptr, data.len - at)) catch |err| {
            sys.print("dazzle-shell: cannot write {s}: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        at += n;
    }
    return true;
}

/// "<dir>/Screenshot N.png" for the first N not taken (a number is taken
/// by any file starting "Screenshot N" and a space or dot, so files
/// renamed "Screenshot 3 of the dock.png", say, keep theirs).
pub fn nextName(buf: []u8, dir: []const u8) ?[:0]const u8 {
    var n: u32 = 1;
    while (n < 100_000) : (n += 1) {
        if (taken(dir, n)) continue;
        return std.fmt.bufPrintZ(buf, "{s}/Screenshot {d}.png", .{ dir, n }) catch null;
    }
    return null;
}

/// Whether a screenshot numbered `n` is in `dir`.
fn taken(dir: []const u8, n: u32) bool {
    var z: [256]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch return false;
    const fd = sys.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return false;
    defer sys.close(fd);
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "Screenshot {d}", .{n}) catch return false;
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const len = sys.check(linux.getdents64(fd, &buf, buf.len)) catch return false;
        if (len == 0) return false;
        var at: usize = 0;
        while (at < len) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len and (name[prefix.len] == ' ' or name[prefix.len] == '.')) return true;
        }
    }
}

const testing = std.testing;

test "screenshots are numbered, after those already there" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/dazzle-screenshot-test-{d}", .{linux.getpid()});
    var z: [128]u8 = undefined;
    _ = linux.mkdir(try std.fmt.bufPrintZ(&z, "{s}", .{dir}), 0o755);
    defer _ = linux.rmdir(std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch unreachable);
    var buf: [256]u8 = undefined;
    const first = nextName(&buf, dir).?;
    try testing.expect(std.mem.endsWith(u8, first, "/Screenshot 1.png"));
    var made: [2][128]u8 = undefined;
    const names = [_][:0]const u8{
        try std.fmt.bufPrintZ(&made[0], "{s}/Screenshot 1.png", .{dir}),
        try std.fmt.bufPrintZ(&made[1], "{s}/Screenshot 2 of the dock.png", .{dir}),
    };
    for (names) |p| sys.close(try sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }));
    defer for (names) |p| {
        _ = linux.unlink(p);
    };
    try testing.expect(std.mem.endsWith(u8, nextName(&buf, dir).?, "/Screenshot 3.png"));
}
