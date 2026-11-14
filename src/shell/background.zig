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
//! it is RGB565 instead (4 MB), dithered so smooth skies do not band.

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
    /// RGB565 pixels, row by row (the renderer lays them out).
    rgb565,
};

/// An image ready for the GPU: `data` as `kind` says, `width` by `height`.
pub const Prepared = struct {
    data: []u8,
    width: u32,
    height: u32,
    kind: Kind,

    pub fn deinit(p: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(p.data);
    }
};

/// The biggest image file read.
pub const max_file_size = 64 * 1024 * 1024;

/// Reads the PNG at `path` and makes it ready for a screen `width` by
/// `height`, as `kind`.
pub fn prepare(gpa: std.mem.Allocator, path: []const u8, width: u32, height: u32, kind: Kind) !Prepared {
    var path_buf: [appearance.ImagePath.max_len + 1]u8 = undefined;
    const pathz = try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0);
    const data = try sys.readFileAlloc(gpa, pathz, max_file_size);
    defer gpa.free(data);
    const image = try png.decode(gpa, data);
    defer gpa.free(image.pixels);
    const pixels = try gpa.alloc(u32, @as(usize, width) * height);
    defer gpa.free(pixels);
    cover(image.pixels, image.width, image.height, pixels, width, height);
    return fromPixels(gpa, pixels, width, height, kind);
}

/// `pixels` (`width` by `height`) ready for the GPU, as `kind`.
pub fn fromPixels(gpa: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, kind: Kind) !Prepared {
    switch (kind) {
        .etc1 => |order| {
            const n = etc1.blocksOf(width, height);
            const blocks = try gpa.alloc(u64, n[0] * n[1]);
            defer gpa.free(blocks);
            etc1.encode(pixels, width, height, blocks);
            const out = try gpa.alloc(u8, etc1.imageSize(width, height));
            @memset(out, 0);
            etc1.upload(out, width, height, blocks, order);
            return .{ .data = out, .width = width, .height = height, .kind = kind };
        },
        .rgb565 => {
            const out = try gpa.alloc(u8, @as(usize, width) * height * 2);
            for (0..height) |y| for (0..width) |x| {
                const px = pixels[y * width + x];
                std.mem.writeInt(u16, out[(y * width + x) * 2 ..][0..2], dither565(px, @intCast(x), @intCast(y)), .little);
            };
            return .{ .data = out, .width = width, .height = height, .kind = kind };
        },
    }
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

/// 0xAARRGGBB as RGB565 (the GPU's: red in the low 5 bits), dithered by
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
    /// How the image wanted is made ready.
    kind: Kind = .rgb565,
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
            j.result = prepare(l.gpa, j.path.slice().?, l.width, l.height, j.kind);
            j.done.store(true, .release);
        }
    };

    pub const Outcome = union(enum) {
        /// The image wanted, ready (the caller frees it).
        image: Prepared,
        /// No image is wanted any more.
        none,
        /// It could not be read (or is not a PNG).
        failed: anyerror,
    };

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) Loader {
        return .{ .gpa = gpa, .width = width, .height = height };
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

test "RGB565 is dithered: a level between two steps comes out as both" {
    const pixels: [16]u32 = @splat(0xff848484);
    var p = try fromPixels(testing.allocator, &pixels, 4, 4, .rgb565);
    defer p.deinit(testing.allocator);
    var low: usize = 0;
    var high: usize = 0;
    for (0..16) |i| {
        const red = std.mem.readInt(u16, p.data[i * 2 ..][0..2], .little) & 31;
        if (red == 0x84 >> 3) low += 1 else if (red == (0x84 >> 3) + 1) high += 1;
    }
    try testing.expect(low > 0 and high > 0 and low + high == 16);
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

    var l: Loader = .init(testing.allocator, 16, 16);
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
    l.want(null, .rgb565);
    try testing.expect(l.poll().? == .none);
    // One that is not there fails.
    l.want("/tmp/dazzle-background-test-missing.png", .rgb565);
    const missing = while (true) {
        if (l.poll()) |o| break o;
        std.Thread.yield() catch {};
    };
    try testing.expect(missing == .failed);
}
