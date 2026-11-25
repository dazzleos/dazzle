//! The OS slots, on Dazzle's page (see software_view.zig): what each
//! holds, which is running and which starts next time, with a button to
//! have the other start next (going back to the system before an update,
//! say: it is tried, so if it does not start the running one comes back).
//! If a slot did not start properly, why: how its shell stopped, how long
//! it ran, and what it logged (see failed_start.zig).

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const locale = @import("locale");
const sys_mod = @import("sys");
const update = @import("update.zig");
const view = @import("view.zig");
const failed_start = @import("failed_start.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const proto = sys_mod.system;

/// What the system manager says of the slots.
pub const Slots = struct {
    running: ?u8 = null,
    next: ?u8 = null,
    versions: [2]?proto.Version = .{ null, null },
    /// The slot that last did not start properly, how, and its log (null:
    /// none was kept).
    failed: ?proto.FailedStart = null,
    log: ?*const failed_start.Summary = null,
    /// A slot is being written (no other can be chosen meanwhile).
    busy: bool = false,

    fn version(s: *const Slots, slot: u8) ?*const proto.Version {
        return if (s.versions[slot - 'a']) |*v| v else null;
    }
};

/// Choosing the slot to start next, or restarting into it.
const SlotAct = struct {
    actions: *Actions,
    slot: u8,

    fn choose(x: *SlotAct) void {
        x.actions.boot = x.slot;
    }

    fn restart(x: *SlotAct) void {
        x.actions.restart = true;
    }
};

fn slotName(slot: u8) []const u8 {
    return if (slot == 'a') locale.text("Slot A") else locale.text("Slot B");
}

/// The slots' rows, and why one did not start (if one did not).
pub fn build(self: *const Settings, cx: *kete.BuildContext, rows: *std.ArrayList(kete.Widget)) void {
    const s = &self.slots;
    const running = s.running orelse return;
    const t = &cx.ui.theme;
    const a = cx.arena;
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 16 }, .child = cx.make(kete.Text{ .text = locale.text("OS slots"), .style = .{ .size = 18, .color = t.on_surface } }) })) catch {};
    rows.append(a, cx.make(kete.Text{ .text = locale.text("Dazzle keeps two systems, starting one of them. A slot chosen to start next is tried: if it does not start properly, the one running now starts again."), .style = .{ .size = 15, .color = t.on_surface_variant } })) catch {};
    for ("ab") |slot| rows.append(a, slotRow(self, cx, slot, running)) catch {};
    if (s.failed) |f| failure(cx, f, s.log, s.version(f.slot), rows);
}

fn slotRow(self: *const Settings, cx: *kete.BuildContext, slot: u8, running: u8) kete.Widget {
    const s = &self.slots;
    const t = &cx.ui.theme;
    const a = cx.arena;
    const next = s.next orelse running;
    const v = s.version(slot);
    var date_buf: [32]u8 = undefined;
    const holds = if (v) |have| cx.fmt("{s} · {s}", .{ have.commit(), update.formatDate(&date_buf, have.time) }) else locale.text("Empty");
    // Running, starting next time, not started properly.
    var tags: std.ArrayList(u8) = .empty;
    const failed = if (s.failed) |f| f.slot == slot and slot != running else false;
    for ([_]struct { bool, []const u8 }{
        .{ slot == running, locale.text("Running now") },
        .{ slot == next, locale.text("Starts next time") },
        .{ failed, locale.text("Did not start properly") },
    }) |tag| if (tag[0]) {
        if (tags.items.len > 0) tags.appendSlice(a, " · ") catch {};
        tags.appendSlice(a, tag[1]) catch {};
    };
    var lines: std.ArrayList(kete.Widget) = .empty;
    lines.append(a, cx.make(kete.Text{ .text = slotName(slot), .style = .{ .size = 17, .color = t.on_surface }, .wrap = false })) catch {};
    lines.append(a, cx.make(kete.Text{ .text = holds, .style = .{ .size = 15, .color = t.on_surface_variant } })) catch {};
    if (tags.items.len > 0) lines.append(a, cx.make(kete.Text{ .text = tags.items, .style = .{ .size = 15, .color = if (failed) t.@"error" else t.primary } })) catch {};
    // Restart into the slot starting next; have the other start next.
    var button: kete.Widget = cx.make(kete.SizedBox.empty);
    if (self.actions) |acts| if (v != null) {
        const x = a.create(SlotAct) catch unreachable;
        x.* = .{ .actions = acts, .slot = slot };
        if (slot == next and slot != running) {
            button = cx.make(kete.FilledButton{ .label = locale.text("Restart"), .icon = .restart_alt, .on_press = .of(x, SlotAct.restart) });
        } else if (slot != next) {
            button = cx.make(kete.OutlinedButton{ .label = locale.text("Start this next"), .icon = .history, .on_press = if (s.busy) null else .of(x, SlotAct.choose) });
        }
    };
    return cx.make(kete.Padding{ .padding = .{ .top = 8 }, .child = cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = a.dupe(kete.Widget, &.{
        cx.make(kete.Icon{ .icon = if (slot == running) .check_circle else .storage, .size = 28, .color = if (slot == running) t.primary else t.on_surface_variant }),
        cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = lines.items }) }),
        button,
    }) catch &.{} }) });
}

/// Why `f.slot` did not start properly: how its shell stopped, how long
/// it ran, and what it logged.
fn failure(cx: *kete.BuildContext, f: proto.FailedStart, log: ?*const failed_start.Summary, v: ?*const proto.Version, rows: *std.ArrayList(kete.Widget)) void {
    const t = &cx.ui.theme;
    const a = cx.arena;
    const name = slotName(f.slot);
    var date_buf: [32]u8 = undefined;
    const which = if (v) |have| kete_vc4.textf(cx, "{s} ({s} · {s}) did not start properly", .{ name, have.commit(), update.formatDate(&date_buf, have.time) }) else kete_vc4.textf(cx, "{s} did not start properly", .{name});
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 16 }, .child = cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = a.dupe(kete.Widget, &.{
        cx.make(kete.Icon{ .icon = .error_outline, .size = 24, .color = t.@"error" }),
        cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = which, .style = .{ .size = 17, .color = t.@"error" } }) }),
    }) catch &.{} }) })) catch {};
    const why = switch (f.stop) {
        .exited => |n| kete_vc4.textf(cx, "Its shell could not be run (exit status {d}).", .{n}),
        .signal => |n| switch (n) {
            11 => kete_vc4.textf(cx, "Its shell crashed ({s}, signal {d}: it read or wrote memory it should not have) before it had run a minute.", .{ proto.signalName(n), n }),
            6 => kete_vc4.textf(cx, "Its shell gave up ({s}, signal {d}: it found something wrong and stopped) before it had run a minute.", .{ proto.signalName(n), n }),
            9 => kete_vc4.textf(cx, "Its shell was killed ({s}, signal {d}: perhaps the system ran out of memory) before it had run a minute.", .{ proto.signalName(n), n }),
            else => kete_vc4.textf(cx, "Its shell was stopped by {s} (signal {d}) before it had run a minute.", .{ proto.signalName(n), n }),
        },
        .unknown => if (log != null)
            locale.text("The system did not get as far as running its shell: it hung (and the watchdog restarted it), or the power went.")
        else
            locale.text("Nothing was kept of that start: it stopped before the system could keep its log (the kernel did not start, or the card could not be read), or the power went at once."),
    };
    rows.append(a, cx.make(kete.Text{ .text = why, .style = .{ .size = 15, .color = t.on_surface } })) catch {};
    const l = log orelse return;
    if (l.ran_us) |us| rows.append(a, cx.make(kete.Text{ .text = kete_vc4.textf(cx, "It ran for {d}.{d} seconds after the kernel started.", .{ us / std.time.us_per_s, us % std.time.us_per_s / 100_000 }), .style = .{ .size = 15, .color = t.on_surface } })) catch {};
    if (l.notable_len > 0) {
        heading(cx, locale.text("What went wrong, as it logged"), rows);
        for (l.notableLines()) |line| rows.append(a, logLine(cx, line, true)) catch {};
        if (l.notable_more > 0) rows.append(a, cx.make(kete.Text{ .text = kete_vc4.textf(cx, "and {d} more", .{l.notable_more}), .style = .{ .size = 14, .color = t.on_surface_variant } })) catch {};
    }
    if (l.tail_len > 0) {
        heading(cx, locale.text("The last it logged"), rows);
        for (l.tailLines()) |line| rows.append(a, logLine(cx, line, false)) catch {};
    }
    rows.append(a, cx.make(kete.Text{ .text = kete_vc4.textf(cx, "The whole log is in {s}.", .{proto.failed_start_log}), .style = .{ .size = 14, .color = t.on_surface_variant } })) catch {};
}

fn heading(cx: *kete.BuildContext, text: []const u8, rows: *std.ArrayList(kete.Widget)) void {
    rows.append(cx.arena, cx.make(kete.Padding{ .padding = .{ .top = 8 }, .child = cx.make(kete.Text{ .text = text, .style = .{ .size = 15, .color = cx.ui.theme.on_surface_variant } }) })) catch {};
}

/// A line of the log: its time, and what it says (wrapped: all of it).
fn logLine(cx: *kete.BuildContext, line: []const u8, wrong: bool) kete.Widget {
    const t = &cx.ui.theme;
    const text = failed_start.message(line);
    const time = std.mem.trim(u8, line[0 .. line.len - text.len], "[] ");
    return cx.make(kete.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = cx.arena.dupe(kete.Widget, &.{
        cx.make(kete.SizedBox{ .width = 96, .child = cx.make(kete.Text{ .text = time, .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false, .text_align = .end }) }),
        cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = text, .style = .{ .size = 14, .color = if (wrong) t.@"error" else t.on_surface }, .break_words = true }) }),
    }) catch &.{} });
}

const testing = std.testing;
const font = kete.font;

test "the slots on Dazzle's page, and why one did not start" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const log_text = try testing.allocator.dupe(u8,
        \\[    2.600000] dazzle: trying OS slot B: if its shell does not run, slot A starts next
        \\[    3.100000] dazzle-shell: cannot open /dev/dri/card0: NotFound
        \\[    3.150000] dazzle: shell exited with status 1
        \\
    );
    var log = failed_start.summarize(log_text, "");
    defer log.deinit(testing.allocator);
    var settings: Settings = .{ .commit = "de14aa2 (7 October 2026)", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .slots = .{
        .running = 'a',
        .next = 'a',
        .versions = .{ proto.Version.init(1791331200, "de14aa2").?, proto.Version.init(1791400000, "0123abc").? },
        .failed = .{ .slot = 'b', .stop = .{ .exited = 1 } },
        .log = &log,
    } };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.root.?.state(Settings.State).software.openDazzle();
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "Slot A") != null);
    try testing.expect(view.findText(u.root.?, "Running now · Starts next time") != null);
    try testing.expect(view.findText(u.root.?, "Did not start properly") != null);
    try testing.expect(view.findText(u.root.?, "Slot B (0123abc · 7 October 2026) did not start properly") != null);
    try testing.expect(view.findText(u.root.?, "Its shell could not be run (exit status 1).") != null);
    try testing.expect(view.findText(u.root.?, "It ran for 3.1 seconds after the kernel started.") != null);
    try testing.expect(view.findText(u.root.?, "dazzle-shell: cannot open /dev/dri/card0: NotFound") != null);
    // Slot B chosen to start next (going back to it), then restarting.
    view.click(u, view.up(view.findText(u.root.?, "Start this next").?, kete.OutlinedButton).?);
    try testing.expectEqual(@as(?u8, 'b'), actions.boot);
    settings.slots.next = 'b';
    u.frame(1920, 960, 2, settings);
    try testing.expect(view.findText(u.root.?, "Running now") != null);
    view.click(u, view.up(view.findText(u.root.?, "Restart").?, kete.FilledButton).?);
    try testing.expect(actions.restart);
    // Nothing kept of a start that stopped early.
    settings.slots.failed = .{ .slot = 'b' };
    settings.slots.log = null;
    u.frame(1920, 960, 3, settings);
    try testing.expect(view.findText(u.root.?, "Nothing was kept of that start: it stopped before the system could keep its log (the kernel did not start, or the card could not be read), or the power went at once.") != null);
    try testing.expect(!view.overflows(u.root.?));
}
