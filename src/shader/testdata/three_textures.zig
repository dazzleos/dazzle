//! Three textures: red from the first, green from the second, blue from
//! the third (which shares texture unit 0 with the first).

const gpu = @import("gpu");

const pos = gpu.vertexInput(gpu.Vec2, 0);
const v_uv = gpu.vertexOutput(gpu.Vec2, 0);

export fn vertex() callconv(.spirv_vertex) void {
    gpu.position.* = .{ pos.*[0], pos.*[1], 0, 1 };
    v_uv.* = pos.*;
}

const uv = gpu.fragmentInput(gpu.Vec2, 0);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const a = gpu.texture(uv.*);
    const b = gpu.texture1(uv.*);
    const c = gpu.texture2(uv.*);
    gpu.color.* = .{ a[0], b[1], c[2], 1 };
}
