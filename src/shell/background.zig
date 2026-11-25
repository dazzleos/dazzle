//! The desktop's background image (chosen in Files, kept in the appearance
//! settings): read, made the screen's size, and made ready for the GPU in
//! the least memory it can take, on a thread of its own so the shell goes
//! on meanwhile.
//!
//! The image is scaled to cover the screen (cropped in the middle), then
//! compressed to ETC1, which the texture unit decodes as it samples: a
//! 1920 by 1080 background takes about 1 MB of the GPU's memory that way,
//! rather than 8 MB at 32 bits a pixel. Where ETC1 cannot be used (the
//! renderer checks the GPU decodes it as expected, `Renderer.etc1Order`),
//! it is BGR565 instead (4 MB), dithered so smooth skies do not band.
//!
//! The built-in backgrounds are ETC1 already (made at build time by
//! tools/mkbackground.zig, at 1920 by 1080): on a screen that size, their
//! blocks are used as they are; otherwise they are decoded, and made ready
//! as a PNG is.

const std = @import("std");
const sys = @import("sys");
const vc4 = @import("vc4");
const png = @import("gfx").png;
const appearance = @import("appearance");

const etc1 = vc4.etc1;

/// How the image is made ready for the GPU.
pub const Kind = union(enum) {
    /// ETC1 blocks, laid out as the texture unit reads them, in this byte
    /// order.
    etc1: etc1.ByteOrder,
    /// BGR565 pixels (red in the low bits), row by row (the renderer lays them out).
    bgr565,
};

/// An image ready for the GPU: `data` as `kind` says, `width` by `height`.
pub const Prepared = struct {
    data: []u8,
    width: u32,
    height: u32,
    kind: Kind,
    /// Its last rows (behind the dock), as the GPU shows them: 0xffRRGGBB,
    /// `width` apart, for the dock's overlay to draw them the same.
    bottom: []u32 = &.{},

    pub fn deinit(p: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(p.data);
        gpa.free(p.bottom);
    }
};

/// The biggest image file read.
pub const max_file_size = 64 * 1024 * 1024;

/// Reads the image at `path` (a PNG, or a built-in background's ETC1
/// file) and makes it ready for a screen `width` by `height`, as `kind`,
/// with its last `bottom_rows` rows as shown.
pub fn prepare(gpa: std.mem.Allocator, path: []const u8, width: u32, height: u32, kind: Kind, bottom_rows: u32) !Prepared {
    var path_buf: [appearance.ImagePath.max_len + 1]u8 = undefined;
    const pathz = try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0);
    const data = try sys.readFileAlloc(gpa, pathz, max_file_size);
    defer gpa.free(data);
    if (std.mem.endsWith(u8, path, ".etc1")) return fromEtc1File(gpa, data, width, height, kind, bottom_rows);
    const image = try png.decode(gpa, data);
    defer gpa.free(image.pixels);
    const pixels = try gpa.alloc(u32, @as(usize, width) * height);
    defer gpa.free(pixels);
    cover(image.pixels, image.width, image.height, pixels, width, height);
    return fromPixels(gpa, pixels, width, height, kind, bottom_rows);
}

/// A built-in background's ETC1 file (`data`: "DZE1", its width and height,
/// then its blocks, see tools/mkbackground.zig) ready for a screen `width`
/// by `height`, as `kind`, with its last `bottom_rows` rows as shown.
pub fn fromEtc1File(gpa: std.mem.Allocator, data: []const u8, width: u32, height: u32, kind: Kind, bottom_rows: u32) !Prepared {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "DZE1")) return error.NotEtc1;
    const w = std.mem.readInt(u32, data[4..8], .little);
    const h = std.mem.readInt(u32, data[8..12], .little);
    const n = etc1.blocksOf(w, h);
    if (w == 0 or h == 0 or data.len != 12 + @as(usize, n[0]) * n[1] * 8) return error.NotEtc1;
    const blocks = try gpa.alloc(u64, n[0] * n[1]);
    defer gpa.free(blocks);
    for (blocks, 0..) |*b, i| b.* = std.mem.readInt(u64, data[12 + i * 8 ..][0..8], .little);
    // The screen's size, for the GPU's ETC1: as it is.
    if (kind == .etc1 and w == width and h == height) return fromBlocks(gpa, blocks, width, height, kind.etc1, bottom_rows);
    // Otherwise, its pixels, made ready as a PNG's are.
    const pixels = try gpa.alloc(u32, @as(usize, w) * h);
    defer gpa.free(pixels);
    for (0..n[1]) |by| for (0..n[0]) |bx| {
        const decoded = etc1.decodeBlock(blocks[by * n[0] + bx]);
        for (0..4) |y| for (0..4) |x| {
            const px = bx * 4 + x;
            const py = by * 4 + y;
            if (px < w and py < h) pixels[py * w + px] = decoded[y * 4 + x];
        };
    };
    if (w == width and h == height) return fromPixels(gpa, pixels, width, height, kind, bottom_rows);
    const scaled = try gpa.alloc(u32, @as(usize, width) * height);
    defer gpa.free(scaled);
    cover(pixels, w, h, scaled, width, height);
    return fromPixels(gpa, scaled, width, height, kind, bottom_rows);
}

/// ETC1 `blocks` (`width` by `height` pixels) laid out for the GPU in
/// `order`, with the last `bottom_rows` rows as shown.
fn fromBlocks(gpa: std.mem.Allocator, blocks: []const u64, width: u32, height: u32, order: etc1.ByteOrder, bottom_rows: u32) !Prepared {
    const rows = @min(bottom_rows, height);
    const first = height - rows;
    const n = etc1.blocksOf(width, height);
    const bottom = try gpa.alloc(u32, @as(usize, width) * rows);
    errdefer gpa.free(bottom);
    const out = try gpa.alloc(u8, etc1.imageSize(width, height));
    @memset(out, 0);
    etc1.upload(out, width, height, blocks, order);
    for (0..rows) |row| for (0..width) |x| {
        const y = first + row;
        const decoded = etc1.decodeBlock(blocks[(y / 4) * n[0] + x / 4]);
        bottom[row * width + x] = decoded[(y % 4) * 4 + x % 4];
    };
    return .{ .data = out, .width = width, .height = height, .kind = .{ .etc1 = order }, .bottom = bottom };
}

/// `pixels` (`width` by `height`) ready for the GPU, as `kind`, with its
/// last `bottom_rows` rows as shown.
pub fn fromPixels(gpa: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, kind: Kind, bottom_rows: u32) !Prepared {
    switch (kind) {
        .etc1 => |order| {
            const n = etc1.blocksOf(width, height);
            const blocks = try gpa.alloc(u64, n[0] * n[1]);
            defer gpa.free(blocks);
            etc1.encode(pixels, width, height, blocks);
            return fromBlocks(gpa, blocks, width, height, order, bottom_rows);
        },
        .bgr565 => {
            const rows = @min(bottom_rows, height);
            const first = height - rows;
            const bottom = try gpa.alloc(u32, @as(usize, width) * rows);
            errdefer gpa.free(bottom);
            const out = try gpa.alloc(u8, @as(usize, width) * height * 2);
            for (0..height) |y| for (0..width) |x| {
                const px = pixels[y * width + x];
                const v = dither565(px, @intCast(x), @intCast(y));
                std.mem.writeInt(u16, out[(y * width + x) * 2 ..][0..2], v, .little);
                if (y >= first) bottom[(y - first) * width + x] = expand565(v);
            };
            return .{ .data = out, .width = width, .height = height, .kind = kind, .bottom = bottom };
        },
    }
}

/// A BGR565 pixel (red in the low bits) as the GPU shows it.
fn expand565(v: u16) u32 {
    const r: u32 = v & 31;
    const g: u32 = v >> 5 & 63;
    const b: u32 = v >> 11;
    return 0xff000000 | ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2));
}

/// Scales `src` (`sw` by `sh`) to cover `dst` (`dw` by `dh`), cropping
/// what is left over equally on either side; each pixel the average of
/// those it covers.
pub fn cover(src: []const u32, sw: u32, sh: u32, dst: []u32, dw: u32, dh: u32) void {
    const scale = @max(@as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(sw)), @as(f64, @floatFromInt(dh)) / @as(f64, @floatFromInt(sh)));
    // The part of the image shown, in its pixels.
    const vw = @as(f64, @floatFromInt(dw)) / scale;
    const vh = @as(f64, @floatFromInt(dh)) / scale;
    const ox = (@as(f64, @floatFromInt(sw)) - vw) / 2;
    const oy = (@as(f64, @floatFromInt(sh)) - vh) / 2;
    for (0..dh) |y| {
        const y0 = span(oy + @as(f64, @floatFromInt(y)) / scale, sh);
        const y1 = @max(spanEnd(oy + @as(f64, @floatFromInt(y + 1)) / scale, sh), y0 + 1);
        for (0..dw) |x| {
            const x0 = span(ox + @as(f64, @floatFromInt(x)) / scale, sw);
            const x1 = @max(spanEnd(ox + @as(f64, @floatFromInt(x + 1)) / scale, sw), x0 + 1);
            var sum: [3]u32 = .{ 0, 0, 0 };
            for (y0..@min(y1, sh)) |sy| for (x0..@min(x1, sw)) |sx| {
                const px = src[sy * sw + sx];
                sum[0] += px >> 16 & 0xff;
                sum[1] += px >> 8 & 0xff;
                sum[2] += px & 0xff;
            };
            const count: u32 = @intCast((@min(y1, sh) - y0) * (@min(x1, sw) - x0));
            dst[y * dw + x] = 0xff000000 | (sum[0] / count) << 16 | (sum[1] / count) << 8 | sum[2] / count;
        }
    }
}

/// The first source pixel at `v`, and the one after the last before `v`.
fn span(v: f64, limit: u32) usize {
    return @intFromFloat(std.math.clamp(@floor(v), 0, @as(f64, @floatFromInt(limit - 1))));
}

fn spanEnd(v: f64, limit: u32) usize {
    return @intFromFloat(std.math.clamp(@round(v), 0, @as(f64, @floatFromInt(limit))));
}

/// A 4x4 ordered dither, in eighths of a 5-bit step.
const bayer = [4][4]u8{ .{ 0, 8, 2, 10 }, .{ 12, 4, 14, 6 }, .{ 3, 11, 1, 9 }, .{ 15, 7, 13, 5 } };

/// 0xAARRGGBB as BGR565 (the GPU's: red in the low 5 bits), dithered by
/// its place.
fn dither565(px: u32, x: u32, y: u32) u16 {
    const t: u32 = bayer[y & 3][x & 3];
    const r: u32 = @min((px >> 16 & 0xff) + t / 2, 255) >> 3;
    const g: u32 = @min((px >> 8 & 0xff) + t / 4, 255) >> 2;
    const b: u32 = @min((px & 0xff) + t / 2, 255) >> 3;
    return @intCast(r | g << 5 | b << 11);
}

/// Makes the background image ready on a thread: `want` says which (or
/// none), and `poll` (each turn of the shell's loop) gives what is ready.
pub const Loader = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    /// Its last rows kept as shown (`Prepared.bottom`).
    bottom_rows: u32,
    /// How the image wanted is made ready.
    kind: Kind = .bgr565,
    /// The image wanted, and the one last given by `poll`.
    wanted: appearance.ImagePath = .{},
    given: appearance.ImagePath = .{},
    job: ?*Job = null,

    const Job = struct {
        path: appearance.ImagePath,
        kind: Kind,
        thread: std.Thread = undefined,
        done: std.atomic.Value(bool) = .init(false),
        result: anyerror!Prepared = error.NotDone,

        fn run(j: *Job, l: *const Loader) void {
            j.result = prepare(l.gpa, j.path.slice().?, l.width, l.height, j.kind, l.bottom_rows);
            j.done.store(true, .release);
        }
    };

    pub const Outcome = union(enum) {
        /// The image wanted, ready (the caller frees it).
        image: Prepared,
        /// No image is wanted any more.
        none,
        /// It could not be read (or is not a PNG or a built-in one).
        failed: anyerror,
    };

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, bottom_rows: u32) Loader {
        return .{ .gpa = gpa, .width = width, .height = height, .bottom_rows = bottom_rows };
    }

    /// Waits for the job under way, and lets it go.
    pub fn deinit(l: *Loader) void {
        if (l.job) |j| {
            j.thread.join();
            if (j.result) |*p| p.deinit(l.gpa) else |_| {}
            l.gpa.destroy(j);
            l.job = null;
        }
    }

    /// The image to show (null: none), made ready as `kind`.
    pub fn want(l: *Loader, path: ?[]const u8, kind: Kind) void {
        l.wanted = if (path) |p| .of(p) else .{};
        l.kind = kind;
    }

    /// What is ready since the last call, if anything changed: starts
    /// making the image wanted when nothing else is being made.
    pub fn poll(l: *Loader) ?Outcome {
        if (l.job) |j| {
            if (!j.done.load(.acquire)) return null;
            j.thread.join();
            l.job = null;
            defer l.gpa.destroy(j);
            // Wanted still: it is given; otherwise, made for nothing.
            if (std.meta.eql(j.path, l.wanted)) {
                l.given = j.path;
                if (j.result) |p| return .{ .image = p } else |err| return .{ .failed = err };
            }
            if (j.result) |*p| p.deinit(l.gpa) else |_| {}
        }
        if (std.meta.eql(l.wanted, l.given)) return null;
        if (l.wanted.slice() == null) {
            l.given = .{};
            return .none;
        }
        const j = l.gpa.create(Job) catch |err| return .{ .failed = err };
        j.* = .{ .path = l.wanted, .kind = l.kind };
        j.thread = std.Thread.spawn(.{}, Job.run, .{ j, l }) catch |err| {
            l.gpa.destroy(j);
            l.given = l.wanted;
            return .{ .failed = err };
        };
        l.job = j;
        return null;
    }
};

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const linux = std.os.linux;

test "an image is scaled to cover the screen, cropped in the middle" {
    // 4 by 2: left half red, right half blue, a green column in the
    // middle two.
    const src = [_]u32{ 0xffff0000, 0xff00ff00, 0xff00ff00, 0xff0000ff, 0xffff0000, 0xff00ff00, 0xff00ff00, 0xff0000ff };
    // Onto a square: the middle two columns, each 2 by 2.
    var dst: [16]u32 = undefined;
    cover(&src, 4, 2, &dst, 4, 4);
    for (dst) |px| try testing.expectEqual(@as(u32, 0xff00ff00), px);
    // Halved: averages.
    var half: [2]u32 = undefined;
    cover(&src, 4, 2, &half, 2, 1);
    try testing.expectEqual(@as(u32, 0xff7f7f00), half[0]);
    try testing.expectEqual(@as(u32, 0xff007f7f), half[1]);
}

test "BGR565 is dithered: a level between two steps comes out as both" {
    const pixels: [16]u32 = @splat(0xff848484);
    var p = try fromPixels(testing.allocator, &pixels, 4, 4, .bgr565, 0);
    defer p.deinit(testing.allocator);
    var low: usize = 0;
    var high: usize = 0;
    for (0..16) |i| {
        const red = std.mem.readInt(u16, p.data[i * 2 ..][0..2], .little) & 31;
        if (red == 0x84 >> 3) low += 1 else if (red == (0x84 >> 3) + 1) high += 1;
    }
    try testing.expect(low > 0 and high > 0 and low + high == 16);
}

test "the bottom rows are kept as the GPU shows them, for the dock's overlay" {
    var pixels: [8 * 8]u32 = undefined;
    for (&pixels, 0..) |*px, i| px.* = 0xff000000 | @as(u32, @intCast(i * 4)) << 16 | @as(u32, @intCast(i * 3)) << 8 | 0x40;
    // ETC1: the blocks decoded.
    var e = try fromPixels(testing.allocator, &pixels, 8, 8, .{ .etc1 = .standard }, 3);
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8 * 3), e.bottom.len);
    var blocks: [4]u64 = undefined;
    etc1.encode(&pixels, 8, 8, &blocks);
    try testing.expectEqual(etc1.decodeBlock(blocks[3])[1 * 4 + 2], e.bottom[0 * 8 + 6]);
    try testing.expectEqual(etc1.decodeBlock(blocks[2])[3 * 4 + 1], e.bottom[2 * 8 + 1]);
    // BGR565: the dithered pixels, widened again.
    var r = try fromPixels(testing.allocator, &pixels, 8, 8, .bgr565, 2);
    defer r.deinit(testing.allocator);
    const v = std.mem.readInt(u16, r.data[(7 * 8 + 5) * 2 ..][0..2], .little);
    try testing.expectEqual(expand565(v), r.bottom[1 * 8 + 5]);
    try testing.expectEqual(@as(u32, 0xffffffff), expand565(0xffff));
}

test "the loader makes the image wanted on a thread, and says when none is" {
    // A 40 by 30 PNG, shown on a 16 by 16 screen.
    var pixels: [40 * 30]u32 = undefined;
    for (&pixels, 0..) |*px, i| px.* = 0xff000000 | @as(u32, @intCast(i % 40 * 6)) << 16 | 0x4080;
    const data = try png.encode(testing.allocator, &pixels, 40, 30);
    defer testing.allocator.free(data);
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-background-test-{d}.png", .{linux.getpid()}, 0);
    try sys.files.writeNew(path, data);
    defer _ = linux.unlink(path);

    var l: Loader = .init(testing.allocator, 16, 16, 3);
    defer l.deinit();
    try testing.expect(l.poll() == null);
    l.want(path, .{ .etc1 = .standard });
    const outcome = while (true) {
        if (l.poll()) |o| break o;
        std.Thread.yield() catch {};
    };
    var image = outcome.image;
    defer image.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, etc1.imageSize(16, 16)), image.data.len);
    // Nothing more, until another is wanted; then none.
    try testing.expect(l.poll() == null);
    l.want(null, .bgr565);
    try testing.expect(l.poll().? == .none);
    // One that is not there fails.
    l.want("/tmp/dazzle-background-test-missing.png", .bgr565);
    const missing = while (true) {
        if (l.poll()) |o| break o;
        std.Thread.yield() catch {};
    };
    try testing.expect(missing == .failed);
}

test "a built-in background's blocks are used as they are at its size, and decoded for another" {
    var pixels: [8 * 8]u32 = undefined;
    for (&pixels, 0..) |*px, i| px.* = 0xff000000 | @as(u32, @intCast(i * 4)) << 16 | 0x2040;
    var blocks: [4]u64 = undefined;
    etc1.encode(&pixels, 8, 8, &blocks);
    var file: [12 + 4 * 8]u8 = undefined;
    @memcpy(file[0..4], "DZE1");
    std.mem.writeInt(u32, file[4..8], 8, .little);
    std.mem.writeInt(u32, file[8..12], 8, .little);
    for (blocks, 0..) |b, i| std.mem.writeInt(u64, file[12 + i * 8 ..][0..8], b, .little);

    // The same size, as ETC1: the blocks, laid out, not compressed again.
    var same = try fromEtc1File(testing.allocator, &file, 8, 8, .{ .etc1 = .reversed }, 2);
    defer same.deinit(testing.allocator);
    var want: [etc1.imageSize(8, 8)]u8 = @splat(0);
    etc1.upload(&want, 8, 8, &blocks, .reversed);
    try testing.expectEqualSlices(u8, &want, same.data);
    try testing.expectEqual(etc1.decodeBlock(blocks[2])[3 * 4 + 1], same.bottom[1 * 8 + 1]);

    // Another size, or BGR565: decoded and scaled, as a PNG would be.
    var small = try fromEtc1File(testing.allocator, &file, 4, 4, .bgr565, 0);
    defer small.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4 * 4 * 2), small.data.len);

    // Not one: refused.
    try testing.expectError(error.NotEtc1, fromEtc1File(testing.allocator, "PNG?", 8, 8, .bgr565, 0));
    try testing.expectError(error.NotEtc1, fromEtc1File(testing.allocator, file[0..20], 8, 8, .bgr565, 0));
}
