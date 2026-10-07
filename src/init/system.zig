//! The system manager: on the first run, while the setup app runs, it
//! prepares the SD card's free space for files and names the computer;
//! later it installs updates of the system for the settings app.
//!
//! Init forks it at boot (and again if it stops). It runs as the Dazzle
//! user, keeping only the capabilities this needs: writing the card,
//! mounting it and setting the hostname (CAP_SYS_ADMIN), writing the card's
//! device, the root-owned /data and the boot partition (CAP_DAC_OVERRIDE),
//! giving /data/system to root (CAP_CHOWN), and restarting the computer
//! (CAP_SYS_BOOT). It listens on /os/sockets/system (see `sys.system` for
//! the protocol) and answers only the setup and settings apps, each only
//! what is theirs to ask: the program the connecting process runs must be
//! /os/shell/dazzle-setup or /os/shell/dazzle-settings.
//!
//! Preparing (asked for when setup starts, so it goes on while the user
//! fills in the pages): a partition after the system's to the end of the
//! card (storage.zig), an empty filesystem on it, written on a thread while
//! the manager answers the app (which shows how far it has got; mkfs.zig), then mounted at /data with /data/system and /data/user
//! in it. Finishing sets the hostname, keeps it in /data/system with a
//! mark that setup has finished, and ends the manager.
//!
//! Meanwhile, from the start, it copies the running OS slot to the other
//! (slots.zig), the image having only one, on another thread. (If setup has finished, as when the power went before the
//! copy did, it only copies.)
//!
//! Updating (update.zig): Settings downloads an update and asks for it to
//! be installed; a child process unpacks it into the OS slot not running
//! and has the firmware start that slot next time. Settings then offers to
//! restart, which the manager does.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const storage = @import("storage.zig");
const mkfs = @import("mkfs.zig");
const slots = @import("slots.zig");
const update = @import("update.zig");
const trial = @import("trial.zig");

const proto = sys.system;
const print = sys.print;

const max_clients = 4;
/// Work on a thread of its own (formatting, or copying the OS slot), so
/// the manager answers meanwhile.
const Work = struct {
    thread: std.Thread,
    done: std.atomic.Value(bool) = .init(false),
    /// How far it has got, in percent.
    percent: std.atomic.Value(u32) = .init(0),
    /// Why it failed (read once it is done).
    err: ?anyerror = null,

    fn finished(w: *const Work) bool {
        return w.done.load(.acquire);
    }
};

/// Forks the manager. `card` says whether there is an SD card, `mounted`
/// whether /data is already there (prepared on an earlier run that did not
/// finish setting up), `slot` which OS slot is running, and `setup_done`
/// whether setup has finished.
pub fn start(card: bool, mounted: bool, slot: ?u8, setup_done: bool) ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print("dazzle: system: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    sys.dropPrivilegesKeeping(&.{ .sys_admin, .dac_override, .chown, .sys_boot }) catch |err| {
        print("dazzle: system: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    sys.ignoreBrokenPipes();
    var m: Manager = .{ .report = .{ .storage = if (mounted) .ready else if (card) .unprepared else .none, .slot = if (card) slot orelse 'a' else null }, .finished = setup_done };
    m.readSlots();
    // The last update did not work (and the system before is running).
    if (storage.exists(trial.failed_marker)) {
        m.report.update = .failed;
        m.report.update_failure = .did_not_start;
    }
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) == .SUCCESS) m.report.hostname = proto.Hostname.parse(std.mem.sliceTo(&uts.nodename, 0)) orelse .{};
    if (card) m.copier = slots.Copier.start(slot orelse 'a') catch |err| blk: {
        print("dazzle: system: cannot copy the OS slot: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (m.copier != null) m.startCopying();
    m.run() catch |err| print("dazzle: system: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

const Manager = struct {
    report: proto.Report,
    /// Formatting (on `formatting`'s thread), and the partition's device.
    formatter: ?mkfs.Formatter = null,
    formatting: ?Work = null,
    fd: ?linux.fd_t = null,
    /// Copying the OS slot (on `copying`'s thread).
    copier: ?slots.Copier = null,
    copying: ?Work = null,
    /// Installing an update.
    installer: ?update.Installer = null,
    /// Setup has finished.
    finished: bool = false,
    /// Settings asked to restart (once it has its answer).
    restart: bool = false,

    /// What the slots hold, and which starts next.
    fn readSlots(m: *Manager) void {
        const running = m.report.slot orelse return;
        m.report.next = slots.next();
        // While an update is tried, os_prefix names the system before it
        // (in case it does not work), but this one is what is installed.
        if (trial.read()) |t| if (t.slot == running and t.state == .started) {
            m.report.next = running;
        };
        for (&m.report.versions, "ab") |*v, s| v.* = slots.version(s);
    }

    fn run(m: *Manager) !void {
        const path = proto.socket_path;
        const listener = try listen(path);
        defer {
            sys.close(listener);
            _ = linux.unlink(path);
        }
        const Conn = struct { fd: linux.fd_t, who: proto.Client };
        var clients: [max_clients]?Conn = @splat(null);
        while (true) {
            // While formatting or copying, see how it goes now and then.
            const busy = m.formatting != null or m.copying != null;
            if (m.formatting != null) m.checkFormatting();
            if (m.copying != null) m.checkCopying();
            if (m.installer) |*i| if (i.finished()) |how| {
                m.installer = null;
                m.report.update = if (how == .none) .ready else .failed;
                m.report.update_failure = how;
                m.readSlots();
            };

            var fds: [1 + max_clients]linux.pollfd = undefined;
            fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
            for (clients, fds[1..]) |c, *f| f.* = .{ .fd = if (c) |conn| conn.fd else -1, .events = linux.POLL.IN, .revents = 0 };
            _ = linux.poll(&fds, fds.len, if (busy) 100 else 1000);
            if (fds[0].revents != 0) {
                const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
                if (linux.errno(rc) == .SUCCESS) {
                    const fd: linux.fd_t = @intCast(rc);
                    if (client(fd)) |who| for (&clients) |*c| {
                        if (c.* == null) {
                            c.* = .{ .fd = fd, .who = who };
                            break;
                        }
                    } else sys.close(fd) else {
                        _ = linux.write(fd, "denied\n", 7);
                        sys.close(fd);
                    }
                }
            }
            for (&clients, fds[1..]) |*c, f| {
                const conn = c.* orelse continue;
                if (f.revents == 0) continue;
                var buf: [256]u8 = undefined;
                const n = linux.read(conn.fd, &buf, buf.len);
                if (linux.errno(n) == .SUCCESS and n > 0) if (proto.Request.parse(buf[0..n])) |req| {
                    if (req.allowedFor(conn.who)) {
                        m.handle(req);
                        var out: [512]u8 = undefined;
                        const text = m.report.write(&out);
                        _ = linux.write(conn.fd, text.ptr, text.len);
                    } else _ = linux.write(conn.fd, "denied\n", 7);
                };
                // One request per connection.
                sys.close(conn.fd);
                c.* = null;
            }
            if (m.restart) restart();
        }
    }

    fn handle(m: *Manager, req: proto.Request) void {
        switch (req) {
            .status => {},
            .prepare => switch (m.report.storage) {
                .unprepared, .failed => m.prepare(),
                else => {},
            },
            .finish => |h| m.finish(h),
            .update => |sha256| m.startUpdate(sha256),
            .restart => m.restart = true,
        }
    }

    /// Starts installing the update Settings downloaded.
    fn startUpdate(m: *Manager, sha256: [64]u8) void {
        if (m.installer != null) return;
        const running = m.report.slot orelse return m.updateFailed(.busy);
        // Not while the other slot is being made.
        if (m.copier != null) return m.updateFailed(.busy);
        m.installer = update.Installer.start(sha256, running) catch |err| {
            print("dazzle: system: cannot start installing the update: {s}\n", .{@errorName(err)});
            return m.updateFailed(.io);
        };
        m.report.update = .installing;
        m.report.update_failure = .none;
    }

    fn updateFailed(m: *Manager, why: proto.UpdateFailure) void {
        m.report.update = .failed;
        m.report.update_failure = why;
    }

    fn fail(m: *Manager, why: proto.Failure, err: anyerror) void {
        print("dazzle: system: cannot prepare the card: {s} ({s})\n", .{ @tagName(why), @errorName(err) });
        m.stopFormatting();
        m.report.storage = .failed;
        m.report.failure = why;
    }

    /// Makes the partition for files and starts formatting it.
    fn prepare(m: *Manager) void {
        m.report.failure = .none;
        const disk = sys.open(storage.card, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch |err| return m.fail(.io, err);
        defer sys.close(disk);
        var mbr: [512]u8 = undefined;
        const n = sys.check(linux.pread(disk, &mbr, mbr.len, 0)) catch |err| return m.fail(.io, err);
        if (n != mbr.len) return m.fail(.io, error.ShortRead);
        const sectors = storage.diskSectors(disk) catch |err| return m.fail(.io, err);
        const plan = storage.planPartition(&mbr, sectors) catch |err| return m.fail(switch (err) {
            error.TooSmall => .too_small,
            error.NoRoom, error.NotMbr => .no_room,
            else => .io,
        }, err);
        print("dazzle: system: partition {d} for files: {d} MiB from {d} MiB\n", .{ @as(u32, plan.entry) + 1, plan.sectors / 2048, plan.start / 2048 });
        storage.addPartition(&mbr, plan);
        _ = sys.check(linux.pwrite(disk, &mbr, mbr.len, 0)) catch |err| return m.fail(.io, err);
        _ = linux.fsync(disk);
        storage.announcePartition(disk, plan) catch |err| return m.fail(.io, err);
        // The device node comes a moment after.
        var waited: u32 = 0;
        while (!storage.exists(storage.data_partition) and waited < 3000) : (waited += 50) sys.sleepMs(50);
        const fd = sys.open(storage.data_partition, .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch |err| return m.fail(.io, err);
        var uuid: [16]u8 = undefined;
        random(&uuid);
        // A random (version 4) UUID.
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        m.formatter = mkfs.Formatter.init(std.heap.page_allocator, fd, @as(u64, plan.sectors) * 512, uuid, @intCast(@max(ts.sec, 0))) catch |err| {
            sys.close(fd);
            return m.fail(if (err == error.TooSmall) .too_small else .io, err);
        };
        m.fd = fd;
        m.report.storage = .preparing;
        m.report.progress = 0;
        m.formatting = .{ .thread = undefined };
        m.formatting.?.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, formatAll, .{m}) catch |err| {
            m.formatting = null;
            return m.fail(.io, err);
        };
    }

    /// The formatting thread.
    fn formatAll(m: *Manager) void {
        const w = &m.formatting.?;
        defer w.done.store(true, .release);
        const f = &m.formatter.?;
        while (true) {
            const done = f.step() catch |err| {
                w.err = err;
                return;
            };
            w.percent.store(@intFromFloat(@min(f.progress() * 100, 100)), .monotonic);
            if (done) return;
        }
    }

    /// The copying thread.
    fn copyAll(m: *Manager) void {
        const w = &m.copying.?;
        defer w.done.store(true, .release);
        m.copier.?.run() catch |err| {
            w.err = err;
        };
    }

    fn startCopying(m: *Manager) void {
        m.copying = .{ .thread = undefined };
        m.copying.?.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, copyAll, .{m}) catch |err| {
            print("dazzle: system: cannot copy the OS slot: {s}\n", .{@errorName(err)});
            m.copying = null;
            m.copier.?.deinit();
            m.copier = null;
            return;
        };
    }

    /// How formatting goes; once it is done, mounts the filesystem.
    fn checkFormatting(m: *Manager) void {
        const w = &(m.formatting orelse return);
        m.report.progress = @intCast(w.percent.load(.monotonic));
        if (!w.finished()) return;
        w.thread.join();
        const err = w.err;
        m.formatting = null;
        if (err) |e| return m.fail(.io, e);
        const f = &m.formatter.?;
        print("dazzle: system: formatted {s} ({d} MiB)\n", .{ storage.data_partition, @as(u64, f.layout.blocks) * mkfs.block_size >> 20 });
        m.stopFormatting();
        if (!storage.mountData()) return m.fail(.mount, error.MountFailed);
        // The system's settings belong to root; the user's files to the user.
        _ = linux.mkdir(proto.config_dir, 0o755);
        _ = linux.chown(proto.config_dir, 0, 0);
        _ = linux.mkdir(proto.user_dir, 0o700);
        // The apps go there too, and updates.
        storage.makeUserDirs();
        m.report.storage = .ready;
    }

    /// Whether the OS slot has been copied.
    fn checkCopying(m: *Manager) void {
        const w = &(m.copying orelse return);
        if (!w.finished()) return;
        w.thread.join();
        if (w.err) |err| print("dazzle: system: cannot copy the OS slot: {s}\n", .{@errorName(err)});
        m.copying = null;
        m.copier = null;
        m.readSlots();
    }

    fn stopFormatting(m: *Manager) void {
        if (m.formatter) |*f| f.deinit();
        m.formatter = null;
        if (m.fd) |fd| sys.close(fd);
        m.fd = null;
    }

    /// Names the computer and, if the card is ready, keeps the name and
    /// marks setup finished there.
    fn finish(m: *Manager, h: proto.Hostname) void {
        const name = h.slice();
        if (sys.check(linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len))) |_| {
            m.report.hostname = h;
            print("dazzle: system: named {s}\n", .{name});
        } else |err| print("dazzle: system: cannot set the hostname: {s}\n", .{@errorName(err)});
        if (m.report.storage == .ready) {
            var line: [80]u8 = undefined;
            writeFile(proto.hostname_file, std.fmt.bufPrint(&line, "{s}\n", .{name}) catch name);
            writeFile(proto.setup_done_file, "");
        }
        m.finished = true;
    }
};

/// Writes a small root-owned file.
fn writeFile(path: [*:0]const u8, data: []const u8) void {
    const fd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }) catch |err| {
        print("dazzle: system: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer sys.close(fd);
    _ = linux.write(fd, data.ptr, data.len);
    _ = linux.fsync(fd);
    // The mode first: once it is root's, this process cannot change it.
    _ = linux.fchmod(fd, 0o644);
    _ = linux.fchown(fd, 0, 0);
}

fn random(buf: []u8) void {
    var at: usize = 0;
    while (at < buf.len) {
        const rc = linux.getrandom(buf[at..].ptr, buf.len - at, 0);
        if (linux.errno(rc) == .SUCCESS) at += rc;
    }
}

/// Restarts the computer: what is written goes to the card first.
fn restart() noreturn {
    print("dazzle: system: restarting\n", .{});
    linux.sync();
    _ = linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
    print("dazzle: system: cannot restart\n", .{});
    linux.exit(1);
}

/// Which app the process at the other end of `fd` runs, if it is one the
/// manager serves.
fn client(fd: linux.fd_t) ?proto.Client {
    const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len)) != .SUCCESS) return null;
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/exe", .{cred.pid}) catch return null;
    var exe: [256]u8 = undefined;
    const n = sys.check(linux.readlink(path.ptr, &exe, exe.len)) catch return null;
    if (std.mem.eql(u8, exe[0..n], proto.setup_program)) return .setup;
    if (std.mem.eql(u8, exe[0..n], proto.settings_program)) return .settings;
    print("dazzle: system: refused {s} (pid {d})\n", .{ exe[0..n], cred.pid });
    return null;
}

/// The listening socket, replacing a stale one; only the user can connect.
fn listen(path: [:0]const u8) !linux.fd_t {
    const fd: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    _ = linux.unlink(path);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    _ = try sys.check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    _ = linux.fchmodat(linux.AT.FDCWD, path, 0o600);
    _ = try sys.check(linux.listen(fd, 4));
    return fd;
}

test "a process running another program is refused" {
    var pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try std.testing.expect(client(pair[0]) == null);
}
