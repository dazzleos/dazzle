//! The OS slots on the boot partition (see storage.zig): the image has
//! slot A only, and on the first start the system manager copies the
//! running slot to the other, a little at a time while setup runs
//! (`Copier`). The copy is written as slot-<x>.new/ and renamed when it is
//! whole, so a slot that is there is complete. Its cmdline.txt says which
//! slot it is.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const storage = @import("storage.zig");

const print = sys.print;

const max_files = 16;
const max_name = 64;
/// How much a step copies.
const chunk = 256 * 1024;

/// A slot's directory: /boot/slot-<slot><suffix>.
fn slotPath(buf: []u8, slot: u8, suffix: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/slot-{c}{s}", .{ storage.boot_dir, slot, suffix }) catch unreachable;
}

fn filePath(buf: []u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch null;
}

fn other(slot: u8) u8 {
    return if (slot == 'a') 'b' else 'a';
}

/// Whether the slot other than the running one is still to be made (the
/// running one is there, the other not).
pub fn otherMissing(running: u8) bool {
    var a: [96]u8 = undefined;
    var b: [96]u8 = undefined;
    return storage.exists(slotPath(&a, running, "")) and !storage.exists(slotPath(&b, other(running), ""));
}

pub const Copier = struct {
    from: u8,
    to: u8,
    names: [max_files][max_name]u8 = undefined,
    lens: [max_files]usize = undefined,
    count: usize = 0,
    /// The file being copied, and where.
    index: usize = 0,
    src: ?linux.fd_t = null,
    dst: ?linux.fd_t = null,

    /// Starts copying the running slot to the other, if the other is not
    /// there; null if there is nothing to do.
    pub fn start(running: u8) !?Copier {
        var c: Copier = .{ .from = running, .to = other(running) };
        var buf: [96]u8 = undefined;
        if (storage.exists(slotPath(&buf, c.to, ""))) return null;
        const src_dir = sys.open(slotPath(&buf, c.from, ""), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return null;
        defer sys.close(src_dir);
        try c.list(src_dir);
        try remount(false);
        errdefer remount(true) catch {};
        // What an earlier start left of a copy, then a new one.
        removeDir(slotPath(&buf, c.to, ".new"));
        _ = try sys.check(linux.mkdir(slotPath(&buf, c.to, ".new"), 0o755));
        print("dazzle: system: copying OS slot {c} to slot {c}\n", .{ std.ascii.toUpper(c.from), std.ascii.toUpper(c.to) });
        return c;
    }

    fn list(c: *Copier, dir: linux.fd_t) !void {
        var buf: [2048]u8 align(8) = undefined;
        while (true) {
            const n = try sys.check(linux.getdents64(dir, &buf, buf.len));
            if (n == 0) return;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                const kind = buf[at + 18];
                const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
                at += reclen;
                const dt_reg = 8;
                if (kind != dt_reg) continue;
                if (c.count == max_files or name.len > max_name) return error.TooManyFiles;
                @memcpy(c.names[c.count][0..name.len], name);
                c.lens[c.count] = name.len;
                c.count += 1;
            }
        }
    }

    fn fileName(c: *const Copier, i: usize) []const u8 {
        return c.names[i][0..c.lens[i]];
    }

    /// Copies a little more. Returns whether the copy is done (and in
    /// place).
    pub fn step(c: *Copier) !bool {
        var from_buf: [96]u8 = undefined;
        var to_buf: [96]u8 = undefined;
        var path_buf: [192]u8 = undefined;
        const from_dir = slotPath(&from_buf, c.from, "");
        const to_dir = slotPath(&to_buf, c.to, ".new");
        if (c.src == null) {
            if (c.index == c.count) return try c.finish();
            const n = c.fileName(c.index);
            c.src = try sys.open(filePath(&path_buf, from_dir, n) orelse return error.NameTooLong, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
            c.dst = try sys.open(filePath(&path_buf, to_dir, n) orelse return error.NameTooLong, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
            // The command line says which slot it is.
            if (std.mem.eql(u8, n, "cmdline.txt")) {
                var text: [1024]u8 = undefined;
                var out: [1024 + 16]u8 = undefined;
                const len = try sys.check(linux.read(c.src.?, &text, text.len));
                try writeAll(c.dst.?, retarget(text[0..len], c.to, &out));
                return try c.next();
            }
        }
        const data = struct {
            var buf: [chunk]u8 = undefined;
        };
        const len = try sys.check(linux.read(c.src.?, &data.buf, chunk));
        if (len == 0) return try c.next();
        try writeAll(c.dst.?, data.buf[0..len]);
        return false;
    }

    /// The file is copied: on to the next.
    fn next(c: *Copier) !bool {
        _ = try sys.check(linux.fsync(c.dst.?));
        c.closeFiles();
        c.index += 1;
        return false;
    }

    fn finish(c: *Copier) !bool {
        var new_buf: [96]u8 = undefined;
        var to_buf: [96]u8 = undefined;
        _ = try sys.check(linux.rename(slotPath(&new_buf, c.to, ".new"), slotPath(&to_buf, c.to, "")));
        if (sys.open(storage.boot_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true })) |dir| {
            _ = linux.fsync(dir);
            sys.close(dir);
        } else |_| {}
        try remount(true);
        print("dazzle: system: made OS slot {c}\n", .{std.ascii.toUpper(c.to)});
        return true;
    }

    fn closeFiles(c: *Copier) void {
        if (c.src) |fd| sys.close(fd);
        if (c.dst) |fd| sys.close(fd);
        c.src = null;
        c.dst = null;
    }

    /// Stops (the copy failed): the boot partition is read-only again.
    pub fn deinit(c: *Copier) void {
        c.closeFiles();
        remount(true) catch {};
    }
};

fn writeAll(fd: linux.fd_t, data: []const u8) !void {
    var at: usize = 0;
    while (at < data.len) at += try sys.check(linux.write(fd, data[at..].ptr, data.len - at));
}

/// Makes the boot partition read-only, or writable.
fn remount(read_only: bool) !void {
    const flags = linux.MS.REMOUNT | linux.MS.NODEV | linux.MS.NOSUID | @as(u32, if (read_only) linux.MS.RDONLY else 0);
    _ = try sys.check(linux.mount(null, storage.boot_dir, null, flags, @intFromPtr(storage.boot_options)));
}

/// Removes a directory of files, if it is there.
fn removeDir(path: [:0]const u8) void {
    const dir = sys.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
    defer sys.close(dir);
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch break;
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var nb: [192]u8 = undefined;
            const file = filePath(&nb, path, name) orelse continue;
            _ = linux.unlink(file);
        }
    }
    _ = linux.rmdir(path);
}

/// A kernel command line for slot `to`: its dazzle.slot=, changed or added.
pub fn retarget(cmdline: []const u8, to: u8, out: []u8) []const u8 {
    const key = "dazzle.slot=";
    var w: std.Io.Writer = .fixed(out);
    var found = false;
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    var first = true;
    while (it.next()) |arg| {
        if (!first) w.writeByte(' ') catch {};
        first = false;
        if (std.mem.startsWith(u8, arg, key)) {
            w.print("{s}{c}", .{ key, to }) catch {};
            found = true;
        } else w.writeAll(arg) catch {};
    }
    if (!found) w.print("{s}{s}{c}", .{ if (first) "" else " ", key, to }) catch {};
    w.writeByte('\n') catch {};
    return w.buffered();
}

test "a slot's command line says which slot it is" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("loglevel=6 dazzle.slot=b rdinit=/os/init\n", retarget("loglevel=6 dazzle.slot=a rdinit=/os/init\n", 'b', &out));
    try std.testing.expectEqualStrings("loglevel=6 dazzle.slot=a\n", retarget("loglevel=6\n", 'a', &out));
    try std.testing.expectEqualStrings("dazzle.slot=b\n", retarget("", 'b', &out));
}
