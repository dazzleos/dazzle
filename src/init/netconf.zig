//! What programs need from a network besides an address: name servers, in
//! /etc/resolv.conf (where Zig's resolver, as others, looks for them), and
//! the time, which HTTPS needs (certificates are only valid for a while,
//! and the Pi has no clock that keeps time while it is off).
//!
//! When an interface gets an address (`online`), the name servers DHCP
//! gave (or the gateway, which home routers answer on) are written to
//! /etc/resolv.conf, and the clock is set by SNTP from DHCP's time servers,
//! or else pool.ntp.org, looked up with a small DNS client of its own (init
//! does not link Zig's resolver). The network manager keeps CAP_SYS_TIME
//! for this. SNTP is not authenticated: the clock is as trustworthy as the
//! network, as on most systems without a clock of their own.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const print = sys.print;

pub const Ip4 = [4]u8;

pub const resolv_conf = "/etc/resolv.conf";
const time_pool = "pool.ntp.org";

/// An interface has an address: keep its name servers and set the clock.
pub fn online(dns: []const Ip4, ntp: []const Ip4, gateway: ?Ip4) void {
    var servers_buf: [3]Ip4 = undefined;
    const servers: []const Ip4 = if (dns.len > 0) dns else if (gateway) |g| blk: {
        servers_buf[0] = g;
        break :blk servers_buf[0..1];
    } else &.{};
    // Nothing to ask (the loopback interface, say).
    if (servers.len == 0 and ntp.len == 0) return;
    if (servers.len > 0) writeResolvConf(servers);
    if (!synced) setClock(ntp, servers);
}

/// Set once, while the system runs (the clock keeps time after that).
var synced = false;

fn writeResolvConf(servers: []const Ip4) void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (servers) |s| w.print("nameserver {d}.{d}.{d}.{d}\n", .{ s[0], s[1], s[2], s[3] }) catch break;
    const fd = sys.open(resolv_conf, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }) catch |err| {
        print("dazzle: network: cannot write {s}: {s}\n", .{ resolv_conf, @errorName(err) });
        return;
    };
    defer sys.close(fd);
    _ = linux.write(fd, w.buffered().ptr, w.buffered().len);
}

fn setClock(ntp: []const Ip4, dns: []const Ip4) void {
    var pool_buf: [1]Ip4 = undefined;
    const servers: []const Ip4 = if (ntp.len > 0) ntp else for (dns) |d| {
        if (lookup(d, time_pool)) |ip| {
            pool_buf[0] = ip;
            break pool_buf[0..1];
        }
    } else {
        print("dazzle: network: no time server (cannot look up {s})\n", .{time_pool});
        return;
    };
    for (servers) |s| {
        const now = sntp(s) orelse continue;
        sys.setRealtimeNs(now) catch |err| {
            print("dazzle: network: cannot set the clock: {s}\n", .{@errorName(err)});
            return;
        };
        synced = true;
        print("dazzle: network: clock set from {d}.{d}.{d}.{d}\n", .{ s[0], s[1], s[2], s[3] });
        return;
    }
    print("dazzle: network: no answer from the time servers\n", .{});
}

/// Sends `request` to `server`:`port` over UDP and waits up to `timeout_ms`
/// for an answer, into `reply`. Returns its length.
fn exchange(server: Ip4, port: u16, request: []const u8, reply: []u8, timeout_ms: i32) ?usize {
    const fd: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return null);
    defer sys.close(fd);
    const addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(server) };
    _ = sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) catch return null;
    for (0..2) |_| {
        _ = sys.check(linux.write(fd, request.ptr, request.len)) catch return null;
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&pfd, 1, timeout_ms) != 1) continue;
        const n = sys.check(linux.read(fd, reply.ptr, reply.len)) catch return null;
        return n;
    }
    return null;
}

// --- SNTP ---------------------------------------------------------------------

/// Seconds from 1900 (NTP's epoch) to 1970.
const ntp_to_unix = 2_208_988_800;

/// The time (nanoseconds since 1970) by the SNTP server at `server`; null
/// if it does not answer, or answers nonsense.
fn sntp(server: Ip4) ?i128 {
    var request: [48]u8 = @splat(0);
    request[0] = 0 << 6 | 4 << 3 | 3; // no leap warning, version 4, client
    var reply: [48]u8 = undefined;
    const sent = sys.nowNs();
    const n = exchange(server, 123, &request, &reply, 1500) orelse return null;
    const t = parseSntp(reply[0..n]) orelse return null;
    // Half the round trip later than the server said.
    return t + @divFloor(@as(i128, sys.nowNs() - sent), 2);
}

/// The transmit time in an SNTP server's reply, as nanoseconds since 1970.
fn parseSntp(reply: []const u8) ?i128 {
    if (reply.len < 48) return null;
    const mode = reply[0] & 7;
    const stratum = reply[1];
    if (mode != 4 or stratum == 0 or stratum > 15) return null;
    const secs = std.mem.readInt(u32, reply[40..44], .big);
    const frac = std.mem.readInt(u32, reply[44..48], .big);
    if (secs == 0) return null;
    // NTP's seconds wrap in 2036: from then on, small values are the next era.
    const era: i128 = if (secs < 0x8000_0000) 1 << 32 else 0;
    const unix = era + secs - ntp_to_unix;
    return unix * std.time.ns_per_s + (@as(i128, frac) * std.time.ns_per_s >> 32);
}

// --- DNS ------------------------------------------------------------------------

/// The first IPv4 address of `name`, asking the name server at `server`.
pub fn lookup(server: Ip4, name: []const u8) ?Ip4 {
    var q: [300]u8 = undefined;
    var id_bytes: [2]u8 = undefined;
    _ = linux.getrandom(&id_bytes, 2, 0);
    const id = std.mem.readInt(u16, &id_bytes, .little);
    const query = dnsQuery(&q, id, name) orelse return null;
    var reply: [512]u8 = undefined;
    const n = exchange(server, 53, query, &reply, 2000) orelse return null;
    return dnsAnswer(reply[0..n], id);
}

/// A query for `name`'s A records.
fn dnsQuery(buf: []u8, id: u16, name: []const u8) ?[]const u8 {
    if (name.len + 18 > buf.len) return null;
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // a query, recursion desired
    std.mem.writeInt(u16, buf[4..6], 1, .big); // one question
    @memset(buf[6..12], 0);
    var at: usize = 12;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return null;
        buf[at] = @intCast(label.len);
        @memcpy(buf[at + 1 ..][0..label.len], label);
        at += 1 + label.len;
    }
    buf[at] = 0;
    std.mem.writeInt(u16, buf[at + 1 ..][0..2], 1, .big); // A
    std.mem.writeInt(u16, buf[at + 3 ..][0..2], 1, .big); // IN
    return buf[0 .. at + 5];
}

/// The first A record in the answer to query `id`.
fn dnsAnswer(msg: []const u8, id: u16) ?Ip4 {
    if (msg.len < 12) return null;
    if (std.mem.readInt(u16, msg[0..2], .big) != id) return null;
    const flags = std.mem.readInt(u16, msg[2..4], .big);
    if (flags & 0x8000 == 0 or flags & 0xf != 0) return null; // not an answer, or an error
    const questions = std.mem.readInt(u16, msg[4..6], .big);
    const answers = std.mem.readInt(u16, msg[6..8], .big);
    var at: usize = 12;
    for (0..questions) |_| at = (skipName(msg, at) orelse return null) + 4;
    for (0..answers) |_| {
        at = skipName(msg, at) orelse return null;
        if (at + 10 > msg.len) return null;
        const rtype = std.mem.readInt(u16, msg[at..][0..2], .big);
        const len = std.mem.readInt(u16, msg[at + 8 ..][0..2], .big);
        at += 10;
        if (at + len > msg.len) return null;
        if (rtype == 1 and len == 4) return msg[at..][0..4].*;
        at += len;
    }
    return null;
}

/// Where the name at `at` ends (labels, or a pointer to them).
fn skipName(msg: []const u8, start: usize) ?usize {
    var at = start;
    while (at < msg.len) {
        const len = msg[at];
        if (len == 0) return at + 1;
        if (len & 0xc0 == 0xc0) return if (at + 2 <= msg.len) at + 2 else null;
        at += 1 + len;
    }
    return null;
}

const testing = std.testing;

test "SNTP replies: the server's time, from 1970" {
    var reply: [48]u8 = @splat(0);
    reply[0] = 0 << 6 | 4 << 3 | 4; // server
    reply[1] = 2;
    // 2026-10-07 00:00:00 UTC, and half a second.
    const unix: u64 = 1_791_331_200;
    std.mem.writeInt(u32, reply[40..44], @intCast(unix + ntp_to_unix), .big);
    std.mem.writeInt(u32, reply[44..48], 0x8000_0000, .big);
    try testing.expectEqual(@as(i128, unix * std.time.ns_per_s + std.time.ns_per_s / 2), parseSntp(&reply).?);
    // Not a server's, or unsynchronized.
    reply[0] = 3;
    try testing.expect(parseSntp(&reply) == null);
    reply[0] = 4;
    reply[1] = 0;
    try testing.expect(parseSntp(&reply) == null);
}

test "DNS: a query, and the address in its answer" {
    var buf: [300]u8 = undefined;
    const q = dnsQuery(&buf, 0x1234, "pool.ntp.org").?;
    try testing.expectEqualSlices(u8, "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x04pool\x03ntp\x03org\x00\x00\x01\x00\x01", q);
    // The answer: the question again, a CNAME (skipped), then an A record,
    // their names pointing back at the question's.
    var a: [128]u8 = undefined;
    @memcpy(a[0..q.len], q);
    a[2] = 0x81;
    a[3] = 0x80;
    a[7] = 2; // two answers
    var at = q.len;
    const cname = [_]u8{ 0xc0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xc0, 12 };
    @memcpy(a[at..][0..cname.len], &cname);
    at += cname.len;
    const rec = [_]u8{ 0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 7 };
    @memcpy(a[at..][0..rec.len], &rec);
    at += rec.len;
    try testing.expectEqual(Ip4{ 203, 0, 113, 7 }, dnsAnswer(a[0..at], 0x1234).?);
    // Another query's, or an error.
    try testing.expect(dnsAnswer(a[0..at], 0x1235) == null);
    a[3] = 0x83; // NXDOMAIN
    try testing.expect(dnsAnswer(a[0..at], 0x1234) == null);
}
