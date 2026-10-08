//! Dazzle's setup app: runs on the first start only, with the whole screen
//! (the shell shows no dock while it runs). It asks for the computer's name
//! and the apps to install (and, later, more), a page at a time (see
//! view.zig), while init's system manager makes the SD card's free space a
//! place for files (see sys.system). The list of apps is downloaded once
//! that is ready (they are kept there; see the store module). Then it
//! installs the apps chosen, tells the manager to finish, which names the
//! computer and marks setup done, and ends. It lives in /os/shell with the
//! shell: it cannot be removed.
//!
//!     dazzle-setup [font.ttf]

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const store = @import("store");
const build_info = @import("build_info");
const names = @import("names.zig");
const view = @import("view.zig");

const proto = sys.system;
const print = sys.print;

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

var frame: vc4.render.Frame = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    run(init, font_path) catch |err| {
        print("dazzle-setup: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print("dazzle-setup: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
            print("dazzle-setup: cannot read the font {s} ({s}); no text\n", .{ font_path, @errorName(err) });
            break :blk null;
        };
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    // Copying and pasting go through the system's clipboard.
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

    var name_buf: [32]u8 = undefined;
    const suggestion = names.random(&name_buf);
    // Preparing the card starts now, while the pages are filled in.
    var report: ?proto.Report = ask("prepare\n");
    // The language and keyboard, as they are (until others are picked).
    const start_locale: locale.Settings = if (report) |r| r.locale else .{};
    locale.current = start_locale.language;
    window_ui.keyboard = start_locale.keyboard;
    var next_ask: u64 = sys.nowNs() + 500 * std.time.ns_per_ms;
    var actions: view.Actions = .{};
    // The apps that can be installed (once the card is ready), and those
    // chosen, left to install.
    var apps: store.Store = .init(gpa, build_info.apps_url);
    var retry_at: u64 = 0;
    var queue: ?u64 = null;
    var installed: usize = 0;
    var total: usize = 0;

    var dirty = true;
    var idle = false;
    while (true) {
        const waited = if (idle) blk: {
            const until = if (window_ui.needs_frame) sys.nowNs() + 16 * std.time.ns_per_ms else next_ask;
            break :blk win.wait(@max(until -| sys.nowNs(), std.time.ns_per_ms));
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print("dazzle-setup: compositor error: {s}\n", .{win.conn.errorMessage()});
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
            .key => |k| window_ui.keyEvent(k.code, k.pressed),
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
        };

        // A language or keyboard picked: used now, and kept.
        if (actions.locale) |l| {
            actions.locale = null;
            locale.current = l.language;
            window_ui.keyboard = l.keyboard;
            var req_buf: [64]u8 = undefined;
            _ = ask(std.fmt.bufPrint(&req_buf, "locale {s} {s}\n", .{ l.language.code(), l.keyboard.code() }) catch "");
            dirty = true;
        }
        // How preparing goes: often while it does.
        if (now >= next_ask) {
            report = ask("status\n");
            const preparing = if (report) |r| r.storage == .preparing else false;
            next_ask = now + @as(u64, if (preparing) 250 else 1000) * std.time.ns_per_ms;
            dirty = true;
        }
        const storage_now: proto.StorageState = if (report) |r| r.storage else .none;
        // The list of apps, kept on the card: once it is ready, and again
        // every while until it comes (the network may come up later).
        if (apps.poll()) dirty = true;
        if (storage_now == .ready and apps.job == null and apps.apps().len == 0 and queue == null and now >= retry_at) {
            apps.refresh(true);
            retry_at = now + 10 * std.time.ns_per_s;
            dirty = true;
        }
        // The pages are done: finish once the card is ready (or there is
        // none, or it failed and that has been accepted), after installing
        // the apps chosen.
        if (actions.finish) |h| {
            const storage: proto.StorageState = if (report) |r| r.storage else .none;
            const can = switch (storage) {
                .ready, .none => true,
                .failed => actions.without_storage,
                .preparing, .unprepared => false,
            };
            // The apps first (with a card to put them on), one at a time.
            var apps_done = true;
            if (can and storage == .ready) {
                if (apps.job != null) {
                    apps_done = false;
                } else {
                    if (queue == null) {
                        const n = @min(apps.apps().len, view.max_apps);
                        queue = actions.apps & if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
                        total = @popCount(queue.?);
                    }
                    if (queue.? != 0) {
                        const a = apps.apps()[@ctz(queue.?)];
                        queue.? &= queue.? - 1;
                        installed = total - @popCount(queue.?) - 1;
                        print("dazzle-setup: installing {s}\n", .{a.name});
                        apps.install(a.name);
                        apps_done = false;
                        dirty = true;
                    }
                }
            }
            if (can and apps_done) {
                var req_buf: [96]u8 = undefined;
                const req = std.fmt.bufPrint(&req_buf, "finish {s}\n", .{h.slice()}) catch "";
                _ = ask(req);
                print("dazzle-setup: finished; the computer is {s}\n", .{h.slice()});
                return;
            }
        }

        idle = true;
        if (!win.suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            window_ui.fullscreen = win.fullscreen;
            window_ui.frame(width, height, now, view.Setup{
                .suggestion = suggestion,
                .locale = start_locale,
                .report = if (report) |*r| r else null,
                .apps = .{
                    .list = apps.apps(),
                    .loading = apps.job != null,
                    .message = apps.message(),
                    .installing = if (apps.busy()) |name| (if (name.len > 0) apps.title(name) else null) else null,
                    .done = installed,
                    .total = total,
                },
                .actions = &actions,
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
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
    }
}

/// Sends the system manager a request (preparing the card can take it a
/// moment to answer).
fn ask(request: []const u8) ?proto.Report {
    return proto.ask(request, 5000);
}

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    // Dazzle's compositor listens on /os/sockets/wayland-0; elsewhere, where
    // WAYLAND_DISPLAY and XDG_RUNTIME_DIR say.
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-setup: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Setup") catch |err| {
        print("dazzle-setup: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-setup");
    return win;
}

test {
    _ = names;
    _ = view;
}
