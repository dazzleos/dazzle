//! Notifications: a short message at the top of the screen, in the middle,
//! in a see-through box like the dock's: an icon, a title and a line under
//! it. It fades in, stays a few seconds, and fades out; a new one takes
//! the place of the one showing. The first use: a screenshot was saved
//! (and where).

const std = @import("std");
const font = @import("font");
const icons = @import("icons");
const glass = @import("glass.zig");
const dock = @import("dock.zig");

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
    font: ?font.Font,
    icon_font: ?font.Font,
    cache: font.GlyphCache,
    /// Room for the widest it gets, three times: drawn over black (and
    /// then its picture, see-through), over white, and as it is shown,
    /// faded.
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

    pub fn init(gpa: std.mem.Allocator, f: ?font.Font, screen_width: u32, scale: f32) !Notice {
        const most = maxWidth(screen_width, scale);
        const height: u32 = @intFromFloat(@round(box_height * scale));
        return .{
            .font = f,
            .icon_font = font.Font.init(icons.font_data) catch null,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, 3 * @as(usize, most) * height),
            .height = height,
            .scale = scale,
            .screen_width = screen_width,
        };
    }

    pub fn deinit(n: *Notice, gpa: std.mem.Allocator) void {
        gpa.free(n.pixels);
        n.cache.deinit();
    }

    fn maxWidth(screen_width: u32, scale: f32) u32 {
        return @min(@as(u32, @intFromFloat(@round(max_width * scale))), screen_width);
    }

    /// Shows `title` and `body` beside `icon`, from `now`, in place of
    /// what showed.
    pub fn show(n: *Notice, icon: icons.Icon, title: []const u8, body: []const u8, now: u64) void {
        const s = n.scale;
        const title_style: ?font.Style = if (n.font) |*f| .{ .font = f, .size = @round(title_size * s), .color = 0 } else null;
        const body_style: ?font.Style = if (n.font) |*f| .{ .font = f, .size = @round(body_size * s), .color = 0 } else null;
        const text_w = if (title_style) |ts| @max(font.measure(ts, title), font.measure(body_style.?, body)) else 0;
        const want = 2 * pad * s + (icon_size + icon_gap) * s + text_w;
        n.width = std.math.clamp(@as(u32, @intFromFloat(@ceil(want))), @min(@as(u32, @intFromFloat(@round(min_width * s))), maxWidth(n.screen_width, s)), maxWidth(n.screen_width, s));
        const count = @as(usize, n.width) * n.height;
        const over_black: font.Canvas = .{ .pixels = n.pixels[0..count], .width = n.width, .height = n.height, .stride = n.width };
        const over_white: font.Canvas = .{ .pixels = n.pixels[count .. 2 * count], .width = n.width, .height = n.height, .stride = n.width };
        n.drawContents(over_black, glass.black, icon, title, body);
        n.drawContents(over_white, glass.white, icon, title, body);
        glass.compose(over_black.pixels, over_white.pixels, n.theme.colors().background);
        glass.cutCorners(over_black, @round(dock.Dock.box_radius * s));
        n.shown_ns = now;
        n.opacity = -1;
    }

    fn drawContents(n: *Notice, canvas: font.Canvas, base: u32, icon: icons.Icon, title: []const u8, body: []const u8) void {
        const s = n.scale;
        const c = n.theme.colors();
        canvas.fill(0, 0, n.width, n.height, base);
        const h: f32 = @floatFromInt(n.height);
        if (n.icon_font) |*f| {
            const size = @round(icon_size * s);
            var buf: [4]u8 = undefined;
            // Icons fill the em square, with the baseline at the bottom.
            _ = font.draw(canvas, &n.cache, .{ .font = f, .size = size, .color = c.dot }, @round(pad * s), @round((h - size) / 2) + size, icons.text(icon, &buf)) catch {};
        }
        const f = if (n.font) |*f| f else return;
        const x = @round((pad + icon_size + icon_gap) * s);
        const room = @as(f32, @floatFromInt(n.width)) - x - pad * s;
        const title_style: font.Style = .{ .font = f, .size = @round(title_size * s), .color = c.dot };
        const body_style: font.Style = .{ .font = f, .size = @round(body_size * s), .color = dimmed(c.dot) };
        var buf: [256]u8 = undefined;
        _ = font.draw(canvas, &n.cache, title_style, x, @round(h / 2 - 4 * s), fit(title_style, title, room, &buf)) catch {};
        _ = font.draw(canvas, &n.cache, body_style, x, @round(h / 2 + body_style.ascent() + 2 * s), fit(body_style, body, room, &buf)) catch {};
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
        const out = n.pixels[2 * count .. 3 * count];
        const a: u32 = @intFromFloat(@round(k * 256));
        for (out, src) |*o, p| o.* = (p & 0x00ffffff) | ((p >> 24) * a >> 8) << 24;
        return out;
    }

    /// Where it is on the screen: at the top, in the middle.
    pub fn place(n: *const Notice) [2]i32 {
        return .{ @divTrunc(@as(i32, @intCast(n.screen_width)) - @as(i32, @intCast(n.width)), 2), @intFromFloat(@round(top_margin * n.scale)) };
    }
};

/// The text colour, a little dimmer: for the line under the title.
fn dimmed(c: u32) u32 {
    return (c & 0x00ffffff) | 0xb8000000;
}

/// `text`, cut short with an ellipsis if it is wider than `room` (in
/// `buf`).
fn fit(style: font.Style, text: []const u8, room: f32, buf: []u8) []const u8 {
    if (font.measure(style, text) <= room) return text;
    var n = text.len;
    while (n > 0) {
        n -= 1;
        // Not in the middle of a character.
        if (n < text.len and text[n] & 0xc0 == 0x80) continue;
        const shown = std.fmt.bufPrint(buf, "{s}…", .{text[0..n]}) catch return text;
        if (font.measure(style, shown) <= room) return shown;
    }
    return "…";
}

const testing = std.testing;

test "a notice fades in, stays, fades out, and is gone; a new one takes its place" {
    var n = try Notice.init(testing.allocator, null, 1920, 1);
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
}

test "a long line is cut short with an ellipsis" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const style: font.Style = .{ .font = &f, .size = 15, .color = 0 };
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Short", fit(style, "Short", 200, &buf));
    const cut = fit(style, "Saved as a very long file name indeed.png", 120, &buf);
    try testing.expect(std.mem.endsWith(u8, cut, "…"));
    try testing.expect(font.measure(style, cut) <= 120);
}
