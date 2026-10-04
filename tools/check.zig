//! Checks run by build.zig before and after external build steps:
//!
//!     check tools <program>:<package> ...
//!         Fails, naming the Ubuntu/Debian packages to install, if any
//!         program is missing from PATH.
//!     check config <fragment> <.config>
//!         Fails if an option the fragment sets to y did not make it into
//!         the final kernel configuration (because a dependency is missing),
//!         or one it turns off is set after all.
//!     check sha256 <file> <hex digest> ...
//!         Fails (and deletes the file, so it is downloaded again) if a
//!         file's SHA-256 digest is not the expected one.

const std = @import("std");
const linux = std.os.linux;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage();
    const cmd = args[1];
    const ok = if (std.mem.eql(u8, cmd, "tools"))
        checkTools(init, args[2..])
    else if (std.mem.eql(u8, cmd, "config"))
        try checkConfig(init, args[2..])
    else if (std.mem.eql(u8, cmd, "sha256"))
        try checkSha256(init, args[2..])
    else
        usage();
    if (!ok) std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: check tools|config|sha256 ...\n", .{});
    std.process.exit(2);
}

fn onPath(path_env: []const u8, program: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_env, ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, program }) catch continue;
        if (linux.access(full.ptr, linux.X_OK) == 0) return true;
    }
    return false;
}

fn checkTools(init: std.process.Init, specs: []const [:0]const u8) bool {
    const path_env = std.process.Environ.getPosix(init.minimal.environ, "PATH") orelse "/usr/bin:/bin";
    var missing_tools: [64][]const u8 = undefined;
    var missing_pkgs: [64][]const u8 = undefined;
    var n_tools: usize = 0;
    var n_pkgs: usize = 0;
    for (specs) |spec| {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse spec.len;
        const program = spec[0..colon];
        const package = if (colon < spec.len) spec[colon + 1 ..] else program;
        if (onPath(path_env, program) or n_tools == missing_tools.len) continue;
        missing_tools[n_tools] = program;
        n_tools += 1;
        for (missing_pkgs[0..n_pkgs]) |p| {
            if (std.mem.eql(u8, p, package)) break;
        } else {
            missing_pkgs[n_pkgs] = package;
            n_pkgs += 1;
        }
    }
    if (n_tools == 0) return true;
    std.debug.print("error: missing tools:", .{});
    for (missing_tools[0..n_tools]) |t| std.debug.print(" {s}", .{t});
    std.debug.print("\nOn Ubuntu/Debian: sudo apt install", .{});
    for (missing_pkgs[0..n_pkgs]) |p| std.debug.print(" {s}", .{p});
    std.debug.print("\n", .{});
    for (missing_pkgs[0..n_pkgs]) |p| {
        if (std.mem.eql(u8, p, "qemu-system-arm"))
            std.debug.print("(On Ubuntu releases with a hardware enablement stack the QEMU package is qemu-system-arm-hwe.)\n", .{});
        if (std.mem.eql(u8, p, "clang") or std.mem.eql(u8, p, "lld") or std.mem.eql(u8, p, "llvm"))
            std.debug.print("The kernel needs LLVM 17 or newer. Or build with GCC: -Dcross-compile=arm-linux-gnueabihf-\n", .{});
    }
    return false;
}

fn checkConfig(init: std.process.Init, args: []const [:0]const u8) !bool {
    if (args.len != 2) usage();
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    const fragment = try cwd.readFileAlloc(init.io, args[0], gpa, .limited(1 << 20));
    defer gpa.free(fragment);
    const config = try cwd.readFileAlloc(init.io, args[1], gpa, .limited(16 << 20));
    defer gpa.free(config);
    var ok = true;
    var lines = std.mem.splitScalar(u8, fragment, '\n');
    while (lines.next()) |line| {
        // "# CONFIG_X is not set" must not be set after all (something
        // selects it, or it cannot be turned off on its own).
        if (std.mem.startsWith(u8, line, "# CONFIG_") and std.mem.endsWith(u8, line, " is not set")) {
            const name = line[2 .. line.len - " is not set".len];
            var cl = std.mem.splitScalar(u8, config, '\n');
            while (cl.next()) |c| if (std.mem.startsWith(u8, c, name) and c.len > name.len and c[name.len] == '=') {
                std.debug.print("error: {s} is set in the final kernel config ({s}), but the fragment turns it off\n", .{ name, c });
                ok = false;
            };
            continue;
        }
        if (!std.mem.startsWith(u8, line, "CONFIG_") or !std.mem.endsWith(u8, line, "=y")) continue;
        var found = false;
        var cl = std.mem.splitScalar(u8, config, '\n');
        while (cl.next()) |c| if (std.mem.eql(u8, c, line)) {
            found = true;
            break;
        };
        if (!found) {
            std.debug.print("error: {s} is not set in the final kernel config (a dependency is missing)\n", .{line});
            ok = false;
        }
    }
    return ok;
}

fn checkSha256(init: std.process.Init, args: []const [:0]const u8) !bool {
    if (args.len % 2 != 0) usage();
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    var ok = true;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const data = try cwd.readFileAlloc(init.io, args[i], gpa, .limited(64 << 20));
        defer gpa.free(data);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, args[i + 1])) {
            std.debug.print("error: {s} has SHA-256 {s}, expected {s}; deleted it so it is fetched again\n", .{ args[i], &hex, args[i + 1] });
            cwd.deleteFile(init.io, args[i]) catch {};
            ok = false;
        }
    }
    return ok;
}
