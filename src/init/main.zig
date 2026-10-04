//! Dazzle init: PID 1.
//!
//! Init is the only process that keeps root privileges. It:
//!
//! 1. mounts /proc, /sys and /dev, and sends its messages to the kernel log;
//! 2. creates the user's runtime directory (/run/user/1000, for the
//!    Wayland socket and the network manager's), starts the network
//!    manager (see network.zig), which brings the wired and Wi-Fi network
//!    up in the background and answers the settings app, and the log server
//!    (which drops to the Dazzle user once it has bound its port); boot
//!    never waits for the network;
//! 3. starts the device manager (see devices.zig), which gives the Dazzle
//!    user the input devices (USB keyboards and mice), now and when they
//!    are plugged in; waits for the vc4 GPU and gives the Dazzle user access to its device
//!    nodes;
//! 4. starts /shell/dazzle-shell, the Wayland compositor, as the Dazzle
//!    user, with its output going to the kernel log; its dock starts the
//!    apps in /apps;
//! 5. reaps exited processes forever (PID 1 must never exit), restarting the
//!    network and device managers if they ever stop.
//!
//! The Dazzle user is just a user ID (see `sys.user`): there are no
//! accounts, passwords or logins.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const logserver = @import("logserver.zig");
const network = @import("network.zig");
const devices = @import("devices.zig");
const build_info = @import("build_info");

const print = sys.print;

const shell_path = "/shell/dazzle-shell";
const runtime_dir = "/run/user/1000";

pub fn main() void {
    if (linux.getpid() != 1) {
        print("dazzle-init must run as PID 1\n", .{});
        linux.exit(1);
    }
    mountPseudoFilesystems();
    sys.logToKmsg();
    print("dazzle: starting as init (build {s})\n", .{build_info.commit});
    _ = linux.syscall2(.sethostname, @intFromPtr(network.hostname), network.hostname.len);
    makeRuntimeDir();
    const network_pid = network.start(runtime_dir);
    logserver.start();
    const devices_pid = devices.start();
    grantGpuAccess();
    const shell_pid = startShell();
    reapForever(shell_pid, network_pid, devices_pid);
}

fn mountPseudoFilesystems() void {
    const mounts = [_]struct { src: [*:0]const u8, dir: [*:0]const u8, fstype: [*:0]const u8, flags: u32 }{
        .{ .src = "proc", .dir = "/proc", .fstype = "proc", .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC },
        .{ .src = "sysfs", .dir = "/sys", .fstype = "sysfs", .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC },
        .{ .src = "devtmpfs", .dir = "/dev", .fstype = "devtmpfs", .flags = linux.MS.NOSUID },
    };
    for (mounts) |m| {
        _ = linux.mkdir(m.dir, 0o755);
        _ = sys.check(linux.mount(m.src, m.dir, m.fstype, m.flags, 0)) catch |err|
            print("dazzle: mount {s}: {s}\n", .{ m.dir, @errorName(err) });
    }
}

const max_cards = 4;

/// Whether DRM card `n` is the vc4 display driver, from its sysfs driver
/// link (".../drivers/vc4-drm").
fn isVc4Card(n: usize) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/drm/card{d}/device/driver", .{n}) catch return false;
    var link: [256]u8 = undefined;
    const len = sys.check(linux.readlink(path.ptr, &link, link.len)) catch return false;
    return std.mem.endsWith(u8, link[0..len], "/vc4-drm");
}

/// DRM device nodes are created root-only (0600). Once the vc4 driver has
/// probed (it may still be loading firmware or waiting for other devices
/// when init starts), hand every DRM node to the Dazzle user. The first
/// process to open a card becomes its DRM master, which it needs for mode
/// setting; init itself never opens them.
fn grantGpuAccess() void {
    var found = false;
    var attempt: u32 = 0;
    while (!found and attempt < 100) : (attempt += 1) {
        for (0..max_cards) |n| found = found or isVc4Card(n);
        if (!found) sys.sleepMs(100);
    }
    if (!found) print("dazzle: no vc4 DRM device after 10 s\n", .{});

    var path_buf: [32]u8 = undefined;
    for (0..max_cards) |n| {
        for ([_]struct { []const u8, usize }{ .{ "card", n }, .{ "renderD", 128 + n } }) |node| {
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/dri/{s}{d}", .{ node[0], node[1] }) catch continue;
            _ = sys.check(linux.chown(path.ptr, sys.user.uid, sys.user.gid)) catch continue;
            _ = linux.fchmodat(linux.AT.FDCWD, path.ptr, 0o660);
        }
    }
}

/// The directory for the user's sockets, readable only by the user.
fn makeRuntimeDir() void {
    for ([_][*:0]const u8{ "/run", "/run/user", runtime_dir }) |dir| _ = linux.mkdir(dir, 0o755);
    _ = linux.chown(runtime_dir, sys.user.uid, sys.user.gid);
    _ = linux.fchmodat(linux.AT.FDCWD, runtime_dir, 0o700);
}

/// Starts the shell as the Dazzle user. Returns its PID, or null if it
/// could not be started.
fn startShell() ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            print("dazzle: cannot start the shell: fork failed ({s})\n", .{@tagName(e)});
            return null;
        },
    }
    if (rc != 0) {
        const pid: linux.pid_t = @intCast(rc);
        print("dazzle: started {s} (pid {d}) as uid {d}\n", .{ shell_path, pid, sys.user.uid });
        return pid;
    }

    // The child. Its output goes to the kernel log: it inherits init's
    // /dev/kmsg descriptor, since only root may open that for writing.
    if (sys.kmsgFd()) |kmsg| {
        _ = linux.dup2(kmsg, 1);
        _ = linux.dup2(kmsg, 2);
    }
    sys.dropPrivileges() catch |err| {
        print("dazzle: cannot drop privileges ({s}); not starting the shell\n", .{@errorName(err)});
        linux.exit(126);
    };
    const argv = [_:null]?[*:0]const u8{shell_path};
    const envp = [_:null]?[*:0]const u8{ "HOME=/", "USER=" ++ sys.user.name, "XDG_RUNTIME_DIR=" ++ runtime_dir };
    const err = linux.errno(linux.execve(shell_path, &argv, &envp));
    print("dazzle: cannot run {s} ({s})\n", .{ shell_path, @tagName(err) });
    linux.exit(127);
}

/// Waits for child processes, logging how the shell ends. Processes whose
/// parent exits are re-parented to init, so this also collects those.
fn reapForever(shell_pid: ?linux.pid_t, first_network_pid: ?linux.pid_t, first_devices_pid: ?linux.pid_t) noreturn {
    var network_pid = first_network_pid;
    var devices_pid = first_devices_pid;
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, &status, 0, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // No children left: wait for signals forever.
            .CHILD => {
                _ = linux.pause();
                continue;
            },
            else => continue,
        }
        const pid: linux.pid_t = @intCast(rc);
        if (pid == network_pid) {
            print("dazzle: network manager stopped (status 0x{x}); restarting it in 5 s\n", .{status});
            sys.sleepMs(5000);
            network_pid = network.start(runtime_dir);
            continue;
        }
        if (pid == devices_pid) {
            print("dazzle: device manager stopped (status 0x{x}); restarting it in 5 s\n", .{status});
            sys.sleepMs(5000);
            devices_pid = devices.start();
            continue;
        }
        if (pid != shell_pid) continue;
        if (linux.W.IFEXITED(status)) {
            print("dazzle: shell exited with status {d}\n", .{linux.W.EXITSTATUS(status)});
        } else if (linux.W.IFSIGNALED(status)) {
            print("dazzle: shell killed by signal {d}\n", .{linux.W.TERMSIG(status)});
        }
    }
}

test {
    _ = @import("logserver.zig");
    _ = @import("network.zig");
    _ = @import("dhcp.zig");
    _ = @import("devices.zig");
    _ = @import("nl80211.zig");
    _ = @import("supplicant.zig");
}
