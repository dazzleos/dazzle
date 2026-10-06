//! The system's clipboard, for text, over Wayland (wl_data_device): what
//! the toolkit's `Ui.clipboard` is given (`ui.Clipboard.of(&window.clipboard)`).
//!
//! Copying makes a data source offering the text, set as the selection
//! (the shell takes it only from the window with the keyboard, with the
//! serial of the input that asked); the shell asks for it (`send`) when
//! another client pastes. Pasting asks the clipboard's offer for text
//! through a pipe, and waits a moment for it. Text this window copied is
//! pasted from its own copy, without the shell.

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

    /// The clipboard's text (in `a`), if it has any: this window's own
    /// copy, or asked of the client that copied it.
    pub fn paste(c: *Clipboard, a: std.mem.Allocator) ?[]const u8 {
        if (c.source != null) return a.dupe(u8, c.text) catch null;
        const offer = c.offer orelse return null;
        const mime = mime_types[c.offer_mime orelse return null];
        var fds: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        defer _ = linux.close(fds[0]);
        // The write end goes to the shell (and is closed here once sent).
        var m = (client.Proxy{ .display = c.conn, .id = offer }).request(p.wl_data_offer.request.receive) catch {
            _ = linux.close(fds[1]);
            return null;
        };
        m.string(mime).fd(fds[1]).end();
        c.conn.flush() catch return null;
        return readAll(a, fds[0]);
    }

    /// What `fd` holds until its end, waiting up to `paste_timeout_ms`.
    fn readAll(a: std.mem.Allocator, fd: linux.fd_t) ?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        var waited: i32 = 0;
        while (out.items.len < max_paste) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            if (linux.poll(&pfd, 1, 50) == 0) {
                waited += 50;
                if (waited >= paste_timeout_ms) break;
                continue;
            }
            const n = linux.read(fd, &buf, buf.len);
            if (linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            out.appendSlice(a, buf[0..n]) catch break;
        }
        return out.toOwnedSlice(a) catch {
            out.deinit(a);
            return null;
        };
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
