//! Writing PNG images: 8-bit RGB (screenshots are opaque), each row
//! filtered by its difference from the pixel before (which suits what is
//! on a screen) and compressed with deflate at its fastest.

const std = @import("std");

/// The PNG of `pixels` (0x__RRGGBB, alpha ignored), `width` by `height`.
pub fn encode(gpa: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 }; // 8 bits, RGB, deflate, filters, not interlaced
    try chunk(gpa, &out, "IHDR", &ihdr);

    // The rows, filtered, then compressed.
    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer z.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .fastest);
    const row = try gpa.alloc(u8, 1 + @as(usize, width) * 3);
    defer gpa.free(row);
    for (0..height) |y| {
        row[0] = 1; // Sub: each byte less the one a pixel before
        var prev: [3]u8 = .{ 0, 0, 0 };
        for (pixels[y * width ..][0..width], 0..) |p, x| {
            const rgb = [3]u8{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) };
            for (0..3) |k| row[1 + x * 3 + k] = rgb[k] -% prev[k];
            prev = rgb;
        }
        try c.writer.writeAll(row);
    }
    try c.finish();
    try chunk(gpa, &out, "IDAT", z.written());
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(body.len), .big);
    try out.appendSlice(gpa, &b);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    std.mem.writeInt(u32, &b, crc.final(), .big);
    try out.appendSlice(gpa, &b);
}

const testing = std.testing;

test "a PNG that decodes to the pixels" {
    const gpa = testing.allocator;
    const pixels = [_]u32{ 0xffff0000, 0xff00ff00, 0x000000ff, 0xff102030, 0xff102031, 0xffffffff };
    const png = try encode(gpa, &pixels, 3, 2);
    defer gpa.free(png);
    try testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x03\x00\x00\x00\x02\x08\x02"));
    // The image data: the IDAT chunk after IHDR's (8 + 4 + 4 + 13 + 4).
    const at = 8 + 25;
    try testing.expectEqualStrings("IDAT", png[at + 4 ..][0..4]);
    const len = std.mem.readInt(u32, png[at..][0..4], .big);
    var input = std.Io.Reader.fixed(png[at + 8 ..][0..len]);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d = std.compress.flate.Decompress.init(&input, .zlib, window);
    var raw: [2 * (1 + 9)]u8 = undefined;
    try d.reader.readSliceAll(&raw);
    for (0..2) |y| {
        const r = raw[y * 10 ..][0..10];
        try testing.expectEqual(@as(u8, 1), r[0]);
        for (3..9) |i| r[1 + i] +%= r[1 + i - 3];
        for (0..3) |x| {
            const p = pixels[y * 3 + x];
            try testing.expectEqualSlices(u8, &.{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) }, r[1 + x * 3 ..][0..3]);
        }
    }
    try testing.expect(std.mem.endsWith(u8, png, "IEND\xae\x42\x60\x82"));
}
