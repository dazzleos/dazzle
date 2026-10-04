//! Painting the laid-out tree: each widget draws on a 2D canvas, with its
//! top left as the origin, or adds a draw of its own straight to the GPU
//! frame (a 3D view, say). Those split the 2D drawing into layers below
//! and above them, so everything keeps the tree's order.
//!
//! Widgets whose children (or content) reach past their edges are clipped
//! to their bounds, and the edges that overflow get black and yellow
//! stripes: a layout that does not fit still shows, with the problem
//! marked.

const std = @import("std");
const gfx = @import("gfx");
const vc4 = @import("vc4");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const runtime = @import("runtime.zig");

const Point = geometry.Point;
const Rect = geometry.Rect;
const Node = widget.Node;
const Ui = runtime.Ui;

/// Where a GPU draw goes, in the frame's pixels.
pub const GpuArea = struct {
    /// The widget's box (draw with it as the viewport).
    viewport: vc4.render.Viewport,
    /// The part of it that may be drawn on (null if all of it).
    scissor: ?vc4.render.Viewport,
};

pub const GpuDraw = struct {
    ctx: *const anyopaque,
    f: *const fn (*const anyopaque, *vc4.render.Frame, GpuArea) anyerror!void,
    area: GpuArea,
};

pub const Segment = union(enum) {
    canvas: *gfx.Canvas,
    gpu: GpuDraw,
};

/// Black and yellow, three quarters opaque.
pub const stripe_colors = [2]gfx.Color{ gfx.Color.argb(0xbf000000), gfx.Color.argb(0xbfffff00) };
/// How deep the overflow stripes go into the widget.
pub const stripe_depth = 8;
const stripe_period = 12;

pub const Painter = struct {
    ui: *Ui,
    /// The node being painted, and its top left in the frame.
    node: *Node,
    origin: Point = .{ 0, 0 },
    /// What may be drawn on, in the frame's pixels.
    clip: ?Rect = null,
    /// What the node being painted draws (see `damage.zig`).
    rec: ?*gfx.Record = null,

    /// The canvas to draw on now, with the origin at the widget's top left
    /// and its clip applied.
    pub fn canvas(p: *Painter) *gfx.Canvas {
        const c = p.ui.currentCanvas();
        c.setOrigin(p.origin);
        c.clip = p.clip;
        c.recorder = p.rec;
        return c;
    }

    /// Draws a line of text with its baseline at `baseline`; returns the
    /// pen position after it. Nothing is drawn without a font.
    pub fn text(p: *Painter, size: f32, x: f32, baseline: f32, str: []const u8, color: gfx.Color) f32 {
        const f = p.ui.font orelse return x;
        return p.canvas().drawText(&p.ui.atlas, .{ .font = f, .size = size }, x, baseline, str, color);
    }

    /// Limits drawing to `r` (relative to the widget) until `restoreClip`
    /// with what this returns.
    pub fn clipTo(p: *Painter, r: Rect) ?Rect {
        const old = p.clip;
        p.clip = intersect(p.clip, .{ .x = r.x + p.origin[0], .y = r.y + p.origin[1], .w = r.w, .h = r.h });
        return old;
    }

    pub fn restoreClip(p: *Painter, old: ?Rect) void {
        p.clip = old;
    }

    /// Adds a draw straight into the GPU frame over the widget's box,
    /// between what is painted before it and after it. `f` is called when
    /// the frame is recorded, with `ctx` (which must last until then: the
    /// widget, or its state). The toolkit cannot see what it draws, so it
    /// takes the whole box to change every frame; `gpuWith` can say less.
    pub fn gpu(p: *Painter, ctx: anytype, comptime f: fn (@TypeOf(ctx), *vc4.render.Frame, GpuArea) anyerror!void) void {
        p.gpuWith(.{}, ctx, f);
    }

    pub const GpuOptions = struct {
        /// The part of the box it draws on (relative to the widget), if
        /// less than all of it.
        bounds: ?Rect = null,
        /// Identifies what it draws: the same key as last frame means the
        /// same picture (so nothing needs redrawing). Without one, it
        /// changes every frame.
        key: ?u64 = null,
    };

    pub fn gpuWith(p: *Painter, options: GpuOptions, ctx: anytype, comptime f: fn (@TypeOf(ctx), *vc4.render.Frame, GpuArea) anyerror!void) void {
        const Ctx = @TypeOf(ctx);
        const box = p.boxRect();
        const vp = viewport(box) orelse return;
        var scissor: ?vc4.render.Viewport = null;
        if (p.clip) |clip| scissor = viewport(intersect(clip, box).?) orelse return;
        if (p.rec) |rec| {
            const key = options.key orelse p.ui.frame_no;
            rec.hash.update(std.mem.asBytes(&key));
            const b = if (options.bounds) |r| intersect(box, .{ .x = r.x + p.origin[0], .y = r.y + p.origin[1], .w = r.w, .h = r.h }).? else box;
            if (intersect(p.clip, b)) |area| if (area.w > 0 and area.h > 0) {
                rec.bounds = if (rec.bounds) |old| old.unite(area) else area;
            };
        }
        p.ui.addGpu(.{
            .ctx = @ptrCast(ctx),
            .f = struct {
                fn call(c: *const anyopaque, frame: *vc4.render.Frame, area: GpuArea) anyerror!void {
                    return f(@as(Ctx, @ptrCast(@alignCast(@constCast(c)))), frame, area);
                }
            }.call,
            .area = .{ .viewport = vp, .scissor = scissor },
        });
    }

    fn boxRect(p: *const Painter) Rect {
        return .{ .x = p.origin[0], .y = p.origin[1], .w = p.node.size.w, .h = p.node.size.h };
    }

    /// Paints a node (laid out this frame) and everything below it.
    pub fn paintNode(p: *Painter, n: *Node) void {
        if (n.laid_out != p.ui.frame_no) return;
        const saved_origin = p.origin;
        const saved_clip = p.clip;
        const saved_node = p.node;
        defer {
            p.origin = saved_origin;
            p.clip = saved_clip;
            p.node = saved_node;
        }
        p.node = n;
        p.origin = .{ p.origin[0] + n.offset[0], p.origin[1] + n.offset[1] };
        const box = p.boxRect();
        const overflowing = n.overflow.any();
        if (overflowing) p.clip = intersect(p.clip, box);
        // Nothing of it can show.
        if (p.clip) |c| if (c.w <= 0 or c.h <= 0) return;

        // What it draws itself (not its children), and where it comes in
        // the order of painting, to compare with the last frame.
        var rec: gfx.Record = .{};
        rec.hash.update(std.mem.asBytes(&p.ui.paint_order));
        p.ui.paint_order += 1;
        const saved_rec = p.rec;
        defer p.rec = saved_rec;
        p.rec = &rec;

        const vt = n.widget.vtable;
        if (vt.paint) |f| f(n.widget.ptr, n, p);
        for (n.children.items) |ch| p.paintNode(ch);
        p.node = n;
        p.rec = &rec;
        if (vt.paint_over) |f| f(n.widget.ptr, n, p);
        if (overflowing) p.paintOverflow(n, box);
        p.ui.damage.painted(n, &rec);
    }

    /// Stripes along each edge that something reaches past.
    fn paintOverflow(p: *Painter, n: *Node, box: Rect) void {
        const o = n.overflow;
        const dx = @min(stripe_depth, box.w);
        const dy = @min(stripe_depth, box.h);
        if (o.left > 0) p.stripes(.{ .x = box.x, .y = box.y, .w = dx, .h = box.h });
        if (o.right > 0) p.stripes(.{ .x = box.x + box.w - dx, .y = box.y, .w = dx, .h = box.h });
        if (o.top > 0) p.stripes(.{ .x = box.x, .y = box.y, .w = box.w, .h = dy });
        if (o.bottom > 0) p.stripes(.{ .x = box.x, .y = box.y + box.h - dy, .w = box.w, .h = dy });
    }

    /// Diagonal black and yellow stripes over `r` (in frame pixels).
    pub fn stripes(p: *Painter, r: Rect) void {
        const clip = intersect(p.clip, r) orelse return;
        if (clip.w <= 0 or clip.h <= 0) return;
        const c = p.ui.currentCanvas();
        c.setOrigin(.{ 0, 0 });
        c.clip = clip;
        c.recorder = p.rec;
        c.fillRect(r, stripe_colors[1]);
        const half = stripe_period / 2;
        // Stripes at 45 degrees, from bottom left to top right.
        var x = @floor((r.x - r.h) / stripe_period) * stripe_period;
        while (x < r.x + r.w) : (x += stripe_period) {
            c.fillPolygon(&.{ .{ x, r.y + r.h }, .{ x + r.h, r.y }, .{ x + r.h + half, r.y }, .{ x + half, r.y + r.h } }, stripe_colors[0]);
        }
    }
};

pub fn intersect(a: ?Rect, b: Rect) ?Rect {
    const r = a orelse return b;
    const x0 = @max(r.x, b.x);
    const y0 = @max(r.y, b.y);
    const x1 = @min(r.x + r.w, b.x + b.w);
    const y1 = @min(r.y + r.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0), .h = @max(y1 - y0, 0) };
}

/// Whole pixels covering `r`, or null if it is empty.
fn viewport(r: Rect) ?vc4.render.Viewport {
    const x0 = @floor(r.x);
    const y0 = @floor(r.y);
    const x1 = @ceil(r.x + r.w);
    const y1 = @ceil(r.y + r.h);
    if (!(x1 > x0 and y1 > y0) or @abs(x0) > 1e6 or @abs(y0) > 1e6 or x1 - x0 > 1e6 or y1 - y0 > 1e6) return null;
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0) };
}
