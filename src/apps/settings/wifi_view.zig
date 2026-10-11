//! The Wi-Fi page: the adapter chosen (when there is more than one),
//! its connection status and MAC address, and a scrollable list of the
//! networks around, with a form under the chosen network to join it.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const info = @import("info.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;
const Page = view.Page;
const PillBar = ui.PillBar;
const PillButton = ui.PillButton;

pub const label = "Wi-Fi";
pub const icon: ui.icons.Icon = .wifi;

pub const State = struct {
    /// The Wi-Fi adapter picked, when there is more than one.
    adapter: usize = 0,
    /// The Wi-Fi network chosen (its SSID), and the password typed.
    selected_buf: [32]u8 = undefined,
    selected_len: u8 = 0,
    has_selected: bool = false,
    password_buf: [63]u8 = undefined,
    password_len: u8 = 0,

    pub fn selected(st: *const State) ?[]const u8 {
        return if (st.has_selected) st.selected_buf[0..st.selected_len] else null;
    }

    pub fn setPassword(st: *State, text: []const u8) void {
        st.password_len = @intCast(@min(text.len, st.password_buf.len));
        @memcpy(st.password_buf[0..st.password_len], text[0..st.password_len]);
    }
};

pub fn build(self: *const Settings, b: Builder, state: *State) ui.Widget {
    const cx = b.cx;
    const wrap = struct {
        fn frame(c: *ui.Context, child: ui.Widget) ui.Widget {
            return c.make(ui.Padding{ .padding = .all(24), .child = c.make(ui.Align{
                .alignment = .top_center,
                .child = c.make(ui.ConstrainedBox{ .constraints = .{ .max_w = view.max_page_width }, .child = child }),
            }) });
        }
    }.frame;
    const report = self.manager orelse return wrap(cx, b.page(&.{b.item("Status", "The network manager is not running")}));
    if (report.denied) return wrap(cx, b.page(&.{b.item("Status", "Not allowed to scan")}));
    const adapters = report.wifiAdapters();
    if (adapters.len == 0) return wrap(cx, b.page(&.{b.item("Status", "No Wi-Fi adapter")}));
    const idx = @min(state.adapter, adapters.len - 1);
    state.adapter = idx;
    const adapter = adapters[idx];
    var top_rows: std.ArrayList(ui.Widget) = .empty;
    const a = cx.ui.arena();
    if (adapters.len > 1) {
        var pills: std.ArrayList(ui.Widget) = .empty;
        for (adapters, 0..) |*ad, i| {
            pills.append(a, cx.make(PillButton{
                .label = ad.name(),
                .selected = i == idx,
                .first = i == 0,
                .last = i + 1 == adapters.len,
                .on_press = pickAdapter(cx, state, self.actions, i, ad.name()),
            })) catch {};
        }
        top_rows.append(a, cx.make(ui.Center{ .height_factor = 1, .child = cx.make(PillBar{ .children = pills.items }) })) catch {};
    }
    top_rows.append(a, connectionRow(self, b, state, adapter.name(), &report.connection)) catch {};
    const m = adapter.mac;
    top_rows.append(a, b.item("MAC address", cx.fmt("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ m[0], m[1], m[2], m[3], m[4], m[5] }))) catch {};

    var list_rows: std.ArrayList(ui.Widget) = .empty;
    const nets = report.slice();
    // The chosen network, if it is still around (and not the one joined).
    const conn = &report.connection;
    const chosen: ?*const info.manager.Network = if (state.selected()) |sel| for (nets) |*n| {
        if (std.mem.eql(u8, n.ssid(), sel)) break n;
    } else null else null;
    const form = chosen != null and !(conn.state.joined() and std.mem.eql(u8, conn.ssid(), chosen.?.ssid()));
    // The networks, in lists that make only the rows that show; the
    // form for joining the chosen one goes under it, between two.
    const split = if (form) chosen.? - nets.ptr + 1 else nets.len;
    if (split > 0) list_rows.append(a, networkList(b, state, report, nets[0..split], chosen)) catch {};
    if (form) list_rows.append(a, joinForm(self, b, state, adapter.name(), chosen.?)) catch {};
    if (split < nets.len) list_rows.append(a, networkList(b, state, report, nets[split..], chosen)) catch {};
    const footer = if (report.scanning) "Scanning…" else if (nets.len == 0) "No networks found" else "";
    if (footer.len > 0) list_rows.append(a, b.item("", footer)) catch {};

    return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
        cx.make(ui.Padding{
            .padding = .{ .left = 24, .top = 24, .right = 24, .bottom = 10 },
            .child = cx.make(ui.Align{
                .alignment = .top_center,
                .height_factor = 1,
                .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = view.max_page_width }, .child = b.page(top_rows.items) }),
            }),
        }),
        cx.make(ui.Expanded{ .child = cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{
            .padding = .{ .left = 24, .top = 0, .right = 24, .bottom = 24 },
            .child = cx.make(ui.Align{
                .alignment = .top_center,
                .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = view.max_page_width }, .child = b.page(list_rows.items) }),
            }),
        }) }).withKey(@as(u64, @intFromEnum(Page.wifi)) + 1) }),
    } });
}

const PickAdapter = struct {
    state: *State,
    actions: ?*Actions,
    index: usize,
    name: info.Str(16),

    fn press(p: *PickAdapter) void {
        p.state.adapter = p.index;
        p.state.has_selected = false;
        if (p.actions) |acts| acts.wifi_adapter = p.name;
    }
};

fn pickAdapter(cx: *ui.Context, state: *State, actions: ?*Actions, index: usize, name: []const u8) ?ui.Callback {
    const p = cx.ui.arena().create(PickAdapter) catch return null;
    p.* = .{ .state = state, .actions = actions, .index = index, .name = .of(name) };
    return .of(p, PickAdapter.press);
}

/// The connection's state, with Disconnect while there is one.
fn connectionRow(self: *const Settings, b: Builder, state: *State, adapter_name: []const u8, c: *const info.manager.Connection) ui.Widget {
    const cx = b.cx;
    const on_this = c.adapter_len == 0 or std.mem.eql(u8, c.adapter(), adapter_name);
    const name = printable(cx, c.ssid());
    const text = if (!on_this) "Not connected" else switch (c.state) {
        .idle => "Not connected",
        .connected => if (c.address) |ip| cx.fmt("Connected to {s} ({d}.{d}.{d}.{d})", .{ name, ip[0], ip[1], ip[2], ip[3] }) else cx.fmt("Connected to {s}", .{name}),
        .connecting, .authenticating, .addressing => cx.fmt("{s}: {s}…", .{ name, c.state.label() }),
        .failed => cx.fmt("Could not connect to {s}: {s}", .{ name, c.failure.label() }),
    };
    if (!on_this or !connectionBusy(c)) return b.item("Status", text);
    return cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        b.label("Status"),
        cx.make(ui.Expanded{ .child = b.value(text) }),
        cx.make(ui.OutlinedButton{ .label = "Disconnect", .on_press = if (self.actions) |acts| .of(act(cx, acts, state, adapter_name, ""), Act.disconnect) else null }),
    } });
}

/// Joining the chosen network: a password field for WPA2, and Connect.
fn joinForm(self: *const Settings, b: Builder, state: *State, adapter_name: []const u8, n: *const info.manager.Network) ui.Widget {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const on_connect: ?ui.Callback = if (self.actions) |acts| .of(act(cx, acts, state, adapter_name, n.ssid()), Act.connect) else null;
    const field: ui.Widget = switch (n.security) {
        .open => cx.make(ui.Text{ .text = "An open network: what is sent can be seen", .style = .{ .size = 16, .color = t.on_surface_variant } }),
        .wpa2 => cx.make(ui.TextField{
            .placeholder = "Password",
            .obscure = true,
            .size = 18,
            .on_changed = .of(state, State.setPassword),
            .on_submit = on_connect,
        }).withKey(std.hash.Fnv1a_64.hash(n.ssid())),
        else => cx.make(ui.Text{ .text = cx.fmt("{s} networks are not supported yet", .{n.security.label()}), .style = .{ .size = 16, .color = t.on_surface_variant } }),
    };
    const supported = n.security == .open or n.security == .wpa2;
    return cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        cx.make(ui.SizedBox{ .width = 150 }),
        cx.make(ui.Expanded{ .child = field }),
        cx.make(ui.OutlinedButton{ .label = "Connect", .on_press = if (supported) on_connect else null }),
    } });
}

/// Wi-Fi networks, a row each; rows are made only for those that show.
fn networkList(b: Builder, state: *State, report: *const info.manager.Report, nets: []const info.manager.Network, chosen: ?*const info.manager.Network) ui.Widget {
    const cx = b.cx;
    const list = cx.ui.arena().create(Networks) catch return cx.make(ui.Empty{});
    list.* = .{ .state = state, .conn = &report.connection, .nets = nets, .chosen = chosen };
    return cx.make(ui.LazyGrid{
        .count = nets.len,
        .cell = .{ .w = std.math.inf(f32), .h = network_row_height },
        .spacing = 10,
        .item = .of(list, Networks.row),
    });
}

/// How tall a network's row is.
const network_row_height = 32;

/// Networks to make rows of (in the frame's arena).
const Networks = struct {
    state: *State,
    conn: *const info.manager.Connection,
    nets: []const info.manager.Network,
    chosen: ?*const info.manager.Network,

    fn row(l: *const Networks, cx: *ui.Context, i: usize) ui.Widget {
        const n = &l.nets[i];
        const is_chosen = l.chosen != null and n == l.chosen.?;
        const joined = l.conn.state != .idle and l.conn.state != .failed and std.mem.eql(u8, l.conn.ssid(), n.ssid());
        return networkRow(cx, n, is_chosen, joined, choose(cx, l.state, n.ssid()));
    }
};

/// A Wi-Fi network: its signal and its name, in the middle of its row
/// (`network_row_height`); pressing it chooses it.
fn networkRow(cx: *ui.Context, n: *const info.manager.Network, chosen: bool, joined: bool, on_press: ui.Callback) ui.Widget {
    const t = &cx.ui.theme;
    const row = cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        cx.make(Signal{ .bars = n.bars(), .locked = n.security != .open, .size = 20 }),
        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = printable(cx, n.ssid()), .style = .{ .size = 18, .color = if (joined) t.primary else t.on_surface }, .wrap = false }) }),
    } });
    return cx.make(ui.Pressable{ .on_press = on_press, .child = cx.make(ui.Decorated{
        .color = if (chosen) t.secondary_container else gfx.Color.argb(0),
        .radius = .all(8),
        .child = cx.make(ui.Padding{ .padding = .{ .top = 3, .bottom = 3 }, .child = row }),
    }) });
}

/// An SSID as text: bytes that are not UTF-8 (SSIDs need not be) become
/// "?".
pub fn printable(cx: *ui.Context, ssid: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(ssid)) return ssid;
    const out = cx.ui.arena().dupe(u8, ssid) catch return "?";
    for (out) |*c| if (c.* >= 0x80 or c.* < 0x20) {
        c.* = '?';
    };
    return out;
}

/// Whether a connection is being made or kept (and can be ended).
fn connectionBusy(c: *const info.manager.Connection) bool {
    return c.state != .idle and !(c.state == .failed and c.failure != .lost);
}

/// Pressing a network chooses it (or, again, unchooses it).
const Choose = struct {
    state: *State,
    ssid_buf: [32]u8,
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

fn choose(cx: *ui.Context, state: *State, ssid: []const u8) ui.Callback {
    const c = cx.ui.arena().create(Choose) catch return .of(state, struct {
        fn none(_: *State) void {}
    }.none);
    c.* = .{ .state = state, .ssid_buf = undefined, .ssid_len = @intCast(ssid.len) };
    @memcpy(c.ssid_buf[0..ssid.len], ssid);
    return .of(c, Choose.press);
}

/// Connect and Disconnect: requests for the main loop.
const Act = struct {
    actions: *Actions,
    state: *State,
    adapter: info.Str(16),
    ssid_buf: [32]u8,
    ssid_len: u8,

    fn connect(x: *Act) void {
        var j: Actions.Join = .{ .adapter = x.adapter, .ssid_len = x.ssid_len, .pass_len = x.state.password_len };
        @memcpy(j.ssid_buf[0..x.ssid_len], x.ssid_buf[0..x.ssid_len]);
        @memcpy(j.pass_buf[0..j.pass_len], x.state.password_buf[0..j.pass_len]);
        x.actions.connect = j;
        // The form closes; the connection row says how it goes.
        x.state.has_selected = false;
    }

    fn disconnect(x: *Act) void {
        x.actions.disconnect = true;
        x.actions.wifi_adapter = x.adapter;
    }
};

fn act(cx: *ui.Context, actions: *Actions, state: *State, adapter: []const u8, ssid: []const u8) *Act {
    const x = cx.ui.arena().create(Act) catch unreachable;
    x.* = .{ .actions = actions, .state = state, .adapter = .of(adapter), .ssid_buf = undefined, .ssid_len = @intCast(ssid.len) };
    @memcpy(x.ssid_buf[0..ssid.len], ssid);
    return x;
}

/// Signal strength (0 to 4 bars) as the Wi-Fi icon, faint, with as many
/// of its arcs lit as the signal is strong: all three for 4 bars, two for
/// 3, the dot for 1 or 2, none for 0.
pub const Signal = struct {
    bars: u8,
    locked: bool = false,
    size: f32,

    pub fn lit(bars: u8, locked: bool) ?ui.icons.Icon {
        return switch (bars) {
            0 => null,
            1, 2 => .wifi_1_bar,
            3 => .wifi_2_bar,
            else => if (locked) .wifi_password else .wifi,
        };
    }

    pub fn build(self: *const Signal, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const full: ui.icons.Icon = if (self.locked) .wifi_password else .wifi;
        const back = cx.make(ui.Icon{ .icon = full, .size = self.size, .color = t.on_surface.withAlpha(0.25) });
        const front = lit(self.bars, self.locked) orelse return back;
        return cx.make(ui.SizedBox{ .width = self.size, .height = self.size, .child = cx.make(ui.Overlay{ .children = &.{
            back,
            cx.make(ui.Icon{ .icon = front, .size = self.size, .color = t.on_surface }),
        } }) });
    }
};

const testing = std.testing;
const font = @import("font");

test "the Wi-Fi page says when it cannot list networks" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    const no_adapter: info.manager.Report = .{};
    const denied: info.manager.Report = .{ .denied = true };
    var empty: info.manager.Report = .{ .scanning = true };
    empty.adapter = .{ .up = true };
    for ([_]struct { ?*const info.manager.Report, []const u8 }{
        .{ null, "The network manager is not running" },
        .{ &no_adapter, "No Wi-Fi adapter" },
        .{ &denied, "Not allowed to scan" },
        .{ &empty, "Scanning…" },
    }) |case| {
        u.frame(1920, 960, 0, Settings{ .commit = "x", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = case[0] });
        var all: std.ArrayList(u8) = .empty;
        defer all.deinit(testing.allocator);
        view.texts(u.root.?, &all);
        try testing.expect(std.mem.indexOf(u8, all.items, case[1]) != null);
    }
}

test "SSIDs that are not text are shown readably" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var r: info.manager.Report = .{};
    r.adapter = .{ .up = true };
    var odd: info.manager.Network = .{ .signal_mbm = -5000, .freq_mhz = 2412, .security = .wpa2 };
    odd.setSsid("bad\xffname");
    r.add(odd);
    u.frame(1920, 960, 0, Settings{ .commit = "x", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &r });
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    view.texts(u.root.?, &all);
    try testing.expect(std.mem.indexOf(u8, all.items, "bad?name") != null);
}

test "choosing a network, typing its password and connecting" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    const wifi = view.sampleWifi();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi };
    u.frame(1920, 960, 0, settings);
    view.click(u, view.findText(u.root.?, "Home").?);
    u.frame(1920, 960, 1, settings);
    // The form fits at every size the shell gives, even with another
    // connection being made (and its Disconnect button).
    var joining = wifi;
    joining.connection = .{ .state = .authenticating };
    joining.connection.setSsid("Cafe");
    for ([_]*const info.manager.Report{ &wifi, &joining }) |report| for (view.test_sizes) |size| {
        u.frame(size[0], size[1], 2, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = report });
        try testing.expect(!view.overflows(u.root.?));
    };
    u.frame(1920, 960, 3, settings);
    view.click(u, view.findType(u.root.?, ui.TextField).?);
    for ("hunter22") |c| {
        const code: u32 = switch (c) {
            'h' => 35,
            'u' => 22,
            'n' => 49,
            't' => 20,
            'e' => 18,
            'r' => 19,
            '2' => 3,
            else => unreachable,
        };
        u.keyEvent(code, true);
        u.keyEvent(code, false);
    }
    u.keyEvent(ui.keymap.enter, true);
    const j = actions.connect.?;
    try testing.expectEqualStrings("Home", j.ssid());
    try testing.expectEqualStrings("hunter22", j.passphrase());
    // The form closes once asked.
    u.frame(1920, 960, 4, settings);
    try testing.expect(view.findType(u.root.?, ui.TextField) == null);

    // Connected: the connection row says so, with Disconnect.
    var joined = wifi;
    joined.connection = .{ .state = .connected, .address = .{ 192, 168, 1, 50 } };
    joined.connection.setSsid("Home");
    u.frame(1920, 960, 5, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &joined });
    try testing.expect(view.findText(u.root.?, "Connected to Home (192.168.1.50)") != null);
    view.click(u, view.findText(u.root.?, "Disconnect").?);
    try testing.expect(actions.disconnect);

    // A network whose security is not supported cannot be joined.
    actions = .{};
    u.frame(1920, 960, 6, settings);
    view.click(u, view.findText(u.root.?, "Library").?);
    u.frame(1920, 960, 7, settings);
    try testing.expect(view.findText(u.root.?, "Enterprise networks are not supported yet") != null);
    view.click(u, view.findText(u.root.?, "Connect").?);
    try testing.expect(actions.connect == null);

    // Failures say why.
    var failed = wifi;
    failed.connection = .{ .state = .failed, .failure = .wrong_password };
    failed.connection.setSsid("Home");
    u.frame(1920, 960, 8, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &failed });
    try testing.expect(view.findText(u.root.?, "Could not connect to Home: wrong password") != null);
}

test "choosing between multiple Wi-Fi adapters with pill buttons" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var report = view.sampleWifi();
    // With a single Wi-Fi adapter, no pill button is shown.
    var actions: Actions = .{};
    u.frame(1920, 960, 0, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(view.findType(u.root.?, PillButton) == null);

    // With two Wi-Fi adapters, pill buttons appear at the top.
    var a0: info.manager.Adapter = .{ .mac = .{ 0xb8, 0x27, 0xeb, 1, 2, 3 }, .up = true };
    a0.setName("wlan0");
    var a1: info.manager.Adapter = .{ .mac = .{ 0x00, 0xe0, 0x4c, 4, 5, 6 }, .up = true };
    a1.setName("wlan1");
    report.addAdapter(a0);
    report.addAdapter(a1);
    u.frame(1920, 960, 1, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(view.findText(u.root.?, "b8:27:eb:01:02:03") != null);
    try testing.expect(view.findText(u.root.?, "00:e0:4c:04:05:06") == null);
    view.click(u, view.up(view.findText(u.root.?, "wlan1").?, PillButton).?);
    try testing.expectEqualStrings("wlan1", actions.wifi_adapter.?.slice());
    u.frame(1920, 960, 2, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(view.findText(u.root.?, "00:e0:4c:04:05:06") != null);
    try testing.expect(view.findText(u.root.?, "b8:27:eb:01:02:03") == null);
}
