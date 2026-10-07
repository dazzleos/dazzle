//! The spinning polyhedron: tinted faces, optionally lit (from a fixed
//! light, with flat normals) and textured; depth-tested and back-face
//! culled.

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const Uniforms = extern struct {
    /// Model, view and projection, column-major.
    mvp: [4]Vec4,
    /// The model's rotation (its columns; w is unused), for the normals.
    rotation: [3]Vec4,
    /// x: lighting on (1) or off (0); y: texturing on (1) or off (0).
    options: Vec4,
};
const u = gpu.uniforms(Uniforms);

/// Towards the light (up, left and in front), normalized.
const light = Vec3{ -0.35, 0.55, 0.76 };
/// Light that reaches faces turned away from it.
const ambient = 0.3;

const in_pos = gpu.vertexInput(Vec3, 0);
const in_uv = gpu.vertexInput(Vec2, 1);
const in_tint = gpu.vertexInput(Vec3, 2);
const in_normal = gpu.vertexInput(Vec3, 3);
const v_uv = gpu.vertexOutput(Vec2, 0);
const v_tint = gpu.vertexOutput(Vec3, 1);
const v_shade = gpu.vertexOutput(f32, 2);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];
    const r = u.rotation;
    const n0 = in_normal.*;
    const n = r[0] * gpu.splat4(n0[0]) + r[1] * gpu.splat4(n0[1]) + r[2] * gpu.splat4(n0[2]);
    const diffuse = @max(n[0] * light[0] + n[1] * light[1] + n[2] * light[2], 0);
    const lit = ambient + (1 - ambient) * diffuse;
    // Unlit: full brightness.
    v_shade.* = 1 + (lit - 1) * u.options[0];
    v_uv.* = in_uv.*;
    v_tint.* = in_tint.*;
}

const f_uv = gpu.fragmentInput(Vec2, 0);
const f_tint = gpu.fragmentInput(Vec3, 1);
const f_shade = gpu.fragmentInput(f32, 2);

export fn fragment() callconv(.spirv_fragment) void {
    const t = gpu.texture(f_uv.*);
    const k = u.options[1];
    const tint = f_tint.*;
    const shade = f_shade.*;
    // Untextured: white.
    gpu.color.* = .{
        (1 + (t[0] - 1) * k) * tint[0] * shade,
        (1 + (t[1] - 1) * k) * tint[1] * shade,
        (1 + (t[2] - 1) * k) * tint[2] * shade,
        1,
    };
}
