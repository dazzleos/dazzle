//! The dock along the bottom of the screen: an icon for each app in /apps.
//! Clicking one starts the app or, if it is running, brings its window to
//! the front (apps run once each).
//!
//! An app is a directory /apps/<name> holding its program, also called
//! <name>, and the files it needs (such as its font). Its icon is its
//! initial on a coloured square, with a dot under it while it runs.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const font = @import("font");

pub const apps_dir = "/apps";

const background = 0xff1c2a4a;
const hover_background = 0xff2c3e66;
const dot_color = 0xffe8eefc;
/// Icon colours, picked by the app's name.
const palette = [_]u32{ 0xff3f7ee8, 0xffe8743f, 0xff3fb86e, 0xffb04fd6, 0xffe8b33f, 0xff3fb8c4, 0xffe84f6a };

pub const App = struct {
    /// Its directory's name, and its program's.
    name: []const u8,
    /// The name shown: without a "stardust-" prefix, capitalised.
    label: []const u8,
    /// The program: /apps/<name>/<name>.
    path: [:0]const u8,
    /// Its process, while it runs.
    pid: ?linux.pid_t = null,

    fn color(a: *const App) u32 {
        return palette[std.hash.Fnv1a_32.hash(a.name) % palette.len];
    }
};

/// The apps in `dir`, sorted by name: its directories that hold a program
/// of the same name.
pub fn findApps(gpa: std.mem.Allocator, dir_path: []const u8) ![]App {
    var path_buf: [256]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{dir_path});
    const dir = sys.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return &.{};
    defer sys.close(dir);
    var apps: std.ArrayList(App) = .empty;
    errdefer apps.deinit(gpa);
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n = try sys.check(linux.getdents64(dir, &buf, buf.len));
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.') continue;
            const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}/{s}", .{ dir_path, name, name }, 0);
            if (linux.errno(linux.access(path, linux.X_OK)) != .SUCCESS) {
                gpa.free(path);
                continue;
            }
            const owned = try gpa.dupe(u8, name);
            try apps.append(gpa, .{ .name = owned, .label = try label(gpa, owned), .path = path });
        }
    }
    std.mem.sort(App, apps.items, {}, struct {
        fn lessThan(_: void, a: App, b: App) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return apps.toOwnedSlice(gpa);
}

/// "stardust-demo" is shown as "Demo".
pub fn label(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const prefix = "stardust-";
    const base = if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) name[prefix.len..] else name;
    const out = try gpa.dupe(u8, base);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub const Dock = struct {
    font: ?font.Font,
    cache: font.GlyphCache,
    pixels: []u32,
    width: u32,
    height: u32,
    scale: f32,
    apps: []App,
    /// The app under the pointer.
    hover: ?usize = null,

    pub fn init(gpa: std.mem.Allocator, f: ?font.Font, apps: []App, screen_width: u32, screen_height: u32) !Dock {
        const scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        const height: u32 = @intFromFloat(@round(76 * scale));
        return .{
            .font = f,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, @as(usize, screen_width) * height),
            .width = screen_width,
            .height = height,
            .scale = scale,
            .apps = apps,
        };
    }

    /// Where app `i`'s icon is, in the dock: the icons are in a row in the
    /// middle.
    pub fn iconRect(d: *const Dock, i: usize) struct { x: f32, y: f32, size: f32 } {
        const size = 56 * d.scale;
        const gap = 20 * d.scale;
        const n: f32 = @floatFromInt(d.apps.len);
        const row = n * size + (n - 1) * gap;
        const x0 = (@as(f32, @floatFromInt(d.width)) - row) / 2;
        return .{ .x = x0 + @as(f32, @floatFromInt(i)) * (size + gap), .y = 6 * d.scale, .size = size };
    }

    /// The app whose icon is at (`x`, `y`) in the dock.
    pub fn hit(d: *const Dock, x: f64, y: f64) ?usize {
        for (0..d.apps.len) |i| {
            const r = d.iconRect(i);
            if (x >= r.x and x < r.x + r.size and y >= r.y and y < r.y + r.size) return i;
        }
        return null;
    }

    pub fn draw(d: *Dock) void {
        const canvas: font.Canvas = .{ .pixels = d.pixels, .width = d.width, .height = d.height, .stride = d.width };
        canvas.fill(0, 0, d.width, d.height, background);
        for (d.apps, 0..) |*app, i| {
            const r = d.iconRect(i);
            if (d.hover == i) {
                const pad = 4 * d.scale;
                roundedRect(canvas, r.x - pad, r.y - pad, r.size + 2 * pad, r.size + 2 * pad, 14 * d.scale, hover_background);
            }
            roundedRect(canvas, r.x, r.y, r.size, r.size, 12 * d.scale, app.color());
            if (d.font) |*f| {
                const style: font.Style = .{ .font = f, .size = 30 * d.scale, .color = 0xffffffff };
                const initial = app.label[0..1];
                const baseline = r.y + r.size / 2 + style.ascent() * 0.36;
                _ = font.draw(canvas, &d.cache, style, r.x + (r.size - font.measure(style, initial)) / 2, baseline, initial) catch {};
            }
            if (app.pid != null) {
                const dot = 6 * d.scale;
                roundedRect(canvas, r.x + (r.size - dot) / 2, r.y + r.size + 3 * d.scale, dot, dot, dot / 2, dot_color);
            }
        }
    }

    /// Moves the hover highlight for the pointer at (`x`, `y`) in the dock
    /// (null: elsewhere). Returns whether it changed.
    pub fn pointerAt(d: *Dock, x: ?f64, y: f64) bool {
        const under = if (x) |px| d.hit(px, y) else null;
        if (under == d.hover) return false;
        d.hover = under;
        return true;
    }
};

/// Fills a rectangle with rounded corners, anti-aliased.
pub fn roundedRect(c: font.Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: u32) void {
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(x), 0, @as(f32, @floatFromInt(c.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(y), 0, @as(f32, @floatFromInt(c.height))));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(x + w), 0, @as(f32, @floatFromInt(c.width))));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(y + h), 0, @as(f32, @floatFromInt(c.height))));
    const cx = x + w / 2;
    const cy = y + h / 2;
    const r = @min(radius, @min(w, h) / 2);
    for (y0..y1) |py| for (x0..x1) |px| {
        // Distance from the pixel's centre to the shape's edge.
        const qx = @abs(@as(f32, @floatFromInt(px)) + 0.5 - cx) - (w / 2 - r);
        const qy = @abs(@as(f32, @floatFromInt(py)) + 0.5 - cy) - (h / 2 - r);
        const outside = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
        const coverage = std.math.clamp(0.5 - outside, 0, 1);
        if (coverage <= 0) continue;
        const p = &c.pixels[py * c.stride + px];
        p.* = font.text.blend(p.*, color, @intFromFloat(@round(coverage * 255)));
    };
}

const testing = std.testing;

test "app labels drop the stardust- prefix" {
    const a = testing.allocator;
    const l = try label(a, "stardust-demo");
    defer a.free(l);
    try testing.expectEqualStrings("Demo", l);
    const m = try label(a, "notes");
    defer a.free(m);
    try testing.expectEqualStrings("Notes", m);
}

test "icons are in a row in the middle, and clicks find them" {
    var apps = [_]App{
        .{ .name = "a", .label = "A", .path = "/apps/a/a" },
        .{ .name = "b", .label = "B", .path = "/apps/b/b" },
    };
    var d = try Dock.init(testing.allocator, null, &apps, 1920, 1080);
    defer testing.allocator.free(d.pixels);
    defer d.cache.deinit();
    try testing.expectEqual(@as(u32, 76), d.height);
    const r0 = d.iconRect(0);
    const r1 = d.iconRect(1);
    try testing.expectApproxEqAbs(@as(f32, 1920) - (r1.x + r1.size), r0.x, 0.01);
    try testing.expectEqual(@as(?usize, 0), d.hit(r0.x + 1, r0.y + 1));
    try testing.expectEqual(@as(?usize, 1), d.hit(r1.x + r1.size - 1, r1.y + r1.size - 1));
    try testing.expectEqual(@as(?usize, null), d.hit(r0.x + r0.size + 1, r0.y + 1));
    try testing.expectEqual(@as(?usize, null), d.hit(0, 0));

    // Hovering changes the picture; a running app gets a dot.
    try testing.expect(d.pointerAt(r1.x + 1, r1.y + 1));
    try testing.expect(!d.pointerAt(r1.x + 2, r1.y + 2));
    apps[0].pid = 42;
    d.draw();
    const at = struct {
        fn f(dock: *const Dock, x: f32, y: f32) u32 {
            return dock.pixels[@as(usize, @intFromFloat(y)) * dock.width + @as(usize, @intFromFloat(x))];
        }
    }.f;
    try testing.expectEqual(@as(u32, background), at(&d, 5, 5));
    try testing.expectEqual(apps[0].color(), at(&d, r0.x + r0.size / 2, r0.y + 4));
    try testing.expectEqual(@as(u32, dot_color), at(&d, r0.x + r0.size / 2, r0.y + r0.size + 6));
    try testing.expectEqual(@as(u32, background), at(&d, r1.x + r1.size / 2, r1.y + r1.size + 6));
    try testing.expectEqual(@as(u32, hover_background), at(&d, r1.x - 2, r1.y + r1.size / 2));
}

test "apps are the directories holding a program of the same name" {
    const a = testing.allocator;
    var tmp_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&tmp_buf, "/tmp/stardust-dock-test-{d}", .{linux.getpid()});
    defer {
        var b: [128]u8 = undefined;
        for ([_][]const u8{ "/zeta/zeta", "/alpha/alpha", "/zeta", "/alpha", "/notes", "" }) |p| {
            const path = std.fmt.bufPrintZ(&b, "{s}{s}", .{ root, p }) catch unreachable;
            if (linux.errno(linux.unlink(path)) != .SUCCESS) _ = linux.rmdir(path);
        }
    }
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdir(root, 0o755)));
    var b: [128]u8 = undefined;
    for ([_][]const u8{ "zeta", "alpha", "notes" }) |name| {
        _ = linux.mkdir(try std.fmt.bufPrintZ(&b, "{s}/{s}", .{ root, name }), 0o755);
    }
    // Programs for two of them; "notes" has none.
    for ([_][]const u8{ "zeta", "alpha" }) |name| {
        const fd = try sys.open(try std.fmt.bufPrintZ(&b, "{s}/{s}/{s}", .{ root, name, name }), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        _ = linux.fchmod(fd, 0o755);
        sys.close(fd);
    }
    const apps = try findApps(a, root);
    defer {
        for (apps) |app| {
            a.free(app.name);
            a.free(app.label);
            a.free(app.path);
        }
        a.free(apps);
    }
    try testing.expectEqual(@as(usize, 2), apps.len);
    try testing.expectEqualStrings("alpha", apps[0].name);
    try testing.expectEqualStrings("Zeta", apps[1].label);
    try testing.expect(std.mem.endsWith(u8, apps[1].path, "/zeta/zeta"));
    try testing.expectEqual(@as(usize, 0), (try findApps(a, "/nonexistent")).len);
}
