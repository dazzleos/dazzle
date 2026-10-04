//! Makes an empty ext2-format filesystem (which the kernel's ext4 driver
//! mounts) on a partition, a step at a time, so the system manager can say
//! how far it has got while it works: `Formatter.step` writes a few block
//! groups' metadata (bitmaps, and their inode tables zeroed) and returns
//! whether it has finished. The primary superblock is written last, so a
//! partition that was not finished is not taken for a filesystem.
//!
//! The layout is mke2fs's for a revision 1 filesystem: 4 KiB blocks, 32768
//! blocks to a group, one inode for every 256 KiB (files on a Pi are few),
//! 256-byte inodes (with room for timestamps after 2038), superblock and
//! group descriptor backups in groups 0, 1 and powers of 3, 5 and 7
//! (sparse_super), file types in directory entries, and large files, and a
//! journal (so a power cut, the usual way a Pi is turned off, does not
//! leave the filesystem inconsistent): one extent of blocks after group
//! 0's metadata, of which only the journal's superblock needs writing. There
//! is no resize space and there are no checksums. The root directory holds
//! lost+found, as e2fsck expects.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const block_size = 4096;
const inode_size = 256;
const blocks_per_group = 8 * block_size;
const bytes_per_inode = 256 * 1024;
const inodes_per_block = block_size / inode_size;
const desc_size = 32;
/// Inodes 1 to 10 are reserved; lost+found is the first ordinary one.
const first_ino = 11;
const root_ino = 2;
const journal_ino = 8;
const lost_found_ino = 11;
/// Groups this small are not worth having.
const min_group_blocks = 256;

pub const Error = error{ TooSmall, OutOfMemory } || sys.Error;

/// Where everything goes, for a partition of a given size.
pub const Layout = struct {
    blocks: u32,
    groups: u32,
    inodes_per_group: u32,
    itable_blocks: u32,
    gdt_blocks: u32,
    journal_blocks: u32,

    pub fn plan(size_bytes: u64) Error!Layout {
        var blocks: u64 = size_bytes / block_size;
        // The ext2 format counts blocks in 32 bits.
        blocks = @min(blocks, std.math.maxInt(u32));
        const ipg_raw = blocks_per_group * block_size / bytes_per_inode;
        const ipg = std.mem.alignForward(u32, ipg_raw, inodes_per_block);
        const itable = ipg / inodes_per_block;
        var groups: u64 = std.math.divCeil(u64, blocks, blocks_per_group) catch unreachable;
        if (groups == 0) return error.TooSmall;
        // A last group too small for its metadata and some data goes.
        while (groups > 1) {
            const last = blocks - (groups - 1) * blocks_per_group;
            const gdt = std.math.divCeil(u64, groups * desc_size, block_size) catch unreachable;
            const meta = (if (hasSuper(@intCast(groups - 1))) 1 + gdt else 0) + 2 + itable;
            if (last >= meta + min_group_blocks) break;
            groups -= 1;
            blocks = groups * blocks_per_group;
        }
        const gdt = std.math.divCeil(u64, groups * desc_size, block_size) catch unreachable;
        // 16 MiB of journal from 1 GiB, 4 MiB below; in group 0.
        const journal: u64 = if (blocks >= 1 << 18) 4096 else 1024;
        const group0 = @min(blocks, blocks_per_group);
        if (group0 < 1 + gdt + 2 + itable + 2 + journal + min_group_blocks) return error.TooSmall;
        return .{
            .blocks = @intCast(blocks),
            .groups = @intCast(groups),
            .inodes_per_group = ipg,
            .itable_blocks = itable,
            .gdt_blocks = @intCast(gdt),
            .journal_blocks = @intCast(journal),
        };
    }

    fn groupStart(_: Layout, g: u32) u32 {
        return g * blocks_per_group;
    }

    fn groupBlocks(l: Layout, g: u32) u32 {
        return if (g + 1 == l.groups) l.blocks - g * blocks_per_group else blocks_per_group;
    }

    /// The blocks before the group's data: superblock and descriptors (in
    /// groups with backups), bitmaps and the inode table.
    fn overhead(l: Layout, g: u32) u32 {
        return l.superBlocks(g) + 2 + l.itable_blocks;
    }

    fn superBlocks(l: Layout, g: u32) u32 {
        return if (hasSuper(g)) 1 + l.gdt_blocks else 0;
    }

    fn blockBitmap(l: Layout, g: u32) u32 {
        return l.groupStart(g) + l.superBlocks(g);
    }

    fn inodeTable(l: Layout, g: u32) u32 {
        return l.blockBitmap(g) + 2;
    }

    /// The first two data blocks of group 0: the root directory's and
    /// lost+found's; the journal follows them.
    fn rootBlock(l: Layout) u32 {
        return l.inodeTable(0) + l.itable_blocks;
    }

    fn journalBlock(l: Layout) u32 {
        return l.rootBlock() + 2;
    }

    /// Group 0's data blocks in use: the two directories' and the journal.
    fn group0Used(l: Layout) u32 {
        return 2 + l.journal_blocks;
    }

    fn freeBlocks(l: Layout, g: u32) u32 {
        return l.groupBlocks(g) - l.overhead(g) - (if (g == 0) l.group0Used() else 0);
    }

    fn freeInodes(l: Layout, g: u32) u32 {
        return l.inodes_per_group - @as(u32, if (g == 0) first_ino else 0);
    }

    pub fn inodes(l: Layout) u32 {
        return l.groups * l.inodes_per_group;
    }
};

/// Groups 0 and 1, and powers of 3, 5 and 7, hold backups.
fn hasSuper(g: u32) bool {
    if (g <= 1) return true;
    for ([_]u32{ 3, 5, 7 }) |base| {
        var p: u64 = base;
        while (p < g) p *= base;
        if (p == g) return true;
    }
    return false;
}

pub const Formatter = struct {
    gpa: std.mem.Allocator,
    fd: linux.fd_t,
    layout: Layout,
    /// The group descriptors, as written in every group with a backup.
    gdt: []u8,
    /// Zeros, for the inode tables.
    zeros: []u8,
    uuid: [16]u8,
    now: u32,
    /// The next group to write; `groups` once only the end is left.
    next: u32 = 0,
    done: bool = false,

    /// Formats the partition open at `fd`, `size_bytes` long.
    pub fn init(gpa: std.mem.Allocator, fd: linux.fd_t, size_bytes: u64, uuid: [16]u8, now: u32) Error!Formatter {
        const l = try Layout.plan(size_bytes);
        const gdt = try gpa.alloc(u8, @as(usize, l.gdt_blocks) * block_size);
        errdefer gpa.free(gdt);
        @memset(gdt, 0);
        for (0..l.groups) |gi| {
            const g: u32 = @intCast(gi);
            const d = gdt[gi * desc_size ..][0..desc_size];
            put32(d, 0, l.blockBitmap(g));
            put32(d, 4, l.blockBitmap(g) + 1);
            put32(d, 8, l.inodeTable(g));
            put16(d, 12, @intCast(l.freeBlocks(g)));
            put16(d, 14, @intCast(l.freeInodes(g)));
            put16(d, 16, if (g == 0) 2 else 0); // directories
        }
        const zeros = try gpa.alloc(u8, @as(usize, l.itable_blocks) * block_size);
        @memset(zeros, 0);
        return .{ .gpa = gpa, .fd = fd, .layout = l, .gdt = gdt, .zeros = zeros, .uuid = uuid, .now = now };
    }

    pub fn deinit(f: *Formatter) void {
        f.gpa.free(f.gdt);
        f.gpa.free(f.zeros);
    }

    /// How much is done, from 0 to 1.
    pub fn progress(f: *const Formatter) f32 {
        if (f.done) return 1;
        return @as(f32, @floatFromInt(f.next)) / @as(f32, @floatFromInt(f.layout.groups + 1));
    }

    /// Writes the next group (or, after the last, the root directory and
    /// the superblock). Returns whether the filesystem is finished.
    pub fn step(f: *Formatter) Error!bool {
        if (f.done) return true;
        const l = f.layout;
        if (f.next < l.groups) {
            try f.writeGroup(f.next);
            f.next += 1;
            return false;
        }
        try f.writeRoot();
        // The primary superblock last.
        var sb: [1024]u8 = undefined;
        f.superblock(&sb, 0);
        try pwriteAll(f.fd, &sb, 1024);
        _ = linux.fsync(f.fd);
        f.done = true;
        return true;
    }

    fn writeGroup(f: *Formatter, g: u32) Error!void {
        const l = f.layout;
        const start: u64 = l.groupStart(g);
        if (hasSuper(g) and g != 0) {
            var block: [block_size]u8 = @splat(0);
            f.superblock(block[0..1024], g);
            try pwriteAll(f.fd, &block, start * block_size);
        }
        if (hasSuper(g)) try pwriteAll(f.fd, f.gdt, (start + 1) * block_size);

        // The block bitmap: the metadata (and in group 0 the two
        // directories' blocks) in use, and the bits past the group's end set.
        var bitmap: [block_size]u8 = @splat(0);
        const used = l.overhead(g) + (if (g == 0) l.group0Used() else 0);
        setBits(&bitmap, 0, used);
        setBits(&bitmap, l.groupBlocks(g), 8 * block_size);
        try pwriteAll(f.fd, &bitmap, @as(u64, l.blockBitmap(g)) * block_size);
        // The inode bitmap: the reserved inodes and lost+found in group 0,
        // and the bits past the group's inodes set.
        @memset(&bitmap, 0);
        if (g == 0) setBits(&bitmap, 0, first_ino);
        setBits(&bitmap, l.inodes_per_group, 8 * block_size);
        try pwriteAll(f.fd, &bitmap, (@as(u64, l.blockBitmap(g)) + 1) * block_size);
        try pwriteAll(f.fd, f.zeros, @as(u64, l.inodeTable(g)) * block_size);
    }

    /// The root directory and lost+found: their inodes and directory blocks.
    fn writeRoot(f: *Formatter) Error!void {
        const l = f.layout;
        const root_block = l.rootBlock();
        // Both inodes are in the inode table's first block.
        var block: [block_size]u8 = @splat(0);
        f.dirInode(block[(root_ino - 1) * inode_size ..][0..inode_size], 0o40755, 3, root_block);
        f.dirInode(block[(lost_found_ino - 1) * inode_size ..][0..inode_size], 0o40700, 2, root_block + 1);
        f.journalInode(block[(journal_ino - 1) * inode_size ..][0..inode_size]);
        try pwriteAll(f.fd, &block, @as(u64, l.inodeTable(0)) * block_size);
        try f.writeJournal();

        @memset(&block, 0);
        var at: usize = 0;
        dirEntry(&block, &at, root_ino, ".", 12);
        dirEntry(&block, &at, root_ino, "..", 12);
        dirEntry(&block, &at, lost_found_ino, "lost+found", block_size - 24);
        try pwriteAll(f.fd, &block, @as(u64, root_block) * block_size);
        @memset(&block, 0);
        at = 0;
        dirEntry(&block, &at, lost_found_ino, ".", 12);
        dirEntry(&block, &at, root_ino, "..", block_size - 12);
        try pwriteAll(f.fd, &block, (@as(u64, root_block) + 1) * block_size);
    }

    /// The journal's inode: its blocks are one extent.
    fn journalInode(f: *const Formatter, ino: *[inode_size]u8) void {
        const l = f.layout;
        put16(ino, 0, 0o100600);
        put32(ino, 4, l.journal_blocks * block_size);
        for ([_]usize{ 8, 12, 16 }) |o| put32(ino, o, f.now);
        put16(ino, 26, 1);
        put32(ino, 28, l.journal_blocks * (block_size / 512));
        put32(ino, 32, 0x80000); // extents
        extentTree(ino[40..100], l.journalBlock(), l.journal_blocks);
        put16(ino, 128, 32);
        put32(ino, 144, f.now);
    }

    /// The journal's superblock (big-endian, as jbd2's are): empty, with
    /// nothing to replay.
    fn writeJournal(f: *const Formatter) Error!void {
        var block: [block_size]u8 = @splat(0);
        const be = struct {
            fn put(b: []u8, at: usize, v: u32) void {
                std.mem.writeInt(u32, b[at..][0..4], v, .big);
            }
        }.put;
        be(&block, 0x00, 0xc03b3998); // magic
        be(&block, 0x04, 4); // superblock, version 2
        be(&block, 0x0c, block_size);
        be(&block, 0x10, f.layout.journal_blocks);
        be(&block, 0x14, 1); // the first log block
        be(&block, 0x18, 1); // the first transaction's sequence
        be(&block, 0x40, 1); // one filesystem uses it
        @memcpy(block[0x100..][0..16], &f.uuid);
        try pwriteAll(f.fd, &block, @as(u64, f.layout.journalBlock()) * block_size);
    }

    fn dirInode(f: *const Formatter, ino: *[inode_size]u8, mode: u16, links: u16, block: u32) void {
        put16(ino, 0, mode);
        put32(ino, 4, block_size); // size
        for ([_]usize{ 8, 12, 16 }) |o| put32(ino, o, f.now); // atime, ctime, mtime
        put16(ino, 26, links);
        put32(ino, 28, block_size / 512); // 512-byte sectors
        put32(ino, 40, block); // i_block[0]
        put16(ino, 128, 32); // i_extra_isize
        put32(ino, 144, f.now); // crtime
    }

    fn superblock(f: *const Formatter, sb: *[1024]u8, group: u32) void {
        const l = f.layout;
        @memset(sb, 0);
        var free_blocks: u32 = 0;
        var free_inodes: u32 = 0;
        for (0..l.groups) |g| {
            free_blocks += l.freeBlocks(@intCast(g));
            free_inodes += l.freeInodes(@intCast(g));
        }
        put32(sb, 0, l.inodes());
        put32(sb, 4, l.blocks);
        put32(sb, 8, 0); // reserved for root: none (one user)
        put32(sb, 12, free_blocks);
        put32(sb, 16, free_inodes);
        put32(sb, 20, 0); // first data block (4 KiB blocks)
        put32(sb, 24, 2); // log2(block size) - 10
        put32(sb, 28, 2);
        put32(sb, 32, blocks_per_group);
        put32(sb, 36, blocks_per_group);
        put32(sb, 40, l.inodes_per_group);
        put32(sb, 48, f.now); // written
        put16(sb, 54, 0xffff); // no mount count limit
        put16(sb, 56, 0xef53); // magic
        put16(sb, 58, 1); // clean
        put16(sb, 60, 1); // on errors, continue
        put32(sb, 64, f.now); // last checked
        put32(sb, 76, 1); // revision 1
        put32(sb, 84, first_ino);
        put16(sb, 88, inode_size);
        put16(sb, 90, @intCast(group));
        put32(sb, 92, 0x4); // compatible: a journal
        put32(sb, 96, 0x2 | 0x40); // incompatible: file types in directories, extents
        put32(sb, 100, 0x1 | 0x2); // read-only compatible: sparse_super, large files
        @memcpy(sb[104..120], &f.uuid);
        @memcpy(sb[120..][0..11], "dazzle-data");
        put32(sb, 224, journal_ino);
        // A copy of the journal inode's blocks and size, in case it is lost.
        var tree: [60]u8 = @splat(0);
        extentTree(&tree, l.journalBlock(), l.journal_blocks);
        @memcpy(sb[268..][0..60], &tree);
        put32(sb, 268 + 64, l.journal_blocks * block_size);
        sb[253] = 1; // the copy is of the inode's blocks
        put32(sb, 264, f.now); // made
        put16(sb, 348, 32); // minimum and wanted extra inode size
        put16(sb, 350, 32);
    }
};

/// An inode's block map as an extent tree with one extent.
fn extentTree(b: []u8, start: u32, len: u32) void {
    put16(b, 0, 0xf30a); // magic
    put16(b, 2, 1); // entries
    put16(b, 4, 4); // room for
    put16(b, 6, 0); // depth: these are the extents
    put32(b, 12, 0); // the first logical block
    put16(b, 16, @intCast(len));
    put16(b, 18, 0); // start (high)
    put32(b, 20, start);
}

fn dirEntry(block: []u8, at: *usize, ino: u32, name: []const u8, rec_len: u16) void {
    const e = block[at.*..];
    put32(e, 0, ino);
    put16(e, 4, rec_len);
    e[6] = @intCast(name.len);
    e[7] = 2; // a directory
    @memcpy(e[8..][0..name.len], name);
    at.* += rec_len;
}

fn setBits(bitmap: []u8, from: u32, to: u32) void {
    var i = from;
    while (i < to) : (i += 1) bitmap[i / 8] |= @as(u8, 1) << @intCast(i % 8);
}

fn put16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

fn pwriteAll(fd: linux.fd_t, data: []const u8, offset: u64) sys.Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = try sys.check(linux.pwrite(fd, data[done..].ptr, data.len - done, @intCast(offset + done)));
        if (n == 0) return error.Unexpected;
        done += n;
    }
}

const testing = std.testing;

test "layouts" {
    try testing.expect(hasSuper(0) and hasSuper(1) and hasSuper(3) and hasSuper(25) and hasSuper(49) and hasSuper(243));
    try testing.expect(!hasSuper(2) and !hasSuper(4) and !hasSuper(26) and !hasSuper(50));
    // A 16 GB card's partition: 119 groups of 128 MiB (their descriptors
    // fit a block), 512 inodes a group (32 blocks of them).
    const l = try Layout.plan(16_000_000_000 - 64 * 1024 * 1024);
    try testing.expectEqual(@as(u32, 512), l.inodes_per_group);
    try testing.expectEqual(@as(u32, 32), l.itable_blocks);
    try testing.expectEqual(@as(u32, (l.blocks + blocks_per_group - 1) / blocks_per_group), l.groups);
    try testing.expectEqual(@as(u32, 119), l.groups);
    try testing.expectEqual(@as(u32, 1), l.gdt_blocks);
    // A last group too small to be worth it goes.
    const cut = try Layout.plan((2 * blocks_per_group + 100) * @as(u64, block_size));
    try testing.expectEqual(@as(u32, 2), cut.groups);
    try testing.expectEqual(@as(u32, 2 * blocks_per_group), cut.blocks);
    try testing.expectError(error.TooSmall, Layout.plan(100 * block_size));
}

test "a formatted partition has a valid superblock and root directory" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/dazzle-mkfs-test-{d}", .{linux.getpid()});
    const fd = try sys.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
    defer {
        sys.close(fd);
        _ = linux.unlink(path);
    }
    const size: u64 = 300 * 1024 * 1024;
    _ = try sys.check(linux.ftruncate(fd, @intCast(size)));
    var f = try Formatter.init(testing.allocator, fd, size, @splat(0x42), 1_800_000_000);
    defer f.deinit();
    var steps: usize = 0;
    while (!try f.step()) steps += 1;
    try testing.expectEqual(@as(usize, f.layout.groups), steps);
    try testing.expectEqual(@as(f32, 1), f.progress());

    var sb: [1024]u8 = undefined;
    _ = try sys.check(linux.pread(fd, &sb, sb.len, 1024));
    try testing.expectEqual(@as(u16, 0xef53), std.mem.readInt(u16, sb[56..58], .little));
    try testing.expectEqual(f.layout.blocks, std.mem.readInt(u32, sb[4..8], .little));
    // Group 1's backup says which group it is.
    _ = try sys.check(linux.pread(fd, &sb, sb.len, blocks_per_group * block_size));
    try testing.expectEqual(@as(u16, 0xef53), std.mem.readInt(u16, sb[56..58], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, sb[90..92], .little));
    // The root directory lists lost+found.
    var block: [block_size]u8 = undefined;
    _ = try sys.check(linux.pread(fd, &block, block.len, @as(i64, f.layout.rootBlock()) * block_size));
    try testing.expectEqualStrings("lost+found", block[24 + 8 ..][0..10]);
}
