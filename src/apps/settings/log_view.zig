//! The Log page: the system's log, newest first, with when each message
//! came (since the system started) and what it says, warnings and errors
//! in colour; or only those.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const log = @import("log.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Builder = view.Builder;

pub const label = "Log";
pub const icon: ui.icons.Icon = .article;

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

pub fn build(self: *const Settings, b: Builder, state: *State) ui.Widget {
    const cx = b.cx;
    const a = cx.ui.arena();
    const problems = cx.make(ui.Switch{ .value = state.problems, .on_changed = .of(state, State.setProblems), .label = "Only warnings and errors" });
    const l = self.log orelse return b.page(&.{ problems, b.value("Reading the log…") });
    if (l.failed) return b.page(&.{b.value("The log cannot be read")});
    // The lines shown, newest first.
    var shown: std.ArrayList(*const log.Line) = .empty;
    for (0..l.count) |i| {
        const line = l.newest(i);
        if (!state.problems or line.level.problem()) shown.append(a, line) catch break;
    }
    const lines = a.create(LogLines) catch return cx.make(ui.Empty{});
    lines.* = .{ .lines = shown.items };
    return b.page(&.{
        problems,
        if (shown.items.len == 0) b.value(if (state.problems) "No warnings or errors" else "Nothing yet") else cx.make(ui.LazyGrid{
            .count = shown.items.len,
            .cell = .{ .w = std.math.inf(f32), .h = log_row_height },
            .item = .of(lines, LogLines.row),
        }),
    });
}

/// The log's lines, to make rows of (in the frame's arena).
const LogLines = struct {
    lines: []const *const log.Line,

    fn row(l: *const LogLines, cx: *ui.Context, i: usize) ui.Widget {
        const t = cx.theme();
        const line = l.lines[i];
        var time_buf: [32]u8 = undefined;
        const color = switch (line.level) {
            .emergency, .alert, .critical, .@"error" => t.@"error",
            .warning => warning_color,
            else => t.on_surface,
        };
        return cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
            cx.make(ui.SizedBox{ .width = 96, .child = cx.make(ui.Text{ .text = cx.fmt("{s}", .{log.formatUptime(&time_buf, line.usec)}), .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false, .text_align = .end }) }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = line.text(), .style = .{ .size = 14, .color = color }, .wrap = false, .ellipsis = true }) }),
        } });
    }
};

const testing = std.testing;
const font = @import("font");

test "the log: newest first, or only its warnings and errors" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
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
    view.click(u, view.up(view.findText(u.root.?, "Only warnings and errors").?, ui.Switch).?);
    u.frame(1600, 900, 3, settings);
    try testing.expect(view.findText(u.root.?, "dazzle-shell: started") == null);
    try testing.expect(view.findText(u.root.?, "dazzle-files: error: OutOfMemory") != null);
    try testing.expect(view.findText(u.root.?, "dazzle: network: no answer from the time servers") != null);
    // Not read yet, and none to show.
    const reading: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net };
    u.frame(1600, 900, 4, reading);
    try testing.expect(view.findText(u.root.?, "Reading the log…") != null);
}
