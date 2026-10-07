//! The dock along the bottom of the screen: an icon for each app in /apps,
//! and for the shell's own (Settings). Clicking one starts the app or, if it
//! is running, brings its window to the front (apps run once each).
//!
//! An app is a directory /apps/<name> holding its program, also called
//! <name>, and the files it needs. The shell's own apps are programs beside
//! it in /os/shell, and cannot be removed. Its icon is a Material icon
//! (named in <program>.icon, beside the program: "folder") or, without
//! one, its initial, on a coloured square, with a dot under it while it
//! runs.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const font = @import("font");
const icons = @import("icons");

pub const apps_dir = "/apps";

const background = 0xff1c2a4a;
const hover_background = 0xff2c3e66;
const dot_color = 0xffe8eefc;
/// Icon colours, picked by the app's name.
const palette = [_]u32{ 0xff3f7ee8, 0xffe8743f, 0xff3fb86e, 0xffb04fd6, 0xffe8b33f, 0xff3fb8c4, 0xffe84f6a };

pub const App = struct {
    /// Its directory's name, and its program's.
    name: []const u8,
    /// The name shown: without a "dazzle-" prefix, capitalised.
    label: []const u8,
    /// The program: /apps/<name>/<name>.
    path: [:0]const u8,
    /// Its icon, from <program>.icon.
    icon: ?icons.Icon = null,
    /// Its process, while it runs.
    pid: ?linux.pid_t = null,

    fn color(a: *const App) u32 {
        return palette[std.hash.Fnv1a_32.hash(a.name) % palette.len];
    }
};

/// The apps in `dir` (its directories that hold a program of the same
/// name) and the programs `builtin` (paths, those that are there), sorted
/// by name.
pub fn findApps(gpa: std.mem.Allocator, dir_path: []const u8, builtin: []const []const u8) ![]App {
    var apps: std.ArrayList(App) = .empty;
    errdefer apps.deinit(gpa);
    for (builtin) |p| {
        const path = try gpa.dupeZ(u8, p);
        if (linux.errno(linux.access(path, linux.X_OK)) != .SUCCESS) {
            gpa.free(path);
            continue;
        }
        const owned = try gpa.dupe(u8, std.fs.path.basename(p));
        try apps.append(gpa, .{ .name = owned, .label = try label(gpa, owned), .path = path, .icon = iconOf(path) });
    }
    var path_buf: [256]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{dir_path});
    if (sys.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true })) |dir| {
        defer sys.close(dir);
        try addDir(gpa, &apps, dir, dir_path);
    } else |_| {}
    std.mem.sort(App, apps.items, {}, struct {
        fn lessThan(_: void, a: App, b: App) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return apps.toOwnedSlice(gpa);
}

fn addDir(gpa: std.mem.Allocator, apps: *std.ArrayList(App), dir: linux.fd_t, dir_path: []const u8) !void {
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
            try apps.append(gpa, .{ .name = owned, .label = try label(gpa, owned), .path = path, .icon = iconOf(path) });
        }
    }
}

/// The icon named in `<program>.icon`, if there is one Dazzle has.
fn iconOf(program: []const u8) ?icons.Icon {
    var path_buf: [300]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}.icon", .{program}) catch return null;
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return null;
    defer sys.close(fd);
    var buf: [64]u8 = undefined;
    const n = sys.check(linux.read(fd, &buf, buf.len)) catch return null;
    return icons.fromName(buf[0..n]);
}

/// "dazzle-demo" is shown as "Demo".
pub fn label(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const prefix = "dazzle-";
    const base = if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) name[prefix.len..] else name;
    const out = try gpa.dupe(u8, base);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub const Dock = struct {
    font: ?font.Font,
    icon_font: ?font.Font,
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
            .icon_font = font.Font.init(icons.font_data) catch null,
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
            const icon_font: ?*const font.Font = if (d.icon_font) |*f| f else null;
            if (app.icon != null and icon_font != null) {
                // Icons fill the em square, with the baseline at the bottom.
                const size = @round(36 * d.scale);
                const style: font.Style = .{ .font = icon_font.?, .size = size, .color = 0xffffffff };
                var buf: [4]u8 = undefined;
                const x = @round(r.x + (r.size - size) / 2);
                const y = @round(r.y + (r.size - size) / 2);
                _ = font.draw(canvas, &d.cache, style, x, y + size, icons.text(app.icon.?, &buf)) catch {};
            } else if (d.font) |*f| {
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
fn roundedRect(c: font.Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: u32) void {
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

test "app labels drop the dazzle- prefix" {
    const a = testing.allocator;
    const l = try label(a, "dazzle-demo");
    defer a.free(l);
    try testing.expectEqualStrings("Demo", l);
    const m = try label(a, "notes");
    defer a.free(m);
    try testing.expectEqualStrings("Notes", m);
}

test "icons are in a row in the middle, and clicks find them" {
    var apps = [_]App{
        .{ .name = "a", .label = "A", .path = "/apps/a/a", .icon = .folder },
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
    // The first app's icon is drawn in white in the middle of its square.
    try testing.expectEqual(@as(u32, 0xffffffff), at(&d, r0.x + r0.size / 2, r0.y + r0.size / 2));
}

test "apps are the directories holding a program of the same name" {
    const a = testing.allocator;
    var tmp_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&tmp_buf, "/tmp/dazzle-dock-test-{d}", .{linux.getpid()});
    defer {
        var b: [128]u8 = undefined;
        for ([_][]const u8{ "/zeta/zeta", "/alpha/alpha", "/alpha/alpha.icon", "/zeta", "/alpha", "/notes", "" }) |p| {
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
    // Alpha's icon is named beside it.
    {
        const fd = try sys.open(try std.fmt.bufPrintZ(&b, "{s}/alpha/alpha.icon", .{root}), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        _ = linux.fchmod(fd, 0o644);
        _ = linux.write(fd, "folder\n", 7);
        sys.close(fd);
    }
    // And a program of the shell's own (one that is not there is left out).
    var own_buf: [128]u8 = undefined;
    const own = try std.fmt.bufPrint(&own_buf, "{s}/zeta/zeta", .{root});
    const apps = try findApps(a, root, &.{ own, "/nonexistent/beta" });
    defer {
        for (apps) |app| {
            a.free(app.name);
            a.free(app.label);
            a.free(app.path);
        }
        a.free(apps);
    }
    try testing.expectEqual(@as(usize, 3), apps.len);
    try testing.expectEqualStrings("alpha", apps[0].name);
    try testing.expectEqual(@as(?icons.Icon, .folder), apps[0].icon);
    try testing.expectEqual(@as(?icons.Icon, null), apps[2].icon);
    try testing.expectEqualStrings("Zeta", apps[1].label);
    try testing.expectEqualStrings("zeta", apps[2].name);
    try testing.expect(std.mem.endsWith(u8, apps[1].path, "/zeta/zeta"));
    try testing.expectEqual(@as(usize, 0), (try findApps(a, "/nonexistent", &.{})).len);
}
