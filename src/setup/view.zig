//! The setup app's window, as widgets: a page at a time, each with a Next
//! button (and Back after the first), filling the screen. The pages:
//!
//! * the computer's name, filled in with a random one;
//!
//! then finishing: if the SD card is still being prepared, a spinner says
//! how far it has got (it started when setup did); if it could not be, why
//! (and Continue). What the window asks of the system manager goes to the
//! main loop through `Actions`.

const std = @import("std");
const ui = @import("ui");
const sys = @import("sys");

const proto = sys.system;

/// The pages, in order. More (language, keyboard, network) can follow.
pub const Page = enum { hostname };
pub const pages = [_]Page{.hostname};

/// What the window asks for; the main loop does it.
pub const Actions = struct {
    /// The pages are done: finish, with this name.
    finish: ?proto.Hostname = null,
    /// Finish even though the card could not be prepared.
    without_storage: bool = false,
};

/// Sizes are designed for a window 900 pixels high (and 1600 wide), and
/// scale with it.
pub fn scaleFor(width: u32, height: u32) f32 {
    return std.math.clamp(@min(@as(f32, @floatFromInt(width)) / 1600, @as(f32, @floatFromInt(height)) / 900), 0.6, 2);
}

pub const Setup = struct {
    scale: f32,
    /// The name to start with.
    suggestion: []const u8,
    /// What the system manager last said; null if it could not be asked.
    report: ?*const proto.Report = null,
    actions: ?*Actions = null,

    pub const State = struct {
        page: usize = 0,
        /// Past the last page.
        finishing: bool = false,
        name_buf: [63]u8 = undefined,
        name_len: u8 = 0,
        name_invalid: bool = false,

        fn name(st: *const State) []const u8 {
            return st.name_buf[0..st.name_len];
        }

        fn setName(st: *State, text: []const u8) void {
            st.name_len = @intCast(@min(text.len, st.name_buf.len));
            @memcpy(st.name_buf[0..st.name_len], text[0..st.name_len]);
            st.name_invalid = false;
        }
    };

    pub fn initState(self: *const Setup) State {
        var st: State = .{};
        st.setName(self.suggestion);
        return st;
    }

    pub fn build(self: *const Setup, cx: *ui.Context, state: *State) ui.Widget {
        const s = self.scale;
        const nav = cx.ui.arena().create(Nav) catch return cx.make(ui.Empty{});
        nav.* = .{ .state = state, .actions = self.actions };
        const content = if (state.finishing) self.finishing(cx, nav) else self.page(cx, state, nav);
        return cx.make(ui.Decorated{ .color = cx.theme().surface, .child = cx.make(ui.Center{ .child = cx.make(ui.SizedBox{
            .width = @round(720 * s),
            .child = cx.make(ui.Padding{ .padding = .all(@round(24 * s)), .child = content }),
        }) }) });
    }

    /// A page: its heading, what it asks, and the buttons.
    fn page(self: *const Setup, cx: *ui.Context, state: *State, nav: *Nav) ui.Widget {
        const s = self.scale;
        const t = cx.theme();
        const body = switch (pages[state.page]) {
            .hostname => self.hostnamePage(cx, state, nav),
        };
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = @round(24 * s), .children = &.{
            cx.make(ui.Text{ .text = "Welcome to Dazzle", .style = .{ .size = 40 * s, .color = t.primary } }),
            body,
            cx.make(ui.Row{ .spacing = @round(12 * s), .main_axis_alignment = .end, .children = &.{
                if (state.page > 0) cx.make(ui.OutlinedButton{ .label = "Back", .on_press = .of(nav, Nav.back) }) else cx.make(ui.Empty{}),
                cx.make(ui.OutlinedButton{ .label = "Next", .on_press = .of(nav, Nav.next) }),
            } }),
        } });
    }

    fn hostnamePage(self: *const Setup, cx: *ui.Context, state: *State, nav: *Nav) ui.Widget {
        const s = self.scale;
        const t = cx.theme();
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = @round(12 * s), .children = &.{
            cx.make(ui.Text{ .text = "Name this computer", .style = .{ .size = 28 * s } }),
            cx.make(ui.Text{
                .text = "Other computers on the network know it by this name. It can have lowercase letters, numbers and hyphens.",
                .style = .{ .size = 18 * s, .color = t.on_surface_variant },
            }),
            cx.make(ui.TextField{
                .initial = state.name(),
                .max_len = state.name_buf.len,
                .size = 20 * s,
                .width = @round(400 * s),
                .on_changed = .of(state, State.setName),
                .on_submit = .of(nav, Nav.next),
            }),
            if (state.name_invalid) cx.make(ui.Text{
                .text = "Use 1 to 63 lowercase letters, numbers and hyphens, not starting or ending with a hyphen",
                .style = .{ .size = 16 * s, .color = t.@"error" },
            }) else cx.make(ui.Empty{}),
        } });
    }

    /// After the last page: waiting for the card, or why it could not be
    /// prepared.
    fn finishing(self: *const Setup, cx: *ui.Context, nav: *Nav) ui.Widget {
        const s = self.scale;
        const t = cx.theme();
        const r = self.report;
        if (r != null and r.?.storage == .failed) {
            return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = @round(16 * s), .children = &.{
                cx.make(ui.Text{ .text = "The SD card could not be prepared", .style = .{ .size = 28 * s } }),
                cx.make(ui.Text{
                    .text = cx.fmt("Dazzle cannot keep files: {s}. Setup will run again when the computer next starts.", .{r.?.failure.label()}),
                    .style = .{ .size = 18 * s, .color = t.on_surface_variant },
                }),
                cx.make(ui.Row{ .main_axis_alignment = .end, .children = &.{
                    cx.make(ui.OutlinedButton{ .label = "Continue", .on_press = .of(nav, Nav.continueWithout) }),
                } }),
            } });
        }
        const progress = if (r) |rep| (if (rep.storage == .preparing) cx.fmt("{d}%", .{rep.progress}) else "") else "";
        return cx.make(ui.Column{ .main_axis_size = .min, .spacing = @round(20 * s), .children = &.{
            cx.make(ui.Spinner{ .size = @round(64 * s) }),
            cx.make(ui.Text{ .text = "Getting the SD card ready", .style = .{ .size = 24 * s } }),
            cx.make(ui.Text{ .text = progress, .style = .{ .size = 18 * s, .color = t.on_surface_variant } }),
        } });
    }
};

/// The buttons.
const Nav = struct {
    state: *Setup.State,
    actions: ?*Actions,

    fn next(n: *Nav) void {
        const st = n.state;
        switch (pages[st.page]) {
            .hostname => if (proto.Hostname.parse(st.name()) == null) {
                st.name_invalid = true;
                return;
            },
        }
        if (st.page + 1 < pages.len) {
            st.page += 1;
            return;
        }
        st.finishing = true;
        if (n.actions) |a| a.finish = proto.Hostname.parse(st.name());
    }

    fn back(n: *Nav) void {
        n.state.page -|= 1;
    }

    fn continueWithout(n: *Nav) void {
        if (n.actions) |a| a.without_storage = true;
    }
};

// --- Tests ---------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");

fn overflows(node: *ui.Node) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.as(ui.Text)) |t| if (std.mem.eql(u8, t.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

fn findType(n: *ui.Node, comptime T: type) ?*ui.Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

fn click(u: *ui.Ui, n: *ui.Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.widgets.btn_left, true);
    u.pointerButton(p, ui.widgets.btn_left, false);
}

test "naming the computer, then waiting for the card" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var actions: Actions = .{};
    var report: proto.Report = .{ .storage = .preparing, .progress = 10 };
    var now: u64 = 0;
    const Draw = struct {
        fn draw(uu: *ui.Ui, r: *const proto.Report, a: *Actions, n: *u64, size: [2]u32) void {
            n.* += 1;
            uu.frame(size[0], size[1], n.*, Setup{ .scale = scaleFor(size[0], size[1]), .suggestion = "awesome-elephant", .report = r, .actions = a });
        }
    }.draw;
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    // The suggestion is filled in.
    const field = findType(u.root.?, ui.TextField).?;
    try testing.expectEqualStrings("awesome-elephant", field.state(ui.TextField.State).text());

    // Not a hostname: it says so, and stays.
    const st = u.root.?.state(Setup.State);
    st.setName("Not OK");
    click(u, findText(u.root.?, "Next").?);
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expect(st.name_invalid and !st.finishing);
    try testing.expect(actions.finish == null);

    // A good one: finishing, with a spinner while the card is prepared.
    st.setName("my-pi");
    click(u, findText(u.root.?, "Next").?);
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expectEqualStrings("my-pi", actions.finish.?.slice());
    try testing.expect(findType(u.root.?, ui.Spinner) != null);
    try testing.expect(findText(u.root.?, "10%") != null);
    try testing.expect(u.needs_frame);

    // If it fails: why, and Continue.
    report = .{ .storage = .failed, .failure = .too_small };
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expect(findType(u.root.?, ui.Spinner) == null);
    click(u, findText(u.root.?, "Continue").?);
    try testing.expect(actions.without_storage);
}
