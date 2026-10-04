//! Health figures for the statistics, to tell a slow program from a slow
//! machine: the SoC's temperature, the CPU's speed (the firmware lowers
//! the clock when the SoC is hot or the supply voltage drops), and how busy
//! the CPU is, overall and in the demo and the shell (its parent).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const Sample = struct {
    /// Degrees Celsius, if the kernel has the thermal sensor.
    temperature: ?f32 = null,
    /// The CPU's speed compared with the first sample, in percent.
    speed: f32 = 100,
    /// CPU use since the previous sample, in percent of all the cores (on a
    /// Pi 3 A+, a program keeping one of its four cores busy is 25%).
    total_busy: f32 = 0,
    demo_busy: f32 = 0,
    shell_busy: f32 = 0,
};

pub const Monitor = struct {
    baseline_ns: u64 = 0,
    last: Counters = .{},

    const Counters = struct {
        /// From /proc/stat, in clock ticks.
        total: u64 = 0,
        idle: u64 = 0,
        demo: u64 = 0,
        shell: u64 = 0,
    };

    pub fn sample(m: *Monitor) Sample {
        var s: Sample = .{ .temperature = temperature() };

        // The fastest of a few runs: one that was not interrupted.
        var best: u64 = std.math.maxInt(u64);
        for (0..5) |_| best = @min(best, spinNs());
        if (m.baseline_ns == 0) m.baseline_ns = @max(best, 1);
        s.speed = 100 * @as(f32, @floatFromInt(m.baseline_ns)) / @as(f32, @floatFromInt(@max(best, 1)));

        var buf: [512]u8 = undefined;
        var now: Counters = .{};
        if (sys.readFile("/proc/stat", &buf)) |stat| if (parseStat(stat)) |c| {
            now.total = c[0];
            now.idle = c[1];
        };
        if (sys.readFile("/proc/self/stat", &buf)) |stat| now.demo = processTicks(stat) orelse 0;
        var path_buf: [32]u8 = undefined;
        const shell_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{linux.getppid()}) catch unreachable;
        if (sys.readFile(shell_path, &buf)) |stat| now.shell = processTicks(stat) orelse 0;

        const elapsed = now.total -| m.last.total;
        if (m.last.total != 0 and elapsed > 0) {
            const e: f32 = @floatFromInt(elapsed);
            s.total_busy = 100 * @as(f32, @floatFromInt(elapsed -| (now.idle -| m.last.idle))) / e;
            s.demo_busy = 100 * @as(f32, @floatFromInt(now.demo -| m.last.demo)) / e;
            s.shell_busy = 100 * @as(f32, @floatFromInt(now.shell -| m.last.shell)) / e;
        }
        m.last = now;
        return s;
    }
};

fn temperature() ?f32 {
    var buf: [32]u8 = undefined;
    const text = sys.readFile("/sys/class/thermal/thermal_zone0/temp", &buf) orelse return null;
    const milli = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch return null;
    return @as(f32, @floatFromInt(milli)) / 1000;
}

/// The time a fixed amount of work takes: a few hundred microseconds on a
/// Pi Zero at full speed. It is wall time (the per-thread CPU clock gave a
/// speed of 0% on the Pi, too coarse or not advancing over so short a
/// time); `sample` keeps the fastest of several runs so that time spent in
/// other processes does not count.
fn spinNs() u64 {
    const t0 = sys.nowNs();
    var x: u32 = 1;
    for (0..50_000) |i| {
        x = x *% 1664525 +% @as(u32, @truncate(i));
        std.mem.doNotOptimizeAway(x);
    }
    return sys.nowNs() - t0;
}

/// The total and idle (idle + iowait) ticks from /proc/stat's first line.
fn parseStat(stat: []const u8) ?[2]u64 {
    const line = stat[0 .. std.mem.indexOfScalar(u8, stat, '\n') orelse stat.len];
    if (!std.mem.startsWith(u8, line, "cpu ")) return null;
    var fields = std.mem.tokenizeScalar(u8, line[4..], ' ');
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    while (fields.next()) |f| : (i += 1) {
        // user nice system idle iowait irq softirq steal (guest time is
        // already in user).
        if (i >= 8) break;
        const v = std.fmt.parseInt(u64, f, 10) catch return null;
        total += v;
        if (i == 3 or i == 4) idle += v;
    }
    return .{ total, idle };
}

/// A process's user + system ticks from /proc/<pid>/stat.
fn processTicks(stat: []const u8) ?u64 {
    // The command name is in parentheses and may contain spaces.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    var i: usize = 0;
    var ticks: u64 = 0;
    // Fields from the state (3rd); utime and stime are the 14th and 15th.
    while (fields.next()) |f| : (i += 1) {
        if (i == 11 or i == 12) ticks += std.fmt.parseInt(u64, f, 10) catch return null;
        if (i == 12) return ticks;
    }
    return null;
}

test "proc parsing" {
    const stat = "cpu  100 5 50 800 20 3 2 0 0 0\ncpu0 100 5 50 800 20 3 2 0 0 0\n";
    try std.testing.expectEqual([2]u64{ 980, 820 }, parseStat(stat).?);
    const self = "25 (stardust demo) R 24 25 0 0 -1 4194304 120 0 0 0 731 42 0 0 20 0 1 0 512 9000000 400";
    try std.testing.expectEqual(@as(u64, 773), processTicks(self).?);
    try std.testing.expect(spinNs() > 0);
}

test "speed is relative to the first sample" {
    var m: Monitor = .{};
    const first = m.sample();
    try std.testing.expect(first.speed > 99 and first.speed < 101);
    try std.testing.expect(m.baseline_ns > 0);
    // Half as fast.
    m.baseline_ns /= 2;
    const s = m.sample();
    try std.testing.expect(s.speed > 30 and s.speed < 70);
}
