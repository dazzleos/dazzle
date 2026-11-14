//! A rounded window's corners and shadow (see render.zig): the parts of it
//! drawn blended, around the rest of it, drawn as it is with quad.zig.
//!
//! The quad's texture coordinates run from 0 to 1 across the window (and
//! beyond it, in the shadow around it), so the fragment's place in the
//! window follows from them and the window's size. Its coverage by the
//! window's rounded outline cuts the corners; outside it, the shadow: the
//! same outline a little lower, fading over `blur` pixels.

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec4 = gpu.Vec4;

const Uniforms = extern struct {
    /// The window's half width and height on the screen, and its corners'
    /// radius.
    shape: Vec4,
    /// The shadow's opacity (0 for none), how far it fades, and how far
    /// down it is.
    shadow: Vec4,
};
const u = gpu.uniforms(Uniforms);

const in_pos = gpu.vertexInput(Vec2, 0);
const in_uv = gpu.vertexInput(Vec2, 1);
const v_uv = gpu.vertexOutput(Vec2, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    v_uv.* = in_uv.*;
}

const f_uv = gpu.fragmentInput(Vec2, 0);

/// Signed distance from `p` (from the centre) to a rounded box (negative
/// inside).
fn roundedBox(p: Vec2, half: Vec2, radius: f32) f32 {
    const q = @abs(p) - (half - gpu.splat2(radius));
    const m = @max(q, gpu.splat2(0));
    return @sqrt(m[0] * m[0] + m[1] * m[1]) + @min(@max(q[0], q[1]), 0) - radius;
}

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const uv = f_uv.*;
    const half = Vec2{ u.shape[0], u.shape[1] };
    const radius = u.shape[2];
    const p = (uv - gpu.splat2(0.5)) * half * gpu.splat2(2);

    // The window, its corners cut, over one pixel.
    const cover = gpu.clamp(0.5 - roundedBox(p, half, radius), 0, 1);

    // The shadow: full under the window, gone `blur` pixels from it.
    const blur = u.shadow[1];
    const t = gpu.clamp(roundedBox(p - Vec2{ 0, u.shadow[2] }, half, radius) / blur, 0, 1);
    const shade = u.shadow[0] * (1 - t * t * (3 - 2 * t));

    // The window over its shadow (black), as one colour over what is
    // behind.
    const alpha = cover + shade * (1 - cover);
    const c = gpu.texture(uv);
    const k = cover / @max(alpha, 0.0001);
    gpu.color.* = .{ c[0] * k, c[1] * k, c[2] * k, alpha };
}
