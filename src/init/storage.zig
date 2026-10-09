//! The SD card. Its first partition (FAT) is the boot partition: the
//! firmware, config.txt, and two OS slots (slot-a/, slot-b/), each a whole
//! system that the firmware loads into memory (config.txt's os_prefix says
//! which). Init mounts it, read-only, at /boot (`mountBoot`). The apps are
//! not there: they are installed (in setup, or later from Settings) in
//! /data/apps.
//!
//! The image is just big enough for its files, but laid out for a bigger
//! partition (mkimage's --grow-to): on the first start, before anything
//! follows it on the card, init grows it to that (`growBoot`), changing
//! only its length in the partition table and its boot sector. That makes
//! room for the second OS slot (system.zig copies the first there) and
//! for updates.
//!
//! The rest of the card is free, for files;
//! on the first run the system manager (system.zig) gives it a partition
//! of its own (`planPartition`, `addPartition`) and a filesystem
//! (mkfs.zig), and init mounts that at /data at every boot after
//! (`mountData`). /data/system holds the system's settings (the computer's
//! name, and whether setup has finished), and /data/user the user's files.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const proto = sys.system;
const trial = @import("trial.zig");
const print = sys.print;

/// The card (on the SDHOST controller), and the partition for files.
pub const card = "/dev/mmcblk0";
pub const boot_partition = "/dev/mmcblk0p1";
pub const data_partition = "/dev/mmcblk0p2";
pub const boot_dir = "/boot";
/// FAT has no owners or permissions: everything is root's, and anyone's to
/// read (and run).
pub const boot_options = "fmask=0022,dmask=0022";

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
    /// The OS slot the system was started from ('a' or 'b'), from the
    /// kernel's command line.
    slot: ?u8 = null,
    /// /data is mounted.
    mounted: bool = false,
    setup_done: bool = false,
    hostname: proto.Hostname = proto.Hostname.parse("dazzle").?,
    /// Whether this start tries an update (see trial.zig).
    trial: trial.Outcome = .none,
};

/// Waits for the card (it is found a moment after boot) and mounts its
/// filesystem, if it has one; then reads the settings kept there.
pub fn boot() Boot {
    var b: Boot = .{};
    var cmdline: [1024]u8 = undefined;
    if (sys.readFile("/proc/cmdline", &cmdline)) |text| b.slot = parseSlot(text);
    if (b.slot) |s| print("dazzle: started from OS slot {c}\n", .{std.ascii.toUpper(s)});
    _ = linux.mkdir(proto.data_dir, 0o755);
    var waited: u32 = 0;
    while (!exists(card) and waited < 3000) : (waited += 100) sys.sleepMs(100);
    b.card = exists(card);
    if (!b.card) {
        print("dazzle: no SD card found: files will not be kept\n", .{});
        return b;
    }
    // The partitions' device nodes come with the card's.
    growBoot();
    mountBoot();
    // First, before anything can fail: an update being tried.
    b.trial = trial.atBoot(b.slot);
    if (!exists(data_partition) or !hasFilesystem(data_partition)) return b;
    b.mounted = mountData();
    if (!b.mounted) return b;
    makeUserDirs();
    b.setup_done = exists(proto.setup_done_file);
    var buf: [80]u8 = undefined;
    if (sys.readFile(proto.hostname_file, &buf)) |text| {
        if (proto.Hostname.parse(std.mem.trim(u8, text, " \n"))) |h| b.hostname = h;
    }
    return b;
}

/// What `b` found at boot, as it is now (the system manager may have
/// prepared the card and finished setup since).
pub fn state(b: Boot) Boot {
    var now = b;
    // /data, once mounted, has the user's files in it.
    now.mounted = b.mounted or exists(proto.user_dir);
    now.setup_done = b.setup_done or exists(proto.setup_done_file);
    return now;
}

/// The slot in a kernel command line's dazzle.slot=<a|b>.
pub fn parseSlot(cmdline: []const u8) ?u8 {
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (it.next()) |arg| {
        const value = if (std.mem.startsWith(u8, arg, "dazzle.slot=")) arg["dazzle.slot=".len..] else continue;
        if (value.len == 1 and (value[0] == 'a' or value[0] == 'b')) return value[0];
    }
    return null;
}

/// Grows the boot partition, if it can grow (`planBootGrowth`). The table
/// first: if the power goes before the boot sector is written, the
/// filesystem is only smaller than its partition, and grows next time.
fn growBoot() void {
    const disk = sys.open(card, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch return;
    defer sys.close(disk);
    var mbr: [sector]u8 = undefined;
    var bs: [sector]u8 = undefined;
    if ((sys.check(linux.pread(disk, &mbr, sector, 0)) catch 0) != sector) return;
    const start: u64 = std.mem.readInt(u32, mbr[446 + 8 ..][0..4], .little);
    if ((sys.check(linux.pread(disk, &bs, sector, @intCast(start * sector))) catch 0) != sector) return;
    const sectors = diskSectors(disk) catch return;
    const new_len = planBootGrowth(&mbr, &bs, sectors) orelse return;
    std.mem.writeInt(u32, mbr[446 + 12 ..][0..4], new_len, .little);
    setFatSectors(&bs, new_len);
    const ok = blk: {
        if ((sys.check(linux.pwrite(disk, &mbr, sector, 0)) catch 0) != sector) break :blk false;
        _ = linux.fsync(disk);
        if ((sys.check(linux.pwrite(disk, &bs, sector, @intCast(start * sector))) catch 0) != sector) break :blk false;
        _ = linux.fsync(disk);
        break :blk true;
    };
    if (!ok) {
        print(sys.log_warning ++ "dazzle: cannot grow {s}\n", .{boot_partition});
        return;
    }
    resizePartition(disk, .{ .entry = 0, .start = @intCast(start), .sectors = new_len }) catch |err|
        print(sys.log_warning ++ "dazzle: cannot resize {s}: {s}\n", .{ boot_partition, @errorName(err) });
    print("dazzle: grew {s} to {d} MiB\n", .{ boot_partition, new_len / 2048 });
}

/// The length the boot partition (the first, FAT16) can grow to, in
/// sectors, if it can grow: when it is the only partition, and the card
/// has room for it and for files after it. It grows as far as its FATs
/// can count clusters (mkimage made them big enough), and ends on a 4 MiB
/// boundary.
pub fn planBootGrowth(mbr: *const [sector]u8, bs: *const [sector]u8, disk_sectors: u64) ?u32 {
    if (mbr[510] != 0x55 or mbr[511] != 0xaa) return null;
    if (!isFat16Type(mbr[446 + 4])) return null;
    for (1..4) |i| {
        const e = mbr[446 + i * 16 ..][0..16];
        if (e[4] != 0 and std.mem.readInt(u32, e[12..16], .little) != 0) return null;
    }
    const start: u64 = std.mem.readInt(u32, mbr[446 + 8 ..][0..4], .little);
    const len: u64 = std.mem.readInt(u32, mbr[446 + 12 ..][0..4], .little);
    const f = FatGeometry.read(bs) orelse return null;
    if (f.sectors > len) return null;
    // As many clusters as the FATs count (two reserved entries), and
    // FAT16 allows.
    const clusters = @min(@as(u64, f.fat_sectors) * sector / 2 - 2, 65524);
    const end = std.mem.alignBackward(u64, start + f.dataStart() + clusters * f.sectors_per_cluster, align_sectors);
    if (end <= start + f.sectors) return null;
    if (end + min_sectors > disk_sectors) return null;
    return @intCast(end - start);
}

fn isFat16Type(kind: u8) bool {
    return kind == 0x04 or kind == 0x06 or kind == 0x0e;
}

/// What growing a FAT16 filesystem needs from its boot sector.
const FatGeometry = struct {
    sectors_per_cluster: u32,
    reserved: u32,
    fats: u32,
    root_sectors: u32,
    fat_sectors: u32,
    sectors: u32,

    fn read(bs: *const [sector]u8) ?FatGeometry {
        if (bs[510] != 0x55 or bs[511] != 0xaa) return null;
        if (std.mem.readInt(u16, bs[11..13], .little) != sector) return null;
        if (!std.mem.eql(u8, bs[54..62], "FAT16   ")) return null;
        const g: FatGeometry = .{
            .sectors_per_cluster = bs[13],
            .reserved = std.mem.readInt(u16, bs[14..16], .little),
            .fats = bs[16],
            .root_sectors = @as(u32, std.mem.readInt(u16, bs[17..19], .little)) * 32 / sector,
            .fat_sectors = std.mem.readInt(u16, bs[22..24], .little),
            .sectors = switch (std.mem.readInt(u16, bs[19..21], .little)) {
                0 => std.mem.readInt(u32, bs[32..36], .little),
                else => |n| n,
            },
        };
        if (g.sectors_per_cluster == 0 or g.fats == 0 or g.fat_sectors == 0) return null;
        return g;
    }

    fn dataStart(g: FatGeometry) u32 {
        return g.reserved + g.fats * g.fat_sectors + g.root_sectors;
    }
};

/// Sets a FAT boot sector's count of sectors.
fn setFatSectors(bs: *[sector]u8, sectors: u32) void {
    if (sectors < 65536) {
        std.mem.writeInt(u16, bs[19..21], @intCast(sectors), .little);
        std.mem.writeInt(u32, bs[32..36], 0, .little);
    } else {
        std.mem.writeInt(u16, bs[19..21], 0, .little);
        std.mem.writeInt(u32, bs[32..36], sectors, .little);
    }
}

/// The user's folders on /data (the apps, and where updates are
/// downloaded), if they are not there. Init calls it as root, the system
/// manager as the user: either way they are the user's.
pub fn makeUserDirs() void {
    for ([_][:0]const u8{ proto.apps_dir, proto.update_dir }) |dir| {
        if (linux.errno(linux.mkdir(dir, 0o755)) != .SUCCESS) continue;
        if (linux.getuid() == 0) _ = linux.chown(dir, sys.user.uid, sys.user.gid);
    }
}

/// Mounts the boot partition, read-only, at /boot.
fn mountBoot() void {
    _ = linux.mkdir(boot_dir, 0o755);
    const flags = linux.MS.RDONLY | linux.MS.NODEV | linux.MS.NOSUID;
    _ = sys.check(linux.mount(boot_partition, boot_dir, "vfat", flags, @intFromPtr(boot_options))) catch |err| {
        print(sys.log_warning ++ "dazzle: cannot mount {s} at {s}: {s}\n", .{ boot_partition, boot_dir, @errorName(err) });
        return;
    };
    print("dazzle: mounted {s} at {s}\n", .{ boot_partition, boot_dir });
}

/// Mounts the partition for files at /data. Returns whether it is.
pub fn mountData() bool {
    const flags = linux.MS.NOATIME | linux.MS.NODEV | linux.MS.NOSUID;
    _ = sys.check(linux.mount(data_partition, proto.data_dir, "ext4", flags, 0)) catch |err| {
        print(sys.log_warning ++ "dazzle: cannot mount {s} at {s}: {s}\n", .{ data_partition, proto.data_dir, @errorName(err) });
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
    return changePartition(fd, plan, 1); // BLKPG_ADD_PARTITION
}

/// Has the kernel read the partition table again, or else tells it a
/// partition's new size.
fn resizePartition(fd: linux.fd_t, plan: Plan) sys.Error!void {
    return changePartition(fd, plan, 3); // BLKPG_RESIZE_PARTITION
}

fn changePartition(fd: linux.fd_t, plan: Plan, op: c_int) sys.Error!void {
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
    var arg: BlkpgArg = .{ .op = op, .datalen = @sizeOf(BlkpgPartition), .data = &part };
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

test "the OS slot is on the kernel's command line" {
    try std.testing.expectEqual(@as(?u8, 'b'), parseSlot("loglevel=6 dazzle.slot=b rdinit=/os/init\n"));
    try std.testing.expectEqual(@as(?u8, 'a'), parseSlot("dazzle.slot=a"));
    try std.testing.expectEqual(@as(?u8, null), parseSlot("loglevel=6 dazzle.slot=c"));
    try std.testing.expectEqual(@as(?u8, null), parseSlot("loglevel=6"));
}

/// A FAT16 boot sector laid out as mkimage lays out one to grow to 128 MiB
/// (2 KiB clusters, 254 sectors of FAT each), `sectors` long.
fn growableBootSector(sectors: u32) [sector]u8 {
    var bs: [sector]u8 = @splat(0);
    std.mem.writeInt(u16, bs[11..13], sector, .little);
    bs[13] = 4;
    std.mem.writeInt(u16, bs[14..16], 1, .little);
    bs[16] = 2;
    std.mem.writeInt(u16, bs[17..19], 512, .little);
    std.mem.writeInt(u16, bs[22..24], 254, .little);
    setFatSectors(&bs, sectors);
    @memcpy(bs[54..62], "FAT16   ");
    bs[510] = 0x55;
    bs[511] = 0xaa;
    return bs;
}

test "the boot partition grows as far as its FATs reach, once, before /data" {
    const disk: u64 = 16_000_000_000 / sector;
    var mbr = imageMbr();
    mbr[446 + 4] = 0x0e;
    // A 10 MiB image.
    std.mem.writeInt(u32, mbr[446 + 12 ..][0..4], 9 * 2048, .little);
    var bs = growableBootSector(9 * 2048);
    // 254 sectors of FAT count 65022 clusters of 4 sectors, after 541 of
    // the rest: up to 2048 + 260629, ending on the boundary before.
    const len = planBootGrowth(&mbr, &bs, disk).?;
    try testing.expectEqual(@as(u32, 128 * 2048 - 2048), len);
    // Grown: no further.
    std.mem.writeInt(u32, mbr[446 + 12 ..][0..4], len, .little);
    setFatSectors(&bs, len);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bs[19..21], .little));
    try testing.expectEqual(@as(?u32, null), planBootGrowth(&mbr, &bs, disk));
    // Only the table written (the power went): the filesystem still grows.
    var half = growableBootSector(9 * 2048);
    try testing.expectEqual(@as(?u32, len), planBootGrowth(&mbr, &half, disk));
    // Not once /data is there, nor on a card with no room for it after.
    var data = imageMbr();
    data[446 + 4] = 0x0e;
    std.mem.writeInt(u32, data[446 + 12 ..][0..4], 9 * 2048, .little);
    addPartition(&data, try planPartition(&data, disk));
    try testing.expectEqual(@as(?u32, null), planBootGrowth(&data, &half, disk));
    try testing.expectEqual(@as(?u32, null), planBootGrowth(&mbr, &half, 160 * 2048));
    // Not FAT16.
    var other = half;
    @memcpy(other[54..62], "FAT32   ");
    try testing.expectEqual(@as(?u32, null), planBootGrowth(&mbr, &other, disk));
}
