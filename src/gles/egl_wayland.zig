//! EGL on Wayland: window surfaces whose buffers are shared with the
//! compositor as dma-bufs.
//!
//! The app creates a `wl_egl_window` for its wl_surface (the standard
//! wayland-egl API) and passes it to eglCreateWindowSurface. Each surface
//! has up to three buffers, rendered by the GPU in its T-tiled layout (the
//! layout its texture unit reads, announced with the BROADCOM_VC4_T_TILED
//! modifier), so the compositor can draw them without copying.
//!
//! eglSwapBuffers renders the frame, waits for the compositor to have shown
//! the previous one (its frame callback; so at most one frame is queued),
//! commits the new one, and picks a buffer the compositor has released for
//! the next frame. A resize takes effect when the next buffer is picked.

const std = @import("std");
const sys = @import("sys");
const vc4 = @import("vc4");
const wayland = @import("wayland");
const context = @import("context.zig");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;
const render = vc4.render;

/// struct wl_egl_window.
pub const Window = struct {
    surface: client.Proxy,
    width: c_int,
    height: c_int,
    /// The size of the last committed buffer.
    attached_width: c_int = 0,
    attached_height: c_int = 0,
};

pub export fn wl_egl_window_create(surface: *const client.Proxy, width: c_int, height: c_int) callconv(.c) ?*Window {
    if (width <= 0 or height <= 0) return null;
    const w = std.heap.page_allocator.create(Window) catch return null;
    w.* = .{ .surface = surface.*, .width = width, .height = height };
    return w;
}

pub export fn wl_egl_window_destroy(w: *Window) callconv(.c) void {
    std.heap.page_allocator.destroy(w);
}

pub export fn wl_egl_window_resize(w: *Window, width: c_int, height: c_int, dx: c_int, dy: c_int) callconv(.c) void {
    _ = dx;
    _ = dy;
    if (width <= 0 or height <= 0) return;
    w.width = width;
    w.height = height;
}

pub export fn wl_egl_window_get_attached_size(w: *Window, width: ?*c_int, height: ?*c_int) callconv(.c) void {
    if (width) |x| x.* = w.attached_width;
    if (height) |x| x.* = w.attached_height;
}

/// What the platform needs from the GPU (a device, or a fake in tests).
pub const Gpu = struct {
    ptr: *anyopaque,
    createBo: *const fn (ptr: *anyopaque, size: u32) anyerror!vc4.Bo,
    destroyBo: *const fn (ptr: *anyopaque, bo: vc4.Bo) void,
    /// A dma-buf file descriptor for a buffer.
    exportBo: *const fn (ptr: *anyopaque, handle: u32) anyerror!std.os.linux.fd_t,

    fn devOf(ptr: *anyopaque) *vc4.Device {
        return @ptrCast(@alignCast(ptr));
    }
    fn devCreateBo(ptr: *anyopaque, size: u32) anyerror!vc4.Bo {
        return devOf(ptr).createBo(size);
    }
    fn devDestroyBo(ptr: *anyopaque, bo: vc4.Bo) void {
        devOf(ptr).destroyBo(bo);
    }
    fn devExportBo(ptr: *anyopaque, handle: u32) anyerror!std.os.linux.fd_t {
        return vc4.drm.exportBuffer(devOf(ptr).fd, handle);
    }

    /// The real GPU. `dev` must stay in place.
    pub fn device(dev: *vc4.Device) Gpu {
        return .{ .ptr = dev, .createBo = devCreateBo, .destroyBo = devDestroyBo, .exportBo = devExportBo };
    }
};

/// The connection's state for EGL: the GPU and the compositor's dma-buf
/// support.
pub const Platform = struct {
    conn: *client.Display,
    gpu: Gpu,
    globals: client.Globals = .{},
    dmabuf: client.Proxy = undefined,
    t_tiled: bool = false,

    /// Binds the compositor's dma-buf global. The platform must stay in
    /// place afterwards (it receives events).
    pub fn init(pl: *Platform) !void {
        const registry = try pl.globals.fetch(pl.conn);
        pl.dmabuf = (try pl.globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = pl, .handler = dmabufEvent })) orelse
            return error.NoDmabuf;
        try pl.conn.roundtrip();
        if (!pl.t_tiled) return error.NoTiledBuffers;
    }

    fn dmabufEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const pl: *Platform = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_linux_dmabuf_v1.event.modifier) return;
        const format = r.uint() catch return;
        const hi = r.uint() catch return;
        const lo = r.uint() catch return;
        if (format == p.fourcc.xrgb8888 and (@as(u64, hi) << 32 | lo) == p.modifier.broadcom_vc4_t_tiled) pl.t_tiled = true;
    }
};

const max_buffers = 3;

const Buffer = struct {
    bo: vc4.Bo,
    proxy: client.Proxy,
    width: u32,
    height: u32,
    /// Committed and not yet released by the compositor.
    busy: bool = false,

    fn target(b: *const Buffer) render.Target {
        return .{ .handle = b.bo.handle, .width = @intCast(b.width), .height = @intCast(b.height), .tiling = render.Target.textureTiling(b.width, b.height) };
    }
};

pub const Surface = struct {
    platform: *Platform,
    window: *Window,
    buffers: [max_buffers]?Buffer = @splat(null),
    back: ?usize = null,
    /// A committed frame whose frame callback has not fired yet.
    frame_pending: bool = false,

    pub fn create(platform: *Platform, window: *Window) !*Surface {
        const s = try std.heap.page_allocator.create(Surface);
        s.* = .{ .platform = platform, .window = window };
        return s;
    }

    pub fn destroy(s: *Surface) void {
        for (&s.buffers) |*slot| if (slot.*) |*b| s.freeBuffer(b, slot);
        s.platform.conn.flush() catch {};
        std.heap.page_allocator.destroy(s);
    }

    pub fn width(s: *const Surface) u32 {
        return @intCast(s.window.width);
    }

    pub fn height(s: *const Surface) u32 {
        return @intCast(s.window.height);
    }

    /// The buffer the next frame renders into.
    pub fn backTarget(s: *Surface) !render.Target {
        const i = s.back orelse try s.pickBack();
        s.back = i;
        return s.buffers[i].?.target();
    }

    fn pickBack(s: *Surface) !usize {
        const w = s.width();
        const h = s.height();
        while (true) {
            // A free buffer of the right size; otherwise replace a free one
            // of the wrong size, or use an empty slot.
            var empty: ?usize = null;
            var stale: ?usize = null;
            for (&s.buffers, 0..) |*slot, i| {
                if (slot.*) |*b| {
                    if (b.busy) continue;
                    if (b.width == w and b.height == h) return i;
                    stale = i;
                } else empty = i;
            }
            if (stale) |i| {
                s.freeBuffer(&s.buffers[i].?, &s.buffers[i]);
                empty = i;
            }
            if (empty) |i| {
                s.buffers[i] = try s.allocBuffer(w, h, i);
                return i;
            }
            // All buffers are with the compositor: wait for a release.
            try s.platform.conn.dispatch();
        }
    }

    fn allocBuffer(s: *Surface, w: u32, h: u32, slot: usize) !Buffer {
        const pl = s.platform;
        const bo = try pl.gpu.createBo(pl.gpu.ptr, vc4.texture.imageSize(w, h));
        errdefer pl.gpu.destroyBo(pl.gpu.ptr, bo);
        const fd = try pl.gpu.exportBo(pl.gpu.ptr, bo.handle);
        const conn = pl.conn;
        const params = try conn.newObject(null);
        var m = try pl.dmabuf.request(p.zwp_linux_dmabuf_v1.request.create_params);
        m.uint(params.id).end();
        const mod = p.modifier.broadcom_vc4_t_tiled;
        m = try params.request(p.zwp_linux_buffer_params_v1.request.add);
        m.fd(fd).uint(0).uint(0).uint(w * 4).uint(@truncate(mod >> 32)).uint(@truncate(mod)).end();
        const proxy = try conn.newObject(.{ .ptr = &s.buffers[slot], .handler = bufferEvent });
        m = try params.request(p.zwp_linux_buffer_params_v1.request.create_immed);
        m.uint(proxy.id).int(@intCast(w)).int(@intCast(h)).uint(p.fourcc.xrgb8888).uint(0).end();
        m = try params.request(p.zwp_linux_buffer_params_v1.request.destroy);
        m.end();
        return .{ .bo = bo, .proxy = proxy, .width = w, .height = h };
    }

    fn freeBuffer(s: *Surface, b: *Buffer, slot: *?Buffer) void {
        if (b.proxy.request(p.wl_buffer.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        s.platform.conn.forget(b.proxy.id);
        s.platform.gpu.destroyBo(s.platform.gpu.ptr, b.bo);
        slot.* = null;
    }

    fn bufferEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const slot: *?Buffer = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_buffer.event.release) if (slot.*) |*b| {
            b.busy = false;
        };
    }

    fn frameDone(ptr: ?*anyopaque, _: *client.Display, _: u32, _: u16, _: *wire.Reader) void {
        const s: *Surface = @ptrCast(@alignCast(ptr.?));
        s.frame_pending = false;
    }

    /// Renders the frame, shows it, and sets up the next one.
    pub fn swap(s: *Surface, ctx: *context.Context) !void {
        ctx.submit();
        const conn = s.platform.conn;
        while (s.frame_pending) try conn.dispatch();
        const i = s.back orelse return;
        const b = &s.buffers[i].?;
        const surface = s.window.surface;
        var m = try surface.request(p.wl_surface.request.attach);
        m.uint(b.proxy.id).int(0).int(0).end();
        m = try surface.request(p.wl_surface.request.damage_buffer);
        m.int(0).int(0).int(@intCast(b.width)).int(@intCast(b.height)).end();
        const cb = try conn.newObject(.{ .ptr = s, .handler = frameDone });
        m = try surface.request(p.wl_surface.request.frame);
        m.uint(cb.id).end();
        m = try surface.request(p.wl_surface.request.commit);
        m.end();
        try conn.flush();
        b.busy = true;
        s.frame_pending = true;
        s.window.attached_width = @intCast(b.width);
        s.window.attached_height = @intCast(b.height);
        s.back = null;
        ctx.setTarget(try s.backTarget());
    }
};
