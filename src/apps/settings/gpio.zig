//! The GPIO page's model: the board's header (which pin is which), and
//! what each GPIO pin is doing: read from the registers (see `sys.gpio`)
//! several times a second while the page shows, with who has it from the
//! kernel once a second. Setting a pin up goes through the kernel.

const std = @import("std");
const sys = @import("sys");

const gpio = sys.gpio;
pub const Mode = gpio.Mode;
pub const Function = gpio.Function;

/// A pin of the header.
pub const Pin = union(enum) {
    power_5v,
    power_3v3,
    ground,
    gpio: u6,
};

/// The 40-pin header (every board since the B+), pin 1 first.
pub const header_40 = [40]Pin{
    .power_3v3,  .power_5v,
    .{ .gpio = 2 },  .power_5v,
    .{ .gpio = 3 },  .ground,
    .{ .gpio = 4 },  .{ .gpio = 14 },
    .ground,     .{ .gpio = 15 },
    .{ .gpio = 17 }, .{ .gpio = 18 },
    .{ .gpio = 27 }, .ground,
    .{ .gpio = 22 }, .{ .gpio = 23 },
    .power_3v3,  .{ .gpio = 24 },
    .{ .gpio = 10 }, .ground,
    .{ .gpio = 9 },  .{ .gpio = 25 },
    .{ .gpio = 11 }, .{ .gpio = 8 },
    .ground,     .{ .gpio = 7 },
    .{ .gpio = 0 },  .{ .gpio = 1 },
    .{ .gpio = 5 },  .ground,
    .{ .gpio = 6 },  .{ .gpio = 12 },
    .{ .gpio = 13 }, .ground,
    .{ .gpio = 19 }, .{ .gpio = 16 },
    .{ .gpio = 26 }, .{ .gpio = 20 },
    .ground,     .{ .gpio = 21 },
};

/// The 26-pin header of the first Model A and B (revision 2): the first 26
/// pins of the 40.
pub const header_26 = header_40[0..26].*;

/// The very first Model B's (revision 1): pins 3, 5 and 13 are GPIO 0, 1
/// and 21.
pub const header_26_rev1 = blk: {
    var h = header_26;
    h[2] = .{ .gpio = 0 };
    h[4] = .{ .gpio = 1 };
    h[12] = .{ .gpio = 21 };
    break :blk h;
};

/// The header of the board whose model this is (as the device tree says);
/// null for the Compute Modules, which have none (their pins are listed
/// instead).
pub fn headerFor(model: []const u8) ?[]const Pin {
    const has = struct {
        fn f(m: []const u8, s: []const u8) bool {
            return std.mem.indexOf(u8, m, s) != null;
        }
    }.f;
    if (has(model, "Compute Module")) return null;
    const first = !has(model, "Plus") and
        (std.mem.startsWith(u8, model, "Raspberry Pi Model A") or std.mem.startsWith(u8, model, "Raspberry Pi Model B"));
    if (first) return if (has(model, "Rev 1")) &header_26_rev1 else &header_26;
    return &header_40;
}

/// What an alternate function of a pin is for, where it is one people use
/// (null otherwise).
pub fn altName(pin: u6, alt: u3) ?[]const u8 {
    const table = [_]struct { u6, u3, []const u8 }{
        .{ 0, 0, "I2C 0 data (HAT EEPROM)" }, .{ 1, 0, "I2C 0 clock (HAT EEPROM)" },
        .{ 0, 4, "UART 2 transmit" },         .{ 1, 4, "UART 2 receive" },
        .{ 2, 0, "I2C 1 data" },              .{ 3, 0, "I2C 1 clock" },
        .{ 2, 5, "I2C 3 data" },              .{ 3, 5, "I2C 3 clock" },
        .{ 4, 0, "General clock 0" },         .{ 5, 0, "General clock 1" },
        .{ 4, 4, "UART 3 transmit" },         .{ 5, 4, "UART 3 receive" },
        .{ 6, 0, "General clock 2" },         .{ 7, 0, "SPI 0 chip select 1" },
        .{ 6, 5, "I2C 4 data" },              .{ 7, 5, "I2C 4 clock" },
        .{ 8, 0, "SPI 0 chip select 0" },     .{ 9, 0, "SPI 0 MISO" },
        .{ 8, 4, "UART 4 transmit" },         .{ 9, 4, "UART 4 receive" },
        .{ 10, 0, "SPI 0 MOSI" },             .{ 11, 0, "SPI 0 clock" },
        .{ 10, 5, "I2C 5 data" },             .{ 11, 5, "I2C 5 clock" },
        .{ 12, 0, "PWM 0" },                  .{ 13, 0, "PWM 1" },
        .{ 12, 4, "UART 5 transmit" },        .{ 13, 4, "UART 5 receive" },
        .{ 14, 0, "UART 0 transmit" },        .{ 15, 0, "UART 0 receive" },
        .{ 14, 5, "UART 1 transmit" },        .{ 15, 5, "UART 1 receive" },
        .{ 16, 4, "SPI 1 chip select 2" },    .{ 17, 4, "SPI 1 chip select 1" },
        .{ 18, 4, "SPI 1 chip select 0" },    .{ 18, 0, "PCM clock" },
        .{ 18, 5, "PWM 0" },                  .{ 19, 0, "PCM frame" },
        .{ 19, 4, "SPI 1 MISO" },             .{ 19, 5, "PWM 1" },
        .{ 20, 0, "PCM in" },                 .{ 20, 4, "SPI 1 MOSI" },
        .{ 21, 0, "PCM out" },                .{ 21, 4, "SPI 1 clock" },
        .{ 22, 4, "JTAG reset" },             .{ 23, 4, "JTAG return clock" },
        .{ 22, 5, "I2C 6 data" },             .{ 23, 5, "I2C 6 clock" },
        .{ 24, 4, "JTAG data out" },          .{ 25, 4, "JTAG clock" },
        .{ 26, 4, "JTAG data in" },           .{ 27, 4, "JTAG mode" },
    };
    for (table) |e| if (e[0] == pin and e[1] == alt) return e[2];
    return null;
}

/// What a pin is usually for, besides GPIO, to label it on the header.
pub fn usualName(pin: u6) ?[]const u8 {
    return switch (pin) {
        0 => "ID SD",
        1 => "ID SC",
        2 => "SDA",
        3 => "SCL",
        4 => "GPCLK0",
        7 => "CE1",
        8 => "CE0",
        9 => "MISO",
        10 => "MOSI",
        11 => "SCLK",
        12 => "PWM0",
        13 => "PWM1",
        14 => "TXD",
        15 => "RXD",
        18 => "PCM CLK",
        else => null,
    };
}

/// A GPIO pin as it is.
pub const Line = struct {
    function: Function = .input,
    high: bool = false,
    /// The kernel says something has it (a driver, or a program), and who.
    used: bool = false,
    consumer_buf: [32]u8 = undefined,
    consumer_len: u8 = 0,

    pub fn consumer(l: *const Line) []const u8 {
        return l.consumer_buf[0..l.consumer_len];
    }
};

pub const Pins = struct {
    regs: ?gpio.Registers = null,
    chip: ?gpio.Chip = null,
    /// Why the pins cannot be read, or set; null while they can.
    read_failure: ?[]const u8 = null,
    set_failure: ?[]const u8 = null,
    lines: [gpio.line_count]Line = @splat(.{}),
    /// How each pin was set up here (pulls cannot be read back), while
    /// Settings runs.
    modes: [gpio.line_count]?Mode = @splat(null),
    /// What the last change was, and why it could not be made.
    last_pin: ?u6 = null,
    last_error: ?[]const u8 = null,
    opened: bool = false,

    pub fn deinit(p: *Pins) void {
        if (p.regs) |*r| r.close();
        if (p.chip) |*c| c.close();
        p.* = .{};
    }

    fn open(p: *Pins) void {
        if (p.opened) return;
        p.opened = true;
        p.regs = gpio.Registers.open() catch |err| blk: {
            p.read_failure = describe(err);
            break :blk null;
        };
        p.chip = gpio.Chip.open() catch |err| blk: {
            p.set_failure = describe(err);
            break :blk null;
        };
    }

    /// Reads the pins' functions and levels.
    pub fn readLevels(p: *Pins) void {
        p.open();
        const r = p.regs orelse return;
        const s = r.read();
        for (&p.lines, 0..) |*l, i| {
            l.function = s.functions[i];
            l.high = s.level(@intCast(i));
        }
    }

    /// Reads who has each pin, from the kernel.
    pub fn readUsers(p: *Pins) void {
        p.open();
        const c = p.chip orelse return;
        for (&p.lines, 0..) |*l, i| {
            const info = c.lineInfo(@intCast(i)) orelse continue;
            l.used = info.used();
            const name = info.consumerName();
            l.consumer_len = @intCast(@min(name.len, l.consumer_buf.len));
            @memcpy(l.consumer_buf[0..l.consumer_len], name[0..l.consumer_len]);
        }
    }

    /// Whether the pin can be set up here.
    pub fn settable(p: *const Pins, pin: u6) bool {
        return p.chip != null and !p.lines[pin].used;
    }

    /// How the pin is set up, as far as is known: an output's level is
    /// read, but an input's pull only if it was set here.
    pub fn mode(p: *const Pins, pin: u6) ?Mode {
        const l = &p.lines[pin];
        return switch (l.function) {
            .output => if (l.high) .output_high else .output_low,
            .input => if (p.modes[pin]) |m| switch (m) {
                .input, .input_pull_up, .input_pull_down => m,
                else => null,
            } else null,
            else => null,
        };
    }

    /// Sets the pin up as `m`.
    pub fn set(p: *Pins, pin: u6, m: Mode) void {
        p.open();
        p.last_pin = pin;
        p.last_error = null;
        const c = p.chip orelse {
            p.last_error = p.set_failure;
            return;
        };
        c.set(pin, m) catch |err| {
            p.last_error = switch (err) {
                error.Busy => "something else is using it",
                error.AccessDenied => "you are not allowed to change it",
                error.Invalid => "it cannot be set up so",
                error.Unexpected => "it could not be changed",
            };
            return;
        };
        p.modes[pin] = m;
        sys.print("dazzle-settings: GPIO {d} set to {s}\n", .{ pin, m.code() });
        p.readLevels();
        p.readUsers();
    }
};

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied => "Not allowed to use the GPIO",
        else => "There is no GPIO to use",
    };
}

const testing = std.testing;

test "headers by board" {
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi 4 Model B Rev 1.1").?.len);
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi 400 Rev 1.0").?.len);
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi 3 Model B Plus Rev 1.3").?.len);
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi Zero W Rev 1.1").?.len);
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi Model B Plus Rev 1.2").?.len);
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi 2 Model B Rev 1.1").?.len);
    const b2 = headerFor("Raspberry Pi Model B Rev 2").?;
    try testing.expectEqual(@as(usize, 26), b2.len);
    try testing.expectEqual(Pin{ .gpio = 2 }, b2[2]);
    const b1 = headerFor("Raspberry Pi Model B Rev 1").?;
    try testing.expectEqual(Pin{ .gpio = 0 }, b1[2]);
    try testing.expectEqual(Pin{ .gpio = 21 }, b1[12]);
    try testing.expect(headerFor("Raspberry Pi Compute Module 3 Rev 1.0") == null);
    try testing.expect(headerFor("Raspberry Pi Compute Module 4 Rev 1.0") == null);
    // Every GPIO 0-27 is on the 40-pin header, once.
    var seen: [28]bool = @splat(false);
    for (header_40) |pin| switch (pin) {
        .gpio => |g| {
            try testing.expect(!seen[g]);
            seen[g] = true;
        },
        else => {},
    };
    for (seen) |s| try testing.expect(s);
}

test "what a pin is set up as" {
    var p: Pins = .{ .opened = true };
    p.lines[17] = .{ .function = .output, .high = true };
    try testing.expectEqual(@as(?Mode, .output_high), p.mode(17));
    p.lines[4] = .{ .function = .input };
    try testing.expect(p.mode(4) == null);
    p.modes[4] = .input_pull_up;
    try testing.expectEqual(@as(?Mode, .input_pull_up), p.mode(4));
    p.lines[2] = .{ .function = .alt0, .used = true };
    try testing.expect(p.mode(2) == null);
    try testing.expect(!p.settable(2));
    try testing.expectEqualStrings("I2C 1 data", altName(2, 0).?);
    try testing.expect(altName(17, 0) == null);
}
