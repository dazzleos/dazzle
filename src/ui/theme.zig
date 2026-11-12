//! Theme: a Material 3 colour scheme (the baseline light and dark ones),
//! text sizes, and persistent appearance settings (`/data/apps/.appearance`).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const gfx = @import("gfx");

const Color = gfx.Color;

/// Where the chosen appearance settings are kept (writable by Settings and
/// readable by all apps and the shell).
pub const settings_file = sys.system.apps_dir ++ "/.appearance";

/// Whether the system uses the dark or light Material 3 colour scheme.
pub const Mode = enum {
    dark,
    light,

    pub fn name(m: Mode) []const u8 {
        return switch (m) {
            .dark => "Dark",
            .light => "Light",
        };
    }

    pub fn code(m: Mode) []const u8 {
        return @tagName(m);
    }

    pub fn fromCode(text: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, text);
    }

    pub fn scheme(m: Mode) Theme {
        return switch (m) {
            .dark => .dark,
            .light => .light,
        };
    }
};

/// The colour of the desktop behind the windows: the same in either
/// theme, and dark, so the windows and the dock stand out on it.
pub const Background = enum {
    navy,
    teal,
    green,
    olive,
    brown,
    maroon,
    plum,
    black,

    pub fn name(bg: Background) []const u8 {
        return switch (bg) {
            .navy => "Navy",
            .teal => "Teal",
            .green => "Green",
            .olive => "Olive",
            .brown => "Brown",
            .maroon => "Maroon",
            .plum => "Plum",
            .black => "Black",
        };
    }

    pub fn code(bg: Background) []const u8 {
        return @tagName(bg);
    }

    pub fn fromCode(text: []const u8) ?Background {
        return std.meta.stringToEnum(Background, text);
    }

    /// 0xAARRGGBB.
    pub fn argb(bg: Background) u32 {
        return switch (bg) {
            .navy => 0xff101830,
            .teal => 0xff0e2a2c,
            .green => 0xff12261c,
            .olive => 0xff262612,
            .brown => 0xff2a1c12,
            .maroon => 0xff2c1216,
            .plum => 0xff241628,
            .black => 0xff000000,
        };
    }
};

/// Persistent appearance settings stored in `settings_file`.
pub const Settings = struct {
    theme: Mode = .dark,
    background: Background = .navy,

    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = tok.next() orelse continue;
            const val = tok.next() orelse continue;
            if (std.mem.eql(u8, key, "theme")) {
                if (Mode.fromCode(val)) |m| s.theme = m;
            } else if (std.mem.eql(u8, key, "background")) {
                if (Background.fromCode(val)) |bg| s.background = bg;
            }
        }
        return s;
    }

    pub fn formatBuf(s: Settings, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "theme {s}\nbackground {s}\n", .{ s.theme.code(), s.background.code() }) catch "";
    }
};

pub fn loadSettings() Settings {
    return loadSettingsFrom(settings_file);
}

pub fn loadSettingsFrom(path: [:0]const u8) Settings {
    var buf: [128]u8 = undefined;
    const text = sys.readFile(path, &buf) orelse return .{};
    return Settings.parse(text);
}

pub fn saveSettings(s: Settings) void {
    _ = linux.mkdir(sys.system.apps_dir, 0o755);
    saveSettingsTo(settings_file, s);
}

pub fn saveSettingsTo(path: [:0]const u8, s: Settings) void {
    var buf: [128]u8 = undefined;
    const content = s.formatBuf(&buf);
    if (content.len == 0) return;
    _ = linux.unlink(path);
    sys.files.writeNew(path, content) catch {};
}

/// Notices `path` (defaulting to `settings_file`) being created, replaced, or
/// modified.
pub const Watch = struct {
    path: [*:0]const u8 = settings_file,
    stamp: ?[5]u64 = null,
    initialized: bool = false,

    /// Whether `path` changed since the last call (false on the first call).
    pub fn changed(w: *Watch) bool {
        var stx: linux.Statx = undefined;
        const mask: linux.STATX = .{ .INO = true, .MTIME = true };
        const now: ?[5]u64 = if (linux.errno(linux.statx(linux.AT.FDCWD, w.path, 0, mask, &stx)) == .SUCCESS)
            .{ stx.dev_major, stx.dev_minor, stx.ino, @bitCast(stx.mtime.sec), stx.mtime.nsec }
        else
            null;
        defer {
            w.stamp = now;
            w.initialized = true;
        }
        if (!w.initialized) return false;
        if (w.stamp == null and now == null) return false;
        const before = w.stamp orelse return true;
        const after = now orelse return true;
        return !std.mem.eql(u64, &before, &after);
    }
};

/// A Material 3 colour scheme, and text sizes in pixels.
pub const Theme = struct {
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    secondary_container: Color,
    surface: Color,
    surface_container: Color,
    surface_container_highest: Color,
    on_surface: Color,
    on_surface_variant: Color,
    outline: Color,
    outline_variant: Color,
    @"error": Color,
    /// The colours of code's parts (see `Highlight`).
    syntax: Syntax,
    body_size: f32 = 14,
    label_size: f32 = 14,
    title_size: f32 = 22,

    /// The baseline light scheme.
    pub const light: Theme = .{
        .primary = .rgb(0x6750a4),
        .on_primary = .rgb(0xffffff),
        .primary_container = .rgb(0xeaddff),
        .on_primary_container = .rgb(0x21005d),
        .secondary_container = .rgb(0xe8def8),
        .surface = .rgb(0xfef7ff),
        .surface_container = .rgb(0xf3edf7),
        .surface_container_highest = .rgb(0xe6e0e9),
        .on_surface = .rgb(0x1d1b20),
        .on_surface_variant = .rgb(0x49454f),
        .outline = .rgb(0x79747e),
        .outline_variant = .rgb(0xcac4d0),
        .@"error" = .rgb(0xb3261e),
        .syntax = .{
            .keyword = .rgb(0x8e24aa),
            .type = .rgb(0x00796b),
            .function = .rgb(0x1565c0),
            .builtin = .rgb(0xad1457),
            .string = .rgb(0x2e7d32),
            .number = .rgb(0xc65400),
            .constant = .rgb(0xc65400),
            .property = .rgb(0x1565c0),
            .comment = .rgb(0x79747e),
        },
    };

    /// The baseline dark scheme.
    pub const dark: Theme = .{
        .primary = .rgb(0xd0bcff),
        .on_primary = .rgb(0x381e72),
        .primary_container = .rgb(0x4f378b),
        .on_primary_container = .rgb(0xeaddff),
        .secondary_container = .rgb(0x4a4458),
        .surface = .rgb(0x141218),
        .surface_container = .rgb(0x211f26),
        .surface_container_highest = .rgb(0x36343b),
        .on_surface = .rgb(0xe6e0e9),
        .on_surface_variant = .rgb(0xcac4d0),
        .outline = .rgb(0x938f99),
        .outline_variant = .rgb(0x49454f),
        .@"error" = .rgb(0xf2b8b5),
        .syntax = .{
            .keyword = .rgb(0xd0a8ff),
            .type = .rgb(0x80cbc4),
            .function = .rgb(0x90caf9),
            .builtin = .rgb(0xf48fb1),
            .string = .rgb(0xa5d6a7),
            .number = .rgb(0xffb74d),
            .constant = .rgb(0xffb74d),
            .property = .rgb(0x90caf9),
            .comment = .rgb(0x938f99),
        },
    };
};

/// What a piece of code is, for its colour (plain text is `on_surface`).
pub const Highlight = enum(u8) {
    plain,
    keyword,
    type,
    function,
    /// Built into the language: Zig's @functions, Python's print and len.
    builtin,
    string,
    number,
    /// true, false, null and the like.
    constant,
    /// A JSON object's names.
    property,
    comment,
};

/// The colours of code, by what it is.
pub const Syntax = struct {
    keyword: Color,
    type: Color,
    function: Color,
    builtin: Color,
    string: Color,
    number: Color,
    constant: Color,
    property: Color,
    comment: Color,

    pub fn color(s: *const Syntax, h: Highlight, plain: Color) Color {
        return switch (h) {
            .plain => plain,
            inline else => |tag| @field(s, @tagName(tag)),
        };
    }
};

const testing = std.testing;

test "appearance settings parse, format, save and load" {
    try testing.expectEqual(Mode.dark, Settings.parse("").theme);
    try testing.expectEqual(Mode.light, Settings.parse("theme light\n").theme);
    try testing.expectEqual(Mode.dark, Settings.parse("theme dark\n").theme);
    try testing.expectEqual(Mode.dark, Settings.parse("theme invalid\n").theme);

    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-appearance-test-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);

    var watch: Watch = .{ .path = path };
    try testing.expect(!watch.changed());
    try testing.expectEqual(Mode.dark, loadSettingsFrom(path).theme);

    saveSettingsTo(path, .{ .theme = .light });
    try testing.expect(watch.changed());
    try testing.expect(!watch.changed());
    try testing.expectEqual(Mode.light, loadSettingsFrom(path).theme);

    sys.sleepMs(20);
    saveSettingsTo(path, .{ .theme = .dark });
    try testing.expect(watch.changed());
    try testing.expectEqual(Mode.dark, loadSettingsFrom(path).theme);
}

test "the appearance settings keep the theme and the background" {
    const s: Settings = .{ .theme = .light, .background = .plum };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(s, Settings.parse(s.formatBuf(&buf)));
    // Written before there was a choice of background.
    try std.testing.expectEqual(Settings{ .theme = .light, .background = .navy }, Settings.parse("theme light\n"));
    // A colour no longer offered (grey was) is the default.
    try std.testing.expectEqual(Settings{ .theme = .light, .background = .navy }, Settings.parse("theme light\nbackground grey\n"));
}
