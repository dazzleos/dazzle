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

pub const Page = enum { hello, keyboard, hostname, network, time };
pub const pages = [_]Page{ .hello, .keyboard, .hostname, .network, .time };

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
    network: ?*const net.Report = null,
    /// The time (seconds since 1970, UTC), if the clock has been set.
    wall_s: ?i64 = null,
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
        /// Every time zone shown, to choose from by name.
        choosing_zone: bool = false,
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
            st.choosing_zone = false;
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

        fn showZones(st: *State) void {
            st.choosing_zone = true;
        }

        fn hideZones(st: *State) void {
            st.choosing_zone = false;
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

    /// Whether the computer is on a network (by Wi-Fi or Ethernet).
    pub fn networkConnected(self: *const Setup) bool {
        const r = self.network orelse return false;
        return r.connection.state == .connected or r.ethernetConnected();
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
        const nav = cx.arena.create(Nav) catch return cx.make(kete.SizedBox.empty);
        nav.* = .{ .state = state, .actions = self.actions };
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
            .network => locale.text("Connect to a network"),
            .time => locale.text("Time zone"),
        };
        const body = switch (which) {
            .hello => unreachable,
            .keyboard => keyboardPage(cx, state),
            .time => self.timePage(cx, state),
            .hostname => self.hostnamePage(cx, state, nav),
            .network => self.networkPage(cx, state),
        };
        const last = state.page + 1 == pages.len;
        const next_label = if (last)
            locale.text("Finish")
        else if (which == .network and !self.networkConnected())
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
        const whole = cx.make(kete.Padding{ .padding = .{ .left = 24, .right = 24, .top = parts.title_top, .bottom = parts.margin }, .child = cx.make(kete.Column{
            .cross_axis_alignment = .stretch,
            .fill = true,
            .children = cx.arena.dupe(kete.Widget, &.{
                cx.make(parts.Title{ .text = title }),
                cx.make(kete.Expanded{ .child = area }),
                cx.make(kete.SizedBox{ .height = parts.above_buttons }),
                parts.buttons(cx, .of(nav, Nav.back), next_label, .of(nav, Nav.next), last),
            }) catch &.{},
        }) });
        // Every keyboard, or zone, to choose from: over the whole page.
        return switch (which) {
            .keyboard => cx.make(kete.Dialog{
                .open = state.choosing_keyboard,
                .title = locale.text("All keyboards"),
                .content = cx.make(kete_vc4.KeyboardPicker{ .keyboard = state.keyboard, .on_changed = .of(state, State.chooseOtherKeyboard) }),
                .confirm_label = locale.text("Cancel"),
                .on_confirm = .of(state, State.hideKeyboards),
                .on_dismiss = .of(state, State.hideKeyboards),
                .width = 480,
                .child = whole,
            }),
            .time => cx.make(kete.Dialog{
                .open = state.choosing_zone,
                .title = locale.text("Time zone"),
                .content = cx.make(kete_vc4.ZonePicker{ .zone = state.timezone, .now_s = self.wall_s orelse 0, .on_changed = .of(state, State.setTimeZone) }),
                .confirm_label = locale.text("Cancel"),
                .on_confirm = .of(state, State.hideZones),
                .on_dismiss = .of(state, State.hideZones),
                .width = 520,
                .child = whole,
            }),
            else => whole,
        };
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
            choices.append(a, cx.make(parts.Choice{
                .label = k.name(),
                .selected = k == state.keyboard,
                .on_press = .of(pick, KeyboardChoice.choose),
            })) catch {};
        }
        choices.append(a, cx.make(parts.Choice{ .label = locale.text("Other keyboards"), .icon = .keyboard, .on_press = .of(state, State.showKeyboards) })) catch {};

        const page_body = cx.make(kete.KeyHandler{ .watch = true, .on_key = .of(state, State.watchKey), .child = cx.make(kete.Column{
            .cross_axis_alignment = .stretch,
            .fill = true,
            .children = a.dupe(kete.Widget, &.{
                // The keyboards to choose from, just above the keyboard's
                // picture, the two as big as there is room for (no bigger
                // than a key 64 pixels across)...
                cx.make(kete.Expanded{ .flex = 4, .child = cx.make(kete.Align{ .alignment = .bottom_center, .child = cx.make(kete.ScaleDown{
                    .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .center, .spacing = 28, .children = a.dupe(kete.Widget, &.{
                        cx.make(kete.Row{ .fill = false, .spacing = 12, .cross_axis_alignment = .center, .children = choices.items }),
                        cx.make(kete_vc4.KeyboardPicture{ .keyboard = state.keyboard, .unit = 64, .light = light }),
                    }) catch &.{} }),
                }) }) }),
                // What is typed: shown while typing, each character gone a
                // while after (there is no field to type in: the label
                // only shows what the layout types), halfway between the
                // keyboard and the buttons.
                cx.make(kete.Expanded{ .child = cx.make(kete.Align{ .alignment = .center, .child = typedLabel(cx, state) }) }),
            }) catch &.{},
        }) });
        return page_body;
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
    /// The time zone: the time it is there (large), the world's hours on
    /// a map to choose one by, and the zone's name, a button that shows
    /// them all to choose from by name.
    fn timePage(self: *const Setup, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        const now = self.wall_s orelse 0;
        const local = state.timezone.local(now);
        var clock_buf: [32]u8 = undefined;
        var date_buf: [64]u8 = undefined;
        const clock = if (self.wall_s != null) locale.formatClock(&clock_buf, local.hour, local.minute) else "--:--";
        const date = if (self.wall_s != null) locale.formatFullDate(&date_buf, local.weekday, local.day, local.month, local.year) else "";
        var label_buf: [96]u8 = undefined;
        var off_buf: [16]u8 = undefined;
        const label = kete_vc4.textf(cx, "{s} · {s}", .{ state.timezone.label(&label_buf), kete_vc4.utcOffset(&off_buf, state.timezone.offsetAt(now)) });
        const body = cx.make(kete.Column{ .cross_axis_alignment = .center, .fill = false, .spacing = 12, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.Text{ .text = a.dupe(u8, clock) catch "", .wrap = false, .style = .{ .size = 120 } }),
            cx.make(kete.Text{ .text = a.dupe(u8, date) catch "", .wrap = false, .style = .{ .size = 24, .color = t.on_surface_variant } }),
            cx.make(kete.SizedBox{ .height = 16 }),
            cx.make(kete.LeftToRight{ .child = cx.make(kete_vc4.ZoneMap{ .zone = state.timezone, .on_changed = .of(state, State.setTimeZone), .width = 640, .bands = true }) }),
            cx.make(kete.SizedBox{ .height = 4 }),
            cx.make(parts.Choice{ .label = label, .icon = .public, .trailing_icon = .arrow_drop_down, .on_press = .of(state, State.showZones) }),
        }) catch &.{} });
        return body;
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
                .outlined = false,
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

    /// The network: Ethernet, how it is (if there is an adapter); the
    /// Wi-Fi networks (if there is one), large, to choose and join; or,
    /// with neither, that there is no network to set up.
    fn networkPage(self: *const Setup, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        var rows: std.ArrayList(kete.Widget) = .empty;
        const report = self.network orelse return noNetwork(cx);
        const ethernets = report.ethernetAdapters();
        const wifis = report.wifiAdapters();
        if (ethernets.len == 0 and wifis.len == 0) return noNetwork(cx);
        if (ethernets.len > 0) {
            const connected = report.ethernetConnected();
            const status = if (connected)
                locale.text("Ethernet connected")
            else if (report.ethernetCarrier())
                locale.text("Ethernet connecting")
            else
                locale.text("Ethernet not connected");
            rows.append(a, cx.make(kete.RoundedBox{
                .color = if (connected) t.primary_container else null,
                .radius = .all(20),
                .child = cx.make(kete.Padding{ .padding = .symmetric(20, 16), .child = cx.make(kete.Row{ .spacing = 20, .cross_axis_alignment = .center, .children = a.dupe(kete.Widget, &.{
                    cx.make(kete.Icon{ .icon = .settings_ethernet, .size = 32, .color = if (connected) t.on_primary_container else t.on_surface_variant }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = status, .wrap = false, .ellipsis = true, .style = .{ .size = 24, .color = if (connected) t.on_primary_container else t.on_surface } }) }),
                    if (report.ethernetCarrier() and !connected) cx.make(kete.Spinner{ .size = 24 }) else if (connected) cx.make(kete.Icon{ .icon = .check_circle, .size = 28, .color = t.on_primary_container }) else cx.make(kete.SizedBox.empty),
                }) catch &.{} }) }),
            })) catch {};
        }
        if (wifis.len > 0) {
            const conn = &report.connection;
            const nets = report.slice();
            var list: std.ArrayList(kete.Widget) = .empty;
            for (nets) |*n| list.append(a, self.networkRow(cx, state, conn, n)) catch {};
            if (nets.len == 0) list.append(a, cx.make(kete.Padding{ .padding = .symmetric(20, 16), .child = cx.make(kete.Row{ .spacing = 20, .cross_axis_alignment = .center, .children = a.dupe(kete.Widget, &.{
                if (report.scanning) cx.make(kete.Spinner{ .size = 28 }) else cx.make(kete.Icon{ .icon = .wifi_off, .size = 32, .color = t.on_surface_variant }),
                cx.make(kete.Text{ .text = if (report.scanning) locale.text("Scanning for networks…") else locale.text("No networks found"), .style = .{ .size = 24, .color = t.on_surface_variant } }),
            }) catch &.{} }) })) catch {};
            // Up to six networks show; more, scrolled to.
            rows.append(a, cx.make(kete.ConstrainedBox{ .constraints = .{ .max_h = 6 * 76 + 120 }, .child = cx.make(kete.ScrollView{
                .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 4, .children = list.items }),
            }) })) catch {};
        }
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 12, .children = rows.items });
    }

    /// No network to set up (no adapter): that, and what to do.
    fn noNetwork(cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        return cx.make(kete.Column{ .cross_axis_alignment = .center, .fill = false, .spacing = 16, .children = cx.arena.dupe(kete.Widget, &.{
            cx.make(kete.Icon{ .icon = .signal_wifi_off, .size = 72, .color = t.on_surface_variant }),
            cx.make(kete.Text{ .text = locale.text("No network adapter"), .style = .{ .size = 28 } }),
            cx.make(kete.Text{
                .text = locale.text("Plug in an Ethernet cable or a Wi-Fi adapter to connect. You can also set up the network later in Settings."),
                .text_align = .center,
                .style = .{ .size = 18, .color = t.on_surface_variant },
            }),
        }) catch &.{} });
    }

    /// A Wi-Fi network, large: pressed, chosen (its password asked for
    /// under it); joined, how that is going, and the way to leave it.
    fn networkRow(self: *const Setup, cx: *kete.BuildContext, state: *State, conn: *const net.Connection, n: *const net.Network) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        const joined = connectionBusy(conn) and std.mem.eql(u8, conn.ssid(), n.ssid());
        const chosen = if (state.selected()) |sel| std.mem.eql(u8, sel, n.ssid()) else false;
        const fg = if (joined) t.on_primary_container else t.on_surface;
        var trailing: std.ArrayList(kete.Widget) = .empty;
        if (joined) {
            if (conn.state == .connected)
                trailing.append(a, cx.make(kete.Icon{ .icon = .check_circle, .size = 28, .color = fg })) catch {}
            else
                trailing.append(a, cx.make(kete.Spinner{ .size = 24 })) catch {};
            if (self.actions) |acts| trailing.append(a, cx.make(kete.TextButton{ .label = locale.text("Disconnect"), .on_press = .of(act(cx, acts, state, ""), Act.disconnect) })) catch {};
        }
        const head = cx.make(kete.Pressable{ .on_press = choose(cx, state, n.ssid()), .child = cx.make(kete.Padding{ .padding = .symmetric(20, 14), .child = cx.make(kete.Row{ .spacing = 20, .cross_axis_alignment = .center, .children = a.dupe(kete.Widget, &.{
            cx.make(Signal{ .bars = n.bars(), .locked = n.security != .open, .size = 32 }),
            cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = printable(cx, n.ssid()), .wrap = false, .ellipsis = true, .style = .{ .size = 24, .color = fg } }) }),
            cx.make(kete.Row{ .fill = false, .spacing = 12, .cross_axis_alignment = .center, .children = trailing.items }),
        }) catch &.{} }) }) });
        var parts_: std.ArrayList(kete.Widget) = .empty;
        parts_.append(a, head) catch {};
        if (!joined and conn.state == .failed and std.mem.eql(u8, conn.ssid(), n.ssid())) parts_.append(a, cx.make(kete.Padding{ .padding = .{ .left = 72, .right = 20, .bottom = 12 }, .child = cx.make(kete.Text{
            .text = kete_vc4.textf(cx, "Could not connect to {s}: {s}", .{ printable(cx, conn.ssid()), conn.failure.label() }),
            .style = .{ .size = 18, .color = t.@"error" },
        }) })) catch {};
        if (chosen and !joined) parts_.append(a, self.joinForm(cx, state, n)) catch {};
        return cx.make(kete.RoundedBox{
            .color = if (joined) t.primary_container else if (chosen) t.surface_container else null,
            .radius = .all(20),
            .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .children = parts_.items }),
        });
    }

    /// Under a network chosen: its password (if it has one), and Connect.
    fn joinForm(self: *const Setup, cx: *kete.BuildContext, state: *State, n: *const net.Network) kete.Widget {
        const t = cx.theme();
        const on_connect: ?kete.Callback = if (self.actions) |acts| .of(act(cx, acts, state, n.ssid()), Act.connect) else null;
        const field: kete.Widget = switch (n.security) {
            .open => cx.make(kete.Text{ .text = locale.text("An open network: what is sent can be seen"), .style = .{ .size = 18, .color = t.on_surface_variant } }),
            .wpa2, .wpa3 => cx.make(kete.RoundedBox{ .color = t.surface_container_highest, .radius = .all(12), .child = cx.make(kete.Padding{ .padding = .symmetric(8, 4), .child = cx.make(kete.TextField{
                .initial = state.password_buf[0..state.password_len],
                .placeholder = locale.text("Password"),
                .obscure = true,
                .outlined = false,
                .autofocus = true,
                .size = 22,
                .width = std.math.inf(f32),
                .on_changed = .of(state, State.setPassword),
                .on_submit = on_connect,
            }).withKey(std.hash.Fnv1a_64.hash(n.ssid())) }) }),
            else => cx.make(kete.Text{ .text = kete_vc4.textf(cx, "{s} networks are not supported yet", .{n.security.label()}), .style = .{ .size = 18, .color = t.on_surface_variant } }),
        };
        const supported = n.security == .open or n.security == .wpa2 or n.security == .wpa3;
        return cx.make(kete.Padding{
            .padding = .{ .left = 72, .right = 20, .bottom = 16 },
            .child = cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = cx.arena.dupe(kete.Widget, &.{
                cx.make(kete.Expanded{ .child = field }),
                cx.make(parts.Choice{ .label = locale.text("Connect"), .filled = true, .on_press = if (supported) on_connect else null }),
            }) catch &.{} }),
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

    fn next(n: *Nav) void {
        const st = n.state;
        switch (pages[st.page]) {
            .hostname => {
                const h = proto.Hostname.parse(st.name()) orelse {
                    st.name_invalid = true;
                    return;
                };
                if (n.actions) |a| a.hostname = h;
            },
            .hello, .keyboard, .network, .time => {},
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

    // A good one: the name is confirmed at once, then the network (none
    // here: no adapter, it says), the time zone, then finishing, with a
    // spinner while the card is prepared.
    st.setName("my-pi");
    click(u, findText(u.root.?, "Next").?);
    Draw(u, &report, &actions, &now, .{ 1920, 1080 });
    try testing.expectEqualStrings("my-pi", actions.hostname.?.slice());
    try testing.expect(findText(u.root.?, "No network adapter") != null);
    click(u, findText(u.root.?, "Skip").?);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 640, 480 } }) |size| {
        Draw(u, &report, &actions, &now, size);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findType(u.root.?, kete_vc4.ZoneMap) != null);
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

    const setup: Setup = .{ .suggestion = "my-pi", .report = &report, .network = &wifi, .actions = &actions };
    u.frame(1280, 720, 0, setup);
    u.root.?.state(Setup.State).page = @intFromEnum(Page.hostname);
    u.frame(1280, 720, 0, setup);
    try testing.expect(findText(u.root.?, "Give me a name") != null);

    // The name, then the network: the Wi-Fi networks (no Ethernet adapter,
    // so nothing of Ethernet), and Skip until one is joined.
    click(u, findText(u.root.?, "Next").?);
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 1280, 720 }, .{ 1024, 768 }, .{ 800, 600 }, .{ 640, 480 } }) |size| {
        u.frame(size[0], size[1], 2, setup);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expectEqualStrings("my-pi", actions.hostname.?.slice());
    try testing.expect(findText(u.root.?, "Connect to a network") != null);
    try testing.expect(findText(u.root.?, "Home") != null);
    try testing.expect(findText(u.root.?, "Cafe") != null);
    try testing.expect(findText(u.root.?, "Skip") != null);
    try testing.expect(findText(u.root.?, "Ethernet not connected") == null);
    // No options other than a network (e.g. no Static / Address / Mode / MAC address).
    try testing.expect(findText(u.root.?, "Address") == null);
    try testing.expect(findText(u.root.?, "Static") == null);
    try testing.expect(findText(u.root.?, "MAC address") == null);

    // Choosing a WPA2 network asks for its password, and Connect joins it.
    click(u, findText(u.root.?, "Home").?);
    u.frame(1280, 720, 3, setup);
    try testing.expect(!overflows(u.root.?));
    const st = u.root.?.state(Setup.State);
    st.setPassword("secret123");
    click(u, findText(u.root.?, "Connect").?);
    try testing.expectEqualStrings("Home", actions.connect.?.ssid());
    try testing.expectEqualStrings("secret123", actions.connect.?.passphrase());

    // Skipping the network: on to the time zone, and Back to it again.
    u.frame(1280, 720, 4, setup);
    click(u, findText(u.root.?, "Skip").?);
    u.frame(1280, 720, 5, setup);
    try testing.expect(findType(u.root.?, kete_vc4.ZoneMap) != null);
    click(u, findText(u.root.?, "Back").?);
    u.frame(1280, 720, 6, setup);
    try testing.expect(findText(u.root.?, "Connect to a network") != null);

    // An Ethernet adapter too, connected: how it is, and Next (it is on a
    // network).
    var eth: net.Ethernet = .{ .adapter = .{ .up = true }, .address = .{ 192, 168, 1, 20 } };
    eth.adapter.?.setName("eth0");
    wifi.addEthernet(eth);
    u.frame(1280, 720, 7, setup);
    try testing.expect(findText(u.root.?, "Ethernet connected") != null);
    try testing.expect(findText(u.root.?, "Next") != null);
    try testing.expect(!overflows(u.root.?));
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
