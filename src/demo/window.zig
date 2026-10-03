//! The demo's window: a Wayland xdg toplevel on the shell.

const std = @import("std");
const wayland = @import("wayland");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

/// Used when the compositor leaves the size to us.
const default_size = [2]u32{ 1280, 720 };

pub const Window = struct {
    conn: *client.Display,
    globals: client.Globals = .{},
    wm_base: client.Proxy = undefined,
    /// The wl_surface, which EGL draws to.
    surface: client.Proxy = undefined,
    xdg_surface: client.Proxy = undefined,
    toplevel: client.Proxy = undefined,
    width: u32 = default_size[0],
    height: u32 = default_size[1],
    /// From the last toplevel configure (0 = our choice).
    next_size: [2]i32 = .{ 0, 0 },
    /// A configure to acknowledge.
    pending_serial: ?u32 = null,
    closed: bool = false,

    /// Connects to the compositor and creates a toplevel window, waiting
    /// for its first configure.
    pub fn open(gpa: std.mem.Allocator, path: []const u8, title: []const u8) !*Window {
        const conn = try client.Display.connect(gpa, path);
        errdefer conn.disconnect();
        const w = try gpa.create(Window);
        w.* = .{ .conn = conn };
        const registry = try w.globals.fetch(conn);
        const compositor = (try w.globals.bind(registry, p.wl_compositor.name, 4, null)) orelse return error.NoCompositor;
        w.wm_base = (try w.globals.bind(registry, p.xdg_wm_base.name, 1, .{ .ptr = w, .handler = wmBaseEvent })) orelse return error.NoXdgShell;

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
        m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
        m.string("stardust-demo").end();
        // The initial commit, without a buffer, asks for the first configure.
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        while (w.pending_serial == null) try conn.dispatch();
        _ = try w.applyConfigure();
        return w;
    }

    /// Handles events that have arrived, without waiting.
    pub fn poll(w: *Window) !void {
        _ = try w.conn.dispatchPending();
    }

    /// Acknowledges a pending configure. Returns the new size if it changed.
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
            p.xdg_toplevel.event.configure => w.next_size = .{ r.int() catch 0, r.int() catch 0 },
            p.xdg_toplevel.event.close => w.closed = true,
            else => {},
        }
    }
};
