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
//!     try host.app.run();

const std = @import("std");
const kete = @import("kete");
const vc4 = @import("vc4");
const sys = @import("sys");
const app = @import("app");
const ui = @import("ui");

pub const renderer = @import("renderer.zig");
pub const window = @import("window.zig");
pub const Renderer = renderer.Renderer;
pub const Window = window.Window;
pub const Display = window.Display;

/// The GPU, the display and renderer kete is given, and the kete app.
/// Keep it where it is once `init`: they point at each other.
pub const Host = struct {
    dev: vc4.Device,
    display: Display,
    renderer: Renderer,
    app: *kete.App,

    pub const Options = struct {
        /// The name the shell knows the app by.
        app_id: ?[]const u8 = null,
        on_last_window_closed: kete.App.OnLastWindowClosed = .quit,
    };

    /// Opens the GPU, and makes a kete app whose windows are opened on the
    /// shell in `environ` and drawn by the GPU, in the system's theme.
    pub fn init(h: *Host, gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !void {
        const name = options.app_id orelse "app";
        h.dev = vc4.device.openRender() catch |err| {
            sys.print(sys.log_error ++ "{s}: no GPU ({s})\n", .{ name, @errorName(err) });
            return err;
        };
        errdefer h.dev.close();
        const gpu: app.Gpu = .device(&h.dev);
        h.display = .{ .gpa = gpa, .gpu = gpu, .environ = environ, .app_id = options.app_id };
        h.renderer = try Renderer.init(gpa, h.dev, gpu);
        errdefer h.renderer.deinit();
        h.app = try kete.App.init(gpa, io, environ, .{
            .app_id = options.app_id,
            .display = h.display.display(),
            .on_last_window_closed = options.on_last_window_closed,
        });
        h.app.shared.attachRenderer(h.renderer.renderer(), false);
        h.app.setTheme(themeMode(ui.theme.loadSettings().theme));
    }

    pub fn deinit(h: *Host) void {
        h.app.deinit();
        h.renderer.deinit();
        h.dev.close();
    }
};

/// Dazzle's appearance setting, as kete's theme.
fn themeMode(m: ui.theme.Mode) kete.ui.theme.ThemeMode {
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
    const f = try kete.font.Font.init(kete.font.default_font_data);
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
