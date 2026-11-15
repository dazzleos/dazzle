const std = @import("std");
const Icon = @import("src/icons/names.zig").Icon;
const builtin_backgrounds = @import("src/appearance/backgrounds.zig");
const kete_build = @import("kete");

const Modules = struct {
    sys: *std.Build.Module,
    vc4: *std.Build.Module,
    shader: *std.Build.Module,
    app: *std.Build.Module,
    gfx: *std.Build.Module,
    appearance: *std.Build.Module,
    font: *std.Build.Module,
    icons: *std.Build.Module,
    wayland: *std.Build.Module,
    build_info: *std.Build.Module,
    store: *std.Build.Module,
    locale: *std.Build.Module,
    video: *std.Build.Module,
    audio: *std.Build.Module,
};

/// Puts `<program>.icon` in the initramfs: the name of the program's icon
/// in the dock.
fn addAppIcon(b: *std.Build, run: *std.Build.Step.Run, program: []const u8, icon: Icon) void {
    run.addPrefixedFileArg(b.fmt("--file={s}.icon=", .{program}), iconFile(b, program, icon));
}

/// The file naming a program's icon (its `<program>.icon`).
fn iconFile(b: *std.Build, program: []const u8, icon: Icon) std.Build.LazyPath {
    const name = b.fmt("{s}.icon", .{std.fs.path.basename(program)});
    return b.addWriteFiles().add(name, b.fmt("{s}\n", .{@tagName(icon)}));
}

/// Puts a NOTICES file at `dest` in the initramfs: the third-party
/// software built into `what`, from its sections in notices/ (by name).
fn addNotices(b: *std.Build, run: *std.Build.Step.Run, dest: []const u8, what: []const u8, sections: []const []const u8) void {
    run.addPrefixedFileArg(b.fmt("--file={s}=", .{dest}), noticesFile(b, what, sections));
}

fn noticesFile(b: *std.Build, what: []const u8, sections: []const []const u8) std.Build.LazyPath {
    const make = b.addRunArtifact(hostTool(b, "notices"));
    const out = make.addOutputFileArg("NOTICES");
    make.addArg(what);
    for (sections) |s| make.addFileArg(b.path(b.fmt("notices/{s}.txt", .{s})));
    return out;
}

/// A file on the SD card's boot partition: its path there, and where it
/// comes from.
const CardFile = struct { []const u8, std.Build.LazyPath };

/// An app: its program, its icon in the dock, and what the catalogue says
/// of it (when `description` is given; otherwise it is built as an archive
/// for sideloading, not listed in `apps.json`).
const App = struct {
    exe: *std.Build.Step.Compile,
    icon: Icon,
    title: []const u8,
    description: ?[]const u8 = null,
    /// The kinds of files it opens (MIME types), for Files to offer it:
    /// <name>.handles in its folder (see src/sys/apps.zig).
    handles: []const []const u8 = &.{},
    /// Third-party software built into or bundled with the app (in notices/).
    notices: []const []const u8 = &.{"MaterialIcons"},
    /// Extra arguments to `mkapp` (and the step that prepares them, if any).
    extra_args: []const []const u8 = &.{},
    extra_step: ?*std.Build.Step = null,
};

/// Each app as an archive to download (zig-out/apps/<name>.tar.xz: its
/// folder, as in /apps), and the catalogue of them (zig-out/apps/apps.json;
/// see tools/mkcatalogue.zig), published beside the image.
fn addAppArchives(b: *std.Build, apps: []const App) *std.Build.Step {
    const step = b.step("app-archives", "The apps' archives (zig-out/apps)");
    const xz = requireTools(b, &.{"xz:xz-utils"});
    const commit = gitCommit(b);
    const commit_time = gitCommitTime(b);
    const version_file = b.addWriteFiles().add("version", b.fmt("{d} {s}\n", .{ commit_time, commit }));
    const catalogue = b.addRunArtifact(hostTool(b, "mkcatalogue"));
    catalogue.addArg(b.fmt("--key={s}", .{signingKey(b).seed_hex}));
    const json = catalogue.addOutputFileArg("apps.json");
    catalogue.addArgs(&.{ commit, b.fmt("{d}", .{commit_time}) });
    for (apps) |a| {
        const name = a.exe.name;
        const app_dir = std.fs.path.dirname(a.exe.root_module.root_source_file.?.src_path.sub_path).?;
        const icon_png = b.path(b.fmt("{s}/icon.png", .{app_dir}));
        const icon_rel = b.fmt("{s}.png", .{name});
        const pack = b.addRunArtifact(hostTool(b, "mkapp"));
        if (a.extra_step) |es| pack.step.dependOn(es);
        const tar = pack.addOutputFileArg(b.fmt("{s}.tar", .{name}));
        pack.addArg(name);
        pack.addArtifactArg(a.exe);
        pack.addPrefixedFileArg("icon.png=", icon_png);
        pack.addPrefixedFileArg("version=", version_file);
        pack.addPrefixedFileArg(b.fmt("{s}.icon=", .{name}), iconFile(b, name, a.icon));
        if (a.handles.len > 0) {
            var text: std.ArrayList(u8) = .empty;
            for (a.handles) |h| text.print(b.allocator, "{s}\n", .{h}) catch @panic("OOM");
            const handles = b.addWriteFiles().add(b.fmt("{s}.handles", .{name}), text.items);
            pack.addPrefixedFileArg(b.fmt("{s}.handles=", .{name}), handles);
        }
        pack.addPrefixedFileArg("NOTICES=", noticesFile(b, b.fmt("the {s} app", .{a.title}), a.notices));
        pack.addArgs(a.extra_args);
        const compress = b.addSystemCommand(&.{ "xz", "-9", "--block-size=4MiB", "-c" });
        compress.step.dependOn(&xz.step);
        compress.addFileArg(tar);
        const archive = compress.captureStdOut(.{ .basename = b.fmt("{s}.tar.xz", .{name}) });
        step.dependOn(&b.addInstallFile(archive, b.fmt("apps/{s}.tar.xz", .{name})).step);
        if (a.description) |desc| {
            step.dependOn(&b.addInstallFile(icon_png, b.fmt("apps/{s}", .{icon_rel})).step);
            catalogue.addArgs(&.{ name, a.title, desc, icon_rel });
            catalogue.addFileArg(archive);
        }
    }
    step.dependOn(&b.addInstallFile(json, "apps/apps.json").step);
    return step;
}

/// The icon font, cut down to Dazzle's icons, and their codepoints (see
/// tools/subset_icons.zig).
const IconFont = struct {
    ttf: std.Build.LazyPath,
    codepoints: std.Build.LazyPath,
};

fn addIconFont(b: *std.Build) IconFont {
    const tool = hostTool(b, "subset_icons");
    tool.root_module.addImport("font", b.createModule(.{ .root_source_file = b.path("src/font/font.zig"), .target = b.graph.host }));
    tool.root_module.addImport("icon_names", b.createModule(.{ .root_source_file = b.path("src/icons/names.zig"), .target = b.graph.host }));
    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path("fonts/MaterialIcons-Regular.ttf"));
    run.addFileArg(b.path("fonts/MaterialIcons-Regular.codepoints"));
    const ttf = run.addOutputFileArg("MaterialIcons.ttf");
    return .{ .ttf = ttf, .codepoints = run.addOutputFileArg("icon_codepoints.zig") };
}

/// A built-in desktop background, made ready by `tools/mkbackground.zig`:
/// the ETC1 file the shell shows, and Settings' thumbnail of it.
const ReadyBackground = struct { etc1: std.Build.LazyPath, thumbnail: std.Build.LazyPath };

/// Each of `builtin_backgrounds.all` (from backgrounds/<file>.png), made
/// ready once.
fn addBackgrounds(b: *std.Build) []const ReadyBackground {
    const State = struct {
        var ready: ?[builtin_backgrounds.all.len]ReadyBackground = null;
    };
    if (State.ready) |*r| return r;
    const tool = b.addExecutable(.{
        .name = "mkbackground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkbackground.zig"),
            .target = b.graph.host,
            // Compressing 1080p photos takes a while unoptimized.
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "etc1", .module = b.createModule(.{ .root_source_file = b.path("src/vc4/etc1.zig") }) },
                .{ .name = "png", .module = b.createModule(.{ .root_source_file = b.path("src/gfx/png.zig") }) },
            },
        }),
    });
    var ready: [builtin_backgrounds.all.len]ReadyBackground = undefined;
    inline for (builtin_backgrounds.all, &ready) |bg, *r| {
        const run = b.addRunArtifact(tool);
        run.addFileArg(b.path("backgrounds/" ++ bg.file ++ ".png"));
        r.etc1 = run.addOutputFileArg(bg.file ++ ".etc1");
        r.thumbnail = run.addOutputFileArg(bg.file ++ "-thumbnail.png");
        run.addArgs(&.{ b.fmt("{d}", .{builtin_backgrounds.thumbnail_width}), b.fmt("{d}", .{builtin_backgrounds.thumbnail_height}) });
    }
    State.ready = ready;
    return &State.ready.?;
}

/// Settings shows the built-in backgrounds' thumbnails:
/// `@embedFile("background-<file>.png")`.
fn addBackgroundThumbnails(b: *std.Build, m: *std.Build.Module) void {
    for (builtin_backgrounds.all, addBackgrounds(b)) |bg, r| {
        m.addAnonymousImport(b.fmt("background-{s}.png", .{bg.file}), .{ .root_source_file = r.thumbnail });
    }
}

/// The Natural Earth 110m and 50m Admin-0 Countries vector datasets,
/// triangulated and subdivided at build time by `tools/mkmap.zig`.
fn addMapData(b: *std.Build) std.Build.LazyPath {
    const tool = hostTool(b, "mkmap");
    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path("src/apps/maps/data/ne_110m_admin_0_countries.geojson"));
    run.addFileArg(b.path("src/apps/maps/data/ne_50m_admin_0_countries.geojson"));
    return run.addOutputFileArg("map_data.zig");
}

/// The library modules, built for one target:
///
/// * `sys`: Linux system call helpers shared by everything
/// * `vc4`: the low-level VideoCore IV graphics API
/// * `shader`: shaders written in Zig: SPIR-V to vc4 programs, and drawing
///   with them
/// * `app`: native apps' windows on dazzle-shell, drawn with vc4
/// * `gfx`: 2D graphics (rounded rectangles, polygons, strokes, text) on vc4
/// * `appearance`: the theme and desktop background chosen in Settings
/// * `font`: OpenType font rendering
/// * `icons`: Material icons, and the font (with just those) to draw them
/// * `wayland`: the Wayland wire protocol and a client library
/// * `locale`: languages and keyboards: the choice, the keys' characters,
///   and how dates, times and text are written
/// * `store`: installing and removing apps (the catalogue, downloads,
///   archives), for the settings and setup apps
/// * `build_info`: `commit`, the source's git commit (short, with "-dirty"
///   when there are uncommitted changes), so a running system can be
///   matched to its source; `commit_time`, when it was committed (newer
///   systems have later times: see Settings' updates); and `apps_url`,
///   where apps and updates are downloaded from
fn addModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, shaders: []const ShaderBlob, icon_font: IconFont) Modules {
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
    const icons = b.createModule(.{
        .root_source_file = b.path("src/icons/icons.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "font", .module = font },
            .{ .name = "icon_codepoints", .module = b.createModule(.{ .root_source_file = icon_font.codepoints, .target = target, .optimize = optimize }) },
        },
    });
    icons.addAnonymousImport("MaterialIcons.ttf", .{ .root_source_file = icon_font.ttf });
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
    const locale = sys.import_table.get("locale").?;
    const app = b.createModule(.{
        .root_source_file = b.path("src/app/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vc4", .module = vc4 },
            .{ .name = "sys", .module = sys },
            .{ .name = "wayland", .module = wayland },
            .{ .name = "locale", .module = locale },
        },
    });
    const audio = b.createModule(.{
        .root_source_file = b.path("src/audio/audio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sys", .module = sys },
        },
    });
    const video = b.createModule(.{
        .root_source_file = b.path("src/video/video.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sys", .module = sys },
            .{ .name = "gfx", .module = gfx },
            .{ .name = "audio", .module = audio },
        },
    });
    const appearance = b.createModule(.{
        .root_source_file = b.path("src/appearance/appearance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sys", .module = sys },
        },
    });
    const info = b.addOptions();
    info.addOption([]const u8, "commit", gitCommit(b));
    info.addOption(u64, "commit_time", gitCommitTime(b));
    info.addOption([]const u8, "apps_url", appsUrl(b));
    info.addOption([]const u8, "signing_key", signingKey(b).public_hex);
    const build_info = info.createModule();
    const store = b.createModule(.{
        .root_source_file = b.path("src/store/store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sys", .module = sys },
            .{ .name = "build_info", .module = build_info },
        },
    });
    return .{ .sys = sys, .vc4 = vc4, .shader = shader, .app = app, .gfx = gfx, .appearance = appearance, .font = font, .icons = icons, .wayland = wayland, .build_info = build_info, .store = store, .locale = locale, .video = video, .audio = audio };
}

/// `sys`, `vc4` and `shader`: what the GPU's users need, and what the
/// shader compiler needs on the build machine.
fn addGpuModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) struct { *std.Build.Module, *std.Build.Module, *std.Build.Module } {
    const locale = b.createModule(.{
        .root_source_file = b.path("src/locale/locale.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sys = b.createModule(.{
        .root_source_file = b.path("src/sys/sys.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "locale", .module = locale }},
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
const ShaderOwner = enum { gfx, demo, shell, blocks, maps };

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
    .{ .source = "src/gfx/shaders/image.zig", .owner = .gfx, .args = &.{"--blend=source-over"} },
    .{ .source = "src/apps/demo/shaders/polyhedron.zig", .owner = .demo, .args = &.{"--depth-test"} },
    // The voxel game's: blocks (solid, then glass and plants blended),
    // water, the sky, the outline of the block picked, and the world drawn
    // smaller stretched over the view.
    .{ .source = "src/apps/blocks/shaders/terrain.zig", .owner = .blocks, .args = &.{"--depth-test"} },
    .{ .source = "src/apps/blocks/shaders/terrain.zig", .name = "terrain_blend", .owner = .blocks, .args = &.{ "--depth-test", "--blend=source-over" } },
    .{ .source = "src/apps/blocks/shaders/water.zig", .owner = .blocks, .args = &.{ "--depth-test", "--blend=source-over" } },
    .{ .source = "src/apps/blocks/shaders/sky.zig", .owner = .blocks, .args = &.{"--depth-test"} },
    .{ .source = "src/apps/blocks/shaders/upscale.zig", .owner = .blocks, .args = &.{} },
    .{ .source = "src/apps/blocks/shaders/line.zig", .owner = .blocks, .args = &.{"--depth-test"} },
    .{ .source = "src/shell/shaders/quad.zig", .owner = .shell, .args = &.{} },
    // The same, blended: the shaded preview of where a window will go.
    .{ .source = "src/shell/shaders/quad.zig", .name = "quad_blend", .owner = .shell, .args = &.{"--blend=source-over"} },
    // Surfaces with alpha (premultiplied, as Wayland's are): a layer over
    // a window, say.
    .{ .source = "src/shell/shaders/quad.zig", .name = "quad_premultiplied", .owner = .shell, .args = &.{"--blend=premultiplied-over"} },
    // Rounded windows' corners and shadows.
    .{ .source = "src/shell/shaders/window.zig", .owner = .shell, .args = &.{"--blend=source-over"} },
    .{ .source = "src/apps/maps/shaders/globe.zig", .owner = .maps, .args = &.{"--depth-test"} },
};

/// Shaders the shader tests compile from SPIR-V themselves, embedded as
/// `@embedFile("<name>.spv")`.
const test_shaders = [_][]const u8{
    "src/shader/testdata/flow.zig",
    "src/shader/testdata/endless.zig",
    "src/shader/testdata/two_textures.zig",
    "src/shader/testdata/three_textures.zig",
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
    _, _, const shader = addGpuModules(b, b.graph.host, .safe);
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
        .optimize = .fast,
    });
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = spirv_target,
            .optimize = .fast,
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

/// Where Settings downloads the app catalogue and the apps from: where
/// the image is published (CI's "latest" release).
fn appsUrl(b: *std.Build) []const u8 {
    const State = struct {
        var url: ?[]const u8 = null;
    };
    if (State.url) |u| return u;
    State.url = b.option([]const u8, "apps-url", "Where Settings downloads apps and their catalogue (apps.json) from") orelse
        "https://github.com/dazzleos/dazzle/releases/latest/download";
    return State.url.?;
}

const SigningKey = struct {
    seed_hex: []const u8,
    public_hex: []const u8,
};

/// The Ed25519 signing key seed (64 hex digits) and its derived 64-hex-digit
/// public key, from `-Dsigning-key=<seed-hex-or-file>`, `DAZZLE_SIGNING_KEY`,
/// or the deterministic default build seed.
fn signingKey(b: *std.Build) SigningKey {
    const State = struct {
        var key: ?SigningKey = null;
    };
    if (State.key) |k| return k;
    const Ed25519 = std.crypto.sign.Ed25519;
    const default_seed: [32]u8 = "dazzle-signing-key-seed-00000001".*;
    const raw_opt = b.option([]const u8, "signing-key", "Ed25519 signing key seed (64 hex digits, or path to file; default: DAZZLE_SIGNING_KEY or built-in key)") orelse
        b.graph.environ_map.get("DAZZLE_SIGNING_KEY");
    var seed: [32]u8 = default_seed;
    if (raw_opt) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 64 and isHexSlice(trimmed)) {
            _ = std.fmt.hexToBytes(&seed, trimmed) catch @panic("invalid -Dsigning-key hex");
        } else if (trimmed.len > 0) {
            b.graph.poisonCache();
            const file_bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, trimmed, b.allocator, .limited(4096)) catch @panic("cannot read signing key file");
            const file_hex = std.mem.trim(u8, file_bytes, " \t\r\n");
            if (file_hex.len != 64 or !isHexSlice(file_hex)) @panic("signing key file must contain 64 hex digits (32-byte Ed25519 seed)");
            _ = std.fmt.hexToBytes(&seed, file_hex) catch @panic("invalid signing key file hex");
        }
    }
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    const pub_bytes = kp.public_key.toBytes();
    State.key = .{
        .seed_hex = b.fmt("{x}", .{&seed}),
        .public_hex = b.fmt("{x}", .{&pub_bytes}),
    };
    return State.key.?;
}

fn isHexSlice(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The project's directory (where build.zig is).
fn rootDir(b: *std.Build) []const u8 {
    const dir = b.root.root_dir.path orelse ".";
    return if (b.root.sub_path.len == 0) dir else b.pathJoin(&.{ dir, b.root.sub_path });
}

/// A path in the project's directory.
fn fromRoot(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.pathJoin(&.{ rootDir(b), sub_path });
}

/// The short hash of the checked-out commit, "-dirty" if tracked files
/// have changed, or "unknown" outside a git checkout.
fn gitCommit(b: *std.Build) []const u8 {
    // What git says can change without build.zig knowing: configure again
    // each build.
    b.graph.poisonCache();
    const root = rootDir(b);
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", root, "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const hash = std.mem.trim(u8, out, " \n");
    const status = b.runAllowFail(&.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch "";
    return if (std.mem.trim(u8, status, " \n").len > 0) b.fmt("{s}-dirty", .{hash}) else hash;
}

/// When the checked-out commit was made, in seconds since 1970 (0 if
/// unknown).
fn gitCommitTime(b: *std.Build) u64 {
    b.graph.poisonCache();
    const root = rootDir(b);
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", root, "log", "-1", "--format=%ct" }, &code, .ignore) catch return 0;
    return std.fmt.parseInt(u64, std.mem.trim(u8, out, " \n"), 10) catch 0;
}

/// A program's root module. The Pi builds (`pi_build`) are stripped (unless
/// built for debugging); host tests keep their symbols.
fn addProgramModule(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, m: Modules, shaders: []const ShaderBlob, pi_build: bool) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .strip = if (pi_build) optimize != .debug else null,
        .imports = &.{
            .{ .name = "sys", .module = m.sys },
            .{ .name = "vc4", .module = m.vc4 },
            .{ .name = "shader", .module = m.shader },
            .{ .name = "app", .module = m.app },
            .{ .name = "gfx", .module = m.gfx },
            .{ .name = "appearance", .module = m.appearance },
            .{ .name = "font", .module = m.font },
            .{ .name = "icons", .module = m.icons },
            .{ .name = "wayland", .module = m.wayland },
            .{ .name = "build_info", .module = m.build_info },
            .{ .name = "store", .module = m.store },
            .{ .name = "locale", .module = m.locale },
            .{ .name = "video", .module = m.video },
            .{ .name = "audio", .module = m.audio },
        },
    });
    // src/<owner>/main.zig embeds its shader programs.
    const dir = std.fs.path.basename(std.fs.path.dirname(path).?);
    if (std.meta.stringToEnum(ShaderOwner, dir)) |owner| addShaderImports(module, shaders, owner);
    return module;
}

/// Gives `module` kete (built without its own backends, or its fonts: it
/// reads the system's, in /os/fonts), and `kete_vc4`,
/// which draws it with Dazzle's window and GPU. Its icon font has only the
/// icons named in `app_dir`'s source (and kete's and kete_vc4's), not all
/// of Material Icons: an icon chosen at run time must be named somewhere,
///
///     comptime { _ = &[_]kete.IconName{ .cloud, .download }; }
fn addKete(b: *std.Build, module: *std.Build.Module, m: Modules, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, app_dir: []const u8) *std.Build.Module {
    const dep = b.dependency("kete", .{});
    const icon_font = kete_build.addIconFontScanned(dep.builder, &.{ b.path(app_dir), b.path("src/kete_vc4") });
    const kete = kete_build.createModules(dep.builder, b.fmt("kete-{s}-{s}", .{ std.fs.path.basename(app_dir), @tagName(target.result.cpu.arch) }), target, optimize, icon_font, .{
        .backends = false,
        .embed_fonts = false,
    }).kete;
    const kete_vc4 = b.createModule(.{
        .root_source_file = b.path("src/kete_vc4/kete_vc4.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kete", .module = kete },
            .{ .name = "sys", .module = m.sys },
            .{ .name = "vc4", .module = m.vc4 },
            .{ .name = "shader", .module = m.shader },
            .{ .name = "app", .module = m.app },
            .{ .name = "gfx", .module = m.gfx },
            .{ .name = "locale", .module = m.locale },
            .{ .name = "appearance", .module = m.appearance },
            .{ .name = "font", .module = m.font },
        },
    });
    module.addImport("kete", kete);
    module.addImport("kete_vc4", kete_vc4);
    return kete_vc4;
}

/// A host tool from tools/.
fn hostTool(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
            .target = b.graph.host,
            // Optimized (with its checks kept): some run at every build,
            // hashing and signing megabytes of archives, which takes
            // seconds unoptimized.
            .optimize = .ReleaseSafe,
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
    // Files fetched or removed outside the build change the steps.
    b.graph.poisonCache();
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

/// The Raspberry Pi kernel: the tip of its default branch (a long-term
/// kernel, with upstream's stable fixes merged in), fetched again at every
/// build so the system always has the latest fixes.
const linux_repo = "https://github.com/raspberrypi/linux.git";

/// The device trees the firmware loads (it picks one by the board, and the
/// slot's kernel.img or kernel7.img by its CPU). The Pi 1 A and A+, and the
/// Pi 3 A+, use the B's, B+'s and 3 B+'s.
const device_trees = [_][]const u8{
    "bcm2708-rpi-b.dtb",
    "bcm2708-rpi-b-rev1.dtb",
    "bcm2708-rpi-b-plus.dtb",
    "bcm2708-rpi-cm.dtb",
    "bcm2708-rpi-zero.dtb",
    "bcm2708-rpi-zero-w.dtb",
    "bcm2709-rpi-2-b.dtb",
    "bcm2709-rpi-cm2.dtb",
    "bcm2710-rpi-2-b.dtb",
    "bcm2710-rpi-3-b.dtb",
    "bcm2710-rpi-3-b-plus.dtb",
    "bcm2710-rpi-cm0.dtb",
    "bcm2710-rpi-cm3.dtb",
    "bcm2710-rpi-zero-2.dtb",
    "bcm2710-rpi-zero-2-w.dtb",
    "bcm2711-rpi-4-b.dtb",
    "bcm2711-rpi-400.dtb",
    "bcm2711-rpi-cm4.dtb",
    "bcm2711-rpi-cm4s.dtb",
};

const arm64_device_trees = [_][]const u8{
    "bcm2712-rpi-5-b.dtb",
    "bcm2712-d-rpi-5-b.dtb",
    "bcm2712-rpi-500.dtb",
    "bcm2712-rpi-cm5-cm5io.dtb",
    "bcm2712-rpi-cm5-cm4io.dtb",
    "bcm2712-rpi-cm5l-cm5io.dtb",
    "bcm2712-rpi-cm5l-cm4io.dtb",
};

/// The device tree overlays the firmware may apply: the display driver
/// (config.txt's dtoverlay=vc4-kms-v3d, which overlay_map.dtb redirects to
/// vc4-kms-v3d-pi4 on the Pi 4 and vc4-kms-v3d-pi5 on the Pi 5) and the
/// cameras (camera_auto_detect picks one). overlay_map.dtb tells the firmware
/// which overlays suit which board.
const overlays = [_][]const u8{ "vc4-kms-v3d.dtbo", "vc4-kms-v3d-pi4.dtbo", "vc4-kms-v3d-pi5.dtbo", "imx219.dtbo", "ov5647.dtbo", "overlay_map.dtb" };

/// Each slot's overlays/README. The firmware only reads overlays from
/// `${os_prefix}overlays/` when this file is there (it says nothing
/// otherwise, and looks in /overlays/ instead).
const overlays_readme =
    \\Device tree overlays for this Dazzle OS slot (vc4-kms-v3d for the
    \\display, imx219 and ov5647 for the cameras), from the Raspberry Pi
    \\kernel.
    \\
    \\The Raspberry Pi firmware loads overlays from the folder os_prefix
    \\names (config.txt) only when this README is here: keep it.
    \\
;

/// Makes a kernel configuration (see `addKernel`): `$1` the source tree,
/// `$2` the output directory, `$3` merge_config.sh, `$4` "stamp" to skip
/// it when made before from the same things or "always", `$5` and `$6`
/// the fragments, and the rest make's ARCH= and CROSS_COMPILE=.
const config_script =
    \\set -e
    \\src=$1 o=$2 merge=$3 mode=$4 dazzle=$5 arch=$6
    \\shift 6
    \\mkdir -p "$o"
    \\cross=$(printf '%s\n' "$@" | sed -n 's/^CROSS_COMPILE=//p')
    \\want="$(git -C "$src" rev-parse HEAD) $(cat "$dazzle" "$arch" | sha256sum) $("${cross}gcc" -dumpfullversion) $*"
    \\if [ "$mode" = stamp ] && [ -f "$o/.config" ] && [ "$(cat "$o/.dazzle-config" 2>/dev/null)" = "$want" ]; then exit 0; fi
    \\rm -f "$o/.dazzle-config"
    \\make -s -C "$src" O="$o" "$@" tinyconfig
    \\# It lists every option it changes: shown only if it fails.
    \\if ! "$merge" -m -O "$o" "$o/.config" "$dazzle" "$arch" > "$o/merge.log" 2>&1; then cat "$o/merge.log" >&2; exit 1; fi
    \\make -s -C "$src" O="$o" "$@" olddefconfig
    \\printf '%s\n' "$want" > "$o/.dazzle-config"
;

const Kernel = struct {
    /// The last step of the kernel builds.
    step: *std.Build.Step,
    /// Where make puts the ARMv6, ARMv7 and ARM64 kernels (O=).
    v6: []const u8,
    v7: []const u8,
    v8: []const u8,
    /// The source tree.
    src: []const u8,

    /// kernel.img: ARMv6, for the Pi 1, Zero and Zero W.
    fn armv6(k: Kernel, b: *std.Build) std.Build.LazyPath {
        return .{ .cwd_relative = b.pathJoin(&.{ k.v6, "arch/arm/boot/zImage" }) };
    }

    /// kernel7.img: ARMv7, with SMP, for the Pi 2, 3, Zero 2 W and 4.
    fn armv7(k: Kernel, b: *std.Build) std.Build.LazyPath {
        return .{ .cwd_relative = b.pathJoin(&.{ k.v7, "arch/arm/boot/zImage" }) };
    }

    /// kernel8.img: ARM64 (gzip-compressed Image.gz), for the Pi 5, 500 and CM5.
    fn arm64(k: Kernel, b: *std.Build) std.Build.LazyPath {
        return .{ .cwd_relative = b.pathJoin(&.{ k.v8, "arch/arm64/boot/Image.gz" }) };
    }

    fn deviceTree(k: Kernel, b: *std.Build, name: []const u8) std.Build.LazyPath {
        return .{ .cwd_relative = b.pathJoin(&.{ k.v7, "arch/arm/boot/dts/broadcom", name }) };
    }

    fn arm64DeviceTree(k: Kernel, b: *std.Build, name: []const u8) std.Build.LazyPath {
        return .{ .cwd_relative = b.pathJoin(&.{ k.v8, "arch/arm64/boot/dts/broadcom", name }) };
    }

    fn overlay(k: Kernel, b: *std.Build, name: []const u8) std.Build.LazyPath {
        return .{ .cwd_relative = b.pathJoin(&.{ k.v7, "arch/arm/boot/dts/overlays", name }) };
    }
};

/// Linux, built with make (as the kernel must be) with GCC, as Raspberry Pi
/// build it: ARMv6 (kernel.img), ARMv7 with SMP (kernel7.img) and ARM64 with
/// 32-bit compatibility (kernel8.img), each tinyconfig plus the options in
/// kernel/dazzle.config and kernel/armv6.config, kernel/armv7.config or
/// kernel/arm64.config, checked to have all taken effect. make does its own
/// incremental building, so this runs every time and is quick when nothing
/// changed.
fn addKernel(b: *std.Build) Kernel {
    const own_tree = b.option([]const u8, "linux", "Linux source tree to build, as it is (default: build/linux-rpi, the Raspberry Pi kernel's default branch, fetched again at every build)");
    const offline = b.option(bool, "offline", "Do not fetch the latest Raspberry Pi kernel (build what build/linux-rpi has)") orelse false;
    const linux_dir = own_tree orelse fromRoot(b, "build/linux-rpi");
    const cross = b.option([]const u8, "cross-compile", "The GCC cross compiler prefix for 32-bit ARM kernels (default: arm-linux-gnueabihf-)") orelse "arm-linux-gnueabihf-";
    const cross64 = b.option([]const u8, "cross-compile-arm64", "The GCC cross compiler prefix for the 64-bit ARM kernel (default: aarch64-linux-gnu-)") orelse "aarch64-linux-gnu-";
    const out = fromRoot(b, "build/kernel");
    const jobs = std.Thread.getCpuCount() catch 4;

    var tools: std.ArrayList([]const u8) = .empty;
    tools.appendSlice(b.allocator, &.{ "make:make", "flex:flex", "bison:bison", "bc:bc", "git:git" }) catch @panic("OOM");
    tools.append(b.allocator, b.fmt("{s}gcc:gcc-arm-linux-gnueabihf", .{cross})) catch @panic("OOM");
    tools.append(b.allocator, b.fmt("{s}ld:binutils-arm-linux-gnueabihf", .{cross})) catch @panic("OOM");
    tools.append(b.allocator, b.fmt("{s}gcc:gcc-aarch64-linux-gnu", .{cross64})) catch @panic("OOM");
    tools.append(b.allocator, b.fmt("{s}ld:binutils-aarch64-linux-gnu", .{cross64})) catch @panic("OOM");
    var last: *std.Build.Step = &requireTools(b, tools.items).step;

    const Chain = struct {
        fn add(prev: **std.Build.Step, run: *std.Build.Step.Run) void {
            run.has_side_effects = true;
            run.step.dependOn(prev.*);
            prev.* = &run.step;
        }
    };
    // The source: the tip of the default branch, cloned or brought up to
    // date (just that commit, without history).
    if (own_tree == null) {
        if (!exists(b, linux_dir)) {
            Chain.add(&last, b.addSystemCommand(&.{ "git", "clone", "--depth", "1", linux_repo, linux_dir }));
        } else if (!offline) {
            Chain.add(&last, b.addSystemCommand(&.{ "git", "-C", linux_dir, "fetch", "--depth", "1", "origin", "HEAD" }));
            Chain.add(&last, b.addSystemCommand(&.{ "git", "-C", linux_dir, "reset", "-q", "--hard", "FETCH_HEAD" }));
        }
    }

    const tc32: []const []const u8 = &.{ "ARCH=arm", b.fmt("CROSS_COMPILE={s}", .{cross}) };
    const tc64: []const []const u8 = &.{ "ARCH=arm64", b.fmt("CROSS_COMPILE={s}", .{cross64}) };
    const make = struct {
        fn cmd(bb: *std.Build, dir: []const u8, o: []const u8, tc: []const []const u8, targets: []const []const u8) *std.Build.Step.Run {
            const run = bb.addSystemCommand(&.{ "make", "-s", "-C", dir, bb.fmt("O={s}", .{o}) });
            run.addArgs(tc);
            run.addArgs(targets);
            return run;
        }
    }.cmd;
    var dirs: [3][]const u8 = undefined;
    for ([_][]const u8{ "armv6", "armv7", "arm64" }, &dirs) |arch, *dir| {
        const is_64 = std.mem.eql(u8, arch, "arm64");
        const toolchain = if (is_64) tc64 else tc32;
        const o = b.pathJoin(&.{ out, arch });
        dir.* = o;
        const fragment = b.path(b.fmt("kernel/{s}.config", .{arch}));
        // The configuration: the smallest, with Dazzle's options and the
        // architecture's merged in. Made again only when what it is made
        // from changed (the kernel's source, the two fragments, the
        // compiler): otherwise a build would spend most of its time on it,
        // and the kernel's make would then look over everything again. A
        // tree of one's own (-Dlinux) may have changed without a commit:
        // its configuration is always made again.
        const config = b.addSystemCommand(&.{ "sh", "-c", config_script, "config", linux_dir, o, b.pathJoin(&.{ linux_dir, "scripts/kconfig/merge_config.sh" }), if (own_tree == null) "stamp" else "always" });
        config.addFileArg(b.path("kernel/dazzle.config"));
        config.addFileArg(fragment);
        config.addArgs(toolchain);
        Chain.add(&last, config);
        for ([_]std.Build.LazyPath{ b.path("kernel/dazzle.config"), fragment }) |wanted| {
            const check_config = b.addRunArtifact(hostTool(b, "check"));
            check_config.addArg("config");
            check_config.addFileArg(wanted);
            check_config.addArg(b.pathJoin(&.{ o, ".config" }));
            Chain.add(&last, check_config);
        }
        var targets: std.ArrayList([]const u8) = .empty;
        targets.appendSlice(b.allocator, &.{ b.fmt("-j{d}", .{jobs}), if (is_64) "Image.gz" else "zImage" }) catch @panic("OOM");
        // The 32-bit device trees and overlays once, with the ARMv7 kernel;
        // the BCM2712 device trees with the ARM64 kernel.
        if (std.mem.eql(u8, arch, "armv7")) {
            for (device_trees) |d| targets.append(b.allocator, b.fmt("broadcom/{s}", .{d})) catch @panic("OOM");
            for (overlays) |d| targets.append(b.allocator, b.fmt("overlays/{s}", .{d})) catch @panic("OOM");
        } else if (is_64) {
            for (arm64_device_trees) |d| targets.append(b.allocator, b.fmt("broadcom/{s}", .{d})) catch @panic("OOM");
        }
        Chain.add(&last, make(b, linux_dir, o, toolchain, targets.items));
    }
    return .{ .step = last, .v6 = dirs[0], .v7 = dirs[1], .v8 = dirs[2], .src = linux_dir };
}

/// Raspberry Pi firmware (the GPU's boot loader), pinned by checksum.
const firmware_tag = "1.20260915";
const firmware = [_]struct { name: []const u8, sha256: []const u8 }{
    .{ .name = "bootcode.bin", .sha256 = "4245ec23b58158dc3e55f3e065eb4ecc0c0705d76c8db506e9f824941feee32e" },
    .{ .name = "start.elf", .sha256 = "32f990801e7765bae6fe5cb940ba5eeff02dd0dac8dc5474db5b3fd345281790" },
    .{ .name = "fixup.dat", .sha256 = "7853f2b51e4489f8b3ce6f9c52fd0afdda38c7383961524e0883d34afcb4827b" },
    .{ .name = "start4.elf", .sha256 = "560ead37044d849325755d3684ac1f74654b3ce6450604a42df6dd832cda9ede" },
    .{ .name = "fixup4.dat", .sha256 = "d181d5055daebac22513d6904fa9ce21d1e99b852cc391af095ade6f0b45c400" },
    .{ .name = "LICENCE.broadcom", .sha256 = "c7283ff51f863d93a275c66e3b4cb08021a5dd4d8c1e7acc47d872fbe52d3d6b" },
};

/// The Wi-Fi chips' firmware, which the kernel's brcmfmac driver loads from
/// /os/firmware/brcm (it asks for "brcm/<name>", and cmdline.txt's
/// firmware_class.path=/os/firmware has the kernel look from there, not
/// /lib/firmware), from Raspberry Pi OS's firmware-nonfree (pinned by
/// commit and checksum), by the chip's name: the driver asks for the
/// board's own first, then these. The licence (firmware/LICENCE.cypress)
/// goes with it.
const wifi_firmware_commit = "3bab0f823f5b53150b76aab77093adef6655b920";
const wifi_firmware = [_]struct { name: []const u8, source: []const u8, sha256: []const u8 }{
    // CYW43430: the Zero W and the Pi 3 B.
    .{ .name = "brcmfmac43430-sdio.bin", .source = "cypress/cyfmac43430-sdio.bin", .sha256 = "0717f8e798f3962230e76e9d840385ba127a38d31d6a55acd5c97cf53e4acc9d" },
    .{ .name = "brcmfmac43430-sdio.txt", .source = "brcm/brcmfmac43430-sdio.txt", .sha256 = "fc3949a4c32f07c18308e7e145c7615be314158e7d714a80e04e4791f16495f9" },
    .{ .name = "brcmfmac43430-sdio.clm_blob", .source = "cypress/cyfmac43430-sdio.clm_blob", .sha256 = "3376b9c9b32d16bf762e21c7fafb665365070ae240d092498d0d1987c22022aa" },
    // CYW43455: the Pi 3 B+, 3 A+, 4 B and 5.
    .{ .name = "brcmfmac43455-sdio.bin", .source = "cypress/cyfmac43455-sdio-standard.bin", .sha256 = "d608f866582519c0a28d86db43040f4f1b98dd1d153e72e9752586546b4a36c3" },
    .{ .name = "brcmfmac43455-sdio.txt", .source = "brcm/brcmfmac43455-sdio.txt", .sha256 = "ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d" },
    .{ .name = "brcmfmac43455-sdio.raspberrypi,4-model-b.txt", .source = "brcm/brcmfmac43455-sdio.txt", .sha256 = "ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d" },
    .{ .name = "brcmfmac43455-sdio.raspberrypi,5-model-b.txt", .source = "brcm/brcmfmac43455-sdio.txt", .sha256 = "ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d" },
    .{ .name = "brcmfmac43455-sdio.clm_blob", .source = "cypress/cyfmac43455-sdio.clm_blob", .sha256 = "9823842cae9fb9a5dd1e5fb31f595516ec7deee341354bef30bb3026eee29cc1" },
    // CYW43436 (and the earlier 43436s): the Zero 2 W.
    .{ .name = "brcmfmac43436-sdio.bin", .source = "brcm/brcmfmac43436-sdio.bin", .sha256 = "510a7dd1e056199b309425548ee0bd846993a1837ac7fa1e4d3e641f05a1327a" },
    .{ .name = "brcmfmac43436-sdio.txt", .source = "brcm/brcmfmac43436-sdio.txt", .sha256 = "4cda90facd8844cff60d80b34b24ecbae76adb9a62508a109461b8bf42b478d1" },
    .{ .name = "brcmfmac43436-sdio.clm_blob", .source = "brcm/brcmfmac43436-sdio.clm_blob", .sha256 = "fce7cbb62ffa6a5a65ca97b13f6fbf28d06c02d986c2072d65bf72164755fc34" },
    .{ .name = "brcmfmac43436s-sdio.bin", .source = "brcm/brcmfmac43436s-sdio.bin", .sha256 = "68b9bcc9855d91733cd44c21de4cb507c91b0d32d838c0696def5eb96c99e2de" },
    .{ .name = "brcmfmac43436s-sdio.txt", .source = "brcm/brcmfmac43436s-sdio.txt", .sha256 = "37a8b85a5a9742761101b764a07bc4d0c8b09f2e180eaea3b503a834277ad595" },
};

/// Downloads the files of `dir` that are missing from `url_of(name)`,
/// then checks them all against their checksums. Returns the check.
fn fetchPinned(b: *std.Build, dir: []const u8, files: anytype, comptime url_of: fn (*std.Build, @TypeOf(files[0])) []const u8) *std.Build.Step {
    var fetch: ?*std.Build.Step = null;
    for (files) |f| {
        const path = b.pathJoin(&.{ dir, f.name });
        if (exists(b, path)) continue;
        const part = b.fmt("{s}.part", .{path});
        const curl = b.addSystemCommand(&.{
            "sh",
            "-c",
            "curl -fsSL --retry 3 --create-dirs -o \"$1\" \"$2\" && mv \"$1\" \"$3\"",
            "fetch",
            part,
            url_of(b, f),
            path,
        });
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

/// The certificates of the authorities HTTPS trusts: Mozilla's, as the
/// certifi project publishes them (PEM), pinned by its release and checksum.
const ca_certificates_tag = "2025.11.12";
const ca_certificates = [_]struct { name: []const u8, sha256: []const u8 }{
    .{ .name = "cacert.pem", .sha256 = "a1ad5d643e21c43b5bed74c7e0891dcdb58f6af51c8ace1e4f020d654aa52a16" },
};

fn fetchCaCertificates(b: *std.Build) *std.Build.Step {
    return fetchPinned(b, fromRoot(b, "build/firmware/certs"), ca_certificates, struct {
        fn url(bb: *std.Build, f: @TypeOf(ca_certificates[0])) []const u8 {
            return bb.fmt("https://raw.githubusercontent.com/certifi/python-certifi/{s}/certifi/{s}", .{ ca_certificates_tag, f.name });
        }
    }.url);
}

fn fetchWifiFirmware(b: *std.Build) *std.Build.Step {
    return fetchPinned(b, fromRoot(b, "build/firmware/wifi"), wifi_firmware, struct {
        fn url(bb: *std.Build, f: @TypeOf(wifi_firmware[0])) []const u8 {
            return bb.fmt("https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/{s}/debian/added-firmware/{s}", .{ wifi_firmware_commit, f.source });
        }
    }.url);
}

/// The ARM Linux Zig compiler bundled into the Develop app, pinned by
/// version and checksum.
const zig_version = "0.17.1";
const zig_arm_archive = [_]struct { name: []const u8, sha256: []const u8 }{
    .{ .name = "zig-arm-linux-" ++ zig_version ++ ".tar.xz", .sha256 = "45b5262ef4d4d1e70d21683b2ef4c1b765b067f34a13e2aa57d5f92bb02382a9" },
};

fn fetchArmZig(b: *std.Build) *std.Build.Step {
    const dir = fromRoot(b, "build/zig");
    const verify = fetchPinned(b, dir, zig_arm_archive, struct {
        fn url(bb: *std.Build, f: @TypeOf(zig_arm_archive[0])) []const u8 {
            return bb.fmt("https://ziglang.org/download/{s}/{s}", .{ zig_version, f.name });
        }
    }.url);
    const tools = requireTools(b, &.{ "tar:tar", "xz:xz-utils" });
    const unpack = b.addSystemCommand(&.{
        "sh",
        "-c",
        "test -x \"$2/zig-arm-linux-" ++ zig_version ++ "/zig\" || tar -xJf \"$1\" -C \"$2\"",
        "unpack-zig",
        b.pathJoin(&.{ dir, zig_arm_archive[0].name }),
        dir,
    });
    unpack.step.dependOn(verify);
    unpack.step.dependOn(&tools.step);
    unpack.has_side_effects = true;
    return &unpack.step;
}

/// Where the boot partition ends on the card, in MiB, once init has grown it
/// on the first start: room for both slots to grow several times over
/// (each holds about 5 MB now), as it cannot grow once /data follows it.
/// The image itself is just big enough for its files (slot B is made on
/// the card), laid out so that growing only changes the partition's size.
const boot_partition_mib = 128;

/// The SD card image (zig-out/dazzle.img), and its files in zig-out/boot
/// for copying onto a card by hand. One FAT partition holds, at its root,
/// the firmware's own files and config.txt (which must be there, so there
/// is one copy); and the OS slots. There are no apps: they are installed
/// in setup (or later from Settings) from their archives (zig-out/apps).
///
/// An OS slot holds a whole copy of the system (the kernel, its device
/// trees, the initramfs with everything in /os, and the kernel's command
/// line), and config.txt's os_prefix says which one the firmware starts.
/// The image has slot A, slot-a/; on the first start the system copies it
/// to slot B, slot-b/. An update writes the slot not in use and switches
/// to it. (If a slot's kernel or device tree is missing, the firmware
/// ignores the prefix.)
///
/// /data is the partition the system makes in the rest of the card on the
/// first start, after growing this one.
fn addImage(b: *std.Build, kernel: Kernel, initramfs: std.Build.LazyPath) *std.Build.Step {
    const dir = fromRoot(b, "build/firmware");
    // Download what is missing, then check everything.
    const verify_step = fetchPinned(b, dir, firmware, struct {
        fn url(bb: *std.Build, f: @TypeOf(firmware[0])) []const u8 {
            return bb.fmt("https://raw.githubusercontent.com/raspberrypi/firmware/{s}/boot/{s}", .{ firmware_tag, f.name });
        }
    }.url);

    // Shared: the firmware (the boot ROM and the first stage load these
    // from the root), and config.txt, which picks the slot.
    var boot_files: std.ArrayList(CardFile) = .empty;
    boot_files.appendSlice(b.allocator, &.{
        .{ "bootcode.bin", .{ .cwd_relative = b.pathJoin(&.{ dir, "bootcode.bin" }) } },
        .{ "start.elf", .{ .cwd_relative = b.pathJoin(&.{ dir, "start.elf" }) } },
        .{ "fixup.dat", .{ .cwd_relative = b.pathJoin(&.{ dir, "fixup.dat" }) } },
        .{ "start4.elf", .{ .cwd_relative = b.pathJoin(&.{ dir, "start4.elf" }) } },
        .{ "fixup4.dat", .{ .cwd_relative = b.pathJoin(&.{ dir, "fixup4.dat" }) } },
        .{ "LICENCE.broadcom", .{ .cwd_relative = b.pathJoin(&.{ dir, "LICENCE.broadcom" }) } },
        .{ "config.txt", b.path("boot/config.txt") },
    }) catch @panic("OOM");
    // Slot A: a whole system. Its command line says which slot it is. The
    // system makes slot B, a copy, on the card on the first start.
    b.graph.poisonCache();
    const cmdline = std.mem.trimEnd(u8, std.Io.Dir.cwd().readFileAlloc(b.graph.io, fromRoot(b, "boot/cmdline.txt"), b.allocator, .limited(4096)) catch @panic("cannot read boot/cmdline.txt"), "\n");
    // What system this is: Dazzle's commit and the kernel's, and the later
    // of the times they were made (so a build with a newer kernel is a
    // newer system, offered as an update even without a change to Dazzle).
    // A kernel tree without git history counts as Dazzle's commit alone.
    // Written only when it changes: a file just written is not trusted by
    // the build's cache, and everything made from it (the system's
    // archive, compressed for seconds, and the card's image) would be made
    // again at every build.
    const version_path = fromRoot(b, "build/version");
    const version_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\v=$(k=$(git -C "$1" log -1 --format="%ct %h" 2>/dev/null) || { echo "$2 $3"; exit; }
        \\t=${k% *}; [ "$t" -gt "$2" ] || t=$2
        \\echo "$t $3-${k#* }")
        \\[ "$(cat "$4" 2>/dev/null)" = "$v" ] || echo "$v" > "$4"
        ,
        "version",
        kernel.src,
        b.fmt("{d}", .{gitCommitTime(b)}),
        gitCommit(b),
        version_path,
    });
    version_cmd.step.dependOn(kernel.step);
    version_cmd.has_side_effects = true;
    const version: std.Build.LazyPath = .{ .cwd_relative = version_path };
    var files: std.ArrayList(CardFile) = .empty;
    files.appendSlice(b.allocator, &.{
        // The firmware starts kernel.img on the ARMv6 boards, kernel7.img on
        // the ARMv7 ones (and Pi 4) and kernel8.img on the Pi 5.
        .{ "kernel.img", kernel.armv6(b) },
        .{ "kernel7.img", kernel.armv7(b) },
        .{ "kernel8.img", kernel.arm64(b) },
        .{ "initramfs.cpio", initramfs },
        // What system the slot holds (sys.system.Version).
        .{ "version", version },
    }) catch @panic("OOM");
    // Every board's device tree, and the overlays (the display driver, and
    // the cameras, applied when the firmware finds one).
    for (device_trees) |d| files.append(b.allocator, .{ d, kernel.deviceTree(b, d) }) catch @panic("OOM");
    for (arm64_device_trees) |d| files.append(b.allocator, .{ d, kernel.arm64DeviceTree(b, d) }) catch @panic("OOM");
    for (overlays) |d| files.append(b.allocator, .{ b.fmt("overlays/{s}", .{d}), kernel.overlay(b, d) }) catch @panic("OOM");
    // The firmware takes overlays from the slot's overlays/ (config.txt's
    // os_prefix) only if there is a README there; otherwise it looks in
    // the card's own /overlays/, which there is not, and silently applies
    // none: no vc4 (no display), and no camera.
    files.append(b.allocator, .{ "overlays/README", b.addWriteFiles().add("README", overlays_readme) }) catch @panic("OOM");
    for (files.items) |f| boot_files.append(b.allocator, .{ b.fmt("slot-a/{s}", .{f[0]}), f[1] }) catch @panic("OOM");
    boot_files.append(b.allocator, .{ "slot-a/cmdline.txt", b.addWriteFiles().add("cmdline.txt", b.fmt("{s} dazzle.slot=a\n", .{cmdline})) }) catch @panic("OOM");
    // The same files as an update (zig-out/os: the archive and its
    // manifest, published beside the image; see tools/mkos.zig).
    const os_step = b.step("os", "Build the system as an update (zig-out/os)");
    {
        const xz = requireTools(b, &.{"xz:xz-utils"});
        const pack = b.addRunArtifact(hostTool(b, "mkos"));
        pack.addArg("pack");
        const tar = pack.addOutputFileArg("dazzle-os.tar");
        for (files.items) |f| pack.addPrefixedFileArg(b.fmt("{s}=", .{f[0]}), f[1]);
        pack.step.dependOn(&version_cmd.step);
        const compress = b.addSystemCommand(&.{ "xz", "-9", "-c" });
        compress.step.dependOn(&xz.step);
        compress.addFileArg(tar);
        const archive = compress.captureStdOut(.{ .basename = "dazzle-os.tar.xz" });
        const manifest = b.addRunArtifact(hostTool(b, "mkos"));
        manifest.addArg("manifest");
        manifest.addArg(b.fmt("--key={s}", .{signingKey(b).seed_hex}));
        const json = manifest.addOutputFileArg("os.json");
        manifest.addFileArg(version);
        manifest.step.dependOn(&version_cmd.step);
        manifest.addFileArg(archive);
        os_step.dependOn(&b.addInstallFile(archive, "os/dazzle-os.tar.xz").step);
        os_step.dependOn(&b.addInstallFile(json, "os/os.json").step);
        os_step.dependOn(&b.addInstallFile(b.path("icon.png"), "os/icon.png").step);
    }

    const mkimage = b.addRunArtifact(hostTool(b, "mkimage"));
    mkimage.step.dependOn(verify_step);
    mkimage.step.dependOn(&version_cmd.step);
    const img = mkimage.addOutputFileArg("dazzle.img");
    mkimage.addArg(if (b.option(u32, "image-size", "SD image size in MiB (default: just big enough)")) |mib| b.fmt("{d}", .{mib}) else "auto");
    mkimage.addArg(b.fmt("--grow-to={d}", .{boot_partition_mib}));
    const image_step = b.step("image", "Build everything into an SD card image: zig-out/dazzle.img (and its files in zig-out/boot)");
    for (boot_files.items) |f| {
        mkimage.addPrefixedFileArg(b.fmt("{s}=", .{f[0]}), f[1]);
        const install = b.addInstallFile(f[1], b.fmt("boot/{s}", .{f[0]}));
        install.step.dependOn(&mkimage.step);
        image_step.dependOn(&install.step);
    }
    image_step.dependOn(&b.addInstallFile(img, "dazzle.img").step);
    image_step.dependOn(os_step);
    return image_step;
}

/// The boards Dazzle runs on, as QEMU emulates them.
const QemuBoard = enum {
    zero,
    @"pi1a+",
    pi2b,
    pi3b,
    @"pi3a+",

    /// QEMU's machine.
    fn machine(q: QemuBoard) []const u8 {
        return switch (q) {
            .zero => "raspi0",
            .@"pi1a+" => "raspi1ap",
            .pi2b => "raspi2b",
            .pi3b => "raspi3b",
            .@"pi3a+" => "raspi3ap",
        };
    }

    /// The device tree the firmware would load.
    fn dtb(q: QemuBoard) []const u8 {
        return switch (q) {
            .zero => "bcm2708-rpi-zero.dtb",
            .@"pi1a+" => "bcm2708-rpi-b-plus.dtb",
            .pi2b => "bcm2709-rpi-2-b.dtb",
            .pi3b => "bcm2710-rpi-3-b.dtb",
            .@"pi3a+" => "bcm2710-rpi-3-b-plus.dtb",
        };
    }

    fn armv7(q: QemuBoard) bool {
        return q == .pi2b or q == .pi3b or q == .@"pi3a+";
    }

    /// QEMU starts its Pi 3s in AArch64.
    fn aarch64(q: QemuBoard) bool {
        return q == .pi3b or q == .@"pi3a+";
    }
};

/// Boots the kernel and initramfs in one of QEMU's Raspberry Pi machines
/// (-Dqemu-board, the Zero's by default), with the log server on
/// http://localhost:8080 (-Dhttp-port to change).
fn addQemu(b: *std.Build, kernel: Kernel, initramfs: std.Build.LazyPath) void {
    const board = b.option(QemuBoard, "qemu-board", "The board QEMU emulates: zero (default), pi1a+, pi2b, pi3b or pi3a+") orelse .zero;
    const program = if (board.aarch64()) "qemu-system-aarch64" else "qemu-system-arm";
    const tools = requireTools(b, &.{ b.fmt("{s}:{s}", .{ program, program }), "fdtput:device-tree-compiler" });
    // QEMU lacks the power management block the watchdog driver waits for.
    const dtb = fromRoot(b, b.fmt("build/qemu-{s}", .{board.dtb()}));
    const copy = b.addSystemCommand(&.{"cp"});
    copy.addFileArg(kernel.deviceTree(b, board.dtb()));
    copy.addArg(dtb);
    copy.step.dependOn(kernel.step);
    copy.step.dependOn(&tools.step);
    copy.has_side_effects = true;
    const patch = b.addSystemCommand(&.{ "fdtput", "-t", "s", dtb, "/soc/watchdog@7e100000", "status", "disabled" });
    patch.step.dependOn(&copy.step);
    patch.has_side_effects = true;
    // QEMU's USB controller works with mainline's driver (dwc2), not the
    // Raspberry Pi kernel's own (dwc_otg), as `dtoverlay=dwc2` chooses.
    const usb = b.addSystemCommand(&.{ "fdtput", "-t", "s", dtb, "/soc/usb@7e980000", "compatible", "brcm,bcm2835-usb" });
    usb.step.dependOn(&patch.step);
    usb.has_side_effects = true;
    const port = b.option(u16, "http-port", "Host port for the HTTP log server when running in QEMU (default 8080)") orelse 8080;
    const qemu = b.addSystemCommand(&.{ program, "-M", board.machine(), "-kernel" });
    const zimage = if (board.armv7()) kernel.armv7(b) else kernel.armv6(b);
    if (board.aarch64()) {
        // A stub switches to AArch32 for the 32-bit kernel. (QEMU's spin
        // loop for the other cores is AArch64 too, so the kernel brings up
        // only the first.)
        const stub = b.addRunArtifact(hostTool(b, "aarch32boot"));
        stub.addFileArg(zimage);
        stub.step.dependOn(kernel.step);
        qemu.addFileArg(stub.addOutputFileArg("zImage-aarch64"));
    } else qemu.addFileArg(zimage);
    qemu.addArgs(&.{ "-dtb", dtb, "-initrd" });
    qemu.addFileArg(initramfs);
    qemu.addArgs(&.{
        // The log server is on (there is no card to keep the setting on).
        "-append",  "printk.devkmsg=on rdinit=/os/init firmware_class.path=/os/firmware dazzle.log_server=on",
        "-device",  "usb-net,netdev=net0",
        "-netdev",  b.fmt("user,id=net0,hostfwd=tcp:127.0.0.1:{d}-:80", .{port}),
        "-display", "none",
    });
    // The console: the PL011, the first serial port; on the Pi 3s the mini
    // UART, the second (the PL011 is the Bluetooth chip's there).
    if (board.aarch64()) qemu.addArgs(&.{ "-serial", "null", "-serial", "mon:stdio" }) else qemu.addArgs(&.{ "-serial", "mon:stdio" });
    qemu.addPassthruArgs();
    qemu.step.dependOn(&usb.step);
    qemu.stdio = .inherit;
    qemu.has_side_effects = true;
    const step = b.step("qemu", "Boot the kernel and initramfs in QEMU (-Dqemu-board for another board; arguments after -- go to QEMU)");
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
    // The Pi programs are optimized for speed unless told otherwise (a
    // Debug build is far too slow on a Pi Zero); host tests default to
    // Debug, for their safety checks.
    const explicit_optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default: fast for the Pi, debug for host tests)");
    const optimize: std.builtin.Optimize = explicit_optimize orelse switch (b.graph.release_mode) {
        .off, .any, .fast => .fast,
        .small => .small,
        .safe => .safe,
    };
    const test_optimize = explicit_optimize orelse .debug;

    const shaders = addShaders(b);
    const icon_font = addIconFont(b);
    const map_data = addMapData(b);
    const pi = addModules(b, target, optimize, shaders, icon_font);
    // init runs as root; the shell and the apps (its Wayland clients) run
    // as the unprivileged Dazzle user.
    const init_exe = b.addExecutable(.{
        .name = "dazzle-init",
        .root_module = addProgramModule(b, "src/init/main.zig", target, optimize, pi, shaders, true),
    });
    const install_init = b.addInstallArtifact(init_exe, .{});
    const demo_module = addProgramModule(b, "src/apps/demo/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, demo_module, pi, target, optimize, "src/apps/demo");
    const demo_exe = b.addExecutable(.{
        .name = "dazzle-demo",
        .root_module = demo_module,
    });
    const install_demo = b.addInstallArtifact(demo_exe, .{});
    const settings_module = addProgramModule(b, "src/apps/settings/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, settings_module, pi, target, optimize, "src/apps/settings");
    addBackgroundThumbnails(b, settings_module);
    const settings_exe = b.addExecutable(.{
        .name = "dazzle-settings",
        .root_module = settings_module,
    });
    const install_settings = b.addInstallArtifact(settings_exe, .{});
    const files_module = addProgramModule(b, "src/apps/files/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, files_module, pi, target, optimize, "src/apps/files");
    const files_exe = b.addExecutable(.{
        .name = "dazzle-files",
        .root_module = files_module,
    });
    const install_files = b.addInstallArtifact(files_exe, .{});
    const camera_module = addProgramModule(b, "src/apps/camera/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, camera_module, pi, target, optimize, "src/apps/camera");
    const camera_exe = b.addExecutable(.{
        .name = "dazzle-camera",
        .root_module = camera_module,
    });
    const install_camera = b.addInstallArtifact(camera_exe, .{});
    const text_editor_module = addProgramModule(b, "src/apps/text_editor/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, text_editor_module, pi, target, optimize, "src/apps/text_editor");
    const text_editor_exe = b.addExecutable(.{
        .name = "dazzle-text-editor",
        .root_module = text_editor_module,
    });
    const install_text_editor = b.addInstallArtifact(text_editor_exe, .{});
    const logger_module = addProgramModule(b, "src/apps/logger/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, logger_module, pi, target, optimize, "src/apps/logger");
    const logger_exe = b.addExecutable(.{
        .name = "dazzle-data-logger",
        .root_module = logger_module,
    });
    const install_logger = b.addInstallArtifact(logger_exe, .{});
    const chat_module = addProgramModule(b, "src/apps/chat/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, chat_module, pi, target, optimize, "src/apps/chat");
    const chat_exe = b.addExecutable(.{
        .name = "dazzle-chat",
        .root_module = chat_module,
    });
    const install_chat = b.addInstallArtifact(chat_exe, .{});
    const blocks_module = addProgramModule(b, "src/apps/blocks/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, blocks_module, pi, target, optimize, "src/apps/blocks");
    const blocks_exe = b.addExecutable(.{
        .name = "dazzle-blocks",
        .root_module = blocks_module,
    });
    const install_blocks = b.addInstallArtifact(blocks_exe, .{});
    const setup_module = addProgramModule(b, "src/apps/setup/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, setup_module, pi, target, optimize, "src/apps/setup");
    const setup_exe = b.addExecutable(.{
        .name = "dazzle-setup",
        .root_module = setup_module,
    });
    const install_setup = b.addInstallArtifact(setup_exe, .{});
    const shell_exe = b.addExecutable(.{
        .name = "dazzle-shell",
        .root_module = addProgramModule(b, "src/shell/main.zig", target, optimize, pi, shaders, true),
    });
    const install_shell = b.addInstallArtifact(shell_exe, .{});
    const maps_mod = addProgramModule(b, "src/apps/maps/main.zig", target, optimize, pi, shaders, true);
    maps_mod.addImport("map_data", b.createModule(.{ .root_source_file = map_data, .target = target, .optimize = optimize }));
    _ = addKete(b, maps_mod, pi, target, optimize, "src/apps/maps");
    const maps_exe = b.addExecutable(.{
        .name = "dazzle-maps",
        .root_module = maps_mod,
    });
    const install_maps = b.addInstallArtifact(maps_exe, .{});
    const terminal_module = addProgramModule(b, "src/apps/terminal/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, terminal_module, pi, target, optimize, "src/apps/terminal");
    const terminal_exe = b.addExecutable(.{
        .name = "dazzle-terminal",
        .root_module = terminal_module,
    });
    const install_terminal = b.addInstallArtifact(terminal_exe, .{});
    const develop_module = addProgramModule(b, "src/apps/develop/main.zig", target, optimize, pi, shaders, true);
    _ = addKete(b, develop_module, pi, target, optimize, "src/apps/develop");
    const develop_exe = b.addExecutable(.{
        .name = "dazzle-develop",
        .root_module = develop_module,
    });
    const install_develop = b.addInstallArtifact(develop_exe, .{});

    // Host tool that packs the init binary into a cpio initramfs.
    const mkinitramfs = b.addExecutable(.{
        .name = "mkinitramfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkinitramfs.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const run_mkinitramfs = b.addRunArtifact(mkinitramfs);
    const initramfs = run_mkinitramfs.addOutputFileArg("initramfs.cpio");
    run_mkinitramfs.addArtifactArg(init_exe);
    run_mkinitramfs.addArtifactArg(shell_exe);
    run_mkinitramfs.addFileArg(b.path("fonts/FiraSans-Regular.ttf"));
    run_mkinitramfs.addFileArg(b.path("fonts/OFL.txt"));
    run_mkinitramfs.addPrefixedFileArg("--file=os/fonts/TwemojiMozilla.ttf=", b.path("fonts/TwemojiMozilla.ttf"));
    run_mkinitramfs.addPrefixedFileArg("--file=os/fonts/TwemojiMozilla-LICENSE.txt=", b.path("fonts/TwemojiMozilla-LICENSE.txt"));
    // The third-party software built into the system's programs, and its
    // licences (each app has its own: see below).
    addNotices(b, run_mkinitramfs, "os/NOTICES", "Dazzle's system programs", &.{"MaterialIcons"});
    // The Wi-Fi chips' firmware, for the kernel to load.
    run_mkinitramfs.step.dependOn(fetchWifiFirmware(b));
    for (wifi_firmware) |f| {
        run_mkinitramfs.addArg(b.fmt("--file=os/firmware/brcm/{s}={s}", .{ f.name, b.pathJoin(&.{ fromRoot(b, "build/firmware/wifi"), f.name }) }));
    }
    run_mkinitramfs.addPrefixedFileArg("--file=os/firmware/brcm/LICENCE.cypress=", b.path("firmware/LICENCE.cypress"));
    // The shell's own apps, beside it in /shell (they cannot be removed).
    run_mkinitramfs.addPrefixedArtifactArg("--shell=", settings_exe);
    run_mkinitramfs.addPrefixedArtifactArg("--shell=", setup_exe);
    // The built-in desktop backgrounds, ready for the GPU, and who took
    // them.
    for (builtin_backgrounds.all, addBackgrounds(b)) |bg, r| {
        run_mkinitramfs.addPrefixedFileArg(b.fmt("--file=os/backgrounds/{s}.etc1=", .{bg.file}), r.etc1);
    }
    run_mkinitramfs.addPrefixedFileArg("--file=os/backgrounds/CREDITS.txt=", b.path("backgrounds/CREDITS.txt"));
    // Dazzle's icon in /os/icon.png, and the dock's icons beside each program.
    run_mkinitramfs.addPrefixedFileArg("--file=os/icon.png=", b.path("icon.png"));
    addAppIcon(b, run_mkinitramfs, "os/shell/dazzle-settings", .settings);
    // The certificates of the authorities HTTPS trusts, for setup and
    // Settings to download apps and updates.
    run_mkinitramfs.step.dependOn(fetchCaCertificates(b));
    run_mkinitramfs.addArg(b.fmt("--file=os/certs/ca-certificates.pem={s}", .{b.pathJoin(&.{ fromRoot(b, "build/firmware/certs"), ca_certificates[0].name })}));
    // The apps, each in /data/apps/<name> and listed in the shell's dock,
    // are not part of the system or the image: each is an archive to
    // download and install, in setup or from Settings (zig-out/apps/, with
    // the catalogue).
    const zig_root = fromRoot(b, "build/zig/zig-arm-linux-" ++ zig_version);
    const apps = [_]App{
        .{ .exe = demo_exe, .icon = .view_in_ar, .title = "Demo" },
        .{ .exe = files_exe, .icon = .folder, .title = "Files", .description = "Browse your files" },
        .{ .exe = camera_exe, .icon = .photo_camera, .title = "Camera", .description = "Take photos and videos" },
        .{ .exe = text_editor_exe, .icon = .edit_note, .title = "Text Editor", .description = "Edit text files", .handles = &.{"text/plain"} },
        .{ .exe = blocks_exe, .icon = .landscape, .title = "Blocks", .description = "Build worlds out of blocks" },
        .{ .exe = logger_exe, .icon = .show_chart, .title = "Data Logger", .description = "Record inputs from the GPIO pins" },
        .{ .exe = chat_exe, .icon = .chat, .title = "Chat", .description = "Chat with others on your network in rooms" },
        .{ .exe = maps_exe, .icon = .public, .title = "Maps", .description = "Explore the Earth on a 3D globe" },
        .{ .exe = terminal_exe, .icon = .terminal, .title = "Terminal", .description = "Run command-line tools" },
        .{
            .exe = develop_exe,
            .icon = .code,
            .title = "Develop",
            .description = "Write and run Zig programs",
            .notices = &.{ "MaterialIcons", "Zig" },
            .extra_step = fetchArmZig(b),
            .extra_args = &.{
                b.fmt("--exe=zig/zig={s}/zig", .{zig_root}),
                b.fmt("zig/LICENSE={s}/LICENSE", .{zig_root}),
                "--exclude=zig/lib/libc",
                "--exclude=zig/lib/libcxx",
                "--exclude=zig/lib/libcxxabi",
                "--exclude=zig/lib/libunwind",
                "--exclude=zig/lib/tsan",
                b.fmt("--dir=zig/lib={s}/lib", .{zig_root}),
            },
        },
    };
    const apps_step = b.step("apps", "Build the apps' archives and their catalogue (zig-out/apps)");
    apps_step.dependOn(addAppArchives(b, &apps));
    b.getInstallStep().dependOn(apps_step);
    const install_initramfs = b.addInstallFile(initramfs, "initramfs.cpio");
    const programs_step = b.step("programs", "Build just the programs (zig-out/bin) and zig-out/initramfs.cpio");
    for ([_]*std.Build.Step{ &install_init.step, &install_demo.step, &install_settings.step, &install_files.step, &install_camera.step, &install_text_editor.step, &install_logger.step, &install_chat.step, &install_blocks.step, &install_maps.step, &install_terminal.step, &install_develop.step, &install_setup.step, &install_shell.step, &install_initramfs.step }) |st| {
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
    const host = addModules(b, b.graph.host, test_optimize, shaders, icon_font);
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
    for ([_]*std.Build.Module{ host.font, host.gfx }) |m| {
        m.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
        m.addAnonymousImport("TwemojiMozilla.ttf", .{ .root_source_file = b.path("fonts/TwemojiMozilla.ttf") });
    }
    const test_step = b.step("test", "Run unit tests on the host");
    // The shell's tests draw text (the dock's tooltips) in the system font.
    const host_shell = addProgramModule(b, "src/shell/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_shell.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    // The demo's layout is tested with its real font.
    const host_demo = addProgramModule(b, "src/apps/demo/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_demo.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_demo, host, b.graph.host, test_optimize, "src/apps/demo");
    const host_settings = addProgramModule(b, "src/apps/settings/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_settings.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_settings, host, b.graph.host, test_optimize, "src/apps/settings");
    addBackgroundThumbnails(b, host_settings);
    const host_files = addProgramModule(b, "src/apps/files/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_files.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_files, host, b.graph.host, test_optimize, "src/apps/files");
    const host_camera = addProgramModule(b, "src/apps/camera/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_camera.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_camera, host, b.graph.host, test_optimize, "src/apps/camera");
    const host_text_editor = addProgramModule(b, "src/apps/text_editor/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_text_editor.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    // Kete's frames, drawn with Dazzle's shaders in the QPU simulator.
    const host_kete_vc4 = addKete(b, host_text_editor, host, b.graph.host, test_optimize, "src/apps/text_editor");
    host_kete_vc4.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    const host_blocks = addProgramModule(b, "src/apps/blocks/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_blocks.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_blocks, host, b.graph.host, test_optimize, "src/apps/blocks");
    const host_logger = addProgramModule(b, "src/apps/logger/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_logger.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_logger, host, b.graph.host, test_optimize, "src/apps/logger");
    const host_chat = addProgramModule(b, "src/apps/chat/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_chat.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_chat, host, b.graph.host, test_optimize, "src/apps/chat");
    const host_setup = addProgramModule(b, "src/apps/setup/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_setup.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_setup, host, b.graph.host, test_optimize, "src/apps/setup");
    const host_maps = addProgramModule(b, "src/apps/maps/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_maps.addImport("map_data", b.createModule(.{ .root_source_file = map_data, .target = b.graph.host, .optimize = test_optimize }));
    host_maps.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_maps, host, b.graph.host, test_optimize, "src/apps/maps");
    const host_terminal = addProgramModule(b, "src/apps/terminal/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_terminal.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_terminal, host, b.graph.host, test_optimize, "src/apps/terminal");
    const host_develop = addProgramModule(b, "src/apps/develop/main.zig", b.graph.host, test_optimize, host, shaders, false);
    host_develop.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    _ = addKete(b, host_develop, host, b.graph.host, test_optimize, "src/apps/develop");
    for ([_]*std.Build.Module{
        host.sys,
        host.vc4,
        host.shader,
        host.app,
        host.gfx,
        host.appearance,
        host.font,
        host.icons,
        host.wayland,
        host.store,
        host.locale,
        host.video,
        host.audio,
        addProgramModule(b, "src/init/main.zig", b.graph.host, test_optimize, host, shaders, false),
        host_demo,
        host_kete_vc4,
        host_settings,
        host_files,
        host_camera,
        host_text_editor,
        host_logger,
        host_chat,
        host_blocks,
        host_setup,
        host_maps,
        host_terminal,
        host_develop,
        host_shell,
    }) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hostTool(b, "mkapp").root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hostTool(b, "mkimage").root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hostTool(b, "mkmap").root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hostTool(b, "mkos").root_module })).step);

    const serve_exe = b.addExecutable(.{
        .name = "dazzle-serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{
                .name = "tls_server",
                .module = b.createModule(.{
                    .root_source_file = b.path("src/store/tls_server.zig"),
                    .target = b.graph.host,
                    .optimize = test_optimize,
                }),
            }},
        }),
    });
    const install_serve = b.addInstallArtifact(serve_exe, .{});
    programs_step.dependOn(&install_serve.step);
    b.getInstallStep().dependOn(&install_serve.step);
    const run_serve = b.addRunArtifact(serve_exe);
    run_serve.step.dependOn(&install_serve.step);
    run_serve.addPassthruArgs();
    run_serve.stdio = .inherit;
    run_serve.has_side_effects = true;
    const serve_step = b.step("serve", "Serve zig-out/os and zig-out/apps over HTTPS for testing (arguments after -- go to dazzle-serve)");
    serve_step.dependOn(&run_serve.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = serve_exe.root_module })).step);

    const shaders_step = b.step("shaders", "Compile the shader programs (zig-out/shaders)");
    for (shaders) |s| shaders_step.dependOn(&b.addInstallFile(s.program, b.fmt("shaders/{s}.shader", .{s.name})).step);
}
