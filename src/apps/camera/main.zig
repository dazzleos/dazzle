//! Dazzle's Camera app: shows what the Raspberry Pi Camera Module sees,
//! and takes photos, saved with the user's files as "Photo 1.png",
//! "Photo 2.png" and so on.
//!
//! Frames come raw from the sensor (capture.zig) and are made pictures of
//! here, on the CPU (isp.zig): a preview the size of the window for each
//! frame, with the white balance worked out from it (the grey world) and
//! the exposure too (exposure.zig) for a sensor without its own (the
//! IMX219; the OV5647's own is turned on). A photo is the latest frame
//! developed at its full size, which a child process does, compresses and
//! writes, so the preview goes on meanwhile.
//!
//!     dazzle-camera [font.ttf]
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const gfx = @import("gfx");
const wayland = @import("wayland");
const capture = @import("capture.zig");
const isp = @import("isp.zig");
const exposure = @import("exposure.zig");
const v4l2 = @import("v4l2.zig");
const view = @import("view.zig");

const print = sys.print;

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

const no_camera = "No camera found. Connect a Raspberry Pi Camera Module (v1 or v2) to the camera connector while the Pi is off, then start it again.";

var frame: vc4.render.Frame = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    run(init, font_path) catch |err| {
        print(sys.log_error ++ "dazzle-camera: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// What the camera shows and does: its frames made pictures of.
const Viewer = struct {
    gpa: std.mem.Allocator,
    cam: capture.Camera,
    params: isp.Params = .{},
    tables: isp.Tables,
    /// Exposure, if the app does it (rather than the sensor).
    ae: ?exposure.Exposure = null,
    /// Two pictures: one shown, one being made.
    pixels: [2][]u32,
    shown: u1 = 0,
    image: ?gfx.Image = null,
    /// Take a photo of the next frame.
    shoot: bool = false,
    /// The photo being saved, on a thread.
    saving: ?*Saving = null,
    /// Under the picture (`status`).
    status_buf: [128]u8 = undefined,
    status_len: usize = 0,

    fn init(gpa: std.mem.Allocator, cam: capture.Camera) !Viewer {
        const most = @as(usize, cam.width / 2) * (cam.height / 2);
        var v: Viewer = .{
            .gpa = gpa,
            .cam = cam,
            .tables = .init(.{}),
            .pixels = .{ try gpa.alloc(u32, most), try gpa.alloc(u32, most) },
        };
        v.setUpExposure();
        v.setStatus("{s}, {d}×{d}", .{ cam.sensorName(), cam.width, cam.height });
        return v;
    }

    fn setStatus(v: *Viewer, comptime fmt: []const u8, args: anytype) void {
        v.status_len = if (std.fmt.bufPrint(&v.status_buf, fmt, args)) |t| t.len else |_| 0;
    }

    fn status(v: *const Viewer) []const u8 {
        return v.status_buf[0..v.status_len];
    }

    /// The sensor's own automatic exposure and white balance, if it has
    /// them (the OV5647); otherwise the app's exposure.
    fn setUpExposure(v: *Viewer) void {
        const c = &v.cam;
        if (c.range(v4l2.cid.exposure_auto) != null) {
            c.setControl(v4l2.cid.exposure_auto, v4l2.exposure_auto_on) catch {};
            c.setControl(v4l2.cid.autogain, 1) catch {};
            c.setControl(v4l2.cid.auto_white_balance, 1) catch {};
            return;
        }
        if (!std.mem.startsWith(u8, c.sensorName(), "imx219 ")) return;
        const lines = c.control(v4l2.cid.exposure) orelse return;
        const gain = c.control(v4l2.cid.analogue_gain) orelse return;
        v.ae = .{ .model = .imx219, .current = .{ .lines = lines, .gain_code = gain } };
    }

    /// Makes a picture of the newest frame (older ones are dropped), at
    /// most `max_width` by `max_height`. Returns whether there is a new one.
    fn update(v: *Viewer, max_width: u32, max_height: u32) !bool {
        var latest: ?capture.Frame = null;
        while (try v.cam.next()) |f| {
            if (latest) |old| v.cam.release(old);
            latest = f;
        }
        const f = latest orelse return false;
        // A frame being saved as a photo is kept until it has been.
        var keep = false;
        defer if (!keep) v.cam.release(f);
        const raw: isp.Raw = .{ .data = f.data, .width = v.cam.width, .height = v.cam.height, .stride = v.cam.stride, .bayer = v.cam.format.bayer, .bits = v.cam.format.bits };
        if (f.data.len < @as(usize, raw.stride) * raw.height) return false;
        if (v.shoot) {
            v.shoot = false;
            keep = v.savePhoto(raw, f);
        }

        const size = isp.previewSize(raw.width, raw.height, @max(max_width, 16), @max(max_height, 16));
        const next = v.shown +% 1;
        const out = v.pixels[next][0 .. @as(usize, size.width) * size.height];
        const stats = isp.preview(raw, &v.tables, v.params.black, out, size.width, size.height, size.step);
        v.image = .init(out, size.width, size.height);
        v.shown = next;

        // White balance and exposure for the frames to come.
        v.params.gains = isp.greyWorld(v.params.gains, stats);
        v.tables = .init(v.params);
        if (v.ae) |*ae| {
            const exp_range = v.cam.range(v4l2.cid.exposure) orelse return true;
            const gain_range = v.cam.range(v4l2.cid.analogue_gain) orelse return true;
            if (ae.update(stats.mean[1], .{ .min_lines = exp_range.min, .max_lines = exp_range.max, .min_gain_code = gain_range.min, .max_gain_code = gain_range.max })) |s| {
                v.cam.setControl(v4l2.cid.exposure, s.lines) catch {};
                v.cam.setControl(v4l2.cid.analogue_gain, s.gain_code) catch {};
            }
        }
        return true;
    }

    fn requestPhoto(v: *Viewer) void {
        if (v.saving == null) v.shoot = true;
    }

    /// Saves `raw` (the frame `f`, which is kept until it has been) as
    /// the next "Photo N.png", on a thread. Returns whether it is being.
    fn savePhoto(v: *Viewer, raw: isp.Raw, f: capture.Frame) bool {
        const s = v.gpa.create(Saving) catch {
            v.setStatus("Cannot save a photo", .{});
            return false;
        };
        s.* = .{ .gpa = v.gpa, .raw = raw, .frame = f, .tables = v.tables, .thread = undefined };
        const path = sys.files.numberedName(&s.path_buf, sys.system.user_dir, "Photo", "png") orelse {
            v.gpa.destroy(s);
            v.setStatus("Cannot save a photo here", .{});
            return false;
        };
        s.path_len = path.len;
        s.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Saving.run, .{s}) catch {
            v.gpa.destroy(s);
            v.setStatus("Cannot save a photo", .{});
            return false;
        };
        v.saving = s;
        v.setStatus("Saving {s}…", .{s.name()});
        return true;
    }

    /// Whether the photo being saved has been (or failed).
    fn checkSaving(v: *Viewer) bool {
        const s = v.saving orelse return false;
        if (!s.done.load(.acquire)) return false;
        s.thread.join();
        v.cam.release(s.frame);
        v.saving = null;
        if (s.ok) v.setStatus("Saved {s} with your files", .{s.name()}) else v.setStatus("{s} could not be saved", .{s.name()});
        v.gpa.destroy(s);
        return true;
    }
};

/// A photo being saved: developed from the raw frame, compressed and
/// written, on a thread.
const Saving = struct {
    gpa: std.mem.Allocator,
    raw: isp.Raw,
    frame: capture.Frame,
    /// The colour tables as they were (the viewer's change with each frame).
    tables: isp.Tables,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    thread: std.Thread,
    done: std.atomic.Value(bool) = .init(false),
    /// Whether it was saved (read once `done`).
    ok: bool = false,

    fn name(s: *const Saving) []const u8 {
        return std.fs.path.basename(s.path_buf[0..s.path_len]);
    }

    fn run(s: *Saving) void {
        defer s.done.store(true, .release);
        const path = s.path_buf[0..s.path_len :0];
        const pixels = s.gpa.alloc(u32, @as(usize, s.raw.width) * s.raw.height) catch return;
        defer s.gpa.free(pixels);
        isp.develop(s.raw, &s.tables, pixels);
        const data = gfx.png.encode(s.gpa, pixels, s.raw.width, s.raw.height) catch return;
        defer s.gpa.free(data);
        sys.files.writeNew(path, data) catch |err| {
            print(sys.log_warning ++ "dazzle-camera: cannot write {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        print("dazzle-camera: saved {s}\n", .{path});
        s.ok = true;
    }
};

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    // The language chosen (in setup, or Settings).
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print(sys.log_error ++ "dazzle-camera: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
            print(sys.log_warning ++ "dazzle-camera: cannot read the font {s} ({s}); no text\n", .{ font_path, @errorName(err) });
            break :blk null;
        };
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

    var viewer: ?Viewer = blk: {
        const cam = capture.Camera.open() catch |err| {
            print("dazzle-camera: no camera ({s})\n", .{@errorName(err)});
            break :blk null;
        };
        break :blk try Viewer.init(gpa, cam);
    };
    if (viewer) |*v| win.wake_fd = v.cam.fd();

    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);

    var dirty = true;
    var idle = false;
    var suspended = false;
    while (true) {
        const waited = if (idle) blk: {
            // Frames wake the window (`wake_fd`); otherwise wait for input.
            const timeout: u64 = if (window_ui.needs_frame and !suspended) 16 * std.time.ns_per_ms else if (viewer != null) std.time.ns_per_s else 60 * std.time.ns_per_s;
            break :blk win.wait(timeout);
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print(sys.log_error ++ "dazzle-camera: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed or controls.quit) {
            // A photo being saved is finished first.
            if (viewer) |*v| if (v.saving) |sv| sv.thread.join();
            return;
        }
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else dirty = true;
        }
        const now = sys.nowNs();
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => {},
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
        };
        if (viewer) |*v| {
            if (v.checkSaving()) dirty = true;
            // Covered: frames are still taken (and dropped), not shown.
            const picture_h = height -| view.chrome_height;
            if (try v.update(width, picture_h) and !suspended) dirty = true;
        }

        idle = true;
        if (!suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            const v: ?*Viewer = if (viewer) |*vw| vw else null;
            window_ui.fullscreen = win.fullscreen;
            window_ui.frame(width, height, now, view.Camera{
                .preview = if (v) |vw| if (vw.image) |*img| img else null else null,
                .message = if (v) |vw| (if (vw.image == null) "Starting the camera…" else "") else no_camera,
                .status = if (v) |vw| vw.status() else "",
                .on_shoot = if (v) |vw| (if (vw.saving == null) ui.Callback.of(vw, Viewer.requestPhoto) else null) else null,
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
            });
            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame, win.flusher());
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *dv| dv.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
    }
}

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-camera: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Camera") catch |err| {
        print(sys.log_warning ++ "dazzle-camera: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-camera");
    return win;
}

test {
    _ = v4l2;
    _ = capture;
    _ = isp;
    _ = exposure;
    _ = view;
}
