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
const font = @import("font");
const glass = @import("glass.zig");
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

    pub fn parse(text: []const u8) Appearance {
        const s = theme_settings.Settings.parse(text);
        return .{
            .theme = switch (s.theme) {
                .dark => .dark,
                .light => .light,
            },
            .image = s.image,
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
    font: ?font.Font,
    icon_font: ?font.Font,
    cache: font.GlyphCache,
    /// The box's picture, `width` by `height` (rows `width` apart), see-
    /// through (`glass`), and wholly outside its rounded corners. Room for
    /// the screen's width, twice: the second is where it is drawn over
    /// white.
    pixels: []u32,
    width: u32,
    height: u32,
    screen_width: u32,
    scale: f32,
    apps: []App,
    /// The app under the pointer.
    hover: ?usize = null,
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
    /// The app's name, over the icon the pointer rests on: when it is due
    /// (the pointer has rested a while), and the app whose it shows.
    tooltip_at: ?u64 = null,
    tooltip_shown: ?usize = null,
    /// Its picture (`drawTooltip`), and the screen's height (the dock is
    /// at its bottom).
    tooltip_pixels: []u32,
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

    pub fn init(gpa: std.mem.Allocator, f: ?font.Font, apps: []App, screen_width: u32, screen_height: u32) !Dock {
        const scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        const height: u32 = @intFromFloat(@round((icon_size + 2 * box_pad) * scale));
        var d: Dock = .{
            .font = f,
            .icon_font = font.Font.init(icons.font_data) catch null,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, 2 * @as(usize, screen_width) * height),
            .tooltip_pixels = try gpa.alloc(u32, @as(usize, tooltipMaxWidth(scale)) * tooltipHeight(scale)),
            .screen_height = screen_height,
            .screen_width = screen_width,
            .width = screen_width,
            .height = height,
            .scale = scale,
            .apps = apps,
        };
        // The apps there to start with are there already.
        d.entries_len = @min(apps.len, max_entries);
        for (d.entries[0..d.entries_len], 0..) |*e, i| e.* = .{ .app = i };
        return d;
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

    pub const Rect = struct { x: f32, y: f32, size: f32 };
    /// The status box's width (at 1080p): the volume, the network and its
    /// activity arrows.
    const status_box_width = 124;
    /// How much wider the status box is with the update icon in it.
    const update_icon_width = 46;

    /// The status box's width, in pixels.
    fn statusWidth(d: *const Dock) f32 {
        const w: f32 = if (d.updates) status_box_width + update_icon_width else status_box_width;
        return w * d.scale;
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
    /// in or out).
    fn iconsWidth(d: *const Dock) f32 {
        var w: f32 = 0;
        for (d.entries[0..d.entries_len]) |e| w += e.k;
        return w * (icon_size + icon_gap) * d.scale;
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
    pub fn picture(d: *const Dock) []const u32 {
        return d.pixels[0 .. @as(usize, d.width) * d.height];
    }

    /// Where app `i`'s icon is, in the box: the icons and the status box
    /// on the right are in a row.
    pub fn iconRect(d: *const Dock, i: usize) Rect {
        for (d.entries[0..d.entries_len], 0..) |e, j| if (e.app == i) return d.entryRect(j);
        // Not in the row (yet): nowhere.
        return .{ .x = -1000, .y = 0, .size = 0 };
    }

    /// Where the `j`th icon in the row is, as big as it is (the room it
    /// takes, and the gap after it, are as much smaller): in the middle of
    /// the space between the icons either side, and of the row's height.
    fn entryRect(d: *const Dock, j: usize) Rect {
        const full = icon_size * d.scale;
        const step = (icon_size + icon_gap) * d.scale;
        var x = d.rowStart();
        for (d.entries[0..j]) |e| x += e.k * step;
        const k = d.entries[j].k;
        const size = full * k;
        // Back by half the gap before it that it has not grown into yet.
        const gap = icon_gap * d.scale;
        return .{ .x = x - (1 - k) * gap / 2, .y = box_pad * d.scale + (full - size) / 2, .size = size };
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

    /// The app whose icon is at (`x`, `y`) in the dock.
    pub fn hit(d: *const Dock, x: f64, y: f64) ?usize {
        for (0..d.apps.len) |i| {
            const r = d.iconRect(i);
            if (x >= r.x and x < r.x + r.size and y >= r.y and y < r.y + r.size) return i;
        }
        return null;
    }

    pub fn draw(d: *Dock) void {
        d.width = d.boxWidth();
        const n = @as(usize, d.width) * d.height;
        const over_black: font.Canvas = .{ .pixels = d.pixels[0..n], .width = d.width, .height = d.height, .stride = d.width };
        const over_white: font.Canvas = .{ .pixels = d.pixels[n .. 2 * n], .width = d.width, .height = d.height, .stride = d.width };
        d.drawContents(over_black, glass.black);
        d.drawContents(over_white, glass.white);
        // In a see-through box, its corners rounded.
        glass.compose(over_black.pixels, over_white.pixels, d.theme.colors().background);
        glass.cutCorners(over_black, @round(box_radius * d.scale));
    }

    /// What is in the box, over `base`.
    fn drawContents(d: *Dock, canvas: font.Canvas, base: u32) void {
        const c = d.theme.colors();
        canvas.fill(0, 0, d.width, d.height, base);
        const icon_font: ?*const font.Font = if (d.icon_font) |*f| f else null;
        for (d.entries[0..d.entries_len], 0..) |e, j| {
            if (e.k <= 0) continue;
            const r = d.entryRect(j);
            // As big as it is on its way in or out.
            const k = e.k;
            const app: ?*const App = if (e.app) |i| &d.apps[i] else null;
            const look: Look = if (app) |a| .of(a) else e.gone;
            if (e.app != null and d.hover == e.app.?) {
                const pad = 4 * d.scale * k;
                roundedRect(canvas, r.x - pad, r.y - pad, r.size + 2 * pad, r.size + 2 * pad, 14 * d.scale * k, c.hover_background);
            }
            roundedRect(canvas, r.x, r.y, r.size, r.size, 12 * d.scale * k, look.color);
            if (look.icon != null and icon_font != null) {
                // Icons fill the em square, with the baseline at the bottom.
                const size = @round(36 * d.scale * k);
                const style: font.Style = .{ .font = icon_font.?, .size = size, .color = 0xffffffff };
                var buf: [4]u8 = undefined;
                const x = @round(r.x + (r.size - size) / 2);
                const y = @round(r.y + (r.size - size) / 2);
                if (size >= 1) _ = font.draw(canvas, &d.cache, style, x, y + size, icons.text(look.icon.?, &buf)) catch {};
            } else if (d.font) |*f| if (look.initial_len > 0 and 30 * d.scale * k >= 1) {
                const style: font.Style = .{ .font = f, .size = 30 * d.scale * k, .color = 0xffffffff };
                const initial = look.initial[0..look.initial_len];
                const baseline = r.y + r.size / 2 + style.ascent() * 0.36;
                _ = font.draw(canvas, &d.cache, style, r.x + (r.size - font.measure(style, initial)) / 2, baseline, initial) catch {};
            };
            if (app) |a| if (a.pid != null) {
                const dot = 6 * d.scale * k;
                const full = icon_size * d.scale;
                roundedRect(canvas, r.x + (r.size - dot) / 2, box_pad * d.scale + full + 3 * d.scale, dot, dot, dot / 2, c.dot);
            };
        }
        const rs = d.statusRect();
        roundedRectOutline(canvas, rs.x, rs.y, rs.width, rs.height, 12 * d.scale, @max(1.5, 2 * d.scale), c.status_border);
        if (icon_font) |f| {
            const size = @round(36 * d.scale);
            const pad = @round(10 * d.scale);
            const y = @round(rs.y + (rs.height - size) / 2);
            const update_x = @round(rs.x + pad);
            const vol_x = if (d.updates) @round(update_x + update_icon_width * d.scale) else update_x;
            const arrow = @round(18 * d.scale);
            const arrows_x = @round(rs.x + rs.width - pad - arrow);
            const net_x = @round(arrows_x - 4 * d.scale - size);
            var buf: [4]u8 = undefined;
            if (d.updates) _ = font.draw(canvas, &d.cache, .{ .font = f, .size = size, .color = c.dot }, update_x, y + size, icons.text(.system_update_alt, &buf)) catch {};
            const vol_color: u32 = if (d.volume.active()) c.status_active else c.status_inactive;
            _ = font.draw(canvas, &d.cache, .{ .font = f, .size = size, .color = vol_color }, vol_x, y + size, icons.text(d.volume.icon(), &buf)) catch {};
            const net_color: u32 = if (d.network.connected()) c.status_active else c.status_inactive;
            _ = font.draw(canvas, &d.cache, .{ .font = f, .size = size, .color = net_color }, net_x, y + size, icons.text(d.network.icon(), &buf)) catch {};
            // Sending above receiving, each lit while data moves that way.
            if (d.network.connected()) {
                const mid = rs.y + rs.height / 2;
                const up_color: u32 = if (d.activity.sending) c.status_active else c.status_inactive;
                const down_color: u32 = if (d.activity.receiving) c.status_active else c.status_inactive;
                _ = font.draw(canvas, &d.cache, .{ .font = f, .size = arrow, .color = up_color }, arrows_x, @round(mid), icons.text(.arrow_upward, &buf)) catch {};
                _ = font.draw(canvas, &d.cache, .{ .font = f, .size = arrow, .color = down_color }, arrows_x, @round(mid + arrow), icons.text(.arrow_downward, &buf)) catch {};
            }
        }
    }

    /// Moves the hover highlight for the pointer at (`x`, `y`) in the dock
    /// (null: elsewhere), at `now`. Returns whether it changed (and with
    /// it, the tooltip: gone, and due again a while later; at once if one
    /// was showing, moving along the icons).
    pub fn pointerAt(d: *Dock, x: ?f64, y: f64, now: u64) bool {
        const under = if (x) |px| d.hit(px, y) else null;
        if (under == d.hover) return false;
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
    pub const Tooltip = struct { pixels: []const u32, width: u32, height: u32, x: i32, y: i32 };

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
        const f = if (d.font) |*f| f else return null;
        d.tooltip_at = null;
        d.tooltip_shown = i;
        const c = d.theme.colors();
        const text = d.apps[i].label;
        const style: font.Style = .{ .font = f, .size = @round(18 * d.scale), .color = c.tooltip_text };
        const pad = @round(12 * d.scale);
        const h = tooltipHeight(d.scale);
        const w: u32 = @min(@as(u32, @intFromFloat(@ceil(font.measure(style, text) + 2 * pad))), tooltipMaxWidth(d.scale));
        const pixels = d.tooltip_pixels[0 .. @as(usize, w) * h];
        const canvas: font.Canvas = .{ .pixels = pixels, .width = w, .height = h, .stride = w };
        canvas.fill(0, 0, w, h, c.tooltip_background);
        const fh: f32 = @floatFromInt(h);
        const baseline = @round(fh / 2 + style.ascent() * 0.36);
        _ = font.draw(canvas, &d.cache, style, pad, baseline, text) catch {};
        // Rounded: what is outside its corners is see-through.
        glass.cutCorners(canvas, @round(6 * d.scale));
        // Above the icon, clear of the dock, and on the screen.
        const r = d.iconRect(i);
        const at = d.place();
        const fw: f32 = @floatFromInt(w);
        const x = std.math.clamp(@round(@as(f32, @floatFromInt(at.x)) + r.x + r.size / 2 - fw / 2), 0, @as(f32, @floatFromInt(d.screen_width)) - fw);
        return .{ .pixels = pixels, .width = w, .height = h, .x = @intFromFloat(x), .y = at.y - @as(i32, @intCast(h)) - @as(i32, @intFromFloat(@round(8 * d.scale))) };
    }
};

fn easeInOut(t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    if (x < 0.5) return 4 * x * x * x;
    const u = -2 * x + 2;
    return 1 - u * u * u / 2;
}

/// Fills a rectangle with rounded corners, anti-aliased.
fn roundedRect(c: font.Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: u32) void {
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(x), 0, @as(f32, @floatFromInt(c.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(y), 0, @as(f32, @floatFromInt(c.height))));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(x + w), 0, @as(f32, @floatFromInt(c.width))));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(y + h), 0, @as(f32, @floatFromInt(c.height))));
    const cx = x + w / 2;
    const cy = y + h / 2;
    const r = @min(radius, @min(w, h) / 2);
    for (y0..y1) |py| for (x0..x1) |px| {
        // Distance from the pixel's centre to the shape's edge.
        const qx = @abs(@as(f32, @floatFromInt(px)) + 0.5 - cx) - (w / 2 - r);
        const qy = @abs(@as(f32, @floatFromInt(py)) + 0.5 - cy) - (h / 2 - r);
        const outside = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
        const coverage = std.math.clamp(0.5 - outside, 0, 1);
        if (coverage <= 0) continue;
        const p = &c.pixels[py * c.stride + px];
        p.* = font.text.blend(p.*, color, @intFromFloat(@round(coverage * 255)));
    };
}

/// Strokes the outline of a rectangle with rounded corners, anti-aliased,
/// leaving its interior unfilled.
fn roundedRectOutline(c: font.Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, stroke: f32, color: u32) void {
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(x), 0, @as(f32, @floatFromInt(c.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(y), 0, @as(f32, @floatFromInt(c.height))));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(x + w), 0, @as(f32, @floatFromInt(c.width))));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(y + h), 0, @as(f32, @floatFromInt(c.height))));
    const cx = x + w / 2;
    const cy = y + h / 2;
    const r = @min(radius, @min(w, h) / 2);
    const half_s = stroke / 2;
    for (y0..y1) |py| for (x0..x1) |px| {
        const qx = @abs(@as(f32, @floatFromInt(px)) + 0.5 - cx) - (w / 2 - r);
        const qy = @abs(@as(f32, @floatFromInt(py)) + 0.5 - cy) - (h / 2 - r);
        const outside = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
        const dist = @abs(outside + half_s) - half_s;
        const coverage = std.math.clamp(0.5 - dist, 0, 1);
        if (coverage <= 0) continue;
        const p = &c.pixels[py * c.stride + px];
        p.* = font.text.blend(p.*, color, @intFromFloat(@round(coverage * 255)));
    };
}

const testing = std.testing;

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
    var d = try Dock.init(testing.allocator, null, &apps, 1920, 1080);
    defer testing.allocator.free(d.pixels);
    defer testing.allocator.free(d.tooltip_pixels);
    defer d.cache.deinit();
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
            return dock.pixels[@as(usize, @intFromFloat(y)) * dock.width + @as(usize, @intFromFloat(x))];
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

test "the dock floats in a rounded box in the middle of the bottom, and slides down and back" {
    var apps = [_]App{
        .{ .name = "a", .label = "A", .path = "/apps/a/a", .icon = .folder },
        .{ .name = "b", .label = "B", .path = "/apps/b/b" },
    };
    var d = try Dock.init(testing.allocator, null, &apps, 1920, 1080);
    defer testing.allocator.free(d.pixels);
    defer testing.allocator.free(d.tooltip_pixels);
    defer d.cache.deinit();
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
    try testing.expectEqual(@as(u32, 0), d.picture()[0] >> 24);
    try testing.expectEqual(@as(u32, 0), d.picture()[d.width - 1] >> 24);
    try testing.expectEqual(@as(u32, glass.alpha), d.picture()[d.width / 2] >> 24);
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
    var d = try Dock.init(testing.allocator, null, &apps, 1920, 1080);
    defer testing.allocator.free(d.pixels);
    defer testing.allocator.free(d.tooltip_pixels);
    defer d.cache.deinit();
    const without = d.statusRect();
    d.draw();
    const box_middle_y: usize = @intFromFloat(without.y + without.height / 2);
    const at = struct {
        fn f(dock: *const Dock, x: f32, y: usize) u32 {
            return dock.pixels[y * dock.width + @as(usize, @intFromFloat(x))];
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
    const fira = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    var d = try Dock.init(testing.allocator, fira, &apps, 1920, 1080);
    defer testing.allocator.free(d.pixels);
    defer testing.allocator.free(d.tooltip_pixels);
    defer d.cache.deinit();
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
    try testing.expect(tip.y + @as(i32, @intCast(tip.height)) < at.y);
    const middle = @as(f32, @floatFromInt(tip.x)) + @as(f32, @floatFromInt(tip.width)) / 2;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(at.x)) + r0.x + r0.size / 2, middle, 1);
    // Its corners are see-through, and its middle not; the name is drawn.
    const c = Theme.dark.colors();
    try testing.expectEqual(@as(u32, 0), tip.pixels[0] >> 24);
    try testing.expectEqual(c.tooltip_background, tip.pixels[(tip.height / 2) * tip.width + 2]);
    var text_pixels: usize = 0;
    for (tip.pixels) |px| if (px != c.tooltip_background and px >> 24 == 0xff) {
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
    var d = try Dock.init(testing.allocator, null, &apps, 1920, 1080);
    defer testing.allocator.free(d.pixels);
    defer testing.allocator.free(d.tooltip_pixels);
    defer d.cache.deinit();
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
