//! 2D graphics on the vc4 API, for Stardust's toolkit: anti-aliased
//! rectangles with rounded corners (and circles), polygons and polylines,
//! filled or stroked, blended over what is below them.
//!
//! A `Canvas` records shapes (on the CPU, without the GPU); a `Renderer`
//! draws them into a vc4 frame:
//!
//!     canvas.begin(width, height);
//!     canvas.fillRoundedRect(.{ .x = 16, .y = 16, .w = 200, .h = 56 }, .all(28), .rgb(0x6750a4));
//!     canvas.strokePolyline(&points, false, 2, .rgb(0x1d1b20));
//!     try renderer.draw(&canvas, &frame);
//!
//! `preview` renders a canvas on the CPU with the same shaders (in the QPU
//! simulator), for tests and preview images.

pub const geometry = @import("geometry.zig");
pub const shaders = @import("shaders.zig");
pub const canvas = @import("canvas.zig");
pub const renderer = @import("renderer.zig");
pub const preview = @import("preview.zig");

pub const Canvas = canvas.Canvas;
pub const Color = canvas.Color;
pub const Rect = canvas.Rect;
pub const Radii = canvas.Radii;
pub const Point = canvas.Point;
pub const Renderer = renderer.Renderer;

test {
    _ = geometry;
    _ = shaders;
    _ = canvas;
    _ = renderer;
    _ = preview;
}
