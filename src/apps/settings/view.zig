//! The settings app's window, as widgets: pages, chosen with the tabs on
//! the left, about the Wi-Fi networks around, Ethernet, the resources in
//! use (with meters), the board (drawn: picking a part says what it is;
//! see board.zig), the USB devices plugged in, the language and keyboard,
//! the system (its build, updates and Linux) and the system's log
//! (newest first, or only its warnings and errors).
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
const locale = @import("locale");
const store = @import("store");
const update = @import("update.zig");
const board = @import("board.zig");
const usb = @import("usb.zig");
const gpio = @import("gpio.zig");
const GpioPage = @import("gpio_view.zig").GpioPage;
const log = @import("log.zig");
const BoardView = @import("board_view.zig").BoardView;
const sys_mod = @import("sys");
const proto = sys_mod.system;

/// The storage bar's colours (the system's is the theme's primary).
pub const apps_color = gfx.Color.argb(0xff4fd8c4);
pub const user_color = gfx.Color.argb(0xffffb68a);

/// What the window asks of the network manager; the main loop sends it,
/// then clears it.
pub const Actions = struct {
    connect: ?Join = null,
    disconnect: bool = false,
    /// The Wi-Fi adapter chosen (when there is more than one).
    wifi_adapter: ?info.Str(16) = null,
    /// How the wired adapter gets its address, and which adapter (empty for
    /// the first).
    ethernet: ?info.manager.Addressing = null,
    ethernet_adapter: info.Str(16) = .{},
    /// The app to install, or remove; whether to get the list of apps again.
    install: ?AppName = null,
    remove: ?AppName = null,
    refresh_apps: bool = false,
    /// Updates: check for one, download the one offered, update all, restart into it.
    check_update: bool = false,
    download_update: bool = false,
    update_all: bool = false,
    restart: bool = false,
    /// The language and keyboard to use.
    locale: ?locale.Settings = null,
    /// A GPIO pin to set up, and how.
    gpio: ?GpioChange = null,
    /// The video memory to have from the next start, in MiB.
    video_memory: ?u16 = null,

    pub const GpioChange = struct { pin: u6, mode: gpio.Mode };


    fn downloadUpdate(a: *Actions) void {
        a.download_update = true;
    }

    fn updateAll(a: *Actions) void {
        a.update_all = true;
    }

    fn restartNow(a: *Actions) void {
        a.restart = true;
    }

    fn videoMemorySetter(comptime mib: u16) fn (*Actions) void {
        return struct {
            fn set(a: *Actions) void {
                a.video_memory = mib;
            }
        }.set;
    }

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
        adapter: info.Str(16) = .{},
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

/// The smallest the window may be: the tabs, and the widest page's rows
/// beside them. Everything is the same size in pixels whatever the
/// window's size; the pages grow to fill the width (up to
/// `max_page_width`), and scroll.
pub const min_size = [2]u32{ 720, 440 };

/// The size the window opens at: the tabs of pages beside a page.
pub const open_size = [2]u32{ 1000, 680 };

/// The widest a page is.
const max_page_width = 960;

/// What the Apps page shows.
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
    /// Where they come from.
    source: []const u8 = "",
};

/// Video memory (see `sys.system.video_memory_sizes`), in MiB: what the GPU
/// may have now, and from the next start; null if not known.
pub const VideoMemory = struct {
    now: ?u16 = null,
    next: ?u16 = null,
    /// Asking for a change failed.
    failed: bool = false,
};

/// What the System page shows of updates.
pub const Update = struct {
    status: update.Status = .unknown,
    /// The system offered: "0123abc (8 October 2026)".
    available: []const u8 = "",
    /// What went wrong last.
    message: []const u8 = "",
    /// Dazzle's 64x64 icon (installed, or from the server when a newer
    /// version is available or none is on disk); null for the fallback icon.
    icon: ?*const gfx.Image = null,
};

pub const Settings = struct {
    commit: []const u8,
    /// The language and keyboard in use.
    locale: locale.Settings = .{},
    /// Where the window's requests go (none in tests that do not look).
    actions: ?*Actions = null,
    system: *const info.System,
    usage: info.Usage,
    network: *const info.Network,
    /// The USB devices plugged in.
    usb: *const usb.Devices = &.{},
    /// The GPIO pins (while their page shows).
    gpio: ?*const gpio.Pins = null,
    /// The system's log, as read so far (while its page shows).
    log: ?*const log.Log = null,
    /// What the network manager last said; null if it could not be asked.
    manager: ?*const info.manager.Report = null,
    /// The apps that can be installed, and how installing goes.
    apps: Apps = .{},
    update: Update = .{},
    video_memory: VideoMemory = .{},
    /// The title bar's buttons (close, and maximize, which shows whether
    /// the window is), and pressing the bar (to move the window).
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub const State = struct {
        /// The page shown.
        page: Page = .wifi,
        /// The Wi-Fi and Ethernet adapters picked, when there is more than
        /// one.
        wifi_adapter: usize = 0,
        ethernet_adapter: usize = 0,
        /// The part of the board picked (an index into its parts), if one
        /// is.
        board_part: ?usize = null,
        /// The GPIO pin picked.
        gpio_pin: u6 = 17,
        /// The log shows only warnings and errors.
        log_problems: bool = false,
        /// The Wi-Fi network chosen (its SSID), and the password typed.
        selected_buf: [32]u8 = undefined,
        selected_len: u8 = 0,
        has_selected: bool = false,
        password_buf: [63]u8 = undefined,
        password_len: u8 = 0,
        /// Whether the Dazzle item on the Software page is expanded to show
        /// the build and kernel version.
        dazzle_expanded: bool = false,
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

        fn toggleDazzle(st: *State) void {
            st.dazzle_expanded = !st.dazzle_expanded;
        }

        fn setLogProblems(st: *State, on: bool) void {
            st.log_problems = on;
        }

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
        const t = cx.theme();
        var tabs: [std.meta.fields(Page).len]ui.Widget = undefined;
        inline for (&tabs, std.meta.fields(Page)) |*w, field| {
            const p: Page = @enumFromInt(field.value);
            w.* = cx.make(Tab{ .label = p.label(), .icon = p.icon(), .selected = state.page == p, .on_press = pick(cx, state, p) });
        }
        // The tabs scroll in a window too short for them all.
        const sidebar = cx.make(ui.SizedBox{ .width = 190, .child = cx.make(ui.Decorated{
            .color = t.surface_container,
            .child = cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .all(12), .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .main_axis_size = .min,
                .spacing = 4,
                .children = &tabs,
            }) }) }),
        }) });
        // A page longer than the window scrolls; another page starts at
        // its top. In a wide window the page is no wider than reads well,
        // in the middle.
        const right = if (state.page == .apps)
            self.appsPage(b, state)
        else blk: {
            const page = switch (state.page) {
                .wifi => self.wifiPage(b, state),
                .ethernet => self.networkPage(b, state),
                .resources => self.resourcesPage(b),
                .board => self.boardPage(b, state),
                .language => self.languagePage(b),
                .gpio => self.gpioPage(b, state),
                .usb => self.usbPage(b),
                .log => self.logPage(b, state),
                .apps => unreachable,
            };
            break :blk cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Align{
                .alignment = .top_center,
                .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = max_page_width }, .child = page }),
            }) }) }).withKey(@as(u64, @intFromEnum(state.page)) + 1);
        };
        const content = cx.make(ui.Row{ .cross_axis_alignment = .stretch, .children = &.{
            sidebar,
            cx.make(ui.Expanded{ .child = cx.make(ui.Decorated{
                .color = t.surface,
                .child = right,
            }) }),
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

    fn appsPage(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const apps = &self.apps;
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        const os_busy = self.update.status == .checking or self.update.status == .downloading or self.update.status == .installing;
        const busy = apps.busy != null or os_busy;
        if (apps.message.len > 0) rows.append(a, b.value(apps.message)) catch {};
        self.dazzleRows(b, state, &rows);
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
            else if (installed)
                cx.make(ui.OutlinedButton{ .label = "Remove", .icon = .delete, .on_press = if (enabled) .of(x.?, AppAct.remove) else null })
            else
                cx.make(ui.OutlinedButton{ .label = "Install", .icon = .download, .on_press = if (enabled) .of(x.?, AppAct.install) else null });
            var size_buf: [32]u8 = undefined;
            const detail = if (app.description.len > 0)
                cx.fmt("{s} · {s}", .{ app.description, info.formatBytes(&size_buf, app.size) })
            else
                cx.fmt("{s}", .{info.formatBytes(&size_buf, app.size)});
            const icon: ?*const gfx.Image = if (i < apps.icons.len) apps.icons[i] else null;
            rows.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 16, .children = &.{
                softwareIcon(cx, icon),
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
                .on_press = if (self.actions != null and !busy) .of(self.actions.?, Actions.updateAll) else null,
            })) catch {};
        }
        footer_children.append(a, cx.make(ui.OutlinedButton{
            .label = "Refresh",
            .icon = .refresh,
            .on_press = if (self.actions != null and !busy) .of(appAct(cx, self.actions.?, state, ""), AppAct.refresh) else null,
        })) catch {};
        const footer = cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = footer_children.items });
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.Expanded{ .child = cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{
                .padding = .{ .left = 24, .top = 24, .right = 24, .bottom = 12 },
                .child = cx.make(ui.Align{
                    .alignment = .top_center,
                    .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = max_page_width }, .child = b.page(rows.items) }),
                }),
            }) }).withKey(@as(u64, @intFromEnum(Page.apps)) + 1) }),
            cx.make(ui.Padding{
                .padding = .{ .left = 24, .top = 12, .right = 24, .bottom = 24 },
                .child = cx.make(ui.Align{
                    .alignment = .center,
                    .height_factor = 1,
                    .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = max_page_width }, .child = footer }),
                }),
            }),
        } });
    }

    /// Dazzle itself, at the head of the Software list: how updates stand
    /// (with Download or Restart), and an expander showing the build and
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
        const text: []const u8, const button: ?Button, const busy = switch (u.status) {
            .unknown, .current => .{ if (u.message.len > 0) u.message else detail, null, false },
            .checking => .{ "Checking for updates…", null, true },
            .available => .{ cx.fmt("Dazzle {s} is available", .{u.available}), Button{ .label = "Download", .icon = .download, .flag = .download }, false },
            .downloading => .{ "Downloading the update…", null, true },
            .installing => .{ "Installing the update…", null, true },
            .ready => .{ "The update is installed: restart to use it", Button{ .label = "Restart", .icon = .restart_alt, .flag = .restart }, false },
        };
        const end: ui.Widget = if (busy) cx.make(ui.Spinner{ .size = 28 }) else if (button) |btn| cx.make(ui.OutlinedButton{
            .label = btn.label,
            .icon = btn.icon,
            .on_press = if (self.actions) |acts| switch (btn.flag) {
                .download => .of(acts, Actions.downloadUpdate),
                .restart => .of(acts, Actions.restartNow),
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
                    dazzleDetail(cx, "Linux", orUnknown(self.system.kernel.slice())),
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

    fn resourcesPage(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const u = self.usage;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        const cores = self.system.cores;
        const cpu = if (u.cpu_busy) |busy| cx.fmt("{d:.0}% busy ({d} {s})", .{ busy, cores, if (cores == 1) "core" else "cores" }) else "Measuring…";
        const mem = cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) });
        return b.page(&.{
            b.meter("CPU", cpu, (u.cpu_busy orelse 0) / 100),
            b.meter("CPU Memory", mem, fraction(u.memUsed(), u.mem_total)),
            self.gpuMemoryRow(b),
            b.storage(u.storage),
        });
    }

    /// GPU memory: how much is in use (with a meter), and an icon beside the
    /// label that opens a menu of the sizes to choose from for the next
    /// start (with Restart when a change is waiting).
    fn gpuMemoryRow(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const t = cx.theme();
        const u = self.usage;
        const vm = self.video_memory;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var b3: [32]u8 = undefined;
        const gpu = if (u.gpu_total > 0) cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.gpuUsed()), info.formatBytes(&b2, u.gpu_total) }) else "Unknown";
        const pending = vm.next != null and vm.now != vm.next;
        const ram_mib = u.mem_total >> 20;
        const a = cx.ui.arena();
        var col: std.ArrayList(ui.Widget) = .empty;
        col.appendSlice(a, &.{
            b.value(gpu),
            cx.make(Meter{ .fraction = fraction(u.gpuUsed(), u.gpu_total), .height = @max(8, 4) }),
        }) catch {};
        if (vm.failed) {
            col.append(a, cx.make(ui.Text{ .text = "It could not be changed", .style = .{ .size = 15, .color = t.@"error" } })) catch {};
        } else if (pending) {
            col.append(a, cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{
                    .text = cx.fmt("{s} after a restart", .{info.formatBytes(&b3, @as(u64, vm.next.?) << 20)}),
                    .style = .{ .size = 15, .color = t.on_surface_variant },
                }) }),
                cx.make(ui.OutlinedButton{ .label = "Restart", .icon = .restart_alt, .on_press = if (self.actions) |acts| .of(acts, Actions.restartNow) else null }),
            } })) catch {};
        }
        return cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
            cx.make(ui.SizedBox{ .width = 150, .child = cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 4, .children = &.{
                cx.make(ui.Text{ .text = "GPU memory", .style = .{ .size = 18, .color = t.on_surface_variant }, .wrap = false }),
                cx.make(VideoMemoryMenu{ .chosen = vm.next, .ram_mib = ram_mib, .actions = if (vm.next != null) self.actions else null }),
            } }) }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 6, .children = col.items }) }),
        } });
    }

    /// The system's log, newest first: when each message came (since the
    /// system started) and what it says, warnings and errors in colour;
    /// or only those.
    fn logPage(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const a = cx.ui.arena();
        const problems = cx.make(ui.Switch{ .value = state.log_problems, .on_changed = .of(state, State.setLogProblems), .label = "Only warnings and errors" });
        const l = self.log orelse return b.page(&.{ problems, b.value("Reading the log…") });
        if (l.failed) return b.page(&.{b.value("The log cannot be read")});
        // The lines shown, newest first.
        var shown: std.ArrayList(*const log.Line) = .empty;
        for (0..l.count) |i| {
            const line = l.newest(i);
            if (!state.log_problems or line.level.problem()) shown.append(a, line) catch break;
        }
        const lines = a.create(LogLines) catch return cx.make(ui.Empty{});
        lines.* = .{ .lines = shown.items };
        return b.page(&.{
            problems,
            if (shown.items.len == 0) b.value(if (state.log_problems) "No warnings or errors" else "Nothing yet") else cx.make(ui.LazyGrid{
                .count = shown.items.len,
                .cell = .{ .w = std.math.inf(f32), .h = log_row_height },
                .item = .of(lines, LogLines.row),
            }),
        });
    }

    /// The GPIO pins: the header as it is laid out, what each pin does,
    /// and the pin picked, to set up.
    fn gpioPage(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const pins = self.gpio orelse return b.page(&.{b.value("Reading the pins\u{2026}")});
        return b.page(&.{cx.make(GpioPage{
            .pins = pins,
            .header = gpio.headerFor(self.system.model.slice()),
            .picked = state.gpio_pin,
            .on_pick = .of(state, struct {
                fn set(st: *State, i: usize) void {
                    st.gpio_pin = @intCast(i);
                }
            }.set),
            .on_mode = if (self.actions) |a| blk: {
                const set = cx.ui.arena().create(GpioSet) catch break :blk null;
                set.* = .{ .actions = a, .pin = state.gpio_pin };
                break :blk .of(set, GpioSet.set);
            } else null,
        })});
    }

    /// The USB devices: what each is, who made it and how fast it talks;
    /// those that are part of the board last.
    fn usbPage(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const t = cx.theme();
        const devices = self.usb.slice();
        if (devices.len == 0) return b.page(&.{b.value("Nothing is plugged in")});
        const a = cx.ui.arena();
        var rows: std.ArrayList(ui.Widget) = .empty;
        for (devices) |*d| {
            var name_buf: [64]u8 = undefined;
            var speed_buf: [16]u8 = undefined;
            var detail: std.ArrayList(u8) = .empty;
            detail.appendSlice(a, d.kind.label()) catch {};
            if (d.manufacturer.len > 0) detail.print(a, "  \u{b7}  {s}", .{d.manufacturer.slice()}) catch {};
            const speed = usb.formatSpeed(&speed_buf, d.speed_mbps);
            if (speed.len > 0) detail.print(a, "  \u{b7}  {s}", .{speed}) catch {};
            if (d.built_in) detail.appendSlice(a, "  \u{b7}  Part of the board") catch {};
            rows.append(a, cx.make(ui.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = &.{
                cx.make(ui.Icon{ .icon = usbIcon(d.kind), .size = 28, .color = t.on_surface_variant }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                    cx.make(ui.Text{ .text = cx.fmt("{s}", .{d.name(&name_buf)}), .style = .{ .size = 18 }, .wrap = false, .ellipsis = true }),
                    cx.make(ui.Text{ .text = detail.items, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
                } }) }),
            } })) catch {};
        }
        return b.page(rows.items);
    }

    /// The language and keyboard, and a field to try the keyboard in.
    fn languagePage(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const t = cx.theme();
        const a = cx.ui.arena();
        const picker = a.create(LocalePick) catch return cx.make(ui.Empty{});
        picker.* = .{ .actions = self.actions, .current = self.locale };
        var rows: std.ArrayList(ui.Widget) = .empty;
        const heading: ui.TextStyle = .{ .size = 18, .color = t.on_surface_variant };
        rows.append(a, cx.make(ui.Text{ .text = "Language", .style = heading })) catch {};
        for (std.enums.values(locale.Language)) |l| rows.append(a, cx.make(ui.Radio(locale.Language){
            .value = l,
            .group_value = self.locale.language,
            .on_changed = if (self.actions != null) .of(picker, LocalePick.language) else null,
            .label = l.name(),
        })) catch {};
        rows.append(a, cx.make(ui.Padding{ .padding = .{ .top = 12 }, .child = cx.make(ui.Text{ .text = "Keyboard", .style = heading }) })) catch {};
        for (std.enums.values(locale.Keyboard)) |k| rows.append(a, cx.make(ui.Radio(locale.Keyboard){
            .value = k,
            .group_value = self.locale.keyboard,
            .on_changed = if (self.actions != null) .of(picker, LocalePick.keyboard) else null,
            .label = k.name(),
        })) catch {};
        rows.append(a, cx.make(ui.Row{ .children = &.{cx.make(ui.TextField{ .placeholder = "Type here to try the keyboard", .width = 360 })} })) catch {};
        return b.page(rows.items);
    }

    /// The board, drawn, and about the part picked on it.
    fn boardPage(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const t = cx.theme();
        const a = cx.ui.arena();
        const model = self.system.model.slice();
        var rows: std.ArrayList(ui.Widget) = .empty;
        rows.append(a, b.value(orUnknown(model))) catch {};
        if (self.system.serial.len > 0) rows.append(a, cx.make(ui.Text{ .text = cx.fmt("Serial: {s}", .{self.system.serial.slice()}), .style = .{ .size = 16, .color = t.on_surface_variant } })) catch {};
        const drawing = board.forModel(model) orelse {
            rows.append(a, b.value("There is no drawing of this board")) catch {};
            return b.page(rows.items);
        };
        // The processor, until something else is picked.
        const picked = state.board_part orelse for (drawing.parts, 0..) |part, i| {
            if (part.kind == .soc or part.kind == .soc_with_ram) break i;
        } else 0;
        const part = &drawing.parts[@min(picked, drawing.parts.len - 1)];
        const about = board.describe(part);
        rows.appendSlice(a, &.{
            cx.make(ui.Padding{ .padding = .symmetric(0, 8), .child = cx.make(ui.Align{ .alignment = .center_left, .child = cx.make(BoardView{ .board = drawing, .selected = picked, .on_select = partPicker(state) }) }) }),
            cx.make(ui.Text{ .text = if (part.chip.len > 0) cx.fmt("{s}: {s}", .{ about.title, part.chip }) else about.title, .style = .{ .size = 20, .color = t.on_surface } }),
            cx.make(ui.Text{ .text = cx.fmt("{s}{s}", .{ about.about, if (part.underside) " (underneath the board)" else "" }), .style = .{ .size = 16, .color = t.on_surface_variant } }),
        }) catch {};
        // What it is doing now, where that is known.
        const u = self.usage;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        const now: ?[]const u8 = switch (part.kind) {
            .soc => if (u.cpu_busy) |busy| (if (u.temperature) |c| cx.fmt("{d:.0}% busy, at {s}", .{ busy, locale.formatTemperature(&b1, c) }) else cx.fmt("{d:.0}% busy", .{busy})) else null,
            .soc_with_ram => if (u.cpu_busy) |busy| cx.fmt("{d:.0}% busy; {s} of {s} of memory in use", .{ busy, info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) }) else null,
            .ram => cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) }),
            .micro_sd, .sd, .emmc => if (u.storage.user + u.storage.apps > 0) cx.fmt("{s} of your files and {s} of apps", .{ info.formatBytes(&b1, u.storage.user), info.formatBytes(&b2, u.storage.apps) }) else null,
            else => null,
        };
        if (now) |text| rows.append(a, cx.make(ui.Text{ .text = text, .style = .{ .size = 16, .color = t.on_surface } })) catch {};
        return b.page(rows.items);
    }

    fn wifiPage(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const report = self.manager orelse return b.page(&.{b.item("Status", "The network manager is not running")});
        if (report.denied) return b.page(&.{b.item("Status", "Not allowed to scan")});
        const adapters = report.wifiAdapters();
        if (adapters.len == 0) return b.page(&.{b.item("Status", "No Wi-Fi adapter")});
        const idx = @min(state.wifi_adapter, adapters.len - 1);
        state.wifi_adapter = idx;
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
                    .on_press = pickAdapter(cx, state, self.actions, .wifi, i, ad.name()),
                })) catch {};
            }
            rows.append(a, cx.make(ui.Center{ .height_factor = 1, .child = cx.make(PillBar{ .children = pills.items }) })) catch {};
        }
        const m = adapter.mac;
        rows.append(a, b.item("Adapter", cx.fmt("{s} ({x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}){s}", .{ adapter.name(), m[0], m[1], m[2], m[3], m[4], m[5], if (adapter.up) "" else ", down" }))) catch {};
        rows.append(a, self.connectionRow(b, state, adapter.name(), &report.connection)) catch {};

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
        if (form) rows.append(a, self.joinForm(b, state, adapter.name(), chosen.?)) catch {};
        if (split < nets.len) rows.append(a, networkList(b, state, report, nets[split..], chosen)) catch {};
        const footer = if (report.scanning) "Scanning…" else if (nets.len == 0) "No networks found" else "";
        if (footer.len > 0) rows.append(a, b.item("", footer)) catch {};
        return b.page(rows.items);
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
        if (!on_this or !connectionBusy(c)) return b.item("Connection", text);
        return cx.make(ui.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = &.{
            b.label("Connection"),
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

    fn networkPage(self: *const Settings, b: Builder, state: *State) ui.Widget {
        const cx = b.cx;
        const net = self.network;
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        const ifaces = net.slice();
        if (ifaces.len == 0) {
            rows.append(a, b.item("Status", "No adapter: plug in a USB Ethernet adapter")) catch {};
            return b.page(rows.items);
        }
        const idx = @min(state.ethernet_adapter, ifaces.len - 1);
        state.ethernet_adapter = idx;
        if (ifaces.len > 1) {
            var pills: std.ArrayList(ui.Widget) = .empty;
            for (ifaces, 0..) |*ifc, k| {
                pills.append(a, cx.make(PillButton{
                    .label = ifc.name.slice(),
                    .selected = k == idx,
                    .first = k == 0,
                    .last = k + 1 == ifaces.len,
                    .on_press = pickAdapter(cx, state, self.actions, .ethernet, k, ifc.name.slice()),
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
        const method = if (self.addressing(i.name.slice()) == .static) "static" else "DHCP";
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
        if (self.manager != null) self.addressingRows(b, state, i, &rows);
        return b.page(rows.items);
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
        const current = self.addressing(iface.name.slice());
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
};

const Mode = enum { dhcp, static };

/// Choosing DHCP or a static address, and applying one.
const Addressing = struct {
    actions: ?*Actions,
    state: *Settings.State,
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
    board,
    gpio,
    usb,
    language,
    apps,
    log,

    pub fn label(p: Page) []const u8 {
        return switch (p) {
            .wifi => "Wi-Fi",
            .ethernet => "Ethernet",
            .resources => "Resources",
            .board => "Board",
            .gpio => "GPIO",
            .usb => "USB",
            .log => "Log",
            .language => "Language",
            .apps => "Software",
        };
    }

    pub fn icon(p: Page) ui.icons.Icon {
        return switch (p) {
            .wifi => .wifi,
            .ethernet => .lan,
            .resources => .speed,
            .board => .developer_board,
            .gpio => .settings_input_component,
            .usb => .usb,
            .log => .article,
            .language => .language,
            .apps => .apps,
        };
    }
};

/// The page `u` (running a `Settings`) shows.
pub fn shownPage(u: *ui.Ui) Page {
    const root = u.root orelse return .wifi;
    if (!root.widget.is(Settings)) return .wifi;
    return root.state(Settings.State).page;
}

/// Shows page `p` in `u` (running a `Settings`); false if the window is
/// not built yet.
pub fn showPage(u: *ui.Ui, p: Page) bool {
    const root = u.root orelse return false;
    if (!root.widget.is(Settings)) return false;
    root.state(Settings.State).page = p;
    return true;
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

/// A connected pill button at the top of a network page, for choosing an
/// adapter when there is more than one.
const PillBar = struct {
    children: []const ui.Widget,

    pub fn build(self: *const PillBar, cx: *ui.Context) ui.Widget {
        return cx.make(ui.Row{ .main_axis_size = .min, .children = self.children });
    }

    pub fn paintOver(_: *const PillBar, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const r: f32 = PillButton.height / 2;
        c.strokeRoundedRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, .all(r), 1, t.outline);
        if (n.children.items.len > 0) {
            const row = n.children.items[0];
            for (row.children.items[1..]) |seg| {
                c.fillRect(.{ .x = seg.offset[0] - 0.5, .y = 0, .w = 1, .h = n.size.h }, t.outline);
            }
        }
    }
};

/// One segment of a `PillBar`.
const PillButton = struct {
    label: []const u8,
    selected: bool,
    first: bool = false,
    last: bool = false,
    on_press: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub const height = 36;

    pub fn build(self: *const PillButton, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const color = if (self.selected) t.on_surface else t.on_surface_variant;
        const bg: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        const r: f32 = height / 2;
        const radius: gfx.Radii = .{
            .tl = if (self.first) r else 0,
            .bl = if (self.first) r else 0,
            .tr = if (self.last) r else 0,
            .br = if (self.last) r else 0,
        };
        return cx.make(ui.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = bg,
            .radius = radius,
            .child = cx.make(ui.SizedBox{ .height = height, .child = cx.make(ui.Padding{
                .padding = .symmetric(18, 0),
                .child = cx.make(ui.Center{ .width_factor = 1, .height_factor = 1, .child = cx.make(ui.Text{
                    .text = self.label,
                    .style = .{ .size = 16, .color = color },
                    .wrap = false,
                }) }),
            }) }),
        }) });
    }
};

const AdapterKind = enum { wifi, ethernet };

const PickAdapter = struct {
    state: *Settings.State,
    actions: ?*Actions,
    kind: AdapterKind,
    index: usize,
    name: info.Str(16),

    fn press(p: *PickAdapter) void {
        switch (p.kind) {
            .wifi => {
                p.state.wifi_adapter = p.index;
                p.state.has_selected = false;
                if (p.actions) |acts| acts.wifi_adapter = p.name;
            },
            .ethernet => {
                if (p.state.ethernet_adapter != p.index) {
                    p.state.ethernet_adapter = p.index;
                    p.state.static_form = false;
                    p.state.form_filled = false;
                    p.state.static_invalid = false;
                }
            },
        }
    }
};

fn pickAdapter(cx: *ui.Context, state: *Settings.State, actions: ?*Actions, kind: AdapterKind, index: usize, name: []const u8) ?ui.Callback {
    const p = cx.ui.arena().create(PickAdapter) catch return null;
    p.* = .{ .state = state, .actions = actions, .kind = kind, .index = index, .name = .of(name) };
    return .of(p, PickAdapter.press);
}

const log_row_height = 26;

/// The log's lines, to make rows of (in the frame's arena).
const LogLines = struct {
    lines: []const *const log.Line,

    fn row(l: *const LogLines, cx: *ui.Context, i: usize) ui.Widget {
        const t = cx.theme();
        const line = l.lines[i];
        var time_buf: [32]u8 = undefined;
        const color = switch (line.level) {
            .emergency, .alert, .critical, .@"error" => t.@"error",
            .warning => warning_color,
            else => t.on_surface,
        };
        return cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
            cx.make(ui.SizedBox{ .width = 96, .child = cx.make(ui.Text{ .text = cx.fmt("{s}", .{log.formatUptime(&time_buf, line.usec)}), .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false, .text_align = .end }) }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = line.text(), .style = .{ .size = 14, .color = color }, .wrap = false, .ellipsis = true }) }),
        } });
    }
};

/// Warnings in the log.
const warning_color = gfx.Color.argb(0xffe6b450);

fn usbIcon(k: usb.Kind) ui.icons.Icon {
    return switch (k) {
        .keyboard => .keyboard,
        .mouse => .mouse,
        .input => .sports_esports,
        .storage => .usb,
        .hub => .device_hub,
        .network => .lan,
        .wireless => .wifi,
        .audio => .headphones,
        .camera => .videocam,
        .printer => .print,
        .other => .usb,
    };
}

/// Picking a language or keyboard (keeping the other as it is).
const LocalePick = struct {
    actions: ?*Actions,
    current: locale.Settings,

    fn language(p: *LocalePick, l: locale.Language) void {
        if (p.actions) |a| a.locale = .{ .language = l, .keyboard = p.current.keyboard };
    }

    fn keyboard(p: *LocalePick, k: locale.Keyboard) void {
        if (p.actions) |a| a.locale = .{ .language = p.current.language, .keyboard = k };
    }
};

/// Setting a GPIO pin up.
const GpioSet = struct {
    actions: *Actions,
    pin: u6,

    fn set(g: *GpioSet, m: gpio.Mode) void {
        g.actions.gpio = .{ .pin = g.pin, .mode = m };
    }
};

/// Picking a part of the board.
fn partPicker(state: *Settings.State) ?ui.ValueCallback(usize) {
    return .of(state, struct {
        fn set(st: *Settings.State, i: usize) void {
            st.board_part = i;
        }
    }.set);
}

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
        x.actions.check_update = true;
    }
};

fn appAct(cx: *ui.Context, actions: *Actions, _: *Settings.State, name: []const u8) *AppAct {
    const x = cx.ui.arena().create(AppAct) catch unreachable;
    x.* = .{ .actions = actions, .name = .init(name) };
    return x;
}

fn act(cx: *ui.Context, actions: *Actions, state: *Settings.State, adapter: []const u8, ssid: []const u8) *Act {
    const x = cx.ui.arena().create(Act) catch unreachable;
    x.* = .{ .actions = actions, .state = state, .adapter = .of(adapter), .ssid_buf = undefined, .ssid_len = @intCast(ssid.len) };
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

/// An icon beside "GPU memory": pressing it offers the sizes in a menu
/// (those too big for the computer's memory dimmed).
const VideoMemoryMenu = struct {
    chosen: ?u16,
    ram_mib: u64,
    /// None if it cannot be changed (the system manager has not said).
    actions: ?*Actions,

    pub const State = struct {
        node: ?*ui.Node = null,
        actions: ?*Actions = null,
        chosen: ?u16 = null,
        ram_mib: u64 = 0,
        interaction: ui.Interaction = .{},

        fn open(st: *State) void {
            const n = st.node orelse return;
            const acts = st.actions orelse return;
            var items: [proto.video_memory_sizes.len]ui.menu.Item = undefined;
            inline for (proto.video_memory_sizes, &items) |mib, *item| {
                const chosen = st.chosen == mib;
                // (The menu keeps the labels: these last.)
                item.* = .{
                    .label = if (chosen) std.fmt.comptimePrint("{d} MB (chosen)", .{mib}) else std.fmt.comptimePrint("{d} MB", .{mib}),
                    .enabled = !chosen and proto.videoMemoryAllowed(mib, st.ram_mib),
                    .on_press = .of(acts, Actions.videoMemorySetter(mib)),
                };
            }
            const pos = n.position();
            n.ui.openMenu(n, .{ pos[0], pos[1] + n.size.h }, &items);
        }
    };

    pub fn build(self: *const VideoMemoryMenu, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const enabled = self.actions != null;
        state.node = cx.node;
        state.actions = self.actions;
        state.chosen = self.chosen;
        state.ram_mib = self.ram_mib;
        const size = 24;
        return cx.make(ui.Pressable{
            .on_press = if (enabled) .of(state, State.open) else null,
            .interaction = &state.interaction,
            .child = cx.make(ui.Decorated{
                .color = if (enabled and state.interaction.hovered) t.on_surface.withAlpha(0.08) else null,
                .radius = .all(size / 2),
                .child = cx.make(ui.SizedBox{ .width = size, .height = size, .child = cx.make(ui.Center{ .child = cx.make(ui.Icon{
                    .icon = .settings,
                    .size = 18,
                    .color = if (enabled) t.on_surface_variant else t.on_surface.withAlpha(0.38),
                }) }) }),
            }),
        });
    }
};

/// Makes the pages and their rows.
const Builder = struct {
    cx: *ui.Context,

    fn page(b: Builder, rows: []const ui.Widget) ui.Widget {
        const cx = b.cx;
        const children = cx.ui.arena().dupe(ui.Widget, rows) catch return cx.make(ui.Empty{});
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 10, .children = children });
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

pub fn decodeIconFile(gpa: std.mem.Allocator, path: [*:0]const u8) ?gfx.png.Decoded {
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

const sample_app_list = [_]store.App{
    .{ .name = "dazzle-demo", .title = "Demo", .description = "Spinning shapes, on the GPU", .icon = "icons/dazzle-demo.png", .file = "dazzle-demo.tar.xz", .size = 40 << 10, .sha256 = "" },
    .{ .name = "dazzle-files", .title = "Files", .description = "Your files", .icon = "icons/dazzle-files.png", .file = "dazzle-files.tar.xz", .size = 50 << 10, .sha256 = "" },
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
            u.frame(size[0], size[1], frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
            try testing.expect(!overflows(u.root.?));
        }
        // What shows maximized (in a smaller window, rows of the lists
        // further down are not made).
        frame_no += 1;
        u.frame(1920, 1036, frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
        texts(u.root.?, &all);
        if (page == .ethernet) {
            click(u, up(findText(u.root.?, "eth1").?, PillButton).?);
            frame_no += 1;
            u.frame(1920, 1036, frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
            texts(u.root.?, &all);
        }
        if (page == .apps) {
            click(u, up(findText(u.root.?, "Dazzle").?, ui.Pressable).?);
            for (test_sizes) |size| {
                frame_no += 1;
                u.frame(size[0], size[1], frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
                try testing.expect(!overflows(u.root.?));
            }
            frame_no += 1;
            u.frame(1920, 1036, frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
            texts(u.root.?, &all);
        }
        // The next page, from its tab.
        if (@as(usize, @intFromEnum(page)) + 1 < std.enums.values(Page).len) {
            const next: Page = @enumFromInt(@as(usize, @intFromEnum(page)) + 1);
            click(u, up(findText(u.root.?, next.label()).?, Tab).?);
            try testing.expectEqual(next, shownPage(u));
        }
    }
    for ([_][]const u8{
        "574d538",
        "6.12.0 (armv6l)",
        "Raspberry Pi Zero W Rev 1.1",
        "a1b2c3d4",
        "Resources",
        "23% busy (1 core)",
        "CPU Memory",
        "134 MB of 434 MB in use",
        "4.0 MB of 64 MB in use",
        "System 600 KB",
        "Apps 2.0 MB",
        "User 0 bytes",
        "Free 300 MB",
        "Ethernet",
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
        // The software list.
        "Software",
        "Dazzle",
        "Spinning shapes, on the GPU",
        "Install",
        "Remove",
        "All apps updated",
    }) |want| {
        if (std.mem.indexOf(u8, all.items, want) == null) {
            std.debug.print("missing \"{s}\" in:\n{s}\n", .{ want, all.items });
            return error.TestUnexpectedResult;
        }
    }
    // In a small window, only the networks that show are made.
    u.root.?.state(Settings.State).page = .wifi;
    u.frame(min_size[0], min_size[1], frame_no + 1, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
    u.frame(min_size[0], min_size[1], frame_no + 2, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
    try testing.expect(findText(u.root.?, "Home") != null);
    try testing.expect(findText(u.root.?, "bad?name") == null);
    // The build is on the Software page, not beside the title; the hardware
    // is the board alone; Catalogue/2 apps/From url are gone.
    for ([_][]const u8{ "Dazzle build", "Hardware\n", "Chip", "GPU\n", "Revision", "In use", "Up for", "Hostname", "Catalogue", "2 apps", "From https://example.com/apps" }) |gone| {
        try testing.expect(std.mem.indexOf(u8, all.items, gone) == null);
    }
}

test "without a network adapter, the network page says so" {
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

test "the Wi-Fi page says when it cannot list networks" {
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

test "choosing between multiple Wi-Fi and Ethernet adapters with pill buttons" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var report = sampleWifi();
    // With a single Wi-Fi adapter, no pill button is shown.
    var actions: Actions = .{};
    u.frame(1920, 960, 0, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(findType(u.root.?, PillButton) == null);

    // With two Wi-Fi adapters, pill buttons appear at the top.
    var a0: info.manager.Adapter = .{ .mac = .{ 0xb8, 0x27, 0xeb, 1, 2, 3 }, .up = true };
    a0.setName("wlan0");
    var a1: info.manager.Adapter = .{ .mac = .{ 0x00, 0xe0, 0x4c, 4, 5, 6 }, .up = true };
    a1.setName("wlan1");
    report.addAdapter(a0);
    report.addAdapter(a1);
    u.frame(1920, 960, 1, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(findText(u.root.?, "wlan0 (b8:27:eb:01:02:03)") != null);
    try testing.expect(findText(u.root.?, "wlan1 (00:e0:4c:04:05:06)") == null);
    click(u, up(findText(u.root.?, "wlan1").?, PillButton).?);
    try testing.expectEqualStrings("wlan1", actions.wifi_adapter.?.slice());
    u.frame(1920, 960, 2, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(findText(u.root.?, "wlan1 (00:e0:4c:04:05:06)") != null);
    try testing.expect(findText(u.root.?, "wlan0 (b8:27:eb:01:02:03)") == null);

    // Ethernet: sample() has eth0 and eth1, selectable via pill buttons.
    click(u, up(findText(u.root.?, "Ethernet").?, Tab).?);
    u.frame(1920, 960, 3, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(findText(u.root.?, "Connected at 100 Mb/s") != null);
    try testing.expect(findText(u.root.?, "Not connected: no cable") == null);
    click(u, up(findText(u.root.?, "eth1").?, PillButton).?);
    u.frame(1920, 960, 4, Settings{ .commit = "x", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &report });
    try testing.expect(findText(u.root.?, "Not connected: no cable") != null);
    try testing.expect(findText(u.root.?, "Connected at 100 Mb/s") == null);
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
    try testing.expect(findText(u.root.?, "All apps updated") != null);
    try testing.expect(findText(u.root.?, "Update all") == null);
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

    // No list yet.
    settings.apps = .{};
    u.frame(1920, 960, 4, settings);
    try testing.expect(findText(u.root.?, "No list of apps yet: is the network up?") != null);
}

test "updates: offered, downloaded, installed, then a restart" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "de14aa2 (7 October 2026)", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .apps = sample_apps, .update = .{ .status = .available, .available = "0123abc (8 October 2026)" } };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(1920, 960, 1, settings);
    try testing.expect(findText(u.root.?, "Dazzle 0123abc (8 October 2026) is available") != null);
    try testing.expect(findText(u.root.?, "1 update available") != null);
    // "Update all" is to the left of "Refresh".
    const update_all_btn = up(findText(u.root.?, "Update all").?, ui.OutlinedButton).?;
    const refresh_btn = up(findText(u.root.?, "Refresh").?, ui.OutlinedButton).?;
    try testing.expect(update_all_btn.position()[0] < refresh_btn.position()[0]);
    click(u, update_all_btn);
    try testing.expect(actions.update_all);
    actions = .{};

    // With both an OS update and an app update: "2 updates available".
    settings.apps.updatable = &.{ true, false };
    u.frame(1920, 960, 2, settings);
    try testing.expect(findText(u.root.?, "2 updates available") != null);

    // Build and kernel details are shown when Dazzle is expanded.
    try testing.expect(findText(u.root.?, "de14aa2 (7 October 2026)") == null);
    click(u, up(findText(u.root.?, "Dazzle").?, ui.Pressable).?);
    u.frame(1920, 960, 3, settings);
    try testing.expect(findText(u.root.?, "de14aa2 (7 October 2026)") != null);
    try testing.expect(findText(u.root.?, "6.12.0 (armv6l)") != null);
    click(u, up(findText(u.root.?, "Download").?, ui.OutlinedButton).?);
    try testing.expect(actions.download_update);

    // Under way: no update buttons.
    for ([_]update.Status{ .checking, .downloading, .installing }) |s| {
        settings.update = .{ .status = s };
        u.frame(1920, 960, 4, settings);
        try testing.expect(up(findText(u.root.?, "Dazzle").?, ui.Row) != null);
        try testing.expect(findText(u.root.?, "Download") == null and findText(u.root.?, "Restart") == null);
    }
    settings.apps.updatable = &.{};
    settings.update = .{ .status = .ready };
    u.frame(1920, 960, 5, settings);
    try testing.expect(findText(u.root.?, "The update is installed: restart to use it") != null);
    click(u, up(findText(u.root.?, "Restart").?, ui.OutlinedButton).?);
    try testing.expect(actions.restart);

    settings.update = .{ .status = .current };
    u.frame(1920, 960, 6, settings);
    try testing.expect(findText(u.root.?, "The operating system · 600 KB") != null);
    try testing.expect(findText(u.root.?, "All apps updated") != null);
    try testing.expect(findText(u.root.?, "Update all") == null);
    click(u, up(findText(u.root.?, "Refresh").?, ui.OutlinedButton).?);
    try testing.expect(actions.check_update and actions.refresh_apps);

    settings.update = .{ .status = .unknown, .message = "Cannot check for updates: the server could not be reached (is the network up?)" };
    u.frame(1920, 960, 7, settings);
    try testing.expect(findText(u.root.?, "Cannot check for updates: the server could not be reached (is the network up?)") != null);
    settings.update = .{};
    u.frame(1920, 960, 8, settings);
    try testing.expect(findText(u.root.?, "The operating system · 600 KB") != null);
}

test "video memory: choosing a size, then a restart" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "de14aa2", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .video_memory = .{ .now = 128, .next = 128 } };
    u.frame(1280, 720, 0, settings);
    u.root.?.state(Settings.State).page = .resources;
    u.frame(1280, 720, 1, settings);
    try testing.expect(findText(u.root.?, "Restart") == null);
    click(u, findType(u.root.?, VideoMemoryMenu).?);
    u.frame(1280, 720, 2, settings);
    // 434 MB of memory: no more than half of it.
    const menu = u.menu.?.items;
    try testing.expectEqualStrings("128 MB (chosen)", menu[2].label);
    try testing.expect(!menu[2].enabled);
    try testing.expect(menu[3].enabled and !menu[4].enabled);
    click(u, findText(u.menu_root.?, "192 MB").?);
    try testing.expectEqual(@as(?u16, 192), actions.video_memory);

    settings.video_memory = .{ .now = 128, .next = 192 };
    u.frame(1280, 720, 3, settings);
    try testing.expect(findText(u.root.?, "192 MB after a restart") != null);
    click(u, up(findText(u.root.?, "Restart").?, ui.OutlinedButton).?);
    try testing.expect(actions.restart);

    // Not known: nothing to change.
    settings.video_memory = .{};
    u.frame(1280, 720, 4, settings);
    actions = .{};
    click(u, findType(u.root.?, VideoMemoryMenu).?);
    try testing.expect(u.menu == null);
}

test "the board, drawn: picking a part says what it is" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var d = sample();
    const wifi = sampleWifi();
    d.sys.model = .of("Raspberry Pi 3 Model B Plus Rev 1.3");
    var n: u64 = 0;
    const draw = struct {
        fn frame(uu: *ui.Ui, dd: anytype, w: *const info.manager.Report, nn: *u64, size: [2]u32) void {
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Settings{ .commit = "574d538", .system = &dd.sys, .usage = dd.usage, .network = &dd.net, .manager = w, .apps = sample_apps });
        }
    }.frame;
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    u.root.?.state(Settings.State).page = .board;
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    // The processor to begin with.
    try testing.expect(findText(u.root.?, "Processor and graphics: BCM2837B0") != null);
    try testing.expect(findText(u.root.?, "23% busy, at 48.3 °C") != null);

    // Clicking the Ethernet port.
    const view = findType(u.root.?, BoardView).?;
    const drawing = board.forModel("Raspberry Pi 3 Model B Plus Rev 1.3").?;
    const r = drawing.bounds();
    const scale = @min(view.size.w / r.w, view.size.h / r.h);
    const origin = view.position();
    const x0 = origin[0] + (view.size.w - r.w * scale) / 2 - r.x * scale;
    const y0 = origin[1] + (view.size.h - r.h * scale) / 2 - r.y * scale;
    const p: ui.Point = .{ x0 + 76 * scale, y0 + 45 * scale };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
    draw(u, &d, &wifi, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "Ethernet") != null);
    try testing.expect(findText(u.root.?, "The wired network") != null);

    // Every board fits, at every size.
    for ([_][]const u8{ "Raspberry Pi Model B Rev 2", "Raspberry Pi Zero 2 W Rev 1.0", "Raspberry Pi Compute Module 3 Rev 1.0", "Raspberry Pi 4 Model B Rev 1.4", "Raspberry Pi Compute Module 4 Rev 1.0", "Raspberry Pi 5 Model B Rev 1.0", "Raspberry Pi Compute Module 5 Rev 1.0", "Something else" }) |model| {
        d.sys.model = .of(model);
        for (test_sizes) |size| {
            draw(u, &d, &wifi, &n, size);
            try testing.expect(!overflows(u.root.?));
        }
    }
    try testing.expect(findText(u.root.?, "There is no drawing of this board") != null);
}

test "the language and keyboard: picking one keeps the other" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var actions: Actions = .{};
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .locale = .{ .language = .en_gb, .keyboard = .gb } };
    u.frame(1600, 900, 0, settings);
    u.root.?.state(Settings.State).page = .language;
    u.frame(1600, 900, 1, settings);
    try testing.expect(findText(u.root.?, "English (Canada)") != null);
    click(u, findText(u.root.?, "English (Canada)").?);
    try testing.expectEqual(locale.Settings{ .language = .en_ca, .keyboard = .gb }, actions.locale.?);
    click(u, findText(u.root.?, "English (US)").?);
    try testing.expectEqual(locale.Settings{ .language = .en_gb, .keyboard = .us }, actions.locale.?);
    try testing.expect(findType(u.root.?, ui.TextField) != null);
}

test "the USB devices: each with what it is, and the board's own" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var devices: usb.Devices = .{};
    devices.items[0] = .{ .kind = .keyboard, .speed_mbps = 1.5, .vendor_id = 0x046d, .product_id = 0xc31c };
    devices.items[0].product.set("USB Keyboard");
    devices.items[0].manufacturer.set("Logitech");
    devices.items[1] = .{ .kind = .storage, .speed_mbps = 480, .vendor_id = 0x0781, .product_id = 0x5567 };
    devices.items[2] = .{ .kind = .network, .speed_mbps = 480, .built_in = true, .vendor_id = 0x0424, .product_id = 0xec00 };
    devices.len = 3;
    var settings: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .usb = &devices };
    u.frame(1600, 900, 0, settings);
    u.root.?.state(Settings.State).page = .usb;
    for (test_sizes) |size| {
        u.frame(size[0], size[1], 1, settings);
        try testing.expect(!overflows(u.root.?));
    }
    u.frame(1600, 900, 2, settings);
    try testing.expect(findText(u.root.?, "USB Keyboard") != null);
    try testing.expect(findText(u.root.?, "Keyboard  \u{b7}  Logitech  \u{b7}  1.5 Mb/s") != null);
    try testing.expect(findText(u.root.?, "USB device 0781:5567") != null);
    try testing.expect(findText(u.root.?, "Network adapter  \u{b7}  480 Mb/s  \u{b7}  Part of the board") != null);
    // Nothing: it says so.
    const none: usb.Devices = .{};
    settings.usb = &none;
    u.frame(1600, 900, 3, settings);
    try testing.expect(findText(u.root.?, "Nothing is plugged in") != null);
}

test "the log: newest first, or only its warnings and errors" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    var l: log.Log = .{};
    l.add("6,1,1500000,-;dazzle: starting as init\n");
    l.add("4,2,2000000,-;dazzle: network: no answer from the time servers\n");
    l.add("3,3,3250000,-;dazzle-files: error: OutOfMemory\n");
    l.add("6,4,65000000,-;dazzle-shell: started\n");
    const settings: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .log = &l };
    u.frame(1600, 900, 0, settings);
    const st = u.root.?.state(Settings.State);
    st.page = .log;
    for (test_sizes) |size| {
        u.frame(size[0], size[1], 1, settings);
        try testing.expect(!overflows(u.root.?));
    }
    u.frame(1600, 900, 2, settings);
    // Newest first, with when.
    const newest = findText(u.root.?, "dazzle-shell: started").?;
    const oldest = findText(u.root.?, "dazzle: starting as init").?;
    try testing.expect(newest.position()[1] < oldest.position()[1]);
    try testing.expect(findText(u.root.?, "1:05.000") != null);
    try testing.expect(findText(u.root.?, "3.250") != null);
    // Only the problems.
    click(u, up(findText(u.root.?, "Only warnings and errors").?, ui.Switch).?);
    u.frame(1600, 900, 3, settings);
    try testing.expect(findText(u.root.?, "dazzle-shell: started") == null);
    try testing.expect(findText(u.root.?, "dazzle-files: error: OutOfMemory") != null);
    try testing.expect(findText(u.root.?, "dazzle: network: no answer from the time servers") != null);
    // Not read yet, and none to show.
    const reading: Settings = .{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net };
    u.frame(1600, 900, 4, reading);
    try testing.expect(findText(u.root.?, "Reading the log…") != null);
}

test "the GPIO pins: the header as it is laid out, and setting a pin up" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var d = sample();
    var actions: Actions = .{};
    var pins: gpio.Pins = .{ .opened = true, .chip = .{ .fd = -1 } };
    pins.lines[17] = .{ .function = .output, .high = true };
    pins.lines[4] = .{ .function = .input, .high = true };
    pins.lines[14] = .{ .function = .alt0, .used = true };
    @memcpy(pins.lines[14].consumer_buf[0..6], "serial");
    pins.lines[14].consumer_len = 6;
    const settings: Settings = .{ .commit = "574d538", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .gpio = &pins };
    u.frame(1600, 900, 0, settings);
    u.root.?.state(Settings.State).page = .gpio;
    for ([_][]const u8{ "Raspberry Pi 3 Model B Rev 1.2", "Raspberry Pi Model B Rev 1", "Raspberry Pi Compute Module 3 Rev 1.0" }) |model| {
        d.sys.model = .of(model);
        for (test_sizes) |size| {
            u.frame(size[0], size[1], 1, settings);
            try testing.expect(!overflows(u.root.?));
        }
    }
    d.sys.model = .of("Raspberry Pi 3 Model B Rev 1.2");
    u.frame(1600, 900, 2, settings);
    // GPIO 17 is picked to start with: pin 11, an output, high.
    try testing.expect(findText(u.root.?, "GPIO 17, pin 11") != null);
    try testing.expect(findText(u.root.?, "Output, high") != null);
    click(u, findText(u.root.?, "Output, low").?);
    try testing.expectEqual(Actions.GpioChange{ .pin = 17, .mode = .output_low }, actions.gpio.?);
    // A pin a driver has cannot be changed.
    click(u, findText(u.root.?, "GPIO 14 (TXD)").?);
    u.frame(1600, 900, 3, settings);
    try testing.expect(findText(u.root.?, "GPIO 14, pin 8") != null);
    try testing.expect(findText(u.root.?, "UART 0 transmit") != null);
    try testing.expect(findText(u.root.?, "In use by serial, so it cannot be changed here") != null);
    try testing.expect(findText(u.root.?, "Input, pulled up") == null);
    // An input pin starts with its default pull, and can be changed.
    click(u, findText(u.root.?, "GPIO 4 (GPCLK0)").?);
    u.frame(1600, 900, 4, settings);
    try testing.expect(findText(u.root.?, "GPIO 4, pin 7") != null);
    click(u, findText(u.root.?, "Input, pulled down").?);
    try testing.expectEqual(Actions.GpioChange{ .pin = 4, .mode = .input_pull_down }, actions.gpio.?);
    // The pins cannot be read.
    pins.read_failure = "Not allowed to use the GPIO";
    u.frame(1600, 900, 5, settings);
    try testing.expect(findText(u.root.?, "Not allowed to use the GPIO") != null);
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
        .{ .name = "dazzle-demo", .title = "Demo", .version = "abc", .time = 1000, .icon = "icons/dazzle-demo.png", .file = "dazzle-demo.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-files", .title = "Files", .version = "abc", .time = 1000, .icon = "icons/dazzle-files.png", .file = "dazzle-files.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-camera", .title = "Camera", .version = "abc", .time = 1000, .icon = "icons/dazzle-camera.png", .file = "dazzle-camera.tar.xz", .size = 1, .sha256 = "" },
        .{ .name = "dazzle-maps", .title = "Maps", .version = "abc", .time = 1000, .icon = "icons/dazzle-maps.png", .file = "dazzle-maps.tar.xz", .size = 1, .sha256 = "" },
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
    const d = sample();
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
    u.frame(min_size[0], min_size[1], 0, settings);
    u.root.?.state(Settings.State).page = .apps;
    u.frame(min_size[0], min_size[1], 1, settings);

    const status_before = findText(u.root.?, "All apps updated").?.position()[1];
    const refresh_before = findText(u.root.?, "Refresh").?.position()[1];
    const dazzle_before = findText(u.root.?, "Dazzle").?.position()[1];

    // Scroll the list down with the mouse wheel over the Software list.
    u.pointerScroll(.{ 400, 200 }, 0, 50);
    u.frame(min_size[0], min_size[1], 2, settings);

    const status_after = findText(u.root.?, "All apps updated").?.position()[1];
    const refresh_after = findText(u.root.?, "Refresh").?.position()[1];
    const dazzle_after = findText(u.root.?, "Dazzle").?.position()[1];

    // The list scrolled up, while the bottom status and Refresh button did not move.
    try testing.expect(dazzle_after < dazzle_before);
    try testing.expectEqual(status_before, status_after);
    try testing.expectEqual(refresh_before, refresh_after);
    try testing.expect(status_after + 20 <= @as(f32, @floatFromInt(min_size[1])));
}





