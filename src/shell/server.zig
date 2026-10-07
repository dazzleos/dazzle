//! The shell's Wayland server: clients, their objects, and the protocol.
//!
//! Supported globals: wl_compositor (surfaces; regions are accepted and
//! ignored), wl_subcompositor (subsurfaces, drawn above their parent),
//! wl_shm (ARGB8888 and XRGB8888, copied to the GPU at commit),
//! zwp_linux_dmabuf_v1 (buffers in the VideoCore IV's T-tiled layout, used
//! by the GPU directly), xdg_wm_base (toplevel windows, and popups above
//! them: see `Popup`), wl_output (the screen), wl_seat (a pointer, and a
//! keyboard with a US XKB keymap: see keyboard.zig), wp_cursor_shape_manager_v1
//! (the pointer's picture, by name) and wl_data_device_manager (copy and
//! paste: see `setSelection`; drag and drop is not supported yet).
//!
//! Windows go in the work area above the shell's dock: maximized (filling
//! it, as they start), or restored (at first to half its width and height),
//! where the client can move them with xdg_toplevel.move (dragging its
//! title bar) and resize with xdg_toplevel.resize (dragging an edge), no
//! smaller than the size it asks for with xdg_toplevel.set_min_size, nor
//! bigger than the work area. While a window is resized, it is told a new
//! size only once it has drawn at the last one, so a slow client is not
//! sent sizes it cannot keep up with. Clients choose the pointer's picture
//! over their windows with wp_cursor_shape_v1 (an arrow, or a resize).
//! They are stacked most recently mapped (or raised, or clicked) on top,
//! and the top one has the keyboard. Windows hidden behind others are
//! covered: they get xdg_toplevel's suspended state, their frame callbacks
//! wait until they can be seen again, and what they commit meanwhile does
//! not make the shell draw a frame. The server does not draw: it keeps the
//! state the renderer needs (`visibleWindows`), and gets textures from the
//! renderer through `Backend`, so it can run without a GPU in tests.
//!
//! Frame pacing: frame callbacks committed with a surface fire after the
//! next frame that shows it has been presented. Because the renderer waits
//! for each composited frame to finish, a client buffer is released as soon
//! as a newer one is committed.
//!
//! Input: the shell reports pointer and key events (`pointerMotion`,
//! `keyboardKey`, ...); the keyboard goes to the top window, the pointer to
//! the window under it, except while it moves a window.

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");
const wire = wayland.wire;
const p = wayland.protocol;

const keyboard = @import("keyboard.zig");
const placement = @import("placement.zig");

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
    .{ .name = p.wl_seat.name, .version = p.wl_seat.version },
    .{ .name = p.wp_cursor_shape_manager_v1.name, .version = p.wp_cursor_shape_manager_v1.version },
    .{ .name = p.wl_data_device_manager.name, .version = p.wl_data_device_manager.version },
    .{ .name = p.wl_subcompositor.name, .version = p.wl_subcompositor.version },
    .{ .name = p.wl_output.name, .version = p.wl_output.version },
};

/// The screen, as wl_output describes it.
pub const Output = struct {
    width: u32 = 1920,
    height: u32 = 1080,
    /// The refresh rate, in thousandths of a hertz.
    refresh_mhz: i32 = 60000,
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
    /// With the version the client bound.
    wm_base: u32,
    positioner: *Positioner,
    popup: *Popup,
    subcompositor,
    subsurface: *Subsurface,
    output: u32,
    xdg_surface: *XdgSurface,
    toplevel: *Toplevel,
    dmabuf,
    params: *Params,
    /// The seat, pointer and keyboard, with the version the client bound.
    seat: u32,
    pointer: u32,
    keyboard: u32,
    touch: u32,
    cursor_shape_manager,
    cursor_shape_device,
    data_device_manager,
    data_source: *DataSource,
    data_device,
    data_offer: *DataOffer,
};

/// What a client offers to paste, as MIME types. The clipboard (the
/// selection) holds one at a time.
pub const DataSource = struct {
    client: *Client,
    id: u32,
    mime_types: std.ArrayList([]u8) = .empty,
};

/// What the clipboard holds, as offered to a client: what it can ask for
/// (`receive`). Null once the source has gone.
pub const DataOffer = struct {
    source: ?*DataSource,
};

pub const Surface = struct {
    client: *Client,
    id: u32,
    pending_buffer: ?*Buffer = null,
    pending_attach: bool = false,
    pending_callbacks: std.ArrayList(u32) = .empty,
    /// Frame callbacks committed while the window was covered.
    held_callbacks: std.ArrayList(u32) = .empty,
    /// The dmabuf buffer being shown, if any.
    buffer: ?*Buffer = null,
    /// A copy of the last shm buffer, owned by the surface.
    copy: ?Texture = null,
    xdg: ?*XdgSurface = null,
    /// Its place in its parent, if it is a subsurface.
    sub: ?*Subsurface = null,
    /// Its subsurfaces, bottom first, drawn above it.
    subsurfaces: std.ArrayList(*Subsurface) = .empty,
    /// Told it is on the output (wl_surface.enter).
    entered: bool = false,

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
    /// Surfaces showing it, and the display while it scans it out (dmabuf
    /// buffers only). It is released to the client when this drops to 0.
    uses: u32 = 0,
    destroyed: bool = false,
};

/// A surface in another (wl_subsurface): drawn above it, at a place
/// relative to it, and taking the pointer there.
pub const Subsurface = struct {
    id: u32,
    /// Null once the wl_surface or its parent has been destroyed.
    surface: ?*Surface,
    parent: ?*Surface,
    x: i32 = 0,
    y: i32 = 0,
    /// A new place, taking effect when the parent is next committed.
    pending: ?[2]i32 = null,
};

/// Where a popup goes (xdg_positioner): see placement.zig.
pub const Positioner = placement.Positioner;

/// A menu, tooltip or the like (xdg_popup): a surface above its parent's
/// window, placed by a positioner. A popup that grabs (menus do) takes
/// the keyboard, and is dismissed (popup_done) when a surface of another
/// client is clicked.
pub const Popup = struct {
    xdg: *XdgSurface,
    id: u32,
    /// Null once the parent is gone (and the popup dismissed).
    parent: ?*XdgSurface,
    /// Its place relative to the parent's surface, and size.
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Where it was asked to go (to place it again when its parent moves,
    /// if it is reactive).
    positioner: Positioner = .{},
    mapped: bool = false,
    grab: bool = false,
    /// popup_done was sent: it is not shown again.
    done: bool = false,
};

pub const XdgSurface = struct {
    /// Null once the wl_surface has been destroyed.
    surface: ?*Surface,
    id: u32,
    toplevel: ?*Toplevel = null,
    popup: ?*Popup = null,
    configured: bool = false,
    /// The xdg_wm_base version it was made with.
    version: u32 = 1,
};

pub const Toplevel = struct {
    xdg: *XdgSurface,
    id: u32,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    mapped: bool = false,
    /// Covered by other windows, and told so (see `Server.updateCovered`).
    suspended: bool = false,
    /// Told it has the keyboard (it is the top window).
    activated: bool = true,
    capabilities_sent: bool = false,
    /// Filling the work area; otherwise restored, at `x`, `y` on the screen.
    maximized: bool = true,
    x: i32 = 0,
    y: i32 = 0,
    /// Restored before, so `x`, `y` and its size are where and how big it
    /// was.
    placed: bool = false,
    /// Its size when restored.
    width: u32 = 0,
    height: u32 = 0,
    /// The smallest and biggest it may be (xdg_toplevel.set_min_size and
    /// set_max_size; 0 for any).
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    /// While its left or top edge is dragged, and until it has drawn at
    /// the size it was told, its right or bottom edge stays put: its
    /// corner follows from these and the size of what it shows.
    anchor_right: ?i32 = null,
    anchor_bottom: ?i32 = null,
    /// The last configure: its serial, and whether the client has drawn
    /// since acknowledging it (or need not, its size being unchanged).
    configure_serial: u32 = 0,
    acked: bool = true,
    drawn: bool = true,
    /// Its size changed while it was drawing: it is told once it has.
    resend: bool = false,

    /// Mapped, with something to show.
    fn shown(t: *const Toplevel) bool {
        return t.mapped and t.xdg.surface != null and t.xdg.surface.?.texture() != null;
    }

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
    /// IDs for objects the server makes (data offers).
    next_server_id: u32 = 0xff000000,

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

const FrameCallback = struct { client: *Client, id: u32 };

/// The process at the other end of a Unix socket.
fn peerPid(fd: linux.fd_t) ?linux.pid_t {
    const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len)) != .SUCCESS) return null;
    return if (cred.pid > 0) cred.pid else null;
}

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
    /// Frame callbacks for the next frame drawn.
    frame_callbacks: std.ArrayList(FrameCallback) = .empty,
    /// Frame callbacks for the frame drawn and waiting to reach the screen.
    presenting: std.ArrayList(FrameCallback) = .empty,
    /// Where the pointer is on the screen.
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    /// The surfaces with pointer and keyboard focus.
    pointer_focus: ?*Surface = null,
    keyboard_focus: ?*Surface = null,
    /// The serial of the last button press, and how many buttons are down.
    press_serial: u32 = 0,
    buttons_down: u32 = 0,
    /// The window the pointer is moving (with the pointer's offset from
    /// its corner) or resizing. The pointer focuses on no surface
    /// meanwhile.
    grab: ?Grab = null,
    /// The pointer's picture the client under it chose (an arrow until it
    /// does).
    client_cursor: Cursor = .arrow,
    /// The touches down, and the serial of the last to go down (for a
    /// client to move or resize its window with it).
    touches: [10]?TouchPoint = @splat(null),
    touch_serial: u32 = 0,
    touch_serial_id: i32 = -1,
    /// Clients sent touch events since the last touch frame.
    touch_frame_clients: [4]?*Client = @splat(null),
    /// What the clipboard holds (from the client that last copied), and
    /// the offers of it made to clients.
    selection: ?*DataSource = null,
    offers: std.ArrayList(*DataOffer) = .empty,
    /// The screen.
    output: Output = .{},
    /// The popups shown, bottom first.
    popups: std.ArrayList(*Popup) = .empty,
    /// The keyboard's modifiers.
    modifiers: keyboard.Modifiers = .{},

    /// A move or resize: by the pointer, or by a touch (`touch`: its ID).
    const Grab = struct { t: *Toplevel, dx: f64, dy: f64, resize: ?Resize = null, touch: ?i32 = null };

    /// A touch on a surface: its events go to the surface it went down on
    /// (null once that has gone, or the touch is the shell's, moving a
    /// window).
    pub const TouchPoint = struct { id: i32, surface: ?*Surface, x: f64, y: f64 };

    /// A resize: the edges dragged (xdg_toplevel.resize_edge's bits), and
    /// where the pointer and the window were when it started.
    const Resize = struct { edges: u32, x: f64, y: f64, rect: Rect };

    /// The edges of a window (xdg_toplevel.resize_edge's bits).
    pub const edge_top = 1;
    pub const edge_bottom = 2;
    pub const edge_left = 4;
    pub const edge_right = 8;

    /// The smallest a window may be made, whatever the client says.
    pub const min_size = 64;

    /// How much of a window a move leaves in the work area, so it can be
    /// moved back.
    const grip = 48;

    pub fn init(gpa: std.mem.Allocator, backend: Backend, work_area: Rect) Server {
        return .{ .gpa = gpa, .backend = backend, .work_area = work_area };
    }

    pub fn deinit(s: *Server) void {
        while (s.clients.items.len > 0) s.removeClient(s.clients.items[0]);
        s.clients.deinit(s.gpa);
        s.toplevels.deinit(s.gpa);
        s.frame_callbacks.deinit(s.gpa);
        s.presenting.deinit(s.gpa);
        s.offers.deinit(s.gpa);
        s.popups.deinit(s.gpa);
    }

    /// Adds a client connected on `fd`.
    pub fn addClient(s: *Server, fd: linux.fd_t) !*Client {
        const c = try s.gpa.create(Client);
        c.* = .{ .server = s, .conn = .init(fd), .pid = peerPid(fd) };
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
        // Nothing more is sent to it (nor made for it).
        c.dead = true;
        for (&s.touch_frame_clients) |*slot| if (slot.* == c) {
            slot.* = null;
        };
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
        inline for (.{ .popup, .toplevel, .subsurface, .xdg_surface, .surface }) |tag| {
            it = c.objects.iterator();
            while (it.next()) |e| if (e.value_ptr.* == tag) s.destroyObject(c, e.value_ptr.*);
        }
        it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .popup, .toplevel, .subsurface, .xdg_surface, .surface, .buffer => {},
            else => s.destroyObject(c, e.value_ptr.*),
        };
        it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            // One the display still shows outlives its client, until
            // `dropBuffer`.
            .buffer => |b| if (b.uses > 0) {
                b.destroyed = true;
            } else s.freeBuffer(b),
            else => {},
        };
        for ([_]*std.ArrayList(FrameCallback){ &s.frame_callbacks, &s.presenting }) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].client == c) _ = list.swapRemove(i) else i += 1;
            }
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
            .data_source => |src| s.destroySource(src),
            .data_offer => |offer| s.destroyOffer(offer),
            .positioner => |pos| s.gpa.destroy(pos),
            .popup => |pp| s.destroyPopup(pp),
            .subsurface => |sub| s.destroySubsurface(sub),
            else => {},
        }
    }

    fn destroySurface(s: *Server, surf: *Surface) void {
        // The client knows it destroyed the surface; no leave events.
        if (s.pointer_focus == surf) s.pointer_focus = null;
        if (s.keyboard_focus == surf) s.keyboard_focus = null;
        for (&s.touches) |*slot| if (slot.*) |*tp| if (tp.surface == surf) {
            tp.surface = null;
        };
        s.setBuffer(surf, null);
        if (surf.copy) |t| s.backend.vtable.destroyTexture(s.backend.ptr, t);
        // Frame callbacks of a destroyed surface never fire.
        for (surf.pending_callbacks.items) |id| _ = surf.client.objects.remove(id);
        for (surf.held_callbacks.items) |id| _ = surf.client.objects.remove(id);
        surf.pending_callbacks.deinit(s.gpa);
        surf.held_callbacks.deinit(s.gpa);
        if (surf.xdg) |x| {
            // The xdg_surface lives on, without a surface.
            if (x.toplevel) |t| s.unmap(t);
            if (x.popup) |pp| s.unmapPopup(pp);
            x.surface = null;
        }
        // Subsurfaces live on, without their surface or parent.
        if (surf.sub) |sub| {
            s.detachSubsurface(sub);
            sub.surface = null;
        }
        for (surf.subsurfaces.items) |child| child.parent = null;
        surf.subsurfaces.deinit(s.gpa);
        s.gpa.destroy(surf);
    }

    fn destroyToplevel(s: *Server, t: *Toplevel) void {
        s.unmap(t);
        t.xdg.toplevel = null;
        s.gpa.destroy(t);
    }

    fn unmap(s: *Server, t: *Toplevel) void {
        if (s.grab) |g| if (g.t == t) {
            s.grab = null;
        };
        // Its popups close.
        var n = s.popups.items.len;
        while (n > 0) {
            n -= 1;
            if (n >= s.popups.items.len) continue;
            const pp = s.popups.items[n];
            if (pp.xdg.surface) |ps| if (s.rootToplevel(ps) == t) s.dismissPopup(pp);
        }
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
        if (surf.buffer) |old| s.dropBuffer(old);
        surf.buffer = b;
        if (b) |nb| nb.uses += 1;
    }

    /// Keeps a buffer from being released or freed while the display shows
    /// it.
    pub fn holdBuffer(s: *Server, b: *Buffer) void {
        _ = s;
        b.uses += 1;
    }

    /// Ends a use of a buffer: when nothing uses it any more, it goes back
    /// to its client (or is freed, if the client destroyed it).
    pub fn dropBuffer(s: *Server, b: *Buffer) void {
        b.uses -= 1;
        if (b.uses > 0) return;
        if (b.destroyed) s.freeBuffer(b) else sendRelease(b);
    }

    /// Moves the work area (when the dock comes or goes): maximized windows
    /// are told the new size, and restored ones kept in it.
    pub fn setWorkArea(s: *Server, wa: Rect) void {
        s.work_area = wa;
        for (s.toplevels.items) |t| {
            const surf = t.xdg.surface orelse continue;
            if (!t.maximized and t.shown()) s.moveWindow(t, @floatFromInt(t.x), @floatFromInt(t.y));
            s.configure(surf.client, t);
        }
        s.damaged = true;
    }

    /// The dma-buf buffer a window shows, if it can go on the display as it
    /// is: maximized, and the size of the work area.
    pub fn scanoutBuffer(s: *const Server, t: *const Toplevel) ?*Buffer {
        if (!t.maximized) return null;
        const surf = t.xdg.surface orelse return null;
        // Subsurfaces and popups are drawn on it.
        if (surf.subsurfaces.items.len > 0) return null;
        for (s.popups.items) |pp| if (pp.xdg.surface) |ps| if (s.rootToplevel(ps) == t) return null;
        const b = surf.buffer orelse return null;
        if (b.dmabuf == null or b.width != s.work_area.width or b.height != s.work_area.height) return null;
        return b;
    }

    fn sendRelease(b: *Buffer) void {
        if (b.destroyed) return;
        if (b.client.send(b.id, p.wl_buffer.event.release)) |m0| {
            var m = m0;
            m.end();
        }
    }

    /// Raises the top window of the client with process `pid` above the
    /// others. Returns whether it has one.
    pub fn raise(s: *Server, pid: linux.pid_t) bool {
        var i = s.toplevels.items.len;
        while (i > 0) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (!t.mapped or t.xdg.surface == null or t.xdg.surface.?.client.pid != pid) continue;
            s.raiseToplevel(t);
            return true;
        }
        return false;
    }

    fn raiseToplevel(s: *Server, t: *Toplevel) void {
        const i = std.mem.indexOfScalar(*Toplevel, s.toplevels.items, t) orelse return;
        if (i + 1 == s.toplevels.items.len) return;
        _ = s.toplevels.orderedRemove(i);
        s.toplevels.appendAssumeCapacity(t);
        s.damaged = true;
    }

    /// The top window, which has the keyboard.
    pub fn topWindow(s: *const Server) ?*Toplevel {
        var i = s.toplevels.items.len;
        while (i > 0) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (t.shown()) return t;
        }
        return null;
    }

    /// The windows to draw, bottom first: those not covered (the top ones,
    /// if there are more than fit in `buf`).
    pub fn visibleWindows(s: *const Server, buf: []*Toplevel) []*Toplevel {
        var n: usize = 0;
        var i = s.toplevels.items.len;
        while (i > 0 and n < buf.len) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (!t.shown() or t.suspended) continue;
            n += 1;
            buf[buf.len - n] = t;
        }
        std.mem.copyForwards(*Toplevel, buf[0..n], buf[buf.len - n ..]);
        return buf[0..n];
    }

    /// Where a window is on the screen, at the size of what it shows.
    pub fn windowRect(s: *const Server, t: *const Toplevel) Rect {
        const tex = t.xdg.surface.?.texture().?;
        if (t.maximized) return .{ .x = s.work_area.x, .y = s.work_area.y, .width = tex.width, .height = tex.height };
        return .{
            .x = if (t.anchor_right) |r| r - @as(i32, @intCast(tex.width)) else t.x,
            .y = if (t.anchor_bottom) |b| b - @as(i32, @intCast(tex.height)) else t.y,
            .width = tex.width,
            .height = tex.height,
        };
    }

    /// The part of a window that can be seen: what is in the work area.
    fn visibleRect(s: *const Server, t: *const Toplevel) Rect {
        const r = s.windowRect(t);
        const wa = s.work_area;
        const x0 = @max(r.x, wa.x);
        const y0 = @max(r.y, wa.y);
        const x1 = @min(r.x + @as(i32, @intCast(r.width)), wa.x + @as(i32, @intCast(wa.width)));
        const y1 = @min(r.y + @as(i32, @intCast(r.height)), wa.y + @as(i32, @intCast(wa.height)));
        return .{ .x = x0, .y = y0, .width = @intCast(@max(x1 - x0, 0)), .height = @intCast(@max(y1 - y0, 0)) };
    }

    /// The size a window is told to be: the work area's, or its restored
    /// size (at first half the work area), no smaller than its minimum
    /// nor bigger than the work area.
    pub fn configuredSize(s: *const Server, t: *const Toplevel) [2]u32 {
        const wa = s.work_area;
        if (t.maximized) return .{ wa.width, wa.height };
        const w = if (t.width != 0) t.width else wa.width / 2;
        const h = if (t.height != 0) t.height else wa.height / 2;
        return .{ s.clampWidth(t, w, wa.width), s.clampHeight(t, h, wa.height) };
    }

    /// A width for `t` between its minimum and maximum, and no more than
    /// `max` (the minimum, if that is more than `max`, giving way).
    fn clampWidth(_: *const Server, t: *const Toplevel, w: u32, max: u32) u32 {
        const min = @max(t.min_width, min_size);
        const most = if (t.max_width != 0) @min(max, @max(t.max_width, min)) else max;
        return @max(@min(w, most), @min(min, max), 1);
    }

    fn clampHeight(_: *const Server, t: *const Toplevel, h: u32, max: u32) u32 {
        const min = @max(t.min_height, min_size);
        const most = if (t.max_height != 0) @min(max, @max(t.max_height, min)) else max;
        return @max(@min(h, most), @min(min, max), 1);
    }

    fn setMaximized(s: *Server, c: *Client, t: *Toplevel, on: bool) void {
        if (t.maximized == on) return;
        if (s.grab) |g| if (g.t == t) s.endGrab();
        t.maximized = on;
        if (!on and !t.placed) {
            // Restored the first time: half the work area (or its minimum
            // size), in the middle.
            const size = s.configuredSize(t);
            t.width = size[0];
            t.height = size[1];
            t.x = s.work_area.x + @divTrunc(@as(i32, @intCast(s.work_area.width)) - @as(i32, @intCast(size[0])), 2);
            t.y = s.work_area.y + @max(@divTrunc(@as(i32, @intCast(s.work_area.height)) - @as(i32, @intCast(size[1])), 2), 0);
            t.placed = true;
        }
        t.anchor_right = null;
        t.anchor_bottom = null;
        if (t.xdg.configured) s.configure(c, t);
        s.damaged = true;
        s.replacePopups(t);
    }

    /// The client says how small its window may be: a restored window
    /// smaller than that grows.
    fn setMinSize(s: *Server, c: *Client, t: *Toplevel, w: i32, h: i32) void {
        t.min_width = @intCast(@max(w, 0));
        t.min_height = @intCast(@max(h, 0));
        s.sizeLimitsChanged(c, t);
    }

    /// The client says how big its window may be: a restored window bigger
    /// than that shrinks.
    fn setMaxSize(s: *Server, c: *Client, t: *Toplevel, w: i32, h: i32) void {
        t.max_width = @intCast(@max(w, 0));
        t.max_height = @intCast(@max(h, 0));
        s.sizeLimitsChanged(c, t);
    }

    fn sizeLimitsChanged(s: *Server, c: *Client, t: *Toplevel) void {
        if (t.maximized or !t.placed) return;
        const size = s.configuredSize(t);
        if (size[0] == t.width and size[1] == t.height) return;
        t.width = size[0];
        t.height = size[1];
        if (t.xdg.configured) s.requestConfigure(c, t);
    }

    /// Moves a restored window, keeping `grip` of it in the work area (and
    /// its top, with its title bar, below the work area's).
    fn moveWindow(s: *Server, t: *Toplevel, x: f64, y: f64) void {
        const wa = s.work_area;
        const w: i32 = @intCast(s.windowRect(t).width);
        const left = wa.x + grip - w;
        const right = wa.x + @as(i32, @intCast(wa.width)) - grip;
        const bottom = wa.y + @as(i32, @intCast(wa.height)) - grip;
        const nx = std.math.clamp(@as(i32, @intFromFloat(@round(x))), @min(left, right), right);
        const ny = std.math.clamp(@as(i32, @intFromFloat(@round(y))), wa.y, @max(bottom, wa.y));
        if (nx == t.x and ny == t.y) return;
        t.x = nx;
        t.y = ny;
        s.damaged = true;
        s.replacePopups(t);
    }

    /// A client asked to move its window with the pointer, which must be
    /// holding a button pressed on it (`serial` being the press's).
    fn startMove(s: *Server, t: *Toplevel, serial: u32) void {
        const by = s.clientGrabAllowed(t, serial) orelse return;
        s.settle(t, true);
        s.grab = .{ .t = t, .dx = by.x - @as(f64, @floatFromInt(t.x)), .dy = by.y - @as(f64, @floatFromInt(t.y)), .touch = by.touch };
        s.takeInput(by.touch);
    }

    /// A client asked to resize its window by `edges` with the pointer, as
    /// for `startMove`.
    fn clientResize(s: *Server, t: *Toplevel, serial: u32, edges: u32) void {
        const by = s.clientGrabAllowed(t, serial) orelse return;
        const valid = edges != 0 and edges & (edge_top | edge_bottom) != edge_top | edge_bottom and edges & (edge_left | edge_right) != edge_left | edge_right;
        if (!valid or edges > 15) return;
        s.startResize(t, edges, by);
    }

    /// What drives a move or resize: the pointer, or a touch.
    const GrabBy = struct { x: f64, y: f64, touch: ?i32 = null };

    /// Whether a client may move or resize its window from the input with
    /// `serial`: a button press it is still holding on the window, or a
    /// touch still down on it; and from where.
    fn clientGrabAllowed(s: *const Server, t: *const Toplevel, serial: u32) ?GrabBy {
        if (t.maximized or !t.shown() or s.grab != null) return null;
        const surf = t.xdg.surface orelse return null;
        if (s.buttons_down > 0 and serial == s.press_serial and s.pointer_focus == surf) return .{ .x = s.pointer_x, .y = s.pointer_y };
        if (serial == s.touch_serial) if (s.touchPoint(s.touch_serial_id)) |tp| if (tp.surface == surf) return .{ .x = tp.x, .y = tp.y, .touch = tp.id };
        return null;
    }

    /// Resizes `t` by its `edges` as the pointer (or touch) moves, until
    /// the buttons are released (or the touch comes up).
    fn startResize(s: *Server, t: *Toplevel, edges: u32, by: GrabBy) void {
        s.settle(t, true);
        const size = s.configuredSize(t);
        s.grab = .{ .t = t, .dx = 0, .dy = 0, .touch = by.touch, .resize = .{
            .edges = edges,
            .x = by.x,
            .y = by.y,
            .rect = .{ .x = t.x, .y = t.y, .width = size[0], .height = size[1] },
        } };
        s.takeInput(by.touch);
    }

    /// The input driving a move or resize is the shell's until it ends:
    /// the pointer leaves the window it is over, or the touch's client is
    /// told its touches are cancelled.
    fn takeInput(s: *Server, touch: ?i32) void {
        const id = touch orelse return s.takePointer();
        const tp = s.touchPoint(id) orelse return;
        const surf = tp.surface orelse return;
        broadcast(surf.client, .touch, p.wl_touch.event.cancel, 1, .{});
        // None of the client's touches go to it any more.
        for (&s.touches) |*slot| if (slot.*) |*other| if (other.surface) |os| if (os.client == surf.client) {
            other.surface = null;
        };
    }

    /// The pointer is the shell's (for a move or resize) until the buttons
    /// are released: it leaves the window it is over.
    fn takePointer(s: *Server) void {
        const surf = s.pointer_focus orelse return;
        broadcast(surf.client, .pointer, p.wl_pointer.event.leave, 1, .{ s.nextSerial(), surf.id });
        broadcast(surf.client, .pointer, p.wl_pointer.event.frame, 5, .{});
        s.pointer_focus = null;
    }

    /// The pointer moved to (`x`, `y`) while resizing.
    fn resizeTo(s: *Server, t: *Toplevel, r: Resize, x: f64, y: f64) void {
        const wa = s.work_area;
        const dx: i32 = @intFromFloat(@round(x - r.x));
        const dy: i32 = @intFromFloat(@round(y - r.y));
        const w0: i32 = @intCast(r.rect.width);
        const h0: i32 = @intCast(r.rect.height);
        var w = t.width;
        var h = t.height;
        if (r.edges & edge_right != 0) w = s.clampWidth(t, @intCast(@max(w0 + dx, 1)), wa.width);
        if (r.edges & edge_left != 0) {
            w = s.clampWidth(t, @intCast(@max(w0 - dx, 1)), wa.width);
            t.anchor_right = r.rect.x + w0;
        }
        if (r.edges & edge_bottom != 0) h = s.clampHeight(t, @intCast(@max(h0 + dy, 1)), wa.height);
        if (r.edges & edge_top != 0) {
            // Its top stays below the work area's.
            const bottom = r.rect.y + h0;
            h = s.clampHeight(t, @intCast(@max(h0 - dy, 1)), @intCast(@max(bottom - wa.y, 1)));
            t.anchor_bottom = bottom;
        }
        if (w == t.width and h == t.height) return;
        t.width = w;
        t.height = h;
        const surf = t.xdg.surface orelse return;
        s.requestConfigure(surf.client, t);
    }

    /// Fixes a restored window's corner where it is, once it has drawn at
    /// the size it was told (or now, if `force`), and no longer keeps an
    /// edge where it was.
    fn settle(s: *Server, t: *Toplevel, force: bool) void {
        if (t.anchor_right == null and t.anchor_bottom == null) return;
        if (!force and (!t.drawn or s.resizing(t))) return;
        if (t.shown()) {
            const r = s.windowRect(t);
            t.x = r.x;
            t.y = r.y;
        }
        t.anchor_right = null;
        t.anchor_bottom = null;
        s.damaged = true;
        s.replacePopups(t);
    }

    fn resizing(s: *const Server, t: *const Toplevel) bool {
        const g = s.grab orelse return false;
        return g.t == t and g.resize != null;
    }

    fn endGrab(s: *Server) void {
        const g = s.grab orelse return;
        s.grab = null;
        s.settle(g.t, false);
        if (s.updatePointerFocus()) s.pointerFrame();
    }

    /// The picture shown for a cursor-shape protocol shape: the resizes,
    /// and an arrow for the others (null if there is no such shape).
    fn cursorForShape(shape: u32) ?Cursor {
        const sh = p.wp_cursor_shape_device_v1.shape;
        return switch (shape) {
            sh.e_resize, sh.w_resize, sh.ew_resize => .resize_horizontal,
            sh.n_resize, sh.s_resize, sh.ns_resize => .resize_vertical,
            sh.nw_resize, sh.se_resize, sh.nwse_resize => .resize_diagonal_down,
            sh.ne_resize, sh.sw_resize, sh.nesw_resize => .resize_diagonal_up,
            1...17, 30...34 => .arrow,
            else => null,
        };
    }

    /// The pointer's pictures.
    pub const Cursor = @import("cursor.zig").Shape;

    /// The pointer's picture: a resize while resizing; otherwise the one
    /// the client under it chose.
    pub fn cursor(s: *const Server) Cursor {
        const g = s.grab orelse return if (s.pointer_focus != null) s.client_cursor else .arrow;
        const edges = if (g.resize) |r| r.edges else 0;
        const v = edges & (edge_top | edge_bottom);
        const h = edges & (edge_left | edge_right);
        if (v != 0 and h != 0) return if ((v == edge_top) == (h == edge_left)) .resize_diagonal_down else .resize_diagonal_up;
        if (h != 0) return .resize_horizontal;
        if (v != 0) return .resize_vertical;
        return .arrow;
    }

    /// Call when a frame has been drawn from the current state: the frame
    /// callbacks committed so far belong to it, and later changes to the
    /// next one.
    pub fn frameDrawn(s: *Server) void {
        s.presenting.appendSlice(s.gpa, s.frame_callbacks.items) catch {
            // Without memory to hold them, fire them now.
            s.framePresented(0);
            s.presenting.appendSlice(s.gpa, s.frame_callbacks.items) catch {};
        };
        s.frame_callbacks.clearRetainingCapacity();
        s.damaged = false;
    }

    /// Fires the drawn frame's callbacks once it has reached the screen.
    pub fn framePresented(s: *Server, time_ms: u32) void {
        for (s.presenting.items) |fc| {
            if (fc.client.send(fc.id, p.wl_callback.event.done)) |m0| {
                var m = m0;
                m.uint(time_ms).end();
            }
            fc.client.deleteId(fc.id);
        }
        s.presenting.clearRetainingCapacity();
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
                try s.bind(c, name, id, version);
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
                    if (offset < 0 or width <= 0 or height <= 0 or width > 2048 or height > 2048 or stride < width * 4 or @mod(stride, 4) != 0 or
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
            .wm_base => |version| switch (m.opcode) {
                p.xdg_wm_base.request.destroy => c.deleteId(m.object),
                p.xdg_wm_base.request.create_positioner => {
                    const id = try r.uint();
                    const pos = try s.gpa.create(Positioner);
                    pos.* = .{};
                    c.addObject(id, .{ .positioner = pos }) catch |e| {
                        s.gpa.destroy(pos);
                        return e;
                    };
                },
                p.xdg_wm_base.request.get_xdg_surface => {
                    const id = try r.uint();
                    const surf = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (surf.xdg != null) return c.postError(m.object, p.xdg_wm_base.err.role, "surface already has a role", .{});
                    const x = try s.gpa.create(XdgSurface);
                    x.* = .{ .surface = surf, .id = id, .version = version };
                    c.addObject(id, .{ .xdg_surface = x }) catch |e| {
                        s.gpa.destroy(x);
                        return e;
                    };
                    surf.xdg = x;
                },
                p.xdg_wm_base.request.pong => {},
                else => return error.InvalidOpcode,
            },
            .positioner => |pos| try s.positionerRequest(c, pos, m, r),
            .popup => |pp| switch (m.opcode) {
                p.xdg_popup.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyPopup(pp);
                },
                p.xdg_popup.request.grab => {
                    _ = try r.uint(); // seat
                    _ = try r.uint(); // serial
                    pp.grab = true;
                    s.updateFocus();
                },
                p.xdg_popup.request.reposition => {
                    const pos = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .positioner => |x| x,
                        else => return error.InvalidObject,
                    };
                    const token = try r.uint();
                    s.placePopup(pp, pos.*);
                    sendTo(c, pp.id, p.xdg_popup.event.repositioned, .{token});
                    s.configurePopup(c, pp);
                },
                else => return error.InvalidOpcode,
            },
            .subcompositor => switch (m.opcode) {
                p.wl_subcompositor.request.destroy => c.deleteId(m.object),
                p.wl_subcompositor.request.get_subsurface => {
                    const id = try r.uint();
                    const surf = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    const parent = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (surf.xdg != null or surf.sub != null) return c.postError(m.object, p.wl_subcompositor.err.bad_surface, "surface already has a role", .{});
                    // Not itself, nor one of its own subsurfaces.
                    var at: ?*Surface = parent;
                    while (at) |a| : (at = if (a.sub) |sub| sub.parent else null) {
                        if (a == surf) return c.postError(m.object, p.wl_subcompositor.err.bad_parent, "a surface cannot be in itself", .{});
                    }
                    const sub = try s.gpa.create(Subsurface);
                    sub.* = .{ .id = id, .surface = surf, .parent = parent };
                    c.addObject(id, .{ .subsurface = sub }) catch |e| {
                        s.gpa.destroy(sub);
                        return e;
                    };
                    parent.subsurfaces.append(s.gpa, sub) catch {};
                    surf.sub = sub;
                },
                else => return error.InvalidOpcode,
            },
            .subsurface => |sub| switch (m.opcode) {
                p.wl_subsurface.request.destroy => {
                    c.deleteId(m.object);
                    s.destroySubsurface(sub);
                },
                p.wl_subsurface.request.set_position => {
                    const x = try r.int();
                    sub.pending = .{ x, try r.int() };
                },
                p.wl_subsurface.request.place_above, p.wl_subsurface.request.place_below => {
                    const sibling = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    s.restack(sub, sibling, m.opcode == p.wl_subsurface.request.place_above);
                },
                // Subsurfaces' state is applied when they are committed
                // (as if desynchronized, whichever they are).
                p.wl_subsurface.request.set_sync, p.wl_subsurface.request.set_desync => {},
                else => return error.InvalidOpcode,
            },
            .output => if (m.opcode == p.wl_output.request.release) c.deleteId(m.object),
            .xdg_surface => |x| switch (m.opcode) {
                p.xdg_surface.request.destroy => {
                    if (x.toplevel != null or x.popup != null) return c.postError(m.object, p.xdg_wm_base.err.defunct_surfaces, "destroy the toplevel or popup first", .{});
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
                p.xdg_surface.request.get_popup => {
                    const id = try r.uint();
                    const parent_id = try r.uint();
                    const pos = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .positioner => |ps| ps,
                        else => return error.InvalidObject,
                    };
                    if (x.toplevel != null or x.popup != null) return c.postError(m.object, p.xdg_surface.err.already_constructed, "already has a role", .{});
                    // Popups need a parent here: there is no other protocol
                    // to give them one.
                    const parent = if (parent_id == 0) null else switch (c.objects.get(parent_id) orelse return error.InvalidObject) {
                        .xdg_surface => |px| px,
                        else => return error.InvalidObject,
                    };
                    if (parent == null) return c.postError(m.object, p.xdg_wm_base.err.invalid_popup_parent, "popups need a parent", .{});
                    if (pos.width <= 0 or pos.height <= 0) return c.postError(m.object, p.xdg_wm_base.err.invalid_positioner, "the positioner has no size", .{});
                    const pp = try s.gpa.create(Popup);
                    pp.* = .{ .xdg = x, .id = id, .parent = parent };
                    c.addObject(id, .{ .popup = pp }) catch |e| {
                        s.gpa.destroy(pp);
                        return e;
                    };
                    x.popup = pp;
                    s.placePopup(pp, pos.*);
                },
                p.xdg_surface.request.ack_configure => {
                    const serial = try r.uint();
                    if (x.toplevel) |t| if (serial == t.configure_serial) s.acked(t);
                },
                p.xdg_surface.request.set_window_geometry => {},
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
                p.xdg_toplevel.request.set_maximized => s.setMaximized(c, t, true),
                p.xdg_toplevel.request.unset_maximized => s.setMaximized(c, t, false),
                p.xdg_toplevel.request.move => {
                    _ = try r.uint();
                    s.startMove(t, try r.uint());
                },
                p.xdg_toplevel.request.resize => {
                    _ = try r.uint();
                    const serial = try r.uint();
                    s.clientResize(t, serial, try r.uint());
                },
                p.xdg_toplevel.request.set_min_size => {
                    const w = try r.int();
                    s.setMinSize(c, t, w, try r.int());
                },
                p.xdg_toplevel.request.set_max_size => {
                    const w = try r.int();
                    s.setMaxSize(c, t, w, try r.int());
                },
                // Windows cannot be minimized or made fullscreen, and have
                // no menu.
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
            .seat => |version| try s.seatRequest(c, version, m, r),
            // The cursor is the shell's own.
            .pointer => if (m.opcode == p.wl_pointer.request.release) c.deleteId(m.object),
            .touch => if (m.opcode == p.wl_touch.request.release) c.deleteId(m.object),
            .keyboard => if (m.opcode == p.wl_keyboard.request.release) c.deleteId(m.object),
            .data_device_manager => switch (m.opcode) {
                p.wl_data_device_manager.request.create_data_source => {
                    const id = try r.uint();
                    const src = try s.gpa.create(DataSource);
                    src.* = .{ .client = c, .id = id };
                    c.addObject(id, .{ .data_source = src }) catch |e| {
                        s.gpa.destroy(src);
                        return e;
                    };
                },
                p.wl_data_device_manager.request.get_data_device => {
                    const id = try r.uint();
                    _ = try r.uint(); // the seat: there is one
                    try c.addObject(id, .data_device);
                    // A client with the keyboard learns what the clipboard
                    // holds.
                    if (s.keyboard_focus) |surf| if (surf.client == c) s.sendSelectionTo(c, id);
                },
                else => return error.InvalidOpcode,
            },
            .data_source => |src| switch (m.opcode) {
                p.wl_data_source.request.offer => {
                    const mime = (try r.string()) orelse return error.InvalidArgument;
                    if (src.mime_types.items.len >= max_mime_types) return;
                    const copy = try s.gpa.dupe(u8, mime);
                    src.mime_types.append(s.gpa, copy) catch |e| {
                        s.gpa.free(copy);
                        return e;
                    };
                },
                p.wl_data_source.request.destroy => {
                    c.deleteId(m.object);
                    s.destroySource(src);
                },
                // Actions are for drag and drop.
                p.wl_data_source.request.set_actions => {},
                else => return error.InvalidOpcode,
            },
            .data_device => switch (m.opcode) {
                // Drag and drop is not supported: nothing is dragged.
                p.wl_data_device.request.start_drag => {},
                p.wl_data_device.request.set_selection => {
                    const id = try r.uint();
                    _ = try r.uint(); // serial
                    const src: ?*DataSource = if (id == 0) null else switch (c.objects.get(id) orelse return error.InvalidObject) {
                        .data_source => |x| x,
                        else => return error.InvalidObject,
                    };
                    s.setSelection(c, src);
                },
                p.wl_data_device.request.release => c.deleteId(m.object),
                else => return error.InvalidOpcode,
            },
            .data_offer => |offer| switch (m.opcode) {
                p.wl_data_offer.request.receive => {
                    const mime = (try r.string()) orelse "";
                    s.receive(offer, mime, try r.fd());
                },
                p.wl_data_offer.request.destroy => {
                    // Made by the server: no delete_id.
                    _ = c.objects.remove(m.object);
                    s.destroyOffer(offer);
                },
                // Accepting, finishing and actions are for drag and drop.
                p.wl_data_offer.request.accept, p.wl_data_offer.request.finish, p.wl_data_offer.request.set_actions => {},
                else => return error.InvalidOpcode,
            },
            .cursor_shape_manager => switch (m.opcode) {
                p.wp_cursor_shape_manager_v1.request.destroy => c.deleteId(m.object),
                p.wp_cursor_shape_manager_v1.request.get_pointer => {
                    const id = try r.uint();
                    _ = try r.uint();
                    try c.addObject(id, .cursor_shape_device);
                },
                // There are no tablets.
                else => return error.InvalidOpcode,
            },
            .cursor_shape_device => switch (m.opcode) {
                p.wp_cursor_shape_device_v1.request.destroy => c.deleteId(m.object),
                p.wp_cursor_shape_device_v1.request.set_shape => {
                    _ = try r.uint();
                    const shape = try r.uint();
                    const picture = cursorForShape(shape) orelse return c.postError(m.object, p.wp_cursor_shape_device_v1.err.invalid_shape, "no cursor shape {d}", .{shape});
                    // Only over its own window.
                    if (s.pointer_focus) |surf| if (surf.client == c) {
                        s.client_cursor = picture;
                    };
                },
                else => return error.InvalidOpcode,
            },
        }
    }

    fn bind(s: *Server, c: *Client, name: u32, id: u32, version: u32) !void {
        switch (name) {
            1 => try c.addObject(id, .compositor),
            2 => {
                try c.addObject(id, .shm);
                for ([_]u32{ p.wl_shm.format.argb8888, p.wl_shm.format.xrgb8888 }) |f| if (c.send(id, p.wl_shm.event.format)) |m0| {
                    var e = m0;
                    e.uint(f).end();
                };
            },
            3 => try c.addObject(id, .{ .wm_base = version }),
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
            5 => {
                try c.addObject(id, .{ .seat = version });
                if (c.send(id, p.wl_seat.event.capabilities)) |m0| {
                    var e = m0;
                    e.uint(p.wl_seat.capability.pointer | p.wl_seat.capability.keyboard | p.wl_seat.capability.touch).end();
                }
                if (version >= 2) if (c.send(id, p.wl_seat.event.name)) |m0| {
                    var e = m0;
                    e.string("seat0").end();
                };
            },
            6 => try c.addObject(id, .cursor_shape_manager),
            7 => try c.addObject(id, .data_device_manager),
            8 => try c.addObject(id, .subcompositor),
            9 => {
                try c.addObject(id, .{ .output = version });
                s.describeOutput(c, id, version);
                // The client's surfaces already shown are on it.
                var it = c.objects.valueIterator();
                while (it.next()) |o| switch (o.*) {
                    .surface => |surf| if (surf.entered) sendTo(c, surf.id, p.wl_surface.event.enter, .{id}),
                    else => {},
                };
            },
            else => unreachable,
        }
    }

    /// Tells a client about the screen: where it is, its mode, its scale
    /// (always 1) and name.
    fn describeOutput(s: *Server, c: *Client, id: u32, version: u32) void {
        const o = s.output;
        if (c.send(id, p.wl_output.event.geometry)) |m0| {
            var e = m0;
            // At 0,0; its physical size is not known.
            e.int(0).int(0).int(0).int(0).int(p.wl_output.subpixel.unknown).string("Unknown").string("Unknown").int(p.wl_output.transform.normal).end();
        }
        sendTo(c, id, p.wl_output.event.mode, .{ @as(u32, p.wl_output.mode_flags.current | p.wl_output.mode_flags.preferred), @as(i32, @intCast(o.width)), @as(i32, @intCast(o.height)), o.refresh_mhz });
        if (version >= 2) sendTo(c, id, p.wl_output.event.scale, .{@as(i32, 1)});
        if (version >= 4) {
            if (c.send(id, p.wl_output.event.name)) |m0| {
                var e = m0;
                e.string("HDMI-A-1").end();
            }
            if (c.send(id, p.wl_output.event.description)) |m0| {
                var e = m0;
                e.string("The screen").end();
            }
        }
        if (version >= 2) sendTo(c, id, p.wl_output.event.done, .{});
    }

    /// Tells a client a surface is on the screen (each of its wl_outputs).
    fn sendEnter(_: *Server, c: *Client, surf: *Surface) void {
        var it = c.objects.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .output) sendTo(c, surf.id, p.wl_surface.event.enter, .{e.key_ptr.*});
    }

    fn seatRequest(s: *Server, c: *Client, version: u32, m: wire.Message, r: *wire.Reader) !void {
        switch (m.opcode) {
            p.wl_seat.request.get_pointer => {
                const id = try r.uint();
                try c.addObject(id, .{ .pointer = version });
                // Already over one of the client's surfaces.
                if (s.pointer_focus) |surf| if (surf.client == c) {
                    const local = s.surfaceLocal();
                    sendTo(c, id, p.wl_pointer.event.enter, .{ s.nextSerial(), surf.id, local[0], local[1] });
                    if (version >= 5) sendTo(c, id, p.wl_pointer.event.frame, .{});
                };
            },
            p.wl_seat.request.get_keyboard => {
                const id = try r.uint();
                try c.addObject(id, .{ .keyboard = version });
                // A US keyboard's XKB keymap (key events carry Linux key
                // codes, which are its key codes less 8).
                if (keyboard.keymapFile()) |fd| {
                    if (c.send(id, p.wl_keyboard.event.keymap)) |m0| {
                        var e = m0;
                        e.uint(p.wl_keyboard.keymap_format.xkb_v1).fd(fd).uint(keyboard.keymap.len).end();
                    } else _ = linux.close(fd);
                } else |err| log.info("no keymap: {s}", .{@errorName(err)});
                // Clients repeat held keys themselves: 25 a second, after
                // 600 ms.
                if (version >= 4) sendTo(c, id, p.wl_keyboard.event.repeat_info, .{ @as(i32, 25), @as(i32, 600) });
                if (s.keyboard_focus) |surf| if (surf.client == c) s.sendKeyboardEnter(c, id, surf);
            },
            p.wl_seat.request.get_touch => try c.addObject(try r.uint(), .{ .touch = version }),
            p.wl_seat.request.release => c.deleteId(m.object),
            else => return error.InvalidOpcode,
        }
    }

    // --- Popups -----------------------------------------------------------------

    fn positionerRequest(_: *Server, c: *Client, pos: *Positioner, m: wire.Message, r: *wire.Reader) !void {
        const req = p.xdg_positioner.request;
        switch (m.opcode) {
            req.destroy => {
                c.deleteId(m.object);
                c.server.gpa.destroy(pos);
            },
            req.set_size => {
                const w = try r.int();
                const h = try r.int();
                if (w <= 0 or h <= 0) return c.postError(m.object, p.xdg_positioner.err.invalid_input, "a popup's size must be positive", .{});
                pos.width = w;
                pos.height = h;
            },
            req.set_anchor_rect => {
                const rect = [4]i32{ try r.int(), try r.int(), try r.int(), try r.int() };
                if (rect[2] < 0 or rect[3] < 0) return c.postError(m.object, p.xdg_positioner.err.invalid_input, "the anchor rectangle's size is negative", .{});
                pos.anchor_rect = rect;
            },
            req.set_anchor => pos.anchor = try r.uint(),
            req.set_gravity => pos.gravity = try r.uint(),
            req.set_offset => {
                const x = try r.int();
                pos.offset = .{ x, try r.int() };
            },
            req.set_constraint_adjustment => pos.constraint_adjustment = try r.uint(),
            req.set_reactive => pos.reactive = true,
            // The parent's size and configure are known here.
            req.set_parent_size, req.set_parent_configure => {},
            else => return error.InvalidOpcode,
        }
    }

    /// Places a popup as its positioner says, relative to its parent, in
    /// the work area as far as its constraint adjustments allow.
    fn placePopup(s: *const Server, pp: *Popup, pos: Positioner) void {
        pp.positioner = pos;
        const area: ?placement.Rect = if (pp.parent) |parent| if (parent.surface) |ps| if (s.surfaceOrigin(ps)) |o| .{
            .x = s.work_area.x - o[0],
            .y = s.work_area.y - o[1],
            .w = @intCast(s.work_area.width),
            .h = @intCast(s.work_area.height),
        } else null else null else null;
        const r = placement.place(pos, area);
        pp.x = r.x;
        pp.y = r.y;
        pp.width = @intCast(r.w);
        pp.height = @intCast(r.h);
    }

    /// A window moved, or its size changed: its reactive popups are placed
    /// again, and told if that moved them.
    fn replacePopups(s: *Server, t: *const Toplevel) void {
        for (s.popups.items) |pp| {
            if (!pp.positioner.reactive or pp.done) continue;
            const ps = pp.xdg.surface orelse continue;
            if (s.rootToplevel(ps) != t) continue;
            const before = .{ pp.x, pp.y, pp.width, pp.height };
            s.placePopup(pp, pp.positioner);
            if (!std.meta.eql(before, .{ pp.x, pp.y, pp.width, pp.height })) s.configurePopup(ps.client, pp);
        }
    }

    /// Tells a popup where it is and how big.
    fn configurePopup(s: *Server, c: *Client, pp: *Popup) void {
        sendTo(c, pp.id, p.xdg_popup.event.configure, .{ pp.x, pp.y, @as(i32, @intCast(pp.width)), @as(i32, @intCast(pp.height)) });
        sendTo(c, pp.xdg.id, p.xdg_surface.event.configure, .{s.nextSerial()});
    }

    fn mapPopup(s: *Server, pp: *Popup) void {
        if (pp.mapped or pp.done) return;
        pp.mapped = true;
        s.popups.append(s.gpa, pp) catch {
            pp.mapped = false;
            return;
        };
        s.damaged = true;
        s.updateFocus();
    }

    fn unmapPopup(s: *Server, pp: *Popup) void {
        // Popups on it go too.
        var i = s.popups.items.len;
        while (i > 0) {
            i -= 1;
            if (i >= s.popups.items.len) continue;
            const other = s.popups.items[i];
            if (other.parent == pp.xdg) s.dismissPopup(other);
        }
        if (std.mem.indexOfScalar(*Popup, s.popups.items, pp)) |j| _ = s.popups.orderedRemove(j);
        if (!pp.mapped) return;
        pp.mapped = false;
        s.damaged = true;
        s.updateFocus();
    }

    /// Closes a popup: it is told (popup_done), and no longer shown.
    fn dismissPopup(s: *Server, pp: *Popup) void {
        if (!pp.done) {
            pp.done = true;
            if (pp.xdg.surface) |surf| sendTo(surf.client, pp.id, p.xdg_popup.event.popup_done, .{});
        }
        s.unmapPopup(pp);
    }

    fn destroyPopup(s: *Server, pp: *Popup) void {
        s.unmapPopup(pp);
        pp.xdg.popup = null;
        // Popups on it lose their parent.
        for (s.popups.items) |other| if (other.parent == pp.xdg) {
            other.parent = null;
        };
        s.gpa.destroy(pp);
    }

    /// Dismisses every grabbing popup (when something else is clicked).
    fn dismissGrabs(s: *Server) void {
        var i = s.popups.items.len;
        while (i > 0) {
            i -= 1;
            if (i >= s.popups.items.len) continue;
            if (s.popups.items[i].grab) s.dismissPopup(s.popups.items[i]);
        }
    }

    // --- Subsurfaces ------------------------------------------------------------

    /// Takes a subsurface out of its parent's list.
    fn detachSubsurface(_: *Server, sub: *Subsurface) void {
        const parent = sub.parent orelse return;
        if (std.mem.indexOfScalar(*Subsurface, parent.subsurfaces.items, sub)) |i| _ = parent.subsurfaces.orderedRemove(i);
    }

    fn destroySubsurface(s: *Server, sub: *Subsurface) void {
        s.detachSubsurface(sub);
        if (sub.surface) |surf| surf.sub = null;
        s.damaged = true;
        s.gpa.destroy(sub);
    }

    /// Moves a subsurface just above or below a sibling (or to the bottom
    /// of the parent's subsurfaces, for the parent itself: they are all
    /// above it).
    fn restack(s: *Server, sub: *Subsurface, sibling: *Surface, above: bool) void {
        const parent = sub.parent orelse return;
        s.detachSubsurface(sub);
        const list = &parent.subsurfaces;
        var at: usize = 0;
        if (sibling != parent) if (sibling.sub) |other| if (std.mem.indexOfScalar(*Subsurface, list.items, other)) |i| {
            at = if (above) i + 1 else i;
        };
        list.insert(s.gpa, at, sub) catch {};
        s.damaged = true;
    }

    // --- Where surfaces are -------------------------------------------------------

    /// The window a surface belongs to: its own, its parent's (for a
    /// subsurface) or its popup parent's.
    pub fn rootToplevel(_: *const Server, surf: *const Surface) ?*Toplevel {
        var at = surf;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            if (at.sub) |sub| {
                at = sub.parent orelse return null;
                continue;
            }
            const x = at.xdg orelse return null;
            if (x.toplevel) |t| return t;
            const pp = x.popup orelse return null;
            const parent = pp.parent orelse return null;
            at = parent.surface orelse return null;
        }
        return null;
    }

    /// Where a surface's top left is on the screen, if it is shown.
    pub fn surfaceOrigin(s: *const Server, surf: *const Surface) ?[2]i32 {
        if (surf.sub) |sub| {
            const parent = sub.parent orelse return null;
            const o = s.surfaceOrigin(parent) orelse return null;
            return .{ o[0] + sub.x, o[1] + sub.y };
        }
        const x = surf.xdg orelse return null;
        if (x.toplevel) |t| {
            if (!t.shown()) return null;
            const r = s.windowRect(t);
            return .{ r.x, r.y };
        }
        const pp = x.popup orelse return null;
        if (!pp.mapped) return null;
        const parent = pp.parent orelse return null;
        const ps = parent.surface orelse return null;
        const o = s.surfaceOrigin(ps) orelse return null;
        return .{ o[0] + pp.x, o[1] + pp.y };
    }

    /// Something to draw: a surface's picture, at a place on the screen,
    /// clipped to an area.
    pub const Quad = struct { texture: Texture, x: i32, y: i32, clip: Rect };

    /// What to draw, bottom first: each window that can be seen, with its
    /// subsurfaces, then its popups (the top ones, if there are more than
    /// fit in `buf`).
    pub fn drawList(s: *const Server, buf: []Quad) []Quad {
        var shown: [32]*Toplevel = undefined;
        var list: std.ArrayList(Quad) = .initBuffer(buf);
        for (s.visibleWindows(&shown)) |t| {
            const surf = t.xdg.surface orelse continue;
            s.addTree(&list, surf);
            for (s.popups.items) |pp| if (pp.xdg.surface) |ps| if (s.rootToplevel(ps) == t) s.addTree(&list, ps);
        }
        return list.items;
    }

    /// A surface and its subsurfaces, above it.
    fn addTree(s: *const Server, list: *std.ArrayList(Quad), surf: *const Surface) void {
        const o = s.surfaceOrigin(surf) orelse return;
        if (surf.texture()) |tex| {
            // Over the most there is room for: the newest, at the top.
            if (list.items.len == list.capacity) _ = list.orderedRemove(0);
            list.appendAssumeCapacity(.{ .texture = tex, .x = o[0], .y = o[1], .clip = s.work_area });
        }
        for (surf.subsurfaces.items) |sub| if (sub.surface) |child| s.addTree(list, child);
    }

    /// The topmost surface of a tree (`surf` and its subsurfaces) at
    /// (`x`, `y`) on the screen.
    fn hitTree(s: *const Server, surf: *Surface, x: f64, y: f64) ?*Surface {
        var i = surf.subsurfaces.items.len;
        while (i > 0) {
            i -= 1;
            if (surf.subsurfaces.items[i].surface) |child| if (s.hitTree(child, x, y)) |hit| return hit;
        }
        const tex = surf.texture() orelse return null;
        const o = s.surfaceOrigin(surf) orelse return null;
        const x0: f64 = @floatFromInt(o[0]);
        const y0: f64 = @floatFromInt(o[1]);
        if (x >= x0 and x < x0 + @as(f64, @floatFromInt(tex.width)) and y >= y0 and y < y0 + @as(f64, @floatFromInt(tex.height))) return surf;
        return null;
    }

    // --- Copy and paste --------------------------------------------------------

    /// The most MIME types a source may offer.
    const max_mime_types = 16;

    /// `c` copied `src` (or emptied the clipboard): it replaces what the
    /// clipboard held, whose source is told (cancelled). Only the client
    /// with the keyboard may, so a window behind cannot take the clipboard;
    /// from another, the source is cancelled at once.
    fn setSelection(s: *Server, c: *Client, src: ?*DataSource) void {
        const focused = if (s.keyboard_focus) |surf| surf.client == c else false;
        if (!focused) {
            if (src) |x| sendCancelled(x);
            return;
        }
        if (s.selection == src) return;
        if (s.selection) |old| {
            s.forgetSource(old);
            sendCancelled(old);
        }
        s.selection = src;
        s.sendSelection();
    }

    fn sendCancelled(src: *DataSource) void {
        if (src.client.send(src.id, p.wl_data_source.event.cancelled)) |m0| {
            var m = m0;
            m.end();
        }
    }

    /// Offers will not reach `src` any more.
    fn forgetSource(s: *Server, src: *DataSource) void {
        for (s.offers.items) |offer| if (offer.source == src) {
            offer.source = null;
        };
    }

    fn destroySource(s: *Server, src: *DataSource) void {
        s.forgetSource(src);
        if (s.selection == src) {
            s.selection = null;
            s.sendSelection();
        }
        for (src.mime_types.items) |mime| s.gpa.free(mime);
        src.mime_types.deinit(s.gpa);
        s.gpa.destroy(src);
    }

    fn destroyOffer(s: *Server, offer: *DataOffer) void {
        if (std.mem.indexOfScalar(*DataOffer, s.offers.items, offer)) |i| _ = s.offers.swapRemove(i);
        s.gpa.destroy(offer);
    }

    /// Tells the client with the keyboard what the clipboard holds.
    fn sendSelection(s: *Server) void {
        const surf = s.keyboard_focus orelse return;
        const c = surf.client;
        var devices: [4]u32 = undefined;
        var n: usize = 0;
        var it = c.objects.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .data_device and n < devices.len) {
            devices[n] = e.key_ptr.*;
            n += 1;
        };
        // (Offers are added to the objects: not while iterating them.)
        for (devices[0..n]) |id| s.sendSelectionTo(c, id);
    }

    /// Sends a client's data device a new offer of what the clipboard
    /// holds, with its MIME types, as the selection (or that it is empty).
    fn sendSelectionTo(s: *Server, c: *Client, device: u32) void {
        if (c.dead) return;
        const src = s.selection orelse {
            sendTo(c, device, p.wl_data_device.event.selection, .{@as(u32, 0)});
            return;
        };
        const offer = s.gpa.create(DataOffer) catch return;
        offer.* = .{ .source = src };
        const id = c.next_server_id;
        c.next_server_id += 1;
        s.offers.append(s.gpa, offer) catch {
            s.gpa.destroy(offer);
            return;
        };
        c.objects.put(s.gpa, id, .{ .data_offer = offer }) catch {
            _ = s.offers.pop();
            s.gpa.destroy(offer);
            return;
        };
        sendTo(c, device, p.wl_data_device.event.data_offer, .{id});
        for (src.mime_types.items) |mime| if (c.send(id, p.wl_data_offer.event.offer)) |m0| {
            var m = m0;
            m.string(mime).end();
        };
        sendTo(c, device, p.wl_data_device.event.selection, .{id});
    }

    /// A client asks for what the clipboard holds, as `mime`, written to
    /// `fd`: its source is asked to write it. If it has gone, `fd` is
    /// closed (and the client reads nothing).
    fn receive(_: *Server, offer: *DataOffer, mime: []const u8, fd: linux.fd_t) void {
        const src = offer.source orelse {
            _ = linux.close(fd);
            return;
        };
        if (src.client.send(src.id, p.wl_data_source.event.send)) |m0| {
            var m = m0;
            m.string(mime).fd(fd).end();
        } else _ = linux.close(fd);
    }

    // --- Touch ------------------------------------------------------------------

    fn touchPoint(s: *const Server, id: i32) ?TouchPoint {
        for (s.touches) |slot| if (slot) |tp| if (tp.id == id) return tp;
        return null;
    }

    fn touchSlot(s: *Server, id: i32) ?*TouchPoint {
        for (&s.touches) |*slot| if (slot.*) |*tp| if (tp.id == id) return tp;
        return null;
    }

    /// A move or resize follows the pointer or touch to (`x`, `y`).
    fn grabTo(s: *Server, g: Grab, x: f64, y: f64) void {
        if (g.resize) |r| return s.resizeTo(g.t, r, x, y);
        s.moveWindow(g.t, x - g.dx, y - g.dy);
    }

    /// A touch went down at (`x`, `y`) on the screen: on the surface there,
    /// whose window comes to the top (and it closes another client's menus,
    /// as a click does). Finish a group of touch events with `touchFrame`.
    pub fn touchDown(s: *Server, time_ms: u32, id: i32, x: f64, y: f64) void {
        const free = for (&s.touches) |*slot| {
            if (slot.* == null) break slot;
        } else return;
        const surf = s.surfaceAt(x, y);
        const owner: ?*Client = if (surf) |sf| sf.client else null;
        for (s.popups.items) |pp| if (pp.grab) if (pp.xdg.surface) |ps| if (ps.client != owner) {
            s.dismissGrabs();
            break;
        };
        if (surf) |sf| if (s.rootToplevel(sf)) |t| if (t != s.topWindow()) {
            s.raiseToplevel(t);
            s.updateFocus();
        };
        free.* = .{ .id = id, .surface = surf, .x = x, .y = y };
        const sf = surf orelse return;
        const serial = s.nextSerial();
        s.touch_serial = serial;
        s.touch_serial_id = id;
        const local = s.localTo(sf, x, y);
        broadcast(sf.client, .touch, p.wl_touch.event.down, 1, .{ serial, time_ms, sf.id, @as(u32, @bitCast(id)), local[0], local[1] });
        s.touchedClient(sf.client);
    }

    pub fn touchMotion(s: *Server, time_ms: u32, id: i32, x: f64, y: f64) void {
        const tp = s.touchSlot(id) orelse return;
        tp.x = x;
        tp.y = y;
        if (s.grab) |g| if (g.touch == id) return s.grabTo(g, x, y);
        const sf = tp.surface orelse return;
        const local = s.localTo(sf, x, y);
        broadcast(sf.client, .touch, p.wl_touch.event.motion, 1, .{ time_ms, @as(u32, @bitCast(id)), local[0], local[1] });
        s.touchedClient(sf.client);
    }

    pub fn touchUp(s: *Server, time_ms: u32, id: i32) void {
        const tp = s.touchSlot(id) orelse return;
        const surf = tp.surface;
        for (&s.touches) |*slot| if (slot.*) |*x| if (x == tp) {
            slot.* = null;
            break;
        };
        if (s.grab) |g| if (g.touch == id) return s.endGrab();
        const sf = surf orelse return;
        broadcast(sf.client, .touch, p.wl_touch.event.up, 1, .{ s.nextSerial(), time_ms, @as(u32, @bitCast(id)) });
        s.touchedClient(sf.client);
    }

    /// Ends a group of touch events, for the clients they went to.
    pub fn touchFrame(s: *Server) void {
        for (&s.touch_frame_clients) |*slot| if (slot.*) |c| {
            broadcast(c, .touch, p.wl_touch.event.frame, 1, .{});
            slot.* = null;
        };
    }

    fn touchedClient(s: *Server, c: *Client) void {
        for (&s.touch_frame_clients) |*slot| {
            if (slot.* == c) return;
            if (slot.* == null) {
                slot.* = c;
                return;
            }
        }
    }

    /// (`x`, `y`) on the screen, relative to a surface.
    fn localTo(s: *const Server, surf: *const Surface, x: f64, y: f64) [2]f64 {
        const o = s.surfaceOrigin(surf) orelse return .{ x, y };
        return .{ x - @as(f64, @floatFromInt(o[0])), y - @as(f64, @floatFromInt(o[1])) };
    }

    // --- Input ----------------------------------------------------------------

    /// Moves the pointer to (`x`, `y`) on the screen. Finish a batch of
    /// pointer events with `pointerFrame`.
    pub fn pointerMotion(s: *Server, time_ms: u32, x: f64, y: f64) void {
        s.pointer_x = x;
        s.pointer_y = y;
        if (s.grab) |g| {
            // A touch moves this window, not the pointer.
            if (g.touch != null) return;
            return s.grabTo(g, x, y);
        }
        // Entering a surface carries the position.
        if (s.updatePointerFocus()) return;
        const surf = s.pointer_focus orelse return;
        const local = s.surfaceLocal();
        broadcast(surf.client, .pointer, p.wl_pointer.event.motion, 1, .{ time_ms, local[0], local[1] });
    }

    /// `button` is a Linux button code (BTN_LEFT, ...).
    pub fn pointerButton(s: *Server, time_ms: u32, button: u32, pressed: bool) void {
        if (pressed) {
            s.buttons_down += 1;
        } else if (s.buttons_down > 0) {
            s.buttons_down -= 1;
        }
        if (s.grab) |g| {
            // The move ends when the buttons are released, which are not
            // passed on (a touch's ends when it comes up).
            if (s.buttons_down == 0 and g.touch == null) s.endGrab();
            return;
        }
        if (pressed) {
            // Clicking anything but the grabbing client's own surfaces
            // closes its menus.
            const owner: ?*Client = if (s.pointer_focus) |surf| surf.client else null;
            for (s.popups.items) |pp| if (pp.grab) if (pp.xdg.surface) |ps| if (ps.client != owner) {
                s.dismissGrabs();
                break;
            };
            // Clicking a window behind another brings it to the top.
            if (s.pointer_focus) |surf| if (s.rootToplevel(surf)) |t| if (t != s.topWindow()) {
                s.raiseToplevel(t);
                s.updateFocus();
            };
        }
        const surf = s.pointer_focus orelse return;
        const state: u32 = if (pressed) p.wl_pointer.button_state.pressed else p.wl_pointer.button_state.released;
        const serial = s.nextSerial();
        if (pressed) s.press_serial = serial;
        broadcast(surf.client, .pointer, p.wl_pointer.event.button, 1, .{ serial, time_ms, button, state });
    }

    /// Scrolls by `value` (in surface pixels) along `axis`.
    pub fn pointerAxis(s: *Server, time_ms: u32, axis: u32, value: f64) void {
        const surf = s.pointer_focus orelse return;
        broadcast(surf.client, .pointer, p.wl_pointer.event.axis, 1, .{ time_ms, axis, value });
    }

    /// Ends a batch of pointer events that belong together.
    pub fn pointerFrame(s: *Server) void {
        const surf = s.pointer_focus orelse return;
        broadcast(surf.client, .pointer, p.wl_pointer.event.frame, 5, .{});
    }

    /// `key` is a Linux key code (KEY_A, ...).
    pub fn keyboardKey(s: *Server, time_ms: u32, key: u32, pressed: bool) void {
        const changed = s.modifiers.update(key, pressed);
        const surf = s.keyboard_focus orelse return;
        const state: u32 = if (pressed) p.wl_keyboard.key_state.pressed else p.wl_keyboard.key_state.released;
        broadcast(surf.client, .keyboard, p.wl_keyboard.event.key, 1, .{ s.nextSerial(), time_ms, key, state });
        // The modifiers after the key, as the keymap has them.
        if (changed) broadcast(surf.client, .keyboard, p.wl_keyboard.event.modifiers, 1, .{ s.nextSerial(), s.modifiers.depressed(), @as(u32, 0), s.modifiers.locked, @as(u32, 0) });
    }

    /// Tells windows whether they are covered and activated, after the
    /// windows change. Covered windows (hidden behind one window above) get
    /// the suspended state, and no frame callbacks until they can be seen
    /// again; the top window is activated.
    pub fn updateCovered(s: *Server) void {
        const top = s.topWindow();
        for (s.toplevels.items, 0..) |t, i| {
            if (!t.shown()) continue;
            const covered = s.isCovered(t, s.toplevels.items[i + 1 ..]);
            const activated = t == top;
            if (covered == t.suspended and activated == t.activated) continue;
            const uncovered = t.suspended and !covered;
            t.suspended = covered;
            t.activated = activated;
            const surf = t.xdg.surface orelse continue;
            s.configure(surf.client, t);
            if (uncovered) {
                for (surf.held_callbacks.items) |id| s.frame_callbacks.append(s.gpa, .{ .client = surf.client, .id = id }) catch {};
                surf.held_callbacks.clearRetainingCapacity();
                s.damaged = true;
            }
        }
    }

    /// Whether one of the windows `above` hides all that can be seen of `t`.
    fn isCovered(s: *const Server, t: *const Toplevel, above: []const *Toplevel) bool {
        const r = s.visibleRect(t);
        for (above) |u| {
            if (!u.shown()) continue;
            const a = s.visibleRect(u);
            if (a.x <= r.x and a.y <= r.y and
                a.x + @as(i32, @intCast(a.width)) >= r.x + @as(i32, @intCast(r.width)) and
                a.y + @as(i32, @intCast(a.height)) >= r.y + @as(i32, @intCast(r.height))) return true;
        }
        return false;
    }

    /// Moves the focus after the windows change: the keyboard to the top
    /// window, and the pointer to the window under it. Windows are told
    /// whether they are covered (see `updateCovered`).
    pub fn updateFocus(s: *Server) void {
        s.updateCovered();
        if (s.updatePointerFocus()) s.pointerFrame();
        // The top window has the keyboard, or its topmost grabbing popup
        // (a menu) has.
        var top: ?*Surface = if (s.topWindow()) |t| t.xdg.surface else null;
        if (s.topWindow()) |t| for (s.popups.items) |pp| if (pp.grab) if (pp.xdg.surface) |ps| if (s.rootToplevel(ps) == t) {
            top = ps;
        };
        if (top == s.keyboard_focus) return;
        if (s.keyboard_focus) |old| broadcast(old.client, .keyboard, p.wl_keyboard.event.leave, 1, .{ s.nextSerial(), old.id });
        s.keyboard_focus = top;
        // What the clipboard holds comes just before the keyboard.
        s.sendSelection();
        if (top) |surf| {
            var it = surf.client.objects.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .keyboard) s.sendKeyboardEnter(surf.client, e.key_ptr.*, surf);
        }
    }

    /// The surface under the pointer, if any: the top window there.
    fn surfaceUnderPointer(s: *Server) ?*Surface {
        return s.surfaceAt(s.pointer_x, s.pointer_y);
    }

    /// The surface at (`x`, `y`) on the screen, if any: the top one there.
    fn surfaceAt(s: *Server, x: f64, y: f64) ?*Surface {
        // Only what is in the work area can be seen.
        const wa = s.work_area;
        if (x < @as(f64, @floatFromInt(wa.x)) or y < @as(f64, @floatFromInt(wa.y)) or
            x >= @as(f64, @floatFromInt(wa.x + @as(i32, @intCast(wa.width)))) or
            y >= @as(f64, @floatFromInt(wa.y + @as(i32, @intCast(wa.height))))) return null;
        var i = s.toplevels.items.len;
        while (i > 0) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (!t.shown() or t.suspended) continue;
            // Its popups, topmost first, are above it.
            var j = s.popups.items.len;
            while (j > 0) {
                j -= 1;
                const ps = s.popups.items[j].xdg.surface orelse continue;
                if (s.rootToplevel(ps) != t) continue;
                if (s.hitTree(ps, x, y)) |hit| return hit;
            }
            const surf = t.xdg.surface orelse continue;
            if (s.hitTree(surf, x, y)) |hit| return hit;
        }
        return null;
    }

    /// The pointer's position relative to the focused surface.
    fn surfaceLocal(s: *const Server) [2]f64 {
        const surf = s.pointer_focus orelse return .{ 0, 0 };
        const o = s.surfaceOrigin(surf) orelse return .{ 0, 0 };
        return .{ s.pointer_x - @as(f64, @floatFromInt(o[0])), s.pointer_y - @as(f64, @floatFromInt(o[1])) };
    }

    /// Sends leave and enter events if the pointer is over a different
    /// surface. Returns whether it is. While a window is moved, the pointer
    /// is over none.
    fn updatePointerFocus(s: *Server) bool {
        const under = if (s.grab != null) null else s.surfaceUnderPointer();
        if (under == s.pointer_focus) return false;
        if (s.pointer_focus) |old| {
            broadcast(old.client, .pointer, p.wl_pointer.event.leave, 1, .{ s.nextSerial(), old.id });
            broadcast(old.client, .pointer, p.wl_pointer.event.frame, 5, .{});
        }
        s.pointer_focus = under;
        // A window it enters chooses its picture again.
        s.client_cursor = .arrow;
        if (under) |surf| {
            const local = s.surfaceLocal();
            broadcast(surf.client, .pointer, p.wl_pointer.event.enter, 1, .{ s.nextSerial(), surf.id, local[0], local[1] });
        }
        return true;
    }

    fn sendKeyboardEnter(s: *Server, c: *Client, id: u32, surf: *Surface) void {
        const no_keys: []const u8 = &.{};
        sendTo(c, id, p.wl_keyboard.event.enter, .{ s.nextSerial(), surf.id, no_keys });
        sendTo(c, id, p.wl_keyboard.event.modifiers, .{ s.serial, s.modifiers.depressed(), @as(u32, 0), s.modifiers.locked, @as(u32, 0) });
    }

    /// Sends an event to each of a client's pointers or keyboards (bound at
    /// `min_version` or later).
    fn broadcast(c: *Client, comptime kind: std.meta.Tag(Object), opcode: u16, min_version: u32, args: anytype) void {
        var it = c.objects.iterator();
        while (it.next()) |e| {
            const version = switch (e.value_ptr.*) {
                kind => |v| v,
                else => continue,
            };
            if (version >= min_version) sendTo(c, e.key_ptr.*, opcode, args);
        }
    }

    /// Sends an event; u32 and i32 arguments are integers, f64 fixed point
    /// numbers and byte slices arrays.
    fn sendTo(c: *Client, id: u32, opcode: u16, args: anytype) void {
        var m = c.send(id, opcode) orelse return;
        inline for (args) |a| switch (@TypeOf(a)) {
            u32 => _ = m.uint(a),
            i32 => _ = m.int(a),
            f64 => _ = m.fixed(a),
            []const u8 => _ = m.array(a),
            else => @compileError("unsupported argument type " ++ @typeName(@TypeOf(a))),
        };
        m.end();
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
        // A covered window's frame callbacks wait until it is uncovered:
        // its client need not draw what cannot be seen.
        const covered = if (s.rootToplevel(surf)) |t| t.mapped and t.suspended else false;
        // Subsurfaces take their new places with their parent.
        for (surf.subsurfaces.items) |sub| if (sub.pending) |pos| {
            sub.x = pos[0];
            sub.y = pos[1];
            sub.pending = null;
        };
        // Shown for the first time: on the screen.
        if (!surf.entered and surf.texture() != null) {
            surf.entered = true;
            s.sendEnter(c, surf);
        }
        if (covered) {
            try surf.held_callbacks.appendSlice(s.gpa, surf.pending_callbacks.items);
        } else {
            for (surf.pending_callbacks.items) |id| try s.frame_callbacks.append(s.gpa, .{ .client = c, .id = id });
        }
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
            // Drawn since acknowledging the last configure: the next size
            // can be sent.
            if (t.acked and !t.drawn) s.drewConfigure(c, t);
        };
        if (surf.xdg) |x| if (x.popup) |pp| {
            if (!x.configured) {
                if (surf.texture() != null) return c.postError(x.id, p.xdg_surface.err.unconfigured_buffer, "buffer before the first configure", .{});
                // Placed again: the parent may have moved since.
                s.configurePopup(c, pp);
                x.configured = true;
            } else if (surf.texture() != null and !pp.mapped) {
                s.mapPopup(pp);
            } else if (surf.texture() == null and pp.mapped) {
                s.unmapPopup(pp);
            }
        };
        // What a covered window shows changes nothing on the screen.
        if (!covered) s.damaged = true;
    }

    /// Sends a toplevel its size and state: maximized or not, activated if
    /// it is the top window, and suspended if it is covered (to clients
    /// that know the state).
    /// Configures `t` with its new size, or once it has drawn at the last
    /// one it was told.
    fn requestConfigure(s: *Server, c: *Client, t: *Toplevel) void {
        if (t.drawn) s.configure(c, t) else t.resend = true;
    }

    /// The client acknowledged the last configure: it draws at its size
    /// next (or need not, if the size is the one it shows).
    fn acked(s: *Server, t: *Toplevel) void {
        t.acked = true;
        const surf = t.xdg.surface orelse return;
        const tex = surf.texture() orelse return;
        const size = s.configuredSize(t);
        if (tex.width == size[0] and tex.height == size[1]) s.drewConfigure(surf.client, t);
    }

    fn drewConfigure(s: *Server, c: *Client, t: *Toplevel) void {
        t.drawn = true;
        if (t.resend) {
            t.resend = false;
            s.configure(c, t);
        } else s.settle(t, false);
    }

    fn configure(s: *Server, c: *Client, t: *Toplevel) void {
        if (t.xdg.version >= 5 and !t.capabilities_sent) {
            // Of the optional features, only maximizing: no menus,
            // fullscreen or minimizing.
            if (c.send(t.id, p.xdg_toplevel.event.wm_capabilities)) |m0| {
                var e = m0;
                var caps: [4]u8 = undefined;
                std.mem.writeInt(u32, &caps, p.xdg_toplevel.wm_capabilities.maximize, .little);
                e.array(&caps).end();
            }
            t.capabilities_sent = true;
        }
        // The biggest it can usefully be: the work area.
        if (t.xdg.version >= 4) sendTo(c, t.id, p.xdg_toplevel.event.configure_bounds, .{ @as(i32, @intCast(s.work_area.width)), @as(i32, @intCast(s.work_area.height)) });
        if (c.send(t.id, p.xdg_toplevel.event.configure)) |m0| {
            var e = m0;
            var states: [16]u8 = undefined;
            var n: usize = 0;
            const set = [_]struct { bool, u32 }{
                .{ t.maximized, p.xdg_toplevel.state.maximized },
                .{ s.resizing(t), p.xdg_toplevel.state.resizing },
                .{ t.activated, p.xdg_toplevel.state.activated },
                .{ t.suspended and t.xdg.version >= 6, p.xdg_toplevel.state.suspended },
            };
            for (set) |st| if (st[0]) {
                std.mem.writeInt(u32, states[n..][0..4], st[1], .little);
                n += 4;
            };
            const size = s.configuredSize(t);
            e.int(@intCast(size[0])).int(@intCast(size[1])).array(states[0..n]).end();
        }
        if (c.send(t.xdg.id, p.xdg_surface.event.configure)) |m0| {
            var e = m0;
            t.configure_serial = s.nextSerial();
            t.acked = false;
            t.drawn = false;
            t.resend = false;
            e.uint(t.configure_serial).end();
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
