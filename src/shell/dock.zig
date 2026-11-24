//! The dock at the bottom of the screen: a rounded box floating in the
//! middle, just big enough for an icon for each app in /data/apps and for
//! the shell's own (Settings), and the status box. It slides down out of
//! the way of a fullscreen window, and back up after (`slideTo`). Clicking one starts the app or, if it
//! is running, brings its window to the front (apps run once each).
//!
//! An app is a directory /data/apps/<name> holding its program, also called
//! <name>, and the files it needs. The shell's own apps are programs beside
//! it in /os/shell, and cannot be removed. Its icon is a Material icon
//! (named in <program>.icon, beside the program: "folder") or, without
//! one, its initial, on a coloured square, with a dot under it while it
//! runs.
//!
//! Apps come and go (setup and Settings install them, and Settings removes
//! them): `AppsWatch` notices /data/apps changing, and `rescan` lists the
//! apps again, keeping running ones' processes. The sound and appearance
//! settings are kept there too, and `AppsWatch` notices those changing.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const evdev = sys.evdev;
const kete = @import("kete");
const glass = @import("glass.zig");
const kete_panel = @import("kete_panel.zig");
const clock = @import("clock.zig");
const ui_icons = @import("ui_icons.zig");
const icons = @import("icons");
const audio = @import("audio");
const theme_settings = @import("appearance");
const store = @import("store");

pub const apps_dir = sys.system.apps_dir;
pub const appearance_file = theme_settings.settings_file;

pub const Theme = enum {
    dark,
    light,

    pub const Colors = struct {
        background: u32,
        hover_background: u32,
        status_border: u32,
        dot: u32,
        status_active: u32,
        status_inactive: u32,
        /// An app's name over its icon, when the pointer rests on it.
        tooltip_background: u32,
        tooltip_text: u32,
    };

    pub fn colors(t: Theme) Colors {
        return switch (t) {
            .dark => .{
                .background = 0xff1c2a4a,
                .hover_background = 0xff2c3e66,
                .status_border = 0xff3b507a,
                .dot = 0xffe8eefc,
                .status_active = 0xffffffff,
                .status_inactive = 0x40ffffff,
                .tooltip_background = 0xffe8eefc,
                .tooltip_text = 0xff1c2a4a,
            },
            .light => .{
                .background = 0xffe8eef8,
                .hover_background = 0xffd0dcf0,
                .status_border = 0xffb0c2e0,
                .dot = 0xff1c2a4a,
                .status_active = 0xff1c2a4a,
                .status_inactive = 0x401c2a4a,
                .tooltip_background = 0xff1c2a4a,
                .tooltip_text = 0xffe8eef8,
            },
        };
    }
};

/// The theme and the desktop's background image, as chosen in Settings
/// (and Files).
pub const Appearance = struct {
    theme: Theme = .dark,
    image: theme_settings.ImagePath = theme_settings.Settings.default_image,
    /// The dock shows the time, and the network's status.
    clock: bool = true,
    network: bool = true,

    pub fn parse(text: []const u8) Appearance {
        const s = theme_settings.Settings.parse(text);
        return .{
            .theme = switch (s.theme) {
                .dark => .dark,
                .light => .light,
            },
            .image = s.image,
            .clock = s.clock,
            .network = s.network,
        };
    }
};

pub fn readAppearance() Appearance {
    var buf: [theme_settings.Settings.max_text]u8 = undefined;
    return .parse(sys.readFile(appearance_file, &buf) orelse "");
}

const background = Theme.dark.colors().background;
/// The box's colour as it is drawn: see-through.
fn glassy(color: u32) u32 {
    return @as(u32, glass.alpha) << 24 | (color & 0x00ffffff);
}
const hover_background = Theme.dark.colors().hover_background;
const status_border = Theme.dark.colors().status_border;
const dot_color = Theme.dark.colors().dot;
/// Icon colours, picked by the app's name.
const palette = [_]u32{ 0xff3f7ee8, 0xffe8743f, 0xff3fb86e, 0xffb04fd6, 0xffe8b33f, 0xff3fb8c4, 0xffe84f6a };

/// How the system is connected, as the dock shows it.
pub const NetworkStatus = union(enum) {
    /// Not connected: whether it has Wi-Fi (its icon struck out), or not
    /// (a globe struck out).
    offline: struct { wifi: bool = false },
    /// Joined to a Wi-Fi network, its signal strength in bars (0..4).
    wifi: u8,
    /// Sharing a connection as a Wi-Fi hotspot.
    hotspot,
    /// Wired Ethernet, with an address.
    ethernet,

    pub fn icon(n: NetworkStatus) icons.Icon {
        return switch (n) {
            .offline => |o| if (o.wifi) .signal_wifi_off else .public_off,
            .wifi => |bars| switch (bars) {
                0 => .signal_wifi_0_bar,
                1 => .network_wifi_1_bar,
                2 => .network_wifi_2_bar,
                3 => .network_wifi_3_bar,
                else => .signal_wifi_4_bar,
            },
            .hotspot => .wifi_tethering,
            .ethernet => .lan,
        };
    }

    pub fn connected(n: NetworkStatus) bool {
        return n != .offline;
    }
};

/// Bytes the network interfaces (all but loopback) have received and sent.
pub const Traffic = struct {
    received: u64 = 0,
    sent: u64 = 0,
};

/// Whether data moved each way since the last look.
pub const Activity = struct {
    receiving: bool = false,
    sending: bool = false,

    /// What moved between `before` and `now`.
    pub fn between(before: Traffic, now: Traffic) Activity {
        return .{ .receiving = now.received != before.received, .sending = now.sent != before.sent };
    }
};

/// The interfaces' byte counts, from /sys/class/net/*/statistics.
pub fn readTraffic() Traffic {
    var t: Traffic = .{};
    const dir = sys.open("/sys/class/net", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return t;
    defer sys.close(dir);
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch break;
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "lo")) continue;
            t.received +%= readCounter(name, "rx_bytes");
            t.sent +%= readCounter(name, "tx_bytes");
        }
    }
    return t;
}

fn readCounter(interface: []const u8, counter: []const u8) u64 {
    var pbuf: [128]u8 = undefined;
    const path = std.mem.printSentinel(&pbuf, "/sys/class/net/{s}/statistics/{s}", .{ interface, counter }, 0) catch return 0;
    var vbuf: [32]u8 = undefined;
    const text = sys.readFile(path, &vbuf) orelse return 0;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch 0;
}

pub const VolumeStatus = struct {
    volume: u8 = 80,
    muted: bool = false,

    pub fn icon(v: VolumeStatus) icons.Icon {
        if (v.muted or v.volume == 0) return .volume_off;
        if (v.volume < 50) return .volume_down;
        return .volume_up;
    }

    pub fn active(v: VolumeStatus) bool {
        return !v.muted and v.volume > 0;
    }
};

pub fn readVolumeStatus() VolumeStatus {
    const s = audio.loadSettings();
    return .{ .volume = s.volume, .muted = s.muted };
}

/// The network manager's report, as the dock shows it: Wi-Fi when it is
/// joined (or sharing a hotspot), else Ethernet once it has an address (a
/// cable alone is not a connection), else offline.
pub fn networkStatusFromReport(r: sys.network.Report) NetworkStatus {
    const has_wifi = r.wifiAdapters().len > 0;
    if (has_wifi) {
        if (r.hotspot.state == .active) return .hotspot;
        if (r.connection.state.joined()) {
            const joined = r.connection.ssid();
            for (r.slice()) |*n| {
                if (std.mem.eql(u8, n.ssid(), joined)) return .{ .wifi = n.bars() };
            }
            return .{ .wifi = 4 };
        }
    }
    if (r.ethernetConnected()) return .ethernet;
    return .{ .offline = .{ .wifi = has_wifi } };
}

pub fn readNetworkStatus() NetworkStatus {
    if (sys.network.ask("status\n")) |r| {
        if (!r.denied) return networkStatusFromReport(r);
    }
    const dir = sys.open("/sys/class/net", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return .{ .offline = .{} };
    defer sys.close(dir);
    var has_wifi = false;
    var wifi_up = false;
    var eth_up = false;
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(dir, &buf, buf.len)) catch break;
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "lo")) continue;
            var pbuf: [128]u8 = undefined;
            const phy = std.mem.printSentinel(&pbuf, "/sys/class/net/{s}/phy80211/name", .{name}, 0) catch continue;
            const is_wifi = linux.errno(linux.access(phy, linux.F_OK)) == .SUCCESS;
            const state_path = std.mem.printSentinel(&pbuf, "/sys/class/net/{s}/operstate", .{name}, 0) catch continue;
            var sbuf: [32]u8 = undefined;
            const up = if (sys.open(state_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true })) |fd| blk: {
                defer sys.close(fd);
                const sn = sys.check(linux.read(fd, &sbuf, sbuf.len)) catch 0;
                break :blk std.mem.eql(u8, std.mem.trim(u8, sbuf[0..sn], " \t\r\n"), "up");
            } else |_| false;
            if (is_wifi) {
                has_wifi = true;
                if (up) wifi_up = true;
            } else if (up) {
                eth_up = true;
            }
        }
    }
    if (wifi_up) return .{ .wifi = 4 };
    if (eth_up) return .ethernet;
    return .{ .offline = .{ .wifi = has_wifi } };
}

pub const App = struct {
    /// Its directory's name, and its program's.
    name: []const u8,
    /// The name shown: without a "dazzle-" prefix, capitalised.
    label: []const u8,
    /// The program: /data/apps/<name>/<name>.
    path: [:0]const u8,
    /// Its icon, from <program>.icon.
    icon: ?icons.Icon = null,
    /// Its process, while it runs.
    pid: ?linux.pid_t = null,

    fn color(a: *const App) u32 {
        return palette[std.hash.Fnv1a_32.hash(a.name) % palette.len];
    }
};

/// Which app in `apps` a Super+<key> shortcut opens, if any (`key_code`
/// is a Linux key code): Super+1..9,0 open the app at that position in the
/// dock; Super+S opens Settings.
pub fn shortcutApp(apps: []const App, key_code: u32) ?usize {
    if (key_code == evdev.key_s) {
        for (apps, 0..) |app, i| {
            if (std.mem.eql(u8, app.name, "dazzle-settings")) return i;
        }
        return null;
    }
    if (key_code >= evdev.key_1 and key_code <= evdev.key_0) {
        const i: usize = key_code - evdev.key_1;
        if (i < apps.len) return i;
    }
    return null;
}

/// The apps in `dir` (its directories that hold a program of the same
/// name), sorted by name, followed by the programs `builtin` (paths, those
/// that are there) on the right.
pub fn findApps(gpa: std.mem.Allocator, dir_path: []const u8, builtin: []const []const u8) ![]App {
    var apps: std.ArrayList(App) = .empty;
    errdefer apps.deinit(gpa);
    var path_buf: [256]u8 = undefined;
    const dir_z = try std.mem.printSentinel(&path_buf, "{s}", .{dir_path}, 0);
    if (sys.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true })) |dir| {
        defer sys.close(dir);
        try addDir(gpa, &apps, dir, dir_path);
    } else |_| {}
    std.mem.sort(App, apps.items, {}, struct {
        fn lessThan(_: void, a: App, b: App) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    for (builtin) |p| {
        const path = try gpa.dupeSentinel(u8, p, 0);
        if (linux.errno(linux.access(path, linux.X_OK)) != .SUCCESS) {
            gpa.free(path);
            continue;
        }
        const owned = try gpa.dupe(u8, std.fs.path.basename(p));
        try apps.append(gpa, .{ .name = owned, .label = try label(gpa, owned), .path = path, .icon = iconOf(path) });
    }
    return apps.toOwnedSlice(gpa);
}

/// Frees what `findApps` made.
pub fn freeApps(gpa: std.mem.Allocator, apps: []App) void {
    for (apps) |app| {
        gpa.free(app.name);
        gpa.free(app.label);
        gpa.free(app.path);
    }
    gpa.free(apps);
}

/// The apps again (as `findApps`), with the processes of those of `old`
/// still there (`old` is the caller's to free, once the dock has them).
pub fn rescan(gpa: std.mem.Allocator, old: []App, dir_path: []const u8, builtin: []const []const u8) ![]App {
    const new = try findApps(gpa, dir_path, builtin);
    for (new) |*app| for (old) |o| {
        if (std.mem.eql(u8, app.name, o.name)) app.pid = o.pid;
    };
    return new;
}

/// Notices what changes in /data/apps, with inotify: apps installed or
/// removed (each is renamed into or out of place), and the sound and
/// appearance settings being written. Its descriptor is polled with the
/// shell's others.
pub const AppsWatch = struct {
    fd: ?linux.fd_t,
    dir: [*:0]const u8,
    /// The directory is watched (it is not until /data is ready).
    watching: bool = false,

    pub const Changes = struct {
        apps: bool = false,
        sound: bool = false,
        appearance: bool = false,
        /// The apps' catalogue (and so what updates there are).
        catalogue: bool = false,
        /// Remote control turned on or off (`sys.remote`).
        remote: bool = false,

        pub const all: Changes = .{ .apps = true, .sound = true, .appearance = true, .catalogue = true, .remote = true };

        pub fn any(c: Changes) bool {
            inline for (comptime std.meta.fieldNames(Changes)) |name| if (@field(c, name)) return true;
            return false;
        }

        /// What changed in either.
        pub fn with(a: Changes, b: Changes) Changes {
            var out: Changes = .{};
            inline for (comptime std.meta.fieldNames(Changes)) |name| @field(out, name) = @field(a, name) or @field(b, name);
            return out;
        }
    };

    const mask = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CLOSE_WRITE | linux.IN.ONLYDIR;
    const sound_name = std.fs.path.basename(audio.settings_file);
    const remote_name = std.fs.path.basename(sys.remote.settings_file);
    const appearance_name = std.fs.path.basename(appearance_file);
    const catalogue_name = std.fs.path.basename(store.catalogue_file);

    /// Watches `dir`, if it is there yet (see `retry`).
    pub fn init(dir: [*:0]const u8) AppsWatch {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        var w: AppsWatch = .{ .fd = if (linux.errno(rc) == .SUCCESS) @intCast(rc) else null, .dir = dir };
        _ = w.retry();
        return w;
    }

    pub fn deinit(w: *AppsWatch) void {
        if (w.fd) |fd| sys.close(fd);
        w.fd = null;
    }

    /// Watches the directory if it is not yet (it is made once /data is
    /// ready): true if it now is, having not been, when everything in it
    /// may have changed meanwhile.
    pub fn retry(w: *AppsWatch) bool {
        if (w.watching) return false;
        const fd = w.fd orelse return false;
        if (linux.errno(linux.inotify_add_watch(fd, w.dir, mask)) != .SUCCESS) return false;
        w.watching = true;
        return true;
    }

    /// What changed since the last call.
    pub fn take(w: *AppsWatch) Changes {
        var c: Changes = .{};
        const fd = w.fd orelse return c;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return c;
            var at: usize = 0;
            while (at + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *align(1) const linux.inotify_event = @ptrCast(&buf[at]);
                const step = @sizeOf(linux.inotify_event) + ev.len;
                if (at + step > rc) break;
                const name = std.mem.sliceTo(buf[at + @sizeOf(linux.inotify_event) .. at + step], 0);
                at += step;
                // The directory went (or /data was unmounted).
                if (ev.mask & linux.IN.IGNORED != 0) {
                    w.watching = false;
                    continue;
                }
                const written = ev.mask & (linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO) != 0;
                if (std.mem.eql(u8, name, sound_name)) {
                    if (written) c.sound = true;
                } else if (std.mem.eql(u8, name, appearance_name)) {
                    if (written) c.appearance = true;
                } else if (std.mem.eql(u8, name, catalogue_name)) {
                    if (written) c.catalogue = true;
                } else if (std.mem.eql(u8, name, remote_name)) {
                    if (written) c.remote = true;
                } else if (name.len > 0 and name[0] != '.' and ev.mask & linux.IN.CLOSE_WRITE == 0) {
                    c.apps = true;
                }
            }
        }
    }
};

fn addDir(gpa: std.mem.Allocator, apps: *std.ArrayList(App), dir: linux.fd_t, dir_path: []const u8) !void {
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n = try sys.check(linux.getdents64(dir, &buf, buf.len));
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.') continue;
            const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}/{s}", .{ dir_path, name, name }, 0);
            if (linux.errno(linux.access(path, linux.X_OK)) != .SUCCESS) {
                gpa.free(path);
                continue;
            }
            const owned = try gpa.dupe(u8, name);
            try apps.append(gpa, .{ .name = owned, .label = try label(gpa, owned), .path = path, .icon = iconOf(path) });
        }
    }
}

/// The icon named in `<program>.icon`, if there is one Dazzle has.
fn iconOf(program: []const u8) ?icons.Icon {
    var path_buf: [300]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "{s}.icon", .{program}, 0) catch return null;
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return null;
    defer sys.close(fd);
    var buf: [64]u8 = undefined;
    const n = sys.check(linux.read(fd, &buf, buf.len)) catch return null;
    return icons.fromName(buf[0..n]);
}

/// "dazzle-demo" is shown as "Demo".
pub fn label(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const prefix = "dazzle-";
    const base = if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) name[prefix.len..] else name;
    const out = try gpa.dupe(u8, base);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub const Dock = struct {
    /// Where the box, and the tooltip, are drawn (kete's).
    panel: *kete_panel.Panel,
    tip_panel: *kete_panel.Panel,
    /// The box's picture, `width` by `height`, see-through (`glass`), and
    /// wholly outside its rounded corners (the panel's, as `draw` last drew
    /// it: on the GPU, if the kit has it).
    drawn: kete_panel.Picture = .{},
    width: u32,
    height: u32,
    screen_width: u32,
    scale: f32,
    apps: []App,
    /// The app under the pointer.
    hover: ?usize = null,
    /// Where the pointer is along the box (with icons turned, those near
    /// it face the front: see `iconTurns`); null: not on it.
    focus_x: ?f32 = null,
    /// Where along the row (in icons) faces the front without the pointer:
    /// slid along by a finger (see `slideIcons`); null: the middle.
    slid_to: ?f32 = null,
    /// Network status shown in the status box on the right of the dock.
    network: NetworkStatus = .{ .offline = .{} },
    /// Whether data is moving, shown as arrows beside the network status.
    activity: Activity = .{},
    /// There are updates (of the system or apps): an icon says so, first
    /// in the status box.
    updates: bool = false,
    /// Volume status shown in the status box beside the network status.
    volume: VolumeStatus = .{},
    /// Light or dark colour scheme (from `/data/apps/.appearance`).
    theme: Theme = .dark,
    /// The status box shows the time (before the volume), and the
    /// network's status (after it), unless turned off in Settings'
    /// appearance.
    show_clock: bool = true,
    show_network: bool = true,
    /// The time zone, and the time the clock shows (as `draw` last drew
    /// it).
    zone: clock.TimeZone = .utc,
    time: ?clock.Time = null,
    /// The app's name, over the icon the pointer rests on: when it is due
    /// (the pointer has rested a while), and the app whose it shows.
    tooltip_at: ?u64 = null,
    tooltip_shown: ?usize = null,
    /// The screen's height (the dock is at its bottom).
    screen_height: u32,
    /// How far down it is, out of the way of a fullscreen window (0: in
    /// its place, 1: off the bottom of the screen), and on its way: from
    /// where, since when, and whether down.
    slide: f32 = 0,
    slide_from: f32 = 0,
    slide_start: ?u64 = null,
    slide_down: bool = false,
    /// What is in the row, in order: the apps, and apps removed that are
    /// still on their way out; each as big as it is on its way in or out.
    entries: [max_entries]Entry = undefined,
    entries_len: usize = 0,

    /// How long the pointer rests on an icon before its name shows.
    pub const tooltip_delay_ns = 500 * std.time.ns_per_ms;
    /// How long it takes to slide down or up.
    pub const slide_ns = 200 * std.time.ns_per_ms;
    /// How long an app's icon takes to grow in, or shrink out, when it is
    /// installed or removed.
    pub const resize_ns = 250 * std.time.ns_per_ms;
    /// The most icons in the row (more would not fit a screen).
    pub const max_entries = 64;

    /// An icon in the row: an app's (by its index in `apps`), or one
    /// removed (`gone`: how it looked), and how big it is: from `from` to
    /// `to` since `start` (null: there).
    pub const Entry = struct {
        app: ?usize,
        gone: Look = .{},
        from: f32 = 1,
        to: f32 = 1,
        start: ?u64 = null,
        /// How big it is now (0: no room taken, 1: all of it).
        k: f32 = 1,
    };

    /// An icon as it is drawn: its colour, and its symbol or its app's
    /// initial.
    pub const Look = struct {
        color: u32 = 0,
        icon: ?icons.Icon = null,
        initial: [4]u8 = undefined,
        initial_len: u8 = 0,

        fn of(app: *const App) Look {
            var l: Look = .{ .color = app.color(), .icon = app.icon };
            const n = std.unicode.utf8ByteSequenceLength(app.label[0]) catch 1;
            l.initial_len = @intCast(@min(n, app.label.len, 4));
            @memcpy(l.initial[0..l.initial_len], app.label[0..l.initial_len]);
            return l;
        }
    };

    pub fn init(kit: *kete_panel.Kit, apps: []App, screen_width: u32, screen_height: u32) !Dock {
        const panel = try kit.gpuPanel();
        errdefer panel.destroy();
        var d: Dock = .{
            .panel = panel,
            .tip_panel = try kit.panel(),
            .screen_height = screen_height,
            .screen_width = screen_width,
            .width = screen_width,
            .height = 0,
            .scale = 1,
            .apps = apps,
        };
        // The apps there to start with are there already.
        d.entries_len = @min(apps.len, max_entries);
        for (d.entries[0..d.entries_len], 0..) |*e, i| e.* = .{ .app = i };
        d.setScreen(screen_width, screen_height, false);
        return d;
    }

    /// Sizes it for a screen `screen_width` by `screen_height`: as it is at
    /// 1080p, scaled down for a smaller one; for fingers (`touch`: a
    /// touchscreen), no smaller than at 1080p (its icons are then about as
    /// big as a fingertip), as long as the status box and an icon fit
    /// across the screen. More icons than fit turn to (see `iconTurns`).
    pub fn setScreen(d: *Dock, screen_width: u32, screen_height: u32, touch: bool) void {
        d.screen_width = screen_width;
        d.screen_height = screen_height;
        d.width = screen_width;
        var scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        if (touch) scale = @max(scale, 1);
        d.scale = scale;
        // The status box and an icon (as wide as they are at this scale)
        // across the screen, less a margin each side.
        const row = (icon_size + icon_gap) * scale + d.statusWidth() + 2 * box_pad * scale;
        const room = @as(f32, @floatFromInt(screen_width)) - 2 * margin * scale;
        if (row > room and row > 0) d.scale = scale * room / row;
        d.height = @intFromFloat(@round((icon_size + 2 * box_pad) * d.scale));
    }

    pub fn deinit(d: *Dock) void {
        d.panel.destroy();
        d.tip_panel.destroy();
    }

    /// The apps are now `new` (`apps`, which they replace, is to be freed
    /// after): those installed grow in from `now`, those removed shrink
    /// out, and the others move along to make room or take it.
    pub fn setApps(d: *Dock, new: []App, now: u64) void {
        var out: [max_entries]Entry = undefined;
        var n: usize = 0;
        var next: usize = 0;
        const add = struct {
            fn f(o: *[max_entries]Entry, len: *usize, e: Entry) void {
                if (len.* < max_entries) {
                    o[len.*] = e;
                    len.* += 1;
                }
            }
        }.f;
        for (d.entries[0..d.entries_len]) |e| {
            const old: ?*const App = if (e.app) |i| &d.apps[i] else null;
            const at: ?usize = if (old) |o| for (new, 0..) |*a, j| {
                if (std.mem.eql(u8, a.name, o.name)) break j;
            } else null else null;
            if (at) |j| if (j >= next) {
                // Those installed before it, growing in.
                for (new[next..j], next..) |_, k| add(&out, &n, .{ .app = k, .from = 0, .to = 1, .start = now, .k = 0 });
                var kept = e;
                kept.app = j;
                add(&out, &n, kept);
                next = j + 1;
                continue;
            };
            // Gone (or it was already): shrinking out from as big as it is.
            if (e.app == null and e.to == 0) {
                add(&out, &n, e);
            } else if (old) |o| {
                add(&out, &n, .{ .app = null, .gone = .of(o), .from = e.k, .to = 0, .start = now, .k = e.k });
            }
        }
        for (new[next..], next..) |_, k| add(&out, &n, .{ .app = k, .from = 0, .to = 1, .start = now, .k = 0 });
        d.entries = out;
        d.entries_len = n;
        d.apps = new;
    }

    /// Grows and shrinks the icons on their way in or out, at `now`; drops
    /// those gone. Returns whether any are on their way.
    pub fn animateApps(d: *Dock, now: u64) bool {
        var moving = false;
        var n: usize = 0;
        for (d.entries[0..d.entries_len]) |e0| {
            var e = e0;
            if (e.start) |start| {
                const t: f32 = @floatCast(@min(@as(f64, @floatFromInt(now -| start)) / resize_ns, 1));
                e.k = e.from + (e.to - e.from) * easeInOut(t);
                if (t >= 1) e.start = null else moving = true;
                if (t >= 1 and e.to == 0) {
                    moving = true;
                    continue;
                }
            }
            d.entries[n] = e;
            n += 1;
        }
        d.entries_len = n;
        return moving;
    }

    /// Whether icons are on their way in or out.
    pub fn resizing(d: *const Dock) bool {
        for (d.entries[0..d.entries_len]) |e| if (e.start != null) return true;
        return false;
    }

    /// An icon in the box: its square's left and top, and size; how wide
    /// it looks (`size`, unless turned), and how far it is turned (see
    /// `iconTurns`: radians, more than 0 its right edge away).
    pub const Rect = struct { x: f32, y: f32, size: f32, width: f32 = 0, turn: f32 = 0 };
    /// The status box's width (at 1080p): the volume, in its padding.
    const status_box_width = 56;
    /// How much wider the status box is with the network (its icon and
    /// activity arrows), and the update icon, in it.
    const network_width = 68;
    const update_icon_width = 46;
    /// The clock's text's size, and the gap after it.
    const clock_text = 22;
    const clock_gap = 10;

    /// The status box's width, in pixels.
    fn statusWidth(d: *const Dock) f32 {
        var w: f32 = status_box_width;
        if (d.updates) w += update_icon_width;
        if (d.show_network) w += network_width;
        return w * d.scale + d.clockWidth();
    }

    /// The room the clock takes in the status box (its widest, so the box
    /// stays as it is as the time changes), in pixels: none if it is not
    /// shown.
    fn clockWidth(d: *const Dock) f32 {
        if (!d.show_clock) return 0;
        const f = d.panel.ui.font orelse return 0;
        var buf: [16]u8 = undefined;
        const text = clock.widestText(&buf);
        return @ceil(kete.font.measure(.{ .font = f, .size = @round(clock_text * d.scale) }, text)) + clock_gap * d.scale;
    }

    /// Shows the time in `zone` from now on.
    pub fn setTimeZone(d: *Dock, zone: clock.TimeZone) void {
        d.zone = zone;
        d.time = null;
    }

    /// Whether the clock, shown, is behind the time at `now` (seconds
    /// since 1970): the dock is then to be drawn again.
    pub fn clockBehind(d: *const Dock, now: i64) bool {
        if (!d.show_clock) return false;
        const t = d.time orelse return true;
        return t.minute != @divFloor(now, 60);
    }
    pub const StatusRect = struct { x: f32, y: f32, width: f32, height: f32 };

    const icon_size = 56;
    const icon_gap = 20;
    /// Between the box's edges and what is in it, the same all round (a
    /// running app's dot is in the padding below its icon).
    const box_pad = 12;
    /// Between the box and the bottom of the screen (and the work area).
    pub const margin = 8;
    pub const box_radius = 18;

    /// The box's width, in pixels: the icons and the status box in a row,
    /// padded; no wider than the screen.
    pub fn boxWidth(d: *const Dock) u32 {
        const row = d.iconsWidth() + d.statusWidth();
        return @min(@as(u32, @intFromFloat(@ceil(row + 2 * box_pad * d.scale))), d.screen_width);
    }

    /// How wide the icons are, in a row: each as big as it is (on its way
    /// in or out), and those turned (`iconTurns`) as narrow as they look.
    fn iconsWidth(d: *const Dock) f32 {
        const step = (icon_size + icon_gap) * d.scale;
        var turns: [max_entries]f32 = undefined;
        d.iconTurns(turns[0..d.entries_len]);
        var w: f32 = 0;
        for (d.entries[0..d.entries_len], turns[0..d.entries_len]) |e, t| w += e.k * step * @cos(t);
        return w;
    }

    /// How many icons there are (those on their way in or out counted as
    /// far as they have grown).
    fn iconCount(d: *const Dock) f32 {
        var n: f32 = 0;
        for (d.entries[0..d.entries_len]) |e| n += e.k;
        return n;
    }

    /// The room across the screen for the icons, beside the status box
    /// (which always shows in full).
    fn iconsRoom(d: *const Dock) f32 {
        return @as(f32, @floatFromInt(d.screen_width)) - 2 * margin * d.scale - 2 * box_pad * d.scale - d.statusWidth();
    }

    /// The most an icon is turned (about 70°: it looks a third as wide).
    const max_turn: f32 = 1.22;
    /// Over how many icons the turn goes from none to the most.
    const fold_ramp: f32 = 1.5;

    /// When the icons do not all fit across the screen, those towards the
    /// ends turn, edge on, to take less room (as on Unity's launcher):
    /// those near the pointer (or, without it, the middle) face the front,
    /// and the further from it the more they are turned, as much as it
    /// takes for them to fit. Each one's turn (in `turns`), its right edge
    /// away to the right of the pointer and its left to the left.
    fn iconTurns(d: *const Dock, turns: []f32) void {
        @memset(turns, 0);
        const step = (icon_size + icon_gap) * d.scale;
        const room = d.iconsRoom();
        if (d.iconCount() * step <= room) return;
        const p = d.focusIndex();
        // How far from the pointer an icon is before it turns: as far as
        // lets them fit (the less, the narrower they are).
        var lo: f32 = -fold_ramp;
        var hi: f32 = d.iconCount();
        if (d.foldedWidth(lo, p) < room) for (0..24) |_| {
            const mid = (lo + hi) / 2;
            if (d.foldedWidth(mid, p) > room) hi = mid else lo = mid;
        };
        var at: f32 = 0;
        for (d.entries[0..d.entries_len], turns) |e, *t| {
            const c = at + e.k / 2;
            at += e.k;
            const f = std.math.clamp((@abs(c - p) - lo) / fold_ramp, 0, 1);
            t.* = if (c < p) -f * max_turn else f * max_turn;
        }
    }

    /// Where along the row (in icons) the pointer is, or the middle.
    fn focusIndex(d: *const Dock) f32 {
        const n = d.iconCount();
        const fx = d.focus_x orelse return std.math.clamp(d.slid_to orelse n / 2, 0, n);
        // Turned to fit, the icons fill the box's room for them, from its
        // padding.
        const room = d.iconsRoom();
        if (!(room > 0)) return n / 2;
        return std.math.clamp((fx - box_pad * d.scale) / room, 0, 1) * n;
    }

    /// A finger dragged along the icons by `dx` pixels: they slide with
    /// it, those turned coming round to the front as they near where it
    /// faces (the other way, the row's end turning away). Returns whether
    /// they moved (only when some are turned to fit).
    pub fn slideIcons(d: *Dock, dx: f32) bool {
        const n = d.iconCount();
        if (n * (icon_size + icon_gap) * d.scale <= d.iconsRoom()) return false;
        const was = d.focusIndex();
        // An icon's width moved, the icons move on by one.
        const to = std.math.clamp(was - dx / ((icon_size + icon_gap) * d.scale), 0, n);
        d.slid_to = to;
        return to != was;
    }

    /// How wide the row of icons is with those further than `from` icons
    /// from `p` turned.
    fn foldedWidth(d: *const Dock, from: f32, p: f32) f32 {
        const step = (icon_size + icon_gap) * d.scale;
        var w: f32 = 0;
        var at: f32 = 0;
        for (d.entries[0..d.entries_len]) |e| {
            const c = at + e.k / 2;
            at += e.k;
            const f = std.math.clamp((@abs(c - p) - from) / fold_ramp, 0, 1);
            w += e.k * step * @cos(f * max_turn);
        }
        return w;
    }

    /// The gap between the box and the bottom of the screen, in pixels.
    fn marginPx(d: *const Dock) u32 {
        return @intFromFloat(@round(margin * d.scale));
    }

    /// The height of the band along the bottom of the screen the dock is
    /// in, with a gap above and below it: windows (but fullscreen ones)
    /// stay above it.
    pub fn bandHeight(d: *const Dock) u32 {
        return d.height + 2 * d.marginPx();
    }

    /// Where the box is on the screen, slid down as far as it is.
    pub const Place = struct { x: i32, y: i32 };
    pub fn place(d: *const Dock) Place {
        const top: f32 = @floatFromInt(d.screen_height - d.marginPx() - d.height);
        const down: f32 = @floatFromInt(d.height + d.marginPx());
        return .{
            .x = @intCast((d.screen_width - d.boxWidth()) / 2),
            .y = @intFromFloat(@round(top + easeInOut(d.slide) * down)),
        };
    }

    /// (`x`, `y`) on the screen, in the box (null: not on it). Where it
    /// is in its place: it takes no input while it slides.
    pub fn local(d: *const Dock, x: f64, y: f64) ?[2]f64 {
        const lx = x - @as(f64, @floatFromInt((d.screen_width - d.boxWidth()) / 2));
        const ly = y - @as(f64, @floatFromInt(d.screen_height - d.marginPx() - d.height));
        if (lx < 0 or ly < 0 or lx >= @as(f64, @floatFromInt(d.boxWidth())) or ly >= @as(f64, @floatFromInt(d.height))) return null;
        return .{ lx, ly };
    }

    /// Sends it down off the screen (for a fullscreen window), or back up,
    /// from where it is, at `now`.
    pub fn slideTo(d: *Dock, down: bool, now: u64) void {
        if (down == d.slide_down) return;
        d.slide_down = down;
        d.slide_from = d.slide;
        d.slide_start = now;
    }

    /// Moves it along its way, at `now`; returns whether it moved.
    pub fn animateSlide(d: *Dock, now: u64) bool {
        const start = d.slide_start orelse return false;
        const k: f32 = @floatCast(@min(@as(f64, @floatFromInt(now -| start)) / slide_ns, 1));
        const to: f32 = if (d.slide_down) 1 else 0;
        d.slide = d.slide_from + (to - d.slide_from) * k;
        if (k >= 1) d.slide_start = null;
        return true;
    }

    /// On its way down or up.
    pub fn sliding(d: *const Dock) bool {
        return d.slide_start != null;
    }

    /// All the way down, off the screen.
    pub fn offScreen(d: *const Dock) bool {
        return d.slide >= 1;
    }

    /// Its picture, as `draw` last drew it.
    pub fn picture(d: *const Dock) kete_panel.Picture {
        return d.drawn;
    }

    /// Where app `i`'s icon is, in the box: the icons and the status box
    /// on the right are in a row.
    pub fn iconRect(d: *const Dock, i: usize) Rect {
        for (d.entries[0..d.entries_len], 0..) |e, j| if (e.app == i) return d.entryRect(j);
        // Not in the row (yet): nowhere.
        return .{ .x = -1000, .y = 0, .size = 0, .width = 0 };
    }

    /// Where the `j`th icon in the row is, as big as it is (the room it
    /// takes, and the gap after it, are as much smaller): in the middle of
    /// the space between the icons either side, and of the row's height.
    fn entryRect(d: *const Dock, j: usize) Rect {
        const full = icon_size * d.scale;
        const step = (icon_size + icon_gap) * d.scale;
        var turns: [max_entries]f32 = undefined;
        d.iconTurns(turns[0..d.entries_len]);
        var x = d.rowStart();
        for (d.entries[0..j], turns[0..j]) |e, t| x += e.k * step * @cos(t);
        const k = d.entries[j].k;
        const size = full * k;
        const w = @cos(turns[j]);
        // Back by half the gap before it that it has not grown into yet.
        const gap = icon_gap * d.scale;
        return .{ .x = x - (1 - k) * gap * w / 2, .y = box_pad * d.scale + (full - size) / 2, .size = size, .width = size * w, .turn = turns[j] };
    }

    /// Where the row starts, in the box.
    fn rowStart(d: *const Dock) f32 {
        const row = d.iconsWidth() + d.statusWidth();
        return (@as(f32, @floatFromInt(d.boxWidth())) - row) / 2;
    }

    /// Where the status box (volume and network) is, to the right of the rightmost app.
    pub fn statusRect(d: *const Dock) StatusRect {
        return .{ .x = d.rowStart() + d.iconsWidth(), .y = box_pad * d.scale, .width = d.statusWidth(), .height = icon_size * d.scale };
    }

    /// Whether (`x`, `y`) in the dock is on the status box (clicked: the
    /// quick settings).
    pub fn hitStatus(d: *const Dock, x: f64, y: f64) bool {
        const rs = d.statusRect();
        return x >= rs.x and x < rs.x + rs.width and y >= rs.y and y < rs.y + rs.height;
    }

    /// The app whose icon is at (`x`, `y`) in the dock: where icons
    /// overlap, the one on top (the later).
    pub fn hit(d: *const Dock, x: f64, y: f64) ?usize {
        var found: ?usize = null;
        for (d.entries[0..d.entries_len], 0..) |e, j| {
            const i = e.app orelse continue;
            const r = d.entryRect(j);
            if (x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.size) found = i;
        }
        return found;
    }

    /// Draws it as it is now (with kete: see `View`).
    pub fn draw(d: *Dock) void {
        d.time = .at(sys.realtimeSec(), d.zone);
        d.width = d.boxWidth();
        d.drawn = d.panel.draw(d.width, d.height, 0, View{ .d = d });
    }

    /// The box as kete widgets: the box, each icon in the row (where the
    /// dock's layout puts it: they grow and shrink, and move along, as apps
    /// come and go), and the status box. Each its own widget, so a change
    /// to one (the pointer moving over the icons) draws only it again.
    const View = struct {
        d: *const Dock,

        pub fn build(v: *const View, cx: *kete.BuildContext) kete.Widget {
            const d = v.d;
            const a = cx.arena;
            var layers: std.ArrayList(kete.Widget) = .empty;
            layers.append(a, cx.make(Box{ .color = glassy(d.theme.colors().background), .radius = @round(box_radius * d.scale) })) catch {};
            for (d.entries[0..d.entries_len], 0..) |e, j| {
                if (e.k <= 0) continue;
                const r = d.entryRect(j);
                const app: ?*const App = if (e.app) |i| &d.apps[i] else null;
                const tile: Tile = .{
                    .turn = r.turn,
                    .look = if (app) |ap| .of(ap) else e.gone,
                    .hover = e.app != null and d.hover == e.app.?,
                    .running = if (app) |ap| ap.pid != null else false,
                    .k = e.k,
                    .scale = d.scale,
                    .theme = d.theme,
                };
                const at = tile.origin(r);
                layers.append(a, placed(cx, at[0], at[1], tile.width(r), tile.height(r), cx.make(tile))) catch {};
            }
            const rs = d.statusRect();
            layers.append(a, placed(cx, rs.x, rs.y, rs.width, rs.height, cx.make(Status{
                .theme = d.theme,
                .scale = d.scale,
                .updates = d.updates,
                .volume = d.volume,
                .network = if (d.show_network) d.network else null,
                .activity = d.activity,
                .clock = if (d.show_clock) if (d.time) |t| t.timeText(a.alloc(u8, 16) catch &.{}) else null else null,
                .clock_width = d.clockWidth(),
            }))) catch {};
            return cx.make(kete.Overlay{ .children = layers.items });
        }
    };

    /// `child`, `w` by `h`, at (`x`, `y`) in the box.
    fn placed(cx: *kete.BuildContext, x: f32, y: f32, w: f32, h: f32, child: kete.Widget) kete.Widget {
        return cx.make(kete.Align{ .alignment = .top_left, .child = cx.make(kete.Padding{ .padding = .{ .left = x, .top = y }, .child = cx.make(kete.SizedBox{ .width = w, .height = h, .child = child }) }) });
    }

    /// The see-through box, its corners rounded.
    const Box = struct {
        color: u32,
        radius: f32,

        pub fn layout(_: *const Box, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
            return c.constrain(.{ .w = c.max_w, .h = c.max_h });
        }

        pub fn paint(b: *const Box, n: *kete.WidgetNode, p: *kete.Painter) void {
            p.canvas().fillRoundedRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, .all(b.radius), kete.gfx.Color.argb(b.color));
        }
    };

    /// An app's icon: its coloured square, its symbol or initial, the
    /// highlight behind it while the pointer is on it, and the dot under
    /// it while it runs; as big as it is (`k`, on its way in or out).
    const Tile = struct {
        /// How far it is turned (see `Dock.iconTurns`).
        turn: f32 = 0,
        look: Look,
        hover: bool,
        running: bool,
        k: f32,
        scale: f32,
        theme: Theme,

        /// The highlight's margin round the square.
        fn margin(t: Tile) f32 {
            return 4 * t.scale * t.k;
        }

        fn origin(t: Tile, r: Rect) [2]f32 {
            return .{ r.x - t.margin() * @cos(t.turn), r.y - t.margin() };
        }

        /// Turned (to fit, see `Dock.iconTurns`): its square, and what is
        /// on it, edge on in perspective, the highlight and dot as ever.
        fn paintTurned(t: *const Tile, n: *kete.WidgetNode, p: *kete.Painter) void {
            const c = t.theme.colors();
            const argb = kete.gfx.Color.argb;
            const cv = p.canvas();
            const s = t.scale;
            const k = t.k;
            const pad = t.margin();
            const size = icon_size * s * k;
            const cx = n.size.w / 2;
            const cy = pad + size / 2;
            var pts: [4 * corner_points]kete.gfx.Point = undefined;
            if (t.hover) cv.fillPolygon(turnedSquare(&pts, cx, cy, size + 2 * pad, 14 * s * k, t.turn), argb(c.hover_background));
            cv.fillPolygon(turnedSquare(&pts, cx, cy, size, 12 * s * k, t.turn), argb(t.look.color));
            // Its symbol or initial, as narrow as the square looks.
            const saved = p.transform;
            const o = cv.origin;
            p.transform = kete.gfx.Affine.scaling(@cos(t.turn), 1).about(.{ o[0] + cx, o[1] + cy });
            if (t.look.icon) |icon| {
                const isz = @round(36 * s * k);
                if (isz >= 1) p.icon(ui_icons.of(icon), cx - isz / 2, cy - isz / 2, isz, argb(0xffffffff));
            } else if (p.ui.font) |f| if (t.look.initial_len > 0 and 30 * s * k >= 1) {
                const style: kete.font.Style = .{ .font = f, .size = 30 * s * k };
                const initial = t.look.initial[0..t.look.initial_len];
                _ = p.text(style.size, cx - kete.font.measure(style, initial) / 2, cy + style.ascent() * 0.36, initial, argb(0xffffffff));
            };
            p.transform = saved;
            _ = p.canvas();
            if (t.running) {
                const dot = 6 * s * k;
                cv.fillRoundedRect(.{ .x = cx - dot / 2, .y = n.size.h - dot, .w = dot, .h = dot }, .all(dot / 2), argb(c.dot));
            }
        }

        fn width(t: Tile, r: Rect) f32 {
            return r.width + 2 * t.margin() * @cos(t.turn);
        }

        /// Down to under the running dot.
        fn height(t: Tile, r: Rect) f32 {
            const full = icon_size * t.scale;
            return box_pad * t.scale + full + 3 * t.scale + 6 * t.scale * t.k - (r.y - t.margin());
        }

        pub fn layout(_: *const Tile, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
            return c.constrain(.{ .w = c.max_w, .h = c.max_h });
        }

        pub fn paint(t: *const Tile, n: *kete.WidgetNode, p: *kete.Painter) void {
            if (t.turn != 0) return t.paintTurned(n, p);
            const c = t.theme.colors();
            const argb = kete.gfx.Color.argb;
            const cv = p.canvas();
            const pad = t.margin();
            const size = n.size.w - 2 * pad;
            const s = t.scale;
            const k = t.k;
            if (t.hover) cv.fillRoundedRect(.{ .x = 0, .y = 0, .w = size + 2 * pad, .h = size + 2 * pad }, .all(14 * s * k), argb(c.hover_background));
            cv.fillRoundedRect(.{ .x = pad, .y = pad, .w = size, .h = size }, .all(12 * s * k), argb(t.look.color));
            if (t.look.icon) |icon| {
                const isz = @round(36 * s * k);
                if (isz >= 1) p.icon(ui_icons.of(icon), pad + (size - isz) / 2, pad + (size - isz) / 2, isz, argb(0xffffffff));
            } else if (p.ui.font) |f| if (t.look.initial_len > 0 and 30 * s * k >= 1) {
                const style: kete.font.Style = .{ .font = f, .size = 30 * s * k };
                const initial = t.look.initial[0..t.look.initial_len];
                _ = p.text(style.size, pad + (size - kete.font.measure(style, initial)) / 2, pad + size / 2 + style.ascent() * 0.36, initial, argb(0xffffffff));
            };
            if (t.running) {
                const dot = 6 * s * k;
                cv.fillRoundedRect(.{ .x = pad + (size - dot) / 2, .y = n.size.h - dot, .w = dot, .h = dot }, .all(dot / 2), argb(c.dot));
            }
        }
    };

    /// A rounded square `size` across, its corners `radius`, round
    /// (`cx`, `cy`), turned by `turn` about its upright middle line and
    /// seen in perspective: its outline.
    fn turnedSquare(out: *[4 * corner_points]kete.gfx.Point, cx: f32, cy: f32, size: f32, radius: f32, turn: f32) []const kete.gfx.Point {
        const h = size / 2;
        const r = @min(radius, h);
        const centres = [4][2]f32{ .{ h - r, -(h - r) }, .{ h - r, h - r }, .{ -(h - r), h - r }, .{ -(h - r), -(h - r) } };
        const starts = [4]f32{ -std.math.pi / 2.0, 0, std.math.pi / 2.0, std.math.pi };
        // The eye a few squares away: the edge turned away smaller.
        const eye = 3 * size;
        var i: usize = 0;
        for (centres, starts) |ctr, a0| for (0..corner_points) |k| {
            const a = a0 + @as(f32, @floatFromInt(k)) / @as(f32, corner_points - 1) * std.math.pi / 2.0;
            const u = ctr[0] + r * @cos(a);
            const v = ctr[1] + r * @sin(a);
            const z = u * @sin(turn);
            const s = eye / (eye + z);
            out[i] = .{ cx + u * @cos(turn) * s, cy + v * s };
            i += 1;
        };
        return out[0..i];
    }
    const corner_points = 6;

    /// The status box: an outline, updates, the time, the volume and the
    /// network (the time and the network if shown).
    const Status = struct {
        theme: Theme,
        scale: f32,
        updates: bool,
        volume: VolumeStatus,
        network: ?NetworkStatus,
        activity: Activity,
        clock: ?[]const u8 = null,
        /// The room kept for it, the gap after it included.
        clock_width: f32 = 0,

        pub fn layout(_: *const Status, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
            return c.constrain(.{ .w = c.max_w, .h = c.max_h });
        }

        pub fn paint(st: *const Status, n: *kete.WidgetNode, p: *kete.Painter) void {
            const c = st.theme.colors();
            const argb = kete.gfx.Color.argb;
            const s = st.scale;
            const w = n.size.w;
            const h = n.size.h;
            // Its outline, inside its edge.
            const stroke = @max(1.5, 2 * s);
            p.canvas().strokeRoundedRect(.{ .x = stroke / 2, .y = stroke / 2, .w = w - stroke, .h = h - stroke }, .all(12 * s - stroke / 2), stroke, argb(c.status_border));
            const size = @round(36 * s);
            const pad = @round(10 * s);
            const y = @round((h - size) / 2);
            const update_x = pad;
            const clock_x = if (st.updates) @round(update_x + update_icon_width * s) else update_x;
            const vol_x = @round(clock_x + st.clock_width);
            const arrow = @round(18 * s);
            const arrows_x = @round(w - pad - arrow);
            const net_x = @round(arrows_x - 4 * s - size);
            if (st.updates) p.icon(.system_update_alt, update_x, y, size, argb(c.dot));
            // The time, its right edge before the volume.
            if (st.clock) |text| if (p.ui.font) |f| {
                const style: kete.font.Style = .{ .font = f, .size = @round(clock_text * s) };
                const tw = kete.font.measure(style, text);
                _ = p.text(style.size, @round(vol_x - clock_gap * s - tw), @round(h / 2 + style.ascent() * 0.36), text, argb(c.status_active));
            };
            p.icon(ui_icons.of(st.volume.icon()), vol_x, y, size, argb(if (st.volume.active()) c.status_active else c.status_inactive));
            const network = st.network orelse return;
            p.icon(ui_icons.of(network.icon()), net_x, y, size, argb(if (network.connected()) c.status_active else c.status_inactive));
            // Sending above receiving, each lit while data moves that way.
            if (network.connected()) {
                const mid = @round(h / 2);
                p.icon(.arrow_upward, arrows_x, mid - arrow, arrow, argb(if (st.activity.sending) c.status_active else c.status_inactive));
                p.icon(.arrow_downward, arrows_x, mid, arrow, argb(if (st.activity.receiving) c.status_active else c.status_inactive));
            }
        }
    };

    /// Moves the hover highlight for the pointer at (`x`, `y`) in the dock
    /// (null: elsewhere), at `now`. Returns whether it changed (and with
    /// it, the tooltip: gone, and due again a while later; at once if one
    /// was showing, moving along the icons).
    pub fn pointerAt(d: *Dock, x: ?f64, y: f64, now: u64) bool {
        // Icons turned to fit face the front near it: they move with it.
        const focus: ?f32 = if (x) |px| @floatCast(px) else null;
        const folded = d.iconCount() * (icon_size + icon_gap) * d.scale > d.iconsRoom();
        const refold = folded and !std.meta.eql(focus, d.focus_x);
        d.focus_x = focus;
        const under = if (x) |px| d.hit(px, y) else null;
        if (under == d.hover) return refold;
        const was_shown = d.tooltip_shown != null;
        d.hover = under;
        d.tooltip_shown = null;
        d.tooltip_at = if (under == null) null else if (was_shown) now else now + tooltip_delay_ns;
        return true;
    }

    /// An icon was pressed: its tooltip goes (until the pointer moves to
    /// another).
    pub fn dismissTooltip(d: *Dock) void {
        d.tooltip_at = null;
        d.tooltip_shown = null;
    }

    /// When the tooltip should show, if it is not showing yet.
    pub fn tooltipDue(d: *const Dock) ?u64 {
        return if (d.tooltip_shown == null) d.tooltip_at else null;
    }

    /// The tooltip's picture: the app's name, centred above its icon.
    pub const Tooltip = struct { picture: kete_panel.Picture, x: i32, y: i32 };

    fn tooltipHeight(scale: f32) u32 {
        return @intFromFloat(@round(34 * scale));
    }

    fn tooltipMaxWidth(scale: f32) u32 {
        return @intFromFloat(@round(480 * scale));
    }

    /// Draws the tooltip of the icon the pointer rests on, if it is due by
    /// `now` (it is then showing).
    pub fn drawTooltip(d: *Dock, now: u64) ?Tooltip {
        const due = d.tooltip_at orelse return null;
        const i = d.hover orelse return null;
        if (now < due or d.tooltip_shown != null) return null;
        d.tooltip_at = null;
        d.tooltip_shown = i;
        const view: TooltipView = .{ .text = d.apps[i].label, .theme = d.theme, .scale = d.scale };
        const h = tooltipHeight(d.scale);
        const w: u32 = @min(d.tip_panel.naturalSize(view)[0], tooltipMaxWidth(d.scale));
        const tip = d.tip_panel.draw(w, h, now, view);
        if (tip.isEmpty()) return null;
        // Above the icon, clear of the dock, and on the screen.
        const r = d.iconRect(i);
        const at = d.place();
        const fw: f32 = @floatFromInt(w);
        const x = std.math.clamp(@round(@as(f32, @floatFromInt(at.x)) + r.x + r.width / 2 - fw / 2), 0, @as(f32, @floatFromInt(d.screen_width)) - fw);
        return .{ .picture = tip, .x = @intFromFloat(x), .y = at.y - @as(i32, @intCast(h)) - @as(i32, @intFromFloat(@round(8 * d.scale))) };
    }

    /// The tooltip, as kete widgets: the app's name in a small rounded box.
    const TooltipView = struct {
        text: []const u8,
        theme: Theme,
        scale: f32,

        pub fn build(v: *const TooltipView, cx: *kete.BuildContext) kete.Widget {
            const c = v.theme.colors();
            const s = v.scale;
            return cx.make(kete.RoundedBox{
                .color = kete.gfx.Color.argb(c.tooltip_background),
                .radius = .all(@round(6 * s)),
                .child = cx.make(kete.Padding{ .padding = .{ .left = @round(12 * s), .right = @round(12 * s) }, .child = cx.make(kete.SizedBox{ .height = @round(34 * s), .child = cx.make(kete.Align{ .alignment = .center_left, .child = cx.make(kete.Text{
                    .text = v.text,
                    .style = .{ .size = @round(18 * s), .color = kete.gfx.Color.argb(c.tooltip_text) },
                    .wrap = false,
                    .ellipsis = true,
                }) }) }) }),
            });
        }
    };
};

fn easeInOut(t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    if (x < 0.5) return 4 * x * x * x;
    const u = -2 * x + 2;
    return 1 - u * u * u / 2;
}

const testing = std.testing;

fn testKit() !*kete_panel.Kit {
    return kete_panel.Kit.create(testing.allocator, testing.io, @embedFile("FiraSans-Regular.ttf"), null, &.{});
}

test "the apps and the settings in the apps directory are noticed changing" {
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-watch-test-{d}", .{linux.getpid()}, 0);
    var sub_buf: [80]u8 = undefined;
    const sub = try std.mem.printSentinel(&sub_buf, "{s}/app", .{path}, 0);
    var sound_buf: [80]u8 = undefined;
    const sound = try std.mem.printSentinel(&sound_buf, "{s}/.sound", .{path}, 0);

    // Not there yet: watched once it is.
    var w: AppsWatch = .init(path);
    defer w.deinit();
    try testing.expect(!w.watching);
    _ = linux.mkdir(path, 0o755);
    defer _ = linux.rmdir(path);
    try testing.expect(w.retry());
    try testing.expect(!w.retry());
    try testing.expect(!w.take().any());

    _ = linux.mkdir(sub, 0o755);
    // Everything that changes is kept when changes are put together.
    try testing.expectEqual(AppsWatch.Changes.all, (AppsWatch.Changes{ .apps = true, .sound = true }).with(.{ .appearance = true, .catalogue = true, .remote = true }));
    try testing.expectEqual(AppsWatch.Changes{ .apps = true }, w.take());
    _ = linux.rmdir(sub);
    try testing.expectEqual(AppsWatch.Changes{ .apps = true }, w.take());

    try sys.files.writeNew(sound, "volume 50\n");
    defer _ = linux.unlink(sound);
    try testing.expectEqual(AppsWatch.Changes{ .sound = true }, w.take());
    try testing.expect(!w.take().any());
}

test "app labels drop the dazzle- prefix" {
    const a = testing.allocator;
    const l = try label(a, "dazzle-demo");
    defer a.free(l);
    try testing.expectEqualStrings("Demo", l);
    const m = try label(a, "notes");
    defer a.free(m);
    try testing.expectEqualStrings("Notes", m);
}

test "icons and the status box are in a row in a box, and clicks find the apps" {
    var apps = [_]App{
        .{ .name = "a", .label = "A", .path = "/apps/a/a", .icon = .folder },
        .{ .name = "b", .label = "B", .path = "/apps/b/b" },
    };
    const kit = try testKit();
    defer kit.destroy();
    var d = try Dock.init(kit, &apps, 1920, 1080);
    defer d.deinit();
    try testing.expectEqual(@as(u32, 80), d.height);
    const r0 = d.iconRect(0);
    const r1 = d.iconRect(1);
    const rs = d.statusRect();
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(d.boxWidth())) - (rs.x + rs.width), r0.x, 0.01);
    try testing.expect(rs.x > r1.x + r1.size);
    try testing.expectEqual(@as(?usize, 0), d.hit(r0.x + 1, r0.y + 1));
    try testing.expectEqual(@as(?usize, 1), d.hit(r1.x + r1.size - 1, r1.y + r1.size - 1));
    try testing.expectEqual(@as(?usize, null), d.hit(rs.x + rs.width / 2, rs.y + rs.height / 2));
    try testing.expectEqual(@as(?usize, null), d.hit(r0.x + r0.size + 1, r0.y + 1));
    try testing.expectEqual(@as(?usize, null), d.hit(0, 0));

    try testing.expectEqual(icons.Icon.volume_up, (VolumeStatus{ .volume = 80, .muted = false }).icon());
    try testing.expectEqual(icons.Icon.volume_down, (VolumeStatus{ .volume = 30, .muted = false }).icon());
    try testing.expectEqual(icons.Icon.volume_off, (VolumeStatus{ .volume = 80, .muted = true }).icon());
    try testing.expectEqual(icons.Icon.volume_off, (VolumeStatus{ .volume = 0, .muted = false }).icon());

    // Hovering changes the picture; a running app gets a dot.
    try testing.expect(d.pointerAt(r1.x + 1, r1.y + 1, 0));
    try testing.expect(!d.pointerAt(r1.x + 2, r1.y + 2, 0));
    apps[0].pid = 42;
    d.network = .ethernet;
    d.volume = .{ .volume = 75, .muted = false };
    d.draw();
    const at = struct {
        fn f(dock: *const Dock, x: f32, y: f32) u32 {
            return dock.drawn.pixels[@as(usize, @intFromFloat(y)) * dock.width + @as(usize, @intFromFloat(x))];
        }
    }.f;
    try testing.expectEqual(@as(u32, glassy(background)), at(&d, @floatFromInt(d.width / 2), 2));
    try testing.expectEqual(apps[0].color(), at(&d, r0.x + r0.size / 2, r0.y + 4));
    try testing.expectEqual(@as(u32, dot_color), at(&d, r0.x + r0.size / 2, r0.y + r0.size + 6));
    try testing.expectEqual(@as(u32, glassy(background)), at(&d, r1.x + r1.size / 2, r1.y + r1.size + 6));
    try testing.expectEqual(@as(u32, hover_background), at(&d, r1.x - 2, r1.y + r1.size / 2));
    // The first app's icon is drawn in white in the middle of its square.
    try testing.expectEqual(@as(u32, 0xffffffff), at(&d, r0.x + r0.size / 2, r0.y + r0.size / 2));
    // The status box has an outline at its top edge, is unfilled inside its padding, and draws the volume and network icons inside it.
    try testing.expectEqual(@as(u32, status_border), at(&d, rs.x + rs.width / 2, rs.y + 1));
    try testing.expectEqual(@as(u32, glassy(background)), at(&d, rs.x + rs.width / 2, rs.y + 5));

    // Switching to the light theme updates the dock background, hover, running dot, and status border.
    try testing.expectEqual(Appearance{}, Appearance.parse(""));
    try testing.expectEqual(Appearance{ .theme = .light, .image = .of("/data/user/sea.png") }, Appearance.parse("theme light\nimage /data/user/sea.png\n"));
    d.theme = .light;
    d.draw();
    const light = Theme.light.colors();
    try testing.expectEqual(glassy(light.background), at(&d, @floatFromInt(d.width / 2), 2));
    try testing.expectEqual(light.dot, at(&d, r0.x + r0.size / 2, r0.y + r0.size + 6));
    try testing.expectEqual(light.hover_background, at(&d, r1.x - 2, r1.y + r1.size / 2));
    try testing.expectEqual(light.status_border, at(&d, rs.x + rs.width / 2, rs.y + 1));
}

test "more icons than fit across the screen turn edge on at the ends, not overlapping; the status box shows in full" {
    var apps: [14]App = undefined;
    const names = "abcdefghijklmn";
    for (&apps, 0..) |*ap, i| ap.* = .{ .name = names[i .. i + 1], .label = names[i .. i + 1], .path = "/apps/x/x" };
    const kit = try testKit();
    defer kit.destroy();
    var d = try Dock.init(kit, &apps, 720, 1280);
    defer d.deinit();
    // For fingers: at full size.
    d.setScreen(720, 1280, true);
    try testing.expectEqual(@as(f32, 1), d.scale);
    try testing.expect(d.boxWidth() <= 720 - 2 * Dock.margin);
    const rs = d.statusRect();
    try testing.expect(rs.x + rs.width <= @as(f32, @floatFromInt(d.boxWidth())) + 0.01);
    // Side by side, none over another; the last clear of the status box.
    for (0..13) |i| {
        const a = d.iconRect(i);
        const b = d.iconRect(i + 1);
        try testing.expect(a.x + a.width <= b.x + 0.01);
        // Each is pressed in its middle.
        try testing.expectEqual(@as(?usize, i), d.hit(a.x + a.width / 2, a.y + a.size / 2));
    }
    const last = d.iconRect(13);
    try testing.expect(last.x + last.width <= rs.x + 0.01);
    // The middle ones face the front most; the ends are turned away, each
    // way, all the way.
    try testing.expect(@abs(d.iconRect(7).turn) < 0.5);
    try testing.expectApproxEqAbs(-Dock.max_turn, d.iconRect(0).turn, 0.01);
    try testing.expectApproxEqAbs(Dock.max_turn, d.iconRect(13).turn, 0.01);
    try testing.expect(d.iconRect(0).width < d.iconRect(0).size);
    // The pointer at the left: those there face the front.
    _ = d.pointerAt(d.iconRect(0).x + 1, d.iconRect(0).y + 1, 0);
    try testing.expect(@abs(d.iconRect(0).turn) < 0.5);
    try testing.expect(d.iconRect(13).turn > 0);
    d.draw();
    // Slid along by a finger (the pointer gone): to the right, the left
    // end comes round to the front; it stays so.
    _ = d.pointerAt(null, 0, 0);
    try testing.expect(d.slideIcons(1000));
    try testing.expect(@abs(d.iconRect(0).turn) < 0.5);
    try testing.expectApproxEqAbs(Dock.max_turn, d.iconRect(13).turn, 0.01);
    try testing.expect(!d.slideIcons(400));
    try testing.expect(d.slideIcons(-2000));
    try testing.expect(@abs(d.iconRect(13).turn) < 0.5);
    try testing.expectApproxEqAbs(-Dock.max_turn, d.iconRect(0).turn, 0.01);
    // With room, none is turned.
    d.setScreen(1920, 1080, true);
    for (0..14) |i| try testing.expectEqual(@as(f32, 0), d.iconRect(i).turn);
}

test "the dock floats in a rounded box in the middle of the bottom, and slides down and back" {
    var apps = [_]App{
        .{ .name = "a", .label = "A", .path = "/apps/a/a", .icon = .folder },
        .{ .name = "b", .label = "B", .path = "/apps/b/b" },
    };
    const kit = try testKit();
    defer kit.destroy();
    var d = try Dock.init(kit, &apps, 1920, 1080);
    defer d.deinit();
    d.draw();
    // Just big enough: the icons and status box, padded.
    try testing.expect(d.width < 500);
    try testing.expectEqual(d.width, d.boxWidth());
    try testing.expectEqual(@as(u32, 80 + 2 * 8), d.bandHeight());
    const at = d.place();
    try testing.expectEqual(@as(i32, @intCast((1920 - d.width) / 2)), at.x);
    try testing.expectEqual(@as(i32, 1080 - 8 - 80), at.y);
    // The same space around the icons on every side.
    const first = d.iconRect(0);
    const status = d.statusRect();
    try testing.expectApproxEqAbs(first.y, first.x, 0.5);
    try testing.expectApproxEqAbs(first.y, @as(f32, @floatFromInt(d.height)) - (first.y + first.size), 0.5);
    try testing.expectApproxEqAbs(first.y, @as(f32, @floatFromInt(d.width)) - (status.x + status.width), 1);
    // Wholly see-through outside its corners, partly in the middle.
    try testing.expectEqual(@as(u32, 0), d.picture().pixels[0] >> 24);
    try testing.expectEqual(@as(u32, 0), d.picture().pixels[d.width - 1] >> 24);
    try testing.expectEqual(@as(u32, glass.alpha), d.picture().pixels[d.width / 2] >> 24);
    // The screen's points map into it, or are beside it.
    const r0 = d.iconRect(0);
    const l = d.local(@as(f64, @floatFromInt(at.x)) + r0.x + 1, @as(f64, @floatFromInt(at.y)) + r0.y + 1).?;
    try testing.expectEqual(@as(?usize, 0), d.hit(l[0], l[1]));
    try testing.expect(d.local(10, 1075) == null);
    try testing.expect(d.local(960, 990) == null);

    // Sent down: on its way for a while, then off the screen; and back.
    try testing.expect(!d.animateSlide(0));
    d.slideTo(true, 1000);
    try testing.expect(d.animateSlide(1000 + Dock.slide_ns / 2));
    try testing.expect(d.sliding());
    const mid = d.place().y;
    try testing.expect(mid > at.y and mid < 1080);
    try testing.expect(d.animateSlide(1000 + Dock.slide_ns));
    try testing.expect(!d.sliding() and d.offScreen());
    try testing.expect(d.place().y >= 1080);
    d.slideTo(false, 5000);
    _ = d.animateSlide(5000 + Dock.slide_ns);
    try testing.expect(!d.offScreen());
    try testing.expectEqual(at.y, d.place().y);
}

test "with updates, the status box is wider and starts with the update icon" {
    var apps = [_]App{.{ .name = "a", .label = "A", .path = "/apps/a/a", .icon = .folder }};
    const kit = try testKit();
    defer kit.destroy();
    var d = try Dock.init(kit, &apps, 1920, 1080);
    defer d.deinit();
    const without = d.statusRect();
    d.draw();
    const box_middle_y: usize = @intFromFloat(without.y + without.height / 2);
    const at = struct {
        fn f(dock: *const Dock, x: f32, y: usize) u32 {
            return dock.drawn.pixels[y * dock.width + @as(usize, @intFromFloat(x))];
        }
    }.f;
    const box_without = d.boxWidth();
    d.updates = true;
    const with = d.statusRect();
    try testing.expectApproxEqAbs(without.width + 46, with.width, 0.01);
    // The box grew to fit it (and stays in the middle).
    try testing.expectEqual(box_without + 46, d.boxWidth());
    // The whole status box is pressed as one (the quick settings open),
    // the update icon too; not an app.
    try testing.expect(d.hitStatus(with.x + 20, with.y + with.height / 2));
    try testing.expect(d.hitStatus(with.x + with.width - 20, with.y + with.height / 2));
    try testing.expect(!d.hitStatus(with.x - 20, with.y + with.height / 2));
    try testing.expectEqual(@as(?usize, null), d.hit(with.x + 20, with.y + with.height / 2));
    d.draw();
    // The icon, in the accent the running dots have, where the volume was.
    var accent = false;
    var x = with.x + 10;
    while (x < with.x + 46) : (x += 1) {
        if (at(&d, x, box_middle_y) == dot_color) accent = true;
    }
    try testing.expect(accent);
}

test "the network status is Wi-Fi when joined, Ethernet with an address, and offline otherwise" {
    // Joined to Wi-Fi with a cable plugged in too: Wi-Fi, with its signal.
    const r_both = sys.network.Report.parse(
        \\ethernet eth0 dhcp 10.0.2.15/24 10.0.2.2 up
        \\wifi adapter wlan0 b8:27:eb:01:02:03 up
        \\wifi connection connected none 486f6d65 192.168.1.50
        \\wifi network -6200 2437 wpa2 486f6d65
        \\end
        \\
    ).?;
    try testing.expectEqual(NetworkStatus{ .wifi = 3 }, networkStatusFromReport(r_both));
    try testing.expectEqual(icons.Icon.network_wifi_3_bar, networkStatusFromReport(r_both).icon());

    const r_weak = sys.network.Report.parse(
        \\wifi adapter wlan0 b8:27:eb:01:02:03 up
        \\wifi connection connected none 486f6d65 192.168.1.50
        \\wifi network -9000 2437 wpa2 486f6d65
        \\end
        \\
    ).?;
    try testing.expectEqual(NetworkStatus{ .wifi = 0 }, networkStatusFromReport(r_weak));
    try testing.expectEqual(icons.Icon.signal_wifi_0_bar, networkStatusFromReport(r_weak).icon());

    // Wi-Fi not joined: Ethernet, if it has an address.
    const r_eth = sys.network.Report.parse(
        \\ethernet eth0 dhcp 10.0.2.15/24 10.0.2.2 up
        \\wifi adapter wlan0 b8:27:eb:01:02:03 up
        \\end
        \\
    ).?;
    try testing.expectEqual(NetworkStatus.ethernet, networkStatusFromReport(r_eth));
    try testing.expectEqual(icons.Icon.lan, networkStatusFromReport(r_eth).icon());

    // A cable with no address yet, and Wi-Fi not joined: offline.
    const r_none = sys.network.Report.parse(
        \\ethernet eth0 dhcp none none up
        \\wifi adapter wlan0 b8:27:eb:01:02:03 up
        \\end
        \\
    ).?;
    try testing.expectEqual(NetworkStatus{ .offline = .{ .wifi = true } }, networkStatusFromReport(r_none));
    try testing.expectEqual(icons.Icon.signal_wifi_off, networkStatusFromReport(r_none).icon());
    try testing.expect(!networkStatusFromReport(r_none).connected());

    // No Wi-Fi, and no cable.
    const r_wired_only = sys.network.Report.parse(
        \\ethernet eth0 dhcp none none down
        \\end
        \\
    ).?;
    try testing.expectEqual(icons.Icon.public_off, networkStatusFromReport(r_wired_only).icon());
}

test "activity is data moving each way since the last look" {
    const before: Traffic = .{ .received = 100, .sent = 50 };
    try testing.expectEqual(Activity{}, Activity.between(before, before));
    try testing.expectEqual(Activity{ .receiving = true }, Activity.between(before, .{ .received = 300, .sent = 50 }));
    try testing.expectEqual(Activity{ .receiving = true, .sending = true }, Activity.between(before, .{ .received = 300, .sent = 60 }));
}

test "apps are the directories holding a program of the same name, with builtin apps on the right" {
    const a = testing.allocator;
    var tmp_buf: [64]u8 = undefined;
    const root = try std.mem.printSentinel(&tmp_buf, "/tmp/dazzle-dock-test-{d}", .{linux.getpid()}, 0);
    defer {
        var b: [128]u8 = undefined;
        for ([_][]const u8{ "/zeta/zeta", "/alpha/alpha", "/alpha/alpha.icon", "/dazzle-settings", "/zeta", "/alpha", "/notes", "" }) |p| {
            const path = std.mem.printSentinel(&b, "{s}{s}", .{ root, p }, 0) catch unreachable;
            if (linux.errno(linux.unlink(path)) != .SUCCESS) _ = linux.rmdir(path);
        }
    }
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdir(root, 0o755)));
    var b: [128]u8 = undefined;
    for ([_][]const u8{ "zeta", "alpha", "notes" }) |name| {
        _ = linux.mkdir(try std.mem.printSentinel(&b, "{s}/{s}", .{ root, name }, 0), 0o755);
    }
    // Programs for two of them; "notes" has none.
    for ([_][]const u8{ "zeta", "alpha" }) |name| {
        const fd = try sys.open(try std.mem.printSentinel(&b, "{s}/{s}/{s}", .{ root, name, name }, 0), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        _ = linux.fchmod(fd, 0o755);
        sys.close(fd);
    }
    // Alpha's icon is named beside it.
    {
        const fd = try sys.open(try std.mem.printSentinel(&b, "{s}/alpha/alpha.icon", .{root}, 0), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        _ = linux.fchmod(fd, 0o644);
        _ = linux.write(fd, "folder\n", 7);
        sys.close(fd);
    }
    // And a program of the shell's own whose name sorts before "zeta", to check it stays rightmost.
    var own_buf: [128]u8 = undefined;
    const own_z = try std.mem.printSentinel(&own_buf, "{s}/dazzle-settings", .{root}, 0);
    {
        const fd = try sys.open(own_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        _ = linux.fchmod(fd, 0o755);
        sys.close(fd);
    }
    const apps = try findApps(a, root, &.{ own_z, "/nonexistent/beta" });
    defer {
        for (apps) |app| {
            a.free(app.name);
            a.free(app.label);
            a.free(app.path);
        }
        a.free(apps);
    }
    try testing.expectEqual(@as(usize, 3), apps.len);
    try testing.expectEqualStrings("alpha", apps[0].name);
    try testing.expectEqual(@as(?icons.Icon, .folder), apps[0].icon);
    try testing.expectEqualStrings("zeta", apps[1].name);
    try testing.expectEqualStrings("Zeta", apps[1].label);
    try testing.expect(std.mem.endsWith(u8, apps[1].path, "/zeta/zeta"));
    try testing.expectEqualStrings("dazzle-settings", apps[2].name);
    try testing.expectEqual(@as(?icons.Icon, null), apps[2].icon);
    try testing.expectEqual(@as(usize, 0), (try findApps(a, "/nonexistent", &.{})).len);
}

test "Super+S opens Settings and Super+1, Super+2 etc open the app at that dock position" {
    const apps = [_]App{
        .{ .name = "dazzle-files", .label = "Files", .path = "/data/apps/dazzle-files/dazzle-files" },
        .{ .name = "dazzle-maps", .label = "Maps", .path = "/data/apps/dazzle-maps/dazzle-maps" },
        .{ .name = "dazzle-settings", .label = "Settings", .path = "/os/shell/dazzle-settings" },
    };
    try testing.expectEqual(@as(?usize, 2), shortcutApp(&apps, evdev.key_s));
    try testing.expectEqual(@as(?usize, 0), shortcutApp(&apps, evdev.key_1));
    try testing.expectEqual(@as(?usize, 1), shortcutApp(&apps, evdev.key_1 + 1));
    try testing.expectEqual(@as(?usize, 2), shortcutApp(&apps, evdev.key_1 + 2));
    try testing.expectEqual(@as(?usize, null), shortcutApp(&apps, evdev.key_1 + 3));
    try testing.expectEqual(@as(?usize, null), shortcutApp(&apps, 30));
}

test "resting the pointer on an icon shows the app's name above it, a while later" {
    var apps = [_]App{
        .{ .name = "dazzle-files", .label = "Files", .path = "/apps/files/files", .icon = .folder },
        .{ .name = "dazzle-settings", .label = "Settings", .path = "/apps/settings/settings", .icon = .settings },
    };
    const kit = try testKit();
    defer kit.destroy();
    var d = try Dock.init(kit, &apps, 1920, 1080);
    defer d.deinit();
    const r0 = d.iconRect(0);
    const r1 = d.iconRect(1);
    const ms = std.time.ns_per_ms;

    // Not at once: half a second later.
    try testing.expect(d.pointerAt(r0.x + 4, r0.y + 4, 1000 * ms));
    try testing.expectEqual(@as(?u64, 1500 * ms), d.tooltipDue());
    try testing.expect(d.drawTooltip(1200 * ms) == null);
    const tip = d.drawTooltip(1500 * ms).?;
    try testing.expectEqual(@as(?usize, 0), d.tooltip_shown);
    try testing.expect(d.tooltipDue() == null);
    // Above the dock, centred over the icon.
    const at = d.place();
    try testing.expect(tip.y + @as(i32, @intCast(tip.picture.height)) < at.y);
    const middle = @as(f32, @floatFromInt(tip.x)) + @as(f32, @floatFromInt(tip.picture.width)) / 2;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(at.x)) + r0.x + r0.size / 2, middle, 1);
    // Its corners are see-through, and its middle not; the name is drawn.
    const c = Theme.dark.colors();
    try testing.expectEqual(@as(u32, 0), tip.picture.pixels[0] >> 24);
    try testing.expectEqual(c.tooltip_background, tip.picture.pixels[(tip.picture.height / 2) * tip.picture.width + 2]);
    var text_pixels: usize = 0;
    for (tip.picture.pixels) |px| if (px != c.tooltip_background and px >> 24 == 0xff) {
        text_pixels += 1;
    };
    try testing.expect(text_pixels > 20);

    // Moving to the next icon, it shows that app's at once.
    try testing.expect(d.pointerAt(r1.x + 4, r1.y + 4, 2000 * ms));
    try testing.expect(d.tooltip_shown == null);
    try testing.expect(d.drawTooltip(2000 * ms) != null);
    try testing.expectEqual(@as(?usize, 1), d.tooltip_shown);
    // Pressed, it goes; and off the icons, it is not due.
    d.dismissTooltip();
    try testing.expect(d.tooltip_shown == null and d.tooltipDue() == null);
    try testing.expect(d.pointerAt(null, 0, 3000 * ms));
    try testing.expect(d.tooltipDue() == null);
    // Back on an icon, a while later again.
    try testing.expect(d.pointerAt(r0.x + 4, r0.y + 4, 4000 * ms));
    try testing.expectEqual(@as(?u64, 4500 * ms), d.tooltipDue());
}

test "an app installed grows in, one removed shrinks out, and the others move along" {
    var apps = [_]App{
        .{ .name = "a", .label = "A", .path = "/apps/a/a", .icon = .folder },
        .{ .name = "c", .label = "C", .path = "/apps/c/c" },
    };
    const kit = try testKit();
    defer kit.destroy();
    var d = try Dock.init(kit, &apps, 1920, 1080);
    defer d.deinit();
    const ms = std.time.ns_per_ms;
    const two = d.boxWidth();
    const c_before = d.iconRect(1).x;
    try testing.expect(!d.resizing());

    // "b" installed, between them: it starts with no room, and grows.
    var more = [_]App{ apps[0], .{ .name = "b", .label = "B", .path = "/apps/b/b" }, apps[1] };
    d.setApps(&more, 1000 * ms);
    try testing.expect(d.resizing());
    try testing.expect(d.animateApps(1000 * ms));
    try testing.expectEqual(two, d.boxWidth());
    try testing.expectEqual(@as(f32, 0), d.iconRect(1).size);
    try testing.expect(d.animateApps(1125 * ms));
    const half = d.iconRect(1);
    try testing.expect(half.size > 0 and half.size < Dock.icon_size);
    try testing.expect(d.boxWidth() > two);
    // In the middle between "a" and "c", which move apart to make room.
    const a_end = d.iconRect(0).x + d.iconRect(0).size;
    try testing.expectApproxEqAbs(half.x - a_end, d.iconRect(2).x - (half.x + half.size), 0.01);
    d.draw();
    try testing.expect(!d.animateApps(1300 * ms));
    try testing.expect(!d.resizing());
    try testing.expectEqual(@as(f32, Dock.icon_size), d.iconRect(1).size);
    try testing.expect(d.iconRect(2).x > c_before);
    const three = d.boxWidth();

    // "a" removed: it shrinks out where it was, then is gone.
    var fewer = [_]App{ more[1], more[2] };
    d.setApps(&fewer, 2000 * ms);
    try testing.expectEqual(@as(usize, 3), d.entries_len);
    try testing.expect(d.entries[0].app == null);
    try testing.expectEqual(apps[0].color(), d.entries[0].gone.color);
    _ = d.animateApps(2125 * ms);
    try testing.expect(d.boxWidth() < three and d.boxWidth() > two - 1);
    d.draw();
    _ = d.animateApps(2300 * ms);
    try testing.expectEqual(@as(usize, 2), d.entries_len);
    try testing.expectEqual(two, d.boxWidth());
    try testing.expectEqual(@as(?usize, 0), d.hit(d.iconRect(0).x + 1, d.iconRect(0).y + 1));
}
