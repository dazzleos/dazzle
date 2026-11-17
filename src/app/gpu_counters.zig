//! The GPU's performance counters, counting in an app's windows' frames
//! (on the Pi 0 to 3's GPU, which has them): what its shader processors
//! spent their time on, and how many triangles and pixels it drew, for
//! the log. Apps say where their frames' time goes with it (Motu while
//! "What is drawn" is shown, Maps while it draws).

const std = @import("std");
const sys = @import("sys");
const vc4 = @import("vc4");
const window = @import("window.zig");

pub const Counting = struct {
    dev: vc4.Device,
    id: ?u32 = null,

    /// What is counted.
    pub const counted: [vc4.device.max_counters]vc4.device.PerfCounter = .{
        .fep_valid_prims_render,
        .fep_valid_quads,
        .tlb_quads_written_to_color_buf,
        .qpu_idle_cycles,
        .qpu_vertex_coord_shading_cycles,
        .qpu_fragment_shading_cycles,
        .qpu_valid_instruction_cycles,
        .qpu_waiting_tmus_cycles,
        .qpu_waiting_scoreboard_cycles,
        .qpu_waiting_varyings_cycles,
        .tmu_texture_quads,
        .tmu_texture_cache_misses,
        .qpu_inst_cache_misses,
        .qpu_uniform_cache_hits,
        .qpu_uniform_cache_misses,
        .qpu_inst_cache_hits,
    };

    pub const Counts = [counted.len]u64;

    /// Counts the windows' frames from now, or stops.
    pub fn count(c: *Counting, on: bool) void {
        if (c.id) |id| c.dev.destroyPerfmon(id);
        c.id = null;
        if (on and !c.dev.is_v3d) c.id = c.dev.createPerfmon(&counted) catch null;
        window.perfmon_id = c.id orelse 0;
    }

    /// What was counted since `count` (in the frames the GPU has finished),
    /// starting again from 0.
    pub fn take(c: *Counting, out: *Counts) bool {
        const id = c.id orelse return false;
        c.dev.perfmonValues(id, out) catch return false;
        c.count(true);
        return true;
    }
};

/// Says (as `name`) what the counters say of `frames` frames, per frame:
/// the shader processors' (QPUs') time on vertices and on pixels, idle,
/// and waiting; the triangles and pixels; textures and caches.
pub fn report(name: []const u8, counts: *const Counting.Counts, frames: u32) void {
    const n: f64 = @floatFromInt(@max(frames, 1));
    var v: [Counting.counted.len]f64 = undefined;
    for (counts, &v) |c, *p| p.* = @as(f64, @floatFromInt(c)) / n;
    const at = struct {
        fn f(vals: []const f64, comptime c: vc4.device.PerfCounter) f64 {
            // Counted, or this does not build.
            const i = comptime std.mem.indexOfScalar(vc4.device.PerfCounter, &Counting.counted, c).?;
            return vals[i];
        }
    }.f;
    const idle = at(&v, .qpu_idle_cycles);
    const vertex = at(&v, .qpu_vertex_coord_shading_cycles);
    const fragment = at(&v, .qpu_fragment_shading_cycles);
    const all = @max(idle + vertex + fragment, 1);
    sys.print("{s}: GPU counters per frame: QPU cycles {d:.1}M (vertices {d:.0}%, pixels {d:.0}%, idle {d:.0}%), running instructions {d:.1}M, waiting for textures {d:.1}M, for the scoreboard {d:.1}M, for varyings {d:.1}M\n", .{
        name,                                        all / 1e6,                               100 * vertex / all,                             100 * fragment / all,
        100 * idle / all,                            at(&v, .qpu_valid_instruction_cycles) / 1e6, at(&v, .qpu_waiting_tmus_cycles) / 1e6, at(&v, .qpu_waiting_scoreboard_cycles) / 1e6,
        at(&v, .qpu_waiting_varyings_cycles) / 1e6,
    });
    sys.print("{s}: GPU counters per frame: triangles drawn {d:.0}k; quads {d:.0}k, written {d:.0}k; texture quads {d:.0}k, texture cache misses {d:.0}k; instruction cache {d:.0}k hits, {d:.0}k misses; uniform cache {d:.0}k hits, {d:.0}k misses\n", .{
        name,
        at(&v, .fep_valid_prims_render) / 1e3,
        at(&v, .fep_valid_quads) / 1e3,
        at(&v, .tlb_quads_written_to_color_buf) / 1e3,
        at(&v, .tmu_texture_quads) / 1e3,
        at(&v, .tmu_texture_cache_misses) / 1e3,
        at(&v, .qpu_inst_cache_hits) / 1e3,
        at(&v, .qpu_inst_cache_misses) / 1e3,
        at(&v, .qpu_uniform_cache_hits) / 1e3,
        at(&v, .qpu_uniform_cache_misses) / 1e3,
    });
}
