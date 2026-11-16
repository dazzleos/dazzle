//! The shell's UI made with kete, as the apps' is: each panel (the dock,
//! its tooltip and quick settings, notifications, the performance overlay,
//! the lock screen) is a widget tree laid out and painted by a kete
//! `WindowUi` of its own (with no window), drawn on the CPU by kete's
//! software renderer into the panel's picture (see render.zig's panels),
//! and given the shell's input: keys typed by the same XKB keymap the apps
//! are given, so they type alike, and the pointer, in the panel's own
//! coordinates. The panels share one `Kit`: the font, its glyphs' atlas
//! and the renderer.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const appearance = @import("appearance");
const keyboard = @import("keyboard.zig");

/// What the panels share.
pub const Kit = struct {
    gpa: std.mem.Allocator,
    shared: *kete.ui.SharedResources,
    software: kete.gfx.software.SoftwareRenderer,

    /// Drawing text in the font in `font_data` (which must last as long as
    /// it does), or kete's own if there is none, and emoji in the font at
    /// `emoji_path`, if there is one.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, font_data: ?[]const u8, emoji_path: ?[]const u8) !*Kit {
        const k = try gpa.create(Kit);
        errdefer gpa.destroy(k);
        const shared = try kete.ui.SharedResources.createWithFonts(gpa, io, .empty, .{ .data = font_data, .emoji_path = emoji_path });
        k.* = .{ .gpa = gpa, .shared = shared, .software = .init() };
        shared.attachRenderer(k.software.renderer(), false);
        return k;
    }

    /// Its panels must be destroyed first.
    pub fn destroy(k: *Kit) void {
        k.shared.destroy();
        k.gpa.destroy(k);
    }

    pub fn panel(k: *Kit) !*Panel {
        const p = try k.gpa.create(Panel);
        errdefer k.gpa.destroy(p);
        p.* = .{ .gpa = k.gpa, .ui = try k.shared.createWindowUi() };
        p.followTheme();
        return p;
    }
};

pub const Panel = struct {
    gpa: std.mem.Allocator,
    ui: *kete.ui.WindowUi,
    /// Its picture: 0xAARRGGBB (not premultiplied), see-through where
    /// nothing is drawn.
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    keyboard_layout: ?locale.Keyboard = null,

    pub fn destroy(p: *Panel) void {
        p.ui.destroy();
        p.gpa.free(p.pixels);
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
    /// memory for it). Only what changed since it was last drawn (kete's
    /// damage) is drawn again, unless its size changed.
    pub fn draw(p: *Panel, width: u32, height: u32, now_ns: u64, root: anytype) []const u32 {
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
        p.ui.frame(width, height, now_ns, root);
        var img: kete.gfx.software.Image = .{ .pixels = p.pixels[0..count], .width = width, .height = height };
        var vps: [kete.ui.damage.Region.max_rects]kete.gfx.Viewport = undefined;
        // kete's damage rectangles never overlap, so what is see-through
        // is blended once.
        const damage: ?[]const kete.gfx.Viewport = if (whole) null else p.ui.damagedViewports(&vps);
        if (damage) |d| if (d.len == 0) return p.pixels[0..count];
        img.clearDamage(damage, 0);
        p.ui.render(&img, damage) catch {};
        return p.pixels[0..count];
    }

    /// A key (a Linux key code) went down or up.
    pub fn key(p: *Panel, code: u32, pressed: bool) void {
        p.ui.handleInput(.{ .key = .{ .key = kete.window.evdev.keyOf(@intCast(code)), .pressed = pressed } });
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
    const kit = try Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    const p = try kit.panel();
    defer p.destroy();
    const fresh = try kit.panel();
    defer fresh.destroy();
    _ = p.draw(100, 90, 0, Rows{ .lit = 0 });
    for (1..4) |lit| {
        const again = p.draw(100, 90, lit, Rows{ .lit = lit });
        try testing.expectEqualSlices(u32, fresh.draw(100, 90, 0, Rows{ .lit = lit }), again);
        fresh.width = 0;
    }
}

test "kete widget trees drawn into panels' pictures, see-through where nothing is" {
    const kit = try Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null);
    defer kit.destroy();
    const p = try kit.panel();
    defer p.destroy();
    p.setKeyboard(.gb);
    const px = p.draw(200, 100, 0, Sample{});
    try testing.expectEqual(@as(usize, 200 * 100), px.len);
    // Nothing in the corner; the box in the middle, opaque.
    try testing.expectEqual(@as(u32, 0), px[0] >> 24);
    try testing.expectEqual(@as(u32, 0xff), px[50 * 200 + 100] >> 24);
    // A second panel, sharing the font: a see-through box keeps its alpha
    // and colour (not premultiplied).
    const q = try kit.panel();
    defer q.destroy();
    const g = q.draw(60, 20, 0, Glass{});
    try testing.expectEqual(@as(u32, 0xb81c2a4a), g[10 * 60 + 30]);
    try testing.expectEqual([2]u32{ 60, 20 }, q.naturalSize(Glass{}));
}
