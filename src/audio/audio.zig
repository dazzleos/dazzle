//! Audio output enumeration, sound settings, and streaming `.wav` playback.
//!
//! Sound settings (volume 0–100%, mute, and chosen output card ID) are stored
//! in `/data/apps/.sound` so both Settings and unprivileged apps (`dazzle-files`)
//! can read and update them directly.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const wav = @import("wav.zig");
pub const alsa = @import("alsa.zig");
pub const aac = @import("aac.zig");

pub const settings_file = sys.system.apps_dir ++ "/.sound";
pub const max_devices = 8;

pub const Kind = enum {
    headphones,
    hdmi,
    usb,
    speaker,
};

pub const Device = struct {
    card: u8 = 0,
    pcm_device: u8 = 0,
    id_buf: [16]u8 = @splat(0),
    id_len: u8 = 0,
    name_buf: [48]u8 = @splat(0),
    name_len: u8 = 0,
    kind: Kind = .speaker,

    pub fn id(d: *const Device) []const u8 {
        return d.id_buf[0..d.id_len];
    }

    pub fn name(d: *const Device) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    pub fn init(card: u8, pcm_device: u8, card_id: []const u8, label: []const u8, kind: Kind) Device {
        var d: Device = .{ .card = card, .pcm_device = pcm_device, .kind = kind };
        d.id_len = @intCast(@min(card_id.len, d.id_buf.len));
        @memcpy(d.id_buf[0..d.id_len], card_id[0..d.id_len]);
        d.name_len = @intCast(@min(label.len, d.name_buf.len));
        @memcpy(d.name_buf[0..d.name_len], label[0..d.name_len]);
        return d;
    }
};

pub const Devices = struct {
    items: [max_devices]Device = @splat(.{}),
    len: u8 = 0,

    pub fn slice(d: *const Devices) []const Device {
        return d.items[0..d.len];
    }
};

/// Classifies an ALSA card's raw identifiers into a user-facing `Kind` and
/// label.
pub fn classifyCard(card_id: []const u8, driver: []const u8, raw_name: []const u8, longname: []const u8, out_buf: *[48]u8) struct { kind: Kind, label: []const u8 } {
    if (containsIgnoreCase(card_id, "Headphones") or
        containsIgnoreCase(raw_name, "Headphones") or
        (containsIgnoreCase(driver, "bcm2835") and !containsIgnoreCase(raw_name, "HDMI")))
    {
        return .{ .kind = .headphones, .label = copyLabel(out_buf, "Headphones") };
    }
    if (containsIgnoreCase(card_id, "vc4hdmi") or
        containsIgnoreCase(driver, "vc4-hdmi") or
        containsIgnoreCase(raw_name, "vc4-hdmi") or
        containsIgnoreCase(raw_name, "HDMI"))
    {
        if (std.mem.endsWith(u8, card_id, "0") or std.mem.endsWith(u8, raw_name, "-0") or std.mem.endsWith(u8, raw_name, " 1")) {
            return .{ .kind = .hdmi, .label = copyLabel(out_buf, "HDMI 1") };
        }
        if (std.mem.endsWith(u8, card_id, "1") or std.mem.endsWith(u8, raw_name, "-1") or std.mem.endsWith(u8, raw_name, " 2")) {
            return .{ .kind = .hdmi, .label = copyLabel(out_buf, "HDMI 2") };
        }
        return .{ .kind = .hdmi, .label = copyLabel(out_buf, "HDMI") };
    }
    if (containsIgnoreCase(driver, "USB") or containsIgnoreCase(longname, "USB")) {
        const clean = if (raw_name.len > 0) raw_name else "USB Audio";
        return .{ .kind = .usb, .label = copyLabel(out_buf, clean) };
    }
    const fallback = if (raw_name.len > 0) raw_name else if (card_id.len > 0) card_id else "Audio Output";
    return .{ .kind = .speaker, .label = copyLabel(out_buf, fallback) };
}

fn copyLabel(out: *[48]u8, s: []const u8) []const u8 {
    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
    return out[0..n];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Enumerates all ALSA playback devices currently present under `/dev/snd`.
pub fn listDevices() Devices {
    var list: Devices = .{};
    for (0..8) |card_usize| {
        if (list.len >= max_devices) break;
        const card: u8 = @intCast(card_usize);
        var ctl_path_buf: [32]u8 = undefined;
        const ctl_path = std.fmt.bufPrintZ(&ctl_path_buf, "/dev/snd/controlC{d}", .{card}) catch continue;
        const ctl_fd = sys.open(ctl_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch continue;
        defer sys.close(ctl_fd);

        var card_info: alsa.SndCtlCardInfo = .{};
        if (linux.errno(linux.ioctl(ctl_fd, alsa.SNDRV_CTL_IOCTL_CARD_INFO, @intFromPtr(&card_info))) != .SUCCESS) continue;

        const pcm_dev = findPlaybackDevice(ctl_fd, card) orelse continue;
        const card_id = alsa.cStr(&card_info.id);
        const driver = alsa.cStr(&card_info.driver);
        const raw_name = alsa.cStr(&card_info.name);
        const longname = alsa.cStr(&card_info.longname);

        var label_buf: [48]u8 = undefined;
        const classified = classifyCard(card_id, driver, raw_name, longname, &label_buf);
        list.items[list.len] = Device.init(card, pcm_dev, card_id, classified.label, classified.kind);
        list.len += 1;
    }
    return list;
}

fn findPlaybackDevice(ctl_fd: linux.fd_t, card: u8) ?u8 {
    var dev: c_int = -1;
    while (linux.errno(linux.ioctl(ctl_fd, alsa.SNDRV_CTL_IOCTL_PCM_NEXT_DEVICE, @intFromPtr(&dev))) == .SUCCESS) {
        if (dev < 0 or dev >= 8) break;
        var pcm_info: alsa.SndPcmInfo = .{
            .device = @intCast(dev),
            .subdevice = 0,
            .stream = alsa.SNDRV_PCM_STREAM_PLAYBACK,
        };
        if (linux.errno(linux.ioctl(ctl_fd, alsa.SNDRV_CTL_IOCTL_PCM_INFO, @intFromPtr(&pcm_info))) == .SUCCESS) {
            return @intCast(dev);
        }
    }
    // Fallback: check whether /dev/snd/pcmC<card>D0p exists.
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/dev/snd/pcmC{d}D0p", .{card}) catch return null;
    if (linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS) return 0;
    return null;
}

// --- Persistent Sound Settings -----------------------------------------------

pub const Settings = struct {
    volume: u8 = 80,
    muted: bool = false,
    output_buf: [16]u8 = @splat(0),
    output_len: u8 = 0,

    pub fn output(s: *const Settings) []const u8 {
        return s.output_buf[0..s.output_len];
    }

    pub fn setOutput(s: *Settings, card_id: []const u8) void {
        s.output_len = @intCast(@min(card_id.len, s.output_buf.len));
        @memcpy(s.output_buf[0..s.output_len], card_id[0..s.output_len]);
    }

    pub fn eql(a: *const Settings, b: *const Settings) bool {
        return a.volume == b.volume and a.muted == b.muted and std.mem.eql(u8, a.output(), b.output());
    }

    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = tok.next() orelse continue;
            const val = tok.next() orelse continue;
            if (std.mem.eql(u8, key, "volume")) {
                if (std.fmt.parseInt(u8, val, 10)) |v| s.volume = @min(v, 100) else |_| {}
            } else if (std.mem.eql(u8, key, "muted")) {
                s.muted = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            } else if (std.mem.eql(u8, key, "output")) {
                s.setOutput(val);
            }
        }
        return s;
    }

    pub fn formatBuf(s: *const Settings, buf: []u8) []const u8 {
        const muted_int: u8 = if (s.muted) 1 else 0;
        if (s.output_len > 0) {
            return std.fmt.bufPrint(buf, "volume {d}\nmuted {d}\noutput {s}\n", .{ @min(s.volume, 100), muted_int, s.output() }) catch "";
        }
        return std.fmt.bufPrint(buf, "volume {d}\nmuted {d}\n", .{ @min(s.volume, 100), muted_int }) catch "";
    }
};

pub fn loadSettings() Settings {
    return loadSettingsFrom(settings_file);
}

pub fn loadSettingsFrom(path: [:0]const u8) Settings {
    var buf: [128]u8 = undefined;
    const text = sys.readFile(path, &buf) orelse return .{};
    return Settings.parse(text);
}

pub fn saveSettings(s: Settings) void {
    _ = linux.mkdir(sys.system.apps_dir, 0o755);
    saveSettingsTo(settings_file, s);
}

pub fn saveSettingsTo(path: [:0]const u8, s: Settings) void {
    var buf: [128]u8 = undefined;
    const content = s.formatBuf(&buf);
    if (content.len == 0) return;
    _ = linux.unlink(path);
    sys.files.writeNew(path, content) catch {};
}

/// Resolves which `Device` in `devices` should be used for `settings`.
/// Prefers an exact match on `settings.output()`, then USB audio, then
/// headphones, then HDMI/first available device.
pub fn activeDevice(devices: *const Devices, settings: *const Settings) ?Device {
    const items = devices.slice();
    if (items.len == 0) return null;
    const wanted = settings.output();
    if (wanted.len > 0) {
        for (items) |d| {
            if (std.mem.eql(u8, d.id(), wanted)) return d;
        }
    }
    for (items) |d| if (d.kind == .usb) return d;
    for (items) |d| if (d.kind == .headphones) return d;
    return items[0];
}

/// Applies `settings` to all detected ALSA cards' hardware mixers.
pub fn applySettings(settings: Settings, devices: *const Devices) void {
    for (devices.slice()) |d| {
        _ = alsa.setCardVolume(d.card, settings.volume, settings.muted);
    }
}

/// Opens the active ALSA playback device for `settings` at `preferred_rate`
/// and applies hardware mixer volume/mute.
pub fn openOutput(preferred_rate: u32, settings: Settings) ?alsa.PcmOutput {
    const devs = listDevices();
    const dev = activeDevice(&devs, &settings) orelse return null;
    const hw_vol = alsa.setCardVolume(dev.card, settings.volume, settings.muted);
    if (alsa.PcmOutput.open(dev.card, dev.pcm_device, preferred_rate)) |out| {
        var pcm = out;
        pcm.hw_volume = hw_vol;
        return pcm;
    }
    return null;
}

// --- Streaming WAV & Test Tone Player ----------------------------------------

pub const Player = struct {
    fd: linux.fd_t = -1,
    owns_fd: bool = false,
    mem_bytes: ?[]const u8 = null,
    tone_Active: bool = false,
    header: wav.Header,
    playing: bool = true,
    ended: bool = false,
    /// Current playback frame position (`0..header.totalFrames()`).
    current_frame: u64 = 0,
    /// Highest source frame already written to the ALSA hardware buffer.
    fed_frame: u64 = 0,
    /// Monotonic timestamp (ns) corresponding to frame 0 of the current play run.
    start_ns: i128 = 0,
    pcm: ?alsa.PcmOutput = null,
    settings: Settings = .{},
    resample_frac: u32 = 0,

    /// Opens a `.wav` file descriptor for streaming playback.
    pub fn open(fd: linux.fd_t) ?Player {
        var hdr_buf: [4096]u8 = undefined;
        const n = sys.check(linux.pread(fd, &hdr_buf, hdr_buf.len, 0)) catch return null;
        if (n < 44) return null;
        const header = wav.parseHeader(hdr_buf[0..n]) orelse return null;
        if (header.totalFrames() == 0) return null;

        var p: Player = .{
            .fd = fd,
            .header = header,
            .settings = loadSettings(),
        };
        p.openHardware();
        return p;
    }

    /// Opens an in-memory `.wav` byte slice for playback (used in tests).
    pub fn openBytes(bytes: []const u8) ?Player {
        const header = wav.parseHeader(bytes) orelse return null;
        if (header.totalFrames() == 0) return null;
        return .{
            .mem_bytes = bytes,
            .header = header,
            .settings = .{},
        };
    }

    /// Opens a synthesized two-note chime (C5 -> G5, 400 ms at 48 kHz) for the
    /// Settings "Test sound" button.
    pub fn openTestTone(settings: Settings) Player {
        const rate: u32 = 48000;
        const frames: u32 = (rate * 400) / 1000; // 400 ms
        var p: Player = .{
            .tone_Active = true,
            .header = .{
                .encoding = .pcm_s16le,
                .channels = 2,
                .sample_rate = rate,
                .bits_per_sample = 16,
                .block_align = 4,
                .data_offset = 0,
                .data_size = frames * 4,
            },
            .settings = settings,
        };
        p.openHardware();
        return p;
    }

    fn openHardware(p: *Player) void {
        p.pcm = openOutput(p.header.sample_rate, p.settings);
    }

    pub fn close(p: *Player) void {
        if (p.pcm) |*pcm| {
            pcm.close();
            p.pcm = null;
        }
        if (p.owns_fd and p.fd >= 0) {
            sys.close(p.fd);
            p.fd = -1;
        }
    }

    /// Reloads or updates sound settings on a running player.
    pub fn updateSettings(p: *Player, new_settings: Settings) void {
        const output_changed = !std.mem.eql(u8, p.settings.output(), new_settings.output());
        p.settings = new_settings;
        if (output_changed) {
            if (p.pcm) |*pcm| {
                pcm.close();
                p.pcm = null;
            }
            p.fed_frame = p.current_frame;
            p.openHardware();
        } else if (p.pcm) |*pcm| {
            pcm.hw_volume = alsa.setCardVolume(pcm.card, p.settings.volume, p.settings.muted);
        }
    }

    pub fn durationMs(p: *const Player) u64 {
        return p.header.durationMs();
    }

    pub fn positionMs(p: *const Player) u64 {
        if (p.header.sample_rate == 0) return 0;
        return (p.current_frame * 1000) / p.header.sample_rate;
    }

    pub fn progress(p: *const Player) f32 {
        const total = p.header.totalFrames();
        if (total == 0) return 0;
        return std.math.clamp(
            @as(f32, @floatFromInt(p.current_frame)) / @as(f32, @floatFromInt(total)),
            0.0,
            1.0,
        );
    }

    pub fn togglePlay(p: *Player) void {
        if (p.ended) {
            p.current_frame = 0;
            p.fed_frame = 0;
            p.ended = false;
            p.playing = true;
            p.start_ns = 0;
            p.resample_frac = 0;
            if (p.pcm) |*pcm| pcm.drop();
            return;
        }
        p.playing = !p.playing;
        p.start_ns = 0;
        if (!p.playing) {
            if (p.pcm) |*pcm| pcm.drop();
            p.fed_frame = p.current_frame;
        }
    }

    pub fn seekMs(p: *Player, target_ms: u64) void {
        const total = p.header.totalFrames();
        if (total == 0) return;
        const target_frame = @min((target_ms * p.header.sample_rate) / 1000, total);
        p.current_frame = target_frame;
        p.fed_frame = target_frame;
        p.ended = target_frame >= total;
        if (p.ended) p.playing = false;
        p.start_ns = 0;
        p.resample_frac = 0;
        if (p.pcm) |*pcm| pcm.drop();
    }

    pub fn seekRelativeMs(p: *Player, delta_ms: i64) void {
        const cur: i64 = @intCast(p.positionMs());
        const next: u64 = @intCast(@max(0, cur + delta_ms));
        p.seekMs(next);
    }

    /// Advances audio playback according to monotonic clock `now_ns`, feeding
    /// decoded PCM frames into the ALSA ring buffer. Returns the number of
    /// milliseconds until the next wakeup, or `null` when paused or finished.
    pub fn step(p: *Player, now_ns: i128) ?u32 {
        if (!p.playing) return null;
        const total = p.header.totalFrames();
        if (total == 0 or p.header.sample_rate == 0) {
            p.playing = false;
            p.ended = true;
            return null;
        }

        const frame_ns: i128 = @divTrunc(std.time.ns_per_s, @as(i128, p.header.sample_rate));
        if (p.start_ns == 0) {
            p.start_ns = now_ns - @as(i128, p.current_frame) * frame_ns;
            p.settings = loadSettings();
            if (p.pcm) |*pcm| {
                pcm.hw_volume = alsa.setCardVolume(pcm.card, p.settings.volume, p.settings.muted);
            }
        }

        const elapsed_ns = @max(@as(i128, 0), now_ns - p.start_ns);
        const wall_frame: u64 = @intCast(@divTrunc(elapsed_ns, @max(frame_ns, 1)));
        p.current_frame = @min(wall_frame, total);

        if (p.pcm != null) {
            p.feedHardware();
        }

        if (p.current_frame >= total) {
            p.current_frame = total;
            p.playing = false;
            p.ended = true;
            return null;
        }

        return 16;
    }

    fn feedHardware(p: *Player) void {
        const pcm = &(p.pcm orelse return);
        const total = p.header.totalFrames();
        if (p.fed_frame >= total) return;

        // Keep up to ~120 ms of audio ahead of wall-clock position in the ring buffer.
        const lookahead_frames: u64 = (p.header.sample_rate * 120) / 1000;
        const max_target = @min(total, p.current_frame + lookahead_frames);

        var src_frames: [512][2]i16 = undefined;
        var dst_frames: [1024][2]i16 = undefined;

        var rounds: usize = 0;
        while (p.fed_frame < max_target and rounds < 8) : (rounds += 1) {
            const want = @min(@as(usize, @intCast(max_target - p.fed_frame)), src_frames.len);
            const decoded = p.readSourceFrames(p.fed_frame, src_frames[0..want]);
            if (decoded == 0) {
                p.fed_frame = total;
                break;
            }

            if (p.header.sample_rate == pcm.rate) {
                const written = pcm.writeStereoFrames(src_frames[0..decoded], p.settings.volume, p.settings.muted);
                p.fed_frame += written;
                if (written < decoded) break;
            } else {
                const res = alsa.resampleLinear(
                    src_frames[0..decoded],
                    p.header.sample_rate,
                    &dst_frames,
                    pcm.rate,
                    &p.resample_frac,
                );
                if (res.produced == 0) break;
                const written = pcm.writeStereoFrames(dst_frames[0..res.produced], p.settings.volume, p.settings.muted);
                if (written == res.produced) {
                    p.fed_frame += res.consumed;
                } else {
                    const consumed_est = (res.consumed * written) / @max(res.produced, 1);
                    p.fed_frame += consumed_est;
                    break;
                }
            }
        }
    }

    fn readSourceFrames(p: *Player, start_frame: u64, out: [][2]i16) usize {
        if (p.tone_Active) {
            return synthesizeTestTone(start_frame, p.header.totalFrames(), p.header.sample_rate, out);
        }
        const bpf: u64 = p.header.bytesPerFrame();
        if (bpf == 0) return 0;
        const byte_offset = p.header.data_offset + start_frame * bpf;
        const max_bytes_avail = if (start_frame * bpf < p.header.data_size)
            p.header.data_size - start_frame * bpf
        else
            0;
        if (max_bytes_avail == 0) return 0;

        var raw_buf: [512 * 16]u8 = undefined;
        const max_frames_in_buf = raw_buf.len / @as(usize, @intCast(bpf));
        const frames_to_read = @min(out.len, max_frames_in_buf);
        const bytes_to_read: usize = @intCast(@min(@as(u64, frames_to_read) * bpf, max_bytes_avail));
        if (bytes_to_read == 0) return 0;

        if (p.mem_bytes) |mem| {
            const start_usize: usize = @intCast(byte_offset);
            if (start_usize >= mem.len) return 0;
            const end_usize = @min(mem.len, start_usize + bytes_to_read);
            return wav.decodeFrames(p.header, mem[start_usize..end_usize], out);
        }
        if (p.fd >= 0) {
            const n = sys.check(linux.pread(p.fd, &raw_buf, bytes_to_read, @intCast(byte_offset))) catch return 0;
            if (n == 0) return 0;
            return wav.decodeFrames(p.header, raw_buf[0..n], out);
        }
        return 0;
    }
};

/// Generates a two-note chime (C5 523.25 Hz for the first half, G5 783.99 Hz
/// for the second half) with a soft envelope.
pub fn synthesizeTestTone(start_frame: u64, total_frames: u64, sample_rate: u32, out: [][2]i16) usize {
    if (start_frame >= total_frames or sample_rate == 0) return 0;
    const count = @min(out.len, @as(usize, @intCast(total_frames - start_frame)));
    const half = total_frames / 2;
    const rate_f: f32 = @floatFromInt(sample_rate);

    for (0..count) |i| {
        const frame = start_frame + i;
        const in_note = if (frame < half) frame else frame - half;
        const note_len = if (frame < half) half else total_frames - half;
        const freq: f32 = if (frame < half) 523.25 else 783.99;

        const t: f32 = @as(f32, @floatFromInt(in_note)) / rate_f;
        const attack: f32 = @min(1.0, @as(f32, @floatFromInt(in_note)) / (rate_f * 0.008));
        const decay: f32 = 1.0 - (@as(f32, @floatFromInt(in_note)) / @as(f32, @floatFromInt(@max(note_len, 1)))) * 0.75;
        const env = attack * decay;
        const sample_f = @sin(t * freq * 2.0 * std.math.pi) * env * 12000.0;
        const sample: i16 = @intFromFloat(std.math.clamp(sample_f, -32767.0, 32767.0));
        out[i] = .{ sample, sample };
    }
    return count;
}

const testing = std.testing;

test {
    _ = wav;
    _ = alsa;
    _ = aac;
}

test "classifyCard identifies Headphones, HDMI and USB audio outputs" {
    var buf: [48]u8 = undefined;
    const hp = classifyCard("Headphones", "bcm2835_headpho", "bcm2835 Headphones", "bcm2835 Headphones", &buf);
    try testing.expectEqual(Kind.headphones, hp.kind);
    try testing.expectEqualStrings("Headphones", hp.label);

    const hdmi = classifyCard("vc4hdmi", "vc4-hdmi", "vc4-hdmi", "vc4-hdmi", &buf);
    try testing.expectEqual(Kind.hdmi, hdmi.kind);
    try testing.expectEqualStrings("HDMI", hdmi.label);

    const hdmi1 = classifyCard("vc4hdmi0", "vc4-hdmi", "vc4-hdmi-0", "vc4-hdmi-0", &buf);
    try testing.expectEqual(Kind.hdmi, hdmi1.kind);
    try testing.expectEqualStrings("HDMI 1", hdmi1.label);

    const usb_dac = classifyCard("DAC", "USB-Audio", "USB Audio DAC", "Burr-Brown USB Audio DAC at usb-1.2", &buf);
    try testing.expectEqual(Kind.usb, usb_dac.kind);
    try testing.expectEqualStrings("USB Audio DAC", usb_dac.label);
}

test "Settings round-trips volume, mute and output device" {
    var s: Settings = .{ .volume = 65, .muted = true };
    s.setOutput("Headphones");
    var buf: [128]u8 = undefined;
    const text = s.formatBuf(&buf);
    const parsed = Settings.parse(text);
    try testing.expect(s.eql(&parsed));
    try testing.expectEqual(@as(u8, 65), parsed.volume);
    try testing.expect(parsed.muted);
    try testing.expectEqualStrings("Headphones", parsed.output());
}

test "Player plays, pauses, seeks and replays WAV audio" {
    var wav_bytes: [44 + 4800 * 4]u8 = @splat(0);
    wav.writePcm16Header(wav_bytes[0..44], 4800, 2, 4800); // 1.0 second
    var player = Player.openBytes(&wav_bytes).?;
    defer player.close();

    try testing.expectEqual(@as(u64, 1000), player.durationMs());
    try testing.expectEqual(@as(u64, 0), player.positionMs());
    try testing.expect(player.playing);

    const t0: i128 = 1_000_000_000;
    try testing.expectEqual(@as(?u32, 16), player.step(t0));
    try testing.expectEqual(@as(?u32, 16), player.step(t0 + 500 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u64, 500), player.positionMs());

    // Seek forward 250 ms.
    player.seekRelativeMs(250);
    try testing.expectEqual(@as(u64, 750), player.positionMs());

    // Reach the end.
    _ = player.step(t0 + 1_000 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u32, null), player.step(t0 + 1_300 * std.time.ns_per_ms));
    try testing.expect(player.ended);
    try testing.expect(!player.playing);

    // Toggle play after ended restarts from 0.
    player.togglePlay();
    try testing.expect(player.playing);
    try testing.expect(!player.ended);
    try testing.expectEqual(@as(u64, 0), player.positionMs());
}
