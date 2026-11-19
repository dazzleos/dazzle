//! The Software page, in two tabs: Installed (Dazzle itself, and the apps
//! installed) and Available (the catalogue's other apps, with a field to
//! search them). An app clicked shows its page: what it is, its
//! screenshot, and Install, Update or Remove; Dazzle's, how its updates
//! stand (with Update or Restart), and its build and kernel. The gear in
//! the status bar shows where software comes from (the official store, or
//! a custom server and its key). Back returns to the list.
//! Under them, a fixed status bar with Update all and Refresh.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const locale = @import("locale");
const gfx = kete.gfx;
const store = @import("store");
const sys_mod = @import("sys");
const info = @import("info.zig");
const update = @import("update.zig");
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;
const Page = view.Page;

pub const label = "Software";
pub const icon: kete.IconName = .apps;

/// What the Software page shows of apps.
pub const Apps = struct {
    /// The catalogue's apps, whether each is installed, and whether each
    /// installed app has a newer version in the catalogue.
    list: []const store.App = &.{},
    /// How many of `list` (from its start) the catalogue offers; the rest
    /// are installed, and no longer offered (they can be removed).
    offered: usize = std.math.maxInt(usize),
    installed: []const bool = &.{},
    updatable: []const bool = &.{},
    /// Each app's 64x64 icon (installed, or from the server when
    /// uninstalled, not on disk or a newer version is available); null
    /// for the fallback icon.
    icons: []const ?*const gfx.Image = &.{},
    /// Apps' screenshots, decoded as their pages are shown.
    screenshots: ?*Screenshots = null,
    /// The app being installed ("" for the list itself, "*" for updating
    /// all); null if nothing is under way.
    busy: ?[]const u8 = null,
    /// What it has downloaded so far (and will in all, if known).
    transfer: store.Transfer = .{},
    /// What happened last.
    message: []const u8 = "",
    /// Where they come from, and the default server URL.
    source: []const u8 = store.default_url,
    default_source: []const u8 = store.default_url,
    /// Built-in Ed25519 signing public key (64 hex chars) and subscribed keys.
    default_key: []const u8 = store.default_signing_key,
    subscribed_keys: []const [store.key_hex_len]u8 = &.{},
};

/// What the Software page shows of OS updates.
pub const Update = struct {
    status: update.Status = .unknown,
    /// The system offered: "0123abc (8 October 2026)".
    available: []const u8 = "",
    /// The archive's size in bytes, when an update is offered.
    size: u64 = 0,
    /// What went wrong last.
    message: []const u8 = "",
    /// What the download under way has got (and will in all).
    transfer: store.Transfer = .{},
    /// Dazzle's 64x64 icon (installed, or from the server when a newer
    /// version is available or none is on disk); null for the fallback icon.
    icon: ?*const gfx.Image = null,
};

pub const State = struct {
    /// Whether Dazzle's page is shown (instead of the list).
    dazzle_page: bool = false,
    /// Whether the current error snackbar has been dismissed.
    dismissed: bool = false,
    last_message_buf: [160]u8 = undefined,
    last_message_len: u8 = 0,
    /// Whether the page of where software comes from is shown (instead of
    /// the list); the source chosen there; what is typed for a custom one
    /// (its URL and key), and whether they were not an `https://` URL and a
    /// 64-character hex Ed25519 public key; and the fields' generation (new
    /// when they are filled again).
    source_page: bool = false,
    source_kind: SourceKind = .official,
    server_url: Field = .{},
    server_invalid: bool = false,
    key_input: Field = .{},
    key_invalid: bool = false,
    source_form_id: u32 = 0,
    /// Where software comes from, as the last frame was built: the server,
    /// the official one, its key, the custom server's key (if any), and
    /// where to ask for a change.
    source_now: []const u8 = store.default_url,
    official_now: []const u8 = store.default_url,
    official_key_now: []const u8 = store.default_signing_key,
    key_now: []const u8 = "",
    actions_now: ?*Actions = null,
    /// The tab shown, what is searched for in Available, and the app
    /// whose page is shown (instead of the list), if any.
    tab: Tab = .installed,
    query: Field = .{},
    details: ?Actions.AppName = null,

    pub const Tab = enum { installed, available };
    pub const SourceKind = enum { official, custom };

    fn selectTab(st: *State, i: usize) void {
        st.tab = if (i == 0) .installed else .available;
        st.details = null;
    }

    fn setQuery(st: *State, q: []const u8) void {
        st.query.set(q);
    }

    fn back(st: *State) void {
        st.details = null;
        st.dazzle_page = false;
        st.source_page = false;
    }

    fn isCustom(st: *const State) bool {
        return !std.mem.eql(u8, st.source_now, st.official_now);
    }

    /// The page of where software comes from, as it is now.
    pub fn openSource(st: *State) void {
        st.source_page = true;
        st.source_kind = if (st.isCustom()) .custom else .official;
        st.fillSourceForm();
    }

    /// The custom source's fields: as it is, or (from the official store)
    /// a URL to start from and no key.
    fn fillSourceForm(st: *State) void {
        st.server_invalid = false;
        st.key_invalid = false;
        st.server_url.set(if (st.isCustom()) st.source_now else "https://");
        st.key_input.set(if (st.isCustom()) st.key_now else "");
        st.source_form_id +%= 1;
    }

    /// The official store, at once; or a custom server, its URL and key
    /// to be given (and applied).
    pub fn chooseSource(st: *State, kind: SourceKind) void {
        st.source_kind = kind;
        st.fillSourceForm();
        if (kind == .official and st.isCustom()) if (st.actions_now) |acts| {
            acts.software_server = .{};
            acts.software_key = .{};
        };
    }

    /// The custom server and its key, if they are right; then the list.
    fn applySource(st: *State) void {
        const url = store.parseHttpsUrl(st.server_url.text());
        var hex: [store.key_hex_len]u8 = undefined;
        const key_text = std.mem.trim(u8, st.key_input.text(), " ");
        const key: ?[]const u8 = if (key_text.len == 0) "" else if (store.parsePublicKey(key_text, &hex) != null) &hex else null;
        st.server_invalid = url == null;
        st.key_invalid = key == null;
        if (url == null or key == null) return;
        if (st.actions_now) |acts| {
            acts.software_server = if (std.mem.eql(u8, url.?, st.official_now)) .{} else .of(url.?);
            acts.software_key = .of(key.?);
        }
        st.source_page = false;
    }

    pub const Field = struct {
        buf: [store.max_url_len]u8 = undefined,
        len: u8 = 0,

        pub fn text(f: *const Field) []const u8 {
            return f.buf[0..f.len];
        }

        pub fn set(f: *Field, t: []const u8) void {
            f.len = @intCast(@min(t.len, f.buf.len));
            @memcpy(f.buf[0..f.len], t[0..f.len]);
        }
    };

    pub fn openDazzle(st: *State) void {
        st.dazzle_page = true;
    }

    pub fn dismissMessage(st: *State) void {
        st.dismissed = true;
    }

    pub fn setServerUrl(st: *State, t: []const u8) void {
        st.server_url.set(t);
    }

    pub fn setKeyInput(st: *State, t: []const u8) void {
        st.key_input.set(t);
    }
};

pub fn build(self: *const Settings, b: Builder, state: *State) kete.Widget {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const apps = &self.apps;
    var rows: std.ArrayList(kete.Widget) = .empty;
    const a = cx.arena;
    const os_busy = self.update.status == .checking or self.update.status == .downloading or self.update.status == .installing;
    const busy = apps.busy != null or os_busy;
    const err_msg = if (apps.message.len > 0 and !std.mem.startsWith(u8, apps.message, locale.text("Cannot get the list of apps")))
        apps.message
    else
        "";
    if (err_msg.len == 0 or apps.busy != null) {
        state.dismissed = false;
        state.last_message_len = 0;
    } else if (!std.mem.eql(u8, state.last_message_buf[0..state.last_message_len], err_msg)) {
        const n: u8 = @intCast(@min(err_msg.len, state.last_message_buf.len));
        @memcpy(state.last_message_buf[0..n], err_msg[0..n]);
        state.last_message_len = n;
        state.dismissed = false;
    }
    const snackbar_msg = if (state.dismissed) "" else err_msg;
    const fixed = if (self.parental) |p| p.on and p.limits.block_software else false;
    var updates: usize = @intFromBool(self.update.status == .available);
    for (apps.list, 0..) |_, i| {
        const installed = i < apps.installed.len and apps.installed[i];
        if (installed and i < apps.updatable.len and apps.updatable[i]) updates += 1;
    }
    // An app's page, or the tab's list.
    const shown: ?usize = if (state.details) |d| for (apps.list, 0..) |app, i| {
        if (std.mem.eql(u8, app.name, d.slice())) break i;
    } else null else null;
    state.official_now = if (apps.default_source.len > 0) apps.default_source else store.default_url;
    state.source_now = if (apps.source.len > 0) apps.source else state.official_now;
    state.official_key_now = if (apps.default_key.len > 0) apps.default_key else store.default_signing_key;
    state.key_now = if (apps.subscribed_keys.len > 0) &apps.subscribed_keys[0] else "";
    state.actions_now = self.actions;
    if (state.source_page) {
        sourcePage(self, b, state, &rows);
    } else if (state.dazzle_page) {
        dazzlePage(self, b, state, &rows);
    } else if (shown) |i| {
        detailsRows(self, b, state, i, busy, fixed, &rows);
    } else {
        rows.append(a, cx.make(kete.TabBar{
            .tabs = a.dupe(kete.Tab, &.{
                .{ .label = locale.text("Installed"), .icon = .apps, .badge = if (updates > 0) @intCast(updates) else null },
                .{ .label = locale.text("Available"), .icon = .download },
            }) catch &.{},
            .selected = @intFromEnum(state.tab),
            .on_select = .of(state, State.selectTab),
        })) catch {};
        if (state.tab == .installed) {
            dazzleRows(self, b, state, &rows);
        } else {
            rows.append(a, cx.make(kete.TextField{ .placeholder = locale.text("Search"), .initial = state.query.text(), .on_changed = .of(state, State.setQuery), .width = std.math.inf(f32) })) catch {};
        }
        // Parental controls may stop apps being installed or removed
        // (updates still come).
        if (fixed) rows.append(a, cx.make(kete.Text{ .text = locale.text("Parental controls stop apps being installed or removed"), .style = .{ .size = 15, .color = t.on_surface_variant } })) catch {};
        var listed: usize = 0;
        for (apps.list, 0..) |app, i| {
            const installed = i < apps.installed.len and apps.installed[i];
            const updatable = installed and i < apps.updatable.len and apps.updatable[i];
            if ((state.tab == .installed) != installed) continue;
            if (state.tab == .available and (i >= apps.offered or !matches(app, state.query.text()))) continue;
            listed += 1;
            const this_busy = if (apps.busy) |n| std.mem.eql(u8, n, app.name) or (std.mem.eql(u8, n, "*") and updatable) else false;
            var size_buf: [32]u8 = undefined;
            const installing = if (apps.busy) |n| std.mem.eql(u8, n, app.name) else false;
            const detail = if (installing)
                withTransfer(cx, locale.text("Installing…"), apps.transfer)
            else if (i >= apps.offered)
                locale.text("Installed, and no longer offered")
            else if (updatable)
                locale.text("Update available")
            else if (app.description.len > 0)
                kete_vc4.textf(cx, "{s} · {s}", .{ app.description, info.formatBytes(&size_buf, app.size) })
            else
                cx.fmt("{s}", .{info.formatBytes(&size_buf, app.size)});
            const app_icon: ?*const gfx.Image = if (i < apps.icons.len) apps.icons[i] else null;
            const open = a.create(OpenApp) catch continue;
            open.* = .{ .state = state, .name = .init(app.name) };
            rows.append(a, cx.make(kete.Pressable{
                .on_press = .of(open, OpenApp.open),
                .child = cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = a.dupe(kete.Widget, &.{
                    softwareIcon(cx, app_icon),
                    cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = withBar(cx, &.{
                        cx.make(kete.Text{ .text = app.title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
                        cx.make(kete.Text{ .text = detail, .style = .{ .size = 15, .color = t.on_surface_variant } }),
                    }, if (installing) apps.transfer else null) }) }),
                    if (this_busy) cx.make(kete.Spinner{ .size = 28 }) else cx.make(kete.Icon{ .icon = .chevron_right, .size = 24, .color = t.on_surface_variant }),
                }) catch &.{} }),
            })) catch {};
        }
        if (listed == 0 and state.tab == .available and apps.list.len > 0) rows.append(a, cx.make(kete.Text{
            .text = if (state.query.len > 0) locale.text("No app matches") else locale.text("Every app is installed"),
            .style = .{ .size = 15, .color = t.on_surface_variant },
        })) catch {};
    }
    const status = if (apps.busy) |name|
        (if (name.len == 0) withTransfer(cx, locale.text("Getting the list of apps…"), apps.transfer) else if (std.mem.eql(u8, name, "*")) withTransfer(cx, locale.text("Updating…"), apps.transfer) else locale.text("Installing…"))
    else if (self.update.status == .checking)
        locale.text("Checking for updates…")
    else if (self.update.status == .downloading or self.update.status == .installing)
        locale.text("Updating…")
    else if (updates == 1)
        locale.text("1 update available")
    else if (updates > 1)
        kete_vc4.textf(cx, "{d} updates available", .{updates})
    else if (apps.list.len == 0)
        locale.text("No list of apps yet: is the network up?")
    else
        locale.text("All apps updated");
    var footer_children: std.ArrayList(kete.Widget) = .empty;
    // Under way: a spinner by what is.
    if (busy) footer_children.append(a, cx.make(kete.Spinner{ .size = 24 })) catch {};
    footer_children.append(a, cx.make(kete.Expanded{ .child = b.value(status) })) catch {};
    if (updates > 0) {
        footer_children.append(a, cx.make(kete.OutlinedButton{
            .label = locale.text("Update all"),
            .icon = .download,
            .on_press = if (self.actions != null and !busy) .of(appAct(cx, self.actions.?, state, ""), AppAct.updateAll) else null,
        })) catch {};
    }
    footer_children.append(a, cx.make(kete.OutlinedButton{
        .label = locale.text("Refresh"),
        .icon = .refresh,
        .on_press = if (self.actions != null and !busy) .of(appAct(cx, self.actions.?, state, ""), AppAct.refresh) else null,
    })) catch {};
    footer_children.append(a, cx.make(kete.Tooltip{ .text = locale.text("Software source"), .child = cx.make(kete.IconButton{
        .icon = .settings,
        .size = 36,
        .icon_size = 20,
        .on_press = if (self.actions != null and !busy) .of(state, State.openSource) else null,
    }) })) catch {};
    const footer = cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = footer_children.items });
    // A scroll of its own for each tab and app's page: each starts at its top.
    const scroll_key: u64 = @as(u64, @intFromEnum(Page.apps)) + 1 + if (shown) |i| 16 + @as(u64, i) else @as(u64, @intFromEnum(state.tab)) * 4;
    return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = &.{
        cx.make(kete.Expanded{ .child = cx.make(kete.Snackbar{
            .message = snackbar_msg,
            .on_dismiss = .of(state, State.dismissMessage),
            .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Padding{
                .padding = .{ .left = 24, .top = 24, .right = 24, .bottom = 12 },
                .child = cx.make(kete.Align{
                    .alignment = .top_center,
                    .child = cx.make(view.PageWidth{ .child = b.page(rows.items) }),
                }),
            }) }).withKey(scroll_key),
        }) }),
        cx.make(kete.Padding{
            .padding = .{ .left = 24, .top = 12, .right = 24, .bottom = 24 },
            .child = cx.make(kete.Align{
                .alignment = .center,
                .height_factor = 1,
                .child = cx.make(view.PageWidth{ .child = footer }),
            }),
        }),
    } });
}

/// An app's row clicked: its page.
const OpenApp = struct {
    state: *State,
    name: Actions.AppName,

    fn open(o: *OpenApp) void {
        o.state.details = o.name;
    }
};

/// Whether `app`'s name, title or description has `q` in it.
fn matches(app: store.App, q: []const u8) bool {
    const query = std.mem.trim(u8, q, " ");
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(app.title, query) != null or std.ascii.findIgnoreCase(app.description, query) != null or std.ascii.findIgnoreCase(app.name, query) != null;
}

/// App `i`'s page: Back, its icon, name and what it is; Install, Update
/// or Remove; its screenshot, and more about it.
fn detailsRows(self: *const Settings, b: Builder, state: *State, i: usize, busy: bool, fixed: bool, rows: *std.ArrayList(kete.Widget)) void {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const a = cx.arena;
    const apps = &self.apps;
    const app = apps.list[i];
    const installed = i < apps.installed.len and apps.installed[i];
    const updatable = installed and i < apps.updatable.len and apps.updatable[i];
    const this_busy = if (apps.busy) |n| std.mem.eql(u8, n, app.name) or (std.mem.eql(u8, n, "*") and updatable) else false;
    const enabled = self.actions != null and !busy;
    const x = if (self.actions) |acts| appAct(cx, acts, state, app.name) else null;
    rows.append(a, cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
        cx.make(kete.TextButton{ .label = locale.text("Back"), .icon = .arrow_back, .on_press = .of(state, State.back) }),
    }) catch &.{} })) catch {};
    var buttons: std.ArrayList(kete.Widget) = .empty;
    if (this_busy) {
        buttons.append(a, cx.make(kete.Spinner{ .size = 28 })) catch {};
    } else {
        if (updatable) buttons.append(a, cx.make(kete.FilledButton{ .label = locale.text("Update"), .icon = .download, .on_press = if (enabled) .of(x.?, AppAct.install) else null })) catch {};
        if (installed) {
            buttons.append(a, cx.make(kete.OutlinedButton{ .label = locale.text("Remove"), .icon = .delete, .destructive = true, .on_press = if (enabled and !fixed) .of(x.?, AppAct.remove) else null })) catch {};
        } else {
            buttons.append(a, cx.make(kete.FilledButton{ .label = locale.text("Install"), .icon = .download, .on_press = if (enabled and !fixed) .of(x.?, AppAct.install) else null })) catch {};
        }
    }
    var size_buf: [32]u8 = undefined;
    const installing = if (apps.busy) |n| std.mem.eql(u8, n, app.name) else false;
    const detail = if (installing)
        withTransfer(cx, locale.text("Installing…"), apps.transfer)
    else if (i >= apps.offered)
        locale.text("Installed, and no longer offered")
    else if (app.description.len > 0)
        kete_vc4.textf(cx, "{s} · {s}", .{ app.description, info.formatBytes(&size_buf, app.size) })
    else
        cx.fmt("{s}", .{info.formatBytes(&size_buf, app.size)});
    const app_icon: ?*const gfx.Image = if (i < apps.icons.len) apps.icons[i] else null;
    rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = a.dupe(kete.Widget, &.{
        softwareIcon(cx, app_icon),
        cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = withBar(cx, &.{
            cx.make(kete.Text{ .text = app.title, .style = .{ .size = 24, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
            cx.make(kete.Text{ .text = detail, .style = .{ .size = 15, .color = t.on_surface_variant } }),
        }, if (installing) apps.transfer else null) }) }),
        cx.make(kete.Row{ .fill = false, .cross_axis_alignment = .center, .spacing = 8, .children = buttons.items }),
    }) catch &.{} })) catch {};
    if (fixed) rows.append(a, cx.make(kete.Text{ .text = locale.text("Parental controls stop apps being installed or removed"), .style = .{ .size = 15, .color = t.on_surface_variant } })) catch {};
    // Its screenshot, as the catalogue was got.
    if (app.screenshot.len > 0) if (apps.screenshots) |shots| if (shots.get(app.name)) |img| {
        rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 8 }, .child = cx.make(kete.Align{ .alignment = .center, .height_factor = 1, .child = cx.make(kete.SizedBox{
            .height = 360,
            .child = cx.make(kete.Image{ .source = .{ .image = img } }),
        }) }) })) catch {};
    };
    if (app.about.len > 0) rows.append(a, cx.make(kete.Text{ .text = app.about, .style = .{ .size = 16, .color = t.on_surface } })) catch {};
}

fn downloadUpdate(a: *Actions) void {
    a.download_update = true;
}

fn restartNow(a: *Actions) void {
    a.restart = true;
}

/// How Dazzle's updates stand: what to say, the button (Update or
/// Restart) if any, and whether it is under way.
const DazzleStatus = struct {
    text: []const u8,
    button: ?struct { label: []const u8, icon: kete.IconName, restart: bool },
    busy: bool,

    fn of(self: *const Settings, cx: *kete.BuildContext) DazzleStatus {
        const u = &self.update;
        var size_buf: [32]u8 = undefined;
        const detail = if (self.usage.storage.system > 0)
            kete_vc4.textf(cx, "The operating system · {s}", .{info.formatBytes(&size_buf, self.usage.storage.system)})
        else
            locale.text("The operating system");
        const available_text = if (u.message.len > 0)
            u.message
        else if (u.size > 0)
            kete_vc4.textf(cx, "Dazzle {s} is available · {s}", .{ u.available, info.formatBytes(&size_buf, u.size) })
        else
            kete_vc4.textf(cx, "Dazzle {s} is available", .{u.available});
        return switch (u.status) {
            .unknown, .current => .{ .text = if (u.message.len > 0) u.message else detail, .button = null, .busy = false },
            .checking => .{ .text = locale.text("Checking for updates…"), .button = null, .busy = true },
            .available => .{ .text = available_text, .button = .{ .label = locale.text("Update"), .icon = .download, .restart = false }, .busy = false },
            .downloading => .{ .text = withTransfer(cx, locale.text("Downloading the update…"), u.transfer), .button = null, .busy = true },
            .installing => .{ .text = locale.text("Installing the update…"), .button = null, .busy = true },
            .ready => .{ .text = if (u.message.len > 0) u.message else locale.text("The update is installed: restart to use it"), .button = .{ .label = locale.text("Restart"), .icon = .restart_alt, .restart = true }, .busy = false },
        };
    }
};

/// Dazzle itself, at the head of the Installed list, as an app is: how its
/// updates stand, and (pressed) its page.
fn dazzleRows(self: *const Settings, b: Builder, state: *State, rows: *std.ArrayList(kete.Widget)) void {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const s = DazzleStatus.of(self, cx);
    rows.append(cx.arena, cx.make(kete.Pressable{
        .on_press = .of(state, State.openDazzle),
        .child = cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = cx.arena.dupe(kete.Widget, &.{
            softwareIcon(cx, self.update.icon),
            cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = withBar(cx, &.{
                cx.make(kete.Text{ .text = locale.text("Dazzle"), .style = .{ .size = 18, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
                cx.make(kete.Text{ .text = s.text, .style = .{ .size = 15, .color = t.on_surface_variant } }),
            }, if (self.update.status == .downloading) self.update.transfer else null) }) }),
            if (s.busy) cx.make(kete.Spinner{ .size = 28 }) else cx.make(kete.Icon{ .icon = .chevron_right, .size = 24, .color = t.on_surface_variant }),
        }) catch &.{} }),
    })) catch {};
}

/// Dazzle's page, as an app's is: Back, its icon, name and how its updates
/// stand; Update or Restart; its build and kernel.
fn dazzlePage(self: *const Settings, b: Builder, state: *State, rows: *std.ArrayList(kete.Widget)) void {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const a = cx.arena;
    const s = DazzleStatus.of(self, cx);
    rows.append(a, cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
        cx.make(kete.TextButton{ .label = locale.text("Back"), .icon = .arrow_back, .on_press = .of(state, State.back) }),
    }) catch &.{} })) catch {};
    const end: kete.Widget = if (s.busy) cx.make(kete.Spinner{ .size = 28 }) else if (s.button) |btn| cx.make(kete.FilledButton{
        .label = btn.label,
        .icon = btn.icon,
        .on_press = if (self.actions) |acts| (if (btn.restart) kete.Callback.of(acts, restartNow) else kete.Callback.of(acts, downloadUpdate)) else null,
    }) else cx.make(kete.SizedBox.empty);
    rows.append(a, cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = a.dupe(kete.Widget, &.{
        softwareIcon(cx, self.update.icon),
        cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = withBar(cx, &.{
            cx.make(kete.Text{ .text = locale.text("Dazzle"), .style = .{ .size = 24, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
            cx.make(kete.Text{ .text = s.text, .style = .{ .size = 15, .color = t.on_surface_variant } }),
        }, if (self.update.status == .downloading) self.update.transfer else null) }) }),
        end,
    }) catch &.{} })) catch {};
    rows.append(a, cx.make(kete.Padding{ .padding = .{ .top = 8 }, .child = cx.make(kete.Column{
        .cross_axis_alignment = .stretch,
        .fill = false,
        .spacing = 4,
        .children = a.dupe(kete.Widget, &.{
            dazzleDetail(cx, locale.text("Build"), self.commit),
            dazzleDetail(cx, "Linux", view.orUnknown(self.system.kernel.slice())),
        }) catch &.{},
    }) })) catch {};
}

fn dazzleDetail(cx: *kete.BuildContext, name: []const u8, text: []const u8) kete.Widget {
    const t = &cx.ui.theme;
    return cx.make(kete.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
        cx.make(kete.SizedBox{ .width = 80, .child = cx.make(kete.Text{ .text = name, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false }) }),
        cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = text, .style = .{ .size = 15, .color = t.on_surface } }) }),
    } });
}

/// Install, Remove, Update all and Refresh on the Software page: requests
/// for the main loop.
const AppAct = struct {
    actions: *Actions,
    state: *State,
    name: Actions.AppName,

    fn install(x: *AppAct) void {
        x.state.dismissed = false;
        x.actions.install = x.name;
    }

    fn remove(x: *AppAct) void {
        x.state.dismissed = false;
        x.actions.remove = x.name;
    }

    fn updateAll(x: *AppAct) void {
        x.state.dismissed = false;
        x.actions.update_all = true;
    }

    fn refresh(x: *AppAct) void {
        x.state.dismissed = false;
        x.actions.refresh_apps = true;
        x.actions.check_update = true;
    }
};

fn appAct(cx: *kete.BuildContext, actions: *Actions, state: *State, name: []const u8) *AppAct {
    const x = cx.arena.create(AppAct) catch unreachable;
    x.* = .{ .actions = actions, .state = state, .name = .init(name) };
    return x;
}

pub const SourceMenu = kete.Select(State.SourceKind);

/// Where software comes from: Source (the official store, or a custom
/// server), and its URL and key, which can be changed for a custom one
/// (and applied).
fn sourcePage(self: *const Settings, b: Builder, state: *State, rows: *std.ArrayList(kete.Widget)) void {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const a = cx.arena;
    const custom = state.source_kind == .custom;
    rows.append(a, cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
        cx.make(kete.TextButton{ .label = locale.text("Back"), .icon = .arrow_back, .on_press = .of(state, State.back) }),
    }) catch &.{} })) catch {};
    rows.append(a, cx.make(kete.Text{ .text = locale.text("Software source"), .style = .{ .size = 24, .color = t.on_surface } })) catch {};
    const options = a.dupe(SourceMenu.Option, &.{
        .labeled(.official, locale.text("Official store")),
        .labeled(.custom, locale.text("Custom")),
    }) catch &.{};
    rows.append(a, sourceRow(cx, locale.text("Source"), cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{cx.make(SourceMenu{
        .options = options,
        .value = state.source_kind,
        .on_changed = if (self.actions != null) .of(state, State.chooseSource) else null,
    })}) catch &.{} }))) catch {};
    const on_apply: ?kete.Callback = if (self.actions != null) .of(state, State.applySource) else null;
    const id: u64 = @as(u64, state.source_form_id) * 2;
    // The official store's: shown as it is (all of it on hover).
    const url_field = cx.make(kete.TextField{
        .placeholder = "https://example.com/dazzle",
        .initial = if (custom) state.server_url.text() else state.official_now,
        .max_len = state.server_url.buf.len,
        .size = 16,
        .width = std.math.inf(f32),
        .enabled = custom,
        .on_changed = .of(state, State.setServerUrl),
        .on_submit = on_apply,
    }).withKey(id);
    rows.append(a, sourceRow(cx, locale.text("URL"), if (custom) url_field else cx.make(kete.Tooltip{ .text = state.official_now, .child = url_field }))) catch {};
    if (state.server_invalid) rows.append(a, cx.make(kete.Text{ .text = locale.text("Give an https:// URL"), .style = .{ .size = 15, .color = t.@"error" } })) catch {};
    const key_field = cx.make(kete.TextField{
        .placeholder = locale.text("Ed25519 public key (64 hex characters)"),
        .initial = if (custom) state.key_input.text() else state.official_key_now,
        .max_len = store.key_hex_len,
        .size = 16,
        .width = std.math.inf(f32),
        .enabled = custom,
        .emoji = false,
        .on_changed = .of(state, State.setKeyInput),
        .on_submit = on_apply,
    }).withKey(id + 1);
    rows.append(a, sourceRow(cx, locale.text("Key"), if (custom) key_field else cx.make(kete.Tooltip{ .text = state.official_key_now, .child = key_field }))) catch {};
    if (state.key_invalid) rows.append(a, cx.make(kete.Text{ .text = locale.text("Give a 64-character hex Ed25519 public key"), .style = .{ .size = 15, .color = t.@"error" } })) catch {};
    if (custom) rows.append(a, cx.make(kete.Row{ .main_axis_alignment = .end, .children = a.dupe(kete.Widget, &.{
        cx.make(kete.FilledButton{ .label = locale.text("Apply"), .on_press = on_apply }),
    }) catch &.{} })) catch {};
}

/// A row of the source page: its name, then `value`.
fn sourceRow(cx: *kete.BuildContext, name: []const u8, value: kete.Widget) kete.Widget {
    const t = &cx.ui.theme;
    return cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = cx.arena.dupe(kete.Widget, &.{
        cx.make(kete.SizedBox{ .width = 80, .child = cx.make(kete.Text{ .text = name, .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
        cx.make(kete.Expanded{ .child = value }),
    }) catch &.{} });
}

/// `what` (under way), and how much it has downloaded: "Installing… 1.2
/// MB of 3.4 MB", or (the total not known) "Getting the list of apps…
/// 340 KB"; `what` alone until anything has come.
fn withTransfer(cx: *kete.BuildContext, what: []const u8, tr: store.Transfer) []const u8 {
    if (tr.done == 0) return what;
    var done_buf: [32]u8 = undefined;
    const done = info.formatBytes(&done_buf, tr.done);
    if (tr.total == 0) return cx.fmt("{s} {s}", .{ what, done });
    var total_buf: [32]u8 = undefined;
    return cx.fmt("{s} {s}", .{ what, kete_vc4.textf(cx, "{s} of {s}", .{ done, info.formatBytes(&total_buf, @max(tr.total, tr.done)) }) });
}

/// `rows` (an item's name and what it says), and under them, while it
/// downloads something of a known size, a bar of how far it has got.
fn withBar(cx: *kete.BuildContext, rows: []const kete.Widget, tr: ?store.Transfer) []const kete.Widget {
    const a = cx.arena;
    const t = tr orelse return a.dupe(kete.Widget, rows) catch &.{};
    if (t.total == 0) return a.dupe(kete.Widget, rows) catch &.{};
    const k: f32 = @floatCast(@min(1, @as(f64, @floatFromInt(t.done)) / @as(f64, @floatFromInt(t.total))));
    var out = a.alloc(kete.Widget, rows.len + 1) catch return rows;
    @memcpy(out[0..rows.len], rows);
    out[rows.len] = cx.make(kete.Padding{ .padding = .{ .top = 4 }, .child = cx.make(kete.ProgressBar{ .value = k }) });
    return out;
}

/// Renders a 64x64 PNG icon, or the fallback `.apps` icon when no icon
/// can be found.
fn softwareIcon(cx: *kete.BuildContext, image: ?*const gfx.Image) kete.Widget {
    const t = &cx.ui.theme;
    if (image) |img| {
        return cx.make(kete.SizedBox{ .width = 64, .height = 64, .child = cx.make(kete.Image{ .source = .{ .image = img } }) });
    }
    return cx.make(kete.SizedBox{ .width = 64, .height = 64, .child = cx.make(kete.Align{ .child = cx.make(kete.Icon{ .icon = .apps, .size = 48, .color = t.on_surface_variant }) }) });
}

/// The screenshot of the app whose page is shown, decoded from
/// `store.screenshots_dir` when it is first wanted (and again after the
/// catalogue is got, as it may have changed).
pub const Screenshots = struct {
    gpa: std.mem.Allocator,
    dir: []const u8 = store.screenshots_dir,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    tried: bool = false,
    decoded: ?gfx.png.Decoded = null,
    image: gfx.Image = undefined,

    pub fn init(gpa: std.mem.Allocator) Screenshots {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Screenshots) void {
        if (s.decoded) |d| s.gpa.free(d.pixels);
        s.decoded = null;
        s.tried = false;
    }

    /// `name`'s screenshot, if it has one that can be read.
    pub fn get(s: *Screenshots, name: []const u8) ?*const gfx.Image {
        if (!s.tried or !std.mem.eql(u8, s.name_buf[0..s.name_len], name)) {
            s.deinit();
            s.tried = true;
            s.name_len = @min(name.len, s.name_buf.len);
            @memcpy(s.name_buf[0..s.name_len], name[0..s.name_len]);
            var path_buf: [256]u8 = undefined;
            const path = std.mem.printSentinel(&path_buf, "{s}/{s}.png", .{ s.dir, name }, 0) catch return null;
            const bytes = sys_mod.readFileAlloc(s.gpa, path, store.max_screenshot) catch return null;
            defer s.gpa.free(bytes);
            const d = gfx.png.decode(s.gpa, bytes) catch return null;
            s.decoded = d;
            s.image = .init(d.pixels, d.width, d.height);
        }
        return if (s.decoded != null) &s.image else null;
    }
};

pub const max_icons = 64;

/// Decoded 64x64 PNG icons for Dazzle and the catalogue's apps, loaded
/// with priority: installed icon on disk when up to date, then the server
/// icon when uninstalled, missing on disk or a newer version is available,
/// then null (showing the fallback icon).
pub const IconSet = struct {
    gpa: std.mem.Allocator,
    os_decoded: ?gfx.png.Decoded = null,
    os_image: ?gfx.Image = null,
    app_decoded: [max_icons]?gfx.png.Decoded = @splat(null),
    app_images: [max_icons]gfx.Image = undefined,
    app_ptrs: [max_icons]?*const gfx.Image = @splat(null),

    pub fn init(gpa: std.mem.Allocator) IconSet {
        return .{ .gpa = gpa };
    }

    pub fn deinit(set: *IconSet) void {
        if (set.os_decoded) |d| set.gpa.free(d.pixels);
        set.os_decoded = null;
        set.os_image = null;
        for (&set.app_decoded, &set.app_ptrs) |*d, *p| {
            if (d.*) |img| set.gpa.free(img.pixels);
            d.* = null;
            p.* = null;
        }
    }

    pub fn reload(
        set: *IconSet,
        os_installed_path: [:0]const u8,
        os_server_path: [:0]const u8,
        os_newer: bool,
        apps_dir: []const u8,
        icons_dir: []const u8,
        apps: []const store.App,
    ) void {
        set.deinit();
        if (loadOsIcon(set.gpa, os_installed_path, os_server_path, os_newer)) |dec| {
            set.os_decoded = dec;
            set.os_image = .init(dec.pixels, dec.width, dec.height);
        }
        const count = @min(apps.len, max_icons);
        for (apps[0..count], 0..) |app, i| {
            if (loadAppIcon(set.gpa, apps_dir, icons_dir, app)) |dec| {
                set.app_decoded[i] = dec;
                set.app_images[i] = .init(dec.pixels, dec.width, dec.height);
                set.app_ptrs[i] = &set.app_images[i];
            }
        }
    }

    pub fn osIcon(set: *const IconSet) ?*const gfx.Image {
        return if (set.os_image) |*img| img else null;
    }

    pub fn appIcons(set: *const IconSet, len: usize) []const ?*const gfx.Image {
        return set.app_ptrs[0..@min(len, max_icons)];
    }
};

fn decodeIconFile(gpa: std.mem.Allocator, path: [*:0]const u8) ?gfx.png.Decoded {
    const bytes = sys_mod.readFileAlloc(gpa, path, 256 * 1024) catch return null;
    defer gpa.free(bytes);
    const decoded = gfx.png.decode(gpa, bytes) catch return null;
    if (decoded.width != store.icon_size or decoded.height != store.icon_size) {
        gpa.free(decoded.pixels);
        return null;
    }
    return decoded;
}

fn loadOsIcon(gpa: std.mem.Allocator, installed_path: [:0]const u8, server_path: [:0]const u8, newer_available: bool) ?gfx.png.Decoded {
    const first = if (newer_available) server_path else installed_path;
    const second = if (newer_available) installed_path else server_path;
    return decodeIconFile(gpa, first) orelse decodeIconFile(gpa, second);
}

fn loadAppIcon(gpa: std.mem.Allocator, dir: []const u8, icons_path: []const u8, app: store.App) ?gfx.png.Decoded {
    var installed_buf: [256]u8 = undefined;
    var server_buf: [256]u8 = undefined;
    const installed_path = std.mem.printSentinel(&installed_buf, "{s}/{s}/icon.png", .{ dir, app.name }, 0) catch null;
    const server_path = std.mem.printSentinel(&server_buf, "{s}/{s}.png", .{ icons_path, app.name }, 0) catch null;
    const installed = store.isInstalled(dir, app.name);
    const use_installed_first = installed and !store.hasNewerVersion(dir, app);
    if (use_installed_first) {
        if (installed_path) |p| if (decodeIconFile(gpa, p)) |img| return img;
    }
    if (server_path) |p| if (decodeIconFile(gpa, p)) |img| return img;
    if (!use_installed_first and installed) {
        if (installed_path) |p| if (decodeIconFile(gpa, p)) |img| return img;
    }
    return null;
}

const testing = std.testing;
const font = kete.font;

test "installing and removing apps, and getting their list again" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .apps = view.sample_apps };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "All apps updated") != null);
    try testing.expect(view.findText(u.root.?, "Update all") == null);
    // Installed: Demo (and Dazzle), not Files; no buttons in the list.
    try testing.expect(view.findText(u.root.?, "Demo") != null and view.findText(u.root.?, "Files") == null);
    try testing.expect(view.findText(u.root.?, "Install") == null);
    // Available: Files, found by searching; its page has Install.
    view.click(u, view.findText(u.root.?, "Available").?);
    u.frame(1920, 960, 2, settings);
    const st = &u.root.?.state(Settings.State).software;
    st.setQuery("demo");
    u.frame(1920, 960, 3, settings);
    try testing.expect(view.findText(u.root.?, "Files") == null and view.findText(u.root.?, "No app matches") != null);
    st.setQuery("your");
    u.frame(1920, 960, 4, settings);
    view.click(u, view.up(view.findText(u.root.?, "Files").?, kete.Pressable).?);
    u.frame(1920, 960, 5, settings);
    view.click(u, view.up(view.findText(u.root.?, "Install").?, kete.FilledButton).?);
    try testing.expectEqualStrings("dazzle-files", actions.install.?.slice());
    // Back, to the list; Installed, Demo's page, Remove.
    view.click(u, view.up(view.findText(u.root.?, "Back").?, kete.TextButton).?);
    u.frame(1920, 960, 6, settings);
    view.click(u, view.findText(u.root.?, "Installed").?);
    u.frame(1920, 960, 7, settings);
    view.click(u, view.up(view.findText(u.root.?, "Demo").?, kete.Pressable).?);
    u.frame(1920, 960, 8, settings);
    view.click(u, view.up(view.findText(u.root.?, "Remove").?, kete.OutlinedButton).?);
    try testing.expectEqualStrings("dazzle-demo", actions.remove.?.slice());
    view.click(u, view.up(view.findText(u.root.?, "Refresh").?, kete.OutlinedButton).?);
    try testing.expect(actions.refresh_apps);

    // While one installs: a spinner in its place, and nothing else can be
    // pressed.
    actions = .{};
    settings.apps.busy = "dazzle-files";
    u.frame(1920, 960, 9, settings);
    try testing.expect(view.findText(u.root.?, "Installing…") != null);
    view.click(u, view.up(view.findText(u.root.?, "Remove").?, kete.OutlinedButton).?);
    try testing.expect(actions.remove == null);
    view.click(u, view.up(view.findText(u.root.?, "Back").?, kete.TextButton).?);

    // An install error shows in a dismissible snackbar.
    settings.apps = view.sample_apps;
    settings.apps.message = "Cannot install Files: the server could not be reached (is the network up?)";
    u.frame(1920, 960, 3, settings);
    const snack = view.findType(u.root.?, kete.Snackbar).?;
    try testing.expect(view.findText(snack, "Cannot install Files: the server could not be reached (is the network up?)") != null);
    view.click(u, view.findType(snack, kete.IconButton).?);
    u.frame(1920, 960, 4, settings);
    try testing.expect(view.findText(u.root.?, "Cannot install Files: the server could not be reached (is the network up?)") == null);

    // No list yet: labelled at the bottom, not in a snackbar.
    settings.apps = .{ .message = "Cannot get the list of apps: the server could not be reached (is the network up?)" };
    u.frame(1920, 960, 5, settings);
    try testing.expect(view.findText(u.root.?, "No list of apps yet: is the network up?") != null);
    try testing.expect(view.findText(u.root.?, "Cannot get the list of apps: the server could not be reached (is the network up?)") == null);
}

test "an installed app the catalogue no longer offers is listed, and can be removed" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    // The catalogue offers Files; Kete Demo is installed, and not offered.
    const list = [_]store.App{
        .{ .name = "dazzle-files", .title = "Files", .file = "dazzle-files.tar.xz", .size = 1000, .sha256 = "" },
        .{ .name = "dazzle-kete-demo", .title = "Kete Demo", .file = "", .size = 0, .sha256 = "" },
    };
    const settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .apps = .{
        .list = &list,
        .offered = 1,
        .installed = &.{ false, true },
        .updatable = &.{ false, false },
    } };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "Kete Demo") != null);
    try testing.expect(view.findText(u.root.?, "Installed, and no longer offered") != null);
    view.click(u, view.up(view.findText(u.root.?, "Kete Demo").?, kete.Pressable).?);
    u.frame(1920, 960, 2, settings);
    view.click(u, view.up(view.findText(u.root.?, "Remove").?, kete.OutlinedButton).?);
    try testing.expectEqualStrings("dazzle-kete-demo", actions.remove.?.slice());
}

test "updates: offered, downloaded, installed, then a restart" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "de14aa2 (7 October 2026)", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .apps = view.sample_apps, .update = .{ .status = .available, .available = "0123abc (8 October 2026)", .size = 4 << 20 } };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "Dazzle 0123abc (8 October 2026) is available · 4.0 MB") != null);
    try testing.expect(view.findText(u.root.?, "1 update available") != null);
    // "Update all" is to the left of "Refresh".
    const update_all_btn = view.up(view.findText(u.root.?, "Update all").?, kete.OutlinedButton).?;
    const refresh_btn = view.up(view.findText(u.root.?, "Refresh").?, kete.OutlinedButton).?;
    try testing.expect(update_all_btn.position()[0] < refresh_btn.position()[0]);
    view.click(u, update_all_btn);
    try testing.expect(actions.update_all);
    actions = .{};

    // With both an OS update and an app update: "2 updates available".
    settings.apps.updatable = &.{ true, false };
    u.frame(1920, 960, 2, settings);
    try testing.expect(view.findText(u.root.?, "2 updates available") != null);
    // An app with an update says so, and its page has Update, and Remove
    // to its right.
    try testing.expect(view.findText(u.root.?, "Update available") != null);
    view.click(u, view.up(view.findText(u.root.?, "Demo").?, kete.Pressable).?);
    u.frame(1920, 960, 20, settings);
    const app_update = view.up(view.findText(u.root.?, "Update").?, kete.FilledButton).?;
    const app_remove = view.up(view.findText(u.root.?, "Remove").?, kete.OutlinedButton).?;
    try testing.expect(app_remove.position()[0] > app_update.position()[0]);
    view.click(u, app_update);
    try testing.expectEqualStrings("dazzle-demo", actions.install.?.slice());
    actions = .{};
    view.click(u, view.up(view.findText(u.root.?, "Back").?, kete.TextButton).?);
    u.frame(1920, 960, 21, settings);

    // Dazzle is listed as an app is (no buttons in the list); its page has
    // its build and kernel, and Update.
    try testing.expect(view.findText(u.root.?, "de14aa2 (7 October 2026)") == null);
    try testing.expect(view.findText(u.root.?, "Update") == null);
    view.click(u, view.up(view.findText(u.root.?, "Dazzle").?, kete.Pressable).?);
    u.frame(1920, 960, 3, settings);
    try testing.expect(view.findText(u.root.?, "de14aa2 (7 October 2026)") != null);
    try testing.expect(view.findText(u.root.?, "6.12.0 (armv6l)") != null);
    try testing.expect(view.findText(u.root.?, "Dazzle 0123abc (8 October 2026) is available · 4.0 MB") != null);
    view.click(u, view.up(view.findText(u.root.?, "Update").?, kete.FilledButton).?);
    try testing.expect(actions.download_update);

    // Under way: no update buttons on its page.
    settings.apps.updatable = &.{};
    for ([_]update.Status{ .checking, .downloading, .installing }) |s| {
        settings.update = .{ .status = s };
        u.frame(1920, 960, 4, settings);
        try testing.expect(view.findText(u.root.?, "Dazzle") != null);
        try testing.expect(view.findText(u.root.?, "Update") == null and view.findText(u.root.?, "Restart") == null);
    }
    settings.update = .{ .status = .ready };
    u.frame(1920, 960, 5, settings);
    try testing.expect(view.findText(u.root.?, "The update is installed: restart to use it") != null);
    view.click(u, view.up(view.findText(u.root.?, "Restart").?, kete.FilledButton).?);
    try testing.expect(actions.restart);
    // Back to the list.
    view.click(u, view.up(view.findText(u.root.?, "Back").?, kete.TextButton).?);
    u.frame(1920, 960, 51, settings);
    try testing.expect(view.findText(u.root.?, "Back") == null);
    try testing.expect(view.findText(u.root.?, "de14aa2 (7 October 2026)") == null);

    settings.update = .{ .status = .current };
    u.frame(1920, 960, 6, settings);
    try testing.expect(view.findText(u.root.?, "The operating system · 600 KB") != null);
    try testing.expect(view.findText(u.root.?, "All apps updated") != null);
    try testing.expect(view.findText(u.root.?, "Update all") == null);
    view.click(u, view.up(view.findText(u.root.?, "Refresh").?, kete.OutlinedButton).?);
    try testing.expect(actions.check_update and actions.refresh_apps);

    settings.update = .{ .status = .unknown, .message = "Cannot check for updates: the server could not be reached (is the network up?)" };
    u.frame(1920, 960, 7, settings);
    try testing.expect(view.findText(u.root.?, "Cannot check for updates: the server could not be reached (is the network up?)") != null);
    settings.update = .{};
    u.frame(1920, 960, 8, settings);
    try testing.expect(view.findText(u.root.?, "The operating system · 600 KB") != null);
}

test "what downloads shows how far it has got: a bar when its size is known, the amount when not" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .apps = view.sample_apps };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;

    // The list being got: its size not known, so a spinner and how much.
    settings.apps.busy = "";
    settings.apps.transfer = .{ .done = 340 * 1024 };
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findTextContaining(u.root.?, "Getting the list of apps… 340") != null);
    try testing.expect(view.findType(u.root.?, kete.Spinner) != null);
    try testing.expect(view.findType(u.root.?, kete.ProgressBar) == null);

    // An app being installed: on its row, how much of all of it, and a bar.
    settings.apps.busy = "dazzle-demo";
    settings.apps.transfer = .{ .done = 1 << 20, .total = 4 << 20 };
    u.frame(1920, 960, 2, settings);
    try testing.expect(view.findText(u.root.?, "Installing… 1.0 MB of 4.0 MB") != null);
    try testing.expectApproxEqAbs(@as(f32, 0.25), view.findType(u.root.?, kete.ProgressBar).?.widget.as(kete.ProgressBar).?.value.?, 0.001);

    // Dazzle's update downloading: the same, on its row.
    settings.apps.busy = null;
    settings.apps.transfer = .{};
    settings.update = .{ .status = .downloading, .transfer = .{ .done = 3 << 20, .total = 12 << 20 } };
    u.frame(1920, 960, 3, settings);
    try testing.expect(view.findText(u.root.?, "Downloading the update… 3.0 MB of 12 MB") != null);
    try testing.expectApproxEqAbs(@as(f32, 0.25), view.findType(u.root.?, kete.ProgressBar).?.widget.as(kete.ProgressBar).?.value.?, 0.001);
    try testing.expect(!view.overflows(u.root.?));
}

test "software icons: installed when up to date, server when uninstalled, missing on disk or newer available, else fallback" {
    const linux = std.os.linux;
    var dir_buf: [64]u8 = undefined;
    const root = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-icons-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(root, 0o755);
    defer sys_mod.files.removeTree(root);

    var os_dir_buf: [96]u8 = undefined;
    var apps_dir_buf: [96]u8 = undefined;
    var icons_dir_buf: [96]u8 = undefined;
    const os_dir = try std.mem.printSentinel(&os_dir_buf, "{s}/os", .{root}, 0);
    const apps_dir = try std.mem.printSentinel(&apps_dir_buf, "{s}/apps", .{root}, 0);
    const icons_dir = try std.mem.printSentinel(&icons_dir_buf, "{s}/apps/.icons", .{root}, 0);
    _ = linux.mkdir(os_dir, 0o755);
    _ = linux.mkdir(apps_dir, 0o755);
    _ = linux.mkdir(icons_dir, 0o755);

    const makePng = struct {
        fn write(gpa: std.mem.Allocator, path: [:0]const u8, argb: u32) !void {
            var pixels: [64 * 64]u32 = undefined;
            @memset(&pixels, argb);
            const png = try gfx.png.encodeRgba(gpa, &pixels, 64, 64);
            defer gpa.free(png);
            try sys_mod.files.writeNew(path, png);
        }
    }.write;

    var os_installed_buf: [128]u8 = undefined;
    var os_server_buf: [128]u8 = undefined;
    const os_installed = try std.mem.printSentinel(&os_installed_buf, "{s}/icon.png", .{os_dir}, 0);
    const os_server = try std.mem.printSentinel(&os_server_buf, "{s}/server-os-icon.png", .{os_dir}, 0);
    try makePng(testing.allocator, os_installed, 0xff112233);
    try makePng(testing.allocator, os_server, 0xffaabbcc);

    // Installed app "dazzle-demo" at version 1000 abc, with an installed icon (0x10) and server icon (0x20).
    var path_buf: [160]u8 = undefined;
    _ = linux.mkdir(try std.mem.printSentinel(&path_buf, "{s}/dazzle-demo", .{apps_dir}, 0), 0o755);
    const demo_bin = try std.mem.printSentinel(&path_buf, "{s}/dazzle-demo/dazzle-demo", .{apps_dir}, 0);
    try sys_mod.files.writeNew(demo_bin, "bin");
    _ = linux.chmod(demo_bin, 0o755);
    try sys_mod.files.writeNew(try std.mem.printSentinel(&path_buf, "{s}/dazzle-demo/version", .{apps_dir}, 0), "1000 abc\n");
    try makePng(testing.allocator, try std.mem.printSentinel(&path_buf, "{s}/dazzle-demo/icon.png", .{apps_dir}, 0), 0xff100000);
    try makePng(testing.allocator, try std.mem.printSentinel(&path_buf, "{s}/dazzle-demo.png", .{icons_dir}, 0), 0xff200000);

    // Installed app "dazzle-files" with NO icon on disk, only a server icon (0x30).
    _ = linux.mkdir(try std.mem.printSentinel(&path_buf, "{s}/dazzle-files", .{apps_dir}, 0), 0o755);
    const files_bin = try std.mem.printSentinel(&path_buf, "{s}/dazzle-files/dazzle-files", .{apps_dir}, 0);
    try sys_mod.files.writeNew(files_bin, "bin");
    _ = linux.chmod(files_bin, 0o755);
    try makePng(testing.allocator, try std.mem.printSentinel(&path_buf, "{s}/dazzle-files.png", .{icons_dir}, 0), 0xff300000);

    // Uninstalled app "dazzle-camera" with a server icon (0x40), and "dazzle-maps" with NO icon anywhere.
    try makePng(testing.allocator, try std.mem.printSentinel(&path_buf, "{s}/dazzle-camera.png", .{icons_dir}, 0), 0xff400000);

    var list = [_]store.App{
        .{ .name = "dazzle-demo", .title = "Demo", .version = "abc", .time = 1000, .icon = "dazzle-demo.png", .file = "dazzle-demo.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-files", .title = "Files", .version = "abc", .time = 1000, .icon = "dazzle-files.png", .file = "dazzle-files.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-camera", .title = "Camera", .version = "abc", .time = 1000, .icon = "dazzle-camera.png", .file = "dazzle-camera.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-maps", .title = "Maps", .version = "abc", .time = 1000, .icon = "dazzle-maps.png", .file = "dazzle-maps.tar.xz", .size = 1, .sha256 = "" },
    };

    var icons: IconSet = .init(testing.allocator);
    defer icons.deinit();

    // Up to date: OS uses installed icon (0x11); Demo uses installed icon (0x10);
    // Files (no disk icon) uses server icon (0x30); Camera (uninstalled) uses server icon (0x40);
    // Maps (no icon anywhere) is null (fallback icon).
    icons.reload(os_installed, os_server, false, apps_dir, icons_dir, &list);
    try testing.expectEqual(@as(u32, 0xff112233), icons.osIcon().?.pixels[0]);
    const got1 = icons.appIcons(list.len);
    try testing.expectEqual(@as(u32, 0xff100000), got1[0].?.pixels[0]);
    try testing.expectEqual(@as(u32, 0xff300000), got1[1].?.pixels[0]);
    try testing.expectEqual(@as(u32, 0xff400000), got1[2].?.pixels[0]);
    try testing.expect(got1[3] == null);

    // Newer version available for OS and Demo: both switch to the server icon!
    list[0].version = "def";
    list[0].time = 2000;
    icons.reload(os_installed, os_server, true, apps_dir, icons_dir, &list);
    try testing.expectEqual(@as(u32, 0xffaabbcc), icons.osIcon().?.pixels[0]);
    const got2 = icons.appIcons(list.len);
    try testing.expectEqual(@as(u32, 0xff200000), got2[0].?.pixels[0]);
}

test "the software list scrolls vertically while the bottom bar stays visible" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    const many_apps = [_]store.App{
        .{ .name = "app-1", .title = "App 1", .description = "First app", .file = "a1.tar.xz", .size = 10 << 10, .sha256 = "" },
        .{ .name = "app-2", .title = "App 2", .description = "Second app", .file = "a2.tar.xz", .size = 10 << 10, .sha256 = "" },
        .{ .name = "app-3", .title = "App 3", .description = "Third app", .file = "a3.tar.xz", .size = 10 << 10, .sha256 = "" },
        .{ .name = "app-4", .title = "App 4", .description = "Fourth app", .file = "a4.tar.xz", .size = 10 << 10, .sha256 = "" },
        .{ .name = "app-5", .title = "App 5", .description = "Fifth app", .file = "a5.tar.xz", .size = 10 << 10, .sha256 = "" },
        .{ .name = "app-6", .title = "App 6", .description = "Sixth app", .file = "a6.tar.xz", .size = 10 << 10, .sha256 = "" },
        .{ .name = "app-7", .title = "App 7", .description = "Seventh app", .file = "a7.tar.xz", .size = 10 << 10, .sha256 = "" },
        .{ .name = "app-8", .title = "App 8", .description = "Eighth app", .file = "a8.tar.xz", .size = 10 << 10, .sha256 = "" },
    };
    const settings: Settings = .{
        .commit = "574d538",
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .apps = .{ .list = &many_apps, .installed = &.{ true, true, true, true, true, true, true, true } },
    };
    u.frame(view.min_size[0], view.min_size[1], 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(view.min_size[0], view.min_size[1], 1, settings);

    const status_before = view.findText(u.root.?, "All apps updated").?.position()[1];
    const refresh_before = view.findText(u.root.?, "Refresh").?.position()[1];
    const dazzle_before = view.findText(u.root.?, "Dazzle").?.position()[1];

    // Scroll the list down with the mouse wheel over the Software list.
    u.pointerScroll(.{ 400, 200 }, 0, 50);
    u.frame(view.min_size[0], view.min_size[1], 2, settings);

    const status_after = view.findText(u.root.?, "All apps updated").?.position()[1];
    const refresh_after = view.findText(u.root.?, "Refresh").?.position()[1];
    const dazzle_after = view.findText(u.root.?, "Dazzle").?.position()[1];

    // The list scrolled up, while the bottom status and Refresh button did not move.
    try testing.expect(dazzle_after < dazzle_before);
    try testing.expectEqual(status_before, status_after);
    try testing.expectEqual(refresh_before, refresh_after);
    try testing.expect(status_after + 20 <= @as(f32, @floatFromInt(view.min_size[1])));
}

test "where software comes from: the official store, or a custom server and its key" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic("test-settings-key-seed-000000001".*);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    var settings: Settings = .{
        .commit = "x",
        .actions = &actions,
        .system = &d.sys,
        .usage = d.usage,
        .network = &d.net,
        .apps = view.sample_apps,
    };
    var frame_no: u64 = 0;
    const draw = struct {
        fn call(uu: *kete.ui.WindowUi, s: Settings, n: *u64) void {
            n.* += 1;
            uu.frame(1920, 960, n.*, s);
        }
    }.call;
    const Fields = struct {
        fn at(root: *kete.WidgetNode, k: usize) *kete.WidgetNode {
            var fields: std.ArrayList(*kete.WidgetNode) = .empty;
            defer fields.deinit(testing.allocator);
            view.findAllType(root, kete.TextField, &fields);
            return fields.items[k];
        }
        fn text(root: *kete.WidgetNode, k: usize) []const u8 {
            return at(root, k).state(kete.TextField.State).text();
        }
        fn enabled(root: *kete.WidgetNode, k: usize) bool {
            return at(root, k).widget.as(kete.TextField).?.enabled;
        }
    };

    draw(u, settings, &frame_no);
    u.root.?.state(Settings.State).page = .apps;
    draw(u, settings, &frame_no);
    // The gear opens the page: the official store, its URL and key shown,
    // not to be changed.
    view.click(u, view.up(view.findIcon(u.root.?, .settings).?, kete.IconButton).?);
    draw(u, settings, &frame_no);
    try testing.expect(view.findText(u.root.?, "Software source") != null);
    try testing.expect(view.findText(u.root.?, "Source") != null and view.findText(u.root.?, "URL") != null and view.findText(u.root.?, "Key") != null);
    try testing.expect(view.findText(u.root.?, "Official store") != null);
    try testing.expectEqualStrings(settings.apps.default_source, Fields.text(u.root.?, 0));
    try testing.expectEqualStrings(store.default_signing_key, Fields.text(u.root.?, 1));
    try testing.expect(!Fields.enabled(u.root.?, 0) and !Fields.enabled(u.root.?, 1));
    try testing.expect(view.findText(u.root.?, "Apply") == null);
    try testing.expect(!view.overflows(u.root.?));

    // Custom: the URL and key can be given, and applied.
    var st = &u.root.?.state(Settings.State).software;
    st.chooseSource(.custom);
    draw(u, settings, &frame_no);
    try testing.expectEqualStrings("https://", Fields.text(u.root.?, 0));
    try testing.expectEqualStrings("", Fields.text(u.root.?, 1));
    try testing.expect(Fields.enabled(u.root.?, 0) and Fields.enabled(u.root.?, 1));
    try testing.expect(actions.software_server == null and actions.software_key == null);
    // Not an https:// URL, or not a key: said so, nothing changed.
    st.server_url.set("http://staging.example.com/dazzle");
    st.key_input.set("not-a-valid-key");
    view.click(u, view.findText(u.root.?, "Apply").?);
    draw(u, settings, &frame_no);
    try testing.expect(actions.software_server == null and actions.software_key == null);
    try testing.expect(view.findText(u.root.?, "Give an https:// URL") != null);
    try testing.expect(view.findText(u.root.?, "Give a 64-character hex Ed25519 public key") != null);
    // Right: applied (the URL without its last slash), and back to the list.
    st = &u.root.?.state(Settings.State).software;
    st.server_url.set("https://staging.example.com/dazzle/");
    st.key_input.set(&pub_hex);
    view.click(u, view.findText(u.root.?, "Apply").?);
    try testing.expectEqualStrings("https://staging.example.com/dazzle", actions.software_server.?.slice());
    try testing.expectEqualStrings(&pub_hex, actions.software_key.?.slice());
    draw(u, settings, &frame_no);
    try testing.expect(view.findText(u.root.?, "Software source") == null);
    actions = .{};

    // Opened again, using it: Custom, with its URL and key.
    settings.apps.source = "https://staging.example.com/dazzle";
    const keys = [_][store.key_hex_len]u8{pub_hex};
    settings.apps.subscribed_keys = &keys;
    draw(u, settings, &frame_no);
    view.click(u, view.up(view.findIcon(u.root.?, .settings).?, kete.IconButton).?);
    draw(u, settings, &frame_no);
    try testing.expect(view.findText(u.root.?, "Custom") != null);
    try testing.expectEqualStrings("https://staging.example.com/dazzle", Fields.text(u.root.?, 0));
    try testing.expectEqualStrings(&pub_hex, Fields.text(u.root.?, 1));
    try testing.expect(!view.overflows(u.root.?));
    // The official store again: at once, with the built-in key alone.
    st = &u.root.?.state(Settings.State).software;
    st.chooseSource(.official);
    try testing.expectEqualStrings("", actions.software_server.?.slice());
    try testing.expectEqualStrings("", actions.software_key.?.slice());
}

test "an app's screenshot is decoded when its page is shown, and only once" {
    const linux = std.os.linux;
    var dir_buf: [64]u8 = undefined;
    const root = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-shots-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(root, 0o755);
    defer sys_mod.files.removeTree(root);
    var pixels: [8 * 4]u32 = undefined;
    @memset(&pixels, 0xff336699);
    const png = try gfx.png.encodeRgba(testing.allocator, &pixels, 8, 4);
    defer testing.allocator.free(png);
    var path_buf: [128]u8 = undefined;
    try sys_mod.files.writeNew(try std.mem.printSentinel(&path_buf, "{s}/dazzle-demo.png", .{root}, 0), png);

    var shots: Screenshots = .init(testing.allocator);
    shots.dir = root;
    defer shots.deinit();
    const img = shots.get("dazzle-demo").?;
    try testing.expectEqual(@as(u32, 8), img.width);
    try testing.expectEqual(@as(u32, 4), img.height);
    // The same one again, as it was.
    try testing.expectEqual(img, shots.get("dazzle-demo").?);
    // One without a screenshot.
    try testing.expect(shots.get("dazzle-other") == null);
    try testing.expect(shots.get("dazzle-demo") != null);
}
