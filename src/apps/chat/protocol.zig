//! Chat's messages, the order they are in, and how they are written on the
//! network. Nothing here touches a socket (see net.zig), so it is all
//! tested on the host.
//!
//! **Order.** There is no server and no leader: every client keeps the
//! whole room's history, and they agree on its order because the order is
//! a function of the messages alone. Each message carries a Lamport
//! timestamp (one more than the largest the author had seen, counting its
//! own), and messages are ordered by (timestamp, author, number). So a
//! reply is always after what it replies to, and messages written at the
//! same time are put in the same order by everyone. A message that was
//! delayed can still land above ones already shown, and then everyone
//! shows it there, once they have it.
//!
//! **History.** Clients connect to each other, all to all. When two
//! connect, each tells the other how many of every author's messages it
//! has (`Have`), and the other sends the rest. Any client can therefore
//! give a new one the whole history, and clients that were apart catch up
//! when they meet again.
//!
//! **On the wire.** Over TCP, a frame is a 16-bit length (of what follows),
//! a kind byte and the body, with numbers big-endian and strings with a
//! length byte:
//!
//!     hello    room(8) room name node(8) port(2) name
//!     peers    count(1) { node(8) address(4) port(2) }...
//!     sync     count(1) { author(8) next(4) }...
//!     message  timestamp(8) author(8) number(4) name text(2+bytes)
//!     ping
//!
//! Over UDP (broadcast to port `discovery_port`), a datagram is "DZCH",
//! the version, a kind ("A" announce, "Q" query, "C" closed), the room,
//! its name, the sender, its TCP port and how many people are in the room.

const std = @import("std");

pub const max_name = 31;
pub const max_text = 127;
pub const max_frame = 1024;
/// The most senders one `sync` lists (more are asked for in full).
pub const max_have = 64;
/// The most people in a room (everyone else is a connection).
pub const max_peers = 16;
/// The most messages kept; a room that long is full.
pub const max_messages = 20000;
/// Timestamps beyond this are not believed (they would put everything
/// else before them).
const max_lamport: u64 = 1 << 48;

/// A name that fits in a fixed space: a person's or a room's.
pub const Name = struct {
    buf: [max_name]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) Name {
        var n: Name = .{};
        n.set(s);
        return n;
    }

    pub fn get(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }

    /// Sets it to `s`, cut short (not in the middle of a character) if
    /// it is too long, and without line breaks or other control
    /// characters.
    pub fn set(n: *Name, s: []const u8) void {
        var len: usize = 0;
        for (s) |c| {
            if (c < ' ' or c == 0x7f) continue;
            if (len == n.buf.len) break;
            n.buf[len] = c;
            len += 1;
        }
        while (len > 0 and len < s.len and n.buf[len - 1] >= 0x80 and !std.unicode.utf8ValidateSlice(n.buf[0..len])) len -= 1;
        n.len = @intCast(len);
    }
};

/// One thing someone said.
pub const Message = struct {
    lamport: u64,
    author: u64,
    /// Its number among its author's messages, from 1.
    seq: u32,
    name: []const u8,
    text: []const u8,

    /// Whether it is before `b` in the room.
    pub fn before(a: Message, b: Message) bool {
        if (a.lamport != b.lamport) return a.lamport < b.lamport;
        if (a.author != b.author) return a.author < b.author;
        return a.seq < b.seq;
    }
};

/// How many of an author's messages someone has: all up to `next - 1`.
pub const Have = struct {
    author: u64,
    next: u32,
};

const Key = struct { author: u64, seq: u32 };

/// A room's history, in order.
pub const Log = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Message) = .empty,
    seen: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// The largest timestamp seen.
    clock: u64 = 0,
    /// The number of this client's next message.
    next_seq: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Log {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Log) void {
        for (l.items.items) |m| freeMessage(l.gpa, m);
        l.items.deinit(l.gpa);
        l.seen.deinit(l.gpa);
    }

    fn freeMessage(gpa: std.mem.Allocator, m: Message) void {
        // The name and the text are one allocation, the name first.
        const all: [*]u8 = @constCast(m.name.ptr);
        gpa.free(all[0 .. m.name.len + m.text.len]);
    }

    fn insertionPoint(l: *const Log, m: Message) usize {
        var lo: usize = 0;
        var hi: usize = l.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (l.items.items[mid].before(m)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Adds a message (copying it) at its place in the order. Returns
    /// whether it was new: not one already here, and fit to keep.
    pub fn add(l: *Log, m: Message) !bool {
        if (m.text.len == 0 or m.text.len > max_text or m.name.len > max_name) return false;
        if (m.seq == 0 or m.lamport == 0 or m.lamport >= max_lamport) return false;
        if (!std.unicode.utf8ValidateSlice(m.text) or !std.unicode.utf8ValidateSlice(m.name)) return false;
        if (l.items.items.len >= max_messages) return false;
        const key: Key = .{ .author = m.author, .seq = m.seq };
        if (l.seen.contains(key)) return false;
        const own = try l.gpa.alloc(u8, m.name.len + m.text.len);
        errdefer l.gpa.free(own);
        @memcpy(own[0..m.name.len], m.name);
        @memcpy(own[m.name.len..], m.text);
        var kept = m;
        kept.name = own[0..m.name.len];
        kept.text = own[m.name.len..];
        try l.seen.put(l.gpa, key, {});
        errdefer _ = l.seen.remove(key);
        try l.items.insert(l.gpa, l.insertionPoint(kept), kept);
        l.clock = @max(l.clock, m.lamport);
        return true;
    }

    /// Writes a message of this client's: after everything seen so far.
    /// Returns it (valid until the log changes), or null if the text is
    /// no good or the room is full.
    pub fn post(l: *Log, author: u64, name: []const u8, text: []const u8) !?Message {
        const m: Message = .{ .lamport = l.clock + 1, .author = author, .seq = l.next_seq, .name = name, .text = text };
        if (!try l.add(m)) return null;
        l.next_seq += 1;
        // `add` put it somewhere among the others: it is the last with
        // this timestamp from this author, so find it by its key.
        for (l.items.items) |*kept| if (kept.author == author and kept.seq == m.seq) return kept.*;
        return null;
    }

    /// For each author (up to `out.len`), what is the next message of
    /// theirs this log lacks, going by the numbers in a row from 1. What
    /// comes after a gap is not counted, so it is sent again.
    pub fn summary(l: *const Log, out: []Have) []Have {
        var n: usize = 0;
        for (l.items.items) |m| {
            var at: ?usize = null;
            for (out[0..n], 0..) |h, i| {
                if (h.author == m.author) {
                    at = i;
                    break;
                }
            }
            if (at == null) {
                if (n == out.len) continue;
                out[n] = .{ .author = m.author, .next = 1 };
                at = n;
                n += 1;
            }
            const h = &out[at.?];
            if (m.seq == h.next) h.next += 1;
        }
        return out[0..n];
    }
};

/// Whether someone with `have` lacks `m`.
pub fn wants(have: []const Have, m: Message) bool {
    for (have) |h| if (h.author == m.author) return m.seq >= h.next;
    return true;
}

// --- Frames ---------------------------------------------------------------------

pub const Kind = enum(u8) {
    hello = 1,
    peers = 2,
    message = 3,
    sync = 4,
    ping = 5,
    _,
};

pub const Hello = struct {
    room: u64,
    room_name: []const u8,
    node: u64,
    /// The TCP port it listens on.
    port: u16,
    name: []const u8,
};

pub const PeerAddr = struct {
    node: u64,
    addr: [4]u8,
    port: u16,
};

const Writer = struct {
    buf: []u8,
    len: usize = 0,
    full: bool = false,

    fn int(w: *Writer, comptime T: type, v: T) void {
        if (w.len + @sizeOf(T) > w.buf.len) {
            w.full = true;
            return;
        }
        std.mem.writeInt(T, w.buf[w.len..][0..@sizeOf(T)], v, .big);
        w.len += @sizeOf(T);
    }

    fn bytes(w: *Writer, b: []const u8) void {
        if (w.len + b.len > w.buf.len) {
            w.full = true;
            return;
        }
        @memcpy(w.buf[w.len..][0..b.len], b);
        w.len += b.len;
    }

    fn str(w: *Writer, s: []const u8) void {
        if (s.len > 255) {
            w.full = true;
            return;
        }
        w.int(u8, @intCast(s.len));
        w.bytes(s);
    }

    /// Begins a frame; `finish` sets its length.
    fn begin(buf: []u8, kind: Kind) Writer {
        var w: Writer = .{ .buf = buf };
        w.int(u16, 0);
        w.int(u8, @intFromEnum(kind));
        return w;
    }

    fn finish(w: *Writer) ?[]const u8 {
        if (w.full or w.len - 2 > max_frame) return null;
        std.mem.writeInt(u16, w.buf[0..2], @intCast(w.len - 2), .big);
        return w.buf[0..w.len];
    }
};

const Reader = struct {
    buf: []const u8,
    at: usize = 0,
    bad: bool = false,

    fn int(r: *Reader, comptime T: type) T {
        if (r.at + @sizeOf(T) > r.buf.len) {
            r.bad = true;
            return 0;
        }
        const v = std.mem.readInt(T, r.buf[r.at..][0..@sizeOf(T)], .big);
        r.at += @sizeOf(T);
        return v;
    }

    fn bytes(r: *Reader, n: usize) []const u8 {
        if (r.at + n > r.buf.len) {
            r.bad = true;
            return "";
        }
        const b = r.buf[r.at..][0..n];
        r.at += n;
        return b;
    }

    fn str(r: *Reader) []const u8 {
        return r.bytes(r.int(u8));
    }

    /// Whether everything read was there, and it was all of it.
    fn done(r: *const Reader) bool {
        return !r.bad and r.at == r.buf.len;
    }
};

pub const Frame = struct {
    kind: Kind,
    body: []const u8,
    /// How many bytes of the buffer it took.
    used: usize,
};

/// The first frame in `buf`, or null if it is not all there yet.
pub fn nextFrame(buf: []const u8) error{BadFrame}!?Frame {
    if (buf.len < 2) return null;
    const len = std.mem.readInt(u16, buf[0..2], .big);
    if (len == 0 or len > max_frame) return error.BadFrame;
    if (buf.len < 2 + @as(usize, len)) return null;
    return .{ .kind = @enumFromInt(buf[2]), .body = buf[3 .. 2 + @as(usize, len)], .used = 2 + @as(usize, len) };
}

pub fn encodeHello(buf: []u8, h: Hello) ?[]const u8 {
    var w = Writer.begin(buf, .hello);
    w.int(u64, h.room);
    w.str(h.room_name);
    w.int(u64, h.node);
    w.int(u16, h.port);
    w.str(h.name);
    return w.finish();
}

pub fn decodeHello(body: []const u8) ?Hello {
    var r: Reader = .{ .buf = body };
    const room = r.int(u64);
    const room_name = r.str();
    const node = r.int(u64);
    const port = r.int(u16);
    const name = r.str();
    if (!r.done() or room_name.len > max_name or name.len > max_name) return null;
    return .{ .room = room, .room_name = room_name, .node = node, .port = port, .name = name };
}

pub fn encodePeers(buf: []u8, peers: []const PeerAddr) ?[]const u8 {
    var w = Writer.begin(buf, .peers);
    w.int(u8, @intCast(@min(peers.len, 255)));
    for (peers[0..@min(peers.len, 255)]) |p| {
        w.int(u64, p.node);
        w.bytes(&p.addr);
        w.int(u16, p.port);
    }
    return w.finish();
}

/// The peers in `body`, in `out` (as many as fit).
pub fn decodePeers(body: []const u8, out: []PeerAddr) ?[]const PeerAddr {
    var r: Reader = .{ .buf = body };
    const count = r.int(u8);
    var n: usize = 0;
    for (0..count) |_| {
        const node = r.int(u64);
        const addr = r.bytes(4);
        const port = r.int(u16);
        if (r.bad) return null;
        if (n < out.len) {
            out[n] = .{ .node = node, .addr = addr[0..4].*, .port = port };
            n += 1;
        }
    }
    if (!r.done()) return null;
    return out[0..n];
}

pub fn encodeSync(buf: []u8, have: []const Have) ?[]const u8 {
    var w = Writer.begin(buf, .sync);
    const n = @min(have.len, max_have);
    w.int(u8, @intCast(n));
    for (have[0..n]) |h| {
        w.int(u64, h.author);
        w.int(u32, h.next);
    }
    return w.finish();
}

pub fn decodeSync(body: []const u8, out: []Have) ?[]const Have {
    var r: Reader = .{ .buf = body };
    const count = r.int(u8);
    var n: usize = 0;
    for (0..count) |_| {
        const author = r.int(u64);
        const next = r.int(u32);
        if (r.bad) return null;
        if (n < out.len) {
            out[n] = .{ .author = author, .next = next };
            n += 1;
        }
    }
    if (!r.done()) return null;
    return out[0..n];
}

pub fn encodeMessage(buf: []u8, m: Message) ?[]const u8 {
    var w = Writer.begin(buf, .message);
    w.int(u64, m.lamport);
    w.int(u64, m.author);
    w.int(u32, m.seq);
    w.str(m.name);
    w.int(u16, @intCast(@min(m.text.len, std.math.maxInt(u16))));
    w.bytes(m.text);
    return w.finish();
}

/// The message in `body`; its name and text are in `body`.
pub fn decodeMessage(body: []const u8) ?Message {
    var r: Reader = .{ .buf = body };
    const lamport = r.int(u64);
    const author = r.int(u64);
    const seq = r.int(u32);
    const name = r.str();
    const text = r.bytes(r.int(u16));
    if (!r.done()) return null;
    return .{ .lamport = lamport, .author = author, .seq = seq, .name = name, .text = text };
}

pub fn encodePing(buf: []u8) ?[]const u8 {
    var w = Writer.begin(buf, .ping);
    return w.finish();
}

// --- Discovery ------------------------------------------------------------------

/// The UDP port rooms are announced on.
pub const discovery_port = 48100;

const magic = "DZCH";
const version = 1;

pub const Datagram = struct {
    kind: enum { announce, query, closed },
    room: u64 = 0,
    room_name: []const u8 = "",
    node: u64 = 0,
    port: u16 = 0,
    members: u8 = 0,
};

pub fn encodeDatagram(buf: []u8, d: Datagram) ?[]const u8 {
    var w: Writer = .{ .buf = buf };
    w.bytes(magic);
    w.int(u8, version);
    w.int(u8, switch (d.kind) {
        .announce => 'A',
        .query => 'Q',
        .closed => 'C',
    });
    w.int(u64, d.room);
    w.str(d.room_name);
    w.int(u64, d.node);
    w.int(u16, d.port);
    w.int(u8, d.members);
    if (w.full) return null;
    return w.buf[0..w.len];
}

pub fn decodeDatagram(buf: []const u8) ?Datagram {
    if (buf.len < magic.len + 2 or !std.mem.eql(u8, buf[0..magic.len], magic)) return null;
    var r: Reader = .{ .buf = buf, .at = magic.len };
    if (r.int(u8) != version) return null;
    const kind: @FieldType(Datagram, "kind") = switch (r.int(u8)) {
        'A' => .announce,
        'Q' => .query,
        'C' => .closed,
        else => return null,
    };
    const room = r.int(u64);
    const room_name = r.str();
    const node = r.int(u64);
    const port = r.int(u16);
    const members = r.int(u8);
    if (!r.done() or room_name.len > max_name) return null;
    return .{ .kind = kind, .room = room, .room_name = room_name, .node = node, .port = port, .members = members };
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

fn say(l: *Log, lamport: u64, author: u64, seq: u32, text: []const u8) !bool {
    return l.add(.{ .lamport = lamport, .author = author, .seq = seq, .name = "x", .text = text });
}

test "messages are ordered by timestamp, then author, then number" {
    var l = Log.init(testing.allocator);
    defer l.deinit();
    try testing.expect(try say(&l, 2, 7, 1, "c"));
    try testing.expect(try say(&l, 1, 9, 1, "b"));
    try testing.expect(try say(&l, 1, 3, 1, "a"));
    try testing.expect(try say(&l, 2, 7, 2, "d"));
    var got: [4]u8 = undefined;
    for (l.items.items, 0..) |m, i| got[i] = m.text[0];
    try testing.expectEqualStrings("abcd", &got);
    try testing.expectEqual(@as(u64, 2), l.clock);
}

test "everyone ends up with the same order, whatever order messages arrive in" {
    const all = [_]Message{
        .{ .lamport = 1, .author = 1, .seq = 1, .name = "a", .text = "hi" },
        .{ .lamport = 1, .author = 2, .seq = 1, .name = "b", .text = "hello" },
        .{ .lamport = 2, .author = 2, .seq = 2, .name = "b", .text = "how are you" },
        .{ .lamport = 3, .author = 1, .seq = 2, .name = "a", .text = "fine" },
        .{ .lamport = 3, .author = 3, .seq = 1, .name = "c", .text = "joined late" },
    };
    var first = Log.init(testing.allocator);
    defer first.deinit();
    for (all) |m| _ = try first.add(m);
    var prng = std.Random.DefaultPrng.init(42);
    for (0..20) |_| {
        var shuffled = all;
        prng.random().shuffle(Message, &shuffled);
        var other = Log.init(testing.allocator);
        defer other.deinit();
        for (shuffled) |m| {
            try testing.expect(try other.add(m));
            // Hearing it twice changes nothing.
            try testing.expect(!try other.add(m));
        }
        try testing.expectEqual(first.items.items.len, other.items.items.len);
        for (first.items.items, other.items.items) |a, b| {
            try testing.expectEqual(a.author, b.author);
            try testing.expectEqual(a.seq, b.seq);
        }
    }
}

test "a message written after hearing others is after them" {
    var l = Log.init(testing.allocator);
    defer l.deinit();
    _ = try say(&l, 40, 5, 1, "far ahead");
    const mine = (try l.post(1, "me", "after")).?;
    try testing.expectEqual(@as(u64, 41), mine.lamport);
    try testing.expectEqual(@as(u32, 1), mine.seq);
    const next = (try l.post(1, "me", "and then")).?;
    try testing.expectEqual(@as(u32, 2), next.seq);
    try testing.expectEqualStrings("and then", l.items.items[l.items.items.len - 1].text);
}

test "messages that are no good are not kept" {
    var l = Log.init(testing.allocator);
    defer l.deinit();
    try testing.expect(!try say(&l, 1, 1, 1, ""));
    try testing.expect(!try say(&l, 1, 1, 0, "no number"));
    try testing.expect(!try say(&l, 0, 1, 1, "no time"));
    try testing.expect(!try say(&l, max_lamport, 1, 1, "far future"));
    try testing.expect(!try say(&l, 1, 1, 1, "x" ** (max_text + 1)));
    try testing.expect(!try say(&l, 1, 1, 1, "bad \xff text"));
    try testing.expectEqual(@as(usize, 0), l.items.items.len);
}

test "the summary says what to send" {
    var l = Log.init(testing.allocator);
    defer l.deinit();
    _ = try say(&l, 1, 1, 1, "a1");
    _ = try say(&l, 2, 1, 2, "a2");
    // Author 2's first is missing: 2 and 3 do not count.
    _ = try say(&l, 3, 2, 2, "b2");
    _ = try say(&l, 4, 2, 3, "b3");
    var buf: [8]Have = undefined;
    const have = l.summary(&buf);
    try testing.expectEqual(@as(usize, 2), have.len);
    try testing.expectEqual(@as(u32, 3), have[0].next);
    try testing.expectEqual(@as(u32, 1), have[1].next);
    const a1: Message = .{ .lamport = 1, .author = 1, .seq = 1, .name = "x", .text = "a1" };
    try testing.expect(!wants(have, a1));
    try testing.expect(wants(have, .{ .lamport = 5, .author = 1, .seq = 3, .name = "x", .text = "a3" }));
    try testing.expect(wants(have, .{ .lamport = 5, .author = 2, .seq = 1, .name = "x", .text = "b1" }));
    // An author nobody listed is wanted whole.
    try testing.expect(wants(have, .{ .lamport = 5, .author = 9, .seq = 1, .name = "x", .text = "c1" }));
    try testing.expect(wants(&.{}, a1));
}

test "a client with part of the history gets the rest from another" {
    var full = Log.init(testing.allocator);
    defer full.deinit();
    var part = Log.init(testing.allocator);
    defer part.deinit();
    for (1..6) |i| _ = try say(&full, i, 1 + i % 2, @intCast((i + 1) / 2), "t");
    _ = try part.add(full.items.items[0]);
    _ = try part.add(full.items.items[1]);
    var buf: [8]Have = undefined;
    const have = part.summary(&buf);
    for (full.items.items) |m| if (wants(have, m)) {
        _ = try part.add(m);
    };
    try testing.expectEqual(full.items.items.len, part.items.items.len);
    for (full.items.items, part.items.items) |a, b| {
        try testing.expectEqual(a.author, b.author);
        try testing.expectEqual(a.seq, b.seq);
    }
}

test "names are cut to fit, and stay text" {
    try testing.expectEqualStrings("kitchen", Name.init("kitchen").get());
    try testing.expectEqualStrings("ab", Name.init("a\nb").get());
    const long = Name.init("é" ** 40);
    try testing.expect(long.len <= max_name);
    try testing.expect(std.unicode.utf8ValidateSlice(long.get()));
}

test "frames are written and read back" {
    var buf: [max_frame + 2]u8 = undefined;
    const hello = encodeHello(&buf, .{ .room = 11, .room_name = "Lounge", .node = 22, .port = 4000, .name = "pi-1" }).?;
    const f = (try nextFrame(hello)).?;
    try testing.expectEqual(Kind.hello, f.kind);
    try testing.expectEqual(hello.len, f.used);
    const h = decodeHello(f.body).?;
    try testing.expectEqual(@as(u64, 11), h.room);
    try testing.expectEqualStrings("Lounge", h.room_name);
    try testing.expectEqual(@as(u64, 22), h.node);
    try testing.expectEqual(@as(u16, 4000), h.port);
    try testing.expectEqualStrings("pi-1", h.name);

    const peers = [_]PeerAddr{ .{ .node = 1, .addr = .{ 10, 0, 0, 2 }, .port = 5 }, .{ .node = 2, .addr = .{ 10, 0, 0, 3 }, .port = 6 } };
    const pf = (try nextFrame(encodePeers(&buf, &peers).?)).?;
    var out: [4]PeerAddr = undefined;
    const got = decodePeers(pf.body, &out).?;
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(u16, 6), got[1].port);
    try testing.expectEqual([4]u8{ 10, 0, 0, 2 }, got[0].addr);

    const have = [_]Have{ .{ .author = 8, .next = 3 }, .{ .author = 9, .next = 1 } };
    const sf = (try nextFrame(encodeSync(&buf, &have).?)).?;
    var hout: [4]Have = undefined;
    const hgot = decodeSync(sf.body, &hout).?;
    try testing.expectEqual(@as(usize, 2), hgot.len);
    try testing.expectEqual(@as(u32, 3), hgot[0].next);

    const m: Message = .{ .lamport = 5, .author = 6, .seq = 7, .name = "pi-2", .text = "héllo" };
    const mf = (try nextFrame(encodeMessage(&buf, m).?)).?;
    const mg = decodeMessage(mf.body).?;
    try testing.expectEqual(@as(u64, 5), mg.lamport);
    try testing.expectEqual(@as(u32, 7), mg.seq);
    try testing.expectEqualStrings("pi-2", mg.name);
    try testing.expectEqualStrings("héllo", mg.text);

    const pg = (try nextFrame(encodePing(&buf).?)).?;
    try testing.expectEqual(Kind.ping, pg.kind);
    try testing.expectEqual(@as(usize, 0), pg.body.len);
}

test "frames arrive in pieces and in bunches" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const one = encodePing(&a).?;
    const two = encodeMessage(&b, .{ .lamport = 1, .author = 1, .seq = 1, .name = "n", .text = "t" }).?;
    var all: [128]u8 = undefined;
    @memcpy(all[0..one.len], one);
    @memcpy(all[one.len..][0..two.len], two);
    const total = one.len + two.len;
    // Not all there: nothing yet.
    try testing.expect((try nextFrame(all[0 .. total - 1][one.len..])) == null);
    try testing.expect((try nextFrame(all[0..1])) == null);
    const f1 = (try nextFrame(all[0..total])).?;
    try testing.expectEqual(Kind.ping, f1.kind);
    const f2 = (try nextFrame(all[f1.used..total])).?;
    try testing.expectEqual(Kind.message, f2.kind);
    try testing.expectEqual(total, f1.used + f2.used);
}

test "bad frames are refused" {
    try testing.expectError(error.BadFrame, nextFrame(&.{ 0, 0 }));
    try testing.expectError(error.BadFrame, nextFrame(&.{ 0xff, 0xff, 1 }));
    // Short or long bodies do not decode.
    try testing.expect(decodeHello("abc") == null);
    try testing.expect(decodeMessage("") == null);
    var buf: [64]u8 = undefined;
    const m = encodeMessage(&buf, .{ .lamport = 1, .author = 1, .seq = 1, .name = "n", .text = "text" }).?;
    const body = m[3..];
    try testing.expect(decodeMessage(body) != null);
    try testing.expect(decodeMessage(body[0 .. body.len - 1]) == null);
    var longer: [64]u8 = undefined;
    @memcpy(longer[0..body.len], body);
    longer[body.len] = 0;
    try testing.expect(decodeMessage(longer[0 .. body.len + 1]) == null);
    // A frame that does not fit is not made.
    var tiny: [8]u8 = undefined;
    try testing.expect(encodeHello(&tiny, .{ .room = 1, .room_name = "r", .node = 2, .port = 3, .name = "n" }) == null);
}

test "announcements are written and read back" {
    var buf: [128]u8 = undefined;
    const d = decodeDatagram(encodeDatagram(&buf, .{ .kind = .announce, .room = 5, .room_name = "Lounge", .node = 6, .port = 7000, .members = 3 }).?).?;
    try testing.expect(d.kind == .announce);
    try testing.expectEqual(@as(u64, 5), d.room);
    try testing.expectEqualStrings("Lounge", d.room_name);
    try testing.expectEqual(@as(u8, 3), d.members);
    const q = decodeDatagram(encodeDatagram(&buf, .{ .kind = .query, .node = 6 }).?).?;
    try testing.expect(q.kind == .query);
    const c = decodeDatagram(encodeDatagram(&buf, .{ .kind = .closed, .room = 5, .node = 6 }).?).?;
    try testing.expect(c.kind == .closed);
    try testing.expect(decodeDatagram("DZCH") == null);
    try testing.expect(decodeDatagram("XXXX\x01A") == null);
    const good = encodeDatagram(&buf, .{ .kind = .announce, .room = 5, .room_name = "r", .node = 6, .port = 1, .members = 1 }).?;
    try testing.expect(decodeDatagram(good[0 .. good.len - 1]) == null);
}
