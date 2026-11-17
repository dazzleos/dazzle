//! Choosing a time zone on a map, as setup and Settings do: the world
//! (Natural Earth's land, flat: longitude across, latitude up, from 58°S to
//! 84°N), each zone's place a dot on it, the chosen one marked and named.
//! Clicking (or touching) the map chooses the zone whose place is nearest;
//! a field above it finds zones by their cities ("auck", "new york",
//! "buenos"), the first few that match as buttons to choose, Enter the
//! first. Always left to right, as the map is.
//!
//!     cx.make(kete_vc4.TimeZoneMap{ .zone = current, .on_changed = .of(st, State.setZone) })

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const world = @import("world_map");

const TimeZone = locale.TimeZone;

/// The latitudes shown (Antarctica's coast, and the far north, left out).
const north: f32 = 84;
const south: f32 = -58;

pub const TimeZoneMap = struct {
    zone: TimeZone,
    /// Called with the zone chosen; without it, nothing can be.
    on_changed: ?kete.ValueCallback(TimeZone) = null,
    /// Its width, and its map's (narrower if there is less room).
    width: f32 = 560,
    /// It fills the height it is given (in an Expanded), the map as big
    /// as fits in it, rather than as wide as `width`.
    fill_height: bool = false,

    pub const State = struct {
        query_buf: [64]u8 = undefined,
        query_len: u8 = 0,

        fn setQuery(st: *State, q: []const u8) void {
            st.query_len = @intCast(@min(q.len, st.query_buf.len));
            @memcpy(st.query_buf[0..st.query_len], q[0..st.query_len]);
        }

        fn query(st: *const State) []const u8 {
            return st.query_buf[0..st.query_len];
        }
    };

    /// How many matches show as buttons.
    const max_matches = 4;

    /// The map itself (for tests to find).
    pub const Map = MapView;

    pub fn build(self: *const TimeZoneMap, cx: *kete.BuildContext, st: *State) kete.Widget {
        const a = cx.arena;
        const t = cx.theme();
        var matches: [max_matches]TimeZone = undefined;
        const n = search(st.query(), &matches);
        var rows: std.ArrayList(kete.Widget) = .empty;
        const first = a.create(Choose) catch return cx.make(kete.SizedBox.empty);
        first.* = .{ .zone = if (n > 0) matches[0] else self.zone, .on_changed = self.on_changed, .state = st };
        rows.append(a, cx.make(kete.TextField{
            .placeholder = locale.text("Search"),
            .on_changed = .of(st, State.setQuery),
            .on_submit = if (n > 0 and self.on_changed != null) .of(first, Choose.call) else null,
            .width = std.math.inf(f32),
        })) catch {};
        if (st.query().len > 0) {
            var buttons: std.ArrayList(kete.Widget) = .empty;
            for (matches[0..n]) |z| {
                const ch = a.create(Choose) catch continue;
                ch.* = .{ .zone = z, .on_changed = self.on_changed, .state = st };
                var buf: [64]u8 = undefined;
                buttons.append(a, cx.make(kete.OutlinedButton{
                    .label = a.dupe(u8, z.city(&buf)) catch "",
                    .on_press = if (self.on_changed != null) .of(ch, Choose.call) else null,
                })) catch {};
            }
            if (n == 0) buttons.append(a, cx.make(kete.Text{ .text = locale.text("No time zone matches"), .style = .{ .size = 15, .color = t.on_surface_variant } })) catch {};
            rows.append(a, cx.make(kete.Row{ .fill = false, .spacing = 8, .cross_axis_alignment = .center, .children = buttons.items })) catch {};
        }
        const map = cx.make(MapView{ .zone = self.zone, .on_changed = self.on_changed, .width = self.width });
        rows.append(a, if (self.fill_height) cx.make(kete.Expanded{ .child = cx.make(kete.Align{ .alignment = .top_left, .child = map }) }) else map) catch {};
        var label_buf: [96]u8 = undefined;
        rows.append(a, cx.make(kete.Text{ .text = a.dupe(u8, self.zone.label(&label_buf)) catch "", .style = .{ .size = 16, .color = t.on_surface } })) catch {};
        // As wide as asked, or as there is room for.
        return cx.make(kete.LeftToRight{ .child = cx.make(kete.SizedBox{ .width = self.width, .child = cx.make(kete.Column{ .fill = self.fill_height, .cross_axis_alignment = .stretch, .spacing = 8, .children = rows.items }) }) });
    }

    /// A zone chosen (from the search): the search is done with.
    const Choose = struct {
        zone: TimeZone,
        on_changed: ?kete.ValueCallback(TimeZone),
        state: *State,

        fn call(c: *Choose) void {
            if (c.on_changed) |f| f.call(c.zone);
        }
    };

    /// The zones whose cities (or names) have `q` in them, those that
    /// start so first; at most `out.len`.
    pub fn search(q: []const u8, out: []TimeZone) usize {
        if (q.len == 0) return 0;
        var n: usize = 0;
        inline for (.{ true, false }) |starting| {
            for (1..TimeZone.count) |i| {
                if (n == out.len) return n;
                const z: TimeZone = @enumFromInt(i);
                var buf: [64]u8 = undefined;
                const c = z.city(&buf);
                // The city's last part ("Buenos Aires" of "Argentina/Buenos
                // Aires"), its whole, or the zone's name.
                const last = c[if (std.mem.lastIndexOfScalar(u8, c, '/')) |s| s + 1 else 0..];
                const hit = if (starting)
                    std.ascii.startsWithIgnoreCase(last, q)
                else
                    !std.ascii.startsWithIgnoreCase(last, q) and (std.ascii.findIgnoreCase(c, q) != null or std.ascii.findIgnoreCase(z.name(), q) != null);
                if (hit) {
                    out[n] = z;
                    n += 1;
                }
            }
        }
        return n;
    }
};

/// The map: the land, the zones' places, the chosen one marked.
const MapView = struct {
    zone: TimeZone,
    on_changed: ?kete.ValueCallback(TimeZone),
    width: f32,

    pub fn layout(self: *const MapView, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        // As wide as asked, or as fits (across, and down).
        var w = @min(self.width, if (std.math.isFinite(c.max_w)) c.max_w else self.width);
        if (std.math.isFinite(c.max_h)) w = @min(w, c.max_h * 360 / (north - south));
        return c.constrain(.{ .w = w, .h = w * (north - south) / 360 });
    }

    /// Where a place is on the map.
    pub fn at(size: kete.Size, lat: f32, lon: f32) kete.Point {
        return .{ (lon + 180) / 360 * size.w, (north - lat) / (north - south) * size.h };
    }

    /// The zone whose place is nearest `p`, if any is near it.
    fn zoneAt(size: kete.Size, p: kete.Point) ?TimeZone {
        var best: ?TimeZone = null;
        var best_d: f32 = 24 * 24;
        for (1..TimeZone.count) |i| {
            const z: TimeZone = @enumFromInt(i);
            const pl = z.place() orelse continue;
            const q = at(size, pl.lat, pl.lon);
            const d = (q[0] - p[0]) * (q[0] - p[0]) + (q[1] - p[1]) * (q[1] - p[1]);
            if (d < best_d) {
                best_d = d;
                best = z;
            }
        }
        return best;
    }

    pub fn event(self: *const MapView, n: *kete.WidgetNode, e: kete.Event) bool {
        if (self.on_changed == null) return false;
        switch (e) {
            .press => |p| return p.button == .left,
            .release => |r| if (r.inside) if (zoneAt(n.size, r.pos)) |z| if (self.on_changed) |f| f.call(z),
            else => {},
        }
        return false;
    }

    pub fn paint(self: *const MapView, n: *kete.WidgetNode, p: *kete.Painter) void {
        const t = n.theme();
        const size = n.size;
        const a = n.ui.arena();
        var c = p.canvas();
        // The sea, then the land.
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = size.w, .h = size.h }, .all(8), t.surface_container);
        const old = p.clipTo(.{ .x = 0, .y = 0, .w = size.w, .h = size.h });
        defer p.restoreClip(old);
        c = p.canvas();
        const land = t.on_surface_variant.withAlpha(0.35);
        for (world.rings) |r| {
            const pts = a.alloc(kete.Point, r[1]) catch return;
            for (world.points[r[0]..][0..r[1]], pts) |w, *q| q.* = at(size, @as(f32, @floatFromInt(w[1])) / 100, @as(f32, @floatFromInt(w[0])) / 100);
            c.fillPath(&.{pts}, land);
        }
        // The zones' places.
        const dot = t.on_surface.withAlpha(0.55);
        for (1..TimeZone.count) |i| {
            const pl = @as(TimeZone, @enumFromInt(i)).place() orelse continue;
            c.fillCircle(at(size, pl.lat, pl.lon), 1.5, dot);
        }
        // The chosen one.
        if (self.zone.place()) |pl| {
            const q = at(size, pl.lat, pl.lon);
            c.fillCircle(q, 7, t.primary.withAlpha(0.3));
            c.fillCircle(q, 4, t.primary);
        }
    }
};

const testing = std.testing;

test "zones found by their cities, those starting so first" {
    var out: [4]TimeZone = undefined;
    const n = TimeZoneMap.search("auck", &out);
    try testing.expect(n >= 1);
    try testing.expectEqualStrings("Pacific/Auckland", out[0].name());
    try testing.expectEqualStrings("America/New_York", out[0..TimeZoneMap.search("new york", &out)][0].name());
    try testing.expectEqualStrings("America/Argentina/Buenos_Aires", out[0..TimeZoneMap.search("buenos", &out)][0].name());
    try testing.expectEqual(@as(usize, 0), TimeZoneMap.search("zzzz", &out));
}

test "a place on the map, and the zone nearest a point" {
    const size: kete.Size = .{ .w = 720, .h = 284 };
    const auckland = TimeZone.fromName("Pacific/Auckland").?;
    const pl = auckland.place().?;
    const q = MapView.at(size, pl.lat, pl.lon);
    try testing.expect(q[0] > 700 and q[1] > 150);
    try testing.expectEqual(auckland, MapView.zoneAt(size, .{ q[0] + 2, q[1] - 1 }).?);
    // Far from any (the middle of the Pacific).
    try testing.expect(MapView.zoneAt(size, MapView.at(size, -40, -130)) == null);
}
