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
//! An app that draws all the time (a game) can keep a frame in flight
//! (`setPipelined`): `submit` hands a frame to the GPU without waiting for
//! it, and shows the one before (which the GPU has finished by then, or
//! soon), so the app records the next frame while the GPU renders this
//! one, rather than each waiting for the other. That takes a third buffer
//! (one shown, one rendering, one being drawn), which is only made while
//! a quarter of the GPU's memory would still be free; otherwise frames go
//! one at a time, as `present` does.
//!
//! The window is resized by dragging its edges when it is not maximized
//! (or tiled: xdg_toplevel's tiled states, filling half the work area):
//! a press within `resize_border` of an edge (inside the window: it has
//! nothing outside) asks the shell to resize it (xdg_toplevel.resize)
//! rather than going to the app, and the pointer shows a resize arrow
//! there (with wp_cursor_shape_v1, if the shell has it). The app says how
//! small it may be with `setMinSize`, and draws at whatever size it is
//! given at or above that.
//!
//! Buffers are RGB565 by default, half the memory of 32-bit ones (a
//! full-screen window's three buffers at 1920x1080 take 12 MB rather than
//! 24): Dazzle's apps draw opaque windows of flat colours, which 16 bits
//! show well. An app that needs more (smooth gradients, say) asks for
//! 32-bit buffers with `setFormat`. If the shell does not take RGB565
//! buffers, they are 32-bit.
//!
//! While another window covers it, the shell says the window is
//! `suspended` and holds its frame callbacks: the app should not draw
//! (nothing would be seen), and the window frees the buffers it is not
//! using, for the app in front. GPU memory is scarce (every buffer comes
//! from the kernel's CMA pool), so a buffer that cannot be had waits for
//! one to be released, or for memory to be freed.

const std = @import("std");
const linux = std.os.linux;
const locale = @import("locale");
const sys = @import("sys");
const evdev = sys.evdev;
const vc4 = @import("vc4");
const wayland = @import("wayland");

const client = wayland.client;
const Clipboard = @import("clipboard.zig").Clipboard;
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
        /// Submits a frame without waiting, returning what to wait for
        /// (null: it cannot, and frames go one at a time).
        submit: ?*const fn (ptr: *anyopaque, frame: *vc4.render.Frame) anyerror!u64 = null,
        /// Waits for what `submit` returned.
        wait: ?*const fn (ptr: *anyopaque, seqno: u64) anyerror!void = null,
        /// The GPU's memory: the pool's size and how much is free, in bytes
        /// (null if unknown).
        memory: ?*const fn (ptr: *anyopaque) ?[2]u64 = null,
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
        try devWait(ptr, try devSubmit(ptr, frame));
    }
    fn devSubmit(ptr: *anyopaque, frame: *vc4.render.Frame) anyerror!u64 {
        const dev = devOf(ptr);
        _ = frame.finish();
        // One job per region the frame is limited to (the GPU runs jobs in
        // the order they come, so waiting for the last waits for all).
        // The kernel copies the control lists, so the frame can be reused
        // at once.
        var seqno: u64 = 0;
        for (0..frame.regionCount()) |i| seqno = try dev.submit(frame.submitRegion(i));
        return seqno;
    }
    fn devWait(ptr: *anyopaque, seqno: u64) anyerror!void {
        if (seqno == 0) return;
        const dev = devOf(ptr);
        dev.waitSeqno(seqno, std.time.ns_per_s) catch |err| {
            if (err != error.TimedOut) return err;
            // Slow, or stuck: the kernel resets a GPU that is stuck, which
            // ends the job (a frame is lost, not the app). Said, with how
            // much of the GPU's memory is free, and waited for longer.
            var comm_buf: [32]u8 = undefined;
            const comm = std.mem.trimEnd(u8, sys.readFile("/proc/self/comm", &comm_buf) orelse "app", "\n");
            const mi = sys.meminfo() orelse sys.Meminfo{};
            sys.print(sys.log_warning ++ "{s}: a frame is not drawn after a second ({d} of {d} MB of GPU memory free); waiting for it\n", .{ comm, mi.cma_free >> 20, mi.cma_total >> 20 });
            try dev.waitSeqno(seqno, gpu_patience_ns);
        };
    }

    /// How long a frame is waited for, at the most, after the first
    /// second: longer than the kernel takes to notice the GPU is stuck and
    /// reset it.
    const gpu_patience_ns = 10 * std.time.ns_per_s;
    fn devMemory(_: *anyopaque) ?[2]u64 {
        const mi = sys.meminfo() orelse return null;
        if (mi.cma_total == 0) return null;
        return .{ mi.cma_total, mi.cma_free };
    }

    /// The real GPU. `dev` must stay in place.
    pub fn device(dev: *vc4.Device) Gpu {
        return .{ .ptr = dev, .vtable = &.{
            .createBo = devCreateBo,
            .destroyBo = devDestroyBo,
            .exportBo = devExportBo,
            .run = devRun,
            .submit = devSubmit,
            .wait = devWait,
            .memory = devMemory,
        } };
    }
};

pub const TextInputState = struct {
    surrounding_text: []const u8 = "",
    cursor: u32 = 0,
    anchor: u32 = 0,
    change_cause: u32 = p.zwp_text_input_v3.change_cause.input_method,
    content_hint: u32 = p.zwp_text_input_v3.content_hint.none,
    content_purpose: u32 = p.zwp_text_input_v3.content_purpose.normal,
    cursor_rect: [4]i32 = .{ 0, 0, 1, 20 },

    pub fn eql(a: TextInputState, b: TextInputState) bool {
        return a.cursor == b.cursor and
            a.anchor == b.anchor and
            a.change_cause == b.change_cause and
            a.content_hint == b.content_hint and
            a.content_purpose == b.content_purpose and
            std.mem.eql(i32, &a.cursor_rect, &b.cursor_rect) and
            std.mem.eql(u8, a.surrounding_text, b.surrounding_text);
    }
};

pub const InputEvent = union(enum) {
    /// The pointer moved to (or entered at) a position in the window.
    motion: [2]f32,
    /// A Linux button code (BTN_LEFT, ...), and where the pointer was.
    button: struct { pos: [2]f32, code: u32, pressed: bool },
    /// A Linux key code (KEY_A, ...).
    key: struct { code: u32, pressed: bool },
    /// The wheel turned: by `dy` pixels down (and `dx` right), with the
    /// pointer at `pos`.
    scroll: struct { pos: [2]f32, dx: f32, dy: f32 },
    /// The pointer left the window (or the shell took it, to move the
    /// window).
    leave,
    /// A touch went down at a position (`id` is the touch's while it
    /// lasts), moved, or came up.
    touch_down: struct { id: i32, pos: [2]f32 },
    touch_motion: struct { id: i32, pos: [2]f32 },
    touch_up: i32,
    /// The window's touches are the shell's now (it moves the window, say):
    /// forget them, without acting on them.
    touch_cancel,
    /// The pointer moved this far, in pixels, whatever the screen's edges
    /// (for a locked pointer: see `lockPointer`).
    relative_motion: [2]f32,
    /// The pointer lock took effect (true), or ended (false).
    pointer_locked: bool,
    /// An input method committed UTF-8 text (`zwp_text_input_v3`).
    text_commit: struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    },
    /// An input method updated its preedit string (`zwp_text_input_v3`).
    text_preedit: struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    },
    /// An input method asked to delete bytes around the cursor
    /// (`zwp_text_input_v3`).
    text_delete_surrounding: struct { before_length: u32, after_length: u32 },
    /// A Wayland drag-and-drop entered or moved over the window, left it,
    /// or dropped at `pos` (`takeDrop` yields the received payload once
    /// its pipe finishes).
    drag_enter: [2]f32,
    drag_motion: [2]f32,
    drag_leave,
    drop: [2]f32,
};

/// Used when the compositor leaves the size to us.
const default_size = [2]u32{ 1280, 720 };

/// How far in from a window's edges a press resizes it, and how far along
/// them from a corner the corner is taken.
pub const resize_border = 6;
pub const resize_corner = 20;

/// A window's edges (xdg_toplevel.resize_edge's bits).
pub const edge_top = 1;
pub const edge_bottom = 2;
pub const edge_left = 4;
pub const edge_right = 8;

const max_buffers = 3;

/// A frame with the GPU (see `Window.submit`): its buffer, what to wait
/// for, and what changed in it.
const InFlight = struct {
    buffer: usize,
    seqno: u64,
    damage: [max_damage]vc4.render.Viewport = undefined,
    /// Null: all of it.
    damage_len: ?usize,
};

const max_damage = 16;

const Buffer = struct {
    /// The frame (counting from 1) last drawn in it; 0 if none.
    drawn: u64 = 0,
    bo: vc4.Bo,
    proxy: client.Proxy,
    width: u32,
    height: u32,
    format: vc4.Format,
    /// Committed and not yet released by the compositor.
    busy: bool = false,
    /// Its frame is with the GPU, not yet shown (see `submit`).
    rendering: bool = false,

    fn target(b: *const Buffer) vc4.render.Target {
        return .{
            .handle = b.bo.handle,
            .width = @intCast(b.width),
            .height = @intCast(b.height),
            .tiling = vc4.render.Target.textureTiling(b.format, b.width, b.height),
            .format = b.format,
        };
    }
};

/// How many extra files a window's `wait` can wake for (`Window.wake_fds`).
pub const max_wake_fds = 8;

pub const Window = struct {
    gpa: std.mem.Allocator,
    gpu: Gpu,
    conn: *client.Display,
    globals: client.Globals = .{},
    wm_base: client.Proxy = undefined,
    dmabuf: client.Proxy = undefined,
    /// The formats the shell takes T-tiled buffers in.
    tiled_formats: std.EnumSet(vc4.Format) = .{},
    /// The format the app would like its buffers in (`setFormat`).
    wanted_format: vc4.Format = .rgb565,
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
    /// Filling the work area (the shell's configure says so); otherwise
    /// movable and resizable.
    maximized: bool = false,
    /// On the whole screen, over the shell's dock (see `setFullscreen`).
    fullscreen: bool = false,
    /// Filling half the work area, against its edges (dragged to the
    /// screen's left or right edge): not resized from its edges either.
    tiled: bool = false,
    /// Rounded by the shell (`Options.rounded`): its corners' radius, as
    /// the shell last said (0 while square: maximized, fullscreen or
    /// tiled). What it shows should keep inside it.
    decoration: ?client.Proxy = null,
    corner_radius: u32 = 0,
    /// The serial of the last active pointer/touch press, for asking the
    /// shell to move the window from it (0 once released).
    press_serial: u32 = 0,
    buttons_down: u32 = 0,
    /// The serial of the pointer entering, for choosing its picture.
    enter_serial: u32 = 0,
    /// The shell's cursor shapes, the pointer's device for them, the shape
    /// last sent to the shell (null if not chosen since entering), and the
    /// shape requested by the app (`setCursor`).
    cursor_shape_manager: ?client.Proxy = null,
    cursor_device: ?client.Proxy = null,
    cursor_shape: ?u32 = null,
    app_cursor: u32 = p.wp_cursor_shape_device_v1.shape.default,

    buffers: [max_buffers]?Buffer = @splat(null),
    /// The buffer the frame being recorded renders into.
    back: ?usize = null,
    /// A committed frame whose frame callback has not fired yet.
    frame_pending: bool = false,
    /// Frames shown so far.
    frames: u64 = 0,
    /// Keep a frame in flight (see `setPipelined`).
    pipelined: bool = false,
    /// The frame submitted and not yet shown.
    in_flight: ?InFlight = null,

    /// Presentation timing (`wp_presentation`): clock ID, last scanout
    /// timestamp and refresh period in nanoseconds, refresh counter, and
    /// `wp_presentation_feedback.kind` flags.
    presentation: ?client.Proxy = null,
    presentation_clock_id: u32 = 1,
    presented_ns: u64 = 0,
    refresh_ns: u64 = 0,
    presentation_seq: u64 = 0,
    presentation_flags: u32 = 0,
    presented_frames: u64 = 0,
    discarded_frames: u64 = 0,

    seat: ?client.Proxy = null,
    touch: ?client.Proxy = null,
    /// Text input (`zwp_text_input_v3`) for IME / on-screen keyboards.
    text_input_manager: ?client.Proxy = null,
    text_input: ?client.Proxy = null,
    text_input_entered: bool = false,
    text_input_enabled: bool = false,
    text_input_has_preedit: bool = false,
    text_input_serial: u32 = 0,
    text_input_state: TextInputState = .{},
    text_input_surrounding_buf: [256]u8 = undefined,
    text_input_pending_preedit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,
    } = null,
    text_input_pending_commit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
    } = null,
    text_input_pending_delete: ?struct {
        before_length: u32,
        after_length: u32,
    } = null,
    /// For locking the pointer (see `lockPointer`): the shell's globals,
    /// the pointer's relative motion, the lock asked for, and whether it
    /// is in effect.
    pointer_constraints: ?client.Proxy = null,
    relative_pointer_manager: ?client.Proxy = null,
    relative_pointer: ?client.Proxy = null,
    locked_pointer: ?client.Proxy = null,
    pointer_locked: bool = false,
    /// The system's clipboard (for the toolkit's `Ui.clipboard`).
    clipboard: Clipboard,
    /// The keyboard's layout, as the shell's keymap says (give it to the
    /// toolkit: `Ui.keyboard`).
    layout: locale.Keyboard = .us,
    /// A file of the app's that `wait` also wakes for when it can be
    /// read (a camera's frames, say), and any extra wake files.
    wake_fd: ?linux.fd_t = null,
    wake_fds: [max_wake_fds]?linux.fd_t = @splat(null),
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,
    /// Keys per second (`wl_keyboard.repeat_info`, 0 disables repeat) and
    /// milliseconds before repeating starts.
    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 600,
    repeat: ?struct { code: u32, next_ns: u64 } = null,
    keys_down: std.StaticBitSet(256) = .empty,
    pointer_pos: [2]f32 = .{ 0, 0 },
    /// Input since the last `takeInput`.
    input: [64]InputEvent = undefined,
    input_len: usize = 0,

    /// Connects to the compositor named in `environ` (`WAYLAND_DISPLAY`
    /// under `XDG_RUNTIME_DIR`) and opens a window, logging why if it
    /// cannot.
    pub fn open(gpa: std.mem.Allocator, gpu: Gpu, environ: std.process.Environ, options: Options) !*Window {
        const name = options.app_id orelse options.title;
        var path_buf: [256]u8 = undefined;
        const path = client.environSocketPath(&path_buf, environ) catch |err| {
            sys.print(sys.log_error ++ "{s}: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{name});
            return err;
        };
        return openPath(gpa, gpu, path, options) catch |err| {
            sys.print(sys.log_error ++ "{s}: cannot open a window on {s} ({s})\n", .{ name, path, @errorName(err) });
            return err;
        };
    }

    /// Connects to the compositor listening on `path` and opens a window.
    pub fn openPath(gpa: std.mem.Allocator, gpu: Gpu, path: []const u8, options: Options) !*Window {
        const conn = try client.Display.connect(gpa, path);
        errdefer conn.disconnect();
        return openOn(gpa, gpu, conn, options);
    }

    /// How a window opens.
    pub const Options = struct {
        title: []const u8,
        /// The app's name, as the shell and its dock know it.
        app_id: ?[]const u8 = null,
        /// The size it opens at: the best for what the app shows. The
        /// shell lets the app choose (it places the window in the middle
        /// of its work area), and makes it smaller if it does not fit.
        size: [2]u32 = default_size,
        /// How small the window may be made (see `setMinSize`).
        min_size: ?[2]u32 = null,
        /// Open maximized instead.
        maximized: bool = false,
        /// Ask the shell to round its corners and draw a shadow
        /// (dazzle_decoration_v1), for a window that draws its own title
        /// bar and border to match (see `corner_radius`). Ignored by a
        /// shell that does not.
        rounded: bool = false,
    };

    /// Opens a window on an existing connection, which the window then
    /// owns. Waits for the first configure.
    pub fn openOn(gpa: std.mem.Allocator, gpu: Gpu, conn: *client.Display, options: Options) !*Window {
        const w = try gpa.create(Window);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .gpu = gpu, .conn = conn, .clipboard = .{ .gpa = gpa }, .width = options.size[0], .height = options.size[1], .maximized = options.maximized };
        w.clipboard.drag_callbacks = .{
            .ctx = w,
            .enter = onDragEnter,
            .motion = onDragMotion,
            .leave = onDragLeave,
            .drop = onDragDrop,
        };
        const title = options.title;
        const registry = try w.globals.fetch(conn);
        const compositor = (try w.globals.bind(registry, p.wl_compositor.name, 4, null)) orelse return error.NoCompositor;
        // Version 6 for the suspended state.
        w.wm_base = (try w.globals.bind(registry, p.xdg_wm_base.name, 6, .{ .ptr = w, .handler = wmBaseEvent })) orelse return error.NoXdgShell;
        w.dmabuf = (try w.globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = w, .handler = dmabufEvent })) orelse return error.NoDmabuf;
        // Optional: the pointer's pictures, presentation timing, and the
        // pointer and keyboard (which come with the seat's capabilities).
        w.cursor_shape_manager = try w.globals.bind(registry, p.wp_cursor_shape_manager_v1.name, 1, null);
        w.presentation = try w.globals.bind(registry, p.wp_presentation.name, 1, .{ .ptr = w, .handler = presentationEvent });
        // Optional: locking the pointer in place, and its relative motion
        // (bound before the seat, which makes the pointer).
        w.pointer_constraints = try w.globals.bind(registry, p.zwp_pointer_constraints_v1.name, 1, null);
        w.relative_pointer_manager = try w.globals.bind(registry, p.zwp_relative_pointer_manager_v1.name, 1, null);
        w.seat = try w.globals.bind(registry, p.wl_seat.name, 5, .{ .ptr = w, .handler = seatEvent });
        // Optional: copy, paste, and drag-and-drop.
        try w.clipboard.attach(conn, try w.globals.bind(registry, p.wl_data_device_manager.name, 3, null), w.seat);
        // Optional: text input (IME / on-screen keyboard).
        w.text_input_manager = try w.globals.bind(registry, p.zwp_text_input_manager_v3.name, 1, null);
        if (w.text_input_manager) |mgr| if (w.seat) |seat| {
            const ti = try conn.newObject(.{ .ptr = w, .handler = textInputEvent });
            var m = try mgr.request(p.zwp_text_input_manager_v3.request.get_text_input);
            m.uint(ti.id).uint(seat.id).end();
            w.text_input = ti;
        };

        w.surface = try conn.newObject(null);
        var m = try compositor.request(p.wl_compositor.request.create_surface);
        m.uint(w.surface.id).end();
        w.xdg_surface = try conn.newObject(.{ .ptr = w, .handler = xdgSurfaceEvent });
        m = try w.wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(w.xdg_surface.id).uint(w.surface.id).end();
        w.toplevel = try conn.newObject(.{ .ptr = w, .handler = toplevelEvent });
        m = try w.xdg_surface.request(p.xdg_surface.request.get_toplevel);
        m.uint(w.toplevel.id).end();
        if (options.rounded) if (try w.globals.bind(registry, p.dazzle_decoration_manager_v1.name, 1, null)) |mgr| {
            const deco = try conn.newObject(.{ .ptr = w, .handler = decorationEvent });
            m = try mgr.request(p.dazzle_decoration_manager_v1.request.get_decoration);
            m.uint(deco.id).uint(w.toplevel.id).end();
            w.decoration = deco;
        };
        m = try w.toplevel.request(p.xdg_toplevel.request.set_title);
        m.string(title).end();
        if (options.app_id) |app_id| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
            m.string(app_id).end();
        }
        if (options.min_size) |min_size| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_min_size);
            m.int(@intCast(min_size[0])).int(@intCast(min_size[1])).end();
        }
        if (options.maximized) {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_maximized);
            m.end();
        }
        // The initial commit, without a buffer, asks for the first configure.
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        while (w.pending_serial == null) try conn.dispatch();
        if (!w.tiled_formats.contains(.xrgb8888)) return error.NoTiledBuffers;
        _ = try w.applyConfigure();
        return w;
    }

    /// Frees the buffers and disconnects.
    pub fn close(w: *Window) void {
        w.clipboard.deinit();
        for (&w.buffers) |*slot| if (slot.*) |*b| w.freeBuffer(b, slot);
        w.conn.flush() catch {};
        w.conn.disconnect();
        w.gpa.destroy(w);
    }

    pub fn setAppId(w: *Window, app_id: []const u8) !void {
        var m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
        m.string(app_id).end();
    }

    /// Handles events that have arrived (and pasted text), without
    /// waiting.
    pub fn poll(w: *Window) !void {
        _ = try w.conn.dispatchPending();
        w.clipboard.service();
        w.serviceRepeat(sys.nowNs());
    }

    /// Asks the shell to show the window on the whole screen, over its
    /// dock (`fullscreen` says when it does), or not; a configure follows.
    pub fn setFullscreen(w: *Window, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_fullscreen else p.xdg_toplevel.request.unset_fullscreen) catch return;
        // On whichever output the shell chooses.
        if (on) _ = m.uint(0);
        m.end();
        w.conn.flush() catch {};
    }

    /// Asks the shell to keep the pointer where it is and hide it, while it
    /// is over the window and the window is on top: the app then gets only
    /// how it moves (`relative_motion` events), as a game turning its view
    /// with the mouse wants. `pointer_locked` events say when that takes
    /// effect and ends (the shell can end it: the Super key does). Returns
    /// whether the shell can.
    pub fn lockPointer(w: *Window) bool {
        if (w.locked_pointer != null) return true;
        const constraints = w.pointer_constraints orelse return false;
        const pointer = w.pointer orelse return false;
        if (w.relative_pointer == null) return false;
        const lock = w.conn.newObject(.{ .ptr = w, .handler = lockEvent }) catch return false;
        var m = constraints.request(p.zwp_pointer_constraints_v1.request.lock_pointer) catch return false;
        // The whole surface (no region), for as long as it is not unlocked.
        m.uint(lock.id).uint(w.surface.id).uint(pointer.id).uint(0).uint(p.zwp_pointer_constraints_v1.lifetime.persistent).end();
        w.conn.flush() catch {};
        w.locked_pointer = lock;
        return true;
    }

    /// Gives the pointer back (see `lockPointer`).
    pub fn unlockPointer(w: *Window) void {
        const lock = w.locked_pointer orelse return;
        if (lock.request(p.zwp_locked_pointer_v1.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(lock.id);
        w.locked_pointer = null;
        if (w.pointer_locked) {
            w.pointer_locked = false;
            w.pushInput(.{ .pointer_locked = false });
        }
        w.conn.flush() catch {};
    }

    fn lockEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        const locked = opcode == p.zwp_locked_pointer_v1.event.locked;
        if (locked == w.pointer_locked) return;
        w.pointer_locked = locked;
        w.pushInput(.{ .pointer_locked = locked });
    }

    fn relativeEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_relative_pointer_v1.event.relative_motion) return;
        _ = r.uint() catch return; // the time, in microseconds
        _ = r.uint() catch return;
        const dx: f32 = @floatCast(r.fixed() catch return);
        const dy: f32 = @floatCast(r.fixed() catch return);
        w.pushInput(.{ .relative_motion = .{ dx, dy } });
    }

    /// Asks the shell to fill the screen with the window, or to make it
    /// its own size again; a configure follows.
    pub fn setMaximized(w: *Window, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_maximized else p.xdg_toplevel.request.unset_maximized) catch return;
        m.end();
        w.conn.flush() catch {};
    }

    /// Changes the title the shell shows for it.
    pub fn setTitle(w: *Window, title: []const u8) void {
        var m = w.toplevel.request(p.xdg_toplevel.request.set_title) catch return;
        m.string(title).end();
        w.conn.flush() catch {};
    }

    /// Tells the shell how small the window may be made: as small as its
    /// content can be shown in.
    pub fn setMinSize(w: *Window, width: u32, height: u32) void {
        var m = w.toplevel.request(p.xdg_toplevel.request.set_min_size) catch return;
        m.int(@intCast(width)).int(@intCast(height)).end();
        w.conn.flush() catch {};
    }

    /// The edges a press at `pos` would resize the window by (0 for none:
    /// a maximized or tiled window is not resized).
    pub fn edgesAt(w: *const Window, pos: [2]f32) u32 {
        if (w.maximized or w.fullscreen or w.tiled) return 0;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const x = pos[0];
        const y = pos[1];
        if (x < 0 or y < 0 or x >= width or y >= height) return 0;
        var edges: u32 = 0;
        if (x < resize_border) edges |= edge_left else if (x >= width - resize_border) edges |= edge_right;
        if (y < resize_border) edges |= edge_top else if (y >= height - resize_border) edges |= edge_bottom;
        // Near a corner: both edges at it.
        if (edges & (edge_left | edge_right) != 0 and edges & (edge_top | edge_bottom) == 0) {
            if (y < resize_corner) edges |= edge_top else if (y >= height - resize_corner) edges |= edge_bottom;
        }
        if (edges & (edge_top | edge_bottom) != 0 and edges & (edge_left | edge_right) == 0) {
            if (x < resize_corner) edges |= edge_left else if (x >= width - resize_corner) edges |= edge_right;
        }
        return edges;
    }

    /// Sets the cursor shape (`wp_cursor_shape_device_v1.shape.*`) shown
    /// inside the window when the pointer is not over a resize border.
    pub fn setCursor(w: *Window, shape: u32) void {
        if (w.app_cursor == shape) return;
        w.app_cursor = shape;
        w.updateCursor();
    }

    /// Shows the pointer as a resize arrow over the edges (while no button
    /// is held), or `app_cursor` elsewhere.
    fn updateCursor(w: *Window) void {
        const edges = if (w.buttons_down == 0) w.edgesAt(w.pointer_pos) else 0;
        const sh = p.wp_cursor_shape_device_v1.shape;
        const vertical = edges & (edge_top | edge_bottom);
        const horizontal = edges & (edge_left | edge_right);
        const shape: u32 = if (vertical != 0 and horizontal != 0)
            (if ((vertical == edge_top) == (horizontal == edge_left)) sh.nwse_resize else sh.nesw_resize)
        else if (horizontal != 0) sh.ew_resize else if (vertical != 0) sh.ns_resize else w.app_cursor;
        if (w.cursor_shape == shape) return;
        const device = w.cursor_device orelse return;
        var m = device.request(p.wp_cursor_shape_device_v1.request.set_shape) catch return;
        m.uint(w.enter_serial).uint(shape).end();
        w.cursor_shape = shape;
    }

    /// Starts a Wayland drag-and-drop operation from the window with `bytes`
    /// offered as `mime_type` (using the last press serial).
    pub fn startDrag(w: *Window, mime_type: []const u8, bytes: []const u8, actions: u32) bool {
        return w.clipboard.startDrag(w.surface, null, mime_type, bytes, actions);
    }

    /// Returns data completed from a drop onto the window since the last
    /// call, if any.
    pub fn takeDrop(w: *Window) ?@import("clipboard.zig").DroppedData {
        return w.clipboard.takeDrop();
    }

    /// Predicts the nanosecond timestamp of the next display scanout after
    /// `now_ns` using `wp_presentation` feedback (`presented_ns` and
    /// `refresh_ns`), falling back to `now_ns` when unknown.
    pub fn nextPresentationNs(w: *const Window, now_ns: u64) u64 {
        if (w.presented_ns == 0 or w.refresh_ns == 0) return now_ns;
        if (now_ns < w.presented_ns) return w.presented_ns + w.refresh_ns;
        const elapsed = now_ns - w.presented_ns;
        const periods = elapsed / w.refresh_ns + 1;
        return w.presented_ns + periods * w.refresh_ns;
    }

    /// Synchronizes the focused text widget's state with `zwp_text_input_v3`
    /// (enabling text input when `state != null` and disabling it when null).
    pub fn setTextInput(w: *Window, state: ?TextInputState) void {
        const ti = w.text_input orelse return;
        if (!w.text_input_entered) {
            if (state) |s| {
                w.saveTextInputState(s);
                w.text_input_enabled = true;
            } else {
                w.text_input_enabled = false;
            }
            return;
        }
        if (state) |s| {
            if (w.text_input_enabled and w.text_input_state.eql(s)) return;
            const enabling = !w.text_input_enabled;
            w.saveTextInputState(s);
            w.text_input_enabled = true;
            w.sendTextInputState(ti, enabling);
        } else {
            if (!w.text_input_enabled) return;
            w.text_input_enabled = false;
            var m = ti.request(p.zwp_text_input_v3.request.disable) catch return;
            m.end();
            m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
            m.end();
            w.text_input_serial +%= 1;
            w.conn.flush() catch {};
        }
    }

    fn saveTextInputState(w: *Window, s: TextInputState) void {
        const n = @min(s.surrounding_text.len, w.text_input_surrounding_buf.len);
        @memcpy(w.text_input_surrounding_buf[0..n], s.surrounding_text[0..n]);
        w.text_input_state = s;
        w.text_input_state.surrounding_text = w.text_input_surrounding_buf[0..n];
        w.text_input_state.cursor = @min(s.cursor, @as(u32, @intCast(n)));
        w.text_input_state.anchor = @min(s.anchor, @as(u32, @intCast(n)));
    }

    fn sendTextInputState(w: *Window, ti: client.Proxy, send_enable: bool) void {
        const s = w.text_input_state;
        if (send_enable) {
            var m = ti.request(p.zwp_text_input_v3.request.enable) catch return;
            m.end();
        }
        var m = ti.request(p.zwp_text_input_v3.request.set_surrounding_text) catch return;
        m.string(s.surrounding_text).uint(s.cursor).uint(s.anchor).end();
        m = ti.request(p.zwp_text_input_v3.request.set_text_change_cause) catch return;
        m.uint(s.change_cause).end();
        m = ti.request(p.zwp_text_input_v3.request.set_content_type) catch return;
        m.uint(s.content_hint).uint(s.content_purpose).end();
        m = ti.request(p.zwp_text_input_v3.request.set_cursor_rectangle) catch return;
        m.int(s.cursor_rect[0]).int(s.cursor_rect[1]).int(s.cursor_rect[2]).int(s.cursor_rect[3]).end();
        m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
        m.end();
        w.text_input_serial +%= 1;
        w.conn.flush() catch {};
    }

    /// Asks the shell to move the window with the pointer, from the button
    /// press just handled (dragging the title bar), until it is released.
    pub fn startMove(w: *Window) void {
        if (w.press_serial == 0) return;
        const seat = w.seat orelse return;
        var m = w.toplevel.request(p.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(w.press_serial).end();
        w.conn.flush() catch {};
    }

    /// Waits for events (input, a configure, a released buffer, pasted
    /// text) for up to `timeout_ns`, and handles them: for when there is
    /// nothing to draw.
    pub fn wait(w: *Window, timeout_ns: u64) !void {
        const now = sys.nowNs();
        const caller_ms: u64 = std.math.divCeil(u64, timeout_ns, std.time.ns_per_ms) catch 0;
        const timeout_ms = @min(caller_ms, w.repeatTimeoutMs(now) orelse caller_ms);
        const paste_fd = w.clipboard.pasteFd();
        const has_wake_fds = for (w.wake_fds) |fd| {
            if (fd != null) break true;
        } else false;
        if (paste_fd == null and w.wake_fd == null and !has_wake_fds) {
            try w.conn.dispatchTimeout(@intCast(@min(timeout_ms, std.math.maxInt(i32))));
            w.serviceRepeat(sys.nowNs());
            return;
        }
        // A paste under way: its pipe is waited on too (no longer than
        // until it gives up); and the app's own files, if it has any.
        try w.conn.flush();
        if (try w.conn.dispatchPending() == 0) {
            const ms = @min(timeout_ms, w.clipboard.pasteTimeoutMs() orelse timeout_ms, std.math.maxInt(i32));
            var fds: [3 + max_wake_fds]linux.pollfd = undefined;
            var n: usize = 0;
            for ([_]?linux.fd_t{ w.conn.conn.fd, paste_fd, w.wake_fd }) |fd| if (fd) |f| {
                fds[n] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            for (w.wake_fds) |fd| if (fd) |f| {
                fds[n] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            _ = linux.poll(&fds, n, @intCast(ms));
            _ = try w.conn.dispatchPending();
        }
        w.clipboard.service();
        w.serviceRepeat(sys.nowNs());
    }

    fn repeatTimeoutMs(w: *const Window, now_ns: u64) ?u64 {
        const rep = w.repeat orelse return null;
        if (w.repeat_rate == 0) return null;
        if (now_ns >= rep.next_ns) return 0;
        return std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
    }

    fn serviceRepeat(w: *Window, now_ns: u64) void {
        const rep = &(w.repeat orelse return);
        if (w.repeat_rate == 0) {
            w.repeat = null;
            return;
        }
        if (now_ns < rep.next_ns) return;
        const step = std.time.ns_per_s / @as(u64, w.repeat_rate);
        rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
        w.pushInput(.{ .key = .{ .code = rep.code, .pressed = true } });
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

    /// Renders a frame too full for what is still to be drawn into it (see
    /// `vc4.render.Flush`).
    pub fn flusher(w: *Window) vc4.render.Flush {
        return .{ .ctx = w, .run = struct {
            fn run(ctx: *anyopaque, frame: *vc4.render.Frame) anyerror!void {
                const self: *Window = @ptrCast(@alignCast(ctx));
                try self.render(frame);
            }
        }.run };
    }

    /// How many frames ago the buffer `beginFrame` gave was last drawn: 1
    /// if in the frame before, 0 if never (its contents are unknown). Only
    /// what changed since then needs drawing into it (see
    /// `vc4.render.Frame.limitTo`).
    pub fn bufferAge(w: *const Window) u32 {
        const i = w.back orelse return 0;
        const b = &w.buffers[i].?;
        if (b.drawn == 0) return 0;
        // The frame in flight is drawn, though not shown yet.
        const drawn = w.frames + @intFromBool(w.in_flight != null);
        return @intCast(@min(drawn + 1 - b.drawn, std.math.maxInt(u32)));
    }

    /// Keeps a frame in flight from now on, if the GPU can (see `submit`);
    /// or not, showing the one in flight.
    pub fn setPipelined(w: *Window, on: bool) !void {
        w.pipelined = on and w.gpu.vtable.submit != null and w.gpu.vtable.wait != null;
        if (!w.pipelined) try w.finishInFlight();
    }

    /// Hands `frame` (begun on `beginFrame`'s target) to the GPU, and
    /// shows the frame submitted before it, saying which parts of the
    /// window changed in it (all if null): with `setPipelined`, without
    /// waiting for the GPU to render this one; otherwise as `render` and
    /// `showDamaged`.
    pub fn submit(w: *Window, frame: *vc4.render.Frame, damage: ?[]const vc4.render.Viewport) !void {
        if (!w.pipelined) {
            try w.render(frame);
            return w.showDamaged(damage);
        }
        if (w.back == null) return error.NoFrameBegun;
        const seqno = try w.gpu.vtable.submit.?(w.gpu.ptr, frame);
        return w.submitted(seqno, damage);
    }

    /// Keeps the frame drawn into `beginFrame`'s buffer, which the GPU is
    /// rendering (`seqno`, from `Gpu.submit`), in flight, and shows the
    /// frame in flight before it: `submit` for a frame already handed to
    /// the GPU by its renderer. Only with `setPipelined`.
    pub fn submitted(w: *Window, seqno: u64, damage: ?[]const vc4.render.Viewport) !void {
        std.debug.assert(w.pipelined);
        const i = w.back orelse return error.NoFrameBegun;
        // The frame before is done by the time this one starts (the GPU
        // takes jobs in turn): show it while this one renders.
        try w.finishInFlight();
        var f: InFlight = .{ .buffer = i, .seqno = seqno, .damage_len = null };
        if (damage) |rects| if (rects.len <= max_damage) {
            @memcpy(f.damage[0..rects.len], rects);
            f.damage_len = rects.len;
        };
        w.in_flight = f;
        w.buffers[i].?.rendering = true;
        w.back = null;
    }

    /// Waits for the frame in flight (if there is one) and shows it: before
    /// the app stops drawing for a while.
    pub fn finishInFlight(w: *Window) !void {
        const f = w.in_flight orelse return;
        w.in_flight = null;
        try w.gpu.vtable.wait.?(w.gpu.ptr, f.seqno);
        const b = &w.buffers[f.buffer].?;
        b.rendering = false;
        try w.showBuffer(f.buffer, if (f.damage_len) |n| f.damage[0..n] else null);
    }

    /// Hands the rendered frame to the compositor, once it has shown the
    /// previous one, saying the whole window changed.
    pub fn show(w: *Window) !void {
        return w.showDamaged(null);
    }

    /// Like `show`, saying which parts of the window changed since the
    /// last frame shown (all of it if null).
    pub fn showDamaged(w: *Window, damage: ?[]const vc4.render.Viewport) !void {
        const i = w.back orelse return error.NoFrameBegun;
        try w.finishInFlight();
        try w.showBuffer(i, damage);
        w.back = null;
    }

    fn showBuffer(w: *Window, i: usize, damage: ?[]const vc4.render.Viewport) !void {
        while (w.frame_pending) {
            try w.conn.dispatch();
            // Covered while waiting: the callback comes when it is in
            // front again.
            if (w.suspended) w.releaseSpareBuffers();
        }
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
        if (w.presentation) |pres| {
            const fb = try w.conn.newObject(.{ .ptr = w, .handler = feedbackEvent });
            m = try pres.request(p.wp_presentation.request.feedback);
            m.uint(w.surface.id).uint(fb.id).end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        try w.conn.flush();
        b.busy = true;
        w.frames += 1;
        b.drawn = w.frames;
        w.frame_pending = true;
    }

    /// The input events received since the last call. The slice is valid
    /// until the next `poll`.
    pub fn takeInput(w: *Window) []const InputEvent {
        defer w.input_len = 0;
        return w.input[0..w.input_len];
    }

    // --- Buffers ----------------------------------------------------------------

    /// Asks for buffers in `format` from the next frame on (RGB565 unless
    /// asked otherwise).
    pub fn setFormat(w: *Window, wanted: vc4.Format) void {
        w.wanted_format = wanted;
    }

    /// The format new buffers are made in: the one wanted, if the shell
    /// takes it.
    pub fn bufferFormat(w: *const Window) vc4.Format {
        return if (w.tiled_formats.contains(w.wanted_format)) w.wanted_format else .xrgb8888;
    }

    fn pickBack(w: *Window) !usize {
        var out_of_memory_waits: u32 = 0;
        while (true) {
            // A free buffer of the right size; otherwise replace a free one
            // of the wrong size, or use an empty slot.
            var empty: ?usize = null;
            var stale: ?usize = null;
            for (&w.buffers, 0..) |*slot, i| {
                if (slot.*) |*b| {
                    if (b.busy or b.rendering) continue;
                    if (b.width == w.width and b.height == w.height and b.format == w.bufferFormat()) return i;
                    stale = i;
                } else empty = i;
            }
            if (stale) |i| {
                w.freeBuffer(&w.buffers[i].?, &w.buffers[i]);
                empty = i;
            }
            // A third buffer only for a frame in flight, and only while the
            // GPU's memory allows it; else that frame is shown, and this
            // one waits for a buffer as usual.
            if (empty != null and w.in_flight != null and !w.roomForAnotherBuffer()) {
                try w.finishInFlight();
                continue;
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
                    if (w.in_flight != null) {
                        try w.finishInFlight();
                        continue;
                    }
                    if (!busy) {
                        out_of_memory_waits += 1;
                        if (out_of_memory_waits > 40) return err;
                        try w.conn.dispatchTimeout(50);
                        continue;
                    }
                }
            }
            // All buffers are with the compositor (or the GPU): wait for a
            // release, having shown the frame in flight.
            if (w.in_flight != null) {
                try w.finishInFlight();
                continue;
            }
            try w.conn.dispatch();
        }
    }

    /// Frees the buffers the compositor does not have and no frame is
    /// being drawn into: while the window is covered, the memory is better
    /// used by the window in front.
    pub fn releaseSpareBuffers(w: *Window) void {
        for (&w.buffers, 0..) |*slot, i| if (slot.*) |*b| {
            if (b.busy or b.rendering or w.back == i) continue;
            w.freeBuffer(b, slot);
        };
    }

    /// Whether a buffer of the window's size can be made leaving a quarter
    /// of the GPU's memory free (for other apps, and the shell).
    fn roomForAnotherBuffer(w: *const Window) bool {
        const get = w.gpu.vtable.memory orelse return false;
        const mem = get(w.gpu.ptr) orelse return false;
        const size = vc4.texture.imageSizeOf(w.bufferFormat(), w.width, w.height);
        return mem[1] >= size + mem[0] / 4;
    }

    fn allocBuffer(w: *Window, slot: usize) !Buffer {
        const gpu = w.gpu;
        const format = w.bufferFormat();
        const bo = try gpu.vtable.createBo(gpu.ptr, vc4.texture.imageSizeOf(format, w.width, w.height));
        errdefer gpu.vtable.destroyBo(gpu.ptr, bo);
        const fd = try gpu.vtable.exportBo(gpu.ptr, bo.handle);
        const params = try w.conn.newObject(null);
        var m = try w.dmabuf.request(p.zwp_linux_dmabuf_v1.request.create_params);
        m.uint(params.id).end();
        const mod = p.modifier.broadcom_vc4_t_tiled;
        m = try params.request(p.zwp_linux_buffer_params_v1.request.add);
        m.fd(fd).uint(0).uint(0).uint(vc4.texture.tiledPitch(format, w.width, w.height)).uint(@truncate(mod >> 32)).uint(@truncate(mod)).end();
        const proxy = try w.conn.newObject(.{ .ptr = &w.buffers[slot], .handler = bufferEvent });
        m = try params.request(p.zwp_linux_buffer_params_v1.request.create_immed);
        m.uint(proxy.id).int(@intCast(w.width)).int(@intCast(w.height)).uint(format.fourcc()).uint(0).end();
        m = try params.request(p.zwp_linux_buffer_params_v1.request.destroy);
        m.end();
        return .{ .bo = bo, .proxy = proxy, .width = w.width, .height = w.height, .format = format };
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

    fn presentationEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wp_presentation.event.clock_id) {
            w.presentation_clock_id = r.uint() catch return;
        }
    }

    fn feedbackEvent(ptr: ?*anyopaque, d: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wp_presentation_feedback.event.sync_output => {
                _ = r.uint() catch return;
            },
            p.wp_presentation_feedback.event.presented => {
                defer d.forget(id);
                const tv_sec_hi = r.uint() catch return;
                const tv_sec_lo = r.uint() catch return;
                const tv_nsec = r.uint() catch return;
                const refresh = r.uint() catch return;
                const seq_hi = r.uint() catch return;
                const seq_lo = r.uint() catch return;
                const flags = r.uint() catch return;
                const secs = (@as(u64, tv_sec_hi) << 32) | tv_sec_lo;
                w.presented_ns = secs * std.time.ns_per_s + tv_nsec;
                if (refresh > 0) w.refresh_ns = refresh;
                w.presentation_seq = (@as(u64, seq_hi) << 32) | seq_lo;
                w.presentation_flags = flags;
                w.presented_frames += 1;
            },
            p.wp_presentation_feedback.event.discarded => {
                d.forget(id);
                w.discarded_frames += 1;
            },
            else => {},
        }
    }

    fn dmabufEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_linux_dmabuf_v1.event.modifier) return;
        const code = r.uint() catch return;
        const hi = r.uint() catch return;
        const lo = r.uint() catch return;
        if ((@as(u64, hi) << 32 | lo) != p.modifier.broadcom_vc4_t_tiled) return;
        if (vc4.Format.fromFourcc(code)) |f| w.tiled_formats.insert(f);
    }

    // --- Shell and input --------------------------------------------------------

    fn onDragEnter(ptr: ?*anyopaque, pos: [2]f32, _: ?[]const u8) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drag_enter = pos });
    }

    fn onDragMotion(ptr: ?*anyopaque, pos: [2]f32) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (w.input_len > 0 and w.input[w.input_len - 1] == .drag_motion) {
            w.input[w.input_len - 1] = .{ .drag_motion = pos };
            return;
        }
        w.pushInput(.{ .drag_motion = pos });
    }

    fn onDragLeave(ptr: ?*anyopaque) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.drag_leave);
    }

    fn onDragDrop(ptr: ?*anyopaque, pos: [2]f32, _: []const u8, _: []const u8, _: u32) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drop = pos });
    }

    fn textInputEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.zwp_text_input_v3.event.enter => {
                _ = r.uint() catch return;
                w.text_input_entered = true;
                if (w.text_input_enabled) if (w.text_input) |ti| {
                    w.sendTextInputState(ti, true);
                };
            },
            p.zwp_text_input_v3.event.leave => {
                _ = r.uint() catch return;
                w.text_input_entered = false;
                w.text_input_pending_preedit = null;
                w.text_input_pending_commit = null;
                w.text_input_pending_delete = null;
            },
            p.zwp_text_input_v3.event.preedit_string => {
                const text = (r.string() catch return) orelse "";
                const begin = r.int() catch return;
                const end = r.int() catch return;
                var pre: @TypeOf(w.text_input_pending_preedit.?) = .{ .cursor_begin = begin, .cursor_end = end };
                const n: u8 = @intCast(@min(text.len, pre.buf.len));
                @memcpy(pre.buf[0..n], text[0..n]);
                pre.len = n;
                w.text_input_pending_preedit = pre;
            },
            p.zwp_text_input_v3.event.commit_string => {
                const text = (r.string() catch return) orelse "";
                var com: @TypeOf(w.text_input_pending_commit.?) = .{};
                const n: u8 = @intCast(@min(text.len, com.buf.len));
                @memcpy(com.buf[0..n], text[0..n]);
                com.len = n;
                w.text_input_pending_commit = com;
            },
            p.zwp_text_input_v3.event.delete_surrounding_text => {
                const before = r.uint() catch return;
                const after = r.uint() catch return;
                w.text_input_pending_delete = .{ .before_length = before, .after_length = after };
            },
            p.zwp_text_input_v3.event.done => {
                _ = r.uint() catch return; // serial
                if (w.text_input_pending_delete) |del| {
                    w.text_input_pending_delete = null;
                    w.pushInput(.{ .text_delete_surrounding = .{ .before_length = del.before_length, .after_length = del.after_length } });
                }
                if (w.text_input_pending_commit) |com| {
                    w.text_input_pending_commit = null;
                    if (com.len > 0) {
                        var ev: InputEvent = .{ .text_commit = .{ .len = com.len } };
                        @memcpy(ev.text_commit.buf[0..com.len], com.buf[0..com.len]);
                        w.pushInput(ev);
                    }
                }
                if (w.text_input_pending_preedit) |pre| {
                    w.text_input_pending_preedit = null;
                    w.text_input_has_preedit = pre.len > 0;
                    var ev: InputEvent = .{ .text_preedit = .{ .len = pre.len, .cursor_begin = pre.cursor_begin, .cursor_end = pre.cursor_end } };
                    @memcpy(ev.text_preedit.buf[0..pre.len], pre.buf[0..pre.len]);
                    w.pushInput(ev);
                } else if (w.text_input_has_preedit) {
                    w.text_input_has_preedit = false;
                    w.pushInput(.{ .text_preedit = .{} });
                }
            },
            else => {},
        }
    }

    fn pushInput(w: *Window, e: InputEvent) void {
        // Coalesce motion; drop events if nobody is reading them.
        if (e == .motion and w.input_len > 0 and w.input[w.input_len - 1] == .motion) {
            w.input[w.input_len - 1] = e;
            return;
        }
        if (e == .touch_motion and w.input_len > 0) switch (w.input[w.input_len - 1]) {
            .touch_motion => |last| if (last.id == e.touch_motion.id) {
                w.input[w.input_len - 1] = e;
                return;
            },
            else => {},
        };
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
            if (w.cursor_shape_manager) |manager| {
                const device = d.newObject(null) catch return;
                m = manager.request(p.wp_cursor_shape_manager_v1.request.get_pointer) catch return;
                m.uint(device.id).uint(pointer.id).end();
                w.cursor_device = device;
            }
            if (w.relative_pointer_manager) |manager| {
                const rel = d.newObject(.{ .ptr = w, .handler = relativeEvent }) catch return;
                m = manager.request(p.zwp_relative_pointer_manager_v1.request.get_relative_pointer) catch return;
                m.uint(rel.id).uint(pointer.id).end();
                w.relative_pointer = rel;
            }
        }
        if (caps & p.wl_seat.capability.touch != 0 and w.touch == null) {
            const touch = d.newObject(.{ .ptr = w, .handler = touchEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_touch) catch return;
            m.uint(touch.id).end();
            w.touch = touch;
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
                const first = r.uint() catch return;
                if (opcode == p.wl_pointer.event.enter) {
                    _ = r.uint() catch return;
                    w.enter_serial = first;
                    w.buttons_down = 0;
                    // The shell shows an arrow until told otherwise.
                    w.cursor_shape = p.wp_cursor_shape_device_v1.shape.default;
                }
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                w.pointer_pos = .{ @floatCast(x), @floatCast(y) };
                w.updateCursor();
                w.pushInput(.{ .motion = w.pointer_pos });
            },
            p.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // time
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = state == p.wl_pointer.button_state.pressed;
                if (pressed) {
                    w.press_serial = serial;
                    w.clipboard.serial = serial;
                } else {
                    w.press_serial = 0;
                }
                // Pressing an edge resizes the window; the app does not
                // see it (nor its release: the shell has the pointer).
                if (pressed and code == evdev.btn_left) {
                    const edges = w.edgesAt(w.pointer_pos);
                    if (edges != 0) if (w.seat) |seat| {
                        var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                        m.uint(seat.id).uint(serial).uint(edges).end();
                        w.conn.flush() catch {};
                        return;
                    };
                }
                const bit = @as(u32, 1) << @intCast(@min(code -% evdev.btn_left, 31));
                w.buttons_down = if (pressed) w.buttons_down | bit else w.buttons_down & ~bit;
                if (!pressed and w.buttons_down == 0) w.updateCursor();
                w.pushInput(.{ .button = .{ .pos = w.pointer_pos, .code = code, .pressed = pressed } });
            },
            p.wl_pointer.event.axis => {
                _ = r.uint() catch return; // time
                const axis = r.uint() catch return;
                const value: f32 = @floatCast(r.fixed() catch return);
                const vertical = axis == p.wl_pointer.axis.vertical_scroll;
                w.pushInput(.{ .scroll = .{ .pos = w.pointer_pos, .dx = if (vertical) 0 else value, .dy = if (vertical) value else 0 } });
            },
            p.wl_pointer.event.leave => {
                w.buttons_down = 0;
                w.press_serial = 0;
                w.cursor_shape = null;
                w.pushInput(.leave);
            },
            else => {},
        }
    }

    fn touchEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_touch.event.down => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // time
                _ = r.uint() catch return; // surface: the window's
                const id: i32 = @bitCast(r.uint() catch return);
                const pos: [2]f32 = .{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) };
                // A touch can move (the title bar) or copy, as a press can.
                w.press_serial = serial;
                w.clipboard.serial = serial;
                // On an edge, it resizes the window, as a press does.
                const edges = w.edgesAt(pos);
                if (edges != 0) if (w.seat) |seat| {
                    var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                    m.uint(seat.id).uint(serial).uint(edges).end();
                    w.conn.flush() catch {};
                    return;
                };
                w.pushInput(.{ .touch_down = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.motion => {
                _ = r.uint() catch return; // time
                const id: i32 = @bitCast(r.uint() catch return);
                const pos: [2]f32 = .{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) };
                w.pushInput(.{ .touch_motion = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.up => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // time
                w.press_serial = 0;
                w.pushInput(.{ .touch_up = @bitCast(r.uint() catch return) });
            },
            p.wl_touch.event.cancel => {
                w.press_serial = 0;
                w.pushInput(.touch_cancel);
            },
            else => {},
        }
    }

    fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            // Key events carry evdev codes, which the toolkit maps itself:
            // only the layout's name is needed (Dazzle's shell names the
            // keymap's symbols after it).
            p.wl_keyboard.event.keymap => {
                _ = r.uint() catch return;
                const fd = r.fd() catch return;
                defer _ = linux.close(fd);
                const size = r.uint() catch return;
                if (keyboardFromKeymap(fd, size)) |k| w.layout = k;
            },
            p.wl_keyboard.event.key => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // time
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = state == p.wl_keyboard.key_state.pressed;
                // Copying (Ctrl+C) needs the key's serial.
                if (pressed) w.clipboard.serial = serial;
                if (code < 256) w.keys_down.setValue(code, pressed);
                if (pressed) {
                    if (!isModifierKey(code) and w.repeat_rate > 0) {
                        w.repeat = .{
                            .code = code,
                            .next_ns = sys.nowNs() + @as(u64, w.repeat_delay_ms) * std.time.ns_per_ms,
                        };
                    }
                } else if (w.repeat) |rep| {
                    if (rep.code == code) w.repeat = null;
                }
                w.pushInput(.{ .key = .{ .code = code, .pressed = pressed } });
            },
            p.wl_keyboard.event.leave => {
                w.repeat = null;
                var it = w.keys_down.iterator(.{});
                while (it.next()) |code| {
                    w.pushInput(.{ .key = .{ .code = @intCast(code), .pressed = false } });
                }
                w.keys_down = .empty;
            },
            p.wl_keyboard.event.repeat_info => {
                const rate = r.int() catch return;
                const delay = r.int() catch return;
                w.repeat_rate = @intCast(@max(rate, 0));
                w.repeat_delay_ms = @intCast(@max(delay, 0));
                if (w.repeat_rate == 0) w.repeat = null;
            },
            else => {},
        }
    }

    fn isModifierKey(code: u32) bool {
        return switch (code) {
            29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
            else => false,
        };
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

    fn decorationEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.dazzle_decoration_v1.event.corner_radius) w.corner_radius = r.uint() catch return;
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *Window = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.xdg_toplevel.event.configure => {
                w.next_size = .{ r.int() catch 0, r.int() catch 0 };
                const states = r.array() catch &.{};
                var suspended = false;
                var maximized = false;
                var fullscreen = false;
                var tiled = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
                    p.xdg_toplevel.state.suspended => suspended = true,
                    p.xdg_toplevel.state.maximized => maximized = true,
                    p.xdg_toplevel.state.fullscreen => fullscreen = true,
                    p.xdg_toplevel.state.tiled_left, p.xdg_toplevel.state.tiled_right, p.xdg_toplevel.state.tiled_top, p.xdg_toplevel.state.tiled_bottom => tiled = true,
                    else => {},
                };
                if (suspended) w.repeat = null;
                w.suspended = suspended;
                w.maximized = maximized;
                w.fullscreen = fullscreen;
                w.tiled = tiled;
            },
            p.xdg_toplevel.event.close => w.closed = true,
            else => {},
        }
    }
};

/// The layout a keymap is for, from its symbols' name (`xkb_symbols
/// "gb"`); null if it is not one Dazzle knows.
fn keyboardFromKeymap(fd: linux.fd_t, size: u32) ?locale.Keyboard {
    if (size == 0 or size > 1 << 20) return null;
    const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const text = @as([*]const u8, @ptrFromInt(rc))[0..size];
    defer _ = linux.munmap(text.ptr, size);
    return layoutNamed(text);
}

fn layoutNamed(keymap: []const u8) ?locale.Keyboard {
    const key = "xkb_symbols \"";
    const at = std.mem.indexOf(u8, keymap, key) orelse return null;
    const rest = keymap[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return locale.Keyboard.fromCode(rest[0..end]);
}

test "the layout is named in the keymap" {
    try std.testing.expectEqual(locale.Keyboard.gb, layoutNamed("xkb_keymap {\nxkb_symbols \"gb\" {\n").?);
    try std.testing.expect(layoutNamed("xkb_symbols \"pc+us+inet(evdev)\" {") == null);
    try std.testing.expect(layoutNamed("nothing") == null);
}

test "held keys repeat after the delay, except modifiers, and stop on release or leave" {
    var win: Window = .{
        .gpa = std.testing.allocator,
        .gpu = undefined,
        .conn = undefined,
        .clipboard = .{ .gpa = std.testing.allocator },
    };
    var disp: client.Display = undefined;

    // repeat_info: 25 keys/s (40 ms), 200 ms initial delay.
    const repeat_msg = [_]u32{ 25, 200 };
    var r_info = wire.Reader{ .data = std.mem.sliceAsBytes(&repeat_msg), .c = undefined };
    Window.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.repeat_info, &r_info);
    try std.testing.expectEqual(@as(u32, 25), win.repeat_rate);
    try std.testing.expectEqual(@as(u32, 200), win.repeat_delay_ms);

    // Modifiers (e.g. Shift = 42) do not arm key repeat.
    const shift_down = [_]u32{ 1, 0, 42, p.wl_keyboard.key_state.pressed };
    var r_shift = wire.Reader{ .data = std.mem.sliceAsBytes(&shift_down), .c = undefined };
    Window.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_shift);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    // Pressing a non-modifier key ('a' = 30) arms key repeat.
    const a_down = [_]u32{ 2, 0, 30, p.wl_keyboard.key_state.pressed };
    var r_a_down = wire.Reader{ .data = std.mem.sliceAsBytes(&a_down), .c = undefined };
    Window.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_down);
    try std.testing.expectEqual(@as(u32, 30), win.repeat.?.code);
    try std.testing.expectEqual(@as(usize, 1), win.takeInput().len);

    // Before the delay expires, serviceRepeat emits nothing.
    const first_due = win.repeat.?.next_ns;
    win.serviceRepeat(first_due - 1);
    try std.testing.expectEqual(@as(usize, 0), win.takeInput().len);
    try std.testing.expectEqual(@as(?u64, 1), win.repeatTimeoutMs(first_due - 1));

    // At the delay, it emits a press and schedules the next repeat 40 ms later.
    win.serviceRepeat(first_due);
    const rep1 = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), rep1.len);
    try std.testing.expectEqual(@as(u32, 30), rep1[0].key.code);
    try std.testing.expect(rep1[0].key.pressed);
    try std.testing.expectEqual(first_due + 40 * std.time.ns_per_ms, win.repeat.?.next_ns);

    // Releasing the key stops repeat.
    const a_up = [_]u32{ 3, 0, 30, p.wl_keyboard.key_state.released };
    var r_a_up = wire.Reader{ .data = std.mem.sliceAsBytes(&a_up), .c = undefined };
    Window.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_up);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    // Losing keyboard focus releases any held keys (such as Shift).
    const leave_msg = [_]u32{ 4, 1 };
    var r_leave = wire.Reader{ .data = std.mem.sliceAsBytes(&leave_msg), .c = undefined };
    Window.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.leave, &r_leave);
    const left = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqual(@as(u32, 42), left[0].key.code);
    try std.testing.expect(!left[0].key.pressed);
}
