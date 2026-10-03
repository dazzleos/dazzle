//! The demo's window: a Wayland xdg toplevel on the shell, with the seat's
//! pointer and keyboard.

const std = @import("std");
const wayland = @import("wayland");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

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
    seat: ?client.Proxy = null,
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,
    pointer_pos: [2]f32 = .{ 0, 0 },
    /// Input since the last `takeInput`.
    input: [64]InputEvent = undefined,
    input_len: usize = 0,

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

    /// The input events received since the last call. The slice is valid
    /// until the next `poll`.
    pub fn takeInput(w: *Window) []const InputEvent {
        defer w.input_len = 0;
        return w.input[0..w.input_len];
    }

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
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // time
                const code = r.uint() catch return;
                const state = r.uint() catch return;
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
                _ = std.os.linux.close(fd);
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
            p.xdg_toplevel.event.configure => w.next_size = .{ r.int() catch 0, r.int() catch 0 },
            p.xdg_toplevel.event.close => w.closed = true,
            else => {},
        }
    }
};
