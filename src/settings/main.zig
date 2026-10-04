//! Stardust's settings app: what the system is and how it is doing. It
//! shows the build, Linux's version, how long the system has been up and
//! the board; the resources in use (CPU, temperature, memory, the GPU's
//! memory and storage); the network (adapters, addresses and traffic);
//! and the Wi-Fi networks around. Only this app may scan for them: it asks
//! init's Wi-Fi manager, which answers no other program (see sys.wifi). The figures that change are
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

    const system = info.System.read();
    print("stardust-settings: {s}, {d} {s}\n", .{ system.model.slice(), system.cores, if (system.cores == 1) "core" else "cores" });
    var monitor: info.UsageMonitor = .{};
    var usage = monitor.read(sys.nowNs());
    var network = info.Network.read();
    // The Wi-Fi manager is asked less often: each request may start a scan.
    const runtime_dir = std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR");
    var wifi: ?info.wifi.Report = null;
    var next_wifi: u64 = 0;
    // What the window asks of the Wi-Fi manager (Connect, Disconnect).
    var actions: view.Actions = .{};
    // The title bar's close button.
    var quit: Quit = .{};

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
            if (err == error.ServerError) print("stardust-settings: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed or quit.requested) return;
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
        };

        // The figures change every second.
        if (!suspended and now >= next_update) {
            next_update = now + std.time.ns_per_s;
            usage = monitor.read(now);
            network = info.Network.read();
            dirty = true;
        }
        if (actions.connect != null or actions.disconnect) if (runtime_dir) |dir| {
            var req_buf: [256]u8 = undefined;
            const req = if (actions.connect) |*j| info.wifi.connectRequest(&req_buf, j.ssid(), j.passphrase()) else "disconnect\n";
            if (actions.connect) |*j| print("stardust-settings: joining \"{s}\"\n", .{j.ssid()});
            wifi = info.askWifi(dir, req);
            actions = .{};
            next_wifi = sys.nowNs() + std.time.ns_per_s;
            dirty = true;
        };
        if (!suspended and now >= next_wifi) {
            // Soon after the first answer (to show what the first scan
            // found) and while joining a network, then every few seconds.
            const busy = if (wifi) |w| w.scanning or w.connection.state == .connecting or w.connection.state == .authenticating or w.connection.state == .addressing else true;
            next_wifi = now + @as(u64, if (busy) 1 else 5) * std.time.ns_per_s;
            wifi = if (runtime_dir) |dir| info.askWifi(dir, "scan\n") else null;
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
                .wifi = if (wifi) |*w| w else null,
                .actions = &actions,
                .on_close = .of(&quit, Quit.request),
                .bar_scale = @as(f32, @floatFromInt(width)) / 1920,
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

const Quit = struct {
    requested: bool = false,

    fn request(q: *Quit) void {
        q.requested = true;
    }
};

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
