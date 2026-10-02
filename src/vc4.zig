//! Bindings for the vc4 DRM driver's V3D (3D engine) ioctls.
//!
//! Mirrors include/uapi/drm/vc4_drm.h. The V3D has no MMU, so the kernel
//! validates every command list and shader and patches in physical addresses;
//! userspace refers to buffers by their index in the `bo_handles` array.

const std = @import("std");
const linux = std.os.linux;
const drm = @import("drm.zig");
const qpu = @import("qpu.zig");
const sys = @import("sys.zig");

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

comptime {
    // Verified against vc4_drm.h compiled for arm-linux-gnueabihf.
    std.debug.assert(@sizeOf(SubmitRclSurface) == 12);
    std.debug.assert(@offsetOf(SubmitCl, "color_read") == 60);
    std.debug.assert(@offsetOf(SubmitCl, "clear_color") == 132);
    std.debug.assert(@offsetOf(SubmitCl, "flags") == 148);
    std.debug.assert(@offsetOf(SubmitCl, "seqno") == 152);
    std.debug.assert(@sizeOf(SubmitCl) == 176);
    std.debug.assert(@sizeOf(CreateShaderBo) == 24);
}

/// A buffer object mapped into our address space.
pub const Bo = struct {
    handle: u32,
    map: []align(std.heap.page_size_min) u8,
};

pub const Device = struct {
    fd: linux.fd_t,

    pub fn getParam(dev: Device, param: Param) !u64 {
        var arg: GetParam = .{ .param = @intFromEnum(param) };
        try drm.ioctl(dev.fd, IOCTL_GET_PARAM, &arg);
        return arg.value;
    }

    /// Allocates a physically contiguous buffer (from CMA) and maps it.
    pub fn createBo(dev: Device, size: u32) !Bo {
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
        drm.gemClose(dev.fd, bo.handle);
    }

    /// Uploads a QPU program. The kernel validates it immediately and the
    /// resulting BO is immutable.
    pub fn createShaderBo(dev: Device, code: []const qpu.Inst) !u32 {
        var arg: CreateShaderBo = .{
            .size = @intCast(code.len * @sizeOf(qpu.Inst)),
            .data = @intFromPtr(code.ptr),
        };
        try drm.ioctl(dev.fd, IOCTL_CREATE_SHADER_BO, &arg);
        return arg.handle;
    }

    /// Submits a job and returns its sequence number.
    pub fn submit(dev: Device, job: *SubmitCl) !u64 {
        try drm.ioctl(dev.fd, IOCTL_SUBMIT_CL, job);
        return job.seqno;
    }

    pub fn waitSeqno(dev: Device, seqno: u64, timeout_ns: u64) !void {
        var arg: WaitSeqno = .{ .seqno = seqno, .timeout_ns = timeout_ns };
        try drm.ioctl(dev.fd, IOCTL_WAIT_SEQNO, &arg);
    }
};
