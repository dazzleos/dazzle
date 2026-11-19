//! The Ethernet page: the adapter chosen (when there is more than one),
//! its status, address (with a configure button to choose between DHCP and
//! a static address, and to see the gateway), and MAC address.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const locale = @import("locale");
const info = @import("info.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;
const PillBar = kete.PillBar;
const PillButton = kete.PillButton;

pub const label = "Ethernet";
pub const icon: kete.IconName = .lan;

pub const State = struct {
    /// The Ethernet adapter picked, when there is more than one.
    adapter: usize = 0,
    /// The form for a static address is open (chosen, before it is applied),
    /// what is typed in it, and whether that was not an address.
    static_form: bool = false,
    form_filled: bool = false,
    form_id: u32 = 0,
    address: Field = .{},
    gateway: Field = .{},
    static_invalid: bool = false,

    pub const Field = struct {
        buf: [32]u8 = undefined,
        len: u8 = 0,

        pub fn text(f: *const Field) []const u8 {
            return f.buf[0..f.len];
        }

        pub fn set(f: *Field, t: []const u8) void {
            f.len = @intCast(@min(t.len, f.buf.len));
            @memcpy(f.buf[0..f.len], t[0..f.len]);
        }
    };

    pub fn setAddress(st: *State, t: []const u8) void {
        st.address.set(t);
    }

    pub fn setGateway(st: *State, t: []const u8) void {
        st.gateway.set(t);
    }
};

pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const net = self.network;
    var rows: std.ArrayList(kete.Widget) = .empty;
    const a = cx.arena;
    const ifaces = net.slice();
    if (ifaces.len == 0) {
        rows.append(a, b.item(locale.text("Status"), locale.text("No adapter: plug in a USB Ethernet adapter"))) catch {};
        return b.page(rows.items);
    }
    const idx = @min(state.adapter, ifaces.len - 1);
    state.adapter = idx;
    if (ifaces.len > 1) {
        var pills: std.ArrayList(kete.Widget) = .empty;
        for (ifaces, 0..) |*ifc, k| {
            pills.append(a, cx.make(PillButton{
                .label = ifc.name.slice(),
                .selected = k == idx,
                .first = k == 0,
                .last = k + 1 == ifaces.len,
                .on_press = pickAdapter(cx, state, k),
            })) catch {};
        }
        rows.append(a, cx.make(kete.Align{ .height_factor = 1, .child = cx.make(PillBar{ .children = pills.items }) })) catch {};
    }
    const i = &ifaces[idx];
    const status = if (!std.mem.eql(u8, i.state.slice(), "up") and !i.carrier)
        (if (std.mem.eql(u8, i.state.slice(), "down")) locale.text("Not connected: no cable") else kete_vc4.textf(cx, "Not connected ({s})", .{i.state.slice()}))
    else if (i.speed) |mbps|
        kete_vc4.textf(cx, "Connected at {d} Mb/s", .{mbps})
    else
        locale.text("Connected");
    rows.append(a, b.item(locale.text("Status"), status)) catch {};
    const current = addressing(self, i.name.slice());
    const method = if (current == .static) "static" else "DHCP";
    const address = if (i.ip) |ip|
        kete_vc4.textf(cx, "{d}.{d}.{d}.{d}/{d} ({s})", .{ ip[0], ip[1], ip[2], ip[3], i.prefix, method })
    else if (i.carrier)
        kete_vc4.textf(cx, "Waiting for an address ({s})", .{method})
    else
        locale.text("Not assigned");
    rows.append(a, addressRow(self, b, state, i, current, address)) catch {};
    if (i.mac.len > 0) rows.append(a, b.item(locale.text("MAC address"), i.mac.slice())) catch {};
    return b.page(rows.items);
}

fn addressRow(
    self: *const Settings,
    b: Builder,
    state: *State,
    iface: *const info.Interface,
    current: info.manager.Addressing,
    address_text: []const u8,
) kete.Widget {
    const cx = b.cx;
    const t = cx.theme();
    return cx.make(kete.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
        cx.make(kete.SizedBox{ .width = 150, .child = cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 4, .children = &.{
            cx.make(kete.Text{ .text = locale.text("Address"), .style = .{ .size = 18, .color = t.on_surface_variant }, .wrap = false }),
            cx.make(AddressConfigButton{
                .state = state,
                .actions = if (self.manager != null) self.actions else null,
                .current = current,
                .adapter = iface.name,
                .ip = iface.ip,
                .prefix = iface.prefix,
                .gateway = self.network.gateway,
            }),
        } }) }),
        cx.make(kete.Expanded{ .child = b.value(address_text) }),
    } });
}

const PickAdapter = struct {
    state: *State,
    index: usize,

    fn press(p: *PickAdapter) void {
        if (p.state.adapter != p.index) {
            p.state.adapter = p.index;
            p.state.static_form = false;
            p.state.form_filled = false;
            p.state.static_invalid = false;
        }
    }
};

fn pickAdapter(cx: *kete.BuildContext, state: *State, index: usize) ?kete.Callback {
    const p = cx.arena.create(PickAdapter) catch return null;
    p.* = .{ .state = state, .index = index };
    return .of(p, PickAdapter.press);
}

/// How the wired adapter `name` gets its address, as the network manager says.
fn addressing(self: *const Settings, name: []const u8) info.manager.Addressing {
    return if (self.manager) |m| m.addressingFor(name) else .dhcp;
}

const Mode = enum { dhcp, static };
const PageState = State;

/// An icon beside "Address": pressing it opens a popup to switch between
/// DHCP (showing the assigned gateway) and a static address.
pub const AddressConfigButton = struct {
    state: *PageState,
    actions: ?*Actions,
    current: info.manager.Addressing,
    adapter: info.Str(16),
    ip: ?[4]u8,
    prefix: u8,
    gateway: ?[4]u8,

    pub const State = BtnState;
    pub const BtnState = struct {
        node: ?*kete.WidgetNode = null,
        state: ?*PageState = null,
        actions: ?*Actions = null,
        current: info.manager.Addressing = .dhcp,
        adapter: info.Str(16) = .{},
        ip: ?[4]u8 = null,
        prefix: u8 = 0,
        gateway: ?[4]u8 = null,
        interaction: kete.PointerInteraction = .{},

        fn open(st: *BtnState) void {
            const n = st.node orelse return;
            const page_st = st.state orelse return;
            page_st.static_invalid = false;
            if (st.current == .dhcp) page_st.form_filled = false;
            const pos = n.position();
            n.ui.openPopup(n, .{ pos[0], pos[1] + n.size.h }, .of(st, BtnState.buildPopup));
        }

        fn chooseDhcp(st: *BtnState) void {
            const page_st = st.state orelse return;
            page_st.static_form = false;
            page_st.form_filled = false;
            page_st.static_invalid = false;
            if (st.current == .static) if (st.actions) |acts| {
                acts.ethernet = .dhcp;
                acts.ethernet_adapter = st.adapter;
            };
        }

        fn chooseStatic(st: *BtnState) void {
            const page_st = st.state orelse return;
            page_st.static_form = true;
        }

        fn apply(st: *BtnState) void {
            const page_st = st.state orelse return;
            const static = info.manager.Static.parse(std.mem.trim(u8, page_st.address.text(), " "), page_st.gateway.text()) orelse {
                page_st.static_invalid = true;
                return;
            };
            page_st.static_invalid = false;
            page_st.static_form = false;
            if (st.actions) |acts| {
                acts.ethernet = .{ .static = static };
                acts.ethernet_adapter = st.adapter;
            }
            if (st.node) |n| n.ui.closeMenu();
        }

        fn buildPopup(st: *BtnState, cx: *kete.BuildContext) kete.Widget {
            const page_st = st.state orelse return cx.make(kete.SizedBox.empty);
            const t = cx.theme();
            const a = cx.arena;
            const static = page_st.static_form or st.current == .static;
            var rows: std.ArrayList(kete.Widget) = .empty;
            rows.append(a, cx.make(kete.Align{ .height_factor = 1, .child = cx.make(PillBar{ .children = &.{
                cx.make(PillButton{
                    .label = locale.text("DHCP"),
                    .selected = !static,
                    .first = true,
                    .last = false,
                    .on_press = if (st.actions != null) .of(st, BtnState.chooseDhcp) else null,
                }),
                cx.make(PillButton{
                    .label = locale.text("Static"),
                    .selected = static,
                    .first = false,
                    .last = true,
                    .on_press = if (st.actions != null) .of(st, BtnState.chooseStatic) else null,
                }),
            } }) })) catch {};

            if (!static) {
                const gw_text = if (st.gateway) |g| kete_vc4.textf(cx, "{d}.{d}.{d}.{d} (DHCP)", .{ g[0], g[1], g[2], g[3] }) else locale.text("None");
                rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                    cx.make(kete.SizedBox{ .width = 110, .child = cx.make(kete.Text{ .text = locale.text("Gateway"), .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = gw_text, .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }) }),
                } })) catch {};
            } else {
                if (!page_st.form_filled) {
                    page_st.form_filled = true;
                    page_st.form_id +%= 1;
                    page_st.static_invalid = false;
                    var buf: [64]u8 = undefined;
                    switch (st.current) {
                        .static => |s| {
                            const ad = s.address;
                            page_st.address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ad[0], ad[1], ad[2], ad[3], s.prefix }) catch "");
                            page_st.gateway.set(if (s.gateway) |g| std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) catch "" else "");
                        },
                        .dhcp => {
                            page_st.address.len = 0;
                            page_st.gateway.len = 0;
                            if (st.ip) |ip| {
                                page_st.address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ip[0], ip[1], ip[2], ip[3], st.prefix }) catch "");
                            }
                            if (st.gateway) |g| page_st.gateway.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) catch "");
                        },
                    }
                }
                const on_apply: ?kete.Callback = if (st.actions != null) .of(st, BtnState.apply) else null;
                const key = @as(u64, page_st.form_id) << 1;
                rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                    cx.make(kete.SizedBox{ .width = 110, .child = cx.make(kete.Text{ .text = locale.text("Address"), .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.TextField{
                        .placeholder = locale.text("Address/prefix"),
                        .initial = page_st.address.text(),
                        .max_len = page_st.address.buf.len,
                        .size = 16,
                        .on_changed = .of(page_st, PageState.setAddress),
                        .on_submit = on_apply,
                    }).withKey(key) }),
                } })) catch {};
                rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                    cx.make(kete.SizedBox{ .width = 110, .child = cx.make(kete.Text{ .text = locale.text("Gateway"), .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.TextField{
                        .placeholder = locale.text("Gateway"),
                        .initial = page_st.gateway.text(),
                        .max_len = page_st.gateway.buf.len,
                        .size = 16,
                        .on_changed = .of(page_st, PageState.setGateway),
                        .on_submit = on_apply,
                    }).withKey(key | 1) }),
                } })) catch {};
                if (page_st.static_invalid) rows.append(a, cx.make(kete.Text{
                    .text = locale.text("Give an address and prefix length (192.168.1.50/24), and a gateway or none"),
                    .style = .{ .size = 15, .color = t.@"error" },
                })) catch {};
                rows.append(a, cx.make(kete.Row{ .main_axis_alignment = .end, .children = &.{
                    cx.make(kete.OutlinedButton{ .label = locale.text("Apply"), .on_press = on_apply }),
                } })) catch {};
            }

            return cx.make(kete.RoundedBox{
                .color = t.surface_container,
                .border_width = 1,
                .border_color = t.outline_variant,
                .radius = .all(8),
                .child = cx.make(kete.SizedBox{ .width = 360, .child = cx.make(kete.Padding{
                    .padding = .all(16),
                    .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 12, .children = rows.items }),
                }) }),
            });
        }
    };

    pub fn build(self: *const AddressConfigButton, cx: *kete.BuildContext, state: *BtnState) kete.Widget {
        state.node = cx.node;
        state.state = self.state;
        state.actions = self.actions;
        state.current = self.current;
        state.adapter = self.adapter;
        state.ip = self.ip;
        state.prefix = self.prefix;
        state.gateway = self.gateway;
        return cx.make(kete.IconButton{
            .icon = .settings,
            .size = 24,
            .icon_size = 18,
            .on_press = if (self.actions != null) .of(state, BtnState.open) else null,
        });
    }
};

const testing = std.testing;
const font = kete.font;

test "without a network adapter, the Ethernet page says so" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    const none: info.Network = .{};
    const settings: Settings = .{ .commit = "x", .system = &d.sys, .usage = .{}, .network = &none };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .ethernet;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "No adapter: plug in a USB Ethernet adapter") != null);
}

test "choosing a static address for Ethernet in the Address popup, and DHCP again" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var report = view.sampleWifi();
    var actions: Actions = .{};
    var frame_no: u64 = 0;
    const Draw = struct {
        fn draw(uu: *kete.ui.WindowUi, dd: anytype, r: *const info.manager.Report, acts: *Actions, n: *u64, size: [2]u32) void {
            n.* += 1;
            uu.frame(size[0], size[1], n.*, Settings{ .commit = "x", .actions = acts, .system = &dd.sys, .usage = dd.usage, .network = &dd.net, .manager = r });
        }
    }.draw;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    u.root.?.state(Settings.State).page = .ethernet;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "192.168.1.42/24 (DHCP)") != null);
    try testing.expect(view.findText(u.root.?, "Traffic") == null);
    try testing.expect(view.findText(u.root.?, "Gateway") == null);
    try testing.expect(view.findType(u.root.?, AddressConfigButton) != null);
    try testing.expect(u.menu_root == null);

    // Clicking the configure icon beside Address opens the popup showing DHCP, Static, and the assigned Gateway.
    view.click(u, view.findType(u.root.?, AddressConfigButton).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(u.menu_root != null);
    try testing.expect(view.findText(u.menu_root.?, "DHCP") != null);
    try testing.expect(view.findText(u.menu_root.?, "Static") != null);
    try testing.expect(view.findText(u.menu_root.?, "Gateway") != null);
    try testing.expect(view.findText(u.menu_root.?, "192.168.1.1 (DHCP)") != null);

    // Static opens the form in the popup, filled in with what DHCP gave; it fits.
    view.click(u, view.findText(u.menu_root.?, "Static").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    const field = view.findType(u.menu_root.?, kete.TextField).?;
    try testing.expectEqualStrings("192.168.1.42/24", field.state(kete.TextField.State).text());
    try testing.expect(actions.ethernet == null);
    for ([_][2]u32{ .{ 1920, 960 }, .{ 1280, 600 }, .{ 1024, 668 }, .{ 960, 480 } }) |size| {
        Draw(u, d, &report, &actions, &frame_no, size);
        try testing.expect(!view.overflows(u.root.?));
        try testing.expect(!view.overflows(u.menu_root.?));
    }
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });

    // Not an address: it says so, and asks nothing.
    var st = &u.root.?.state(Settings.State).ethernet;
    st.address.set("192.168.1/24");
    view.click(u, view.findText(u.menu_root.?, "Apply").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(actions.ethernet == null);
    try testing.expect(view.findText(u.menu_root.?, "Give an address and prefix length (192.168.1.50/24), and a gateway or none") != null);
    // An address: it is asked for, and the popup closes.
    st = &u.root.?.state(Settings.State).ethernet;
    st.address.set("192.168.1.50/24");
    view.click(u, view.findText(u.menu_root.?, "Apply").?);
    try testing.expectEqual(info.manager.Static.parse("192.168.1.50/24", "192.168.1.1").?, actions.ethernet.?.static);
    actions = .{};

    // The manager now says static: reopening the popup shows the static form, and choosing DHCP asks for DHCP at once.
    report.ethernet.addressing = .{ .static = info.manager.Static.parse("192.168.1.50/24", "192.168.1.1").? };
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "192.168.1.42/24 (static)") != null);
    view.click(u, view.findType(u.root.?, AddressConfigButton).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findType(u.menu_root.?, kete.TextField) != null);
    view.click(u, view.findText(u.menu_root.?, "DHCP").?);
    try testing.expect(actions.ethernet.? == .dhcp);
    report.ethernet.addressing = .dhcp;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findType(u.menu_root.?, kete.TextField) == null);
}

test "choosing between multiple Ethernet adapters with pill buttons" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var d = view.sample();
    d.net.len = 2;
    const report = view.sampleWifi();
    var actions: Actions = .{};
    u.frame(1920, 960, 0, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    u.root.?.state(Settings.State).page = .ethernet;
    u.frame(1920, 960, 1, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(view.findText(u.root.?, "Connected at 100 Mb/s") != null);
    try testing.expect(view.findText(u.root.?, "Not connected: no cable") == null);
    view.click(u, view.up(view.findText(u.root.?, "eth1").?, PillButton).?);
    u.frame(1920, 960, 2, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(view.findText(u.root.?, "Not connected: no cable") != null);
    try testing.expect(view.findText(u.root.?, "Connected at 100 Mb/s") == null);
}
