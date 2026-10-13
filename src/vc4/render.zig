//! Builds DRM_IOCTL_VC4_SUBMIT_CL jobs: one frame (one render target) with
//! any number of draw calls.
//!
//! The kernel refers to buffers by their index in the job's `bo_handles`
//! array, which `Frame` builds from the GEM handles each draw uses, so
//! callers deal in handles only.

const std = @import("std");
const cl = @import("cl.zig");
const compiler = @import("compiler.zig");
const texture = @import("texture.zig");
const Format = @import("format.zig").Format;
const device = @import("device.zig");
const v3d_cl = @import("v3d_cl.zig");

pub const ShaderBinding = struct {
    /// GEM handle of the shader BO.
    handle: u32,
    /// What each uniform stream word holds (from the compiler).
    layout: []const compiler.UniformKind,
    /// Values for `.user` entries, by index.
    user: []const u32 = &.{},
};

pub const Texture = struct {
    handle: u32,
    config: texture.Config,
};

pub const Attribute = struct {
    /// GEM handle of the vertex buffer.
    handle: u32,
    offset: u32,
    /// Bytes per vertex (up to 64).
    size: u8,
    stride: u8,
    vs_vpm_offset: u8,
    cs_vpm_offset: u8,
};

pub const Indices = struct {
    handle: u32,
    /// Byte offset of the first index.
    offset: u32,
    /// The largest index used, so the kernel can bounds-check attributes.
    max_index: u32,
    type: enum { u8, u16 } = .u16,
};

/// The area of the target that clip space maps to, in pixels with y = 0 at
/// the top.
pub const Viewport = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    /// Viewport half-size in 1/16ths of a pixel, as the vertex shaders and
    /// the clipper want it. Y is negated so that +Y in clip space points up.
    pub fn scale(v: Viewport) [2]f32 {
        return .{
            @as(f32, @floatFromInt(v.width)) / 2.0 * 16.0,
            -@as(f32, @floatFromInt(v.height)) / 2.0 * 16.0,
        };
    }

    pub fn scaleBits(v: Viewport) [2]u32 {
        const s = v.scale();
        return .{ @bitCast(s[0]), @bitCast(s[1]) };
    }
};

pub const Draw = struct {
    fs: ShaderBinding,
    vs: ShaderBinding,
    cs: ShaderBinding,
    fs_num_varyings: u8,
    /// The fragment shader runs two threads per QPU (it was compiled
    /// threaded: `compiler.Compiled.threaded`).
    fs_threaded: bool = false,
    attributes: []const Attribute,
    vs_attribute_mask: u8,
    vs_attributes_size: u8,
    cs_attribute_mask: u8,
    cs_attributes_size: u8,
    primitive: cl.PrimitiveMode = .triangles,
    /// Vertex count (or index count with `indices`).
    count: u32,
    /// First vertex for array draws.
    first: u32 = 0,
    indices: ?Indices = null,
    config: cl.Bcl.Config = .{},
    /// Defaults to the whole target.
    viewport: ?Viewport = null,
    /// Further limits rendering to this rectangle (y = 0 at the top).
    scissor: ?Viewport = null,
    /// The fragment shader's textures, by slot (see compiler.Shader.texture).
    texture: ?Texture = null,
    texture1: ?Texture = null,
    texture2: ?Texture = null,

    fn unit(d: *const Draw, slot: u8) Texture {
        return switch (slot) {
            0 => d.texture.?,
            1 => d.texture1.?,
            else => d.texture2.?,
        };
    }
};

/// A colour buffer: the tile buffer is stored to it (and, to keep what
/// it had, loaded from it) in its format. Depth lives only in the tile
/// buffer: it is cleared to `clear_z` at the start of each tile and never
/// stored.
pub const Target = struct {
    handle: u32,
    width: u16,
    height: u16,
    /// Linear (raster order, for scanout), or the T or LT tiled layouts the
    /// texture unit reads (see texture.zig), so the result can be sampled
    /// as a texture of the same size.
    tiling: cl.Tiling = .linear,
    format: Format = .xrgb8888,

    /// The tiled layout the texture unit expects for an image of this size.
    pub fn textureTiling(format: Format, width: u32, height: u32) cl.Tiling {
        return if (texture.isLtOf(format, width, height)) .lt else .t;
    }

    /// Byte stride the hardware uses for linear render targets: the width
    /// rounded up to a micro-tile.
    pub fn pitch(format: Format, width: u16) u32 {
        return std.mem.alignForward(u32, width, format.utileWidth()) * format.bytesPerPixel();
    }

    pub fn fullViewport(t: Target) Viewport {
        return .{ .x = 0, .y = 0, .width = t.width, .height = t.height };
    }
};

pub const Load = union(enum) {
    /// Start from a solid colour (0xAARRGGBB).
    clear: u32,
    /// Keep the target's current contents.
    keep,
};

/// Buffers a frame can use (a 3D scene drawn from many buffers, and the
/// UI over it).
pub const max_bos = 256;

pub const Error = error{FrameFull};

/// Renders a frame that is too full for what is still to be drawn, waiting
/// for the GPU; drawing then goes on in it (see `Frame.again`).
pub const Flush = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, frame: *Frame) anyerror!void,

    pub fn flush(fl: Flush, frame: *Frame) !void {
        try fl.run(fl.ctx, frame);
        frame.again();
    }
};

/// A frame being recorded. `submit` points into the frame's own buffers,
/// so a Frame must not be moved between `begin` and submission. It is
/// large; keep it in static or heap memory rather than on the stack, and
/// declare it `undefined` (`begin` initialises it) so it costs nothing in
/// the binary.
pub const Frame = struct {
    bcl_buf: [32 * 1024]u8 = undefined,
    bin: cl.Bcl = undefined,
    rec_buf: [32 * 1024]u8 = undefined,
    rec: cl.Writer = undefined,
    rec_count: u32 = 0,
    uniforms: [32 * 1024]u32 = undefined,
    uniforms_len: usize = 0,
    bo_handles: [max_bos]u32 = undefined,
    bo_count: u32 = 0,
    target: Target = undefined,
    load: Load = .keep,
    clear_z: u32 = 0xffffff,
    draws: u32 = 0,
    submit: device.SubmitCl = .{},
    /// Tile ranges to render (inclusive: x0, y0, x1, y1); none means all.
    regions: [max_regions][4]u8 = undefined,
    region_count: usize = 0,
    /// Set by `limitTo` with nothing to draw: `regionCount` is then 0.
    limited_to_nothing: bool = false,
    /// 4x multisampled (antialiased), each pixel's samples averaged as
    /// tiles are stored: see `beginMultisampled`.
    msaa: bool = false,
    v3d_draws: [max_v3d_draws]V3dDraw = undefined,

    pub const max_regions = 4;
    pub const max_v3d_draws = 768;

    pub const V3dDraw = struct {
        x0: u16,
        y0: u16,
        width: u16,
        height: u16,
        vp: Viewport,
        config: cl.Bcl.Config,
        fs_handle: u32,
        vs_handle: u32,
        cs_handle: u32,
        fs_num_varyings: u8,
        fs_layout: []const compiler.UniformKind,
        vs_layout: []const compiler.UniformKind,
        cs_layout: []const compiler.UniformKind,
        uniforms_start: u32,
        attrs: [8]Attribute,
        attrs_len: u8,
        cs_attribute_mask: u8,
        primitive: cl.PrimitiveMode,
        count: u32,
        first: u32,
        indices: ?Indices,
        textures: [3]?Texture,
    };

    pub fn begin(f: *Frame, target: Target, load: Load) void {
        f.beginWith(target, load, false);
    }

    /// Begins a frame with 4x multisampling: edges are antialiased. Each
    /// pixel has four samples in the tile buffer (so tiles are 32 pixels
    /// square, four times as many), which are averaged as each tile is
    /// stored: the fragment shaders still run once a pixel, and as many
    /// bytes are written as without it. Programs that blend use their
    /// multisampled fragment shaders (see shader.Program.fs_ms). It starts
    /// from a colour: a tile buffer of samples cannot be loaded from an
    /// image of pixels.
    pub fn beginMultisampled(f: *Frame, target: Target, clear: u32) void {
        f.beginWith(target, .{ .clear = clear }, true);
    }

    fn beginWith(f: *Frame, target: Target, load: Load, msaa: bool) void {
        f.msaa = msaa;
        f.bin = .init(&f.bcl_buf);
        f.rec = .init(&f.rec_buf);
        f.rec_count = 0;
        f.uniforms_len = 0;
        f.bo_count = 0;
        f.target = target;
        f.load = load;
        f.clear_z = 0xffffff;
        f.draws = 0;
        f.region_count = 0;
        f.limited_to_nothing = false;
        _ = f.index(target.handle) catch unreachable;

        const tiles = f.tileCounts();
        f.bin.tileBinningModeConfig(@intCast(tiles[0]), @intCast(tiles[1]), msaa);
        f.bin.startTileBinning();
        f.bin.primitiveListFormat();
    }

    /// Starts the frame again once it has been rendered, on the same
    /// target and parts of it, keeping what it drew.
    pub fn again(f: *Frame) void {
        var regions = f.regions;
        const region_count = f.region_count;
        const nothing = f.limited_to_nothing;
        // Not multisampled again (what is drawn is loaded, as pixels):
        // the regions' tiles, in the bigger tiles.
        if (f.msaa) for (regions[0..region_count]) |*t| {
            for (t) |*c| c.* /= 2;
        };
        f.begin(f.target, .keep);
        f.regions = regions;
        f.region_count = region_count;
        f.limited_to_nothing = nothing;
    }

    /// Tiles' size, in pixels.
    pub fn tileSize(f: *const Frame) u16 {
        return if (f.msaa) cl.multisample_tile_size else cl.tile_size;
    }

    fn tileCounts(f: *const Frame) [2]u16 {
        return .{
            std.math.divCeil(u16, f.target.width, f.tileSize()) catch unreachable,
            std.math.divCeil(u16, f.target.height, f.tileSize()) catch unreachable,
        };
    }

    /// The bo_handles index for a GEM handle, adding it if needed.
    fn index(f: *Frame, handle: u32) Error!u32 {
        for (f.bo_handles[0..f.bo_count], 0..) |h, i| if (h == handle) return @intCast(i);
        if (f.bo_count == max_bos) return error.FrameFull;
        f.bo_handles[f.bo_count] = handle;
        f.bo_count += 1;
        return f.bo_count - 1;
    }

    fn pushUniform(f: *Frame, v: u32) Error!void {
        if (f.uniforms_len == f.uniforms.len) return error.FrameFull;
        f.uniforms[f.uniforms_len] = v;
        f.uniforms_len += 1;
    }

    /// Whether one more draw with up to `uniform_words` words in its three
    /// uniform streams (texture indices included) and up to 12 new buffers
    /// is sure to fit.
    pub fn hasRoom(f: *const Frame, uniform_words: usize) bool {
        return f.bin.w.len + 128 <= f.bcl_buf.len and
            f.rec.len + 128 <= f.rec_buf.len and
            f.uniforms_len + uniform_words <= f.uniforms.len and
            f.bo_count + 12 <= max_bos and
            f.draws < max_v3d_draws;
    }

    pub fn draw(f: *Frame, d: Draw) Error!void {
        std.debug.assert(d.attributes.len >= 1 and d.attributes.len <= 8);
        // Worst case control list and shader record space for one draw.
        if (f.bin.w.len + 128 > f.bcl_buf.len or f.rec.len + 128 > f.rec_buf.len or f.draws >= max_v3d_draws) return error.FrameFull;

        const vp = d.viewport orelse f.target.fullViewport();
        const scale = vp.scale();
        // Clip to the viewport (the hardware does guard-band clipping, so
        // primitives would otherwise rasterise outside it) and the target.
        var x0: i32 = @max(vp.x, 0);
        var y0: i32 = @max(vp.y, 0);
        var x1: i32 = @min(vp.x + @as(i32, @intCast(vp.width)), f.target.width);
        var y1: i32 = @min(vp.y + @as(i32, @intCast(vp.height)), f.target.height);
        if (d.scissor) |sc| {
            x0 = @max(x0, sc.x);
            y0 = @max(y0, sc.y);
            x1 = @min(x1, sc.x + @as(i32, @intCast(sc.width)));
            y1 = @min(y1, sc.y + @as(i32, @intCast(sc.height)));
        }
        if (x1 <= x0 or y1 <= y0) return;

        f.bin.clipWindow(@intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0));
        f.bin.configurationBits(d.config);
        f.bin.viewportOffset(@as(f32, @floatFromInt(vp.x)) + @as(f32, @floatFromInt(vp.width)) / 2.0, @as(f32, @floatFromInt(vp.y)) + @as(f32, @floatFromInt(vp.height)) / 2.0);
        f.bin.clipperXyScaling(scale[0], scale[1]);
        f.bin.clipperZScaling(0.5, 0.5);

        // Shader record.
        var attrs: [8]cl.Attribute = undefined;
        for (d.attributes, 0..) |a, i| attrs[i] = .{
            .bo_index = try f.index(a.handle),
            .offset = a.offset,
            .size = a.size,
            .stride = a.stride,
            .vs_vpm_offset = a.vs_vpm_offset,
            .cs_vpm_offset = a.cs_vpm_offset,
        };
        cl.writeShaderRecord(&f.rec, .{
            .flags = @as(u16, if (d.fs_threaded) 0 else cl.shader_flag_fs_single_thread) | cl.shader_flag_enable_clipping,
            .fs_num_varyings = d.fs_num_varyings,
            .fs_bo_index = try f.index(d.fs.handle),
            .vs_bo_index = try f.index(d.vs.handle),
            .cs_bo_index = try f.index(d.cs.handle),
            .vs_attribute_mask = d.vs_attribute_mask,
            .vs_attributes_size = d.vs_attributes_size,
            .cs_attribute_mask = d.cs_attribute_mask,
            .cs_attributes_size = d.cs_attributes_size,
            .attributes = attrs[0..d.attributes.len],
        });
        f.rec_count += 1;

        const uniforms_start: u32 = @intCast(f.uniforms_len);
        // Uniform streams in shader record order: FS, VS, CS. Each starts
        // with the bo_handles index of every texture it samples, which the
        // kernel uses to relocate P0, followed by the uniform words.
        for ([_]ShaderBinding{ d.fs, d.vs, d.cs }) |s| {
            for (s.layout) |k| switch (k) {
                .tex_p0 => |u| try f.pushUniform(try f.index(d.unit(u).handle)),
                else => {},
            };
            for (s.layout) |k| try f.pushUniform(switch (k) {
                .user => |i| s.user[i],
                .tex_p0 => |u| texture.p0(d.unit(u).config),
                .tex_p1 => |u| texture.p1(d.unit(u).config),
                .constant => |c| c,
            });
        }

        f.bin.glShaderState(@intCast(d.attributes.len));
        if (d.indices) |ib| {
            f.bin.gemHandles(try f.index(ib.handle), 0);
            f.bin.glIndexedPrimitive(d.primitive, ib.type == .u16, d.count, ib.offset, ib.max_index);
        } else {
            f.bin.glArrayPrimitive(d.primitive, d.count, d.first);
        }

        var v3d_attrs: [8]Attribute = undefined;
        @memcpy(v3d_attrs[0..d.attributes.len], d.attributes);
        f.v3d_draws[f.draws] = .{
            .x0 = @intCast(x0),
            .y0 = @intCast(y0),
            .width = @intCast(x1 - x0),
            .height = @intCast(y1 - y0),
            .vp = vp,
            .config = d.config,
            .fs_handle = d.fs.handle,
            .vs_handle = d.vs.handle,
            .cs_handle = d.cs.handle,
            .fs_num_varyings = d.fs_num_varyings,
            .fs_layout = d.fs.layout,
            .vs_layout = d.vs.layout,
            .cs_layout = d.cs.layout,
            .uniforms_start = uniforms_start,
            .attrs = v3d_attrs,
            .attrs_len = @intCast(d.attributes.len),
            .cs_attribute_mask = d.cs_attribute_mask,
            .primitive = d.primitive,
            .count = d.count,
            .first = d.first,
            .indices = d.indices,
            .textures = .{ d.texture, d.texture1, d.texture2 },
        };
        f.draws += 1;
    }

    /// Renders only the tiles covering `rects` (in target pixels): the rest
    /// of the target keeps what it holds. Tiles are 64 pixels square (32
    /// multisampled), so those within the rectangles are cleared and drawn
    /// whole. Rectangles
    /// whose tiles overlap are rendered together; empty ones are dropped.
    /// Without a call (or after `limitTo(null)`), everything is rendered.
    pub fn limitTo(f: *Frame, rects: ?[]const Viewport) void {
        f.region_count = 0;
        f.limited_to_nothing = false;
        const list = rects orelse return;
        const tiles = f.tileCounts();
        var ranges: [max_regions + 8][4]i32 = undefined;
        var n: usize = 0;
        for (list) |r| {
            const x0 = @max(r.x, 0);
            const y0 = @max(r.y, 0);
            const x1 = @min(r.x + @as(i32, @intCast(r.width)), f.target.width);
            const y1 = @min(r.y + @as(i32, @intCast(r.height)), f.target.height);
            if (x1 <= x0 or y1 <= y0) continue;
            const ts: i32 = f.tileSize();
            var t: [4]i32 = .{ @divFloor(x0, ts), @divFloor(y0, ts), @divFloor(x1 - 1, ts), @divFloor(y1 - 1, ts) };
            t[2] = @min(t[2], tiles[0] - 1);
            t[3] = @min(t[3], tiles[1] - 1);
            // Merge with the ranges it overlaps (repeatedly, as merging
            // can make it overlap others).
            var i: usize = 0;
            while (i < n) {
                const q = ranges[i];
                if (t[0] <= q[2] and q[0] <= t[2] and t[1] <= q[3] and q[1] <= t[3]) {
                    t = .{ @min(t[0], q[0]), @min(t[1], q[1]), @max(t[2], q[2]), @max(t[3], q[3]) };
                    ranges[i] = ranges[n - 1];
                    n -= 1;
                    i = 0;
                } else i += 1;
            }
            if (n == ranges.len) {
                // Too many: all of them as one.
                for (ranges[0..n]) |q| t = .{ @min(t[0], q[0]), @min(t[1], q[1]), @max(t[2], q[2]), @max(t[3], q[3]) };
                n = 0;
            }
            ranges[n] = t;
            n += 1;
        }
        // More than can be submitted: the last ones together.
        while (n > max_regions) {
            const q = ranges[n - 1];
            const t = &ranges[n - 2];
            t.* = .{ @min(t[0], q[0]), @min(t[1], q[1]), @max(t[2], q[2]), @max(t[3], q[3]) };
            n -= 1;
        }
        for (ranges[0..n], f.regions[0..n]) |t, *out| out.* = .{ @intCast(t[0]), @intCast(t[1]), @intCast(t[2]), @intCast(t[3]) };
        f.region_count = n;
        if (n == 0) f.limited_to_nothing = true;
    }

    /// How many jobs the frame is submitted as (see `submitRegion`): 1
    /// unless it was limited to several regions, 0 if to none.
    pub fn regionCount(f: *const Frame) usize {
        if (f.region_count == 0) return if (f.limited_to_nothing) 0 else 1;
        return f.region_count;
    }

    /// Whether anything drawn in `r` (target pixels) can show: false if it
    /// is outside every tile the frame is limited to.
    pub fn covers(f: *const Frame, r: Viewport) bool {
        if (f.limited_to_nothing) return false;
        if (f.region_count == 0) return true;
        const ts: i32 = f.tileSize();
        const x0 = @divFloor(r.x, ts);
        const y0 = @divFloor(r.y, ts);
        const x1 = @divFloor(r.x + @as(i32, @intCast(r.width)) - 1, ts);
        const y1 = @divFloor(r.y + @as(i32, @intCast(r.height)) - 1, ts);
        for (f.regions[0..f.region_count]) |t| {
            if (x0 <= t[2] and t[0] <= x1 and y0 <= t[3] and t[1] <= y1) return true;
        }
        return false;
    }

    /// After `finish`: the ioctl argument for region `i`'s job.
    pub fn submitRegion(f: *Frame, i: usize) *device.SubmitCl {
        if (f.region_count > 0) {
            const t = f.regions[i];
            f.submit.min_x_tile = t[0];
            f.submit.min_y_tile = t[1];
            f.submit.max_x_tile = t[2];
            f.submit.max_y_tile = t[3];
        }
        return &f.submit;
    }

    /// Completes the frame and returns the ioctl argument (for the first
    /// region, if limited to several).
    pub fn finish(f: *Frame) *device.SubmitCl {
        f.bin.finish();
        const tiles = f.tileCounts();
        f.submit = .{
            .bin_cl = @intFromPtr(&f.bcl_buf),
            .bin_cl_size = @intCast(f.bin.bytes().len),
            .shader_rec = @intFromPtr(&f.rec_buf),
            .shader_rec_size = @intCast(f.rec.len),
            .shader_rec_count = f.rec_count,
            .uniforms = @intFromPtr(&f.uniforms),
            .uniforms_size = @intCast(f.uniforms_len * 4),
            .bo_handles = @intFromPtr(&f.bo_handles),
            .bo_handle_count = f.bo_count,
            .width = f.target.width,
            .height = f.target.height,
            .min_x_tile = 0,
            .min_y_tile = 0,
            .max_x_tile = @intCast(tiles[0] - 1),
            .max_y_tile = @intCast(tiles[1] - 1),
            .color_write = .{
                .hindex = 0,
                .bits = cl.renderConfigBits(f.target.tiling, f.target.format.renderConfigFormat()) |
                    (if (f.msaa) cl.render_config_multisample else 0),
            },
            // The clear values are always loaded so depth starts cleared;
            // keeping the colour loads it back from the target.
            .clear_color = switch (f.load) {
                .clear => |c| .{ c, c },
                .keep => .{ 0, 0 },
            },
            .clear_z = f.clear_z,
            .flags = device.SubmitCl.flag_use_clear_color,
        };
        // Without draws only the rendering pass is needed (a clear, or a
        // load and store); the kernel skips binning for an empty list.
        if (f.draws == 0) {
            f.submit.bin_cl_size = 0;
            f.submit.shader_rec_size = 0;
            f.submit.shader_rec_count = 0;
            f.submit.uniforms_size = 0;
        }
        if (f.load == .keep) {
            f.submit.color_read = .{
                .hindex = 0,
                .bits = cl.loadStoreBits(f.target.tiling, .color, f.target.format.loadStoreFormat()),
            };
        }
        return f.submitRegion(0);
    }

    pub fn bcl(f: *const Frame) []const u8 {
        return f.bin.bytes();
    }

    pub fn shaderRecords(f: *const Frame) []const u8 {
        return f.rec_buf[0..f.rec.len];
    }

    pub fn uniformWords(f: *const Frame) []const u32 {
        return f.uniforms[0..f.uniforms_len];
    }

    pub fn handles(f: *const Frame) []const u32 {
        return f.bo_handles[0..f.bo_count];
    }

    fn boAddr(f: *const Frame, bo_addrs: []const u32, handle: u32) u32 {
        for (f.bo_handles[0..f.bo_count], 0..) |h, i| {
            if (h == handle) return bo_addrs[i];
        }
        unreachable;
    }

    /// Translates the recorded frame into V3D 4.2/7.1 BCL, RCL, and indirect
    /// state buffers, submits them via `DRM_IOCTL_V3D_SUBMIT_CL`, and returns
    /// the command list BO handle to wait on.
    pub fn submitV3dRegion(f: *Frame, dev: device.Device, job: *const device.SubmitCl) !u32 {
        var bo_addrs: [max_bos]u32 = undefined;
        for (f.bo_handles[0..f.bo_count], 0..) |h, i| {
            bo_addrs[i] = try dev.getBoOffset(h);
        }

        const tiles = f.tileCounts();
        const num_tiles: u32 = @as(u32, tiles[0]) * @as(u32, tiles[1]);
        const tile_alloc_size = std.mem.alignForward(u32, @max(num_tiles * 64, 4096), 4096);
        const tile_state_size = std.mem.alignForward(u32, @max(num_tiles * 64, 4096), 4096);

        const slot = &v3d_scratch[v3d_scratch_next];
        v3d_scratch_next = (v3d_scratch_next + 1) % v3d_scratch_slots;
        if (slot.in_use) {
            try dev.waitBo(slot.cl_bo.?.handle, std.time.ns_per_s);
            slot.in_use = false;
        }
        if (slot.cl_bo == null) {
            slot.cl_bo = try dev.createV3dBo(256 * 1024);
        }
        if (slot.tile_alloc_bo) |bo| {
            if (bo.map.len < tile_alloc_size) {
                dev.destroyV3dBo(bo);
                slot.tile_alloc_bo = null;
            }
        }
        if (slot.tile_alloc_bo == null) {
            slot.tile_alloc_bo = try dev.createV3dBo(tile_alloc_size);
        }
        if (slot.tile_state_bo) |bo| {
            if (bo.map.len < tile_state_size) {
                dev.destroyV3dBo(bo);
                slot.tile_state_bo = null;
            }
        }
        if (slot.tile_state_bo == null) {
            slot.tile_state_bo = try dev.createV3dBo(tile_state_size);
        }

        const cl_bo = slot.cl_bo.?;
        const tile_alloc_bo = slot.tile_alloc_bo.?;
        const tile_state_bo = slot.tile_state_bo.?;

        const cl_base = try dev.getBoOffset(cl_bo.handle);
        const tile_alloc_addr = try dev.getBoOffset(tile_alloc_bo.handle);
        const tile_state_addr = try dev.getBoOffset(tile_state_bo.handle);
        const target_addr = bo_addrs[0];

        // 0..64: default vertex attributes (zeros).
        @memset(cl_bo.map[0..64], 0);
        const default_attr_addr = cl_base;

        const v3d_ver = dev.v3d_ver;

        // 64..128: generic per-tile list.
        var gen_rcl = v3d_cl.Rcl.init(cl_bo.map[64..128]);
        gen_rcl.tileCoordinatesImplicit();
        if (f.load == .keep) {
            gen_rcl.loadTileBufferGeneralColor(target_addr, f.target.format, f.target.tiling, f.target.width, f.target.height);
        }
        gen_rcl.endOfLoads();
        if (f.draws > 0) {
            gen_rcl.primListFormatTriangles();
            gen_rcl.setInstanceId(0);
            gen_rcl.branchToImplicitTileList();
        }
        gen_rcl.storeTileBufferGeneralColor(target_addr, f.target.format, f.target.tiling, f.target.width, f.target.height, f.msaa);
        gen_rcl.clearTileBuffers(true, false, v3d_ver);
        gen_rcl.endOfTileMarker();
        gen_rcl.returnFromSubList();
        const generic_start = cl_base + 64;
        const generic_end = generic_start + @as(u32, @intCast(gen_rcl.bytes().len));

        // 128..196608: indirect state (shader records, attribute records,
        // texture/sampler states, uniforms).
        var ind_off: u32 = 128;

        // 196608..245760: BCL.
        const bcl_off: u32 = 196608;
        var v3d_bcl = v3d_cl.Bcl.init(cl_bo.map[bcl_off..245760]);
        var any_early_z = false;
        if (f.draws > 0) {
            v3d_bcl.startBinning(f.target.width, f.target.height, f.msaa, v3d_ver);
            for (f.v3d_draws[0..f.draws]) |*d| {
                if (d.config.early_z) any_early_z = true;
                v3d_bcl.clipWindow(d.x0, d.y0, d.width, d.height);
                v3d_bcl.cfgBits(d.config, f.msaa, v3d_ver);
                const scale = d.vp.scale();
                v3d_bcl.viewport(
                    @as(f32, @floatFromInt(d.vp.x)) + @as(f32, @floatFromInt(d.vp.width)) / 2.0,
                    @as(f32, @floatFromInt(d.vp.y)) + @as(f32, @floatFromInt(d.vp.height)) / 2.0,
                    scale[0],
                    scale[1],
                    v3d_ver,
                );

                // Emit Texture Shader State (32-byte aligned) and Sampler State
                // (8-byte aligned) for any bound textures.
                var tex_state_addrs: [3]u32 = .{ 0, 0, 0 };
                var samp_state_addrs: [3]u32 = .{ 0, 0, 0 };
                for (d.textures, 0..) |maybe_tex, ti| {
                    if (maybe_tex) |t| {
                        if (ti > 0 and d.textures[0] != null and std.meta.eql(t, d.textures[0].?)) {
                            tex_state_addrs[ti] = tex_state_addrs[0];
                            samp_state_addrs[ti] = samp_state_addrs[0];
                            continue;
                        }
                        ind_off = std.mem.alignForward(u32, ind_off, 32);
                        const t_addr = f.boAddr(&bo_addrs, t.handle);
                        const t_state = v3d_cl.packTextureShaderState(t_addr, t.config);
                        @memcpy(cl_bo.map[ind_off..][0..24], std.mem.asBytes(&t_state));
                        tex_state_addrs[ti] = cl_base + ind_off;
                        ind_off += 24;

                        ind_off = std.mem.alignForward(u32, ind_off, 8);
                        const s_state = v3d_cl.packSamplerState(t.config);
                        @memcpy(cl_bo.map[ind_off..][0..24], std.mem.asBytes(&s_state));
                        samp_state_addrs[ti] = cl_base + ind_off;
                        ind_off += 24;
                    }
                }

                // Write FS, VS, CS uniform streams.
                var uni_addrs: [3]u32 = .{ 0, 0, 0 };
                var u_cursor: usize = d.uniforms_start;
                const layouts = [3][]const compiler.UniformKind{ d.fs_layout, d.vs_layout, d.cs_layout };
                for (layouts, 0..) |layout, si| {
                    var tex_count: usize = 0;
                    for (layout) |k| if (k == .tex_p0) {
                        tex_count += 1;
                    };
                    u_cursor += tex_count;
                    ind_off = std.mem.alignForward(u32, ind_off, 4);
                    uni_addrs[si] = cl_base + ind_off;
                    for (layout, 0..) |k, wi| {
                        const word: u32 = switch (k) {
                            .user, .constant => f.uniforms[u_cursor + wi],
                            .tex_p0 => |u| v3d_cl.tmuConfigP0(tex_state_addrs[u]),
                            .tex_p1 => |u| v3d_cl.tmuConfigP1(samp_state_addrs[u]),
                        };
                        std.mem.writeInt(u32, cl_bo.map[ind_off..][0..4], word, .little);
                        ind_off += 4;
                    }
                    u_cursor += layout.len;
                }

                // Write GL Shader State Record + Attribute Records (32-byte aligned).
                ind_off = std.mem.alignForward(u32, ind_off, 32);
                const shader_rec_addr = cl_base + ind_off;
                var attr_recs: [8]v3d_cl.AttributeRecord = undefined;
                for (d.attrs[0..d.attrs_len], 0..) |a, ai| {
                    attr_recs[ai] = .{
                        .addr = f.boAddr(&bo_addrs, a.handle) + a.offset,
                        .components = @intCast(a.size / 4),
                        .stride = a.stride,
                        .read_by_cs = (d.cs_attribute_mask >> @intCast(ai)) & 1 != 0,
                    };
                }
                const rec_hdr_len: u32 = if (v3d_ver >= 71) 32 else 36;
                const rec_bytes_len: u32 = rec_hdr_len + @as(u32, d.attrs_len) * 16;
                var rec_w = cl.Writer.init(cl_bo.map[ind_off..][0..rec_bytes_len]);
                const srec: v3d_cl.ShaderRecord = .{
                    .fs_code_addr = f.boAddr(&bo_addrs, d.fs_handle),
                    .fs_uniforms_addr = uni_addrs[0],
                    .vs_code_addr = f.boAddr(&bo_addrs, d.vs_handle),
                    .vs_uniforms_addr = uni_addrs[1],
                    .cs_code_addr = f.boAddr(&bo_addrs, d.cs_handle),
                    .cs_uniforms_addr = uni_addrs[2],
                    .default_attr_addr = default_attr_addr,
                    .fs_num_varyings = d.fs_num_varyings,
                    .attributes = attr_recs[0..d.attrs_len],
                };
                if (v3d_ver >= 71) {
                    v3d_cl.writeShaderStateRecord71(&rec_w, srec, dev.hasDrawIndex());
                } else {
                    v3d_cl.writeShaderStateRecord(&rec_w, srec);
                }
                ind_off += rec_bytes_len;

                v3d_bcl.vcmCacheSize(4, 4);
                v3d_bcl.glShaderState(shader_rec_addr, @intCast(d.attrs_len));
                if (d.indices) |ib| {
                    const ib_addr = f.boAddr(&bo_addrs, ib.handle);
                    const idx_bytes: u32 = if (ib.type == .u16) 2 else 1;
                    v3d_bcl.indexBufferSetup(ib_addr, ib.offset + d.count * idx_bytes);
                    v3d_bcl.indexedPrimList(d.primitive, ib.type == .u16, d.count, ib.offset);
                } else {
                    v3d_bcl.vertexArrayPrims(d.primitive, d.count, d.first);
                }
            }
            v3d_bcl.finish();
        }
        const bcl_start: u32 = if (f.draws > 0) cl_base + bcl_off else 0;
        const bcl_end: u32 = if (f.draws > 0) bcl_start + @as(u32, @intCast(v3d_bcl.bytes().len)) else 0;

        // 245760..262144: RCL.
        const rcl_off: u32 = 245760;
        var rcl = v3d_cl.Rcl.init(cl_bo.map[rcl_off..262144]);
        rcl.tileRenderingModeCfgCommon(f.target.width, f.target.height, f.msaa, any_early_z, true, v3d_ver);
        const clear_argb: u32 = switch (f.load) {
            .clear => |c| c,
            .keep => 0,
        };
        const clear_rgba = v3d_cl.Rcl.packClearColor(clear_argb);
        if (v3d_ver >= 71) {
            rcl.tileRenderingModeCfgRenderTargetPart1(clear_rgba);
        } else {
            rcl.tileRenderingModeCfgClearColorsPart1(clear_rgba);
            const layout = v3d_cl.targetLayout(f.target.format, f.target.tiling, f.target.width, f.target.height);
            if (layout.uif_padded_height_in_ub -| layout.implicit_padded_height_in_ub >= 15) {
                rcl.tileRenderingModeCfgClearColorsPart3(layout.uif_padded_height_in_ub);
            }
            rcl.tileRenderingModeCfgColor();
        }
        const clear_z_f: f32 = @as(f32, @floatFromInt(f.clear_z)) / @as(f32, @floatFromInt(0xffffff));
        rcl.tileRenderingModeCfgZsClearValues(clear_z_f, 0, v3d_ver);
        rcl.tileListInitialBlockSize();
        rcl.multicoreRenderingTileListSetBase(tile_alloc_addr);
        rcl.multicoreRenderingSupertileCfg(@intCast(tiles[0]), @intCast(tiles[1]));

        // Two initial dummy stores (GFXH-1742 workaround + initial TLB clear).
        for (0..2) |i| {
            rcl.tileCoordinates(0, 0);
            rcl.endOfLoads();
            rcl.storeTileBufferGeneralNone();
            if (i == 0) rcl.clearTileBuffers(true, false, v3d_ver);
            rcl.endOfTileMarker();
        }
        rcl.flushVcdCache();
        rcl.startAddressOfGenericTileList(generic_start, generic_end);

        var ty: u16 = job.min_y_tile;
        while (ty <= job.max_y_tile) : (ty += 1) {
            var tx: u16 = job.min_x_tile;
            while (tx <= job.max_x_tile) : (tx += 1) {
                rcl.supertileCoordinates(@intCast(tx), @intCast(ty));
            }
        }
        rcl.endOfRendering();

        const rcl_start = cl_base + rcl_off;
        const rcl_end = rcl_start + @as(u32, @intCast(rcl.bytes().len));

        var v3d_handles: [max_bos + 3]u32 = undefined;
        @memcpy(v3d_handles[0..f.bo_count], f.bo_handles[0..f.bo_count]);
        v3d_handles[f.bo_count] = cl_bo.handle;
        v3d_handles[f.bo_count + 1] = tile_alloc_bo.handle;
        v3d_handles[f.bo_count + 2] = tile_state_bo.handle;

        var v3d_submit: device.V3dSubmitCl = .{
            .bcl_start = bcl_start,
            .bcl_end = bcl_end,
            .rcl_start = rcl_start,
            .rcl_end = rcl_end,
            .qma = tile_alloc_addr,
            .qms = @intCast(tile_alloc_bo.map.len),
            .qts = tile_state_addr,
            .bo_handles = @intFromPtr(&v3d_handles),
            .bo_handle_count = f.bo_count + 3,
            .flags = device.V3dSubmitCl.flag_flush_cache,
        };
        try dev.submitV3d(&v3d_submit);
        v3d_scratch_seq += 1;
        slot.seq = v3d_scratch_seq;
        slot.in_use = true;
        return cl_bo.handle;
    }
};

const V3dScratchSlot = struct {
    cl_bo: ?device.Bo = null,
    tile_alloc_bo: ?device.Bo = null,
    tile_state_bo: ?device.Bo = null,
    seq: u64 = 0,
    in_use: bool = false,
};

const v3d_scratch_slots = Frame.max_regions * 2;
var v3d_scratch: [v3d_scratch_slots]V3dScratchSlot = @splat(.{});
var v3d_scratch_next: usize = 0;
var v3d_scratch_seq: u64 = 0;

pub fn markV3dCompleted(handle: u32) void {
    var done_seq: u64 = 0;
    for (v3d_scratch) |slot| {
        if (slot.cl_bo) |bo| {
            if (bo.handle == handle) {
                done_seq = slot.seq;
                break;
            }
        }
    }
    if (done_seq == 0) return;
    for (&v3d_scratch) |*slot| {
        if (slot.in_use and slot.seq <= done_seq) slot.in_use = false;
    }
}

pub fn freeV3dScratch(dev: device.Device) void {
    for (&v3d_scratch) |*slot| {
        if (slot.cl_bo) |bo| dev.destroyV3dBo(bo);
        if (slot.tile_alloc_bo) |bo| dev.destroyV3dBo(bo);
        if (slot.tile_state_bo) |bo| dev.destroyV3dBo(bo);
        slot.* = .{};
    }
    v3d_scratch_next = 0;
    v3d_scratch_seq = 0;
}

const testing = std.testing;

fn testDraw(fs_layout: []const compiler.UniformKind, vs_layout: []const compiler.UniformKind, attrs: []const Attribute, user: []const u32) Draw {
    return .{
        .fs = .{ .handle = 11, .layout = fs_layout },
        .vs = .{ .handle = 12, .layout = vs_layout, .user = user },
        .cs = .{ .handle = 13, .layout = vs_layout, .user = user },
        .fs_num_varyings = 0,
        .attributes = attrs,
        .vs_attribute_mask = 1,
        .vs_attributes_size = 8,
        .cs_attribute_mask = 1,
        .cs_attributes_size = 8,
        .count = 3,
    };
}

test "uniform streams start with texture handle indices" {
    const fs_layout = [_]compiler.UniformKind{ .{ .tex_p0 = 0 }, .{ .tex_p1 = 0 } };
    const vs_layout = [_]compiler.UniformKind{ .{ .user = 1 }, .{ .user = 0 } };
    const attrs = [_]Attribute{.{ .handle = 14, .offset = 0, .size = 8, .stride = 8, .vs_vpm_offset = 0, .cs_vpm_offset = 0 }};
    const cfg: texture.Config = .{ .width = 64, .height = 64 };
    const f = try testing.allocator.create(Frame);
    defer testing.allocator.destroy(f);
    f.* = .{};
    f.begin(.{ .handle = 10, .width = 640, .height = 480 }, .{ .clear = 0 });
    var d = testDraw(&fs_layout, &vs_layout, &attrs, &.{ 100, 200 });
    d.texture = .{ .handle = 15, .config = cfg };
    try f.draw(d);
    _ = f.finish();
    // bo_handles: target, vertices, fs, vs, cs, texture.
    try testing.expectEqualSlices(u32, &.{ 10, 14, 11, 12, 13, 15 }, f.handles());
    try testing.expectEqualSlices(u32, &.{ 5, texture.p0(cfg), texture.p1(cfg), 200, 100, 200, 100 }, f.uniformWords());
}

test "multiple draws share buffers and add shader records" {
    const layout = [_]compiler.UniformKind{.{ .user = 0 }};
    const attrs = [_]Attribute{.{ .handle = 14, .offset = 0, .size = 8, .stride = 8, .vs_vpm_offset = 0, .cs_vpm_offset = 0 }};
    const f = try testing.allocator.create(Frame);
    defer testing.allocator.destroy(f);
    f.* = .{};
    f.begin(.{ .handle = 10, .width = 128, .height = 64 }, .keep);
    try f.draw(testDraw(&.{}, &layout, &attrs, &.{1}));
    var indexed = testDraw(&.{}, &layout, &attrs, &.{2});
    indexed.indices = .{ .handle = 16, .offset = 0, .max_index = 2 };
    try f.draw(indexed);
    const s = f.finish();
    try testing.expectEqual(@as(u32, 2), s.shader_rec_count);
    try testing.expectEqual(@as(u32, 6), s.bo_handle_count); // target, vbo, fs, vs, cs, ib
    try testing.expectEqual(@as(u32, 0), s.color_read.hindex); // keep loads the target
    const b = f.bcl();
    try testing.expectEqual(@intFromEnum(cl.Packet.flush), b[b.len - 1]);
}

test "frames limited to regions render the tiles covering them" {
    var f: Frame = undefined;
    f.begin(.{ .handle = 10, .width = 640, .height = 480 }, .{ .clear = 0 });
    // Two rectangles in one tile, and one far away.
    f.limitTo(&.{
        .{ .x = 10, .y = 10, .width = 5, .height = 5 },
        .{ .x = 30, .y = 40, .width = 10, .height = 10 },
        .{ .x = 600, .y = 400, .width = 40, .height = 80 },
    });
    try std.testing.expectEqual(@as(usize, 2), f.regionCount());
    _ = f.finish();
    const a = f.submitRegion(0);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, [4]u8{ a.min_x_tile, a.min_y_tile, a.max_x_tile, a.max_y_tile });
    const b = f.submitRegion(1);
    try std.testing.expectEqual([4]u8{ 9, 6, 9, 7 }, [4]u8{ b.min_x_tile, b.min_y_tile, b.max_x_tile, b.max_y_tile });
    // Overlapping tile ranges merge.
    f.limitTo(&.{ .{ .x = 0, .y = 0, .width = 100, .height = 10 }, .{ .x = 70, .y = 0, .width = 100, .height = 10 } });
    try std.testing.expectEqual(@as(usize, 1), f.regionCount());
    try std.testing.expect(f.covers(.{ .x = 60, .y = 0, .width = 50, .height = 5 }));
    try std.testing.expect(!f.covers(.{ .x = 300, .y = 100, .width = 50, .height = 5 }));
    // Nothing to draw: no jobs; no limit: one, of everything.
    f.limitTo(&.{.{ .x = 700, .y = 0, .width = 10, .height = 10 }});
    try std.testing.expectEqual(@as(usize, 0), f.regionCount());
    f.limitTo(null);
    try std.testing.expectEqual(@as(usize, 1), f.regionCount());
    _ = f.finish();
    const all = f.submitRegion(0);
    try std.testing.expectEqual([4]u8{ 0, 0, 9, 7 }, [4]u8{ all.min_x_tile, all.min_y_tile, all.max_x_tile, all.max_y_tile });
}

test "multisampled frames: tiles of 32 pixels, the binner and the store told, the next part not" {
    const f = try testing.allocator.create(Frame);
    defer testing.allocator.destroy(f);
    f.* = .{};
    f.beginMultisampled(.{ .handle = 10, .width = 640, .height = 480 }, 0xff000000);
    try testing.expect(f.msaa);
    // The binning config's flags (its last byte): 4x multisampling; and
    // twice as many tiles each way.
    const b = f.bcl();
    try testing.expectEqual(@as(u8, 1), b[15]);
    try testing.expectEqual(@as(u8, 20), b[13]);
    try testing.expectEqual(@as(u8, 15), b[14]);
    // Regions are in its tiles.
    f.limitTo(&.{.{ .x = 600, .y = 400, .width = 40, .height = 80 }});
    const s = f.finish();
    try testing.expectEqual([4]u8{ 18, 12, 19, 14 }, [4]u8{ s.min_x_tile, s.min_y_tile, s.max_x_tile, s.max_y_tile });
    try testing.expectEqual(cl.render_config_multisample, s.color_write.bits & cl.render_config_multisample);
    try testing.expectEqual(device.SubmitRclSurface.no_surface, s.color_read.hindex);
    // Drawing goes on (a full frame) without multisampling, loading what
    // was drawn, on the same parts, in its tiles.
    f.again();
    try testing.expect(!f.msaa);
    const t = f.finish();
    try testing.expectEqual([4]u8{ 9, 6, 9, 7 }, [4]u8{ t.min_x_tile, t.min_y_tile, t.max_x_tile, t.max_y_tile });
    try testing.expectEqual(@as(u16, 0), t.color_write.bits & cl.render_config_multisample);
    // Plain frames are as before.
    f.begin(.{ .handle = 10, .width = 640, .height = 480 }, .{ .clear = 0 });
    try testing.expect(!f.msaa);
    try testing.expectEqual(@as(u8, 0), f.bcl()[15]);
}

test "a full frame starts again on the same parts, keeping what it drew" {
    const layout = [_]compiler.UniformKind{.{ .user = 0 }};
    const attrs = [_]Attribute{.{ .handle = 14, .offset = 0, .size = 8, .stride = 8, .vs_vpm_offset = 0, .cs_vpm_offset = 0 }};
    const f = try testing.allocator.create(Frame);
    defer testing.allocator.destroy(f);
    f.* = .{};
    f.begin(.{ .handle = 10, .width = 640, .height = 480 }, .{ .clear = 0xff000000 });
    f.limitTo(&.{ .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .{ .x = 600, .y = 400, .width = 40, .height = 80 } });
    // Draw until there is no room for more.
    var draws: usize = 0;
    while (f.hasRoom(256)) : (draws += 1) try f.draw(testDraw(&.{}, &layout, &attrs, &.{1}));
    try testing.expect(draws > 100);
    _ = f.finish();
    f.again();
    try testing.expect(f.hasRoom(256));
    try testing.expectEqual(@as(usize, 2), f.regionCount());
    try testing.expect(f.covers(.{ .x = 610, .y = 410, .width = 5, .height = 5 }));
    try testing.expect(!f.covers(.{ .x = 300, .y = 200, .width = 5, .height = 5 }));
    try f.draw(testDraw(&.{}, &layout, &attrs, &.{1}));
    const s = f.finish();
    try testing.expectEqual(@as(u32, 1), s.shader_rec_count);
    try testing.expectEqual(@as(u32, 0), s.color_read.hindex); // what was drawn is loaded
}
