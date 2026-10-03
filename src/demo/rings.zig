//! Expanding, fading rings where the pointer moves and clicks, drawn behind
//! the cube. Without blending in the GL layer, "fading" means moving the
//! colour towards the background.

const std = @import("std");
const gles = @import("gles");
const cube = @import("cube.zig");

const gl = gles.gl;

const vertex_shader =
    \\attribute vec2 pos;
    \\attribute vec3 color;
    \\uniform vec2 scale;
    \\varying vec3 v_color;
    \\void main() {
    \\    gl_Position = vec4(pos * scale + vec2(-1.0, 1.0), 0.0, 1.0);
    \\    v_color = color;
    \\}
;

const fragment_shader =
    \\precision mediump float;
    \\varying vec3 v_color;
    \\void main() {
    \\    gl_FragColor = vec4(v_color, 1.0);
    \\}
;

const max_rings = 32;
const segments = 48;
/// Each ring is a triangle strip, joined to the next by two repeated
/// vertices (degenerate triangles), so all rings are one draw.
const vertices_per_ring = 2 * (segments + 1) + 2;
/// x, y, r, g, b.
const floats_per_vertex = 5;

pub const Kind = enum {
    /// A button press: big and slow.
    click,
    /// Pointer motion: small and quick.
    trail,
};

const Ring = struct {
    x: f32,
    y: f32,
    born: u64,
    kind: Kind,
    color: [3]f32,
};

pub const Rings = struct {
    program: gl.GLuint,
    scale_loc: gl.GLint,
    background: [3]f32,
    rings: [max_rings]Ring = undefined,
    len: usize = 0,
    vertices: [max_rings * vertices_per_ring * floats_per_vertex]f32 = undefined,
    /// When the last trail ring started, to space them out.
    last_trail: u64 = 0,

    pub fn init(background: u32) !Rings {
        const program = try cube.buildProgram(vertex_shader, fragment_shader, &.{ "pos", "color" });
        return .{
            .program = program,
            .scale_loc = gl.glGetUniformLocation(program, "scale"),
            .background = rgb(background),
        };
    }

    /// Starts a ring at (`x`, `y`) in window pixels.
    pub fn add(r: *Rings, now: u64, x: f32, y: f32, kind: Kind, color: u32) void {
        if (kind == .trail) {
            if (now -| r.last_trail < trail_interval) return;
            r.last_trail = now;
        }
        // Full: the oldest goes.
        if (r.len == max_rings) {
            std.mem.copyForwards(Ring, r.rings[0 .. max_rings - 1], r.rings[1..max_rings]);
            r.len -= 1;
        }
        r.rings[r.len] = .{ .x = x, .y = y, .born = now, .kind = kind, .color = rgb(color) };
        r.len += 1;
    }

    pub fn draw(r: *Rings, now: u64, width: u32, height: u32) void {
        // Drop finished rings.
        var kept: usize = 0;
        for (r.rings[0..r.len]) |ring| if (now -| ring.born < lifetime(ring.kind)) {
            r.rings[kept] = ring;
            kept += 1;
        };
        r.len = kept;
        if (r.len == 0) return;

        const unit = @as(f32, @floatFromInt(@min(width, height))) / 1080;
        var n: usize = 0;
        for (r.rings[0..r.len]) |ring| n = r.addRing(n, ring, now, unit);

        gl.glUseProgram(r.program);
        gl.glDisable(gl.GL_DEPTH_TEST);
        gl.glDisable(gl.GL_CULL_FACE);
        gl.glUniform2f(r.scale_loc, 2 / @as(f32, @floatFromInt(width)), -2 / @as(f32, @floatFromInt(height)));
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
        gl.glEnableVertexAttribArray(0);
        gl.glEnableVertexAttribArray(1);
        const stride = floats_per_vertex * @sizeOf(f32);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, &r.vertices);
        gl.glVertexAttribPointer(1, 3, gl.GL_FLOAT, gl.GL_FALSE, stride, &r.vertices[2]);
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, @intCast(n));
    }

    /// Writes a ring's vertices from vertex `n`; returns the new count.
    fn addRing(r: *Rings, n: usize, ring: Ring, now: u64, unit: f32) usize {
        const t = @as(f32, @floatFromInt(now -| ring.born)) / @as(f32, @floatFromInt(lifetime(ring.kind)));
        // Fast at first, slowing down.
        const grow = 1 - (1 - t) * (1 - t);
        const radius: f32, const thickness: f32 = switch (ring.kind) {
            .click => .{ 12 + 150 * grow, 8 * (1 - t) + 2 },
            .trail => .{ 4 + 36 * grow, 3 * (1 - t) + 1 },
        };
        var color: [3]f32 = undefined;
        for (&color, ring.color, r.background) |*c, from, to| c.* = from + (to - from) * t;

        var at = n;
        const inner = (radius - thickness / 2) * unit;
        const outer = (radius + thickness / 2) * unit;
        for (0..segments + 1) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.tau / segments;
            const c = @cos(a);
            const s = @sin(a);
            at = r.vertex(at, ring.x + c * outer, ring.y + s * outer, color);
            if (i == 0 and n > 0) at = r.vertex(at, ring.x + c * outer, ring.y + s * outer, color);
            at = r.vertex(at, ring.x + c * inner, ring.y + s * inner, color);
        }
        // Repeat the last vertex; the next ring repeats its first.
        const last = r.vertices[(at - 1) * floats_per_vertex ..][0..floats_per_vertex];
        at = r.vertex(at, last[0], last[1], color);
        return at;
    }

    fn vertex(r: *Rings, n: usize, x: f32, y: f32, color: [3]f32) usize {
        r.vertices[n * floats_per_vertex ..][0..floats_per_vertex].* = .{ x, y, color[0], color[1], color[2] };
        return n + 1;
    }
};

/// How often pointer motion leaves a ring.
const trail_interval = 40 * std.time.ns_per_ms;

fn lifetime(kind: Kind) u64 {
    return switch (kind) {
        .click => 900 * std.time.ns_per_ms,
        .trail => 500 * std.time.ns_per_ms,
    };
}

fn rgb(argb: u32) [3]f32 {
    return .{
        @as(f32, @floatFromInt(argb >> 16 & 0xff)) / 255,
        @as(f32, @floatFromInt(argb >> 8 & 0xff)) / 255,
        @as(f32, @floatFromInt(argb & 0xff)) / 255,
    };
}

test "rings fit their vertex buffer and expire" {
    var r: Rings = .{ .program = 0, .scale_loc = 0, .background = .{ 0, 0, 0 } };
    for (0..max_rings + 5) |i| r.add(@as(u64, i) * trail_interval, 10, 10, if (i % 2 == 0) .click else .trail, 0xffffffff);
    try std.testing.expectEqual(@as(usize, max_rings), r.len);
    var n: usize = 0;
    for (r.rings[0..r.len]) |ring| n = r.addRing(n, ring, ring.born, 1);
    // One extra vertex per ring after the first joins it to the previous.
    try std.testing.expectEqual(max_rings * vertices_per_ring - 1, n);
    // A ring starts in its own colour and ends in the background's.
    try std.testing.expectEqual(@as(f32, 1), r.vertices[2]);
    _ = r.addRing(0, r.rings[0], r.rings[0].born + lifetime(r.rings[0].kind), 1);
    try std.testing.expectEqual(@as(f32, 0), r.vertices[2]);
}
