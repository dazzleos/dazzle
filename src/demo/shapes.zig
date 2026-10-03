//! A showcase of the 2D canvas in Material 3's shapes and colours: a card
//! with buttons, floating action buttons, chips, text fields, selection
//! controls, polygons, strokes and translucent circles.

const std = @import("std");
const gfx = @import("gfx");

const Color = gfx.Color;

/// The area it takes, in pixels.
pub const size = [2]f32{ 560, 500 };

// Material 3 baseline (light) colours.
const surface = Color.rgb(0xfef7ff);
const surface_low = Color.rgb(0xf7f2fa);
const primary = Color.rgb(0x6750a4);
const on_primary = Color.rgb(0xffffff);
const primary_container = Color.rgb(0xeaddff);
const on_primary_container = Color.rgb(0x21005d);
const secondary_container = Color.rgb(0xe8def8);
const tertiary = Color.rgb(0x7d5260);
const outline = Color.rgb(0x79747e);
const outline_variant = Color.rgb(0xcac4d0);
const on_surface = Color.rgb(0x1d1b20);
const err = Color.rgb(0xb3261e);

/// Draws it with its top left corner at `origin`.
pub fn draw(c: *gfx.Canvas, origin: gfx.Point) void {
    c.setOrigin(origin);
    defer c.setOrigin(.{ 0, 0 });
    c.fillRoundedRect(.{ .x = 0, .y = 0, .w = size[0], .h = size[1] }, .all(28), surface);

    // An elevated card: a soft shadow, then the card, with content
    // placeholders and filled, tonal and outlined buttons.
    c.fillRoundedRect(.{ .x = 16, .y = 19, .w = 344, .h = 184 }, .all(13), Color.rgb(0).withAlpha(0.06));
    c.fillRoundedRect(.{ .x = 16, .y = 17, .w = 344, .h = 184 }, .all(12), Color.rgb(0).withAlpha(0.10));
    c.fillRoundedRect(.{ .x = 16, .y = 16, .w = 344, .h = 184 }, .all(12), surface_low);
    c.fillCircle(.{ 60, 60 }, 28, primary_container);
    c.fillRoundedRect(.{ .x = 104, .y = 40, .w = 200, .h = 14 }, .all(7), outline_variant);
    c.fillRoundedRect(.{ .x = 104, .y = 64, .w = 140, .h = 14 }, .all(7), outline_variant);
    c.fillRect(.{ .x = 32, .y = 104, .w = 312, .h = 1 }, outline_variant);
    c.fillRoundedRect(.{ .x = 32, .y = 144, .w = 96, .h = 40 }, .all(20), primary);
    c.fillRoundedRect(.{ .x = 140, .y = 144, .w = 96, .h = 40 }, .all(20), secondary_container);
    c.strokeRoundedRect(.{ .x = 248, .y = 144, .w = 96, .h = 40 }, .all(20), 1, outline);

    // Floating action buttons: large (with a plus), regular, small.
    c.fillRoundedRect(.{ .x = 384, .y = 16, .w = 96, .h = 96 }, .all(28), primary_container);
    c.fillPolygon(&.{ .{ 429, 44 }, .{ 435, 44 }, .{ 435, 61 }, .{ 452, 61 }, .{ 452, 67 }, .{ 435, 67 }, .{ 435, 84 }, .{ 429, 84 }, .{ 429, 67 }, .{ 412, 67 }, .{ 412, 61 }, .{ 429, 61 } }, on_primary_container);
    c.fillRoundedRect(.{ .x = 384, .y = 128, .w = 56, .h = 56 }, .all(16), primary_container);
    c.fillRoundedRect(.{ .x = 456, .y = 136, .w = 40, .h = 40 }, .all(12), primary_container);

    // Chips and text fields.
    c.strokeRoundedRect(.{ .x = 16, .y = 224, .w = 88, .h = 32 }, .all(8), 1, outline);
    c.fillRoundedRect(.{ .x = 116, .y = 224, .w = 88, .h = 32 }, .all(8), secondary_container);
    c.strokeRoundedRect(.{ .x = 216, .y = 224, .w = 88, .h = 32 }, .all(8), 1, outline);
    c.strokeRoundedRect(.{ .x = 320, .y = 212, .w = 104, .h = 56 }, .all(4), 1, outline);
    c.strokeRoundedRect(.{ .x = 436, .y = 212, .w = 108, .h = 56 }, .all(4), 2, primary);

    // Selection controls: switches, radio buttons, checkboxes, a slider.
    c.fillRoundedRect(.{ .x = 16, .y = 288, .w = 52, .h = 32 }, .all(16), primary);
    c.fillCircle(.{ 52, 304 }, 12, on_primary);
    c.fillRoundedRect(.{ .x = 80, .y = 288, .w = 52, .h = 32 }, .all(16), Color.rgb(0xe6e0e9));
    c.strokeRoundedRect(.{ .x = 80, .y = 288, .w = 52, .h = 32 }, .all(16), 2, outline);
    c.fillCircle(.{ 96, 304 }, 8, outline);
    c.strokeCircle(.{ 164, 304 }, 10, 2, primary);
    c.fillCircle(.{ 164, 304 }, 5, primary);
    c.strokeCircle(.{ 196, 304 }, 10, 2, outline);
    c.fillRoundedRect(.{ .x = 219, .y = 295, .w = 18, .h = 18 }, .all(2), primary);
    c.strokePolyline(&.{ .{ 223, 304 }, .{ 227, 308 }, .{ 234, 299 } }, false, 2, on_primary);
    c.strokeRoundedRect(.{ .x = 251, .y = 295, .w = 18, .h = 18 }, .all(2), 2, outline);
    c.fillRoundedRect(.{ .x = 288, .y = 296, .w = 120, .h = 16 }, .{ .tl = 8, .bl = 8, .tr = 2, .br = 2 }, primary);
    c.fillRoundedRect(.{ .x = 420, .y = 296, .w = 124, .h = 16 }, .{ .tl = 2, .bl = 2, .tr = 8, .br = 8 }, secondary_container);
    c.fillRoundedRect(.{ .x = 411, .y = 284, .w = 4, .h = 40 }, .all(2), primary);

    // Polygons: a concave star; a hexagon with an outline.
    var star: [10]gfx.Point = undefined;
    for (&star, 0..) |*p, i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.pi / 5.0 - std.math.pi / 2.0;
        const r: f32 = if (i % 2 == 0) 48 else 20;
        p.* = .{ 64 + r * @cos(a), 412 + r * @sin(a) };
    }
    c.fillPolygon(&star, tertiary);
    var hex: [6]gfx.Point = undefined;
    for (&hex, 0..) |*p, i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.pi / 3.0;
        p.* = .{ 170 + 40 * @cos(a), 412 + 40 * @sin(a) };
    }
    c.fillPolygon(&hex, primary_container);
    c.strokePolyline(&hex, true, 3, primary);

    // A line chart, and a 1-pixel line and a hairline.
    c.strokePolyline(&.{ .{ 230, 460 }, .{ 260, 380 }, .{ 290, 420 }, .{ 320, 360 }, .{ 350, 440 } }, false, 3, err);
    c.strokePolyline(&.{ .{ 230, 476 }, .{ 350, 466 } }, false, 1, on_surface);
    c.strokePolyline(&.{ .{ 230, 488 }, .{ 350, 478 } }, false, 0.5, on_surface);

    // Translucent circles over each other.
    c.fillCircle(.{ 420, 392 }, 44, primary.withAlpha(0.5));
    c.fillCircle(.{ 480, 392 }, 44, tertiary.withAlpha(0.5));
    c.fillCircle(.{ 450, 440 }, 44, Color.rgb(0x386a20).withAlpha(0.5));
}

test "the showcase records" {
    var c = gfx.Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(1920, 1036);
    draw(&c, .{ 24, 400 });
    try std.testing.expect(!c.failed);
    try std.testing.expect(c.batches.items.len > 0);
}
