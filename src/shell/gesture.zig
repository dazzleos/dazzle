//! The shell's touch gestures: four fingers swiped (any way) show the
//! overview, or end it, as Super does.
//!
//! Every touch goes past `Gestures` first. Once a fourth finger is down
//! with three others the touches are the shell's (`began`: the shell tells
//! the apps theirs are cancelled), and so is any other that goes down,
//! until they are all up. When they have moved far enough together (on
//! average), that is a swipe, once.

const std = @import("std");

pub const fingers = 4;

pub const Gestures = struct {
    touches: [10]?Touch = @splat(null),
    /// Four fingers went down together: the touches are the shell's until
    /// none is down.
    active: bool = false,
    /// It has swiped (once a gesture).
    swiped: bool = false,
    /// How far (on average, in pixels) they move to swipe.
    distance: f64 = 60,

    const Touch = struct { id: i32, from: [2]f64, at: [2]f64 };

    pub const Outcome = enum {
        /// Not the shell's: as ever.
        none,
        /// The shell's (part of a gesture): nothing else is done with it.
        taken,
        /// The fourth finger: the gesture begins (the apps' touches are
        /// to be cancelled).
        began,
        /// The fingers swiped.
        swipe,
    };

    pub fn down(g: *Gestures, id: i32, x: f64, y: f64) Outcome {
        for (&g.touches) |*slot| if (slot.* == null) {
            slot.* = .{ .id = id, .from = .{ x, y }, .at = .{ x, y } };
            break;
        };
        if (g.active) return .taken;
        if (g.count() < fingers) return .none;
        g.active = true;
        g.swiped = false;
        // From where they are now.
        for (&g.touches) |*slot| if (slot.*) |*t| {
            t.from = t.at;
        };
        return .began;
    }

    pub fn motion(g: *Gestures, id: i32, x: f64, y: f64) Outcome {
        const t = g.find(id) orelse return if (g.active) .taken else .none;
        t.at = .{ x, y };
        if (!g.active) return .none;
        if (g.swiped) return .taken;
        // How far they have moved together, on average.
        var sum: [2]f64 = .{ 0, 0 };
        var n: f64 = 0;
        for (g.touches) |slot| if (slot) |o| {
            sum[0] += o.at[0] - o.from[0];
            sum[1] += o.at[1] - o.from[1];
            n += 1;
        };
        const dx = sum[0] / n;
        const dy = sum[1] / n;
        if (dx * dx + dy * dy < g.distance * g.distance) return .taken;
        g.swiped = true;
        return .swipe;
    }

    pub fn up(g: *Gestures, id: i32) Outcome {
        const was_active = g.active;
        for (&g.touches) |*slot| if (slot.*) |t| if (t.id == id) {
            slot.* = null;
        };
        if (g.count() == 0) {
            g.active = false;
            g.swiped = false;
        }
        return if (was_active) .taken else .none;
    }

    fn count(g: *const Gestures) usize {
        var n: usize = 0;
        for (g.touches) |slot| n += @intFromBool(slot != null);
        return n;
    }

    fn find(g: *Gestures, id: i32) ?*Touch {
        for (&g.touches) |*slot| if (slot.*) |*t| if (t.id == id) return t;
        return null;
    }
};

const testing = std.testing;

test "four fingers swiped: once, and their touches are the shell's until all are up" {
    var g: Gestures = .{ .distance = 90 };
    try testing.expectEqual(Gestures.Outcome.none, g.down(1, 100, 500));
    try testing.expectEqual(Gestures.Outcome.none, g.down(2, 200, 500));
    try testing.expectEqual(Gestures.Outcome.none, g.motion(2, 200, 490));
    try testing.expectEqual(Gestures.Outcome.none, g.down(3, 300, 500));
    try testing.expectEqual(Gestures.Outcome.began, g.down(4, 400, 500));
    // Up together, a little: not yet.
    for ([_]i32{ 1, 2, 3, 4 }, 0..) |id, i| try testing.expectEqual(Gestures.Outcome.taken, g.motion(id, @floatFromInt(100 * (i + 1)), 470));
    // Further: a swipe, once.
    try testing.expectEqual(Gestures.Outcome.taken, g.motion(1, 100, 400));
    try testing.expectEqual(Gestures.Outcome.taken, g.motion(2, 200, 400));
    try testing.expectEqual(Gestures.Outcome.taken, g.motion(3, 300, 400));
    try testing.expectEqual(Gestures.Outcome.swipe, g.motion(4, 400, 400));
    try testing.expectEqual(Gestures.Outcome.taken, g.motion(4, 400, 300));
    // A fifth finger meanwhile is the shell's too.
    try testing.expectEqual(Gestures.Outcome.taken, g.down(5, 500, 500));
    for ([_]i32{ 1, 2, 3, 4, 5 }) |id| try testing.expectEqual(Gestures.Outcome.taken, g.up(id));
    // After: as ever.
    try testing.expectEqual(Gestures.Outcome.none, g.down(6, 100, 100));
    try testing.expectEqual(Gestures.Outcome.none, g.motion(6, 100, 300));
    try testing.expectEqual(Gestures.Outcome.none, g.up(6));
}

test "three fingers moved are not a gesture" {
    var g: Gestures = .{};
    for ([_]i32{ 1, 2, 3 }) |id| try testing.expectEqual(Gestures.Outcome.none, g.down(id, 100, 500));
    for ([_]i32{ 1, 2, 3 }) |id| try testing.expectEqual(Gestures.Outcome.none, g.motion(id, 100, 100));
}
