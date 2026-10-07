//! The network manager: the one process that configures the network, wired
//! and Wi-Fi, without holding up boot.
//!
//! Init forks it early. It runs
//! as the Dazzle user and keeps only the capabilities this needs:
//! changing interfaces, routes and Wi-Fi (CAP_NET_ADMIN), packet sockets and
//! tying sockets to an interface (CAP_NET_RAW, for EAPOL and DHCP) and the
//! DHCP client port (CAP_NET_BIND_SERVICE).
//!
//! Ethernet: it looks for a wired adapter (a USB one can be plugged in at
//! any time), brings it up and gives it an address: by DHCP (the client
//! runs in a child process, see `ipv4.runDhcp`, and waits for the link and
//! renews the lease itself), or a static one chosen in the settings app.
//! Wi-Fi: see wifi.zig.
//!
//! It listens on /os/sockets/network (see `sys.network` for the
//! protocol) and answers only the settings app: the program the connecting
//! process runs must be /os/shell/dazzle-settings. Every
//! app runs as the same user, so the socket's permissions alone could not
//! tell them apart. Nothing is remembered across a reboot: the system lives
//! in RAM.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const ipv4 = @import("ipv4.zig");
const wifi = @import("wifi.zig");

const proto = sys.network;
const print = sys.print;

/// How often to look for a wired adapter, and whether it is still there.
const look_ns = 2 * std.time.ns_per_s;
const max_clients = 4;

pub fn start() ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print("dazzle: network: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    // And setting the clock, from the network's time (netconf.zig).
    sys.dropPrivilegesKeeping(&.{ .net_admin, .net_raw, .net_bind_service, .sys_time }) catch |err| {
        print("dazzle: network: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    sys.ignoreBrokenPipes();
    run() catch |err| print("dazzle: network: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

/// The wired adapter, and how it gets its address.
const Ethernet = struct {
    ifc: ?ipv4.Interface = null,
    addressing: proto.Addressing = .dhcp,
    dhcp_pid: ?linux.pid_t = null,
    looked_ns: u64 = 0,
    said_waiting: bool = false,

    /// Finds the adapter, or notices it has gone.
    fn look(e: *Ethernet, now: u64) void {
        if (now -| e.looked_ns < look_ns) return;
        e.looked_ns = now;
        if (e.ifc) |*i| {
            if (i.exists()) return;
            print("dazzle: network: {s} removed\n", .{i.name()});
            e.stopDhcp();
            e.ifc = null;
            return;
        }
        const i = ipv4.findEthernet() orelse {
            if (!e.said_waiting) print("dazzle: network: waiting for an Ethernet adapter\n", .{});
            e.said_waiting = true;
            return;
        };
        e.said_waiting = false;
        print("dazzle: network: found {s} ({x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2})\n", .{
            i.name(), i.mac[0], i.mac[1], i.mac[2], i.mac[3], i.mac[4], i.mac[5],
        });
        e.ifc = i;
        e.apply();
    }

    /// Chooses how the adapter gets its address.
    fn set(e: *Ethernet, a: proto.Addressing) void {
        e.addressing = a;
        if (e.ifc) |*i| {
            // From a static address, or to a new one: the old goes first
            // (DHCP may give another).
            e.stopDhcp();
            ipv4.removeAddress(i.name());
            e.apply();
        }
    }

    /// Gives the adapter its address as chosen.
    fn apply(e: *Ethernet) void {
        const i = &(e.ifc orelse return);
        _ = ipv4.bringUp(i.name());
        switch (e.addressing) {
            .static => |st| ipv4.setStatic(i.name(), st.address, st.prefix, st.gateway) catch |err| {
                print("dazzle: network: cannot set {s}'s address ({s})\n", .{ i.name(), @errorName(err) });
            },
            .dhcp => {
                const rc = linux.fork();
                if (linux.errno(rc) != .SUCCESS) return print("dazzle: network: cannot start DHCP on {s}\n", .{i.name()});
                if (rc == 0) ipv4.runDhcp(i.name());
                e.dhcp_pid = @intCast(rc);
            },
        }
    }

    fn stopDhcp(e: *Ethernet) void {
        const pid = e.dhcp_pid orelse return;
        _ = linux.kill(pid, .TERM);
        var status: u32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
        e.dhcp_pid = null;
    }

    fn fill(e: *const Ethernet, r: *proto.Report) void {
        r.ethernet.addressing = e.addressing;
        r.ethernet.adapter = null;
        if (e.ifc) |*i| {
            var a: proto.Adapter = .{ .mac = i.mac, .up = i.carrier() };
            a.setName(i.name());
            r.ethernet.adapter = a;
        }
    }
};

fn run() !void {
    // Loopback first: some programs talk to themselves over it.
    ipv4.setStatic("lo", .{ 127, 0, 0, 1 }, 8, null) catch {};

    const listener = try listen(proto.socket_path);
    var ethernet: Ethernet = .{};
    var w: wifi.Manager = .{};
    var clients: [max_clients]?linux.fd_t = @splat(null);
    while (true) {
        const now = sys.nowNs();
        ethernet.look(now);
        w.look(now);

        var fds: [3 + max_clients]linux.pollfd = undefined;
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = w.eventFd(), .events = linux.POLL.IN, .revents = 0 };
        fds[2] = .{ .fd = w.eapolFd(), .events = linux.POLL.IN, .revents = 0 };
        for (clients, fds[3..]) |c, *f| f.* = .{ .fd = c orelse -1, .events = linux.POLL.IN, .revents = 0 };
        _ = linux.poll(&fds, fds.len, 1000);
        const t = sys.nowNs();

        w.events(t);
        w.eapol();
        w.tick(t);
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
            if (linux.errno(n) == .SUCCESS and n > 0) if (proto.Request.parse(buf[0..n])) |req| {
                switch (req) {
                    .status => {},
                    .ethernet => |a| ethernet.set(a),
                    .wifi => |wr| w.handle(wr, t),
                }
                var report: proto.Report = .{};
                ethernet.fill(&report);
                w.fill(&report);
                var out: [4096]u8 = undefined;
                const text = report.write(&out);
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
    if (!ok) print("dazzle: network: refused {s} (pid {d})\n", .{ exe[0..n], cred.pid });
    return ok;
}

pub fn isAllowedProgram(exe: []const u8) bool {
    return std.mem.eql(u8, exe, proto.allowed_program);
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
    try std.testing.expect(isAllowedProgram("/os/shell/dazzle-settings"));
    try std.testing.expect(!isAllowedProgram("/apps/dazzle-demo/dazzle-demo"));
    try std.testing.expect(!isAllowedProgram("/os/shell/dazzle-settings (deleted)"));
    try std.testing.expect(!isAllowedProgram("/tmp/dazzle-settings"));
}

test "a process running another program is refused" {
    var pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    // The other end is this test program.
    try std.testing.expect(!allowed(pair[0]));
}

test {
    _ = ipv4;
    _ = wifi;
}
