//! Chat's network: finding rooms, and keeping the people in a room
//! connected to each other. It is one thread: every socket is in one epoll
//! set, which is the one file the window waits on (`Net.epfd`, the
//! window's `wake_fd`), and `Net.service` then does whatever they have
//! to say. See protocol.zig for how messages are ordered and what is sent.
//!
//! **Finding rooms.** Everyone in a room broadcasts an announcement to
//! UDP port `protocol.discovery_port` every few seconds, with the TCP
//! port they listen on; those not in a room hear them and list the rooms.
//! Each listing remembers the members heard announcing it lately. Someone
//! leaving says so, and is forgotten at once; a room with nobody left to
//! announce it (or not heard for a while) is gone from the list. There is
//! nothing else to a room: it exists while someone is in it, whoever
//! started it.
//!
//! **Joining.** The newcomer connects (TCP) to the member that announced
//! the room last (or, if it cannot be reached, the others heard), and
//! they exchange `hello`s. Each tells the other who else it
//! is connected to, so the newcomer connects to all of them: everyone is
//! connected to everyone. Announcements also mend the mesh: a member that
//! hears one from someone it is not connected to, and has the smaller id,
//! connects to them. Two connections made to each other at once are
//! resolved the same way at both ends: the one started by the smaller id
//! stays.
//!
//! Anyone on the network can join a room: there are no passwords.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const protocol = @import("protocol.zig");

const Name = protocol.Name;

const announce_ns = 3 * std.time.ns_per_s;
/// A room nobody has announced for this long is not listed.
const ad_expiry_ns = 10 * std.time.ns_per_s;
const ping_ns = 5 * std.time.ns_per_s;
/// Connected, and silent for this long (a ping comes every `ping_ns`).
const dead_ns = 20 * std.time.ns_per_s;
/// A connection that has not said hello by now is dropped.
const handshake_ns = 10 * std.time.ns_per_s;
/// How long to try to join a room.
const join_ns = 8 * std.time.ns_per_s;
/// The most listed rooms.
const max_ads = 32;
/// The most that waits to be sent to one peer.
const max_backlog = 256 * 1024;

// Linux's values (the same on every architecture).
const EPOLLIN = 0x001;
const EPOLLOUT = 0x004;
const EPOLLERR = 0x008;
const EPOLLHUP = 0x010;
const EPOLLRDHUP = 0x2000;
const EPOLL_CLOEXEC = 0x80000;
const EPOLL_CTL_ADD = 1;
const EPOLL_CTL_DEL = 2;
const EPOLL_CTL_MOD = 3;

/// An address and port.
pub const Endpoint = struct {
    addr: [4]u8,
    port: u16,
};

/// Everyone on the network, where announcements are heard.
const everyone: Endpoint = .{ .addr = .{ 255, 255, 255, 255 }, .port = protocol.discovery_port };

pub const Options = struct {
    /// This computer's name, as the others see it.
    name: []const u8,
    /// Where announcements are heard (0: any port, for tests).
    udp_port: u16 = protocol.discovery_port,
    /// Where they are sent.
    announce_to: []const Endpoint = &.{everyone},
};

/// The most members remembered for a room listed.
pub const max_hosts = 4;

/// A member heard announcing a room: where to connect to them.
pub const Host = struct {
    node: u64,
    at: Endpoint,
    seen_ns: u64,
};

/// A room someone announced.
pub const Ad = struct {
    room: u64,
    name: Name,
    members: u8,
    /// The members heard announcing it lately, the latest first.
    hosts: [max_hosts]Host = undefined,
    hosts_len: u8 = 0,

    pub fn hostList(a: *const Ad) []const Host {
        return a.hosts[0..a.hosts_len];
    }

    /// Notes that a member announced it (just now: they go first).
    fn heard(a: *Ad, h: Host) void {
        a.forget(h.node);
        const keep: u8 = @min(a.hosts_len, max_hosts - 1);
        std.mem.copyBackwards(Host, a.hosts[1 .. keep + 1], a.hosts[0..keep]);
        a.hosts[0] = h;
        a.hosts_len = keep + 1;
    }

    /// Forgets a member (who left).
    fn forget(a: *Ad, node: u64) void {
        var k: usize = 0;
        while (k < a.hosts_len) {
            if (a.hosts[k].node == node) a.remove(k) else k += 1;
        }
    }

    /// Forgets the members not heard for a while.
    fn expire(a: *Ad, now: u64) void {
        var k: usize = 0;
        while (k < a.hosts_len) {
            if (now -| a.hosts[k].seen_ns > ad_expiry_ns) a.remove(k) else k += 1;
        }
    }

    fn remove(a: *Ad, k: usize) void {
        std.mem.copyForwards(Host, a.hosts[k .. a.hosts_len - 1], a.hosts[k + 1 .. a.hosts_len]);
        a.hosts_len -= 1;
    }
};

/// The room this client is in.
pub const Room = struct {
    id: u64,
    name: Name,
    log: protocol.Log,
    /// Whether it is part of the room: it started it, or some member has
    /// answered it.
    connected: bool,
    /// When to give up on joining.
    deadline_ns: u64 = 0,
    /// Joining: the members to try, and how many have been.
    hosts: [max_hosts]Endpoint = undefined,
    hosts_len: u8 = 0,
    tried: u8 = 0,
};

const PeerState = enum { connecting, open, ready };

const rx_size = 2 * (protocol.max_frame + 2);

/// Another client in the room (once `ready`; before that it is just a
/// connection).
const Peer = struct {
    fd: linux.fd_t,
    /// Whether this client connected to it (and not the other way).
    outbound: bool,
    state: PeerState,
    node: u64 = 0,
    name: Name = .{},
    /// Where it listens.
    addr: [4]u8,
    port: u16,
    born_ns: u64,
    last_rx_ns: u64,
    rx: [rx_size]u8 = undefined,
    rx_len: usize = 0,
    /// What is yet to be sent: `tx[tx_at..]`.
    tx: std.ArrayList(u8) = .empty,
    tx_at: usize = 0,
    /// Whether epoll is told to wake for room to write.
    writing: bool = false,
};

pub const Net = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    /// Readable when any socket has something: the window waits on it.
    epfd: linux.fd_t,
    /// Announcements; not there if the port is taken.
    udp: ?linux.fd_t,
    listener: linux.fd_t,
    port: u16,
    node: u64,
    name: Name,
    ads: std.ArrayList(Ad) = .empty,
    room: ?Room = null,
    peers: std.ArrayList(*Peer) = .empty,
    /// Something to tell the person, if there is.
    message: []const u8 = "",
    /// What the window shows has changed.
    changed: bool = true,
    next_announce_ns: u64 = 0,
    next_ping_ns: u64 = 0,
    last_reply_ns: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Net {
        const epfd: linux.fd_t = @intCast(try sys.check(linux.epoll_create1(EPOLL_CLOEXEC)));
        errdefer sys.close(epfd);

        const listener = try newSocket(linux.SOCK.STREAM);
        errdefer sys.close(listener);
        const bind_addr = sockaddrIn(.{ 0, 0, 0, 0 }, 0);
        _ = try sys.check(linux.bind(listener, @ptrCast(&bind_addr), @sizeOf(@TypeOf(bind_addr))));
        _ = try sys.check(linux.listen(listener, 8));

        var message: []const u8 = "";
        const udp: ?linux.fd_t = openDiscovery(opts.udp_port) catch blk: {
            message = "Rooms cannot be found: the network port is in use";
            break :blk null;
        };
        errdefer if (udp) |fd| sys.close(fd);

        if (!epollCtl(epfd, EPOLL_CTL_ADD, listener, EPOLLIN)) return error.Unexpected;
        if (udp) |fd| if (!epollCtl(epfd, EPOLL_CTL_ADD, fd, EPOLLIN)) return error.Unexpected;

        var n: Net = .{
            .gpa = gpa,
            .opts = opts,
            .epfd = epfd,
            .udp = udp,
            .listener = listener,
            .port = localPort(listener),
            .node = randomId(),
            .name = Name.init(opts.name),
            .message = message,
        };
        // Whoever is in a room says so.
        n.broadcast(.{ .kind = .query, .node = n.node });
        return n;
    }

    /// The port announcements are heard on.
    pub fn udpPort(n: *const Net) u16 {
        return localPort(n.udp orelse return 0);
    }

    pub fn deinit(n: *Net) void {
        n.leave();
        n.peers.deinit(n.gpa);
        n.ads.deinit(n.gpa);
        if (n.udp) |fd| sys.close(fd);
        sys.close(n.listener);
        sys.close(n.epfd);
    }

    // --- What the window asks -----------------------------------------------------

    /// Starts a room, and is in it.
    pub fn create(n: *Net, room_name: []const u8, now: u64) void {
        if (n.room != null) return;
        n.room = .{
            .id = randomId(),
            .name = Name.init(room_name),
            .log = protocol.Log.init(n.gpa),
            .connected = true,
        };
        n.message = "";
        n.announce();
        n.next_announce_ns = now + announce_ns;
        n.changed = true;
    }

    /// Joins a listed room.
    pub fn join(n: *Net, room: u64, now: u64) void {
        if (n.room != null) return;
        var found: ?Ad = null;
        for (n.ads.items) |a| {
            if (a.room == room) found = a;
        }
        const ad = found orelse return;
        n.room = .{
            .id = ad.room,
            .name = ad.name,
            .log = protocol.Log.init(n.gpa),
            .connected = false,
            .deadline_ns = now + join_ns,
        };
        const r = &n.room.?;
        for (ad.hostList(), 0..) |h, k| r.hosts[k] = h.at;
        r.hosts_len = ad.hosts_len;
        n.message = "";
        n.changed = true;
        n.tryNextHost(now);
    }

    /// Joining: connects to the next member heard announcing the room, or
    /// gives up if there is none left to try.
    fn tryNextHost(n: *Net, now: u64) void {
        const r = n.roomPtr() orelse return;
        while (r.tried < r.hosts_len) {
            const h = r.hosts[r.tried];
            r.tried += 1;
            if (n.dial(h.addr, h.port, now) != null) return;
        }
        n.joinFailed();
    }

    /// Leaves the room. The others carry on in it; if there are none, it
    /// is gone.
    pub fn leave(n: *Net) void {
        const r = n.roomPtr() orelse return;
        // Not to be joined through any more (and the room not listed at
        // all, if nobody else announces it).
        if (r.connected) n.broadcast(.{ .kind = .left, .room = r.id, .node = n.node });
        n.leaveRoom();
    }

    fn leaveRoom(n: *Net) void {
        const r = n.roomPtr() orelse return;
        n.dropAll();
        n.removeAd(r.id);
        r.log.deinit();
        n.room = null;
        // Ask who is where, as at the start.
        n.broadcast(.{ .kind = .query, .node = n.node });
        n.changed = true;
    }

    fn joinFailed(n: *Net) void {
        n.leaveRoom();
        n.message = "That room could not be joined";
    }

    /// Says something in the room.
    pub fn say(n: *Net, text: []const u8) void {
        const r = n.roomPtr() orelse return;
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return;
        var len = @min(trimmed.len, protocol.max_text);
        while (len > 0 and len < trimmed.len and trimmed[len] & 0xc0 == 0x80) len -= 1;
        const m = (r.log.post(n.node, n.name.get(), trimmed[0..len]) catch null) orelse return;
        n.changed = true;
        var buf: [protocol.max_frame + 2]u8 = undefined;
        const frame = protocol.encodeMessage(&buf, m) orelse return;
        var i = n.peers.items.len;
        while (i > 0) {
            i -= 1;
            const p = n.peers.items[i];
            if (p.state == .ready) _ = n.send(p, frame);
        }
    }

    /// The names of the people in the room, this client first.
    pub fn members(n: *const Net, out: [][]const u8) [][]const u8 {
        if (out.len == 0) return out[0..0];
        out[0] = n.name.get();
        var k: usize = 1;
        for (n.peers.items) |p| {
            if (p.state == .ready and k < out.len) {
                out[k] = p.name.get();
                k += 1;
            }
        }
        return out[0..k];
    }

    pub fn readyCount(n: *const Net) usize {
        var count: usize = 0;
        for (n.peers.items) |p| {
            if (p.state == .ready) count += 1;
        }
        return count;
    }

    fn roomPtr(n: *Net) ?*Room {
        return if (n.room) |*r| r else null;
    }

    // --- Time and sockets ---------------------------------------------------------

    /// Does what the sockets have to say, and what is due. Returns whether
    /// what the window shows has changed.
    pub fn service(n: *Net, now: u64) bool {
        var events: [16]linux.epoll_event = undefined;
        while (true) {
            const rc = linux.epoll_wait(n.epfd, &events, events.len, 0);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            for (events[0..rc]) |ev| n.handle(ev.data.fd, ev.events, now);
            if (rc < events.len) break;
        }
        n.tick(now);
        const changed = n.changed;
        n.changed = false;
        return changed;
    }

    fn handle(n: *Net, fd: linux.fd_t, events: u32, now: u64) void {
        if (fd == n.listener) return n.acceptPeers(now);
        if (n.udp) |u| if (fd == u) return n.readDatagrams(now);
        const p = n.peerFor(fd) orelse return;
        if (p.state == .connecting) {
            if ((events & (EPOLLOUT | EPOLLERR | EPOLLHUP)) == 0) return;
            var failure: i32 = 0;
            var failure_len: linux.socklen_t = @sizeOf(i32);
            const rc = linux.getsockopt(p.fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&failure), &failure_len);
            if (linux.errno(rc) != .SUCCESS or failure != 0) return n.closePeer(p);
            p.state = .open;
            if (!n.flush(p)) return;
        } else if ((events & EPOLLOUT) != 0) {
            if (!n.flush(p)) return;
        }
        if ((events & (EPOLLIN | EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0) n.readPeer(p, now);
    }

    fn tick(n: *Net, now: u64) void {
        n.pruneAds(now);
        const r = n.roomPtr() orelse return;
        if (!r.connected) {
            if (now >= r.deadline_ns) return n.joinFailed();
            if (n.peers.items.len == 0) return n.tryNextHost(now);
        }
        if (now >= n.next_announce_ns) {
            n.announce();
            n.next_announce_ns = now + announce_ns;
        }
        const ping = now >= n.next_ping_ns;
        if (ping) n.next_ping_ns = now + ping_ns;
        var j = n.peers.items.len;
        while (j > 0) {
            j -= 1;
            const p = n.peers.items[j];
            if (p.state != .ready) {
                if (now -| p.born_ns > handshake_ns) n.closePeer(p);
            } else if (now -| p.last_rx_ns > dead_ns) {
                n.closePeer(p);
            } else if (ping) {
                var buf: [8]u8 = undefined;
                if (protocol.encodePing(&buf)) |frame| _ = n.send(p, frame);
            }
        }
    }

    fn peerFor(n: *const Net, fd: linux.fd_t) ?*Peer {
        for (n.peers.items) |p| {
            if (p.fd == fd) return p;
        }
        return null;
    }

    // --- Announcements ------------------------------------------------------------

    fn broadcast(n: *Net, d: protocol.Datagram) void {
        const fd = n.udp orelse return;
        var buf: [128]u8 = undefined;
        const bytes = protocol.encodeDatagram(&buf, d) orelse return;
        for (n.opts.announce_to) |to| {
            const dest = sockaddrIn(to.addr, to.port);
            // No network: nobody to hear it.
            _ = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, @ptrCast(&dest), @sizeOf(@TypeOf(dest)));
        }
    }

    fn announce(n: *Net) void {
        const r = n.roomPtr() orelse return;
        if (!r.connected) return;
        n.broadcast(.{
            .kind = .announce,
            .room = r.id,
            .room_name = r.name.get(),
            .node = n.node,
            .port = n.port,
            .members = @intCast(@min(n.readyCount() + 1, 255)),
        });
    }

    fn readDatagrams(n: *Net, now: u64) void {
        const fd = n.udp orelse return;
        while (true) {
            var buf: [256]u8 = undefined;
            var from: linux.sockaddr.in = undefined;
            var from_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.recvfrom(fd, &buf, buf.len, linux.MSG.DONTWAIT, @ptrCast(&from), &from_len);
            if (linux.errno(rc) != .SUCCESS) return;
            const d = protocol.decodeDatagram(buf[0..rc]) orelse continue;
            n.hear(d, @bitCast(from.addr), now);
        }
    }

    fn hear(n: *Net, d: protocol.Datagram, addr: [4]u8, now: u64) void {
        // Our own, heard back.
        if (d.node == n.node) return;
        switch (d.kind) {
            .query => if (n.room != null and now -| n.last_reply_ns > std.time.ns_per_s / 2) {
                n.last_reply_ns = now;
                n.announce();
            },
            .left => {
                for (n.ads.items) |*a| {
                    if (a.room == d.room) a.forget(d.node);
                }
                n.pruneAds(now);
            },
            .announce => {
                if (n.roomPtr()) |r| {
                    // A member we are not connected to: the smaller id
                    // connects.
                    if (r.id == d.room and r.connected and n.node < d.node) n.meet(addr, d.port, d.node, now);
                    if (r.id == d.room) return;
                }
                const host: Host = .{ .node = d.node, .at = .{ .addr = addr, .port = d.port }, .seen_ns = now };
                const name = Name.init(d.room_name);
                for (n.ads.items) |*a| {
                    if (a.room != d.room) continue;
                    if (a.members != d.members or !std.mem.eql(u8, a.name.get(), name.get())) n.changed = true;
                    a.name = name;
                    a.members = d.members;
                    a.heard(host);
                    return;
                }
                if (n.ads.items.len >= max_ads) return;
                var ad: Ad = .{ .room = d.room, .name = name, .members = d.members };
                ad.heard(host);
                n.ads.append(n.gpa, ad) catch return;
                n.changed = true;
            },
        }
    }

    /// Lets go of the rooms nobody announces any more.
    fn pruneAds(n: *Net, now: u64) void {
        var i: usize = 0;
        while (i < n.ads.items.len) {
            n.ads.items[i].expire(now);
            if (n.ads.items[i].hosts_len == 0) {
                _ = n.ads.orderedRemove(i);
                n.changed = true;
            } else i += 1;
        }
    }

    fn removeAd(n: *Net, room: u64) void {
        var i: usize = 0;
        while (i < n.ads.items.len) {
            if (n.ads.items[i].room == room) {
                _ = n.ads.orderedRemove(i);
                n.changed = true;
            } else i += 1;
        }
    }

    // --- Connections --------------------------------------------------------------

    /// Connects to a member we heard of, if we have not met.
    fn meet(n: *Net, addr: [4]u8, port: u16, node: u64, now: u64) void {
        if (node == n.node or n.peers.items.len >= protocol.max_peers) return;
        for (n.peers.items) |p| {
            if (p.state == .ready and p.node == node) return;
            if (p.state != .ready and p.outbound and std.mem.eql(u8, &p.addr, &addr) and p.port == port) return;
        }
        _ = n.dial(addr, port, now);
    }

    fn dial(n: *Net, addr: [4]u8, port: u16, now: u64) ?*Peer {
        const fd = newSocket(linux.SOCK.STREAM) catch return null;
        setNoDelay(fd);
        const dest = sockaddrIn(addr, port);
        const state: PeerState = switch (linux.errno(linux.connect(fd, @ptrCast(&dest), @sizeOf(@TypeOf(dest))))) {
            .SUCCESS => .open,
            .INPROGRESS => .connecting,
            else => {
                sys.close(fd);
                return null;
            },
        };
        const p = n.addPeer(fd, true, state, addr, port, now) orelse {
            sys.close(fd);
            return null;
        };
        _ = n.sendHello(p);
        return p;
    }

    fn acceptPeers(n: *Net, now: u64) void {
        while (true) {
            var from: linux.sockaddr.in = undefined;
            var from_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.accept4(n.listener, @ptrCast(&from), &from_len, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return;
            const fd: linux.fd_t = @intCast(rc);
            // Only a room has anyone to talk to.
            if (n.room == null or n.peers.items.len >= protocol.max_peers + 4) {
                sys.close(fd);
                continue;
            }
            setNoDelay(fd);
            const p = n.addPeer(fd, false, .open, @bitCast(from.addr), 0, now) orelse {
                sys.close(fd);
                continue;
            };
            _ = n.sendHello(p);
        }
    }

    fn addPeer(n: *Net, fd: linux.fd_t, outbound: bool, state: PeerState, addr: [4]u8, port: u16, now: u64) ?*Peer {
        const p = n.gpa.create(Peer) catch return null;
        p.* = .{ .fd = fd, .outbound = outbound, .state = state, .addr = addr, .port = port, .born_ns = now, .last_rx_ns = now };
        n.peers.append(n.gpa, p) catch {
            n.gpa.destroy(p);
            return null;
        };
        var events: u32 = EPOLLIN;
        if (state == .connecting) events |= EPOLLOUT;
        if (!epollCtl(n.epfd, EPOLL_CTL_ADD, fd, events)) {
            _ = n.peers.pop();
            n.gpa.destroy(p);
            return null;
        }
        p.writing = state == .connecting;
        return p;
    }

    /// Closes a connection (not the room: it goes on with the others).
    fn closePeer(n: *Net, p: *Peer) void {
        _ = epollCtl(n.epfd, EPOLL_CTL_DEL, p.fd, 0);
        sys.close(p.fd);
        for (n.peers.items, 0..) |q, i| {
            if (q == p) {
                _ = n.peers.orderedRemove(i);
                break;
            }
        }
        if (p.state == .ready) n.changed = true;
        p.tx.deinit(n.gpa);
        n.gpa.destroy(p);
    }

    fn dropAll(n: *Net) void {
        while (n.peers.items.len > 0) n.closePeer(n.peers.items[n.peers.items.len - 1]);
    }

    fn watchWrite(n: *Net, p: *Peer, on: bool) void {
        if (p.writing == on) return;
        p.writing = on;
        _ = epollCtl(n.epfd, EPOLL_CTL_MOD, p.fd, if (on) EPOLLIN | EPOLLOUT else EPOLLIN);
    }

    /// Queues a frame for a peer and sends what it can take. Returns
    /// false if the peer is gone (closed) because it could not be sent to.
    fn send(n: *Net, p: *Peer, frame: []const u8) bool {
        if (p.tx.items.len - p.tx_at + frame.len > max_backlog) {
            n.closePeer(p);
            return false;
        }
        p.tx.appendSlice(n.gpa, frame) catch {
            n.closePeer(p);
            return false;
        };
        return n.flush(p);
    }

    fn flush(n: *Net, p: *Peer) bool {
        if (p.state == .connecting) return true;
        while (p.tx_at < p.tx.items.len) {
            const rest = p.tx.items[p.tx_at..];
            const rc = linux.sendto(p.fd, rest.ptr, rest.len, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => p.tx_at += rc,
                .INTR => {},
                .AGAIN => {
                    n.watchWrite(p, true);
                    return true;
                },
                else => {
                    n.closePeer(p);
                    return false;
                },
            }
        }
        p.tx.clearRetainingCapacity();
        p.tx_at = 0;
        n.watchWrite(p, false);
        return true;
    }

    fn readPeer(n: *Net, p: *Peer, now: u64) void {
        while (true) {
            if (p.rx_len == p.rx.len) return n.closePeer(p);
            const rc = linux.recvfrom(p.fd, p.rx[p.rx_len..].ptr, p.rx.len - p.rx_len, linux.MSG.DONTWAIT, null, null);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return,
                else => return n.closePeer(p),
            }
            if (rc == 0) return n.closePeer(p);
            p.rx_len += rc;
            p.last_rx_ns = now;
            if (!n.parseFrames(p, now)) return;
        }
    }

    /// Handles the frames that have arrived. Returns false if the peer
    /// was closed.
    fn parseFrames(n: *Net, p: *Peer, now: u64) bool {
        var at: usize = 0;
        while (true) {
            const next = protocol.nextFrame(p.rx[at..p.rx_len]) catch {
                n.closePeer(p);
                return false;
            };
            const f = next orelse break;
            at += f.used;
            if (!n.onFrame(p, f, now)) return false;
        }
        std.mem.copyForwards(u8, p.rx[0 .. p.rx_len - at], p.rx[at..p.rx_len]);
        p.rx_len -= at;
        return true;
    }

    /// Returns false if the peer was closed.
    fn onFrame(n: *Net, p: *Peer, f: protocol.Frame, now: u64) bool {
        const r = n.roomPtr() orelse {
            n.closePeer(p);
            return false;
        };
        if (p.state != .ready and f.kind != .hello) {
            n.closePeer(p);
            return false;
        }
        switch (f.kind) {
            .hello => {
                const h = protocol.decodeHello(f.body);
                if (p.state == .ready or h == null or h.?.room != r.id or h.?.node == n.node) {
                    n.closePeer(p);
                    return false;
                }
                return n.welcome(p, r, h.?);
            },
            .peers => {
                var buf: [protocol.max_peers + 4]protocol.PeerAddr = undefined;
                const list = protocol.decodePeers(f.body, &buf) orelse {
                    n.closePeer(p);
                    return false;
                };
                for (list) |pa| n.meet(pa.addr, pa.port, pa.node, now);
            },
            .sync => {
                var buf: [protocol.max_have]protocol.Have = undefined;
                const have = protocol.decodeSync(f.body, &buf) orelse {
                    n.closePeer(p);
                    return false;
                };
                var out: [protocol.max_frame + 2]u8 = undefined;
                for (r.log.items.items) |m| {
                    if (!protocol.wants(have, m)) continue;
                    const frame = protocol.encodeMessage(&out, m) orelse continue;
                    if (!n.send(p, frame)) return false;
                }
            },
            .message => {
                const m = protocol.decodeMessage(f.body) orelse {
                    n.closePeer(p);
                    return false;
                };
                if (r.log.add(m) catch false) n.changed = true;
            },
            .ping => {},
            _ => {},
        }
        return true;
    }

    /// A peer said hello: it is in the room. Returns false if the peer was
    /// closed.
    fn welcome(n: *Net, p: *Peer, r: *Room, h: protocol.Hello) bool {
        // The same client twice (each connected to the other at the same
        // time): the connection the smaller id made stays, at both ends.
        for (n.peers.items) |q| {
            if (q == p or q.state != .ready or q.node != h.node) continue;
            const by_p = if (p.outbound) n.node else h.node;
            const by_q = if (q.outbound) n.node else h.node;
            if (by_p <= by_q) {
                n.closePeer(q);
                break;
            }
            n.closePeer(p);
            return false;
        }
        if (n.readyCount() >= protocol.max_peers) {
            n.closePeer(p);
            return false;
        }
        p.node = h.node;
        p.name = Name.init(h.name);
        if (!p.outbound) p.port = h.port;
        p.state = .ready;
        n.changed = true;
        if (!r.connected) {
            r.connected = true;
            n.announce();
            n.next_announce_ns = p.last_rx_ns + announce_ns;
        }

        // Who else is here, and what each has (so each gets the rest).
        var buf: [64 + 16 * 15]u8 = undefined;
        var others: [protocol.max_peers]protocol.PeerAddr = undefined;
        var count: usize = 0;
        for (n.peers.items) |q| {
            if (q != p and q.state == .ready and count < others.len) {
                others[count] = .{ .node = q.node, .addr = q.addr, .port = q.port };
                count += 1;
            }
        }
        if (protocol.encodePeers(&buf, others[0..count])) |frame| {
            if (!n.send(p, frame)) return false;
        }
        var have: [protocol.max_have]protocol.Have = undefined;
        var sync: [4 + protocol.max_have * 12 + 8]u8 = undefined;
        if (protocol.encodeSync(&sync, r.log.summary(&have))) |frame| {
            if (!n.send(p, frame)) return false;
        }
        return true;
    }

    fn sendHello(n: *Net, p: *Peer) bool {
        const r = n.roomPtr() orelse return true;
        var buf: [128]u8 = undefined;
        const frame = protocol.encodeHello(&buf, .{
            .room = r.id,
            .room_name = r.name.get(),
            .node = n.node,
            .port = n.port,
            .name = n.name.get(),
        }) orelse return true;
        return n.send(p, frame);
    }
};

// --- Sockets --------------------------------------------------------------------

fn sockaddrIn(addr: [4]u8, port: u16) linux.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(addr),
    };
}

fn newSocket(kind: u32) !linux.fd_t {
    return @intCast(try sys.check(linux.socket(linux.AF.INET, kind | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0)));
}

fn setNoDelay(fd: linux.fd_t) void {
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(c_int));
}

fn localPort(fd: linux.fd_t) u16 {
    var a: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&a), &len)) != .SUCCESS) return 0;
    return std.mem.bigToNative(u16, a.port);
}

/// The UDP socket announcements are sent and heard on. Others on this
/// computer share the port.
fn openDiscovery(port: u16) !linux.fd_t {
    const fd = try newSocket(linux.SOCK.DGRAM);
    errdefer sys.close(fd);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.BROADCAST, std.mem.asBytes(&one), @sizeOf(c_int));
    const addr = sockaddrIn(.{ 0, 0, 0, 0 }, port);
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    return fd;
}

fn epollCtl(epfd: linux.fd_t, op: u32, fd: linux.fd_t, events: u32) bool {
    var ev: linux.epoll_event = .{ .events = events, .data = .{ .fd = fd } };
    return linux.errno(linux.epoll_ctl(epfd, op, fd, &ev)) == .SUCCESS;
}

/// A random 64-bit id (not 0).
fn randomId() u64 {
    var bytes: [8]u8 = undefined;
    const rc = linux.getrandom(&bytes, bytes.len, 0);
    const id = if (linux.errno(rc) == .SUCCESS and rc == bytes.len)
        std.mem.readInt(u64, &bytes, .little)
    else
        sys.nowNs() *% 0x9e3779b97f4a7c15;
    return if (id == 0) 1 else id;
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

const loopback: [4]u8 = .{ 127, 0, 0, 1 };

/// Three clients on this computer, each announcing to the others' ports
/// over the loopback (as a broadcast reaches everyone on a network).
const Lan = struct {
    nets: [3]Net,
    to: [3]Endpoint,

    fn init(lan: *Lan) !void {
        const names = [_][]const u8{ "alice", "bob", "carol" };
        var made: usize = 0;
        errdefer for (lan.nets[0..made]) |*n| n.deinit();
        for (&lan.nets, names) |*n, name| {
            n.* = try Net.init(testing.allocator, .{ .name = name, .udp_port = 0, .announce_to = &.{} });
            made += 1;
        }
        for (&lan.nets, &lan.to) |*n, *to| to.* = .{ .addr = loopback, .port = n.udpPort() };
        for (&lan.nets) |*n| n.opts.announce_to = &lan.to;
    }

    fn deinit(lan: *Lan) void {
        for (&lan.nets) |*n| n.deinit();
    }

    /// Runs them all until `done` (or a few seconds go by).
    fn until(lan: *Lan, comptime done: fn (*Lan) bool) !void {
        for (0..3000) |_| {
            for (&lan.nets) |*n| _ = n.service(sys.nowNs());
            if (done(lan)) return;
            sys.sleepMs(1);
        }
        return error.Timeout;
    }
};

fn inRoom(n: *const Net) bool {
    return n.room != null and n.room.?.connected;
}

fn said(n: *const Net) usize {
    return if (n.room) |r| r.log.items.items.len else 0;
}

fn listedBy(n: *const Net, host: u64) bool {
    for (n.ads.items) |a| {
        for (a.hostList()) |h| if (h.node == host) return true;
    }
    return false;
}

fn expectSameHistory(a: *const Net, b: *const Net) !void {
    const x = a.room.?.log.items.items;
    const y = b.room.?.log.items.items;
    try testing.expectEqual(x.len, y.len);
    for (x, y) |p, q| {
        try testing.expectEqual(p.author, q.author);
        try testing.expectEqual(p.seq, q.seq);
        try testing.expectEqualStrings(p.text, q.text);
    }
}

test "a room is found, joined and talked in, and lasts while anyone is in it" {
    var lan: Lan = undefined;
    try lan.init();
    defer lan.deinit();
    const a = &lan.nets[0];
    const b = &lan.nets[1];
    const c = &lan.nets[2];

    a.create("Lounge", sys.nowNs());
    a.say("first");
    a.say("second");

    // The others hear of it.
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return l.nets[1].ads.items.len == 1 and l.nets[2].ads.items.len == 1;
        }
    }.f);
    try testing.expectEqualStrings("Lounge", b.ads.items[0].name.get());
    try testing.expectEqual(@as(u8, 1), b.ads.items[0].members);

    // Bob joins, and gets what was said.
    b.join(b.ads.items[0].room, sys.nowNs());
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return inRoom(&l.nets[1]) and said(&l.nets[1]) == 2;
        }
    }.f);
    try expectSameHistory(a, b);

    // They talk at the same time, and agree on the order.
    a.say("from alice");
    b.say("from bob");
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return said(&l.nets[0]) == 4 and said(&l.nets[1]) == 4 and l.nets[2].ads.items[0].members == 2;
        }
    }.f);
    try expectSameHistory(a, b);

    // Alice, who started it, leaves: Bob keeps it open, and nobody is
    // sent to Alice to join it.
    a.leave();
    try lan.until(struct {
        fn f(l: *Lan) bool {
            const alice = l.nets[0].node;
            return l.nets[1].readyCount() == 0 and !listedBy(&l.nets[2], alice) and l.nets[0].ads.items.len == 1;
        }
    }.f);
    try testing.expect(inRoom(b));
    try testing.expectEqual(@as(usize, 1), c.ads.items.len);

    // Carol joins through Bob, and gets all of it.
    c.join(c.ads.items[0].room, sys.nowNs());
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return inRoom(&l.nets[2]) and said(&l.nets[2]) == 4;
        }
    }.f);
    try expectSameHistory(b, c);
    c.say("hello from carol");
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return said(&l.nets[1]) == 5;
        }
    }.f);
    try expectSameHistory(b, c);

    // Bob leaves: it is still listed, as Carol is in it. When she leaves
    // too it is gone at once (not when it would have expired).
    b.leave();
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return !listedBy(&l.nets[0], l.nets[1].node) and listedBy(&l.nets[0], l.nets[2].node);
        }
    }.f);
    try testing.expectEqual(@as(usize, 1), a.ads.items.len);
    c.leave();
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return l.nets[0].ads.items.len == 0 and l.nets[1].ads.items.len == 0;
        }
    }.f);
}

test "joining tries each member heard of, and gives up if none answers" {
    var lan: Lan = undefined;
    try lan.init();
    defer lan.deinit();
    const a = &lan.nets[0];
    const b = &lan.nets[1];
    const now = sys.nowNs();
    a.create("Lounge", now);

    // Heard last from someone who has gone (nothing listens on port 1),
    // and before that from Alice: Bob gets in through her.
    var ad: Ad = .{ .room = a.room.?.id, .name = Name.init("Lounge"), .members = 2 };
    ad.heard(.{ .node = a.node, .at = .{ .addr = loopback, .port = a.port }, .seen_ns = now });
    ad.heard(.{ .node = 99, .at = .{ .addr = loopback, .port = 1 }, .seen_ns = now });
    try b.ads.append(b.gpa, ad);
    b.join(ad.room, now);
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return inRoom(&l.nets[1]);
        }
    }.f);

    // Nobody there at all: it says so.
    const c = &lan.nets[2];
    var gone: Ad = .{ .room = 5, .name = Name.init("Nowhere"), .members = 1 };
    gone.heard(.{ .node = 98, .at = .{ .addr = loopback, .port = 1 }, .seen_ns = now });
    try c.ads.append(c.gpa, gone);
    c.join(5, now);
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return l.nets[2].room == null;
        }
    }.f);
    try testing.expect(c.message.len > 0);
}

test "three people all meet, even when two join at once" {
    var lan: Lan = undefined;
    try lan.init();
    defer lan.deinit();
    const a = &lan.nets[0];
    const b = &lan.nets[1];
    const c = &lan.nets[2];
    a.create("Lounge", sys.nowNs());
    try lan.until(struct {
        fn f(l: *Lan) bool {
            return l.nets[1].ads.items.len == 1 and l.nets[2].ads.items.len == 1;
        }
    }.f);
    b.join(b.ads.items[0].room, sys.nowNs());
    c.join(c.ads.items[0].room, sys.nowNs());
    try lan.until(struct {
        fn f(l: *Lan) bool {
            for (&l.nets) |*n| if (n.readyCount() != 2) return false;
            return true;
        }
    }.f);

    // Whoever speaks is heard by everyone, in the same order.
    a.say("one");
    b.say("two");
    c.say("three");
    try lan.until(struct {
        fn f(l: *Lan) bool {
            for (&l.nets) |*n| if (said(n) != 3) return false;
            return true;
        }
    }.f);
    try expectSameHistory(a, b);
    try expectSameHistory(a, c);
    var names: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), a.members(&names).len);
}
