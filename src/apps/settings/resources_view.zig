//! The Resources page: CPU, CPU memory, GPU memory (with a menu to choose
//! its size for the next start) and storage (system, apps, user and free).

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const info = @import("info.zig");
const sys_mod = @import("sys");
const proto = sys_mod.system;
const view = @import("view.zig");

const Settings = view.Settings;
const Actions = view.Actions;
const Builder = view.Builder;

pub const label = "Resources";
pub const icon: ui.icons.Icon = .speed;

/// The storage bar's colours (the system's is the theme's primary).
pub const apps_color = gfx.Color.argb(0xff4fd8c4);
pub const user_color = gfx.Color.argb(0xffffb68a);

/// Video memory (see `sys.system.video_memory_sizes`), in MiB: what the GPU
/// may have now, and from the next start; null if not known.
pub const VideoMemory = struct {
    now: ?u16 = null,
    next: ?u16 = null,
    /// Asking for a change failed.
    failed: bool = false,
};

pub fn build(self: *const Settings, b: Builder) ui.Widget {
    const cx = b.cx;
    const u = self.usage;
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const cores = self.system.cores;
    const cpu = if (u.cpu_busy) |busy| cx.fmt("{d:.0}% busy ({d} {s})", .{ busy, cores, if (cores == 1) "core" else "cores" }) else "Measuring…";
    const mem = cx.fmt("{s} of {s} in use", .{ info.formatBytes(&b1, u.memUsed()), info.formatBytes(&b2, u.mem_total) });
    return b.page(&.{
        meterRow(b, "CPU", cpu, (u.cpu_busy orelse 0) / 100),
        meterRow(b, "CPU Memory", mem, fraction(u.memUsed(), u.mem_total)),
        gpuMemoryRow(self, b),
        storageRow(b, u.storage),
    });
}

fn fraction(part: u64, whole: u64) f32 {
    if (whole == 0) return 0;
    return @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(whole));
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

/// A label, its value and a meter showing how much is used.
fn meterRow(b: Builder, name: []const u8, text: []const u8, used: f32) ui.Widget {
    const cx = b.cx;
    return cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 12, .children = &.{
        b.label(name),
        cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 6, .children = &.{
            b.value(text),
            cx.make(Meter{ .fraction = used, .height = @max(8, 4) }),
        } }) }),
    } });
}

/// Storage: what the system, the apps and the user take, and what is
/// free, in a bar of coloured segments with a key above.
fn storageRow(b: Builder, st: info.Storage) ui.Widget {
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
            cx.make(ui.OutlinedButton{ .label = "Restart", .icon = .restart_alt, .on_press = if (self.actions) |acts| .of(acts, restartNow) else null }),
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

/// An icon beside "GPU memory": pressing it offers the sizes in a menu
/// (those too big for the computer's memory dimmed).
pub const VideoMemoryMenu = struct {
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
                    .on_press = .of(acts, videoMemorySetter(mib)),
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

test "without usage readings, the Resources page says Measuring" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    const none: info.Network = .{};
    const settings: Settings = .{ .commit = "x", .system = &d.sys, .usage = .{}, .network = &none };
    u.frame(1920, 960, 0, settings);
    u.root.?.state(Settings.State).page = .resources;
    u.frame(1920, 960, 1, settings);
    try testing.expect(view.findText(u.root.?, "Measuring…") != null);
}

test "video memory: choosing a size, then a restart" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const d = view.sample();
    var actions: Actions = .{};
    var settings: Settings = .{ .commit = "de14aa2", .actions = &actions, .system = &d.sys, .usage = d.usage, .network = &d.net, .video_memory = .{ .now = 128, .next = 128 } };
    u.frame(1280, 720, 0, settings);
    u.root.?.state(Settings.State).page = .resources;
    u.frame(1280, 720, 1, settings);
    try testing.expect(view.findText(u.root.?, "Restart") == null);
    view.click(u, view.findType(u.root.?, VideoMemoryMenu).?);
    u.frame(1280, 720, 2, settings);
    // 434 MB of memory: no more than half of it.
    const menu = u.menu.?.content.items;
    try testing.expectEqualStrings("128 MB (chosen)", menu[2].label);
    try testing.expect(!menu[2].enabled);
    try testing.expect(menu[3].enabled and !menu[4].enabled);
    view.click(u, view.findText(u.menu_root.?, "192 MB").?);
    try testing.expectEqual(@as(?u16, 192), actions.video_memory);

    settings.video_memory = .{ .now = 128, .next = 192 };
    u.frame(1280, 720, 3, settings);
    try testing.expect(view.findText(u.root.?, "192 MB after a restart") != null);
    view.click(u, view.up(view.findText(u.root.?, "Restart").?, ui.OutlinedButton).?);
    try testing.expect(actions.restart);

    // Not known: nothing to change.
    settings.video_memory = .{};
    u.frame(1280, 720, 4, settings);
    actions = .{};
    view.click(u, view.findType(u.root.?, VideoMemoryMenu).?);
    try testing.expect(u.menu == null);
}
