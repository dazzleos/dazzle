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

    fn importDmabuf(ptr: *anyopaque, fd: linux.fd_t, w: u32, h: u32, format: vc4.Format) anyerror!server_mod.Texture {
        const r: *FakeRenderer = @ptrCast(@alignCast(ptr));
        _ = linux.close(fd);
        r.next += 1;
        _ = r.live.fetchAdd(1, .monotonic);
        return .{ .handle = r.next, .width = w, .height = h, .format = format };
    }

    fn uploadPixels(ptr: *anyopaque, existing: ?server_mod.Texture, pixels: []const u8, w: u32, h: u32, stride: u32, format: vc4.Format) anyerror!server_mod.Texture {
        const r: *FakeRenderer = @ptrCast(@alignCast(ptr));
        _ = stride;
        _ = r.uploads.fetchAdd(1, .monotonic);
        r.last_pixel.store(std.mem.readInt(u32, pixels[0..4], .little), .monotonic);
        if (existing) |e| if (e.width == w and e.height == h and e.format == format) return e;
        r.next += 1;
        _ = r.live.fetchAdd(1, .monotonic);
        return .{ .handle = r.next, .width = w, .height = h, .format = format };
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
    /// Set by the test to have the server thread feed it input events.
    send_input: std.atomic.Value(bool) = .init(false),
    /// Set by the test to have it feed a touch: down at 30,50 (in the
    /// window at 0,40), moved to 60,80, and up.
    send_touch: std.atomic.Value(bool) = .init(false),
    /// Set by the test to have the server thread hold the top window's
    /// buffer as the display would when showing it directly, or drop it.
    hold_top: std.atomic.Value(bool) = .init(false),
    drop_held: std.atomic.Value(bool) = .init(false),
    held: ?*server_mod.Buffer = null,

    fn run(st: *ServerThread) void {
        const c = st.server.addClient(st.fd) catch return;
        while (true) {
            var fds = [_]linux.pollfd{.{ .fd = c.conn.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, 10);
            if (!st.server.dispatch(c)) break;
            st.server.updateFocus();
            if (st.hold_top.swap(false, .monotonic)) {
                st.held = st.server.scanoutBuffer(st.server.topWindow().?).?;
                st.server.holdBuffer(st.held.?);
            }
            if (st.drop_held.swap(false, .monotonic)) {
                st.server.dropBuffer(st.held.?);
                st.held = null;
                st.server.flushClients();
            }
            if (st.send_input.swap(false, .monotonic)) {
                const srv = &st.server;
                // Over the bar, then over the window (at y = 40).
                srv.pointerMotion(1, 10, 10);
                srv.pointerFrame();
                srv.pointerMotion(2, 30, 50);
                srv.pointerFrame();
                srv.pointerMotion(3, 31.5, 52);
                srv.pointerButton(3, p.input.btn_left, true);
                srv.pointerFrame();
                srv.pointerAxis(4, p.wl_pointer.axis.vertical_scroll, 15);
                srv.pointerFrame();
                srv.keyboardKey(5, 30, true); // KEY_A
                srv.keyboardKey(6, 30, false);
                srv.flushClients();
            }
            if (st.send_touch.swap(false, .monotonic)) {
                const srv = &st.server;
                srv.touchDown(1, 9, 30, 50);
                srv.touchFrame();
                srv.touchMotion(2, 9, 60, 80);
                srv.touchFrame();
                srv.touchUp(3, 9);
                srv.touchFrame();
                srv.flushClients();
            }
            if (st.server.damaged) {
                if (st.server.topWindow()) |t| {
                    if (std.mem.eql(u8, t.title(), "Test window")) _ = st.titles_seen.fetchAdd(1, .monotonic);
                    st.last_width.store(t.xdg.surface.?.texture().?.width, .monotonic);
                    _ = st.frames.fetchAdd(1, .monotonic);
                }
                st.server.frameDrawn();
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
    activated: bool = false,
    suspended: bool = false,
    maximized: bool = false,
    /// From the pointer, if it has one.
    pointer_in: bool = false,
    press_serial: u32 = 0,
    releases: u32 = 0,

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
        const states = r.array() catch &.{};
        s.activated = false;
        s.suspended = false;
        s.maximized = false;
        var i: usize = 0;
        while (i + 4 <= states.len) : (i += 4) switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
            p.xdg_toplevel.state.activated => s.activated = true,
            p.xdg_toplevel.state.maximized => s.maximized = true,
            p.xdg_toplevel.state.suspended => s.suspended = true,
            else => {},
        };
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const s: *State = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_pointer.event.enter => s.pointer_in = true,
            p.wl_pointer.event.leave => s.pointer_in = false,
            p.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                if ((r.uint() catch return) == p.wl_pointer.button_state.pressed) s.press_serial = serial else s.releases += 1;
            },
            else => {},
        }
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
    try testing.expectEqual(@as(usize, 9), globals.len);
    const compositor = (try globals.bind(registry, p.wl_compositor.name, 4, null)).?;
    const wm_base = (try globals.bind(registry, p.xdg_wm_base.name, 1, null)).?;
    const dmabuf = (try globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = &state, .handler = State.dmabufEvent })).?;
    const shm = (try globals.bind(registry, p.wl_shm.name, 1, .{ .ptr = &state, .handler = State.shmEvent })).?;
    try d.roundtrip();
    try testing.expect(state.t_tiled);
    // ARGB8888, XRGB8888 and RGB565.
    try testing.expectEqual(@as(u32, 3), state.shm_formats);

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

// --- Native app windows ----------------------------------------------------------

const vc4 = @import("vc4");
const app = @import("app");

/// A GPU for app windows that keeps buffers in memory, exports them as
/// pipes, and records the frames it is asked to render.
const FakeGpu = struct {
    live_bos: u32 = 0,
    next_handle: u32 = 1,
    frames: u32 = 0,
    last_target: ?vc4.render.Target = null,

    fn gpu(f: *FakeGpu) app.Gpu {
        return .{ .ptr = f, .vtable = &.{ .createBo = createBo, .destroyBo = destroyBo, .exportBo = exportBo, .run = run } };
    }

    fn createBo(ptr: *anyopaque, size: u32) anyerror!vc4.Bo {
        const f: *FakeGpu = @ptrCast(@alignCast(ptr));
        const map = try testing.allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), size);
        f.live_bos += 1;
        f.next_handle += 1;
        return .{ .handle = f.next_handle, .map = map };
    }
    fn destroyBo(ptr: *anyopaque, bo: vc4.Bo) void {
        const f: *FakeGpu = @ptrCast(@alignCast(ptr));
        testing.allocator.free(bo.map);
        f.live_bos -= 1;
    }
    fn exportBo(_: *anyopaque, _: u32) anyerror!linux.fd_t {
        var pipe: [2]linux.fd_t = undefined;
        _ = linux.pipe2(&pipe, .{ .CLOEXEC = true });
        _ = linux.close(pipe[1]);
        return pipe[0];
    }
    fn run(ptr: *anyopaque, frame: *vc4.render.Frame) anyerror!void {
        const f: *FakeGpu = @ptrCast(@alignCast(ptr));
        _ = frame.finish();
        f.frames += 1;
        f.last_target = frame.target;
    }
};

var test_frame: vc4.render.Frame = undefined;

test "app windows render, present through the compositor and resize" {
    var pair: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    var renderer: FakeRenderer = .{};
    const st = try testing.allocator.create(ServerThread);
    defer testing.allocator.destroy(st);
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 320, .height = 200 }), .fd = pair[0] };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{st});

    var fake: FakeGpu = .{};
    const d = try client.Display.fromFd(testing.allocator, pair[1]);
    const win = try app.Window.openOn(testing.allocator, fake.gpu(), d, "Test window");
    // Maximized into the work area.
    try testing.expectEqual(@as(u32, 320), win.width);
    try testing.expectEqual(@as(u32, 200), win.height);

    for (0..6) |_| {
        test_frame.begin(try win.beginFrame(), .{ .clear = 0xff000000 });
        try win.present(&test_frame);
    }
    // Frames render into T-tiled buffers the compositor can sample.
    try testing.expectEqual(@as(u32, 6), fake.frames);
    try testing.expectEqual(vc4.cl.Tiling.t, fake.last_target.?.tiling);
    // RGB565, unless the app asks for 32 bits.
    try testing.expectEqual(vc4.Format.rgb565, fake.last_target.?.format);
    while (win.frame_pending) try d.dispatch();
    try testing.expectEqual(@as(u32, 320), st.last_width.load(.monotonic));
    try testing.expect(st.titles_seen.load(.monotonic) > 0);

    // A new size (as a configure would set) takes effect with the next
    // buffer.
    win.width = 160;
    win.height = 100;
    for (0..4) |_| {
        test_frame.begin(try win.beginFrame(), .{ .clear = 0xff000000 });
        try win.present(&test_frame);
    }
    while (win.frame_pending) try d.dispatch();
    try testing.expectEqual(@as(u32, 160), st.last_width.load(.monotonic));
    try testing.expectEqual(@as(u16, 100), fake.last_target.?.height);
    // The window never holds more than three buffers.
    try testing.expect(fake.live_bos <= 3);

    // Asking for 32-bit buffers replaces them.
    win.setFormat(.xrgb8888);
    for (0..4) |_| {
        test_frame.begin(try win.beginFrame(), .{ .clear = 0xff000000 });
        try win.present(&test_frame);
    }
    while (win.frame_pending) try d.dispatch();
    try testing.expectEqual(vc4.Format.xrgb8888, fake.last_target.?.format);
    try testing.expect(fake.live_bos <= 3);

    win.close();
    thread.join();
    try testing.expectEqual(@as(u32, 0), fake.live_bos);
    try testing.expectEqual(@as(i32, 0), renderer.live.load(.monotonic));
}

const InputState = struct {
    capabilities: u32 = 0,
    keymap_format: ?u32 = null,
    keymap_size: u32 = 0,
    /// The keymap's start.
    keymap_head: [16]u8 = @splat(0),
    repeat_rate: i32 = 0,
    keyboard_entered: bool = false,
    pointer_entered: bool = false,
    enter_x: f64 = 0,
    enter_y: f64 = 0,
    motion_x: f64 = 0,
    motion_y: f64 = 0,
    buttons: u32 = 0,
    scrolled: f64 = 0,
    pointer_frames: u32 = 0,
    keys: [4]u32 = @splat(0),
    n_keys: usize = 0,

    fn seatEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const s: *InputState = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_seat.event.capabilities) s.capabilities = r.uint() catch 0;
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const s: *InputState = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_pointer.event.enter => {
                _ = r.uint() catch 0;
                _ = r.uint() catch 0;
                s.pointer_entered = true;
                s.enter_x = r.fixed() catch 0;
                s.enter_y = r.fixed() catch 0;
            },
            p.wl_pointer.event.motion => {
                _ = r.uint() catch 0;
                s.motion_x = r.fixed() catch 0;
                s.motion_y = r.fixed() catch 0;
            },
            p.wl_pointer.event.button => {
                _ = r.uint() catch 0;
                _ = r.uint() catch 0;
                if ((r.uint() catch 0) == p.input.btn_left and (r.uint() catch 0) == p.wl_pointer.button_state.pressed) s.buttons += 1;
            },
            p.wl_pointer.event.axis => {
                _ = r.uint() catch 0;
                _ = r.uint() catch 0;
                s.scrolled += r.fixed() catch 0;
            },
            p.wl_pointer.event.frame => s.pointer_frames += 1,
            else => {},
        }
    }

    fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const s: *InputState = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_keyboard.event.keymap => {
                s.keymap_format = r.uint() catch null;
                if (r.fd()) |fd| {
                    _ = linux.pread(fd, &s.keymap_head, s.keymap_head.len, 0);
                    _ = linux.close(fd);
                } else |_| {}
                s.keymap_size = r.uint() catch 0;
            },
            p.wl_keyboard.event.repeat_info => s.repeat_rate = r.int() catch 0,
            p.wl_keyboard.event.enter => s.keyboard_entered = true,
            p.wl_keyboard.event.key => {
                _ = r.uint() catch 0;
                _ = r.uint() catch 0;
                const key = r.uint() catch 0;
                const state = r.uint() catch 0;
                if (s.n_keys < s.keys.len) {
                    s.keys[s.n_keys] = key << 1 | state;
                    s.n_keys += 1;
                }
            },
            else => {},
        }
    }
};

test "the shown window gets the pointer and keyboard" {
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
    var input: InputState = .{};
    var globals: client.Globals = .{};
    const registry = try globals.fetch(d);
    const compositor = (try globals.bind(registry, p.wl_compositor.name, 4, null)).?;
    const wm_base = (try globals.bind(registry, p.xdg_wm_base.name, 1, null)).?;
    const shm = (try globals.bind(registry, p.wl_shm.name, 1, null)).?;
    const seat = (try globals.bind(registry, p.wl_seat.name, 5, .{ .ptr = &input, .handler = InputState.seatEvent })).?;
    const pointer = try d.newObject(.{ .ptr = &input, .handler = InputState.pointerEvent });
    var m = try seat.request(p.wl_seat.request.get_pointer);
    m.uint(pointer.id).end();
    const keyboard = try d.newObject(.{ .ptr = &input, .handler = InputState.keyboardEvent });
    m = try seat.request(p.wl_seat.request.get_keyboard);
    m.uint(keyboard.id).end();
    try d.roundtrip();
    try testing.expectEqual(@as(u32, p.wl_seat.capability.pointer | p.wl_seat.capability.keyboard | p.wl_seat.capability.touch), input.capabilities);
    // An XKB keymap, in a file the client can read; keys repeat.
    try testing.expectEqual(@as(?u32, p.wl_keyboard.keymap_format.xkb_v1), input.keymap_format);
    try testing.expectEqual(@as(u32, @intCast(@import("keyboard.zig").keymap(.us).len)), input.keymap_size);
    try testing.expectEqualStrings("// The keymap W", input.keymap_head[0..15]);
    try testing.expectEqual(@as(i32, 25), input.repeat_rate);

    // A mapped window (an shm buffer) gets the keyboard focus.
    const surface = try d.newObject(null);
    m = try compositor.request(p.wl_compositor.request.create_surface);
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
    const memfd: linux.fd_t = @intCast(linux.memfd_create("test", 0));
    try testing.expectEqual(@as(usize, 0), linux.ftruncate(memfd, 64 * 64 * 4));
    const pool = try d.newObject(null);
    m = try shm.request(p.wl_shm.request.create_pool);
    m.uint(pool.id).fd(memfd).int(64 * 64 * 4).end();
    const sb = try d.newObject(.{ .ptr = &state, .handler = State.bufferEvent });
    m = try pool.request(p.wl_shm_pool.request.create_buffer);
    m.uint(sb.id).int(0).int(64).int(64).int(256).uint(p.wl_shm.format.xrgb8888).end();
    try commitBuffer(surface, sb, &state);
    while (state.frames_done < 1) try d.dispatch();
    try d.roundtrip();
    try testing.expect(input.keyboard_entered);
    try testing.expect(!input.pointer_entered);

    // The pointer enters the window (64x64 at 0,40), in surface coordinates.
    st.send_input.store(true, .monotonic);
    while (input.n_keys < 2) try d.dispatch();
    try testing.expect(input.pointer_entered);
    try testing.expectEqual(@as(f64, 30), input.enter_x);
    try testing.expectEqual(@as(f64, 10), input.enter_y);
    try testing.expectEqual(@as(f64, 31.5), input.motion_x);
    try testing.expectEqual(@as(f64, 12), input.motion_y);
    try testing.expectEqual(@as(u32, 1), input.buttons);
    try testing.expectEqual(@as(f64, 15), input.scrolled);
    try testing.expectEqual(@as(u32, 3), input.pointer_frames);
    try testing.expectEqual(@as(u32, 30 << 1 | 1), input.keys[0]);
    try testing.expectEqual(@as(u32, 30 << 1 | 0), input.keys[1]);

    d.disconnect();
    thread.join();
    try testing.expect(st.server.pointer_focus == null);
    try testing.expect(st.server.keyboard_focus == null);
}

test "a buffer on the display is released only once it leaves the screen" {
    var pair: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    var renderer: FakeRenderer = .{};
    const st = try testing.allocator.create(ServerThread);
    defer testing.allocator.destroy(st);
    // The work area is the dma-bufs' size, so they can be shown directly.
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 64, .height = 48 }), .fd = pair[0] };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{st});

    const d = try client.Display.fromFd(testing.allocator, pair[1]);
    var state: State = .{};
    var globals: client.Globals = .{};
    const registry = try globals.fetch(d);
    const compositor = (try globals.bind(registry, p.wl_compositor.name, 4, null)).?;
    const wm_base = (try globals.bind(registry, p.xdg_wm_base.name, 1, null)).?;
    const dmabuf = (try globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, null)).?;
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

    const b0 = try createDmabuf(d, dmabuf, &state, 0, p.modifier.broadcom_vc4_t_tiled);
    const b1 = try createDmabuf(d, dmabuf, &state, 1, p.modifier.broadcom_vc4_t_tiled);
    try commitBuffer(surface, b0, &state);
    while (state.frames_done < 1) try d.dispatch();

    // The display shows b0: a newer buffer does not release it...
    st.hold_top.store(true, .monotonic);
    while (st.hold_top.load(.monotonic)) try d.roundtrip();
    try commitBuffer(surface, b1, &state);
    while (state.frames_done < 2) try d.dispatch();
    try d.roundtrip();
    try testing.expect(!state.released[0]);
    // ...until the display moves on.
    st.drop_held.store(true, .monotonic);
    while (!state.released[0]) try d.dispatch();

    // A buffer still on the display outlives its client.
    st.hold_top.store(true, .monotonic);
    while (st.hold_top.load(.monotonic)) try d.roundtrip();
    d.disconnect();
    thread.join();
    try testing.expectEqual(@as(i32, 1), renderer.live.load(.monotonic));
    st.server.dropBuffer(st.held.?);
    try testing.expectEqual(@as(i32, 0), renderer.live.load(.monotonic));
}

test "clients are known by their process, which the dock raises windows by" {
    var pair: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer _ = linux.close(pair[1]);
    var renderer: FakeRenderer = .{};
    var server: server_mod.Server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 800, .height = 560 });
    defer server.deinit();
    const c = try server.addClient(pair[0]);
    try testing.expectEqual(@as(?linux.pid_t, linux.getpid()), c.pid);
    // No window to raise yet.
    try testing.expect(!server.raise(linux.getpid()));
}

/// Runs the server for several clients (each given a made-up process ID,
/// 1001 onwards), until they all disconnect.
const MultiServerThread = struct {
    server: server_mod.Server,
    fds: []const linux.fd_t,
    frames: std.atomic.Value(u32) = .init(0),
    /// Set by the test: the process whose window to raise.
    raise_pid: std.atomic.Value(i32) = .init(0),
    /// Set by the test: pointer input to feed the server (`Input`).
    input: std.atomic.Value(u32) = .init(0),
    /// Where the window of process 1002 is.
    second_x: std.atomic.Value(i32) = .init(0),
    second_y: std.atomic.Value(i32) = .init(0),

    const Input = enum(u32) {
        none,
        /// Press in the second window (restored, at 200,180).
        press_second,
        /// Move by (100, 60), then release.
        drag_release,
        /// Click in the first window (maximized, at 0,40).
        click_first,
        /// Press in the second window (restored at 300,240, showing 64x64
        /// whatever size it is told), as if at its corner.
        press_corner,
        /// Move by (40, 30), then by (50, 40) more.
        drag_resize,
        release,
    };

    fn feed(srv: *server_mod.Server, input: Input) void {
        const left = p.input.btn_left;
        switch (input) {
            .none => {},
            .press_second => {
                srv.pointerMotion(1, 210, 190);
                srv.pointerFrame();
                srv.pointerButton(1, left, true);
                srv.pointerFrame();
            },
            .drag_release => {
                srv.pointerMotion(2, 260, 220);
                srv.pointerFrame();
                srv.pointerMotion(3, 310, 250);
                srv.pointerFrame();
                srv.pointerButton(4, left, false);
                srv.pointerFrame();
            },
            .press_corner => {
                srv.pointerMotion(7, 350, 290);
                srv.pointerFrame();
                srv.pointerButton(7, left, true);
                srv.pointerFrame();
            },
            .drag_resize => {
                srv.pointerMotion(8, 390, 320);
                srv.pointerFrame();
                srv.pointerMotion(9, 440, 360);
                srv.pointerFrame();
            },
            .release => {
                srv.pointerButton(10, left, false);
                srv.pointerFrame();
            },
            .click_first => {
                srv.pointerMotion(5, 10, 50);
                srv.pointerFrame();
                srv.pointerButton(5, left, true);
                srv.pointerFrame();
                srv.pointerButton(6, left, false);
                srv.pointerFrame();
            },
        }
    }

    fn run(st: *MultiServerThread) void {
        var clients: [4]?*server_mod.Client = @splat(null);
        for (st.fds, 0..) |fd, i| {
            clients[i] = st.server.addClient(fd) catch return;
            clients[i].?.pid = @intCast(1001 + i);
        }
        while (true) {
            var fds: [4]linux.pollfd = undefined;
            var n: usize = 0;
            for (clients) |c| if (c) |cl| {
                fds[n] = .{ .fd = cl.conn.fd, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            if (n == 0) break;
            _ = linux.poll(&fds, n, 10);
            for (&clients) |*c| if (c.*) |cl| {
                if (!st.server.dispatch(cl)) c.* = null;
            };
            const pid = st.raise_pid.swap(0, .monotonic);
            if (pid != 0) _ = st.server.raise(pid);
            feed(&st.server, @enumFromInt(st.input.swap(0, .monotonic)));
            st.server.updateFocus();
            for (st.server.toplevels.items) |t| if (t.xdg.surface) |surf| if (surf.client.pid == 1002) {
                st.second_x.store(t.x, .monotonic);
                st.second_y.store(t.y, .monotonic);
            };
            if (st.server.damaged) {
                _ = st.frames.fetchAdd(1, .monotonic);
                st.server.frameDrawn();
                st.server.framePresented(16);
            }
            st.server.flushClients();
        }
    }
};

const TestWindow = struct {
    d: *client.Display,
    state: State = .{},
    surface: client.Proxy = undefined,
    buffer: client.Proxy = undefined,
    xdg_surface: client.Proxy = undefined,
    toplevel: client.Proxy = undefined,
    seat: ?client.Proxy = null,

    /// Connects on `fd` and maps a 64x64 shm window (with a pointer if
    /// `pointer`).
    fn open(tw: *TestWindow) !void {
        return tw.openWith(false);
    }

    fn openWith(tw: *TestWindow, pointer: bool) !void {
        const d = tw.d;
        var globals: client.Globals = .{};
        const registry = try globals.fetch(d);
        if (pointer) {
            const seat = (try globals.bind(registry, p.wl_seat.name, 5, null)).?;
            const ptr = try d.newObject(.{ .ptr = &tw.state, .handler = State.pointerEvent });
            var m = try seat.request(p.wl_seat.request.get_pointer);
            m.uint(ptr.id).end();
            tw.seat = seat;
        }
        const compositor = (try globals.bind(registry, p.wl_compositor.name, 4, null)).?;
        const wm_base = (try globals.bind(registry, p.xdg_wm_base.name, 6, null)).?;
        const shm = (try globals.bind(registry, p.wl_shm.name, 1, null)).?;
        tw.surface = try d.newObject(null);
        var m = try compositor.request(p.wl_compositor.request.create_surface);
        m.uint(tw.surface.id).end();
        const xdg_surface = try d.newObject(.{ .ptr = &tw.state, .handler = State.xdgSurfaceEvent });
        tw.xdg_surface = xdg_surface;
        m = try wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(xdg_surface.id).uint(tw.surface.id).end();
        tw.toplevel = try d.newObject(.{ .ptr = &tw.state, .handler = State.toplevelEvent });
        m = try xdg_surface.request(p.xdg_surface.request.get_toplevel);
        m.uint(tw.toplevel.id).end();
        m = try tw.surface.request(p.wl_surface.request.commit);
        m.end();
        try d.roundtrip();
        m = try xdg_surface.request(p.xdg_surface.request.ack_configure);
        m.uint(tw.state.configure_serial).end();
        const memfd: linux.fd_t = @intCast(linux.memfd_create("test", 0));
        _ = linux.ftruncate(memfd, 64 * 64 * 4);
        const pool = try d.newObject(null);
        m = try shm.request(p.wl_shm.request.create_pool);
        m.uint(pool.id).fd(memfd).int(64 * 64 * 4).end();
        tw.buffer = try d.newObject(.{ .ptr = &tw.state, .handler = State.bufferEvent });
        m = try pool.request(p.wl_shm_pool.request.create_buffer);
        m.uint(tw.buffer.id).int(0).int(64).int(64).int(256).uint(p.wl_shm.format.xrgb8888).end();
        try tw.frame();
        while (tw.state.frames_done < 1) try d.dispatch();
    }

    fn frame(tw: *TestWindow) !void {
        try commitBuffer(tw.surface, tw.buffer, &tw.state);
        try tw.d.flush();
    }

    /// Acknowledges the last configure, and draws (its 64x64 buffer, as
    /// it always does).
    fn ackAndDraw(tw: *TestWindow) !void {
        var m = try tw.xdg_surface.request(p.xdg_surface.request.ack_configure);
        m.uint(tw.state.configure_serial).end();
        try tw.frame();
    }

    /// Handles events until `cond` holds (or a second passes).
    fn waitFor(tw: *TestWindow, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        for (0..100) |_| {
            if (cond(ctx)) return;
            try tw.d.dispatchTimeout(10);
        }
        return error.Timeout;
    }
};

test "a covered window is suspended, without frame callbacks or redraws, until raised" {
    var a: [2]linux.fd_t = undefined;
    var b: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &a));
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &b));
    var renderer: FakeRenderer = .{};
    const fds = [_]linux.fd_t{ a[0], b[0] };
    const st = try testing.allocator.create(MultiServerThread);
    defer testing.allocator.destroy(st);
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 800, .height = 560 }), .fds = &fds };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, MultiServerThread.run, .{st});

    var first: TestWindow = .{ .d = try client.Display.fromFd(testing.allocator, a[1]) };
    try first.open();
    try testing.expect(first.state.activated and !first.state.suspended);

    // A second window covers the first, which is told so.
    var second: TestWindow = .{ .d = try client.Display.fromFd(testing.allocator, b[1]) };
    try second.open();
    const Cond = struct {
        fn suspended(s: *const State) bool {
            return s.suspended;
        }
        fn shown(s: *const State) bool {
            return s.activated and !s.suspended;
        }
    };
    try first.waitFor(&first.state, Cond.suspended);
    try testing.expect(!first.state.activated);
    try testing.expect(second.state.activated);

    // A covered window's frames neither redraw the screen nor get frame
    // callbacks.
    const frames = st.frames.load(.monotonic);
    try first.frame();
    try first.d.roundtrip();
    try first.d.roundtrip();
    try testing.expectEqual(@as(u32, 1), first.state.frames_done);
    try testing.expectEqual(frames, st.frames.load(.monotonic));

    // Raised, it is shown again and its frame callback fires; the other is
    // covered.
    st.raise_pid.store(1001, .monotonic);
    try first.waitFor(&first.state, Cond.shown);
    const Done = struct {
        fn two(s: *const State) bool {
            return s.frames_done >= 2;
        }
    };
    try first.waitFor(&first.state, Done.two);
    try second.waitFor(&second.state, Cond.suspended);

    first.d.disconnect();
    second.d.disconnect();
    thread.join();
}

test "a restored window is half the size, moves by its grab, and windows are clicked to the top" {
    var a: [2]linux.fd_t = undefined;
    var b: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &a));
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &b));
    var renderer: FakeRenderer = .{};
    const fds = [_]linux.fd_t{ a[0], b[0] };
    const st = try testing.allocator.create(MultiServerThread);
    defer testing.allocator.destroy(st);
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 800, .height = 560 }), .fds = &fds };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, MultiServerThread.run, .{st});

    var first: TestWindow = .{ .d = try client.Display.fromFd(testing.allocator, a[1]) };
    try first.openWith(true);
    try testing.expect(first.state.maximized);
    try testing.expectEqual(@as(i32, 800), first.state.configure_width);
    var second: TestWindow = .{ .d = try client.Display.fromFd(testing.allocator, b[1]) };
    try second.openWith(true);
    const Cond = struct {
        fn suspended(s: *const State) bool {
            return s.suspended;
        }
        fn visible(s: *const State) bool {
            return !s.suspended;
        }
        fn restored(s: *const State) bool {
            return !s.maximized;
        }
        fn maximized(s: *const State) bool {
            return s.maximized;
        }
        fn pressed(s: *const State) bool {
            return s.press_serial != 0;
        }
        fn activated(s: *const State) bool {
            return s.activated;
        }
        fn deactivated(s: *const State) bool {
            return !s.activated;
        }
        fn moved(t: *const MultiServerThread) bool {
            return t.second_x.load(.monotonic) == 300 and t.second_y.load(.monotonic) == 240;
        }
    };
    try first.waitFor(&first.state, Cond.suspended);

    // Restored, the second window is told half the work area's size, and
    // goes in the middle of it, which uncovers the first window (64x64 at
    // the corner). The second keeps the keyboard.
    var m = try second.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try second.d.flush();
    try second.waitFor(&second.state, Cond.restored);
    try testing.expectEqual(@as(i32, 400), second.state.configure_width);
    try testing.expectEqual(@as(i32, 280), second.state.configure_height);
    try testing.expect(second.state.activated);
    try first.waitFor(&first.state, Cond.visible);
    try testing.expect(!first.state.activated);
    try testing.expectEqual(@as(i32, 200), st.second_x.load(.monotonic));
    try testing.expectEqual(@as(i32, 180), st.second_y.load(.monotonic));

    // Pressing on it (its title bar, say) and asking to move: the window
    // follows the pointer, which leaves it until the button is released
    // (which the client does not see).
    st.input.store(@intFromEnum(MultiServerThread.Input.press_second), .monotonic);
    try second.waitFor(&second.state, Cond.pressed);
    try testing.expect(second.state.pointer_in);
    m = try second.toplevel.request(p.xdg_toplevel.request.move);
    m.uint(second.seat.?.id).uint(second.state.press_serial).end();
    try second.d.roundtrip();
    try testing.expect(!second.state.pointer_in);
    st.input.store(@intFromEnum(MultiServerThread.Input.drag_release), .monotonic);
    try second.waitFor(st, Cond.moved);
    try second.d.roundtrip();
    try testing.expectEqual(@as(u32, 0), second.state.releases);
    try testing.expect(second.state.pointer_in);

    // A move with a stale serial (no button down) does nothing.
    m = try second.toplevel.request(p.xdg_toplevel.request.move);
    m.uint(second.seat.?.id).uint(second.state.press_serial).end();
    try second.d.roundtrip();
    try testing.expect(st.server.grab == null);

    // Resizing by the bottom right corner: the window is told each new
    // size only once it has drawn at the last.
    const Size = struct {
        fn is(s: *const State, w: i32, h: i32) bool {
            return s.configure_width == w and s.configure_height == h;
        }
        fn step1(s: *const State) bool {
            return is(s, 440, 310);
        }
        fn step2(s: *const State) bool {
            return is(s, 490, 350);
        }
        fn grown(s: *const State) bool {
            return is(s, 520, 400);
        }
    };
    try second.ackAndDraw();
    // Its minimum is smaller than it is: nothing changes.
    m = try second.toplevel.request(p.xdg_toplevel.request.set_min_size);
    m.int(380).int(260).end();
    try second.d.roundtrip();
    try testing.expect(Size.is(&second.state, 400, 280));
    const pressed_before = second.state.press_serial;
    st.input.store(@intFromEnum(MultiServerThread.Input.press_corner), .monotonic);
    for (0..100) |_| {
        if (second.state.press_serial != pressed_before) break;
        try second.d.dispatchTimeout(10);
    }
    m = try second.toplevel.request(p.xdg_toplevel.request.resize);
    m.uint(second.seat.?.id).uint(second.state.press_serial).uint(server_mod.Server.edge_bottom | server_mod.Server.edge_right).end();
    try second.d.roundtrip();
    try testing.expect(!second.state.pointer_in);
    st.input.store(@intFromEnum(MultiServerThread.Input.drag_resize), .monotonic);
    try second.waitFor(&second.state, Size.step1);
    // The pointer has moved on, but the window has not drawn yet.
    for (0..5) |_| try second.d.dispatchTimeout(10);
    try testing.expect(Size.step1(&second.state));
    try second.ackAndDraw();
    try second.waitFor(&second.state, Size.step2);
    try second.ackAndDraw();
    st.input.store(@intFromEnum(MultiServerThread.Input.release), .monotonic);
    try second.d.roundtrip();
    // A bigger minimum makes it bigger.
    m = try second.toplevel.request(p.xdg_toplevel.request.set_min_size);
    m.int(520).int(400).end();
    try second.d.flush();
    try second.waitFor(&second.state, Size.grown);
    try second.ackAndDraw();
    // A resize with no button down does nothing.
    m = try second.toplevel.request(p.xdg_toplevel.request.resize);
    m.uint(second.seat.?.id).uint(second.state.press_serial).uint(server_mod.Server.edge_right).end();
    try second.d.roundtrip();
    try testing.expect(st.server.grab == null);

    // Clicking the first window brings it to the top, with the keyboard.
    st.input.store(@intFromEnum(MultiServerThread.Input.click_first), .monotonic);
    try first.waitFor(&first.state, Cond.activated);
    try first.d.roundtrip();
    try testing.expect(first.state.press_serial != 0);
    try testing.expectEqual(@as(u32, 1), first.state.releases);
    try second.waitFor(&second.state, Cond.deactivated);

    // Maximized again, the second window (still below) is in the corner,
    // under the first, so covered.
    m = try second.toplevel.request(p.xdg_toplevel.request.set_maximized);
    m.end();
    try second.d.flush();
    try second.waitFor(&second.state, Cond.maximized);
    try testing.expectEqual(@as(i32, 800), second.state.configure_width);
    try second.waitFor(&second.state, Cond.suspended);

    first.d.disconnect();
    second.d.disconnect();
    thread.join();
}

test "text copied in one app window is pasted in another, through the shell" {
    var a: [2]linux.fd_t = undefined;
    var b: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &a));
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &b));
    var renderer: FakeRenderer = .{};
    const fds = [_]linux.fd_t{ a[0], b[0] };
    const st = try testing.allocator.create(MultiServerThread);
    defer testing.allocator.destroy(st);
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 320, .height = 200 }), .fds = &fds };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, MultiServerThread.run, .{st});

    var fake: FakeGpu = .{};
    const show = struct {
        fn f(win: *app.Window) !void {
            test_frame.begin(try win.beginFrame(), .{ .clear = 0xff000000 });
            try win.present(&test_frame);
            while (win.frame_pending) try win.conn.dispatch();
        }
    }.f;
    // The first window, with the keyboard, copies.
    const first = try app.Window.openOn(testing.allocator, fake.gpu(), try client.Display.fromFd(testing.allocator, a[1]), "First");
    try show(first);
    first.clipboard.copy("hello from the first");
    try first.conn.roundtrip();
    // Pasted text goes to a sink, when it comes.
    const Got = struct {
        text: [64]u8 = undefined,
        len: ?usize = null,
        fn sink(g: *@This()) app.clipboard.Sink {
            return .{ .ctx = g, .f = got };
        }
        fn got(ctx: *anyopaque, t: ?[]const u8) void {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            const text = t orelse "(none)";
            @memcpy(g.text[0..text.len], text);
            g.len = text.len;
        }
        fn slice(g: *const @This()) ?[]const u8 {
            return g.text[0 .. g.len orelse return null];
        }
    };
    // Its own copy pastes at once, without the shell.
    var own: Got = .{};
    first.clipboard.paste(own.sink());
    try testing.expectEqualStrings("hello from the first", own.slice().?);

    // The second window opens on top, with the keyboard, and is told what
    // the clipboard holds.
    const second = try app.Window.openOn(testing.allocator, fake.gpu(), try client.Display.fromFd(testing.allocator, b[1]), "Second");
    try show(second);
    for (0..100) |_| {
        if (second.clipboard.offer_mime != null) break;
        try second.conn.dispatchTimeout(10);
    }
    try testing.expect(second.clipboard.offer_mime != null);
    // Pasting returns at once; the text comes once the first window has
    // written it (as it handles its events), and the second's event loop
    // reads it.
    var pasted: Got = .{};
    second.clipboard.paste(pasted.sink());
    try testing.expect(pasted.len == null);
    try testing.expect(second.clipboard.pasteFd() != null);
    for (0..200) |_| {
        if (pasted.len != null) break;
        try first.wait(5 * std.time.ns_per_ms);
        try second.wait(5 * std.time.ns_per_ms);
    }
    try testing.expectEqualStrings("hello from the first", pasted.slice().?);
    try testing.expect(second.clipboard.pasteFd() == null);

    // The second copies: the first's copy is cancelled (its next paste
    // asks the shell), and the second pastes its own.
    second.clipboard.copy("now the second");
    try second.conn.roundtrip();
    for (0..100) |_| {
        if (first.clipboard.source == null) break;
        try first.conn.dispatchTimeout(10);
    }
    try testing.expect(first.clipboard.source == null);
    var again: Got = .{};
    second.clipboard.paste(again.sink());
    try testing.expectEqualStrings("now the second", again.slice().?);

    // A copy that never comes: the paste gives up, with nothing.
    second.clipboard.source = null;
    var never: Got = .{};
    second.clipboard.paste(never.sink());
    second.clipboard.pending.?.deadline_ms = 0;
    second.clipboard.service();
    try testing.expectEqualStrings("(none)", never.slice().?);
    second.clipboard.source = null;

    first.close();
    second.close();
    thread.join();
}

test "an app window's touches come as its input" {
    var pair: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    var renderer: FakeRenderer = .{};
    const st = try testing.allocator.create(ServerThread);
    defer testing.allocator.destroy(st);
    st.* = .{ .server = .init(testing.allocator, renderer.backend(), .{ .x = 0, .y = 40, .width = 320, .height = 200 }), .fd = pair[0] };
    defer st.server.deinit();
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{st});

    var fake: FakeGpu = .{};
    const win = try app.Window.openOn(testing.allocator, fake.gpu(), try client.Display.fromFd(testing.allocator, pair[1]), "Touched");
    test_frame.begin(try win.beginFrame(), .{ .clear = 0xff000000 });
    try win.present(&test_frame);
    while (win.frame_pending) try win.conn.dispatch();
    try testing.expect(win.touch != null);
    st.send_touch.store(true, .monotonic);
    var got: [8]app.InputEvent = undefined;
    var n: usize = 0;
    for (0..200) |_| {
        try win.wait(5 * std.time.ns_per_ms);
        for (win.takeInput()) |e| if (n < got.len) {
            got[n] = e;
            n += 1;
        };
        if (n >= 3) break;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(app.InputEvent{ .touch_down = .{ .id = 9, .pos = .{ 30, 10 } } }, got[0]);
    try testing.expectEqual(app.InputEvent{ .touch_motion = .{ .id = 9, .pos = .{ 60, 40 } } }, got[1]);
    try testing.expectEqual(app.InputEvent{ .touch_up = 9 }, got[2]);
    win.close();
    thread.join();
}
