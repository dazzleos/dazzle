//! The machine's IPv4 address, for display. SIOCGIFCONF lists every
//! interface that has an address; it needs no privileges.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const Address = struct {
    ip: [4]u8,
    name_buf: [linux.IFNAMESIZE]u8,

    pub fn name(a: *const Address) []const u8 {
        return std.mem.sliceTo(&a.name_buf, 0);
    }
};

const ifconf = extern struct {
    len: c_int,
    buf: ?[*]linux.ifreq,
};

/// The first IPv4 address on an interface other than loopback, if any.
pub fn primaryAddress() ?Address {
    const sock: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return null);
    defer sys.close(sock);
    var reqs: [8]linux.ifreq = undefined;
    var conf: ifconf = .{ .len = @sizeOf(@TypeOf(reqs)), .buf = &reqs };
    _ = sys.check(linux.ioctl(sock, linux.SIOCGIFCONF, @intFromPtr(&conf))) catch return null;
    const count: usize = @as(usize, @intCast(conf.len)) / @sizeOf(linux.ifreq);
    return pick(reqs[0..count]);
}

fn pick(reqs: []const linux.ifreq) ?Address {
    for (reqs) |*r| {
        const n = std.mem.sliceTo(&r.ifrn.name, 0);
        if (std.mem.eql(u8, n, "lo")) continue;
        if (r.ifru.addr.family != linux.AF.INET) continue;
        const in: *const linux.sockaddr.in = @ptrCast(@alignCast(&r.ifru.addr));
        return .{ .ip = @bitCast(in.addr), .name_buf = r.ifrn.name };
    }
    return null;
}

test "loopback is skipped" {
    var reqs: [2]linux.ifreq = undefined;
    @memset(std.mem.sliceAsBytes(&reqs), 0);
    for (&reqs, [_][]const u8{ "lo", "eth0" }, [_][4]u8{ .{ 127, 0, 0, 1 }, .{ 192, 168, 1, 42 } }) |*r, n, ip| {
        @memcpy(r.ifrn.name[0..n.len], n);
        const in: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast(ip) };
        r.ifru.addr = @bitCast(in);
    }
    const a = pick(&reqs).?;
    try std.testing.expectEqualStrings("eth0", a.name());
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 42 }, a.ip);
    try std.testing.expect(pick(reqs[0..1]) == null);
}
