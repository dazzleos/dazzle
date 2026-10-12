//! The setup app's window, as widgets: a page at a time, each with a Next
//! button (Finish on the last, and Back after the first), filling the
//! screen. The pages:
//!
//! * the language and the keyboard (which changes with the language, until
//!   one is picked), with a field to try the keyboard in;
//! * the computer's name, filled in with a random one;
//! * the apps to install (the image has none), from the catalogue, all
//!   chosen to begin with;
//!
//! then finishing: if the SD card is still being prepared, a spinner says
//! how far it has got (it started when setup did); if it could not be, why
//! (and Continue); then the apps chosen are installed, one at a time. What
//! the window asks for goes to the main loop through `Actions`.

const std = @import("std");
const ui = @import("ui");
const sys = @import("sys");
const store = @import("store");
const locale = @import("locale");

const proto = sys.system;

/// The pages, in order. More (the network, say) can follow.
/// The size the window opens at: one step at a time.
pub const open_size = [2]u32{ 880, 620 };

pub const Page = enum { language, hostname, apps };
pub const pages = [_]Page{ .language, .hostname, .apps };

/// The most apps that can be chosen (the catalogue's first).
pub const max_apps = 64;

/// What the window asks for; the main loop does it.
pub const Actions = struct {
    /// The pages are done: finish, with this name.
    finish: ?proto.Hostname = null,
    /// Finish even though the card could not be prepared.
    without_storage: bool = false,
    /// The apps to install: bit i for the catalogue's app i.
    apps: u64 = 0,
    /// The language or keyboard picked (to use now, and keep).
    locale: ?locale.Settings = null,
};

/// What the apps page shows.
pub const Apps = struct {
    /// The catalogue's apps.
    list: []const store.App = &.{},
    /// Getting the catalogue.
    loading: bool = false,
    /// Why it could not be got.
    message: []const u8 = "",
    /// Installing: which app (its title), and how far through.
    installing: ?[]const u8 = null,
    done: usize = 0,
    total: usize = 0,
};

/// Everything is the same size in pixels, whatever the window's: the card
/// in the middle of it.
pub const Setup = struct {
    /// The name to start with.
    suggestion: []const u8,
    /// The language and keyboard to start with.
    locale: locale.Settings = .{},
    /// What the system manager last said; null if it could not be asked.
    report: ?*const proto.Report = null,
    apps: Apps = .{},
    actions: ?*Actions = null,

    pub const State = struct {
        page: usize = 0,
        /// Past the last page.
        finishing: bool = false,
        name_buf: [63]u8 = undefined,
        name_len: u8 = 0,
        name_invalid: bool = false,
        /// The apps not chosen: bit i for the catalogue's app i.
        skipped: u64 = 0,
        language: locale.Language = .en_us,
        keyboard: locale.Keyboard = .us,
        /// The keyboard was picked (rather than going with the language).
        keyboard_picked: bool = false,
        /// Where the window's choices go.
        actions: ?*Actions = null,

        fn setLanguage(st: *State, l: locale.Language) void {
            st.language = l;
            if (!st.keyboard_picked) st.keyboard = l.keyboard();
            st.chose();
        }

        fn setKeyboard(st: *State, k: locale.Keyboard) void {
            st.keyboard = k;
            st.keyboard_picked = true;
            st.chose();
        }

        fn chose(st: *State) void {
            if (st.actions) |a| a.locale = .{ .language = st.language, .keyboard = st.keyboard };
        }

        fn chosen(st: *const State, i: usize) bool {
            return i < max_apps and st.skipped & (@as(u64, 1) << @intCast(i)) == 0;
        }

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
        var st: State = .{ .language = self.locale.language, .keyboard = self.locale.keyboard };
        st.setName(self.suggestion);
        return st;
    }

    pub fn build(self: *const Setup, cx: *ui.Context, state: *State) ui.Widget {
        const nav = cx.ui.arena().create(Nav) catch return cx.make(ui.Empty{});
        nav.* = .{ .state = state, .actions = self.actions };
        state.actions = self.actions;
        const content = if (state.finishing) self.finishing(cx, nav) else self.page(cx, state, nav);
        // At most 720 pixels wide, narrower in a narrower window.
        return cx.make(ui.Decorated{ .color = cx.theme().surface, .child = cx.make(ui.Center{ .child = cx.make(ui.ConstrainedBox{
            .constraints = .{ .max_w = 720 },
            .child = cx.make(ui.Padding{ .padding = .all(24), .child = content }),
        }) }) });
    }

    /// A page: its heading, what it asks, and the buttons.
    fn page(self: *const Setup, cx: *ui.Context, state: *State, nav: *Nav) ui.Widget {
        const t = cx.theme();
        const body = switch (pages[state.page]) {
            .language => languagePage(cx, state),
            .hostname => self.hostnamePage(cx, state, nav),
            .apps => self.appsPage(cx, state),
        };
        const last = state.page + 1 == pages.len;
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 24, .children = &.{
            cx.make(ui.Text{ .text = "Welcome to Dazzle", .style = .{ .size = 40, .color = t.primary } }),
            body,
            cx.make(ui.Row{ .spacing = 12, .main_axis_alignment = .end, .children = &.{
                if (state.page > 0) cx.make(ui.OutlinedButton{ .label = "Back", .icon = .arrow_back, .on_press = .of(nav, Nav.back) }) else cx.make(ui.Empty{}),
                cx.make(ui.OutlinedButton{ .label = if (last) "Finish" else "Next", .icon = if (last) .check else null, .trailing_icon = if (last) null else .arrow_forward, .on_press = .of(nav, Nav.next) }),
            } }),
        } });
    }

    fn languagePage(cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const a = cx.ui.arena();
        var languages: std.ArrayList(ui.Widget) = .empty;
        for (std.enums.values(locale.Language)) |l| languages.append(a, cx.make(ui.Radio(locale.Language){
            .value = l,
            .group_value = state.language,
            .on_changed = .of(state, State.setLanguage),
            .label = l.name(),
        })) catch {};
        var keyboards: std.ArrayList(ui.Widget) = .empty;
        for (std.enums.values(locale.Keyboard)) |k| keyboards.append(a, cx.make(ui.Radio(locale.Keyboard){
            .value = k,
            .group_value = state.keyboard,
            .on_changed = .of(state, State.setKeyboard),
            .label = k.name(),
        })) catch {};
        const heading: ui.TextStyle = .{ .size = 20, .color = t.on_surface_variant };
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 12, .children = &.{
            cx.make(ui.Text{ .text = "Language and keyboard", .style = .{ .size = 28 } }),
            cx.make(ui.Row{ .spacing = 24, .cross_axis_alignment = .start, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .start, .main_axis_size = .min, .spacing = 4, .children = &.{
                    cx.make(ui.Text{ .text = "Language", .style = heading }),
                    cx.make(ui.Column{ .cross_axis_alignment = .start, .main_axis_size = .min, .children = languages.items }),
                } }) }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 4, .children = &.{
                    cx.make(ui.Text{ .text = "Keyboard", .style = heading }),
                    cx.make(ui.Column{ .cross_axis_alignment = .start, .main_axis_size = .min, .children = keyboards.items }),
                    cx.make(ui.Padding{ .padding = .{ .top = 8 }, .child = cx.make(ui.TextField{ .placeholder = "Type here to try it", .width = std.math.inf(f32) }) }),
                } }) }),
            } }),
        } });
    }

    fn hostnamePage(_: *const Setup, cx: *ui.Context, state: *State, nav: *Nav) ui.Widget {
        const t = cx.theme();
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 12, .children = &.{
            cx.make(ui.Text{ .text = "Name this computer", .style = .{ .size = 28 } }),
            cx.make(ui.Text{
                .text = "Other computers on the network know it by this name. It can have lowercase letters, numbers and hyphens.",
                .style = .{ .size = 18, .color = t.on_surface_variant },
            }),
            cx.make(ui.TextField{
                .initial = state.name(),
                .max_len = state.name_buf.len,
                .size = 20,
                .width = 400,
                .on_changed = .of(state, State.setName),
                .on_submit = .of(nav, Nav.next),
            }),
            if (state.name_invalid) cx.make(ui.Text{
                .text = "Use 1 to 63 lowercase letters, numbers and hyphens, not starting or ending with a hyphen",
                .style = .{ .size = 16, .color = t.@"error" },
            }) else cx.make(ui.Empty{}),
        } });
    }

    fn appsPage(self: *const Setup, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const a = cx.ui.arena();
        var rows: std.ArrayList(ui.Widget) = .empty;
        rows.appendSlice(a, &.{
            cx.make(ui.Text{ .text = "Choose your apps", .style = .{ .size = 28 } }),
            cx.make(ui.Text{
                .text = "They are installed when you finish. You can add or remove apps later in Settings.",
                .style = .{ .size = 18, .color = t.on_surface_variant },
            }),
        }) catch {};
        const apps = &self.apps;
        if (apps.list.len == 0) {
            const why = if (apps.loading or apps.message.len == 0)
                "Getting the list of apps…"
            else
                cx.fmt("The list of apps could not be got: {s}. You can install apps later in Settings.", .{apps.message});
            rows.append(a, cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                if (apps.loading or apps.message.len == 0) cx.make(ui.Spinner{ .size = 24 }) else cx.make(ui.Empty{}),
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = why, .style = .{ .size = 18, .color = t.on_surface_variant } }) }),
            } })) catch {};
        }
        for (apps.list[0..@min(apps.list.len, max_apps)], 0..) |app, i| {
            const toggle = a.create(Toggle) catch break;
            toggle.* = .{ .state = state, .index = @intCast(i) };
            rows.append(a, cx.make(ui.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = &.{
                cx.make(ui.Checkbox{ .value = state.chosen(i), .on_changed = .of(toggle, Toggle.set) }),
                cx.make(ui.Icon{ .icon = ui.icons.fromName(app.icon) orelse .apps, .size = 32, .color = t.on_surface_variant }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                    cx.make(ui.Text{ .text = app.title, .style = .{ .size = 20 }, .wrap = false, .ellipsis = true }),
                    cx.make(ui.Text{ .text = app.description, .style = .{ .size = 16, .color = t.on_surface_variant } }),
                } }) }),
            } })) catch {};
        }
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 12, .children = rows.items });
    }

    /// After the last page: waiting for the card, or why it could not be
    /// prepared; then installing the apps.
    fn finishing(self: *const Setup, cx: *ui.Context, nav: *Nav) ui.Widget {
        const t = cx.theme();
        const r = self.report;
        if (r != null and r.?.storage == .failed) {
            return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 16, .children = &.{
                cx.make(ui.Text{ .text = "The SD card could not be prepared", .style = .{ .size = 28 } }),
                cx.make(ui.Text{
                    .text = cx.fmt("Dazzle cannot keep files: {s}. Setup will run again when the computer next starts.", .{r.?.failure.label()}),
                    .style = .{ .size = 18, .color = t.on_surface_variant },
                }),
                cx.make(ui.Row{ .main_axis_alignment = .end, .children = &.{
                    cx.make(ui.OutlinedButton{ .label = "Continue", .on_press = .of(nav, Nav.continueWithout) }),
                } }),
            } });
        }
        if (self.apps.installing) |title| {
            return cx.make(ui.Column{ .main_axis_size = .min, .spacing = 20, .children = &.{
                cx.make(ui.Spinner{ .size = 64 }),
                cx.make(ui.Text{ .text = cx.fmt("Installing {s}", .{title}), .style = .{ .size = 24 } }),
                cx.make(ui.Text{ .text = cx.fmt("{d} of {d}", .{ self.apps.done + 1, self.apps.total }), .style = .{ .size = 18, .color = t.on_surface_variant } }),
            } });
        }
        const progress = if (r) |rep| (if (rep.storage == .preparing) cx.fmt("{d}%", .{rep.progress}) else "") else "";
        return cx.make(ui.Column{ .main_axis_size = .min, .spacing = 20, .children = &.{
            cx.make(ui.Spinner{ .size = 64 }),
            cx.make(ui.Text{ .text = "Getting the SD card ready", .style = .{ .size = 24 } }),
            cx.make(ui.Text{ .text = progress, .style = .{ .size = 18, .color = t.on_surface_variant } }),
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
            .language, .apps => {},
        }
        if (st.page + 1 < pages.len) {
            st.page += 1;
            return;
        }
        st.finishing = true;
        if (n.actions) |a| {
            a.finish = proto.Hostname.parse(st.name());
            a.apps = ~st.skipped;
        }
    }

    fn back(n: *Nav) void {
        n.state.page -|= 1;
    }

    fn continueWithout(n: *Nav) void {
        if (n.actions) |a| a.without_storage = true;
    }
};

/// A checkbox on the apps page.
const Toggle = struct {
    state: *Setup.State,
    index: u6,

    fn set(t: *Toggle, on: bool) void {
        const bit = @as(u64, 1) << t.index;
        if (on) t.state.skipped &= ~bit else t.state.skipped |= bit;
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
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
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
            uu.frame(size[0], size[1], n.*, Setup{ .suggestion = "awesome-elephant", .report = r, .actions = a });
        }
    }.draw;
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 }, .{ 800, 600 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    // The language first; then the name, which fits too.
    try testing.expect(findText(u.root.?, "Language and keyboard") != null);
    click(u, findText(u.root.?, "Next").?);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
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

    // A good one: the apps (the list still coming), then finishing, with a
    // spinner while the card is prepared.
    st.setName("my-pi");
    click(u, findText(u.root.?, "Next").?);
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expect(findText(u.root.?, "Choose your apps") != null);
    try testing.expect(findText(u.root.?, "Getting the list of apps…") != null);
    try testing.expect(actions.finish == null);
    click(u, findText(u.root.?, "Finish").?);
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

test "choosing apps, then installing them" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const report: proto.Report = .{ .storage = .ready };
    const list = [_]store.App{
        .{ .name = "dazzle-demo", .title = "Demo", .description = "A spinning 3D shape", .icon = "view_in_ar", .file = "dazzle-demo.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-files", .title = "Files", .description = "Browse your files", .icon = "folder", .file = "dazzle-files.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-camera", .title = "Camera", .description = "Take photos", .icon = "photo_camera", .file = "dazzle-camera.tar.xz", .size = 1, .sha256 = "" },
    };
    var setup: Setup = .{ .suggestion = "my-pi", .report = &report, .actions = &actions, .apps = .{ .list = &list } };
    u.frame(1280, 720, 0, setup);
    u.root.?.state(Setup.State).page = 2;
    u.frame(1280, 720, 1, setup);
    try testing.expect(!overflows(u.root.?));
    try testing.expect(findText(u.root.?, "Browse your files") != null);
    // All chosen to begin with: Files is left out.
    click(u, findType(up(findText(u.root.?, "Files").?, ui.Row).?, ui.Checkbox).?);
    u.frame(1280, 720, 2, setup);
    click(u, findText(u.root.?, "Finish").?);
    try testing.expect(actions.apps & 0b111 == 0b101);

    // Installing: which, and how far.
    setup.apps.installing = "Camera";
    setup.apps.done = 1;
    setup.apps.total = 2;
    u.frame(1280, 720, 3, setup);
    try testing.expect(findText(u.root.?, "Installing Camera") != null);
    try testing.expect(findText(u.root.?, "2 of 2") != null);

    // No list: why, and that it can wait.
    u.root.?.state(Setup.State).finishing = false;
    setup.apps = .{ .message = "the server could not be reached (is the network up?)" };
    u.frame(1280, 720, 4, setup);
    try testing.expect(findText(u.root.?, "The list of apps could not be got: the server could not be reached (is the network up?). You can install apps later in Settings.") != null);
}

fn up(n: *ui.Node, comptime T: type) ?*ui.Node {
    var at: ?*ui.Node = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

test "the language and keyboard: the keyboard goes with the language, until one is picked" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const report: proto.Report = .{ .storage = .preparing };
    const setup: Setup = .{ .suggestion = "my-pi", .report = &report, .actions = &actions, .locale = .{ .language = .en_us, .keyboard = .us } };
    u.frame(1280, 720, 0, setup);
    const st = u.root.?.state(Setup.State);
    try testing.expect(findText(u.root.?, "English (New Zealand)") != null);
    // British English: and a UK keyboard.
    click(u, findText(u.root.?, "English (United Kingdom)").?);
    u.frame(1280, 720, 1, setup);
    try testing.expectEqual(locale.Language.en_gb, st.language);
    try testing.expectEqual(locale.Keyboard.gb, st.keyboard);
    try testing.expectEqual(locale.Keyboard.gb, actions.locale.?.keyboard);
    // A US keyboard picked stays, whatever the language.
    click(u, findText(u.root.?, "English (US)").?);
    u.frame(1280, 720, 2, setup);
    click(u, findText(u.root.?, "English (Australia)").?);
    u.frame(1280, 720, 3, setup);
    try testing.expectEqual(locale.Settings{ .language = .en_au, .keyboard = .us }, actions.locale.?);
    // Somewhere to try it.
    try testing.expect(findType(u.root.?, ui.TextField) != null);
    try testing.expect(!overflows(u.root.?));
}
