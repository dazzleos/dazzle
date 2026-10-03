//! Double-buffered output: two scanout buffers, flipped at vertical blank.

const std = @import("std");
const linux = std.os.linux;
const drm = @import("drm.zig");
const render = @import("render.zig");
const vc4 = @import("device.zig");

pub const Buffer = struct {
    bo: vc4.Bo,
    fb_id: u32,
};

pub const Display = struct {
    fd: linux.fd_t,
    output: drm.Output,
    width: u16,
    height: u16,
    buffers: [2]Buffer,
    /// The buffer currently being scanned out.
    front: u1 = 0,
    shown: bool = false,
    /// A page flip to the back buffer is queued and has not happened yet;
    /// the back buffer must not be drawn into until it has.
    flip_pending: bool = false,

    pub fn init(dev: vc4.Device, output: drm.Output) !Display {
        const width = output.mode.hdisplay;
        const height = output.mode.vdisplay;
        const pitch = render.Target.pitch(width);
        var d: Display = .{
            .fd = dev.fd,
            .output = output,
            .width = width,
            .height = height,
            .buffers = undefined,
        };
        for (&d.buffers, 0..) |*b, i| {
            const bo = try dev.createBo(pitch * height);
            errdefer dev.destroyBo(bo);
            const fb_id = try drm.addFramebuffer(dev.fd, bo.handle, width, height, pitch, drm.format_xrgb8888);
            b.* = .{ .bo = bo, .fb_id = fb_id };
            _ = i;
        }
        return d;
    }

    /// The buffer to render the next frame into.
    pub fn back(d: *const Display) *const Buffer {
        return &d.buffers[d.front +% 1];
    }

    /// The back buffer as a render target.
    pub fn backTarget(d: *const Display) render.Target {
        return .{ .handle = d.back().bo.handle, .width = d.width, .height = d.height };
    }

    /// Shows the back buffer and waits until it is on the screen, which
    /// paces rendering to the display's refresh rate.
    pub fn present(d: *Display) !void {
        if (!try d.queue()) while (try d.handleEvents() == null) {};
    }

    /// Shows the back buffer at the next vertical blank, without waiting:
    /// `handleEvents` reports when it is on the screen. The first call sets
    /// the mode, which shows the buffer at once; it returns true then.
    pub fn queue(d: *Display) !bool {
        std.debug.assert(!d.flip_pending);
        const b = d.back();
        if (!d.shown) {
            try drm.setCrtc(d.fd, d.output, b.fb_id);
            d.shown = true;
            d.front +%= 1;
            return true;
        }
        try drm.pageFlip(d.fd, d.output.crtc_id, b.fb_id);
        d.flip_pending = true;
        return false;
    }

    /// Reads the DRM file's events; call it when the file is readable.
    /// Returns the vertical blank's time (microseconds, CLOCK_MONOTONIC)
    /// if the queued flip has happened.
    pub fn handleEvents(d: *Display) !?u64 {
        const t = try drm.readFlipEvents(d.fd) orelse return null;
        if (!d.flip_pending) return null;
        d.flip_pending = false;
        d.front +%= 1;
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
