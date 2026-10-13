//! The keyboard as Wayland clients see it: an XKB keymap for the keyboard's
//! layout, sent to each client in a sealed memory file (and again when the
//! layout changes), and the state of its modifiers (Shift, Caps Lock,
//! Control, Alt, Num Lock, Super), which the shell tracks from the key
//! codes and sends as masks of the keymap's modifiers.
//!
//! The keymap is keymap.xkb with the symbols of the layout's keys (from
//! the locale module, as the toolkit types them) and keys.xkb's other keys.
//! Its symbols are named after the layout (`xkb_symbols "gb"`), which is how
//! Dazzle's apps know it (see app's window.zig).

const std = @import("std");
const linux = std.os.linux;
const locale = @import("locale");

/// The keymap for a layout, as XKB text (with the NUL the protocol counts
/// in its size).
pub fn keymap(k: locale.Keyboard) []const u8 {
    return switch (k) {
        inline else => |l| comptime generate(l),
    };
}

fn generate(comptime k: locale.Keyboard) []const u8 {
    @setEvalBranchQuota(200_000);
    var symbols: []const u8 = "";
    var altgr = false;
    for (k.keys()) |key| {
        const letter = key.plain >= 'a' and key.plain <= 'z';
        if (key.altgr != null) altgr = true;
        symbols = symbols ++ if (key.altgr) |third|
            std.fmt.comptimePrint("    key <{s}> {{ type = \"FOUR_LEVEL\", [ {s}, {s}, {s}, {s} ] }};\n", .{ keyName(key.code), keysym(key.plain), keysym(key.shifted), keysym(third), keysym(third) })
        else if (letter)
            std.fmt.comptimePrint("    key <{s}> {{ type = \"ALPHABETIC\", [ {s}, {s} ] }};\n", .{ keyName(key.code), keysym(key.plain), keysym(key.shifted) })
        else
            std.fmt.comptimePrint("    key <{s}> {{ [ {s}, {s} ] }};\n", .{ keyName(key.code), keysym(key.plain), keysym(key.shifted) });
    }
    // With a third level, the right Alt is AltGr.
    const alt = if (altgr)
        "    key <RALT> { [ ISO_Level3_Shift ] };\n    modifier_map Mod1 { <LALT> };\n    modifier_map Mod5 { <RALT> };\n"
    else
        "    key <RALT> { [ Alt_R ] };\n    modifier_map Mod1 { <LALT>, <RALT> };\n";
    return @embedFile("keymap.xkb") ++ "xkb_symbols \"" ++ k.code() ++ "\" {\n" ++ symbols ++ @embedFile("keys.xkb") ++ alt ++ "};\n};\n\x00";
}

/// The XKB name of the key with a Linux key code.
fn keyName(comptime code: u8) []const u8 {
    return switch (code) {
        2...13 => std.fmt.comptimePrint("AE{d:0>2}", .{code - 1}),
        16...27 => std.fmt.comptimePrint("AD{d:0>2}", .{code - 15}),
        30...40 => std.fmt.comptimePrint("AC{d:0>2}", .{code - 29}),
        41 => "TLDE",
        43 => "BKSL",
        44...53 => std.fmt.comptimePrint("AB{d:0>2}", .{code - 43}),
        57 => "SPCE",
        86 => "LSGT",
        else => @compileError(std.fmt.comptimePrint("no XKB name for key {d}", .{code})),
    };
}

/// A character's keysym name.
fn keysym(comptime c: u21) []const u8 {
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) return &[_]u8{@intCast(c)};
    return switch (c) {
        ' ' => "space",
        '!' => "exclam",
        '"' => "quotedbl",
        '#' => "numbersign",
        '$' => "dollar",
        '%' => "percent",
        '&' => "ampersand",
        '\'' => "apostrophe",
        '(' => "parenleft",
        ')' => "parenright",
        '*' => "asterisk",
        '+' => "plus",
        ',' => "comma",
        '-' => "minus",
        '.' => "period",
        '/' => "slash",
        ':' => "colon",
        ';' => "semicolon",
        '<' => "less",
        '=' => "equal",
        '>' => "greater",
        '?' => "question",
        '@' => "at",
        '[' => "bracketleft",
        '\\' => "backslash",
        ']' => "bracketright",
        '^' => "asciicircum",
        '_' => "underscore",
        '`' => "grave",
        '{' => "braceleft",
        '|' => "bar",
        '}' => "braceright",
        '~' => "asciitilde",
        '£' => "sterling",
        '¬' => "notsign",
        '¦' => "brokenbar",
        '€' => "EuroSign",
        else => std.fmt.comptimePrint("U{X:0>4}", .{c}),
    };
}

/// A file holding the layout's keymap, for wl_keyboard.keymap: sealed, so
/// clients can map it but nobody can change it.
pub fn keymapFile(k: locale.Keyboard) !linux.fd_t {
    const text = keymap(k);
    const fd_rc = linux.memfd_create("dazzle-keymap", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
    const fd: linux.fd_t = @intCast(fd_rc);
    errdefer _ = linux.close(fd);
    var at: usize = 0;
    while (at < text.len) {
        const rc = linux.write(fd, text[at..].ptr, text.len - at);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return error.SystemResources;
        at += rc;
    }
    const seals = linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE;
    _ = linux.fcntl(fd, linux.F.ADD_SEALS, seals);
    return fd;
}

/// The keymap's modifiers, as wl_keyboard.modifiers masks (XKB's real
/// modifiers: keymap.xkb and keys.xkb map the keys to them).
pub const shift = 1 << 0;
pub const lock = 1 << 1;
pub const control = 1 << 2;
pub const mod1 = 1 << 3; // Alt
pub const mod2 = 1 << 4; // Num Lock
pub const mod4 = 1 << 6; // Super
pub const mod5 = 1 << 7; // AltGr, on layouts with a third level

pub const Modifiers = struct {
    /// Held down (each key's count: both Shifts, say).
    held: [6]u8 = @splat(0),
    /// Caps Lock and Num Lock, toggled by their keys.
    locked: u32 = 0,
    /// The right Alt is AltGr (Mod5), as the layout's keymap says.
    altgr: bool = false,

    const keys = [_]struct { code: u32, slot: u3 }{
        .{ .code = 42, .slot = 0 }, // left Shift
        .{ .code = 54, .slot = 0 }, // right Shift
        .{ .code = 29, .slot = 1 }, // left Control
        .{ .code = 97, .slot = 1 }, // right Control
        .{ .code = 56, .slot = 2 }, // left Alt
        .{ .code = 100, .slot = 2 }, // right Alt
        .{ .code = 125, .slot = 3 }, // left Super
        .{ .code = 126, .slot = 3 }, // right Super
    };
    const slot_masks = [_]u32{ shift, control, mod1, mod4, mod5 };
    const right_alt = 100;
    const caps_lock = 58;
    const num_lock = 69;

    /// Notes a key going down or up (Linux key code). Returns whether the
    /// masks changed.
    pub fn update(m: *Modifiers, code: u32, pressed: bool) bool {
        const before = .{ m.depressed(), m.locked };
        for (keys) |k| if (k.code == code) {
            const n = &m.held[if (code == right_alt and m.altgr) 4 else k.slot];
            n.* = if (pressed) n.* +| 1 else n.* -| 1;
        };
        if (pressed and code == caps_lock) m.locked ^= lock;
        if (pressed and code == num_lock) m.locked ^= mod2;
        return before[0] != m.depressed() or before[1] != m.locked;
    }

    /// The modifiers held down.
    pub fn depressed(m: *const Modifiers) u32 {
        var mask: u32 = 0;
        for (slot_masks, 0..) |bit, i| if (m.held[i] > 0) {
            mask |= bit;
        };
        return mask;
    }
};

const testing = std.testing;

test "the right Alt is AltGr where the layout has a third level" {
    var m: Modifiers = .{};
    _ = m.update(100, true);
    try testing.expectEqual(@as(u32, mod1), m.depressed());
    _ = m.update(100, false);
    m.altgr = true;
    _ = m.update(100, true);
    try testing.expectEqual(@as(u32, mod5), m.depressed());
}

test "modifiers follow their keys, and the locks toggle" {
    var m: Modifiers = .{};
    try testing.expect(m.update(42, true));
    try testing.expectEqual(@as(u32, shift), m.depressed());
    // Both Shifts, one released: still shifted.
    try testing.expect(!m.update(54, true));
    try testing.expect(!m.update(42, false));
    try testing.expectEqual(@as(u32, shift), m.depressed());
    try testing.expect(m.update(54, false));
    try testing.expect(m.update(29, true));
    try testing.expectEqual(@as(u32, control), m.depressed());
    // A letter changes nothing.
    try testing.expect(!m.update(30, true));
    try testing.expect(m.update(58, true));
    try testing.expectEqual(@as(u32, lock), m.locked);
    try testing.expect(!m.update(58, false));
    try testing.expect(m.update(58, true));
    try testing.expectEqual(@as(u32, 0), m.locked);
}

test "each layout's keymap: its keys, and its name" {
    const us = keymap(.us);
    try testing.expect(std.mem.indexOf(u8, us, "xkb_symbols \"us\" {") != null);
    try testing.expect(std.mem.indexOf(u8, us, "key <AE02> { [ 2, at ] };") != null);
    try testing.expect(std.mem.indexOf(u8, us, "key <AD01> { type = \"ALPHABETIC\", [ q, Q ] };") != null);
    try testing.expect(std.mem.indexOf(u8, us, "key <ESC> { [ Escape ] };") != null);
    try testing.expect(std.mem.indexOf(u8, us, "modifier_map Mod1 { <LALT>, <RALT> };") != null);
    try testing.expectEqual(@as(u8, 0), us[us.len - 1]);
    const gb = keymap(.gb);
    try testing.expect(std.mem.indexOf(u8, gb, "xkb_symbols \"gb\" {") != null);
    try testing.expect(std.mem.indexOf(u8, gb, "key <AE03> { [ 3, sterling ] };") != null);
    try testing.expect(std.mem.indexOf(u8, gb, "key <AE04> { type = \"FOUR_LEVEL\", [ 4, dollar, EuroSign, EuroSign ] };") != null);
    try testing.expect(std.mem.indexOf(u8, gb, "key <BKSL> { [ numbersign, asciitilde ] };") != null);
    try testing.expect(std.mem.indexOf(u8, gb, "modifier_map Mod5 { <RALT> };") != null);
}

test "the keymap is in a sealed file" {
    const fd = try keymapFile(.gb);
    defer _ = linux.close(fd);
    var buf: [1024]u8 = undefined;
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const n = linux.read(fd, &buf, buf.len);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "xkb_keymap {") != null);
    // Sealed: it cannot be written.
    try testing.expect(linux.errno(linux.write(fd, "x", 1)) != .SUCCESS);
}
