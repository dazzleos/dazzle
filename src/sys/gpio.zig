//! The Raspberry Pi's GPIO: what each pin is doing, read from the GPIO
//! registers (/dev/gpiomem, mapped read-only), and changing a pin through
//! the kernel's GPIO character device (/dev/gpiochipN, its v2 interface).
//!
//! Reading the registers sees every pin as it is, whatever it is used for,
//! without disturbing it; the character device would take a pin over to
//! read it, and give it back as an input. Changing a pin goes through the
//! kernel, which refuses pins its drivers use (the console's UART, say).
//! Settings asks for a pin, sets it up and lets it go at once: the Pi's
//! pin driver keeps an output's level, and pulls, after it is let go.
//!
//! The device manager gives the Dazzle user both devices.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The BCM283x has 54 GPIO lines.
pub const line_count = 54;

pub const gpiomem_path = "/dev/gpiomem";
pub const gpiomem0_path = "/dev/gpiomem0";
pub const gpiomem1_path = "/dev/gpiomem1";
pub const rp1_bank_size = 0xc000;

/// What a pin does: GPIO in or out, or an alternate function (I2C, SPI,
/// UART, PWM, ...: which depends on the pin).
pub const Function = enum(u4) {
    input = 0b0000,
    output = 0b0001,
    alt0 = 0b0100,
    alt1 = 0b0101,
    alt2 = 0b0110,
    alt3 = 0b0111,
    alt4 = 0b0011,
    alt5 = 0b0010,
    alt6 = 0b1000,
    alt7 = 0b1001,
    alt8 = 0b1010,

    /// The alternate function's number, if it is one.
    pub fn alt(f: Function) ?u4 {
        return switch (f) {
            .input, .output => null,
            .alt0 => 0,
            .alt1 => 1,
            .alt2 => 2,
            .alt3 => 3,
            .alt4 => 4,
            .alt5 => 5,
            .alt6 => 6,
            .alt7 => 7,
            .alt8 => 8,
        };
    }
};

/// The GPIO registers, mapped read-only. On the Pi 5, the RP1 southbridge's
/// IO_BANK0..2 are at /dev/gpiomem0 and SYS_RIO0..2 at /dev/gpiomem1; on
/// earlier boards, BCM283x's registers are at /dev/gpiomem.
pub const Registers = struct {
    regs: []align(std.heap.page_size_min) const u8,
    rio: ?[]align(std.heap.page_size_min) const u8 = null,

    pub fn open() !Registers {
        if (mapFile(gpiomem0_path, rp1_bank_size)) |io| {
            const rio = mapFile(gpiomem1_path, rp1_bank_size) catch |err| {
                _ = linux.munmap(io.ptr, io.len);
                return err;
            };
            return .{ .regs = io, .rio = rio };
        } else |_| {}
        return .{ .regs = try mapFile(gpiomem_path, 4096) };
    }

    fn mapFile(path: [:0]const u8, len: usize) ![]align(std.heap.page_size_min) const u8 {
        const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .SYNC = true });
        defer sys.close(fd);
        const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        const p: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(rc);
        return p[0..len];
    }

    pub fn close(r: *Registers) void {
        _ = linux.munmap(r.regs.ptr, r.regs.len);
        if (r.rio) |rio| _ = linux.munmap(rio.ptr, rio.len);
    }

    pub fn isRp1(r: *const Registers) bool {
        return r.rio != null;
    }

    fn word(buf: []align(std.heap.page_size_min) const u8, offset: usize) u32 {
        const p: *const volatile u32 = @ptrCast(@alignCast(buf.ptr + offset));
        return p.*;
    }

    /// What every pin does, and its level.
    pub fn read(r: *const Registers) State {
        if (r.rio) |rio| return readRp1(r.regs, rio);
        var s: State = .{};
        // GPFSEL0..5: three bits a pin, ten pins a register.
        for (0..6) |i| {
            const w = word(r.regs, i * 4);
            for (0..10) |j| {
                const pin = i * 10 + j;
                if (pin >= line_count) break;
                s.functions[pin] = @enumFromInt(@as(u3, @truncate(w >> @intCast(j * 3))));
            }
        }
        // GPLEV0..1.
        s.levels = @as(u64, word(r.regs, 0x34)) | @as(u64, word(r.regs, 0x38)) << 32;
        return s;
    }

    fn readRp1(io: []align(std.heap.page_size_min) const u8, rio: []align(std.heap.page_size_min) const u8) State {
        var s: State = .{};
        const banks = [_]struct { start: usize, count: usize, off: usize }{
            .{ .start = 0, .count = 28, .off = 0x0000 },
            .{ .start = 28, .count = 6, .off = 0x4000 },
            .{ .start = 34, .count = 20, .off = 0x8000 },
        };
        for (banks) |b| {
            const rio_oe = word(rio, b.off + 0x0004);
            const rio_in = word(rio, b.off + 0x0008);
            for (0..b.count) |p| {
                const pin = b.start + p;
                const ctrl = word(io, b.off + p * 8 + 4);
                const funcsel: u5 = @truncate(ctrl);
                const oeover: u2 = @truncate(ctrl >> 14);
                const is_out = (rio_oe >> @intCast(p)) & 1 != 0;
                s.functions[pin] = if (oeover == 2)
                    .input
                else switch (funcsel) {
                    0 => .alt0,
                    1 => .alt1,
                    2 => .alt2,
                    3 => .alt3,
                    4 => .alt4,
                    5 => if (is_out) .output else .input,
                    6 => .alt6,
                    7 => .alt7,
                    8 => .alt8,
                    else => if (is_out) .output else .input,
                };
                if ((rio_in >> @intCast(p)) & 1 != 0) s.levels |= @as(u64, 1) << @intCast(pin);
            }
        }
        return s;
    }
};

/// What the pins are doing.
pub const State = struct {
    functions: [line_count]Function = @splat(.input),
    /// Bit n: whether pin n is high.
    levels: u64 = 0,

    pub fn level(s: *const State, pin: u6) bool {
        return s.levels >> pin & 1 != 0;
    }
};

// --- The character device (linux/gpio.h, v2) -------------------------------------

pub const line_flag = struct {
    pub const used: u64 = 1 << 0;
    pub const active_low: u64 = 1 << 1;
    pub const input: u64 = 1 << 2;
    pub const output: u64 = 1 << 3;
    pub const bias_pull_up: u64 = 1 << 8;
    pub const bias_pull_down: u64 = 1 << 9;
    pub const bias_disabled: u64 = 1 << 10;
};

const attr_output_values = 2;

const ChipInfo = extern struct {
    name: [32]u8,
    label: [32]u8,
    lines: u32,
};

const LineAttribute = extern struct {
    id: u32,
    padding: u32 = 0,
    value: u64,
};

pub const LineInfo = extern struct {
    name: [32]u8 = @splat(0),
    consumer: [32]u8 = @splat(0),
    offset: u32 = 0,
    num_attrs: u32 = 0,
    flags: u64 = 0,
    attrs: [10]LineAttribute = @splat(.{ .id = 0, .value = 0 }),
    padding: [4]u32 = @splat(0),

    pub fn used(i: *const LineInfo) bool {
        return i.flags & line_flag.used != 0;
    }

    /// Who has the line (a driver, or a program), if anyone says.
    pub fn consumerName(i: *const LineInfo) []const u8 {
        return std.mem.sliceTo(&i.consumer, 0);
    }

    pub fn lineName(i: *const LineInfo) []const u8 {
        return std.mem.sliceTo(&i.name, 0);
    }
};

const LineConfigAttribute = extern struct {
    attr: LineAttribute,
    mask: u64,
};

const LineConfig = extern struct {
    flags: u64,
    num_attrs: u32,
    padding: [5]u32 = @splat(0),
    attrs: [10]LineConfigAttribute = @splat(.{ .attr = .{ .id = 0, .value = 0 }, .mask = 0 }),
};

const LineRequest = extern struct {
    offsets: [64]u32 = @splat(0),
    consumer: [32]u8 = @splat(0),
    config: LineConfig,
    num_lines: u32,
    event_buffer_size: u32 = 0,
    padding: [5]u32 = @splat(0),
    fd: i32 = 0,
};

const IOCTL = linux.IOCTL;
const get_chipinfo = IOCTL.IOR(0xB4, 0x01, ChipInfo);
const get_lineinfo = IOCTL.IOWR(0xB4, 0x05, LineInfo);
const get_line = IOCTL.IOWR(0xB4, 0x07, LineRequest);

/// How a pin can be set up.
pub const Mode = enum {
    input,
    input_pull_up,
    input_pull_down,
    output_low,
    output_high,

    pub fn flags(m: Mode) u64 {
        return switch (m) {
            .input => line_flag.input | line_flag.bias_disabled,
            .input_pull_up => line_flag.input | line_flag.bias_pull_up,
            .input_pull_down => line_flag.input | line_flag.bias_pull_down,
            .output_low, .output_high => line_flag.output,
        };
    }

    pub fn code(m: Mode) []const u8 {
        return switch (m) {
            .input => "input",
            .input_pull_up => "input-pull-up",
            .input_pull_down => "input-pull-down",
            .output_low => "output-low",
            .output_high => "output-high",
        };
    }
};

/// The GPIO chip of the SoC's pins.
pub const Chip = struct {
    fd: linux.fd_t,

    /// Finds the SoC's chip among /dev/gpiochip0..7 (the others are
    /// expanders: the firmware's, on the Pi 3).
    pub fn open() !Chip {
        var buf: [32]u8 = undefined;
        var denied = false;
        for (0..8) |n| {
            const path = std.mem.printSentinel(&buf, "/dev/gpiochip{d}", .{n}, 0) catch unreachable;
            const fd = sys.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch |err| {
                if (err == error.AccessDenied) denied = true;
                continue;
            };
            var info: ChipInfo = undefined;
            if (linux.errno(linux.ioctl(fd, get_chipinfo, @intFromPtr(&info))) == .SUCCESS and info.lines >= line_count) {
                return .{ .fd = fd };
            }
            sys.close(fd);
        }
        return if (denied) error.AccessDenied else error.NotFound;
    }

    pub fn close(c: *Chip) void {
        sys.close(c.fd);
    }

    pub fn lineInfo(c: *const Chip, pin: u32) ?LineInfo {
        var info: LineInfo = .{ .offset = pin };
        if (linux.errno(linux.ioctl(c.fd, get_lineinfo, @intFromPtr(&info))) != .SUCCESS) return null;
        return info;
    }

    /// Sets pin `pin` up as `mode`, and lets it go (it stays so).
    pub fn set(c: *const Chip, pin: u32, mode: Mode) SetError!void {
        var req: LineRequest = .{
            .config = .{ .flags = mode.flags(), .num_attrs = 0 },
            .num_lines = 1,
        };
        req.offsets[0] = pin;
        @memcpy(req.consumer[0..consumer.len], consumer);
        if (mode == .output_low or mode == .output_high) {
            req.config.num_attrs = 1;
            req.config.attrs[0] = .{ .attr = .{ .id = attr_output_values, .value = @intFromBool(mode == .output_high) }, .mask = 1 };
        }
        switch (linux.errno(linux.ioctl(c.fd, get_line, @intFromPtr(&req)))) {
            .SUCCESS => sys.close(req.fd),
            .BUSY => return error.Busy,
            .ACCES, .PERM => return error.AccessDenied,
            .INVAL => return error.Invalid,
            else => return error.Unexpected,
        }
    }

    const consumer = "dazzle";
};

pub const SetError = error{
    /// Something else has the pin (a driver, or a program).
    Busy,
    AccessDenied,
    Invalid,
    Unexpected,
};

const testing = std.testing;

test "the kernel's structures are its size" {
    try testing.expectEqual(@as(usize, 68), @sizeOf(ChipInfo));
    try testing.expectEqual(@as(usize, 256), @sizeOf(LineInfo));
    try testing.expectEqual(@as(usize, 272), @sizeOf(LineConfig));
    try testing.expectEqual(@as(usize, 592), @sizeOf(LineRequest));
    // _IOWR(0xB4, 0x05, struct gpio_v2_line_info) and the others.
    try testing.expectEqual(@as(u32, 0xc100b405), get_lineinfo);
    try testing.expectEqual(@as(u32, 0xc250b407), get_line);
    try testing.expectEqual(@as(u32, 0x8044b401), get_chipinfo);
}

test "functions from the registers" {
    // A fake register page: pin 0 an output, pin 2 ALT0 (I2C), pin 14 ALT5,
    // pin 53 ALT3; pins 1 and 33 high.
    var page: [4096]u8 align(std.heap.page_size_min) = @splat(0);
    const put = struct {
        fn f(p: []u8, off: usize, v: u32) void {
            std.mem.writeInt(u32, p[off..][0..4], v, .little);
        }
    }.f;
    put(&page, 0x00, 0b001 | 0b100 << 6);
    put(&page, 0x04, 0b010 << 12);
    put(&page, 0x14, 0b111 << 9);
    put(&page, 0x34, 0b10);
    put(&page, 0x38, 0b10);
    const r: Registers = .{ .regs = &page };
    const s = r.read();
    try testing.expectEqual(Function.output, s.functions[0]);
    try testing.expectEqual(Function.input, s.functions[1]);
    try testing.expectEqual(Function.alt0, s.functions[2]);
    try testing.expectEqual(Function.alt5, s.functions[14]);
    try testing.expectEqual(Function.alt3, s.functions[53]);
    try testing.expect(s.level(1) and s.level(33) and !s.level(0));
    try testing.expectEqual(@as(?u4, 5), Function.alt5.alt());
}

test "functions from RP1 registers" {
    var io: [rp1_bank_size]u8 align(std.heap.page_size_min) = @splat(0);
    var rio: [rp1_bank_size]u8 align(std.heap.page_size_min) = @splat(0);
    const put = struct {
        fn f(p: []u8, off: usize, v: u32) void {
            std.mem.writeInt(u32, p[off..][0..4], v, .little);
        }
    }.f;
    // Pin 0: FUNCSEL=5 (GPIO), RIO_OE bit 0 = 1 -> output.
    put(&io, 0x0000 + 0 * 8 + 4, 5);
    // Pin 1: FUNCSEL=5 (GPIO), RIO_OE bit 1 = 0 -> input.
    put(&io, 0x0000 + 1 * 8 + 4, 5);
    // Pin 2: FUNCSEL=3 (ALT3 = I2C1 SDA).
    put(&io, 0x0000 + 2 * 8 + 4, 3);
    // Pin 14: FUNCSEL=4 (ALT4 = UART0 TX).
    put(&io, 0x0000 + 14 * 8 + 4, 4);
    // Pin 18: FUNCSEL=8 (ALT8 = GPCLK1).
    put(&io, 0x0000 + 18 * 8 + 4, 8);
    // Bank 0 RIO_OE (pin 0 output) and RIO_IN (pin 1 high).
    put(&rio, 0x0004, 1 << 0);
    put(&rio, 0x0008, 1 << 1);
    // Pin 33 (Bank 1, p = 5): FUNCSEL=5, RIO_IN bit 5 = 1.
    put(&io, 0x4000 + 5 * 8 + 4, 5);
    put(&rio, 0x4008, 1 << 5);
    const r: Registers = .{ .regs = &io, .rio = &rio };
    const s = r.read();
    try testing.expect(r.isRp1());
    try testing.expectEqual(Function.output, s.functions[0]);
    try testing.expectEqual(Function.input, s.functions[1]);
    try testing.expectEqual(Function.alt3, s.functions[2]);
    try testing.expectEqual(Function.alt4, s.functions[14]);
    try testing.expectEqual(Function.alt8, s.functions[18]);
    try testing.expect(s.level(1) and s.level(33) and !s.level(0));
}
