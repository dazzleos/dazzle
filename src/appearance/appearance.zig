//! The system's appearance, as chosen in Settings: the dark or light
//! theme, and the desktop's background: a colour, and perhaps an image
//! over it (chosen in Files). Kept in `settings_file`, which Settings and
//! Files write and the shell and the apps read (and watch).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

/// The backgrounds built into the system.
pub const backgrounds = @import("backgrounds.zig");

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

/// An image file's path, kept in the settings (a value, so they can be
/// copied and compared).
pub const ImagePath = struct {
    buf: [max_len]u8 = @splat(0),
    len: u16 = 0,

    pub const max_len = 256;

    /// `path`, or none if it is empty (or too long to keep).
    pub fn of(path: []const u8) ImagePath {
        var p: ImagePath = .{};
        if (path.len == 0 or path.len > max_len) return p;
        @memcpy(p.buf[0..path.len], path);
        p.len = @intCast(path.len);
        return p;
    }

    pub fn slice(p: *const ImagePath) ?[]const u8 {
        return if (p.len == 0) null else p.buf[0..p.len];
    }
};

/// Persistent appearance settings stored in `settings_file`.
pub const Settings = struct {
    theme: Mode = .dark,
    background: Background = .navy,
    /// An image to show over the background colour, filling the screen,
    /// if any: a PNG, or a built-in one (`backgrounds`).
    image: ImagePath = .{},

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
            } else if (std.mem.eql(u8, key, "image")) {
                // The rest of the line: a path may have spaces.
                const start = @intFromPtr(val.ptr) - @intFromPtr(line.ptr);
                s.image = .of(std.mem.trimEnd(u8, line[start..], " \t\r"));
            }
        }
        return s;
    }

    pub fn formatBuf(s: Settings, buf: []u8) []const u8 {
        const head = std.fmt.bufPrint(buf, "theme {s}\nbackground {s}\n", .{ s.theme.code(), s.background.code() }) catch return "";
        const path = s.image.slice() orelse return head;
        const tail = std.fmt.bufPrint(buf[head.len..], "image {s}\n", .{path}) catch return "";
        return buf[0 .. head.len + tail.len];
    }

    /// The most `formatBuf` writes.
    pub const max_text = 64 + ImagePath.max_len;
};

pub fn loadSettings() Settings {
    return loadSettingsFrom(settings_file);
}

pub fn loadSettingsFrom(path: [:0]const u8) Settings {
    var buf: [Settings.max_text]u8 = undefined;
    const text = sys.readFile(path, &buf) orelse return .{};
    return Settings.parse(text);
}

pub fn saveSettings(s: Settings) void {
    _ = linux.mkdir(sys.system.apps_dir, 0o755);
    saveSettingsTo(settings_file, s);
}

pub fn saveSettingsTo(path: [:0]const u8, s: Settings) void {
    var buf: [Settings.max_text]u8 = undefined;
    const content = s.formatBuf(&buf);
    if (content.len == 0) return;
    _ = linux.unlink(path);
    sys.files.writeNew(path, content) catch {};
}

const testing = std.testing;

test "appearance settings parse, format, save and load" {
    try testing.expectEqual(Mode.dark, Settings.parse("").theme);
    try testing.expectEqual(Mode.light, Settings.parse("theme light\n").theme);
    try testing.expectEqual(Mode.dark, Settings.parse("theme dark\n").theme);
    try testing.expectEqual(Mode.dark, Settings.parse("theme invalid\n").theme);

    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-appearance-test-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);

    try testing.expectEqual(Mode.dark, loadSettingsFrom(path).theme);
    saveSettingsTo(path, .{ .theme = .light });
    try testing.expectEqual(Mode.light, loadSettingsFrom(path).theme);
    saveSettingsTo(path, .{ .theme = .dark, .background = .teal });
    try testing.expectEqual(Settings{ .theme = .dark, .background = .teal }, loadSettingsFrom(path));
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

test "an image over the background is kept, with spaces in its path" {
    const s: Settings = .{ .theme = .dark, .background = .teal, .image = .of("/data/user/My Pictures/sea.png") };
    var buf: [Settings.max_text]u8 = undefined;
    const text = s.formatBuf(&buf);
    try std.testing.expectEqualStrings("theme dark\nbackground teal\nimage /data/user/My Pictures/sea.png\n", text);
    const back = Settings.parse(text);
    try std.testing.expectEqual(s, back);
    try std.testing.expectEqualStrings("/data/user/My Pictures/sea.png", back.image.slice().?);
    // None: no line for it.
    try std.testing.expect(Settings.parse("theme dark\n").image.slice() == null);
}
