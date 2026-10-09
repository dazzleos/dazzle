//! Protocol tests of the server's newer features (outputs, subsurfaces,
//! popups, the keyboard's keymap and modifiers, copy and paste), run on one
//! thread: clients write requests, the server handles them, and the
//! clients handle the events, in turn, so every step is deterministic.

const std = @import("std");
const vc4 = @import("vc4");
const linux = std.os.linux;
const wayland = @import("wayland");
const server_mod = @import("server.zig");

const p = wayland.protocol;
const client = wayland.client;
const wire = wayland.wire;
const testing = std.testing;
const Server = server_mod.Server;

/// Textures without a GPU.
const FakeRenderer = struct {
    next: u32 = 1,

    fn backend(r: *FakeRenderer) server_mod.Backend {
        return .{ .ptr = r, .vtable = &.{ .importDmabuf = importDmabuf, .uploadPixels = uploadPixels, .destroyTexture = destroyTexture } };
    }

    fn importDmabuf(ptr: *anyopaque, fd: linux.fd_t, w: u32, h: u32, format: vc4.Format) anyerror!server_mod.Texture {
        const r: *FakeRenderer = @ptrCast(@alignCast(ptr));
        _ = linux.close(fd);
        r.next += 1;
        return .{ .handle = r.next, .width = w, .height = h, .format = format };
    }

    fn uploadPixels(ptr: *anyopaque, existing: ?server_mod.Texture, _: []const u8, w: u32, h: u32, _: u32, format: vc4.Format) anyerror!server_mod.Texture {
        const r: *FakeRenderer = @ptrCast(@alignCast(ptr));
        if (existing) |e| if (e.width == w and e.height == h and e.format == format) return e;
        r.next += 1;
        return .{ .handle = r.next, .width = w, .height = h, .format = format };
    }

    fn destroyTexture(_: *anyopaque, _: server_mod.Texture) void {}
};

/// The server with a work area of 800x560 at 0,40 (under a 40-pixel
/// panel), and its clients.
const World = struct {
    renderer: FakeRenderer = .{},
    server: Server = undefined,
    peers: [3]?*Peer = @splat(null),

    fn init(w: *World) void {
        w.server = .init(testing.allocator, w.renderer.backend(), .{ .x = 0, .y = 40, .width = 800, .height = 560 });
        w.server.output = .{ .width = 800, .height = 600, .refresh_mhz = 59940 };
    }

    fn deinit(w: *World) void {
        for (&w.peers) |*slot| if (slot.*) |peer| {
            peer.d.disconnect();
            testing.allocator.destroy(peer);
            slot.* = null;
        };
        w.server.deinit();
    }

    /// Connects a client, with its registry's globals.
    fn connect(w: *World) !*Peer {
        var pair: [2]linux.fd_t = undefined;
        if (linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair) != 0) return error.SystemResources;
        const peer = try testing.allocator.create(Peer);
        peer.* = .{ .world = w, .c = try w.server.addClient(pair[0]), .d = try client.Display.fromFd(testing.allocator, pair[1]) };
        for (&w.peers) |*slot| if (slot.* == null) {
            slot.* = peer;
            break;
        };
        peer.registry = try peer.d.newObject(.{ .ptr = peer, .handler = Peer.registryEvent });
        var m = try peer.d.proxy().request(p.wl_display.request.get_registry);
        m.uint(peer.registry.id).end();
        try w.pump();
        return peer;
    }

    /// Requests to the server, its events to the clients, until both are
    /// quiet.
    fn pump(w: *World) !void {
        for (0..4) |_| {
            for (w.peers) |slot| if (slot) |peer| if (!peer.gone) {
                try peer.d.flush();
                // Disconnected (and freed) after an error.
                if (!w.server.dispatch(peer.c)) peer.gone = true;
            };
            w.server.updateFocus();
            w.server.flushClients();
            for (w.peers) |slot| if (slot) |peer| if (!peer.gone) {
                _ = peer.d.dispatchPending() catch |e| if (e != error.ServerError) return e;
            };
        }
    }

    /// What the renderer would draw: where each surface's picture goes.
    fn drawn(w: *World, buf: *[16]Server.Quad) []Server.Quad {
        return w.server.drawList(buf);
    }
};

/// A client, with what it has seen.
const Peer = struct {
    world: *World,
    c: *server_mod.Client,
    d: *client.Display,
    /// The server disconnected it (`c` is gone).
    gone: bool = false,
    registry: client.Proxy = undefined,
    globals: [16]struct { name: u32, interface: [40]u8, len: usize } = undefined,
    n_globals: usize = 0,

    fn registryEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const peer: *Peer = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_registry.event.global or peer.n_globals == peer.globals.len) return;
        const name = r.uint() catch return;
        const interface = (r.string() catch return) orelse return;
        const g = &peer.globals[peer.n_globals];
        g.name = name;
        g.len = @min(interface.len, g.interface.len);
        @memcpy(g.interface[0..g.len], interface[0..g.len]);
        peer.n_globals += 1;
    }

    fn bind(peer: *Peer, interface: []const u8, version: u32, listener: ?client.Listener) !client.Proxy {
        for (peer.globals[0..peer.n_globals]) |g| if (std.mem.eql(u8, g.interface[0..g.len], interface)) {
            const obj = try peer.d.newObject(listener);
            var m = try peer.registry.request(p.wl_registry.request.bind);
            m.uint(g.name).string(interface).uint(version).uint(obj.id).end();
            return obj;
        };
        return error.NoSuchGlobal;
    }

    /// A buffer of `w`x`h` pixels in shared memory.
    fn shmBuffer(peer: *Peer, shm: client.Proxy, w: i32, h: i32) !client.Proxy {
        const size = w * h * 4;
        const memfd: linux.fd_t = @intCast(linux.memfd_create("test", linux.MFD.CLOEXEC));
        _ = linux.ftruncate(memfd, size);
        const pool = try peer.d.newObject(null);
        var m = try shm.request(p.wl_shm.request.create_pool);
        m.uint(pool.id).fd(memfd).int(size).end();
        const buffer = try peer.d.newObject(null);
        m = try pool.request(p.wl_shm_pool.request.create_buffer);
        m.uint(buffer.id).int(0).int(w).int(h).int(w * 4).uint(p.wl_shm.format.xrgb8888).end();
        m = try pool.request(p.wl_shm_pool.request.destroy);
        m.end();
        return buffer;
    }

    fn surface(peer: *Peer, compositor: client.Proxy, listener: ?client.Listener) !client.Proxy {
        const surf = try peer.d.newObject(listener);
        var m = try compositor.request(p.wl_compositor.request.create_surface);
        m.uint(surf.id).end();
        return surf;
    }

    fn show(_: *Peer, surf: client.Proxy, buffer: client.Proxy) !void {
        var m = try surf.request(p.wl_surface.request.attach);
        m.uint(buffer.id).int(0).int(0).end();
        m = try surf.request(p.wl_surface.request.commit);
        m.end();
    }
};

/// What a client heard on an object: the last event's opcode and
/// arguments (as numbers), and how many there were.
const Heard = struct {
    events: u32 = 0,
    last_opcode: u16 = 0,
    args: [8]i64 = @splat(0),
    /// Events by opcode.
    counts: [8]u32 = @splat(0),
    /// On a keyboard: its keymap event carries a file, which is closed.
    keyboard: bool = false,

    fn listener(h: *Heard) client.Listener {
        return .{ .ptr = h, .handler = event };
    }

    fn event(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const h: *Heard = @ptrCast(@alignCast(ptr.?));
        h.events += 1;
        h.last_opcode = opcode;
        if (opcode < h.counts.len) h.counts[opcode] += 1;
        h.args = @splat(0);
        // The keymap's file: closed.
        if (h.keyboard and opcode == p.wl_keyboard.event.keymap) {
            _ = r.uint() catch {};
            if (r.fd()) |fd| _ = linux.close(fd) else |_| {}
            return;
        }
        // Every other event these tests listen for starts with numbers;
        // read as many as there are.
        for (&h.args) |*a| a.* = @as(i32, @bitCast(r.uint() catch break));
    }
};

/// A maximized window: its surface, xdg_surface and toplevel, configured
/// and showing a buffer the size it was told.
const Window = struct {
    surface: client.Proxy,
    xdg: client.Proxy,
    toplevel: client.Proxy,
    xdg_heard: Heard = .{},

    fn open(win: *Window, peer: *Peer, compositor: client.Proxy, wm_base: client.Proxy, shm: client.Proxy, surface_listener: ?client.Listener) !void {
        win.surface = try peer.surface(compositor, surface_listener);
        win.xdg = try peer.d.newObject(win.xdg_heard.listener());
        var m = try wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(win.xdg.id).uint(win.surface.id).end();
        win.toplevel = try peer.d.newObject(null);
        m = try win.xdg.request(p.xdg_surface.request.get_toplevel);
        m.uint(win.toplevel.id).end();
        // Windows open at the size their client chooses; this one fills
        // the work area.
        m = try win.toplevel.request(p.xdg_toplevel.request.set_maximized);
        m.end();
        m = try win.surface.request(p.wl_surface.request.commit);
        m.end();
        try peer.world.pump();
        m = try win.xdg.request(p.xdg_surface.request.ack_configure);
        m.uint(@intCast(win.xdg_heard.args[0])).end();
        try peer.show(win.surface, try peer.shmBuffer(shm, 800, 560));
        try peer.world.pump();
    }
};

test "the output describes the screen, and windows are on it" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    var output_heard: Heard = .{};
    const output = try a.bind(p.wl_output.name, 4, output_heard.listener());
    try w.pump();
    // geometry, mode, scale, name, description, done: the mode last
    // before the name.
    try testing.expectEqual(@as(u32, 1), output_heard.counts[p.wl_output.event.mode]);
    try testing.expectEqual(@as(u32, 1), output_heard.counts[p.wl_output.event.done]);
    try testing.expectEqual(@as(u32, 1), output_heard.counts[p.wl_output.event.scale]);
    try testing.expectEqual(p.wl_output.event.done, output_heard.last_opcode);

    // A window shown is on the output.
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    var surface_heard: Heard = .{};
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, surface_heard.listener());
    try testing.expectEqual(p.wl_surface.event.enter, surface_heard.last_opcode);
    try testing.expectEqual(@as(i64, output.id), surface_heard.args[0]);
}

test "subsurfaces are drawn above their parent, where it says, and take the pointer" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const subcompositor = try a.bind(p.wl_subcompositor.name, 1, null);
    var pointer_heard: Heard = .{};
    const seat = try a.bind(p.wl_seat.name, 5, null);
    const pointer = try a.d.newObject(pointer_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_pointer);
    m.uint(pointer.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    // Two subsurfaces, 32x16, at 10,20 and 12,22 in the window.
    const subs = [2]client.Proxy{ try a.surface(compositor, null), try a.surface(compositor, null) };
    var roles: [2]client.Proxy = undefined;
    for (subs, &roles, 0..) |sub, *role, i| {
        role.* = try a.d.newObject(null);
        m = try subcompositor.request(p.wl_subcompositor.request.get_subsurface);
        m.uint(role.id).uint(sub.id).uint(win.surface.id).end();
        m = try role.request(p.wl_subsurface.request.set_position);
        m.int(10 + 2 * @as(i32, @intCast(i))).int(20 + 2 * @as(i32, @intCast(i))).end();
        try a.show(sub, try a.shmBuffer(shm, 32, 16));
    }
    try w.pump();
    var buf: [16]Server.Quad = undefined;
    // Their places take effect when the parent is committed.
    try testing.expectEqual(@as(usize, 3), w.drawn(&buf).len);
    try testing.expectEqual(@as(i32, 40), w.drawn(&buf)[1].y);
    m = try win.surface.request(p.wl_surface.request.commit);
    m.end();
    try w.pump();
    const drawn = w.drawn(&buf);
    try testing.expectEqual(@as(i32, 10), drawn[1].x);
    try testing.expectEqual(@as(i32, 60), drawn[1].y);
    try testing.expectEqual(@as(i32, 12), drawn[2].x);

    // The pointer over the top one is on it, in its coordinates.
    w.server.pointerMotion(1, 15, 65);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(w.server.pointer_focus.?.id, subs[1].id);

    // The first above the second: it is on top.
    m = try roles[0].request(p.wl_subsurface.request.place_above);
    m.uint(subs[1].id).end();
    try w.pump();
    try testing.expectEqual(@as(i32, 10), w.drawn(&buf)[2].x);

    // A surface cannot be its own parent.
    const bad = try a.d.newObject(null);
    m = try subcompositor.request(p.wl_subcompositor.request.get_subsurface);
    m.uint(bad.id).uint(win.surface.id).uint(subs[0].id).end();
    try w.pump();
    try testing.expect(a.gone);
}

test "popups go where their positioner says, take the keyboard, and close on a click elsewhere" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    var keyboard_heard: Heard = .{ .keyboard = true };
    const keyboard = try a.d.newObject(keyboard_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_keyboard);
    m.uint(keyboard.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    // 100x50, under the left of a 40x10 rectangle at 20,30, extending
    // down and right.
    const positioner = try a.d.newObject(null);
    m = try wm_base.request(p.xdg_wm_base.request.create_positioner);
    m.uint(positioner.id).end();
    m = try positioner.request(p.xdg_positioner.request.set_size);
    m.int(100).int(50).end();
    m = try positioner.request(p.xdg_positioner.request.set_anchor_rect);
    m.int(20).int(30).int(40).int(10).end();
    m = try positioner.request(p.xdg_positioner.request.set_anchor);
    m.uint(p.xdg_positioner.anchor.bottom_left).end();
    m = try positioner.request(p.xdg_positioner.request.set_gravity);
    m.uint(p.xdg_positioner.anchor.bottom_right).end();

    const surf = try a.surface(compositor, null);
    var xdg_heard: Heard = .{};
    const xdg = try a.d.newObject(xdg_heard.listener());
    m = try wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
    m.uint(xdg.id).uint(surf.id).end();
    var popup_heard: Heard = .{};
    const popup = try a.d.newObject(popup_heard.listener());
    m = try xdg.request(p.xdg_surface.request.get_popup);
    m.uint(popup.id).uint(win.xdg.id).uint(positioner.id).end();
    m = try popup.request(p.xdg_popup.request.grab);
    m.uint(seat.id).uint(0).end();
    m = try surf.request(p.wl_surface.request.commit);
    m.end();
    try w.pump();
    try testing.expectEqual(p.xdg_popup.event.configure, popup_heard.last_opcode);
    try testing.expectEqualSlices(i64, &.{ 20, 40, 100, 50 }, popup_heard.args[0..4]);
    m = try xdg.request(p.xdg_surface.request.ack_configure);
    m.uint(@intCast(xdg_heard.args[0])).end();
    try a.show(surf, try a.shmBuffer(shm, 100, 50));
    try w.pump();
    // Above the window (at 0,40), at 20,40 in it; with the keyboard.
    var buf: [16]Server.Quad = undefined;
    const drawn = w.drawn(&buf);
    try testing.expectEqual(@as(usize, 2), drawn.len);
    try testing.expectEqual(@as(i32, 20), drawn[1].x);
    try testing.expectEqual(@as(i32, 80), drawn[1].y);
    try testing.expectEqual(w.server.keyboard_focus.?.id, surf.id);
    // Not on the display directly: it is drawn on the window.
    try testing.expect(w.server.scanoutBuffer(w.server.topWindow().?) == null);

    // Moved to the right edge, it slides back into the work area (as its
    // positioner allows).
    m = try positioner.request(p.xdg_positioner.request.set_anchor_rect);
    m.int(780).int(30).int(10).int(10).end();
    m = try positioner.request(p.xdg_positioner.request.set_constraint_adjustment);
    m.uint(@import("placement.zig").adjust.slide_x).end();
    m = try popup.request(p.xdg_popup.request.reposition);
    m.uint(positioner.id).uint(7).end();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), popup_heard.counts[p.xdg_popup.event.repositioned]);
    try testing.expectEqualSlices(i64, &.{ 700, 40, 100, 50 }, popup_heard.args[0..4]);

    // A click on its own window leaves it; a click outside every window
    // (above the work area) closes it, and the keyboard goes back.
    w.server.pointerMotion(1, 400, 300);
    w.server.pointerButton(1, p.input.btn_left, true);
    w.server.pointerButton(2, p.input.btn_left, false);
    try w.pump();
    try testing.expectEqual(@as(u32, 0), popup_heard.counts[p.xdg_popup.event.popup_done]);
    w.server.pointerMotion(3, 400, 10);
    w.server.pointerButton(3, p.input.btn_left, true);
    w.server.pointerButton(4, p.input.btn_left, false);
    try w.pump();
    try testing.expectEqual(@as(u32, 1), popup_heard.counts[p.xdg_popup.event.popup_done]);
    try testing.expectEqual(@as(usize, 1), w.drawn(&buf).len);
    try testing.expectEqual(w.server.keyboard_focus.?.id, win.surface.id);
    m = try popup.request(p.xdg_popup.request.destroy);
    m.end();
    try w.pump();
    try testing.expect(!a.c.dead);
}

test "the keyboard's modifiers are sent as they change" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    var keyboard_heard: Heard = .{ .keyboard = true };
    const keyboard = try a.d.newObject(keyboard_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_keyboard);
    m.uint(keyboard.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);
    const before = keyboard_heard.counts[p.wl_keyboard.event.modifiers];
    // Shift down: the key, then the modifiers (Shift).
    w.server.keyboardKey(1, 42, true);
    try w.pump();
    try testing.expectEqual(p.wl_keyboard.event.modifiers, keyboard_heard.last_opcode);
    try testing.expectEqual(@as(i64, 1), keyboard_heard.args[1]);
    // A letter: no modifiers event.
    w.server.keyboardKey(2, 30, true);
    try w.pump();
    try testing.expectEqual(p.wl_keyboard.event.key, keyboard_heard.last_opcode);
    w.server.keyboardKey(3, 42, false);
    try w.pump();
    try testing.expectEqual(@as(i64, 0), keyboard_heard.args[1]);
    try testing.expectEqual(before + 2, keyboard_heard.counts[p.wl_keyboard.event.modifiers]);
}

/// What a client heard on its data device: offers, their MIME types, and
/// the selection.
const DataHeard = struct {
    peer: *Peer,
    offer: ?u32 = null,
    selection: ?u32 = null,
    selections: u32 = 0,
    mime: [64]u8 = undefined,
    mime_len: usize = 0,

    fn deviceEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const h: *DataHeard = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_data_device.event.data_offer => {
                const id = r.uint() catch return;
                h.offer = id;
                d.setListener(id, .{ .ptr = h, .handler = offerEvent }) catch {};
            },
            p.wl_data_device.event.selection => {
                const id = r.uint() catch return;
                h.selection = if (id == 0) null else id;
                h.selections += 1;
            },
            else => {},
        }
    }

    fn offerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const h: *DataHeard = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_data_offer.event.offer) return;
        const mime = (r.string() catch return) orelse return;
        h.mime_len = @min(mime.len, h.mime.len);
        @memcpy(h.mime[0..h.mime_len], mime[0..h.mime_len]);
    }
};

/// What a client heard on its data source: what to send, and where.
const SourceHeard = struct {
    send_fd: ?linux.fd_t = null,
    cancelled: bool = false,

    fn event(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const h: *SourceHeard = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_data_source.event.send => {
                _ = r.string() catch return;
                h.send_fd = r.fd() catch return;
            },
            p.wl_data_source.event.cancelled => h.cancelled = true,
            else => {},
        }
    }
};

test "text copied in one client is pasted in another" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const mime = "text/plain;charset=utf-8";
    // Each client: a window, the keyboard, and a data device.
    const Side = struct {
        peer: *Peer,
        manager: client.Proxy,
        device: client.Proxy,
        heard: DataHeard,
        keyboard_heard: Heard = .{ .keyboard = true },
        win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined },

        fn setUp(side: *@This(), world: *World) !void {
            const peer = try world.connect();
            side.* = .{ .peer = peer, .manager = undefined, .device = undefined, .heard = .{ .peer = peer } };
            const compositor = try peer.bind(p.wl_compositor.name, 4, null);
            const wm_base = try peer.bind(p.xdg_wm_base.name, 6, null);
            const shm = try peer.bind(p.wl_shm.name, 1, null);
            const seat = try peer.bind(p.wl_seat.name, 5, null);
            const keyboard = try peer.d.newObject(side.keyboard_heard.listener());
            var m = try seat.request(p.wl_seat.request.get_keyboard);
            m.uint(keyboard.id).end();
            side.manager = try peer.bind(p.wl_data_device_manager.name, 3, null);
            side.device = try peer.d.newObject(.{ .ptr = &side.heard, .handler = DataHeard.deviceEvent });
            m = try side.manager.request(p.wl_data_device_manager.request.get_data_device);
            m.uint(side.device.id).uint(seat.id).end();
            try side.win.open(peer, compositor, wm_base, shm, null);
        }

        fn copy(side: *@This(), heard: *SourceHeard) !client.Proxy {
            const source = try side.peer.d.newObject(.{ .ptr = heard, .handler = SourceHeard.event });
            var m = try side.manager.request(p.wl_data_device_manager.request.create_data_source);
            m.uint(source.id).end();
            m = try source.request(p.wl_data_source.request.offer);
            m.string(mime).end();
            m = try side.device.request(p.wl_data_device.request.set_selection);
            m.uint(source.id).uint(0).end();
            return source;
        }
    };
    var a: Side = undefined;
    try a.setUp(&w);
    // A (with the keyboard) copies: it is told the clipboard has it.
    var a_source_heard: SourceHeard = .{};
    _ = try a.copy(&a_source_heard);
    try w.pump();
    try testing.expect(a.heard.selection != null);
    try testing.expectEqualStrings(mime, a.heard.mime[0..a.heard.mime_len]);

    // B's window opens on top, with the keyboard: it is told what the
    // clipboard holds, and asks for it.
    var b: Side = undefined;
    try b.setUp(&w);
    try testing.expectEqual(w.server.keyboard_focus.?.client, b.peer.c);
    const offer = b.heard.selection orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(mime, b.heard.mime[0..b.heard.mime_len]);
    var pipe: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    var m = try (client.Proxy{ .display = b.peer.d, .id = offer }).request(p.wl_data_offer.request.receive);
    m.string(mime).fd(pipe[1]).end();
    try w.pump();
    // A writes it; B reads it.
    const fd = a_source_heard.send_fd orelse return error.TestUnexpectedResult;
    _ = linux.write(fd, "hello", 5);
    _ = linux.close(fd);
    var got: [16]u8 = undefined;
    const n = linux.read(pipe[0], &got, got.len);
    _ = linux.close(pipe[0]);
    try testing.expectEqualStrings("hello", got[0..n]);

    // B copies: A's source is cancelled. A cannot copy (it has not the
    // keyboard): its new source is cancelled at once.
    var b_source_heard: SourceHeard = .{};
    const b_source = try b.copy(&b_source_heard);
    try w.pump();
    try testing.expect(a_source_heard.cancelled);
    var late: SourceHeard = .{};
    _ = try a.copy(&late);
    try w.pump();
    try testing.expect(late.cancelled and !b_source_heard.cancelled);
    // B's source destroyed: the clipboard is empty.
    m = try b_source.request(p.wl_data_source.request.destroy);
    m.end();
    try w.pump();
    try testing.expect(b.heard.selection == null);
}

test "touches go to the surface they went down on, and can move its window" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    var seat_heard: Heard = .{};
    const seat = try a.bind(p.wl_seat.name, 5, seat_heard.listener());
    var touch_heard: Heard = .{};
    const touch = try a.d.newObject(touch_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_touch);
    m.uint(touch.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);
    try testing.expect(seat_heard.args[0] & p.wl_seat.capability.touch != 0);

    // Down at 100,140 on the screen: 100,100 in the window (at 0,40).
    w.server.touchDown(1, 3, 100, 140);
    w.server.touchFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), touch_heard.counts[p.wl_touch.event.down]);
    try testing.expectEqual(p.wl_touch.event.frame, touch_heard.last_opcode);
    w.server.touchMotion(2, 3, 110, 150);
    try w.pump();
    try testing.expectEqualSlices(i64, &.{ 2, 3, 110 * 256, 110 * 256 }, touch_heard.args[0..4]);
    w.server.touchUp(3, 3);
    w.server.touchFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), touch_heard.counts[p.wl_touch.event.up]);

    // Restored (to 400x280 at 200,180), the window moves with a touch on
    // it once the client asks, which is told the touch is not its own any
    // more.
    m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try w.pump();
    w.server.touchDown(4, 5, 250, 200);
    try w.pump();
    const serial: u32 = @intCast(touch_heard.args[0]);
    m = try win.toplevel.request(p.xdg_toplevel.request.move);
    m.uint(seat.id).uint(serial).end();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), touch_heard.counts[p.wl_touch.event.cancel]);
    const moves_before = touch_heard.counts[p.wl_touch.event.motion];
    w.server.touchMotion(5, 5, 300, 260);
    // The pointer does not move it meanwhile.
    w.server.pointerMotion(5, 10, 500);
    try w.pump();
    const t = w.server.topWindow().?;
    try testing.expectEqual(@as(i32, 250), t.x);
    try testing.expectEqual(@as(i32, 240), t.y);
    try testing.expectEqual(moves_before, touch_heard.counts[p.wl_touch.event.motion]);
    w.server.touchUp(6, 5);
    try w.pump();
    try testing.expect(w.server.grab == null);
    try testing.expectEqual(@as(u32, 1), touch_heard.counts[p.wl_touch.event.up]);
}
