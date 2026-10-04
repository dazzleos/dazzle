//! The WPA supplicant: the station's side of WPA2-Personal's key handshakes
//! (IEEE 802.11-2020 12.7), as EAPOL-Key frames in and out. It has no I/O
//! of its own: the network manager hands it the frames that arrive (over a
//! packet socket) and sends and installs what it says.
//!
//! Joining a WPA2-Personal network:
//!
//! 1. The pairwise master key (PMK) is the passphrase stretched with
//!    PBKDF2-SHA1 over the SSID, 4096 rounds (`pmkFromPassphrase`).
//! 2. After association, the access point sends message 1 of the 4-way
//!    handshake with its nonce (ANonce). The supplicant picks its own
//!    (SNonce) and derives the pairwise transient key (PTK) from both
//!    nonces, both addresses and the PMK: a key confirmation key (KCK, for
//!    the MIC that proves each side knows the PMK), a key encryption key
//!    (KEK, for the group key) and the temporal key (TK, which encrypts the
//!    traffic). It answers with message 2: its nonce, its RSN element and a
//!    MIC.
//! 3. Message 3 proves the access point knows the PMK too (its MIC), repeats
//!    the RSN element it advertised (so a downgrade would show) and carries
//!    the group temporal key (GTK, for broadcasts), wrapped with the KEK
//!    (AES key wrap). Message 4 acknowledges it; then both sides install
//!    the keys.
//! 4. The access point replaces the GTK from time to time with the group key
//!    handshake: one message carrying the new GTK, and an acknowledgement.
//!
//! Only CCMP (AES) pairwise keys and PSK key management are supported: WPA2,
//! and WPA2/WPA3 networks through their WPA2 side. The group cipher may be
//! CCMP or TKIP (on old mixed networks). WPA3 (SAE) is not.

const std = @import("std");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const Aes128 = std.crypto.core.aes.Aes128;

pub const Mac = [6]u8;
pub const Nonce = [32]u8;

/// Cipher suites, as nl80211 names them (OUI 00-0F-AC and the type).
pub const cipher_tkip: u32 = 0x000fac02;
pub const cipher_ccmp: u32 = 0x000fac04;
/// Key management: PSK.
pub const akm_psk: u32 = 0x000fac02;

// --- Keys -----------------------------------------------------------------------

/// The pairwise master key from a passphrase (8 to 63 characters) and the
/// network's SSID.
pub fn pmkFromPassphrase(passphrase: []const u8, ssid: []const u8) [32]u8 {
    var pmk: [32]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&pmk, passphrase, ssid, 4096, HmacSha1) catch unreachable;
    return pmk;
}

/// Whether a passphrase is one WPA2 accepts: 8 to 63 printable ASCII
/// characters.
pub fn validPassphrase(p: []const u8) bool {
    if (p.len < 8 or p.len > 63) return false;
    for (p) |c| if (c < 32 or c > 126) return false;
    return true;
}

/// The 802.11 pseudo-random function on HMAC-SHA1: `out.len` bytes from
/// the key, a label and data.
pub fn prf(out: []u8, key: []const u8, label: []const u8, data: []const u8) void {
    var i: u8 = 0;
    var at: usize = 0;
    while (at < out.len) : (i += 1) {
        var h = HmacSha1.init(key);
        h.update(label);
        h.update(&.{0});
        h.update(data);
        h.update(&.{i});
        var block: [HmacSha1.mac_length]u8 = undefined;
        h.final(&block);
        const n = @min(block.len, out.len - at);
        @memcpy(out[at..][0..n], block[0..n]);
        at += n;
    }
}

pub const Ptk = struct {
    kck: [16]u8,
    kek: [16]u8,
    tk: [16]u8,
};

/// The pairwise transient key for CCMP.
pub fn derivePtk(pmk: *const [32]u8, aa: Mac, spa: Mac, anonce: Nonce, snonce: Nonce) Ptk {
    var data: [6 + 6 + 32 + 32]u8 = undefined;
    const a_first = std.mem.order(u8, &aa, &spa) == .lt;
    @memcpy(data[0..6], if (a_first) &aa else &spa);
    @memcpy(data[6..12], if (a_first) &spa else &aa);
    const n_first = std.mem.order(u8, &anonce, &snonce) == .lt;
    @memcpy(data[12..44], if (n_first) &anonce else &snonce);
    @memcpy(data[44..76], if (n_first) &snonce else &anonce);
    var out: [48]u8 = undefined;
    prf(&out, pmk, "Pairwise key expansion", &data);
    return .{ .kck = out[0..16].*, .kek = out[16..32].*, .tk = out[32..48].* };
}

/// The EAPOL-Key MIC (key descriptor version 2): HMAC-SHA1 over the frame
/// with its MIC field zeroed, cut to 16 bytes.
pub fn mic(kck: *const [16]u8, frame: []const u8) [16]u8 {
    var full: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&full, frame, kck);
    return full[0..16].*;
}

const wrap_iv = [8]u8{ 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6 };

/// AES key wrap (RFC 3394): `plain` (a multiple of 8 bytes, at least 16)
/// into `out` (8 bytes longer).
pub fn aesWrap(kek: *const [16]u8, plain: []const u8, out: []u8) void {
    const n = plain.len / 8;
    const ctx = Aes128.initEnc(kek.*);
    var a = wrap_iv;
    @memcpy(out[8..][0..plain.len], plain);
    for (0..6) |j| for (1..n + 1) |i| {
        var b: [16]u8 = undefined;
        @memcpy(b[0..8], &a);
        @memcpy(b[8..16], out[i * 8 ..][0..8]);
        ctx.encrypt(&b, &b);
        const t: u64 = @intCast(n * j + i);
        a = b[0..8].*;
        std.mem.writeInt(u64, &a, std.mem.readInt(u64, &a, .big) ^ t, .big);
        @memcpy(out[i * 8 ..][0..8], b[8..16]);
    };
    @memcpy(out[0..8], &a);
}

/// AES key unwrap (RFC 3394): `wrapped` into `out` (8 bytes shorter).
/// Fails if the integrity check does not hold (the wrong key, or damage).
pub fn aesUnwrap(kek: *const [16]u8, wrapped: []const u8, out: []u8) error{BadKeyWrap}!void {
    if (wrapped.len < 24 or wrapped.len % 8 != 0) return error.BadKeyWrap;
    const n = wrapped.len / 8 - 1;
    const ctx = Aes128.initDec(kek.*);
    var a = wrapped[0..8].*;
    @memcpy(out[0 .. n * 8], wrapped[8..][0 .. n * 8]);
    var j: usize = 6;
    while (j > 0) {
        j -= 1;
        var i = n;
        while (i > 0) : (i -= 1) {
            const t: u64 = @intCast(n * j + i);
            var b: [16]u8 = undefined;
            std.mem.writeInt(u64, b[0..8], std.mem.readInt(u64, &a, .big) ^ t, .big);
            @memcpy(b[8..16], out[(i - 1) * 8 ..][0..8]);
            ctx.decrypt(&b, &b);
            a = b[0..8].*;
            @memcpy(out[(i - 1) * 8 ..][0..8], b[8..16]);
        }
    }
    if (!std.crypto.timing_safe.eql([8]u8, a, wrap_iv)) return error.BadKeyWrap;
}

// --- EAPOL-Key frames -----------------------------------------------------------

/// Key information bits.
pub const info = struct {
    /// Key descriptor version 2: HMAC-SHA1-128 MIC, AES key wrap.
    pub const version_aes: u16 = 2;
    pub const version_mask: u16 = 0x7;
    pub const pairwise: u16 = 1 << 3;
    pub const install: u16 = 1 << 6;
    pub const ack: u16 = 1 << 7;
    pub const mic: u16 = 1 << 8;
    pub const secure: u16 = 1 << 9;
    pub const @"error": u16 = 1 << 10;
    pub const request: u16 = 1 << 11;
    pub const encrypted: u16 = 1 << 12;
};

const eapol_key = 3;
const descriptor_rsn = 2;
/// The EAPOL header (4 bytes) and the key descriptor up to its data.
pub const header_len = 4 + 95;
const mic_at = 4 + 77;

pub const KeyFrame = struct {
    /// The whole frame, for checking its MIC.
    raw: []const u8,
    eapol_version: u8,
    info: u16,
    key_length: u16,
    replay: u64,
    nonce: Nonce,
    rsc: [8]u8,
    mic: [16]u8,
    data: []const u8,

    pub fn parse(frame: []const u8) ?KeyFrame {
        if (frame.len < header_len or frame[1] != eapol_key or frame[4] != descriptor_rsn) return null;
        const body_len = std.mem.readInt(u16, frame[2..4], .big);
        if (4 + @as(usize, body_len) > frame.len) return null;
        const raw = frame[0 .. 4 + body_len];
        const data_len = std.mem.readInt(u16, raw[97..99], .big);
        if (header_len + @as(usize, data_len) > raw.len) return null;
        return .{
            .raw = raw,
            .eapol_version = raw[0],
            .info = std.mem.readInt(u16, raw[5..7], .big),
            .key_length = std.mem.readInt(u16, raw[7..9], .big),
            .replay = std.mem.readInt(u64, raw[9..17], .big),
            .nonce = raw[17..49].*,
            .rsc = raw[65..73].*,
            .mic = raw[mic_at..][0..16].*,
            .data = raw[header_len..][0..data_len],
        };
    }

    /// Whether the frame's MIC is right for this KCK.
    pub fn micValid(f: *const KeyFrame, kck: *const [16]u8) bool {
        var copy: [2048]u8 = undefined;
        if (f.raw.len > copy.len) return false;
        @memcpy(copy[0..f.raw.len], f.raw);
        @memset(copy[mic_at..][0..16], 0);
        return std.crypto.timing_safe.eql([16]u8, mic(kck, copy[0..f.raw.len]), f.mic);
    }
};

/// Builds an EAPOL-Key frame into `buf`, with its MIC if `kck` is given.
pub fn buildKeyFrame(buf: []u8, eapol_version: u8, key_info: u16, key_length: u16, replay: u64, nonce: Nonce, data: []const u8, kck: ?*const [16]u8) []const u8 {
    const len = header_len + data.len;
    const f = buf[0..len];
    @memset(f, 0);
    f[0] = eapol_version;
    f[1] = eapol_key;
    std.mem.writeInt(u16, f[2..4], @intCast(len - 4), .big);
    f[4] = descriptor_rsn;
    std.mem.writeInt(u16, f[5..7], key_info, .big);
    std.mem.writeInt(u16, f[7..9], key_length, .big);
    std.mem.writeInt(u64, f[9..17], replay, .big);
    @memcpy(f[17..49], &nonce);
    std.mem.writeInt(u16, f[97..99], @intCast(data.len), .big);
    @memcpy(f[header_len..], data);
    if (kck) |k| f[mic_at..][0..16].* = mic(k, f);
    return f;
}

/// The RSN element the station sends (in its association request and in
/// message 2): version 1, the network's group cipher, CCMP for pairwise,
/// PSK key management and no capabilities.
pub fn rsnElement(buf: *[22]u8, group_cipher: u32) []const u8 {
    buf.* = .{
        48, 20,
        1,  0,
        0,  0,
        0,    0, // group cipher, below
        1,    0,
        0x00, 0x0f,
        0xac, 4,
        1,    0,
        0x00, 0x0f,
        0xac, 2,
        0,    0,
    };
    std.mem.writeInt(u32, buf[4..8], group_cipher, .big);
    return buf;
}

// --- The handshakes -------------------------------------------------------------

pub const GroupKey = struct {
    index: u2,
    key: [32]u8,
    len: u8,
    /// The receive sequence counter to start from (6 bytes, little-endian).
    rsc: [6]u8,
};

/// What to do after a frame.
pub const Actions = struct {
    /// A frame to send to the access point.
    reply: ?[]const u8 = null,
    /// The pairwise key to install (CCMP), after sending the reply.
    pairwise: ?[16]u8 = null,
    group: ?GroupKey = null,
    /// The 4-way handshake has finished: the connection may carry traffic.
    complete: bool = false,
};

pub const Error = error{BadKeyWrap};

pub const Handshake = struct {
    pmk: [32]u8,
    /// The access point's and our addresses.
    aa: Mac,
    spa: Mac,
    /// Our RSN element, and the one the access point advertised.
    own_rsn: []const u8,
    ap_rsn: []const u8,
    /// The network's group cipher (for swapping a TKIP group key's MIC keys).
    group_cipher: u32,
    anonce: ?Nonce = null,
    snonce: Nonce = undefined,
    ptk: ?Ptk = null,
    /// The last replay counter accepted (frames must count up).
    replay: ?u64 = null,
    /// How many times message 1 came: more than once without message 3
    /// usually means the passphrase is wrong (the access point did not
    /// accept message 2's MIC).
    message1_count: u32 = 0,
    complete: bool = false,
    /// Frames are built here.
    out: [256]u8 = undefined,

    /// Handles an EAPOL frame from the access point; fills in what to do.
    /// Frames that are not for us, or fail their checks, are dropped (as
    /// the standard says), leaving `actions` empty.
    pub fn handle(h: *Handshake, frame: []const u8, random: *const fn ([]u8) void, actions: *Actions) void {
        actions.* = .{};
        const k = KeyFrame.parse(frame) orelse return;
        if (k.info & info.version_mask != info.version_aes or k.info & info.ack == 0) return;
        if (h.replay) |r| if (k.replay <= r and k.info & info.mic != 0) return;
        if (k.info & info.pairwise != 0) {
            if (k.info & info.mic == 0) h.message1(&k, random, actions) else h.message3(&k, actions) catch {};
        } else h.groupMessage1(&k, actions) catch {};
    }

    /// Message 1: the ANonce. Answered with message 2.
    fn message1(h: *Handshake, k: *const KeyFrame, random: *const fn ([]u8) void, actions: *Actions) void {
        h.message1_count += 1;
        // A repeated message 1 with the same nonce gets the same answer.
        if (h.anonce == null or !std.mem.eql(u8, &h.anonce.?, &k.nonce)) {
            h.anonce = k.nonce;
            random(&h.snonce);
            h.ptk = derivePtk(&h.pmk, h.aa, h.spa, k.nonce, h.snonce);
        }
        h.replay = k.replay;
        actions.reply = buildKeyFrame(&h.out, k.eapol_version, info.version_aes | info.pairwise | info.mic, 0, k.replay, h.snonce, h.own_rsn, &h.ptk.?.kck);
    }

    /// Message 3: checked, and its GTK taken; answered with message 4, then
    /// the keys are installed.
    fn message3(h: *Handshake, k: *const KeyFrame, actions: *Actions) Error!void {
        const ptk = h.ptk orelse return;
        const anonce = h.anonce orelse return;
        if (!std.mem.eql(u8, &k.nonce, &anonce)) return;
        if (k.info & info.install == 0 or k.info & info.encrypted == 0) return;
        if (!k.micValid(&ptk.kck)) return;
        h.replay = k.replay;
        var plain: [512]u8 = undefined;
        if (k.data.len > plain.len + 8) return;
        try aesUnwrap(&ptk.kek, k.data, &plain);
        const kd = parseKeyData(plain[0 .. k.data.len - 8]);
        // The RSN element must be the one advertised (else something
        // between us changed the beacon: a downgrade).
        if (h.ap_rsn.len > 0) {
            const rsn = kd.rsn orelse return;
            if (!std.mem.eql(u8, rsn, h.ap_rsn)) return;
        }
        actions.reply = buildKeyFrame(&h.out, k.eapol_version, info.version_aes | info.pairwise | info.mic | info.secure, 0, k.replay, @splat(0), &.{}, &ptk.kck);
        actions.pairwise = ptk.tk;
        if (kd.gtk) |g| actions.group = h.groupKey(g, k.rsc);
        actions.complete = true;
        h.complete = true;
    }

    /// The group key handshake's message 1: a new GTK.
    fn groupMessage1(h: *Handshake, k: *const KeyFrame, actions: *Actions) Error!void {
        if (!h.complete) return;
        const ptk = h.ptk orelse return;
        if (k.info & info.mic == 0 or k.info & info.encrypted == 0) return;
        if (!k.micValid(&ptk.kck)) return;
        h.replay = k.replay;
        var plain: [512]u8 = undefined;
        if (k.data.len > plain.len + 8) return;
        try aesUnwrap(&ptk.kek, k.data, &plain);
        const g = parseKeyData(plain[0 .. k.data.len - 8]).gtk orelse return;
        actions.reply = buildKeyFrame(&h.out, k.eapol_version, info.version_aes | info.mic | info.secure, 0, k.replay, @splat(0), &.{}, &ptk.kck);
        actions.group = h.groupKey(g, k.rsc);
    }

    fn groupKey(h: *const Handshake, g: Gtk, rsc: [8]u8) ?GroupKey {
        if (g.key.len > 32) return null;
        var out: GroupKey = .{ .index = g.index, .key = @splat(0), .len = @intCast(g.key.len), .rsc = rsc[0..6].* };
        @memcpy(out.key[0..g.key.len], g.key);
        // A TKIP key's two Michael keys are given from the access point's
        // side: the station's transmit key is its receive key.
        if (h.group_cipher == cipher_tkip and g.key.len == 32) {
            var t: [8]u8 = undefined;
            @memcpy(&t, out.key[16..24]);
            @memcpy(out.key[16..24], out.key[24..32]);
            @memcpy(out.key[24..32], &t);
        }
        return out;
    }
};

const Gtk = struct { index: u2, key: []const u8 };

const KeyData = struct {
    rsn: ?[]const u8 = null,
    gtk: ?Gtk = null,
};

/// The RSN element and GTK from (decrypted) key data: elements and key
/// data encapsulations (KDEs: element 0xdd, OUI 00-0F-AC, a type).
fn parseKeyData(data: []const u8) KeyData {
    var out: KeyData = .{};
    var at: usize = 0;
    while (at + 2 <= data.len) {
        const id = data[at];
        const len = data[at + 1];
        // Padding: 0xdd then zeros.
        if (id == 0xdd and len == 0) break;
        if (at + 2 + len > data.len) break;
        const body = data[at + 2 ..][0..len];
        if (id == 48) out.rsn = data[at..][0 .. 2 + len];
        if (id == 0xdd and len >= 6 and std.mem.eql(u8, body[0..3], &.{ 0x00, 0x0f, 0xac }) and body[3] == 1) {
            out.gtk = .{ .index = @truncate(body[4] & 3), .key = body[6..] };
        }
        at += 2 + len;
    }
    return out;
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "the PMK from a passphrase (IEEE 802.11 test vector)" {
    try testing.expectEqual(hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"), pmkFromPassphrase("password", "IEEE"));
    try testing.expect(validPassphrase("password"));
    try testing.expect(!validPassphrase("short"));
    try testing.expect(!validPassphrase("tab\there!"));
    try testing.expect(!validPassphrase("x" ** 64));
}

test "the PTK (checked against the PRF computed independently)" {
    var pmk: [32]u8 = undefined;
    for (&pmk, 0..) |*b, i| b.* = @intCast(i);
    const ptk = derivePtk(&pmk, .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 }, .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, @splat(0x10), @splat(0x20));
    const want = hex("ba31c9396d09a0218791ff4da3664cc357becee157146cb9c9265b06c75e81a9a464f11b8e2048ac8fba2f8a0bf77739");
    try testing.expectEqual(want[0..16].*, ptk.kck);
    try testing.expectEqual(want[16..32].*, ptk.kek);
    try testing.expectEqual(want[32..48].*, ptk.tk);
    // The same whichever way round the addresses and nonces are.
    const swapped = derivePtk(&pmk, .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 }, @splat(0x20), @splat(0x10));
    try testing.expectEqual(ptk.tk, swapped.tk);
}

test "AES key wrap (RFC 3394 test vector)" {
    const kek = hex("000102030405060708090A0B0C0D0E0F");
    const key = hex("00112233445566778899AABBCCDDEEFF");
    var wrapped: [24]u8 = undefined;
    aesWrap(&kek, &key, &wrapped);
    try testing.expectEqual(hex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5"), wrapped);
    var back: [16]u8 = undefined;
    try aesUnwrap(&kek, &wrapped, &back);
    try testing.expectEqual(key, back);
    wrapped[3] ^= 1;
    try testing.expectError(error.BadKeyWrap, aesUnwrap(&kek, &wrapped, &back));
}

/// The access point's side, for testing the supplicant against.
const Authenticator = struct {
    pmk: [32]u8,
    aa: Mac,
    spa: Mac,
    rsn: []const u8,
    gtk: [16]u8,
    anonce: Nonce = @splat(0x5a),
    replay: u64 = 1,
    ptk: ?Ptk = null,
    buf: [512]u8 = undefined,

    fn message1(a: *Authenticator) []const u8 {
        return buildKeyFrame(&a.buf, 2, info.version_aes | info.pairwise | info.ack, 16, a.replay, a.anonce, &.{}, null);
    }

    /// Checks message 2 and answers with message 3 (null if the MIC is
    /// wrong: a wrong passphrase).
    fn message3(a: *Authenticator, m2: []const u8) ?[]const u8 {
        const k = KeyFrame.parse(m2) orelse return null;
        a.ptk = derivePtk(&a.pmk, a.aa, a.spa, a.anonce, k.nonce);
        if (!k.micValid(&a.ptk.?.kck)) return null;
        return a.encrypted(info.version_aes | info.pairwise | info.ack | info.mic | info.install | info.secure | info.encrypted, true);
    }

    fn groupMessage1(a: *Authenticator) []const u8 {
        return a.encrypted(info.version_aes | info.ack | info.mic | info.secure | info.encrypted, false);
    }

    fn encrypted(a: *Authenticator, key_info: u16, with_rsn: bool) []const u8 {
        a.replay += 1;
        var plain: [64]u8 = undefined;
        var n: usize = 0;
        if (with_rsn) {
            @memcpy(plain[0..a.rsn.len], a.rsn);
            n = a.rsn.len;
        }
        const kde = [_]u8{ 0xdd, 22, 0x00, 0x0f, 0xac, 1, 1, 0 };
        @memcpy(plain[n..][0..kde.len], &kde);
        n += kde.len;
        @memcpy(plain[n..][0..16], &a.gtk);
        n += 16;
        // Padded to a multiple of 8 with 0xdd and zeros.
        if (n % 8 != 0) {
            plain[n] = 0xdd;
            n += 1;
            while (n % 8 != 0) : (n += 1) plain[n] = 0;
        }
        var wrapped: [72]u8 = undefined;
        aesWrap(&a.ptk.?.kek, plain[0..n], wrapped[0 .. n + 8]);
        var f = buildKeyFrame(&a.buf, 2, key_info, 16, a.replay, a.anonce, wrapped[0 .. n + 8], null);
        // RSC 5 for the group key.
        const m = a.buf[0..f.len];
        m[65] = 5;
        m[mic_at..][0..16].* = mic(&a.ptk.?.kck, m);
        f = m;
        return f;
    }
};

fn testRandom(buf: []u8) void {
    @memset(buf, 0x77);
}

fn pair(passphrase: []const u8) struct { Handshake, Authenticator } {
    var rsn_buf: [22]u8 = undefined;
    _ = rsnElement(&rsn_buf, cipher_ccmp);
    const S = struct {
        var rsn: [22]u8 = undefined;
    };
    S.rsn = rsn_buf;
    const aa: Mac = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const spa: Mac = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    return .{
        .{ .pmk = pmkFromPassphrase(passphrase, "Home"), .aa = aa, .spa = spa, .own_rsn = &S.rsn, .ap_rsn = &S.rsn, .group_cipher = cipher_ccmp },
        .{ .pmk = pmkFromPassphrase("correct horse", "Home"), .aa = aa, .spa = spa, .rsn = &S.rsn, .gtk = @splat(0x42) },
    };
}

test "the 4-way handshake with an access point that knows the passphrase" {
    var s, var ap = pair("correct horse");
    var act: Actions = .{};
    s.handle(ap.message1(), testRandom, &act);
    const m2 = act.reply.?;
    try testing.expect(act.pairwise == null and !act.complete);
    var m2_copy: [256]u8 = undefined;
    @memcpy(m2_copy[0..m2.len], m2);
    const m3 = ap.message3(m2_copy[0..m2.len]).?;
    var m3_copy: [512]u8 = undefined;
    @memcpy(m3_copy[0..m3.len], m3);
    s.handle(m3_copy[0..m3.len], testRandom, &act);
    try testing.expect(act.complete);
    // Both sides have the same keys.
    try testing.expectEqual(ap.ptk.?.tk, act.pairwise.?);
    try testing.expectEqual(@as(u2, 1), act.group.?.index);
    try testing.expectEqualSlices(u8, &ap.gtk, act.group.?.key[0..act.group.?.len]);
    try testing.expectEqual([6]u8{ 5, 0, 0, 0, 0, 0 }, act.group.?.rsc);
    // Message 4: MIC, secure, no nonce, valid for the access point.
    const m4 = KeyFrame.parse(act.reply.?).?;
    try testing.expect(m4.info & info.secure != 0 and m4.info & info.pairwise != 0);
    try testing.expect(m4.micValid(&ap.ptk.?.kck));

    // A replayed message 3 is dropped.
    s.handle(m3_copy[0..m3.len], testRandom, &act);
    try testing.expect(act.reply == null);

    // A new group key later.
    const g1 = ap.groupMessage1();
    var g1_copy: [512]u8 = undefined;
    @memcpy(g1_copy[0..g1.len], g1);
    ap.gtk = @splat(0x43);
    s.handle(g1_copy[0..g1.len], testRandom, &act);
    try testing.expect(act.group != null and act.pairwise == null);
    try testing.expect(KeyFrame.parse(act.reply.?).?.micValid(&ap.ptk.?.kck));
}

test "a wrong passphrase: the access point repeats message 1" {
    var s, var ap = pair("wrong horse");
    var act: Actions = .{};
    s.handle(ap.message1(), testRandom, &act);
    try testing.expect(ap.message3(act.reply.?) == null);
    s.handle(ap.message1(), testRandom, &act);
    try testing.expectEqual(@as(u32, 2), s.message1_count);
    try testing.expect(!s.complete);
}

test "a message 3 whose RSN element differs from the beacon's is refused" {
    var s, var ap = pair("correct horse");
    var other: [22]u8 = undefined;
    _ = rsnElement(&other, cipher_tkip);
    s.ap_rsn = &other;
    var act: Actions = .{};
    s.handle(ap.message1(), testRandom, &act);
    var m2: [256]u8 = undefined;
    @memcpy(m2[0..act.reply.?.len], act.reply.?);
    const m3 = ap.message3(m2[0..act.reply.?.len]).?;
    s.handle(m3, testRandom, &act);
    try testing.expect(!act.complete and act.reply == null);
}

test "TKIP group keys have their Michael keys swapped" {
    var s, _ = pair("x");
    s.group_cipher = cipher_tkip;
    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    const g = s.groupKey(.{ .index = 2, .key = &key }, @splat(0)).?;
    try testing.expectEqualSlices(u8, key[0..16], g.key[0..16]);
    try testing.expectEqualSlices(u8, key[24..32], g.key[16..24]);
    try testing.expectEqualSlices(u8, key[16..24], g.key[24..32]);
}
