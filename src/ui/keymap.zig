//! Linux key codes (input-event-codes.h) to characters, for a US keyboard.
//! The shell sends key codes without a keymap (wl_keyboard's no_keymap), so
//! the toolkit maps them itself.

pub const escape = 1;
pub const backspace = 14;
pub const tab = 15;
pub const enter = 28;
pub const left_ctrl = 29;
pub const right_ctrl = 97;
pub const key_a = 30;
pub const left_shift = 42;
pub const key_x = 45;
pub const key_c = 46;
pub const key_v = 47;
pub const right_shift = 54;
pub const caps_lock = 58;
pub const home = 102;
pub const left = 105;
pub const right = 106;
pub const end = 107;
pub const delete = 111;
pub const keypad_enter = 96;

const plain = blk: {
    var t: [64]u8 = @splat(0);
    for ("1234567890-=", 2..) |c, i| t[i] = c;
    for ("qwertyuiop[]", 16..) |c, i| t[i] = c;
    for ("asdfghjkl;'`", 30..) |c, i| t[i] = c;
    t[43] = '\\';
    for ("zxcvbnm,./", 44..) |c, i| t[i] = c;
    t[57] = ' ';
    break :blk t;
};

const shifted = blk: {
    var t: [64]u8 = @splat(0);
    for ("!@#$%^&*()_+", 2..) |c, i| t[i] = c;
    for ("QWERTYUIOP{}", 16..) |c, i| t[i] = c;
    for ("ASDFGHJKL:\"~", 30..) |c, i| t[i] = c;
    t[43] = '|';
    for ("ZXCVBNM<>?", 44..) |c, i| t[i] = c;
    t[57] = ' ';
    break :blk t;
};

/// The character a key types, if it types one. Caps Lock shifts letters
/// only.
pub fn char(code: u32, shift: bool, caps: bool) ?u8 {
    if (code >= plain.len) return null;
    const c = plain[code];
    if (c == 0) return null;
    const letter = c >= 'a' and c <= 'z';
    const up = if (letter) shift != caps else shift;
    return if (up) shifted[code] else c;
}

const testing = @import("std").testing;

test "US key map" {
    try testing.expectEqual(@as(?u8, 'a'), char(30, false, false));
    try testing.expectEqual(@as(?u8, 'A'), char(30, true, false));
    try testing.expectEqual(@as(?u8, 'A'), char(30, false, true));
    try testing.expectEqual(@as(?u8, 'a'), char(30, true, true));
    try testing.expectEqual(@as(?u8, '1'), char(2, false, true));
    try testing.expectEqual(@as(?u8, '!'), char(2, true, false));
    try testing.expectEqual(@as(?u8, '0'), char(11, false, false));
    try testing.expectEqual(@as(?u8, ' '), char(57, true, false));
    try testing.expectEqual(@as(?u8, '?'), char(53, true, false));
    try testing.expectEqual(@as(?u8, '|'), char(43, true, false));
    try testing.expectEqual(@as(?u8, null), char(enter, false, false));
    try testing.expectEqual(@as(?u8, null), char(500, false, false));
}
