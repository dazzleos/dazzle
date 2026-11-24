//! The OS slots on the boot partition (see storage.zig): the image has
//! slot A only, and on the first start the system manager copies the
//! running slot to the other, on a thread while setup runs (`Copier`). The copy is written as slot-<x>.new/ and renamed when it is
//! whole, so a slot that is there is complete. Its cmdline.txt says which
//! slot it is, and its version file what system it holds (see
//! `sys.system.Version`). Updates (update.zig) are written to the slot not
//! running the same way; config.txt's os_prefix says which slot the
//! firmware starts.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const storage = @import("storage.zig");

const print = sys.print;
const proto = sys.system;

const config_file = storage.boot_dir ++ "/config.txt";

const max_files = 64;
const max_name = 64;
/// How much is read at a time.
const chunk = 256 * 1024;

/// A slot's directory: /boot/slot-<slot><suffix>.
pub fn slotPath(buf: []u8, slot: u8, suffix: []const u8) [:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/slot-{c}{s}", .{ storage.boot_dir, slot, suffix }, 0) catch unreachable;
}

fn filePath(buf: []u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch null;
}

pub fn other(slot: u8) u8 {
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

    /// Starts copying the running slot to the other, if the other is not
    /// there; null if there is nothing to do.
    pub fn start(running: u8) !?Copier {
        var c: Copier = .{ .from = running, .to = other(running) };
        var buf: [96]u8 = undefined;
        if (storage.exists(slotPath(&buf, c.to, ""))) return null;
        const src_dir = sys.open(slotPath(&buf, c.from, ""), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return null;
        defer sys.close(src_dir);
        try c.list(src_dir, "");
        try remount(false);
        errdefer remount(true) catch {};
        // What an earlier start left of a copy, then a new one.
        removeDir(slotPath(&buf, c.to, ".new"));
        _ = try sys.check(linux.mkdir(slotPath(&buf, c.to, ".new"), 0o755));
        print("dazzle: system: copying OS slot {c} to slot {c}\n", .{ std.ascii.toUpper(c.from), std.ascii.toUpper(c.to) });
        return c;
    }

    /// Lists the slot's files, and those in its folders (overlays/), as
    /// paths in the slot.
    fn list(c: *Copier, dir: linux.fd_t, prefix: []const u8) !void {
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
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                var path_buf: [max_name]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ prefix, name }) catch return error.TooManyFiles;
                const dt_dir = 4;
                const dt_reg = 8;
                if (kind == dt_dir and prefix.len == 0) {
                    var name_z: [max_name + 1]u8 = undefined;
                    @memcpy(name_z[0..name.len], name);
                    name_z[name.len] = 0;
                    const sub: linux.fd_t = @intCast(try sys.check(linux.openat(dir, name_z[0..name.len :0], .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)));
                    defer sys.close(sub);
                    var sub_prefix: [max_name]u8 = undefined;
                    try c.list(sub, std.fmt.bufPrint(&sub_prefix, "{s}/", .{name}) catch return error.TooManyFiles);
                    continue;
                }
                if (kind != dt_reg) continue;
                if (c.count == max_files) return error.TooManyFiles;
                @memcpy(c.names[c.count][0..path.len], path);
                c.lens[c.count] = path.len;
                c.count += 1;
            }
        }
    }

    fn fileName(c: *const Copier, i: usize) []const u8 {
        return c.names[i][0..c.lens[i]];
    }

    /// Copies the files, and puts the copy in place (the boot partition
    /// is read-only again after, whatever happens).
    pub fn run(c: *Copier) !void {
        defer remount(true) catch {};
        const buf = try std.heap.page_allocator.alloc(u8, chunk);
        defer std.heap.page_allocator.free(buf);
        for (0..c.count) |i| try c.copyFile(c.fileName(i), buf);
        var new_buf: [96]u8 = undefined;
        var to_buf: [96]u8 = undefined;
        _ = try sys.check(linux.rename(slotPath(&new_buf, c.to, ".new"), slotPath(&to_buf, c.to, "")));
        if (sys.open(storage.boot_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true })) |dir| {
            _ = linux.fsync(dir);
            sys.close(dir);
        } else |_| {}
        print("dazzle: system: made OS slot {c}\n", .{std.ascii.toUpper(c.to)});
    }

    /// Copies the file `name` (a path in the slot) to the copy.
    fn copyFile(c: *Copier, name: []const u8, buf: []u8) !void {
        var from_buf: [96]u8 = undefined;
        var to_buf: [96]u8 = undefined;
        var path_buf: [192]u8 = undefined;
        const from_dir = slotPath(&from_buf, c.from, "");
        const to_dir = slotPath(&to_buf, c.to, ".new");
        // A file in a folder: the folder first.
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
            const sub = filePath(&path_buf, to_dir, name[0..slash]) orelse return error.NameTooLong;
            switch (linux.errno(linux.mkdir(sub, 0o755))) {
                .SUCCESS, .EXIST => {},
                else => |e| return sys.errorFromErrno(e),
            }
        }
        const src = try sys.open(filePath(&path_buf, from_dir, name) orelse return error.NameTooLong, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        defer sys.close(src);
        const dst = try sys.open(filePath(&path_buf, to_dir, name) orelse return error.NameTooLong, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
        defer sys.close(dst);
        if (std.mem.eql(u8, name, "cmdline.txt")) {
            // The command line says which slot it is.
            var text: [1024]u8 = undefined;
            var out: [1024 + 16]u8 = undefined;
            const len = try sys.check(linux.read(src, &text, text.len));
            try writeAll(dst, retarget(text[0..len], c.to, &out));
        } else while (true) {
            const len = try sys.check(linux.read(src, buf.ptr, buf.len));
            if (len == 0) break;
            try writeAll(dst, buf[0..len]);
        }
        _ = try sys.check(linux.fsync(dst));
    }

    /// Gives up before `run` (the boot partition is read-only again).
    pub fn deinit(_: *Copier) void {
        remount(true) catch {};
    }
};

fn writeAll(fd: linux.fd_t, data: []const u8) !void {
    var at: usize = 0;
    while (at < data.len) at += try sys.check(linux.write(fd, data[at..].ptr, data.len - at));
}

/// Makes the boot partition read-only, or writable.
pub fn remount(read_only: bool) !void {
    const flags = linux.MS.REMOUNT | linux.MS.NODEV | linux.MS.NOSUID | @as(u32, if (read_only) linux.MS.RDONLY else 0);
    _ = try sys.check(linux.mount(null, storage.boot_dir, null, flags, @intFromPtr(storage.boot_options)));
}

/// Removes a directory and what is in it, if it is there.
fn removeDir(path: [:0]const u8) void {
    sys.files.removeTree(path);
}

/// What `slot` holds (its version file); null if it is not there or says
/// nothing readable.
pub fn version(slot: u8) ?proto.Version {
    var dir_buf: [96]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const path = filePath(&path_buf, slotPath(&dir_buf, slot, ""), proto.Version.file_name) orelse return null;
    var buf: [64]u8 = undefined;
    return proto.Version.parse(sys.readFile(path, &buf) orelse return null);
}

/// The slot the firmware starts next (config.txt's os_prefix).
pub fn next() ?u8 {
    const gpa = std.heap.page_allocator;
    const text = sys.readFileAlloc(gpa, config_file, 1024 * 1024) catch return null;
    defer gpa.free(text);
    return osPrefix(text);
}

/// Has the firmware start `slot` next time: config.txt's os_prefix
/// changed, written as config.txt.new, then renamed over it. The boot
/// partition must be writable.
pub fn startNext(slot: u8) !void {
    const gpa = std.heap.page_allocator;
    const text = try sys.readFileAlloc(gpa, config_file, 1024 * 1024);
    defer gpa.free(text);
    const out = try gpa.alloc(u8, text.len + 128);
    defer gpa.free(out);
    const changed = setOsPrefix(text, slot, out);
    const tmp = config_file ++ ".new";
    _ = linux.unlink(tmp);
    const fd = try sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
    defer sys.close(fd);
    try writeAll(fd, changed);
    _ = try sys.check(linux.fsync(fd));
    _ = try sys.check(linux.rename(tmp, config_file));
    if (sys.open(storage.boot_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true })) |dir| {
        _ = linux.fsync(dir);
        sys.close(dir);
    } else |_| {}
}

const os_prefix_key = "os_prefix=slot-";

/// The slot in config.txt's "os_prefix=slot-<x>/" line.
pub fn osPrefix(config: []const u8) ?u8 {
    var lines = std.mem.splitScalar(u8, config, '\n');
    var found: ?u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, os_prefix_key) or line.len < os_prefix_key.len + 1) continue;
        const s = line[os_prefix_key.len];
        // The last one counts, as for the firmware.
        if (s == 'a' or s == 'b') found = s;
    }
    return found;
}

/// Settings an update brings to config.txt on cards made before it (each
/// added if the card does not set it at all).
const added_settings = [_][]const u8{
    // The firmware's wait before starting the kernel (a second by default).
    "boot_delay=0",
    // A display on the DSI connector, found by the firmware (its overlay).
    "display_auto_detect=1",
};

/// Settings an update takes out of config.txt on cards made before it.
const removed_settings = [_][]const u8{
    // Passed on to the Touch Display 2's overlay by the firmware: without
    // its touch controller.
    "disable_touchscreen=1",
};

/// config.txt with its os_prefix lines for `slot` (or one added), the
/// settings it does not have yet (`added_settings`), and without those
/// taken out (`removed_settings`).
pub fn setOsPrefix(config: []const u8, slot: u8, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    var found = false;
    var has: [added_settings.len]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, config, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const removed = for (removed_settings) |r| {
            if (std.mem.eql(u8, line, r)) break true;
        } else false;
        if (removed) continue;
        if (!first) w.writeByte('\n') catch {};
        first = false;
        for (added_settings, &has) |setting, *h| {
            const key = setting[0 .. std.mem.indexOfScalar(u8, setting, '=').? + 1];
            if (std.mem.startsWith(u8, line, key)) h.* = true;
        }
        if (std.mem.startsWith(u8, line, "os_prefix=")) {
            w.print("os_prefix=slot-{c}/", .{slot}) catch {};
            found = true;
        } else w.writeAll(raw) catch {};
    }
    if (!found) {
        if (w.end > 0 and out[w.end - 1] != '\n') w.writeByte('\n') catch {};
        w.print("os_prefix=slot-{c}/\n", .{slot}) catch {};
    }
    for (added_settings, has) |setting, h| if (!h) {
        if (w.end > 0 and out[w.end - 1] != '\n') w.writeByte('\n') catch {};
        w.print("{s}\n", .{setting}) catch {};
    };
    return w.buffered();
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

/// The video memory a kernel command line gives (its cma=), in MiB; null
/// if it gives none (the device tree's then) or one not in whole MiB.
pub fn cmaMiB(cmdline: []const u8) ?u16 {
    const key = "cma=";
    var found: ?u16 = null;
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (it.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, key)) continue;
        const v = arg[key.len..];
        if (v.len < 2) continue;
        const n = std.fmt.parseInt(u32, v[0 .. v.len - 1], 10) catch continue;
        // The last one counts, as for the kernel.
        found = switch (v[v.len - 1]) {
            'M', 'm' => std.math.cast(u16, n),
            'G', 'g' => std.math.cast(u16, n * 1024),
            else => null,
        };
    }
    return found;
}

/// A kernel command line with cma= set to `mib` MiB (changed, or added).
pub fn setCma(cmdline: []const u8, mib: u16, out: []u8) []const u8 {
    const key = "cma=";
    var w: std.Io.Writer = .fixed(out);
    var found = false;
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    var first = true;
    while (it.next()) |arg| {
        const is_cma = std.mem.startsWith(u8, arg, key);
        // Only one.
        if (is_cma and found) continue;
        if (!first) w.writeByte(' ') catch {};
        first = false;
        if (is_cma) {
            w.print("{s}{d}M", .{ key, mib }) catch {};
            found = true;
        } else w.writeAll(arg) catch {};
    }
    if (!found) w.print("{s}{s}{d}M", .{ if (first) "" else " ", key, mib }) catch {};
    w.writeByte('\n') catch {};
    return w.buffered();
}

/// The video memory `slot` starts with (its cmdline.txt's cma=).
pub fn videoMemory(slot: u8) ?u16 {
    var dir_buf: [96]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const path = filePath(&path_buf, slotPath(&dir_buf, slot, ""), "cmdline.txt") orelse return null;
    var buf: [1024]u8 = undefined;
    return cmaMiB(sys.readFile(path, &buf) orelse return null);
}

/// Has both slots start with `mib` MiB of video memory: each one's
/// cmdline.txt changed, written as cmdline.txt.new, then renamed over it
/// (both, so it holds whichever starts: the one running, an update, or the
/// one before if an update does not work). The boot partition must be
/// writable.
pub fn setVideoMemory(mib: u16) !void {
    var wrote = false;
    for ("ab") |slot| {
        var dir_buf: [96]u8 = undefined;
        var path_buf: [128]u8 = undefined;
        var tmp_buf: [128]u8 = undefined;
        const dir = slotPath(&dir_buf, slot, "");
        const path = filePath(&path_buf, dir, "cmdline.txt") orelse return error.NameTooLong;
        var buf: [1024]u8 = undefined;
        const cmdline = sys.readFile(path, &buf) orelse continue;
        var out: [1024 + 16]u8 = undefined;
        const changed = setCma(cmdline, mib, &out);
        const tmp = filePath(&tmp_buf, dir, "cmdline.txt.new") orelse return error.NameTooLong;
        _ = linux.unlink(tmp);
        const fd = try sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
        {
            defer sys.close(fd);
            try writeAll(fd, changed);
            _ = try sys.check(linux.fsync(fd));
        }
        _ = try sys.check(linux.rename(tmp, path));
        if (sys.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true })) |d| {
            _ = linux.fsync(d);
            sys.close(d);
        } else |_| {}
        wrote = true;
    }
    if (!wrote) return error.NotFound;
}

test "the command line's cma= is the video memory" {
    try std.testing.expectEqual(@as(?u16, 128), cmaMiB("loglevel=6 cma=128M rdinit=/os/init\n"));
    try std.testing.expectEqual(@as(?u16, 1024), cmaMiB("cma=1G"));
    try std.testing.expectEqual(@as(?u16, 256), cmaMiB("cma=64M cma=256M"));
    try std.testing.expectEqual(@as(?u16, null), cmaMiB("loglevel=6"));
    try std.testing.expectEqual(@as(?u16, null), cmaMiB("cma=65536K"));
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("loglevel=6 cma=256M rdinit=/os/init dazzle.slot=a\n", setCma("loglevel=6 cma=128M rdinit=/os/init dazzle.slot=a\n", 256, &out));
    try std.testing.expectEqualStrings("loglevel=6 cma=64M\n", setCma("loglevel=6\n", 64, &out));
    try std.testing.expectEqualStrings("cma=96M x\n", setCma("cma=1G x cma=64M", 96, &out));
    try std.testing.expectEqualStrings("cma=192M\n", setCma("", 192, &out));
}

test "config.txt's os_prefix picks the slot" {
    const config = "# Dazzle\narm_64bit=0\nos_prefix=slot-a/\ncamera_auto_detect=1\n";
    try std.testing.expectEqual(@as(?u8, 'a'), osPrefix(config));
    var out: [256]u8 = undefined;
    var first: [256]u8 = undefined;
    const changed = setOsPrefix(config, 'b', &first);
    // A card made before: the settings it lacks are added.
    try std.testing.expectEqualStrings("# Dazzle\narm_64bit=0\nos_prefix=slot-b/\ncamera_auto_detect=1\nboot_delay=0\ndisplay_auto_detect=1\n", changed);
    try std.testing.expectEqual(@as(?u8, 'b'), osPrefix(changed));
    try std.testing.expectEqual(@as(?u8, null), osPrefix("arm_64bit=0\n"));
    try std.testing.expectEqualStrings("arm_64bit=0\nos_prefix=slot-a/\nboot_delay=0\ndisplay_auto_detect=1\n", setOsPrefix("arm_64bit=0", 'a', &out));
    // Set already (to whatever): left as it is, and not added twice.
    try std.testing.expectEqualStrings("boot_delay=2\nos_prefix=slot-b/\ndisplay_auto_detect=1\n", setOsPrefix("boot_delay=2\nos_prefix=slot-a/\n", 'b', &out));
    var again: [256]u8 = undefined;
    try std.testing.expectEqualStrings(changed, setOsPrefix(changed, 'b', &again));
    // Taken out.
    try std.testing.expectEqualStrings("os_prefix=slot-b/\nboot_delay=0\ndisplay_auto_detect=1\n", setOsPrefix("os_prefix=slot-a/\ndisable_touchscreen=1\nboot_delay=0\ndisplay_auto_detect=1\n", 'b', &again));
}

test "a slot's command line says which slot it is" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("loglevel=6 dazzle.slot=b rdinit=/os/init\n", retarget("loglevel=6 dazzle.slot=a rdinit=/os/init\n", 'b', &out));
    try std.testing.expectEqualStrings("loglevel=6 dazzle.slot=a\n", retarget("loglevel=6\n", 'a', &out));
    try std.testing.expectEqualStrings("dazzle.slot=b\n", retarget("", 'b', &out));
}
