//! The Wi-Fi manager: finds the Wi-Fi adapter, brings it up, scans for
//! networks when asked, and tells the settings app what it found.
//!
//! Init forks it once the user's runtime directory exists. It runs as the
//! Stardust user, keeping only CAP_NET_ADMIN (nl80211 needs it to start a
//! scan, and bringing an interface up needs it too). It listens on
//! $XDG_RUNTIME_DIR/stardust-wifi (see `sys.wifi` for the protocol) and
//! answers only the settings app: the program the connecting process runs
//! must be /apps/stardust-settings/stardust-settings. Every app runs as the
//! same user, so the socket's permissions alone could not tell them apart.
//!
//! A request answers at once with what the last scan found, and starts a
//! new scan if that one is older than `rescan_ns` (the settings app asks
//! every few seconds while it is open, so nothing scans while it is not).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const nl80211 = @import("nl80211.zig");

const wifi = sys.wifi;
const print = sys.print;

/// How old a scan may be before a request starts another.
const rescan_ns = 10 * std.time.ns_per_s;
/// A scan that has not finished by then is given up.
const scan_timeout_ns = 15 * std.time.ns_per_s;
/// How often to look for an adapter (one can be slow to appear: its
/// firmware loads after boot).
const look_ns = 2 * std.time.ns_per_s;
const max_clients = 4;

pub fn start(runtime_dir: []const u8) ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print("stardust: wifi: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    sys.dropPrivilegesKeeping(&.{.net_admin}) catch |err| {
        print("stardust: wifi: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    run(runtime_dir) catch |err| print("stardust: wifi: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

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

    /// Answers a request: what is known now, starting a scan if it is old.
    fn request(m: *Manager, now: u64) void {
        if (m.station) |st| {
            if (m.scan_started_ns == null and (m.scanned_ns == 0 or now -| m.scanned_ns >= rescan_ns)) {
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
        }
        m.report.adapter = if (m.station) |st| st.adapter else null;
        m.report.scanning = m.scan_started_ns != null;
    }

    /// Handles scan events, and gives up a scan that took too long.
    fn events(m: *Manager, now: u64) void {
        const nl = &(m.nl orelse return);
        const st = m.station orelse return;
        switch (nl.readEvents()) {
            .none => if (m.scan_started_ns) |t| if (now -| t > scan_timeout_ns) {
                m.scan_started_ns = null;
            },
            .scan_aborted => m.scan_started_ns = null,
            .scan_done => {
                m.scan_started_ns = null;
                m.scanned_ns = now;
                var fresh: wifi.Report = .{};
                nl.scanResults(st.index, &fresh) catch |err| {
                    print("stardust: wifi: cannot read the scan ({s})\n", .{@errorName(err)});
                    return;
                };
                m.report.networks = fresh.networks;
                m.report.len = fresh.len;
            },
        }
    }
};

fn run(runtime_dir: []const u8) !void {
    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ runtime_dir, wifi.socket_name });
    const listener = try listen(path);
    var m: Manager = .{};
    var clients: [max_clients]?linux.fd_t = @splat(null);
    while (true) {
        const now = sys.nowNs();
        m.look(now);

        var fds: [2 + max_clients]linux.pollfd = undefined;
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = if (m.nl) |nl| nl.events.fd else -1, .events = linux.POLL.IN, .revents = 0 };
        for (clients, fds[2..]) |c, *f| f.* = .{ .fd = c orelse -1, .events = linux.POLL.IN, .revents = 0 };
        _ = linux.poll(&fds, fds.len, 1000);
        const t = sys.nowNs();

        m.events(t);
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
        for (&clients, fds[2..]) |*c, f| {
            const fd = c.* orelse continue;
            if (f.revents == 0) continue;
            var buf: [64]u8 = undefined;
            const n = linux.read(fd, &buf, buf.len);
            if (linux.errno(n) == .SUCCESS and n > 0 and std.mem.startsWith(u8, buf[0..n], "scan")) {
                m.request(t);
                var out: [4096]u8 = undefined;
                const text = m.report.write(&out);
                _ = linux.write(fd, text.ptr, text.len);
            }
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
