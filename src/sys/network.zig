//! The network manager's protocol. Init runs the manager
//! (src/init/network.zig), the one process that configures the network
//! (Ethernet and Wi-Fi: that needs CAP_NET_ADMIN); it listens on a socket,
//! /os/sockets/network, and answers only the settings app, checked by the program the
//! connecting process runs.
//!
//! A client connects, sends a request and reads the report until the
//! manager closes the connection. The requests are:
//!
//!     status
//!     ethernet dhcp
//!     ethernet static <address>/<prefix> <gateway, or ->
//!     wifi scan
//!     wifi connect <SSID in hex> <passphrase in hex, or - for an open network>
//!     wifi disconnect
//!
//! and the report:
//!
//!     ethernet eth0 static 192.168.1.50/24 192.168.1.1
//!     wifi adapter wlan0 b8:27:eb:01:02:03 up
//!     wifi scanning
//!     wifi connection connected none 486f6d65 192.168.1.50
//!     wifi network -5400 2437 wpa2 486f6d65
//!     end
//!
//! Each line after "status" and before "end" starts with what it is about:
//! "ethernet" or "wifi". "status" only reports; "wifi scan" also scans for
//! Wi-Fi networks if the last scan is old. "ethernet" is how the wired adapter (or "-" while there is
//! none) gets its address: "dhcp", or "static" with the address, prefix
//! length and gateway (or "-"); the choice is kept until the system stops.
//! "wifi adapter" names the Wi-Fi adapter (or "wifi none" says there is
//! none); "wifi scanning" says a scan is under way; each "network" is one network: its
//! signal in mBm (hundredths of dBm), the frequency in MHz of its strongest
//! access point, its security and its SSID in hexadecimal (SSIDs are bytes,
//! not necessarily text). "wifi connection" is the state of joining a network:
//! the state, why it failed (or "none"), the network's SSID in hexadecimal
//! and the address DHCP gave (or "-"). A client the manager does not serve
//! gets "denied\n".

const std = @import("std");

/// The manager's socket.
pub const socket_path = "/os/sockets/network";

/// The only program the manager answers.
pub const allowed_program = "/os/shell/dazzle-settings";

pub const max_networks = 24;
pub const max_adapters = 4;

pub const Security = enum {
    open,
    wep,
    wpa,
    wpa2,
    wpa3,
    enterprise,

    pub fn label(s: Security) []const u8 {
        return switch (s) {
            .open => "Open",
            .wep => "WEP",
            .wpa => "WPA",
            .wpa2 => "WPA2",
            .wpa3 => "WPA3",
            .enterprise => "Enterprise",
        };
    }
};

pub const Network = struct {
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,
    /// Hundredths of dBm.
    signal_mbm: i32 = 0,
    freq_mhz: u32 = 0,
    security: Security = .open,

    pub fn ssid(n: *const Network) []const u8 {
        return n.ssid_buf[0..n.ssid_len];
    }

    pub fn setSsid(n: *Network, s: []const u8) void {
        n.ssid_len = @intCast(@min(s.len, n.ssid_buf.len));
        @memcpy(n.ssid_buf[0..n.ssid_len], s[0..n.ssid_len]);
    }

    pub fn dbm(n: *const Network) i32 {
        return @divTrunc(n.signal_mbm, 100);
    }

    /// "2.4 GHz", "5 GHz" or "6 GHz".
    pub fn band(n: *const Network) []const u8 {
        return if (n.freq_mhz >= 5925) "6 GHz" else if (n.freq_mhz >= 4900) "5 GHz" else "2.4 GHz";
    }

    /// Signal strength as 0 to 4 bars: -50 dBm or better is full.
    pub fn bars(n: *const Network) u8 {
        const d = n.dbm();
        return if (d >= -55) 4 else if (d >= -67) 3 else if (d >= -75) 2 else if (d >= -85) 1 else 0;
    }
};

pub const ConnectionState = enum {
    idle,
    /// Associating with the access point.
    connecting,
    /// The 4-way handshake.
    authenticating,
    /// Asking DHCP for an address.
    addressing,
    connected,
    failed,

    /// Past the handshake.
    pub fn joined(s: ConnectionState) bool {
        return s == .addressing or s == .connected;
    }

    pub fn label(s: ConnectionState) []const u8 {
        return switch (s) {
            .idle => "Not connected",
            .connecting => "Connecting",
            .authenticating => "Checking the password",
            .addressing => "Getting an address",
            .connected => "Connected",
            .failed => "Could not connect",
        };
    }
};

pub const Failure = enum {
    none,
    not_found,
    unsupported,
    bad_passphrase,
    wrong_password,
    rejected,
    timeout,
    lost,

    pub fn label(f: Failure) []const u8 {
        return switch (f) {
            .none => "",
            .not_found => "the network is out of range",
            .unsupported => "its security is not supported yet (only open and WPA2 networks are)",
            .bad_passphrase => "a WPA2 password has 8 to 63 characters",
            .wrong_password => "wrong password",
            .rejected => "the network refused",
            .timeout => "no answer",
            .lost => "the connection was lost; trying again",
        };
    }
};

pub const Connection = struct {
    state: ConnectionState = .idle,
    failure: Failure = .none,
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,
    address: ?[4]u8 = null,
    adapter_buf: [16]u8 = undefined,
    adapter_len: u8 = 0,

    pub fn ssid(c: *const Connection) []const u8 {
        return c.ssid_buf[0..c.ssid_len];
    }

    pub fn setSsid(c: *Connection, s: []const u8) void {
        c.ssid_len = @intCast(@min(s.len, c.ssid_buf.len));
        @memcpy(c.ssid_buf[0..c.ssid_len], s[0..c.ssid_len]);
    }

    pub fn adapter(c: *const Connection) []const u8 {
        return c.adapter_buf[0..c.adapter_len];
    }

    pub fn setAdapter(c: *Connection, name: []const u8) void {
        c.adapter_len = @intCast(@min(name.len, c.adapter_buf.len));
        @memcpy(c.adapter_buf[0..c.adapter_len], name[0..c.adapter_len]);
    }
};

/// A request to scan for Wi-Fi networks (on `adapter` if given).
pub fn scanRequest(buf: []u8, adapter: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (adapter.len > 0) w.print("wifi scan {s}\n", .{adapter}) catch {} else w.writeAll("wifi scan\n") catch {};
    return w.buffered();
}

/// A request to leave the Wi-Fi network (on `adapter` if given).
pub fn disconnectRequest(buf: []u8, adapter: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (adapter.len > 0) w.print("wifi disconnect {s}\n", .{adapter}) catch {} else w.writeAll("wifi disconnect\n") catch {};
    return w.buffered();
}

/// A request to join a network.
pub fn connectRequest(buf: []u8, ssid: []const u8, passphrase: []const u8) []const u8 {
    return connectAdapterRequest(buf, "", ssid, passphrase);
}

/// A request to join a network on `adapter` (or the default adapter when empty).
pub fn connectAdapterRequest(buf: []u8, adapter: []const u8, ssid: []const u8, passphrase: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (adapter.len > 0) w.print("wifi connect {s} {x} ", .{ adapter, ssid }) catch {} else w.print("wifi connect {x} ", .{ssid}) catch {};
    if (passphrase.len == 0) w.writeAll("-") catch {} else w.print("{x}", .{passphrase}) catch {};
    w.writeAll("\n") catch {};
    return w.buffered();
}

pub const Ip4 = [4]u8;

/// A fixed address for the wired adapter.
pub const Static = struct {
    address: Ip4,
    prefix: u6,
    gateway: ?Ip4 = null,

    /// Reads "192.168.1.50/24" and a gateway ("192.168.1.1", or "" or "-"
    /// for none). Null if either is not a valid address.
    pub fn parse(cidr: []const u8, gateway: []const u8) ?Static {
        const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return null;
        const address = parseIp4(cidr[0..slash]) orelse return null;
        const prefix = std.fmt.parseInt(u6, cidr[slash + 1 ..], 10) catch return null;
        if (prefix == 0 or prefix > 32) return null;
        const gw = std.mem.trim(u8, gateway, " ");
        if (gw.len == 0 or std.mem.eql(u8, gw, "-")) return .{ .address = address, .prefix = prefix };
        return .{ .address = address, .prefix = prefix, .gateway = parseIp4(gw) orelse return null };
    }

    /// "192.168.1.50/24 192.168.1.1" (or "... -" without a gateway).
    pub fn format(st: Static, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const a = st.address;
        try w.print("{d}.{d}.{d}.{d}/{d} ", .{ a[0], a[1], a[2], a[3], st.prefix });
        if (st.gateway) |g| try w.print("{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) else try w.writeAll("-");
    }
};

pub fn parseIp4(s: []const u8) ?Ip4 {
    var out: Ip4 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&out) |*b| b.* = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    return if (it.next() == null) out else null;
}

/// How the wired adapter gets its address.
pub const Addressing = union(enum) {
    dhcp,
    static: Static,
};

/// The request choosing how the wired adapter gets its address.
pub fn ethernetRequest(buf: []u8, a: Addressing) []const u8 {
    return ethernetAdapterRequest(buf, "", a);
}

/// The request choosing how the wired adapter `adapter` gets its address.
pub fn ethernetAdapterRequest(buf: []u8, adapter: []const u8, a: Addressing) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (adapter.len > 0) w.print("ethernet {s} ", .{adapter}) catch {} else w.writeAll("ethernet ") catch {};
    switch (a) {
        .dhcp => w.writeAll("dhcp\n") catch {},
        .static => |st| w.print("static {f}\n", .{st}) catch {},
    }
    return w.buffered();
}

pub const EthernetRequest = struct {
    adapter_buf: [16]u8 = undefined,
    adapter_len: u8 = 0,
    addressing: Addressing,

    pub fn adapter(r: *const EthernetRequest) []const u8 {
        return r.adapter_buf[0..r.adapter_len];
    }
};

/// A Wi-Fi request.
pub const WifiRequest = union(enum) {
    scan: struct {
        adapter_buf: [16]u8 = undefined,
        adapter_len: u8 = 0,

        pub fn adapter(s: *const @This()) []const u8 {
            return s.adapter_buf[0..s.adapter_len];
        }
    },
    disconnect: struct {
        adapter_buf: [16]u8 = undefined,
        adapter_len: u8 = 0,

        pub fn adapter(d: *const @This()) []const u8 {
            return d.adapter_buf[0..d.adapter_len];
        }
    },
    connect: struct {
        adapter_buf: [16]u8 = undefined,
        adapter_len: u8 = 0,
        ssid_buf: [32]u8,
        ssid_len: u8,
        pass_buf: [63]u8,
        pass_len: u8,

        pub fn adapter(c: *const @This()) []const u8 {
            return c.adapter_buf[0..c.adapter_len];
        }
    },
};

pub const Request = union(enum) {
    status,
    ethernet: EthernetRequest,
    wifi: WifiRequest,

    pub fn parse(line: []const u8) ?Request {
        var f = std.mem.tokenizeAny(u8, line, " \n");
        const kind = f.next() orelse return null;
        if (std.mem.eql(u8, kind, "status")) return .status;
        if (std.mem.eql(u8, kind, "ethernet")) {
            const first = f.next() orelse return null;
            var er: EthernetRequest = .{ .addressing = .dhcp };
            const how = if (std.mem.eql(u8, first, "dhcp") or std.mem.eql(u8, first, "static")) first else blk: {
                if (first.len > er.adapter_buf.len) return null;
                er.adapter_len = @intCast(first.len);
                @memcpy(er.adapter_buf[0..first.len], first);
                break :blk f.next() orelse return null;
            };
            if (std.mem.eql(u8, how, "dhcp")) {
                er.addressing = .dhcp;
                return .{ .ethernet = er };
            }
            if (!std.mem.eql(u8, how, "static")) return null;
            const cidr = f.next() orelse return null;
            er.addressing = .{ .static = Static.parse(cidr, f.next() orelse "-") orelse return null };
            return .{ .ethernet = er };
        }
        if (!std.mem.eql(u8, kind, "wifi")) return null;
        const what = f.next() orelse return null;
        if (std.mem.eql(u8, what, "scan")) {
            var sc: @FieldType(WifiRequest, "scan") = .{};
            if (f.next()) |name| {
                if (name.len > sc.adapter_buf.len) return null;
                sc.adapter_len = @intCast(name.len);
                @memcpy(sc.adapter_buf[0..name.len], name);
            }
            return .{ .wifi = .{ .scan = sc } };
        }
        if (std.mem.eql(u8, what, "disconnect")) {
            var dc: @FieldType(WifiRequest, "disconnect") = .{};
            if (f.next()) |name| {
                if (name.len > dc.adapter_buf.len) return null;
                dc.adapter_len = @intCast(name.len);
                @memcpy(dc.adapter_buf[0..name.len], name);
            }
            return .{ .wifi = .{ .disconnect = dc } };
        }
        if (!std.mem.eql(u8, what, "connect")) return null;
        const tok1 = f.next() orelse return null;
        const tok2 = f.next() orelse return null;
        var r: @FieldType(WifiRequest, "connect") = .{ .ssid_buf = undefined, .ssid_len = 0, .pass_buf = undefined, .pass_len = 0 };
        const ssid_hex, const pass_hex = if (f.next()) |tok3| blk: {
            if (tok1.len > r.adapter_buf.len) return null;
            r.adapter_len = @intCast(tok1.len);
            @memcpy(r.adapter_buf[0..tok1.len], tok1);
            break :blk .{ tok2, tok3 };
        } else .{ tok1, tok2 };
        if (ssid_hex.len > 64 or ssid_hex.len % 2 != 0) return null;
        r.ssid_len = @intCast((std.fmt.hexToBytes(&r.ssid_buf, ssid_hex) catch return null).len);
        if (!std.mem.eql(u8, pass_hex, "-")) {
            if (pass_hex.len > 126 or pass_hex.len % 2 != 0) return null;
            r.pass_len = @intCast((std.fmt.hexToBytes(&r.pass_buf, pass_hex) catch return null).len);
        }
        return .{ .wifi = .{ .connect = r } };
    }
};

pub const Adapter = struct {
    name_buf: [16]u8 = undefined,
    name_len: u8 = 0,
    mac: [6]u8 = @splat(0),
    up: bool = false,

    pub fn name(a: *const Adapter) []const u8 {
        return a.name_buf[0..a.name_len];
    }

    pub fn setName(a: *Adapter, s: []const u8) void {
        a.name_len = @intCast(@min(s.len, a.name_buf.len));
        @memcpy(a.name_buf[0..a.name_len], s[0..a.name_len]);
    }
};

/// A wired adapter, and how it gets its address.
pub const Ethernet = struct {
    adapter: ?Adapter = null,
    addressing: Addressing = .dhcp,
};

pub const Report = struct {
    ethernet: Ethernet = .{},
    ethernets: [max_adapters]Ethernet = undefined,
    ethernet_len: usize = 0,
    /// The Wi-Fi adapter (or the first / active one when there are several).
    adapter: ?Adapter = null,
    adapters: [max_adapters]Adapter = undefined,
    adapter_len: usize = 0,
    scanning: bool = false,
    connection: Connection = .{},
    networks: [max_networks]Network = undefined,
    len: usize = 0,
    /// The manager refused the client.
    denied: bool = false,

    pub fn slice(r: *const Report) []const Network {
        return r.networks[0..r.len];
    }

    /// All Wi-Fi adapters reported: `adapters[0..adapter_len]`, or `adapter`
    /// if `adapters` was not populated directly.
    pub fn wifiAdapters(r: *const Report) []const Adapter {
        if (r.adapter_len > 0) return r.adapters[0..r.adapter_len];
        if (r.adapter) |*a| return a[0..1];
        return &.{};
    }

    /// Adds a Wi-Fi adapter to the report.
    pub fn addAdapter(r: *Report, a: Adapter) void {
        if (r.adapter == null) r.adapter = a;
        if (r.adapter_len < max_adapters) {
            r.adapters[r.adapter_len] = a;
            r.adapter_len += 1;
        }
    }

    /// All Ethernet entries reported: `ethernets[0..ethernet_len]`, or
    /// `ethernet` if `ethernets` was not populated directly.
    pub fn ethernetAdapters(r: *const Report) []const Ethernet {
        if (r.ethernet_len > 0) return r.ethernets[0..r.ethernet_len];
        if (r.ethernet.adapter != null or r.ethernet.addressing != .dhcp) return (&r.ethernet)[0..1];
        return &.{};
    }

    /// Adds a wired adapter entry to the report.
    pub fn addEthernet(r: *Report, e: Ethernet) void {
        if (r.ethernet_len == 0) r.ethernet = e;
        if (r.ethernet_len < max_adapters) {
            r.ethernets[r.ethernet_len] = e;
            r.ethernet_len += 1;
        }
    }

    /// How the wired adapter `name` gets its address.
    pub fn addressingFor(r: *const Report, name: []const u8) Addressing {
        for (r.ethernets[0..r.ethernet_len]) |*e| {
            if (e.adapter) |*a| if (std.mem.eql(u8, a.name(), name)) return e.addressing;
        }
        return r.ethernet.addressing;
    }

    /// Adds a network, keeping one entry per SSID (its strongest access
    /// point) and the list sorted by signal, strongest first. Networks
    /// without a name (hidden ones) are left out.
    pub fn add(r: *Report, n: Network) void {
        const name = n.ssid();
        if (name.len == 0 or std.mem.allEqual(u8, name, 0)) return;
        for (r.networks[0..r.len], 0..) |*e, i| if (std.mem.eql(u8, e.ssid(), name)) {
            if (n.signal_mbm <= e.signal_mbm) return;
            _ = remove(r, i);
            break;
        };
        // Where it goes; a full list drops its weakest.
        var at: usize = 0;
        while (at < r.len and r.networks[at].signal_mbm >= n.signal_mbm) at += 1;
        if (at == max_networks) return;
        const end = @min(r.len, max_networks - 1);
        std.mem.copyBackwards(Network, r.networks[at + 1 .. end + 1], r.networks[at..end]);
        r.networks[at] = n;
        r.len = end + 1;
    }

    fn remove(r: *Report, i: usize) Network {
        const n = r.networks[i];
        std.mem.copyForwards(Network, r.networks[i .. r.len - 1], r.networks[i + 1 .. r.len]);
        r.len -= 1;
        return n;
    }

    pub fn write(r: *const Report, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        const eths = r.ethernetAdapters();
        if (eths.len == 0) {
            const e = &r.ethernet;
            w.print("ethernet {s} ", .{if (e.adapter) |*a| a.name() else "-"}) catch {};
            switch (e.addressing) {
                .dhcp => w.writeAll("dhcp\n") catch {},
                .static => |st| w.print("static {f}\n", .{st}) catch {},
            }
        } else for (eths) |*e| {
            w.print("ethernet {s} ", .{if (e.adapter) |*a| a.name() else "-"}) catch {};
            switch (e.addressing) {
                .dhcp => w.writeAll("dhcp\n") catch {},
                .static => |st| w.print("static {f}\n", .{st}) catch {},
            }
        }
        const wifis = r.wifiAdapters();
        if (wifis.len == 0) {
            w.writeAll("wifi none\n") catch {};
        } else for (wifis) |*a| {
            const m = a.mac;
            w.print("wifi adapter {s} {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} {s}\n", .{ a.name(), m[0], m[1], m[2], m[3], m[4], m[5], if (a.up) "up" else "down" }) catch {};
        }
        if (r.scanning) w.writeAll("wifi scanning\n") catch {};
        const c = &r.connection;
        w.print("wifi connection {s} {s} ", .{ @tagName(c.state), @tagName(c.failure) }) catch {};
        if (c.ssid_len == 0) w.writeAll("-") catch {} else w.print("{x}", .{c.ssid()}) catch {};
        if (c.address) |a| w.print(" {d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch {} else w.writeAll(" -") catch {};
        if (c.adapter_len > 0) w.print(" {s}\n", .{c.adapter()}) catch {} else w.writeAll("\n") catch {};
        for (r.slice()) |*n| {
            w.print("wifi network {d} {d} {s} {x}\n", .{ n.signal_mbm, n.freq_mhz, @tagName(n.security), n.ssid() }) catch {};
        }
        w.writeAll("end\n") catch {};
        return w.buffered();
    }

    /// Reads a report; null if it is incomplete (no "end").
    pub fn parse(text: []const u8) ?Report {
        var r: Report = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            var kind = f.next() orelse continue;
            if (std.mem.eql(u8, kind, "end")) return r;
            // Wi-Fi's lines say what about it after "wifi".
            const is_wifi = std.mem.eql(u8, kind, "wifi");
            if (is_wifi) kind = f.next() orelse continue;
            if (is_wifi != !(std.mem.eql(u8, kind, "ethernet") or std.mem.eql(u8, kind, "denied"))) continue;
            if (std.mem.eql(u8, kind, "denied")) {
                r.denied = true;
                return r;
            } else if (std.mem.eql(u8, kind, "scanning")) {
                r.scanning = true;
            } else if (std.mem.eql(u8, kind, "ethernet")) {
                const name = f.next() orelse continue;
                var e: Ethernet = .{};
                if (!std.mem.eql(u8, name, "-")) {
                    var a: Adapter = .{};
                    a.setName(name);
                    e.adapter = a;
                }
                if (std.mem.eql(u8, f.next() orelse "", "static")) {
                    const cidr = f.next() orelse continue;
                    if (Static.parse(cidr, f.next() orelse "-")) |st| e.addressing = .{ .static = st };
                }
                if (e.adapter != null or r.ethernet_len > 0) {
                    r.addEthernet(e);
                } else {
                    r.ethernet = e;
                }
            } else if (std.mem.eql(u8, kind, "connection")) {
                var c: Connection = .{};
                c.state = std.meta.stringToEnum(ConnectionState, f.next() orelse continue) orelse .idle;
                c.failure = std.meta.stringToEnum(Failure, f.next() orelse continue) orelse .none;
                const hex = f.next() orelse continue;
                if (!std.mem.eql(u8, hex, "-") and hex.len <= 64 and hex.len % 2 == 0) {
                    c.ssid_len = @intCast((std.fmt.hexToBytes(&c.ssid_buf, hex) catch continue).len);
                }
                if (f.next()) |addr| if (!std.mem.eql(u8, addr, "-")) {
                    var a: [4]u8 = undefined;
                    var parts = std.mem.tokenizeScalar(u8, addr, '.');
                    const ok = for (&a) |*b| {
                        b.* = std.fmt.parseInt(u8, parts.next() orelse break false, 10) catch break false;
                    } else true;
                    if (ok) c.address = a;
                };
                if (f.next()) |ifname| if (!std.mem.eql(u8, ifname, "-")) c.setAdapter(ifname);
                r.connection = c;
            } else if (std.mem.eql(u8, kind, "adapter")) {
                var a: Adapter = .{};
                a.setName(f.next() orelse continue);
                var mac = std.mem.tokenizeScalar(u8, f.next() orelse "", ':');
                for (&a.mac) |*b| b.* = std.fmt.parseInt(u8, mac.next() orelse "0", 16) catch 0;
                a.up = std.mem.eql(u8, f.next() orelse "", "up");
                r.addAdapter(a);
            } else if (std.mem.eql(u8, kind, "network")) {
                var n: Network = .{};
                n.signal_mbm = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
                n.freq_mhz = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
                n.security = std.meta.stringToEnum(Security, f.next() orelse continue) orelse .open;
                const hex = f.next() orelse continue;
                var bytes: [32]u8 = undefined;
                const decoded = std.fmt.hexToBytes(bytes[0..@min(bytes.len, hex.len / 2)], hex[0 .. @min(bytes.len, hex.len / 2) * 2]) catch continue;
                n.setSsid(decoded);
                if (r.len < max_networks) {
                    r.networks[r.len] = n;
                    r.len += 1;
                }
            }
        }
        return null;
    }
};

const testing = std.testing;

fn net(name: []const u8, mbm: i32, freq: u32, sec: Security) Network {
    var n: Network = .{ .signal_mbm = mbm, .freq_mhz = freq, .security = sec };
    n.setSsid(name);
    return n;
}

test "networks are listed once each, strongest first, without hidden ones" {
    var r: Report = .{};
    r.add(net("Cafe", -7000, 2412, .open));
    r.add(net("Home", -6100, 2437, .wpa2));
    r.add(net("", -3000, 2462, .wpa2));
    r.add(net("\x00\x00", -3000, 2462, .wpa2));
    // The same network's stronger access point, on 5 GHz.
    r.add(net("Cafe", -4800, 5180, .open));
    r.add(net("Cafe", -9000, 2412, .open));
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("Cafe", r.slice()[0].ssid());
    try testing.expectEqualStrings("5 GHz", r.slice()[0].band());
    try testing.expectEqualStrings("Home", r.slice()[1].ssid());
    try testing.expectEqual(@as(u8, 4), r.slice()[0].bars());
    try testing.expectEqual(@as(u8, 3), r.slice()[1].bars());

    // A full list keeps the strongest.
    var full: Report = .{};
    for (0..max_networks + 5) |i| {
        var name: [8]u8 = undefined;
        full.add(net(std.fmt.bufPrint(&name, "n{d}", .{i}) catch unreachable, -9000 + @as(i32, @intCast(i)) * 100, 2412, .wpa2));
    }
    try testing.expectEqual(@as(usize, max_networks), full.len);
    try testing.expect(full.slice()[0].signal_mbm > full.slice()[max_networks - 1].signal_mbm);
    try testing.expectEqualStrings("n28", full.slice()[0].ssid());
}

test "reports go through the socket as text and come back the same" {
    var r: Report = .{ .scanning = true };
    var a: Adapter = .{ .mac = .{ 0xb8, 0x27, 0xeb, 1, 2, 3 }, .up = true };
    a.setName("wlan0");
    r.addAdapter(a);
    var a2: Adapter = .{ .mac = .{ 0xb8, 0x27, 0xeb, 4, 5, 6 }, .up = false };
    a2.setName("wlan1");
    r.addAdapter(a2);
    r.add(net("Home", -5400, 2437, .wpa2));
    r.add(net("Café net", -6100, 5180, .wpa3));
    var buf: [1024]u8 = undefined;
    const text = r.write(&buf);
    try testing.expect(std.mem.startsWith(u8, text, "ethernet - dhcp\nwifi adapter wlan0 b8:27:eb:01:02:03 up\nwifi adapter wlan1 b8:27:eb:04:05:06 down\nwifi scanning\nwifi connection idle none - -\nwifi network -5400 2437 wpa2 486f6d65\n"));
    const back = Report.parse(text).?;
    try testing.expectEqualStrings("wlan0", back.adapter.?.name());
    try testing.expectEqual(@as(usize, 2), back.wifiAdapters().len);
    try testing.expectEqualStrings("wlan1", back.wifiAdapters()[1].name());
    try testing.expectEqual(a.mac, back.adapter.?.mac);
    try testing.expect(back.scanning and !back.denied);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("Café net", back.slice()[1].ssid());
    try testing.expectEqual(Security.wpa3, back.slice()[1].security);

    try testing.expect(Report.parse("wifi none\nwifi network -5400") == null);
    try testing.expect(Report.parse("denied\n").?.denied);
    try testing.expect(Report.parse("wifi none\nend\n").?.adapter == null);
    // Wi-Fi's words are only read after "wifi".
    try testing.expect(!Report.parse("scanning\nend\n").?.scanning);
}

test "requests and the connection state go through the socket" {
    var buf: [256]u8 = undefined;
    const req = connectRequest(&buf, "Home", "correct horse");
    try testing.expectEqualStrings("wifi connect 486f6d65 636f727265637420686f727365\n", req);
    const r = Request.parse(req).?.wifi.connect;
    try testing.expectEqualStrings("", r.adapter());
    try testing.expectEqualStrings("Home", r.ssid_buf[0..r.ssid_len]);
    try testing.expectEqualStrings("correct horse", r.pass_buf[0..r.pass_len]);
    const req_wlan1 = connectAdapterRequest(&buf, "wlan1", "Home", "correct horse");
    const r_wlan1 = Request.parse(req_wlan1).?.wifi.connect;
    try testing.expectEqualStrings("wlan1", r_wlan1.adapter());
    try testing.expectEqualStrings("Home", r_wlan1.ssid_buf[0..r_wlan1.ssid_len]);
    const open = Request.parse(connectRequest(&buf, "Cafe", "")).?.wifi.connect;
    try testing.expectEqual(@as(u8, 0), open.pass_len);
    try testing.expect(Request.parse("wifi scan\n").?.wifi == .scan);
    try testing.expectEqualStrings("wlan1", Request.parse("wifi scan wlan1\n").?.wifi.scan.adapter());
    try testing.expect(Request.parse("wifi disconnect\n").?.wifi == .disconnect);
    try testing.expectEqualStrings("wlan1", Request.parse("wifi disconnect wlan1\n").?.wifi.disconnect.adapter());
    try testing.expect(Request.parse("wifi connect zz -\n") == null);
    try testing.expect(Request.parse("scan\n") == null);
    try testing.expect(Request.parse("wifi\n") == null);
    try testing.expect(Request.parse("reboot\n") == null);

    var rep: Report = .{};
    rep.connection = .{ .state = .connected, .address = .{ 192, 168, 1, 50 } };
    rep.connection.setSsid("Home");
    rep.connection.setAdapter("wlan1");
    var out: [512]u8 = undefined;
    const back = Report.parse(rep.write(&out)).?;
    try testing.expectEqual(ConnectionState.connected, back.connection.state);
    try testing.expectEqualStrings("Home", back.connection.ssid());
    try testing.expectEqualStrings("wlan1", back.connection.adapter());
    try testing.expectEqual([4]u8{ 192, 168, 1, 50 }, back.connection.address.?);
    rep.connection = .{ .state = .failed, .failure = .wrong_password };
    const failed = Report.parse(rep.write(&out)).?;
    try testing.expectEqual(Failure.wrong_password, failed.connection.failure);
    try testing.expect(failed.connection.address == null and failed.connection.ssid_len == 0);
}

test "the wired adapter's addressing goes through the socket" {
    var buf: [256]u8 = undefined;
    const st = Static.parse("192.168.1.50/24", "192.168.1.1").?;
    try testing.expectEqual(Ip4{ 192, 168, 1, 50 }, st.address);
    try testing.expectEqual(@as(u6, 24), st.prefix);
    try testing.expectEqual(Ip4{ 192, 168, 1, 1 }, st.gateway.?);
    try testing.expect(Static.parse("10.0.0.2/8", "").?.gateway == null);
    try testing.expect(Static.parse("10.0.0/8", "") == null);
    try testing.expect(Static.parse("10.0.0.2/33", "") == null);
    try testing.expect(Static.parse("10.0.0.2", "") == null);
    try testing.expect(Static.parse("10.0.0.2/8", "10.0.0.256") == null);

    const req = ethernetRequest(&buf, .{ .static = st });
    try testing.expectEqualStrings("ethernet static 192.168.1.50/24 192.168.1.1\n", req);
    try testing.expectEqual(st, Request.parse(req).?.ethernet.addressing.static);
    const req_eth1 = ethernetAdapterRequest(&buf, "eth1", .{ .static = st });
    try testing.expectEqualStrings("ethernet eth1 static 192.168.1.50/24 192.168.1.1\n", req_eth1);
    try testing.expectEqualStrings("eth1", Request.parse(req_eth1).?.ethernet.adapter());
    try testing.expectEqual(st, Request.parse(req_eth1).?.ethernet.addressing.static);
    try testing.expect(Request.parse(ethernetRequest(&buf, .dhcp)).?.ethernet.addressing == .dhcp);
    try testing.expectEqualStrings("eth1", Request.parse(ethernetAdapterRequest(&buf, "eth1", .dhcp)).?.ethernet.adapter());
    try testing.expect(Request.parse("ethernet static 10.0.0.2/8 -\n").?.ethernet.addressing.static.gateway == null);
    try testing.expect(Request.parse("ethernet static nonsense\n") == null);
    try testing.expect(Request.parse("status\n").? == .status);

    var r: Report = .{};
    var a: Adapter = .{};
    a.setName("eth0");
    r.addEthernet(.{ .adapter = a, .addressing = .{ .static = Static.parse("10.0.0.2/8", "-").? } });
    var a2: Adapter = .{};
    a2.setName("eth1");
    r.addEthernet(.{ .adapter = a2, .addressing = .dhcp });
    var out: [512]u8 = undefined;
    const text = r.write(&out);
    try testing.expect(std.mem.startsWith(u8, text, "ethernet eth0 static 10.0.0.2/8 -\nethernet eth1 dhcp\n"));
    const back = Report.parse(text).?;
    try testing.expectEqualStrings("eth0", back.ethernet.adapter.?.name());
    try testing.expectEqual(r.ethernet.addressing.static, back.addressingFor("eth0").static);
    try testing.expect(back.addressingFor("eth1") == .dhcp);
    try testing.expect(Report.parse("ethernet - dhcp\nwifi none\nend\n").?.ethernet.adapter == null);
}
