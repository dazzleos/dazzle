//! The setup app's window, as widgets: a page at a time, each with a Next
//! button (Finish on the last, and Back after the first), filling the
//! screen. The pages:
//!
//! * the language and the keyboard (which changes with the language, until
//!   one is picked), with a field to try the keyboard in;
//! * the time zone (the language's, until one is picked);
//! * the computer's name, filled in with a random one;
//! * the Wi-Fi network to join (if Ethernet did not connect and there is a
//!   Wi-Fi adapter), or Skip to set up the network later in Settings;
//! * the apps to install (the image has none), from the catalogue, all
//!   chosen to begin with;
//!
//! then finishing: if the SD card is still being prepared, a spinner says
//! how far it has got (it started when setup did); if it could not be, why
//! (and Continue); then the apps chosen are installed, one at a time. What
//! the window asks for goes to the main loop through `Actions`.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const sys = @import("sys");
const store = @import("store");
const locale = @import("locale");

const proto = sys.system;
const net = sys.network;

/// The pages, in order.
/// The size the window opens at: one step at a time.
pub const open_size = [2]u32{ 880, 620 };

pub const Page = enum { language, time, hostname, wifi, apps };
pub const pages = [_]Page{ .language, .time, .hostname, .wifi, .apps };

/// The most apps that can be chosen (the catalogue's first).
pub const max_apps = 64;

/// What the window asks for; the main loop does it.
pub const Actions = struct {
    /// The computer's name, once confirmed on its page.
    hostname: ?proto.Hostname = null,
    /// The pages are done: finish, with this name.
    finish: ?proto.Hostname = null,
    /// Finish even though the card could not be prepared.
    without_storage: bool = false,
    /// The apps to install: bit i for the catalogue's app i.
    apps: u64 = 0,
    /// The language or keyboard picked (to use now, and keep).
    locale: ?locale.Settings = null,
    /// A Wi-Fi network to join.
    connect: ?Join = null,
    /// Leave the Wi-Fi network.
    disconnect: bool = false,
    /// The Wi-Fi step was skipped.
    skip_wifi: bool = false,

    pub const Join = struct {
        ssid_buf: [net.max_ssid]u8 = undefined,
        ssid_len: u8 = 0,
        pass_buf: [63]u8 = undefined,
        pass_len: u8 = 0,

        pub fn ssid(j: *const Join) []const u8 {
            return j.ssid_buf[0..j.ssid_len];
        }

        pub fn passphrase(j: *const Join) []const u8 {
            return j.pass_buf[0..j.pass_len];
        }
    };
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
    /// What the network manager last said; null if it could not be asked.
    wifi: ?*const net.Report = null,
    /// Whether Ethernet has connected.
    ethernet_connected: bool = false,
    apps: Apps = .{},
    actions: ?*Actions = null,

    pub const State = struct {
        page: usize = 0,
        /// Past the last page.
        finishing: bool = false,
        name_buf: [63]u8 = undefined,
        name_len: u8 = 0,
        name_invalid: bool = false,
        /// The Wi-Fi network chosen (its SSID), and the password typed.
        selected_buf: [net.max_ssid]u8 = undefined,
        selected_len: u8 = 0,
        has_selected: bool = false,
        password_buf: [63]u8 = undefined,
        password_len: u8 = 0,
        /// The apps not chosen: bit i for the catalogue's app i.
        skipped: u64 = 0,
        language: locale.Language = .en_us,
        keyboard: locale.Keyboard = .us,
        timezone: locale.TimeZone = .utc,
        /// The keyboard, and the zone, were picked (rather than going with
        /// the language).
        keyboard_picked: bool = false,
        timezone_picked: bool = false,
        /// Where the window's choices go.
        actions: ?*Actions = null,

        fn setLanguage(st: *State, l: locale.Language) void {
            st.language = l;
            if (!st.keyboard_picked) st.keyboard = l.keyboard();
            if (!st.timezone_picked) st.timezone = l.timeZone();
            st.chose();
        }

        fn setTimeZone(st: *State, z: locale.TimeZone) void {
            st.timezone = z;
            st.timezone_picked = true;
            st.chose();
        }

        fn pickKeyboard(st: *State, i: usize) void {
            if (i < std.enums.values(locale.Keyboard).len) st.setKeyboard(@enumFromInt(i));
        }

        fn setKeyboard(st: *State, k: locale.Keyboard) void {
            st.keyboard = k;
            st.keyboard_picked = true;
            st.chose();
        }

        fn chose(st: *State) void {
            if (st.actions) |a| a.locale = .{ .language = st.language, .keyboard = st.keyboard, .timezone = st.timezone };
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

        pub fn selected(st: *const State) ?[]const u8 {
            return if (st.has_selected) st.selected_buf[0..st.selected_len] else null;
        }

        pub fn setPassword(st: *State, text: []const u8) void {
            st.password_len = @intCast(@min(text.len, st.password_buf.len));
            @memcpy(st.password_buf[0..st.password_len], text[0..st.password_len]);
        }
    };

    pub fn showWifi(self: *const Setup) bool {
        if (self.ethernet_connected) return false;
        const w = self.wifi orelse return false;
        return w.wifiAdapters().len > 0;
    }

    pub fn wifiConnected(self: *const Setup) bool {
        const w = self.wifi orelse return false;
        return w.connection.state == .connected;
    }

    pub fn initState(self: *const Setup) State {
        // A zone already chosen (setup run again) is kept; otherwise the
        // language's.
        const zone = if (self.locale.timezone != .utc) self.locale.timezone else self.locale.language.timeZone();
        var st: State = .{ .language = self.locale.language, .keyboard = self.locale.keyboard, .timezone = zone, .timezone_picked = self.locale.timezone != .utc };
        st.setName(self.suggestion);
        return st;
    }

    pub fn build(self: *const Setup, cx: *kete.BuildContext, state: *State) kete.Widget {
        const show_wifi = self.showWifi();
        if (pages[state.page] == .wifi and !show_wifi) {
            state.page = @intFromEnum(Page.apps);
        }
        const nav = cx.arena.create(Nav) catch return cx.make(kete.SizedBox.empty);
        nav.* = .{
            .state = state,
            .actions = self.actions,
            .show_wifi = show_wifi,
            .wifi_connected = self.wifiConnected(),
        };
        state.actions = self.actions;
        const content = if (state.finishing) self.finishing(cx, nav) else self.page(cx, state, nav);
        // At most 720 pixels wide, narrower in a narrower window.
        return cx.make(kete.RoundedBox{ .color = cx.theme().surface, .child = cx.make(kete.Align{ .child = cx.make(kete.ConstrainedBox{
            .constraints = .{ .max_w = 720 },
            .child = cx.make(kete.Padding{ .padding = .all(24), .child = content }),
        }) }) });
    }

    /// A page: its heading, what it asks, and the buttons.
    fn page(self: *const Setup, cx: *kete.BuildContext, state: *State, nav: *Nav) kete.Widget {
        const t = cx.theme();
        const which = pages[state.page];
        const body = switch (which) {
            .language => languagePage(cx, state),
            .time => timePage(cx, state),
            .hostname => self.hostnamePage(cx, state, nav),
            .wifi => self.wifiPage(cx, state),
            .apps => self.appsPage(cx, state),
        };
        const last = state.page + 1 == pages.len;
        const next_label = if (last)
            locale.text("Finish")
        else if (which == .wifi and !self.wifiConnected())
            locale.text("Skip")
        else
            locale.text("Next");
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 24, .children = &.{
            cx.make(kete.Text{ .text = locale.text("Welcome to Dazzle"), .style = .{ .size = 40, .color = t.primary } }),
            body,
            cx.make(kete.Row{ .spacing = 12, .main_axis_alignment = .end, .children = &.{
                if (state.page > 0) cx.make(kete.OutlinedButton{ .label = locale.text("Back"), .icon = .arrow_back, .on_press = .of(nav, Nav.back) }) else cx.make(kete.SizedBox.empty),
                cx.make(kete.OutlinedButton{ .label = next_label, .icon = if (last) .check else null, .trailing_icon = if (last) null else .arrow_forward, .on_press = .of(nav, Nav.next) }),
            } }),
        } });
    }

    fn languagePage(cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        var keyboards: std.ArrayList(kete.MenuItem) = .empty;
        for (std.enums.values(locale.Keyboard)) |k| keyboards.append(a, .{ .label = k.name() }) catch {};
        const heading: kete.TextStyle = .{ .size = 20, .color = t.on_surface_variant };
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = &.{
            cx.make(kete.Text{ .text = locale.text("Language and keyboard"), .style = .{ .size = 28 } }),
            cx.make(kete.Row{ .spacing = 24, .cross_axis_alignment = .start, .children = &.{
                cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .start, .fill = false, .spacing = 4, .children = &.{
                    cx.make(kete.Text{ .text = locale.text("Language"), .style = heading }),
                    cx.make(kete_vc4.LanguagePicker{ .language = state.language, .on_changed = .of(state, State.setLanguage), .height = 160 }),
                } }) }),
                cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 4, .children = &.{
                    cx.make(kete.Text{ .text = locale.text("Keyboard"), .style = heading }),
                    cx.make(kete.DropdownMenu{ .options = keyboards.items, .selected = @intFromEnum(state.keyboard), .on_selected = .of(state, State.pickKeyboard), .width = 260 }),
                    cx.make(kete.Padding{ .padding = .{ .top = 8 }, .child = cx.make(kete.TextField{ .placeholder = locale.text("Type here to try it"), .width = std.math.inf(f32) }) }),
                } }) }),
            } }),
        } });
    }

    /// The time zone: its area, then its city.
    fn timePage(cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        return cx.make(kete.Column{ .cross_axis_alignment = .start, .fill = false, .spacing = 12, .children = cx.arena.dupe(kete.Widget, &.{
            cx.make(kete.Text{ .text = locale.text("Time zone"), .style = .{ .size = 28 } }),
            cx.make(kete.Text{ .text = locale.text("Where the computer is, for its clock"), .style = .{ .size = 18, .color = t.on_surface_variant } }),
            cx.make(kete_vc4.TimeZonePicker{ .zone = state.timezone, .on_changed = .of(state, State.setTimeZone) }),
        }) catch &.{} });
    }

    fn hostnamePage(_: *const Setup, cx: *kete.BuildContext, state: *State, nav: *Nav) kete.Widget {
        const t = cx.theme();
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = &.{
            cx.make(kete.Text{ .text = locale.text("Name this computer"), .style = .{ .size = 28 } }),
            cx.make(kete.Text{
                .text = locale.text("Other computers on the network know it by this name. It can have lowercase letters, numbers and hyphens."),
                .style = .{ .size = 18, .color = t.on_surface_variant },
            }),
            cx.make(kete.TextField{
                .initial = state.name(),
                .max_len = state.name_buf.len,
                .size = 20,
                .width = 400,
                .on_changed = .of(state, State.setName),
                .on_submit = .of(nav, Nav.next),
            }),
            if (state.name_invalid) cx.make(kete.Text{
                .text = locale.text("Use 1 to 63 lowercase letters, numbers and hyphens, not starting or ending with a hyphen"),
                .style = .{ .size = 16, .color = t.@"error" },
            }) else cx.make(kete.SizedBox.empty),
        } });
    }

    fn wifiPage(self: *const Setup, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        var rows: std.ArrayList(kete.Widget) = .empty;
        rows.append(a, cx.make(kete.Text{ .text = locale.text("Connect to Wi-Fi"), .style = .{ .size = 28 } })) catch {};
        const report = self.wifi orelse return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = rows.items });
        const conn = &report.connection;
        const name = printable(cx, conn.ssid());
        switch (conn.state) {
            .idle => rows.append(a, cx.make(kete.Text{
                .text = locale.text("Choose a network to connect to, or skip to set up the network later in Settings."),
                .style = .{ .size = 18, .color = t.on_surface_variant },
            })) catch {},
            .connecting, .authenticating, .addressing => rows.append(a, cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                cx.make(kete.Spinner{ .size = 20 }),
                cx.make(kete.Expanded{ .child = cx.make(kete.Text{
                    .text = kete_vc4.textf(cx, "{s}: {s}…", .{ name, conn.state.label() }),
                    .style = .{ .size = 18, .color = t.on_surface_variant },
                }) }),
            } })) catch {},
            .connected => rows.append(a, cx.make(kete.Text{
                .text = kete_vc4.textf(cx, "Connected to {s}", .{name}),
                .style = .{ .size = 18, .color = t.on_surface_variant },
            })) catch {},
            .failed => rows.append(a, cx.make(kete.Text{
                .text = kete_vc4.textf(cx, "Could not connect to {s}: {s}", .{ name, conn.failure.label() }),
                .style = .{ .size = 18, .color = t.@"error" },
            })) catch {},
        }

        const nets = report.slice();
        if (nets.len == 0) {
            if (report.scanning) {
                rows.append(a, cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                    cx.make(kete.Spinner{ .size = 24 }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = locale.text("Scanning for networks…"), .style = .{ .size = 18, .color = t.on_surface_variant } }) }),
                } })) catch {};
            } else {
                rows.append(a, cx.make(kete.Text{ .text = locale.text("No networks found"), .style = .{ .size = 18, .color = t.on_surface_variant } })) catch {};
            }
            return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = rows.items });
        }

        const chosen: ?*const net.Network = if (state.selected()) |sel| for (nets) |*n| {
            if (std.mem.eql(u8, n.ssid(), sel)) break n;
        } else null else null;
        const form = chosen != null and !(conn.state.joined() and std.mem.eql(u8, conn.ssid(), chosen.?.ssid()));
        const split = if (form) chosen.? - nets.ptr + 1 else nets.len;
        var list_rows: std.ArrayList(kete.Widget) = .empty;
        if (split > 0) list_rows.append(a, self.networkList(cx, state, report, nets[0..split], chosen)) catch {};
        if (form) list_rows.append(a, self.joinForm(cx, state, chosen.?)) catch {};
        if (split < nets.len) {
            if (form) list_rows.append(a, cx.make(kete.HorizontalDivider{ .inset = 16 })) catch {};
            list_rows.append(a, self.networkList(cx, state, report, nets[split..], chosen)) catch {};
        }

        rows.append(a, cx.make(kete.ConstrainedBox{
            .constraints = .{ .max_h = 180 },
            .child = cx.make(kete.ScrollView{
                .child = cx.make(kete.Card{
                    .variant = .outlined,
                    .padding = .all(4),
                    .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .children = list_rows.items }),
                }),
            }),
        })) catch {};
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = rows.items });
    }

    fn networkList(
        self: *const Setup,
        cx: *kete.BuildContext,
        state: *State,
        report: *const net.Report,
        nets: []const net.Network,
        chosen: ?*const net.Network,
    ) kete.Widget {
        const list = cx.arena.create(Networks) catch return cx.make(kete.SizedBox.empty);
        list.* = .{
            .actions = self.actions,
            .state = state,
            .conn = &report.connection,
            .nets = nets,
            .chosen = chosen,
        };
        return cx.make(kete.Grid.list(nets.len, network_row_height, .of(list, Networks.row)));
    }

    fn joinForm(self: *const Setup, cx: *kete.BuildContext, state: *State, n: *const net.Network) kete.Widget {
        const t = cx.theme();
        const on_connect: ?kete.Callback = if (self.actions) |acts| .of(act(cx, acts, state, n.ssid()), Act.connect) else null;
        const field: kete.Widget = switch (n.security) {
            .open => cx.make(kete.Text{ .text = locale.text("An open network: what is sent can be seen"), .style = .{ .size = 16, .color = t.on_surface_variant } }),
            .wpa2, .wpa3 => cx.make(kete.TextField{
                .initial = state.password_buf[0..state.password_len],
                .placeholder = locale.text("Password"),
                .obscure = true,
                .autofocus = true,
                .size = 18,
                .on_changed = .of(state, State.setPassword),
                .on_submit = on_connect,
            }).withKey(std.hash.Fnv1a_64.hash(n.ssid())),
            else => cx.make(kete.Text{ .text = kete_vc4.textf(cx, "{s} networks are not supported yet", .{n.security.label()}), .style = .{ .size = 16, .color = t.on_surface_variant } }),
        };
        const supported = n.security == .open or n.security == .wpa2 or n.security == .wpa3;
        return cx.make(kete.Padding{
            .padding = .symmetric(16, 8),
            .child = cx.make(kete.Row{
                .cross_axis_alignment = .center,
                .spacing = 12,
                .children = &.{
                    cx.make(kete.Expanded{ .child = field }),
                    cx.make(kete.OutlinedButton{ .label = locale.text("Connect"), .on_press = if (supported) on_connect else null }),
                },
            }),
        });
    }

    fn appsPage(self: *const Setup, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        var rows: std.ArrayList(kete.Widget) = .empty;
        rows.appendSlice(a, &.{
            cx.make(kete.Text{ .text = locale.text("Choose your apps"), .style = .{ .size = 28 } }),
            cx.make(kete.Text{
                .text = locale.text("They are installed when you finish. You can add or remove apps later in Settings."),
                .style = .{ .size = 18, .color = t.on_surface_variant },
            }),
        }) catch {};
        const apps = &self.apps;
        if (apps.list.len == 0) {
            const why = if (apps.loading or apps.message.len == 0)
                locale.text("Getting the list of apps…")
            else
                kete_vc4.textf(cx, "The list of apps could not be got: {s}. You can install apps later in Settings.", .{apps.message});
            rows.append(a, cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                if (apps.loading or apps.message.len == 0) cx.make(kete.Spinner{ .size = 24 }) else cx.make(kete.SizedBox.empty),
                cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = why, .style = .{ .size = 18, .color = t.on_surface_variant } }) }),
            } })) catch {};
        }
        for (apps.list[0..@min(apps.list.len, max_apps)], 0..) |app, i| {
            const toggle = a.create(Toggle) catch break;
            toggle.* = .{ .state = state, .index = @intCast(i) };
            rows.append(a, cx.make(kete.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = &.{
                cx.make(kete.Checkbox{ .value = state.chosen(i), .on_changed = .of(toggle, Toggle.set) }),
                cx.make(kete.Icon{ .icon = kete.IconName.fromName(app.icon) orelse .apps, .size = 32, .color = t.on_surface_variant }),
                cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = &.{
                    cx.make(kete.Text{ .text = app.title, .style = .{ .size = 20 }, .wrap = false, .ellipsis = true }),
                    cx.make(kete.Text{ .text = app.description, .style = .{ .size = 16, .color = t.on_surface_variant } }),
                } }) }),
            } })) catch {};
        }
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = rows.items });
    }

    /// After the last page: waiting for the card, or why it could not be
    /// prepared; then installing the apps.
    fn finishing(self: *const Setup, cx: *kete.BuildContext, nav: *Nav) kete.Widget {
        const t = cx.theme();
        const r = self.report;
        if (r != null and r.?.storage == .failed) {
            return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 16, .children = &.{
                cx.make(kete.Text{ .text = locale.text("The SD card could not be prepared"), .style = .{ .size = 28 } }),
                cx.make(kete.Text{
                    .text = kete_vc4.textf(cx, "Dazzle cannot keep files: {s}. Setup will run again when the computer next starts.", .{r.?.failure.label()}),
                    .style = .{ .size = 18, .color = t.on_surface_variant },
                }),
                cx.make(kete.Row{ .main_axis_alignment = .end, .children = &.{
                    cx.make(kete.OutlinedButton{ .label = locale.text("Continue"), .on_press = .of(nav, Nav.continueWithout) }),
                } }),
            } });
        }
        if (self.apps.installing) |title| {
            return cx.make(kete.Column{ .fill = false, .spacing = 20, .children = &.{
                cx.make(kete.Spinner{ .size = 64 }),
                cx.make(kete.Text{ .text = kete_vc4.textf(cx, "Installing {s}", .{title}), .style = .{ .size = 24 } }),
                cx.make(kete.Text{ .text = kete_vc4.textf(cx, "{d} of {d}", .{ self.apps.done + 1, self.apps.total }), .style = .{ .size = 18, .color = t.on_surface_variant } }),
            } });
        }
        const progress = if (r) |rep| (if (rep.storage == .preparing) cx.fmt("{d}%", .{rep.progress}) else "") else "";
        return cx.make(kete.Column{ .fill = false, .spacing = 20, .children = &.{
            cx.make(kete.Spinner{ .size = 64 }),
            cx.make(kete.Text{ .text = locale.text("Getting the SD card ready"), .style = .{ .size = 24 } }),
            cx.make(kete.Text{ .text = progress, .style = .{ .size = 18, .color = t.on_surface_variant } }),
        } });
    }
};

/// How tall a network's row is (including the 1px divider below it).
const network_row_height = kete.ListItem.one_line_height + 1;

/// Networks to make rows of (in the frame's arena).
const Networks = struct {
    actions: ?*Actions,
    state: *Setup.State,
    conn: *const net.Connection,
    nets: []const net.Network,
    chosen: ?*const net.Network,

    fn row(l: *const Networks, cx: *kete.BuildContext, i: usize) kete.Widget {
        const n = &l.nets[i];
        const is_chosen = l.chosen != null and n == l.chosen.?;
        const joined = connectionBusy(l.conn) and std.mem.eql(u8, l.conn.ssid(), n.ssid());
        const on_disconnect: ?kete.Callback = if (joined)
            (if (l.actions) |acts| .of(act(cx, acts, l.state, ""), Act.disconnect) else null)
        else
            null;
        const item = networkRow(cx, n, is_chosen, joined, choose(cx, l.state, n.ssid()), on_disconnect);
        if (i + 1 >= l.nets.len) return cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .stretch,
            .children = &.{item},
        });
        return cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .stretch,
            .children = &.{
                item,
                cx.make(kete.HorizontalDivider{ .inset = 16 }),
            },
        });
    }
};

fn networkRow(
    cx: *kete.BuildContext,
    n: *const net.Network,
    chosen: bool,
    joined: bool,
    on_press: kete.Callback,
    on_disconnect: ?kete.Callback,
) kete.Widget {
    return cx.make(kete.ListItem{
        .headline = printable(cx, n.ssid()),
        .leading = cx.make(Signal{ .bars = n.bars(), .locked = n.security != .open, .size = 20 }),
        .trailing = if (joined) cx.make(kete.OutlinedButton{ .label = locale.text("Disconnect"), .on_press = on_disconnect }) else null,
        .selected = chosen or joined,
        .on_press = on_press,
    });
}

const Signal = struct {
    bars: u8,
    locked: bool = false,
    size: f32,

    fn lit(bars: u8, locked: bool) ?kete.IconName {
        return switch (bars) {
            0 => null,
            1, 2 => .wifi_1_bar,
            3 => .wifi_2_bar,
            else => if (locked) .wifi_password else .wifi,
        };
    }

    pub fn build(self: *const Signal, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const full: kete.IconName = if (self.locked) .wifi_password else .wifi;
        const back = cx.make(kete.Icon{ .icon = full, .size = self.size, .color = t.on_surface.withAlpha(0.25) });
        const front = lit(self.bars, self.locked) orelse return back;
        return cx.make(kete.SizedBox{ .width = self.size, .height = self.size, .child = cx.make(kete.Overlay{ .children = &.{
            back,
            cx.make(kete.Icon{ .icon = front, .size = self.size, .color = t.on_surface }),
        } }) });
    }
};

fn printable(cx: *kete.BuildContext, ssid: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(ssid)) return ssid;
    const out = cx.arena.dupe(u8, ssid) catch return "?";
    for (out) |*c| if (c.* >= 0x80 or c.* < 0x20) {
        c.* = '?';
    };
    return out;
}

fn connectionBusy(c: *const net.Connection) bool {
    return c.state != .idle and !(c.state == .failed and c.failure != .lost);
}

const Choose = struct {
    state: *Setup.State,
    ssid_buf: [net.max_ssid]u8,
    ssid_len: u8,

    fn press(c: *Choose) void {
        const st = c.state;
        const ssid = c.ssid_buf[0..c.ssid_len];
        if (st.selected()) |sel| if (std.mem.eql(u8, sel, ssid)) {
            st.has_selected = false;
            return;
        };
        st.has_selected = true;
        st.selected_len = c.ssid_len;
        @memcpy(st.selected_buf[0..c.ssid_len], ssid);
        st.password_len = 0;
    }
};

fn choose(cx: *kete.BuildContext, state: *Setup.State, ssid: []const u8) kete.Callback {
    const c = cx.arena.create(Choose) catch return .of(state, struct {
        fn none(_: *Setup.State) void {}
    }.none);
    c.* = .{ .state = state, .ssid_buf = undefined, .ssid_len = @intCast(ssid.len) };
    @memcpy(c.ssid_buf[0..ssid.len], ssid);
    return .of(c, Choose.press);
}

const Act = struct {
    actions: *Actions,
    state: *Setup.State,
    ssid_buf: [net.max_ssid]u8,
    ssid_len: u8,

    fn connect(x: *Act) void {
        var j: Actions.Join = .{ .ssid_len = x.ssid_len, .pass_len = x.state.password_len };
        @memcpy(j.ssid_buf[0..x.ssid_len], x.ssid_buf[0..x.ssid_len]);
        @memcpy(j.pass_buf[0..j.pass_len], x.state.password_buf[0..j.pass_len]);
        x.actions.connect = j;
        x.state.has_selected = false;
    }

    fn disconnect(x: *Act) void {
        x.actions.disconnect = true;
    }
};

fn act(cx: *kete.BuildContext, actions: *Actions, state: *Setup.State, ssid: []const u8) *Act {
    const x = cx.arena.create(Act) catch unreachable;
    x.* = .{ .actions = actions, .state = state, .ssid_buf = undefined, .ssid_len = @intCast(ssid.len) };
    @memcpy(x.ssid_buf[0..ssid.len], ssid);
    return x;
}

/// The buttons.
const Nav = struct {
    state: *Setup.State,
    actions: ?*Actions,
    show_wifi: bool = false,
    wifi_connected: bool = false,

    fn next(n: *Nav) void {
        const st = n.state;
        switch (pages[st.page]) {
            .hostname => {
                const h = proto.Hostname.parse(st.name()) orelse {
                    st.name_invalid = true;
                    return;
                };
                if (n.actions) |a| a.hostname = h;
                st.page = if (n.show_wifi) @intFromEnum(Page.wifi) else @intFromEnum(Page.apps);
                return;
            },
            .wifi => {
                if (!n.wifi_connected) if (n.actions) |a| {
                    a.skip_wifi = true;
                };
                st.page = @intFromEnum(Page.apps);
                return;
            },
            .language, .time, .apps => {},
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
        const st = n.state;
        if (pages[st.page] == .apps and !n.show_wifi) {
            st.page = @intFromEnum(Page.hostname);
            return;
        }
        st.page -|= 1;
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
const font = kete.font;

fn overflows(node: *kete.WidgetNode) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *kete.WidgetNode, text: []const u8) ?*kete.WidgetNode {
    if (n.widget.as(kete.Text)) |t| if (std.mem.eql(u8, t.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

fn findType(n: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

fn click(u: *kete.ui.WindowUi, n: *kete.WidgetNode) void {
    const at = n.position();
    const p: kete.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
}

test "naming the computer, then waiting for the card" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .{};
    var report: proto.Report = .{ .storage = .preparing, .progress = 10 };
    var now: u64 = 0;
    const Draw = struct {
        fn draw(uu: *kete.ui.WindowUi, r: *const proto.Report, a: *Actions, n: *u64, size: [2]u32) void {
            n.* += 1;
            uu.frame(size[0], size[1], n.*, Setup{ .suggestion = "awesome-elephant", .report = r, .actions = a });
        }
    }.draw;
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 }, .{ 800, 600 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    // The language first; then the time zone and the name, which fit too.
    try testing.expect(findText(u.root.?, "Language and keyboard") != null);
    click(u, findText(u.root.?, "Next").?);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findType(u.root.?, kete_vc4.TimeZonePicker) != null);
    click(u, findText(u.root.?, "Next").?);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    // The suggestion is filled in.
    const field = findType(u.root.?, kete.TextField).?;
    try testing.expectEqualStrings("awesome-elephant", field.state(kete.TextField.State).text());

    // Not a hostname: it says so, and stays.
    const st = u.root.?.state(Setup.State);
    st.setName("Not OK");
    click(u, findText(u.root.?, "Next").?);
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expect(st.name_invalid and !st.finishing);
    try testing.expect(actions.hostname == null);
    try testing.expect(actions.finish == null);

    // A good one: the name is confirmed at once, then the apps (the list
    // still coming), then finishing, with a spinner while the card is
    // prepared.
    st.setName("my-pi");
    click(u, findText(u.root.?, "Next").?);
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expectEqualStrings("my-pi", actions.hostname.?.slice());
    try testing.expect(findText(u.root.?, "Choose your apps") != null);
    try testing.expect(findText(u.root.?, "Getting the list of apps…") != null);
    try testing.expect(actions.finish == null);
    click(u, findText(u.root.?, "Finish").?);
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expectEqualStrings("my-pi", actions.finish.?.slice());
    try testing.expect(findType(u.root.?, kete.Spinner) != null);
    try testing.expect(findText(u.root.?, "10%") != null);
    try testing.expect(u.needs_frame);

    // If it fails: why, and Continue.
    report = .{ .storage = .failed, .failure = .too_small };
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expect(findType(u.root.?, kete.Spinner) == null);
    click(u, findText(u.root.?, "Continue").?);
    try testing.expect(actions.without_storage);
}

test "Wi-Fi networks are shown when Ethernet is not connected and a Wi-Fi adapter is present" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const report: proto.Report = .{ .storage = .ready };
    var wifi: net.Report = .{};
    var wlan: net.Adapter = .{ .up = true };
    wlan.setName("wlan0");
    wifi.addAdapter(wlan);
    var home: net.Network = .{ .signal_mbm = -5200, .freq_mhz = 2437, .security = .wpa2 };
    home.setSsid("Home");
    wifi.add(home);
    var cafe: net.Network = .{ .signal_mbm = -6800, .freq_mhz = 2412, .security = .open };
    cafe.setSsid("Cafe");
    wifi.add(cafe);

    var setup: Setup = .{ .suggestion = "my-pi", .report = &report, .wifi = &wifi, .actions = &actions };
    u.frame(1280, 720, 0, setup);
    click(u, findText(u.root.?, "Next").?);
    u.frame(1280, 720, 1, setup);
    // The time zone, then the name.
    click(u, findText(u.root.?, "Next").?);
    u.frame(1280, 720, 1, setup);
    try testing.expect(findText(u.root.?, "Name this computer") != null);

    // Approving the hostname when Ethernet is not connected goes to the Wi-Fi page.
    click(u, findText(u.root.?, "Next").?);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 }, .{ 800, 600 }, .{ 640, 480 } }) |size| {
        u.frame(size[0], size[1], 2, setup);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expectEqualStrings("my-pi", actions.hostname.?.slice());
    try testing.expect(findText(u.root.?, "Connect to Wi-Fi") != null);
    try testing.expect(findText(u.root.?, "Home") != null);
    try testing.expect(findText(u.root.?, "Cafe") != null);
    try testing.expect(findText(u.root.?, "Skip") != null);
    // No options other than a network (e.g. no Static / Address / Mode / MAC address).
    try testing.expect(findText(u.root.?, "Address") == null);
    try testing.expect(findText(u.root.?, "Static") == null);
    try testing.expect(findText(u.root.?, "Mode") == null);
    try testing.expect(findText(u.root.?, "MAC address") == null);

    // Selecting a WPA2 network shows the password field and Connect button.
    click(u, findText(u.root.?, "Home").?);
    u.frame(1280, 720, 3, setup);
    try testing.expect(!overflows(u.root.?));
    const st = u.root.?.state(Setup.State);
    st.setPassword("secret123");
    click(u, findText(u.root.?, "Connect").?);
    try testing.expectEqualStrings("Home", actions.connect.?.ssid());
    try testing.expectEqualStrings("secret123", actions.connect.?.passphrase());

    // Skipping the network advances to the apps page.
    u.frame(1280, 720, 4, setup);
    click(u, findText(u.root.?, "Skip").?);
    u.frame(1280, 720, 5, setup);
    try testing.expect(actions.skip_wifi);
    try testing.expect(findText(u.root.?, "Choose your apps") != null);

    // If Ethernet is connected, approving the hostname skips the Wi-Fi page.
    u.root.?.state(Setup.State).page = @intFromEnum(Page.hostname);
    setup.ethernet_connected = true;
    u.frame(1280, 720, 6, setup);
    click(u, findText(u.root.?, "Next").?);
    u.frame(1280, 720, 7, setup);
    try testing.expect(findText(u.root.?, "Choose your apps") != null);
}

test "choosing apps, then installing them" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
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
    u.root.?.state(Setup.State).page = @intFromEnum(Page.apps);
    u.frame(1280, 720, 1, setup);
    try testing.expect(!overflows(u.root.?));
    try testing.expect(findText(u.root.?, "Browse your files") != null);
    // All chosen to begin with: Files is left out.
    click(u, findType(up(findText(u.root.?, "Files").?, kete.Row).?, kete.Checkbox).?);
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

fn up(n: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
    var at: ?*kete.WidgetNode = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

test "every page fits, in Spanish too" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const report: proto.Report = .{ .storage = .preparing, .progress = 10 };
    const setup: Setup = .{ .suggestion = "awesome-elephant", .report = &report, .actions = &actions };
    defer locale.current = .en_gb;
    var n: u64 = 0;
    for ([_]locale.Language{ .en_gb, .es_es, .es_ar, .zh_cn }) |lang| for (0..pages.len) |page| for ([_][2]u32{ .{ 1920, 1080 }, .{ 800, 600 }, .{ 640, 480 } }) |size| {
        locale.current = lang;
        n += 1;
        u.frame(size[0], size[1], n, setup);
        u.root.?.state(Setup.State).page = @intCast(page);
        n += 1;
        u.frame(size[0], size[1], n, setup);
        errdefer std.debug.print("the {s} page overflows at {d}x{d} in {s}\n", .{ @tagName(pages[page]), size[0], size[1], lang.code() });
        try testing.expect(!overflows(u.root.?));
    };
}

test "the language and keyboard: the keyboard goes with the language, until one is picked" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
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
    try testing.expect(findType(u.root.?, kete.DropdownMenu) != null);
    st.pickKeyboard(@intFromEnum(locale.Keyboard.us));
    u.frame(1280, 720, 2, setup);
    click(u, findText(u.root.?, "English (Australia)").?);
    u.frame(1280, 720, 3, setup);
    // The time zone goes with the language too: Sydney's, for Australia.
    try testing.expectEqual(locale.Settings{ .language = .en_au, .keyboard = .us, .timezone = locale.TimeZone.fromName("Australia/Sydney").? }, actions.locale.?);
    // Somewhere to try it.
    try testing.expect(findType(u.root.?, kete.TextField) != null);
    try testing.expect(!overflows(u.root.?));
}
