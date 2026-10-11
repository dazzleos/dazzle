//! Bindings for the vc4 and v3d DRM drivers' 3D engine ioctls.
//!
//! Mirrors `include/uapi/drm/vc4_drm.h` (VideoCore IV / V3D 2.1) and
//! `include/uapi/drm/v3d_drm.h` (VideoCore VI / V3D 4.2 on BCM2711).
//! On RPi 0-3 (`vc4`), both KMS display and 3D rendering live on the same
//! `vc4` DRM device. On RPi 4 (`BCM2711`), `vc4` provides KMS display scanout
//! while `v3d` provides the 3D engine with its own MMU.

const std = @import("std");
const linux = std.os.linux;
const drm = @import("drm.zig");
const qpu = @import("qpu.zig");
const render = @import("render.zig");
const sys = @import("sys");

pub const SubmitRclSurface = extern struct {
    /// Index into `bo_handles`, or `no_surface`.
    hindex: u32 = no_surface,
    offset: u32 = 0,
    bits: u16 = 0,
    flags: u16 = 0,

    pub const no_surface = ~@as(u32, 0);
};

pub const SubmitCl = extern struct {
    bin_cl: u64 = 0,
    shader_rec: u64 = 0,
    uniforms: u64 = 0,
    bo_handles: u64 = 0,
    bin_cl_size: u32 = 0,
    shader_rec_size: u32 = 0,
    shader_rec_count: u32 = 0,
    uniforms_size: u32 = 0,
    bo_handle_count: u32 = 0,
    width: u16 = 0,
    height: u16 = 0,
    min_x_tile: u8 = 0,
    min_y_tile: u8 = 0,
    max_x_tile: u8 = 0,
    max_y_tile: u8 = 0,
    color_read: SubmitRclSurface = .{},
    color_write: SubmitRclSurface = .{},
    zs_read: SubmitRclSurface = .{},
    zs_write: SubmitRclSurface = .{},
    msaa_color_write: SubmitRclSurface = .{},
    msaa_zs_write: SubmitRclSurface = .{},
    clear_color: [2]u32 = .{ 0, 0 },
    clear_z: u32 = 0,
    clear_s: u8 = 0,
    /// `__u32 pad:24` in C; shares a 32-bit unit with clear_s.
    pad: [3]u8 = .{ 0, 0, 0 },
    flags: u32 = 0,
    seqno: u64 = 0,
    perfmonid: u32 = 0,
    in_sync: u32 = 0,
    out_sync: u32 = 0,
    pad2: u32 = 0,

    pub const flag_use_clear_color = 1 << 0;
    pub const flag_fixed_rcl_order = 1 << 1;
    pub const flag_rcl_order_increasing_x = 1 << 2;
    pub const flag_rcl_order_increasing_y = 1 << 3;
};

pub const WaitSeqno = extern struct {
    seqno: u64,
    timeout_ns: u64,
};

pub const CreateBo = extern struct {
    size: u32,
    flags: u32 = 0,
    handle: u32 = 0,
    pad: u32 = 0,
};

pub const MmapBo = extern struct {
    handle: u32,
    flags: u32 = 0,
    offset: u64 = 0,
};

pub const CreateShaderBo = extern struct {
    size: u32,
    flags: u32 = 0,
    data: u64,
    handle: u32 = 0,
    pad: u32 = 0,
};

pub const GetParam = extern struct {
    param: u32,
    pad: u32 = 0,
    value: u64 = 0,
};

pub const Param = enum(u32) {
    v3d_ident0 = 0,
    v3d_ident1 = 1,
    v3d_ident2 = 2,
    supports_branches = 3,
    supports_etc1 = 4,
    supports_threaded_fs = 5,
    supports_fixed_rcl_order = 6,
    supports_madvise = 7,
    supports_perfmon = 8,
};

pub const IOCTL_SUBMIT_CL = drm.IOWR(drm.command_base + 0x00, SubmitCl);
pub const IOCTL_WAIT_SEQNO = drm.IOWR(drm.command_base + 0x01, WaitSeqno);
pub const IOCTL_CREATE_BO = drm.IOWR(drm.command_base + 0x03, CreateBo);
pub const IOCTL_MMAP_BO = drm.IOWR(drm.command_base + 0x04, MmapBo);
pub const IOCTL_CREATE_SHADER_BO = drm.IOWR(drm.command_base + 0x05, CreateShaderBo);
pub const IOCTL_GET_PARAM = drm.IOWR(drm.command_base + 0x07, GetParam);

// --- V3D (VideoCore VI / BCM2711) ioctls (`include/uapi/drm/v3d_drm.h`) ---

pub const V3dSubmitCl = extern struct {
    bcl_start: u32 = 0,
    bcl_end: u32 = 0,
    rcl_start: u32 = 0,
    rcl_end: u32 = 0,
    in_sync_bcl: u32 = 0,
    in_sync_rcl: u32 = 0,
    out_sync: u32 = 0,
    /// Tile allocation memory address and size (bytes).
    qma: u32 = 0,
    qms: u32 = 0,
    /// Tile state data array address.
    qts: u32 = 0,
    bo_handles: u64 = 0,
    bo_handle_count: u32 = 0,
    flags: u32 = 0,
    perfmon_id: u32 = 0,
    pad: u32 = 0,
    extensions: u64 = 0,

    pub const flag_flush_cache = 1 << 0;
};

pub const V3dWaitBo = extern struct {
    handle: u32,
    pad: u32 = 0,
    timeout_ns: u64,
};

pub const V3dCreateBo = extern struct {
    size: u32,
    flags: u32 = 0,
    handle: u32 = 0,
    offset: u32 = 0,
};

pub const V3dMmapBo = extern struct {
    handle: u32,
    flags: u32 = 0,
    offset: u64 = 0,
};

pub const V3dGetParam = extern struct {
    param: u32,
    pad: u32 = 0,
    value: u64 = 0,
};

pub const V3dGetBoOffset = extern struct {
    handle: u32,
    offset: u32 = 0,
};

pub const IOCTL_V3D_SUBMIT_CL = drm.IOWR(drm.command_base + 0x00, V3dSubmitCl);
pub const IOCTL_V3D_WAIT_BO = drm.IOWR(drm.command_base + 0x01, V3dWaitBo);
pub const IOCTL_V3D_CREATE_BO = drm.IOWR(drm.command_base + 0x02, V3dCreateBo);
pub const IOCTL_V3D_MMAP_BO = drm.IOWR(drm.command_base + 0x03, V3dMmapBo);
pub const IOCTL_V3D_GET_PARAM = drm.IOWR(drm.command_base + 0x04, V3dGetParam);
pub const IOCTL_V3D_GET_BO_OFFSET = drm.IOWR(drm.command_base + 0x05, V3dGetBoOffset);

comptime {
    // Verified against vc4_drm.h and v3d_drm.h compiled for arm-linux-gnueabihf.
    std.debug.assert(@sizeOf(SubmitRclSurface) == 12);
    std.debug.assert(@offsetOf(SubmitCl, "color_read") == 60);
    std.debug.assert(@offsetOf(SubmitCl, "clear_color") == 132);
    std.debug.assert(@offsetOf(SubmitCl, "flags") == 148);
    std.debug.assert(@offsetOf(SubmitCl, "seqno") == 152);
    std.debug.assert(@sizeOf(SubmitCl) == 176);
    std.debug.assert(@sizeOf(CreateShaderBo) == 24);
    std.debug.assert(@sizeOf(V3dSubmitCl) == 72);
    std.debug.assert(@sizeOf(V3dWaitBo) == 16);
    std.debug.assert(@sizeOf(V3dCreateBo) == 16);
    std.debug.assert(@sizeOf(V3dMmapBo) == 16);
    std.debug.assert(@sizeOf(V3dGetParam) == 16);
    std.debug.assert(@sizeOf(V3dGetBoOffset) == 8);
}

/// A buffer object mapped into our address space.
pub const Bo = struct {
    handle: u32,
    map: []align(std.heap.page_size_min) u8,
    /// When KMS (`vc4`) and 3D (`v3d`) are separate DRM devices, the GEM
    /// handle on the KMS device (`dev.fd`) for scanout framebuffers/cursors.
    kms_handle: u32 = 0,

    pub fn kmsHandle(bo: Bo) u32 {
        return if (bo.kms_handle != 0) bo.kms_handle else bo.handle;
    }
};

fn openV3dNode() ?linux.fd_t {
    var path_buf: [32]u8 = undefined;
    for (128..132) |n| {
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/dri/renderD{d}", .{n}) catch continue;
        const fd = sys.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch continue;
        var name_buf: [32]u8 = undefined;
        const name = drm.driverName(fd, &name_buf) catch "";
        if (std.mem.eql(u8, name, "v3d")) {
            sys.print("dazzle: opened {s} ({s})\n", .{ path, name });
            return fd;
        }
        sys.close(fd);
    }
    const cards = [_][*:0]const u8{ "/dev/dri/card0", "/dev/dri/card1", "/dev/dri/card2" };
    for (cards) |path| {
        const fd = sys.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch continue;
        var name_buf: [32]u8 = undefined;
        const name = drm.driverName(fd, &name_buf) catch "";
        if (std.mem.eql(u8, name, "v3d")) {
            sys.print("dazzle: opened {s} ({s})\n", .{ path, name });
            return fd;
        }
        sys.close(fd);
    }
    return null;
}

/// Opens the vc4 DRM device (and on BCM2711 / RPi 4, the companion v3d 3D
/// device). Drivers may still be probing when init starts, so this polls for
/// a few seconds.
pub fn open() !Device {
    const paths = [_][*:0]const u8{ "/dev/dri/card0", "/dev/dri/card1", "/dev/dri/card2" };
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        for (paths) |path| {
            const fd = sys.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch continue;
            var name_buf: [32]u8 = undefined;
            const name = drm.driverName(fd, &name_buf) catch "";
            if (std.mem.eql(u8, name, "vc4")) {
                var dev: Device = .{ .fd = fd };
                if (dev.getParam(.v3d_ident0)) |_| {
                    sys.print("dazzle: opened {s} ({s})\n", .{ path, name });
                    return dev;
                } else |_| {
                    // BCM2711 (RPi 4): vc4 is KMS-only; 3D is on the v3d device.
                    if (openV3dNode()) |v3d_fd| {
                        sys.print("dazzle: opened {s} ({s}) + v3d\n", .{ path, name });
                        return .{ .fd = fd, .v3d_fd = v3d_fd, .is_v3d = true };
                    }
                }
            }
            sys.close(fd);
        }
        sys.sleepMs(100);
    }
    return error.NoVc4Device;
}

/// Opens the 3D render node (`v3d` on RPi 4, `vc4` on RPi 0-3): GPU rendering
/// without display control, for clients of a compositor.
pub fn openRender() !Device {
    var path_buf: [32]u8 = undefined;
    for (128..132) |n| {
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/dri/renderD{d}", .{n}) catch continue;
        const fd = sys.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch continue;
        var name_buf: [32]u8 = undefined;
        const name = drm.driverName(fd, &name_buf) catch "";
        if (std.mem.eql(u8, name, "v3d")) return .{ .fd = fd, .is_v3d = true };
        if (std.mem.eql(u8, name, "vc4")) {
            var dev: Device = .{ .fd = fd };
            if (dev.getParam(.v3d_ident0)) |_| return dev else |_| {}
        }
        sys.close(fd);
    }
    return error.NoVc4Device;
}

pub const Device = struct {
    fd: linux.fd_t,
    v3d_fd: ?linux.fd_t = null,
    is_v3d: bool = false,

    pub fn renderFd(dev: Device) linux.fd_t {
        return dev.v3d_fd orelse dev.fd;
    }

    pub fn getParam(dev: Device, param: Param) !u64 {
        var arg: GetParam = .{ .param = @intFromEnum(param) };
        try drm.ioctl(dev.fd, IOCTL_GET_PARAM, &arg);
        return arg.value;
    }

    /// Allocates a buffer on the V3D 4.2 device (`renderFd()`).
    pub fn createV3dBo(dev: Device, size: u32) !Bo {
        const rfd = dev.renderFd();
        var create: V3dCreateBo = .{ .size = size };
        try drm.ioctl(rfd, IOCTL_V3D_CREATE_BO, &create);
        errdefer drm.gemClose(rfd, create.handle);

        var mmap_arg: V3dMmapBo = .{ .handle = create.handle };
        try drm.ioctl(rfd, IOCTL_V3D_MMAP_BO, &mmap_arg);
        const addr = try sys.check(linux.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            rfd,
            @intCast(mmap_arg.offset),
        ));
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr);
        return .{ .handle = create.handle, .map = ptr[0..size] };
    }

    pub fn destroyV3dBo(dev: Device, bo: Bo) void {
        _ = linux.munmap(bo.map.ptr, bo.map.len);
        drm.gemClose(dev.renderFd(), bo.handle);
    }

    /// Allocates a GPU buffer and maps it. When `dev` bridges both `vc4` (KMS)
    /// and `v3d` (3D), allocates a physically contiguous buffer on `vc4` and
    /// imports it into `v3d` so it can be both rendered to and scanned out.
    pub fn createBo(dev: Device, size: u32) !Bo {
        if (dev.is_v3d) {
            if (dev.v3d_fd) |vfd| {
                var dumb: drm.ModeCreateDumb = .{ .width = size, .height = 1, .bpp = 8 };
                try drm.ioctl(dev.fd, drm.IOCTL_MODE_CREATE_DUMB, &dumb);
                errdefer drm.gemClose(dev.fd, dumb.handle);
                var map_arg: drm.ModeMapDumb = .{ .handle = dumb.handle };
                try drm.ioctl(dev.fd, drm.IOCTL_MODE_MAP_DUMB, &map_arg);
                const dumb_size: usize = @intCast(dumb.size);
                const addr = try sys.check(linux.mmap(
                    null,
                    dumb_size,
                    .{ .READ = true, .WRITE = true },
                    .{ .TYPE = .SHARED },
                    dev.fd,
                    @intCast(map_arg.offset),
                ));
                const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr);
                errdefer _ = linux.munmap(ptr, dumb_size);

                const prime_fd = try drm.exportBuffer(dev.fd, dumb.handle);
                defer sys.close(prime_fd);
                const v3d_handle = try drm.importBuffer(vfd, prime_fd);
                return .{
                    .handle = v3d_handle,
                    .kms_handle = dumb.handle,
                    .map = ptr[0..size],
                };
            }
            return dev.createV3dBo(size);
        }

        var create: CreateBo = .{ .size = size };
        try drm.ioctl(dev.fd, IOCTL_CREATE_BO, &create);
        errdefer drm.gemClose(dev.fd, create.handle);

        var mmap_arg: MmapBo = .{ .handle = create.handle };
        try drm.ioctl(dev.fd, IOCTL_MMAP_BO, &mmap_arg);
        const addr = try sys.check(linux.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            dev.fd,
            @intCast(mmap_arg.offset),
        ));
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr);
        return .{ .handle = create.handle, .map = ptr[0..size] };
    }

    pub fn destroyBo(dev: Device, bo: Bo) void {
        _ = linux.munmap(bo.map.ptr, bo.map.len);
        drm.gemClose(dev.renderFd(), bo.handle);
        if (bo.kms_handle != 0 and bo.kms_handle != bo.handle) {
            drm.gemClose(dev.fd, bo.kms_handle);
        }
    }

    /// Uploads a QPU program. On VC4 the kernel validates it immediately; on
    /// V3D 4.2 the instructions live in a V3D MMU buffer object.
    pub fn createShaderBo(dev: Device, code: []const qpu.Inst) !u32 {
        if (dev.is_v3d) {
            const byte_len: u32 = @intCast(code.len * @sizeOf(qpu.Inst));
            const alloc_size = std.mem.alignForward(u32, @max(byte_len, 64), 4096);
            const bo = try dev.createV3dBo(alloc_size);
            @memcpy(bo.map[0..byte_len], std.mem.sliceAsBytes(code));
            _ = linux.munmap(bo.map.ptr, bo.map.len);
            return bo.handle;
        }
        var arg: CreateShaderBo = .{
            .size = @intCast(code.len * @sizeOf(qpu.Inst)),
            .data = @intFromPtr(code.ptr),
        };
        try drm.ioctl(dev.fd, IOCTL_CREATE_SHADER_BO, &arg);
        return arg.handle;
    }

    pub fn destroyShaderBo(dev: Device, handle: u32) void {
        drm.gemClose(dev.renderFd(), handle);
    }

    pub fn importBuffer(dev: Device, dma_buf_fd: linux.fd_t) !u32 {
        return drm.importBuffer(dev.renderFd(), dma_buf_fd);
    }

    pub fn closeHandle(dev: Device, handle: u32) void {
        drm.gemClose(dev.renderFd(), handle);
    }

    pub fn getBoOffset(dev: Device, handle: u32) !u32 {
        var arg: V3dGetBoOffset = .{ .handle = handle };
        try drm.ioctl(dev.renderFd(), IOCTL_V3D_GET_BO_OFFSET, &arg);
        return arg.offset;
    }

    pub fn waitBo(dev: Device, handle: u32, timeout_ns: u64) !void {
        var arg: V3dWaitBo = .{ .handle = handle, .timeout_ns = timeout_ns };
        try drm.ioctl(dev.renderFd(), IOCTL_V3D_WAIT_BO, &arg);
    }

    pub fn submitV3d(dev: Device, job: *V3dSubmitCl) !void {
        try drm.ioctl(dev.renderFd(), IOCTL_V3D_SUBMIT_CL, job);
    }

    /// Submits a job and returns its sequence number.
    pub fn submit(dev: Device, job: *SubmitCl) !u64 {
        if (dev.is_v3d) {
            const frame: *render.Frame = @fieldParentPtr("submit", job);
            try frame.submitV3dRegion(dev, job);
            return 0;
        }
        try drm.ioctl(dev.fd, IOCTL_SUBMIT_CL, job);
        return job.seqno;
    }

    pub fn waitSeqno(dev: Device, seqno: u64, timeout_ns: u64) !void {
        if (dev.is_v3d) {
            if (seqno != 0) try dev.waitBo(@intCast(seqno), timeout_ns);
            return;
        }
        var arg: WaitSeqno = .{ .seqno = seqno, .timeout_ns = timeout_ns };
        try drm.ioctl(dev.fd, IOCTL_WAIT_SEQNO, &arg);
    }
};
