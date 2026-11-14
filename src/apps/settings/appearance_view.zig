//! The Appearance page: system colour scheme (Dark or Light), and the
//! desktop's background: one of the built-in photos, picked here (or a
//! picture chosen in Files).

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const appearance_settings = @import("appearance");
const builtin = appearance_settings.backgrounds;
const view = @import("view.zig");
const gfx = kete.gfx;
const sys = @import("sys");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;

pub const label = "Appearance";
pub const icon: kete.IconName = .palette;

pub const State = struct {
    appearance: appearance_settings.Settings = .{},
    actions: ?*Actions = null,

    fn setDark(st: *State) void {
        const acts = st.actions orelse return;
        var next = acts.appearance orelse st.appearance;
        next.theme = .dark;
        acts.appearance = next;
    }

    fn setLight(st: *State) void {
        const acts = st.actions orelse return;
        var next = acts.appearance orelse st.appearance;
        next.theme = .light;
        acts.appearance = next;
    }

    fn setImage(comptime bg: builtin.BuiltIn) fn (*State) void {
        return struct {
            fn set(st: *State) void {
                const acts = st.actions orelse return;
                var next = acts.appearance orelse st.appearance;
                next.image = .of(builtin.path(bg));
                acts.appearance = next;
            }
        }.set;
    }
};

pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const a = cx.arena;

    state.appearance = self.appearance;
    state.actions = self.actions;

    var rows: std.ArrayList(kete.Widget) = .empty;

    const theme_bar = cx.make(kete.PillBar{
        .children = &.{
            cx.make(kete.PillButton{
                .label = "Dark",
                .icon = .dark_mode,
                .selected = self.appearance.theme == .dark,
                .first = true,
                .on_press = if (self.actions != null) .of(state, State.setDark) else null,
            }),
            cx.make(kete.PillButton{
                .label = "Light",
                .icon = .light_mode,
                .selected = self.appearance.theme == .light,
                .last = true,
                .on_press = if (self.actions != null) .of(state, State.setLight) else null,
            }),
        },
    });

    rows.append(a, cx.make(kete.Row{
        .cross_axis_alignment = .center,
        .spacing = 12,
        .children = &.{
            b.label("Theme"),
            theme_bar,
        },
    })) catch {};

    // A tile of each photo under its label; the one chosen is ringed, as
    // a radio button is.
    rows.append(a, cx.make(kete.Column{
        .cross_axis_alignment = .start,
        .spacing = 8,
        .children = cx.makeAll(.{
            b.label("Background"),
            photoRow(cx, self, state),
        }),
    })) catch {};

    return b.page(rows.items);
}

/// The built-in photos, each a tile of it, and the picture chosen in Files
/// if it is the background; the one chosen is ringed.
fn photoRow(cx: *kete.BuildContext, self: *const Settings, state: *State) kete.Widget {
    var tiles: [builtin.all.len + 1]kete.Widget = undefined;
    const chosen = self.appearance.image.slice() orelse "";
    inline for (builtin.all, tiles[0..builtin.all.len], 0..) |bg, *t, i| {
        t.* = tile(cx, bg.name, thumbnail(i), std.mem.eql(u8, chosen, builtin.path(bg)), if (self.actions != null) .of(state, State.setImage(bg)) else null);
    }
    var count: usize = builtin.all.len;
    if (chosen.len > 0 and builtin.find(chosen) == null) {
        const name = chosen[if (std.mem.lastIndexOfScalar(u8, chosen, '/')) |slash| slash + 1 else 0..];
        tiles[count] = tile(cx, name, customThumbnail(chosen), true, null);
        count += 1;
    }
    return cx.make(kete.Row{ .spacing = 8, .children = cx.arena.dupe(kete.Widget, tiles[0..count]) catch &.{} });
}

/// A picture's tile: its thumbnail, rounded, named by its tooltip, and
/// ringed in the theme's primary colour when it is the one chosen.
fn tile(cx: *kete.BuildContext, name: []const u8, image: ?*const gfx.Image, chosen: bool, on_press: ?kete.Callback) kete.Widget {
    const t = cx.theme();
    return cx.make(kete.Tooltip{
        .text = name,
        .child = cx.make(kete.Pressable{
            .on_press = on_press,
            .child = cx.make(kete.RoundedBox{
                .border_width = if (chosen) ring else 0,
                .border_color = if (chosen) t.primary else null,
                .radius = .all(tile_radius + ring + ring_gap),
                .child = cx.make(kete.Padding{
                    .padding = .all(ring + ring_gap),
                    .child = cx.make(kete.SizedBox{
                        .width = builtin.thumbnail_width,
                        .height = builtin.thumbnail_height,
                        .child = if (image) |img| cx.make(kete.Image{ .source = .{ .image = img } }) else cx.make(kete.SizedBox.empty),
                    }),
                }),
            }),
        }),
    });
}

/// The picture chosen in Files, as a thumbnail: made when it is first
/// shown (and again when another is chosen).
var custom_path: appearance_settings.ImagePath = .{};
var custom_pixels: [builtin.thumbnail_width * builtin.thumbnail_height]u32 = undefined;
var custom_image: ?gfx.Image = null;

fn customThumbnail(path: []const u8) ?*const gfx.Image {
    if (!std.mem.eql(u8, custom_path.slice() orelse "", path)) {
        custom_path = .of(path);
        custom_image = null;
        if (makeThumbnail(path, &custom_pixels)) custom_image = .init(&custom_pixels, builtin.thumbnail_width, builtin.thumbnail_height);
    }
    return if (custom_image) |*img| img else null;
}

/// Reads the PNG at `path` into `out`, as a thumbnail: scaled to cover it
/// (cropped in the middle), each pixel the average of those it covers, its
/// corners rounded. Returns whether it could.
fn makeThumbnail(path: []const u8, out: []u32) bool {
    const gpa = std.heap.smp_allocator;
    var path_buf: [appearance_settings.ImagePath.max_len + 1]u8 = undefined;
    const pathz = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0) catch return false;
    const bytes = sys.readFileAlloc(gpa, pathz, 64 * 1024 * 1024) catch return false;
    defer gpa.free(bytes);
    const img = gfx.png.decode(gpa, bytes) catch return false;
    defer gpa.free(img.pixels);
    const tw: u32 = builtin.thumbnail_width;
    const th: u32 = builtin.thumbnail_height;
    if (img.width == 0 or img.height == 0) return false;
    // The part of the picture shown: as wide, or as tall, as it can be.
    const scale = @max(@as(f64, tw) / @as(f64, @floatFromInt(img.width)), @as(f64, th) / @as(f64, @floatFromInt(img.height)));
    const vw = @as(f64, tw) / scale;
    const vh = @as(f64, th) / scale;
    const ox = (@as(f64, @floatFromInt(img.width)) - vw) / 2;
    const oy = (@as(f64, @floatFromInt(img.height)) - vh) / 2;
    for (0..th) |y| for (0..tw) |x| {
        const x0: usize = @intFromFloat(@floor(ox + @as(f64, @floatFromInt(x)) / scale));
        const y0: usize = @intFromFloat(@floor(oy + @as(f64, @floatFromInt(y)) / scale));
        const x1 = @min(@max(@as(usize, @intFromFloat(@floor(ox + @as(f64, @floatFromInt(x + 1)) / scale))), x0 + 1), img.width);
        const y1 = @min(@max(@as(usize, @intFromFloat(@floor(oy + @as(f64, @floatFromInt(y + 1)) / scale))), y0 + 1), img.height);
        var sum: [3]u64 = .{ 0, 0, 0 };
        for (y0..y1) |sy| for (x0..x1) |sx| {
            const px = img.pixels[sy * img.width + sx];
            sum[0] += px >> 16 & 0xff;
            sum[1] += px >> 8 & 0xff;
            sum[2] += px & 0xff;
        };
        const n = @max((y1 - y0) * (x1 - x0), 1);
        out[y * tw + x] = @intCast(0xff000000 | (sum[0] / n) << 16 | (sum[1] / n) << 8 | sum[2] / n);
    };
    roundCorners(out, tw, th, tile_radius);
    return true;
}

/// The built-in photos' thumbnails (made at build time), decoded the first
/// time they show: kete's Image is given their pixels, as it cannot load
/// bytes without the app's `std.Io`.
var thumbnail_pixels: [builtin.all.len][builtin.thumbnail_width * builtin.thumbnail_height]u32 = undefined;
var thumbnails: [builtin.all.len]?gfx.Image = @splat(null);

fn thumbnail(comptime i: usize) ?*const gfx.Image {
    if (thumbnails[i] == null) {
        const bytes = @embedFile("background-" ++ builtin.all[i].file ++ ".png");
        const decoded = gfx.png.decode(std.heap.smp_allocator, bytes) catch return null;
        defer std.heap.smp_allocator.free(decoded.pixels);
        if (decoded.width != builtin.thumbnail_width or decoded.height != builtin.thumbnail_height) return null;
        @memcpy(&thumbnail_pixels[i], decoded.pixels);
        roundCorners(&thumbnail_pixels[i], decoded.width, decoded.height, tile_radius);
        thumbnails[i] = .init(&thumbnail_pixels[i], decoded.width, decoded.height);
    }
    return &thumbnails[i].?;
}

/// Makes the corners of `pixels` (`w` by `h`), outside a rounded rectangle
/// of `radius`, see-through (anti-aliased).
fn roundCorners(pixels: []u32, w: u32, h: u32, radius: f32) void {
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const n: u32 = @intFromFloat(@ceil(radius));
    for (0..h) |py| {
        if (py >= n and py + n < h) continue;
        for (0..w) |px| {
            if (px >= n and px + n < w) continue;
            const qx = @abs(@as(f32, @floatFromInt(px)) + 0.5 - fw / 2) - (fw / 2 - radius);
            const qy = @abs(@as(f32, @floatFromInt(py)) + 0.5 - fh / 2) - (fh / 2 - radius);
            const outside = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
            const coverage = std.math.clamp(0.5 - outside, 0, 1);
            const p = &pixels[py * w + px];
            p.* = (p.* & 0x00ffffff) | @as(u32, @intFromFloat(@round(coverage * 255))) << 24;
        }
    }
}

/// The radius of a photo tile's corners.
const tile_radius = 10;
/// The ring around the chosen photo, and the gap inside it.
const ring = 3;
const ring_gap = 3;

/// A photo's tile, by its tooltip.
fn findTile(n: *kete.WidgetNode, name: []const u8) ?*kete.WidgetNode {
    if (n.widget.as(kete.Tooltip)) |tip| if (std.mem.eql(u8, tip.text, name)) return n;
    for (n.children.items) |ch| if (findTile(ch, name)) |found| return found;
    return null;
}

/// Whether a photo's tile is ringed (chosen).
fn ringed(n: *kete.WidgetNode, name: []const u8) bool {
    var at = findTile(n, name).?;
    while (!at.widget.is(kete.RoundedBox)) at = at.children.items[0];
    return at.widget.as(kete.RoundedBox).?.border_color != null;
}

const testing = std.testing;
const font = kete.font;

test "Appearance page toggles between Dark and Light theme" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .appearance = .{ .theme = .dark } };
    u.frame(1280, 720, 1, settings);
    _ = view.showPage(u, .appearance);
    u.frame(1280, 720, 2, settings);
    try testing.expect(view.findText(u.root.?, "Theme") != null);

    // Clicking Light, then Dark, sets the theme, keeping the background.
    view.click(u, view.up(view.findText(u.root.?, "Light").?, kete.Pressable).?);
    try testing.expectEqual(appearance_settings.Mode.light, actions.appearance.?.theme);
    try testing.expectEqualStrings("/os/backgrounds/forest.etc1", actions.appearance.?.image.slice().?);
    settings.appearance = actions.appearance.?;
    u.theme = kete_vc4.themeMode(settings.appearance.theme).scheme();
    actions = .{};
    u.frame(1280, 720, 3, settings);
    try testing.expectEqual(kete.Theme.light.surface, u.theme.surface);
    view.click(u, view.up(view.findText(u.root.?, "Dark").?, kete.Pressable).?);
    try testing.expectEqual(appearance_settings.Mode.dark, actions.appearance.?.theme);
}

test "a built-in photo is picked as the background, shown by its rounded thumbnail" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .appearance = .{} };
    u.frame(1280, 720, 1, settings);
    _ = view.showPage(u, .appearance);
    u.frame(1280, 720, 2, settings);
    // A tile of each, its thumbnail's pixels given (not bytes to load);
    // the forest, to start with, is ringed.
    inline for (builtin.all) |bg| {
        const found = findTile(u.root.?, bg.name).?;
        var at = found;
        while (!at.widget.is(kete.Image)) at = at.children.items[0];
        try testing.expect(at.widget.as(kete.Image).?.source == .image);
    }
    try testing.expect(ringed(u.root.?, "Forest"));
    try testing.expect(!ringed(u.root.?, "Seashore"));
    // Rounded: see-through at the corners.
    try testing.expectEqual(@as(u32, 0), thumbnail(0).?.pixels[0] >> 24);
    try testing.expectEqual(@as(u32, 0xff), thumbnail(0).?.pixels[builtin.thumbnail_width * 30 + 50] >> 24);

    view.click(u, findTile(u.root.?, "Seashore").?.child(0));
    try testing.expectEqualStrings("/os/backgrounds/seashore.etc1", actions.appearance.?.image.slice().?);
    settings.appearance = actions.appearance.?;
    u.frame(1280, 720, 3, settings);
    try testing.expect(ringed(u.root.?, "Seashore"));
    try testing.expect(!ringed(u.root.?, "Forest"));

    // Without a picture chosen in Files: just the built-in photos.
    try testing.expect(view.up(findTile(u.root.?, "Forest").?, kete.Row).?.children.items.len == builtin.all.len);
}

test "a picture chosen in Files is a fourth tile, ringed, with its thumbnail" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    // A 40 by 10 picture: red on the left, blue on the right.
    var pixels: [40 * 10]u32 = undefined;
    for (&pixels, 0..) |*px, i| px.* = if (i % 40 < 20) 0xffff0000 else 0xff0000ff;
    const png = try gfx.png.encode(testing.allocator, &pixels, 40, 10);
    defer testing.allocator.free(png);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/dazzle-settings-sea-{d}.png", .{std.os.linux.getpid()}, 0);
    _ = std.os.linux.unlink(path);
    try sys.files.writeNew(path, png);
    defer _ = std.os.linux.unlink(path);

    const d = view.sample();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .appearance = .{ .image = .of(path) } };
    u.frame(1280, 720, 1, settings);
    _ = view.showPage(u, .appearance);
    u.frame(1280, 720, 2, settings);
    const name = path[std.mem.lastIndexOfScalar(u8, path, '/').? + 1 ..];
    try testing.expect(ringed(u.root.?, name));
    inline for (builtin.all) |bg| try testing.expect(!ringed(u.root.?, bg.name));
    try testing.expectEqual(builtin.all.len + 1, view.up(findTile(u.root.?, name).?, kete.Row).?.children.items.len);
    // Its thumbnail: the middle of it, scaled; corners rounded.
    const thumb = customThumbnail(path).?;
    try testing.expectEqual(@as(u32, 0xffff0000), thumb.pixels[30 * builtin.thumbnail_width + 10]);
    try testing.expectEqual(@as(u32, 0xff0000ff), thumb.pixels[30 * builtin.thumbnail_width + builtin.thumbnail_width - 10]);
    try testing.expectEqual(@as(u32, 0), thumb.pixels[0] >> 24);
}
