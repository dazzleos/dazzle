//! The system's appearance, as chosen in Settings: the dark or light
//! theme, and the desktop's background: one of the photos built into the
//! system (`backgrounds`; the forest to start with), or an image chosen in
//! Files. Kept in `settings_file`, which Settings and
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
    /// The image filling the screen behind the windows: a built-in one
    /// (`backgrounds`), or a PNG.
    image: ImagePath = default_image,
    /// The last picture chosen in Files: Settings offers it beside the
    /// built-in ones (while its file is there), whichever is shown.
    custom: ImagePath = .{},

    pub const default_image: ImagePath = .of(backgrounds.path(backgrounds.all[0]));

    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = tok.next() orelse continue;
            const val = tok.next() orelse continue;
            if (std.mem.eql(u8, key, "theme")) {
                if (Mode.fromCode(val)) |m| s.theme = m;
            } else if (std.mem.eql(u8, key, "image") or std.mem.eql(u8, key, "custom")) {
                // The rest of the line: a path may have spaces.
                const start = @intFromPtr(val.ptr) - @intFromPtr(line.ptr);
                const path: ImagePath = .of(std.mem.trimEnd(u8, line[start..], " \t\r"));
                if (key[0] == 'i') s.image = path else s.custom = path;
            }
        }
        // Written before the last picture from Files was kept apart: the
        // one shown, if it is one.
        if (s.custom.slice() == null) if (s.image.slice()) |p| if (backgrounds.find(p) == null) {
            s.custom = s.image;
        };
        return s;
    }

    /// Shows `path`, a picture chosen in Files, and keeps it as the one
    /// Settings offers.
    pub fn chooseCustom(s: *Settings, path: []const u8) void {
        s.image = .of(path);
        s.custom = s.image;
    }

    pub fn formatBuf(s: Settings, buf: []u8) []const u8 {
        const head = std.fmt.bufPrint(buf, "theme {s}\n", .{s.theme.code()}) catch return "";
        var len = head.len;
        if (s.image.slice()) |path| len += (std.fmt.bufPrint(buf[len..], "image {s}\n", .{path}) catch return "").len;
        if (s.custom.slice()) |path| len += (std.fmt.bufPrint(buf[len..], "custom {s}\n", .{path}) catch return "").len;
        return buf[0..len];
    }

    /// The most `formatBuf` writes.
    pub const max_text = 64 + 2 * ImagePath.max_len;
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
    const sea: Settings = .{ .theme = .dark, .image = .of(backgrounds.path(backgrounds.all[1])) };
    saveSettingsTo(path, sea);
    try testing.expectEqual(sea, loadSettingsFrom(path));
}

test "the forest is the background to start with, and before there was a choice of photos" {
    try testing.expectEqualStrings("/os/backgrounds/forest.etc1", Settings.parse("").image.slice().?);
    // Written when the background was a colour: the colour is forgotten.
    const old = Settings.parse("theme light\nbackground teal\n");
    try testing.expectEqual(Mode.light, old.theme);
    try testing.expectEqualStrings("/os/backgrounds/forest.etc1", old.image.slice().?);
}

test "the last picture chosen in Files is kept while a built-in one shows" {
    var s: Settings = .{};
    s.chooseCustom("/data/user/sea.png");
    s.image = .of(backgrounds.path(backgrounds.all[0]));
    var buf: [Settings.max_text]u8 = undefined;
    const text = s.formatBuf(&buf);
    try testing.expectEqualStrings("theme dark\nimage /os/backgrounds/forest.etc1\ncustom /data/user/sea.png\n", text);
    try testing.expectEqual(s, Settings.parse(text));
    // Written before it was kept apart: the picture shown is it.
    try testing.expectEqualStrings("/data/user/old.png", Settings.parse("theme dark\nimage /data/user/old.png\n").custom.slice().?);
    try testing.expect(Settings.parse("theme dark\nimage /os/backgrounds/forest.etc1\n").custom.slice() == null);
}

test "the background image is kept, with spaces in its path" {
    var s: Settings = .{};
    s.chooseCustom("/data/user/My Pictures/sea.png");
    var buf: [Settings.max_text]u8 = undefined;
    const text = s.formatBuf(&buf);
    try std.testing.expectEqualStrings("theme dark\nimage /data/user/My Pictures/sea.png\ncustom /data/user/My Pictures/sea.png\n", text);
    const back = Settings.parse(text);
    try std.testing.expectEqual(s, back);
    try std.testing.expectEqualStrings("/data/user/My Pictures/sea.png", back.image.slice().?);
}
