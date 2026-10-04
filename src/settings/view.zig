//! The settings app's window, as widgets: cards about the system (its
//! build, Linux and the board), the resources in use (with meters) and the
//! network, in two columns.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const info = @import("info.zig");

/// The storage bar's colours (the system's is the theme's primary).
pub const apps_color = gfx.Color.argb(0xff4fd8c4);
pub const user_color = gfx.Color.argb(0xffffb68a);

pub const Settings = struct {
    commit: []const u8,
    system: *const info.System,
    usage: info.Usage,
    network: *const info.Network,
    /// Sizes are designed for a window 900 pixels high and scale with it.
    scale: f32,

    pub fn build(self: *const Settings, cx: *ui.Context) ui.Widget {
        const s = self.scale;
        const t = &cx.ui.theme;
        const b: Builder = .{ .cx = cx, .s = s };
        return cx.make(ui.Padding{ .padding = .all(@floor(32 * s)), .child = cx.make(ui.Column{
            .cross_axis_alignment = .stretch,
            .spacing = 20 * s,
            .children = &.{
                cx.make(ui.Text{ .text = "Settings", .style = .{ .size = 44 * s, .color = t.on_surface }, .wrap = false }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 20 * s, .children = &.{
                    cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 20 * s, .children = &.{
                        self.systemCard(b),
                        self.networkCard(b),
                    } }) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 20 * s, .children = &.{
                        self.resourcesCard(b),
                    } }) }),
                } }) }),
            },
        }) });
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

    fn networkCard(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const net = self.network;
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        rows.append(a, b.item("Name", orUnknown(self.system.hostname.slice()))) catch {};
        if (net.len == 0) {
            rows.append(a, b.item("Status", "No network adapter: plug in a USB Ethernet adapter")) catch {};
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
            const method = if (self.system.static_ip.len > 0) "static" else "DHCP";
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
        return b.card("Network", rows.items);
    }
};

fn orUnknown(s: []const u8) []const u8 {
    return if (s.len == 0) "Unknown" else s;
}

fn fraction(part: u64, whole: u64) f32 {
    if (whole == 0) return 0;
    return @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(whole));
}

/// Makes the cards and their rows, sized for the window.
const Builder = struct {
    cx: *ui.Context,
    s: f32,

    fn card(b: Builder, title: []const u8, rows: []const ui.Widget) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const children = cx.ui.arena().alloc(ui.Widget, rows.len + 1) catch return cx.make(ui.Empty{});
        children[0] = cx.make(ui.Padding{ .padding = .{ .bottom = 4 * b.s }, .child = cx.make(ui.Text{ .text = title, .style = .{ .size = 24 * b.s, .color = t.primary }, .wrap = false }) });
        @memcpy(children[1..], rows);
        return cx.make(ui.Decorated{ .color = t.surface_container, .radius = .all(16 * b.s), .child = cx.make(ui.Padding{
            .padding = .all(@floor(20 * b.s)),
            .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 10 * b.s, .children = children }),
        }) });
    }

    fn label(b: Builder, text: []const u8) ui.Widget {
        const cx = b.cx;
        return cx.make(ui.SizedBox{ .width = 150 * b.s, .child = cx.make(ui.Text{ .text = text, .style = .{ .size = 18 * b.s, .color = cx.ui.theme.on_surface_variant }, .wrap = false }) });
    }

    fn value(b: Builder, text: []const u8) ui.Widget {
        return b.cx.make(ui.Text{ .text = text, .style = .{ .size = 18 * b.s, .color = b.cx.ui.theme.on_surface } });
    }

    /// A label and its value.
    fn item(b: Builder, name: []const u8, text: []const u8) ui.Widget {
        return b.cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12 * b.s, .children = &.{
            b.label(name),
            b.cx.make(ui.Expanded{ .child = b.value(text) }),
        } });
    }

    /// Storage: what the system, the apps and the user take, in a bar of
    /// coloured segments with a key above, and the free space below.
    fn storage(b: Builder, st: info.Storage) ui.Widget {
        const cx = b.cx;
        const t = &cx.ui.theme;
        const total = st.total();
        const parts = [_]struct { name: []const u8, bytes: u64, color: gfx.Color }{
            .{ .name = "System", .bytes = st.system, .color = t.primary },
            .{ .name = "Apps", .bytes = st.apps, .color = apps_color },
            .{ .name = "User", .bytes = st.user, .color = user_color },
        };
        const a = cx.ui.arena();
        const segments = a.alloc(SegmentBar.Segment, parts.len) catch return cx.make(ui.Empty{});
        const key = a.alloc(ui.Widget, parts.len) catch return cx.make(ui.Empty{});
        const dot = @round(10 * b.s);
        for (parts, segments, key) |part, *seg, *k| {
            var buf: [32]u8 = undefined;
            seg.* = .{ .fraction = fraction(part.bytes, total), .color = part.color };
            k.* = cx.make(ui.Row{ .spacing = 6 * b.s, .main_axis_size = .min, .children = &.{
                cx.make(ui.SizedBox{ .width = dot, .height = dot, .child = cx.make(ui.Decorated{ .color = part.color, .radius = .all(dot / 2) }) }),
                cx.make(ui.Text{ .text = cx.fmt("{s} {s}", .{ part.name, info.formatBytes(&buf, part.bytes) }), .style = .{ .size = 16 * b.s, .color = t.on_surface }, .wrap = false }),
            } });
        }
        var free_buf: [32]u8 = undefined;
        return cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12 * b.s, .children = &.{
            b.label("Storage"),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 6 * b.s, .children = &.{
                cx.make(ui.Row{ .spacing = 16 * b.s, .main_axis_size = .min, .children = key }),
                cx.make(SegmentBar{ .segments = segments, .height = @max(@round(8 * b.s), 4) }),
                b.value(cx.fmt("{s} free", .{info.formatBytes(&free_buf, st.free)})),
            } }) }),
        } });
    }

    /// A label, its value and a meter showing how much is used.
    fn meter(b: Builder, name: []const u8, text: []const u8, used: f32) ui.Widget {
        const cx = b.cx;
        return cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12 * b.s, .children = &.{
            b.label(name),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 6 * b.s, .children = &.{
                b.value(text),
                cx.make(Meter{ .fraction = used, .height = @max(@round(8 * b.s), 4) }),
            } }) }),
        } });
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

fn sample() struct { sys: info.System, net: info.Network, usage: info.Usage } {
    const sys: info.System = .{ .model = .of("Raspberry Pi Zero W Rev 1.1"), .cores = 1, .serial = .of("a1b2c3d4"), .kernel = .of("6.12.0 (armv6l)"), .hostname = .of("stardust") };
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

test "everything is shown, and fits the window at the shell's sizes" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    for ([_][2]u32{ .{ 1920, 960 }, .{ 1280, 600 }, .{ 1024, 668 } }) |size| {
        const scale = scaleFor(size[0], size[1]);
        u.frame(size[0], size[1], 0, Settings{ .commit = "574d538", .system = &d.sys, .usage = d.usage, .network = &d.net, .scale = scale });
        try testing.expect(!overflows(u.root.?));
    }
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    texts(u.root.?, &all);
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
        "300 MB free",
        "2 h 5 min",
        "Connected at 100 Mb/s",
        "192.168.1.42/24 (DHCP)",
        "12 MB received, 3.0 MB sent",
        "Not connected: no cable",
        "192.168.1.1",
    }) |want| {
        if (std.mem.indexOf(u8, all.items, want) == null) {
            std.debug.print("missing \"{s}\" in:\n{s}\n", .{ want, all.items });
            return error.TestUnexpectedResult;
        }
    }
    // The build is in the system card, not beside the title; the hardware
    // is the board alone.
    for ([_][]const u8{ "Stardust build", "Hardware\n", "Chip", "GPU\n", "Revision", "In use" }) |gone| {
        try testing.expect(std.mem.indexOf(u8, all.items, gone) == null);
    }
}

test "without a network adapter, the network card says so" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    const none: info.Network = .{};
    u.frame(1920, 960, 0, Settings{ .commit = "x", .system = &d.sys, .usage = .{}, .network = &none, .scale = 1 });
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    texts(u.root.?, &all);
    try testing.expect(std.mem.indexOf(u8, all.items, "No network adapter") != null);
    try testing.expect(std.mem.indexOf(u8, all.items, "Measuring") != null);
}

/// The scale for a window: designed for 900 pixels high (and 1500 wide).
pub fn scaleFor(width: u32, height: u32) f32 {
    return std.math.clamp(@min(@as(f32, @floatFromInt(width)) / 1500, @as(f32, @floatFromInt(height)) / 900), 0.5, 2);
}
