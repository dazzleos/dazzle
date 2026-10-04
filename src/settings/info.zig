//! What the settings app shows about the machine, read from the kernel
//! (/proc, /sys, the device tree), the GPU and the network interfaces. All
//! of it is readable by the unprivileged Stardust user.
//!
//! `Hardware` does not change while the system runs and is read once;
//! `Usage` and `Network` are read again every second.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");

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

// --- Hardware -------------------------------------------------------------------

pub const Gpu = struct {
    /// The V3D's technology version and revision (2.1 on the VideoCore IV).
    version: u8,
    revision: u8,
    slices: u8,
    qpus_per_slice: u8,
    tmus_per_slice: u8,
    /// Vertex pipeline memory, in KB.
    vpm_kb: u32,

    pub fn qpus(g: Gpu) u32 {
        return @as(u32, g.slices) * g.qpus_per_slice;
    }
};

/// The V3D's identification registers, as the vc4 driver reports them.
pub fn decodeGpu(ident0: u64, ident1: u64) ?Gpu {
    // IDENT0: "V3D" in the low three bytes, the technology version above.
    if (ident0 & 0xffffff != 0x443356) return null;
    const vpm: u32 = @truncate(ident1 >> 28 & 0xf);
    return .{
        .version = @truncate(ident0 >> 24),
        .revision = @truncate(ident1 & 0xf),
        .slices = @truncate(ident1 >> 4 & 0xf),
        .qpus_per_slice = @truncate(ident1 >> 8 & 0xf),
        .tmus_per_slice = @truncate(ident1 >> 12 & 0xf),
        // In KB; 0 means 16.
        .vpm_kb = if (vpm == 0) 16 else vpm,
    };
}

pub const Hardware = struct {
    /// The board, from the device tree: "Raspberry Pi Zero W Rev 1.1".
    model: Str(64) = .{},
    /// The system on a chip: "BCM2835".
    soc: Str(16) = .{},
    /// The CPU's core: "ARM1176JZF-S".
    cpu: Str(48) = .{},
    cores: u32 = 0,
    /// The board's revision code and serial number (from /proc/cpuinfo).
    revision: Str(16) = .{},
    serial: Str(24) = .{},
    gpu: ?Gpu = null,
    /// Linux's version ("6.12.0 (armv6l)") and the machine's name on the
    /// network.
    kernel: Str(64) = .{},
    hostname: Str(64) = .{},
    /// A static address from the kernel command line (otherwise DHCP).
    static_ip: Str(48) = .{},

    pub fn read(dev: ?vc4.Device) Hardware {
        var h: Hardware = .{};
        var buf: [4096]u8 = undefined;
        if (sys.readFile("/sys/firmware/devicetree/base/model", &buf)) |m| h.model.set(std.mem.trimEnd(u8, m, "\x00\n"));
        if (sys.readFile("/sys/firmware/devicetree/base/compatible", &buf)) |c| h.soc = socName(c);
        if (sys.readFile("/proc/cpuinfo", &buf)) |info| {
            const c = parseCpuinfo(info);
            h.cpu = c.cpu;
            h.cores = c.cores;
            h.revision = c.revision;
            h.serial = c.serial;
            if (h.soc.len == 0) h.soc = c.hardware;
        }
        if (dev) |d| {
            const id0 = d.getParam(.v3d_ident0) catch 0;
            const id1 = d.getParam(.v3d_ident1) catch 0;
            h.gpu = decodeGpu(id0, id1);
        }
        var uts: linux.utsname = undefined;
        if (linux.errno(linux.uname(&uts)) == .SUCCESS) {
            h.kernel.print("{s} ({s})", .{ std.mem.sliceTo(&uts.release, 0), std.mem.sliceTo(&uts.machine, 0) });
            h.hostname.set(std.mem.sliceTo(&uts.nodename, 0));
        }
        if (sys.readFile("/proc/cmdline", &buf)) |cmdline| if (staticIp(cmdline)) |ip| h.static_ip.set(ip);
        return h;
    }
};

/// The SoC from the device tree's compatible list ("brcm,bcm2837" is the
/// last entry naming the chip).
pub fn socName(compatible: []const u8) Str(16) {
    var out: Str(16) = .{};
    var it = std.mem.tokenizeScalar(u8, compatible, 0);
    while (it.next()) |entry| if (std.mem.startsWith(u8, entry, "brcm,")) {
        out.set(entry["brcm,".len..]);
        for (out.buf[0..out.len]) |*ch| ch.* = std.ascii.toUpper(ch.*);
    };
    return out;
}

pub const Cpuinfo = struct {
    cpu: Str(48) = .{},
    cores: u32 = 0,
    hardware: Str(16) = .{},
    revision: Str(16) = .{},
    serial: Str(24) = .{},
};

pub fn parseCpuinfo(text: []const u8) Cpuinfo {
    var out: Cpuinfo = .{};
    var model: []const u8 = "";
    var part: ?u32 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "processor")) {
            out.cores += 1;
        } else if (std.mem.eql(u8, key, "model name") and model.len == 0) {
            model = value;
        } else if (std.mem.eql(u8, key, "CPU part") and part == null) {
            part = std.fmt.parseInt(u32, value, 0) catch null;
        } else if (std.mem.eql(u8, key, "Hardware")) {
            out.hardware.set(value);
        } else if (std.mem.eql(u8, key, "Revision")) {
            out.revision.set(value);
        } else if (std.mem.eql(u8, key, "Serial")) {
            out.serial.set(std.mem.trimStart(u8, value, "0"));
        }
    }
    const name: ?[]const u8 = if (part) |p| switch (p) {
        0xb76 => "ARM1176JZF-S",
        0xc07 => "Cortex-A7",
        0xd03 => "Cortex-A53",
        0xd08 => "Cortex-A72",
        else => null,
    } else null;
    out.cpu.set(name orelse model);
    return out;
}

/// The address in `stardust.ip=` on the kernel command line.
pub fn staticIp(cmdline: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (it.next()) |arg| if (std.mem.startsWith(u8, arg, "stardust.ip=")) return arg["stardust.ip=".len..];
    return null;
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
    /// The system's files: Stardust runs from a filesystem in RAM, loaded
    /// from the SD card at boot.
    storage_bytes: u64 = 0,
    storage_files: u32 = 0,
    uptime_s: u64 = 0,

    pub fn memUsed(u: Usage) u64 {
        return u.mem_total -| u.mem_available;
    }

    pub fn gpuUsed(u: Usage) u64 {
        return u.gpu_total -| u.gpu_free;
    }
};

pub const Meminfo = struct { total: u64 = 0, available: u64 = 0, cma_total: u64 = 0, cma_free: u64 = 0 };

/// /proc/meminfo's figures, in bytes.
pub fn parseMeminfo(text: []const u8) Meminfo {
    var out: Meminfo = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        const kb = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        const key = line[0..colon];
        const field: ?*u64 = if (std.mem.eql(u8, key, "MemTotal")) &out.total else if (std.mem.eql(u8, key, "MemAvailable")) &out.available else if (std.mem.eql(u8, key, "CmaTotal")) &out.cma_total else if (std.mem.eql(u8, key, "CmaFree")) &out.cma_free else null;
        if (field) |f| f.* = kb * 1024;
    }
    return out;
}

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
    storage: [2]u64 = .{ 0, 0 },

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
            var t: Tally = .{};
            t.add("/", 0);
            m.storage = .{ t.bytes, t.files };
        }
        u.storage_bytes = m.storage[0];
        u.storage_files = @intCast(m.storage[1]);
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
        const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
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
                if (depth == 0 and (std.mem.eql(u8, name, "proc") or std.mem.eql(u8, name, "sys") or std.mem.eql(u8, name, "dev"))) continue;
                var child_buf: [512]u8 = undefined;
                const sep: []const u8 = if (std.mem.endsWith(u8, path, "/")) "" else "/";
                const child = std.fmt.bufPrintZ(&child_buf, "{s}{s}{s}", .{ path, sep, name }) catch continue;
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
    const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/net/{s}/{s}", .{ iface, file }) catch return null;
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

test "the GPU's identification" {
    // A VideoCore IV: V3D 2.1, 3 slices of 4 QPUs and 2 TMUs, 12 KB VPM.
    const g = decodeGpu(0x02443356, 0xc0102431).?;
    try testing.expectEqual(@as(u8, 2), g.version);
    try testing.expectEqual(@as(u8, 1), g.revision);
    try testing.expectEqual(@as(u8, 3), g.slices);
    try testing.expectEqual(@as(u8, 4), g.qpus_per_slice);
    try testing.expectEqual(@as(u8, 2), g.tmus_per_slice);
    try testing.expectEqual(@as(u32, 12), g.qpus());
    try testing.expectEqual(@as(u32, 12), g.vpm_kb);
    try testing.expect(decodeGpu(0, 0) == null);
}

test "the CPU and board from /proc/cpuinfo, and the SoC from the device tree" {
    const zero = "processor\t: 0\nmodel name\t: ARMv6-compatible processor rev 7 (v6l)\nBogoMIPS\t: 697.95\nCPU part\t: 0xb76\n\nHardware\t: BCM2835\nRevision\t: 9000c1\nSerial\t\t: 00000000a1b2c3d4\n";
    const c = parseCpuinfo(zero);
    try testing.expectEqualStrings("ARM1176JZF-S", c.cpu.slice());
    try testing.expectEqual(@as(u32, 1), c.cores);
    try testing.expectEqualStrings("9000c1", c.revision.slice());
    try testing.expectEqualStrings("a1b2c3d4", c.serial.slice());
    try testing.expectEqualStrings("BCM2835", c.hardware.slice());

    const quad = "processor : 0\nCPU part : 0xd03\nprocessor : 1\nprocessor : 2\nprocessor : 3\n";
    const q = parseCpuinfo(quad);
    try testing.expectEqualStrings("Cortex-A53", q.cpu.slice());
    try testing.expectEqual(@as(u32, 4), q.cores);
    // An unknown part: the model name.
    try testing.expectEqualStrings("Some CPU", parseCpuinfo("processor : 0\nmodel name : Some CPU\nCPU part : 0x123\n").cpu.slice());

    try testing.expectEqualStrings("BCM2837", socName("raspberrypi,3-model-a-plus\x00brcm,bcm2837\x00").slice());
    try testing.expectEqualStrings("BCM2835", socName("raspberrypi,model-zero-w\x00brcm,bcm2835\x00").slice());
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

    try testing.expectEqualStrings("192.168.1.50/24,192.168.1.1", staticIp("console=tty1 stardust.ip=192.168.1.50/24,192.168.1.1 quiet\n").?);
    try testing.expect(staticIp("console=tty1\n") == null);
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
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/stardust-tally-{d}", .{linux.getpid()});
    var b: [128]u8 = undefined;
    _ = linux.mkdir(root, 0o755);
    _ = linux.mkdir(try std.fmt.bufPrintZ(&b, "{s}/sub", .{root}), 0o755);
    defer {
        for ([_][]const u8{ "/sub/b", "/a", "/sub", "" }) |p| {
            const path = std.fmt.bufPrintZ(&b, "{s}{s}", .{ root, p }) catch unreachable;
            if (linux.errno(linux.unlink(path)) != .SUCCESS) _ = linux.rmdir(path);
        }
    }
    for ([_][]const u8{ "/a", "/sub/b" }, [_]usize{ 100, 23 }) |p, size| {
        const fd = try sys.open(try std.fmt.bufPrintZ(&b, "{s}{s}", .{ root, p }), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
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
    const h = Hardware.read(null);
    try testing.expect(h.kernel.len > 0);
    var m: UsageMonitor = .{};
    _ = m.read(1);
    const u = m.read(2);
    try testing.expect(u.mem_total > 0 and u.mem_available <= u.mem_total);
    try testing.expect(u.storage_files > 0);
    const net = Network.read();
    for (net.slice()) |*i| try testing.expect(i.name.len > 0 and !std.mem.eql(u8, i.name.slice(), "lo"));
}
