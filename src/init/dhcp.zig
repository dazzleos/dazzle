//! DHCP (RFC 2131) messages: building client requests and parsing server
//! replies. No system calls here; `network.zig` sends and receives them.

const std = @import("std");

pub const Ip4 = [4]u8;
pub const Mac = [6]u8;

pub const client_port = 68;
pub const server_port = 67;

pub const MessageType = enum(u8) {
    discover = 1,
    offer = 2,
    request = 3,
    decline = 4,
    ack = 5,
    nak = 6,
    release = 7,
    inform = 8,
    _,
};

const magic_cookie = [4]u8{ 99, 130, 83, 99 };
/// Fixed BOOTP header size, before the magic cookie and options.
const header_size = 236;
/// Some servers ignore requests shorter than a BOOTP message.
const min_message_size = 300;
pub const max_message_size = 576;

const Option = struct {
    const pad = 0;
    const subnet_mask = 1;
    const router = 3;
    const dns = 6;
    const hostname = 12;
    const ntp = 42;
    const requested_ip = 50;
    const lease_time = 51;
    const message_type = 53;
    const server_id = 54;
    const parameter_list = 55;
    const renewal_time = 58;
    const rebinding_time = 59;
    const client_id = 61;
    const end = 255;
};

pub const Request = struct {
    type: MessageType,
    xid: u32,
    mac: Mac,
    /// Our current address when renewing or rebinding.
    ciaddr: Ip4 = .{ 0, 0, 0, 0 },
    /// The offered (or previous) address, when selecting or rebooting.
    requested_ip: ?Ip4 = null,
    /// The chosen server, when selecting.
    server_id: ?Ip4 = null,
    hostname: []const u8 = "",
};

/// Builds a client message into `buf` and returns it.
pub fn build(buf: *[max_message_size]u8, r: Request) []const u8 {
    @memset(buf, 0);
    buf[0] = 1; // BOOTREQUEST
    buf[1] = 1; // Ethernet
    buf[2] = 6; // hardware address length
    std.mem.writeInt(u32, buf[4..8], r.xid, .big);
    // Ask for broadcast replies: until it is configured the interface
    // cannot receive packets sent to the offered address.
    const unconfigured = std.mem.eql(u8, &r.ciaddr, &.{ 0, 0, 0, 0 });
    if (unconfigured) std.mem.writeInt(u16, buf[10..12], 0x8000, .big);
    buf[12..16].* = r.ciaddr;
    buf[28..34].* = r.mac;
    buf[header_size..][0..4].* = magic_cookie;

    var at: usize = header_size + 4;
    const put = struct {
        fn f(b: []u8, pos: *usize, code: u8, data: []const u8) void {
            b[pos.*] = code;
            b[pos.* + 1] = @intCast(data.len);
            @memcpy(b[pos.* + 2 ..][0..data.len], data);
            pos.* += 2 + data.len;
        }
    }.f;
    put(buf, &at, Option.message_type, &.{@intFromEnum(r.type)});
    put(buf, &at, Option.client_id, &([1]u8{1} ++ r.mac));
    if (r.requested_ip) |ip| put(buf, &at, Option.requested_ip, &ip);
    if (r.server_id) |ip| put(buf, &at, Option.server_id, &ip);
    if (r.hostname.len > 0) put(buf, &at, Option.hostname, r.hostname[0..@min(r.hostname.len, 63)]);
    put(buf, &at, Option.parameter_list, &.{
        Option.subnet_mask, Option.router, Option.dns, Option.ntp, Option.lease_time, Option.server_id, Option.renewal_time, Option.rebinding_time,
    });
    buf[at] = Option.end;
    at += 1;
    return buf[0..@max(at, min_message_size)];
}

pub const Reply = struct {
    type: MessageType,
    xid: u32,
    yiaddr: Ip4,
    server_id: ?Ip4 = null,
    subnet_mask: ?Ip4 = null,
    router: ?Ip4 = null,
    /// Name servers, and time servers (the first few of each).
    dns: Servers = .{},
    ntp: Servers = .{},
    /// Seconds; null means the server did not say.
    lease_time: ?u32 = null,
    renewal_time: ?u32 = null,
    rebinding_time: ?u32 = null,
};

/// Parses a server reply for the client with this hardware address.
/// Returns null for anything else (or anything malformed).
pub fn parse(msg: []const u8, mac: Mac) ?Reply {
    if (msg.len < header_size + 4) return null;
    if (msg[0] != 2 or msg[1] != 1 or msg[2] != 6) return null; // BOOTREPLY, Ethernet
    if (!std.mem.eql(u8, msg[28..34], &mac)) return null;
    if (!std.mem.eql(u8, msg[header_size..][0..4], &magic_cookie)) return null;
    var r: Reply = .{
        .type = @enumFromInt(0),
        .xid = std.mem.readInt(u32, msg[4..8], .big),
        .yiaddr = msg[16..20].*,
    };
    var have_type = false;
    var at: usize = header_size + 4;
    while (at < msg.len) {
        const code = msg[at];
        if (code == Option.end) break;
        if (code == Option.pad) {
            at += 1;
            continue;
        }
        if (at + 1 >= msg.len) return null;
        const len = msg[at + 1];
        if (at + 2 + len > msg.len) return null;
        const data = msg[at + 2 ..][0..len];
        at += 2 + len;
        switch (code) {
            Option.message_type => if (len == 1) {
                r.type = @enumFromInt(data[0]);
                have_type = true;
            },
            Option.server_id => if (len == 4) {
                r.server_id = data[0..4].*;
            },
            Option.subnet_mask => if (len == 4) {
                r.subnet_mask = data[0..4].*;
            },
            // The first router is the default gateway.
            Option.router => if (len >= 4) {
                r.router = data[0..4].*;
            },
            Option.dns => r.dns = .parse(data),
            Option.ntp => r.ntp = .parse(data),
            Option.lease_time => if (len == 4) {
                r.lease_time = std.mem.readInt(u32, data[0..4], .big);
            },
            Option.renewal_time => if (len == 4) {
                r.renewal_time = std.mem.readInt(u32, data[0..4], .big);
            },
            Option.rebinding_time => if (len == 4) {
                r.rebinding_time = std.mem.readInt(u32, data[0..4], .big);
            },
            else => {},
        }
    }
    return if (have_type) r else null;
}

/// Up to three servers' addresses, from an option listing them.
pub const Servers = struct {
    list: [3]Ip4 = undefined,
    len: usize = 0,

    fn parse(data: []const u8) Servers {
        var s: Servers = .{};
        while (s.len < s.list.len and (s.len + 1) * 4 <= data.len) : (s.len += 1) s.list[s.len] = data[s.len * 4 ..][0..4].*;
        return s;
    }

    pub fn slice(s: *const Servers) []const Ip4 {
        return s.list[0..s.len];
    }
};

/// The address, mask and gateway granted by an ACK (with the name and
/// time servers), and when to renew.
pub const Lease = struct {
    address: Ip4,
    prefix: u6,
    gateway: ?Ip4,
    dns: Servers,
    ntp: Servers,
    server: Ip4,
    /// Seconds from when the lease was granted.
    renew_after: u32,
    rebind_after: u32,
    expires_after: u32,

    pub fn fromAck(ack: Reply, server: Ip4) Lease {
        const lease = ack.lease_time orelse 3600;
        // An infinite lease (0xffffffff) still gets renewed now and then.
        const length = @min(lease, 7 * 24 * 3600);
        return .{
            .address = ack.yiaddr,
            .prefix = if (ack.subnet_mask) |m| prefixLength(m) else defaultPrefix(ack.yiaddr),
            .gateway = ack.router,
            .dns = ack.dns,
            .ntp = ack.ntp,
            .server = ack.server_id orelse server,
            .renew_after = @min(ack.renewal_time orelse length / 2, length),
            .rebind_after = @min(ack.rebinding_time orelse length / 8 * 7, length),
            .expires_after = length,
        };
    }
};

pub fn prefixLength(mask: Ip4) u6 {
    return @intCast(@popCount(std.mem.readInt(u32, &mask, .big)));
}

pub fn maskFromPrefix(prefix: u6) Ip4 {
    const bits: u32 = if (prefix == 0) 0 else ~@as(u32, 0) << @intCast(32 - @as(u32, prefix));
    var out: Ip4 = undefined;
    std.mem.writeInt(u32, &out, bits, .big);
    return out;
}

fn defaultPrefix(ip: Ip4) u6 {
    return if (ip[0] < 128) 8 else if (ip[0] < 192) 16 else 24;
}

pub fn broadcastAddress(ip: Ip4, prefix: u6) Ip4 {
    const mask = std.mem.readInt(u32, &maskFromPrefix(prefix), .big);
    var out: Ip4 = undefined;
    std.mem.writeInt(u32, &out, std.mem.readInt(u32, &ip, .big) | ~mask, .big);
    return out;
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const test_mac: Mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };

fn testReply(buf: *[max_message_size]u8, msg_type: MessageType, options: []const u8) []const u8 {
    @memset(buf, 0);
    buf[0] = 2;
    buf[1] = 1;
    buf[2] = 6;
    std.mem.writeInt(u32, buf[4..8], 0xdeadbeef, .big);
    buf[16..20].* = .{ 10, 0, 2, 15 };
    buf[28..34].* = test_mac;
    buf[header_size..][0..4].* = magic_cookie;
    var at: usize = header_size + 4;
    buf[at..][0..3].* = .{ Option.message_type, 1, @intFromEnum(msg_type) };
    at += 3;
    @memcpy(buf[at..][0..options.len], options);
    at += options.len;
    buf[at] = Option.end;
    return buf[0 .. at + 1];
}

test "discover message" {
    var buf: [max_message_size]u8 = undefined;
    const msg = build(&buf, .{ .type = .discover, .xid = 0x01020304, .mac = test_mac, .hostname = "dazzle" });
    try testing.expectEqual(@as(usize, min_message_size), msg.len);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 6, 0, 1, 2, 3, 4, 0, 0, 0x80, 0 }, msg[0..12]);
    try testing.expectEqualSlices(u8, &test_mac, msg[28..34]);
    try testing.expectEqualSlices(u8, &(magic_cookie ++ [_]u8{ 53, 1, 1, 61, 7, 1 }), msg[236..246]);
    try testing.expect(std.mem.indexOf(u8, msg, &([_]u8{ 12, 6 } ++ "dazzle".*)) != null);
}

test "renewal requests are unicast and carry ciaddr" {
    var buf: [max_message_size]u8 = undefined;
    const msg = build(&buf, .{ .type = .request, .xid = 7, .mac = test_mac, .ciaddr = .{ 10, 0, 2, 15 } });
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, msg[10..12]);
    try testing.expectEqualSlices(u8, &.{ 10, 0, 2, 15 }, msg[12..16]);
    // No requested address or server ID while renewing.
    try testing.expect(std.mem.indexOfScalar(u8, msg[240..], 50) == null);
}

test "parse an ack" {
    var buf: [max_message_size]u8 = undefined;
    const msg = testReply(&buf, .ack, &.{
        1,  4, 255, 255, 255, 0,
        3,  8, 10,  0,   2,   2,
        10, 0, 2,   3,   51,  4,
        0,  1, 81,  128, 54,  4,
        10, 0, 2,   2,   6,   8,
        10, 0, 2,   3,   1,   1,
        1,  1, 42,  4,   10,  0,
        2,  4,
    });
    const r = parse(msg, test_mac).?;
    try testing.expectEqual(MessageType.ack, r.type);
    try testing.expectEqual(@as(u32, 0xdeadbeef), r.xid);
    try testing.expectEqual(Ip4{ 10, 0, 2, 15 }, r.yiaddr);
    try testing.expectEqual(Ip4{ 10, 0, 2, 2 }, r.router.?);
    const lease = Lease.fromAck(r, .{ 0, 0, 0, 0 });
    try testing.expectEqual(@as(u6, 24), lease.prefix);
    try testing.expectEqual(@as(u32, 86400), lease.expires_after);
    try testing.expectEqual(@as(u32, 43200), lease.renew_after);
    try testing.expectEqual(@as(u32, 75600), lease.rebind_after);
    try testing.expectEqual(Ip4{ 10, 0, 2, 2 }, lease.server);
    try testing.expectEqualSlices(Ip4, &.{ .{ 10, 0, 2, 3 }, .{ 1, 1, 1, 1 } }, lease.dns.slice());
    try testing.expectEqualSlices(Ip4, &.{.{ 10, 0, 2, 4 }}, lease.ntp.slice());
}

test "replies for other clients or malformed ones are ignored" {
    var buf: [max_message_size]u8 = undefined;
    const msg = testReply(&buf, .offer, &.{});
    try testing.expect(parse(msg, .{ 1, 2, 3, 4, 5, 6 }) == null);
    try testing.expect(parse(msg[0..100], test_mac) == null);
    // An option running past the end.
    const bad = testReply(&buf, .offer, &.{ 51, 40, 0 });
    try testing.expect(parse(bad[0 .. bad.len - 1], test_mac) == null);
}

test "masks and prefixes" {
    try testing.expectEqual(@as(u6, 24), prefixLength(.{ 255, 255, 255, 0 }));
    try testing.expectEqual(Ip4{ 255, 255, 240, 0 }, maskFromPrefix(20));
    try testing.expectEqual(Ip4{ 0, 0, 0, 0 }, maskFromPrefix(0));
    try testing.expectEqual(Ip4{ 192, 168, 1, 255 }, broadcastAddress(.{ 192, 168, 1, 42 }, 24));
}
