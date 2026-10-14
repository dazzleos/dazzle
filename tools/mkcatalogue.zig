//! Writes the app catalogue, apps.json: the apps that can be installed,
//! published beside the image and their archives (each made by mkapp, and
//! compressed). Settings downloads it, each app's icon (`<name>.png`),
//! and an app's archive from the same place by its "file", checking its size,
//! SHA-256 and Ed25519 signature.
//!
//!     {
//!       "version": "<the commit they were built from>",
//!       "time": <when it was committed, in seconds since 1970>,
//!       "apps": [
//!         {
//!           "name": "dazzle-demo",
//!           "title": "Demo",
//!           "description": "A spinning 3D shape, showing off the graphics",
//!           "version": "<the commit they were built from>",
//!           "time": <when it was committed, in seconds since 1970>,
//!           "icon": "dazzle-demo.png",
//!           "file": "dazzle-demo.tar.xz",
//!           "size": 104321,
//!           "sha256": "<64 hex digits>",
//!           "signature": "<128 hex digits>"
//!         }
//!       ]
//!     }
//!
//! Usage: mkcatalogue [--key=<64-hex-seed>] <apps.json> <version> <time> (<name> <title> <description> <icon> <archive>)...

const std = @import("std");
pub const Ed25519 = std.crypto.sign.Ed25519;

/// The default deterministic 32-byte Ed25519 seed used when no signing key
/// is provided.
pub const default_seed: [32]u8 = "dazzle-signing-key-seed-00000001".*;

pub const App = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    version: []const u8 = "",
    time: u64 = 0,
    icon: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
    signature: []const u8 = "",
};

pub const Catalogue = struct {
    version: []const u8,
    time: u64 = 0,
    apps: []const App,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var base: usize = 1;
    var seed: [32]u8 = default_seed;
    if (base < args.len and std.mem.startsWith(u8, args[base], "--key=")) {
        seed = try parseSeed(args[base]["--key=".len..]);
        base += 1;
    }
    if (args.len < base + 3 or (args.len - (base + 3)) % 5 != 0) {
        std.debug.print("usage: mkcatalogue [--key=<64-hex-seed>] <apps.json> <version> <time> (<name> <title> <description> <icon> <archive>)...\n", .{});
        std.process.exit(2);
    }
    const kp = keyPair(seed);
    const out_path = args[base];
    const version = args[base + 1];
    const time = try std.fmt.parseInt(u64, args[base + 2], 10);
    const cwd = std.Io.Dir.cwd();
    var apps: std.ArrayList(App) = .empty;
    var i: usize = base + 3;
    while (i < args.len) : (i += 5) {
        const archive = try cwd.readFileAlloc(init.io, args[i + 4], arena, .limited(256 << 20));
        try apps.append(arena, .{
            .name = args[i],
            .title = args[i + 1],
            .description = args[i + 2],
            .version = version,
            .time = time,
            .icon = args[i + 3],
            .file = try std.fmt.allocPrint(arena, "{s}.tar.xz", .{args[i]}),
            .size = archive.len,
            .sha256 = try hexSha256(arena, archive),
            .signature = try hexSignature(arena, archive, kp),
        });
    }
    const json = try write(arena, .{ .version = version, .time = time, .apps = apps.items });
    const file = try cwd.createFile(init.io, out_path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, json);
}

pub fn keyPair(seed: [32]u8) Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
}

pub fn parseSeed(text: []const u8) ![32]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != 64) return error.InvalidSigningKey;
    var seed: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&seed, trimmed) catch return error.InvalidSigningKey;
    return seed;
}

pub fn hexSha256(gpa: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.allocPrint(gpa, "{x}", .{&digest});
}

pub fn hexSignature(gpa: std.mem.Allocator, data: []const u8, kp: Ed25519.KeyPair) ![]const u8 {
    const sig = try kp.sign(data, null);
    const bytes = sig.toBytes();
    return std.fmt.allocPrint(gpa, "{x}", .{&bytes});
}

pub fn write(gpa: std.mem.Allocator, c: Catalogue) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(c, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

test "the catalogue: each app, with its archive's size, digest and Ed25519 signature" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const kp = keyPair(default_seed);
    const json = try write(a, .{ .version = "abc1234", .time = 1791331200, .apps = &.{.{
        .name = "dazzle-demo",
        .title = "Demo",
        .description = "Spins",
        .version = "abc1234",
        .time = 1791331200,
        .icon = "dazzle-demo.png",
        .file = "dazzle-demo.tar.xz",
        .size = 3,
        .sha256 = try hexSha256(a, "abc"),
        .signature = try hexSignature(a, "abc", kp),
    }} });
    const back = try std.json.parseFromSliceLeaky(Catalogue, a, json, .{});
    try std.testing.expectEqualStrings("abc1234", back.version);
    try std.testing.expectEqual(@as(u64, 1791331200), back.time);
    try std.testing.expectEqualStrings("Demo", back.apps[0].title);
    try std.testing.expectEqualStrings("dazzle-demo.png", back.apps[0].icon);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", back.apps[0].sha256);
    try std.testing.expectEqual(@as(usize, 128), back.apps[0].signature.len);
    var sig_bytes: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sig_bytes, back.apps[0].signature);
    try Ed25519.Signature.fromBytes(sig_bytes).verify("abc", kp.public_key);
}

