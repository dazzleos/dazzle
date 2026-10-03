//! The spinning cube: textured, tinted, depth-tested and back-face culled.

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const Uniforms = extern struct {
    /// Model, view and projection, column-major.
    mvp: [4]Vec4,
};
const u = gpu.uniforms(Uniforms);

const in_pos = gpu.vertexInput(Vec3, 0);
const in_uv = gpu.vertexInput(Vec2, 1);
const in_tint = gpu.vertexInput(Vec3, 2);
const v_uv = gpu.vertexOutput(Vec2, 0);
const v_tint = gpu.vertexOutput(Vec3, 1);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];
    v_uv.* = in_uv.*;
    v_tint.* = in_tint.*;
}

const f_uv = gpu.fragmentInput(Vec2, 0);
const f_tint = gpu.fragmentInput(Vec3, 1);

export fn fragment() callconv(.spirv_fragment) void {
    const t = gpu.texture(f_uv.*);
    const tint = f_tint.*;
    gpu.color.* = .{ t[0] * tint[0], t[1] * tint[1], t[2] * tint[2], 1 };
}
