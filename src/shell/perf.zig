//! The performance overlay, toggled with Super+I: a small panel in the
//! top right of the screen showing FPS, CPU, GPU and memory use, refreshed
//! every second while it is shown.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const font = @import("font");

/// KEY_I (linux/input-event-codes.h).
pub const key_i = 23;

const background = 0xff1c2a4a;
const border_color = 0xff2c3e66;
const track_color = 0xff101830;
const label_color = 0xff9ab0d8;
const value_color = 0xffe8eefc;

const fps_color = 0xff3fb86e;
const fps_low_color = 0xffe8b33f;
const cpu_color = 0xff3f7ee8;
const gpu_color = 0xff3fb8c4;
const mem_color = 0xffb04fd6;
const gpu_mem_color = 0xffe8883f;
const high_color = 0xffe84f6a;

pub const Stats = struct {
    /// Frames shown per second over the last interval.
    fps: f32 = 0,
    /// CPU use in percent of all cores (0..100), once two samples have been taken.
    cpu_busy: ?f32 = null,
    /// GPU 3D engine use in percent (0..100), from DRM fdinfo or compositor GPU time.
    gpu_busy: ?f32 = null,
    /// Contiguous memory (CMA) used by the GPU and its total, in bytes.
    gpu_used: u64 = 0,
    gpu_total: u64 = 0,
    /// System memory in use and total, in bytes.
    mem_used: u64 = 0,
    mem_total: u64 = 0,
};

pub const Lines = struct {
    fps: [48]u8 = undefined,
    fps_len: usize = 0,
    cpu: [48]u8 = undefined,
    cpu_len: usize = 0,
    gpu: [48]u8 = undefined,
    gpu_len: usize = 0,
    mem: [48]u8 = undefined,
    mem_len: usize = 0,
    gpu_mem: [48]u8 = undefined,
    gpu_mem_len: usize = 0,

    pub fn fpsText(l: *const Lines) []const u8 {
        return l.fps[0..l.fps_len];
    }

    pub fn cpuText(l: *const Lines) []const u8 {
        return l.cpu[0..l.cpu_len];
    }

    pub fn gpuText(l: *const Lines) []const u8 {
        return l.gpu[0..l.gpu_len];
    }

    pub fn memText(l: *const Lines) []const u8 {
        return l.mem[0..l.mem_len];
    }

    pub fn gpuMemText(l: *const Lines) []const u8 {
        return l.gpu_mem[0..l.gpu_mem_len];
    }
};

fn printLen(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
    return (std.fmt.bufPrint(buf, fmt, args) catch return 0).len;
}

/// Formats the five value strings shown in the overlay.
pub fn formatLines(s: Stats) Lines {
    var out: Lines = .{};
    out.fps_len = printLen(&out.fps, "{d:.0}", .{@max(s.fps, 0)});
    out.cpu_len = if (s.cpu_busy) |busy|
        printLen(&out.cpu, "{d:.0}%", .{std.math.clamp(busy, 0, 100)})
    else
        printLen(&out.cpu, "—", .{});

    out.gpu_len = if (s.gpu_busy) |busy|
        printLen(&out.gpu, "{d:.0}%", .{std.math.clamp(busy, 0, 100)})
    else
        printLen(&out.gpu, "—", .{});

    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    if (s.mem_total > 0) {
        const pct = 100 * @as(f32, @floatFromInt(s.mem_used)) / @as(f32, @floatFromInt(s.mem_total));
        const used_s = formatBytes(&b1, s.mem_used);
        const total_s = formatBytes(&b2, s.mem_total);
        out.mem_len = printLen(&out.mem, "{d:.0}%  ·  {s} / {s}", .{ std.math.clamp(pct, 0, 100), used_s, total_s });
    } else {
        out.mem_len = printLen(&out.mem, "—", .{});
    }

    if (s.gpu_total > 0) {
        const pct = 100 * @as(f32, @floatFromInt(s.gpu_used)) / @as(f32, @floatFromInt(s.gpu_total));
        const used_s = formatBytes(&b1, s.gpu_used);
        const total_s = formatBytes(&b2, s.gpu_total);
        out.gpu_mem_len = printLen(&out.gpu_mem, "{d:.0}%  ·  {s} / {s}", .{ std.math.clamp(pct, 0, 100), used_s, total_s });
    } else {
        out.gpu_mem_len = printLen(&out.gpu_mem, "—", .{});
    }
    return out;
}

/// "340 KB", "9.8 MB", "1.2 GB".
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };
    var v = b;
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    if (u == 0) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch return "";
    if (v < 10) return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch return "";
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch return "";
}

/// The total and idle (idle + iowait) ticks from /proc/stat's first line.
pub fn parseStat(stat: []const u8) ?[2]u64 {
    const line = stat[0 .. std.mem.indexOfScalar(u8, stat, '\n') orelse stat.len];
    if (!std.mem.startsWith(u8, line, "cpu ")) return null;
    var fields = std.mem.tokenizeScalar(u8, line[4..], ' ');
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    while (fields.next()) |f| : (i += 1) {
        if (i >= 8) break;
        const v = std.fmt.parseInt(u64, f, 10) catch return null;
        total += v;
        if (i == 3 or i == 4) idle += v;
    }
    return .{ total, idle };
}

/// Parses a `/proc/<pid>/fdinfo/<fd>` file for a DRM file descriptor,
/// returning its `drm-client-id` and the busiest engine's cumulative time
/// in nanoseconds (`drm-engine-*: <ns> ns`).
pub fn parseDrmFdinfo(text: []const u8) ?struct { client_id: u64, engine_ns: u64 } {
    var client_id: ?u64 = null;
    var max_engine_ns: ?u64 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "drm-client-id")) {
            client_id = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (std.mem.startsWith(u8, key, "drm-engine-") and !std.mem.endsWith(u8, key, "-capacity")) {
            var toks = std.mem.tokenizeAny(u8, val, " \t");
            const num = toks.next() orelse continue;
            const unit = toks.next() orelse continue;
            if (!std.mem.eql(u8, unit, "ns")) continue;
            const ns = std.fmt.parseInt(u64, num, 10) catch continue;
            max_engine_ns = @max(max_engine_ns orelse 0, ns);
        }
    }
    return .{ .client_id = client_id orelse return null, .engine_ns = max_engine_ns orelse return null };
}

pub const Monitor = struct {
    last_ns: ?u64 = null,
    last_cpu: ?[2]u64 = null,
    last_drm_ns: ?u64 = null,

    pub fn reset(m: *Monitor, now_ns: u64) void {
        m.last_ns = now_ns;
        var buf: [4096]u8 = undefined;
        if (sys.readFile("/proc/stat", &buf)) |stat| m.last_cpu = parseStat(stat);
        m.last_drm_ns = readDrmEngineNs(&.{});
    }

    pub fn sample(m: *Monitor, now_ns: u64, frames: u32, shell_gpu_ns: u64, client_pids: []const linux.pid_t) Stats {
        var s: Stats = .{};
        const elapsed_ns = if (m.last_ns) |last| now_ns -| last else 0;
        m.last_ns = now_ns;

        if (elapsed_ns > 0) {
            s.fps = @as(f32, @floatFromInt(frames)) / (@as(f32, @floatFromInt(elapsed_ns)) / std.time.ns_per_s);
        }

        var buf: [4096]u8 = undefined;
        if (sys.readFile("/proc/stat", &buf)) |stat| if (parseStat(stat)) |now_cpu| {
            if (m.last_cpu) |last_cpu| {
                const total = now_cpu[0] -| last_cpu[0];
                const idle = now_cpu[1] -| last_cpu[1];
                if (total > 0) {
                    s.cpu_busy = 100 * @as(f32, @floatFromInt(total -| idle)) / @as(f32, @floatFromInt(total));
                }
            }
            m.last_cpu = now_cpu;
        };

        if (sys.meminfo()) |mi| {
            s.mem_total = mi.total;
            s.mem_used = mi.total -| mi.available;
            s.gpu_total = mi.cma_total;
            s.gpu_used = mi.cma_total -| mi.cma_free;
        }

        if (readDrmEngineNs(client_pids)) |drm_ns| {
            if (m.last_drm_ns) |last_drm| if (elapsed_ns > 0) {
                const busy_ns = drm_ns -| last_drm;
                s.gpu_busy = std.math.clamp(100 * @as(f32, @floatFromInt(busy_ns)) / @as(f32, @floatFromInt(elapsed_ns)), 0, 100);
            };
            m.last_drm_ns = drm_ns;
        } else if (elapsed_ns > 0) {
            s.gpu_busy = std.math.clamp(100 * @as(f32, @floatFromInt(shell_gpu_ns)) / @as(f32, @floatFromInt(elapsed_ns)), 0, 100);
        }

        return s;
    }
};

/// Sums cumulative GPU engine nanoseconds across `/proc/self/fdinfo` and
/// `client_pids`, deduplicating DRM clients by `drm-client-id`. Returns
/// null if no DRM fd reports `drm-engine-*`.
fn readDrmEngineNs(client_pids: []const linux.pid_t) ?u64 {
    var seen_ids: [64]u64 = undefined;
    var n_seen: usize = 0;
    var total_ns: u64 = 0;
    var any = false;

    const scanPid = struct {
        fn run(dir_path: [*:0]const u8, seen: *[64]u64, count: *usize, sum: *u64, found: *bool) void {
            const dir = sys.open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
            defer sys.close(dir);
            var dents: [2048]u8 align(8) = undefined;
            while (true) {
                const n = sys.check(linux.getdents64(dir, &dents, dents.len)) catch return;
                if (n == 0) return;
                var at: usize = 0;
                while (at < n) {
                    const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
                    const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
                    at += reclen;
                    if (name.len == 0 or name[0] == '.') continue;
                    var path_buf: [96]u8 = undefined;
                    const p = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ std.mem.sliceTo(dir_path, 0), name }) catch continue;
                    var fbuf: [1024]u8 = undefined;
                    const text = sys.readFile(p, &fbuf) orelse continue;
                    const info = parseDrmFdinfo(text) orelse continue;
                    const dup = for (seen[0..count.*]) |id| {
                        if (id == info.client_id) break true;
                    } else false;
                    if (dup) continue;
                    if (count.* < seen.len) {
                        seen[count.*] = info.client_id;
                        count.* += 1;
                    }
                    sum.* +%= info.engine_ns;
                    found.* = true;
                }
            }
        }
    }.run;

    scanPid("/proc/self/fdinfo", &seen_ids, &n_seen, &total_ns, &any);
    for (client_pids) |pid| {
        if (pid <= 0) continue;
        var dir_buf: [64]u8 = undefined;
        const dir_path = std.fmt.bufPrintZ(&dir_buf, "/proc/{d}/fdinfo", .{pid}) catch continue;
        scanPid(dir_path, &seen_ids, &n_seen, &total_ns, &any);
    }
    return if (any) total_ns else null;
}

pub const Overlay = struct {
    font: ?font.Font,
    cache: font.GlyphCache,
    pixels: []u32,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    scale: f32,

    pub fn init(gpa: std.mem.Allocator, f: ?font.Font, screen_width: u32, screen_height: u32) !Overlay {
        const raw_scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        const scale = @max(raw_scale, 0.5);
        const width: u32 = @min(screen_width, @as(u32, @intFromFloat(@round(280 * scale))));
        const height: u32 = @min(screen_height, @as(u32, @intFromFloat(@round(180 * scale))));
        const margin_x: i32 = @intFromFloat(@round(16 * scale));
        const margin_y: i32 = @intFromFloat(@round(56 * scale));
        const x: i32 = @max(0, @as(i32, @intCast(screen_width)) - @as(i32, @intCast(width)) - margin_x);
        const y: i32 = @min(margin_y, @max(0, @as(i32, @intCast(screen_height)) - @as(i32, @intCast(height))));
        return .{
            .font = f,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, @as(usize, width) * height),
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .scale = scale,
        };
    }

    pub fn deinit(o: *Overlay, gpa: std.mem.Allocator) void {
        gpa.free(o.pixels);
        o.cache.deinit();
    }

    pub fn draw(o: *Overlay, stats: Stats) void {
        const canvas: font.Canvas = .{ .pixels = o.pixels, .width = o.width, .height = o.height, .stride = o.width };
        canvas.fill(0, 0, o.width, o.height, border_color);
        const border: u32 = @max(1, @as(u32, @intFromFloat(@round(2 * o.scale))));
        if (o.width > 2 * border and o.height > 2 * border) {
            canvas.fill(@intCast(border), @intCast(border), o.width - 2 * border, o.height - 2 * border, background);
        }

        const lines = formatLines(stats);
        const gpu_frac: f32 = (stats.gpu_busy orelse 0) / 100;
        const mem_frac: f32 = if (stats.mem_total > 0)
            @as(f32, @floatFromInt(stats.mem_used)) / @as(f32, @floatFromInt(stats.mem_total))
        else
            0;
        const gpu_mem_frac: f32 = if (stats.gpu_total > 0)
            @as(f32, @floatFromInt(stats.gpu_used)) / @as(f32, @floatFromInt(stats.gpu_total))
        else
            0;
        const cpu_frac: f32 = (stats.cpu_busy orelse 0) / 100;
        const fps_frac: f32 = stats.fps / 60;

        const Row = struct {
            label: []const u8,
            value: []const u8,
            fraction: f32,
            color: u32,
        };
        const rows = [5]Row{
            .{
                .label = "FPS",
                .value = lines.fpsText(),
                .fraction = fps_frac,
                .color = if (stats.fps > 0 and stats.fps < 30) fps_low_color else fps_color,
            },
            .{
                .label = "CPU",
                .value = lines.cpuText(),
                .fraction = cpu_frac,
                .color = if (cpu_frac >= 0.9) high_color else cpu_color,
            },
            .{
                .label = "GPU",
                .value = lines.gpuText(),
                .fraction = gpu_frac,
                .color = if (gpu_frac >= 0.9) high_color else gpu_color,
            },
            .{
                .label = "Memory",
                .value = lines.memText(),
                .fraction = mem_frac,
                .color = if (mem_frac >= 0.9) high_color else mem_color,
            },
            .{
                .label = "GPU Memory",
                .value = lines.gpuMemText(),
                .fraction = gpu_mem_frac,
                .color = if (gpu_mem_frac >= 0.9) high_color else gpu_mem_color,
            },
        };

        const pad_x = 14 * o.scale;
        const pad_y = 10 * o.scale;
        const row_h = 32 * o.scale;
        const bar_h = @max(3, @round(5 * o.scale));
        const bar_w = @max(1, @as(f32, @floatFromInt(o.width)) - 2 * pad_x);
        const text_size = @round(15 * o.scale);

        for (rows, 0..) |r, i| {
            const y0 = pad_y + @as(f32, @floatFromInt(i)) * row_h;
            if (o.font) |*f| {
                const label_style: font.Style = .{ .font = f, .size = text_size, .color = label_color };
                const value_style: font.Style = .{ .font = f, .size = text_size, .color = value_color };
                const baseline = @round(y0 + label_style.ascent());
                _ = font.draw(canvas, &o.cache, label_style, @round(pad_x), baseline, r.label) catch {};
                const lw = font.measure(label_style, r.label);
                const vw = font.measure(value_style, r.value);
                const vx = @max(pad_x + lw + 8 * o.scale, @as(f32, @floatFromInt(o.width)) - pad_x - vw);
                _ = font.draw(canvas, &o.cache, value_style, @round(vx), baseline, r.value) catch {};
            }
            const bar_y = @round(y0 + 21 * o.scale);
            roundedRect(canvas, pad_x, bar_y, bar_w, bar_h, bar_h / 2, track_color);
            const clamped = std.math.clamp(if (std.math.isFinite(r.fraction)) r.fraction else 0, 0, 1);
            if (clamped > 0) {
                const fill_w = @max(bar_h, bar_w * clamped);
                roundedRect(canvas, pad_x, bar_y, fill_w, bar_h, bar_h / 2, r.color);
            }
        }
    }
};

/// Fills a rectangle with rounded corners, anti-aliased.
fn roundedRect(c: font.Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: u32) void {
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(x), 0, @as(f32, @floatFromInt(c.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(y), 0, @as(f32, @floatFromInt(c.height))));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(x + w), 0, @as(f32, @floatFromInt(c.width))));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(y + h), 0, @as(f32, @floatFromInt(c.height))));
    const cx = x + w / 2;
    const cy = y + h / 2;
    const r = @min(radius, @min(w, h) / 2);
    for (y0..y1) |py| for (x0..x1) |px| {
        const qx = @abs(@as(f32, @floatFromInt(px)) + 0.5 - cx) - (w / 2 - r);
        const qy = @abs(@as(f32, @floatFromInt(py)) + 0.5 - cy) - (h / 2 - r);
        const outside = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
        const coverage = std.math.clamp(0.5 - outside, 0, 1);
        if (coverage <= 0) continue;
        const p = &c.pixels[py * c.stride + px];
        p.* = font.text.blend(p.*, color, @intFromFloat(@round(coverage * 255)));
    };
}

const testing = std.testing;

test "CPU ticks and DRM fdinfo parsing" {
    try testing.expectEqual([2]u64{ 980, 820 }, parseStat("cpu  100 5 50 800 20 3 2 0 0 0\ncpu0 1\n").?);
    try testing.expect(parseStat("mem 100\n") == null);

    const fdinfo =
        "pos:\t0\n" ++
        "flags:\t02000002\n" ++
        "mnt_id:\t25\n" ++
        "ino:\t412\n" ++
        "drm-driver:\tv3d\n" ++
        "drm-client-id:\t7\n" ++
        "drm-engine-v3d:\t125000000 ns\n" ++
        "drm-engine-render:\t180000000 ns\n" ++
        "drm-engine-bin:\t40000000 ns\n";
    const parsed = parseDrmFdinfo(fdinfo).?;
    try testing.expectEqual(@as(u64, 7), parsed.client_id);
    try testing.expectEqual(@as(u64, 180000000), parsed.engine_ns);
    try testing.expect(parseDrmFdinfo("pos:\t0\ndrm-driver:\tvc4\ndrm-client-id:\t3\n") == null);
}

test "formatting FPS, CPU, GPU, memory and GPU memory lines" {
    const lines = formatLines(.{
        .fps = 59.8,
        .cpu_busy = 24.4,
        .gpu_busy = 38.2,
        .gpu_used = 32 * 1024 * 1024,
        .gpu_total = 128 * 1024 * 1024,
        .mem_used = 96 * 1024 * 1024,
        .mem_total = 434 * 1024 * 1024,
    });
    try testing.expectEqualStrings("60", lines.fpsText());
    try testing.expectEqualStrings("24%", lines.cpuText());
    try testing.expectEqualStrings("38%", lines.gpuText());
    try testing.expectEqualStrings("22%  ·  96 MB / 434 MB", lines.memText());
    try testing.expectEqualStrings("25%  ·  32 MB / 128 MB", lines.gpuMemText());

    const cma_only = formatLines(.{
        .fps = 0,
        .cpu_busy = null,
        .gpu_busy = null,
        .gpu_used = 16 * 1024 * 1024,
        .gpu_total = 64 * 1024 * 1024,
        .mem_used = 0,
        .mem_total = 0,
    });
    try testing.expectEqualStrings("0", cma_only.fpsText());
    try testing.expectEqualStrings("—", cma_only.cpuText());
    try testing.expectEqualStrings("—", cma_only.gpuText());
    try testing.expectEqualStrings("—", cma_only.memText());
    try testing.expectEqualStrings("25%  ·  16 MB / 64 MB", cma_only.gpuMemText());
}

test "overlay draws background, border and meter bars in the top right" {
    var o = try Overlay.init(testing.allocator, null, 1920, 1080);
    defer o.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 280), o.width);
    try testing.expectEqual(@as(u32, 180), o.height);
    try testing.expectEqual(@as(i32, 1920 - 280 - 16), o.x);
    try testing.expectEqual(@as(i32, 56), o.y);

    o.draw(.{
        .fps = 60,
        .cpu_busy = 50,
        .gpu_busy = 95,
        .mem_used = 256 * 1024 * 1024,
        .mem_total = 512 * 1024 * 1024,
        .gpu_used = 64 * 1024 * 1024,
        .gpu_total = 128 * 1024 * 1024,
    });
    // Border at (0, 0) and background inside.
    try testing.expectEqual(@as(u32, border_color), o.pixels[0]);
    try testing.expectEqual(@as(u32, background), o.pixels[4 * o.width + 4]);
    // First row (FPS = 60, full green bar) at y = 10 + 21 + 2 = 33.
    try testing.expectEqual(@as(u32, fps_color), o.pixels[33 * o.width + o.width / 2]);
    // Second row (CPU = 50%, half blue bar, half track) at y = 10 + 32 + 21 + 2 = 65.
    try testing.expectEqual(@as(u32, cpu_color), o.pixels[65 * o.width + 30]);
    try testing.expectEqual(@as(u32, track_color), o.pixels[65 * o.width + o.width - 30]);
    // Third row (GPU = 95% >= 90%, high_color) at y = 10 + 64 + 21 + 2 = 97.
    try testing.expectEqual(@as(u32, high_color), o.pixels[97 * o.width + 30]);
    // Fifth row (GPU Memory = 50%, gpu_mem_color) at y = 10 + 128 + 21 + 2 = 161.
    try testing.expectEqual(@as(u32, gpu_mem_color), o.pixels[161 * o.width + 30]);
    try testing.expectEqual(@as(u32, track_color), o.pixels[161 * o.width + o.width - 30]);
}

test "monitor samples this machine" {
    var m: Monitor = .{};
    m.reset(1 * std.time.ns_per_s);
    const s = m.sample(2 * std.time.ns_per_s, 60, 4 * std.time.ns_per_ms, &.{});
    try testing.expectApproxEqAbs(@as(f32, 60), s.fps, 0.01);
    try testing.expect(s.mem_total > 0);
}
