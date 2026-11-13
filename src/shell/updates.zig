//! Whether there are updates, for the dock to show: a newer system (one
//! not in either OS slot already) or a newer version of an installed app.
//! The shell asks the apps' server for its catalogue and the system's
//! os.json (as Settings' Software page does, into the same files) a minute
//! after it starts and then once a day, in a child process (`store.Job`).
//! What Settings fetches, installs or removes meanwhile is seen as the
//! files change (see `AppsWatch`) and as the system manager reports.

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
    /// There is an update, of the system or an app.
    available: bool = false,

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
    /// whether `available` changed.
    pub fn tick(u: *Updates, now: u64) bool {
        if (now >= u.next_check and u.apps.job == null) {
            u.next_check = now + check_every_ns;
            u.apps.refresh(true);
        }
        if (u.apps.poll()) {
            if (u.apps.message().len > 0) sys.print(sys.log_warning ++ "dazzle-shell: {s}\n", .{u.apps.message()});
            return u.recompute();
        }
        return false;
    }

    /// What the system manager says now. Returns whether `available`
    /// changed.
    pub fn setReport(u: *Updates, r: sys.system.Report) bool {
        u.report = r;
        return u.recompute();
    }

    /// The catalogue, os.json or the apps changed (Settings fetched them,
    /// or installed or removed apps): read again. Returns whether
    /// `available` changed.
    pub fn reload(u: *Updates) bool {
        u.apps.loadCatalogue();
        return u.recompute();
    }

    fn recompute(u: *Updates) bool {
        const was = u.available;
        u.available = appsNewer(store.apps_dir, u.apps.apps()) or u.systemNewer();
        return u.available != was;
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
    for (catalogue) |a| if (store.isInstalled(dir, a.name) and store.hasNewerVersion(dir, a)) return true;
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
