//! What Dazzle's shaders, written in Zig and compiled to SPIR-V, import
//! as "gpu": vector types, inputs and outputs by location, the uniform
//! block, the position, and texture sampling.
//!
//! A program is one file with both entry points:
//!
//!     const gpu = @import("gpu");
//!
//!     const pos = gpu.vertexInput(gpu.Vec2, 0);
//!     const v_color = gpu.vertexOutput(gpu.Vec4, 0);
//!     export fn vertex() callconv(.spirv_vertex) void {
//!         gpu.position.* = .{ pos.*[0], pos.*[1], 0, 1 };
//!         v_color.* = .{ 1, 0, 0, 1 };
//!     }
//!
//!     const color = gpu.fragmentInput(gpu.Vec4, 0);
//!     export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
//!         gpu.color.* = color.*;
//!     }
//!
//! Comparisons, `if`, `switch`, `@select` and loops work, by predication
//! (each of the 16 lanes takes its own way, and both sides of an `if` run
//! when they differ). Loops are unrolled, so they must stop after a number
//! of iterations known when the shader is compiled; a `break` that depends
//! on the data is fine. The fragment's colour is straight RGBA; blending
//! and depth testing are set when the program is built.

const std = @import("std");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

/// The vertex's position in clip space (vertex shaders write it).
pub const position = std.spirv.position_out;

/// The fragment's colour, straight (not premultiplied) RGBA.
pub const color = @extern(*addrspace(.output) Vec4, .{ .name = "dazzle_color", .decoration = .{ .location = 0 } });

// Names for the variables at each location. (Literals: names built with
// std.fmt.comptimePrint crashed Zig 0.16's SPIR-V backend.)
const max_locations = 8;
const vin_names = [max_locations][]const u8{ "dazzle_vin0", "dazzle_vin1", "dazzle_vin2", "dazzle_vin3", "dazzle_vin4", "dazzle_vin5", "dazzle_vin6", "dazzle_vin7" };
const vout_names = [max_locations][]const u8{ "dazzle_vout0", "dazzle_vout1", "dazzle_vout2", "dazzle_vout3", "dazzle_vout4", "dazzle_vout5", "dazzle_vout6", "dazzle_vout7" };
const fin_names = [max_locations][]const u8{ "dazzle_fin0", "dazzle_fin1", "dazzle_fin2", "dazzle_fin3", "dazzle_fin4", "dazzle_fin5", "dazzle_fin6", "dazzle_fin7" };

/// A vertex attribute.
pub fn vertexInput(comptime T: type, comptime location: u32) *addrspace(.input) T {
    return @extern(*addrspace(.input) T, .{ .name = vin_names[location], .decoration = .{ .location = location } });
}

/// A value passed to the fragment shader, interpolated across the triangle.
pub fn vertexOutput(comptime T: type, comptime location: u32) *addrspace(.output) T {
    return @extern(*addrspace(.output) T, .{ .name = vout_names[location], .decoration = .{ .location = location } });
}

/// What the vertex shader wrote with `vertexOutput` at this location.
pub fn fragmentInput(comptime T: type, comptime location: u32) *addrspace(.input) T {
    return @extern(*addrspace(.input) T, .{ .name = fin_names[location], .decoration = .{ .location = location } });
}

/// The program's uniforms: an extern struct the app sets for each draw.
pub fn uniforms(comptime T: type) *addrspace(.uniform) T {
    return @extern(*addrspace(.uniform) T, .{ .name = "dazzle_uniforms", .decoration = .{ .descriptor = .{ .binding = 0, .set = 0 } } });
}

/// Samples the draw's texture at `coord` (0 to 1 across it), as RGBA.
pub fn texture(coord: Vec2) Vec4 {
    return asm volatile (
        \\%f32 = OpTypeFloat 32
        \\%v4 = OpTypeVector %f32 4
        \\%img = OpTypeImage %f32 2D 0 0 0 1 Unknown
        \\%simg = OpTypeSampledImage %img
        \\%ptr = OpTypePointer UniformConstant %simg
        \\%tex = OpVariable %ptr UniformConstant
        \\%s = OpLoad %simg %tex
        \\%ret = OpImageSampleImplicitLod %v4 %s %coord
        : [ret] "" (-> Vec4),
        : [coord] "" (coord),
    );
}

/// Samples the draw's second texture (texture unit 1) at `coord`, as
/// RGBA. (Its variable is bound at 2: the uniforms are at 0, and unit 0's
/// texture is not bound.)
pub fn texture1(coord: Vec2) Vec4 {
    return asm volatile (
        \\%f32 = OpTypeFloat 32
        \\%v4 = OpTypeVector %f32 4
        \\%img = OpTypeImage %f32 2D 0 0 0 1 Unknown
        \\%simg = OpTypeSampledImage %img
        \\%ptr = OpTypePointer UniformConstant %simg
        \\%tex = OpVariable %ptr UniformConstant
        \\OpDecorate %tex DescriptorSet 0
        \\OpDecorate %tex Binding 2
        \\%s = OpLoad %simg %tex
        \\%ret = OpImageSampleImplicitLod %v4 %s %coord
        : [ret] "" (-> Vec4),
        : [coord] "" (coord),
    );
}

/// Samples the draw's third texture at `coord`, as RGBA (bound at 3; on
/// texture unit 0, with the first).
pub fn texture2(coord: Vec2) Vec4 {
    return asm volatile (
        \\%f32 = OpTypeFloat 32
        \\%v4 = OpTypeVector %f32 4
        \\%img = OpTypeImage %f32 2D 0 0 0 1 Unknown
        \\%simg = OpTypeSampledImage %img
        \\%ptr = OpTypePointer UniformConstant %simg
        \\%tex = OpVariable %ptr UniformConstant
        \\OpDecorate %tex DescriptorSet 0
        \\OpDecorate %tex Binding 3
        \\%s = OpLoad %simg %tex
        \\%ret = OpImageSampleImplicitLod %v4 %s %coord
        : [ret] "" (-> Vec4),
        : [coord] "" (coord),
    );
}

pub fn splat2(x: f32) Vec2 {
    return @splat(x);
}

pub fn splat3(x: f32) Vec3 {
    return @splat(x);
}

pub fn splat4(x: f32) Vec4 {
    return @splat(x);
}

pub fn clamp(x: anytype, lo: anytype, hi: anytype) @TypeOf(x) {
    return @min(@max(x, lo), hi);
}

pub fn dot(a: anytype, b: @TypeOf(a)) f32 {
    return @reduce(.Add, a * b);
}

pub fn length(a: anytype) f32 {
    return @sqrt(dot(a, a));
}

pub fn normalize(a: anytype) @TypeOf(a) {
    return a * @as(@TypeOf(a), @splat(1 / length(a)));
}
