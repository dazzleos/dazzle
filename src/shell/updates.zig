//! Whether there are updates, for the dock to show: a newer system (one
//! not in either OS slot already) or a newer version of an installed app.
//! The shell asks the apps' server for its catalogue and the system's
//! os.json (as Settings' Software page does, into the same files) a minute
//! after it starts and then once a day, in a child process (`store.Job`).
//! What Settings fetches, installs or removes meanwhile is seen as the
//! files change (see `AppsWatch`) and as the system manager reports.
//!
//! Remote control can also have it check now, install everything newer
//! (the apps, and the system: downloaded, then installed by the system
//! manager into the other slot), and say how that goes (`checkNow`,
//! `installAll`, `describe`).

const std = @import("std");
const sys = @import("sys");
const store = @import("store");
const build_info = @import("build_info");

const Version = sys.system.Version;

/// How long after the shell starts the first check is (the network has
/// had a moment to come up), and how long between checks.
pub const first_check_ns = 60 * std.time.ns_per_s;
pub const check_every_ns = 24 * 3600 * std.time.ns_per_s;

pub const Updates = struct {
    gpa: std.mem.Allocator,
    url_buf: [store.max_url_len]u8 = undefined,
    /// The catalogue (and, with it, os.json) and the check under way.
    apps: store.Store = undefined,
    /// The system this shell was built with (the running one's, unless the
    /// system manager says otherwise).
    built: Version,
    /// What the system manager last said (which slots hold what).
    report: ?sys.system.Report = null,
    next_check: u64,
    /// There is an update, of the system or an app; and which.
    available: bool = false,
    system: bool = false,
    apps_newer: bool = false,
    /// Downloading the system update (and having it installed).
    os_job: ?store.Job = null,
    /// Install what is newer once the check under way is done.
    install_after_check: bool = false,
    /// What went wrong last (remote control says it).
    problem_buf: [160]u8 = undefined,
    problem_len: usize = 0,

    /// Starts watching for updates (in place: `apps` keeps a pointer into
    /// `url_buf`). The first check is in a minute.
    pub fn init(u: *Updates, gpa: std.mem.Allocator, now: u64) void {
        u.* = .{
            .gpa = gpa,
            .built = Version.init(build_info.commit_time, build_info.commit) orelse .{},
            .next_check = now + first_check_ns,
        };
        u.apps = .init(gpa, store.loadServerUrl(&u.url_buf, build_info.apps_url));
        u.apps.check_os = true;
        _ = u.recompute();
    }

    /// Starts the check when it is due, and follows it (the shell's reaper
    /// may reap its child first: the job still reads its result). Returns
    /// whether what there are updates of changed.
    /// When `tick` next has something to do (monotonic nanoseconds): at
    /// once, every second or so, while a check or an update runs (they are
    /// looked at as they go); otherwise at the next daily check.
    pub fn dueAt(u: *const Updates, now: u64) u64 {
        if (u.os_job != null or u.apps.job != null) return now + std.time.ns_per_s;
        return u.next_check;
    }

    pub fn tick(u: *Updates, now: u64) bool {
        if (now >= u.next_check and u.apps.job == null) {
            u.next_check = now + check_every_ns;
            u.useServer();
            u.apps.refresh(true);
        }
        var changed = false;
        if (u.os_job) |*j| {
            var buf: [160]u8 = undefined;
            if (j.finished(&buf)) |outcome| {
                u.os_job = null;
                if (outcome) |why| u.setProblem("cannot update the system: {s}", .{why});
                changed = true;
            }
        }
        if (u.apps.poll()) {
            if (u.apps.message().len > 0) {
                sys.print(sys.log_warning ++ "dazzle-shell: {s}\n", .{u.apps.message()});
                u.setProblem("{s}", .{u.apps.message()});
            }
            changed = u.recompute() or changed;
            // The check asked for has finished: install what it found.
            if (u.install_after_check and u.apps.job == null) {
                u.install_after_check = false;
                u.installNow();
            }
        }
        return changed;
    }

    /// Checks for updates now (the apps' catalogue and the system's
    /// os.json).
    pub fn checkNow(u: *Updates) void {
        u.problem_len = 0;
        if (u.apps.job == null) {
            u.useServer();
            u.apps.refresh(true);
        }
    }

    /// The software server as Settings has it now (it may have been
    /// changed since the shell started).
    fn useServer(u: *Updates) void {
        var buf: [store.max_url_len]u8 = undefined;
        const now = store.loadServerUrl(&buf, build_info.apps_url);
        if (std.mem.eql(u8, now, u.apps.base_url)) return;
        @memcpy(u.url_buf[0..now.len], now);
        u.apps.setBaseUrl(u.url_buf[0..now.len]);
    }

    /// Checks for updates now, then installs everything newer: the apps,
    /// and the system (which starts when the computer restarts).
    pub fn installAll(u: *Updates) void {
        u.checkNow();
        u.install_after_check = true;
    }

    fn installNow(u: *Updates) void {
        _ = u.recompute();
        if (u.apps_newer) u.apps.updateAll();
        if (u.system and u.os_job == null) {
            var parsed = store.loadOsManifest(u.gpa) orelse return;
            defer parsed.deinit();
            u.os_job = store.Job.spawn(.os_download, parsed.value.version, store.downloadAndInstallOs, .{ u.gpa, u.apps.base_url, parsed.value }) catch |err| blk: {
                u.setProblem("cannot update the system: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
    }

    fn setProblem(u: *Updates, comptime fmt: []const u8, args: anytype) void {
        u.problem_len = if (std.fmt.bufPrint(&u.problem_buf, fmt, args)) |t| t.len else |_| 0;
    }

    /// How updates stand, for remote control: what is being done, what is
    /// newer, and what the system manager says of the system's.
    pub fn describe(u: *const Updates, w: *std.Io.Writer) !void {
        const doing = if (u.install_after_check or (u.apps.job != null and u.apps.job.?.kind == .catalogue))
            "checking"
        else if (u.apps.job != null)
            "updating apps"
        else if (u.os_job != null)
            "downloading the system"
        else
            "idle";
        try w.print("doing {s}\n", .{doing});
        try w.print("apps {s}\n", .{if (u.apps_newer) "newer available" else "up to date"});
        const r = if (u.report) |*rep| rep else null;
        const system = if (r != null and r.?.update == .installing)
            "installing"
        else if (r != null and r.?.slot != null and r.?.next != null and r.?.slot.? != r.?.next.?)
            "installed, starts when restarted"
        else if (u.system)
            "newer available"
        else
            "up to date";
        try w.print("system {s}\n", .{system});
        if (u.problem_len > 0) try w.print("problem {s}\n", .{u.problem_buf[0..u.problem_len]});
    }

    /// What the system manager says now. Returns whether what there are
    /// updates of changed.
    pub fn setReport(u: *Updates, r: sys.system.Report) bool {
        u.report = r;
        return u.recompute();
    }

    /// The catalogue, os.json or the apps changed (Settings fetched them,
    /// or installed or removed apps): read again. Returns whether what
    /// there are updates of changed.
    pub fn reload(u: *Updates) bool {
        u.apps.loadCatalogue();
        return u.recompute();
    }

    fn recompute(u: *Updates) bool {
        const was = .{ u.system, u.apps_newer };
        u.apps_newer = appsNewer(store.apps_dir, u.apps.apps());
        u.system = u.systemNewer();
        u.available = u.system or u.apps_newer;
        return u.system != was[0] or u.apps_newer != was[1];
    }

    fn systemNewer(u: *const Updates) bool {
        var parsed = store.loadOsManifest(u.gpa) orelse return false;
        defer parsed.deinit();
        const report = if (u.report) |*r| r else null;
        return store.osOffered(&parsed.value, store.runningVersion(report, u.built), report);
    }
};

/// Whether an app installed in `dir` has a newer version in `catalogue`.
pub fn appsNewer(dir: []const u8, catalogue: []const store.App) bool {
    for (catalogue) |a| if (store.installedEntry(dir, a) and store.hasNewerVersion(dir, a)) return true;
    return false;
}

const testing = std.testing;
const linux = std.os.linux;

test "an installed app with a newer version in the catalogue is an update" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-updates-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    // "notes" is installed, at an old version; "maps" is not.
    var buf: [128]u8 = undefined;
    _ = linux.mkdir(try std.mem.printSentinel(&buf, "{s}/notes", .{dir}, 0), 0o755);
    const program = try std.mem.printSentinel(&buf, "{s}/notes/notes", .{dir}, 0);
    try sys.files.writeNew(program, "");
    _ = linux.chmod(program, 0o755);
    try sys.files.writeNew(try std.mem.printSentinel(&buf, "{s}/notes/" ++ Version.file_name, .{dir}, 0), "1791000000 0000aaa\n");

    const sha = "f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753";
    const same = [_]store.App{.{ .name = "notes", .title = "Notes", .version = "0000aaa", .time = 1791000000, .file = "notes.tar.xz", .size = 1, .sha256 = sha }};
    try testing.expect(!appsNewer(dir, &same));
    const newer = [_]store.App{
        .{ .name = "maps", .title = "Maps", .version = "1111bbb", .time = 1791400000, .file = "maps.tar.xz", .size = 1, .sha256 = sha },
        .{ .name = "notes", .title = "Notes", .version = "1111bbb", .time = 1791400000, .file = "notes.tar.xz", .size = 1, .sha256 = sha },
    };
    try testing.expect(appsNewer(dir, &newer));
    // Only for apps installed.
    try testing.expect(!appsNewer(dir, newer[0..1]));
}
