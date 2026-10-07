//! Where apps live: /data/apps, the user's (Settings installs and removes
//! them there, without privileges), shown at /apps once the card's space
//! for files is there. Until then (the first start, while setup prepares
//! the card) /apps shows the image's own apps on the boot partition.
//!
//! The first time, /data/apps is made a copy of the image's apps
//! (/boot/apps): written as /data/apps.new, then renamed, so a copy cut
//! off is made again. Its files are the user's.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const print = sys.print;

pub const installed = sys.system.data_dir ++ "/apps";
const image_apps = "/boot/apps";
const shown_at = "/apps";

/// Makes /data/apps if it is not there, and shows it at /apps. Init calls
/// it as root, the system manager as the user (with CAP_DAC_OVERRIDE and
/// CAP_SYS_ADMIN): either way, the files are the user's.
pub fn useInstalled() void {
    if (!exists(installed)) {
        const new = installed ++ ".new";
        sys.files.removeTree(new);
        copyTree(image_apps, new) catch |err| {
            print("dazzle: cannot copy the apps to {s}: {s}\n", .{ installed, @errorName(err) });
            sys.files.removeTree(new);
            return;
        };
        _ = sys.check(linux.rename(new, installed)) catch |err| {
            print("dazzle: cannot make {s}: {s}\n", .{ installed, @errorName(err) });
            return;
        };
        print("dazzle: apps copied to {s}\n", .{installed});
    }
    _ = sys.check(linux.mount(installed, shown_at, null, linux.MS.BIND, 0)) catch |err| {
        print("dazzle: cannot show {s} at {s}: {s}\n", .{ installed, shown_at, @errorName(err) });
        return;
    };
    print("dazzle: apps from {s}\n", .{installed});
}

fn exists(path: [*:0]const u8) bool {
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
}

/// Copies the directory `from` to `to` (which must not be there), and what
/// is in it, as the user's.
pub fn copyTree(from: [:0]const u8, to: [:0]const u8) !void {
    _ = try sys.check(linux.mkdir(to, 0o755));
    own(to);
    const dir = try sys.open(from, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    defer sys.close(dir);
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
            var src_buf: [512]u8 = undefined;
            var dst_buf: [512]u8 = undefined;
            const src = try std.fmt.bufPrintZ(&src_buf, "{s}/{s}", .{ from, name });
            const dst = try std.fmt.bufPrintZ(&dst_buf, "{s}/{s}", .{ to, name });
            const dt_dir = 4;
            // An app's program is named after its folder; FAT says every
            // file can be run, so that is how programs are told.
            if (kind == dt_dir) try copyTree(src, dst) else try copyFile(src, dst, std.mem.eql(u8, name, std.fs.path.basename(to)));
        }
    }
}

fn copyFile(from: [:0]const u8, to: [:0]const u8, program: bool) !void {
    const src = try sys.open(from, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer sys.close(src);
    const dst = try sys.open(to, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
    defer sys.close(dst);
    _ = linux.fchmod(dst, if (program) 0o755 else 0o644);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.check(linux.read(src, &buf, buf.len));
        if (n == 0) break;
        var done: usize = 0;
        while (done < n) done += try sys.check(linux.write(dst, buf[done..n].ptr, n - done));
    }
    _ = linux.fsync(dst);
    own(to);
}

/// Gives a file to the user (it already is, unless root made it).
fn own(path: [:0]const u8) void {
    if (linux.getuid() == 0) _ = linux.chown(path, sys.user.uid, sys.user.gid);
}

const testing = std.testing;

test "the apps are copied, programs (named after their folders) runnable, and removed" {
    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/dazzle-apps-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(root, 0o755);
    defer sys.files.removeTree(root);
    var b: [5][128]u8 = undefined;
    const from = try std.fmt.bufPrintZ(&b[0], "{s}/from", .{root});
    const app = try std.fmt.bufPrintZ(&b[1], "{s}/from/notes", .{root});
    const prog = try std.fmt.bufPrintZ(&b[2], "{s}/from/notes/notes", .{root});
    _ = linux.mkdir(from, 0o755);
    _ = linux.mkdir(app, 0o755);
    const fd = try sys.open(prog, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
    _ = linux.fchmod(fd, 0o755);
    _ = linux.write(fd, "#!", 2);
    sys.close(fd);

    const to = try std.fmt.bufPrintZ(&b[3], "{s}/to", .{root});
    try copyTree(from, to);
    const copied = try std.fmt.bufPrintZ(&b[4], "{s}/to/notes/notes", .{root});
    var stx: linux.Statx = undefined;
    try testing.expectEqual(@as(usize, 0), linux.statx(linux.AT.FDCWD, copied, 0, .{ .MODE = true, .SIZE = true }, &stx));
    try testing.expectEqual(@as(u64, 2), stx.size);
    try testing.expect(stx.mode & 0o111 != 0);
    // Not over one that is there.
    try testing.expectError(error.Unexpected, copyTree(from, to));
    sys.files.removeTree(to);
    try testing.expect(!exists(to));
}
