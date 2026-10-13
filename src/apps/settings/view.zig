//! The settings app's window, as widgets: pages, chosen with the tabs on
//! the left, about the Wi-Fi networks around, Ethernet, the board,
//! software, resources in use, language and keyboard,
//! and the system's log. What is asked of the network manager, and of the
//! store, goes to the main loop through `Actions`.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const info = @import("info.zig");
const locale = @import("locale");
const store = @import("store");
const usb = @import("usb.zig");
const gpio = @import("gpio.zig");
const log = @import("log.zig");

pub const wifi_view = @import("wifi_view.zig");
pub const ethernet_view = @import("ethernet_view.zig");
pub const board_view = @import("board_view.zig");
pub const software_view = @import("software_view.zig");
pub const resources_view = @import("resources_view.zig");
pub const language_view = @import("language_view.zig");
pub const log_view = @import("log_view.zig");

/// What the window asks of the network manager; the main loop sends it,
/// then clears it.
pub const Actions = struct {
    connect: ?Join = null,
    hotspot: ?Join = null,
    disconnect: bool = false,
    /// The Wi-Fi adapter chosen (when there is more than one), and how it gets its address.
    wifi_adapter: ?info.Str(16) = null,
    wifi_addressing: ?info.manager.Addressing = null,
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
    /// The software server URL (`https://...`), or empty (`""`) to revert to
    /// the default server.
    software_server: ?info.Str(store.max_url_len) = null,
    /// The language and keyboard to use.
    locale: ?locale.Settings = null,
    /// A GPIO pin to set up, and how.
    gpio: ?GpioChange = null,
    /// The video memory to have from the next start, in MiB.
    video_memory: ?u16 = null,

    pub const GpioChange = struct { pin: u6, mode: gpio.Mode };

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
        network: info.manager.HotspotNetwork = .{},
        upstream: info.Str(16) = .{},

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
pub const max_page_width = 960;

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
    apps: software_view.Apps = .{},
    update: software_view.Update = .{},
    video_memory: resources_view.VideoMemory = .{},
    /// The title bar's buttons (close, and maximize, which shows whether
    /// the window is), and pressing the bar (to move the window).
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub const State = struct {
        /// The page shown.
        page: Page = .wifi,
        wifi: wifi_view.State = .{},
        ethernet: ethernet_view.State = .{},
        board: board_view.State = .{},
        software: software_view.State = .{},
        resources: resources_view.State = .{},
        log: log_view.State = .{},

        fn selectPage(st: *State, idx: usize) void {
            if (idx < std.meta.fields(Page).len) st.page = @enumFromInt(idx);
        }
    };

    pub fn build(self: *const Settings, cx: *ui.Context, state: *State) ui.Widget {
        const b: Builder = .{ .cx = cx };
        const t = cx.theme();
        var rail_items: [std.meta.fields(Page).len]ui.NavigationRail.Item = undefined;
        inline for (&rail_items, std.meta.fields(Page)) |*item, field| {
            const p: Page = @enumFromInt(field.value);
            item.* = .{ .label = p.label(), .icon = p.icon() };
        }
        const sidebar = cx.make(ui.NavigationRail{
            .items = &rail_items,
            .selected = @intFromEnum(state.page),
            .on_select = .of(state, State.selectPage),
        });
        // A page longer than the window scrolls; another page starts at
        // its top. In a wide window the page is no wider than reads well,
        // in the middle.
        const right = switch (state.page) {
            .wifi => wifi_view.build(self, b, &state.wifi),
            .ethernet => b.scroll(.ethernet, ethernet_view.build(self, b, &state.ethernet)),
            .board => board_view.build(self, b, &state.board),
            .apps => software_view.build(self, b, &state.software),
            .resources => resources_view.build(self, b, &state.resources),
            .language => b.scroll(.language, language_view.build(self, b)),
            .log => b.scroll(.log, log_view.build(self, b, &state.log)),
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
};

/// The pages, in the order of their tabs.
pub const Page = enum {
    wifi,
    ethernet,
    board,
    apps,
    resources,
    language,
    log,

    pub fn label(p: Page) []const u8 {
        return switch (p) {
            .wifi => wifi_view.label,
            .ethernet => ethernet_view.label,
            .board => board_view.label,
            .apps => software_view.label,
            .resources => resources_view.label,
            .language => language_view.label,
            .log => log_view.label,
        };
    }

    pub fn icon(p: Page) ui.icons.Icon {
        return switch (p) {
            .wifi => wifi_view.icon,
            .ethernet => ethernet_view.icon,
            .board => board_view.icon,
            .apps => software_view.icon,
            .resources => resources_view.icon,
            .language => language_view.icon,
            .log => log_view.icon,
        };
    }
};

/// The page `u` (running a `Settings`) shows.
pub fn shownPage(u: *ui.Ui) Page {
    const root = u.root orelse return .wifi;
    if (!root.widget.is(Settings)) return .wifi;
    return root.state(Settings.State).page;
}

/// Whether a Wi-Fi network is selected in `u` (so its join form is open).
pub fn wifiNetworkSelected(u: *ui.Ui) bool {
    const root = u.root orelse return false;
    if (!root.widget.is(Settings)) return false;
    return root.state(Settings.State).wifi.has_selected;
}

/// Shows page `p` in `u` (running a `Settings`); false if the window is
/// not built yet.
pub fn showPage(u: *ui.Ui, p: Page) bool {
    const root = u.root orelse return false;
    if (!root.widget.is(Settings)) return false;
    root.state(Settings.State).page = p;
    return true;
}

/// Shows the Board page with the GPIO header selected in `u` (running a
/// `Settings`); false if the window is not built yet.
pub fn showGpio(u: *ui.Ui) bool {
    const root = u.root orelse return false;
    if (!root.widget.is(Settings)) return false;
    const st = root.state(Settings.State);
    st.page = .board;
    st.board.part = null;
    st.board.select_gpio = true;
    return true;
}

pub fn orUnknown(s: []const u8) []const u8 {
    return if (s.len == 0) "Unknown" else s;
}

/// Makes the pages and their rows.
pub const Builder = struct {
    cx: *ui.Context,

    pub fn page(b: Builder, rows: []const ui.Widget) ui.Widget {
        const cx = b.cx;
        const children = cx.ui.arena().dupe(ui.Widget, rows) catch return cx.make(ui.Empty{});
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 10, .children = children });
    }

    pub fn scroll(b: Builder, p: Page, child: ui.Widget) ui.Widget {
        const cx = b.cx;
        return cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Align{
            .alignment = .top_center,
            .child = cx.make(ui.ConstrainedBox{ .constraints = .{ .max_w = max_page_width }, .child = child }),
        }) }) }).withKey(@as(u64, @intFromEnum(p)) + 1);
    }

    pub fn label(b: Builder, text: []const u8) ui.Widget {
        const cx = b.cx;
        return cx.make(ui.SizedBox{ .width = 150, .child = cx.make(ui.Text{ .text = text, .style = .{ .size = 18, .color = cx.ui.theme.on_surface_variant }, .wrap = false }) });
    }

    pub fn value(b: Builder, text: []const u8) ui.Widget {
        return b.cx.make(ui.Text{ .text = text, .style = .{ .size = 18, .color = b.cx.ui.theme.on_surface } });
    }

    /// A label and its value.
    pub fn item(b: Builder, name: []const u8, text: []const u8) ui.Widget {
        return b.cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
            b.label(name),
            b.cx.make(ui.Expanded{ .child = b.value(text) }),
        } });
    }
};

const testing = std.testing;
const font = @import("font");

pub const sample_app_list = [_]store.App{
    .{ .name = "dazzle-demo", .title = "Demo", .description = "Spinning shapes, on the GPU", .icon = "icons/dazzle-demo.png", .file = "dazzle-demo.tar.xz", .size = 40 << 10, .sha256 = "" },
    .{ .name = "dazzle-files", .title = "Files", .description = "Your files", .icon = "icons/dazzle-files.png", .file = "dazzle-files.tar.xz", .size = 50 << 10, .sha256 = "" },
};
pub const sample_apps: software_view.Apps = .{ .list = &sample_app_list, .installed = &.{ true, false }, .source = "https://example.com/apps", .default_source = "https://example.com/apps" };

pub fn sample() struct { sys: info.System, net: info.Network, usage: info.Usage } {
    const sys: info.System = .{ .model = .of("Raspberry Pi Zero W Rev 1.1"), .cores = 1, .serial = .of("a1b2c3d4"), .kernel = .of("6.12.0 (armv6l)"), .hostname = .of("awesome-elephant") };
    var net: info.Network = .{ .gateway = .{ 192, 168, 1, 1 } };
    net.interfaces[0] = .{ .name = .of("eth0"), .state = .of("up"), .carrier = true, .mac = .of("00:e0:4c:68:01:02"), .ip = .{ 192, 168, 1, 42 }, .prefix = 24, .speed = 100, .rx_bytes = 12 << 20, .tx_bytes = 3 << 20 };
    net.interfaces[1] = .{ .name = .of("eth1"), .state = .of("down") };
    net.len = 1;
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

pub fn sampleWifi() info.manager.Report {
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

pub fn texts(node: *ui.Node, out: *std.ArrayList(u8)) void {
    if (node.widget.is(ui.Text)) {
        out.appendSlice(testing.allocator, node.widget.as(ui.Text).?.text) catch {};
        out.append(testing.allocator, '\n') catch {};
    }
    for (node.children.items) |ch| texts(ch, out);
}

pub fn overflows(node: *ui.Node) bool {
    const o = node.overflow;
    if (o.left > 0 or o.top > 0 or o.right > 0 or o.bottom > 0) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

/// The sizes to lay out at: the smallest the window may be, as narrow
/// and as short as it may be, a restored window's first size on a 1080p
/// screen, and maximized on a 720p and a 1080p screen. Everything is the
/// same size in pixels in each.
pub const test_sizes = [_][2]u32{
    min_size,
    .{ min_size[0], 1036 },
    .{ 1920, min_size[1] },
    .{ 960, 518 },
    .{ 1280, 668 },
    .{ 1920, 1036 },
};

pub fn findText(node: *ui.Node, text: []const u8) ?*ui.Node {
    if (node.widget.as(ui.Text)) |t| if (std.mem.eql(u8, t.text, text)) return node;
    for (node.children.items) |ch| if (findText(ch, text)) |n| return n;
    return null;
}

pub fn findType(node: *ui.Node, comptime T: type) ?*ui.Node {
    if (node.widget.is(T)) return node;
    for (node.children.items) |ch| if (findType(ch, T)) |n| return n;
    return null;
}

/// The nearest node above `n` (or `n`) whose widget is a `T`.
pub fn up(n: *ui.Node, comptime T: type) ?*ui.Node {
    var at: ?*ui.Node = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

pub fn click(u: *ui.Ui, n: *ui.Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + 4, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
}

test "everything is shown, and fits from the smallest window to the biggest" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var d = sample();
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
            d.net.len = 2;
            frame_no += 1;
            u.frame(1920, 1036, frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
            click(u, up(findText(u.root.?, "eth1").?, ui.PillButton).?);
            frame_no += 1;
            u.frame(1920, 1036, frame_no, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .manager = &wifi, .apps = sample_apps, .video_memory = .{ .now = 128, .next = 192 } });
            texts(u.root.?, &all);
            d.net.len = 1;
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
            click(u, up(findText(u.root.?, next.label()).?, ui.Pressable).?);
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
        "Not connected: no cable",
        "b8:27:eb:01:02:03",
        "Not connected, scanning…",
        // Every network: the page scrolls.
        "Further",
        "bad?name",
        "Home",
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
    // All network names are horizontally aligned, whether locked or open.
    try testing.expectEqual(findText(u.root.?, "Home").?.position()[0], findText(u.root.?, "Cafe").?.position()[0]);
    // The build is on the Software page, not beside the title; the hardware
    // is the board alone; Catalogue/2 apps/From url and dBm/adapter name/WPA2/GHz on Wi-Fi are gone.
    for ([_][]const u8{ "Dazzle build", "Hardware\n", "Chip", "GPU\n", "Revision", "In use", "Up for", "Hostname", "Catalogue", "2 apps", "From https://example.com/apps", "dBm", "wlan0", "WPA2", "GHz", "Traffic", "Gateway" }) |gone| {
        try testing.expect(std.mem.indexOf(u8, all.items, gone) == null);
    }
}
