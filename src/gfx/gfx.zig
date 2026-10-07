//! 2D graphics on the vc4 API, for Dazzle's toolkit: anti-aliased
//! rectangles with rounded corners (and circles), polygons and polylines,
//! filled or stroked, blended over what is below them.
//!
//! A `Canvas` records shapes and text (on the CPU, without the GPU); a
//! `Renderer` draws them into a vc4 frame. Text's glyphs come from an
//! `Atlas`, a texture of glyphs the font renderer rasterized:
//!
//!     canvas.begin(width, height);
//!     canvas.fillRoundedRect(.{ .x = 16, .y = 16, .w = 200, .h = 56 }, .all(28), .rgb(0x6750a4));
//!     canvas.strokePolyline(&points, false, 2, .rgb(0x1d1b20));
//!     _ = canvas.drawText(&atlas, .{ .font = &fira, .size = 16 }, 16, 120, "Hello", .rgb(0x1d1b20));
//!     try renderer.draw(&canvas, &frame);
//!
//! `preview` renders a canvas on the CPU with the same shaders (in the QPU
//! simulator), for tests and preview images.

pub const geometry = @import("geometry.zig");
pub const atlas = @import("atlas.zig");
pub const shaders = @import("shaders.zig");
pub const canvas = @import("canvas.zig");
pub const renderer = @import("renderer.zig");
pub const preview = @import("preview.zig");
pub const png = @import("png.zig");

pub const Canvas = canvas.Canvas;
pub const Image = canvas.Image;
pub const Color = canvas.Color;
pub const Rect = canvas.Rect;
pub const Radii = canvas.Radii;
pub const Point = canvas.Point;
pub const Renderer = renderer.Renderer;
pub const Atlas = atlas.Atlas;
pub const Record = canvas.Record;

test {
    _ = geometry;
    _ = atlas;
    _ = shaders;
    _ = canvas;
    _ = renderer;
    _ = png;
    _ = preview;
}
