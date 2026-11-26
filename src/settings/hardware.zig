//! What is connected to the board's connectors, for the Board page: the
//! monitors on HDMI, the display and camera on their ribbon cables, more
//! about the SD card, and whether Bluetooth is on. (The network's and the
//! sound's come from their own reports; see board_view.zig.)

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const info = @import("info.zig");

const Str = info.Str;

/// A monitor on an HDMI port, as its EDID says.
pub const Monitor = struct {
    connected: bool = false,
    /// Its maker (from the EDID's three-letter code) and model name.
    maker: Str(24) = .{},
    model: Str(16) = .{},
    /// Its picture's size, in millimetres (0: not said).
    size_mm: [2]u16 = .{ 0, 0 },
    /// The year it was made (0: not said).
    year: u16 = 0,
    /// The resolution it likes best, and how often it is drawn then.
    width: u16 = 0,
    height: u16 = 0,
    refresh_hz: u16 = 0,
    /// Whether it has speakers (it takes sound over HDMI).
    speakers: bool = false,

    /// Its diagonal, in inches (0: not known).
    pub fn inches(m: *const Monitor) u16 {
        const w: f32 = @floatFromInt(m.size_mm[0]);
        const h: f32 = @floatFromInt(m.size_mm[1]);
        return @intFromFloat(@round(@sqrt(w * w + h * h) / 25.4));
    }
};

/// A display on the display connector (DSI): the Touch Display 2, say.
pub const Panel = struct {
    connected: bool = false,
    name: Str(32) = .{},
    width: u16 = 0,
    height: u16 = 0,
    /// Whether it is a touchscreen.
    touch: bool = false,
};

/// A camera module on the camera connector.
pub const Camera = struct {
    connected: bool = false,
    /// Its sensor, as the kernel names its driver ("imx219").
    sensor: Str(16) = .{},

    /// The camera module with that sensor, and how many megapixels it
    /// takes (null: not one of Raspberry Pi's).
    pub fn module(c: *const Camera) ?struct { name: []const u8, maker: []const u8, megapixels: f32 } {
        const s = c.sensor.slice();
        const known = [_]struct { []const u8, []const u8, []const u8, f32 }{
            .{ "ov5647", "Camera Module 1", "OmniVision OV5647", 5 },
            .{ "imx219", "Camera Module 2", "Sony IMX219", 8 },
            .{ "imx708", "Camera Module 3", "Sony IMX708", 12 },
            .{ "imx477", "HQ Camera", "Sony IMX477", 12.3 },
            .{ "imx296", "Global Shutter Camera", "Sony IMX296", 1.6 },
            .{ "imx500", "AI Camera", "Sony IMX500", 12.3 },
        };
        for (known) |k| if (std.mem.eql(u8, s, k[0])) return .{ .name = k[1], .maker = k[2], .megapixels = k[3] };
        return null;
    }
};

/// More about the SD card than its size and maker (info.Card): its name,
/// and when it was made.
pub const CardDetails = struct {
    name: Str(16) = .{},
    month: u8 = 0,
    year: u16 = 0,
};

/// How a sound output is being used.
pub const SoundUse = enum {
    /// There is no such output (a monitor without speakers, say).
    none,
    /// It could be chosen, in the Sound page.
    available,
    /// Sound goes to it, but nothing is playing.
    chosen,
    playing,
};

pub const Hardware = struct {
    hdmi: [2]Monitor = .{ .{}, .{} },
    hdmi_sound: [2]SoundUse = .{ .none, .none },
    panel: Panel = .{},
    camera: Camera = .{},
    card: CardDetails = .{},
    /// Null: there is no Bluetooth.
    bluetooth: ?bool = null,
};

/// Reads it all: from sysfs (the displays, their EDIDs, the camera's
/// sensor, the card, Bluetooth) and ALSA's /proc files (whether sound goes
/// to each monitor, `output` being the card chosen in Sound).
pub fn read(output: []const u8) Hardware {
    var h: Hardware = .{};
    var names: Names = .{};
    names.list("/sys/class/drm");
    for (names.slice()) |name| {
        // card1-HDMI-A-1, card1-DSI-1.
        const conn = name[(std.mem.indexOfScalar(u8, name, '-') orelse continue) + 1 ..];
        var path_buf: [96]u8 = undefined;
        var buf: [64]u8 = undefined;
        const status = sys.readFile(std.fmt.bufPrintSentinel(&path_buf, "/sys/class/drm/{s}/status", .{name}, 0) catch continue, &buf) orelse continue;
        const connected = std.mem.startsWith(u8, status, "connected");
        if (std.mem.startsWith(u8, conn, "HDMI-A-")) {
            const n = std.fmt.parseInt(u8, conn["HDMI-A-".len..], 10) catch continue;
            if (n < 1 or n > 2) continue;
            const m = &h.hdmi[n - 1];
            m.connected = connected;
            if (!connected) continue;
            var edid: [512]u8 = undefined;
            if (sys.readFile(std.fmt.bufPrintSentinel(&path_buf, "/sys/class/drm/{s}/edid", .{name}, 0) catch continue, &edid)) |e| m.* = parseEdid(e) orelse m.*;
        } else if (std.mem.startsWith(u8, conn, "DSI-")) {
            h.panel.connected = connected;
            if (!connected) continue;
            // Its mode, the first listed ("720x1280").
            if (sys.readFile(std.fmt.bufPrintSentinel(&path_buf, "/sys/class/drm/{s}/modes", .{name}, 0) catch continue, &buf)) |modes| {
                var it = std.mem.tokenizeAny(u8, modes, "x\n");
                h.panel.width = std.fmt.parseInt(u16, it.next() orelse "", 10) catch 0;
                h.panel.height = std.fmt.parseInt(u16, it.next() orelse "", 10) catch 0;
            }
            h.panel.name = .of(panelName(h.panel.width, h.panel.height));
            h.panel.touch = hasTouchscreen();
        }
    }
    // Sound to each monitor: ALSA's vc4hdmi cards (vc4hdmi, or vc4hdmi0
    // and vc4hdmi1 with two ports).
    var cards_buf: [1024]u8 = undefined;
    if (sys.readFile("/proc/asound/cards", &cards_buf)) |cards| {
        var lines = std.mem.splitScalar(u8, cards, '\n');
        while (lines.next()) |line| {
            const open = std.mem.indexOfScalar(u8, line, '[') orelse continue;
            const close = std.mem.indexOfScalarPos(u8, line, open, ']') orelse continue;
            const index = std.fmt.parseInt(u8, std.mem.trim(u8, line[0..open], " "), 10) catch continue;
            const id = std.mem.trim(u8, line[open + 1 .. close], " ");
            if (!std.mem.startsWith(u8, id, "vc4hdmi")) continue;
            const port: usize = if (std.mem.eql(u8, id, "vc4hdmi1")) 1 else 0;
            h.hdmi_sound[port] = if (playing(index)) .playing else if (std.mem.eql(u8, id, output)) .chosen else .available;
        }
    }
    h.camera = readCamera();
    var path_buf: [64]u8 = undefined;
    _ = &path_buf;
    var buf: [32]u8 = undefined;
    if (sys.readFile("/sys/block/mmcblk0/device/name", &buf)) |n| h.card.name = .of(std.mem.trim(u8, n, " \n"));
    if (sys.readFile("/sys/block/mmcblk0/device/date", &buf)) |d| {
        // "03/2021".
        var it = std.mem.tokenizeAny(u8, d, "/\n");
        h.card.month = std.fmt.parseInt(u8, it.next() orelse "", 10) catch 0;
        h.card.year = std.fmt.parseInt(u16, it.next() orelse "", 10) catch 0;
    }
    var bt: Names = .{};
    bt.list("/sys/class/bluetooth");
    h.bluetooth = bt.len > 0;
    return h;
}

/// The names in a directory (up to 32), but . and ..
const Names = struct {
    buf: [32][48]u8 = undefined,
    lens: [32]u8 = undefined,
    len: usize = 0,
    out: [32][]const u8 = undefined,

    fn list(n: *Names, dir_path: [*:0]const u8) void {
        const dir = sys.open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
        defer sys.close(dir);
        var dents: [2048]u8 align(8) = undefined;
        while (true) {
            const got = sys.check(linux.getdents64(dir, &dents, dents.len)) catch break;
            if (got == 0) break;
            var at: usize = 0;
            while (at < got) {
                const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
                const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
                at += reclen;
                if (name.len == 0 or name[0] == '.' or name.len > 48 or n.len == n.buf.len) continue;
                @memcpy(n.buf[n.len][0..name.len], name);
                n.lens[n.len] = @intCast(name.len);
                n.len += 1;
            }
        }
    }

    fn slice(n: *Names) []const []const u8 {
        for (0..n.len) |i| n.out[i] = n.buf[i][0..n.lens[i]];
        return n.out[0..n.len];
    }
};

/// Whether ALSA card `index` is playing (its first playback stream
/// running).
fn playing(index: u8) bool {
    var path_buf: [64]u8 = undefined;
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/asound/card{d}/pcm0p/sub0/status", .{index}, 0) catch return false;
    const status = sys.readFile(path, &buf) orelse return false;
    return std.mem.indexOf(u8, status, "RUNNING") != null;
}

/// Whether there is a touchscreen (an input device that is the display:
/// INPUT_PROP_DIRECT).
fn hasTouchscreen() bool {
    var names: Names = .{};
    names.list("/sys/class/input");
    for (names.slice()) |name| {
        if (!std.mem.startsWith(u8, name, "input")) continue;
        var path_buf: [80]u8 = undefined;
        var buf: [32]u8 = undefined;
        const props = sys.readFile(std.fmt.bufPrintSentinel(&path_buf, "/sys/class/input/{s}/properties", .{name}, 0) catch continue, &buf) orelse continue;
        const bits = std.fmt.parseInt(u32, std.mem.trim(u8, props, " \n"), 16) catch continue;
        // INPUT_PROP_DIRECT is bit 1.
        if (bits & 2 != 0) return true;
    }
    return false;
}

/// The display Raspberry Pi makes at that size.
fn panelName(width: u16, height: u16) []const u8 {
    if (width == 720 and height == 1280) return "Touch Display 2";
    if (width == 800 and height == 480) return "Touch Display";
    return "";
}

/// The camera's sensor: the V4L2 sub-device that is not Unicam's (named
/// as its driver names it, "imx219 10-0010").
fn readCamera() Camera {
    var names: Names = .{};
    names.list("/sys/class/video4linux");
    for (names.slice()) |name| {
        if (!std.mem.startsWith(u8, name, "v4l-subdev")) continue;
        var path_buf: [80]u8 = undefined;
        var buf: [64]u8 = undefined;
        const text = sys.readFile(std.fmt.bufPrintSentinel(&path_buf, "/sys/class/video4linux/{s}/name", .{name}, 0) catch continue, &buf) orelse continue;
        const sensor = std.mem.sliceTo(std.mem.trim(u8, text, " \n"), ' ');
        if (sensor.len == 0 or std.mem.startsWith(u8, sensor, "unicam")) continue;
        return .{ .connected = true, .sensor = .of(sensor) };
    }
    return .{};
}

/// A monitor as its EDID says: its maker and name, size, year, best
/// resolution and whether it has speakers. Null if it is not an EDID.
pub fn parseEdid(e: []const u8) ?Monitor {
    if (e.len < 128 or !std.mem.eql(u8, e[0..8], &.{ 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 })) return null;
    var m: Monitor = .{ .connected = true };
    // The maker: three letters, five bits each.
    const code = std.mem.readInt(u16, e[8..10], .big);
    const letters = [3]u8{ @as(u8, @intCast(code >> 10 & 0x1f)) + 'A' - 1, @as(u8, @intCast(code >> 5 & 0x1f)) + 'A' - 1, @as(u8, @intCast(code & 0x1f)) + 'A' - 1 };
    m.maker = .of(makerName(&letters) orelse &letters);
    m.year = if (e[17] > 0) 1990 + @as(u16, e[17]) else 0;
    m.size_mm = .{ @as(u16, e[21]) * 10, @as(u16, e[22]) * 10 };
    // The descriptors: the first its best timing; one its name.
    var d: usize = 54;
    while (d < 126) : (d += 18) {
        const b = e[d..][0..18];
        const clock = std.mem.readInt(u16, b[0..2], .little);
        if (clock != 0) {
            if (d != 54) continue;
            const ha: u32 = b[2] | @as(u32, b[4] >> 4) << 8;
            const hb: u32 = b[3] | @as(u32, b[4] & 0xf) << 8;
            const va: u32 = b[5] | @as(u32, b[7] >> 4) << 8;
            const vb: u32 = b[6] | @as(u32, b[7] & 0xf) << 8;
            m.width = @intCast(ha);
            m.height = @intCast(va);
            if ((ha + hb) * (va + vb) > 0) m.refresh_hz = @intCast((@as(u64, clock) * 10_000 + (ha + hb) * (va + vb) / 2) / ((ha + hb) * (va + vb)));
            // Its size more exactly, in millimetres.
            const wmm: u16 = b[12] | @as(u16, b[14] >> 4) << 8;
            const hmm: u16 = b[13] | @as(u16, b[14] & 0xf) << 8;
            if (wmm > 0 and hmm > 0) m.size_mm = .{ wmm, hmm };
        } else if (b[3] == 0xfc) {
            m.model = .of(std.mem.trimEnd(u8, std.mem.sliceTo(b[5..18], '\n'), " "));
        }
    }
    // Speakers: the CEA extension's basic audio.
    if (e.len >= 256 and e[126] > 0 and e[128] == 0x02) m.speakers = e[131] & 0x40 != 0;
    // A model named for its maker ("DELL U2415"): the maker said once.
    const model = m.model.slice();
    if (model.len > m.maker.len and std.ascii.startsWithIgnoreCase(model, m.maker.slice()) and model[m.maker.len] == ' ') m.model = .of(model[m.maker.len + 1 ..]);
    return m;
}

/// The makers of monitors, by their EDID codes.
fn makerName(code: []const u8) ?[]const u8 {
    const makers = [_]struct { []const u8, []const u8 }{
        .{ "ACR", "Acer" },      .{ "AOC", "AOC" },        .{ "APP", "Apple" },      .{ "AUS", "ASUS" },
        .{ "BNQ", "BenQ" },      .{ "DEL", "Dell" },       .{ "ENC", "Eizo" },       .{ "GBT", "Gigabyte" },
        .{ "GSM", "LG" },        .{ "HEC", "Hisense" },    .{ "HPN", "HP" },         .{ "HWP", "HP" },
        .{ "IVM", "iiyama" },    .{ "LEN", "Lenovo" },     .{ "MEI", "Panasonic" },  .{ "MSI", "MSI" },
        .{ "NEC", "NEC" },       .{ "PHL", "Philips" },    .{ "RPI", "Raspberry Pi" }, .{ "SAM", "Samsung" },
        .{ "SHP", "Sharp" },     .{ "SNY", "Sony" },       .{ "TCL", "TCL" },        .{ "TOS", "Toshiba" },
        .{ "VIZ", "Vizio" },     .{ "VSC", "ViewSonic" },  .{ "XMI", "Xiaomi" },     .{ "HKC", "HKC" },
    };
    for (makers) |mk| if (std.mem.eql(u8, mk[0], code)) return mk[1];
    return null;
}

/// What a Pi 3 with a monitor, the Touch Display 2 and a camera might
/// say, for tests and pictures.
pub fn sample() Hardware {
    var h: Hardware = .{ .bluetooth = false };
    h.hdmi[0] = .{ .connected = true, .maker = .of("Dell"), .model = .of("U2415"), .size_mm = .{ 518, 324 }, .year = 2016, .width = 1920, .height = 1200, .refresh_hz = 60, .speakers = true };
    h.hdmi_sound[0] = .playing;
    h.panel = .{ .connected = true, .name = .of("Touch Display 2"), .width = 720, .height = 1280, .touch = true };
    h.camera = .{ .connected = true, .sensor = .of("imx219") };
    h.card = .{ .name = .of("SC32G"), .month = 3, .year = 2021 };
    return h;
}

test "a monitor's EDID" {
    var e: [256]u8 = @splat(0);
    @memcpy(e[0..8], &[_]u8{ 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 });
    // DEL: D=4, E=5, L=12.
    std.mem.writeInt(u16, e[8..10], (4 << 10) | (5 << 5) | 12, .big);
    e[17] = 26; // 2016
    e[21] = 52;
    e[22] = 32;
    // 1920x1200 at 60 Hz (154 MHz, 2080x1235 in all), 518x324 mm.
    std.mem.writeInt(u16, e[54..56], 15400, .little);
    e[56] = 1920 & 0xff;
    e[57] = 160;
    e[58] = (1920 >> 8) << 4;
    e[59] = 1200 & 0xff;
    e[60] = 35;
    e[61] = (1200 >> 8) << 4;
    e[66] = 518 & 0xff;
    e[67] = 324 & 0xff;
    e[68] = (518 >> 8) << 4 | (324 >> 8);
    // Its name.
    e[72 + 3] = 0xfc;
    @memcpy(e[72 + 5 ..][0..13], "DELL U2415\n  ");
    // Speakers.
    e[126] = 1;
    e[128] = 2;
    e[131] = 0x40;
    const m = parseEdid(&e).?;
    try std.testing.expectEqualStrings("Dell", m.maker.slice());
    try std.testing.expectEqualStrings("U2415", m.model.slice());
    try std.testing.expectEqual(@as(u16, 2016), m.year);
    try std.testing.expectEqual(@as(u16, 1920), m.width);
    try std.testing.expectEqual(@as(u16, 1200), m.height);
    try std.testing.expectEqual(@as(u16, 60), m.refresh_hz);
    try std.testing.expectEqual(@as(u16, 24), m.inches());
    try std.testing.expect(m.speakers);
    try std.testing.expect(parseEdid(e[0..100]) == null);
}

test "a monitor's diagonal, and a camera's module" {
    const h = sample();
    try std.testing.expectEqual(@as(u16, 24), h.hdmi[0].inches());
    try std.testing.expectEqualStrings("Camera Module 2", h.camera.module().?.name);
    try std.testing.expect((Camera{ .sensor = .of("ov9281") }).module() == null);
}
