//! stardust-shell: a minimal Wayland compositor and shell.
//!
//! It owns the display (as the DRM master) and draws with the low-level vc4
//! API: a bar across the top (the window title and the time since boot)
//! and the most recent window, maximized below it. Clients connect on
//! $XDG_RUNTIME_DIR/wayland-0; the shell starts the programs named on its
//! command line as clients (by default /bin/stardust-demo).
//!
//! Init starts it as the unprivileged Stardust user, with stdout and stderr
//! going to the kernel log.
//!
//!     stardust-shell [client ...]

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const vc4 = @import("vc4");
const font = @import("font");
const server_mod = @import("server.zig");
const render = @import("render.zig");

const print = sys.print;

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    _ = level;
    print("stardust-shell: " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ") ++ fmt ++ "\n", args);
}

const default_client = "/bin/stardust-demo";

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print("stardust-shell: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    const runtime_dir = std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR") orelse {
        print("stardust-shell: XDG_RUNTIME_DIR is not set\n", .{});
        return error.NoRuntimeDir;
    };

    const dev = try vc4.device.open();
    const output = try vc4.drm.waitForOutput(dev.fd);
    var renderer = try render.Renderer.init(gpa, dev, output);
    print("stardust-shell: display {d}x{d}\n", .{ renderer.width, renderer.height });

    var bar: ?render.Bar = null;
    if (sys.readFileAlloc(gpa, font.system_font_path, 32 * 1024 * 1024)) |data| {
        if (font.Font.init(data)) |f| {
            bar = try render.Bar.init(gpa, f, renderer.width, renderer.height);
        } else |err| print("stardust-shell: font: {s}\n", .{@errorName(err)});
    } else |err| print("stardust-shell: cannot read {s}: {s}\n", .{ font.system_font_path, @errorName(err) });
    const bar_height: u32 = if (bar) |b| b.height else 0;

    var server = server_mod.Server.init(gpa, renderer.backend(), .{
        .x = 0,
        .y = @intCast(bar_height),
        .width = renderer.width,
        .height = renderer.height - bar_height,
    });

    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/wayland-0", .{runtime_dir});
    const listener = try listen(path);
    print("stardust-shell: listening on {s}\n", .{path});

    // Start the clients.
    var args = init.args.iterate();
    _ = args.skip();
    var started = false;
    while (args.next()) |client| {
        _ = spawn(client, runtime_dir);
        started = true;
    }
    if (!started) _ = spawn(default_client, runtime_dir);

    const start = sys.nowNs();
    var next_tick: u64 = start;
    var last_title: [64]u8 = undefined;
    var last_title_len: usize = 0;
    while (true) {
        reapChildren();

        // Wait for clients, or the next clock tick, or nothing if a frame
        // is due.
        var fds: [33]linux.pollfd = undefined;
        fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
        const n_clients = @min(server.clients.items.len, fds.len - 1);
        for (server.clients.items[0..n_clients], 1..) |c, i| fds[i] = .{ .fd = c.conn.fd, .events = linux.POLL.IN, .revents = 0 };
        const now = sys.nowNs();
        const timeout: i32 = if (server.damaged) 0 else if (next_tick > now) @intCast((next_tick - now) / std.time.ns_per_ms + 1) else 0;
        _ = linux.poll(&fds, n_clients + 1, timeout);

        if (fds[0].revents != 0) {
            const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) == .SUCCESS) {
                _ = try server.addClient(@intCast(rc));
                print("stardust-shell: client connected\n", .{});
            }
        }
        // Clients may disconnect (and leave the list) while being handled.
        var i: usize = 0;
        while (i < server.clients.items.len) {
            const c = server.clients.items[i];
            const ready = for (fds[1 .. n_clients + 1]) |f| {
                if (f.fd == c.conn.fd) break f.revents != 0;
            } else false;
            if (ready and !server.dispatch(c)) {
                print("stardust-shell: client disconnected\n", .{});
                continue;
            }
            i += 1;
        }

        // The bar: once a second, or when the title changes.
        const top = server.topWindow();
        const title = if (top) |t| t.title() else "";
        const t_now = sys.nowNs();
        const title_changed = !std.mem.eql(u8, title, last_title[0..last_title_len]);
        if (bar) |*b| if (t_now >= next_tick or title_changed) {
            last_title_len = @min(title.len, last_title.len);
            @memcpy(last_title[0..last_title_len], title[0..last_title_len]);
            b.draw(title, (t_now - start) / std.time.ns_per_s) catch {};
            try renderer.setBar(b.pixels, b.width, b.height);
            server.damaged = true;
        };
        if (t_now >= next_tick) next_tick = start + ((t_now - start) / std.time.ns_per_s + 1) * std.time.ns_per_s;

        if (server.damaged) {
            const window: ?render.Window = if (top) |t| .{
                .texture = t.xdg.surface.?.texture().?,
                .x = server.work_area.x,
                .y = server.work_area.y,
                .clip = server.work_area,
            } else null;
            renderer.drawFrame(window) catch |err| print("stardust-shell: frame failed: {s}\n", .{@errorName(err)});
            server.framePresented(@truncate((sys.nowNs() - start) / std.time.ns_per_ms));
        } else server.flushClients();
    }
}

/// Creates the listening socket, replacing a stale one.
fn listen(path: [:0]const u8) !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer sys.close(fd);
    _ = linux.unlink(path);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    _ = try sys.check(linux.listen(fd, 8));
    return fd;
}

/// Starts a client program, with the Wayland environment.
fn spawn(program: [*:0]const u8, runtime_dir: [:0]const u8) ?linux.pid_t {
    var env_buf: [160]u8 = undefined;
    const runtime_env = std.fmt.bufPrintZ(&env_buf, "XDG_RUNTIME_DIR={s}", .{runtime_dir}) catch return null;
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        print("stardust-shell: cannot start {s}: fork failed\n", .{program});
        return null;
    }
    if (rc != 0) {
        print("stardust-shell: started {s} (pid {d})\n", .{ program, rc });
        return @intCast(rc);
    }
    const argv = [_:null]?[*:0]const u8{program};
    const envp = [_:null]?[*:0]const u8{ "HOME=/", "PATH=/bin", "WAYLAND_DISPLAY=wayland-0", runtime_env.ptr };
    const err = linux.errno(linux.execve(program, &argv, &envp));
    print("stardust-shell: cannot run {s} ({s})\n", .{ program, @tagName(err) });
    linux.exit(127);
}

fn reapChildren() void {
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        if (linux.W.IFEXITED(status)) {
            print("stardust-shell: client {d} exited with status {d}\n", .{ rc, linux.W.EXITSTATUS(status) });
        } else if (linux.W.IFSIGNALED(status)) {
            print("stardust-shell: client {d} killed by signal {d}\n", .{ rc, linux.W.TERMSIG(status) });
        }
    }
}

test {
    _ = @import("server.zig");
    _ = @import("server_test.zig");
}
