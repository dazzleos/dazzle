//! The USB page: the USB devices plugged in, what each is, who made it
//! and how fast it talks; those that are part of the board last.

const std = @import("std");
const ui = @import("ui");
const usb = @import("usb.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Builder = view.Builder;

pub const label = "USB";
pub const icon: ui.icons.Icon = .usb;

pub fn build(self: *const Settings, b: Builder) ui.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const devices = self.usb.slice();
    if (devices.len == 0) return b.page(&.{b.value("Nothing is plugged in")});
    const a = cx.ui.arena();
    var rows: std.ArrayList(ui.Widget) = .empty;
    for (devices) |*d| {
        var name_buf: [64]u8 = undefined;
        var speed_buf: [16]u8 = undefined;
        var detail: std.ArrayList(u8) = .empty;
        detail.appendSlice(a, d.kind.label()) catch {};
        if (d.manufacturer.len > 0) detail.print(a, "  \u{b7}  {s}", .{d.manufacturer.slice()}) catch {};
        const speed = usb.formatSpeed(&speed_buf, d.speed_mbps);
        if (speed.len > 0) detail.print(a, "  \u{b7}  {s}", .{speed}) catch {};
        if (d.built_in) detail.appendSlice(a, "  \u{b7}  Part of the board") catch {};
        rows.append(a, cx.make(ui.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = &.{
            cx.make(ui.Icon{ .icon = usbIcon(d.kind), .size = 28, .color = t.on_surface_variant }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                cx.make(ui.Text{ .text = cx.fmt("{s}", .{d.name(&name_buf)}), .style = .{ .size = 18 }, .wrap = false, .ellipsis = true }),
                cx.make(ui.Text{ .text = detail.items, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
            } }) }),
        } })) catch {};
    }
    return b.page(rows.items);
}

fn usbIcon(k: usb.Kind) ui.icons.Icon {
    return switch (k) {
        .keyboard => .keyboard,
        .mouse => .mouse,
        .input => .sports_esports,
        .storage => .usb,
        .hub => .device_hub,
        .network => .lan,
        .wireless => .wifi,
        .audio => .headphones,
        .camera => .videocam,
        .printer => .print,
        .other => .usb,
    };
}

const testing = std.testing;
const font = @import("font");

test "the USB devices: each with what it is, and the board's own" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var devices: usb.Devices = .{};
    devices.items[0] = .{ .kind = .keyboard, .speed_mbps = 1.5, .vendor_id = 0x046d, .product_id = 0xc31c };
    devices.items[0].product.set("USB Keyboard");
    devices.items[0].manufacturer.set("Logitech");
    devices.items[1] = .{ .kind = .storage, .speed_mbps = 480, .vendor_id = 0x0781, .product_id = 0x5567 };
    devices.items[2] = .{ .kind = .network, .speed_mbps = 480, .built_in = true, .vendor_id = 0x0424, .product_id = 0xec00 };
    devices.len = 3;
    var settings: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .usb = &devices };
    u.frame(1600, 900, 0, settings);
    u.root.?.state(Settings.State).page = .usb;
    for (view.test_sizes) |size| {
        u.frame(size[0], size[1], 1, settings);
        try testing.expect(!view.overflows(u.root.?));
    }
    u.frame(1600, 900, 2, settings);
    try testing.expect(view.findText(u.root.?, "USB Keyboard") != null);
    try testing.expect(view.findText(u.root.?, "Keyboard  \u{b7}  Logitech  \u{b7}  1.5 Mb/s") != null);
    try testing.expect(view.findText(u.root.?, "USB device 0781:5567") != null);
    try testing.expect(view.findText(u.root.?, "Network adapter  \u{b7}  480 Mb/s  \u{b7}  Part of the board") != null);
    // Nothing: it says so.
    const none: usb.Devices = .{};
    settings.usb = &none;
    u.frame(1600, 900, 3, settings);
    try testing.expect(view.findText(u.root.?, "Nothing is plugged in") != null);
}
