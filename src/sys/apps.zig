//! Apps and the kinds of files they open. An app (in /data/apps/<name>/)
//! says which it opens in <name>.handles: MIME types, one a line
//! ("text/plain"). It is started with the file's path as its argument.
//! Files asks which app opens a kind of file (`handler`), offers what it
//! can do with it only if one does, and starts it (`launch`).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The MIME type of plain text.
pub const text_plain = "text/plain";

/// The program (its path, in `buf`) of an app in /data/apps that opens
/// files of type `mime`, if one does.
pub fn handler(buf: []u8, mime: []const u8) ?[:0]const u8 {
    return handlerIn(sys.system.apps_dir, buf, mime);
}

pub fn handlerIn(dir_path: []const u8, buf: []u8, mime: []const u8) ?[:0]const u8 {
    var dir_buf: [256]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir_path}) catch return null;
    const dir = sys.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return null;
    defer sys.close(dir);
    var dents: [2048]u8 align(8) = undefined;
    // The first by name, so the same app is chosen each time.
    var best: ?[64]u8 = null;
    var best_len: usize = 0;
    while (true) {
        const n = sys.check(linux.getdents64(dir, &dents, dents.len)) catch break;
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.' or name.len > 64) continue;
            if (!handles(dir_path, name, mime)) continue;
            if (best != null and std.mem.order(u8, name, best.?[0..best_len]) != .lt) continue;
            best = undefined;
            @memcpy(best.?[0..name.len], name);
            best_len = name.len;
        }
    }
    const b = best orelse return null;
    const name = b[0..best_len];
    return std.fmt.bufPrintZ(buf, "{s}/{s}/{s}", .{ dir_path, name, name }) catch null;
}

/// Whether the app `name` in `dir_path` says it opens `mime`.
fn handles(dir_path: []const u8, name: []const u8, mime: []const u8) bool {
    var path_buf: [384]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/{s}.handles", .{ dir_path, name, name }) catch return false;
    var buf: [1024]u8 = undefined;
    const text = sys.readFile(path, &buf) orelse return false;
    var lines = std.mem.tokenizeAny(u8, text, "\n\r");
    while (lines.next()) |line| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line, " \t"), mime)) return true;
    return false;
}

/// Starts `program` with `arg`, and the environment `env` ("NAME=value"),
/// on its own: it is not the caller's child, so it goes on if the caller
/// stops (and init collects it when it ends).
pub fn launch(program: [:0]const u8, arg: [:0]const u8, env: []const [*:0]const u8) !void {
    var envp: [8:null]?[*:0]const u8 = @splat(null);
    for (env[0..@min(env.len, envp.len)], 0..) |e, i| envp[i] = e;
    const argv = [_:null]?[*:0]const u8{ program.ptr, arg.ptr };
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| return sys.errorFromErrno(e),
    }
    if (rc == 0) {
        // The child starts the program in a child of its own, and goes.
        _ = linux.setsid();
        const rc2 = linux.fork();
        if (linux.errno(rc2) == .SUCCESS and rc2 == 0) {
            const err = linux.errno(linux.execve(program, &argv, &envp));
            sys.print("cannot run {s} ({s})\n", .{ program, @tagName(err) });
            linux.exit(127);
        }
        linux.exit(0);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(rc), &status, 0, null);
}

const testing = std.testing;

test "the app that opens a kind of file" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/dazzle-apps-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "viewer", "editor", "camera" }) |name| _ = linux.mkdir(try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }), 0o755);
    try sys.files.writeNew(try std.fmt.bufPrintZ(&buf, "{s}/editor/editor.handles", .{dir}), "text/plain\ntext/markdown\n");
    try sys.files.writeNew(try std.fmt.bufPrintZ(&buf, "{s}/viewer/viewer.handles", .{dir}), "image/png\nText/Plain\n");
    var out: [256]u8 = undefined;
    // Two do: the first by name.
    try testing.expect(std.mem.endsWith(u8, handlerIn(dir, &out, text_plain).?, "/editor/editor"));
    try testing.expect(std.mem.endsWith(u8, handlerIn(dir, &out, "image/png").?, "/viewer/viewer"));
    try testing.expect(handlerIn(dir, &out, "audio/ogg") == null);
    try testing.expect(handlerIn("/nonexistent", &out, text_plain) == null);
}
