//! Installing an update of the system: Settings downloads it (the files of
//! an OS slot, as a tar archive of the folder "os", compressed with xz; see
//! tools/mkos.zig) to /data/update and asks the system manager, with the
//! archive's SHA-256, to install it. The manager does that in a child
//! process (`Installer`), so it goes on answering meanwhile:
//!
//! 1. The archive is read into memory and checked against the SHA-256
//!    Settings gave (it is the user's file: it is checked as it is used).
//! 2. It is unpacked into slot-<x>.new/ on the boot partition, <x> being
//!    the slot not running, with the running slot's command line made
//!    that slot's; it must have a kernel, an initramfs and a version.
//! 3. The slot that was there (the system before the running one) goes,
//!    and slot-<x>.new/ becomes slot-<x>/.
//! 4. It is marked to be tried (trial.zig), and config.txt's os_prefix is
//!    changed to it, so the firmware starts it next time; if it does not
//!    work there, the system goes back to the running one.
//!
//! Until step 4 the running system is what starts; a power cut leaves at
//! worst an unfinished slot-<x>.new/ or no slot <x>, which the next update
//! (or the copier, slots.zig) makes again.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const storage = @import("storage.zig");
const slots = @import("slots.zig");
const trial = @import("trial.zig");

const proto = sys.system;
const print = sys.print;

pub const Installer = struct {
    pid: linux.pid_t,
    /// The child's report: empty if it worked, else the failure's name.
    result: linux.fd_t,

    /// Starts installing the update whose archive has SHA-256 `sha256`
    /// into the slot other than `running`.
    pub fn start(sha256: [64]u8, running: u8) !Installer {
        var fds: [2]linux.fd_t = undefined;
        _ = try sys.check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |e| {
                sys.close(fds[0]);
                sys.close(fds[1]);
                return sys.errorFromErrno(e);
            },
        }
        if (rc == 0) {
            sys.close(fds[0]);
            install(std.heap.page_allocator, &sha256, running) catch |err| {
                print(sys.log_warning ++ "dazzle: system: cannot install the update: {s}\n", .{@errorName(err)});
                const why = @tagName(failure(err));
                _ = linux.write(fds[1], why.ptr, why.len);
            };
            linux.exit(0);
        }
        sys.close(fds[1]);
        return .{ .pid = @intCast(rc), .result = fds[0] };
    }

    /// If installing has finished: how it went.
    pub fn finished(i: *Installer) ?proto.UpdateFailure {
        var status: u32 = 0;
        const rc = linux.wait4(i.pid, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) == .SUCCESS and rc == 0) return null;
        var buf: [32]u8 = undefined;
        const n = sys.check(linux.read(i.result, &buf, buf.len)) catch 0;
        sys.close(i.result);
        if (n > 0) return std.meta.stringToEnum(proto.UpdateFailure, buf[0..n]) orelse .io;
        return if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0) .none else .io;
    }
};

fn failure(err: anyerror) proto.UpdateFailure {
    return switch (err) {
        error.WrongArchive, error.BadArchive, error.NotFound, error.Incomplete => .archive,
        else => .io,
    };
}

fn install(gpa: std.mem.Allocator, sha256: []const u8, running: u8) !void {
    const archive = sys.readFileAlloc(gpa, proto.update_archive, sys.archive.max_unpacked) catch |err|
        return if (err == error.NotFound) error.WrongArchive else err;
    defer gpa.free(archive);
    if (!sys.archive.sha256Is(archive, sha256)) return error.WrongArchive;
    const to = slots.other(running);
    print("dazzle: system: installing the update into OS slot {c}\n", .{std.ascii.toUpper(to)});

    try slots.remount(false);
    defer slots.remount(true) catch {};
    // An earlier update that did not work is forgotten.
    _ = linux.unlink(trial.failed_marker);
    var new_buf: [96]u8 = undefined;
    var slot_buf: [96]u8 = undefined;
    var from_buf: [96]u8 = undefined;
    const new = slots.slotPath(&new_buf, to, ".new");
    const slot = slots.slotPath(&slot_buf, to, "");
    sys.files.removeTree(new);
    _ = try sys.check(linux.mkdir(new, 0o755));
    errdefer sys.files.removeTree(new);
    try sys.archive.extract(gpa, archive, "os", new);
    var path_buf: [128]u8 = undefined;
    for ([_][]const u8{ "kernel.img", "kernel7.img", "kernel8.img", "initramfs.cpio", proto.Version.file_name }) |name| {
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ new, name });
        if (!storage.exists(path)) return error.Incomplete;
    }

    // The running slot's command line, for the new slot.
    const from_cmdline = try std.fmt.bufPrintZ(&path_buf, "{s}/cmdline.txt", .{slots.slotPath(&from_buf, running, "")});
    var cmdline_buf: [1024]u8 = undefined;
    const cmdline = sys.readFile(from_cmdline, &cmdline_buf) orelse return error.NotFound;
    var out: [1024 + 16]u8 = undefined;
    const to_cmdline = try std.fmt.bufPrintZ(&path_buf, "{s}/cmdline.txt", .{new});
    const fd = try sys.open(to_cmdline, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
    {
        defer sys.close(fd);
        const text = slots.retarget(cmdline, to, &out);
        var at: usize = 0;
        while (at < text.len) at += try sys.check(linux.write(fd, text[at..].ptr, text.len - at));
        _ = try sys.check(linux.fsync(fd));
    }

    // Into place, then tried next time.
    sys.files.removeTree(slot);
    _ = try sys.check(linux.rename(new, slot));
    try trial.write(.{ .slot = to, .state = .pending });
    try slots.startNext(to);
    _ = linux.unlink(proto.update_archive);
    print("dazzle: system: OS slot {c} has the update; it starts next time\n", .{std.ascii.toUpper(to)});
}
