//! Stardust's settings app: what the system is and how it is doing. It
//! shows the build, Linux's version and how long the system has been up;
//! the hardware (board, chip, CPU, GPU, memory); what is in use (CPU,
//! temperature, memory, the GPU's memory and the system's files); and the
//! network (adapters, addresses and traffic). The figures that change are
//! read again every second (see info.zig); the window is built with the
//! `ui` toolkit (see view.zig), and only what changed is drawn again.
//!
//!     stardust-settings [font.ttf]
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const build_info = @import("build_info");
const info = @import("info.zig");
const view = @import("view.zig");

const print = sys.print;

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

var frame: vc4.render.Frame = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse (sys.appFile(&font_buf, font.default_font_file) catch font.default_font_file);
    run(init, font_path) catch |err| {
        print("stardust-settings: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print("stardust-settings: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
            print("stardust-settings: cannot read the font {s} ({s}); no text\n", .{ font_path, @errorName(err) });
            break :blk null;
        };
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    try window_ui.attachGpu(dev);

    const hardware = info.Hardware.read(dev);
    print("stardust-settings: {s}, {s}, {s} x{d}\n", .{ hardware.model.slice(), hardware.soc.slice(), hardware.cpu.slice(), hardware.cores });
    var monitor: info.UsageMonitor = .{};
    var usage = monitor.read(sys.nowNs());
    var network = info.Network.read();

    var next_update: u64 = sys.nowNs() + std.time.ns_per_s;
    var dirty = true;
    var idle = false;
    while (true) {
        const waited = if (idle) blk: {
            const until = if (window_ui.needs_frame) sys.nowNs() + 16 * std.time.ns_per_ms else next_update;
            break :blk win.wait(@max(until -| sys.nowNs(), std.time.ns_per_ms));
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print("stardust-settings: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed) return;
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }
        const now = sys.nowNs();
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => {},
        };

        // The figures change every second.
        if (now >= next_update) {
            next_update = now + std.time.ns_per_s;
            usage = monitor.read(now);
            network = info.Network.read();
            dirty = true;
        }

        idle = true;
        if (dirty or window_ui.needs_frame) {
            dirty = false;
            window_ui.frame(width, height, now, view.Settings{
                .commit = build_info.commit,
                .hardware = &hardware,
                .usage = usage,
                .network = &network,
                .scale = view.scaleFor(width, height),
            });
            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame);
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
    }
}

/// Opens a window on the Wayland compositor.
fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    const display_name = Environ.getPosix(init.environ, "WAYLAND_DISPLAY") orelse {
        print("stardust-settings: WAYLAND_DISPLAY is not set; run me under stardust-shell\n", .{});
        return error.NoCompositor;
    };
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), display_name) catch {
        print("stardust-settings: XDG_RUNTIME_DIR is not set\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Settings") catch |err| {
        print("stardust-settings: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("stardust-settings");
    return win;
}

test {
    _ = info;
    _ = view;
}
