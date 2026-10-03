//! Protocol tests: the client library talks to the server over a socket
//! pair, with the server in a thread and a fake renderer in place of the
//! GPU.

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");
const server_mod = @import("server.zig");

const p = wayland.protocol;
const client = wayland.client;
const wire = wayland.wire;
const testing = std.testing;

const FakeRenderer = struct {
    next: u32 = 1,
    live: std.atomic.Value(i32) = .init(0),
    uploads: std.atomic.Value(u32) = .init(0),
    last_pixel: std.atomic.Value(u32) = .init(0),

    fn backend(r: *FakeRenderer) server_mod.Backend {
        return .{ .ptr = r, .vtable = &.{ .importDmabuf = importDmabuf, .uploadPixels = uploadPixels, .destroyTexture = destroyTexture } };
    }

    fn importDmabuf(ptr: *anyopaque, fd: linux.fd_t, w: u32, h: u32) anyerror!server_mod.Texture {
        const r: *FakeRenderer = @ptrCast(@alignCast(ptr));
        _ = linux.close(fd);
        r.next += 1;
        _ = r.live.fetchAdd(1, .monotonic);
        return .{ .handle = r.next, .width = w, .height = h };
    }

    fn uploadPixels(ptr: *anyopaque, existing: ?server_mod.Texture, pixels: []const u8, w: u32, h: u32, stride: u32) anyerror!server_mod.Texture {
        const r: *FakeRenderer = @ptrCast(@alignCast(ptr));
        _ = stride;
        _ = r.uploads.fetchAdd(1, .monotonic);
        r.last_pixel.store(std.mem.readInt(u32, pixels[0..4], .little), .monotonic);
        if (existing) |e| if (e.width == w and e.height == h) return e;
        r.next += 1;
        _ = r.live.fetchAdd(1, .monotonic);
        return .{ .handle = r.next, .width = w, .height = h };
    }

    fn destroyTexture(ptr: *anyopaque, _: server_mod.Texture) void {
        const r: *FakeRenderer = @ptrCast(@alignCast(ptr));
        _ = r.live.fetchSub(1, .monotonic);
    }
};

/// Runs the server until its client disconnects, "presenting" a frame
/// whenever something changed.
const ServerThread = struct {
    server: server_mod.Server,
    fd: linux.fd_t,
    titles_seen: std.atomic.Value(u32) = .init(0),
    frames: std.atomic.Value(u32) = .init(0),
    last_width: std.atomic.Value(u32) = .init(0),

    fn run(st: *ServerThread) void {
        const c = st.server.addClient(st.fd) catch return;
        while (true) {
            var fds = [_]linux.pollfd{.{ .fd = c.conn.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, 50);
            if (!st.server.dispatch(c)) break;
            if (st.server.damaged) {
                if (st.server.topWindow()) |t| {
                    if (std.mem.eql(u8, t.title(), "Test window")) _ = st.titles_seen.fetchAdd(1, .monotonic);
                    st.last_width.store(t.xdg.surface.?.texture().?.width, .monotonic);
                    _ = st.frames.fetchAdd(1, .monotonic);
                }
                st.server.framePresented(16);
            }
        }
    }
};

const State = struct {
    modifiers: u32 = 0,
    t_tiled: bool = false,
    shm_formats: u32 = 0,
    configure_width: i32 = 0,
    configure_height: i32 = 0,
    configure_serial: u32 = 0,
    frames_done: u32 = 0,
    released: [4]bool = @splat(false),
    buffer_ids: [4]u32 = @splat(0),

    fn dmabufEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const s: *State = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_linux_dmabuf_v1.event.modifier) return;
        const format = r.uint() catch return;
        const hi = r.uint() catch return;
        const lo = r.uint() catch return;
        s.modifiers += 1;
        if (format == p.fourcc.xrgb8888 and (@as(u64, hi) << 32 | lo) == p.modifier.broadcom_vc4_t_tiled) s.t_tiled = true;
    }

    fn shmEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, _: u16, _: *wire.Reader) void {
        const s: *State = @ptrCast(@alignCast(ptr.?));
        s.shm_formats += 1;
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const s: *State = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.xdg_toplevel.event.configure) return;
        s.configure_width = r.int() catch 0;
        s.configure_height = r.int() catch 0;
    }

    fn xdgSurfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, _: u16, r: *wire.Reader) void {
        const s: *State = @ptrCast(@alignCast(ptr.?));
        s.configure_serial = r.uint() catch 0;
    }

    fn frameDone(ptr: ?*anyopaque, _: *client.Display, _: u32, _: u16, _: *wire.Reader) void {
        const s: *State = @ptrCast(@alignCast(ptr.?));
        s.frames_done += 1;
    }

    fn bufferEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, _: u16, _: *wire.Reader) void {
        const s: *State = @ptrCast(@alignCast(ptr.?));
        for (s.buffer_ids, 0..) |b, i| if (b == id) {
            s.released[i] = true;
        };
    }
};

fn createDmabuf(d: *client.Display, dmabuf: client.Proxy, state: *State, slot: usize, modifier: u64) !client.Proxy {
    const params = try d.newObject(null);
    var m = try dmabuf.request(p.zwp_linux_dmabuf_v1.request.create_params);
    m.uint(params.id).end();
    // Any file descriptor will do for the fake renderer.
    var pipe: [2]linux.fd_t = undefined;
    _ = linux.pipe2(&pipe, .{ .CLOEXEC = true });
    _ = linux.close(pipe[1]);
    var add = try params.request(p.zwp_linux_buffer_params_v1.request.add);
    add.fd(pipe[0]).uint(0).uint(0).uint(256).uint(@truncate(modifier >> 32)).uint(@truncate(modifier)).end();
    const buffer = try d.newObject(.{ .ptr = state, .handler = State.bufferEvent });
    state.buffer_ids[slot] = buffer.id;
    var create = try params.request(p.zwp_linux_buffer_params_v1.request.create_immed);
    create.uint(buffer.id).int(64).int(48).uint(p.fourcc.xrgb8888).uint(0).end();
    var destroy = try params.request(p.zwp_linux_buffer_params_v1.request.destroy);
    destroy.end();
    return buffer;
}

fn commitBuffer(surface: client.Proxy, buffer: client.Proxy, state: *State) !void {
    var a = try surface.request(p.wl_surface.request.attach);
    a.uint(buffer.id).int(0).int(0).end();
    const cb = try surface.display.newObject(.{ .ptr = state, .handler = State.frameDone });
    var f = try surface.request(p.wl_surface.request.frame);
    f.uint(cb.id).end();
    var c = try surface.request(p.wl_surface.request.commit);
    c.end();
}

test "a client maps a window, gets frame callbacks and buffer releases" {
    var pair: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    var renderer: FakeRenderer = .{};
    const st = try testing.allocator.create(ServerThread);
    defer testing.allocator.destroy(st);
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 800, .height = 560 }), .fd = pair[0] };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{st});

    const d = try client.Display.fromFd(testing.allocator, pair[1]);
    var state: State = .{};
    var globals: client.Globals = .{};
    const registry = try globals.fetch(d);
    try testing.expectEqual(@as(usize, 4), globals.len);
    const compositor = (try globals.bind(registry, p.wl_compositor.name, 4, null)).?;
    const wm_base = (try globals.bind(registry, p.xdg_wm_base.name, 1, null)).?;
    const dmabuf = (try globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = &state, .handler = State.dmabufEvent })).?;
    const shm = (try globals.bind(registry, p.wl_shm.name, 1, .{ .ptr = &state, .handler = State.shmEvent })).?;
    try d.roundtrip();
    try testing.expect(state.t_tiled);
    try testing.expectEqual(@as(u32, 2), state.shm_formats);

    // A toplevel: the first commit gets the configure.
    const surface = try d.newObject(null);
    var m = try compositor.request(p.wl_compositor.request.create_surface);
    m.uint(surface.id).end();
    const xdg_surface = try d.newObject(.{ .ptr = &state, .handler = State.xdgSurfaceEvent });
    m = try wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
    m.uint(xdg_surface.id).uint(surface.id).end();
    const toplevel = try d.newObject(.{ .ptr = &state, .handler = State.toplevelEvent });
    m = try xdg_surface.request(p.xdg_surface.request.get_toplevel);
    m.uint(toplevel.id).end();
    m = try toplevel.request(p.xdg_toplevel.request.set_title);
    m.string("Test window").end();
    m = try surface.request(p.wl_surface.request.commit);
    m.end();
    try d.roundtrip();
    try testing.expectEqual(@as(i32, 800), state.configure_width);
    try testing.expectEqual(@as(i32, 560), state.configure_height);
    try testing.expect(state.configure_serial != 0);
    m = try xdg_surface.request(p.xdg_surface.request.ack_configure);
    m.uint(state.configure_serial).end();

    // Two dmabuf frames: the first buffer is released when the second is
    // committed, and each frame's callback fires once it is shown.
    const b0 = try createDmabuf(d, dmabuf, &state, 0, p.modifier.broadcom_vc4_t_tiled);
    const b1 = try createDmabuf(d, dmabuf, &state, 1, p.modifier.broadcom_vc4_t_tiled);
    try commitBuffer(surface, b0, &state);
    while (state.frames_done < 1) try d.dispatch();
    try testing.expect(!state.released[0]);
    try commitBuffer(surface, b1, &state);
    while (state.frames_done < 2) try d.dispatch();
    try testing.expect(state.released[0]);
    try testing.expect(!state.released[1]);
    try testing.expect(st.titles_seen.load(.monotonic) > 0);

    // A shared-memory frame is copied and released at once.
    const memfd: linux.fd_t = @intCast(linux.memfd_create("test", 0));
    try testing.expectEqual(@as(usize, 0), linux.ftruncate(memfd, 16 * 16 * 4));
    const map: [*]u8 = @ptrFromInt(linux.mmap(null, 16 * 16 * 4, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, memfd, 0));
    std.mem.writeInt(u32, map[0..4], 0xff336699, .little);
    const pool = try d.newObject(null);
    m = try shm.request(p.wl_shm.request.create_pool);
    m.uint(pool.id).fd(memfd).int(16 * 16 * 4).end();
    const sb = try d.newObject(.{ .ptr = &state, .handler = State.bufferEvent });
    state.buffer_ids[2] = sb.id;
    m = try pool.request(p.wl_shm_pool.request.create_buffer);
    m.uint(sb.id).int(0).int(16).int(16).int(64).uint(p.wl_shm.format.xrgb8888).end();
    try commitBuffer(surface, sb, &state);
    while (state.frames_done < 3) try d.dispatch();
    try testing.expect(state.released[1]); // the dmabuf it replaced
    try testing.expect(state.released[2]);
    try testing.expectEqual(@as(u32, 0xff336699), renderer.last_pixel.load(.monotonic));

    // Unsupported layouts are a protocol error.
    _ = try createDmabuf(d, dmabuf, &state, 3, p.modifier.linear);
    try testing.expectError(error.ServerError, d.roundtrip());
    try testing.expectEqual(@as(u32, p.zwp_linux_buffer_params_v1.err.invalid_format), d.error_code);
    try testing.expect(std.mem.startsWith(u8, d.errorMessage(), "only T-tiled"));

    d.disconnect();
    thread.join();
    // Everything the client had was freed.
    try testing.expectEqual(@as(i32, 0), renderer.live.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), st.server.clients.items.len);
    try testing.expect(st.server.topWindow() == null);
}

// --- EGL and GL on Wayland ------------------------------------------------------

const gles = @import("gles");
const vc4 = @import("vc4");
const gl = gles.gl;
const egl_wayland = gles.egl.egl_wayland;

/// The GL context's fake GPU, also exporting "dma-bufs" (pipes).
const FakeExport = struct {
    gpu: gles.context.FakeGpu,

    fn createBo(ptr: *anyopaque, size: u32) anyerror!vc4.Bo {
        const f: *FakeExport = @ptrCast(@alignCast(ptr));
        return f.gpu.backend().vtable.createBo(&f.gpu, size);
    }
    fn destroyBo(ptr: *anyopaque, bo: vc4.Bo) void {
        const f: *FakeExport = @ptrCast(@alignCast(ptr));
        f.gpu.backend().vtable.destroyBo(&f.gpu, bo);
    }
    fn exportBo(_: *anyopaque, _: u32) anyerror!linux.fd_t {
        var pipe: [2]linux.fd_t = undefined;
        _ = linux.pipe2(&pipe, .{ .CLOEXEC = true });
        _ = linux.close(pipe[1]);
        return pipe[0];
    }
};

test "EGL window surfaces render, swap through the compositor and resize" {
    var pair: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    var renderer: FakeRenderer = .{};
    const st = try testing.allocator.create(ServerThread);
    defer testing.allocator.destroy(st);
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 320, .height = 200 }), .fd = pair[0] };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{st});

    const d = try client.Display.fromFd(testing.allocator, pair[1]);
    var state: State = .{};
    var globals: client.Globals = .{};
    const registry = try globals.fetch(d);
    const compositor = (try globals.bind(registry, p.wl_compositor.name, 4, null)).?;
    const wm_base = (try globals.bind(registry, p.xdg_wm_base.name, 1, null)).?;
    const surface = try d.newObject(null);
    var m = try compositor.request(p.wl_compositor.request.create_surface);
    m.uint(surface.id).end();
    const xdg_surface = try d.newObject(.{ .ptr = &state, .handler = State.xdgSurfaceEvent });
    m = try wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
    m.uint(xdg_surface.id).uint(surface.id).end();
    const toplevel = try d.newObject(.{ .ptr = &state, .handler = State.toplevelEvent });
    m = try xdg_surface.request(p.xdg_surface.request.get_toplevel);
    m.uint(toplevel.id).end();
    m = try surface.request(p.wl_surface.request.commit);
    m.end();
    try d.roundtrip();
    m = try xdg_surface.request(p.xdg_surface.request.ack_configure);
    m.uint(state.configure_serial).end();

    // EGL's side: the platform, a window and its surface, and a GL context.
    var fake: FakeExport = .{ .gpu = .{ .gpa = testing.allocator } };
    var pl: egl_wayland.Platform = .{ .conn = d, .gpu = .{ .ptr = &fake, .createBo = FakeExport.createBo, .destroyBo = FakeExport.destroyBo, .exportBo = FakeExport.exportBo } };
    try pl.init();
    const win = egl_wayland.wl_egl_window_create(&surface, state.configure_width, state.configure_height).?;
    defer egl_wayland.wl_egl_window_destroy(win);
    const es = try egl_wayland.Surface.create(&pl, win);
    const ctx = try gles.context.Context.create(testing.allocator, fake.gpu.backend());
    gles.context.current = ctx;
    ctx.setTarget(try es.backTarget());

    for (0..6) |i| {
        gl.glClearColor(@floatFromInt(i % 2), 0, 0, 1);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        try es.swap(ctx);
    }
    // Frames render into T-tiled buffers the compositor can sample.
    try testing.expectEqual(@as(u32, 6), fake.gpu.frames);
    try testing.expectEqual(vc4.cl.renderConfigBits(.t, vc4.cl.render_config_format_rgba8888), fake.gpu.last_submit.color_write.bits);
    try testing.expectEqual(@as(u32, 320), st.last_width.load(.monotonic));

    // A resize takes effect with the next buffer.
    egl_wayland.wl_egl_window_resize(win, 160, 100, 0, 0);
    for (0..4) |_| {
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        try es.swap(ctx);
    }
    // Let the last frame be shown.
    while (es.frame_pending) try d.dispatch();
    try testing.expectEqual(@as(u32, 160), st.last_width.load(.monotonic));
    var w: c_int = 0;
    var h: c_int = 0;
    egl_wayland.wl_egl_window_get_attached_size(win, &w, &h);
    try testing.expectEqual(@as(c_int, 100), h);
    // The client never holds more than three buffers.
    try testing.expect(fake.gpu.live_bos <= 3 + 2);

    ctx.target = null;
    es.destroy();
    ctx.destroy();
    d.disconnect();
    thread.join();
    try testing.expectEqual(@as(i32, 0), renderer.live.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), fake.gpu.live_bos);
}
