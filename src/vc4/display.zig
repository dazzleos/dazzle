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

    /// Shows the back buffer. The first call sets the mode; later calls
    /// queue a page flip and wait for it, which paces rendering to the
    /// display's refresh rate.
    pub fn present(d: *Display) !void {
        const b = d.back();
        if (!d.shown) {
            try drm.setCrtc(d.fd, d.output, b.fb_id);
            d.shown = true;
        } else {
            try drm.pageFlip(d.fd, d.output.crtc_id, b.fb_id);
            try drm.waitFlip(d.fd);
        }
        d.front +%= 1;
    }
};
