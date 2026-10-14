//! The Software page: Dazzle itself (with Update or Restart, and an
//! expander showing the build and kernel version) and the catalogue's
//! apps (with Install, Update or Remove beside each), in a scrollable
//! list above a fixed status bar with Update all and Refresh.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
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
pub const icon: ui.icons.Icon = .apps;

/// What the Software page shows of apps.
pub const Apps = struct {
    /// The catalogue's apps, whether each is installed, and whether each
    /// installed app has a newer version in the catalogue.
    list: []const store.App = &.{},
    installed: []const bool = &.{},
    updatable: []const bool = &.{},
    /// Each app's 64x64 icon (installed, or from the server when
    /// uninstalled, not on disk or a newer version is available); null
    /// for the fallback icon.
    icons: []const ?*const gfx.Image = &.{},
    /// The app being installed ("" for the list itself, "*" for updating
    /// all); null if nothing is under way.
    busy: ?[]const u8 = null,
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
    /// Dazzle's 64x64 icon (installed, or from the server when a newer
    /// version is available or none is on disk); null for the fallback icon.
    icon: ?*const gfx.Image = null,
};

const PageState = State;

pub const State = struct {
    /// Whether the Dazzle item on the Software page is expanded to show
    /// the build and kernel version.
    dazzle_expanded: bool = false,
    /// Whether the current error snackbar has been dismissed.
    dismissed: bool = false,
    last_message_buf: [160]u8 = undefined,
    last_message_len: u8 = 0,
    /// Whether the form for a custom software server URL is open in the
    /// popup, what is typed in it, and whether it was not an `https://` URL.
    custom_form: bool = false,
    form_filled: bool = false,
    form_id: u32 = 0,
    server_url: Field = .{},
    server_invalid: bool = false,
    /// What is typed in the new signing key field in the popup, and whether
    /// it was not a 64-character hex Ed25519 public key.
    key_form_id: u32 = 1000,
    key_input: Field = .{},
    key_invalid: bool = false,

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

    pub fn toggleDazzle(st: *State) void {
        st.dazzle_expanded = !st.dazzle_expanded;
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

pub fn build(self: *const Settings, b: Builder, state: *State) ui.Widget {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const apps = &self.apps;
    var rows: std.ArrayList(ui.Widget) = .empty;
    const a = cx.ui.arena();
    const os_busy = self.update.status == .checking or self.update.status == .downloading or self.update.status == .installing;
    const busy = apps.busy != null or os_busy;
    const err_msg = if (apps.message.len > 0 and !std.mem.startsWith(u8, apps.message, "Cannot get the list of apps"))
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
    dazzleRows(self, b, state, &rows);
    var updates: usize = @intFromBool(self.update.status == .available);
    for (apps.list, 0..) |app, i| {
        const installed = i < apps.installed.len and apps.installed[i];
        const updatable = installed and i < apps.updatable.len and apps.updatable[i];
        if (updatable) updates += 1;
        const this_busy = if (apps.busy) |n| std.mem.eql(u8, n, app.name) or (std.mem.eql(u8, n, "*") and updatable) else false;
        const enabled = self.actions != null and !busy;
        const x = if (self.actions) |acts| appAct(cx, acts, state, app.name) else null;
        const button: ui.Widget = if (this_busy)
            cx.make(ui.Spinner{ .size = 28 })
        else if (updatable)
            cx.make(ui.OutlinedButton{ .label = "Update", .icon = .download, .on_press = if (enabled) .of(x.?, AppAct.install) else null })
        else if (installed)
            cx.make(ui.OutlinedButton{ .icon = .delete, .destructive = true, .on_press = if (enabled) .of(x.?, AppAct.remove) else null })
        else
            cx.make(ui.OutlinedButton{ .label = "Install", .icon = .download, .on_press = if (enabled) .of(x.?, AppAct.install) else null });
        var size_buf: [32]u8 = undefined;
        const detail = if (app.description.len > 0)
            cx.fmt("{s} · {s}", .{ app.description, info.formatBytes(&size_buf, app.size) })
        else
            cx.fmt("{s}", .{info.formatBytes(&size_buf, app.size)});
        const app_icon: ?*const gfx.Image = if (i < apps.icons.len) apps.icons[i] else null;
        rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = &.{
            softwareIcon(cx, app_icon),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                cx.make(ui.Text{ .text = app.title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
                cx.make(ui.Text{ .text = detail, .style = .{ .size = 15, .color = t.on_surface_variant } }),
            } }) }),
            button,
        } })) catch {};
    }
    const status = if (apps.busy) |name|
        (if (name.len == 0) "Getting the list of apps…" else if (std.mem.eql(u8, name, "*")) "Updating…" else "Installing…")
    else if (self.update.status == .checking)
        "Checking for updates…"
    else if (self.update.status == .downloading or self.update.status == .installing)
        "Updating…"
    else if (updates == 1)
        "1 update available"
    else if (updates > 1)
        cx.fmt("{d} updates available", .{updates})
    else if (apps.list.len == 0)
        "No list of apps yet: is the network up?"
    else
        "All apps updated";
    var footer_children: std.ArrayList(ui.Widget) = .empty;
    footer_children.append(a, cx.make(ui.Expanded{ .child = b.value(status) })) catch {};
    if (updates > 0) {
        footer_children.append(a, cx.make(ui.OutlinedButton{
            .label = "Update all",
            .icon = .download,
            .on_press = if (self.actions != null and !busy) .of(appAct(cx, self.actions.?, state, ""), AppAct.updateAll) else null,
        })) catch {};
    }
    footer_children.append(a, cx.make(ui.OutlinedButton{
        .label = "Refresh",
        .icon = .refresh,
        .on_press = if (self.actions != null and !busy) .of(appAct(cx, self.actions.?, state, ""), AppAct.refresh) else null,
    })) catch {};
    footer_children.append(a, cx.make(ServerConfigButton{
        .state = state,
        .actions = if (!busy) self.actions else null,
        .source = if (apps.source.len > 0) apps.source else store.default_url,
        .default_source = if (apps.default_source.len > 0) apps.default_source else store.default_url,
        .default_key = if (apps.default_key.len > 0) apps.default_key else store.default_signing_key,
        .subscribed_keys = apps.subscribed_keys,
    })) catch {};
    const footer = cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = footer_children.items });
    return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
        cx.make(ui.Expanded{ .child = cx.make(ui.Snackbar{
            .message = snackbar_msg,
            .on_dismiss = .of(state, State.dismissMessage),
            .child = cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{
                .padding = .{ .left = 24, .top = 24, .right = 24, .bottom = 12 },
                .child = cx.make(ui.Align{
                    .alignment = .top_center,
                    .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = view.max_page_width }, .child = b.page(rows.items) }),
                }),
            }) }).withKey(@as(u64, @intFromEnum(Page.apps)) + 1),
        }) }),
        cx.make(ui.Padding{
            .padding = .{ .left = 24, .top = 12, .right = 24, .bottom = 24 },
            .child = cx.make(ui.Align{
                .alignment = .center,
                .height_factor = 1,
                .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = view.max_page_width }, .child = footer }),
            }),
        }),
    } });
}

fn downloadUpdate(a: *Actions) void {
    a.download_update = true;
}

fn restartNow(a: *Actions) void {
    a.restart = true;
}

/// Dazzle itself, at the head of the Software list: how updates stand
/// (with Update or Restart), and an expander showing the build and
/// kernel version.
fn dazzleRows(self: *const Settings, b: Builder, state: *State, rows: *std.ArrayList(ui.Widget)) void {
    const cx = b.cx;
    const t = &cx.ui.theme;
    const a = cx.ui.arena();
    const u = &self.update;
    var size_buf: [32]u8 = undefined;
    const detail = if (self.usage.storage.system > 0)
        cx.fmt("The operating system · {s}", .{info.formatBytes(&size_buf, self.usage.storage.system)})
    else
        "The operating system";
    const Button = struct { label: []const u8, icon: ui.icons.Icon, flag: enum { download, restart } };
    const available_text = if (u.message.len > 0)
        u.message
    else if (u.size > 0)
        cx.fmt("Dazzle {s} is available · {s}", .{ u.available, info.formatBytes(&size_buf, u.size) })
    else
        cx.fmt("Dazzle {s} is available", .{u.available});
    const text: []const u8, const button: ?Button, const busy = switch (u.status) {
        .unknown, .current => .{ if (u.message.len > 0) u.message else detail, null, false },
        .checking => .{ "Checking for updates…", null, true },
        .available => .{ available_text, Button{ .label = "Update", .icon = .download, .flag = .download }, false },
        .downloading => .{ "Downloading the update…", null, true },
        .installing => .{ "Installing the update…", null, true },
        .ready => .{ if (u.message.len > 0) u.message else "The update is installed: restart to use it", Button{ .label = "Restart", .icon = .restart_alt, .flag = .restart }, false },
    };
    const end: ui.Widget = if (busy) cx.make(ui.Spinner{ .size = 28 }) else if (button) |btn| cx.make(ui.OutlinedButton{
        .label = btn.label,
        .icon = btn.icon,
        .on_press = if (self.actions) |acts| switch (btn.flag) {
            .download => .of(acts, downloadUpdate),
            .restart => .of(acts, restartNow),
        } else null,
    }) else cx.make(ui.Empty{});
    const header = cx.make(ui.Pressable{
        .on_press = .of(state, State.toggleDazzle),
        .child = cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = &.{
            softwareIcon(cx, u.icon),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 4, .children = &.{
                    cx.make(ui.Text{ .text = "Dazzle", .style = .{ .size = 18, .color = t.on_surface }, .wrap = false }),
                    cx.make(ui.Icon{ .icon = if (state.dazzle_expanded) .expand_more else .chevron_right, .size = 20, .color = t.on_surface_variant }),
                } }),
                cx.make(ui.Text{ .text = text, .style = .{ .size = 15, .color = t.on_surface_variant } }),
            } }) }),
        } }),
    });
    rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = &.{
        cx.make(ui.Expanded{ .child = header }),
        end,
    } })) catch {};
    if (state.dazzle_expanded) {
        rows.append(a, cx.make(ui.Padding{ .padding = .{ .left = 80 }, .child = cx.make(ui.Column{
            .cross_axis_alignment = .stretch,
            .main_axis_size = .min,
            .spacing = 4,
            .children = &.{
                dazzleDetail(cx, "Build", self.commit),
                dazzleDetail(cx, "Linux", view.orUnknown(self.system.kernel.slice())),
            },
        }) })) catch {};
    }
}

fn dazzleDetail(cx: *ui.Context, name: []const u8, text: []const u8) ui.Widget {
    const t = &cx.ui.theme;
    return cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
        cx.make(ui.SizedBox{ .width = 80, .child = cx.make(ui.Text{ .text = name, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false }) }),
        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = text, .style = .{ .size = 15, .color = t.on_surface } }) }),
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

fn appAct(cx: *ui.Context, actions: *Actions, state: *State, name: []const u8) *AppAct {
    const x = cx.ui.arena().create(AppAct) catch unreachable;
    x.* = .{ .actions = actions, .state = state, .name = .init(name) };
    return x;
}

const KeyAct = struct {
    actions: *Actions,
    key: [store.key_hex_len]u8,

    fn unsubscribe(x: *KeyAct) void {
        x.actions.unsubscribe_key = .of(&x.key);
    }
};

fn keyAct(cx: *ui.Context, actions: *Actions, key: [store.key_hex_len]u8) *KeyAct {
    const x = cx.ui.arena().create(KeyAct) catch unreachable;
    x.* = .{ .actions = actions, .key = key };
    return x;
}

/// An icon button in the Software footer bar: pressing it opens a popup to
/// switch the software server between the default (`build_info.apps_url`)
/// and a custom `https://` URL, and to subscribe or remove Ed25519 signing keys.
pub const ServerConfigButton = struct {
    state: *PageState,
    actions: ?*Actions,
    source: []const u8,
    default_source: []const u8,
    default_key: []const u8 = store.default_signing_key,
    subscribed_keys: []const [store.key_hex_len]u8 = &.{},

    pub const State = BtnState;
    pub const BtnState = struct {
        node: ?*ui.Node = null,
        state: ?*PageState = null,
        actions: ?*Actions = null,
        source: []const u8 = store.default_url,
        default_source: []const u8 = store.default_url,
        default_key: []const u8 = store.default_signing_key,
        subscribed_keys: []const [store.key_hex_len]u8 = &.{},

        fn isCustom(st: *const BtnState) bool {
            return !std.mem.eql(u8, st.source, st.default_source);
        }

        fn open(st: *BtnState) void {
            const n = st.node orelse return;
            const page_st = st.state orelse return;
            page_st.server_invalid = false;
            page_st.key_invalid = false;
            page_st.custom_form = st.isCustom();
            if (!st.isCustom()) page_st.form_filled = false;
            const pos = n.position();
            n.ui.openPopup(n, .{ pos[0], pos[1] }, .of(st, BtnState.buildPopup));
        }

        fn chooseDefault(st: *BtnState) void {
            const page_st = st.state orelse return;
            page_st.custom_form = false;
            page_st.form_filled = false;
            page_st.server_invalid = false;
            if (st.isCustom()) if (st.actions) |acts| {
                acts.software_server = .{};
            };
        }

        fn chooseCustom(st: *BtnState) void {
            const page_st = st.state orelse return;
            page_st.custom_form = true;
        }

        fn apply(st: *BtnState) void {
            const page_st = st.state orelse return;
            const url = store.parseHttpsUrl(page_st.server_url.text()) orelse {
                page_st.server_invalid = true;
                return;
            };
            page_st.server_invalid = false;
            page_st.custom_form = false;
            if (st.actions) |acts| {
                acts.software_server = if (std.mem.eql(u8, url, st.default_source)) .{} else .of(url);
            }
            if (st.node) |n| n.ui.closeMenu();
        }

        fn subscribeKey(st: *BtnState) void {
            const page_st = st.state orelse return;
            var hex: [store.key_hex_len]u8 = undefined;
            _ = store.parsePublicKey(page_st.key_input.text(), &hex) orelse {
                page_st.key_invalid = true;
                return;
            };
            page_st.key_invalid = false;
            page_st.key_input.set("");
            page_st.key_form_id +%= 1;
            if (st.actions) |acts| {
                acts.subscribe_key = .of(&hex);
            }
        }

        fn buildPopup(st: *BtnState, cx: *ui.Context) ui.Widget {
            const page_st = st.state orelse return cx.make(ui.Empty{});
            const t = cx.theme();
            const a = cx.ui.arena();
            const custom = page_st.custom_form or st.isCustom();
            var rows: std.ArrayList(ui.Widget) = .empty;
            rows.append(a, cx.make(ui.Center{ .height_factor = 1, .child = cx.make(ui.PillBar{ .children = &.{
                cx.make(ui.PillButton{
                    .label = "Default",
                    .selected = !custom,
                    .first = true,
                    .last = false,
                    .on_press = if (st.actions != null) .of(st, BtnState.chooseDefault) else null,
                }),
                cx.make(ui.PillButton{
                    .label = "Custom",
                    .selected = custom,
                    .first = false,
                    .last = true,
                    .on_press = if (st.actions != null) .of(st, BtnState.chooseCustom) else null,
                }),
            } }) })) catch {};

            if (!custom) {
                rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                    cx.make(ui.SizedBox{ .width = 70, .child = cx.make(ui.Text{ .text = "Server", .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = st.default_source, .style = .{ .size = 16, .color = t.on_surface } }) }),
                } })) catch {};
            } else {
                if (!page_st.form_filled) {
                    page_st.form_filled = true;
                    page_st.form_id +%= 1;
                    page_st.server_invalid = false;
                    page_st.server_url.set(if (st.isCustom()) st.source else "https://");
                }
                const on_apply: ?ui.Callback = if (st.actions != null) .of(st, BtnState.apply) else null;
                const key = @as(u64, page_st.form_id);
                rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                    cx.make(ui.SizedBox{ .width = 70, .child = cx.make(ui.Text{ .text = "Server", .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                        .placeholder = "https://example.com/dazzle",
                        .initial = page_st.server_url.text(),
                        .max_len = page_st.server_url.buf.len,
                        .size = 16,
                        .on_changed = .of(page_st, PageState.setServerUrl),
                        .on_submit = on_apply,
                    }).withKey(key) }),
                } })) catch {};
                if (page_st.server_invalid) rows.append(a, cx.make(ui.Text{
                    .text = "Give an https:// URL",
                    .style = .{ .size = 15, .color = t.@"error" },
                })) catch {};
                rows.append(a, cx.make(ui.Row{ .main_axis_alignment = .end, .children = &.{
                    cx.make(ui.OutlinedButton{ .label = "Apply", .on_press = on_apply }),
                } })) catch {};
            }

            rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                cx.make(ui.SizedBox{ .width = 70, .child = cx.make(ui.Text{ .text = "Keys", .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false }) }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = st.default_key, .style = .{ .size = 15, .color = t.on_surface }, .wrap = false, .ellipsis = true }) }),
            } })) catch {};
            for (st.subscribed_keys) |k| {
                const key_str = cx.fmt("{s}", .{&k});
                const on_unsub: ?ui.Callback = if (st.actions) |acts| .of(keyAct(cx, acts, k), KeyAct.unsubscribe) else null;
                rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                    cx.make(ui.SizedBox{ .width = 70, .child = cx.make(ui.Empty{}) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = key_str, .style = .{ .size = 15, .color = t.on_surface }, .wrap = false, .ellipsis = true }) }),
                    cx.make(ui.IconButton{
                        .icon = .delete,
                        .size = 28,
                        .icon_size = 18,
                        .on_press = on_unsub,
                    }),
                } })) catch {};
            }
            const on_subscribe: ?ui.Callback = if (st.actions != null) .of(st, BtnState.subscribeKey) else null;
            rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                    .placeholder = "Ed25519 public key (64 hex characters)",
                    .initial = page_st.key_input.text(),
                    .max_len = store.key_hex_len,
                    .size = 15,
                    .on_changed = .of(page_st, PageState.setKeyInput),
                    .on_submit = on_subscribe,
                }).withKey(@as(u64, page_st.key_form_id)) }),
                cx.make(ui.OutlinedButton{ .label = "Subscribe", .on_press = on_subscribe }),
            } })) catch {};
            if (page_st.key_invalid) rows.append(a, cx.make(ui.Text{
                .text = "Give a 64-character hex Ed25519 public key",
                .style = .{ .size = 15, .color = t.@"error" },
            })) catch {};

            return cx.make(ui.Decorated{
                .color = t.surface_container,
                .border = .{ .width = 1, .color = t.outline_variant },
                .radius = .all(8),
                .child = cx.make(ui.SizedBox{ .width = 420, .child = cx.make(ui.Padding{
                    .padding = .all(16),
                    .child = cx.make(ui.Column{ .main_axis_size = .min, .cross_axis_alignment = .stretch, .spacing = 12, .children = rows.items }),
                }) }),
            });
        }
    };

    pub fn build(self: *const ServerConfigButton, cx: *ui.Context, state: *BtnState) ui.Widget {
        state.node = cx.node;
        state.state = self.state;
        state.actions = self.actions;
        state.source = self.source;
        state.default_source = self.default_source;
        state.default_key = self.default_key;
        state.subscribed_keys = self.subscribed_keys;
        return cx.make(ui.IconButton{
            .icon = .settings,
            .size = 36,
            .icon_size = 20,
            .on_press = if (self.actions != null) .of(state, BtnState.open) else null,
        });
    }
};

/// Renders a 64x64 PNG icon, or the fallback `.apps` icon when no icon
/// can be found.
fn softwareIcon(cx: *ui.Context, image: ?*const gfx.Image) ui.Widget {
    const t = &cx.ui.theme;
    if (image) |img| {
        return cx.make(ui.SizedBox{ .width = 64, .height = 64, .child = cx.make(ui.Image{ .image = img }) });
    }
    return cx.make(ui.SizedBox{ .width = 64, .height = 64, .child = cx.make(ui.Center{ .child = cx.make(ui.Icon{ .icon = .apps, .size = 48, .color = t.on_surface_variant }) }) });
}

pub const max_icons = 64;

/// Decoded 64x64 PNG icons for Dazzle and the catalogue's apps, loaded
/// with priority: installed icon on disk when up to date, then the server
/// icon when uninstalled, missing on disk or a newer version is available,
/// then null (showing the fallback icon).
pub const IconSet = struct {
    gpa: std.mem.Allocator,
    os_decoded: ?gfx.png.Decoded = null,
    os_image: ?gfx.Image = null,
    app_decoded: [max_icons]?gfx.png.Decoded = .{null} ** max_icons,
    app_images: [max_icons]gfx.Image = undefined,
    app_ptrs: [max_icons]?*const gfx.Image = .{null} ** max_icons,

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
    const installed_path = std.fmt.bufPrintZ(&installed_buf, "{s}/{s}/icon.png", .{ dir, app.name }) catch null;
    const server_path = std.fmt.bufPrintZ(&server_buf, "{s}/{s}.png", .{ icons_path, app.name }) catch null;
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
const font = @import("font");

test "installing and removing apps, and getting their list again" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .apps = view.sample_apps };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "All apps updated") != null);
    try testing.expect(view.findText(u.root.?, "Update all") == null);
    view.click(u, view.up(view.findText(u.root.?, "Install").?, ui.OutlinedButton).?);
    try testing.expectEqualStrings("dazzle-files", actions.install.?.slice());
    view.click(u, view.up(view.findIcon(u.root.?, .delete).?, ui.OutlinedButton).?);
    try testing.expectEqualStrings("dazzle-demo", actions.remove.?.slice());
    view.click(u, view.up(view.findText(u.root.?, "Refresh").?, ui.OutlinedButton).?);
    try testing.expect(actions.refresh_apps);

    // While one installs: a spinner in its place, and nothing else can be
    // pressed.
    actions = .{};
    settings.apps.busy = "dazzle-files";
    u.frame(1920, 960, 2, settings);
    try testing.expect(view.findText(u.root.?, "Install") == null);
    try testing.expect(view.findText(u.root.?, "Installing…") != null);
    view.click(u, view.up(view.findIcon(u.root.?, .delete).?, ui.OutlinedButton).?);
    try testing.expect(actions.remove == null);

    // An install error shows in a dismissible snackbar.
    settings.apps = view.sample_apps;
    settings.apps.message = "Cannot install Files: the server could not be reached (is the network up?)";
    u.frame(1920, 960, 3, settings);
    const snack = view.findType(u.root.?, ui.Snackbar).?;
    try testing.expect(view.findText(snack, "Cannot install Files: the server could not be reached (is the network up?)") != null);
    view.click(u, view.findType(snack, ui.IconButton).?);
    u.frame(1920, 960, 4, settings);
    try testing.expect(view.findText(u.root.?, "Cannot install Files: the server could not be reached (is the network up?)") == null);

    // No list yet: labelled at the bottom, not in a snackbar.
    settings.apps = .{ .message = "Cannot get the list of apps: the server could not be reached (is the network up?)" };
    u.frame(1920, 960, 5, settings);
    try testing.expect(view.findText(u.root.?, "No list of apps yet: is the network up?") != null);
    try testing.expect(view.findText(u.root.?, "Cannot get the list of apps: the server could not be reached (is the network up?)") == null);
}

test "updates: offered, downloaded, installed, then a restart" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
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
    const update_all_btn = view.up(view.findText(u.root.?, "Update all").?, ui.OutlinedButton).?;
    const refresh_btn = view.up(view.findText(u.root.?, "Refresh").?, ui.OutlinedButton).?;
    try testing.expect(update_all_btn.position()[0] < refresh_btn.position()[0]);
    view.click(u, update_all_btn);
    try testing.expect(actions.update_all);
    actions = .{};

    // With both an OS update and an app update: "2 updates available".
    settings.apps.updatable = &.{ true, false };
    u.frame(1920, 960, 2, settings);
    try testing.expect(view.findText(u.root.?, "2 updates available") != null);
    try testing.expect(view.findIcon(u.root.?, .delete) == null);

    // Build and kernel details are shown when Dazzle is expanded.
    try testing.expect(view.findText(u.root.?, "de14aa2 (7 October 2026)") == null);
    view.click(u, view.up(view.findText(u.root.?, "Dazzle").?, ui.Pressable).?);
    u.frame(1920, 960, 3, settings);
    try testing.expect(view.findText(u.root.?, "de14aa2 (7 October 2026)") != null);
    try testing.expect(view.findText(u.root.?, "6.12.0 (armv6l)") != null);
    view.click(u, view.up(view.findText(u.root.?, "Update").?, ui.OutlinedButton).?);
    try testing.expect(actions.download_update);

    // Under way: no update buttons on Dazzle.
    settings.apps.updatable = &.{};
    for ([_]update.Status{ .checking, .downloading, .installing }) |s| {
        settings.update = .{ .status = s };
        u.frame(1920, 960, 4, settings);
        try testing.expect(view.up(view.findText(u.root.?, "Dazzle").?, ui.Row) != null);
        try testing.expect(view.findText(u.root.?, "Update") == null and view.findText(u.root.?, "Restart") == null);
    }
    settings.update = .{ .status = .ready };
    u.frame(1920, 960, 5, settings);
    try testing.expect(view.findText(u.root.?, "The update is installed: restart to use it") != null);
    view.click(u, view.up(view.findText(u.root.?, "Restart").?, ui.OutlinedButton).?);
    try testing.expect(actions.restart);

    settings.update = .{ .status = .current };
    u.frame(1920, 960, 6, settings);
    try testing.expect(view.findText(u.root.?, "The operating system · 600 KB") != null);
    try testing.expect(view.findText(u.root.?, "All apps updated") != null);
    try testing.expect(view.findText(u.root.?, "Update all") == null);
    view.click(u, view.up(view.findText(u.root.?, "Refresh").?, ui.OutlinedButton).?);
    try testing.expect(actions.check_update and actions.refresh_apps);

    settings.update = .{ .status = .unknown, .message = "Cannot check for updates: the server could not be reached (is the network up?)" };
    u.frame(1920, 960, 7, settings);
    try testing.expect(view.findText(u.root.?, "Cannot check for updates: the server could not be reached (is the network up?)") != null);
    settings.update = .{};
    u.frame(1920, 960, 8, settings);
    try testing.expect(view.findText(u.root.?, "The operating system · 600 KB") != null);
}

test "software icons: installed when up to date, server when uninstalled, missing on disk or newer available, else fallback" {
    const linux = std.os.linux;
    var dir_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&dir_buf, "/tmp/dazzle-icons-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(root, 0o755);
    defer sys_mod.files.removeTree(root);

    var os_dir_buf: [96]u8 = undefined;
    var apps_dir_buf: [96]u8 = undefined;
    var icons_dir_buf: [96]u8 = undefined;
    const os_dir = try std.fmt.bufPrintZ(&os_dir_buf, "{s}/os", .{root});
    const apps_dir = try std.fmt.bufPrintZ(&apps_dir_buf, "{s}/apps", .{root});
    const icons_dir = try std.fmt.bufPrintZ(&icons_dir_buf, "{s}/apps/.icons", .{root});
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
    const os_installed = try std.fmt.bufPrintZ(&os_installed_buf, "{s}/icon.png", .{os_dir});
    const os_server = try std.fmt.bufPrintZ(&os_server_buf, "{s}/server-os-icon.png", .{os_dir});
    try makePng(testing.allocator, os_installed, 0xff112233);
    try makePng(testing.allocator, os_server, 0xffaabbcc);

    // Installed app "dazzle-demo" at version 1000 abc, with an installed icon (0x10) and server icon (0x20).
    var path_buf: [160]u8 = undefined;
    _ = linux.mkdir(try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-demo", .{apps_dir}), 0o755);
    const demo_bin = try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-demo/dazzle-demo", .{apps_dir});
    try sys_mod.files.writeNew(demo_bin, "bin");
    _ = linux.chmod(demo_bin, 0o755);
    try sys_mod.files.writeNew(try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-demo/version", .{apps_dir}), "1000 abc\n");
    try makePng(testing.allocator, try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-demo/icon.png", .{apps_dir}), 0xff100000);
    try makePng(testing.allocator, try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-demo.png", .{icons_dir}), 0xff200000);

    // Installed app "dazzle-files" with NO icon on disk, only a server icon (0x30).
    _ = linux.mkdir(try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-files", .{apps_dir}), 0o755);
    const files_bin = try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-files/dazzle-files", .{apps_dir});
    try sys_mod.files.writeNew(files_bin, "bin");
    _ = linux.chmod(files_bin, 0o755);
    try makePng(testing.allocator, try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-files.png", .{icons_dir}), 0xff300000);

    // Uninstalled app "dazzle-camera" with a server icon (0x40), and "dazzle-maps" with NO icon anywhere.
    try makePng(testing.allocator, try std.fmt.bufPrintZ(&path_buf, "{s}/dazzle-camera.png", .{icons_dir}), 0xff400000);

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
    const u = try ui.Ui.create(testing.allocator, &f);
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
        .apps = .{ .list = &many_apps, .installed = &.{ true, false, false, false, false, false, false, false } },
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

test "changing the software server to a custom https URL and back to default" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
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
        fn call(uu: *ui.Ui, s: Settings, n: *u64) void {
            n.* += 1;
            uu.frame(1920, 960, n.*, s);
        }
    }.call;

    draw(u, settings, &frame_no);
    u.root.?.state(Settings.State).page = .apps;
    draw(u, settings, &frame_no);
    try testing.expect(view.findType(u.root.?, ServerConfigButton) != null);
    try testing.expect(u.menu_root == null);

    // Clicking the configure icon opens the popup showing Default, Custom, and the default server URL.
    view.click(u, view.findType(u.root.?, ServerConfigButton).?);
    draw(u, settings, &frame_no);
    try testing.expect(u.menu_root != null);
    try testing.expect(view.findText(u.menu_root.?, "Default") != null);
    try testing.expect(view.findText(u.menu_root.?, "Custom") != null);
    try testing.expect(view.findText(u.menu_root.?, "https://example.com/apps") != null);

    // Choosing Custom shows the URL text field starting with "https://".
    view.click(u, view.findText(u.menu_root.?, "Custom").?);
    draw(u, settings, &frame_no);
    const field = view.findType(u.menu_root.?, ui.TextField).?;
    try testing.expectEqualStrings("https://", field.state(ui.TextField.State).text());
    try testing.expect(!view.overflows(u.menu_root.?));

    // Non-https URL is rejected with an error message.
    var st = &u.root.?.state(Settings.State).software;
    st.server_url.set("http://staging.example.com/dazzle");
    view.click(u, view.findText(u.menu_root.?, "Apply").?);
    draw(u, settings, &frame_no);
    try testing.expect(actions.software_server == null);
    try testing.expect(view.findText(u.menu_root.?, "Give an https:// URL") != null);

    // Valid https URL is accepted (stripping trailing slash) and closes the popup.
    st = &u.root.?.state(Settings.State).software;
    st.server_url.set("https://staging.example.com/dazzle/");
    view.click(u, view.findText(u.menu_root.?, "Apply").?);
    try testing.expectEqualStrings("https://staging.example.com/dazzle", actions.software_server.?.slice());
    actions = .{};

    // Reopening when using a custom server opens on Custom; clicking Default resets to default.
    settings.apps.source = "https://staging.example.com/dazzle";
    draw(u, settings, &frame_no);
    view.click(u, view.findType(u.root.?, ServerConfigButton).?);
    draw(u, settings, &frame_no);
    try testing.expect(view.findType(u.menu_root.?, ui.TextField) != null);
    view.click(u, view.findText(u.menu_root.?, "Default").?);
    try testing.expectEqualStrings("", actions.software_server.?.slice());
}

test "subscribing and removing Ed25519 signing keys in the software settings popup" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic("test-settings-key-seed-000000001".*);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    const subscribed = [_][store.key_hex_len]u8{pub_hex};
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
        fn call(uu: *ui.Ui, s: Settings, n: *u64) void {
            n.* += 1;
            uu.frame(1920, 960, n.*, s);
        }
    }.call;

    draw(u, settings, &frame_no);
    u.root.?.state(Settings.State).page = .apps;
    draw(u, settings, &frame_no);

    view.click(u, view.findType(u.root.?, ServerConfigButton).?);
    draw(u, settings, &frame_no);
    try testing.expect(u.menu_root != null);
    try testing.expect(view.findText(u.menu_root.?, "Keys") != null);
    try testing.expect(view.findText(u.menu_root.?, store.default_signing_key) != null);

    // Invalid key shows an error message.
    var st = &u.root.?.state(Settings.State).software;
    st.key_input.set("not-a-valid-key");
    view.click(u, view.findText(u.menu_root.?, "Subscribe").?);
    draw(u, settings, &frame_no);
    try testing.expect(actions.subscribe_key == null);
    try testing.expect(view.findText(u.menu_root.?, "Give a 64-character hex Ed25519 public key") != null);

    // Valid 64-character hex Ed25519 public key sets subscribe_key action and clears input.
    st = &u.root.?.state(Settings.State).software;
    st.key_input.set(&pub_hex);
    view.click(u, view.findText(u.menu_root.?, "Subscribe").?);
    draw(u, settings, &frame_no);
    try testing.expectEqualStrings(&pub_hex, actions.subscribe_key.?.slice());
    actions = .{};

    // Subscribed keys are displayed with a delete button to unsubscribe.
    settings.apps.subscribed_keys = &subscribed;
    draw(u, settings, &frame_no);
    try testing.expect(view.findText(u.menu_root.?, &pub_hex) != null);
    try testing.expect(!view.overflows(u.menu_root.?));
    const del_icon = view.findIcon(u.menu_root.?, .delete).?;
    view.click(u, view.up(del_icon, ui.IconButton).?);
    try testing.expectEqualStrings(&pub_hex, actions.unsubscribe_key.?.slice());
}
