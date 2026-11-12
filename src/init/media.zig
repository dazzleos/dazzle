//! The media manager: mounts USB drives as they are plugged in, and
//! unmounts them when the user ejects them (or pulls them out).
//!
//! Init forks it at boot (and again if it stops). It runs as the Dazzle
//! user, keeping only the capabilities this needs: mounting
//! (CAP_SYS_ADMIN), and reading a drive's start to see what is on it
//! (CAP_DAC_READ_SEARCH: the kernel's device nodes are root's). It mounts
//! what is there at start, then listens for the kernel's uevents: each
//! USB drive (sd*), and each of its partitions, holding a filesystem it
//! knows (volume.zig) is mounted at /media/<its label> ("USB drive" if it
//! has none), the user's, with no programs that change user (nosuid), no
//! devices and no access times (to spare the flash).
//!
//! It listens on /os/sockets/media (see `sys.media`): ejecting writes what
//! is left to the drive and unmounts it, unless a file on it is open. A
//! drive pulled out without being ejected is unmounted all the same, as
//! soon as nothing uses it.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const volume = @import("volume.zig");

const proto = sys.media;
const print = sys.print;

const max_mounts = 16;
/// umount2: unmount once nothing uses it.
const mnt_detach = 2;
const max_clients = 4;

/// What a drive with no label is called.
const unnamed = "USB drive";

/// Forks the manager. Returns its PID, or null if it could not be started.
pub fn start() ?linux.pid_t {
    // The drives' folders are made in /media, which is the user's.
    _ = linux.mkdir(proto.media_dir, 0o755);
    _ = linux.chown(proto.media_dir, sys.user.uid, sys.user.gid);
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc != 0) return @intCast(rc),
        else => |e| {
            print(sys.log_error ++ "dazzle: media: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    sys.dropPrivilegesKeeping(&.{ .sys_admin, .dac_read_search }) catch |err| {
        print(sys.log_warning ++ "dazzle: media: cannot drop privileges ({s})\n", .{@errorName(err)});
        linux.exit(1);
    };
    sys.ignoreBrokenPipes();
    var m: Manager = .{};
    m.run() catch |err| print("dazzle: media: {s}\n", .{@errorName(err)});
    linux.exit(1);
}

/// A drive (or partition) mounted, or ejected and not yet pulled out.
const Mount = struct {
    dev_buf: [16]u8 = undefined,
    dev_len: usize = 0,
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    ejected: bool = false,

    fn dev(m: *const Mount) []const u8 {
        return m.dev_buf[0..m.dev_len];
    }

    fn name(m: *const Mount) []const u8 {
        return m.name_buf[0..m.name_len];
    }

    fn path(m: *const Mount, buf: []u8) ?[:0]const u8 {
        return std.mem.printSentinel(buf, "{s}/{s}", .{ proto.media_dir, m.name() }, 0) catch null;
    }
};

const Manager = struct {
    mounts: [max_mounts]?Mount = @splat(null),

    fn run(m: *Manager) !void {
        // Listen first, so no drive is missed between the scan and the loop.
        const uevents: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, linux.NETLINK.KOBJECT_UEVENT)));
        var addr: linux.sockaddr.nl = .{ .pid = 0, .groups = 1 };
        _ = try sys.check(linux.bind(uevents, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)));
        const listener = try listen(proto.socket_path);
        m.scan();

        var clients: [max_clients]?linux.fd_t = @splat(null);
        while (true) {
            var fds: [2 + max_clients]linux.pollfd = undefined;
            fds[0] = .{ .fd = uevents, .events = linux.POLL.IN, .revents = 0 };
            fds[1] = .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 };
            for (clients, fds[2..]) |c, *f| f.* = .{ .fd = c orelse -1, .events = linux.POLL.IN, .revents = 0 };
            _ = linux.poll(&fds, fds.len, -1);
            if (fds[0].revents != 0) {
                var buf: [4096]u8 = undefined;
                const rc = linux.recvfrom(uevents, &buf, buf.len, 0, null, null);
                if (linux.errno(rc) == .SUCCESS) if (Uevent.parse(buf[0..rc])) |e| switch (e.action) {
                    .add => m.add(e.dev),
                    .remove => m.remove(e.dev),
                };
            }
            if (fds[1].revents != 0) {
                const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
                if (linux.errno(rc) == .SUCCESS) {
                    const fd: linux.fd_t = @intCast(rc);
                    for (&clients) |*c| {
                        if (c.* == null) {
                            c.* = fd;
                            break;
                        }
                    } else sys.close(fd);
                }
            }
            for (&clients, fds[2..]) |*c, f| {
                const fd = c.* orelse continue;
                if (f.revents == 0) continue;
                var buf: [256]u8 = undefined;
                const n = linux.read(fd, &buf, buf.len);
                if (linux.errno(n) == .SUCCESS and n > 0) {
                    const answer: proto.Answer = if (proto.parseEject(buf[0..n])) |name| m.eject(name) else .failed;
                    var out: [16]u8 = undefined;
                    const text = std.fmt.bufPrint(&out, "{s}\n", .{@tagName(answer)}) catch unreachable;
                    _ = linux.write(fd, text.ptr, text.len);
                }
                // One request per connection.
                sys.close(fd);
                c.* = null;
            }
        }
    }

    /// Mounts the drives there already are.
    fn scan(m: *Manager) void {
        const dir = sys.open("/sys/class/block", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
        defer sys.close(dir);
        var dents: [4096]u8 align(8) = undefined;
        while (true) {
            const n = sys.check(linux.getdents64(dir, &dents, dents.len)) catch return;
            if (n == 0) return;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
                const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
                at += reclen;
                if (isDrive(name)) m.add(name);
            }
        }
    }

    fn find(m: *Manager, dev: []const u8) ?*Mount {
        for (&m.mounts) |*s| if (s.*) |*mt| if (std.mem.eql(u8, mt.dev(), dev)) return mt;
        return null;
    }

    fn add(m: *Manager, dev: []const u8) void {
        if (dev.len > 15 or m.find(dev) != null) return;
        const slot = for (&m.mounts) |*s| {
            if (s.* == null) break s;
        } else return;
        var dev_path_buf: [32]u8 = undefined;
        const dev_path = std.mem.printSentinel(&dev_path_buf, "/dev/{s}", .{dev}, 0) catch return;
        const vol = probe(dev_path) orelse return;

        var mt: Mount = .{ .dev_len = dev.len };
        @memcpy(mt.dev_buf[0..dev.len], dev);
        // Named by its label; another drive with the same gets a number.
        var base_buf: [64]u8 = undefined;
        const base = volume.folderName(&base_buf, vol.label(), unnamed);
        var path_buf: [128]u8 = undefined;
        var path: [:0]const u8 = undefined;
        var n: usize = 1;
        while (true) : (n += 1) {
            const name = (if (n == 1) std.fmt.bufPrint(&mt.name_buf, "{s}", .{base}) else std.fmt.bufPrint(&mt.name_buf, "{s} {d}", .{ base, n })) catch return;
            mt.name_len = name.len;
            path = mt.path(&path_buf) orelse return;
            if (linux.errno(linux.mkdir(path, 0o755)) == .SUCCESS) break;
            if (n == 99) return;
        }

        var options_buf: [128]u8 = undefined;
        const options: ?[:0]const u8 = switch (vol.kind) {
            // The user's (FAT, exFAT and NTFS have no owners of their own),
            // with no file a program.
            .fat => std.mem.printSentinel(&options_buf, "uid={d},gid={d},fmask=0133,dmask=0022,utf8,shortname=mixed,flush", .{ sys.user.uid, sys.user.gid }, 0) catch null,
            .exfat, .ntfs => std.mem.printSentinel(&options_buf, "uid={d},gid={d},fmask=0133,dmask=0022", .{ sys.user.uid, sys.user.gid }, 0) catch null,
            .ext => null,
        };
        const flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOATIME;
        _ = sys.check(linux.mount(dev_path, path, vol.kind.fsType(), flags, if (options) |o| @intFromPtr(o.ptr) else 0)) catch |err| {
            print(sys.log_warning ++ "dazzle: media: cannot mount {s} ({s}) at {s}: {s}\n", .{ dev_path, vol.kind.fsType(), path, @errorName(err) });
            _ = linux.rmdir(path);
            return;
        };
        print("dazzle: media: mounted {s} ({s}) at {s}\n", .{ dev_path, vol.kind.fsType(), path });
        slot.* = mt;
    }

    fn remove(m: *Manager, dev: []const u8) void {
        const mt = m.find(dev) orelse return;
        if (!mt.ejected) {
            var buf: [128]u8 = undefined;
            if (mt.path(&buf)) |path| {
                // Gone: whatever was not written is lost. It is unmounted
                // once nothing uses it.
                _ = linux.umount2(path, mnt_detach);
                _ = linux.rmdir(path);
                print("dazzle: media: {s} was pulled out without being ejected\n", .{path});
            }
        }
        for (&m.mounts) |*s| if (s.*) |*x| if (x == mt) {
            s.* = null;
        };
    }

    fn eject(m: *Manager, name: []const u8) proto.Answer {
        const mt = for (&m.mounts) |*s| {
            if (s.*) |*x| if (!x.ejected and std.mem.eql(u8, x.name(), name)) break x;
        } else return .unknown;
        var buf: [128]u8 = undefined;
        const path = mt.path(&buf) orelse return .failed;
        // Write everything first: unmounting writes it too, but this way
        // it is written even if something keeps the drive busy.
        if (sys.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true })) |fd| {
            _ = linux.syncfs(fd);
            sys.close(fd);
        } else |_| {}
        switch (linux.errno(linux.umount2(path, 0))) {
            .SUCCESS => {},
            .BUSY => return .busy,
            else => |e| {
                print(sys.log_warning ++ "dazzle: media: cannot unmount {s} ({s})\n", .{ path, @tagName(e) });
                return .failed;
            },
        }
        _ = linux.rmdir(path);
        mt.ejected = true;
        print("dazzle: media: ejected {s}\n", .{path});
        return .ejected;
    }
};

/// Whether `name` (in /dev) is a USB drive or one of its partitions; the
/// SD card is mmcblk0.
fn isDrive(name: []const u8) bool {
    return name.len >= 3 and std.mem.startsWith(u8, name, "sd") and std.ascii.isLower(name[2]);
}

/// What filesystem the device holds.
fn probe(dev_path: [:0]const u8) ?volume.Volume {
    const fd = sys.open(dev_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch |err| {
        print(sys.log_warning ++ "dazzle: media: cannot read {s}: {s}\n", .{ dev_path, @errorName(err) });
        return null;
    };
    defer sys.close(fd);
    const Dev = struct {
        fn readAt(ctx: *const anyopaque, offset: u64, buf: []u8) bool {
            const f: *const linux.fd_t = @ptrCast(@alignCast(ctx));
            var done: usize = 0;
            while (done < buf.len) {
                const rc = linux.pread(f.*, buf[done..].ptr, buf.len - done, @intCast(offset + done));
                if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
                done += rc;
            }
            return true;
        }
    };
    return volume.probe(.{ .ctx = &fd, .f = Dev.readAt });
}

const Uevent = struct {
    action: enum { add, remove },
    dev: []const u8,

    /// A USB drive (or partition) coming or going.
    fn parse(msg: []const u8) ?Uevent {
        var action: []const u8 = "";
        var subsystem: []const u8 = "";
        var devname: []const u8 = "";
        var fields = std.mem.splitScalar(u8, msg, 0);
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "ACTION=")) action = field["ACTION=".len..];
            if (std.mem.startsWith(u8, field, "SUBSYSTEM=")) subsystem = field["SUBSYSTEM=".len..];
            if (std.mem.startsWith(u8, field, "DEVNAME=")) devname = field["DEVNAME=".len..];
        }
        if (!std.mem.eql(u8, subsystem, "block") or !isDrive(devname)) return null;
        if (std.mem.eql(u8, action, "add")) return .{ .action = .add, .dev = devname };
        if (std.mem.eql(u8, action, "remove")) return .{ .action = .remove, .dev = devname };
        return null;
    }
};

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

test "USB drives' uevents" {
    const add = Uevent.parse("add@/devices/platform/soc/20980000.usb/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sda/sda1\x00ACTION=add\x00SUBSYSTEM=block\x00DEVNAME=sda1\x00DEVTYPE=partition\x00").?;
    try std.testing.expect(add.action == .add);
    try std.testing.expectEqualStrings("sda1", add.dev);
    try std.testing.expect(Uevent.parse("remove@/x\x00ACTION=remove\x00SUBSYSTEM=block\x00DEVNAME=sdb\x00").?.action == .remove);
    // Not the SD card, nor anything else.
    try std.testing.expect(Uevent.parse("add@/x\x00ACTION=add\x00SUBSYSTEM=block\x00DEVNAME=mmcblk0p2\x00") == null);
    try std.testing.expect(Uevent.parse("add@/x\x00ACTION=add\x00SUBSYSTEM=scsi_disk\x00DEVNAME=sda\x00") == null);
    try std.testing.expect(Uevent.parse("change@/x\x00ACTION=change\x00SUBSYSTEM=block\x00DEVNAME=sda\x00") == null);
}
