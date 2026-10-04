//! A loop whose number of iterations depends on the fragment, which
//! cannot be unrolled: the shader tests check it is reported.

const gpu = @import("gpu");

const in_pos = gpu.vertexInput(gpu.Vec2, 0);
const out_x = gpu.vertexOutput(f32, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    out_x.* = p[0];
}

const in_x = gpu.fragmentInput(f32, 0);

export fn fragment() callconv(.spirv_fragment) void {
    var x: f32 = 0;
    while (x < in_x.*) x += 0.25;
    gpu.color.* = .{ x, 0, 0, 1 };
}
