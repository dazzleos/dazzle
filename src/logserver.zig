//! Serves the system log over TCP so it can be read without a serial cable.
//!
//! `telnet <pi> 23` (or `nc <pi> 23`) prints the kernel log buffer from
//! boot, which also holds init's own messages (see `sys.print`), then
//! follows new messages live. Each client gets its own process reading
//! /dev/kmsg, so a hung GPU job in init does not stop the log.
//!
//! The port can be changed on the kernel command line with
//! `stardust.logport=<port>`.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Ip4 = [4]u8;

pub const Config = struct {
    port: u16 = 23,
};

/// Reads `stardust.*` options from a kernel command line.
pub fn parseCmdline(cmdline: []const u8) Config {
    var cfg: Config = .{};
    var it = std.mem.tokenizeAny(u8, cmdline, " \t\n");
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "stardust.logport=")) {
            cfg.port = std.fmt.parseInt(u16, arg["stardust.logport=".len..], 10) catch cfg.port;
        }
    }
    return cfg;
}

fn readCmdline(buf: []u8) []const u8 {
    const fd = sys.open("/proc/cmdline", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return "";
    defer sys.close(fd);
    const n = sys.check(linux.read(fd, buf.ptr, buf.len)) catch return "";
    return buf[0..n];
}

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
    var cmdline_buf: [1024]u8 = undefined;
    const cfg = parseCmdline(readCmdline(&cmdline_buf));
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return,
        else => |e| {
            sys.print("stardust: log server: fork failed ({s})\n", .{@tagName(e)});
            return;
        },
    }
    serve(cfg) catch |err| sys.print("stardust: log server: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

fn serve(cfg: Config) !void {
    // Reap per-client processes automatically, and turn writes to a closed
    // connection into EPIPE errors instead of killing the process.
    ignoreSignal(.CHLD);
    ignoreSignal(.PIPE);

    const listener: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    const one: c_int = 1;
    _ = linux.setsockopt(listener, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
    const bind_addr = sockaddrIn(.{ 0, 0, 0, 0 }, cfg.port);
    _ = try sys.check(linux.bind(listener, @ptrCast(&bind_addr), @sizeOf(@TypeOf(bind_addr))));
    _ = try sys.check(linux.listen(listener, 4));

    sys.print("stardust: log server listening on TCP port {d}\n", .{cfg.port});

    while (true) {
        const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) {
            sys.sleepMs(100);
            continue;
        }
        const client: linux.fd_t = @intCast(rc);
        const pid = linux.fork();
        if (pid == 0) {
            sys.close(listener);
            streamLog(client);
            linux.exit(0);
        }
        sys.close(client);
    }
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

/// Formats one /dev/kmsg record ("prio,seq,usec,flags;text\n" followed by
/// optional " KEY=value" lines) as "[seconds.micros] text\r\n".
pub fn formatRecord(out: []u8, record: []const u8) ?[]const u8 {
    const semi = std.mem.indexOfScalar(u8, record, ';') orelse return null;
    var fields = std.mem.splitScalar(u8, record[0..semi], ',');
    _ = fields.next() orelse return null; // priority and facility
    _ = fields.next() orelse return null; // sequence number
    const usec = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const body = record[semi + 1 ..];
    const text = body[0 .. std.mem.indexOfScalar(u8, body, '\n') orelse body.len];
    return std.fmt.bufPrint(out, "[{d:>5}.{d:0>6}] {s}\r\n", .{
        usec / std.time.us_per_s, usec % std.time.us_per_s, text,
    }) catch null;
}

fn streamLog(client: linux.fd_t) void {
    defer sys.close(client);
    if (!writeAll(client, "Stardust system log. Following new messages; disconnect to stop.\r\n")) return;

    const kmsg = sys.open("/dev/kmsg", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch {
        _ = writeAll(client, "cannot open /dev/kmsg\r\n");
        return;
    };
    defer sys.close(kmsg);

    var record: [8192]u8 = undefined;
    var line: [8192 + 32]u8 = undefined;
    var fds = [_]linux.pollfd{
        .{ .fd = kmsg, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = client, .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        if (linux.errno(linux.poll(&fds, fds.len, -1)) != .SUCCESS) continue;

        // Input from the client is only telnet option negotiation, which is
        // discarded. End of input means the client went away.
        if (fds[1].revents != 0) {
            var discard: [256]u8 = undefined;
            const rc = linux.read(client, &discard, discard.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        }

        if (fds[0].revents != 0) {
            const rc = linux.read(kmsg, &record, record.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                // The ring buffer overwrote records we had not read yet;
                // the next read continues from the oldest remaining one.
                .PIPE, .INTR, .AGAIN => continue,
                else => return,
            }
            const text = formatRecord(&line, record[0..rc]) orelse continue;
            if (!writeAll(client, text)) return;
        }
    }
}

const testing = std.testing;

test "parse command line options" {
    const cfg = parseCmdline("console=ttyAMA0 stardust.logport=2323\n");
    try testing.expectEqual(@as(u16, 2323), cfg.port);
    try testing.expectEqual(@as(u16, 23), parseCmdline("ip=dhcp").port);
}

test "format kmsg record" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "[    3.000042] stardust: starting as init\r\n",
        formatRecord(&buf, "5,512,3000042,-;stardust: starting as init\n SUBSYSTEM=foo\n").?,
    );
    try testing.expectEqual(@as(?[]const u8, null), formatRecord(&buf, "garbage"));
}

test "sockaddr is in network byte order" {
    const a = sockaddrIn(.{ 192, 168, 1, 83 }, 5555);
    const bytes = std.mem.asBytes(&a);
    try testing.expectEqualSlices(u8, &.{ 0x15, 0xb3, 192, 168, 1, 83 }, bytes[2..8]);
}
