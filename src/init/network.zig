//! The network manager: brings up the wired Ethernet interface and keeps it
//! configured, without holding up boot.
//!
//! Init forks it early. It waits for an Ethernet interface to appear (a USB
//! adapter can be plugged in at any time), brings it up and waits for a
//! link. Then it configures the interface: by DHCP, renewing the lease as it
//! goes, or with the static address from `stardust.ip=`. If the link drops
//! it starts again when the link returns, and if the adapter is unplugged it
//! goes back to waiting for one.
//!
//! It runs as the Stardust user and keeps only the capabilities this needs:
//! changing interfaces and routes (CAP_NET_ADMIN), tying its socket to the
//! interface (CAP_NET_RAW) and the DHCP client port (CAP_NET_BIND_SERVICE).
//!
//! Options on the kernel command line:
//!
//! * `stardust.ip=<address>/<prefix>[,<gateway>]` sets a static address
//!   instead of using DHCP, for example `stardust.ip=192.168.1.50/24,192.168.1.1`.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const dhcp = @import("dhcp.zig");

const Ip4 = dhcp.Ip4;
const print = sys.print;

pub const hostname = "stardust";

pub const Static = struct {
    address: Ip4,
    prefix: u6,
    gateway: ?Ip4 = null,
};

pub const Config = struct {
    static: ?Static = null,
};

pub fn parseIp4(s: []const u8) ?Ip4 {
    var out: Ip4 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&out) |*b| b.* = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    return if (it.next() == null) out else null;
}

/// Reads `stardust.*` network options from a kernel command line.
pub fn parseCmdline(cmdline: []const u8) Config {
    const value = sys.cmdlineValue(cmdline, "stardust.ip") orelse return .{};
    var parts = std.mem.splitScalar(u8, value, ',');
    const cidr = parts.next().?;
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return .{};
    const address = parseIp4(cidr[0..slash]) orelse return .{};
    const prefix = std.fmt.parseInt(u6, cidr[slash + 1 ..], 10) catch return .{};
    if (prefix > 32) return .{};
    const gateway = if (parts.next()) |g| parseIp4(g) orelse return .{} else null;
    return .{ .static = .{ .address = address, .prefix = prefix, .gateway = gateway } };
}

/// Forks the network manager. Returns its PID in the parent.
pub fn start() ?linux.pid_t {
    var cmdline_buf: [1024]u8 = undefined;
    const cfg = parseCmdline(sys.readCmdline(&cmdline_buf));
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print("stardust: network: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    sys.dropPrivilegesKeeping(&.{ .net_admin, .net_raw, .net_bind_service }) catch |err| {
        print("stardust: network: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    run(cfg);
}

const Interface = struct {
    name_buf: [linux.IFNAMESIZE]u8 = @splat(0),
    name_len: usize = 0,
    mac: dhcp.Mac = undefined,

    fn name(i: *const Interface) []const u8 {
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

    fn exists(i: *const Interface) bool {
        var buf: [8]u8 = undefined;
        return i.attr("type", &buf) != null;
    }

    fn carrier(i: *const Interface) bool {
        var buf: [8]u8 = undefined;
        const c = i.attr("carrier", &buf) orelse return false;
        return std.mem.eql(u8, c, "1");
    }
};

fn run(cfg: Config) noreturn {
    const ctl: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch {
        print("stardust: network: no IPv4 socket\n", .{});
        linux.exit(1);
    });
    var lo: Interface = .{};
    @memcpy(lo.name_buf[0..2], "lo");
    lo.name_len = 2;
    configure(ctl, &lo, .{ 127, 0, 0, 1 }, 8, null) catch {};

    while (true) {
        const ifc = waitForInterface();
        print("stardust: network: found {s} ({x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2})\n", .{
            ifc.name(), ifc.mac[0], ifc.mac[1], ifc.mac[2], ifc.mac[3], ifc.mac[4], ifc.mac[5],
        });
        manage(ctl, &ifc, cfg) catch |err| switch (err) {
            error.InterfaceGone => print("stardust: network: {s} removed\n", .{ifc.name()}),
            else => {
                print("stardust: network: {s}: {s}\n", .{ ifc.name(), @errorName(err) });
                sys.sleepMs(5000);
            },
        };
    }
}

/// Waits for a wired Ethernet interface (sysfs type 1, not Wi-Fi) and
/// returns the first.
fn waitForInterface() Interface {
    var reported = false;
    while (true) {
        if (findInterface()) |i| return i;
        if (!reported) print("stardust: network: waiting for an Ethernet adapter\n", .{});
        reported = true;
        sys.sleepMs(1000);
    }
}

fn findInterface() ?Interface {
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
        // network first: they are the Wi-Fi manager's.
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

const Error = error{ InterfaceGone, LinkDown } || sys.Error;

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

/// Manages one interface until it disappears.
fn manage(ctl: linux.fd_t, ifc: *const Interface, cfg: Config) Error!void {
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

        const result = if (cfg.static) |s| blk: {
            try configure(ctl, ifc, s.address, s.prefix, s.gateway);
            logAddress(ifc, s.address, s.prefix, s.gateway, "static");
            break :blk waitLinkDown(ifc);
        } else dhcpSession(ctl, ifc, &previous);
        result catch |err| switch (err) {
            // Keep the address: the link may come straight back, and DHCP
            // then asks for the same one.
            error.LinkDown => print("stardust: network: {s} link down\n", .{ifc.name()}),
            else => return err,
        };
    }
}

fn checkLink(ifc: *const Interface) Error!void {
    if (!ifc.exists()) return error.InterfaceGone;
    if (!ifc.carrier()) return error.LinkDown;
}

fn waitLinkDown(ifc: *const Interface) Error!void {
    while (true) {
        try checkLink(ifc);
        sys.sleepMs(1000);
    }
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

const testing = std.testing;

test "static address option" {
    const cfg = parseCmdline("console=ttyAMA0 stardust.ip=192.168.1.50/24,192.168.1.1\n");
    try testing.expectEqual(Ip4{ 192, 168, 1, 50 }, cfg.static.?.address);
    try testing.expectEqual(@as(u6, 24), cfg.static.?.prefix);
    try testing.expectEqual(Ip4{ 192, 168, 1, 1 }, cfg.static.?.gateway.?);
    try testing.expectEqual(@as(?Ip4, null), parseCmdline("stardust.ip=10.0.0.2/8").static.?.gateway);
    try testing.expect(parseCmdline("stardust.ip=10.0.0/8").static == null);
    try testing.expect(parseCmdline("stardust.ip=10.0.0.2/33").static == null);
    try testing.expect(parseCmdline("ip=dhcp").static == null);
}

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
