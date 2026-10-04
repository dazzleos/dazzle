//! The Wi-Fi manager's protocol. Init runs the manager (src/init/wifi.zig),
//! the only process allowed to scan (scanning needs CAP_NET_ADMIN); it
//! listens on a socket in the user's runtime directory and answers only the
//! settings app, checked by the program the connecting process runs.
//!
//! A client connects, sends "scan\n" and reads the report until the manager
//! closes the connection:
//!
//!     adapter wlan0 b8:27:eb:01:02:03 up
//!     scanning
//!     network -5400 2437 wpa2 486f6d65
//!     end
//!
//! "adapter" names the Wi-Fi adapter (or "none" says there is none);
//! "scanning" says a scan is under way; each "network" is one network: its
//! signal in mBm (hundredths of dBm), the frequency in MHz of its strongest
//! access point, its security and its SSID in hexadecimal (SSIDs are bytes,
//! not necessarily text). A client the manager does not serve gets
//! "denied\n".

const std = @import("std");

/// The socket's name in $XDG_RUNTIME_DIR.
pub const socket_name = "stardust-wifi";

/// The only program the manager answers.
pub const allowed_program = "/apps/stardust-settings/stardust-settings";

pub const max_networks = 24;

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

pub const Report = struct {
    adapter: ?Adapter = null,
    scanning: bool = false,
    networks: [max_networks]Network = undefined,
    len: usize = 0,
    /// The manager refused the client.
    denied: bool = false,

    pub fn slice(r: *const Report) []const Network {
        return r.networks[0..r.len];
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
        if (r.adapter) |*a| {
            const m = a.mac;
            w.print("adapter {s} {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} {s}\n", .{ a.name(), m[0], m[1], m[2], m[3], m[4], m[5], if (a.up) "up" else "down" }) catch {};
        } else w.writeAll("none\n") catch {};
        if (r.scanning) w.writeAll("scanning\n") catch {};
        for (r.slice()) |*n| {
            w.print("network {d} {d} {s} {x}\n", .{ n.signal_mbm, n.freq_mhz, @tagName(n.security), n.ssid() }) catch {};
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
            const kind = f.next() orelse continue;
            if (std.mem.eql(u8, kind, "end")) return r;
            if (std.mem.eql(u8, kind, "denied")) {
                r.denied = true;
                return r;
            } else if (std.mem.eql(u8, kind, "scanning")) {
                r.scanning = true;
            } else if (std.mem.eql(u8, kind, "adapter")) {
                var a: Adapter = .{};
                a.setName(f.next() orelse continue);
                var mac = std.mem.tokenizeScalar(u8, f.next() orelse "", ':');
                for (&a.mac) |*b| b.* = std.fmt.parseInt(u8, mac.next() orelse "0", 16) catch 0;
                a.up = std.mem.eql(u8, f.next() orelse "", "up");
                r.adapter = a;
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
    r.adapter = a;
    r.add(net("Home", -5400, 2437, .wpa2));
    r.add(net("Café net", -6100, 5180, .wpa3));
    var buf: [1024]u8 = undefined;
    const text = r.write(&buf);
    try testing.expect(std.mem.startsWith(u8, text, "adapter wlan0 b8:27:eb:01:02:03 up\nscanning\nnetwork -5400 2437 wpa2 486f6d65\n"));
    const back = Report.parse(text).?;
    try testing.expectEqualStrings("wlan0", back.adapter.?.name());
    try testing.expectEqual(a.mac, back.adapter.?.mac);
    try testing.expect(back.scanning and !back.denied);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("Café net", back.slice()[1].ssid());
    try testing.expectEqual(Security.wpa3, back.slice()[1].security);

    try testing.expect(Report.parse("none\nnetwork -5400") == null);
    try testing.expect(Report.parse("denied\n").?.denied);
    try testing.expect(Report.parse("none\nend\n").?.adapter == null);
}
