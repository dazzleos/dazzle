//! `Ui`: runs a widget tree. Each frame it builds the root widget (keeping
//! the nodes and state that still match), lays it out to the window's
//! size, and paints it; `render` then records it into a vc4 frame.
//! Pointer events go to the widgets under the pointer, and keys to the
//! widget with the keyboard (`focus`). A menu (`openMenu`) is shown above
//! everything and gets the pointer first; the right button, or a touch held
//! without moving (`long_press_ns`), asks the widget under it for one
//! (`Event.context`).
//!
//! A touch (one at a time) acts as the left button: a tap clicks. One
//! that moves pans: whatever can scroll under it follows it, and nothing is
//! clicked; if nothing can, it drags as the pointer would.
//!
//! Text is copied and pasted through
//! `clipboard` (the system's, which the app gives), or within the app if
//! there is none.
//!
//!     const ui = try Ui.create(gpa, &fira);
//!     try ui.attachGpu(dev);
//!     // Each frame:
//!     ui.frame(width, height, now_ns, MyApp{ .title = "Hello" });
//!     try ui.render(&frame, window.flusher());

const std = @import("std");
const app = @import("app");
const sys = @import("sys");
const gfx = @import("gfx");
const vc4 = @import("vc4");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const Theme = @import("theme.zig").Theme;
const damage_mod = @import("damage.zig");
const keymap = @import("keymap.zig");
const menu_mod = @import("menu.zig");
const drag_mod = @import("drag.zig");
const locale = @import("locale");

const Point = geometry.Point;
const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.Node;
const Context = widget.Context;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Segment = painter_mod.Segment;

/// The system's clipboard, for text: `Clipboard.of(&app_clipboard)`, for
/// a type with `copy(self, text)` and `paste(self, sink)`. Pasting may take
/// a while (the text comes from another app): the text goes to the sink
/// when it has come, `sink.f(sink.ctx, text)` (null if there is none),
/// perhaps before `paste` returns.
pub const Clipboard = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Sink = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, text: ?[]const u8) void,
    };

    pub const VTable = struct {
        copy: *const fn (*anyopaque, []const u8) void,
        paste: *const fn (*anyopaque, Sink) void,
    };

    pub fn of(impl: anytype) Clipboard {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        return .{ .ptr = impl, .vtable = &struct {
            const vtable: VTable = .{ .copy = copy, .paste = paste };
            fn copy(ptr: *anyopaque, text: []const u8) void {
                T.copy(@ptrCast(@alignCast(ptr)), text);
            }
            fn paste(ptr: *anyopaque, sink: Sink) void {
                T.paste(@ptrCast(@alignCast(ptr)), .{ .ctx = sink.ctx, .f = sink.f });
            }
        }.vtable };
    }
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    /// Text is drawn in it; without one, text takes no space.
    font: ?*const font.Font,
    owned_font: ?font.Font = null,
    font_data: ?[]const u8 = null,
    /// Icons are drawn with it (see `Icon`).
    icon_font: font.Font,
    theme: Theme = .dark,
    atlas: gfx.Atlas,
    renderer: ?gfx.Renderer = null,
    root: ?*Node = null,
    /// Widgets are made in one while the other holds the last frame's
    /// (which events between frames still use).
    arenas: [2]std.heap.ArenaAllocator,
    frame_no: u64 = 0,
    now_ns: u64 = 0,
    /// Something changed (input, or a widget asked for another frame).
    needs_frame: bool = true,
    /// The frame's drawing: canvases (kept for reuse) and GPU draws.
    canvases: std.ArrayList(*gfx.Canvas) = .empty,
    canvases_used: usize = 0,
    segments: std.ArrayList(Segment) = .empty,
    pointer: ?Point = null,
    /// Event handlers under the pointer, deepest first.
    hovered: std.ArrayList(*Node) = .empty,
    hover_scratch: std.ArrayList(*Node) = .empty,
    /// The handler that took the pointer when a button went down.
    captured: ?*Node = null,
    /// The widget keys go to.
    focused: ?*Node = null,
    shift: u2 = 0,
    ctrl: u2 = 0,
    /// The right Alt, for a keyboard's third characters (the UK's €).
    altgr: u2 = 0,
    caps_lock: bool = false,
    /// The keyboard's layout: what character each key types.
    keyboard: locale.Keyboard = .us,
    /// The window fills the screen: title bars are not drawn (set from
    /// the app's window, as `keyboard` is).
    fullscreen: bool = false,
    /// Whether the window fills the work area (for `TitleBar`).
    maximized: bool = true,
    /// What the window's title bar buttons do (set by `attachWindow`).
    controls: ?*app.Controls = null,
    /// The system's clipboard (the app gives it); without one, text is
    /// copied within the app (`local_clipboard`).
    clipboard: ?Clipboard = null,
    local_clipboard: std.ArrayList(u8) = .empty,
    /// A paste under way: the widget that asked (whose going drops it),
    /// and where the text goes.
    paste: ?struct { owner: *Node, on_text: widget.ValueCallback([]const u8) } = null,
    /// The menu or popup shown, if any: its items (with their own copy) or
    /// builder, where it was asked for (in the window), and the widget that
    /// asked (which takes it away if it goes). Its nodes are made at the
    /// next frame.
    menu: ?struct {
        content: union(enum) {
            items: []menu_mod.Item,
            popup: PopupBuilder,
        },
        at: Point,
        owner: *Node,
    } = null,
    menu_root: ?*Node = null,
    /// What is being dragged, if anything (see drag.zig), and the chip
    /// that follows the pointer.
    drag: ?drag_mod.Drag = null,
    drag_root: ?*Node = null,
    drag_scratch: std.ArrayList(*Node) = .empty,
    /// A touch held down on a widget, which becomes a long press
    /// (`Event.context`) if it stays there: where it went down, and when
    /// the first frame after saw it.
    hold: ?struct { node: *Node, pos: Point, since: ?u64 = null } = null,
    /// The touch followed (others are ignored): its ID, where it went down
    /// and last was, whether it has moved, and whether it pans (scrolling
    /// what is under it) or drags (as the pointer would).
    touch: ?struct { id: i32, start: Point, last: Point, moved: bool = false, panning: bool = false } = null,
    /// The release of a press that became a long press is not sent.
    swallow_release: bool = false,
    /// The window's size at the last frame.
    frame_size: [2]u32 = .{ 1, 1 },
    /// What changed in the last frame (and the frames before).
    damage: damage_mod.Tracker = .{},
    /// Counts nodes as they are painted (their order is part of what they
    /// draw).
    paint_order: u64 = 0,
    /// How many scroll views are laying out their children: what in them
    /// shows is known only after (see `Node.realizeIn`).
    scrolling: u32 = 0,

    /// A builder that creates a popup widget each frame while open.
    pub const PopupBuilder = struct {
        ctx: *const anyopaque,
        f: *const fn (ctx: *const anyopaque, cx: *Context) Widget,

        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context) Widget) PopupBuilder {
            return .{ .ctx = ptr, .f = struct {
                fn call(raw: *const anyopaque, cx: *Context) Widget {
                    return f(@ptrCast(@alignCast(@constCast(raw))), cx);
                }
            }.call };
        }
    };

    pub fn create(gpa: std.mem.Allocator, f: ?*const font.Font) !*Ui {
        const ui = try gpa.create(Ui);
        errdefer gpa.destroy(ui);
        ui.* = .{ .gpa = gpa, .font = f, .icon_font = try font.Font.init(@import("icons").font_data), .atlas = try gfx.Atlas.init(gpa), .arenas = .{ .init(gpa), .init(gpa) } };
        return ui;
    }

    /// Creates a `Ui` with the font at `path` (or the system's default font
    /// when null), logging a warning if the font cannot be read.
    pub fn createWithFont(gpa: std.mem.Allocator, name: []const u8, path: ?[*:0]const u8) !*Ui {
        var font_buf: [512]u8 = undefined;
        const font_path: [:0]const u8 = if (path) |p| std.mem.span(p) else sys.fontFile(&font_buf, font.default_font_file);
        var font_data: ?[]const u8 = null;
        const owned_font: ?font.Font = blk: {
            const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
                sys.print(sys.log_warning ++ "{s}: cannot read the font {s} ({s}); no text\n", .{ name, font_path, @errorName(err) });
                break :blk null;
            };
            if (font.Font.init(data)) |f| {
                font_data = data;
                break :blk f;
            } else |_| {
                gpa.free(data);
                break :blk null;
            }
        };
        errdefer if (font_data) |d| gpa.free(d);
        const ui = try create(gpa, null);
        ui.font_data = font_data;
        ui.owned_font = owned_font;
        if (ui.owned_font) |*f| ui.font = f;
        return ui;
    }

    pub fn destroy(ui: *Ui) void {
        ui.closeMenu();
        ui.endDrag(false);
        if (ui.menu_root) |m| m.destroy();
        if (ui.drag_root) |d| d.destroy();
        ui.drag_scratch.deinit(ui.gpa);
        if (ui.root) |r| r.destroy();
        ui.local_clipboard.deinit(ui.gpa);
        ui.hovered.deinit(ui.gpa);
        ui.hover_scratch.deinit(ui.gpa);
        for (ui.canvases.items) |c| {
            c.deinit();
            ui.gpa.destroy(c);
        }
        ui.canvases.deinit(ui.gpa);
        ui.segments.deinit(ui.gpa);
        if (ui.renderer) |*r| r.deinit();
        ui.atlas.deinit();
        for (&ui.arenas) |*a| a.deinit();
        if (ui.font_data) |d| ui.gpa.free(d);
        ui.gpa.destroy(ui);
    }

    /// Connects the UI's clipboard, keyboard layout, and window state to
    /// `win` (and its title bar's buttons to `controls`, if given).
    pub fn attachWindow(ui: *Ui, win: *app.Window, controls: ?*app.Controls) void {
        ui.clipboard = .of(&win.clipboard);
        ui.controls = controls;
        ui.syncWindow(win);
    }

    /// Updates the UI's keyboard layout and window state from `win`.
    pub fn syncWindow(ui: *Ui, win: *const app.Window) void {
        ui.keyboard = win.layout;
        ui.fullscreen = win.fullscreen;
        ui.maximized = win.maximized;
    }

    /// Lets `render` draw with the GPU.
    pub fn attachGpu(ui: *Ui, dev: vc4.Device) !void {
        ui.renderer = try gfx.Renderer.init(ui.gpa, dev);
    }

    /// Lets a frame be recorded while the one before still renders (see
    /// app.Window.setPipelined): the UI's GPU buffers take turns.
    pub fn setPipelined(ui: *Ui, on: bool) void {
        if (ui.renderer) |*r| r.pipelined = on;
    }

    /// The arena this frame's widgets are made in.
    pub fn arena(ui: *Ui) std.mem.Allocator {
        return ui.arenas[@intCast(ui.frame_no % 2)].allocator();
    }

    /// Builds, lays out and paints a frame with `root` (a widget's value)
    /// filling a `width` by `height` window.
    pub fn frame(ui: *Ui, width: u32, height: u32, now_ns: u64, root: anytype) void {
        ui.frame_no += 1;
        _ = ui.arenas[@intCast(ui.frame_no % 2)].reset(.retain_capacity);
        ui.now_ns = now_ns;
        ui.needs_frame = false;
        ui.checkHold();
        ui.damage.begin(ui.frame_no, width, height);
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
        const w = cx.make(root);
        if (ui.root) |r| if (r.widget.vtable != w.vtable) {
            r.destroy();
            ui.root = null;
        };
        if (ui.root == null) ui.root = Node.create(ui, w);
        const r = ui.root orelse return;
        r.build(w);
        const window: Size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) };
        _ = r.layout(.tight(window));
        r.offset = .{ 0, 0 };
        const m = ui.buildMenu(window);
        const d = ui.buildDrag(window);
        ui.paint(r, d, m, width, height);
        ui.damage.sweep(r);
        if (d) |n| ui.damage.sweep(n);
        if (m) |n| ui.damage.sweep(n);
        // The layout may have moved things under the pointer.
        if (ui.pointer) |p| ui.updateHover(p);
        // A long press is waited for frame by frame.
        if (ui.hold != null) ui.needs_frame = true;
    }

    /// The menu's nodes, laid out where it goes; none if no menu is shown
    /// (one closed since the last frame goes now).
    fn buildMenu(ui: *Ui, window: Size) ?*Node {
        const menu = ui.menu orelse {
            if (ui.menu_root) |n| n.destroy();
            ui.menu_root = null;
            return null;
        };
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
        const w = switch (menu.content) {
            .items => |items| cx.make(menu_mod.Menu{ .items = items }),
            .popup => |popup| popup.f(popup.ctx, &cx),
        };
        if (ui.menu_root) |m| if (m.widget.vtable != w.vtable) {
            m.destroy();
            ui.menu_root = null;
        };
        if (ui.menu_root == null) ui.menu_root = Node.create(ui, w);
        const n = ui.menu_root orelse return null;
        n.build(w);
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        n.offset = menu_mod.place(window, menu.at, size);
        return n;
    }

    /// The chip following the pointer while something is dragged, laid
    /// out beside the pointer (in the window); none if nothing is.
    fn buildDrag(ui: *Ui, window: Size) ?*Node {
        const d = ui.drag orelse {
            if (ui.drag_root) |n| n.destroy();
            ui.drag_root = null;
            return null;
        };
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
        const w = cx.make(drag_mod.Chip{ .label = d.label, .icon = d.icon });
        if (ui.drag_root == null) ui.drag_root = Node.create(ui, w);
        const n = ui.drag_root orelse return null;
        n.build(w);
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        n.offset = .{
            std.math.clamp(d.pos[0] + 12, 0, @max(0, window.w - size.w)),
            std.math.clamp(d.pos[1] + 16, 0, @max(0, window.h - size.h)),
        };
        return n;
    }

    fn paint(ui: *Ui, r: *Node, drag: ?*Node, menu: ?*Node, width: u32, height: u32) void {
        ui.atlas.beginFrame();
        ui.canvases_used = 0;
        ui.segments.clearRetainingCapacity();
        ui.frame_size = .{ width, height };
        ui.paint_order = 0;
        var p: Painter = .{ .ui = ui, .node = r };
        p.paintNode(r);
        if (drag) |d| p.paintNode(d);
        // The menu above everything.
        if (menu) |m| p.paintNode(m);
    }

    // --- Menus ------------------------------------------------------------------

    /// Shows a menu of `items` at `at` (in the window), for `owner` (the
    /// widget asking, whose going closes it). It replaces any other.
    pub fn openMenu(ui: *Ui, owner: *Node, at: Point, items: []const menu_mod.Item) void {
        ui.closeMenu();
        const copy = ui.gpa.dupe(menu_mod.Item, items) catch return;
        ui.menu = .{ .content = .{ .items = copy }, .at = at, .owner = owner };
        ui.needs_frame = true;
    }

    /// Shows a custom popup built by `popup` at `at` (in the window), for
    /// `owner` (whose going closes it). Clicking outside or pressing Escape
    /// closes it.
    pub fn openPopup(ui: *Ui, owner: *Node, at: Point, popup: PopupBuilder) void {
        ui.closeMenu();
        ui.menu = .{ .content = .{ .popup = popup }, .at = at, .owner = owner };
        ui.needs_frame = true;
    }

    /// Closes the menu or popup, if one is shown.
    pub fn closeMenu(ui: *Ui) void {
        const menu = ui.menu orelse return;
        switch (menu.content) {
            .items => |items| ui.gpa.free(items),
            .popup => {},
        }
        ui.menu = null;
        ui.needs_frame = true;
    }

    // --- Dragging -----------------------------------------------------------------

    /// Starts dragging (from a `Draggable`); the label is copied.
    pub fn startDrag(ui: *Ui, d: drag_mod.Drag) void {
        ui.endDrag(false);
        var drag = d;
        drag.label = ui.gpa.dupe(u8, d.label) catch return;
        drag.target = null;
        ui.drag = drag;
        ui.moveDrag(d.pos);
    }

    /// What is dragged is at `pos` (in the window) now.
    pub fn moveDrag(ui: *Ui, pos: Point) void {
        const d = &(ui.drag orelse return);
        d.pos = pos;
        ui.drag_scratch.clearRetainingCapacity();
        if (ui.root) |r| _ = r.hitTest(pos, &ui.drag_scratch);
        d.target = drag_mod.targetIn(ui.drag_scratch.items, d.data);
        ui.needs_frame = true;
    }

    /// Stops dragging: dropped on the target under the pointer (if
    /// `drop`, and there is one), or not.
    pub fn endDrag(ui: *Ui, drop: bool) void {
        const d = ui.drag orelse return;
        ui.drag = null;
        ui.gpa.free(d.label);
        ui.needs_frame = true;
        if (!drop) return;
        const target = d.target orelse return;
        const t = target.widget.as(drag_mod.DropTarget) orelse return;
        if (t.on_drop) |f| f.call(d.data);
    }

    // --- Copy and paste -----------------------------------------------------------

    /// Puts text on the clipboard.
    pub fn copyText(ui: *Ui, text: []const u8) void {
        if (ui.clipboard) |c| return c.vtable.copy(c.ptr, text);
        ui.local_clipboard.clearRetainingCapacity();
        ui.local_clipboard.appendSlice(ui.gpa, text) catch {};
    }

    /// Asks for the text on the clipboard, for `owner`: it goes to
    /// `on_text` when it comes (which may be later: another app gives it),
    /// unless `owner` has gone, another paste has been asked for, or there
    /// is none. A frame is asked for then.
    pub fn pasteText(ui: *Ui, owner: *Node, on_text: widget.ValueCallback([]const u8)) void {
        ui.paste = .{ .owner = owner, .on_text = on_text };
        if (ui.clipboard) |c| return c.vtable.paste(c.ptr, .{ .ctx = ui, .f = pasted });
        pasted(ui, if (ui.local_clipboard.items.len > 0) ui.local_clipboard.items else null);
    }

    fn pasted(ctx: *anyopaque, text: ?[]const u8) void {
        const ui: *Ui = @ptrCast(@alignCast(ctx));
        const p = ui.paste orelse return;
        ui.paste = null;
        if (text) |t| p.on_text.call(t);
        ui.needs_frame = true;
    }

    // --- Long presses ---------------------------------------------------------------

    /// How long a touch is held down without moving for a menu.
    pub const long_press_ns = 500 * std.time.ns_per_ms;
    /// How far a touch may move and still be a tap (or a long press).
    pub const touch_slop = 8;

    /// A hold that has lasted becomes a long press: the widget is asked for
    /// a menu, and if it shows one, the press is its (the release is not
    /// sent).
    fn checkHold(ui: *Ui) void {
        const h = &(ui.hold orelse return);
        const since = h.since orelse {
            h.since = ui.now_ns;
            return;
        };
        if (ui.now_ns -| since < long_press_ns) return;
        const n = h.node;
        const pos = h.pos;
        ui.hold = null;
        if (send(n, .{ .context = local(n, pos) })) {
            ui.captured = null;
            ui.swallow_release = true;
        }
    }

    /// The canvas painting goes on: the last segment's, or a new one after
    /// a GPU draw.
    pub fn currentCanvas(ui: *Ui) *gfx.Canvas {
        if (ui.segments.items.len > 0) switch (ui.segments.items[ui.segments.items.len - 1]) {
            .canvas => |c| return c,
            .gpu => {},
        };
        return ui.newCanvas() orelse {
            // Out of memory: draw into the last canvas there is (out of
            // order), or a scratch one that is never shown.
            if (ui.canvases.items.len > 0) return ui.canvases.items[0];
            return &scratch_canvas;
        };
    }

    var scratch_canvas: gfx.Canvas = .init(std.heap.page_allocator);

    fn newCanvas(ui: *Ui) ?*gfx.Canvas {
        if (ui.canvases_used == ui.canvases.items.len) {
            const c = ui.gpa.create(gfx.Canvas) catch return null;
            c.* = .init(ui.gpa);
            ui.canvases.append(ui.gpa, c) catch {
                ui.gpa.destroy(c);
                return null;
            };
        }
        const c = ui.canvases.items[ui.canvases_used];
        c.begin(ui.frame_size[0], ui.frame_size[1]);
        ui.segments.append(ui.gpa, .{ .canvas = c }) catch return null;
        ui.canvases_used += 1;
        return c;
    }

    pub fn addGpu(ui: *Ui, d: painter_mod.GpuDraw) void {
        ui.segments.append(ui.gpa, .{ .gpu = d }) catch {};
    }

    /// Whether the last frame looks any different from the one before (if
    /// not, there is nothing to draw or show).
    pub fn changed(ui: *const Ui) bool {
        return !ui.damage.frame.isEmpty();
    }

    /// What changed in the last frame, in window pixels (for the
    /// compositor).
    pub fn damaged(ui: *const Ui) []const geometry.Rect {
        return ui.damage.frame.slice();
    }

    /// What changed in the last frame, as `vc4.render.Viewport` rectangles
    /// for `app.Window.showDamaged` or `app.Window.submit`.
    pub fn damagedViewports(ui: *const Ui, out: *[damage_mod.Region.max_rects]vc4.render.Viewport) []const vc4.render.Viewport {
        const rects = ui.damaged();
        for (rects, out[0..rects.len]) |r, *v| v.* = .{
            .x = @intFromFloat(r.x),
            .y = @intFromFloat(r.y),
            .width = @intFromFloat(r.w),
            .height = @intFromFloat(r.h),
        };
        return out[0..rects.len];
    }

    /// What must be drawn into a buffer last drawn `age` frames ago (1 for
    /// the frame before; 0 if never, or unknown) to show the last frame.
    pub fn repaint(ui: *const Ui, age: u32) damage_mod.Region {
        return ui.damage.repaint(age);
    }

    /// Limits `frame` (begun) to drawing `region`: the rest of its target
    /// keeps what it holds.
    pub fn limit(frame_: *vc4.render.Frame, region: *const damage_mod.Region) void {
        var vps: [damage_mod.Region.max_rects]vc4.render.Viewport = undefined;
        for (region.slice(), vps[0..region.len]) |r, *v| v.* = .{
            .x = @intFromFloat(r.x),
            .y = @intFromFloat(r.y),
            .width = @intFromFloat(r.w),
            .height = @intFromFloat(r.h),
        };
        frame_.limitTo(vps[0..region.len]);
    }

    /// Records the last frame painted into `frame` (whose previous use of
    /// the UI's buffers has finished rendering).
    pub fn render(ui: *Ui, frame_: *vc4.render.Frame, flush: ?vc4.render.Flush) !void {
        const r = if (ui.renderer) |*r| r else return error.NoGpu;
        try r.prepare(ui.canvases.items[0..ui.canvases_used]);
        for (ui.segments.items) |s| switch (s) {
            .canvas => |c| try r.record(c, frame_, flush),
            .gpu => |g| if (frame_.covers(g.area.scissor orelse g.area.viewport)) try g.f(g.ctx, frame_, g.area),
        };
    }

    /// If the last `frame` changed anything, renders only the damaged parts
    /// into `win` and submits it.
    pub fn present(ui: *Ui, win: *app.Window, frame_: *vc4.render.Frame, clear: u32) !bool {
        if (!ui.changed()) return false;
        const target = try win.beginFrame();
        const repaint_region = ui.repaint(win.bufferAge());
        frame_.begin(target, .{ .clear = clear });
        limit(frame_, &repaint_region);
        try ui.render(frame_, win.flusher());
        var damage: [damage_mod.Region.max_rects]vc4.render.Viewport = undefined;
        try win.submit(frame_, ui.damagedViewports(&damage));
        return true;
    }

    /// Draws the last frame painted into `img` on the CPU, with the real
    /// shaders in the QPU simulator; GPU draws are left out.
    pub fn preview(ui: *Ui, img: gfx.preview.Image) !void {
        const programs = gfx.preview.Programs.load();
        for (ui.segments.items) |s| switch (s) {
            .canvas => |c| try gfx.preview.render(c, &programs, img),
            .gpu => {},
        };
    }

    // --- Input ------------------------------------------------------------------

    /// Sends a window input event to the widget tree.
    pub fn handleInput(ui: *Ui, e: app.InputEvent) void {
        switch (e) {
            .motion => |pos| ui.pointerMotion(pos),
            .button => |b| ui.pointerButton(b.pos, b.code, b.pressed),
            .scroll => |s| ui.pointerScroll(s.pos, s.dx, s.dy),
            .key => |k| ui.keyEvent(k.code, k.pressed),
            .leave => ui.pointerLeave(),
            .touch_down => |t| ui.touchDown(t.id, t.pos),
            .touch_motion => |t| ui.touchMotion(t.id, t.pos),
            .touch_up => |id| ui.touchUp(id),
            .touch_cancel => ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
        }
    }

    /// Sends all pending input events from `win` to the widget tree.
    pub fn takeInput(ui: *Ui, win: *app.Window) void {
        ui.syncWindow(win);
        for (win.takeInput()) |e| ui.handleInput(e);
    }

    pub fn pointerMotion(ui: *Ui, pos: Point) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        for (ui.hovered.items) |n| _ = send(n, .{ .motion = local(n, pos) });
        if (ui.captured) |n| if (std.mem.indexOfScalar(*Node, ui.hovered.items, n) == null) {
            _ = send(n, .{ .motion = local(n, pos) });
        };
    }

    /// A button (a Linux key code: BTN_LEFT is 0x110) went down or up.
    pub fn pointerButton(ui: *Ui, pos: Point, button: u32, pressed: bool) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        ui.needs_frame = true;
        if (pressed) {
            if (ui.captured != null) return;
            // With a menu shown, a press outside it closes it (and does
            // nothing else).
            if (ui.menu != null and !ui.overMenu()) {
                ui.closeMenu();
                return;
            }
            // Clicking elsewhere takes the keyboard away.
            if (ui.focused) |f| if (std.mem.indexOfScalar(*Node, ui.hovered.items, f) == null) ui.focus(null);
            // The right button asks for a menu, if a widget has one.
            if (button == widget.btn_right) for (ui.hovered.items) |n| if (send(n, .{ .context = local(n, pos) })) return;
            for (ui.hovered.items) |n| if (send(n, .{ .press = .{ .pos = local(n, pos), .button = button } })) {
                ui.captured = n;
                return;
            };
        } else if (ui.swallow_release) {
            ui.swallow_release = false;
            ui.hold = null;
        } else if (ui.captured) |n| {
            ui.hold = null;
            ui.captured = null;
            const inside = std.mem.indexOfScalar(*Node, ui.hovered.items, n) != null;
            _ = send(n, .{ .release = .{ .pos = local(n, pos), .button = button, .inside = inside } });
        }
    }

    // --- Touch ----------------------------------------------------------------------

    /// A touch went down at `pos`: it presses there, as the left button
    /// does (and, held there, becomes a long press). Only one touch is
    /// followed at a time.
    pub fn touchDown(ui: *Ui, id: i32, pos: Point) void {
        if (ui.touch != null) return;
        ui.touch = .{ .id = id, .start = pos, .last = pos };
        ui.pointerButton(pos, widget.btn_left, true);
        if (ui.captured) |n| ui.hold = .{ .node = n, .pos = pos };
    }

    /// The touch moved to `pos`. Once it has gone further than
    /// `touch_slop`, it pans what can scroll under where it went down, if
    /// anything can (the press is then cancelled: nothing is clicked), or
    /// else drags.
    pub fn touchMotion(ui: *Ui, id: i32, pos: Point) void {
        const t = &(ui.touch orelse return);
        if (t.id != id) return;
        // A long press showed a menu: the touch is done with.
        if (ui.swallow_release) return;
        if (!t.moved and @abs(pos[0] - t.start[0]) <= touch_slop and @abs(pos[1] - t.start[1]) <= touch_slop) return;
        const first = !t.moved;
        t.moved = true;
        ui.hold = null;
        const dx = t.last[0] - pos[0];
        const dy = t.last[1] - pos[1];
        t.last = pos;
        if (t.panning) {
            _ = ui.pan(t.start, dx, dy);
            return;
        }
        if (first and ui.pan(t.start, dx, dy)) {
            t.panning = true;
            ui.cancelPress();
            return;
        }
        ui.pointerMotion(pos);
    }

    /// The touch came up: a tap (or the end of a drag) releases where it
    /// last was, as the left button does.
    pub fn touchUp(ui: *Ui, id: i32) void {
        const t = ui.touch orelse return;
        if (t.id != id) return;
        if (!t.panning) ui.pointerButton(t.last, widget.btn_left, false);
        ui.touch = null;
        ui.hold = null;
        ui.swallow_release = false;
        // A touch hovers over nothing once it is up.
        ui.pointerLeave();
    }

    /// The touches are not the window's any more (the shell moves it,
    /// say): what they pressed is let go without a click.
    pub fn touchCancel(ui: *Ui) void {
        ui.cancelPress();
        ui.touch = null;
        ui.hold = null;
        ui.swallow_release = false;
        ui.pointerLeave();
    }

    /// Scrolls what can scroll under `at` by (`dx`, `dy`). Returns whether
    /// anything did.
    fn pan(ui: *Ui, at: Point, dx: f32, dy: f32) bool {
        ui.updateHover(at);
        for (ui.hovered.items) |n| if (send(n, .{ .scroll = .{ .pos = local(n, at), .dx = dx, .dy = dy, .touch = true } })) {
            ui.needs_frame = true;
            return true;
        };
        return false;
    }

    /// Lets go of what was pressed, without a click.
    fn cancelPress(ui: *Ui) void {
        const n = ui.captured orelse return;
        ui.captured = null;
        _ = send(n, .{ .release = .{ .pos = .{ -1, -1 }, .button = widget.btn_left, .inside = false } });
        ui.needs_frame = true;
    }

    /// The wheel turned (`dy` pixels down, `dx` right): the deepest widget
    /// under the pointer that can scroll does.
    pub fn pointerScroll(ui: *Ui, pos: Point, dx: f32, dy: f32) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        for (ui.hovered.items) |n| if (send(n, .{ .scroll = .{ .pos = local(n, pos), .dx = dx, .dy = dy } })) {
            ui.needs_frame = true;
            return;
        };
    }

    /// Gives the keyboard to a widget (null: to none).
    pub fn focus(ui: *Ui, n: ?*Node) void {
        if (ui.focused == n) return;
        if (ui.focused) |old| _ = send(old, .blur);
        ui.focused = n;
        if (n) |new| _ = send(new, .focus);
        ui.needs_frame = true;
    }

    /// A key (a Linux key code) went down or up; it goes to the widget with
    /// the keyboard. Escape closes a menu.
    pub fn keyEvent(ui: *Ui, code: u32, pressed: bool) void {
        switch (code) {
            keymap.left_shift, keymap.right_shift => {
                ui.shift = if (pressed) ui.shift +| 1 else ui.shift -| 1;
                return;
            },
            keymap.left_ctrl, keymap.right_ctrl => {
                ui.ctrl = if (pressed) ui.ctrl +| 1 else ui.ctrl -| 1;
                return;
            },
            keymap.right_alt => {
                ui.altgr = if (pressed) ui.altgr +| 1 else ui.altgr -| 1;
                return;
            },
            keymap.caps_lock => if (pressed) {
                ui.caps_lock = !ui.caps_lock;
            },
            keymap.escape => if (pressed and ui.menu != null) {
                ui.closeMenu();
                return;
            },
            else => {},
        }
        const n = ui.focused orelse return;
        const ctrl = ui.ctrl > 0;
        const shift = ui.shift > 0;
        _ = send(n, .{ .key = .{
            .code = code,
            .pressed = pressed,
            .char = if (pressed and !ctrl) ui.keyboard.char(code, shift, ui.caps_lock, ui.altgr > 0) else null,
            .ctrl = ctrl,
            .shift = shift,
        } });
        ui.needs_frame = true;
    }

    /// The pointer left the window.
    pub fn pointerLeave(ui: *Ui) void {
        ui.pointer = null;
        for (ui.hovered.items) |n| _ = send(n, .leave);
        ui.hovered.clearRetainingCapacity();
        ui.needs_frame = true;
    }

    fn updateHover(ui: *Ui, pos: Point) void {
        // The last path's list is reused for the new one.
        var path = ui.hover_scratch;
        path.clearRetainingCapacity();
        // With a menu shown, only it is under the pointer.
        if (ui.menu != null) {
            if (ui.menu_root) |m| _ = m.hitTest(.{ pos[0] - m.offset[0], pos[1] - m.offset[1] }, &path);
        } else if (ui.root) |r| _ = r.hitTest(pos, &path);
        for (ui.hovered.items) |n| if (std.mem.indexOfScalar(*Node, path.items, n) == null) {
            _ = send(n, .leave);
            ui.needs_frame = true;
        };
        for (path.items) |n| if (std.mem.indexOfScalar(*Node, ui.hovered.items, n) == null) {
            _ = send(n, .enter);
            ui.needs_frame = true;
        };
        ui.hover_scratch = ui.hovered;
        ui.hovered = path;
    }

    fn send(n: *Node, e: Event) bool {
        const f = n.widget.vtable.event orelse return false;
        return f(n.widget.ptr, n, e);
    }

    fn local(n: *const Node, pos: Point) Point {
        const at = n.position();
        return .{ pos[0] - at[0], pos[1] - at[1] };
    }

    /// Whether the pointer is over the menu shown (as last laid out).
    fn overMenu(ui: *const Ui) bool {
        const m = ui.menu_root orelse return false;
        const pos = ui.pointer orelse return false;
        const x = pos[0] - m.offset[0];
        const y = pos[1] - m.offset[1];
        return x >= 0 and y >= 0 and x < m.size.w and y < m.size.h;
    }

    /// Drops references to a node being freed.
    pub fn forget(ui: *Ui, n: *Node) void {
        if (ui.menu) |m| if (m.owner == n) ui.closeMenu();
        if (ui.drag) |*d| {
            if (d.source == n) ui.endDrag(false) else if (d.target == n) d.target = null;
        }
        if (ui.paste) |p| if (p.owner == n) {
            ui.paste = null;
        };
        if (ui.hold) |h| if (h.node == n) {
            ui.hold = null;
        };
        if (ui.focused == n) ui.focused = null;
        if (std.mem.indexOfScalar(*Node, ui.hovered.items, n)) |i| _ = ui.hovered.orderedRemove(i);
    }
};

/// A native toolkit app: owns the GPU device, the Wayland `app.Window`,
/// `app.Controls`, `Ui`, and the `vc4.render.Frame` used to draw it.
pub const App = struct {
    gpa: std.mem.Allocator,
    name: []const u8,
    dev: vc4.Device,
    win: *app.Window,
    controls: app.Controls,
    ui: *Ui,
    frame: vc4.render.Frame = undefined,
    clear_color: u32 = 0xff141218,
    width: u32,
    height: u32,
    dirty: bool = true,
    idle: bool = false,
    suspended: bool = false,
    sync_keyboard: bool = true,
    /// Set by `step` when the window's size changed in the last configure.
    resized: bool = false,
    /// Set by `step` when `suspended` changed in the last configure.
    suspended_changed: bool = false,

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 1280, 720 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
        font_path: ?[*:0]const u8 = null,
        pipelined: bool = false,
        clear_color: u32 = 0xff141218,
    };

    /// Opens the GPU, connects to the compositor in `environ`, opens the
    /// window, loads the font, and attaches the toolkit to the window.
    pub fn open(gpa: std.mem.Allocator, environ: std.process.Environ, options: Options) !*App {
        const name = options.app_id orelse options.title;
        const a = try gpa.create(App);
        errdefer gpa.destroy(a);
        a.gpa = gpa;
        a.name = name;
        a.dev = vc4.device.openRender() catch |err| {
            sys.print(sys.log_error ++ "{s}: no GPU ({s})\n", .{ name, @errorName(err) });
            return err;
        };
        errdefer a.dev.close();
        a.win = try app.Window.open(gpa, .device(&a.dev), environ, .{
            .title = options.title,
            .app_id = options.app_id,
            .size = options.size,
            .min_size = options.min_size,
            .maximized = options.maximized,
        });
        errdefer a.win.close();
        a.controls = .{ .win = a.win };
        a.ui = try Ui.createWithFont(gpa, name, options.font_path);
        errdefer a.ui.destroy();
        a.ui.attachWindow(a.win, &a.controls);
        try a.ui.attachGpu(a.dev);
        if (options.pipelined) {
            try a.win.setPipelined(true);
            a.ui.setPipelined(a.win.pipelined);
        }
        a.clear_color = options.clear_color;
        a.width = a.win.width;
        a.height = a.win.height;
        a.dirty = true;
        a.idle = false;
        a.suspended = false;
        a.sync_keyboard = true;
        a.resized = false;
        a.suspended_changed = false;
        return a;
    }

    pub fn close(a: *App) void {
        a.ui.destroy();
        a.win.close();
        a.dev.close();
        a.gpa.destroy(a);
    }

    /// Waits (when `idle`) or polls for window events, applies any pending
    /// configure, and updates `suspended`. Returns `false` when the window
    /// has been closed.
    pub fn step(a: *App, idle_timeout_ns: u64) !bool {
        const waited = if (a.idle) blk: {
            try a.win.finishInFlight();
            const timeout: u64 = if (a.ui.needs_frame and !a.suspended) 16 * std.time.ns_per_ms else idle_timeout_ns;
            break :blk a.win.wait(timeout);
        } else a.win.poll();
        waited catch |err| {
            if (err == error.ServerError) sys.print(sys.log_error ++ "{s}: compositor error: {s}\n", .{ a.name, a.win.conn.errorMessage() });
            return err;
        };
        if (a.win.closed or a.controls.quit) return false;
        a.resized = false;
        if (try a.win.applyConfigure()) |size| {
            a.width = size[0];
            a.height = size[1];
            a.dirty = true;
            a.resized = true;
        }
        a.suspended_changed = a.win.suspended != a.suspended;
        if (a.suspended_changed) {
            a.suspended = a.win.suspended;
            if (a.suspended) {
                try a.win.finishInFlight();
                a.win.releaseSpareBuffers();
            } else {
                a.dirty = true;
            }
        }
        if (a.sync_keyboard) a.ui.keyboard = a.win.layout;
        a.ui.fullscreen = a.win.fullscreen;
        a.ui.maximized = a.win.maximized;
        return true;
    }

    /// Forwards all pending input events from `win` to `ui`.
    pub fn takeInput(a: *App) void {
        if (a.sync_keyboard) a.ui.keyboard = a.win.layout;
        a.ui.fullscreen = a.win.fullscreen;
        a.ui.maximized = a.win.maximized;
        for (a.win.takeInput()) |e| a.ui.handleInput(e);
    }

    /// If the window is not suspended and the UI needs a frame (`dirty` or
    /// `ui.needs_frame`), builds `root` and presents any changed regions;
    /// `idle` is cleared when a frame is shown, and set otherwise.
    pub fn draw(a: *App, now_ns: u64, root: anytype) !void {
        a.idle = true;
        if (!a.suspended and (a.dirty or a.ui.needs_frame)) {
            a.dirty = false;
            a.ui.frame(a.width, a.height, now_ns, root);
            if (try a.ui.present(a.win, &a.frame, a.clear_color)) a.idle = false;
        }
    }
};
