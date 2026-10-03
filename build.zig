const std = @import("std");

const Modules = struct {
    sys: *std.Build.Module,
    vc4: *std.Build.Module,
    gles: *std.Build.Module,
};

/// The library modules, built for one target:
///
/// * `sys`: Linux system call helpers shared by everything
/// * `vc4`: the low-level VideoCore IV graphics API
/// * `gles`: OpenGL ES 2.0 and GLSL, built on vc4
fn addModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const sys = b.createModule(.{
        .root_source_file = b.path("src/sys/sys.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vc4 = b.createModule(.{
        .root_source_file = b.path("src/vc4/vc4.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sys", .module = sys }},
    });
    const gles = b.createModule(.{
        .root_source_file = b.path("src/gles/gles.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sys", .module = sys },
            .{ .name = "vc4", .module = vc4 },
        },
    });
    return .{ .sys = sys, .vc4 = vc4, .gles = gles };
}

fn addInitModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, single_threaded: ?bool) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/init/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .strip = if (single_threaded != null) optimize != .Debug else null,
        .imports = &.{
            .{ .name = "sys", .module = m.sys },
            .{ .name = "vc4", .module = m.vc4 },
            .{ .name = "gles", .module = m.gles },
        },
    });
}

pub fn build(b: *std.Build) void {
    // The Raspberry Pi Zero / Zero W: BCM2835, ARM1176JZF-S with VFPv2.
    // No libc: the program talks to the kernel through raw system calls.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
        .os_tag = .linux,
        .abi = .eabihf,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const pi = addModules(b, target, optimize);
    const init_exe = b.addExecutable(.{
        .name = "stardust-init",
        .root_module = addInitModule(b, target, optimize, pi, true),
    });
    b.installArtifact(init_exe);

    // Host tool that packs the init binary into a cpio initramfs.
    const mkinitramfs = b.addExecutable(.{
        .name = "mkinitramfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkinitramfs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_mkinitramfs = b.addRunArtifact(mkinitramfs);
    const initramfs = run_mkinitramfs.addOutputFileArg("initramfs.cpio");
    run_mkinitramfs.addArtifactArg(init_exe);
    const install_initramfs = b.addInstallFile(initramfs, "initramfs.cpio");
    b.getInstallStep().dependOn(&install_initramfs.step);

    const initramfs_step = b.step("initramfs", "Build zig-out/initramfs.cpio");
    initramfs_step.dependOn(&install_initramfs.step);

    // Unit tests run on the build machine; they cover the parts that do not
    // need the GPU (instruction encoding, compiler, simulator, ...).
    const host = addModules(b, b.graph.host, optimize);
    const test_step = b.step("test", "Run unit tests on the host");
    for ([_]*std.Build.Module{ host.sys, host.vc4, host.gles, addInitModule(b, b.graph.host, optimize, host, null) }) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
