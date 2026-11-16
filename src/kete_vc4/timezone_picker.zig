//! Choosing a time zone, as setup and Settings do: two dropdowns, its area
//! (Europe, Pacific, …) and its city in that area. Choosing an area
//! chooses its first city, to be changed.
//!
//!     cx.make(kete_vc4.TimeZonePicker{ .zone = current, .on_changed = .of(st, State.setZone) })

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");

const TimeZone = locale.TimeZone;

pub const TimeZonePicker = struct {
    zone: TimeZone,
    /// Called with the zone chosen; without it, the dropdowns are disabled.
    on_changed: ?kete.ValueCallback(TimeZone) = null,

    pub fn build(self: *const TimeZonePicker, cx: *kete.BuildContext) kete.Widget {
        const a = cx.arena;
        const pick = a.create(Pick) catch return cx.make(kete.SizedBox.empty);
        pick.* = .{ .on_changed = self.on_changed, .zone = self.zone };
        const area = self.zone.area();
        var areas: std.ArrayList(kete.MenuItem) = .empty;
        var area_index: ?usize = null;
        for (TimeZone.areas, 0..) |name, i| {
            areas.append(a, .{ .label = name }) catch {};
            if (std.mem.eql(u8, name, area)) area_index = i;
        }
        const in_area = TimeZone.inArea(area);
        pick.first = in_area.first;
        var cities: std.ArrayList(kete.MenuItem) = .empty;
        for (0..in_area.count) |i| {
            const z: TimeZone = @enumFromInt(in_area.first + i);
            const buf = a.alloc(u8, z.name().len) catch break;
            cities.append(a, .{ .label = z.city(buf) }) catch {};
        }
        const enabled = self.on_changed != null;
        return cx.make(kete.Row{ .cross_axis_alignment = .center, .spacing = 12, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.DropdownMenu{
                .options = areas.items,
                .selected = area_index,
                .on_selected = if (enabled) .of(pick, Pick.chooseArea) else null,
                .width = 130,
            }),
            cx.make(kete.DropdownMenu{
                .options = cities.items,
                .selected = @intFromEnum(self.zone) - in_area.first,
                .on_selected = if (enabled) .of(pick, Pick.chooseCity) else null,
                .width = 230,
            }),
        }) catch &.{} });
    }

    const Pick = struct {
        on_changed: ?kete.ValueCallback(TimeZone),
        zone: TimeZone,
        /// The shown area's first zone.
        first: u16 = 0,

        fn chooseArea(p: *Pick, i: usize) void {
            if (i >= TimeZone.areas.len) return;
            const name = TimeZone.areas[i];
            if (std.mem.eql(u8, name, p.zone.area())) return;
            if (p.on_changed) |cb| cb.call(@enumFromInt(TimeZone.inArea(name).first));
        }

        fn chooseCity(p: *Pick, i: usize) void {
            if (p.on_changed) |cb| cb.call(@enumFromInt(p.first + i));
        }
    };
};

const testing = std.testing;

const Chosen = struct {
    zone: ?TimeZone = null,

    fn set(c: *Chosen, z: TimeZone) void {
        c.zone = z;
    }
};

test "a time zone chosen by its area, then its city" {
    const f = try kete.font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var chosen: Chosen = .{};
    const picker: TimeZonePicker = .{ .zone = TimeZone.fromName("Europe/London").?, .on_changed = .of(&chosen, Chosen.set) };
    u.frame(800, 600, 0, picker);
    const pick = blk: {
        // The Pick the build made, through the dropdowns' callbacks.
        var found: ?*TimeZonePicker.Pick = null;
        var stack: std.ArrayList(*kete.WidgetNode) = .empty;
        defer stack.deinit(testing.allocator);
        try stack.append(testing.allocator, u.root.?);
        while (stack.pop()) |n| {
            if (n.widget.as(kete.DropdownMenu)) |d| if (d.on_selected) |cb| {
                found = @ptrCast(@alignCast(cb.ctx));
            };
            for (n.children.items) |c| try stack.append(testing.allocator, c);
        }
        break :blk found.?;
    };
    // Pacific: its first city.
    const pacific = for (TimeZone.areas, 0..) |name, i| {
        if (std.mem.eql(u8, name, "Pacific")) break i;
    } else unreachable;
    pick.chooseArea(pacific);
    try testing.expectEqualStrings("Pacific", chosen.zone.?.area());
    // In Europe still: a city there.
    pick.chooseCity(1);
    try testing.expectEqualStrings("Europe", chosen.zone.?.area());
}
