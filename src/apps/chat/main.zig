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
//! People are known by the computer's name (Settings). It runs until its
//! window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const ui = @import("ui");
const net = @import("net.zig");
const protocol = @import("protocol.zig");
const view = @import("view.zig");

const print = sys.print;

/// What a room is called if it was started without a name.
const default_room_name = "Chat Room";

/// How long to wait for anything, with nothing to draw: timers (announcing
/// a room, pinging, letting go of rooms not heard of) are due this often.
const idle_ns = std.time.ns_per_s;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-chat: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// The computer's name, which is what others see (the kernel's, set from
/// the name chosen when the system was set up).
fn hostname(buf: *[64]u8) []const u8 {
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return "dazzle";
    const n = std.mem.indexOfScalar(u8, &uts.nodename, 0) orelse uts.nodename.len;
    if (n == 0) return "dazzle";
    const len = @min(n, buf.len);
    @memcpy(buf[0..len], uts.nodename[0..len]);
    return buf[0..len];
}

fn run(init: std.process.Init.Minimal) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;

    var name_buf: [64]u8 = undefined;
    var network = try net.Net.init(gpa, .{ .name = hostname(&name_buf) });
    defer network.deinit();

    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Chat",
        .app_id = "dazzle-chat",
        .size = view.open_size,
        .min_size = view.min_size,
    });
    defer a.close();
    // The sockets wake the window.
    a.win.wake_fd = network.epfd;

    var actions: view.Actions = .{};

    while (try a.step(idle_ns)) {
        const now = sys.nowNs();
        a.takeInput();
        if (network.service(now)) a.dirty = true;
        if (apply(&actions, &network, now)) a.dirty = true;

        var names: [protocol.max_peers + 1][]const u8 = undefined;
        try a.draw(now, view.Chat{
            .node = network.node,
            .ads = network.ads.items,
            .room = if (network.room) |*r| r else null,
            .members = network.members(&names),
            .message = network.message,
            .actions = &actions,
        });
    }
}

/// Does what the window asked. Returns whether anything changed.
fn apply(actions: *view.Actions, network: *net.Net, now: u64) bool {
    var changed = false;
    if (actions.dismiss) {
        actions.dismiss = false;
        network.message = "";
        changed = true;
    }
    if (actions.join) |room| {
        actions.join = null;
        network.join(room, now);
        actions.draft_len = 0;
        changed = true;
    }
    if (actions.create) {
        actions.create = false;
        const typed = std.mem.trim(u8, actions.roomName(), " \t");
        network.create(if (typed.len == 0) default_room_name else typed, now);
        actions.room_name_len = 0;
        actions.draft_len = 0;
        changed = true;
    }
    if (actions.leave) {
        actions.leave = false;
        network.leave();
        actions.room_name_len = 0;
        actions.draft_len = 0;
        changed = true;
    }
    if (actions.send) {
        actions.send = false;
        if (std.mem.trim(u8, actions.draft(), " \t").len > 0) {
            network.say(actions.draft());
            // The field starts again, empty.
            actions.draft_len = 0;
            actions.draft_key += 1;
            changed = true;
        }
    }
    return changed;
}

test {
    _ = protocol;
    _ = net;
    _ = view;
}
