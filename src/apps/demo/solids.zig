//! The Platonic solids, spinning: tinted faces, optionally lit (with flat
//! normals, from a fixed light) and textured with a checkerboard,
//! depth-tested and back-face culled, drawn with the vc4 API and their
//! shader (shaders/polyhedron.zig).
//!
//! Each solid's faces are found from its corners: they are the planes
//! through three corners with every corner on one side.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");

pub const Shape = enum {
    tetrahedron,
    cube,
    octahedron,
    dodecahedron,
    icosahedron,

    /// Triangles in its mesh (see the test).
    pub fn triangles(s: Shape) u32 {
        return switch (s) {
            .tetrahedron => 4,
            .cube => 12,
            .octahedron => 8,
            .dodecahedron => 36,
            .icosahedron => 20,
        };
    }

    pub fn name(s: Shape) []const u8 {
        return switch (s) {
            .tetrahedron => "Tetrahedron",
            .cube => "Cube",
            .octahedron => "Octahedron",
            .dodecahedron => "Dodecahedron",
            .icosahedron => "Icosahedron",
        };
    }
};

pub const shapes = std.enums.values(Shape);

const phi: f32 = (1.0 + @sqrt(5.0)) / 2.0;

/// Each solid's corners, up to scale.
fn corners(shape: Shape) []const [3]f32 {
    const ip = 1 / phi;
    return switch (shape) {
        .tetrahedron => &.{ .{ 1, 1, 1 }, .{ 1, -1, -1 }, .{ -1, 1, -1 }, .{ -1, -1, 1 } },
        .cube => &.{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 }, .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ -1, 1, 1 }, .{ 1, 1, 1 } },
        .octahedron => &.{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } },
        .dodecahedron => &.{
            .{ -1, -1, -1 }, .{ 1, -1, -1 },   .{ -1, 1, -1 },   .{ 1, 1, -1 },     .{ -1, -1, 1 },  .{ 1, -1, 1 },    .{ -1, 1, 1 },    .{ 1, 1, 1 },
            .{ 0, ip, phi }, .{ 0, -ip, phi }, .{ 0, ip, -phi }, .{ 0, -ip, -phi }, .{ ip, phi, 0 }, .{ -ip, phi, 0 }, .{ ip, -phi, 0 }, .{ -ip, -phi, 0 },
            .{ phi, 0, ip }, .{ -phi, 0, ip }, .{ phi, 0, -ip }, .{ -phi, 0, -ip },
        },
        .icosahedron => &.{
            .{ 0, 1, phi }, .{ 0, -1, phi }, .{ 0, 1, -phi }, .{ 0, -1, -phi },
            .{ 1, phi, 0 }, .{ -1, phi, 0 }, .{ 1, -phi, 0 }, .{ -1, -phi, 0 },
            .{ phi, 0, 1 }, .{ -phi, 0, 1 }, .{ phi, 0, -1 }, .{ -phi, 0, -1 },
        },
    };
}

/// Every solid's corners are this far from its centre (the cube's, with
/// its corners at ±1).
pub const radius: f32 = @sqrt(3.0);

pub const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    tint: [3]f32,
    normal: [3]f32,
};

/// Face tints: pure primaries and secondaries, so colour errors stand out.
const tints = [_][3]f32{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 1, 0 }, .{ 1, 0, 1 }, .{ 0, 1, 1 } };

pub const Mesh = struct {
    /// Each face's corners (its own, for its normal), wound counter-clockwise
    /// seen from outside.
    vertices: []Vertex,
    /// Triangles, fanned across each face.
    indices: []u16,

    pub fn deinit(m: Mesh, gpa: std.mem.Allocator) void {
        gpa.free(m.vertices);
        gpa.free(m.indices);
    }

    pub fn triangles(m: Mesh) usize {
        return m.indices.len / 3;
    }
};

const V3 = @Vector(3, f32);

fn dot(a: V3, b: V3) f32 {
    return @reduce(.Add, a * b);
}

fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn normalize(a: V3) V3 {
    return a / @as(V3, @splat(@sqrt(dot(a, a))));
}

/// The solid's faces as triangles.
pub fn mesh(gpa: std.mem.Allocator, shape: Shape) !Mesh {
    const raw = corners(shape);
    var pts: [20]V3 = undefined;
    for (raw, pts[0..raw.len]) |c, *p| p.* = normalize(c) * @as(V3, @splat(radius));
    const ps = pts[0..raw.len];
    const eps = 1e-3;

    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(gpa);
    var indices: std.ArrayList(u16) = .empty;
    errdefer indices.deinit(gpa);
    var planes: std.ArrayList(V3) = .empty;
    defer planes.deinit(gpa);

    for (0..ps.len) |i| for (i + 1..ps.len) |j| for (j + 1..ps.len) |k| {
        const c = cross(ps[j] - ps[i], ps[k] - ps[i]);
        if (dot(c, c) < eps) continue;
        var n = normalize(c);
        var d = dot(n, ps[i]);
        if (d < 0) {
            n = -n;
            d = -d;
        }
        // A face: every corner on its inner side, and not found already.
        const outer = for (ps) |p| {
            if (dot(n, p) > d + eps) break false;
        } else true;
        if (!outer) continue;
        const known = for (planes.items) |q| {
            if (dot(q, n) > 1 - eps) break true;
        } else false;
        if (known) continue;
        try planes.append(gpa, n);

        // Its corners, in order around it.
        var face: [5]V3 = undefined;
        var count: usize = 0;
        for (ps) |p| if (@abs(dot(n, p) - d) < eps) {
            face[count] = p;
            count += 1;
        };
        var centre: V3 = @splat(0);
        for (face[0..count]) |p| centre += p;
        centre /= @as(V3, @splat(@floatFromInt(count)));
        const u = normalize(face[0] - centre);
        const w = cross(n, u);
        const Angle = struct {
            u: V3,
            w: V3,
            c: V3,
            fn of(a: @This(), p: V3) f32 {
                return std.math.atan2(dot(p - a.c, a.w), dot(p - a.c, a.u));
            }
            fn less(a: @This(), p: V3, q: V3) bool {
                return a.of(p) < a.of(q);
            }
        };
        const angle: Angle = .{ .u = u, .w = w, .c = centre };
        std.mem.sort(V3, face[0..count], angle, Angle.less);

        // The checkerboard spans each face (0 to 2 across it).
        const r = @sqrt(dot(face[0] - centre, face[0] - centre));
        const first: u16 = @intCast(vertices.items.len);
        const tint = tints[(planes.items.len - 1) % tints.len];
        for (face[0..count]) |p| try vertices.append(gpa, .{
            .pos = p,
            .uv = .{ dot(p - centre, u) / r + 1, dot(p - centre, w) / r + 1 },
            .tint = tint,
            .normal = n,
        });
        for (1..count - 1) |t| try indices.appendSlice(gpa, &.{ first, first + @as(u16, @intCast(t)), first + @as(u16, @intCast(t + 1)) });
    };
    return .{ .vertices = try vertices.toOwnedSlice(gpa), .indices = try indices.toOwnedSlice(gpa) };
}

const texture_size = 128;

/// Draw options.
pub const Look = struct {
    lighting: bool = true,
    texturing: bool = true,
};

pub const Solids = struct {
    pipeline: shader.Pipeline,
    vbo: vc4.Bo,
    ibo: vc4.Bo,
    texture: vc4.Bo,
    parts: [shapes.len]Part,

    /// Where a solid is in the buffers.
    const Part = struct { first_vertex: u32, vertex_count: u32, first_index: u32, index_count: u32 };

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !Solids {
        const program = shader.Program.decode(@embedFile("polyhedron.shader")) catch unreachable;
        var pipeline = try shader.Pipeline.init(gpa, dev, program, .{
            .vertex_stride = @sizeOf(Vertex),
            .attributes = &.{
                .{ .location = 0, .offset = @offsetOf(Vertex, "pos") },
                .{ .location = 1, .offset = @offsetOf(Vertex, "uv") },
                .{ .location = 2, .offset = @offsetOf(Vertex, "tint") },
                .{ .location = 3, .offset = @offsetOf(Vertex, "normal") },
            },
            .cull = .back,
        });
        errdefer pipeline.deinit(dev);

        // All the solids, one after another in one vertex and one index
        // buffer.
        var meshes: [shapes.len]Mesh = undefined;
        var made: usize = 0;
        defer for (meshes[0..made]) |m| m.deinit(gpa);
        var parts: [shapes.len]Part = undefined;
        var nv: u32 = 0;
        var ni: u32 = 0;
        for (shapes, &meshes, &parts) |s, *m, *part| {
            m.* = try mesh(gpa, s);
            made += 1;
            part.* = .{ .first_vertex = nv, .vertex_count = @intCast(m.vertices.len), .first_index = ni, .index_count = @intCast(m.indices.len) };
            nv += part.vertex_count;
            ni += part.index_count;
        }
        const vbo = try dev.createBo(nv * @sizeOf(Vertex));
        errdefer dev.destroyBo(vbo);
        const ibo = try dev.createBo(ni * 2);
        errdefer dev.destroyBo(ibo);
        for (meshes, parts) |m, part| {
            @memcpy(vbo.map[part.first_vertex * @sizeOf(Vertex) ..][0 .. m.vertices.len * @sizeOf(Vertex)], std.mem.sliceAsBytes(m.vertices));
            @memcpy(ibo.map[part.first_index * 2 ..][0 .. m.indices.len * 2], std.mem.sliceAsBytes(m.indices));
        }

        // A white and dark grey checkerboard: with the pure face tints,
        // white squares show each tint at full strength.
        var pixels: [texture_size * texture_size]u32 = undefined;
        for (0..texture_size) |y| for (0..texture_size) |x| {
            pixels[y * texture_size + x] = if (((x / 16) + (y / 16)) % 2 == 0) 0xffffffff else 0xff404040;
        };
        const texture = try dev.createBo(vc4.texture.imageSize(texture_size, texture_size));
        vc4.texture.upload(texture.map, &pixels, texture_size, texture_size);
        return .{ .pipeline = pipeline, .vbo = vbo, .ibo = ibo, .texture = texture, .parts = parts };
    }

    /// Draws `shape` at `time` seconds into its rotation, filling
    /// `viewport` (and clipped to `scissor`).
    pub fn draw(s: *Solids, frame: *vc4.render.Frame, viewport: vc4.render.Viewport, scissor: ?vc4.render.Viewport, time: f32, shape: Shape, look: Look) !void {
        var uniforms: [32]f32 = undefined;
        uniforms[0..16].* = mvp(viewport.width, viewport.height, time);
        // The rotation's columns (their w is 0).
        uniforms[16..28].* = model(time)[0..12].*;
        uniforms[28..32].* = .{ @floatFromInt(@intFromBool(look.lighting)), @floatFromInt(@intFromBool(look.texturing)), 0, 0 };
        s.pipeline.setUniforms(std.mem.asBytes(&uniforms));
        const part = s.parts[@intFromEnum(shape)];
        try s.pipeline.draw(frame, .{
            .viewport = viewport,
            .scissor = scissor,
            .vertices = s.vbo.handle,
            .vertex_offset = part.first_vertex * @sizeOf(Vertex),
            .count = part.index_count,
            .indices = .{ .handle = s.ibo.handle, .offset = part.first_index * 2, .max_index = part.vertex_count - 1 },
            .texture = .{ .handle = s.texture.handle, .config = .{ .width = texture_size, .height = texture_size } },
        });
    }
};

// --- Matrices (column-major, as the shader expects) --------------------------------

pub const Mat4 = [16]f32;

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[col * 4 + k];
        out[col * 4 + row] = sum;
    };
    return out;
}

pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy / 2.0);
    var m: Mat4 = @splat(0);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = 2 * far * near / (near - far);
    return m;
}

pub fn translation(x: f32, y: f32, z: f32) Mat4 {
    var m: Mat4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    m[12] = x;
    m[13] = y;
    m[14] = z;
    return m;
}

pub fn rotationX(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 };
}

pub fn rotationY(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 };
}

/// The solid's rotation at `time` seconds.
pub fn model(time: f32) Mat4 {
    return mul(rotationX(time * 0.7), rotationY(time));
}

/// How far the camera is from the solids' centre.
const camera_distance = 6.0;

/// The camera: projection and view, for a viewport of this size.
pub fn viewProjection(width: u32, height: u32) Mat4 {
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    // Far enough back that the solids clear the panel on the left (see
    // view.zig's test).
    const view = translation(0, 0, -camera_distance);
    return mul(perspective(std.math.degreesToRadians(50.0), aspect, 1.0, 20.0), view);
}

pub fn mvp(width: u32, height: u32, time: f32) Mat4 {
    return mul(viewProjection(width, height), model(time));
}

/// Where any solid can appear in a viewport of this size, however it is
/// turned: the outline of the sphere through its corners. The sphere is
/// on the camera's axis, so its outline is a circle (an ellipse in pixels)
/// around the centre, of half-height f·r/√(d² − r²) in clip space (f from
/// the field of view, d the distance). Pixels from the viewport's top left:
/// x, y, width, height.
pub fn screenBounds(width: u32, height: u32) [4]f32 {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const f = 1.0 / @tan(std.math.degreesToRadians(50.0) / 2.0);
    const d = camera_distance;
    const half_y = f * radius / @sqrt(d * d - radius * radius);
    const half_x = half_y * h / w;
    // A pixel for the edges' rounding.
    const x0 = @max(@floor((1 - half_x) / 2 * w) - 1, 0);
    const y0 = @max(@floor((1 - half_y) / 2 * h) - 1, 0);
    const x1 = @min(@ceil((1 + half_x) / 2 * w) + 1, w);
    const y1 = @min(@ceil((1 + half_y) / 2 * h) + 1, h);
    return .{ x0, y0, x1 - x0, y1 - y0 };
}

const testing = std.testing;

test "each solid has its faces, wound counter-clockwise seen from outside" {
    const want = [_][3]usize{ .{ 4, 3, 4 }, .{ 6, 4, 12 }, .{ 8, 3, 8 }, .{ 12, 5, 36 }, .{ 20, 3, 20 } };
    for (shapes, want) |s, w| {
        const m = try mesh(testing.allocator, s);
        defer m.deinit(testing.allocator);
        // Faces times corners per face; triangles fanned across them.
        try testing.expectEqual(w[0] * w[1], m.vertices.len);
        try testing.expectEqual(w[2], m.triangles());
        try testing.expectEqual(w[2], s.triangles());
        for (0..m.triangles()) |t| {
            const a: V3 = m.vertices[m.indices[t * 3]].pos;
            const b: V3 = m.vertices[m.indices[t * 3 + 1]].pos;
            const c: V3 = m.vertices[m.indices[t * 3 + 2]].pos;
            const n = cross(b - a, c - a);
            // Facing out, along the face's normal.
            try testing.expect(dot(n, (a + b + c) / @as(V3, @splat(3))) > 0);
            try testing.expect(dot(normalize(n), m.vertices[m.indices[t * 3]].normal) > 0.999);
        }
        for (m.vertices) |v| {
            try testing.expectApproxEqAbs(@as(f32, radius), @sqrt(dot(v.pos, v.pos)), 1e-4);
            try testing.expect(v.uv[0] >= -1e-4 and v.uv[0] <= 2.0001 and v.uv[1] >= -1e-4 and v.uv[1] <= 2.0001);
        }
    }
}

test "the solids stay in front of the camera" {
    for ([_]f32{ 0, 1, 2.5, 4 }) |t| {
        const m = mvp(1920, 1080, t);
        for (shapes) |s| for (corners(s)) |c| {
            const v = normalize(c) * @as(V3, @splat(radius));
            const w = v[0] * m[3] + v[1] * m[7] + v[2] * m[11] + m[15];
            try testing.expect(w > 2.0);
        };
    }
}

test "every solid stays within its screen bounds" {
    for ([_][2]u32{ .{ 1920, 1036 }, .{ 640, 480 } }) |size| {
        const b = screenBounds(size[0], size[1]);
        try testing.expect(b[2] < @as(f32, @floatFromInt(size[0])) and b[3] < @as(f32, @floatFromInt(size[1])));
        for (shapes) |s| {
            const msh = try mesh(testing.allocator, s);
            defer msh.deinit(testing.allocator);
            var t: f32 = 0;
            while (t < 10) : (t += 0.1) {
                const m = mvp(size[0], size[1], t);
                for (msh.vertices) |v| {
                    const p = v.pos;
                    const cw = p[0] * m[3] + p[1] * m[7] + p[2] * m[11] + m[15];
                    const x = ((p[0] * m[0] + p[1] * m[4] + p[2] * m[8] + m[12]) / cw + 1) / 2 * @as(f32, @floatFromInt(size[0]));
                    const y = (1 - (p[0] * m[1] + p[1] * m[5] + p[2] * m[9] + m[13]) / cw) / 2 * @as(f32, @floatFromInt(size[1]));
                    try testing.expect(x >= b[0] and x <= b[0] + b[2] and y >= b[1] and y <= b[1] + b[3]);
                }
            }
        }
    }
}
