//! A key lit as it is pressed, so someone typing sees which: held, all of
//! it; let go, fading over `fade_ns`. Setup's keyboard picture (keys typed
//! on the keyboard) and the shell's on-screen keyboard (keys touched)
//! light their keys so.

const std = @import("std");
const kete = @import("kete");
const sys = @import("sys");

/// How long a key let go takes to stop being lit.
pub const fade_ns: u64 = 300 * std.time.ns_per_ms;

/// How lit a key is (0 to 1): held, or let go at `let_go_ns` (0: never).
pub fn lit(held: bool, let_go_ns: u64, now_ns: u64) f32 {
    if (held) return 1;
    if (let_go_ns == 0) return 0;
    const since = now_ns -| let_go_ns;
    if (since >= fade_ns) return 0;
    return 1 - @as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(fade_ns));
}

/// A key's face lit `g` (its colour unlit: `base`), in theme `t`.
pub fn face(t: anytype, base: kete.gfx.Color, g: f32) kete.gfx.Color {
    return kete.Easing.linear.lerp(base, t.primary_container, g);
}

/// A key's edge lit `g`.
pub fn border(t: anytype, g: f32) kete.gfx.Color {
    return kete.Easing.linear.lerp(t.outline_variant, t.primary, g);
}

/// A key pressed by the pointer or a touch (a `kete.Pressable`'s): kept
/// from frame to frame.
pub const Key = struct {
    /// Give it to the key's `Pressable`.
    interaction: kete.PointerInteraction = .{},
    was_held: bool = false,
    let_go_ns: u64 = 0,

    /// It was pressed (call it from the `Pressable`'s `on_press`): lit
    /// even if it was let go before a frame saw it held (a quick tap).
    pub fn pressed(k: *Key) void {
        k.let_go_ns = sys.nowNs();
    }

    /// How lit it is now; frames asked for while it fades.
    pub fn glow(k: *Key, cx: *kete.BuildContext) f32 {
        const now = cx.now();
        const held = k.interaction.pressed;
        if (k.was_held and !held) k.let_go_ns = now;
        k.was_held = held;
        const g = lit(held, k.let_go_ns, now);
        if (g > 0 and !held) cx.requestFrame();
        return g;
    }
};

test "a key lit while held, fading once let go" {
    try std.testing.expectEqual(@as(f32, 1), lit(true, 0, 5));
    try std.testing.expectEqual(@as(f32, 0), lit(false, 0, 5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lit(false, 1000, 1000 + fade_ns / 2), 0.001);
    try std.testing.expectEqual(@as(f32, 0), lit(false, 1000, 1000 + fade_ns));
}
