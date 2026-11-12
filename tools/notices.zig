//! Makes a NOTICES file: the third-party software built into a program
//! (or the system's programs), and its licences, from a section for each
//! in notices/.
//!
//!     notices <out> <what> <section.txt>...
//!
//! <what> is what the notices are for ("Dazzle's system programs", "the
//! Files app").

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: notices <out> <what> <section.txt>...\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "Third-party software in {s}\n\nThe following are built into {s}, under the licences given.\n", .{ args[2], args[2] });
    for (args[3..]) |path| {
        const section = try cwd.readFileAlloc(init.io, path, arena, .limited(1 << 20));
        try out.appendSlice(arena, "\n" ++ &@as([80]u8, @splat('=')) ++ "\n");
        try out.appendSlice(arena, section);
        if (!std.mem.endsWith(u8, section, "\n")) try out.append(arena, '\n');
    }
    const file = try cwd.createFile(init.io, args[1], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, out.items);
}
