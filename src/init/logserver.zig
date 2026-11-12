//! Serves the system log over HTTP so it can be read without a serial
//! cable, in a browser or with curl:
//!
//!     http://<pi>/         the log since boot (kernel and init messages,
//!                          which include every program's; see `sys.print`)
//!     http://<pi>/follow   the same, then new messages as they arrive
//!
//! Only while it is turned on, in Settings (`sys.system.log_server_file`,
//! which it looks at every second), or by `dazzle.log_server=on` on the
//! kernel's command line: it is off unless asked for, as anyone on the
//! network can read the log.
//!
//! Each request gets its own process reading /dev/kmsg, so a hung GPU job
//! in the demo does not stop the log; turning the server off ends them.
//! The server runs as the Dazzle user, keeping only the capability to
//! bind its port; the processes for requests keep none.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const build_info = @import("build_info");

pub const Ip4 = [4]u8;

/// The HTTP port it listens on.
const http_port = 80;

/// How often it looks at whether it is to serve, in milliseconds.
const check_ms = 1000;

fn sockaddrIn(addr: Ip4, port: u16) linux.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(addr),
    };
}

fn ignoreSignal(sig: linux.SIG) void {
    const act: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(sig, &act, null);
}

/// Forks the log server. Returns in the parent; the child never returns.
pub fn start() void {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return,
        else => |e| {
            sys.print(sys.log_error ++ "dazzle: log server: fork failed ({s})\n", .{@tagName(e)});
            return;
        },
    }
    serve() catch |err| sys.print("dazzle: log server: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

fn serve() !void {
    // Reap per-client processes automatically, and turn writes to a closed
    // connection into EPIPE errors instead of killing the process.
    ignoreSignal(.CHLD);
    ignoreSignal(.PIPE);

    // Only binding to the port needs root's privilege; reading /dev/kmsg
    // does not.
    try sys.dropPrivilegesKeeping(&.{.net_bind_service});

    const forced = sys.system.logServerForced();
    var listener: ?linux.fd_t = null;
    // The clients watch the read end, and stop when it is closed here.
    var stop: [2]linux.fd_t = undefined;
    var last_err: ?anyerror = null;
    while (true) {
        const on = forced or sys.system.logServerChosen();
        if (on and listener == null) {
            if (listen()) |l| {
                if (sys.check(linux.pipe2(&stop, .{ .CLOEXEC = true }))) |_| {
                    listener = l;
                    last_err = null;
                    sys.print("dazzle: log server listening on HTTP port {d} as uid {d}\n", .{ http_port, linux.getuid() });
                } else |err| {
                    sys.close(l);
                    return err;
                }
            } else |err| {
                if (last_err == null or last_err.? != err) sys.print(sys.log_warning ++ "dazzle: log server: cannot listen on port {d} ({s})\n", .{ http_port, @errorName(err) });
                last_err = err;
            }
        } else if (!on and listener != null) {
            sys.close(listener.?);
            listener = null;
            // Ends the connections being served.
            sys.close(stop[1]);
            sys.close(stop[0]);
            sys.print("dazzle: log server stopped\n", .{});
        }
        const l = listener orelse {
            sys.sleepMs(check_ms);
            continue;
        };
        var fds = [_]linux.pollfd{.{ .fd = l, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, check_ms);
        if (linux.errno(ready) != .SUCCESS or ready == 0) continue;
        const rc = linux.accept4(l, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) continue;
        const client: linux.fd_t = @intCast(rc);
        const pid = linux.fork();
        if (pid == 0) {
            sys.close(l);
            sys.close(stop[1]);
            dropCapabilities();
            handle(client, stop[0]);
            linux.exit(0);
        }
        sys.close(client);
    }
}

/// A socket listening on `http_port`.
fn listen() !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
    const bind_addr = sockaddrIn(.{ 0, 0, 0, 0 }, http_port);
    _ = try sys.check(linux.bind(fd, @ptrCast(&bind_addr), @sizeOf(@TypeOf(bind_addr))));
    _ = try sys.check(linux.listen(fd, 4));
    return fd;
}

/// Gives up the capabilities kept (a client's process needs none).
fn dropCapabilities() void {
    const Header = extern struct { version: u32, pid: i32 };
    const Data = extern struct { effective: u32, permitted: u32, inheritable: u32 };
    var header: Header = .{ .version = 0x20080522, .pid = 0 }; // _LINUX_CAPABILITY_VERSION_3
    const none = [2]Data{ .{ .effective = 0, .permitted = 0, .inheritable = 0 }, .{ .effective = 0, .permitted = 0, .inheritable = 0 } };
    _ = linux.syscall2(.capset, @intFromPtr(&header), @intFromPtr(&none));
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
    return true;
}

/// Formats one /dev/kmsg record (see `sys.log`) as "[seconds.micros]
/// text\n".
pub fn formatRecord(out: []u8, record: []const u8) ?[]const u8 {
    var text_buf: [8192]u8 = undefined;
    const r = sys.log.parse(&text_buf, record) orelse return null;
    return std.fmt.bufPrint(out, "[{d:>5}.{d:0>6}] {s}\n", .{ r.usec / std.time.us_per_s, r.usec % std.time.us_per_s, r.text }) catch null;
}

pub const Request = struct {
    head: bool,
    page: Page,
};

pub const Page = enum { log, follow, not_found };

/// Parses an HTTP request line ("GET /follow HTTP/1.1"). Null if it is not
/// a GET or HEAD request.
pub fn parseRequest(line: []const u8) ?Request {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    const method = parts.next() orelse return null;
    const head = std.mem.eql(u8, method, "HEAD");
    if (!head and !std.mem.eql(u8, method, "GET")) return null;
    const target = parts.next() orelse return null;
    const path = target[0 .. std.mem.indexOfAny(u8, target, "?#") orelse target.len];
    const page: Page = if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/log"))
        .log
    else if (std.mem.eql(u8, path, "/follow"))
        .follow
    else
        .not_found;
    return .{ .head = head, .page = page };
}

/// Reads the request's first line, waiting up to 5 seconds.
fn readRequestLine(client: linux.fd_t, buf: []u8) ?[]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        var fds = [_]linux.pollfd{.{ .fd = client, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&fds, 1, 5000) == 0) return null;
        const rc = linux.read(client, buf[len..].ptr, buf.len - len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
        len += rc;
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |end| return std.mem.trimEnd(u8, buf[0..end], "\r");
    }
    return null;
}

const text_headers = "Content-Type: text/plain; charset=utf-8\r\n" ++
    // Show text as it arrives rather than waiting to sniff its type.
    "X-Content-Type-Options: nosniff\r\n" ++
    "Cache-Control: no-store\r\n" ++
    "Connection: close\r\n\r\n";

/// Answers a request, until `stop` is closed (the server is turned off).
fn handle(client: linux.fd_t, stop: linux.fd_t) void {
    defer sys.close(client);
    var buf: [2048]u8 = undefined;
    const line = readRequestLine(client, &buf) orelse return;
    const req = parseRequest(line) orelse {
        _ = writeAll(client, "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    if (req.page == .not_found) {
        const body = "Not found. The log is at / (and /follow for live messages).\n";
        var head_buf: [128]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 404 Not Found\r\nContent-Length: {d}\r\n", .{body.len}) catch return;
        if (writeAll(client, head) and writeAll(client, text_headers) and !req.head) _ = writeAll(client, body);
        return;
    }
    if (!writeAll(client, "HTTP/1.1 200 OK\r\n" ++ text_headers) or req.head) return;
    const follow = req.page == .follow;
    const intro = if (follow)
        "Dazzle " ++ build_info.commit ++ " system log, following new messages.\n\n"
    else
        "Dazzle " ++ build_info.commit ++ " system log. /follow shows new messages as they arrive.\n\n";
    if (!writeAll(client, intro)) return;
    streamLog(client, follow, stop);
}

/// Sends the log since boot, then (when following) new messages until the
/// client goes away, or `stop` is closed.
fn streamLog(client: linux.fd_t, follow: bool, stop: linux.fd_t) void {
    const kmsg = sys.open("/dev/kmsg", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }) catch {
        _ = writeAll(client, "cannot open /dev/kmsg\n");
        return;
    };
    defer sys.close(kmsg);

    var record: [8192]u8 = undefined;
    var line: [8192 + 32]u8 = undefined;
    while (true) {
        const rc = linux.read(kmsg, &record, record.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const text = formatRecord(&line, record[0..rc]) orelse continue;
                if (!writeAll(client, text)) return;
                continue;
            },
            // The ring buffer overwrote records we had not read yet; the
            // next read continues from the oldest remaining one.
            .PIPE, .INTR => continue,
            // Everything so far has been sent.
            .AGAIN => if (!follow) return,
            else => return,
        }
        // Wait for a new message, for the client to hang up, or for the
        // server to stop.
        var fds = [_]linux.pollfd{
            .{ .fd = kmsg, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = client, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = stop, .events = linux.POLL.IN, .revents = 0 },
        };
        if (linux.errno(linux.poll(&fds, fds.len, -1)) != .SUCCESS) continue;
        if (fds[2].revents != 0) return;
        if (fds[1].revents != 0) {
            var discard: [256]u8 = undefined;
            const n = linux.read(client, &discard, discard.len);
            if (linux.errno(n) != .SUCCESS or n == 0) return;
        }
    }
}

const testing = std.testing;

test "format kmsg record" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "[    3.000042] dazzle: starting as init\n",
        formatRecord(&buf, "5,512,3000042,-;dazzle: starting as init\n SUBSYSTEM=foo\n").?,
    );
    try testing.expectEqual(@as(?[]const u8, null), formatRecord(&buf, "garbage"));
    // Escaped UTF-8 and backslashes are decoded.
    try testing.expectEqualStrings(
        "[    6.845023] dazzle: SoC 36 °C, C:\\dir\n",
        formatRecord(&buf, "6,900,6845023,-;dazzle: SoC 36 \\xc2\\xb0C, C:\\x5cdir\n").?,
    );
}

test "parse requests" {
    try testing.expectEqual(Request{ .head = false, .page = .log }, parseRequest("GET / HTTP/1.1").?);
    try testing.expectEqual(Request{ .head = true, .page = .follow }, parseRequest("HEAD /follow?x=1 HTTP/1.1").?);
    try testing.expectEqual(Page.not_found, parseRequest("GET /favicon.ico HTTP/1.1").?.page);
    try testing.expectEqual(@as(?Request, null), parseRequest("POST / HTTP/1.1"));
    try testing.expectEqual(@as(?Request, null), parseRequest(""));
}

test "sockaddr is in network byte order" {
    const a = sockaddrIn(.{ 192, 168, 1, 83 }, 5555);
    const bytes = std.mem.asBytes(&a);
    try testing.expectEqualSlices(u8, &.{ 0x15, 0xb3, 192, 168, 1, 83 }, bytes[2..8]);
}
