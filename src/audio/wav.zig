//! RIFF/WAVE (`.wav`) header parser and PCM frame decoder.
//!
//! Parses the `fmt ` and `data` chunks from the start of a WAVE file (skipping
//! metadata chunks such as `LIST`, `JUNK`, `fact` or `bext` in between) so
//! large `.wav` files can be streamed directly from a file descriptor without
//! loading the entire file into memory.

const std = @import("std");

pub const Encoding = enum {
    pcm_u8,
    pcm_s16le,
    pcm_s24le,
    pcm_s32le,
    float_f32le,
};

pub const Header = struct {
    encoding: Encoding,
    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    block_align: u16,
    /// Byte offset of the first sample frame inside the file.
    data_offset: u64,
    /// Byte length of the `data` chunk payload.
    data_size: u64,

    pub fn bytesPerFrame(h: Header) u32 {
        return @max(@as(u32, h.block_align), @as(u32, h.channels) * (h.bits_per_sample / 8));
    }

    pub fn totalFrames(h: Header) u64 {
        const bpf = h.bytesPerFrame();
        if (bpf == 0) return 0;
        return h.data_size / bpf;
    }

    pub fn durationMs(h: Header) u64 {
        if (h.sample_rate == 0) return 0;
        return (h.totalFrames() * 1000) / h.sample_rate;
    }

    /// Formats a human-readable summary such as `"WAV audio, 44.1 kHz stereo"`.
    pub fn describe(h: Header, buf: []u8) []const u8 {
        var khz_buf: [24]u8 = undefined;
        const khz = if (h.sample_rate % 1000 == 0)
            std.fmt.bufPrint(&khz_buf, "{d} kHz", .{h.sample_rate / 1000}) catch "WAV audio"
        else if (h.sample_rate % 100 == 0)
            std.fmt.bufPrint(&khz_buf, "{d}.{d} kHz", .{ h.sample_rate / 1000, (h.sample_rate % 1000) / 100 }) catch "WAV audio"
        else
            std.fmt.bufPrint(&khz_buf, "{d}.{d:0>2} kHz", .{ h.sample_rate / 1000, (h.sample_rate % 1000) / 10 }) catch "WAV audio";

        return switch (h.channels) {
            1 => std.fmt.bufPrint(buf, "WAV audio, {s} mono", .{khz}) catch "WAV audio",
            2 => std.fmt.bufPrint(buf, "WAV audio, {s} stereo", .{khz}) catch "WAV audio",
            else => std.fmt.bufPrint(buf, "WAV audio, {s}, {d} channels", .{ khz, h.channels }) catch "WAV audio",
        };
    }
};

/// Whether `bytes` begins with a RIFF/WAVE magic header.
pub fn isWav(bytes: []const u8) bool {
    return bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WAVE");
}

/// Parses a WAVE header from the prefix of a file (`bytes` need only cover up
/// to the `data` chunk's 8-byte header, not the whole sample payload).
pub fn parseHeader(bytes: []const u8) ?Header {
    if (!isWav(bytes)) return null;
    const riff_size = std.mem.readInt(u32, bytes[4..8], .little);
    const riff_end: u64 = @as(u64, riff_size) + 8;

    var pos: usize = 12;
    var fmt_encoding: ?Encoding = null;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var block_align: u16 = 0;
    var bits_per_sample: u16 = 0;

    while (pos + 8 <= bytes.len) {
        const id = bytes[pos..][0..4];
        const chunk_size = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const payload_start = pos + 8;

        if (std.mem.eql(u8, id, "fmt ")) {
            if (chunk_size < 16 or payload_start + chunk_size > bytes.len) return null;
            const fmt = bytes[payload_start..][0..chunk_size];
            var tag = std.mem.readInt(u16, fmt[0..2], .little);
            channels = std.mem.readInt(u16, fmt[2..4], .little);
            sample_rate = std.mem.readInt(u32, fmt[4..8], .little);
            block_align = std.mem.readInt(u16, fmt[12..14], .little);
            bits_per_sample = std.mem.readInt(u16, fmt[14..16], .little);

            if (tag == 0xFFFE and chunk_size >= 40) {
                tag = std.mem.readInt(u16, fmt[24..26], .little);
            }
            if (channels == 0 or channels > 8) return null;
            if (sample_rate < 4000 or sample_rate > 384_000) return null;

            fmt_encoding = switch (tag) {
                1 => switch (bits_per_sample) {
                    8 => .pcm_u8,
                    16 => .pcm_s16le,
                    24 => .pcm_s24le,
                    32 => .pcm_s32le,
                    else => return null,
                },
                3 => switch (bits_per_sample) {
                    32 => .float_f32le,
                    else => return null,
                },
                else => return null,
            };
            const min_align = channels * (bits_per_sample / 8);
            if (block_align < min_align) block_align = min_align;
        } else if (std.mem.eql(u8, id, "data")) {
            const enc = fmt_encoding orelse return null;
            const data_offset: u64 = payload_start;
            const max_data = if (riff_end > data_offset) riff_end - data_offset else chunk_size;
            const data_size: u64 = if (chunk_size == 0xFFFF_FFFF) max_data else @min(@as(u64, chunk_size), max_data);
            return .{
                .encoding = enc,
                .channels = channels,
                .sample_rate = sample_rate,
                .bits_per_sample = bits_per_sample,
                .block_align = block_align,
                .data_offset = data_offset,
                .data_size = data_size,
            };
        }

        const padded = @as(usize, chunk_size) + (@as(usize, chunk_size) & 1);
        pos = std.math.add(usize, payload_start, padded) catch return null;
    }
    return null;
}

/// Decodes up to `out_stereo.len` frames from `raw` (starting on a frame
/// boundary) into signed 16-bit stereo `[left, right]` pairs. Returns the
/// number of frames decoded.
pub fn decodeFrames(header: Header, raw: []const u8, out_stereo: [][2]i16) usize {
    const bpf: usize = header.bytesPerFrame();
    if (bpf == 0) return 0;
    const avail_frames = raw.len / bpf;
    const count = @min(avail_frames, out_stereo.len);
    const bps: usize = header.bits_per_sample / 8;

    for (0..count) |i| {
        const frame = raw[i * bpf ..][0..bpf];
        const left = decodeSample(header.encoding, frame[0..bps]);
        const right = if (header.channels >= 2 and bps * 2 <= bpf)
            decodeSample(header.encoding, frame[bps .. bps * 2])
        else
            left;
        out_stereo[i] = .{ left, right };
    }
    return count;
}

fn decodeSample(encoding: Encoding, bytes: []const u8) i16 {
    return switch (encoding) {
        .pcm_u8 => (@as(i16, bytes[0]) - 128) << 8,
        .pcm_s16le => std.mem.readInt(i16, bytes[0..2], .little),
        .pcm_s24le => @bitCast(std.mem.readInt(u16, bytes[1..3], .little)),
        .pcm_s32le => @intCast(std.mem.readInt(i32, bytes[0..4], .little) >> 16),
        .float_f32le => blk: {
            const bits = std.mem.readInt(u32, bytes[0..4], .little);
            const f: f32 = @bitCast(bits);
            if (std.math.isNan(f)) break :blk 0;
            const clamped = std.math.clamp(f, -1.0, 1.0);
            break :blk @intFromFloat(@round(clamped * 32767.0));
        },
    };
}

/// Writes a canonical 44-byte 16-bit PCM WAVE header into `out`.
pub fn writePcm16Header(out: *[44]u8, sample_rate: u32, channels: u16, num_frames: u32) void {
    const block_align: u16 = channels * 2;
    const data_bytes: u32 = num_frames * @as(u32, block_align);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_bytes, .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], sample_rate * @as(u32, block_align), .little);
    std.mem.writeInt(u16, out[32..34], block_align, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_bytes, .little);
}

const testing = std.testing;

test "parseHeader parses standard and metadata-padded WAV headers" {
    var hdr_bytes: [44]u8 = undefined;
    writePcm16Header(&hdr_bytes, 44100, 2, 44100 * 3);
    const h = parseHeader(&hdr_bytes).?;
    try testing.expectEqual(Encoding.pcm_s16le, h.encoding);
    try testing.expectEqual(@as(u16, 2), h.channels);
    try testing.expectEqual(@as(u32, 44100), h.sample_rate);
    try testing.expectEqual(@as(u64, 44), h.data_offset);
    try testing.expectEqual(@as(u64, 44100 * 3 * 4), h.data_size);
    try testing.expectEqual(@as(u64, 3000), h.durationMs());

    var desc_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("WAV audio, 44.1 kHz stereo", h.describe(&desc_buf));

    // With an odd-sized JUNK chunk between fmt and data.
    var with_junk: [60]u8 = undefined;
    @memcpy(with_junk[0..36], hdr_bytes[0..36]);
    std.mem.writeInt(u32, with_junk[4..8], 52 + 1600, .little);
    @memcpy(with_junk[36..40], "JUNK");
    std.mem.writeInt(u32, with_junk[40..44], 7, .little);
    @memset(with_junk[44..52], 0); // 7 bytes + 1 pad byte
    @memcpy(with_junk[52..56], "data");
    std.mem.writeInt(u32, with_junk[56..60], 1600, .little);
    const hj = parseHeader(&with_junk).?;
    try testing.expectEqual(@as(u64, 60), hj.data_offset);
    try testing.expectEqual(@as(u64, 1600), hj.data_size);
}

test "decodeFrames converts 8-bit, 16-bit, 24-bit and float samples to stereo i16" {
    // 16-bit mono -> stereo duplication.
    const h16: Header = .{
        .encoding = .pcm_s16le,
        .channels = 1,
        .sample_rate = 48000,
        .bits_per_sample = 16,
        .block_align = 2,
        .data_offset = 44,
        .data_size = 4,
    };
    var raw16: [4]u8 = undefined;
    std.mem.writeInt(i16, raw16[0..2], 1234, .little);
    std.mem.writeInt(i16, raw16[2..4], -5678, .little);
    var out: [2][2]i16 = undefined;
    try testing.expectEqual(@as(usize, 2), decodeFrames(h16, &raw16, &out));
    try testing.expectEqual([2]i16{ 1234, 1234 }, out[0]);
    try testing.expectEqual([2]i16{ -5678, -5678 }, out[1]);

    // 8-bit unsigned stereo.
    const h8: Header = .{
        .encoding = .pcm_u8,
        .channels = 2,
        .sample_rate = 22050,
        .bits_per_sample = 8,
        .block_align = 2,
        .data_offset = 44,
        .data_size = 2,
    };
    const raw8 = [_]u8{ 128, 255 };
    try testing.expectEqual(@as(usize, 1), decodeFrames(h8, &raw8, out[0..1]));
    try testing.expectEqual(@as(i16, 0), out[0][0]);
    try testing.expectEqual(@as(i16, 127 << 8), out[0][1]);
}
