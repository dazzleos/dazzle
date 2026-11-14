//! Remote control: while it is turned on (in Settings: off unless asked
//! for), the shell takes requests over HTTP from other computers on the
//! network to move the pointer, click, type, launch apps and take
//! screenshots, for testing Dazzle from another computer. Each request
//! must carry the code Settings shows (a new one each time it is turned
//! on). Kept in `settings_file`: "code 123456\n" while on, "off\n" when
//! not; Settings writes it and the shell watches it.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const settings_file = sys.system.apps_dir ++ "/.remote";

/// The port the shell listens on.
pub const port = 8080;

/// The code requests must carry, while it is on.
pub const Setting = struct {
    code: ?u32 = null,

    pub fn parse(text: []const u8) Setting {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            if (!std.mem.eql(u8, tok.next() orelse continue, "code")) continue;
            const code = std.fmt.parseInt(u32, tok.next() orelse continue, 10) catch continue;
            if (code >= 100000 and code <= 999999) return .{ .code = code };
        }
        return .{};
    }

    pub fn format(s: Setting, buf: []u8) []const u8 {
        const code = s.code orelse return "off\n";
        return std.fmt.bufPrint(buf, "code {d}\n", .{code}) catch "off\n";
    }

    /// On, with a new code chosen at random.
    pub fn fresh() Setting {
        var bytes: [4]u8 = undefined;
        var at: usize = 0;
        while (at < bytes.len) {
            const rc = linux.getrandom(bytes[at..].ptr, bytes.len - at, 0);
            if (linux.errno(rc) == .SUCCESS) at += rc;
        }
        return .{ .code = 100000 + std.mem.readInt(u32, &bytes, .little) % 900000 };
    }
};

pub fn load() Setting {
    var buf: [64]u8 = undefined;
    return .parse(sys.readFile(settings_file, &buf) orelse return .{});
}

pub fn save(s: Setting) void {
    var buf: [32]u8 = undefined;
    _ = linux.unlink(settings_file);
    sys.files.writeNew(settings_file, s.format(&buf)) catch {};
}

test "the setting says the code while on, and off otherwise" {
    var buf: [32]u8 = undefined;
    const on: Setting = .{ .code = 482913 };
    try std.testing.expectEqualStrings("code 482913\n", on.format(&buf));
    try std.testing.expectEqual(on, Setting.parse(on.format(&buf)));
    try std.testing.expectEqual(Setting{}, Setting.parse("off\n"));
    try std.testing.expectEqual(Setting{}, Setting.parse("code 12\n"));
    const f = Setting.fresh();
    try std.testing.expect(f.code.? >= 100000 and f.code.? <= 999999);
}
