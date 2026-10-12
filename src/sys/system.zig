//! The system manager's protocol. Init runs the manager
//! (src/init/system.zig), which on the first run prepares the SD card's
//! free space for files and sets the computer's name, and later installs
//! updates of the system into the OS slot not in use. It listens on a
//! socket, /os/sockets/system, and answers only the setup and settings
//! apps, checked by the program the connecting process runs.
//!
//! A client connects, sends a request and reads the report until the
//! manager closes the connection. The requests are:
//!
//!     status
//!     prepare                  give the card's free space a filesystem (setup)
//!     hostname <hostname>      name the computer (setup)
//!     finish <hostname>        name the computer, and finish setting up (setup)
//!     update <sha256>          install the system in update_archive, whose
//!                              SHA-256 this is, into the slot not in use,
//!                              and start that slot next time (settings)
//!     restart                  restart the computer (settings)
//!     locale <language> <keyboard>
//!                              the language and keyboard (setup and
//!                              settings): kept in /data/system/locale
//!                              (once there is a /data)
//!     video_memory <MiB>       how much memory the GPU may have, from the
//!                              next start (settings): see `video_memory`
//!
//! and the report:
//!
//!     storage preparing 42
//!     hostname awesome-elephant
//!     slot a
//!     next a
//!     version a 1791331200 de14aa2
//!     version b -
//!     update none
//!     locale en-GB gb
//!     video_memory 128 256
//!     end
//!
//! "storage" is how the card's free space is: "none" (there is no card),
//! "unprepared", "preparing" with how far it has got (in percent),
//! "ready", or "failed" with why. "slot" is the OS slot running, "next" the
//! one the firmware starts next time (config.txt's os_prefix), and
//! "version" what each slot holds ("-": nothing, or not known). "update"
//! is how installing an update goes: "none", "installing", "ready" (the
//! next start runs it) or "failed" with why ("did_not_start" when it was
//! installed but did not work, and the system before is running again).
//! "video_memory" is the memory the GPU may have now and from the next
//! start, in MiB ("-": not known). A client the manager does not
//! serve, or a request it does not serve that client, gets "denied\n".

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const locale = @import("locale");

/// The manager's socket.
pub const socket_path = "/os/sockets/system";

/// The programs the manager answers.
pub const setup_program = "/os/shell/dazzle-setup";
pub const settings_program = "/os/shell/dazzle-settings";

/// Where the card's free space is mounted, and the files in it.
pub const data_dir = "/data";
/// The system's settings (owned by root).
pub const config_dir = "/data/system";
/// The computer's name.
pub const hostname_file = "/data/system/hostname";
/// There once setup has finished.
pub const setup_done_file = "/data/system/setup-done";
/// The user's files.
pub const user_dir = "/data/user";
/// The apps installed, each in its own folder: /data/apps/<name>/<name> is
/// its program (the user's).
pub const apps_dir = data_dir ++ "/apps";
/// Where Settings downloads updates (the user's).
pub const update_dir = "/data/update";
/// An update: the files of an OS slot, as a tar archive of the folder "os",
/// compressed with xz (see tools/mkos.zig).
pub const update_archive = update_dir ++ "/dazzle-os.tar.xz";

/// Video memory: the kernel's CMA pool, which every buffer the GPU uses
/// comes from (the V3D has no MMU), and which the rest of the system can
/// use only for memory it can move. Its size is cma=<n>M on the kernel's
/// command line, the slots' cmdline.txt, so a change applies from the next
/// start (and updates keep it: they copy the running slot's command line).
/// The sizes offered, in MiB.
pub const video_memory_sizes = [_]u16{ 64, 96, 128, 192, 256, 384 };

/// Whether `mib` may be chosen on a computer with `ram_mib` of memory (as
/// Linux has it): one of the sizes, and no more than half of it, so the
/// system and the apps keep enough.
pub fn videoMemoryAllowed(mib: u16, ram_mib: u64) bool {
    if (std.mem.indexOfScalar(u16, &video_memory_sizes, mib) == null) return false;
    return @as(u64, mib) * 2 <= ram_mib;
}

pub const StorageState = enum { none, unprepared, preparing, ready, failed };

pub const Failure = enum {
    none,
    /// Too little space after the system's partition.
    too_small,
    /// The partition table has no room for another partition.
    no_room,
    /// Reading or writing the card failed.
    io,
    /// The new filesystem could not be mounted.
    mount,

    pub fn label(f: Failure) []const u8 {
        return switch (f) {
            .none => "",
            .too_small => "there is too little free space on the card",
            .no_room => "the card's partition table is full",
            .io => "the card could not be written",
            .mount => "the new filesystem could not be used",
        };
    }
};

pub const Request = union(enum) {
    status,
    prepare,
    hostname: Hostname,
    finish: Hostname,
    /// The archive's SHA-256, in hex.
    update: [64]u8,
    restart,
    locale: locale.Settings,
    /// In MiB, one of `video_memory_sizes`.
    video_memory: u16,

    pub fn parse(line: []const u8) ?Request {
        var f = std.mem.tokenizeAny(u8, line, " \n");
        const kind = f.next() orelse return null;
        if (std.mem.eql(u8, kind, "status")) return .status;
        if (std.mem.eql(u8, kind, "prepare")) return .prepare;
        if (std.mem.eql(u8, kind, "hostname")) return .{ .hostname = Hostname.parse(f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "finish")) return .{ .finish = Hostname.parse(f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "restart")) return .restart;
        if (std.mem.eql(u8, kind, "locale")) return .{ .locale = .{
            .language = locale.Language.fromCode(f.next() orelse return null) orelse return null,
            .keyboard = locale.Keyboard.fromCode(f.next() orelse return null) orelse return null,
        } };
        if (std.mem.eql(u8, kind, "video_memory")) {
            const mib = std.fmt.parseInt(u16, f.next() orelse return null, 10) catch return null;
            if (std.mem.indexOfScalar(u16, &video_memory_sizes, mib) == null) return null;
            return .{ .video_memory = mib };
        }
        if (std.mem.eql(u8, kind, "update")) {
            const hex = f.next() orelse return null;
            if (hex.len != 64) return null;
            for (hex) |c| if (!std.ascii.isHex(c)) return null;
            var r: Request = .{ .update = undefined };
            for (&r.update, hex) |*d, c| d.* = std.ascii.toLower(c);
            return r;
        }
        return null;
    }

    /// Whether `client` may ask this.
    pub fn allowedFor(r: Request, client: Client) bool {
        return switch (r) {
            .status => true,
            .prepare, .hostname, .finish => client == .setup,
            .update, .restart, .video_memory => client == .settings,
            .locale => true,
        };
    }
};

pub const Client = enum { setup, settings };

/// What an OS slot holds: when its source was committed (seconds since
/// 1970: newer systems have later times) and the commit (Dazzle's and the
/// kernel's, "<commit>-<kernel commit>"). The build writes it in the slot,
/// as "version": "<time> <commit>\n".
pub const Version = struct {
    time: u64 = 0,
    commit_buf: [40]u8 = undefined,
    commit_len: u8 = 0,

    pub const file_name = "version";

    pub fn commit(v: *const Version) []const u8 {
        return v.commit_buf[0..v.commit_len];
    }

    pub fn parse(text: []const u8) ?Version {
        var f = std.mem.tokenizeAny(u8, text, " \n");
        const time = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
        return init(time, f.next() orelse return null);
    }

    pub fn init(time: u64, hash: []const u8) ?Version {
        if (hash.len == 0 or hash.len > 40) return null;
        for (hash) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return null;
        var v: Version = .{ .time = time, .commit_len = @intCast(hash.len) };
        @memcpy(v.commit_buf[0..hash.len], hash);
        return v;
    }

    pub fn eql(a: *const Version, b: *const Version) bool {
        return std.mem.eql(u8, a.commit(), b.commit());
    }
};

pub const UpdateState = enum { none, installing, ready, failed };

pub const UpdateFailure = enum {
    none,
    /// The OS slots are not there (no card), or the other is still being made.
    busy,
    /// The archive is not there, or not what Settings downloaded.
    archive,
    /// Reading or writing the card failed.
    io,
    /// It was installed, but did not start properly: the system before it
    /// is running again.
    did_not_start,

    pub fn label(f: UpdateFailure) []const u8 {
        return switch (f) {
            .none => "",
            .busy => "the system cannot be updated yet",
            .archive => "the download was not right",
            .io => "the card could not be written",
            .did_not_start => "it did not start properly, so this version is running again",
        };
    }
};

/// A computer's name: 1 to 63 lowercase letters, digits and hyphens, not
/// starting or ending with a hyphen (a DNS label).
pub const Hostname = struct {
    buf: [63]u8 = undefined,
    len: u8 = 0,

    pub fn slice(h: *const Hostname) []const u8 {
        return h.buf[0..h.len];
    }

    pub fn parse(s: []const u8) ?Hostname {
        if (s.len == 0 or s.len > 63 or s[0] == '-' or s[s.len - 1] == '-') return null;
        for (s) |c| switch (c) {
            'a'...'z', '0'...'9', '-' => {},
            else => return null,
        };
        var h: Hostname = .{ .len = @intCast(s.len) };
        @memcpy(h.buf[0..s.len], s);
        return h;
    }
};

pub const Report = struct {
    storage: StorageState = .none,
    /// How far preparing has got, in percent.
    progress: u8 = 0,
    failure: Failure = .none,
    hostname: Hostname = .{},
    /// The OS slot running, and the one the firmware starts next.
    slot: ?u8 = null,
    next: ?u8 = null,
    /// What slots A and B hold.
    versions: [2]?Version = .{ null, null },
    update: UpdateState = .none,
    update_failure: UpdateFailure = .none,
    /// The language and keyboard chosen.
    locale: locale.Settings = .{},
    /// The memory the GPU may have now, and from the next start, in MiB.
    video_memory_now: ?u16 = null,
    video_memory_next: ?u16 = null,
    /// The manager refused the client.
    denied: bool = false,

    pub fn version(r: *const Report, slot: u8) ?*const Version {
        if (slot != 'a' and slot != 'b') return null;
        return if (r.versions[slot - 'a']) |*v| v else null;
    }

    /// Whether `v` is in either slot.
    pub fn holds(r: *const Report, v: *const Version) bool {
        for (&r.versions) |*s| if (s.*) |*have| if (have.eql(v)) return true;
        return false;
    }

    pub fn write(r: *const Report, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print("storage {s}", .{@tagName(r.storage)}) catch {};
        switch (r.storage) {
            .preparing => w.print(" {d}", .{r.progress}) catch {},
            .failed => w.print(" {s}", .{@tagName(r.failure)}) catch {},
            else => {},
        }
        w.print("\nhostname {s}\n", .{if (r.hostname.len > 0) r.hostname.slice() else "-"}) catch {};
        if (r.slot) |s| w.print("slot {c}\n", .{s}) catch {};
        if (r.next) |s| w.print("next {c}\n", .{s}) catch {};
        for (r.versions, "ab") |v, s| {
            if (v) |*have| w.print("version {c} {d} {s}\n", .{ s, have.time, have.commit() }) catch {} else w.print("version {c} -\n", .{s}) catch {};
        }
        w.print("update {s}", .{@tagName(r.update)}) catch {};
        if (r.update == .failed) w.print(" {s}", .{@tagName(r.update_failure)}) catch {};
        w.print("\nlocale {s} {s}", .{ r.locale.language.code(), r.locale.keyboard.code() }) catch {};
        w.writeAll("\nvideo_memory") catch {};
        for ([_]?u16{ r.video_memory_now, r.video_memory_next }) |v| if (v) |mib| w.print(" {d}", .{mib}) catch {} else w.writeAll(" -") catch {};
        w.writeAll("\nend\n") catch {};
        return w.buffered();
    }

    /// Reads a report; null if it is incomplete (no "end").
    pub fn parse(text: []const u8) ?Report {
        var r: Report = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const kind = f.next() orelse continue;
            if (std.mem.eql(u8, kind, "end")) return r;
            if (std.mem.eql(u8, kind, "denied")) {
                r.denied = true;
                return r;
            } else if (std.mem.eql(u8, kind, "storage")) {
                r.storage = std.meta.stringToEnum(StorageState, f.next() orelse continue) orelse .none;
                const extra = f.next() orelse continue;
                switch (r.storage) {
                    .preparing => r.progress = std.fmt.parseInt(u8, extra, 10) catch 0,
                    .failed => r.failure = std.meta.stringToEnum(Failure, extra) orelse .io,
                    else => {},
                }
            } else if (std.mem.eql(u8, kind, "hostname")) {
                r.hostname = Hostname.parse(f.next() orelse continue) orelse .{};
            } else if (std.mem.eql(u8, kind, "slot") or std.mem.eql(u8, kind, "next")) {
                const s = parseSlot(f.next() orelse continue) orelse continue;
                if (kind[0] == 's') r.slot = s else r.next = s;
            } else if (std.mem.eql(u8, kind, "version")) {
                const s = parseSlot(f.next() orelse continue) orelse continue;
                r.versions[s - 'a'] = Version.parse(f.rest());
            } else if (std.mem.eql(u8, kind, "locale")) {
                if (locale.Language.fromCode(f.next() orelse continue)) |l| r.locale.language = l;
                if (locale.Keyboard.fromCode(f.next() orelse continue)) |k| r.locale.keyboard = k;
            } else if (std.mem.eql(u8, kind, "video_memory")) {
                r.video_memory_now = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch null;
                r.video_memory_next = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch null;
            } else if (std.mem.eql(u8, kind, "update")) {
                r.update = std.meta.stringToEnum(UpdateState, f.next() orelse continue) orelse .none;
                if (r.update == .failed) r.update_failure = std.meta.stringToEnum(UpdateFailure, f.next() orelse "io") orelse .io;
            }
        }
        return null;
    }
};

fn parseSlot(s: []const u8) ?u8 {
    return if (s.len == 1 and (s[0] == 'a' or s[0] == 'b')) s[0] else null;
}

/// Sends the manager a request and returns its report; null if it cannot
/// be reached, or does not answer within `timeout_ms`.
pub fn ask(request: []const u8, timeout_ms: u64) ?Report {
    const path = socket_path;
    const fd: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch return null);
    defer sys.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    _ = sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) catch return null;
    _ = sys.check(linux.write(fd, request.ptr, request.len)) catch return null;
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    const deadline = sys.nowNs() + timeout_ms * std.time.ns_per_ms;
    while (len < buf.len) {
        const now = sys.nowNs();
        if (now >= deadline) return null;
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&pfd, 1, @intCast((deadline - now) / std.time.ns_per_ms + 1)) == 0) return null;
        const n = sys.check(linux.read(fd, buf[len..].ptr, buf.len - len)) catch return null;
        if (n == 0) break;
        len += n;
    }
    return Report.parse(buf[0..len]);
}

const testing = std.testing;

test "hostnames" {
    try testing.expectEqualStrings("awesome-elephant", Hostname.parse("awesome-elephant").?.slice());
    try testing.expect(Hostname.parse("pi4") != null);
    try testing.expect(Hostname.parse("") == null);
    try testing.expect(Hostname.parse("-pi") == null);
    try testing.expect(Hostname.parse("pi-") == null);
    try testing.expect(Hostname.parse("My-Pi") == null);
    try testing.expect(Hostname.parse("pi.local") == null);
    try testing.expect(Hostname.parse("a" ** 64) == null);
}

test "requests and reports go through the socket" {
    try testing.expect(Request.parse("status\n").? == .status);
    try testing.expect(Request.parse("prepare\n").? == .prepare);
    try testing.expectEqualStrings("awesome-elephant", Request.parse("hostname awesome-elephant\n").?.hostname.slice());
    try testing.expect(Request.parse("hostname Bad!\n") == null);
    try testing.expectEqualStrings("dazzle", Request.parse("finish dazzle\n").?.finish.slice());
    try testing.expect(Request.parse("finish Bad!\n") == null);
    try testing.expect(Request.parse("reboot\n") == null);
    try testing.expect(Request.parse("restart\n").? == .restart);
    const sum = "F3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753";
    try testing.expectEqualStrings("f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753", &Request.parse("update " ++ sum ++ "\n").?.update);
    try testing.expect(Request.parse("update abc\n") == null);
    try testing.expect(Request.parse("update " ++ "g" ** 64) == null);
    // Who may ask what.
    try testing.expect(Request.allowedFor(.status, .settings));
    try testing.expect(!Request.allowedFor(.prepare, .settings));
    try testing.expect(Request.allowedFor(.{ .hostname = Hostname.parse("my-pi").? }, .setup));
    try testing.expect(!Request.allowedFor(.{ .hostname = Hostname.parse("my-pi").? }, .settings));
    try testing.expect(!Request.allowedFor(.restart, .setup));
    try testing.expect(Request.allowedFor(.restart, .settings));
    const lr = Request.parse("locale en-NZ gb\n").?.locale;
    try testing.expectEqual(locale.Language.en_nz, lr.language);
    try testing.expectEqual(locale.Keyboard.gb, lr.keyboard);
    try testing.expect(Request.parse("locale fr-FR us\n") == null);
    try testing.expect(Request.allowedFor(.{ .locale = .{} }, .setup));
    try testing.expect(Request.allowedFor(.{ .locale = .{} }, .settings));
    const chosen: Report = .{ .locale = .{ .language = .en_au, .keyboard = .gb } };
    var chosen_buf: [256]u8 = undefined;
    try testing.expectEqual(locale.Language.en_au, Report.parse(chosen.write(&chosen_buf)).?.locale.language);

    var r: Report = .{ .storage = .preparing, .progress = 42, .hostname = Hostname.parse("awesome-elephant").? };
    var buf: [256]u8 = undefined;
    const text = r.write(&buf);
    try testing.expectEqualStrings("storage preparing 42\nhostname awesome-elephant\nversion a -\nversion b -\nupdate none\nlocale en-US us\nvideo_memory - -\nend\n", text);
    const back = Report.parse(text).?;
    try testing.expectEqual(StorageState.preparing, back.storage);
    try testing.expectEqual(@as(u8, 42), back.progress);
    try testing.expectEqualStrings("awesome-elephant", back.hostname.slice());
    r = .{ .storage = .failed, .failure = .too_small };
    const failed = Report.parse(r.write(&buf)).?;
    try testing.expectEqual(Failure.too_small, failed.failure);
    try testing.expectEqual(@as(u8, 0), failed.hostname.len);
    try testing.expect(Report.parse("denied\n").?.denied);
    try testing.expect(Report.parse("storage ready\n") == null);

    // The slots, and an update.
    r = .{ .storage = .ready, .slot = 'a', .next = 'b', .versions = .{ Version.parse("1791331200 de14aa2\n").?, Version.init(1791400000, "0123abc").? }, .update = .ready };
    const slots = Report.parse(r.write(&buf)).?;
    try testing.expectEqual(@as(?u8, 'a'), slots.slot);
    try testing.expectEqual(@as(?u8, 'b'), slots.next);
    try testing.expectEqual(@as(u64, 1791331200), slots.version('a').?.time);
    try testing.expectEqualStrings("0123abc", slots.version('b').?.commit());
    try testing.expectEqual(UpdateState.ready, slots.update);
    try testing.expect(slots.holds(&Version.init(5, "de14aa2").?));
    try testing.expect(!slots.holds(&Version.init(5, "fffffff").?));
    r = .{ .update = .failed, .update_failure = .archive };
    const failed_update = Report.parse(r.write(&buf)).?;
    try testing.expectEqual(UpdateFailure.archive, failed_update.update_failure);
    try testing.expect(failed_update.version('a') == null);
    // Video memory: now, and from the next start.
    r = .{ .video_memory_now = 128, .video_memory_next = 256 };
    const vm = Report.parse(r.write(&buf)).?;
    try testing.expectEqual(@as(?u16, 128), vm.video_memory_now);
    try testing.expectEqual(@as(?u16, 256), vm.video_memory_next);
    try testing.expectEqual(@as(u16, 192), Request.parse("video_memory 192\n").?.video_memory);
    try testing.expect(Request.parse("video_memory 100\n") == null);
    try testing.expect(Request.parse("video_memory\n") == null);
    try testing.expect(Request.allowedFor(.{ .video_memory = 128 }, .settings));
    try testing.expect(!Request.allowedFor(.{ .video_memory = 128 }, .setup));
    try testing.expect(videoMemoryAllowed(256, 940));
    try testing.expect(!videoMemoryAllowed(256, 430));
    try testing.expect(videoMemoryAllowed(192, 430));
    try testing.expect(!videoMemoryAllowed(100, 940));
    try testing.expect(Version.parse("soon abc") == null);
    try testing.expect(Version.parse("12 a/b") == null);
}
