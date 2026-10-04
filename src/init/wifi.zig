//! The Wi-Fi manager: finds the Wi-Fi adapter, brings it up, scans for
//! networks, joins the one the settings app asks for (open, or WPA2 with
//! the supplicant in supplicant.zig), and gets an address for it by DHCP.
//!
//! Init forks it once the user's runtime directory exists. It runs as the
//! Stardust user, keeping only the network capabilities it needs:
//! CAP_NET_ADMIN (nl80211 needs it to scan, connect and install keys, and
//! configuring the interface does too), CAP_NET_RAW (the supplicant's
//! EAPOL frames go through a packet socket, and DHCP binds to the
//! interface) and CAP_NET_BIND_SERVICE (the DHCP client port). It listens
//! on $XDG_RUNTIME_DIR/stardust-wifi (see `sys.wifi` for the protocol) and
//! answers only the settings app: the program the connecting process runs
//! must be /apps/stardust-settings/stardust-settings. Every app runs as the
//! same user, so the socket's permissions alone could not tell them apart.
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
const network = @import("network.zig");

const wifi = sys.wifi;
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
const max_clients = 4;

const eth_p_pae: u16 = 0x888e;

pub fn start(runtime_dir: []const u8) ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print("stardust: wifi: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    sys.dropPrivilegesKeeping(&.{ .net_admin, .net_raw, .net_bind_service }) catch |err| {
        print("stardust: wifi: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    run(runtime_dir) catch |err| print("stardust: wifi: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

/// Joining a network, and staying joined.
const Join = struct {
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,
    /// The PMK; null for an open network.
    pmk: ?[32]u8 = null,
    bss: nl80211.Bss = undefined,
    rsn_buf: [22]u8 = undefined,
    handshake: supplicant.Handshake = undefined,
    eapol: ?linux.fd_t = null,
    started_ns: u64 = 0,
    dhcp_pid: ?linux.pid_t = null,
    /// When to try again after losing the connection.
    retry_at: ?u64 = null,

    fn ssid(j: *const Join) []const u8 {
        return j.ssid_buf[0..j.ssid_len];
    }
};

const Manager = struct {
    nl: ?nl80211.Nl80211 = null,
    station: ?nl80211.Interface = null,
    report: wifi.Report = .{},
    /// When the last scan finished, and when the one under way started.
    scanned_ns: u64 = 0,
    scan_started_ns: ?u64 = null,
    looked_ns: u64 = 0,
    /// Logged once each.
    said_no_wifi: bool = false,
    /// The network being joined (or joined), if any.
    join: ?Join = null,

    /// Looks for the adapter (and nl80211 itself) if it is not known yet.
    fn look(m: *Manager, now: u64) void {
        if (m.station != null or now -| m.looked_ns < look_ns) return;
        m.looked_ns = now;
        if (m.nl == null) {
            m.nl = nl80211.Nl80211.open() catch |err| {
                if (!m.said_no_wifi) print("stardust: wifi: no nl80211 ({s}): this kernel has no Wi-Fi\n", .{@errorName(err)});
                m.said_no_wifi = true;
                return;
            };
        }
        const station = (m.nl.?.findStation() catch return) orelse return;
        print("stardust: wifi: found {s}\n", .{station.adapter.name()});
        m.station = station;
        m.station.?.adapter.up = bringUp(station.adapter.name());
    }

    fn handle(m: *Manager, req: wifi.Request, now: u64) void {
        switch (req) {
            .scan => m.scan(now),
            .disconnect => m.leave(true),
            .connect => |c| m.connect(c.ssid_buf[0..c.ssid_len], c.pass_buf[0..c.pass_len], now),
        }
        m.report.adapter = if (m.station) |st| st.adapter else null;
        m.report.scanning = m.scan_started_ns != null;
    }

    /// Starts a scan if the last is old.
    fn scan(m: *Manager, now: u64) void {
        const st = m.station orelse return;
        // Not while joining: scanning takes the radio off the channel.
        switch (m.report.connection.state) {
            .connecting, .authenticating, .addressing => return,
            else => {},
        }
        if (m.scan_started_ns != null or (m.scanned_ns != 0 and now -| m.scanned_ns < rescan_ns)) return;
        if (m.nl.?.triggerScan(st.index)) {
            m.scan_started_ns = now;
        } else |err| switch (err) {
            // Another scan is under way (the kernel's own).
            error.Busy => m.scan_started_ns = now,
            else => {
                print("stardust: wifi: cannot scan ({s})\n", .{@errorName(err)});
                // Down, perhaps: up again, and try at the next request.
                m.station.?.adapter.up = bringUp(st.adapter.name());
            },
        }
    }

    fn fail(m: *Manager, why: wifi.Failure) void {
        print("stardust: wifi: could not join \"{s}\": {s}\n", .{ m.report.connection.ssid(), @tagName(why) });
        m.leave(false);
        m.report.connection.state = .failed;
        m.report.connection.failure = why;
    }

    fn setState(m: *Manager, state: wifi.ConnectionState) void {
        m.report.connection.state = state;
        m.report.connection.failure = .none;
    }

    /// Starts joining a network.
    fn connect(m: *Manager, ssid: []const u8, passphrase: []const u8, now: u64) void {
        m.leave(true);
        m.report.connection = .{};
        m.report.connection.setSsid(ssid);
        const st = m.station orelse return m.fail(.not_found);
        const bss = (m.nl.?.findBss(st.index, ssid) catch null) orelse return m.fail(.not_found);
        var j: Join = .{ .bss = bss, .started_ns = now };
        @memcpy(j.ssid_buf[0..ssid.len], ssid);
        j.ssid_len = @intCast(ssid.len);
        const wpa2 = bss.rsn_len > 0;
        if (wpa2) {
            if (!bss.ccmp or !bss.psk or (bss.group_cipher != supplicant.cipher_ccmp and bss.group_cipher != supplicant.cipher_tkip)) return m.fail(.unsupported);
            if (!supplicant.validPassphrase(passphrase)) return m.fail(.bad_passphrase);
            j.pmk = supplicant.pmkFromPassphrase(passphrase, ssid);
        } else if (bss.network.security != .open) return m.fail(.unsupported);
        m.join = j;
        m.startJoin(now) catch |err| {
            print("stardust: wifi: cannot connect ({s})\n", .{@errorName(err)});
            m.fail(.rejected);
        };
    }

    /// Asks the driver to connect (again), with the handshake ready.
    fn startJoin(m: *Manager, now: u64) !void {
        const j = &m.join.?;
        const st = m.station.?;
        j.started_ns = now;
        j.retry_at = null;
        var params: nl80211.ConnectParams = .{ .ssid = j.ssid(), .bssid = j.bss.bssid, .freq_mhz = j.bss.network.freq_mhz };
        if (j.pmk) |pmk| {
            const rsn = supplicant.rsnElement(&j.rsn_buf, j.bss.group_cipher);
            j.handshake = .{ .pmk = pmk, .aa = j.bss.bssid, .spa = st.adapter.mac, .own_rsn = rsn, .ap_rsn = j.bss.rsn(), .group_cipher = j.bss.group_cipher };
            // Listening before connecting, so message 1 is not missed.
            if (j.eapol == null) j.eapol = try openEapol(st.index);
            params.wpa2 = .{ .rsn = rsn, .group_cipher = j.bss.group_cipher };
        }
        if (!m.station.?.adapter.up) m.station.?.adapter.up = bringUp(st.adapter.name());
        print("stardust: wifi: joining \"{s}\" ({x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}, {d} MHz)\n", .{ j.ssid(), j.bss.bssid[0], j.bss.bssid[1], j.bss.bssid[2], j.bss.bssid[3], j.bss.bssid[4], j.bss.bssid[5], j.bss.network.freq_mhz });
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
            network.removeAddress(st.adapter.name());
        }
        if (forget) {
            m.join = null;
            m.report.connection = .{};
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
        m.setState(.addressing);
        const name = m.station.?.adapter.name();
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) return m.fail(.rejected);
        if (rc == 0) network.runDhcp(name);
        j.dhcp_pid = @intCast(rc);
    }

    /// Handles nl80211's events.
    fn events(m: *Manager, now: u64) void {
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
            } else |err| print("stardust: wifi: cannot read the scan ({s})\n", .{@errorName(err)});
        } else if (m.scan_started_ns) |t| if (now -| t > scan_timeout_ns) {
            m.scan_started_ns = null;
        };

        const j = &(m.join orelse return);
        const state = m.report.connection.state;
        if (ev.connected) |c| if (state == .connecting) {
            if (c.status != 0) return m.fail(.rejected);
            if (!std.mem.allEqual(u8, &c.bssid, 0)) {
                j.bss.bssid = c.bssid;
                j.handshake.aa = c.bssid;
            }
            if (j.pmk == null) m.startDhcp() else m.setState(.authenticating);
        };
        if (ev.disconnected) |reason| switch (state) {
            // A failed association comes as a connect result; a
            // disconnection now is the end of the previous connection.
            .connecting => {},
            .authenticating => {
                // A disconnection after message 1 came (and 3 did not)
                // means the access point did not accept message 2's MIC.
                const wrong = state == .authenticating and j.handshake.message1_count > 0 and !j.handshake.complete;
                print("stardust: wifi: disconnected (reason {d})\n", .{reason});
                m.fail(if (wrong) .wrong_password else .rejected);
            },
            .addressing, .connected => {
                print("stardust: wifi: connection to \"{s}\" lost (reason {d}); trying again\n", .{ j.ssid(), reason });
                m.leave(false);
                m.report.connection.state = .failed;
                m.report.connection.failure = .lost;
                m.report.connection.address = null;
                j.retry_at = now + retry_ns;
            },
            else => {},
        };
    }

    /// Handles EAPOL frames for the supplicant.
    fn eapol(m: *Manager) void {
        const j = &(m.join orelse return);
        const fd = j.eapol orelse return;
        var buf: [2048]u8 = undefined;
        while (true) {
            const n = linux.recvfrom(fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
            if (linux.errno(n) != .SUCCESS or n == 0) return;
            // Message 1 may come before the connection event is read.
            const state = m.report.connection.state;
            if (state != .connecting and state != .authenticating and !j.handshake.complete) continue;
            var actions: supplicant.Actions = .{};
            j.handshake.handle(buf[0..n], random, &actions);
            const st = m.station.?;
            if (actions.reply) |reply| sendEapol(fd, st.index, j.bss.bssid, reply);
            if (actions.pairwise) |tk| m.nl.?.setPairwiseKey(st.index, j.bss.bssid, tk) catch |err| {
                print("stardust: wifi: cannot install the pairwise key ({s})\n", .{@errorName(err)});
                return m.fail(.rejected);
            };
            if (actions.group) |g| m.nl.?.setGroupKey(st.index, j.bss.group_cipher, g.index, g.key[0..g.len], g.rsc) catch |err| {
                print("stardust: wifi: cannot install the group key ({s})\n", .{@errorName(err)});
            };
            if (actions.complete and !m.report.connection.state.joined()) {
                print("stardust: wifi: joined \"{s}\" (WPA2)\n", .{j.ssid()});
                m.nl.?.authorize(st.index, j.bss.bssid);
                m.startDhcp();
            }
        }
    }

    /// Timeouts, retries and noticing the address DHCP got.
    fn tick(m: *Manager, now: u64) void {
        const j = &(m.join orelse return);
        switch (m.report.connection.state) {
            .connecting, .authenticating => if (now -| j.started_ns > connect_timeout_ns) {
                const wrong = j.pmk != null and j.handshake.message1_count > 1 and !j.handshake.complete;
                m.fail(if (wrong) .wrong_password else .timeout);
            },
            .addressing, .connected => {
                const addr = interfaceAddress(m.station.?.adapter.name());
                if (addr) |a| {
                    if (m.report.connection.state == .addressing) print("stardust: wifi: \"{s}\" gave {d}.{d}.{d}.{d}\n", .{ j.ssid(), a[0], a[1], a[2], a[3] });
                    m.setState(.connected);
                }
                m.report.connection.address = addr;
            },
            .failed => if (j.retry_at) |t| if (now >= t) {
                m.startJoin(now) catch {
                    j.retry_at = now + retry_ns;
                };
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

/// The interface's IPv4 address, if it has one.
fn interfaceAddress(name: []const u8) ?[4]u8 {
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

fn run(runtime_dir: []const u8) !void {
    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ runtime_dir, wifi.socket_name });
    const listener = try listen(path);
    var m: Manager = .{};
    var clients: [max_clients]?linux.fd_t = @splat(null);
    while (true) {
        const now = sys.nowNs();
        m.look(now);

        var fds: [3 + max_clients]linux.pollfd = undefined;
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = if (m.nl) |nl| nl.events.fd else -1, .events = linux.POLL.IN, .revents = 0 };
        fds[2] = .{ .fd = if (m.join) |j| j.eapol orelse -1 else -1, .events = linux.POLL.IN, .revents = 0 };
        for (clients, fds[3..]) |c, *f| f.* = .{ .fd = c orelse -1, .events = linux.POLL.IN, .revents = 0 };
        _ = linux.poll(&fds, fds.len, 1000);
        const t = sys.nowNs();

        m.events(t);
        m.eapol();
        m.tick(t);
        if (fds[0].revents != 0) {
            const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) == .SUCCESS) {
                const fd: linux.fd_t = @intCast(rc);
                if (!allowed(fd)) {
                    _ = linux.write(fd, "denied\n", 7);
                    sys.close(fd);
                } else for (&clients) |*c| {
                    if (c.* == null) {
                        c.* = fd;
                        break;
                    }
                } else sys.close(fd);
            }
        }
        for (&clients, fds[3..]) |*c, f| {
            const fd = c.* orelse continue;
            if (f.revents == 0) continue;
            var buf: [256]u8 = undefined;
            const n = linux.read(fd, &buf, buf.len);
            if (linux.errno(n) == .SUCCESS and n > 0) if (wifi.Request.parse(buf[0..n])) |req| {
                m.handle(req, t);
                var out: [4096]u8 = undefined;
                const text = m.report.write(&out);
                _ = linux.write(fd, text.ptr, text.len);
            };
            // One request per connection.
            sys.close(fd);
            c.* = null;
        }
    }
}

/// Whether the process at the other end of `fd` runs the settings app.
fn allowed(fd: linux.fd_t) bool {
    const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len)) != .SUCCESS) return false;
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/exe", .{cred.pid}) catch return false;
    var exe: [256]u8 = undefined;
    const n = sys.check(linux.readlink(path.ptr, &exe, exe.len)) catch return false;
    const ok = isAllowedProgram(exe[0..n]);
    if (!ok) print("stardust: wifi: refused {s} (pid {d})\n", .{ exe[0..n], cred.pid });
    return ok;
}

pub fn isAllowedProgram(exe: []const u8) bool {
    return std.mem.eql(u8, exe, wifi.allowed_program);
}

/// Brings an interface up. Returns whether it is up.
fn bringUp(name: []const u8) bool {
    const sock: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return false);
    defer sys.close(sock);
    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    const n = @min(name.len, req.ifrn.name.len - 1);
    @memcpy(req.ifrn.name[0..n], name[0..n]);
    if (linux.errno(linux.ioctl(sock, linux.SIOCGIFFLAGS, @intFromPtr(&req))) != .SUCCESS) return false;
    if (req.ifru.flags.UP) return true;
    req.ifru.flags.UP = true;
    if (linux.errno(linux.ioctl(sock, linux.SIOCSIFFLAGS, @intFromPtr(&req))) != .SUCCESS) {
        print("stardust: wifi: cannot bring {s} up\n", .{name});
        return false;
    }
    return true;
}

/// The listening socket, replacing a stale one; only the user can connect.
fn listen(path: [:0]const u8) !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    _ = linux.unlink(path);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    _ = linux.fchmodat(linux.AT.FDCWD, path, 0o600);
    _ = try sys.check(linux.listen(fd, 4));
    return fd;
}

test "only the settings app is answered" {
    try std.testing.expect(isAllowedProgram("/apps/stardust-settings/stardust-settings"));
    try std.testing.expect(!isAllowedProgram("/apps/stardust-demo/stardust-demo"));
    try std.testing.expect(!isAllowedProgram("/apps/stardust-settings/stardust-settings (deleted)"));
    try std.testing.expect(!isAllowedProgram("/tmp/stardust-settings"));
}

test "a process running another program is refused" {
    var pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    // The other end is this test program.
    try std.testing.expect(!allowed(pair[0]));
}
