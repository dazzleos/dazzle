//! The dock's quick settings: a popup above the status box (shown when it
//! is clicked) with the volume (a slider, and its icon to mute), how the
//! computer is connected, whether there are updates (clicked: Settings'
//! Software page), and a button to power the computer off (pressed twice:
//! the first press asks to be sure). In a see-through box like the dock's.

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const icons = @import("icons");
const glass = @import("glass.zig");
const dock = @import("dock.zig");
const kete_panel = @import("kete_panel.zig");
const ui_icons = @import("ui_icons.zig");

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
    /// Where it is drawn (kete's).
    panel: *kete_panel.Panel,
    /// Its picture, `width` by `height`, as `draw` last drew it (on the
    /// GPU, if the kit has it).
    drawn: kete_panel.Picture = .{},
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

    pub fn init(kit: *kete_panel.Kit, scale: f32) !Quick {
        const width: u32 = @intFromFloat(@round(box_width * scale));
        const most: u32 = @intFromFloat(@ceil(max_height * scale));
        return .{
            .panel = try kit.gpuPanel(),
            .width = width,
            .height = most,
            .scale = scale,
        };
    }

    pub fn deinit(q: *Quick) void {
        q.panel.destroy();
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

    pub fn picture(q: *const Quick) kete_panel.Picture {
        return q.drawn;
    }

    /// Draws it as it is now (with kete: see `View`).
    pub fn draw(q: *Quick) void {
        q.height = @intFromFloat(q.layout().height);
        q.drawn = q.panel.draw(q.width, q.height, 0, View{ .q = q });
    }

    /// It as kete widgets, each where its layout puts it.
    const View = struct {
        q: *const Quick,

        pub fn build(v: *const View, cx: *kete.BuildContext) kete.Widget {
            const q = v.q;
            const c = q.theme.colors();
            const s = q.scale;
            const w: f32 = @floatFromInt(q.width);
            const l = q.layout();
            const a = cx.arena;
            const argb = kete.gfx.Color.argb;
            var layers: std.ArrayList(kete.Widget) = .empty;
            layers.append(a, cx.make(Fill{ .color = (c.background & 0x00ffffff) | @as(u32, glass.alpha) << 24, .radius = @round(dock.Dock.box_radius * s) })) catch {};
            // The volume: its icon (clicked: muted), the slider and how loud.
            layers.append(a, placed(cx, 0, l.volume_y, w, volume_row * s, cx.make(Volume{
                .theme = q.theme,
                .scale = s,
                .volume = q.volume,
                .mute_hover = q.hover == .mute,
                .knob_big = q.hover == .slider or q.dragging,
                .mute = q.muteRect(),
                .slider = q.sliderRect(),
            }))) catch {};
            for (l.divider_ys) |dy| layers.append(a, placed(cx, pad * s, @round(dy), w - 2 * pad * s, @max(1, @round(s)), cx.make(Fill{ .color = c.status_border }))) catch {};
            // The network: a line for each kind of adapter.
            var lines: [2]struct { icon: kete.IconName, text: []const u8 } = undefined;
            var count: usize = 0;
            if (q.network.ethernetText(a.alloc(u8, 64) catch &.{})) |t| {
                lines[count] = .{ .icon = .lan, .text = t };
                count += 1;
            }
            if (q.network.wifiText(a.alloc(u8, 96) catch &.{})) |t| {
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
                layers.append(a, placed(cx, pad * s, y, w - 2 * pad * s, network_row * s, iconRow(cx, s, line.icon, line.text, argb(c.dot), null))) catch {};
            }
            // Updates, if there are any: clicked, Settings' Software page.
            if (l.updates) |r| layers.append(a, placed(cx, r.x, r.y, r.w, r.h, cx.make(kete.RoundedBox{
                .color = argb(if (q.hover == .updates) c.hover_background else 0),
                .radius = .all(10 * s),
                .child = cx.make(kete.Padding{ .padding = .{ .left = pad * s / 2, .right = pad * s / 2 }, .child = iconRow(cx, s, .system_update_alt, q.updates.text(), argb(c.dot), .chevron_right) }),
            }))) catch {};
            // Turning the computer off: pressed once, it asks to be sure.
            const pw = l.power;
            const color: u32 = if (q.power_armed) 0xffffffff else c.dot;
            layers.append(a, placed(cx, pw.x, pw.y, pw.w, pw.h, cx.make(kete.RoundedBox{
                .color = argb(if (q.power_armed) armed_color else if (q.hover == .power) c.status_border else c.hover_background),
                .radius = .all(12 * s),
                .child = cx.make(kete.Align{ .child = cx.make(kete.Row{ .fill = false, .cross_axis_alignment = .center, .spacing = 8 * s, .children = a.dupe(kete.Widget, &.{
                    cx.make(kete.Icon{ .icon = .power_settings_new, .size = @round(small_icon * s), .color = argb(color) }),
                    cx.make(kete.Text{ .text = if (q.power_armed) "Click again to power off" else "Power off", .style = .{ .size = @round(text_size * s), .color = argb(color) }, .wrap = false }),
                }) catch &.{} }) }),
            }))) catch {};
            return cx.make(kete.Overlay{ .children = layers.items });
        }
    };

    /// `child`, `w` by `h`, at (`x`, `y`) in it.
    fn placed(cx: *kete.BuildContext, x: f32, y: f32, w: f32, h: f32, child: kete.Widget) kete.Widget {
        return cx.make(kete.Align{ .alignment = .top_left, .child = cx.make(kete.Padding{ .padding = .{ .left = x, .top = y }, .child = cx.make(kete.SizedBox{ .width = w, .height = h, .child = child }) }) });
    }

    /// An icon and text after it, cut short (with an ellipsis) if it is too
    /// long; and another icon at the end, if any.
    fn iconRow(cx: *kete.BuildContext, s: f32, which: kete.IconName, text: []const u8, color: kete.gfx.Color, end: ?kete.IconName) kete.Widget {
        const a = cx.arena;
        var items: std.ArrayList(kete.Widget) = .empty;
        items.appendSlice(a, &.{
            cx.make(kete.Icon{ .icon = which, .size = @round(small_icon * s), .color = color }),
            cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = text, .style = .{ .size = @round(text_size * s), .color = color }, .wrap = false, .ellipsis = true }) }),
        }) catch {};
        if (end) |e| items.append(a, cx.make(kete.Icon{ .icon = e, .size = @round(small_icon * s), .color = color })) catch {};
        return cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 10 * s, .children = items.items });
    }

    /// A rounded rectangle filling where it is put.
    const Fill = struct {
        color: u32,
        radius: f32 = 0,

        pub fn layout(_: *const Fill, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
            return c.constrain(.{ .w = c.max_w, .h = c.max_h });
        }

        pub fn paint(f: *const Fill, n: *kete.WidgetNode, p: *kete.Painter) void {
            const r: kete.gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
            if (f.radius > 0) p.canvas().fillRoundedRect(r, .all(f.radius), kete.gfx.Color.argb(f.color)) else p.canvas().fillRect(r, kete.gfx.Color.argb(f.color));
        }
    };

    /// The volume's row: its icon (the mute button), the slider and how
    /// loud, at the rectangles given (in the popup).
    const Volume = struct {
        theme: dock.Theme,
        scale: f32,
        volume: dock.VolumeStatus,
        mute_hover: bool,
        knob_big: bool,
        mute: Rect,
        slider: Rect,

        pub fn layout(_: *const Volume, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
            return c.constrain(.{ .w = c.max_w, .h = c.max_h });
        }

        pub fn paint(v: *const Volume, n: *kete.WidgetNode, p: *kete.Painter) void {
            const c = v.theme.colors();
            const argb = kete.gfx.Color.argb;
            const s = v.scale;
            const cv = p.canvas();
            const h = n.size.h;
            if (v.mute_hover) cv.fillRoundedRect(.{ .x = v.mute.x, .y = 0, .w = v.mute.w, .h = v.mute.h }, .all(10 * s), argb(c.hover_background));
            const vol_icon = @round(volume_icon * s);
            p.icon(ui_icons.of(v.volume.icon()), @round(pad * s), @round((h - vol_icon) / 2), vol_icon, argb(c.dot));
            const th = track_height * s;
            const track_y = (h - th) / 2;
            cv.fillRoundedRect(.{ .x = v.slider.x, .y = track_y, .w = v.slider.w, .h = th }, .all(th / 2), argb(c.status_border));
            const k = @as(f32, @floatFromInt(v.volume.volume)) / 100;
            if (k > 0) cv.fillRoundedRect(.{ .x = v.slider.x, .y = track_y, .w = @max(th, v.slider.w * k), .h = th }, .all(th / 2), argb(if (v.volume.active()) accent else c.status_inactive));
            const knob = knob_radius * s * (if (v.knob_big) @as(f32, 1.15) else 1);
            cv.fillCircle(.{ v.slider.x + v.slider.w * k, track_y + th / 2 }, knob, argb(c.dot));
            if (p.ui.font) |f| {
                var pbuf: [8]u8 = undefined;
                const pct = std.fmt.bufPrint(&pbuf, "{d}%", .{v.volume.volume}) catch "";
                const style: kete.font.Style = .{ .font = f, .size = @round(text_size * s) };
                _ = p.text(style.size, @round(n.size.w - pad * s - kete.font.measure(style, pct)), @round(h / 2 + style.ascent() * 0.36), pct, argb(c.dot));
            }
        }
    };
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
    const kit = try kete_panel.Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    var q = try Quick.init(kit, 1);
    defer q.deinit();
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
    const pic = q.picture().pixels;
    try testing.expectEqual(@as(u32, 0), pic[0] >> 24);
    try testing.expectEqual(@as(u32, glass.alpha), pic[@as(usize, q.height / 2) * q.width + 2] >> 24);
    const px: usize = @intFromFloat(l.power.x + 4);
    const py: usize = @intFromFloat(l.power.y + l.power.h / 2);
    try testing.expectEqual(dock.Theme.dark.colors().hover_background, pic[py * q.width + px]);
}

test "pressing the popup's parts mutes, drags the slider, and asks twice before powering off" {
    const kit = try kete_panel.Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    var q = try Quick.init(kit, 1);
    defer q.deinit();
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
