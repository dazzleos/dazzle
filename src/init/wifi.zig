//! Wi-Fi, for the network manager (network.zig): finds the Wi-Fi adapter,
//! brings it up, scans for networks, joins the one the settings app asks
//! for (open, or WPA2 with the supplicant in supplicant.zig), and gets an
//! address for it by DHCP. nl80211 needs CAP_NET_ADMIN to scan, connect
//! and install keys; the supplicant's EAPOL frames go through a packet
//! socket (CAP_NET_RAW).
//!
//! A scan request answers at once with what the last scan found, and starts
//! a new scan if that one is older than `rescan_ns` (the settings app asks
//! every few seconds while it is open, so nothing scans while it is not).
//!
//! Joining: the network's strongest access point from the last scan is
//! asked to connect; the driver associates (the chips' firmware does that
//! itself). For WPA2 the supplicant then does the 4-way handshake over
//! EAPOL frames and its keys are installed. A child process then runs the
//! network manager's DHCP client on the interface (see `network.runDhcp`)
//! until the connection ends. A lost connection is tried again. Nothing is
//! remembered across a reboot: the system lives in RAM.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const nl80211 = @import("nl80211.zig");
const supplicant = @import("supplicant.zig");
const ipv4 = @import("ipv4.zig");
const dhcp = @import("dhcp.zig");
const nat = @import("nat.zig");

const wifi = sys.network;
const print = sys.print;

/// How old a scan may be before a request starts another.
const rescan_ns = 10 * std.time.ns_per_s;
/// A scan that has not finished by then is given up.
const scan_timeout_ns = 15 * std.time.ns_per_s;
/// How often to look for an adapter (one can be slow to appear: its
/// firmware loads after boot).
const look_ns = 2 * std.time.ns_per_s;
/// Connecting and the handshake must be done by then.
const connect_timeout_ns = 20 * std.time.ns_per_s;
/// A lost connection is tried again after this.
const retry_ns = 5 * std.time.ns_per_s;

const eth_p_pae: u16 = 0x888e;

/// Joining a network, and staying joined.
const Join = struct {
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,
    pass_buf: [63]u8 = undefined,
    pass_len: u8 = 0,
    has_bss: bool = false,
    /// The PMK; null for an open network.
    pmk: ?[32]u8 = null,
    /// Key management suite (`akm_psk`, `akm_psk_sha256`, or `akm_sae`); 0 for open.
    akm: u32 = 0,
    sae: ?supplicant.Sae = null,
    sae_committed: bool = false,
    sae_confirmed: bool = false,
    bss: nl80211.Bss = undefined,
    rsn_buf: [44]u8 = undefined,
    handshake: supplicant.Handshake = undefined,
    eapol: ?linux.fd_t = null,
    /// Message 1 can arrive from the radio before the driver's connect
    /// event (and before the netdev transmit path is ready for message 2);
    /// it is held until `events` sees `connected`.
    pending_eapol_buf: [512]u8 = undefined,
    pending_eapol_len: u16 = 0,
    pending_eapol_src: [6]u8 = @splat(0),
    started_ns: u64 = 0,
    dhcp_pid: ?linux.pid_t = null,
    /// When to try again after losing the connection.
    retry_at: ?u64 = null,

    fn ssid(j: *const Join) []const u8 {
        return j.ssid_buf[0..j.ssid_len];
    }

    fn passphrase(j: *const Join) []const u8 {
        return j.pass_buf[0..j.pass_len];
    }
};

const StationAuth = struct {
    mac: [6]u8,
    auth: supplicant.Authenticator,
};

/// Running an access point (hotspot).
const Hotspot = struct {
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,
    pmk: ?[32]u8 = null,
    gtk: [16]u8 = undefined,
    rsn_buf: [22]u8 = undefined,
    eapol: ?linux.fd_t = null,
    dhcp_fd: ?linux.fd_t = null,
    pool: dhcp.Pool = .{},
    stations: [8]?StationAuth = @splat(null),

    fn ssid(h: *const Hotspot) []const u8 {
        return h.ssid_buf[0..h.ssid_len];
    }

    fn stationFor(h: *Hotspot, mac: [6]u8, ap_mac: [6]u8) ?*StationAuth {
        const pmk = h.pmk orelse return null;
        for (&h.stations) |*entry| {
            if (entry.*) |*s| if (std.mem.eql(u8, &s.mac, &mac)) return s;
        }
        const rsn = supplicant.rsnElement(&h.rsn_buf, supplicant.cipher_ccmp);
        for (&h.stations) |*entry| {
            if (entry.* == null) {
                entry.* = .{
                    .mac = mac,
                    .auth = .{ .pmk = pmk, .aa = ap_mac, .spa = mac, .gtk = h.gtk, .rsn = rsn },
                };
                return &entry.*.?;
            }
        }
        h.stations[0] = .{
            .mac = mac,
            .auth = .{ .pmk = pmk, .aa = ap_mac, .spa = mac, .gtk = h.gtk, .rsn = rsn },
        };
        return &h.stations[0].?;
    }

    fn removeStation(h: *Hotspot, mac: [6]u8) void {
        for (&h.stations) |*entry| {
            if (entry.*) |s| if (std.mem.eql(u8, &s.mac, &mac)) {
                entry.* = null;
            };
        }
    }
};

pub const Manager = struct {
    nl: ?nl80211.Nl80211 = null,
    station: ?nl80211.Interface = null,
    stations: [wifi.max_adapters]nl80211.Interface = undefined,
    station_len: usize = 0,
    report: wifi.Report = .{},
    /// When the last scan finished, and when the one under way started.
    scanned_ns: u64 = 0,
    scan_started_ns: ?u64 = null,
    looked_ns: u64 = 0,
    /// Logged once each.
    said_no_wifi: bool = false,
    /// The network being joined (or joined), if any.
    join: ?Join = null,
    /// The active hotspot, if any.
    hotspot: ?Hotspot = null,
    /// How the Wi-Fi client gets its address (DHCP or static).
    addressing: wifi.Addressing = .dhcp,
    preferred_adapter_buf: [16]u8 = undefined,
    preferred_adapter_len: u8 = 0,
    pending_hotspot: ?wifi.WifiRequest.Connect = null,

    fn preferredAdapter(m: *const Manager) []const u8 {
        return m.preferred_adapter_buf[0..m.preferred_adapter_len];
    }

    fn setPreferredAdapter(m: *Manager, name: []const u8) void {
        m.preferred_adapter_len = @intCast(@min(name.len, m.preferred_adapter_buf.len));
        @memcpy(m.preferred_adapter_buf[0..m.preferred_adapter_len], name[0..m.preferred_adapter_len]);
    }

    /// Loads saved Wi-Fi configuration at startup.
    pub fn loadConfig(m: *Manager, cfg: *const wifi.Config, now: u64) void {
        m.addressing = cfg.wifi_addressing;
        m.report.connection.addressing = cfg.wifi_addressing;
        if (cfg.wifi_address_adapter_len > 0) {
            m.setPreferredAdapter(cfg.wifiAddressAdapter());
        }
        switch (cfg.wifi_mode) {
            .none => {},
            .connect => |*con| {
                if (con.adapter_len > 0) m.setPreferredAdapter(con.adapter());
                m.connect(con.ssid(), con.passphrase(), now);
            },
            .hotspot => |*hs| {
                if (hs.adapter_len > 0) m.setPreferredAdapter(hs.adapter());
                m.pending_hotspot = hs.*;
            },
        }
    }

    /// Looks for Wi-Fi adapters (and nl80211 itself).
    pub fn look(m: *Manager, now: u64) void {
        if (now -| m.looked_ns < look_ns) return;
        m.looked_ns = now;
        if (m.nl == null) {
            m.nl = nl80211.Nl80211.open() catch |err| {
                if (!m.said_no_wifi) print("dazzle: wifi: no nl80211 ({s}): this kernel has no Wi-Fi\n", .{@errorName(err)});
                m.said_no_wifi = true;
                return;
            };
        }
        var found: [wifi.max_adapters]nl80211.Interface = undefined;
        const n = m.nl.?.findStations(&found) catch return;
        for (found[0..n]) |*ifc| {
            const known = for (m.stations[0..m.station_len]) |old| {
                if (std.mem.eql(u8, old.adapter.name(), ifc.adapter.name())) break true;
            } else false;
            if (!known) print("dazzle: wifi: found {s}\n", .{ifc.adapter.name()});
            ifc.adapter.up = ipv4.bringUp(ifc.adapter.name());
        }
        m.stations = found;
        m.station_len = n;
        if (n == 0) {
            m.station = null;
        } else if (m.station) |cur| {
            for (m.stations[0..n]) |ifc| {
                if (std.mem.eql(u8, ifc.adapter.name(), cur.adapter.name())) {
                    m.station = ifc;
                    break;
                }
            } else m.station = m.stations[0];
        } else {
            m.station = m.stations[0];
            if (m.preferred_adapter_len > 0) {
                for (m.stations[0..n]) |ifc| {
                    if (std.mem.eql(u8, ifc.adapter.name(), m.preferredAdapter())) {
                        m.station = ifc;
                        break;
                    }
                }
            }
        }
        if (m.station != null) {
            if (m.pending_hotspot) |hs| {
                if (hs.adapter_len > 0) m.selectStation(hs.adapter());
                if (hs.adapter_len == 0 or std.mem.eql(u8, m.station.?.adapter.name(), hs.adapter())) {
                    m.pending_hotspot = null;
                    m.startHotspot(hs.ssid(), hs.passphrase(), hs.network, hs.upstream());
                }
            } else if (m.join) |*j| {
                if (!j.has_bss and m.scan_started_ns == null and j.retry_at == null) {
                    m.tryStartPendingJoin(now);
                }
            }
        }
    }

    fn selectStation(m: *Manager, name: []const u8) void {
        if (name.len == 0) return;
        m.setPreferredAdapter(name);
        if (m.station) |cur| if (std.mem.eql(u8, cur.adapter.name(), name)) return;
        for (m.stations[0..m.station_len]) |ifc| {
            if (std.mem.eql(u8, ifc.adapter.name(), name)) {
                m.leave(true);
                m.stopHotspot();
                m.station = ifc;
                m.scanned_ns = 0;
                m.scan_started_ns = null;
                m.report.len = 0;
                if (m.nl) |*nl| nl.scanResults(ifc.index, &m.report) catch {};
                break;
            }
        }
    }

    /// Handles a Wi-Fi request.
    pub fn handle(m: *Manager, req: wifi.WifiRequest, now: u64) void {
        switch (req) {
            .scan => |s| {
                m.selectStation(s.adapter());
                m.scan(now);
            },
            .disconnect => |d| {
                m.selectStation(d.adapter());
                m.pending_hotspot = null;
                m.leave(true);
                m.stopHotspot();
            },
            .address => |a| {
                m.selectStation(a.adapter());
                m.addressing = a.addressing;
                m.report.connection.addressing = a.addressing;
                if (m.join != null and m.report.connection.state.joined()) {
                    m.stopDhcp();
                    if (m.station) |st| ipv4.removeAddress(st.adapter.name());
                    m.report.connection.address = null;
                    m.startDhcp();
                }
            },
            .connect => |c| {
                m.selectStation(c.adapter());
                m.pending_hotspot = null;
                m.stopHotspot();
                m.connect(c.ssid_buf[0..c.ssid_len], c.pass_buf[0..c.pass_len], now);
            },
            .hotspot => |h| {
                m.selectStation(h.adapter());
                m.pending_hotspot = null;
                m.startHotspot(h.ssid_buf[0..h.ssid_len], h.pass_buf[0..h.pass_len], h.network, h.upstream());
            },
        }
    }

    /// What to report: the adapters, the scan, the connection, and the hotspot.
    pub fn fill(m: *const Manager, r: *wifi.Report) void {
        r.adapter = if (m.station) |st| st.adapter else null;
        r.adapter_len = 0;
        for (m.stations[0..m.station_len]) |st| r.addAdapter(st.adapter);
        r.scanning = m.scan_started_ns != null;
        r.connection = m.report.connection;
        r.connection.addressing = m.addressing;
        r.hotspot = m.report.hotspot;
        if (m.station) |st| {
            r.connection.setAdapter(st.adapter.name());
            r.hotspot.setAdapter(st.adapter.name());
        }
        r.networks = m.report.networks;
        r.len = m.report.len;
    }

    /// nl80211's events and EAPOL frames come on these.
    pub fn eventFd(m: *const Manager) linux.fd_t {
        return if (m.nl) |nl| nl.events.fd else -1;
    }

    pub fn eapolFd(m: *const Manager) linux.fd_t {
        if (m.join) |j| if (j.eapol) |fd| return fd;
        if (m.hotspot) |h| if (h.eapol) |fd| return fd;
        return -1;
    }

    pub fn dhcpFd(m: *const Manager) linux.fd_t {
        if (m.hotspot) |h| if (h.dhcp_fd) |fd| return fd;
        return -1;
    }

    /// Starts a scan if the last is old.
    fn scan(m: *Manager, now: u64) void {
        const st = m.station orelse return;
        // Not while a hotspot is active or while joining an AP on a channel:
        // scanning takes the radio off the channel.
        if (m.hotspot != null or m.report.hotspot.state == .active) return;
        const associating = if (m.join) |j| j.has_bss else false;
        switch (m.report.connection.state) {
            .connecting => if (associating) return,
            .authenticating, .addressing => return,
            else => {},
        }
        if (m.scan_started_ns != null or (m.scanned_ns != 0 and now -| m.scanned_ns < rescan_ns)) return;
        if (m.nl.?.triggerScan(st.index)) {
            m.scan_started_ns = now;
        } else |err| switch (err) {
            // Another scan is under way (the kernel's own).
            error.Busy => m.scan_started_ns = now,
            else => {
                print(sys.log_warning ++ "dazzle: wifi: cannot scan ({s})\n", .{@errorName(err)});
                // Down, perhaps: up again, and try at the next request.
                m.station.?.adapter.up = ipv4.bringUp(st.adapter.name());
            },
        }
    }

    fn fail(m: *Manager, why: wifi.Failure) void {
        print(sys.log_warning ++ "dazzle: wifi: could not join \"{s}\": {s}\n", .{ m.report.connection.ssid(), @tagName(why) });
        m.leave(false);
        m.report.connection.state = .failed;
        m.report.connection.failure = why;
    }

    fn failHotspot(m: *Manager, why: wifi.Failure) void {
        print(sys.log_warning ++ "dazzle: wifi: could not start hotspot \"{s}\": {s}\n", .{ m.report.hotspot.ssid(), @tagName(why) });
        const saved = m.report.hotspot;
        m.stopHotspot();
        m.report.hotspot = saved;
        m.report.hotspot.state = .failed;
        m.report.hotspot.failure = why;
        m.report.hotspot.address = null;
    }

    fn setState(m: *Manager, state: wifi.ConnectionState) void {
        m.report.connection.state = state;
        m.report.connection.failure = .none;
    }

    fn switchIfType(nl: *nl80211.Nl80211, st: nl80211.Interface, iftype: u32) !void {
        nl.setInterfaceType(st.index, iftype) catch {
            ipv4.bringDown(st.adapter.name());
            try nl.setInterfaceType(st.index, iftype);
        };
        _ = ipv4.bringUp(st.adapter.name());
    }

    /// Starts an access point (hotspot) on the selected adapter.
    fn startHotspot(m: *Manager, ssid: []const u8, passphrase: []const u8, net: wifi.HotspotNetwork, upstream: []const u8) void {
        m.leave(true);
        m.stopHotspot();
        m.report.hotspot = .{ .prefix = net.prefix };
        m.report.hotspot.setSsid(ssid);
        m.report.hotspot.setPassphrase(passphrase);
        m.report.hotspot.setUpstream(upstream);
        if (ssid.len == 0 or ssid.len > wifi.max_ssid) return m.failHotspot(.rejected);
        if (passphrase.len > 0 and !supplicant.validPassphrase(passphrase)) return m.failHotspot(.bad_passphrase);
        const st = m.station orelse return m.failHotspot(.not_found);
        const nl = &(m.nl orelse return m.failHotspot(.not_found));

        const ap_ip = net.serverIp();
        const share = upstream.len > 0 and !std.mem.eql(u8, upstream, "none");
        var h: Hotspot = .{
            .ssid_len = @intCast(ssid.len),
            .pool = .{
                .server_ip = ap_ip,
                .subnet_mask = net.subnetMask(),
                .share_internet = share,
                .dns = if (share) readResolvConfDns() else null,
            },
        };
        @memcpy(h.ssid_buf[0..ssid.len], ssid);
        if (passphrase.len > 0) {
            h.pmk = supplicant.pmkFromPassphrase(passphrase, ssid);
            random(&h.gtk);
            _ = supplicant.rsnElement(&h.rsn_buf, supplicant.cipher_ccmp);
        }

        switchIfType(nl, st, nl80211.iftype_ap) catch |err| {
            print(sys.log_warning ++ "dazzle: wifi: cannot switch {s} to AP mode ({s})\n", .{ st.adapter.name(), @errorName(err) });
            return m.failHotspot(.unsupported);
        };
        if (h.pmk != null) {
            h.eapol = openEapol(st.index) catch |err| {
                print(sys.log_warning ++ "dazzle: wifi: cannot open EAPOL socket ({s})\n", .{@errorName(err)});
                return m.failHotspot(.rejected);
            };
        }
        nl.startAp(st.index, .{ .ssid = ssid, .bssid = st.adapter.mac, .wpa2 = h.pmk != null }) catch |err| {
            if (h.eapol) |fd| sys.close(fd);
            print(sys.log_warning ++ "dazzle: wifi: cannot start AP on {s} ({s})\n", .{ st.adapter.name(), @errorName(err) });
            return m.failHotspot(.rejected);
        };
        if (h.pmk != null) {
            nl.setGroupKey(st.index, supplicant.cipher_ccmp, 1, &h.gtk, @splat(0)) catch |err| {
                print(sys.log_warning ++ "dazzle: wifi: cannot install AP group key ({s})\n", .{@errorName(err)});
            };
        }
        ipv4.setStatic(st.adapter.name(), ap_ip, net.prefix, null) catch |err| {
            print(sys.log_warning ++ "dazzle: wifi: cannot configure hotspot address ({s})\n", .{@errorName(err)});
            m.hotspot = h;
            return m.failHotspot(.rejected);
        };
        if (share) {
            nat.enableMasquerade(ap_ip, net.subnetMask(), upstream) catch |err| {
                print(sys.log_warning ++ "dazzle: wifi: cannot configure hotspot NAT ({s})\n", .{@errorName(err)});
            };
        } else {
            nat.disableMasquerade();
        }
        setIpForward(share);
        h.dhcp_fd = ipv4.openDhcpServer(st.adapter.name()) catch null;
        m.hotspot = h;
        m.report.hotspot.state = .active;
        m.report.hotspot.failure = .none;
        m.report.hotspot.address = ap_ip;
        m.report.hotspot.prefix = net.prefix;
        m.scan_started_ns = null;
        print("dazzle: wifi: hotspot \"{s}\" active on {s} ({d}.{d}.{d}.{d}/{d})\n", .{ ssid, st.adapter.name(), ap_ip[0], ap_ip[1], ap_ip[2], ap_ip[3], net.prefix });
    }

    fn stopHotspot(m: *Manager) void {
        if (m.hotspot) |*h| {
            if (h.dhcp_fd) |fd| sys.close(fd);
            h.dhcp_fd = null;
            if (h.eapol) |fd| sys.close(fd);
            h.eapol = null;
            setIpForward(false);
            nat.disableMasquerade();
            if (m.station) |st| {
                if (m.nl) |*nl| {
                    nl.stopAp(st.index) catch {};
                    switchIfType(nl, st, nl80211.iftype_station) catch {};
                }
                ipv4.removeAddress(st.adapter.name());
            }
            m.hotspot = null;
        }
        m.report.hotspot = .{};
    }

    /// Starts joining a network.
    fn connect(m: *Manager, ssid: []const u8, passphrase: []const u8, now: u64) void {
        m.leave(true);
        m.report.connection = .{ .addressing = m.addressing };
        m.report.connection.setSsid(ssid);
        if (ssid.len == 0 or ssid.len > wifi.max_ssid) return m.fail(.rejected);
        if (passphrase.len > 0 and !supplicant.validPassphrase(passphrase)) return m.fail(.bad_passphrase);

        var j: Join = .{ .started_ns = now };
        @memcpy(j.ssid_buf[0..ssid.len], ssid);
        j.ssid_len = @intCast(ssid.len);
        @memcpy(j.pass_buf[0..passphrase.len], passphrase);
        j.pass_len = @intCast(passphrase.len);
        if (passphrase.len > 0) {
            j.pmk = supplicant.pmkFromPassphrase(passphrase, ssid);
        }
        m.join = j;
        m.tryStartPendingJoin(now);
    }

    fn tryStartPendingJoin(m: *Manager, now: u64) void {
        const j = &(m.join orelse return);
        const st = m.station orelse {
            if (m.looked_ns == 0) {
                m.setState(.connecting);
            } else {
                m.report.connection.state = .failed;
                m.report.connection.failure = .not_found;
                j.retry_at = now + retry_ns;
            }
            return;
        };
        const nl = &(m.nl orelse return);
        if (nl.findBss(st.index, j.ssid()) catch null) |bss| {
            const wpa = bss.rsn_len > 0;
            if (wpa) {
                if (!bss.ccmp or (!bss.psk and !bss.psk_sha256 and !bss.sae) or (bss.group_cipher != supplicant.cipher_ccmp and bss.group_cipher != supplicant.cipher_tkip)) return m.fail(.unsupported);
                if (bss.psk) {
                    j.akm = supplicant.akm_psk;
                    if (!supplicant.validPassphrase(j.passphrase())) return m.fail(.bad_passphrase);
                    if (j.pmk == null) j.pmk = supplicant.pmkFromPassphrase(j.passphrase(), j.ssid());
                } else if (bss.psk_sha256) {
                    j.akm = supplicant.akm_psk_sha256;
                    if (!supplicant.validPassphrase(j.passphrase())) return m.fail(.bad_passphrase);
                    if (j.pmk == null) j.pmk = supplicant.pmkFromPassphrase(j.passphrase(), j.ssid());
                } else {
                    j.akm = supplicant.akm_sae;
                    if (j.passphrase().len < 8 or j.passphrase().len > 63) return m.fail(.bad_passphrase);
                    j.pmk = @splat(0);
                }
            } else {
                if (bss.network.security != .open) return m.fail(.unsupported);
                j.akm = 0;
                j.pmk = null;
            }
            j.bss = bss;
            j.has_bss = true;
            m.startJoin(now) catch |err| {
                print(sys.log_warning ++ "dazzle: wifi: cannot connect ({s})\n", .{@errorName(err)});
                m.fail(.rejected);
            };
            return;
        }
        // Not in the scan cache yet: if no scan has finished recently, start
        // one and wait for `ev.scan_done` before declaring `not_found`.
        if (m.scanned_ns == 0 or m.scan_started_ns != null) {
            m.setState(.connecting);
            m.scan(now);
            if (m.scan_started_ns != null) return;
        }
        print(sys.log_warning ++ "dazzle: wifi: could not join \"{s}\": not_found\n", .{j.ssid()});
        m.report.connection.state = .failed;
        m.report.connection.failure = .not_found;
        j.retry_at = now + retry_ns;
    }

    /// Asks the driver to connect (again), with the handshake ready.
    fn startJoin(m: *Manager, now: u64) !void {
        const j = &m.join.?;
        const st = m.station.?;
        j.started_ns = now;
        j.retry_at = null;
        j.pending_eapol_len = 0;
        j.sae = null;
        j.sae_committed = false;
        j.sae_confirmed = false;
        var params: nl80211.ConnectParams = .{ .ssid = j.ssid(), .bssid = j.bss.bssid, .freq_mhz = j.bss.network.freq_mhz };
        if (j.pmk) |pmk| {
            const is_sae = j.akm == supplicant.akm_sae;
            const mfp_capable = is_sae or j.bss.mfp_capable or j.bss.mfp_required;
            const mfp_required = is_sae or j.bss.mfp_required;
            const rsn = supplicant.rsnElementEx(&j.rsn_buf, j.bss.group_cipher, j.akm, mfp_capable, mfp_required, null);
            j.handshake = .{
                .pmk = pmk,
                .aa = j.bss.bssid,
                .spa = st.adapter.mac,
                .own_rsn = rsn,
                .ap_rsn = j.bss.rsn(),
                .group_cipher = j.bss.group_cipher,
                .akm = j.akm,
            };
            // Listening before connecting, so message 1 is not missed.
            if (j.eapol == null) j.eapol = try openEapol(st.index);
            params.wpa2 = .{
                .rsn = rsn,
                .group_cipher = j.bss.group_cipher,
                .akm = j.akm,
                .mfp_required = mfp_required,
            };
        }
        if (!m.station.?.adapter.up) m.station.?.adapter.up = ipv4.bringUp(st.adapter.name());
        print("dazzle: wifi: joining \"{s}\" ({x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}, {d} MHz)\n", .{ j.ssid(), j.bss.bssid[0], j.bss.bssid[1], j.bss.bssid[2], j.bss.bssid[3], j.bss.bssid[4], j.bss.bssid[5], j.bss.network.freq_mhz });
        try m.nl.?.connect(st.index, params);
        m.setState(.connecting);
    }

    /// Leaves the network: DHCP stopped, the address removed, the driver
    /// disconnected. Forgets it if `forget`.
    fn leave(m: *Manager, forget: bool) void {
        const j = &(m.join orelse return);
        m.stopDhcp();
        if (j.eapol) |fd| sys.close(fd);
        j.eapol = null;
        if (m.station) |st| {
            m.nl.?.disconnect(st.index) catch {};
            ipv4.removeAddress(st.adapter.name());
        }
        if (forget) {
            m.join = null;
            m.report.connection = .{ .addressing = m.addressing };
        }
    }

    fn stopDhcp(m: *Manager) void {
        const j = &(m.join orelse return);
        const pid = j.dhcp_pid orelse return;
        _ = linux.kill(pid, .TERM);
        var status: u32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
        j.dhcp_pid = null;
    }

    /// The handshake is done (or the network is open): get an address.
    fn startDhcp(m: *Manager) void {
        const j = &m.join.?;
        const name = m.station.?.adapter.name();
        switch (m.addressing) {
            .static => |st| {
                ipv4.setStatic(name, st.address, st.prefix, st.gateway) catch |err| {
                    print(sys.log_warning ++ "dazzle: wifi: cannot set {s}'s static address ({s})\n", .{ name, @errorName(err) });
                    return m.fail(.rejected);
                };
                m.report.connection.address = st.address;
                m.report.connection.prefix = st.prefix;
                m.setState(.connected);
            },
            .dhcp => {
                m.setState(.addressing);
                const rc = linux.fork();
                if (linux.errno(rc) != .SUCCESS) return m.fail(.rejected);
                if (rc == 0) ipv4.runDhcp(name);
                j.dhcp_pid = @intCast(rc);
            },
        }
    }

    /// Handles an incoming 802.11 SAE Authentication frame during external
    /// authentication.
    fn handleSaeFrame(m: *Manager, rx: *const nl80211.RxFrame) void {
        const nl = &(m.nl orelse return);
        const st = m.station orelse return;
        const j = &(m.join orelse return);
        const sae = &(j.sae orelse return);
        const frame = rx.bytes();
        if (frame.len < 30 or frame[0] != 0xb0) return;
        const alg = std.mem.readInt(u16, frame[24..26], .little);
        if (alg != supplicant.auth_alg_sae) return;
        const seq = std.mem.readInt(u16, frame[26..28], .little);
        const status = std.mem.readInt(u16, frame[28..30], .little);
        const body = frame[30..];
        const freq = if (rx.freq_mhz != 0) rx.freq_mhz else j.bss.network.freq_mhz;

        switch (seq) {
            1 => {
                if (status == supplicant.status_anti_clogging_token_req and body.len >= 2) {
                    const token = body[2..];
                    var commit_body: [256]u8 = undefined;
                    var tx_frame: [300]u8 = undefined;
                    const cb = sae.writeCommit(&commit_body, token);
                    const tx = supplicant.Sae.buildAuthFrame(&tx_frame, st.adapter.mac, j.bss.bssid, 1, supplicant.status_success, cb);
                    nl.sendFrame(st.index, freq, tx) catch {};
                    return;
                }
                if (status != supplicant.status_success or !sae.processCommit(body)) {
                    nl.externalAuthStatus(st.index, j.ssid(), j.bss.bssid, 1, null);
                    return m.fail(.rejected);
                }
                j.sae_committed = true;
                var confirm_body: [supplicant.Sae.confirm_len]u8 = undefined;
                var tx_frame: [64]u8 = undefined;
                const cb = sae.writeConfirm(&confirm_body);
                const tx = supplicant.Sae.buildAuthFrame(&tx_frame, st.adapter.mac, j.bss.bssid, 2, supplicant.status_success, cb);
                nl.sendFrame(st.index, freq, tx) catch {
                    nl.externalAuthStatus(st.index, j.ssid(), j.bss.bssid, 1, null);
                    return m.fail(.rejected);
                };
            },
            2 => {
                if (status != supplicant.status_success or !j.sae_committed or !sae.processConfirm(body)) {
                    nl.externalAuthStatus(st.index, j.ssid(), j.bss.bssid, 1, null);
                    return m.fail(.wrong_password);
                }
                j.sae_confirmed = true;
                j.pmk = sae.pmk;
                j.handshake.pmk = sae.pmk;
                j.handshake.ptk = null;
                nl.externalAuthStatus(st.index, j.ssid(), j.bss.bssid, 0, sae.pmkid);
            },
            else => {},
        }
    }

    /// Handles nl80211's events.
    pub fn events(m: *Manager, now: u64) void {
        const nl = &(m.nl orelse return);
        const st = m.station orelse return;
        const ev = nl.readEvents();
        if (ev.scan_aborted) m.scan_started_ns = null;
        if (ev.scan_done) {
            m.scan_started_ns = null;
            m.scanned_ns = now;
            var fresh: wifi.Report = .{};
            if (nl.scanResults(st.index, &fresh)) {
                m.report.networks = fresh.networks;
                m.report.len = fresh.len;
            } else |err| print(sys.log_warning ++ "dazzle: wifi: cannot read the scan ({s})\n", .{@errorName(err)});
            if (m.join) |*j| if (!j.has_bss) {
                m.tryStartPendingJoin(now);
            };
        } else if (m.scan_started_ns) |t| if (now -| t > scan_timeout_ns) {
            m.scan_started_ns = null;
        };

        if (m.hotspot) |*h| {
            if (ev.new_station) |mac| {
                if (h.pmk == null) {
                    nl.authorize(st.index, mac);
                    m.authorizeHotspotClient(mac);
                } else if (h.eapol) |fd| {
                    if (h.stationFor(mac, st.adapter.mac)) |s| {
                        const m1 = s.auth.start(random);
                        sendEapol(fd, st.index, mac, m1);
                    }
                }
            }
            if (ev.del_station) |mac| {
                h.removeStation(mac);
                m.report.hotspot.removeClient(mac);
            }
            return;
        }

        const j = &(m.join orelse return);
        const state = m.report.connection.state;
        if (ev.external_auth) |ext| if (state == .connecting and j.akm == supplicant.akm_sae) {
            if (!ext.start) {
                j.sae = null;
            } else {
                if (!std.mem.allEqual(u8, &ext.bssid, 0) and !std.mem.eql(u8, &j.bss.bssid, &ext.bssid)) {
                    if (nl.findBssByBssid(st.index, j.ssid(), ext.bssid) catch null) |actual| {
                        j.bss = actual;
                    } else {
                        j.bss.bssid = ext.bssid;
                    }
                    j.handshake.setAp(j.bss.bssid, j.bss.rsn());
                }
                j.sae = supplicant.Sae.init(j.passphrase(), st.adapter.mac, j.bss.bssid, random);
                j.sae_committed = false;
                j.sae_confirmed = false;
                var commit_body: [128]u8 = undefined;
                var tx_frame: [160]u8 = undefined;
                const cb = j.sae.?.writeCommit(&commit_body, &.{});
                const tx = supplicant.Sae.buildAuthFrame(&tx_frame, st.adapter.mac, j.bss.bssid, 1, supplicant.status_success, cb);
                nl.sendFrame(st.index, j.bss.network.freq_mhz, tx) catch |err| {
                    print(sys.log_warning ++ "dazzle: wifi: cannot send SAE Commit ({s})\n", .{@errorName(err)});
                    nl.externalAuthStatus(st.index, j.ssid(), j.bss.bssid, 1, null);
                    return m.fail(.rejected);
                };
            }
        };
        for (ev.auth_frames[0..ev.auth_frames_len]) |*rx| {
            if (m.join == null) return;
            m.handleSaeFrame(rx);
        }
        if (m.join == null) return;
        if (ev.connected) |c| if (state == .connecting) {
            if (c.status != 0) {
                const wrong_sae = j.akm == supplicant.akm_sae and j.sae_committed and !j.sae_confirmed;
                return m.fail(if (wrong_sae) .wrong_password else .rejected);
            }
            if (!std.mem.allEqual(u8, &c.bssid, 0)) {
                if (!std.mem.eql(u8, &j.bss.bssid, &c.bssid)) {
                    if (nl.findBssByBssid(st.index, j.ssid(), c.bssid) catch null) |actual| {
                        j.bss = actual;
                    } else {
                        j.bss.bssid = c.bssid;
                    }
                }
                j.handshake.setAp(j.bss.bssid, j.bss.rsn());
            }
            if (j.pmk == null) {
                m.startDhcp();
            } else {
                m.setState(.authenticating);
                if (j.pending_eapol_len > 0) {
                    const len = j.pending_eapol_len;
                    const src = j.pending_eapol_src;
                    j.pending_eapol_len = 0;
                    var frame: [512]u8 = undefined;
                    @memcpy(frame[0..len], j.pending_eapol_buf[0..len]);
                    m.handleEapolFrame(frame[0..len], src);
                    if (m.join == null) return;
                }
            }
        };
        if (ev.disconnected) |reason| switch (state) {
            // A failed association comes as a connect result; a
            // disconnection now is the end of the previous connection.
            .connecting => {},
            .authenticating => {
                // A disconnection after message 1 came (and 3 did not)
                // means the access point did not accept message 2's MIC.
                const wrong = state == .authenticating and j.handshake.message1_count > 0 and !j.handshake.complete;
                print("dazzle: wifi: disconnected (reason {d})\n", .{reason});
                m.fail(if (wrong) .wrong_password else .rejected);
            },
            .addressing, .connected => {
                print("dazzle: wifi: connection to \"{s}\" lost (reason {d}); trying again\n", .{ j.ssid(), reason });
                m.leave(false);
                m.report.connection.state = .failed;
                m.report.connection.failure = .lost;
                m.report.connection.address = null;
                j.retry_at = now + retry_ns;
            },
            else => {},
        };
    }

    /// Handles EAPOL frames for the supplicant or hotspot authenticator.
    pub fn eapol(m: *Manager) void {
        if (m.hotspot) |*h| {
            const fd = h.eapol orelse return;
            const st = m.station orelse return;
            var buf: [2048]u8 = undefined;
            while (true) {
                var from: SockaddrLl = undefined;
                var from_len: linux.socklen_t = @sizeOf(SockaddrLl);
                const n = linux.recvfrom(fd, &buf, buf.len, linux.MSG.DONTWAIT, @ptrCast(&from), &from_len);
                if (linux.errno(n) != .SUCCESS or n == 0) return;
                const sta_mac: [6]u8 = from.addr[0..6].*;
                const s = h.stationFor(sta_mac, st.adapter.mac) orelse continue;
                var actions: supplicant.Actions = .{};
                s.auth.handle(buf[0..n], &actions);
                if (actions.reply) |reply| sendEapol(fd, st.index, sta_mac, reply);
                if (actions.pairwise) |tk| {
                    m.nl.?.setPairwiseKey(st.index, sta_mac, tk) catch |err| {
                        print(sys.log_warning ++ "dazzle: wifi: cannot install station pairwise key ({s})\n", .{@errorName(err)});
                        continue;
                    };
                    m.nl.?.authorize(st.index, sta_mac);
                    m.authorizeHotspotClient(sta_mac);
                }
            }
        }
        var buf: [2048]u8 = undefined;
        while (true) {
            const j = &(m.join orelse return);
            const fd = j.eapol orelse return;
            var from: SockaddrLl = undefined;
            var from_len: linux.socklen_t = @sizeOf(SockaddrLl);
            const n = linux.recvfrom(fd, &buf, buf.len, linux.MSG.DONTWAIT, @ptrCast(&from), &from_len);
            if (linux.errno(n) != .SUCCESS or n == 0) return;
            const src_mac: [6]u8 = from.addr[0..6].*;
            const state = m.report.connection.state;
            // Message 1 may arrive from the radio before the driver has
            // finished its post-association setup and sent `connected`;
            // hold it until `events` sees `connected`.
            if (state == .connecting) {
                if (n <= j.pending_eapol_buf.len) {
                    @memcpy(j.pending_eapol_buf[0..n], buf[0..n]);
                    j.pending_eapol_len = @intCast(n);
                    j.pending_eapol_src = src_mac;
                }
                continue;
            }
            if (state != .authenticating and !j.handshake.complete) continue;
            m.handleEapolFrame(buf[0..n], src_mac);
        }
    }

    fn handleEapolFrame(m: *Manager, frame: []const u8, src_mac: [6]u8) void {
        const j = &(m.join orelse return);
        const fd = j.eapol orelse return;
        const st = m.station orelse return;
        if (!std.mem.allEqual(u8, &src_mac, 0) and !std.mem.eql(u8, &j.bss.bssid, &src_mac)) {
            j.bss.bssid = src_mac;
            j.handshake.setAp(src_mac, j.bss.rsn());
        }
        var actions: supplicant.Actions = .{};
        j.handshake.handle(frame, random, &actions);
        if (actions.reply) |reply| sendEapol(fd, st.index, j.bss.bssid, reply);
        if (actions.pairwise) |tk| m.nl.?.setPairwiseKey(st.index, j.bss.bssid, tk) catch |err| {
            print(sys.log_warning ++ "dazzle: wifi: cannot install the pairwise key ({s})\n", .{@errorName(err)});
            return m.fail(.rejected);
        };
        if (actions.group) |g| m.nl.?.setGroupKey(st.index, j.bss.group_cipher, g.index, g.key[0..g.len], g.rsc) catch |err| {
            print(sys.log_warning ++ "dazzle: wifi: cannot install the group key ({s})\n", .{@errorName(err)});
        };
        if (actions.igtk) |igtk| m.nl.?.setManagementGroupKey(st.index, igtk.index, igtk.key, igtk.ipn);
        if (actions.complete and !m.report.connection.state.joined()) {
            const proto = if (j.akm == supplicant.akm_sae) "WPA3" else "WPA2";
            print("dazzle: wifi: joined \"{s}\" ({s})\n", .{ j.ssid(), proto });
            m.nl.?.authorize(st.index, j.bss.bssid);
            m.startDhcp();
        }
    }

    fn authorizeHotspotClient(m: *Manager, mac: [6]u8) void {
        var cl: wifi.HotspotClient = .{ .mac = mac };
        if (m.hotspot) |*h| if (h.pool.clientInfo(mac)) |info| {
            cl.address = info.ip;
            cl.setName(info.hostname);
        };
        m.report.hotspot.addClient(cl);
    }

    /// Handles DHCP requests from hotspot clients.
    pub fn dhcp(m: *Manager) void {
        const h = &(m.hotspot orelse return);
        const fd = h.dhcp_fd orelse return;
        if (h.pool.share_internet) h.pool.dns = readResolvConfDns() orelse h.pool.dns;
        while (ipv4.stepDhcpServer(fd, &h.pool)) |mac| {
            if (h.pool.clientInfo(mac)) |info| {
                var cl: wifi.HotspotClient = .{ .mac = mac, .address = info.ip };
                cl.setName(info.hostname);
                m.report.hotspot.addClient(cl);
            }
        }
    }

    /// Timeouts, retries and noticing the address DHCP got.
    pub fn tick(m: *Manager, now: u64) void {
        const j = &(m.join orelse return);
        switch (m.report.connection.state) {
            .connecting, .authenticating => if (now -| j.started_ns > connect_timeout_ns) {
                if (!j.has_bss) {
                    m.report.connection.state = .failed;
                    m.report.connection.failure = .not_found;
                    j.retry_at = now + retry_ns;
                } else {
                    const wrong_eapol = j.pmk != null and j.handshake.message1_count > 1 and !j.handshake.complete;
                    const wrong_sae = j.akm == supplicant.akm_sae and j.sae_committed and !j.sae_confirmed;
                    m.fail(if (wrong_eapol or wrong_sae) .wrong_password else .timeout);
                }
            },
            .addressing, .connected => {
                const addr = ipv4.interfaceAddress(m.station.?.adapter.name());
                if (addr) |a| {
                    if (m.report.connection.state == .addressing) print("dazzle: wifi: \"{s}\" gave {d}.{d}.{d}.{d}\n", .{ j.ssid(), a[0], a[1], a[2], a[3] });
                    m.setState(.connected);
                    m.report.connection.prefix = ipv4.interfacePrefix(m.station.?.adapter.name());
                }
                m.report.connection.address = addr;
            },
            .failed => if (j.retry_at) |t| if (now >= t) {
                if (j.has_bss) {
                    m.startJoin(now) catch {
                        j.retry_at = now + retry_ns;
                    };
                } else {
                    m.scanned_ns = 0;
                    j.started_ns = now;
                    j.retry_at = null;
                    m.tryStartPendingJoin(now);
                }
            },
            .idle => {},
        }
    }
};

fn random(buf: []u8) void {
    var at: usize = 0;
    while (at < buf.len) {
        const rc = linux.getrandom(buf[at..].ptr, buf.len - at, 0);
        if (linux.errno(rc) == .SUCCESS) at += rc;
    }
}

/// struct sockaddr_ll.
const SockaddrLl = extern struct {
    family: u16 = linux.AF.PACKET,
    protocol: u16 = std.mem.nativeToBig(u16, eth_p_pae),
    ifindex: i32,
    hatype: u16 = 0,
    pkttype: u8 = 0,
    halen: u8 = 0,
    addr: [8]u8 = @splat(0),
};

/// A packet socket for EAPOL frames on the interface.
fn openEapol(ifindex: u32) !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.PACKET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, std.mem.nativeToBig(u16, eth_p_pae))));
    errdefer sys.close(fd);
    const addr: SockaddrLl = .{ .ifindex = @intCast(ifindex) };
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrLl)));
    return fd;
}

fn sendEapol(fd: linux.fd_t, ifindex: u32, to: [6]u8, frame: []const u8) void {
    var addr: SockaddrLl = .{ .ifindex = @intCast(ifindex), .halen = 6 };
    @memcpy(addr.addr[0..6], &to);
    _ = linux.sendto(fd, frame.ptr, frame.len, 0, @ptrCast(&addr), @sizeOf(SockaddrLl));
}

fn setIpForward(enable: bool) void {
    const fd = sys.open("/proc/sys/net/ipv4/ip_forward", .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }) catch return;
    defer sys.close(fd);
    const val = if (enable) "1\n" else "0\n";
    _ = linux.write(fd, val.ptr, val.len);
}

fn readResolvConfDns() ?wifi.Ip4 {
    var buf: [256]u8 = undefined;
    const text = sys.readFile("/etc/resolv.conf", &buf) orelse return null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        if (std.mem.eql(u8, words.next() orelse continue, "nameserver")) {
            if (words.next()) |ip_str| if (wifi.parseIp4(ip_str)) |ip| return ip;
        }
    }
    return null;
}

const testing = std.testing;

test "Manager.loadConfig restores Wi-Fi client and hotspot settings at startup" {
    var req_buf: [256]u8 = undefined;
    var cfg: wifi.Config = .{};
    const st = wifi.Static.parse("192.168.1.99/24", "192.168.1.1").?;
    _ = cfg.apply(wifi.Request.parse(wifi.wifiAddressRequest(&req_buf, "wlan0", .{ .static = st })).?);
    _ = cfg.apply(wifi.Request.parse(wifi.connectAdapterRequest(&req_buf, "wlan0", "HomeNet", "secret123")).?);

    var m: Manager = .{};
    m.loadConfig(&cfg, 1000);
    try testing.expectEqual(st, m.addressing.static);
    try testing.expectEqualStrings("wlan0", m.preferredAdapter());
    try testing.expect(m.join != null);
    try testing.expect(!m.join.?.has_bss);
    try testing.expectEqualStrings("HomeNet", m.join.?.ssid());
    try testing.expectEqualStrings("secret123", m.join.?.passphrase());
    try testing.expectEqual(wifi.ConnectionState.connecting, m.report.connection.state);

    var cfg_hs: wifi.Config = .{};
    _ = cfg_hs.apply(wifi.Request.parse(wifi.hotspotFullRequest(&req_buf, "wlan0", "DazzleAP", "hunter22", .{}, "eth0")).?);
    var m_hs: Manager = .{};
    m_hs.loadConfig(&cfg_hs, 1000);
    try testing.expect(m_hs.pending_hotspot != null);
    try testing.expectEqualStrings("DazzleAP", m_hs.pending_hotspot.?.ssid());
    try testing.expectEqualStrings("eth0", m_hs.pending_hotspot.?.upstream());
}

