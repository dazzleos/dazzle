//! The boot screen: the Dazzle logo in the middle of the screen, and below
//! it what the system is doing ("Starting", "Checking the files", ...),
//! from as soon as init starts until the shell shows its first frame; and
//! again while the computer restarts or turns off.
//!
//! It is drawn by a process of its own (`start`), which owns the display
//! meanwhile: if init held it, every process init starts after would hold
//! it too (a forked process shares its files), and the screen's buffer
//! (GPU memory, which is scarce) would never be freed. Init tells it what
//! to say (`Splash.say`); when the shell starts (`Splash.handOver`), it
//! lets the shell have the display, and goes once the shell has put a
//! frame of its own on the screen, so the screen is never blank between
//! them. The shell fades in from it (its first frames show this frame's
//! buffer over the desktop, on the display's top plane, see the shell's
//! `BootFade`).
//!
//! Shutting down (`startShutdown`), it fades the other way: the shell,
//! asked to stop, shows its last frame alone and lets the display go;
//! the shutdown screen takes the display, shows that frame over itself on
//! the top plane, and fades it out (by the plane's alpha), then says it
//! is done.
//!
//! The text is drawn with kete's font renderer, in Fira Sans from
//! /os/fonts; the logo is decoded with kete's PNG decoder. Nothing else
//! of kete is needed (init does not use the GPU).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");
const kete_font = @import("kete_font");
const kete_png = @import("kete_png");

const drm = vc4.drm;
const print = sys.print;

/// Behind the logo: Dazzle's dark surface colour.
const background: u32 = 0xff1c1b1f;
/// The text under the logo.
const text_color: u32 = 0xffc8c5ca;

/// How long the boot screen waits for the shell's first frame before
/// going anyway (the screen is then blank until the shell draws).
const handover_timeout_ns = 30 * std.time.ns_per_s;

/// The boot screen's process, as init sees it.
pub const Splash = struct {
    pid: linux.pid_t,
    /// What init writes to it: a line of text to show, or an empty line
    /// to hand the display over.
    pipe: linux.fd_t,
    /// Where it says it has let the display go.
    ack: linux.fd_t,

    /// Shows `text` under the logo, in place of what was there.
    pub fn say(s: Splash, text: []const u8) void {
        var buf: [128]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = '\n';
        _ = linux.write(s.pipe, &buf, n + 1);
    }

    /// The shell is about to start: the boot screen lets the display go
    /// (it stays on the screen until the shell has drawn), and this
    /// returns once it has, so the shell can have it (or after a second,
    /// if the boot screen does not answer).
    pub fn handOver(s: Splash) void {
        _ = linux.write(s.pipe, "\n", 1);
        sys.close(s.pipe);
        var pfd = [1]linux.pollfd{.{ .fd = s.ack, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, 1000);
        sys.close(s.ack);
    }

    /// Waits for the boot screen to have gone (and its process to be
    /// reaped), at most `timeout_ms`: before the computer restarts, so
    /// the last thing said is seen.
    pub fn wait(s: Splash, timeout_ms: u32) void {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 50) {
            var status: u32 = 0;
            const rc = linux.wait4(s.pid, @ptrCast(&status), linux.W.NOHANG, null);
            if (linux.errno(rc) != .SUCCESS or rc != 0) return;
            sys.sleepMs(50);
        }
    }
};

/// Starts the boot screen saying `text`. Null if it cannot be started
/// (booting goes on without it).
pub fn start(text: []const u8) ?Splash {
    var fds: [2]linux.fd_t = undefined;
    _ = sys.check(linux.pipe2(&fds, .{ .CLOEXEC = true })) catch return null;
    var ack: [2]linux.fd_t = undefined;
    _ = sys.check(linux.pipe2(&ack, .{ .CLOEXEC = true })) catch {
        for (fds) |fd| sys.close(fd);
        return null;
    };
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        for ([_]linux.fd_t{ fds[0], fds[1], ack[0], ack[1] }) |fd| sys.close(fd);
        return null;
    }
    if (rc == 0) {
        sys.close(fds[1]);
        sys.close(ack[0]);
        run(fds[0], ack[1], text);
        linux.exit(0);
    }
    sys.close(fds[0]);
    sys.close(ack[1]);
    return .{ .pid = @intCast(rc), .pipe = fds[1], .ack = ack[0] };
}

/// Starts the shutdown screen saying `text`: it waits for the shell to
/// let the display go (or for a moment, if there is no shell), fades from
/// the shell's last frame to itself, and says when it has (`waitShown`).
/// It is not stopped with the other processes (it ignores SIGTERM).
pub fn startShutdown(text: []const u8) ?Splash {
    var ack: [2]linux.fd_t = undefined;
    _ = sys.check(linux.pipe2(&ack, .{ .CLOEXEC = true })) catch return null;
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        for (ack) |fd| sys.close(fd);
        return null;
    }
    if (rc == 0) {
        sys.close(ack[0]);
        const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.TERM, &ignore, null);
        runShutdown(ack[1], text);
        // On the screen until the computer restarts.
        while (true) _ = linux.pause();
    }
    sys.close(ack[1]);
    return .{ .pid = @intCast(rc), .pipe = -1, .ack = ack[0] };
}

/// Waits (`timeout_ms` at most) for the shutdown screen to be shown
/// (faded in).
pub fn waitShown(s: Splash, timeout_ms: i32) void {
    var pfd = [1]linux.pollfd{.{ .fd = s.ack, .events = linux.POLL.IN, .revents = 0 }};
    _ = linux.poll(&pfd, 1, timeout_ms);
}

/// How long the shutdown screen fades in over the shell's last frame.
const fade_ns = 400 * std.time.ns_per_ms;

fn runShutdown(done: linux.fd_t, text: []const u8) void {
    defer {
        _ = linux.write(done, "x", 1);
        sys.close(done);
    }
    var screen = Screen.open(false) catch |err| {
        print(sys.log_warning ++ "dazzle: shutdown screen: {s}\n", .{@errorName(err)});
        return;
    };
    screen.say(text);
    // The display, once the shell has let it go (it shows its last frame
    // first), or after a moment (it has stopped, or there is none).
    const started = sys.nowNs();
    while (linux.errno(linux.ioctl(screen.fd, drm.IOCTL_SET_MASTER, 0)) != .SUCCESS) {
        if (sys.nowNs() - started > 4 * std.time.ns_per_s) break;
        sys.sleepMs(20);
    }
    const last = drm.adoptShown(screen.fd, screen.output.crtc_id);
    var kms = vc4.kms.Kms.init(screen.fd, screen.output) catch {
        drm.setCrtc(screen.fd, screen.output, screen.fb) catch {};
        return;
    };
    const w = screen.width;
    const h = screen.height;
    const own: vc4.kms.Layer = .{ .fb_id = screen.fb, .src_width = w, .src_height = h, .x = 0, .y = 0, .width = w, .height = h };
    const from = last orelse {
        showOnly(&kms, &screen, own);
        return;
    };
    var cover: vc4.kms.Layer = .{ .fb_id = from.fb_id, .src_width = @min(from.width, w), .src_height = @min(from.height, h), .x = 0, .y = 0, .width = @min(from.width, w), .height = @min(from.height, h) };
    if (!kms.canFadeCover() or !kms.setCover(cover)) {
        showOnly(&kms, &screen, own);
        return;
    }
    // As it was (the shell's last frame), then less and less of it.
    _ = kms.commit(own, @splat(null)) catch {
        drm.setCrtc(screen.fd, screen.output, screen.fb) catch {};
        return;
    };
    const fading = sys.nowNs();
    while (true) {
        const t = @min(@as(f32, @floatFromInt(sys.nowNs() - fading)) / @as(f32, @floatFromInt(fade_ns)), 1);
        const ease = 1 - (1 - t) * (1 - t);
        cover.alpha = @intFromFloat(@round((1 - ease) * 0xffff));
        _ = kms.setCover(if (t < 1) cover else null);
        _ = kms.commit(own, @splat(null)) catch break;
        drm.waitFlip(screen.fd) catch break;
        if (t >= 1) break;
    }
}

/// Shows the screen alone (atomically, or by the old call if that fails).
fn showOnly(kms: *vc4.kms.Kms, screen: *const Screen, own: vc4.kms.Layer) void {
    _ = kms.setCover(null);
    _ = kms.commit(own, @splat(null)) catch {
        drm.setCrtc(screen.fd, screen.output, screen.fb) catch {};
    };
}

/// The boot screen's process: shows it, says what init says, and goes
/// once the shell has the screen.
fn run(pipe: linux.fd_t, ack: linux.fd_t, first: []const u8) void {
    var screen = Screen.open(true) catch |err| {
        print(sys.log_warning ++ "dazzle: boot screen: {s}\n", .{@errorName(err)});
        // Nothing to let go: init is not held up.
        sys.close(ack);
        return;
    };
    screen.say(first);
    // What init says, line by line, until the hand-over (an empty line,
    // or init's end of the pipe closed).
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    reading: while (true) {
        const n = sys.check(linux.read(pipe, buf[len..].ptr, buf.len - len)) catch 0;
        if (n == 0) break;
        len += n;
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |end| {
            const line = buf[0..end];
            if (line.len == 0) break :reading;
            screen.say(line);
            std.mem.copyForwards(u8, buf[0..], buf[end + 1 .. len]);
            len -= end + 1;
        }
        if (len == buf.len) len = 0;
    }
    screen.handOver(ack);
}

/// The screen, drawn by the CPU into a buffer the display shows.
const Screen = struct {
    fd: linux.fd_t,
    output: drm.Output,
    fb: u32,
    pixels: []u32,
    width: u32,
    height: u32,
    /// Where the text goes: its baseline, and the band it is drawn in.
    baseline: f32,
    band_top: u32,
    band_height: u32,
    font: ?kete_font.Font,
    font_data: []const u8 = &.{},
    cache: kete_font.GlyphCache,
    style: kete_font.Style,

    const gpa = std.heap.page_allocator;

    /// Draws the screen; `show`s it (being the display's master), or
    /// leaves that to the caller.
    fn open(show: bool) !Screen {
        const fd = try openDisplay();
        errdefer sys.close(fd);
        const output = try findOutput(fd);
        const width: u32 = output.mode.hdisplay;
        const height: u32 = output.mode.vdisplay;
        const buffer = try drm.DumbBuffer.create(fd, width, height);
        const fb = try drm.addFramebuffer(fd, buffer.handle, width, height, buffer.pitch, drm.format_xrgb8888);
        const pixels = std.mem.bytesAsSlice(u32, buffer.map[0 .. buffer.pitch * height]);
        @memset(pixels, background);
        // The logo: a quarter of the screen's height, in the middle (a
        // little above, to leave room for the text).
        const logo_size: u32 = @max(64, height / 4);
        const logo_top: u32 = (height - logo_size) / 2 - height / 24;
        drawLogo(pixels, buffer.pitch / 4, (width - logo_size) / 2, logo_top, logo_size);
        const size: f32 = @floatFromInt(@max(16, height / 40));
        const font_data = sys.readFileAlloc(gpa, "/os/fonts/" ++ kete_font.default_font_file, 4 * 1024 * 1024) catch &.{};
        const font = if (font_data.len > 0) kete_font.Font.init(font_data) catch null else null;
        var s: Screen = .{
            .fd = fd,
            .output = output,
            .fb = fb,
            .pixels = pixels,
            .width = width,
            .height = height,
            .baseline = @as(f32, @floatFromInt(logo_top + logo_size)) + size * 2.5,
            .band_top = logo_top + logo_size + @as(u32, @intFromFloat(size)),
            .band_height = @intFromFloat(size * 2.5),
            .font = font,
            .font_data = font_data,
            .cache = .init(gpa),
            .style = undefined,
        };
        if (s.font) |*f| s.style = .{ .font = f, .size = size };
        // Shown once drawn.
        if (show) try drm.setCrtc(fd, output, fb);
        return s;
    }

    /// Shows `text` under the logo, centred.
    fn say(s: *Screen, text: []const u8) void {
        const stride = s.pitch();
        for (s.band_top..@min(s.band_top + s.band_height, s.height)) |y| @memset(s.pixels[y * stride ..][0..s.width], background);
        if (s.font) |*f| {
            s.style.font = f;
            const w = kete_font.measure(s.style, text);
            const x = (@as(f32, @floatFromInt(s.width)) - w) / 2;
            const canvas: kete_font.Canvas = .{ .pixels = s.pixels, .width = s.width, .height = s.height, .stride = stride };
            _ = kete_font.draw(canvas, &s.cache, s.style, @round(x), s.baseline, text) catch {};
        }
    }

    fn pitch(s: *const Screen) u32 {
        return @intCast(s.pixels.len / s.height);
    }

    /// Lets the shell have the display, and waits (a while at most) for
    /// it to show a frame of its own before going: the boot screen's
    /// buffer goes with this process.
    fn handOver(s: *Screen, ack: linux.fd_t) void {
        drm.dropMaster(s.fd) catch {};
        _ = linux.write(ack, "x", 1);
        sys.close(ack);
        const started = sys.nowNs();
        while (sys.nowNs() - started < handover_timeout_ns) {
            const shown = drm.crtcFramebuffer(s.fd, s.output.crtc_id) catch break;
            if (shown != s.fb) break;
            sys.sleepMs(50);
        }
    }
};

/// Opens the display's DRM device (the vc4 driver's card), waiting a
/// moment for it to come.
fn openDisplay() !linux.fd_t {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        for (0..4) |n| {
            var path_buf: [64]u8 = undefined;
            const link_path = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/drm/card{d}/device/driver", .{n}, 0) catch continue;
            var link: [256]u8 = undefined;
            const len = sys.check(linux.readlink(link_path.ptr, &link, link.len)) catch continue;
            if (!std.mem.endsWith(u8, link[0..len], "/vc4-drm")) continue;
            var dev_buf: [32]u8 = undefined;
            const dev = std.fmt.bufPrintSentinel(&dev_buf, "/dev/dri/card{d}", .{n}, 0) catch continue;
            return sys.open(dev.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        }
        if (waited >= 3000) return error.NoDisplay;
        sys.sleepMs(100);
    }
}

/// The connected display, waiting a moment for it (HDMI is found a little
/// after the driver).
fn findOutput(fd: linux.fd_t) !drm.Output {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        return drm.findOutput(fd) catch |err| {
            if (err != error.NoConnectedOutput or attempt == 20) return err;
            sys.sleepMs(100);
            continue;
        };
    }
}

/// Draws the logo `size` pixels square at (`x`, `y`), over what is there:
/// each pixel the average of the logo's pixels it covers.
fn drawLogo(pixels: []u32, stride: u32, x: u32, y: u32, size: u32) void {
    const decoded = kete_png.decode(std.heap.page_allocator, @embedFile("logo.png")) catch return;
    defer std.heap.page_allocator.free(decoded.pixels);
    scaleOver(pixels, stride, x, y, size, decoded.pixels, decoded.width, decoded.height);
}

/// `src` (0xAARRGGBB, straight alpha) scaled to `size` square, blended
/// over `dst` at (`x`, `y`).
fn scaleOver(dst: []u32, stride: u32, x: u32, y: u32, size: u32, src: []const u32, sw: u32, sh: u32) void {
    for (0..size) |dy| for (0..size) |dx| {
        const x0 = dx * sw / size;
        const x1 = @max(x0 + 1, (dx + 1) * sw / size);
        const y0 = dy * sh / size;
        const y1 = @max(y0 + 1, (dy + 1) * sh / size);
        // Premultiplied sums, so transparent pixels add no colour.
        var sum: [4]u64 = .{ 0, 0, 0, 0 };
        for (y0..y1) |sy| for (x0..x1) |sx| {
            const p = src[sy * sw + sx];
            const a: u64 = p >> 24;
            sum[0] += a;
            inline for (1..4) |i| sum[i] += ((p >> @intCast(24 - 8 * i)) & 0xff) * a;
        };
        const n: u64 = (y1 - y0) * (x1 - x0);
        const a = sum[0] / n;
        const at = (y + dy) * stride + x + dx;
        const under = dst[at];
        var out: u32 = 0xff000000;
        inline for (1..4) |i| {
            const shift: u5 = @intCast(24 - 8 * i);
            const c = sum[i] / n / 255;
            const b: u64 = (under >> shift) & 0xff;
            out |= @as(u32, @intCast((c * 255 + b * (255 - a)) / 255)) << shift;
        }
        dst[at] = out;
    };
}

test "the logo is scaled down evenly and blended over what is under it" {
    // A 4x4 image: its left half opaque white, its right half clear.
    var src: [16]u32 = undefined;
    for (0..4) |r| for (0..4) |c| {
        src[r * 4 + c] = if (c < 2) 0xffffffff else 0x00000000;
    };
    var dst: [4]u32 = @splat(0xff000000);
    scaleOver(&dst, 2, 0, 0, 2, &src, 4, 4);
    try std.testing.expectEqual(@as(u32, 0xffffffff), dst[0]);
    try std.testing.expectEqual(@as(u32, 0xff000000), dst[1]);
    // Half covered: half way.
    var half: [1]u32 = .{0xff000000};
    scaleOver(&half, 1, 0, 0, 1, src[0..4], 2, 2);
    try std.testing.expectEqual(@as(u32, 0xff7f7f7f), half[0]);
}
