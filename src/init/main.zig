//! Dazzle init: PID 1.
//!
//! Init is the only process that keeps root privileges. It:
//!
//! 1. mounts /proc, /sys and /dev, and sends its messages to the kernel log;
//! 2. waits a moment for the SD card and mounts its space for files at
//!    /data (if setup has prepared it), and names the computer as kept
//!    there (or "dazzle");
//! 3. starts the network manager (see
//!    network.zig), which brings the wired and Wi-Fi network up in the
//!    background and answers the settings app, and the log server (which
//!    drops to the Dazzle user once it has bound its port); boot never
//!    waits for the network;
//! 4. starts the device manager (see devices.zig), which gives the Dazzle
//!    user the input, camera, audio, GPIO, I2C and serial devices, now and
//!    when they are plugged in; waits for the vc4/v3d GPU and gives the
//!    Dazzle user access to its device nodes;
//! 5. starts the media manager (see media.zig), which mounts USB drives
//!    in /media as they are plugged in, and unmounts them when they are
//!    ejected;
//! 6. starts the system manager (see system.zig), which prepares the card
//!    and names the computer for the setup app, makes the second OS slot
//!    (also later, if that was cut off), and installs updates for the
//!    settings app;
//! 7. starts /os/shell/dazzle-shell, the Wayland compositor, as the Dazzle
//!    user (with --setup until setup has finished), with its output going
//!    to the kernel log; its dock starts the apps;
//! 8. reaps exited processes forever (PID 1 must never exit), restarting the
//!    shell and the network, device, media and system managers if they ever
//!    stop; and, when this start tries an update, keeps it once the shell has
//!    run for a minute, or restarts into the system before if the shell stops
//!    first (see trial.zig).
//!
//! The Dazzle user is just a user ID (see `sys.user`): there are no
//! accounts, passwords or logins.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const logserver = @import("logserver.zig");
const network = @import("network.zig");
const devices = @import("devices.zig");
const media = @import("media.zig");
const storage = @import("storage.zig");
const system = @import("system.zig");
const trial = @import("trial.zig");
const build_info = @import("build_info");

const print = sys.print;

const shell_path = "/os/shell/dazzle-shell";

pub fn main() void {
    if (linux.getpid() != 1) {
        print("dazzle-init must run as PID 1\n", .{});
        linux.exit(1);
    }
    mountPseudoFilesystems();
    prepareRoot();
    sys.logToKmsg();
    print("dazzle: starting as init (build {s})\n", .{build_info.commit});
    // The card's files (and the computer's name, kept there once setup has
    // finished; until then, setup names it).
    const card = storage.boot();
    const name = card.hostname.slice();
    if (name.len > 0) _ = linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len);
    const network_pid = network.start();
    logserver.start();
    const devices_pid = devices.start();
    grantGpuAccess();
    const media_pid = media.start();
    // Until setup has finished, the shell runs the setup app (and nothing
    // else), and the system manager prepares the card and names the
    // computer for it. It also makes the second OS slot, if that is still
    // to be made, and later installs updates.
    const system_pid = system.start(card.card, card.mounted, card.slot, card.setup_done);
    const shell_pid = startShell(!card.setup_done);
    // Trying an update: the watchdog runs until it has worked, which is
    // when the shell has run for a while (the timer, a child process that
    // ends then).
    var t: Trying = .{};
    if (card.trial == .trying) {
        t.watchdog = trial.Watchdog.start();
        t.timer = startTimer(trial.healthy_ns);
    }
    reapForever(shell_pid, network_pid, devices_pid, media_pid, system_pid, card, &t);
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

/// The kernel unpacks a default initramfs of its own before ours, which
/// makes an empty /root; nothing uses it. (Dazzle's own files are in /os,
/// with the Dazzle user's sockets in /os/sockets, which is the user's.)
fn prepareRoot() void {
    _ = linux.rmdir("/root");
}

const max_cards = 4;

/// Whether DRM card `n` is bound to `driver_suffix` (e.g. "/vc4-drm" or "/v3d").
fn isDrmDriverCard(n: usize, driver_suffix: []const u8) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/drm/card{d}/device/driver", .{n}) catch return false;
    var link: [256]u8 = undefined;
    const len = sys.check(linux.readlink(path.ptr, &link, link.len)) catch return false;
    return std.mem.endsWith(u8, link[0..len], driver_suffix);
}

/// Whether the board is a BCM2711 (Raspberry Pi 4) or BCM2712 (Raspberry Pi 5),
/// where 3D rendering is driven by the separate `v3d` DRM driver alongside
/// `vc4-drm` for display.
fn needsV3d() bool {
    var buf: [128]u8 = undefined;
    const compat = sys.readFile("/sys/firmware/devicetree/base/compatible", &buf) orelse return false;
    return std.mem.indexOf(u8, compat, "brcm,bcm2711") != null or
        std.mem.indexOf(u8, compat, "brcm,bcm2712") != null;
}

/// The display's and GPU's parts in the device tree (platform devices
/// named for their nodes), which the vc4 and v3d drivers bind together.
const display_parts = [_][]const u8{ ".hdmi", ".hvs", ".v3d", ".txp", ".pixelvalve", ".mop", ".moplet", ".dvp", ".cprman", ":gpu", ":firmware", ":clocks", ":power", ".i2c", ".dma", ".dma-controller", ".gpio", ".mailbox" };

/// Says which of the display's parts have no driver, and what each waits
/// for (its suppliers, by device link, that are not ready), so a log shows
/// why vc4 did not come.
fn reportDisplayDevices() void {
    // Whether the device tree has vc4 on at all: config.txt's
    // dtoverlay=vc4-kms-v3d turns it on, if the firmware applied it.
    var buf: [32]u8 = undefined;
    const status = sys.readFile("/sys/firmware/devicetree/base/soc/gpu/status", &buf) orelse
        sys.readFile("/sys/firmware/devicetree/base/gpu/status", &buf);
    print("dazzle: device tree: vc4 (gpu) is {s}\n", .{if (status) |st| std.mem.sliceTo(st, 0) else "not there"});
    const base = "/sys/bus/platform/devices";
    const dir = sys.open(base, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
    defer sys.close(dir);
    var dents: [8192]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(dir, &dents, dents.len)) catch return;
        if (n == 0) return;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
            at += reclen;
            const part = for (display_parts) |suffix| {
                if (std.mem.endsWith(u8, name, suffix)) break true;
            } else false;
            if (part) reportDevice(base, name);
        }
    }
}

fn reportDevice(base: []const u8, name: []const u8) void {
    var path_buf: [256]u8 = undefined;
    var link: [256]u8 = undefined;
    const driver = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/driver", .{ base, name }) catch return;
    if (sys.check(linux.readlink(driver.ptr, &link, link.len))) |len| {
        const d = link[0..len];
        print("dazzle: display part {s}: driver {s}\n", .{ name, d[(std.mem.lastIndexOfScalar(u8, d, '/') orelse 0) + 1 ..] });
        return;
    } else |_| {}
    var buf: [32]u8 = undefined;
    const waiting_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/waiting_for_supplier", .{ base, name }) catch return;
    const waiting = std.mem.trim(u8, sys.readFile(waiting_path.ptr, &buf) orelse "?", " \n");
    print(sys.log_warning ++ "dazzle: display part {s}: no driver (waiting for a supplier: {s})\n", .{ name, waiting });
    // Its suppliers: links named supplier:<bus>:<device>, each with a
    // status ("available" once the supplier has its driver).
    const dev_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ base, name }) catch return;
    const dir = sys.open(dev_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return;
    defer sys.close(dir);
    var dents: [4096]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(dir, &dents, dents.len)) catch return;
        if (n == 0) return;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            const entry = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
            at += reclen;
            if (!std.mem.startsWith(u8, entry, "supplier:")) continue;
            var status_path_buf: [320]u8 = undefined;
            const status_path = std.fmt.bufPrintZ(&status_path_buf, "{s}/{s}/{s}/status", .{ base, name, entry }) catch continue;
            var status_buf: [32]u8 = undefined;
            const status = std.mem.trim(u8, sys.readFile(status_path.ptr, &status_buf) orelse "?", " \n");
            print("dazzle:   {s}: {s}\n", .{ entry["supplier:".len..], status });
        }
    }
}

/// DRM device nodes are created root-only (0600). Once the vc4 driver (and
/// v3d on the Pi 4 and 5) has probed (it may still be loading firmware or
/// waiting for other devices when init starts), hand every DRM node to the
/// Dazzle user. The first process to open a card becomes its DRM master,
/// which it needs for mode setting; init itself never opens them.
fn grantGpuAccess() void {
    const needs_v3d = needsV3d();
    var found_vc4 = false;
    var found_v3d = !needs_v3d;
    var attempt: u32 = 0;
    while ((!found_vc4 or !found_v3d) and attempt < 100) : (attempt += 1) {
        for (0..max_cards) |n| {
            found_vc4 = found_vc4 or isDrmDriverCard(n, "/vc4-drm");
            found_v3d = found_v3d or isDrmDriverCard(n, "/v3d");
        }
        if (!found_vc4 or !found_v3d) sys.sleepMs(100);
    }
    if (!found_vc4 or !found_v3d) {
        print(sys.log_error ++ "dazzle: no vc4/v3d DRM device after 10 s\n", .{});
        reportDisplayDevices();
    }

    var path_buf: [32]u8 = undefined;
    for (0..max_cards) |n| {
        for ([_]struct { []const u8, usize }{ .{ "card", n }, .{ "renderD", 128 + n } }) |node| {
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/dri/{s}{d}", .{ node[0], node[1] }) catch continue;
            _ = sys.check(linux.chown(path.ptr, sys.user.uid, sys.user.gid)) catch continue;
            _ = linux.fchmodat(linux.AT.FDCWD, path.ptr, 0o660);
        }
    }
}

/// Starts the shell as the Dazzle user. Returns its PID, or null if it
/// could not be started.
fn startShell(setup: bool) ?linux.pid_t {
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            print(sys.log_error ++ "dazzle: cannot start the shell: fork failed ({s})\n", .{@tagName(e)});
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
        print(sys.log_warning ++ "dazzle: cannot drop privileges ({s}); not starting the shell\n", .{@errorName(err)});
        linux.exit(126);
    };
    const argv = [_:null]?[*:0]const u8{ shell_path, if (setup) "--setup" else null };
    const envp = [_:null]?[*:0]const u8{ "HOME=/", "USER=" ++ sys.user.name };
    const err = linux.errno(linux.execve(shell_path, &argv, &envp));
    print(sys.log_warning ++ "dazzle: cannot run {s} ({s})\n", .{ shell_path, @tagName(err) });
    linux.exit(127);
}

/// An update being tried.
const Trying = struct {
    watchdog: ?trial.Watchdog = null,
    /// Ends when the update has run long enough.
    timer: ?linux.pid_t = null,
};

/// A child process that does nothing for `ns`.
fn startTimer(ns: u64) ?linux.pid_t {
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return null;
    if (rc == 0) {
        sys.sleepMs(@intCast(ns / std.time.ns_per_ms));
        linux.exit(0);
    }
    return @intCast(rc);
}

/// Waits for child processes, logging how the shell ends and restarting it.
/// Processes whose parent exits are re-parented to init, so this also
/// collects those.
fn reapForever(first_shell_pid: ?linux.pid_t, first_network_pid: ?linux.pid_t, first_devices_pid: ?linux.pid_t, first_media_pid: ?linux.pid_t, first_system_pid: ?linux.pid_t, card: storage.Boot, t: *Trying) noreturn {
    var shell_pid = first_shell_pid;
    var network_pid = first_network_pid;
    var devices_pid = first_devices_pid;
    var media_pid = first_media_pid;
    var system_pid = first_system_pid;
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
            network_pid = network.start();
            continue;
        }
        if (pid == devices_pid) {
            print("dazzle: device manager stopped (status 0x{x}); restarting it in 5 s\n", .{status});
            sys.sleepMs(5000);
            devices_pid = devices.start();
            continue;
        }
        if (pid == media_pid) {
            print("dazzle: media manager stopped (status 0x{x}); restarting it in 5 s\n", .{status});
            sys.sleepMs(5000);
            media_pid = media.start();
            continue;
        }
        if (pid == system_pid) {
            print("dazzle: system manager stopped (status 0x{x}); restarting it in 5 s\n", .{status});
            sys.sleepMs(5000);
            // What it did meanwhile (setup, say) is on the card.
            const now = storage.state(card);
            system_pid = system.start(now.card, now.mounted, now.slot, now.setup_done);
            continue;
        }
        if (t.timer != null and pid == t.timer.?) {
            // The shell has run all this while: the update works.
            t.timer = null;
            trial.commit(card.slot orelse 'a');
            if (t.watchdog) |w| w.end();
            t.watchdog = null;
            continue;
        }
        if (pid != shell_pid) continue;
        if (linux.W.IFEXITED(status)) {
            print("dazzle: shell exited with status {d}\n", .{linux.W.EXITSTATUS(status)});
        } else if (linux.W.IFSIGNALED(status)) {
            print("dazzle: shell killed by signal {d}\n", .{linux.W.TERMSIG(status)});
        }
        // The update does not work: back to the system before (which the
        // next start already is).
        if (t.timer != null) {
            print(sys.log_error ++ "dazzle: the update did not work\n", .{});
            trial.restart();
        }
        print("dazzle: restarting the shell in 1 s\n", .{});
        sys.sleepMs(1000);
        shell_pid = startShell(!storage.state(card).setup_done);
    }
}

test {
    _ = @import("logserver.zig");
    _ = @import("network.zig");
    _ = @import("dhcp.zig");
    _ = @import("netconf.zig");
    _ = @import("devices.zig");
    _ = @import("media.zig");
    _ = @import("volume.zig");
    _ = @import("nl80211.zig");
    _ = @import("nat.zig");
    _ = @import("supplicant.zig");
    _ = @import("mkfs.zig");
    _ = @import("storage.zig");
    _ = @import("system.zig");
    _ = @import("slots.zig");
    _ = @import("trial.zig");
}
