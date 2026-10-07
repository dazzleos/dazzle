//! Screenshots: Print Screen saves the screen as a PNG file among the
//! user's files (/data/user: no folder of its own, as the user has few
//! files), named "Screenshot 1.png", "Screenshot 2.png" and so on.
//!
//! The pixels are read back from the GPU in the shell (see
//! `render.Renderer.capture`); a child process compresses and writes them,
//! so the shell goes on drawing meanwhile.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const png = @import("gfx").png;

/// Print Screen (KEY_SYSRQ, a Linux key code).
pub const key_print = 99;

/// Where screenshots go: with the user's other files.
pub const folder = sys.system.user_dir;

/// Saves `pixels` (`width` by `height`) in `dir` as the next unused
/// "Screenshot N.png", in a child process. Takes `pixels` (allocated with
/// `gpa`).
pub fn save(gpa: std.mem.Allocator, dir: []const u8, pixels: []u32, width: u32, height: u32) void {
    defer gpa.free(pixels);
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
    sys.files.writeNew(path, data) catch |err| {
        sys.print("dazzle-shell: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    return true;
}

/// "<dir>/Screenshot N.png" for the first N not taken.
pub fn nextName(buf: []u8, dir: []const u8) ?[:0]const u8 {
    return sys.files.numberedName(buf, dir, "Screenshot", "png");
}
