//! Expanding, fading rings where the pointer clicks, drawn behind the
//! cube with the 2D canvas.

const std = @import("std");
const gfx = @import("kete").gfx;

const max_rings = 32;

/// How long a ring takes to grow and fade away.
const lifetime = 500 * std.time.ns_per_ms;

const Ring = struct {
    center: gfx.Point,
    born: u64,
    color: gfx.Color,
};

pub const Rings = struct {
    rings: [max_rings]Ring = undefined,
    len: usize = 0,

    /// Starts a ring at (`x`, `y`) in window pixels.
    pub fn add(r: *Rings, now: u64, x: f32, y: f32, color: gfx.Color) void {
        // Full: the oldest goes.
        if (r.len == max_rings) {
            std.mem.copyForwards(Ring, r.rings[0 .. max_rings - 1], r.rings[1..max_rings]);
            r.len -= 1;
        }
        r.rings[r.len] = .{ .center = .{ x, y }, .born = now, .color = color };
        r.len += 1;
    }

    /// Draws the live rings.
    pub fn draw(r: *Rings, c: *gfx.Canvas, now: u64) void {
        var kept: usize = 0;
        for (r.rings[0..r.len]) |ring| {
            const age = now -| ring.born;
            if (age >= lifetime) continue;
            r.rings[kept] = ring;
            kept += 1;
            const t = @as(f32, @floatFromInt(age)) / @as(f32, @floatFromInt(lifetime));
            // Fast at first, slowing down; thinning and fading as it goes.
            const grow = 1 - (1 - t) * (1 - t);
            const radius = 4 + 36 * grow;
            const width = 3 * (1 - t) + 1;
            c.strokeCircle(ring.center, radius, width, ring.color.withAlpha(1 - t));
        }
        r.len = kept;
    }
};

test "rings expire, and the oldest makes way" {
    var c = gfx.Canvas.init(std.testing.allocator);
    defer c.deinit();
    var r: Rings = .{};
    for (0..max_rings + 5) |i| r.add(i, 10, 10, .rgb(0xffffff));
    try std.testing.expectEqual(@as(usize, max_rings), r.len);
    c.begin(100, 100);
    r.draw(&c, lifetime / 2);
    try std.testing.expectEqual(@as(usize, max_rings), r.len);
    try std.testing.expect(c.batches.items.len > 0);
    c.begin(100, 100);
    r.draw(&c, 2 * lifetime);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}
