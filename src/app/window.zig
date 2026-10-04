//! A native app's window: a Wayland xdg toplevel on the shell, the seat's
//! pointer and keyboard, and the buffers the app renders into.
//!
//! The window has up to three buffers of its current size, rendered by the
//! GPU in the tiled layout its texture unit reads (announced with the
//! BROADCOM_VC4_T_TILED modifier) and shared with the shell as dma-bufs,
//! so the shell can draw them, or show them on the display directly,
//! without copying.
//!
//! `beginFrame` picks a buffer the shell has released; `present` renders
//! the frame, waits for the shell to have shown the previous one (its frame
//! callback, so at most one frame is queued) and commits the new one. A
//! resize takes effect at the next `beginFrame`.
//!
//! While another window covers it, the shell says the window is
//! `suspended` and holds its frame callbacks: the app should not draw
//! (nothing would be seen), and the window frees the buffers it is not
//! using, for the app in front. GPU memory is scarce (every buffer comes
//! from the kernel's CMA pool), so a buffer that cannot be had waits for
//! one to be released, or for memory to be freed.

const std = @import("std");
const linux = std.os.linux;
const vc4 = @import("vc4");
const wayland = @import("wayland");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

/// What a window needs from the GPU.
pub const Gpu = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBo: *const fn (ptr: *anyopaque, size: u32) anyerror!vc4.Bo,
        destroyBo: *const fn (ptr: *anyopaque, bo: vc4.Bo) void,
        /// A dma-buf file descriptor for a buffer.
        exportBo: *const fn (ptr: *anyopaque, handle: u32) anyerror!linux.fd_t,
        /// Submits a frame and waits for the GPU to finish it.
        run: *const fn (ptr: *anyopaque, frame: *vc4.render.Frame) anyerror!void,
    };

    fn devOf(ptr: *anyopaque) *vc4.Device {
        return @ptrCast(@alignCast(ptr));
    }
    fn devCreateBo(ptr: *anyopaque, size: u32) anyerror!vc4.Bo {
        return devOf(ptr).createBo(size);
    }
    fn devDestroyBo(ptr: *anyopaque, bo: vc4.Bo) void {
        devOf(ptr).destroyBo(bo);
    }
    fn devExportBo(ptr: *anyopaque, handle: u32) anyerror!linux.fd_t {
        return vc4.drm.exportBuffer(devOf(ptr).fd, handle);
    }
    fn devRun(ptr: *anyopaque, frame: *vc4.render.Frame) anyerror!void {
        const dev = devOf(ptr);
        _ = frame.finish();
        // One job per region the frame is limited to.
        var seqno: ?u64 = null;
        for (0..frame.regionCount()) |i| seqno = try dev.submit(frame.submitRegion(i));
        if (seqno) |s| try dev.waitSeqno(s, std.time.ns_per_s);
    }

    /// The real GPU. `dev` must stay in place.
    pub fn device(dev: *vc4.Device) Gpu {
        return .{ .ptr = dev, .vtable = &.{ .createBo = devCreateBo, .destroyBo = devDestroyBo, .exportBo = devExportBo, .run = devRun } };
    }
};

pub const InputEvent = union(enum) {
    /// The pointer moved to (or entered at) a position in the window.
    motion: [2]f32,
    /// A Linux button code (BTN_LEFT, ...), and where the pointer was.
    button: struct { pos: [2]f32, code: u32, pressed: bool },
    /// A Linux key code (KEY_A, ...).
    key: struct { code: u32, pressed: bool },
};

/// Used when the compositor leaves the size to us.
const default_size = [2]u32{ 1280, 720 };

const max_buffers = 3;

const Buffer = struct {
    /// The frame (counting from 1) last drawn in it; 0 if none.
    drawn: u64 = 0,
    bo: vc4.Bo,
    proxy: client.Proxy,
    width: u32,
    height: u32,
    /// Committed and not yet released by the compositor.
    busy: bool = false,

    fn target(b: *const Buffer) vc4.render.Target {
        return .{ .handle = b.bo.handle, .width = @intCast(b.width), .height = @intCast(b.height), .tiling = vc4.render.Target.textureTiling(b.width, b.height) };
    }
};

pub const Window = struct {
    gpa: std.mem.Allocator,
    gpu: Gpu,
    conn: *client.Display,
    globals: client.Globals = .{},
    wm_base: client.Proxy = undefined,
    dmabuf: client.Proxy = undefined,
    t_tiled: bool = false,
    surface: client.Proxy = undefined,
    xdg_surface: client.Proxy = undefined,
    toplevel: client.Proxy = undefined,
    /// The size frames are rendered at.
    width: u32 = default_size[0],
    height: u32 = default_size[1],
    /// From the last toplevel configure (0 = our choice).
    next_size: [2]i32 = .{ 0, 0 },
    /// A configure to acknowledge.
    pending_serial: ?u32 = null,
    closed: bool = false,
    /// Covered by another window: there is no point drawing.
    suspended: bool = false,
    /// Filling the screen (the shell's configure says so); otherwise half
    /// the screen, and movable.
    maximized: bool = true,
    /// The serial of the last pointer button press, for asking the shell
    /// to move the window from it.
    press_serial: u32 = 0,

    buffers: [max_buffers]?Buffer = @splat(null),
    /// The buffer the frame being recorded renders into.
    back: ?usize = null,
    /// A committed frame whose frame callback has not fired yet.
    frame_pending: bool = false,
    /// Frames shown so far.
    frames: u64 = 0,

    seat: ?client.Proxy = null,
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,
    pointer_pos: [2]f32 = .{ 0, 0 },
    /// Input since the last `takeInput`.
    input: [64]InputEvent = undefined,
    input_len: usize = 0,

    /// Connects to the compositor listening on `path` and opens a window.
    pub fn open(gpa: std.mem.Allocator, gpu: Gpu, path: []const u8, title: []const u8) !*Window {
        const conn = try client.Display.connect(gpa, path);
        errdefer conn.disconnect();
        return openOn(gpa, gpu, conn, title);
    }

    /// Opens a window on an existing connection, which the window then
    /// owns. Waits for the first configure.
    pub fn openOn(gpa: std.mem.Allocator, gpu: Gpu, conn: *client.Display, title: []const u8) !*Window {
        const w = try gpa.create(Window);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .gpu = gpu, .conn = conn };
        const registry = try w.globals.fetch(conn);
        const compositor = (try w.globals.bind(registry, p.wl_compositor.name, 4, null)) orelse return error.NoCompositor;
        // Version 6 for the suspended state.
        w.wm_base = (try w.globals.bind(registry, p.xdg_wm_base.name, 6, .{ .ptr = w, .handler = wmBaseEvent })) orelse return error.NoXdgShell;
        w.dmabuf = (try w.globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = w, .handler = dmabufEvent })) orelse return error.NoDmabuf;
        // Optional: the pointer and keyboard come with the seat's capabilities.
        w.seat = try w.globals.bind(registry, p.wl_seat.name, 5, .{ .ptr = w, .handler = seatEvent });

        w.surface = try conn.newObject(null);
        var m = try compositor.request(p.wl_compositor.request.create_surface);
        m.uint(w.surface.id).end();
        w.xdg_surface = try conn.newObject(.{ .ptr = w, .handler = xdgSurfaceEvent });
        m = try w.wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(w.xdg_surface.id).uint(w.surface.id).end();
        w.toplevel = try conn.newObject(.{ .ptr = w, .handler = toplevelEvent });
        m = try w.xdg_surface.request(p.xdg_surface.request.get_toplevel);
        m.uint(w.toplevel.id).end();
        m = try w.toplevel.request(p.xdg_toplevel.request.set_title);
        m.string(title).end();
        // The initial commit, without a buffer, asks for the first configure.
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        while (w.pending_serial == null) try conn.dispatch();
        if (!w.t_tiled) return error.NoTiledBuffers;
        _ = try w.applyConfigure();
        return w;
    }

    /// Frees the buffers and disconnects.
    pub fn close(w: *Window) void {
        for (&w.buffers) |*slot| if (slot.*) |*b| w.freeBuffer(b, slot);
        w.conn.flush() catch {};
        w.conn.disconnect();
        w.gpa.destroy(w);
    }

    pub fn setAppId(w: *Window, app_id: []const u8) !void {
        var m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
        m.string(app_id).end();
    }

    /// Handles events that have arrived, without waiting.
    pub fn poll(w: *Window) !void {
        _ = try w.conn.dispatchPending();
    }

    /// Asks the shell to fill the screen with the window, or to make it
    /// half the screen again; a configure follows.
    pub fn setMaximized(w: *Window, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_maximized else p.xdg_toplevel.request.unset_maximized) catch return;
        m.end();
        w.conn.flush() catch {};
    }

    /// Asks the shell to move the window with the pointer, from the button
    /// press just handled (dragging the title bar), until it is released.
    pub fn startMove(w: *Window) void {
        const seat = w.seat orelse return;
        var m = w.toplevel.request(p.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(w.press_serial).end();
        w.conn.flush() catch {};
    }

    /// Waits for events (input, a configure, a released buffer) for up to
    /// `timeout_ns`, and handles them: for when there is nothing to draw.
    pub fn wait(w: *Window, timeout_ns: u64) !void {
        try w.conn.dispatchTimeout(@intCast(@min(std.math.divCeil(u64, timeout_ns, std.time.ns_per_ms) catch 0, std.math.maxInt(i32))));
    }

    /// Acknowledges a pending configure. Returns the new size if it changed;
    /// frames are rendered at it from the next `beginFrame`.
    pub fn applyConfigure(w: *Window) !?[2]u32 {
        const serial = w.pending_serial orelse return null;
        w.pending_serial = null;
        const size = [2]u32{
            if (w.next_size[0] > 0) @intCast(w.next_size[0]) else w.width,
            if (w.next_size[1] > 0) @intCast(w.next_size[1]) else w.height,
        };
        var m = try w.xdg_surface.request(p.xdg_surface.request.ack_configure);
        m.uint(serial).end();
        if (size[0] == w.width and size[1] == w.height) return null;
        w.width = size[0];
        w.height = size[1];
        return size;
    }

    /// The render target for the next frame: a buffer of the window's size
    /// the compositor is not using (waiting for one if need be).
    pub fn beginFrame(w: *Window) !vc4.render.Target {
        const i = w.back orelse try w.pickBack();
        w.back = i;
        return w.buffers[i].?.target();
    }

    /// Renders `frame` (begun on `beginFrame`'s target), and shows it once
    /// the compositor has shown the previous one: `render`, then `show`.
    pub fn present(w: *Window, frame: *vc4.render.Frame) !void {
        try w.render(frame);
        try w.show();
    }

    /// Renders `frame` (begun on `beginFrame`'s target), waiting for the
    /// GPU.
    pub fn render(w: *Window, frame: *vc4.render.Frame) !void {
        try w.gpu.vtable.run(w.gpu.ptr, frame);
    }

    /// How many frames ago the buffer `beginFrame` gave was last drawn: 1
    /// if in the frame before, 0 if never (its contents are unknown). Only
    /// what changed since then needs drawing into it (see
    /// `vc4.render.Frame.limitTo`).
    pub fn bufferAge(w: *const Window) u32 {
        const i = w.back orelse return 0;
        const b = &w.buffers[i].?;
        if (b.drawn == 0) return 0;
        return @intCast(@min(w.frames + 1 - b.drawn, std.math.maxInt(u32)));
    }

    /// Hands the rendered frame to the compositor, once it has shown the
    /// previous one, saying the whole window changed.
    pub fn show(w: *Window) !void {
        return w.showDamaged(null);
    }

    /// Like `show`, saying which parts of the window changed since the
    /// last frame shown (all of it if null).
    pub fn showDamaged(w: *Window, damage: ?[]const vc4.render.Viewport) !void {
        while (w.frame_pending) {
            try w.conn.dispatch();
            // Covered while waiting: the callback comes when it is in
            // front again.
            if (w.suspended) w.releaseSpareBuffers();
        }
        const i = w.back orelse return error.NoFrameBegun;
        const b = &w.buffers[i].?;
        var m = try w.surface.request(p.wl_surface.request.attach);
        m.uint(b.proxy.id).int(0).int(0).end();
        if (damage) |rects| {
            for (rects) |r| {
                m = try w.surface.request(p.wl_surface.request.damage_buffer);
                m.int(r.x).int(r.y).int(@intCast(r.width)).int(@intCast(r.height)).end();
            }
        } else {
            m = try w.surface.request(p.wl_surface.request.damage_buffer);
            m.int(0).int(0).int(@intCast(b.width)).int(@intCast(b.height)).end();
        }
        const cb = try w.conn.newObject(.{ .ptr = w, .handler = frameDone });
        m = try w.surface.request(p.wl_surface.request.frame);
        m.uint(cb.id).end();
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        try w.conn.flush();
        b.busy = true;
        w.frames += 1;
        b.drawn = w.frames;
        w.frame_pending = true;
        w.back = null;
    }

    /// The input events received since the last call. The slice is valid
    /// until the next `poll`.
    pub fn takeInput(w: *Window) []const InputEvent {
        defer w.input_len = 0;
        return w.input[0..w.input_len];
    }

    // --- Buffers ----------------------------------------------------------------

    fn pickBack(w: *Window) !usize {
        var out_of_memory_waits: u32 = 0;
        while (true) {
            // A free buffer of the right size; otherwise replace a free one
            // of the wrong size, or use an empty slot.
            var empty: ?usize = null;
            var stale: ?usize = null;
            for (&w.buffers, 0..) |*slot, i| {
                if (slot.*) |*b| {
                    if (b.busy) continue;
                    if (b.width == w.width and b.height == w.height) return i;
                    stale = i;
                } else empty = i;
            }
            if (stale) |i| {
                w.freeBuffer(&w.buffers[i].?, &w.buffers[i]);
                empty = i;
            }
            if (empty) |i| {
                if (w.allocBuffer(i)) |b| {
                    w.buffers[i] = b;
                    return i;
                } else |err| {
                    if (err != error.OutOfMemory) return err;
                    // No GPU memory for another buffer: make do with those
                    // there are, or wait for some to be freed.
                    const busy = for (w.buffers) |slot| {
                        if (slot) |b| if (b.busy) break true;
                    } else false;
                    if (!busy) {
                        out_of_memory_waits += 1;
                        if (out_of_memory_waits > 40) return err;
                        try w.conn.dispatchTimeout(50);
                        continue;
                    }
                }
            }
            // All buffers are with the compositor: wait for a release.
            try w.conn.dispatch();
        }
    }

    /// Frees the buffers the compositor does not have and no frame is
    /// being drawn into: while the window is covered, the memory is better
    /// used by the window in front.
    pub fn releaseSpareBuffers(w: *Window) void {
        for (&w.buffers, 0..) |*slot, i| if (slot.*) |*b| {
            if (b.busy or w.back == i) continue;
            w.freeBuffer(b, slot);
        };
    }

    fn allocBuffer(w: *Window, slot: usize) !Buffer {
        const gpu = w.gpu;
        const bo = try gpu.vtable.createBo(gpu.ptr, vc4.texture.imageSize(w.width, w.height));
        errdefer gpu.vtable.destroyBo(gpu.ptr, bo);
        const fd = try gpu.vtable.exportBo(gpu.ptr, bo.handle);
        const params = try w.conn.newObject(null);
        var m = try w.dmabuf.request(p.zwp_linux_dmabuf_v1.request.create_params);
        m.uint(params.id).end();
        const mod = p.modifier.broadcom_vc4_t_tiled;
        m = try params.request(p.zwp_linux_buffer_params_v1.request.add);
        m.fd(fd).uint(0).uint(0).uint(w.width * 4).uint(@truncate(mod >> 32)).uint(@truncate(mod)).end();
        const proxy = try w.conn.newObject(.{ .ptr = &w.buffers[slot], .handler = bufferEvent });
        m = try params.request(p.zwp_linux_buffer_params_v1.request.create_immed);
        m.uint(proxy.id).int(@intCast(w.width)).int(@intCast(w.height)).uint(p.fourcc.xrgb8888).uint(0).end();
        m = try params.request(p.zwp_linux_buffer_params_v1.request.destroy);
        m.end();
        return .{ .bo = bo, .proxy = proxy, .width = w.width, .height = w.height };
    }

    fn freeBuffer(w: *Window, b: *Buffer, slot: *?Buffer) void {
        if (b.proxy.request(p.wl_buffer.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(b.proxy.id);
        w.gpu.vtable.destroyBo(w.gpu.ptr, b.bo);
        slot.* = null;
    }

    fn bufferEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const slot: *?Buffer = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_buffer.event.release) if (slot.*) |*b| {
            b.busy = false;
        };
    }

    fn frameDone(ptr: ?*anyopaque, _: *client.Display, _: u32, _: u16, _: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        w.frame_pending = false;
    }

    fn dmabufEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_linux_dmabuf_v1.event.modifier) return;
        const format = r.uint() catch return;
        const hi = r.uint() catch return;
        const lo = r.uint() catch return;
        if (format == p.fourcc.xrgb8888 and (@as(u64, hi) << 32 | lo) == p.modifier.broadcom_vc4_t_tiled) w.t_tiled = true;
    }

    // --- Shell and input --------------------------------------------------------

    fn pushInput(w: *Window, e: InputEvent) void {
        // Coalesce motion; drop events if nobody is reading them.
        if (e == .motion and w.input_len > 0 and w.input[w.input_len - 1] == .motion) {
            w.input[w.input_len - 1] = e;
            return;
        }
        if (w.input_len == w.input.len) return;
        w.input[w.input_len] = e;
        w.input_len += 1;
    }

    fn seatEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_seat.event.capabilities) return;
        const caps = r.uint() catch return;
        if (caps & p.wl_seat.capability.pointer != 0 and w.pointer == null) {
            const pointer = d.newObject(.{ .ptr = w, .handler = pointerEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_pointer) catch return;
            m.uint(pointer.id).end();
            w.pointer = pointer;
        }
        if (caps & p.wl_seat.capability.keyboard != 0 and w.keyboard == null) {
            const keyboard = d.newObject(.{ .ptr = w, .handler = keyboardEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_keyboard) catch return;
            m.uint(keyboard.id).end();
            w.keyboard = keyboard;
        }
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_pointer.event.enter, p.wl_pointer.event.motion => {
                // enter: serial, surface; motion: time.
                _ = r.uint() catch return;
                if (opcode == p.wl_pointer.event.enter) _ = r.uint() catch return;
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                w.pointer_pos = .{ @floatCast(x), @floatCast(y) };
                w.pushInput(.{ .motion = w.pointer_pos });
            },
            p.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // time
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                if (state == p.wl_pointer.button_state.pressed) w.press_serial = serial;
                w.pushInput(.{ .button = .{ .pos = w.pointer_pos, .code = code, .pressed = state == p.wl_pointer.button_state.pressed } });
            },
            else => {},
        }
    }

    fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            // No keymap is needed for evdev codes; just close it.
            p.wl_keyboard.event.keymap => {
                _ = r.uint() catch return;
                const fd = r.fd() catch return;
                _ = linux.close(fd);
            },
            p.wl_keyboard.event.key => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // time
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                w.pushInput(.{ .key = .{ .code = code, .pressed = state == p.wl_keyboard.key_state.pressed } });
            },
            else => {},
        }
    }

    fn wmBaseEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.xdg_wm_base.event.ping) return;
        const serial = r.uint() catch return;
        var m = w.wm_base.request(p.xdg_wm_base.request.pong) catch return;
        m.uint(serial).end();
    }

    fn xdgSurfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.xdg_surface.event.configure) w.pending_serial = r.uint() catch return;
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.xdg_toplevel.event.configure => {
                w.next_size = .{ r.int() catch 0, r.int() catch 0 };
                const states = r.array() catch &.{};
                var suspended = false;
                var maximized = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
                    p.xdg_toplevel.state.suspended => suspended = true,
                    p.xdg_toplevel.state.maximized => maximized = true,
                    else => {},
                };
                w.suspended = suspended;
                w.maximized = maximized;
            },
            p.xdg_toplevel.event.close => w.closed = true,
            else => {},
        }
    }
};
