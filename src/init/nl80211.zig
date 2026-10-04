//! nl80211, Linux's Wi-Fi configuration interface, over generic netlink:
//! finding the Wi-Fi adapter, starting scans, hearing when they finish and
//! reading what they found. Just what the Wi-Fi manager needs.
//!
//! Generic netlink messages are a netlink header, a generic netlink header
//! (the command) and attributes: type-length-value records, 4-byte aligned,
//! some holding further attributes (nested).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const wifi = sys.wifi;

// netlink.h, genetlink.h
const netlink_generic = 16;
const sol_netlink = 270;
const netlink_add_membership = 1;
const nlm_f_request = 0x01;
const nlm_f_multi = 0x02;
const nlm_f_ack = 0x04;
const nlm_f_dump = 0x300;
const nlmsg_error = 2;
const nlmsg_done = 3;
const genl_id_ctrl = 0x10;
const ctrl_cmd_getfamily = 3;
const ctrl_attr_family_id = 1;
const ctrl_attr_family_name = 2;
const ctrl_attr_mcast_groups = 7;
const ctrl_attr_mcast_grp_name = 1;
const ctrl_attr_mcast_grp_id = 2;

// nl80211.h
pub const cmd = struct {
    pub const get_interface = 5;
    pub const new_interface = 7;
    pub const get_scan = 32;
    pub const trigger_scan = 33;
    pub const new_scan_results = 34;
    pub const scan_aborted = 35;
};
const attr = struct {
    const ifindex = 3;
    const ifname = 4;
    const iftype = 5;
    const mac = 6;
    const bss = 47;
};
const bss = struct {
    const frequency = 2;
    const capability = 5;
    const information_elements = 6;
    const signal_mbm = 7;
};
const iftype_station = 2;

const nlmsghdr_len = 16;
const genlmsghdr_len = 4;

/// An attribute: its type (without the nested and byte order flags) and
/// value.
pub const Attr = struct {
    type: u16,
    data: []const u8,

    pub fn int(a: Attr, comptime T: type) ?T {
        if (a.data.len < @sizeOf(T)) return null;
        return std.mem.readInt(T, a.data[0..@sizeOf(T)], .little);
    }

    pub fn string(a: Attr) []const u8 {
        return std.mem.sliceTo(a.data, 0);
    }
};

pub const Attrs = struct {
    rest: []const u8,

    pub fn of(data: []const u8) Attrs {
        return .{ .rest = data };
    }

    pub fn next(it: *Attrs) ?Attr {
        if (it.rest.len < 4) return null;
        const len = std.mem.readInt(u16, it.rest[0..2], .little);
        const typ = std.mem.readInt(u16, it.rest[2..4], .little) & 0x3fff;
        if (len < 4 or len > it.rest.len) return null;
        const a: Attr = .{ .type = typ, .data = it.rest[4..len] };
        it.rest = it.rest[@min(std.mem.alignForward(usize, len, 4), it.rest.len)..];
        return a;
    }

    /// The first attribute of this type.
    pub fn find(data: []const u8, typ: u16) ?Attr {
        var it = of(data);
        while (it.next()) |a| if (a.type == typ) return a;
        return null;
    }
};

/// Builds a generic netlink request.
const Message = struct {
    buf: [256]u8 = undefined,
    len: usize = nlmsghdr_len + genlmsghdr_len,

    fn put(m: *Message, typ: u16, data: []const u8) void {
        const len: u16 = @intCast(4 + data.len);
        std.mem.writeInt(u16, m.buf[m.len..][0..2], len, .little);
        std.mem.writeInt(u16, m.buf[m.len + 2 ..][0..2], typ, .little);
        @memcpy(m.buf[m.len + 4 ..][0..data.len], data);
        const end = m.len + std.mem.alignForward(usize, len, 4);
        @memset(m.buf[m.len + len .. end], 0);
        m.len = end;
    }

    fn finish(m: *Message, family: u16, flags: u16, seq: u32, command: u8) []const u8 {
        std.mem.writeInt(u32, m.buf[0..4], @intCast(m.len), .little);
        std.mem.writeInt(u16, m.buf[4..6], family, .little);
        std.mem.writeInt(u16, m.buf[6..8], flags, .little);
        std.mem.writeInt(u32, m.buf[8..12], seq, .little);
        std.mem.writeInt(u32, m.buf[12..16], 0, .little);
        m.buf[16] = command;
        m.buf[17] = 1; // version
        m.buf[18] = 0;
        m.buf[19] = 0;
        return m.buf[0..m.len];
    }
};

/// A message received: its type (a family, or a control code), and for
/// generic netlink its command and attributes.
pub const Received = struct {
    type: u16,
    flags: u16,
    seq: u32,
    command: u8,
    attrs: []const u8,
    /// For an error or acknowledgement: 0 or a negative errno.
    err: i32 = 0,
};

/// Splits a datagram into its messages.
pub const Messages = struct {
    rest: []const u8,

    pub fn next(it: *Messages) ?Received {
        if (it.rest.len < nlmsghdr_len) return null;
        const len = std.mem.readInt(u32, it.rest[0..4], .little);
        if (len < nlmsghdr_len or len > it.rest.len) return null;
        const m = it.rest[0..len];
        it.rest = it.rest[@min(std.mem.alignForward(usize, len, 4), it.rest.len)..];
        var r: Received = .{
            .type = std.mem.readInt(u16, m[4..6], .little),
            .flags = std.mem.readInt(u16, m[6..8], .little),
            .seq = std.mem.readInt(u32, m[8..12], .little),
            .command = 0,
            .attrs = &.{},
        };
        if (r.type == nlmsg_error) {
            if (m.len >= nlmsghdr_len + 4) r.err = std.mem.readInt(i32, m[16..20], .little);
        } else if (r.type != nlmsg_done and m.len >= nlmsghdr_len + genlmsghdr_len) {
            r.command = m[16];
            r.attrs = m[nlmsghdr_len + genlmsghdr_len ..];
        }
        return r;
    }
};

pub const Error = sys.Error || error{ NoNl80211, Netlink };

const Socket = struct {
    fd: linux.fd_t,
    seq: u32 = 1,

    fn open() Error!Socket {
        const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, netlink_generic)));
        errdefer sys.close(fd);
        const Addr = extern struct { family: u16 = linux.AF.NETLINK, pad: u16 = 0, pid: u32 = 0, groups: u32 = 0 };
        const addr: Addr = .{};
        _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(Addr)));
        // Requests are answered at once; do not wait forever if not.
        const tv: linux.timeval = .{ .sec = 2, .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        return .{ .fd = fd };
    }

    /// Sends a request and hands each reply to `on`, until the reply ends
    /// (an acknowledgement, or the end of a dump).
    fn request(s: *Socket, m: *Message, family: u16, flags: u16, command: u8, ctx: anytype, comptime on: fn (@TypeOf(ctx), Received) void) Error!void {
        const seq = s.seq;
        s.seq +%= 1;
        const bytes = m.finish(family, flags | nlm_f_request | nlm_f_ack, seq, command);
        _ = try sys.check(linux.write(s.fd, bytes.ptr, bytes.len));
        var buf: [32768]u8 align(4) = undefined;
        while (true) {
            const n = try sys.check(linux.recvfrom(s.fd, &buf, buf.len, 0, null, null));
            var it: Messages = .{ .rest = buf[0..n] };
            while (it.next()) |r| {
                if (r.seq != seq) continue;
                switch (r.type) {
                    nlmsg_done => return,
                    nlmsg_error => return if (r.err == 0) {} else sys.errorFromErrno(@enumFromInt(-r.err)),
                    else => on(ctx, r),
                }
            }
        }
    }
};

pub const Interface = struct {
    index: u32,
    adapter: wifi.Adapter,
};

pub const Event = enum { none, scan_done, scan_aborted };

pub const Nl80211 = struct {
    req: Socket,
    events: Socket,
    family: u16,

    /// Opens nl80211; fails with NoNl80211 if the kernel has no Wi-Fi
    /// support.
    pub fn open() Error!Nl80211 {
        var req = try Socket.open();
        errdefer sys.close(req.fd);
        var m: Message = .{};
        m.put(ctrl_attr_family_name, "nl80211\x00");
        var found: Family = .{};
        req.request(&m, genl_id_ctrl, 0, ctrl_cmd_getfamily, &found, Family.on) catch |err| {
            return if (err == error.NoDevice or err == error.NotFound) error.NoNl80211 else err;
        };
        if (found.id == 0) return error.NoNl80211;
        const events = try Socket.open();
        errdefer sys.close(events.fd);
        if (found.scan_group) |g| _ = try sys.check(linux.setsockopt(events.fd, sol_netlink, netlink_add_membership, std.mem.asBytes(&g), 4));
        return .{ .req = req, .events = events, .family = found.id };
    }

    /// The first Wi-Fi interface in station (client) mode.
    pub fn findStation(n: *Nl80211) Error!?Interface {
        var m: Message = .{};
        var out: ?Interface = null;
        try n.req.request(&m, n.family, nlm_f_dump, cmd.get_interface, &out, struct {
            fn on(o: *?Interface, r: Received) void {
                if (o.* != null or r.command != cmd.new_interface) return;
                o.* = parseInterface(r.attrs);
            }
        }.on);
        return out;
    }

    pub fn triggerScan(n: *Nl80211, ifindex: u32) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        try n.req.request(&m, n.family, 0, cmd.trigger_scan, {}, struct {
            fn on(_: void, _: Received) void {}
        }.on);
    }

    /// What the last scans found (the kernel keeps them a while).
    pub fn scanResults(n: *Nl80211, ifindex: u32, report: *wifi.Report) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        report.len = 0;
        try n.req.request(&m, n.family, nlm_f_dump, cmd.get_scan, report, struct {
            fn on(r: *wifi.Report, msg: Received) void {
                if (msg.command != cmd.new_scan_results) return;
                const b = Attrs.find(msg.attrs, attr.bss) orelse return;
                if (parseBss(b.data)) |net| r.add(net);
            }
        }.on);
    }

    /// Reads waiting scan events: whether a scan finished (or was given
    /// up).
    pub fn readEvents(n: *Nl80211) Event {
        var event: Event = .none;
        var buf: [8192]u8 align(4) = undefined;
        while (true) {
            const rc = linux.recvfrom(n.events.fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return event;
            var it: Messages = .{ .rest = buf[0..rc] };
            while (it.next()) |r| {
                if (r.type != n.family) continue;
                if (r.command == cmd.new_scan_results) event = .scan_done;
                if (r.command == cmd.scan_aborted and event == .none) event = .scan_aborted;
            }
        }
    }

    pub fn close(n: *Nl80211) void {
        sys.close(n.req.fd);
        sys.close(n.events.fd);
    }
};

const Family = struct {
    id: u16 = 0,
    scan_group: ?u32 = null,

    fn on(f: *Family, r: Received) void {
        f.* = parseFamily(r.attrs);
    }
};

/// The family ID and "scan" multicast group from a CTRL_CMD_GETFAMILY
/// reply.
fn parseFamily(attrs: []const u8) Family {
    var f: Family = .{};
    if (Attrs.find(attrs, ctrl_attr_family_id)) |a| f.id = a.int(u16) orelse 0;
    const groups = Attrs.find(attrs, ctrl_attr_mcast_groups) orelse return f;
    var it = Attrs.of(groups.data);
    while (it.next()) |g| {
        const name = Attrs.find(g.data, ctrl_attr_mcast_grp_name) orelse continue;
        const id = Attrs.find(g.data, ctrl_attr_mcast_grp_id) orelse continue;
        if (std.mem.eql(u8, name.string(), "scan")) f.scan_group = id.int(u32);
    }
    return f;
}

fn parseInterface(attrs: []const u8) ?Interface {
    const iftype = (Attrs.find(attrs, attr.iftype) orelse return null).int(u32) orelse return null;
    if (iftype != iftype_station) return null;
    var i: Interface = .{ .index = (Attrs.find(attrs, attr.ifindex) orelse return null).int(u32) orelse return null, .adapter = .{} };
    if (Attrs.find(attrs, attr.ifname)) |a| i.adapter.setName(a.string());
    if (Attrs.find(attrs, attr.mac)) |a| if (a.data.len >= 6) {
        @memcpy(&i.adapter.mac, a.data[0..6]);
    };
    return i;
}

/// A network from one access point's scan result (NL80211_ATTR_BSS).
pub fn parseBss(attrs: []const u8) ?wifi.Network {
    var n: wifi.Network = .{};
    n.freq_mhz = (Attrs.find(attrs, bss.frequency) orelse return null).int(u32) orelse return null;
    n.signal_mbm = if (Attrs.find(attrs, bss.signal_mbm)) |a| a.int(i32) orelse -10000 else -10000;
    const capability = if (Attrs.find(attrs, bss.capability)) |a| a.int(u16) orelse 0 else 0;
    const ies = if (Attrs.find(attrs, bss.information_elements)) |a| a.data else &.{};
    n.setSsid(ssidOf(ies) orelse return null);
    n.security = securityOf(capability, ies);
    return n;
}

/// The SSID from information elements (element 0).
pub fn ssidOf(ies: []const u8) ?[]const u8 {
    var it = Elements{ .rest = ies };
    while (it.next()) |e| if (e.id == 0) return e.data;
    return null;
}

/// The security from the capability's privacy bit and the RSN and WPA
/// elements.
pub fn securityOf(capability: u16, ies: []const u8) wifi.Security {
    var it = Elements{ .rest = ies };
    var wpa = false;
    while (it.next()) |e| {
        if (e.id == 48) return rsnSecurity(e.data);
        // Microsoft's WPA element: OUI 00:50:f2, type 1.
        if (e.id == 221 and e.data.len >= 4 and std.mem.eql(u8, e.data[0..4], &.{ 0x00, 0x50, 0xf2, 0x01 })) wpa = true;
    }
    if (wpa) return .wpa;
    const privacy = 0x0010;
    return if (capability & privacy != 0) .wep else .open;
}

/// WPA2, WPA3 or enterprise, from the RSN element's key management suites.
fn rsnSecurity(rsn: []const u8) wifi.Security {
    // Version (2), group cipher (4), pairwise ciphers (count, 4 each), then
    // key management suites (count, 4 each).
    if (rsn.len < 8) return .wpa2;
    const pairwise = std.mem.readInt(u16, rsn[6..8], .little);
    const akm_at = 8 + @as(usize, pairwise) * 4;
    if (rsn.len < akm_at + 2) return .wpa2;
    const count = std.mem.readInt(u16, rsn[akm_at..][0..2], .little);
    var psk = false;
    var sae = false;
    var eap = false;
    for (0..count) |i| {
        const at = akm_at + 2 + i * 4;
        if (rsn.len < at + 4) break;
        if (!std.mem.eql(u8, rsn[at..][0..3], &.{ 0x00, 0x0f, 0xac })) continue;
        switch (rsn[at + 3]) {
            1, 5, 11, 12, 13 => eap = true,
            2, 4, 6 => psk = true,
            8, 9, 24, 25 => sae = true,
            else => {},
        }
    }
    if (eap and !psk and !sae) return .enterprise;
    // A network that also takes WPA2 is listed as WPA2: what most devices
    // will use.
    if (sae and !psk) return .wpa3;
    return .wpa2;
}

const Element = struct { id: u8, data: []const u8 };

const Elements = struct {
    rest: []const u8,

    fn next(it: *Elements) ?Element {
        if (it.rest.len < 2) return null;
        const len = it.rest[1];
        if (it.rest.len < 2 + @as(usize, len)) return null;
        const e: Element = .{ .id = it.rest[0], .data = it.rest[2 .. 2 + len] };
        it.rest = it.rest[2 + len ..];
        return e;
    }
};

const testing = std.testing;

/// Attributes for tests.
fn attrBytes(out: []u8, items: []const struct { u16, []const u8 }) []const u8 {
    var m: Message = .{ .len = 0 };
    for (items) |it| m.put(it[0], it[1]);
    @memcpy(out[0..m.len], m.buf[0..m.len]);
    return out[0..m.len];
}

test "the family reply gives nl80211's ID and its scan group" {
    var g1: [64]u8 = undefined;
    var g2: [64]u8 = undefined;
    var groups: [160]u8 = undefined;
    var all: [256]u8 = undefined;
    const config = attrBytes(&g1, &.{ .{ ctrl_attr_mcast_grp_id, &.{ 3, 0, 0, 0 } }, .{ ctrl_attr_mcast_grp_name, "config\x00" } });
    const scan = attrBytes(&g2, &.{ .{ ctrl_attr_mcast_grp_id, &.{ 4, 0, 0, 0 } }, .{ ctrl_attr_mcast_grp_name, "scan\x00" } });
    const list = attrBytes(&groups, &.{ .{ 1 | 0x8000, config }, .{ 2 | 0x8000, scan } });
    const reply = attrBytes(&all, &.{ .{ ctrl_attr_family_name, "nl80211\x00" }, .{ ctrl_attr_family_id, &.{ 0x1c, 0 } }, .{ ctrl_attr_mcast_groups | 0x8000, list } });
    const f = parseFamily(reply);
    try testing.expectEqual(@as(u16, 0x1c), f.id);
    try testing.expectEqual(@as(?u32, 4), f.scan_group);
}

test "interfaces: only stations, with their name and address" {
    var buf: [128]u8 = undefined;
    const station = attrBytes(&buf, &.{ .{ attr.ifindex, &.{ 3, 0, 0, 0 } }, .{ attr.ifname, "wlan0\x00" }, .{ attr.iftype, &.{ 2, 0, 0, 0 } }, .{ attr.mac, &.{ 0xb8, 0x27, 0xeb, 1, 2, 3 } } });
    const i = parseInterface(station).?;
    try testing.expectEqual(@as(u32, 3), i.index);
    try testing.expectEqualStrings("wlan0", i.adapter.name());
    try testing.expectEqual([6]u8{ 0xb8, 0x27, 0xeb, 1, 2, 3 }, i.adapter.mac);
    var buf2: [128]u8 = undefined;
    const monitor = attrBytes(&buf2, &.{ .{ attr.ifindex, &.{ 4, 0, 0, 0 } }, .{ attr.iftype, &.{ 6, 0, 0, 0 } } });
    try testing.expect(parseInterface(monitor) == null);
}

test "scan results: SSID, signal, frequency and security" {
    // SSID "Home", then RSN with one pairwise cipher (CCMP) and PSK.
    const rsn_psk = [_]u8{ 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 2 };
    var ies: [64]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ &.{ 0, 4 }, "Home", &.{ 48, rsn_psk.len }, &rsn_psk }) |part| {
        @memcpy(ies[n..][0..part.len], part);
        n += part.len;
    }
    var buf: [160]u8 = undefined;
    const mbm: i32 = -5400;
    const result = attrBytes(&buf, &.{
        .{ bss.frequency, &.{ 0x85, 0x09, 0, 0 } }, // 2437
        .{ bss.signal_mbm, std.mem.asBytes(&mbm) },
        .{ bss.capability, &.{ 0x11, 0x04 } },
        .{ bss.information_elements, ies[0..n] },
    });
    const net = parseBss(result).?;
    try testing.expectEqualStrings("Home", net.ssid());
    try testing.expectEqual(@as(u32, 2437), net.freq_mhz);
    try testing.expectEqual(@as(i32, -5400), net.signal_mbm);
    try testing.expectEqual(wifi.Security.wpa2, net.security);

    // SAE only is WPA3; 802.1X only is enterprise; the WPA element is WPA;
    // privacy without either is WEP; nothing is open.
    const rsn_sae = [_]u8{ 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 8 };
    try testing.expectEqual(wifi.Security.wpa3, securityOf(0x11, &([_]u8{ 48, rsn_sae.len } ++ rsn_sae)));
    const rsn_mixed = [_]u8{ 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 2, 0, 0x00, 0x0f, 0xac, 2, 0x00, 0x0f, 0xac, 8 };
    try testing.expectEqual(wifi.Security.wpa2, securityOf(0x11, &([_]u8{ 48, rsn_mixed.len } ++ rsn_mixed)));
    const rsn_eap = [_]u8{ 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 1 };
    try testing.expectEqual(wifi.Security.enterprise, securityOf(0x11, &([_]u8{ 48, rsn_eap.len } ++ rsn_eap)));
    try testing.expectEqual(wifi.Security.wpa, securityOf(0x11, &[_]u8{ 221, 6, 0x00, 0x50, 0xf2, 0x01, 1, 0 }));
    try testing.expectEqual(wifi.Security.wep, securityOf(0x11, &.{}));
    try testing.expectEqual(wifi.Security.open, securityOf(0x01, &.{}));
    // No SSID element: not a network to list.
    var buf3: [64]u8 = undefined;
    try testing.expect(parseBss(attrBytes(&buf3, &.{.{ bss.frequency, &.{ 0x85, 0x09, 0, 0 } }})) == null);
}

test "netlink messages split, with errors and dump ends" {
    var buf: [64]u8 align(4) = undefined;
    // An error (-16, EBUSY) for sequence 7, then a dump end.
    std.mem.writeInt(u32, buf[0..4], 36, .little);
    std.mem.writeInt(u16, buf[4..6], nlmsg_error, .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    std.mem.writeInt(u32, buf[8..12], 7, .little);
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    std.mem.writeInt(i32, buf[16..20], -16, .little);
    @memset(buf[20..36], 0);
    std.mem.writeInt(u32, buf[36..40], 20, .little);
    std.mem.writeInt(u16, buf[40..42], nlmsg_done, .little);
    std.mem.writeInt(u16, buf[42..44], nlm_f_multi, .little);
    std.mem.writeInt(u32, buf[44..48], 7, .little);
    @memset(buf[48..56], 0);
    var it: Messages = .{ .rest = buf[0..56] };
    const e = it.next().?;
    try testing.expectEqual(@as(u16, nlmsg_error), e.type);
    try testing.expectEqual(@as(i32, -16), e.err);
    try testing.expectEqual(@as(u16, nlmsg_done), it.next().?.type);
    try testing.expect(it.next() == null);
}

test "this machine's kernel: nl80211 resolves, or there is no Wi-Fi" {
    var n = Nl80211.open() catch |err| {
        try testing.expectEqual(error.NoNl80211, err);
        return;
    };
    defer n.close();
    try testing.expect(n.family >= genl_id_ctrl);
    _ = try n.findStation();
    try testing.expectEqual(Event.none, n.readEvents());
}
