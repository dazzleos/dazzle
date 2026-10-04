//! The SD card's free space, for files. The firmware loads the system from
//! the card's FAT partition into memory, and the rest of the card is free;
//! on the first run the system manager (system.zig) gives it a partition
//! of its own (`planPartition`, `addPartition`) and a filesystem
//! (mkfs.zig), and init mounts that at /data at every boot after
//! (`mountData`). /data/system holds the system's settings (the computer's
//! name, and whether setup has finished), and /data/user the user's files.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const proto = sys.system;
const print = sys.print;

/// The card (on the SDHOST controller), and the partition for files.
pub const card = "/dev/mmcblk0";
pub const data_partition = "/dev/mmcblk0p2";

const sector = 512;
/// Partitions start on 4 MiB boundaries (SD cards' erase blocks).
const align_sectors = 8192;
/// Less than this is not worth having.
const min_sectors = 64 * 1024 * 1024 / sector;
const linux_type = 0x83;

pub const Error = error{ TooSmall, NoRoom, NotMbr } || sys.Error;

/// What init finds at boot.
pub const Boot = struct {
    card: bool = false,
    /// /data is mounted.
    mounted: bool = false,
    setup_done: bool = false,
    hostname: proto.Hostname = proto.Hostname.parse("dazzle").?,
};

/// Waits for the card (it is found a moment after boot) and mounts its
/// filesystem, if it has one; then reads the settings kept there.
pub fn boot() Boot {
    var b: Boot = .{};
    _ = linux.mkdir(proto.data_dir, 0o755);
    var waited: u32 = 0;
    while (!exists(card) and waited < 3000) : (waited += 100) sys.sleepMs(100);
    b.card = exists(card);
    if (!b.card) {
        print("dazzle: no SD card found: files will not be kept\n", .{});
        return b;
    }
    // The partition's device node comes with the card's.
    if (!exists(data_partition) or !hasFilesystem(data_partition)) return b;
    b.mounted = mountData();
    if (!b.mounted) return b;
    b.setup_done = exists(proto.setup_done_file);
    var buf: [80]u8 = undefined;
    if (sys.readFile(proto.hostname_file, &buf)) |text| {
        if (proto.Hostname.parse(std.mem.trim(u8, text, " \n"))) |h| b.hostname = h;
    }
    return b;
}

/// Mounts the partition for files at /data. Returns whether it is.
pub fn mountData() bool {
    const flags = linux.MS.NOATIME | linux.MS.NODEV | linux.MS.NOSUID;
    _ = sys.check(linux.mount(data_partition, proto.data_dir, "ext4", flags, 0)) catch |err| {
        print("dazzle: cannot mount {s} at {s}: {s}\n", .{ data_partition, proto.data_dir, @errorName(err) });
        return false;
    };
    print("dazzle: mounted {s} at {s}\n", .{ data_partition, proto.data_dir });
    return true;
}

pub fn exists(path: [*:0]const u8) bool {
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
}

/// Whether the partition at `path` holds an ext2/3/4 filesystem.
pub fn hasFilesystem(path: [*:0]const u8) bool {
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return false;
    defer sys.close(fd);
    var magic: [2]u8 = undefined;
    const n = sys.check(linux.pread(fd, &magic, 2, 1024 + 56)) catch return false;
    return n == 2 and std.mem.readInt(u16, &magic, .little) == 0xef53;
}

/// Where the partition for files goes: its entry in the partition table,
/// first sector and length.
pub const Plan = struct { entry: u2, start: u32, sectors: u32 };

/// Plans the partition for files in the master boot record `mbr` of a card
/// of `disk_sectors`: an existing Linux partition after the first (one
/// made before, if formatting it did not finish), or else a new one in the
/// first free entry, from the end of the last partition (rounded up to
/// 4 MiB) to the end of the card.
pub fn planPartition(mbr: *const [sector]u8, disk_sectors: u64) Error!Plan {
    if (mbr[510] != 0x55 or mbr[511] != 0xaa) return error.NotMbr;
    var end: u64 = 0;
    var free: ?u2 = null;
    for (0..4) |i| {
        const e = mbr[446 + i * 16 ..][0..16];
        const kind = e[4];
        const start = std.mem.readInt(u32, e[8..12], .little);
        const len = std.mem.readInt(u32, e[12..16], .little);
        if (kind == 0 or len == 0) {
            if (free == null) free = @intCast(i);
            continue;
        }
        if (i > 0 and kind == linux_type) return .{ .entry = @intCast(i), .start = start, .sectors = len };
        end = @max(end, @as(u64, start) + len);
    }
    const entry = free orelse return error.NoRoom;
    const start = std.mem.alignForward(u64, end, align_sectors);
    if (start >= disk_sectors or disk_sectors - start < min_sectors) return error.TooSmall;
    // The table counts sectors in 32 bits (2 TiB).
    const len = @min(disk_sectors - start, std.math.maxInt(u32) - start);
    if (start > std.math.maxInt(u32) or len < min_sectors) return error.TooSmall;
    return .{ .entry = entry, .start = @intCast(start), .sectors = @intCast(len) };
}

/// Writes the planned partition into the table.
pub fn addPartition(mbr: *[sector]u8, plan: Plan) void {
    const e = mbr[446 + @as(usize, plan.entry) * 16 ..][0..16];
    @memset(e, 0);
    // Addressed by LBA only: the CHS fields say so.
    e[1] = 0xfe;
    e[2] = 0xff;
    e[3] = 0xff;
    e[4] = linux_type;
    e[5] = 0xfe;
    e[6] = 0xff;
    e[7] = 0xff;
    std.mem.writeInt(u32, e[8..12], plan.start, .little);
    std.mem.writeInt(u32, e[12..16], plan.sectors, .little);
}

/// The card's size, in sectors.
pub fn diskSectors(fd: linux.fd_t) sys.Error!u64 {
    var bytes: u64 = 0;
    _ = try sys.check(linux.ioctl(fd, linux.IOCTL.IOR(0x12, 114, usize), @intFromPtr(&bytes))); // BLKGETSIZE64
    return bytes / sector;
}

/// Has the kernel read the partition table again (so the new partition's
/// device appears), or else adds the partition itself.
pub fn announcePartition(fd: linux.fd_t, plan: Plan) sys.Error!void {
    const blkrrpart = linux.IOCTL.IO(0x12, 95);
    if (linux.errno(linux.ioctl(fd, blkrrpart, 0)) == .SUCCESS) return;
    const BlkpgPartition = extern struct {
        start: i64,
        length: i64,
        pno: c_int,
        devname: [64]u8 = @splat(0),
        volname: [64]u8 = @splat(0),
    };
    const BlkpgArg = extern struct { op: c_int, flags: c_int = 0, datalen: c_int, data: *anyopaque };
    var part: BlkpgPartition = .{ .start = @as(i64, plan.start) * sector, .length = @as(i64, plan.sectors) * sector, .pno = @as(c_int, plan.entry) + 1 };
    var arg: BlkpgArg = .{ .op = 1, .datalen = @sizeOf(BlkpgPartition), .data = &part }; // BLKPG_ADD_PARTITION
    _ = try sys.check(linux.ioctl(fd, linux.IOCTL.IO(0x12, 105), @intFromPtr(&arg))); // BLKPG
}

const testing = std.testing;

/// A table with a boot partition from 1 MiB to 64 MiB (mkimage's are
/// smaller: as big as their files need).
fn imageMbr() [sector]u8 {
    var mbr: [sector]u8 = @splat(0);
    const e = mbr[446..][0..16];
    e[0] = 0x80;
    e[4] = 0x0c;
    std.mem.writeInt(u32, e[8..12], 2048, .little);
    std.mem.writeInt(u32, e[12..16], 64 * 2048 - 2048, .little);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    return mbr;
}

test "the partition for files goes after the system's, to the end of the card" {
    var mbr = imageMbr();
    const disk: u64 = 16_000_000_000 / sector;
    const plan = try planPartition(&mbr, disk);
    try testing.expectEqual(@as(u2, 1), plan.entry);
    // 64 MiB is already on a 4 MiB boundary.
    try testing.expectEqual(@as(u32, 64 * 2048), plan.start);
    try testing.expectEqual(@as(u32, @intCast(disk - 64 * 2048)), plan.sectors);
    addPartition(&mbr, plan);
    try testing.expectEqual(@as(u8, 0x83), mbr[446 + 16 + 4]);
    // Made before (formatting did not finish): the same one again.
    const again = try planPartition(&mbr, disk);
    try testing.expectEqual(plan, again);

    // A card the size of the image: no room.
    var small = imageMbr();
    try testing.expectError(error.TooSmall, planPartition(&small, 64 * 2048));
    try testing.expectError(error.TooSmall, planPartition(&small, 64 * 2048 + 1000));
    // An end not on a boundary is rounded up.
    std.mem.writeInt(u32, small[446 + 12 ..][0..4], 100_000, .little);
    try testing.expectEqual(@as(u32, 106_496), (try planPartition(&small, disk)).start);
    // Not a partition table.
    var blank: [sector]u8 = @splat(0);
    try testing.expectError(error.NotMbr, planPartition(&blank, disk));
    // Full.
    var full = imageMbr();
    for (1..4) |i| {
        full[446 + i * 16 + 4] = 0x0b;
        std.mem.writeInt(u32, full[446 + i * 16 + 8 ..][0..4], @intCast(200_000 * i), .little);
        std.mem.writeInt(u32, full[446 + i * 16 + 12 ..][0..4], 1000, .little);
    }
    try testing.expectError(error.NoRoom, planPartition(&full, disk));
}
