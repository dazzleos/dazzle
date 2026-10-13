//! IPv4 Network Address Translation (NAT / masquerading) for Wi-Fi hotspot
//! internet sharing, configured over netfilter netlink (`NETLINK_NETFILTER`,
//! subsystem `NFNL_SUBSYS_NFTABLES`).
//!
//! Using `nf_tables` netlink attributes avoids any architecture-specific
//! binary table layouts, so the same 32-bit ARM userspace configures both
//! 32-bit (`kernel.img`, `kernel7.img`) and 64-bit (`kernel8.img` with
//! `CONFIG_COMPAT=y`) kernels without external `iptables` or `nft` binaries.
//!
//! When internet sharing is enabled on a hotspot subnet (`net_addr`/`mask`)
//! with an upstream interface (`out_ifname`), `enableMasquerade` creates the
//! `ip dazzle` table, a `postrouting` base chain (`type nat hook postrouting
//! priority srcnat`), and a rule matching packets from the hotspot subnet
//! leaving on `out_ifname` with the `masquerade` expression. `disableMasquerade`
//! deletes the `ip dazzle` table (and everything in it).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const Ip4 = [4]u8;
pub const Error = sys.Error;

// linux/netlink.h
const netlink_netfilter = 12;
const nlm_f_request = 0x0001;
const nlm_f_ack = 0x0004;
const nlm_f_create = 0x0400;
const nlm_f_append = 0x0800;
const nlmsg_error = 2;
const nlmsg_done = 3;
const nla_f_nested = 0x8000;

// linux/netfilter.h, linux/netfilter_ipv4.h, linux/netfilter/nfnetlink.h
const nfproto_unspec = 0;
const nfproto_ipv4 = 2;
const nf_accept = 1;
const nf_inet_post_routing = 4;
const nf_ip_pri_nat_src: u32 = 100;
const nfnetlink_v0 = 0;
const nfnl_subsys_nftables = 10;
const nfnl_msg_batch_begin = 0x0010;
const nfnl_msg_batch_end = 0x0011;

// linux/netfilter/nf_tables.h
const nft_reg_1 = 1;
const nft_msg_newtable = 0;
const nft_msg_deltable = 2;
const nft_msg_newchain = 3;
const nft_msg_newrule = 6;

const nfta_list_elem = 1;

const nfta_hook_hooknum = 1;
const nfta_hook_priority = 2;

const nfta_table_name = 1;
const nfta_table_flags = 2;

const nfta_chain_table = 1;
const nfta_chain_name = 3;
const nfta_chain_hook = 4;
const nfta_chain_policy = 5;
const nfta_chain_type = 7;

const nfta_rule_table = 1;
const nfta_rule_chain = 2;
const nfta_rule_expressions = 4;

const nfta_data_value = 1;

const nfta_expr_name = 1;
const nfta_expr_data = 2;

const nft_payload_network_header = 1;
const nfta_payload_dreg = 1;
const nfta_payload_base = 2;
const nfta_payload_offset = 3;
const nfta_payload_len = 4;

const nfta_bitwise_sreg = 1;
const nfta_bitwise_dreg = 2;
const nfta_bitwise_len = 3;
const nfta_bitwise_mask = 4;
const nfta_bitwise_xor = 5;

const nft_meta_oifname = 7;
const nfta_meta_dreg = 1;
const nfta_meta_key = 2;

const nft_cmp_eq = 0;
const nfta_cmp_sreg = 1;
const nfta_cmp_op = 2;
const nfta_cmp_data = 3;

const nlmsghdr_len = 16;
const nfgenmsg_len = 4;

pub const table_name = "dazzle";
pub const chain_name = "postrouting";

/// Builds netfilter netlink messages and nested attributes into a buffer.
const Batch = struct {
    buf: []u8,
    len: usize = 0,

    fn beginMsg(b: *Batch, msg_type: u16, flags: u16, seq: u32, family: u8, res_id: u16) usize {
        const start = b.len;
        @memset(b.buf[start .. start + nlmsghdr_len + nfgenmsg_len], 0);
        std.mem.writeInt(u16, b.buf[start + 4 ..][0..2], msg_type, .little);
        std.mem.writeInt(u16, b.buf[start + 6 ..][0..2], flags, .little);
        std.mem.writeInt(u32, b.buf[start + 8 ..][0..4], seq, .little);
        b.buf[start + 16] = family;
        b.buf[start + 17] = nfnetlink_v0;
        std.mem.writeInt(u16, b.buf[start + 18 ..][0..2], res_id, .big);
        b.len = start + nlmsghdr_len + nfgenmsg_len;
        return start;
    }

    fn endMsg(b: *Batch, start: usize) void {
        b.len = std.mem.alignForward(usize, b.len, 4);
        std.mem.writeInt(u32, b.buf[start..][0..4], @intCast(b.len - start), .little);
    }

    fn beginNested(b: *Batch, attr_type: u16) usize {
        const start = b.len;
        std.mem.writeInt(u16, b.buf[start..][0..2], 4, .little);
        std.mem.writeInt(u16, b.buf[start + 2 ..][0..2], attr_type | nla_f_nested, .little);
        b.len = start + 4;
        return start;
    }

    fn endNested(b: *Batch, start: usize) void {
        std.mem.writeInt(u16, b.buf[start..][0..2], @intCast(b.len - start), .little);
        b.len = std.mem.alignForward(usize, b.len, 4);
    }

    fn putAttr(b: *Batch, attr_type: u16, data: []const u8) void {
        const total: u16 = @intCast(4 + data.len);
        std.mem.writeInt(u16, b.buf[b.len..][0..2], total, .little);
        std.mem.writeInt(u16, b.buf[b.len + 2 ..][0..2], attr_type, .little);
        @memcpy(b.buf[b.len + 4 ..][0..data.len], data);
        const aligned = std.mem.alignForward(usize, total, 4);
        @memset(b.buf[b.len + total .. b.len + aligned], 0);
        b.len += aligned;
    }

    fn putStrZ(b: *Batch, attr_type: u16, s: []const u8) void {
        const total: u16 = @intCast(4 + s.len + 1);
        std.mem.writeInt(u16, b.buf[b.len..][0..2], total, .little);
        std.mem.writeInt(u16, b.buf[b.len + 2 ..][0..2], attr_type, .little);
        @memcpy(b.buf[b.len + 4 ..][0..s.len], s);
        b.buf[b.len + 4 + s.len] = 0;
        const aligned = std.mem.alignForward(usize, total, 4);
        @memset(b.buf[b.len + total .. b.len + aligned], 0);
        b.len += aligned;
    }

    fn putBe32(b: *Batch, attr_type: u16, val: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .big);
        b.putAttr(attr_type, &bytes);
    }

    fn putDataValue(b: *Batch, attr_type: u16, data: []const u8) void {
        const nest = b.beginNested(attr_type);
        b.putAttr(nfta_data_value, data);
        b.endNested(nest);
    }
};

fn nftMsgType(msg: u8) u16 {
    return (@as(u16, nfnl_subsys_nftables) << 8) | msg;
}

/// Builds an `nf_tables` transaction batch that creates the `ip dazzle`
/// table, `postrouting` NAT base chain, and masquerading rule for packets
/// from `ap_ip`/`mask` going out on `out_ifname`.
pub fn buildEnableBatch(buf: []u8, base_seq: u32, ap_ip: Ip4, mask: Ip4, out_ifname: []const u8) []const u8 {
    var b: Batch = .{ .buf = buf };
    var seq = base_seq;

    // 1. Batch begin.
    const m_begin = b.beginMsg(nfnl_msg_batch_begin, nlm_f_request, seq, nfproto_unspec, nfnl_subsys_nftables);
    b.endMsg(m_begin);
    seq +%= 1;

    // 2. Create table `ip dazzle`.
    const m_table = b.beginMsg(nftMsgType(nft_msg_newtable), nlm_f_request | nlm_f_create, seq, nfproto_ipv4, 0);
    b.putStrZ(nfta_table_name, table_name);
    b.putBe32(nfta_table_flags, 0);
    b.endMsg(m_table);
    seq +%= 1;

    // 3. Create base chain `postrouting { type nat hook postrouting priority srcnat; policy accept; }`.
    const m_chain = b.beginMsg(nftMsgType(nft_msg_newchain), nlm_f_request | nlm_f_create, seq, nfproto_ipv4, 0);
    b.putStrZ(nfta_chain_table, table_name);
    b.putStrZ(nfta_chain_name, chain_name);
    const hook = b.beginNested(nfta_chain_hook);
    b.putBe32(nfta_hook_hooknum, nf_inet_post_routing);
    b.putBe32(nfta_hook_priority, nf_ip_pri_nat_src);
    b.endNested(hook);
    b.putBe32(nfta_chain_policy, nf_accept);
    b.putStrZ(nfta_chain_type, "nat");
    b.endMsg(m_chain);
    seq +%= 1;

    // 4. Create rule: ip saddr & mask == (ap_ip & mask) oifname == out_ifname masquerade.
    const m_rule = b.beginMsg(nftMsgType(nft_msg_newrule), nlm_f_request | nlm_f_create | nlm_f_append, seq, nfproto_ipv4, 0);
    b.putStrZ(nfta_rule_table, table_name);
    b.putStrZ(nfta_rule_chain, chain_name);
    const exprs = b.beginNested(nfta_rule_expressions);

    // 4a. payload: load IPv4 source address (offset 12, length 4) into reg 1.
    const e_payload = b.beginNested(nfta_list_elem);
    b.putStrZ(nfta_expr_name, "payload");
    const d_payload = b.beginNested(nfta_expr_data);
    b.putBe32(nfta_payload_dreg, nft_reg_1);
    b.putBe32(nfta_payload_base, nft_payload_network_header);
    b.putBe32(nfta_payload_offset, 12);
    b.putBe32(nfta_payload_len, 4);
    b.endNested(d_payload);
    b.endNested(e_payload);

    // 4b. bitwise: reg 1 = (reg 1 & mask) ^ 0.
    const e_bitwise = b.beginNested(nfta_list_elem);
    b.putStrZ(nfta_expr_name, "bitwise");
    const d_bitwise = b.beginNested(nfta_expr_data);
    b.putBe32(nfta_bitwise_sreg, nft_reg_1);
    b.putBe32(nfta_bitwise_dreg, nft_reg_1);
    b.putBe32(nfta_bitwise_len, 4);
    b.putDataValue(nfta_bitwise_mask, &mask);
    b.putDataValue(nfta_bitwise_xor, &.{ 0, 0, 0, 0 });
    b.endNested(d_bitwise);
    b.endNested(e_bitwise);

    // 4c. cmp: reg 1 == (ap_ip & mask).
    const net_addr: Ip4 = .{
        ap_ip[0] & mask[0],
        ap_ip[1] & mask[1],
        ap_ip[2] & mask[2],
        ap_ip[3] & mask[3],
    };
    const e_cmp_ip = b.beginNested(nfta_list_elem);
    b.putStrZ(nfta_expr_name, "cmp");
    const d_cmp_ip = b.beginNested(nfta_expr_data);
    b.putBe32(nfta_cmp_sreg, nft_reg_1);
    b.putBe32(nfta_cmp_op, nft_cmp_eq);
    b.putDataValue(nfta_cmp_data, &net_addr);
    b.endNested(d_cmp_ip);
    b.endNested(e_cmp_ip);

    // 4d. meta: load output interface name (`NFT_META_OIFNAME`) into reg 1.
    const e_meta = b.beginNested(nfta_list_elem);
    b.putStrZ(nfta_expr_name, "meta");
    const d_meta = b.beginNested(nfta_expr_data);
    b.putBe32(nfta_meta_key, nft_meta_oifname);
    b.putBe32(nfta_meta_dreg, nft_reg_1);
    b.endNested(d_meta);
    b.endNested(e_meta);

    // 4e. cmp: reg 1 == out_ifname (16-byte IFNAMSIZ NUL-padded buffer).
    var ifname_buf: [linux.IFNAMESIZE]u8 = @splat(0);
    const ifname_len = @min(out_ifname.len, linux.IFNAMESIZE - 1);
    @memcpy(ifname_buf[0..ifname_len], out_ifname[0..ifname_len]);
    const e_cmp_if = b.beginNested(nfta_list_elem);
    b.putStrZ(nfta_expr_name, "cmp");
    const d_cmp_if = b.beginNested(nfta_expr_data);
    b.putBe32(nfta_cmp_sreg, nft_reg_1);
    b.putBe32(nfta_cmp_op, nft_cmp_eq);
    b.putDataValue(nfta_cmp_data, &ifname_buf);
    b.endNested(d_cmp_if);
    b.endNested(e_cmp_if);

    // 4f. masquerade.
    const e_masq = b.beginNested(nfta_list_elem);
    b.putStrZ(nfta_expr_name, "masquerade");
    const d_masq = b.beginNested(nfta_expr_data);
    b.endNested(d_masq);
    b.endNested(e_masq);

    b.endNested(exprs);
    b.endMsg(m_rule);
    seq +%= 1;

    // 5. Batch end (requests ACK for the transaction).
    const m_end = b.beginMsg(nfnl_msg_batch_end, nlm_f_request | nlm_f_ack, seq, nfproto_unspec, nfnl_subsys_nftables);
    b.endMsg(m_end);

    return b.buf[0..b.len];
}

/// Builds an `nf_tables` transaction batch that deletes the `ip dazzle` table
/// (and all chains and rules within it).
pub fn buildDisableBatch(buf: []u8, base_seq: u32) []const u8 {
    var b: Batch = .{ .buf = buf };
    var seq = base_seq;

    const m_begin = b.beginMsg(nfnl_msg_batch_begin, nlm_f_request, seq, nfproto_unspec, nfnl_subsys_nftables);
    b.endMsg(m_begin);
    seq +%= 1;

    const m_del = b.beginMsg(nftMsgType(nft_msg_deltable), nlm_f_request, seq, nfproto_ipv4, 0);
    b.putStrZ(nfta_table_name, table_name);
    b.endMsg(m_del);
    seq +%= 1;

    const m_end = b.beginMsg(nfnl_msg_batch_end, nlm_f_request | nlm_f_ack, seq, nfproto_unspec, nfnl_subsys_nftables);
    b.endMsg(m_end);

    return b.buf[0..b.len];
}

/// Checks a netlink reply datagram for `NLMSG_ERROR` messages; returns `true`
/// when an acknowledgement (`err == 0`) or `NLMSG_DONE` was seen, or the first
/// error returned by the kernel.
pub fn checkReply(datagram: []const u8) Error!bool {
    var rest = datagram;
    var done = false;
    while (rest.len >= nlmsghdr_len) {
        const len = std.mem.readInt(u32, rest[0..4], .little);
        if (len < nlmsghdr_len or len > rest.len) break;
        const msg = rest[0..len];
        rest = rest[@min(std.mem.alignForward(usize, len, 4), rest.len)..];
        const msg_type = std.mem.readInt(u16, msg[4..6], .little);
        switch (msg_type) {
            nlmsg_done => done = true,
            nlmsg_error => if (msg.len >= nlmsghdr_len + 4) {
                const err = std.mem.readInt(i32, msg[16..20], .little);
                if (err < 0) return sys.errorFromErrno(@enumFromInt(-err));
                done = true;
            },
            else => {},
        }
    }
    return done;
}

fn sendBatch(bytes: []const u8) Error!void {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, netlink_netfilter)));
    defer sys.close(fd);
    const Addr = extern struct { family: u16 = linux.AF.NETLINK, pad: u16 = 0, pid: u32 = 0, groups: u32 = 0 };
    const addr: Addr = .{};
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(Addr)));
    const tv: linux.timeval = .{ .sec = 2, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));

    _ = try sys.check(linux.write(fd, bytes.ptr, bytes.len));
    var reply: [4096]u8 align(4) = undefined;
    while (true) {
        const n = try sys.check(linux.recvfrom(fd, &reply, reply.len, 0, null, null));
        if (n == 0) return;
        if (try checkReply(reply[0..n])) return;
    }
}

/// Replaces any previous Dazzle NAT table with a masquerading rule for traffic
/// from the hotspot subnet (`ap_ip`/`mask`) routed out `out_ifname`.
pub fn enableMasquerade(ap_ip: Ip4, mask: Ip4, out_ifname: []const u8) Error!void {
    disableMasquerade();
    var buf: [1024]u8 align(4) = undefined;
    const batch = buildEnableBatch(&buf, 1, ap_ip, mask, out_ifname);
    try sendBatch(batch);
}

/// Removes the Dazzle NAT table if present.
pub fn disableMasquerade() void {
    var buf: [256]u8 align(4) = undefined;
    const batch = buildDisableBatch(&buf, 1);
    sendBatch(batch) catch {};
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const nl80211 = @import("nl80211.zig");

test "buildDisableBatch encodes batch begin, deltable dazzle, and batch end" {
    var buf: [256]u8 align(4) = undefined;
    const batch = buildDisableBatch(&buf, 10);

    // Three messages: BATCH_BEGIN (20B), DELTABLE (20B + 12B attr = 32B), BATCH_END (20B).
    try testing.expectEqual(@as(usize, 20 + 32 + 20), batch.len);

    // Message 1: NFNL_MSG_BATCH_BEGIN
    try testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, batch[0..4], .little));
    try testing.expectEqual(@as(u16, nfnl_msg_batch_begin), std.mem.readInt(u16, batch[4..6], .little));
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, batch[8..12], .little));
    try testing.expectEqual(@as(u16, nfnl_subsys_nftables), std.mem.readInt(u16, batch[18..20], .big));

    // Message 2: NFT_MSG_DELTABLE
    const del = batch[20..52];
    try testing.expectEqual(@as(u32, 32), std.mem.readInt(u32, del[0..4], .little));
    try testing.expectEqual(nftMsgType(nft_msg_deltable), std.mem.readInt(u16, del[4..6], .little));
    try testing.expectEqual(@as(u8, nfproto_ipv4), del[16]);
    const tbl = nl80211.Attrs.find(del[20..], nfta_table_name).?;
    try testing.expectEqualStrings("dazzle", tbl.string());

    // Message 3: NFNL_MSG_BATCH_END
    const end = batch[52..72];
    try testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, end[0..4], .little));
    try testing.expectEqual(@as(u16, nfnl_msg_batch_end), std.mem.readInt(u16, end[4..6], .little));
    try testing.expectEqual(@as(u16, nlm_f_request | nlm_f_ack), std.mem.readInt(u16, end[6..8], .little));
}

test "buildEnableBatch encodes table, postrouting nat chain, and masquerade rule" {
    var buf: [1024]u8 align(4) = undefined;
    const batch = buildEnableBatch(&buf, 1, .{ 10, 42, 0, 1 }, .{ 255, 255, 255, 0 }, "eth0");

    // Walk all five messages in the batch.
    var rest = batch;
    var count: usize = 0;
    var types: [5]u16 = undefined;
    var payloads: [5][]const u8 = undefined;
    while (rest.len > 0) : (count += 1) {
        try testing.expect(rest.len >= 20);
        const len = std.mem.readInt(u32, rest[0..4], .little);
        try testing.expect(len >= 20 and len <= rest.len);
        types[count] = std.mem.readInt(u16, rest[4..6], .little);
        payloads[count] = rest[20..len];
        rest = rest[len..];
    }
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expectEqual(@as(u16, nfnl_msg_batch_begin), types[0]);
    try testing.expectEqual(nftMsgType(nft_msg_newtable), types[1]);
    try testing.expectEqual(nftMsgType(nft_msg_newchain), types[2]);
    try testing.expectEqual(nftMsgType(nft_msg_newrule), types[3]);
    try testing.expectEqual(@as(u16, nfnl_msg_batch_end), types[4]);

    // Check chain attributes: table="dazzle", name="postrouting", type="nat", hook=POST_ROUTING(4), prio=100.
    try testing.expectEqualStrings("dazzle", nl80211.Attrs.find(payloads[2], nfta_chain_table).?.string());
    try testing.expectEqualStrings("postrouting", nl80211.Attrs.find(payloads[2], nfta_chain_name).?.string());
    try testing.expectEqualStrings("nat", nl80211.Attrs.find(payloads[2], nfta_chain_type).?.string());
    const hook_attr = nl80211.Attrs.find(payloads[2], nfta_chain_hook).?;
    try testing.expectEqual(@as(u32, nf_inet_post_routing), std.mem.readInt(u32, nl80211.Attrs.find(hook_attr.data, nfta_hook_hooknum).?.data[0..4], .big));
    try testing.expectEqual(@as(u32, nf_ip_pri_nat_src), std.mem.readInt(u32, nl80211.Attrs.find(hook_attr.data, nfta_hook_priority).?.data[0..4], .big));

    // Check rule expressions: payload, bitwise, cmp (10.42.0.0), meta (oifname), cmp (eth0), masquerade.
    const exprs_attr = nl80211.Attrs.find(payloads[3], nfta_rule_expressions).?;
    var it = nl80211.Attrs.of(exprs_attr.data);
    const expected_names = [_][]const u8{ "payload", "bitwise", "cmp", "meta", "cmp", "masquerade" };
    for (expected_names, 0..) |want, i| {
        const elem = it.next().?;
        try testing.expectEqual(@as(u16, nfta_list_elem), elem.type);
        const name = nl80211.Attrs.find(elem.data, nfta_expr_name).?.string();
        try testing.expectEqualStrings(want, name);
        if (i == 2) {
            // Subnet comparison must mask 10.42.0.1 with 255.255.255.0 -> 10.42.0.0.
            const expr_data = nl80211.Attrs.find(elem.data, nfta_expr_data).?;
            const cmp_data = nl80211.Attrs.find(expr_data.data, nfta_cmp_data).?;
            const val = nl80211.Attrs.find(cmp_data.data, nfta_data_value).?;
            try testing.expectEqualSlices(u8, &.{ 10, 42, 0, 0 }, val.data);
        } else if (i == 4) {
            // Output interface comparison must match "eth0".
            const expr_data = nl80211.Attrs.find(elem.data, nfta_expr_data).?;
            const cmp_data = nl80211.Attrs.find(expr_data.data, nfta_cmp_data).?;
            const val = nl80211.Attrs.find(cmp_data.data, nfta_data_value).?;
            try testing.expectEqualStrings("eth0", val.string());
        }
    }
    try testing.expect(it.next() == null);
}

test "checkReply handles ACK and negative errno" {
    var ack: [20]u8 = @splat(0);
    std.mem.writeInt(u32, ack[0..4], 20, .little);
    std.mem.writeInt(u16, ack[4..6], nlmsg_error, .little);
    std.mem.writeInt(i32, ack[16..20], 0, .little);
    try testing.expect(try checkReply(&ack));

    var enoent = ack;
    std.mem.writeInt(i32, enoent[16..20], -@as(i32, @intFromEnum(linux.E.NOENT)), .little);
    try testing.expectError(error.NotFound, checkReply(&enoent));
}
