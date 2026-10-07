//! The media manager's protocol. Init runs the manager
//! (src/init/media.zig), which mounts USB drives as they are plugged in,
//! each in a folder of /media named by its label, and unmounts them when
//! they are ejected (or pulled out). It listens on a socket,
//! /os/sockets/media, that only the Dazzle user can connect to.
//!
//! A client connects, sends one request and reads the answer:
//!
//!     eject <folder name>
//!
//! and the answer is one of:
//!
//!     ejected          everything is written, and it can be pulled out
//!     busy             something has a file on it open
//!     unknown          no drive is mounted there
//!     failed

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The manager's socket.
pub const socket_path = "/os/sockets/media";

/// Where drives are mounted: /media/<label>.
pub const media_dir = "/media";

pub const Answer = enum {
    ejected,
    busy,
    unknown,
    failed,

    pub fn parse(text: []const u8) ?Answer {
        return std.meta.stringToEnum(Answer, std.mem.trim(u8, text, " \n"));
    }
};

/// The folder name an eject request is for.
pub fn parseEject(line: []const u8) ?[]const u8 {
    const rest = std.mem.trimEnd(u8, line, "\n");
    if (!std.mem.startsWith(u8, rest, "eject ")) return null;
    const name = rest["eject ".len..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    return name;
}

/// Asks the manager to eject the drive at /media/<name>; null if it
/// cannot be reached, or does not answer within `timeout_ms` (writing what
/// is left to a slow drive can take a while).
pub fn eject(name: []const u8, timeout_ms: u64) ?Answer {
    const path = socket_path;
    const fd: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch return null);
    defer sys.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    _ = sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) catch return null;
    var req: [300]u8 = undefined;
    const text = std.fmt.bufPrint(&req, "eject {s}\n", .{name}) catch return null;
    _ = sys.check(linux.write(fd, text.ptr, text.len)) catch return null;
    var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.poll(&pfd, 1, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) == 0) return null;
    var buf: [32]u8 = undefined;
    const n = sys.check(linux.read(fd, &buf, buf.len)) catch return null;
    return Answer.parse(buf[0..n]);
}

test "eject requests and answers" {
    try std.testing.expectEqualStrings("My stick", parseEject("eject My stick\n").?);
    try std.testing.expect(parseEject("eject \n") == null);
    try std.testing.expect(parseEject("eject ..\n") == null);
    try std.testing.expect(parseEject("eject a/b\n") == null);
    try std.testing.expect(parseEject("mount x\n") == null);
    try std.testing.expectEqual(Answer.busy, Answer.parse("busy\n").?);
    try std.testing.expect(Answer.parse("what") == null);
}
