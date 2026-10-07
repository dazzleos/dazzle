//! What filesystem a drive (or one of its partitions) holds, and its
//! label, read from the start of the device: FAT (12, 16 or 32), exFAT,
//! NTFS or ext2/3/4, the filesystems USB drives come with or are given.
//! The media manager (media.zig) mounts it by its type, at a folder named
//! by its label.

const std = @import("std");

pub const Kind = enum {
    fat,
    exfat,
    ntfs,
    ext,

    /// The kernel's name for its filesystem.
    pub fn fsType(k: Kind) [:0]const u8 {
        return switch (k) {
            .fat => "vfat",
            .exfat => "exfat",
            .ntfs => "ntfs3",
            .ext => "ext4",
        };
    }
};

pub const Volume = struct {
    kind: Kind,
    /// UTF-8; empty if it has none.
    label_buf: [96]u8 = undefined,
    label_len: usize = 0,

    pub fn label(v: *const Volume) []const u8 {
        return v.label_buf[0..v.label_len];
    }

    fn setLabel(v: *Volume, text: []const u8) void {
        const t = std.mem.trim(u8, text, " \x00");
        const n = @min(t.len, v.label_buf.len);
        @memcpy(v.label_buf[0..n], t[0..n]);
        v.label_len = n;
    }

    /// A label in UTF-16LE (as exFAT and NTFS keep them).
    fn setLabelUtf16(v: *Volume, bytes: []const u8) void {
        var units: [64]u16 = undefined;
        const n = @min(bytes.len / 2, units.len);
        for (units[0..n], 0..) |*u, i| u.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
        var out: [96]u8 = undefined;
        var len: usize = 0;
        var it = std.unicode.Utf16LeIterator.init(units[0..n]);
        while (it.nextCodepoint() catch null) |c| {
            var enc: [4]u8 = undefined;
            const l = std.unicode.utf8Encode(c, &enc) catch break;
            if (len + l > out.len) break;
            @memcpy(out[len..][0..l], enc[0..l]);
            len += l;
        }
        v.setLabel(out[0..len]);
    }

    /// A FAT label: 11 bytes in the computer's old code page; only ASCII
    /// is kept as it is.
    fn setLabelFat(v: *Volume, bytes: []const u8) void {
        var out: [11]u8 = undefined;
        const n = @min(bytes.len, out.len);
        for (out[0..n], bytes[0..n]) |*o, c| o.* = if (c >= 0x20 and c < 0x7f) c else '_';
        v.setLabel(out[0..n]);
    }
};

/// Reads `buf.len` bytes of the device from `offset`; false if it cannot.
pub const ReadAt = struct {
    ctx: *const anyopaque,
    f: *const fn (ctx: *const anyopaque, offset: u64, buf: []u8) bool,

    fn read(r: ReadAt, offset: u64, buf: []u8) bool {
        return r.f(r.ctx, offset, buf);
    }
};

/// The filesystem on the device, if it is one Dazzle mounts.
pub fn probe(r: ReadAt) ?Volume {
    var boot: [512]u8 = undefined;
    if (!r.read(0, &boot)) return null;
    if (std.mem.eql(u8, boot[3..11], "EXFAT   ")) return exfat(r, &boot);
    if (std.mem.eql(u8, boot[3..11], "NTFS    ")) return ntfs(r, &boot);
    if (fat(r, &boot)) |v| return v;
    var sb: [1024]u8 = undefined;
    if (r.read(1024, &sb) and std.mem.readInt(u16, sb[56..58], .little) == 0xef53) {
        var v: Volume = .{ .kind = .ext };
        v.setLabel(std.mem.sliceTo(sb[120..136], 0));
        return v;
    }
    return null;
}

/// How much of a root folder is looked through for the label.
const max_root_read = 32 * 1024;

fn fat(r: ReadAt, boot: *const [512]u8) ?Volume {
    if (boot[510] != 0x55 or boot[511] != 0xaa) return null;
    // A partition table has the same mark: a FAT boot sector says it is
    // one, and describes the filesystem sensibly.
    const fat32 = std.mem.eql(u8, boot[82..87], "FAT32");
    if (!fat32 and !std.mem.eql(u8, boot[54..57], "FAT")) return null;
    const bps = std.mem.readInt(u16, boot[11..13], .little);
    const spc = boot[13];
    const reserved = std.mem.readInt(u16, boot[14..16], .little);
    const fats = boot[16];
    if (!(bps == 512 or bps == 1024 or bps == 2048 or bps == 4096)) return null;
    if (spc == 0 or !std.math.isPowerOfTwo(spc) or reserved == 0 or fats == 0) return null;

    var v: Volume = .{ .kind = .fat };
    // The label in the root folder is the one kept up to date; the boot
    // sector's is a copy, often "NO NAME".
    const boot_label = if (fat32) boot[71..82] else boot[43..54];
    if (!std.mem.eql(u8, boot_label, "NO NAME    ")) v.setLabelFat(boot_label);
    var root_offset: u64 = undefined;
    var root_len: usize = undefined;
    const fat16_size = std.mem.readInt(u16, boot[22..24], .little);
    if (fat16_size != 0) {
        root_offset = (@as(u64, reserved) + @as(u64, fats) * fat16_size) * bps;
        root_len = @as(usize, std.mem.readInt(u16, boot[17..19], .little)) * 32;
    } else {
        const fat_size = std.mem.readInt(u32, boot[36..40], .little);
        const root_cluster = std.mem.readInt(u32, boot[44..48], .little);
        if (root_cluster < 2) return v;
        const data = @as(u64, reserved) + @as(u64, fats) * fat_size;
        root_offset = (data + @as(u64, root_cluster - 2) * spc) * bps;
        root_len = @as(usize, spc) * bps;
    }
    var root: [max_root_read]u8 = undefined;
    const len = @min(root_len, root.len);
    if (len == 0 or !r.read(root_offset, root[0..len])) return v;
    var at: usize = 0;
    while (at + 32 <= len) : (at += 32) {
        const e = root[at..][0..32];
        if (e[0] == 0) break;
        if (e[0] == 0xe5) continue;
        const attr = e[11];
        // Long names' parts have every one of the low four bits.
        if (attr & 0x0f == 0x0f) continue;
        if (attr & 0x08 != 0) {
            v.label_len = 0;
            v.setLabelFat(e[0..11]);
            break;
        }
    }
    return v;
}

fn exfat(r: ReadAt, boot: *const [512]u8) ?Volume {
    var v: Volume = .{ .kind = .exfat };
    const bps_shift = boot[108];
    const spc_shift = boot[109];
    if (bps_shift < 9 or bps_shift > 12 or spc_shift > 25 - bps_shift) return v;
    const heap = std.mem.readInt(u32, boot[88..92], .little);
    const root_cluster = std.mem.readInt(u32, boot[96..100], .little);
    if (root_cluster < 2) return v;
    const offset = (@as(u64, heap) << @intCast(bps_shift)) + (@as(u64, root_cluster - 2) << @intCast(bps_shift + spc_shift));
    var root: [max_root_read]u8 = undefined;
    const len = @min(@as(usize, 1) << @intCast(bps_shift + spc_shift), root.len);
    if (!r.read(offset, root[0..len])) return v;
    var at: usize = 0;
    while (at + 32 <= len) : (at += 32) {
        const e = root[at..][0..32];
        if (e[0] == 0) break;
        // The volume label's entry.
        if (e[0] == 0x83) {
            v.setLabelUtf16(e[2 .. 2 + @as(usize, @min(e[1], 11)) * 2]);
            break;
        }
    }
    return v;
}

fn ntfs(r: ReadAt, boot: *const [512]u8) ?Volume {
    var v: Volume = .{ .kind = .ntfs };
    const bps = std.mem.readInt(u16, boot[11..13], .little);
    const spc = boot[13];
    if (bps < 256 or bps > 4096 or spc == 0) return v;
    const cluster = @as(u64, bps) * spc;
    const mft = std.mem.readInt(u64, boot[48..56], .little);
    const per_record: i8 = @bitCast(boot[64]);
    const record_size: u64 = if (per_record > 0) @as(u64, @intCast(per_record)) * cluster else @as(u64, 1) << @intCast(@min(-@as(i16, per_record), 16));
    var rec: [4096]u8 = undefined;
    if (record_size < 512 or record_size > rec.len) return v;
    const len: usize = @intCast(record_size);
    // $Volume is the fourth record of the master file table.
    if (!r.read(mft *% cluster +% 3 * record_size, rec[0..len])) return v;
    if (!std.mem.eql(u8, rec[0..4], "FILE")) return v;
    // The last two bytes of each 512 were swapped for a check value when
    // it was written; put them back.
    const usa = std.mem.readInt(u16, rec[4..6], .little);
    const usa_count = std.mem.readInt(u16, rec[6..8], .little);
    if (usa + @as(usize, usa_count) * 2 > len) return v;
    for (1..usa_count) |i| {
        const end = i * 512;
        if (end > len) break;
        @memcpy(rec[end - 2 .. end], rec[usa + i * 2 ..][0..2]);
    }
    var at: usize = std.mem.readInt(u16, rec[20..22], .little);
    while (at + 24 <= len) {
        const kind = std.mem.readInt(u32, rec[at..][0..4], .little);
        const size = std.mem.readInt(u32, rec[at + 4 ..][0..4], .little);
        if (kind == 0xffff_ffff or size < 24 or at + size > len) break;
        // $VOLUME_NAME, kept in the record itself.
        if (kind == 0x60 and rec[at + 8] == 0) {
            const value_len = std.mem.readInt(u32, rec[at + 16 ..][0..4], .little);
            const value_at = at + std.mem.readInt(u16, rec[at + 20 ..][0..2], .little);
            if (value_at + value_len <= at + size) v.setLabelUtf16(rec[value_at .. value_at + value_len]);
            break;
        }
        at += size;
    }
    return v;
}

/// A folder name for a volume: its label, without what a folder name
/// cannot have, or `fallback` (the label may be empty).
pub fn folderName(buf: []u8, label: []const u8, fallback: []const u8) []const u8 {
    var len: usize = 0;
    for (label) |c| {
        if (len == buf.len) break;
        buf[len] = if (c == '/' or c < 0x20) '_' else c;
        len += 1;
    }
    const name = std.mem.trim(u8, buf[0..len], " .");
    if (name.len == 0) {
        const n = @min(fallback.len, buf.len);
        @memcpy(buf[0..n], fallback[0..n]);
        return buf[0..n];
    }
    std.mem.copyForwards(u8, buf, name);
    return buf[0..name.len];
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

const Image = struct {
    bytes: []u8,

    fn readAt(ctx: *const anyopaque, offset: u64, buf: []u8) bool {
        const img: *const Image = @ptrCast(@alignCast(ctx));
        if (offset + buf.len > img.bytes.len) return false;
        @memcpy(buf, img.bytes[@intCast(offset)..][0..buf.len]);
        return true;
    }

    fn reader(img: *const Image) ReadAt {
        return .{ .ctx = img, .f = readAt };
    }
};

fn put16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

test "FAT32: the label in the root folder, over the boot sector's" {
    var bytes: [64 * 1024]u8 = @splat(0);
    put16(&bytes, 11, 512);
    bytes[13] = 1;
    put16(&bytes, 14, 32);
    bytes[16] = 2;
    put32(&bytes, 36, 8);
    put32(&bytes, 44, 2);
    @memcpy(bytes[71..82], "NO NAME    ");
    @memcpy(bytes[82..90], "FAT32   ");
    bytes[510] = 0x55;
    bytes[511] = 0xaa;
    // The root folder: a long name's part, then the label.
    const root = (32 + 2 * 8) * 512;
    bytes[root] = 0x41;
    bytes[root + 11] = 0x0f;
    @memcpy(bytes[root + 32 ..][0..11], "HOLIDAY    ");
    bytes[root + 32 + 11] = 0x08;
    const img: Image = .{ .bytes = &bytes };
    const v = probe(img.reader()).?;
    try testing.expectEqual(Kind.fat, v.kind);
    try testing.expectEqualStrings("HOLIDAY", v.label());
    // Without one there, the boot sector's.
    bytes[root + 32 + 11] = 0x20;
    @memcpy(bytes[71..82], "STICK      ");
    try testing.expectEqualStrings("STICK", probe(img.reader()).?.label());
    // A partition table is not a filesystem.
    @memset(bytes[54..90], 0);
    try testing.expect(probe(img.reader()) == null);
}

test "FAT16: the root folder after the tables" {
    var bytes: [64 * 1024]u8 = @splat(0);
    put16(&bytes, 11, 512);
    bytes[13] = 4;
    put16(&bytes, 14, 1);
    bytes[16] = 2;
    put16(&bytes, 17, 512);
    put16(&bytes, 22, 20);
    @memcpy(bytes[43..54], "NO NAME    ");
    @memcpy(bytes[54..62], "FAT16   ");
    bytes[510] = 0x55;
    bytes[511] = 0xaa;
    const root = (1 + 2 * 20) * 512;
    @memcpy(bytes[root..][0..11], "CAM\xe9RA     ");
    bytes[root + 11] = 0x08;
    const img: Image = .{ .bytes = &bytes };
    try testing.expectEqualStrings("CAM_RA", probe(img.reader()).?.label());
}

test "exFAT: the label entry in the root folder" {
    var bytes: [64 * 1024]u8 = @splat(0);
    @memcpy(bytes[3..11], "EXFAT   ");
    put32(&bytes, 88, 16);
    put32(&bytes, 96, 4);
    bytes[108] = 9;
    bytes[109] = 3;
    const root = 16 * 512 + 2 * 8 * 512;
    bytes[root] = 0x81;
    bytes[root + 32] = 0x83;
    bytes[root + 33] = 5;
    for ("Fotos", 0..) |c, i| put16(&bytes, root + 34 + i * 2, c);
    put16(&bytes, root + 34 + 2, 0xf6); // ö
    const img: Image = .{ .bytes = &bytes };
    const v = probe(img.reader()).?;
    try testing.expectEqual(Kind.exfat, v.kind);
    try testing.expectEqualStrings("F\u{f6}tos", v.label());
}

test "NTFS: $Volume's name, with the record's check values put back" {
    var bytes: [64 * 1024]u8 = @splat(0);
    @memcpy(bytes[3..11], "NTFS    ");
    put16(&bytes, 11, 512);
    bytes[13] = 8;
    std.mem.writeInt(u64, bytes[48..56], 2, .little);
    bytes[64] = @bitCast(@as(i8, -10));
    const rec = 2 * 8 * 512 + 3 * 1024;
    const r = bytes[rec..][0..1024];
    @memcpy(r[0..4], "FILE");
    put16(r, 4, 48);
    put16(r, 6, 3);
    put16(r, 20, 56);
    // $STANDARD_INFORMATION, then $VOLUME_NAME.
    put32(r, 56, 0x10);
    put32(r, 60, 32);
    put32(r, 88, 0x60);
    put32(r, 92, 40);
    put32(r, 88 + 16, 8);
    put16(r, 88 + 20, 24);
    for ("Data", 0..) |c, i| put16(r, 88 + 24 + i * 2, c);
    put32(r, 128, 0xffff_ffff);
    // The check value at the end of each 512, and what was there.
    put16(r, 48, 0x1234);
    put16(r, 50, 0);
    put16(r, 52, 0);
    put16(r, 510, 0x1234);
    put16(r, 1022, 0x1234);
    const img: Image = .{ .bytes = &bytes };
    const v = probe(img.reader()).?;
    try testing.expectEqual(Kind.ntfs, v.kind);
    try testing.expectEqualStrings("Data", v.label());
}

test "ext4, and nothing" {
    var bytes: [4096]u8 = @splat(0);
    const img: Image = .{ .bytes = &bytes };
    try testing.expect(probe(img.reader()) == null);
    put16(&bytes, 1024 + 56, 0xef53);
    @memcpy(bytes[1024 + 120 ..][0..6], "backup");
    const v = probe(img.reader()).?;
    try testing.expectEqual(Kind.ext, v.kind);
    try testing.expectEqualStrings("backup", v.label());
}

test "folder names from labels" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("HOLIDAY", folderName(&buf, "HOLIDAY", "USB drive"));
    try testing.expectEqualStrings("a_b", folderName(&buf, "a/b", "USB drive"));
    try testing.expectEqualStrings("USB drive", folderName(&buf, " .. ", "USB drive"));
    try testing.expectEqualStrings("USB drive", folderName(&buf, "", "USB drive"));
}
