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

        pub fn setQuery(st: *State, q: []const u8) void {
            st.query_len = @intCast(@min(q.len, st.query_buf.len));
            @memcpy(st.query_buf[0..st.query_len], q[0..st.query_len]);
        }

        pub fn query(st: *const State) []const u8 {
            return st.query_buf[0..st.query_len];
        }
    };

    /// How many matches show as buttons.
    const max_matches = 4;

    /// The map itself (for tests to find, and for a map alone).
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
    pub const Choose = struct {
        zone: TimeZone,
        on_changed: ?kete.ValueCallback(TimeZone),
        state: *State,

        pub fn call(c: *Choose) void {
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

/// The map: the land, the zones' places, the chosen one marked. With
/// `bands`, the world's time zones too (Natural Earth's: the regions an
/// hour, or part of one, ahead of or behind UTC, by their borders), every
/// other hour shaded, their outlines drawn, the chosen zone's region lit;
/// clicking where no place is near chooses the zone in that region nearest
/// the click. A zone's region is its standard time's (summer time moves a
/// clock, not where it is).
pub const MapView = struct {
    zone: TimeZone,
    on_changed: ?kete.ValueCallback(TimeZone) = null,
    width: f32 = 560,
    bands: bool = false,

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

    /// The time zone region at `p`: its quarter hours ahead of UTC.
    pub fn regionAt(size: kete.Size, p: kete.Point) ?i8 {
        for (world.zones) |z| for (world.zone_triangles[z.triangles[0]..][0..z.triangles[1]]) |tri| {
            var q: [3]kete.Point = undefined;
            for (tri, &q) |k, *o| o.* = onMap(size, world.zone_points[k]);
            if (inTriangle(p, q)) return z.quarter_hours;
        };
        return null;
    }

    /// Where a point of the world map's (hundredths of a degree) is.
    fn onMap(size: kete.Size, w: [2]i16) kete.Point {
        return at(size, @as(f32, @floatFromInt(w[1])) / 100, @as(f32, @floatFromInt(w[0])) / 100);
    }

    fn inTriangle(p: kete.Point, t: [3]kete.Point) bool {
        const d0 = (t[1][0] - t[0][0]) * (p[1] - t[0][1]) - (t[1][1] - t[0][1]) * (p[0] - t[0][0]);
        const d1 = (t[2][0] - t[1][0]) * (p[1] - t[1][1]) - (t[2][1] - t[1][1]) * (p[0] - t[1][0]);
        const d2 = (t[0][0] - t[2][0]) * (p[1] - t[2][1]) - (t[0][1] - t[2][1]) * (p[0] - t[2][0]);
        return (d0 >= 0 and d1 >= 0 and d2 >= 0) or (d0 <= 0 and d1 <= 0 and d2 <= 0);
    }

    /// The zone nearest `p` of those in its region (whose standard time is
    /// the region's), if any is.
    pub fn zoneInBand(size: kete.Size, p: kete.Point) ?TimeZone {
        const quarters = regionAt(size, p) orelse return null;
        var best: ?TimeZone = null;
        var best_d: f32 = std.math.inf(f32);
        for (1..TimeZone.count) |i| {
            const z: TimeZone = @enumFromInt(i);
            const pl = z.place() orelse continue;
            if (@divFloor(z.standardOffset(), 900) != quarters) continue;
            const q = at(size, pl.lat, pl.lon);
            const d = (q[0] - p[0]) * (q[0] - p[0]) + (q[1] - p[1]) * (q[1] - p[1]);
            if (d < best_d) {
                best_d = d;
                best = z;
            }
        }
        return best;
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
            .release => |r| if (r.inside) if (zoneAt(n.size, r.pos) orelse if (self.bands) zoneInBand(n.size, r.pos) else null) |z| if (self.on_changed) |f| f.call(z),
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
        // In one go, their edges not smoothed: smoothed one by one, each
        // triangle's edges let the sea through a little where it meets the
        // next, and the land (thousands of triangles, many smaller than a
        // pixel) came out speckled.
        const land = mix(t.surface_container, t.on_surface_variant, 0.35);
        const corners = a.alloc([3]f32, world.triangles.len * 3) catch return;
        for (world.triangles, 0..) |tri, i| for (tri, 0..) |k, j| {
            const w = world.points[k];
            const q = at(size, @as(f32, @floatFromInt(w[1])) / 100, @as(f32, @floatFromInt(w[0])) / 100);
            corners[i * 3 + j] = .{ q[0], q[1], 1 };
        };
        c.fillShaded(corners, land);
        if (self.bands) {
            // Every other hour's regions shaded (those part of an hour out
            // between), the chosen zone's lit, and their outlines.
            const chosen = @divFloor(self.zone.standardOffset(), 900);
            for (world.zones) |z| {
                const lit = z.quarter_hours == chosen;
                const color = if (lit)
                    t.primary.withAlpha(0.32)
                else if (@mod(z.quarter_hours, 4) != 0)
                    t.on_surface.withAlpha(0.03)
                else if (@mod(@divFloor(z.quarter_hours, 4), 2) == 0)
                    t.on_surface.withAlpha(0.06)
                else
                    continue;
                const tris = world.zone_triangles[z.triangles[0]..][0..z.triangles[1]];
                const zc = a.alloc([3]f32, tris.len * 3) catch continue;
                for (tris, 0..) |tri, i| for (tri, 0..) |k, j_| {
                    const q = onMap(size, world.zone_points[k]);
                    zc[i * 3 + j_] = .{ q[0], q[1], 1 };
                };
                c.fillShaded(zc, color);
            }
            for (world.zones) |z| {
                const lit = z.quarter_hours == chosen;
                for (world.zone_rings[z.rings[0]..][0..z.rings[1]]) |r| {
                    const ring = world.zone_outline[r[0]..][0..r[1]];
                    // In pieces the canvas takes (each sharing its last
                    // point with the next).
                    var from: usize = 0;
                    while (from + 1 < ring.len) {
                        const count = @min(ring.len - from, 400);
                        const pts = a.alloc(kete.Point, count) catch break;
                        for (ring[from..][0..count], pts) |k, *o| o.* = onMap(size, world.zone_points[k]);
                        c.strokePolyline(pts, false, if (lit) 1.5 else 1, if (lit) t.primary.withAlpha(0.8) else t.on_surface.withAlpha(0.14));
                        from += count - 1;
                    }
                }
            }
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

/// Choosing a zone by name: a field to find it by its city, and the zones
/// that match (before anything is typed, those whose clocks show what
/// `zone`'s does), each with how far ahead of or behind UTC it is.
pub const ZonePicker = struct {
    zone: TimeZone,
    now_s: i64 = 0,
    on_changed: ?kete.ValueCallback(TimeZone) = null,

    /// The most zones listed.
    const shown = 8;

    pub const State = TimeZoneMap.State;

    pub fn build(self: *const ZonePicker, cx: *kete.BuildContext, st: *State) kete.Widget {
        const a = cx.arena;
        const t = cx.theme();
        var found: [shown]TimeZone = undefined;
        const n = if (st.query().len > 0) TimeZoneMap.search(st.query(), &found) else sameTime(self.zone, self.now_s, &found);
        var rows: std.ArrayList(kete.Widget) = .empty;
        const first = a.create(TimeZoneMap.Choose) catch return cx.make(kete.SizedBox.empty);
        first.* = .{ .zone = if (n > 0) found[0] else self.zone, .on_changed = self.on_changed, .state = st };
        rows.append(a, cx.make(kete.TextField{
            .placeholder = locale.text("Search"),
            .autofocus = true,
            .on_changed = .of(st, State.setQuery),
            .on_submit = if (n > 0 and self.on_changed != null) .of(first, TimeZoneMap.Choose.call) else null,
            .width = std.math.inf(f32),
        })) catch {};
        if (n == 0) rows.append(a, cx.make(kete.Text{ .text = locale.text("No time zone matches"), .style = .{ .size = 15, .color = t.on_surface_variant } })) catch {};
        for (found[0..n]) |z| {
            const ch = a.create(TimeZoneMap.Choose) catch continue;
            ch.* = .{ .zone = z, .on_changed = self.on_changed, .state = st };
            var buf: [96]u8 = undefined;
            var off_buf: [16]u8 = undefined;
            rows.append(a, cx.make(kete.ListItem{
                .headline = a.dupe(u8, z.label(&buf)) catch "",
                .trailing = cx.make(kete.Text{ .text = a.dupe(u8, utcOffset(&off_buf, z.offsetAt(self.now_s))) catch "", .style = .{ .size = 14, .color = t.on_surface_variant } }),
                .selected = z == self.zone,
                .on_press = if (self.on_changed != null) .of(ch, TimeZoneMap.Choose.call) else null,
            })) catch {};
        }
        return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 4, .children = rows.items });
    }

    /// The zones (the chosen one first) whose clocks show the same time as
    /// `zone`'s at `now`; at most `out.len`.
    pub fn sameTime(zone: TimeZone, now: i64, out: []TimeZone) usize {
        if (out.len == 0) return 0;
        out[0] = zone;
        var n: usize = 1;
        const offset = zone.offsetAt(now);
        for (1..TimeZone.count) |i| {
            if (n == out.len) break;
            const z: TimeZone = @enumFromInt(i);
            if (z == zone or z.place() == null or z.offsetAt(now) != offset) continue;
            out[n] = z;
            n += 1;
        }
        return n;
    }
};

/// "UTC", "UTC+13", "UTC−3" or "UTC+5:30", for `seconds` ahead of UTC.
pub fn utcOffset(buf: []u8, seconds: i32) []const u8 {
    if (seconds == 0) return "UTC";
    const m: u32 = @abs(seconds) / 60;
    const sign = if (seconds < 0) "\u{2212}" else "+";
    if (m % 60 == 0) return std.fmt.bufPrint(buf, "UTC{s}{d}", .{ sign, m / 60 }) catch "UTC";
    return std.fmt.bufPrint(buf, "UTC{s}{d}:{d:0>2}", .{ sign, m / 60, m % 60 }) catch "UTC";
}

/// `b` over `a`, `f` of the way.
fn mix(a: kete.gfx.Color, b: kete.gfx.Color, f: f32) kete.gfx.Color {
    return .{ .r = a.r + (b.r - a.r) * f, .g = a.g + (b.g - a.g) * f, .b = a.b + (b.b - a.b) * f, .a = 1 };
}

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

test "the hours ahead of UTC, and the zones in a band and at the same time" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("UTC", utcOffset(&buf, 0));
    try testing.expectEqualStrings("UTC+13", utcOffset(&buf, 13 * 3600));
    try testing.expectEqualStrings("UTC\u{2212}3", utcOffset(&buf, -3 * 3600));
    try testing.expectEqualStrings("UTC+5:30", utcOffset(&buf, 5 * 3600 + 1800));
    // 16 November 2026: New Zealand in summer time (UTC+13).
    const now: i64 = 1_794_787_200;
    const auckland = TimeZone.fromName("Pacific/Auckland").?;
    var out: [8]TimeZone = undefined;
    const n = ZonePicker.sameTime(auckland, now, &out);
    try testing.expectEqual(auckland, out[0]);
    for (out[0..n]) |z| try testing.expectEqual(auckland.offsetAt(now), z.offsetAt(now));
    // Clicking in the middle of the Pacific (no place near): the zone in
    // that region nearest it (UTC−10: Honolulu, say).
    const size: kete.Size = .{ .w = 720, .h = 284 };
    const z = MapView.zoneInBand(size, MapView.at(size, 10, -150)).?;
    try testing.expectEqual(@as(i32, -10 * 3600), z.standardOffset());
    // India's region is half an hour out; Nepal's, a quarter.
    try testing.expectEqual(@as(?i8, 22), MapView.regionAt(size, MapView.at(size, 22, 79)));
    try testing.expectEqual(@as(?i8, 23), MapView.regionAt(size, MapView.at(size, 28.2, 84)));
}
