//! Builds the SD card image: an MBR partition table with one bootable FAT16
//! partition holding the given files in its root directory, with long
//! (VFAT) file names. No root, loop devices or filesystem tools needed, and
//! the output is the same for the same inputs.
//!
//! Usage: mkimage <output.img> <size in MiB, or "auto"> <name>=<file> ...
//!
//! The partition starts at 1 MiB and fills the rest of the image. "auto"
//! makes the image just big enough for the files, with some room to spare
//! (a quarter more, and at least 1 MiB), in whole MiB; nothing on the
//! device writes to it, and the rest of the card is for files (/data). The
//! Pi's boot ROM and firmware read FAT16, which suits a partition this
//! small (FAT32 needs at least 65525 clusters, 32 MiB of 512-byte ones).
//! Clusters are one 512-byte sector, or as many as keep the partition
//! within FAT16's 65524 clusters.

const std = @import("std");

const sector = 512;
const part_start = 2048;
const reserved_sectors = 1;
const num_fats = 2;
/// FAT16's limits on the number of clusters.
const min_clusters = 4085;
const max_clusters = 65524;
/// 2026-01-01, 00:00, for every timestamp.
const fat_date: u16 = (2026 - 1980) << 9 | 1 << 5 | 1;

const File = struct { name: []const u8, data: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: mkimage <output.img> <size in MiB, or auto> <name>=<file> ...\n", .{});
        std.process.exit(2);
    }
    const size_mib: ?u32 = if (std.mem.eql(u8, args[2], "auto")) null else try std.fmt.parseInt(u32, args[2], 10);
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

/// The root directory's entries: the volume label, and each file's long
/// name parts and 8.3 entry.
const Directory = struct {
    entries: std.ArrayList([32]u8) = .empty,
    /// Where each file's 8.3 entry is.
    file_entry: []usize,

    fn make(gpa: std.mem.Allocator, files: []const File) !Directory {
        var d: Directory = .{ .file_entry = try gpa.alloc(usize, files.len) };
        var label: [32]u8 = @splat(0);
        @memcpy(label[0..11], "DAZZLE     ");
        label[11] = 0x08; // volume label
        try d.entries.append(gpa, label);
        var shorts: std.ArrayList([11]u8) = .empty;
        for (files, 0..) |f, i| {
            const short = shortName(f.name, shorts.items);
            try shorts.append(gpa, short);
            try appendLongName(gpa, &d.entries, f.name, short);
            d.file_entry[i] = d.entries.items.len;
            var e: [32]u8 = @splat(0);
            @memcpy(e[0..11], &short);
            e[11] = 0x20; // archive
            put16(&e, 16, fat_date); // created
            put16(&e, 18, fat_date); // accessed
            put16(&e, 24, fat_date); // written
            put32(&e, 28, @intCast(f.data.len));
            try d.entries.append(gpa, e);
        }
        return d;
    }

    /// Root directory entries: room for these (at least the usual 512),
    /// filling whole sectors.
    fn rootEntries(d: *const Directory) u32 {
        return @intCast(@max(512, std.mem.alignForward(usize, d.entries.items.len, sector / 32)));
    }
};

/// Where everything goes in a partition of `part_sectors`.
const Layout = struct {
    sectors_per_cluster: u32,
    fat_sectors: u32,
    root_sectors: u32,
    clusters: u32,

    fn plan(part_sectors: u32, root_entries: u32) !Layout {
        const root_sectors = root_entries * 32 / sector;
        var spc: u32 = 1;
        while (spc <= 64) : (spc *= 2) {
            // FAT size: enough 2-byte entries for every cluster that remains.
            var fat_sectors: u32 = 1;
            var clusters: u32 = 0;
            while (true) {
                const meta = reserved_sectors + num_fats * fat_sectors + root_sectors;
                if (meta >= part_sectors) return error.ImageTooSmall;
                clusters = (part_sectors - meta) / spc;
                const needed = std.math.divCeil(u32, (clusters + 2) * 2, sector) catch unreachable;
                if (needed <= fat_sectors) break;
                fat_sectors = needed;
            }
            if (clusters > max_clusters) continue;
            if (clusters < min_clusters) return error.ImageTooSmall;
            return .{ .sectors_per_cluster = spc, .fat_sectors = fat_sectors, .root_sectors = root_sectors, .clusters = clusters };
        }
        return error.ImageTooBig;
    }

    fn dataStart(l: Layout) u32 {
        return reserved_sectors + num_fats * l.fat_sectors + l.root_sectors;
    }

    fn clusterBytes(l: Layout) u32 {
        return l.sectors_per_cluster * sector;
    }
};

/// The size, in MiB, of an image just big enough for `files` (with some
/// room to spare).
fn autoSize(files: []const File, root_entries: u32) u32 {
    var data: u64 = 0;
    for (files) |f| data += std.mem.alignForward(u64, f.data.len, sector);
    const room = @max(data / 4, 1 << 20);
    // At least FAT16's least clusters.
    const data_sectors = @max((data + room) / sector, min_clusters + 16);
    const fat_sectors = std.math.divCeil(u64, (data_sectors + 2) * 2, sector) catch unreachable;
    const total = part_start + reserved_sectors + num_fats * fat_sectors + root_entries * 32 / sector + data_sectors;
    return @intCast(std.math.divCeil(u64, total, 2048) catch unreachable);
}

/// The image, `size_mib` big or (null) just big enough.
pub fn build(gpa: std.mem.Allocator, size_mib: ?u32, files: []const File) ![]u8 {
    var dir = try Directory.make(gpa, files);
    const root_entries = dir.rootEntries();
    const mib = size_mib orelse autoSize(files, root_entries);
    const total_sectors = mib * 2048;
    if (total_sectors <= part_start) return error.ImageTooSmall;
    const part_sectors = total_sectors - part_start;
    const l = try Layout.plan(part_sectors, root_entries);

    const image = try gpa.alloc(u8, @as(usize, total_sectors) * sector);
    @memset(image, 0);
    const part = image[part_start * sector ..];

    // --- MBR ---
    put32(image, 440, 0x53544152); // disk signature
    const entry = image[446..][0..16];
    entry[0] = 0x80; // bootable
    entry[1..4].* = .{ 0xfe, 0xff, 0xff }; // CHS unused: LBA only
    entry[4] = 0x0e; // FAT16 (LBA)
    entry[5..8].* = .{ 0xfe, 0xff, 0xff };
    put32(entry, 8, part_start);
    put32(entry, 12, part_sectors);
    image[510] = 0x55;
    image[511] = 0xaa;

    // --- Clusters: each file's, contiguously ---
    const fat = try gpa.alloc(u16, l.clusters + 2);
    @memset(fat, 0);
    fat[0] = 0xfff8;
    fat[1] = 0xffff;
    var next: u32 = 2;
    const cluster_bytes = l.clusterBytes();
    for (files, 0..) |f, i| {
        const n: u32 = @intCast(std.math.divCeil(usize, f.data.len, cluster_bytes) catch unreachable);
        if (n == 0) continue;
        if (next + n > fat.len) return error.ImageFull;
        const first = next;
        for (0..n) |k| {
            const c = first + @as(u32, @intCast(k));
            fat[c] = if (k + 1 == n) 0xffff else @intCast(c + 1);
        }
        next += n;
        put16(&dir.entries.items[dir.file_entry[i]], 26, @intCast(first));
        const at = (@as(usize, l.dataStart()) + (first - 2) * l.sectors_per_cluster) * sector;
        @memcpy(part[at..][0..f.data.len], f.data);
    }

    // --- FATs, and the root directory after them ---
    for (0..num_fats) |k| {
        const at = (reserved_sectors + k * l.fat_sectors) * sector;
        for (fat, 0..) |v, c| put16(part, at + c * 2, v);
    }
    const root_at = (reserved_sectors + num_fats * l.fat_sectors) * sector;
    @memcpy(part[root_at..][0 .. dir.entries.items.len * 32], std.mem.sliceAsBytes(dir.entries.items));

    // --- Boot sector ---
    const bs = part[0..sector];
    bs[0..3].* = .{ 0xeb, 0x3c, 0x90 };
    @memcpy(bs[3..11], "DAZZLE  ");
    put16(bs, 11, sector);
    bs[13] = @intCast(l.sectors_per_cluster);
    put16(bs, 14, reserved_sectors);
    bs[16] = num_fats;
    put16(bs, 17, @intCast(root_entries));
    if (part_sectors < 65536) put16(bs, 19, @intCast(part_sectors)) else put32(bs, 32, part_sectors);
    bs[21] = 0xf8; // fixed disk
    put16(bs, 22, @intCast(l.fat_sectors));
    put16(bs, 24, 63); // sectors per track (for old BIOSes only)
    put16(bs, 26, 255); // heads
    put32(bs, 28, part_start); // hidden sectors before the partition
    bs[36] = 0x80; // drive number
    bs[38] = 0x29; // extended boot signature
    put32(bs, 39, 0x53544152); // volume ID
    @memcpy(bs[43..54], "DAZZLE     ");
    @memcpy(bs[54..62], "FAT16   ");
    bs[510] = 0x55;
    bs[511] = 0xaa;
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

test "an image has a valid partition and boot sector, and is as big as it needs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const files = [_]File{
        .{ .name = "config.txt", .data = "hello\n" },
        .{ .name = "bcm2835-rpi-zero-w.dtb", .data = &(@as([1500]u8, @splat(7))) },
    };
    // Small files: FAT16's least clusters (2 MiB of them), and the 1 MiB
    // before the partition.
    const img = try build(arena.allocator(), null, &files);
    try std.testing.expectEqual(@as(usize, 4 << 20), img.len);
    try std.testing.expectEqual(@as(u8, 0x0e), img[446 + 4]);
    const part = img[part_start * sector ..];
    try std.testing.expectEqualStrings("FAT16   ", part[54..62]);
    try std.testing.expectEqual(@as(u8, 1), part[13]);
    // 9 MB of files: a quarter more, in whole MiB.
    const big = try arena.allocator().alloc(u8, 9_000_000);
    const sized = try build(arena.allocator(), null, &.{.{ .name = "initramfs.cpio", .data = big }});
    try std.testing.expectEqual(@as(usize, 12 << 20), sized.len);
    // A size given, too big for 512-byte clusters: bigger clusters.
    const fixed = try build(arena.allocator(), 64, &files);
    try std.testing.expectEqual(@as(usize, 64 << 20), fixed.len);
    try std.testing.expectEqual(@as(u8, 2), fixed[part_start * sector + 13]);
    try std.testing.expectError(error.ImageTooSmall, build(arena.allocator(), 2, &files));
}
