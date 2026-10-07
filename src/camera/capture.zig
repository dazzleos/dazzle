//! Capturing raw frames from the Camera Module, with the kernel's Unicam
//! driver: the sensor (an IMX219 or OV5647, a V4L2 sub-device) sends
//! frames over CSI-2 to Unicam (another sub-device), which writes them to
//! memory through its video device, "unicam-image".
//!
//! Opening the camera finds the three in /sys/class/video4linux, turns the
//! picture the right way up (a sensor mounted upside down, as the Camera
//! Modules are, says so with its rotation), picks a mode (`chooseMode`:
//! the whole field of view, binned, about 2 megapixels at most) and a raw
//! format (8 bits if the sensor has it, else 10 packed), sets that format
//! on the sensor, on Unicam and on the video device (all must agree, or
//! streaming fails), and starts streaming into four buffers mapped into
//! memory. `next` gives each frame as it comes; `release` hands it back.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const v4l2 = @import("v4l2.zig");

const print = sys.print;

pub const n_buffers = 4;
const sysfs = "/sys/class/video4linux";

pub const Size = struct { width: u32, height: u32 };

/// A raw frame: `height` rows of `stride` bytes.
pub const Frame = struct {
    data: []const u8,
    index: u32,
    sequence: u32,
};

pub const Error = error{ NoCamera, NoMode, Unsupported } || sys.Error;

pub const Camera = struct {
    video: linux.fd_t,
    sensor: linux.fd_t,
    unicam: linux.fd_t,
    /// The sensor's name, as its driver gives it ("imx219 10-0010").
    name: [32]u8 = @splat(0),
    name_len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: v4l2.RawFormat = undefined,
    maps: [n_buffers][]align(std.heap.page_size_min) u8 = undefined,
    n_maps: usize = 0,
    streaming: bool = false,

    /// Finds the camera, sets it up and starts streaming.
    pub fn open() Error!Camera {
        var paths: Paths = .{};
        try paths.find();
        var c: Camera = .{
            .video = try sys.open(paths.path(.video), .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }),
            .sensor = undefined,
            .unicam = undefined,
        };
        errdefer sys.close(c.video);
        c.sensor = try sys.open(paths.path(.sensor), .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        errdefer sys.close(c.sensor);
        c.unicam = try sys.open(paths.path(.unicam), .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        errdefer sys.close(c.unicam);
        @memcpy(c.name[0..paths.sensor_name_len], paths.sensor_name[0..paths.sensor_name_len]);
        c.name_len = paths.sensor_name_len;
        try c.configure();
        errdefer c.unmap();
        try c.start();
        return c;
    }

    pub fn sensorName(c: *const Camera) []const u8 {
        return c.name[0..c.name_len];
    }

    pub fn close(c: *Camera) void {
        if (c.streaming) {
            var t: c_int = v4l2.buf_type_video_capture;
            _ = linux.ioctl(c.video, v4l2.streamoff, @intFromPtr(&t));
        }
        c.unmap();
        sys.close(c.unicam);
        sys.close(c.sensor);
        sys.close(c.video);
    }

    fn unmap(c: *Camera) void {
        for (c.maps[0..c.n_maps]) |m| _ = linux.munmap(m.ptr, m.len);
        c.n_maps = 0;
    }

    fn configure(c: *Camera) Error!void {
        // The right way up: flipped both ways for a sensor mounted upside
        // down. (Flips change the Bayer order, so they come first.)
        if (c.control(v4l2.cid.camera_sensor_rotation)) |rotation| if (rotation == 180) {
            c.setControl(v4l2.cid.hflip, 1) catch {};
            c.setControl(v4l2.cid.vflip, 1) catch {};
        };
        const format = try c.chooseFormat();
        const sizes = try c.modeSizes(format.code);
        const size = chooseMode(sizes.slice()) orelse return error.NoMode;

        var sf: v4l2.SubdevFormat = .{ .pad = 0, .format = .{ .width = size.width, .height = size.height, .code = format.code } };
        _ = try sys.check(linux.ioctl(c.sensor, v4l2.subdev_s_fmt, @intFromPtr(&sf)));
        // The sensor may have adjusted it.
        c.format = v4l2.rawFormat(sf.format.code) orelse return error.Unsupported;
        // Unicam's input (it passes it through to its output).
        var uf: v4l2.SubdevFormat = .{ .pad = 0, .format = sf.format };
        _ = try sys.check(linux.ioctl(c.unicam, v4l2.subdev_s_fmt, @intFromPtr(&uf)));

        var vf: v4l2.Format = .{ .type = v4l2.buf_type_video_capture, .fmt = .{ .pix = .{
            .width = sf.format.width,
            .height = sf.format.height,
            .pixelformat = c.format.fourcc,
            .field = v4l2.field_none,
            .bytesperline = 0,
            .sizeimage = 0,
        } } };
        _ = try sys.check(linux.ioctl(c.video, v4l2.s_fmt, @intFromPtr(&vf)));
        if (vf.fmt.pix.pixelformat != c.format.fourcc) return error.Unsupported;
        c.width = vf.fmt.pix.width;
        c.height = vf.fmt.pix.height;
        c.stride = vf.fmt.pix.bytesperline;
        print("dazzle-camera: {s}, {d}x{d}, {d}-bit {s}, {d} bytes a row\n", .{ c.sensorName(), c.width, c.height, c.format.bits, @tagName(c.format.bayer), c.stride });
    }

    /// The sensor's raw format with the fewest bits (8 rather than 10:
    /// a picture on this screen needs no more, and they are half the
    /// memory to read).
    fn chooseFormat(c: *Camera) Error!v4l2.RawFormat {
        var best: ?v4l2.RawFormat = null;
        var i: u32 = 0;
        while (i < 32) : (i += 1) {
            var e: v4l2.SubdevMbusCodeEnum = .{ .pad = 0, .index = i };
            if (linux.errno(linux.ioctl(c.sensor, v4l2.subdev_enum_mbus_code, @intFromPtr(&e))) != .SUCCESS) break;
            const f = v4l2.rawFormat(e.code) orelse continue;
            if (best == null or f.bits < best.?.bits) best = f;
        }
        return best orelse error.Unsupported;
    }

    const Sizes = struct {
        items: [16]Size = undefined,
        len: usize = 0,
        fn slice(s: *const Sizes) []const Size {
            return s.items[0..s.len];
        }
    };

    fn modeSizes(c: *Camera, code: u32) Error!Sizes {
        var out: Sizes = .{};
        var i: u32 = 0;
        while (out.len < out.items.len) : (i += 1) {
            var e: v4l2.SubdevFrameSizeEnum = .{ .index = i, .pad = 0, .code = code };
            if (linux.errno(linux.ioctl(c.sensor, v4l2.subdev_enum_frame_size, @intFromPtr(&e))) != .SUCCESS) break;
            out.items[out.len] = .{ .width = e.max_width, .height = e.max_height };
            out.len += 1;
        }
        if (out.len == 0) return error.NoMode;
        return out;
    }

    fn start(c: *Camera) Error!void {
        var req: v4l2.RequestBuffers = .{ .count = n_buffers, .type = v4l2.buf_type_video_capture, .memory = v4l2.memory_mmap };
        _ = try sys.check(linux.ioctl(c.video, v4l2.reqbufs, @intFromPtr(&req)));
        if (req.count == 0) return error.Unsupported;
        for (0..@min(req.count, n_buffers)) |i| {
            var b: v4l2.Buffer = .{ .index = @intCast(i), .type = v4l2.buf_type_video_capture, .memory = v4l2.memory_mmap };
            _ = try sys.check(linux.ioctl(c.video, v4l2.querybuf, @intFromPtr(&b)));
            const rc = linux.mmap(null, b.length, .{ .READ = true }, .{ .TYPE = .SHARED }, c.video, b.m.offset);
            if (linux.errno(rc) != .SUCCESS) return error.Unsupported;
            c.maps[i] = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(rc))[0..b.length];
            c.n_maps = i + 1;
            _ = try sys.check(linux.ioctl(c.video, v4l2.qbuf, @intFromPtr(&b)));
        }
        var t: c_int = v4l2.buf_type_video_capture;
        _ = try sys.check(linux.ioctl(c.video, v4l2.streamon, @intFromPtr(&t)));
        c.streaming = true;
    }

    /// The file to wait on for frames.
    pub fn fd(c: *const Camera) linux.fd_t {
        return c.video;
    }

    /// The next frame, if one has come; `release` it when done with it.
    pub fn next(c: *Camera) Error!?Frame {
        var b: v4l2.Buffer = .{ .type = v4l2.buf_type_video_capture, .memory = v4l2.memory_mmap };
        switch (linux.errno(linux.ioctl(c.video, v4l2.dqbuf, @intFromPtr(&b)))) {
            .SUCCESS => {},
            .AGAIN => return null,
            else => |e| return sys.errorFromErrno(e),
        }
        if (b.index >= c.n_maps) return error.Unsupported;
        return .{ .data = c.maps[b.index][0..@min(b.bytesused, c.maps[b.index].len)], .index = b.index, .sequence = b.sequence };
    }

    pub fn release(c: *Camera, f: Frame) void {
        var b: v4l2.Buffer = .{ .index = f.index, .type = v4l2.buf_type_video_capture, .memory = v4l2.memory_mmap };
        _ = linux.ioctl(c.video, v4l2.qbuf, @intFromPtr(&b));
    }

    /// A sensor control's value; null if it has none.
    pub fn control(c: *const Camera, id: u32) ?i32 {
        var ctl: v4l2.Control = .{ .id = id, .value = 0 };
        if (linux.errno(linux.ioctl(c.sensor, v4l2.g_ctrl, @intFromPtr(&ctl))) != .SUCCESS) return null;
        return ctl.value;
    }

    pub fn setControl(c: *const Camera, id: u32, value: i32) Error!void {
        var ctl: v4l2.Control = .{ .id = id, .value = value };
        _ = try sys.check(linux.ioctl(c.sensor, v4l2.s_ctrl, @intFromPtr(&ctl)));
    }

    pub const Range = struct { min: i32, max: i32, default: i32 };

    /// A sensor control's range (it can change: the exposure's longest
    /// with the frame's length); null if it has none.
    pub fn range(c: *const Camera, id: u32) ?Range {
        var q: v4l2.QueryControl = .{ .id = id };
        if (linux.errno(linux.ioctl(c.sensor, v4l2.queryctrl, @intFromPtr(&q))) != .SUCCESS) return null;
        if (q.flags & v4l2.ctrl_flag_disabled != 0) return null;
        return .{ .min = q.minimum, .max = q.maximum, .default = q.default_value };
    }
};

/// The mode to capture in, of the sensor's: the whole picture (closest to
/// 4:3, its full field of view), as big as fits in about 2 megapixels
/// (binned modes; the full-size ones are too slow and too much memory
/// for a Pi Zero); else the smallest.
pub fn chooseMode(sizes: []const Size) ?Size {
    const max_pixels = 2_100_000;
    var best: ?Size = null;
    for (sizes) |s| {
        if (@as(u64, s.width) * s.height > max_pixels) continue;
        const b = best orelse {
            best = s;
            continue;
        };
        const d = aspectError(s);
        const bd = aspectError(b);
        if (d < bd - 0.01 or (@abs(d - bd) <= 0.01 and s.width * s.height > b.width * b.height)) best = s;
    }
    if (best) |b| return b;
    var smallest: ?Size = null;
    for (sizes) |s| {
        if (smallest == null or s.width * s.height < smallest.?.width * smallest.?.height) smallest = s;
    }
    return smallest;
}

fn aspectError(s: Size) f32 {
    return @abs(@as(f32, @floatFromInt(s.width)) / @as(f32, @floatFromInt(s.height)) - 4.0 / 3.0);
}

/// Where the camera's three devices are, found by their names.
const Paths = struct {
    video_n: ?u32 = null,
    sensor_n: ?u32 = null,
    unicam_n: ?u32 = null,
    sensor_name: [32]u8 = undefined,
    sensor_name_len: usize = 0,
    buf: [32]u8 = undefined,

    const Which = enum { video, sensor, unicam };

    fn find(p: *Paths) Error!void {
        const dir = sys.open(sysfs, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return error.NoCamera;
        defer sys.close(dir);
        var buf: [2048]u8 align(8) = undefined;
        while (true) {
            const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch break;
            if (n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                const entry = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
                at += reclen;
                p.consider(entry);
            }
        }
        if (p.video_n == null or p.sensor_n == null or p.unicam_n == null) return error.NoCamera;
    }

    fn consider(p: *Paths, entry: []const u8) void {
        var name_path_buf: [96]u8 = undefined;
        const name_path = std.fmt.bufPrintZ(&name_path_buf, "{s}/{s}/name", .{ sysfs, entry }) catch return;
        var name_buf: [64]u8 = undefined;
        const name = std.mem.trim(u8, sys.readFile(name_path, &name_buf) orelse return, " \n");
        if (std.mem.startsWith(u8, entry, "video")) {
            const n = std.fmt.parseInt(u32, entry["video".len..], 10) catch return;
            if (std.mem.eql(u8, name, "unicam-image")) p.video_n = n;
        } else if (std.mem.startsWith(u8, entry, "v4l-subdev")) {
            const n = std.fmt.parseInt(u32, entry["v4l-subdev".len..], 10) catch return;
            if (std.mem.eql(u8, name, "unicam")) {
                p.unicam_n = n;
            } else if (isSensor(name)) {
                p.sensor_n = n;
                p.sensor_name_len = @min(name.len, p.sensor_name.len);
                @memcpy(p.sensor_name[0..p.sensor_name_len], name[0..p.sensor_name_len]);
            }
        }
    }

    fn path(p: *Paths, which: Which) [:0]const u8 {
        return switch (which) {
            .video => std.fmt.bufPrintZ(&p.buf, "/dev/video{d}", .{p.video_n.?}),
            .sensor => std.fmt.bufPrintZ(&p.buf, "/dev/v4l-subdev{d}", .{p.sensor_n.?}),
            .unicam => std.fmt.bufPrintZ(&p.buf, "/dev/v4l-subdev{d}", .{p.unicam_n.?}),
        } catch unreachable;
    }
};

/// The sensors the device trees have overlays for.
pub fn isSensor(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "imx219 ") or std.mem.startsWith(u8, name, "ov5647 ");
}

const testing = std.testing;

test "the mode: the whole picture, binned" {
    // The IMX219's modes: full size, 1080p (cropped), binned, and VGA.
    const imx219 = [_]Size{ .{ .width = 3280, .height = 2464 }, .{ .width = 1920, .height = 1080 }, .{ .width = 1640, .height = 1232 }, .{ .width = 640, .height = 480 } };
    try testing.expectEqual(Size{ .width = 1640, .height = 1232 }, chooseMode(&imx219).?);
    // The OV5647's.
    const ov5647 = [_]Size{ .{ .width = 2592, .height = 1944 }, .{ .width = 1920, .height = 1080 }, .{ .width = 1296, .height = 972 }, .{ .width = 640, .height = 480 } };
    try testing.expectEqual(Size{ .width = 1296, .height = 972 }, chooseMode(&ov5647).?);
    // Only big ones: the smallest.
    const big = [_]Size{ .{ .width = 4000, .height = 3000 }, .{ .width = 3000, .height = 2000 } };
    try testing.expectEqual(Size{ .width = 3000, .height = 2000 }, chooseMode(&big).?);
    try testing.expectEqual(@as(?Size, null), chooseMode(&.{}));
}

test "sensors by their drivers' names" {
    try testing.expect(isSensor("imx219 10-0010"));
    try testing.expect(isSensor("ov5647 10-0036"));
    try testing.expect(!isSensor("unicam"));
}
