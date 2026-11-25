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
//!     update <sha256> <signature>
//!                              install the system in update_archive, whose
//!                              SHA-256 and Ed25519 signature these are,
//!                              into the slot not in use, and start that
//!                              slot next time (settings)
//!     restart                  restart the computer (settings)
//!     setup_again              have setup run at the next start (it
//!                              is marked unfinished: the card's files
//!                              are kept), and restart (the shell, for
//!                              remote control: for trying setup)
//!     boot <a|b>               start that OS slot next time (settings):
//!                              the other slot is tried, as an update is,
//!                              so if it does not start the running one
//!                              comes back; the running one undoes that
//!     power_off                turn the computer off (the shell's quick
//!                              settings, and settings)
//!     locale <language> <keyboard> [<time zone>]
//!                              the language, keyboard and time zone
//!                              (setup and settings; UTC if none is
//!                              given): kept in /data/system/locale (once
//!                              there is a /data)
//!     video_memory <MiB>       how much memory the GPU may have, from the
//!                              next start (settings): see `video_memory`
//!     orientation <landscape|portrait>
//!                              the screen's (settings): the shell turns
//!                              to it at once, and the boot screen from
//!                              the next start; see `Orientation`
//!     parental_on <password> <limits>
//!                              turn parental controls on (settings), the
//!                              password (in hex) to unlock from now on;
//!                              the limits as `parental.Limits` says them
//!     parental_off <password>  turn them off, unlocking (settings, and the
//!                              shell's lock screen)
//!     parental_bonus <password> <minutes>
//!                              more time today (settings)
//!
//! and the report:
//!
//!     storage preparing 42
//!     hostname awesome-elephant
//!     slot a
//!     next a
//!     version a 1791331200 de14aa2
//!     version b -
//!     update failed did_not_start
//!     failed_start b signal 11
//!     locale en-GB gb Europe/London
//!     video_memory 128 256
//!     orientation portrait
//!     parental on 120 180 1200 420 block
//!     parental_status none 1794830400 - 42 120 0 0
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
//! "failed_start" is the slot that last did not start properly, and how
//! its shell stopped (see `Stop`); its log is `failed_start_log`.
//! "video_memory" is the memory the GPU may have now and from the next
//! start, in MiB ("-": not known). "orientation" is the screen's (as it is
//! kept, for the next start too). "parental" is whether parental
//! controls are on, and their limits; "parental_status" whether the
//! computer is locked ("none", "time" or "downtime"), when it will lock
//! and when it may be used again (seconds since 1970, by the manager's
//! clock), the minutes used and allowed today, the bonus minutes, and
//! the manager's clock less the system's (see `sys.parental`). The answer
//! to a request with a password has "password ok" or "password wrong". A
//! client the manager does not serve, or a request it does not serve that
//! client, gets "denied\n".

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const locale = @import("locale");
const parental = @import("parental.zig");

/// The manager's socket.
pub const socket_path = "/os/sockets/system";

/// The programs the manager answers.
pub const setup_program = "/os/shell/dazzle-setup";
pub const settings_program = "/os/shell/dazzle-settings";
pub const shell_program = "/os/shell/dazzle-shell";

/// Where the card's free space is mounted, and the files in it.
pub const data_dir = "/data";
/// The system's settings (owned by root).
pub const config_dir = "/data/system";
/// The computer's name.
pub const hostname_file = "/data/system/hostname";
/// There once setup has finished.
pub const setup_done_file = "/data/system/setup-done";
/// "on" to serve the log over HTTP (see init's logserver.zig), which
/// Settings turns on and off; off without it.
pub const log_server_file = "/data/system/log-server";
/// On the kernel's command line, serves the log over HTTP whatever
/// `log_server_file` says (as `zig build qemu` does, having no card).
pub const log_server_cmdline = "dazzle.log_server=on";

/// Whether the log is to be served over HTTP: the kernel's command line
/// has `log_server_cmdline`, or `log_server_file` says "on".
pub fn logServerOn() bool {
    return logServerForced() or logServerChosen();
}

/// Whether the kernel's command line has `log_server_cmdline`.
pub fn logServerForced() bool {
    var buf: [1024]u8 = undefined;
    const cmdline = sys.readFile("/proc/cmdline", &buf) orelse return false;
    var words = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (words.next()) |w| if (std.mem.eql(u8, w, log_server_cmdline)) return true;
    return false;
}

/// Whether `log_server_file` says "on".
pub fn logServerChosen() bool {
    var buf: [16]u8 = undefined;
    const text = sys.readFile(log_server_file, &buf) orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, text, " \n"), "on");
}
/// The log of the last start that did not work (an OS slot tried, whose
/// shell did not run): see init's bootlog.zig. Anyone's to read.
pub const failed_start_log = "/data/system/start-failed.log";
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
pub const video_memory_sizes = [_]u16{ 64, 96, 128, 192, 256, 384, 512 };

/// The video memory a computer with `ram_mib` of memory is given until
/// someone chooses (`video_memory_chosen_file`): more on those with more
/// (a Pi 4 or 400 with 4 GB has room for the GPU to have plenty, as the
/// Raspberry Pi's own system gives it).
pub fn defaultVideoMemory(ram_mib: u64) u16 {
    if (ram_mib >= 3 * 1024) return 512;
    if (ram_mib >= 3 * 512) return 256;
    return 128;
}

/// There when someone has chosen the video memory (in Settings), which is
/// then kept as it is.
pub const video_memory_chosen_file = "/data/system/video-memory-chosen";

/// Which way the screen is: wider than tall, or taller. A display the
/// other way (the Touch Display 2 is upright; a monitor wide) is turned a
/// quarter, by the boot screen and the shell. It is kept on the kernel's
/// command line (`orientation_arg`), which both can read from the start;
/// landscape if it is not there. Changed, the shell turns at once (it
/// follows the system manager's report), the boot screen from the next
/// start.
pub const Orientation = enum {
    landscape,
    portrait,

    /// The orientation a kernel command line gives.
    pub fn of(cmdline: []const u8) Orientation {
        var found: Orientation = .landscape;
        var it = std.mem.tokenizeAny(u8, cmdline, " \n");
        while (it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, orientation_arg)) continue;
            found = std.meta.stringToEnum(Orientation, arg[orientation_arg.len..]) orelse found;
        }
        return found;
    }

    /// This start's (from /proc/cmdline).
    pub fn now() Orientation {
        var buf: [1024]u8 = undefined;
        const rc = linux.open("/proc/cmdline", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return .landscape;
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return .landscape;
        return of(buf[0..n]);
    }

    /// Whether a display `width` by `height` is turned for it.
    pub fn turns(o: Orientation, width: u32, height: u32) bool {
        return (height > width) != (o == .portrait);
    }
};

/// The kernel command line's argument for the orientation.
pub const orientation_arg = "dazzle.orientation=";

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
    pub const Update = struct {
        /// The archive's SHA-256, in hex.
        sha256: [64]u8,
        /// The archive's Ed25519 signature, in hex.
        signature: [128]u8,
    };

    status,
    subscribe,
    prepare,
    hostname: Hostname,
    finish: Hostname,
    update: Update,
    restart,
    /// Setup at the next start, and restart.
    setup_again,
    /// The OS slot to start next time.
    boot: u8,
    power_off,
    locale: locale.Settings,
    /// In MiB, one of `video_memory_sizes`.
    video_memory: u16,
    orientation: Orientation,
    /// Serve the log over HTTP, or not.
    log_server: bool,
    parental_on: struct { password: parental.Password, limits: parental.Limits },
    parental_off: parental.Password,
    parental_bonus: struct { password: parental.Password, minutes: u16 },

    pub fn parse(line: []const u8) ?Request {
        var f = std.mem.tokenizeAny(u8, line, " \n");
        const kind = f.next() orelse return null;
        if (std.mem.eql(u8, kind, "status")) return .status;
        if (std.mem.eql(u8, kind, "subscribe")) return .subscribe;
        if (std.mem.eql(u8, kind, "prepare")) return .prepare;
        if (std.mem.eql(u8, kind, "hostname")) return .{ .hostname = Hostname.parse(f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "finish")) return .{ .finish = Hostname.parse(f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "restart")) return .restart;
        if (std.mem.eql(u8, kind, "setup_again")) return .setup_again;
        if (std.mem.eql(u8, kind, "boot")) return .{ .boot = parseSlot(f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "power_off")) return .power_off;
        if (std.mem.eql(u8, kind, "locale")) return .{ .locale = .{
            .language = locale.Language.fromCode(f.next() orelse return null) orelse return null,
            .keyboard = locale.Keyboard.fromCode(f.next() orelse return null) orelse return null,
            .timezone = if (f.next()) |z| locale.TimeZone.fromName(z) orelse return null else .utc,
        } };
        if (std.mem.eql(u8, kind, "video_memory")) {
            const mib = std.fmt.parseInt(u16, f.next() orelse return null, 10) catch return null;
            if (std.mem.indexOfScalar(u16, &video_memory_sizes, mib) == null) return null;
            return .{ .video_memory = mib };
        }
        if (std.mem.eql(u8, kind, "orientation")) return .{ .orientation = std.meta.stringToEnum(Orientation, f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "log_server")) return .{ .log_server = parseOnOff(f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "parental_on")) {
            const password = parental.Password.fromHex(f.next() orelse return null) orelse return null;
            return .{ .parental_on = .{ .password = password, .limits = parental.Limits.parse(&f) orelse return null } };
        }
        if (std.mem.eql(u8, kind, "parental_off")) return .{ .parental_off = parental.Password.fromHex(f.next() orelse return null) orelse return null };
        if (std.mem.eql(u8, kind, "parental_bonus")) {
            const password = parental.Password.fromHex(f.next() orelse return null) orelse return null;
            const minutes = std.fmt.parseInt(u16, f.next() orelse return null, 10) catch return null;
            if (minutes == 0 or minutes > parental.Limits.most_minutes) return null;
            return .{ .parental_bonus = .{ .password = password, .minutes = minutes } };
        }
        if (std.mem.eql(u8, kind, "update")) {
            const hex = f.next() orelse return null;
            const sig = f.next() orelse return null;
            if (hex.len != 64 or sig.len != 128) return null;
            for (hex) |c| if (!std.ascii.isHex(c)) return null;
            for (sig) |c| if (!std.ascii.isHex(c)) return null;
            var r: Request = .{ .update = undefined };
            for (&r.update.sha256, hex) |*d, c| d.* = std.ascii.toLower(c);
            for (&r.update.signature, sig) |*d, c| d.* = std.ascii.toLower(c);
            return r;
        }
        return null;
    }

    /// Whether `client` may ask this.
    pub fn allowedFor(r: Request, client: Client) bool {
        return switch (r) {
            .status, .subscribe => true,
            .prepare, .hostname, .finish => client == .setup,
            // The shell too: remote control installs updates and restarts.
            .update, .restart => client == .settings or client == .shell,
            // Remote control's (for trying setup).
            .setup_again => client == .shell,
            .boot, .video_memory, .orientation, .log_server, .parental_on, .parental_bonus => client == .settings,
            // The shell's lock screen unlocks.
            .parental_off => client == .settings or client == .shell,
            .locale => client == .setup or client == .settings,
            .power_off => client == .shell or client == .settings,
        };
    }
};

pub const Client = enum { setup, settings, shell };

fn parseOnOff(word: []const u8) ?bool {
    if (std.mem.eql(u8, word, "on")) return true;
    if (std.mem.eql(u8, word, "off")) return false;
    return null;
}

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

/// How a tried system's shell stopped (see init's trial.zig): it exited,
/// with a status; it was killed, by a signal; or not known (the system
/// hung and the watchdog restarted it, the power went, or it stopped
/// before the shell ran).
pub const Stop = union(enum) {
    unknown,
    exited: u8,
    signal: u8,

    /// From the words after a trial's state ("exited 1", "signal 11").
    pub fn parse(f: anytype) Stop {
        const kind = f.next() orelse return .unknown;
        const n = std.fmt.parseInt(u8, f.next() orelse return .unknown, 10) catch return .unknown;
        if (std.mem.eql(u8, kind, "exited")) return .{ .exited = n };
        if (std.mem.eql(u8, kind, "signal")) return .{ .signal = n };
        return .unknown;
    }

    pub fn write(s: Stop, w: *std.Io.Writer) !void {
        switch (s) {
            .unknown => try w.writeAll("unknown"),
            .exited => |n| try w.print("exited {d}", .{n}),
            .signal => |n| try w.print("signal {d}", .{n}),
        }
    }

    /// In English, for the log.
    pub fn describe(s: Stop, buf: []u8) []const u8 {
        return switch (s) {
            .unknown => "it hung, lost power or stopped before its shell ran",
            .exited => |n| std.fmt.bufPrint(buf, "its shell exited with status {d}", .{n}) catch "its shell exited",
            .signal => |n| std.fmt.bufPrint(buf, "its shell was killed by {s}", .{signalName(n)}) catch "its shell was killed",
        };
    }
};

/// A signal's name ("SIGSEGV"); "a signal" if it is not a usual one.
pub fn signalName(n: u8) []const u8 {
    return switch (n) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        else => "a signal",
    };
}

/// The OS slot that last did not start properly, and how.
pub const FailedStart = struct {
    slot: u8,
    stop: Stop = .unknown,
};

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

/// Parental controls, as the report says them (see `sys.parental`).
pub const Parental = struct {
    on: bool = false,
    limits: parental.Limits = .{},
    lock: parental.Lock = .none,
    /// When it will lock, while not locked; when it may be used again,
    /// while it is (seconds since 1970, by the manager's clock).
    lock_at: ?i64 = null,
    until: ?i64 = null,
    /// Minutes used today, and allowed (null: no limit), with the bonus
    /// minutes given.
    used: u32 = 0,
    allowed: ?u32 = null,
    bonus: u16 = 0,
    /// The manager's clock less the system's: not 0 while the clock is not
    /// set (it goes on from the last time the manager saw).
    clock_offset: i64 = 0,

    /// The manager's clock, by the system's.
    pub fn now(p: Parental, system_now: i64) i64 {
        return system_now + p.clock_offset;
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
    /// The slot that last did not start properly (its log is
    /// `failed_start_log`).
    failed_start: ?FailedStart = null,
    /// The language and keyboard chosen.
    locale: locale.Settings = .{},
    /// The memory the GPU may have now, and from the next start, in MiB.
    video_memory_now: ?u16 = null,
    video_memory_next: ?u16 = null,
    /// The screen's orientation (as kept for the next start, which the
    /// shell follows at once).
    orientation: Orientation = .landscape,
    /// The log is served over HTTP (see `logServerOn`).
    log_server: bool = false,
    parental: Parental = .{},
    /// The password given with the request answered was right (or not);
    /// null if none was given.
    password: ?bool = null,
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
        if (r.failed_start) |fs| {
            w.print("\nfailed_start {c} ", .{fs.slot}) catch {};
            fs.stop.write(&w) catch {};
        }
        w.print("\nlocale {s} {s} {s}", .{ r.locale.language.code(), r.locale.keyboard.code(), r.locale.timezone.name() }) catch {};
        w.writeAll("\nvideo_memory") catch {};
        for ([_]?u16{ r.video_memory_now, r.video_memory_next }) |v| if (v) |mib| w.print(" {d}", .{mib}) catch {} else w.writeAll(" -") catch {};
        w.print("\norientation {s}", .{@tagName(r.orientation)}) catch {};
        w.print("\nlog_server {s}", .{if (r.log_server) "on" else "off"}) catch {};
        const p = r.parental;
        w.print("\nparental {s} ", .{if (p.on) "on" else "off"}) catch {};
        p.limits.write(&w) catch {};
        w.print("\nparental_status {s} ", .{@tagName(p.lock)}) catch {};
        writeOptional(&w, p.lock_at);
        w.writeByte(' ') catch {};
        writeOptional(&w, p.until);
        w.print(" {d} ", .{p.used}) catch {};
        writeOptional(&w, p.allowed);
        w.print(" {d} {d}", .{ p.bonus, p.clock_offset }) catch {};
        if (r.password) |ok| w.print("\npassword {s}", .{if (ok) "ok" else "wrong"}) catch {};
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
                if (locale.TimeZone.fromName(f.next() orelse continue)) |z| r.locale.timezone = z;
            } else if (std.mem.eql(u8, kind, "video_memory")) {
                r.video_memory_now = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch null;
                r.video_memory_next = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch null;
            } else if (std.mem.eql(u8, kind, "orientation")) {
                r.orientation = std.meta.stringToEnum(Orientation, f.next() orelse continue) orelse .landscape;
            } else if (std.mem.eql(u8, kind, "log_server")) {
                r.log_server = parseOnOff(f.next() orelse continue) orelse false;
            } else if (std.mem.eql(u8, kind, "parental")) {
                r.parental.on = parseOnOff(f.next() orelse continue) orelse false;
                var lf = std.mem.tokenizeAny(u8, f.rest(), " ");
                if (parental.Limits.parse(&lf)) |l| r.parental.limits = l;
            } else if (std.mem.eql(u8, kind, "parental_status")) {
                const p = &r.parental;
                p.lock = std.meta.stringToEnum(parental.Lock, f.next() orelse continue) orelse .none;
                p.lock_at = parseOptional(i64, f.next() orelse continue);
                p.until = parseOptional(i64, f.next() orelse continue);
                p.used = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch 0;
                p.allowed = parseOptional(u32, f.next() orelse continue);
                p.bonus = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch 0;
                p.clock_offset = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch 0;
            } else if (std.mem.eql(u8, kind, "password")) {
                r.password = std.mem.eql(u8, f.next() orelse continue, "ok");
            } else if (std.mem.eql(u8, kind, "failed_start")) {
                const s = parseSlot(f.next() orelse continue) orelse continue;
                r.failed_start = .{ .slot = s, .stop = Stop.parse(&f) };
            } else if (std.mem.eql(u8, kind, "update")) {
                r.update = std.meta.stringToEnum(UpdateState, f.next() orelse continue) orelse .none;
                if (r.update == .failed) r.update_failure = std.meta.stringToEnum(UpdateFailure, f.next() orelse "io") orelse .io;
            }
        }
        return null;
    }
};

fn writeOptional(w: *std.Io.Writer, v: anytype) void {
    if (v) |n| w.print("{d}", .{n}) catch {} else w.writeByte('-') catch {};
}

fn parseOptional(comptime T: type, s: []const u8) ?T {
    return std.fmt.parseInt(T, s, 10) catch null;
}

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
    var buf: [2048]u8 = undefined;
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

/// Extracts the first complete report from `text`, returning it and how
/// many bytes of `text` it consumed.
fn takeReport(text: []const u8) ?struct { report: Report, consumed: usize } {
    var pos: usize = 0;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return null;
        const line = std.mem.trim(u8, text[pos..nl], " \r");
        pos = nl + 1;
        if (std.mem.eql(u8, line, "end") or std.mem.eql(u8, line, "denied")) {
            const report = Report.parse(text[0..pos]) orelse return null;
            return .{ .report = report, .consumed = pos };
        }
    }
    return null;
}

/// A live connection to the system manager that receives a new `Report`
/// whenever the system state changes.
pub const Subscription = struct {
    fd: ?linux.fd_t = null,
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn deinit(s: *Subscription) void {
        if (s.fd) |fd| sys.close(fd);
        s.fd = null;
        s.len = 0;
    }

    /// Connects and subscribes if not already connected.
    pub fn connect(s: *Subscription) void {
        _ = s.connectTo(socket_path);
    }

    pub fn connectTo(s: *Subscription, path: []const u8) ?linux.fd_t {
        if (s.fd) |fd| return fd;
        const fd: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)) catch return null);
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) {
            sys.close(fd);
            return null;
        }
        @memcpy(addr.path[0..path.len], path);
        _ = sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) catch {
            sys.close(fd);
            return null;
        };
        const req = "subscribe\n";
        _ = sys.check(linux.write(fd, req.ptr, req.len)) catch {
            sys.close(fd);
            return null;
        };
        s.fd = fd;
        s.len = 0;
        return fd;
    }

    /// Reads any reports that have arrived without blocking, returning the
    /// latest complete `Report` if at least one arrived.
    pub fn poll(s: *Subscription) ?Report {
        return s.pollFrom(socket_path);
    }

    pub fn pollFrom(s: *Subscription, path: []const u8) ?Report {
        const fd = s.connectTo(path) orelse return null;
        while (s.len < s.buf.len) {
            const rc = linux.read(fd, s.buf[s.len..].ptr, s.buf.len - s.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        s.deinit();
                        break;
                    }
                    s.len += rc;
                },
                .INTR => continue,
                .AGAIN => break,
                else => {
                    s.deinit();
                    break;
                },
            }
        }
        var latest: ?Report = null;
        while (takeReport(s.buf[0..s.len])) |got| {
            if (!got.report.denied) latest = got.report;
            const rem = s.len - got.consumed;
            std.mem.copyForwards(u8, s.buf[0..rem], s.buf[got.consumed..s.len]);
            s.len = rem;
        }
        if (s.len == s.buf.len) s.len = 0;
        return latest;
    }
};

const testing = std.testing;

/// `text` `n` times over.
fn comptimeRepeat(comptime text: []const u8, comptime n: usize) *const [text.len * n]u8 {
    const result = comptime result: {
        var out: [text.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * text.len ..][0..text.len], text);
        break :result out;
    };
    return &result;
}

test "hostnames" {
    try testing.expectEqualStrings("awesome-elephant", Hostname.parse("awesome-elephant").?.slice());
    try testing.expect(Hostname.parse("pi4") != null);
    try testing.expect(Hostname.parse("") == null);
    try testing.expect(Hostname.parse("-pi") == null);
    try testing.expect(Hostname.parse("pi-") == null);
    try testing.expect(Hostname.parse("My-Pi") == null);
    try testing.expect(Hostname.parse("pi.local") == null);
    try testing.expect(Hostname.parse(&@as([64]u8, @splat('a'))) == null);
}

test "requests and reports go through the socket" {
    try testing.expect(Request.parse("status\n").? == .status);
    try testing.expect(Request.parse("subscribe\n").? == .subscribe);
    try testing.expect(Request.parse("prepare\n").? == .prepare);
    try testing.expectEqualStrings("awesome-elephant", Request.parse("hostname awesome-elephant\n").?.hostname.slice());
    try testing.expect(Request.parse("hostname Bad!\n") == null);
    try testing.expectEqualStrings("dazzle", Request.parse("finish dazzle\n").?.finish.slice());
    try testing.expect(Request.parse("finish Bad!\n") == null);
    try testing.expect(Request.parse("reboot\n") == null);
    try testing.expect(Request.parse("restart\n").? == .restart);
    try testing.expect(Request.parse("power_off\n").? == .power_off);
    try testing.expect(Request.parse("setup_again\n").? == .setup_again);
    try testing.expect(Request.allowedFor(.setup_again, .shell));
    try testing.expect(!Request.allowedFor(.setup_again, .settings));
    try testing.expect(Request.allowedFor(.power_off, .shell));
    try testing.expect(Request.allowedFor(.power_off, .settings));
    try testing.expect(!Request.allowedFor(.power_off, .setup));
    const sum = "F3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753";
    const sig = "A1" ++ comptimeRepeat("02", 63);
    const upd = Request.parse("update " ++ sum ++ " " ++ sig ++ "\n").?.update;
    try testing.expectEqualStrings("f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753", &upd.sha256);
    try testing.expectEqualStrings("a1" ++ comptimeRepeat("02", 63), &upd.signature);
    try testing.expect(Request.parse("update " ++ sum ++ "\n") == null);
    try testing.expect(Request.parse("update abc\n") == null);
    try testing.expect(Request.parse("update " ++ &@as([64]u8, @splat('g')) ++ " " ++ sig) == null);
    try testing.expect(Request.parse("update " ++ sum ++ " " ++ &@as([128]u8, @splat('g'))) == null);
    // Who may ask what.
    try testing.expect(Request.allowedFor(.status, .settings));
    try testing.expect(Request.allowedFor(.subscribe, .shell));
    try testing.expect(!Request.allowedFor(.prepare, .settings));
    try testing.expect(!Request.allowedFor(.{ .locale = .{} }, .shell));
    try testing.expect(Request.allowedFor(.{ .hostname = Hostname.parse("my-pi").? }, .setup));
    try testing.expect(!Request.allowedFor(.{ .hostname = Hostname.parse("my-pi").? }, .settings));
    try testing.expect(!Request.allowedFor(.restart, .setup));
    try testing.expect(Request.allowedFor(.restart, .settings));
    const lr = Request.parse("locale en-NZ gb\n").?.locale;
    try testing.expectEqual(locale.Language.en_nz, lr.language);
    try testing.expectEqual(locale.Keyboard.gb, lr.keyboard);
    try testing.expect(Request.parse("locale xx-XX us\n") == null);
    try testing.expectEqualStrings("Europe/London", Request.parse("locale en-GB gb Europe/London\n").?.locale.timezone.name());
    try testing.expectEqual(locale.TimeZone.utc, lr.timezone);
    try testing.expect(Request.parse("locale en-GB gb Middle/Earth\n") == null);
    try testing.expect(Request.allowedFor(.{ .locale = .{} }, .setup));
    try testing.expect(Request.allowedFor(.{ .locale = .{} }, .settings));
    const chosen: Report = .{ .locale = .{ .language = .en_au, .keyboard = .gb, .timezone = locale.TimeZone.fromName("Australia/Perth").? } };
    var chosen_buf: [256]u8 = undefined;
    try testing.expectEqual(chosen.locale, Report.parse(chosen.write(&chosen_buf)).?.locale);

    var r: Report = .{ .storage = .preparing, .progress = 42, .hostname = Hostname.parse("awesome-elephant").? };
    var buf: [512]u8 = undefined;
    const text = r.write(&buf);
    try testing.expectEqualStrings("storage preparing 42\nhostname awesome-elephant\nversion a -\nversion b -\nupdate none\nlocale en-US us UTC\nvideo_memory - -\norientation landscape\nlog_server off\nparental off - - - - allow\nparental_status none - - 0 - 0 0\nend\n", text);
    const back = Report.parse(text).?;
    try testing.expectEqual(StorageState.preparing, back.storage);
    try testing.expectEqual(@as(u8, 42), back.progress);
    try testing.expectEqualStrings("awesome-elephant", back.hostname.slice());
    r = .{ .storage = .failed, .failure = .too_small };
    const failed = Report.parse(r.write(&buf)).?;
    try testing.expectEqual(Failure.too_small, failed.failure);
    try testing.expectEqual(@as(u8, 0), failed.hostname.len);
    try testing.expect(Report.parse("denied\n").?.denied);
    // The orientation: asked for by Settings, and said now and next.
    try testing.expectEqual(Orientation.portrait, Request.parse("orientation portrait\n").?.orientation);
    try testing.expect(Request.parse("orientation sideways\n") == null);
    try testing.expect(Request.allowedFor(.{ .orientation = .portrait }, .settings));
    try testing.expect(!Request.allowedFor(.{ .orientation = .portrait }, .shell));
    r = .{ .orientation = .portrait };
    try testing.expectEqual(Orientation.portrait, Report.parse(r.write(&buf)).?.orientation);
    try testing.expectEqual(Orientation.portrait, Orientation.of("cma=128M dazzle.orientation=portrait dazzle.slot=a"));
    try testing.expectEqual(Orientation.landscape, Orientation.of("cma=128M"));
    // The Touch Display 2 (upright) is turned for landscape, a monitor for
    // portrait.
    try testing.expect(Orientation.landscape.turns(720, 1280));
    try testing.expect(!Orientation.landscape.turns(1920, 1080));
    try testing.expect(Orientation.portrait.turns(1920, 1080));
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
    try testing.expect(failed_update.failed_start == null);
    // A slot that did not start, and how.
    r = .{ .update = .failed, .update_failure = .did_not_start, .failed_start = .{ .slot = 'b', .stop = .{ .signal = 11 } } };
    const not_started = Report.parse(r.write(&buf)).?;
    try testing.expectEqual(FailedStart{ .slot = 'b', .stop = .{ .signal = 11 } }, not_started.failed_start.?);
    r = .{ .failed_start = .{ .slot = 'a' } };
    try testing.expectEqual(Stop.unknown, Report.parse(r.write(&buf)).?.failed_start.?.stop);
    var how: [96]u8 = undefined;
    try testing.expectEqualStrings("its shell was killed by SIGSEGV", (Stop{ .signal = 11 }).describe(&how));
    try testing.expectEqualStrings("its shell exited with status 1", (Stop{ .exited = 1 }).describe(&how));
    // Choosing the slot to start.
    try testing.expectEqual(@as(u8, 'b'), Request.parse("boot b\n").?.boot);
    try testing.expect(Request.parse("boot c\n") == null);
    try testing.expect(Request.parse("boot\n") == null);
    try testing.expect(Request.allowedFor(.{ .boot = 'a' }, .settings));
    try testing.expect(!Request.allowedFor(.{ .boot = 'a' }, .shell));
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
    // Serving the log: only Settings turns it on or off.
    const serving: Report = .{ .log_server = true };
    var serving_buf: [512]u8 = undefined;
    try testing.expect(Report.parse(serving.write(&serving_buf)).?.log_server);
    try testing.expect(Request.parse("log_server on\n").?.log_server);
    try testing.expect(!Request.parse("log_server off\n").?.log_server);
    try testing.expect(Request.parse("log_server yes\n") == null);
    try testing.expect(Request.parse("log_server\n") == null);
    try testing.expect(Request.allowedFor(.{ .log_server = true }, .settings));
    try testing.expect(!Request.allowedFor(.{ .log_server = true }, .setup));
    try testing.expect(!Request.allowedFor(.{ .log_server = true }, .shell));
    // Parental controls: on, locked till the morning; a password's answer.
    var locked: Report = .{ .parental = .{ .on = true, .limits = .{ .weekday = 90 }, .lock = .time, .until = 1794830400, .used = 90, .allowed = 90, .bonus = 0, .clock_offset = -5 }, .password = false };
    const lb = Report.parse(locked.write(&buf)).?;
    try testing.expectEqual(locked.parental, lb.parental);
    try testing.expectEqual(@as(?bool, false), lb.password);
    locked.password = null;
    try testing.expect(Report.parse(locked.write(&buf)).?.password == null);
    const on = Request.parse("parental_on 7365736166 60 120 - - allow\n").?;
    try testing.expectEqualStrings("sesaf", on.parental_on.password.slice());
    try testing.expectEqual(@as(?u16, 60), on.parental_on.limits.weekday);
    try testing.expect(on.parental_on.limits.downtime == null);
    try testing.expect(Request.parse("parental_on 7365 60 120\n") == null);
    try testing.expectEqualStrings("ab", Request.parse("parental_off 6162\n").?.parental_off.slice());
    try testing.expectEqual(@as(u16, 30), Request.parse("parental_bonus 6162 30\n").?.parental_bonus.minutes);
    try testing.expect(Request.parse("parental_bonus 6162 0\n") == null);
    try testing.expect(Request.allowedFor(on, .settings) and !Request.allowedFor(on, .shell) and !Request.allowedFor(on, .setup));
    try testing.expect(Request.allowedFor(.{ .parental_off = .{} }, .shell));
    try testing.expect(Version.parse("soon abc") == null);
    try testing.expect(Version.parse("12 a/b") == null);

    var pair: [2]linux.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &pair));
    defer sys.close(pair[1]);
    var sub: Subscription = .{ .fd = pair[0] };
    defer sub.deinit();
    _ = linux.write(pair[1], text.ptr, text.len);
    const vm_text = r.write(&buf);
    _ = linux.write(pair[1], vm_text.ptr, vm_text.len);
    const got = sub.poll().?;
    try testing.expectEqual(@as(?u16, 256), got.video_memory_next);
}

test "video memory grows with the computer's memory until chosen" {
    try std.testing.expectEqual(@as(u16, 128), defaultVideoMemory(434));
    try std.testing.expectEqual(@as(u16, 128), defaultVideoMemory(948));
    try std.testing.expectEqual(@as(u16, 256), defaultVideoMemory(1900));
    try std.testing.expectEqual(@as(u16, 512), defaultVideoMemory(3800));
    try std.testing.expect(videoMemoryAllowed(defaultVideoMemory(3800), 3800));
    try std.testing.expect(videoMemoryAllowed(defaultVideoMemory(434), 434));
}
