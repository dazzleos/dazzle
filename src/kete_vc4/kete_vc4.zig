//! Kete on Dazzle: kete's apps in Dazzle's windows, drawn by its GPU.
//!
//! Kete is built without window or render backends of its own; this gives
//! it Dazzle's (`window.zig`: windows on Dazzle's shell, and their input)
//! and the vc4 renderer (`renderer.zig`: kete's canvases drawn with
//! Dazzle's shaders, straight into the windows' buffers).
//!
//!     var host: kete_vc4.Host = undefined;
//!     try host.init(gpa, io, environ, .{ .app_id = "dazzle-example" });
//!     defer host.deinit();
//!     _ = try host.app.openWindow(.{ .title = "Example", .root = .of(&root) });
//!     while (try host.step(std.math.maxInt(u64))) {}
//!
//! `Host.step` is kete's step, following the system's theme as it is
//! changed in Settings; an app with things of its own to do between steps
//! (a socket, a thread's results) has its files wake the loop with
//! `Host.wakeOn`, and `Host.redraw` once its state has changed.

const std = @import("std");
const kete = @import("kete");
const vc4 = @import("vc4");
const sys = @import("sys");
const app = @import("app");
const appearance = @import("appearance");
const dazzle_font = @import("font");
const locale = @import("locale");
const linux = std.os.linux;

pub const renderer = @import("renderer.zig");
pub const window = @import("window.zig");
/// `fmt` (a format, in British English) in the system's language (see
/// `locale.text`), with `args`, in the frame's arena: `cx.fmt`, translated.
pub fn textf(cx: *kete.BuildContext, comptime fmt: []const u8, args: anytype) []const u8 {
    return switch (locale.current) {
        inline else => |l| cx.fmt(comptime locale.textIn(l, fmt), args),
    };
}

/// Choosing a time zone (setup's, and Settings').
pub const TimeZonePicker = @import("timezone_picker.zig").TimeZonePicker;
/// Choosing a language, by searching (setup's, and Settings').
pub const LanguagePicker = @import("language_picker.zig").LanguagePicker;
pub const Renderer = renderer.Renderer;
pub const Window = window.Window;
pub const Display = window.Display;
/// The icons the apps' catalogue names, kept in kete's icon font.
pub const app_icons = @import("app_icons.zig").icons;

/// The GPU, the display and renderer kete is given, and the kete app.
/// Keep it where it is once `init`: they point at each other.
pub const Host = struct {
    dev: vc4.Device,
    display: Display,
    renderer: Renderer,
    app: *kete.App,
    theme_watch: ThemeWatch,

    pub const Options = struct {
        /// The name the shell knows the app by.
        app_id: ?[]const u8 = null,
        on_last_window_closed: kete.App.OnLastWindowClosed = .quit,
        /// Who draws the title bar: kete, or no one (an app with the whole
        /// screen, as setup is).
        decorations: kete.window.WindowDecorations = .toolkit,
        /// Records a frame while the GPU renders the one before, rather
        /// than waiting for it: for an app that draws a frame after another
        /// (a game), at the cost of a frame's delay and a buffer's memory.
        pipelined: bool = false,
    };

    /// Opens the GPU, and makes a kete app whose windows are opened on the
    /// shell in `environ` and drawn by the GPU, in the system's theme and
    /// fonts (kete has none of its own: they are in /os/fonts).
    pub fn init(h: *Host, gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !void {
        const name = options.app_id orelse "app";
        h.dev = vc4.device.openRender() catch |err| {
            sys.print(sys.log_error ++ "{s}: no GPU ({s})\n", .{ name, @errorName(err) });
            return err;
        };
        errdefer h.dev.close();
        const gpu: app.Gpu = .device(&h.dev);
        h.display = .{ .gpa = gpa, .io = io, .gpu = gpu, .environ = environ, .app_id = options.app_id, .decorations = options.decorations };
        h.renderer = try Renderer.init(gpa, h.dev, gpu);
        errdefer h.renderer.deinit();
        if (options.pipelined) _ = h.renderer.setPipelined(true);
        h.display.renderer = &h.renderer;
        var font_buf: [256]u8 = undefined;
        var emoji_buf: [256]u8 = undefined;
        var cjk_buf: [256]u8 = undefined;
        var arabic_buf: [256]u8 = undefined;
        h.app = try kete.App.init(gpa, io, environ, .{
            .app_id = options.app_id,
            .font_path = sys.fontFile(&font_buf, dazzle_font.default_font_file),
            .emoji_font_path = sys.fontFile(&emoji_buf, dazzle_font.emoji_font_file),
            // Chinese, Japanese, Arabic, and other scripts Fira Sans lacks.
            .fallback_font_paths = &.{ sys.fontFile(&cjk_buf, dazzle_font.cjk_font_file), sys.fontFile(&arabic_buf, dazzle_font.arabic_font_file) },
            .display = h.display.display(),
            .on_last_window_closed = options.on_last_window_closed,
        });
        h.app.shared.attachRenderer(h.renderer.renderer(), false);
        followThemeOf(h);
        h.theme_watch = .init();
        if (h.theme_watch.fd) |fd| _ = h.display.wakeOn(fd, true);
    }

    pub fn deinit(h: *Host) void {
        h.theme_watch.deinit();
        h.app.deinit();
        h.renderer.deinit();
        h.dev.close();
    }

    /// kete's step (see `kete.App.step`), and the system's theme taken if
    /// it changed. False when the app should end.
    pub fn step(h: *Host, idle_timeout_ns: u64) !bool {
        // Arabic: laid out right to left.
        h.app.setRightToLeft(locale.current.rightToLeft());
        const going = try h.app.step(idle_timeout_ns);
        if (h.theme_watch.changed()) followThemeOf(h);
        return going;
    }

    /// Wakes `step` when `fd` can be read (or no longer, `on` false).
    pub fn wakeOn(h: *Host, fd: linux.fd_t, on: bool) void {
        if (!h.display.wakeOn(fd, on)) sys.print(sys.log_warning ++ "kete_vc4: too many files to wake for\n", .{});
    }

    /// Draws the windows again (the app's state changed).
    pub fn redraw(h: *Host) void {
        for (h.app.windows.items) |w| if (!w.isClosed()) {
            w.dirty = true;
        };
    }
};

/// Notices the appearance settings being written (in Settings), by
/// watching their directory.
const ThemeWatch = struct {
    fd: ?linux.fd_t,

    const name = std.fs.path.basename(appearance.settings_file);

    fn init() ThemeWatch {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return .{ .fd = null };
        const fd: linux.fd_t = @intCast(rc);
        const dir: [*:0]const u8 = sys.system.apps_dir;
        if (linux.errno(linux.inotify_add_watch(fd, dir, linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.ONLYDIR)) != .SUCCESS) {
            sys.close(fd);
            return .{ .fd = null };
        }
        return .{ .fd = fd };
    }

    fn deinit(w: *ThemeWatch) void {
        if (w.fd) |fd| sys.close(fd);
        w.fd = null;
    }

    /// Whether the settings were written since the last call.
    fn changed(w: *ThemeWatch) bool {
        const fd = w.fd orelse return false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var written = false;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return written;
            var at: usize = 0;
            while (at + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *align(1) const linux.inotify_event = @ptrCast(&buf[at]);
                const step_len = @sizeOf(linux.inotify_event) + ev.len;
                if (at + step_len > rc) break;
                const ev_name = std.mem.sliceTo(buf[at + @sizeOf(linux.inotify_event) .. at + step_len], 0);
                at += step_len;
                if (std.mem.eql(u8, ev_name, name)) written = true;
            }
        }
    }
};

/// Dazzle's appearance setting, as kete's theme (and the windows'
/// borders' colour).
fn followThemeOf(h: *Host) void {
    const mode = themeMode(appearance.loadSettings().theme);
    h.app.setTheme(mode);
    h.renderer.border_color = mode.scheme().outline_variant;
}

/// Dazzle's appearance setting, as kete's theme.
pub fn themeMode(m: appearance.Mode) kete.ui.theme.ThemeMode {
    return switch (m) {
        inline else => |tag| @field(kete.ui.theme.ThemeMode, @tagName(tag)),
    };
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const dazzle_gfx = @import("gfx");

/// Some of kete's widgets: text, icons, buttons and selection controls.
const Sample = struct {
    pub fn build(_: *const Sample, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.Align.center(cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 12,
            .children = cx.makeAll(.{
                kete.Text{ .text = "Hello from kete on Dazzle!" },
                kete.Row{
                    .fill = false,
                    .spacing = 12,
                    .children = cx.makeAll(.{
                        kete.OutlinedButton{ .icon = .remove },
                        kete.FilledButton{ .icon = .add, .label = "Add" },
                    }),
                },
                kete.SwitchRow{ .label = "Switch", .value = true },
                kete.Checkbox{ .value = true },
                kete.SizedBox{ .width = 200, .child = cx.make(kete.Slider{ .value = 0.5 }) },
            }),
        })));
    }
};

test "kete's frames look the same drawn by Dazzle's shaders as by kete's software renderer" {
    const w = 320;
    const h = 240;
    const f = try kete.font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const wui = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer wui.destroy();
    wui.frame(w, h, 0, Sample{});
    const clear = wui.theme.surface.toArgb();

    const software = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(software);
    const shaded = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(shaded);
    @memset(software, clear);
    @memset(shaded, clear);
    const programs = dazzle_gfx.preview.Programs.load();
    var canvases: usize = 0;
    for (wui.segments.items[0..wui.main_segments]) |s| switch (s) {
        .canvas => |c| {
            canvases += 1;
            try kete.gfx.software.render(c, .{ .pixels = software, .width = w, .height = h });
            try dazzle_gfx.preview.render(c, &programs, .{ .pixels = shaded, .width = w, .height = h });
        },
        .gpu => {},
    };
    try testing.expect(canvases > 0);

    // Something was drawn, and the two agree, give or take each one's
    // rounding at the edges of shapes and glyphs.
    var drawn: usize = 0;
    var differ: usize = 0;
    for (software, shaded) |a, b| {
        if (a != clear) drawn += 1;
        if (channelDistance(a, b) > 48) differ += 1;
    }
    try testing.expect(drawn > 1000);
    if (differ * 100 > drawn) {
        std.debug.print("{d} of {d} drawn pixels differ\n", .{ differ, drawn });
        return error.TestUnexpectedResult;
    }
}

fn channelDistance(a: u32, b: u32) u32 {
    var most: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const x: i32 = @intCast(a >> shift & 0xff);
        const y: i32 = @intCast(b >> shift & 0xff);
        most = @max(most, @abs(x - y));
    }
    return most;
}

test {
    _ = @import("timezone_picker.zig");
    _ = @import("language_picker.zig");
}
