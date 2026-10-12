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
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const ui = @import("ui");
const store = @import("store");
const build_info = @import("build_info");
const names = @import("names.zig");
const view = @import("view.zig");

const proto = sys.system;
const print = sys.print;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    run(init, font_path) catch |err| {
        print(sys.log_error ++ "dazzle-setup: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    const gpa = std.heap.page_allocator;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Setup",
        .app_id = "dazzle-setup",
        .size = view.open_size,
        .font_path = font_path,
    });
    defer a.close();
    a.sync_keyboard = false;

    var name_buf: [32]u8 = undefined;
    const suggestion = names.random(&name_buf);
    // Preparing the card starts now, while the pages are filled in.
    var report: ?proto.Report = ask("prepare\n");
    // The language and keyboard, as they are (until others are picked).
    const start_locale: locale.Settings = if (report) |r| r.locale else .{};
    locale.current = start_locale.language;
    a.ui.keyboard = start_locale.keyboard;
    var next_ask: u64 = sys.nowNs() + 500 * std.time.ns_per_ms;
    var actions: view.Actions = .{};
    // The apps that can be installed (once the card is ready), and those
    // chosen, left to install.
    var apps: store.Store = .init(gpa, build_info.apps_url);
    var retry_at: u64 = 0;
    var queue: ?u64 = null;
    var installed: usize = 0;
    var total: usize = 0;

    while (try a.step(@max(next_ask -| sys.nowNs(), std.time.ns_per_ms))) {
        const now = sys.nowNs();
        a.takeInput();

        // A language or keyboard picked: used now, and kept.
        if (actions.locale) |l| {
            actions.locale = null;
            locale.current = l.language;
            a.ui.keyboard = l.keyboard;
            var req_buf: [64]u8 = undefined;
            _ = ask(std.fmt.bufPrint(&req_buf, "locale {s} {s}\n", .{ l.language.code(), l.keyboard.code() }) catch "");
            a.dirty = true;
        }
        // How preparing goes: often while it does.
        if (now >= next_ask) {
            report = ask("status\n");
            const preparing = if (report) |r| r.storage == .preparing else false;
            next_ask = now + @as(u64, if (preparing) 250 else 1000) * std.time.ns_per_ms;
            a.dirty = true;
        }
        const storage_now: proto.StorageState = if (report) |r| r.storage else .none;
        // The list of apps, kept on the card: once it is ready, and again
        // every while until it comes (the network may come up later).
        if (apps.poll()) a.dirty = true;
        if (storage_now == .ready and apps.job == null and apps.apps().len == 0 and queue == null and now >= retry_at) {
            apps.refresh(true);
            retry_at = now + 10 * std.time.ns_per_s;
            a.dirty = true;
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
                        const item = apps.apps()[@ctz(queue.?)];
                        queue.? &= queue.? - 1;
                        installed = total - @popCount(queue.?) - 1;
                        print("dazzle-setup: installing {s}\n", .{item.name});
                        apps.install(item.name);
                        apps_done = false;
                        a.dirty = true;
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

        try a.draw(now, view.Setup{
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
    }
}

/// Sends the system manager a request (preparing the card can take it a
/// moment to answer).
fn ask(request: []const u8) ?proto.Report {
    return proto.ask(request, 5000);
}

test {
    _ = names;
    _ = view;
}
