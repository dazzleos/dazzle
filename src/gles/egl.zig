//! EGL 1.4 for Stardust, with one configuration (8-bit RGBA with a 24-bit
//! depth buffer) and two platforms:
//!
//! * Wayland: eglGetDisplay(wl_display), where the native display is a
//!   `*wayland.client.Display`, and window surfaces made from a
//!   `wl_egl_window` (see egl_wayland.zig). Rendering goes into buffers
//!   shared with the compositor; this is how apps run under stardust-shell.
//! * The screen itself: eglGetDisplay(EGL_DEFAULT_DISPLAY) opens the GPU
//!   and the first connected output, and a window surface is the whole
//!   screen, double-buffered with page flips. The app must be the only one
//!   using the display (no compositor).
//!
//! Entry points are exported with the C ABI under their standard names. A
//! typical program:
//!
//!     const dpy = eglGetDisplay(wl_display);
//!     _ = eglInitialize(dpy, null, null);
//!     var config: EGLConfig = null;
//!     var n: EGLint = 0;
//!     _ = eglChooseConfig(dpy, &attribs, &config, 1, &n);
//!     const window = wl_egl_window_create(&wl_surface, width, height);
//!     const surface = eglCreateWindowSurface(dpy, config, @intFromPtr(window), null);
//!     const ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, &.{ EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE });
//!     _ = eglMakeCurrent(dpy, surface, surface, ctx);
//!     // ... GL calls, then eglSwapBuffers(dpy, surface) once per frame

const std = @import("std");
const sys = @import("sys");
const vc4 = @import("vc4");
const context = @import("context.zig");
pub const egl_wayland = @import("egl_wayland.zig");
const gl = @import("gl.zig");

const drm = vc4.drm;

pub const EGLint = i32;
pub const EGLBoolean = c_uint;
pub const EGLenum = c_uint;
pub const EGLDisplay = ?*anyopaque;
pub const EGLConfig = ?*anyopaque;
pub const EGLSurface = ?*anyopaque;
pub const EGLContext = ?*anyopaque;
pub const EGLNativeDisplayType = ?*anyopaque;
pub const EGLNativeWindowType = usize;
pub const EGLNativePixmapType = usize;
pub const EGLClientBuffer = ?*anyopaque;

pub const EGL_DEFAULT_DISPLAY: EGLNativeDisplayType = null;
pub const EGL_NO_DISPLAY: EGLDisplay = null;
pub const EGL_NO_CONTEXT: EGLContext = null;
pub const EGL_NO_SURFACE: EGLSurface = null;
pub const EGL_FALSE: EGLBoolean = 0;
pub const EGL_TRUE: EGLBoolean = 1;
pub const EGL_DONT_CARE: EGLint = -1;

// Errors.
pub const EGL_SUCCESS: EGLint = 0x3000;
pub const EGL_NOT_INITIALIZED: EGLint = 0x3001;
pub const EGL_BAD_ACCESS: EGLint = 0x3002;
pub const EGL_BAD_ALLOC: EGLint = 0x3003;
pub const EGL_BAD_ATTRIBUTE: EGLint = 0x3004;
pub const EGL_BAD_CONFIG: EGLint = 0x3005;
pub const EGL_BAD_CONTEXT: EGLint = 0x3006;
pub const EGL_BAD_CURRENT_SURFACE: EGLint = 0x3007;
pub const EGL_BAD_DISPLAY: EGLint = 0x3008;
pub const EGL_BAD_MATCH: EGLint = 0x3009;
pub const EGL_BAD_NATIVE_PIXMAP: EGLint = 0x300A;
pub const EGL_BAD_NATIVE_WINDOW: EGLint = 0x300B;
pub const EGL_BAD_PARAMETER: EGLint = 0x300C;
pub const EGL_BAD_SURFACE: EGLint = 0x300D;
pub const EGL_CONTEXT_LOST: EGLint = 0x300E;

// Config attributes.
pub const EGL_BUFFER_SIZE: EGLint = 0x3020;
pub const EGL_ALPHA_SIZE: EGLint = 0x3021;
pub const EGL_BLUE_SIZE: EGLint = 0x3022;
pub const EGL_GREEN_SIZE: EGLint = 0x3023;
pub const EGL_RED_SIZE: EGLint = 0x3024;
pub const EGL_DEPTH_SIZE: EGLint = 0x3025;
pub const EGL_STENCIL_SIZE: EGLint = 0x3026;
pub const EGL_CONFIG_CAVEAT: EGLint = 0x3027;
pub const EGL_CONFIG_ID: EGLint = 0x3028;
pub const EGL_LEVEL: EGLint = 0x3029;
pub const EGL_MAX_PBUFFER_HEIGHT: EGLint = 0x302A;
pub const EGL_MAX_PBUFFER_PIXELS: EGLint = 0x302B;
pub const EGL_MAX_PBUFFER_WIDTH: EGLint = 0x302C;
pub const EGL_NATIVE_RENDERABLE: EGLint = 0x302D;
pub const EGL_NATIVE_VISUAL_ID: EGLint = 0x302E;
pub const EGL_NATIVE_VISUAL_TYPE: EGLint = 0x302F;
pub const EGL_SAMPLES: EGLint = 0x3031;
pub const EGL_SAMPLE_BUFFERS: EGLint = 0x3032;
pub const EGL_SURFACE_TYPE: EGLint = 0x3033;
pub const EGL_TRANSPARENT_TYPE: EGLint = 0x3034;
pub const EGL_TRANSPARENT_BLUE_VALUE: EGLint = 0x3035;
pub const EGL_TRANSPARENT_GREEN_VALUE: EGLint = 0x3036;
pub const EGL_TRANSPARENT_RED_VALUE: EGLint = 0x3037;
pub const EGL_NONE: EGLint = 0x3038;
pub const EGL_BIND_TO_TEXTURE_RGB: EGLint = 0x3039;
pub const EGL_BIND_TO_TEXTURE_RGBA: EGLint = 0x303A;
pub const EGL_MIN_SWAP_INTERVAL: EGLint = 0x303B;
pub const EGL_MAX_SWAP_INTERVAL: EGLint = 0x303C;
pub const EGL_LUMINANCE_SIZE: EGLint = 0x303D;
pub const EGL_ALPHA_MASK_SIZE: EGLint = 0x303E;
pub const EGL_COLOR_BUFFER_TYPE: EGLint = 0x303F;
pub const EGL_RENDERABLE_TYPE: EGLint = 0x3040;
pub const EGL_MATCH_NATIVE_PIXMAP: EGLint = 0x3041;
pub const EGL_CONFORMANT: EGLint = 0x3042;

pub const EGL_SLOW_CONFIG: EGLint = 0x3050;
pub const EGL_NON_CONFORMANT_CONFIG: EGLint = 0x3051;
pub const EGL_TRANSPARENT_RGB: EGLint = 0x3052;
pub const EGL_RGB_BUFFER: EGLint = 0x308E;
pub const EGL_LUMINANCE_BUFFER: EGLint = 0x308F;

pub const EGL_PBUFFER_BIT: EGLint = 0x0001;
pub const EGL_PIXMAP_BIT: EGLint = 0x0002;
pub const EGL_WINDOW_BIT: EGLint = 0x0004;
pub const EGL_OPENGL_ES_BIT: EGLint = 0x0001;
pub const EGL_OPENVG_BIT: EGLint = 0x0002;
pub const EGL_OPENGL_ES2_BIT: EGLint = 0x0004;
pub const EGL_OPENGL_BIT: EGLint = 0x0008;

// Strings.
pub const EGL_VENDOR: EGLint = 0x3053;
pub const EGL_VERSION: EGLint = 0x3054;
pub const EGL_EXTENSIONS: EGLint = 0x3055;
pub const EGL_CLIENT_APIS: EGLint = 0x308D;

// Surface attributes.
pub const EGL_HEIGHT: EGLint = 0x3056;
pub const EGL_WIDTH: EGLint = 0x3057;
pub const EGL_LARGEST_PBUFFER: EGLint = 0x3058;
pub const EGL_RENDER_BUFFER: EGLint = 0x3086;
pub const EGL_SWAP_BEHAVIOR: EGLint = 0x3093;
pub const EGL_BACK_BUFFER: EGLint = 0x3084;
pub const EGL_SINGLE_BUFFER: EGLint = 0x3085;
pub const EGL_BUFFER_DESTROYED: EGLint = 0x3095;
pub const EGL_HORIZONTAL_RESOLUTION: EGLint = 0x3090;
pub const EGL_VERTICAL_RESOLUTION: EGLint = 0x3091;
pub const EGL_PIXEL_ASPECT_RATIO: EGLint = 0x3092;
pub const EGL_UNKNOWN: EGLint = -1;

// Contexts and APIs.
pub const EGL_CONTEXT_CLIENT_TYPE: EGLint = 0x3097;
pub const EGL_CONTEXT_CLIENT_VERSION: EGLint = 0x3098;
pub const EGL_OPENGL_ES_API: EGLenum = 0x30A0;
pub const EGL_OPENVG_API: EGLenum = 0x30A1;
pub const EGL_OPENGL_API: EGLenum = 0x30A2;
pub const EGL_DRAW: EGLint = 0x3059;
pub const EGL_READ: EGLint = 0x305A;

const Display = struct {
    initialized: bool = false,
    dev: vc4.Device = undefined,
    platform: enum { kms, wayland },
    /// The screen, for the KMS platform.
    output: drm.Output = undefined,
    /// The compositor connection, for the Wayland platform.
    wl: egl_wayland.Platform = undefined,
};

/// A window surface: the whole screen (KMS), or a Wayland window.
const Surface = union(enum) {
    kms: vc4.display.Display,
    wayland: *egl_wayland.Surface,

    fn width(s: *const Surface) u32 {
        return switch (s.*) {
            .kms => |d| d.width,
            .wayland => |w| w.width(),
        };
    }

    fn height(s: *const Surface) u32 {
        return switch (s.*) {
            .kms => |d| d.height,
            .wayland => |w| w.height(),
        };
    }

    fn backTarget(s: *Surface) !vc4.render.Target {
        return switch (s.*) {
            .kms => |*d| d.backTarget(),
            .wayland => |w| w.backTarget(),
        };
    }
};

const Context = struct {
    gl: *context.Context,
    /// Whether it has been current before (the viewport is set then).
    bound: bool = false,
};

/// The two platforms' displays: the screen directly (EGL_DEFAULT_DISPLAY),
/// or a Wayland compositor (a native display of a wayland client Display).
var kms_display: Display = .{ .platform = .kms };
var wayland_display: Display = .{ .platform = .wayland };
var current_display: ?*Display = null;
var last_error: EGLint = EGL_SUCCESS;
var current_context: ?*Context = null;
var current_surface: ?*Surface = null;
/// The single configuration's handle.
const the_config: EGLConfig = @ptrFromInt(1);

const gpa = std.heap.page_allocator;

fn fail(e: EGLint) EGLBoolean {
    last_error = e;
    return EGL_FALSE;
}

fn ok() EGLBoolean {
    last_error = EGL_SUCCESS;
    return EGL_TRUE;
}

fn displayHandle(dpy: EGLDisplay) ?*Display {
    if (dpy == @as(EGLDisplay, @ptrCast(&kms_display))) return &kms_display;
    if (dpy == @as(EGLDisplay, @ptrCast(&wayland_display))) return &wayland_display;
    last_error = EGL_BAD_DISPLAY;
    return null;
}

/// The display behind a handle, if it is ours and initialized.
fn display(dpy: EGLDisplay) ?*Display {
    const d = displayHandle(dpy) orelse return null;
    if (!d.initialized) {
        last_error = EGL_NOT_INITIALIZED;
        return null;
    }
    return d;
}

// --- The GPU backend for GL contexts ----------------------------------------

fn deviceOf(ptr: *anyopaque) vc4.Device {
    return @as(*Display, @ptrCast(@alignCast(ptr))).dev;
}

fn createBo(ptr: *anyopaque, size: u32) anyerror!vc4.Bo {
    return deviceOf(ptr).createBo(size);
}

fn destroyBo(ptr: *anyopaque, bo: vc4.Bo) void {
    deviceOf(ptr).destroyBo(bo);
}

fn createShader(ptr: *anyopaque, code: []const vc4.qpu.Inst) anyerror!u32 {
    return deviceOf(ptr).createShaderBo(code);
}

fn destroyShader(ptr: *anyopaque, handle: u32) void {
    drm.gemClose(deviceOf(ptr).fd, handle);
}

fn run(ptr: *anyopaque, frame: *vc4.render.Frame) anyerror!void {
    const dev = deviceOf(ptr);
    const seqno = try dev.submit(&frame.submit);
    try dev.waitSeqno(seqno, std.time.ns_per_s);
}

const backend_vtable: context.Backend.VTable = .{
    .createBo = createBo,
    .destroyBo = destroyBo,
    .createShader = createShader,
    .destroyShader = destroyShader,
    .run = run,
};

// --- Displays ---------------------------------------------------------------

/// EGL_DEFAULT_DISPLAY gives the screen itself (the app must be the DRM
/// master, so no compositor may be running); a wayland client Display
/// (`*wayland.client.Display`) gives windows on that compositor.
pub export fn eglGetDisplay(native: EGLNativeDisplayType) callconv(.c) EGLDisplay {
    const n = native orelse return @ptrCast(&kms_display);
    if (!wayland_display.initialized) wayland_display.wl.conn = @ptrCast(@alignCast(n));
    return @ptrCast(&wayland_display);
}

pub export fn eglInitialize(dpy: EGLDisplay, major: ?*EGLint, minor: ?*EGLint) callconv(.c) EGLBoolean {
    const d = displayHandle(dpy) orelse return EGL_FALSE;
    if (!d.initialized) switch (d.platform) {
        .kms => {
            const dev = vc4.device.open() catch |e| {
                sys.print("stardust egl: no vc4 GPU: {s}\n", .{@errorName(e)});
                return fail(EGL_NOT_INITIALIZED);
            };
            const output = drm.waitForOutput(dev.fd) catch |e| {
                sys.print("stardust egl: no display output: {s}\n", .{@errorName(e)});
                sys.close(dev.fd);
                return fail(EGL_NOT_INITIALIZED);
            };
            d.dev = dev;
            d.output = output;
            d.initialized = true;
        },
        .wayland => {
            const dev = vc4.device.openRender() catch |e| {
                sys.print("stardust egl: no vc4 render node: {s}\n", .{@errorName(e)});
                return fail(EGL_NOT_INITIALIZED);
            };
            d.dev = dev;
            d.wl = .{ .conn = d.wl.conn, .gpu = .device(&d.dev) };
            d.wl.init() catch |e| {
                sys.print("stardust egl: the compositor cannot take GPU buffers: {s}\n", .{@errorName(e)});
                sys.close(dev.fd);
                return fail(EGL_NOT_INITIALIZED);
            };
            d.initialized = true;
        },
    };
    if (major) |m| m.* = 1;
    if (minor) |m| m.* = 4;
    return ok();
}

pub export fn eglTerminate(dpy: EGLDisplay) callconv(.c) EGLBoolean {
    const d = displayHandle(dpy) orelse return EGL_FALSE;
    if (d.initialized) {
        // Contexts and surfaces should have been destroyed; closing the
        // device frees whatever is left.
        context.current = null;
        current_context = null;
        current_surface = null;
        current_display = null;
        sys.close(d.dev.fd);
        d.initialized = false;
    }
    return ok();
}

pub export fn eglQueryString(dpy: EGLDisplay, name: EGLint) callconv(.c) ?[*:0]const u8 {
    _ = display(dpy) orelse return null;
    last_error = EGL_SUCCESS;
    return switch (name) {
        EGL_VENDOR => "Stardust",
        EGL_VERSION => "1.4 Stardust",
        EGL_EXTENSIONS => "",
        EGL_CLIENT_APIS => "OpenGL_ES",
        else => {
            last_error = EGL_BAD_PARAMETER;
            return null;
        },
    };
}

pub export fn eglGetError() callconv(.c) EGLint {
    const e = last_error;
    last_error = EGL_SUCCESS;
    return e;
}

pub export fn eglGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const n = std.mem.span(name);
    return gl.procAddress(n) orelse procAddress(n);
}

/// The EGL entry points by name.
fn procAddress(name: []const u8) ?*const anyopaque {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(@This()).@"struct".decls) |d| {
        if (comptime std.mem.startsWith(u8, d.name, "egl") and @typeInfo(@TypeOf(@field(@This(), d.name))) == .@"fn") {
            if (std.mem.eql(u8, name, d.name)) return @ptrCast(&@field(@This(), d.name));
        }
    }
    return null;
}

// --- Configurations ---------------------------------------------------------

/// The one configuration's attributes.
fn configAttrib(attribute: EGLint) ?EGLint {
    return switch (attribute) {
        // The render target stores alpha; the display ignores it.
        EGL_BUFFER_SIZE => 32,
        EGL_RED_SIZE, EGL_GREEN_SIZE, EGL_BLUE_SIZE, EGL_ALPHA_SIZE => 8,
        EGL_STENCIL_SIZE, EGL_LUMINANCE_SIZE, EGL_ALPHA_MASK_SIZE => 0,
        EGL_DEPTH_SIZE => 24,
        EGL_CONFIG_CAVEAT => EGL_NONE,
        EGL_CONFIG_ID => 1,
        EGL_LEVEL => 0,
        EGL_MAX_PBUFFER_WIDTH, EGL_MAX_PBUFFER_HEIGHT, EGL_MAX_PBUFFER_PIXELS => 0,
        EGL_NATIVE_RENDERABLE => EGL_FALSE,
        EGL_NATIVE_VISUAL_ID => @bitCast(drm.format_xrgb8888),
        EGL_NATIVE_VISUAL_TYPE => 0,
        EGL_SAMPLES, EGL_SAMPLE_BUFFERS => 0,
        EGL_SURFACE_TYPE => EGL_WINDOW_BIT,
        EGL_TRANSPARENT_TYPE => EGL_NONE,
        EGL_TRANSPARENT_RED_VALUE, EGL_TRANSPARENT_GREEN_VALUE, EGL_TRANSPARENT_BLUE_VALUE => 0,
        EGL_BIND_TO_TEXTURE_RGB, EGL_BIND_TO_TEXTURE_RGBA => EGL_FALSE,
        EGL_MIN_SWAP_INTERVAL, EGL_MAX_SWAP_INTERVAL => 1,
        EGL_COLOR_BUFFER_TYPE => EGL_RGB_BUFFER,
        EGL_RENDERABLE_TYPE, EGL_CONFORMANT => EGL_OPENGL_ES2_BIT,
        else => null,
    };
}

/// Whether the configuration satisfies one eglChooseConfig criterion.
fn matches(attribute: EGLint, value: EGLint) ?bool {
    if (value == EGL_DONT_CARE) return true;
    const have = configAttrib(attribute) orelse return null;
    return switch (attribute) {
        // Sizes are minimums.
        EGL_BUFFER_SIZE, EGL_RED_SIZE, EGL_GREEN_SIZE, EGL_BLUE_SIZE, EGL_ALPHA_SIZE, EGL_DEPTH_SIZE, EGL_STENCIL_SIZE, EGL_LUMINANCE_SIZE, EGL_ALPHA_MASK_SIZE, EGL_SAMPLES, EGL_SAMPLE_BUFFERS => have >= value,
        // Bit masks must include the requested bits.
        EGL_SURFACE_TYPE, EGL_RENDERABLE_TYPE, EGL_CONFORMANT => have & value == value,
        // Not selection criteria.
        EGL_MAX_PBUFFER_WIDTH, EGL_MAX_PBUFFER_HEIGHT, EGL_MAX_PBUFFER_PIXELS, EGL_NATIVE_VISUAL_ID, EGL_TRANSPARENT_RED_VALUE, EGL_TRANSPARENT_GREEN_VALUE, EGL_TRANSPARENT_BLUE_VALUE => true,
        else => have == value,
    };
}

pub export fn eglGetConfigs(dpy: EGLDisplay, configs: ?[*]EGLConfig, config_size: EGLint, num_config: ?*EGLint) callconv(.c) EGLBoolean {
    _ = display(dpy) orelse return EGL_FALSE;
    const n = num_config orelse return fail(EGL_BAD_PARAMETER);
    n.* = 1;
    if (configs) |c| {
        if (config_size < 1) {
            n.* = 0;
        } else c[0] = the_config;
    }
    return ok();
}

pub export fn eglChooseConfig(dpy: EGLDisplay, attrib_list: ?[*]const EGLint, configs: ?[*]EGLConfig, config_size: EGLint, num_config: ?*EGLint) callconv(.c) EGLBoolean {
    _ = display(dpy) orelse return EGL_FALSE;
    const n = num_config orelse return fail(EGL_BAD_PARAMETER);
    var match = true;
    if (attrib_list) |list| {
        var i: usize = 0;
        while (list[i] != EGL_NONE) : (i += 2) {
            // EGL_CONFIG_ID selects by ID alone, but there is only one.
            match = match and (matches(list[i], list[i + 1]) orelse return fail(EGL_BAD_ATTRIBUTE));
        }
    }
    n.* = @intFromBool(match);
    if (configs) |c| {
        if (config_size < 1) {
            n.* = 0;
        } else if (match) c[0] = the_config;
    }
    return ok();
}

pub export fn eglGetConfigAttrib(dpy: EGLDisplay, config: EGLConfig, attribute: EGLint, value: *EGLint) callconv(.c) EGLBoolean {
    _ = display(dpy) orelse return EGL_FALSE;
    if (config != the_config) return fail(EGL_BAD_CONFIG);
    value.* = configAttrib(attribute) orelse return fail(EGL_BAD_ATTRIBUTE);
    return ok();
}

// --- Surfaces ---------------------------------------------------------------

/// On the KMS platform the window is ignored and the surface is the whole
/// screen; on Wayland it is a `wl_egl_window`.
pub export fn eglCreateWindowSurface(dpy: EGLDisplay, config: EGLConfig, window: EGLNativeWindowType, attrib_list: ?[*]const EGLint) callconv(.c) EGLSurface {
    _ = attrib_list;
    const d = display(dpy) orelse return EGL_NO_SURFACE;
    if (config != the_config) {
        last_error = EGL_BAD_CONFIG;
        return EGL_NO_SURFACE;
    }
    const s = gpa.create(Surface) catch {
        last_error = EGL_BAD_ALLOC;
        return EGL_NO_SURFACE;
    };
    switch (d.platform) {
        .kms => s.* = .{ .kms = vc4.display.Display.init(d.dev, d.output) catch {
            gpa.destroy(s);
            last_error = EGL_BAD_ALLOC;
            return EGL_NO_SURFACE;
        } },
        .wayland => {
            if (window == 0) {
                gpa.destroy(s);
                last_error = EGL_BAD_NATIVE_WINDOW;
                return EGL_NO_SURFACE;
            }
            s.* = .{ .wayland = egl_wayland.Surface.create(&d.wl, @ptrFromInt(window)) catch {
                gpa.destroy(s);
                last_error = EGL_BAD_ALLOC;
                return EGL_NO_SURFACE;
            } };
        },
    }
    last_error = EGL_SUCCESS;
    return s;
}

pub export fn eglCreatePbufferSurface(dpy: EGLDisplay, config: EGLConfig, attrib_list: ?[*]const EGLint) callconv(.c) EGLSurface {
    _ = config;
    _ = attrib_list;
    _ = display(dpy) orelse return EGL_NO_SURFACE;
    last_error = EGL_BAD_MATCH;
    return EGL_NO_SURFACE;
}

pub export fn eglCreatePixmapSurface(dpy: EGLDisplay, config: EGLConfig, pixmap: EGLNativePixmapType, attrib_list: ?[*]const EGLint) callconv(.c) EGLSurface {
    _ = config;
    _ = pixmap;
    _ = attrib_list;
    _ = display(dpy) orelse return EGL_NO_SURFACE;
    last_error = EGL_BAD_MATCH;
    return EGL_NO_SURFACE;
}

fn surfaceOf(s: EGLSurface) *Surface {
    return @ptrCast(@alignCast(s.?));
}

pub export fn eglDestroySurface(dpy: EGLDisplay, surface: EGLSurface) callconv(.c) EGLBoolean {
    const d = display(dpy) orelse return EGL_FALSE;
    if (surface == EGL_NO_SURFACE) return fail(EGL_BAD_SURFACE);
    const s = surfaceOf(surface);
    if (current_surface == s) return fail(EGL_BAD_ACCESS);
    switch (s.*) {
        .kms => |k| for (k.buffers) |b| d.dev.destroyBo(b.bo),
        .wayland => |w| w.destroy(),
    }
    gpa.destroy(s);
    return ok();
}

pub export fn eglQuerySurface(dpy: EGLDisplay, surface: EGLSurface, attribute: EGLint, value: *EGLint) callconv(.c) EGLBoolean {
    _ = display(dpy) orelse return EGL_FALSE;
    if (surface == EGL_NO_SURFACE) return fail(EGL_BAD_SURFACE);
    const s = surfaceOf(surface);
    value.* = switch (attribute) {
        EGL_WIDTH => @intCast(s.width()),
        EGL_HEIGHT => @intCast(s.height()),
        EGL_CONFIG_ID => 1,
        EGL_RENDER_BUFFER => EGL_BACK_BUFFER,
        EGL_SWAP_BEHAVIOR => EGL_BUFFER_DESTROYED,
        EGL_HORIZONTAL_RESOLUTION, EGL_VERTICAL_RESOLUTION, EGL_PIXEL_ASPECT_RATIO => EGL_UNKNOWN,
        EGL_LARGEST_PBUFFER => return ok(),
        else => return fail(EGL_BAD_ATTRIBUTE),
    };
    return ok();
}

pub export fn eglSurfaceAttrib(dpy: EGLDisplay, surface: EGLSurface, attribute: EGLint, value: EGLint) callconv(.c) EGLBoolean {
    _ = surface;
    _ = display(dpy) orelse return EGL_FALSE;
    if (attribute == EGL_SWAP_BEHAVIOR and value == EGL_BUFFER_DESTROYED) return ok();
    return fail(EGL_BAD_MATCH);
}

/// Frames are always shown at vertical blank, one per refresh at most.
pub export fn eglSwapInterval(dpy: EGLDisplay, interval: EGLint) callconv(.c) EGLBoolean {
    _ = interval;
    _ = display(dpy) orelse return EGL_FALSE;
    return ok();
}

/// Renders the frame and shows it. On the screen (KMS) this waits for the
/// page flip at the next vertical blank; on Wayland it waits for the
/// compositor to show the previous frame, then commits this one. The new
/// back buffer's contents are undefined, so frames should start with
/// glClear.
pub export fn eglSwapBuffers(dpy: EGLDisplay, surface: EGLSurface) callconv(.c) EGLBoolean {
    _ = display(dpy) orelse return EGL_FALSE;
    if (surface == EGL_NO_SURFACE) return fail(EGL_BAD_SURFACE);
    const s = surfaceOf(surface);
    if (current_surface != s) return fail(EGL_BAD_SURFACE);
    const c = current_context.?;
    switch (s.*) {
        .kms => |*k| {
            c.gl.submit();
            k.present() catch |e| {
                sys.print("stardust egl: page flip failed: {s}\n", .{@errorName(e)});
                return fail(EGL_BAD_NATIVE_WINDOW);
            };
            c.gl.setTarget(k.backTarget());
        },
        .wayland => |w| w.swap(c.gl) catch |e| {
            sys.print("stardust egl: presenting to the compositor failed: {s}\n", .{@errorName(e)});
            return fail(EGL_BAD_NATIVE_WINDOW);
        },
    }
    return ok();
}

// --- Contexts ---------------------------------------------------------------

pub export fn eglBindAPI(api: EGLenum) callconv(.c) EGLBoolean {
    if (api != EGL_OPENGL_ES_API) return fail(EGL_BAD_PARAMETER);
    return ok();
}

pub export fn eglQueryAPI() callconv(.c) EGLenum {
    return EGL_OPENGL_ES_API;
}

pub export fn eglCreateContext(dpy: EGLDisplay, config: EGLConfig, share_context: EGLContext, attrib_list: ?[*]const EGLint) callconv(.c) EGLContext {
    const d = display(dpy) orelse return EGL_NO_CONTEXT;
    if (config != the_config) {
        last_error = EGL_BAD_CONFIG;
        return EGL_NO_CONTEXT;
    }
    if (share_context != EGL_NO_CONTEXT) {
        // Object sharing between contexts is not supported.
        last_error = EGL_BAD_MATCH;
        return EGL_NO_CONTEXT;
    }
    if (attrib_list) |list| {
        var i: usize = 0;
        while (list[i] != EGL_NONE) : (i += 2) {
            if (list[i] != EGL_CONTEXT_CLIENT_VERSION) {
                last_error = EGL_BAD_ATTRIBUTE;
                return EGL_NO_CONTEXT;
            }
            if (list[i + 1] != 2) {
                last_error = EGL_BAD_MATCH;
                return EGL_NO_CONTEXT;
            }
        }
    }
    const c = gpa.create(Context) catch {
        last_error = EGL_BAD_ALLOC;
        return EGL_NO_CONTEXT;
    };
    c.* = .{ .gl = context.Context.create(gpa, .{ .ptr = d, .vtable = &backend_vtable }) catch {
        gpa.destroy(c);
        last_error = EGL_BAD_ALLOC;
        return EGL_NO_CONTEXT;
    } };
    last_error = EGL_SUCCESS;
    return c;
}

fn contextOf(c: EGLContext) *Context {
    return @ptrCast(@alignCast(c.?));
}

pub export fn eglDestroyContext(dpy: EGLDisplay, ctx: EGLContext) callconv(.c) EGLBoolean {
    _ = display(dpy) orelse return EGL_FALSE;
    if (ctx == EGL_NO_CONTEXT) return fail(EGL_BAD_CONTEXT);
    const c = contextOf(ctx);
    if (current_context == c) return fail(EGL_BAD_ACCESS);
    c.gl.destroy();
    gpa.destroy(c);
    return ok();
}

pub export fn eglMakeCurrent(dpy: EGLDisplay, draw: EGLSurface, read: EGLSurface, ctx: EGLContext) callconv(.c) EGLBoolean {
    const d = display(dpy) orelse return EGL_FALSE;
    if (draw != read) return fail(EGL_BAD_MATCH);
    // Finish the previous binding's rendering.
    if (current_context) |old| {
        old.gl.submit();
        old.gl.target = null;
    }
    if (ctx == EGL_NO_CONTEXT) {
        if (draw != EGL_NO_SURFACE) return fail(EGL_BAD_MATCH);
        current_context = null;
        current_surface = null;
        current_display = null;
        context.current = null;
        return ok();
    }
    if (draw == EGL_NO_SURFACE) return fail(EGL_BAD_MATCH);
    const c = contextOf(ctx);
    const s = surfaceOf(draw);
    c.gl.setTarget(s.backTarget() catch return fail(EGL_BAD_ALLOC));
    if (!c.bound) {
        // The viewport and scissor box start out covering the surface.
        const size: [4]c_int = .{ 0, 0, @intCast(s.width()), @intCast(s.height()) };
        c.gl.viewport = size;
        c.gl.scissor = size;
        c.bound = true;
    }
    current_context = c;
    current_surface = s;
    current_display = d;
    context.current = c.gl;
    return ok();
}

pub export fn eglGetCurrentContext() callconv(.c) EGLContext {
    return current_context;
}

pub export fn eglGetCurrentSurface(readdraw: EGLint) callconv(.c) EGLSurface {
    _ = readdraw;
    return current_surface;
}

pub export fn eglGetCurrentDisplay() callconv(.c) EGLDisplay {
    return current_display;
}

pub export fn eglQueryContext(dpy: EGLDisplay, ctx: EGLContext, attribute: EGLint, value: *EGLint) callconv(.c) EGLBoolean {
    _ = display(dpy) orelse return EGL_FALSE;
    if (ctx == EGL_NO_CONTEXT) return fail(EGL_BAD_CONTEXT);
    value.* = switch (attribute) {
        EGL_CONFIG_ID => 1,
        EGL_CONTEXT_CLIENT_TYPE => @intCast(EGL_OPENGL_ES_API),
        EGL_CONTEXT_CLIENT_VERSION => 2,
        EGL_RENDER_BUFFER => EGL_BACK_BUFFER,
        else => return fail(EGL_BAD_ATTRIBUTE),
    };
    return ok();
}

pub export fn eglWaitClient() callconv(.c) EGLBoolean {
    return ok();
}

pub export fn eglWaitGL() callconv(.c) EGLBoolean {
    return ok();
}

pub export fn eglWaitNative(engine: EGLint) callconv(.c) EGLBoolean {
    _ = engine;
    return ok();
}

pub export fn eglReleaseThread() callconv(.c) EGLBoolean {
    return ok();
}

test "config selection" {
    try std.testing.expectEqual(true, matches(EGL_RED_SIZE, 8).?);
    try std.testing.expectEqual(false, matches(EGL_STENCIL_SIZE, 8).?);
    try std.testing.expectEqual(true, matches(EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT).?);
    try std.testing.expectEqual(false, matches(EGL_SURFACE_TYPE, EGL_PBUFFER_BIT).?);
    try std.testing.expectEqual(true, matches(EGL_DEPTH_SIZE, EGL_DONT_CARE).?);
    try std.testing.expect(matches(0x1234, 0) == null);
}

test "eglGetProcAddress" {
    try std.testing.expect(eglGetProcAddress("glDrawArrays") != null);
    try std.testing.expect(eglGetProcAddress("eglSwapBuffers") == @as(?*const anyopaque, @ptrCast(&eglSwapBuffers)));
    try std.testing.expect(eglGetProcAddress("eglNope") == null);
}
