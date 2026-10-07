//! The system's clipboard, for text, over Wayland (wl_data_device): what
//! the toolkit's `Ui.clipboard` is given (`ui.Clipboard.of(&window.clipboard)`).
//!
//! Copying makes a data source offering the text, set as the selection
//! (the shell takes it only from the window with the keyboard, with the
//! serial of the input that asked); the shell asks for it (`send`) when
//! another client pastes. Pasting asks the clipboard's offer for text
//! through a pipe and returns at once: the text comes to a `Sink` once it
//! has all arrived, read as the window's event loop sees it come
//! (`Window.wait` and `poll` watch the pipe, and call `service`), or
//! nothing if it does not come within `paste_timeout_ms`. Text this window
//! copied is pasted from its own copy, without the shell, at once.

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

/// The text types offered, and taken in this order of preference.
const mime_types = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" };

/// The most text pasted.
pub const max_paste = 1024 * 1024;
/// How long pasting waits for the text.
pub const paste_timeout_ms = 1000;

/// Where pasted text goes: `f(ctx, text)`, with the text (valid during the
/// call), or null if there was none.
pub const Sink = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, text: ?[]const u8) void,
};

fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub const Clipboard = struct {
    gpa: std.mem.Allocator,
    conn: *client.Display = undefined,
    device: ?client.Proxy = null,
    manager: ?client.Proxy = null,
    seat: ?client.Proxy = null,
    /// The serial of the latest key or button press (set by the window).
    serial: u32 = 0,
    /// What the clipboard holds (an offer), and the best text type it
    /// has, if any.
    offer: ?u32 = null,
    offer_mime: ?usize = null,
    /// An offer being described (its types come before the selection).
    incoming: ?u32 = null,
    incoming_mime: ?usize = null,
    /// What this window copied, while it is the selection.
    source: ?client.Proxy = null,
    text: []u8 = &.{},
    /// A paste under way: the pipe it comes through (non-blocking), what
    /// has come, where it goes, and when to give up.
    pending: ?struct { fd: linux.fd_t, got: std.ArrayList(u8) = .empty, sink: Sink, deadline_ms: u64 } = null,

    /// Starts using the data device of `seat`, if the shell has one.
    pub fn attach(c: *Clipboard, conn: *client.Display, manager: ?client.Proxy, seat: ?client.Proxy) !void {
        c.conn = conn;
        c.manager = manager;
        c.seat = seat;
        const m = manager orelse return;
        const s = seat orelse return;
        const device = try conn.newObject(.{ .ptr = c, .handler = deviceEvent });
        var req = try m.request(p.wl_data_device_manager.request.get_data_device);
        req.uint(device.id).uint(s.id).end();
        c.device = device;
    }

    pub fn deinit(c: *Clipboard) void {
        c.cancelPaste();
        c.gpa.free(c.text);
        c.text = &.{};
    }

    /// Puts `text` on the clipboard.
    pub fn copy(c: *Clipboard, text: []const u8) void {
        const manager = c.manager orelse return;
        const device = c.device orelse return;
        c.dropSource();
        c.text = c.gpa.dupe(u8, text) catch return;
        const source = c.conn.newObject(.{ .ptr = c, .handler = sourceEvent }) catch return;
        var m = manager.request(p.wl_data_device_manager.request.create_data_source) catch return;
        m.uint(source.id).end();
        for (mime_types) |mime| {
            m = source.request(p.wl_data_source.request.offer) catch return;
            m.string(mime).end();
        }
        m = device.request(p.wl_data_device.request.set_selection) catch return;
        m.uint(source.id).uint(c.serial).end();
        c.source = source;
        c.conn.flush() catch {};
    }

    /// Asks for the clipboard's text, which goes to `sink` (once; null if
    /// it has none): this window's own copy at once, or what the client
    /// that copied it writes, as it comes (see `service`). Another paste
    /// under way is dropped (its sink never called).
    pub fn paste(c: *Clipboard, sink: Sink) void {
        c.cancelPaste();
        if (c.source != null) return sink.f(sink.ctx, c.text);
        const offer = c.offer orelse return sink.f(sink.ctx, null);
        const mime = mime_types[c.offer_mime orelse return sink.f(sink.ctx, null)];
        var fds: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return sink.f(sink.ctx, null);
        // Only this end is non-blocking: the writer's is as it likes.
        const flags = linux.fcntl(fds[0], linux.F.GETFL, 0);
        _ = linux.fcntl(fds[0], linux.F.SETFL, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
        // The write end goes to the shell (and is closed here once sent).
        var m = (client.Proxy{ .display = c.conn, .id = offer }).request(p.wl_data_offer.request.receive) catch {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
            return sink.f(sink.ctx, null);
        };
        m.string(mime).fd(fds[1]).end();
        c.conn.flush() catch {};
        c.pending = .{ .fd = fds[0], .sink = sink, .deadline_ms = nowMs() + paste_timeout_ms };
    }

    /// The pipe a paste comes through, for the event loop to wait on.
    pub fn pasteFd(c: *const Clipboard) ?linux.fd_t {
        return if (c.pending) |pd| pd.fd else null;
    }

    /// How long until a paste under way gives up (null if none is).
    pub fn pasteTimeoutMs(c: *const Clipboard) ?u64 {
        const pd = c.pending orelse return null;
        return pd.deadline_ms -| nowMs();
    }

    /// Reads what has come of a paste under way, without waiting; once it
    /// has all come (or the time is up), gives it to its sink.
    pub fn service(c: *Clipboard) void {
        const pd = &(c.pending orelse return);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = linux.read(pd.fd, &buf, buf.len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return c.finishPaste(true);
                    pd.got.appendSlice(c.gpa, buf[0..@min(n, max_paste -| pd.got.items.len)]) catch return c.finishPaste(false);
                    if (pd.got.items.len >= max_paste) return c.finishPaste(true);
                },
                .INTR => {},
                .AGAIN => break,
                else => return c.finishPaste(false),
            }
        }
        if (nowMs() >= pd.deadline_ms) c.finishPaste(false);
    }

    /// Ends a paste: its text (or none) to its sink.
    fn finishPaste(c: *Clipboard, ok: bool) void {
        var pd = c.pending orelse return;
        c.pending = null;
        _ = linux.close(pd.fd);
        defer pd.got.deinit(c.gpa);
        pd.sink.f(pd.sink.ctx, if (ok) pd.got.items else null);
    }

    /// Drops a paste under way, without telling its sink.
    pub fn cancelPaste(c: *Clipboard) void {
        var pd = c.pending orelse return;
        c.pending = null;
        _ = linux.close(pd.fd);
        pd.got.deinit(c.gpa);
    }

    /// Forgets what this window copied (its source destroyed).
    fn dropSource(c: *Clipboard) void {
        if (c.source) |s| {
            if (s.request(p.wl_data_source.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            c.conn.forget(s.id);
        }
        c.source = null;
        c.gpa.free(c.text);
        c.text = &.{};
    }

    fn destroyOffer(c: *Clipboard, id: u32) void {
        if ((client.Proxy{ .display = c.conn, .id = id }).request(p.wl_data_offer.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        c.conn.forget(id);
    }

    fn deviceEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const c: *Clipboard = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_data_device.event.data_offer => {
                const id = r.uint() catch return;
                // One described but never made the selection is dropped.
                if (c.incoming) |old| if (old != c.offer) c.destroyOffer(old);
                c.incoming = id;
                c.incoming_mime = null;
                d.setListener(id, .{ .ptr = c, .handler = offerEvent }) catch {};
            },
            p.wl_data_device.event.selection => {
                const id = r.uint() catch return;
                if (c.offer) |old| if (old != id) c.destroyOffer(old);
                c.offer = if (id == 0) null else id;
                c.offer_mime = if (id != 0 and c.incoming == id) c.incoming_mime else null;
                if (c.incoming == id) c.incoming = null;
            },
            else => {},
        }
    }

    fn offerEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const c: *Clipboard = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_data_offer.event.offer or c.incoming != id) return;
        const mime = (r.string() catch return) orelse return;
        for (mime_types, 0..) |t, i| if (std.mem.eql(u8, t, mime)) {
            if (c.incoming_mime == null or i < c.incoming_mime.?) c.incoming_mime = i;
        };
    }

    fn sourceEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const c: *Clipboard = @ptrCast(@alignCast(ptr.?));
        const source = c.source orelse return;
        if (source.id != id) return;
        switch (opcode) {
            p.wl_data_source.event.send => {
                _ = r.string() catch return;
                const fd = r.fd() catch return;
                defer _ = linux.close(fd);
                writeAll(fd, c.text);
            },
            // Another client copied: this window's copy is not needed.
            p.wl_data_source.event.cancelled => c.dropSource(),
            else => {},
        }
    }

    fn writeAll(fd: linux.fd_t, data: []const u8) void {
        var at: usize = 0;
        var waited: i32 = 0;
        while (at < data.len) {
            const n = linux.write(fd, data[at..].ptr, data.len - at);
            switch (linux.errno(n)) {
                .SUCCESS => at += n,
                .INTR => {},
                // A full pipe the reader is slow to empty: wait a little.
                .AGAIN => {
                    var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&pfd, 1, 50);
                    waited += 50;
                    if (waited >= paste_timeout_ms) return;
                },
                else => return,
            }
        }
    }
};
