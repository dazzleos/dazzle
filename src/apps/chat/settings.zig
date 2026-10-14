//! The name Chat goes by, as chosen in its settings: kept in the user's
//! files (`name_file`). Until one is chosen (or when it is cleared, or set
//! back to the computer's name) it is the computer's name, so it follows
//! that if it changes.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const protocol = @import("protocol.zig");

pub const name_file = "/data/user/.chat-name";

/// The computer's name (the kernel's, set from the name chosen when the
/// system was set up).
pub fn hostname(buf: *[64]u8) []const u8 {
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return "dazzle";
    const n = std.mem.indexOfScalar(u8, &uts.nodename, 0) orelse uts.nodename.len;
    if (n == 0) return "dazzle";
    const len = @min(n, buf.len);
    @memcpy(buf[0..len], uts.nodename[0..len]);
    return buf[0..len];
}

/// The name chosen, or `default` if none was.
pub fn loadName(path: [:0]const u8, buf: []u8, default: []const u8) []const u8 {
    const text = sys.readFile(path, buf) orelse return default;
    const name = std.mem.trim(u8, text, " \t\r\n");
    return if (name.len == 0) default else name;
}

/// Keeps `name` as the one chosen; an empty name, or `default`, is no
/// choice (the file goes). Returns the name now gone by.
pub fn saveName(path: [:0]const u8, name: []const u8, default: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t");
    const chosen = protocol.Name.init(trimmed);
    _ = linux.unlink(path);
    if (chosen.len == 0 or std.mem.eql(u8, chosen.get(), default)) return default;
    var buf: [protocol.max_name + 1]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{chosen.get()}) catch return default;
    sys.files.writeNew(path, line) catch |err| {
        sys.print(sys.log_warning ++ "dazzle-chat: cannot save the name: {s}\n", .{@errorName(err)});
    };
    return trimmed[0..chosen.len];
}

test "the name is the computer's until another is chosen" {
    const testing = std.testing;
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/dazzle-chat-name-{d}", .{linux.getpid()});
    _ = linux.unlink(path);
    defer _ = linux.unlink(path);
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("kitchen-pi", loadName(path, &buf, "kitchen-pi"));
    try testing.expectEqualStrings("Alice", saveName(path, "  Alice ", "kitchen-pi"));
    try testing.expectEqualStrings("Alice", loadName(path, &buf, "kitchen-pi"));
    // Cleared, or set back to the computer's: it follows the computer's.
    try testing.expectEqualStrings("kitchen-pi", saveName(path, "", "kitchen-pi"));
    try testing.expectEqualStrings("lounge-pi", loadName(path, &buf, "lounge-pi"));
    _ = saveName(path, "Bob", "kitchen-pi");
    try testing.expectEqualStrings("kitchen-pi", saveName(path, "kitchen-pi", "kitchen-pi"));
    try testing.expectEqualStrings("lounge-pi", loadName(path, &buf, "lounge-pi"));
    try testing.expect(hostname(&buf).len > 0);
}
