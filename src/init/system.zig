//! The system manager: on the first run, while the setup app runs, it
//! prepares the SD card's free space for files and names the computer.
//!
//! Init forks it until setup has finished, and while an OS slot is to be
//! made (below). It runs as the Dazzle user,
//! keeping only the capabilities this needs: writing the card, mounting it
//! and setting the hostname (CAP_SYS_ADMIN), writing the card's device and
//! the root-owned /data (CAP_DAC_OVERRIDE), and giving /data/system to root
//! (CAP_CHOWN). It listens on /os/sockets/system (see `sys.system` for
//! the protocol) and answers only the setup app: the program the
//! connecting process runs must be /os/shell/dazzle-setup.
//!
//! Preparing (asked for when setup starts, so it goes on while the user
//! fills in the pages): a partition after the system's to the end of the
//! card (storage.zig), an empty filesystem on it, written a few block
//! groups at a time between requests so the app can show how far it has
//! got (mkfs.zig), then mounted at /data with /data/system and /data/user
//! in it. Finishing sets the hostname, keeps it in /data/system with a
//! mark that setup has finished, and ends the manager.
//!
//! Meanwhile, from the start, it copies the running OS slot to the other
//! (slots.zig), the image having only one, a slice at a time like
//! formatting; it ends once that is done too. (If setup has finished, as
//! when the power went before the copy did, it only copies.)

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const storage = @import("storage.zig");
const mkfs = @import("mkfs.zig");
const slots = @import("slots.zig");
const apps = @import("apps.zig");

const proto = sys.system;
const print = sys.print;

const max_clients = 4;
/// How long formatting works before looking at the socket again.
const slice_ns = 50 * std.time.ns_per_ms;

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
    sys.dropPrivilegesKeeping(&.{ .sys_admin, .dac_override, .chown }) catch |err| {
        print("dazzle: system: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    var m: Manager = .{ .report = .{ .storage = if (mounted) .ready else if (card) .unprepared else .none }, .finished = setup_done };
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) == .SUCCESS) m.report.hostname = proto.Hostname.parse(std.mem.sliceTo(&uts.nodename, 0)) orelse .{};
    if (card) m.copier = slots.Copier.start(slot orelse 'a') catch |err| blk: {
        print("dazzle: system: cannot copy the OS slot: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    m.run() catch |err| print("dazzle: system: {s}\n", .{@errorName(err)});
    linux.exit(if (m.finished) 0 else 1);
}

const Manager = struct {
    report: proto.Report,
    /// Formatting, and the partition's device.
    formatter: ?mkfs.Formatter = null,
    fd: ?linux.fd_t = null,
    /// Copying the OS slot.
    copier: ?slots.Copier = null,
    finished: bool = false,

    fn run(m: *Manager) !void {
        const path = proto.socket_path;
        const listener = try listen(path);
        defer {
            sys.close(listener);
            _ = linux.unlink(path);
        }
        var clients: [max_clients]?linux.fd_t = @splat(null);
        while (!m.finished or m.copier != null) {
            // While formatting or copying, only look at the socket between
            // slices.
            const busy = m.formatter != null or m.copier != null;
            if (m.formatter != null) m.format();
            if (m.copier != null) m.copySlot();

            var fds: [1 + max_clients]linux.pollfd = undefined;
            fds[0] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
            for (clients, fds[1..]) |c, *f| f.* = .{ .fd = c orelse -1, .events = linux.POLL.IN, .revents = 0 };
            _ = linux.poll(&fds, fds.len, if (busy) 0 else 1000);
            if (fds[0].revents != 0) {
                const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
                if (linux.errno(rc) == .SUCCESS) {
                    const fd: linux.fd_t = @intCast(rc);
                    if (!allowed(fd)) {
                        _ = linux.write(fd, "denied\n", 7);
                        sys.close(fd);
                    } else for (&clients) |*c| {
                        if (c.* == null) {
                            c.* = fd;
                            break;
                        }
                    } else sys.close(fd);
                }
            }
            for (&clients, fds[1..]) |*c, f| {
                const fd = c.* orelse continue;
                if (f.revents == 0) continue;
                var buf: [256]u8 = undefined;
                const n = linux.read(fd, &buf, buf.len);
                if (linux.errno(n) == .SUCCESS and n > 0) if (proto.Request.parse(buf[0..n])) |req| {
                    m.handle(req);
                    var out: [256]u8 = undefined;
                    const text = m.report.write(&out);
                    _ = linux.write(fd, text.ptr, text.len);
                };
                // One request per connection.
                sys.close(fd);
                c.* = null;
            }
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
        }
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
    }

    /// Formats for a slice of time; mounts the filesystem once it is done.
    fn format(m: *Manager) void {
        const f = &(m.formatter orelse return);
        const until = sys.nowNs() + slice_ns;
        while (sys.nowNs() < until) {
            const done = f.step() catch |err| return m.fail(.io, err);
            if (done) break;
        }
        m.report.progress = @intFromFloat(@min(f.progress() * 100, 100));
        if (!f.done) return;
        print("dazzle: system: formatted {s} ({d} MiB)\n", .{ storage.data_partition, @as(u64, f.layout.blocks) * mkfs.block_size >> 20 });
        m.stopFormatting();
        if (!storage.mountData()) return m.fail(.mount, error.MountFailed);
        // The system's settings belong to root; the user's files to the user.
        _ = linux.mkdir(proto.config_dir, 0o755);
        _ = linux.chown(proto.config_dir, 0, 0);
        _ = linux.mkdir(proto.user_dir, 0o700);
        // The apps go there too, where Settings installs them.
        apps.useInstalled();
        m.report.storage = .ready;
    }

    /// Copies the OS slot for a slice of time.
    fn copySlot(m: *Manager) void {
        const c = &(m.copier orelse return);
        const until = sys.nowNs() + slice_ns;
        while (sys.nowNs() < until) {
            const done = c.step() catch |err| {
                print("dazzle: system: cannot copy the OS slot: {s}\n", .{@errorName(err)});
                c.deinit();
                m.copier = null;
                return;
            };
            if (done) {
                m.copier = null;
                return;
            }
        }
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

/// Whether the process at the other end of `fd` runs the setup app.
fn allowed(fd: linux.fd_t) bool {
    const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len)) != .SUCCESS) return false;
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/exe", .{cred.pid}) catch return false;
    var exe: [256]u8 = undefined;
    const n = sys.check(linux.readlink(path.ptr, &exe, exe.len)) catch return false;
    const ok = std.mem.eql(u8, exe[0..n], proto.allowed_program);
    if (!ok) print("dazzle: system: refused {s} (pid {d})\n", .{ exe[0..n], cred.pid });
    return ok;
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
    try std.testing.expect(!allowed(pair[0]));
}
