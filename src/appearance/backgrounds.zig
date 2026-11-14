//! The desktop backgrounds built into the system: photos in backgrounds/,
//! made ready at build time (tools/mkbackground.zig) and kept in
//! `dir` as `<file>.etc1`, for the shell to show and Settings to offer.
//! Only plain data: build.zig reads it too.

pub const BuiltIn = struct {
    /// What Settings calls it.
    name: []const u8,
    /// backgrounds/<file>.png in the source; `dir`/<file>.etc1 in the
    /// system.
    file: []const u8,
    /// Who took the photo (on Unsplash).
    photographer: []const u8,
};

pub const dir = "/os/backgrounds";

pub const all = [_]BuiltIn{
    .{ .name = "Forest", .file = "forest", .photographer = "Dan Otis" },
    .{ .name = "Seashore", .file = "seashore", .photographer = "Nattu Adnan" },
    .{ .name = "Sun rays", .file = "sunrays", .photographer = "Dave Hoefler" },
};

/// The path of `b` in the system.
pub fn path(comptime b: BuiltIn) []const u8 {
    return dir ++ "/" ++ b.file ++ ".etc1";
}

/// The built-in background at `p`, if it is one.
pub fn find(p: []const u8) ?BuiltIn {
    inline for (all) |b| {
        if (eql(p, path(b))) return b;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The size thumbnails are made at, for Settings.
pub const thumbnail_width = 112;
pub const thumbnail_height = 63;
