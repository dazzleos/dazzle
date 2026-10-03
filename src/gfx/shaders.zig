//! The 2D shaders, written with the vc4 compiler's builder API.
//!
//! Both programs take vertices in clip space (computed on the CPU) and
//! blend their colour over what the tile buffer holds (source-over, with
//! straight alpha).
//!
//! * `shape`: anti-aliased rounded rectangles, filled or stroked. Each
//!   vertex carries the rectangle: the fragment's position relative to its
//!   centre, its half size, corner radius and stroke width, and the colour.
//!   The fragment shader computes the signed distance to the rounded outline
//!   and turns it into coverage over one pixel.
//! * `solid`: triangles with a colour per vertex, for polygons and strokes
//!   whose anti-aliased edges are fringes fading to transparent.
//!
//! Uniforms 0 and 1 are the viewport scale (x, y) in 1/16ths of a pixel.

const std = @import("std");
const vc4 = @import("vc4");

const compiler = vc4.compiler;
const Shader = compiler.Shader;
const Value = compiler.Value;

/// Floats per shape vertex: clip x, y; then local x, y, half width,
/// half height, radius, stroke width; then r, g, b, a.
pub const shape_floats = 12;
/// Floats per solid vertex: clip x, y; then r, g, b, a.
pub const solid_floats = 6;

/// The vertex shader's screen-space header: X/Y in 1/16ths of a pixel, Zs
/// and 1/Wc.
fn writeScreenHeader(s: *Shader, x: Value, y: Value) void {
    s.vpmWrite(s.packScreenXy(s.fmul(x, s.uniform(0)), s.fmul(y, s.uniform(1))));
    s.vpmWrite(s.constantF(0.5));
    s.vpmWrite(s.constantF(1.0));
}

/// A vertex shader passing `floats - 2` varyings through after the
/// position.
pub fn vertex(floats: u32) Shader {
    var s = Shader.init(.vertex);
    const x = s.vpmRead();
    const y = s.vpmRead();
    var rest: [shape_floats]Value = undefined;
    for (rest[0 .. floats - 2]) |*v| v.* = s.vpmRead();
    writeScreenHeader(&s, x, y);
    for (rest[0 .. floats - 2]) |v| s.vpmWrite(v);
    return s;
}

/// The coordinate shader (for the binner): the position only.
pub fn coordinate() Shader {
    var s = Shader.init(.coordinate);
    const x = s.vpmRead();
    const y = s.vpmRead();
    s.vpmWrite(x);
    s.vpmWrite(y);
    s.vpmWrite(s.constantF(0.0));
    s.vpmWrite(s.constantF(1.0));
    writeScreenHeader(&s, x, y);
    return s;
}

fn clamp01(s: *Shader, x: Value) Value {
    return s.binary(.fmin, s.binary(.fmax, x, s.constantF(0.0)), s.constantF(1.0));
}

/// Blends `color` (r, g, b) with coverage alpha `a` over the tile buffer
/// and writes the result.
fn blendOut(s: *Shader, r: Value, g: Value, b: Value, a: Value) void {
    const dst = s.tlbColorLoad();
    const inv = s.fsub(s.constantF(1.0), a);
    // The tile buffer holds B, G, R, A.
    const src = [4]Value{ b, g, r, s.constantF(1.0) };
    var out: [4]Value = undefined;
    for (&out, src, 0..) |*o, c, i| {
        const d = s.unpackUnorm8(dst, @intCast(i));
        o.* = s.fadd(s.fmul(c, a), s.fmul(d, inv));
    }
    s.tlbColor(s.packUnorm8888(out[0], out[1], out[2], out[3]));
}

/// The pixel's coverage by the shape shrunk by `inset`: its distance
/// spread over one pixel, but no more than the product of the coverages by
/// the box's sides, which is exact at square corners (where the distance
/// alone would give half rather than a quarter).
fn boxCoverage(s: *Shader, d: Value, ex: Value, ey: Value, inset: Value) Value {
    const half = s.constantF(0.5);
    const by_distance = clamp01(s, s.fsub(half, s.fadd(d, inset)));
    const by_sides = s.fmul(clamp01(s, s.fsub(half, s.fadd(ex, inset))), clamp01(s, s.fsub(half, s.fadd(ey, inset))));
    return s.binary(.fmin, by_distance, by_sides);
}

pub fn shapeFragment() Shader {
    var s = Shader.init(.fragment);
    const px = s.varying();
    const py = s.varying();
    const hx = s.varying();
    const hy = s.varying();
    const radius = s.varying();
    const stroke = s.varying();
    const r = s.varying();
    const g = s.varying();
    const b = s.varying();
    const a = s.varying();
    const zero = s.constantF(0.0);

    // Signed distance to a rounded box (negative inside):
    // q = |p| - (half - radius); d = |max(q, 0)| + min(max(q.x, q.y), 0) - radius
    const ax = s.binary(.fmaxabs, px, px);
    const ay = s.binary(.fmaxabs, py, py);
    const qx = s.fsub(ax, s.fsub(hx, radius));
    const qy = s.fsub(ay, s.fsub(hy, radius));
    const mx = s.binary(.fmax, qx, zero);
    const my = s.binary(.fmax, qy, zero);
    const len2 = s.fadd(s.fmul(mx, mx), s.fmul(my, my));
    // sqrt(x) = x / sqrt(x), and 0 at 0.
    const len = s.fmul(len2, s.unary(.rsqrt, s.binary(.fmax, len2, s.constantF(1e-12))));
    const inside = s.binary(.fmin, s.binary(.fmax, qx, qy), zero);
    const d = s.fsub(s.fadd(len, inside), radius);
    // Distances to the box's sides, without rounding.
    const ex = s.fsub(ax, hx);
    const ey = s.fsub(ay, hy);

    // Coverage of the band from the outline to `stroke` pixels inside it.
    const coverage = s.fsub(boxCoverage(&s, d, ex, ey, zero), boxCoverage(&s, d, ex, ey, stroke));
    blendOut(&s, r, g, b, s.fmul(a, coverage));
    return s;
}

pub fn solidFragment() Shader {
    var s = Shader.init(.fragment);
    const r = s.varying();
    const g = s.varying();
    const b = s.varying();
    const a = s.varying();
    blendOut(&s, r, g, b, a);
    return s;
}

/// A program's three hardware shaders, compiled.
pub const Compiled = struct {
    fs: compiler.Compiled,
    vs: compiler.Compiled,
    cs: compiler.Compiled,
};

pub fn compileShape() !Compiled {
    var fs = shapeFragment();
    var vs = vertex(shape_floats);
    var cs = coordinate();
    return .{ .fs = try compiler.compile(&fs), .vs = try compiler.compile(&vs), .cs = try compiler.compile(&cs) };
}

pub fn compileSolid() !Compiled {
    var fs = solidFragment();
    var vs = vertex(solid_floats);
    var cs = coordinate();
    return .{ .fs = try compiler.compile(&fs), .vs = try compiler.compile(&vs), .cs = try compiler.compile(&cs) };
}

test "the 2D shaders compile and pass the hardware rules" {
    const shape = try compileShape();
    const solid = try compileSolid();
    for ([_]compiler.Compiled{ shape.fs, shape.vs, shape.cs, solid.fs, solid.vs, solid.cs }) |c| {
        try vc4.qpu.validate(c.code(), c.stage, null);
    }
}
