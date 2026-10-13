//! Raw Linux ALSA kernel interface (`/dev/snd/controlC*` and `/dev/snd/pcmC*D*p`).
//!
//! Defines the kernel UAPI structures and ioctls from `<sound/asound.h>` so
//! Dazzle can enumerate sound cards, adjust hardware mixer volume/mute controls,
//! and stream PCM audio to HDMI (`vc4-hdmi`), the Raspberry Pi 3.5 mm headphone
//! jack (`bcm2835-audio`) and USB audio devices (`snd-usb-audio`) without libc
//! or `alsa-lib`.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const snd_pcm_uframes_t = c_ulong;
pub const snd_pcm_sframes_t = c_long;

// --- PCM stream direction, access and sample formats -------------------------

pub const SNDRV_PCM_STREAM_PLAYBACK: c_int = 0;
pub const SNDRV_PCM_STREAM_CAPTURE: c_int = 1;

pub const SNDRV_PCM_ACCESS_RW_INTERLEAVED: u32 = 3;

pub const SNDRV_PCM_FORMAT_U8: u32 = 1;
pub const SNDRV_PCM_FORMAT_S16_LE: u32 = 2;
pub const SNDRV_PCM_FORMAT_S24_LE: u32 = 6;
pub const SNDRV_PCM_FORMAT_S32_LE: u32 = 10;
pub const SNDRV_PCM_FORMAT_IEC958_SUBFRAME_LE: u32 = 18;

// --- HW_PARAMS mask and interval indices -------------------------------------

pub const SNDRV_PCM_HW_PARAM_ACCESS: usize = 0;
pub const SNDRV_PCM_HW_PARAM_FORMAT: usize = 1;
pub const SNDRV_PCM_HW_PARAM_SUBFORMAT: usize = 2;

pub const SNDRV_PCM_HW_PARAM_FIRST_INTERVAL: usize = 8;
pub const SNDRV_PCM_HW_PARAM_SAMPLE_BITS: usize = 8;
pub const SNDRV_PCM_HW_PARAM_FRAME_BITS: usize = 9;
pub const SNDRV_PCM_HW_PARAM_CHANNELS: usize = 10;
pub const SNDRV_PCM_HW_PARAM_RATE: usize = 11;
pub const SNDRV_PCM_HW_PARAM_PERIOD_TIME: usize = 12;
pub const SNDRV_PCM_HW_PARAM_PERIOD_SIZE: usize = 13;
pub const SNDRV_PCM_HW_PARAM_PERIOD_BYTES: usize = 14;
pub const SNDRV_PCM_HW_PARAM_PERIODS: usize = 15;
pub const SNDRV_PCM_HW_PARAM_BUFFER_TIME: usize = 16;
pub const SNDRV_PCM_HW_PARAM_BUFFER_SIZE: usize = 17;
pub const SNDRV_PCM_HW_PARAM_BUFFER_BYTES: usize = 18;
pub const SNDRV_PCM_HW_PARAM_TICK_TIME: usize = 19;

// --- Control (mixer / card info) structures and ioctls -----------------------

pub const SndCtlCardInfo = extern struct {
    card: c_int = 0,
    pad: c_int = 0,
    id: [16]u8 = @splat(0),
    driver: [16]u8 = @splat(0),
    name: [32]u8 = @splat(0),
    longname: [80]u8 = @splat(0),
    reserved_: [16]u8 = @splat(0),
    mixername: [80]u8 = @splat(0),
    components: [128]u8 = @splat(0),
};

pub const SndPcmInfo = extern struct {
    device: c_uint = 0,
    subdevice: c_uint = 0,
    stream: c_int = SNDRV_PCM_STREAM_PLAYBACK,
    card: c_int = 0,
    id: [64]u8 = @splat(0),
    name: [80]u8 = @splat(0),
    subname: [32]u8 = @splat(0),
    dev_class: c_int = 0,
    dev_subclass: c_int = 0,
    subdevices_count: c_uint = 0,
    subdevices_avail: c_uint = 0,
    sync: [16]u8 = @splat(0),
    reserved: [64]u8 = @splat(0),
};

pub const SndCtlElemId = extern struct {
    numid: c_uint = 0,
    iface: c_int = 0,
    device: c_uint = 0,
    subdevice: c_uint = 0,
    name: [44]u8 = @splat(0),
    index: c_uint = 0,
};

pub const SndCtlElemList = extern struct {
    offset: c_uint = 0,
    space: c_uint = 0,
    used: c_uint = 0,
    count: c_uint = 0,
    pids: ?[*]SndCtlElemId = null,
    reserved: [50]u8 = @splat(0),
};

pub const SNDRV_CTL_ELEM_TYPE_BOOLEAN: c_int = 1;
pub const SNDRV_CTL_ELEM_TYPE_INTEGER: c_int = 2;

pub const SNDRV_CTL_ELEM_ACCESS_READ: c_uint = 1 << 0;
pub const SNDRV_CTL_ELEM_ACCESS_WRITE: c_uint = 1 << 1;
pub const SNDRV_CTL_ELEM_ACCESS_INACTIVE: c_uint = 1 << 8;

pub const SndCtlElemInfo = extern struct {
    id: SndCtlElemId = .{},
    elem_type: c_int = 0,
    access: c_uint = 0,
    count: c_uint = 0,
    owner: c_int = 0,
    value: extern union {
        integer: extern struct {
            min: c_long,
            max: c_long,
            step: c_long,
        },
        reserved: [128]u8,
    } = .{ .reserved = @splat(0) },
    dimen: [4]u16 = @splat(0),
    reserved: [56]u8 = @splat(0),
};

pub const SndCtlElemValue = extern struct {
    id: SndCtlElemId = .{},
    indirect: c_uint = 0,
    value: extern union {
        integer: [128]c_long,
        integer64: [64]i64,
        bytes: [512]u8,
    } = .{ .bytes = @splat(0) },
    reserved: [128]u8 = @splat(0),
};

pub const SNDRV_CTL_IOCTL_CARD_INFO = linux.IOCTL.IOR('U', 0x01, SndCtlCardInfo);
pub const SNDRV_CTL_IOCTL_ELEM_LIST = linux.IOCTL.IOWR('U', 0x10, SndCtlElemList);
pub const SNDRV_CTL_IOCTL_ELEM_INFO = linux.IOCTL.IOWR('U', 0x11, SndCtlElemInfo);
pub const SNDRV_CTL_IOCTL_ELEM_READ = linux.IOCTL.IOWR('U', 0x12, SndCtlElemValue);
pub const SNDRV_CTL_IOCTL_ELEM_WRITE = linux.IOCTL.IOWR('U', 0x13, SndCtlElemValue);
pub const SNDRV_CTL_IOCTL_PCM_NEXT_DEVICE = linux.IOCTL.IOR('U', 0x30, c_int);
pub const SNDRV_CTL_IOCTL_PCM_INFO = linux.IOCTL.IOWR('U', 0x31, SndPcmInfo);

// --- PCM hardware parameters and transfer ioctls -----------------------------

pub const SndMask = extern struct {
    bits: [8]u32 = @splat(0),

    pub fn fill(m: *SndMask) void {
        m.bits = @splat(0xFFFF_FFFF);
    }

    pub fn clear(m: *SndMask) void {
        m.bits = @splat(0);
    }

    pub fn set(m: *SndMask, bit: u32) void {
        if (bit < 256) m.bits[bit >> 5] |= @as(u32, 1) << @intCast(bit & 31);
    }

    pub fn testBit(m: *const SndMask, bit: u32) bool {
        if (bit >= 256) return false;
        return (m.bits[bit >> 5] & (@as(u32, 1) << @intCast(bit & 31))) != 0;
    }

    pub fn only(bit: u32) SndMask {
        var m: SndMask = .{};
        m.set(bit);
        return m;
    }
};

pub const SndInterval = extern struct {
    min: c_uint = 0,
    max: c_uint = 0xFFFF_FFFF,
    flags: c_uint = 0,

    pub fn any() SndInterval {
        return .{ .min = 0, .max = 0xFFFF_FFFF, .flags = 0 };
    }

    pub fn exact(val: u32) SndInterval {
        return .{ .min = val, .max = val, .flags = 1 << 2 }; // integer = 1
    }

    pub fn range(min_val: u32, max_val: u32) SndInterval {
        return .{ .min = min_val, .max = max_val, .flags = 0 };
    }
};

pub const SndPcmHwParams = extern struct {
    flags: c_uint = 0,
    masks: [3]SndMask = @splat(.{}),
    mres: [5]SndMask = @splat(.{}),
    intervals: [12]SndInterval = @splat(.{}),
    ires: [9]SndInterval = @splat(.{}),
    rmask: c_uint = 0,
    cmask: c_uint = 0,
    info: c_uint = 0,
    msbits: c_uint = 0,
    rate_num: c_uint = 0,
    rate_den: c_uint = 0,
    fifo_size: snd_pcm_uframes_t = 0,
    reserved: [64]u8 = @splat(0),

    pub fn initAny() SndPcmHwParams {
        var p: SndPcmHwParams = .{};
        for (&p.masks) |*m| m.fill();
        for (&p.intervals) |*iv| iv.* = SndInterval.any();
        p.rmask = 0xFFFF_FFFF;
        return p;
    }

    pub fn mask(p: *SndPcmHwParams, idx: usize) *SndMask {
        return &p.masks[idx];
    }

    pub fn interval(p: *SndPcmHwParams, param: usize) *SndInterval {
        return &p.intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    }

    pub fn setInterval(p: *SndPcmHwParams, param: usize, iv: SndInterval) void {
        p.intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL] = iv;
        p.rmask |= @as(u32, 1) << @intCast(param);
    }

    pub fn setMask(p: *SndPcmHwParams, param: usize, m: SndMask) void {
        p.masks[param] = m;
        p.rmask |= @as(u32, 1) << @intCast(param);
    }
};

pub const SndXferi = extern struct {
    result: snd_pcm_sframes_t = 0,
    buf: ?*const anyopaque = null,
    frames: snd_pcm_uframes_t = 0,
};

pub const SNDRV_PCM_IOCTL_HW_REFINE = linux.IOCTL.IOWR('A', 0x10, SndPcmHwParams);
pub const SNDRV_PCM_IOCTL_HW_PARAMS = linux.IOCTL.IOWR('A', 0x11, SndPcmHwParams);
pub const SNDRV_PCM_IOCTL_DELAY = linux.IOCTL.IOR('A', 0x21, snd_pcm_sframes_t);
pub const SNDRV_PCM_IOCTL_PREPARE = linux.IOCTL.IO('A', 0x40);
pub const SNDRV_PCM_IOCTL_DROP = linux.IOCTL.IO('A', 0x43);
pub const SNDRV_PCM_IOCTL_DRAIN = linux.IOCTL.IO('A', 0x44);
pub const SNDRV_PCM_IOCTL_WRITEI_FRAMES = linux.IOCTL.IOW('A', 0x50, SndXferi);

// --- Mixer control helpers ---------------------------------------------------

/// Sets all playback volume and mute switch controls on `card` (`0..7`).
/// Returns `true` if at least one hardware playback volume control was found
/// and updated, or `false` if the card has no hardware volume control (e.g.
/// `vc4-hdmi`, which relies on software volume scaling).
pub fn setCardVolume(card: u8, volume_pct: u8, muted: bool) bool {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/dev/snd/controlC{d}", .{card}) catch return false;
    const fd = sys.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch return false;
    defer sys.close(fd);

    var list: SndCtlElemList = .{};
    if (linux.errno(linux.ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, @intFromPtr(&list))) != .SUCCESS) return false;
    if (list.count == 0) return false;

    var ids: [64]SndCtlElemId = undefined;
    const space: u32 = @min(list.count, @as(u32, ids.len));
    list.offset = 0;
    list.space = space;
    list.pids = &ids;
    if (linux.errno(linux.ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, @intFromPtr(&list))) != .SUCCESS) return false;

    const clamped_pct: i64 = @min(@as(i64, volume_pct), 100);
    var set_any_volume = false;

    for (ids[0..@min(list.used, space)]) |id| {
        const name = cStr(&id.name);
        if (isCaptureControl(name)) continue;

        var info: SndCtlElemInfo = .{ .id = .{ .numid = id.numid } };
        if (linux.errno(linux.ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, @intFromPtr(&info))) != .SUCCESS) continue;
        if ((info.access & SNDRV_CTL_ELEM_ACCESS_WRITE) == 0) continue;
        if ((info.access & SNDRV_CTL_ELEM_ACCESS_INACTIVE) != 0) continue;
        const count = @min(info.count, 8);
        if (count == 0) continue;

        if (info.elem_type == SNDRV_CTL_ELEM_TYPE_INTEGER and isVolumeControl(name)) {
            const min_v: i64 = info.value.integer.min;
            const max_v: i64 = info.value.integer.max;
            if (max_v <= min_v) continue;
            const target: c_long = if (muted or clamped_pct == 0)
                @intCast(min_v)
            else
                @intCast(min_v + @divTrunc((max_v - min_v) * clamped_pct + 50, 100));

            var val: SndCtlElemValue = .{ .id = .{ .numid = id.numid } };
            for (0..count) |ch| val.value.integer[ch] = target;
            if (linux.errno(linux.ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, @intFromPtr(&val))) == .SUCCESS) {
                set_any_volume = true;
            }
        } else if (info.elem_type == SNDRV_CTL_ELEM_TYPE_BOOLEAN and isSwitchControl(name)) {
            var val: SndCtlElemValue = .{ .id = .{ .numid = id.numid } };
            const on: c_long = if (muted) 0 else 1;
            for (0..count) |ch| val.value.integer[ch] = on;
            _ = linux.ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, @intFromPtr(&val));
        }
    }
    return set_any_volume;
}

fn isCaptureControl(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "Capture") != null or
        std.mem.indexOf(u8, name, "Mic") != null or
        std.mem.indexOf(u8, name, "Boost") != null;
}

fn isVolumeControl(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "Volume") and
        (std.mem.indexOf(u8, name, "Playback") != null or
            std.mem.indexOf(u8, name, "Master") != null or
            std.mem.indexOf(u8, name, "PCM") != null or
            std.mem.indexOf(u8, name, "Headphone") != null or
            std.mem.indexOf(u8, name, "Speaker") != null);
}

fn isSwitchControl(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "Switch") and
        (std.mem.indexOf(u8, name, "Playback") != null or
            std.mem.indexOf(u8, name, "Master") != null or
            std.mem.indexOf(u8, name, "PCM") != null or
            std.mem.indexOf(u8, name, "Headphone") != null or
            std.mem.indexOf(u8, name, "Speaker") != null);
}

pub fn cStr(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return std.mem.trim(u8, bytes[0..end], " \t\r\n");
}

// --- PCM output stream and sample format conversion --------------------------

pub const SampleFormat = enum {
    s16_le,
    s32_le,
    u8_pcm,
    iec958_subframe_le,

    pub fn bytesPerSample(f: SampleFormat) u32 {
        return switch (f) {
            .u8_pcm => 1,
            .s16_le => 2,
            .s32_le, .iec958_subframe_le => 4,
        };
    }

    pub fn alsaCode(f: SampleFormat) u32 {
        return switch (f) {
            .u8_pcm => SNDRV_PCM_FORMAT_U8,
            .s16_le => SNDRV_PCM_FORMAT_S16_LE,
            .s32_le => SNDRV_PCM_FORMAT_S32_LE,
            .iec958_subframe_le => SNDRV_PCM_FORMAT_IEC958_SUBFRAME_LE,
        };
    }
};

pub const PcmOutput = struct {
    fd: linux.fd_t = -1,
    card: u8 = 0,
    device: u8 = 0,
    format: SampleFormat = .s16_le,
    channels: u16 = 2,
    rate: u32 = 48000,
    buffer_frames: u32 = 4096,
    /// IEC958 block frame counter (`0..191`) for `vc4-hdmi` S/PDIF subframes.
    iec958_frame: u8 = 0,
    /// Whether the card has its own hardware volume control.
    hw_volume: bool = false,

    pub fn open(card: u8, device: u8, preferred_rate: u32) ?PcmOutput {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/snd/pcmC{d}D{d}p", .{ card, device }) catch return null;
        const fd = sys.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }) catch return null;
        errdefer sys.close(fd);

        var params = SndPcmHwParams.initAny();
        if (linux.errno(linux.ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, @intFromPtr(&params))) != .SUCCESS) {
            sys.close(fd);
            return null;
        }

        // Pick format: prefer S16_LE, then S32_LE, then IEC958_SUBFRAME_LE (vc4-hdmi), then U8.
        const fmt_mask = params.mask(SNDRV_PCM_HW_PARAM_FORMAT).*;
        const format: SampleFormat = if (fmt_mask.testBit(SNDRV_PCM_FORMAT_S16_LE))
            .s16_le
        else if (fmt_mask.testBit(SNDRV_PCM_FORMAT_S32_LE))
            .s32_le
        else if (fmt_mask.testBit(SNDRV_PCM_FORMAT_IEC958_SUBFRAME_LE))
            .iec958_subframe_le
        else if (fmt_mask.testBit(SNDRV_PCM_FORMAT_U8))
            .u8_pcm
        else {
            sys.close(fd);
            return null;
        };

        // Pick channels: prefer stereo (2), fall back to device min/max (1 or 2).
        const ch_iv = params.interval(SNDRV_PCM_HW_PARAM_CHANNELS).*;
        const channels: u16 = if (ch_iv.min <= 2 and ch_iv.max >= 2)
            2
        else if (ch_iv.min <= 1 and ch_iv.max >= 1)
            1
        else {
            sys.close(fd);
            return null;
        };

        // Pick rate: clamp preferred_rate to hardware's supported interval, preferring 48000 or 44100 if outside.
        const rate_iv = params.interval(SNDRV_PCM_HW_PARAM_RATE).*;
        const rate: u32 = pickRate(preferred_rate, rate_iv.min, rate_iv.max);

        var hw = SndPcmHwParams.initAny();
        hw.setMask(SNDRV_PCM_HW_PARAM_ACCESS, SndMask.only(SNDRV_PCM_ACCESS_RW_INTERLEAVED));
        hw.setMask(SNDRV_PCM_HW_PARAM_FORMAT, SndMask.only(format.alsaCode()));
        hw.setInterval(SNDRV_PCM_HW_PARAM_CHANNELS, SndInterval.exact(channels));
        hw.setInterval(SNDRV_PCM_HW_PARAM_RATE, SndInterval.range(rate, rate));

        // Refine with access/format/channels/rate first so we can clamp period & buffer sizes.
        _ = linux.ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, @intFromPtr(&hw));

        const period_iv = hw.interval(SNDRV_PCM_HW_PARAM_PERIOD_SIZE).*;
        const want_period = std.math.clamp(rate / 50, @max(period_iv.min, 256), @max(period_iv.min, @min(period_iv.max, 2048)));
        hw.setInterval(SNDRV_PCM_HW_PARAM_PERIOD_SIZE, SndInterval.range(period_iv.min, @max(period_iv.min, @min(period_iv.max, want_period * 2))));

        const buf_iv = hw.interval(SNDRV_PCM_HW_PARAM_BUFFER_SIZE).*;
        const want_buf = std.math.clamp(want_period * 4, @max(buf_iv.min, 1024), @max(buf_iv.min, @min(buf_iv.max, 16384)));
        hw.setInterval(SNDRV_PCM_HW_PARAM_BUFFER_SIZE, SndInterval.range(@min(buf_iv.max, want_buf / 2), @max(buf_iv.min, @min(buf_iv.max, want_buf * 2))));

        if (linux.errno(linux.ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, @intFromPtr(&hw))) != .SUCCESS) {
            // Retry with unconstrained period/buffer sizes.
            hw = SndPcmHwParams.initAny();
            hw.setMask(SNDRV_PCM_HW_PARAM_ACCESS, SndMask.only(SNDRV_PCM_ACCESS_RW_INTERLEAVED));
            hw.setMask(SNDRV_PCM_HW_PARAM_FORMAT, SndMask.only(format.alsaCode()));
            hw.setInterval(SNDRV_PCM_HW_PARAM_CHANNELS, SndInterval.exact(channels));
            hw.setInterval(SNDRV_PCM_HW_PARAM_RATE, SndInterval.range(rate, rate));
            if (linux.errno(linux.ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, @intFromPtr(&hw))) != .SUCCESS) {
                sys.close(fd);
                return null;
            }
        }

        if (linux.errno(linux.ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0)) != .SUCCESS) {
            sys.close(fd);
            return null;
        }

        const actual_rate = hw.interval(SNDRV_PCM_HW_PARAM_RATE).min;
        const actual_buf = hw.interval(SNDRV_PCM_HW_PARAM_BUFFER_SIZE).min;

        return .{
            .fd = fd,
            .card = card,
            .device = device,
            .format = format,
            .channels = channels,
            .rate = if (actual_rate >= 4000 and actual_rate <= 384_000) actual_rate else rate,
            .buffer_frames = if (actual_buf >= 256 and actual_buf <= 65536) actual_buf else 4096,
        };
    }

    pub fn close(p: *PcmOutput) void {
        if (p.fd >= 0) {
            _ = linux.ioctl(p.fd, SNDRV_PCM_IOCTL_DROP, 0);
            sys.close(p.fd);
            p.fd = -1;
        }
    }

    pub fn drop(p: *PcmOutput) void {
        if (p.fd >= 0) {
            _ = linux.ioctl(p.fd, SNDRV_PCM_IOCTL_DROP, 0);
            _ = linux.ioctl(p.fd, SNDRV_PCM_IOCTL_PREPARE, 0);
        }
    }

    /// Writes interleaved stereo `[2]i16` frames (already at `p.rate`),
    /// returning how many frames the kernel accepted (`0` if the hardware ring
    /// buffer is currently full).
    pub fn writeStereoFrames(p: *PcmOutput, frames: []const [2]i16, sw_volume_pct: u8, muted: bool) usize {
        if (p.fd < 0 or frames.len == 0) return 0;
        var encoded_buf: [1024 * 8]u8 = undefined;
        const max_chunk = @min(frames.len, 1024);
        const chunk = frames[0..max_chunk];
        const byte_len = encodeFrames(
            p.format,
            p.channels,
            p.rate,
            &p.iec958_frame,
            chunk,
            if (p.hw_volume) 100 else sw_volume_pct,
            muted,
            &encoded_buf,
        );
        const frame_bytes = @as(usize, p.channels) * p.format.bytesPerSample();
        const count = byte_len / frame_bytes;

        var xfer: SndXferi = .{
            .buf = &encoded_buf,
            .frames = count,
        };
        const rc = linux.ioctl(p.fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, @intFromPtr(&xfer));
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(@max(xfer.result, 0)),
            .AGAIN => return 0,
            .PIPE, .STRPIPE => {
                // Underrun or suspend: prepare and retry once.
                _ = linux.ioctl(p.fd, SNDRV_PCM_IOCTL_PREPARE, 0);
                xfer.result = 0;
                if (linux.errno(linux.ioctl(p.fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, @intFromPtr(&xfer))) == .SUCCESS) {
                    return @intCast(@max(xfer.result, 0));
                }
                return 0;
            },
            else => return 0,
        }
    }
};

fn pickRate(preferred: u32, min_rate: u32, max_rate: u32) u32 {
    const lo = @max(min_rate, 8000);
    const hi = @min(max_rate, 192_000);
    if (lo > hi) return preferred;
    if (preferred >= lo and preferred <= hi) return preferred;
    if (48000 >= lo and 48000 <= hi) return 48000;
    if (44100 >= lo and 44100 <= hi) return 44100;
    return std.math.clamp(preferred, lo, hi);
}

/// Encodes stereo `i16` frames into the hardware's `SampleFormat` and channel
/// count, applying software volume (`0..100`) and mute. Returns the number of
/// bytes written to `out`.
pub fn encodeFrames(
    format: SampleFormat,
    channels: u16,
    rate: u32,
    iec958_frame: *u8,
    frames: []const [2]i16,
    volume_pct: u8,
    muted: bool,
    out: []u8,
) usize {
    const scale: i32 = if (muted) 0 else @min(@as(i32, volume_pct), 100);
    const frame_bytes = @as(usize, channels) * format.bytesPerSample();
    const max_frames = @min(frames.len, out.len / frame_bytes);
    var pos: usize = 0;

    for (frames[0..max_frames]) |pair| {
        const l: i16 = @intCast(@divTrunc(@as(i32, pair[0]) * scale, 100));
        const r: i16 = @intCast(@divTrunc(@as(i32, pair[1]) * scale, 100));
        if (channels == 1) {
            const mono: i16 = @intCast(@divTrunc(@as(i32, l) + @as(i32, r), 2));
            encodeOneSample(format, rate, iec958_frame.*, 0, mono, out[pos..]);
            pos += format.bytesPerSample();
        } else {
            encodeOneSample(format, rate, iec958_frame.*, 0, l, out[pos..]);
            pos += format.bytesPerSample();
            encodeOneSample(format, rate, iec958_frame.*, 1, r, out[pos..]);
            pos += format.bytesPerSample();
        }
        iec958_frame.* = (iec958_frame.* + 1) % 192;
    }
    return pos;
}

fn encodeOneSample(format: SampleFormat, rate: u32, iec_frame: u8, channel: u1, sample: i16, out: []u8) void {
    switch (format) {
        .s16_le => std.mem.writeInt(i16, out[0..2], sample, .little),
        .s32_le => std.mem.writeInt(i32, out[0..4], @as(i32, sample) << 16, .little),
        .u8_pcm => out[0] = @intCast(std.math.clamp(@divTrunc(@as(i32, sample), 256) + 128, 0, 255)),
        .iec958_subframe_le => {
            const subframe = packIec958Subframe(sample, rate, iec_frame, channel);
            std.mem.writeInt(u32, out[0..4], subframe, .little);
        },
    }
}

/// Packs a 16-bit signed PCM sample into a 32-bit IEC958 (S/PDIF) subframe for
/// `vc4-hdmi`.
pub fn packIec958Subframe(sample: i16, rate: u32, iec_frame: u8, channel: u1) u32 {
    const preamble: u32 = if (channel == 1)
        0x04 // W (Y): right channel
    else if (iec_frame == 0)
        0x08 // B (Z): block start, left channel
    else
        0x02; // M (X): left channel

    const pcm24: u32 = (@as(u32, @as(u16, @bitCast(sample))) << 8) & 0x00FF_FFFF;
    var sub: u32 = preamble | (pcm24 << 4);

    if (iec958ChannelStatusBit(rate, iec_frame)) {
        sub |= 1 << 30;
    }
    if ((@popCount(sub & 0x7FFF_FFF0) & 1) != 0) {
        sub |= 1 << 31;
    }
    return sub;
}

fn iec958ChannelStatusBit(rate: u32, iec_frame: u8) bool {
    const byte_idx = iec_frame >> 3;
    const bit_idx: u3 = @intCast(iec_frame & 7);
    const status_byte: u8 = switch (byte_idx) {
        0 => 0x04, // Consumer linear PCM, copyright permitted
        3 => switch (rate) {
            32000 => 0x03,
            44100 => 0x00,
            48000 => 0x02,
            88200 => 0x08,
            96000 => 0x0A,
            176400 => 0x0C,
            192000 => 0x0E,
            else => 0x02,
        },
        4 => 0x02, // 16-bit word length
        else => 0x00,
    };
    return ((status_byte >> bit_idx) & 1) != 0;
}

/// Linearly resamples stereo `[2]i16` frames from `src_rate` to `dst_rate`.
/// Returns `.{ src_consumed, dst_produced }`.
pub fn resampleLinear(
    src: []const [2]i16,
    src_rate: u32,
    dst: [][2]i16,
    dst_rate: u32,
    frac_fp16: *u32,
) struct { consumed: usize, produced: usize } {
    if (src.len == 0 or dst.len == 0) return .{ .consumed = 0, .produced = 0 };
    if (src_rate == dst_rate or src_rate == 0 or dst_rate == 0) {
        const n = @min(src.len, dst.len);
        @memcpy(dst[0..n], src[0..n]);
        return .{ .consumed = n, .produced = n };
    }

    const step_fp16: u64 = (@as(u64, src_rate) << 16) / dst_rate;
    var pos_fp16: u64 = frac_fp16.*;
    var produced: usize = 0;

    while (produced < dst.len) {
        const idx: usize = @intCast(pos_fp16 >> 16);
        if (idx >= src.len) break;
        const next_idx = @min(idx + 1, src.len - 1);
        const frac: i32 = @intCast(pos_fp16 & 0xFFFF);
        const inv: i32 = 65536 - frac;

        const l: i16 = @intCast((@as(i32, src[idx][0]) * inv + @as(i32, src[next_idx][0]) * frac) >> 16);
        const r: i16 = @intCast((@as(i32, src[idx][1]) * inv + @as(i32, src[next_idx][1]) * frac) >> 16);
        dst[produced] = .{ l, r };
        produced += 1;
        pos_fp16 += step_fp16;
    }

    const consumed = @min(src.len, @as(usize, @intCast(pos_fp16 >> 16)));
    frac_fp16.* = @intCast(pos_fp16 - (@as(u64, consumed) << 16));
    return .{ .consumed = consumed, .produced = produced };
}

const testing = std.testing;

test "ALSA kernel struct sizes and IEC958 subframe parity" {
    try testing.expectEqual(@as(usize, 376), @sizeOf(SndCtlCardInfo));
    try testing.expectEqual(@as(usize, 288), @sizeOf(SndPcmInfo));
    try testing.expectEqual(@as(usize, 64), @sizeOf(SndCtlElemId));
    try testing.expectEqual(@as(usize, 272), @sizeOf(SndCtlElemInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(SndMask));
    try testing.expectEqual(@as(usize, 12), @sizeOf(SndInterval));

    // IEC958 subframe: bits 4..31 must always have even parity.
    const sub0 = packIec958Subframe(0x1234, 48000, 0, 0);
    try testing.expectEqual(@as(u32, 0x08), sub0 & 0x0F);
    try testing.expectEqual(@as(u32, 0), @popCount(sub0 & 0xFFFF_FFF0) & 1);

    const sub1 = packIec958Subframe(-12345, 44100, 1, 1);
    try testing.expectEqual(@as(u32, 0x04), sub1 & 0x0F);
    try testing.expectEqual(@as(u32, 0), @popCount(sub1 & 0xFFFF_FFF0) & 1);
}

test "encodeFrames scales volume and mutes cleanly" {
    const frames = [_][2]i16{ .{ 10000, -10000 }, .{ 4000, -4000 } };
    var iec: u8 = 0;
    var out: [16]u8 = undefined;

    const bytes = encodeFrames(.s16_le, 2, 48000, &iec, &frames, 50, false, &out);
    try testing.expectEqual(@as(usize, 8), bytes);
    try testing.expectEqual(@as(i16, 5000), std.mem.readInt(i16, out[0..2], .little));
    try testing.expectEqual(@as(i16, -5000), std.mem.readInt(i16, out[2..4], .little));

    _ = encodeFrames(.s16_le, 2, 48000, &iec, &frames, 80, true, &out);
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[0..2], .little));
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[2..4], .little));
}

test "resampleLinear converts between sample rates" {
    const src = [_][2]i16{ .{ 0, 0 }, .{ 1000, -1000 }, .{ 2000, -2000 }, .{ 3000, -3000 } };
    var dst: [8][2]i16 = undefined;
    var frac: u32 = 0;
    const res = resampleLinear(&src, 24000, &dst, 48000, &frac);
    try testing.expectEqual(@as(usize, 4), res.consumed);
    try testing.expectEqual(@as(usize, 8), res.produced);
    try testing.expectEqual(@as(i16, 0), dst[0][0]);
    try testing.expectEqual(@as(i16, 500), dst[1][0]);
    try testing.expectEqual(@as(i16, 1000), dst[2][0]);
}
