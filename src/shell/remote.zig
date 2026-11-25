//! Remote control (see `sys.remote`): an HTTP server, on `sys.remote.port`,
//! while it is turned on. Each request is a GET carrying the code
//! (`?code=123456`); one at a time, answered and closed:
//!
//!     /status                       the screen, the pointer, the windows
//!                                   and the apps, as text
//!     /screenshot                   the screen, as a PNG
//!     /screenshot?bands=1           the same, drawn a band at a time (as
//!                                   when video memory is short), to try it
//!     /pointer?x=&y=                moves the pointer there
//!     /move?dx=&dy=                 moves the pointer by that much (as a
//!                                   mouse does: an app that has taken
//!                                   the pointer, as Motu does, turns)
//!     /click?x=&y=[&button=right]   moves the pointer there and clicks
//!     /tap?x=&y=                    touches the screen there (as a
//!                                   touchscreen does), and lets go
//!     /swipe?x=&y=&x2=&y2=[&fingers=4]
//!                                   touches the screen at (x, y), moves
//!                                   to (x2, y2) and lets go (with more
//!                                   fingers, side by side, 60 apart)
//!     /button?button=left&pressed=1 presses (or lets go of) a button
//!     /scroll?dy=                   scrolls (positive: down)
//!     /key?key=28[&pressed=1]       presses a key (a Linux key code) and
//!                                   lets it go, or only one of those
//!     /type?text=                   types the text (US keys: letters,
//!                                   digits, space and common punctuation);
//!                                   503 if input already queued leaves no
//!                                   room for it all (try again)
//!     /launch?app=motu     opens an app, or brings it to the top
//!     /quit?app=motu[&force=1]
//!                                   asks the app's windows to close (or
//!                                   ends it at once)
//!     /window?do=place&x=&y=&w=&h=[&app=motu]
//!                                   puts the window there, that big
//!     /window?do=maximize[&app=motu]
//!                                   maximizes, restores, makes fullscreen
//!                                   (fullscreen), leaves fullscreen
//!                                   (windowed), closes or raises the top
//!                                   window (of the app, or by its title)
//!     /notify?title=[&body=][&icon=warning]
//!                                   shows a notification (its icon one
//!                                   of the shell's own: photo_camera,
//!                                   warning, check, schedule or
//!                                   notifications, the default)
//!     /updates                      how updates stand, as text
//!     /check                        checks for updates now
//!     /install?app=motu             checks, then installs that app (one
//!                                   not installed yet)
//!     /update                       checks, then installs everything
//!                                   newer (the system starts when the
//!                                   computer restarts)
//!     /restart                      restarts the computer
//!     /source                       where software comes from (the
//!                                   official store, or a custom server),
//!                                   its URL and key, as text
//!     /source?url=official          the official store
//!     /source?url=https://...[&key=<64 hex digits>]
//!                                   a custom server, and its key (as
//!                                   Settings' Software source page sets)
//!
//! A wrong code (or none) gets 403. The shell carries out each command
//! (`Server.accept` gives it), and answers (`Request.respond`).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

/// What a request asks for.
pub const Command = union(enum) {
    status,
    /// Whether to draw it a band at a time, even with room for all of it.
    screenshot: bool,
    pointer: [2]f64,
    move: [2]f64,
    click: struct { x: f64, y: f64, button: u32 },
    button: struct { button: u32, pressed: bool },
    scroll: f64,
    key: struct { code: u32, pressed: ?bool },
    /// The text (in the request's buffer).
    type: []const u8,
    launch: []const u8,
    /// The app to install (in the request's buffer).
    install: []const u8,
    /// The app (in the request's buffer); ended at once, or asked to close.
    quit: struct { app: []const u8, force: bool },
    /// What to do to the top window, of `app` (its app ID or title) or of
    /// all.
    window: struct { action: WindowAction, app: ?[]const u8 },
    /// Where to put the top window (of `app`), and how big.
    place: struct { app: ?[]const u8, x: i32, y: i32, width: u32, height: u32 },
    /// A notification to show: its title and body (in the request's
    /// buffer), and its icon's name, if one was given.
    notify: struct { title: []const u8, body: []const u8, icon: ?[]const u8 },
    /// A touch at (x, y) on the screen, down and up.
    tap: [2]f64,
    /// A touch from (x, y) to (x2, y2): down, moved along, and up; with
    /// `fingers` side by side.
    swipe: struct { from: [2]f64, to: [2]f64, fingers: u8 = 1 },
    updates,
    check,
    update,
    restart,
    /// Where software comes from: to say (null), or to set (the URL, in
    /// the request's buffer, "official" for the official store; and the
    /// key, "" for none).
    source: ?struct { url: []const u8, key: []const u8 },
};

/// What `/window` does (as `Server.WindowAction`).
pub const WindowAction = enum { maximize, restore, fullscreen, windowed, close, raise };

/// A request read, its command to be carried out and answered.
pub const Request = struct {
    fd: linux.fd_t,
    command: Command,
    /// The request's text, which `command`'s strings are in.
    buf: [4096]u8 = undefined,
    text_buf: [1024]u8 = undefined,

    /// Answers it (with `body` as `content_type`), and closes it.
    pub fn respond(r: *Request, status: []const u8, content_type: []const u8, body: []const u8) void {
        var head_buf: [160]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch "";
        writeAll(r.fd, head);
        writeAll(r.fd, body);
        sys.close(r.fd);
    }
};

pub const Server = struct {
    listener: ?linux.fd_t = null,
    code: ?u32 = null,

    /// Listening while `setting` says it is on (with its code); not
    /// otherwise. Returns whether that changed.
    pub fn configure(s: *Server, setting: sys.remote.Setting) bool {
        const was = s.code;
        s.code = setting.code;
        if (setting.code != null and s.listener == null) {
            s.listener = listen() catch |err| blk: {
                sys.print(sys.log_warning ++ "dazzle-shell: remote control cannot listen on port {d}: {s}\n", .{ sys.remote.port, @errorName(err) });
                break :blk null;
            };
            if (s.listener != null) sys.print("dazzle-shell: remote control on, port {d}\n", .{sys.remote.port});
        } else if (setting.code == null) if (s.listener) |fd| {
            sys.close(fd);
            s.listener = null;
            sys.print("dazzle-shell: remote control off\n", .{});
        };
        return was != s.code;
    }

    /// The next request, if one is waiting (on `listener`) and asks for
    /// something with the right code; others are answered here.
    pub fn accept(s: *Server, out: *Request) bool {
        const lfd = s.listener orelse return false;
        const rc = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return false;
        const fd: linux.fd_t = @intCast(rc);
        // A client that sends nothing does not hold the shell up for long.
        const tv: linux.timeval = .{ .sec = 1, .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        out.* = .{ .fd = fd, .command = .status };
        var len: usize = 0;
        while (std.mem.indexOf(u8, out.buf[0..len], "\r\n\r\n") == null and len < out.buf.len) {
            const n = linux.read(fd, out.buf[len..].ptr, out.buf.len - len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            len += n;
        }
        switch (parse(out.buf[0..len], s.code orelse 0, &out.text_buf)) {
            .command => |c| {
                out.command = c;
                return true;
            },
            .forbidden => out.respond("403 Forbidden", "text/plain", "The code is wrong\n"),
            .not_found => out.respond("404 Not Found", "text/plain", "No such command\n"),
            .bad => out.respond("400 Bad Request", "text/plain", "Not a request this understands\n"),
        }
        return false;
    }
};

fn listen() !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer sys.close(fd);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
    var addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, sys.remote.port), .addr = 0 };
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    _ = try sys.check(linux.listen(fd, 4));
    return fd;
}

fn writeAll(fd: linux.fd_t, data: []const u8) void {
    var at: usize = 0;
    while (at < data.len) {
        const n = linux.write(fd, data[at..].ptr, data.len - at);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        at += n;
    }
}

const Parsed = union(enum) { command: Command, forbidden, not_found, bad };

/// The command in an HTTP request (its text so far), if it has the code.
fn parse(text: []const u8, code: u32, text_buf: []u8) Parsed {
    const line_end = std.mem.indexOf(u8, text, "\r\n") orelse return .bad;
    var parts = std.mem.tokenizeScalar(u8, text[0..line_end], ' ');
    if (!std.mem.eql(u8, parts.next() orelse return .bad, "GET")) return .bad;
    const target = parts.next() orelse return .bad;
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |i| target[i + 1 ..] else "";
    const given = std.fmt.parseInt(u32, param(query, "code") orelse return .forbidden, 10) catch return .forbidden;
    if (code == 0 or given != code) return .forbidden;
    const num = struct {
        fn f(qs: []const u8, name: []const u8) ?f64 {
            return std.fmt.parseFloat(f64, param(qs, name) orelse return null) catch null;
        }
    }.f;
    if (std.mem.eql(u8, path, "/status")) return .{ .command = .status };
    if (std.mem.eql(u8, path, "/screenshot")) return .{ .command = .{ .screenshot = if (param(query, "bands")) |v| std.mem.eql(u8, v, "1") else false } };
    if (std.mem.eql(u8, path, "/pointer")) return .{ .command = .{ .pointer = .{ num(query, "x") orelse return .bad, num(query, "y") orelse return .bad } } };
    if (std.mem.eql(u8, path, "/move")) return .{ .command = .{ .move = .{ num(query, "dx") orelse return .bad, num(query, "dy") orelse return .bad } } };
    if (std.mem.eql(u8, path, "/click")) return .{ .command = .{ .click = .{
        .x = num(query, "x") orelse return .bad,
        .y = num(query, "y") orelse return .bad,
        .button = buttonCode(param(query, "button") orelse "left") orelse return .bad,
    } } };
    if (std.mem.eql(u8, path, "/swipe")) return .{ .command = .{ .swipe = .{
        .from = .{ num(query, "x") orelse return .bad, num(query, "y") orelse return .bad },
        .to = .{ num(query, "x2") orelse return .bad, num(query, "y2") orelse return .bad },
        .fingers = @intFromFloat(std.math.clamp(num(query, "fingers") orelse 1, 1, 5)),
    } } };
    if (std.mem.eql(u8, path, "/tap")) return .{ .command = .{ .tap = .{ num(query, "x") orelse return .bad, num(query, "y") orelse return .bad } } };
    if (std.mem.eql(u8, path, "/button")) return .{ .command = .{ .button = .{
        .button = buttonCode(param(query, "button") orelse "left") orelse return .bad,
        .pressed = !std.mem.eql(u8, param(query, "pressed") orelse "1", "0"),
    } } };
    if (std.mem.eql(u8, path, "/scroll")) return .{ .command = .{ .scroll = num(query, "dy") orelse return .bad } };
    if (std.mem.eql(u8, path, "/key")) return .{ .command = .{ .key = .{
        .code = std.fmt.parseInt(u32, param(query, "key") orelse return .bad, 10) catch return .bad,
        .pressed = if (param(query, "pressed")) |p| !std.mem.eql(u8, p, "0") else null,
    } } };
    if (std.mem.eql(u8, path, "/type")) return .{ .command = .{ .type = decode(param(query, "text") orelse return .bad, text_buf) orelse return .bad } };
    if (std.mem.eql(u8, path, "/install")) return .{ .command = .{ .install = decode(param(query, "app") orelse return .bad, text_buf) orelse return .bad } };
    if (std.mem.eql(u8, path, "/launch")) return .{ .command = .{ .launch = decode(param(query, "app") orelse return .bad, text_buf) orelse return .bad } };
    if (std.mem.eql(u8, path, "/quit")) return .{ .command = .{ .quit = .{
        .app = decode(param(query, "app") orelse return .bad, text_buf) orelse return .bad,
        .force = std.mem.eql(u8, param(query, "force") orelse "0", "1"),
    } } };
    if (std.mem.eql(u8, path, "/window") and std.mem.eql(u8, param(query, "do") orelse "", "place")) {
        const int = struct {
            fn f(qs_: []const u8, name: []const u8, comptime T: type) ?T {
                return std.fmt.parseInt(T, param(qs_, name) orelse return null, 10) catch null;
            }
        }.f;
        return .{ .command = .{ .place = .{
            .app = if (param(query, "app")) |a| decode(a, text_buf) orelse return .bad else null,
            .x = int(query, "x", i32) orelse return .bad,
            .y = int(query, "y", i32) orelse return .bad,
            .width = int(query, "w", u32) orelse return .bad,
            .height = int(query, "h", u32) orelse return .bad,
        } } };
    }
    if (std.mem.eql(u8, path, "/window")) return .{ .command = .{ .window = .{
        .action = std.meta.stringToEnum(WindowAction, param(query, "do") orelse return .bad) orelse return .bad,
        .app = if (param(query, "app")) |a| decode(a, text_buf) orelse return .bad else null,
    } } };
    if (std.mem.eql(u8, path, "/notify")) {
        const half = text_buf.len / 2;
        return .{ .command = .{ .notify = .{
            .title = decode(param(query, "title") orelse return .bad, text_buf[0..half]) orelse return .bad,
            .body = if (param(query, "body")) |b| decode(b, text_buf[half..]) orelse return .bad else "",
            .icon = param(query, "icon"),
        } } };
    }
    if (std.mem.eql(u8, path, "/updates")) return .{ .command = .updates };
    if (std.mem.eql(u8, path, "/check")) return .{ .command = .check };
    if (std.mem.eql(u8, path, "/update")) return .{ .command = .update };
    if (std.mem.eql(u8, path, "/restart")) return .{ .command = .restart };
    if (std.mem.eql(u8, path, "/source")) {
        const raw = param(query, "url") orelse return .{ .command = .{ .source = null } };
        return .{ .command = .{ .source = .{
            .url = decode(raw, text_buf) orelse return .bad,
            .key = param(query, "key") orelse "",
        } } };
    }
    return .not_found;
}

/// A query parameter's value (still %-encoded).
fn param(query: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.tokenizeScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// A %-encoded value ("+" a space), in `buf`.
fn decode(v: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.len) : (n += 1) {
        if (n >= buf.len) return null;
        if (v[i] == '%' and i + 2 < v.len) {
            buf[n] = std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            buf[n] = if (v[i] == '+') ' ' else v[i];
            i += 1;
        }
    }
    return buf[0..n];
}

fn buttonCode(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "left")) return sys.evdev.btn_left;
    if (std.mem.eql(u8, name, "right")) return sys.evdev.btn_left + 1;
    if (std.mem.eql(u8, name, "middle")) return sys.evdev.btn_left + 2;
    return null;
}

/// The Linux key code typing `c` on US keys, and whether with Shift.
pub fn keyFor(c: u8) ?struct { code: u32, shift: bool } {
    const lower = "1234567890-=\tqwertyuiop[]\nasdfghjkl;'`\\zxcvbnm,./ ";
    const upper = "!@#$%^&*()_+\tQWERTYUIOP{}\nASDFGHJKL:\"~|ZXCVBNM<>? ";
    // Their codes, in the same order.
    const codes = [_]u8{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 57 };
    comptime std.debug.assert(lower.len == codes.len and upper.len == codes.len);
    if (std.mem.indexOfScalar(u8, lower, c)) |i| return .{ .code = codes[i], .shift = false };
    if (std.mem.indexOfScalar(u8, upper, c)) |i| return .{ .code = codes[i], .shift = true };
    return null;
}

/// Left Shift's key code.
pub const key_left_shift = 42;

const testing = std.testing;

test "requests are read with their code, and others turned away" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(Parsed.forbidden, parse("GET /status HTTP/1.1\r\n\r\n", 123456, &buf));
    try testing.expectEqual(Parsed.forbidden, parse("GET /status?code=111111 HTTP/1.1\r\n\r\n", 123456, &buf));
    try testing.expectEqual(Parsed.forbidden, parse("GET /status?code=0 HTTP/1.1\r\n\r\n", 0, &buf));
    try testing.expect(parse("GET /status?code=123456 HTTP/1.1\r\n\r\n", 123456, &buf).command == .status);
    try testing.expectEqual(Parsed.not_found, parse("GET /reboot?code=123456 HTTP/1.1\r\n\r\n", 123456, &buf));
    try testing.expectEqual(Parsed.bad, parse("POST /status?code=123456 HTTP/1.1\r\n\r\n", 123456, &buf));
    const note = parse("GET /notify?code=123456&title=Hello+there&body=It%27s%20me&icon=warning HTTP/1.1\r\n\r\n", 123456, &buf).command.notify;
    try testing.expectEqualStrings("Hello there", note.title);
    try testing.expectEqualStrings("It's me", note.body);
    try testing.expectEqualStrings("warning", note.icon.?);
    try testing.expectEqual(Parsed.bad, parse("GET /notify?code=123456&body=x HTTP/1.1\r\n\r\n", 123456, &buf));
    const click = parse("GET /click?code=123456&x=10.5&y=20&button=right HTTP/1.1\r\n\r\n", 123456, &buf).command.click;
    try testing.expectEqual(@as(f64, 10.5), click.x);
    try testing.expectEqual(sys.evdev.btn_left + 1, click.button);
    try testing.expectEqualStrings("Hello, there!", parse("GET /type?code=123456&text=Hello%2C+there%21 HTTP/1.1\r\n\r\n", 123456, &buf).command.type);
    try testing.expectEqual(@as(?bool, false), parse("GET /key?code=123456&key=28&pressed=0 HTTP/1.1\r\n\r\n", 123456, &buf).command.key.pressed);
    try testing.expectEqualStrings("motu", parse("GET /launch?code=123456&app=motu HTTP/1.1\r\n\r\n", 123456, &buf).command.launch);
    try testing.expectEqual(false, parse("GET /screenshot?code=123456 HTTP/1.1\r\n\r\n", 123456, &buf).command.screenshot);
    try testing.expectEqual(true, parse("GET /screenshot?code=123456&bands=1 HTTP/1.1\r\n\r\n", 123456, &buf).command.screenshot);
}

test "apps, windows and updates are controlled directly" {
    var buf: [64]u8 = undefined;
    const quit = parse("GET /quit?code=123456&app=motu&force=1 HTTP/1.1\r\n\r\n", 123456, &buf).command.quit;
    try testing.expectEqualStrings("motu", quit.app);
    try testing.expect(quit.force);
    try testing.expect(!parse("GET /quit?code=123456&app=motu HTTP/1.1\r\n\r\n", 123456, &buf).command.quit.force);
    const w = parse("GET /window?code=123456&do=fullscreen&app=Motu HTTP/1.1\r\n\r\n", 123456, &buf).command.window;
    try testing.expectEqual(WindowAction.fullscreen, w.action);
    try testing.expectEqualStrings("Motu", w.app.?);
    try testing.expect(parse("GET /window?code=123456&do=maximize HTTP/1.1\r\n\r\n", 123456, &buf).command.window.app == null);
    try testing.expect(parse("GET /window?code=123456&do=explode HTTP/1.1\r\n\r\n", 123456, &buf) == .bad);
    const pl = parse("GET /window?code=123456&do=place&x=10&y=-5&w=800&h=600&app=Chat HTTP/1.1\r\n\r\n", 123456, &buf).command.place;
    try testing.expectEqual(@as(i32, -5), pl.y);
    try testing.expectEqual(@as(u32, 800), pl.width);
    try testing.expectEqualStrings("Chat", pl.app.?);
    try testing.expect(parse("GET /window?code=123456&do=place&x=10 HTTP/1.1\r\n\r\n", 123456, &buf) == .bad);
    try testing.expect(parse("GET /update?code=123456 HTTP/1.1\r\n\r\n", 123456, &buf).command == .update);
    try testing.expectEqual([2]f64{ 10, 20 }, parse("GET /tap?code=123456&x=10&y=20 HTTP/1.1\r\n\r\n", 123456, &buf).command.tap);
    const sw = parse("GET /swipe?code=123456&x=10&y=20&x2=30&y2=200&fingers=4 HTTP/1.1\r\n\r\n", 123456, &buf).command.swipe;
    try testing.expectEqual([2]f64{ 10, 20 }, sw.from);
    try testing.expectEqual([2]f64{ 30, 200 }, sw.to);
    try testing.expectEqual(@as(u8, 4), sw.fingers);
    try testing.expect(parse("GET /restart?code=123456 HTTP/1.1\r\n\r\n", 123456, &buf).command == .restart);
    // Not without the code.
    try testing.expect(parse("GET /restart HTTP/1.1\r\n\r\n", 123456, &buf) == .forbidden);
    // Where software comes from: said, or set.
    try testing.expect(parse("GET /source?code=123456 HTTP/1.1\r\n\r\n", 123456, &buf).command.source == null);
    const official = parse("GET /source?code=123456&url=official HTTP/1.1\r\n\r\n", 123456, &buf).command.source.?;
    try testing.expectEqualStrings("official", official.url);
    try testing.expectEqualStrings("", official.key);
    const custom = parse("GET /source?code=123456&url=https%3A%2F%2F192.168.1.2%3A8443&key=ab12 HTTP/1.1\r\n\r\n", 123456, &buf).command.source.?;
    try testing.expectEqualStrings("https://192.168.1.2:8443", custom.url);
    try testing.expectEqualStrings("ab12", custom.key);
}

test "text is typed with US keys" {
    try testing.expectEqual(@as(u32, 30), keyFor('a').?.code);
    try testing.expect(keyFor('A').?.shift);
    try testing.expectEqual(@as(u32, 57), keyFor(' ').?.code);
    try testing.expectEqual(@as(u32, 52), keyFor('.').?.code);
    try testing.expectEqual(@as(u32, 9), keyFor('*').?.code);
    try testing.expect(keyFor(0x7f) == null);
}
