//! Control flow in a shader, for the shader tests: each fragment takes its
//! own way through it, depending on its input.

const gpu = @import("gpu");

const in_pos = gpu.vertexInput(gpu.Vec2, 0);
const out_v = gpu.vertexOutput(gpu.Vec4, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    out_v.* = .{ p[0], p[1], 0, 1 };
}

const in_v = gpu.fragmentInput(gpu.Vec4, 0);

/// Early returns.
fn band(x: f32) f32 {
    if (x < 0.25) return 0;
    if (x < 0.5) return 0.25;
    if (x >= 0.75) return 1;
    return 0.5;
}

const weights = [_]f32{ 0.5, 0.25, 0.125 };

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const c = in_v.*;

    var r = c[0];
    if (c[1] < 0.25) {
        r = 1;
    } else if (c[1] < 0.5) {
        r *= 0.5;
    } else if (c[1] == 0.5) {
        r = 0.75;
    } else {
        r = 0;
    }

    const g = band(if (c[2] >= c[3]) c[2] else c[3]);

    // A loop known when compiled, with a break that is not.
    var steps: f32 = 0;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        if (c[0] + @as(f32, @floatFromInt(i)) * 0.25 > 1) break;
        steps += 0.125;
    }
    var sum: f32 = 0;
    for (weights) |w| sum += w * c[1];

    const k: u32 = @intFromFloat(c[3] * 3);
    const pick: f32 = switch (k) {
        0 => 0.25,
        1 => 0.5,
        else => 0.125,
    };

    const sel = @select(f32, c > gpu.splat4(0.5), gpu.splat4(0.25), gpu.splat4(0));
    gpu.color.* = .{ r, g, steps + sum * 0.5, pick + sel[2] + sel[3] };
}
