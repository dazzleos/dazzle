//! Compiles a shader program for the GPU when Dazzle is built:
//!
//!     shaderc <program.spv> <output> [--depth-test] [--blend=none|source-over]
//!
//! The input is a Zig shader source compiled to SPIR-V (by build.zig); the
//! output is the program as `shader.Program.encode` writes it, which the
//! programs using it embed. Errors name the line in the Zig source.

const std = @import("std");
const shader = @import("shader");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) usage();
    var options: shader.Options = .{};
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--depth-test")) {
            options.depth_test = true;
        } else if (std.mem.eql(u8, arg, "--blend=none")) {
            options.blend = .none;
        } else if (std.mem.eql(u8, arg, "--blend=source-over")) {
            options.blend = .source_over;
        } else usage();
    }
    const cwd = std.Io.Dir.cwd();
    const spirv = try cwd.readFileAlloc(init.io, args[1], arena, .limited(16 << 20));
    var diag: shader.Diagnostic = .{};
    const program = shader.Program.compile(arena, spirv, options, &diag) catch |err| {
        std.debug.print("error: {s}: {s}\n", .{ @errorName(err), diag.message() });
        std.process.exit(1);
    };
    const bytes = try program.encode(arena);
    const out = try cwd.createFile(init.io, args[2], .{});
    defer out.close(init.io);
    try out.writeStreamingAll(init.io, bytes);
}

fn usage() noreturn {
    std.debug.print("usage: shaderc <program.spv> <output> [--depth-test] [--blend=none|source-over]\n", .{});
    std.process.exit(2);
}
