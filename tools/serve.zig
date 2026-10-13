//! Serves the built OS update (`zig-out/os`) and app catalogue (`zig-out/apps`)
//! over HTTPS from the build machine for testing Dazzle's Software page and
//! setup app before publishing a release.
//!
//! Prints the `https://<ip>:<port>` URL to enter into Settings -> Software ->
//! Software server. `store.Client` trusts the deterministic `Dazzle Test CA`
//! root certificate used by `tls_server`.
//!
//! Usage: zig build serve [-- [--port=8443] [--host=<ip-or-host>] [zig-out]]

const std = @import("std");
const linux = std.os.linux;
const tls_server = @import("tls_server");

pub const default_port: u16 = 8443;

/// Synthetic os.json served when `zig-out/os/os.json` has not been built yet,
/// with `time = 1` so `store.fetchOs` succeeds without offering a bogus update.
pub const fallback_os_json =
    \\{
    \\  "name": "dazzle",
    \\  "title": "Dazzle",
    \\  "description": "The operating system",
    \\  "version": "0000000",
    \\  "time": 1,
    \\  "icon": "icon.png",
    \\  "file": "dazzle-os.tar.xz",
    \\  "size": 0,
    \\  "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    \\}
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var root_dir: []const u8 = "zig-out";
    var host_override: ?[]const u8 = null;
    var port: u16 = default_port;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch {
                std.debug.print("serve: invalid port in '{s}'\n", .{arg});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            host_override = arg["--host=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("usage: dazzle-serve [--port=8443] [--host=<ip-or-host>] [zig-out]\n", .{});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("serve: unknown option '{s}'\n", .{arg});
            std.process.exit(2);
        } else {
            root_dir = std.mem.trimEnd(u8, arg, "/");
        }
    }

    const listener = try bindListener(port);
    defer _ = linux.close(listener.fd);

    var ip_buf: [64]u8 = undefined;
    const host = host_override orelse detectLanIp(&ip_buf);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout_w.interface;
    try out.print("Serving Dazzle software from {s}/os and {s}/apps\n", .{ root_dir, root_dir });
    try out.print("URL for Settings -> Software -> Software server:\n\n", .{});
    try out.print("  https://{s}:{d}\n\n", .{ host, listener.port });
    try out.flush();

    while (true) {
        const rc = linux.accept4(listener.fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) continue;
        const conn_fd: linux.fd_t = @intCast(rc);
        handleConnection(gpa, init.io, conn_fd, root_dir, host);
    }
}

pub const Listener = struct {
    fd: linux.fd_t,
    port: u16,
};

pub fn bindListener(preferred_port: u16) !Listener {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));

    var addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, preferred_port),
        .addr = 0, // INADDR_ANY
    };
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        if (preferred_port == 0) return error.BindFailed;
        addr.port = 0;
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    }
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ListenFailed;

    var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&addr), &addr_len)) != .SUCCESS) return error.BindFailed;
    return .{
        .fd = fd,
        .port = std.mem.bigToNative(u16, addr.port),
    };
}

/// Determines the build machine's outbound IPv4 address by connecting a UDP
/// socket to 1.1.1.1:53 and reading `getsockname`, falling back to 127.0.0.1.
pub fn detectLanIp(buf: *[64]u8) []const u8 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return "127.0.0.1";
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var remote: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, 53),
        .addr = @bitCast([4]u8{ 1, 1, 1, 1 }),
    };
    if (linux.errno(linux.connect(fd, @ptrCast(&remote), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return "127.0.0.1";

    var local: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&local), &len)) != .SUCCESS) return "127.0.0.1";

    const ip: [4]u8 = @bitCast(local.addr);
    if (ip[0] == 0 or ip[0] == 127) return "127.0.0.1";
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch "127.0.0.1";
}

/// Maps a URL request path (such as `/os.json`, `/apps.json`, `/icon.png`,
/// `/dazzle-files.png`, or `/dazzle-files.tar.xz`) to its relative
/// path under `root_dir`, or null if the path is not an allowed store path.
pub fn resolveRequestPath(buf: *[512]u8, root_dir: []const u8, req_path: []const u8) ?[]const u8 {
    const clean = if (std.mem.indexOfScalar(u8, req_path, '?')) |q| req_path[0..q] else req_path;
    if (!std.mem.startsWith(u8, clean, "/")) return null;
    const rel = clean[1..];
    if (std.mem.eql(u8, rel, "os.json") or
        std.mem.eql(u8, rel, "icon.png") or
        std.mem.eql(u8, rel, "dazzle-os.tar.xz"))
    {
        return std.fmt.bufPrint(buf, "{s}/os/{s}", .{ root_dir, rel }) catch null;
    }
    if (std.mem.eql(u8, rel, "apps.json")) {
        return std.fmt.bufPrint(buf, "{s}/apps/apps.json", .{root_dir}) catch null;
    }
    if (std.mem.endsWith(u8, rel, ".png")) {
        const stem = rel[0 .. rel.len - ".png".len];
        if (!validSlug(stem)) return null;
        return std.fmt.bufPrint(buf, "{s}/apps/{s}", .{ root_dir, rel }) catch null;
    }
    if (std.mem.endsWith(u8, rel, ".tar.xz")) {
        const stem = rel[0 .. rel.len - ".tar.xz".len];
        if (!validSlug(stem)) return null;
        return std.fmt.bufPrint(buf, "{s}/apps/{s}", .{ root_dir, rel }) catch null;
    }
    return null;
}

fn validSlug(name: []const u8) bool {
    if (name.len == 0 or name.len > 48 or name[0] == '-') return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

pub fn handleConnection(gpa: std.mem.Allocator, io: std.Io, fd: linux.fd_t, root_dir: []const u8, default_host: []const u8) void {
    defer _ = linux.close(fd);
    var tls_conn = tls_server.Conn.handshake(fd, default_host) catch return;
    var req_buf: [16384]u8 = undefined;
    var filled: usize = 0;

    while (true) {
        const header_end = while (true) {
            if (std.mem.indexOf(u8, req_buf[0..filled], "\r\n\r\n")) |idx| break idx + 4;
            var chunk: [16384]u8 = undefined;
            const n = tls_conn.read(&chunk) catch return;
            if (n == 0 or filled + n > req_buf.len) return;
            @memcpy(req_buf[filled .. filled + n], chunk[0..n]);
            filled += n;
        };

        const req = req_buf[0..header_end];
        const first_line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
        const first_line = req[0..first_line_end];
        var parts = std.mem.tokenizeScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) {
            sendResponse(&tls_conn, 405, "Method Not Allowed", "text/plain", "Method Not Allowed\n") catch return;
        } else {
            servePath(gpa, io, &tls_conn, root_dir, target) catch return;
        }

        const rest = filled - header_end;
        std.mem.copyForwards(u8, req_buf[0..rest], req_buf[header_end..filled]);
        filled = rest;
    }
}

fn servePath(gpa: std.mem.Allocator, io: std.Io, tls_conn: *tls_server.Conn, root_dir: []const u8, target: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const fs_path = resolveRequestPath(&path_buf, root_dir, target) orelse {
        std.debug.print("GET {s} -> 404\n", .{target});
        return sendResponse(tls_conn, 404, "Not Found", "text/plain", "Not Found\n");
    };

    const cwd = std.Io.Dir.cwd();
    const content_type = contentTypeFor(target);
    if (cwd.readFileAlloc(io, fs_path, gpa, .limited(256 << 20))) |body| {
        defer gpa.free(body);
        std.debug.print("GET {s} -> 200 ({d} bytes)\n", .{ target, body.len });
        return sendResponse(tls_conn, 200, "OK", content_type, body);
    } else |_| {
        // Fallback when zig-out/os hasn't been built yet (only zig-out/apps):
        if (std.mem.eql(u8, target, "/os.json")) {
            std.debug.print("GET {s} -> 200 (fallback os.json)\n", .{target});
            return sendResponse(tls_conn, 200, "OK", "application/json", fallback_os_json);
        }
        if (std.mem.eql(u8, target, "/icon.png")) {
            if (cwd.readFileAlloc(io, "icon.png", gpa, .limited(1 << 20))) |icon| {
                defer gpa.free(icon);
                std.debug.print("GET {s} -> 200 ({d} bytes, repo icon.png)\n", .{ target, icon.len });
                return sendResponse(tls_conn, 200, "OK", "image/png", icon);
            } else |_| {}
        }
        std.debug.print("GET {s} -> 404 ({s} missing)\n", .{ target, fs_path });
        return sendResponse(tls_conn, 404, "Not Found", "text/plain", "Not Found\n");
    }
}

fn contentTypeFor(target: []const u8) []const u8 {
    if (std.mem.endsWith(u8, target, ".json")) return "application/json";
    if (std.mem.endsWith(u8, target, ".png")) return "image/png";
    if (std.mem.endsWith(u8, target, ".tar.xz")) return "application/x-xz";
    return "application/octet-stream";
}

fn sendResponse(
    tls_conn: *tls_server.Conn,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
        .{ status, reason, content_type, body.len },
    );
    try tls_conn.writeAll(hdr);
    try tls_conn.writeAll(body);
}

test "resolveRequestPath maps OS and app routes to zig-out/os and zig-out/apps" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("zig-out/os/os.json", resolveRequestPath(&buf, "zig-out", "/os.json").?);
    try std.testing.expectEqualStrings("zig-out/os/icon.png", resolveRequestPath(&buf, "zig-out", "/icon.png").?);
    try std.testing.expectEqualStrings("zig-out/os/dazzle-os.tar.xz", resolveRequestPath(&buf, "zig-out", "/dazzle-os.tar.xz").?);
    try std.testing.expectEqualStrings("zig-out/apps/apps.json", resolveRequestPath(&buf, "zig-out", "/apps.json").?);
    try std.testing.expectEqualStrings("zig-out/apps/dazzle-files.png", resolveRequestPath(&buf, "zig-out", "/dazzle-files.png").?);
    try std.testing.expectEqualStrings("zig-out/apps/dazzle-files.tar.xz", resolveRequestPath(&buf, "zig-out", "/dazzle-files.tar.xz").?);

    try std.testing.expect(resolveRequestPath(&buf, "zig-out", "/../etc/passwd") == null);
    try std.testing.expect(resolveRequestPath(&buf, "zig-out", "/icons/dazzle-files.png") == null);
    try std.testing.expect(resolveRequestPath(&buf, "zig-out", "/../secret.tar.xz") == null);
    try std.testing.expect(resolveRequestPath(&buf, "zig-out", "/unknown.txt") == null);
}
