//! Installing and removing apps: for the setup app (choosing apps, its last
//! page) and Settings' Software page.
//!
//! The catalogue of apps that can be installed (apps.json; see
//! tools/mkcatalogue.zig) and their archives are published where the
//! image is (`build_info.apps_url`), or on a custom `https://` software
//! server stored in `/data/apps/.server`. An app's archive is its folder,
//! as in /data/apps, as a tar file compressed with xz.
//!
//! * Downloading (the catalogue, or an app) is done over HTTPS by a child
//!   process (`Job`), so the window goes on meanwhile. It trusts the
//!   authorities in /os/certs (Mozilla's) and the `Dazzle Test CA` used by
//!   `dazzle-serve`, and needs the clock set (the network manager sets it).
//! * Installing checks the archive's size, SHA-256 and Ed25519 signature
//!   against the catalogue (using the built-in public key and any extra
//!   public keys subscribed in `/data/apps/.keys`), unpacks it into a hidden
//!   folder in /data/apps (only the app's own folder, no links), and renames
//!   it into place: replacing an installed copy, if there is one.
//! * Removing renames the app's folder out of sight, then deletes it.
//!
//! /data/apps is the user's (made with /data, when setup prepares the
//! card), so the apps need no privileges for this. The catalogue last
//! downloaded is kept there as .catalogue.json, to list the apps without a
//! network.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const build_info = @import("build_info");
pub const tls_server = @import("tls_server.zig");
pub const Ed25519 = std.crypto.sign.Ed25519;

pub const apps_dir = sys.system.apps_dir;
pub const icons_dir = apps_dir ++ "/.icons";
pub const os_icon_file = "/os/icon.png";
pub const update_icon_file = sys.system.update_dir ++ "/icon.png";
pub const icon_size = 64;
pub const default_url = "https://github.com/dazzleos/dazzle/releases/latest/download";
pub const max_url_len = 255;
pub const server_file = apps_dir ++ "/.server";
pub const keys_file = apps_dir ++ "/.keys";
pub const key_hex_len = Ed25519.PublicKey.encoded_length * 2;
pub const sig_hex_len = Ed25519.Signature.encoded_length * 2;
pub const max_keys = 16;
pub const default_signing_key: []const u8 = build_info.signing_key;
pub const default_seed: [32]u8 = "dazzle-signing-key-seed-00000001".*;
/// The apps' catalogue, as last downloaded.
pub const catalogue_file = apps_dir ++ "/.catalogue.json";
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
    signature: []const u8 = "",
    /// A language pack's language (its code): data the system uses for
    /// it (Japanese's dictionary), installed like an app but not one (it
    /// has no program, and is not listed with the apps).
    language: []const u8 = "",
};

pub const Catalogue = struct {
    version: []const u8 = "",
    time: u64 = 0,
    /// The apps, then the language packs (see `parseCatalogue`).
    apps: []const App,
    /// How many of them are apps.
    n_apps: usize = 0,
};

/// The catalogue in `json`: its apps first, then its language packs.
pub fn parseCatalogue(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(Catalogue) {
    var parsed = try std.json.parseFromSlice(Catalogue, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    for (parsed.value.apps) |a| if (!validName(a.name)) return error.BadCatalogue;
    const all: []App = @constCast(parsed.value.apps);
    std.mem.sort(App, all, {}, struct {
        fn lt(_: void, a: App, b: App) bool {
            return a.language.len == 0 and b.language.len != 0;
        }
    }.lt);
    var n: usize = 0;
    while (n < all.len and all[n].language.len == 0) n += 1;
    parsed.value.n_apps = n;
    return parsed;
}

/// The language pack for `code` ("ja") in `catalogue`, if it has one.
pub fn languagePackIn(catalogue: Catalogue, code: []const u8) ?App {
    for (catalogue.apps[catalogue.n_apps..]) |a| if (std.mem.eql(u8, a.language, code)) return a;
    return null;
}

/// Whether `entry` (an app, or a language pack) is installed in `dir`.
pub fn installedEntry(dir: []const u8, entry: App) bool {
    return if (entry.language.len != 0) isPackInstalled(dir, entry.name) else isInstalled(dir, entry.name);
}

/// Whether language pack `name` is installed in `dir`.
pub fn isPackInstalled(dir: []const u8, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const path = std.mem.printSentinel(&buf, "{s}/{s}/version", .{ dir, name }, 0) catch return false;
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
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
    const path = std.mem.printSentinel(&buf, "{s}/{s}/{s}", .{ dir, name, name }, 0) catch return false;
    return linux.errno(linux.access(path, linux.X_OK)) == .SUCCESS;
}

/// The apps installed in `dir` that `catalogue` does not have (it no
/// longer offers them, or they came from another server): as catalogue
/// entries, with a title made from the name ("dazzle-kete-demo" is "Kete
/// Demo"), in `gpa` (free with `freeInstalledOnly`), sorted by name.
pub fn installedOnly(gpa: std.mem.Allocator, dir: []const u8, catalogue: []const App) ![]App {
    var list: std.ArrayList(App) = .empty;
    errdefer freeInstalledOnly(gpa, list.items);
    var dir_buf: [256]u8 = undefined;
    const dir_z = std.mem.printSentinel(&dir_buf, "{s}", .{dir}, 0) catch return error.NameTooLong;
    const fd = sys.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return list.toOwnedSlice(gpa);
    defer sys.close(fd);
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(fd, &buf, buf.len)) catch break;
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len == 0 or name[0] == '.' or !validName(name) or !isInstalled(dir, name)) continue;
            const offered = for (catalogue) |a| {
                if (std.mem.eql(u8, a.name, name)) break true;
            } else false;
            if (offered) continue;
            const owned = try gpa.dupe(u8, name);
            errdefer gpa.free(owned);
            const title = try titleOf(gpa, name);
            errdefer gpa.free(title);
            try list.append(gpa, .{ .name = owned, .title = title, .file = "", .size = 0, .sha256 = "" });
        }
    }
    std.mem.sort(App, list.items, {}, struct {
        fn lt(_: void, a: App, b: App) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return list.toOwnedSlice(gpa);
}

pub fn freeInstalledOnly(gpa: std.mem.Allocator, list: []const App) void {
    for (list) |a| {
        gpa.free(a.name);
        gpa.free(a.title);
    }
    gpa.free(list);
}

/// A title for an app known only by its name: without "dazzle-", its words
/// (between dashes) capitalised.
fn titleOf(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const base = if (std.mem.startsWith(u8, name, "dazzle-") and name.len > "dazzle-".len) name["dazzle-".len..] else name;
    const out = try gpa.dupe(u8, base);
    var start = true;
    for (out) |*c| {
        if (c.* == '-' or c.* == '_') {
            c.* = ' ';
            start = true;
        } else {
            if (start) c.* = std.ascii.toUpper(c.*);
            start = false;
        }
    }
    return out;
}

/// The version of app `name` installed in `dir`, from `<dir>/<name>/version`.
pub fn installedVersion(dir: []const u8, name: []const u8) ?sys.system.Version {
    var path_buf: [256]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "{s}/{s}/{s}", .{ dir, name, sys.system.Version.file_name }, 0) catch return null;
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
        if (std.mem.printSentinel(buf, "{s}/{s}/icon.png", .{ dir, app.name }, 0)) |p| {
            if (hasValidIconFile(p)) return p;
        } else |_| {}
    }
    if (std.mem.printSentinel(buf, "{s}/{s}.png", .{ icons_path, app.name }, 0)) |p| {
        if (hasValidIconFile(p)) return p;
    } else |_| {}
    if (!use_installed_first and installed) {
        if (std.mem.printSentinel(buf, "{s}/{s}/icon.png", .{ dir, app.name }, 0)) |p| {
            if (hasValidIconFile(p)) return p;
        } else |_| {}
    }
    return null;
}

/// Parses a 64-character hex Ed25519 public key (ignoring surrounding
/// whitespace), rejecting non-canonical encodings, off-curve points, and
/// small-order torsion points, and writes its lowercase hex form to `out_hex`.
pub fn parsePublicKey(text: []const u8, out_hex: *[key_hex_len]u8) ?Ed25519.PublicKey {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != key_hex_len) return null;
    for (trimmed, out_hex) |c, *dst| {
        if (!std.ascii.isHex(c)) return null;
        dst.* = std.ascii.toLower(c);
    }
    var bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, out_hex) catch return null;
    const pk = Ed25519.PublicKey.fromBytes(bytes) catch return null;
    const p = std.crypto.ecc.Edwards25519.fromBytes(bytes) catch return null;
    p.clearCofactor().rejectIdentity() catch return null;
    return pk;
}

/// Validates a 64-character hex Ed25519 public key and returns its
/// normalized lowercase hex array, or null if invalid.
pub fn validPublicKey(text: []const u8) ?[key_hex_len]u8 {
    var out: [key_hex_len]u8 = undefined;
    _ = parsePublicKey(text, &out) orelse return null;
    return out;
}

/// User-subscribed Ed25519 public keys (stored in `/data/apps/.keys`).
pub const KeyList = struct {
    keys: [max_keys][key_hex_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(l: *const KeyList) []const [key_hex_len]u8 {
        return l.keys[0..l.len];
    }

    pub fn contains(l: *const KeyList, hex: []const u8) bool {
        for (l.slice()) |*k| {
            if (std.ascii.eqlIgnoreCase(k, hex)) return true;
        }
        return false;
    }

    pub fn add(l: *KeyList, text: []const u8) bool {
        const norm = validPublicKey(text) orelse return false;
        if (std.ascii.eqlIgnoreCase(&norm, default_signing_key)) return true;
        if (l.contains(&norm)) return true;
        if (l.len >= max_keys) return false;
        l.keys[l.len] = norm;
        l.len += 1;
        return true;
    }

    pub fn remove(l: *KeyList, text: []const u8) bool {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        var i: usize = 0;
        var removed = false;
        while (i < l.len) {
            if (std.ascii.eqlIgnoreCase(&l.keys[i], trimmed)) {
                var j = i;
                while (j + 1 < l.len) : (j += 1) l.keys[j] = l.keys[j + 1];
                l.len -= 1;
                removed = true;
            } else {
                i += 1;
            }
        }
        return removed;
    }
};

pub fn loadKeys() KeyList {
    return loadKeysFrom(keys_file);
}

pub fn loadKeysFrom(path: [:0]const u8) KeyList {
    var list: KeyList = .{};
    var raw: [max_keys * (key_hex_len + 4) + 64]u8 = undefined;
    const text = sys.readFile(path, &raw) orelse return list;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        _ = list.add(line);
    }
    return list;
}

pub fn saveKeys(list: *const KeyList) void {
    _ = linux.mkdir(apps_dir, 0o755);
    saveKeysTo(keys_file, list);
}

pub fn saveKeysTo(path: [:0]const u8, list: *const KeyList) void {
    if (list.len == 0) {
        _ = linux.unlink(path);
        return;
    }
    var buf: [max_keys * (key_hex_len + 1)]u8 = undefined;
    var pos: usize = 0;
    for (list.slice()) |*k| {
        @memcpy(buf[pos .. pos + key_hex_len], k);
        buf[pos + key_hex_len] = '\n';
        pos += key_hex_len + 1;
    }
    _ = linux.unlink(path);
    sys.files.writeNew(path, buf[0..pos]) catch {};
}

pub fn subscribeKey(text: []const u8) bool {
    _ = linux.mkdir(apps_dir, 0o755);
    return subscribeKeyAt(keys_file, text);
}

pub fn subscribeKeyAt(path: [:0]const u8, text: []const u8) bool {
    var list = loadKeysFrom(path);
    if (!list.add(text)) return false;
    saveKeysTo(path, &list);
    return true;
}

pub fn unsubscribeKey(text: []const u8) void {
    unsubscribeKeyAt(keys_file, text);
}

pub fn unsubscribeKeyAt(path: [:0]const u8, text: []const u8) void {
    var list = loadKeysFrom(path);
    if (list.remove(text)) saveKeysTo(path, &list);
}

/// Signs `data` with the Ed25519 key pair derived from `seed`, returning
/// the 128-character lowercase hex signature.
pub fn signHex(data: []const u8, seed: [32]u8) [sig_hex_len]u8 {
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    const sig = kp.sign(data, null) catch unreachable;
    const bytes = sig.toBytes();
    var out: [sig_hex_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&bytes}) catch unreachable;
    return out;
}

/// Checks that `signature_hex` (128 hex digits) is a valid Ed25519
/// signature over `data` by `default_signing_key` or one of `extra_keys`.
pub fn verifySignature(data: []const u8, signature_hex: []const u8, extra_keys: []const [key_hex_len]u8) !void {
    const trimmed = std.mem.trim(u8, signature_hex, " \t\r\n");
    if (trimmed.len != sig_hex_len) return error.BadSignature;
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig_bytes, trimmed) catch return error.BadSignature;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);

    var key_hex: [key_hex_len]u8 = undefined;
    if (parsePublicKey(default_signing_key, &key_hex)) |pk| {
        if (sig.verify(data, pk)) |_| return else |_| {}
    }
    for (extra_keys) |*k| {
        if (parsePublicKey(k, &key_hex)) |pk| {
            if (sig.verify(data, pk)) |_| return else |_| {}
        }
    }
    return error.BadSignature;
}

/// Checks a downloaded archive against the catalogue (size, SHA-256, and
/// Ed25519 signature against the default key and subscribed keys).
pub fn verify(archive: []const u8, app: App) !void {
    const keys = loadKeys();
    return verifyWithKeys(archive, app, keys.slice());
}

pub fn verifyWithKeys(archive: []const u8, app: App, extra_keys: []const [key_hex_len]u8) !void {
    if (archive.len != app.size) return error.WrongSize;
    if (!sys.archive.sha256Is(archive, app.sha256)) return error.WrongChecksum;
    try verifySignature(archive, app.signature, extra_keys);
}

/// Unpacks `archive` (xz-compressed tar) into `dir` as app `name`,
/// replacing the app if it is there.
pub fn unpack(gpa: std.mem.Allocator, archive: []const u8, dir: []const u8, name: []const u8) !void {
    if (!validName(name)) return error.BadName;
    var staging_buf: [256]u8 = undefined;
    const staging = try std.mem.printSentinel(&staging_buf, "{s}/.install-{s}", .{ dir, name }, 0);
    sys.files.removeTree(staging);
    _ = try sys.check(linux.mkdir(staging, 0o755));
    defer sys.files.removeTree(staging);
    var new_buf: [512]u8 = undefined;
    const new = try std.mem.printSentinel(&new_buf, "{s}/{s}", .{ staging, name }, 0);
    _ = try sys.check(linux.mkdir(new, 0o755));
    // Only the app's own folder.
    try sys.archive.extract(gpa, archive, name, new);
    if (!isInstalled(staging, name)) return error.BadArchive;

    // Into place: an installed copy out of the way first.
    var app_buf: [256]u8 = undefined;
    var old_buf: [256]u8 = undefined;
    const app_path = try std.mem.printSentinel(&app_buf, "{s}/{s}", .{ dir, name }, 0);
    const old = try std.mem.printSentinel(&old_buf, "{s}/.old-{s}", .{ dir, name }, 0);
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
    const app_path = try std.mem.printSentinel(&app_buf, "{s}/{s}", .{ dir, name }, 0);
    const gone = try std.mem.printSentinel(&gone_buf, "{s}/.remove-{s}", .{ dir, name }, 0);
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

    /// The HTTP client, ready for `url` (with the certificates loaded, for
    /// HTTPS).
    fn prepare(c: *Client, url: []const u8) !*std.http.Client {
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
        return client;
    }

    /// Downloads `url` into memory: for what is small (a catalogue, a
    /// manifest, an icon).
    pub fn download(c: *Client, url: []const u8) ![]u8 {
        const client = try c.prepare(url);
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

    /// Downloads `url` into the new file `path` (replacing one left there),
    /// a piece at a time, so that an archive of tens of megabytes never
    /// has to fit in memory: it fails once more than `size` bytes come, or
    /// if fewer than `size` do. On failure the file is removed.
    pub fn downloadToFile(c: *Client, url: []const u8, path: [:0]const u8, size: u64) !void {
        const client = try c.prepare(url);
        _ = linux.unlink(path);
        const fd = try sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
        var ok = false;
        defer {
            sys.close(fd);
            if (!ok) _ = linux.unlink(path);
        }
        _ = linux.fchmod(fd, 0o644);
        var buf: [64 * 1024]u8 = undefined;
        var fw: FileWriter = .{ .fd = fd, .limit = size, .interface = .{ .vtable = &.{ .drain = FileWriter.drain }, .buffer = &buf } };
        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &fw.interface,
            .keep_alive = true,
        }) catch |err| return fw.failure orelse err;
        if (result.status != .ok) {
            last_status = @intFromEnum(result.status);
            return error.HttpError;
        }
        fw.interface.flush() catch return fw.failure orelse error.WriteFailed;
        if (fw.written != size) return error.WrongSize;
        _ = try sys.check(linux.fsync(fd));
        ok = true;
    }
};

/// Writes a download to a file, stopping at `limit` bytes.
const FileWriter = struct {
    fd: linux.fd_t,
    limit: u64,
    written: u64 = 0,
    /// Why writing stopped, if it did.
    failure: ?anyerror = null,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FileWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.writeAll(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.writeAll(d);
            n += d.len;
        }
        for (0..splat) |_| try self.writeAll(data[data.len - 1]);
        return n + data[data.len - 1].len * splat;
    }

    fn writeAll(self: *FileWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (self.written + bytes.len > self.limit) {
            self.failure = error.WrongSize;
            return error.WriteFailed;
        }
        var at: usize = 0;
        while (at < bytes.len) at += sys.check(linux.write(self.fd, bytes[at..].ptr, bytes.len - at)) catch |err| {
            self.failure = err;
            return error.WriteFailed;
        };
        self.written += bytes.len;
    }
};

/// Downloads `url` over HTTP/HTTPS.
pub fn download(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: Client = .init(gpa);
    defer client.deinit();
    return client.download(url);
}

/// Downloads the system update `m` offers (from `base_url`) to the card,
/// checks its size, SHA-256 and signature, and asks the system manager to
/// install it (which checks them again): it unpacks it into the slot not
/// running and has the firmware start that slot next time. For a job's
/// child process (`Job`): Settings', or the shell's (remote control).
pub fn downloadAndInstallOs(gpa: std.mem.Allocator, base_url: []const u8, m: OsManifest) !void {
    const proto = sys.system;
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, m.file });
    // Straight to the card, not into memory.
    const tmp = proto.update_archive ++ ".new";
    var client: Client = .init(gpa);
    defer client.deinit();
    try client.downloadToFile(url, tmp, m.size);
    errdefer _ = linux.unlink(tmp);
    {
        const archive = try sys.files.Mapped.open(tmp);
        defer archive.close();
        if (!sys.archive.sha256Is(archive.data, m.sha256)) return error.WrongChecksum;
        const keys = loadKeys();
        try verifySignature(archive.data, m.signature, keys.slice());
    }
    _ = try sys.check(linux.rename(tmp, proto.update_archive));
    var request: [208]u8 = undefined;
    // The manager answers between slices of other work (making the other
    // slot, say), which can take it a while on a slow card.
    const report = proto.ask(try std.fmt.bufPrint(&request, "update {s} {s}\n", .{ m.sha256, m.signature }), 30_000) orelse return error.InstallFailed;
    if (report.denied or report.update == .failed) return error.InstallFailed;
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
    const man_path = try std.mem.printSentinel(&man_buf, "{s}/os.json", .{dir}, 0);
    const tmp = try std.mem.printSentinel(&tmp_buf, "{s}/os.json.new", .{dir}, 0);
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
            if (std.mem.printSentinel(&icon_tmp_buf, "{s}/icon.png.new", .{dir}, 0)) |icon_tmp| {
                if (std.mem.printSentinel(&icon_dst_buf, "{s}/icon.png", .{dir}, 0)) |icon_dst| {
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
    const cat_path = try std.mem.printSentinel(&cat_buf, "{s}/.catalogue.json", .{dir}, 0);
    const tmp = try std.mem.printSentinel(&tmp_buf, "{s}/.catalogue.json.new", .{dir}, 0);
    _ = linux.unlink(tmp);
    try sys.files.writeNew(tmp, json);
    _ = try sys.check(linux.rename(tmp, cat_path));

    var icons_buf: [256]u8 = undefined;
    const icons_path = try std.mem.printSentinel(&icons_buf, "{s}/.icons", .{dir}, 0);
    _ = linux.mkdir(icons_path, 0o755);
    for (parsed.value.apps) |a| {
        // Language packs have no icon.
        if (a.language.len != 0) continue;
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
        const icon_tmp = std.mem.printSentinel(&icon_tmp_buf, "{s}/{s}.png.new", .{ icons_path, a.name }, 0) catch continue;
        const icon_dst = std.mem.printSentinel(&icon_dst_buf, "{s}/{s}.png", .{ icons_path, a.name }, 0) catch continue;
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

    /// How long a job may take: little for the small files of a list of
    /// apps or a system update's description, longer for downloads.
    fn timeLimit(kind: Kind) u64 {
        return switch (kind) {
            .catalogue, .os_check => 30 * std.time.ns_per_s,
            .install, .update_all, .os_download => 10 * 60 * std.time.ns_per_s,
        };
    }

    /// If the job has finished: null if it worked, else why not (in `buf`).
    pub fn finished(j: *Job, buf: []u8) ??[]const u8 {
        var status: u32 = 0;
        const rc = linux.wait4(j.pid, @ptrCast(&status), linux.W.NOHANG, null);
        if (linux.errno(rc) == .SUCCESS and rc == 0) {
            if (sys.nowNs() -| j.started < timeLimit(j.kind)) return null;
            _ = linux.kill(j.pid, .KILL);
            _ = linux.wait4(j.pid, @ptrCast(&status), 0, null);
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
    var client: Client = .init(gpa);
    defer client.deinit();
    try downloadAndInstall(&client, gpa, base_url, app);
}

fn childUpdateAll(gpa: std.mem.Allocator, base_url: []const u8, list: []const App) !void {
    var client: Client = .init(gpa);
    defer client.deinit();
    for (list) |app| {
        if (!installedEntry(apps_dir, app) or !hasNewerVersion(apps_dir, app)) continue;
        try downloadAndInstall(&client, gpa, base_url, app);
    }
}

/// Downloads `app`'s archive to /data/apps/.download-<name> (not into
/// memory: Develop's is tens of megabytes, too much beside everything else
/// on a 512 MB Pi), checks it and installs it.
fn downloadAndInstall(client: *Client, gpa: std.mem.Allocator, base_url: []const u8, app: App) !void {
    if (!validName(app.name)) return error.BadName;
    if (app.size > max_download) return error.TooBig;
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, app.file });
    defer gpa.free(url);
    var path_buf: [256]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "{s}/.download-{s}", .{ apps_dir, app.name }, 0);
    try client.downloadToFile(url, path, app.size);
    defer _ = linux.unlink(path);
    const archive = try sys.files.Mapped.open(path);
    defer archive.close();
    try verify(archive.data, app);
    try unpack(gpa, archive.data, apps_dir, app.name);
}

/// Why a job failed, for people.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ClockNotSet => "the clock is not set yet (it is set once the network is up)",
        error.WrongSize, error.WrongChecksum => "the download was not what the catalogue said",
        error.BadSignature => "the download's signature could not be trusted",
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

/// What the Software page shows and does for apps: the catalogue, and the job under way.
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
            _ = linux.wait4(j.pid, @ptrCast(&status), 0, null);
            sys.close(j.result);
            s.job = null;
        };
        s.base_url = base_url;
        s.asked = false;
        s.message_len = 0;
    }

    /// Reads the catalogue downloaded last (by this or another program).
    pub fn loadCatalogue(s: *Store) void {
        const json = sys.readFileAlloc(s.gpa, catalogue_file, max_download) catch return;
        defer s.gpa.free(json);
        const parsed = parseCatalogue(s.gpa, json) catch return;
        if (s.catalogue) |*c| c.deinit();
        s.catalogue = parsed;
    }

    /// The catalogue's apps (not its language packs).
    pub fn apps(s: *const Store) []const App {
        return if (s.catalogue) |c| c.value.apps[0..c.value.n_apps] else &.{};
    }

    /// The catalogue's apps and language packs.
    pub fn entries(s: *const Store) []const App {
        return if (s.catalogue) |c| c.value.apps else &.{};
    }

    /// The catalogue's language pack for `code` ("ja"), if it has one.
    pub fn languagePack(s: *const Store, code: []const u8) ?App {
        return if (s.catalogue) |c| languagePackIn(c.value, code) else null;
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

    /// Installs app (or language pack) `name`, from the catalogue.
    pub fn install(s: *Store, name: []const u8) void {
        if (s.job != null) return;
        for (s.entries()) |a| if (std.mem.eql(u8, a.name, name)) {
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
        for (s.entries()) |a| if (installedEntry(apps_dir, a) and hasNewerVersion(apps_dir, a)) {
            any = true;
            break;
        };
        if (!any) return;
        s.job = Job.spawn(.update_all, "*", childUpdateAll, .{ s.gpa, s.base_url, s.entries() }) catch |err| {
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

/// The system offered as an update (os.json, beside the apps' catalogue:
/// see `fetchOs`), once downloaded: kept in `os_manifest_file`.
pub const os_manifest_file = sys.system.update_dir ++ "/os.json";

pub const OsManifest = struct {
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

    pub fn parse(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(OsManifest) {
        const parsed = std.json.parseFromSlice(OsManifest, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadManifest;
        errdefer parsed.deinit();
        const m = parsed.value;
        if (sys.system.Version.init(m.time, m.version) == null or !(std.mem.endsWith(u8, m.file, ".tar.xz") and validName(m.file[0 .. m.file.len - ".tar.xz".len])) or m.sha256.len != 64) return error.BadManifest;
        return parsed;
    }

    pub fn versionOf(m: *const OsManifest) sys.system.Version {
        return sys.system.Version.init(m.time, m.version).?;
    }
};

/// Whether `m` should be offered: newer than the running system, and in
/// neither slot.
pub fn osOffered(m: *const OsManifest, running: sys.system.Version, report: ?*const sys.system.Report) bool {
    const v = m.versionOf();
    if (v.time <= running.time or v.eql(&running)) return false;
    if (report) |r| if (r.holds(&v)) return false;
    return true;
}

/// The running system's version: the running slot's (with its kernel's
/// commit and time), as the system manager says in `report`; else `built`,
/// the one the program was built with.
pub fn runningVersion(report: ?*const sys.system.Report, built: sys.system.Version) sys.system.Version {
    const r = report orelse return built;
    const s = r.slot orelse return built;
    return if (r.version(s)) |v| v.* else built;
}

/// The system update downloaded last (`os_manifest_file`), if there is
/// one that reads well.
pub fn loadOsManifest(gpa: std.mem.Allocator) ?std.json.Parsed(OsManifest) {
    const json = sys.readFileAlloc(gpa, os_manifest_file, 64 * 1024) catch return null;
    defer gpa.free(json);
    return OsManifest.parse(gpa, json) catch null;
}

const testing = std.testing;

test "language packs come after the apps, apart from them" {
    const c = try parseCatalogue(testing.allocator,
        \\{"version": "abc", "apps": [
        \\  {"name": "dazzle-language-ja", "title": "Japanese", "file": "dazzle-language-ja.tar.xz", "size": 10, "sha256": "00", "language": "ja"},
        \\  {"name": "dazzle-demo", "title": "Demo", "file": "dazzle-demo.tar.xz", "size": 10, "sha256": "00"}]}
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.value.n_apps);
    try testing.expectEqualStrings("dazzle-demo", c.value.apps[0].name);
    try testing.expectEqualStrings("dazzle-language-ja", languagePackIn(c.value, "ja").?.name);
    try testing.expect(languagePackIn(c.value, "zh") == null);
}

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

test "a download is checked against the catalogue and its Ed25519 signature" {
    const sig = signHex(fixture, default_seed);
    var signed = fixture_app;
    signed.signature = &sig;
    try verifyWithKeys(fixture, signed, &.{});

    var wrong = signed;
    wrong.size += 1;
    try testing.expectError(error.WrongSize, verifyWithKeys(fixture, wrong, &.{}));
    wrong = signed;
    wrong.sha256 = &@as([64]u8, @splat('0'));
    try testing.expectError(error.WrongChecksum, verifyWithKeys(fixture, wrong, &.{}));

    // Missing or tampered signature is rejected.
    try testing.expectError(error.BadSignature, verifyWithKeys(fixture, fixture_app, &.{}));
    wrong = signed;
    wrong.signature = &@as([128]u8, @splat('0'));
    try testing.expectError(error.BadSignature, verifyWithKeys(fixture, wrong, &.{}));

    // Signed with another key: rejected until that key is subscribed.
    const other_seed: [32]u8 = "custom-third-party-signing-seed!".*;
    const other_kp = Ed25519.KeyPair.generateDeterministic(other_seed) catch unreachable;
    const other_pub_bytes = other_kp.public_key.toBytes();
    var other_pub_hex: [key_hex_len]u8 = undefined;
    _ = std.fmt.bufPrint(&other_pub_hex, "{x}", .{&other_pub_bytes}) catch unreachable;
    const other_sig = signHex(fixture, other_seed);
    var third_party = fixture_app;
    third_party.signature = &other_sig;
    try testing.expectError(error.BadSignature, verifyWithKeys(fixture, third_party, &.{}));

    var keys_path_buf: [64]u8 = undefined;
    const keys_path = try std.mem.printSentinel(&keys_path_buf, "/tmp/dazzle-keys-test-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(keys_path);

    try testing.expect(!subscribeKeyAt(keys_path, "not-a-valid-key"));
    // Weak (small-order torsion) Ed25519 public keys are rejected:
    // 00..00 (order 4) and 0100..00 (the identity point, order 1).
    try testing.expect(!subscribeKeyAt(keys_path, &@as([64]u8, @splat('0'))));
    try testing.expect(!subscribeKeyAt(keys_path, "01" ++ &@as([62]u8, @splat('0'))));
    try testing.expect(subscribeKeyAt(keys_path, &other_pub_hex));
    const loaded = loadKeysFrom(keys_path);
    try testing.expectEqual(@as(usize, 1), loaded.len);
    try verifyWithKeys(fixture, third_party, loaded.slice());

    unsubscribeKeyAt(keys_path, &other_pub_hex);
    try testing.expectEqual(@as(usize, 0), loadKeysFrom(keys_path).len);
}

test "installing unpacks the app's folder into place, again replaces it, removing deletes it" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-store-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    try unpack(testing.allocator, fixture, dir, "hello");
    try testing.expect(isInstalled(dir, "hello"));
    var buf: [128]u8 = undefined;
    const icon = try std.mem.printSentinel(&buf, "{s}/hello/hello.icon", .{dir}, 0);
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
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-keepalive-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var os_dir_buf: [80]u8 = undefined;
    var apps_dir_buf: [80]u8 = undefined;
    const os_dir = try std.mem.printSentinel(&os_dir_buf, "{s}/update", .{dir}, 0);
    const app_dir = try std.mem.printSentinel(&apps_dir_buf, "{s}/apps", .{dir}, 0);
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
    const os_icon = try std.mem.printSentinel(&path_buf, "{s}/icon.png", .{os_dir}, 0);
    try testing.expectEqualStrings(png_64 ++ "OS", sys.readFile(os_icon, &read_buf).?);
    const demo_icon = try std.mem.printSentinel(&path_buf, "{s}/.icons/dazzle-demo.png", .{app_dir}, 0);
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
    const path = try std.mem.printSentinel(&path_buf, "/tmp/dazzle-server-test-{d}", .{linux.getpid()}, 0);
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
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-https-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var os_dir_buf: [80]u8 = undefined;
    var apps_dir_buf: [80]u8 = undefined;
    const os_dir = try std.mem.printSentinel(&os_dir_buf, "{s}/update", .{dir}, 0);
    const app_dir = try std.mem.printSentinel(&apps_dir_buf, "{s}/apps", .{dir}, 0);
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
    const os_icon = try std.mem.printSentinel(&path_buf, "{s}/icon.png", .{os_dir}, 0);
    try testing.expectEqualStrings(png_64 ++ "TLS-OS", sys.readFile(os_icon, &read_buf).?);
    const demo_icon = try std.mem.printSentinel(&path_buf, "{s}/.icons/dazzle-demo.png", .{app_dir}, 0);
    try testing.expectEqualStrings(png_64 ++ "TLS-DEMO", sys.readFile(demo_icon, &read_buf).?);
}

test "an update is offered when it is newer and in neither slot" {
    const json =
        \\{"version": "0123abc", "time": 1791400000, "file": "dazzle-os.tar.xz", "size": 4000000,
        \\ "sha256": "f3e817e51826f4ca7b7d334af8f857d9c42416073f44c7429e1bfda7f097a753"}
    ;
    const parsed = try OsManifest.parse(testing.allocator, json);
    defer parsed.deinit();
    const m = &parsed.value;
    const running = sys.system.Version.init(1791331200, "de14aa2").?;
    try testing.expect(osOffered(m, running, null));
    // Older or the same: not.
    try testing.expect(!osOffered(m, sys.system.Version.init(1791500000, "fffffff").?, null));
    try testing.expect(!osOffered(m, sys.system.Version.init(1791400000, "0123abc").?, null));
    // Already in the other slot (downloaded before): not.
    var report: sys.system.Report = .{ .slot = 'a', .next = 'a', .versions = .{ running, sys.system.Version.init(1791400000, "0123abc").? } };
    try testing.expect(!osOffered(m, running, &report));
    report.versions[1] = sys.system.Version.init(1791000000, "0000aaa").?;
    try testing.expect(osOffered(m, running, &report));

    // Manifests that are not right.
    try testing.expectError(error.BadManifest, OsManifest.parse(testing.allocator, "{\"version\": \"x y\", \"time\": 1, \"file\": \"a.tar.xz\", \"size\": 1, \"sha256\": \"" ++ &@as([64]u8, @splat('0')) ++ "\"}"));
    try testing.expectError(error.BadManifest, OsManifest.parse(testing.allocator, "{\"version\": \"abc\", \"time\": 1, \"file\": \"../a\", \"size\": 1, \"sha256\": \"" ++ &@as([64]u8, @splat('0')) ++ "\"}"));
    try testing.expectError(error.BadManifest, OsManifest.parse(testing.allocator, "[]"));
}

test "installed apps the catalogue does not have are listed, with titles from their names" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-installed-only-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ "dazzle-kete-demo", "dazzle-files", "notes" }) |name| {
        _ = linux.mkdir(try std.mem.printSentinel(&buf, "{s}/{s}", .{ dir, name }, 0), 0o755);
        const program = try std.mem.printSentinel(&buf, "{s}/{s}/{s}", .{ dir, name, name }, 0);
        try sys.files.writeNew(program, "");
        _ = linux.chmod(program, 0o755);
    }
    // A folder with no program is not an app.
    _ = linux.mkdir(try std.mem.printSentinel(&buf, "{s}/empty", .{dir}, 0), 0o755);
    const catalogue = [_]App{.{ .name = "dazzle-files", .title = "Files", .file = "dazzle-files.tar.xz", .size = 1, .sha256 = "" }};
    const extra = try installedOnly(testing.allocator, dir, &catalogue);
    defer freeInstalledOnly(testing.allocator, extra);
    try testing.expectEqual(@as(usize, 2), extra.len);
    try testing.expectEqualStrings("dazzle-kete-demo", extra[0].name);
    try testing.expectEqualStrings("Kete Demo", extra[0].title);
    try testing.expectEqualStrings("Notes", extra[1].title);
}
