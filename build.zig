const std = @import("std");

const Modules = struct {
    sys: *std.Build.Module,
    vc4: *std.Build.Module,
    shader: *std.Build.Module,
    app: *std.Build.Module,
    gfx: *std.Build.Module,
    ui: *std.Build.Module,
    font: *std.Build.Module,
    wayland: *std.Build.Module,
    build_info: *std.Build.Module,
};

/// The library modules, built for one target:
///
/// * `sys`: Linux system call helpers shared by everything
/// * `vc4`: the low-level VideoCore IV graphics API
/// * `shader`: shaders written in Zig: SPIR-V to vc4 programs, and drawing
///   with them
/// * `app`: native apps' windows on dazzle-shell, drawn with vc4
/// * `gfx`: 2D graphics (rounded rectangles, polygons, strokes, text) on vc4
/// * `ui`: the widget toolkit, on gfx
/// * `font`: OpenType font rendering
/// * `wayland`: the Wayland wire protocol and a client library
/// * `build_info`: `commit`, the source's git commit (short, with "-dirty"
///   when there are uncommitted changes), so a running system can be
///   matched to its source
fn addModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, shaders: []const ShaderBlob) Modules {
    const sys, const vc4, const shader = addGpuModules(b, target, optimize);
    const wayland = b.createModule(.{
        .root_source_file = b.path("src/wayland/wayland.zig"),
        .target = target,
        .optimize = optimize,
    });
    const font = b.createModule(.{
        .root_source_file = b.path("src/font/font.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gfx = b.createModule(.{
        .root_source_file = b.path("src/gfx/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vc4", .module = vc4 },
            .{ .name = "shader", .module = shader },
            .{ .name = "font", .module = font },
        },
    });
    addShaderImports(gfx, shaders, .gfx);
    const ui = b.createModule(.{
        .root_source_file = b.path("src/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vc4", .module = vc4 },
            .{ .name = "gfx", .module = gfx },
            .{ .name = "font", .module = font },
        },
    });
    const app = b.createModule(.{
        .root_source_file = b.path("src/app/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vc4", .module = vc4 },
            .{ .name = "wayland", .module = wayland },
        },
    });
    const info = b.addOptions();
    info.addOption([]const u8, "commit", gitCommit(b));
    return .{ .sys = sys, .vc4 = vc4, .shader = shader, .app = app, .gfx = gfx, .ui = ui, .font = font, .wayland = wayland, .build_info = info.createModule() };
}

/// `sys`, `vc4` and `shader`: what the GPU's users need, and what the
/// shader compiler needs on the build machine.
fn addGpuModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct { *std.Build.Module, *std.Build.Module, *std.Build.Module } {
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
    const shader = b.createModule(.{
        .root_source_file = b.path("src/shader/shader.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sys", .module = sys },
            .{ .name = "vc4", .module = vc4 },
        },
    });
    return .{ sys, vc4, shader };
}

/// Who embeds a shader program.
const ShaderOwner = enum { gfx, demo, shell };

/// The shader programs: Zig sources compiled to SPIR-V, then for the GPU
/// by tools/shaderc.zig (with the render state that changes their code),
/// and embedded in their owner as `@embedFile("<name>.shader")`.
/// A program is named after its source unless given a name (to build one
/// source twice, with different options).
const shader_programs = [_]struct { source: []const u8, name: ?[]const u8 = null, owner: ShaderOwner, args: []const []const u8 }{
    .{ .source = "src/gfx/shaders/shape.zig", .owner = .gfx, .args = &.{"--blend=source-over"} },
    .{ .source = "src/gfx/shaders/solid.zig", .owner = .gfx, .args = &.{"--blend=source-over"} },
    // The same, for triangles that are opaque all over: no blending.
    .{ .source = "src/gfx/shaders/solid.zig", .name = "opaque", .owner = .gfx, .args = &.{"--blend=none"} },
    .{ .source = "src/gfx/shaders/text.zig", .owner = .gfx, .args = &.{"--blend=source-over"} },
    .{ .source = "src/demo/shaders/polyhedron.zig", .owner = .demo, .args = &.{"--depth-test"} },
    .{ .source = "src/shell/shaders/quad.zig", .owner = .shell, .args = &.{} },
};

/// Shaders the shader tests compile from SPIR-V themselves, embedded as
/// `@embedFile("<name>.spv")`.
const test_shaders = [_][]const u8{
    "src/shader/testdata/flow.zig",
    "src/shader/testdata/endless.zig",
};

const ShaderBlob = struct {
    /// The source's name without ".zig".
    name: []const u8,
    owner: ShaderOwner,
    spirv: std.Build.LazyPath,
    program: std.Build.LazyPath,
};

/// Compiles the shader programs (once: they are the same for every
/// target).
fn addShaders(b: *std.Build) []const ShaderBlob {
    const shaderc = hostTool(b, "shaderc");
    _, _, const shader = addGpuModules(b, b.graph.host, .ReleaseSafe);
    shaderc.root_module.addImport("shader", shader);

    const blobs = b.allocator.alloc(ShaderBlob, shader_programs.len) catch @panic("OOM");
    for (shader_programs, blobs) |p, *blob| {
        const name = p.name orelse std.fs.path.stem(p.source);
        const spirv = addSpirv(b, name, p.source);
        const run = b.addRunArtifact(shaderc);
        run.addFileArg(spirv);
        const program = run.addOutputFileArg(b.fmt("{s}.shader", .{name}));
        run.addArgs(p.args);
        blob.* = .{ .name = name, .owner = p.owner, .spirv = spirv, .program = program };
    }
    return blobs;
}

/// A shader's Zig source compiled to SPIR-V.
fn addSpirv(b: *std.Build, name: []const u8, source: []const u8) std.Build.LazyPath {
    const spirv_target = b.resolveTargetQuery(.{ .cpu_arch = .spirv64, .os_tag = .vulkan, .ofmt = .spirv });
    const gpu = b.createModule(.{
        .root_source_file = b.path("src/shader/gpu.zig"),
        .target = spirv_target,
        .optimize = .ReleaseFast,
    });
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = spirv_target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "gpu", .module = gpu }},
        }),
        .use_llvm = false,
    });
    return obj.getEmittedBin();
}

fn addShaderImports(m: *std.Build.Module, shaders: []const ShaderBlob, owner: ShaderOwner) void {
    const b = m.owner;
    for (shaders) |s| if (s.owner == owner) {
        m.addAnonymousImport(b.fmt("{s}.shader", .{s.name}), .{ .root_source_file = s.program });
    };
}

/// The short hash of the checked-out commit, "-dirty" if tracked files
/// have changed, or "unknown" outside a git checkout.
fn gitCommit(b: *std.Build) []const u8 {
    const root = b.build_root.path orelse ".";
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", root, "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const hash = std.mem.trim(u8, out, " \n");
    const status = b.runAllowFail(&.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch "";
    return if (std.mem.trim(u8, status, " \n").len > 0) b.fmt("{s}-dirty", .{hash}) else hash;
}

/// A program's root module. `single_threaded` and stripping are set for the
/// Pi builds and left at their defaults for host tests.
fn addProgramModule(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, m: Modules, shaders: []const ShaderBlob, single_threaded: ?bool) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .strip = if (single_threaded != null) optimize != .Debug else null,
        .imports = &.{
            .{ .name = "sys", .module = m.sys },
            .{ .name = "vc4", .module = m.vc4 },
            .{ .name = "shader", .module = m.shader },
            .{ .name = "app", .module = m.app },
            .{ .name = "gfx", .module = m.gfx },
            .{ .name = "ui", .module = m.ui },
            .{ .name = "font", .module = m.font },
            .{ .name = "wayland", .module = m.wayland },
            .{ .name = "build_info", .module = m.build_info },
        },
    });
    // src/<owner>/main.zig embeds its shader programs.
    const dir = std.fs.path.basename(std.fs.path.dirname(path).?);
    if (std.meta.stringToEnum(ShaderOwner, dir)) |owner| addShaderImports(module, shaders, owner);
    return module;
}

/// A host tool from tools/.
fn hostTool(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
}

/// A step that fails, naming the packages to install, if any of the
/// programs ("program:package") is missing.
fn requireTools(b: *std.Build, tools: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(hostTool(b, "check"));
    run.addArg("tools");
    run.addArgs(tools);
    run.has_side_effects = true;
    return run;
}

fn exists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

const linux_version = "v7.2";

const Kernel = struct {
    /// The last step of the kernel build.
    step: *std.Build.Step,
    /// Where make puts its output (O=).
    out: []const u8,
    /// The source tree.
    src: []const u8,

    /// Builds a device tree of our own the way the kernel builds its own
    /// (preprocessed, then compiled by the kernel's dtc), so it can include
    /// one of the kernel's: `#include "arm/broadcom/<board>.dts"`.
    fn deviceTree(k: Kernel, b: *std.Build, dts: std.Build.LazyPath, name: []const u8) std.Build.LazyPath {
        const includes = b.pathJoin(&.{ k.src, "scripts/dtc/include-prefixes" });
        const cpp = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-nostdinc", "-I", includes, "-undef", "-D__DTS__", "-x", "assembler-with-cpp", "-o" });
        const pre = cpp.addOutputFileArg(b.fmt("{s}.dts", .{name}));
        cpp.addFileArg(dts);
        cpp.step.dependOn(k.step);
        const dtc = b.addSystemCommand(&.{b.pathJoin(&.{ k.out, "scripts/dtc/dtc" })});
        dtc.addArgs(&.{ "-q", "-b", "0", b.fmt("-i{s}", .{includes}), "-@", "-o" });
        const out = dtc.addOutputFileArg(b.fmt("{s}.dtb", .{name}));
        dtc.addFileArg(pre);
        return out;
    }

    fn file(k: Kernel, b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        return .{ .cwd_relative = b.pathJoin(&.{ k.out, sub_path }) };
    }
};

/// Linux, built with make (as the kernel must be): tinyconfig, plus the
/// options in kernel/dazzle.config, checked to have all taken effect.
/// make does its own incremental building, so this runs every time and is
/// quick when nothing changed.
fn addKernel(b: *std.Build) Kernel {
    const linux_dir = b.option([]const u8, "linux", "Linux source tree (default: build/linux, cloned at " ++ linux_version ++ " if missing)") orelse
        b.pathFromRoot("build/linux");
    const cross = b.option([]const u8, "cross-compile", "Build the kernel with this GCC cross compiler prefix (e.g. arm-linux-gnueabihf-) instead of LLVM");
    const out = b.pathFromRoot("build/kernel");
    const jobs = std.Thread.getCpuCount() catch 4;

    var tools: std.ArrayList([]const u8) = .empty;
    tools.appendSlice(b.allocator, &.{ "make:make", "flex:flex", "bison:bison", "bc:bc" }) catch @panic("OOM");
    const clone = !exists(b, linux_dir);
    if (clone) tools.append(b.allocator, "git:git") catch @panic("OOM");
    if (cross) |prefix| {
        tools.append(b.allocator, b.fmt("{s}gcc:gcc-arm-linux-gnueabihf", .{prefix})) catch @panic("OOM");
        tools.append(b.allocator, b.fmt("{s}ld:binutils-arm-linux-gnueabihf", .{prefix})) catch @panic("OOM");
    } else {
        tools.appendSlice(b.allocator, &.{ "clang:clang", "ld.lld:lld", "llvm-ar:llvm", "llvm-nm:llvm", "llvm-objcopy:llvm", "llvm-objdump:llvm", "llvm-readelf:llvm", "llvm-strip:llvm" }) catch @panic("OOM");
    }
    var last: *std.Build.Step = &requireTools(b, tools.items).step;

    const Chain = struct {
        fn add(prev: **std.Build.Step, run: *std.Build.Step.Run) void {
            run.has_side_effects = true;
            run.step.dependOn(prev.*);
            prev.* = &run.step;
        }
    };
    if (clone) Chain.add(&last, b.addSystemCommand(&.{ "git", "clone", "--depth", "1", "--branch", linux_version, "https://github.com/torvalds/linux.git", linux_dir }));
    Chain.add(&last, b.addSystemCommand(&.{ "mkdir", "-p", out }));

    const toolchain: []const []const u8 = if (cross) |prefix|
        &.{ "ARCH=arm", b.fmt("CROSS_COMPILE={s}", .{prefix}) }
    else
        &.{ "ARCH=arm", "LLVM=1" };
    const make = struct {
        fn cmd(bb: *std.Build, dir: []const u8, o: []const u8, tc: []const []const u8, targets: []const []const u8) *std.Build.Step.Run {
            const run = bb.addSystemCommand(&.{ "make", "-s", "-C", dir, bb.fmt("O={s}", .{o}) });
            run.addArgs(tc);
            run.addArgs(targets);
            return run;
        }
    }.cmd;
    Chain.add(&last, make(b, linux_dir, out, toolchain, &.{"tinyconfig"}));
    const merge = b.addSystemCommand(&.{ b.pathJoin(&.{ linux_dir, "scripts/kconfig/merge_config.sh" }), "-m", "-O", out, b.pathJoin(&.{ out, ".config" }) });
    merge.addFileArg(b.path("kernel/dazzle.config"));
    // It lists every option it changes; show that only if it fails.
    merge.expectExitCode(0);
    Chain.add(&last, merge);
    Chain.add(&last, make(b, linux_dir, out, toolchain, &.{"olddefconfig"}));
    const check_config = b.addRunArtifact(hostTool(b, "check"));
    check_config.addArg("config");
    check_config.addFileArg(b.path("kernel/dazzle.config"));
    check_config.addArg(b.pathJoin(&.{ out, ".config" }));
    Chain.add(&last, check_config);
    Chain.add(&last, make(b, linux_dir, out, toolchain, &.{
        b.fmt("-j{d}", .{jobs}), "zImage", "broadcom/bcm2835-rpi-zero.dtb", "broadcom/bcm2835-rpi-zero-w.dtb", "broadcom/bcm2837-rpi-3-a-plus.dtb",
    }));
    return .{ .step = last, .out = out, .src = linux_dir };
}

/// Raspberry Pi firmware (the GPU's boot loader), pinned by checksum.
const firmware_tag = "1.20260915";
const firmware = [_]struct { name: []const u8, sha256: []const u8 }{
    .{ .name = "bootcode.bin", .sha256 = "4245ec23b58158dc3e55f3e065eb4ecc0c0705d76c8db506e9f824941feee32e" },
    .{ .name = "start.elf", .sha256 = "32f990801e7765bae6fe5cb940ba5eeff02dd0dac8dc5474db5b3fd345281790" },
    .{ .name = "fixup.dat", .sha256 = "7853f2b51e4489f8b3ce6f9c52fd0afdda38c7383961524e0883d34afcb4827b" },
    .{ .name = "LICENCE.broadcom", .sha256 = "c7283ff51f863d93a275c66e3b4cb08021a5dd4d8c1e7acc47d872fbe52d3d6b" },
};

/// The Wi-Fi chips' firmware, which the kernel's brcmfmac driver loads from
/// /brcm (it asks for "brcm/<name>", and cmdline.txt's
/// firmware_class.path=/ has the kernel look from the root directory, not
/// /lib/firmware), from Raspberry Pi OS's firmware-nonfree (pinned by
/// commit and checksum), named for each board's device tree so the driver
/// finds it. The licence (firmware/LICENCE.cypress) goes with it.
const wifi_firmware_commit = "3bab0f823f5b53150b76aab77093adef6655b920";
const wifi_firmware = [_]struct { name: []const u8, source: []const u8, sha256: []const u8 }{
    // Pi Zero W: CYW43430.
    .{ .name = "brcmfmac43430-sdio.raspberrypi,model-zero-w.bin", .source = "cypress/cyfmac43430-sdio.bin", .sha256 = "0717f8e798f3962230e76e9d840385ba127a38d31d6a55acd5c97cf53e4acc9d" },
    .{ .name = "brcmfmac43430-sdio.raspberrypi,model-zero-w.txt", .source = "brcm/brcmfmac43430-sdio.txt", .sha256 = "fc3949a4c32f07c18308e7e145c7615be314158e7d714a80e04e4791f16495f9" },
    .{ .name = "brcmfmac43430-sdio.raspberrypi,model-zero-w.clm_blob", .source = "cypress/cyfmac43430-sdio.clm_blob", .sha256 = "3376b9c9b32d16bf762e21c7fafb665365070ae240d092498d0d1987c22022aa" },
    // Pi 3 A+: CYW43455.
    .{ .name = "brcmfmac43455-sdio.raspberrypi,3-model-a-plus.bin", .source = "cypress/cyfmac43455-sdio-standard.bin", .sha256 = "d608f866582519c0a28d86db43040f4f1b98dd1d153e72e9752586546b4a36c3" },
    .{ .name = "brcmfmac43455-sdio.raspberrypi,3-model-a-plus.txt", .source = "brcm/brcmfmac43455-sdio.txt", .sha256 = "ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d" },
    .{ .name = "brcmfmac43455-sdio.raspberrypi,3-model-a-plus.clm_blob", .source = "cypress/cyfmac43455-sdio.clm_blob", .sha256 = "9823842cae9fb9a5dd1e5fb31f595516ec7deee341354bef30bb3026eee29cc1" },
};

/// Downloads the files of `dir` that are missing from `url_of(name)`,
/// then checks them all against their checksums. Returns the check.
fn fetchPinned(b: *std.Build, dir: []const u8, files: anytype, comptime url_of: fn (*std.Build, @TypeOf(files[0])) []const u8) *std.Build.Step {
    var fetch: ?*std.Build.Step = null;
    for (files) |f| {
        const path = b.pathJoin(&.{ dir, f.name });
        if (exists(b, path)) continue;
        const curl = b.addSystemCommand(&.{ "curl", "-fsSL", "--create-dirs", "-o", path, url_of(b, f) });
        curl.has_side_effects = true;
        if (fetch == null) {
            const tools = requireTools(b, &.{"curl:curl"});
            fetch = &tools.step;
        }
        curl.step.dependOn(fetch.?);
        fetch = &curl.step;
    }
    const verify = b.addRunArtifact(hostTool(b, "check"));
    verify.addArg("sha256");
    for (files) |f| verify.addArgs(&.{ b.pathJoin(&.{ dir, f.name }), f.sha256 });
    verify.has_side_effects = true;
    if (fetch) |f| verify.step.dependOn(f);
    return &verify.step;
}

fn fetchWifiFirmware(b: *std.Build) *std.Build.Step {
    return fetchPinned(b, b.pathFromRoot("build/firmware/wifi"), wifi_firmware, struct {
        fn url(bb: *std.Build, f: @TypeOf(wifi_firmware[0])) []const u8 {
            return bb.fmt("https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/{s}/debian/added-firmware/{s}", .{ wifi_firmware_commit, f.source });
        }
    }.url);
}

/// The SD card image (zig-out/dazzle.img), and its files in zig-out/boot
/// for copying onto a card by hand.
fn addImage(b: *std.Build, kernel: Kernel, initramfs: std.Build.LazyPath) *std.Build.Step {
    const dir = b.pathFromRoot("build/firmware");
    // Download what is missing, then check everything.
    const verify_step = fetchPinned(b, dir, firmware, struct {
        fn url(bb: *std.Build, f: @TypeOf(firmware[0])) []const u8 {
            return bb.fmt("https://raw.githubusercontent.com/raspberrypi/firmware/{s}/boot/{s}", .{ firmware_tag, f.name });
        }
    }.url);

    const boot_files = [_]struct { []const u8, std.Build.LazyPath }{
        .{ "bootcode.bin", .{ .cwd_relative = b.pathJoin(&.{ dir, "bootcode.bin" }) } },
        .{ "start.elf", .{ .cwd_relative = b.pathJoin(&.{ dir, "start.elf" }) } },
        .{ "fixup.dat", .{ .cwd_relative = b.pathJoin(&.{ dir, "fixup.dat" }) } },
        .{ "LICENCE.broadcom", .{ .cwd_relative = b.pathJoin(&.{ dir, "LICENCE.broadcom" }) } },
        .{ "zImage", kernel.file(b, "arch/arm/boot/zImage") },
        .{ "bcm2835-rpi-zero.dtb", kernel.file(b, "arch/arm/boot/dts/broadcom/bcm2835-rpi-zero.dtb") },
        .{ "bcm2835-rpi-zero-w.dtb", kernel.file(b, "arch/arm/boot/dts/broadcom/bcm2835-rpi-zero-w.dtb") },
        // Mainline's, with the Wi-Fi chip's power added (see the source).
        .{ "bcm2837-rpi-3-a-plus.dtb", kernel.deviceTree(b, b.path("boot/bcm2837-rpi-3-a-plus.dts"), "bcm2837-rpi-3-a-plus") },
        .{ "initramfs.cpio", initramfs },
        .{ "config.txt", b.path("boot/config.txt") },
        .{ "cmdline.txt", b.path("boot/cmdline.txt") },
    };
    const mkimage = b.addRunArtifact(hostTool(b, "mkimage"));
    mkimage.step.dependOn(verify_step);
    mkimage.step.dependOn(kernel.step);
    const img = mkimage.addOutputFileArg("dazzle.img");
    mkimage.addArg(b.fmt("{d}", .{b.option(u32, "image-size", "SD image size in MiB (default 64)") orelse 64}));
    const image_step = b.step("image", "Build everything into an SD card image: zig-out/dazzle.img (and its files in zig-out/boot)");
    for (boot_files) |f| {
        mkimage.addPrefixedFileArg(b.fmt("{s}=", .{f[0]}), f[1]);
        const install = b.addInstallFile(f[1], b.fmt("boot/{s}", .{f[0]}));
        install.step.dependOn(&mkimage.step);
        image_step.dependOn(&install.step);
    }
    image_step.dependOn(&b.addInstallFile(img, "dazzle.img").step);
    return image_step;
}

/// The boards Dazzle runs on, as QEMU emulates them.
const QemuBoard = enum {
    zero,
    @"pi3a+",

    fn dtb(q: QemuBoard) []const u8 {
        return switch (q) {
            .zero => "bcm2835-rpi-zero.dtb",
            .@"pi3a+" => "bcm2837-rpi-3-a-plus.dtb",
        };
    }
};

/// Boots the kernel and initramfs in QEMU's raspi0 machine (or raspi3ap,
/// with -Dqemu-board=pi3a+), with the log server on http://localhost:8080
/// (-Dhttp-port to change).
fn addQemu(b: *std.Build, kernel: Kernel, initramfs: std.Build.LazyPath) void {
    const board = b.option(QemuBoard, "qemu-board", "The board QEMU emulates: zero (default) or pi3a+") orelse .zero;
    const program = if (board == .zero) "qemu-system-arm" else "qemu-system-aarch64";
    const tools = requireTools(b, &.{ b.fmt("{s}:{s}", .{ program, program }), "fdtput:device-tree-compiler" });
    // QEMU lacks the power management block the watchdog driver waits for.
    const dtb = b.pathFromRoot(b.fmt("build/qemu-{s}", .{board.dtb()}));
    const copy = b.addSystemCommand(&.{"cp"});
    copy.addFileArg(kernel.file(b, b.fmt("arch/arm/boot/dts/broadcom/{s}", .{board.dtb()})));
    copy.addArg(dtb);
    copy.step.dependOn(kernel.step);
    copy.step.dependOn(&tools.step);
    copy.has_side_effects = true;
    const patch = b.addSystemCommand(&.{ "fdtput", "-t", "s", dtb, "/soc/watchdog@7e100000", "status", "disabled" });
    patch.step.dependOn(&copy.step);
    patch.has_side_effects = true;
    const port = b.option(u16, "http-port", "Host port for the HTTP log server when running in QEMU (default 8080)") orelse 8080;
    const qemu = b.addSystemCommand(&.{ program, "-M", if (board == .zero) "raspi0" else "raspi3ap", "-kernel" });
    const zimage = kernel.file(b, "arch/arm/boot/zImage");
    switch (board) {
        .zero => qemu.addFileArg(zimage),
        // QEMU starts the Pi 3 in AArch64: a stub switches to AArch32 for
        // the 32-bit kernel. (QEMU's spin loop for the other cores is
        // AArch64 too, so the kernel brings up only the first.)
        .@"pi3a+" => {
            const stub = b.addRunArtifact(hostTool(b, "aarch32boot"));
            stub.addFileArg(zimage);
            stub.step.dependOn(kernel.step);
            qemu.addFileArg(stub.addOutputFileArg("zImage-aarch64"));
        },
    }
    qemu.addArgs(&.{ "-dtb", dtb, "-initrd" });
    qemu.addFileArg(initramfs);
    qemu.addArgs(&.{
        "-append",  "printk.devkmsg=on firmware_class.path=/",
        "-device",  "usb-net,netdev=net0",
        "-netdev",  b.fmt("user,id=net0,hostfwd=tcp:127.0.0.1:{d}-:80", .{port}),
        "-display", "none",
    });
    // The console: the PL011 on the Zero, the mini UART (the second serial
    // port) on the Pi 3 A+.
    if (board == .zero) qemu.addArgs(&.{ "-serial", "mon:stdio" }) else qemu.addArgs(&.{ "-serial", "null", "-serial", "mon:stdio" });
    if (b.args) |args| qemu.addArgs(args);
    qemu.step.dependOn(&patch.step);
    qemu.stdio = .inherit;
    qemu.has_side_effects = true;
    const step = b.step("qemu", "Boot the kernel and initramfs in QEMU (-Dqemu-board=pi3a+ for the Pi 3 A+; arguments after -- go to QEMU)");
    step.dependOn(&qemu.step);
}

pub fn build(b: *std.Build) void {
    // The Raspberry Pi Zero / Zero W: BCM2835, ARM1176JZF-S with VFPv2. The
    // same programs run on the Pi 3 A+'s Cortex-A53 (in AArch32, which runs
    // ARMv6 code). No libc: the programs talk to the kernel through raw
    // system calls.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
        .os_tag = .linux,
        .abi = .eabihf,
    });
    // The Pi programs are optimized for size unless told otherwise (a
    // Debug build is far too slow on a Pi Zero); host tests default to
    // Debug, for their safety checks.
    const explicit_optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSmall for the Pi, Debug for host tests)");
    const optimize: std.builtin.OptimizeMode = explicit_optimize orelse switch (b.release_mode) {
        .off, .any, .small => .ReleaseSmall,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
    };
    const test_optimize = explicit_optimize orelse .Debug;

    const shaders = addShaders(b);
    const pi = addModules(b, target, optimize, shaders);
    // init runs as root; the shell and the apps (its Wayland clients) run
    // as the unprivileged Dazzle user.
    const init_exe = b.addExecutable(.{
        .name = "dazzle-init",
        .root_module = addProgramModule(b, "src/init/main.zig", target, optimize, pi, shaders, true),
    });
    const install_init = b.addInstallArtifact(init_exe, .{});
    const demo_exe = b.addExecutable(.{
        .name = "dazzle-demo",
        .root_module = addProgramModule(b, "src/demo/main.zig", target, optimize, pi, shaders, true),
    });
    const install_demo = b.addInstallArtifact(demo_exe, .{});
    const settings_exe = b.addExecutable(.{
        .name = "dazzle-settings",
        .root_module = addProgramModule(b, "src/settings/main.zig", target, optimize, pi, shaders, true),
    });
    const install_settings = b.addInstallArtifact(settings_exe, .{});
    const files_exe = b.addExecutable(.{
        .name = "dazzle-files",
        .root_module = addProgramModule(b, "src/files/main.zig", target, optimize, pi, shaders, true),
    });
    const install_files = b.addInstallArtifact(files_exe, .{});
    const setup_exe = b.addExecutable(.{
        .name = "dazzle-setup",
        .root_module = addProgramModule(b, "src/setup/main.zig", target, optimize, pi, shaders, true),
    });
    const install_setup = b.addInstallArtifact(setup_exe, .{});
    const shell_exe = b.addExecutable(.{
        .name = "dazzle-shell",
        .root_module = addProgramModule(b, "src/shell/main.zig", target, optimize, pi, shaders, true),
    });
    const install_shell = b.addInstallArtifact(shell_exe, .{});

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
    run_mkinitramfs.addArtifactArg(shell_exe);
    run_mkinitramfs.addFileArg(b.path("fonts/FiraSans-Regular.ttf"));
    run_mkinitramfs.addFileArg(b.path("fonts/OFL.txt"));
    // The Wi-Fi chips' firmware, for the kernel to load.
    run_mkinitramfs.step.dependOn(fetchWifiFirmware(b));
    for (wifi_firmware) |f| {
        run_mkinitramfs.addArg(b.fmt("--file=brcm/{s}={s}", .{ f.name, b.pathJoin(&.{ b.pathFromRoot("build/firmware/wifi"), f.name }) }));
    }
    run_mkinitramfs.addPrefixedFileArg("--file=brcm/LICENCE.cypress=", b.path("firmware/LICENCE.cypress"));
    // The shell's own apps, beside it in /shell (they cannot be removed).
    run_mkinitramfs.addPrefixedArtifactArg("--shell=", settings_exe);
    run_mkinitramfs.addPrefixedArtifactArg("--shell=", setup_exe);
    // The apps, each in /apps/<name>, listed in the shell's dock.
    run_mkinitramfs.addArtifactArg(demo_exe);
    run_mkinitramfs.addArtifactArg(files_exe);
    const install_initramfs = b.addInstallFile(initramfs, "initramfs.cpio");
    const programs_step = b.step("programs", "Build just the programs (zig-out/bin) and zig-out/initramfs.cpio");
    for ([_]*std.Build.Step{ &install_init.step, &install_demo.step, &install_settings.step, &install_files.step, &install_setup.step, &install_shell.step, &install_initramfs.step }) |st| {
        programs_step.dependOn(st);
        b.getInstallStep().dependOn(st);
    }

    const initramfs_step = b.step("initramfs", "Build zig-out/initramfs.cpio");
    initramfs_step.dependOn(&install_initramfs.step);

    const kernel = addKernel(b);
    const kernel_step = b.step("kernel", "Build the Linux kernel and device trees (in build/kernel)");
    kernel_step.dependOn(kernel.step);

    // `zig build` builds everything, including the SD card image.
    b.getInstallStep().dependOn(addImage(b, kernel, initramfs));
    addQemu(b, kernel, initramfs);

    // Unit tests run on the build machine; they cover the parts that do not
    // need the GPU (instruction encoding, compiler, simulator, ...).
    const host = addModules(b, b.graph.host, test_optimize, shaders);
    // The shader tests check programs built here, and compile them again
    // from SPIR-V as an app would.
    for (shaders) |s| {
        host.shader.addAnonymousImport(b.fmt("{s}.shader", .{s.name}), .{ .root_source_file = s.program });
        host.shader.addAnonymousImport(b.fmt("{s}.spv", .{s.name}), .{ .root_source_file = s.spirv });
    }
    for (test_shaders) |source| {
        const name = std.fs.path.stem(source);
        host.shader.addAnonymousImport(b.fmt("{s}.spv", .{name}), .{ .root_source_file = addSpirv(b, name, source) });
    }
    // The font tests use the real system font.
    for ([_]*std.Build.Module{ host.font, host.gfx, host.ui }) |m| m.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    const test_step = b.step("test", "Run unit tests on the host");
    // The demo's layout is tested with its real font.
    const host_demo = addProgramModule(b, "src/demo/main.zig", b.graph.host, test_optimize, host, shaders, null);
    host_demo.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    const host_settings = addProgramModule(b, "src/settings/main.zig", b.graph.host, test_optimize, host, shaders, null);
    host_settings.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    const host_files = addProgramModule(b, "src/files/main.zig", b.graph.host, test_optimize, host, shaders, null);
    host_files.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    const host_setup = addProgramModule(b, "src/setup/main.zig", b.graph.host, test_optimize, host, shaders, null);
    host_setup.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    for ([_]*std.Build.Module{
        host.sys,
        host.vc4,
        host.shader,
        host.app,
        host.gfx,
        host.ui,
        host.font,
        host.wayland,
        addProgramModule(b, "src/init/main.zig", b.graph.host, test_optimize, host, shaders, null),
        host_demo,
        host_settings,
        host_files,
        host_setup,
        addProgramModule(b, "src/shell/main.zig", b.graph.host, test_optimize, host, shaders, null),
    }) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hostTool(b, "mkimage").root_module })).step);

    const shaders_step = b.step("shaders", "Compile the shader programs (zig-out/shaders)");
    for (shaders) |s| shaders_step.dependOn(&b.addInstallFile(s.program, b.fmt("shaders/{s}.shader", .{s.name})).step);
}
