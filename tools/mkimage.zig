//! Builds the SD card image: an MBR partition table with one bootable FAT32
//! partition holding the given files in its root directory, with long
//! (VFAT) file names. No root, loop devices or filesystem tools needed, and
//! the output is the same for the same inputs.
//!
//! Usage: mkimage <output.img> <size in MiB> <name>=<file> ...
//!
//! The partition starts at 1 MiB and fills the rest of the image. Clusters
//! are one 512-byte sector, as mkfs.vfat chooses for a small partition
//! (FAT32 needs at least 65525 clusters).

const std = @import("std");

const sector = 512;
const part_start = 2048;
const reserved_sectors = 32;
const num_fats = 2;
const sectors_per_cluster = 1;
const cluster_size = sector * sectors_per_cluster;
/// 2026-01-01, 00:00, for every timestamp.
const fat_date: u16 = (2026 - 1980) << 9 | 1 << 5 | 1;

const File = struct { name: []const u8, data: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: mkimage <output.img> <size in MiB> <name>=<file> ...\n", .{});
        std.process.exit(2);
    }
    const size_mib = try std.fmt.parseInt(u32, args[2], 10);
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList(File) = .empty;
    for (args[3..]) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadArgument;
        try files.append(arena, .{
            .name = spec[0..eq],
            .data = try cwd.readFileAlloc(init.io, spec[eq + 1 ..], arena, .limited(256 << 20)),
        });
    }
    const image = try build(arena, size_mib, files.items);
    const out = try cwd.createFile(init.io, args[1], .{});
    defer out.close(init.io);
    try out.writeStreamingAll(init.io, image);
}

fn put16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

pub fn build(gpa: std.mem.Allocator, size_mib: u32, files: []const File) ![]u8 {
    const total_sectors = size_mib * 2048;
    if (total_sectors <= part_start + 1024) return error.ImageTooSmall;
    const part_sectors = total_sectors - part_start;

    // FAT size: enough 4-byte entries for every cluster that remains.
    var fat_sectors: u32 = 1;
    var clusters: u32 = 0;
    while (true) {
        clusters = (part_sectors - reserved_sectors - num_fats * fat_sectors) / sectors_per_cluster;
        const needed = std.math.divCeil(u32, (clusters + 2) * 4, sector) catch unreachable;
        if (needed <= fat_sectors) break;
        fat_sectors = needed;
    }
    if (clusters < 65525) return error.ImageTooSmall;

    const image = try gpa.alloc(u8, @as(usize, total_sectors) * sector);
    @memset(image, 0);
    const part = image[part_start * sector ..];
    const data_start = reserved_sectors + num_fats * fat_sectors;

    // --- MBR ---
    put32(image, 440, 0x53544152); // disk signature
    const entry = image[446..][0..16];
    entry[0] = 0x80; // bootable
    entry[1..4].* = .{ 0xfe, 0xff, 0xff }; // CHS unused: LBA only
    entry[4] = 0x0c; // FAT32 (LBA)
    entry[5..8].* = .{ 0xfe, 0xff, 0xff };
    put32(entry, 8, part_start);
    put32(entry, 12, part_sectors);
    image[510] = 0x55;
    image[511] = 0xaa;

    // --- Directory entries (needed to size the root directory) ---
    var entries: std.ArrayList([32]u8) = .empty;
    var label: [32]u8 = @splat(0);
    @memcpy(label[0..11], "DAZZLE     ");
    label[11] = 0x08; // volume label
    try entries.append(gpa, label);
    var shorts: std.ArrayList([11]u8) = .empty;
    const file_entry_index = try gpa.alloc(usize, files.len);
    for (files, 0..) |f, i| {
        const short = shortName(f.name, shorts.items);
        try shorts.append(gpa, short);
        try appendLongName(gpa, &entries, f.name, short);
        file_entry_index[i] = entries.items.len;
        var e: [32]u8 = @splat(0);
        @memcpy(e[0..11], &short);
        e[11] = 0x20; // archive
        put16(&e, 16, fat_date); // created
        put16(&e, 18, fat_date); // accessed
        put16(&e, 24, fat_date); // written
        put32(&e, 28, @intCast(f.data.len));
        try entries.append(gpa, e);
    }

    // --- Clusters: the root directory, then each file, contiguously ---
    const fat = try gpa.alloc(u32, clusters + 2);
    @memset(fat, 0);
    fat[0] = 0x0ffffff8;
    fat[1] = 0x0fffffff;
    var next: u32 = 2;
    const allocChain = struct {
        fn f(table: []u32, next_cluster: *u32, count: u32) !u32 {
            if (count == 0) return 0;
            const first = next_cluster.*;
            if (first + count > table.len) return error.ImageFull;
            for (0..count) |k| {
                const c = first + @as(u32, @intCast(k));
                table[c] = if (k + 1 == count) 0x0fffffff else c + 1;
            }
            next_cluster.* += count;
            return first;
        }
    }.f;
    const clusterOffset = struct {
        fn f(start: u32, c: u32) usize {
            return (@as(usize, start) + (c - 2) * sectors_per_cluster) * sector;
        }
    }.f;

    const root_bytes = entries.items.len * 32;
    const root_first = try allocChain(fat, &next, @intCast(std.math.divCeil(usize, root_bytes, cluster_size) catch unreachable));
    for (files, 0..) |f, i| {
        const n: u32 = @intCast(std.math.divCeil(usize, f.data.len, cluster_size) catch unreachable);
        const first = try allocChain(fat, &next, n);
        const e = &entries.items[file_entry_index[i]];
        put16(e, 20, @truncate(first >> 16));
        put16(e, 26, @truncate(first));
        if (n > 0) @memcpy(part[clusterOffset(data_start, first)..][0..f.data.len], f.data);
    }
    @memcpy(part[clusterOffset(data_start, root_first)..][0..root_bytes], std.mem.sliceAsBytes(entries.items));

    // --- FATs ---
    for (0..num_fats) |k| {
        const at = (reserved_sectors + k * fat_sectors) * sector;
        for (fat, 0..) |v, c| put32(part, at + c * 4, v);
    }

    // --- Boot sector, FSInfo, and their backups ---
    const bs = part[0..sector];
    bs[0..3].* = .{ 0xeb, 0x58, 0x90 };
    @memcpy(bs[3..11], "DAZZLE  ");
    put16(bs, 11, sector);
    bs[13] = sectors_per_cluster;
    put16(bs, 14, reserved_sectors);
    bs[16] = num_fats;
    bs[21] = 0xf8; // fixed disk
    put16(bs, 24, 63); // sectors per track (for old BIOSes only)
    put16(bs, 26, 255); // heads
    put32(bs, 28, part_start); // hidden sectors before the partition
    put32(bs, 32, part_sectors);
    put32(bs, 36, fat_sectors);
    put32(bs, 44, root_first);
    put16(bs, 48, 1); // FSInfo sector
    put16(bs, 50, 6); // backup boot sector
    bs[64] = 0x80; // drive number
    bs[66] = 0x29; // extended boot signature
    put32(bs, 67, 0x53544152); // volume ID
    @memcpy(bs[71..82], "DAZZLE     ");
    @memcpy(bs[82..90], "FAT32   ");
    bs[510] = 0x55;
    bs[511] = 0xaa;
    const fsinfo = part[sector .. 2 * sector];
    put32(fsinfo, 0, 0x41615252);
    put32(fsinfo, 484, 0x61417272);
    put32(fsinfo, 488, clusters - (next - 2)); // free clusters
    put32(fsinfo, 492, next); // next free
    put32(fsinfo, 508, 0xaa550000);
    @memcpy(part[6 * sector .. 8 * sector], part[0 .. 2 * sector]);
    return image;
}

/// An 8.3 name: the name itself in capitals if it fits, otherwise the first
/// letters of the name, ~N, and the extension's first letters.
fn shortName(name: []const u8, taken: []const [11]u8) [11]u8 {
    var out: [11]u8 = @splat(' ');
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const base = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d + 1 ..] else "";
    const valid = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'()-@^_`{}~", c) != null;
        }
    }.f;
    var fits = base.len >= 1 and base.len <= 8 and ext.len <= 3;
    for (base) |c| fits = fits and valid(c);
    for (ext) |c| fits = fits and valid(c);
    for (ext, 0..) |c, i| if (i < 3 and valid(c)) {
        out[8 + i] = std.ascii.toUpper(c);
    };
    if (fits) {
        for (base, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        return out;
    }
    var stem: [6]u8 = undefined;
    var n: usize = 0;
    for (base) |c| if (n < 6 and valid(c)) {
        stem[n] = std.ascii.toUpper(c);
        n += 1;
    };
    var k: u8 = 1;
    while (true) : (k += 1) {
        var candidate = out;
        @memcpy(candidate[0..n], stem[0..n]);
        candidate[n] = '~';
        candidate[n + 1] = '0' + k;
        for (taken) |t| {
            if (std.mem.eql(u8, &t, &candidate)) break;
        } else return candidate;
    }
}

fn shortChecksum(short: [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| sum = (sum >> 1 | (sum & 1) << 7) +% c;
    return sum;
}

/// The long-name entries for `name`, last part first, as FAT stores them.
fn appendLongName(gpa: std.mem.Allocator, entries: *std.ArrayList([32]u8), name: []const u8, short: [11]u8) !void {
    const parts = std.math.divCeil(usize, name.len + 1, 13) catch unreachable; // with the terminating NUL
    const offsets = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    var p = parts;
    while (p > 0) : (p -= 1) {
        var e: [32]u8 = @splat(0);
        e[0] = @intCast(p);
        if (p == parts) e[0] |= 0x40; // the last part
        e[11] = 0x0f; // long name
        e[13] = shortChecksum(short);
        for (offsets, 0..) |off, k| {
            const idx = (p - 1) * 13 + k;
            const ch: u16 = if (idx < name.len) name[idx] else if (idx == name.len) 0 else 0xffff;
            put16(&e, off, ch);
        }
        try entries.append(gpa, e);
    }
}

test "short names" {
    try std.testing.expectEqualStrings("CONFIG  TXT", &shortName("config.txt", &.{}));
    try std.testing.expectEqualStrings("ZIMAGE     ", &shortName("zImage", &.{}));
    try std.testing.expectEqualStrings("BCM283~1DTB", &shortName("bcm2835-rpi-zero.dtb", &.{}));
    try std.testing.expectEqualStrings("BCM283~2DTB", &shortName("bcm2835-rpi-zero-w.dtb", &.{"BCM283~1DTB".*}));
    try std.testing.expectEqualStrings("LICENC~1BRO", &shortName("LICENCE.broadcom", &.{}));
}

test "an image has a valid partition and boot sector" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const img = try build(arena.allocator(), 64, &.{
        .{ .name = "config.txt", .data = "hello\n" },
        .{ .name = "bcm2835-rpi-zero-w.dtb", .data = &(@as([1500]u8, @splat(7))) },
    });
    try std.testing.expectEqual(@as(usize, 64 << 20), img.len);
    try std.testing.expectEqual(@as(u8, 0x0c), img[446 + 4]);
    const part = img[part_start * sector ..];
    try std.testing.expectEqualStrings("FAT32   ", part[82..90]);
    try std.testing.expectEqualSlices(u8, part[0..512], part[6 * 512 .. 7 * 512]);
}
