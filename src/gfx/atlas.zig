//! Glyphs for drawing text with the GPU: rasterized on the CPU (by the
//! font renderer) into one texture, packed in rows ("shelves"), and kept
//! there while they fit. The renderer uploads the parts that changed.
//!
//! Each texel is the glyph's coverage, one byte: the texture is A8 (vc4's
//! ALPHA type, a quarter of the memory of 32-bit texels), and the text
//! shader takes the colour from the vertices.

const std = @import("std");
const font = @import("font");

pub const width = 1024;
pub const height = 512;

/// Where a glyph is in the atlas, and how it sits on the baseline.
pub const Entry = struct {
    x: u16,
    y: u16,
    /// Zero for glyphs with no ink (spaces).
    w: u16,
    h: u16,
    /// Offset of its top left from the pen position on the baseline.
    left: i16,
    top: i16,
};

const Key = struct {
    font: usize,
    glyph: u16,
    /// Pixels per em, in 1/64ths.
    size: u32,
    /// Horizontal offset in quarter pixels.
    subpixel: u2,
};

pub const Rect = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

pub const Atlas = struct {
    gpa: std.mem.Allocator,
    /// Coverage, rows of `width`.
    pixels: []u8,
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    /// Texels changed since the last upload.
    dirty: ?Rect = null,
    /// A glyph did not fit this frame (and was not drawn): the atlas starts
    /// again empty at the next frame.
    full: bool = false,
    /// The text drawn recently, laid out.
    runs: font.RunCache,

    pub fn init(gpa: std.mem.Allocator) !Atlas {
        const pixels = try gpa.alloc(u8, width * height);
        @memset(pixels, 0);
        return .{ .gpa = gpa, .pixels = pixels, .runs = .init(gpa) };
    }

    pub fn deinit(a: *Atlas) void {
        a.runs.deinit();
        a.map.deinit(a.gpa);
        a.gpa.free(a.pixels);
    }

    /// Call before recording a frame's text.
    pub fn beginFrame(a: *Atlas) void {
        a.runs.sweep();
        if (!a.full) return;
        a.map.clearRetainingCapacity();
        @memset(a.pixels, 0);
        a.shelf_x = 0;
        a.shelf_y = 0;
        a.shelf_h = 0;
        a.full = false;
        a.dirty = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height };
    }

    /// The glyph at `size` pixels per em shifted right by `subpixel`
    /// quarter pixels, rasterized into the atlas if it is not there yet;
    /// null if it does not fit (or cannot be rasterized).
    pub fn glyph(a: *Atlas, f: *const font.Font, index: u16, size: f32, subpixel: u2) ?Entry {
        const key: Key = .{ .font = @intFromPtr(f), .glyph = index, .size = @intFromFloat(@max(size, 0) * 64), .subpixel = subpixel };
        if (a.map.get(key)) |e| return e;
        if (a.full) return null;
        const b = font.rasterizeGlyph(a.gpa, f, index, size, @as(f32, @floatFromInt(subpixel)) / 4) catch return null;
        defer a.gpa.free(b.mask);
        var e: Entry = .{ .x = 0, .y = 0, .w = 0, .h = 0, .left = @intCast(std.math.clamp(b.left, -32768, 32767)), .top = @intCast(std.math.clamp(b.top, -32768, 32767)) };
        if (b.width > 0 and b.height > 0) {
            // A texel of space around each, so nothing bleeds in.
            const w = b.width + 1;
            const h = b.height + 1;
            if (w > width or h > height) return a.fail();
            if (a.shelf_x + w > width) {
                a.shelf_y += a.shelf_h;
                a.shelf_x = 0;
                a.shelf_h = 0;
            }
            if (a.shelf_y + h > height) return a.fail();
            e.x = @intCast(a.shelf_x);
            e.y = @intCast(a.shelf_y);
            e.w = @intCast(b.width);
            e.h = @intCast(b.height);
            for (0..b.height) |row| {
                @memcpy(a.pixels[(a.shelf_y + row) * width + a.shelf_x ..][0..b.width], b.mask[row * b.width ..][0..b.width]);
            }
            a.markDirty(.{ .x0 = a.shelf_x, .y0 = a.shelf_y, .x1 = a.shelf_x + b.width, .y1 = a.shelf_y + b.height });
            a.shelf_x += w;
            a.shelf_h = @max(a.shelf_h, h);
        }
        a.map.put(a.gpa, key, e) catch return null;
        return e;
    }

    fn fail(a: *Atlas) ?Entry {
        a.full = true;
        return null;
    }

    fn markDirty(a: *Atlas, r: Rect) void {
        a.dirty = if (a.dirty) |d| .{ .x0 = @min(d.x0, r.x0), .y0 = @min(d.y0, r.y0), .x1 = @max(d.x1, r.x1), .y1 = @max(d.y1, r.y1) } else r;
    }
};

const testing = std.testing;

test "glyphs are packed once, and a full atlas starts again" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    var a = try Atlas.init(testing.allocator);
    defer a.deinit();
    const e = a.glyph(&f, f.glyphIndex('A'), 32, 0).?;
    try testing.expect(e.w > 10 and e.h > 10);
    try testing.expectEqual(e, a.glyph(&f, f.glyphIndex('A'), 32, 0).?);
    // Its coverage is there.
    var ink: u32 = 0;
    for (0..e.h) |y| for (0..e.w) |x| {
        ink += a.pixels[(e.y + y) * width + e.x + x];
    };
    try testing.expect(ink > 255 * 50);
    try testing.expect(a.dirty != null);
    // Spaces take no room.
    try testing.expectEqual(@as(u16, 0), a.glyph(&f, f.glyphIndex(' '), 32, 0).?.w);
    // Huge glyphs fill it up: later ones are refused until the next frame.
    var n: u16 = 1;
    while (a.glyph(&f, n, 300, 0) != null) n += 1;
    try testing.expect(a.full);
    a.beginFrame();
    try testing.expect(!a.full);
    try testing.expect(a.glyph(&f, f.glyphIndex('A'), 32, 0) != null);
}
