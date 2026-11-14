//! The dock's quick settings: a popup above the status box (shown when it
//! is clicked) with the volume (a slider, and its icon to mute), how the
//! computer is connected, whether there are updates (clicked: Settings'
//! Software page), and a button to power the computer off (pressed twice:
//! the first press asks to be sure). In a see-through box like the dock's.

const std = @import("std");
const sys = @import("sys");
const font = @import("font");
const icons = @import("icons");
const glass = @import("glass.zig");
const dock = @import("dock.zig");

/// How the computer is connected, as the popup says it: each kind of
/// adapter it has.
pub const NetworkSummary = struct {
    ethernet: Wired = .none,
    /// The link's speed in Mb/s (0: not known).
    speed: u32 = 0,
    wifi: Wireless = .none,
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,

    pub const Wired = enum { none, unplugged, connecting, connected };
    pub const Wireless = enum { none, not_connected, connecting, connected, hotspot };

    pub fn fromReport(r: *const sys.network.Report) NetworkSummary {
        var n: NetworkSummary = .{};
        for (r.ethernetAdapters()) |*e| {
            const a = e.adapter orelse continue;
            const state: Wired = if (e.address != null) .connected else if (a.up) .connecting else .unplugged;
            if (@intFromEnum(state) > @intFromEnum(n.ethernet)) {
                n.ethernet = state;
                n.speed = a.speed;
            }
        }
        if (r.wifiAdapters().len > 0) {
            const c = &r.connection;
            n.wifi = if (r.hotspot.state == .active) .hotspot else switch (c.state) {
                .connected, .addressing => .connected,
                .connecting, .authenticating => .connecting,
                .idle, .failed => .not_connected,
            };
            const name = if (n.wifi == .hotspot) r.hotspot.ssid_buf[0..r.hotspot.ssid_len] else c.ssid();
            n.ssid_len = @intCast(@min(name.len, n.ssid_buf.len));
            @memcpy(n.ssid_buf[0..n.ssid_len], name[0..n.ssid_len]);
        }
        return n;
    }

    pub fn ssid(n: *const NetworkSummary) []const u8 {
        return n.ssid_buf[0..n.ssid_len];
    }

    /// What it says of the wired connection, if there is an adapter.
    pub fn ethernetText(n: *const NetworkSummary, buf: []u8) ?[]const u8 {
        return switch (n.ethernet) {
            .none => null,
            .unplugged => "Ethernet not connected",
            .connecting => "Ethernet connecting",
            .connected => if (n.speed == 0) "Ethernet connected" else if (n.speed % 1000 == 0)
                std.fmt.bufPrint(buf, "Ethernet connected · {d} Gb/s", .{n.speed / 1000}) catch "Ethernet connected"
            else
                std.fmt.bufPrint(buf, "Ethernet connected · {d} Mb/s", .{n.speed}) catch "Ethernet connected",
        };
    }

    /// What it says of Wi-Fi, if there is an adapter.
    pub fn wifiText(n: *const NetworkSummary, buf: []u8) ?[]const u8 {
        return switch (n.wifi) {
            .none => null,
            .not_connected => "Wi-Fi not connected",
            .connecting => std.fmt.bufPrint(buf, "Wi-Fi connecting to {s}", .{n.ssid()}) catch "Wi-Fi connecting",
            .connected => std.fmt.bufPrint(buf, "Wi-Fi connected to {s}", .{n.ssid()}) catch "Wi-Fi connected",
            .hotspot => std.fmt.bufPrint(buf, "Wi-Fi hotspot {s} on", .{n.ssid()}) catch "Wi-Fi hotspot on",
        };
    }
};

/// What there are updates of.
pub const Updates = enum {
    none,
    system,
    apps,
    both,

    pub fn of(system: bool, apps: bool) Updates {
        if (system and apps) return .both;
        if (system) return .system;
        if (apps) return .apps;
        return .none;
    }

    pub fn text(u: Updates) []const u8 {
        return switch (u) {
            .none => "",
            .system => "System update available",
            .apps => "App updates available",
            .both => "System and app updates available",
        };
    }
};

/// The parts of it that do something when clicked.
pub const Part = enum { mute, slider, updates, power };

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
};

/// Its size and parts (at 1080p; scaled).
const box_width = 340;
const pad = 16;
const volume_row = 40;
const volume_icon = 28;
const percent_width = 48;
/// Between the sections, with a line across the middle.
const section_gap = 20;
const network_row = 28;
const small_icon = 22;
const updates_gap = 8;
const updates_row = 36;
const power_row = 40;
const text_size = 16;
/// The slider's track, and the knob on it.
const track_height = 6;
const knob_radius = 9;
/// The highest it gets: two network rows and the updates.
const max_height = pad + volume_row + section_gap + 2 * network_row + updates_gap + updates_row + section_gap + power_row + pad;
/// Between it and the dock.
const gap_above_dock = 8;

/// The slider's colour.
const accent = 0xff3f7ee8;
/// The power button, pressed once.
const armed_color = 0xffd04050;

pub const Quick = struct {
    font: ?font.Font,
    icon_font: ?font.Font,
    cache: font.GlyphCache,
    /// Its picture, `width` by `height` (rows `width` apart); room for the
    /// tallest it gets, twice: the second is where it is drawn over white.
    pixels: []u32,
    width: u32,
    height: u32,
    scale: f32,
    theme: dock.Theme = .dark,
    volume: dock.VolumeStatus = .{},
    network: NetworkSummary = .{},
    updates: Updates = .none,
    /// Showing, and where (its top left on the screen).
    shown: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    /// The part under the pointer.
    hover: ?Part = null,
    /// The slider is being dragged.
    dragging: bool = false,
    /// The power button was pressed once: pressed again, the computer
    /// turns off.
    power_armed: bool = false,

    pub fn init(gpa: std.mem.Allocator, f: ?font.Font, scale: f32) !Quick {
        const width: u32 = @intFromFloat(@round(box_width * scale));
        const most: u32 = @intFromFloat(@ceil(max_height * scale));
        return .{
            .font = f,
            .icon_font = font.Font.init(icons.font_data) catch null,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, 2 * @as(usize, width) * most),
            .width = width,
            .height = most,
            .scale = scale,
        };
    }

    pub fn deinit(q: *Quick, gpa: std.mem.Allocator) void {
        gpa.free(q.pixels);
        q.cache.deinit();
    }

    /// Where its parts are, in it.
    const Layout = struct {
        volume_y: f32,
        network_y: f32,
        network_rows: u32,
        divider_ys: [2]f32,
        updates: ?Rect,
        power: Rect,
        height: f32,
    };

    fn networkRows(q: *const Quick) u32 {
        var n: u32 = 0;
        if (q.network.ethernet != .none) n += 1;
        if (q.network.wifi != .none) n += 1;
        return @max(n, 1);
    }

    fn layout(q: *const Quick) Layout {
        const s = q.scale;
        const w: f32 = @floatFromInt(q.width);
        var y = pad * s;
        const volume_y = y;
        y += volume_row * s;
        const first_divider = y + section_gap * s / 2;
        y += section_gap * s;
        const network_y = y;
        const rows = q.networkRows();
        y += @as(f32, @floatFromInt(rows)) * network_row * s;
        var updates: ?Rect = null;
        if (q.updates != .none) {
            y += updates_gap * s;
            updates = .{ .x = pad * s / 2, .y = y, .w = w - pad * s, .h = updates_row * s };
            y += updates_row * s;
        }
        const second_divider = y + section_gap * s / 2;
        y += section_gap * s;
        const power: Rect = .{ .x = pad * s, .y = y, .w = w - 2 * pad * s, .h = power_row * s };
        y += power_row * s + pad * s;
        return .{
            .volume_y = volume_y,
            .network_y = network_y,
            .network_rows = rows,
            .divider_ys = .{ first_divider, second_divider },
            .updates = updates,
            .power = power,
            .height = @ceil(y),
        };
    }

    fn muteRect(q: *const Quick) Rect {
        const s = q.scale;
        return .{ .x = pad * s / 2, .y = pad * s, .w = (volume_icon + pad) * s, .h = volume_row * s };
    }

    /// Where the slider takes the pointer: its track, as tall as its row.
    pub fn sliderRect(q: *const Quick) Rect {
        const s = q.scale;
        const x0 = (pad + volume_icon + 12) * s;
        const x1 = @as(f32, @floatFromInt(q.width)) - (pad + percent_width) * s;
        return .{ .x = x0, .y = pad * s, .w = x1 - x0, .h = volume_row * s };
    }

    /// The volume the slider has at `x` (in it).
    pub fn volumeAt(q: *const Quick, x: f64) u8 {
        const r = q.sliderRect();
        const k = std.math.clamp((x - r.x) / r.w, 0, 1);
        return @intFromFloat(@round(k * 100));
    }

    /// The part at (`x`, `y`) in it.
    pub fn hit(q: *const Quick, x: f64, y: f64) ?Part {
        const l = q.layout();
        // The slider is easy to catch: a knob's width beyond its ends.
        var slider = q.sliderRect();
        slider.x -= knob_radius * q.scale;
        slider.w += 2 * knob_radius * q.scale;
        if (slider.contains(x, y)) return .slider;
        if (q.muteRect().contains(x, y)) return .mute;
        if (l.updates) |r| if (r.contains(x, y)) return .updates;
        if (l.power.contains(x, y)) return .power;
        return null;
    }

    /// (`x`, `y`) on the screen, in it (if it is shown there).
    pub fn local(q: *const Quick, x: f64, y: f64) ?[2]f64 {
        if (!q.shown) return null;
        const lx = x - @as(f64, @floatFromInt(q.x));
        const ly = y - @as(f64, @floatFromInt(q.y));
        if (lx < 0 or ly < 0 or lx >= @as(f64, @floatFromInt(q.width)) or ly >= @as(f64, @floatFromInt(q.height))) return null;
        return .{ lx, ly };
    }

    /// Puts it above the dock (whose box's top is at `dock_top`), its
    /// right edge at the status box's (`status_right`), on the screen.
    pub fn place(q: *Quick, status_right: i32, dock_top: i32, screen_width: u32) void {
        const margin: i32 = @intFromFloat(@round(dock.Dock.margin * q.scale));
        const w: i32 = @intCast(q.width);
        q.x = std.math.clamp(status_right - w, margin, @max(margin, @as(i32, @intCast(screen_width)) - w - margin));
        q.y = dock_top - @as(i32, @intFromFloat(@round(gap_above_dock * q.scale))) - @as(i32, @intCast(q.height));
    }

    /// What a press does.
    pub const Action = union(enum) {
        none,
        /// It looks different: draw it again.
        redraw,
        /// The volume, as it is to be.
        volume: dock.VolumeStatus,
        /// Settings' Software page opens, and the popup closes.
        updates,
        /// The computer is to be powered off.
        power_off,
    };

    /// A press at (`x`, `y`) in it.
    pub fn press(q: *Quick, x: f64, y: f64) Action {
        const part = q.hit(x, y);
        // Anything else pressed, the power button is not pressed twice.
        const disarmed = q.power_armed and part != .power;
        if (disarmed) q.power_armed = false;
        switch (part orelse return if (disarmed) .redraw else .none) {
            .mute => return .{ .volume = .{ .volume = q.volume.volume, .muted = !q.volume.muted } },
            .slider => {
                q.dragging = true;
                return .{ .volume = .{ .volume = q.volumeAt(x), .muted = false } };
            },
            .updates => return .updates,
            .power => {
                if (q.power_armed) return .power_off;
                q.power_armed = true;
                return .redraw;
            },
        }
    }

    /// The pointer moved to `x` in it (wherever it is): the volume, if the
    /// slider is being dragged to another.
    pub fn drag(q: *const Quick, x: f64) ?dock.VolumeStatus {
        if (!q.dragging) return null;
        const v = q.volumeAt(x);
        if (v == q.volume.volume and !q.volume.muted) return null;
        return .{ .volume = v, .muted = false };
    }

    /// The press ended. Returns whether the slider was being dragged.
    pub fn release(q: *Quick) bool {
        defer q.dragging = false;
        return q.dragging;
    }

    /// The pointer is at (`x`, `y`) in it (null: elsewhere). Returns
    /// whether what it highlights changed.
    pub fn pointerAt(q: *Quick, at: ?[2]f64) bool {
        const part = if (at) |l| q.hit(l[0], l[1]) else null;
        if (part == q.hover) return false;
        q.hover = part;
        return true;
    }

    /// Closes it, as it was before it opened.
    pub fn close(q: *Quick) void {
        q.shown = false;
        q.hover = null;
        q.dragging = false;
        q.power_armed = false;
    }

    pub fn picture(q: *const Quick) []const u32 {
        return q.pixels[0 .. @as(usize, q.width) * q.height];
    }

    pub fn draw(q: *Quick) void {
        q.height = @intFromFloat(q.layout().height);
        const n = @as(usize, q.width) * q.height;
        const over_black: font.Canvas = .{ .pixels = q.pixels[0..n], .width = q.width, .height = q.height, .stride = q.width };
        const over_white: font.Canvas = .{ .pixels = q.pixels[n .. 2 * n], .width = q.width, .height = q.height, .stride = q.width };
        q.drawContents(over_black, glass.black);
        q.drawContents(over_white, glass.white);
        glass.compose(over_black.pixels, over_white.pixels, q.theme.colors().background);
        glass.cutCorners(over_black, @round(dock.Dock.box_radius * q.scale));
    }

    fn drawContents(q: *Quick, canvas: font.Canvas, base: u32) void {
        const c = q.theme.colors();
        const s = q.scale;
        const w: f32 = @floatFromInt(q.width);
        const l = q.layout();
        canvas.fill(0, 0, q.width, q.height, base);
        const text_color = c.dot;

        // The volume: its icon (clicked: muted), the slider and how loud.
        const mute = q.muteRect();
        if (q.hover == .mute) glass.fillRounded(canvas, mute.x, mute.y, mute.w, mute.h, 10 * s, c.hover_background);
        const vol_icon = @round(volume_icon * s);
        q.icon(canvas, q.volume.icon(), vol_icon, pad * s, l.volume_y + (volume_row * s - vol_icon) / 2, text_color);
        const slider = q.sliderRect();
        const track_y = l.volume_y + (volume_row * s - track_height * s) / 2;
        const th = track_height * s;
        glass.fillRounded(canvas, slider.x, track_y, slider.w, th, th / 2, c.status_border);
        const k = @as(f32, @floatFromInt(q.volume.volume)) / 100;
        const fill = if (q.volume.active()) accent else c.status_inactive;
        if (k > 0) glass.fillRounded(canvas, slider.x, track_y, @max(th, slider.w * k), th, th / 2, fill);
        const knob = knob_radius * s * (if (q.hover == .slider or q.dragging) @as(f32, 1.15) else 1);
        const knob_x = slider.x + slider.w * k;
        glass.fillRounded(canvas, knob_x - knob, track_y + th / 2 - knob, 2 * knob, 2 * knob, knob, text_color);
        if (q.font) |*f| {
            var pbuf: [8]u8 = undefined;
            const pct = std.fmt.bufPrint(&pbuf, "{d}%", .{q.volume.volume}) catch "";
            const style: font.Style = .{ .font = f, .size = @round(text_size * s), .color = text_color };
            const tw = font.measure(style, pct);
            _ = font.draw(canvas, &q.cache, style, @round(w - pad * s - tw), @round(l.volume_y + volume_row * s / 2 + style.ascent() * 0.36), pct) catch {};
        }

        for (l.divider_ys) |dy| canvas.fill(@intFromFloat(pad * s), @intFromFloat(@round(dy)), @intFromFloat(w - 2 * pad * s), @max(1, @as(u32, @intFromFloat(@round(s)))), c.status_border);

        // The network: a line for each kind of adapter.
        var lines: [2]struct { icon: icons.Icon, text: []const u8 } = undefined;
        var count: usize = 0;
        var eth_buf: [64]u8 = undefined;
        var wifi_buf: [96]u8 = undefined;
        if (q.network.ethernetText(&eth_buf)) |t| {
            lines[count] = .{ .icon = .lan, .text = t };
            count += 1;
        }
        if (q.network.wifiText(&wifi_buf)) |t| {
            lines[count] = .{ .icon = switch (q.network.wifi) {
                .connected, .connecting => .wifi,
                .hotspot => .wifi_tethering,
                else => .wifi_off,
            }, .text = t };
            count += 1;
        }
        if (count == 0) {
            lines[0] = .{ .icon = .public_off, .text = "No network adapter" };
            count = 1;
        }
        for (lines[0..count], 0..) |line, i| {
            const y = l.network_y + @as(f32, @floatFromInt(i)) * network_row * s;
            q.iconRow(canvas, line.icon, line.text, y, network_row * s, text_color);
        }

        // Updates, if there are any: clicked, Settings' Software page.
        if (l.updates) |r| {
            if (q.hover == .updates) glass.fillRounded(canvas, r.x, r.y, r.w, r.h, 10 * s, c.hover_background);
            q.iconRow(canvas, .system_update_alt, q.updates.text(), r.y, r.h, text_color);
            const ic = @round(small_icon * s);
            q.icon(canvas, .chevron_right, ic, r.x + r.w - pad * s / 2 - ic, r.y + (r.h - ic) / 2, text_color);
        }

        // Turning the computer off: pressed once, it asks to be sure.
        const p = l.power;
        const button: u32 = if (q.power_armed) armed_color else if (q.hover == .power) c.status_border else c.hover_background;
        glass.fillRounded(canvas, p.x, p.y, p.w, p.h, 12 * s, button);
        const label = if (q.power_armed) "Click again to power off" else "Power off";
        const color: u32 = if (q.power_armed) 0xffffffff else text_color;
        const ic = @round(small_icon * s);
        const gap = 8 * s;
        const tw = if (q.font) |*f| font.measure(.{ .font = f, .size = @round(text_size * s), .color = color }, label) else 0;
        const x0 = @round(p.x + (p.w - (ic + gap + tw)) / 2);
        q.icon(canvas, .power_settings_new, ic, x0, p.y + (p.h - ic) / 2, color);
        if (q.font) |*f| {
            const style: font.Style = .{ .font = f, .size = @round(text_size * s), .color = color };
            _ = font.draw(canvas, &q.cache, style, x0 + ic + gap, @round(p.y + p.h / 2 + style.ascent() * 0.36), label) catch {};
        }
    }

    /// An icon `size` big with its top left at (`x`, `y`).
    fn icon(q: *Quick, canvas: font.Canvas, which: icons.Icon, size: f32, x: f32, y: f32, color: u32) void {
        const f = if (q.icon_font) |*f| f else return;
        var buf: [4]u8 = undefined;
        // Icons fill the em square, with the baseline at the bottom.
        _ = font.draw(canvas, &q.cache, .{ .font = f, .size = size, .color = color }, @round(x), @round(y) + size, icons.text(which, &buf)) catch {};
    }

    /// An icon and text after it, in a row `h` high at `y`, cut short (with
    /// an ellipsis) if it is too long.
    fn iconRow(q: *Quick, canvas: font.Canvas, which: icons.Icon, text: []const u8, y: f32, h: f32, color: u32) void {
        const s = q.scale;
        const ic = @round(small_icon * s);
        q.icon(canvas, which, ic, pad * s, y + (h - ic) / 2, color);
        const f = if (q.font) |*f| f else return;
        const style: font.Style = .{ .font = f, .size = @round(text_size * s), .color = color };
        const x = pad * s + ic + 10 * s;
        const room = @as(f32, @floatFromInt(q.width)) - x - pad * s;
        var shown = text;
        var buf: [128]u8 = undefined;
        if (font.measure(style, text) > room) {
            var n = text.len;
            while (n > 0) {
                n -= 1;
                // Not in the middle of a character.
                if (n < text.len and text[n] & 0xc0 == 0x80) continue;
                shown = std.fmt.bufPrint(&buf, "{s}…", .{text[0..n]}) catch text;
                if (font.measure(style, shown) <= room) break;
            }
        }
        _ = font.draw(canvas, &q.cache, style, @round(x), @round(y + h / 2 + style.ascent() * 0.36), shown) catch {};
    }
};

const testing = std.testing;

test "the network summary says how each kind of adapter is connected" {
    var r: sys.network.Report = .{};
    var none_buf: [96]u8 = undefined;
    // No adapters: nothing to say of either.
    var n = NetworkSummary.fromReport(&r);
    try testing.expect(n.ethernetText(&none_buf) == null and n.wifiText(&none_buf) == null);

    var eth: sys.network.Adapter = .{ .up = true, .speed = 100 };
    eth.setName("eth0");
    r.addEthernet(.{ .adapter = eth, .address = .{ 192, 168, 1, 2 } });
    var wifi: sys.network.Adapter = .{};
    wifi.setName("wlan0");
    r.addAdapter(wifi);
    n = NetworkSummary.fromReport(&r);
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("Ethernet connected · 100 Mb/s", n.ethernetText(&buf).?);
    try testing.expectEqualStrings("Wi-Fi not connected", n.wifiText(&buf).?);

    r.connection.state = .connected;
    r.connection.setSsid("Home");
    r.ethernets[0].adapter.?.speed = 1000;
    n = NetworkSummary.fromReport(&r);
    try testing.expectEqualStrings("Ethernet connected · 1 Gb/s", n.ethernetText(&buf).?);
    try testing.expectEqualStrings("Wi-Fi connected to Home", n.wifiText(&buf).?);

    // A cable without an address yet, and none at all.
    r.ethernets[0].address = null;
    try testing.expectEqualStrings("Ethernet connecting", NetworkSummary.fromReport(&r).ethernetText(&buf).?);
    r.ethernets[0].adapter.?.up = false;
    try testing.expectEqualStrings("Ethernet not connected", NetworkSummary.fromReport(&r).ethernetText(&buf).?);
}

test "updates are described by what they are of" {
    try testing.expectEqual(Updates.none, Updates.of(false, false));
    try testing.expectEqualStrings("System update available", Updates.of(true, false).text());
    try testing.expectEqualStrings("App updates available", Updates.of(false, true).text());
    try testing.expectEqualStrings("System and app updates available", Updates.of(true, true).text());
}

test "the popup sits above the status box, and its parts take clicks" {
    var q = try Quick.init(testing.allocator, null, 1);
    defer q.deinit(testing.allocator);
    q.network.ethernet = .connected;
    q.volume = .{ .volume = 40, .muted = false };
    q.draw();
    const no_updates = q.height;
    q.updates = .system;
    q.draw();
    // Taller with the updates in it.
    try testing.expect(q.height > no_updates);
    q.place(1300, 992, 1920);
    try testing.expectEqual(@as(i32, 1300 - 340), q.x);
    try testing.expectEqual(@as(i32, 992 - 8 - @as(i32, @intCast(q.height))), q.y);
    // Kept on the screen.
    q.place(100, 992, 1920);
    try testing.expectEqual(@as(i32, 8), q.x);

    const slider = q.sliderRect();
    try testing.expectEqual(Part.slider, q.hit(slider.x + slider.w / 2, slider.y + slider.h / 2).?);
    try testing.expectEqual(@as(u8, 50), q.volumeAt(slider.x + slider.w / 2));
    try testing.expectEqual(@as(u8, 0), q.volumeAt(slider.x - 50));
    try testing.expectEqual(@as(u8, 100), q.volumeAt(slider.x + slider.w + 50));
    try testing.expectEqual(Part.mute, q.hit(20, 30).?);
    const l = q.layout();
    try testing.expectEqual(Part.updates, q.hit(l.updates.?.x + 10, l.updates.?.y + 10).?);
    try testing.expectEqual(Part.power, q.hit(l.power.x + l.power.w / 2, l.power.y + l.power.h / 2).?);
    try testing.expect(q.hit(5, 2) == null);

    // A see-through box, the corners cut; the power button solid.
    const pic = q.picture();
    try testing.expectEqual(@as(u32, 0), pic[0] >> 24);
    try testing.expectEqual(@as(u32, glass.alpha), pic[@as(usize, q.height / 2) * q.width + 2] >> 24);
    const px: usize = @intFromFloat(l.power.x + 4);
    const py: usize = @intFromFloat(l.power.y + l.power.h / 2);
    try testing.expectEqual(dock.Theme.dark.colors().hover_background, pic[py * q.width + px]);
}

test "pressing the popup's parts mutes, drags the slider, and asks twice before powering off" {
    var q = try Quick.init(testing.allocator, null, 1);
    defer q.deinit(testing.allocator);
    q.volume = .{ .volume = 40, .muted = false };
    q.updates = .apps;
    q.draw();
    const l = q.layout();
    // The icon mutes, and unmutes.
    try testing.expectEqual(dock.VolumeStatus{ .volume = 40, .muted = true }, q.press(20, 30).volume);
    // The slider: pressed, the volume there; dragged, along with it (off
    // its end too), and let go.
    const slider = q.sliderRect();
    try testing.expectEqual(@as(u8, 25), q.press(slider.x + slider.w / 4, slider.y + 5).volume.volume);
    q.volume.volume = 25;
    try testing.expectEqual(@as(u8, 100), q.drag(slider.x + slider.w + 40).?.volume);
    try testing.expect(q.release());
    try testing.expect(q.drag(slider.x) == null);
    // Updates: Settings.
    try testing.expect(q.press(l.updates.?.x + 5, l.updates.?.y + 5) == .updates);
    // Power: once to ask, again to power off; anything between, and it
    // asks again.
    const px = l.power.x + 5;
    const py = l.power.y + 5;
    try testing.expect(q.press(px, py) == .redraw);
    try testing.expect(q.power_armed);
    try testing.expect(q.press(5, 2) == .redraw);
    try testing.expect(!q.power_armed);
    try testing.expect(q.press(px, py) == .redraw);
    try testing.expect(q.press(px, py) == .power_off);
    q.close();
    try testing.expect(!q.power_armed and !q.shown);
}
