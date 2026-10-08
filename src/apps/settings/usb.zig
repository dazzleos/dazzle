//! The USB devices plugged in, as Linux lists them in
//! /sys/bus/usb/devices: each device's name (as it gives it, or its
//! maker's and product's numbers), what kind of thing it is (from its
//! interfaces' classes), how fast it talks, and whether it is part of the
//! board (the hub and network adapter on most Pis) or plugged in. Hubs'
//! own controllers (usb1, ...) and the devices' interfaces (1-1:1.0) are
//! left out.

const std = @import("std");
const sys = @import("sys");
const linux = std.os.linux;

pub const sysfs_dir = "/sys/bus/usb/devices";

pub const Kind = enum {
    keyboard,
    mouse,
    /// Other input: a game controller, a touchscreen.
    input,
    storage,
    hub,
    network,
    wireless,
    audio,
    camera,
    printer,
    other,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .keyboard => "Keyboard",
            .mouse => "Mouse",
            .input => "Input device",
            .storage => "Storage",
            .hub => "Hub",
            .network => "Network adapter",
            .wireless => "Wireless adapter",
            .audio => "Sound",
            .camera => "Camera",
            .printer => "Printer",
            .other => "Device",
        };
    }
};

fn Str(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn set(s: *@This(), text: []const u8) void {
            s.len = @min(text.len, n);
            @memcpy(s.buf[0..s.len], text[0..s.len]);
        }

        pub fn slice(s: *const @This()) []const u8 {
            return s.buf[0..s.len];
        }
    };
}

pub const Device = struct {
    /// Its place on the bus: "1-1.2".
    port: Str(16) = .{},
    product: Str(64) = .{},
    manufacturer: Str(64) = .{},
    vendor_id: u16 = 0,
    product_id: u16 = 0,
    kind: Kind = .other,
    /// Megabits a second: 1.5, 12, 480 or 5000.
    speed_mbps: f32 = 0,
    /// Part of the board, rather than plugged in.
    built_in: bool = false,

    /// What to call it: its product's name, or its numbers.
    pub fn name(d: *const Device, buf: []u8) []const u8 {
        if (d.product.len > 0) return d.product.slice();
        return std.fmt.bufPrint(buf, "USB device {x:0>4}:{x:0>4}", .{ d.vendor_id, d.product_id }) catch "USB device";
    }
};

pub const max_devices = 16;

pub const Devices = struct {
    items: [max_devices]Device = undefined,
    len: usize = 0,

    pub fn slice(d: *const Devices) []const Device {
        return d.items[0..d.len];
    }

    pub fn read() Devices {
        return readFrom(sysfs_dir);
    }

    /// The devices listed in `dir` (a sysfs tree), in port order: those
    /// plugged in first, then the board's.
    pub fn readFrom(dir: [:0]const u8) Devices {
        var out: Devices = .{};
        const fd = sys.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return out;
        defer sys.close(fd);
        var dents: [4096]u8 align(8) = undefined;
        while (true) {
            const n = sys.check(linux.getdents64(fd, &dents, dents.len)) catch break;
            if (n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
                const entry = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
                at += reclen;
                // Devices are "<bus>-<port>[.<port>...]"; not the root hubs
                // (usbN), nor interfaces (with a colon).
                if (entry.len == 0 or !std.ascii.isDigit(entry[0]) or std.mem.indexOfScalar(u8, entry, ':') != null) continue;
                if (out.len == max_devices) break;
                if (readDevice(dir, entry)) |d| {
                    out.items[out.len] = d;
                    out.len += 1;
                }
            }
        }
        std.mem.sort(Device, out.items[0..out.len], {}, before);
        return out;
    }
};

fn before(_: void, a: Device, b: Device) bool {
    if (a.built_in != b.built_in) return !a.built_in;
    return std.mem.order(u8, a.port.slice(), b.port.slice()) == .lt;
}

fn readDevice(dir: []const u8, port: []const u8) ?Device {
    var d: Device = .{};
    d.port.set(port);
    var buf: [128]u8 = undefined;
    d.vendor_id = std.fmt.parseInt(u16, attr(&buf, dir, port, "idVendor") orelse return null, 16) catch return null;
    d.product_id = std.fmt.parseInt(u16, attr(&buf, dir, port, "idProduct") orelse "0", 16) catch 0;
    if (attr(&buf, dir, port, "product")) |p| d.product.set(p);
    if (attr(&buf, dir, port, "manufacturer")) |m| d.manufacturer.set(m);
    if (attr(&buf, dir, port, "speed")) |s| d.speed_mbps = std.fmt.parseFloat(f32, s) catch 0;
    if (attr(&buf, dir, port, "removable")) |r| d.built_in = std.mem.eql(u8, r, "fixed");
    const class = std.fmt.parseInt(u8, attr(&buf, dir, port, "bDeviceClass") orelse "00", 16) catch 0;
    d.kind = kindOf(class, 0, 0);
    // A device that says only that its interfaces say: the first that
    // says something.
    if (d.kind == .other) d.kind = interfacesKind(dir, port);
    return d;
}

/// What kind of device an (interface) class, subclass and protocol is.
pub fn kindOf(class: u8, subclass: u8, protocol: u8) Kind {
    return switch (class) {
        0x01 => .audio,
        0x02, 0x0a => .network,
        0x03 => if (subclass == 1 and protocol == 1) .keyboard else if (subclass == 1 and protocol == 2) .mouse else .input,
        0x07 => .printer,
        0x08 => .storage,
        0x09 => .hub,
        0x0e => .camera,
        0xe0 => .wireless,
        else => .other,
    };
}

/// The kind its interfaces ("<port>:<config>.<n>") say; a keyboard's
/// other interfaces (its media keys, say) do not make it something else.
fn interfacesKind(dir: []const u8, port: []const u8) Kind {
    var best: Kind = .other;
    var buf: [128]u8 = undefined;
    for (0..8) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}:1.{d}", .{ port, i }) catch break;
        const class = std.fmt.parseInt(u8, attr(&buf, dir, name, "bInterfaceClass") orelse break, 16) catch continue;
        const sub = std.fmt.parseInt(u8, attr(&buf, dir, name, "bInterfaceSubClass") orelse "00", 16) catch 0;
        const proto = std.fmt.parseInt(u8, attr(&buf, dir, name, "bInterfaceProtocol") orelse "00", 16) catch 0;
        var k = kindOf(class, sub, proto);
        // A vendor's own class: the driver Linux gave it says what it is
        // (the network adapters on the boards, say).
        if (class == 0xff) k = driverKind(dir, name);
        if (best == .other or (best == .input and (k == .keyboard or k == .mouse))) best = k;
    }
    return best;
}

fn driverKind(dir: []const u8, interface: []const u8) Kind {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/driver", .{ dir, interface }) catch return .other;
    var target: [256]u8 = undefined;
    const n = sys.check(linux.readlink(path, &target, target.len)) catch return .other;
    const driver = std.fs.path.basename(target[0..n]);
    const network = [_][]const u8{ "smsc95xx", "lan78xx", "r8152", "asix", "ax88179_178a", "cdc_ether", "cdc_ncm" };
    for (network) |d| if (std.mem.eql(u8, d, driver)) return .network;
    if (std.mem.startsWith(u8, driver, "brcmfmac") or std.mem.startsWith(u8, driver, "rt") or std.mem.startsWith(u8, driver, "mt7")) return .wireless;
    return .other;
}

/// A device's (or interface's) attribute, trimmed.
fn attr(buf: []u8, dir: []const u8, entry: []const u8, name: []const u8) ?[]const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/{s}", .{ dir, entry, name }) catch return null;
    const text = sys.readFile(path, buf) orelse return null;
    return std.mem.trim(u8, text, " \n\x00");
}

/// "480 Mb/s", "1.5 Mb/s", "5 Gb/s".
pub fn formatSpeed(buf: []u8, mbps: f32) []const u8 {
    if (mbps <= 0) return "";
    if (mbps >= 1000) return std.fmt.bufPrint(buf, "{d} Gb/s", .{mbps / 1000}) catch "";
    return std.fmt.bufPrint(buf, "{d} Mb/s", .{mbps}) catch "";
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

const FakeSysfs = struct {
    path_buf: [64]u8 = undefined,
    path: [:0]const u8 = "",

    fn init(f: *FakeSysfs) !void {
        f.path = try std.fmt.bufPrintZ(&f.path_buf, "/tmp/dazzle-usb-test-{d}", .{linux.getpid()});
        _ = linux.mkdir(f.path, 0o755);
    }

    fn deinit(f: *FakeSysfs) void {
        sys.files.removeTree(f.path);
    }

    fn add(f: *FakeSysfs, entry: []const u8, attrs: []const [2][]const u8) !void {
        var buf: [256]u8 = undefined;
        _ = linux.mkdir(try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ f.path, entry }), 0o755);
        for (attrs) |a| try sys.files.writeNew(try std.fmt.bufPrintZ(&buf, "{s}/{s}/{s}", .{ f.path, entry, a[0] }), a[1]);
    }
};

test "devices, their kinds and speeds, the board's last" {
    var f: FakeSysfs = .{};
    try f.init();
    defer f.deinit();
    // The root hub and an interface: left out.
    try f.add("usb1", &.{.{ "idVendor", "1d6b\n" }});
    // The board's hub.
    try f.add("1-1", &.{ .{ "idVendor", "0424\n" }, .{ "idProduct", "9514\n" }, .{ "bDeviceClass", "09\n" }, .{ "speed", "480\n" }, .{ "removable", "fixed\n" } });
    // A keyboard (its first interface says so; its second is media keys).
    try f.add("1-1.2", &.{ .{ "idVendor", "046d\n" }, .{ "idProduct", "c31c\n" }, .{ "product", "USB Keyboard\n" }, .{ "manufacturer", "Logitech\n" }, .{ "bDeviceClass", "00\n" }, .{ "speed", "1.5\n" }, .{ "removable", "removable\n" } });
    try f.add("1-1.2:1.0", &.{ .{ "bInterfaceClass", "03\n" }, .{ "bInterfaceSubClass", "01\n" }, .{ "bInterfaceProtocol", "01\n" } });
    try f.add("1-1.2:1.1", &.{ .{ "bInterfaceClass", "03\n" }, .{ "bInterfaceSubClass", "00\n" }, .{ "bInterfaceProtocol", "00\n" } });
    // A stick with no name.
    try f.add("1-1.3", &.{ .{ "idVendor", "0781\n" }, .{ "idProduct", "5567\n" }, .{ "bDeviceClass", "00\n" }, .{ "speed", "480\n" } });
    try f.add("1-1.3:1.0", &.{.{ "bInterfaceClass", "08\n" }});

    const d = Devices.readFrom(f.path);
    try testing.expectEqual(@as(usize, 3), d.len);
    const all = d.slice();
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("USB Keyboard", all[0].name(&buf));
    try testing.expectEqual(Kind.keyboard, all[0].kind);
    try testing.expectEqualStrings("Logitech", all[0].manufacturer.slice());
    try testing.expectEqualStrings("1.5 Mb/s", formatSpeed(&buf, all[0].speed_mbps));
    try testing.expectEqualStrings("USB device 0781:5567", all[1].name(&buf));
    try testing.expectEqual(Kind.storage, all[1].kind);
    try testing.expectEqual(Kind.hub, all[2].kind);
    try testing.expect(all[2].built_in);
    try testing.expectEqualStrings("480 Mb/s", formatSpeed(&buf, all[2].speed_mbps));
    try testing.expectEqualStrings("5 Gb/s", formatSpeed(&buf, 5000));
    // Nothing there: none.
    try testing.expectEqual(@as(usize, 0), Devices.readFrom("/nonexistent").len);
}
