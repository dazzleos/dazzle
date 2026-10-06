//! `Ui`: runs a widget tree. Each frame it builds the root widget (keeping
//! the nodes and state that still match), lays it out to the window's
//! size, and paints it; `render` then records it into a vc4 frame.
//! Pointer events go to the widgets under the pointer, and keys to the
//! widget with the keyboard (`focus`).
//!
//!     const ui = try Ui.create(gpa, &fira);
//!     try ui.attachGpu(dev);
//!     // Each frame:
//!     ui.frame(width, height, now_ns, MyApp{ .title = "Hello" });
//!     try ui.render(&frame, window.flusher());

const std = @import("std");
const gfx = @import("gfx");
const vc4 = @import("vc4");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const material = @import("material.zig");
const damage_mod = @import("damage.zig");
const keymap = @import("keymap.zig");

const Point = geometry.Point;
const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.Node;
const Context = widget.Context;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Segment = painter_mod.Segment;

pub const Ui = struct {
    gpa: std.mem.Allocator,
    /// Text is drawn in it; without one, text takes no space.
    font: ?*const font.Font,
    /// Icons are drawn with it (see `Icon`).
    icon_font: font.Font,
    theme: material.Theme = .dark,
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
    caps_lock: bool = false,
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

    pub fn create(gpa: std.mem.Allocator, f: ?*const font.Font) !*Ui {
        const ui = try gpa.create(Ui);
        errdefer gpa.destroy(ui);
        ui.* = .{ .gpa = gpa, .font = f, .icon_font = try font.Font.init(@import("icons").font_data), .atlas = try gfx.Atlas.init(gpa), .arenas = .{ .init(gpa), .init(gpa) } };
        return ui;
    }

    pub fn destroy(ui: *Ui) void {
        if (ui.root) |r| r.destroy();
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
        ui.gpa.destroy(ui);
    }

    /// Lets `render` draw with the GPU.
    pub fn attachGpu(ui: *Ui, dev: vc4.Device) !void {
        ui.renderer = try gfx.Renderer.init(ui.gpa, dev);
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
        _ = r.layout(.tight(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) }));
        r.offset = .{ 0, 0 };
        ui.paint(r, width, height);
        ui.damage.sweep(r);
        // The layout may have moved things under the pointer.
        if (ui.pointer) |p| ui.updateHover(p);
    }

    fn paint(ui: *Ui, r: *Node, width: u32, height: u32) void {
        ui.atlas.beginFrame();
        ui.canvases_used = 0;
        ui.segments.clearRetainingCapacity();
        ui.frame_size = .{ width, height };
        ui.paint_order = 0;
        var p: Painter = .{ .ui = ui, .node = r };
        p.paintNode(r);
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
            // Clicking elsewhere takes the keyboard away.
            if (ui.focused) |f| if (std.mem.indexOfScalar(*Node, ui.hovered.items, f) == null) ui.focus(null);
            for (ui.hovered.items) |n| if (send(n, .{ .press = .{ .pos = local(n, pos), .button = button } })) {
                ui.captured = n;
                return;
            };
        } else if (ui.captured) |n| {
            ui.captured = null;
            const inside = std.mem.indexOfScalar(*Node, ui.hovered.items, n) != null;
            _ = send(n, .{ .release = .{ .pos = local(n, pos), .button = button, .inside = inside } });
        }
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
    /// the keyboard.
    pub fn keyEvent(ui: *Ui, code: u32, pressed: bool) void {
        switch (code) {
            keymap.left_shift, keymap.right_shift => {
                ui.shift = if (pressed) ui.shift +| 1 else ui.shift -| 1;
                return;
            },
            keymap.caps_lock => if (pressed) {
                ui.caps_lock = !ui.caps_lock;
            },
            else => {},
        }
        const n = ui.focused orelse return;
        _ = send(n, .{ .key = .{ .code = code, .pressed = pressed, .char = if (pressed) keymap.char(code, ui.shift > 0, ui.caps_lock) else null } });
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
        if (ui.root) |r| _ = r.hitTest(pos, &path);
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

    /// Drops references to a node being freed.
    pub fn forget(ui: *Ui, n: *Node) void {
        if (ui.captured == n) ui.captured = null;
        if (ui.focused == n) ui.focused = null;
        if (std.mem.indexOfScalar(*Node, ui.hovered.items, n)) |i| _ = ui.hovered.orderedRemove(i);
    }
};
