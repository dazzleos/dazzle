//! USB keyboards, mice and touchscreens, read from their evdev nodes
//! (/dev/input/eventN).
//!
//! Init's device manager gives the Dazzle user each node as it appears;
//! the shell looks for new ones once a second, so devices can be plugged
//! in at any time. Relative motion moves the pointer, the wheel scrolls,
//! mouse buttons are pointer buttons and every other key is a keyboard
//! key, as a Linux key code. A device with absolute positions is a
//! touchscreen (`Touch`): its touches go down, move and come up, each at a
//! place on the screen from 0 to 1 across and down.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const evdev = sys.evdev;

const print = sys.print;

pub const TouchKind = enum { down, motion, up };

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
    /// A touch on a touchscreen: `id` is the touch's while it lasts, and
    /// `x`, `y` where it is, from 0 to 1 across and down the screen.
    touch: struct { kind: TouchKind, id: i32, x: f64 = 0, y: f64 = 0 },
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

/// How far one notch of a scroll wheel scrolls.
const wheel_step = 15;

pub fn decode(ev_type: u16, code: u16, value: i32) ?Event {
    switch (ev_type) {
        evdev.ev_syn => if (code == evdev.syn_report) return .frame,
        evdev.ev_rel => switch (code) {
            evdev.rel_x => return .{ .motion = .{ value, 0 } },
            evdev.rel_y => return .{ .motion = .{ 0, value } },
            // Wheel notches are positive up and left.
            evdev.rel_wheel => return .{ .axis = .{ .axis = 0, .value = @floatFromInt(-value * wheel_step) } },
            evdev.rel_hwheel => return .{ .axis = .{ .axis = 1, .value = @floatFromInt(value * wheel_step) } },
            else => {},
        },
        evdev.ev_key => {
            // 2 is the keyboard's own auto-repeat; clients repeat keys.
            if (value != 0 and value != 1) return null;
            const pressed = value == 1;
            if (code >= evdev.btn_mouse and code <= evdev.btn_task) return .{ .button = .{ .code = code, .pressed = pressed } };
            if (code < evdev.btn_misc and code != 0) return .{ .key = .{ .code = code, .pressed = pressed } };
        },
        else => {},
    }
    return null;
}

/// A touchscreen's touches, followed through its events: those that
/// track several (multitouch's slots, each touch with a tracking ID), or
/// one (BTN_TOUCH with ABS_X and ABS_Y). What changed is reported at each
/// SYN_REPORT, then a frame.
pub const Touch = struct {
    /// The range of positions across and down.
    range: [2][2]i32,
    multitouch: bool,
    slot: usize = 0,
    slots: [max_touches]Slot = @splat(.{}),

    pub const max_touches = 10;

    const Slot = struct {
        /// The touch's ID while one is down (-1 when none is).
        id: i32 = -1,
        x: i32 = 0,
        y: i32 = 0,
        /// The ID reported down (-1 if none), for a touch that came up
        /// to be reported up with it.
        reported: i32 = -1,
        moved: bool = false,
    };

    /// Takes one raw event; at a SYN_REPORT, adds what changed to `out`
    /// (from `n`), and returns how many it holds now.
    pub fn feed(t: *Touch, ev_type: u16, code: u16, value: i32, out: []Event, n_in: usize) usize {
        var n = n_in;
        switch (ev_type) {
            evdev.ev_abs => if (t.multitouch) switch (code) {
                evdev.abs_mt_slot => t.slot = @intCast(std.math.clamp(value, 0, max_touches - 1)),
                evdev.abs_mt_tracking_id => t.slots[t.slot].id = value,
                evdev.abs_mt_position_x => {
                    t.slots[t.slot].x = value;
                    t.slots[t.slot].moved = true;
                },
                evdev.abs_mt_position_y => {
                    t.slots[t.slot].y = value;
                    t.slots[t.slot].moved = true;
                },
                else => {},
            } else switch (code) {
                evdev.abs_x => {
                    t.slots[0].x = value;
                    t.slots[0].moved = true;
                },
                evdev.abs_y => {
                    t.slots[0].y = value;
                    t.slots[0].moved = true;
                },
                else => {},
            },
            evdev.ev_key => if (!t.multitouch and code == evdev.btn_touch) {
                t.slots[0].id = if (value != 0) 0 else -1;
            },
            evdev.ev_syn => if (code == evdev.syn_report) {
                const before = n;
                for (&t.slots) |*sl| {
                    if (n + 2 > out.len) break;
                    // Up (or replaced by another touch).
                    if (sl.reported != -1 and sl.reported != sl.id) {
                        out[n] = .{ .touch = .{ .kind = .up, .id = sl.reported } };
                        n += 1;
                        sl.reported = -1;
                    }
                    if (sl.id == -1) {
                        sl.moved = false;
                        continue;
                    }
                    const x = t.scale(sl.x, 0);
                    const y = t.scale(sl.y, 1);
                    if (sl.reported == -1) {
                        out[n] = .{ .touch = .{ .kind = .down, .id = sl.id, .x = x, .y = y } };
                        n += 1;
                        sl.reported = sl.id;
                    } else if (sl.moved) {
                        out[n] = .{ .touch = .{ .kind = .motion, .id = sl.id, .x = x, .y = y } };
                        n += 1;
                    }
                    sl.moved = false;
                }
                if (n > before and n < out.len) {
                    out[n] = .frame;
                    n += 1;
                }
            },
            else => {},
        }
        return n;
    }

    /// A position as 0 to 1 across its range.
    fn scale(t: *const Touch, v: i32, axis: usize) f64 {
        const r = t.range[axis];
        if (r[1] <= r[0]) return 0;
        return std.math.clamp(@as(f64, @floatFromInt(v - r[0])) / @as(f64, @floatFromInt(r[1] - r[0])), 0, 1);
    }
};

/// linux/input.h's struct input_absinfo.
const AbsInfo = extern struct { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 };

/// The touchscreen a device is, if it is one: it reports absolute
/// positions (multitouch's, or a single touch's).
fn probeTouch(fd: linux.fd_t) ?Touch {
    var abs_bits: [8]u8 = @splat(0);
    const eviocgbit_abs = linux.IOCTL.IOR('E', 0x20 + evdev.ev_abs, [8]u8);
    if (linux.errno(linux.ioctl(fd, eviocgbit_abs, @intFromPtr(&abs_bits))) != .SUCCESS) return null;
    const has = struct {
        fn f(bits: []const u8, bit: u16) bool {
            return bits[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
        }
    }.f;
    const multitouch = has(&abs_bits, evdev.abs_mt_position_x) and has(&abs_bits, evdev.abs_mt_position_y);
    if (!multitouch and !(has(&abs_bits, evdev.abs_x) and has(&abs_bits, evdev.abs_y))) return null;
    var t: Touch = .{ .range = undefined, .multitouch = multitouch };
    const axes = if (multitouch) [2]u16{ evdev.abs_mt_position_x, evdev.abs_mt_position_y } else [2]u16{ evdev.abs_x, evdev.abs_y };
    for (axes, 0..) |a, i| {
        var info: AbsInfo = undefined;
        if (linux.errno(linux.ioctl(fd, linux.IOCTL.IOR('E', @intCast(0x40 + a), AbsInfo), @intFromPtr(&info))) != .SUCCESS) return null;
        t.range[i] = .{ info.minimum, info.maximum };
    }
    return t;
}

/// Whether a device is a mouse: it reports relative motion across.
fn probeMouse(fd: linux.fd_t) bool {
    var rel_bits: [2]u8 = @splat(0);
    const eviocgbit_rel = linux.IOCTL.IOR('E', 0x20 + evdev.ev_rel, [2]u8);
    if (linux.errno(linux.ioctl(fd, eviocgbit_rel, @intFromPtr(&rel_bits))) != .SUCCESS) return false;
    return rel_bits[evdev.rel_x / 8] & (@as(u8, 1) << @intCast(evdev.rel_x % 8)) != 0;
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
    /// The touchscreens' touches.
    touch: [max_devices]?Touch = @splat(null),
    /// Which are mice (they move the pointer by so much: relative motion).
    mouse: [max_devices]bool = @splat(false),
    /// Watching /dev/input (inotify) for nodes made (a device plugged in)
    /// or handed to the user (init does that after): `scan` when it says
    /// so, rather than looking every so often.
    watch: ?linux.fd_t = null,

    /// Starts watching /dev/input, then opens what is there.
    pub fn watchNodes(d: *Devices) void {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) == .SUCCESS) {
            const fd: linux.fd_t = @intCast(rc);
            if (linux.errno(linux.inotify_add_watch(fd, "/dev/input", linux.IN.CREATE | linux.IN.ATTRIB)) == .SUCCESS) {
                d.watch = fd;
            } else sys.close(fd);
        }
        d.scan();
    }

    /// The watch said something changed: what it said is read, and the
    /// nodes are looked at again.
    pub fn nodesChanged(d: *Devices) void {
        const fd = d.watch orelse return;
        var buf: [1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        }
        d.scan();
    }

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
        const path = std.mem.printSentinel(&path_buf, "/dev/input/event{d}", .{n}, 0) catch return;
        // Not handed to the user yet: tried again at the next scan.
        const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }) catch return;
        slot.* = fd;
        d.active[n] = false;
        var name: [64]u8 = @splat(0);
        _ = linux.ioctl(fd, linux.IOCTL.IOR('E', 0x06, [64]u8), @intFromPtr(&name));
        d.touch[n] = probeTouch(fd);
        d.mouse[n] = d.touch[n] == null and probeMouse(fd);
        print("dazzle-shell: input: {s}: {s}{s}\n", .{ path, std.mem.sliceTo(&name, 0), if (d.touch[n] != null) " (touchscreen)" else if (d.mouse[n]) " (mouse)" else "" });
    }

    /// Whether a touchscreen is there (the dock is sized for fingers then).
    pub fn hasTouch(d: *const Devices) bool {
        for (d.fds, d.touch) |slot, t| if (slot != null and t != null) return true;
        return false;
    }

    /// Whether a mouse is plugged in (the pointer is shown only then).
    pub fn hasMouse(d: *const Devices) bool {
        for (d.fds, d.mouse) |slot, m| if (slot != null and m) return true;
        return false;
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
                    d.mouse[i] = false;
                    d.touch[i] = null;
                    print("dazzle-shell: input: /dev/input/event{d} removed\n", .{i});
                };
                sys.close(fd);
                if (e != .NODEV) print(sys.log_error ++ "dazzle-shell: input: read failed ({s})\n", .{@tagName(e)});
                return out[0..0];
            },
        }
        var touch: ?*Touch = null;
        for (&d.fds, 0..) |slot, i| if (slot == fd) {
            if (d.touch[i]) |*t| touch = t;
            if (!d.active[i]) {
                d.active[i] = true;
                print("dazzle-shell: input: first events from /dev/input/event{d}\n", .{i});
            }
        };
        for (raw[0 .. rc / @sizeOf(RawEvent)]) |r| {
            if (n == out.len) break;
            // A touchscreen's events are its touches.
            if (touch) |t| {
                n = t.feed(r.type, r.code, r.value, out, n);
                continue;
            }
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
    try std.testing.expectEqual(Event{ .motion = .{ -3, 0 } }, decode(evdev.ev_rel, evdev.rel_x, -3).?);
    try std.testing.expectEqual(Event{ .motion = .{ 0, 5 } }, decode(evdev.ev_rel, evdev.rel_y, 5).?);
    try std.testing.expectEqual(Event{ .axis = .{ .axis = 0, .value = -15 } }, decode(evdev.ev_rel, evdev.rel_wheel, 1).?);
    try std.testing.expectEqual(Event{ .button = .{ .code = 0x110, .pressed = true } }, decode(evdev.ev_key, 0x110, 1).?);
    try std.testing.expectEqual(Event{ .key = .{ .code = 30, .pressed = false } }, decode(evdev.ev_key, 30, 0).?);
    try std.testing.expectEqual(@as(?Event, null), decode(evdev.ev_key, 30, 2));
    try std.testing.expectEqual(Event.frame, decode(evdev.ev_syn, evdev.syn_report, 0).?);
    try std.testing.expectEqual(@as(?Event, null), decode(0x04, 0, 0)); // EV_MSC
}

test "multitouch: touches go down, move and come up, from 0 to 1" {
    var t: Touch = .{ .range = .{ .{ 0, 1000 }, .{ 0, 500 } }, .multitouch = true };
    var out: [8]Event = undefined;
    var n: usize = 0;
    // A touch in slot 0 at 250,250.
    for ([_][3]i32{ .{ evdev.ev_abs, evdev.abs_mt_slot, 0 }, .{ evdev.ev_abs, evdev.abs_mt_tracking_id, 7 }, .{ evdev.ev_abs, evdev.abs_mt_position_x, 250 }, .{ evdev.ev_abs, evdev.abs_mt_position_y, 250 }, .{ evdev.ev_syn, evdev.syn_report, 0 } }) |e| n = t.feed(@intCast(e[0]), @intCast(e[1]), e[2], &out, n);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Event{ .touch = .{ .kind = .down, .id = 7, .x = 0.25, .y = 0.5 } }, out[0]);
    try std.testing.expectEqual(Event.frame, out[1]);
    // A second finger, and the first moving.
    n = 0;
    for ([_][3]i32{ .{ evdev.ev_abs, evdev.abs_mt_slot, 1 }, .{ evdev.ev_abs, evdev.abs_mt_tracking_id, 8 }, .{ evdev.ev_abs, evdev.abs_mt_position_x, 1000 }, .{ evdev.ev_abs, evdev.abs_mt_position_y, 0 }, .{ evdev.ev_abs, evdev.abs_mt_slot, 0 }, .{ evdev.ev_abs, evdev.abs_mt_position_x, 500 }, .{ evdev.ev_syn, evdev.syn_report, 0 } }) |e| n = t.feed(@intCast(e[0]), @intCast(e[1]), e[2], &out, n);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Event{ .touch = .{ .kind = .motion, .id = 7, .x = 0.5, .y = 0.5 } }, out[0]);
    try std.testing.expectEqual(Event{ .touch = .{ .kind = .down, .id = 8, .x = 1, .y = 0 } }, out[1]);
    // Both up.
    n = 0;
    for ([_][3]i32{ .{ evdev.ev_abs, evdev.abs_mt_tracking_id, -1 }, .{ evdev.ev_abs, evdev.abs_mt_slot, 1 }, .{ evdev.ev_abs, evdev.abs_mt_tracking_id, -1 }, .{ evdev.ev_syn, evdev.syn_report, 0 } }) |e| n = t.feed(@intCast(e[0]), @intCast(e[1]), e[2], &out, n);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Event{ .touch = .{ .kind = .up, .id = 7 } }, out[0]);
    try std.testing.expectEqual(Event{ .touch = .{ .kind = .up, .id = 8 } }, out[1]);
    // Nothing changed: nothing, not even a frame.
    try std.testing.expectEqual(@as(usize, 0), t.feed(evdev.ev_syn, evdev.syn_report, 0, &out, 0));
}

test "single touch: BTN_TOUCH with ABS_X and ABS_Y" {
    var t: Touch = .{ .range = .{ .{ 100, 300 }, .{ 100, 300 } }, .multitouch = false };
    var out: [8]Event = undefined;
    var n: usize = 0;
    for ([_][3]i32{ .{ evdev.ev_key, evdev.btn_touch, 1 }, .{ evdev.ev_abs, evdev.abs_x, 200 }, .{ evdev.ev_abs, evdev.abs_y, 100 }, .{ evdev.ev_syn, evdev.syn_report, 0 } }) |e| n = t.feed(@intCast(e[0]), @intCast(e[1]), e[2], &out, n);
    try std.testing.expectEqual(Event{ .touch = .{ .kind = .down, .id = 0, .x = 0.5, .y = 0 } }, out[0]);
    n = 0;
    for ([_][3]i32{ .{ evdev.ev_key, evdev.btn_touch, 0 }, .{ evdev.ev_syn, evdev.syn_report, 0 } }) |e| n = t.feed(@intCast(e[0]), @intCast(e[1]), e[2], &out, n);
    try std.testing.expectEqual(Event{ .touch = .{ .kind = .up, .id = 0 } }, out[0]);
}
