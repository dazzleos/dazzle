//! nl80211, Linux's Wi-Fi configuration interface, over generic netlink:
//! finding the Wi-Fi adapter, scanning, connecting (the driver does the
//! association itself: the chip's firmware is "full MAC"), installing the
//! supplicant's keys, and hearing about all of it. Just what the Wi-Fi
//! manager needs.
//!
//! Generic netlink messages are a netlink header, a generic netlink header
//! (the command) and attributes: type-length-value records, 4-byte aligned,
//! some holding further attributes (nested).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const wifi = sys.network;

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
const nla_f_nested = 0x8000;

// nl80211.h
pub const cmd = struct {
    pub const get_interface = 5;
    pub const set_interface = 6;
    pub const new_interface = 7;
    pub const set_key = 10;
    pub const new_key = 11;
    pub const start_ap = 15;
    pub const stop_ap = 17;
    pub const set_station = 18;
    pub const new_station = 19;
    pub const del_station = 20;
    pub const get_scan = 32;
    pub const trigger_scan = 33;
    pub const new_scan_results = 34;
    pub const scan_aborted = 35;
    pub const connect = 46;
    pub const disconnect = 48;
};
const attr = struct {
    const ifindex = 3;
    const ifname = 4;
    const iftype = 5;
    const mac = 6;
    const key_data = 7;
    const key_idx = 8;
    const key_cipher = 9;
    const key_seq = 10;
    const key_default = 11;
    const beacon_interval = 12;
    const dtim_period = 13;
    const beacon_head = 14;
    const beacon_tail = 15;
    const wiphy_freq = 38;
    const ie = 42;
    const bss = 47;
    const ssid = 52;
    const auth_type = 53;
    const reason_code = 54;
    const key_type = 55;
    const sta_flags2 = 67;
    const control_port = 68;
    const privacy = 70;
    const status_code = 72;
    const cipher_suites_pairwise = 73;
    const cipher_suite_group = 74;
    const wpa_versions = 75;
    const akm_suites = 76;
    const key_default_types = 110;
    const hidden_ssid = 126;
    const ie_probe_resp = 127;
    const ie_assoc_resp = 128;
    const channel_width = 159;
    const center_freq1 = 160;
};
const key_default_type_multicast = 2;
const keytype_group = 0;
const keytype_pairwise = 1;
const wpa_version_2 = 2;
const sta_flag_authorized = 1;
const chan_width_20 = 1;
const bss = struct {
    const bssid = 1;
    const frequency = 2;
    const capability = 5;
    const information_elements = 6;
    const signal_mbm = 7;
};
pub const iftype_station: u32 = 2;
pub const iftype_ap: u32 = 3;

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
    buf: [512]u8 = undefined,
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

/// What the events since the last look said.
pub const Events = struct {
    scan_done: bool = false,
    scan_aborted: bool = false,
    /// A connection attempt finished: 0 is success, else an 802.11
    /// status code; and the access point.
    connected: ?struct { status: u16, bssid: [6]u8 } = null,
    /// The connection was lost: the 802.11 reason code.
    disconnected: ?u16 = null,
    /// In AP mode: a station associated or disassociated.
    new_station: ?[6]u8 = null,
    del_station: ?[6]u8 = null,
};

/// An access point found by a scan, with what connecting to it needs.
pub const Bss = struct {
    network: wifi.Network,
    bssid: [6]u8,
    /// Its RSN element as advertised (empty for open and WPA1 networks).
    rsn_buf: [64]u8 = undefined,
    rsn_len: u8 = 0,
    group_cipher: u32 = 0,
    /// It offers CCMP for pairwise keys, and PSK key management.
    ccmp: bool = false,
    psk: bool = false,

    pub fn rsn(b: *const Bss) []const u8 {
        return b.rsn_buf[0..b.rsn_len];
    }
};

/// What connecting needs to say.
pub const ConnectParams = struct {
    ssid: []const u8,
    bssid: [6]u8,
    freq_mhz: u32,
    /// For WPA2: our RSN element and the group cipher; null for an open
    /// network.
    wpa2: ?struct { rsn: []const u8, group_cipher: u32 } = null,
};

/// What starting an access point (hotspot) needs to say.
pub const ApParams = struct {
    ssid: []const u8,
    bssid: [6]u8,
    wpa2: bool = false,
    channel: u8 = 1,
};

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
        for ([_]?u32{ found.scan_group, found.mlme_group }) |group| if (group) |g| {
            _ = try sys.check(linux.setsockopt(events.fd, sol_netlink, netlink_add_membership, std.mem.asBytes(&g), 4));
        };
        return .{ .req = req, .events = events, .family = found.id };
    }

    /// All Wi-Fi interfaces in station (client) mode, sorted by name.
    pub fn findStations(n: *Nl80211, out: *[wifi.max_adapters]Interface) Error!usize {
        var m: Message = .{};
        const List = struct { items: *[wifi.max_adapters]Interface, len: usize = 0 };
        var list: List = .{ .items = out };
        try n.req.request(&m, n.family, nlm_f_dump, cmd.get_interface, &list, struct {
            fn on(l: *List, r: Received) void {
                if (l.len == l.items.len or r.command != cmd.new_interface) return;
                if (parseInterface(r.attrs)) |ifc| {
                    l.items[l.len] = ifc;
                    l.len += 1;
                }
            }
        }.on);
        std.mem.sort(Interface, out[0..list.len], {}, struct {
            fn lessThan(_: void, a: Interface, b: Interface) bool {
                return std.mem.lessThan(u8, a.adapter.name(), b.adapter.name());
            }
        }.lessThan);
        return list.len;
    }

    /// The first Wi-Fi interface in station (client) mode.
    pub fn findStation(n: *Nl80211) Error!?Interface {
        var list: [wifi.max_adapters]Interface = undefined;
        return if ((try n.findStations(&list)) > 0) list[0] else null;
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

    /// The strongest access point of the network with this SSID in the
    /// last scan.
    pub fn findBss(n: *Nl80211, ifindex: u32, ssid: []const u8) Error!?Bss {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        const Found = struct { ssid: []const u8, best: ?Bss = null };
        var found: Found = .{ .ssid = ssid };
        try n.req.request(&m, n.family, nlm_f_dump, cmd.get_scan, &found, struct {
            fn on(f: *Found, msg: Received) void {
                if (msg.command != cmd.new_scan_results) return;
                const b = Attrs.find(msg.attrs, attr.bss) orelse return;
                const info = parseBssDetail(b.data) orelse return;
                if (!std.mem.eql(u8, info.network.ssid(), f.ssid)) return;
                if (f.best == null or info.network.signal_mbm > f.best.?.network.signal_mbm) f.best = info;
            }
        }.on);
        return found.best;
    }

    /// Starts connecting; an event says how it went.
    pub fn connect(n: *Nl80211, ifindex: u32, p: ConnectParams) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        m.put(attr.ssid, p.ssid);
        m.put(attr.mac, &p.bssid);
        m.put(attr.wiphy_freq, std.mem.asBytes(&p.freq_mhz));
        const open_system: u32 = 0;
        m.put(attr.auth_type, std.mem.asBytes(&open_system));
        if (p.wpa2) |w| {
            const version: u32 = wpa_version_2;
            const pairwise: u32 = @import("supplicant.zig").cipher_ccmp;
            const akm: u32 = @import("supplicant.zig").akm_psk;
            m.put(attr.privacy, &.{});
            m.put(attr.wpa_versions, std.mem.asBytes(&version));
            m.put(attr.cipher_suites_pairwise, std.mem.asBytes(&pairwise));
            m.put(attr.cipher_suite_group, std.mem.asBytes(&w.group_cipher));
            m.put(attr.akm_suites, std.mem.asBytes(&akm));
            m.put(attr.ie, w.rsn);
            // The supplicant does the handshake (over EAPOL frames): until
            // then only those frames may pass.
            m.put(attr.control_port, &.{});
        }
        try n.req.request(&m, n.family, 0, cmd.connect, {}, ignore);
    }

    pub fn disconnect(n: *Nl80211, ifindex: u32) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        const unspecified: u16 = 3; // deauthenticated: leaving
        m.put(attr.reason_code, std.mem.asBytes(&unspecified));
        try n.req.request(&m, n.family, 0, cmd.disconnect, {}, ignore);
    }

    /// Installs the pairwise key (CCMP) for the access point.
    pub fn setPairwiseKey(n: *Nl80211, ifindex: u32, bssid: [6]u8, tk: [16]u8) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        m.put(attr.mac, &bssid);
        const idx: u8 = 0;
        const cipher: u32 = @import("supplicant.zig").cipher_ccmp;
        const typ: u32 = keytype_pairwise;
        m.put(attr.key_idx, std.mem.asBytes(&idx));
        m.put(attr.key_cipher, std.mem.asBytes(&cipher));
        m.put(attr.key_data, &tk);
        m.put(attr.key_type, std.mem.asBytes(&typ));
        try n.req.request(&m, n.family, 0, cmd.new_key, {}, ignore);
    }

    /// Installs a group key, and makes it the one broadcasts use.
    pub fn setGroupKey(n: *Nl80211, ifindex: u32, cipher: u32, index: u8, key: []const u8, rsc: [6]u8) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        const typ: u32 = keytype_group;
        m.put(attr.key_idx, std.mem.asBytes(&index));
        m.put(attr.key_cipher, std.mem.asBytes(&cipher));
        m.put(attr.key_data, key);
        m.put(attr.key_seq, &rsc);
        m.put(attr.key_type, std.mem.asBytes(&typ));
        try n.req.request(&m, n.family, 0, cmd.new_key, {}, ignore);
        var d: Message = .{};
        d.put(attr.ifindex, std.mem.asBytes(&ifindex));
        d.put(attr.key_idx, std.mem.asBytes(&index));
        d.put(attr.key_default, &.{});
        var types: [4]u8 = undefined;
        std.mem.writeInt(u16, types[0..2], 4, .little);
        std.mem.writeInt(u16, types[2..4], key_default_type_multicast, .little);
        d.put(attr.key_default_types | nla_f_nested, &types);
        // Drivers that pick the group key themselves refuse this.
        n.req.request(&d, n.family, 0, cmd.set_key, {}, ignore) catch {};
    }

    /// Marks the access point (or associated station) authorized (the port
    /// open for traffic), for drivers that want to be told.
    pub fn authorize(n: *Nl80211, ifindex: u32, bssid: [6]u8) void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        m.put(attr.mac, &bssid);
        var flags: [8]u8 = undefined;
        std.mem.writeInt(u32, flags[0..4], 1 << sta_flag_authorized, .little);
        std.mem.writeInt(u32, flags[4..8], 1 << sta_flag_authorized, .little);
        m.put(attr.sta_flags2, &flags);
        n.req.request(&m, n.family, 0, cmd.set_station, {}, ignore) catch {};
    }

    /// Switches an interface between station (`iftype_station`) and AP
    /// (`iftype_ap`) mode.
    pub fn setInterfaceType(n: *Nl80211, ifindex: u32, iftype: u32) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        m.put(attr.iftype, std.mem.asBytes(&iftype));
        try n.req.request(&m, n.family, 0, cmd.set_interface, {}, ignore);
    }

    /// Starts an access point (hotspot) on an interface in AP mode.
    pub fn startAp(n: *Nl80211, ifindex: u32, p: ApParams) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        const interval: u32 = 100;
        const dtim: u32 = 2;
        const hidden: u32 = 0;
        const freq_mhz: u32 = 2407 + @as(u32, p.channel) * 5;
        const width: u32 = chan_width_20;
        m.put(attr.beacon_interval, std.mem.asBytes(&interval));
        m.put(attr.dtim_period, std.mem.asBytes(&dtim));
        m.put(attr.ssid, p.ssid);
        m.put(attr.hidden_ssid, std.mem.asBytes(&hidden));
        m.put(attr.wiphy_freq, std.mem.asBytes(&freq_mhz));
        m.put(attr.channel_width, std.mem.asBytes(&width));
        m.put(attr.center_freq1, std.mem.asBytes(&freq_mhz));
        var head_buf: [96]u8 = undefined;
        var tail_buf: [32]u8 = undefined;
        const head = beaconHead(&head_buf, p);
        const tail = beaconTail(&tail_buf, p.wpa2);
        m.put(attr.beacon_head, head);
        m.put(attr.beacon_tail, tail);
        if (p.wpa2) {
            const supplicant = @import("supplicant.zig");
            var rsn_buf: [22]u8 = undefined;
            const rsn = supplicant.rsnElement(&rsn_buf, supplicant.cipher_ccmp);
            const version: u32 = wpa_version_2;
            const cipher: u32 = supplicant.cipher_ccmp;
            const akm: u32 = supplicant.akm_psk;
            m.put(attr.privacy, &.{});
            m.put(attr.wpa_versions, std.mem.asBytes(&version));
            m.put(attr.cipher_suites_pairwise, std.mem.asBytes(&cipher));
            m.put(attr.cipher_suite_group, std.mem.asBytes(&cipher));
            m.put(attr.akm_suites, std.mem.asBytes(&akm));
            m.put(attr.ie, rsn);
            m.put(attr.ie_probe_resp, rsn);
            m.put(attr.ie_assoc_resp, rsn);
            m.put(attr.control_port, &.{});
        }
        try n.req.request(&m, n.family, 0, cmd.start_ap, {}, ignore);
    }

    pub fn stopAp(n: *Nl80211, ifindex: u32) Error!void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        try n.req.request(&m, n.family, 0, cmd.stop_ap, {}, ignore);
    }

    pub fn delStation(n: *Nl80211, ifindex: u32, mac: [6]u8) void {
        var m: Message = .{};
        m.put(attr.ifindex, std.mem.asBytes(&ifindex));
        m.put(attr.mac, &mac);
        n.req.request(&m, n.family, 0, cmd.del_station, {}, ignore) catch {};
    }

    /// Reads waiting events: scans finishing, connections made and lost.
    pub fn readEvents(n: *Nl80211) Events {
        var events: Events = .{};
        var buf: [8192]u8 align(4) = undefined;
        while (true) {
            const rc = linux.recvfrom(n.events.fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return events;
            var it: Messages = .{ .rest = buf[0..rc] };
            while (it.next()) |r| if (r.type == n.family) parseEvent(r, &events);
        }
    }

    pub fn close(n: *Nl80211) void {
        sys.close(n.req.fd);
        sys.close(n.events.fd);
    }
};

fn ignore(_: void, _: Received) void {}

fn parseEvent(r: Received, events: *Events) void {
    switch (r.command) {
        cmd.new_scan_results => events.scan_done = true,
        cmd.scan_aborted => events.scan_aborted = true,
        cmd.connect => {
            var bssid: [6]u8 = @splat(0);
            if (Attrs.find(r.attrs, attr.mac)) |a| if (a.data.len >= 6) {
                bssid = a.data[0..6].*;
            };
            // No status code: it timed out.
            const status = if (Attrs.find(r.attrs, attr.status_code)) |a| a.int(u16) orelse 1 else 1;
            events.connected = .{ .status = status, .bssid = bssid };
        },
        cmd.disconnect => events.disconnected = if (Attrs.find(r.attrs, attr.reason_code)) |a| a.int(u16) orelse 0 else 0,
        cmd.new_station => if (Attrs.find(r.attrs, attr.mac)) |a| if (a.data.len >= 6) {
            events.new_station = a.data[0..6].*;
        },
        cmd.del_station => if (Attrs.find(r.attrs, attr.mac)) |a| if (a.data.len >= 6) {
            events.del_station = a.data[0..6].*;
        },
        else => {},
    }
}

/// 802.11 Beacon head: 24-byte management header, 12-byte fixed parameters,
/// SSID IE, Supported Rates IE, and DS Parameter Set IE.
pub fn beaconHead(out: *[96]u8, p: ApParams) []const u8 {
    @memset(out, 0);
    out[0] = 0x80; // Beacon frame control
    @memset(out[4..10], 0xff); // DA: broadcast
    @memcpy(out[10..16], &p.bssid); // SA
    @memcpy(out[16..22], &p.bssid); // BSSID
    // Fixed parameters at 24..36: 8-byte timestamp (0), beacon interval 100, capability.
    std.mem.writeInt(u16, out[32..34], 100, .little);
    const cap: u16 = if (p.wpa2) 0x0411 else 0x0401; // ESS + Short Slot Time (+ Privacy)
    std.mem.writeInt(u16, out[34..36], cap, .little);
    var pos: usize = 36;
    const ssid = p.ssid[0..@min(p.ssid.len, wifi.max_ssid)];
    out[pos] = 0; // SSID IE
    out[pos + 1] = @intCast(ssid.len);
    @memcpy(out[pos + 2 ..][0..ssid.len], ssid);
    pos += 2 + ssid.len;
    // Supported Rates IE (1, 2, 5.5, 11, 6, 9, 12, 18 Mbps)
    const rates = [_]u8{ 1, 8, 0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24 };
    @memcpy(out[pos..][0..rates.len], &rates);
    pos += rates.len;
    // DS Parameter Set IE (channel)
    const ds = [_]u8{ 3, 1, p.channel };
    @memcpy(out[pos..][0..ds.len], &ds);
    pos += ds.len;
    return out[0..pos];
}

/// 802.11 Beacon tail: Extended Supported Rates IE and optional RSN IE.
pub fn beaconTail(out: *[32]u8, wpa2: bool) []const u8 {
    // Extended Supported Rates IE (24, 36, 48, 54 Mbps)
    const ext_rates = [_]u8{ 50, 4, 0x30, 0x48, 0x60, 0x6c };
    @memcpy(out[0..ext_rates.len], &ext_rates);
    var pos: usize = ext_rates.len;
    if (wpa2) {
        const supplicant = @import("supplicant.zig");
        var rsn_buf: [22]u8 = undefined;
        const rsn = supplicant.rsnElement(&rsn_buf, supplicant.cipher_ccmp);
        @memcpy(out[pos..][0..rsn.len], rsn);
        pos += rsn.len;
    }
    return out[0..pos];
}

const Family = struct {
    id: u16 = 0,
    scan_group: ?u32 = null,
    mlme_group: ?u32 = null,

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
        if (std.mem.eql(u8, name.string(), "mlme")) f.mlme_group = id.int(u32);
    }
    return f;
}

fn parseInterface(attrs: []const u8) ?Interface {
    const iftype = (Attrs.find(attrs, attr.iftype) orelse return null).int(u32) orelse return null;
    if (iftype != iftype_station and iftype != iftype_ap) return null;
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

/// An access point's scan result with its address and RSN details.
pub fn parseBssDetail(attrs: []const u8) ?Bss {
    var b: Bss = .{ .network = parseBss(attrs) orelse return null, .bssid = undefined };
    const addr = Attrs.find(attrs, bss.bssid) orelse return null;
    if (addr.data.len < 6) return null;
    b.bssid = addr.data[0..6].*;
    const ies = if (Attrs.find(attrs, bss.information_elements)) |a| a.data else &.{};
    var it = Elements{ .rest = ies };
    while (it.next()) |e| if (e.id == 48 and e.data.len + 2 <= b.rsn_buf.len) {
        b.rsn_len = @intCast(e.data.len + 2);
        b.rsn_buf[0] = 48;
        b.rsn_buf[1] = @intCast(e.data.len);
        @memcpy(b.rsn_buf[2..b.rsn_len], e.data);
        const r = rsnDetail(e.data);
        b.group_cipher = r.group;
        b.ccmp = r.ccmp;
        b.psk = r.psk;
        break;
    };
    return b;
}

/// The group cipher, and whether CCMP and PSK are on offer, from an RSN
/// element's body.
fn rsnDetail(rsn: []const u8) struct { group: u32, ccmp: bool, psk: bool } {
    var out: @TypeOf(rsnDetail(rsn)) = .{ .group = 0, .ccmp = false, .psk = false };
    if (rsn.len < 6) return out;
    out.group = std.mem.readInt(u32, rsn[2..6], .big);
    if (rsn.len < 8) return out;
    const pairwise = std.mem.readInt(u16, rsn[6..8], .little);
    for (0..pairwise) |i| {
        const at = 8 + i * 4;
        if (rsn.len < at + 4) return out;
        if (std.mem.readInt(u32, rsn[at..][0..4], .big) == 0x000fac04) out.ccmp = true;
    }
    const akm_at = 8 + @as(usize, pairwise) * 4;
    if (rsn.len < akm_at + 2) return out;
    const count = std.mem.readInt(u16, rsn[akm_at..][0..2], .little);
    for (0..count) |i| {
        const at = akm_at + 2 + i * 4;
        if (rsn.len < at + 4) break;
        const suite = std.mem.readInt(u32, rsn[at..][0..4], .big);
        // PSK with SHA-1 (not SHA-256, suite 6: a different MIC).
        if (suite == 0x000fac02) out.psk = true;
    }
    return out;
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
    const e = n.readEvents();
    try testing.expect(!e.scan_done and e.connected == null and e.disconnected == null);
}

test "an access point's address and RSN details, for connecting" {
    // RSN: version 1, group TKIP, pairwise CCMP and TKIP, AKM PSK, caps.
    const rsn = [_]u8{ 1, 0, 0x00, 0x0f, 0xac, 2, 2, 0, 0x00, 0x0f, 0xac, 4, 0x00, 0x0f, 0xac, 2, 1, 0, 0x00, 0x0f, 0xac, 2, 0, 0 };
    const ies = [_]u8{ 0, 4, 'H', 'o', 'm', 'e', 48, rsn.len } ++ rsn;
    var buf: [192]u8 = undefined;
    const mbm: i32 = -6000;
    const result = attrBytes(&buf, &.{
        .{ bss.bssid, &.{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 } },
        .{ bss.frequency, &.{ 0x6c, 0x09, 0, 0 } }, // 2412
        .{ bss.signal_mbm, std.mem.asBytes(&mbm) },
        .{ bss.capability, &.{ 0x11, 0x04 } },
        .{ bss.information_elements, &ies },
    });
    const b = parseBssDetail(result).?;
    try testing.expectEqual([6]u8{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 }, b.bssid);
    try testing.expectEqual(@as(u32, 0x000fac02), b.group_cipher);
    try testing.expect(b.ccmp and b.psk);
    try testing.expectEqualSlices(u8, &([_]u8{ 48, rsn.len } ++ rsn), b.rsn());

    // PSK-SHA256 only is not something the supplicant can do.
    const sha256 = [_]u8{ 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 6 };
    try testing.expect(!rsnDetail(&sha256).psk);
}

test "connection events" {
    var buf: [64]u8 = undefined;
    var ev: Events = .{};
    parseEvent(.{ .type = 0x1c, .flags = 0, .seq = 0, .command = cmd.connect, .attrs = attrBytes(&buf, &.{ .{ attr.mac, &.{ 2, 1, 2, 3, 4, 5 } }, .{ attr.status_code, &.{ 0, 0 } } }) }, &ev);
    try testing.expectEqual(@as(u16, 0), ev.connected.?.status);
    try testing.expectEqual([6]u8{ 2, 1, 2, 3, 4, 5 }, ev.connected.?.bssid);
    // Timed out: no status code.
    ev = .{};
    parseEvent(.{ .type = 0x1c, .flags = 0, .seq = 0, .command = cmd.connect, .attrs = &.{} }, &ev);
    try testing.expect(ev.connected.?.status != 0);
    parseEvent(.{ .type = 0x1c, .flags = 0, .seq = 0, .command = cmd.disconnect, .attrs = attrBytes(&buf, &.{.{ attr.reason_code, &.{ 15, 0 } }}) }, &ev);
    try testing.expectEqual(@as(?u16, 15), ev.disconnected);
    parseEvent(.{ .type = 0x1c, .flags = 0, .seq = 0, .command = cmd.new_station, .attrs = attrBytes(&buf, &.{.{ attr.mac, &.{ 0xaa, 0xbb, 0xcc, 1, 2, 3 } }}) }, &ev);
    try testing.expectEqual([6]u8{ 0xaa, 0xbb, 0xcc, 1, 2, 3 }, ev.new_station.?);
    parseEvent(.{ .type = 0x1c, .flags = 0, .seq = 0, .command = cmd.del_station, .attrs = attrBytes(&buf, &.{.{ attr.mac, &.{ 0xaa, 0xbb, 0xcc, 1, 2, 3 } }}) }, &ev);
    try testing.expectEqual([6]u8{ 0xaa, 0xbb, 0xcc, 1, 2, 3 }, ev.del_station.?);
}

test "beacon head and tail contain SSID and RSN security" {
    var head_buf: [96]u8 = undefined;
    var tail_buf: [32]u8 = undefined;
    const head = beaconHead(&head_buf, .{ .ssid = "DazzleAP", .bssid = .{ 2, 0, 0, 1, 2, 3 }, .wpa2 = true, .channel = 6 });
    const tail = beaconTail(&tail_buf, true);
    try testing.expectEqualStrings("DazzleAP", ssidOf(head[36..]).?);
    const cap = std.mem.readInt(u16, head[34..36], .little);
    try testing.expectEqual(wifi.Security.wpa2, securityOf(cap, tail));
}

