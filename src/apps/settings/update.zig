//! Updating the system (Settings' Software page). Where the apps come from
//! (`build_info.apps_url`), the build also publishes the system as an
//! update: os.json says which it is (its commit, and when that was
//! committed), and dazzle-os.tar.xz is its files (see tools/mkos.zig).
//!
//! * Checking downloads os.json (when the page is first shown, and when
//!   asked) into /data/update. An update is offered when it was committed
//!   after the running system and is in neither OS slot (the system
//!   manager says what they hold).
//! * Downloading fetches the archive to /data/update, checks its size,
//!   SHA-256 and Ed25519 signature against os.json, and asks the system
//!   manager to install it (with the SHA-256 and signature, which it checks
//!   again): it unpacks it into the slot not running and has the firmware
//!   start that slot next time.
//! * Once it has, Settings offers to restart, which the manager does.
//!
//! Downloads run in a child process (`store.Job`), as the apps' do.

const std = @import("std");
const locale = @import("locale");
const linux = std.os.linux;
const sys = @import("sys");
const store = @import("store");

const proto = sys.system;

pub const manifest_file = proto.update_dir ++ "/os.json";

pub const Manifest = struct {
    name: []const u8 = "dazzle",
    title: []const u8 = "Dazzle",
    description: []const u8 = "",
    version: []const u8,
    time: u64,
    icon: []const u8 = "",
    file: []const u8,
    size: u64,
    sha256: []const u8,
    signature: []const u8 = "",

    pub fn parse(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(Manifest) {
        const parsed = std.json.parseFromSlice(Manifest, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadManifest;
        errdefer parsed.deinit();
        const m = parsed.value;
        if (proto.Version.init(m.time, m.version) == null or !(std.mem.endsWith(u8, m.file, ".tar.xz") and store.validName(m.file[0 .. m.file.len - ".tar.xz".len])) or m.sha256.len != 64) return error.BadManifest;
        return parsed;
    }

    pub fn versionOf(m: *const Manifest) proto.Version {
        return proto.Version.init(m.time, m.version).?;
    }
};

/// What the Software page shows of updates.
pub const Status = enum {
    /// Not checked yet, or the check failed (see the message).
    unknown,
    checking,
    /// A newer system can be downloaded.
    available,
    downloading,
    installing,
    /// Installed: it starts when the computer restarts.
    ready,
    /// Nothing newer.
    current,
};

/// Whether `m` should be offered: newer than the running system, and in
/// neither slot.
pub fn offered(m: *const Manifest, running: proto.Version, report: ?*const proto.Report) bool {
    const v = m.versionOf();
    if (v.time <= running.time or v.eql(&running)) return false;
    if (report) |r| if (r.holds(&v)) return false;
    return true;
}

pub const Updater = struct {
    gpa: std.mem.Allocator,
    base_url: []const u8,
    running: proto.Version,
    manifest: ?std.json.Parsed(Manifest) = null,
    job: ?store.Job = null,
    /// What the system manager last said.
    report: ?proto.Report = null,
    sub: proto.Subscription = .{},
    next_ask: u64 = 0,
    /// Whether os.json has been asked for since the program started.
    asked: bool = false,
    /// What went wrong last.
    message_buf: [160]u8 = undefined,
    message_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, base_url: []const u8, running: proto.Version) Updater {
        var u: Updater = .{ .gpa = gpa, .base_url = base_url, .running = running };
        u.loadManifest();
        u.sub.connect();
        return u;
    }

    pub fn deinit(u: *Updater) void {
        u.sub.deinit();
        if (u.manifest) |*m| m.deinit();
    }

    pub fn setBaseUrl(u: *Updater, base_url: []const u8) void {
        if (u.job) |*j| if (j.kind == .os_check) {
            var wstatus: u32 = 0;
            _ = linux.kill(j.pid, .KILL);
            _ = linux.wait4(j.pid, &wstatus, 0, null);
            sys.close(j.result);
            u.job = null;
        };
        u.base_url = base_url;
        u.asked = false;
        u.message_len = 0;
    }

    pub fn loadManifest(u: *Updater) void {
        const json = sys.readFileAlloc(u.gpa, manifest_file, 64 * 1024) catch return;
        defer u.gpa.free(json);
        const parsed = Manifest.parse(u.gpa, json) catch return;
        if (u.manifest) |*m| m.deinit();
        u.manifest = parsed;
    }

    pub fn message(u: *const Updater) []const u8 {
        return u.message_buf[0..u.message_len];
    }

    fn setMessage(u: *Updater, comptime fmt: []const u8, args: anytype) void {
        u.message_len = if (std.fmt.bufPrint(&u.message_buf, fmt, args)) |t| t.len else |_| 0;
    }

    /// The system that can be downloaded, if it is offered.
    pub fn available(u: *const Updater) ?*const Manifest {
        const m = if (u.manifest) |*p| &p.value else return null;
        const report = if (u.report) |*r| r else null;
        // The running slot's version (with its kernel's commit and time), as
        // the system manager says; else the one this was built with.
        const running = if (report) |r| (if (r.slot) |s| (if (r.version(s)) |v| v.* else u.running) else u.running) else u.running;
        return if (offered(m, running, report)) m else null;
    }

    pub fn status(u: *const Updater) Status {
        if (u.job) |j| return if (j.kind == .os_check) .checking else .downloading;
        const r = if (u.report) |*r| r else null;
        if (r) |rep| {
            if (rep.update == .installing) return .installing;
            // The firmware starts the other slot next time.
            if (rep.slot != null and rep.next != null and rep.slot.? != rep.next.?) return .ready;
        }
        if (u.available() != null) return .available;
        return if (u.manifest != null and u.message_len == 0) .current else .unknown;
    }

    /// Downloads os.json again (once a session, unless asked).
    pub fn check(u: *Updater, again: bool) void {
        if (u.job != null or (u.asked and !again)) return;
        u.asked = true;
        u.job = store.Job.spawn(.os_check, "", childCheck, .{ u.gpa, u.base_url }) catch |err| {
            u.setMessage("Cannot check for updates: {s}", .{@errorName(err)});
            return;
        };
        u.message_len = 0;
    }

    /// Downloads the offered system, and has it installed.
    pub fn download(u: *Updater) void {
        if (u.job != null) return;
        const m = u.available() orelse return;
        u.job = store.Job.spawn(.os_download, m.version, childDownload, .{ u.gpa, u.base_url, m.* }) catch |err| {
            u.setMessage("Cannot download the update: {s}", .{@errorName(err)});
            return;
        };
        u.message_len = 0;
    }

    pub fn restart(u: *Updater) void {
        if (proto.ask("restart\n", 3000) == null) u.setMessage("Cannot restart: the system did not answer", .{});
    }

    fn applyReport(u: *Updater, r: proto.Report) void {
        u.report = r;
        // What the manager says of installing goes before what was
        // said before.
        switch (r.update) {
            .failed => if (u.message_len == 0) u.setMessage("Cannot update: {s}", .{r.update_failure.label()}),
            .installing, .ready => u.message_len = 0,
            .none => {},
        }
    }

    /// Follows the job under way and the system manager. Returns whether
    /// what is shown changed.
    pub fn poll(u: *Updater, now: u64) bool {
        var changed = false;
        if (u.job) |*j| {
            var buf: [160]u8 = undefined;
            if (j.finished(&buf)) |outcome| {
                const kind = j.kind;
                u.job = null;
                changed = true;
                switch (kind) {
                    .os_check => if (outcome) |why| u.setMessage("Cannot check for updates: {s}", .{why}) else u.loadManifest(),
                    else => if (outcome) |why| u.setMessage("Cannot update: {s}", .{why}),
                }
            }
        }
        if (u.sub.fd == null and now >= u.next_ask) {
            u.sub.connect();
            u.next_ask = now + 5 * std.time.ns_per_s;
        }
        if (u.sub.poll()) |r| if (!r.denied) {
            const was = u.status();
            const prev_report = u.report;
            u.applyReport(r);
            changed = changed or u.status() != was or !std.meta.eql(prev_report, u.report);
        };
        return changed;
    }
};

fn childCheck(gpa: std.mem.Allocator, base_url: []const u8) !void {
    _ = linux.mkdir(proto.update_dir, 0o755);
    var client: store.Client = .init(gpa);
    defer client.deinit();
    try store.fetchOs(&client, gpa, base_url, proto.update_dir);
}

fn childDownload(gpa: std.mem.Allocator, base_url: []const u8, m: Manifest) !void {
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, m.file });
    const archive = try store.download(gpa, url);
    if (archive.len != m.size) return error.WrongSize;
    if (!sys.archive.sha256Is(archive, m.sha256)) return error.WrongChecksum;
    const keys = store.loadKeys();
    try store.verifySignature(archive, m.signature, keys.slice());
    const tmp = proto.update_archive ++ ".new";
    _ = linux.unlink(tmp);
    try sys.files.writeNew(tmp, archive);
    _ = try sys.check(linux.rename(tmp, proto.update_archive));
    var request: [208]u8 = undefined;
    // The manager answers between slices of other work (making the other
    // slot, say), which can take it a while on a slow card.
    const report = proto.ask(try std.fmt.bufPrint(&request, "update {s} {s}\n", .{ m.sha256, m.signature }), 30_000) orelse return error.InstallFailed;
    if (report.denied or report.update == .failed) return error.InstallFailed;
}

/// "7 October 2026" (in the current language's way: "October 7, 2026").
pub fn formatDate(buf: []u8, seconds: u64) []const u8 {
    const day = std.time.epoch.EpochSeconds{ .secs = seconds };
    const yd = day.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return locale.formatLongDate(buf, md.day_index + 1, @intFromEnum(md.month), yd.year);
}

const testing = std.testing;

test "an update is offered when it is newer and in neither slot" {
    const json =
        \\{"version": "0123abc", "time": 1791400000, "file": "dazzle-os.tar.xz", "size": 4000000,
        \\ "sha256": "f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753"}
    ;
    const parsed = try Manifest.parse(testing.allocator, json);
    defer parsed.deinit();
    const m = &parsed.value;
    const running = proto.Version.init(1791331200, "de14aa2").?;
    try testing.expect(offered(m, running, null));
    // Older or the same: not.
    try testing.expect(!offered(m, proto.Version.init(1791500000, "fffffff").?, null));
    try testing.expect(!offered(m, proto.Version.init(1791400000, "0123abc").?, null));
    // Already in the other slot (downloaded before): not.
    var report: proto.Report = .{ .slot = 'a', .next = 'a', .versions = .{ running, proto.Version.init(1791400000, "0123abc").? } };
    try testing.expect(!offered(m, running, &report));
    report.versions[1] = proto.Version.init(1791000000, "0000aaa").?;
    try testing.expect(offered(m, running, &report));

    // Manifests that are not right.
    try testing.expectError(error.BadManifest, Manifest.parse(testing.allocator, "{\"version\": \"x y\", \"time\": 1, \"file\": \"a.tar.xz\", \"size\": 1, \"sha256\": \"" ++ "0" ** 64 ++ "\"}"));
    try testing.expectError(error.BadManifest, Manifest.parse(testing.allocator, "{\"version\": \"abc\", \"time\": 1, \"file\": \"../a\", \"size\": 1, \"sha256\": \"" ++ "0" ** 64 ++ "\"}"));
    try testing.expectError(error.BadManifest, Manifest.parse(testing.allocator, "[]"));
}

test "dates" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("7 October 2026", formatDate(&buf, 1791331200 + 86400 * 0 + 3600));
    try testing.expectEqualStrings("1 January 1970", formatDate(&buf, 0));
}
