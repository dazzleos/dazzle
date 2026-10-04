//! The 2D shaders, written in Zig (shaders/) and compiled when Stardust is
//! built. Both take vertices in clip space (computed on the CPU) and blend
//! their colour over what the tile buffer holds (source-over, with straight
//! alpha).
//!
//! * `shape`: anti-aliased rounded rectangles, filled or stroked. Each
//!   vertex carries the rectangle: the fragment's position relative to its
//!   centre, its half size, corner radius and stroke width, and the colour.
//!   The fragment shader computes the signed distance to the rounded outline
//!   and turns it into coverage over one pixel.
//! * `solid`: triangles with a colour per vertex, for polygons and strokes
//!   whose anti-aliased edges are fringes fading to transparent.
//! * `text`: glyphs, their coverage from the glyph atlas texture.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");

const Program = shader.Program;

/// Floats per shape vertex: clip x, y; then local x, y, half width,
/// half height; radius, stroke width; then r, g, b, a.
pub const shape_floats = 12;
/// Floats per solid vertex: clip x, y; then r, g, b, a.
pub const solid_floats = 6;
/// Floats per text vertex: clip x, y; atlas u, v; then r, g, b, a.
pub const text_floats = 8;

pub const shape_layout: shader.pipeline.Options = .{
    .vertex_stride = shape_floats * 4,
    .attributes = &.{
        .{ .location = 0, .offset = 0 },
        .{ .location = 1, .offset = 8 },
        .{ .location = 2, .offset = 24 },
        .{ .location = 3, .offset = 32 },
    },
};

pub const solid_layout: shader.pipeline.Options = .{
    .vertex_stride = solid_floats * 4,
    .attributes = &.{
        .{ .location = 0, .offset = 0 },
        .{ .location = 1, .offset = 8 },
    },
};

pub const text_layout: shader.pipeline.Options = .{
    .vertex_stride = text_floats * 4,
    .attributes = &.{
        .{ .location = 0, .offset = 0 },
        .{ .location = 1, .offset = 8 },
        .{ .location = 2, .offset = 16 },
    },
};

pub fn shape() Program {
    return Program.decode(@embedFile("shape.shader")) catch unreachable;
}

pub fn solid() Program {
    return Program.decode(@embedFile("solid.shader")) catch unreachable;
}

pub fn text() Program {
    return Program.decode(@embedFile("text.shader")) catch unreachable;
}

test "the 2D shaders pass the hardware rules, and read the vertex layouts" {
    for ([_]Program{ shape(), solid(), text() }, [_]shader.pipeline.Options{ shape_layout, solid_layout, text_layout }, [_]u32{ shape_floats, solid_floats, text_floats }) |p, layout, floats| {
        for ([_]vc4.compiler.Compiled{ p.fs, p.vs, p.cs }) |c| try vc4.qpu.validate(c.code(), c.stage, null);
        try std.testing.expectEqual(layout.attributes.len, p.num_attributes);
        var total: u32 = 0;
        for (p.attributeList(), layout.attributes) |a, f| {
            try std.testing.expectEqual(a.location, f.location);
            try std.testing.expectEqual(total * 4, f.offset);
            total += a.components;
        }
        try std.testing.expectEqual(floats, total);
        // Everything but the position is passed on, in order.
        try std.testing.expectEqual(floats - 2, p.varying_components);
    }
}
