//! The shell's UI made with kete, as the apps' is: a widget tree laid out
//! and painted by a kete `WindowUi` of its own (with no window), drawn on
//! the CPU by kete's software renderer into a panel's picture (see
//! render.zig's panels), and given the shell's input: keys typed by the
//! same XKB keymap the apps are given, so they type alike, and the
//! pointer, in the panel's own coordinates.

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const appearance = @import("appearance");
const keyboard = @import("keyboard.zig");

pub const Panel = struct {
    gpa: std.mem.Allocator,
    ui: *kete.ui.WindowUi,
    software: kete.gfx.software.SoftwareRenderer,
    /// Its picture: 0xAARRGGBB, see-through where nothing is drawn.
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    keyboard_layout: ?locale.Keyboard = null,

    /// A panel drawing text in the font in `font_data` (which must last as
    /// long as it does), or kete's own if there is none.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, font_data: ?[]const u8) !*Panel {
        const p = try gpa.create(Panel);
        errdefer gpa.destroy(p);
        const ui = if (font_data) |d| try kete.ui.WindowUi.createWithFontData(gpa, io, d) else try kete.ui.WindowUi.createDefault(gpa, io);
        p.* = .{ .gpa = gpa, .ui = ui, .software = .init() };
        ui.attachRenderer(p.software.renderer(), false);
        p.followTheme();
        return p;
    }

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

    /// Lays out and paints `root` (a widget, as an app's window has) at
    /// `width` by `height`, and returns its picture.
    pub fn draw(p: *Panel, width: u32, height: u32, now_ns: u64, root: anytype) []const u32 {
        const count = @as(usize, width) * height;
        if (p.pixels.len != count) {
            p.gpa.free(p.pixels);
            p.pixels = p.gpa.alloc(u32, count) catch {
                p.pixels = &.{};
                return &.{};
            };
        }
        p.width = width;
        p.height = height;
        p.ui.frame(width, height, now_ns, root);
        var img: kete.gfx.software.Image = .{ .pixels = p.pixels, .width = width, .height = height };
        img.clear(0);
        p.ui.render(&img, null) catch {};
        return p.pixels;
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

test "a kete widget tree drawn into a panel's picture, see-through around it" {
    const p = try Panel.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"));
    defer p.destroy();
    p.setKeyboard(.gb);
    const px = p.draw(200, 100, 0, Sample{});
    try testing.expectEqual(@as(usize, 200 * 100), px.len);
    // Nothing in the corner; the box in the middle, opaque.
    try testing.expectEqual(@as(u32, 0), px[0] >> 24);
    try testing.expectEqual(@as(u32, 0xff), px[50 * 200 + 100] >> 24);
}
