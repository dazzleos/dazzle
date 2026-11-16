//! The performance overlay, toggled with Super+I: a small panel in the
//! bottom right of the screen showing FPS, CPU, GPU and memory use,
//! refreshed every second while it is shown; in a see-through box like the
//! dock's.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const kete = @import("kete");
const glass = @import("glass.zig");
const dock = @import("dock.zig");
const kete_panel = @import("kete_panel.zig");

/// Text and the bars' tracks, in each theme.
const Colors = struct { label: u32, value: u32, track: u32 };
fn colors(theme: dock.Theme) Colors {
    return switch (theme) {
        .dark => .{ .label = 0xff9ab0d8, .value = 0xffe8eefc, .track = 0x60000000 },
        .light => .{ .label = 0xff4a5a7a, .value = 0xff1c2a4a, .track = 0x401c2a4a },
    };
}

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
                    const p = std.mem.printSentinel(&path_buf, "{s}/{s}", .{ std.mem.sliceTo(dir_path, 0), name }, 0) catch continue;
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
        const dir_path = std.mem.printSentinel(&dir_buf, "/proc/{d}/fdinfo", .{pid}, 0) catch continue;
        scanPid(dir_path, &seen_ids, &n_seen, &total_ns, &any);
    }
    return if (any) total_ns else null;
}

pub const Overlay = struct {
    /// Where it is drawn (kete's).
    panel: *kete_panel.Panel,
    /// Its picture, as `draw` last drew it.
    pixels: []const u32 = &.{},
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    scale: f32,

    pub fn init(kit: *kete_panel.Kit, screen_width: u32, screen_height: u32) !Overlay {
        const raw_scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        const scale = @max(raw_scale, 0.5);
        const width: u32 = @min(screen_width, @as(u32, @intFromFloat(@round(280 * scale))));
        const height: u32 = @min(screen_height, @as(u32, @intFromFloat(@round(180 * scale))));
        // As far from the bottom (and the right) as the dock is.
        const margin: i32 = @intFromFloat(@round(dock.Dock.margin * scale));
        const x: i32 = @max(0, @as(i32, @intCast(screen_width)) - @as(i32, @intCast(width)) - margin);
        const y: i32 = @max(0, @as(i32, @intCast(screen_height)) - @as(i32, @intCast(height)) - margin);
        return .{ .panel = try kit.panel(), .width = width, .height = height, .x = x, .y = y, .scale = scale };
    }

    pub fn deinit(o: *Overlay) void {
        o.panel.destroy();
    }

    /// Its picture, `width` by `height`.
    pub fn picture(o: *const Overlay) []const u32 {
        return o.pixels;
    }

    /// Draws `stats` in a see-through box like the dock's, in `theme`
    /// (with kete: see `View`).
    pub fn draw(o: *Overlay, stats: Stats, theme: dock.Theme) void {
        o.pixels = o.panel.draw(o.width, o.height, 0, View{ .stats = stats, .theme = theme, .scale = o.scale });
    }

    /// A row: what it is, how much, and a bar.
    const Meter = struct {
        label: []const u8,
        value: []const u8,
        fraction: f32,
        color: u32,
        colors: Colors,
        scale: f32,

        pub fn layout(_: *const Meter, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
            return c.constrain(.{ .w = c.max_w, .h = c.max_h });
        }

        pub fn paint(m: *const Meter, n: *kete.WidgetNode, p: *kete.Painter) void {
            const argb = kete.gfx.Color.argb;
            const s = m.scale;
            const w = n.size.w;
            if (p.ui.font) |f| {
                const style: kete.font.Style = .{ .font = f, .size = @round(15 * s) };
                const baseline = @round(style.ascent());
                _ = p.text(style.size, 0, baseline, m.label, argb(m.colors.label));
                const lw = kete.font.measure(style, m.label);
                const vw = kete.font.measure(style, m.value);
                _ = p.text(style.size, @round(@max(lw + 8 * s, w - vw)), baseline, m.value, argb(m.colors.value));
            }
            const bar_h = @max(3, @round(5 * s));
            const bar_y = @round(21 * s);
            const cv = p.canvas();
            cv.fillRoundedRect(.{ .x = 0, .y = bar_y, .w = w, .h = bar_h }, .all(bar_h / 2), argb(m.colors.track));
            const k = std.math.clamp(if (std.math.isFinite(m.fraction)) m.fraction else 0, 0, 1);
            if (k > 0) cv.fillRoundedRect(.{ .x = 0, .y = bar_y, .w = @max(bar_h, w * k), .h = bar_h }, .all(bar_h / 2), argb(m.color));
        }
    };

    /// It as kete widgets: the see-through box, and a meter a row.
    const View = struct {
        stats: Stats,
        theme: dock.Theme,
        scale: f32,

        pub fn build(v: *const View, cx: *kete.BuildContext) kete.Widget {
            const stats = v.stats;
            const s = v.scale;
            const c = colors(v.theme);
            const a = cx.arena;
            const lines = a.create(Lines) catch return cx.make(kete.SizedBox.empty);
            lines.* = formatLines(stats);
            const gpu_frac: f32 = (stats.gpu_busy orelse 0) / 100;
            const mem_frac: f32 = if (stats.mem_total > 0) @as(f32, @floatFromInt(stats.mem_used)) / @as(f32, @floatFromInt(stats.mem_total)) else 0;
            const gpu_mem_frac: f32 = if (stats.gpu_total > 0) @as(f32, @floatFromInt(stats.gpu_used)) / @as(f32, @floatFromInt(stats.gpu_total)) else 0;
            const cpu_frac: f32 = (stats.cpu_busy orelse 0) / 100;
            const rows = [5]Meter{
                .{ .label = "FPS", .value = lines.fpsText(), .fraction = stats.fps / 60, .color = if (stats.fps > 0 and stats.fps < 30) fps_low_color else fps_color, .colors = c, .scale = s },
                .{ .label = "CPU", .value = lines.cpuText(), .fraction = cpu_frac, .color = if (cpu_frac >= 0.9) high_color else cpu_color, .colors = c, .scale = s },
                .{ .label = "GPU", .value = lines.gpuText(), .fraction = gpu_frac, .color = if (gpu_frac >= 0.9) high_color else gpu_color, .colors = c, .scale = s },
                .{ .label = "Memory", .value = lines.memText(), .fraction = mem_frac, .color = if (mem_frac >= 0.9) high_color else mem_color, .colors = c, .scale = s },
                .{ .label = "GPU Memory", .value = lines.gpuMemText(), .fraction = gpu_mem_frac, .color = if (gpu_mem_frac >= 0.9) high_color else gpu_mem_color, .colors = c, .scale = s },
            };
            var children: [rows.len]kete.Widget = undefined;
            for (&children, rows) |*ch, r| ch.* = cx.make(kete.SizedBox{ .height = 32 * s, .child = cx.make(r) });
            return cx.make(kete.RoundedBox{
                .color = kete.gfx.Color.argb((v.theme.colors().background & 0x00ffffff) | @as(u32, glass.alpha) << 24),
                .radius = .all(@round(dock.Dock.box_radius * s)),
                .child = cx.make(kete.Padding{ .padding = .{ .left = 14 * s, .right = 14 * s, .top = 10 * s }, .child = cx.make(kete.Column{
                    .cross_axis_alignment = .stretch,
                    .children = a.dupe(kete.Widget, &children) catch &.{},
                }) }),
            });
        }
    };
};

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

test "overlay draws a see-through box like the dock's, with meter bars, in the bottom right" {
    const kit = try kete_panel.Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    var o = try Overlay.init(kit, 1920, 1080);
    defer o.deinit();
    try testing.expectEqual(@as(u32, 280), o.width);
    try testing.expectEqual(@as(u32, 180), o.height);
    try testing.expectEqual(@as(i32, 1920 - 280 - 8), o.x);
    try testing.expectEqual(@as(i32, 1080 - 180 - 8), o.y);

    o.draw(.{
        .fps = 60,
        .cpu_busy = 50,
        .gpu_busy = 95,
        .mem_used = 256 * 1024 * 1024,
        .mem_total = 512 * 1024 * 1024,
        .gpu_used = 64 * 1024 * 1024,
        .gpu_total = 128 * 1024 * 1024,
    }, .dark);
    const box = dock.Theme.dark.colors().background;
    const track = o.pixels[65 * o.width + o.width - 30];
    // Rounded: none of it at the corner; the box's colour, see-through,
    // inside.
    try testing.expectEqual(@as(u32, 0), o.pixels[0] >> 24);
    try testing.expectEqual(@as(u32, glass.alpha) << 24 | (box & 0xffffff), o.pixels[o.height / 2 * o.width + 4]);
    // The tracks are darker than the box, and more opaque.
    try testing.expect(track >> 24 > glass.alpha and track >> 24 < 0xff);
    try testing.expect((track & 0xff) < (box & 0xff));
    // First row (FPS = 60, full green bar) at y = 10 + 21 + 2 = 33.
    try testing.expectEqual(@as(u32, fps_color), o.pixels[33 * o.width + o.width / 2]);
    // Second row (CPU = 50%, half blue bar, half track) at y = 10 + 32 + 21 + 2 = 65.
    try testing.expectEqual(@as(u32, cpu_color), o.pixels[65 * o.width + 30]);
    // Third row (GPU = 95% >= 90%, high_color) at y = 10 + 64 + 21 + 2 = 97.
    try testing.expectEqual(@as(u32, high_color), o.pixels[97 * o.width + 30]);
    // Fifth row (GPU Memory = 50%, gpu_mem_color) at y = 10 + 128 + 21 + 2 = 161.
    try testing.expectEqual(@as(u32, gpu_mem_color), o.pixels[161 * o.width + 30]);
    try testing.expectEqual(track, o.pixels[161 * o.width + o.width - 30]);
}

test "drawn again as the numbers change, the same as drawn afresh" {
    const kit = try kete_panel.Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    var o = try Overlay.init(kit, 1920, 1080);
    defer o.deinit();
    var fresh = try Overlay.init(kit, 1920, 1080);
    defer fresh.deinit();
    for (0..4) |i| {
        const k: f32 = @floatFromInt(i);
        const stats: Stats = .{ .fps = 30 + 9 * k, .cpu_busy = 10 + 20 * k, .gpu_busy = 5 * k, .mem_used = (100 + 50 * i) << 20, .mem_total = 400 << 20, .gpu_used = (10 + i) << 20, .gpu_total = 64 << 20 };
        o.draw(stats, .dark);
        fresh.panel.width = 0;
        fresh.draw(stats, .dark);
        try testing.expectEqualSlices(u32, fresh.picture(), o.picture());
    }
}

test "monitor samples this machine" {
    var m: Monitor = .{};
    m.reset(1 * std.time.ns_per_s);
    const s = m.sample(2 * std.time.ns_per_s, 60, 4 * std.time.ns_per_ms, &.{});
    try testing.expectApproxEqAbs(@as(f32, 60), s.fps, 0.01);
    try testing.expect(s.mem_total > 0);
}
