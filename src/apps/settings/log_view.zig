//! The Debug page: the system's log, newest first, with when each message
//! came (since the system started) and what it says, warnings and errors
//! in colour; or only those. And whether it is served over HTTP, for
//! reading in a browser on another computer (off unless turned on: anyone
//! on the network can read it).

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const locale = @import("locale");
const kete_vc4 = @import("kete_vc4");
const gfx = kete.gfx;
const log = @import("log.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Builder = view.Builder;
const Actions = view.Actions;

/// "Debug": the log, and what developers turn on (serving the log,
/// remote control).
pub const label = "Debug";
pub const icon: kete.IconName = .bug_report;

const log_row_height = 26;

/// Warnings in the log.
const warning_color = gfx.Color.argb(0xffe6b450);

pub const State = struct {
    /// The log shows only warnings and errors.
    problems: bool = false,

    pub fn setProblems(st: *State, on: bool) void {
        st.problems = on;
    }
};

pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const a = cx.arena;
    const problems = cx.make(kete.SwitchRow{ .value = state.problems, .on_changed = .of(state, State.setProblems), .label = locale.text("Only warnings and errors") });
    const serving = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 10, .children = cx.makeAll(.{ serveRow(self, b), remoteRow(self, b) }) });
    const l = self.log orelse return b.page(&.{ serving, problems, b.value(locale.text("Reading the log…")) });
    if (l.failed) return b.page(&.{ serving, b.value(locale.text("The log cannot be read")) });
    // The lines shown, newest first.
    var shown: std.ArrayList(*const log.Line) = .empty;
    for (0..l.count) |i| {
        const line = l.newest(i);
        if (!state.problems or line.level.problem()) shown.append(a, line) catch break;
    }
    const lines = a.create(LogLines) catch return cx.make(kete.SizedBox.empty);
    lines.* = .{ .lines = shown.items };
    return b.page(&.{
        serving,
        problems,
        if (shown.items.len == 0) b.value(if (state.problems) "No warnings or errors" else "Nothing yet") else cx.make(kete.Grid.list(shown.items.len, log_row_height, .of(lines, LogLines.row))),
    });
}

/// Whether the log is served over HTTP, turned on and off here, and where
/// to read it while it is.
fn serveRow(self: *const Settings, b: Builder) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    // Unknown until the system manager says.
    const on = self.log_server orelse return cx.make(kete.SizedBox.empty);
    const host = self.system.hostname.slice();
    const note = if (!on)
        locale.text("Lets other computers on the network read the log in a browser. Anyone on the network can read it.")
    else if (host.len > 0)
        kete_vc4.textf(cx, "Anyone on the network can read the log at http://{s}/ (and http://{s}/follow as it is written).", .{ host, host })
    else
        locale.text("Anyone on the network can read the log, at this computer's address.");
    return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 4, .children = &.{
        cx.make(kete.SwitchRow{
            .value = on,
            .on_changed = if (self.actions) |a| .of(a, setLogServer) else null,
            .label = locale.text("Serve the log over HTTP"),
        }),
        cx.make(kete.Text{ .text = note, .style = .{ .size = 14, .color = t.on_surface_variant } }),
    } });
}

fn setLogServer(a: *Actions, on: bool) void {
    a.log_server = on;
}

/// Whether other computers on the network may control this one (for
/// testing Dazzle from another computer), and the code they need.
fn remoteRow(self: *const Settings, b: Builder) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const host = self.system.hostname.slice();
    const note = if (self.remote_code) |code|
        kete_vc4.textf(cx, "Code {d}. With it, a computer on the network can move the pointer, type, open and close apps and windows, take screenshots, install updates and restart, at http://{s}:{d}/. Turn this off when you are done.", .{ code, if (host.len > 0) host else locale.text("this computer"), sys.remote.port })
    else
        "For testing Dazzle from another computer: it can then move the pointer, type, open and close apps and windows, take screenshots, install updates and restart, with a code shown here.";
    return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 4, .children = &.{
        cx.make(kete.SwitchRow{
            .value = self.remote_code != null,
            .on_changed = if (self.actions) |a| .of(a, setRemote) else null,
            .label = locale.text("Let other computers control this one"),
        }),
        cx.make(kete.Text{ .text = note, .style = .{ .size = 14, .color = t.on_surface_variant } }),
    } });
}

fn setRemote(a: *Actions, on: bool) void {
    a.remote = on;
}

/// The log's lines, to make rows of (in the frame's arena).
const LogLines = struct {
    lines: []const *const log.Line,

    fn row(l: *const LogLines, cx: *kete.BuildContext, i: usize) kete.Widget {
        const t = cx.theme();
        const line = l.lines[i];
        var time_buf: [32]u8 = undefined;
        const color = switch (line.level) {
            .emergency, .alert, .critical, .@"error" => t.@"error",
            .warning => warning_color,
            else => t.on_surface,
        };
        return cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
            cx.make(kete.SizedBox{ .width = 96, .child = cx.make(kete.Text{ .text = cx.fmt("{s}", .{log.formatUptime(&time_buf, line.usec)}), .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false, .text_align = .end }) }),
            cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = line.text(), .style = .{ .size = 14, .color = color }, .wrap = false, .ellipsis = true }) }),
        } });
    }
};

const testing = std.testing;
const font = kete.font;

test "the log: newest first, or only its warnings and errors" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var l: log.Log = .{};
    l.add("6,1,1500000,-;dazzle: starting as init\n");
    l.add("4,2,2000000,-;dazzle: network: no answer from the time servers\n");
    l.add("3,3,3250000,-;dazzle-files: error: OutOfMemory\n");
    l.add("6,4,65000000,-;dazzle-shell: started\n");
    const settings: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .log = &l };
    u.frame(1600, 900, 0, settings);
    const st = u.root.?.state(Settings.State);
    st.page = .log;
    for (view.test_sizes) |size| {
        u.frame(size[0], size[1], 1, settings);
        try testing.expect(!view.overflows(u.root.?));
    }
    u.frame(1600, 900, 2, settings);
    // Newest first, with when.
    const newest = view.findText(u.root.?, "dazzle-shell: started").?;
    const oldest = view.findText(u.root.?, "dazzle: starting as init").?;
    try testing.expect(newest.position()[1] < oldest.position()[1]);
    try testing.expect(view.findText(u.root.?, "1:05.000") != null);
    try testing.expect(view.findText(u.root.?, "3.250") != null);
    // Only the problems.
    view.click(u, view.up(view.findText(u.root.?, "Only warnings and errors").?, kete.SwitchRow).?);
    u.frame(1600, 900, 3, settings);
    try testing.expect(view.findText(u.root.?, "dazzle-shell: started") == null);
    try testing.expect(view.findText(u.root.?, "dazzle-files: error: OutOfMemory") != null);
    try testing.expect(view.findText(u.root.?, "dazzle: network: no answer from the time servers") != null);
    // Serving it over HTTP: off, then turned on (and the address shown).
    try testing.expect(view.findText(u.root.?, "Serve the log over HTTP") == null);
    var actions: Actions = .{};
    const off: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .log = &l, .log_server = false, .actions = &actions };
    u.frame(1600, 900, 4, off);
    view.click(u, view.up(view.findText(u.root.?, "Serve the log over HTTP").?, kete.SwitchRow).?);
    u.frame(1600, 900, 5, off);
    try testing.expectEqual(@as(?bool, true), actions.log_server);
    try testing.expect(view.findTextContaining(u.root.?, "http://awesome-elephant/") == null);
    const on: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .log = &l, .log_server = true, .actions = &actions };
    u.frame(1600, 900, 6, on);
    try testing.expect(view.findTextContaining(u.root.?, "http://awesome-elephant/") != null);
    for (view.test_sizes) |size| {
        u.frame(size[0], size[1], 7, on);
        try testing.expect(!view.overflows(u.root.?));
    }
    // Not read yet, and none to show.
    const reading: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net };
    u.frame(1600, 900, 8, reading);
    try testing.expect(view.findText(u.root.?, "Reading the log…") != null);
}

test "remote control is turned on and off, and its code shown while on" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var l: log.Log = .{};
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .log = &l, .log_server = false, .actions = &actions };
    u.frame(1600, 900, 0, settings);
    u.root.?.state(Settings.State).page = .log;
    u.frame(1600, 900, 1, settings);
    view.click(u, view.up(view.findText(u.root.?, "Let other computers control this one").?, kete.SwitchRow).?);
    try testing.expectEqual(@as(?bool, true), actions.remote);
    settings.remote_code = 482913;
    u.frame(1600, 900, 2, settings);
    try testing.expect(view.findTextContaining(u.root.?, "Code 482913") != null);
    try testing.expect(view.findTextContaining(u.root.?, "http://awesome-elephant:8080/") != null);
    actions = .{};
    view.click(u, view.up(view.findText(u.root.?, "Let other computers control this one").?, kete.SwitchRow).?);
    try testing.expectEqual(@as(?bool, false), actions.remote);
    for (view.test_sizes) |size| {
        u.frame(size[0], size[1], 3, settings);
        try testing.expect(!view.overflows(u.root.?));
    }
}
