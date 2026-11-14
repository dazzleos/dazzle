//! Atomic mode setting: showing buffers on the display's planes in one
//! commit per frame.
//!
//! The display hardware (the HVS) composes several planes as it scans out,
//! so a buffer can be shown without copying it into a full-screen frame
//! first. `Kms` drives a CRTC's primary plane and, when there are planes
//! free, up to `max_overlays` overlay planes above it; each `commit` sets
//! them all and the mode (the first time), and reports completion as a page flip event, like
//! `drm.pageFlip`.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const drm = @import("drm.zig");

const SetClientCap = extern struct { capability: u64, value: u64 };
const IOCTL_SET_CLIENT_CAP = linux.IOCTL.IOW(drm.ioctl_base, 0x0d, SetClientCap);
const cap_universal_planes = 2;
const cap_atomic = 3;

const GetPlaneRes = extern struct { plane_id_ptr: u64 = 0, count_planes: u32 = 0 };
const IOCTL_MODE_GETPLANERESOURCES = drm.IOWR(0xb5, GetPlaneRes);

const GetPlane = extern struct {
    plane_id: u32,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    possible_crtcs: u32 = 0,
    gamma_size: u32 = 0,
    count_format_types: u32 = 0,
    format_type_ptr: u64 = 0,
};
const IOCTL_MODE_GETPLANE = drm.IOWR(0xb6, GetPlane);

const ObjGetProperties = extern struct {
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_props: u32 = 0,
    obj_id: u32,
    obj_type: u32,
};
const IOCTL_MODE_OBJ_GETPROPERTIES = drm.IOWR(0xb9, ObjGetProperties);

const GetProperty = extern struct {
    values_ptr: u64 = 0,
    enum_blob_ptr: u64 = 0,
    prop_id: u32,
    flags: u32 = 0,
    name: [32]u8 = @splat(0),
    count_values: u32 = 0,
    count_enum_blobs: u32 = 0,
};
const IOCTL_MODE_GETPROPERTY = drm.IOWR(0xaa, GetProperty);

const CreateBlob = extern struct { data: u64, length: u32, blob_id: u32 = 0 };
const IOCTL_MODE_CREATEPROPBLOB = drm.IOWR(0xbd, CreateBlob);

const AtomicReq = extern struct {
    flags: u32,
    count_objs: u32,
    objs_ptr: u64,
    count_props_ptr: u64,
    props_ptr: u64,
    prop_values_ptr: u64,
    reserved: u64 = 0,
    user_data: u64 = 0,
};
const IOCTL_MODE_ATOMIC = drm.IOWR(0xbc, AtomicReq);

/// DRM_FORMAT_MOD_BROADCOM_VC4_T_TILED: the GPU's T-tiled layout, which
/// the display can also scan out.
pub const modifier_t_tiled: u64 = 0x07 << 56 | 1;

const atomic_test_only = 0x0100;
const atomic_nonblock = 0x0200;
const atomic_allow_modeset = 0x0400;

const object_connector = 0xc0c0c0c0;
const object_crtc = 0xcccccccc;
const object_plane = 0xeeeeeeee;

/// Values of a plane's "type" property.
const plane_type_overlay = 0;
const plane_type_primary = 1;

comptime {
    // Sizes from the uapi headers, identical on 32- and 64-bit targets.
    std.debug.assert(@sizeOf(SetClientCap) == 16);
    std.debug.assert(@sizeOf(GetPlaneRes) == 16);
    std.debug.assert(@sizeOf(GetPlane) == 32);
    std.debug.assert(@sizeOf(ObjGetProperties) == 32);
    std.debug.assert(@sizeOf(GetProperty) == 64);
    std.debug.assert(@sizeOf(CreateBlob) == 16);
    std.debug.assert(@sizeOf(AtomicReq) == 56);
}

const max_props = 64;

/// An object's properties: names to IDs, and current values.
const Props = struct {
    ids: [max_props]u32 = undefined,
    values: [max_props]u64 = undefined,
    names: [max_props][32]u8 = undefined,
    len: usize = 0,

    fn read(fd: linux.fd_t, obj_id: u32, obj_type: u32) !Props {
        var p: Props = .{};
        var req: ObjGetProperties = .{ .obj_id = obj_id, .obj_type = obj_type };
        try drm.ioctl(fd, IOCTL_MODE_OBJ_GETPROPERTIES, &req);
        p.len = @min(req.count_props, max_props);
        req.count_props = @intCast(p.len);
        req.props_ptr = @intFromPtr(&p.ids);
        req.prop_values_ptr = @intFromPtr(&p.values);
        try drm.ioctl(fd, IOCTL_MODE_OBJ_GETPROPERTIES, &req);
        for (p.ids[0..p.len], 0..) |prop_id, i| {
            var prop: GetProperty = .{ .prop_id = prop_id };
            try drm.ioctl(fd, IOCTL_MODE_GETPROPERTY, &prop);
            p.names[i] = prop.name;
        }
        return p;
    }

    fn index(p: *const Props, name: []const u8) ?usize {
        for (p.names[0..p.len], 0..) |n, i| if (std.mem.eql(u8, std.mem.sliceTo(&n, 0), name)) return i;
        return null;
    }

    fn id(p: *const Props, name: []const u8) !u32 {
        return p.ids[p.index(name) orelse return error.MissingProperty];
    }

    fn value(p: *const Props, name: []const u8) ?u64 {
        return p.values[p.index(name) orelse return null];
    }
};

const PlaneProps = struct {
    fb_id: u32,
    crtc_id: u32,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    crtc_x: u32,
    crtc_y: u32,
    crtc_w: u32,
    crtc_h: u32,

    fn read(fd: linux.fd_t, plane_id: u32) !struct { PlaneProps, ?u64 } {
        const p = try Props.read(fd, plane_id, object_plane);
        return .{ .{
            .fb_id = try p.id("FB_ID"),
            .crtc_id = try p.id("CRTC_ID"),
            .src_x = try p.id("SRC_X"),
            .src_y = try p.id("SRC_Y"),
            .src_w = try p.id("SRC_W"),
            .src_h = try p.id("SRC_H"),
            .crtc_x = try p.id("CRTC_X"),
            .crtc_y = try p.id("CRTC_Y"),
            .crtc_w = try p.id("CRTC_W"),
            .crtc_h = try p.id("CRTC_H"),
        }, p.value("type") };
    }
};

pub const Plane = struct { id: u32, props: PlaneProps };

/// Overlay planes `Kms` uses, at most: one for a layer over a window shown
/// directly, and two for the shell's panels.
pub const max_overlays = 3;

/// What is shown on each overlay plane (null: nothing).
pub const Overlays = [max_overlays]?Layer;

/// A buffer shown on a plane: its framebuffer, the part of it to show
/// (from its top left corner), and where on the screen.
pub const Layer = struct {
    fb_id: u32,
    src_width: u32,
    src_height: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// An atomic request under construction: properties grouped by object.
pub const Request = struct {
    objs: [3 + max_overlays]u32 = undefined,
    counts: [3 + max_overlays]u32 = undefined,
    n_objs: usize = 0,
    props: [48]u32 = undefined,
    values: [48]u64 = undefined,
    n_props: usize = 0,

    fn object(r: *Request, id: u32) void {
        r.objs[r.n_objs] = id;
        r.counts[r.n_objs] = 0;
        r.n_objs += 1;
    }

    fn set(r: *Request, prop: u32, value: u64) void {
        r.props[r.n_props] = prop;
        r.values[r.n_props] = value;
        r.n_props += 1;
        r.counts[r.n_objs - 1] += 1;
    }

    /// Overlay planes are stacked above the primary plane by default, so
    /// their order (zpos) is left alone.
    fn plane(r: *Request, p: Plane, crtc_id: u32, layer: ?Layer) void {
        r.object(p.id);
        const pp = p.props;
        const l = layer orelse {
            r.set(pp.fb_id, 0);
            r.set(pp.crtc_id, 0);
            return;
        };
        r.set(pp.fb_id, l.fb_id);
        r.set(pp.crtc_id, crtc_id);
        // Source coordinates are 16.16 fixed point.
        r.set(pp.src_x, 0);
        r.set(pp.src_y, 0);
        r.set(pp.src_w, @as(u64, l.src_width) << 16);
        r.set(pp.src_h, @as(u64, l.src_height) << 16);
        r.set(pp.crtc_x, @as(u32, @bitCast(l.x)));
        r.set(pp.crtc_y, @as(u32, @bitCast(l.y)));
        r.set(pp.crtc_w, l.width);
        r.set(pp.crtc_h, l.height);
    }
};

pub const Kms = struct {
    fd: linux.fd_t,
    output: drm.Output,
    connector_crtc_id: u32,
    crtc_mode_id: u32,
    crtc_active: u32,
    mode_blob: u32,
    primary: Plane,
    /// Planes above the primary one, as many as the CRTC has to spare.
    overlays: [max_overlays]?Plane,
    mode_set: bool = false,
    /// What the last commit put on each plane: later commits only change
    /// what differs, so the kernel re-checks as little as it can.
    shown_primary: ?Layer = null,
    shown_overlays: Overlays = @splat(null),

    /// Switches the DRM file to atomic mode setting and finds the CRTC's
    /// planes. Fails (and the caller should use the legacy API) if the
    /// driver does not support it.
    pub fn init(fd: linux.fd_t, output: drm.Output) !Kms {
        var cap: SetClientCap = .{ .capability = cap_universal_planes, .value = 1 };
        try drm.ioctl(fd, IOCTL_SET_CLIENT_CAP, &cap);
        cap = .{ .capability = cap_atomic, .value = 1 };
        try drm.ioctl(fd, IOCTL_SET_CLIENT_CAP, &cap);

        const conn = try Props.read(fd, output.connector_id, object_connector);
        const crtc = try Props.read(fd, output.crtc_id, object_crtc);

        var ids: [32]u32 = undefined;
        var res: GetPlaneRes = .{};
        try drm.ioctl(fd, IOCTL_MODE_GETPLANERESOURCES, &res);
        res = .{ .plane_id_ptr = @intFromPtr(&ids), .count_planes = @min(res.count_planes, ids.len) };
        try drm.ioctl(fd, IOCTL_MODE_GETPLANERESOURCES, &res);

        var primary: ?Plane = null;
        var overlays: [max_overlays]?Plane = @splat(null);
        var n_overlays: usize = 0;
        for (ids[0..res.count_planes]) |plane_id| {
            var plane: GetPlane = .{ .plane_id = plane_id };
            drm.ioctl(fd, IOCTL_MODE_GETPLANE, &plane) catch continue;
            if (plane.possible_crtcs & (@as(u32, 1) << @intCast(output.crtc_index)) == 0) continue;
            const props, const plane_type = PlaneProps.read(fd, plane_id) catch continue;
            if (plane_type == plane_type_primary and primary == null) {
                primary = .{ .id = plane_id, .props = props };
            } else if (plane_type == plane_type_overlay and n_overlays < max_overlays) {
                overlays[n_overlays] = .{ .id = plane_id, .props = props };
                n_overlays += 1;
            }
        }

        var blob: CreateBlob = .{ .data = @intFromPtr(&output.mode), .length = @sizeOf(drm.ModeInfo) };
        try drm.ioctl(fd, IOCTL_MODE_CREATEPROPBLOB, &blob);
        return .{
            .fd = fd,
            .output = output,
            .connector_crtc_id = try conn.id("CRTC_ID"),
            .crtc_mode_id = try crtc.id("MODE_ID"),
            .crtc_active = try crtc.id("ACTIVE"),
            .mode_blob = blob.blob_id,
            .primary = primary orelse return error.NoPrimaryPlane,
            .overlays = overlays,
        };
    }

    /// The request for showing `primary` and `overlays` above it, setting the mode if it has not been set yet. Unless `full`, it
    /// only changes what differs from the last commit: a plane whose layer
    /// is the same is left out, and one that only shows a new buffer gets
    /// just that.
    pub fn request(k: *const Kms, primary: Layer, overlays: Overlays, full: bool) Request {
        var r: Request = .{};
        const all = full or !k.mode_set;
        if (!k.mode_set) {
            r.object(k.output.connector_id);
            r.set(k.connector_crtc_id, k.output.crtc_id);
            r.object(k.output.crtc_id);
            r.set(k.crtc_mode_id, k.mode_blob);
            r.set(k.crtc_active, 1);
        }
        var overlay_changed: [max_overlays]bool = undefined;
        var any_overlay_changed = false;
        for (&overlay_changed, k.overlays, k.shown_overlays, overlays) |*c, plane, shown_layer, layer| {
            c.* = plane != null and (all or !std.meta.eql(shown_layer, layer));
            any_overlay_changed = any_overlay_changed or c.*;
        }
        const shown = k.shown_primary;
        if (all or shown == null or !std.meta.eql(shown.?, primary)) {
            var moved = shown orelse primary;
            moved.fb_id = primary.fb_id;
            if (!all and shown != null and std.meta.eql(moved, primary)) {
                r.object(k.primary.id);
                r.set(k.primary.props.fb_id, primary.fb_id);
            } else r.plane(k.primary, k.output.crtc_id, primary);
        } else if (!any_overlay_changed) {
            // Nothing changed; a commit needs an object for its event.
            r.object(k.primary.id);
            r.set(k.primary.props.fb_id, primary.fb_id);
        }
        for (k.overlays, overlays, overlay_changed) |plane, layer, changed| if (changed) r.plane(plane.?, k.output.crtc_id, layer);
        return r;
    }

    /// Whether the display can show these layers (without showing them).
    pub fn check(k: *const Kms, primary: Layer, overlays: Overlays) bool {
        for (k.overlays, overlays) |plane, layer| if (layer != null and plane == null) return false;
        var r = k.request(primary, overlays, true);
        const flags: u32 = atomic_test_only | @as(u32, if (k.mode_set) 0 else atomic_allow_modeset);
        k.submit(&r, flags) catch return false;
        return true;
    }

    /// Shows the layers at the next vertical blank, without waiting; a page
    /// flip event reports when they are on the screen. The first commit
    /// sets the mode and waits for it instead, and returns true (no event
    /// follows).
    pub fn commit(k: *Kms, primary: Layer, overlays: Overlays) !bool {
        var r = k.request(primary, overlays, false);
        const at_once = !k.mode_set;
        if (at_once) {
            try k.submit(&r, atomic_allow_modeset);
            k.mode_set = true;
        } else {
            k.submit(&r, atomic_nonblock | drm.page_flip_event) catch |err| switch (err) {
                // Another update (such as the cursor) is still in progress:
                // wait for it.
                error.Busy => try k.submit(&r, drm.page_flip_event),
                else => return err,
            };
        }
        k.shown_primary = primary;
        // Without a plane, nothing is shown there.
        for (&k.shown_overlays, k.overlays, overlays) |*shown_layer, plane, layer| shown_layer.* = if (plane != null) layer else null;
        return at_once;
    }

    fn submit(k: *const Kms, r: *Request, flags: u32) !void {
        var req: AtomicReq = .{
            .flags = flags,
            .count_objs = @intCast(r.n_objs),
            .objs_ptr = @intFromPtr(&r.objs),
            .count_props_ptr = @intFromPtr(&r.counts),
            .props_ptr = @intFromPtr(&r.props),
            .prop_values_ptr = @intFromPtr(&r.values),
        };
        // Not drm.ioctl: EBUSY must reach the caller rather than be retried.
        const rc = linux.ioctl(k.fd, IOCTL_MODE_ATOMIC, @intFromPtr(&req));
        if (linux.errno(rc) != .SUCCESS) return sys.errorFromErrno(linux.errno(rc));
    }
};

test "atomic requests group properties by object" {
    const props: PlaneProps = .{ .fb_id = 1, .crtc_id = 2, .src_x = 3, .src_y = 4, .src_w = 5, .src_h = 6, .crtc_x = 7, .crtc_y = 8, .crtc_w = 9, .crtc_h = 10 };
    var mode: drm.ModeInfo = std.mem.zeroes(drm.ModeInfo);
    mode.hdisplay = 1920;
    var k: Kms = .{
        .fd = -1,
        .output = .{ .connector_id = 30, .crtc_id = 40, .crtc_index = 0, .mode = mode },
        .connector_crtc_id = 100,
        .crtc_mode_id = 101,
        .crtc_active = 102,
        .mode_blob = 55,
        .primary = .{ .id = 50, .props = props },
        .overlays = .{ .{ .id = 60, .props = props }, .{ .id = 61, .props = props }, .{ .id = 62, .props = props } },
    };
    const window: Layer = .{ .fb_id = 77, .src_width = 1920, .src_height = 1036, .x = 0, .y = 44, .width = 1920, .height = 1036 };
    var r = k.request(window, .{ null, null, null }, false);
    // The mode set: connector, CRTC, then all the planes.
    try std.testing.expectEqualSlices(u32, &.{ 30, 40, 50, 60, 61, 62 }, r.objs[0..r.n_objs]);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 10, 2, 2, 2 }, r.counts[0..r.n_objs]);
    try std.testing.expectEqual(@as(u64, 1036 << 16), r.values[3 + 5]);
    try std.testing.expectEqual(@as(u64, 44), r.values[3 + 7]);
    // The overlays are switched off.
    try std.testing.expectEqualSlices(u64, &.{ 0, 0, 0, 0 }, r.values[r.n_props - 4 .. r.n_props]);

    k.mode_set = true;
    r = k.request(window, .{ window, null, null }, false);
    try std.testing.expectEqualSlices(u32, &.{ 50, 60 }, r.objs[0..r.n_objs]);
    try std.testing.expectEqual(@as(usize, 20), r.n_props);

    // After that is shown, a new buffer in the same place changes only the
    // primary plane's framebuffer.
    k.shown_primary = window;
    k.shown_overlays = .{ window, null, null };
    var next = window;
    next.fb_id = 78;
    r = k.request(next, .{ window, null, null }, false);
    try std.testing.expectEqualSlices(u32, &.{50}, r.objs[0..r.n_objs]);
    try std.testing.expectEqualSlices(u32, &.{1}, r.props[0..r.n_props]);
    try std.testing.expectEqual(@as(u64, 78), r.values[0]);
    // A new bar changes only the overlay plane.
    var bar = window;
    bar.fb_id = 90;
    r = k.request(window, .{ bar, null, null }, false);
    try std.testing.expectEqualSlices(u32, &.{60}, r.objs[0..r.n_objs]);
    // A dock appearing changes only the second.
    r = k.request(window, .{ window, bar, null }, false);
    try std.testing.expectEqualSlices(u32, &.{61}, r.objs[0..r.n_objs]);
    // Nothing new still names the primary plane, for the flip event.
    r = k.request(window, .{ window, null, null }, false);
    try std.testing.expectEqualSlices(u32, &.{50}, r.objs[0..r.n_objs]);
    // A full request sets everything.
    r = k.request(window, .{ window, bar, null }, true);
    try std.testing.expectEqual(@as(usize, 32), r.n_props);
}
