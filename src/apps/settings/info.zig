//! What the settings app shows about the machine, read from the kernel
//! (/proc, /sys, the device tree) and the network interfaces. All
//! of it is readable by the unprivileged Dazzle user.
//!
//! `System` does not change while the system runs and is read once;
//! `Usage` and `Network` are read again every second.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

/// A short piece of text kept in place.
pub fn Str(comptime n: usize) type {
    return struct {
        const Self = @This();
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn slice(s: *const Self) []const u8 {
            return s.buf[0..s.len];
        }

        pub fn set(s: *Self, text: []const u8) void {
            s.len = @min(text.len, n);
            @memcpy(s.buf[0..s.len], text[0..s.len]);
        }

        pub fn print(s: *Self, comptime fmt: []const u8, args: anytype) void {
            // Cut short if it does not fit.
            s.len = if (std.fmt.bufPrint(&s.buf, fmt, args)) |out| out.len else |_| n;
        }

        pub fn of(text: []const u8) Self {
            var s: Self = .{};
            s.set(text);
            return s;
        }
    };
}

// --- System ---------------------------------------------------------------------

/// What does not change while the system runs.
pub const System = struct {
    /// The board, from the device tree: "Raspberry Pi Zero W Rev 1.1".
    model: Str(64) = .{},
    /// The board's serial number, if the firmware gives it.
    serial: Str(24) = .{},
    cores: u32 = 0,
    /// Linux's version ("6.12.0 (armv6l)") and the machine's name on the
    /// network.
    kernel: Str(64) = .{},
    hostname: Str(64) = .{},
    /// The card (or flash) the system runs from.
    card: Card = .{},

    pub fn read() System {
        var h: System = .{};
        var buf: [4096]u8 = undefined;
        const dt = "/sys/firmware/devicetree/base";
        if (sys.readFile(dt ++ "/model", &buf)) |m| h.model.set(std.mem.trimEnd(u8, m, "\x00\n"));
        if (sys.readFile("/proc/cpuinfo", &buf)) |info| {
            const c = parseCpuinfo(info);
            h.cores = c.cores;
            h.serial = c.serial;
        }
        // Linux on 32-bit ARM only fills in /proc/cpuinfo's serial number
        // when booted the old way (ATAGs); the firmware puts it in the
        // device tree too.
        if (h.serial.len == 0) if (sys.readFile(dt ++ "/system/linux,serial", &buf)) |raw| {
            h.serial = serialFromDeviceTree(raw);
        };
        h.card = Card.read("/sys/block/mmcblk0");
        var uts: linux.utsname = undefined;
        if (linux.errno(linux.uname(&uts)) == .SUCCESS) {
            h.kernel.print("{s} ({s})", .{ std.mem.sliceTo(&uts.release, 0), std.mem.sliceTo(&uts.machine, 0) });
            h.hostname.set(std.mem.sliceTo(&uts.nodename, 0));
        }
        return h;
    }
};

/// The SD card (or eMMC flash) the system runs from: how big it is, and
/// who made it, if its maker's code is known.
pub const Card = struct {
    /// In bytes (0: not known).
    bytes: u64 = 0,
    maker: []const u8 = "",

    /// From the block device's directory in sysfs (`/sys/block/mmcblk0`).
    pub fn read(dir: []const u8) Card {
        var c: Card = .{};
        var path_buf: [96]u8 = undefined;
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&path_buf, "{s}/size", .{dir}, 0)) |path| {
            if (sys.readFile(path, &buf)) |text| {
                const sectors = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
                c.bytes = sectors * 512;
            }
        } else |_| {}
        // The makers' codes are SD cards' (eMMC's differ).
        const is_sd = if (std.fmt.bufPrintSentinel(&path_buf, "{s}/device/type", .{dir}, 0)) |path|
            std.mem.eql(u8, std.mem.trim(u8, sys.readFile(path, &buf) orelse "", " \n"), "SD")
        else |_| false;
        if (is_sd) if (std.fmt.bufPrintSentinel(&path_buf, "{s}/device/manfid", .{dir}, 0)) |path| {
            if (sys.readFile(path, &buf)) |text| {
                const id = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 0) catch 0;
                c.maker = sdMaker(id) orelse "";
            }
        } else |_| {};
        return c;
    }

    /// "32 GB SanDisk card": its size as cards are sold (in thousands of
    /// millions of bytes), and its maker if known.
    pub fn describe(c: Card, buf: []u8) []const u8 {
        if (c.bytes == 0) return "";
        var size_buf: [16]u8 = undefined;
        const gb = @as(f64, @floatFromInt(c.bytes)) / 1e9;
        const size = if (gb >= 1) std.fmt.bufPrint(&size_buf, "{d:.0} GB", .{gb}) catch "" else std.fmt.bufPrint(&size_buf, "{d:.0} MB", .{gb * 1000}) catch "";
        if (c.maker.len == 0) return std.fmt.bufPrint(buf, "{s}", .{size}) catch "";
        return std.fmt.bufPrint(buf, "{s}, made by {s}", .{ size, c.maker }) catch "";
    }
};

test "the card's size and maker are read from sysfs, and said as cards are sold" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/dazzle-card-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var path_buf: [96]u8 = undefined;
    _ = linux.mkdir(try std.fmt.bufPrintSentinel(&path_buf, "{s}/device", .{dir}, 0), 0o755);
    try sys.files.writeNew(try std.fmt.bufPrintSentinel(&path_buf, "{s}/size", .{dir}, 0), "62333952\n");
    try sys.files.writeNew(try std.fmt.bufPrintSentinel(&path_buf, "{s}/device/type", .{dir}, 0), "SD\n");
    try sys.files.writeNew(try std.fmt.bufPrintSentinel(&path_buf, "{s}/device/manfid", .{dir}, 0), "0x000003\n");
    const card = Card.read(dir);
    try std.testing.expectEqual(@as(u64, 62333952 * 512), card.bytes);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("32 GB, made by SanDisk", card.describe(&buf));
    // A maker not known, or none: just the size.
    try std.testing.expectEqualStrings("8 GB", (Card{ .bytes = 7_948_206_080 }).describe(&buf));
    try std.testing.expect(sdMaker(0xee) == null);
    // Nothing there: nothing known.
    try std.testing.expectEqual(@as(u64, 0), Card.read("/tmp/dazzle-no-such-card").bytes);
}

/// Who made an SD card, by its maker's code (as mmc-utils knows them).
pub fn sdMaker(id: u32) ?[]const u8 {
    return switch (id) {
        0x01 => "Panasonic",
        0x02 => "Toshiba",
        0x03 => "SanDisk",
        0x1b => "Samsung",
        0x1d => "ADATA",
        0x27 => "Phison",
        0x28 => "Lexar",
        0x31 => "Silicon Power",
        0x41 => "Kingston",
        0x74 => "Transcend",
        0x76 => "Patriot",
        0x82 => "Sony",
        else => null,
    };
}

/// A device tree's 64-bit serial number (big-endian), in hexadecimal; empty
/// if it is 0.
pub fn serialFromDeviceTree(raw: []const u8) Str(24) {
    var out: Str(24) = .{};
    if (raw.len < 8) return out;
    const v = std.mem.readInt(u64, raw[0..8], .big);
    if (v != 0) out.print("{x}", .{v});
    return out;
}

pub const Cpuinfo = struct {
    cores: u32 = 0,
    /// Without leading zeros: empty if it is 0 (as Linux reports it when
    /// booted from a device tree).
    serial: Str(24) = .{},
};

pub fn parseCpuinfo(text: []const u8) Cpuinfo {
    var out: Cpuinfo = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "processor")) {
            out.cores += 1;
        } else if (std.mem.eql(u8, key, "Serial")) {
            out.serial.set(std.mem.trimStart(u8, value, "0"));
        }
    }
    return out;
}

// --- Usage ----------------------------------------------------------------------

pub const Usage = struct {
    /// CPU use since the last reading, in percent of all the cores.
    cpu_busy: ?f32 = null,
    /// The SoC's temperature in degrees Celsius.
    temperature: ?f32 = null,
    /// Bytes of memory: all of it, and what programs could still have.
    mem_total: u64 = 0,
    mem_available: u64 = 0,
    /// The contiguous memory the GPU's buffers come from (the GPU has no
    /// MMU), and how much of it is free.
    gpu_total: u64 = 0,
    gpu_free: u64 = 0,
    storage: Storage = .{},
    uptime_s: u64 = 0,

    pub fn memUsed(u: Usage) u64 {
        return u.mem_total -| u.mem_available;
    }

    pub fn gpuUsed(u: Usage) u64 {
        return u.gpu_total -| u.gpu_free;
    }
};

/// Where the storage goes. Dazzle runs from a filesystem in RAM, loaded
/// from the SD card at boot, so its files take memory and the free space is
/// the memory available.
pub const Storage = struct {
    /// Bytes of files: the system's (init and the shell, in memory), the
    /// apps' (in /data/apps) and the user's (the rest of what is used of
    /// the SD card's space for files, /data); and what is free (there, or,
    /// without it, of the memory the system runs in).
    system: u64 = 0,
    apps: u64 = 0,
    user: u64 = 0,
    free: u64 = 0,

    pub fn total(s: Storage) u64 {
        return s.system + s.apps + s.user + s.free;
    }
};

pub const Meminfo = sys.Meminfo;
pub const parseMeminfo = sys.parseMeminfo;

/// The total and idle (idle + iowait) ticks from /proc/stat's first line.
pub fn parseStat(stat: []const u8) ?[2]u64 {
    const line = stat[0 .. std.mem.indexOfScalar(u8, stat, '\n') orelse stat.len];
    if (!std.mem.startsWith(u8, line, "cpu ")) return null;
    var fields = std.mem.tokenizeScalar(u8, line[4..], ' ');
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    while (fields.next()) |f| : (i += 1) {
        // user nice system idle iowait irq softirq steal
        if (i >= 8) break;
        const v = std.fmt.parseInt(u64, f, 10) catch return null;
        total += v;
        if (i == 3 or i == 4) idle += v;
    }
    return .{ total, idle };
}

pub const UsageMonitor = struct {
    last: ?[2]u64 = null,
    /// The system's files change rarely: counted again every so often.
    storage_at: u64 = 0,
    storage: Storage = .{},

    pub fn read(m: *UsageMonitor, now_ns: u64) Usage {
        var u: Usage = .{};
        var buf: [4096]u8 = undefined;
        if (sys.readFile("/proc/stat", &buf)) |stat| if (parseStat(stat)) |now| {
            if (m.last) |last| {
                const total = now[0] -| last[0];
                if (total > 0) u.cpu_busy = 100 * @as(f32, @floatFromInt(total -| (now[1] -| last[1]))) / @as(f32, @floatFromInt(total));
            }
            m.last = now;
        };
        if (sys.readFile("/sys/class/thermal/thermal_zone0/temp", &buf)) |t| {
            if (std.fmt.parseInt(i32, std.mem.trim(u8, t, " \n"), 10)) |milli| {
                u.temperature = @as(f32, @floatFromInt(milli)) / 1000;
            } else |_| {}
        }
        if (sys.readFile("/proc/meminfo", &buf)) |text| {
            const mi = parseMeminfo(text);
            u.mem_total = mi.total;
            u.mem_available = mi.available;
            u.gpu_total = mi.cma_total;
            u.gpu_free = mi.cma_free;
        }
        if (sys.readFile("/proc/uptime", &buf)) |text| {
            const end = std.mem.indexOfAny(u8, text, ". ") orelse text.len;
            u.uptime_s = std.fmt.parseInt(u64, text[0..end], 10) catch 0;
        }
        if (m.storage_at == 0 or now_ns >= m.storage_at) {
            m.storage_at = now_ns + 10 * std.time.ns_per_s;
            var all: Tally = .{};
            all.add("/", 0);
            var apps: Tally = .{};
            apps.add(sys.system.apps_dir, 1);
            m.storage = .{ .system = all.bytes, .apps = apps.bytes };
        }
        u.storage = m.storage;
        u.storage.free = u.mem_available;
        // The card's space for files (an ext4 mount): the apps are there
        // too, so the user's are what is left of what is used.
        if (sys.diskSpace(sys.system.data_dir)) |d| if (d.kind == 0xef53) {
            u.storage.user = (d.total -| d.free) -| u.storage.apps;
            u.storage.free = d.free;
        };
        return u;
    }
};

/// The size of the files under a directory.
pub const Tally = struct {
    bytes: u64 = 0,
    files: u64 = 0,

    /// Counts the files under `path` (not following links); at the root,
    /// the kernel's own filesystems are left out.
    pub fn add(t: *Tally, path: []const u8, depth: u32) void {
        if (depth > 16) return;
        var path_buf: [512]u8 = undefined;
        const dir_path = std.mem.printSentinel(&path_buf, "{s}", .{path}, 0) catch return;
        const dir = sys.open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
        defer sys.close(dir);
        var buf: [2048]u8 align(8) = undefined;
        while (true) {
            const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch return;
            if (n == 0) return;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                const kind = buf[at + 18];
                const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
                at += reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (depth == 0 and (std.mem.eql(u8, name, "proc") or std.mem.eql(u8, name, "sys") or std.mem.eql(u8, name, "dev") or std.mem.eql(u8, name, "data") or std.mem.eql(u8, name, "boot"))) continue;
                var child_buf: [512]u8 = undefined;
                const sep: []const u8 = if (std.mem.endsWith(u8, path, "/")) "" else "/";
                const child = std.mem.printSentinel(&child_buf, "{s}{s}{s}", .{ path, sep, name }, 0) catch continue;
                const dt_dir = 4;
                const dt_reg = 8;
                if (kind == dt_dir) {
                    t.add(child, depth + 1);
                } else if (kind == dt_reg) {
                    var stx: linux.Statx = undefined;
                    if (linux.errno(linux.statx(linux.AT.FDCWD, child, linux.AT.SYMLINK_NOFOLLOW, .{ .SIZE = true }, &stx)) != .SUCCESS) continue;
                    t.bytes += stx.size;
                    t.files += 1;
                }
            }
        }
    }
};

// --- Network --------------------------------------------------------------------

pub const Interface = struct {
    name: Str(16) = .{},
    /// "up", "down", "dormant", ...
    state: Str(16) = .{},
    /// Whether a cable (with something at the other end) is plugged in.
    carrier: bool = false,
    mac: Str(24) = .{},
    ip: ?[4]u8 = null,
    prefix: u8 = 0,
    /// Link speed in Mb/s, if known.
    speed: ?u32 = null,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
};

pub const Network = struct {
    pub const max_interfaces = 4;

    interfaces: [max_interfaces]Interface = undefined,
    len: usize = 0,
    gateway: ?[4]u8 = null,

    pub fn slice(n: *const Network) []const Interface {
        return n.interfaces[0..n.len];
    }

    pub fn read() Network {
        var net: Network = .{};
        const dir = sys.open("/sys/class/net", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return net;
        defer sys.close(dir);
        var buf: [2048]u8 align(8) = undefined;
        const sock: ?linux.fd_t = if (sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0))) |fd| @intCast(fd) else |_| null;
        defer if (sock) |fd| sys.close(fd);
        while (true) {
            const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch break;
            if (n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
                at += reclen;
                if (name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "lo")) continue;
                // Wi-Fi interfaces are the Wi-Fi card's.
                var phy_buf: [32]u8 = undefined;
                if (sysfs(name, "phy80211/name", &phy_buf) != null) continue;
                if (net.len == max_interfaces) break;
                net.interfaces[net.len] = readInterface(name, sock);
                net.len += 1;
            }
        }
        std.mem.sort(Interface, net.interfaces[0..net.len], {}, struct {
            fn lessThan(_: void, a: Interface, b: Interface) bool {
                return std.mem.lessThan(u8, a.name.slice(), b.name.slice());
            }
        }.lessThan);
        var route_buf: [2048]u8 = undefined;
        if (sys.readFile("/proc/net/route", &route_buf)) |routes| net.gateway = defaultGateway(routes);
        return net;
    }
};

fn readInterface(name: []const u8, sock: ?linux.fd_t) Interface {
    var i: Interface = .{ .name = .of(name) };
    var buf: [64]u8 = undefined;
    i.state.set(std.mem.trim(u8, sysfs(name, "operstate", &buf) orelse "unknown", " \n"));
    // Reading the carrier of an interface that is down fails.
    i.carrier = std.mem.eql(u8, std.mem.trim(u8, sysfs(name, "carrier", &buf) orelse "0", " \n"), "1");
    i.mac.set(std.mem.trim(u8, sysfs(name, "address", &buf) orelse "", " \n"));
    if (sysfs(name, "speed", &buf)) |s| {
        const v = std.fmt.parseInt(i32, std.mem.trim(u8, s, " \n"), 10) catch -1;
        if (v > 0) i.speed = @intCast(v);
    }
    i.rx_bytes = number(sysfs(name, "statistics/rx_bytes", &buf));
    i.tx_bytes = number(sysfs(name, "statistics/tx_bytes", &buf));
    if (sock) |fd| {
        var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
        @memcpy(req.ifrn.name[0..@min(name.len, req.ifrn.name.len - 1)], name[0..@min(name.len, req.ifrn.name.len - 1)]);
        if (linux.errno(linux.ioctl(fd, linux.SIOCGIFADDR, @intFromPtr(&req))) == .SUCCESS and req.ifru.addr.family == linux.AF.INET) {
            const in: *const linux.sockaddr.in = @ptrCast(@alignCast(&req.ifru.addr));
            i.ip = @bitCast(in.addr);
            if (linux.errno(linux.ioctl(fd, linux.SIOCGIFNETMASK, @intFromPtr(&req))) == .SUCCESS) {
                const mask: *const linux.sockaddr.in = @ptrCast(@alignCast(&req.ifru.addr));
                i.prefix = @popCount(mask.addr);
            }
        }
    }
    return i;
}

fn sysfs(iface: []const u8, file: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [96]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/sys/class/net/{s}/{s}", .{ iface, file }, 0) catch return null;
    return sys.readFile(path, buf);
}

fn number(text: ?[]const u8) u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, text orelse "0", " \n"), 10) catch 0;
}

/// The gateway of the default route in /proc/net/route.
pub fn defaultGateway(routes: []const u8) ?[4]u8 {
    var lines = std.mem.tokenizeScalar(u8, routes, '\n');
    _ = lines.next(); // the header
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // interface
        const dest = fields.next() orelse continue;
        const gateway = fields.next() orelse continue;
        const flags = std.fmt.parseInt(u32, fields.next() orelse continue, 16) catch continue;
        const rtf_gateway = 0x2;
        if (!std.mem.eql(u8, dest, "00000000") or flags & rtf_gateway == 0) continue;
        // The address as the kernel keeps it, read as a number in the
        // host's byte order.
        const g = std.fmt.parseInt(u32, gateway, 16) catch continue;
        return @bitCast(g);
    }
    return null;
}

// --- The network manager ----------------------------------------------------------

pub const manager = sys.network;

/// Sends the network manager a request ("wifi scan\n", or one from
/// `manager.connectRequest` or `manager.ethernetRequest`, ...) and returns
/// its report. Null if the manager cannot be reached.
pub fn askManager(request: []const u8) ?manager.Report {
    return manager.ask(request);
}

// --- Formatting -----------------------------------------------------------------

/// "340 KB", "9.8 MB", "1.2 GB".
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB" };
    var v = b;
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    if (u == 0) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "";
    if (v < 10) return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch "";
}

/// "45 s", "3 min 20 s", "2 h 5 min", "1 d 4 h".
pub fn formatDuration(buf: []u8, s: u64) []const u8 {
    if (s < 60) return std.fmt.bufPrint(buf, "{d} s", .{s}) catch "";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d} min {d} s", .{ s / 60, s % 60 }) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d} h {d} min", .{ s / 3600, s / 60 % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d} d {d} h", .{ s / 86400, s / 3600 % 24 }) catch "";
}

const testing = std.testing;

test "the cores and serial number" {
    const zero = "processor\t: 0\nmodel name\t: ARMv6-compatible processor rev 7 (v6l)\nHardware\t: BCM2835\nRevision\t: 0000\nSerial\t\t: 00000000a1b2c3d4\n";
    const c = parseCpuinfo(zero);
    try testing.expectEqual(@as(u32, 1), c.cores);
    try testing.expectEqualStrings("a1b2c3d4", c.serial.slice());
    // Booted from a device tree, Linux reports 0.
    const q = parseCpuinfo("processor : 0\nprocessor : 1\nprocessor : 2\nprocessor : 3\nSerial : 0000000000000000\n");
    try testing.expectEqual(@as(u32, 4), q.cores);
    try testing.expectEqual(@as(usize, 0), q.serial.len);
    try testing.expectEqualStrings("a1b2c3d4", serialFromDeviceTree(&.{ 0, 0, 0, 0, 0xa1, 0xb2, 0xc3, 0xd4 }).slice());
    try testing.expectEqual(@as(usize, 0), serialFromDeviceTree(&@as([8]u8, @splat(0))).len);
}

test "memory, CPU time, routes and the command line" {
    const mi = parseMeminfo("MemTotal:         444532 kB\nMemFree:          300000 kB\nMemAvailable:     400000 kB\nCmaTotal:          65536 kB\nCmaFree:           40000 kB\n");
    try testing.expectEqual(@as(u64, 444532 * 1024), mi.total);
    try testing.expectEqual(@as(u64, 400000 * 1024), mi.available);
    try testing.expectEqual(@as(u64, 65536 * 1024), mi.cma_total);
    try testing.expectEqual(@as(u64, 40000 * 1024), mi.cma_free);

    try testing.expectEqual([2]u64{ 980, 820 }, parseStat("cpu  100 5 50 800 20 3 2 0 0 0\ncpu0 1\n").?);

    const routes = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\neth0\t0001A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\neth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n";
    // The kernel writes the address as a number in the host's byte order:
    // on little-endian machines, the first byte last.
    const g = defaultGateway(routes).?;
    if (@import("builtin").cpu.arch.endian() == .little) try testing.expectEqual([4]u8{ 192, 168, 1, 1 }, g);
    try testing.expect(defaultGateway("Iface\tDestination\n") == null);
}

test "sizes and durations read naturally" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("512 bytes", formatBytes(&buf, 512));
    try testing.expectEqualStrings("340 KB", formatBytes(&buf, 340 * 1024));
    try testing.expectEqualStrings("9.8 MB", formatBytes(&buf, 10276045));
    try testing.expectEqualStrings("1.5 GB", formatBytes(&buf, 1536 * 1024 * 1024));
    try testing.expectEqualStrings("45 s", formatDuration(&buf, 45));
    try testing.expectEqualStrings("3 min 20 s", formatDuration(&buf, 200));
    try testing.expectEqualStrings("2 h 5 min", formatDuration(&buf, 7500));
    try testing.expectEqualStrings("1 d 4 h", formatDuration(&buf, 100800));
}

test "files are counted, without the kernel's filesystems" {
    var root_buf: [64]u8 = undefined;
    const root = try std.mem.printSentinel(&root_buf, "/tmp/dazzle-tally-{d}", .{linux.getpid()}, 0);
    var b: [128]u8 = undefined;
    _ = linux.mkdir(root, 0o755);
    _ = linux.mkdir(try std.mem.printSentinel(&b, "{s}/sub", .{root}, 0), 0o755);
    defer {
        for ([_][]const u8{ "/sub/b", "/a", "/sub", "" }) |p| {
            const path = std.mem.printSentinel(&b, "{s}{s}", .{ root, p }, 0) catch unreachable;
            if (linux.errno(linux.unlink(path)) != .SUCCESS) _ = linux.rmdir(path);
        }
    }
    for ([_][]const u8{ "/a", "/sub/b" }, [_]usize{ 100, 23 }) |p, size| {
        const fd = try sys.open(try std.mem.printSentinel(&b, "{s}{s}", .{ root, p }, 0), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        var data: [100]u8 = @splat('x');
        _ = linux.write(fd, &data, size);
        sys.close(fd);
    }
    var t: Tally = .{};
    t.add(root, 1);
    try testing.expectEqual(@as(u64, 123), t.bytes);
    try testing.expectEqual(@as(u64, 2), t.files);
}

test "reading this machine" {
    const h = System.read();
    try testing.expect(h.kernel.len > 0);
    var m: UsageMonitor = .{};
    _ = m.read(1);
    const u = m.read(2);
    try testing.expect(u.mem_total > 0 and u.mem_available <= u.mem_total);
    try testing.expect(u.storage.system > 0 and u.storage.free > 0);
    const net = Network.read();
    for (net.slice()) |*i| try testing.expect(i.name.len > 0 and !std.mem.eql(u8, i.name.slice(), "lo"));
}
