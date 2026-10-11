//! The Ethernet page: the adapter chosen (when there is more than one),
//! its status, address, traffic, MAC address and gateway, and choosing
//! between DHCP and a static address.

const std = @import("std");
const ui = @import("ui");
const info = @import("info.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;
const PillBar = ui.PillBar;
const PillButton = ui.PillButton;

pub const label = "Ethernet";
pub const icon: ui.icons.Icon = .lan;

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

pub fn build(self: *const Settings, b: Builder, state: *State) ui.Widget {
    const cx = b.cx;
    const net = self.network;
    var rows: std.ArrayList(ui.Widget) = .empty;
    const a = cx.ui.arena();
    const ifaces = net.slice();
    if (ifaces.len == 0) {
        rows.append(a, b.item("Status", "No adapter: plug in a USB Ethernet adapter")) catch {};
        return b.page(rows.items);
    }
    const idx = @min(state.adapter, ifaces.len - 1);
    state.adapter = idx;
    if (ifaces.len > 1) {
        var pills: std.ArrayList(ui.Widget) = .empty;
        for (ifaces, 0..) |*ifc, k| {
            pills.append(a, cx.make(PillButton{
                .label = ifc.name.slice(),
                .selected = k == idx,
                .first = k == 0,
                .last = k + 1 == ifaces.len,
                .on_press = pickAdapter(cx, state, k),
            })) catch {};
        }
        rows.append(a, cx.make(ui.Center{ .height_factor = 1, .child = cx.make(PillBar{ .children = pills.items }) })) catch {};
    }
    const i = &ifaces[idx];
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const status = if (!std.mem.eql(u8, i.state.slice(), "up") and !i.carrier)
        (if (std.mem.eql(u8, i.state.slice(), "down")) "Not connected: no cable" else cx.fmt("Not connected ({s})", .{i.state.slice()}))
    else if (i.speed) |mbps|
        cx.fmt("Connected at {d} Mb/s", .{mbps})
    else
        "Connected";
    rows.append(a, b.item("Status", status)) catch {};
    const method = if (addressing(self, i.name.slice()) == .static) "static" else "DHCP";
    // An adapter without a link has no address or traffic to show.
    if (i.carrier or i.ip != null) {
        const address = if (i.ip) |ip|
            cx.fmt("{d}.{d}.{d}.{d}/{d} ({s})", .{ ip[0], ip[1], ip[2], ip[3], i.prefix, method })
        else
            cx.fmt("Waiting for an address ({s})", .{method});
        rows.append(a, b.item("Address", address)) catch {};
        rows.append(a, b.item("Traffic", cx.fmt("{s} received, {s} sent", .{ info.formatBytes(&b1, i.rx_bytes), info.formatBytes(&b2, i.tx_bytes) }))) catch {};
    }
    if (i.mac.len > 0) rows.append(a, b.item("MAC address", i.mac.slice())) catch {};
    if (net.gateway) |g| rows.append(a, b.item("Gateway", cx.fmt("{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }))) catch {};
    // How the adapter gets its address, if there is one and the
    // network manager can be asked.
    if (self.manager != null) addressingRows(self, b, state, i, &rows);
    return b.page(rows.items);
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

fn pickAdapter(cx: *ui.Context, state: *State, index: usize) ?ui.Callback {
    const p = cx.ui.arena().create(PickAdapter) catch return null;
    p.* = .{ .state = state, .index = index };
    return .of(p, PickAdapter.press);
}

/// How the wired adapter `name` gets its address, as the network manager says.
fn addressing(self: *const Settings, name: []const u8) info.manager.Addressing {
    return if (self.manager) |m| m.addressingFor(name) else .dhcp;
}

/// DHCP or a static address, and the form for a static address while
/// that is chosen.
fn addressingRows(self: *const Settings, b: Builder, state: *State, iface: *const info.Interface, rows: *std.ArrayList(ui.Widget)) void {
    const cx = b.cx;
    const a = cx.ui.arena();
    const current = addressing(self, iface.name.slice());
    const static = state.static_form or current == .static;
    const choice = cx.ui.arena().create(Addressing) catch return;
    choice.* = .{ .actions = self.actions, .state = state, .current = current, .adapter = iface.name };
    const on_changed: ?ui.ValueCallback(Mode) = if (self.actions != null) .of(choice, Addressing.choose) else null;
    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        b.label("Addressing"),
        cx.make(ui.Radio(Mode){ .value = .dhcp, .group_value = if (static) .static else .dhcp, .on_changed = on_changed, .label = "DHCP" }),
        cx.make(ui.Radio(Mode){ .value = .static, .group_value = if (static) .static else .dhcp, .on_changed = on_changed, .label = "Static" }),
    } })) catch {};
    if (!static) return;

    // The fields start with the static address in use, or else the one
    // DHCP gave.
    if (!state.form_filled) {
        state.form_filled = true;
        state.form_id +%= 1;
        state.static_invalid = false;
        var buf: [64]u8 = undefined;
        switch (current) {
            .static => |st| {
                const ad = st.address;
                state.address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ad[0], ad[1], ad[2], ad[3], st.prefix }) catch "");
                state.gateway.set(if (st.gateway) |g| std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) catch "" else "");
            },
            .dhcp => {
                state.address.len = 0;
                state.gateway.len = 0;
                if (iface.ip) |ip| {
                    state.address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ip[0], ip[1], ip[2], ip[3], iface.prefix }) catch "");
                }
                if (self.network.gateway) |g| state.gateway.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) catch "");
            },
        }
    }
    const on_apply: ?ui.Callback = if (self.actions != null) .of(choice, Addressing.apply) else null;
    const key = @as(u64, state.form_id) << 1;
    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        cx.make(ui.SizedBox{ .width = 150 }),
        cx.make(ui.Expanded{ .flex = 3, .child = cx.make(ui.TextField{
            .placeholder = "Address/prefix",
            .initial = state.address.text(),
            .max_len = state.address.buf.len,
            .size = 18,
            .on_changed = .of(state, State.setAddress),
            .on_submit = on_apply,
        }).withKey(key) }),
        cx.make(ui.Expanded{ .flex = 2, .child = cx.make(ui.TextField{
            .placeholder = "Gateway",
            .initial = state.gateway.text(),
            .max_len = state.gateway.buf.len,
            .size = 18,
            .on_changed = .of(state, State.setGateway),
            .on_submit = on_apply,
        }).withKey(key | 1) }),
        cx.make(ui.OutlinedButton{ .label = "Apply", .on_press = on_apply }),
    } })) catch {};
    if (state.static_invalid) rows.append(a, cx.make(ui.Row{ .spacing = 12, .children = &.{
        cx.make(ui.SizedBox{ .width = 150 }),
        cx.make(ui.Expanded{ .child = cx.make(ui.Text{
            .text = "Give an address and prefix length (192.168.1.50/24), and a gateway or none",
            .style = .{ .size = 16, .color = cx.ui.theme.@"error" },
        }) }),
    } })) catch {};
}

const Mode = enum { dhcp, static };

/// Choosing DHCP or a static address, and applying one.
const Addressing = struct {
    actions: ?*Actions,
    state: *State,
    current: info.manager.Addressing,
    adapter: info.Str(16),

    fn choose(x: *Addressing, mode: Mode) void {
        const st = x.state;
        switch (mode) {
            .dhcp => {
                st.static_form = false;
                st.form_filled = false;
                if (x.current == .static) if (x.actions) |acts| {
                    acts.ethernet = .dhcp;
                    acts.ethernet_adapter = x.adapter;
                };
            },
            // The form opens; nothing changes until it is applied.
            .static => st.static_form = true,
        }
    }

    fn apply(x: *Addressing) void {
        const st = x.state;
        const static = info.manager.Static.parse(std.mem.trim(u8, st.address.text(), " "), st.gateway.text()) orelse {
            st.static_invalid = true;
            return;
        };
        st.static_invalid = false;
        st.static_form = false;
        if (x.actions) |acts| {
            acts.ethernet = .{ .static = static };
            acts.ethernet_adapter = x.adapter;
        }
    }
};

const testing = std.testing;
const font = @import("font");

test "without a network adapter, the Ethernet page says so" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    const none: info.Network = .{};
    const settings: Settings = .{ .commit = "x", .system = &d.sys, .usage = .{}, .network = &none };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .ethernet;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "No adapter: plug in a USB Ethernet adapter") != null);
}

test "choosing a static address for Ethernet, and DHCP again" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var report = view.sampleWifi();
    var actions: Actions = .{};
    var frame_no: u64 = 0;
    const Draw = struct {
        fn draw(uu: *ui.Ui, dd: anytype, r: *const info.manager.Report, acts: *Actions, n: *u64, size: [2]u32) void {
            n.* += 1;
            uu.frame(size[0], size[1], n.*, Settings{ .commit = "x", .actions = acts, .system = &dd.sys, .usage = dd.usage, .network = &dd.net, .manager = r });
        }
    }.draw;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    u.root.?.state(Settings.State).page = .ethernet;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "Addressing") != null);
    try testing.expect(view.findText(u.root.?, "192.168.1.42/24 (DHCP)") != null);
    try testing.expect(view.findType(u.root.?, ui.TextField) == null);

    // Static opens the form, filled in with what DHCP gave; it fits.
    view.click(u, view.findText(u.root.?, "Static").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    const field = view.findType(u.root.?, ui.TextField).?;
    try testing.expectEqualStrings("192.168.1.42/24", field.state(ui.TextField.State).text());
    try testing.expect(actions.ethernet == null);
    for ([_][2]u32{ .{ 1920, 960 }, .{ 1280, 600 }, .{ 1024, 668 }, .{ 960, 480 } }) |size| {
        Draw(u, d, &report, &actions, &frame_no, size);
        try testing.expect(!view.overflows(u.root.?));
    }
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });

    // Not an address: it says so, and asks nothing.
    var st = &u.root.?.state(Settings.State).ethernet;
    st.address.set("192.168.1/24");
    view.click(u, view.findText(u.root.?, "Apply").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(actions.ethernet == null);
    try testing.expect(view.findText(u.root.?, "Give an address and prefix length (192.168.1.50/24), and a gateway or none") != null);
    // An address: it is asked for.
    st = &u.root.?.state(Settings.State).ethernet;
    st.address.set("192.168.1.50/24");
    view.click(u, view.findText(u.root.?, "Apply").?);
    try testing.expectEqual(info.manager.Static.parse("192.168.1.50/24", "192.168.1.1").?, actions.ethernet.?.static);
    actions = .{};

    // The manager now says static: the form stays, filled in with it.
    report.ethernet.addressing = .{ .static = info.manager.Static.parse("192.168.1.50/24", "192.168.1.1").? };
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "192.168.1.42/24 (static)") != null);
    try testing.expect(view.findType(u.root.?, ui.TextField) != null);
    // DHCP again is asked for at once, and the form closes.
    view.click(u, view.findText(u.root.?, "DHCP").?);
    try testing.expect(actions.ethernet.? == .dhcp);
    report.ethernet.addressing = .dhcp;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findType(u.root.?, ui.TextField) == null);
}

test "choosing between multiple Ethernet adapters with pill buttons" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
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
