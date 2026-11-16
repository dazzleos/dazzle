//! The shell's see-through boxes (the dock, its quick settings, the
//! notifications and the performance overlay, drawn with kete): their
//! colour, `alpha` opaque, so what is behind them shows through but not
//! through what is drawn in them. Pixels are 0xAARRGGBB, not
//! premultiplied, except where the display's planes take them
//! premultiplied.

const std = @import("std");

/// How opaque a box is.
pub const alpha = 0xb8;

/// `p` premultiplied by its alpha, as the display's planes take it.
pub fn premultiply(p: u32) u32 {
    const a = p >> 24;
    if (a == 255) return p;
    var out: u32 = a << 24;
    inline for (.{ 0, 8, 16 }) |shift| out |= ((p >> shift & 0xff) * a + 127) / 255 << shift;
    return out;
}

test "premultiplied, as the display's planes take it" {
    try std.testing.expectEqual(@as(u32, 0x80402010), premultiply(0x80804020));
    try std.testing.expectEqual(@as(u32, 0xff804020), premultiply(0xff804020));
}
