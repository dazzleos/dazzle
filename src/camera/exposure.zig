//! Automatic exposure, for sensors that have none of their own (the
//! IMX219; the OV5647 has its own, which the app turns on instead): from
//! each frame's green mean, longer or shorter exposures, then more or less
//! analogue gain when the exposure is as long as the frame allows.
//!
//! Settings take effect a frame or two after they are made, so it changes
//! them only every `settle` frames, and only part of the way at a time
//! (the square root of the change wanted), so it does not overshoot.

const std = @import("std");

/// The mean, linear, the picture aims for: a mid grey.
pub const target: f32 = 0.18;
/// Frames between changes.
pub const settle = 3;

/// How a sensor's analogue gain control maps to its gain.
pub const GainModel = enum {
    /// The IMX219's: code c gives 256 / (256 - c).
    imx219,

    pub fn gain(m: GainModel, c: i32) f32 {
        return switch (m) {
            .imx219 => 256.0 / (256.0 - @as(f32, @floatFromInt(c))),
        };
    }

    pub fn code(m: GainModel, g: f32) i32 {
        return switch (m) {
            .imx219 => @intFromFloat(@round(256.0 - 256.0 / @max(g, 1))),
        };
    }
};

pub const Settings = struct { lines: i32, gain_code: i32 };

pub const Limits = struct {
    min_lines: i32,
    max_lines: i32,
    min_gain_code: i32,
    max_gain_code: i32,
};

pub const Exposure = struct {
    model: GainModel,
    current: Settings,
    frames: u32 = 0,

    /// The settings for the frame whose green mean (linear, 0 to 1) is
    /// `mean`; null if they stay as they are.
    pub fn update(e: *Exposure, mean: f32, limits: Limits) ?Settings {
        e.frames += 1;
        if (e.frames < settle) return null;
        e.frames = 0;
        const ratio = target / @max(mean, 0.001);
        // Near enough.
        if (ratio > 0.9 and ratio < 1.1) return null;
        const step = @sqrt(std.math.clamp(ratio, 1.0 / 16.0, 16));
        const gain = e.model.gain(e.current.gain_code);
        const total = @as(f32, @floatFromInt(e.current.lines)) * gain * step;
        const max_lines: f32 = @floatFromInt(limits.max_lines);
        const lines = std.math.clamp(total, @as(f32, @floatFromInt(limits.min_lines)), max_lines);
        const max_gain = e.model.gain(limits.max_gain_code);
        const new: Settings = .{
            .lines = @intFromFloat(@round(lines)),
            .gain_code = std.math.clamp(e.model.code(std.math.clamp(total / lines, 1, max_gain)), limits.min_gain_code, limits.max_gain_code),
        };
        if (std.meta.eql(new, e.current)) return null;
        e.current = new;
        return new;
    }
};

const testing = std.testing;

test "the IMX219's gain codes" {
    try testing.expectEqual(@as(f32, 1), GainModel.imx219.gain(0));
    try testing.expectEqual(@as(f32, 2), GainModel.imx219.gain(128));
    try testing.expectEqual(@as(i32, 128), GainModel.imx219.code(2));
    try testing.expectEqual(@as(i32, 0), GainModel.imx219.code(0.5));
}

/// A scene whose green mean is `brightness` times the exposure (lines
/// times gain), as a sensor would see it.
fn settleOn(e: *Exposure, brightness: f32, limits: Limits, frames: usize) void {
    for (0..frames) |_| {
        const mean = @min(brightness * @as(f32, @floatFromInt(e.current.lines)) * e.model.gain(e.current.gain_code), 1);
        _ = e.update(mean, limits);
    }
}

test "exposure finds the target: longer first, then gain" {
    const limits: Limits = .{ .min_lines = 4, .max_lines = 1700, .min_gain_code = 0, .max_gain_code = 232 };
    // A bright scene: the exposure shortens, without gain.
    var e: Exposure = .{ .model = .imx219, .current = .{ .lines = 1000, .gain_code = 0 } };
    settleOn(&e, 0.001, limits, 100);
    try testing.expectApproxEqRel(target, 0.001 * @as(f32, @floatFromInt(e.current.lines)), 0.1);
    try testing.expectEqual(@as(i32, 0), e.current.gain_code);
    // A dark one: the longest exposure, and gain.
    settleOn(&e, 0.00002, limits, 200);
    try testing.expectEqual(@as(i32, 1700), e.current.lines);
    try testing.expect(e.current.gain_code > 0);
    try testing.expectApproxEqRel(target, 0.00002 * 1700 * GainModel.imx219.gain(e.current.gain_code), 0.1);
    // Too dark for it: as much as there is.
    settleOn(&e, 0.0000001, limits, 200);
    try testing.expectEqual(@as(i32, 232), e.current.gain_code);
}
