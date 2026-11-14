//! Screenshots: Print Screen saves the screen as a PNG file among the
//! user's files (/data/user: no folder of its own, as the user has few
//! files), named "Screenshot 1.png", "Screenshot 2.png" and so on.
//!
//! The pixels are read back from the GPU in the shell (see
//! `render.Renderer.capture`); a thread compresses and writes them, so the
//! shell goes on drawing meanwhile, and then says how it went (`Report`)
//! on a pipe the shell waits on, for it to tell the user.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const png = @import("gfx").png;

/// Where screenshots go: with the user's other files.
pub const folder = sys.system.user_dir;

/// How saving a screenshot went: the file's name, or why it was not
/// saved. Written whole to the pipe (it is smaller than a pipe writes at
/// once), and read whole.
pub const Report = extern struct {
    saved: bool,
    len: u8,
    text_buf: [254]u8,

    fn of(saved: bool, message: []const u8) Report {
        var r: Report = .{ .saved = saved, .len = @intCast(@min(message.len, 254)), .text_buf = undefined };
        @memcpy(r.text_buf[0..r.len], message[0..r.len]);
        return r;
    }

    /// The file's name (without its folder), or why it was not saved.
    pub fn text(r: *const Report) []const u8 {
        return r.text_buf[0..r.len];
    }

    fn send(r: Report, fd: linux.fd_t) void {
        _ = linux.write(fd, std.mem.asBytes(&r), @sizeOf(Report));
    }

    /// The next report on the pipe `fd` (non-blocking), if there is one.
    pub fn read(fd: linux.fd_t) ?Report {
        var r: Report = undefined;
        const n = linux.read(fd, std.mem.asBytes(&r), @sizeOf(Report));
        if (linux.errno(n) != .SUCCESS or n != @sizeOf(Report)) return null;
        return r;
    }
};

/// Saves `pixels` (`width` by `height`) in `dir` as the next unused
/// "Screenshot N.png", on a thread, which then writes a `Report` to
/// `report_fd`. Takes `pixels` (allocated with `gpa`, which must be
/// thread-safe).
pub fn save(gpa: std.mem.Allocator, dir: []const u8, pixels: []u32, width: u32, height: u32, report_fd: linux.fd_t) void {
    const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, saveNow, .{ gpa, dir, pixels, width, height, report_fd }) catch |err| {
        sys.print(sys.log_warning ++ "dazzle-shell: cannot save a screenshot ({s})\n", .{@errorName(err)});
        gpa.free(pixels);
        Report.of(false, "There is no room to save it").send(report_fd);
        return;
    };
    t.detach();
}

fn saveNow(gpa: std.mem.Allocator, dir: []const u8, pixels: []u32, width: u32, height: u32, report_fd: linux.fd_t) void {
    defer gpa.free(pixels);
    const data = png.encode(gpa, pixels, width, height) catch |err| {
        sys.print(sys.log_warning ++ "dazzle-shell: cannot make a screenshot: {s}\n", .{@errorName(err)});
        Report.of(false, "There is no room to save it").send(report_fd);
        return;
    };
    defer gpa.free(data);
    // Another screenshot may be saved at the same time: if it takes the
    // name, the next one.
    for (0..8) |_| {
        var path_buf: [512]u8 = undefined;
        const path = nextName(&path_buf, dir) orelse break;
        sys.files.writeNew(path, data) catch |err| {
            if (err == error.Exists) continue;
            sys.print(sys.log_warning ++ "dazzle-shell: cannot write {s}: {s}\n", .{ path, @errorName(err) });
            Report.of(false, "It could not be written to the card").send(report_fd);
            return;
        };
        sys.print("dazzle-shell: saved {s}\n", .{path});
        Report.of(true, std.fs.path.basename(path)).send(report_fd);
        return;
    }
    sys.print(sys.log_warning ++ "dazzle-shell: no name for a screenshot in {s}\n", .{dir});
    Report.of(false, "There is no name free for it").send(report_fd);
}

/// "<dir>/Screenshot N.png" for the first N not taken.
pub fn nextName(buf: []u8, dir: []const u8) ?[:0]const u8 {
    return sys.files.numberedName(buf, dir, "Screenshot", "png");
}

test "saving a screenshot on a 1 MiB thread stack" {
    const gpa = std.testing.allocator;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-screenshot-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);

    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (pipe) |fd| sys.close(fd);
    const pixels = try gpa.alloc(u32, 4 * 3);
    @memset(pixels, 0xff224466);
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, saveNow, .{ gpa, dir, pixels, 4, 3, pipe[1] });
    t.join();
    // It says where it was saved.
    const report = Report.read(pipe[0]).?;
    try std.testing.expect(report.saved);
    try std.testing.expectEqualStrings("Screenshot 1.png", report.text());
    try std.testing.expect(Report.read(pipe[0]) == null);

    var path_buf: [512]u8 = undefined;
    const saved = try std.mem.printSentinel(&path_buf, "{s}/Screenshot 1.png", .{dir}, 0);
    const data = try sys.readFileAlloc(gpa, saved, 64 * 1024);
    defer gpa.free(data);
    const decoded = try png.decode(gpa, data);
    defer gpa.free(decoded.pixels);
    try std.testing.expectEqual(@as(u32, 4), decoded.width);
    try std.testing.expectEqual(@as(u32, 3), decoded.height);
}
