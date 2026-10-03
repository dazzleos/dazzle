//! The shell's Wayland server: clients, their objects, and the protocol.
//!
//! Supported globals: wl_compositor (surfaces; regions are accepted and
//! ignored), wl_shm (ARGB8888 and XRGB8888, copied to the GPU at commit),
//! zwp_linux_dmabuf_v1 (buffers in the VideoCore IV's T-tiled layout, used
//! by the GPU directly) and xdg_wm_base (toplevel windows; popups are not
//! supported).
//!
//! Windows are maximized into the work area below the shell's bar, and the
//! most recently mapped one is shown. The server does not draw: it keeps the
//! state the renderer needs (`topWindow`), and gets textures from the
//! renderer through `Backend`, so it can run without a GPU in tests.
//!
//! Frame pacing: frame callbacks committed with a surface fire after the
//! next frame that shows it has been presented. Because the renderer waits
//! for each composited frame to finish, a client buffer is released as soon
//! as a newer one is committed.

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");
const wire = wayland.wire;
const p = wayland.protocol;

const log = std.log.scoped(.shell);

pub const Texture = struct {
    /// The renderer's handle for the texture.
    handle: u32,
    width: u32,
    height: u32,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Imports a T-tiled dma-buf as a texture. Takes ownership of `fd`.
        importDmabuf: *const fn (ptr: *anyopaque, fd: linux.fd_t, width: u32, height: u32) anyerror!Texture,
        /// Copies 32-bit pixels into a texture, reusing `existing` if it has
        /// the same size.
        uploadPixels: *const fn (ptr: *anyopaque, existing: ?Texture, pixels: []const u8, width: u32, height: u32, stride: u32) anyerror!Texture,
        destroyTexture: *const fn (ptr: *anyopaque, t: Texture) void,
    };
};

pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

const globals = [_]struct { name: []const u8, version: u32 }{
    .{ .name = p.wl_compositor.name, .version = p.wl_compositor.version },
    .{ .name = p.wl_shm.name, .version = p.wl_shm.version },
    .{ .name = p.xdg_wm_base.name, .version = p.xdg_wm_base.version },
    .{ .name = p.zwp_linux_dmabuf_v1.name, .version = p.zwp_linux_dmabuf_v1.version },
};

const Object = union(enum) {
    display,
    registry,
    callback,
    compositor,
    surface: *Surface,
    region,
    shm,
    shm_pool: *ShmPool,
    buffer: *Buffer,
    wm_base,
    positioner,
    xdg_surface: *XdgSurface,
    toplevel: *Toplevel,
    dmabuf,
    params: *Params,
};

pub const Surface = struct {
    client: *Client,
    id: u32,
    pending_buffer: ?*Buffer = null,
    pending_attach: bool = false,
    pending_callbacks: std.ArrayList(u32) = .empty,
    /// The dmabuf buffer being shown, if any.
    buffer: ?*Buffer = null,
    /// A copy of the last shm buffer, owned by the surface.
    copy: ?Texture = null,
    xdg: ?*XdgSurface = null,

    pub fn texture(s: *const Surface) ?Texture {
        if (s.buffer) |b| return b.dmabuf;
        return s.copy;
    }
};

pub const ShmPool = struct {
    map: []align(std.heap.page_size_min) u8,
    fd: linux.fd_t,
    /// The pool object and its buffers.
    refs: u32 = 1,

    fn unref(pool: *ShmPool, gpa: std.mem.Allocator) void {
        pool.refs -= 1;
        if (pool.refs > 0) return;
        _ = linux.munmap(pool.map.ptr, pool.map.len);
        _ = linux.close(pool.fd);
        gpa.destroy(pool);
    }
};

pub const Buffer = struct {
    client: *Client,
    id: u32,
    width: u32,
    height: u32,
    /// Set for dmabuf buffers.
    dmabuf: ?Texture = null,
    /// Set for shm buffers.
    shm: ?struct { pool: *ShmPool, offset: u32, stride: u32 } = null,
    /// Surfaces showing it (dmabuf buffers only).
    uses: u32 = 0,
    destroyed: bool = false,
};

pub const XdgSurface = struct {
    /// Null once the wl_surface has been destroyed.
    surface: ?*Surface,
    id: u32,
    toplevel: ?*Toplevel = null,
    configured: bool = false,
};

pub const Toplevel = struct {
    xdg: *XdgSurface,
    id: u32,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    mapped: bool = false,

    pub fn title(t: *const Toplevel) []const u8 {
        return t.title_buf[0..t.title_len];
    }
};

pub const Params = struct {
    fd: ?linux.fd_t = null,
    modifier: u64 = 0,
    used: bool = false,
};

pub const Client = struct {
    server: *Server,
    conn: wire.Connection,
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    dead: bool = false,
    pid: ?linux.pid_t = null,

    fn send(c: *Client, object: u32, opcode: u16) ?wire.Builder {
        if (c.dead) return null;
        return c.conn.begin(object, opcode) catch {
            c.dead = true;
            return null;
        };
    }

    fn postError(c: *Client, object: u32, code: u32, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "error";
        log.info("client error on object {d}: {s}", .{ object, msg });
        if (c.send(p.wl_display.id, p.wl_display.event.@"error")) |m0| {
            var m = m0;
            m.uint(object).uint(code).string(msg).end();
        }
        c.conn.flush() catch {};
        c.dead = true;
    }

    fn deleteId(c: *Client, id: u32) void {
        _ = c.objects.remove(id);
        if (c.send(p.wl_display.id, p.wl_display.event.delete_id)) |m0| {
            var m = m0;
            m.uint(id).end();
        }
    }

    fn addObject(c: *Client, id: u32, object: Object) !void {
        if (id == 0 or id >= 0xff000000 or c.objects.contains(id)) {
            c.postError(p.wl_display.id, p.wl_display.err.invalid_object, "invalid new object ID {d}", .{id});
            return error.ProtocolError;
        }
        try c.objects.put(c.server.gpa, id, object);
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    backend: Backend,
    clients: std.ArrayList(*Client) = .empty,
    /// Toplevels in stacking order, bottom first.
    toplevels: std.ArrayList(*Toplevel) = .empty,
    /// Where windows go.
    work_area: Rect,
    serial: u32 = 0,
    /// Something visible changed since the last frame.
    damaged: bool = true,
    /// Frame callbacks to fire after the next presented frame.
    frame_callbacks: std.ArrayList(struct { client: *Client, id: u32 }) = .empty,

    pub fn init(gpa: std.mem.Allocator, backend: Backend, work_area: Rect) Server {
        return .{ .gpa = gpa, .backend = backend, .work_area = work_area };
    }

    pub fn deinit(s: *Server) void {
        while (s.clients.items.len > 0) s.removeClient(s.clients.items[0]);
        s.clients.deinit(s.gpa);
        s.toplevels.deinit(s.gpa);
        s.frame_callbacks.deinit(s.gpa);
    }

    /// Adds a client connected on `fd`.
    pub fn addClient(s: *Server, fd: linux.fd_t) !*Client {
        const c = try s.gpa.create(Client);
        c.* = .{ .server = s, .conn = .init(fd) };
        errdefer s.gpa.destroy(c);
        try c.objects.put(s.gpa, p.wl_display.id, .display);
        try s.clients.append(s.gpa, c);
        return c;
    }

    /// Reads and handles a client's requests. Disconnects (and frees) it on
    /// errors or when it hangs up; returns whether it is still connected.
    pub fn dispatch(s: *Server, c: *Client) bool {
        while (!c.dead) {
            while (!c.dead) {
                const m = (c.conn.next() catch {
                    c.postError(p.wl_display.id, p.wl_display.err.invalid_method, "malformed message", .{});
                    break;
                }) orelse break;
                var r = wire.Reader.init(&c.conn, m);
                s.handle(c, m, &r) catch |err| {
                    if (!c.dead) c.postError(m.object, p.wl_display.err.invalid_method, "bad request {d} ({s})", .{ m.opcode, @errorName(err) });
                };
            }
            _ = c.conn.read() catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    c.dead = true;
                    break;
                },
            };
        }
        if (!c.dead) c.conn.flush() catch {
            c.dead = true;
        };
        if (c.dead) {
            s.removeClient(c);
            return false;
        }
        return true;
    }

    /// Flushes every client's events.
    pub fn flushClients(s: *Server) void {
        var i: usize = 0;
        while (i < s.clients.items.len) {
            const c = s.clients.items[i];
            c.conn.flush() catch {
                s.removeClient(c);
                continue;
            };
            i += 1;
        }
    }

    pub fn removeClient(s: *Server, c: *Client) void {
        // Objects refer to each other, so they go in order: what surfaces
        // show, toplevels, xdg_surfaces, surfaces, then the rest, and
        // buffers last.
        var it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .surface => |surf| if (surf.buffer) |b| {
                surf.buffer = null;
                b.uses -= 1;
                // Buffers the client already destroyed are not in its map.
                if (b.destroyed and b.uses == 0) s.freeBuffer(b);
            },
            else => {},
        };
        inline for (.{ .toplevel, .xdg_surface, .surface }) |tag| {
            it = c.objects.iterator();
            while (it.next()) |e| if (e.value_ptr.* == tag) s.destroyObject(c, e.value_ptr.*);
        }
        it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .toplevel, .xdg_surface, .surface, .buffer => {},
            else => s.destroyObject(c, e.value_ptr.*),
        };
        it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .buffer => |b| s.freeBuffer(b),
            else => {},
        };
        var i: usize = 0;
        while (i < s.frame_callbacks.items.len) {
            if (s.frame_callbacks.items[i].client == c) _ = s.frame_callbacks.swapRemove(i) else i += 1;
        }
        c.objects.deinit(s.gpa);
        c.conn.deinit();
        for (s.clients.items, 0..) |x, j| if (x == c) {
            _ = s.clients.orderedRemove(j);
            break;
        };
        s.gpa.destroy(c);
        s.damaged = true;
    }

    /// Frees an object's resources, except buffers (see removeClient).
    fn destroyObject(s: *Server, c: *Client, o: Object) void {
        _ = c;
        switch (o) {
            .surface => |surf| s.destroySurface(surf),
            .shm_pool => |pool| pool.unref(s.gpa),
            .xdg_surface => |x| {
                if (x.surface) |surf| surf.xdg = null;
                s.gpa.destroy(x);
            },
            .toplevel => |t| s.destroyToplevel(t),
            .params => |pr| {
                if (pr.fd) |fd| _ = linux.close(fd);
                s.gpa.destroy(pr);
            },
            else => {},
        }
    }

    fn destroySurface(s: *Server, surf: *Surface) void {
        s.setBuffer(surf, null);
        if (surf.copy) |t| s.backend.vtable.destroyTexture(s.backend.ptr, t);
        // Frame callbacks of a destroyed surface never fire.
        for (surf.pending_callbacks.items) |id| _ = surf.client.objects.remove(id);
        surf.pending_callbacks.deinit(s.gpa);
        if (surf.xdg) |x| {
            // The xdg_surface lives on, without a surface.
            if (x.toplevel) |t| s.unmap(t);
            x.surface = null;
        }
        s.gpa.destroy(surf);
    }

    fn destroyToplevel(s: *Server, t: *Toplevel) void {
        s.unmap(t);
        t.xdg.toplevel = null;
        s.gpa.destroy(t);
    }

    fn unmap(s: *Server, t: *Toplevel) void {
        for (s.toplevels.items, 0..) |x, i| if (x == t) {
            _ = s.toplevels.orderedRemove(i);
            break;
        };
        t.mapped = false;
        s.damaged = true;
    }

    fn freeBuffer(s: *Server, b: *Buffer) void {
        if (b.dmabuf) |t| s.backend.vtable.destroyTexture(s.backend.ptr, t);
        if (b.shm) |shm| shm.pool.unref(s.gpa);
        s.gpa.destroy(b);
    }

    /// Makes `b` the dmabuf a surface shows, releasing the previous one.
    fn setBuffer(s: *Server, surf: *Surface, b: ?*Buffer) void {
        if (surf.buffer == b) return;
        if (surf.buffer) |old| {
            old.uses -= 1;
            if (old.destroyed and old.uses == 0) {
                s.freeBuffer(old);
            } else sendRelease(old);
        }
        surf.buffer = b;
        if (b) |nb| nb.uses += 1;
    }

    fn sendRelease(b: *Buffer) void {
        if (b.destroyed) return;
        if (b.client.send(b.id, p.wl_buffer.event.release)) |m0| {
            var m = m0;
            m.end();
        }
    }

    /// The window to show: the top mapped toplevel.
    pub fn topWindow(s: *const Server) ?*Toplevel {
        var i = s.toplevels.items.len;
        while (i > 0) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (t.mapped and t.xdg.surface != null and t.xdg.surface.?.texture() != null) return t;
        }
        return null;
    }

    /// Fires frame callbacks once a frame has reached the screen.
    pub fn framePresented(s: *Server, time_ms: u32) void {
        for (s.frame_callbacks.items) |fc| {
            if (fc.client.send(fc.id, p.wl_callback.event.done)) |m0| {
                var m = m0;
                m.uint(time_ms).end();
            }
            fc.client.deleteId(fc.id);
        }
        s.frame_callbacks.clearRetainingCapacity();
        s.damaged = false;
        s.flushClients();
    }

    fn nextSerial(s: *Server) u32 {
        s.serial +%= 1;
        return s.serial;
    }

    // --- Requests -------------------------------------------------------------

    fn handle(s: *Server, c: *Client, m: wire.Message, r: *wire.Reader) !void {
        const object = c.objects.get(m.object) orelse {
            // Requests to objects the client just destroyed can race with
            // delete_id; they are ignored.
            return;
        };
        switch (object) {
            .display => switch (m.opcode) {
                p.wl_display.request.sync => {
                    const id = try r.uint();
                    try c.addObject(id, .callback);
                    if (c.send(id, p.wl_callback.event.done)) |m0| {
                        var e = m0;
                        e.uint(s.serial).end();
                    }
                    c.deleteId(id);
                },
                p.wl_display.request.get_registry => {
                    const id = try r.uint();
                    try c.addObject(id, .registry);
                    for (globals, 1..) |g, name| if (c.send(id, p.wl_registry.event.global)) |m0| {
                        var e = m0;
                        e.uint(@intCast(name)).string(g.name).uint(g.version).end();
                    };
                },
                else => return error.InvalidOpcode,
            },
            .registry => {
                if (m.opcode != p.wl_registry.request.bind) return error.InvalidOpcode;
                const name = try r.uint();
                const interface = (try r.string()) orelse return error.InvalidInterface;
                const version = try r.uint();
                const id = try r.uint();
                if (name == 0 or name > globals.len) return error.InvalidGlobal;
                const g = globals[name - 1];
                if (!std.mem.eql(u8, interface, g.name) or version == 0 or version > g.version) return error.InvalidGlobal;
                try s.bind(c, name, id);
            },
            .callback => return error.InvalidOpcode,
            .compositor => switch (m.opcode) {
                p.wl_compositor.request.create_surface => {
                    const id = try r.uint();
                    const surf = try s.gpa.create(Surface);
                    surf.* = .{ .client = c, .id = id };
                    c.addObject(id, .{ .surface = surf }) catch |e| {
                        s.gpa.destroy(surf);
                        return e;
                    };
                },
                p.wl_compositor.request.create_region => try c.addObject(try r.uint(), .region),
                else => return error.InvalidOpcode,
            },
            .region => if (m.opcode == p.wl_region.request.destroy) c.deleteId(m.object),
            .surface => |surf| try s.surfaceRequest(c, surf, m, r),
            .shm => {
                if (m.opcode != p.wl_shm.request.create_pool) return error.InvalidOpcode;
                const id = try r.uint();
                const fd = try r.fd();
                const size = try r.int();
                if (size <= 0) {
                    _ = linux.close(fd);
                    return c.postError(m.object, p.wl_shm.err.invalid_fd, "invalid pool size", .{});
                }
                const pool = try s.gpa.create(ShmPool);
                pool.* = .{ .fd = fd, .map = mapPool(fd, @intCast(size)) orelse {
                    _ = linux.close(fd);
                    s.gpa.destroy(pool);
                    return c.postError(m.object, p.wl_shm.err.invalid_fd, "cannot map the pool", .{});
                } };
                c.addObject(id, .{ .shm_pool = pool }) catch |e| {
                    pool.unref(s.gpa);
                    return e;
                };
            },
            .shm_pool => |pool| switch (m.opcode) {
                p.wl_shm_pool.request.create_buffer => {
                    const id = try r.uint();
                    const offset = try r.int();
                    const width = try r.int();
                    const height = try r.int();
                    const stride = try r.int();
                    const format = try r.uint();
                    if (format != p.wl_shm.format.argb8888 and format != p.wl_shm.format.xrgb8888)
                        return c.postError(m.object, p.wl_shm.err.invalid_format, "unsupported format {d}", .{format});
                    if (offset < 0 or width <= 0 or height <= 0 or width > 2048 or height > 2048 or stride < width * 4 or
                        @as(u64, @intCast(offset)) + @as(u64, @intCast(stride)) * @as(u64, @intCast(height)) > pool.map.len)
                        return c.postError(m.object, p.wl_shm.err.invalid_stride, "buffer outside the pool", .{});
                    const b = try s.gpa.create(Buffer);
                    b.* = .{ .client = c, .id = id, .width = @intCast(width), .height = @intCast(height), .shm = .{ .pool = pool, .offset = @intCast(offset), .stride = @intCast(stride) } };
                    pool.refs += 1;
                    c.addObject(id, .{ .buffer = b }) catch |e| {
                        s.freeBuffer(b);
                        return e;
                    };
                },
                p.wl_shm_pool.request.destroy => {
                    pool.unref(s.gpa);
                    c.deleteId(m.object);
                },
                p.wl_shm_pool.request.resize => {
                    const size = try r.int();
                    if (size < pool.map.len) return c.postError(m.object, p.wl_shm.err.invalid_fd, "pools cannot shrink", .{});
                    const map = mapPool(pool.fd, @intCast(size)) orelse return c.postError(m.object, p.wl_shm.err.invalid_fd, "cannot map the pool", .{});
                    _ = linux.munmap(pool.map.ptr, pool.map.len);
                    pool.map = map;
                },
                else => return error.InvalidOpcode,
            },
            .buffer => |b| {
                if (m.opcode != p.wl_buffer.request.destroy) return error.InvalidOpcode;
                c.deleteId(m.object);
                b.destroyed = true;
                // Forget it where it is attached but not yet committed.
                var it = c.objects.valueIterator();
                while (it.next()) |o| switch (o.*) {
                    .surface => |surf| if (surf.pending_buffer == b) {
                        surf.pending_buffer = null;
                    },
                    else => {},
                };
                if (b.uses == 0) s.freeBuffer(b);
            },
            .wm_base => switch (m.opcode) {
                p.xdg_wm_base.request.destroy => c.deleteId(m.object),
                p.xdg_wm_base.request.create_positioner => try c.addObject(try r.uint(), .positioner),
                p.xdg_wm_base.request.get_xdg_surface => {
                    const id = try r.uint();
                    const surf = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (surf.xdg != null) return c.postError(m.object, p.xdg_wm_base.err.role, "surface already has a role", .{});
                    const x = try s.gpa.create(XdgSurface);
                    x.* = .{ .surface = surf, .id = id };
                    c.addObject(id, .{ .xdg_surface = x }) catch |e| {
                        s.gpa.destroy(x);
                        return e;
                    };
                    surf.xdg = x;
                },
                p.xdg_wm_base.request.pong => {},
                else => return error.InvalidOpcode,
            },
            .positioner => if (m.opcode == 0) c.deleteId(m.object),
            .xdg_surface => |x| switch (m.opcode) {
                p.xdg_surface.request.destroy => {
                    if (x.toplevel != null) return c.postError(m.object, p.xdg_wm_base.err.defunct_surfaces, "destroy the toplevel first", .{});
                    if (x.surface) |surf| surf.xdg = null;
                    c.deleteId(m.object);
                    s.gpa.destroy(x);
                },
                p.xdg_surface.request.get_toplevel => {
                    const id = try r.uint();
                    if (x.toplevel != null) return c.postError(m.object, p.xdg_surface.err.already_constructed, "already has a role", .{});
                    const t = try s.gpa.create(Toplevel);
                    t.* = .{ .xdg = x, .id = id };
                    c.addObject(id, .{ .toplevel = t }) catch |e| {
                        s.gpa.destroy(t);
                        return e;
                    };
                    x.toplevel = t;
                },
                p.xdg_surface.request.get_popup => return c.postError(m.object, p.xdg_wm_base.err.invalid_popup_parent, "popups are not supported", .{}),
                p.xdg_surface.request.set_window_geometry, p.xdg_surface.request.ack_configure => {},
                else => return error.InvalidOpcode,
            },
            .toplevel => |t| switch (m.opcode) {
                p.xdg_toplevel.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyToplevel(t);
                },
                p.xdg_toplevel.request.set_title => {
                    const title = (try r.string()) orelse "";
                    t.title_len = @min(title.len, t.title_buf.len);
                    @memcpy(t.title_buf[0..t.title_len], title[0..t.title_len]);
                    s.damaged = true;
                },
                // Everything is maximized; the other requests do not apply.
                else => {},
            },
            .dmabuf => switch (m.opcode) {
                p.zwp_linux_dmabuf_v1.request.destroy => c.deleteId(m.object),
                p.zwp_linux_dmabuf_v1.request.create_params => {
                    const id = try r.uint();
                    const pr = try s.gpa.create(Params);
                    pr.* = .{};
                    c.addObject(id, .{ .params = pr }) catch |e| {
                        s.gpa.destroy(pr);
                        return e;
                    };
                },
                else => return error.InvalidOpcode,
            },
            .params => |pr| try s.paramsRequest(c, pr, m, r),
        }
    }

    fn bind(s: *Server, c: *Client, name: u32, id: u32) !void {
        switch (name) {
            1 => try c.addObject(id, .compositor),
            2 => {
                try c.addObject(id, .shm);
                for ([_]u32{ p.wl_shm.format.argb8888, p.wl_shm.format.xrgb8888 }) |f| if (c.send(id, p.wl_shm.event.format)) |m0| {
                    var e = m0;
                    e.uint(f).end();
                };
            },
            3 => try c.addObject(id, .wm_base),
            4 => {
                try c.addObject(id, .dmabuf);
                const mod = p.modifier.broadcom_vc4_t_tiled;
                for ([_]u32{ p.fourcc.xrgb8888, p.fourcc.argb8888 }) |f| {
                    if (c.send(id, p.zwp_linux_dmabuf_v1.event.format)) |m0| {
                        var e = m0;
                        e.uint(f).end();
                    }
                    if (c.send(id, p.zwp_linux_dmabuf_v1.event.modifier)) |m0| {
                        var e = m0;
                        e.uint(f).uint(@truncate(mod >> 32)).uint(@truncate(mod)).end();
                    }
                }
            },
            else => unreachable,
        }
        _ = s;
    }

    fn surfaceRequest(s: *Server, c: *Client, surf: *Surface, m: wire.Message, r: *wire.Reader) !void {
        switch (m.opcode) {
            p.wl_surface.request.destroy => {
                c.deleteId(m.object);
                s.destroySurface(surf);
            },
            p.wl_surface.request.attach => {
                const id = try r.uint();
                surf.pending_attach = true;
                surf.pending_buffer = if (id == 0) null else switch (c.objects.get(id) orelse return error.InvalidObject) {
                    .buffer => |b| b,
                    else => return error.InvalidObject,
                };
            },
            p.wl_surface.request.frame => {
                const id = try r.uint();
                try c.addObject(id, .callback);
                try surf.pending_callbacks.append(s.gpa, id);
            },
            p.wl_surface.request.commit => try s.commit(c, surf),
            p.wl_surface.request.set_buffer_scale => if (try r.int() != 1)
                return c.postError(m.object, p.wl_surface.err.invalid_scale, "only scale 1 is supported", .{}),
            p.wl_surface.request.set_buffer_transform => if (try r.int() != 0)
                return c.postError(m.object, p.wl_surface.err.invalid_transform, "transforms are not supported", .{}),
            // Damage and regions: the whole screen is redrawn anyway.
            p.wl_surface.request.damage, p.wl_surface.request.damage_buffer, p.wl_surface.request.set_opaque_region, p.wl_surface.request.set_input_region => {},
            else => return error.InvalidOpcode,
        }
    }

    fn commit(s: *Server, c: *Client, surf: *Surface) !void {
        if (surf.pending_attach) {
            surf.pending_attach = false;
            const b = surf.pending_buffer;
            surf.pending_buffer = null;
            if (b) |nb| {
                if (nb.shm) |shm| {
                    // Copy the pixels now, so the buffer can be released.
                    const pixels = shm.pool.map[shm.offset..][0 .. shm.stride * nb.height];
                    const t = try s.backend.vtable.uploadPixels(s.backend.ptr, surf.copy, pixels, nb.width, nb.height, shm.stride);
                    if (surf.copy) |old| if (old.handle != t.handle) s.backend.vtable.destroyTexture(s.backend.ptr, old);
                    surf.copy = t;
                    s.setBuffer(surf, null);
                    sendRelease(nb);
                } else {
                    if (surf.copy) |old| s.backend.vtable.destroyTexture(s.backend.ptr, old);
                    surf.copy = null;
                    s.setBuffer(surf, nb);
                }
            } else {
                s.setBuffer(surf, null);
                if (surf.copy) |old| s.backend.vtable.destroyTexture(s.backend.ptr, old);
                surf.copy = null;
            }
        }
        for (surf.pending_callbacks.items) |id| try s.frame_callbacks.append(s.gpa, .{ .client = c, .id = id });
        surf.pending_callbacks.clearRetainingCapacity();

        if (surf.xdg) |x| if (x.toplevel) |t| {
            if (!x.configured) {
                // The initial commit: tell the client its size.
                if (surf.texture() != null) return c.postError(x.id, p.xdg_surface.err.unconfigured_buffer, "buffer before the first configure", .{});
                s.configure(c, t);
                x.configured = true;
            } else if (surf.texture() != null and !t.mapped) {
                t.mapped = true;
                try s.toplevels.append(s.gpa, t);
            } else if (surf.texture() == null and t.mapped) {
                s.unmap(t);
            }
        };
        s.damaged = true;
    }

    fn configure(s: *Server, c: *Client, t: *Toplevel) void {
        if (c.send(t.id, p.xdg_toplevel.event.configure)) |m0| {
            var e = m0;
            var states: [8]u8 = undefined;
            std.mem.writeInt(u32, states[0..4], p.xdg_toplevel.state.maximized, .little);
            std.mem.writeInt(u32, states[4..8], p.xdg_toplevel.state.activated, .little);
            e.int(@intCast(s.work_area.width)).int(@intCast(s.work_area.height)).array(&states).end();
        }
        if (c.send(t.xdg.id, p.xdg_surface.event.configure)) |m0| {
            var e = m0;
            e.uint(s.nextSerial()).end();
        }
    }

    fn paramsRequest(s: *Server, c: *Client, pr: *Params, m: wire.Message, r: *wire.Reader) !void {
        const E = p.zwp_linux_buffer_params_v1.err;
        switch (m.opcode) {
            p.zwp_linux_buffer_params_v1.request.destroy => {
                c.deleteId(m.object);
                if (pr.fd) |fd| _ = linux.close(fd);
                s.gpa.destroy(pr);
            },
            p.zwp_linux_buffer_params_v1.request.add => {
                const fd = try r.fd();
                const plane = try r.uint();
                _ = try r.uint(); // offset
                _ = try r.uint(); // stride (meaningless for T tiling)
                const hi = try r.uint();
                const lo = try r.uint();
                if (plane != 0) {
                    _ = linux.close(fd);
                    return c.postError(m.object, E.plane_idx, "only one plane is supported", .{});
                }
                if (pr.fd != null) {
                    _ = linux.close(fd);
                    return c.postError(m.object, E.plane_set, "plane 0 already set", .{});
                }
                pr.fd = fd;
                pr.modifier = @as(u64, hi) << 32 | lo;
            },
            p.zwp_linux_buffer_params_v1.request.create, p.zwp_linux_buffer_params_v1.request.create_immed => {
                const immediate = m.opcode == p.zwp_linux_buffer_params_v1.request.create_immed;
                const id = if (immediate) try r.uint() else 0;
                const width = try r.int();
                const height = try r.int();
                const format = try r.uint();
                _ = try r.uint(); // flags
                if (pr.used) return c.postError(m.object, E.already_used, "params already used", .{});
                pr.used = true;
                const fd = pr.fd orelse return c.postError(m.object, E.incomplete, "no planes", .{});
                pr.fd = null;
                if (format != p.fourcc.xrgb8888 and format != p.fourcc.argb8888 or pr.modifier != p.modifier.broadcom_vc4_t_tiled) {
                    _ = linux.close(fd);
                    return c.postError(m.object, E.invalid_format, "only T-tiled XRGB8888 and ARGB8888 are supported", .{});
                }
                if (width <= 0 or height <= 0 or width > 2048 or height > 2048) {
                    _ = linux.close(fd);
                    return c.postError(m.object, E.invalid_dimensions, "invalid size {d}x{d}", .{ width, height });
                }
                const t = s.backend.vtable.importDmabuf(s.backend.ptr, fd, @intCast(width), @intCast(height)) catch |err| {
                    log.warn("dmabuf import failed: {s}", .{@errorName(err)});
                    if (immediate) return c.postError(m.object, E.invalid_wl_buffer, "import failed", .{});
                    if (c.send(m.object, p.zwp_linux_buffer_params_v1.event.failed)) |m0| {
                        var e = m0;
                        e.end();
                    }
                    return;
                };
                const b = try s.gpa.create(Buffer);
                b.* = .{ .client = c, .id = 0, .width = @intCast(width), .height = @intCast(height), .dmabuf = t };
                // A server-created ID for `create`, or the client's.
                b.id = if (immediate) id else s.serverId(c);
                c.addObject(b.id, .{ .buffer = b }) catch |e| {
                    s.freeBuffer(b);
                    return e;
                };
                if (!immediate) if (c.send(m.object, p.zwp_linux_buffer_params_v1.event.created)) |m0| {
                    var e = m0;
                    e.uint(b.id).end();
                };
            },
            else => return error.InvalidOpcode,
        }
    }

    fn serverId(s: *Server, c: *Client) u32 {
        _ = s;
        var id: u32 = 0xff000000;
        while (c.objects.contains(id)) id += 1;
        return id;
    }
};

fn mapPool(fd: linux.fd_t, size: usize) ?[]align(std.heap.page_size_min) u8 {
    const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
    return ptr[0..size];
}
