//! Asking the shell to open an app: one app can send the user to another
//! (the Data Logger to Settings' GPIO page, say). The shell listens on
//! /os/sockets/shell; a client connects and sends one line:
//!
//!     open <app> [<what>]
//!
//! naming the app by its program's name ("dazzle-settings") and, if it
//! likes, what the app is to show (an argument it understands: "gpio").
//! The shell answers "opened" or "unknown". An app not running is started
//! with <what> as its argument; one running is brought to the front, and
//! <what> is sent on to it, on its own socket (/os/sockets/app-<app>), if
//! it has one: a line, "<what>".

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const socket_path = "/os/sockets/shell";

pub const Request = struct {
    app: []const u8,
    what: ?[]const u8,

    pub fn parse(line: []const u8) ?Request {
        var f = std.mem.tokenizeAny(u8, line, " \n");
        if (!std.mem.eql(u8, f.next() orelse return null, "open")) return null;
        const app = f.next() orelse return null;
        if (!validWord(app)) return null;
        const what = f.next();
        if (what) |w| if (!validWord(w)) return null;
        if (f.next() != null) return null;
        return .{ .app = app, .what = what };
    }
};

/// Names and arguments are plain: letters, digits, '-' and '_'.
fn validWord(w: []const u8) bool {
    if (w.len == 0 or w.len > 64) return false;
    for (w) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// The socket an app listens on for what to show: /os/sockets/app-<name>.
pub fn appSocket(buf: []u8, name: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(buf, "/os/sockets/app-{s}", .{name}, 0) catch null;
}

/// Asks the shell to open `app`, showing `what`. Returns whether it did.
pub fn open(app: []const u8, what: ?[]const u8) bool {
    var req: [160]u8 = undefined;
    const line = if (what) |w| std.fmt.bufPrint(&req, "open {s} {s}\n", .{ app, w }) else std.fmt.bufPrint(&req, "open {s}\n", .{app});
    var answer: [32]u8 = undefined;
    const got = send(socket_path, line catch return false, &answer) orelse return false;
    return std.mem.startsWith(u8, got, "opened");
}

/// Sends `line` to the socket at `path`, and reads the answer (if `answer`
/// has room for one). Null if the socket is not there.
pub fn send(path: []const u8, line: []const u8, answer: []u8) ?[]const u8 {
    const fd: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch return null);
    defer sys.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    _ = sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) catch return null;
    _ = sys.check(linux.write(fd, line.ptr, line.len)) catch return null;
    if (answer.len == 0) return answer[0..0];
    // A second at most.
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.poll(&pfd, 1, 1000) <= 0) return null;
    const n = sys.check(linux.read(fd, answer.ptr, answer.len)) catch return null;
    return answer[0..n];
}

/// Listens on the Unix socket at `path` (replacing a stale one), without
/// blocking.
pub fn listen(path: [:0]const u8) !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer sys.close(fd);
    _ = linux.unlink(path);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    _ = try sys.check(linux.listen(fd, 4));
    return fd;
}

/// Takes a connection waiting on `listener` and reads its line (into
/// `buf`), without the newline; null if there is none. The connection is
/// returned too, to answer on (the caller closes it).
pub fn accept(listener: linux.fd_t, buf: []u8) ?struct { fd: linux.fd_t, line: []const u8 } {
    const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.poll(&pfd, 1, 200) <= 0) {
        sys.close(fd);
        return null;
    }
    const n = sys.check(linux.read(fd, buf.ptr, buf.len)) catch {
        sys.close(fd);
        return null;
    };
    return .{ .fd = fd, .line = std.mem.trimEnd(u8, buf[0..n], "\n") };
}

const testing = std.testing;

test "requests" {
    const r = Request.parse("open dazzle-settings gpio\n").?;
    try testing.expectEqualStrings("dazzle-settings", r.app);
    try testing.expectEqualStrings("gpio", r.what.?);
    try testing.expect(Request.parse("open dazzle-files").?.what == null);
    try testing.expect(Request.parse("open ../x") == null);
    try testing.expect(Request.parse("open a b c") == null);
    try testing.expect(Request.parse("close a") == null);
    try testing.expect(Request.parse("open") == null);
}

test "an app's socket, and a line over it" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/os/sockets/app-dazzle-settings", appSocket(&buf, "dazzle-settings").?);
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-shell-test-{d}", .{linux.getpid()}, 0);
    const l = try listen(path);
    defer {
        sys.close(l);
        _ = linux.unlink(path);
    }
    var none: [0]u8 = .{};
    try testing.expect(send(path, "gpio\n", &none) != null);
    var line_buf: [32]u8 = undefined;
    const got = accept(l, &line_buf).?;
    defer sys.close(got.fd);
    try testing.expectEqualStrings("gpio", got.line);
    try testing.expect(send("/nonexistent/socket", "x\n", &none) == null);
}
