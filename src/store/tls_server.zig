//! A minimal TLS 1.3 server and X.509v3 certificate generator for serving
//! Dazzle OS updates and apps over HTTPS from the build machine during
//! testing (see tools/serve.zig).
//!
//! `store.Client` trusts the deterministic `Dazzle Test CA` root certificate
//! generated here, and the server signs a leaf certificate on the fly for
//! the SNI host (or IP address) requested by the client.

const std = @import("std");
const linux = std.os.linux;
const tls = std.crypto.tls;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const X25519 = std.crypto.dh.X25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const ca_seed: [32]u8 = "dazzle-test-ca-seed-000000000001".*;
pub const leaf_seed: [32]u8 = "dazzle-test-leaf-seed-0000000002".*;
pub const ca_common_name = "Dazzle Test CA";

pub fn caKeyPair() Ecdsa.KeyPair {
    return Ecdsa.KeyPair.generateDeterministic(ca_seed) catch unreachable;
}

pub fn leafKeyPair() Ecdsa.KeyPair {
    return Ecdsa.KeyPair.generateDeterministic(leaf_seed) catch unreachable;
}

/// Adds the deterministic Dazzle Test CA root certificate to `bundle`.
pub fn addTestCa(bundle: *std.crypto.Certificate.Bundle, gpa: std.mem.Allocator, now_sec: i64) !void {
    const ca_kp = caKeyPair();
    var der_buf: [1024]u8 = undefined;
    const ca_der = try makeCert(&der_buf, ca_common_name, ca_kp.public_key.toUncompressedSec1(), ca_kp, 1, false);
    const decoded_start: u32 = @intCast(bundle.bytes.items.len);
    try bundle.bytes.appendSlice(gpa, ca_der);
    try bundle.parseCert(gpa, decoded_start, now_sec);
}

/// Builds a DER-encoded X.509v3 certificate with `issuer = CN=Dazzle Test CA`
/// and `subject = CN=<subject_cn>`, signed by `issuer_kp` with
/// `ecdsa-with-SHA256`. When `include_san` is true, also adds a
/// `subjectAltName` extension with `dNSName = subject_cn`.
pub fn makeCert(
    out: []u8,
    subject_cn: []const u8,
    subject_pub_sec1: [65]u8,
    issuer_kp: Ecdsa.KeyPair,
    serial: u8,
    include_san: bool,
) ![]const u8 {
    // OID ecdsa-with-SHA256 (1.2.840.10045.4.3.2)
    const sig_alg = [_]u8{ 0x30, 0x0a, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 };
    // Validity: 2020-01-01T00:00:00Z to 2099-12-31T23:59:59Z
    const validity = [_]u8{ 0x30, 0x22, 0x18, 0x0f } ++ "20200101000000Z".* ++ [_]u8{ 0x18, 0x0f } ++ "20991231235959Z".*;
    // SubjectPublicKeyInfo for P-256 uncompressed point
    const spki_hdr = [_]u8{
        0x30, 0x59, // SEQUENCE (89)
        0x30, 0x13, // SEQUENCE (19)
        0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // id-ecPublicKey
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // prime256v1
        0x03, 0x42, 0x00, // BIT STRING (66, 0 unused bits)
    };

    var issuer_buf: [128]u8 = undefined;
    const issuer_der = try encodeName(&issuer_buf, ca_common_name);

    var subject_buf: [320]u8 = undefined;
    const subject_der = try encodeName(&subject_buf, subject_cn);

    var ext_buf: [320]u8 = undefined;
    const ext_der = if (include_san) try encodeSanExtension(&ext_buf, subject_cn) else &[_]u8{};

    var tbs_body: [768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&tbs_body);
    try w.writeAll(&[_]u8{ 0xa0, 0x03, 0x02, 0x01, 0x02 }); // version v3
    try w.writeAll(&[_]u8{ 0x02, 0x01, serial }); // serialNumber
    try w.writeAll(&sig_alg);
    try w.writeAll(issuer_der);
    try w.writeAll(&validity);
    try w.writeAll(subject_der);
    try w.writeAll(&spki_hdr);
    try w.writeAll(&subject_pub_sec1);
    try w.writeAll(ext_der);

    var tbs_buf: [800]u8 = undefined;
    const tbs_der = try wrapTlv(&tbs_buf, 0x30, w.buffered());

    const sig = try issuer_kp.sign(tbs_der, null);
    var sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&sig_der_buf);

    var bit_str_payload: [Ecdsa.Signature.der_encoded_length_max + 1]u8 = undefined;
    bit_str_payload[0] = 0x00;
    @memcpy(bit_str_payload[1 .. 1 + sig_der.len], sig_der);
    var sig_bit_buf: [96]u8 = undefined;
    const sig_bit_der = try wrapTlv(&sig_bit_buf, 0x03, bit_str_payload[0 .. 1 + sig_der.len]);

    var cert_body: [960]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cert_body);
    try cw.writeAll(tbs_der);
    try cw.writeAll(&sig_alg);
    try cw.writeAll(sig_bit_der);
    return wrapTlv(out, 0x30, cw.buffered());
}

fn encodeName(out: []u8, cn: []const u8) ![]const u8 {
    var utf8_buf: [260]u8 = undefined;
    const utf8_der = try wrapTlv(&utf8_buf, 0x0c, cn);
    var atv_body: [268]u8 = undefined;
    @memcpy(atv_body[0..5], &[_]u8{ 0x06, 0x03, 0x55, 0x04, 0x03 }); // OID commonName
    @memcpy(atv_body[5 .. 5 + utf8_der.len], utf8_der);
    var atv_buf: [276]u8 = undefined;
    const atv_der = try wrapTlv(&atv_buf, 0x30, atv_body[0 .. 5 + utf8_der.len]);
    var rdn_buf: [284]u8 = undefined;
    const rdn_der = try wrapTlv(&rdn_buf, 0x31, atv_der);
    return wrapTlv(out, 0x30, rdn_der);
}

fn encodeSanExtension(out: []u8, dns_name: []const u8) ![]const u8 {
    var gn_buf: [260]u8 = undefined;
    const gn_der = try wrapTlv(&gn_buf, 0x82, dns_name); // [2] dNSName
    var gns_buf: [268]u8 = undefined;
    const gns_der = try wrapTlv(&gns_buf, 0x30, gn_der); // GeneralNames SEQUENCE
    var oct_buf: [276]u8 = undefined;
    const oct_der = try wrapTlv(&oct_buf, 0x04, gns_der); // extnValue OCTET STRING
    var ext_body: [284]u8 = undefined;
    @memcpy(ext_body[0..5], &[_]u8{ 0x06, 0x03, 0x55, 0x1D, 0x11 }); // OID subjectAltName
    @memcpy(ext_body[5 .. 5 + oct_der.len], oct_der);
    var ext_seq_buf: [292]u8 = undefined;
    const ext_seq = try wrapTlv(&ext_seq_buf, 0x30, ext_body[0 .. 5 + oct_der.len]);
    var exts_seq_buf: [300]u8 = undefined;
    const exts_seq = try wrapTlv(&exts_seq_buf, 0x30, ext_seq);
    return wrapTlv(out, 0xa3, exts_seq); // [3] EXPLICIT Extensions
}

fn wrapTlv(out: []u8, tag: u8, body: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    try w.writeByte(tag);
    if (body.len < 0x80) {
        try w.writeByte(@intCast(body.len));
    } else if (body.len <= 0xff) {
        try w.writeAll(&[_]u8{ 0x81, @intCast(body.len) });
    } else if (body.len <= 0xffff) {
        try w.writeAll(&[_]u8{ 0x82, @intCast(body.len >> 8), @intCast(body.len & 0xff) });
    } else return error.Overflow;
    try w.writeAll(body);
    return w.buffered();
}

const SelectedCipher = enum {
    aes_128_gcm,
    chacha20_poly1305,
};

/// A TLS 1.3 server connection over a connected socket fd.
pub const Conn = struct {
    fd: linux.fd_t,
    cipher: SelectedCipher,
    client_key: [32]u8 = undefined,
    server_key: [32]u8 = undefined,
    client_iv: [12]u8,
    server_iv: [12]u8,
    read_seq: u64 = 0,
    write_seq: u64 = 0,

    pub fn handshake(fd: linux.fd_t, default_host: []const u8) !Conn {
        // 1. Read ClientHello record
        var hdr: [5]u8 = undefined;
        try readExact(fd, &hdr);
        if (hdr[0] != @intFromEnum(tls.ContentType.handshake)) return error.TlsUnexpectedMessage;
        const rec_len = std.mem.readInt(u16, hdr[3..5], .big);
        if (rec_len > 16384 or rec_len < 4) return error.TlsRecordOverflow;
        var ch_buf: [16384]u8 = undefined;
        const ch = ch_buf[0..rec_len];
        try readExact(fd, ch);
        if (ch[0] != @intFromEnum(tls.HandshakeType.client_hello)) return error.TlsUnexpectedMessage;
        const ch_len = std.mem.readInt(u24, ch[1..4], .big);
        if (4 + @as(usize, ch_len) != ch.len) return error.TlsDecodeError;

        var d = tls.Decoder.fromTheirSlice(ch[4..]);
        try d.ensure(2 + 32 + 1);
        _ = d.decode(u16); // legacy_version
        _ = d.array(32); // client_random
        const sess_id_len = d.decode(u8);
        try d.ensure(sess_id_len + 2);
        const sess_id = d.slice(sess_id_len);
        const suites_len = d.decode(u16);
        try d.ensure(suites_len + 1);
        const suites_bytes = d.slice(suites_len);

        var chosen_suite: tls.CipherSuite = .AES_128_GCM_SHA256;
        var chosen_cipher: SelectedCipher = .aes_128_gcm;
        var si: usize = 0;
        while (si + 2 <= suites_bytes.len) : (si += 2) {
            const suite: tls.CipherSuite = @enumFromInt(std.mem.readInt(u16, suites_bytes[si..][0..2], .big));
            if (suite == .AES_128_GCM_SHA256) {
                chosen_suite = .AES_128_GCM_SHA256;
                chosen_cipher = .aes_128_gcm;
                break;
            } else if (suite == .CHACHA20_POLY1305_SHA256) {
                chosen_suite = .CHACHA20_POLY1305_SHA256;
                chosen_cipher = .chacha20_poly1305;
                break;
            }
        }

        const comp_len = d.decode(u8);
        try d.ensure(comp_len + 2);
        d.skip(comp_len);
        const exts_len = d.decode(u16);
        var extsd = try d.sub(exts_len);

        var sni_host: []const u8 = default_host;
        var client_x25519: ?[32]u8 = null;

        while (!extsd.eof()) {
            try extsd.ensure(4);
            const et = extsd.decode(tls.ExtensionType);
            const elen = extsd.decode(u16);
            var ed = try extsd.sub(elen);
            switch (et) {
                .server_name => {
                    if (elen >= 5) {
                        try ed.ensure(3);
                        _ = ed.decode(u16); // list len
                        const name_type = ed.decode(u8);
                        if (name_type == 0) {
                            try ed.ensure(2);
                            const nlen = ed.decode(u16);
                            try ed.ensure(nlen);
                            const host_slice = ed.slice(nlen);
                            if (host_slice.len > 0) sni_host = host_slice;
                        }
                    }
                },
                .key_share => {
                    try ed.ensure(2);
                    const shares_len = ed.decode(u16);
                    var sd = try ed.sub(shares_len);
                    while (!sd.eof()) {
                        try sd.ensure(4);
                        const group = sd.decode(tls.NamedGroup);
                        const klen = sd.decode(u16);
                        try sd.ensure(klen);
                        const kslice = sd.slice(klen);
                        if (group == .x25519 and klen == 32) {
                            client_x25519 = kslice[0..32].*;
                        }
                    }
                },
                else => {},
            }
        }

        const peer_pub = client_x25519 orelse return error.TlsIllegalParameter;
        const server_x25519 = X25519.KeyPair.generateDeterministic("dazzle-test-x25519-ephemeral-key".*) catch unreachable;
        const shared_secret = try X25519.scalarmult(server_x25519.secret_key, peer_pub);

        var transcript = Sha256.init(.{});
        transcript.update(ch);

        // 2. Build and send ServerHello + ChangeCipherSpec
        const server_random = "dazzle-test-server-random-bytes!".*;
        const sh_exts = tls.extension(.supported_versions, tls.int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_3))) ++
            tls.extension(.key_share, tls.int(u16, @intFromEnum(tls.NamedGroup.x25519)) ++ tls.int(u16, 32) ++ server_x25519.public_key);

        var sh_body_buf: [256]u8 = undefined;
        var shw: std.Io.Writer = .fixed(&sh_body_buf);
        try shw.writeAll(&tls.int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)));
        try shw.writeAll(&server_random);
        try shw.writeByte(@intCast(sess_id.len));
        try shw.writeAll(sess_id);
        try shw.writeAll(&tls.int(u16, @intFromEnum(chosen_suite)));
        try shw.writeByte(0); // compression null
        try shw.writeAll(&tls.int(u16, sh_exts.len));
        try shw.writeAll(&sh_exts);
        const sh_body = shw.buffered();

        var sh_hs_buf: [260]u8 = undefined;
        sh_hs_buf[0] = @intFromEnum(tls.HandshakeType.server_hello);
        std.mem.writeInt(u24, sh_hs_buf[1..4], @intCast(sh_body.len), .big);
        @memcpy(sh_hs_buf[4 .. 4 + sh_body.len], sh_body);
        const sh_hs = sh_hs_buf[0 .. 4 + sh_body.len];
        transcript.update(sh_hs);

        var sh_rec: [5 + 260 + 6]u8 = undefined;
        sh_rec[0] = @intFromEnum(tls.ContentType.handshake);
        std.mem.writeInt(u16, sh_rec[1..3], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
        std.mem.writeInt(u16, sh_rec[3..5], @intCast(sh_hs.len), .big);
        @memcpy(sh_rec[5 .. 5 + sh_hs.len], sh_hs);
        // Append ChangeCipherSpec record so Client.zig transitions to .handshake cipher_state
        const ccs = [_]u8{ @intFromEnum(tls.ContentType.change_cipher_spec), 0x03, 0x03, 0x00, 0x01, 0x01 };
        @memcpy(sh_rec[5 + sh_hs.len ..][0..ccs.len], &ccs);
        try writeAllFd(fd, sh_rec[0 .. 5 + sh_hs.len + ccs.len]);

        // 3. Derive handshake traffic secrets
        const hello_hash = transcript.peek();
        const zeroes = [_]u8{0} ** 32;
        const early_secret = HkdfSha256.extract(&[_]u8{0}, &zeroes);
        const empty_hash = tls.emptyHash(Sha256);
        const hs_derived = tls.hkdfExpandLabel(HkdfSha256, early_secret, "derived", &empty_hash, 32);
        const hs_secret = HkdfSha256.extract(&hs_derived, &shared_secret);
        const ap_derived = tls.hkdfExpandLabel(HkdfSha256, hs_secret, "derived", &empty_hash, 32);
        const master_secret = HkdfSha256.extract(&ap_derived, &zeroes);

        const c_hs_secret = tls.hkdfExpandLabel(HkdfSha256, hs_secret, "c hs traffic", &hello_hash, 32);
        const s_hs_secret = tls.hkdfExpandLabel(HkdfSha256, hs_secret, "s hs traffic", &hello_hash, 32);
        const c_fin_key = tls.hkdfExpandLabel(HkdfSha256, c_hs_secret, "finished", "", 32);
        const s_fin_key = tls.hkdfExpandLabel(HkdfSha256, s_hs_secret, "finished", "", 32);
        const c_hs_iv = tls.hkdfExpandLabel(HkdfSha256, c_hs_secret, "iv", "", 12);
        const s_hs_iv = tls.hkdfExpandLabel(HkdfSha256, s_hs_secret, "iv", "", 12);

        var hs_conn: Conn = .{
            .fd = fd,
            .cipher = chosen_cipher,
            .client_iv = c_hs_iv,
            .server_iv = s_hs_iv,
        };
        switch (chosen_cipher) {
            .aes_128_gcm => {
                hs_conn.client_key[0..16].* = tls.hkdfExpandLabel(HkdfSha256, c_hs_secret, "key", "", 16);
                hs_conn.server_key[0..16].* = tls.hkdfExpandLabel(HkdfSha256, s_hs_secret, "key", "", 16);
            },
            .chacha20_poly1305 => {
                hs_conn.client_key = tls.hkdfExpandLabel(HkdfSha256, c_hs_secret, "key", "", 32);
                hs_conn.server_key = tls.hkdfExpandLabel(HkdfSha256, s_hs_secret, "key", "", 32);
            },
        }

        // 4. Send EncryptedExtensions, Certificate, CertificateVerify, Finished
        const ee_hs = [_]u8{ @intFromEnum(tls.HandshakeType.encrypted_extensions), 0x00, 0x00, 0x02, 0x00, 0x00 };
        transcript.update(&ee_hs);
        try hs_conn.writeRecord(.handshake, &ee_hs);

        const ca_kp = caKeyPair();
        const leaf_kp = leafKeyPair();
        var cert_der_buf: [1024]u8 = undefined;
        const leaf_der = try makeCert(&cert_der_buf, sni_host, leaf_kp.public_key.toUncompressedSec1(), ca_kp, 2, true);

        var cert_hs_buf: [1100]u8 = undefined;
        var cw: std.Io.Writer = .fixed(&cert_hs_buf);
        try cw.writeByte(@intFromEnum(tls.HandshakeType.certificate));
        const certs_list_len: u24 = @intCast(3 + leaf_der.len + 2);
        try cw.writeAll(&tls.int(u24, 1 + 3 + certs_list_len));
        try cw.writeByte(0); // cert_request_context_len
        try cw.writeAll(&tls.int(u24, certs_list_len));
        try cw.writeAll(&tls.int(u24, @intCast(leaf_der.len)));
        try cw.writeAll(leaf_der);
        try cw.writeAll(&[_]u8{ 0x00, 0x00 }); // extensions
        const cert_hs = cw.buffered();
        transcript.update(cert_hs);
        try hs_conn.writeRecord(.handshake, cert_hs);

        const cv_prefix = " " ** 64 ++ "TLS 1.3, server CertificateVerify\x00";
        const cv_hash = transcript.peek();
        var cv_msg: [cv_prefix.len + 32]u8 = undefined;
        @memcpy(cv_msg[0..cv_prefix.len], cv_prefix);
        @memcpy(cv_msg[cv_prefix.len..], &cv_hash);
        const cv_sig = try leaf_kp.sign(&cv_msg, null);
        var cv_sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const cv_sig_der = cv_sig.toDer(&cv_sig_der_buf);

        var cv_hs_buf: [128]u8 = undefined;
        var cvw: std.Io.Writer = .fixed(&cv_hs_buf);
        try cvw.writeByte(@intFromEnum(tls.HandshakeType.certificate_verify));
        try cvw.writeAll(&tls.int(u24, @intCast(4 + cv_sig_der.len)));
        try cvw.writeAll(&tls.int(u16, @intFromEnum(tls.SignatureScheme.ecdsa_secp256r1_sha256)));
        try cvw.writeAll(&tls.int(u16, @intCast(cv_sig_der.len)));
        try cvw.writeAll(cv_sig_der);
        const cv_hs = cvw.buffered();
        transcript.update(cv_hs);
        try hs_conn.writeRecord(.handshake, cv_hs);

        const fin_digest = transcript.peek();
        const s_verify = tls.hmac(HmacSha256, &fin_digest, s_fin_key);
        var fin_hs: [4 + 32]u8 = undefined;
        fin_hs[0] = @intFromEnum(tls.HandshakeType.finished);
        std.mem.writeInt(u24, fin_hs[1..4], 32, .big);
        @memcpy(fin_hs[4..36], &s_verify);
        transcript.update(&fin_hs);
        try hs_conn.writeRecord(.handshake, &fin_hs);

        const handshake_hash = transcript.finalResult();

        // 5. Read client's ChangeCipherSpec (optional) and encrypted Finished
        var c_fin_buf: [256]u8 = undefined;
        const c_fin = try hs_conn.readHandshakeRecord(&c_fin_buf);
        const expected_c_verify = tls.hmac(HmacSha256, &handshake_hash, c_fin_key);
        if (c_fin.len != 36 or c_fin[0] != @intFromEnum(tls.HandshakeType.finished)) return error.TlsUnexpectedMessage;
        if (!std.crypto.timing_safe.eql([32]u8, expected_c_verify, c_fin[4..36].*)) return error.TlsDecryptError;

        // 6. Derive application traffic keys
        const c_ap_secret = tls.hkdfExpandLabel(HkdfSha256, master_secret, "c ap traffic", &handshake_hash, 32);
        const s_ap_secret = tls.hkdfExpandLabel(HkdfSha256, master_secret, "s ap traffic", &handshake_hash, 32);
        var ap_conn: Conn = .{
            .fd = fd,
            .cipher = chosen_cipher,
            .client_iv = tls.hkdfExpandLabel(HkdfSha256, c_ap_secret, "iv", "", 12),
            .server_iv = tls.hkdfExpandLabel(HkdfSha256, s_ap_secret, "iv", "", 12),
        };
        switch (chosen_cipher) {
            .aes_128_gcm => {
                ap_conn.client_key[0..16].* = tls.hkdfExpandLabel(HkdfSha256, c_ap_secret, "key", "", 16);
                ap_conn.server_key[0..16].* = tls.hkdfExpandLabel(HkdfSha256, s_ap_secret, "key", "", 16);
            },
            .chacha20_poly1305 => {
                ap_conn.client_key = tls.hkdfExpandLabel(HkdfSha256, c_ap_secret, "key", "", 32);
                ap_conn.server_key = tls.hkdfExpandLabel(HkdfSha256, s_ap_secret, "key", "", 32);
            },
        }
        return ap_conn;
    }

    fn readHandshakeRecord(c: *Conn, out: []u8) ![]u8 {
        while (true) {
            var hdr: [5]u8 = undefined;
            try readExact(c.fd, &hdr);
            const rlen = std.mem.readInt(u16, hdr[3..5], .big);
            if (hdr[0] == @intFromEnum(tls.ContentType.change_cipher_spec)) {
                var ccs_buf: [16]u8 = undefined;
                if (rlen > ccs_buf.len) return error.TlsDecodeError;
                try readExact(c.fd, ccs_buf[0..rlen]);
                continue;
            }
            if (hdr[0] != @intFromEnum(tls.ContentType.application_data)) return error.TlsUnexpectedMessage;
            const plain = try c.decryptRecord(hdr, rlen, out);
            if (plain.ct != .handshake) return error.TlsUnexpectedMessage;
            return plain.data;
        }
    }

    pub fn read(c: *Conn, out: []u8) !usize {
        while (true) {
            var hdr: [5]u8 = undefined;
            readExact(c.fd, &hdr) catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => |e| return e,
            };
            const rlen = std.mem.readInt(u16, hdr[3..5], .big);
            if (hdr[0] == @intFromEnum(tls.ContentType.change_cipher_spec)) {
                var ccs_buf: [16]u8 = undefined;
                if (rlen > ccs_buf.len) return error.TlsDecodeError;
                try readExact(c.fd, ccs_buf[0..rlen]);
                continue;
            }
            if (hdr[0] == @intFromEnum(tls.ContentType.alert)) return 0;
            if (hdr[0] != @intFromEnum(tls.ContentType.application_data)) return error.TlsUnexpectedMessage;
            const plain = try c.decryptRecord(hdr, rlen, out);
            switch (plain.ct) {
                .application_data => if (plain.data.len > 0) return plain.data.len,
                .alert => return 0,
                else => {},
            }
        }
    }

    pub fn writeAll(c: *Conn, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const chunk = @min(data.len - off, 16384);
            try c.writeRecord(.application_data, data[off .. off + chunk]);
            off += chunk;
        }
    }

    fn decryptRecord(c: *Conn, hdr: [5]u8, rlen: u16, out: []u8) !struct { ct: tls.ContentType, data: []u8 } {
        if (rlen < 17 or rlen > tls.max_ciphertext_len) return error.TlsRecordOverflow;
        var cipher_buf: [tls.max_ciphertext_len]u8 = undefined;
        try readExact(c.fd, cipher_buf[0..rlen]);
        const ct_len = rlen - 16;
        if (ct_len > out.len) return error.BufferTooSmall;
        const ciphertext = cipher_buf[0..ct_len];
        const tag = cipher_buf[ct_len..rlen][0..16].*;
        const nonce = makeNonce(c.client_iv, c.read_seq);
        c.read_seq += 1;
        switch (c.cipher) {
            .aes_128_gcm => Aes128Gcm.decrypt(out[0..ct_len], ciphertext, tag, &hdr, nonce, c.client_key[0..16].*) catch return error.TlsBadRecordMac,
            .chacha20_poly1305 => ChaCha20Poly1305.decrypt(out[0..ct_len], ciphertext, tag, &hdr, nonce, c.client_key) catch return error.TlsBadRecordMac,
        }
        const trimmed = std.mem.trimEnd(u8, out[0..ct_len], "\x00");
        if (trimmed.len == 0) return error.TlsUnexpectedMessage;
        const inner_ct: tls.ContentType = @enumFromInt(trimmed[trimmed.len - 1]);
        return .{ .ct = inner_ct, .data = out[0 .. trimmed.len - 1] };
    }

    fn writeRecord(c: *Conn, ct: tls.ContentType, data: []const u8) !void {
        if (data.len > 16384) return error.TlsRecordOverflow;
        var clear_buf: [16385]u8 = undefined;
        @memcpy(clear_buf[0..data.len], data);
        clear_buf[data.len] = @intFromEnum(ct);
        const clear = clear_buf[0 .. data.len + 1];

        const rec_len: u16 = @intCast(clear.len + 16);
        var rec_buf: [5 + 16385 + 16]u8 = undefined;
        rec_buf[0] = @intFromEnum(tls.ContentType.application_data);
        std.mem.writeInt(u16, rec_buf[1..3], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
        std.mem.writeInt(u16, rec_buf[3..5], rec_len, .big);
        const hdr = rec_buf[0..5].*;
        const ciphertext = rec_buf[5 .. 5 + clear.len];
        const tag = rec_buf[5 + clear.len ..][0..16];
        const nonce = makeNonce(c.server_iv, c.write_seq);
        c.write_seq += 1;
        switch (c.cipher) {
            .aes_128_gcm => Aes128Gcm.encrypt(ciphertext, tag, clear, &hdr, nonce, c.server_key[0..16].*),
            .chacha20_poly1305 => ChaCha20Poly1305.encrypt(ciphertext, tag, clear, &hdr, nonce, c.server_key),
        }
        try writeAllFd(c.fd, rec_buf[0 .. 5 + rec_len]);
    }
};

fn makeNonce(iv: [12]u8, seq: u64) [12]u8 {
    var nonce = iv;
    var seq_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_bytes, seq, .big);
    for (0..8) |i| nonce[4 + i] ^= seq_bytes[i];
    return nonce;
}

fn readExact(fd: linux.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf[off..].ptr, buf.len - off);
        if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
        if (rc == 0) return error.EndOfStream;
        off += rc;
    }
}

fn writeAllFd(fd: linux.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.write(fd, buf[off..].ptr, buf.len - off);
        if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        if (rc == 0) return error.WriteFailed;
        off += rc;
    }
}
