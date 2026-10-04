//! IPv4 addresses for the network manager's interfaces: set by hand, or
//! got and kept by DHCP (the client runs in a process of its own for each
//! interface, see `runDhcp`, and waits for the link, renews the lease and
//! starts again when the link returns), and finding the wired adapter.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const dhcp = @import("dhcp.zig");

const Ip4 = dhcp.Ip4;
const print = sys.print;

pub const hostname = "stardust";

pub const Interface = struct {
    name_buf: [linux.IFNAMESIZE]u8 = @splat(0),
    name_len: usize = 0,
    mac: dhcp.Mac = undefined,

    pub fn named(n: []const u8) Interface {
        var i: Interface = .{ .name_len = @min(n.len, linux.IFNAMESIZE - 1) };
        @memcpy(i.name_buf[0..i.name_len], n[0..i.name_len]);
        return i;
    }

    pub fn name(i: *const Interface) []const u8 {
        return i.name_buf[0..i.name_len];
    }

    fn nameZ(i: *const Interface) [*:0]const u8 {
        return @ptrCast(&i.name_buf);
    }

    /// Reads /sys/class/net/<name>/<attr>.
    fn attr(i: *const Interface, comptime a: []const u8, buf: []u8) ?[]const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/net/{s}/" ++ a, .{i.name()}) catch return null;
        const text = sys.readFile(path.ptr, buf) orelse return null;
        return std.mem.trimEnd(u8, text, "\n");
    }

    pub fn exists(i: *const Interface) bool {
        var buf: [8]u8 = undefined;
        return i.attr("type", &buf) != null;
    }

    pub fn carrier(i: *const Interface) bool {
        var buf: [8]u8 = undefined;
        const c = i.attr("carrier", &buf) orelse return false;
        return std.mem.eql(u8, c, "1");
    }
};

/// The first wired Ethernet interface (sysfs type 1, not Wi-Fi), if any.
pub fn findEthernet() ?Interface {
    const dir = sys.open("/sys/class/net", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return null;
    defer sys.close(dir);
    var buf: [2048]u8 align(8) = undefined;
    const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch return null;
    var at: usize = 0;
    while (at < n) {
        const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
        const entry_name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
        at += reclen;
        if (entry_name.len == 0 or entry_name[0] == '.' or entry_name.len >= linux.IFNAMESIZE) continue;
        var i: Interface = .{ .name_len = entry_name.len };
        @memcpy(i.name_buf[0..entry_name.len], entry_name);
        var attr_buf: [32]u8 = undefined;
        // ARPHRD_ETHER; this also skips the loopback interface.
        if (!std.mem.eql(u8, i.attr("type", &attr_buf) orelse continue, "1")) continue;
        // Wi-Fi interfaces are Ethernet-like too, but need joining a
        // network first: they are Wi-Fi's (wifi.zig).
        if (i.attr("phy80211/name", &attr_buf) != null) continue;
        i.mac = parseMac(i.attr("address", &attr_buf) orelse continue) orelse continue;
        return i;
    }
    return null;
}

fn parseMac(s: []const u8) ?dhcp.Mac {
    var out: dhcp.Mac = undefined;
    var it = std.mem.splitScalar(u8, s, ':');
    for (&out) |*b| b.* = std.fmt.parseInt(u8, it.next() orelse return null, 16) catch return null;
    return out;
}

pub const Error = error{ InterfaceGone, LinkDown } || sys.Error;

fn ifreqFor(ifc: *const Interface) linux.ifreq {
    var req: linux.ifreq = undefined;
    @memset(std.mem.asBytes(&req), 0);
    req.ifrn.name = ifc.name_buf;
    return req;
}

fn sockaddr(ip: Ip4) linux.sockaddr {
    const in: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast(ip) };
    return @bitCast(in);
}

fn ioctl(fd: linux.fd_t, request: u32, arg: anytype) sys.Error!void {
    _ = try sys.check(linux.ioctl(fd, request, @intFromPtr(arg)));
}

fn setUp(ctl: linux.fd_t, ifc: *const Interface) Error!void {
    var req = ifreqFor(ifc);
    ioctl(ctl, linux.SIOCGIFFLAGS, &req) catch return error.InterfaceGone;
    req.ifru.flags.UP = true;
    try ioctl(ctl, linux.SIOCSIFFLAGS, &req);
}

/// struct rtentry, for SIOCADDRT.
const RtEntry = extern struct {
    pad1: c_ulong = 0,
    dst: linux.sockaddr,
    gateway: linux.sockaddr,
    genmask: linux.sockaddr,
    flags: c_ushort,
    pad2: c_short = 0,
    pad3: c_ulong = 0,
    pad4: ?*anyopaque = null,
    metric: c_short = 0,
    dev: ?[*:0]const u8 = null,
    mtu: c_ulong = 0,
    window: c_ulong = 0,
    irtt: c_ushort = 0,
};

/// Sets the interface's address (replacing any other, and the routes
/// through it) and default route, and brings it up.
fn configure(ctl: linux.fd_t, ifc: *const Interface, address: Ip4, prefix: u6, gateway: ?Ip4) Error!void {
    var req = ifreqFor(ifc);
    req.ifru.addr = sockaddr(address);
    try ioctl(ctl, linux.SIOCSIFADDR, &req);
    req.ifru.netmask = sockaddr(dhcp.maskFromPrefix(prefix));
    try ioctl(ctl, linux.SIOCSIFNETMASK, &req);
    req.ifru.broadaddr = sockaddr(dhcp.broadcastAddress(address, prefix));
    try ioctl(ctl, linux.SIOCSIFBRDADDR, &req);
    try setUp(ctl, ifc);
    if (gateway) |gw| {
        var route: RtEntry = .{
            .dst = sockaddr(.{ 0, 0, 0, 0 }),
            .gateway = sockaddr(gw),
            .genmask = sockaddr(.{ 0, 0, 0, 0 }),
            .flags = 0x1 | 0x2, // RTF_UP | RTF_GATEWAY
            .dev = ifc.nameZ(),
        };
        switch (linux.errno(linux.ioctl(ctl, linux.SIOCADDRT, @intFromPtr(&route)))) {
            // A route left from an earlier lease is fine.
            .SUCCESS, .EXIST => {},
            else => |e| return sys.errorFromErrno(e),
        }
    }
}

/// Removes the interface's address (and so its routes).
fn deconfigure(ctl: linux.fd_t, ifc: *const Interface) void {
    var req = ifreqFor(ifc);
    req.ifru.addr = sockaddr(.{ 0, 0, 0, 0 });
    _ = linux.ioctl(ctl, linux.SIOCSIFADDR, @intFromPtr(&req));
}

fn logAddress(ifc: *const Interface, address: Ip4, prefix: u6, gateway: ?Ip4, how: []const u8) void {
    var gw_buf: [32]u8 = undefined;
    const gw = if (gateway) |g| std.fmt.bufPrint(&gw_buf, ", gateway {d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) catch "" else "";
    print("stardust: network: {s} is {d}.{d}.{d}.{d}/{d}{s} ({s})\n", .{
        ifc.name(), address[0], address[1], address[2], address[3], prefix, gw, how,
    });
}

/// Keeps an address on the interface by DHCP until it disappears.
fn manage(ctl: linux.fd_t, ifc: *const Interface) Error!void {
    var previous: ?Ip4 = null;
    while (true) {
        try setUp(ctl, ifc);
        var waited = false;
        while (!ifc.carrier()) {
            if (!ifc.exists()) return error.InterfaceGone;
            if (!waited) print("stardust: network: {s} waiting for a link\n", .{ifc.name()});
            waited = true;
            sys.sleepMs(500);
        }
        print("stardust: network: {s} link up\n", .{ifc.name()});

        dhcpSession(ctl, ifc, &previous) catch |err| switch (err) {
            // Keep the address: the link may come straight back, and DHCP
            // then asks for the same one.
            error.LinkDown => print("stardust: network: {s} link down\n", .{ifc.name()}),
            else => return err,
        };
    }
}

/// Gets and keeps an address by DHCP for the interface called `name`: the
/// network manager runs this in a child process for the wired adapter, and
/// for Wi-Fi once it has joined a network, and stops it when it is no
/// longer wanted. Never returns.
pub fn runDhcp(name: []const u8) noreturn {
    var ifc = Interface.named(name);
    var attr_buf: [32]u8 = undefined;
    ifc.mac = parseMac(ifc.attr("address", &attr_buf) orelse linux.exit(1)) orelse linux.exit(1);
    const ctl: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch linux.exit(1));
    manage(ctl, &ifc) catch |err| print("stardust: network: {s}: {s}\n", .{ ifc.name(), @errorName(err) });
    linux.exit(0);
}

/// Gives the interface called `name` a fixed address (and default route,
/// if there is a gateway), replacing any other.
pub fn setStatic(name: []const u8, address: Ip4, prefix: u6, gateway: ?Ip4) Error!void {
    const ifc = Interface.named(name);
    const ctl: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(ctl);
    try configure(ctl, &ifc, address, prefix, gateway);
    logAddress(&ifc, address, prefix, gateway, "static");
}

/// Removes the address of the interface called `name`.
pub fn removeAddress(name: []const u8) void {
    const ifc = Interface.named(name);
    const ctl: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return);
    defer sys.close(ctl);
    deconfigure(ctl, &ifc);
}

fn checkLink(ifc: *const Interface) Error!void {
    if (!ifc.exists()) return error.InterfaceGone;
    if (!ifc.carrier()) return error.LinkDown;
}

const Client = struct {
    sock: linux.fd_t,
    ifc: *const Interface,
    xid: u32,

    fn open(ifc: *const Interface) Error!Client {
        const sock: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
        errdefer sys.close(sock);
        const one: c_int = 1;
        _ = try sys.check(linux.setsockopt(sock, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int)));
        _ = try sys.check(linux.setsockopt(sock, linux.SOL.SOCKET, linux.SO.BROADCAST, std.mem.asBytes(&one), @sizeOf(c_int)));
        // Send and receive on this interface only, even without an address.
        _ = try sys.check(linux.setsockopt(sock, linux.SOL.SOCKET, linux.SO.BINDTODEVICE, &ifc.name_buf, @intCast(ifc.name_len)));
        const addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, dhcp.client_port), .addr = 0 };
        _ = try sys.check(linux.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
        const seed: u32 = @truncate(sys.nowNs());
        return .{ .sock = sock, .ifc = ifc, .xid = seed ^ std.mem.readInt(u32, ifc.mac[2..6], .big) };
    }

    fn close(c: *Client) void {
        sys.close(c.sock);
    }

    fn send(c: *Client, r: dhcp.Request, to: Ip4) void {
        var buf: [dhcp.max_message_size]u8 = undefined;
        const msg = dhcp.build(&buf, r);
        const dest: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, dhcp.server_port), .addr = @bitCast(to) };
        _ = linux.sendto(c.sock, msg.ptr, msg.len, 0, @ptrCast(&dest), @sizeOf(@TypeOf(dest)));
    }

    /// Waits until `deadline` for a reply of one of the wanted types to the
    /// current transaction, checking the link every second.
    fn receive(c: *Client, deadline: u64, wanted: []const dhcp.MessageType) Error!?dhcp.Reply {
        while (true) {
            try checkLink(c.ifc);
            const now = sys.nowNs();
            if (now >= deadline) return null;
            const wait_ms: i32 = @intCast(@min((deadline - now) / std.time.ns_per_ms + 1, 1000));
            var fds = [_]linux.pollfd{.{ .fd = c.sock, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&fds, 1, wait_ms);
            if (linux.errno(rc) != .SUCCESS or rc == 0) continue;
            var buf: [1500]u8 = undefined;
            const n = linux.recvfrom(c.sock, &buf, buf.len, 0, null, null);
            if (linux.errno(n) != .SUCCESS) continue;
            const reply = dhcp.parse(buf[0..n], c.ifc.mac) orelse continue;
            if (reply.xid != c.xid) continue;
            if (std.mem.indexOfScalar(dhcp.MessageType, wanted, reply.type) != null) return reply;
        }
    }

    /// Sends `r` and waits for an answer, retrying with backoff (4, 8, 16,
    /// 32, then every 64 seconds) until `give_up`.
    fn exchange(c: *Client, r: dhcp.Request, to: Ip4, wanted: []const dhcp.MessageType, give_up: ?u64) Error!?dhcp.Reply {
        var timeout_s: u64 = 4;
        while (true) {
            const now = sys.nowNs();
            if (give_up) |g| if (now >= g) return null;
            c.send(r, to);
            var deadline = now + timeout_s * std.time.ns_per_s;
            if (give_up) |g| deadline = @min(deadline, g);
            if (try c.receive(deadline, wanted)) |reply| return reply;
            timeout_s = @min(timeout_s * 2, 64);
        }
    }
};

const broadcast: Ip4 = .{ 255, 255, 255, 255 };

/// Gets a lease and keeps renewing it until the link goes down or the
/// interface goes away.
fn dhcpSession(ctl: linux.fd_t, ifc: *const Interface, previous: *?Ip4) Error!void {
    var c = try Client.open(ifc);
    defer c.close();
    var configured = false;
    while (true) {
        // Selecting: discover servers and request the first offer.
        c.xid +%= 1;
        const offer = (try c.exchange(.{ .type = .discover, .xid = c.xid, .mac = ifc.mac, .requested_ip = previous.*, .hostname = hostname }, broadcast, &.{.offer}, null)).?;
        const server = offer.server_id orelse continue;
        const ack = (try c.exchange(.{
            .type = .request,
            .xid = c.xid,
            .mac = ifc.mac,
            .requested_ip = offer.yiaddr,
            .server_id = server,
            .hostname = hostname,
        }, broadcast, &.{ .ack, .nak }, sys.nowNs() + 60 * std.time.ns_per_s)) orelse continue;
        if (ack.type == .nak) continue;

        var lease = dhcp.Lease.fromAck(ack, server);
        while (true) {
            const granted = sys.nowNs();
            try configure(ctl, ifc, lease.address, lease.prefix, lease.gateway);
            if (!configured or previous.* == null or !std.mem.eql(u8, &previous.*.?, &lease.address)) {
                var how_buf: [48]u8 = undefined;
                logAddress(ifc, lease.address, lease.prefix, lease.gateway, std.fmt.bufPrint(&how_buf, "DHCP, lease {d} s", .{lease.expires_after}) catch "DHCP");
            }
            configured = true;
            previous.* = lease.address;

            // Bound until the renewal time.
            const s = std.time.ns_per_s;
            _ = try c.receive(granted + @as(u64, lease.renew_after) * s, &.{});
            // Renewing: ask the server that granted the lease, then any
            // server, until the lease runs out.
            c.xid +%= 1;
            const renew: dhcp.Request = .{ .type = .request, .xid = c.xid, .mac = ifc.mac, .ciaddr = lease.address, .hostname = hostname };
            const reply = (try c.exchange(renew, lease.server, &.{ .ack, .nak }, granted + @as(u64, lease.rebind_after) * s)) orelse
                (try c.exchange(renew, broadcast, &.{ .ack, .nak }, granted + @as(u64, lease.expires_after) * s));
            if (reply != null and reply.?.type == .ack) {
                lease = dhcp.Lease.fromAck(reply.?, lease.server);
                continue;
            }
            print("stardust: network: {s} lost its lease\n", .{ifc.name()});
            deconfigure(ctl, ifc);
            configured = false;
            break;
        }
    }
}

/// The interface's IPv4 address, if it has one.
pub fn interfaceAddress(name: []const u8) ?Ip4 {
    const sock: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return null);
    defer sys.close(sock);
    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    const n = @min(name.len, req.ifrn.name.len - 1);
    @memcpy(req.ifrn.name[0..n], name[0..n]);
    if (linux.errno(linux.ioctl(sock, linux.SIOCGIFADDR, @intFromPtr(&req))) != .SUCCESS) return null;
    const in: *const linux.sockaddr.in = @ptrCast(@alignCast(&req.ifru.addr));
    const a: [4]u8 = @bitCast(in.addr);
    return if (std.mem.allEqual(u8, &a, 0)) null else a;
}

/// Brings an interface up. Returns whether it is up.
pub fn bringUp(name: []const u8) bool {
    const sock: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return false);
    defer sys.close(sock);
    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    const n = @min(name.len, req.ifrn.name.len - 1);
    @memcpy(req.ifrn.name[0..n], name[0..n]);
    if (linux.errno(linux.ioctl(sock, linux.SIOCGIFFLAGS, @intFromPtr(&req))) != .SUCCESS) return false;
    if (req.ifru.flags.UP) return true;
    req.ifru.flags.UP = true;
    if (linux.errno(linux.ioctl(sock, linux.SIOCSIFFLAGS, @intFromPtr(&req))) != .SUCCESS) {
        print("stardust: network: cannot bring {s} up\n", .{name});
        return false;
    }
    return true;
}

const testing = std.testing;

test "parse MAC address" {
    try testing.expectEqual(dhcp.Mac{ 0x52, 0x54, 0, 0x12, 0x34, 0xab }, parseMac("52:54:00:12:34:ab").?);
    try testing.expect(parseMac("52:54:00") == null);
}

comptime {
    // struct rtentry on 32-bit ARM, as laid out by the kernel headers.
    if (@sizeOf(usize) == 4) {
        std.debug.assert(@offsetOf(RtEntry, "flags") == 52);
        std.debug.assert(@offsetOf(RtEntry, "dev") == 68);
        std.debug.assert(@sizeOf(RtEntry) == 84);
    }
}
