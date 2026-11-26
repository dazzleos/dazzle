//! Minimal bindings for the DRM core and KMS (mode setting) ioctls.
//!
//! Structures mirror include/uapi/drm/drm.h and drm_mode.h. They are
//! `extern` so they follow the C ABI of the target, which matters on 32-bit
//! ARM where u64 fields are 8-byte aligned.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const ioctl_base = 'd';
pub const command_base = 0x40;

pub fn IOWR(nr: u8, comptime T: type) u32 {
    return linux.IOCTL.IOWR(ioctl_base, nr, T);
}

pub fn IO(nr: u8) u32 {
    return linux.IOCTL.IO(ioctl_base, nr);
}

/// Issues an ioctl, retrying on EINTR/EAGAIN as libdrm does.
pub fn ioctl(fd: linux.fd_t, request: u32, arg: anytype) sys.Error!void {
    while (true) {
        const rc = linux.ioctl(fd, request, @intFromPtr(arg));
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR, .AGAIN => continue,
            else => |e| return sys.errorFromErrno(e),
        }
    }
}

// --- Core ---------------------------------------------------------------------

pub const Version = extern struct {
    version_major: c_int = 0,
    version_minor: c_int = 0,
    version_patchlevel: c_int = 0,
    name_len: usize = 0,
    name: ?[*]u8 = null,
    date_len: usize = 0,
    date: ?[*]u8 = null,
    desc_len: usize = 0,
    desc: ?[*]u8 = null,
};

pub const GemClose = extern struct {
    handle: u32,
    pad: u32 = 0,
};

pub const IOCTL_VERSION = IOWR(0x00, Version);
pub const IOCTL_GEM_CLOSE = linux.IOCTL.IOW(ioctl_base, 0x09, GemClose);
pub const IOCTL_SET_MASTER = IO(0x1e);
pub const IOCTL_DROP_MASTER = IO(0x1f);

/// Returns the kernel driver name (e.g. "vc4") in `buf`.
pub fn driverName(fd: linux.fd_t, buf: []u8) ![]const u8 {
    var v: Version = .{ .name_len = buf.len, .name = buf.ptr };
    try ioctl(fd, IOCTL_VERSION, &v);
    return buf[0..@min(v.name_len, buf.len)];
}

pub fn gemClose(fd: linux.fd_t, handle: u32) void {
    var arg: GemClose = .{ .handle = handle };
    ioctl(fd, IOCTL_GEM_CLOSE, &arg) catch {};
}

// --- KMS ----------------------------------------------------------------------

pub const ModeCardRes = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};

pub const mode_type_preferred = 1 << 3;

pub const ModeInfo = extern struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type: u32,
    name: [32]u8,

    pub fn nameSlice(m: *const ModeInfo) []const u8 {
        return std.mem.sliceTo(&m.name, 0);
    }
};

pub const ModeGetConnector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,
};

pub const connection_connected = 1;
/// DRM_MODE_CONNECTOR_DSI.
pub const connector_dsi = 16;

pub const ModeGetEncoder = extern struct {
    encoder_id: u32 = 0,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

pub const ModeCrtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode: ModeInfo = std.mem.zeroes(ModeInfo),
};

pub const ModeFbCmd2 = extern struct {
    fb_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pixel_format: u32 = 0,
    flags: u32 = 0,
    handles: [4]u32 = .{ 0, 0, 0, 0 },
    pitches: [4]u32 = .{ 0, 0, 0, 0 },
    offsets: [4]u32 = .{ 0, 0, 0, 0 },
    modifier: [4]u64 = .{ 0, 0, 0, 0 },
};

pub fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

/// 32-bit xRGB, stored as B, G, R, x bytes in memory.
pub const format_xrgb8888 = fourcc("XR24");
/// 32-bit ARGB (premultiplied, as the display blends it), stored as B, G,
/// R, A bytes in memory.
pub const format_argb8888 = fourcc("AR24");

pub const IOCTL_MODE_GETRESOURCES = IOWR(0xa0, ModeCardRes);
pub const IOCTL_MODE_GETCRTC = IOWR(0xa1, ModeCrtc);
pub const IOCTL_MODE_SETCRTC = IOWR(0xa2, ModeCrtc);
pub const IOCTL_MODE_GETENCODER = IOWR(0xa6, ModeGetEncoder);
pub const IOCTL_MODE_GETCONNECTOR = IOWR(0xa7, ModeGetConnector);
pub const IOCTL_MODE_RMFB = IOWR(0xaf, c_uint);
pub const IOCTL_MODE_PAGE_FLIP = IOWR(0xb0, ModeCrtcPageFlip);
pub const IOCTL_MODE_CREATE_DUMB = IOWR(0xb2, ModeCreateDumb);
pub const IOCTL_MODE_MAP_DUMB = IOWR(0xb3, ModeMapDumb);
pub const IOCTL_MODE_ADDFB2 = IOWR(0xb8, ModeFbCmd2);
pub const IOCTL_MODE_GETFB2 = IOWR(0xce, ModeFbCmd2);

pub const ModeCreateDumb = extern struct {
    height: u32,
    width: u32,
    bpp: u32,
    flags: u32 = 0,
    handle: u32 = 0,
    pitch: u32 = 0,
    size: u64 = 0,
};

pub const ModeMapDumb = extern struct {
    handle: u32,
    pad: u32 = 0,
    offset: u64 = 0,
};

pub const ModeCrtcPageFlip = extern struct {
    crtc_id: u32,
    fb_id: u32,
    flags: u32,
    reserved: u32 = 0,
    user_data: u64 = 0,
};

pub const page_flip_event = 0x01;
pub const event_flip_complete = 0x02;

pub const Event = extern struct {
    type: u32,
    length: u32,
};

/// struct drm_event_vblank: a vertical blank or completed page flip.
pub const EventVblank = extern struct {
    base: Event,
    user_data: u64,
    tv_sec: u32,
    tv_usec: u32,
    sequence: u32,
    crtc_id: u32,
};

/// Queues a flip to `fb_id` at the next vertical blank. Completion is
/// reported as an event on the DRM file; see `waitFlip`.
pub fn pageFlip(fd: linux.fd_t, crtc_id: u32, fb_id: u32) !void {
    var arg: ModeCrtcPageFlip = .{ .crtc_id = crtc_id, .fb_id = fb_id, .flags = page_flip_event };
    try ioctl(fd, IOCTL_MODE_PAGE_FLIP, &arg);
}

/// Blocks until a page flip completes.
pub fn waitFlip(fd: linux.fd_t) !void {
    while (try readFlipEvents(fd) == null) {}
}

/// Reads the DRM file's pending events (blocking if there are none).
/// Returns the time of the vertical blank at which a page flip completed,
/// in microseconds on CLOCK_MONOTONIC, if one did.
pub fn readFlipEvents(fd: linux.fd_t) !?u64 {
    var buf: [256]u8 align(8) = undefined;
    const rc = linux.read(fd, &buf, buf.len);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR, .AGAIN => return null,
        else => |e| return sys.errorFromErrno(e),
    }
    return parseFlipEvents(buf[0..rc], null);
}

/// Flips completed on other CRTCs than the one that read them (two
/// displays share a DRM file, and so its events): kept for theirs
/// (`readFlipEventsFor`).
var other_flips: [4]?struct { crtc: u32, at: u64 } = @splat(null);

/// Whether a flip on `crtc_id` was read by another display (and is kept
/// for it): its file will not say so again.
pub fn flipKept(crtc_id: u32) bool {
    for (other_flips) |o| if (o) |f| if (f.crtc == crtc_id) return true;
    return false;
}

/// As `readFlipEvents`, for the flip on `crtc_id`: another's is kept for it.
/// Reads nothing if another display read this one's already. With two
/// displays (`wait` false), it does not wait for events: the other's
/// might be all that come, or none.
pub fn readFlipEventsFor(fd: linux.fd_t, crtc_id: u32, wait: bool) !?u64 {
    for (&other_flips) |*o| if (o.*) |f| if (f.crtc == crtc_id) {
        o.* = null;
        return f.at;
    };
    if (!wait) {
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&pfd, 1, 0) != 1) return null;
    }
    var buf: [256]u8 align(8) = undefined;
    const rc = linux.read(fd, &buf, buf.len);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR, .AGAIN => return null,
        else => |e| return sys.errorFromErrno(e),
    }
    return parseFlipEvents(buf[0..rc], crtc_id);
}

/// The time of the flip in `events` (on `crtc`, if given: those on others
/// are kept in `other_flips`).
fn parseFlipEvents(events: []const u8, crtc: ?u32) ?u64 {
    var flipped: ?u64 = null;
    var off: usize = 0;
    while (off + @sizeOf(Event) <= events.len) {
        const ev = std.mem.bytesToValue(Event, events[off..][0..@sizeOf(Event)]);
        if (ev.length < @sizeOf(Event) or off + ev.length > events.len) break;
        if (ev.type == event_flip_complete and ev.length >= @sizeOf(EventVblank)) {
            const v = std.mem.bytesToValue(EventVblank, events[off..][0..@sizeOf(EventVblank)]);
            const at = @as(u64, v.tv_sec) * std.time.us_per_s + v.tv_usec;
            if (crtc == null or v.crtc_id == crtc.?) {
                flipped = at;
            } else {
                const slot = for (&other_flips) |*o| {
                    if (o.* == null or o.*.?.crtc == v.crtc_id) break o;
                } else &other_flips[0];
                slot.* = .{ .crtc = v.crtc_id, .at = at };
            }
        }
        off += ev.length;
    }
    return flipped;
}

test "flip events" {
    var buf: [64]u8 align(8) = @splat(0);
    const ev: EventVblank = .{ .base = .{ .type = event_flip_complete, .length = 32 }, .user_data = 0, .tv_sec = 12, .tv_usec = 345, .sequence = 1, .crtc_id = 70 };
    @memcpy(buf[32..64], std.mem.asBytes(&ev));
    // Something else first (a vblank event), then the flip.
    std.mem.writeInt(u32, buf[0..4], 0x01, .little);
    std.mem.writeInt(u32, buf[4..8], 32, .little);
    try std.testing.expectEqual(@as(?u64, 12_000_345), parseFlipEvents(&buf, null));
    try std.testing.expectEqual(@as(?u64, null), parseFlipEvents(buf[0..32], null));
    // Another display's: kept for it.
    try std.testing.expectEqual(@as(?u64, null), parseFlipEvents(&buf, 71));
    try std.testing.expectEqual(@as(?u64, 12_000_345), try readFlipEventsFor(-1, 70, true));
}

/// A connected output and the mode and CRTC chosen to drive it.
pub const Output = struct {
    connector_id: u32,
    crtc_id: u32,
    /// The CRTC's position in the card's list, which planes' possible CRTC
    /// masks refer to.
    crtc_index: u32,
    mode: ModeInfo,
    /// On the DSI connector (a display attached to the board: the Touch
    /// Display 2), not HDMI.
    dsi: bool = false,
    /// The port it is on (each keeps its own orientation).
    port: sys.system.Port = .hdmi0,
};

const max_objects = 16;
const max_modes = 64;

/// The display to use: a monitor on HDMI if one is connected, otherwise
/// a display on the DSI connector (one attached to the board, as the
/// Touch Display 2 is). With both, the DSI display is a companion to the
/// HDMI one (`findCompanion`). Its preferred mode (or the first listed),
/// and a CRTC that can drive it.
pub fn findOutput(fd: linux.fd_t) !Output {
    return findOutputOf(fd, false, null) catch |err| switch (err) {
        error.NoConnectedOutput => findOutputOf(fd, true, null),
        else => err,
    };
}

/// A display on the DSI connector besides `main` (on HDMI), on a CRTC of
/// its own; null if there is none.
pub fn findCompanion(fd: linux.fd_t, main: Output) ?Output {
    if (main.dsi) return null;
    return findOutputOf(fd, true, main.crtc_id) catch null;
}

/// The first connected connector on DSI (`want_dsi`) or not, its mode and
/// a CRTC for it (not `not_crtc`).
fn findOutputOf(fd: linux.fd_t, want_dsi: bool, not_crtc: ?u32) !Output {
    var crtcs: [max_objects]u32 = undefined;
    var connectors: [max_objects]u32 = undefined;
    var encoders: [max_objects]u32 = undefined;

    var res: ModeCardRes = .{};
    try ioctl(fd, IOCTL_MODE_GETRESOURCES, &res);
    res = .{
        .crtc_id_ptr = @intFromPtr(&crtcs),
        .connector_id_ptr = @intFromPtr(&connectors),
        .encoder_id_ptr = @intFromPtr(&encoders),
        .count_crtcs = @min(res.count_crtcs, max_objects),
        .count_connectors = @min(res.count_connectors, max_objects),
        .count_encoders = @min(res.count_encoders, max_objects),
    };
    try ioctl(fd, IOCTL_MODE_GETRESOURCES, &res);

    for (connectors[0..res.count_connectors]) |connector_id| {
        var modes: [max_modes]ModeInfo = undefined;
        var conn_encoders: [max_objects]u32 = undefined;

        var conn: ModeGetConnector = .{ .connector_id = connector_id };
        try ioctl(fd, IOCTL_MODE_GETCONNECTOR, &conn);
        if (conn.connection != connection_connected or conn.count_modes == 0) continue;
        if ((conn.connector_type == connector_dsi) != want_dsi) continue;
        conn = .{
            .connector_id = connector_id,
            .modes_ptr = @intFromPtr(&modes),
            .encoders_ptr = @intFromPtr(&conn_encoders),
            .count_modes = @min(conn.count_modes, max_modes),
            .count_encoders = @min(conn.count_encoders, max_objects),
        };
        try ioctl(fd, IOCTL_MODE_GETCONNECTOR, &conn);
        if (conn.count_modes == 0) continue;

        var mode = modes[0];
        for (modes[0..@min(conn.count_modes, max_modes)]) |m| {
            if (m.type & mode_type_preferred != 0) {
                mode = m;
                break;
            }
        }

        // Prefer the CRTC the connector's current encoder is already using;
        // otherwise take any CRTC one of its encoders can be routed to.
        for (conn_encoders[0..@min(conn.count_encoders, max_objects)]) |encoder_id| {
            var enc: ModeGetEncoder = .{ .encoder_id = encoder_id };
            ioctl(fd, IOCTL_MODE_GETENCODER, &enc) catch continue;
            if (encoder_id == conn.encoder_id and enc.crtc_id != 0 and enc.crtc_id != not_crtc) {
                if (std.mem.indexOfScalar(u32, crtcs[0..res.count_crtcs], enc.crtc_id)) |index|
                    return .{ .connector_id = connector_id, .crtc_id = enc.crtc_id, .crtc_index = @intCast(index), .mode = mode, .dsi = want_dsi, .port = .of(want_dsi, conn.connector_type_id) };
            }
            for (crtcs[0..res.count_crtcs], 0..) |crtc_id, index| {
                if (crtc_id == not_crtc) continue;
                if (enc.possible_crtcs & (@as(u32, 1) << @intCast(index)) != 0)
                    return .{ .connector_id = connector_id, .crtc_id = crtc_id, .crtc_index = @intCast(index), .mode = mode, .dsi = want_dsi, .port = .of(want_dsi, conn.connector_type_id) };
            }
        }
    }
    return error.NoConnectedOutput;
}

/// Wraps a GEM buffer as a KMS framebuffer.
pub fn addFramebuffer(fd: linux.fd_t, handle: u32, width: u32, height: u32, pitch: u32, format: u32) !u32 {
    var cmd: ModeFbCmd2 = .{
        .width = width,
        .height = height,
        .pixel_format = format,
        .handles = .{ handle, 0, 0, 0 },
        .pitches = .{ pitch, 0, 0, 0 },
    };
    try ioctl(fd, IOCTL_MODE_ADDFB2, &cmd);
    return cmd.fb_id;
}

pub const ModeCursor = extern struct {
    flags: u32,
    crtc_id: u32,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    handle: u32 = 0,
};

pub const IOCTL_MODE_CURSOR = IOWR(0xa3, ModeCursor);
pub const cursor_bo = 0x01;
pub const cursor_move = 0x02;

/// Shows a linear, premultiplied ARGB8888 buffer (`width` * 4 bytes per row)
/// as the CRTC's cursor; handle 0 hides it. The CRTC must be on.
pub fn setCursor(fd: linux.fd_t, crtc_id: u32, handle: u32, width: u32, height: u32) !void {
    var arg: ModeCursor = .{ .flags = cursor_bo, .crtc_id = crtc_id, .handle = handle, .width = width, .height = height };
    try ioctl(fd, IOCTL_MODE_CURSOR, &arg);
}

/// Moves the cursor's top left corner to (`x`, `y`). It is a plane of its
/// own, so this needs no new frame.
pub fn moveCursor(fd: linux.fd_t, crtc_id: u32, x: i32, y: i32) !void {
    var arg: ModeCursor = .{ .flags = cursor_move, .crtc_id = crtc_id, .x = x, .y = y };
    try ioctl(fd, IOCTL_MODE_CURSOR, &arg);
}

pub const fb_modifiers = 0x02;

/// Like `addFramebuffer`, for a buffer in a layout other than linear, such
/// as the GPU's T tiling.
pub fn addFramebufferWithModifier(fd: linux.fd_t, handle: u32, width: u32, height: u32, pitch: u32, format: u32, modifier: u64) !u32 {
    var cmd: ModeFbCmd2 = .{
        .width = width,
        .height = height,
        .pixel_format = format,
        .flags = fb_modifiers,
        .handles = .{ handle, 0, 0, 0 },
        .pitches = .{ pitch, 0, 0, 0 },
        .modifier = .{ modifier, 0, 0, 0 },
    };
    try ioctl(fd, IOCTL_MODE_ADDFB2, &cmd);
    return cmd.fb_id;
}

pub fn removeFramebuffer(fd: linux.fd_t, fb_id: u32) void {
    var id = fb_id;
    ioctl(fd, IOCTL_MODE_RMFB, &id) catch {};
}

/// Scans out `fb_id` on `output` using a legacy (non-atomic) mode set.
pub fn setCrtc(fd: linux.fd_t, output: Output, fb_id: u32) !void {
    var connector_id = output.connector_id;
    var crtc: ModeCrtc = .{
        .set_connectors_ptr = @intFromPtr(&connector_id),
        .count_connectors = 1,
        .crtc_id = output.crtc_id,
        .fb_id = fb_id,
        .mode_valid = 1,
        .mode = output.mode,
    };
    try ioctl(fd, IOCTL_MODE_SETCRTC, &crtc);
}

/// A framebuffer (another process's, say), with a handle to its buffer
/// in this DRM file: which the kernel gives only the display's master, or
/// a process with CAP_SYS_ADMIN. Close the handle (`gemClose`) when done.
pub fn framebufferInfo(fd: linux.fd_t, fb_id: u32) !ModeFbCmd2 {
    var fb: ModeFbCmd2 = .{ .fb_id = fb_id };
    try ioctl(fd, IOCTL_MODE_GETFB2, &fb);
    if (fb.handles[0] == 0) return error.AccessDenied;
    return fb;
}

/// What the screen shows now (CRTC `crtc_id`'s framebuffer), as a
/// framebuffer of this DRM file's own, made from the same buffer: so it
/// can be shown (on another plane, faded) after the process it was drawn
/// by has gone. Null if there is nothing on the screen, or it cannot be
/// had (see `framebufferInfo`).
pub fn adoptShown(fd: linux.fd_t, crtc_id: u32) ?struct { fb_id: u32, handle: u32, width: u32, height: u32 } {
    const shown = crtcFramebuffer(fd, crtc_id) catch return null;
    if (shown == 0) return null;
    const info = framebufferInfo(fd, shown) catch return null;
    const handle = info.handles[0];
    var fb: ModeFbCmd2 = .{
        .width = info.width,
        .height = info.height,
        .pixel_format = info.pixel_format,
        .flags = info.flags,
        .handles = .{ handle, 0, 0, 0 },
        .pitches = .{ info.pitches[0], 0, 0, 0 },
        .offsets = .{ info.offsets[0], 0, 0, 0 },
        .modifier = .{ info.modifier[0], 0, 0, 0 },
    };
    ioctl(fd, IOCTL_MODE_ADDFB2, &fb) catch {
        gemClose(fd, handle);
        return null;
    };
    return .{ .fb_id = fb.fb_id, .handle = handle, .width = info.width, .height = info.height };
}

/// The framebuffer a CRTC shows (0 if none).
pub fn crtcFramebuffer(fd: linux.fd_t, crtc_id: u32) !u32 {
    var crtc: ModeCrtc = .{ .crtc_id = crtc_id };
    try ioctl(fd, IOCTL_MODE_GETCRTC, &crtc);
    return crtc.fb_id;
}

/// Gives up being the display's master (another process may become it).
pub fn dropMaster(fd: linux.fd_t) !void {
    _ = try sys.check(linux.ioctl(fd, IOCTL_DROP_MASTER, 0));
}

/// A buffer the CPU draws into (32 bits a pixel), mapped.
pub const DumbBuffer = struct {
    handle: u32,
    pitch: u32,
    map: []align(std.heap.page_size_min) u8,

    pub fn create(fd: linux.fd_t, width: u32, height: u32) !DumbBuffer {
        var dumb: ModeCreateDumb = .{ .width = width, .height = height, .bpp = 32 };
        try ioctl(fd, IOCTL_MODE_CREATE_DUMB, &dumb);
        errdefer gemClose(fd, dumb.handle);
        var map: ModeMapDumb = .{ .handle = dumb.handle };
        try ioctl(fd, IOCTL_MODE_MAP_DUMB, &map);
        const rc = linux.mmap(null, @intCast(dumb.size), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(map.offset));
        if (linux.errno(rc) != .SUCCESS) return error.MapFailed;
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
        return .{ .handle = dumb.handle, .pitch = dumb.pitch, .map = ptr[0..@intCast(dumb.size)] };
    }
};

comptime {
    // Sizes from the uapi headers, identical on 32- and 64-bit targets.
    std.debug.assert(@sizeOf(ModeCardRes) == 64);
    std.debug.assert(@sizeOf(ModeCursor) == 28);
    std.debug.assert(@sizeOf(EventVblank) == 32);
    std.debug.assert(@sizeOf(ModeInfo) == 68);
    std.debug.assert(@sizeOf(ModeGetConnector) == 80);
    std.debug.assert(@sizeOf(ModeGetEncoder) == 20);
    std.debug.assert(@sizeOf(ModeCrtc) == 104);
    std.debug.assert(@sizeOf(ModeFbCmd2) == 104);
    std.debug.assert(@sizeOf(ModeCrtcPageFlip) == 24);
    std.debug.assert(@sizeOf(ModeCreateDumb) == 32);
    std.debug.assert(@sizeOf(ModeMapDumb) == 16);
}

/// Like `findOutput`, but waits a few seconds for a display to appear:
/// HDMI hotplug detection can lag behind the driver binding.
pub fn waitForOutput(fd: linux.fd_t) !Output {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        return findOutput(fd) catch |err| {
            if (err != error.NoConnectedOutput or attempt == 50) return err;
            sys.sleepMs(100);
            continue;
        };
    }
}

// --- Buffer sharing (PRIME / dma-buf) ---------------------------------------

const PrimeHandle = extern struct {
    handle: u32,
    flags: u32,
    fd: i32,
};

pub const IOCTL_PRIME_HANDLE_TO_FD = IOWR(0x2d, PrimeHandle);
pub const IOCTL_PRIME_FD_TO_HANDLE = IOWR(0x2e, PrimeHandle);

/// Exports a buffer as a dma-buf file descriptor another process can import.
pub fn exportBuffer(fd: linux.fd_t, handle: u32) !linux.fd_t {
    // DRM_CLOEXEC (O_CLOEXEC, 02000000) | DRM_RDWR (O_RDWR, 2).
    var arg: PrimeHandle = .{ .handle = handle, .flags = 0o2000000 | 2, .fd = -1 };
    try ioctl(fd, IOCTL_PRIME_HANDLE_TO_FD, &arg);
    return arg.fd;
}

/// Imports a dma-buf, returning a GEM handle on this device (to be closed
/// with gemClose). The file descriptor stays open.
pub fn importBuffer(fd: linux.fd_t, dmabuf: linux.fd_t) !u32 {
    var arg: PrimeHandle = .{ .handle = 0, .flags = 0, .fd = dmabuf };
    try ioctl(fd, IOCTL_PRIME_FD_TO_HANDLE, &arg);
    return arg.handle;
}
