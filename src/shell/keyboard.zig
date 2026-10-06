//! The keyboard as Wayland clients see it: an XKB keymap for a US keyboard
//! (us.xkb), sent to each client in a sealed memory file, and the state of
//! its modifiers (Shift, Caps Lock, Control, Alt, Num Lock, Super), which
//! the shell tracks from the key codes and sends as masks of the keymap's
//! modifiers.

const std = @import("std");
const linux = std.os.linux;

/// The keymap, as XKB text (with the NUL the protocol counts in its size).
pub const keymap = @embedFile("us.xkb") ++ "\x00";

/// A file holding the keymap, for wl_keyboard.keymap: sealed, so clients
/// can map it but nobody can change it.
pub fn keymapFile() !linux.fd_t {
    const fd_rc = linux.memfd_create("dazzle-keymap", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
    const fd: linux.fd_t = @intCast(fd_rc);
    errdefer _ = linux.close(fd);
    var at: usize = 0;
    while (at < keymap.len) {
        const rc = linux.write(fd, keymap[at..].ptr, keymap.len - at);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return error.SystemResources;
        at += rc;
    }
    const seals = linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE;
    _ = linux.fcntl(fd, linux.F.ADD_SEALS, seals);
    return fd;
}

/// The keymap's modifiers, as wl_keyboard.modifiers masks (XKB's real
/// modifiers: us.xkb maps the keys to them).
pub const shift = 1 << 0;
pub const lock = 1 << 1;
pub const control = 1 << 2;
pub const mod1 = 1 << 3; // Alt
pub const mod2 = 1 << 4; // Num Lock
pub const mod4 = 1 << 6; // Super

pub const Modifiers = struct {
    /// Held down (each key's count: both Shifts, say).
    held: [6]u8 = @splat(0),
    /// Caps Lock and Num Lock, toggled by their keys.
    locked: u32 = 0,

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
    const slot_masks = [_]u32{ shift, control, mod1, mod4 };
    const caps_lock = 58;
    const num_lock = 69;

    /// Notes a key going down or up (Linux key code). Returns whether the
    /// masks changed.
    pub fn update(m: *Modifiers, code: u32, pressed: bool) bool {
        const before = .{ m.depressed(), m.locked };
        for (keys) |k| if (k.code == code) {
            const n = &m.held[k.slot];
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

test "the keymap is in a sealed file" {
    const fd = try keymapFile();
    defer _ = linux.close(fd);
    var buf: [256]u8 = undefined;
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const n = linux.read(fd, &buf, buf.len);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "xkb_keymap {") != null);
    // Sealed: it cannot be written.
    try testing.expect(linux.errno(linux.write(fd, "x", 1)) != .SUCCESS);
}
