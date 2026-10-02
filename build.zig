const std = @import("std");

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

    const init_exe = b.addExecutable(.{
        .name = "stardust-init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = optimize != .Debug,
        }),
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
    // need the GPU (instruction encoding, command list layout, ...).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests on the host");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
