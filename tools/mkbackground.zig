//! Makes a built-in desktop background ready to go in the system: from a
//! PNG (1920 by 1080, as the backgrounds/ directory has them), the ETC1
//! file the shell shows (see src/shell/background.zig) and a small PNG of
//! it for Settings' Appearance page.
//!
//! The ETC1 file: "DZE1", the width and height (32-bit, little-endian),
//! then each 4 by 4 block's 64 bits (little-endian), a row of blocks at a
//! time from the top left.
//!
//! Usage: mkbackground <image.png> <out.etc1> <thumbnail.png> <thumbnail width> <thumbnail height>

const std = @import("std");
const etc1 = @import("etc1");
const png = @import("png");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 6) {
        std.debug.print("usage: mkbackground <image.png> <out.etc1> <thumbnail.png> <thumbnail width> <thumbnail height>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, args[1], gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(data);
    const image = try png.decode(gpa, data);
    defer gpa.free(image.pixels);

    const n = etc1.blocksOf(image.width, image.height);
    const blocks = try gpa.alloc(u64, n[0] * n[1]);
    defer gpa.free(blocks);
    etc1.encode(image.pixels, image.width, image.height, blocks);
    const out = try gpa.alloc(u8, 12 + blocks.len * 8);
    defer gpa.free(out);
    @memcpy(out[0..4], "DZE1");
    std.mem.writeInt(u32, out[4..8], image.width, .little);
    std.mem.writeInt(u32, out[8..12], image.height, .little);
    for (blocks, 0..) |b, i| std.mem.writeInt(u64, out[12 + i * 8 ..][0..8], b, .little);
    try write(io, args[2], out);

    // The thumbnail: each pixel the average of those it covers.
    const tw = try std.fmt.parseInt(u32, args[4], 10);
    const th = try std.fmt.parseInt(u32, args[5], 10);
    const small = try gpa.alloc(u32, @as(usize, tw) * th);
    defer gpa.free(small);
    for (0..th) |y| for (0..tw) |x| {
        const x0 = x * image.width / tw;
        const x1 = @max((x + 1) * image.width / tw, x0 + 1);
        const y0 = y * image.height / th;
        const y1 = @max((y + 1) * image.height / th, y0 + 1);
        var sum: [3]u64 = .{ 0, 0, 0 };
        for (y0..y1) |sy| for (x0..x1) |sx| {
            const px = image.pixels[sy * image.width + sx];
            sum[0] += px >> 16 & 0xff;
            sum[1] += px >> 8 & 0xff;
            sum[2] += px & 0xff;
        };
        const count = (y1 - y0) * (x1 - x0);
        small[y * tw + x] = @intCast(0xff000000 | (sum[0] / count) << 16 | (sum[1] / count) << 8 | sum[2] / count);
    };
    const encoded = try png.encode(gpa, small, tw, th);
    defer gpa.free(encoded);
    try write(io, args[3], encoded);
}

fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
