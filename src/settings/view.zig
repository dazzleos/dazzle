//! The settings app's window, as widgets: cards about the system (its
//! build and Linux), the hardware, what is in use (with meters) and the
//! network, in two columns.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const info = @import("info.zig");

pub const Settings = struct {
    commit: []const u8,
    hardware: *const info.Hardware,
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
                cx.make(ui.Row{ .cross_axis_alignment = .end, .spacing = 16 * s, .main_axis_size = .min, .children = &.{
                    cx.make(ui.Text{ .text = "Settings", .style = .{ .size = 44 * s, .color = t.on_surface }, .wrap = false }),
                    cx.make(ui.Padding{ .padding = .{ .bottom = 6 * s }, .child = cx.make(ui.Text{ .text = cx.fmt("Stardust build {s}", .{self.commit}), .style = .{ .size = 20 * s, .color = t.on_surface_variant }, .wrap = false }) }),
                } }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 20 * s, .children = &.{
                    cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 20 * s, .children = &.{
                        self.system(b),
                        self.hardwareCard(b),
                    } }) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 20 * s, .children = &.{
                        self.usageCard(b),
                        self.networkCard(b),
                    } }) }),
                } }) }),
            },
        }) });
    }

    fn system(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        var dur: [32]u8 = undefined;
        return b.card("System", &.{
            b.item("Build", self.commit),
            b.item("Linux", self.hardware.kernel.slice()),
            b.item("Up for", cx.fmt("{s}", .{info.formatDuration(&dur, self.usage.uptime_s)})),
        });
    }

    fn hardwareCard(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const h = self.hardware;
        var mem: [32]u8 = undefined;
        const gpu = if (h.gpu) |g|
            cx.fmt("VideoCore IV (V3D {d}.{d}), {d} QPUs in {d} slices", .{ g.version, g.revision, g.qpus(), g.slices })
        else
            "VideoCore IV";
        return b.card("Hardware", &.{
            b.item("Board", orUnknown(h.model.slice())),
            b.item("Chip", orUnknown(h.soc.slice())),
            b.item("CPU", cx.fmt("{s}, {d} {s}", .{ orUnknown(h.cpu.slice()), h.cores, if (h.cores == 1) "core" else "cores" })),
            b.item("GPU", gpu),
            b.item("Memory", cx.fmt("{s}", .{info.formatBytes(&mem, self.usage.mem_total)})),
            b.item("Revision", orUnknown(h.revision.slice())),
            b.item("Serial", orUnknown(h.serial.slice())),
        });
    }

    fn usageCard(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const u = self.usage;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        const cores = self.hardware.cores;
        const cpu = if (u.cpu_busy) |busy| cx.fmt("{d:.0}% busy ({d} {s})", .{ busy, cores, if (cores == 1) "core" else "cores" }) else "Measuring…";
        const temperature = if (u.temperature) |c| cx.fmt("{d:.1} °C", .{c}) else "Unknown";
        const mem = cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) });
        const gpu = if (u.gpu_total > 0) cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.gpuUsed()), info.formatBytes(&b2, u.gpu_total) }) else "Unknown";
        const storage = cx.fmt("{s} in {d} files, in memory (loaded from the SD card at boot)", .{ info.formatBytes(&b1, u.storage_bytes), u.storage_files });
        return b.card("In use", &.{
            b.meter("CPU", cpu, (u.cpu_busy orelse 0) / 100),
            b.item("Temperature", temperature),
            b.meter("Memory", mem, fraction(u.memUsed(), u.mem_total)),
            b.meter("GPU memory", gpu, fraction(u.gpuUsed(), u.gpu_total)),
            b.item("Storage", storage),
        });
    }

    fn networkCard(self: *const Settings, b: Builder) ui.Widget {
        const cx = b.cx;
        const net = self.network;
        var rows: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();
        rows.append(a, b.item("Name", orUnknown(self.hardware.hostname.slice()))) catch {};
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
            const method = if (self.hardware.static_ip.len > 0) "static" else "DHCP";
            // An adapter without a link has no address or traffic to show.
            if (i.carrier or i.ip != null) {
                const address = if (i.ip) |ip|
                    cx.fmt("{d}.{d}.{d}.{d}/{d} ({s})", .{ ip[0], ip[1], ip[2], ip[3], i.prefix, method })
                else
                    cx.fmt("Waiting for an address ({s})", .{method});
                rows.append(a, b.item("Address", address)) catch {};
                rows.append(a, b.item("Traffic", cx.fmt("{s} received, {s} sent", .{ info.formatBytes(&b1, i.rx_bytes), info.formatBytes(&b2, i.tx_bytes) }))) catch {};
            }
            if (i.mac.len > 0) rows.append(a, b.item("Hardware", i.mac.slice())) catch {};
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

fn sample() struct { hw: info.Hardware, net: info.Network, usage: info.Usage } {
    var hw: info.Hardware = .{ .model = .of("Raspberry Pi Zero W Rev 1.1"), .soc = .of("BCM2835"), .cpu = .of("ARM1176JZF-S"), .cores = 1, .revision = .of("9000c1"), .serial = .of("a1b2c3d4"), .kernel = .of("6.12.0 (armv6l)"), .hostname = .of("stardust") };
    hw.gpu = info.decodeGpu(0x02443356, 0xc0102431);
    var net: info.Network = .{ .gateway = .{ 192, 168, 1, 1 } };
    net.interfaces[0] = .{ .name = .of("eth0"), .state = .of("up"), .carrier = true, .mac = .of("00:e0:4c:68:01:02"), .ip = .{ 192, 168, 1, 42 }, .prefix = 24, .speed = 100, .rx_bytes = 12 << 20, .tx_bytes = 3 << 20 };
    net.interfaces[1] = .{ .name = .of("eth1"), .state = .of("down") };
    net.len = 2;
    return .{ .hw = hw, .net = net, .usage = .{ .cpu_busy = 23, .temperature = 48.3, .mem_total = 434 << 20, .mem_available = 300 << 20, .gpu_total = 64 << 20, .gpu_free = 60 << 20, .storage_bytes = 10 << 20, .storage_files = 7, .uptime_s = 7500 } };
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
        u.frame(size[0], size[1], 0, Settings{ .commit = "574d538", .hardware = &d.hw, .usage = d.usage, .network = &d.net, .scale = scale });
        try testing.expect(!overflows(u.root.?));
    }
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    texts(u.root.?, &all);
    for ([_][]const u8{
        "Stardust build 574d538",
        "Raspberry Pi Zero W Rev 1.1",
        "ARM1176JZF-S, 1 core",
        "VideoCore IV (V3D 2.1), 12 QPUs in 3 slices",
        "23% busy (1 core)",
        "48.3 °C",
        "134 MB of 434 MB in use",
        "4.0 MB of 64 MB in use",
        "10 MB in 7 files",
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
}

test "without a network adapter, the network card says so" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = sample();
    const none: info.Network = .{};
    u.frame(1920, 960, 0, Settings{ .commit = "x", .hardware = &d.hw, .usage = .{}, .network = &none, .scale = 1 });
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
