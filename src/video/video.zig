//! Hardware-accelerated video decoding, playback, encoding and MP4
//! recording on the Raspberry Pi: `bcm2835-codec` (/dev/video10 for
//! decoding, /dev/video11 for encoding), Video4Linux2 memory-to-memory
//! devices that send frames over VCHIQ to the VideoCore GPU's
//! `ril.video_decode` and `ril.video_encode` services using CMA memory.
//!
//! `Stream` reads the container (MP4/MOV `ftyp`/`moov`, or raw Annex-B
//! H.264) from an open file descriptor without loading the whole file
//! into memory, so large videos stream directly from the card or USB
//! drive. `Decoder` and `Player` drive playback, while `Encoder`,
//! `Mp4Muxer` and `Recorder` encode YUV 4:2:0 frames to H.264 and stream
//! them directly into an `.mp4` file on disk.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const gfx = @import("gfx");
const audio = @import("audio");
pub const v4l2 = sys.v4l2;

pub const Codec = enum {
    h264,
    mpeg4,
    mjpeg,
    h263,

    pub fn name(c: Codec) []const u8 {
        return switch (c) {
            .h264 => "H.264",
            .mpeg4 => "MPEG-4",
            .mjpeg => "Motion JPEG",
            .h263 => "H.263",
        };
    }

    pub fn fourcc(c: Codec) u32 {
        return switch (c) {
            .h264 => v4l2.fourcc("H264"),
            .mpeg4 => v4l2.fourcc("MPG4"),
            .mjpeg => v4l2.fourcc("MJPG"),
            .h263 => v4l2.fourcc("H263"),
        };
    }
};

/// One compressed video frame in the file.
pub const Sample = struct {
    offset: u64,
    size: u32,
    pts_us: u64,
    keyframe: bool,
};

pub const AudioCodec = enum {
    aac,
    pcm_u8,
    pcm_s8,
    pcm_s16le,
    pcm_s16be,
    pcm_s24le,
    pcm_s24be,
    pcm_s32le,
    pcm_s32be,
    float_f32le,
    float_f32be,
    ulaw,
    alaw,

    pub fn bytesPerSample(c: AudioCodec) u8 {
        return switch (c) {
            .aac => 0,
            .pcm_u8, .pcm_s8, .ulaw, .alaw => 1,
            .pcm_s16le, .pcm_s16be => 2,
            .pcm_s24le, .pcm_s24be => 3,
            .pcm_s32le, .pcm_s32be, .float_f32le, .float_f32be => 4,
        };
    }
};

pub const AudioPacket = struct {
    offset: u64,
    size: u32,
    pts_us: u64,
    frames: u32,
};

pub const AudioTrack = struct {
    codec: AudioCodec,
    sample_rate: u32,
    channels: u8,
    aac_config: audio.aac.Config = .{},
    packets: []AudioPacket,
    max_packet_size: u32,

    pub fn deinit(a: *AudioTrack, gpa: std.mem.Allocator) void {
        if (a.packets.len > 0) gpa.free(a.packets);
        a.packets = &.{};
    }

    pub fn packetAtOrAfter(a: *const AudioTrack, target_us: u64) usize {
        for (a.packets, 0..) |pkt, i| {
            if (pkt.pts_us >= target_us) {
                return if (a.codec == .aac and i > 0) i - 1 else i;
            }
        }
        return a.packets.len;
    }

    pub fn readPacket(a: *const AudioTrack, fd: linux.fd_t, index: usize, buf: []u8) ![]const u8 {
        if (index >= a.packets.len) return error.EndOfStream;
        const pkt = a.packets[index];
        if (pkt.size > buf.len) return error.BufferTooSmall;
        const dst = buf[0..pkt.size];
        if ((try preadInto(fd, dst, pkt.offset)) != pkt.size) return error.UnexpectedEof;
        return dst;
    }
};

/// The largest `moov` metadata box read into memory (16 MiB), and the
/// most frames indexed in a single video (~2 hours at 30 fps).
const max_moov_bytes = 16 * 1024 * 1024;
const max_samples = 216_000;
const max_audio_packets = 360_000;
const max_audio_packet_bytes = 64 * 1024;
/// The largest raw Annex-B stream scanned in full (64 MiB).
const max_annexb_bytes = 64 * 1024 * 1024;
/// The largest single compressed frame buffer (768 KiB, matching
/// bcm2835-codec's DEF_COMP_BUF_SIZE_GREATER_720P).
const max_frame_bytes = 768 * 1024;
/// The largest picture made for a viewer (960×540): big enough to fill a
/// pane on a 1080p screen while keeping texture uploads quick on a Pi
/// Zero or Pi 1.
const max_display_width = 960;
const max_display_height = 540;

/// Whether the first bytes of a file look like a video container or
/// elementary stream `Stream.open` may be able to read.
pub fn looksLikeVideo(head: []const u8) bool {
    if (head.len >= 12 and std.mem.eql(u8, head[4..8], "ftyp")) {
        const brand = head[8..12];
        // Still-image ISO BMFF files (AVIF, HEIC) are not videos.
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis") or
            std.mem.eql(u8, brand, "heic") or std.mem.eql(u8, brand, "heix") or
            std.mem.eql(u8, brand, "mif1")) return false;
        return true;
    }
    if (head.len >= 8) {
        const tag = head[4..8];
        if (std.mem.eql(u8, tag, "moov") or std.mem.eql(u8, tag, "mdat") or std.mem.eql(u8, tag, "wide")) {
            const sz = std.mem.readInt(u32, head[0..4], .big);
            if (sz == 1 or sz >= 8) return true;
        }
    }
    return looksLikeAnnexB(head);
}

fn looksLikeAnnexB(head: []const u8) bool {
    const first = nextStartCode(head, 0) orelse return false;
    if (first.pos != 0 or first.end >= head.len) return false;
    const nal = head[first.end];
    if (nal & 0x80 != 0) return false;
    const nal_type = nal & 0x1f;
    // An H.264 stream begins with an SPS (7) or an Access Unit Delimiter (9)
    // followed soon by an SPS.
    if (nal_type == 7) return validSpsHeader(head[first.end..]);
    if (nal_type == 9) {
        var at = first.end + 1;
        while (nextStartCode(head, at)) |sc| : (at = sc.end + 1) {
            if (sc.end >= head.len) break;
            const h = head[sc.end];
            if (h & 0x80 != 0) return false;
            if ((h & 0x1f) == 7) return validSpsHeader(head[sc.end..]);
        }
    }
    return false;
}

fn validSpsHeader(nal: []const u8) bool {
    if (nal.len < 4) return false;
    const profile = nal[1];
    return switch (profile) {
        66, 77, 88, 100, 110, 122, 144, 244 => nal[3] > 0 and nal[3] <= 62,
        else => false,
    };
}

/// A parsed video stream and its frame index.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    fd: linux.fd_t,
    owns_fd: bool = true,
    codec: Codec,
    width: u32,
    height: u32,
    duration_us: u64,
    samples: []Sample,
    /// Codec configuration prepended on keyframes / stream start (Annex-B
    /// SPS/PPS for `avc1`/`avc3` or raw H.264; VOL header for `mp4v`).
    header: []u8,
    /// For MP4 `avc1`/`avc3`: the byte length of each NAL unit's length
    /// prefix (1, 2 or 4). Zero when samples are already framed (Annex-B,
    /// MJPEG, MPEG-4, H.263).
    nal_length_size: u8 = 0,
    scratch: []u8 = &.{},
    audio_track: ?AudioTrack = null,

    pub fn open(gpa: std.mem.Allocator, fd: linux.fd_t, file_size: u64, owns_fd: bool) !Stream {
        var head: [64]u8 = undefined;
        const n = try preadInto(fd, &head, 0);
        if (n < 8) return error.InvalidVideo;
        var s = if (looksLikeAnnexB(head[0..n]))
            try parseAnnexB(gpa, fd, file_size)
        else
            try parseMp4(gpa, fd, file_size);
        errdefer s.deinit();
        s.owns_fd = owns_fd;
        if (s.nal_length_size > 0) {
            var max_sz: u32 = 0;
            for (s.samples) |sp| max_sz = @max(max_sz, sp.size);
            if (max_sz > max_frame_bytes) return error.FrameTooLarge;
            s.scratch = try gpa.alloc(u8, @max(max_sz, 1));
        }
        return s;
    }

    pub fn deinit(s: *Stream) void {
        if (s.audio_track) |*at| at.deinit(s.gpa);
        if (s.scratch.len > 0) s.gpa.free(s.scratch);
        if (s.header.len > 0) s.gpa.free(s.header);
        if (s.samples.len > 0) s.gpa.free(s.samples);
        if (s.owns_fd and s.fd >= 0) sys.close(s.fd);
    }

    /// Reads sample `index` into `out`, converting length-prefixed MP4 NAL
    /// units to Annex-B start codes and prepending `header` when
    /// `include_header` (or the sample is a keyframe).
    pub fn readSample(s: *const Stream, index: usize, include_header: bool, out: []u8) !usize {
        if (index >= s.samples.len) return error.EndOfStream;
        const sp = s.samples[index];
        var pos: usize = 0;
        if ((include_header or sp.keyframe) and s.header.len > 0) {
            if (s.header.len > out.len) return error.BufferTooSmall;
            @memcpy(out[0..s.header.len], s.header);
            pos = s.header.len;
        }
        if (s.nal_length_size > 0) {
            if (sp.size > s.scratch.len) return error.FrameTooLarge;
            const raw = s.scratch[0..sp.size];
            if ((try preadInto(s.fd, raw, sp.offset)) != sp.size) return error.UnexpectedEof;
            var at: usize = 0;
            const step = s.nal_length_size;
            while (at + step <= raw.len) {
                const nal_len: usize = switch (step) {
                    1 => raw[at],
                    2 => std.mem.readInt(u16, raw[at..][0..2], .big),
                    3 => (@as(usize, raw[at]) << 16) | (@as(usize, raw[at + 1]) << 8) | raw[at + 2],
                    4 => std.mem.readInt(u32, raw[at..][0..4], .big),
                    else => return error.InvalidVideo,
                };
                at += step;
                if (nal_len == 0) continue;
                if (at + nal_len > raw.len) break;
                if (pos + 4 + nal_len > out.len) return error.BufferTooSmall;
                @memcpy(out[pos..][0..4], &[_]u8{ 0, 0, 0, 1 });
                pos += 4;
                @memcpy(out[pos..][0..nal_len], raw[at..][0..nal_len]);
                pos += nal_len;
                at += nal_len;
            }
            return pos;
        }
        if (pos + sp.size > out.len) return error.BufferTooSmall;
        if ((try preadInto(s.fd, out[pos..][0..sp.size], sp.offset)) != sp.size) return error.UnexpectedEof;
        return pos + sp.size;
    }

    /// The index of the last keyframe at or before `target_us`.
    pub fn keyframeAtOrBefore(s: *const Stream, target_us: u64) usize {
        if (s.samples.len == 0) return 0;
        var best: usize = 0;
        for (s.samples, 0..) |sp, i| {
            if (sp.keyframe and sp.pts_us <= target_us) best = i;
            if (sp.pts_us > target_us and i > best) break;
        }
        return best;
    }
};

fn preadInto(fd: linux.fd_t, buf: []u8, offset: u64) !usize {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pread(fd, buf[done..].ptr, buf.len - done, @bitCast(offset + done));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                done += rc;
            },
            .INTR => continue,
            else => return error.ReadError,
        }
    }
    return done;
}

// --- ISO Base Media File Format (MP4 / MOV) demuxer --------------------------

const Box = struct {
    kind: [4]u8,
    payload: []const u8,
    next: usize,
};

fn nextBox(data: []const u8, at: usize) ?Box {
    if (at + 8 > data.len) return null;
    const sz32 = std.mem.readInt(u32, data[at..][0..4], .big);
    const kind = data[at + 4 ..][0..4].*;
    var header_len: usize = 8;
    var total: u64 = sz32;
    if (sz32 == 1) {
        if (at + 16 > data.len) return null;
        total = std.mem.readInt(u64, data[at + 8 ..][0..8], .big);
        header_len = 16;
    } else if (sz32 == 0) {
        total = data.len - at;
    }
    if (total < header_len or at + total > data.len) return null;
    const end: usize = @intCast(at + total);
    return .{ .kind = kind, .payload = data[at + header_len .. end], .next = end };
}

fn parseMp4(gpa: std.mem.Allocator, fd: linux.fd_t, file_size: u64) !Stream {
    var offset: u64 = 0;
    var moov_offset: ?u64 = null;
    var moov_size: usize = 0;
    var hdr: [16]u8 = undefined;
    while (offset + 8 <= file_size) {
        const n = try preadInto(fd, hdr[0..8], offset);
        if (n < 8) break;
        const sz32 = std.mem.readInt(u32, hdr[0..4], .big);
        const kind = hdr[4..8];
        var box_hdr: u64 = 8;
        var box_size: u64 = sz32;
        if (sz32 == 1) {
            if ((try preadInto(fd, hdr[8..16], offset + 8)) < 8) break;
            box_size = std.mem.readInt(u64, hdr[8..16], .big);
            box_hdr = 16;
        } else if (sz32 == 0) {
            box_size = file_size - offset;
        }
        if (box_size < box_hdr or offset + box_size > file_size) break;
        if (std.mem.eql(u8, kind, "moov")) {
            const payload_len = box_size - box_hdr;
            if (payload_len == 0 or payload_len > max_moov_bytes) return error.InvalidVideo;
            moov_offset = offset + box_hdr;
            moov_size = @intCast(payload_len);
            break;
        }
        offset += box_size;
    }
    const m_off = moov_offset orelse return error.InvalidVideo;
    const moov = try gpa.alloc(u8, moov_size);
    defer gpa.free(moov);
    if ((try preadInto(fd, moov, m_off)) != moov_size) return error.InvalidVideo;
    return parseMoov(gpa, fd, file_size, moov);
}

fn parseMoov(gpa: std.mem.Allocator, fd: linux.fd_t, file_size: u64, moov: []const u8) !Stream {
    var video_stream: ?Stream = null;
    errdefer if (video_stream) |*vs| vs.deinit();
    var audio_track: ?AudioTrack = null;
    errdefer if (audio_track) |*at| at.deinit(gpa);

    var at: usize = 0;
    while (nextBox(moov, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "trak")) {
            if (video_stream == null) {
                if (parseTrak(gpa, fd, file_size, b.payload)) |s| {
                    video_stream = s;
                    continue;
                } else |_| {}
            }
            if (audio_track == null) {
                if (parseAudioTrak(gpa, file_size, b.payload)) |a| {
                    audio_track = a;
                } else |_| {}
            }
        }
    }
    if (video_stream) |*vs| {
        vs.audio_track = audio_track;
        audio_track = null;
        return vs.*;
    }
    return error.InvalidVideo;
}

fn parseTrak(gpa: std.mem.Allocator, fd: linux.fd_t, file_size: u64, trak: []const u8) !Stream {
    var mdia: ?[]const u8 = null;
    var tkhd_w: u32 = 0;
    var tkhd_h: u32 = 0;
    var at: usize = 0;
    while (nextBox(trak, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "tkhd") and b.payload.len >= 84) {
            const version = b.payload[0];
            const dim_off: usize = if (version == 1) 88 else 76;
            if (b.payload.len >= dim_off + 8) {
                tkhd_w = std.mem.readInt(u32, b.payload[dim_off..][0..4], .big) >> 16;
                tkhd_h = std.mem.readInt(u32, b.payload[dim_off + 4 ..][0..4], .big) >> 16;
            }
        } else if (std.mem.eql(u8, &b.kind, "mdia")) {
            mdia = b.payload;
        }
    }
    const mdia_bytes = mdia orelse return error.InvalidVideo;
    var timescale: u32 = 0;
    var mdhd_duration: u64 = 0;
    var is_video = false;
    var minf: ?[]const u8 = null;
    at = 0;
    while (nextBox(mdia_bytes, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "mdhd") and b.payload.len >= 20) {
            const version = b.payload[0];
            if (version == 1 and b.payload.len >= 32) {
                timescale = std.mem.readInt(u32, b.payload[20..24], .big);
                const d = std.mem.readInt(u64, b.payload[24..32], .big);
                mdhd_duration = if (d == std.math.maxInt(u64)) 0 else d;
            } else if (version == 0) {
                timescale = std.mem.readInt(u32, b.payload[12..16], .big);
                const d = std.mem.readInt(u32, b.payload[16..20], .big);
                mdhd_duration = if (d == std.math.maxInt(u32)) 0 else d;
            }
        } else if (std.mem.eql(u8, &b.kind, "hdlr") and b.payload.len >= 12) {
            if (std.mem.eql(u8, b.payload[8..12], "vide")) is_video = true;
        } else if (std.mem.eql(u8, &b.kind, "minf")) {
            minf = b.payload;
        }
    }
    if (!is_video) return error.InvalidVideo;
    const minf_bytes = minf orelse return error.InvalidVideo;
    var stbl: ?[]const u8 = null;
    at = 0;
    while (nextBox(minf_bytes, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "stbl")) stbl = b.payload;
    }
    const stbl_bytes = stbl orelse return error.InvalidVideo;
    return parseStbl(gpa, fd, file_size, stbl_bytes, if (timescale > 0) timescale else 1000, mdhd_duration, tkhd_w, tkhd_h);
}

const StsdInfo = struct {
    codec: Codec,
    width: u32,
    height: u32,
    header: []u8,
    nal_length_size: u8,
};

fn parseStsd(gpa: std.mem.Allocator, payload: []const u8) !StsdInfo {
    if (payload.len < 16) return error.InvalidVideo;
    const count = std.mem.readInt(u32, payload[4..8], .big);
    if (count == 0) return error.InvalidVideo;
    const entry = nextBox(payload, 8) orelse return error.InvalidVideo;
    // VisualSampleEntry has 6 reserved bytes, 2-byte data_reference_index,
    // 16 bytes pre_defined/reserved, then u16 width and u16 height (offset 24..28),
    // and ends at offset 78 where child boxes (`avcC`, `esds`, etc.) begin.
    if (entry.payload.len < 78) return error.InvalidVideo;
    var width: u32 = std.mem.readInt(u16, entry.payload[24..26], .big);
    var height: u32 = std.mem.readInt(u16, entry.payload[26..28], .big);
    const children = entry.payload[78..];

    if (std.mem.eql(u8, &entry.kind, "avc1") or std.mem.eql(u8, &entry.kind, "avc3")) {
        var at: usize = 0;
        while (nextBox(children, at)) |b| : (at = b.next) {
            if (std.mem.eql(u8, &b.kind, "avcC")) {
                const avcc = try parseAvcC(gpa, b.payload);
                errdefer gpa.free(avcc.header);
                if (avcc.width > 0 and avcc.height > 0) {
                    width = avcc.width;
                    height = avcc.height;
                }
                return .{
                    .codec = .h264,
                    .width = width,
                    .height = height,
                    .header = avcc.header,
                    .nal_length_size = avcc.nal_length_size,
                };
            }
        }
        return error.InvalidVideo;
    }
    if (std.mem.eql(u8, &entry.kind, "mp4v")) {
        var header: []u8 = &.{};
        var at: usize = 0;
        while (nextBox(children, at)) |b| : (at = b.next) {
            if (std.mem.eql(u8, &b.kind, "esds")) {
                if (parseEsdsConfig(b.payload)) |cfg| {
                    header = try gpa.dupe(u8, cfg);
                    break;
                }
            }
        }
        return .{ .codec = .mpeg4, .width = width, .height = height, .header = header, .nal_length_size = 0 };
    }
    if (std.mem.eql(u8, &entry.kind, "mjpa") or std.mem.eql(u8, &entry.kind, "mjpb") or std.mem.eql(u8, &entry.kind, "jpeg")) {
        return .{ .codec = .mjpeg, .width = width, .height = height, .header = &.{}, .nal_length_size = 0 };
    }
    if (std.mem.eql(u8, &entry.kind, "s263") or std.mem.eql(u8, &entry.kind, "h263")) {
        return .{ .codec = .h263, .width = width, .height = height, .header = &.{}, .nal_length_size = 0 };
    }
    return error.UnsupportedCodec;
}

const AvcC = struct {
    header: []u8,
    nal_length_size: u8,
    width: u32,
    height: u32,
};

fn parseAvcC(gpa: std.mem.Allocator, data: []const u8) !AvcC {
    if (data.len < 7 or data[0] != 1) return error.InvalidVideo;
    const nal_length_size: u8 = (data[4] & 0x03) + 1;
    const num_sps = data[5] & 0x1f;
    var at: usize = 6;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var width: u32 = 0;
    var height: u32 = 0;

    var i: u8 = 0;
    while (i < num_sps) : (i += 1) {
        if (at + 2 > data.len) return error.InvalidVideo;
        const len = std.mem.readInt(u16, data[at..][0..2], .big);
        at += 2;
        if (at + len > data.len) return error.InvalidVideo;
        const sps = data[at..][0..len];
        at += len;
        if (len > 0) {
            try out.appendSlice(gpa, &.{ 0, 0, 0, 1 });
            try out.appendSlice(gpa, sps);
            if (parseSps(sps)) |info| {
                width = info.width;
                height = info.height;
            }
        }
    }
    if (at >= data.len) return error.InvalidVideo;
    const num_pps = data[at];
    at += 1;
    i = 0;
    while (i < num_pps) : (i += 1) {
        if (at + 2 > data.len) return error.InvalidVideo;
        const len = std.mem.readInt(u16, data[at..][0..2], .big);
        at += 2;
        if (at + len > data.len) return error.InvalidVideo;
        const pps = data[at..][0..len];
        at += len;
        if (len > 0) {
            try out.appendSlice(gpa, &.{ 0, 0, 0, 1 });
            try out.appendSlice(gpa, pps);
        }
    }
    return .{
        .header = try out.toOwnedSlice(gpa),
        .nal_length_size = nal_length_size,
        .width = width,
        .height = height,
    };
}

/// Extracts the DecoderSpecificInfo (tag 0x05) payload from an `esds` box.
fn parseEsdsConfig(data: []const u8) ?[]const u8 {
    if (data.len < 6) return null;
    var at: usize = 4; // version + flags
    while (at + 2 <= data.len) {
        const tag = data[at];
        at += 1;
        var len: usize = 0;
        var count: u8 = 0;
        while (at < data.len and count < 4) : (count += 1) {
            const b = data[at];
            at += 1;
            len = (len << 7) | (b & 0x7f);
            if (b & 0x80 == 0) break;
        }
        if (at + len > data.len) return null;
        if (tag == 0x03) {
            if (len < 3) return null;
            const flags = data[at + 2];
            var skip: usize = 3;
            if (flags & 0x80 != 0) skip += 2;
            if (flags & 0x40 != 0) {
                if (at + skip >= data.len) return null;
                skip += 1 + data[at + skip];
            }
            if (flags & 0x20 != 0) skip += 2;
            at += @min(skip, len);
        } else if (tag == 0x04) {
            if (len < 13) return null;
            at += 13;
        } else if (tag == 0x05) {
            return data[at..][0..len];
        } else {
            at += len;
        }
    }
    return null;
}

fn parseStbl(
    gpa: std.mem.Allocator,
    fd: linux.fd_t,
    file_size: u64,
    stbl: []const u8,
    timescale: u32,
    mdhd_duration: u64,
    tkhd_w: u32,
    tkhd_h: u32,
) !Stream {
    var stsd_box: ?[]const u8 = null;
    var stts_box: ?[]const u8 = null;
    var ctts_box: ?[]const u8 = null;
    var stsc_box: ?[]const u8 = null;
    var stsz_box: ?[]const u8 = null;
    var stco_box: ?[]const u8 = null;
    var co64_box: ?[]const u8 = null;
    var stss_box: ?[]const u8 = null;

    var at: usize = 0;
    while (nextBox(stbl, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "stsd")) stsd_box = b.payload else if (std.mem.eql(u8, &b.kind, "stts")) stts_box = b.payload else if (std.mem.eql(u8, &b.kind, "ctts")) ctts_box = b.payload else if (std.mem.eql(u8, &b.kind, "stsc")) stsc_box = b.payload else if (std.mem.eql(u8, &b.kind, "stsz")) stsz_box = b.payload else if (std.mem.eql(u8, &b.kind, "stco")) stco_box = b.payload else if (std.mem.eql(u8, &b.kind, "co64")) co64_box = b.payload else if (std.mem.eql(u8, &b.kind, "stss")) stss_box = b.payload;
    }

    var info = try parseStsd(gpa, stsd_box orelse return error.InvalidVideo);
    errdefer if (info.header.len > 0) gpa.free(info.header);
    if (info.width == 0) info.width = tkhd_w;
    if (info.height == 0) info.height = tkhd_h;
    if (info.width == 0 or info.height == 0) return error.InvalidVideo;

    const stsz = stsz_box orelse return error.InvalidVideo;
    if (stsz.len < 12) return error.InvalidVideo;
    const default_size = std.mem.readInt(u32, stsz[4..8], .big);
    const sample_count_raw = std.mem.readInt(u32, stsz[8..12], .big);
    if (sample_count_raw == 0) return error.InvalidVideo;
    const sample_count: usize = @min(sample_count_raw, max_samples);
    if (default_size == 0 and stsz.len < 12 + sample_count * 4) return error.InvalidVideo;

    const stsc = stsc_box orelse return error.InvalidVideo;
    if (stsc.len < 8) return error.InvalidVideo;
    const stsc_count = std.mem.readInt(u32, stsc[4..8], .big);
    if (stsc_count == 0 or stsc.len < 8 + @as(usize, stsc_count) * 12) return error.InvalidVideo;

    const chunk_count: usize = if (stco_box) |co| blk: {
        if (co.len < 8) return error.InvalidVideo;
        const c = std.mem.readInt(u32, co[4..8], .big);
        if (co.len < 8 + @as(usize, c) * 4) return error.InvalidVideo;
        break :blk c;
    } else if (co64_box) |co| blk: {
        if (co.len < 8) return error.InvalidVideo;
        const c = std.mem.readInt(u32, co[4..8], .big);
        if (co.len < 8 + @as(usize, c) * 8) return error.InvalidVideo;
        break :blk c;
    } else return error.InvalidVideo;
    if (chunk_count == 0) return error.InvalidVideo;

    const samples = try gpa.alloc(Sample, sample_count);
    errdefer gpa.free(samples);

    // 1. Sample offsets and sizes (from stsc + stco/co64 + stsz).
    var sample_idx: usize = 0;
    var stsc_idx: usize = 0;
    var chunk_idx: usize = 0;
    while (chunk_idx < chunk_count and sample_idx < sample_count) : (chunk_idx += 1) {
        const chunk_1based = chunk_idx + 1;
        while (stsc_idx + 1 < stsc_count) {
            const next_first = std.mem.readInt(u32, stsc[8 + (stsc_idx + 1) * 12 ..][0..4], .big);
            if (chunk_1based >= next_first) stsc_idx += 1 else break;
        }
        const per_chunk = std.mem.readInt(u32, stsc[8 + stsc_idx * 12 + 4 ..][0..4], .big);
        var offset: u64 = if (stco_box) |co|
            std.mem.readInt(u32, co[8 + chunk_idx * 4 ..][0..4], .big)
        else
            std.mem.readInt(u64, co64_box.?[8 + chunk_idx * 8 ..][0..8], .big);

        var j: u32 = 0;
        while (j < per_chunk and sample_idx < sample_count) : (j += 1) {
            const sz = if (default_size != 0)
                default_size
            else
                std.mem.readInt(u32, stsz[12 + sample_idx * 4 ..][0..4], .big);
            if (offset + sz > file_size) {
                if (sample_idx == 0) return error.InvalidVideo;
                break;
            }
            samples[sample_idx] = .{
                .offset = offset,
                .size = sz,
                .pts_us = 0,
                .keyframe = stss_box == null,
            };
            offset += sz;
            sample_idx += 1;
        }
    }
    const valid_count = sample_idx;
    if (valid_count == 0) return error.InvalidVideo;

    // 2. Decoding timestamps (stts) and composition offsets (ctts).
    var dts_ticks: u64 = 0;
    if (stts_box) |stts| if (stts.len >= 8) {
        const count = std.mem.readInt(u32, stts[4..8], .big);
        var idx: usize = 0;
        var entry_i: usize = 0;
        while (entry_i < count and 8 + (entry_i + 1) * 8 <= stts.len and idx < valid_count) : (entry_i += 1) {
            const n = std.mem.readInt(u32, stts[8 + entry_i * 8 ..][0..4], .big);
            const delta = std.mem.readInt(u32, stts[8 + entry_i * 8 + 4 ..][0..4], .big);
            var k: u32 = 0;
            while (k < n and idx < valid_count) : (k += 1) {
                samples[idx].pts_us = dts_ticks * 1_000_000 / timescale;
                dts_ticks += delta;
                idx += 1;
            }
        }
    };
    if (ctts_box) |ctts| if (ctts.len >= 8) {
        const count = std.mem.readInt(u32, ctts[4..8], .big);
        var idx: usize = 0;
        var entry_i: usize = 0;
        while (entry_i < count and 8 + (entry_i + 1) * 8 <= ctts.len and idx < valid_count) : (entry_i += 1) {
            const n = std.mem.readInt(u32, ctts[8 + entry_i * 8 ..][0..4], .big);
            const raw_off = std.mem.readInt(i32, ctts[8 + entry_i * 8 + 4 ..][0..4], .big);
            const off_us: i64 = @divTrunc(@as(i64, raw_off) * 1_000_000, @as(i64, timescale));
            var k: u32 = 0;
            while (k < n and idx < valid_count) : (k += 1) {
                const pts: i64 = @as(i64, @intCast(samples[idx].pts_us)) + off_us;
                samples[idx].pts_us = @intCast(@max(pts, 0));
                idx += 1;
            }
        }
    };

    // 3. Keyframes (stss); sample 0 is always treated as a starting keyframe.
    samples[0].keyframe = true;
    if (stss_box) |stss| if (stss.len >= 8) {
        const count = std.mem.readInt(u32, stss[4..8], .big);
        var entry_i: usize = 0;
        while (entry_i < count and 8 + (entry_i + 1) * 4 <= stss.len) : (entry_i += 1) {
            const sync_1based = std.mem.readInt(u32, stss[8 + entry_i * 4 ..][0..4], .big);
            if (sync_1based >= 1 and sync_1based <= valid_count) {
                samples[sync_1based - 1].keyframe = true;
            }
        }
    };

    const duration_us: u64 = if (mdhd_duration > 0)
        mdhd_duration * 1_000_000 / timescale
    else if (dts_ticks > 0)
        dts_ticks * 1_000_000 / timescale
    else
        samples[valid_count - 1].pts_us;

    const final_samples = if (valid_count < sample_count)
        try gpa.realloc(samples, valid_count)
    else
        samples;

    return .{
        .gpa = gpa,
        .fd = fd,
        .codec = info.codec,
        .width = info.width,
        .height = info.height,
        .duration_us = duration_us,
        .samples = final_samples,
        .header = info.header,
        .nal_length_size = info.nal_length_size,
    };
}

// --- MP4 / MOV audio track demuxer & PCM/G.711 decoders ----------------------

fn parseAudioTrak(gpa: std.mem.Allocator, file_size: u64, trak: []const u8) !AudioTrack {
    var mdia: ?[]const u8 = null;
    var at: usize = 0;
    while (nextBox(trak, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "mdia")) mdia = b.payload;
    }
    const mdia_bytes = mdia orelse return error.InvalidAudio;
    var timescale: u32 = 0;
    var is_sound = false;
    var minf: ?[]const u8 = null;
    at = 0;
    while (nextBox(mdia_bytes, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "mdhd") and b.payload.len >= 20) {
            const version = b.payload[0];
            if (version == 1 and b.payload.len >= 32) {
                timescale = std.mem.readInt(u32, b.payload[20..24], .big);
            } else if (version == 0) {
                timescale = std.mem.readInt(u32, b.payload[12..16], .big);
            }
        } else if (std.mem.eql(u8, &b.kind, "hdlr") and b.payload.len >= 12) {
            if (std.mem.eql(u8, b.payload[8..12], "soun")) is_sound = true;
        } else if (std.mem.eql(u8, &b.kind, "minf")) {
            minf = b.payload;
        }
    }
    if (!is_sound) return error.InvalidAudio;
    const minf_bytes = minf orelse return error.InvalidAudio;
    var stbl: ?[]const u8 = null;
    at = 0;
    while (nextBox(minf_bytes, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "stbl")) stbl = b.payload;
    }
    const stbl_bytes = stbl orelse return error.InvalidAudio;
    return parseAudioStbl(gpa, file_size, stbl_bytes, timescale);
}

const AudioStsdInfo = struct {
    codec: AudioCodec,
    sample_rate: u32,
    channels: u8,
    aac_config: audio.aac.Config = .{},
};

fn findBoxRecursive(children: []const u8, kind: *const [4]u8) ?[]const u8 {
    var at: usize = 0;
    while (nextBox(children, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, kind)) return b.payload;
        if (std.mem.eql(u8, &b.kind, "wave")) {
            if (findBoxRecursive(b.payload, kind)) |found| return found;
        }
    }
    return null;
}

fn parseAudioStsd(payload: []const u8, fallback_rate: u32) !AudioStsdInfo {
    if (payload.len < 16) return error.InvalidAudio;
    const count = std.mem.readInt(u32, payload[4..8], .big);
    if (count == 0) return error.InvalidAudio;
    const entry = nextBox(payload, 8) orelse return error.InvalidAudio;
    if (entry.payload.len < 28) return error.InvalidAudio;

    const version = std.mem.readInt(u16, entry.payload[8..10], .big);
    var channels: u8 = @intCast(std.math.clamp(std.mem.readInt(u16, entry.payload[16..18], .big), 1, 8));
    var sample_size: u16 = std.mem.readInt(u16, entry.payload[18..20], .big);
    var sample_rate: u32 = std.mem.readInt(u32, entry.payload[24..28], .big) >> 16;
    if (sample_rate == 0) sample_rate = if (fallback_rate > 0) fallback_rate else 48000;

    if (version == 2 and entry.payload.len >= 64) {
        const sr_bits = std.mem.readInt(u64, entry.payload[32..40], .big);
        const sr_f64: f64 = @bitCast(sr_bits);
        if (sr_f64 >= 4000.0 and sr_f64 <= 192000.0) {
            sample_rate = @intFromFloat(@round(sr_f64));
        }
        const ch32 = std.mem.readInt(u32, entry.payload[40..44], .big);
        if (ch32 >= 1 and ch32 <= 8) channels = @intCast(ch32);
        const bits32 = std.mem.readInt(u32, entry.payload[48..52], .big);
        if (bits32 >= 8 and bits32 <= 64) sample_size = @intCast(bits32);
    }

    const child_off: usize = if (version == 2 and entry.payload.len >= 64)
        64
    else if (version == 1 and entry.payload.len >= 44)
        44
    else
        28;
    const children = if (child_off <= entry.payload.len) entry.payload[child_off..] else &.{};

    if (std.mem.eql(u8, &entry.kind, "mp4a")) {
        const esds = findBoxRecursive(children, "esds") orelse return error.InvalidAudio;
        const asc = parseEsdsConfig(esds) orelse return error.InvalidAudio;
        const cfg = audio.aac.parseConfig(asc) orelse return error.UnsupportedCodec;
        return .{
            .codec = .aac,
            .sample_rate = cfg.sample_rate,
            .channels = cfg.channels,
            .aac_config = cfg,
        };
    }

    var little_endian = false;
    if (findBoxRecursive(children, "enda")) |enda| {
        if (enda.len >= 2 and std.mem.readInt(u16, enda[0..2], .big) == 1) {
            little_endian = true;
        }
    }

    if (std.mem.eql(u8, &entry.kind, "sowt")) {
        return .{ .codec = if (sample_size == 8) .pcm_s8 else .pcm_s16le, .sample_rate = sample_rate, .channels = channels };
    }
    if (std.mem.eql(u8, &entry.kind, "twos")) {
        return .{ .codec = if (sample_size == 8) .pcm_s8 else .pcm_s16be, .sample_rate = sample_rate, .channels = channels };
    }
    if (std.mem.eql(u8, &entry.kind, "raw ") or std.mem.eql(u8, &entry.kind, "NONE")) {
        return .{ .codec = .pcm_u8, .sample_rate = sample_rate, .channels = channels };
    }
    if (std.mem.eql(u8, &entry.kind, "in24")) {
        return .{ .codec = if (little_endian) .pcm_s24le else .pcm_s24be, .sample_rate = sample_rate, .channels = channels };
    }
    if (std.mem.eql(u8, &entry.kind, "in32")) {
        return .{ .codec = if (little_endian) .pcm_s32le else .pcm_s32be, .sample_rate = sample_rate, .channels = channels };
    }
    if (std.mem.eql(u8, &entry.kind, "fl32")) {
        return .{ .codec = if (little_endian) .float_f32le else .float_f32be, .sample_rate = sample_rate, .channels = channels };
    }
    if (std.mem.eql(u8, &entry.kind, "lpcm")) {
        if (version == 2 and entry.payload.len >= 56) {
            const flags = std.mem.readInt(u32, entry.payload[52..56], .big);
            const is_float = (flags & 1) != 0;
            const is_be = (flags & 2) != 0;
            if (is_float and sample_size == 32) {
                return .{ .codec = if (is_be) .float_f32be else .float_f32le, .sample_rate = sample_rate, .channels = channels };
            }
            if (sample_size == 24) return .{ .codec = if (is_be) .pcm_s24be else .pcm_s24le, .sample_rate = sample_rate, .channels = channels };
            if (sample_size == 32) return .{ .codec = if (is_be) .pcm_s32be else .pcm_s32le, .sample_rate = sample_rate, .channels = channels };
            if (sample_size == 8) return .{ .codec = if ((flags & 4) != 0) .pcm_s8 else .pcm_u8, .sample_rate = sample_rate, .channels = channels };
            return .{ .codec = if (is_be) .pcm_s16be else .pcm_s16le, .sample_rate = sample_rate, .channels = channels };
        }
        return .{
            .codec = switch (sample_size) {
                8 => .pcm_u8,
                24 => .pcm_s24le,
                32 => .pcm_s32le,
                else => .pcm_s16le,
            },
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }
    if (std.mem.eql(u8, &entry.kind, "ulaw")) {
        return .{ .codec = .ulaw, .sample_rate = sample_rate, .channels = channels };
    }
    if (std.mem.eql(u8, &entry.kind, "alaw")) {
        return .{ .codec = .alaw, .sample_rate = sample_rate, .channels = channels };
    }
    return error.UnsupportedCodec;
}

fn parseAudioStbl(gpa: std.mem.Allocator, file_size: u64, stbl: []const u8, mdhd_timescale: u32) !AudioTrack {
    var stsd_box: ?[]const u8 = null;
    var stts_box: ?[]const u8 = null;
    var stsc_box: ?[]const u8 = null;
    var stsz_box: ?[]const u8 = null;
    var stco_box: ?[]const u8 = null;
    var co64_box: ?[]const u8 = null;

    var at: usize = 0;
    while (nextBox(stbl, at)) |b| : (at = b.next) {
        if (std.mem.eql(u8, &b.kind, "stsd")) stsd_box = b.payload else if (std.mem.eql(u8, &b.kind, "stts")) stts_box = b.payload else if (std.mem.eql(u8, &b.kind, "stsc")) stsc_box = b.payload else if (std.mem.eql(u8, &b.kind, "stsz")) stsz_box = b.payload else if (std.mem.eql(u8, &b.kind, "stco")) stco_box = b.payload else if (std.mem.eql(u8, &b.kind, "co64")) co64_box = b.payload;
    }

    const info = try parseAudioStsd(stsd_box orelse return error.InvalidAudio, mdhd_timescale);
    const timescale = if (mdhd_timescale > 0) mdhd_timescale else info.sample_rate;

    const stsz = stsz_box orelse return error.InvalidAudio;
    if (stsz.len < 12) return error.InvalidAudio;
    const default_size = std.mem.readInt(u32, stsz[4..8], .big);
    const sample_count_raw = std.mem.readInt(u32, stsz[8..12], .big);
    if (sample_count_raw == 0) return error.InvalidAudio;

    const stsc = stsc_box orelse return error.InvalidAudio;
    if (stsc.len < 8) return error.InvalidAudio;
    const stsc_count = std.mem.readInt(u32, stsc[4..8], .big);
    if (stsc_count == 0 or stsc.len < 8 + @as(usize, stsc_count) * 12) return error.InvalidAudio;

    const chunk_count: usize = if (stco_box) |co| blk: {
        if (co.len < 8) return error.InvalidAudio;
        const c = std.mem.readInt(u32, co[4..8], .big);
        if (co.len < 8 + @as(usize, c) * 4) return error.InvalidAudio;
        break :blk c;
    } else if (co64_box) |co| blk: {
        if (co.len < 8) return error.InvalidAudio;
        const c = std.mem.readInt(u32, co[4..8], .big);
        if (co.len < 8 + @as(usize, c) * 8) return error.InvalidAudio;
        break :blk c;
    } else return error.InvalidAudio;
    if (chunk_count == 0) return error.InvalidAudio;

    var packets: std.ArrayList(AudioPacket) = .empty;
    errdefer packets.deinit(gpa);
    var max_packet_size: u32 = 0;

    if (info.codec != .aac and default_size != 0) {
        // Constant-size PCM / G.711 samples: group contiguous chunk frames into packets of up to 1024 frames.
        const bpf: u32 = @as(u32, info.codec.bytesPerSample()) * info.channels;
        if (bpf == 0) return error.InvalidAudio;
        var stsc_idx: usize = 0;
        var total_frames: u64 = 0;
        var samples_left: u64 = sample_count_raw;

        for (0..chunk_count) |chunk_idx| {
            if (samples_left == 0 or packets.items.len >= max_audio_packets) break;
            const chunk_1based = chunk_idx + 1;
            while (stsc_idx + 1 < stsc_count) {
                const next_first = std.mem.readInt(u32, stsc[8 + (stsc_idx + 1) * 12 ..][0..4], .big);
                if (chunk_1based >= next_first) stsc_idx += 1 else break;
            }
            const per_chunk: u64 = @min(@as(u64, std.mem.readInt(u32, stsc[8 + stsc_idx * 12 + 4 ..][0..4], .big)), samples_left);
            var offset: u64 = if (stco_box) |co|
                std.mem.readInt(u32, co[8 + chunk_idx * 4 ..][0..4], .big)
            else
                std.mem.readInt(u64, co64_box.?[8 + chunk_idx * 8 ..][0..8], .big);

            var chunk_frames: u64 = if (default_size == bpf)
                per_chunk
            else if (default_size > bpf and default_size % bpf == 0)
                per_chunk * (default_size / bpf)
            else
                per_chunk;

            samples_left -|= per_chunk;
            while (chunk_frames > 0 and packets.items.len < max_audio_packets) {
                const pkt_frames: u32 = @intCast(@min(chunk_frames, 1024));
                const pkt_bytes: u32 = pkt_frames * bpf;
                if (offset + pkt_bytes > file_size) break;
                const pts_us: u64 = (total_frames * 1_000_000) / @max(info.sample_rate, 1);
                try packets.append(gpa, .{
                    .offset = offset,
                    .size = pkt_bytes,
                    .pts_us = pts_us,
                    .frames = pkt_frames,
                });
                max_packet_size = @max(max_packet_size, pkt_bytes);
                offset += pkt_bytes;
                total_frames += pkt_frames;
                chunk_frames -= pkt_frames;
            }
        }
    } else {
        // Variable-size packets (AAC or chunked PCM with explicit stsz table).
        const sample_count: usize = @min(sample_count_raw, max_audio_packets);
        if (default_size == 0 and stsz.len < 12 + sample_count * 4) return error.InvalidAudio;
        const bpf: u32 = if (info.codec == .aac) 0 else @as(u32, info.codec.bytesPerSample()) * info.channels;

        var sample_idx: usize = 0;
        var stsc_idx: usize = 0;
        for (0..chunk_count) |chunk_idx| {
            if (sample_idx >= sample_count) break;
            const chunk_1based = chunk_idx + 1;
            while (stsc_idx + 1 < stsc_count) {
                const next_first = std.mem.readInt(u32, stsc[8 + (stsc_idx + 1) * 12 ..][0..4], .big);
                if (chunk_1based >= next_first) stsc_idx += 1 else break;
            }
            const per_chunk = std.mem.readInt(u32, stsc[8 + stsc_idx * 12 + 4 ..][0..4], .big);
            var offset: u64 = if (stco_box) |co|
                std.mem.readInt(u32, co[8 + chunk_idx * 4 ..][0..4], .big)
            else
                std.mem.readInt(u64, co64_box.?[8 + chunk_idx * 8 ..][0..8], .big);

            var j: u32 = 0;
            while (j < per_chunk and sample_idx < sample_count) : (j += 1) {
                const sz = if (default_size != 0)
                    default_size
                else
                    std.mem.readInt(u32, stsz[12 + sample_idx * 4 ..][0..4], .big);
                if (sz == 0 or sz > max_audio_packet_bytes or offset + sz > file_size) {
                    if (sample_idx == 0) return error.InvalidAudio;
                    break;
                }
                const pkt_frames: u32 = if (info.codec == .aac)
                    audio.aac.frame_samples
                else if (bpf > 0)
                    sz / bpf
                else
                    1024;
                try packets.append(gpa, .{
                    .offset = offset,
                    .size = sz,
                    .pts_us = 0,
                    .frames = pkt_frames,
                });
                max_packet_size = @max(max_packet_size, sz);
                offset += sz;
                sample_idx += 1;
            }
        }

        // Fill timestamps from stts (or fallback to frame counter).
        var dts_ticks: u64 = 0;
        var idx: usize = 0;
        if (stts_box) |stts| if (stts.len >= 8) {
            const count = std.mem.readInt(u32, stts[4..8], .big);
            var entry_i: usize = 0;
            while (entry_i < count and 8 + (entry_i + 1) * 8 <= stts.len and idx < packets.items.len) : (entry_i += 1) {
                const n = std.mem.readInt(u32, stts[8 + entry_i * 8 ..][0..4], .big);
                const delta = std.mem.readInt(u32, stts[8 + entry_i * 8 + 4 ..][0..4], .big);
                var k: u32 = 0;
                while (k < n and idx < packets.items.len) : (k += 1) {
                    packets.items[idx].pts_us = (dts_ticks * 1_000_000) / @max(timescale, 1);
                    dts_ticks += delta;
                    idx += 1;
                }
            }
        };
        while (idx < packets.items.len) : (idx += 1) {
            packets.items[idx].pts_us = (@as(u64, idx) * 1024 * 1_000_000) / @max(info.sample_rate, 1);
        }
    }

    if (packets.items.len == 0) return error.InvalidAudio;
    return .{
        .codec = info.codec,
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .aac_config = info.aac_config,
        .packets = try packets.toOwnedSlice(gpa),
        .max_packet_size = max_packet_size,
    };
}

pub fn decodeAudioPcmPacket(codec: AudioCodec, channels: u8, raw: []const u8, out: *[1024][2]i16) usize {
    const bps = codec.bytesPerSample();
    if (bps == 0 or channels == 0) return 0;
    const bpf: usize = @as(usize, bps) * channels;
    const count = @min(raw.len / bpf, out.len);
    for (0..count) |i| {
        const frame = raw[i * bpf ..][0..bpf];
        const l = decodeOneSample(codec, frame[0..bps]);
        const r = if (channels >= 2) decodeOneSample(codec, frame[bps .. bps * 2]) else l;
        out[i] = .{ l, r };
    }
    return count;
}

fn decodeOneSample(codec: AudioCodec, bytes: []const u8) i16 {
    return switch (codec) {
        .aac => 0,
        .pcm_u8 => (@as(i16, bytes[0]) - 128) << 8,
        .pcm_s8 => @as(i16, @as(i8, @bitCast(bytes[0]))) << 8,
        .pcm_s16le => std.mem.readInt(i16, bytes[0..2], .little),
        .pcm_s16be => std.mem.readInt(i16, bytes[0..2], .big),
        .pcm_s24le => @intCast((@as(i32, @as(i8, @bitCast(bytes[2]))) << 8) | bytes[1]),
        .pcm_s24be => @intCast((@as(i32, @as(i8, @bitCast(bytes[0]))) << 8) | bytes[1]),
        .pcm_s32le => @intCast(std.mem.readInt(i32, bytes[0..4], .little) >> 16),
        .pcm_s32be => @intCast(std.mem.readInt(i32, bytes[0..4], .big) >> 16),
        .float_f32le => blk: {
            const f: f32 = @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
            if (std.math.isNan(f)) break :blk 0;
            break :blk @intFromFloat(std.math.clamp(f * 32767.0, -32768.0, 32767.0));
        },
        .float_f32be => blk: {
            const f: f32 = @bitCast(std.mem.readInt(u32, bytes[0..4], .big));
            if (std.math.isNan(f)) break :blk 0;
            break :blk @intFromFloat(std.math.clamp(f * 32767.0, -32768.0, 32767.0));
        },
        .ulaw => decodeUlaw(bytes[0]),
        .alaw => decodeAlaw(bytes[0]),
    };
}

fn decodeUlaw(u_val: u8) i16 {
    const u = ~u_val;
    const t: i32 = ((@as(i32, u & 0x0f) << 3) + 0x84) << @as(u4, @intCast((u & 0x70) >> 4));
    const v: i32 = if ((u & 0x80) != 0) (0x84 - t) else (t - 0x84);
    return @intCast(std.math.clamp(v, -32768, 32767));
}

fn decodeAlaw(a_val: u8) i16 {
    const a = a_val ^ 0x55;
    var t: i32 = (@as(i32, a & 0x0f) << 4) + 8;
    const seg: u4 = @intCast((a & 0x70) >> 4);
    if (seg != 0) t = (t + 0x100) << (seg - 1);
    const v: i32 = if ((a & 0x80) != 0) t else -t;
    return @intCast(std.math.clamp(v, -32768, 32767));
}

// --- Raw Annex-B H.264 stream parser & SPS decoder ---------------------------

const StartCode = struct {
    pos: usize,
    end: usize,
};

fn nextStartCode(data: []const u8, from: usize) ?StartCode {
    var i = from;
    while (i + 3 <= data.len) : (i += 1) {
        if (data[i] != 0 or data[i + 1] != 0) continue;
        if (data[i + 2] == 1) return .{ .pos = i, .end = i + 3 };
        if (i + 4 <= data.len and data[i + 2] == 0 and data[i + 3] == 1) return .{ .pos = i, .end = i + 4 };
    }
    return null;
}

pub const SpsInfo = struct {
    width: u32,
    height: u32,
    frame_duration_us: u64 = 40_000, // 25 fps default when VUI timing is absent
};

/// Parses an H.264 Sequence Parameter Set (SPS) NAL unit (starting at the
/// NAL header byte `0x67`/`0x27`/`0x07`) to find the picture size and
/// frame rate.
pub fn parseSps(nal: []const u8) ?SpsInfo {
    if (nal.len < 4 or (nal[0] & 0x1f) != 7) return null;
    // Remove emulation prevention bytes (00 00 03 -> 00 00) from the first
    // 128 bytes of the SPS RBSP.
    var rbsp: [128]u8 = undefined;
    var rbsp_len: usize = 0;
    var i: usize = 1;
    while (i < nal.len and rbsp_len < rbsp.len) : (i += 1) {
        if (i + 2 < nal.len and nal[i] == 0 and nal[i + 1] == 0 and nal[i + 2] == 3) {
            rbsp[rbsp_len] = 0;
            rbsp_len += 1;
            if (rbsp_len < rbsp.len) {
                rbsp[rbsp_len] = 0;
                rbsp_len += 1;
            }
            i += 2;
        } else {
            rbsp[rbsp_len] = nal[i];
            rbsp_len += 1;
        }
    }
    var br: BitReader = .{ .data = rbsp[0..rbsp_len] };
    const profile_idc = br.readBits(8) orelse return null;
    _ = br.readBits(8) orelse return null; // constraint flags + reserved
    _ = br.readBits(8) orelse return null; // level_idc
    _ = br.readUe() orelse return null; // seq_parameter_set_id

    var chroma_format_idc: u32 = 1;
    switch (profile_idc) {
        100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 => {
            chroma_format_idc = br.readUe() orelse return null;
            if (chroma_format_idc == 3) _ = br.readBits(1) orelse return null;
            _ = br.readUe() orelse return null; // bit_depth_luma_minus8
            _ = br.readUe() orelse return null; // bit_depth_chroma_minus8
            _ = br.readBits(1) orelse return null; // qpprime_y_zero_transform_bypass_flag
            const scaling = br.readBits(1) orelse return null;
            if (scaling != 0) {
                const count: usize = if (chroma_format_idc != 3) 8 else 12;
                for (0..count) |idx| {
                    const present = br.readBits(1) orelse return null;
                    if (present != 0) {
                        const sz: usize = if (idx < 6) 16 else 64;
                        var last: i32 = 8;
                        var next: i32 = 8;
                        for (0..sz) |_| {
                            if (next != 0) {
                                const delta = br.readSe() orelse return null;
                                next = @mod(last + delta + 256, 256);
                            }
                            last = if (next == 0) last else next;
                        }
                    }
                }
            }
        },
        else => {},
    }

    _ = br.readUe() orelse return null; // log2_max_frame_num_minus4
    const poc_type = br.readUe() orelse return null;
    if (poc_type == 0) {
        _ = br.readUe() orelse return null;
    } else if (poc_type == 1) {
        _ = br.readBits(1) orelse return null;
        _ = br.readSe() orelse return null;
        _ = br.readSe() orelse return null;
        const n = br.readUe() orelse return null;
        if (n > 255) return null;
        for (0..n) |_| _ = br.readSe() orelse return null;
    }
    _ = br.readUe() orelse return null; // max_num_ref_frames
    _ = br.readBits(1) orelse return null; // gaps_in_frame_num_value_allowed_flag
    const pic_width_in_mbs_minus1 = br.readUe() orelse return null;
    const pic_height_in_map_units_minus1 = br.readUe() orelse return null;
    const frame_mbs_only_flag = br.readBits(1) orelse return null;
    if (frame_mbs_only_flag == 0) _ = br.readBits(1) orelse return null;
    _ = br.readBits(1) orelse return null; // direct_8x8_inference_flag

    var width: u32 = (pic_width_in_mbs_minus1 + 1) * 16;
    var height: u32 = (2 - frame_mbs_only_flag) * (pic_height_in_map_units_minus1 + 1) * 16;

    const frame_cropping_flag = br.readBits(1) orelse return null;
    if (frame_cropping_flag != 0) {
        const left = br.readUe() orelse return null;
        const right = br.readUe() orelse return null;
        const top = br.readUe() orelse return null;
        const bottom = br.readUe() orelse return null;
        const sub_w: u32 = if (chroma_format_idc == 1 or chroma_format_idc == 2) 2 else 1;
        const sub_h: u32 = (if (chroma_format_idc == 1) @as(u32, 2) else 1) * (2 - frame_mbs_only_flag);
        width -|= (left + right) * sub_w;
        height -|= (top + bottom) * sub_h;
    }
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return null;

    var frame_duration_us: u64 = 40_000;
    if (br.readBits(1)) |vui| if (vui != 0) {
        if (br.readBits(1)) |ar| if (ar != 0) {
            if (br.readBits(8)) |idc| if (idc == 255) {
                _ = br.readBits(16);
                _ = br.readBits(16);
            };
        };
        if (br.readBits(1)) |overscan| if (overscan != 0) {
            _ = br.readBits(1);
        };
        if (br.readBits(1)) |vid_sig| if (vid_sig != 0) {
            _ = br.readBits(4);
            if (br.readBits(1)) |cd| if (cd != 0) {
                _ = br.readBits(24);
            };
        };
        if (br.readBits(1)) |chroma_loc| if (chroma_loc != 0) {
            _ = br.readUe();
            _ = br.readUe();
        };
        if (br.readBits(1)) |timing| if (timing != 0) {
            const units = br.readBits(32) orelse 0;
            const scale = br.readBits(32) orelse 0;
            if (units > 0 and scale > units * 2) {
                frame_duration_us = @max(@as(u64, units) * 2_000_000 / scale, 1_000);
            }
        };
    };
    return .{ .width = width, .height = height, .frame_duration_us = frame_duration_us };
}

const BitReader = struct {
    data: []const u8,
    bit: usize = 0,

    fn readBits(b: *BitReader, n: u6) ?u32 {
        if (n == 0) return 0;
        if (b.bit + n > b.data.len * 8) return null;
        var v: u32 = 0;
        var k: u6 = 0;
        while (k < n) : (k += 1) {
            const byte = b.data[b.bit >> 3];
            const shift: u3 = @intCast(7 - (b.bit & 7));
            v = (v << 1) | ((byte >> shift) & 1);
            b.bit += 1;
        }
        return v;
    }

    fn readUe(b: *BitReader) ?u32 {
        var zeros: u5 = 0;
        while (true) {
            const bit = b.readBits(1) orelse return null;
            if (bit == 1) break;
            if (zeros == 31) return null;
            zeros += 1;
        }
        if (zeros == 0) return 0;
        const tail = b.readBits(zeros) orelse return null;
        return (@as(u32, 1) << zeros) - 1 + tail;
    }

    fn readSe(b: *BitReader) ?i32 {
        const code = b.readUe() orelse return null;
        const mag: i32 = @intCast((code + 1) >> 1);
        return if (code & 1 != 0) mag else -mag;
    }
};

fn parseAnnexB(gpa: std.mem.Allocator, fd: linux.fd_t, file_size: u64) !Stream {
    if (file_size == 0 or file_size > max_annexb_bytes) return error.InvalidVideo;
    const len: usize = @intCast(file_size);
    const data = try gpa.alloc(u8, len);
    defer gpa.free(data);
    if ((try preadInto(fd, data, 0)) != len) return error.InvalidVideo;

    var sps_info: ?SpsInfo = null;
    var header: std.ArrayList(u8) = .empty;
    errdefer header.deinit(gpa);
    var samples: std.ArrayList(Sample) = .empty;
    errdefer samples.deinit(gpa);

    var frame_start: ?usize = null;
    var has_slice = false;
    var is_keyframe = false;
    var pts_us: u64 = 0;

    var sc_opt = nextStartCode(data, 0);
    while (sc_opt) |sc| {
        const next_sc = nextStartCode(data, sc.end);
        const nal_end = if (next_sc) |n| n.pos else data.len;
        if (sc.end < nal_end) {
            const nal = data[sc.end..nal_end];
            const nal_type = nal[0] & 0x1f;
            if ((nal_type == 7 or nal_type == 8 or nal_type == 9) and has_slice) {
                const start = frame_start.?;
                const step_us = if (sps_info) |info| info.frame_duration_us else 40_000;
                try samples.append(gpa, .{
                    .offset = start,
                    .size = @intCast(sc.pos - start),
                    .pts_us = pts_us,
                    .keyframe = is_keyframe,
                });
                pts_us += step_us;
                frame_start = sc.pos;
                has_slice = false;
                is_keyframe = false;
            }
            if (frame_start == null) frame_start = sc.pos;
            if (nal_type == 7) {
                if (sps_info == null) {
                    sps_info = parseSps(nal);
                    try header.appendSlice(gpa, data[sc.pos..nal_end]);
                }
            } else if (nal_type == 8 and header.items.len > 0 and samples.items.len == 0) {
                try header.appendSlice(gpa, data[sc.pos..nal_end]);
            } else if (nal_type == 1 or nal_type == 5) {
                if (has_slice) {
                    // Check first_mb_in_slice == 0 (ue(v) starts with a '1' bit):
                    // a new frame's first slice starts at macroblock 0.
                    if (nal.len >= 2 and (nal[1] & 0x80) != 0) {
                        const start = frame_start.?;
                        const step_us = if (sps_info) |info| info.frame_duration_us else 40_000;
                        try samples.append(gpa, .{
                            .offset = start,
                            .size = @intCast(sc.pos - start),
                            .pts_us = pts_us,
                            .keyframe = is_keyframe,
                        });
                        pts_us += step_us;
                        frame_start = sc.pos;
                        is_keyframe = false;
                    }
                }
                has_slice = true;
                if (nal_type == 5) is_keyframe = true;
            }
        }
        sc_opt = next_sc;
    }
    if (has_slice) if (frame_start) |start| {
        try samples.append(gpa, .{
            .offset = start,
            .size = @intCast(data.len - start),
            .pts_us = pts_us,
            .keyframe = is_keyframe or samples.items.len == 0,
        });
        pts_us += if (sps_info) |info| info.frame_duration_us else 40_000;
    };

    const info = sps_info orelse return error.InvalidVideo;
    if (samples.items.len == 0) return error.InvalidVideo;
    samples.items[0].keyframe = true;

    return .{
        .gpa = gpa,
        .fd = fd,
        .codec = .h264,
        .width = info.width,
        .height = info.height,
        .duration_us = pts_us,
        .samples = try samples.toOwnedSlice(gpa),
        .header = try header.toOwnedSlice(gpa),
        .nal_length_size = 0,
    };
}

// --- V4L2 M2M hardware video decoder -----------------------------------------

const max_buffers = 6;

const MappedBuf = struct {
    data: []align(std.heap.page_size_min) u8 = &.{},
    queued: bool = false,
};

pub const DecodedFrame = struct {
    index: u32,
    data: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    slice_height: u32,
    pixfmt: u32,
    pts_us: u64,
    last: bool,
};

pub const Decoder = struct {
    fd: linux.fd_t,
    out_bufs: [max_buffers]MappedBuf = @splat(.{}),
    out_count: u32 = 0,
    cap_bufs: [max_buffers]MappedBuf = @splat(.{}),
    cap_count: u32 = 0,
    out_streaming: bool = false,
    cap_streaming: bool = false,
    width: u32,
    height: u32,
    stride: u32 = 0,
    slice_height: u32 = 0,
    pixfmt: u32 = v4l2.pix_fmt_yuv420,
    eos: bool = false,

    pub fn open(codec: Codec, width: u32, height: u32) !Decoder {
        const fd = try openDevice(codec.fourcc());
        errdefer sys.close(fd);

        for ([_]u32{ v4l2.event_source_change, v4l2.event_eos }) |ev_type| {
            var sub: v4l2.EventSubscription = .{ .type = ev_type };
            _ = linux.ioctl(fd, v4l2.subscribe_event, @intFromPtr(&sub));
        }

        const out_size: u32 = if (width * height > 1280 * 720) max_frame_bytes else 512 * 1024;
        var out_fmt: v4l2.Format = .{
            .type = v4l2.buf_type_video_output_mplane,
            .fmt = .{ .pix_mp = .{
                .width = width,
                .height = height,
                .pixelformat = codec.fourcc(),
                .num_planes = 1,
                .plane_fmt = blk: {
                    var p: [8]v4l2.PlanePixFormat = @splat(.{});
                    p[0] = .{ .sizeimage = out_size };
                    break :blk p;
                },
            } },
        };
        try ioctl(fd, v4l2.s_fmt, &out_fmt);

        var cap_fmt: v4l2.Format = .{
            .type = v4l2.buf_type_video_capture_mplane,
            .fmt = .{ .pix_mp = .{
                .width = width,
                .height = std.mem.alignForward(u32, height, 16),
                .pixelformat = v4l2.pix_fmt_yuv420,
                .num_planes = 1,
            } },
        };
        try ioctl(fd, v4l2.s_fmt, &cap_fmt);

        var d: Decoder = .{
            .fd = fd,
            .width = width,
            .height = height,
            .stride = cap_fmt.fmt.pix_mp.plane_fmt[0].bytesperline,
            .slice_height = cap_fmt.fmt.pix_mp.height,
            .pixfmt = cap_fmt.fmt.pix_mp.pixelformat,
        };
        errdefer d.deinit();

        try d.allocBuffers(v4l2.buf_type_video_output_mplane, 4, &d.out_bufs, &d.out_count);
        try d.allocBuffers(v4l2.buf_type_video_capture_mplane, 4, &d.cap_bufs, &d.cap_count);
        try d.queueAllCapture();

        var out_type: c_int = v4l2.buf_type_video_output_mplane;
        try ioctl(fd, v4l2.streamon, &out_type);
        d.out_streaming = true;

        var cap_type: c_int = v4l2.buf_type_video_capture_mplane;
        try ioctl(fd, v4l2.streamon, &cap_type);
        d.cap_streaming = true;

        return d;
    }

    pub fn deinit(d: *Decoder) void {
        d.stopStreaming();
        freeBuffers(d.fd, v4l2.buf_type_video_output_mplane, &d.out_bufs, &d.out_count);
        freeBuffers(d.fd, v4l2.buf_type_video_capture_mplane, &d.cap_bufs, &d.cap_count);
        sys.close(d.fd);
    }

    fn allocBuffers(d: *Decoder, buf_type: u32, wanted: u32, bufs: *[max_buffers]MappedBuf, count_out: *u32) !void {
        var req: v4l2.RequestBuffers = .{ .count = wanted, .type = buf_type, .memory = v4l2.memory_mmap };
        try ioctl(d.fd, v4l2.reqbufs, &req);
        if (req.count == 0) return error.NoBuffers;
        const count = @min(req.count, max_buffers);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var plane: v4l2.Plane = .{};
            var b: v4l2.Buffer = .{
                .index = i,
                .type = buf_type,
                .memory = v4l2.memory_mmap,
                .m = .{ .planes = @ptrCast(&plane) },
                .length = 1,
            };
            try ioctl(d.fd, v4l2.querybuf, &b);
            if (plane.length == 0) return error.NoBuffers;
            const addr = try sys.check(linux.mmap(null, plane.length, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, d.fd, plane.m.mem_offset));
            bufs[i] = .{ .data = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..plane.length], .queued = false };
            count_out.* = i + 1;
        }
    }

    fn freeBuffers(fd: linux.fd_t, buf_type: u32, bufs: *[max_buffers]MappedBuf, count: *u32) void {
        for (bufs[0..count.*]) |*b| {
            if (b.data.len > 0) _ = linux.munmap(b.data.ptr, b.data.len);
            b.* = .{};
        }
        count.* = 0;
        var req: v4l2.RequestBuffers = .{ .count = 0, .type = buf_type, .memory = v4l2.memory_mmap };
        _ = linux.ioctl(fd, v4l2.reqbufs, @intFromPtr(&req));
    }

    fn queueAllCapture(d: *Decoder) !void {
        for (0..d.cap_count) |i| {
            if (!d.cap_bufs[i].queued) try d.queueCapture(@intCast(i));
        }
    }

    pub fn queueCapture(d: *Decoder, index: u32) !void {
        var plane: v4l2.Plane = .{ .length = @intCast(d.cap_bufs[index].data.len) };
        var b: v4l2.Buffer = .{
            .index = index,
            .type = v4l2.buf_type_video_capture_mplane,
            .memory = v4l2.memory_mmap,
            .m = .{ .planes = @ptrCast(&plane) },
            .length = 1,
        };
        try ioctl(d.fd, v4l2.qbuf, &b);
        d.cap_bufs[index].queued = true;
    }

    /// Reclaims any finished output buffers and returns the index of a
    /// free output buffer, if one is ready.
    pub fn acquireOutput(d: *Decoder) ?u32 {
        while (true) {
            var plane: v4l2.Plane = .{};
            var b: v4l2.Buffer = .{
                .type = v4l2.buf_type_video_output_mplane,
                .memory = v4l2.memory_mmap,
                .m = .{ .planes = @ptrCast(&plane) },
                .length = 1,
            };
            if (linux.errno(linux.ioctl(d.fd, v4l2.dqbuf, @intFromPtr(&b))) != .SUCCESS) break;
            if (b.index < d.out_count) d.out_bufs[b.index].queued = false;
        }
        for (0..d.out_count) |i| {
            if (!d.out_bufs[i].queued) return @intCast(i);
        }
        return null;
    }

    pub fn outputBuffer(d: *Decoder, index: u32) []u8 {
        return d.out_bufs[index].data;
    }

    pub fn submitOutput(d: *Decoder, index: u32, used: usize, pts_us: u64, keyframe: bool) !void {
        var plane: v4l2.Plane = .{
            .bytesused = @intCast(used),
            .length = @intCast(d.out_bufs[index].data.len),
        };
        var b: v4l2.Buffer = .{
            .index = index,
            .type = v4l2.buf_type_video_output_mplane,
            .field = v4l2.field_none,
            .flags = if (keyframe) v4l2.buf_flag_keyframe else 0,
            .timestamp = .{
                .sec = @intCast(pts_us / 1_000_000),
                .usec = @intCast(pts_us % 1_000_000),
            },
            .memory = v4l2.memory_mmap,
            .m = .{ .planes = @ptrCast(&plane) },
            .length = 1,
        };
        try ioctl(d.fd, v4l2.qbuf, &b);
        d.out_bufs[index].queued = true;
    }

    pub fn sendEos(d: *Decoder) void {
        var cmd: v4l2.DecoderCmd = .{ .cmd = v4l2.dec_cmd_stop };
        _ = linux.ioctl(d.fd, v4l2.decoder_cmd, @intFromPtr(&cmd));
    }

    /// Processes pending V4L2 events (including resolution changes) and
    /// dequeues the next decoded capture frame, if one is ready.
    pub fn nextFrame(d: *Decoder) !?DecodedFrame {
        try d.pollEvents();
        if (!d.cap_streaming) return null;

        var plane: v4l2.Plane = .{};
        var b: v4l2.Buffer = .{
            .type = v4l2.buf_type_video_capture_mplane,
            .memory = v4l2.memory_mmap,
            .m = .{ .planes = @ptrCast(&plane) },
            .length = 1,
        };
        switch (linux.errno(linux.ioctl(d.fd, v4l2.dqbuf, @intFromPtr(&b)))) {
            .SUCCESS => {},
            .AGAIN, .PIPE => return null,
            else => return error.DecodeFailed,
        }
        if (b.index >= d.cap_count) return null;
        d.cap_bufs[b.index].queued = false;
        const last = (b.flags & v4l2.buf_flag_last) != 0;
        if (last) d.eos = true;
        if (plane.bytesused == 0 or (b.flags & v4l2.buf_flag_error) != 0) {
            if (!last) d.queueCapture(b.index) catch {};
            return null;
        }
        const pts_us: u64 = @as(u64, @intCast(@max(b.timestamp.sec, 0))) * 1_000_000 +
            @as(u64, @intCast(@max(b.timestamp.usec, 0)));
        return .{
            .index = b.index,
            .data = d.cap_bufs[b.index].data[0..@min(plane.bytesused, d.cap_bufs[b.index].data.len)],
            .width = d.width,
            .height = d.height,
            .stride = d.stride,
            .slice_height = d.slice_height,
            .pixfmt = d.pixfmt,
            .pts_us = pts_us,
            .last = last,
        };
    }

    fn pollEvents(d: *Decoder) !void {
        while (true) {
            var ev: v4l2.Event = .{};
            if (linux.errno(linux.ioctl(d.fd, v4l2.dqevent, @intFromPtr(&ev))) != .SUCCESS) break;
            switch (ev.type) {
                v4l2.event_source_change => try d.handleSourceChange(),
                v4l2.event_eos => d.eos = true,
                else => {},
            }
        }
    }

    fn handleSourceChange(d: *Decoder) !void {
        if (d.cap_streaming) {
            var cap_type: c_int = v4l2.buf_type_video_capture_mplane;
            _ = linux.ioctl(d.fd, v4l2.streamoff, @intFromPtr(&cap_type));
            d.cap_streaming = false;
        }
        freeBuffers(d.fd, v4l2.buf_type_video_capture_mplane, &d.cap_bufs, &d.cap_count);

        var fmt: v4l2.Format = .{ .type = v4l2.buf_type_video_capture_mplane, .fmt = .{ .pix_mp = .{} } };
        try ioctl(d.fd, v4l2.g_fmt, &fmt);
        if (fmt.fmt.pix_mp.pixelformat != v4l2.pix_fmt_yuv420 and
            fmt.fmt.pix_mp.pixelformat != v4l2.pix_fmt_nv12)
        {
            fmt.fmt.pix_mp.pixelformat = v4l2.pix_fmt_yuv420;
            try ioctl(d.fd, v4l2.s_fmt, &fmt);
        }
        d.stride = fmt.fmt.pix_mp.plane_fmt[0].bytesperline;
        d.slice_height = fmt.fmt.pix_mp.height;
        d.pixfmt = fmt.fmt.pix_mp.pixelformat;
        d.width = fmt.fmt.pix_mp.width;
        d.height = fmt.fmt.pix_mp.height;

        var sel: v4l2.Selection = .{
            .type = v4l2.buf_type_video_capture,
            .target = v4l2.sel_tgt_compose,
        };
        if (linux.errno(linux.ioctl(d.fd, v4l2.g_selection, @intFromPtr(&sel))) == .SUCCESS) {
            if (sel.r.width > 0 and sel.r.height > 0) {
                d.width = sel.r.width;
                d.height = sel.r.height;
            }
        }

        try d.allocBuffers(v4l2.buf_type_video_capture_mplane, 4, &d.cap_bufs, &d.cap_count);
        try d.queueAllCapture();
        var cap_type: c_int = v4l2.buf_type_video_capture_mplane;
        try ioctl(d.fd, v4l2.streamon, &cap_type);
        d.cap_streaming = true;
    }

    fn stopStreaming(d: *Decoder) void {
        if (d.out_streaming) {
            var out_type: c_int = v4l2.buf_type_video_output_mplane;
            _ = linux.ioctl(d.fd, v4l2.streamoff, @intFromPtr(&out_type));
            d.out_streaming = false;
        }
        if (d.cap_streaming) {
            var cap_type: c_int = v4l2.buf_type_video_capture_mplane;
            _ = linux.ioctl(d.fd, v4l2.streamoff, @intFromPtr(&cap_type));
            d.cap_streaming = false;
        }
        for (d.out_bufs[0..d.out_count]) |*b| b.queued = false;
        for (d.cap_bufs[0..d.cap_count]) |*b| b.queued = false;
    }

    /// Flushes both queues and restarts streaming (for seeking or replaying).
    pub fn reset(d: *Decoder) !void {
        d.stopStreaming();
        // Drain any pending events from before the flush.
        var ev: v4l2.Event = .{};
        while (linux.errno(linux.ioctl(d.fd, v4l2.dqevent, @intFromPtr(&ev))) == .SUCCESS) {}
        d.eos = false;
        try d.queueAllCapture();
        var out_type: c_int = v4l2.buf_type_video_output_mplane;
        try ioctl(d.fd, v4l2.streamon, &out_type);
        d.out_streaming = true;
        var cap_type: c_int = v4l2.buf_type_video_capture_mplane;
        try ioctl(d.fd, v4l2.streamon, &cap_type);
        d.cap_streaming = true;
    }
};

fn openDevice(wanted_fourcc: u32) !linux.fd_t {
    // Check /dev/video10 (bcm2835-codec-decode's default number) first.
    if (tryDevice(10, wanted_fourcc)) |fd| return fd;
    for (0..32) |n| {
        if (n == 10) continue;
        if (tryDevice(n, wanted_fourcc)) |fd| return fd;
    }
    return error.NoHardwareDecoder;
}

fn tryDevice(n: usize, wanted_fourcc: u32) ?linux.fd_t {
    var path_buf: [32]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/dev/video{d}", .{n}, 0) catch return null;
    const fd = sys.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }) catch return null;
    var cap: v4l2.Capability = undefined;
    if (linux.errno(linux.ioctl(fd, v4l2.querycap, @intFromPtr(&cap))) != .SUCCESS) {
        sys.close(fd);
        return null;
    }
    const caps = if (cap.device_caps != 0) cap.device_caps else cap.capabilities;
    if (caps & v4l2.cap_video_m2m_mplane == 0 or caps & v4l2.cap_streaming == 0) {
        sys.close(fd);
        return null;
    }
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var desc: v4l2.FmtDesc = .{ .index = i, .type = v4l2.buf_type_video_output_mplane };
        if (linux.errno(linux.ioctl(fd, v4l2.enum_fmt, @intFromPtr(&desc))) != .SUCCESS) break;
        if (desc.pixelformat == wanted_fourcc) return fd;
    }
    sys.close(fd);
    return null;
}

fn ioctl(fd: linux.fd_t, request: u32, arg: anytype) !void {
    switch (linux.errno(linux.ioctl(fd, request, @intFromPtr(arg)))) {
        .SUCCESS => {},
        else => return error.IoctlFailed,
    }
}

// --- YUV 4:2:0 (YU12 / YV12 / NV12) to 0xffRRGGBB conversion -----------------

pub const DisplaySize = struct {
    width: u32,
    height: u32,
};

pub fn displaySize(src_w: u32, src_h: u32) DisplaySize {
    if (src_w == 0 or src_h == 0) return .{ .width = 1, .height = 1 };
    if (src_w <= max_display_width and src_h <= max_display_height) {
        return .{ .width = src_w, .height = src_h };
    }
    const scale_w = (@as(u64, src_w) * max_display_height + src_h - 1) / src_h;
    if (scale_w <= max_display_width) {
        return .{ .width = @intCast(@max(scale_w, 1)), .height = max_display_height };
    }
    const scale_h = (@as(u64, src_h) * max_display_width + src_w - 1) / src_w;
    return .{ .width = max_display_width, .height = @intCast(@max(scale_h, 1)) };
}

pub fn yuvToArgb(
    data: []const u8,
    src_w: u32,
    src_h: u32,
    stride: u32,
    slice_h: u32,
    pixfmt: u32,
    dst: []u32,
    dst_w: u32,
    dst_h: u32,
) void {
    const bpl: usize = @max(stride, src_w);
    const sh: usize = @max(slice_h, src_h);
    const y_plane_len = bpl * sh;
    if (data.len < y_plane_len) return;
    const y_plane = data[0..y_plane_len];
    const chroma = data[y_plane_len..];

    const interleaved = pixfmt == v4l2.pix_fmt_nv12 or pixfmt == v4l2.pix_fmt_nv21;
    const swap_uv = pixfmt == v4l2.pix_fmt_yvu420 or pixfmt == v4l2.pix_fmt_nv21;
    const uv_stride: usize = if (interleaved) bpl else bpl / 2;
    const u_plane_len: usize = (bpl / 2) * (sh / 2);

    for (0..dst_h) |dy| {
        const sy: usize = dy * src_h / dst_h;
        const y_row = y_plane[sy * bpl ..];
        const uv_row_idx = sy >> 1;
        const out_row = dst[dy * dst_w ..][0..dst_w];

        for (0..dst_w) |dx| {
            const sx: usize = dx * src_w / dst_w;
            const y_val: i32 = y_row[sx];
            const cx: usize = sx >> 1;
            var u_val: i32 = 128;
            var v_val: i32 = 128;
            if (interleaved) {
                const idx = uv_row_idx * uv_stride + cx * 2;
                if (idx + 1 < chroma.len) {
                    u_val = chroma[if (swap_uv) idx + 1 else idx];
                    v_val = chroma[if (swap_uv) idx else idx + 1];
                }
            } else {
                const idx = uv_row_idx * uv_stride + cx;
                if (idx + u_plane_len < chroma.len) {
                    u_val = chroma[if (swap_uv) idx + u_plane_len else idx];
                    v_val = chroma[if (swap_uv) idx else idx + u_plane_len];
                }
            }
            out_row[dx] = yuvPixel(y_val, u_val, v_val);
        }
    }
}

fn yuvPixel(y: i32, u: i32, v: i32) u32 {
    // BT.601 studio swing (Y 16..235, Cb/Cr 16..240) to sRGB:
    const c = @max(y - 16, 0) * 298;
    const d = u - 128;
    const e = v - 128;
    const r: u32 = @intCast(std.math.clamp((c + 409 * e + 128) >> 8, 0, 255));
    const g: u32 = @intCast(std.math.clamp((c - 100 * d - 208 * e + 128) >> 8, 0, 255));
    const b: u32 = @intCast(std.math.clamp((c + 516 * d + 128) >> 8, 0, 255));
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

/// Converts a `width` by `height` `0xffRRGGBB` picture into planar YUV
/// 4:2:0 (`YU12`: `stride × slice_h` luma plane followed by `(stride/2) ×
/// (slice_h/2)` Cb and Cr planes) in `dst`, using BT.601 studio swing.
/// Returns the number of bytes written in `dst`.
pub fn argbToYuv420(
    src: []const u32,
    width: u32,
    height: u32,
    dst: []u8,
    stride: u32,
    slice_h: u32,
) usize {
    const w: usize = width;
    const h: usize = height;
    const bpl: usize = @max(stride, width);
    const sh: usize = @max(slice_h, height);
    const y_plane_len = bpl * sh;
    const uv_stride = bpl / 2;
    const u_plane_len = uv_stride * (sh / 2);
    const total_len = y_plane_len + 2 * u_plane_len;
    if (src.len < w * h or dst.len < total_len) return 0;

    const y_plane = dst[0..y_plane_len];
    const u_plane = dst[y_plane_len..][0..u_plane_len];
    const v_plane = dst[y_plane_len + u_plane_len ..][0..u_plane_len];

    var y: usize = 0;
    while (y + 1 < h) : (y += 2) {
        const src_row0 = src[y * w ..][0..w];
        const src_row1 = src[(y + 1) * w ..][0..w];
        const y_row0 = y_plane[y * bpl ..][0..w];
        const y_row1 = y_plane[(y + 1) * bpl ..][0..w];
        const u_row = u_plane[(y >> 1) * uv_stride ..][0 .. w / 2];
        const v_row = v_plane[(y >> 1) * uv_stride ..][0 .. w / 2];

        var x: usize = 0;
        while (x + 1 < w) : (x += 2) {
            const p00 = src_row0[x];
            const p01 = src_row0[x + 1];
            const p10 = src_row1[x];
            const p11 = src_row1[x + 1];

            const r00: i32 = @intCast((p00 >> 16) & 0xff);
            const g00: i32 = @intCast((p00 >> 8) & 0xff);
            const b00: i32 = @intCast(p00 & 0xff);

            const r01: i32 = @intCast((p01 >> 16) & 0xff);
            const g01: i32 = @intCast((p01 >> 8) & 0xff);
            const b01: i32 = @intCast(p01 & 0xff);

            const r10: i32 = @intCast((p10 >> 16) & 0xff);
            const g10: i32 = @intCast((p10 >> 8) & 0xff);
            const b10: i32 = @intCast(p10 & 0xff);

            const r11: i32 = @intCast((p11 >> 16) & 0xff);
            const g11: i32 = @intCast((p11 >> 8) & 0xff);
            const b11: i32 = @intCast(p11 & 0xff);

            y_row0[x] = @intCast(std.math.clamp(((66 * r00 + 129 * g00 + 25 * b00 + 128) >> 8) + 16, 16, 235));
            y_row0[x + 1] = @intCast(std.math.clamp(((66 * r01 + 129 * g01 + 25 * b01 + 128) >> 8) + 16, 16, 235));
            y_row1[x] = @intCast(std.math.clamp(((66 * r10 + 129 * g10 + 25 * b10 + 128) >> 8) + 16, 16, 235));
            y_row1[x + 1] = @intCast(std.math.clamp(((66 * r11 + 129 * g11 + 25 * b11 + 128) >> 8) + 16, 16, 235));

            const r_avg = (r00 + r01 + r10 + r11 + 2) >> 2;
            const g_avg = (g00 + g01 + g10 + g11 + 2) >> 2;
            const b_avg = (b00 + b01 + b10 + b11 + 2) >> 2;

            u_row[x >> 1] = @intCast(std.math.clamp(((-38 * r_avg - 74 * g_avg + 112 * b_avg + 128) >> 8) + 128, 16, 240));
            v_row[x >> 1] = @intCast(std.math.clamp(((112 * r_avg - 94 * g_avg - 18 * b_avg + 128) >> 8) + 128, 16, 240));
        }
    }
    return total_len;
}

// --- V4L2 M2M hardware H.264 video encoder & MP4 recorder --------------------

pub const EncodedPacket = struct {
    index: u32,
    data: []const u8,
    pts_us: u64,
    keyframe: bool,
    last: bool,
};

pub const Encoder = struct {
    fd: linux.fd_t,
    out_bufs: [max_buffers]MappedBuf = @splat(.{}),
    out_count: u32 = 0,
    cap_bufs: [max_buffers]MappedBuf = @splat(.{}),
    cap_count: u32 = 0,
    out_streaming: bool = false,
    cap_streaming: bool = false,
    width: u32,
    height: u32,
    stride: u32 = 0,
    slice_height: u32 = 0,
    eos: bool = false,

    pub const Options = struct {
        fps: u32 = 30,
        bitrate: i32 = 2_500_000,
        gop_size: i32 = 30,
    };

    pub fn open(width: u32, height: u32, opts: Options) !Encoder {
        const w = std.mem.alignBackward(u32, width, 16);
        const h = std.mem.alignBackward(u32, height, 16);
        if (w == 0 or h == 0) return error.InvalidDimensions;

        const fd = try openEncoderDevice(Codec.h264.fourcc());
        errdefer sys.close(fd);

        var sub: v4l2.EventSubscription = .{ .type = v4l2.event_eos };
        _ = linux.ioctl(fd, v4l2.subscribe_event, @intFromPtr(&sub));

        setControl(fd, v4l2.cid.mpeg_video_bitrate, opts.bitrate);
        setControl(fd, v4l2.cid.mpeg_video_gop_size, opts.gop_size);
        setControl(fd, v4l2.cid.mpeg_video_h264_i_period, opts.gop_size);
        setControl(fd, v4l2.cid.mpeg_video_repeat_seq_header, 1);

        var parm: v4l2.StreamParm = .{
            .type = v4l2.buf_type_video_output_mplane,
            .parm = .{ .output = .{
                .timeperframe = .{ .numerator = 1, .denominator = @max(opts.fps, 1) },
            } },
        };
        _ = linux.ioctl(fd, v4l2.s_parm, @intFromPtr(&parm));

        // bcm2835-codec-encode aligns YUV420 output stride to 64 bytes.
        const wanted_stride = std.mem.alignForward(u32, w, 64);
        var out_fmt: v4l2.Format = .{
            .type = v4l2.buf_type_video_output_mplane,
            .fmt = .{ .pix_mp = .{
                .width = w,
                .height = h,
                .pixelformat = v4l2.pix_fmt_yuv420,
                .num_planes = 1,
                .plane_fmt = blk: {
                    var p: [8]v4l2.PlanePixFormat = @splat(.{});
                    p[0] = .{
                        .bytesperline = wanted_stride,
                        .sizeimage = wanted_stride * h * 3 / 2,
                    };
                    break :blk p;
                },
            } },
        };
        try ioctl(fd, v4l2.s_fmt, &out_fmt);

        var cap_fmt: v4l2.Format = .{
            .type = v4l2.buf_type_video_capture_mplane,
            .fmt = .{ .pix_mp = .{
                .width = w,
                .height = h,
                .pixelformat = Codec.h264.fourcc(),
                .num_planes = 1,
                .plane_fmt = blk: {
                    var p: [8]v4l2.PlanePixFormat = @splat(.{});
                    p[0] = .{ .sizeimage = 512 * 1024 };
                    break :blk p;
                },
            } },
        };
        try ioctl(fd, v4l2.s_fmt, &cap_fmt);

        var e: Encoder = .{
            .fd = fd,
            .width = w,
            .height = h,
            .stride = @max(out_fmt.fmt.pix_mp.plane_fmt[0].bytesperline, w),
            .slice_height = @max(out_fmt.fmt.pix_mp.height, h),
        };
        errdefer e.deinit();

        try allocMmapBuffers(fd, v4l2.buf_type_video_output_mplane, 4, &e.out_bufs, &e.out_count);
        try allocMmapBuffers(fd, v4l2.buf_type_video_capture_mplane, 4, &e.cap_bufs, &e.cap_count);
        for (0..e.cap_count) |i| try e.queueCapture(@intCast(i));

        var out_type: c_int = v4l2.buf_type_video_output_mplane;
        try ioctl(fd, v4l2.streamon, &out_type);
        e.out_streaming = true;

        var cap_type: c_int = v4l2.buf_type_video_capture_mplane;
        try ioctl(fd, v4l2.streamon, &cap_type);
        e.cap_streaming = true;

        return e;
    }

    pub fn deinit(e: *Encoder) void {
        if (e.out_streaming) {
            var out_type: c_int = v4l2.buf_type_video_output_mplane;
            _ = linux.ioctl(e.fd, v4l2.streamoff, @intFromPtr(&out_type));
            e.out_streaming = false;
        }
        if (e.cap_streaming) {
            var cap_type: c_int = v4l2.buf_type_video_capture_mplane;
            _ = linux.ioctl(e.fd, v4l2.streamoff, @intFromPtr(&cap_type));
            e.cap_streaming = false;
        }
        Decoder.freeBuffers(e.fd, v4l2.buf_type_video_output_mplane, &e.out_bufs, &e.out_count);
        Decoder.freeBuffers(e.fd, v4l2.buf_type_video_capture_mplane, &e.cap_bufs, &e.cap_count);
        sys.close(e.fd);
    }

    pub fn queueCapture(e: *Encoder, index: u32) !void {
        var plane: v4l2.Plane = .{ .length = @intCast(e.cap_bufs[index].data.len) };
        var b: v4l2.Buffer = .{
            .index = index,
            .type = v4l2.buf_type_video_capture_mplane,
            .memory = v4l2.memory_mmap,
            .m = .{ .planes = @ptrCast(&plane) },
            .length = 1,
        };
        try ioctl(e.fd, v4l2.qbuf, &b);
        e.cap_bufs[index].queued = true;
    }

    /// Reclaims finished output buffers and returns the index of a free
    /// output buffer, if one is available.
    pub fn acquireOutput(e: *Encoder) ?u32 {
        while (true) {
            var plane: v4l2.Plane = .{};
            var b: v4l2.Buffer = .{
                .type = v4l2.buf_type_video_output_mplane,
                .memory = v4l2.memory_mmap,
                .m = .{ .planes = @ptrCast(&plane) },
                .length = 1,
            };
            if (linux.errno(linux.ioctl(e.fd, v4l2.dqbuf, @intFromPtr(&b))) != .SUCCESS) break;
            if (b.index < e.out_count) e.out_bufs[b.index].queued = false;
        }
        for (0..e.out_count) |i| {
            if (!e.out_bufs[i].queued) return @intCast(i);
        }
        return null;
    }

    pub fn outputBuffer(e: *Encoder, index: u32) []u8 {
        return e.out_bufs[index].data;
    }

    pub fn submitOutput(e: *Encoder, index: u32, used: usize, pts_us: u64, force_keyframe: bool) !void {
        if (force_keyframe) setControl(e.fd, v4l2.cid.mpeg_video_force_key_frame, 1);
        var plane: v4l2.Plane = .{
            .bytesused = @intCast(used),
            .length = @intCast(e.out_bufs[index].data.len),
        };
        var b: v4l2.Buffer = .{
            .index = index,
            .type = v4l2.buf_type_video_output_mplane,
            .field = v4l2.field_none,
            .timestamp = .{
                .sec = @intCast(pts_us / 1_000_000),
                .usec = @intCast(pts_us % 1_000_000),
            },
            .memory = v4l2.memory_mmap,
            .m = .{ .planes = @ptrCast(&plane) },
            .length = 1,
        };
        try ioctl(e.fd, v4l2.qbuf, &b);
        e.out_bufs[index].queued = true;
    }

    pub fn sendEos(e: *Encoder) void {
        var cmd: v4l2.EncoderCmd = .{ .cmd = v4l2.enc_cmd_stop };
        _ = linux.ioctl(e.fd, v4l2.encoder_cmd, @intFromPtr(&cmd));
    }

    /// Dequeues the next encoded H.264 packet, if one is ready.
    pub fn nextPacket(e: *Encoder) !?EncodedPacket {
        while (true) {
            var ev: v4l2.Event = .{};
            if (linux.errno(linux.ioctl(e.fd, v4l2.dqevent, @intFromPtr(&ev))) != .SUCCESS) break;
            if (ev.type == v4l2.event_eos) e.eos = true;
        }
        if (!e.cap_streaming) return null;

        var plane: v4l2.Plane = .{};
        var b: v4l2.Buffer = .{
            .type = v4l2.buf_type_video_capture_mplane,
            .memory = v4l2.memory_mmap,
            .m = .{ .planes = @ptrCast(&plane) },
            .length = 1,
        };
        switch (linux.errno(linux.ioctl(e.fd, v4l2.dqbuf, @intFromPtr(&b)))) {
            .SUCCESS => {},
            .AGAIN, .PIPE => return null,
            else => return error.EncodeFailed,
        }
        if (b.index >= e.cap_count) return null;
        e.cap_bufs[b.index].queued = false;
        const last = (b.flags & v4l2.buf_flag_last) != 0;
        if (last) e.eos = true;
        if (plane.bytesused == 0 or (b.flags & v4l2.buf_flag_error) != 0) {
            if (!last) e.queueCapture(b.index) catch {};
            return null;
        }
        const pts_us: u64 = @as(u64, @intCast(@max(b.timestamp.sec, 0))) * 1_000_000 +
            @as(u64, @intCast(@max(b.timestamp.usec, 0)));
        return .{
            .index = b.index,
            .data = e.cap_bufs[b.index].data[0..@min(plane.bytesused, e.cap_bufs[b.index].data.len)],
            .pts_us = pts_us,
            .keyframe = (b.flags & v4l2.buf_flag_keyframe) != 0,
            .last = last,
        };
    }
};

fn allocMmapBuffers(fd: linux.fd_t, buf_type: u32, wanted: u32, bufs: *[max_buffers]MappedBuf, count_out: *u32) !void {
    var req: v4l2.RequestBuffers = .{ .count = wanted, .type = buf_type, .memory = v4l2.memory_mmap };
    try ioctl(fd, v4l2.reqbufs, &req);
    if (req.count == 0) return error.NoBuffers;
    const count = @min(req.count, max_buffers);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var plane: v4l2.Plane = .{};
        var b: v4l2.Buffer = .{
            .index = i,
            .type = buf_type,
            .memory = v4l2.memory_mmap,
            .m = .{ .planes = @ptrCast(&plane) },
            .length = 1,
        };
        try ioctl(fd, v4l2.querybuf, &b);
        if (plane.length == 0) return error.NoBuffers;
        const addr = try sys.check(linux.mmap(null, plane.length, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, plane.m.mem_offset));
        bufs[i] = .{ .data = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..plane.length], .queued = false };
        count_out.* = i + 1;
    }
}

fn setControl(fd: linux.fd_t, id: u32, value: i32) void {
    var ctrl: v4l2.Control = .{ .id = id, .value = value };
    _ = linux.ioctl(fd, v4l2.s_ctrl, @intFromPtr(&ctrl));
}

fn openEncoderDevice(wanted_fourcc: u32) !linux.fd_t {
    // Check /dev/video11 (bcm2835-codec-encode's default number) first.
    if (tryEncoderDevice(11, wanted_fourcc)) |fd| return fd;
    for (0..32) |n| {
        if (n == 11) continue;
        if (tryEncoderDevice(n, wanted_fourcc)) |fd| return fd;
    }
    return error.NoHardwareEncoder;
}

fn tryEncoderDevice(n: usize, wanted_fourcc: u32) ?linux.fd_t {
    var path_buf: [32]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/dev/video{d}", .{n}, 0) catch return null;
    const fd = sys.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }) catch return null;
    var cap: v4l2.Capability = undefined;
    if (linux.errno(linux.ioctl(fd, v4l2.querycap, @intFromPtr(&cap))) != .SUCCESS) {
        sys.close(fd);
        return null;
    }
    const caps = if (cap.device_caps != 0) cap.device_caps else cap.capabilities;
    if (caps & v4l2.cap_video_m2m_mplane == 0 or caps & v4l2.cap_streaming == 0) {
        sys.close(fd);
        return null;
    }
    var has_yuv_out = false;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var desc: v4l2.FmtDesc = .{ .index = i, .type = v4l2.buf_type_video_output_mplane };
        if (linux.errno(linux.ioctl(fd, v4l2.enum_fmt, @intFromPtr(&desc))) != .SUCCESS) break;
        if (desc.pixelformat == v4l2.pix_fmt_yuv420) {
            has_yuv_out = true;
            break;
        }
    }
    if (has_yuv_out) {
        i = 0;
        while (i < 64) : (i += 1) {
            var desc: v4l2.FmtDesc = .{ .index = i, .type = v4l2.buf_type_video_capture_mplane };
            if (linux.errno(linux.ioctl(fd, v4l2.enum_fmt, @intFromPtr(&desc))) != .SUCCESS) break;
            if (desc.pixelformat == wanted_fourcc) return fd;
        }
    }
    sys.close(fd);
    return null;
}

/// Streams encoded Annex-B H.264 packets into an ISO Base Media File Format
/// (`.mp4`) file on disk without buffering frame payloads in memory.
pub const Mp4Muxer = struct {
    gpa: std.mem.Allocator,
    fd: linux.fd_t,
    width: u32,
    height: u32,
    fps: u32,
    mdat_offset: u64 = 20,
    write_offset: u64 = 28,
    sps: [256]u8 = undefined,
    sps_len: usize = 0,
    pps: [256]u8 = undefined,
    pps_len: usize = 0,
    samples: std.ArrayList(MuxSample) = .empty,

    const MuxSample = struct {
        size: u32,
        pts_us: u64,
        keyframe: bool,
    };

    pub fn init(gpa: std.mem.Allocator, fd: linux.fd_t, width: u32, height: u32, fps: u32) !Mp4Muxer {
        // 20-byte `ftyp` box followed by an 8-byte `mdat` box header whose
        // 32-bit size is patched in `finish`.
        const header = "\x00\x00\x00\x14ftypisom\x00\x00\x02\x00isom\x00\x00\x00\x00mdat";
        try pwriteAll(fd, header, 0);
        return .{
            .gpa = gpa,
            .fd = fd,
            .width = width,
            .height = height,
            .fps = @max(fps, 1),
        };
    }

    pub fn deinit(m: *Mp4Muxer) void {
        m.samples.deinit(m.gpa);
    }

    /// Parses an Annex-B H.264 buffer from the encoder, captures SPS/PPS
    /// NALs for the `avcC` box, and writes 4-byte length-prefixed slice
    /// NALs to `mdat`.
    pub fn writePacket(m: *Mp4Muxer, annexb: []const u8, pts_us: u64, keyframe_hint: bool) !void {
        var sample_bytes: u32 = 0;
        var is_keyframe = keyframe_hint;

        var sc_opt = nextStartCode(annexb, 0);
        if (sc_opt == null and annexb.len > 0) {
            try m.writeNal(annexb, &sample_bytes, &is_keyframe);
        } else {
            while (sc_opt) |sc| {
                const next_sc = nextStartCode(annexb, sc.end);
                const nal_end = if (next_sc) |n| n.pos else annexb.len;
                if (sc.end < nal_end) {
                    try m.writeNal(annexb[sc.end..nal_end], &sample_bytes, &is_keyframe);
                }
                sc_opt = next_sc;
            }
        }

        if (sample_bytes > 0 and m.samples.items.len < max_samples) {
            try m.samples.append(m.gpa, .{
                .size = sample_bytes,
                .pts_us = pts_us,
                .keyframe = is_keyframe or m.samples.items.len == 0,
            });
        }
    }

    fn writeNal(m: *Mp4Muxer, nal: []const u8, sample_bytes: *u32, is_keyframe: *bool) !void {
        if (nal.len == 0) return;
        const nal_type = nal[0] & 0x1f;
        if (nal_type == 7) {
            if (m.sps_len == 0 and nal.len <= m.sps.len) {
                @memcpy(m.sps[0..nal.len], nal);
                m.sps_len = nal.len;
            }
            return;
        }
        if (nal_type == 8) {
            if (m.pps_len == 0 and nal.len <= m.pps.len) {
                @memcpy(m.pps[0..nal.len], nal);
                m.pps_len = nal.len;
            }
            return;
        }
        if (nal_type == 9) return;
        if (nal_type == 5) is_keyframe.* = true;

        var len_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_be, @intCast(nal.len), .big);
        try pwriteAll(m.fd, &len_be, m.write_offset);
        m.write_offset += 4;
        try pwriteAll(m.fd, nal, m.write_offset);
        m.write_offset += nal.len;
        sample_bytes.* += @intCast(4 + nal.len);
    }

    /// Patches the `mdat` box size and writes the trailing `moov` box.
    pub fn finish(m: *Mp4Muxer) !void {
        if (m.samples.items.len == 0 or m.sps_len < 4 or m.pps_len == 0) return error.EmptyRecording;

        const mdat_size: u32 = @intCast(m.write_offset - m.mdat_offset);
        var mdat_sz_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &mdat_sz_be, mdat_size, .big);
        try pwriteAll(m.fd, &mdat_sz_be, m.mdat_offset);

        const sps = m.sps[0..m.sps_len];
        const pps = m.pps[0..m.pps_len];
        const timescale: u32 = 1000; // 1 tick = 1 ms
        const default_delta_ms: u32 = @max(1000 / m.fps, 1);

        const W = struct {
            fn u32be(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, v, .big);
                try list.appendSlice(a, &b);
            }
            fn u16be(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
                var b: [2]u8 = undefined;
                std.mem.writeInt(u16, &b, v, .big);
                try list.appendSlice(a, &b);
            }
        };

        // avcC
        var avcc: std.ArrayList(u8) = .empty;
        defer avcc.deinit(m.gpa);
        try W.u32be(&avcc, m.gpa, @intCast(8 + 6 + 2 + sps.len + 1 + 2 + pps.len));
        try avcc.appendSlice(m.gpa, "avcC");
        try avcc.appendSlice(m.gpa, &.{ 1, sps[1], sps[2], sps[3], 0xff, 0xe1 });
        try W.u16be(&avcc, m.gpa, @intCast(sps.len));
        try avcc.appendSlice(m.gpa, sps);
        try avcc.append(m.gpa, 1);
        try W.u16be(&avcc, m.gpa, @intCast(pps.len));
        try avcc.appendSlice(m.gpa, pps);

        // avc1 (8 + 78 + avcc)
        var avc1: std.ArrayList(u8) = .empty;
        defer avc1.deinit(m.gpa);
        try W.u32be(&avc1, m.gpa, @intCast(8 + 78 + avcc.items.len));
        try avc1.appendSlice(m.gpa, "avc1");
        try avc1.appendNTimes(m.gpa, 0, 6);
        try W.u16be(&avc1, m.gpa, 1); // data_reference_index
        try avc1.appendNTimes(m.gpa, 0, 16);
        try W.u16be(&avc1, m.gpa, @intCast(m.width));
        try W.u16be(&avc1, m.gpa, @intCast(m.height));
        try W.u32be(&avc1, m.gpa, 0x00480000); // horizresolution 72 dpi
        try W.u32be(&avc1, m.gpa, 0x00480000); // vertresolution 72 dpi
        try W.u32be(&avc1, m.gpa, 0);
        try W.u16be(&avc1, m.gpa, 1); // frame_count
        try avc1.appendNTimes(m.gpa, 0, 32); // compressorname
        try W.u16be(&avc1, m.gpa, 0x0018); // depth = 24
        try W.u16be(&avc1, m.gpa, 0xffff); // pre_defined = -1
        try avc1.appendSlice(m.gpa, avcc.items);

        // stsd
        var stsd: std.ArrayList(u8) = .empty;
        defer stsd.deinit(m.gpa);
        try W.u32be(&stsd, m.gpa, @intCast(16 + avc1.items.len));
        try stsd.appendSlice(m.gpa, "stsd\x00\x00\x00\x00\x00\x00\x00\x01");
        try stsd.appendSlice(m.gpa, avc1.items);

        // stts (per-sample duration in milliseconds)
        var stts: std.ArrayList(u8) = .empty;
        defer stts.deinit(m.gpa);
        const n_samples = m.samples.items.len;
        try W.u32be(&stts, m.gpa, @intCast(16 + n_samples * 8));
        try stts.appendSlice(m.gpa, "stts\x00\x00\x00\x00");
        try W.u32be(&stts, m.gpa, @intCast(n_samples));
        var total_ticks: u32 = 0;
        for (m.samples.items, 0..) |sp, i| {
            const delta_ms: u32 = if (i + 1 < n_samples) blk: {
                const next_pts = m.samples.items[i + 1].pts_us;
                break :blk @intCast(@max((next_pts -| sp.pts_us + 500) / 1000, 1));
            } else default_delta_ms;
            try W.u32be(&stts, m.gpa, 1);
            try W.u32be(&stts, m.gpa, delta_ms);
            total_ticks +|= delta_ms;
        }

        // stsc (1 chunk containing all samples)
        var stsc: std.ArrayList(u8) = .empty;
        defer stsc.deinit(m.gpa);
        try W.u32be(&stsc, m.gpa, 28);
        try stsc.appendSlice(m.gpa, "stsc\x00\x00\x00\x00\x00\x00\x00\x01");
        try W.u32be(&stsc, m.gpa, 1);
        try W.u32be(&stsc, m.gpa, @intCast(n_samples));
        try W.u32be(&stsc, m.gpa, 1);

        // stsz
        var stsz: std.ArrayList(u8) = .empty;
        defer stsz.deinit(m.gpa);
        try W.u32be(&stsz, m.gpa, @intCast(20 + n_samples * 4));
        try stsz.appendSlice(m.gpa, "stsz\x00\x00\x00\x00\x00\x00\x00\x00");
        try W.u32be(&stsz, m.gpa, @intCast(n_samples));
        for (m.samples.items) |sp| try W.u32be(&stsz, m.gpa, sp.size);

        // stco (single chunk starting right after the 8-byte mdat header)
        var stco: std.ArrayList(u8) = .empty;
        defer stco.deinit(m.gpa);
        try W.u32be(&stco, m.gpa, 20);
        try stco.appendSlice(m.gpa, "stco\x00\x00\x00\x00\x00\x00\x00\x01");
        try W.u32be(&stco, m.gpa, @intCast(m.mdat_offset + 8));

        // stss (1-based sync sample indices)
        var sync_count: u32 = 0;
        for (m.samples.items) |sp| if (sp.keyframe) {
            sync_count += 1;
        };
        var stss: std.ArrayList(u8) = .empty;
        defer stss.deinit(m.gpa);
        try W.u32be(&stss, m.gpa, 16 + sync_count * 4);
        try stss.appendSlice(m.gpa, "stss\x00\x00\x00\x00");
        try W.u32be(&stss, m.gpa, sync_count);
        for (m.samples.items, 0..) |sp, i| if (sp.keyframe) {
            try W.u32be(&stss, m.gpa, @intCast(i + 1));
        };

        // stbl
        var stbl: std.ArrayList(u8) = .empty;
        defer stbl.deinit(m.gpa);
        const stbl_len = 8 + stsd.items.len + stts.items.len + stsc.items.len + stsz.items.len + stco.items.len + stss.items.len;
        try W.u32be(&stbl, m.gpa, @intCast(stbl_len));
        try stbl.appendSlice(m.gpa, "stbl");
        try stbl.appendSlice(m.gpa, stsd.items);
        try stbl.appendSlice(m.gpa, stts.items);
        try stbl.appendSlice(m.gpa, stsc.items);
        try stbl.appendSlice(m.gpa, stsz.items);
        try stbl.appendSlice(m.gpa, stco.items);
        try stbl.appendSlice(m.gpa, stss.items);

        // vmhd + dinf + stbl -> minf
        const vmhd = "\x00\x00\x00\x14vmhd\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00";
        const dinf = "\x00\x00\x00\x24dinf\x00\x00\x00\x1cdref\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0curl \x00\x00\x00\x01";
        var minf: std.ArrayList(u8) = .empty;
        defer minf.deinit(m.gpa);
        try W.u32be(&minf, m.gpa, @intCast(8 + vmhd.len + dinf.len + stbl.items.len));
        try minf.appendSlice(m.gpa, "minf");
        try minf.appendSlice(m.gpa, vmhd);
        try minf.appendSlice(m.gpa, dinf);
        try minf.appendSlice(m.gpa, stbl.items);

        // mdhd (version 0: 32 bytes)
        var mdhd: std.ArrayList(u8) = .empty;
        defer mdhd.deinit(m.gpa);
        try W.u32be(&mdhd, m.gpa, 32);
        try mdhd.appendSlice(m.gpa, "mdhd");
        try mdhd.appendNTimes(m.gpa, 0, 12);
        try W.u32be(&mdhd, m.gpa, timescale);
        try W.u32be(&mdhd, m.gpa, total_ticks);
        try W.u32be(&mdhd, m.gpa, 0x55c40000); // language = und

        // hdlr (vide: 33 bytes)
        const hdlr = "\x00\x00\x00\x21hdlr\x00\x00\x00\x00\x00\x00\x00\x00vide\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

        // mdia
        var mdia: std.ArrayList(u8) = .empty;
        defer mdia.deinit(m.gpa);
        try W.u32be(&mdia, m.gpa, @intCast(8 + mdhd.items.len + hdlr.len + minf.items.len));
        try mdia.appendSlice(m.gpa, "mdia");
        try mdia.appendSlice(m.gpa, mdhd.items);
        try mdia.appendSlice(m.gpa, hdlr);
        try mdia.appendSlice(m.gpa, minf.items);

        // tkhd (version 0: 92 bytes)
        var tkhd: std.ArrayList(u8) = .empty;
        defer tkhd.deinit(m.gpa);
        try W.u32be(&tkhd, m.gpa, 92);
        try tkhd.appendSlice(m.gpa, "tkhd\x00\x00\x00\x03"); // flags: enabled | in_movie
        try tkhd.appendNTimes(m.gpa, 0, 8);
        try W.u32be(&tkhd, m.gpa, 1); // track_ID = 1
        try W.u32be(&tkhd, m.gpa, 0);
        try W.u32be(&tkhd, m.gpa, total_ticks);
        try tkhd.appendNTimes(m.gpa, 0, 16);
        try W.u32be(&tkhd, m.gpa, 0x00010000); // identity matrix
        try tkhd.appendNTimes(m.gpa, 0, 12);
        try W.u32be(&tkhd, m.gpa, 0x00010000);
        try tkhd.appendNTimes(m.gpa, 0, 12);
        try W.u32be(&tkhd, m.gpa, 0x40000000);
        try W.u32be(&tkhd, m.gpa, m.width << 16);
        try W.u32be(&tkhd, m.gpa, m.height << 16);

        // trak
        var trak: std.ArrayList(u8) = .empty;
        defer trak.deinit(m.gpa);
        try W.u32be(&trak, m.gpa, @intCast(8 + tkhd.items.len + mdia.items.len));
        try trak.appendSlice(m.gpa, "trak");
        try trak.appendSlice(m.gpa, tkhd.items);
        try trak.appendSlice(m.gpa, mdia.items);

        // mvhd (version 0: 108 bytes)
        var mvhd: std.ArrayList(u8) = .empty;
        defer mvhd.deinit(m.gpa);
        try W.u32be(&mvhd, m.gpa, 108);
        try mvhd.appendSlice(m.gpa, "mvhd\x00\x00\x00\x00");
        try mvhd.appendNTimes(m.gpa, 0, 8);
        try W.u32be(&mvhd, m.gpa, timescale);
        try W.u32be(&mvhd, m.gpa, total_ticks);
        try W.u32be(&mvhd, m.gpa, 0x00010000); // rate = 1.0
        try W.u16be(&mvhd, m.gpa, 0x0100); // volume = 1.0
        try mvhd.appendNTimes(m.gpa, 0, 10);
        try W.u32be(&mvhd, m.gpa, 0x00010000); // identity matrix
        try mvhd.appendNTimes(m.gpa, 0, 12);
        try W.u32be(&mvhd, m.gpa, 0x00010000);
        try mvhd.appendNTimes(m.gpa, 0, 12);
        try W.u32be(&mvhd, m.gpa, 0x40000000);
        try mvhd.appendNTimes(m.gpa, 0, 24);
        try W.u32be(&mvhd, m.gpa, 2); // next_track_ID

        // moov
        var moov: std.ArrayList(u8) = .empty;
        defer moov.deinit(m.gpa);
        try W.u32be(&moov, m.gpa, @intCast(8 + mvhd.items.len + trak.items.len));
        try moov.appendSlice(m.gpa, "moov");
        try moov.appendSlice(m.gpa, mvhd.items);
        try moov.appendSlice(m.gpa, trak.items);

        try pwriteAll(m.fd, moov.items, m.write_offset);
        m.write_offset += moov.items.len;
    }
};

fn pwriteAll(fd: linux.fd_t, data: []const u8, offset: u64) !void {
    var done: usize = 0;
    while (done < data.len) {
        const rc = linux.pwrite(fd, data[done..].ptr, data.len - done, @bitCast(offset + done));
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .INTR => continue,
            else => return error.WriteError,
        }
    }
}

/// Records `0xffRRGGBB` frames into an `.mp4` file using the hardware
/// H.264 encoder.
pub const Recorder = struct {
    encoder: Encoder,
    muxer: Mp4Muxer,
    fd: linux.fd_t,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    start_ns: ?u64 = null,
    frames_submitted: u32 = 0,

    pub fn start(gpa: std.mem.Allocator, path: [:0]const u8, width: u32, height: u32, opts: Encoder.Options) !Recorder {
        if (path.len >= 512) return error.NameTooLong;
        var enc = try Encoder.open(width, height, opts);
        errdefer enc.deinit();

        const fd: linux.fd_t = @intCast(try sys.check(linux.open(
            path,
            .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            0o644,
        )));
        errdefer {
            sys.close(fd);
            _ = linux.unlink(path);
        }

        var mux = try Mp4Muxer.init(gpa, fd, enc.width, enc.height, opts.fps);
        errdefer mux.deinit();

        var r: Recorder = .{
            .encoder = enc,
            .muxer = mux,
            .fd = fd,
            .path_len = path.len,
        };
        @memcpy(r.path_buf[0..path.len], path);
        r.path_buf[path.len] = 0;
        return r;
    }

    pub fn name(r: *const Recorder) []const u8 {
        return std.fs.path.basename(r.path_buf[0..r.path_len]);
    }

    pub fn pathZ(r: *const Recorder) [:0]const u8 {
        return r.path_buf[0..r.path_len :0];
    }

    pub fn elapsedUs(r: *const Recorder, now_ns: u64) u64 {
        const s = r.start_ns orelse return 0;
        return (now_ns -| s) / std.time.ns_per_us;
    }

    /// Drains ready encoded packets to disk and submits a `width × height`
    /// `0xffRRGGBB` frame to the hardware encoder if an input buffer is free.
    pub fn addFrame(r: *Recorder, argb: []const u32, now_ns: u64) !void {
        try r.drainPackets();
        if (r.encoder.acquireOutput()) |buf_idx| {
            if (r.start_ns == null) r.start_ns = now_ns;
            const pts_us = (now_ns -| r.start_ns.?) / std.time.ns_per_us;
            const out = r.encoder.outputBuffer(buf_idx);
            const used = argbToYuv420(argb, r.encoder.width, r.encoder.height, out, r.encoder.stride, r.encoder.slice_height);
            if (used > 0) {
                try r.encoder.submitOutput(buf_idx, used, pts_us, r.frames_submitted == 0);
                r.frames_submitted += 1;
            }
        }
        try r.drainPackets();
    }

    fn drainPackets(r: *Recorder) !void {
        while (try r.encoder.nextPacket()) |pkt| {
            const is_last = pkt.last;
            const idx = pkt.index;
            defer if (!is_last) r.encoder.queueCapture(idx) catch {};
            try r.muxer.writePacket(pkt.data, pkt.pts_us, pkt.keyframe);
            if (is_last) break;
        }
    }

    /// Flushes the hardware encoder, writes the MP4 `moov` index and closes
    /// the file. If no frames were recorded, removes the empty file and
    /// returns `error.EmptyRecording`.
    pub fn stop(r: *Recorder) !void {
        defer {
            r.muxer.deinit();
            r.encoder.deinit();
            sys.close(r.fd);
        }
        errdefer _ = linux.unlink(r.pathZ());

        if (r.frames_submitted > 0) {
            r.encoder.sendEos();
            var tries: u32 = 0;
            while (tries < 60 and !r.encoder.eos) : (tries += 1) {
                try r.drainPackets();
                if (r.encoder.eos) break;
                var fds = [1]linux.pollfd{.{
                    .fd = r.encoder.fd,
                    .events = linux.POLL.IN | linux.POLL.PRI,
                    .revents = 0,
                }};
                _ = linux.poll(&fds, 1, 5);
            }
            try r.drainPackets();
        }
        try r.muxer.finish();
    }
};

// --- Video player ------------------------------------------------------------

pub const Player = struct {
    gpa: std.mem.Allocator,
    stream: Stream,
    decoder: ?Decoder = null,
    /// Two pixel buffers so the GPU can draw one while the next is filled.
    pixels: [2][]u32 = .{ &.{}, &.{} },
    shown: u1 = 0,
    image: ?gfx.Image = null,
    playing: bool = false,
    finished: bool = false,
    /// Current playback time in microseconds.
    position_us: u64 = 0,
    /// Playback clock anchor: at monotonic time `start_ns`, the video was
    /// at `base_us`.
    start_ns: u64 = 0,
    base_us: u64 = 0,
    /// Next sample index in `stream.samples` to feed to the decoder.
    next_sample: usize = 0,
    need_header: bool = true,
    eos_sent: bool = false,
    /// A decoded capture frame waiting for its presentation timestamp.
    pending: ?DecodedFrame = null,
    /// Why hardware decoding could not start, if `decoder == null`.
    hw_unavailable: bool = false,
    /// Audio playback state when `stream.audio_track` is present.
    pcm: ?audio.alsa.PcmOutput = null,
    audio_settings: audio.Settings = .{},
    aac_decoder: ?*audio.aac.Decoder = null,
    audio_pkt_buf: []u8 = &.{},
    audio_frames: [4096][2]i16 = undefined,
    audio_frames_len: usize = 0,
    audio_frames_pos: usize = 0,
    audio_resample_frac: u32 = 0,
    next_audio_pkt: usize = 0,

    pub fn open(gpa: std.mem.Allocator, fd: linux.fd_t, file_size: u64, owns_fd: bool, now_ns: u64) !*Player {
        var stream = try Stream.open(gpa, fd, file_size, owns_fd);
        errdefer stream.deinit();

        const p = try gpa.create(Player);
        errdefer gpa.destroy(p);
        const max_pixels = @as(usize, max_display_width) * max_display_height;
        const buf0 = try gpa.alloc(u32, max_pixels);
        errdefer gpa.free(buf0);
        const buf1 = try gpa.alloc(u32, max_pixels);
        errdefer gpa.free(buf1);

        p.* = .{
            .gpa = gpa,
            .stream = stream,
            .pixels = .{ buf0, buf1 },
        };

        if (Decoder.open(stream.codec, stream.width, stream.height)) |dec| {
            p.decoder = dec;
            p.decodeFirstFrame();
            p.initAudio();
            p.playing = true;
            p.start_ns = now_ns;
            p.base_us = 0;
            p.feedAudio();
        } else |_| {
            p.hw_unavailable = true;
        }
        return p;
    }

    pub fn destroy(p: *Player) void {
        if (p.pcm) |*pcm| pcm.close();
        if (p.aac_decoder) |aac_dec| p.gpa.destroy(aac_dec);
        if (p.audio_pkt_buf.len > 0) p.gpa.free(p.audio_pkt_buf);
        if (p.pending) |f| if (p.decoder) |*d| d.queueCapture(f.index) catch {};
        if (p.decoder) |*d| d.deinit();
        if (p.pixels[0].len > 0) p.gpa.free(p.pixels[0]);
        if (p.pixels[1].len > 0) p.gpa.free(p.pixels[1]);
        p.stream.deinit();
        p.gpa.destroy(p);
    }

    fn initAudio(p: *Player) void {
        const at = &(p.stream.audio_track orelse return);
        if (at.packets.len == 0 or at.max_packet_size == 0) return;
        p.audio_settings = audio.loadSettings();
        p.pcm = audio.openOutput(at.sample_rate, p.audio_settings) orelse return;
        p.audio_pkt_buf = p.gpa.alloc(u8, at.max_packet_size) catch {
            if (p.pcm) |*pcm| pcm.close();
            p.pcm = null;
            return;
        };
        if (at.codec == .aac) {
            const dec = p.gpa.create(audio.aac.Decoder) catch {
                p.gpa.free(p.audio_pkt_buf);
                p.audio_pkt_buf = &.{};
                if (p.pcm) |*pcm| pcm.close();
                p.pcm = null;
                return;
            };
            dec.* = audio.aac.Decoder.init(at.aac_config);
            p.aac_decoder = dec;
        }
    }

    fn resetAudioAt(p: *Player, target_us: u64) void {
        if (p.pcm) |*pcm| pcm.drop();
        p.audio_frames_pos = 0;
        p.audio_frames_len = 0;
        p.audio_resample_frac = 0;
        if (p.aac_decoder) |aac_dec| aac_dec.reset();
        if (p.stream.audio_track) |*at| {
            p.next_audio_pkt = at.packetAtOrAfter(target_us);
        }
    }

    fn feedAudio(p: *Player) void {
        const pcm = &(p.pcm orelse return);
        const at = &(p.stream.audio_track orelse return);

        if (p.audio_frames_pos < p.audio_frames_len) {
            const rem = p.audio_frames[p.audio_frames_pos..p.audio_frames_len];
            const written = pcm.writeStereoFrames(rem, p.audio_settings.volume, p.audio_settings.muted);
            p.audio_frames_pos += written;
            if (p.audio_frames_pos < p.audio_frames_len) return;
        }

        const horizon_us = p.position_us + 150_000;
        var raw_frames: [1024][2]i16 = undefined;
        var rounds: usize = 0;

        while (p.next_audio_pkt < at.packets.len and rounds < 8) : (rounds += 1) {
            const pkt = at.packets[p.next_audio_pkt];
            if (pkt.pts_us > horizon_us) break;
            const pkt_idx = p.next_audio_pkt;
            p.next_audio_pkt += 1;

            // Drop packets that are more than 250 ms behind the current clock.
            if (pkt.pts_us + 250_000 < p.position_us) continue;

            const bytes = at.readPacket(p.stream.fd, pkt_idx, p.audio_pkt_buf) catch continue;
            const decoded: usize = if (at.codec == .aac) blk: {
                const aac_dec = p.aac_decoder orelse break;
                break :blk aac_dec.decodeFrame(bytes, &raw_frames) catch continue;
            } else decodeAudioPcmPacket(at.codec, at.channels, bytes, &raw_frames);

            if (decoded == 0) continue;
            // If this was a pre-roll AAC packet decoded solely to prime the
            // IMDCT overlap window before `position_us`, don't queue its PCM.
            if (at.codec == .aac and pkt.pts_us + 20_000 < p.position_us) continue;

            if (at.sample_rate == pcm.rate) {
                @memcpy(p.audio_frames[0..decoded], raw_frames[0..decoded]);
                p.audio_frames_len = decoded;
            } else {
                const res = audio.alsa.resampleLinear(
                    raw_frames[0..decoded],
                    at.sample_rate,
                    &p.audio_frames,
                    pcm.rate,
                    &p.audio_resample_frac,
                );
                p.audio_frames_len = res.produced;
            }
            p.audio_frames_pos = 0;
            if (p.audio_frames_len == 0) continue;

            const written = pcm.writeStereoFrames(
                p.audio_frames[0..p.audio_frames_len],
                p.audio_settings.volume,
                p.audio_settings.muted,
            );
            p.audio_frames_pos = written;
            if (p.audio_frames_pos < p.audio_frames_len) break;
        }
    }

    /// Feeds the initial frames and waits briefly for the hardware decoder
    /// to produce the first picture, so opening a video shows it right away.
    fn decodeFirstFrame(p: *Player) void {
        var tries: u32 = 0;
        while (tries < 50 and p.image == null) : (tries += 1) {
            p.feedDecoder();
            const d = &(p.decoder orelse return);
            if (d.nextFrame() catch null) |f| {
                p.presentFrame(f);
                d.queueCapture(f.index) catch {};
                return;
            }
            var fds = [1]linux.pollfd{.{
                .fd = d.fd,
                .events = linux.POLL.IN | linux.POLL.PRI | linux.POLL.OUT,
                .revents = 0,
            }};
            _ = linux.poll(&fds, 1, 5);
        }
    }

    fn feedDecoder(p: *Player) void {
        const d = &(p.decoder orelse return);
        while (p.next_sample < p.stream.samples.len) {
            const buf_idx = d.acquireOutput() orelse break;
            const out = d.outputBuffer(buf_idx);
            const sp = p.stream.samples[p.next_sample];
            const used = p.stream.readSample(p.next_sample, p.need_header, out) catch {
                p.next_sample += 1;
                continue;
            };
            d.submitOutput(buf_idx, used, sp.pts_us, sp.keyframe or p.need_header) catch break;
            p.need_header = false;
            p.next_sample += 1;
        }
        if (p.next_sample >= p.stream.samples.len and !p.eos_sent) {
            d.sendEos();
            p.eos_sent = true;
        }
    }

    fn presentFrame(p: *Player, f: DecodedFrame) void {
        const sz = displaySize(f.width, f.height);
        const next = p.shown +% 1;
        const out = p.pixels[next][0 .. @as(usize, sz.width) * sz.height];
        yuvToArgb(f.data, f.width, f.height, f.stride, f.slice_height, f.pixfmt, out, sz.width, sz.height);
        p.image = .init(out, sz.width, sz.height);
        p.shown = next;
    }

    /// Advances playback to monotonic time `now_ns`. Returns whether the
    /// displayed frame or playback state changed.
    pub fn step(p: *Player, now_ns: u64) bool {
        if (!p.playing) return false;
        const d = &(p.decoder orelse {
            p.playing = false;
            return true;
        });

        const elapsed_us = (now_ns -| p.start_ns) / std.time.ns_per_us;
        p.position_us = @min(p.base_us + elapsed_us, p.stream.duration_us);
        var changed = false;

        p.feedDecoder();
        p.feedAudio();

        while (true) {
            if (p.pending == null) {
                p.pending = d.nextFrame() catch null;
            }
            const f = p.pending orelse break;
            if (f.pts_us > p.position_us + 2_000) break;
            p.presentFrame(f);
            const is_last = f.last;
            d.queueCapture(f.index) catch {};
            p.pending = null;
            changed = true;
            p.feedDecoder();
            if (is_last) break;
        }

        if (p.pending == null and p.next_sample >= p.stream.samples.len and
            (d.eos or p.position_us >= p.stream.duration_us))
        {
            p.playing = false;
            p.finished = true;
            p.position_us = p.stream.duration_us;
            if (p.pcm) |*pcm| pcm.drop();
            changed = true;
        }
        return changed;
    }

    /// How long the main loop should wait before calling `step` again.
    pub fn nextWakeNs(p: *const Player) ?u64 {
        if (!p.playing or p.decoder == null) return null;
        const video_wake: u64 = if (p.pending) |f| blk: {
            if (f.pts_us <= p.position_us) break :blk 1 * std.time.ns_per_ms;
            const wait_us = @min(f.pts_us - p.position_us, 33_000);
            break :blk @max(wait_us * std.time.ns_per_us, 1 * std.time.ns_per_ms);
        } else 8 * std.time.ns_per_ms;

        if (p.pcm != null) {
            if (p.stream.audio_track) |at| {
                if (p.next_audio_pkt < at.packets.len or p.audio_frames_pos < p.audio_frames_len) {
                    return @min(video_wake, 12 * std.time.ns_per_ms);
                }
            }
        }
        return video_wake;
    }

    pub fn togglePlay(p: *Player, now_ns: u64) void {
        if (p.decoder == null) return;
        if (p.playing) {
            const elapsed_us = (now_ns -| p.start_ns) / std.time.ns_per_us;
            p.position_us = @min(p.base_us + elapsed_us, p.stream.duration_us);
            p.base_us = p.position_us;
            p.playing = false;
            p.resetAudioAt(p.position_us);
            return;
        }
        if (p.finished or p.position_us >= p.stream.duration_us) {
            p.seekTo(0, now_ns);
        }
        p.finished = false;
        p.playing = true;
        p.start_ns = now_ns;
        p.base_us = p.position_us;
        p.audio_settings = audio.loadSettings();
        if (p.pcm) |*pcm| {
            pcm.hw_volume = audio.alsa.setCardVolume(pcm.card, p.audio_settings.volume, p.audio_settings.muted);
        }
        p.feedAudio();
    }

    pub fn seekTo(p: *Player, target_us: u64, now_ns: u64) void {
        const clamped = @min(target_us, p.stream.duration_us);
        const kf = p.stream.keyframeAtOrBefore(clamped);
        const kf_pts = if (kf < p.stream.samples.len) p.stream.samples[kf].pts_us else 0;
        p.position_us = kf_pts;
        p.base_us = kf_pts;
        p.start_ns = now_ns;
        p.finished = false;
        p.next_sample = kf;
        p.need_header = true;
        p.eos_sent = false;
        p.resetAudioAt(kf_pts);
        if (p.pending) |f| {
            if (p.decoder) |*d| d.queueCapture(f.index) catch {};
            p.pending = null;
        }
        if (p.decoder) |*d| {
            d.reset() catch return;
            var tries: u32 = 0;
            while (tries < 40) : (tries += 1) {
                p.feedDecoder();
                if (d.nextFrame() catch null) |f| {
                    p.presentFrame(f);
                    d.queueCapture(f.index) catch {};
                    break;
                }
                var fds = [1]linux.pollfd{.{
                    .fd = d.fd,
                    .events = linux.POLL.IN | linux.POLL.PRI | linux.POLL.OUT,
                    .revents = 0,
                }};
                _ = linux.poll(&fds, 1, 5);
            }
        }
        if (p.playing) p.feedAudio();
    }
};

/// Formats a duration in microseconds as `"M:SS"` or `"H:MM:SS"`.
pub fn formatDuration(buf: []u8, us: u64) []const u8 {
    const total_secs = (us + 500_000) / 1_000_000;
    const secs = total_secs % 60;
    const mins = (total_secs / 60) % 60;
    const hours = total_secs / 3600;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, mins, secs }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ mins, secs }) catch "";
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "H.264 SPS parsing extracts resolution and frame rate" {
    // Baseline 320x240 SPS (pic_width_in_mbs_minus1 = 19, pic_height_in_map_units_minus1 = 14).
    const sps = [_]u8{ 0x67, 0x42, 0xc0, 0x1e, 0xd9, 0x01, 0x41, 0xfb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x62, 0xe4, 0x80 };
    try testing.expect(looksLikeAnnexB(&[_]u8{ 0, 0, 0, 1 } ++ sps));
    const info = parseSps(&sps).?;
    try testing.expectEqual(@as(u32, 320), info.width);
    try testing.expectEqual(@as(u32, 240), info.height);
    try testing.expectEqual(@as(u64, 33_333), info.frame_duration_us);
}

test "MP4 demuxing, avcC to Annex-B conversion and keyframe seeking" {
    // Build a minimal valid MP4 (`ftyp` + `mdat` + `moov`) with 2 H.264 frames.
    const sps = [_]u8{ 0x67, 0x42, 0xc0, 0x1e, 0xd9, 0x01, 0x41, 0xfb, 0x80 };
    const pps = [_]u8{ 0x68, 0xce, 0x3c, 0x80 };
    // Frame 0: IDR slice (4-byte length prefix + 4 bytes payload).
    const frame0 = [_]u8{ 0, 0, 0, 4, 0x65, 0x88, 0x84, 0x21 };
    // Frame 1: P slice (4-byte length prefix + 4 bytes payload).
    const frame1 = [_]u8{ 0, 0, 0, 4, 0x41, 0x9a, 0x24, 0x6c };

    const mp4 = try buildTestMp4(testing.allocator, &sps, &pps, &frame0, &frame1);
    defer testing.allocator.free(mp4);

    try testing.expect(looksLikeVideo(mp4));

    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-video-test-{d}.mp4", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);
    try sys.files.writeNew(path, mp4);

    const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    var stream = try Stream.open(testing.allocator, fd, mp4.len, true);
    defer stream.deinit();

    try testing.expectEqual(Codec.h264, stream.codec);
    try testing.expectEqual(@as(u32, 320), stream.width);
    try testing.expectEqual(@as(u32, 240), stream.height);
    try testing.expectEqual(@as(usize, 2), stream.samples.len);
    try testing.expectEqual(@as(u64, 80_000), stream.duration_us);
    try testing.expect(stream.samples[0].keyframe);
    try testing.expect(!stream.samples[1].keyframe);
    try testing.expectEqual(@as(u64, 0), stream.samples[0].pts_us);
    try testing.expectEqual(@as(u64, 40_000), stream.samples[1].pts_us);

    var out: [256]u8 = undefined;
    const n0 = try stream.readSample(0, true, &out);
    // Header (4+sps + 4+pps) + Annex-B frame0 (4+4)
    try testing.expectEqual(4 + sps.len + 4 + pps.len + 8, n0);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1 }, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21 }, out[n0 - 8 .. n0]);

    const n1 = try stream.readSample(1, false, &out);
    try testing.expectEqual(@as(usize, 8), n1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x41, 0x9a, 0x24, 0x6c }, out[0..n1]);

    try testing.expectEqual(@as(usize, 0), stream.keyframeAtOrBefore(50_000));
}

test "YUV420 and NV12 conversion produces opaque ARGB pixels" {
    // 2x2 white pixel block (Y=235, U=128, V=128) in YU12.
    const yu12 = [_]u8{
        235, 235, 235, 235, // Y (2x2)
        128, // U (1x1)
        128, // V (1x1)
    };
    var dst: [4]u32 = undefined;
    yuvToArgb(&yu12, 2, 2, 2, 2, v4l2.pix_fmt_yuv420, &dst, 2, 2);
    for (dst) |px| try testing.expectEqual(@as(u32, 0xffffffff), px);

    // 2x2 black pixel block (Y=16, U=128, V=128) in NV12.
    const nv12 = [_]u8{
        16,  16,  16, 16,
        128, 128,
    };
    yuvToArgb(&nv12, 2, 2, 2, 2, v4l2.pix_fmt_nv12, &dst, 2, 2);
    for (dst) |px| try testing.expectEqual(@as(u32, 0xff000000), px);

    // Round-trip ARGB -> YUV420 (with 64-byte stride alignment) -> ARGB.
    const src_px = [4]u32{ 0xffffffff, 0xffffffff, 0xff000000, 0xff000000 };
    var yuv_buf: [64 * 2 * 3 / 2]u8 = @splat(0);
    const written = argbToYuv420(&src_px, 2, 2, &yuv_buf, 64, 2);
    try testing.expectEqual(yuv_buf.len, written);
    var roundtrip: [4]u32 = undefined;
    yuvToArgb(&yuv_buf, 2, 2, 64, 2, v4l2.pix_fmt_yuv420, &roundtrip, 2, 2);
    try testing.expectEqual(@as(u32, 0xffffffff), roundtrip[0]);
    try testing.expectEqual(@as(u32, 0xffffffff), roundtrip[1]);
    try testing.expectEqual(@as(u32, 0xff000000), roundtrip[2]);
    try testing.expectEqual(@as(u32, 0xff000000), roundtrip[3]);
}

test "Mp4Muxer streams Annex-B H.264 packets into a valid playable MP4" {
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-mux-test-{d}.mp4", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);

    const fd: linux.fd_t = @intCast(try sys.check(linux.open(
        path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    )));
    defer sys.close(fd);

    var mux = try Mp4Muxer.init(testing.allocator, fd, 320, 240, 25);
    defer mux.deinit();

    const sps = [_]u8{ 0x67, 0x42, 0xc0, 0x1e, 0xd9, 0x01, 0x41, 0xfb, 0x80 };
    const pps = [_]u8{ 0x68, 0xce, 0x3c, 0x80 };
    // Packet 0: separate SPS+PPS header buffer (as bcm2835-codec-encode emits first).
    const hdr_pkt = [_]u8{ 0, 0, 0, 1 } ++ sps ++ [_]u8{ 0, 0, 0, 1 } ++ pps;
    try mux.writePacket(&hdr_pkt, 0, false);
    try testing.expectEqual(@as(usize, 0), mux.samples.items.len);

    // Packet 1: IDR slice at t = 0.
    const idr_pkt = [_]u8{ 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21 };
    try mux.writePacket(&idr_pkt, 0, true);

    // Packet 2: non-IDR P slice at t = 40ms.
    const p_pkt = [_]u8{ 0, 0, 0, 1, 0x41, 0x9a, 0x24, 0x6c };
    try mux.writePacket(&p_pkt, 40_000, false);

    try mux.finish();

    var stream = try Stream.open(testing.allocator, fd, mux.write_offset, false);
    defer stream.deinit();

    try testing.expectEqual(Codec.h264, stream.codec);
    try testing.expectEqual(@as(u32, 320), stream.width);
    try testing.expectEqual(@as(u32, 240), stream.height);
    try testing.expectEqual(@as(usize, 2), stream.samples.len);
    try testing.expectEqual(@as(u64, 80_000), stream.duration_us);
    try testing.expect(stream.samples[0].keyframe);
    try testing.expect(!stream.samples[1].keyframe);

    var sample_buf: [128]u8 = undefined;
    const s0 = try stream.readSample(0, true, &sample_buf);
    try testing.expectEqual(4 + sps.len + 4 + pps.len + idr_pkt.len, s0);
    const s1 = try stream.readSample(1, false, &sample_buf);
    try testing.expectEqual(p_pkt.len, s1);
    try testing.expectEqualSlices(u8, &p_pkt, sample_buf[0..s1]);
}

pub fn buildTestMp4(gpa: std.mem.Allocator, sps: []const u8, pps: []const u8, frame0: []const u8, frame1: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const w32 = struct {
        fn put(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .big);
            try list.appendSlice(a, &b);
        }
        fn put16(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .big);
            try list.appendSlice(a, &b);
        }
    };

    // ftyp (20 bytes)
    try w32.put(&out, gpa, 20);
    try out.appendSlice(gpa, "ftypisom\x00\x00\x02\x00isom");

    // mdat (8 + frame0.len + frame1.len)
    const mdat_data_off: u32 = @intCast(out.items.len + 8);
    try w32.put(&out, gpa, @intCast(8 + frame0.len + frame1.len));
    try out.appendSlice(gpa, "mdat");
    try out.appendSlice(gpa, frame0);
    try out.appendSlice(gpa, frame1);

    // avcC box
    var avcc: std.ArrayList(u8) = .empty;
    defer avcc.deinit(gpa);
    try w32.put(&avcc, gpa, @intCast(8 + 6 + 2 + sps.len + 1 + 2 + pps.len));
    try avcc.appendSlice(gpa, "avcC");
    try avcc.appendSlice(gpa, &.{ 1, sps[1], sps[2], sps[3], 0xff, 0xe1 });
    try w32.put16(&avcc, gpa, @intCast(sps.len));
    try avcc.appendSlice(gpa, sps);
    try avcc.append(gpa, 1);
    try w32.put16(&avcc, gpa, @intCast(pps.len));
    try avcc.appendSlice(gpa, pps);

    // avc1 visual sample entry (8 + 78 + avcc)
    var avc1: std.ArrayList(u8) = .empty;
    defer avc1.deinit(gpa);
    try w32.put(&avc1, gpa, @intCast(8 + 78 + avcc.items.len));
    try avc1.appendSlice(gpa, "avc1");
    try avc1.appendNTimes(gpa, 0, 24);
    try w32.put16(&avc1, gpa, 320);
    try w32.put16(&avc1, gpa, 240);
    try avc1.appendNTimes(gpa, 0, 50);
    try avc1.appendSlice(gpa, avcc.items);

    // stsd
    var stsd: std.ArrayList(u8) = .empty;
    defer stsd.deinit(gpa);
    try w32.put(&stsd, gpa, @intCast(16 + avc1.items.len));
    try stsd.appendSlice(gpa, "stsd\x00\x00\x00\x00\x00\x00\x00\x01");
    try stsd.appendSlice(gpa, avc1.items);

    // stts (2 samples, delta = 40 ticks at timescale 1000 => 40ms each)
    var stts: std.ArrayList(u8) = .empty;
    defer stts.deinit(gpa);
    try w32.put(&stts, gpa, 24);
    try stts.appendSlice(gpa, "stts\x00\x00\x00\x00\x00\x00\x00\x01");
    try w32.put(&stts, gpa, 2);
    try w32.put(&stts, gpa, 40);

    // stsc (1 chunk of 2 samples)
    var stsc: std.ArrayList(u8) = .empty;
    defer stsc.deinit(gpa);
    try w32.put(&stsc, gpa, 28);
    try stsc.appendSlice(gpa, "stsc\x00\x00\x00\x00\x00\x00\x00\x01");
    try w32.put(&stsc, gpa, 1);
    try w32.put(&stsc, gpa, 2);
    try w32.put(&stsc, gpa, 1);

    // stsz
    var stsz: std.ArrayList(u8) = .empty;
    defer stsz.deinit(gpa);
    try w32.put(&stsz, gpa, 28);
    try stsz.appendSlice(gpa, "stsz\x00\x00\x00\x00\x00\x00\x00\x00");
    try w32.put(&stsz, gpa, 2);
    try w32.put(&stsz, gpa, @intCast(frame0.len));
    try w32.put(&stsz, gpa, @intCast(frame1.len));

    // stco
    var stco: std.ArrayList(u8) = .empty;
    defer stco.deinit(gpa);
    try w32.put(&stco, gpa, 20);
    try stco.appendSlice(gpa, "stco\x00\x00\x00\x00\x00\x00\x00\x01");
    try w32.put(&stco, gpa, mdat_data_off);

    // stss (sample 1 is keyframe)
    var stss: std.ArrayList(u8) = .empty;
    defer stss.deinit(gpa);
    try w32.put(&stss, gpa, 20);
    try stss.appendSlice(gpa, "stss\x00\x00\x00\x00\x00\x00\x00\x01");
    try w32.put(&stss, gpa, 1);

    // stbl
    var stbl: std.ArrayList(u8) = .empty;
    defer stbl.deinit(gpa);
    const stbl_len = 8 + stsd.items.len + stts.items.len + stsc.items.len + stsz.items.len + stco.items.len + stss.items.len;
    try w32.put(&stbl, gpa, @intCast(stbl_len));
    try stbl.appendSlice(gpa, "stbl");
    try stbl.appendSlice(gpa, stsd.items);
    try stbl.appendSlice(gpa, stts.items);
    try stbl.appendSlice(gpa, stsc.items);
    try stbl.appendSlice(gpa, stsz.items);
    try stbl.appendSlice(gpa, stco.items);
    try stbl.appendSlice(gpa, stss.items);

    // minf
    var minf: std.ArrayList(u8) = .empty;
    defer minf.deinit(gpa);
    try w32.put(&minf, gpa, @intCast(8 + stbl.items.len));
    try minf.appendSlice(gpa, "minf");
    try minf.appendSlice(gpa, stbl.items);

    // mdhd (version 0: 4+12+4(timescale=1000)+4(duration=80)+4 = 32 bytes)
    var mdhd: std.ArrayList(u8) = .empty;
    defer mdhd.deinit(gpa);
    try w32.put(&mdhd, gpa, 32);
    try mdhd.appendSlice(gpa, "mdhd");
    try mdhd.appendNTimes(gpa, 0, 12);
    try w32.put(&mdhd, gpa, 1000);
    try w32.put(&mdhd, gpa, 80);
    try mdhd.appendNTimes(gpa, 0, 4);

    // hdlr (vide)
    var hdlr: std.ArrayList(u8) = .empty;
    defer hdlr.deinit(gpa);
    try w32.put(&hdlr, gpa, 32);
    try hdlr.appendSlice(gpa, "hdlr\x00\x00\x00\x00\x00\x00\x00\x00vide");
    try hdlr.appendNTimes(gpa, 0, 12);

    // mdia
    var mdia: std.ArrayList(u8) = .empty;
    defer mdia.deinit(gpa);
    try w32.put(&mdia, gpa, @intCast(8 + mdhd.items.len + hdlr.items.len + minf.items.len));
    try mdia.appendSlice(gpa, "mdia");
    try mdia.appendSlice(gpa, mdhd.items);
    try mdia.appendSlice(gpa, hdlr.items);
    try mdia.appendSlice(gpa, minf.items);

    // trak
    var trak: std.ArrayList(u8) = .empty;
    defer trak.deinit(gpa);
    try w32.put(&trak, gpa, @intCast(8 + mdia.items.len));
    try trak.appendSlice(gpa, "trak");
    try trak.appendSlice(gpa, mdia.items);

    // moov
    try w32.put(&out, gpa, @intCast(8 + trak.items.len));
    try out.appendSlice(gpa, "moov");
    try out.appendSlice(gpa, trak.items);

    return out.toOwnedSlice(gpa);
}

test "MP4 audio track parsing and PCM/AAC packet decoding" {
    // 1. Verify PCM packet decoding across endianness and channel counts.
    var pcm_out: [1024][2]i16 = undefined;
    const s16le_bytes = [_]u8{ 0x34, 0x12, 0xcc, 0xed, 0x00, 0x40, 0x00, 0xc0 };
    const n_le = decodeAudioPcmPacket(.pcm_s16le, 2, &s16le_bytes, &pcm_out);
    try testing.expectEqual(@as(usize, 2), n_le);
    try testing.expectEqual(@as(i16, 0x1234), pcm_out[0][0]);
    try testing.expectEqual(@as(i16, -0x1234), pcm_out[0][1]);
    try testing.expectEqual(@as(i16, 0x4000), pcm_out[1][0]);
    try testing.expectEqual(@as(i16, -0x4000), pcm_out[1][1]);

    const s16be_mono = [_]u8{ 0x12, 0x34 };
    const n_be = decodeAudioPcmPacket(.pcm_s16be, 1, &s16be_mono, &pcm_out);
    try testing.expectEqual(@as(usize, 1), n_be);
    try testing.expectEqual(@as(i16, 0x1234), pcm_out[0][0]);
    try testing.expectEqual(@as(i16, 0x1234), pcm_out[0][1]);

    // 2. Verify mp4a stsd + esds parsing for 48 kHz stereo AAC-LC (0x11, 0x90).
    const mp4a_stsd = [_]u8{
        0, 0, 0, 0, // version + flags
        0, 0, 0, 1, // entry count = 1
        0, 0, 0, 57, 'm', 'p', '4', 'a', // box header (57 bytes)
        0, 0, 0, 0, 0, 0, // reserved
        0, 1, // data_reference_index
        0, 0, 0, 0, 0, 0, 0, 0, // version=0, revision=0, vendor=0
        0, 2, // channels = 2
        0, 16, // sample_size = 16
        0, 0, 0, 0, // compression_id, packet_size
        0xbb, 0x80, 0,   0, // sample_rate = 48000.0 (16.16 fixed)
        // esds child box (21 bytes):
        0,    0,    0,   21,
        'e',  's',  'd', 's',
        0, 0, 0, 0, // version + flags
        0x03, 0x07, 0x00, 0x01, 0x00, // ES_Descriptor
        0x05, 0x02, 0x11, 0x90, // DecoderSpecificInfo: AAC-LC 48 kHz stereo
    };
    const stsd_info = try parseAudioStsd(&mp4a_stsd, 48000);
    try testing.expectEqual(AudioCodec.aac, stsd_info.codec);
    try testing.expectEqual(@as(u32, 48000), stsd_info.sample_rate);
    try testing.expectEqual(@as(u8, 2), stsd_info.channels);
    try testing.expectEqual(@as(u4, 3), stsd_info.aac_config.freq_index);
}
