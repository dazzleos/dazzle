//! Double-buffered output: two scanout buffers, flipped at vertical blank.
//! With atomic mode setting it can also show other buffers on the
//! display's planes (`queueLayers`), such as a client's window.

const std = @import("std");
const linux = std.os.linux;
const drm = @import("drm.zig");
const render = @import("render.zig");
const vc4 = @import("device.zig");
const kms_mod = @import("kms.zig");
const Format = @import("format.zig").Format;

pub const Buffer = struct {
    bo: vc4.Bo,
    fb_id: u32,
};

pub const Display = struct {
    fd: linux.fd_t,
    output: drm.Output,
    width: u16,
    height: u16,
    format: Format,
    buffers: [2]Buffer,
    /// Atomic mode setting, when the driver supports it: needed to show
    /// other buffers (`queueLayers`). Otherwise the legacy calls are used.
    kms: ?kms_mod.Kms,
    /// Which of `buffers` is on the screen; null before the first frame
    /// and while `queueLayers` buffers are shown.
    on_screen: ?u1 = null,
    /// A frame is queued and has not reached the screen yet; the buffers
    /// must not change until it has.
    flip_pending: bool = false,
    /// What the queued frame shows: one of `buffers`, or null for layers.
    pending_buffer: ?u1 = null,

    /// Two linear buffers of the display's size, in `format`.
    pub fn init(dev: vc4.Device, output: drm.Output, format: Format) !Display {
        const width = output.mode.hdisplay;
        const height = output.mode.vdisplay;
        const pitch = render.Target.pitch(format, width);
        var d: Display = .{
            .format = format,
            .fd = dev.fd,
            .output = output,
            .width = width,
            .height = height,
            .buffers = undefined,
            .kms = kms_mod.Kms.init(dev.fd, output) catch null,
        };
        for (&d.buffers) |*b| {
            const bo = try dev.createBo(pitch * height);
            errdefer dev.destroyBo(bo);
            const fb_id = try drm.addFramebuffer(dev.fd, bo.kmsHandle(), width, height, pitch, format.fourcc());
            b.* = .{ .bo = bo, .fb_id = fb_id };
        }
        return d;
    }

    fn backIndex(d: *const Display) u1 {
        return if (d.on_screen) |i| i +% 1 else 0;
    }

    /// The buffer to render the next frame into.
    pub fn back(d: *const Display) *const Buffer {
        return &d.buffers[d.backIndex()];
    }

    /// The back buffer as a render target.
    pub fn backTarget(d: *const Display) render.Target {
        return .{ .handle = d.back().bo.handle, .width = d.width, .height = d.height, .format = d.format };
    }

    /// Shows the back buffer and waits until it is on the screen, which
    /// paces rendering to the display's refresh rate.
    pub fn present(d: *Display) !void {
        if (!try d.queue()) while (try d.handleEvents() == null) {};
    }

    /// The whole screen, showing one of `buffers`.
    fn fullScreen(d: *const Display, i: u1) kms_mod.Layer {
        return .{ .fb_id = d.buffers[i].fb_id, .src_width = d.width, .src_height = d.height, .x = 0, .y = 0, .width = d.width, .height = d.height };
    }

    /// Shows the back buffer at the next vertical blank, without waiting:
    /// `handleEvents` reports when it is on the screen. The first frame
    /// sets the mode, which shows it at once; this returns true then.
    pub fn queue(d: *Display) !bool {
        std.debug.assert(!d.flip_pending);
        const i = d.backIndex();
        const at_once = if (d.kms) |*k|
            try k.commit(d.fullScreen(i), @splat(null))
        else if (d.on_screen == null) blk: {
            try drm.setCrtc(d.fd, d.output, d.buffers[i].fb_id);
            break :blk true;
        } else blk: {
            try drm.pageFlip(d.fd, d.output.crtc_id, d.buffers[i].fb_id);
            break :blk false;
        };
        if (at_once) {
            d.on_screen = i;
        } else {
            d.flip_pending = true;
            d.pending_buffer = i;
        }
        return at_once;
    }

    /// Whether `queueLayers` can show these layers.
    pub fn canShow(d: *const Display, primary: kms_mod.Layer, overlays: kms_mod.Overlays) bool {
        const k = &(d.kms orelse return false);
        return k.check(primary, overlays);
    }

    /// Like `queue`, but shows other buffers (framebuffers made with
    /// `drm.addFramebuffer`) on the display's planes instead.
    pub fn queueLayers(d: *Display, primary: kms_mod.Layer, overlays: kms_mod.Overlays) !bool {
        std.debug.assert(!d.flip_pending);
        const k = &(d.kms orelse return error.Unsupported);
        const at_once = try k.commit(primary, overlays);
        if (at_once) {
            d.on_screen = null;
        } else {
            d.flip_pending = true;
            d.pending_buffer = null;
        }
        return at_once;
    }

    /// Reads the DRM file's events; call it when the file is readable.
    /// Returns the vertical blank's time (microseconds, CLOCK_MONOTONIC)
    /// if the queued frame has reached the screen.
    pub fn handleEvents(d: *Display) !?u64 {
        const t = try drm.readFlipEvents(d.fd) orelse return null;
        if (!d.flip_pending) return null;
        d.flip_pending = false;
        d.on_screen = d.pending_buffer;
        return t;
    }

    /// The time between vertical blanks, in microseconds.
    pub fn refreshPeriodUs(d: *const Display) u64 {
        const m = d.output.mode;
        const pixels = @as(u64, m.htotal) * m.vtotal;
        if (m.clock == 0 or pixels == 0) return std.time.us_per_s / 60;
        // The clock is in kHz.
        return pixels * std.time.us_per_ms / m.clock;
    }
};
