//! Prefixes a 32-bit ARM Linux zImage with a stub that starts it from
//! AArch64, for QEMU's Pi 3 machines (which start every kernel in AArch64
//! at EL2; the real firmware starts a 32-bit kernel in AArch32):
//!
//!     aarch32boot <zImage> <output>
//!
//! The stub makes EL1 AArch32, gives it the timer, turns its MMU and caches
//! off, and returns to the zImage (which follows at 0x1000) in SVC mode
//! with interrupts masked, passing r0 = 0, r1 = ~0 (no machine number: use
//! the device tree) and r2 = the device tree QEMU passed in x0.

const std = @import("std");

/// The stub's AArch64 instructions.
pub const stub = [_]u32{
    0xaa0003e2, // mov x2, x0
    0xd2800000, // mov x0, #0
    0xb2407fe1, // mov x1, #0xffffffff
    0xd2800003, // mov x3, #0
    0xd51c1103, // msr hcr_el2, x3          (RW = 0: EL1 is AArch32)
    0xd2800063, // mov x3, #3
    0xd51ce103, // msr cnthctl_el2, x3      (EL1 may use the physical timer)
    0xd51ce07f, // msr cntvoff_el2, xzr
    0xd2810003, // mov x3, #0x800
    0xf2a61a03, // movk x3, #0x30d0, lsl #16
    0xd5181003, // msr sctlr_el1, x3        (MMU and caches off)
    0x10007ea3, // adr x3, 0x1000           (the zImage)
    0xd51c4023, // msr elr_el2, x3
    0xd2803a63, // mov x3, #0x1d3           (AArch32 SVC, A, I and F masked)
    0xd51c4003, // msr spsr_el2, x3
    0xd69f03e0, // eret
};

pub const kernel_offset = 0x1000;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: aarch32boot <zImage> <output>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const kernel = try cwd.readFileAlloc(init.io, args[1], arena, .limited(64 << 20));
    const out = try arena.alloc(u8, kernel_offset + kernel.len);
    @memset(out[0..kernel_offset], 0);
    for (stub, 0..) |inst, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], inst, .little);
    @memcpy(out[kernel_offset..], kernel);
    const file = try cwd.createFile(init.io, args[2], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, out);
}
