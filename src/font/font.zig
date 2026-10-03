//! Stardust's font renderer: OpenType fonts with TrueType outlines,
//! rasterized with exact-area anti-aliasing and laid out with kerning.
//!
//! * `opentype`: parsing the font (character map, metrics, outlines, GPOS
//!   kerning)
//! * `raster`: rasterizing outlines into coverage masks
//! * `text`: the glyph cache, layout, and drawing into 32-bit pixels
//!
//! The system font is Fira Sans (SIL Open Font License), installed in the
//! image as /usr/share/fonts/FiraSans-Regular.ttf.
//!
//!     const f = try font.Font.init(data);
//!     var cache = font.GlyphCache.init(gpa);
//!     _ = try font.draw(canvas, &cache, .{ .font = &f, .size = 32 }, x, baseline, "Hello");

pub const opentype = @import("opentype.zig");
pub const raster = @import("raster.zig");
pub const text = @import("text.zig");

pub const Font = opentype.Font;
pub const Canvas = text.Canvas;
pub const GlyphCache = text.GlyphCache;
pub const Style = text.Style;
pub const draw = text.draw;
pub const measure = text.measure;

/// Where the system font is installed.
pub const system_font_path = "/usr/share/fonts/FiraSans-Regular.ttf";

test {
    _ = opentype;
    _ = raster;
    _ = text;
}
