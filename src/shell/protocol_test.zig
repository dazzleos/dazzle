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
    counts: [16]u32 = @splat(0),
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

    /// Acknowledges the last configure (after its state changed, say), as
    /// a client does before it draws again.
    fn ack(win: *Window, peer: *Peer) !void {
        try peer.world.pump();
        var m = try win.xdg.request(p.xdg_surface.request.ack_configure);
        m.uint(@intCast(win.xdg_heard.args[0])).end();
    }

    /// Acknowledges the last configure, and draws at `width` by `height`.
    fn redraw(win: *Window, peer: *Peer, shm: client.Proxy, width: i32, height: i32) !void {
        try win.ack(peer);
        try peer.show(win.surface, try peer.shmBuffer(shm, width, height));
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

test "a window's last frame stays where it was until it draws as it is told to be" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);
    var quads: [16]Server.Quad = undefined;
    const maximized = w.drawn(&quads)[0];

    // Restored: the maximized frame is where it was, not in the restored
    // window's place, until a frame comes at the restored size.
    var m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try win.ack(a);
    try w.pump();
    var drawn = w.drawn(&quads)[0];
    try testing.expectEqual(maximized.x, drawn.x);
    try testing.expectEqual(maximized.y, drawn.y);
    try a.show(win.surface, try a.shmBuffer(shm, 400, 280));
    try w.pump();
    drawn = w.drawn(&quads)[0];
    try testing.expectEqual(@as(i32, 200), drawn.x);
    try testing.expectEqual(@as(i32, 180), drawn.y);

    // Maximized again: the restored frame stays put until the maximized one.
    m = try win.toplevel.request(p.xdg_toplevel.request.set_maximized);
    m.end();
    try win.ack(a);
    try w.pump();
    drawn = w.drawn(&quads)[0];
    try testing.expectEqual(@as(i32, 200), drawn.x);
    try win.redraw(a, shm, 800, 560);
    drawn = w.drawn(&quads)[0];
    try testing.expectEqual(maximized.x, drawn.x);
    try testing.expectEqual(maximized.y, drawn.y);
}

test "a window leaving fullscreen goes back to where and how big it was" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);
    var quads: [16]Server.Quad = undefined;

    // Restored, at 200,180 and 400 by 280.
    var m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try win.redraw(a, shm, 400, 280);
    var drawn = w.drawn(&quads)[0];
    try testing.expectEqual(@as(i32, 200), drawn.x);
    try testing.expectEqual(@as(i32, 180), drawn.y);

    // Fullscreen: the whole screen.
    m = try win.toplevel.request(p.xdg_toplevel.request.set_fullscreen);
    m.uint(0).end();
    try w.pump();
    try win.redraw(a, shm, @intCast(w.server.output.width), @intCast(w.server.output.height));
    drawn = w.drawn(&quads)[0];
    try testing.expectEqual(@as(i32, 0), drawn.x);
    try testing.expectEqual(@as(i32, 0), drawn.y);
    // Its client says how small it may be (as kete does as its content
    // changes): that is not its size when restored.
    m = try win.toplevel.request(p.xdg_toplevel.request.set_min_size);
    m.int(300).int(200).end();
    try w.pump();

    // Back: where it was, as big as it was.
    m = try win.toplevel.request(p.xdg_toplevel.request.unset_fullscreen);
    m.end();
    try w.pump();
    const t = w.server.toplevels.items[0];
    try testing.expectEqual([2]u32{ 400, 280 }, w.server.configuredSize(t));
    try win.redraw(a, shm, 400, 280);
    drawn = w.drawn(&quads)[0];
    try testing.expectEqual(@as(i32, 200), drawn.x);
    try testing.expectEqual(@as(i32, 180), drawn.y);
    try testing.expectEqual(@as(u32, 400), drawn.width);
    try testing.expectEqual(@as(u32, 280), drawn.height);
}

test "the overview shows every window smaller, side by side, without telling them, and one picked comes to the top" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    // A maximized (800 by 560), and B above it, restored at 400 by 280.
    var win_a: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win_a.open(a, compositor, wm_base, shm, null);
    var win_b: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win_b.open(a, compositor, wm_base, shm, null);
    var m = try win_b.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try win_b.redraw(a, shm, 400, 280);
    const t_a = w.server.toplevels.items[0];
    const t_b = w.server.toplevels.items[1];
    try testing.expectEqual(t_b, w.server.topWindow().?);

    w.server.setOverview(true);
    try w.pump();
    try testing.expect(w.server.overview);
    var quads: [16]Server.Quad = undefined;
    // On their way: half the time is half the way (slow, quick, slow).
    try testing.expect(w.server.animateOverview(1000));
    try testing.expectEqual(@as(u32, 800), w.drawn(&quads)[0].width);
    try testing.expect(w.server.animateOverview(1000 + Server.overview_ns / 2));
    try testing.expectEqual(@as(u32, (800 + 352) / 2), w.drawn(&quads)[0].width);
    try testing.expect(!w.server.animateOverview(1000 + Server.overview_ns));
    // Two cells across the work area (32 around and between them), each
    // 352 by 496: B (the top one) on the left, A on the right, each as big
    // as fits its cell, in the middle of it. A is drawn first, below.
    const drawn = w.drawn(&quads);
    try testing.expectEqual(@as(usize, 2), drawn.len);
    try testing.expectEqual(t_a.xdg.surface.?.texture().?.handle, drawn[0].texture.handle);
    try testing.expectEqual(@as(i32, 32 + 352 + 32), drawn[0].x);
    try testing.expectEqual(@as(i32, w.server.work_area.y + 32 + (496 - 246) / 2), drawn[0].y);
    try testing.expectEqual(@as(u32, 352), drawn[0].width);
    try testing.expectEqual(@as(u32, 246), drawn[0].height);
    try testing.expectEqual(@as(i32, 32), drawn[1].x);
    try testing.expectEqual(@as(u32, 352), drawn[1].width);
    // Neither has the pointer or keyboard; each is still the size it was.
    try testing.expect(w.server.keyboard_focus == null);
    w.server.pointerMotion(0, 500, 300);
    try testing.expect(w.server.pointer_focus == null);
    try testing.expect(w.server.scanoutBuffer(t_a) == null);
    try testing.expectEqual([2]u32{ 800, 560 }, w.server.configuredSize(t_a));
    try testing.expectEqual([2]u32{ 400, 280 }, w.server.configuredSize(t_b));
    try testing.expectEqual(@as(?*server_mod.Toplevel, t_a), w.server.overviewAt(500, 300));
    try testing.expectEqual(@as(?*server_mod.Toplevel, t_b), w.server.overviewAt(100, 300));
    try testing.expectEqual(@as(?*server_mod.Toplevel, null), w.server.overviewAt(5, 5));

    // Picking A: it is on top, with the keyboard, and the overview ends.
    // On their way back, A (now on top) is drawn last, from where it was
    // in the overview: it does not change places.
    w.server.overviewPick(t_a);
    try w.pump();
    try testing.expect(!w.server.overview);
    try testing.expectEqual(t_a, w.server.topWindow().?);
    try testing.expectEqual(win_a.surface.id, w.server.keyboard_focus.?.id);
    try testing.expect(w.server.animateOverview(5000));
    var back = w.drawn(&quads);
    try testing.expectEqual(t_a.xdg.surface.?.texture().?.handle, back[back.len - 1].texture.handle);
    try testing.expectEqual(@as(i32, 32 + 352 + 32), back[back.len - 1].x);
    try testing.expect(!w.server.animateOverview(5000 + Server.overview_ns));
    back = w.drawn(&quads);
    try testing.expectEqual(@as(i32, 0), back[back.len - 1].x);
    try testing.expectEqual(@as(u32, 800), back[back.len - 1].width);

    // Escape ends it too.
    w.server.setOverview(true);
    w.server.keyboardKey(0, server_mod.key_esc, true);
    try testing.expect(!w.server.overview);
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

/// What a client heard on its data device: offers, their MIME types and
/// actions, drag enter/motion/leave/drop, and the selection.
const DataHeard = struct {
    peer: *Peer,
    offer: ?u32 = null,
    selection: ?u32 = null,
    selections: u32 = 0,
    mime: [64]u8 = undefined,
    mime_len: usize = 0,
    source_actions: u32 = 0,
    action: u32 = 0,
    enter_serial: u32 = 0,
    enter_surface: u32 = 0,
    enter_x: f64 = 0,
    enter_y: f64 = 0,
    enter_offer: ?u32 = null,
    enters: u32 = 0,
    leaves: u32 = 0,
    motions: u32 = 0,
    motion_x: f64 = 0,
    motion_y: f64 = 0,
    drops: u32 = 0,

    fn deviceEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const h: *DataHeard = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_data_device.event.data_offer => {
                const id = r.uint() catch return;
                h.offer = id;
                d.setListener(id, .{ .ptr = h, .handler = offerEvent }) catch {};
            },
            p.wl_data_device.event.enter => {
                h.enter_serial = r.uint() catch return;
                h.enter_surface = r.uint() catch return;
                h.enter_x = r.fixed() catch return;
                h.enter_y = r.fixed() catch return;
                const id = r.uint() catch return;
                h.enter_offer = if (id == 0) null else id;
                h.enters += 1;
            },
            p.wl_data_device.event.leave => h.leaves += 1,
            p.wl_data_device.event.motion => {
                _ = r.uint() catch return;
                h.motion_x = r.fixed() catch return;
                h.motion_y = r.fixed() catch return;
                h.motions += 1;
            },
            p.wl_data_device.event.drop => h.drops += 1,
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
        switch (opcode) {
            p.wl_data_offer.event.offer => {
                const mime = (r.string() catch return) orelse return;
                h.mime_len = @min(mime.len, h.mime.len);
                @memcpy(h.mime[0..h.mime_len], mime[0..h.mime_len]);
            },
            p.wl_data_offer.event.source_actions => h.source_actions = r.uint() catch return,
            p.wl_data_offer.event.action => h.action = r.uint() catch return,
            else => {},
        }
    }
};

/// What a client heard on its data source: target MIME type, negotiated
/// action, what to send and where, drop performed/finished, and cancelled.
const SourceHeard = struct {
    send_fd: ?linux.fd_t = null,
    cancelled: bool = false,
    drop_performed: bool = false,
    finished: bool = false,
    action: u32 = 0,
    targets: u32 = 0,
    target_mime: [64]u8 = undefined,
    target_mime_len: ?usize = null,

    fn event(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const h: *SourceHeard = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_data_source.event.target => {
                h.targets += 1;
                if (r.string() catch return) |mime| {
                    const n = @min(mime.len, h.target_mime.len);
                    @memcpy(h.target_mime[0..n], mime[0..n]);
                    h.target_mime_len = n;
                } else h.target_mime_len = null;
            },
            p.wl_data_source.event.send => {
                _ = r.string() catch return;
                h.send_fd = r.fd() catch return;
            },
            p.wl_data_source.event.cancelled => h.cancelled = true,
            p.wl_data_source.event.dnd_drop_performed => h.drop_performed = true,
            p.wl_data_source.event.dnd_finished => h.finished = true,
            p.wl_data_source.event.action => h.action = r.uint() catch return,
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
    try win.redraw(a, shm, 400, 280);
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

test "a window dragged to the left or right edge fills that half, to the top fills the work area, and dragged away is restored" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    const pointer = try a.d.newObject(null);
    var m = try seat.request(p.wl_seat.request.get_pointer);
    m.uint(pointer.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);
    m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try win.redraw(a, shm, 400, 280);
    const t = w.server.topWindow().?;
    const wa = w.server.work_area;
    var quads: [16]Server.Quad = undefined;

    const Drag = struct {
        /// Presses at (`x`, `y`), asks to move the window from there, and
        /// moves the pointer to (`to_x`, `to_y`).
        fn to(ww: *World, win_: *Window, seat_: client.Proxy, x: f64, y: f64, to_x: f64, to_y: f64) !void {
            ww.server.pointerMotion(1, x, y);
            ww.server.pointerFrame();
            ww.server.pointerButton(2, p.input.btn_left, true);
            ww.server.pointerFrame();
            try ww.pump();
            var mm = try win_.toplevel.request(p.xdg_toplevel.request.move);
            mm.uint(seat_.id).uint(ww.server.press_serial).end();
            try ww.pump();
            ww.server.pointerMotion(3, to_x, to_y);
            try ww.pump();
        }

        fn release(ww: *World) !void {
            ww.server.pointerButton(4, p.input.btn_left, false);
            ww.server.pointerFrame();
            try ww.pump();
        }
    };

    // Dragged to the left edge: the left half is shown, shaded, under it,
    // and let go, it fills that half, told it is tiled.
    try Drag.to(&w, &win, seat, 250, 200, 1, 300);
    try testing.expectEqual(@as(?server_mod.Snap, .left), w.server.snap);
    const drawn = w.drawn(&quads);
    try testing.expect(drawn[0].preview);
    try testing.expectEqual(wa.x + 8, drawn[0].x);
    try testing.expectEqual(wa.width / 2 - 16, drawn[0].width);
    try testing.expect(!drawn[1].preview);
    try Drag.release(&w);
    try testing.expectEqual(@as(?server_mod.Tile, .left), t.tiled);
    try testing.expectEqual(@as(?server_mod.Snap, null), w.server.snap);
    try testing.expectEqual([2]u32{ wa.width / 2, wa.height }, w.server.configuredSize(t));
    try win.redraw(a, shm, @intCast(wa.width / 2), @intCast(wa.height));
    try testing.expectEqual(server_mod.Rect{ .x = wa.x, .y = wa.y, .width = wa.width / 2, .height = wa.height }, w.server.windowRect(t));
    // It is not resized from its edges.
    w.server.pointerMotion(1, 200, 300);
    w.server.pointerButton(2, p.input.btn_left, true);
    try w.pump();
    m = try win.toplevel.request(p.xdg_toplevel.request.resize);
    m.uint(seat.id).uint(w.server.press_serial).uint(8).end();
    try w.pump();
    try testing.expect(w.server.grab == null);
    try Drag.release(&w);

    // Pressed and moved a little, it stays; dragged away, it is restored,
    // under the pointer, and not let go at an edge, stays so.
    try Drag.to(&w, &win, seat, 100, 300, 105, 302);
    try testing.expectEqual(@as(?server_mod.Tile, .left), t.tiled);
    w.server.pointerMotion(5, 300, 300);
    try w.pump();
    try testing.expectEqual(@as(?server_mod.Tile, null), t.tiled);
    try testing.expectEqual([2]u32{ 400, 280 }, w.server.configuredSize(t));
    try Drag.release(&w);
    try testing.expect(!t.maximized and t.tiled == null);
    try win.redraw(a, shm, 400, 280);

    // Dragged to the top edge, it fills the work area.
    const r = w.server.windowRect(t);
    try Drag.to(&w, &win, seat, @floatFromInt(r.x + 50), @floatFromInt(r.y + 10), 400, @floatFromInt(wa.y));
    try testing.expectEqual(@as(?server_mod.Snap, .maximize), w.server.snap);
    try Drag.release(&w);
    try testing.expect(t.maximized);
    try win.redraw(a, shm, @intCast(wa.width), @intCast(wa.height));

    // From there, dragged to the right edge: restored on the way, then
    // the right half.
    try Drag.to(&w, &win, seat, 400, @floatFromInt(wa.y + 10), @floatFromInt(wa.width - 1), 300);
    try testing.expect(!t.maximized);
    try testing.expectEqual(@as(?server_mod.Snap, .right), w.server.snap);
    try Drag.release(&w);
    try testing.expectEqual(@as(?server_mod.Tile, .right), t.tiled);
    try win.redraw(a, shm, @intCast(wa.width - wa.width / 2), @intCast(wa.height));
    try testing.expectEqual(wa.x + @as(i32, @intCast(wa.width / 2)), w.server.windowRect(t).x);
}

test "pressing in a window keeps the pointer when dragging and releasing outside it, or moving quickly" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    var pointer_heard: Heard = .{};
    const pointer = try a.d.newObject(pointer_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_pointer);
    m.uint(pointer.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    // Restore to 400x280 at 200,180.
    m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try win.redraw(a, shm, 400, 280);

    // Press inside the window (at 250,200), drag outside the window and
    // below the work area (into the dock area at y=580), and release there.
    w.server.pointerMotion(1, 250, 200);
    w.server.pointerFrame();
    w.server.pointerButton(2, p.input.btn_left, true);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(w.server.pointer_focus.?.id, win.surface.id);

    const motions_before = pointer_heard.counts[p.wl_pointer.event.motion];
    const leaves_before = pointer_heard.counts[p.wl_pointer.event.leave];
    w.server.pointerMotion(3, 50, 580);
    w.server.pointerFrame();
    try w.pump();
    // Still focused on the window while the button is held down.
    try testing.expectEqual(w.server.pointer_focus.?.id, win.surface.id);
    try testing.expectEqual(motions_before + 1, pointer_heard.counts[p.wl_pointer.event.motion]);
    try testing.expectEqual(leaves_before, pointer_heard.counts[p.wl_pointer.event.leave]);

    // Releasing outside delivers the button release and then leaves the window.
    w.server.pointerButton(4, p.input.btn_left, false);
    w.server.pointerFrame();
    try w.pump();
    try testing.expect(w.server.pointer_focus == null);
    try testing.expectEqual(@as(u32, 0), w.server.buttons_down);
    try testing.expectEqual(@as(u32, 2), pointer_heard.counts[p.wl_pointer.event.button]);
    try testing.expectEqual(leaves_before + 1, pointer_heard.counts[p.wl_pointer.event.leave]);

    // An unmatched button release (e.g. a click that started on the dock) is ignored.
    w.server.pointerButton(5, p.input.btn_left, false);
    try testing.expectEqual(@as(u32, 0), w.server.buttons_down);

    // Pressing on the title bar and moving off the window before xdg_toplevel.move
    // arrives still starts the move anchored at the press position, and releasing
    // ends the grab.
    w.server.pointerMotion(6, 250, 190);
    w.server.pointerFrame();
    w.server.pointerButton(7, p.input.btn_left, true);
    w.server.pointerFrame();
    try w.pump();
    const press_serial = w.server.press_serial;
    // Pointer moves quickly above the window before the client's move request arrives.
    w.server.pointerMotion(8, 300, 100);
    w.server.pointerFrame();
    m = try win.toplevel.request(p.xdg_toplevel.request.move);
    m.uint(seat.id).uint(press_serial).end();
    try w.pump();
    try testing.expect(w.server.grab != null);
    const t = w.server.topWindow().?;
    // dx was 250 - 200 = 50, so at pointer_x = 300 the window moved to x = 250.
    try testing.expectEqual(@as(i32, 250), t.x);
    w.server.pointerButton(9, p.input.btn_left, false);
    w.server.pointerFrame();
    try w.pump();
    try testing.expect(w.server.grab == null);
}

test "dragging from one client and dropping on another negotiates actions, draws the icon, transfers data, and finishes" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const mime = "text/uri-list";
    const A = p.wl_data_device_manager.dnd_action;
    const Side = struct {
        peer: *Peer,
        compositor: client.Proxy,
        shm: client.Proxy,
        seat: client.Proxy,
        pointer: client.Proxy,
        pointer_heard: Heard = .{},
        manager: client.Proxy,
        device: client.Proxy,
        heard: DataHeard,
        win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined },

        fn setUp(side: *@This(), world: *World) !void {
            const peer = try world.connect();
            side.* = .{
                .peer = peer,
                .compositor = undefined,
                .shm = undefined,
                .seat = undefined,
                .pointer = undefined,
                .manager = undefined,
                .device = undefined,
                .heard = .{ .peer = peer },
            };
            side.compositor = try peer.bind(p.wl_compositor.name, 4, null);
            const wm_base = try peer.bind(p.xdg_wm_base.name, 6, null);
            side.shm = try peer.bind(p.wl_shm.name, 1, null);
            side.seat = try peer.bind(p.wl_seat.name, 5, null);
            side.pointer = try peer.d.newObject(side.pointer_heard.listener());
            var m = try side.seat.request(p.wl_seat.request.get_pointer);
            m.uint(side.pointer.id).end();
            side.manager = try peer.bind(p.wl_data_device_manager.name, 3, null);
            side.device = try peer.d.newObject(.{ .ptr = &side.heard, .handler = DataHeard.deviceEvent });
            m = try side.manager.request(p.wl_data_device_manager.request.get_data_device);
            m.uint(side.device.id).uint(side.seat.id).end();
            try side.win.open(peer, side.compositor, wm_base, side.shm, null);
        }
    };

    var a: Side = undefined;
    try a.setUp(&w);
    var b: Side = undefined;
    try b.setUp(&w);
    // Restore A and B to 400x280 at 200,180, and move B to 350,220 so both
    // windows are visible side by side.
    var m = try a.win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    m = try b.win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try a.win.ack(a.peer);
    try b.win.ack(b.peer);
    try a.peer.show(a.win.surface, try a.peer.shmBuffer(a.shm, 400, 280));
    try b.peer.show(b.win.surface, try b.peer.shmBuffer(b.shm, 400, 280));
    try w.pump();
    w.server.pointerMotion(1, 250, 200);
    w.server.pointerFrame();
    w.server.pointerButton(2, p.input.btn_left, true);
    w.server.pointerFrame();
    try w.pump();
    m = try b.win.toplevel.request(p.xdg_toplevel.request.move);
    m.uint(b.seat.id).uint(w.server.press_serial).end();
    try w.pump();
    w.server.pointerMotion(3, 400, 240);
    w.server.pointerButton(4, p.input.btn_left, false);
    w.server.pointerFrame();
    try w.pump();

    // Press in A at 250,250 and start a drag with an icon surface.
    w.server.pointerMotion(8, 250, 250);
    w.server.pointerFrame();
    w.server.pointerButton(9, p.input.btn_left, true);
    w.server.pointerFrame();
    try w.pump();
    const drag_serial = w.server.press_serial;

    var src_heard: SourceHeard = .{};
    const source = try a.peer.d.newObject(.{ .ptr = &src_heard, .handler = SourceHeard.event });
    m = try a.manager.request(p.wl_data_device_manager.request.create_data_source);
    m.uint(source.id).end();
    m = try source.request(p.wl_data_source.request.offer);
    m.string(mime).end();
    m = try source.request(p.wl_data_source.request.set_actions);
    m.uint(A.copy | A.move).end();

    const icon = try a.peer.surface(a.compositor, null);
    try a.peer.show(icon, try a.peer.shmBuffer(a.shm, 24, 24));
    const leaves_before = a.pointer_heard.counts[p.wl_pointer.event.leave];
    m = try a.device.request(p.wl_data_device.request.start_drag);
    m.uint(source.id).uint(a.win.surface.id).uint(icon.id).uint(drag_serial).end();
    try w.pump();

    // Starting the drag takes the pointer away from A (wl_pointer.leave),
    // enters A's surface on its data device, and draws the icon on top.
    try testing.expectEqual(leaves_before + 1, a.pointer_heard.counts[p.wl_pointer.event.leave]);
    try testing.expectEqual(@as(u32, 1), a.heard.enters);
    try testing.expectEqual(a.win.surface.id, a.heard.enter_surface);
    var quads: [16]Server.Quad = undefined;
    const drawn = w.drawn(&quads);
    try testing.expectEqual(@as(usize, 3), drawn.len);
    try testing.expectEqual(@as(i32, 250), drawn[2].x);
    try testing.expectEqual(@as(i32, 250), drawn[2].y);

    // Move over B's window at 650,300 (which is at 350,220, so local 300,80).
    w.server.pointerMotion(10, 650, 300);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), a.heard.leaves);
    try testing.expectEqual(@as(u32, 1), b.heard.enters);
    try testing.expectEqual(b.win.surface.id, b.heard.enter_surface);
    try testing.expectEqual(@as(f64, 300), b.heard.enter_x);
    try testing.expectEqual(@as(f64, 80), b.heard.enter_y);
    try testing.expectEqual(A.copy | A.move, b.heard.source_actions);
    try testing.expectEqualStrings(mime, b.heard.mime[0..b.heard.mime_len]);
    const b_offer_id = b.heard.enter_offer orelse return error.TestUnexpectedResult;
    const b_offer: client.Proxy = .{ .display = b.peer.d, .id = b_offer_id };

    // B accepts the MIME type and prefers `move`: both sides learn the
    // negotiated action (`move`), and A learns the accepted target MIME.
    m = try b_offer.request(p.wl_data_offer.request.accept);
    m.uint(b.heard.enter_serial).string(mime).end();
    m = try b_offer.request(p.wl_data_offer.request.set_actions);
    m.uint(A.copy | A.move).uint(A.move).end();
    try w.pump();
    try testing.expectEqual(A.move, b.heard.action);
    try testing.expectEqual(A.move, src_heard.action);
    try testing.expectEqualStrings(mime, src_heard.target_mime[0..src_heard.target_mime_len.?]);

    // Moving further inside B sends wl_data_device.motion and moves the icon.
    w.server.pointerMotion(11, 660, 315);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), b.heard.motions);
    try testing.expectEqual(@as(f64, 310), b.heard.motion_x);
    try testing.expectEqual(@as(f64, 95), b.heard.motion_y);
    try testing.expectEqual(@as(i32, 660), w.drawn(&quads)[2].x);
    try testing.expectEqual(@as(i32, 315), w.drawn(&quads)[2].y);

    // Moving outside all windows (e.g. x=100, y=100) leaves B and resets
    // A's target and action to none.
    w.server.pointerMotion(12, 100, 100);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), b.heard.leaves);
    try testing.expect(src_heard.target_mime_len == null);
    try testing.expectEqual(A.none, src_heard.action);

    // Re-enter B, accept and negotiate `copy`, then release the button to drop.
    w.server.pointerMotion(13, 650, 300);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 2), b.heard.enters);
    const offer2: client.Proxy = .{ .display = b.peer.d, .id = b.heard.enter_offer.? };
    m = try offer2.request(p.wl_data_offer.request.accept);
    m.uint(b.heard.enter_serial).string(mime).end();
    m = try offer2.request(p.wl_data_offer.request.set_actions);
    m.uint(A.copy).uint(A.copy).end();
    try w.pump();
    try testing.expectEqual(A.copy, b.heard.action);
    try testing.expectEqual(A.copy, src_heard.action);

    w.server.pointerButton(14, p.input.btn_left, false);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), b.heard.drops);
    try testing.expect(src_heard.drop_performed);
    try testing.expect(!src_heard.cancelled);
    // The drag icon is gone once the drag ends, and the pointer enters B.
    try testing.expectEqual(@as(usize, 2), w.drawn(&quads).len);
    try testing.expectEqual(w.server.pointer_focus.?.id, b.win.surface.id);

    // B receives the data from the dropped offer, then finishes and destroys it.
    var pipe: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    m = try offer2.request(p.wl_data_offer.request.receive);
    m.string(mime).fd(pipe[1]).end();
    try w.pump();
    const fd = src_heard.send_fd orelse return error.TestUnexpectedResult;
    _ = linux.write(fd, "file:///a\r\n", 11);
    _ = linux.close(fd);
    var got: [32]u8 = undefined;
    const n = linux.read(pipe[0], &got, got.len);
    _ = linux.close(pipe[0]);
    try testing.expectEqualStrings("file:///a\r\n", got[0..n]);

    m = try offer2.request(p.wl_data_offer.request.finish);
    m.end();
    m = try offer2.request(p.wl_data_offer.request.destroy);
    m.end();
    try w.pump();
    try testing.expect(src_heard.finished);
}

test "releasing an unaccepted drag cancels the source, and a touch can drive a drag" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const A = p.wl_data_device_manager.dnd_action;
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    var touch_heard: Heard = .{};
    const touch = try a.d.newObject(touch_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_touch);
    m.uint(touch.id).end();
    const manager = try a.bind(p.wl_data_device_manager.name, 3, null);
    var data_heard: DataHeard = .{ .peer = a };
    const device = try a.d.newObject(.{ .ptr = &data_heard, .handler = DataHeard.deviceEvent });
    m = try manager.request(p.wl_data_device_manager.request.get_data_device);
    m.uint(device.id).uint(seat.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    // Touch down and start a drag, then lift the finger without accepting
    // the offer: the target gets leave and the source gets cancelled.
    w.server.touchDown(1, 0, 100, 140);
    try w.pump();
    const serial: u32 = @intCast(touch_heard.args[0]);
    var src_heard: SourceHeard = .{};
    const source = try a.d.newObject(.{ .ptr = &src_heard, .handler = SourceHeard.event });
    m = try manager.request(p.wl_data_device_manager.request.create_data_source);
    m.uint(source.id).end();
    m = try source.request(p.wl_data_source.request.offer);
    m.string("text/plain").end();
    m = try source.request(p.wl_data_source.request.set_actions);
    m.uint(A.copy).end();
    m = try device.request(p.wl_data_device.request.start_drag);
    m.uint(source.id).uint(win.surface.id).uint(0).uint(serial).end();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), touch_heard.counts[p.wl_touch.event.cancel]);
    try testing.expectEqual(@as(u32, 1), data_heard.enters);

    w.server.touchMotion(2, 0, 150, 200);
    try w.pump();
    try testing.expectEqual(@as(u32, 1), data_heard.motions);

    w.server.touchUp(3, 0);
    try w.pump();
    try testing.expectEqual(@as(u32, 0), data_heard.drops);
    try testing.expectEqual(@as(u32, 1), data_heard.leaves);
    try testing.expect(src_heard.cancelled);

    // A self-drag (source = 0) enters, moves and drops on the client's own
    // surface without an offer.
    w.server.touchDown(4, 1, 200, 240);
    try w.pump();
    const serial2: u32 = @intCast(touch_heard.args[0]);
    m = try device.request(p.wl_data_device.request.start_drag);
    m.uint(0).uint(win.surface.id).uint(0).uint(serial2).end();
    try w.pump();
    try testing.expectEqual(@as(u32, 2), data_heard.enters);
    try testing.expect(data_heard.enter_offer == null);
    w.server.touchUp(5, 1);
    try w.pump();
    try testing.expectEqual(@as(u32, 1), data_heard.drops);
    try testing.expectEqual(@as(u32, 2), data_heard.leaves);
}

test "client cursors from wl_pointer.set_cursor and cursor shapes from wp_cursor_shape_device_v1" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    var pointer_heard: Heard = .{};
    const pointer = try a.d.newObject(pointer_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_pointer);
    m.uint(pointer.id).end();
    const shape_mgr = try a.bind(p.wp_cursor_shape_manager_v1.name, 1, null);
    const shape_dev = try a.d.newObject(null);
    m = try shape_mgr.request(p.wp_cursor_shape_manager_v1.request.get_pointer);
    m.uint(shape_dev.id).uint(pointer.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    // Move pointer into the window to acquire pointer focus and an enter serial.
    w.server.pointerMotion(1, 100, 100);
    try w.pump();
    try testing.expectEqual(w.server.pointer_focus.?.id, win.surface.id);
    const enter_serial: u32 = @intCast(pointer_heard.args[0]);

    // Setting cursor shapes updates the server's chosen cursor.
    m = try shape_dev.request(p.wp_cursor_shape_device_v1.request.set_shape);
    m.uint(enter_serial).uint(p.wp_cursor_shape_device_v1.shape.pointer).end();
    try w.pump();
    try testing.expectEqual(.pointer, w.server.cursor());

    m = try shape_dev.request(p.wp_cursor_shape_device_v1.request.set_shape);
    m.uint(enter_serial).uint(p.wp_cursor_shape_device_v1.shape.text).end();
    try w.pump();
    try testing.expectEqual(.text, w.server.cursor());

    m = try shape_dev.request(p.wp_cursor_shape_device_v1.request.set_shape);
    m.uint(enter_serial).uint(p.wp_cursor_shape_device_v1.shape.not_allowed).end();
    try w.pump();
    try testing.expectEqual(.not_allowed, w.server.cursor());

    // Setting a client-drawn cursor surface hides the hardware cursor plane and
    // draws the cursor surface at (pointer - hotspot) on top of the scene.
    const cur_surf = try a.surface(compositor, null);
    try a.show(cur_surf, try a.shmBuffer(shm, 16, 16));
    m = try pointer.request(p.wl_pointer.request.set_cursor);
    m.uint(enter_serial).uint(cur_surf.id).int(4).int(6).end();
    try w.pump();
    try testing.expectEqual(.hidden, w.server.cursor());
    var quads: [16]Server.Quad = undefined;
    const drawn = w.drawn(&quads);
    try testing.expectEqual(@as(usize, 2), drawn.len);
    try testing.expectEqual(@as(i32, 96), drawn[1].x);
    try testing.expectEqual(@as(i32, 94), drawn[1].y);

    // Passing surface = 0 to set_cursor hides the cursor without drawing a quad.
    m = try pointer.request(p.wl_pointer.request.set_cursor);
    m.uint(enter_serial).uint(0).int(0).int(0).end();
    try w.pump();
    try testing.expectEqual(.hidden, w.server.cursor());
    try testing.expectEqual(@as(usize, 1), w.drawn(&quads).len);
}

test "input regions with add and subtract pass pointer events through to the window behind" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const b = try w.connect();
    const a_comp = try a.bind(p.wl_compositor.name, 4, null);
    const a_wm = try a.bind(p.xdg_wm_base.name, 6, null);
    const a_shm = try a.bind(p.wl_shm.name, 1, null);
    const b_comp = try b.bind(p.wl_compositor.name, 4, null);
    const b_wm = try b.bind(p.xdg_wm_base.name, 6, null);
    const b_shm = try b.bind(p.wl_shm.name, 1, null);

    var a_win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try a_win.open(a, a_comp, a_wm, a_shm, null);
    var b_win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try b_win.open(b, b_comp, b_wm, b_shm, null);

    // B is on top (at 0,40, 800x560). Give B an input region covering 0..400x0..560
    // minus a hole at 100..200x100..200, and an opaque region.
    const reg = try b.d.newObject(null);
    var m = try b_comp.request(p.wl_compositor.request.create_region);
    m.uint(reg.id).end();
    m = try reg.request(p.wl_region.request.add);
    m.int(0).int(0).int(400).int(560).end();
    m = try reg.request(p.wl_region.request.subtract);
    m.int(100).int(100).int(100).int(100).end();
    m = try b_win.surface.request(p.wl_surface.request.set_input_region);
    m.uint(reg.id).end();
    m = try b_win.surface.request(p.wl_surface.request.set_opaque_region);
    m.uint(reg.id).end();
    m = try reg.request(p.wl_region.request.destroy);
    m.end();
    m = try b_win.surface.request(p.wl_surface.request.commit);
    m.end();
    try w.pump();

    // At 50,100 on screen (50,60 in B): inside B's input region -> hits B.
    w.server.pointerMotion(1, 50, 100);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(w.server.pointer_focus.?.client, b.c);

    // At 150,190 on screen (150,150 in B): inside the subtracted hole -> passes through to A!
    w.server.pointerMotion(2, 150, 190);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(w.server.pointer_focus.?.client, a.c);

    // At 500,200 on screen (500,160 in B): outside B's 0..400 region -> passes through to A.
    w.server.pointerMotion(3, 500, 200);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(w.server.pointer_focus.?.client, a.c);
}

test "pointer confinement clamps pointer motion to the region, and locked pointer hint warps on unlock" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    const pointer = try a.d.newObject(null);
    var m = try seat.request(p.wl_seat.request.get_pointer);
    m.uint(pointer.id).end();
    const constraints = try a.bind(p.zwp_pointer_constraints_v1.name, 1, null);
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    // Create a confinement region [50..150, 60..160] in surface coords (screen [50..150, 100..200]).
    const reg = try a.d.newObject(null);
    m = try compositor.request(p.wl_compositor.request.create_region);
    m.uint(reg.id).end();
    m = try reg.request(p.wl_region.request.add);
    m.int(50).int(60).int(100).int(100).end();

    var confined_heard: Heard = .{};
    const confined = try a.d.newObject(confined_heard.listener());
    m = try constraints.request(p.zwp_pointer_constraints_v1.request.confine_pointer);
    m.uint(confined.id).uint(win.surface.id).uint(pointer.id).uint(reg.id).uint(p.zwp_pointer_constraints_v1.lifetime.oneshot).end();
    try w.pump();
    // Pointer starts at 400,300 (outside the confinement region), so not confined yet.
    try testing.expectEqual(@as(u32, 0), confined_heard.counts[p.zwp_confined_pointer_v1.event.confined]);

    // Move pointer into the region (screen 100,150 -> surface 100,110): activates confinement.
    w.server.pointerMotion(1, 100, 150);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), confined_heard.counts[p.zwp_confined_pointer_v1.event.confined]);

    // Clamping keeps the pointer inside [50..149, 100..199] on screen.
    const clamped = w.server.clampPointer(300, 400);
    try testing.expectEqual(@as(f64, 149), clamped[0]);
    try testing.expectEqual(@as(f64, 199), clamped[1]);

    // Breaking the constraint sends unconfined and removes oneshot constraint.
    w.server.breakLock();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), confined_heard.counts[p.zwp_confined_pointer_v1.event.unconfined]);
    m = try confined.request(p.zwp_confined_pointer_v1.request.destroy);
    m.end();

    // Lock the pointer and set a cursor position hint (220, 180 in surface -> 220, 220 on screen).
    var locked_heard: Heard = .{};
    const locked = try a.d.newObject(locked_heard.listener());
    m = try constraints.request(p.zwp_pointer_constraints_v1.request.lock_pointer);
    m.uint(locked.id).uint(win.surface.id).uint(pointer.id).uint(0).uint(p.zwp_pointer_constraints_v1.lifetime.persistent).end();
    m = try locked.request(p.zwp_locked_pointer_v1.request.set_cursor_position_hint);
    m.fixed(220).fixed(180).end();
    m = try win.surface.request(p.wl_surface.request.commit);
    m.end();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), locked_heard.counts[p.zwp_locked_pointer_v1.event.locked]);

    // Destroying the locked pointer warps the server pointer to the hint position.
    m = try locked.request(p.zwp_locked_pointer_v1.request.destroy);
    m.end();
    try w.pump();
    try testing.expectEqual(@as(f64, 220), w.server.pointer_x);
    try testing.expectEqual(@as(f64, 220), w.server.pointer_y);
}

test "synchronized subsurfaces hold their committed buffer until the parent commits or set_desync is called" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const subcompositor = try a.bind(p.wl_subcompositor.name, 1, null);
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    const sub_surf = try a.surface(compositor, null);
    const role = try a.d.newObject(null);
    var m = try subcompositor.request(p.wl_subcompositor.request.get_subsurface);
    m.uint(role.id).uint(sub_surf.id).uint(win.surface.id).end();
    m = try role.request(p.wl_subsurface.request.set_sync);
    m.end();
    try a.show(sub_surf, try a.shmBuffer(shm, 40, 30));
    try w.pump();

    // While synchronized, the subsurface's committed buffer is cached and not yet drawn.
    var quads: [16]Server.Quad = undefined;
    try testing.expectEqual(@as(usize, 1), w.drawn(&quads).len);

    // Committing the parent applies the cached subsurface state.
    m = try win.surface.request(p.wl_surface.request.commit);
    m.end();
    try w.pump();
    try testing.expectEqual(@as(usize, 2), w.drawn(&quads).len);

    // Detaching the subsurface buffer while synchronized waits until set_desync.
    m = try sub_surf.request(p.wl_surface.request.attach);
    m.uint(0).int(0).int(0).end();
    m = try sub_surf.request(p.wl_surface.request.commit);
    m.end();
    try w.pump();
    try testing.expectEqual(@as(usize, 2), w.drawn(&quads).len);

    m = try role.request(p.wl_subsurface.request.set_desync);
    m.end();
    try w.pump();
    try testing.expectEqual(@as(usize, 1), w.drawn(&quads).len);
}

test "xdg_surface window geometry, xdg_toplevel parent/app_id/close, and xdg_wm_base ping/pong" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    var wm_heard: Heard = .{};
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, wm_heard.listener());
    const shm = try a.bind(p.wl_shm.name, 1, null);
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    var top_heard: Heard = .{};
    try a.d.setListener(win.toplevel.id, top_heard.listener());

    // Restore and set a 10,15 window geometry offset (e.g. client-drawn shadow margin).
    var m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    m = try win.xdg.request(p.xdg_surface.request.set_window_geometry);
    m.int(10).int(15).int(400).int(280).end();
    m = try win.toplevel.request(p.xdg_toplevel.request.set_app_id);
    m.string("io.dazzle.test").end();
    m = try win.toplevel.request(p.xdg_toplevel.request.set_parent);
    m.uint(0).end();
    m = try win.toplevel.request(p.xdg_toplevel.request.show_window_menu);
    m.uint(0).uint(0).int(20).int(20).end();
    m = try win.toplevel.request(p.xdg_toplevel.request.set_minimized);
    m.end();
    try win.ack(a);
    try a.show(win.surface, try a.shmBuffer(shm, 420, 310));
    try w.pump();

    const t = w.server.topWindow().?;
    try testing.expectEqualStrings("io.dazzle.test", t.appId());
    // Window is at 200,180; with geometry offset 10,15 its surface draws at 190,165.
    var quads: [16]Server.Quad = undefined;
    const drawn = w.drawn(&quads);
    try testing.expectEqual(@as(i32, 190), drawn[0].x);
    try testing.expectEqual(@as(i32, 165), drawn[0].y);

    // Server ping is delivered on xdg_wm_base and cleared by client pong.
    _ = w.server.ping(a.c);
    try w.pump();
    try testing.expect(a.c.ping_serial != 0);
    try testing.expectEqual(p.xdg_wm_base.event.ping, wm_heard.last_opcode);
    m = try wm_base.request(p.xdg_wm_base.request.pong);
    m.uint(@intCast(wm_heard.args[0])).end();
    try w.pump();
    try testing.expectEqual(@as(u32, 0), a.c.ping_serial);

    // Closing the toplevel sends xdg_toplevel.close.
    w.server.closeToplevel(t);
    try w.pump();
    try testing.expectEqual(@as(u32, 1), top_heard.counts[p.xdg_toplevel.event.close]);
}

test "pointer axis v5 sends axis_source, axis_discrete, and axis_stop" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    var pointer_heard: Heard = .{};
    const pointer = try a.d.newObject(pointer_heard.listener());
    var m = try seat.request(p.wl_seat.request.get_pointer);
    m.uint(pointer.id).end();
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    w.server.pointerMotion(1, 100, 100);
    w.server.pointerFrame();
    w.server.pointerAxis(2, p.wl_pointer.axis.vertical_scroll, 15.0);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), pointer_heard.counts[p.wl_pointer.event.axis_source]);
    try testing.expectEqual(@as(u32, 1), pointer_heard.counts[p.wl_pointer.event.axis_discrete]);
    try testing.expectEqual(@as(u32, 1), pointer_heard.counts[p.wl_pointer.event.axis]);

    // Value 0 sends axis_stop.
    w.server.pointerAxis(3, p.wl_pointer.axis.vertical_scroll, 0);
    w.server.pointerFrame();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), pointer_heard.counts[p.wl_pointer.event.axis_stop]);
}

test "surface buffer scale and transform determine logical size, and unmapping sends wl_surface.leave" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    _ = try a.bind(p.wl_output.name, 4, null);
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    var surf_heard: Heard = .{};
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, surf_heard.listener());
    try testing.expectEqual(@as(u32, 1), surf_heard.counts[p.wl_surface.event.enter]);

    // Restore and attach a 400x600 buffer with scale 2 and 90-degree transform:
    // logical size becomes (600 / 2) x (400 / 2) = 300 x 200.
    var m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    m = try win.surface.request(p.wl_surface.request.set_buffer_scale);
    m.int(2).end();
    m = try win.surface.request(p.wl_surface.request.set_buffer_transform);
    m.int(p.wl_output.transform.@"90").end();
    try win.ack(a);
    try a.show(win.surface, try a.shmBuffer(shm, 400, 600));
    try w.pump();

    var quads: [16]Server.Quad = undefined;
    const drawn = w.drawn(&quads);
    try testing.expectEqual(@as(usize, 1), drawn.len);
    try testing.expectEqual(@as(u32, 300), drawn[0].width);
    try testing.expectEqual(@as(u32, 200), drawn[0].height);
    try testing.expectEqual(@as(u3, p.wl_output.transform.@"90"), drawn[0].transform);
    // Scaled/transformed buffers use the compositor rather than direct scanout.
    try testing.expect(w.server.scanoutBuffer(w.server.topWindow().?) == null);

    // Unmapping the surface sends wl_surface.leave for the output.
    m = try win.surface.request(p.wl_surface.request.attach);
    m.uint(0).int(0).int(0).end();
    m = try win.surface.request(p.wl_surface.request.commit);
    m.end();
    try w.pump();
    try testing.expectEqual(@as(u32, 1), surf_heard.counts[p.wl_surface.event.leave]);
}

test "wp_presentation reports clock_id, sync_output, presented timestamps, and discarded frames" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    _ = try a.bind(p.wl_output.name, 4, null);
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    var pres_heard: Heard = .{};
    const pres = try a.bind(p.wp_presentation.name, 1, pres_heard.listener());
    try w.pump();
    // Binding wp_presentation immediately announces CLOCK_MONOTONIC (1).
    try testing.expectEqual(@as(u32, 1), pres_heard.counts[p.wp_presentation.event.clock_id]);
    try testing.expectEqual(@as(i64, 1), pres_heard.args[0]);

    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);

    // Commit two frames before scanout: the first feedback is discarded when superseded,
    // and the second receives sync_output + presented when framePresentedNs runs.
    var fb1_heard: Heard = .{};
    const fb1 = try a.d.newObject(fb1_heard.listener());
    var m = try pres.request(p.wp_presentation.request.feedback);
    m.uint(win.surface.id).uint(fb1.id).end();
    try a.show(win.surface, try a.shmBuffer(shm, 800, 560));
    try w.pump();
    try testing.expectEqual(@as(u32, 0), fb1_heard.events);

    var fb2_heard: Heard = .{};
    const fb2 = try a.d.newObject(fb2_heard.listener());
    m = try pres.request(p.wp_presentation.request.feedback);
    m.uint(win.surface.id).uint(fb2.id).end();
    try a.show(win.surface, try a.shmBuffer(shm, 800, 560));
    try w.pump();

    // First feedback was superseded by the second commit before presentation.
    try testing.expectEqual(@as(u32, 1), fb1_heard.counts[p.wp_presentation_feedback.event.discarded]);
    try testing.expectEqual(@as(u32, 0), fb2_heard.events);

    // Present the frame at t = 5_250_000_000 ns (5s + 250ms).
    const flags = p.wp_presentation_feedback.kind.vsync | p.wp_presentation_feedback.kind.hw_clock | p.wp_presentation_feedback.kind.hw_completion;
    w.server.frameDrawn();
    w.server.framePresentedNs(5_250_000_000, flags);
    try w.pump();
    try testing.expectEqual(@as(u32, 1), fb2_heard.counts[p.wp_presentation_feedback.event.sync_output]);
    try testing.expectEqual(@as(u32, 1), fb2_heard.counts[p.wp_presentation_feedback.event.presented]);
    // presented args: tv_sec_hi (0), tv_sec_lo (5), tv_nsec (250_000_000), refresh_ns (16683350 for 59940 mHz), seq_hi (0), seq_lo (1), flags.
    try testing.expectEqual(@as(i64, 0), fb2_heard.args[0]);
    try testing.expectEqual(@as(i64, 5), fb2_heard.args[1]);
    try testing.expectEqual(@as(i64, 250_000_000), fb2_heard.args[2]);
    try testing.expectEqual(@as(i64, 1_000_000_000_000 / 59940), fb2_heard.args[3]);
    try testing.expectEqual(@as(i64, 1), fb2_heard.args[5]);
    try testing.expectEqual(@as(i64, flags), fb2_heard.args[6]);
}

test "zwp_text_input_v3 sends enter/leave with focus, commits client state, and delivers IME events" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const seat = try a.bind(p.wl_seat.name, 5, null);
    const tim = try a.bind(p.zwp_text_input_manager_v3.name, 1, null);

    const TiEvents = struct {
        entered: u32 = 0,
        left: u32 = 0,
        preedit: [64]u8 = undefined,
        preedit_len: usize = 0,
        preedit_begin: i32 = 0,
        preedit_end: i32 = 0,
        commit: [64]u8 = undefined,
        commit_len: usize = 0,
        del_before: u32 = 0,
        del_after: u32 = 0,
        done_serial: u32 = 0,

        fn event(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
            const s: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (opcode) {
                p.zwp_text_input_v3.event.enter => s.entered = r.uint() catch 0,
                p.zwp_text_input_v3.event.leave => s.left = r.uint() catch 0,
                p.zwp_text_input_v3.event.preedit_string => {
                    const str = (r.string() catch return) orelse "";
                    s.preedit_len = @min(str.len, s.preedit.len);
                    @memcpy(s.preedit[0..s.preedit_len], str[0..s.preedit_len]);
                    s.preedit_begin = r.int() catch 0;
                    s.preedit_end = r.int() catch 0;
                },
                p.zwp_text_input_v3.event.commit_string => {
                    const str = (r.string() catch return) orelse "";
                    s.commit_len = @min(str.len, s.commit.len);
                    @memcpy(s.commit[0..s.commit_len], str[0..s.commit_len]);
                },
                p.zwp_text_input_v3.event.delete_surrounding_text => {
                    s.del_before = r.uint() catch 0;
                    s.del_after = r.uint() catch 0;
                },
                p.zwp_text_input_v3.event.done => s.done_serial = r.uint() catch 0,
                else => {},
            }
        }
    };

    var ti_ev: TiEvents = .{};
    const ti = try a.d.newObject(.{ .ptr = &ti_ev, .handler = TiEvents.event });
    var m = try tim.request(p.zwp_text_input_manager_v3.request.get_text_input);
    m.uint(ti.id).uint(seat.id).end();

    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);
    try testing.expectEqual(win.surface.id, ti_ev.entered);

    // Client enables text input, sets surrounding text, content type, cursor rectangle, and commits.
    m = try ti.request(p.zwp_text_input_v3.request.enable);
    m.end();
    m = try ti.request(p.zwp_text_input_v3.request.set_surrounding_text);
    m.string("hello world").int(5).int(5).end();
    m = try ti.request(p.zwp_text_input_v3.request.set_text_change_cause);
    m.uint(p.zwp_text_input_v3.change_cause.input_method).end();
    m = try ti.request(p.zwp_text_input_v3.request.set_content_type);
    m.uint(p.zwp_text_input_v3.content_hint.spellcheck).uint(p.zwp_text_input_v3.content_purpose.normal).end();
    m = try ti.request(p.zwp_text_input_v3.request.set_cursor_rectangle);
    m.int(12).int(34).int(2).int(20).end();
    m = try ti.request(p.zwp_text_input_v3.request.commit);
    m.end();
    try w.pump();

    // Server records the committed state with serial 1.
    const srv_ti = w.server.activeTextInput().?;
    try testing.expect(srv_ti.enabled);
    try testing.expectEqualStrings("hello world", srv_ti.surrounding_text);
    try testing.expectEqual(@as(i32, 5), srv_ti.cursor);
    try testing.expectEqual(@as(i32, 5), srv_ti.anchor);
    try testing.expectEqual(@as(u32, p.zwp_text_input_v3.content_hint.spellcheck), srv_ti.content_hint);
    try testing.expectEqual(@as(i32, 12), srv_ti.cursor_rect.x);
    try testing.expectEqual(@as(u32, 1), srv_ti.serial);

    // Server sends preedit, delete_surrounding_text, commit_string, and done(1).
    w.server.textInputPreedit("ni", 0, 2);
    w.server.textInputDeleteSurrounding(1, 0);
    w.server.textInputCommitString("你好");
    w.server.textInputDone();
    try w.pump();
    try testing.expectEqualStrings("ni", ti_ev.preedit[0..ti_ev.preedit_len]);
    try testing.expectEqual(@as(i32, 2), ti_ev.preedit_end);
    try testing.expectEqual(@as(u32, 1), ti_ev.del_before);
    try testing.expectEqualStrings("你好", ti_ev.commit[0..ti_ev.commit_len]);
    try testing.expectEqual(@as(u32, 1), ti_ev.done_serial);
}

test "a window whose client asks is drawn rounded, with a shadow, unless square; other windows are drawn as they are" {
    var w: World = .{};
    w.init();
    defer w.deinit();
    var quads: [16]Server.Quad = undefined;

    // A window that did not ask, at the bottom.
    const b = try w.connect();
    const b_compositor = try b.bind(p.wl_compositor.name, 4, null);
    const b_wm_base = try b.bind(p.xdg_wm_base.name, 6, null);
    const b_shm = try b.bind(p.wl_shm.name, 1, null);
    var plain: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try plain.open(b, b_compositor, b_wm_base, b_shm, null);
    var m = try plain.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try plain.redraw(b, b_shm, 400, 280);
    const plain_t = w.server.topWindow().?;

    // One that asks, over it.
    const a = try w.connect();
    const compositor = try a.bind(p.wl_compositor.name, 4, null);
    const wm_base = try a.bind(p.xdg_wm_base.name, 6, null);
    const shm = try a.bind(p.wl_shm.name, 1, null);
    const mgr = try a.bind(p.dazzle_decoration_manager_v1.name, 1, null);
    var win: Window = .{ .surface = undefined, .xdg = undefined, .toplevel = undefined };
    try win.open(a, compositor, wm_base, shm, null);
    var deco_heard: Heard = .{};
    const deco = try a.d.newObject(deco_heard.listener());
    m = try mgr.request(p.dazzle_decoration_manager_v1.request.get_decoration);
    m.uint(deco.id).uint(win.toplevel.id).end();
    try w.pump();
    // Maximized, it is told it is square.
    try testing.expectEqual(@as(u32, 1), deco_heard.counts[p.dazzle_decoration_v1.event.corner_radius]);
    try testing.expectEqual(@as(i64, 0), deco_heard.args[0]);
    try testing.expectEqual(@as(u16, 0), w.drawn(&quads)[0].radius);

    // Restored, it is told its radius, and drawn so once it has drawn.
    m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try win.redraw(a, shm, 400, 280);
    try testing.expectEqual(@as(i64, server_mod.corner_radius), deco_heard.args[0]);
    var drawn = w.drawn(&quads);
    try testing.expectEqual(@as(usize, 2), drawn.len);
    try testing.expectEqual(@as(u16, 0), drawn[0].radius);
    try testing.expect(!drawn[0].shadow);
    try testing.expectEqual(@as(u16, server_mod.corner_radius), drawn[1].radius);
    try testing.expect(drawn[1].shadow);
    try testing.expectEqual(w.server.work_area, drawn[1].shadow_clip);
    // The window behind, the same size in the same place, can be seen at
    // its corners: it is not covered.
    w.server.updateFocus();
    try testing.expectEqual(w.server.windowRect(plain_t), w.server.windowRect(w.server.topWindow().?));
    try testing.expect(!plain_t.suspended);

    // Maximized again: square, once drawn so.
    m = try win.toplevel.request(p.xdg_toplevel.request.set_maximized);
    m.end();
    try w.pump();
    try testing.expectEqual(@as(i64, 0), deco_heard.args[0]);
    try win.redraw(a, shm, 800, 560);
    try testing.expectEqual(@as(u16, 0), w.drawn(&quads)[0].radius);

    // Without its decoration, drawn as it is; and the window behind,
    // hidden, is covered.
    m = try win.toplevel.request(p.xdg_toplevel.request.unset_maximized);
    m.end();
    try win.redraw(a, shm, 400, 280);
    try testing.expectEqual(@as(u16, server_mod.corner_radius), w.drawn(&quads)[1].radius);
    m = try deco.request(p.dazzle_decoration_v1.request.destroy);
    m.end();
    try w.pump();
    w.server.updateFocus();
    drawn = w.drawn(&quads);
    try testing.expectEqual(@as(u16, 0), drawn[drawn.len - 1].radius);
    try testing.expect(plain_t.suspended);
}
