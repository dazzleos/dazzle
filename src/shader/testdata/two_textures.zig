//! Two textures: the colour from unit 0, scaled by unit 1's red.

const gpu = @import("gpu");

const pos = gpu.vertexInput(gpu.Vec2, 0);
const v_uv = gpu.vertexOutput(gpu.Vec2, 0);

export fn vertex() callconv(.spirv_vertex) void {
    gpu.position.* = .{ pos.*[0], pos.*[1], 0, 1 };
    v_uv.* = pos.*;
}

const uv = gpu.fragmentInput(gpu.Vec2, 0);

export fn fragment() callconv(.spirv_fragment) void {
    const a = gpu.texture(uv.*);
    const b = gpu.texture1(uv.*);
    gpu.color.* = .{ a[0] * b[0], a[1] * b[0], a[2] * b[0], 1 };
}
