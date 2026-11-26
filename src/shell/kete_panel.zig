//! The shell's UI made with kete, as the apps' is: each panel (the dock,
//! its tooltip and quick settings, notifications, the performance overlay,
//! the lock screen) is a widget tree laid out and painted by a kete
//! `WindowUi` of its own (with no window), and given the shell's input:
//! keys typed by the same XKB keymap the apps are given, so they type
//! alike, and the pointer, in the panel's own coordinates. The panels
//! share one `Kit`: the font, its glyphs' atlas and the renderers.
//!
//! A panel is drawn into its picture (see render.zig's panels) on the
//! GPU, by kete_vc4's renderer (as the apps' windows are), if it is made
//! with `Kit.gpuPanel` and the kit has the GPU (`Kit.useGpu`): those big
//! enough, and drawn often enough, for it to be worth it (the dock, its
//! quick settings, the performance overlay). Others, and all of them where
//! there is no GPU (in tests), are drawn on the CPU by kete's software
//! renderer.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const appearance = @import("appearance");
const keyboard = @import("keyboard.zig");
const sys = @import("sys");
const vc4 = @import("vc4");
const app = @import("app");
const kete_vc4 = @import("kete_vc4");

/// A panel's picture as last drawn: its pixels, or, drawn on the GPU, its
/// texture.
pub const Picture = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Drawn on the CPU: 0xAARRGGBB (not premultiplied), see-through where
    /// nothing is drawn.
    pixels: []const u32 = &.{},
    /// Drawn on the GPU: the buffer (its GEM handle) holding it as a
    /// texture (ARGB8888, premultiplied, tiled as the texture unit reads
    /// it), the same each time it is drawn at the same size.
    texture: ?u32 = null,

    /// Whether there is nothing (there was no memory to draw it in).
    pub fn isEmpty(p: Picture) bool {
        return p.pixels.len == 0 and p.texture == null;
    }
};

/// The GPU, for the panels drawn on it: the device, and kete_vc4's
/// renderer.
const Gpu = struct {
    dev: vc4.Device,
    renderer: kete_vc4.Renderer,
};

/// How long something took, over the times it was done: for remote
/// control's status, to see what the panels cost on the computer itself.
pub const Times = struct {
    count: u32 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    /// The pixels it was done for, over all of them.
    pixels: u64 = 0,

    pub fn add(t: *Times, ns: u64, pixels: u64) void {
        t.count += 1;
        t.total_ns += ns;
        t.max_ns = @max(t.max_ns, ns);
        t.pixels += pixels;
    }

    /// "<count>x avg <µs> max <µs>, <pixels> px avg".
    pub fn format(t: Times, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (t.count == 0) return w.writeAll("none");
        try w.print("{d}x avg {d} us max {d} us, {d} px avg", .{ t.count, t.total_ns / t.count / 1000, t.max_ns / 1000, t.pixels / t.count });
    }
};

/// What the panels share.
pub const Kit = struct {
    gpa: std.mem.Allocator,
    shared: *kete.ui.SharedResources,
    software: kete.gfx.software.SoftwareRenderer,
    gpu: ?*Gpu = null,

    /// Drawing text in the font in `font_data` (which must last as long as
    /// it does), or kete's own if there is none, emoji in the font at
    /// `emoji_path`, if there is one, and other scripts (Chinese) in those
    /// at `fallback_paths` (those there are).
    pub fn create(gpa: std.mem.Allocator, io: std.Io, font_data: ?[]const u8, emoji_path: ?[]const u8, fallback_paths: []const []const u8) !*Kit {
        const k = try gpa.create(Kit);
        errdefer gpa.destroy(k);
        const shared = try kete.ui.SharedResources.createWithFonts(gpa, io, .empty, .{ .data = font_data, .emoji_path = emoji_path, .fallback_paths = fallback_paths });
        k.* = .{ .gpa = gpa, .shared = shared, .software = .init() };
        shared.attachRenderer(k.software.renderer(), false);
        return k;
    }

    /// Draws the panels made with `gpuPanel` on the GPU `dev` from now on
    /// (those made before keep how they are drawn).
    pub fn useGpu(k: *Kit, dev: vc4.Device) !void {
        if (k.gpu != null) return;
        const g = try k.gpa.create(Gpu);
        errdefer k.gpa.destroy(g);
        g.dev = dev;
        g.renderer = try kete_vc4.Renderer.init(k.gpa, dev, app.Gpu.device(&g.dev));
        k.gpu = g;
    }

    /// Its panels must be destroyed first.
    pub fn destroy(k: *Kit) void {
        if (k.gpu) |g| {
            g.renderer.deinit();
            k.gpa.destroy(g);
        }
        k.shared.destroy();
        k.gpa.destroy(k);
    }

    /// A panel drawn on the CPU.
    pub fn panel(k: *Kit) !*Panel {
        return k.makePanel(null);
    }

    /// A panel drawn on the GPU, if the kit has it (`useGpu`).
    pub fn gpuPanel(k: *Kit) !*Panel {
        return k.makePanel(k.gpu);
    }

    fn makePanel(k: *Kit, gpu: ?*Gpu) !*Panel {
        const p = try k.gpa.create(Panel);
        errdefer k.gpa.destroy(p);
        p.* = .{ .gpa = k.gpa, .ui = try k.shared.createWindowUi(), .gpu = gpu };
        p.followTheme();
        return p;
    }
};

pub const Panel = struct {
    gpa: std.mem.Allocator,
    ui: *kete.ui.WindowUi,
    /// Its picture, drawn on the CPU: 0xAARRGGBB (not premultiplied),
    /// see-through where nothing is drawn.
    pixels: []u32 = &.{},
    /// Or drawn on the GPU (see `Picture.texture`), into this.
    gpu: ?*Gpu = null,
    texture: ?vc4.Bo = null,
    width: u32 = 0,
    height: u32 = 0,
    keyboard_layout: ?locale.Keyboard = null,
    /// The Shift and Control keys held (left, right), as the keys it was
    /// given say: Shift and Tab moves the focus back.
    shift_held: [2]bool = .{ false, false },
    ctrl_held: [2]bool = .{ false, false },
    /// Its widgets laid out and painted (`frame`), and drawn into its
    /// picture (`render`), each time it is drawn.
    frame_times: Times = .{},
    render_times: Times = .{},
    /// Drawn on the GPU: of `render_times`, the GPU's part (from handing
    /// it the frame to its finishing), and of that, the waiting.
    gpu_times: Times = .{},
    wait_times: Times = .{},
    /// And the kernel taking the job.
    submit_times: Times = .{},

    pub fn destroy(p: *Panel) void {
        p.ui.destroy();
        p.gpa.free(p.pixels);
        if (p.texture) |bo| p.gpu.?.dev.destroyBo(bo);
        p.gpa.destroy(p);
    }

    /// In the system's theme (light or dark), as the apps are.
    pub fn followTheme(p: *Panel) void {
        p.ui.theme = switch (appearance.loadSettings().theme) {
            inline else => |tag| @field(kete.ui.theme.ThemeMode, @tagName(tag)),
        }.scheme();
    }

    /// Types keys as `layout` does (the keymap the apps have).
    pub fn setKeyboard(p: *Panel, layout: locale.Keyboard) void {
        if (p.keyboard_layout == layout) return;
        p.keyboard_layout = layout;
        const text = keyboard.keymap(layout);
        // Without the NUL the protocol counts.
        p.ui.loadKeymap(std.mem.trimEnd(u8, text, "\x00")) catch {};
    }

    /// How big `root` would like to be (its widgets' natural size).
    pub fn naturalSize(p: *Panel, root: anytype) [2]u32 {
        const n = p.ui.naturalSize(root);
        return .{ n.size[0] orelse n.least[0], n.size[1] orelse n.least[1] };
    }

    /// Lays out and paints `root` (a widget, as an app's window has) at
    /// `width` by `height`, and returns its picture (empty if there is no
    /// memory for it). It is drawn again only if something changed (kete's
    /// damage), and on the CPU only where it did, unless its size changed.
    pub fn draw(p: *Panel, width: u32, height: u32, now_ns: u64, root: anytype) Picture {
        if (p.gpu) |g| return p.drawGpu(g, width, height, now_ns, root);
        const pixels = p.drawCpu(width, height, now_ns, root);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    /// Drawn whole (the GPU's frames are cheap) into its texture, cleared
    /// to see-through: blended as the GPU blends, what is drawn comes out
    /// premultiplied.
    fn drawGpu(p: *Panel, g: *Gpu, width: u32, height: u32, now_ns: u64, root: anytype) Picture {
        const resized = p.texture == null or width != p.width or height != p.height;
        if (resized) {
            if (p.texture) |bo| g.dev.destroyBo(bo);
            p.texture = null;
            p.width = 0;
            p.height = 0;
            if (width == 0 or height == 0) return .{};
            p.texture = g.dev.createBo(vc4.texture.imageSizeOf(.argb8888, width, height)) catch return .{};
            p.width = width;
            p.height = height;
        }
        const bo = p.texture.?;
        const picture: Picture = .{ .width = width, .height = height, .texture = bo.handle };
        const count = @as(u64, width) * height;
        const started = sys.nowNs();
        p.ui.frame(width, height, now_ns, root);
        const framed = sys.nowNs();
        p.frame_times.add(framed - started, count);
        var vps: [kete.ui.damage.Region.max_rects]kete.gfx.Viewport = undefined;
        if (!resized and p.ui.damagedViewports(&vps).len == 0) return picture;
        const f = p.ui.framePacket(0);
        const target: kete.gfx.DmabufTarget = .{
            .id = bo.handle,
            .fd = -1,
            .fourcc = vc4.Format.argb8888.fourcc().?,
            .modifier = kete_vc4.renderer.tiled_modifier,
            .offset = 0,
            .stride = 0,
            .width = width,
            .height = height,
            .origin = .{ 0, 0 },
            .content = .{ width, height },
            .cpu = undefined,
        };
        const all = [_]kete.gfx.Viewport{.{ .x = 0, .y = 0, .width = width, .height = height }};
        const waited = app.window.gpu_waited_ns;
        const submitted = app.window.gpu_submit_ns;
        g.renderer.renderDmabuf(f.canvases, f.segments, &target, 0, &.{}, &all) catch |err| {
            sys.print(sys.log_warning ++ "dazzle-shell: a panel is not drawn on the GPU: {s}\n", .{@errorName(err)});
            return .{};
        };
        p.render_times.add(sys.nowNs() - framed, count);
        p.gpu_times.add(g.renderer.takeStats().gpu_ns, count);
        p.wait_times.add(app.window.gpu_waited_ns -% waited, count);
        p.submit_times.add(app.window.gpu_submit_ns -% submitted, count);
        return picture;
    }

    fn drawCpu(p: *Panel, width: u32, height: u32, now_ns: u64, root: anytype) []const u32 {
        const count = @as(usize, width) * height;
        var whole = width != p.width or height != p.height;
        if (p.pixels.len < count) {
            p.gpa.free(p.pixels);
            p.pixels = p.gpa.alloc(u32, count) catch {
                p.pixels = &.{};
                p.width = 0;
                return &.{};
            };
            whole = true;
        }
        p.width = width;
        p.height = height;
        const started = sys.nowNs();
        p.ui.frame(width, height, now_ns, root);
        const framed = sys.nowNs();
        p.frame_times.add(framed - started, count);
        var img: kete.gfx.software.Image = .{ .pixels = p.pixels[0..count], .width = width, .height = height };
        var vps: [kete.ui.damage.Region.max_rects]kete.gfx.Viewport = undefined;
        // kete's damage rectangles never overlap, so what is see-through
        // is blended once.
        const damage: ?[]const kete.gfx.Viewport = if (whole) null else p.ui.damagedViewports(&vps);
        if (damage) |d| if (d.len == 0) return p.pixels[0..count];
        img.clearDamage(damage, 0);
        p.ui.render(&img, damage) catch {};
        var drawn: u64 = count;
        if (damage) |d| {
            drawn = 0;
            for (d) |v| drawn += @as(u64, v.width) * v.height;
        }
        p.render_times.add(sys.nowNs() - framed, drawn);
        return p.pixels[0..count];
    }

    /// A key (a Linux key code) went down or up.
    pub fn key(p: *Panel, code: u32, pressed: bool) void {
        switch (code) {
            42 => p.shift_held[0] = pressed,
            54 => p.shift_held[1] = pressed,
            29 => p.ctrl_held[0] = pressed,
            97 => p.ctrl_held[1] = pressed,
            else => {},
        }
        p.ui.handleInput(.{ .key = .{
            .key = kete.window.evdev.keyOf(@intCast(code)),
            .pressed = pressed,
            .shift = p.shift_held[0] or p.shift_held[1],
            .ctrl = p.ctrl_held[0] or p.ctrl_held[1],
        } });
    }

    /// The focus moved as Tab (or Shift and Tab, back) moves it: to the
    /// first (the last) widget that takes it, if nothing has it yet.
    pub fn moveFocus(p: *Panel, forward: bool) void {
        p.ui.handleInput(.{ .key = .{ .key = .tab, .pressed = true, .shift = !forward } });
        p.ui.handleInput(.{ .key = .{ .key = .tab, .pressed = false, .shift = !forward } });
    }

    /// The pointer, at `pos` in the panel.
    pub fn pointerMotion(p: *Panel, pos: [2]f32) void {
        p.ui.handleInput(.{ .motion = pos });
    }

    pub fn pointerButton(p: *Panel, pos: [2]f32, pressed: bool) void {
        p.ui.handleInput(.{ .button = .{ .pos = pos, .button = .left, .pressed = pressed } });
    }

    /// Whether it wants drawing again (something changed, or animates).
    pub fn needsFrame(p: *const Panel) bool {
        return p.ui.needs_frame;
    }
};

const testing = std.testing;

const Sample = struct {
    pub fn build(_: *const Sample, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.Align{ .child = cx.make(kete.RoundedBox{ .color = cx.theme().surface, .radius = .all(12), .child = cx.make(kete.SizedBox{ .width = 100, .height = 40, .child = cx.make(kete.Text{ .text = "Hi" }) }) }) });
    }
};

/// A see-through box (as the dock's), and text on it.
const Glass = struct {
    pub fn build(_: *const Glass, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.RoundedBox{ .color = kete.gfx.Color.argb(0xb81c2a4a), .child = cx.make(kete.SizedBox{ .width = 60, .height = 20 }) });
    }
};

/// Rows of see-through bars, which change: drawn again in part.
const Rows = struct {
    lit: usize,

    pub fn build(r: *const Rows, cx: *kete.BuildContext) kete.Widget {
        var rows: [4]kete.Widget = undefined;
        for (&rows, 0..) |*w, i| w.* = cx.make(kete.SizedBox{ .height = 20, .child = cx.make(kete.RoundedBox{ .color = kete.gfx.Color.argb(if (i == r.lit) 0xff3f7ee8 else 0x40ffffff), .radius = .all(4) }) });
        return cx.make(kete.RoundedBox{ .color = kete.gfx.Color.argb(0xb81c2a4a), .child = cx.make(kete.Column{ .spacing = 1, .children = cx.arena.dupe(kete.Widget, &rows) catch &.{} }) });
    }
};

test "drawn again only where it changed, the same as drawn whole" {
    const kit = try Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null, &.{});
    defer kit.destroy();
    const p = try kit.panel();
    defer p.destroy();
    const fresh = try kit.panel();
    defer fresh.destroy();
    _ = p.draw(100, 90, 0, Rows{ .lit = 0 });
    for (1..4) |lit| {
        const again = p.draw(100, 90, lit, Rows{ .lit = lit }).pixels;
        try testing.expectEqualSlices(u32, fresh.draw(100, 90, 0, Rows{ .lit = lit }).pixels, again);
        fresh.width = 0;
    }
}

test "kete widget trees drawn into panels' pictures, see-through where nothing is" {
    const kit = try Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null, &.{});
    defer kit.destroy();
    const p = try kit.panel();
    defer p.destroy();
    p.setKeyboard(.gb);
    const px = p.draw(200, 100, 0, Sample{}).pixels;
    try testing.expectEqual(@as(usize, 200 * 100), px.len);
    // Nothing in the corner; the box in the middle, opaque.
    try testing.expectEqual(@as(u32, 0), px[0] >> 24);
    try testing.expectEqual(@as(u32, 0xff), px[50 * 200 + 100] >> 24);
    // A second panel, sharing the font: a see-through box keeps its alpha
    // and colour (not premultiplied).
    const q = try kit.panel();
    defer q.destroy();
    const g = q.draw(60, 20, 0, Glass{}).pixels;
    try testing.expectEqual(@as(u32, 0xb81c2a4a), g[10 * 60 + 30]);
    try testing.expectEqual([2]u32{ 60, 20 }, q.naturalSize(Glass{}));
}
