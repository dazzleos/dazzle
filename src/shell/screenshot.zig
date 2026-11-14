//! Screenshots: Print Screen saves the screen as a PNG file among the
//! user's files (/data/user: no folder of its own, as the user has few
//! files), named "Screenshot 1.png", "Screenshot 2.png" and so on.
//!
//! The pixels are read back from the GPU in the shell (see
//! `render.Renderer.capture`); a thread compresses and writes them, so the
//! shell goes on drawing meanwhile.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const png = @import("gfx").png;

/// Where screenshots go: with the user's other files.
pub const folder = sys.system.user_dir;

/// Saves `pixels` (`width` by `height`) in `dir` as the next unused
/// "Screenshot N.png", on a thread. Takes `pixels` (allocated with `gpa`,
/// which must be thread-safe).
pub fn save(gpa: std.mem.Allocator, dir: []const u8, pixels: []u32, width: u32, height: u32) void {
    const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, saveNow, .{ gpa, dir, pixels, width, height }) catch |err| {
        sys.print(sys.log_warning ++ "dazzle-shell: cannot save a screenshot ({s})\n", .{@errorName(err)});
        gpa.free(pixels);
        return;
    };
    t.detach();
}

fn saveNow(gpa: std.mem.Allocator, dir: []const u8, pixels: []u32, width: u32, height: u32) void {
    defer gpa.free(pixels);
    const data = png.encode(gpa, pixels, width, height) catch |err| {
        sys.print(sys.log_warning ++ "dazzle-shell: cannot make a screenshot: {s}\n", .{@errorName(err)});
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
            return;
        };
        sys.print("dazzle-shell: saved {s}\n", .{path});
        return;
    }
    sys.print(sys.log_warning ++ "dazzle-shell: no name for a screenshot in {s}\n", .{dir});
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

    const pixels = try gpa.alloc(u32, 4 * 3);
    @memset(pixels, 0xff224466);
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, saveNow, .{ gpa, dir, pixels, 4, 3 });
    t.join();

    var path_buf: [512]u8 = undefined;
    const saved = try std.mem.printSentinel(&path_buf, "{s}/Screenshot 1.png", .{dir}, 0);
    const data = try sys.readFileAlloc(gpa, saved, 64 * 1024);
    defer gpa.free(data);
    const decoded = try png.decode(gpa, data);
    defer gpa.free(decoded.pixels);
    try std.testing.expectEqual(@as(u32, 4), decoded.width);
    try std.testing.expectEqual(@as(u32, 3), decoded.height);
}
