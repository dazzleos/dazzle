//! Remote control: while it is turned on (in Settings: off unless asked
//! for), the shell takes requests over HTTP from other computers on the
//! network to move the pointer, click, type, launch apps and take
//! screenshots, for testing Dazzle from another computer. Each request
//! must carry the code Settings shows (a new one each time it is turned
//! on). Kept in `settings_file`: "code 123456\n" while on, "off\n" when
//! not; Settings writes it and the shell watches it. `cmdline_key` on the
//! kernel's command line ("dazzle.remote=123456", put in a slot's
//! cmdline.txt with the card in another computer) has it on with that code
//! whatever Settings says: before setup has finished too, for trying
//! Dazzle on a board with no screen working yet.

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

pub const cmdline_key = "dazzle.remote=";

pub fn load() Setting {
    if (forced()) |s| return s;
    var buf: [64]u8 = undefined;
    return .parse(sys.readFile(settings_file, &buf) orelse return .{});
}

/// The code on the kernel's command line (`cmdline_key`), if there is one.
pub fn forced() ?Setting {
    var buf: [1024]u8 = undefined;
    return fromCmdline(sys.readFile("/proc/cmdline", &buf) orelse return null);
}

fn fromCmdline(cmdline: []const u8) ?Setting {
    var words = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (words.next()) |w| if (std.mem.startsWith(u8, w, cmdline_key)) {
        var line: [32]u8 = undefined;
        const s = Setting.parse(std.fmt.bufPrint(&line, "code {s}", .{w[cmdline_key.len..]}) catch return null);
        return if (s.code != null) s else null;
    };
    return null;
}

test "a code on the kernel's command line" {
    try std.testing.expectEqual(@as(?u32, 408938), fromCmdline("cma=128M dazzle.remote=408938 dazzle.slot=a\n").?.code);
    try std.testing.expect(fromCmdline("cma=128M dazzle.slot=a") == null);
    try std.testing.expect(fromCmdline("dazzle.remote=12") == null);
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
