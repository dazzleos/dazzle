//! Installing and removing apps: for the setup app (choosing apps, its last
//! page) and Settings' Apps page.
//!
//! The catalogue of apps that can be installed (apps.json; see
//! tools/mkcatalogue.zig) and their archives are published where the
//! image is (`build_info.apps_url`). An app's archive is its folder, as in
//! /data/apps, as a tar file compressed with xz.
//!
//! * Downloading (the catalogue, or an app) is done over HTTPS by a child
//!   process (`Job`), so the window goes on meanwhile. It trusts the
//!   authorities in /os/certs (Mozilla's), and needs the clock set (the
//!   network manager sets it).
//! * Installing checks the archive's size and SHA-256 against the
//!   catalogue, unpacks it into a hidden folder in /data/apps (only the
//!   app's own folder, no links), and renames it into place: replacing an
//!   installed copy, if there is one.
//! * Removing renames the app's folder out of sight, then deletes it.
//!
//! /data/apps is the user's (made with /data, when setup prepares the
//! card), so the apps need no privileges for this. The catalogue last
//! downloaded is kept there as .catalogue.json, to list the apps without a
//! network.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
pub const tls_server = @import("tls_server.zig");

pub const apps_dir = sys.system.apps_dir;
pub const icons_dir = apps_dir ++ "/.icons";
pub const os_icon_file = "/os/icon.png";
pub const update_icon_file = sys.system.update_dir ++ "/icon.png";
pub const icon_size = 64;
pub const default_url = "https://github.com/dazzleos/dazzle/releases/latest/download";
pub const max_url_len = 255;
pub const server_file = apps_dir ++ "/.server";
const catalogue_file = apps_dir ++ "/.catalogue.json";
const ca_file = "/os/certs/ca-certificates.pem";

/// The most an archive or the catalogue may be.
pub const max_download = 128 * 1024 * 1024;

pub const App = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8 = "",
    version: []const u8 = "",
    time: u64 = 0,
    icon: []const u8 = "",
    file: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const Catalogue = struct {
    version: []const u8 = "",
    time: u64 = 0,
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

/// Validates a software server URL (`https://...`), trimming surrounding
/// whitespace and trailing slashes; null if it is not a valid HTTPS URL.
pub fn parseHttpsUrl(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, text, " \t\r\n"), "/");
    if (!std.mem.startsWith(u8, trimmed, "https://")) return null;
    if (trimmed.len <= "https://".len or trimmed.len > max_url_len) return null;
    for (trimmed) |c| if (c <= ' ' or c == 0x7f) return null;
    const after_scheme = trimmed["https://".len];
    if (after_scheme == '/' or after_scheme == ':' or after_scheme == '?' or after_scheme == '#') return null;
    const uri = std.Uri.parse(trimmed) catch return null;
    if (uri.host == null) return null;
    return trimmed;
}

/// Reads the custom software server URL from `/data/apps/.server` into
/// `buf`, or returns `fallback` when none (or an invalid one) is stored.
pub fn loadServerUrl(buf: *[max_url_len]u8, fallback: []const u8) []const u8 {
    return loadServerUrlFrom(server_file, buf, fallback);
}

pub fn loadServerUrlFrom(path: [:0]const u8, buf: *[max_url_len]u8, fallback: []const u8) []const u8 {
    var raw: [max_url_len + 16]u8 = undefined;
    const text = sys.readFile(path, &raw) orelse return fallback;
    const valid = parseHttpsUrl(text) orelse return fallback;
    @memcpy(buf[0..valid.len], valid);
    return buf[0..valid.len];
}

/// Saves a custom `https://` software server URL to `/data/apps/.server`,
/// or removes the file when `url` is null or empty (reverting to the
/// default server).
pub fn saveServerUrl(url: ?[]const u8) void {
    _ = linux.mkdir(apps_dir, 0o755);
    saveServerUrlTo(server_file, url);
}

pub fn saveServerUrlTo(path: [:0]const u8, url: ?[]const u8) void {
    const raw = url orelse {
        _ = linux.unlink(path);
        return;
    };
    if (raw.len == 0) {
        _ = linux.unlink(path);
        return;
    }
    const valid = parseHttpsUrl(raw) orelse return;
    var line_buf: [max_url_len + 1]u8 = undefined;
    @memcpy(line_buf[0..valid.len], valid);
    line_buf[valid.len] = '\n';
    _ = linux.unlink(path);
    sys.files.writeNew(path, line_buf[0 .. valid.len + 1]) catch {};
}

/// Whether `path` is a safe relative PNG icon filename on the server
/// ("icon.png" or "<name>.png").
pub fn validIconPath(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".png")) return false;
    const stem = path[0 .. path.len - ".png".len];
    return validName(stem);
}

/// Whether `bytes` has a 64x64 PNG header.
pub fn validIconPng(bytes: []const u8) bool {
    if (bytes.len < 24) return false;
    if (!std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return false;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    return w == icon_size and h == icon_size;
}

/// Whether app `name` is in `dir` (its folder, with its program).
pub fn isInstalled(dir: []const u8, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}/{s}", .{ dir, name, name }) catch return false;
    return linux.errno(linux.access(path, linux.X_OK)) == .SUCCESS;
}

/// The version of app `name` installed in `dir`, from `<dir>/<name>/version`.
pub fn installedVersion(dir: []const u8, name: []const u8) ?sys.system.Version {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/{s}", .{ dir, name, sys.system.Version.file_name }) catch return null;
    var buf: [96]u8 = undefined;
    const text = sys.readFile(path, &buf) orelse return null;
    return sys.system.Version.parse(text);
}

/// Whether `app` in the catalogue is newer than the copy installed in `dir`.
pub fn hasNewerVersion(dir: []const u8, app: App) bool {
    const remote = sys.system.Version.init(app.time, app.version) orelse return false;
    const local = installedVersion(dir, app.name) orelse return false;
    return remote.time > local.time and !remote.eql(&local);
}

fn hasValidIconFile(path: [*:0]const u8) bool {
    var hdr: [24]u8 = undefined;
    const bytes = sys.readFile(path, &hdr) orelse return false;
    return validIconPng(bytes);
}

/// Resolves the icon file to show for the OS: the installed `/os/icon.png`
/// when up to date, or the server's `icon.png` when a newer version is
/// available or `/os/icon.png` is missing; null for the fallback icon.
pub fn resolveOsIcon(installed_path: [:0]const u8, server_path: [:0]const u8, newer_available: bool) ?[:0]const u8 {
    const first = if (newer_available) server_path else installed_path;
    const second = if (newer_available) installed_path else server_path;
    if (hasValidIconFile(first)) return first;
    if (hasValidIconFile(second)) return second;
    return null;
}

/// Resolves the icon file to show for `app`: the installed
/// `<dir>/<name>/icon.png` when installed and up to date, or the server's
/// `<icons_path>/<name>.png` when uninstalled, when no icon is on disk or
/// when a newer version is available; null for the fallback icon.
pub fn resolveAppIcon(buf: []u8, dir: []const u8, icons_path: []const u8, app: App) ?[:0]const u8 {
    const installed = isInstalled(dir, app.name);
    const use_installed_first = installed and !hasNewerVersion(dir, app);
    if (use_installed_first) {
        if (std.fmt.bufPrintZ(buf, "{s}/{s}/icon.png", .{ dir, app.name })) |p| {
            if (hasValidIconFile(p)) return p;
        } else |_| {}
    }
    if (std.fmt.bufPrintZ(buf, "{s}/{s}.png", .{ icons_path, app.name })) |p| {
        if (hasValidIconFile(p)) return p;
    } else |_| {}
    if (!use_installed_first and installed) {
        if (std.fmt.bufPrintZ(buf, "{s}/{s}/icon.png", .{ dir, app.name })) |p| {
            if (hasValidIconFile(p)) return p;
        } else |_| {}
    }
    return null;
}

/// Checks a downloaded archive against the catalogue.
pub fn verify(archive: []const u8, app: App) !void {
    if (archive.len != app.size) return error.WrongSize;
    if (!sys.archive.sha256Is(archive, app.sha256)) return error.WrongChecksum;
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
    var new_buf: [512]u8 = undefined;
    const new = try std.fmt.bufPrintZ(&new_buf, "{s}/{s}", .{ staging, name });
    _ = try sys.check(linux.mkdir(new, 0o755));
    // Only the app's own folder.
    try sys.archive.extract(gpa, archive, name, new);
    if (!isInstalled(staging, name)) return error.BadArchive;

    // Into place: an installed copy out of the way first.
    var app_buf: [256]u8 = undefined;
    var old_buf: [256]u8 = undefined;
    const app_path = try std.fmt.bufPrintZ(&app_buf, "{s}/{s}", .{ dir, name });
    const old = try std.fmt.bufPrintZ(&old_buf, "{s}/.old-{s}", .{ dir, name });
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

// --- Downloading, in a child process ---------------------------------------------

/// What the last download asked for, and the HTTP status that said no (0
/// if none did), for the log (in a job's child process).
var last_url: []const u8 = "";
var last_status: u16 = 0;

/// An HTTP/HTTPS client that keeps its connection open across requests so
/// os.json, icon.png, apps.json and <app>.png can be fetched in one
/// socket connection.
pub const Client = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    http: ?std.http.Client = null,
    certs_loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator) Client {
        return .{ .gpa = gpa, .threaded = .init(gpa, .{}) };
    }

    pub fn deinit(c: *Client) void {
        if (c.http) |*h| h.deinit();
        c.threaded.deinit();
    }

    pub fn download(c: *Client, url: []const u8) ![]u8 {
        last_url = url;
        last_status = 0;
        const io = c.threaded.io();
        if (c.http == null) c.http = .{ .allocator = c.gpa, .io = io };
        const client = &c.http.?;
        if (std.mem.startsWith(u8, url, "https:") and !c.certs_loaded) {
            const now = std.Io.Clock.real.now(io);
            // A clock that was never set (1970) would make every certificate
            // look not yet valid.
            if (now.toSeconds() < 1_700_000_000) return error.ClockNotSet;
            client.ca_bundle.addCertsFromFilePathAbsolute(c.gpa, io, now, ca_file) catch {};
            tls_server.addTestCa(&client.ca_bundle, c.gpa, now.toSeconds()) catch {};
            if (client.ca_bundle.map.count() == 0) return error.CertificateIssuerNotFound;
            client.now = now;
            c.certs_loaded = true;
        }
        var out: std.Io.Writer.Allocating = .init(c.gpa);
        errdefer out.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &out.writer,
            .keep_alive = true,
        });
        if (result.status != .ok) {
            last_status = @intFromEnum(result.status);
            return error.HttpError;
        }
        if (out.written().len > max_download) return error.TooBig;
        return out.toOwnedSlice();
    }
};

/// Downloads `url` over HTTP/HTTPS.
pub fn download(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: Client = .init(gpa);
    defer client.deinit();
    return client.download(url);
}

/// Downloads `os.json` and `icon.png` from `base_url` into `dir` using `client`.
pub fn fetchOs(client: *Client, gpa: std.mem.Allocator, base_url: []const u8, dir: []const u8) !void {
    const url = try std.fmt.allocPrint(gpa, "{s}/os.json", .{base_url});
    defer gpa.free(url);
    const json = try client.download(url);
    defer gpa.free(json);
    const parsed = std.json.parseFromSlice(App, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadManifest;
    defer parsed.deinit();
    const m = parsed.value;
    if (sys.system.Version.init(m.time, m.version) == null or !(std.mem.endsWith(u8, m.file, ".tar.xz") and validName(m.file[0 .. m.file.len - ".tar.xz".len])) or m.sha256.len != 64) return error.BadManifest;
    var man_buf: [256]u8 = undefined;
    var tmp_buf: [256]u8 = undefined;
    const man_path = try std.fmt.bufPrintZ(&man_buf, "{s}/os.json", .{dir});
    const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}/os.json.new", .{dir});
    _ = linux.unlink(tmp);
    try sys.files.writeNew(tmp, json);
    _ = try sys.check(linux.rename(tmp, man_path));

    const icon_rel = if (validIconPath(m.icon)) m.icon else "icon.png";
    const icon_url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, icon_rel });
    defer gpa.free(icon_url);
    if (client.download(icon_url)) |png| {
        defer gpa.free(png);
        if (validIconPng(png)) {
            var icon_tmp_buf: [256]u8 = undefined;
            var icon_dst_buf: [256]u8 = undefined;
            if (std.fmt.bufPrintZ(&icon_tmp_buf, "{s}/icon.png.new", .{dir})) |icon_tmp| {
                if (std.fmt.bufPrintZ(&icon_dst_buf, "{s}/icon.png", .{dir})) |icon_dst| {
                    _ = linux.unlink(icon_tmp);
                    if (sys.files.writeNew(icon_tmp, png)) |_| {
                        _ = linux.rename(icon_tmp, icon_dst);
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        }
    } else |_| {}
}

/// Downloads `apps.json` and each app's `<name>.png` from `base_url`
/// into `dir` using `client`.
pub fn fetchCatalogue(client: *Client, gpa: std.mem.Allocator, base_url: []const u8, dir: []const u8) !void {
    const url = try std.fmt.allocPrint(gpa, "{s}/apps.json", .{base_url});
    defer gpa.free(url);
    const json = try client.download(url);
    defer gpa.free(json);
    // Only a catalogue that reads is kept.
    const parsed = try parseCatalogue(gpa, json);
    defer parsed.deinit();
    var cat_buf: [256]u8 = undefined;
    var tmp_buf: [256]u8 = undefined;
    const cat_path = try std.fmt.bufPrintZ(&cat_buf, "{s}/.catalogue.json", .{dir});
    const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}/.catalogue.json.new", .{dir});
    _ = linux.unlink(tmp);
    try sys.files.writeNew(tmp, json);
    _ = try sys.check(linux.rename(tmp, cat_path));

    var icons_buf: [256]u8 = undefined;
    const icons_path = try std.fmt.bufPrintZ(&icons_buf, "{s}/.icons", .{dir});
    _ = linux.mkdir(icons_path, 0o755);
    for (parsed.value.apps) |a| {
        var rel_buf: [96]u8 = undefined;
        const icon_rel = if (validIconPath(a.icon))
            a.icon
        else
            std.fmt.bufPrint(&rel_buf, "{s}.png", .{a.name}) catch continue;
        const icon_url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, icon_rel });
        defer gpa.free(icon_url);
        const png = client.download(icon_url) catch continue;
        defer gpa.free(png);
        if (!validIconPng(png)) continue;
        var icon_tmp_buf: [256]u8 = undefined;
        var icon_dst_buf: [256]u8 = undefined;
        const icon_tmp = std.fmt.bufPrintZ(&icon_tmp_buf, "{s}/{s}.png.new", .{ icons_path, a.name }) catch continue;
        const icon_dst = std.fmt.bufPrintZ(&icon_dst_buf, "{s}/{s}.png", .{ icons_path, a.name }) catch continue;
        _ = linux.unlink(icon_tmp);
        sys.files.writeNew(icon_tmp, png) catch continue;
        _ = linux.rename(icon_tmp, icon_dst);
    }
}

pub const Job = struct {
    pub const Kind = enum { catalogue, install, update_all, os_check, os_download };

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

    /// Starts `work(args...)` in a child process: `name` is what it is
    /// working on (an app's name, or "").
    pub fn spawn(kind: Kind, job_name: []const u8, comptime work: anytype, args: anytype) !Job {
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
            @call(.auto, work, args) catch |err| {
                var why_buf: [160]u8 = undefined;
                const why = if (last_status != 0)
                    std.fmt.bufPrint(&why_buf, "{s} (HTTP {d})", .{ describe(err), last_status }) catch describe(err)
                else
                    describe(err);
                _ = linux.write(fds[1], why.ptr, why.len);
                logFailure(kind, job_name, err);
            };
            linux.exit(0);
        }
        sys.close(fds[1]);
        var j: Job = .{ .kind = kind, .pid = @intCast(rc), .started = sys.nowNs(), .result = fds[0] };
        j.name_len = @min(job_name.len, j.name_buf.len);
        @memcpy(j.name_buf[0..j.name_len], job_name[0..j.name_len]);
        return j;
    }

    /// Logs (as a warning) why a job failed: the program's name (setup or
    /// Settings), what it was doing, the error, and the URL and HTTP
    /// status if it was a download that the server said no to.
    fn logFailure(kind: Kind, job_name: []const u8, err: anyerror) void {
        var comm_buf: [32]u8 = undefined;
        const comm = std.mem.trimEnd(u8, sys.readFile("/proc/self/comm", &comm_buf) orelse "dazzle", "\n");
        var status_buf: [16]u8 = undefined;
        const status = if (last_status != 0) std.fmt.bufPrint(&status_buf, " (HTTP {d})", .{last_status}) catch "" else "";
        sys.print(sys.log_warning ++ "{s}: cannot {s}{s}{s}: {s}{s}{s}{s}\n", .{
            comm,
            switch (kind) {
                .catalogue => "get the list of apps",
                .install => "install",
                .update_all => "update apps",
                .os_check => "check for a system update",
                .os_download => "download the system update",
            },
            if (job_name.len > 0) " " else "",
            job_name,
            @errorName(err),
            status,
            if (last_url.len > 0) " from " else "",
            last_url,
        });
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

fn childCatalogue(gpa: std.mem.Allocator, base_url: []const u8, check_os: bool) !void {
    var client: Client = .init(gpa);
    defer client.deinit();
    if (check_os) {
        _ = linux.mkdir(sys.system.update_dir, 0o755);
        fetchOs(&client, gpa, base_url, sys.system.update_dir) catch {};
    }
    try fetchCatalogue(&client, gpa, base_url, apps_dir);
}

fn childInstall(gpa: std.mem.Allocator, base_url: []const u8, app: App) !void {
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, app.file });
    const archive = try download(gpa, url);
    try verify(archive, app);
    try unpack(gpa, archive, apps_dir, app.name);
}

fn childUpdateAll(gpa: std.mem.Allocator, base_url: []const u8, list: []const App) !void {
    var client: Client = .init(gpa);
    defer client.deinit();
    for (list) |app| {
        if (!isInstalled(apps_dir, app.name) or !hasNewerVersion(apps_dir, app)) continue;
        const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, app.file });
        defer gpa.free(url);
        const archive = try client.download(url);
        defer gpa.free(archive);
        try verify(archive, app);
        try unpack(gpa, archive, apps_dir, app.name);
    }
}

/// Why a job failed, for people.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ClockNotSet => "the clock is not set yet (it is set once the network is up)",
        error.WrongSize, error.WrongChecksum => "the download was not what the catalogue said",
        error.BadArchive, error.BadName => "the archive was not right",
        error.InstallFailed => "the system could not install it",
        error.BadCatalogue, error.BadManifest => "the list of apps was not right",
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
    /// Whether refreshing also fetches `os.json` and `icon.png` over the
    /// same keep-alive connection.
    check_os: bool = false,
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

    pub fn setBaseUrl(s: *Store, base_url: []const u8) void {
        if (s.job) |*j| if (j.kind == .catalogue) {
            var status: u32 = 0;
            _ = linux.kill(j.pid, .KILL);
            _ = linux.wait4(j.pid, &status, 0, null);
            sys.close(j.result);
            s.job = null;
        };
        s.base_url = base_url;
        s.asked = false;
        s.message_len = 0;
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

    /// Downloads the catalogue again (once a session, unless asked).
    pub fn refresh(s: *Store, again: bool) void {
        if (s.job != null or (s.asked and !again)) return;
        s.asked = true;
        s.job = Job.spawn(.catalogue, "", childCatalogue, .{ s.gpa, s.base_url, s.check_os }) catch |err| {
            s.setMessage("Cannot get the list of apps: {s}", .{@errorName(err)});
            return;
        };
        s.message_len = 0;
    }

    pub fn install(s: *Store, name: []const u8) void {
        if (s.job != null) return;
        for (s.apps()) |a| if (std.mem.eql(u8, a.name, name)) {
            s.job = Job.spawn(.install, a.name, childInstall, .{ s.gpa, s.base_url, a }) catch |err| {
                s.setMessage("Cannot install {s}: {s}", .{ a.title, @errorName(err) });
                return;
            };
            s.message_len = 0;
            return;
        };
    }

    /// Updates all installed apps that have a newer version in the catalogue.
    pub fn updateAll(s: *Store) void {
        if (s.job != null) return;
        var any = false;
        for (s.apps()) |a| if (isInstalled(apps_dir, a.name) and hasNewerVersion(apps_dir, a)) {
            any = true;
            break;
        };
        if (!any) return;
        s.job = Job.spawn(.update_all, "*", childUpdateAll, .{ s.gpa, s.base_url, s.apps() }) catch |err| {
            s.setMessage("Cannot update apps: {s}", .{@errorName(err)});
            return;
        };
        s.message_len = 0;
    }

    pub fn uninstall(s: *Store, name: []const u8) void {
        if (s.job != null) return;
        remove(apps_dir, name) catch |err| {
            s.setMessage("Cannot remove {s}: {s}", .{ s.title(name), @errorName(err) });
            return;
        };
        s.message_len = 0;
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
            .install => if (outcome) |why| s.setMessage("Cannot install {s}: {s}", .{ s.title(name), why }),
            .update_all => if (outcome) |why| s.setMessage("Cannot update apps: {s}", .{why}) else {
                s.message_len = 0;
            },
            .os_check, .os_download => {},
        }
        return true;
    }
};

const testing = std.testing;

test "the catalogue: apps, and names that are folders" {
    const json =
        \\{"version": "abc", "time": 1791331200, "apps": [
        \\  {"name": "dazzle-demo", "title": "Demo", "description": "Spins",
        \\   "version": "abc", "time": 1791331200, "icon": "dazzle-demo.png",
        \\   "file": "dazzle-demo.tar.xz", "size": 10, "sha256": "00", "added": "later"}
        \\]}
    ;
    const c = try parseCatalogue(testing.allocator, json);
    defer c.deinit();
    try testing.expectEqualStrings("Demo", c.value.apps[0].title);
    try testing.expectEqualStrings("dazzle-demo.png", c.value.apps[0].icon);
    try testing.expectEqual(@as(u64, 1791331200), c.value.apps[0].time);
    try testing.expect(validName("dazzle-demo"));
    try testing.expect(!validName("../etc"));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("Upper"));
    try testing.expect(validIconPath("icon.png"));
    try testing.expect(validIconPath("dazzle-demo.png"));
    try testing.expect(!validIconPath("../icon.png"));
    try testing.expect(!validIconPath("icons/dazzle-demo.png"));
    try testing.expect(!validIconPath("view_in_ar"));
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

test "keep-alive fetches os.json, icon.png, apps.json and <app>.png on a single socket connection" {
    // A minimal 64x64 PNG header for the server to return.
    const png_64 = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x00\x40" ++ "\x00\x00\x00\x40" ++ "\x08\x06\x00\x00\x00";
    try testing.expect(validIconPng(png_64));

    const listener: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(listener);
    var addr: linux.sockaddr.in = .{
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    _ = try sys.check(linux.bind(listener, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    _ = try sys.check(linux.listen(listener, 1));
    var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try sys.check(linux.getsockname(listener, @ptrCast(&addr), &addr_len));
    const port = std.mem.bigToNative(u16, addr.port);

    const Server = struct {
        fn run(lfd: linux.fd_t) void {
            const os_body =
                \\{"name":"dazzle","title":"Dazzle","description":"The operating system","version":"0123abc","time":1791400000,"icon":"icon.png","file":"dazzle-os.tar.xz","size":10,"sha256":"f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753"}
            ;
            const apps_body =
                \\{"version":"0123abc","time":1791400000,"apps":[{"name":"dazzle-demo","title":"Demo","description":"Spins","version":"0123abc","time":1791400000,"icon":"dazzle-demo.png","file":"dazzle-demo.tar.xz","size":10,"sha256":"00"}]}
            ;
            // Accept only ONE socket connection: all 4 requests must arrive on it.
            const rc = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return;
            const conn: linux.fd_t = @intCast(rc);
            defer sys.close(conn);

            var req_buf: [2048]u8 = undefined;
            var filled: usize = 0;
            for (0..4) |_| {
                const header_end = while (true) {
                    if (std.mem.indexOf(u8, req_buf[0..filled], "\r\n\r\n")) |idx| break idx + 4;
                    const n = sys.check(linux.read(conn, req_buf[filled..].ptr, req_buf.len - filled)) catch return;
                    if (n == 0) return;
                    filled += n;
                };
                const req = req_buf[0..header_end];
                const body: []const u8 = if (std.mem.startsWith(u8, req, "GET /os.json "))
                    os_body
                else if (std.mem.startsWith(u8, req, "GET /icon.png "))
                    png_64 ++ "OS"
                else if (std.mem.startsWith(u8, req, "GET /apps.json "))
                    apps_body
                else if (std.mem.startsWith(u8, req, "GET /dazzle-demo.png "))
                    png_64 ++ "DEMO"
                else
                    return;
                var resp_buf: [1024]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &resp_buf,
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch return;
                _ = linux.write(conn, resp.ptr, resp.len);
                const rest = filled - header_end;
                std.mem.copyForwards(u8, req_buf[0..rest], req_buf[header_end..filled]);
                filled = rest;
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Server.run, .{listener});
    defer thread.join();

    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/dazzle-keepalive-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var os_dir_buf: [80]u8 = undefined;
    var apps_dir_buf: [80]u8 = undefined;
    const os_dir = try std.fmt.bufPrintZ(&os_dir_buf, "{s}/update", .{dir});
    const app_dir = try std.fmt.bufPrintZ(&apps_dir_buf, "{s}/apps", .{dir});
    _ = linux.mkdir(os_dir, 0o755);
    _ = linux.mkdir(app_dir, 0o755);

    var url_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port});
    var client: Client = .init(testing.allocator);
    defer client.deinit();
    try fetchOs(&client, testing.allocator, base_url, os_dir);
    try fetchCatalogue(&client, testing.allocator, base_url, app_dir);

    var path_buf: [128]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    const os_icon = try std.fmt.bufPrintZ(&path_buf, "{s}/icon.png", .{os_dir});
    try testing.expectEqualStrings(png_64 ++ "OS", sys.readFile(os_icon, &read_buf).?);
    const demo_icon = try std.fmt.bufPrintZ(&path_buf, "{s}/.icons/dazzle-demo.png", .{app_dir});
    try testing.expectEqualStrings(png_64 ++ "DEMO", sys.readFile(demo_icon, &read_buf).?);
}

test "parsing and saving custom https software server URLs" {
    try testing.expectEqualStrings(
        "https://github.com/dazzleos/dazzle/releases/latest/download",
        parseHttpsUrl(default_url).?,
    );
    try testing.expectEqualStrings(
        "https://example.com/dazzle",
        parseHttpsUrl("  https://example.com/dazzle/  ").?,
    );
    try testing.expectEqualStrings(
        "https://192.168.1.10:8443/releases",
        parseHttpsUrl("https://192.168.1.10:8443/releases///").?,
    );
    try testing.expect(parseHttpsUrl("") == null);
    try testing.expect(parseHttpsUrl("http://example.com/dazzle") == null);
    try testing.expect(parseHttpsUrl("https://") == null);
    try testing.expect(parseHttpsUrl("https:///path") == null);
    try testing.expect(parseHttpsUrl("https://:443/path") == null);
    try testing.expect(parseHttpsUrl("https://example.com/has space") == null);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/dazzle-server-test-{d}", .{linux.getpid()});
    defer _ = linux.unlink(path);

    var buf: [max_url_len]u8 = undefined;
    try testing.expectEqualStrings(default_url, loadServerUrlFrom(path, &buf, default_url));

    saveServerUrlTo(path, "https://staging.example.com/dazzle/");
    try testing.expectEqualStrings("https://staging.example.com/dazzle", loadServerUrlFrom(path, &buf, default_url));

    saveServerUrlTo(path, null);
    try testing.expectEqualStrings(default_url, loadServerUrlFrom(path, &buf, default_url));
}

test "HTTPS client trusts the Dazzle Test CA and fetches over TLS 1.3 keep-alive" {
    const png_64 = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x00\x40" ++ "\x00\x00\x00\x40" ++ "\x08\x06\x00\x00\x00";
    const listener: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer sys.close(listener);
    var addr: linux.sockaddr.in = .{
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    _ = try sys.check(linux.bind(listener, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    _ = try sys.check(linux.listen(listener, 1));
    var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try sys.check(linux.getsockname(listener, @ptrCast(&addr), &addr_len));
    const port = std.mem.bigToNative(u16, addr.port);

    const HttpsServer = struct {
        fn run(lfd: linux.fd_t) void {
            const os_body =
                \\{"name":"dazzle","title":"Dazzle","description":"The operating system","version":"0123abc","time":1791400000,"icon":"icon.png","file":"dazzle-os.tar.xz","size":10,"sha256":"f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753"}
            ;
            const apps_body =
                \\{"version":"0123abc","time":1791400000,"apps":[{"name":"dazzle-demo","title":"Demo","description":"Spins","version":"0123abc","time":1791400000,"icon":"dazzle-demo.png","file":"dazzle-demo.tar.xz","size":10,"sha256":"00"}]}
            ;
            const rc = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return;
            const fd: linux.fd_t = @intCast(rc);
            defer sys.close(fd);

            var tls_conn = tls_server.Conn.handshake(fd, "127.0.0.1") catch return;
            var req_buf: [16384]u8 = undefined;
            var filled: usize = 0;
            for (0..4) |_| {
                const header_end = while (true) {
                    if (std.mem.indexOf(u8, req_buf[0..filled], "\r\n\r\n")) |idx| break idx + 4;
                    var chunk: [16384]u8 = undefined;
                    const n = tls_conn.read(&chunk) catch return;
                    if (n == 0 or filled + n > req_buf.len) return;
                    @memcpy(req_buf[filled .. filled + n], chunk[0..n]);
                    filled += n;
                };
                const req = req_buf[0..header_end];
                const body: []const u8 = if (std.mem.startsWith(u8, req, "GET /os.json "))
                    os_body
                else if (std.mem.startsWith(u8, req, "GET /icon.png "))
                    png_64 ++ "TLS-OS"
                else if (std.mem.startsWith(u8, req, "GET /apps.json "))
                    apps_body
                else if (std.mem.startsWith(u8, req, "GET /dazzle-demo.png "))
                    png_64 ++ "TLS-DEMO"
                else
                    return;
                var resp_buf: [1024]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &resp_buf,
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch return;
                tls_conn.writeAll(resp) catch return;
                const rest = filled - header_end;
                std.mem.copyForwards(u8, req_buf[0..rest], req_buf[header_end..filled]);
                filled = rest;
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, HttpsServer.run, .{listener});
    defer thread.join();

    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/dazzle-https-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var os_dir_buf: [80]u8 = undefined;
    var apps_dir_buf: [80]u8 = undefined;
    const os_dir = try std.fmt.bufPrintZ(&os_dir_buf, "{s}/update", .{dir});
    const app_dir = try std.fmt.bufPrintZ(&apps_dir_buf, "{s}/apps", .{dir});
    _ = linux.mkdir(os_dir, 0o755);
    _ = linux.mkdir(app_dir, 0o755);

    var url_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}", .{port});
    var client: Client = .init(testing.allocator);
    defer client.deinit();
    try fetchOs(&client, testing.allocator, base_url, os_dir);
    try fetchCatalogue(&client, testing.allocator, base_url, app_dir);

    var path_buf: [128]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    const os_icon = try std.fmt.bufPrintZ(&path_buf, "{s}/icon.png", .{os_dir});
    try testing.expectEqualStrings(png_64 ++ "TLS-OS", sys.readFile(os_icon, &read_buf).?);
    const demo_icon = try std.fmt.bufPrintZ(&path_buf, "{s}/.icons/dazzle-demo.png", .{app_dir});
    try testing.expectEqualStrings(png_64 ++ "TLS-DEMO", sys.readFile(demo_icon, &read_buf).?);
}



