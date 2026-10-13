//! The WPA supplicant: the station's side of WPA2-Personal and WPA3-Personal
//! authentication and key handshakes (IEEE 802.11-2020 12.4 and 12.7), as
//! 802.11 Authentication and EAPOL-Key frames in and out. It has no I/O of
//! its own: the network manager hands it the frames that arrive and sends and
//! installs what it says.
//!
//! Joining a WPA2-Personal or WPA3-Personal network:
//!
//! 1. For WPA2 (PSK), the pairwise master key (PMK) is the passphrase
//!    stretched with PBKDF2-SHA1 over the SSID, 4096 rounds
//!    (`pmkFromPassphrase`). For WPA3 (SAE), the station and access point
//!    derive a shared PMK and PMKID with Simultaneous Authentication of
//!    Equals (`Sae`, Dragonfly over NIST P-256, group 19) in two 802.11
//!    Authentication messages (Commit and Confirm) before association.
//! 2. After association, the access point sends message 1 of the 4-way
//!    handshake with its nonce (ANonce). The supplicant picks its own
//!    (SNonce) and derives the pairwise transient key (PTK) from both
//!    nonces, both addresses and the PMK (using PRF-SHA1 for WPA2-PSK, or
//!    KDF-SHA-256 for WPA3-SAE and WPA2-PSK-SHA256): a key confirmation key
//!    (KCK, for the MIC that proves each side knows the PMK), a key
//!    encryption key (KEK, for the group key) and the temporal key (TK,
//!    which encrypts the traffic). It answers with message 2: its nonce, its
//!    RSN element and a MIC.
//! 3. Message 3 proves the access point knows the PMK too (its MIC), repeats
//!    the RSN element it advertised (so a downgrade would show) and carries
//!    the group temporal key (GTK, for broadcasts) and optional integrity
//!    group temporal key (IGTK, for management frame protection), wrapped
//!    with the KEK (AES key wrap). Message 4 acknowledges it; then both
//!    sides install the keys.
//! 4. The access point replaces the GTK from time to time with the group key
//!    handshake: one message carrying the new GTK, and an acknowledgement.

const std = @import("std");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Aes128 = std.crypto.core.aes.Aes128;
const P256 = std.crypto.ecc.P256;

pub const Mac = [6]u8;
pub const Nonce = [32]u8;

/// Cipher suites, as nl80211 names them (OUI 00-0F-AC and the type).
pub const cipher_tkip: u32 = 0x000fac02;
pub const cipher_ccmp: u32 = 0x000fac04;
/// Group management cipher suite: BIP-CMAC-128 (IEEE 802.11w).
pub const cipher_bip_cmac_128: u32 = 0x000fac06;
/// Key management suites: PSK (SHA-1), PSK-SHA256, and SAE (WPA3-Personal).
pub const akm_psk: u32 = 0x000fac02;
pub const akm_psk_sha256: u32 = 0x000fac06;
pub const akm_sae: u32 = 0x000fac08;

/// RSN Capability bits (IEEE 802.11-2020 9.4.2.24.4).
pub const rsn_cap_mfpr: u16 = 1 << 6;
pub const rsn_cap_mfpc: u16 = 1 << 7;

// --- Keys -----------------------------------------------------------------------

/// The pairwise master key from a passphrase (8 to 63 characters) and the
/// network's SSID.
pub fn pmkFromPassphrase(passphrase: []const u8, ssid: []const u8) [32]u8 {
    var pmk: [32]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&pmk, passphrase, ssid, 4096, HmacSha1) catch unreachable;
    return pmk;
}

/// Whether a passphrase is one WPA2/WPA3 accepts: 8 to 63 printable ASCII
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

/// The 802.11 SHA-256 key derivation function (IEEE 802.11-2020 12.7.1.7.2):
/// `out.len` bytes from `key`, `label` and `context`, using 16-bit
/// little-endian iteration counter (starting at 1) and bit length `L`.
pub fn kdfSha256(out: []u8, key: []const u8, label: []const u8, context: []const u8) void {
    const bit_len: u16 = @intCast(out.len * 8);
    var len_le: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_le, bit_len, .little);
    var counter: u16 = 1;
    var at: usize = 0;
    while (at < out.len) : (counter += 1) {
        var cnt_le: [2]u8 = undefined;
        std.mem.writeInt(u16, &cnt_le, counter, .little);
        var h = HmacSha256.init(key);
        h.update(&cnt_le);
        h.update(label);
        h.update(context);
        h.update(&len_le);
        var block: [HmacSha256.mac_length]u8 = undefined;
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

fn ptkContext(aa: Mac, spa: Mac, anonce: Nonce, snonce: Nonce) [6 + 6 + 32 + 32]u8 {
    var data: [6 + 6 + 32 + 32]u8 = undefined;
    const a_first = std.mem.order(u8, &aa, &spa) == .lt;
    @memcpy(data[0..6], if (a_first) &aa else &spa);
    @memcpy(data[6..12], if (a_first) &spa else &aa);
    const n_first = std.mem.order(u8, &anonce, &snonce) == .lt;
    @memcpy(data[12..44], if (n_first) &anonce else &snonce);
    @memcpy(data[44..76], if (n_first) &snonce else &anonce);
    return data;
}

/// The pairwise transient key for CCMP (WPA2-PSK, SHA-1 PRF).
pub fn derivePtk(pmk: *const [32]u8, aa: Mac, spa: Mac, anonce: Nonce, snonce: Nonce) Ptk {
    const data = ptkContext(aa, spa, anonce, snonce);
    var out: [48]u8 = undefined;
    prf(&out, pmk, "Pairwise key expansion", &data);
    return .{ .kck = out[0..16].*, .kek = out[16..32].*, .tk = out[32..48].* };
}

/// The pairwise transient key for CCMP with SHA-256 KDF (SAE and PSK-SHA256).
pub fn derivePtkSha256(pmk: *const [32]u8, aa: Mac, spa: Mac, anonce: Nonce, snonce: Nonce) Ptk {
    const data = ptkContext(aa, spa, anonce, snonce);
    var out: [48]u8 = undefined;
    kdfSha256(&out, pmk, "Pairwise key expansion", &data);
    return .{ .kck = out[0..16].*, .kek = out[16..32].*, .tk = out[32..48].* };
}

/// The EAPOL-Key MIC (key descriptor version 2): HMAC-SHA1 over the frame
/// with its MIC field zeroed, cut to 16 bytes.
pub fn mic(kck: *const [16]u8, frame: []const u8) [16]u8 {
    var full: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&full, frame, kck);
    return full[0..16].*;
}

/// The EAPOL-Key MIC for AKM 00-0F-AC:6 and 00-0F-AC:8 (SAE): HMAC-SHA256
/// over the frame with its MIC field zeroed, cut to 16 bytes (128 bits).
pub fn micSha256(kck: *const [16]u8, frame: []const u8) [16]u8 {
    var full: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&full, frame, kck);
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

// --- SAE (WPA3-Personal, IEEE 802.11-2020 12.4) ---------------------------------

/// NIST P-256 (IANA Group 19) field prime p, in big-endian bytes.
const p256_prime_be = [32]u8{
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

/// 802.11 authentication algorithm number for SAE.
pub const auth_alg_sae: u16 = 3;
/// 802.11 status codes used in SAE authentication frames.
pub const status_success: u16 = 0;
pub const status_anti_clogging_token_req: u16 = 76;
pub const status_sae_hash_to_element: u16 = 126;

/// Derives the SAE Password Element (PWE) on NIST P-256 (group 19) using the
/// Hunting-and-Pecking algorithm (IEEE 802.11-2020 12.4.4.2.2), running a
/// fixed 40 iterations in constant time.
pub fn derivePwe(password: []const u8, addr1: Mac, addr2: Mac) P256 {
    var salt: [12]u8 = undefined;
    const a1_bigger = std.mem.order(u8, &addr1, &addr2) == .gt;
    @memcpy(salt[0..6], if (a1_bigger) &addr1 else &addr2);
    @memcpy(salt[6..12], if (a1_bigger) &addr2 else &addr1);

    var found: u1 = 0;
    var chosen_x = P256.Fe.zero;
    var chosen_odd: u1 = 0;
    const dummy_seed: [32]u8 = @splat(0x5a);

    var counter: u8 = 1;
    while (counter <= 40) : (counter += 1) {
        var h = HmacSha256.init(&salt);
        h.update(password);
        h.update(&.{counter});
        var pwd_seed: [32]u8 = undefined;
        h.final(&pwd_seed);
        const odd: u1 = @truncate(pwd_seed[31] & 1);
        for (&pwd_seed, dummy_seed) |*b, d| {
            b.* ^= (b.* ^ d) *% found;
        }
        var pwd_value: [32]u8 = undefined;
        kdfSha256(&pwd_value, &pwd_seed, "SAE Hunting and Pecking", &p256_prime_be);
        if (P256.Fe.fromBytes(pwd_value, .big)) |x| {
            const rhs = x.sq().mul(x).sub(x).sub(x).sub(x).add(P256.B);
            const is_sq: u1 = @intFromBool(rhs.isSquare());
            const take: u1 = is_sq & ~found;
            chosen_x.cMov(x, take);
            chosen_odd ^= (chosen_odd ^ odd) & take;
            found |= is_sq;
        } else |_| {}
    }
    const y = P256.recoverY(chosen_x, chosen_odd == 1) catch return P256.basePoint;
    return .{ .x = chosen_x, .y = y, .z = P256.Fe.one };
}

/// Samples a random scalar in 2..r-1 for P-256.
fn randomScalar(random: *const fn ([]u8) void) P256.scalar.Scalar {
    while (true) {
        var raw: [48]u8 = undefined;
        random(&raw);
        const s = P256.scalar.Scalar.fromBytes48(raw, .little);
        if (!s.isZero() and !s.equivalent(P256.scalar.Scalar.one)) return s;
    }
}

/// Simultaneous Authentication of Equals (SAE, Dragonfly over NIST P-256,
/// group 19) for WPA3-Personal.
pub const Sae = struct {
    pub const group_id: u16 = 19;
    pub const commit_len = 2 + 32 + 64;
    pub const confirm_len = 2 + 32;

    pwe: P256,
    rand: P256.scalar.Scalar,
    mask: P256.scalar.Scalar,
    own_scalar: [32]u8,
    own_element: [64]u8,
    peer_scalar: [32]u8 = @splat(0),
    peer_element: [64]u8 = @splat(0),
    kck: [32]u8 = @splat(0),
    pmk: [32]u8 = @splat(0),
    pmkid: [16]u8 = @splat(0),
    send_confirm: u16 = 0,
    committed: bool = false,
    confirmed: bool = false,

    /// Prepares a fresh SAE session and generates our Commit scalar and element.
    pub fn init(password: []const u8, sta: Mac, ap: Mac, random: *const fn ([]u8) void) Sae {
        const pwe = derivePwe(password, sta, ap);
        const r = randomScalar(random);
        const m = randomScalar(random);
        const scalar = r.add(m).toBytes(.big);
        // COMMIT-ELEMENT = -(mask * PWE) = mask * (-PWE).
        const elem_pt = pwe.neg().mul(m.toBytes(.big), .big) catch P256.basePoint;
        const aff = elem_pt.affineCoordinates();
        var elem: [64]u8 = undefined;
        elem[0..32].* = aff.x.toBytes(.big);
        elem[32..64].* = aff.y.toBytes(.big);
        return .{
            .pwe = pwe,
            .rand = r,
            .mask = m,
            .own_scalar = scalar,
            .own_element = elem,
        };
    }

    /// Writes the body of an SAE Commit frame (after the 802.11 Authentication
    /// header's alg=3, seq=1, status=0): group 19, optional anti-clogging
    /// token, our 32-byte scalar and 64-byte element.
    pub fn writeCommit(s: *const Sae, out: []u8, token: []const u8) []const u8 {
        std.mem.writeInt(u16, out[0..2], group_id, .little);
        var pos: usize = 2;
        if (token.len > 0) {
            @memcpy(out[pos..][0..token.len], token);
            pos += token.len;
        }
        @memcpy(out[pos..][0..32], &s.own_scalar);
        pos += 32;
        @memcpy(out[pos..][0..64], &s.own_element);
        pos += 64;
        return out[0..pos];
    }

    /// Processes the peer's SAE Commit frame body (starting at Group ID) and
    /// derives KCK, PMK, and PMKID. Returns false if the group is not 19, the
    /// scalar/element are invalid, or a reflection attack is detected.
    pub fn processCommit(s: *Sae, body: []const u8) bool {
        if (body.len < commit_len) return false;
        if (std.mem.readInt(u16, body[0..2], .little) != group_id) return false;
        const p_scalar_bytes = body[2..34].*;
        const p_elem_bytes = body[34..98].*;
        // Reflection check: peer's commit must not equal our own.
        if (std.mem.eql(u8, &p_scalar_bytes, &s.own_scalar) and std.mem.eql(u8, &p_elem_bytes, &s.own_element)) return false;

        const p_scalar = P256.scalar.Scalar.fromBytes(p_scalar_bytes, .big) catch return false;
        if (p_scalar.isZero() or p_scalar.equivalent(P256.scalar.Scalar.one)) return false;
        const p_elem = P256.fromSerializedAffineCoordinates(p_elem_bytes[0..32].*, p_elem_bytes[32..64].*, .big) catch return false;
        p_elem.rejectIdentity() catch return false;

        // K = rand * (peer_scalar * PWE + PEER_ELEMENT).
        const sp = s.pwe.mul(p_scalar_bytes, .big) catch return false;
        const sum = sp.add(p_elem);
        const k_pt = sum.mul(s.rand.toBytes(.big), .big) catch return false;
        const k_x = k_pt.affineCoordinates().x.toBytes(.big);

        const zero_key: [32]u8 = @splat(0);
        var keyseed: [32]u8 = undefined;
        HmacSha256.create(&keyseed, &k_x, &zero_key);

        const own_s = P256.scalar.Scalar.fromBytes(s.own_scalar, .big) catch return false;
        const context = own_s.add(p_scalar).toBytes(.big);

        var kck_pmk: [64]u8 = undefined;
        kdfSha256(&kck_pmk, &keyseed, "SAE KCK and PMK", &context);
        s.kck = kck_pmk[0..32].*;
        s.pmk = kck_pmk[32..64].*;
        s.pmkid = context[0..16].*;
        s.peer_scalar = p_scalar_bytes;
        s.peer_element = p_elem_bytes;
        s.committed = true;
        return true;
    }

    fn computeConfirm(kck: *const [32]u8, send_confirm: u16, s1: *const [32]u8, e1: *const [64]u8, s2: *const [32]u8, e2: *const [64]u8) [32]u8 {
        var sc: [2]u8 = undefined;
        std.mem.writeInt(u16, &sc, send_confirm, .little);
        var h = HmacSha256.init(kck);
        h.update(&sc);
        h.update(s1);
        h.update(e1);
        h.update(s2);
        h.update(e2);
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    /// Writes the body of an SAE Confirm frame (send-confirm + 32-byte HMAC).
    pub fn writeConfirm(s: *Sae, out: *[confirm_len]u8) []const u8 {
        s.send_confirm +%= 1;
        std.mem.writeInt(u16, out[0..2], s.send_confirm, .little);
        out[2..34].* = computeConfirm(&s.kck, s.send_confirm, &s.own_scalar, &s.own_element, &s.peer_scalar, &s.peer_element);
        return out[0..];
    }

    /// Verifies the peer's SAE Confirm frame body (send-confirm + 32-byte HMAC).
    pub fn processConfirm(s: *Sae, body: []const u8) bool {
        if (!s.committed or body.len < confirm_len) return false;
        const peer_sc = std.mem.readInt(u16, body[0..2], .little);
        const expected = computeConfirm(&s.kck, peer_sc, &s.peer_scalar, &s.peer_element, &s.own_scalar, &s.own_element);
        if (!std.crypto.timing_safe.eql([32]u8, expected, body[2..34].*)) return false;
        s.confirmed = true;
        return true;
    }

    /// Builds a complete 802.11 Authentication management frame (24-byte
    /// header + 6-byte auth header + body).
    pub fn buildAuthFrame(out: []u8, da: Mac, sa: Mac, bssid: Mac, seq: u16, status: u16, body: []const u8) []const u8 {
        @memset(out[0..24], 0);
        out[0] = 0xb0; // Subtype: Authentication
        @memcpy(out[4..10], &da);
        @memcpy(out[10..16], &sa);
        @memcpy(out[16..22], &bssid);
        std.mem.writeInt(u16, out[24..26], auth_alg_sae, .little);
        std.mem.writeInt(u16, out[26..28], seq, .little);
        std.mem.writeInt(u16, out[28..30], status, .little);
        @memcpy(out[30..][0..body.len], body);
        return out[0 .. 30 + body.len];
    }
};

// --- EAPOL-Key frames -----------------------------------------------------------

/// Key information bits.
pub const info = struct {
    /// Key descriptor version 0: AKM-defined MIC and key wrap (used by SAE).
    pub const version_akm: u16 = 0;
    /// Key descriptor version 2: HMAC-SHA1-128 MIC, AES key wrap.
    pub const version_aes: u16 = 2;
    /// Key descriptor version 3: AES-128-CMAC / HMAC-SHA256-128 MIC, AES key wrap.
    pub const version_sha256: u16 = 3;
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

    /// Whether the frame's MIC is right for this KCK (HMAC-SHA1-128).
    pub fn micValid(f: *const KeyFrame, kck: *const [16]u8) bool {
        return f.micValidWith(kck, false);
    }

    /// Whether the frame's MIC is right for this KCK, using HMAC-SHA256-128
    /// when `sha256` is true or HMAC-SHA1-128 when false.
    pub fn micValidWith(f: *const KeyFrame, kck: *const [16]u8, sha256: bool) bool {
        var copy: [2048]u8 = undefined;
        if (f.raw.len > copy.len) return false;
        @memcpy(copy[0..f.raw.len], f.raw);
        @memset(copy[mic_at..][0..16], 0);
        const want = if (sha256) micSha256(kck, copy[0..f.raw.len]) else mic(kck, copy[0..f.raw.len]);
        return std.crypto.timing_safe.eql([16]u8, want, f.mic);
    }
};

/// Builds an EAPOL-Key frame into `buf`, with its MIC if `kck` is given.
pub fn buildKeyFrame(buf: []u8, eapol_version: u8, key_info: u16, key_length: u16, replay: u64, nonce: Nonce, data: []const u8, kck: ?*const [16]u8) []const u8 {
    return buildKeyFrameWith(buf, eapol_version, key_info, key_length, replay, nonce, data, kck, false);
}

pub fn buildKeyFrameWith(buf: []u8, eapol_version: u8, key_info: u16, key_length: u16, replay: u64, nonce: Nonce, data: []const u8, kck: ?*const [16]u8, sha256: bool) []const u8 {
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
    if (kck) |k| f[mic_at..][0..16].* = if (sha256) micSha256(k, f) else mic(k, f);
    return f;
}

/// The RSN element the station sends for WPA2 (in its association request and
/// in message 2): version 1, the network's group cipher, CCMP for pairwise,
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

/// The RSN element the station sends for WPA3-SAE (or WPA2 with MFP/SHA256):
/// version 1, group cipher, CCMP pairwise, `akm` (`akm_sae`, `akm_psk_sha256`
/// or `akm_psk`), RSN capabilities (MFPC and MFPR when management frame
/// protection is used), optional PMKID, and BIP-CMAC-128 group management
/// cipher suite when MFP is enabled.
pub fn rsnElementEx(buf: *[44]u8, group_cipher: u32, akm: u32, mfp_capable: bool, mfp_required: bool, pmkid: ?[16]u8) []const u8 {
    if (akm == akm_psk and !mfp_capable and !mfp_required and pmkid == null) {
        return rsnElement(buf[0..22], group_cipher);
    }
    buf[0] = 48;
    std.mem.writeInt(u16, buf[2..4], 1, .little);
    std.mem.writeInt(u32, buf[4..8], group_cipher, .big);
    std.mem.writeInt(u16, buf[8..10], 1, .little);
    std.mem.writeInt(u32, buf[10..14], cipher_ccmp, .big);
    std.mem.writeInt(u16, buf[14..16], 1, .little);
    std.mem.writeInt(u32, buf[16..20], akm, .big);
    var caps: u16 = 0;
    if (mfp_capable or mfp_required) caps |= rsn_cap_mfpc;
    if (mfp_required) caps |= rsn_cap_mfpr;
    std.mem.writeInt(u16, buf[20..22], caps, .little);
    var pos: usize = 22;
    if (pmkid) |id| {
        std.mem.writeInt(u16, buf[pos..][0..2], 1, .little);
        pos += 2;
        @memcpy(buf[pos..][0..16], &id);
        pos += 16;
    } else if (mfp_capable or mfp_required) {
        std.mem.writeInt(u16, buf[pos..][0..2], 0, .little);
        pos += 2;
    }
    if (mfp_capable or mfp_required) {
        std.mem.writeInt(u32, buf[pos..][0..4], cipher_bip_cmac_128, .big);
        pos += 4;
    }
    buf[1] = @intCast(pos - 2);
    return buf[0..pos];
}

// --- The handshakes -------------------------------------------------------------

pub const GroupKey = struct {
    index: u2,
    key: [32]u8,
    len: u8,
    /// The receive sequence counter to start from (6 bytes, little-endian).
    rsc: [6]u8,
};

/// Integrity Group Temporal Key (IGTK) for Management Frame Protection (802.11w).
pub const Igtk = struct {
    /// Key ID (typically 4 or 5).
    index: u8,
    ipn: [6]u8,
    key: [16]u8,
};

/// What to do after a frame.
pub const Actions = struct {
    /// A frame to send to the access point.
    reply: ?[]const u8 = null,
    /// The pairwise key to install (CCMP), after sending the reply.
    pairwise: ?[16]u8 = null,
    group: ?GroupKey = null,
    igtk: ?Igtk = null,
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
    /// The negotiated key management suite (`akm_psk`, `akm_psk_sha256`, or `akm_sae`).
    akm: u32 = akm_psk,
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

    fn usesSha256(h: *const Handshake) bool {
        return h.akm == akm_sae or h.akm == akm_psk_sha256;
    }

    fn validVersion(h: *const Handshake, ver: u16) bool {
        return switch (h.akm) {
            akm_sae => ver == info.version_akm or ver == info.version_sha256 or ver == info.version_aes,
            akm_psk_sha256 => ver == info.version_sha256 or ver == info.version_akm,
            else => ver == info.version_aes,
        };
    }

    /// Updates the access point's address and RSN element; drops any PTK
    /// derived for another address.
    pub fn setAp(h: *Handshake, aa: Mac, ap_rsn: []const u8) void {
        if (!std.mem.eql(u8, &h.aa, &aa)) {
            h.aa = aa;
            h.anonce = null;
            h.ptk = null;
        }
        if (ap_rsn.len > 0) h.ap_rsn = ap_rsn;
    }

    /// Handles an EAPOL frame from the access point; fills in what to do.
    /// Frames that are not for us, or fail their checks, are dropped (as
    /// the standard says), leaving `actions` empty.
    pub fn handle(h: *Handshake, frame: []const u8, random: *const fn ([]u8) void, actions: *Actions) void {
        actions.* = .{};
        const k = KeyFrame.parse(frame) orelse return;
        if (!h.validVersion(k.info & info.version_mask) or k.info & info.ack == 0) return;
        if (h.replay) |r| if (k.replay <= r and k.info & info.mic != 0) return;
        if (k.info & info.pairwise != 0) {
            if (k.info & info.mic == 0) h.message1(&k, random, actions) else h.message3(&k, actions) catch {};
        } else h.groupMessage1(&k, actions) catch {};
    }

    /// Message 1: the ANonce. Answered with message 2.
    fn message1(h: *Handshake, k: *const KeyFrame, random: *const fn ([]u8) void, actions: *Actions) void {
        h.message1_count += 1;
        const sha256 = h.usesSha256();
        // A repeated message 1 with the same nonce gets the same answer.
        if (h.anonce == null or !std.mem.eql(u8, &h.anonce.?, &k.nonce)) {
            h.anonce = k.nonce;
            random(&h.snonce);
            h.ptk = if (sha256)
                derivePtkSha256(&h.pmk, h.aa, h.spa, k.nonce, h.snonce)
            else
                derivePtk(&h.pmk, h.aa, h.spa, k.nonce, h.snonce);
        }
        h.replay = k.replay;
        const ver = k.info & info.version_mask;
        actions.reply = buildKeyFrameWith(&h.out, k.eapol_version, ver | info.pairwise | info.mic, 0, k.replay, h.snonce, h.own_rsn, &h.ptk.?.kck, sha256);
    }

    /// Message 3: checked, and its GTK taken; answered with message 4, then
    /// the keys are installed.
    fn message3(h: *Handshake, k: *const KeyFrame, actions: *Actions) Error!void {
        const ptk = h.ptk orelse return;
        const anonce = h.anonce orelse return;
        if (!std.mem.eql(u8, &k.nonce, &anonce)) return;
        if (k.info & info.install == 0 or k.info & info.encrypted == 0) return;
        const sha256 = h.usesSha256();
        if (!k.micValidWith(&ptk.kck, sha256)) return;
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
        const ver = k.info & info.version_mask;
        actions.reply = buildKeyFrameWith(&h.out, k.eapol_version, ver | info.pairwise | info.mic | info.secure, 0, k.replay, @splat(0), &.{}, &ptk.kck, sha256);
        actions.pairwise = ptk.tk;
        if (kd.gtk) |g| actions.group = h.groupKey(g, k.rsc);
        actions.igtk = kd.igtk;
        actions.complete = true;
        h.complete = true;
    }

    /// The group key handshake's message 1: a new GTK.
    fn groupMessage1(h: *Handshake, k: *const KeyFrame, actions: *Actions) Error!void {
        if (!h.complete) return;
        const ptk = h.ptk orelse return;
        if (k.info & info.mic == 0 or k.info & info.encrypted == 0) return;
        const sha256 = h.usesSha256();
        if (!k.micValidWith(&ptk.kck, sha256)) return;
        h.replay = k.replay;
        var plain: [512]u8 = undefined;
        if (k.data.len > plain.len + 8) return;
        try aesUnwrap(&ptk.kek, k.data, &plain);
        const kd = parseKeyData(plain[0 .. k.data.len - 8]);
        const g = kd.gtk orelse return;
        const ver = k.info & info.version_mask;
        actions.reply = buildKeyFrameWith(&h.out, k.eapol_version, ver | info.mic | info.secure, 0, k.replay, @splat(0), &.{}, &ptk.kck, sha256);
        actions.group = h.groupKey(g, k.rsc);
        actions.igtk = kd.igtk;
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
    igtk: ?Igtk = null,
};

/// The RSN element, GTK and IGTK from (decrypted) key data: elements and key
/// data encapsulations (KDEs: element 0xdd, OUI 00-0F-AC, a type: 1 for GTK,
/// 9 for IGTK).
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
        if (id == 48 and out.rsn == null) out.rsn = data[at..][0 .. 2 + len];
        if (id == 0xdd and len >= 6 and std.mem.eql(u8, body[0..3], &.{ 0x00, 0x0f, 0xac })) {
            if (body[3] == 1) {
                out.gtk = .{ .index = @truncate(body[4] & 3), .key = body[6..] };
            } else if (body[3] == 9 and len >= 4 + 2 + 6 + 16) {
                // IGTK KDE (IEEE 802.11-2020 Figure 12-42): Key ID (2 bytes LE),
                // IPN (6 bytes), and 16-byte IGTK (for BIP-CMAC-128).
                const key_id = std.mem.readInt(u16, body[4..6], .little);
                if (key_id <= 0xff) {
                    out.igtk = .{
                        .index = @intCast(key_id),
                        .ipn = body[6..12].*,
                        .key = body[12..28].*,
                    };
                }
            }
        }
        at += 2 + len;
    }
    return out;
}

/// The access point's side of a station's WPA2/WPA3 4-way handshake.
pub const Authenticator = struct {
    pmk: [32]u8,
    aa: Mac,
    spa: Mac,
    rsn: []const u8,
    gtk: [16]u8,
    igtk: ?[16]u8 = null,
    akm: u32 = akm_psk,
    rsc: u8 = 0,
    anonce: Nonce = @splat(0x5a),
    replay: u64 = 1,
    ptk: ?Ptk = null,
    complete: bool = false,
    buf: [512]u8 = undefined,

    fn usesSha256(a: *const Authenticator) bool {
        return a.akm == akm_sae or a.akm == akm_psk_sha256;
    }

    fn descriptorVersion(a: *const Authenticator) u16 {
        return switch (a.akm) {
            akm_sae => info.version_akm,
            akm_psk_sha256 => info.version_sha256,
            else => info.version_aes,
        };
    }

    /// Picks a fresh ANonce and builds message 1 of the 4-way handshake.
    pub fn start(a: *Authenticator, random: *const fn ([]u8) void) []const u8 {
        random(&a.anonce);
        a.replay = 1;
        a.ptk = null;
        a.complete = false;
        return a.message1();
    }

    pub fn message1(a: *Authenticator) []const u8 {
        return buildKeyFrameWith(&a.buf, 2, a.descriptorVersion() | info.pairwise | info.ack, 16, a.replay, a.anonce, &.{}, null, a.usesSha256());
    }

    /// Checks message 2 and answers with message 3 (null if the MIC is
    /// wrong: a wrong passphrase).
    pub fn message3(a: *Authenticator, m2: []const u8) ?[]const u8 {
        const k = KeyFrame.parse(m2) orelse return null;
        const sha256 = a.usesSha256();
        a.ptk = if (sha256)
            derivePtkSha256(&a.pmk, a.aa, a.spa, a.anonce, k.nonce)
        else
            derivePtk(&a.pmk, a.aa, a.spa, a.anonce, k.nonce);
        if (!k.micValidWith(&a.ptk.?.kck, sha256)) return null;
        return a.encrypted(a.descriptorVersion() | info.pairwise | info.ack | info.mic | info.install | info.secure | info.encrypted, true);
    }

    pub fn groupMessage1(a: *Authenticator) []const u8 {
        return a.encrypted(a.descriptorVersion() | info.ack | info.mic | info.secure | info.encrypted, false);
    }

    /// Handles an EAPOL-Key frame (message 2 or message 4) from the station.
    pub fn handle(a: *Authenticator, frame: []const u8, actions: *Actions) void {
        actions.* = .{};
        const k = KeyFrame.parse(frame) orelse return;
        if (k.info & info.version_mask != a.descriptorVersion()) return;
        if (k.info & info.pairwise == 0 or k.info & info.mic == 0 or k.info & info.ack != 0) return;
        if (k.replay != a.replay) return;
        if (k.info & info.secure == 0) {
            if (a.message3(frame)) |m3| actions.reply = m3;
        } else {
            const ptk = a.ptk orelse return;
            if (!k.micValidWith(&ptk.kck, a.usesSha256())) return;
            actions.pairwise = ptk.tk;
            actions.complete = true;
            a.complete = true;
        }
    }

    fn encrypted(a: *Authenticator, key_info: u16, with_rsn: bool) []const u8 {
        a.replay += 1;
        var plain: [128]u8 = undefined;
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
        if (a.igtk) |igtk| {
            const igtk_kde = [_]u8{ 0xdd, 28, 0x00, 0x0f, 0xac, 9, 4, 0, 0, 0, 0, 0, 0, 0 };
            @memcpy(plain[n..][0..igtk_kde.len], &igtk_kde);
            n += igtk_kde.len;
            @memcpy(plain[n..][0..16], &igtk);
            n += 16;
        }
        // Padded to a multiple of 8 with 0xdd and zeros.
        if (n % 8 != 0) {
            plain[n] = 0xdd;
            n += 1;
            while (n % 8 != 0) : (n += 1) plain[n] = 0;
        }
        var wrapped: [136]u8 = undefined;
        aesWrap(&a.ptk.?.kek, plain[0..n], wrapped[0 .. n + 8]);
        const sha256 = a.usesSha256();
        var f = buildKeyFrameWith(&a.buf, 2, key_info, 16, a.replay, a.anonce, wrapped[0 .. n + 8], null, sha256);
        const m = a.buf[0..f.len];
        m[65] = a.rsc;
        m[mic_at..][0..16].* = if (sha256) micSha256(&a.ptk.?.kck, m) else mic(&a.ptk.?.kck, m);
        f = m;
        return f;
    }
};

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
        .{ .pmk = pmkFromPassphrase("correct horse", "Home"), .aa = aa, .spa = spa, .rsn = &S.rsn, .gtk = @splat(0x42), .rsc = 5 },
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

test "Authenticator.start and Authenticator.handle complete the 4-way handshake" {
    var s, var ap = pair("correct horse");
    var sta_act: Actions = .{};
    var ap_act: Actions = .{};

    const m1 = ap.start(testRandom);
    var m1_copy: [256]u8 = undefined;
    @memcpy(m1_copy[0..m1.len], m1);
    s.handle(m1_copy[0..m1.len], testRandom, &sta_act);
    try testing.expect(sta_act.reply != null and !sta_act.complete);

    var m2_copy: [256]u8 = undefined;
    const m2_len = sta_act.reply.?.len;
    @memcpy(m2_copy[0..m2_len], sta_act.reply.?);
    ap.handle(m2_copy[0..m2_len], &ap_act);
    try testing.expect(ap_act.reply != null and !ap_act.complete);

    var m3_copy: [256]u8 = undefined;
    const m3_len = ap_act.reply.?.len;
    @memcpy(m3_copy[0..m3_len], ap_act.reply.?);
    s.handle(m3_copy[0..m3_len], testRandom, &sta_act);
    try testing.expect(sta_act.complete and sta_act.reply != null);

    var m4_copy: [256]u8 = undefined;
    const m4_len = sta_act.reply.?.len;
    @memcpy(m4_copy[0..m4_len], sta_act.reply.?);
    ap.handle(m4_copy[0..m4_len], &ap_act);
    try testing.expect(ap_act.complete);
    try testing.expectEqual(sta_act.pairwise.?, ap_act.pairwise.?);
}

test "setAp invalidates cached PTK when the access point BSSID changes" {
    var s, var ap = pair("correct horse");
    // Suppose the station initially had a different BSSID from the scan,
    // processed message 1 early, and then learned the real BSSID.
    s.aa = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    var act: Actions = .{};
    const m1 = ap.message1();
    var m1_copy: [256]u8 = undefined;
    @memcpy(m1_copy[0..m1.len], m1);
    s.handle(m1_copy[0..m1.len], testRandom, &act);
    try testing.expect(ap.message3(act.reply.?) == null);

    s.setAp(ap.aa, ap.rsn);
    s.handle(m1_copy[0..m1.len], testRandom, &act);
    var m2_copy: [256]u8 = undefined;
    const m2_len = act.reply.?.len;
    @memcpy(m2_copy[0..m2_len], act.reply.?);
    const m3 = ap.message3(m2_copy[0..m2_len]).?;
    s.handle(m3, testRandom, &act);
    try testing.expect(act.complete);
}

test "WPA3-Personal: SAE Commit/Confirm exchange followed by SHA-256 4-way handshake and IGTK" {
    const sta_mac: Mac = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    const ap_mac: Mac = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 };

    // PWE derivation is symmetric in MAC order and produces a valid point on P-256.
    const pwe1 = derivePwe("correct horse", sta_mac, ap_mac);
    const pwe2 = derivePwe("correct horse", ap_mac, sta_mac);
    try pwe1.rejectIdentity();
    try testing.expect(pwe1.equivalent(pwe2));

    const Rng = struct {
        var seed: u8 = 1;
        fn fill(buf: []u8) void {
            for (buf) |*b| {
                b.* = seed;
                seed +%= 17;
            }
        }
    };

    var sta_sae = Sae.init("correct horse", sta_mac, ap_mac, Rng.fill);
    var ap_sae = Sae.init("correct horse", ap_mac, sta_mac, Rng.fill);

    var sta_commit_buf: [128]u8 = undefined;
    var ap_commit_buf: [128]u8 = undefined;
    const sta_commit = sta_sae.writeCommit(&sta_commit_buf, &.{});
    const ap_commit = ap_sae.writeCommit(&ap_commit_buf, &.{});

    // Reflection attack (peer sends our own commit back) is rejected.
    try testing.expect(!sta_sae.processCommit(sta_commit));

    try testing.expect(sta_sae.processCommit(ap_commit));
    try testing.expect(ap_sae.processCommit(sta_commit));
    try testing.expectEqual(sta_sae.pmk, ap_sae.pmk);
    try testing.expectEqual(sta_sae.pmkid, ap_sae.pmkid);
    try testing.expectEqual(sta_sae.kck, ap_sae.kck);

    var sta_confirm: [Sae.confirm_len]u8 = undefined;
    var ap_confirm: [Sae.confirm_len]u8 = undefined;
    _ = sta_sae.writeConfirm(&sta_confirm);
    _ = ap_sae.writeConfirm(&ap_confirm);

    try testing.expect(sta_sae.processConfirm(&ap_confirm));
    try testing.expect(ap_sae.processConfirm(&sta_confirm));

    // A wrong password fails Confirm verification.
    var wrong_sae = Sae.init("wrong horse!", sta_mac, ap_mac, Rng.fill);
    var wrong_commit_buf: [128]u8 = undefined;
    const wrong_commit = wrong_sae.writeCommit(&wrong_commit_buf, &.{});
    var ap_sae2 = Sae.init("correct horse", ap_mac, sta_mac, Rng.fill);
    var ap_commit2_buf: [128]u8 = undefined;
    const ap_commit2 = ap_sae2.writeCommit(&ap_commit2_buf, &.{});
    try testing.expect(wrong_sae.processCommit(ap_commit2));
    try testing.expect(ap_sae2.processCommit(wrong_commit));
    var wrong_confirm: [Sae.confirm_len]u8 = undefined;
    _ = wrong_sae.writeConfirm(&wrong_confirm);
    try testing.expect(!ap_sae2.processConfirm(&wrong_confirm));

    // Now run the WPA3-SAE 4-way handshake with the SAE-derived PMK and PMKID.
    var sta_rsn_buf: [44]u8 = undefined;
    const sta_rsn = rsnElementEx(&sta_rsn_buf, cipher_ccmp, akm_sae, true, true, sta_sae.pmkid);
    try testing.expectEqual(@as(usize, 44), sta_rsn.len);

    var ap_rsn_buf: [44]u8 = undefined;
    const ap_rsn = rsnElementEx(&ap_rsn_buf, cipher_ccmp, akm_sae, true, true, null);
    try testing.expectEqual(@as(usize, 28), ap_rsn.len);

    var s: Handshake = .{
        .pmk = sta_sae.pmk,
        .aa = ap_mac,
        .spa = sta_mac,
        .own_rsn = sta_rsn,
        .ap_rsn = ap_rsn,
        .group_cipher = cipher_ccmp,
        .akm = akm_sae,
    };
    var ap: Authenticator = .{
        .pmk = ap_sae.pmk,
        .aa = ap_mac,
        .spa = sta_mac,
        .rsn = ap_rsn,
        .gtk = @splat(0x42),
        .igtk = @splat(0x99),
        .akm = akm_sae,
        .rsc = 7,
    };

    var sta_act: Actions = .{};
    var ap_act: Actions = .{};

    const m1 = ap.start(testRandom);
    var m1_copy: [256]u8 = undefined;
    @memcpy(m1_copy[0..m1.len], m1);
    s.handle(m1_copy[0..m1.len], testRandom, &sta_act);
    try testing.expect(sta_act.reply != null and !sta_act.complete);

    var m2_copy: [256]u8 = undefined;
    const m2_len = sta_act.reply.?.len;
    @memcpy(m2_copy[0..m2_len], sta_act.reply.?);
    ap.handle(m2_copy[0..m2_len], &ap_act);
    try testing.expect(ap_act.reply != null and !ap_act.complete);

    var m3_copy: [256]u8 = undefined;
    const m3_len = ap_act.reply.?.len;
    @memcpy(m3_copy[0..m3_len], ap_act.reply.?);
    s.handle(m3_copy[0..m3_len], testRandom, &sta_act);
    try testing.expect(sta_act.complete and sta_act.reply != null);
    try testing.expectEqual(ap.ptk.?.tk, sta_act.pairwise.?);
    try testing.expectEqual(@as(u8, 4), sta_act.igtk.?.index);
    try testing.expectEqual(@as([16]u8, @splat(0x99)), sta_act.igtk.?.key);

    var m4_copy: [256]u8 = undefined;
    const m4_len = sta_act.reply.?.len;
    @memcpy(m4_copy[0..m4_len], sta_act.reply.?);
    ap.handle(m4_copy[0..m4_len], &ap_act);
    try testing.expect(ap_act.complete);
}

