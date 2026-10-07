//! Names for a new computer: two words, like "awesome-elephant", picked
//! at random so that computers on the same network are unlikely to share
//! one. Each is a valid hostname (lowercase letters and a hyphen).

const std = @import("std");

const adjectives = [_][]const u8{
    "awesome", "bold",    "brave",  "breezy",  "bright", "calm",     "cheerful", "clever",
    "cosmic",  "curious", "dapper", "eager",   "fancy",  "fearless", "friendly", "gentle",
    "glowing", "golden",  "happy",  "jolly",   "kind",   "lively",   "lucky",    "mighty",
    "nimble",  "noble",   "plucky", "polite",  "proud",  "quick",    "quiet",    "radiant",
    "shiny",   "silly",   "snappy", "sparkly", "speedy", "sunny",    "swift",    "zesty",
};

const animals = [_][]const u8{
    "badger",  "beaver", "bison",  "camel", "cheetah", "dolphin", "eagle",    "elephant",
    "falcon",  "ferret", "fox",    "gecko", "giraffe", "heron",   "hedgehog", "koala",
    "lemur",   "lion",   "llama",  "lynx",  "magpie",  "meerkat", "moose",    "narwhal",
    "octopus", "otter",  "owl",    "panda", "parrot",  "penguin", "puffin",   "rabbit",
    "raccoon", "robin",  "salmon", "seal",  "sloth",   "tiger",   "turtle",   "walrus",
};

/// A name made from two random numbers.
pub fn pick(buf: []u8, a: u32, b: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ adjectives[a % adjectives.len], animals[b % animals.len] }) catch "dazzle";
}

/// A random name.
pub fn random(buf: []u8) []const u8 {
    var bytes: [8]u8 = undefined;
    var at: usize = 0;
    while (at < bytes.len) {
        const rc = std.os.linux.getrandom(bytes[at..].ptr, bytes.len - at, 0);
        if (std.os.linux.errno(rc) == .SUCCESS) at += rc else break;
    }
    return pick(buf, std.mem.readInt(u32, bytes[0..4], .little), std.mem.readInt(u32, bytes[4..8], .little));
}

test "names are two words, and valid hostnames" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("awesome-elephant", pick(&buf, 0, 7));
    const Hostname = @import("sys").system.Hostname;
    for (adjectives) |adj| for (animals) |animal| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}-{s}", .{ adj, animal });
        try std.testing.expect(Hostname.parse(name) != null);
    };
    try std.testing.expect(Hostname.parse(random(&buf)) != null);
}
