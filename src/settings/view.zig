//! The settings app's window, as widgets: pages, chosen with the tabs on
//! the left, about the Wi-Fi networks around, Ethernet, the resources in
//! use (with meters) and the system (its build, Linux and the board).
//! Choosing a Wi-Fi network shows a password field (for WPA2) and a
//! Connect button; choosing a static address for Ethernet shows fields for
//! it. The Apps page lists the apps that can be installed (from the
//! catalogue; see store.zig), with Install or Remove beside each. What is
//! asked of the network manager, and of the store, goes to the main loop
//! through `Actions`.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const info = @import("info.zig");
const store = @import("store.zig");

/// The storage bar's colours (the system's is the theme's primary).
pub const apps_color = gfx.Color.argb(0xff4fd8c4);
pub const user_color = gfx.Color.argb(0xffffb68a);

/// What the window asks of the network manager; the main loop sends it,
/// then clears it.
pub const Actions = struct {
    connect: ?Join = null,
    disconnect: bool = false,
    /// How the wired adapter gets its address.
    ethernet: ?info.manager.Addressing = null,
    /// The app to install, or remove; whether to get the list of apps again.
    install: ?AppName = null,
    remove: ?AppName = null,
    refresh_apps: bool = false,

    pub const AppName = struct {
        buf: [48]u8 = undefined,
        len: u8 = 0,

        pub fn init(name: []const u8) AppName {
            var n: AppName = .{ .len = @intCast(@min(name.len, 48)) };
            @memcpy(n.buf[0..n.len], name[0..n.len]);
            return n;
        }

        pub fn slice(n: *const AppName) []const u8 {
            return n.buf[0..n.len];
        }
    };

    pub const Join = struct {
        ssid_buf: [32]u8 = undefined,
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

/// The smallest the window may be: the tabs, and the widest card's rows
/// beside them. Everything is the same size in pixels whatever the
/// window's size; the cards grow to fill the width (up to
/// `max_page_width`), and their pages scroll.
pub const min_size = [2]u32{ 720, 440 };

/// The widest a page is.
const max_page_width = 960;

/// What the Apps page shows.
pub const Apps = struct {
    /// The catalogue's apps, and whether each is installed.
    list: []const store.App = &.{},
    installed: []const bool = &.{},
    /// The app being installed ("" for the list itself); null if nothing
    /// is under way.
    busy: ?[]const u8 = null,
    /// What happened last.
    message: []const u8 = "",
    /// Whether apps can be installed yet (not before setup).
    writable: bool = true,
    /// Where they come from.
    source: []const u8 = "",
};

pub const Settings = struct {
    commit: []const u8,
    /// Where the window's requests go (none in tests that do not look).
    actions: ?*Actions = null,
    system: *const info.System,
    usage: info.Usage,
    network: *const info.Network,
    /// What the network manager last said; null if it could not be asked.
    manager: ?*const info.manager.Report = null,
    /// The apps that can be installed, and how installing goes.
    apps: Apps = .{},
    /// The title bar's buttons (close, and maximize, which shows whether
    /// the window is), and pressing the bar (to move the window).
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub const State = struct {
        /// The page shown.
        page: Page = .wifi,
        /// The Wi-Fi network chosen (its SSID), and the password typed.
        selected_buf: [32]u8 = undefined,
        selected_len: u8 = 0,
        has_selected: bool = false,
        password_buf: [63]u8 = undefined,
        password_len: u8 = 0,
        /// Ethernet: the form for a static address is open (chosen, before
        /// it is applied), what is typed in it, and whether that was not an
        /// address.
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

        fn setAddress(st: *State, t: []const u8) void {
            st.address.set(t);
        }

        fn setGateway(st: *State, t: []const u8) void {
            st.gateway.set(t);
        }

        pub fn selected(st: *const State) ?[]const u8 {
            return if (st.has_selected) st.selected_buf[0..st.selected_len] else null;
        }

        fn setPassword(st: *State, text: []const u8) void {
            st.password_len = @intCast(@min(text.len, st.password_buf.len));
            @memcpy(st.password_buf[0..st.password_len], text[0..st.password_len]);
        }
    };

    pub fn build(self: *const Settings, cx: *ui.Context, state: *State) ui.Widget {
        const b: Builder = .{ .cx = cx };
        const page = switch (state.page) {
            .wifi => self.wifiCard(b, state),
            .ethernet => self.networkCard(b, state),
            .resources => self.resourcesCard(b),
            .system => self.systemCard(b),
            .apps => self.appsCard(b, state),
        };
        const t = cx.theme();
        var tabs: [std.meta.fields(Page).len]ui.Widget = undefined;
        inline for (&tabs, std.meta.fields(Page)) |*w, field| {
            const p: Page = @enumFromInt(field.value);
            w.* = cx.make(Tab{ .label = p.label(), .icon = p.icon(), .selected = state.page == p, .on_press = pick(cx, state, p) });
        }
        const sidebar = cx.make(ui.SizedBox{ .width = 190, .child = cx.make(ui.Decorated{
            .color = t.surface_container,
            .child = cx.make(ui.Padding{ .padding = .all(12), .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .spacing = 4,
                .children = &tabs,
            }) }),
        }) });
        // A page longer than the window scrolls; another page starts at
        // its top. In a wide window the page is no wider than reads well,
        // in the middle.
        const content = cx.make(ui.Row{ .cross_axis_alignment = .stretch, .children = &.{
            sidebar,
            cx.make(ui.Expanded{ .child = cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Align{
                .alignment = .top_center,
                .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = max_page_width }, .child = page }),
            }) }) }).withKey(@as(u64, @intFromEnum(state.page)) + 1) }),
        } });
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = "Settings",
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
            }),
            cx.make(ui.Expanded{ .child = content }),
        } });
    }

    fn appsCard(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const apps = &self.apps;
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        const busy = apps.busy != null;
        // The list's state, and getting it again.
        const status = if (apps.busy) |name| (if (name.len == 0) "Getting the list of apps…" else "Installing…") else if (apps.list.len == 0 and !apps.writable) "Apps can be installed once setup has finished" else if (apps.list.len == 0) "No list of apps yet: is the network up?" else cx.fmt("{d} apps", .{apps.list.len});
        rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
            b.label("Catalogue"),
            cx.make(ui.Expanded{ .child = b.value(status) }),
            cx.make(ui.OutlinedButton{ .label = "Refresh", .icon = .refresh, .on_press = if (self.actions != null and !busy) .of(appAct(cx, self.actions.?, state, ""), AppAct.refresh) else null }),
        } })) catch {};
        if (apps.message.len > 0) rows.append(a, b.item("", apps.message)) catch {};
        if (!apps.writable and apps.list.len > 0) rows.append(a, b.item("", "Apps can be installed once setup has finished")) catch {};
        for (apps.list, 0..) |app, i| {
            const installed = i < apps.installed.len and apps.installed[i];
            const this_busy = if (apps.busy) |n| std.mem.eql(u8, n, app.name) else false;
            const enabled = self.actions != null and !busy and (installed or apps.writable);
            const x = if (self.actions) |acts| appAct(cx, acts, state, app.name) else null;
            const button: ui.Widget = if (this_busy)
                cx.make(ui.Spinner{ .size = 28 })
            else if (installed)
                cx.make(ui.OutlinedButton{ .label = "Remove", .icon = .delete, .on_press = if (enabled) .of(x.?, AppAct.remove) else null })
            else
                cx.make(ui.OutlinedButton{ .label = "Install", .icon = .download, .on_press = if (enabled) .of(x.?, AppAct.install) else null });
            var size_buf: [32]u8 = undefined;
            const detail = if (app.description.len > 0)
                cx.fmt("{s} · {s}", .{ app.description, info.formatBytes(&size_buf, app.size) })
            else
                cx.fmt("{s}", .{info.formatBytes(&size_buf, app.size)});
            rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = &.{
                cx.make(ui.Icon{ .icon = ui.icons.fromName(app.icon) orelse .apps, .size = 32, .color = t.on_surface_variant }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                    cx.make(ui.Text{ .text = app.title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
                    cx.make(ui.Text{ .text = detail, .style = .{ .size = 15, .color = t.on_surface_variant } }),
                } }) }),
                button,
            } })) catch {};
        }
        if (apps.source.len > 0) rows.append(a, cx.make(ui.Text{ .text = cx.fmt("From {s}", .{apps.source}), .style = .{ .size = 14, .color = t.on_surface_variant } })) catch {};
        return b.card("Apps", rows.items);
    }

    fn systemCard(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const sys = self.system;
        var dur: [32]u8 = undefined;
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        rows.appendSlice(a, &.{
            b.item("Build", self.commit),
            b.item("Linux", orUnknown(sys.kernel.slice())),
            b.item("Up for", cx.fmt("{s}", .{info.formatDuration(&dur, self.usage.uptime_s)})),
            b.item("Board", orUnknown(sys.model.slice())),
            b.item("Hostname", orUnknown(sys.hostname.slice())),
        }) catch {};
        if (sys.serial.len > 0) rows.append(a, b.item("Serial", sys.serial.slice())) catch {};
        return b.card("System", rows.items);
    }

    fn resourcesCard(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const u = self.usage;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        const cores = self.system.cores;
        const cpu = if (u.cpu_busy) |busy| cx.fmt("{d:.0}% busy ({d} {s})", .{ busy, cores, if (cores == 1) "core" else "cores" }) else "Measuring…";
        const temperature = if (u.temperature) |c| cx.fmt("{d:.1} °C", .{c}) else "Unknown";
        const mem = cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) });
        const gpu = if (u.gpu_total > 0) cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.gpuUsed()), info.formatBytes(&b2, u.gpu_total) }) else "Unknown";
        return b.card("Resources", &.{
            b.meter("CPU", cpu, (u.cpu_busy orelse 0) / 100),
            b.item("Temperature", temperature),
            b.meter("Memory", mem, fraction(u.memUsed(), u.mem_total)),
            b.meter("GPU memory", gpu, fraction(u.gpuUsed(), u.gpu_total)),
            b.storage(u.storage),
        });
    }

    fn wifiCard(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const report = self.manager orelse return b.card("Wi-Fi", &.{b.item("Status", "The network manager is not running")});
        if (report.denied) return b.card("Wi-Fi", &.{b.item("Status", "Not allowed to scan")});
        const adapter = report.adapter orelse return b.card("Wi-Fi", &.{b.item("Status", "No Wi-Fi adapter")});
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        const m = adapter.mac;
        rows.append(a, b.item("Adapter", cx.fmt("{s} ({x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}){s}", .{ adapter.name(), m[0], m[1], m[2], m[3], m[4], m[5], if (adapter.up) "" else ", down" }))) catch {};
        rows.append(a, self.connectionRow(b, state, &report.connection)) catch {};

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
        if (split > 0) rows.append(a, networkList(b, state, report, nets[0..split], chosen)) catch {};
        if (form) rows.append(a, self.joinForm(b, state, chosen.?)) catch {};
        if (split < nets.len) rows.append(a, networkList(b, state, report, nets[split..], chosen)) catch {};
        const footer = if (report.scanning) "Scanning…" else if (nets.len == 0) "No networks found" else "";
        if (footer.len > 0) rows.append(a, b.item("", footer)) catch {};
        return b.card("Wi-Fi", rows.items);
    }

    /// The connection's state, with Disconnect while there is one.
    fn connectionRow(self: *const Settings, b: Builder, state: *State, c: *const info.manager.Connection) ui.Widget {
        const cx = b.cx;
        const name = printable(cx, c.ssid());
        const text = switch (c.state) {
            .idle => "Not connected",
            .connected => if (c.address) |ip| cx.fmt("Connected to {s} ({d}.{d}.{d}.{d})", .{ name, ip[0], ip[1], ip[2], ip[3] }) else cx.fmt("Connected to {s}", .{name}),
            .connecting, .authenticating, .addressing => cx.fmt("{s}: {s}…", .{ name, c.state.label() }),
            .failed => cx.fmt("Could not connect to {s}: {s}", .{ name, c.failure.label() }),
        };
        if (!connectionBusy(c)) return b.item("Connection", text);
        return cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
            b.label("Connection"),
            cx.make(ui.Expanded{ .child = b.value(text) }),
            cx.make(ui.OutlinedButton{ .label = "Disconnect", .on_press = if (self.actions) |acts| .of(act(cx, acts, state, ""), Act.disconnect) else null }),
        } });
    }

    /// Joining the chosen network: a password field for WPA2, and Connect.
    fn joinForm(self: *const Settings, b: Builder, state: *State, n: *const info.manager.Network) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const on_connect: ?ui.Callback = if (self.actions) |acts| .of(act(cx, acts, state, n.ssid()), Act.connect) else null;
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

    fn networkCard(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const net = self.network;
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        if (net.len == 0) {
            rows.append(a, b.item("Status", "No adapter: plug in a USB Ethernet adapter")) catch {};
        }
        for (net.slice()) |*i| {
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            const status = if (!std.mem.eql(u8, i.state.slice(), "up") and !i.carrier)
                (if (std.mem.eql(u8, i.state.slice(), "down")) "Not connected: no cable" else cx.fmt("Not connected ({s})", .{i.state.slice()}))
            else if (i.speed) |mbps|
                cx.fmt("Connected at {d} Mb/s", .{mbps})
            else
                "Connected";
            rows.append(a, b.item(i.name.slice(), status)) catch {};
            const method = if (self.addressing() == .static) "static" else "DHCP";
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
        }
        if (net.gateway) |g| rows.append(a, b.item("Gateway", cx.fmt("{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] }))) catch {};
        // How the adapter gets its address, if there is one and the
        // network manager can be asked.
        if (net.len > 0 and self.manager != null) self.addressingRows(b, state, &rows);
        return b.card("Ethernet", rows.items);
    }

    /// How the wired adapter gets its address, as the network manager says.
    fn addressing(self: *const Settings) info.manager.Addressing {
        return if (self.manager) |m| m.ethernet.addressing else .dhcp;
    }

    /// DHCP or a static address, and the form for a static address while
    /// that is chosen.
    fn addressingRows(self: *const Settings, b: Builder, state: *State, rows: *std.ArrayList(ui.Widget)) void {
        const cx = b.cx;
        const a = cx.ui.arena();
        const current = self.addressing();
        const static = state.static_form or current == .static;
        const choice = cx.ui.arena().create(Addressing) catch return;
        choice.* = .{ .actions = self.actions, .state = state, .current = current };
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
                    for (self.network.slice()) |*i| if (i.ip) |ip| {
                        state.address.set(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ ip[0], ip[1], ip[2], ip[3], i.prefix }) catch "");
                        break;
                    };
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
};

const Mode = enum { dhcp, static };

/// Choosing DHCP or a static address, and applying one.
const Addressing = struct {
    actions: ?*Actions,
    state: *Settings.State,
    current: info.manager.Addressing,

    fn choose(x: *Addressing, mode: Mode) void {
        const st = x.state;
        switch (mode) {
            .dhcp => {
                st.static_form = false;
                st.form_filled = false;
                if (x.current == .static) if (x.actions) |acts| {
                    acts.ethernet = .dhcp;
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
        if (x.actions) |acts| acts.ethernet = .{ .static = static };
    }
};

/// Wi-Fi networks, a row each; rows are made only for those that show.
fn networkList(b: Builder, state: *Settings.State, report: *const info.manager.Report, nets: []const info.manager.Network, chosen: ?*const info.manager.Network) ui.Widget {
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
    state: *Settings.State,
    conn: *const info.manager.Connection,
    nets: []const info.manager.Network,
    chosen: ?*const info.manager.Network,

    fn row(l: *const Networks, cx: *ui.Context, i: usize) ui.Widget {
        const b: Builder = .{ .cx = cx };
        const n = &l.nets[i];
        const is_chosen = l.chosen != null and n == l.chosen.?;
        const joined = l.conn.state != .idle and l.conn.state != .failed and std.mem.eql(u8, l.conn.ssid(), n.ssid());
        return b.network(n, is_chosen, joined, choose(cx, l.state, n.ssid()));
    }
};

/// Whether a connection is being made or kept (and can be ended).
fn connectionBusy(c: *const info.manager.Connection) bool {
    return c.state != .idle and !(c.state == .failed and c.failure != .lost);
}

/// The pages, in the order of their tabs.
pub const Page = enum {
    wifi,
    ethernet,
    resources,
    apps,
    system,

    pub fn label(p: Page) []const u8 {
        return switch (p) {
            .wifi => "Wi-Fi",
            .ethernet => "Ethernet",
            .resources => "Resources",
            .apps => "Apps",
            .system => "System",
        };
    }

    pub fn icon(p: Page) ui.icons.Icon {
        return switch (p) {
            .wifi => .wifi,
            .ethernet => .lan,
            .resources => .speed,
            .apps => .apps,
            .system => .info,
        };
    }
};

/// The page `u` (running a `Settings`) shows.
pub fn shownPage(u: *ui.Ui) Page {
    const root = u.root orelse return .wifi;
    if (!root.widget.is(Settings)) return .wifi;
    return root.state(Settings.State).page;
}

/// A tab: pressing it shows its page.
const Tab = struct {
    label: []const u8,
    icon: ui.icons.Icon,
    selected: bool,
    on_press: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub fn build(self: *const Tab, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const height = 48;
        const color = if (self.selected) t.on_surface else t.on_surface_variant;
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        return cx.make(ui.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = highlight,
            .radius = .all(height / 2),
            .child = cx.make(ui.SizedBox{ .height = height, .child = cx.make(ui.Padding{ .padding = .symmetric(16, 0), .child = cx.make(ui.Row{
                .cross_axis_alignment = .center,
                .spacing = 12,
                .children = &.{
                    cx.make(ui.Icon{ .icon = self.icon, .size = 22, .color = color }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Text{
                        .text = self.label,
                        .style = .{ .size = 18, .color = color },
                        .wrap = false,
                        .ellipsis = true,
                    }) }),
                },
            }) }) }),
        }) });
    }
};

/// Pressing a tab shows its page.
const Pick = struct {
    state: *Settings.State,
    page: Page,

    fn press(p: *Pick) void {
        p.state.page = p.page;
    }
};

fn pick(cx: *ui.Context, state: *Settings.State, page: Page) ?ui.Callback {
    const p = cx.ui.arena().create(Pick) catch return null;
    p.* = .{ .state = state, .page = page };
    return .of(p, Pick.press);
}

/// Pressing a network chooses it (or, again, unchooses it).
const Choose = struct {
    state: *Settings.State,
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

fn choose(cx: *ui.Context, state: *Settings.State, ssid: []const u8) ui.Callback {
    const c = cx.ui.arena().create(Choose) catch return .of(state, struct {
        fn none(_: *Settings.State) void {}
    }.none);
    c.* = .{ .state = state, .ssid_buf = undefined, .ssid_len = @intCast(ssid.len) };
    @memcpy(c.ssid_buf[0..ssid.len], ssid);
    return .of(c, Choose.press);
}

/// Connect and Disconnect: requests for the main loop.
const Act = struct {
    actions: *Actions,
    state: *Settings.State,
    ssid_buf: [32]u8,
    ssid_len: u8,

    fn connect(x: *Act) void {
        var j: Actions.Join = .{ .ssid_len = x.ssid_len, .pass_len = x.state.password_len };
        @memcpy(j.ssid_buf[0..x.ssid_len], x.ssid_buf[0..x.ssid_len]);
        @memcpy(j.pass_buf[0..j.pass_len], x.state.password_buf[0..j.pass_len]);
        x.actions.connect = j;
        // The form closes; the connection row says how it goes.
        x.state.has_selected = false;
    }

    fn disconnect(x: *Act) void {
        x.actions.disconnect = true;
    }
};

/// Install, Remove and Refresh on the Apps page: requests for the main
/// loop.
const AppAct = struct {
    actions: *Actions,
    name: Actions.AppName,

    fn install(x: *AppAct) void {
        x.actions.install = x.name;
    }

    fn remove(x: *AppAct) void {
        x.actions.remove = x.name;
    }

    fn refresh(x: *AppAct) void {
        x.actions.refresh_apps = true;
    }
};

fn appAct(cx: *ui.Context, actions: *Actions, _: *Settings.State, name: []const u8) *AppAct {
    const x = cx.ui.arena().create(AppAct) catch unreachable;
    x.* = .{ .actions = actions, .name = .init(name) };
    return x;
}

fn act(cx: *ui.Context, actions: *Actions, state: *Settings.State, ssid: []const u8) *Act {
    const x = cx.ui.arena().create(Act) catch unreachable;
    x.* = .{ .actions = actions, .state = state, .ssid_buf = undefined, .ssid_len = @intCast(ssid.len) };
    @memcpy(x.ssid_buf[0..ssid.len], ssid);
    return x;
}

/// An SSID as text: bytes that are not UTF-8 (SSIDs need not be) become
/// "?".
fn printable(cx: *ui.Context, ssid: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(ssid)) return ssid;
    const out = cx.ui.arena().dupe(u8, ssid) catch return "?";
    for (out) |*c| if (c.* >= 0x80 or c.* < 0x20) {
        c.* = '?';
    };
    return out;
}

fn orUnknown(s: []const u8) []const u8 {
    return if (s.len == 0) "Unknown" else s;
}

fn fraction(part: u64, whole: u64) f32 {
    if (whole == 0) return 0;
    return @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(whole));
}

/// Makes the cards and their rows.
const Builder = struct {
    cx: *ui.Context,

    fn card(b: Builder, title: []const u8, rows: []const ui.Widget) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const children = cx.ui.arena().alloc(ui.Widget, rows.len + 1) catch return cx.make(ui.Empty{});
        children[0] = cx.make(ui.Padding{ .padding = .{ .bottom = 4 }, .child = cx.make(ui.Text{ .text = title, .style = .{ .size = 24, .color = t.primary }, .wrap = false }) });
        @memcpy(children[1..], rows);
        return cx.make(ui.Decorated{ .color = t.surface_container, .radius = .all(16), .child = cx.make(ui.Padding{
            .padding = .all(20),
            .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 10, .children = children }),
        }) });
    }

    fn label(b: Builder, text: []const u8) ui.Widget {
        const cx = b.cx;
        return cx.make(ui.SizedBox{ .width = 150, .child = cx.make(ui.Text{ .text = text, .style = .{ .size = 18, .color = cx.ui.theme.on_surface_variant }, .wrap = false }) });
    }

    fn value(b: Builder, text: []const u8) ui.Widget {
        return b.cx.make(ui.Text{ .text = text, .style = .{ .size = 18, .color = b.cx.ui.theme.on_surface } });
    }

    /// A label and its value.
    fn item(b: Builder, name: []const u8, text: []const u8) ui.Widget {
        return b.cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
            b.label(name),
            b.cx.make(ui.Expanded{ .child = b.value(text) }),
        } });
    }

    /// Storage: what the system, the apps and the user take, and what is
    /// free, in a bar of coloured segments with a key above.
    fn storage(b: Builder, st: info.Storage) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const total = st.total();
        const parts = [_]struct { name: []const u8, bytes: u64, color: gfx.Color }{
            .{ .name = "System", .bytes = st.system, .color = t.primary },
            .{ .name = "Apps", .bytes = st.apps, .color = apps_color },
            .{ .name = "User", .bytes = st.user, .color = user_color },
            // The bar's track.
            .{ .name = "Free", .bytes = st.free, .color = t.surface_container_highest },
        };
        const a = cx.ui.arena();
        const segments = a.alloc(SegmentBar.Segment, parts.len - 1) catch return cx.make(ui.Empty{});
        const key = a.alloc(ui.Widget, parts.len) catch return cx.make(ui.Empty{});
        const dot = 10;
        for (parts, key, 0..) |part, *k, i| {
            var buf: [32]u8 = undefined;
            if (i < segments.len) segments[i] = .{ .fraction = fraction(part.bytes, total), .color = part.color };
            k.* = cx.make(ui.Row{ .spacing = 6, .cross_axis_alignment = .center, .children = &.{
                cx.make(ui.SizedBox{ .width = dot, .height = dot, .child = cx.make(ui.Decorated{ .color = part.color, .radius = .all(dot / 2) }) }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = cx.fmt("{s} {s}", .{ part.name, info.formatBytes(&buf, part.bytes) }), .style = .{ .size = 16, .color = t.on_surface }, .wrap = false, .ellipsis = true }) }),
            } });
        }
        return cx.make(ui.Row{
            .cross_axis_alignment = .start,
            .spacing = 12,
            .children = &.{
                b.label("Storage"),
                cx.make(ui.Expanded{
                    .child = cx.make(ui.Column{
                        .cross_axis_alignment = .stretch,
                        .main_axis_size = .min,
                        .spacing = 6,
                        .children = &.{
                            // On as many lines as it takes.
                            cx.make(ui.Grid{ .cell = .{ .w = 140, .h = 22 }, .spacing = 6, .children = key }),
                            cx.make(SegmentBar{ .segments = segments, .height = @max(8, 4) }),
                        },
                    }),
                }),
            },
        });
    }

    /// A Wi-Fi network: its signal, name, security and band, in the middle
    /// of its row (`network_row_height`); pressing it chooses it.
    fn network(b: Builder, n: *const info.manager.Network, chosen: bool, joined: bool, on_press: ui.Callback) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const row = cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
            cx.make(ui.SizedBox{ .width = 150, .child = cx.make(ui.Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{
                cx.make(Signal{ .bars = n.bars(), .size = 20 }),
                cx.make(ui.Text{ .text = cx.fmt("{d} dBm", .{n.dbm()}), .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }),
            } }) }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = printable(cx, n.ssid()), .style = .{ .size = 18, .color = if (joined) t.primary else t.on_surface }, .wrap = false }) }),
            cx.make(ui.Text{ .text = cx.fmt("{s} · {s}", .{ n.security.label(), n.band() }), .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }),
        } });
        return cx.make(ui.Pressable{ .on_press = on_press, .child = cx.make(ui.Decorated{
            .color = if (chosen) t.secondary_container else gfx.Color.argb(0),
            .radius = .all(8),
            .child = cx.make(ui.Padding{ .padding = .{ .top = 3, .bottom = 3 }, .child = row }),
        }) });
    }

    /// A label, its value and a meter showing how much is used.
    fn meter(b: Builder, name: []const u8, text: []const u8, used: f32) ui.Widget {
        const cx = b.cx;
        return cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
            b.label(name),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 6, .children = &.{
                b.value(text),
                cx.make(Meter{ .fraction = used, .height = @max(8, 4) }),
            } }) }),
        } });
    }
};

/// Signal strength (0 to 4 bars) as the Wi-Fi icon, faint, with as many
/// of its arcs lit as the signal is strong: all three for 4 bars, two for
/// 3, the dot for 1 or 2, none for 0.
pub const Signal = struct {
    bars: u8,
    size: f32,

    pub fn lit(bars: u8) ?ui.icons.Icon {
        return switch (bars) {
            0 => null,
            1, 2 => .wifi_1_bar,
            3 => .wifi_2_bar,
            else => .wifi,
        };
    }

    pub fn build(self: *const Signal, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const back = cx.make(ui.Icon{ .icon = .wifi, .size = self.size, .color = t.on_surface.withAlpha(0.25) });
        const front = lit(self.bars) orelse return back;
        return cx.make(ui.SizedBox{ .width = self.size, .height = self.size, .child = cx.make(ui.Overlay{ .children = &.{
            back,
            cx.make(ui.Icon{ .icon = front, .size = self.size, .color = t.on_surface }),
        } }) });
    }
};

/// A bar of segments side by side, each `fraction` of its length (the
/// rest is the track: what is free).
pub const SegmentBar = struct {
    pub const Segment = struct { fraction: f32, color: gfx.Color };

    segments: []const Segment,
    height: f32,

    pub fn layout(self: *const SegmentBar, _: *ui.Node, c: ui.Constraints) ui.Size {
        return c.constrain(.{ .w = if (std.math.isFinite(c.max_w)) c.max_w else 200, .h = self.height });
    }

    pub fn paint(self: *const SegmentBar, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const h = n.size.h;
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = h }, .all(h / 2), t.surface_container_highest);
        // Each segment is drawn from the start, longest first, so each
        // keeps the bar's round start and only the last shows its end.
        var ends: [8]f32 = undefined;
        var x: f32 = 0;
        const segs = self.segments[0..@min(self.segments.len, ends.len)];
        for (segs, ends[0..segs.len]) |seg, *e| {
            const f = std.math.clamp(if (std.math.isFinite(seg.fraction)) seg.fraction else 0, 0, 1);
            x = @min(x + n.size.w * f, n.size.w);
            e.* = x;
        }
        var i = segs.len;
        while (i > 0) {
            i -= 1;
            const prev = if (i == 0) 0 else ends[i - 1];
            if (ends[i] <= prev) continue;
            // At least a round end's width, so a little still shows.
            c.fillRoundedRect(.{ .x = 0, .y = 0, .w = @max(ends[i], prev + h), .h = h }, .all(h / 2), segs[i].color);
        }
    }
};

/// A bar filled by `fraction` (0 to 1), in the error colour when nearly
/// full.
pub const Meter = struct {
    fraction: f32,
    height: f32,

    pub const warning = 0.9;

    pub fn layout(self: *const Meter, _: *ui.Node, c: ui.Constraints) ui.Size {
        return c.constrain(.{ .w = if (std.math.isFinite(c.max_w)) c.max_w else 200, .h = self.height });
    }

    pub fn paint(self: *const Meter, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        const radius: gfx.Radii = .all(n.size.h / 2);
        c.fillRoundedRect(r, radius, t.surface_container_highest);
        const f = std.math.clamp(if (std.math.isFinite(self.fraction)) self.fraction else 0, 0, 1);
        if (f <= 0) return;
        // At least a round end's width, so a little use still shows.
        const w = @max(n.size.w * f, n.size.h);
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = w, .h = n.size.h }, radius, if (f >= warning) t.@"error" else t.primary);
    }
};

const testing = std.testing;
const font = @import("font");

const sample_app_list = [_]store.App{
    .{ .name = "dazzle-demo", .title = "Demo", .description = "Spinning shapes, on the GPU", .icon = "view_in_ar", .file = "dazzle-demo.tar.xz", .size = 40 << 10, .sha256 = "" },
    .{ .name = "dazzle-files", .title = "Files", .description = "Your files", .icon = "folder", .file = "dazzle-files.tar.xz", .size = 50 << 10, .sha256 = "" },
};
const sample_apps: Apps = .{ .list = &sample_app_list, .installed = &.{ true, false }, .source = "https://example.com/apps" };

fn sample() struct { sys: info.System, net: info.Network, usage: info.Usage } {
    const sys: info.System = .{ .model = .of("Raspberry Pi Zero W Rev 1.1"), .cores = 1, .serial = .of("a1b2c3d4"), .kernel = .of("6.12.0 (armv6l)"), .hostname = .of("dazzle") };
    var net: info.Network = .{ .gateway = .{ 192, 168, 1, 1 } };
    net.interfaces[0] = .{ .name = .of("eth0"), .state = .of("up"), .carrier = true, .mac = .of("00:e0:4c:68:01:02"), .ip = .{ 192, 168, 1, 42 }, .prefix = 24, .speed = 100, .rx_bytes = 12 << 20, .tx_bytes = 3 << 20 };
    net.interfaces[1] = .{ .name = .of("eth1"), .state = .of("down") };
    net.len = 2;
    return .{ .sys = sys, .net = net, .usage = .{
        .cpu_busy = 23,
        .temperature = 48.3,
        .mem_total = 434 << 20,
        .mem_available = 300 << 20,
        .gpu_total = 64 << 20,
        .gpu_free = 60 << 20,
        .storage = .{ .system = 600 << 10, .apps = 2 << 20, .user = 0, .free = 300 << 20 },
        .uptime_s = 7500,
    } };
}

fn sampleWifi() info.manager.Report {
    var r: info.manager.Report = .{ .scanning = true };
    var a: info.manager.Adapter = .{ .mac = .{ 0xb8, 0x27, 0xeb, 1, 2, 3 }, .up = true };
    a.setName("wlan0");
    r.adapter = a;
    const nets = [_]struct { []const u8, i32, u32, info.manager.Security }{
        .{ "Home", -4800, 5180, .wpa2 },   .{ "Cafe", -6100, 2412, .open },      .{ "Library", -7000, 2437, .enterprise },
        .{ "Office", -7200, 2462, .wpa3 }, .{ "Neighbour", -8000, 2412, .wpa2 }, .{ "Shop", -8100, 2437, .wpa2 },
        .{ "Bus", -8200, 2412, .open },    .{ "Old", -8400, 2462, .wep },        .{ "Far", -8800, 2412, .wpa2 },
        .{ "Further", -9000, 2412, .wpa },
    };
    for (nets) |n| {
        var net: info.manager.Network = .{ .signal_mbm = n[1], .freq_mhz = n[2], .security = n[3] };
        net.setSsid(n[0]);
        r.add(net);
    }
    var odd: info.manager.Network = .{ .signal_mbm = -9500, .freq_mhz = 2412, .security = .wpa2 };
    odd.setSsid("bad\xffname");
    r.add(odd);
    return r;
}

fn texts(node: *ui.Node, out: *std.ArrayList(u8)) void {
    if (node.widget.is(ui.Text)) {
        out.appendSlice(testing.allocator, node.widget.as(ui.Text).?.text) catch {};
        out.append(testing.allocator, '\n') catch {};
    }
    for (node.children.items) |ch| texts(ch, out);
}

fn overflows(node: *ui.Node) bool {
    const o = node.overflow;
    if (o.left > 0 or o.top > 0 or o.right > 0 or o.bottom > 0) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

/// The sizes to lay out at: the smallest the window may be, as narrow
/// and as short as it may be, a restored window's first size on a 1080p
/// screen, and maximized on a 720p and a 1080p screen. Everything is the
/// same size in pixels in each.
const test_sizes = [_][2]u32{
    min_size,
    .{ min_size[0], 1036 },
    .{ 1920, min_size[1] },
    .{ 960, 518 },
    .{ 1280, 668 },
    .{ 1920, 1036 },
};

test "everything is shown, and fits from the smallest window to the biggest" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    const wifi = sampleWifi();
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    // Every page, at every size.
    var frame_no: u64 = 0;
    for (std.enums.values(Page)) |page| {
        for (test_sizes) |size| {
            frame_no += 1;
            u.frame(size[0], size[1], frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps });
            try testing.expect(!overflows(u.root.?));
        }
        // What shows maximized (in a smaller window, rows of the lists
        // further down are not made).
        frame_no += 1;
        u.frame(1920, 1036, frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps });
        texts(u.root.?, &all);
        // The next page, from its tab.
        if (@as(usize, @intFromEnum(page)) + 1 < std.enums.values(Page).len) {
            const next: Page = @enumFromInt(@as(usize, @intFromEnum(page)) + 1);
            click(u, up(findText(u.root.?, next.label()).?, Tab).?);
            try testing.expectEqual(next, shownPage(u));
        }
    }
    for ([_][]const u8{
        "574d538",
        "Raspberry Pi Zero W Rev 1.1",
        "a1b2c3d4",
        "Resources",
        "23% busy (1 core)",
        "48.3 °C",
        "134 MB of 434 MB in use",
        "4.0 MB of 64 MB in use",
        "System 600 KB",
        "Apps 2.0 MB",
        "User 0 bytes",
        "Free 300 MB",
        "Hostname",
        "Ethernet",
        "2 h 5 min",
        "Connected at 100 Mb/s",
        "192.168.1.42/24 (DHCP)",
        "12 MB received, 3.0 MB sent",
        "Not connected: no cable",
        "192.168.1.1",
        "wlan0 (b8:27:eb:01:02:03)",
        "Scanning…",
        // Every network: the page scrolls.
        "Further",
        "bad?name",
        "Not connected",
        "Home",
        "WPA2 · 5 GHz",
        "-48 dBm",
        "Open · 2.4 GHz",
        "Enterprise · 2.4 GHz",
        // The apps.
        "Spinning shapes, on the GPU",
        "Install",
        "Remove",
        "From https://example.com/apps",
    }) |want| {
        if (std.mem.indexOf(u8, all.items, want) == null) {
            std.debug.print("missing \"{s}\" in:\n{s}\n", .{ want, all.items });
            return error.TestUnexpectedResult;
        }
    }
    // In a small window, only the networks that show are made.
    u.root.?.state(Settings.State).page = .wifi;
    u.frame(min_size[0], min_size[1], frame_no + 1, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps });
    u.frame(min_size[0], min_size[1], frame_no + 2, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps });
    try testing.expect(findText(u.root.?, "Home") != null);
    try testing.expect(findText(u.root.?, "bad?name") == null);
    // The build is in the system card, not beside the title; the hardware
    // is the board alone.
    for ([_][]const u8{ "Dazzle build", "Hardware\n", "Chip", "GPU\n", "Revision", "In use" }) |gone| {
        try testing.expect(std.mem.indexOf(u8, all.items, gone) == null);
    }
}

test "without a network adapter, the network card says so" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    const none: info.Network = .{};
    const settings: Settings = .{ .commit = "x", .system = &d.sys, .usage = .{}, .network = &none };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .ethernet;
    u.frame(1920, 960, 1, settings);
    try testing.expect(findText(u.root.?, "No adapter: plug in a USB Ethernet adapter") != null);
    u.root.?.state(Settings.State).page = .resources;
    u.frame(1920, 960, 2, settings);
    try testing.expect(findText(u.root.?, "Measuring…") != null);
}

test "the Wi-Fi card says when it cannot list networks" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
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
        texts(u.root.?, &all);
        try testing.expect(std.mem.indexOf(u8, all.items, case[1]) != null);
    }
}

test "SSIDs that are not text are shown readably" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var r: info.manager.Report = .{};
    r.adapter = .{ .up = true };
    var odd: info.manager.Network = .{ .signal_mbm = -5000, .freq_mhz = 2412, .security = .wpa2 };
    odd.setSsid("bad\xffname");
    r.add(odd);
    u.frame(1920, 960, 0, Settings{ .commit = "x", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &r });
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    texts(u.root.?, &all);
    try testing.expect(std.mem.indexOf(u8, all.items, "bad?name") != null);
}

fn findText(node: *ui.Node, text: []const u8) ?*ui.Node {
    if (node.widget.as(ui.Text)) |t| if (std.mem.eql(u8, t.text, text)) return node;
    for (node.children.items) |ch| if (findText(ch, text)) |n| return n;
    return null;
}

fn findType(node: *ui.Node, comptime T: type) ?*ui.Node {
    if (node.widget.is(T)) return node;
    for (node.children.items) |ch| if (findType(ch, T)) |n| return n;
    return null;
}

/// The nearest node above `n` (or `n`) whose widget is a `T`.
fn up(n: *ui.Node, comptime T: type) ?*ui.Node {
    var at: ?*ui.Node = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

fn click(u: *ui.Ui, n: *ui.Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + 4, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
}

test "choosing a network, typing its password and connecting" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    const wifi = sampleWifi();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi };
    u.frame(1920, 960, 0, settings);
    click(u, findText(u.root.?, "Home").?);
    u.frame(1920, 960, 1, settings);
    // The form fits at every size the shell gives, even with another
    // connection being made (and its Disconnect button).
    var joining = wifi;
    joining.connection = .{ .state = .authenticating };
    joining.connection.setSsid("Cafe");
    for ([_]*const info.manager.Report{ &wifi, &joining }) |report| for (test_sizes) |size| {
        u.frame(size[0], size[1], 2, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = report });
        try testing.expect(!overflows(u.root.?));
    };
    u.frame(1920, 960, 3, settings);
    click(u, findType(u.root.?, ui.TextField).?);
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
    try testing.expect(findType(u.root.?, ui.TextField) == null);

    // Connected: the connection row says so, with Disconnect.
    var joined = wifi;
    joined.connection = .{ .state = .connected, .address = .{ 192, 168, 1, 50 } };
    joined.connection.setSsid("Home");
    u.frame(1920, 960, 5, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &joined });
    try testing.expect(findText(u.root.?, "Connected to Home (192.168.1.50)") != null);
    click(u, findText(u.root.?, "Disconnect").?);
    try testing.expect(actions.disconnect);

    // A network whose security is not supported cannot be joined.
    actions = .{};
    u.frame(1920, 960, 6, settings);
    click(u, findText(u.root.?, "Library").?);
    u.frame(1920, 960, 7, settings);
    try testing.expect(findText(u.root.?, "Enterprise networks are not supported yet") != null);
    click(u, findText(u.root.?, "Connect").?);
    try testing.expect(actions.connect == null);

    // Failures say why.
    var failed = wifi;
    failed.connection = .{ .state = .failed, .failure = .wrong_password };
    failed.connection.setSsid("Home");
    u.frame(1920, 960, 8, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &failed });
    try testing.expect(findText(u.root.?, "Could not connect to Home: wrong password") != null);
}

test "choosing a static address for Ethernet, and DHCP again" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var report = sampleWifi();
    var actions: Actions = .{};
    var frame_no: u64 = 0;
    const Draw = struct {
        fn draw(uu: *ui.Ui, dd: anytype, r: *const info.manager.Report, acts: *Actions, n: *u64, size: [2]u32) void {
            n.* += 1;
            uu.frame(size[0], size[1], n.*, Settings{ .commit = "x", .actions = acts, .system = &dd.sys, .usage = dd.usage, .network = &dd.net, .manager = r });
        }
    }.draw;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    click(u, up(findText(u.root.?, "Ethernet").?, Tab).?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(findText(u.root.?, "Addressing") != null);
    try testing.expect(findText(u.root.?, "192.168.1.42/24 (DHCP)") != null);
    try testing.expect(findType(u.root.?, ui.TextField) == null);

    // Static opens the form, filled in with what DHCP gave; it fits.
    click(u, findText(u.root.?, "Static").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    const field = findType(u.root.?, ui.TextField).?;
    try testing.expectEqualStrings("192.168.1.42/24", field.state(ui.TextField.State).text());
    try testing.expect(actions.ethernet == null);
    for ([_][2]u32{ .{ 1920, 960 }, .{ 1280, 600 }, .{ 1024, 668 }, .{ 960, 480 } }) |size| {
        Draw(u, d, &report, &actions, &frame_no, size);
        try testing.expect(!overflows(u.root.?));
    }
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });

    // Not an address: it says so, and asks nothing.
    var st = u.root.?.state(Settings.State);
    st.address.set("192.168.1/24");
    click(u, findText(u.root.?, "Apply").?);
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(actions.ethernet == null);
    try testing.expect(findText(u.root.?, "Give an address and prefix length (192.168.1.50/24), and a gateway or none") != null);
    // An address: it is asked for.
    st = u.root.?.state(Settings.State);
    st.address.set("192.168.1.50/24");
    click(u, findText(u.root.?, "Apply").?);
    try testing.expectEqual(info.manager.Static.parse("192.168.1.50/24", "192.168.1.1").?, actions.ethernet.?.static);
    actions = .{};

    // The manager now says static: the form stays, filled in with it.
    report.ethernet.addressing = .{ .static = info.manager.Static.parse("192.168.1.50/24", "192.168.1.1").? };
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(findText(u.root.?, "192.168.1.42/24 (static)") != null);
    try testing.expect(findType(u.root.?, ui.TextField) != null);
    // DHCP again is asked for at once, and the form closes.
    click(u, findText(u.root.?, "DHCP").?);
    try testing.expect(actions.ethernet.? == .dhcp);
    report.ethernet.addressing = .dhcp;
    Draw(u, d, &report, &actions, &frame_no, .{ 1920, 960 });
    try testing.expect(findType(u.root.?, ui.TextField) == null);
}

test "installing and removing apps, and getting their list again" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .apps = sample_apps };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(1920, 960, 1, settings);
    click(u, up(findText(u.root.?, "Install").?, ui.OutlinedButton).?);
    try testing.expectEqualStrings("dazzle-files", actions.install.?.slice());
    click(u, up(findText(u.root.?, "Remove").?, ui.OutlinedButton).?);
    try testing.expectEqualStrings("dazzle-demo", actions.remove.?.slice());
    click(u, up(findText(u.root.?, "Refresh").?, ui.OutlinedButton).?);
    try testing.expect(actions.refresh_apps);

    // While one installs: a spinner in its place, and nothing else can be
    // pressed.
    actions = .{};
    settings.apps.busy = "dazzle-files";
    u.frame(1920, 960, 2, settings);
    try testing.expect(findText(u.root.?, "Install") == null);
    try testing.expect(findText(u.root.?, "Installing…") != null);
    click(u, up(findText(u.root.?, "Remove").?, ui.OutlinedButton).?);
    try testing.expect(actions.remove == null);

    // Before setup: nothing can be installed, and it says why.
    settings.apps = sample_apps;
    settings.apps.writable = false;
    u.frame(1920, 960, 3, settings);
    try testing.expect(findText(u.root.?, "Apps can be installed once setup has finished") != null);
    click(u, up(findText(u.root.?, "Install").?, ui.OutlinedButton).?);
    try testing.expect(actions.install == null);

    // No list yet.
    settings.apps = .{};
    u.frame(1920, 960, 4, settings);
    try testing.expect(findText(u.root.?, "No list of apps yet: is the network up?") != null);
}
