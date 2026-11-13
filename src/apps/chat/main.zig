//! Dazzle's Chat: talk to the other people on the network, in rooms. Anyone
//! can start a room; it is announced on the local network (see net.zig),
//! so everyone running Chat sees it listed and can join. A room lasts as
//! long as someone is in it: whoever started it can leave, and the others
//! carry on. Everyone in a room keeps all of its history, in the same
//! order, so someone who joins gets it from whoever they reach first (see
//! protocol.zig).
//!
//!     dazzle-chat
//!
//! People are known by the name chosen in its settings, or else the
//! computer's name (see settings.zig). It runs until its window is closed.

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const net = @import("net.zig");
const protocol = @import("protocol.zig");
const view = @import("view.zig");
const settings = @import("settings.zig");

const print = sys.print;

/// What a room is called if it was started without a name.
const default_room_name = "Chat Room";

/// How long to wait for anything, with nothing to draw: timers (announcing
/// a room, pinging, letting go of rooms not heard of) are due this often.
const idle_ns = std.time.ns_per_s;

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-chat: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// The window's root: the rooms, and the one joined, as they are now.
const Root = struct {
    network: *net.Net,
    host: []const u8,
    actions: *view.Actions,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        const network = r.network;
        const names = cx.arena.alloc([]const u8, protocol.max_peers + 1) catch return cx.make(kete.SizedBox.empty);
        return cx.make(view.Chat{
            .node = network.node,
            .ads = network.ads.items,
            .room = if (network.room) |*room| room else null,
            .members = network.members(names[0 .. protocol.max_peers + 1]),
            .message = network.message,
            .name = network.name.get(),
            .default_name = r.host,
            .actions = r.actions,
        });
    }
};

fn run(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;

    var host_buf: [64]u8 = undefined;
    const host_name = settings.hostname(&host_buf);
    var name_buf: [128]u8 = undefined;
    var network = try net.Net.init(gpa, .{ .name = settings.loadName(settings.name_file, &name_buf, host_name) });
    defer network.deinit();

    var host: kete_vc4.Host = undefined;
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-chat" });
    defer host.deinit();
    // The sockets wake the loop.
    host.wakeOn(network.epfd, true);

    var actions: view.Actions = .init(gpa);
    defer actions.deinit();
    const root: Root = .{ .network = &network, .host = host_name, .actions = &actions };
    const window = try host.app.openWindow(.{
        .title = "Chat",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .on_close_request = .close,
    });

    var title_buf: [64]u8 = undefined;
    var title: []const u8 = "Chat";
    while (try host.step(idle_ns)) {
        const now = sys.nowNs();
        if (network.service(now)) host.redraw();
        if (apply(&actions, &network, host_name, now)) host.redraw();
        // The title is the room's name, in one.
        const wanted = view.windowTitle(if (network.room) |*r| r else null);
        if (!std.mem.eql(u8, wanted, title)) {
            const n = @min(wanted.len, title_buf.len);
            @memcpy(title_buf[0..n], wanted[0..n]);
            title = title_buf[0..n];
            window.setTitle(title);
        }
    }
}

/// Does what the window asked. Returns whether anything changed.
fn apply(actions: *view.Actions, network: *net.Net, host: []const u8, now: u64) bool {
    var changed = false;
    if (actions.open_settings) {
        actions.open_settings = false;
        actions.settings_open = true;
        actions.name.setText(network.name.get());
        changed = true;
    }
    if (actions.save_settings) {
        actions.save_settings = false;
        actions.settings_open = false;
        network.rename(settings.saveName(settings.name_file, actions.name.text(), host));
        changed = true;
    }
    if (actions.dismiss) {
        actions.dismiss = false;
        network.message = "";
        changed = true;
    }
    if (actions.join) |room| {
        actions.join = null;
        network.join(room, now);
        actions.draft.setText("");
        changed = true;
    }
    if (actions.create) {
        actions.create = false;
        const typed = std.mem.trim(u8, actions.room_name.text(), " \t");
        network.create(if (typed.len == 0) default_room_name else typed, now);
        actions.room_name.setText("");
        actions.draft.setText("");
        changed = true;
    }
    if (actions.leave) {
        actions.leave = false;
        network.leave();
        actions.room_name.setText("");
        actions.draft.setText("");
        changed = true;
    }
    if (actions.send) {
        actions.send = false;
        if (std.mem.trim(u8, actions.draft.text(), " \t").len > 0) {
            network.say(actions.draft.text());
            // The field starts again, empty.
            actions.draft.setText("");
            changed = true;
        }
    }
    return changed;
}

test {
    _ = protocol;
    _ = net;
    _ = view;
    _ = settings;
}
