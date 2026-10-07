//! A window in RGB565: a texture drawn as it is, but for its red and blue.
//! The texture unit returns an RGB565 texel red first, and the tile buffer
//! wants blue first (as 32-bit textures come), so they are swapped back.
//! RGB565 has no alpha: the window is opaque.

const gpu = @import("gpu");

const in_pos = gpu.vertexInput(gpu.Vec2, 0);
const in_uv = gpu.vertexInput(gpu.Vec2, 1);
const v_uv = gpu.vertexOutput(gpu.Vec2, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    v_uv.* = in_uv.*;
}

const f_uv = gpu.fragmentInput(gpu.Vec2, 0);

export fn fragment() callconv(.spirv_fragment) void {
    const t = gpu.texture(f_uv.*);
    gpu.color.* = .{ t[2], t[1], t[0], 1 };
}
