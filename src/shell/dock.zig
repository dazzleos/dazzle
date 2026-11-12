//! The dock along the bottom of the screen: an icon for each app in /data/apps,
//! and for the shell's own (Settings). Clicking one starts the app or, if it
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
const font = @import("font");
const icons = @import("icons");
const audio = @import("audio");
const theme_settings = @import("ui").theme;

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
            },
            .light => .{
                .background = 0xffe8eef8,
                .hover_background = 0xffd0dcf0,
                .status_border = 0xffb0c2e0,
                .dot = 0xff1c2a4a,
                .status_active = 0xff1c2a4a,
                .status_inactive = 0x401c2a4a,
            },
        };
    }
};

/// The theme and the desktop's colour, as chosen in Settings.
pub const Appearance = struct {
    theme: Theme = .dark,
    background: u32 = theme_settings.Background.navy.argb(),

    pub fn parse(text: []const u8) Appearance {
        const s = theme_settings.Settings.parse(text);
        return .{
            .theme = switch (s.theme) {
                .dark => .dark,
                .light => .light,
            },
            .background = s.background.argb(),
        };
    }
};

pub fn readAppearance() Appearance {
    var buf: [128]u8 = undefined;
    return .parse(sys.readFile(appearance_file, &buf) orelse "");
}

const background = Theme.dark.colors().background;
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

/// Linux key codes (linux/input-event-codes.h) for Super shortcuts:
/// Super+1..9,0 open the app at that position in the dock; Super+S opens
/// Settings.
pub const key_1 = 2;
pub const key_0 = 11;
pub const key_s = 31;

/// Which app in `apps` a Super+<key> shortcut opens, if any.
pub fn shortcutApp(apps: []const App, key_code: u32) ?usize {
    if (key_code == key_s) {
        for (apps, 0..) |app, i| {
            if (std.mem.eql(u8, app.name, "dazzle-settings")) return i;
        }
        return null;
    }
    if (key_code >= key_1 and key_code <= key_0) {
        const i: usize = key_code - key_1;
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
/// still there; frees `old`.
pub fn rescan(gpa: std.mem.Allocator, old: []App, dir_path: []const u8, builtin: []const []const u8) ![]App {
    const new = try findApps(gpa, dir_path, builtin);
    for (new) |*app| for (old) |o| {
        if (std.mem.eql(u8, app.name, o.name)) app.pid = o.pid;
    };
    freeApps(gpa, old);
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

        pub const all: Changes = .{ .apps = true, .sound = true, .appearance = true };

        pub fn any(c: Changes) bool {
            return c.apps or c.sound or c.appearance;
        }
    };

    const mask = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CLOSE_WRITE | linux.IN.ONLYDIR;
    const sound_name = std.fs.path.basename(audio.settings_file);
    const appearance_name = std.fs.path.basename(appearance_file);

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
    pixels: []u32,
    width: u32,
    height: u32,
    scale: f32,
    apps: []App,
    /// The app under the pointer.
    hover: ?usize = null,
    /// Network status shown in the status box on the right of the dock.
    network: NetworkStatus = .{ .offline = .{} },
    /// Whether data is moving, shown as arrows beside the network status.
    activity: Activity = .{},
    /// Volume status shown in the status box beside the network status.
    volume: VolumeStatus = .{},
    /// Light or dark colour scheme (from `/data/apps/.appearance`).
    theme: Theme = .dark,

    pub fn init(gpa: std.mem.Allocator, f: ?font.Font, apps: []App, screen_width: u32, screen_height: u32) !Dock {
        const scale = @min(@as(f32, @floatFromInt(screen_width)) / 1920, @as(f32, @floatFromInt(screen_height)) / 1080);
        const height: u32 = @intFromFloat(@round(76 * scale));
        return .{
            .font = f,
            .icon_font = font.Font.init(icons.font_data) catch null,
            .cache = font.GlyphCache.init(gpa),
            .pixels = try gpa.alloc(u32, @as(usize, screen_width) * height),
            .width = screen_width,
            .height = height,
            .scale = scale,
            .apps = apps,
        };
    }

    pub const Rect = struct { x: f32, y: f32, size: f32 };
    /// The status box's width (at 1080p): the volume, the network and its
    /// activity arrows.
    const status_box_width = 124;
    pub const StatusRect = struct { x: f32, y: f32, width: f32, height: f32 };

    /// Where app `i`'s icon is, in the dock: the icons and the status box
    /// on the right are in a row in the middle.
    pub fn iconRect(d: *const Dock, i: usize) Rect {
        const size = 56 * d.scale;
        const gap = 20 * d.scale;
        const status_width = status_box_width * d.scale;
        const row = @as(f32, @floatFromInt(d.apps.len)) * (size + gap) + status_width;
        const x0 = (@as(f32, @floatFromInt(d.width)) - row) / 2;
        return .{ .x = x0 + @as(f32, @floatFromInt(i)) * (size + gap), .y = 6 * d.scale, .size = size };
    }

    /// Where the status box (volume and network) is, to the right of the rightmost app.
    pub fn statusRect(d: *const Dock) StatusRect {
        const r = d.iconRect(d.apps.len);
        return .{ .x = r.x, .y = r.y, .width = status_box_width * d.scale, .height = r.size };
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
        const c = d.theme.colors();
        const canvas: font.Canvas = .{ .pixels = d.pixels, .width = d.width, .height = d.height, .stride = d.width };
        canvas.fill(0, 0, d.width, d.height, c.background);
        const icon_font: ?*const font.Font = if (d.icon_font) |*f| f else null;
        for (d.apps, 0..) |*app, i| {
            const r = d.iconRect(i);
            if (d.hover == i) {
                const pad = 4 * d.scale;
                roundedRect(canvas, r.x - pad, r.y - pad, r.size + 2 * pad, r.size + 2 * pad, 14 * d.scale, c.hover_background);
            }
            roundedRect(canvas, r.x, r.y, r.size, r.size, 12 * d.scale, app.color());
            if (app.icon != null and icon_font != null) {
                // Icons fill the em square, with the baseline at the bottom.
                const size = @round(36 * d.scale);
                const style: font.Style = .{ .font = icon_font.?, .size = size, .color = 0xffffffff };
                var buf: [4]u8 = undefined;
                const x = @round(r.x + (r.size - size) / 2);
                const y = @round(r.y + (r.size - size) / 2);
                _ = font.draw(canvas, &d.cache, style, x, y + size, icons.text(app.icon.?, &buf)) catch {};
            } else if (d.font) |*f| {
                const style: font.Style = .{ .font = f, .size = 30 * d.scale, .color = 0xffffffff };
                const initial = app.label[0..1];
                const baseline = r.y + r.size / 2 + style.ascent() * 0.36;
                _ = font.draw(canvas, &d.cache, style, r.x + (r.size - font.measure(style, initial)) / 2, baseline, initial) catch {};
            }
            if (app.pid != null) {
                const dot = 6 * d.scale;
                roundedRect(canvas, r.x + (r.size - dot) / 2, r.y + r.size + 3 * d.scale, dot, dot, dot / 2, c.dot);
            }
        }
        const rs = d.statusRect();
        roundedRectOutline(canvas, rs.x, rs.y, rs.width, rs.height, 12 * d.scale, @max(1.5, 2 * d.scale), c.status_border);
        if (icon_font) |f| {
            const size = @round(36 * d.scale);
            const pad = @round(10 * d.scale);
            const y = @round(rs.y + (rs.height - size) / 2);
            const vol_x = @round(rs.x + pad);
            const arrow = @round(18 * d.scale);
            const arrows_x = @round(rs.x + rs.width - pad - arrow);
            const net_x = @round(arrows_x - 4 * d.scale - size);
            var buf: [4]u8 = undefined;
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
    /// (null: elsewhere). Returns whether it changed.
    pub fn pointerAt(d: *Dock, x: ?f64, y: f64) bool {
        const under = if (x) |px| d.hit(px, y) else null;
        if (under == d.hover) return false;
        d.hover = under;
        return true;
    }
};

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

test "icons and the status box are in a row in the middle, and clicks find the apps" {
    var apps = [_]App{
        .{ .name = "a", .label = "A", .path = "/apps/a/a", .icon = .folder },
        .{ .name = "b", .label = "B", .path = "/apps/b/b" },
    };
    var d = try Dock.init(testing.allocator, null, &apps, 1920, 1080);
    defer testing.allocator.free(d.pixels);
    defer d.cache.deinit();
    try testing.expectEqual(@as(u32, 76), d.height);
    const r0 = d.iconRect(0);
    const r1 = d.iconRect(1);
    const rs = d.statusRect();
    try testing.expectApproxEqAbs(@as(f32, 1920) - (rs.x + rs.width), r0.x, 0.01);
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
    try testing.expect(d.pointerAt(r1.x + 1, r1.y + 1));
    try testing.expect(!d.pointerAt(r1.x + 2, r1.y + 2));
    apps[0].pid = 42;
    d.network = .ethernet;
    d.volume = .{ .volume = 75, .muted = false };
    d.draw();
    const at = struct {
        fn f(dock: *const Dock, x: f32, y: f32) u32 {
            return dock.pixels[@as(usize, @intFromFloat(y)) * dock.width + @as(usize, @intFromFloat(x))];
        }
    }.f;
    try testing.expectEqual(@as(u32, background), at(&d, 5, 5));
    try testing.expectEqual(apps[0].color(), at(&d, r0.x + r0.size / 2, r0.y + 4));
    try testing.expectEqual(@as(u32, dot_color), at(&d, r0.x + r0.size / 2, r0.y + r0.size + 6));
    try testing.expectEqual(@as(u32, background), at(&d, r1.x + r1.size / 2, r1.y + r1.size + 6));
    try testing.expectEqual(@as(u32, hover_background), at(&d, r1.x - 2, r1.y + r1.size / 2));
    // The first app's icon is drawn in white in the middle of its square.
    try testing.expectEqual(@as(u32, 0xffffffff), at(&d, r0.x + r0.size / 2, r0.y + r0.size / 2));
    // The status box has an outline at its top edge, is unfilled inside its padding, and draws the volume and network icons inside it.
    try testing.expectEqual(@as(u32, status_border), at(&d, rs.x + rs.width / 2, rs.y + 1));
    try testing.expectEqual(@as(u32, background), at(&d, rs.x + rs.width / 2, rs.y + 5));

    // Switching to the light theme updates the dock background, hover, running dot, and status border.
    try testing.expectEqual(Appearance{}, Appearance.parse(""));
    try testing.expectEqual(Appearance{ .theme = .light, .background = 0xff000000 }, Appearance.parse("theme light\nbackground black\n"));
    d.theme = .light;
    d.draw();
    const light = Theme.light.colors();
    try testing.expectEqual(light.background, at(&d, 5, 5));
    try testing.expectEqual(light.dot, at(&d, r0.x + r0.size / 2, r0.y + r0.size + 6));
    try testing.expectEqual(light.hover_background, at(&d, r1.x - 2, r1.y + r1.size / 2));
    try testing.expectEqual(light.status_border, at(&d, rs.x + rs.width / 2, rs.y + 1));
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
    try testing.expectEqual(@as(?usize, 2), shortcutApp(&apps, key_s));
    try testing.expectEqual(@as(?usize, 0), shortcutApp(&apps, key_1));
    try testing.expectEqual(@as(?usize, 1), shortcutApp(&apps, key_1 + 1));
    try testing.expectEqual(@as(?usize, 2), shortcutApp(&apps, key_1 + 2));
    try testing.expectEqual(@as(?usize, null), shortcutApp(&apps, key_1 + 3));
    try testing.expectEqual(@as(?usize, null), shortcutApp(&apps, 30));
}
