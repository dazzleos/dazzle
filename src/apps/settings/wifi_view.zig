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
const PillBar = ui.PillBar;
const PillButton = ui.PillButton;

pub const label = "Wi-Fi";
pub const icon: ui.icons.Icon = .wifi;

pub const Mode = enum { client, access_point };

pub const State = struct {
    /// The Wi-Fi adapter picked, when there is more than one.
    adapter: usize = 0,
    /// The Wi-Fi network chosen (its SSID), and the password typed.
    selected_buf: [32]u8 = undefined,
    selected_len: u8 = 0,
    has_selected: bool = false,
    password_buf: [63]u8 = undefined,
    password_len: u8 = 0,
    /// Client static address popup state.
    static_form: bool = false,
    static_filled: bool = false,
    static_id: u32 = 0,
    static_address: Field = .{},
    static_gateway: Field = .{},
    static_invalid: bool = false,
    /// Access point mode form state.
    hotspot_form: bool = false,
    form_filled: bool = false,
    form_id: u32 = 0,
    hotspot_ssid: Field = .{},
    hotspot_password: Field = .{},
    hotspot_network: info.manager.HotspotNetwork = .{},
    hotspot_upstream: info.Str(16) = .{},
    hotspot_invalid: bool = false,
    /// Access point address popup state.
    ap_address: Field = .{},
    ap_address_invalid: bool = false,
    ap_address_id: u32 = 0,

    pub const Field = struct {
        buf: [63]u8 = undefined,
        len: u8 = 0,

        pub fn text(f: *const Field) []const u8 {
            return f.buf[0..f.len];
        }

        pub fn set(f: *Field, t: []const u8) void {
            f.len = @intCast(@min(t.len, f.buf.len));
            @memcpy(f.buf[0..f.len], t[0..f.len]);
        }
    };

    pub fn selected(st: *const State) ?[]const u8 {
        return if (st.has_selected) st.selected_buf[0..st.selected_len] else null;
    }

    pub fn setPassword(st: *State, text: []const u8) void {
        st.password_len = @intCast(@min(text.len, st.password_buf.len));
        @memcpy(st.password_buf[0..st.password_len], text[0..st.password_len]);
    }

    pub fn setStaticAddress(st: *State, text: []const u8) void {
        st.static_address.set(text);
    }

    pub fn setStaticGateway(st: *State, text: []const u8) void {
        st.static_gateway.set(text);
    }

    pub fn setHotspotSsid(st: *State, text: []const u8) void {
        st.hotspot_ssid.set(text);
    }

    pub fn setHotspotPassword(st: *State, text: []const u8) void {
        st.hotspot_password.set(text);
    }

    pub fn setApAddress(st: *State, text: []const u8) void {
        st.ap_address.set(text);
    }

    pub fn validHotspotNameAndPassword(st: *const State) bool {
        const ssid = std.mem.trim(u8, st.hotspot_ssid.text(), " ");
        const pass = st.hotspot_password.text();
        if (ssid.len < 1 or ssid.len > 32) return false;
        if (pass.len < 8 or pass.len > 63) return false;
        for (pass) |c| if (c < 0x20 or c > 0x7e) return false;
        return true;
    }
};

pub fn build(self: *const Settings, b: Builder, state: *State) ui.Widget {
    const cx = b.cx;
    const report = self.manager orelse return b.scroll(.wifi, b.page(&.{b.item("Status", "The network manager is not running")}));
    if (report.denied) return b.scroll(.wifi, b.page(&.{b.item("Status", "Not allowed to scan")}));
    const adapters = report.wifiAdapters();
    if (adapters.len == 0) return b.scroll(.wifi, b.page(&.{b.item("Status", "No Wi-Fi adapter")}));
    const idx = @min(state.adapter, adapters.len - 1);
    state.adapter = idx;
    const adapter = adapters[idx];
    var rows: std.ArrayList(ui.Widget) = .empty;
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
        rows.append(a, cx.make(ui.Center{ .height_factor = 1, .child = cx.make(PillBar{ .children = pills.items }) })) catch {};
    }
    const hs = &report.hotspot;
    const on_this_hs = hs.adapter_len == 0 or std.mem.eql(u8, hs.adapter(), adapter.name());
    const current_hs = on_this_hs and hs.state != .off;
    const is_hotspot = state.hotspot_form or current_hs;
    const upstreams = upstreamOptions(self, adapter.name());
    if (is_hotspot) ensureHotspotDefaults(self, state, hs, on_this_hs, &upstreams);

    const active_hs = is_hotspot and current_hs and hs.state == .active;
    const mode_row = modeRow(self, b, state, adapter.name(), hs, on_this_hs, current_hs, is_hotspot, &upstreams);
    const status_row = statusRow(self, b, state, adapter.name(), &report.connection, hs, is_hotspot, report.scanning);
    const address_row = addressRow(self, b, state, adapter.name(), &report.connection, hs, current_hs, is_hotspot);
    const m = adapter.mac;
    const mac_row = b.item("MAC address", cx.fmt("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ m[0], m[1], m[2], m[3], m[4], m[5] }));

    if (active_hs) {
        const qr_ssid = if (hs.ssid_len > 0) hs.ssid() else state.hotspot_ssid.text();
        const qr_pass = if (hs.passphrase().len > 0) hs.passphrase() else state.hotspot_password.text();
        rows.append(a, cx.make(ui.Overlay{
            .children = &.{
                b.page(&.{ mode_row, status_row, address_row, mac_row }),
                cx.make(ui.Align{
                    .alignment = .top_right,
                    .child = cx.make(ui.QrCode{ .text = wifiQrText(a, qr_ssid, qr_pass) }),
                }),
            },
        })) catch {};
    } else {
        rows.appendSlice(a, &.{ mode_row, status_row, address_row, mac_row }) catch {};
    }

    if (is_hotspot) {
        hotspotRows(self, b, state, adapter.name(), hs, current_hs, &upstreams, &rows);
        return b.scroll(.wifi, b.page(rows.items));
    }

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
    if (split > 0) list_rows.append(a, networkList(self, b, state, adapter.name(), report, nets[0..split], chosen)) catch {};
    if (form) list_rows.append(a, joinForm(self, b, state, adapter.name(), chosen.?)) catch {};
    if (split < nets.len) {
        if (form) list_rows.append(a, cx.make(ui.Divider{ .inset = 16 })) catch {};
        list_rows.append(a, networkList(self, b, state, adapter.name(), report, nets[split..], chosen)) catch {};
    }

    const net_label = if (nets.len > 0)
        cx.make(ui.Padding{ .padding = .{ .top = 19 }, .child = b.label("Network") })
    else
        b.label("Network");
    const net_content = if (nets.len > 0)
        cx.make(ui.Card{
            .variant = .outlined,
            .padding = .all(4),
            .child = cx.make(ui.Column{
                .main_axis_size = .min,
                .cross_axis_alignment = .stretch,
                .children = list_rows.items,
            }),
        })
    else if (!report.scanning)
        b.value("No networks found")
    else
        cx.make(ui.Empty{});
    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
        net_label,
        cx.make(ui.Expanded{ .child = net_content }),
    } })) catch {};

    return b.scroll(.wifi, b.page(rows.items));
}

const PickAdapter = struct {
    state: *State,
    actions: ?*Actions,
    index: usize,
    name: info.Str(16),

    fn press(p: *PickAdapter) void {
        p.state.adapter = p.index;
        p.state.has_selected = false;
        p.state.static_form = false;
        p.state.static_filled = false;
        p.state.static_invalid = false;
        p.state.hotspot_form = false;
        p.state.form_filled = false;
        p.state.hotspot_invalid = false;
        p.state.hotspot_network = .{};
        p.state.ap_address_invalid = false;
        if (p.actions) |acts| acts.wifi_adapter = p.name;
    }
};

fn pickAdapter(cx: *ui.Context, state: *State, actions: ?*Actions, index: usize, name: []const u8) ?ui.Callback {
    const p = cx.ui.arena().create(PickAdapter) catch return null;
    p.* = .{ .state = state, .actions = actions, .index = index, .name = .of(name) };
    return .of(p, PickAdapter.press);
}

/// The connection or access point state.
fn statusRow(
    _: *const Settings,
    b: Builder,
    _: *State,
    adapter_name: []const u8,
    c: *const info.manager.Connection,
    hs: *const info.manager.Hotspot,
    is_hotspot: bool,
    scanning: bool,
) ui.Widget {
    const cx = b.cx;
    if (is_hotspot) {
        const text = switch (hs.state) {
            .off => "Inactive",
            .active => "Active",
            .failed => cx.fmt("Could not start access point: {s}", .{hs.failure.label()}),
        };
        return b.item("Status", text);
    }
    const on_this = c.adapter_len == 0 or std.mem.eql(u8, c.adapter(), adapter_name);
    const name = printable(cx, c.ssid());
    const base = if (!on_this) "Not connected" else switch (c.state) {
        .idle => "Not connected",
        .connected => cx.fmt("Connected to {s}", .{name}),
        .connecting, .authenticating, .addressing => cx.fmt("{s}: {s}…", .{ name, c.state.label() }),
        .failed => cx.fmt("Could not connect to {s}: {s}", .{ name, c.failure.label() }),
    };
    const show_scan = scanning and (!on_this or switch (c.state) {
        .idle, .connected, .failed => true,
        .connecting, .authenticating, .addressing => false,
    });
    const text = if (show_scan) cx.fmt("{s}, scanning…", .{base}) else base;
    return b.item("Status", text);
}

/// The IPv4 address in CIDR format (`<ip>/<prefix>`) assigned to this host
/// on the Wi-Fi interface, or "Not assigned" when not connected in Client mode.
fn addressRow(
    self: *const Settings,
    b: Builder,
    state: *State,
    adapter_name: []const u8,
    c: *const info.manager.Connection,
    hs: *const info.manager.Hotspot,
    current_hs: bool,
    is_hotspot: bool,
) ui.Widget {
    const cx = b.cx;
    const t = cx.theme();
    const active_hs = current_hs and hs.state == .active;
    const addr = if (is_hotspot) blk: {
        const net = if (active_hs) hs.network() else state.hotspot_network;
        const ip = net.serverIp();
        break :blk cx.fmt("{d}.{d}.{d}.{d}/{d}", .{ ip[0], ip[1], ip[2], ip[3], net.prefix });
    } else blk: {
        const on_this = c.adapter_len == 0 or std.mem.eql(u8, c.adapter(), adapter_name);
        const method = if (c.addressing == .static) "static" else "DHCP";
        break :blk if (on_this and c.state == .connected)
            (if (c.address) |ip| cx.fmt("{d}.{d}.{d}.{d}/{d} ({s})", .{ ip[0], ip[1], ip[2], ip[3], c.prefix, method }) else "Not assigned")
        else
            "Not assigned";
    };
    const can_configure = self.actions != null and (!is_hotspot or !active_hs);
    return cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
        cx.make(ui.SizedBox{ .width = 150, .child = cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 4, .children = &.{
            cx.make(ui.Text{ .text = "Address", .style = .{ .size = 18, .color = t.on_surface_variant }, .wrap = false }),
            cx.make(AddressConfigButton{
                .state = state,
                .actions = if (can_configure) self.actions else null,
                .is_hotspot = is_hotspot,
                .current = c.addressing,
                .adapter = .of(adapter_name),
                .ip = c.address,
                .prefix = c.prefix,
                .gateway = self.network.gateway,
            }),
        } }) }),
        cx.make(ui.Expanded{ .child = b.value(addr) }),
    } });
}

const PageState = State;

/// An icon beside "Address": in Client mode, opens a popup to switch between
/// DHCP (showing the assigned gateway) and a static address; in Access Point
/// mode (when stopped), opens a popup to configure the access point's CIDR
/// address (`192.168.4.1/24`).
pub const AddressConfigButton = struct {
    state: *PageState,
    actions: ?*Actions,
    is_hotspot: bool,
    current: info.manager.Addressing,
    adapter: info.Str(16),
    ip: ?[4]u8,
    prefix: u6 = 24,
    gateway: ?[4]u8,

    pub const State = BtnState;
    pub const BtnState = struct {
        node: ?*ui.Node = null,
        state: ?*PageState = null,
        actions: ?*Actions = null,
        is_hotspot: bool = false,
        current: info.manager.Addressing = .dhcp,
        adapter: info.Str(16) = .{},
        ip: ?[4]u8 = null,
        prefix: u6 = 24,
        gateway: ?[4]u8 = null,
        interaction: ui.Interaction = .{},

        fn open(st: *BtnState) void {
            const n = st.node orelse return;
            const page_st = st.state orelse return;
            if (st.is_hotspot) {
                page_st.ap_address_invalid = false;
                page_st.ap_address_id +%= 1;
                const net = page_st.hotspot_network;
                const ip = net.serverIp();
                var buf: [32]u8 = undefined;
                page_st.ap_address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ip[0], ip[1], ip[2], ip[3], net.prefix }) catch "192.168.4.1/24");
            } else {
                page_st.static_invalid = false;
                if (st.current == .dhcp) page_st.static_filled = false;
            }
            const pos = n.position();
            n.ui.openPopup(n, .{ pos[0], pos[1] + n.size.h }, .of(st, BtnState.buildPopup));
        }

        fn chooseDhcp(st: *BtnState) void {
            const page_st = st.state orelse return;
            page_st.static_form = false;
            page_st.static_filled = false;
            page_st.static_invalid = false;
            if (st.current == .static) if (st.actions) |acts| {
                acts.wifi_addressing = .dhcp;
                acts.wifi_adapter = st.adapter;
            };
        }

        fn chooseStatic(st: *BtnState) void {
            const page_st = st.state orelse return;
            page_st.static_form = true;
        }

        fn applyClient(st: *BtnState) void {
            const page_st = st.state orelse return;
            const static = info.manager.Static.parse(std.mem.trim(u8, page_st.static_address.text(), " "), page_st.static_gateway.text()) orelse {
                page_st.static_invalid = true;
                return;
            };
            page_st.static_invalid = false;
            page_st.static_form = false;
            if (st.actions) |acts| {
                acts.wifi_addressing = .{ .static = static };
                acts.wifi_adapter = st.adapter;
            }
            if (st.node) |n| n.ui.closeMenu();
        }

        fn applyAp(st: *BtnState) void {
            const page_st = st.state orelse return;
            const trimmed = std.mem.trim(u8, page_st.ap_address.text(), " ");
            if (trimmed.len == 0) {
                page_st.hotspot_network = .{};
                page_st.ap_address_invalid = false;
                if (st.node) |n| n.ui.closeMenu();
                return;
            }
            const net = info.manager.HotspotNetwork.parseHost(trimmed) orelse {
                page_st.ap_address_invalid = true;
                return;
            };
            page_st.ap_address_invalid = false;
            page_st.hotspot_network = net;
            if (st.node) |n| n.ui.closeMenu();
        }

        fn buildPopup(st: *BtnState, cx: *ui.Context) ui.Widget {
            const page_st = st.state orelse return cx.make(ui.Empty{});
            const t = cx.theme();
            const a = cx.ui.arena();
            var rows: std.ArrayList(ui.Widget) = .empty;

            if (st.is_hotspot) {
                const on_apply: ?ui.Callback = if (st.actions != null) .of(st, BtnState.applyAp) else null;
                const key = (@as(u64, page_st.ap_address_id) << 1) | 0x2000_0000;
                rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                    cx.make(ui.SizedBox{ .width = 110, .child = cx.make(ui.Text{ .text = "Address", .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                        .placeholder = "192.168.4.1/24",
                        .initial = page_st.ap_address.text(),
                        .max_len = 18,
                        .size = 16,
                        .on_changed = .of(page_st, PageState.setApAddress),
                        .on_submit = on_apply,
                    }).withKey(key) }),
                } })) catch {};
                if (page_st.ap_address_invalid) rows.append(a, cx.make(ui.Text{
                    .text = "Give a host address and prefix length (192.168.4.1/24)",
                    .style = .{ .size = 15, .color = t.@"error" },
                })) catch {};
                rows.append(a, cx.make(ui.Row{ .main_axis_alignment = .end, .children = &.{
                    cx.make(ui.OutlinedButton{ .label = "Apply", .on_press = on_apply }),
                } })) catch {};
            } else {
                const static = page_st.static_form or st.current == .static;
                rows.append(a, cx.make(ui.Center{ .height_factor = 1, .child = cx.make(PillBar{ .children = &.{
                    cx.make(PillButton{
                        .label = "DHCP",
                        .selected = !static,
                        .first = true,
                        .last = false,
                        .on_press = if (st.actions != null) .of(st, BtnState.chooseDhcp) else null,
                    }),
                    cx.make(PillButton{
                        .label = "Static",
                        .selected = static,
                        .first = false,
                        .last = true,
                        .on_press = if (st.actions != null) .of(st, BtnState.chooseStatic) else null,
                    }),
                } }) })) catch {};

                if (!static) {
                    const gw_text = if (st.gateway) |g| cx.fmt("{d}.{d}.{d}.{d} (DHCP)", .{ g[0], g[1], g[2], g[3] }) else "None";
                    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                        cx.make(ui.SizedBox{ .width = 110, .child = cx.make(ui.Text{ .text = "Gateway", .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = gw_text, .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }) }),
                    } })) catch {};
                } else {
                    if (!page_st.static_filled) {
                        page_st.static_filled = true;
                        page_st.static_id +%= 1;
                        page_st.static_invalid = false;
                        var buf: [64]u8 = undefined;
                        switch (st.current) {
                            .static => |s| {
                                const ad = s.address;
                                page_st.static_address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ad[0], ad[1], ad[2], ad[3], s.prefix }) catch "");
                                page_st.static_gateway.set(if (s.gateway) |g| std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) catch "" else "");
                            },
                            .dhcp => {
                                page_st.static_address.len = 0;
                                page_st.static_gateway.len = 0;
                                if (st.ip) |ip| {
                                    page_st.static_address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ip[0], ip[1], ip[2], ip[3], st.prefix }) catch "");
                                }
                                if (st.gateway) |g| page_st.static_gateway.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }) catch "");
                            },
                        }
                    }
                    const on_apply: ?ui.Callback = if (st.actions != null) .of(st, BtnState.applyClient) else null;
                    const key = (@as(u64, page_st.static_id) << 1) | 0x1000_0000;
                    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                        cx.make(ui.SizedBox{ .width = 110, .child = cx.make(ui.Text{ .text = "Address", .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                        cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                            .placeholder = "Address/prefix",
                            .initial = page_st.static_address.text(),
                            .max_len = 32,
                            .size = 16,
                            .on_changed = .of(page_st, PageState.setStaticAddress),
                            .on_submit = on_apply,
                        }).withKey(key) }),
                    } })) catch {};
                    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                        cx.make(ui.SizedBox{ .width = 110, .child = cx.make(ui.Text{ .text = "Gateway", .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                        cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                            .placeholder = "Gateway",
                            .initial = page_st.static_gateway.text(),
                            .max_len = 32,
                            .size = 16,
                            .on_changed = .of(page_st, PageState.setStaticGateway),
                            .on_submit = on_apply,
                        }).withKey(key | 1) }),
                    } })) catch {};
                    if (page_st.static_invalid) rows.append(a, cx.make(ui.Text{
                        .text = "Give an address and prefix length (192.168.1.50/24), and a gateway or none",
                        .style = .{ .size = 15, .color = t.@"error" },
                    })) catch {};
                    rows.append(a, cx.make(ui.Row{ .main_axis_alignment = .end, .children = &.{
                        cx.make(ui.OutlinedButton{ .label = "Apply", .on_press = on_apply }),
                    } })) catch {};
                }
            }

            return cx.make(ui.Decorated{
                .color = t.surface_container,
                .border = .{ .width = 1, .color = t.outline_variant },
                .radius = .all(8),
                .child = cx.make(ui.SizedBox{ .width = 360, .child = cx.make(ui.Padding{
                    .padding = .all(16),
                    .child = cx.make(ui.Column{ .main_axis_size = .min, .cross_axis_alignment = .stretch, .spacing = 12, .children = rows.items }),
                }) }),
            });
        }
    };

    pub fn build(self: *const AddressConfigButton, cx: *ui.Context, state: *BtnState) ui.Widget {
        state.node = cx.node;
        state.state = self.state;
        state.actions = self.actions;
        state.is_hotspot = self.is_hotspot;
        state.current = self.current;
        state.adapter = self.adapter;
        state.ip = self.ip;
        state.prefix = self.prefix;
        state.gateway = self.gateway;
        return cx.make(ui.IconButton{
            .icon = .settings,
            .size = 24,
            .icon_size = 18,
            .on_press = if (self.actions != null) .of(state, BtnState.open) else null,
        });
    }
};

pub const UpstreamOption = struct {
    name: info.Str(16) = .{},
    label: info.Str(16) = .{},
    ethernet: bool = false,
    connected: bool = true,
};

pub const UpstreamList = struct {
    items: [8]UpstreamOption = undefined,
    len: usize = 0,

    pub fn slice(l: *const UpstreamList) []const UpstreamOption {
        return l.items[0..l.len];
    }

    pub fn find(l: *const UpstreamList, name: []const u8) ?UpstreamOption {
        for (l.slice()) |opt| {
            if (std.mem.eql(u8, opt.name.slice(), name)) return opt;
        }
        return null;
    }
};

pub fn upstreamOptions(self: *const Settings, adapter_name: []const u8) UpstreamList {
    var list: UpstreamList = .{};
    const eths = self.network.slice();
    for (eths) |*eth| {
        if (list.len >= list.items.len) break;
        const lbl = if (eths.len == 1) "Ethernet" else eth.name.slice();
        list.items[list.len] = .{
            .name = eth.name,
            .label = .of(lbl),
            .ethernet = true,
            .connected = eth.carrier or eth.ip != null or std.mem.eql(u8, eth.state.slice(), "up"),
        };
        list.len += 1;
    }
    if (self.manager) |report| {
        for (report.wifiAdapters()) |*w| {
            if (std.mem.eql(u8, w.name(), adapter_name)) continue;
            if (list.len >= list.items.len) break;
            list.items[list.len] = .{
                .name = .of(w.name()),
                .label = .of(w.name()),
                .ethernet = false,
                .connected = true,
            };
            list.len += 1;
        }
    }
    return list;
}

fn ensureHotspotDefaults(
    self: *const Settings,
    state: *State,
    hs: *const info.manager.Hotspot,
    on_this_hs: bool,
    upstreams: *const UpstreamList,
) void {
    const default_upstream = if (upstreams.len > 0) upstreams.items[0].name else info.Str(16){};
    if (!state.form_filled) {
        state.form_filled = true;
        state.form_id +%= 1;
        state.hotspot_invalid = false;
        if (on_this_hs and hs.ssid_len > 0) {
            state.hotspot_ssid.set(hs.ssid());
            state.hotspot_password.set(hs.passphrase());
            state.hotspot_network = hs.network();
            state.hotspot_upstream = if (hs.upstream_len > 0) .of(hs.upstream()) else default_upstream;
        } else {
            const default_ssid = if (self.system.hostname.len > 0) self.system.hostname.slice() else "dazzle";
            state.hotspot_ssid.set(default_ssid);
            var pass_buf: [12]u8 = undefined;
            state.hotspot_password.set(randomHotspotPassword(&pass_buf));
            state.hotspot_network = .{};
            state.hotspot_upstream = default_upstream;
        }
    }
    if (upstreams.len == 0) {
        state.hotspot_upstream = .{};
    } else if (!std.mem.eql(u8, state.hotspot_upstream.slice(), "none") and upstreams.find(state.hotspot_upstream.slice()) == null) {
        state.hotspot_upstream = default_upstream;
    }
}

const hotspot_password_alphabet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";

fn randomHotspotPassword(buf: *[12]u8) []const u8 {
    var raw: [12]u8 = @splat(0);
    var at: usize = 0;
    while (at < raw.len) {
        const rc = std.os.linux.getrandom(raw[at..].ptr, raw.len - at, 0);
        if (std.os.linux.errno(rc) == .SUCCESS) at += rc else break;
    }
    for (buf, raw) |*dst, b| {
        dst.* = hotspot_password_alphabet[b % hotspot_password_alphabet.len];
    }
    return buf[0..];
}

/// The first row on the Wi-Fi page: Client or Access Point mode, with Start/Stop
/// beside it in Access Point mode.
fn modeRow(
    self: *const Settings,
    b: Builder,
    state: *State,
    adapter_name: []const u8,
    hs: *const info.manager.Hotspot,
    on_this_hs: bool,
    current_hs: bool,
    is_hotspot: bool,
    upstreams: *const UpstreamList,
) ui.Widget {
    const cx = b.cx;
    const a = cx.ui.arena();
    const mode: Mode = if (is_hotspot) .access_point else .client;
    const default_upstream = if (upstreams.len > 0) upstreams.items[0].name else info.Str(16){};
    const choice = a.create(ModeChoice) catch return cx.make(ui.Empty{});
    choice.* = .{
        .actions = self.actions,
        .state = state,
        .hs = hs,
        .on_this_hs = on_this_hs,
        .current_hs = current_hs,
        .adapter = .of(adapter_name),
        .hostname = self.system.hostname,
        .default_upstream = default_upstream,
    };
    const mode_menu = cx.make(ModeMenu{
        .options = &mode_options,
        .value = mode,
        .on_changed = if (self.actions != null) .of(choice, ModeChoice.choose) else null,
    });
    if (!is_hotspot) {
        return cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
            b.label("Mode"),
            mode_menu,
        } });
    }
    const active = current_hs and hs.state == .active;
    const can_start = state.validHotspotNameAndPassword();
    const on_start: ?ui.Callback = if (self.actions != null and can_start) .of(choice, ModeChoice.start) else null;
    const on_stop: ?ui.Callback = if (self.actions != null) .of(choice, ModeChoice.stop) else null;
    return cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        b.label("Mode"),
        mode_menu,
        cx.make(ui.OutlinedButton{
            .label = if (active) "Stop" else "Start",
            .on_press = if (active) on_stop else on_start,
        }),
    } });
}

/// The Access Point configuration rows (Name, Password, Upstream, Clients)
/// shown below MAC address when Access Point mode is chosen.
fn hotspotRows(
    self: *const Settings,
    b: Builder,
    state: *State,
    adapter_name: []const u8,
    hs: *const info.manager.Hotspot,
    current_hs: bool,
    upstreams: *const UpstreamList,
    rows: *std.ArrayList(ui.Widget),
) void {
    const cx = b.cx;
    const a = cx.ui.arena();
    const default_upstream = if (upstreams.len > 0) upstreams.items[0].name else info.Str(16){};
    const active = current_hs and hs.state == .active;
    const can_start = state.validHotspotNameAndPassword();
    const choice = a.create(ModeChoice) catch return;
    choice.* = .{
        .actions = self.actions,
        .state = state,
        .hs = hs,
        .on_this_hs = true,
        .current_hs = current_hs,
        .adapter = .of(adapter_name),
        .hostname = self.system.hostname,
        .default_upstream = default_upstream,
    };
    const on_start: ?ui.Callback = if (self.actions != null and can_start) .of(choice, ModeChoice.start) else null;

    const key = (@as(u64, state.form_id) << 2) | 0x4000_0000;
    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        b.label("Name"),
        cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
            .placeholder = "Name",
            .initial = state.hotspot_ssid.text(),
            .max_len = 32,
            .size = 18,
            .enabled = !active,
            .on_changed = .of(state, State.setHotspotSsid),
            .on_submit = if (!active) on_start else null,
        }).withKey(key) }),
    } })) catch {};
    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        b.label("Password"),
        cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
            .placeholder = "Password",
            .initial = state.hotspot_password.text(),
            .max_len = 63,
            .obscure = true,
            .size = 18,
            .enabled = !active,
            .on_changed = .of(state, State.setHotspotPassword),
            .on_submit = if (!active) on_start else null,
        }).withKey(key | 1) }),
    } })) catch {};
    const selected_opt = upstreams.find(state.hotspot_upstream.slice());
    const internet_note: ?[]const u8 = if (upstreams.len == 0)
        "No other network connection is available"
    else if (selected_opt) |opt|
        (if (opt.ethernet and !opt.connected) "Connect an Ethernet cable to share the internet" else null)
    else
        null;
    const sel = state.hotspot_upstream.slice();
    const upstream_opts = a.alloc([]const u8, 1 + upstreams.len) catch return;
    upstream_opts[0] = "None";
    var selected_upstream: usize = 0;
    for (upstreams.slice(), 0..) |opt, i| {
        upstream_opts[i + 1] = cx.fmt("{s}", .{opt.label.slice()});
        if (!std.mem.eql(u8, sel, "none") and std.mem.eql(u8, opt.name.slice(), sel)) {
            selected_upstream = i + 1;
        }
    }
    const up_pick = a.create(UpstreamPick) catch return;
    up_pick.* = .{ .wifi_state = state, .upstreams = upstreams.* };
    const internet_menu = cx.make(InternetMenu{
        .options = upstream_opts,
        .selected = selected_upstream,
        .on_selected = if (!active and self.actions != null and upstreams.len > 0) .of(up_pick, UpstreamPick.select) else null,
    });
    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
        b.label("Upstream"),
        internet_menu,
        if (internet_note) |note|
            cx.make(ui.Expanded{ .child = cx.make(ui.Text{
                .text = note,
                .style = .{ .size = 16, .color = cx.ui.theme.on_surface_variant },
            }) })
        else
            cx.make(ui.Empty{}),
    } })) catch {};
    if (state.hotspot_invalid) rows.append(a, cx.make(ui.Row{ .spacing = 12, .children = &.{
        cx.make(ui.SizedBox{ .width = 150 }),
        cx.make(ui.Expanded{ .child = cx.make(ui.Text{
            .text = "Give a name (1–32 characters) and a password of 8–63 characters",
            .style = .{ .size = 16, .color = cx.ui.theme.@"error" },
        }) }),
    } })) catch {};

    const clients = hs.clientSlice();
    if (clients.len == 0) {
        rows.append(a, b.item("Clients", "None")) catch {};
    } else {
        var client_rows: std.ArrayList(ui.Widget) = .empty;
        for (clients) |*cl| {
            const cm = cl.mac;
            const mac_str = cx.fmt("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ cm[0], cm[1], cm[2], cm[3], cm[4], cm[5] });
            const line = if (cl.name_len > 0) blk: {
                const cname = printable(cx, cl.name());
                break :blk if (cl.address) |ip|
                    cx.fmt("{s} ({d}.{d}.{d}.{d}, {s})", .{ cname, ip[0], ip[1], ip[2], ip[3], mac_str })
                else
                    cx.fmt("{s} ({s})", .{ cname, mac_str });
            } else if (cl.address) |ip|
                cx.fmt("{d}.{d}.{d}.{d} ({s})", .{ ip[0], ip[1], ip[2], ip[3], mac_str })
            else
                mac_str;
            client_rows.append(a, b.value(line)) catch {};
        }
        rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
            b.label("Clients"),
            cx.make(ui.Expanded{ .child = b.page(client_rows.items) }),
        } })) catch {};
    }
}

/// The Wi-Fi mode as a menu button: pressing it offers "Client" and
/// "Access Point" in a menu.
pub const ModeMenu = ui.Select(Mode);

const mode_options = [_]ModeMenu.Option{
    .{ .value = .client, .label = "Client" },
    .{ .value = .access_point, .label = "Access Point" },
};

/// The interface whose internet connection is shared over the access point.
pub const InternetMenu = struct {
    options: []const []const u8,
    selected: ?usize = 0,
    on_selected: ?ui.ValueCallback(usize) = null,

    pub fn build(self: *const InternetMenu, cx: *ui.Context) ui.Widget {
        return cx.make(ui.DropdownMenu{
            .options = self.options,
            .selected = self.selected,
            .on_selected = self.on_selected,
        });
    }
};

const UpstreamPick = struct {
    wifi_state: *PageState,
    upstreams: UpstreamList,

    fn select(p: *UpstreamPick, idx: usize) void {
        p.wifi_state.hotspot_upstream = if (idx == 0 or idx - 1 >= p.upstreams.len)
            .of("none")
        else
            p.upstreams.items[idx - 1].name;
    }
};

const ModeChoice = struct {
    actions: ?*Actions,
    state: *State,
    hs: *const info.manager.Hotspot,
    on_this_hs: bool = false,
    current_hs: bool,
    adapter: info.Str(16),
    hostname: info.Str(64) = .{},
    default_upstream: info.Str(16) = .{},

    fn choose(x: *ModeChoice, mode: Mode) void {
        const st = x.state;
        switch (mode) {
            .client => {
                st.hotspot_form = false;
                st.hotspot_invalid = false;
                if (x.current_hs) if (x.actions) |acts| {
                    acts.disconnect = true;
                    acts.wifi_adapter = x.adapter;
                };
            },
            .access_point => {
                st.hotspot_form = true;
                st.has_selected = false;
                if (!st.form_filled) {
                    st.form_filled = true;
                    st.form_id +%= 1;
                    st.hotspot_invalid = false;
                    if (x.on_this_hs and x.hs.ssid_len > 0) {
                        st.hotspot_ssid.set(x.hs.ssid());
                        st.hotspot_password.set(x.hs.passphrase());
                        st.hotspot_network = x.hs.network();
                        st.hotspot_upstream = if (x.hs.upstream_len > 0) .of(x.hs.upstream()) else x.default_upstream;
                    } else {
                        const default_ssid = if (x.hostname.len > 0) x.hostname.slice() else "dazzle";
                        st.hotspot_ssid.set(default_ssid);
                        var pass_buf: [12]u8 = undefined;
                        st.hotspot_password.set(randomHotspotPassword(&pass_buf));
                        st.hotspot_network = .{};
                        st.hotspot_upstream = x.default_upstream;
                    }
                }
            },
        }
    }

    fn start(x: *ModeChoice) void {
        const st = x.state;
        const ssid = std.mem.trim(u8, st.hotspot_ssid.text(), " ");
        const pass = st.hotspot_password.text();
        if (!st.validHotspotNameAndPassword()) {
            st.hotspot_invalid = true;
            return;
        }
        st.hotspot_invalid = false;
        if (x.actions) |acts| {
            var h: Actions.Join = .{
                .adapter = x.adapter,
                .ssid_len = @intCast(ssid.len),
                .pass_len = @intCast(pass.len),
                .network = st.hotspot_network,
                .upstream = if (st.hotspot_upstream.len > 0) st.hotspot_upstream else .of("none"),
            };
            @memcpy(h.ssid_buf[0..h.ssid_len], ssid);
            @memcpy(h.pass_buf[0..h.pass_len], pass);
            acts.hotspot = h;
        }
    }

    fn stop(x: *ModeChoice) void {
        x.state.hotspot_form = true;
        x.state.hotspot_invalid = false;
        if (x.actions) |acts| {
            acts.disconnect = true;
            acts.wifi_adapter = x.adapter;
        }
    }
};

/// Joining the chosen network: a password field for WPA2/WPA3, and Connect.
fn joinForm(self: *const Settings, b: Builder, state: *State, adapter_name: []const u8, n: *const info.manager.Network) ui.Widget {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const on_connect: ?ui.Callback = if (self.actions) |acts| .of(act(cx, acts, state, adapter_name, n.ssid()), Act.connect) else null;
    const field: ui.Widget = switch (n.security) {
        .open => cx.make(ui.Text{ .text = "An open network: what is sent can be seen", .style = .{ .size = 16, .color = t.on_surface_variant } }),
        .wpa2, .wpa3 => cx.make(ui.TextField{
            .initial = state.password_buf[0..state.password_len],
            .placeholder = "Password",
            .obscure = true,
            .autofocus = true,
            .size = 18,
            .on_changed = .of(state, State.setPassword),
            .on_submit = on_connect,
        }).withKey(std.hash.Fnv1a_64.hash(n.ssid())),
        else => cx.make(ui.Text{ .text = cx.fmt("{s} networks are not supported yet", .{n.security.label()}), .style = .{ .size = 16, .color = t.on_surface_variant } }),
    };
    const supported = n.security == .open or n.security == .wpa2 or n.security == .wpa3;
    return cx.make(ui.Padding{
        .padding = .symmetric(16, 8),
        .child = cx.make(ui.Row{
            .cross_axis_alignment = .center,
            .spacing = 12,
            .children = &.{
                cx.make(ui.Expanded{ .child = field }),
                cx.make(ui.OutlinedButton{ .label = "Connect", .on_press = if (supported) on_connect else null }),
            },
        }),
    });
}

/// Wi-Fi networks, a row each; rows are made only for those that show.
fn networkList(
    self: *const Settings,
    b: Builder,
    state: *State,
    adapter_name: []const u8,
    report: *const info.manager.Report,
    nets: []const info.manager.Network,
    chosen: ?*const info.manager.Network,
) ui.Widget {
    const cx = b.cx;
    const list = cx.ui.arena().create(Networks) catch return cx.make(ui.Empty{});
    const c = &report.connection;
    const on_this = c.adapter_len == 0 or std.mem.eql(u8, c.adapter(), adapter_name);
    list.* = .{
        .actions = self.actions,
        .state = state,
        .adapter_name = adapter_name,
        .conn = c,
        .on_this = on_this,
        .nets = nets,
        .chosen = chosen,
    };
    return cx.make(ui.LazyGrid{
        .count = nets.len,
        .cell = .{ .w = std.math.inf(f32), .h = network_row_height },
        .spacing = 0,
        .item = .of(list, Networks.row),
    });
}

/// How tall a network's row is (including the 1px divider below it).
const network_row_height = ui.ListItem.one_line_height + 1;

/// Networks to make rows of (in the frame's arena).
const Networks = struct {
    actions: ?*Actions,
    state: *State,
    adapter_name: []const u8,
    conn: *const info.manager.Connection,
    on_this: bool,
    nets: []const info.manager.Network,
    chosen: ?*const info.manager.Network,

    fn row(l: *const Networks, cx: *ui.Context, i: usize) ui.Widget {
        const n = &l.nets[i];
        const is_chosen = l.chosen != null and n == l.chosen.?;
        const joined = l.on_this and connectionBusy(l.conn) and std.mem.eql(u8, l.conn.ssid(), n.ssid());
        const on_disconnect: ?ui.Callback = if (joined)
            (if (l.actions) |acts| .of(act(cx, acts, l.state, l.adapter_name, ""), Act.disconnect) else null)
        else
            null;
        const item = networkRow(cx, n, is_chosen, joined, choose(cx, l.state, n.ssid(), n.passphrase()), on_disconnect);
        if (i + 1 >= l.nets.len) return cx.make(ui.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .children = &.{item},
        });
        return cx.make(ui.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .children = &.{
                item,
                cx.make(ui.Divider{ .inset = 16 }),
            },
        });
    }
};

/// A Wi-Fi network: its signal, its name, and a Disconnect button when
/// connected, inside a clickable `ListItem`.
fn networkRow(
    cx: *ui.Context,
    n: *const info.manager.Network,
    chosen: bool,
    joined: bool,
    on_press: ui.Callback,
    on_disconnect: ?ui.Callback,
) ui.Widget {
    return cx.make(ui.ListItem{
        .headline = printable(cx, n.ssid()),
        .leading = cx.make(Signal{ .bars = n.bars(), .locked = n.security != .open, .size = 20 }),
        .trailing = if (joined) cx.make(ui.OutlinedButton{ .label = "Disconnect", .on_press = on_disconnect }) else null,
        .selected = chosen or joined,
        .on_press = on_press,
    });
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

/// Formats a Wi-Fi configuration payload (`WIFI:T:WPA;S:<ssid>;P:<password>;;`)
/// for a QR code, escaping `\`, `;`, `,`, `"`, and `:`.
pub fn wifiQrText(a: std.mem.Allocator, ssid: []const u8, password: []const u8) []const u8 {
    const buf = a.alloc(u8, 256) catch return "";
    var pos: usize = 0;
    const prefix = if (password.len == 0) "WIFI:T:nopass;S:" else "WIFI:T:WPA;S:";
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    pos = appendWifiQrEscaped(buf, pos, ssid);
    if (password.len > 0) {
        const mid = ";P:";
        @memcpy(buf[pos .. pos + mid.len], mid);
        pos += mid.len;
        pos = appendWifiQrEscaped(buf, pos, password);
    }
    const suffix = ";;";
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;
    return buf[0..pos];
}

fn appendWifiQrEscaped(buf: []u8, start: usize, s: []const u8) usize {
    var pos = start;
    for (s) |c| {
        switch (c) {
            '\\', ';', ',', '"', ':' => {
                if (pos + 2 > buf.len) break;
                buf[pos] = '\\';
                buf[pos + 1] = c;
                pos += 2;
            },
            else => {
                if (pos + 1 > buf.len) break;
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    return pos;
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
    pass_buf: [63]u8 = undefined,
    pass_len: u8 = 0,

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
        st.setPassword(c.pass_buf[0..c.pass_len]);
    }
};

fn choose(cx: *ui.Context, state: *State, ssid: []const u8, passphrase: []const u8) ui.Callback {
    const c = cx.ui.arena().create(Choose) catch return .of(state, struct {
        fn none(_: *State) void {}
    }.none);
    const pass_len: u8 = @intCast(@min(passphrase.len, c.pass_buf.len));
    c.* = .{ .state = state, .ssid_buf = undefined, .ssid_len = @intCast(ssid.len), .pass_len = pass_len };
    @memcpy(c.ssid_buf[0..ssid.len], ssid);
    @memcpy(c.pass_buf[0..pass_len], passphrase[0..pass_len]);
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
        .{ &empty, "Not connected, scanning…" },
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

    // Connected: the connection row says so (with scanning while scanning), with Disconnect,
    // and the Address row shows the assigned IP address in CIDR format with (DHCP).
    var joined = wifi;
    joined.connection = .{ .state = .connected, .address = .{ 192, 168, 1, 50 }, .prefix = 24 };
    joined.connection.setSsid("Home");
    u.frame(1920, 960, 5, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &joined });
    try testing.expect(view.findText(u.root.?, "Connected to Home, scanning…") != null);
    try testing.expect(view.findText(u.root.?, "192.168.1.50/24 (DHCP)") != null);
    view.click(u, view.findText(u.root.?, "Disconnect").?);
    try testing.expect(actions.disconnect);

    // A WPA3 network shows the password field and can be joined.
    actions = .{};
    u.frame(1920, 960, 6, settings);
    view.click(u, view.findText(u.root.?, "Office").?);
    u.frame(1920, 960, 7, settings);
    try testing.expect(view.findType(u.root.?, ui.TextField) != null);
    u.root.?.state(Settings.State).wifi.setPassword("wpa3secret");
    view.click(u, view.findText(u.root.?, "Connect").?);
    try testing.expectEqualStrings("Office", actions.connect.?.ssid());
    try testing.expectEqualStrings("wpa3secret", actions.connect.?.passphrase());

    // A network whose security is not supported cannot be joined.
    actions = .{};
    u.frame(1920, 960, 8, settings);
    view.click(u, view.findText(u.root.?, "Library").?);
    u.frame(1920, 960, 9, settings);
    try testing.expect(view.findText(u.root.?, "Enterprise networks are not supported yet") != null);
    view.click(u, view.findText(u.root.?, "Connect").?);
    try testing.expect(actions.connect == null);

    // Failures say why.
    var failed = wifi;
    failed.scanning = false;
    failed.connection = .{ .state = .failed, .failure = .wrong_password };
    failed.connection.setSsid("Home");
    u.frame(1920, 960, 10, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &failed });
    try testing.expect(view.findText(u.root.?, "Could not connect to Home: wrong password") != null);

    // Selecting a network with a remembered passphrase pre-fills its password so Connect works immediately.
    var saved_wifi = wifi;
    for (saved_wifi.networks[0..saved_wifi.len]) |*n| {
        if (std.mem.eql(u8, n.ssid(), "Home")) n.setPassphrase("savedsecret");
    }
    actions = .{};
    const saved_settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &saved_wifi };
    u.frame(1920, 960, 9, saved_settings);
    view.click(u, view.findText(u.root.?, "Home").?);
    u.frame(1920, 960, 10, saved_settings);
    view.click(u, view.findText(u.root.?, "Connect").?);
    try testing.expectEqualStrings("Home", actions.connect.?.ssid());
    try testing.expectEqualStrings("savedsecret", actions.connect.?.passphrase());
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

test "switching to Access Point mode, applying configuration, and returning to Client" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var d = view.sample();
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
    try testing.expect(view.findText(u.root.?, "Mode") != null);
    try testing.expect(view.findText(u.root.?, "Client") != null);
    try testing.expect(view.findText(u.root.?, "Address") != null);
    try testing.expect(view.findText(u.root.?, "Not assigned") != null);
    try testing.expect(view.findText(u.root.?, "Network") != null);
    try testing.expect(view.findText(u.root.?, "Home") != null);
    // Mode is the first row on the Wi-Fi page (above Status, Address, and MAC address).
    const mode_y = view.findText(u.root.?, "Mode").?.position()[1];
    const status_y = view.findText(u.root.?, "Status").?.position()[1];
    const addr_y = view.findText(u.root.?, "Address").?.position()[1];
    const mac_y = view.findText(u.root.?, "MAC address").?.position()[1];
    try testing.expect(mode_y < status_y);
    try testing.expect(status_y < addr_y);
    try testing.expect(addr_y < mac_y);

    const status_x = view.findText(u.root.?, "Not connected, scanning…").?.position()[0];
    const addr_x = view.findText(u.root.?, "Not assigned").?.position()[0];
    const mac_x = view.findText(u.root.?, "b8:27:eb:01:02:03").?.position()[0];
    const net_x = view.findType(u.root.?, ui.Card).?.position()[0];
    try testing.expectEqual(status_x, addr_x);
    try testing.expectEqual(status_x, mac_x);
    try testing.expectEqual(status_x, net_x);

    // Clicking the configure icon beside Address in Client mode opens the DHCP/Static pill popup.
    view.click(u, view.findType(u.root.?, AddressConfigButton).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(u.menu_root != null);
    try testing.expect(view.findType(u.menu_root.?, PillBar) != null);
    try testing.expect(view.findText(u.menu_root.?, "DHCP") != null);
    try testing.expect(view.findText(u.menu_root.?, "Static") != null);
    try testing.expect(view.findText(u.menu_root.?, "Gateway") != null);
    try testing.expect(view.findText(u.menu_root.?, "192.168.1.1 (DHCP)") != null);
    view.click(u, view.findText(u.menu_root.?, "Static").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    u.root.?.state(Settings.State).wifi.static_address.set("192.168.1.99/24");
    view.click(u, view.findText(u.menu_root.?, "Apply").?);
    try testing.expectEqual(info.manager.Static.parse("192.168.1.99/24", "192.168.1.1").?, actions.wifi_addressing.?.static);
    actions = .{};

    // Selecting Access Point from the Mode menu hides the network list and shows
    // the Access Point form (without a separate Network row) with the board's
    // hostname ("awesome-elephant"), CIDR Address ("192.168.4.1/24"), and a Start
    // button to the right of the Mode button.
    view.click(u, view.findType(u.root.?, ModeMenu).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    view.click(u, view.findText(u.menu_root.?, "Access Point").?);
    try testing.expect(actions.hotspot == null);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "Home") == null);
    try testing.expect(view.findText(u.root.?, "Network") == null);
    try testing.expect(view.findText(u.root.?, "Inactive") != null);
    try testing.expect(view.findText(u.root.?, "192.168.4.1/24") != null);
    try testing.expect(view.findText(u.root.?, "Start") != null);
    try testing.expect(view.findText(u.root.?, "Name") != null);
    try testing.expect(view.findText(u.root.?, "Password") != null);
    try testing.expect(view.findText(u.root.?, "Upstream") != null);
    // With a single Ethernet adapter in sample(), Upstream shows "Ethernet".
    try testing.expect(view.findText(view.findType(u.root.?, InternetMenu).?, "Ethernet") != null);
    try testing.expect(view.findText(u.root.?, "eth0") == null);
    try testing.expect(view.findText(u.root.?, "Clients") != null);
    try testing.expect(view.findText(u.root.?, "None") != null);
    const field = view.findType(u.root.?, ui.TextField).?;
    try testing.expect(field.widget.as(ui.TextField).?.enabled);
    try testing.expectEqualStrings("awesome-elephant", field.state(ui.TextField.State).text());
    try testing.expectEqual(@as(usize, 12), u.root.?.state(Settings.State).wifi.hotspot_password.text().len);
    try testing.expect(view.up(view.findText(u.root.?, "Start").?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press != null);
    for (view.test_sizes) |size| {
        Draw(u, d, &report, &actions, &frame_no, size);
        try testing.expect(!view.overflows(u.root.?));
    }
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });

    // With two Ethernet interfaces (eth0 and eth1), Upstream shows eth0 and offers None, eth0, eth1.
    d.net.len = 2;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(view.findType(u.root.?, InternetMenu).?, "eth0") != null);
    view.click(u, view.findType(u.root.?, InternetMenu).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.menu_root.?, "None") != null);
    try testing.expect(view.findText(u.menu_root.?, "eth0") != null);
    view.click(u, view.findText(u.menu_root.?, "eth1").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "Connect an Ethernet cable to share the internet") != null);

    // Returning to a single Ethernet adapter shows "Ethernet".
    d.net.len = 1;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(view.findType(u.root.?, InternetMenu).?, "Ethernet") != null);
    try testing.expect(view.findType(view.findType(u.root.?, InternetMenu).?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press != null);

    // Without any other network connection, the Upstream menu is disabled with the reason.
    d.net.len = 0;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "No other network connection is available") != null);
    try testing.expect(view.findType(view.findType(u.root.?, InternetMenu).?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);
    d.net.len = 1;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });

    // Without a password (or with a password under 8 characters, or an empty
    // name), Start is inactive (on_press == null).
    var st = &u.root.?.state(Settings.State).wifi;
    st.hotspot_password.set("");
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.up(view.findText(u.root.?, "Start").?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);
    view.click(u, view.findText(u.root.?, "Start").?);
    try testing.expect(actions.hotspot == null);

    st = &u.root.?.state(Settings.State).wifi;
    st.hotspot_password.set("short");
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.up(view.findText(u.root.?, "Start").?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);

    st = &u.root.?.state(Settings.State).wifi;
    st.hotspot_ssid.set("");
    st.hotspot_password.set("secretpass");
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.up(view.findText(u.root.?, "Start").?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);

    // Configuring the Access Point CIDR address via the Address popup while stopped:
    // an invalid CIDR is rejected, and a valid host CIDR updates the Address row.
    st = &u.root.?.state(Settings.State).wifi;
    st.hotspot_ssid.set("DazzleBox");
    st.hotspot_password.set("secretpass");
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    view.click(u, view.findType(u.root.?, AddressConfigButton).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expectEqualStrings("192.168.4.1/24", view.findType(u.menu_root.?, ui.TextField).?.state(ui.TextField.State).text());
    u.root.?.state(Settings.State).wifi.ap_address.set("10.42.0.0/24");
    view.click(u, view.findText(u.menu_root.?, "Apply").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(u.menu_root != null);
    try testing.expect(view.findText(u.menu_root.?, "Give a host address and prefix length (192.168.4.1/24)") != null);
    u.root.?.state(Settings.State).wifi.ap_address.set("10.42.0.254/24");
    view.click(u, view.findText(u.menu_root.?, "Apply").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(u.menu_root == null);
    try testing.expect(view.findText(u.root.?, "10.42.0.254/24") != null);

    // Pressing Start sends the hotspot action with the configured network and host IP.
    view.click(u, view.findText(u.root.?, "Start").?);
    try testing.expectEqualStrings("DazzleBox", actions.hotspot.?.ssid());
    try testing.expectEqualStrings("secretpass", actions.hotspot.?.passphrase());
    try testing.expectEqual([4]u8{ 10, 42, 0, 0 }, actions.hotspot.?.network.address);
    try testing.expectEqual(@as(u6, 24), actions.hotspot.?.network.prefix);
    try testing.expectEqual([4]u8{ 10, 42, 0, 254 }, actions.hotspot.?.network.serverIp());
    try testing.expectEqualStrings("eth0", actions.hotspot.?.upstream.slice());
    actions = .{};

    // Active access point shows Active status, the assigned CIDR address, a Stop button,
    // disabled AddressConfigButton and config fields, connected clients, and the QR code
    // in the top right.
    try testing.expect(view.findType(u.root.?, ui.QrCode) == null);
    report.hotspot = .{ .state = .active, .address = .{ 10, 42, 0, 254 }, .prefix = 24 };
    report.hotspot.setSsid("DazzleBox");
    report.hotspot.setPassphrase("secretpass");
    report.hotspot.setUpstream("eth0");
    var cl: info.manager.HotspotClient = .{ .mac = .{ 0xa4, 0x5e, 0x60, 0x12, 0x34, 0x56 }, .address = .{ 10, 42, 0, 10 } };
    cl.setName("laptop");
    report.hotspot.addClient(cl);
    for (view.test_sizes) |size| {
        Draw(u, d, &report, &actions, &frame_no, size);
        try testing.expect(!view.overflows(u.root.?));
    }
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "Active") != null);
    try testing.expect(view.findText(u.root.?, "10.42.0.254/24") != null);
    try testing.expect(view.findText(u.root.?, "Stop") != null);
    try testing.expect(view.findText(u.root.?, "Start") == null);
    try testing.expect(!view.findType(u.root.?, ui.TextField).?.widget.as(ui.TextField).?.enabled);
    try testing.expect(view.findType(view.findType(u.root.?, InternetMenu).?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);
    try testing.expect(view.findText(u.root.?, "laptop (10.42.0.10, a4:5e:60:12:34:56)") != null);
    const qr_node = view.findType(u.root.?, ui.QrCode).?;
    try testing.expectEqualStrings("WIFI:T:WPA;S:DazzleBox;P:secretpass;;", qr_node.widget.as(ui.QrCode).?.text);
    try testing.expect(qr_node.position()[0] > view.findText(u.root.?, "Active").?.position()[0]);
    try testing.expect(qr_node.position()[1] <= view.findText(u.root.?, "Status").?.position()[1]);
    // Clicking AddressConfigButton while active does not open the popup.
    view.click(u, view.findType(u.root.?, AddressConfigButton).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(u.menu_root == null);

    // Pressing Stop stops the access point, hides the QR code, and makes the Address popup and config fields active again.
    view.click(u, view.findText(u.root.?, "Stop").?);
    try testing.expect(actions.disconnect);
    actions = .{};
    report.hotspot = .{};
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findType(u.root.?, ui.QrCode) == null);
    try testing.expect(view.findText(u.root.?, "Inactive") != null);
    try testing.expect(view.findText(u.root.?, "10.42.0.254/24") != null);
    try testing.expect(view.findText(u.root.?, "Start") != null);
    try testing.expect(view.findType(u.root.?, ui.TextField).?.widget.as(ui.TextField).?.enabled);

    // Switching back to Client restores the network list.
    view.click(u, view.findType(u.root.?, ModeMenu).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    view.click(u, view.findText(u.menu_root.?, "Client").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(view.findText(u.root.?, "Home") != null);
}
