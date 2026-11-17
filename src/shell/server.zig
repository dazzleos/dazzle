//! The shell's Wayland server: clients, their objects, and the protocol.
//!
//! Supported globals: wl_compositor (surfaces; regions are accepted and
//! ignored), wl_subcompositor (subsurfaces, drawn above their parent),
//! wl_shm (ARGB8888, XRGB8888 and RGB565, copied to the GPU at commit),
//! zwp_linux_dmabuf_v1 (buffers in the VideoCore IV's T-tiled layout, in
//! the same formats, used by the GPU directly), xdg_wm_base (toplevel windows, and popups above
//! them: see `Popup`), wl_output (the screen), wl_seat (a pointer, a
//! touch device, and a keyboard with an XKB keymap for the chosen layout:
//! see keyboard.zig), wp_cursor_shape_manager_v1 (the pointer's picture, by
//! name), zwp_pointer_constraints_v1 and zwp_relative_pointer_manager_v1
//! (pointer lock and relative motion), and wl_data_device_manager (copy and
//! paste: see `setSelection`; drag and drop: see `startDrag`).
//!
//! Windows go anywhere on the screen, the shell's dock drawn over them,
//! but maximized and tiled ones stay in the work area above the dock:
//! restored (as they start, at the size the client chooses when told 0 by
//! 0, in the middle of the work area; or, restored from maximized without
//! one, half the work area), or maximized (filling the work area),
//! where the client can move them with xdg_toplevel.move (dragging its
//! title bar) and resize with xdg_toplevel.resize (dragging an edge), no
//! smaller than the size it asks for with xdg_toplevel.set_min_size, nor
//! bigger than the screen. While a window is resized, it is told a new
//! size only once it has drawn at the last one, so a slow client is not
//! sent sizes it cannot keep up with. Clients choose the pointer's picture
//! over their windows with wp_cursor_shape_v1 (an arrow, or a resize).
//! A window can also fill the whole screen, over the dock
//! (xdg_toplevel.set_fullscreen): the dock is hidden while it is on top.
//! A window being moved to the work area's left or right edge fills that
//! half when let go (xdg_toplevel's tiled states), and to its top edge,
//! all of it; what it will fill is shown, shaded, under it meanwhile.
//! Moved from there, it is restored under the pointer.
//! A surface can be shown at a size other than its buffer's (wp_viewport's
//! destination; its source, a part of the buffer, is not supported): an
//! app draws a smaller buffer to draw faster, and it is stretched, by the
//! GPU, or by the display when it is shown directly.
//! A window whose client asks (dazzle_decoration_manager_v1, Dazzle's
//! own) is drawn with rounded corners and a shadow, unless it is square
//! against the edges (maximized, fullscreen or tiled); the client is told
//! the radius, to draw its border to match. Other clients' windows are
//! drawn as they are.
//! They are stacked most recently mapped (or raised, or clicked) on top,
//! and the top one has the keyboard. Windows hidden behind others are
//! covered: they get xdg_toplevel's suspended state, their frame callbacks
//! wait until they can be seen again, and what they commit meanwhile does
//! not make the shell draw a frame. In the overview (Super, tapped) every
//! window is drawn smaller, side by side in the work area, without being
//! told, for one to be picked (`setOverview`). The server does not draw: it keeps the
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
const evdev = @import("sys").evdev;
const linux = std.os.linux;
const wayland = @import("wayland");
const vc4 = @import("vc4");
const wire = wayland.wire;
const p = wayland.protocol;

const keyboard = @import("keyboard.zig");
const locale = @import("locale");
const placement = @import("placement.zig");

const log = std.log.scoped(.shell);

pub const Texture = struct {
    /// The renderer's handle for the texture.
    handle: u32,
    width: u32,
    height: u32,
    format: vc4.Format = .xrgb8888,
    /// ETC1 compressed (the desktop's background), not `format`.
    compressed: bool = false,
};

/// The formats clients' buffers can be in, and wl_shm's codes for them
/// (dma-bufs use their DRM codes).
const buffer_formats = [_]vc4.Format{ .argb8888, .xrgb8888, .rgb565 };

fn shmCode(f: vc4.Format) u32 {
    return switch (f) {
        .argb8888 => p.wl_shm.format.argb8888,
        .xrgb8888 => p.wl_shm.format.xrgb8888,
        .rgb565 => p.wl_shm.format.rgb565,
        .a8, .rgba4444 => unreachable, // textures only
    };
}

fn fromShmCode(code: u32) ?vc4.Format {
    for (buffer_formats) |f| if (shmCode(f) == code) return f;
    return null;
}

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Imports a T-tiled dma-buf as a texture. Takes ownership of `fd`.
        importDmabuf: *const fn (ptr: *anyopaque, fd: linux.fd_t, width: u32, height: u32, format: vc4.Format) anyerror!Texture,
        /// Copies pixels (rows `stride` bytes apart) into a texture, reusing
        /// `existing` if it has the same size and format.
        uploadPixels: *const fn (ptr: *anyopaque, existing: ?Texture, pixels: []const u8, width: u32, height: u32, stride: u32, format: vc4.Format) anyerror!Texture,
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
    .{ .name = p.zwp_pointer_constraints_v1.name, .version = p.zwp_pointer_constraints_v1.version },
    .{ .name = p.zwp_relative_pointer_manager_v1.name, .version = p.zwp_relative_pointer_manager_v1.version },
    .{ .name = p.wp_presentation.name, .version = p.wp_presentation.version },
    .{ .name = p.zwp_text_input_manager_v3.name, .version = p.zwp_text_input_manager_v3.version },
    .{ .name = p.dazzle_decoration_manager_v1.name, .version = p.dazzle_decoration_manager_v1.version },
    .{ .name = p.wp_viewporter.name, .version = p.wp_viewporter.version },
};

/// The radius of the corners of windows the shell rounds (those whose
/// clients ask, with dazzle_decoration_v1), and of their shadow.
pub const corner_radius = 12;

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
    region: *Region,
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
    data_device_manager: u32,
    data_source: *DataSource,
    data_device: u32,
    data_offer: *DataOffer,
    pointer_constraints,
    locked_pointer: *PointerLock,
    confined_pointer: *PointerLock,
    relative_pointer_manager,
    /// With the version bound (1), for `broadcast`.
    relative_pointer: u32,
    presentation,
    presentation_feedback,
    text_input_manager,
    text_input: *TextInput,
    decoration_manager,
    viewporter,
    viewport: *Viewport,
    decoration: *Decoration,
};

/// A window on its way to its place after its state changed (maximized,
/// say): from where it was, `k` of the way (eased), since its first frame;
/// what it showed before fading out over what it shows now.
pub const StateAnim = struct {
    from: Rect,
    start_ns: ?u64 = null,
    k: f32 = 0,
    old: ?OldFrame = null,
};

/// What a window's surface showed before its state changed, kept while
/// it fades out: a dmabuf held from its client (`buffer`), or a copy the
/// shell owns. Where it was relative to the window (at `from`), its
/// logical size and transform, and its corners' radius.
pub const OldFrame = struct {
    texture: Texture,
    buffer: ?*Buffer = null,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    transform: u3 = 0,
    radius: u32 = 0,
};

/// What a surface's size is to be, from its next commit.
pub const Destination = union(enum) { none, size: [2]u32 };

/// A surface's wp_viewport. Outlives its surface (without it) until
/// destroyed.
pub const Viewport = struct {
    id: u32,
    surface: ?*Surface,
};

/// A toplevel's dazzle_decoration_v1: the shell rounds its corners and
/// draws its shadow. Outlives the toplevel (without it) until destroyed.
pub const Decoration = struct {
    id: u32,
    toplevel: ?*Toplevel,
};

/// Something that takes keys before clients: `key` returns whether it took
/// the key (a Linux key code), after the modifiers have noted it.
pub const InputMethodHook = struct {
    ctx: *anyopaque,
    key: *const fn (ctx: *anyopaque, s: *Server, key: u32, pressed: bool) bool,
};

pub const TextInput = struct {
    client: *Client,
    id: u32,
    /// Number of `commit` requests received on this object (sent in `done`).
    serial: u32 = 0,
    enabled: bool = false,
    surrounding_text: []u8 = &.{},
    cursor: i32 = 0,
    anchor: i32 = 0,
    change_cause: u32 = p.zwp_text_input_v3.change_cause.input_method,
    content_hint: u32 = p.zwp_text_input_v3.content_hint.none,
    content_purpose: u32 = p.zwp_text_input_v3.content_purpose.normal,
    cursor_rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    pending: Pending = .{},

    pub const Pending = struct {
        enabled: bool = false,
        surrounding_text: ?[]u8 = null,
        cursor: i32 = 0,
        anchor: i32 = 0,
        change_cause: u32 = p.zwp_text_input_v3.change_cause.input_method,
        content_hint: u32 = p.zwp_text_input_v3.content_hint.none,
        content_purpose: u32 = p.zwp_text_input_v3.content_purpose.normal,
        cursor_rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
};

pub const RegionOp = struct {
    subtract: bool = false,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Region = struct {
    ops: std.ArrayList(RegionOp) = .empty,

    pub fn contains(ops: []const RegionOp, x: i32, y: i32) bool {
        var in = false;
        for (ops) |op| {
            if (op.width > 0 and op.height > 0 and x >= op.x and y >= op.y and x -| op.x < op.width and y -| op.y < op.height) {
                in = !op.subtract;
            }
        }
        return in;
    }

    pub fn bounds(ops: []const RegionOp) ?Rect {
        var x0: i32 = std.math.maxInt(i32);
        var y0: i32 = std.math.maxInt(i32);
        var x1: i32 = std.math.minInt(i32);
        var y1: i32 = std.math.minInt(i32);
        var any = false;
        for (ops) |op| {
            if (op.subtract or op.width <= 0 or op.height <= 0) continue;
            x0 = @min(x0, op.x);
            y0 = @min(y0, op.y);
            x1 = @max(x1, op.x +| op.width);
            y1 = @max(y1, op.y +| op.height);
            any = true;
        }
        if (!any or x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
    }
};

/// A client's wish to have the pointer locked in place or confined over a
/// surface (zwp_locked_pointer_v1 / zwp_confined_pointer_v1). It takes
/// effect while the pointer is over the surface (and inside `region`, if
/// set) and its window is on top.
pub const PointerLock = struct {
    client: *Client,
    id: u32,
    /// Null once the surface has been destroyed.
    surface: ?*Surface,
    /// True for a locked pointer; false for a confined pointer.
    lock: bool = true,
    /// Takes effect again after it ends (lifetime persistent); otherwise
    /// only once.
    persistent: bool,
    /// Ended, and not persistent: it will not take effect again.
    spent: bool = false,
    /// Optional constraint region (null = entire surface input region).
    region: ?[]RegionOp = null,
    pending_region: ?[]RegionOp = null,
    pending_region_set: bool = false,
    /// Cursor position hint for a locked pointer, in surface coordinates.
    hint: ?[2]f64 = null,
    pending_hint: ?[2]f64 = null,
};

/// What a client offers to paste or drag, as MIME types. The clipboard
/// (the selection) and a drag each hold at most one at a time.
pub const DataSource = struct {
    client: *Client,
    id: u32,
    version: u32 = 1,
    mime_types: std.ArrayList([]u8) = .empty,
    /// Drag-and-drop actions set by wl_data_source.set_actions.
    actions: ?u32 = null,
    /// The last negotiated action sent to this source.
    action: u32 = 0,
    action_sent: bool = false,
    /// Used for the selection or a drag: cannot be used again.
    used: bool = false,
};

/// What the clipboard or a drag holds, as offered to a client: what it
/// can ask for (`receive`). `source` is null once the source has gone.
pub const DataOffer = struct {
    client: *Client,
    id: u32,
    version: u32 = 1,
    source: ?*DataSource,
    /// True for a drag-and-drop offer; false for a clipboard offer.
    dnd: bool = false,
    /// True while this offer is the active drag offer (or dropped and
    /// awaiting `finish`).
    active: bool = false,
    /// True once `wl_data_device.drop` has been sent on this offer.
    dropped: bool = false,
    /// True once `wl_data_offer.finish` has been called.
    finished: bool = false,
    /// Whether a non-null MIME type has been accepted.
    accepted: bool = false,
    /// Drag-and-drop actions and preferred action set by `set_actions`.
    actions: u32 = 0,
    preferred_action: u32 = 0,
    /// The last negotiated action sent to this offer.
    action: u32 = 0,
    action_sent: bool = false,
};

pub const Surface = struct {
    client: *Client,
    id: u32,
    pending_buffer: ?*Buffer = null,
    pending_attach: bool = false,
    pending_callbacks: std.ArrayList(u32) = .empty,
    /// Frame callbacks committed while the window was covered.
    held_callbacks: std.ArrayList(u32) = .empty,
    /// `wp_presentation_feedback` object IDs awaiting `wl_surface.commit`.
    pending_feedback: std.ArrayList(u32) = .empty,
    pending_scale: ?u32 = null,
    scale: u32 = 1,
    /// Its size, if not its buffer's (wp_viewport's destination), and a new
    /// one (or none: `.none`) to take when it is next committed.
    destination: ?[2]u32 = null,
    pending_destination: ?Destination = null,
    viewport: ?*Viewport = null,
    pending_transform: ?u3 = null,
    transform: u3 = 0,
    pending_input_region: ?[]RegionOp = null,
    pending_input_region_set: bool = false,
    input_region: ?[]RegionOp = null,
    pending_opaque_region: ?[]RegionOp = null,
    pending_opaque_region_set: bool = false,
    opaque_region: ?[]RegionOp = null,
    /// The dmabuf buffer being shown, if any.
    buffer: ?*Buffer = null,
    /// A copy of the last shm buffer, owned by the surface.
    copy: ?Texture = null,
    xdg: ?*XdgSurface = null,
    /// Its place in its parent, if it is a subsurface.
    sub: ?*Subsurface = null,
    /// Used as a drag-and-drop icon (wl_data_device.start_drag).
    drag_icon: bool = false,
    /// Used as a pointer cursor (wl_pointer.set_cursor).
    cursor_role: bool = false,
    /// Its subsurfaces, bottom first, drawn above it.
    subsurfaces: std.ArrayList(*Subsurface) = .empty,
    /// Told it is on the output (wl_surface.enter).
    entered: bool = false,

    pub fn texture(s: *const Surface) ?Texture {
        if (s.buffer) |b| return b.dmabuf;
        return s.copy;
    }

    /// Logical surface dimensions after applying buffer transform and scale.
    pub fn size(s: *const Surface) ?[2]u32 {
        const tex = s.texture() orelse return null;
        if (s.destination) |d| return d;
        const bw = if (s.transform & 1 != 0) tex.height else tex.width;
        const bh = if (s.transform & 1 != 0) tex.width else tex.height;
        return .{ @max(bw / s.scale, 1), @max(bh / s.scale, 1) };
    }

    /// Its buffer's size, in pixels (as it is in the buffer: before its
    /// transform).
    pub fn bufferSize(s: *const Surface) ?[2]u32 {
        const tex = s.texture() orelse return null;
        return .{ tex.width, tex.height };
    }

    pub fn hasRole(s: *const Surface) bool {
        return s.xdg != null or s.sub != null or s.drag_icon or s.cursor_role;
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
    shm: ?struct { pool: *ShmPool, offset: u32, stride: u32, format: vc4.Format } = null,
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
    /// In synchronized mode, commits to the subsurface are cached until the
    /// parent commits (or `set_desync` is called).
    sync: bool = false,
    cached: CachedState = .{},

    pub const CachedState = struct {
        has_state: bool = false,
        attach: bool = false,
        buffer: ?*Buffer = null,
        callbacks: std.ArrayList(u32) = .empty,
        feedback: std.ArrayList(u32) = .empty,
        scale: ?u32 = null,
        transform: ?u3 = null,
        input_region: ?[]RegionOp = null,
        input_region_set: bool = false,
        opaque_region: ?[]RegionOp = null,
        opaque_region_set: bool = false,
    };
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
    /// Optional window geometry set by `xdg_surface.set_window_geometry`.
    pending_geometry: ?Rect = null,
    geometry: ?Rect = null,
};

/// A half of the work area a window can fill.
pub const Tile = enum { left, right };

/// Where a window dragged to an edge goes when it is let go: filling the
/// work area (the top edge), or half of it (the left or right).
pub const Snap = enum { maximize, left, right };

pub const Toplevel = struct {
    xdg: *XdgSurface,
    id: u32,
    parent: ?*Toplevel = null,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    app_id_buf: [64]u8 = undefined,
    app_id_len: usize = 0,
    mapped: bool = false,
    /// Covered by other windows, and told so (see `Server.updateCovered`).
    suspended: bool = false,
    /// Told it has the keyboard (it is the top window).
    activated: bool = true,
    capabilities_sent: bool = false,
    /// Filling the work area; otherwise restored, at `x`, `y` on the screen.
    /// A window starts restored, at the size its client chooses (see
    /// `placeFirst`).
    maximized: bool = false,
    /// Filling the whole screen, over the dock (whether maximized or not
    /// is kept for when it leaves fullscreen).
    fullscreen: bool = false,
    /// Maximized and fullscreen as it is shown: as it last drew, after
    /// being told. Until it draws as it is now told, its last frame stays
    /// where it was, rather than showing where the next one will go.
    shown_maximized: bool = false,
    shown_fullscreen: bool = false,
    /// Filling the left or right half of the work area (dragged to that
    /// edge), and as it is shown; maximized and fullscreen come first.
    tiled: ?Tile = null,
    shown_tiled: ?Tile = null,
    /// Its client asked for rounded corners and a shadow.
    decoration: ?*Decoration = null,
    /// Maximized, fullscreen, tiled or restored, just now: what it shows
    /// is drawn on its way from where it was (`Server.animateWindows`).
    anim: ?StateAnim = null,
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

    /// The radius its corners are drawn with, as it is shown: rounded if
    /// its client asked, unless it is square against the work area's or
    /// screen's edges.
    pub fn shownRadius(t: *const Toplevel) u32 {
        if (t.decoration == null or t.shown_maximized or t.shown_fullscreen or t.shown_tiled != null) return 0;
        return corner_radius;
    }

    /// The radius it is told to draw for, in its next configure.
    fn toldRadius(t: *const Toplevel) u32 {
        if (t.decoration == null or t.maximized or t.fullscreen or t.tiled != null) return 0;
        return corner_radius;
    }

    /// Told to be maximized, fullscreen, tiled or restored, and not yet
    /// shown so.
    fn stateChanging(t: *const Toplevel) bool {
        return t.shown_maximized != t.maximized or t.shown_fullscreen != t.fullscreen or t.shown_tiled != t.tiled;
    }

    /// Mapped, with something to show.
    fn shown(t: *const Toplevel) bool {
        return t.mapped and t.xdg.surface != null and t.xdg.surface.?.texture() != null;
    }

    pub fn title(t: *const Toplevel) []const u8 {
        return t.title_buf[0..t.title_len];
    }

    pub fn appId(t: *const Toplevel) []const u8 {
        return t.app_id_buf[0..t.app_id_len];
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
    /// Readable once its process has ended: its socket may outlive it (a
    /// child it forked has it too), but its windows should not.
    pidfd: ?linux.fd_t = null,
    /// IDs for objects the server makes (data offers).
    next_server_id: u32 = 0xff000000,
    /// Last ping serial sent on `xdg_wm_base.ping`, and whether it was ponged.
    ping_serial: u32 = 0,
    ponged: bool = false,

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
const PresentationFeedback = struct { client: *Client, id: u32, surface: ?*Surface = null };

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
    /// The shell's own parts of the screen, over the windows (the dock,
    /// its quick settings): the pointer there is the shell's, not a
    /// window's (none has it, and the shell picks its cursor).
    shell_areas: [2]?Rect = @splat(null),
    serial: u32 = 0,
    /// Something visible changed since the last frame.
    damaged: bool = true,
    /// The overview (Super, tapped): every window drawn smaller, side by
    /// side in the work area (`overviewLayout`), for one to be picked. The
    /// windows are not told their size changed: only how they are drawn
    /// does, and they have neither the pointer nor the keyboard meanwhile.
    overview: bool = false,
    /// Where the window being moved goes if it is let go now (the pointer
    /// is at an edge of the work area); shown, shaded, under it.
    snap: ?Snap = null,
    /// How far into the overview the windows are drawn: 0 where they are,
    /// 1 in their places in it; between, on their way in or out (see
    /// `animateOverview`).
    overview_t: f32 = 0,
    /// The way in or out under way: when it started (from the next
    /// `animateOverview`, if not yet), and from where.
    overview_anim: ?struct { start_ns: ?u64 = null, from: f32 } = null,
    /// The windows' order in the overview (the top one first), fixed as it
    /// starts, so that one picked does not change places on its way back.
    overview_order: [32]*Toplevel = undefined,
    overview_n: usize = 0,
    /// Frame callbacks for the next frame drawn.
    frame_callbacks: std.ArrayList(FrameCallback) = .empty,
    /// Frame callbacks for the frame drawn and waiting to reach the screen.
    presenting: std.ArrayList(FrameCallback) = .empty,
    /// Presentation feedback objects for the next frame drawn.
    frame_feedback: std.ArrayList(PresentationFeedback) = .empty,
    /// Presentation feedback objects for the frame drawn and waiting to reach the screen.
    presenting_feedback: std.ArrayList(PresentationFeedback) = .empty,
    /// Monotonically increasing presented frame counter (`wp_presentation_feedback`).
    present_seq: u64 = 0,
    /// Where the pointer is on the screen.
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    /// The keyboard's layout (its keymap is sent to clients).
    keyboard_layout: locale.Keyboard = .us,
    /// The surfaces with pointer and keyboard focus.
    pointer_focus: ?*Surface = null,
    keyboard_focus: ?*Surface = null,
    /// The serial and position of the last button press, and the bitmask
    /// of buttons currently down.
    press_serial: u32 = 0,
    press_x: f64 = 0,
    press_y: f64 = 0,
    buttons_down: u32 = 0,
    /// The window the pointer is moving (with the pointer's offset from
    /// its corner) or resizing. The pointer focuses on no surface
    /// meanwhile.
    grab: ?Grab = null,
    /// The pointer is over a window's resize border (its outer pixel and
    /// into its shadow; see `edgeAt`): the window and its edges. A press
    /// there resizes it, and no client has the pointer meanwhile.
    edge_hover: ?EdgeHit = null,
    /// The pointer's picture the client under it chose (an arrow until it
    /// does), or a custom cursor surface set by `wl_pointer.set_cursor`.
    client_cursor: Cursor = .arrow,
    cursor_surface: ?*Surface = null,
    cursor_hotspot: [2]i32 = .{ 0, 0 },
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
    /// A drag-and-drop operation in progress.
    drag: ?Drag = null,
    /// The screen.
    output: Output = .{},
    /// The popups shown, bottom first.
    popups: std.ArrayList(*Popup) = .empty,
    /// The keyboard's modifiers.
    modifiers: keyboard.Modifiers = .{},
    /// The system's input method (see ime.zig): offered each key before
    /// the client with the keyboard, which does not get what it takes.
    input_method: ?InputMethodHook = null,
    /// Pointer locks asked for, and the one in effect.
    locks: std.ArrayList(*PointerLock) = .empty,
    active_lock: ?*PointerLock = null,

    /// A move or resize: by the pointer, or by a touch (`touch`: its ID).
    /// A window moved or resized. A maximized or tiled window being moved
    /// stays as it is (`unsnap`) until the pointer has gone `unsnap_after`
    /// from where it was pressed (`x`, `y`), then is restored under it.
    const Grab = struct { t: *Toplevel, dx: f64, dy: f64, resize: ?Resize = null, touch: ?i32 = null, unsnap: bool = false, x: f64 = 0, y: f64 = 0 };

    /// How far a maximized or tiled window is dragged before it is
    /// restored, and how near an edge of the work area the pointer is for
    /// a window dragged there to fill it (or half of it).
    const unsnap_after = 12;
    const snap_edge = 6;

    /// A drag-and-drop operation: by the pointer, or by a touch (`touch`:
    /// its ID).
    const Drag = struct {
        client: *Client,
        source: ?*DataSource,
        icon: ?*Surface,
        touch: ?i32 = null,
        focus: ?*Surface = null,
        offer: ?*DataOffer = null,
    };

    /// A touch on a surface: its events go to the surface it went down on
    /// (null once that has gone, or the touch is the shell's, moving a
    /// window).
    pub const TouchPoint = struct { id: i32, surface: ?*Surface, press_x: f64, press_y: f64, x: f64, y: f64 };

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

    /// A window's resize border, as GTK has it: from its outer pixel out
    /// into its shadow this far, the corners this far along its sides.
    pub const resize_handle = 12;
    pub const resize_corner = 24;

    /// A window's edges under the pointer.
    pub const EdgeHit = struct { t: *Toplevel, edges: u32 };

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
        s.frame_feedback.deinit(s.gpa);
        s.presenting_feedback.deinit(s.gpa);
        s.offers.deinit(s.gpa);
        s.popups.deinit(s.gpa);
        s.locks.deinit(s.gpa);
    }

    /// Adds a client connected on `fd`.
    pub fn addClient(s: *Server, fd: linux.fd_t) !*Client {
        const c = try s.gpa.create(Client);
        c.* = .{ .server = s, .conn = .init(fd), .pid = peerPid(fd) };
        errdefer s.gpa.destroy(c);
        if (c.pid) |pid| if (pid != linux.getpid()) {
            const rc = linux.pidfd_open(pid, 0);
            if (linux.errno(rc) == .SUCCESS) c.pidfd = @intCast(rc);
        };
        errdefer if (c.pidfd) |pf| {
            _ = linux.close(pf);
        };
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

    /// The client whose process `pidfd` follows ended: it goes, with its
    /// windows, even if its socket is still open. Returns whether it was
    /// still connected.
    pub fn clientExited(s: *Server, pidfd: linux.fd_t) bool {
        for (s.clients.items) |c| if (c.pidfd == pidfd) {
            s.removeClient(c);
            return true;
        };
        return false;
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
        for ([_]*std.ArrayList(PresentationFeedback){ &s.frame_feedback, &s.presenting_feedback }) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].client == c) _ = list.swapRemove(i) else i += 1;
            }
        }
        c.objects.deinit(s.gpa);
        c.conn.deinit();
        if (c.pidfd) |pf| _ = linux.close(pf);
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
            .region => |reg| s.destroyRegion(reg),
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
            .locked_pointer, .confined_pointer => |lock| s.destroyLock(lock),
            .text_input => |ti| s.destroyTextInput(ti),
            .decoration => |d| s.destroyDecoration(d),
            .viewport => |v| s.destroyViewport(v),
            else => {},
        }
    }

    fn destroyDecoration(s: *Server, d: *Decoration) void {
        if (d.toplevel) |t| {
            t.decoration = null;
            s.damaged = true;
        }
        s.gpa.destroy(d);
    }

    /// A surface's viewport goes: its size is its buffer's again, from its
    /// next commit.
    fn destroyViewport(s: *Server, v: *Viewport) void {
        if (v.surface) |surf| {
            surf.viewport = null;
            surf.pending_destination = .none;
        }
        s.gpa.destroy(v);
    }

    fn destroyTextInput(s: *Server, ti: *TextInput) void {
        s.gpa.free(ti.surrounding_text);
        if (ti.pending.surrounding_text) |txt| s.gpa.free(txt);
        s.gpa.destroy(ti);
    }

    fn resetTextInputPending(s: *Server, ti: *TextInput) void {
        if (ti.pending.surrounding_text) |txt| s.gpa.free(txt);
        ti.pending = .{};
    }

    fn discardSurfaceFeedback(s: *Server, surf: *Surface) void {
        var i: usize = 0;
        while (i < s.frame_feedback.items.len) {
            const fb = s.frame_feedback.items[i];
            if (fb.surface == surf) {
                sendFeedbackDiscarded(fb.client, fb.id);
                _ = s.frame_feedback.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn sendFeedbackDiscarded(c: *Client, id: u32) void {
        if (!c.dead) {
            sendTo(c, id, p.wp_presentation_feedback.event.discarded, .{});
            c.deleteId(id);
        } else {
            _ = c.objects.remove(id);
        }
    }

    fn destroyRegion(s: *Server, reg: *Region) void {
        reg.ops.deinit(s.gpa);
        s.gpa.destroy(reg);
    }

    fn destroySurface(s: *Server, surf: *Surface) void {
        if (surf.viewport) |v| v.surface = null;
        // A lock on it ends.
        for (s.locks.items) |lock| if (lock.surface == surf) {
            lock.surface = null;
        };
        if (s.active_lock) |lock| if (lock.surface == null) s.endLock(lock);
        // The client knows it destroyed the surface; no leave events.
        if (s.pointer_focus == surf) s.pointer_focus = null;
        if (s.keyboard_focus == surf) s.keyboard_focus = null;
        if (s.cursor_surface == surf) {
            s.cursor_surface = null;
            s.damaged = true;
        }
        if (s.drag) |*d| {
            if (d.icon == surf) {
                d.icon = null;
                s.damaged = true;
            }
            if (d.focus == surf) {
                d.focus = null;
                if (d.offer) |offer| {
                    offer.active = false;
                    offer.accepted = false;
                    d.offer = null;
                }
                if (d.source) |src| s.clearDragSourceTarget(src);
            }
        }
        for (&s.touches) |*slot| if (slot.*) |*tp| if (tp.surface == surf) {
            tp.surface = null;
        };
        s.setBuffer(surf, null);
        if (surf.copy) |t| s.backend.vtable.destroyTexture(s.backend.ptr, t);
        if (surf.pending_input_region) |ops| s.gpa.free(ops);
        if (surf.input_region) |ops| s.gpa.free(ops);
        if (surf.pending_opaque_region) |ops| s.gpa.free(ops);
        if (surf.opaque_region) |ops| s.gpa.free(ops);
        // Frame callbacks of a destroyed surface never fire.
        for (surf.pending_callbacks.items) |id| _ = surf.client.objects.remove(id);
        for (surf.held_callbacks.items) |id| _ = surf.client.objects.remove(id);
        surf.pending_callbacks.deinit(s.gpa);
        surf.held_callbacks.deinit(s.gpa);
        for (surf.pending_feedback.items) |id| sendFeedbackDiscarded(surf.client, id);
        surf.pending_feedback.deinit(s.gpa);
        s.discardSurfaceFeedback(surf);
        for (s.presenting_feedback.items) |*fb| if (fb.surface == surf) {
            fb.surface = null;
        };
        if (surf.xdg) |x| {
            // The xdg_surface lives on, without a surface.
            if (x.toplevel) |t| s.unmap(t);
            if (x.popup) |pp| s.unmapPopup(pp);
            x.surface = null;
        }
        // Subsurfaces live on, without their surface or parent.
        if (surf.sub) |sub| {
            s.clearSubsurfaceCached(sub, surf.client);
            s.detachSubsurface(sub);
            sub.surface = null;
        }
        for (surf.subsurfaces.items) |child| child.parent = null;
        surf.subsurfaces.deinit(s.gpa);
        s.gpa.destroy(surf);
    }

    fn destroyToplevel(s: *Server, t: *Toplevel) void {
        if (t.decoration) |d| d.toplevel = null;
        for (s.toplevels.items) |other| if (other.parent == t) {
            other.parent = null;
        };
        s.unmap(t);
        t.xdg.toplevel = null;
        s.gpa.destroy(t);
    }

    fn unmap(s: *Server, t: *Toplevel) void {
        if (s.grab) |g| if (g.t == t) {
            s.grab = null;
        };
        if (s.edge_hover) |e| if (e.t == t) {
            s.edge_hover = null;
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
        s.endAnim(t);
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

    /// Wakes all configured toplevels by sending a configure event (e.g. when
    /// a system-wide appearance setting changes).
    pub fn wakeAll(s: *Server) void {
        for (s.toplevels.items) |t| {
            if (!t.xdg.configured) continue;
            const surf = t.xdg.surface orelse continue;
            s.configure(surf.client, t);
        }
    }

    /// The whole screen.
    pub fn screen(s: *const Server) Rect {
        return .{ .x = 0, .y = 0, .width = s.output.width, .height = s.output.height };
    }

    /// The area a window is in, as it is shown: the work area if it is
    /// maximized or tiled (leaving the dock room), otherwise the screen
    /// (fullscreen, or restored: the dock is drawn over it there).
    fn areaOf(s: *const Server, t: *const Toplevel) Rect {
        if (t.shown_fullscreen) return s.screen();
        if (t.shown_maximized or t.shown_tiled != null) return s.work_area;
        return s.screen();
    }

    /// The area a window is told it can fill.
    fn toldAreaOf(s: *const Server, t: *const Toplevel) Rect {
        return if (t.fullscreen) s.screen() else s.work_area;
    }

    /// The top window fills the screen: the shell's panels are hidden.
    pub fn fullscreenTop(s: *const Server) bool {
        // The overview is in the work area, with the dock.
        if (s.overviewShown()) return false;
        const t = s.topWindow() orelse return false;
        return t.shown_fullscreen;
    }

    /// The dma-buf buffer a window shows, if it can go on the display as it
    /// is: maximized or fullscreen, and the size of the area it fills.
    pub fn scanoutBuffer(s: *const Server, t: *const Toplevel) ?*Buffer {
        if (!t.shown_maximized and !t.shown_fullscreen) return null;
        if (t.anim != null) return null;
        if (s.overviewShown() or s.snap != null) return null;
        const surf = t.xdg.surface orelse return null;
        if (surf.scale != 1 or surf.transform != 0) return null;
        if (t.xdg.geometry) |g| if (g.x != 0 or g.y != 0) return null;
        // Subsurfaces, popups, a drag icon and a custom cursor are drawn on it.
        if (surf.subsurfaces.items.len > 0) return null;
        if (s.drag) |d| if (d.icon) |icon| if (icon.texture() != null) return null;
        if (s.cursor_surface) |cs| if (cs.texture() != null and s.pointer_focus != null) return null;
        for (s.popups.items) |pp| if (pp.xdg.surface) |ps| if (s.rootToplevel(ps) == t) return null;
        // Another window that can be seen (below the work area, around the
        // dock) would not be.
        for (s.toplevels.items) |u| if (u != t and u.shown() and !u.suspended) return null;
        const b = surf.buffer orelse return null;
        const area = s.areaOf(t);
        // As big as the area (its buffer may be smaller: the display
        // stretches it).
        const sz = surf.size() orelse return null;
        if (b.dmabuf == null or sz[0] != area.width or sz[1] != area.height) return null;
        return b;
    }

    fn sendRelease(b: *Buffer) void {
        if (b.destroyed) return;
        if (b.client.send(b.id, p.wl_buffer.event.release)) |m0| {
            var m = m0;
            m.end();
        }
    }

    /// Asks a client to close `t` (`xdg_toplevel.close`).
    pub fn closeToplevel(_: *Server, t: *Toplevel) void {
        const surf = t.xdg.surface orelse return;
        sendTo(surf.client, t.id, p.xdg_toplevel.event.close, .{});
    }

    /// Sends `xdg_wm_base.ping` to each of `c`'s `xdg_wm_base` objects and
    /// returns the ping serial.
    pub fn ping(s: *Server, c: *Client) u32 {
        const serial = s.nextSerial();
        c.ping_serial = serial;
        c.ponged = false;
        broadcast(c, .wm_base, p.xdg_wm_base.event.ping, 1, .{serial});
        return serial;
    }

    /// Where a window goes in the overview.
    pub const OverviewSlot = struct { t: *Toplevel, rect: Rect };

    /// Space around the overview's windows, and between them.
    const overview_gap = 32;

    /// How long the windows take to go into the overview, or out of it.
    pub const overview_ns = 250 * std.time.ns_per_ms;

    /// Shows the overview, or ends it. It shows only when there are
    /// windows, and not while a window is moved or something dragged.
    pub fn setOverview(s: *Server, on: bool) void {
        if (on == s.overview) return;
        if (on) {
            if (s.topWindow() == null or s.drag != null) return;
            if (s.grab != null) s.endGrab();
            s.dismissGrabs();
            s.breakLock();
        }
        if (on and s.overview_t == 0) {
            // Their places, top first, for the way in and out.
            s.overview_n = 0;
            var i = s.toplevels.items.len;
            while (i > 0 and s.overview_n < s.overview_order.len) {
                i -= 1;
                const t = s.toplevels.items[i];
                if (!t.shown()) continue;
                s.overview_order[s.overview_n] = t;
                s.overview_n += 1;
            }
        }
        s.overview = on;
        s.overview_anim = .{ .from = s.overview_t };
        s.damaged = true;
        // The windows lose the pointer and keyboard, or have them again, and
        // none is covered in the overview.
        s.updateFocus();
    }

    /// Moves the way into or out of the overview on to `now_ns`. Returns
    /// whether it is still under way (and a frame is to be drawn).
    pub fn animateOverview(s: *Server, now_ns: u64) bool {
        const a = &(s.overview_anim orelse return false);
        const start = a.start_ns orelse blk: {
            a.start_ns = now_ns;
            break :blk now_ns;
        };
        const to: f32 = if (s.overview) 1 else 0;
        const k: f32 = @floatCast(@min(@as(f64, @floatFromInt(now_ns -| start)) / overview_ns, 1));
        s.overview_t = a.from + (to - a.from) * k;
        s.damaged = true;
        if (k < 1) return true;
        s.overview_anim = null;
        if (!s.overview) s.overview_n = 0;
        return false;
    }

    /// How long a window takes to get to its place when maximized,
    /// fullscreen, tiled or restored.
    pub const state_anim_ns = 200 * std.time.ns_per_ms;

    /// Moves the windows whose state just changed on towards their
    /// places (from the first frame drawn of it, at `now_ns`). Returns
    /// whether any are still on their way.
    pub fn animateWindows(s: *Server, now_ns: u64) bool {
        var moving = false;
        for (s.toplevels.items) |t| {
            const a = &(t.anim orelse continue);
            const start = a.start_ns orelse blk: {
                a.start_ns = now_ns;
                break :blk now_ns;
            };
            const k: f32 = @floatCast(@min(@as(f64, @floatFromInt(now_ns -| start)) / state_anim_ns, 1));
            s.damaged = true;
            if (k >= 1) {
                s.endAnim(t);
                continue;
            }
            a.k = k;
            moving = true;
        }
        return moving;
    }

    /// `t` is no longer on its way to its place: its old frame goes.
    fn endAnim(s: *Server, t: *Toplevel) void {
        const a = t.anim orelse return;
        if (a.old) |o| s.releaseOldFrame(o);
        t.anim = null;
    }

    fn releaseOldFrame(s: *Server, o: OldFrame) void {
        if (o.buffer) |b| s.dropBuffer(b) else s.backend.vtable.destroyTexture(s.backend.ptr, o.texture);
    }

    /// The overview is drawn, all or part of the way in.
    pub fn overviewShown(s: *const Server) bool {
        return s.overview or s.overview_t > 0;
    }

    /// Picks a window in the overview: it comes to the top, with the
    /// keyboard, and the overview ends.
    pub fn overviewPick(s: *Server, t: *Toplevel) void {
        s.raiseToplevel(t);
        s.setOverview(false);
    }

    /// The window in the overview at (`x`, `y`) on the screen, if any.
    pub fn overviewAt(s: *const Server, x: f64, y: f64) ?*Toplevel {
        var buf: [32]OverviewSlot = undefined;
        for (s.overviewLayout(&buf)) |slot| {
            const r = slot.rect;
            if (x >= @as(f64, @floatFromInt(r.x)) and y >= @as(f64, @floatFromInt(r.y)) and
                x < @as(f64, @floatFromInt(r.x + @as(i32, @intCast(r.width)))) and
                y < @as(f64, @floatFromInt(r.y + @as(i32, @intCast(r.height))))) return slot.t;
        }
        return null;
    }

    /// Where each window shown goes in the overview, the top one first: in
    /// rows and columns (as near square as they go) filling the work area,
    /// each made as big as fits its cell (but no bigger than it is), in the
    /// middle of it, the last row's in the middle too.
    pub fn overviewLayout(s: *const Server, buf: []OverviewSlot) []OverviewSlot {
        var n: usize = 0;
        // In the order they had as it started (those still shown), then any
        // since, the top one first.
        for (s.overview_order[0..s.overview_n]) |t| {
            if (n == buf.len) break;
            if (std.mem.indexOfScalar(*Toplevel, s.toplevels.items, t) == null or !t.shown()) continue;
            buf[n] = .{ .t = t, .rect = undefined };
            n += 1;
        }
        var i = s.toplevels.items.len;
        while (i > 0 and n < buf.len) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (!t.shown() or std.mem.indexOfScalar(*Toplevel, s.overview_order[0..s.overview_n], t) != null) continue;
            buf[n] = .{ .t = t, .rect = undefined };
            n += 1;
        }
        if (n == 0) return buf[0..0];
        const cols: usize = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(n)))));
        const rows = (n + cols - 1) / cols;
        const wa = s.work_area;
        const gap: f64 = overview_gap;
        const cell_w = @max((@as(f64, @floatFromInt(wa.width)) - gap * @as(f64, @floatFromInt(cols + 1))) / @as(f64, @floatFromInt(cols)), 1);
        const cell_h = @max((@as(f64, @floatFromInt(wa.height)) - gap * @as(f64, @floatFromInt(rows + 1))) / @as(f64, @floatFromInt(rows)), 1);
        for (buf[0..n], 0..) |*slot, k| {
            const row = k / cols;
            const col = k % cols;
            // The last row's cells, in the middle.
            const in_row = if (row == rows - 1) n - row * cols else cols;
            const row_x = (@as(f64, @floatFromInt(cols - in_row)) * (cell_w + gap)) / 2;
            const r = s.windowRect(slot.t);
            const rw: f64 = @floatFromInt(@max(r.width, 1));
            const rh: f64 = @floatFromInt(@max(r.height, 1));
            const scale = @min(@min(cell_w / rw, cell_h / rh), 1);
            const w = @max(@round(rw * scale), 1);
            const h = @max(@round(rh * scale), 1);
            const cx = @as(f64, @floatFromInt(wa.x)) + gap + row_x + @as(f64, @floatFromInt(col)) * (cell_w + gap);
            const cy = @as(f64, @floatFromInt(wa.y)) + gap + @as(f64, @floatFromInt(row)) * (cell_h + gap);
            slot.rect = .{
                .x = @intFromFloat(@round(cx + (cell_w - w) / 2)),
                .y = @intFromFloat(@round(cy + (cell_h - h) / 2)),
                .width = @intFromFloat(w),
                .height = @intFromFloat(h),
            };
        }
        return buf[0..n];
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

    /// What remote control can do to a window (as its title bar's buttons
    /// and its app can).
    pub const WindowAction = enum { maximize, restore, fullscreen, windowed, close, raise };

    /// The top window whose app (its app ID, or the name of its program)
    /// or title is `app`; the top window if `app` is null.
    pub fn findWindow(s: *const Server, app: ?[]const u8) ?*Toplevel {
        var i = s.toplevels.items.len;
        while (i > 0) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (!t.mapped or t.xdg.surface == null) continue;
            const want = app orelse return t;
            if (std.mem.eql(u8, t.appId(), want) or std.mem.eql(u8, t.title(), want)) return t;
        }
        return null;
    }

    /// Does `action` to window `t`, as if its title bar's button (or its
    /// app) asked: a window leaving fullscreen goes back to how it was.
    pub fn act(s: *Server, t: *Toplevel, action: WindowAction) void {
        const c = (t.xdg.surface orelse return).client;
        switch (action) {
            .maximize => s.setMaximized(c, t, true),
            .restore => {
                s.setFullscreen(c, t, false);
                s.setMaximized(c, t, false);
            },
            .fullscreen => s.setFullscreen(c, t, true),
            .windowed => s.setFullscreen(c, t, false),
            .close => s.closeToplevel(t),
            .raise => s.raiseToplevel(t),
        }
    }

    fn raiseToplevel(s: *Server, t: *Toplevel) void {
        const i = std.mem.indexOfScalar(*Toplevel, s.toplevels.items, t) orelse return;
        if (i + 1 < s.toplevels.items.len) {
            _ = s.toplevels.orderedRemove(i);
            s.toplevels.appendAssumeCapacity(t);
            s.damaged = true;
        }
        // Keep any transient child toplevels (`child.parent == t`) stacked above `t`.
        var k: usize = 0;
        var n = s.toplevels.items.len;
        while (k < n) {
            const child = s.toplevels.items[k];
            if (child.parent == t) {
                s.raiseToplevel(child);
                n -= 1;
            } else {
                k += 1;
            }
        }
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

    /// Logical window dimensions of `t` (its `xdg_surface` geometry if set,
    /// otherwise its surface size).
    fn toplevelLogicalSize(t: *const Toplevel) [2]u32 {
        if (t.xdg.geometry) |g| return .{ g.width, g.height };
        return t.xdg.surface.?.size().?;
    }

    /// Where a window is on the screen, at the logical size of what it shows.
    pub fn windowRect(s: *const Server, t: *const Toplevel) Rect {
        const sz = toplevelLogicalSize(t);
        if (t.shown_maximized or t.shown_fullscreen) {
            const area = s.areaOf(t);
            return .{ .x = area.x, .y = area.y, .width = sz[0], .height = sz[1] };
        }
        if (t.shown_tiled) |side| {
            const half = s.tileRect(side);
            return .{ .x = half.x, .y = half.y, .width = sz[0], .height = sz[1] };
        }
        return .{
            .x = if (t.anchor_right) |r| r - @as(i32, @intCast(sz[0])) else t.x,
            .y = if (t.anchor_bottom) |b| b - @as(i32, @intCast(sz[1])) else t.y,
            .width = sz[0],
            .height = sz[1],
        };
    }

    /// The part of a window that can be seen: what is in the work area (or,
    /// fullscreen, the screen).
    fn visibleRect(s: *const Server, t: *const Toplevel) Rect {
        const r = s.windowRect(t);
        const wa = s.areaOf(t);
        const x0 = @max(r.x, wa.x);
        const y0 = @max(r.y, wa.y);
        const x1 = @min(r.x + @as(i32, @intCast(r.width)), wa.x + @as(i32, @intCast(wa.width)));
        const y1 = @min(r.y + @as(i32, @intCast(r.height)), wa.y + @as(i32, @intCast(wa.height)));
        return .{ .x = x0, .y = y0, .width = @intCast(@max(x1 - x0, 0)), .height = @intCast(@max(y1 - y0, 0)) };
    }

    /// The size a window is told to be: the work area's, or its restored
    /// size (at first half the work area), no smaller than its minimum
    /// nor bigger than the work area (maximized or tiled) or the screen.
    pub fn configuredSize(s: *const Server, t: *const Toplevel) [2]u32 {
        const wa = s.work_area;
        if (t.fullscreen) return .{ s.output.width, s.output.height };
        if (t.maximized) return .{ wa.width, wa.height };
        // Tiled: exactly half, even if the window asks to be wider (it
        // would cover the other half).
        if (t.tiled) |side| {
            const r = s.tileRect(side);
            return .{ r.width, r.height };
        }
        // Restored, it can be as big as the screen (under the dock).
        const w = if (t.width != 0) t.width else wa.width / 2;
        const h = if (t.height != 0) t.height else wa.height / 2;
        return .{ s.clampWidth(t, w, s.output.width), s.clampHeight(t, h, s.output.height) };
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
        // Maximized, or restored, it no longer fills a half.
        t.tiled = null;
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

    /// A restored window's first buffer: the size its client chose (it was
    /// told 0 by 0: see `configure`), as far as the work area and its size
    /// limits allow, in the middle of the work area. If it had to be made
    /// smaller, it is told so. One that fills the work area is maximized
    /// (as one that leaves fullscreen without ever having been placed, a
    /// game started fullscreen, say): it can then be shown directly. A
    /// fullscreen window is placed once it leaves fullscreen.
    fn placeFirst(s: *Server, c: *Client, t: *Toplevel) void {
        if (t.placed or t.maximized or t.fullscreen) return;
        const sz = toplevelLogicalSize(t);
        const wa = s.work_area;
        if (sz[0] >= wa.width and sz[1] >= wa.height) {
            s.setMaximized(c, t, true);
            return;
        }
        t.width = s.clampWidth(t, sz[0], wa.width);
        t.height = s.clampHeight(t, sz[1], wa.height);
        t.x = wa.x + @divTrunc(@as(i32, @intCast(wa.width)) - @as(i32, @intCast(t.width)), 2);
        t.y = wa.y + @max(@divTrunc(@as(i32, @intCast(wa.height)) - @as(i32, @intCast(t.height)), 2), 0);
        t.placed = true;
        if (t.width != sz[0] or t.height != sz[1]) s.requestConfigure(c, t);
    }

    /// Makes a window fill the screen, over the dock, or not.
    fn setFullscreen(s: *Server, c: *Client, t: *Toplevel, on: bool) void {
        if (t.fullscreen == on) return;
        if (s.grab) |g| if (g.t == t) s.endGrab();
        t.fullscreen = on;
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

    /// Its restored size is kept within the new limits (whether it is
    /// restored now, or maximized or fullscreen and will be again); a
    /// window restored now is told.
    fn sizeLimitsChanged(s: *Server, c: *Client, t: *Toplevel) void {
        if (!t.placed) return;
        const wa = s.screen();
        const w = s.clampWidth(t, t.width, wa.width);
        const h = s.clampHeight(t, t.height, wa.height);
        if (w == t.width and h == t.height) return;
        t.width = w;
        t.height = h;
        if (!t.maximized and !t.fullscreen and t.xdg.configured) s.requestConfigure(c, t);
    }

    /// Moves a restored window, keeping `grip` of it on the screen (and its
    /// top, with its title bar, below the work area's).
    fn moveWindow(s: *Server, t: *Toplevel, x: f64, y: f64) void {
        const wa = s.screen();
        const w: i32 = @intCast(s.windowRect(t).width);
        const left = wa.x + grip - w;
        const right = wa.x + @as(i32, @intCast(wa.width)) - grip;
        const bottom = wa.y + @as(i32, @intCast(wa.height)) - grip;
        const nx = std.math.clamp(@as(i32, @intFromFloat(@round(x))), @min(left, right), right);
        const top = s.work_area.y;
        const ny = std.math.clamp(@as(i32, @intFromFloat(@round(y))), top, @max(bottom, top));
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
        const g: Grab = .{
            .t = t,
            .dx = by.press_x - @as(f64, @floatFromInt(t.x)),
            .dy = by.press_y - @as(f64, @floatFromInt(t.y)),
            .touch = by.touch,
            .unsnap = t.maximized or t.tiled != null,
            .x = by.press_x,
            .y = by.press_y,
        };
        s.grab = g;
        s.takeInput(by.touch);
        s.grabTo(g, by.x, by.y);
    }

    /// A client asked to resize its window by `edges` with the pointer, as
    /// for `startMove`.
    fn clientResize(s: *Server, t: *Toplevel, serial: u32, edges: u32) void {
        if (t.maximized or t.tiled != null) return;
        const by = s.clientGrabAllowed(t, serial) orelse return;
        const valid = edges != 0 and edges & (edge_top | edge_bottom) != edge_top | edge_bottom and edges & (edge_left | edge_right) != edge_left | edge_right;
        if (!valid or edges > 15) return;
        s.startResize(t, edges, by);
    }

    /// What drives a move or resize: the pointer, or a touch.
    const GrabBy = struct { press_x: f64, press_y: f64, x: f64, y: f64, touch: ?i32 = null };

    /// Whether a client may move or resize its window from the input with
    /// `serial`: a button press it is still holding on the window, or a
    /// touch still down on it; and from where.
    fn clientGrabAllowed(s: *const Server, t: *const Toplevel, serial: u32) ?GrabBy {
        if (t.fullscreen or !t.shown() or s.grab != null or s.drag != null) return null;
        const surf = t.xdg.surface orelse return null;
        if (s.buttons_down != 0 and serial == s.press_serial and s.pointer_focus == surf) return .{ .press_x = s.press_x, .press_y = s.press_y, .x = s.pointer_x, .y = s.pointer_y };
        if (serial == s.touch_serial) if (s.touchPoint(s.touch_serial_id)) |tp| if (tp.surface == surf) return .{ .press_x = tp.press_x, .press_y = tp.press_y, .x = tp.x, .y = tp.y, .touch = tp.id };
        return null;
    }

    /// Resizes `t` by its `edges` as the pointer (or touch) moves, until
    /// the buttons are released (or the touch comes up).
    fn startResize(s: *Server, t: *Toplevel, edges: u32, by: GrabBy) void {
        s.settle(t, true);
        const size = s.configuredSize(t);
        const g: Grab = .{ .t = t, .dx = 0, .dy = 0, .touch = by.touch, .resize = .{
            .edges = edges,
            .x = by.press_x,
            .y = by.press_y,
            .rect = .{ .x = t.x, .y = t.y, .width = size[0], .height = size[1] },
        } };
        s.grab = g;
        s.takeInput(by.touch);
        s.grabTo(g, by.x, by.y);
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
        const wa = s.screen();
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
            h = s.clampHeight(t, @intCast(@max(h0 - dy, 1)), @intCast(@max(bottom - s.work_area.y, 1)));
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
        s.setSnap(null);
        s.settle(g.t, false);
        if (s.updatePointerFocus()) s.pointerFrame();
    }

    /// The buttons (or touch) driving a move or resize were let go: a
    /// window moved to an edge fills the work area, or half of it.
    fn dropGrab(s: *Server) void {
        const g = s.grab orelse return;
        const snap = s.snap;
        s.endGrab();
        const sn = snap orelse return;
        if (g.resize != null) return;
        const c = (g.t.xdg.surface orelse return).client;
        switch (sn) {
            .maximize => s.setMaximized(c, g.t, true),
            .left => s.setTiled(c, g.t, .left),
            .right => s.setTiled(c, g.t, .right),
        }
    }

    /// The picture shown for a cursor-shape protocol shape (null if there
    /// is no such shape).
    fn cursorForShape(shape: u32) ?Cursor {
        const sh = p.wp_cursor_shape_device_v1.shape;
        return switch (shape) {
            sh.default, sh.context_menu, sh.help, sh.alias, sh.copy, sh.zoom_in, sh.zoom_out => .arrow,
            sh.pointer => .pointer,
            sh.progress, sh.wait => .wait,
            sh.cell, sh.crosshair => .crosshair,
            sh.text => .text,
            sh.vertical_text => .vertical_text,
            sh.move, sh.all_scroll, sh.grab, sh.grabbing => .move,
            sh.no_drop, sh.not_allowed => .not_allowed,
            sh.e_resize, sh.w_resize, sh.ew_resize, sh.col_resize => .resize_horizontal,
            sh.n_resize, sh.s_resize, sh.ns_resize, sh.row_resize => .resize_vertical,
            sh.nw_resize, sh.se_resize, sh.nwse_resize => .resize_diagonal_down,
            sh.ne_resize, sh.sw_resize, sh.nesw_resize => .resize_diagonal_up,
            else => null,
        };
    }

    /// The pointer's pictures.
    pub const Cursor = @import("cursor.zig").Shape;

    /// The pointer's picture: a resize while resizing; otherwise the one
    /// the client under it chose (or `.hidden` if the client drew its own
    /// cursor surface).
    pub fn cursor(s: *const Server) Cursor {
        if (s.pointerLocked()) return .hidden;
        const g = s.grab orelse {
            if (s.edge_hover) |e| return edgeCursor(e.edges);
            if (s.pointer_focus != null) {
                if (s.cursor_surface != null) return .hidden;
                return s.client_cursor;
            }
            return .arrow;
        };
        return edgeCursor(if (g.resize) |r| r.edges else 0);
    }

    /// The resize arrow for `edges` (an arrow for none).
    fn edgeCursor(edges: u32) Cursor {
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
        s.presenting_feedback.appendSlice(s.gpa, s.frame_feedback.items) catch {
            for (s.frame_feedback.items) |fb| sendFeedbackDiscarded(fb.client, fb.id);
        };
        s.frame_feedback.clearRetainingCapacity();
        s.damaged = false;
    }

    /// Fires the drawn frame's callbacks once it has reached the screen.
    pub fn framePresented(s: *Server, time_ms: u32) void {
        const flags: u32 = p.wp_presentation_feedback.kind.vsync |
            p.wp_presentation_feedback.kind.hw_clock |
            p.wp_presentation_feedback.kind.hw_completion;
        s.framePresentedNs(@as(u64, time_ms) * std.time.ns_per_ms, flags);
    }

    /// Fires the drawn frame's `wl_callback` and `wp_presentation_feedback`
    /// objects with nanosecond presentation timestamp `time_ns` and
    /// `wp_presentation_feedback.kind` `flags`.
    pub fn framePresentedNs(s: *Server, time_ns: u64, flags: u32) void {
        const time_ms: u32 = @truncate(time_ns / std.time.ns_per_ms);
        for (s.presenting.items) |fc| {
            if (fc.client.send(fc.id, p.wl_callback.event.done)) |m0| {
                var m = m0;
                m.uint(time_ms).end();
            }
            fc.client.deleteId(fc.id);
        }
        s.presenting.clearRetainingCapacity();

        s.present_seq +%= 1;
        const sec = time_ns / std.time.ns_per_s;
        const nsec: u32 = @intCast(time_ns % std.time.ns_per_s);
        const tv_sec_hi: u32 = @truncate(sec >> 32);
        const tv_sec_lo: u32 = @truncate(sec);
        const refresh_ns: u32 = if (s.output.refresh_mhz > 0)
            @intCast(@divTrunc(1_000_000_000_000, @as(u64, @intCast(s.output.refresh_mhz))))
        else
            0;
        const seq_hi: u32 = @truncate(s.present_seq >> 32);
        const seq_lo: u32 = @truncate(s.present_seq);

        for (s.presenting_feedback.items) |fb| {
            if (fb.client.dead) continue;
            var it = fb.client.objects.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == .output) {
                    sendTo(fb.client, fb.id, p.wp_presentation_feedback.event.sync_output, .{e.key_ptr.*});
                }
            }
            sendTo(fb.client, fb.id, p.wp_presentation_feedback.event.presented, .{
                tv_sec_hi,
                tv_sec_lo,
                nsec,
                refresh_ns,
                seq_hi,
                seq_lo,
                flags,
            });
            fb.client.deleteId(fb.id);
        }
        s.presenting_feedback.clearRetainingCapacity();
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
                p.wl_compositor.request.create_region => {
                    const id = try r.uint();
                    const reg = try s.gpa.create(Region);
                    reg.* = .{};
                    c.addObject(id, .{ .region = reg }) catch |e| {
                        s.gpa.destroy(reg);
                        return e;
                    };
                },
                else => return error.InvalidOpcode,
            },
            .region => |reg| switch (m.opcode) {
                p.wl_region.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyRegion(reg);
                },
                p.wl_region.request.add, p.wl_region.request.subtract => {
                    const x = try r.int();
                    const y = try r.int();
                    const w = try r.int();
                    const h = try r.int();
                    try reg.ops.append(s.gpa, .{
                        .subtract = m.opcode == p.wl_region.request.subtract,
                        .x = x,
                        .y = y,
                        .width = w,
                        .height = h,
                    });
                },
                else => return error.InvalidOpcode,
            },
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
                    const code = try r.uint();
                    const format = fromShmCode(code) orelse
                        return c.postError(m.object, p.wl_shm.err.invalid_format, "unsupported format {d}", .{code});
                    const bpp: i32 = @intCast(format.bytesPerPixel());
                    if (offset < 0 or width <= 0 or height <= 0 or width > 2048 or height > 2048 or stride < width * bpp or @mod(stride, bpp) != 0 or
                        @as(u64, @intCast(offset)) + @as(u64, @intCast(stride)) * @as(u64, @intCast(height)) > pool.map.len)
                        return c.postError(m.object, p.wl_shm.err.invalid_stride, "buffer outside the pool", .{});
                    const b = try s.gpa.create(Buffer);
                    b.* = .{ .client = c, .id = id, .width = @intCast(width), .height = @intCast(height), .shm = .{ .pool = pool, .offset = @intCast(offset), .stride = @intCast(stride), .format = format } };
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
                    if (surf.hasRole()) return c.postError(m.object, p.xdg_wm_base.err.role, "surface already has a role", .{});
                    const x = try s.gpa.create(XdgSurface);
                    x.* = .{ .surface = surf, .id = id, .version = version };
                    c.addObject(id, .{ .xdg_surface = x }) catch |e| {
                        s.gpa.destroy(x);
                        return e;
                    };
                    surf.xdg = x;
                },
                p.xdg_wm_base.request.pong => {
                    const serial = try r.uint();
                    if (serial == c.ping_serial) {
                        c.ping_serial = 0;
                        c.ponged = true;
                    }
                },
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
                    if (surf.hasRole()) return c.postError(m.object, p.wl_subcompositor.err.bad_surface, "surface already has a role", .{});
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
                p.wl_subsurface.request.set_sync => sub.sync = true,
                p.wl_subsurface.request.set_desync => {
                    sub.sync = false;
                    if (!s.isSubsurfaceSync(sub) and sub.cached.has_state) {
                        try s.applySubsurfaceCached(sub);
                    }
                },
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
                    if (x.toplevel != null or x.popup != null) return c.postError(m.object, p.xdg_surface.err.already_constructed, "already has a role", .{});
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
                p.xdg_surface.request.set_window_geometry => {
                    const gx = try r.int();
                    const gy = try r.int();
                    const gw = try r.int();
                    const gh = try r.int();
                    if (gw <= 0 or gh <= 0) return c.postError(m.object, p.xdg_wm_base.err.invalid_surface_state, "window geometry size must be positive", .{});
                    x.pending_geometry = .{ .x = gx, .y = gy, .width = @intCast(gw), .height = @intCast(gh) };
                },
                else => return error.InvalidOpcode,
            },
            .toplevel => |t| switch (m.opcode) {
                p.xdg_toplevel.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyToplevel(t);
                },
                p.xdg_toplevel.request.set_parent => {
                    const parent_id = try r.uint();
                    const parent: ?*Toplevel = if (parent_id == 0) null else switch (c.objects.get(parent_id) orelse return error.InvalidObject) {
                        .toplevel => |pt| pt,
                        else => return error.InvalidObject,
                    };
                    var at = parent;
                    while (at) |cur| : (at = cur.parent) {
                        if (cur == t) return c.postError(m.object, p.xdg_wm_base.err.invalid_surface_state, "a window cannot be its own parent", .{});
                    }
                    t.parent = parent;
                    if (parent) |pt| if (t.mapped and pt.mapped) s.raiseToplevel(pt);
                },
                p.xdg_toplevel.request.set_title => {
                    const title = (try r.string()) orelse "";
                    t.title_len = @min(title.len, t.title_buf.len);
                    @memcpy(t.title_buf[0..t.title_len], title[0..t.title_len]);
                    s.damaged = true;
                },
                p.xdg_toplevel.request.set_app_id => {
                    const app_id = (try r.string()) orelse "";
                    t.app_id_len = @min(app_id.len, t.app_id_buf.len);
                    @memcpy(t.app_id_buf[0..t.app_id_len], app_id[0..t.app_id_len]);
                },
                p.xdg_toplevel.request.show_window_menu => {
                    _ = try r.uint(); // seat
                    _ = try r.uint(); // serial
                    _ = try r.int(); // x
                    _ = try r.int(); // y
                },
                p.xdg_toplevel.request.set_maximized => s.setMaximized(c, t, true),
                p.xdg_toplevel.request.unset_maximized => s.setMaximized(c, t, false),
                // On the one screen there is, whichever output is asked for.
                p.xdg_toplevel.request.set_fullscreen => {
                    _ = try r.uint(); // output
                    s.setFullscreen(c, t, true);
                },
                p.xdg_toplevel.request.unset_fullscreen => s.setFullscreen(c, t, false),
                p.xdg_toplevel.request.set_minimized => {},
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
                else => return error.InvalidOpcode,
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
            .pointer_constraints => switch (m.opcode) {
                p.zwp_pointer_constraints_v1.request.destroy => c.deleteId(m.object),
                p.zwp_pointer_constraints_v1.request.lock_pointer, p.zwp_pointer_constraints_v1.request.confine_pointer => {
                    const is_lock = m.opcode == p.zwp_pointer_constraints_v1.request.lock_pointer;
                    const id = try r.uint();
                    const surf_id = try r.uint();
                    _ = try r.uint(); // the wl_pointer
                    const region_id = try r.uint();
                    const lifetime = try r.uint();
                    const surf = switch (c.objects.get(surf_id) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    const region_ops = try s.copyRegionArg(c, region_id);
                    errdefer if (region_ops) |ops| s.gpa.free(ops);
                    for (s.locks.items) |other| if (other.surface == surf) {
                        if (region_ops) |ops| s.gpa.free(ops);
                        return c.postError(m.object, p.zwp_pointer_constraints_v1.err.already_constrained, "the pointer is already constrained on surface {d}", .{surf_id});
                    };
                    const lock = try s.gpa.create(PointerLock);
                    lock.* = .{
                        .client = c,
                        .id = id,
                        .surface = surf,
                        .lock = is_lock,
                        .persistent = lifetime == p.zwp_pointer_constraints_v1.lifetime.persistent,
                        .region = region_ops,
                    };
                    errdefer s.gpa.destroy(lock);
                    try s.locks.append(s.gpa, lock);
                    errdefer _ = s.locks.pop();
                    try c.addObject(id, if (is_lock) .{ .locked_pointer = lock } else .{ .confined_pointer = lock });
                    s.updateLock();
                },
                else => return error.InvalidOpcode,
            },
            .locked_pointer => |lock| switch (m.opcode) {
                p.zwp_locked_pointer_v1.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyLock(lock);
                },
                p.zwp_locked_pointer_v1.request.set_cursor_position_hint => {
                    const hx = try r.fixed();
                    const hy = try r.fixed();
                    lock.pending_hint = .{ hx, hy };
                },
                p.zwp_locked_pointer_v1.request.set_region => {
                    const ops = try s.copyRegionArg(c, try r.uint());
                    if (lock.pending_region) |old| s.gpa.free(old);
                    lock.pending_region = ops;
                    lock.pending_region_set = true;
                },
                else => return error.InvalidOpcode,
            },
            .confined_pointer => |lock| switch (m.opcode) {
                p.zwp_confined_pointer_v1.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyLock(lock);
                },
                p.zwp_confined_pointer_v1.request.set_region => {
                    const ops = try s.copyRegionArg(c, try r.uint());
                    if (lock.pending_region) |old| s.gpa.free(old);
                    lock.pending_region = ops;
                    lock.pending_region_set = true;
                },
                else => return error.InvalidOpcode,
            },
            .relative_pointer_manager => switch (m.opcode) {
                p.zwp_relative_pointer_manager_v1.request.destroy => c.deleteId(m.object),
                p.zwp_relative_pointer_manager_v1.request.get_relative_pointer => {
                    const id = try r.uint();
                    _ = try r.uint(); // the wl_pointer
                    try c.addObject(id, .{ .relative_pointer = 1 });
                },
                else => return error.InvalidOpcode,
            },
            .relative_pointer => if (m.opcode == p.zwp_relative_pointer_v1.request.destroy) c.deleteId(m.object),
            .pointer => switch (m.opcode) {
                p.wl_pointer.request.set_cursor => {
                    _ = try r.uint(); // serial
                    const surf_id = try r.uint();
                    const hot_x = try r.int();
                    const hot_y = try r.int();
                    const surf: ?*Surface = if (surf_id == 0) null else switch (c.objects.get(surf_id) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (surf) |cs| {
                        if (cs.xdg != null or cs.sub != null or cs.drag_icon)
                            return c.postError(m.object, p.wl_pointer.err.role, "surface already has a role", .{});
                        cs.cursor_role = true;
                    }
                    if (s.pointer_focus) |pf| if (pf.client == c) {
                        if (s.cursor_surface != surf or s.cursor_hotspot[0] != hot_x or s.cursor_hotspot[1] != hot_y) s.damaged = true;
                        s.cursor_surface = surf;
                        s.cursor_hotspot = .{ hot_x, hot_y };
                        s.client_cursor = if (surf == null) .hidden else .arrow;
                    };
                },
                p.wl_pointer.request.release => c.deleteId(m.object),
                else => return error.InvalidOpcode,
            },
            .touch => if (m.opcode == p.wl_touch.request.release) c.deleteId(m.object),
            .keyboard => if (m.opcode == p.wl_keyboard.request.release) c.deleteId(m.object),
            .data_device_manager => |version| switch (m.opcode) {
                p.wl_data_device_manager.request.create_data_source => {
                    const id = try r.uint();
                    const src = try s.gpa.create(DataSource);
                    src.* = .{ .client = c, .id = id, .version = version };
                    c.addObject(id, .{ .data_source = src }) catch |e| {
                        s.gpa.destroy(src);
                        return e;
                    };
                },
                p.wl_data_device_manager.request.get_data_device => {
                    const id = try r.uint();
                    _ = try r.uint(); // the seat: there is one
                    try c.addObject(id, .{ .data_device = version });
                    // A client with the keyboard learns what the clipboard
                    // holds.
                    if (s.keyboard_focus) |surf| if (surf.client == c) s.sendSelectionTo(c, id, version);
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
                p.wl_data_source.request.set_actions => {
                    const actions = try r.uint();
                    if (actions & ~@as(u32, p.wl_data_device_manager.dnd_action.all) != 0)
                        return c.postError(m.object, p.wl_data_source.err.invalid_action_mask, "invalid action mask {d}", .{actions});
                    if (src.used or src.actions != null)
                        return c.postError(m.object, p.wl_data_source.err.invalid_source, "actions already set or source already used", .{});
                    src.actions = actions;
                },
                else => return error.InvalidOpcode,
            },
            .data_device => switch (m.opcode) {
                p.wl_data_device.request.start_drag => {
                    const src_id = try r.uint();
                    const origin_id = try r.uint();
                    const icon_id = try r.uint();
                    const serial = try r.uint();
                    const src: ?*DataSource = if (src_id == 0) null else switch (c.objects.get(src_id) orelse return error.InvalidObject) {
                        .data_source => |x| x,
                        else => return error.InvalidObject,
                    };
                    const origin = switch (c.objects.get(origin_id) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    const icon: ?*Surface = if (icon_id == 0) null else switch (c.objects.get(icon_id) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (icon) |ic| {
                        if (ic.xdg != null or ic.sub != null or ic.cursor_role) return c.postError(m.object, p.wl_data_device.err.role, "surface already has a role", .{});
                        ic.drag_icon = true;
                    }
                    if (src) |ds| {
                        if (ds.used) return c.postError(m.object, p.wl_data_device.err.used_source, "data source already used", .{});
                        ds.used = true;
                    }
                    s.startDrag(c, src, origin, icon, serial);
                },
                p.wl_data_device.request.set_selection => {
                    const id = try r.uint();
                    _ = try r.uint(); // serial
                    const src: ?*DataSource = if (id == 0) null else switch (c.objects.get(id) orelse return error.InvalidObject) {
                        .data_source => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (src) |ds| {
                        if (ds.actions != null) return c.postError(ds.id, p.wl_data_source.err.invalid_source, "drag source cannot be used as selection", .{});
                        if (ds.used) return c.postError(m.object, p.wl_data_device.err.used_source, "data source already used", .{});
                        ds.used = true;
                    }
                    s.setSelection(c, src);
                },
                p.wl_data_device.request.release => c.deleteId(m.object),
                else => return error.InvalidOpcode,
            },
            .data_offer => |offer| switch (m.opcode) {
                p.wl_data_offer.request.accept => {
                    _ = try r.uint(); // serial
                    const mime = try r.string();
                    if (offer.finished) return c.postError(m.object, p.wl_data_offer.err.invalid_offer, "offer already finished", .{});
                    if (!offer.dnd or !offer.active) return;
                    offer.accepted = mime != null;
                    if (offer.source) |src| {
                        if (src.client.send(src.id, p.wl_data_source.event.target)) |m0| {
                            var e = m0;
                            e.string(mime).end();
                        }
                        if (offer.version < 3) s.negotiateAction(offer);
                    }
                },
                p.wl_data_offer.request.receive => {
                    const mime = (try r.string()) orelse "";
                    const fd = try r.fd();
                    if (offer.finished) {
                        _ = linux.close(fd);
                        return c.postError(m.object, p.wl_data_offer.err.invalid_offer, "offer already finished", .{});
                    }
                    s.receive(offer, mime, fd);
                },
                p.wl_data_offer.request.destroy => {
                    // Made by the server: no delete_id.
                    _ = c.objects.remove(m.object);
                    s.destroyOffer(offer);
                },
                p.wl_data_offer.request.finish => {
                    if (!offer.dnd or !offer.dropped or !offer.active or offer.finished or !offer.accepted or (offer.version >= 3 and offer.action == 0))
                        return c.postError(m.object, p.wl_data_offer.err.invalid_finish, "cannot finish this offer", .{});
                    offer.finished = true;
                    offer.active = false;
                    if (offer.source) |src| {
                        if (src.version >= 3) sendTo(src.client, src.id, p.wl_data_source.event.dnd_finished, .{});
                        offer.source = null;
                    }
                },
                p.wl_data_offer.request.set_actions => {
                    const actions = try r.uint();
                    const preferred = try r.uint();
                    if (!offer.dnd or offer.finished)
                        return c.postError(m.object, p.wl_data_offer.err.invalid_offer, "not an active drag offer", .{});
                    if (actions & ~@as(u32, p.wl_data_device_manager.dnd_action.all) != 0)
                        return c.postError(m.object, p.wl_data_offer.err.invalid_action_mask, "invalid action mask {d}", .{actions});
                    if (preferred & ~@as(u32, p.wl_data_device_manager.dnd_action.all) != 0 or @popCount(preferred) > 1)
                        return c.postError(m.object, p.wl_data_offer.err.invalid_action, "invalid preferred action {d}", .{preferred});
                    offer.actions = actions;
                    offer.preferred_action = preferred;
                    if (offer.active) s.negotiateAction(offer);
                },
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
                        if (s.cursor_surface != null) {
                            s.cursor_surface = null;
                            s.damaged = true;
                        }
                        s.client_cursor = picture;
                    };
                },
                else => return error.InvalidOpcode,
            },
            .presentation => switch (m.opcode) {
                p.wp_presentation.request.destroy => c.deleteId(m.object),
                p.wp_presentation.request.feedback => {
                    const surf_id = try r.uint();
                    const id = try r.uint();
                    const surf = switch (c.objects.get(surf_id) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    try c.addObject(id, .presentation_feedback);
                    try surf.pending_feedback.append(s.gpa, id);
                },
                else => return error.InvalidOpcode,
            },
            .presentation_feedback => return error.InvalidOpcode,
            .decoration_manager => switch (m.opcode) {
                p.dazzle_decoration_manager_v1.request.destroy => c.deleteId(m.object),
                p.dazzle_decoration_manager_v1.request.get_decoration => {
                    const id = try r.uint();
                    const t = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .toplevel => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (t.decoration != null) return c.postError(m.object, p.dazzle_decoration_manager_v1.err.already_constructed, "the toplevel already has a decoration", .{});
                    const d = try s.gpa.create(Decoration);
                    d.* = .{ .id = id, .toplevel = t };
                    c.addObject(id, .{ .decoration = d }) catch |e| {
                        s.gpa.destroy(d);
                        return e;
                    };
                    t.decoration = d;
                    // Configured already: told its radius with a new one.
                    if (t.configure_serial != 0) s.configure(c, t);
                },
                else => return error.InvalidOpcode,
            },
            .viewporter => switch (m.opcode) {
                p.wp_viewporter.request.destroy => c.deleteId(m.object),
                p.wp_viewporter.request.get_viewport => {
                    const id = try r.uint();
                    const surf = switch (c.objects.get(try r.uint()) orelse return error.InvalidObject) {
                        .surface => |x| x,
                        else => return error.InvalidObject,
                    };
                    if (surf.viewport != null) return c.postError(m.object, p.wp_viewporter.err.viewport_exists, "the surface already has a viewport", .{});
                    const v = try s.gpa.create(Viewport);
                    v.* = .{ .id = id, .surface = surf };
                    c.addObject(id, .{ .viewport = v }) catch |e| {
                        s.gpa.destroy(v);
                        return e;
                    };
                    surf.viewport = v;
                },
                else => return error.InvalidOpcode,
            },
            .viewport => |v| switch (m.opcode) {
                p.wp_viewport.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyViewport(v);
                },
                p.wp_viewport.request.set_source => {
                    // All of the buffer is shown: a part of it is not
                    // supported, and taken as all of it.
                    for (0..4) |_| _ = try r.int();
                },
                p.wp_viewport.request.set_destination => {
                    const w = try r.int();
                    const h = try r.int();
                    const surf = v.surface orelse return c.postError(m.object, p.wp_viewport.err.no_surface, "the surface is gone", .{});
                    if (w == -1 and h == -1) {
                        surf.pending_destination = .none;
                    } else if (w <= 0 or h <= 0) {
                        return c.postError(m.object, p.wp_viewport.err.bad_value, "a destination must be positive, or -1 by -1", .{});
                    } else surf.pending_destination = .{ .size = .{ @intCast(w), @intCast(h) } };
                },
                else => return error.InvalidOpcode,
            },
            .decoration => |d| switch (m.opcode) {
                p.dazzle_decoration_v1.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyDecoration(d);
                },
                else => return error.InvalidOpcode,
            },
            .text_input_manager => switch (m.opcode) {
                p.zwp_text_input_manager_v3.request.destroy => c.deleteId(m.object),
                p.zwp_text_input_manager_v3.request.get_text_input => {
                    const id = try r.uint();
                    _ = try r.uint(); // seat
                    const ti = try s.gpa.create(TextInput);
                    ti.* = .{ .client = c, .id = id };
                    c.addObject(id, .{ .text_input = ti }) catch |e| {
                        s.gpa.destroy(ti);
                        return e;
                    };
                    if (s.keyboard_focus) |surf| if (surf.client == c) {
                        sendTo(c, id, p.zwp_text_input_v3.event.enter, .{surf.id});
                    };
                },
                else => return error.InvalidOpcode,
            },
            .text_input => |ti| switch (m.opcode) {
                p.zwp_text_input_v3.request.destroy => {
                    c.deleteId(m.object);
                    s.destroyTextInput(ti);
                },
                p.zwp_text_input_v3.request.enable => {
                    s.resetTextInputPending(ti);
                    ti.pending.enabled = true;
                },
                p.zwp_text_input_v3.request.disable => {
                    s.resetTextInputPending(ti);
                    ti.pending.enabled = false;
                },
                p.zwp_text_input_v3.request.set_surrounding_text => {
                    const text = (try r.string()) orelse "";
                    const cur_pos = try r.int();
                    const anchor = try r.int();
                    const copy = try s.gpa.dupe(u8, text);
                    if (ti.pending.surrounding_text) |old| s.gpa.free(old);
                    ti.pending.surrounding_text = copy;
                    ti.pending.cursor = cur_pos;
                    ti.pending.anchor = anchor;
                },
                p.zwp_text_input_v3.request.set_text_change_cause => {
                    ti.pending.change_cause = try r.uint();
                },
                p.zwp_text_input_v3.request.set_content_type => {
                    const hint = try r.uint();
                    ti.pending.content_hint = hint;
                    ti.pending.content_purpose = try r.uint();
                },
                p.zwp_text_input_v3.request.set_cursor_rectangle => {
                    const rx = try r.int();
                    const ry = try r.int();
                    const rw = try r.int();
                    const rh = try r.int();
                    ti.pending.cursor_rect = .{
                        .x = rx,
                        .y = ry,
                        .width = @intCast(@max(rw, 0)),
                        .height = @intCast(@max(rh, 0)),
                    };
                },
                p.zwp_text_input_v3.request.commit => {
                    ti.serial +%= 1;
                    ti.enabled = ti.pending.enabled;
                    if (!ti.enabled) {
                        s.gpa.free(ti.surrounding_text);
                        ti.surrounding_text = &.{};
                        ti.cursor = 0;
                        ti.anchor = 0;
                        ti.change_cause = p.zwp_text_input_v3.change_cause.input_method;
                        ti.content_hint = p.zwp_text_input_v3.content_hint.none;
                        ti.content_purpose = p.zwp_text_input_v3.content_purpose.normal;
                        ti.cursor_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                    } else {
                        if (ti.pending.surrounding_text) |txt| {
                            s.gpa.free(ti.surrounding_text);
                            ti.surrounding_text = txt;
                            ti.pending.surrounding_text = null;
                            ti.cursor = ti.pending.cursor;
                            ti.anchor = ti.pending.anchor;
                        }
                        ti.change_cause = ti.pending.change_cause;
                        ti.pending.change_cause = p.zwp_text_input_v3.change_cause.input_method;
                        ti.content_hint = ti.pending.content_hint;
                        ti.content_purpose = ti.pending.content_purpose;
                        ti.cursor_rect = ti.pending.cursor_rect;
                    }
                },
                else => return error.InvalidOpcode,
            },
        }
    }

    fn copyRegionArg(s: *Server, c: *Client, region_id: u32) !?[]RegionOp {
        if (region_id == 0) return null;
        const reg = switch (c.objects.get(region_id) orelse return error.InvalidObject) {
            .region => |x| x,
            else => return error.InvalidObject,
        };
        return try s.gpa.dupe(RegionOp, reg.ops.items);
    }

    fn bind(s: *Server, c: *Client, name: u32, id: u32, version: u32) !void {
        switch (name) {
            1 => try c.addObject(id, .compositor),
            2 => {
                try c.addObject(id, .shm);
                for (buffer_formats) |f| if (c.send(id, p.wl_shm.event.format)) |m0| {
                    var e = m0;
                    e.uint(shmCode(f)).end();
                };
            },
            3 => try c.addObject(id, .{ .wm_base = version }),
            4 => {
                try c.addObject(id, .dmabuf);
                const mod = p.modifier.broadcom_vc4_t_tiled;
                for (buffer_formats) |f| {
                    if (c.send(id, p.zwp_linux_dmabuf_v1.event.format)) |m0| {
                        var e = m0;
                        e.uint(f.fourcc()).end();
                    }
                    if (c.send(id, p.zwp_linux_dmabuf_v1.event.modifier)) |m0| {
                        var e = m0;
                        e.uint(f.fourcc()).uint(@truncate(mod >> 32)).uint(@truncate(mod)).end();
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
            7 => try c.addObject(id, .{ .data_device_manager = version }),
            8 => try c.addObject(id, .subcompositor),
            10 => try c.addObject(id, .pointer_constraints),
            11 => try c.addObject(id, .relative_pointer_manager),
            12 => {
                try c.addObject(id, .presentation);
                sendTo(c, id, p.wp_presentation.event.clock_id, .{@as(u32, p.wp_presentation.clock.monotonic)});
            },
            13 => try c.addObject(id, .text_input_manager),
            14 => try c.addObject(id, .decoration_manager),
            15 => try c.addObject(id, .viewporter),
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

    fn sendLeave(_: *Server, c: *Client, surf: *Surface) void {
        var it = c.objects.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .output) sendTo(c, surf.id, p.wl_surface.event.leave, .{e.key_ptr.*});
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
                // The layout's XKB keymap (key events carry Linux key
                // codes, which are its key codes less 8).
                s.sendKeymap(c, id);
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
    /// the work area (or, over a fullscreen window, the screen) as far as
    /// its constraint adjustments allow.
    fn placePopup(s: *const Server, pp: *Popup, pos: Positioner) void {
        pp.positioner = pos;
        const area: ?placement.Rect = if (pp.parent) |parent| if (parent.surface) |ps| if (s.surfaceOrigin(ps)) |o| blk: {
            const wa = if (s.rootToplevel(ps)) |t| s.areaOf(t) else s.work_area;
            break :blk .{
                .x = wa.x - o[0],
                .y = wa.y - o[1],
                .w = @intCast(wa.width),
                .h = @intCast(wa.height),
            };
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

    /// Whether `sub` (or one of its ancestor subsurfaces) is in synchronized mode.
    fn isSubsurfaceSync(_: *const Server, sub: *const Subsurface) bool {
        var cur: ?*const Subsurface = sub;
        while (cur) |cs| {
            if (cs.sync) return true;
            cur = if (cs.parent) |p_surf| p_surf.sub else null;
        }
        return false;
    }

    fn clearSubsurfaceCached(s: *Server, sub: *Subsurface, c: ?*Client) void {
        if (sub.cached.buffer) |b| {
            sub.cached.buffer = null;
            s.dropBuffer(b);
        }
        if (c) |cl| {
            for (sub.cached.callbacks.items) |id| _ = cl.objects.remove(id);
            for (sub.cached.feedback.items) |id| sendFeedbackDiscarded(cl, id);
        }
        sub.cached.callbacks.deinit(s.gpa);
        sub.cached.feedback.deinit(s.gpa);
        if (sub.cached.input_region) |ops| s.gpa.free(ops);
        if (sub.cached.opaque_region) |ops| s.gpa.free(ops);
        sub.cached = .{};
    }

    fn cacheSubsurfaceCommit(s: *Server, surf: *Surface, sub: *Subsurface) !void {
        sub.cached.has_state = true;
        if (surf.pending_attach) {
            surf.pending_attach = false;
            const nb = surf.pending_buffer;
            surf.pending_buffer = null;
            if (sub.cached.buffer) |old| s.dropBuffer(old);
            sub.cached.buffer = nb;
            if (nb) |b| b.uses += 1;
            sub.cached.attach = true;
            for (sub.cached.feedback.items) |id| sendFeedbackDiscarded(surf.client, id);
            sub.cached.feedback.clearRetainingCapacity();
        }
        if (surf.pending_scale) |sc| {
            sub.cached.scale = sc;
            surf.pending_scale = null;
        }
        if (surf.pending_transform) |tf| {
            sub.cached.transform = tf;
            surf.pending_transform = null;
        }
        if (surf.pending_input_region_set) {
            if (sub.cached.input_region) |old| s.gpa.free(old);
            sub.cached.input_region = surf.pending_input_region;
            sub.cached.input_region_set = true;
            surf.pending_input_region = null;
            surf.pending_input_region_set = false;
        }
        if (surf.pending_opaque_region_set) {
            if (sub.cached.opaque_region) |old| s.gpa.free(old);
            sub.cached.opaque_region = surf.pending_opaque_region;
            sub.cached.opaque_region_set = true;
            surf.pending_opaque_region = null;
            surf.pending_opaque_region_set = false;
        }
        try sub.cached.callbacks.appendSlice(s.gpa, surf.pending_callbacks.items);
        surf.pending_callbacks.clearRetainingCapacity();
        try sub.cached.feedback.appendSlice(s.gpa, surf.pending_feedback.items);
        surf.pending_feedback.clearRetainingCapacity();
    }

    fn applySubsurfaceCached(s: *Server, sub: *Subsurface) anyerror!void {
        if (!sub.cached.has_state) return;
        const surf = sub.surface orelse {
            s.clearSubsurfaceCached(sub, null);
            return;
        };
        sub.cached.has_state = false;
        if (sub.cached.attach) {
            sub.cached.attach = false;
            const b = sub.cached.buffer;
            sub.cached.buffer = null;
            defer if (b) |nb| s.dropBuffer(nb);
            if (!surf.pending_attach) {
                surf.pending_attach = true;
                surf.pending_buffer = b;
            }
        }
        if (sub.cached.scale) |sc| {
            if (surf.pending_scale == null) surf.pending_scale = sc;
            sub.cached.scale = null;
        }
        if (sub.cached.transform) |tf| {
            if (surf.pending_transform == null) surf.pending_transform = tf;
            sub.cached.transform = null;
        }
        if (sub.cached.input_region_set) {
            if (!surf.pending_input_region_set) {
                surf.pending_input_region = sub.cached.input_region;
                surf.pending_input_region_set = true;
            } else if (sub.cached.input_region) |ops| s.gpa.free(ops);
            sub.cached.input_region = null;
            sub.cached.input_region_set = false;
        }
        if (sub.cached.opaque_region_set) {
            if (!surf.pending_opaque_region_set) {
                surf.pending_opaque_region = sub.cached.opaque_region;
                surf.pending_opaque_region_set = true;
            } else if (sub.cached.opaque_region) |ops| s.gpa.free(ops);
            sub.cached.opaque_region = null;
            sub.cached.opaque_region_set = false;
        }
        try surf.pending_callbacks.insertSlice(s.gpa, 0, sub.cached.callbacks.items);
        sub.cached.callbacks.clearRetainingCapacity();
        try surf.pending_feedback.insertSlice(s.gpa, 0, sub.cached.feedback.items);
        sub.cached.feedback.clearRetainingCapacity();
        try s.applySurfaceCommit(surf.client, surf);
    }

    /// Takes a subsurface out of its parent's list.
    fn detachSubsurface(_: *Server, sub: *Subsurface) void {
        const parent = sub.parent orelse return;
        if (std.mem.indexOfScalar(*Subsurface, parent.subsurfaces.items, sub)) |i| _ = parent.subsurfaces.orderedRemove(i);
    }

    fn destroySubsurface(s: *Server, sub: *Subsurface) void {
        s.clearSubsurfaceCached(sub, if (sub.surface) |surf| surf.client else null);
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
        if (s.drag) |d| if (d.icon == surf) {
            if (surf.texture() == null) return null;
            const pos = s.dragPos(d);
            return .{ @intFromFloat(@round(pos[0])), @intFromFloat(@round(pos[1])) };
        };
        if (s.cursor_surface == surf and s.pointer_focus != null and s.grab == null and !s.pointerLocked()) {
            if (surf.texture() == null) return null;
            return .{
                @as(i32, @intFromFloat(@round(s.pointer_x))) - s.cursor_hotspot[0],
                @as(i32, @intFromFloat(@round(s.pointer_y))) - s.cursor_hotspot[1],
            };
        }
        const x = surf.xdg orelse return null;
        if (x.toplevel) |t| {
            if (!t.shown()) return null;
            const r = s.windowRect(t);
            const gx = if (x.geometry) |g| g.x else 0;
            const gy = if (x.geometry) |g| g.y else 0;
            return .{ r.x - gx, r.y - gy };
        }
        const pp = x.popup orelse return null;
        if (!pp.mapped) return null;
        const parent = pp.parent orelse return null;
        const ps = parent.surface orelse return null;
        const o = s.surfaceOrigin(ps) orelse return null;
        const pgx = if (parent.geometry) |g| g.x else 0;
        const pgy = if (parent.geometry) |g| g.y else 0;
        const gx = if (x.geometry) |g| g.x else 0;
        const gy = if (x.geometry) |g| g.y else 0;
        return .{ o[0] + pgx + pp.x - gx, o[1] + pgy + pp.y - gy };
    }

    /// Something to draw: a surface's picture, at a place on the screen,
    /// with its logical size and buffer transform, clipped to an area.
    /// A `preview` is not a surface's: it shows, shaded, what a window
    /// dragged to an edge will fill (its texture is not drawn).
    pub const Quad = struct {
        texture: Texture,
        x: i32,
        y: i32,
        width: u32 = 0,
        height: u32 = 0,
        transform: u3 = 0,
        clip: Rect,
        preview: bool = false,
        /// A rounded window: its corners' radius on the screen, and
        /// whether it has a shadow, drawn within `shadow_clip`.
        radius: u16 = 0,
        shadow: bool = false,
        shadow_clip: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        /// Less than 1: drawn see-through, over what is under it (a
        /// window's old frame, fading out).
        opacity: f32 = 1,
    };

    /// How a window's main surface is drawn: rounded, with a shadow.
    const Rounding = struct { radius: u32 = 0, shadow: bool = false, shadow_clip: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };

    /// How `t` is rounded: only if its client asked, its surface is the
    /// window (no geometry within it) and it is shown in the usual way.
    fn rounding(t: *const Toplevel) u32 {
        const r = t.shownRadius();
        if (r == 0) return 0;
        const surf = t.xdg.surface orelse return 0;
        if (surf.transform != 0) return 0;
        const sz = surf.size() orelse return 0;
        if (t.xdg.geometry) |g| if (g.x != 0 or g.y != 0 or g.width != sz[0] or g.height != sz[1]) return 0;
        if (sz[0] < 2 * r or sz[1] < 2 * r) return 0;
        return r;
    }

    /// What to draw, bottom first: each window that can be seen, with its
    /// subsurfaces, then its popups, a drag icon, and a custom cursor
    /// surface on top (the top ones, if there are more than fit in `buf`).
    pub fn drawList(s: *const Server, buf: []Quad) []Quad {
        var list: std.ArrayList(Quad) = .initBuffer(buf);
        if (s.overviewShown()) {
            // Each window in its place, smaller (or on its way there), in
            // their stacking order: the top one drawn last.
            var slots: [32]OverviewSlot = undefined;
            const layout = s.overviewLayout(&slots);
            const e = easeInOut(s.overview_t);
            for (s.toplevels.items) |t| {
                const slot = for (layout) |sl| {
                    if (sl.t == t) break sl;
                } else continue;
                const surf = t.xdg.surface orelse continue;
                const from = s.windowRect(t);
                const to = lerpRect(from, slot.rect, e);
                const radius = @as(u64, rounding(t)) * to.width / @max(from.width, 1);
                s.addTreeScaled(&list, surf, from, to, @intCast(radius));
            }
            return list.items;
        }
        var shown: [32]*Toplevel = undefined;
        for (s.visibleWindows(&shown)) |t| {
            const surf = t.xdg.surface orelse continue;
            // Clipped to the work area, or the screen for a fullscreen one.
            const clip = s.areaOf(t);
            // Under the window being moved, what it will fill.
            if (s.grab) |g| if (g.t == t) if (s.snapRect()) |r| if (surf.texture()) |tex| {
                const inset = 8;
                if (list.items.len == list.capacity) _ = list.orderedRemove(0);
                list.appendAssumeCapacity(.{
                    .texture = tex,
                    .x = r.x + inset,
                    .y = r.y + inset,
                    .width = r.width -| 2 * inset,
                    .height = r.height -| 2 * inset,
                    .clip = s.work_area,
                    .preview = true,
                });
            };
            // On its way to its place, after its state changed: what it
            // shows now, stretched to where the window is on the way, and
            // what it showed before over it, fading out. Their corners go
            // from the old frame's roundness to the new one's.
            if (t.anim) |a| {
                const to = s.windowRect(t);
                const e = easeInOut(a.k);
                const at = lerpRect(a.from, to, e);
                const radius = if (a.old) |o| lerpU32(o.radius, rounding(t), e) else rounding(t);
                s.addTreeScaled(&list, surf, to, at, radius);
                if (a.old) |o| {
                    const fx = @as(f64, @floatFromInt(at.width)) / @as(f64, @floatFromInt(@max(a.from.width, 1)));
                    const fy = @as(f64, @floatFromInt(at.height)) / @as(f64, @floatFromInt(@max(a.from.height, 1)));
                    if (list.items.len == list.capacity) _ = list.orderedRemove(0);
                    list.appendAssumeCapacity(.{
                        .texture = o.texture,
                        .x = at.x + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(o.x)) * fx))),
                        .y = at.y + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(o.y)) * fy))),
                        .width = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(o.width)) * fx))), 1),
                        .height = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(o.height)) * fy))), 1),
                        .transform = o.transform,
                        .clip = at,
                        .radius = @intCast(radius),
                        .opacity = 1 - e,
                    });
                }
                continue;
            }
            // A tiled window drawn wider than its half is cut to it.
            const win_clip = if (t.shown_tiled) |side| s.tileRect(side) else clip;
            s.addTree(&list, surf, win_clip, .{ .radius = rounding(t), .shadow = true, .shadow_clip = s.screen() });
            for (s.popups.items) |pp| if (pp.xdg.surface) |ps| if (s.rootToplevel(ps) == t) s.addTree(&list, ps, clip, .{});
        }
        if (s.drag) |d| if (d.icon) |icon| s.addTree(&list, icon, s.screen(), .{});
        if (s.cursor_surface) |cs| if (s.pointer_focus != null and s.grab == null and !s.pointerLocked()) s.addTree(&list, cs, s.screen(), .{});
        return list.items;
    }

    /// A surface and its subsurfaces, above it; the surface rounded as
    /// `round` says (not its subsurfaces).
    fn addTree(s: *const Server, list: *std.ArrayList(Quad), surf: *const Surface, clip: Rect, round: Rounding) void {
        const o = s.surfaceOrigin(surf) orelse return;
        if (surf.texture()) |tex| {
            const sz = surf.size().?;
            // Over the most there is room for: the newest, at the top.
            if (list.items.len == list.capacity) _ = list.orderedRemove(0);
            list.appendAssumeCapacity(.{
                .texture = tex,
                .x = o[0],
                .y = o[1],
                .width = sz[0],
                .height = sz[1],
                .transform = surf.transform,
                .clip = clip,
                .radius = @intCast(round.radius),
                .shadow = round.radius > 0 and round.shadow,
                .shadow_clip = round.shadow_clip,
            });
        }
        for (surf.subsurfaces.items) |sub| if (sub.surface) |child| s.addTree(list, child, clip, .{});
    }

    /// Slow at the start and the end, quick between (cubic).
    fn easeInOut(t: f32) f32 {
        const x = std.math.clamp(t, 0, 1);
        if (x < 0.5) return 4 * x * x * x;
        const u = -2 * x + 2;
        return 1 - u * u * u / 2;
    }

    fn lerpU32(a: u32, b: u32, k: f32) u32 {
        const fa: f32 = @floatFromInt(a);
        return @intFromFloat(@round(fa + (@as(f32, @floatFromInt(b)) - fa) * k));
    }

    /// `a`, `k` of the way to `b`.
    fn lerpRect(a: Rect, b: Rect, k: f32) Rect {
        const f = struct {
            fn i(x: i32, y: i32, t: f32) i32 {
                return x + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(y - x)) * t)));
            }
            fn u(x: u32, y: u32, t: f32) u32 {
                return @intCast(@max(i(@intCast(x), @intCast(y), t), 1));
            }
        };
        return .{ .x = f.i(a.x, b.x, k), .y = f.i(a.y, b.y, k), .width = f.u(a.width, b.width, k), .height = f.u(a.height, b.height, k) };
    }

    /// A window's surface and its subsurfaces, drawn with the window (at
    /// `from` on the screen) stretched to fill `to` instead, and clipped
    /// to it; the window's surface with its corners rounded by `radius`
    /// (on the screen), without a shadow.
    fn addTreeScaled(s: *const Server, list: *std.ArrayList(Quad), surf: *const Surface, from: Rect, to: Rect, radius: u32) void {
        const o = s.surfaceOrigin(surf) orelse return;
        const fx = @as(f64, @floatFromInt(to.width)) / @as(f64, @floatFromInt(@max(from.width, 1)));
        const fy = @as(f64, @floatFromInt(to.height)) / @as(f64, @floatFromInt(@max(from.height, 1)));
        if (surf.texture()) |tex| {
            const sz = surf.size().?;
            if (list.items.len == list.capacity) _ = list.orderedRemove(0);
            list.appendAssumeCapacity(.{
                .texture = tex,
                .x = to.x + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(o[0] - from.x)) * fx))),
                .y = to.y + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(o[1] - from.y)) * fy))),
                .width = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sz[0])) * fx))), 1),
                .height = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sz[1])) * fy))), 1),
                .transform = surf.transform,
                .clip = to,
                .radius = @intCast(radius),
            });
        }
        for (surf.subsurfaces.items) |sub| if (sub.surface) |child| s.addTreeScaled(list, child, from, to, 0);
    }

    /// The topmost surface of a tree (`surf` and its subsurfaces) at
    /// (`x`, `y`) on the screen.
    fn hitTree(s: *const Server, surf: *Surface, x: f64, y: f64) ?*Surface {
        var i = surf.subsurfaces.items.len;
        while (i > 0) {
            i -= 1;
            if (surf.subsurfaces.items[i].surface) |child| if (s.hitTree(child, x, y)) |hit| return hit;
        }
        const sz = surf.size() orelse return null;
        const o = s.surfaceOrigin(surf) orelse return null;
        const lx = x - @as(f64, @floatFromInt(o[0]));
        const ly = y - @as(f64, @floatFromInt(o[1]));
        if (lx >= 0 and lx < @as(f64, @floatFromInt(sz[0])) and ly >= 0 and ly < @as(f64, @floatFromInt(sz[1]))) {
            if (surf.input_region) |ops| {
                if (!Region.contains(ops, @intFromFloat(@floor(lx)), @intFromFloat(@floor(ly)))) return null;
            }
            return surf;
        }
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
        if (s.drag) |d| if (d.source == src) s.cancelDrag();
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
        if (s.drag) |*d| if (d.offer == offer) {
            d.offer = null;
        };
        if (offer.dropped and offer.active) {
            offer.active = false;
            if (offer.source) |src| if (!src.client.dead) {
                if (offer.version < 3) {
                    if (src.version >= 3) sendTo(src.client, src.id, p.wl_data_source.event.dnd_finished, .{});
                } else {
                    if (src.version >= 3 and src.action != 0) {
                        src.action = 0;
                        sendTo(src.client, src.id, p.wl_data_source.event.action, .{@as(u32, 0)});
                    }
                    sendCancelled(src);
                }
            };
        }
        if (std.mem.indexOfScalar(*DataOffer, s.offers.items, offer)) |i| _ = s.offers.swapRemove(i);
        s.gpa.destroy(offer);
    }

    /// Tells the client with the keyboard what the clipboard holds.
    fn sendSelection(s: *Server) void {
        const surf = s.keyboard_focus orelse return;
        const c = surf.client;
        var devices: [4]struct { id: u32, version: u32 } = undefined;
        var n: usize = 0;
        var it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .data_device => |v| if (n < devices.len) {
                devices[n] = .{ .id = e.key_ptr.*, .version = v };
                n += 1;
            },
            else => {},
        };
        // (Offers are added to the objects: not while iterating them.)
        for (devices[0..n]) |dev| s.sendSelectionTo(c, dev.id, dev.version);
    }

    /// Sends a client's data device a new offer of `src`, with its MIME
    /// types (and drag actions, if `dnd`).
    fn makeOffer(s: *Server, c: *Client, device: u32, version: u32, src: *DataSource, dnd: bool) ?*DataOffer {
        const offer = s.gpa.create(DataOffer) catch return null;
        const id = c.next_server_id;
        c.next_server_id += 1;
        offer.* = .{ .client = c, .id = id, .version = version, .source = src, .dnd = dnd };
        s.offers.append(s.gpa, offer) catch {
            s.gpa.destroy(offer);
            return null;
        };
        c.objects.put(s.gpa, id, .{ .data_offer = offer }) catch {
            _ = s.offers.pop();
            s.gpa.destroy(offer);
            return null;
        };
        sendTo(c, device, p.wl_data_device.event.data_offer, .{id});
        for (src.mime_types.items) |mime| if (c.send(id, p.wl_data_offer.event.offer)) |m0| {
            var m = m0;
            m.string(mime).end();
        };
        if (dnd and version >= 3) sendTo(c, id, p.wl_data_offer.event.source_actions, .{src.actions orelse 0});
        return offer;
    }

    /// Sends a client's data device a new offer of what the clipboard
    /// holds, with its MIME types, as the selection (or that it is empty).
    fn sendSelectionTo(s: *Server, c: *Client, device: u32, version: u32) void {
        if (c.dead) return;
        const src = s.selection orelse {
            sendTo(c, device, p.wl_data_device.event.selection, .{@as(u32, 0)});
            return;
        };
        const offer = s.makeOffer(c, device, version, src, false) orelse return;
        sendTo(c, device, p.wl_data_device.event.selection, .{offer.id});
    }

    /// A client asks for what an offer holds, as `mime`, written to `fd`:
    /// its source is asked to write it. If it has gone, `fd` is closed
    /// (and the client reads nothing).
    fn receive(_: *Server, offer: *DataOffer, mime: []const u8, fd: linux.fd_t) void {
        if (offer.dnd and !offer.active) {
            _ = linux.close(fd);
            return;
        }
        const src = offer.source orelse {
            _ = linux.close(fd);
            return;
        };
        if (src.client.send(src.id, p.wl_data_source.event.send)) |m0| {
            var m = m0;
            m.string(mime).fd(fd).end();
        } else _ = linux.close(fd);
    }

    // --- Drag and drop ---------------------------------------------------------

    /// Whether `origin` has the active button press or touch with `serial`,
    /// and from where.
    fn dragAllowed(s: *const Server, origin: *const Surface, serial: u32) ?GrabBy {
        if (s.grab != null or s.drag != null) return null;
        if (s.buttons_down != 0 and serial == s.press_serial and s.pointer_focus == origin) return .{ .press_x = s.press_x, .press_y = s.press_y, .x = s.pointer_x, .y = s.pointer_y };
        if (serial == s.touch_serial) if (s.touchPoint(s.touch_serial_id)) |tp| if (tp.surface == origin) return .{ .press_x = tp.press_x, .press_y = tp.press_y, .x = tp.x, .y = tp.y, .touch = tp.id };
        return null;
    }

    /// Starts a drag from `origin` (with an optional `src` and `icon`
    /// surface) if `serial` matches the active button press or touch on it.
    fn startDrag(s: *Server, c: *Client, src: ?*DataSource, origin: *Surface, icon: ?*Surface, serial: u32) void {
        const by = s.dragAllowed(origin, serial) orelse {
            if (src) |ds| sendCancelled(ds);
            return;
        };
        s.drag = .{ .client = c, .source = src, .icon = icon, .touch = by.touch };
        s.takeInput(by.touch);
        s.updateLock();
        if (icon) |ic| if (ic.texture() != null) {
            s.damaged = true;
        };
        _ = s.updateDragFocus(.{ by.x, by.y });
    }

    fn dragPos(s: *const Server, d: Drag) [2]f64 {
        if (d.touch) |id| if (s.touchPoint(id)) |tp| return .{ tp.x, tp.y };
        return .{ s.pointer_x, s.pointer_y };
    }

    fn clearDragSourceTarget(_: *Server, src: *DataSource) void {
        if (src.client.send(src.id, p.wl_data_source.event.target)) |m0| {
            var e = m0;
            e.string(null).end();
        }
        if (src.version >= 3 and src.action != 0) {
            src.action = 0;
            src.action_sent = true;
            sendTo(src.client, src.id, p.wl_data_source.event.action, .{@as(u32, 0)});
        }
    }

    /// Updates the surface under an active drag, sending `leave` and `enter`
    /// (with a new `wl_data_offer`) when it changes. Returns whether it
    /// changed.
    fn updateDragFocus(s: *Server, pos: [2]f64) bool {
        const d = &(s.drag orelse return false);
        var under = s.surfaceAt(pos[0], pos[1]);
        // Without a data source, only the dragging client's own surfaces
        // receive drag events.
        if (d.source == null) if (under) |u| if (u.client != d.client) {
            under = null;
        };
        if (under == d.focus) return false;
        if (d.focus) |old| {
            broadcast(old.client, .data_device, p.wl_data_device.event.leave, 1, .{});
            if (d.offer) |offer| {
                offer.active = false;
                offer.accepted = false;
                d.offer = null;
            }
            if (d.source) |src| if (under == null) s.clearDragSourceTarget(src);
        }
        d.focus = under;
        const surf = under orelse return true;
        const c = surf.client;
        if (c.dead) return true;
        var devices: [4]struct { id: u32, version: u32 } = undefined;
        var n: usize = 0;
        var it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .data_device => |v| if (n < devices.len) {
                devices[n] = .{ .id = e.key_ptr.*, .version = v };
                n += 1;
            },
            else => {},
        };
        const local = s.localTo(surf, pos[0], pos[1]);
        const serial = s.nextSerial();
        for (devices[0..n]) |dev| {
            if (d.source) |src| {
                const offer = s.makeOffer(c, dev.id, dev.version, src, true) orelse continue;
                offer.active = true;
                d.offer = offer;
                sendTo(c, dev.id, p.wl_data_device.event.enter, .{ serial, surf.id, local[0], local[1], offer.id });
                s.negotiateAction(offer);
            } else {
                sendTo(c, dev.id, p.wl_data_device.event.enter, .{ serial, surf.id, local[0], local[1], @as(u32, 0) });
            }
        }
        return true;
    }

    /// A drag follows the pointer or touch to (`x`, `y`).
    fn dragTo(s: *Server, time_ms: u32, x: f64, y: f64) void {
        const d = s.drag orelse return;
        if (d.icon) |icon| if (icon.texture() != null) {
            s.damaged = true;
        };
        // Entering a surface carries the position.
        if (s.updateDragFocus(.{ x, y })) return;
        const surf = (s.drag orelse return).focus orelse return;
        const local = s.localTo(surf, x, y);
        broadcast(surf.client, .data_device, p.wl_data_device.event.motion, 1, .{ time_ms, local[0], local[1] });
    }

    /// Chooses the drag action from what the source and target offer support,
    /// and notifies either side whose action changed.
    fn negotiateAction(_: *Server, offer: *DataOffer) void {
        const src = offer.source orelse return;
        const A = p.wl_data_device_manager.dnd_action;
        const src_actions: u32 = if (src.version < 3) (A.copy | A.move) else (src.actions orelse 0);
        const dst_actions: u32 = if (offer.version < 3) (if (offer.accepted) src_actions else 0) else offer.actions;
        const common = src_actions & dst_actions;
        const chosen: u32 = if (common == 0)
            A.none
        else if (offer.preferred_action != 0 and (common & offer.preferred_action) != 0)
            offer.preferred_action
        else if ((common & A.copy) != 0)
            A.copy
        else if ((common & A.move) != 0)
            A.move
        else if ((common & A.ask) != 0)
            A.ask
        else
            A.none;
        if (offer.version >= 3 and (!offer.action_sent or offer.action != chosen)) {
            offer.action = chosen;
            offer.action_sent = true;
            sendTo(offer.client, offer.id, p.wl_data_offer.event.action, .{chosen});
        }
        if (src.version >= 3 and (!src.action_sent or src.action != chosen)) {
            src.action = chosen;
            src.action_sent = true;
            sendTo(src.client, src.id, p.wl_data_source.event.action, .{chosen});
        }
    }

    /// Ends an active drag when the buttons are released or the touch comes
    /// up: drops onto the focused surface if accepted, or cancels the drag.
    fn endDrag(s: *Server) void {
        const d = s.drag orelse return;
        s.drag = null;
        if (d.icon != null) s.damaged = true;
        if (d.source) |src| {
            const accepted = if (d.focus != null) if (d.offer) |offer|
                offer.accepted and ((src.version < 3 and offer.version < 3) or offer.action != 0 or src.action != 0)
            else
                false else false;
            if (accepted) {
                const surf = d.focus.?;
                const offer = d.offer.?;
                offer.dropped = true;
                broadcast(surf.client, .data_device, p.wl_data_device.event.drop, 1, .{});
                if (src.version >= 3) sendTo(src.client, src.id, p.wl_data_source.event.dnd_drop_performed, .{});
            } else {
                if (d.focus) |surf| broadcast(surf.client, .data_device, p.wl_data_device.event.leave, 1, .{});
                if (d.offer) |offer| offer.active = false;
                if (!src.client.dead) sendCancelled(src);
            }
        } else if (d.focus) |surf| {
            broadcast(surf.client, .data_device, p.wl_data_device.event.drop, 1, .{});
            broadcast(surf.client, .data_device, p.wl_data_device.event.leave, 1, .{});
        }
        if (s.updatePointerFocus()) s.pointerFrame();
    }

    /// Cancels an active drag (when its source is destroyed).
    fn cancelDrag(s: *Server) void {
        const d = s.drag orelse return;
        s.drag = null;
        if (d.icon != null) s.damaged = true;
        if (d.focus) |surf| broadcast(surf.client, .data_device, p.wl_data_device.event.leave, 1, .{});
        if (d.offer) |offer| offer.active = false;
        if (s.updatePointerFocus()) s.pointerFrame();
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
    fn grabTo(s: *Server, g0: Grab, x: f64, y: f64) void {
        var g = g0;
        if (g.resize) |r| return s.resizeTo(g.t, r, x, y);
        if (g.unsnap) {
            // Maximized or tiled: it stays so until dragged a way.
            if (@abs(x - g.x) < unsnap_after and @abs(y - g.y) < unsnap_after) return;
            g = s.unsnap(g);
            s.grab = g;
        }
        const at = s.resistEdges(g.t, x - g.dx, y - g.dy);
        s.moveWindow(g.t, at[0], at[1]);
        s.setSnap(s.snapAt(x, y));
    }

    /// Where a window moved to (`x`, `y`) by the pointer goes, the work
    /// area's edges resisting, as GNOME's do (mutter's edge-resistance.c):
    /// moving towards one, its edge stops at it until the pointer would
    /// take it `edge_resistance` past, then follows the pointer again.
    fn resistEdges(s: *const Server, t: *const Toplevel, x: f64, y: f64) [2]f64 {
        const wa = s.work_area;
        const size = s.windowRect(t);
        const w: f64 = @floatFromInt(size.width);
        const h: f64 = @floatFromInt(size.height);
        const left: f64 = @floatFromInt(wa.x);
        const right = left + @as(f64, @floatFromInt(wa.width));
        const bottom = @as(f64, @floatFromInt(wa.y)) + @as(f64, @floatFromInt(wa.height));
        const old_x: f64 = @floatFromInt(t.x);
        const old_y: f64 = @floatFromInt(t.y);
        return .{
            resist(old_x, x, left, right - w),
            resist(old_y, y, -std.math.inf(f64), bottom - h),
        };
    }

    /// How far past an edge the pointer takes a window before it goes on.
    pub const edge_resistance = 32;

    /// `new` (from `old`), stopped at `low` or `high` if it is moving
    /// past it, from it or within, by less than `edge_resistance`.
    fn resist(old: f64, new: f64, low: f64, high: f64) f64 {
        const e: f64 = edge_resistance;
        if (new < old and old >= low and new < low and low - new < e) return low;
        if (new > old and old <= high and new > high and new - high < e) return high;
        return new;
    }

    /// A maximized or tiled window dragged away is restored to its own
    /// size, under the pointer: as far along it (across) as the pointer
    /// was along the window, and as far down (its title bar, still under
    /// the pointer). Returns the grab, from there.
    fn unsnap(s: *Server, g: Grab) Grab {
        const t = g.t;
        const was = s.windowRect(t);
        // (Not with setMaximized, which ends the move.)
        t.maximized = false;
        t.tiled = null;
        const size = s.configuredSize(t);
        t.width = size[0];
        t.height = size[1];
        if (t.xdg.configured) s.configure(t.xdg.surface.?.client, t);
        s.replacePopups(t);
        const along = std.math.clamp((g.x - @as(f64, @floatFromInt(was.x))) / @as(f64, @floatFromInt(@max(was.width, 1))), 0, 1);
        const down = std.math.clamp(g.y - @as(f64, @floatFromInt(was.y)), 0, @as(f64, @floatFromInt(size[1])) - 1);
        var out = g;
        out.unsnap = false;
        out.dx = along * @as(f64, @floatFromInt(size[0]));
        out.dy = down;
        // It is no longer anchored to an edge, and is drawn where it goes.
        t.anchor_right = null;
        t.anchor_bottom = null;
        t.placed = true;
        s.damaged = true;
        return out;
    }

    /// Where a window let go with the pointer at (`x`, `y`) goes: at the
    /// work area's top edge, filling it; at its left or right edge, the
    /// half there.
    fn snapAt(s: *const Server, x: f64, y: f64) ?Snap {
        const wa = s.work_area;
        const left: f64 = @floatFromInt(wa.x);
        const right: f64 = @floatFromInt(wa.x + @as(i32, @intCast(wa.width)));
        const top: f64 = @floatFromInt(wa.y);
        if (y < top + snap_edge) return .maximize;
        if (x < left + snap_edge) return .left;
        if (x >= right - snap_edge) return .right;
        return null;
    }

    fn setSnap(s: *Server, snap: ?Snap) void {
        if (snap == s.snap) return;
        s.snap = snap;
        s.damaged = true;
    }

    /// The half of the work area a window tiled there fills.
    pub fn tileRect(s: *const Server, side: Tile) Rect {
        const wa = s.work_area;
        const left_w = wa.width / 2;
        return switch (side) {
            .left => .{ .x = wa.x, .y = wa.y, .width = left_w, .height = wa.height },
            .right => .{ .x = wa.x + @as(i32, @intCast(left_w)), .y = wa.y, .width = wa.width - left_w, .height = wa.height },
        };
    }

    /// What the window being moved will fill if it is let go now: shown,
    /// shaded, under it.
    pub fn snapRect(s: *const Server) ?Rect {
        const snap = s.snap orelse return null;
        return switch (snap) {
            .maximize => s.work_area,
            .left => s.tileRect(.left),
            .right => s.tileRect(.right),
        };
    }

    /// Fills half the work area with a window, or not.
    fn setTiled(s: *Server, c: *Client, t: *Toplevel, side: ?Tile) void {
        if (t.tiled == side and !t.maximized) return;
        t.maximized = false;
        t.tiled = side;
        t.anchor_right = null;
        t.anchor_bottom = null;
        if (t.xdg.configured) s.configure(c, t);
        s.damaged = true;
        s.replacePopups(t);
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
        free.* = .{ .id = id, .surface = surf, .press_x = x, .press_y = y, .x = x, .y = y };
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
        if (s.drag) |d| if (d.touch == id) return s.dragTo(time_ms, x, y);
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
        if (s.grab) |g| if (g.touch == id) return s.dropGrab();
        if (s.drag) |d| if (d.touch == id) return s.endDrag();
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

    /// Clamps (`x`, `y`) to the active pointer confinement region, if one is
    /// in effect.
    pub fn clampPointer(s: *const Server, x: f64, y: f64) [2]f64 {
        const lock = s.active_lock orelse return .{ x, y };
        if (lock.lock) return .{ s.pointer_x, s.pointer_y };
        const surf = lock.surface orelse return .{ x, y };
        const o = s.surfaceOrigin(surf) orelse return .{ x, y };
        const sz = surf.size() orelse return .{ x, y };
        const ox: f64 = @floatFromInt(o[0]);
        const oy: f64 = @floatFromInt(o[1]);
        var min_x: f64 = 0;
        var min_y: f64 = 0;
        var max_x: f64 = @floatFromInt(@max(sz[0], 1) - 1);
        var max_y: f64 = @floatFromInt(@max(sz[1], 1) - 1);
        if (surf.input_region) |ops| if (Region.bounds(ops)) |b| {
            min_x = @max(min_x, @as(f64, @floatFromInt(b.x)));
            min_y = @max(min_y, @as(f64, @floatFromInt(b.y)));
            max_x = @min(max_x, @as(f64, @floatFromInt(b.x + @as(i32, @intCast(b.width)) - 1)));
            max_y = @min(max_y, @as(f64, @floatFromInt(b.y + @as(i32, @intCast(b.height)) - 1)));
        };
        if (lock.region) |ops| if (Region.bounds(ops)) |b| {
            min_x = @max(min_x, @as(f64, @floatFromInt(b.x)));
            min_y = @max(min_y, @as(f64, @floatFromInt(b.y)));
            max_x = @min(max_x, @as(f64, @floatFromInt(b.x + @as(i32, @intCast(b.width)) - 1)));
            max_y = @min(max_y, @as(f64, @floatFromInt(b.y + @as(i32, @intCast(b.height)) - 1)));
        };
        const lx = std.math.clamp(x - ox, min_x, @max(min_x, max_x));
        const ly = std.math.clamp(y - oy, min_y, @max(min_y, max_y));
        const ix: i32 = @intFromFloat(@floor(lx));
        const iy: i32 = @intFromFloat(@floor(ly));
        if (surf.input_region) |ops| if (!Region.contains(ops, ix, iy)) return .{ s.pointer_x, s.pointer_y };
        if (lock.region) |ops| if (!Region.contains(ops, ix, iy)) return .{ s.pointer_x, s.pointer_y };
        return .{ ox + lx, oy + ly };
    }

    /// Moves the pointer to (`x`, `y`) on the screen. Finish a batch of
    /// pointer events with `pointerFrame`.
    pub fn pointerMotion(s: *Server, time_ms: u32, x: f64, y: f64) void {
        const clamped = s.clampPointer(x, y);
        s.pointer_x = clamped[0];
        s.pointer_y = clamped[1];
        if (s.cursor_surface) |cs| if (cs.texture() != null) {
            s.damaged = true;
        };
        if (s.grab) |g| {
            // A touch moves this window, not the pointer.
            if (g.touch != null) return;
            return s.grabTo(g, s.pointer_x, s.pointer_y);
        }
        if (s.drag) |d| {
            if (d.touch != null) return;
            return s.dragTo(time_ms, s.pointer_x, s.pointer_y);
        }
        // Entering a surface carries the position.
        if (s.updatePointerFocus()) return;
        s.updateLock();
        const surf = s.pointer_focus orelse return;
        const local = s.surfaceLocal();
        broadcast(surf.client, .pointer, p.wl_pointer.event.motion, 1, .{ time_ms, local[0], local[1] });
    }

    /// The pointer moved by (`dx`, `dy`), before the screen's edges limit
    /// it: the client under it hears of it (zwp_relative_pointer_v1).
    /// Returns whether the pointer is locked, and so stays where it is
    /// (`pointerMotion` is not called).
    pub fn pointerRelative(s: *Server, time_ms: u32, dx: f64, dy: f64) bool {
        if (s.grab == null and s.drag == null) if (s.pointer_focus) |surf| {
            const us: u64 = @as(u64, time_ms) * 1000;
            broadcast(surf.client, .relative_pointer, p.zwp_relative_pointer_v1.event.relative_motion, 1, .{ @as(u32, @truncate(us >> 32)), @as(u32, @truncate(us)), dx, dy, dx, dy });
        };
        return s.pointerLocked();
    }

    /// The pointer is locked in place (its picture hidden).
    pub fn pointerLocked(s: *const Server) bool {
        return if (s.active_lock) |l| l.lock else false;
    }

    /// Puts the lock or confinement that should be in effect into effect:
    /// the one on the surface under the pointer, if its window is on top
    /// (and nothing is being moved). One that ends is told so.
    fn updateLock(s: *Server) void {
        const top = s.topWindow();
        const want: ?*PointerLock = for (s.locks.items) |lock| {
            const surf = lock.surface orelse continue;
            if (lock.spent or surf != s.pointer_focus or s.grab != null or s.drag != null) continue;
            if (top == null or s.rootToplevel(surf) != top) continue;
            if (lock.region) |ops| if (s.active_lock != lock) {
                const local = s.localTo(surf, s.pointer_x, s.pointer_y);
                if (!Region.contains(ops, @intFromFloat(@floor(local[0])), @intFromFloat(@floor(local[1])))) continue;
            };
            break lock;
        } else null;
        if (want == s.active_lock) return;
        if (s.active_lock) |old| s.endLock(old);
        if (want) |lock| {
            s.active_lock = lock;
            const ev: u16 = if (lock.lock) p.zwp_locked_pointer_v1.event.locked else p.zwp_confined_pointer_v1.event.confined;
            sendTo(lock.client, lock.id, ev, .{});
        }
    }

    fn applyLockHint(s: *Server, lock: *const PointerLock) void {
        if (!lock.lock) return;
        const hint = lock.hint orelse return;
        const surf = lock.surface orelse return;
        const o = s.surfaceOrigin(surf) orelse return;
        const max_x: f64 = @floatFromInt(@max(s.output.width, 1) - 1);
        const max_y: f64 = @floatFromInt(@max(s.output.height, 1) - 1);
        s.pointer_x = std.math.clamp(@as(f64, @floatFromInt(o[0])) + hint[0], 0, max_x);
        s.pointer_y = std.math.clamp(@as(f64, @floatFromInt(o[1])) + hint[1], 0, max_y);
    }

    /// The lock or confinement in effect ends: the client is told, and a
    /// one-shot constraint is spent.
    fn endLock(s: *Server, lock: *PointerLock) void {
        if (s.active_lock != lock) return;
        s.applyLockHint(lock);
        s.active_lock = null;
        const ev: u16 = if (lock.lock) p.zwp_locked_pointer_v1.event.unlocked else p.zwp_confined_pointer_v1.event.unconfined;
        sendTo(lock.client, lock.id, ev, .{});
        if (!lock.persistent) lock.spent = true;
    }

    /// Ends the lock in effect for good, whatever its lifetime: the user
    /// wants the pointer back (the shell's way out of a game that keeps
    /// it).
    pub fn breakLock(s: *Server) void {
        const lock = s.active_lock orelse return;
        s.endLock(lock);
        lock.spent = true;
    }

    fn destroyLock(s: *Server, lock: *PointerLock) void {
        // The client destroyed it: no unlocked/unconfined event, but its
        // cursor position hint still applies if it was active.
        if (s.active_lock == lock) {
            s.applyLockHint(lock);
            s.active_lock = null;
        }
        if (lock.region) |ops| s.gpa.free(ops);
        if (lock.pending_region) |ops| s.gpa.free(ops);
        for (s.locks.items, 0..) |x, i| if (x == lock) {
            _ = s.locks.swapRemove(i);
            break;
        };
        s.gpa.destroy(lock);
    }

    fn buttonBit(button: u32) u32 {
        const idx = button -% evdev.btn_left;
        return @as(u32, 1) << @intCast(@min(idx, 31));
    }

    /// `button` is a Linux button code (BTN_LEFT, ...).
    pub fn pointerButton(s: *Server, time_ms: u32, button: u32, pressed: bool) void {
        const bit = buttonBit(button);
        if (pressed) {
            s.buttons_down |= bit;
        } else {
            if (s.buttons_down & bit == 0) return;
            s.buttons_down &= ~bit;
        }
        if (s.grab) |g| {
            // The move ends when the buttons are released, which are not
            // passed on (a touch's ends when it comes up).
            if (s.buttons_down == 0 and g.touch == null) s.dropGrab();
            return;
        }
        if (s.drag) |d| {
            if (s.buttons_down == 0 and d.touch == null) s.endDrag();
            return;
        }
        // A press on a window's resize border resizes it.
        if (pressed and s.buttons_down == bit and button == evdev.btn_left) if (s.edge_hover) |e| {
            s.dismissGrabs();
            if (e.t != s.topWindow()) {
                s.raiseToplevel(e.t);
                s.updateFocus();
            }
            s.edge_hover = null;
            s.startResize(e.t, e.edges, .{ .press_x = s.pointer_x, .press_y = s.pointer_y, .x = s.pointer_x, .y = s.pointer_y });
            return;
        };
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
        if (pressed) {
            s.press_serial = serial;
            s.press_x = s.pointer_x;
            s.press_y = s.pointer_y;
        }
        broadcast(surf.client, .pointer, p.wl_pointer.event.button, 1, .{ serial, time_ms, button, state });
        if (!pressed and s.buttons_down == 0) _ = s.updatePointerFocus();
    }

    /// Scrolls by `value` (in surface pixels) along `axis` (or stops when
    /// `value` is 0).
    pub fn pointerAxis(s: *Server, time_ms: u32, axis: u32, value: f64) void {
        if (value == 0) return s.pointerAxisStop(time_ms, axis);
        const surf = s.pointer_focus orelse return;
        broadcast(surf.client, .pointer, p.wl_pointer.event.axis_source, 5, .{@as(u32, p.wl_pointer.axis_source.wheel)});
        const discrete: i32 = @intFromFloat(@round(value / 15.0));
        if (discrete != 0) broadcast(surf.client, .pointer, p.wl_pointer.event.axis_discrete, 5, .{ axis, discrete });
        broadcast(surf.client, .pointer, p.wl_pointer.event.axis, 1, .{ time_ms, axis, value });
    }

    /// Stops scrolling along `axis` (version 5).
    pub fn pointerAxisStop(s: *Server, time_ms: u32, axis: u32) void {
        const surf = s.pointer_focus orelse return;
        broadcast(surf.client, .pointer, p.wl_pointer.event.axis_source, 5, .{@as(u32, p.wl_pointer.axis_source.wheel)});
        broadcast(surf.client, .pointer, p.wl_pointer.event.axis_stop, 5, .{ time_ms, axis });
    }

    /// Ends a batch of pointer events that belong together.
    pub fn pointerFrame(s: *Server) void {
        const surf = s.pointer_focus orelse return;
        broadcast(surf.client, .pointer, p.wl_pointer.event.frame, 5, .{});
    }

    /// `key` is a Linux key code (KEY_A, ...).
    pub fn keyboardKey(s: *Server, time_ms: u32, key: u32, pressed: bool) void {
        const changed = s.modifiers.update(key, pressed);
        // Escape ends the overview (no window has the keyboard in it).
        if (s.overview and pressed and key == evdev.key_esc) return s.setOverview(false);
        const surf = s.keyboard_focus orelse return;
        const taken = if (s.input_method) |im| im.key(im.ctx, s, key, pressed) else false;
        const state: u32 = if (pressed) p.wl_keyboard.key_state.pressed else p.wl_keyboard.key_state.released;
        if (!taken) broadcast(surf.client, .keyboard, p.wl_keyboard.event.key, 1, .{ s.nextSerial(), time_ms, key, state });
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
            // In the overview, every window can be seen.
            const covered = !s.overview and s.isCovered(t, s.toplevels.items[i + 1 ..]);
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
            if (u.xdg.surface) |us| if (us.input_region != null) continue;
            // A rounded window does not hide what is behind its corners.
            const a = insetRect(s.visibleRect(u), @intCast(u.shownRadius()));
            if (a.x <= r.x and a.y <= r.y and
                a.x + @as(i32, @intCast(a.width)) >= r.x + @as(i32, @intCast(r.width)) and
                a.y + @as(i32, @intCast(a.height)) >= r.y + @as(i32, @intCast(r.height))) return true;
        }
        return false;
    }

    /// `r`, `by` smaller on each side.
    fn insetRect(r: Rect, by: u32) Rect {
        if (by == 0) return r;
        return .{ .x = r.x + @as(i32, @intCast(by)), .y = r.y + @as(i32, @intCast(by)), .width = r.width -| 2 * by, .height = r.height -| 2 * by };
    }

    /// Moves the focus after the windows change: the keyboard to the top
    /// window, and the pointer to the window under it. Windows are told
    /// whether they are covered (see `updateCovered`).
    pub fn updateFocus(s: *Server) void {
        s.updateCovered();
        if (s.drag) |d| _ = s.updateDragFocus(s.dragPos(d));
        if (s.updatePointerFocus()) s.pointerFrame();
        s.updateLock();
        // The top window has the keyboard, or its topmost grabbing popup
        // (a menu) has.
        var top: ?*Surface = if (s.overview) null else if (s.topWindow()) |t| t.xdg.surface else null;
        if (!s.overview) if (s.topWindow()) |t| for (s.popups.items) |pp| if (pp.grab) if (pp.xdg.surface) |ps| if (s.rootToplevel(ps) == t) {
            top = ps;
        };
        if (top == s.keyboard_focus) return;
        if (s.keyboard_focus) |old| {
            broadcast(old.client, .keyboard, p.wl_keyboard.event.leave, 1, .{ s.nextSerial(), old.id });
            var it = old.client.objects.valueIterator();
            while (it.next()) |o| switch (o.*) {
                .text_input => |ti| {
                    ti.enabled = false;
                    s.resetTextInputPending(ti);
                    sendTo(old.client, ti.id, p.zwp_text_input_v3.event.leave, .{old.id});
                },
                else => {},
            };
        }
        s.keyboard_focus = top;
        // What the clipboard holds comes just before the keyboard.
        s.sendSelection();
        if (top) |surf| {
            var it = surf.client.objects.iterator();
            while (it.next()) |e| switch (e.value_ptr.*) {
                .keyboard => s.sendKeyboardEnter(surf.client, e.key_ptr.*, surf),
                .text_input => |ti| sendTo(surf.client, ti.id, p.zwp_text_input_v3.event.enter, .{surf.id}),
                else => {},
            };
        }
    }

    /// Returns the active (enabled) `TextInput` of the client with keyboard
    /// focus, if any.
    pub fn activeTextInput(s: *const Server) ?*TextInput {
        const surf = s.keyboard_focus orelse return null;
        var it = surf.client.objects.valueIterator();
        while (it.next()) |o| switch (o.*) {
            .text_input => |ti| if (ti.enabled) return ti,
            else => {},
        };
        return null;
    }

    /// Sends `zwp_text_input_v3.preedit_string` to the active text input.
    pub fn textInputPreedit(s: *Server, text: ?[]const u8, cursor_begin: i32, cursor_end: i32) void {
        const ti = s.activeTextInput() orelse return;
        if (ti.client.send(ti.id, p.zwp_text_input_v3.event.preedit_string)) |m0| {
            var m = m0;
            m.string(text).int(cursor_begin).int(cursor_end).end();
        }
    }

    /// Sends `zwp_text_input_v3.commit_string` to the active text input.
    pub fn textInputCommitString(s: *Server, text: ?[]const u8) void {
        const ti = s.activeTextInput() orelse return;
        if (ti.client.send(ti.id, p.zwp_text_input_v3.event.commit_string)) |m0| {
            var m = m0;
            m.string(text).end();
        }
    }

    /// Sends `zwp_text_input_v3.delete_surrounding_text` to the active text input.
    pub fn textInputDeleteSurrounding(s: *Server, before_length: u32, after_length: u32) void {
        const ti = s.activeTextInput() orelse return;
        sendTo(ti.client, ti.id, p.zwp_text_input_v3.event.delete_surrounding_text, .{ before_length, after_length });
    }

    /// Sends `zwp_text_input_v3.done` with the last committed serial to the
    /// active text input.
    pub fn textInputDone(s: *Server) void {
        const ti = s.activeTextInput() orelse return;
        sendTo(ti.client, ti.id, p.zwp_text_input_v3.event.done, .{ti.serial});
    }

    /// The surface under the pointer, if any: the top window there.
    fn surfaceUnderPointer(s: *Server) ?*Surface {
        return s.surfaceAt(s.pointer_x, s.pointer_y);
    }

    /// The surface at (`x`, `y`) on the screen, if any: the top one there.
    fn rectHas(r: Rect, x: f64, y: f64) bool {
        return x >= @as(f64, @floatFromInt(r.x)) and y >= @as(f64, @floatFromInt(r.y)) and
            x < @as(f64, @floatFromInt(r.x + @as(i32, @intCast(r.width)))) and
            y < @as(f64, @floatFromInt(r.y + @as(i32, @intCast(r.height))));
    }

    /// The window whose resize border (`resize_handle`) is at (`x`, `y`),
    /// and its edges there, if a window's is, and nothing is above it
    /// there: a floating window with a shadow, that can be resized.
    pub fn edgeAt(s: *Server, x: f64, y: f64) ?EdgeHit {
        if (!rectHas(s.screen(), x, y)) return null;
        for (s.shell_areas) |area| if (area) |r| if (rectHas(r, x, y)) return null;
        var i = s.toplevels.items.len;
        while (i > 0) {
            i -= 1;
            const t = s.toplevels.items[i];
            if (!t.shown() or t.suspended) continue;
            var j = s.popups.items.len;
            while (j > 0) {
                j -= 1;
                const ps = s.popups.items[j].xdg.surface orelse continue;
                if (s.rootToplevel(ps) != t) continue;
                if (s.hitTree(ps, x, y) != null) return null;
            }
            const surf = t.xdg.surface orelse continue;
            const resizable = rounding(t) > 0 and (t.max_width == 0 or t.max_width != t.min_width or t.max_height == 0 or t.max_height != t.min_height);
            if (resizable) {
                const r = s.windowRect(t);
                if (edgesOf(r, x, y)) |edges| return if (edges == 0) null else .{ .t = t, .edges = edges };
            }
            if (s.hitTree(surf, x, y) != null) return null;
        }
        return null;
    }

    /// The edges of window `r` (`resize_handle` out from it, its outer
    /// pixel in) at (`x`, `y`): 0 within it, null outside it all.
    fn edgesOf(r: Rect, x: f64, y: f64) ?u32 {
        const h: f64 = resize_handle;
        const left: f64 = @floatFromInt(r.x);
        const top: f64 = @floatFromInt(r.y);
        const right = left + @as(f64, @floatFromInt(r.width));
        const bottom = top + @as(f64, @floatFromInt(r.height));
        if (x < left - h or x >= right + h or y < top - h or y >= bottom + h) return null;
        var edges: u32 = 0;
        if (x < left + 1) edges |= edge_left else if (x >= right - 1) edges |= edge_right;
        if (y < top + 1) edges |= edge_top else if (y >= bottom - 1) edges |= edge_bottom;
        // Near a corner: both edges at it.
        const c: f64 = resize_corner;
        if (edges & (edge_left | edge_right) != 0 and edges & (edge_top | edge_bottom) == 0) {
            if (y < top + c) edges |= edge_top else if (y >= bottom - c) edges |= edge_bottom;
        }
        if (edges & (edge_top | edge_bottom) != 0 and edges & (edge_left | edge_right) == 0) {
            if (x < left + c) edges |= edge_left else if (x >= right - c) edges |= edge_right;
        }
        return edges;
    }

    fn surfaceAt(s: *Server, x: f64, y: f64) ?*Surface {
        // Windows can be anywhere on the screen, but the shell's parts of
        // it are over them.
        if (!rectHas(s.screen(), x, y)) return null;
        for (s.shell_areas) |area| if (area) |r| if (rectHas(r, x, y)) return null;
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
    /// is over none; while a button is held down, the surface it was
    /// pressed on keeps the pointer until the button is released.
    fn updatePointerFocus(s: *Server) bool {
        // Over a window's resize border, no client has the pointer.
        if (s.grab == null and s.drag == null and !s.overview and s.buttons_down == 0) {
            const hit = s.edgeAt(s.pointer_x, s.pointer_y);
            const was = s.edge_hover;
            s.edge_hover = hit;
            if (!std.meta.eql(hit, was)) s.damaged = true;
        }
        const under = if (s.grab != null or s.drag != null or s.overview or s.edge_hover != null)
            null
        else if (s.buttons_down != 0)
            (if (s.pointer_focus) |surf| if (surf.texture() != null and s.surfaceOrigin(surf) != null) surf else null else null)
        else
            s.surfaceUnderPointer();
        if (under == s.pointer_focus) return false;
        if (s.pointer_focus) |old| {
            broadcast(old.client, .pointer, p.wl_pointer.event.leave, 1, .{ s.nextSerial(), old.id });
            broadcast(old.client, .pointer, p.wl_pointer.event.frame, 5, .{});
        }
        s.pointer_focus = under;
        // A window it enters chooses its picture again.
        if (s.cursor_surface != null) {
            s.cursor_surface = null;
            s.damaged = true;
        }
        s.client_cursor = .arrow;
        if (under) |surf| {
            const local = s.surfaceLocal();
            broadcast(surf.client, .pointer, p.wl_pointer.event.enter, 1, .{ s.nextSerial(), surf.id, local[0], local[1] });
        }
        s.updateLock();
        return true;
    }

    fn sendKeyboardEnter(s: *Server, c: *Client, id: u32, surf: *Surface) void {
        const no_keys: []const u8 = &.{};
        sendTo(c, id, p.wl_keyboard.event.enter, .{ s.nextSerial(), surf.id, no_keys });
        sendTo(c, id, p.wl_keyboard.event.modifiers, .{ s.serial, s.modifiers.depressed(), @as(u32, 0), s.modifiers.locked, @as(u32, 0) });
    }

    /// Sends a keyboard (`id`) the layout's keymap.
    fn sendKeymap(s: *Server, c: *Client, id: u32) void {
        const fd = keyboard.keymapFile(s.keyboard_layout) catch |err| return log.info("no keymap: {s}", .{@errorName(err)});
        var m = c.send(id, p.wl_keyboard.event.keymap) orelse {
            _ = linux.close(fd);
            return;
        };
        m.uint(p.wl_keyboard.keymap_format.xkb_v1).fd(fd).uint(@intCast(keyboard.keymap(s.keyboard_layout).len)).end();
    }

    /// Changes the keyboard's layout: every client's keyboards are sent its
    /// keymap.
    pub fn setKeyboard(s: *Server, layout: locale.Keyboard) void {
        if (layout == s.keyboard_layout) return;
        s.keyboard_layout = layout;
        s.modifiers.altgr = for (layout.keys()) |k| {
            if (k.altgr != null) break true;
        } else false;
        for (s.clients.items) |c| {
            var it = c.objects.iterator();
            while (it.next()) |e| switch (e.value_ptr.*) {
                .keyboard => s.sendKeymap(c, e.key_ptr.*),
                else => {},
            };
        }
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
            p.wl_surface.request.set_buffer_scale => {
                const sc = try r.int();
                if (sc <= 0) return c.postError(m.object, p.wl_surface.err.invalid_scale, "scale must be positive", .{});
                surf.pending_scale = @intCast(sc);
            },
            p.wl_surface.request.set_buffer_transform => {
                const tf = try r.int();
                if (tf < 0 or tf > 7) return c.postError(m.object, p.wl_surface.err.invalid_transform, "invalid transform {d}", .{tf});
                surf.pending_transform = @intCast(tf);
            },
            p.wl_surface.request.set_input_region => {
                const ops = try s.copyRegionArg(c, try r.uint());
                if (surf.pending_input_region) |old| s.gpa.free(old);
                surf.pending_input_region = ops;
                surf.pending_input_region_set = true;
            },
            p.wl_surface.request.set_opaque_region => {
                const ops = try s.copyRegionArg(c, try r.uint());
                if (surf.pending_opaque_region) |old| s.gpa.free(old);
                surf.pending_opaque_region = ops;
                surf.pending_opaque_region_set = true;
            },
            // Damage: the whole screen is redrawn anyway.
            p.wl_surface.request.damage, p.wl_surface.request.damage_buffer => {
                _ = try r.int();
                _ = try r.int();
                _ = try r.int();
                _ = try r.int();
            },
            else => return error.InvalidOpcode,
        }
    }

    fn commit(s: *Server, c: *Client, surf: *Surface) !void {
        if (surf.sub) |sub| if (s.isSubsurfaceSync(sub)) {
            return s.cacheSubsurfaceCommit(surf, sub);
        };
        try s.applySurfaceCommit(c, surf);
    }

    fn applySurfaceCommit(s: *Server, c: *Client, surf: *Surface) anyerror!void {
        // Where a window was, before this (perhaps a new size, for a new
        // state): the state's animation starts there.
        const before: ?Rect = if (surf.xdg) |x| if (x.toplevel) |t| (if (t.mapped and surf.texture() != null) s.windowRect(t) else null) else null else null;
        // What it shows now, if this may be the frame of its new state:
        // kept, to fade out (see `drewConfigure`).
        var old_frame: ?OldFrame = if (before) |r| s.keepOldFrame(surf, r) else null;
        defer if (old_frame) |o| s.releaseOldFrame(o);
        if (surf.pending_scale) |sc| {
            surf.scale = sc;
            surf.pending_scale = null;
        }
        if (surf.pending_transform) |tf| {
            surf.transform = tf;
            surf.pending_transform = null;
        }
        if (surf.pending_destination) |d| {
            surf.destination = switch (d) {
                .none => null,
                .size => |sz| sz,
            };
            surf.pending_destination = null;
        }
        if (surf.pending_input_region_set) {
            if (surf.input_region) |old| s.gpa.free(old);
            surf.input_region = surf.pending_input_region;
            surf.pending_input_region = null;
            surf.pending_input_region_set = false;
        }
        if (surf.pending_opaque_region_set) {
            if (surf.opaque_region) |old| s.gpa.free(old);
            surf.opaque_region = surf.pending_opaque_region;
            surf.pending_opaque_region = null;
            surf.pending_opaque_region_set = false;
        }
        for (s.locks.items) |lock| if (lock.surface == surf) {
            if (lock.pending_hint) |h| {
                lock.hint = h;
                lock.pending_hint = null;
            }
            if (lock.pending_region_set) {
                if (lock.region) |old| s.gpa.free(old);
                lock.region = lock.pending_region;
                lock.pending_region = null;
                lock.pending_region_set = false;
            }
        };
        if (surf.pending_attach) {
            surf.pending_attach = false;
            // A new buffer commit before the previous one was drawn supersedes
            // any presentation feedback queued for that previous commit.
            s.discardSurfaceFeedback(surf);
            const b = surf.pending_buffer;
            surf.pending_buffer = null;
            if (b) |nb| {
                if (nb.shm) |shm| {
                    // Copy the pixels now, so the buffer can be released.
                    const pixels = shm.pool.map[shm.offset..][0 .. shm.stride * nb.height];
                    const t = try s.backend.vtable.uploadPixels(s.backend.ptr, surf.copy, pixels, nb.width, nb.height, shm.stride, shm.format);
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
        if (surf.xdg) |x| if (x.pending_geometry) |g| {
            x.geometry = g;
            x.pending_geometry = null;
        };
        // A covered window's frame callbacks wait until it is uncovered:
        // its client need not draw what cannot be seen.
        const covered = if (s.rootToplevel(surf)) |t| t.mapped and t.suspended else false;
        // Subsurfaces take their new places and apply cached synchronized
        // commits with their parent.
        for (surf.subsurfaces.items) |sub| {
            if (sub.pending) |pos| {
                sub.x = pos[0];
                sub.y = pos[1];
                sub.pending = null;
            }
            if (sub.cached.has_state) try s.applySubsurfaceCached(sub);
        }
        // Shown for the first time: on the screen; unmapped: leaves it.
        if (!surf.entered and surf.texture() != null) {
            surf.entered = true;
            s.sendEnter(c, surf);
        } else if (surf.entered and surf.texture() == null) {
            surf.entered = false;
            s.sendLeave(c, surf);
        }
        if (covered) {
            try surf.held_callbacks.appendSlice(s.gpa, surf.pending_callbacks.items);
        } else {
            for (surf.pending_callbacks.items) |id| try s.frame_callbacks.append(s.gpa, .{ .client = c, .id = id });
        }
        surf.pending_callbacks.clearRetainingCapacity();
        if (covered or surf.texture() == null) {
            for (surf.pending_feedback.items) |id| sendFeedbackDiscarded(c, id);
        } else {
            for (surf.pending_feedback.items) |id| try s.frame_feedback.append(s.gpa, .{ .client = c, .id = id, .surface = surf });
        }
        surf.pending_feedback.clearRetainingCapacity();

        if (surf.xdg) |x| if (x.toplevel) |t| {
            if (!x.configured) {
                // The initial commit: tell the client its size.
                if (surf.texture() != null) return c.postError(x.id, p.xdg_surface.err.unconfigured_buffer, "buffer before the first configure", .{});
                s.configure(c, t);
                x.configured = true;
            } else if (surf.texture() != null and !t.mapped) {
                t.mapped = true;
                s.placeFirst(c, t);
                try s.toplevels.append(s.gpa, t);
            } else if (surf.texture() == null and t.mapped) {
                s.unmap(t);
            } else if (surf.texture() != null and !t.placed and !t.maximized and !t.fullscreen) {
                // Shown fullscreen first, and out of it now: placed as a
                // window's first buffer is.
                s.placeFirst(c, t);
            }
            // Drawn since acknowledging the last configure: the next size
            // can be sent.
            if (t.acked and !t.drawn) s.drewConfigure(c, t, before, &old_frame);
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
        if (surf.texture() == null) return;
        const sz = toplevelLogicalSize(t);
        const size = s.configuredSize(t);
        if (sz[0] == size[0] and sz[1] == size[1]) s.drewConfigure(surf.client, t, s.windowRect(t), null);
    }

    /// The frame `surf` shows, kept from being released or replaced, if
    /// it is a window's (at `at` on the screen) about to be shown in a new
    /// state: its next commit attaches a frame of it.
    fn keepOldFrame(s: *Server, surf: *Surface, at: Rect) ?OldFrame {
        const t = (surf.xdg orelse return null).toplevel orelse return null;
        if (!surf.pending_attach or surf.pending_buffer == null) return null;
        if (!t.acked or t.drawn or !t.stateChanging() or s.overviewShown()) return null;
        const tex = surf.texture() orelse return null;
        const o = s.surfaceOrigin(surf) orelse return null;
        const sz = surf.size() orelse return null;
        const frame: OldFrame = .{
            .texture = tex,
            .buffer = surf.buffer,
            .x = o[0] - at.x,
            .y = o[1] - at.y,
            .width = sz[0],
            .height = sz[1],
            .transform = surf.transform,
            .radius = rounding(t),
        };
        // The surface's copy is the shell's to keep; a new one is made
        // for the new frame.
        if (surf.buffer) |b| s.holdBuffer(b) else surf.copy = null;
        return frame;
    }

    /// `t` has drawn as it was last told (it was at `from` on the screen
    /// before, showing `old`, if kept): shown in its new state, on its way
    /// there from `from`, with `old` fading out (taken from `old`).
    fn drewConfigure(s: *Server, c: *Client, t: *Toplevel, from: ?Rect, old: ?*?OldFrame) void {
        t.drawn = true;
        if (t.stateChanging()) {
            t.shown_maximized = t.maximized;
            t.shown_fullscreen = t.fullscreen;
            t.shown_tiled = t.tiled;
            if (from) |r| if (!s.overviewShown() and !std.meta.eql(r, s.windowRect(t))) {
                s.endAnim(t);
                t.anim = .{ .from = r };
                if (old) |o| {
                    t.anim.?.old = o.*;
                    o.* = null;
                }
            };
            s.damaged = true;
            s.replacePopups(t);
        }
        if (t.resend) {
            t.resend = false;
            s.configure(c, t);
        } else s.settle(t, false);
    }

    fn configure(s: *Server, c: *Client, t: *Toplevel) void {
        if (t.xdg.version >= 5 and !t.capabilities_sent) {
            // Of the optional features, maximizing and fullscreen: no
            // menus or minimizing.
            if (c.send(t.id, p.xdg_toplevel.event.wm_capabilities)) |m0| {
                var e = m0;
                var caps: [8]u8 = undefined;
                std.mem.writeInt(u32, caps[0..4], p.xdg_toplevel.wm_capabilities.maximize, .little);
                std.mem.writeInt(u32, caps[4..8], p.xdg_toplevel.wm_capabilities.fullscreen, .little);
                e.array(&caps).end();
            }
            t.capabilities_sent = true;
        }
        // The biggest it can usefully be: the work area (or the screen).
        const bounds = s.toldAreaOf(t);
        if (t.xdg.version >= 4) sendTo(c, t.id, p.xdg_toplevel.event.configure_bounds, .{ @as(i32, @intCast(bounds.width)), @as(i32, @intCast(bounds.height)) });
        if (c.send(t.id, p.xdg_toplevel.event.configure)) |m0| {
            var e = m0;
            var states: [32]u8 = undefined;
            var n: usize = 0;
            const set = [_]struct { bool, u32 }{
                .{ t.maximized and !t.fullscreen, p.xdg_toplevel.state.maximized },
                .{ t.fullscreen, p.xdg_toplevel.state.fullscreen },
                .{ s.resizing(t), p.xdg_toplevel.state.resizing },
                .{ t.activated, p.xdg_toplevel.state.activated },
                .{ t.suspended and t.xdg.version >= 6, p.xdg_toplevel.state.suspended },
                // Tiled: against the work area's edges on three sides.
                .{ t.tiled == .left and !t.maximized and !t.fullscreen and t.xdg.version >= 2, p.xdg_toplevel.state.tiled_left },
                .{ t.tiled == .right and !t.maximized and !t.fullscreen and t.xdg.version >= 2, p.xdg_toplevel.state.tiled_right },
                .{ t.tiled != null and !t.maximized and !t.fullscreen and t.xdg.version >= 2, p.xdg_toplevel.state.tiled_top },
                .{ t.tiled != null and !t.maximized and !t.fullscreen and t.xdg.version >= 2, p.xdg_toplevel.state.tiled_bottom },
            };
            for (set) |st| if (st[0]) {
                std.mem.writeInt(u32, states[n..][0..4], st[1], .little);
                n += 4;
            };
            // A window not yet placed chooses its own size (0 by 0).
            const size: [2]u32 = if (!t.placed and !t.maximized and !t.fullscreen) .{ 0, 0 } else s.configuredSize(t);
            e.int(@intCast(size[0])).int(@intCast(size[1])).array(states[0..n]).end();
        }
        if (t.decoration) |d| sendTo(c, d.id, p.dazzle_decoration_v1.event.corner_radius, .{t.toldRadius()});
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
                const code = try r.uint();
                _ = try r.uint(); // flags
                if (pr.used) return c.postError(m.object, E.already_used, "params already used", .{});
                pr.used = true;
                const fd = pr.fd orelse return c.postError(m.object, E.incomplete, "no planes", .{});
                pr.fd = null;
                const format = for (buffer_formats) |f| {
                    if (f.fourcc() == code) break f;
                } else null;
                if (format == null or pr.modifier != p.modifier.broadcom_vc4_t_tiled) {
                    _ = linux.close(fd);
                    return c.postError(m.object, E.invalid_format, "only T-tiled XRGB8888, ARGB8888 and RGB565 are supported", .{});
                }
                if (width <= 0 or height <= 0 or width > 2048 or height > 2048) {
                    _ = linux.close(fd);
                    return c.postError(m.object, E.invalid_dimensions, "invalid size {d}x{d}", .{ width, height });
                }
                const t = s.backend.vtable.importDmabuf(s.backend.ptr, fd, @intCast(width), @intCast(height), format.?) catch |err| {
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
