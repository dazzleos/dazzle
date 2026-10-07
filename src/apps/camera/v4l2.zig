//! The parts of Video4Linux2 (videodev2.h) and its sub-device interface
//! (v4l2-subdev.h) the camera uses: structures laid out as the kernel's,
//! ioctl numbers, and the codes for raw Bayer formats. The layouts differ
//! between 32-bit ARM (where Dazzle runs) and 64-bit hosts (where the
//! tests run); the tests check both against the numbers the kernel's own
//! headers give (a program built from them for each).
//!
//! Buffers use the 64-bit time layout (the kernel's native one on 32-bit
//! ARM since Linux 5.6), so their ioctls are the ones without _TIME32.

const std = @import("std");
const linux = std.os.linux;

pub const Capability = extern struct {
    driver: [16]u8,
    card: [32]u8,
    bus_info: [32]u8,
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [3]u32,
};

pub const PixFormat = extern struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32 = 0,
    priv: u32 = 0,
    flags: u32 = 0,
    ycbcr_enc: u32 = 0,
    quantization: u32 = 0,
    xfer_func: u32 = 0,
};

pub const Format = extern struct {
    type: u32,
    fmt: extern union {
        pix: PixFormat,
        raw_data: [200]u8,
        // Some of the kernel's members hold pointers.
        _align: usize,
    },
};

pub const RequestBuffers = extern struct {
    count: u32,
    type: u32,
    memory: u32,
    capabilities: u32 = 0,
    flags: u8 = 0,
    reserved: [3]u8 = @splat(0),
};

pub const Timecode = extern struct {
    type: u32,
    flags: u32,
    frames: u8,
    seconds: u8,
    minutes: u8,
    hours: u8,
    userbits: [4]u8,
};

pub const Buffer = extern struct {
    index: u32 = 0,
    type: u32 = 0,
    bytesused: u32 = 0,
    flags: u32 = 0,
    field: u32 = 0,
    timestamp: extern struct { sec: i64, usec: i64 } = .{ .sec = 0, .usec = 0 },
    timecode: Timecode = std.mem.zeroes(Timecode),
    sequence: u32 = 0,
    memory: u32 = 0,
    m: extern union { offset: u32, userptr: usize, fd: i32 } = .{ .userptr = 0 },
    length: u32 = 0,
    reserved2: u32 = 0,
    request_fd: i32 = 0,
};

pub const Control = extern struct {
    id: u32,
    value: i32,
};

pub const QueryControl = extern struct {
    id: u32,
    type: u32 = 0,
    name: [32]u8 = @splat(0),
    minimum: i32 = 0,
    maximum: i32 = 0,
    step: i32 = 0,
    default_value: i32 = 0,
    flags: u32 = 0,
    reserved: [2]u32 = @splat(0),
};

pub const MbusFramefmt = extern struct {
    width: u32,
    height: u32,
    code: u32,
    field: u32 = field_none,
    colorspace: u32 = 0,
    ycbcr_enc: u16 = 0,
    quantization: u16 = 0,
    xfer_func: u16 = 0,
    flags: u16 = 0,
    reserved: [10]u16 = @splat(0),
};

pub const SubdevFormat = extern struct {
    which: u32 = format_active,
    pad: u32,
    format: MbusFramefmt,
    stream: u32 = 0,
    reserved: [7]u32 = @splat(0),
};

pub const SubdevMbusCodeEnum = extern struct {
    pad: u32,
    index: u32,
    code: u32 = 0,
    which: u32 = format_active,
    flags: u32 = 0,
    stream: u32 = 0,
    reserved: [6]u32 = @splat(0),
};

pub const SubdevFrameSizeEnum = extern struct {
    index: u32,
    pad: u32,
    code: u32,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
    which: u32 = format_active,
    stream: u32 = 0,
    reserved: [7]u32 = @splat(0),
};

const IOCTL = linux.IOCTL;

pub const querycap = IOCTL.IOR('V', 0, Capability);
pub const g_fmt = IOCTL.IOWR('V', 4, Format);
pub const s_fmt = IOCTL.IOWR('V', 5, Format);
pub const reqbufs = IOCTL.IOWR('V', 8, RequestBuffers);
pub const querybuf = IOCTL.IOWR('V', 9, Buffer);
pub const qbuf = IOCTL.IOWR('V', 15, Buffer);
pub const dqbuf = IOCTL.IOWR('V', 17, Buffer);
pub const streamon = IOCTL.IOW('V', 18, c_int);
pub const streamoff = IOCTL.IOW('V', 19, c_int);
pub const g_ctrl = IOCTL.IOWR('V', 27, Control);
pub const s_ctrl = IOCTL.IOWR('V', 28, Control);
pub const queryctrl = IOCTL.IOWR('V', 36, QueryControl);
pub const subdev_g_fmt = IOCTL.IOWR('V', 4, SubdevFormat);
pub const subdev_s_fmt = IOCTL.IOWR('V', 5, SubdevFormat);
pub const subdev_enum_mbus_code = IOCTL.IOWR('V', 2, SubdevMbusCodeEnum);
pub const subdev_enum_frame_size = IOCTL.IOWR('V', 74, SubdevFrameSizeEnum);

pub const buf_type_video_capture = 1;
pub const memory_mmap = 1;
pub const field_none = 1;
pub const format_active = 1;
pub const cap_video_capture = 0x1;
pub const ctrl_flag_disabled = 0x1;

/// Controls (v4l2-controls.h).
pub const cid = struct {
    pub const auto_white_balance = 0x0098090c;
    pub const exposure = 0x00980911;
    pub const autogain = 0x00980912;
    pub const hflip = 0x00980914;
    pub const vflip = 0x00980915;
    pub const exposure_auto = 0x009a0901;
    pub const camera_sensor_rotation = 0x009a0923;
    pub const vblank = 0x009e0901;
    pub const hblank = 0x009e0902;
    pub const analogue_gain = 0x009e0903;
    pub const digital_gain = 0x009f0905;
};
pub const exposure_auto_on = 0;

/// The order of a Bayer pattern's colours, from the top left: its first
/// row's two, then its second row's.
pub const Bayer = enum { rggb, grbg, gbrg, bggr };

/// A raw format the camera can capture: its media bus code (between the
/// sensor and Unicam), Unicam's pixel format for it in memory, and its
/// Bayer order and bits per sample (8, or 10 packed four to five bytes).
pub const RawFormat = struct { code: u32, fourcc: u32, bayer: Bayer, bits: u8 };

pub const raw_formats = [_]RawFormat{
    .{ .code = 0x3014, .fourcc = fourcc("RGGB"), .bayer = .rggb, .bits = 8 },
    .{ .code = 0x3002, .fourcc = fourcc("GRBG"), .bayer = .grbg, .bits = 8 },
    .{ .code = 0x3013, .fourcc = fourcc("GBRG"), .bayer = .gbrg, .bits = 8 },
    .{ .code = 0x3001, .fourcc = fourcc("BA81"), .bayer = .bggr, .bits = 8 },
    .{ .code = 0x300f, .fourcc = fourcc("pRAA"), .bayer = .rggb, .bits = 10 },
    .{ .code = 0x300a, .fourcc = fourcc("pgAA"), .bayer = .grbg, .bits = 10 },
    .{ .code = 0x300e, .fourcc = fourcc("pGAA"), .bayer = .gbrg, .bits = 10 },
    .{ .code = 0x3007, .fourcc = fourcc("pBAA"), .bayer = .bggr, .bits = 10 },
};

pub fn rawFormat(code: u32) ?RawFormat {
    for (raw_formats) |f| if (f.code == code) return f;
    return null;
}

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

const testing = std.testing;

test "structures and ioctls are laid out as the kernel's" {
    const arm = @import("builtin").cpu.arch == .arm;
    try testing.expectEqual(@as(usize, 104), @sizeOf(Capability));
    try testing.expectEqual(@as(usize, 48), @sizeOf(PixFormat));
    try testing.expectEqual(@as(usize, if (arm) 204 else 208), @sizeOf(Format));
    try testing.expectEqual(@as(usize, if (arm) 4 else 8), @offsetOf(Format, "fmt"));
    try testing.expectEqual(@as(usize, 20), @sizeOf(RequestBuffers));
    try testing.expectEqual(@as(usize, if (arm) 80 else 88), @sizeOf(Buffer));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Buffer, "timestamp"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(Buffer, "sequence"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(Buffer, "m"));
    try testing.expectEqual(@as(usize, if (arm) 68 else 72), @offsetOf(Buffer, "length"));
    try testing.expectEqual(@as(usize, 68), @sizeOf(QueryControl));
    try testing.expectEqual(@as(usize, 40), @offsetOf(QueryControl, "minimum"));
    try testing.expectEqual(@as(usize, 48), @sizeOf(MbusFramefmt));
    try testing.expectEqual(@as(usize, 88), @sizeOf(SubdevFormat));
    try testing.expectEqual(@as(usize, 56), @offsetOf(SubdevFormat, "stream"));
    try testing.expectEqual(@as(usize, 48), @sizeOf(SubdevMbusCodeEnum));
    try testing.expectEqual(@as(usize, 64), @sizeOf(SubdevFrameSizeEnum));

    try testing.expectEqual(@as(u32, 0x80685600), querycap);
    try testing.expectEqual(@as(u32, if (arm) 0xc0cc5605 else 0xc0d05605), s_fmt);
    try testing.expectEqual(@as(u32, 0xc0145608), reqbufs);
    try testing.expectEqual(@as(u32, if (arm) 0xc050560f else 0xc058560f), qbuf);
    try testing.expectEqual(@as(u32, if (arm) 0xc0505611 else 0xc0585611), dqbuf);
    try testing.expectEqual(@as(u32, 0x40045612), streamon);
    try testing.expectEqual(@as(u32, 0xc008561c), s_ctrl);
    try testing.expectEqual(@as(u32, 0xc0445624), queryctrl);
    try testing.expectEqual(@as(u32, 0xc0585605), subdev_s_fmt);
    try testing.expectEqual(@as(u32, 0xc0305602), subdev_enum_mbus_code);
    try testing.expectEqual(@as(u32, 0xc040564a), subdev_enum_frame_size);
}

test "raw formats' codes" {
    try testing.expectEqual(@as(u32, 0x42474752), rawFormat(0x3014).?.fourcc);
    try testing.expectEqual(@as(u32, 0x31384142), rawFormat(0x3001).?.fourcc);
    try testing.expectEqual(@as(u32, 0x41415270), rawFormat(0x300f).?.fourcc);
    try testing.expectEqual(@as(u32, 0x41414270), rawFormat(0x3007).?.fourcc);
    try testing.expectEqual(Bayer.gbrg, rawFormat(0x300e).?.bayer);
    try testing.expectEqual(@as(?RawFormat, null), rawFormat(0x2008));
}
