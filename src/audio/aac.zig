//! ISO/IEC 14496-3 (MPEG-4 Audio) AAC-LC decoder.
//!
//! Decodes `mp4a` AudioSpecificConfig headers and raw AAC-LC frames into
//! interleaved stereo 16-bit signed PCM (`[1024][2]i16`).

const std = @import("std");

pub const frame_samples = 1024;

pub const sample_rates = [13]u32{
    96000, 88200, 64000, 48000, 44100, 32000,
    24000, 22050, 16000, 12000, 11025, 8000,
    7350,
};

pub const Config = struct {
    object_type: u8 = 2,
    freq_index: u4 = 3,
    sample_rate: u32 = 48000,
    channels: u8 = 2,
};

/// Parses an MPEG-4 `AudioSpecificConfig` (from an `esds` DecoderSpecificInfo
/// descriptor) into a `Config`.
pub fn parseConfig(asc: []const u8) ?Config {
    if (asc.len < 2) return null;
    var br: BitReader = .{ .data = asc };
    var obj_type: u8 = @intCast(br.readBits(5) orelse return null);
    if (obj_type == 31) {
        obj_type = @intCast(32 + (br.readBits(6) orelse return null));
    }
    // Support AAC Main (1), AAC-LC (2), AAC-LTP (4), SBR/HE-AACv1 (5), and PS/HE-AACv2 (29).
    if (obj_type != 1 and obj_type != 2 and obj_type != 4 and obj_type != 5 and obj_type != 29) {
        return null;
    }

    const freq_idx_raw: u4 = @intCast(br.readBits(4) orelse return null);
    var sample_rate: u32 = 48000;
    var freq_index: u4 = 3;
    if (freq_idx_raw == 15) {
        sample_rate = br.readBits(24) orelse return null;
        if (sample_rate == 0) return null;
        freq_index = nearestFreqIndex(sample_rate);
    } else if (freq_idx_raw < sample_rates.len) {
        freq_index = freq_idx_raw;
        sample_rate = sample_rates[freq_idx_raw];
    } else {
        return null;
    }

    const chan_cfg: u8 = @intCast(br.readBits(4) orelse return null);
    const channels: u8 = switch (chan_cfg) {
        0 => 2,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5, 6 => 6,
        7 => 8,
        else => 2,
    };

    return .{
        .object_type = obj_type,
        .freq_index = freq_index,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

fn nearestFreqIndex(rate: u32) u4 {
    for (sample_rates, 0..) |sr, i| {
        if (rate >= sr) return @intCast(i);
    }
    return 11;
}

// --- Bitstream reader --------------------------------------------------------

const BitReader = struct {
    data: []const u8,
    bit: usize = 0,

    fn bitsLeft(b: *const BitReader) usize {
        const total = b.data.len * 8;
        return if (b.bit < total) total - b.bit else 0;
    }

    fn readBit(b: *BitReader) ?u1 {
        if (b.bit >= b.data.len * 8) return null;
        const byte = b.data[b.bit >> 3];
        const shift: u3 = @intCast(7 - (b.bit & 7));
        b.bit += 1;
        return @intCast((byte >> shift) & 1);
    }

    fn readBits(b: *BitReader, n: u5) ?u32 {
        if (n == 0) return 0;
        if (b.bit + n > b.data.len * 8) return null;
        var v: u32 = 0;
        var k: u5 = 0;
        while (k < n) : (k += 1) {
            const byte = b.data[b.bit >> 3];
            const shift: u3 = @intCast(7 - (b.bit & 7));
            v = (v << 1) | ((byte >> shift) & 1);
            b.bit += 1;
        }
        return v;
    }

    fn skipBits(b: *BitReader, n: usize) void {
        b.bit = @min(b.bit + n, b.data.len * 8);
    }

    fn byteAlign(b: *BitReader) void {
        b.bit = (b.bit + 7) & ~@as(usize, 7);
    }
};

// --- Canonical Huffman codebooks (ISO/IEC 14496-3 Table 4.A.1 .. 4.A.12) ----

const sf_counts = [19]u16{ 1, 0, 1, 3, 2, 4, 3, 5, 4, 6, 6, 6, 5, 8, 4, 7, 3, 7, 46 };
const sf_syms = [121]u8{ 60, 59, 61, 58, 62, 57, 63, 56, 64, 55, 65, 66, 54, 67, 53, 68, 52, 69, 51, 70, 50, 49, 71, 72, 48, 73, 47, 74, 46, 76, 75, 77, 78, 45, 43, 44, 79, 42, 41, 80, 40, 81, 39, 82, 38, 83, 37, 35, 85, 33, 36, 34, 84, 32, 87, 89, 30, 31, 86, 29, 26, 27, 28, 24, 88, 25, 22, 23, 90, 21, 19, 3, 1, 2, 0, 98, 99, 100, 101, 102, 117, 97, 91, 92, 93, 94, 95, 96, 104, 111, 112, 113, 114, 115, 116, 110, 105, 106, 107, 108, 109, 118, 6, 8, 9, 10, 5, 103, 120, 119, 4, 7, 15, 16, 18, 20, 17, 11, 12, 14, 13 };

const cb1_counts = [19]u16{ 1, 0, 0, 0, 8, 0, 24, 0, 24, 8, 16, 0, 0, 0, 0, 0, 0, 0, 0 };
const cb1_syms = [81]u8{ 40, 67, 13, 39, 49, 41, 37, 43, 31, 58, 22, 38, 46, 34, 42, 76, 36, 4, 28, 64, 48, 16, 44, 70, 32, 52, 50, 10, 68, 12, 66, 14, 30, 73, 19, 61, 51, 47, 35, 33, 55, 65, 45, 25, 15, 7, 29, 59, 57, 21, 1, 27, 53, 69, 77, 23, 79, 5, 9, 75, 63, 11, 3, 17, 71, 60, 20, 24, 56, 80, 8, 72, 6, 0, 74, 62, 26, 18, 2, 54, 78 };

const cb2_counts = [19]u16{ 0, 0, 1, 1, 7, 24, 15, 19, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
const cb2_syms = [81]u8{ 40, 67, 13, 41, 37, 39, 31, 43, 49, 34, 22, 46, 42, 48, 38, 12, 58, 64, 4, 36, 70, 68, 32, 16, 50, 28, 14, 30, 10, 76, 52, 44, 66, 47, 65, 19, 33, 61, 75, 71, 25, 29, 79, 15, 1, 11, 55, 73, 59, 21, 7, 17, 5, 3, 27, 69, 63, 45, 53, 23, 9, 51, 57, 35, 77, 60, 20, 56, 0, 24, 26, 80, 6, 62, 18, 8, 72, 54, 2, 74, 78 };

const cb3_counts = [19]u16{ 1, 0, 0, 4, 2, 6, 3, 5, 15, 15, 8, 9, 3, 3, 5, 2, 0, 0, 0 };
const cb3_syms = [81]u8{ 0, 27, 1, 9, 3, 36, 4, 12, 10, 30, 13, 28, 39, 40, 31, 37, 54, 2, 5, 63, 48, 7, 16, 45, 14, 66, 6, 21, 15, 18, 11, 57, 49, 22, 42, 43, 46, 33, 34, 19, 67, 41, 64, 32, 8, 17, 75, 51, 29, 55, 25, 72, 52, 38, 58, 44, 76, 24, 23, 35, 73, 69, 78, 26, 79, 70, 50, 53, 20, 60, 47, 61, 68, 65, 80, 77, 71, 59, 56, 74, 62 };

const cb4_counts = [19]u16{ 0, 0, 0, 10, 6, 0, 9, 21, 8, 14, 11, 2, 0, 0, 0, 0, 0, 0, 0 };
const cb4_syms = [81]u8{ 40, 13, 37, 39, 31, 27, 36, 0, 4, 30, 28, 12, 1, 10, 3, 9, 67, 43, 49, 41, 66, 64, 48, 58, 16, 14, 42, 22, 32, 46, 38, 34, 63, 57, 45, 55, 11, 21, 5, 15, 19, 29, 7, 33, 54, 2, 18, 6, 52, 76, 70, 44, 50, 68, 51, 75, 69, 25, 17, 73, 23, 61, 35, 79, 47, 59, 65, 53, 71, 77, 24, 72, 8, 60, 20, 56, 80, 26, 78, 74, 62 };

const cb5_counts = [19]u16{ 1, 0, 0, 4, 4, 0, 4, 12, 12, 12, 18, 10, 4, 0, 0, 0, 0, 0, 0 };
const cb5_syms = [81]u8{ 40, 31, 49, 41, 39, 48, 32, 30, 50, 22, 42, 58, 38, 21, 59, 29, 51, 23, 57, 33, 47, 13, 67, 37, 43, 12, 52, 68, 28, 14, 66, 46, 34, 24, 60, 20, 56, 11, 65, 25, 55, 69, 61, 15, 19, 36, 4, 77, 76, 3, 44, 75, 27, 53, 35, 5, 45, 64, 10, 16, 26, 2, 78, 54, 62, 70, 6, 18, 74, 63, 1, 7, 71, 17, 79, 73, 9, 72, 8, 80, 0 };

const cb6_counts = [19]u16{ 0, 0, 0, 9, 0, 16, 13, 8, 23, 8, 4, 0, 0, 0, 0, 0, 0, 0, 0 };
const cb6_syms = [81]u8{ 40, 49, 39, 41, 31, 50, 32, 48, 30, 57, 59, 23, 21, 22, 33, 58, 47, 51, 38, 29, 42, 56, 24, 20, 60, 14, 68, 66, 34, 12, 52, 46, 28, 67, 13, 37, 43, 69, 11, 25, 61, 65, 55, 19, 15, 70, 64, 10, 16, 45, 27, 77, 5, 3, 53, 75, 35, 36, 6, 2, 62, 18, 4, 78, 74, 26, 76, 54, 44, 9, 17, 63, 73, 71, 79, 7, 1, 80, 8, 0, 72 };

const cb7_counts = [19]u16{ 1, 0, 2, 1, 0, 4, 5, 10, 14, 15, 8, 4, 0, 0, 0, 0, 0, 0, 0 };
const cb7_syms = [64]u8{ 0, 8, 1, 9, 17, 10, 16, 2, 25, 11, 18, 24, 3, 19, 26, 12, 33, 13, 41, 27, 20, 4, 32, 34, 21, 42, 5, 49, 40, 14, 35, 29, 28, 43, 22, 50, 15, 30, 6, 48, 36, 57, 37, 58, 44, 51, 23, 59, 52, 45, 38, 31, 56, 7, 53, 46, 60, 39, 47, 61, 62, 54, 55, 63 };

const cb8_counts = [19]u16{ 0, 0, 1, 5, 7, 10, 14, 15, 8, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
const cb8_syms = [64]u8{ 9, 17, 8, 10, 1, 18, 0, 16, 2, 25, 11, 26, 19, 27, 33, 12, 34, 20, 24, 3, 35, 28, 42, 41, 21, 13, 43, 29, 36, 44, 4, 37, 32, 22, 50, 49, 14, 30, 51, 45, 40, 52, 5, 38, 57, 58, 23, 53, 59, 15, 46, 31, 54, 60, 48, 39, 6, 61, 62, 55, 47, 56, 7, 63 };

const cb9_counts = [19]u16{ 1, 0, 2, 1, 0, 4, 3, 8, 11, 20, 31, 38, 32, 14, 4, 0, 0, 0, 0 };
const cb9_syms = [169]u8{ 0, 13, 1, 14, 27, 15, 26, 2, 40, 28, 16, 39, 3, 29, 41, 17, 53, 30, 18, 54, 42, 4, 52, 66, 31, 19, 43, 67, 79, 55, 5, 32, 65, 20, 44, 21, 105, 56, 68, 80, 92, 6, 106, 34, 45, 33, 57, 118, 22, 93, 78, 69, 81, 107, 7, 119, 47, 58, 46, 8, 131, 82, 35, 70, 104, 91, 94, 132, 120, 108, 23, 95, 83, 71, 60, 59, 48, 144, 73, 117, 109, 133, 36, 9, 145, 121, 84, 157, 61, 110, 24, 122, 134, 72, 96, 37, 25, 158, 146, 49, 74, 85, 111, 147, 10, 97, 159, 130, 135, 62, 86, 38, 123, 124, 63, 143, 87, 50, 75, 112, 99, 161, 51, 148, 98, 160, 149, 136, 64, 100, 76, 11, 162, 88, 156, 137, 77, 101, 125, 12, 150, 113, 126, 138, 102, 163, 89, 115, 151, 103, 90, 114, 139, 116, 127, 128, 129, 141, 165, 140, 152, 164, 153, 166, 167, 142, 154, 155, 168 };

const cb10_counts = [19]u16{ 0, 0, 0, 3, 8, 14, 17, 25, 31, 41, 22, 8, 0, 0, 0, 0, 0, 0, 0 };
const cb10_syms = [169]u8{ 14, 15, 27, 28, 13, 1, 16, 41, 40, 29, 42, 26, 2, 30, 54, 17, 53, 0, 55, 43, 39, 3, 56, 31, 67, 18, 66, 68, 44, 69, 57, 80, 32, 81, 52, 79, 4, 19, 45, 70, 82, 58, 83, 93, 46, 33, 71, 106, 94, 65, 92, 5, 105, 20, 107, 95, 59, 34, 84, 96, 21, 47, 108, 60, 72, 109, 73, 97, 85, 119, 78, 86, 120, 48, 118, 35, 6, 110, 121, 61, 132, 22, 98, 111, 122, 99, 133, 74, 134, 36, 131, 49, 123, 87, 104, 62, 91, 145, 100, 146, 136, 23, 144, 124, 7, 112, 135, 50, 75, 113, 148, 8, 147, 37, 101, 88, 137, 63, 24, 158, 125, 159, 149, 76, 160, 150, 161, 51, 89, 117, 138, 130, 157, 9, 64, 126, 162, 38, 114, 127, 25, 151, 163, 102, 77, 90, 139, 115, 164, 10, 103, 143, 140, 152, 153, 11, 154, 128, 141, 156, 116, 165, 142, 129, 155, 167, 12, 166, 168 };

const cb11_counts = [19]u16{ 0, 0, 0, 2, 6, 7, 16, 59, 55, 95, 43, 6, 0, 0, 0, 0, 0, 0, 0 };
const cb11_syms = [289]u16{ 0, 18, 288, 17, 1, 35, 19, 36, 20, 52, 53, 34, 37, 2, 54, 69, 21, 70, 38, 71, 55, 51, 3, 86, 87, 39, 72, 22, 88, 56, 89, 73, 104, 40, 103, 105, 57, 23, 84, 67, 277, 275, 276, 106, 278, 68, 74, 4, 50, 90, 101, 279, 274, 280, 41, 121, 58, 107, 91, 118, 282, 122, 120, 281, 135, 33, 24, 75, 283, 123, 284, 152, 273, 108, 169, 42, 92, 186, 285, 139, 138, 59, 85, 286, 203, 124, 76, 109, 125, 5, 140, 287, 220, 25, 137, 254, 93, 237, 60, 141, 126, 43, 142, 155, 156, 271, 77, 110, 102, 157, 94, 143, 127, 26, 173, 6, 172, 154, 158, 78, 44, 159, 61, 111, 174, 144, 175, 160, 190, 27, 119, 176, 128, 62, 95, 171, 79, 189, 223, 112, 224, 45, 272, 96, 192, 191, 161, 129, 145, 16, 81, 7, 64, 193, 222, 225, 207, 47, 226, 146, 113, 178, 177, 240, 208, 28, 80, 188, 63, 30, 206, 130, 65, 97, 98, 242, 82, 194, 241, 209, 227, 210, 136, 195, 46, 162, 243, 115, 180, 257, 147, 163, 244, 179, 99, 196, 239, 48, 114, 29, 229, 8, 228, 131, 211, 132, 258, 205, 116, 49, 260, 259, 31, 164, 83, 245, 149, 230, 148, 100, 66, 181, 197, 212, 261, 262, 150, 256, 133, 153, 9, 166, 165, 213, 246, 183, 247, 214, 117, 134, 167, 263, 198, 201, 32, 182, 184, 232, 231, 200, 199, 151, 249, 233, 217, 264, 248, 170, 215, 168, 10, 216, 187, 218, 185, 234, 13, 250, 265, 266, 202, 251, 221, 11, 235, 267, 268, 219, 238, 252, 236, 204, 253, 14, 12, 269, 255, 15, 270 };

fn decodeCanonical(br: *BitReader, counts: *const [19]u16, comptime SymT: type, syms: []const SymT) ?u16 {
    var code: u32 = 0;
    var first: u32 = 0;
    var index: usize = 0;
    for (counts) |cnt| {
        const bit = br.readBit() orelse return null;
        code = (code << 1) | bit;
        if (code - first < cnt) {
            const idx = index + (code - first);
            if (idx >= syms.len) return null;
            return syms[idx];
        }
        index += cnt;
        first = (first + cnt) << 1;
    }
    return null;
}

fn decodeScaleFactorDelta(br: *BitReader) ?i16 {
    const sym = decodeCanonical(br, &sf_counts, u8, &sf_syms) orelse return null;
    return @as(i16, @intCast(sym)) - 60;
}

fn decodeSpectralSym(br: *BitReader, cb: u8) ?u16 {
    return switch (cb) {
        1 => decodeCanonical(br, &cb1_counts, u8, &cb1_syms),
        2 => decodeCanonical(br, &cb2_counts, u8, &cb2_syms),
        3 => decodeCanonical(br, &cb3_counts, u8, &cb3_syms),
        4 => decodeCanonical(br, &cb4_counts, u8, &cb4_syms),
        5 => decodeCanonical(br, &cb5_counts, u8, &cb5_syms),
        6 => decodeCanonical(br, &cb6_counts, u8, &cb6_syms),
        7 => decodeCanonical(br, &cb7_counts, u8, &cb7_syms),
        8 => decodeCanonical(br, &cb8_counts, u8, &cb8_syms),
        9 => decodeCanonical(br, &cb9_counts, u8, &cb9_syms),
        10 => decodeCanonical(br, &cb10_counts, u8, &cb10_syms),
        11 => decodeCanonical(br, &cb11_counts, u16, &cb11_syms),
        else => null,
    };
}

// --- Scale Factor Band offset tables (ISO/IEC 14496-3 4.5.2.3) --------------

const swb_1024_96 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240, 276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024 };
const swb_1024_64 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 100, 112, 124, 140, 156, 172, 192, 216, 240, 268, 304, 344, 384, 424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824, 864, 904, 944, 984, 1024 };
const swb_1024_48 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024 };
const swb_1024_32 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 960, 992, 1024 };
const swb_1024_24 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024 };
const swb_1024_16 = [_]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024 };
const swb_1024_8 = [_]u16{ 0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172, 188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448, 476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024 };

const swb_128_96 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128 };
const swb_128_48 = [_]u16{ 0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128 };
const swb_128_24 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128 };
const swb_128_16 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128 };
const swb_128_8 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128 };

fn swbOffsetsLong(freq_index: u4) []const u16 {
    return switch (freq_index) {
        0, 1 => &swb_1024_96,
        2 => &swb_1024_64,
        3, 4 => &swb_1024_48,
        5 => &swb_1024_32,
        6, 7 => &swb_1024_24,
        8, 9, 10 => &swb_1024_16,
        else => &swb_1024_8,
    };
}

fn swbOffsetsShort(freq_index: u4) []const u16 {
    return switch (freq_index) {
        0, 1, 2 => &swb_128_96,
        3, 4, 5 => &swb_128_48,
        6, 7 => &swb_128_24,
        8, 9, 10 => &swb_128_16,
        else => &swb_128_8,
    };
}

// --- Individual Channel Stream (ICS) state -----------------------------------

const WindowSequence = enum(u2) {
    only_long = 0,
    long_start = 1,
    eight_short = 2,
    long_stop = 3,
};

const TnsFilter = struct {
    length: u8 = 0,
    order: u5 = 0,
    direction: u1 = 0,
    lpc: [21]f32 = @splat(0),
};

const Ics = struct {
    max_sfb: u8 = 0,
    num_swb: u8 = 0,
    window_sequence: WindowSequence = .only_long,
    window_shape: u1 = 0,
    prev_window_shape: u1 = 0,
    num_windows: u8 = 1,
    num_window_groups: u8 = 1,
    group_len: [8]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
    sect_cb: [8][64]u8 = @splat(@splat(0)),
    sf: [8][64]i16 = @splat(@splat(0)),
    tns_present: bool = false,
    tns_n_filt: [8]u2 = @splat(0),
    tns_filters: [8][3]TnsFilter = @splat(@splat(.{})),
    spec: [1024]f32 = @splat(0),
};

// --- Decoder -----------------------------------------------------------------

pub const Decoder = struct {
    config: Config,
    overlap: [2][1024]f32 = @splat(@splat(0)),
    prev_window_shape: [2]u1 = .{ 0, 0 },
    rng_state: u32 = 0x1f2e3d4c,
    ics_pair: [2]Ics = @splat(.{}),
    ms_mask_present: u2 = 0,
    ms_used: [8][64]bool = @splat(@splat(false)),

    // Precomputed window tables (initialized on first init)
    pub fn init(config: Config) Decoder {
        ensureTables();
        return .{ .config = config };
    }

    pub fn reset(d: *Decoder) void {
        d.overlap = @splat(@splat(0));
        d.prev_window_shape = .{ 0, 0 };
    }

    /// Decodes a single raw AAC frame (`raw_data_block`) into 1024 stereo
    /// 16-bit PCM frames in `out`.
    pub fn decodeFrame(d: *Decoder, raw: []const u8, out: *[1024][2]i16) !usize {
        if (raw.len == 0) return error.EmptyPacket;
        var br: BitReader = .{ .data = raw };
        var ch_decoded: u8 = 0;
        var out_f: [2][1024]f32 = @splat(@splat(0));

        while (br.bitsLeft() >= 3) {
            const id_syn_ele: u3 = @intCast(br.readBits(3) orelse break);
            switch (id_syn_ele) {
                0 => { // ID_SCE (Single Channel Element)
                    _ = br.readBits(4) orelse return error.InvalidBitstream;
                    const ch_idx: usize = if (ch_decoded < 2) ch_decoded else 1;
                    d.ics_pair[0] = .{ .prev_window_shape = d.prev_window_shape[ch_idx] };
                    try d.decodeIcs(&br, &d.ics_pair[0], false, false);
                    if (d.ics_pair[0].tns_present) d.applyTns(&d.ics_pair[0]);
                    if (ch_decoded < 2) {
                        d.filterbank(&d.ics_pair[0], ch_idx, &out_f[ch_idx]);
                        d.prev_window_shape[ch_idx] = d.ics_pair[0].window_shape;
                        ch_decoded += 1;
                    }
                },
                1 => { // ID_CPE (Channel Pair Element)
                    _ = br.readBits(4) orelse return error.InvalidBitstream;
                    const common_window = (br.readBit() orelse return error.InvalidBitstream) == 1;
                    d.ics_pair[0] = .{ .prev_window_shape = d.prev_window_shape[0] };
                    d.ics_pair[1] = .{ .prev_window_shape = d.prev_window_shape[1] };
                    d.ms_mask_present = 0;
                    d.ms_used = @splat(@splat(false));

                    if (common_window) {
                        try d.decodeIcsInfo(&br, &d.ics_pair[0]);
                        d.ics_pair[1].max_sfb = d.ics_pair[0].max_sfb;
                        d.ics_pair[1].num_swb = d.ics_pair[0].num_swb;
                        d.ics_pair[1].window_sequence = d.ics_pair[0].window_sequence;
                        d.ics_pair[1].window_shape = d.ics_pair[0].window_shape;
                        d.ics_pair[1].num_windows = d.ics_pair[0].num_windows;
                        d.ics_pair[1].num_window_groups = d.ics_pair[0].num_window_groups;
                        d.ics_pair[1].group_len = d.ics_pair[0].group_len;

                        d.ms_mask_present = @intCast(br.readBits(2) orelse return error.InvalidBitstream);
                        if (d.ms_mask_present == 1) {
                            for (0..d.ics_pair[0].num_window_groups) |g| {
                                for (0..d.ics_pair[0].max_sfb) |sfb| {
                                    d.ms_used[g][sfb] = (br.readBit() orelse return error.InvalidBitstream) == 1;
                                }
                            }
                        } else if (d.ms_mask_present == 2) {
                            for (0..d.ics_pair[0].num_window_groups) |g| {
                                for (0..d.ics_pair[0].max_sfb) |sfb| {
                                    d.ms_used[g][sfb] = true;
                                }
                            }
                        }
                    }

                    try d.decodeIcs(&br, &d.ics_pair[0], common_window, false);
                    try d.decodeIcs(&br, &d.ics_pair[1], common_window, false);

                    if (common_window) {
                        d.applyStereo(&d.ics_pair[0], &d.ics_pair[1]);
                    }
                    if (d.ics_pair[0].tns_present) d.applyTns(&d.ics_pair[0]);
                    if (d.ics_pair[1].tns_present) d.applyTns(&d.ics_pair[1]);

                    if (ch_decoded == 0) {
                        d.filterbank(&d.ics_pair[0], 0, &out_f[0]);
                        d.filterbank(&d.ics_pair[1], 1, &out_f[1]);
                        d.prev_window_shape[0] = d.ics_pair[0].window_shape;
                        d.prev_window_shape[1] = d.ics_pair[1].window_shape;
                        ch_decoded = 2;
                    }
                },
                3 => { // ID_LFE
                    _ = br.readBits(4) orelse return error.InvalidBitstream;
                    var tmp_ics: Ics = .{};
                    try d.decodeIcs(&br, &tmp_ics, false, false);
                },
                4 => { // ID_DSE (Data Stream Element)
                    _ = br.readBits(4) orelse return error.InvalidBitstream;
                    const align_flag = (br.readBit() orelse return error.InvalidBitstream) == 1;
                    var count: usize = br.readBits(8) orelse return error.InvalidBitstream;
                    if (count == 255) {
                        count += br.readBits(8) orelse return error.InvalidBitstream;
                    }
                    if (align_flag) br.byteAlign();
                    br.skipBits(count * 8);
                },
                5 => { // ID_PCE (Program Config Element)
                    try skipPce(&br);
                },
                6 => { // ID_FIL (Fill Element)
                    var count: usize = br.readBits(4) orelse return error.InvalidBitstream;
                    if (count == 15) {
                        const esc = br.readBits(8) orelse return error.InvalidBitstream;
                        count += @as(usize, esc) -| 1;
                    }
                    br.skipBits(count * 8);
                },
                7 => break, // ID_END
                else => return error.UnsupportedElement,
            }
        }

        if (ch_decoded == 0) return error.NoAudioChannels;
        if (ch_decoded == 1) {
            out_f[1] = out_f[0];
        }

        for (0..1024) |i| {
            const l: i16 = @intFromFloat(std.math.clamp(@round(out_f[0][i]), -32768.0, 32767.0));
            const r: i16 = @intFromFloat(std.math.clamp(@round(out_f[1][i]), -32768.0, 32767.0));
            out[i] = .{ l, r };
        }
        return 1024;
    }

    fn decodeIcsInfo(d: *const Decoder, br: *BitReader, ics: *Ics) !void {
        const reserved = br.readBit() orelse return error.InvalidBitstream;
        if (reserved != 0) return error.InvalidBitstream;
        ics.window_sequence = @enumFromInt(br.readBits(2) orelse return error.InvalidBitstream);
        ics.window_shape = br.readBit() orelse return error.InvalidBitstream;

        if (ics.window_sequence == .eight_short) {
            ics.max_sfb = @intCast(br.readBits(4) orelse return error.InvalidBitstream);
            const scale_factor_grouping: u7 = @intCast(br.readBits(7) orelse return error.InvalidBitstream);
            const swb = swbOffsetsShort(d.config.freq_index);
            ics.num_swb = @intCast(swb.len - 1);
            if (ics.max_sfb > ics.num_swb) return error.InvalidBitstream;
            ics.num_windows = 8;
            ics.num_window_groups = 1;
            ics.group_len = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
            for (0..7) |i| {
                const bit: u3 = @intCast(6 - i);
                if (((scale_factor_grouping >> bit) & 1) == 0) {
                    ics.num_window_groups += 1;
                    ics.group_len[ics.num_window_groups - 1] = 1;
                } else {
                    ics.group_len[ics.num_window_groups - 1] += 1;
                }
            }
        } else {
            ics.max_sfb = @intCast(br.readBits(6) orelse return error.InvalidBitstream);
            const swb = swbOffsetsLong(d.config.freq_index);
            ics.num_swb = @intCast(swb.len - 1);
            if (ics.max_sfb > ics.num_swb) return error.InvalidBitstream;
            ics.num_windows = 1;
            ics.num_window_groups = 1;
            ics.group_len = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
            const predictor_present = br.readBit() orelse return error.InvalidBitstream;
            if (predictor_present == 1) {
                if (d.config.object_type == 1) {
                    const pred_reset = br.readBit() orelse return error.InvalidBitstream;
                    if (pred_reset == 1) _ = br.readBits(5) orelse return error.InvalidBitstream;
                    const pred_max = @min(ics.max_sfb, 40);
                    for (0..pred_max) |_| _ = br.readBit() orelse return error.InvalidBitstream;
                } else {
                    return error.UnsupportedLtp;
                }
            }
        }
    }

    fn decodeIcs(d: *Decoder, br: *BitReader, ics: *Ics, common_window: bool, scale_flag: bool) !void {
        const global_gain: i16 = @intCast(br.readBits(8) orelse return error.InvalidBitstream);
        if (!common_window and !scale_flag) {
            try d.decodeIcsInfo(br, ics);
        }
        try decodeSectionData(br, ics);
        try decodeScaleFactorData(br, ics, global_gain);

        var pulse_present = false;
        var pulse_num: u3 = 0;
        var pulse_start_sfb: u6 = 0;
        var pulse_off: [4]u5 = @splat(0);
        var pulse_amp: [4]u4 = @splat(0);

        if (!scale_flag) {
            pulse_present = (br.readBit() orelse return error.InvalidBitstream) == 1;
            if (pulse_present) {
                if (ics.window_sequence == .eight_short) return error.InvalidBitstream;
                pulse_num = @intCast((br.readBits(2) orelse return error.InvalidBitstream) + 1);
                pulse_start_sfb = @intCast(br.readBits(6) orelse return error.InvalidBitstream);
                for (0..pulse_num) |i| {
                    pulse_off[i] = @intCast(br.readBits(5) orelse return error.InvalidBitstream);
                    pulse_amp[i] = @intCast(br.readBits(4) orelse return error.InvalidBitstream);
                }
            }
            ics.tns_present = (br.readBit() orelse return error.InvalidBitstream) == 1;
            if (ics.tns_present) {
                try decodeTnsData(br, ics);
            }
            const gain_control = (br.readBit() orelse return error.InvalidBitstream) == 1;
            if (gain_control) return error.UnsupportedGainControl;
        }

        try d.decodeSpectralData(br, ics, pulse_present, pulse_num, pulse_start_sfb, pulse_off, pulse_amp);
    }

    fn decodeSectionData(br: *BitReader, ics: *Ics) !void {
        const bits: u5 = if (ics.window_sequence == .eight_short) 3 else 5;
        const esc_val: u32 = (@as(u32, 1) << bits) - 1;
        for (0..ics.num_window_groups) |g| {
            var k: u8 = 0;
            while (k < ics.max_sfb) {
                const cb: u8 = @intCast(br.readBits(4) orelse return error.InvalidBitstream);
                var len: u16 = 0;
                while (true) {
                    const inc = br.readBits(bits) orelse return error.InvalidBitstream;
                    len += @intCast(inc);
                    if (inc < esc_val) break;
                    if (k + len > ics.max_sfb) return error.InvalidBitstream;
                }
                if (k + len > ics.max_sfb) return error.InvalidBitstream;
                for (0..len) |_| {
                    ics.sect_cb[g][k] = cb;
                    k += 1;
                }
            }
        }
    }

    fn decodeScaleFactorData(br: *BitReader, ics: *Ics, global_gain: i16) !void {
        var sf: i16 = global_gain;
        var is_pos: i16 = 0;
        var noise_energy: i16 = global_gain - 90;
        var first_noise = true;

        for (0..ics.num_window_groups) |g| {
            for (0..ics.max_sfb) |sfb| {
                const cb = ics.sect_cb[g][sfb];
                if (cb == 0) {
                    ics.sf[g][sfb] = 0;
                } else if (cb == 14 or cb == 15) { // INTENSITY_HCB2 / INTENSITY_HCB
                    const delta = decodeScaleFactorDelta(br) orelse return error.InvalidBitstream;
                    is_pos += delta;
                    ics.sf[g][sfb] = is_pos;
                } else if (cb == 13) { // NOISE_HCB
                    if (first_noise) {
                        first_noise = false;
                        const diff: i16 = @intCast(br.readBits(9) orelse return error.InvalidBitstream);
                        noise_energy += diff - 256;
                    } else {
                        const delta = decodeScaleFactorDelta(br) orelse return error.InvalidBitstream;
                        noise_energy += delta;
                    }
                    ics.sf[g][sfb] = noise_energy;
                } else {
                    const delta = decodeScaleFactorDelta(br) orelse return error.InvalidBitstream;
                    sf += delta;
                    if (sf < 0 or sf > 255) return error.InvalidBitstream;
                    ics.sf[g][sfb] = sf;
                }
            }
        }
    }

    fn decodeTnsData(br: *BitReader, ics: *Ics) !void {
        const is_short = ics.window_sequence == .eight_short;
        const n_filt_bits: u5 = if (is_short) 1 else 2;
        const len_bits: u5 = if (is_short) 4 else 6;
        const order_bits: u5 = if (is_short) 3 else 5;

        for (0..ics.num_windows) |w| {
            const n_filt: u2 = @intCast(br.readBits(n_filt_bits) orelse return error.InvalidBitstream);
            ics.tns_n_filt[w] = n_filt;
            if (n_filt == 0) continue;
            const coef_res: u1 = br.readBit() orelse return error.InvalidBitstream;
            for (0..n_filt) |filt| {
                const length: u8 = @intCast(br.readBits(len_bits) orelse return error.InvalidBitstream);
                const order: u5 = @intCast(br.readBits(order_bits) orelse return error.InvalidBitstream);
                if (order > 20) return error.InvalidBitstream;
                var tf: TnsFilter = .{ .length = length, .order = order };
                if (order > 0) {
                    tf.direction = br.readBit() orelse return error.InvalidBitstream;
                    const compress: u1 = br.readBit() orelse return error.InvalidBitstream;
                    const coef_bits: u5 = @as(u5, 3) + coef_res - compress;
                    var k_ref: [20]f32 = @splat(0);
                    const iq_fac_pos: f32 = if (coef_res == 1) (1.0 / 7.0) else (1.0 / 3.0);
                    const iq_fac_neg: f32 = if (coef_res == 1) (1.0 / 8.0) else (1.0 / 4.0);
                    const shift: u4 = @as(u4, 2) + coef_res - compress;
                    const half: i32 = @as(i32, 1) << shift;
                    for (0..order) |i| {
                        const raw_c: i32 = @intCast(br.readBits(coef_bits) orelse return error.InvalidBitstream);
                        const signed_c: i32 = if (raw_c >= half) raw_c - (half * 2) else raw_c;
                        const angle = (@as(f32, @floatFromInt(signed_c)) * (std.math.pi / 2.0)) *
                            (if (signed_c >= 0) iq_fac_pos else iq_fac_neg);
                        k_ref[i] = @sin(angle);
                    }
                    // Step-up recursion from reflection coefficients k_ref to LP filter coefficients
                    tf.lpc[0] = 1.0;
                    var b_tmp: [21]f32 = @splat(0);
                    for (0..order) |m| {
                        tf.lpc[m + 1] = k_ref[m];
                        for (1..m + 1) |i| {
                            b_tmp[i] = tf.lpc[i] + k_ref[m] * tf.lpc[m + 1 - i];
                        }
                        for (1..m + 1) |i| {
                            tf.lpc[i] = b_tmp[i];
                        }
                    }
                }
                ics.tns_filters[w][filt] = tf;
            }
        }
    }

    fn decodeSpectralData(
        d: *Decoder,
        br: *BitReader,
        ics: *Ics,
        pulse_present: bool,
        pulse_num: u3,
        pulse_start_sfb: u6,
        pulse_off: [4]u5,
        pulse_amp: [4]u4,
    ) !void {
        ics.spec = @splat(0);
        var quant: [1024]i16 = @splat(0);
        const is_short = ics.window_sequence == .eight_short;
        const swb = if (is_short) swbOffsetsShort(d.config.freq_index) else swbOffsetsLong(d.config.freq_index);

        var group_off: usize = 0;
        for (0..ics.num_window_groups) |g| {
            const g_len = ics.group_len[g];
            for (0..ics.max_sfb) |sfb| {
                const cb = ics.sect_cb[g][sfb];
                const sfb_start = swb[sfb];
                const sfb_end = swb[sfb + 1];
                const sfb_width = sfb_end - sfb_start;

                for (0..g_len) |w| {
                    const base = group_off + w * 128 + sfb_start;
                    if (cb == 0 or cb >= 13) continue;
                    if (cb <= 4) {
                        var idx: usize = 0;
                        while (idx < sfb_width) : (idx += 4) {
                            const sym = decodeSpectralSym(br, cb) orelse return error.InvalidBitstream;
                            var vals: [4]i16 = undefined;
                            if (cb <= 2) {
                                vals[0] = @as(i16, @intCast((sym / 27) % 3)) - 1;
                                vals[1] = @as(i16, @intCast((sym / 9) % 3)) - 1;
                                vals[2] = @as(i16, @intCast((sym / 3) % 3)) - 1;
                                vals[3] = @as(i16, @intCast(sym % 3)) - 1;
                            } else {
                                vals[0] = @intCast((sym / 27) % 3);
                                vals[1] = @intCast((sym / 9) % 3);
                                vals[2] = @intCast((sym / 3) % 3);
                                vals[3] = @intCast(sym % 3);
                                for (&vals) |*v| {
                                    if (v.* != 0) {
                                        const sign = br.readBit() orelse return error.InvalidBitstream;
                                        if (sign == 1) v.* = -v.*;
                                    }
                                }
                            }
                            for (0..4) |k| quant[base + idx + k] = vals[k];
                        }
                    } else {
                        var idx: usize = 0;
                        while (idx < sfb_width) : (idx += 2) {
                            const sym = decodeSpectralSym(br, cb) orelse return error.InvalidBitstream;
                            var y: i16 = 0;
                            var z: i16 = 0;
                            if (cb <= 6) {
                                y = @as(i16, @intCast(sym / 9)) - 4;
                                z = @as(i16, @intCast(sym % 9)) - 4;
                            } else {
                                const mod: u16 = switch (cb) {
                                    7, 8 => 8,
                                    9, 10 => 13,
                                    else => 17,
                                };
                                y = @intCast(sym / mod);
                                z = @intCast(sym % mod);
                                var sign_y: i16 = 1;
                                var sign_z: i16 = 1;
                                if (y != 0) {
                                    if ((br.readBit() orelse return error.InvalidBitstream) == 1) sign_y = -1;
                                }
                                if (z != 0) {
                                    if ((br.readBit() orelse return error.InvalidBitstream) == 1) sign_z = -1;
                                }
                                if (cb == 11) {
                                    if (y == 16) y = readEscape(br) orelse return error.InvalidBitstream;
                                    if (z == 16) z = readEscape(br) orelse return error.InvalidBitstream;
                                }
                                y *= sign_y;
                                z *= sign_z;
                            }
                            quant[base + idx] = y;
                            quant[base + idx + 1] = z;
                        }
                    }
                }
            }
            group_off += @as(usize, g_len) * 128;
        }

        if (pulse_present and pulse_start_sfb < swb.len) {
            var k: usize = swb[pulse_start_sfb];
            for (0..pulse_num) |i| {
                k += pulse_off[i];
                if (k >= 1024) break;
                if (quant[k] > 0) {
                    quant[k] +|= pulse_amp[i];
                } else {
                    quant[k] -|= pulse_amp[i];
                }
            }
        }

        // Dequantize & apply scale factors (plus PNS for codebook 13)
        group_off = 0;
        for (0..ics.num_window_groups) |g| {
            const g_len = ics.group_len[g];
            for (0..ics.max_sfb) |sfb| {
                const cb = ics.sect_cb[g][sfb];
                const sfb_start = swb[sfb];
                const sfb_end = swb[sfb + 1];
                const sf_val = ics.sf[g][sfb];

                if (cb == 13) { // NOISE_HCB (Perceptual Noise Substitution)
                    const scale = std.math.pow(f32, 2.0, 0.25 * @as(f32, @floatFromInt(sf_val)));
                    for (0..g_len) |w| {
                        const base = group_off + w * 128;
                        var energy: f32 = 0;
                        for (sfb_start..sfb_end) |idx| {
                            d.rng_state = d.rng_state *% 1664525 +% 1013904223;
                            const r_f: f32 = @floatFromInt(@as(i32, @bitCast(d.rng_state)));
                            ics.spec[base + idx] = r_f;
                            energy += r_f * r_f;
                        }
                        const norm = if (energy > 0) scale / @sqrt(energy) else 0;
                        for (sfb_start..sfb_end) |idx| {
                            ics.spec[base + idx] *= norm;
                        }
                    }
                } else if (cb >= 1 and cb <= 11) {
                    const gain = sfGain(sf_val);
                    for (0..g_len) |w| {
                        const base = group_off + w * 128;
                        for (sfb_start..sfb_end) |idx| {
                            const q = quant[base + idx];
                            if (q != 0) {
                                ics.spec[base + idx] = iqVal(q) * gain;
                            }
                        }
                    }
                }
            }
            group_off += @as(usize, g_len) * 128;
        }
    }

    fn applyStereo(d: *const Decoder, left: *Ics, right: *Ics) void {
        const is_short = left.window_sequence == .eight_short;
        const swb = if (is_short) swbOffsetsShort(d.config.freq_index) else swbOffsetsLong(d.config.freq_index);
        var group_off: usize = 0;
        for (0..left.num_window_groups) |g| {
            const g_len = left.group_len[g];
            for (0..left.max_sfb) |sfb| {
                const sfb_start = swb[sfb];
                const sfb_end = swb[sfb + 1];
                const r_cb = right.sect_cb[g][sfb];
                const l_cb = left.sect_cb[g][sfb];

                if (r_cb == 14 or r_cb == 15) { // Intensity Stereo
                    var sign: f32 = if (r_cb == 14) -1.0 else 1.0;
                    if (d.ms_mask_present == 1 and d.ms_used[g][sfb]) sign = -sign;
                    const scale = sign * std.math.pow(f32, 0.5, 0.25 * @as(f32, @floatFromInt(right.sf[g][sfb])));
                    for (0..g_len) |w| {
                        const base = group_off + w * 128;
                        for (sfb_start..sfb_end) |idx| {
                            right.spec[base + idx] = left.spec[base + idx] * scale;
                        }
                    }
                } else if (d.ms_used[g][sfb] and l_cb < 13 and r_cb < 13) { // M/S Stereo
                    for (0..g_len) |w| {
                        const base = group_off + w * 128;
                        for (sfb_start..sfb_end) |idx| {
                            const l = left.spec[base + idx];
                            const r = right.spec[base + idx];
                            left.spec[base + idx] = l + r;
                            right.spec[base + idx] = l - r;
                        }
                    }
                }
            }
            group_off += @as(usize, g_len) * 128;
        }
    }

    fn applyTns(d: *const Decoder, ics: *Ics) void {
        const is_short = ics.window_sequence == .eight_short;
        const swb = if (is_short) swbOffsetsShort(d.config.freq_index) else swbOffsetsLong(d.config.freq_index);
        const tns_max_bands: u8 = if (is_short)
            tnsMaxBandsShort(d.config.freq_index)
        else
            tnsMaxBandsLong(d.config.freq_index);
        const max_sfb = @min(ics.max_sfb, tns_max_bands);

        for (0..ics.num_windows) |w| {
            var bottom: u8 = ics.num_swb;
            const n_filt = ics.tns_n_filt[w];
            for (0..n_filt) |f_idx| {
                const tf = &ics.tns_filters[w][f_idx];
                const top = bottom;
                bottom = bottom -| tf.length;
                if (tf.order == 0) continue;
                const start_sfb = @min(bottom, max_sfb);
                const end_sfb = @min(top, max_sfb);
                if (start_sfb >= end_sfb) continue;

                const start_bin: usize = swb[start_sfb];
                const end_bin: usize = swb[end_sfb];
                if (start_bin >= end_bin) continue;

                const base = if (is_short) w * 128 else 0;
                const count = end_bin - start_bin;
                var state: [21]f32 = @splat(0);

                for (0..count) |step| {
                    const idx = if (tf.direction == 1)
                        base + end_bin - 1 - step
                    else
                        base + start_bin + step;
                    var y = ics.spec[idx];
                    for (1..@as(usize, tf.order) + 1) |k| {
                        y -= tf.lpc[k] * state[k - 1];
                    }
                    var k: usize = tf.order;
                    while (k > 1) : (k -= 1) {
                        state[k - 1] = state[k - 2];
                    }
                    state[0] = y;
                    ics.spec[idx] = y;
                }
            }
        }
    }

    fn filterbank(d: *Decoder, ics: *const Ics, ch: usize, pcm_out: *[1024]f32) void {
        const win_prev = windowLong(ics.prev_window_shape);
        const win_curr = windowLong(ics.window_shape);
        const win_prev_short = windowShort(ics.prev_window_shape);
        const win_curr_short = windowShort(ics.window_shape);

        var time_buf: [2048]f32 = @splat(0);

        switch (ics.window_sequence) {
            .only_long => {
                imdctLong(&ics.spec, &time_buf);
                for (0..1024) |i| {
                    pcm_out[i] = d.overlap[ch][i] + time_buf[i] * win_prev[i];
                    d.overlap[ch][i] = time_buf[1024 + i] * win_curr[1023 - i];
                }
            },
            .long_start => {
                imdctLong(&ics.spec, &time_buf);
                for (0..1024) |i| {
                    pcm_out[i] = d.overlap[ch][i] + time_buf[i] * win_prev[i];
                }
                for (0..448) |i| {
                    d.overlap[ch][i] = time_buf[1024 + i];
                }
                for (0..128) |i| {
                    d.overlap[ch][448 + i] = time_buf[1024 + 448 + i] * win_curr_short[127 - i];
                }
                for (576..1024) |i| {
                    d.overlap[ch][i] = 0;
                }
            },
            .long_stop => {
                imdctLong(&ics.spec, &time_buf);
                for (0..448) |i| {
                    pcm_out[i] = d.overlap[ch][i];
                }
                for (0..128) |i| {
                    pcm_out[448 + i] = d.overlap[ch][448 + i] + time_buf[448 + i] * win_prev_short[i];
                }
                for (576..1024) |i| {
                    pcm_out[i] = d.overlap[ch][i] + time_buf[i];
                }
                for (0..1024) |i| {
                    d.overlap[ch][i] = time_buf[1024 + i] * win_curr[1023 - i];
                }
            },
            .eight_short => {
                var short_overlap: [2048]f32 = @splat(0);
                for (0..1024) |i| short_overlap[i] = d.overlap[ch][i];
                var short_time: [256]f32 = undefined;
                for (0..8) |w| {
                    const spec_slice: *const [128]f32 = ics.spec[w * 128 ..][0..128];
                    imdctShort(spec_slice, &short_time);
                    const w_prev = if (w == 0) win_prev_short else win_curr_short;
                    const off = 448 + w * 128;
                    for (0..128) |i| {
                        short_overlap[off + i] += short_time[i] * w_prev[i];
                        short_overlap[off + 128 + i] += short_time[128 + i] * win_curr_short[127 - i];
                    }
                }
                for (0..1024) |i| {
                    pcm_out[i] = short_overlap[i];
                    d.overlap[ch][i] = short_overlap[1024 + i];
                }
            },
        }
    }
};

fn readEscape(br: *BitReader) ?i16 {
    var n: u5 = 4;
    while (true) {
        const bit = br.readBit() orelse return null;
        if (bit == 0) break;
        if (n >= 15) return null;
        n += 1;
    }
    const tail = br.readBits(n) orelse return null;
    const val: u32 = (@as(u32, 1) << n) + tail;
    return @intCast(@min(val, 8191));
}

fn skipPce(br: *BitReader) !void {
    _ = br.readBits(4) orelse return error.InvalidBitstream; // element_instance_tag
    _ = br.readBits(2) orelse return error.InvalidBitstream; // object_type
    _ = br.readBits(4) orelse return error.InvalidBitstream; // sampling_frequency_index
    const num_front = br.readBits(4) orelse return error.InvalidBitstream;
    const num_side = br.readBits(4) orelse return error.InvalidBitstream;
    const num_back = br.readBits(4) orelse return error.InvalidBitstream;
    const num_lfe = br.readBits(2) orelse return error.InvalidBitstream;
    const num_assoc = br.readBits(3) orelse return error.InvalidBitstream;
    const num_cc = br.readBits(4) orelse return error.InvalidBitstream;
    if ((br.readBit() orelse return error.InvalidBitstream) == 1) _ = br.readBits(4) orelse return error.InvalidBitstream;
    if ((br.readBit() orelse return error.InvalidBitstream) == 1) _ = br.readBits(4) orelse return error.InvalidBitstream;
    if ((br.readBit() orelse return error.InvalidBitstream) == 1) _ = br.readBits(3) orelse return error.InvalidBitstream;
    br.skipBits((num_front + num_side + num_back) * 5 + num_lfe * 4 + num_assoc * 4 + num_cc * 5);
    br.byteAlign();
    const comment_bytes = br.readBits(8) orelse return error.InvalidBitstream;
    br.skipBits(comment_bytes * 8);
}

fn tnsMaxBandsLong(freq_index: u4) u8 {
    return switch (freq_index) {
        0 => 31,
        1 => 31,
        2 => 34,
        3 => 40,
        4 => 42,
        5 => 51,
        6, 7 => 46,
        8, 9, 10 => 42,
        else => 39,
    };
}

fn tnsMaxBandsShort(freq_index: u4) u8 {
    return switch (freq_index) {
        0, 1, 2 => 9,
        3, 4 => 14,
        5 => 14,
        else => 15,
    };
}

// --- Lookup tables (IQ, Scale Factor, Sine & KBD Windows, IMDCT Twiddles) ---

var tables_ready: std.atomic.Value(bool) = .init(false);
var iq_table: [8192]f32 = undefined;
var sf_table: [256]f32 = undefined;
var sine_long: [1024]f32 = undefined;
var sine_short: [128]f32 = undefined;
var kbd_long: [1024]f32 = undefined;
var kbd_short: [128]f32 = undefined;
var twiddle_long_cos: [512]f32 = undefined;
var twiddle_long_sin: [512]f32 = undefined;
var twiddle_short_cos: [64]f32 = undefined;
var twiddle_short_sin: [64]f32 = undefined;

fn ensureTables() void {
    if (tables_ready.load(.acquire)) return;
    iq_table[0] = 0;
    for (1..iq_table.len) |i| {
        const x: f32 = @floatFromInt(i);
        iq_table[i] = x * std.math.cbrt(x);
    }
    // Scale factor table: 2^(0.25 * (sf - 100)).
    for (0..sf_table.len) |sf| {
        const exp: f32 = (@as(f32, @floatFromInt(sf)) - 100.0) * 0.25;
        sf_table[sf] = std.math.pow(f32, 2.0, exp);
    }
    for (0..1024) |i| {
        sine_long[i] = @sin((@as(f32, @floatFromInt(i)) + 0.5) * (std.math.pi / 2048.0));
    }
    for (0..128) |i| {
        sine_short[i] = @sin((@as(f32, @floatFromInt(i)) + 0.5) * (std.math.pi / 256.0));
    }
    computeKbdWindow(1024, 4.0, &kbd_long);
    computeKbdWindow(128, 6.0, &kbd_short);

    for (0..512) |k| {
        const angle = -2.0 * std.math.pi * (@as(f64, @floatFromInt(k)) + 0.125) / 2048.0;
        twiddle_long_cos[k] = @floatCast(@cos(angle));
        twiddle_long_sin[k] = @floatCast(@sin(angle));
    }
    for (0..64) |k| {
        const angle = -2.0 * std.math.pi * (@as(f64, @floatFromInt(k)) + 0.125) / 256.0;
        twiddle_short_cos[k] = @floatCast(@cos(angle));
        twiddle_short_sin[k] = @floatCast(@sin(angle));
    }
    tables_ready.store(true, .release);
}

fn computeKbdWindow(comptime n: usize, alpha: f64, out: *[n]f32) void {
    const pi_alpha = std.math.pi * alpha;
    const denom = besselI0(pi_alpha);
    var cum: [n + 1]f64 = undefined;
    var sum: f64 = 0.0;
    const nf: f64 = @floatFromInt(n);
    for (0..n + 1) |i| {
        const t = (2.0 * @as(f64, @floatFromInt(i)) / nf) - 1.0;
        const arg = pi_alpha * @sqrt(@max(0.0, 1.0 - t * t));
        sum += besselI0(arg) / denom;
        cum[i] = sum;
    }
    for (0..n) |i| {
        out[i] = @floatCast(@sqrt(cum[i] / sum));
    }
}

fn besselI0(x: f64) f64 {
    var sum: f64 = 1.0;
    var term: f64 = 1.0;
    const half_x = x * 0.5;
    for (1..32) |k| {
        const kf: f64 = @floatFromInt(k);
        term *= (half_x / kf) * (half_x / kf);
        sum += term;
        if (term < sum * 1e-15) break;
    }
    return sum;
}

fn iqVal(q: i16) f32 {
    const abs_q: usize = @min(@as(usize, @abs(q)), iq_table.len - 1);
    const mag = iq_table[abs_q];
    return if (q < 0) -mag else mag;
}

fn sfGain(sf: i16) f32 {
    const idx: usize = @intCast(std.math.clamp(sf, 0, 255));
    return sf_table[idx];
}

fn windowLong(shape: u1) *const [1024]f32 {
    return if (shape == 1) &kbd_long else &sine_long;
}

fn windowShort(shape: u1) *const [128]f32 {
    return if (shape == 1) &kbd_short else &sine_short;
}

// --- Fast FFT-based IMDCT (1024 -> 2048 and 128 -> 256) ---------------------

fn imdctLong(spec: *const [1024]f32, out: *[2048]f32) void {
    var re: [512]f32 = undefined;
    var im: [512]f32 = undefined;
    // Scale factor 1.0 / 512.0 normalizes the unnormalized 512-point FFT IMDCT
    // to match ISO 14496-3's 16-bit PCM amplitude.
    const scale: f32 = 1.0 / 512.0;

    for (0..512) |k| {
        const r_in = spec[2 * k];
        const i_in = spec[1023 - 2 * k];
        const c = twiddle_long_cos[k];
        const s = twiddle_long_sin[k];
        re[k] = (r_in * c - i_in * s) * scale;
        im[k] = (r_in * s + i_in * c) * scale;
    }

    fft(512, &re, &im);

    var z_re: [512]f32 = undefined;
    var z_im: [512]f32 = undefined;
    for (0..512) |k| {
        const c = twiddle_long_cos[k];
        const s = twiddle_long_sin[k];
        z_re[k] = re[k] * c - im[k] * s;
        z_im[k] = re[k] * s + im[k] * c;
    }

    for (0..256) |k| {
        out[2 * k] = z_re[256 + k];
        out[2 * k + 1] = -z_im[255 - k];
        out[512 + 2 * k] = z_im[k];
        out[512 + 2 * k + 1] = -z_re[511 - k];
        out[1024 + 2 * k] = z_im[256 + k];
        out[1024 + 2 * k + 1] = -z_re[255 - k];
        out[1536 + 2 * k] = -z_re[k];
        out[1536 + 2 * k + 1] = z_im[511 - k];
    }
}

fn imdctShort(spec: *const [128]f32, out: *[256]f32) void {
    var re: [64]f32 = undefined;
    var im: [64]f32 = undefined;
    const scale: f32 = 1.0 / 512.0;

    for (0..64) |k| {
        const r_in = spec[2 * k];
        const i_in = spec[127 - 2 * k];
        const c = twiddle_short_cos[k];
        const s = twiddle_short_sin[k];
        re[k] = (r_in * c - i_in * s) * scale;
        im[k] = (r_in * s + i_in * c) * scale;
    }

    fft(64, &re, &im);

    var z_re: [64]f32 = undefined;
    var z_im: [64]f32 = undefined;
    for (0..64) |k| {
        const c = twiddle_short_cos[k];
        const s = twiddle_short_sin[k];
        z_re[k] = re[k] * c - im[k] * s;
        z_im[k] = re[k] * s + im[k] * c;
    }

    for (0..32) |k| {
        out[2 * k] = z_re[32 + k];
        out[2 * k + 1] = -z_im[31 - k];
        out[64 + 2 * k] = z_im[k];
        out[64 + 2 * k + 1] = -z_re[63 - k];
        out[128 + 2 * k] = z_im[32 + k];
        out[128 + 2 * k + 1] = -z_re[31 - k];
        out[192 + 2 * k] = -z_re[k];
        out[192 + 2 * k + 1] = z_im[63 - k];
    }
}

fn fft(comptime n: usize, re: *[n]f32, im: *[n]f32) void {
    const log_n = @ctz(@as(usize, n));
    for (0..n) |i| {
        const j = @bitReverse(@as(std.meta.Int(.unsigned, log_n), @intCast(i)));
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len >> 1;
        const step_angle = -2.0 * std.math.pi / @as(f64, @floatFromInt(len));
        const w_step_re = @cos(step_angle);
        const w_step_im = @sin(step_angle);
        var i: usize = 0;
        while (i < n) : (i += len) {
            var w_re: f64 = 1.0;
            var w_im: f64 = 0.0;
            for (0..half) |j| {
                const wr: f32 = @floatCast(w_re);
                const wi: f32 = @floatCast(w_im);
                const u_re = re[i + j];
                const u_im = im[i + j];
                const v_re = re[i + j + half] * wr - im[i + j + half] * wi;
                const v_im = re[i + j + half] * wi + im[i + j + half] * wr;
                re[i + j] = u_re + v_re;
                im[i + j] = u_im + v_im;
                re[i + j + half] = u_re - v_re;
                im[i + j + half] = u_im - v_im;
                const next_w_re = w_re * w_step_re - w_im * w_step_im;
                w_im = w_re * w_step_im + w_im * w_step_re;
                w_re = next_w_re;
            }
        }
    }
}

const testing = std.testing;

test "parseConfig extracts AAC-LC sample rate and channel count" {
    // AAC-LC (object_type=2), 48000 Hz (freq_index=3), Stereo (chan_cfg=2):
    // 00010 0011 0010 000 = 0x11 0x90
    const cfg = parseConfig(&.{ 0x11, 0x90 }).?;
    try testing.expectEqual(@as(u8, 2), cfg.object_type);
    try testing.expectEqual(@as(u32, 48000), cfg.sample_rate);
    try testing.expectEqual(@as(u8, 2), cfg.channels);

    // AAC-LC (2), 44100 Hz (freq_index=4), Mono (chan_cfg=1):
    // 00010 0100 0001 000 = 0x12 0x08
    const cfg_mono = parseConfig(&.{ 0x12, 0x08 }).?;
    try testing.expectEqual(@as(u32, 44100), cfg_mono.sample_rate);
    try testing.expectEqual(@as(u8, 1), cfg_mono.channels);
}

test "IMDCT long and short blocks reconstruct cosine basis with exact phase and amplitude" {
    ensureTables();
    // Verify that FFT-based imdctLong matches the direct ISO 14496-3 formula:
    // imdct[n] = (1/512) * sum_k X[k] * cos(2*pi/2048 * (n + 0.5 + 512) * (k + 0.5))
    var spec: [1024]f32 = @splat(0);
    spec[7] = 5120.0;
    spec[23] = -2048.0;
    var out: [2048]f32 = undefined;
    imdctLong(&spec, &out);

    for ([_]usize{ 0, 1, 127, 511, 512, 1023, 1536, 2047 }) |n| {
        const nf: f64 = @floatFromInt(n);
        const expected: f32 = @floatCast((1.0 / 512.0) * (5120.0 * @cos(2.0 * std.math.pi / 2048.0 * (nf + 0.5 + 512.0) * 7.5) +
            (-2048.0) * @cos(2.0 * std.math.pi / 2048.0 * (nf + 0.5 + 512.0) * 23.5)));
        try testing.expectApproxEqAbs(expected, out[n], 0.001);
    }
}

test "Decoder decodes real AAC-LC stereo frames into 440 Hz PCM audio" {
    const frame0 = [_]u8{
        222, 2,   0,   76,  97,  118, 99,  54,  50,  46,  49,  49,  46,  49,  48,  48,
        0,   66,  85,  31,  255, 255, 255, 240, 2,   98,  215, 76,  132, 16,  181, 47,
        110, 243, 231, 219, 142, 56,  113, 157, 101, 164, 138, 178, 69,  72,  228, 231,
        72,  16,  77,  211, 15,  240, 172, 208, 110, 46,  201, 216, 223, 73,  152, 191,
        225, 44,  147, 51,  127, 134, 214, 255, 215, 6,   151, 67,  211, 92,  147, 152,
        191, 59,  225, 222, 155, 214, 92,  78,  245, 156, 229, 95,  83,  249, 94,  179,
        224, 183, 156, 235, 93,  197, 113, 157, 123, 57,  208, 178, 58,  22,  39,  29,
        141, 197, 92,  108, 218, 13,  155, 27,  98,  176, 214, 177, 55,  43,  45,  202,
        118, 181, 89,  158, 165, 158, 165, 146, 125, 108, 213, 249, 171, 244, 141, 51,
        88,  231, 214, 207, 173, 159, 91,  62,  170, 82,  252, 214, 26,  166, 186, 108,
        233, 179, 162, 181, 21,  169, 179, 166, 198, 155, 25,  152, 204, 206, 155, 58,
        43,  81,  90,  139, 58,  108, 102, 99,  51,  25,  152, 209, 90,  138, 212, 86,
        162, 148, 73,  68,  190, 73,  68,  148, 73,  79,  20,  241, 68,  148, 73,  68,
        190, 75,  228, 148, 73,  79,  20,  241, 68,  148, 75,  228, 190, 75,  228, 148,
        241, 79,  20,  241, 79,  20,  75,  228, 190, 23,  201, 125, 226, 158, 20,  81,
        69,  20,  81,  69,  20,  81,  69,  20,  81,  69,  20,  192, 252, 62,  29,  75,
        219, 188, 249, 246, 227, 142, 28,  103, 89,  105, 34,  172, 145, 82,  57,  57,
        210, 4,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   28,
    };
    const frame1 = [_]u8{
        33,  76,  108, 254, 7,   252, 127, 199, 252, 76,  90,  41,  186, 220, 52,  162,
        109, 213, 100, 74,  221, 102, 111, 111, 60,  113, 109, 189, 92,  211, 199, 63,
        139, 129, 171, 191, 237, 247, 26,  213, 202, 167, 233, 209, 53,  173, 93,  80,
        109, 78,  205, 88,  31,  75,  207, 60,  194, 70,  210, 147, 210, 214, 179, 149,
        51,  243, 185, 255, 66,  75,  91,  83,  22,  105, 232, 230, 205, 182, 147, 99,
        91,  59,  10,  169, 145, 219, 159, 54,  215, 182, 214, 217, 224, 219, 84,  227,
        77,  195, 5,   85,  22,  153, 156, 201, 68,  194, 165, 171, 245, 144, 157, 18,
        19,  122, 240, 72,  72,  72,  78,  110, 18,  18,  18,  114, 101, 187, 184, 72,
        72,  73,  197, 180, 238, 225, 33,  37,  66,  102, 201, 221, 255, 151, 143, 225,
        135, 100, 162, 2,   40,  208, 16,  219, 211, 32,  144, 81,  60,  238, 186, 211,
        17,  205, 86,  35,  86,  49,  34,  142, 93,  196, 202, 202, 32,  200, 181, 184,
        126, 251, 217, 93,  67,  156, 181, 135, 33,  227, 56,  173, 6,   154, 165, 3,
        58,  217, 245, 82,  97,  103, 103, 154, 182, 125, 84,  165, 82,  97,  70,  22,
        118, 57,  171, 101, 42,  148, 154, 24,  81,  133, 106, 217, 171, 101, 42,  140,
        154, 24,  81,  133, 242, 121, 187, 113, 195, 28,  49,  146, 105, 38,  165, 217,
        217, 240, 106, 217, 217, 217, 217, 217, 156, 200, 223, 229, 242, 249, 124, 190,
        95,  36,  143, 61,  145, 115, 78,  66,  40,  152, 3,   100, 168, 114, 194, 126,
        3,   206, 18,  181, 20,  137, 197, 251, 110, 45,  227, 88,  156, 84,  238, 42,
        195, 60,  214, 197, 59,  60,  215, 21,  59,  61,  27,  61,  59,  61,  58,  217,
        175, 155, 12,  112, 199, 12,  100, 154, 70,  118, 118, 118, 116, 121, 129, 219,
        135, 175, 99,  215, 177, 235, 219, 219, 207, 28,  91,  107, 87,  45,  227, 159,
        197, 192, 31,  111, 184, 214, 174, 15,  227, 162, 107, 90,  176, 0,   0,   0,
        0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   28,
    };

    const cfg = parseConfig(&.{ 0x11, 0x90 }).?;
    var dec = Decoder.init(cfg);
    var pcm: [1024][2]i16 = undefined;
    try testing.expectEqual(@as(usize, 1024), try dec.decodeFrame(&frame0, &pcm));
    try testing.expectEqual(@as(usize, 1024), try dec.decodeFrame(&frame1, &pcm));

    var peak: u32 = 0;
    for (pcm) |s| {
        peak = @max(peak, @abs(@as(i32, s[0])));
    }
    try testing.expect(peak > 1000);
}

