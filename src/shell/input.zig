//! USB keyboards and mice, read from their evdev nodes (/dev/input/eventN).
//!
//! Init's device manager gives the Dazzle user each node as it appears;
//! the shell looks for new ones once a second, so devices can be plugged
//! in at any time. Relative motion moves the pointer, the wheel scrolls,
//! mouse buttons are pointer buttons and every other key is a keyboard
//! key, as a Linux key code.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

const print = sys.print;

pub const Event = union(enum) {
    /// Relative pointer motion.
    motion: [2]i32,
    /// A Linux button code (BTN_LEFT, ...).
    button: struct { code: u32, pressed: bool },
    /// Scrolling, in Wayland's terms: an axis (0 vertical, 1 horizontal)
    /// and a distance, positive down or right.
    axis: struct { axis: u32, value: f64 },
    /// A Linux key code (KEY_A, ...).
    key: struct { code: u32, pressed: bool },
    /// The end of a group of events that happened together.
    frame,
};

/// linux/input.h's struct input_event, with the time as two longs.
const RawEvent = extern struct {
    sec: usize,
    usec: usize,
    type: u16,
    code: u16,
    value: i32,
};

const ev_syn = 0x00;
const ev_key = 0x01;
const ev_rel = 0x02;
const syn_report = 0;
const rel_x = 0x00;
const rel_y = 0x01;
const rel_hwheel = 0x06;
const rel_wheel = 0x08;
const btn_mouse = 0x110;
const btn_task = 0x117;
/// Keyboard keys are below the first button code.
const btn_misc = 0x100;
/// How far one notch of a scroll wheel scrolls.
const wheel_step = 15;

pub fn decode(ev_type: u16, code: u16, value: i32) ?Event {
    switch (ev_type) {
        ev_syn => if (code == syn_report) return .frame,
        ev_rel => switch (code) {
            rel_x => return .{ .motion = .{ value, 0 } },
            rel_y => return .{ .motion = .{ 0, value } },
            // Wheel notches are positive up and left.
            rel_wheel => return .{ .axis = .{ .axis = 0, .value = @floatFromInt(-value * wheel_step) } },
            rel_hwheel => return .{ .axis = .{ .axis = 1, .value = @floatFromInt(value * wheel_step) } },
            else => {},
        },
        ev_key => {
            // 2 is the keyboard's own auto-repeat; clients repeat keys.
            if (value != 0 and value != 1) return null;
            const pressed = value == 1;
            if (code >= btn_mouse and code <= btn_task) return .{ .button = .{ .code = code, .pressed = pressed } };
            if (code < btn_misc and code != 0) return .{ .key = .{ .code = code, .pressed = pressed } };
        },
        else => {},
    }
    return null;
}

pub const max_devices = 32;

/// N for a device node named "eventN" (N below `max_devices`).
fn eventNumber(name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, name, "event")) return null;
    const n = std.fmt.parseInt(usize, name["event".len..], 10) catch return null;
    return if (n < max_devices) n else null;
}

pub const Devices = struct {
    /// Open event nodes, by number.
    fds: [max_devices]?linux.fd_t = @splat(null),
    /// Whether each has sent events yet (logged once, for diagnosis).
    active: [max_devices]bool = @splat(false),

    /// Opens event nodes that are not open yet.
    pub fn scan(d: *Devices) void {
        const dir = sys.open("/dev/input", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
        defer sys.close(dir);
        var buf: [2048]u8 align(8) = undefined;
        while (true) {
            const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch return;
            if (n == 0) return;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
                at += reclen;
                if (eventNumber(name)) |number| d.open(number);
            }
        }
    }

    /// Opens /dev/input/event`n` unless it is open.
    fn open(d: *Devices, n: usize) void {
        const slot = &d.fds[n];
        if (slot.* != null) return;
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{n}) catch return;
        // Not handed to the user yet: tried again at the next scan.
        const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }) catch return;
        slot.* = fd;
        d.active[n] = false;
        var name: [64]u8 = @splat(0);
        _ = linux.ioctl(fd, linux.IOCTL.IOR('E', 0x06, [64]u8), @intFromPtr(&name));
        print("dazzle-shell: input: {s}: {s}\n", .{ path, std.mem.sliceTo(&name, 0) });
    }

    /// Adds the open devices to `fds`; returns how many.
    pub fn pollFds(d: *const Devices, fds: []linux.pollfd) usize {
        var n: usize = 0;
        for (d.fds) |slot| if (slot) |fd| {
            if (n == fds.len) break;
            fds[n] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        };
        return n;
    }

    /// Reads the events a device has (whose file descriptor is `fd`) into
    /// `out`. Closes it when it is unplugged.
    pub fn read(d: *Devices, fd: linux.fd_t, out: []Event) []Event {
        var raw: [64]RawEvent = undefined;
        var n: usize = 0;
        const rc = linux.read(fd, @ptrCast(&raw), @sizeOf(@TypeOf(raw)));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN, .INTR => return out[0..0],
            else => |e| {
                for (&d.fds, 0..) |*slot, i| if (slot.* == fd) {
                    slot.* = null;
                    print("dazzle-shell: input: /dev/input/event{d} removed\n", .{i});
                };
                sys.close(fd);
                if (e != .NODEV) print("dazzle-shell: input: read failed ({s})\n", .{@tagName(e)});
                return out[0..0];
            },
        }
        for (&d.fds, 0..) |slot, i| if (slot == fd and !d.active[i]) {
            d.active[i] = true;
            print("dazzle-shell: input: first events from /dev/input/event{d}\n", .{i});
        };
        for (raw[0 .. rc / @sizeOf(RawEvent)]) |r| {
            if (n == out.len) break;
            if (decode(r.type, r.code, r.value)) |e| {
                out[n] = e;
                n += 1;
            }
        }
        return out[0..n];
    }
};

test "event node names" {
    try std.testing.expectEqual(@as(?usize, 3), eventNumber("event3"));
    try std.testing.expectEqual(@as(?usize, null), eventNumber("mouse0"));
    try std.testing.expectEqual(@as(?usize, null), eventNumber("event99"));
    try std.testing.expectEqual(@as(?usize, null), eventNumber("by-id"));
}

test "decode" {
    try std.testing.expectEqual(Event{ .motion = .{ -3, 0 } }, decode(ev_rel, rel_x, -3).?);
    try std.testing.expectEqual(Event{ .motion = .{ 0, 5 } }, decode(ev_rel, rel_y, 5).?);
    try std.testing.expectEqual(Event{ .axis = .{ .axis = 0, .value = -15 } }, decode(ev_rel, rel_wheel, 1).?);
    try std.testing.expectEqual(Event{ .button = .{ .code = 0x110, .pressed = true } }, decode(ev_key, 0x110, 1).?);
    try std.testing.expectEqual(Event{ .key = .{ .code = 30, .pressed = false } }, decode(ev_key, 30, 0).?);
    try std.testing.expectEqual(@as(?Event, null), decode(ev_key, 30, 2));
    try std.testing.expectEqual(Event.frame, decode(ev_syn, syn_report, 0).?);
    try std.testing.expectEqual(@as(?Event, null), decode(0x04, 0, 0)); // EV_MSC
}
