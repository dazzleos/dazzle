//! Hand-scheduled QPU programs for the first triangle.
//!
//! The V3D pipeline runs three programs per draw:
//!
//! * The coordinate shader (CS) runs during binning. It reads the position
//!   attribute and writes clip-space and screen-space coordinates so the
//!   binner can work out which tiles each triangle touches.
//! * The vertex shader (VS) runs during rendering. It writes screen-space
//!   coordinates plus the varyings the fragment shader interpolates.
//! * The fragment shader (FS) runs per 2x2 quad of pixels and writes the
//!   final colour to the tile buffer (TLB).
//!
//! These programs are the output a real GLSL compiler would produce for:
//!
//!     attribute vec2 pos;       varying vec3 v_color;
//!     attribute vec3 color;     void main() { gl_FragColor = vec4(v_color, 1.0); }
//!     void main() { gl_Position = vec4(pos, 0.0, 1.0); v_color = color; }
//!
//! Since w is always 1.0, the perspective divide is skipped.

const qpu = @import("qpu.zig");

const r = qpu.r;
const ra = qpu.ra;
const wr = qpu.wr;
const wa = qpu.wa;

/// Vertex attribute layout shared by the shader record and the shaders.
pub const attributes = struct {
    /// vec2 position followed by vec3 colour, all f32.
    pub const stride = 5 * 4;
    pub const position_offset = 0;
    pub const position_size = 2 * 4;
    pub const color_offset = 2 * 4;
    pub const color_size = 3 * 4;
};

/// Number of varyings the VS writes and the FS reads (r, g, b).
pub const num_varyings = 3;

/// Uniforms read by the CS and VS, in stream order.
pub const VertexUniforms = extern struct {
    /// Viewport half-width in 1/16ths of a pixel.
    x_scale: f32,
    /// Viewport half-height in 1/16ths of a pixel; negative to flip Y so
    /// that +Y in clip space points up the screen.
    y_scale: f32,
};

/// VPM setup values. Fields (section 7 of the reference guide):
/// bits 23:20 number of vectors (reads only; 0 means 16), 17:12 stride,
/// 11 horizontal, 9:8 size (2 = 32-bit), 7:0 address.
fn vpmSetup(count: u4) u32 {
    return @as(u32, count) << 20 | 1 << 12 | 1 << 11 | 2 << 8;
}

pub const Program = qpu.Program(32);

/// Emits the shared epilogue that converts clip-space x/y in r0/r1 into the
/// packed 12.4 fixed-point screen coordinates the hardware expects, then
/// writes Xs|Ys, Zs and 1/Wc to the VPM.
///
/// Clobbers r0, r1, r2 and ra1.
fn emitScreenSpaceOutputs(p: *Program) !void {
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = wr(0), .a = r(0), .b = qpu.unif } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = wr(1), .a = r(1), .b = qpu.unif } }));
    // Xs into the low 16 bits and Ys into the high 16 bits of ra1. Regfile
    // A pack modes convert the ftoi result to int16 in place.
    p.emit(try qpu.alu(.{
        .add = .{ .op = .ftoi, .dst = wa(1), .a = r(0), .b = r(0) },
        .pack = .{ .regfile_a = .@"16a" },
    }));
    p.emit(try qpu.alu(.{
        .add = .{ .op = .ftoi, .dst = wa(1), .a = r(1), .b = r(1) },
        .pack = .{ .regfile_a = .@"16b" },
    }));
    // ra1 cannot be read in the instruction straight after it is written, so
    // load Zs (0.5: depth 0 mapped to the middle of the [0, 1] range) here.
    p.emit(try qpu.loadImm(.{ .add_dst = wr(2), .value = @bitCast(@as(f32, 0.5)) }));
    p.emit(try qpu.mov(qpu.vpm_write, ra(1)));
    p.emit(try qpu.mov(qpu.vpm_write, r(2)));
    // 1/Wc.
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write, .value = @bitCast(@as(f32, 1.0)) }));
}

/// Coordinate shader. Output per vertex: Xc, Yc, Zc, Wc, Xs|Ys, Zs, 1/Wc.
pub fn coordinate() !Program {
    var p: Program = .{};
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = vpmSetup(0) }));
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = vpmSetup(2) }));
    p.emit(try qpu.mov(wr(0), qpu.vpm_read)); // x
    p.emit(try qpu.mov(wr(1), qpu.vpm_read)); // y
    p.emit(try qpu.mov(qpu.vpm_write, r(0))); // Xc
    p.emit(try qpu.mov(qpu.vpm_write, r(1))); // Yc
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write, .value = @bitCast(@as(f32, 0.0)) })); // Zc
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write, .value = @bitCast(@as(f32, 1.0)) })); // Wc
    try emitScreenSpaceOutputs(&p);
    p.end(.coordinate);
    try qpu.validate(p.code(), .coordinate, null);
    return p;
}

/// Vertex shader. Output per vertex: Xs|Ys, Zs, 1/Wc, then the varyings.
pub fn vertex() !Program {
    var p: Program = .{};
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = vpmSetup(0) }));
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = vpmSetup(5) }));
    p.emit(try qpu.mov(wr(0), qpu.vpm_read)); // x
    p.emit(try qpu.mov(wr(1), qpu.vpm_read)); // y
    p.emit(try qpu.mov(wa(0), qpu.vpm_read)); // red
    p.emit(try qpu.mov(wr(3), qpu.vpm_read)); // green
    p.emit(try qpu.mov(wa(2), qpu.vpm_read)); // blue
    try emitScreenSpaceOutputs(&p);
    p.emit(try qpu.mov(qpu.vpm_write, ra(0)));
    p.emit(try qpu.mov(qpu.vpm_write, r(3)));
    p.emit(try qpu.mov(qpu.vpm_write, ra(2)));
    p.end(.vertex);
    try qpu.validate(p.code(), .vertex, null);
    return p;
}

/// Fragment shader: interpolates the colour varyings and writes an opaque
/// pixel to the tile buffer.
pub fn fragment() !Program {
    var p: Program = .{};
    // Each varying read returns the partially interpolated value and loads
    // the constant term (C) into r5. Perspective-correct interpolation is
    // vary * W + C.
    for (0..num_varyings) |i| {
        const acc: u3 = @intCast(i);
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        p.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = wr(acc), .a = r(acc), .b = r(5) } }));
    }
    // Pack to 8-bit unorm channels in r3. The render target is
    // B8G8R8A8 in memory (DRM_FORMAT_XRGB8888), so blue goes in byte 0.
    const one = qpu.smallImmFloat(1.0);
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = wr(3), .a = r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = wr(3), .a = r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = wr(3), .a = r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
    // The first TLB access implicitly waits for the scoreboard.
    p.emit(try qpu.mov(qpu.tlb_color_all, r(3)));
    p.end(.fragment);
    try qpu.validate(p.code(), .fragment, null);
    return p;
}

const std = @import("std");

test "shaders encode and pass validation" {
    _ = try coordinate();
    _ = try vertex();
    _ = try fragment();
}

test "shaders read every attribute word they declare" {
    const count = struct {
        fn vpmReads(code: []const qpu.Inst) usize {
            var n: usize = 0;
            for (code) |i| {
                if (qpu.getSig(i) != .load_imm and qpu.getRaddrA(i) == qpu.R.vpm) n += 1;
            }
            return n;
        }
    };
    const cs = try coordinate();
    const vs = try vertex();
    try std.testing.expectEqual(@as(usize, attributes.position_size / 4), count.vpmReads(cs.code()));
    try std.testing.expectEqual(@as(usize, attributes.stride / 4), count.vpmReads(vs.code()));
}
