//! Dazzle's windows (`app.Window`) as kete's: a `kete.window.Display` that
//! opens them, and the `kete.window.Window` each one is, giving kete its
//! input and its buffers to draw into with the vc4 renderer
//! (`renderer.zig`).
//!
//! It waits on kete's watched sources (a `Waker` from another thread,
//! images loaded) and on the app's own files (`Display.wakeOn`) as well
//! as the window's events.
//!
//! Not yet given to kete: the clipboard, input methods, drag and drop and
//! popups (menus are drawn in the window).

const std = @import("std");
const linux = std.os.linux;
const kete = @import("kete");
const vc4 = @import("vc4");
const app = @import("app");
const locale = @import("locale");
const renderer_mod = @import("renderer.zig");

const kwin = kete.window;
const kgfx = kete.gfx;

/// The keys whose state the window keeps, to know what a key types.
const key_left_shift = 42;
const key_right_shift = 54;
const key_left_ctrl = 29;
const key_right_ctrl = 97;
const key_right_alt = 100;
const key_caps_lock = 58;

/// Linux's mouse buttons.
const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;
const btn_side = 0x113;
const btn_extra = 0x114;

/// Sees Dazzle's input before kete does, and takes what it wants (true):
/// for a game that has the mouse, say (`Display.input_filter`).
pub const InputFilter = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, e: app.InputEvent) bool,

    pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), app.InputEvent) bool) InputFilter {
        const P = @TypeOf(ptr);
        return .{ .ctx = @ptrCast(ptr), .f = struct {
            fn call(ctx: *anyopaque, e: app.InputEvent) bool {
                return f(@as(P, @ptrCast(@alignCast(ctx))), e);
            }
        }.call };
    }
};

/// A key going down or up, for an app's own shortcuts (`Display.on_key`):
/// its Linux key code, and whether Control is held.
pub const KeyPress = struct {
    code: u32,
    pressed: bool,
    ctrl: bool,
};

pub const Window = struct {
    win: *app.Window,
    /// Its title, as kete set it (as much as fits).
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    /// What kete has been given of its input, converted from Dazzle's.
    input: std.ArrayList(kwin.InputEvent) = .empty,
    gpa: std.mem.Allocator,
    /// The modifiers held, and whether Caps Lock is on.
    shift: u2 = 0,
    ctrl: u2 = 0,
    altgr: bool = false,
    caps: bool = false,
    /// Not yet closed (`close`): `win` is gone once it is.
    open: bool = true,
    /// Who draws its title bar: kete, or no one (`Display.decorations`).
    drawn_by: kwin.WindowDecorations = .toolkit,
    /// The keyboard layout the app chose, rather than the system's
    /// (`Display.setKeyboard`).
    keyboard: ?locale.Keyboard = null,
    /// Where the pointer is (null if it is not over the window), and the
    /// last key pressed (a Linux key code): for an app that shows them.
    pointer: ?[2]f32 = null,
    last_key: ?u32 = null,
    /// Told of each key before kete is (`Display.on_key`).
    on_key: ?kete.ValueCallback(KeyPress) = null,
    /// Takes the input it wants before kete sees it (`Display.input_filter`).
    input_filter: ?InputFilter = null,
    /// The renderer: it draws the window's border, and when it leaves
    /// frames with the GPU, the frame it left is kept in flight
    /// (`Display.renderer`).
    renderer: ?*renderer_mod.Renderer = null,

    pub fn platform(_: *const Window) kwin.WindowPlatform {
        return .custom;
    }

    pub fn bufferTransport(_: *const Window) kwin.WindowBufferTransport {
        return .linux_dmabuf;
    }

    /// Dazzle's shell draws no decorations: kete draws the title bar (with
    /// no shadow: the buffers it is given have no frame), unless the app
    /// wants none.
    pub fn decorations(w: *const Window) kwin.WindowDecorations {
        return w.drawn_by;
    }

    pub fn bufferSync(_: *const Window) kwin.WindowBufferSync {
        return .implicit;
    }

    pub fn frameSync(_: *const Window) kwin.WindowFrameSync {
        return .{ .vsync = true, .frame_callback = true };
    }

    pub fn getTitle(w: *const Window) []const u8 {
        return w.title_buf[0..w.title_len];
    }

    pub fn setTitle(w: *Window, title: []const u8) void {
        w.keepTitle(title);
        w.win.setTitle(w.getTitle());
    }

    fn keepTitle(w: *Window, title: []const u8) void {
        var n = @min(title.len, w.title_buf.len);
        // Not cutting a character in two.
        while (n > 0 and n < title.len and title[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(w.title_buf[0..n], title[0..n]);
        w.title_len = n;
    }

    pub fn poll(w: *Window) !void {
        try w.win.poll();
    }

    pub fn wait(w: *Window, timeout_ns: u64) !void {
        // Finish the frame in flight before sleeping (none yet: frames are
        // rendered whole before they are shown).
        try w.win.finishInFlight();
        try w.win.wait(timeout_ns);
    }

    pub fn size(w: *const Window) [2]u32 {
        return .{ w.win.width, w.win.height };
    }

    pub fn getScale(_: *const Window) u32 {
        return 1;
    }

    pub fn takeCloseRequest(w: *Window) bool {
        return w.win.closed;
    }

    pub fn isSuspended(w: *const Window) bool {
        return w.win.suspended;
    }

    pub fn isMaximized(w: *const Window) bool {
        return w.win.maximized;
    }

    pub fn isFullscreen(w: *const Window) bool {
        return w.win.fullscreen;
    }

    /// Maximized or not, it has no corners or shadow of its own.
    pub fn isTiled(_: *const Window) bool {
        return true;
    }

    pub fn isFramePending(w: *const Window) bool {
        return w.win.frame_pending;
    }

    pub fn refreshNs(w: *const Window) u64 {
        return w.win.refresh_ns;
    }

    pub fn nextPresentationNs(w: *const Window, now_ns: u64) u64 {
        return w.win.nextPresentationNs(now_ns);
    }

    pub fn applyConfigure(w: *Window) !?[2]u32 {
        return w.win.applyConfigure();
    }

    pub fn releaseSpareBuffers(w: *Window) void {
        w.win.releaseSpareBuffers();
    }

    pub fn setCursor(w: *Window, cursor: kwin.PointerCursor) void {
        w.win.setCursor(cursorShape(cursor));
    }

    pub fn setMinSize(w: *Window, width: u32, height: u32) void {
        w.win.setMinSize(width, height);
    }

    pub fn setMaximized(w: *Window, on: bool) void {
        w.win.setMaximized(on);
    }

    pub fn setFullscreen(w: *Window, on: bool) void {
        w.win.setFullscreen(on);
    }

    pub fn startMove(w: *Window) void {
        w.win.startMove();
    }

    pub fn lockPointer(w: *Window) bool {
        return w.win.lockPointer();
    }

    pub fn unlockPointer(w: *Window) void {
        w.win.unlockPointer();
    }

    pub fn layout(w: *const Window) kwin.KeyboardLayout {
        const k = w.keyboard orelse w.win.layout;
        return .init(k.name(), @tagName(k));
    }

    /// The window's next buffer, for the vc4 renderer: its GEM handle (as
    /// the `id`), format and tiling.
    pub fn beginDmabufFrame(w: *Window) ?kgfx.DmabufTarget {
        const t = w.win.beginFrame() catch return null;
        // Not filling the work area or the screen, it has a border.
        if (w.renderer) |r| r.outline = !w.win.maximized and !w.win.fullscreen;
        return .{
            .id = t.handle,
            .fd = -1,
            .fourcc = t.format.fourcc(),
            .modifier = if (t.tiling == .linear) 0 else renderer_mod.tiled_modifier,
            .offset = 0,
            .stride = vc4.render.Target.pitch(t.format, t.width),
            .width = t.width,
            .height = t.height,
            .origin = .{ 0, 0 },
            .content = .{ t.width, t.height },
            .cpu = .{ .ctx = w, .begin = noCpu, .end = noCpuEnd },
        };
    }

    fn noCpu(_: *anyopaque) anyerror!kgfx.software.Image {
        return error.NoCpuAccess;
    }

    fn noCpuEnd(_: *anyopaque) void {}

    pub fn bufferAge(w: *const Window) u32 {
        return w.win.bufferAge();
    }

    /// Shows the frame the renderer drew, saying what changed in it; or,
    /// if the renderer left it with the GPU, keeps it in flight and shows
    /// the one before.
    pub fn showDamaged(w: *Window, damage: ?[]const kgfx.Viewport) !void {
        var vps: [kgfx.frame.Damage.max_rects]vc4.render.Viewport = undefined;
        const rects: ?[]const vc4.render.Viewport = if (damage) |d| if (d.len <= vps.len) blk: {
            for (d, vps[0..d.len]) |v, *o| o.* = renderer_mod.viewport(v);
            break :blk vps[0..d.len];
        } else null else null;
        if (w.renderer) |r| if (r.pending) |seqno| {
            r.pending = null;
            return w.win.submitted(seqno, rects);
        };
        return w.win.showDamaged(rects);
    }

    /// Dazzle's input since the last call, as kete's.
    pub fn takeInput(w: *Window) []const kwin.InputEvent {
        w.input.clearRetainingCapacity();
        for (w.win.takeInput()) |e| {
            if (w.input_filter) |f| if (f.f(f.ctx, e)) continue;
            const k = w.convert(e) orelse continue;
            w.input.append(w.gpa, k) catch break;
        }
        return w.input.items;
    }

    fn convert(w: *Window, e: app.InputEvent) ?kwin.InputEvent {
        switch (e) {
            .motion => |pos| w.pointer = pos,
            .button => |b| w.pointer = b.pos,
            .leave => w.pointer = null,
            .key => |k| if (k.pressed) {
                w.last_key = k.code;
            },
            else => {},
        }
        return switch (e) {
            .motion => |pos| .{ .motion = pos },
            .button => |b| .{ .button = .{ .pos = b.pos, .button = button(b.code), .pressed = b.pressed } },
            .key => |k| w.key(k.code, k.pressed),
            .scroll => |s| .{ .scroll = .{ .pos = s.pos, .dx = s.dx, .dy = s.dy } },
            .leave => .leave,
            .touch_down => |t| .{ .touch_down = .{ .id = t.id, .pos = t.pos } },
            .touch_motion => |t| .{ .touch_motion = .{ .id = t.id, .pos = t.pos } },
            .touch_up => |id| .{ .touch_up = id },
            .touch_cancel => .touch_cancel,
            .relative_motion => |d| .{ .relative_motion = d },
            .pointer_locked => |on| .{ .pointer_locked = on },
            .text_commit => |c| blk: {
                var o: kwin.InputEvent = .{ .text_commit = .{} };
                @memcpy(o.text_commit.buf[0..c.len], c.buf[0..c.len]);
                o.text_commit.len = c.len;
                break :blk o;
            },
            .text_preedit => |p| blk: {
                var o: kwin.InputEvent = .{ .text_preedit = .{ .cursor_begin = p.cursor_begin, .cursor_end = p.cursor_end } };
                @memcpy(o.text_preedit.buf[0..p.len], p.buf[0..p.len]);
                o.text_preedit.len = p.len;
                break :blk o;
            },
            .text_delete_surrounding => |d| .{ .text_delete_surrounding = .{ .before_length = d.before_length, .after_length = d.after_length } },
            .drag_enter => |pos| .{ .drag_enter = pos },
            .drag_motion => |pos| .{ .drag_motion = pos },
            .drag_leave => .drag_leave,
            .drop => |pos| .{ .drop = pos },
        };
    }

    /// A key, with what it types on the system's keyboard layout and the
    /// modifiers held.
    fn key(w: *Window, code: u32, pressed: bool) kwin.InputEvent {
        switch (code) {
            key_left_shift, key_right_shift => w.shift = if (pressed) w.shift +| 1 else w.shift -| 1,
            key_left_ctrl, key_right_ctrl => w.ctrl = if (pressed) w.ctrl +| 1 else w.ctrl -| 1,
            key_right_alt => w.altgr = pressed,
            key_caps_lock => if (pressed) {
                w.caps = !w.caps;
            },
            else => {},
        }
        const k = w.keyboard orelse w.win.layout;
        const shift = w.shift > 0;
        const ctrl = w.ctrl > 0;
        if (w.on_key) |f| f.call(.{ .code = code, .pressed = pressed, .ctrl = ctrl });
        return .{ .key = .{
            .key = kwin.evdev.keyOf(code),
            .pressed = pressed,
            .char = if (ctrl) null else k.char(code, shift, w.caps, w.altgr),
            .shift = shift,
            .ctrl = ctrl,
        } };
    }

    pub fn close(w: *Window) void {
        if (!w.open) return;
        w.open = false;
        w.input.deinit(w.gpa);
        w.win.close();
    }
};

fn button(code: u32) kwin.PointerButton {
    return switch (code) {
        btn_left => .left,
        btn_right => .right,
        btn_middle => .middle,
        btn_side => .back,
        btn_extra => .forward,
        else => .other,
    };
}

/// A kete cursor's `wp_cursor_shape_device_v1.shape` code (the arrow for
/// any Dazzle has no name for).
fn cursorShape(c: kwin.PointerCursor) u32 {
    const sh = app.CursorShape;
    return switch (c) {
        inline else => |tag| if (@hasDecl(sh, @tagName(tag))) @field(sh, @tagName(tag)) else sh.default,
    };
}

/// Opens Dazzle windows for kete: one, for now (each has a connection to
/// the shell of its own, which `poll` and `wait` are given to).
pub const Display = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    gpu: app.Gpu,
    environ: std.process.Environ,
    app_id: ?[]const u8 = null,
    window: ?Window = null,
    /// The app's files to wake for (`wakeOn`), and kete's sources (`watch`).
    wake_fds: [max_app_fds]?linux.fd_t = @splat(null),
    sources: [max_sources]?kwin.Source = @splat(null),
    /// Who draws its windows' title bars: kete (`.toolkit`), or no one
    /// (`.none`: an app with the whole screen).
    decorations: kwin.WindowDecorations = .toolkit,
    /// The keyboard layout to type with, if the app chooses it rather than
    /// the system (setup, before the system has one).
    keyboard: ?locale.Keyboard = null,
    /// Told of each key before kete is: for an app's shortcuts that work
    /// whatever has the keyboard (or nothing does).
    on_key: ?kete.ValueCallback(KeyPress) = null,
    /// Sees the input first, and takes what it wants from kete.
    input_filter: ?InputFilter = null,
    /// The renderer: it draws the windows' borders, and if it leaves
    /// frames with the GPU (see `Renderer.pipelined`), the windows keep its
    /// frame in flight.
    renderer: ?*renderer_mod.Renderer = null,

    const max_app_fds = app.window.max_wake_fds - max_sources;
    const max_sources = 3;

    /// Wakes the app's loop (`kete.App.step` returns) when `fd` can be
    /// read, or no longer (`on` false). False if there is no room for it.
    pub fn wakeOn(d: *Display, fd: linux.fd_t, on: bool) bool {
        defer d.syncWake();
        for (&d.wake_fds) |*slot| if (slot.* == fd) {
            if (!on) slot.* = null;
            return true;
        };
        if (!on) return true;
        for (&d.wake_fds) |*slot| if (slot.* == null) {
            slot.* = fd;
            return true;
        };
        return false;
    }

    /// Types with `k` rather than the system's layout (null: the system's).
    pub fn setKeyboard(d: *Display, k: ?locale.Keyboard) void {
        d.keyboard = k;
        if (d.openWindowOrNull()) |w| w.keyboard = k;
    }

    /// kete's sources to wait on (and read when they can be).
    pub fn watch(d: *Display, source: kwin.Source, on: bool) void {
        defer d.syncWake();
        for (&d.sources) |*slot| if (slot.*) |s| if (s.eql(source)) {
            if (!on) slot.* = null;
            return;
        };
        if (!on) return;
        for (&d.sources) |*slot| if (slot.* == null) {
            slot.* = source;
            return;
        };
    }

    /// Gives the window the files to wake for.
    fn syncWake(d: *Display) void {
        const w = d.openWindowOrNull() orelse return;
        var fds: [app.window.max_wake_fds]?linux.fd_t = @splat(null);
        var n: usize = 0;
        for (d.wake_fds) |fd| if (fd) |f| {
            fds[n] = f;
            n += 1;
        };
        for (d.sources) |src| if (src) |s| {
            fds[n] = s.fd;
            n += 1;
        };
        w.win.wake_fds = fds;
    }

    /// Reads the sources that can be read, giving them what they read.
    fn serviceSources(d: *Display) void {
        for (d.sources) |src| if (src) |s| {
            var pfd = [1]linux.pollfd{.{ .fd = s.fd, .events = linux.POLL.IN, .revents = 0 }};
            if (linux.poll(&pfd, 1, 0) != 1) continue;
            const op = s.read(s.ctx) orelse continue;
            const result = d.io.operate(op) catch continue;
            s.done(s.ctx, result);
        };
    }

    pub fn platform(_: *const Display) kwin.WindowPlatform {
        return .custom;
    }

    pub fn display(d: *Display) kwin.Display {
        return .of(d);
    }

    pub fn openWindow(d: *Display, o: struct {
        title: []const u8,
        size: [2]?u32 = .{ null, null },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
    }) !*Window {
        if (d.window) |*w| if (w.open) return error.OneWindowOnly;
        var options: app.Window.Options = .{
            .title = o.title,
            .app_id = d.app_id,
            .min_size = o.min_size,
            .maximized = o.maximized,
        };
        for (o.size, &options.size) |given, *side| if (given) |v| {
            side.* = v;
        };
        const win = try app.Window.open(d.gpa, d.gpu, d.environ, options);
        d.window = .{ .win = win, .gpa = d.gpa, .drawn_by = d.decorations, .keyboard = d.keyboard, .on_key = d.on_key, .input_filter = d.input_filter, .renderer = d.renderer };
        if (d.renderer) |r| if (r.pipelined) try win.setPipelined(true);
        d.window.?.keepTitle(o.title);
        d.syncWake();
        return &d.window.?;
    }

    /// The window, if it is open.
    fn openWindowOrNull(d: *Display) ?*Window {
        const w = &(d.window orelse return null);
        return if (w.open) w else null;
    }

    pub fn poll(d: *Display) !void {
        if (d.openWindowOrNull()) |w| try w.poll();
        d.serviceSources();
    }

    pub fn wait(d: *Display, timeout_ns: u64) !void {
        if (d.openWindowOrNull()) |w| try w.wait(timeout_ns);
        d.serviceSources();
    }
};
