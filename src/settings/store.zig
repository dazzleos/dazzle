//! Installing and removing apps (Settings' Apps page).
//!
//! The catalogue of apps that can be installed (apps.json; see
//! tools/mkcatalogue.zig) and their archives are published where the
//! image is (`build_info.apps_url`). An app's archive is its folder, as in
//! /apps, as a tar file compressed with xz.
//!
//! * Downloading (the catalogue, or an app) is done over HTTPS by a child
//!   process (`Job`), so the window goes on meanwhile. It trusts the
//!   authorities in /os/certs (Mozilla's), and needs the clock set (the
//!   network manager sets it).
//! * Installing checks the archive's size and SHA-256 against the
//!   catalogue, unpacks it into a hidden folder in /apps (only the app's
//!   own folder, no links), and renames it into place: replacing an
//!   installed copy, if there is one.
//! * Removing renames the app's folder out of sight, then deletes it.
//!
//! /apps is /data/apps, the user's (init/apps.zig), so Settings needs no
//! privileges for this. The catalogue last downloaded is kept there as
//! .catalogue.json, to list the apps without a network.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const apps_dir = "/apps";
const catalogue_file = apps_dir ++ "/.catalogue.json";
const ca_file = "/os/certs/ca-certificates.pem";

/// The most an archive or the catalogue may be.
const max_download = 64 * 1024 * 1024;

pub const App = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8 = "",
    icon: []const u8 = "",
    file: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const Catalogue = struct {
    version: []const u8 = "",
    apps: []const App,
};

pub fn parseCatalogue(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(Catalogue) {
    const parsed = try std.json.parseFromSlice(Catalogue, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    for (parsed.value.apps) |a| if (!validName(a.name)) return error.BadCatalogue;
    return parsed;
}

/// An app's name, as a folder in /apps: lower case letters, digits and
/// dashes.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48 or name[0] == '-') return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

/// Whether app `name` is in `dir` (its folder, with its program).
pub fn isInstalled(dir: []const u8, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}/{s}", .{ dir, name, name }) catch return false;
    return linux.errno(linux.access(path, linux.X_OK)) == .SUCCESS;
}

/// Whether apps can be installed in `dir` (not before setup has made the
/// card's space for files: /apps is then the image's, read-only).
pub fn writable(dir: [*:0]const u8) bool {
    return linux.errno(linux.access(dir, linux.W_OK)) == .SUCCESS;
}

/// Checks a downloaded archive against the catalogue.
pub fn verify(archive: []const u8, app: App) !void {
    if (archive.len != app.size) return error.WrongSize;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    if (!std.ascii.eqlIgnoreCase(&hex, app.sha256)) return error.WrongChecksum;
}

/// Unpacks `archive` (xz-compressed tar) into `dir` as app `name`,
/// replacing the app if it is there.
pub fn unpack(gpa: std.mem.Allocator, archive: []const u8, dir: []const u8, name: []const u8) !void {
    if (!validName(name)) return error.BadName;
    var staging_buf: [256]u8 = undefined;
    const staging = try std.fmt.bufPrintZ(&staging_buf, "{s}/.install-{s}", .{ dir, name });
    sys.files.removeTree(staging);
    _ = try sys.check(linux.mkdir(staging, 0o755));
    defer sys.files.removeTree(staging);

    // Decompressed in memory: apps are small.
    var input: std.Io.Reader = .fixed(archive);
    var xz = try std.compress.xz.Decompress.init(&input, gpa, &.{});
    defer xz.deinit();
    var tar: std.Io.Writer.Allocating = .init(gpa);
    defer tar.deinit();
    _ = xz.reader.streamRemaining(&tar.writer) catch return error.BadArchive;
    if (tar.written().len > max_download) return error.BadArchive;

    var tar_reader: std.Io.Reader = .fixed(tar.written());
    var file_name_buf: [256]u8 = undefined;
    var link_name_buf: [256]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_reader, .{ .file_name_buffer = &file_name_buf, .link_name_buffer = &link_name_buf });
    while (it.next() catch return error.BadArchive) |f| {
        const rel = std.mem.trimEnd(u8, f.name, "/");
        // Only the app's own folder, and nothing outside it.
        if (!(std.mem.eql(u8, rel, name) or (std.mem.startsWith(u8, rel, name) and rel.len > name.len and rel[name.len] == '/'))) return error.BadArchive;
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return error.BadArchive;
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ staging, rel });
        switch (f.kind) {
            .directory => _ = sys.check(linux.mkdir(path, 0o755)) catch |err| if (err != error.Unexpected) return err,
            .file => {
                const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
                defer sys.close(fd);
                _ = linux.fchmod(fd, if (f.mode & 0o100 != 0) 0o755 else 0o644);
                var w_buf: [4096]u8 = undefined;
                var fw: FdWriter = .{ .fd = fd, .interface = .{ .vtable = &.{ .drain = FdWriter.drain }, .buffer = &w_buf } };
                it.streamRemaining(f, &fw.interface) catch return error.BadArchive;
                fw.interface.flush() catch return error.BadArchive;
                _ = linux.fsync(fd);
            },
            // No links: an app is plain files.
            else => return error.BadArchive,
        }
    }
    if (!isInstalled(staging, name)) return error.BadArchive;

    // Into place: an installed copy out of the way first.
    var app_buf: [256]u8 = undefined;
    var old_buf: [256]u8 = undefined;
    var new_buf: [512]u8 = undefined;
    const app_path = try std.fmt.bufPrintZ(&app_buf, "{s}/{s}", .{ dir, name });
    const old = try std.fmt.bufPrintZ(&old_buf, "{s}/.old-{s}", .{ dir, name });
    const new = try std.fmt.bufPrintZ(&new_buf, "{s}/{s}", .{ staging, name });
    sys.files.removeTree(old);
    const replacing = linux.errno(linux.access(app_path, linux.F_OK)) == .SUCCESS;
    if (replacing) _ = try sys.check(linux.rename(app_path, old));
    _ = sys.check(linux.rename(new, app_path)) catch |err| {
        if (replacing) _ = linux.rename(old, app_path);
        return err;
    };
    sys.files.removeTree(old);
}

/// Removes app `name` from `dir`.
pub fn remove(dir: []const u8, name: []const u8) !void {
    if (!validName(name)) return error.BadName;
    var app_buf: [256]u8 = undefined;
    var gone_buf: [256]u8 = undefined;
    const app_path = try std.fmt.bufPrintZ(&app_buf, "{s}/{s}", .{ dir, name });
    const gone = try std.fmt.bufPrintZ(&gone_buf, "{s}/.remove-{s}", .{ dir, name });
    sys.files.removeTree(gone);
    // Out of sight at once (the dock follows), then deleted.
    _ = try sys.check(linux.rename(app_path, gone));
    sys.files.removeTree(gone);
}

/// A writer to a file descriptor, for the archive's files.
const FdWriter = struct {
    fd: linux.fd_t,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("interface", w);
        try writeAll(self.fd, w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try writeAll(self.fd, d);
            n += d.len;
        }
        for (0..splat) |_| try writeAll(self.fd, data[data.len - 1]);
        return n + data[data.len - 1].len * splat;
    }

    fn writeAll(fd: linux.fd_t, bytes: []const u8) std.Io.Writer.Error!void {
        var at: usize = 0;
        while (at < bytes.len) at += sys.check(linux.write(fd, bytes[at..].ptr, bytes.len - at)) catch return error.WriteFailed;
    }
};

// --- Downloading, in a child process ---------------------------------------------

/// Downloads `url` over HTTPS.
fn download(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    if (std.mem.startsWith(u8, url, "https:")) {
        const now = std.Io.Clock.real.now(io);
        // A clock that was never set (1970) would make every certificate
        // look not yet valid.
        if (now.toSeconds() < 1_700_000_000) return error.ClockNotSet;
        try client.ca_bundle.addCertsFromFilePathAbsolute(gpa, io, now, ca_file);
        client.now = now;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &out.writer });
    if (result.status != .ok) return error.HttpError;
    if (out.written().len > max_download) return error.TooBig;
    return out.toOwnedSlice();
}

pub const Job = struct {
    pub const Kind = enum { catalogue, install };

    kind: Kind,
    pid: linux.pid_t,
    /// When it started (it is stopped if it takes too long: a server that
    /// stops answering would otherwise hold up the next).
    started: u64,
    /// The child's report: empty if it worked, else why not.
    result: linux.fd_t,
    name_buf: [48]u8 = undefined,
    name_len: usize = 0,

    pub fn name(j: *const Job) []const u8 {
        return j.name_buf[0..j.name_len];
    }

    /// Starts downloading the catalogue (`app` null) or installing `app`,
    /// from `base_url`.
    pub fn start(gpa: std.mem.Allocator, base_url: []const u8, app: ?App) !Job {
        var fds: [2]linux.fd_t = undefined;
        _ = try sys.check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |e| {
                sys.close(fds[0]);
                sys.close(fds[1]);
                return sys.errorFromErrno(e);
            },
        }
        if (rc == 0) {
            sys.close(fds[0]);
            const outcome = if (app) |a| childInstall(gpa, base_url, a) else childCatalogue(gpa, base_url);
            if (outcome) |_| {} else |err| {
                const why = describe(err);
                _ = linux.write(fds[1], why.ptr, why.len);
                sys.print("dazzle-settings: {s}: {s}\n", .{ if (app) |a| a.name else "apps.json", @errorName(err) });
            }
            linux.exit(0);
        }
        sys.close(fds[1]);
        var j: Job = .{ .kind = if (app == null) .catalogue else .install, .pid = @intCast(rc), .started = sys.nowNs(), .result = fds[0] };
        if (app) |a| {
            j.name_len = @min(a.name.len, j.name_buf.len);
            @memcpy(j.name_buf[0..j.name_len], a.name[0..j.name_len]);
        }
        return j;
    }

    const time_limit = 10 * 60 * std.time.ns_per_s;

    /// If the job has finished: null if it worked, else why not (in `buf`).
    pub fn finished(j: *Job, buf: []u8) ??[]const u8 {
        var status: u32 = 0;
        const rc = linux.wait4(j.pid, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) == .SUCCESS and rc == 0) {
            if (sys.nowNs() -| j.started < time_limit) return null;
            _ = linux.kill(j.pid, .KILL);
            _ = linux.wait4(j.pid, &status, 0, null);
            sys.close(j.result);
            return @as(?[]const u8, "it took too long");
        }
        const n = sys.check(linux.read(j.result, buf.ptr, buf.len)) catch 0;
        sys.close(j.result);
        const outcome: ?[]const u8 = if (n > 0) buf[0..n] else if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0) null else "it stopped";
        return outcome;
    }
};

fn childCatalogue(gpa: std.mem.Allocator, base_url: []const u8) !void {
    const url = try std.fmt.allocPrint(gpa, "{s}/apps.json", .{base_url});
    const json = try download(gpa, url);
    // Only a catalogue that reads is kept.
    (try parseCatalogue(gpa, json)).deinit();
    const tmp = catalogue_file ++ ".new";
    _ = linux.unlink(tmp);
    try sys.files.writeNew(tmp, json);
    _ = try sys.check(linux.rename(tmp, catalogue_file));
}

fn childInstall(gpa: std.mem.Allocator, base_url: []const u8, app: App) !void {
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, app.file });
    const archive = try download(gpa, url);
    try verify(archive, app);
    try unpack(gpa, archive, apps_dir, app.name);
}

/// Why a job failed, for people.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ClockNotSet => "the clock is not set yet (it is set once the network is up)",
        error.WrongSize, error.WrongChecksum => "the download was not what the catalogue said",
        error.BadArchive, error.BadName => "the app's archive was not right",
        error.BadCatalogue => "the list of apps was not right",
        error.HttpError => "the server did not have it",
        error.UnknownHostName, error.NameServerFailure, error.HostLacksNetworkAddresses => "the server could not be found (is the network up?)",
        error.ConnectionRefused, error.NetworkUnreachable, error.ConnectionTimedOut, error.ConnectionResetByPeer => "the server could not be reached (is the network up?)",
        error.CertificateIssuerNotFound, error.TlsCertificateNotVerified, error.CertificateExpired, error.CertificateNotYetValid => "the server's certificate could not be trusted",
        error.OutOfMemory => "there was not enough memory",
        else => @errorName(err),
    };
}

/// What the Apps page shows and does: the catalogue, and the job under way.
pub const Store = struct {
    gpa: std.mem.Allocator,
    base_url: []const u8,
    catalogue: ?std.json.Parsed(Catalogue) = null,
    job: ?Job = null,
    /// What happened last (an error, or what was done).
    message_buf: [160]u8 = undefined,
    message_len: usize = 0,
    /// Whether the catalogue has been asked for since the program started.
    asked: bool = false,

    pub fn init(gpa: std.mem.Allocator, base_url: []const u8) Store {
        var s: Store = .{ .gpa = gpa, .base_url = base_url };
        s.loadCatalogue();
        return s;
    }

    fn loadCatalogue(s: *Store) void {
        const json = sys.readFileAlloc(s.gpa, catalogue_file, max_download) catch return;
        defer s.gpa.free(json);
        const parsed = parseCatalogue(s.gpa, json) catch return;
        if (s.catalogue) |*c| c.deinit();
        s.catalogue = parsed;
    }

    pub fn apps(s: *const Store) []const App {
        return if (s.catalogue) |c| c.value.apps else &.{};
    }

    pub fn message(s: *const Store) []const u8 {
        return s.message_buf[0..s.message_len];
    }

    fn setMessage(s: *Store, comptime fmt: []const u8, args: anytype) void {
        s.message_len = if (std.fmt.bufPrint(&s.message_buf, fmt, args)) |t| t.len else |_| 0;
    }

    /// The app being installed, or "" for the catalogue; null if nothing
    /// is under way.
    pub fn busy(s: *const Store) ?[]const u8 {
        const j = s.job orelse return null;
        return j.name();
    }

    /// Downloads the catalogue again (once a session, unless asked). Not
    /// before setup: it is kept with the apps.
    pub fn refresh(s: *Store, again: bool) void {
        if (s.job != null or (s.asked and !again) or !writable(apps_dir)) return;
        s.asked = true;
        s.job = Job.start(s.gpa, s.base_url, null) catch |err| {
            s.setMessage("Cannot get the list of apps: {s}", .{@errorName(err)});
            return;
        };
        s.message_len = 0;
    }

    pub fn install(s: *Store, name: []const u8) void {
        if (s.job != null) return;
        if (!writable(apps_dir)) {
            s.setMessage("Apps can be installed once setup has prepared the card", .{});
            return;
        }
        for (s.apps()) |a| if (std.mem.eql(u8, a.name, name)) {
            s.job = Job.start(s.gpa, s.base_url, a) catch |err| {
                s.setMessage("Cannot install {s}: {s}", .{ a.title, @errorName(err) });
                return;
            };
            s.message_len = 0;
            return;
        };
    }

    pub fn uninstall(s: *Store, name: []const u8) void {
        if (s.job != null) return;
        remove(apps_dir, name) catch |err| {
            s.setMessage("Cannot remove {s}: {s}", .{ name, @errorName(err) });
            return;
        };
        s.setMessage("Removed {s}", .{s.title(name)});
    }

    /// An app's title, from the catalogue (else its name).
    pub fn title(s: *const Store, name: []const u8) []const u8 {
        for (s.apps()) |a| if (std.mem.eql(u8, a.name, name)) return a.title;
        return name;
    }

    /// Whether the job under way has finished (and what is shown changed).
    pub fn poll(s: *Store) bool {
        const j = &(s.job orelse return false);
        var buf: [160]u8 = undefined;
        const outcome = j.finished(&buf) orelse return false;
        const kind = j.kind;
        var name_buf: [48]u8 = undefined;
        const name = name_buf[0..j.name_len];
        @memcpy(name, j.name());
        s.job = null;
        switch (kind) {
            .catalogue => if (outcome) |why| s.setMessage("Cannot get the list of apps: {s}", .{why}) else s.loadCatalogue(),
            .install => if (outcome) |why| s.setMessage("Cannot install {s}: {s}", .{ s.title(name), why }) else s.setMessage("Installed {s}: it is in the dock", .{s.title(name)}),
        }
        return true;
    }
};

const testing = std.testing;

test "the catalogue: apps, and names that are folders" {
    const json =
        \\{"version": "abc", "apps": [
        \\  {"name": "dazzle-demo", "title": "Demo", "description": "Spins", "icon": "view_in_ar",
        \\   "file": "dazzle-demo.tar.xz", "size": 10, "sha256": "00", "added": "later"}
        \\]}
    ;
    const c = try parseCatalogue(testing.allocator, json);
    defer c.deinit();
    try testing.expectEqualStrings("Demo", c.value.apps[0].title);
    try testing.expect(validName("dazzle-demo"));
    try testing.expect(!validName("../etc"));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("Upper"));
    const bad = "{\"apps\": [{\"name\": \"../x\", \"title\": \"X\", \"file\": \"x\", \"size\": 1, \"sha256\": \"0\"}]}";
    try testing.expectError(error.BadCatalogue, parseCatalogue(testing.allocator, bad));
}

const fixture = @embedFile("testdata/hello.tar.xz");
const fixture_app: App = .{
    .name = "hello",
    .title = "Hello",
    .file = "hello.tar.xz",
    .size = fixture.len,
    .sha256 = "f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753",
};

test "a download is checked against the catalogue" {
    try verify(fixture, fixture_app);
    var wrong = fixture_app;
    wrong.size += 1;
    try testing.expectError(error.WrongSize, verify(fixture, wrong));
    wrong = fixture_app;
    wrong.sha256 = "00" ** 32;
    try testing.expectError(error.WrongChecksum, verify(fixture, wrong));
}

test "installing unpacks the app's folder into place, again replaces it, removing deletes it" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/dazzle-store-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    try unpack(testing.allocator, fixture, dir, "hello");
    try testing.expect(isInstalled(dir, "hello"));
    var buf: [128]u8 = undefined;
    const icon = try std.fmt.bufPrintZ(&buf, "{s}/hello/hello.icon", .{dir});
    var read_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("apps\n", sys.readFile(icon, &read_buf).?);
    try testing.expect(linux.errno(linux.access(icon, linux.X_OK)) != .SUCCESS);
    // Again: replaced, nothing left beside it.
    try unpack(testing.allocator, fixture, dir, "hello");
    try testing.expect(isInstalled(dir, "hello"));
    // Under another name, the archive's folder is not that app's.
    try testing.expectError(error.BadArchive, unpack(testing.allocator, fixture, dir, "other"));
    try testing.expect(!isInstalled(dir, "other"));
    try remove(dir, "hello");
    try testing.expect(!isInstalled(dir, "hello"));
    // Only the test's directory itself is left.
    const fd = try sys.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    defer sys.close(fd);
    var dents: [512]u8 align(8) = undefined;
    const n = try sys.check(linux.getdents64(fd, &dents, dents.len));
    var count: usize = 0;
    var at: usize = 0;
    while (at < n) : (count += 1) at += std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
    try testing.expectEqual(@as(usize, 2), count); // . and ..
}
