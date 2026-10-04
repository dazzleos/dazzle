//! Dazzle's settings app: what the system is and how it is doing. It
//! shows the build, Linux's version, how long the system has been up and
//! the board; the resources in use (CPU, temperature, memory, the GPU's
//! memory and storage); the network (adapters, addresses and traffic);
//! and the Wi-Fi networks around. Only this app may scan for them, join
//! one, or choose how Ethernet gets its address: it asks init's network
//! manager, which answers no other program (see sys.network). The figures
//! that change are read again every second (see info.zig); the window is built with the
//! `ui` toolkit (see view.zig), and only what changed is drawn again.
//!
//!     dazzle-settings [font.ttf]
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
        print("dazzle-settings: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print("dazzle-settings: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
            print("dazzle-settings: cannot read the font {s} ({s}); no text\n", .{ font_path, @errorName(err) });
            break :blk null;
        };
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    try window_ui.attachGpu(dev);

    const system = info.System.read();
    print("dazzle-settings: {s}, {d} {s}\n", .{ system.model.slice(), system.cores, if (system.cores == 1) "core" else "cores" });
    var monitor: info.UsageMonitor = .{};
    var usage = monitor.read(sys.nowNs());
    var network = info.Network.read();
    // The network manager is asked less often: each request may start a
    // Wi-Fi scan.
    var report: ?info.manager.Report = null;
    var next_ask: u64 = 0;
    // What the window asks of the network manager (Connect, Disconnect, an
    // Ethernet address).
    var actions: view.Actions = .{};
    // What the title bar's buttons do. Its size stays as it was for the
    // whole screen when the window is restored to half of it.
    var controls: app.Controls = .{ .win = win };
    const bar_scale = @as(f32, @floatFromInt(width)) / 1920;

    var next_update: u64 = sys.nowNs() + std.time.ns_per_s;
    var dirty = true;
    var idle = false;
    var suspended = false;
    while (true) {
        const waited = if (idle) blk: {
            const until = if (suspended) sys.nowNs() + 60 * std.time.ns_per_s else if (window_ui.needs_frame) sys.nowNs() + 16 * std.time.ns_per_ms else next_update;
            break :blk win.wait(@max(until -| sys.nowNs(), std.time.ns_per_ms));
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print("dazzle-settings: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed or controls.quit) return;
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }
        // Covered by another window: nothing is read or drawn, and the
        // window in front gets the GPU memory.
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else next_update = 0;
        }
        const now = sys.nowNs();
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| window_ui.keyEvent(k.code, k.pressed),
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
        };

        // The figures change every second.
        if (!suspended and now >= next_update) {
            next_update = now + std.time.ns_per_s;
            usage = monitor.read(now);
            network = info.Network.read();
            dirty = true;
        }
        if (actions.connect != null or actions.disconnect or actions.ethernet != null) {
            var req_buf: [256]u8 = undefined;
            if (actions.ethernet) |a| report = info.askManager(info.manager.ethernetRequest(&req_buf, a));
            if (actions.connect != null or actions.disconnect) {
                const req = if (actions.connect) |*j| info.manager.connectRequest(&req_buf, j.ssid(), j.passphrase()) else "disconnect\n";
                if (actions.connect) |*j| print("dazzle-settings: joining \"{s}\"\n", .{j.ssid()});
                report = info.askManager(req);
            }
            actions = .{};
            next_ask = sys.nowNs() + std.time.ns_per_s;
            dirty = true;
        }
        if (!suspended and now >= next_ask) {
            // Soon after the first answer (to show what the first scan
            // found) and while joining a network, then every few seconds.
            const busy = if (report) |r| r.scanning or r.connection.state == .connecting or r.connection.state == .authenticating or r.connection.state == .addressing else true;
            next_ask = now + @as(u64, if (busy) 1 else 5) * std.time.ns_per_s;
            report = info.askManager("scan\n");
            dirty = true;
        }

        idle = true;
        if (!suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            window_ui.frame(width, height, now, view.Settings{
                .commit = build_info.commit,
                .system = &system,
                .usage = usage,
                .network = &network,
                .manager = if (report) |*r| r else null,
                .actions = &actions,
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
                .bar_scale = bar_scale,
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
    // Dazzle's compositor listens on /wayland-0; elsewhere, where
    // WAYLAND_DISPLAY and XDG_RUNTIME_DIR say.
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-settings: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Settings") catch |err| {
        print("dazzle-settings: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-settings");
    return win;
}

test {
    _ = info;
    _ = view;
}
