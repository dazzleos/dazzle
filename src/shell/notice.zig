//! Notifications: a short message at the top of the screen, in the middle,
//! in a see-through box like the dock's: an icon, a title and a line under
//! it. It fades in, stays a few seconds, and fades out; a new one takes
//! the place of the one showing. The first use: a screenshot was saved
//! (and where).

const std = @import("std");
const kete = @import("kete");
const glass = @import("glass.zig");
const dock = @import("dock.zig");
const kete_panel = @import("kete_panel.zig");

/// How long it takes to fade in, stays, and takes to fade out.
pub const fade_in_ns = 150 * std.time.ns_per_ms;
pub const stay_ns = 3 * std.time.ns_per_s;
pub const fade_out_ns = 400 * std.time.ns_per_ms;

/// Its size and parts (at 1080p; scaled).
const box_height = 72;
const min_width = 320;
const max_width = 640;
const pad = 20;
const icon_size = 32;
const icon_gap = 16;
const title_size = 17;
const body_size = 15;
/// Between it and the top of the screen.
const top_margin = 16;

pub const Notice = struct {
    /// Where it is drawn (kete's: see kete_panel.zig).
    panel: *kete_panel.Panel,
    /// Its picture as drawn, and as it is shown, faded: room for the
    /// widest it gets, twice.
    pixels: []u32,
    width: u32 = 0,
    height: u32,
    scale: f32,
    screen_width: u32,
    theme: dock.Theme = .dark,
    /// Since when it shows (null: it does not).
    shown_ns: ?u64 = null,
    /// How opaque it was last drawn (to draw it again only if that
    /// changes).
    opacity: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, panel: *kete_panel.Panel, screen_width: u32, scale: f32) !Notice {
        const most = maxWidth(screen_width, scale);
        const height: u32 = @intFromFloat(@round(box_height * scale));
        return .{
            .panel = panel,
            .pixels = try gpa.alloc(u32, 2 * @as(usize, most) * height),
            .height = height,
            .scale = scale,
            .screen_width = screen_width,
        };
    }

    pub fn deinit(n: *Notice, gpa: std.mem.Allocator) void {
        gpa.free(n.pixels);
    }

    fn maxWidth(screen_width: u32, scale: f32) u32 {
        return @min(@as(u32, @intFromFloat(@round(max_width * scale))), screen_width);
    }

    /// Shows `title` and `body` beside `icon`, from `now`, in place of
    /// what showed.
    pub fn show(n: *Notice, icon: kete.IconName, title: []const u8, body: []const u8, now: u64) void {
        const view: View = .{ .theme = n.theme, .scale = n.scale, .icon = icon, .title = title, .body = body };
        const s = n.scale;
        const natural = n.panel.naturalSize(view);
        const least = @min(@as(u32, @intFromFloat(@round(min_width * s))), maxWidth(n.screen_width, s));
        n.width = std.math.clamp(natural[0], least, maxWidth(n.screen_width, s));
        const count = @as(usize, n.width) * n.height;
        const drawn = n.panel.draw(n.width, n.height, now, view).pixels;
        if (drawn.len == count) @memcpy(n.pixels[0..count], drawn) else @memset(n.pixels[0..count], 0);
        n.shown_ns = now;
        n.opacity = -1;
    }

    /// How opaque it is at `now` (0: gone).
    pub fn opacityAt(n: *const Notice, now: u64) f32 {
        const since = now -| (n.shown_ns orelse return 0);
        if (since < fade_in_ns) return @as(f32, @floatFromInt(since)) / fade_in_ns;
        if (since < fade_in_ns + stay_ns) return 1;
        const out = since - fade_in_ns - stay_ns;
        if (out >= fade_out_ns) return 0;
        return 1 - @as(f32, @floatFromInt(out)) / fade_out_ns;
    }

    /// Whether it shows at `now` (fading in, staying or fading out).
    pub fn visible(n: *const Notice, now: u64) bool {
        const start = n.shown_ns orelse return false;
        return now < start + fade_in_ns + stay_ns + fade_out_ns;
    }

    /// When it next changes after `now` (it starts to fade out, or is
    /// fading), if it shows.
    pub fn wakeAt(n: *const Notice, now: u64) ?u64 {
        const start = n.shown_ns orelse return null;
        const fade_out_from = start + fade_in_ns + stay_ns;
        if (now >= fade_out_from + fade_out_ns) return null;
        if (now < start + fade_in_ns or now >= fade_out_from) return now;
        return fade_out_from;
    }

    /// Its picture at `now`, if it changed since it was last asked for
    /// (faded as much as it is then); null if it is the same, or gone.
    pub fn frame(n: *Notice, now: u64) ?[]const u32 {
        if (!n.visible(now)) {
            n.shown_ns = null;
            return null;
        }
        const k = n.opacityAt(now);
        if (k == n.opacity) return null;
        n.opacity = k;
        const count = @as(usize, n.width) * n.height;
        const src = n.pixels[0..count];
        const out = n.pixels[count .. 2 * count];
        const a: u32 = @intFromFloat(@round(k * 256));
        for (out, src) |*o, p| o.* = (p & 0x00ffffff) | ((p >> 24) * a >> 8) << 24;
        return out;
    }

    /// Where it is on the screen: at the top, in the middle.
    pub fn place(n: *const Notice) [2]i32 {
        return .{ @divTrunc(@as(i32, @intCast(n.screen_width)) - @as(i32, @intCast(n.width)), 2), @intFromFloat(@round(top_margin * n.scale)) };
    }
};

// The icons notices are shown with (for kete's icon font, which has only
// the icons named).
comptime {
    _ = &[_]kete.IconName{ .photo_camera, .warning, .check, .schedule };
}

/// What it shows, as kete widgets: the icon, and the title with a line
/// under it, in a see-through box like the dock's.
const View = struct {
    theme: dock.Theme,
    scale: f32,
    icon: kete.IconName,
    title: []const u8,
    body: []const u8,

    pub fn build(v: *const View, cx: *kete.BuildContext) kete.Widget {
        const c = v.theme.colors();
        const s = v.scale;
        const text = kete.gfx.Color.argb(c.dot);
        const dim = kete.gfx.Color.argb((c.dot & 0x00ffffff) | 0xb8000000);
        var lines: std.ArrayList(kete.Widget) = .empty;
        const a = cx.arena;
        lines.append(a, cx.make(kete.Text{ .text = v.title, .style = .{ .size = @round(title_size * s), .color = text }, .wrap = false, .ellipsis = true })) catch {};
        if (v.body.len > 0) lines.append(a, cx.make(kete.Text{ .text = v.body, .style = .{ .size = @round(body_size * s), .color = dim }, .wrap = false, .ellipsis = true })) catch {};
        return cx.make(kete.RoundedBox{
            .color = kete.gfx.Color.argb((c.background & 0x00ffffff) | @as(u32, glass.alpha) << 24),
            .radius = .all(@round(dock.Dock.box_radius * s)),
            .child = cx.make(kete.Padding{ .padding = .{ .left = @round(pad * s), .right = @round(pad * s) }, .child = cx.make(kete.SizedBox{ .height = @round(box_height * s), .child = cx.make(kete.Row{
                .fill = false,
                .cross_axis_alignment = .center,
                .spacing = @round(icon_gap * s),
                .children = a.dupe(kete.Widget, &.{
                    cx.make(kete.Icon{ .icon = v.icon, .size = @round(icon_size * s), .color = text }),
                    // No wider than the widest notice has room for.
                    cx.make(kete.ConstrainedBox{ .constraints = .{ .max_w = (max_width - 2 * pad - icon_size - icon_gap) * s }, .child = cx.make(kete.Column{ .fill = false, .spacing = @round(2 * s), .children = lines.items }) }),
                }) catch &.{},
            }) }) }),
        });
    }
};

const testing = std.testing;

test "a notice fades in, stays, fades out, and is gone; a new one takes its place" {
    const kit = try kete_panel.Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    const panel = try kit.panel();
    defer panel.destroy();
    var n = try Notice.init(testing.allocator, panel, 1920, 1);
    defer n.deinit(testing.allocator);
    const ms = std.time.ns_per_ms;
    try testing.expect(!n.visible(0));
    try testing.expect(n.wakeAt(0) == null);

    n.show(.photo_camera, "Screenshot saved", "Screenshot 1.png", 1000 * ms);
    try testing.expectEqual(@as(u32, 320), n.width);
    try testing.expectEqual([2]i32{ (1920 - 320) / 2, 16 }, n.place());
    // Fading in: a frame each refresh.
    try testing.expect(n.visible(1000 * ms));
    try testing.expectEqual(@as(?u64, 1050 * ms), n.wakeAt(1050 * ms));
    const half = n.frame(1075 * ms).?;
    const middle = (n.height / 2) * n.width + 4;
    try testing.expect(half[middle] >> 24 > 0 and half[middle] >> 24 < glass.alpha);
    // Staying: as it is, until it fades out.
    try testing.expectEqual(@as(u32, glass.alpha), n.frame(2000 * ms).?[middle] >> 24);
    try testing.expect(n.frame(3000 * ms) == null);
    try testing.expectEqual(@as(?u64, (1000 + 150 + 3000) * ms), n.wakeAt(3000 * ms));
    // Fading out, then gone.
    try testing.expect(n.frame(4350 * ms).?[middle] >> 24 < glass.alpha);
    try testing.expect(n.frame(4600 * ms) == null);
    try testing.expect(!n.visible(4600 * ms));
    try testing.expect(n.wakeAt(4600 * ms) == null);

    // Another, while one shows: in its place, from the start.
    n.show(.photo_camera, "One", "", 5000 * ms);
    n.show(.warning, "Two", "", 5100 * ms);
    try testing.expectEqual(@as(?u64, 5100 * ms), n.shown_ns);
    try testing.expectEqual(@as(f32, 1), n.opacityAt(5300 * ms));
    // A long line: as wide as it may be, and cut short.
    n.show(.warning, "Screenshot saved", "Saved as \u{201c}A screenshot with a very long name indeed, longer than the screen has room for.png\u{201d} in your files", 6000 * ms);
    try testing.expect(n.width > max_width - 20 and n.width <= max_width);
}
