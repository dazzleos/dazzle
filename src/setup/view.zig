//! The setup app's window, as widgets: a page at a time, filling the
//! screen, each with large Back and Next buttons (Finish on the last) in
//! the same place along the bottom, in the middle. The pages:
//!
//! * "Hello" in every language, to pick the language by (hello.zig): it
//!   fills the screen, the buttons only once a word is picked;
//! * the keyboard: those most likely for the language, the likeliest
//!   chosen, and the rest one button away; with its keys drawn, lit as
//!   they are pressed, and what is typed shown;
//! * the computer's name, filled in with a random one (named, it joins the
//!   network);
//! * the Wi-Fi network to join (if Ethernet did not connect and there is a
//!   Wi-Fi adapter), or Skip to set up the network later in Settings;
//! * the time zone (the language's, until one is picked);
//!
//! then finishing: if the SD card is still being prepared, a spinner says
//! how far it has got (it started when setup did); if it could not be, why
//! (and Continue). What the window asks for goes to the main loop through
//! `Actions`.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const sys = @import("sys");
const locale = @import("locale");
const hello = @import("hello.zig");
const parts = @import("parts.zig");

const proto = sys.system;
const net = sys.network;

/// The pages, in order.
/// The size the window opens at: one step at a time.
pub const open_size = [2]u32{ 880, 620 };

pub const Page = enum { hello, keyboard, hostname, wifi, time };
pub const pages = [_]Page{ .hello, .keyboard, .hostname, .wifi, .time };

/// Keys lit on the keyboard's picture: those with Linux key codes below
/// this (every one it draws).
const key_codes = 128;
/// The most characters typed shown at once (the oldest go first).
const max_typed = 40;
/// How long a character typed is shown; how long the label stays after
/// the last; and how long it takes to fade in and out.
const typed_life_ns = 3 * std.time.ns_per_s;
const typed_idle_ns = 1500 * std.time.ns_per_ms;
const typed_fade_ns = 300 * std.time.ns_per_ms;

/// A character typed, and when.
const Typed = struct { char: u21, at_ns: u64 };

/// How long a key let go takes to stop being lit.
const key_fade_ns: f32 = 300 * std.time.ns_per_ms;

/// What the window asks for; the main loop does it.
pub const Actions = struct {
    /// The computer's name, once confirmed on its page.
    hostname: ?proto.Hostname = null,
    /// The pages are done: finish, with this name.
    finish: ?proto.Hostname = null,
    /// Finish even though the card could not be prepared.
    without_storage: bool = false,
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
    actions: ?*Actions = null,

    pub const State = struct {
        page: usize = 0,
        /// The first page's words, and the one picked.
        hello: hello.State = .{},
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
        language: locale.Language = .en_us,
        keyboard: locale.Keyboard = .us,
        timezone: locale.TimeZone = .utc,
        /// The keys held down (by Linux key code), those let go and to be
        /// faded from when the page is next made, and when each was let go:
        /// lit on the keyboard's picture.
        keys_held: std.StaticBitSet(key_codes) = .empty,
        keys_let_go: std.StaticBitSet(key_codes) = .empty,
        key_let_go_ns: [key_codes]u64 = @splat(0),
        /// What was typed on the keyboard page, the oldest first (each
        /// gone a while after), and since when the label has been showing
        /// (null: it is not).
        typed: [max_typed]Typed = undefined,
        typed_len: usize = 0,
        typed_shown_ns: ?u64 = null,
        /// Every keyboard shown, to choose from; and one chosen there that
        /// is not one of the language's likely ones (offered beside them).
        choosing_keyboard: bool = false,
        other_keyboard: ?locale.Keyboard = null,
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

        /// A key pressed or let go anywhere on the page (while the field
        /// types it): it lights on the keyboard's picture.
        fn watchKey(st: *State, k: kete.Event.Key) bool {
            if (k.pressed) {
                if (k.char) |c| {
                    if (c >= ' ') st.typeChar(c);
                } else if (k.key == .backspace and st.typed_len > 0) st.typed_len -= 1;
            }
            const code = kete.window.evdev.codeOf(k.key) orelse return false;
            if (code >= key_codes) return false;
            if (k.pressed) {
                st.keys_held.set(code);
                st.keys_let_go.unset(code);
            } else if (st.keys_held.isSet(code)) {
                st.keys_held.unset(code);
                st.keys_let_go.set(code);
            }
            return false;
        }

        /// A character typed on the keyboard page: shown (its time set
        /// when the page is next made), the oldest gone if there is no room.
        fn typeChar(st: *State, c: u21) void {
            if (st.typed_len == st.typed.len) {
                std.mem.copyForwards(Typed, st.typed[0 .. st.typed.len - 1], st.typed[1..]);
                st.typed_len -= 1;
            }
            st.typed[st.typed_len] = .{ .char = c, .at_ns = 0 };
            st.typed_len += 1;
        }

        /// One of the keyboards offered.
        fn chooseKeyboard(st: *State, k: locale.Keyboard) void {
            st.setKeyboard(k);
        }

        /// One from every keyboard: chosen, and offered beside the likely
        /// ones (if it is not one).
        fn chooseOtherKeyboard(st: *State, k: locale.Keyboard) void {
            st.setKeyboard(k);
            if (std.mem.indexOfScalar(locale.Keyboard, st.language.keyboards(), k) == null) st.other_keyboard = k;
            st.choosing_keyboard = false;
        }

        fn showKeyboards(st: *State) void {
            st.choosing_keyboard = true;
        }

        fn hideKeyboards(st: *State) void {
            st.choosing_keyboard = false;
        }

        fn chose(st: *State) void {
            if (st.actions) |a| a.locale = .{ .language = st.language, .keyboard = st.keyboard, .timezone = st.timezone };
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
            state.page = @intFromEnum(Page.time);
        }
        const nav = cx.arena.create(Nav) catch return cx.make(kete.SizedBox.empty);
        nav.* = .{
            .state = state,
            .actions = self.actions,
            .show_wifi = show_wifi,
            .wifi_connected = self.wifiConnected(),
        };
        state.actions = self.actions;
        // The first page is the whole window.
        if (!state.finishing and pages[state.page] == .hello) {
            return cx.make(hello.Page{ .state = &state.hello, .on_select = .of(nav, Nav.selectLanguage), .on_next = .of(nav, Nav.next) });
        }
        if (state.finishing) return cx.make(kete.RoundedBox{ .color = cx.theme().surface, .child = cx.make(kete.Align{ .child = cx.make(kete.ConstrainedBox{
            .constraints = .{ .max_w = 720 },
            .child = cx.make(kete.Padding{ .padding = .all(24), .child = self.finishing(cx, nav) }),
        }) }) });
        return cx.make(kete.RoundedBox{ .color = cx.theme().surface, .child = self.page(cx, state, nav) });
    }

    /// A page: its title, what it asks in the middle (at most 720 pixels
    /// wide), and the buttons along the bottom.
    fn page(self: *const Setup, cx: *kete.BuildContext, state: *State, nav: *Nav) kete.Widget {
        const which = pages[state.page];
        const title = switch (which) {
            .hello => unreachable, // the whole window (see `build`)
            .keyboard => locale.text("Is this your keyboard?"),
            .hostname => locale.text("Give me a name"),
            .wifi => locale.text("Connect to Wi-Fi"),
            .time => locale.text("Time zone"),
        };
        const body = switch (which) {
            .hello => unreachable,
            .keyboard => keyboardPage(cx, state),
            .time => timePage(cx, state),
            .hostname => self.hostnamePage(cx, state, nav),
            .wifi => self.wifiPage(cx, state),
        };
        const last = state.page + 1 == pages.len;
        const next_label = if (last)
            locale.text("Finish")
        else if (which == .wifi and !self.wifiConnected())
            locale.text("Skip")
        else
            locale.text("Next");
        // The keyboard page's picture takes the room there is, as wide as
        // the screen (the others are as tall as they need, in the middle,
        // and made smaller if there is not room on a small screen).
        const fill = which == .keyboard;
        const area = if (fill)
            cx.make(kete.Align{ .alignment = .top_center, .child = cx.make(kete.ConstrainedBox{ .constraints = .{ .max_w = 1600 }, .child = cx.make(kete.SizedBox{ .height = std.math.inf(f32), .child = body }) }) })
        else
            cx.make(kete.Align{ .child = cx.make(kete.ScaleDown{ .child = cx.make(kete.ConstrainedBox{ .constraints = .{ .max_w = 720 }, .child = body }) }) });
        return cx.make(kete.Padding{ .padding = .{ .left = 24, .right = 24, .top = parts.title_top, .bottom = parts.margin }, .child = cx.make(kete.Column{
            .cross_axis_alignment = .stretch,
            .fill = true,
            .children = cx.arena.dupe(kete.Widget, &.{
                cx.make(parts.Title{ .text = title }),
                cx.make(kete.Expanded{ .child = area }),
                cx.make(kete.SizedBox{ .height = parts.above_buttons }),
                parts.buttons(cx, .of(nav, Nav.back), next_label, .of(nav, Nav.next), last),
            }) catch &.{},
        }) });
    }

    /// The keyboard: the language's likely ones to choose from (the
    /// likeliest chosen to begin with), and every one a button away; its
    /// keys drawn, lit as they are pressed, and what is typed shown.
    fn keyboardPage(cx: *kete.BuildContext, state: *State) kete.Widget {
        const a = cx.arena;
        const now = cx.now();
        // The keys' light: held, all of it; let go, fading.
        const light = a.alloc(f32, key_codes) catch return cx.make(kete.SizedBox.empty);
        var fading = false;
        for (light, 0..) |*l, code| {
            if (state.keys_let_go.isSet(code)) {
                state.keys_let_go.unset(code);
                state.key_let_go_ns[code] = now;
            }
            const since = now -| state.key_let_go_ns[code];
            l.* = if (state.keys_held.isSet(code)) 1 else if (state.key_let_go_ns[code] != 0 and since < key_fade_ns) 1 - @as(f32, @floatFromInt(since)) / key_fade_ns else 0;
            if (l.* > 0 and !state.keys_held.isSet(code)) fading = true;
        }
        if (fading) cx.requestFrame();

        var choices: std.ArrayList(kete.Widget) = .empty;
        var offered: [8]locale.Keyboard = undefined;
        var n: usize = 0;
        for (state.language.keyboards()) |k| {
            offered[n] = k;
            n += 1;
        }
        if (state.other_keyboard) |k| if (std.mem.indexOfScalar(locale.Keyboard, offered[0..n], k) == null) {
            offered[n] = k;
            n += 1;
        };
        for (offered[0..n]) |k| {
            const pick = a.create(KeyboardChoice) catch continue;
            pick.* = .{ .state = state, .keyboard = k };
            choices.append(a, cx.make(kete.Chip{
                .label = k.name(),
                .icon = if (k == state.keyboard) .check else null,
                .selected = k == state.keyboard,
                .on_press = .of(pick, KeyboardChoice.choose),
            })) catch {};
        }
        choices.append(a, cx.make(kete.TextButton{ .label = locale.text("Other keyboards"), .icon = .keyboard, .on_press = .of(state, State.showKeyboards) })) catch {};

        const page_body = cx.make(kete.KeyHandler{ .watch = true, .on_key = .of(state, State.watchKey), .child = cx.make(kete.Column{
            .cross_axis_alignment = .stretch,
            .fill = true,
            .children = a.dupe(kete.Widget, &.{
                // The keyboards to choose from, just above the keyboard's
                // picture, the two as big as there is room for (no bigger
                // than a key 80 pixels across)...
                cx.make(kete.Expanded{ .flex = 4, .child = cx.make(kete.Align{ .alignment = .bottom_center, .child = cx.make(kete.ScaleDown{
                    .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .center, .spacing = 20, .children = a.dupe(kete.Widget, &.{
                        cx.make(kete.Row{ .fill = false, .spacing = 8, .cross_axis_alignment = .center, .children = choices.items }),
                        cx.make(kete_vc4.KeyboardPicture{ .keyboard = state.keyboard, .unit = 80, .light = light }),
                    }) catch &.{} }),
                }) }) }),
                // What is typed: shown while typing, each character gone a
                // while after (there is no field to type in: the label
                // only shows what the layout types), halfway between the
                // keyboard and the buttons.
                cx.make(kete.Expanded{ .child = cx.make(kete.Align{ .alignment = .center, .child = typedLabel(cx, state) }) }),
            }) catch &.{},
        }) });
        return cx.make(kete.Dialog{
            .open = state.choosing_keyboard,
            .title = locale.text("All keyboards"),
            .content = cx.make(kete_vc4.KeyboardPicker{ .keyboard = state.keyboard, .on_changed = .of(state, State.chooseOtherKeyboard) }),
            .confirm_label = locale.text("Cancel"),
            .on_confirm = .of(state, State.hideKeyboards),
            .on_dismiss = .of(state, State.hideKeyboards),
            .width = 480,
            .child = page_body,
        });
    }

    /// What was typed on the keyboard page, in the middle, large: fading in
    /// as it is typed, each character gone a while after, and fading out
    /// once nothing is (it takes the same room, shown or not).
    fn typedLabel(cx: *kete.BuildContext, state: *State) kete.Widget {
        const now = cx.now();
        const a = cx.arena;
        // Characters typed since: from now.
        for (state.typed[0..state.typed_len]) |*c| if (c.at_ns == 0) {
            c.at_ns = @max(now, 1);
        };
        // Those shown long enough, gone.
        var keep: usize = 0;
        for (state.typed[0..state.typed_len]) |c| if (now -| c.at_ns < typed_life_ns) {
            state.typed[keep] = c;
            keep += 1;
        };
        state.typed_len = keep;
        var last: u64 = 0;
        for (state.typed[0..state.typed_len]) |c| last = @max(last, c.at_ns);
        var alpha: f32 = 0;
        if (state.typed_len > 0) {
            if (state.typed_shown_ns == null) state.typed_shown_ns = now;
            const in = @min(1, @as(f32, @floatFromInt(now -| state.typed_shown_ns.?)) / typed_fade_ns);
            const idle = now -| last;
            const out = if (idle < typed_idle_ns) 1 else 1 - @min(1, @as(f32, @floatFromInt(idle - typed_idle_ns)) / typed_fade_ns);
            alpha = @min(in, out);
            if (out <= 0) {
                // Faded out: what was typed goes with it.
                state.typed_len = 0;
                state.typed_shown_ns = null;
            } else cx.requestFrame();
        } else state.typed_shown_ns = null;
        var text: std.ArrayList(u8) = .empty;
        for (state.typed[0..state.typed_len]) |c| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c.char, &buf) catch continue;
            text.appendSlice(a, buf[0..n]) catch {};
        }
        return cx.make(kete.SizedBox{ .height = 56, .child = cx.make(kete.Align{ .alignment = .center, .child = cx.make(kete.Opacity{
            .opacity = alpha,
            .child = cx.make(kete.Text{ .text = text.items, .wrap = false, .ellipsis = true, .style = .{ .size = 32 } }),
        }) }) });
    }

    /// The time zone: on a map, or found by its city.
    fn timePage(cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        // The map as wide as the page (the zone picked right under it).
        return cx.make(kete.Column{ .cross_axis_alignment = .start, .fill = false, .spacing = 12, .children = cx.arena.dupe(kete.Widget, &.{
            cx.make(kete.Text{ .text = locale.text("Where the computer is, for its clock"), .style = .{ .size = 18, .color = t.on_surface_variant } }),
            cx.make(kete_vc4.TimeZoneMap{ .zone = state.timezone, .on_changed = .of(state, State.setTimeZone), .width = 720 }),
        }) catch &.{} });
    }

    fn hostnamePage(_: *const Setup, cx: *kete.BuildContext, state: *State, nav: *Nav) kete.Widget {
        const t = cx.theme();
        // The name, large, in the middle; what it can have under it (or
        // what is wrong with it).
        return cx.make(kete.Column{ .cross_axis_alignment = .center, .fill = false, .spacing = 16, .children = &.{
            cx.make(kete.TextField{
                .initial = state.name(),
                .max_len = state.name_buf.len,
                .size = 44,
                .width = 640,
                .centered = true,
                .autofocus = true,
                .on_changed = .of(state, State.setName),
                .on_submit = .of(nav, Nav.next),
            }),
            if (state.name_invalid) cx.make(kete.Text{
                .text = locale.text("Use 1 to 63 lowercase letters, numbers and hyphens, not starting or ending with a hyphen"),
                .text_align = .center,
                .style = .{ .size = 18, .color = t.@"error" },
            }) else cx.make(kete.Text{
                .text = locale.text("Lowercase letters, numbers and hyphens. You can change it later in Settings."),
                .text_align = .center,
                .style = .{ .size = 18, .color = t.on_surface_variant },
            }),
        } });
    }

    fn wifiPage(self: *const Setup, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        var rows: std.ArrayList(kete.Widget) = .empty;
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

    /// After the last page: waiting for the card, or why it could not be
    /// prepared.
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
                cx.make(kete.Row{ .main_axis_alignment = .center, .children = &.{
                    cx.make(parts.BigButton{ .label = locale.text("Continue"), .look = .filled, .on_press = .of(nav, Nav.continueWithout) }),
                } }),
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
                if (!n.show_wifi) {
                    st.page = @intFromEnum(Page.time);
                    return;
                }
            },
            .wifi => if (!n.wifi_connected) if (n.actions) |a| {
                a.skip_wifi = true;
            },
            .hello, .keyboard, .time => {},
        }
        if (st.page + 1 < pages.len) {
            st.page += 1;
            return;
        }
        st.finishing = true;
        if (n.actions) |a| {
            a.finish = proto.Hostname.parse(st.name());
        }
    }

    /// A language chosen on the first page: used at once (its Next goes
    /// on with it).
    fn selectLanguage(n: *Nav, l: locale.Language) void {
        // Its keyboard (and zone), and those likely for it, again.
        n.state.keyboard_picked = false;
        n.state.other_keyboard = null;
        n.state.setLanguage(l);
    }

    fn back(n: *Nav) void {
        const st = n.state;
        if (pages[st.page] == .time and !n.show_wifi) {
            st.page = @intFromEnum(Page.hostname);
            return;
        }
        st.page -|= 1;
    }

    fn continueWithout(n: *Nav) void {
        if (n.actions) |a| a.without_storage = true;
    }
};

/// One of the keyboards offered, to choose.
const KeyboardChoice = struct {
    state: *Setup.State,
    keyboard: locale.Keyboard,

    fn choose(c: *KeyboardChoice) void {
        c.state.chooseKeyboard(c.keyboard);
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

/// Where `p` (in `n`'s own coordinates) is in the window: through the
/// transforms of it and the nodes it is in (the keyboard page's, drawn
/// smaller).
fn onWindow(n: *const kete.WidgetNode, p: kete.Point) kete.Point {
    var q = p;
    var at: ?*const kete.WidgetNode = n;
    while (at) |x| : (at = x.parent) {
        if (x.widget.vtable.paint_transform) |f| q = f(x.widget.ptr, x).apply(q);
        q = .{ q[0] + x.offset[0], q[1] + x.offset[1] };
    }
    return q;
}

fn click(u: *kete.ui.WindowUi, n: *kete.WidgetNode) void {
    const p = onWindow(n, .{ n.size.w / 2, n.size.h / 2 });
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
    // Past the first page ("Hello", to pick the language by).
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    u.root.?.state(Setup.State).page = @intFromEnum(Page.keyboard);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 }, .{ 800, 600 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    // The keyboard; then the name, which fits too.
    try testing.expect(findType(u.root.?, kete_vc4.KeyboardPicture) != null);
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

    // A good one: the name is confirmed at once, then (no Wi-Fi) the time
    // zone, then finishing, with a spinner while the card is prepared.
    st.setName("my-pi");
    click(u, findText(u.root.?, "Next").?);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expectEqualStrings("my-pi", actions.hostname.?.slice());
    try testing.expect(findType(u.root.?, kete_vc4.TimeZoneMap) != null);
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
    u.root.?.state(Setup.State).page = @intFromEnum(Page.keyboard);
    u.frame(1280, 720, 0, setup);
    click(u, findText(u.root.?, "Next").?);
    u.frame(1280, 720, 1, setup);
    // The name.
    try testing.expect(findText(u.root.?, "Give me a name") != null);

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

    // Skipping the network advances to the time zone.
    u.frame(1280, 720, 4, setup);
    click(u, findText(u.root.?, "Skip").?);
    u.frame(1280, 720, 5, setup);
    try testing.expect(actions.skip_wifi);
    try testing.expect(findType(u.root.?, kete_vc4.TimeZoneMap) != null);
    // Back goes to the network again.
    click(u, findText(u.root.?, "Back").?);
    u.frame(1280, 720, 6, setup);
    try testing.expect(findText(u.root.?, "Connect to Wi-Fi") != null);

    // If Ethernet is connected, approving the hostname skips the Wi-Fi page.
    u.root.?.state(Setup.State).page = @intFromEnum(Page.hostname);
    setup.ethernet_connected = true;
    u.frame(1280, 720, 6, setup);
    click(u, findText(u.root.?, "Next").?);
    u.frame(1280, 720, 7, setup);
    try testing.expect(findType(u.root.?, kete_vc4.TimeZoneMap) != null);
    // And Back passes it by.
    click(u, findText(u.root.?, "Back").?);
    u.frame(1280, 720, 8, setup);
    try testing.expect(findText(u.root.?, "Give me a name") != null);
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
    for ([_]locale.Language{ .en_gb, .es_es, .es_ar, .zh_cn, .fr_fr, .de_de, .pt_br, .ja_jp, .ar_eg }) |lang| for (0..pages.len) |page| for ([_][2]u32{ .{ 1920, 1080 }, .{ 800, 600 }, .{ 640, 480 } }) |size| {
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

test "the keyboard: the language's likely ones, every one a button away, and the keys lit as they are pressed" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const report: proto.Report = .{ .storage = .preparing };
    const setup: Setup = .{ .suggestion = "my-pi", .report = &report, .actions = &actions, .locale = .{ .language = .es_mx, .keyboard = .latam } };
    const ms = std.time.ns_per_ms;
    u.frame(1280, 720, 0, setup);
    const st = u.root.?.state(Setup.State);
    st.page = @intFromEnum(Page.keyboard);
    u.frame(1280, 720, 1 * ms, setup);
    // Mexico's: Latin American Spanish, then Spain's, then US English.
    for ([_][]const u8{ "Español (Latinoamérica)", "Español (España)", "English (US)" }) |name| try testing.expect(findText(u.root.?, name) != null);
    try testing.expect(findText(u.root.?, "Deutsch (QWERTZ)") == null);
    click(u, findText(u.root.?, "Español (España)").?);
    u.frame(1280, 720, 2 * ms, setup);
    try testing.expectEqual(locale.Keyboard.es, st.keyboard);
    try testing.expectEqual(locale.Keyboard.es, actions.locale.?.keyboard);
    // Every keyboard: German, picked there, is offered beside them.
    click(u, findText(u.root.?, "Other keyboards").?);
    u.frame(1280, 720, 3 * ms, setup);
    try testing.expect(st.choosing_keyboard);
    try testing.expect(findType(u.root.?, kete_vc4.KeyboardPicker) != null);
    // (As the list does, chosen there.)
    st.chooseOtherKeyboard(.de);
    u.frame(1280, 720, 4 * ms, setup);
    try testing.expectEqual(locale.Keyboard.de, st.keyboard);
    try testing.expect(!st.choosing_keyboard);
    try testing.expect(findText(u.root.?, "Deutsch (QWERTZ)") != null);
    // Q pressed: lit while held, fading once let go; and shown typed.
    u.focus(null);
    const light = struct {
        fn of(uu: *kete.ui.WindowUi) f32 {
            return findType(uu.root.?, kete_vc4.KeyboardPicture).?.widget.as(kete_vc4.KeyboardPicture).?.light[16];
        }
    }.of;
    u.key(.{ .key = .q, .pressed = true, .char = 'q' });
    u.frame(1280, 720, 5 * ms, setup);
    try testing.expectEqual(@as(f32, 1), light(u));
    u.key(.{ .key = .q, .pressed = false });
    u.frame(1280, 720, 6 * ms, setup);
    u.frame(1280, 720, 106 * ms, setup);
    try testing.expect(light(u) > 0 and light(u) < 1);
    try testing.expect(findText(u.root.?, "q") != null);
    u.frame(1280, 720, 1000 * ms, setup);
    try testing.expectEqual(@as(f32, 0), light(u));
    try testing.expect(!overflows(u.root.?));
    // Some time later, gone (and nothing to type in).
    u.frame(1280, 720, 6000 * ms, setup);
    u.frame(1280, 720, 6001 * ms, setup);
    try testing.expect(findText(u.root.?, "q") == null);
    try testing.expect(findType(u.root.?, kete.TextField) == null);
}

test "the first page: hello in every language; one picked, its languages, and back" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const report: proto.Report = .{ .storage = .preparing };
    const setup: Setup = .{ .suggestion = "my-pi", .report = &report, .actions = &actions };
    const s = std.time.ns_per_s;
    u.frame(1920, 1080, 1 * s, setup);
    const st = u.root.?.state(Setup.State);
    try testing.expectEqual(Page.hello, pages[st.page]);
    // The most spoken first: English is in at once, Japanese later.
    u.frame(1920, 1080, 1 * s + 500 * std.time.ns_per_ms, setup);
    try testing.expect(findText(u.root.?, "Hello") != null);
    try testing.expect(findText(u.root.?, "こんにちは") == null);
    u.frame(1920, 1080, 20 * s, setup);
    for (hello.words) |w| try testing.expect(findText(u.root.?, w.text) != null);
    // Hola: the others go, it turns into the title, and its languages
    // show, the first chosen.
    click(u, findText(u.root.?, "Hola").?);
    try testing.expectEqual(locale.Language.es_mx, actions.locale.?.language);
    u.frame(1920, 1080, 20 * s + 100 * std.time.ns_per_ms, setup);
    u.frame(1920, 1080, 22 * s, setup);
    try testing.expect(findText(u.root.?, "Hello") == null);
    try testing.expect(findText(u.root.?, "Hello, I speak…") != null);
    try testing.expect(findText(u.root.?, "Español (México)") != null);
    try testing.expect(findText(u.root.?, "Español (Chile)") != null);
    try testing.expect(!overflows(u.root.?));
    // Back: the words again.
    click(u, findText(u.root.?, "Back").?);
    u.frame(1920, 1080, 23 * s, setup);
    u.frame(1920, 1080, 25 * s, setup);
    try testing.expect(findText(u.root.?, "Hello") != null);
    try testing.expect(findText(u.root.?, "Español (México)") == null);
    // Hola, then Chile: chosen (still on this page); then Next, on to the
    // keyboard with it.
    click(u, findText(u.root.?, "Hola").?);
    u.frame(1920, 1080, 26 * s, setup);
    u.frame(1920, 1080, 28 * s, setup);
    click(u, findText(u.root.?, "Español (Chile)").?);
    u.frame(1920, 1080, 29 * s, setup);
    try testing.expectEqual(Page.hello, pages[st.page]);
    try testing.expectEqual(locale.Language.es_cl, st.language);
    try testing.expectEqual(locale.Language.es_cl, actions.locale.?.language);
    click(u, findText(u.root.?, "Next").?);
    u.frame(1920, 1080, 30 * s, setup);
    try testing.expectEqual(Page.keyboard, pages[st.page]);
    try testing.expectEqual(locale.Language.es_cl, st.language);
}
