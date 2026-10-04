//! The bar across the top of the screen: the front window's title (or
//! "Stardust" when no app is open) and, while there is a window, a button
//! that closes it.

const std = @import("std");
const font = @import("font");
const dock = @import("dock.zig");

pub const background = 0xff1c2a4a;
const hover_background = 0xff2c3e66;
const title_color = 0xffe8eefc;
const close_color = 0xffb8c4dc;

/// The title when no app is open.
pub const no_window_title = "Stardust";

pub const Bar = struct {
    font: font.Font,
    cache: font.GlyphCache,
    pixels: []u32,
    width: u32,
    height: u32,
    scale: f32,
    /// Whether the close button is shown, and under the pointer.
    closable: bool = false,
    close_hover: bool = false,

    pub fn init(gpa: std.mem.Allocator, f: font.Font, screen_width: u32, screen_height: u32) !Bar {
        const scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        const height: u32 = @intFromFloat(@round(44 * scale));
        return .{
            .font = f,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, @as(usize, screen_width) * height),
            .width = screen_width,
            .height = height,
            .scale = scale,
        };
    }

    /// Where the close button is: a square at the right end.
    pub fn closeRect(b: *const Bar) struct { x: f32, y: f32, size: f32 } {
        const size = 34 * b.scale;
        const h: f32 = @floatFromInt(b.height);
        return .{ .x = @as(f32, @floatFromInt(b.width)) - size - 8 * b.scale, .y = (h - size) / 2, .size = size };
    }

    /// Whether (`x`, `y`) is on the close button (when it is shown).
    pub fn hitClose(b: *const Bar, x: f64, y: f64) bool {
        if (!b.closable) return false;
        const r = b.closeRect();
        return x >= r.x and x < r.x + r.size and y >= r.y and y < r.y + r.size;
    }

    /// Moves the close button's highlight for the pointer at (`x`, `y`)
    /// (null: off the bar). Returns whether it changed.
    pub fn pointerAt(b: *Bar, x: ?f64, y: f64) bool {
        const over = if (x) |px| b.hitClose(px, y) else false;
        if (over == b.close_hover) return false;
        b.close_hover = over;
        return true;
    }

    /// Draws the bar for a window with this title, or for no window.
    pub fn draw(b: *Bar, window_title: ?[]const u8) void {
        b.closable = window_title != null;
        if (!b.closable) b.close_hover = false;
        const canvas: font.Canvas = .{ .pixels = b.pixels, .width = b.width, .height = b.height, .stride = b.width };
        canvas.fill(0, 0, b.width, b.height, background);
        const s = b.scale;
        const w: f32 = @floatFromInt(b.width);
        const title = window_title orelse no_window_title;
        const style: font.Style = .{ .font = &b.font, .size = 22 * s, .color = title_color };
        _ = font.draw(canvas, &b.cache, style, (w - font.measure(style, title)) / 2, 29 * s, title) catch {};
        if (b.closable) {
            const r = b.closeRect();
            if (b.close_hover) dock.roundedRect(canvas, r.x, r.y, r.size, r.size, r.size / 2, hover_background);
            const cross: font.Style = .{ .font = &b.font, .size = 30 * s, .color = close_color };
            const glyph = "×";
            _ = font.draw(canvas, &b.cache, cross, r.x + (r.size - font.measure(cross, glyph)) / 2, r.y + r.size / 2 + cross.ascent() * 0.33, glyph) catch {};
        }
    }
};

const testing = std.testing;

test "the close button shows only for a window, and clicks find it" {
    var b: Bar = .{ .font = undefined, .cache = font.GlyphCache.init(testing.allocator), .pixels = &.{}, .width = 1920, .height = 44, .scale = 1 };
    defer b.cache.deinit();
    const r = b.closeRect();
    try testing.expect(!b.hitClose(r.x + 5, r.y + 5));
    b.closable = true;
    try testing.expect(b.hitClose(r.x + 5, r.y + 5));
    try testing.expect(!b.hitClose(r.x - 5, r.y + 5));
    try testing.expect(r.x + r.size < 1920);
    try testing.expect(b.pointerAt(r.x + 5, r.y + 5));
    try testing.expect(!b.pointerAt(r.x + 6, r.y + 6));
    try testing.expect(b.pointerAt(null, 0));
}
