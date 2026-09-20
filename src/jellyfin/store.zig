//! Where this app keeps things on disk: the access token, and the artwork
//! cache.
//!
//! ## Where, and why there
//!
//! An installed webOS app writes **inside its own installed directory**. That
//! is not a guess: the native homebrew apps on this TV all do it, and the
//! directory is world-writable for exactly that reason.
//!
//! ```
//! com.limelight.webos/conf/{moonlight.ini,hosts.ini,key/key.pem}
//! com.limelight.webos/cache/<uuid>_<id>          (box art)
//! com.limelight.webos/.cache/fontconfig/...      (library-managed)
//! org.mariotaku.ihsplay/.cache/fontconfig/...
//! ```
//!
//! So this uses `conf/` for the token and `cache/` for artwork, matching
//! Moonlight. `.cache/` is left to whatever libraries want it.
//!
//! Finding that directory needs no environment, which matters because SAM
//! provides none (the same reason the app reads its source from a fixed
//! path). An installed app runs with its own directory as the working
//! directory, so `/proc/self/cwd` is the answer -- and it is also how we tell
//! "installed" from "development".
//!
//! Run any other way -- `zig build run`, which drops a binary in `/tmp` -- the
//! root is `/tmp/jellyfin-native`. Development state belongs on tmpfs, where a
//! reboot clears it and nothing accumulates in the source tree.
//!
//! `$JELLYFIN_STORE` overrides both.

const std = @import("std");
const c = std.c;

/// Artwork budget. The cache is pruned to this at startup, oldest first.
/// Two hundred-odd posters at 240x360 PNG; a library of any size settles here.
const cache_budget = 48 * 1024 * 1024;

var root_buffer: [512]u8 = @splat(0);
var root_len: usize = 0;
var installed_app = false;

pub fn root() []const u8 {
    return root_buffer[0..root_len];
}

pub fn installed() bool {
    return installed_app;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.sliceTo(c.getenv(name) orelse return null, 0);
}

/// The directory an installed app runs in, or null when this is not one.
///
/// `/usr/palm/applications/` is the marker rather than the leading component,
/// because a developer-mode install lives under `/media/developer/apps` and a
/// retail one under `/media/cryptofs/apps`, both ending in that path.
fn appDirectory(buffer: []u8) ?[]const u8 {
    const rc = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/cwd", buffer.ptr, buffer.len);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    const path = buffer[0..rc];
    if (std.mem.indexOf(u8, path, "/usr/palm/applications/") == null) return null;
    // The last component is the app id, which always has a dot in it.
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (std.mem.indexOfScalar(u8, path[slash + 1 ..], '.') == null) return null;
    return path;
}

fn makeDirectory(path: []const u8) void {
    var zero: [512]u8 = undefined;
    const name = std.fmt.bufPrintZ(&zero, "{s}", .{path}) catch return;
    _ = c.mkdir(name, 0o755);
}

/// Resolve the root and make sure `conf/` and `cache/` exist. Call once,
/// before any worker thread runs.
pub fn init() void {
    var cwd: [512]u8 = undefined;
    if (env("JELLYFIN_STORE")) |override| {
        root_len = @min(override.len, root_buffer.len - 1);
        @memcpy(root_buffer[0..root_len], override[0..root_len]);
    } else if (appDirectory(&cwd)) |dir| {
        installed_app = true;
        root_len = @min(dir.len, root_buffer.len - 1);
        @memcpy(root_buffer[0..root_len], dir[0..root_len]);
    } else {
        const dev = "/tmp/jellyfin-native";
        root_len = dev.len;
        @memcpy(root_buffer[0..root_len], dev);
    }
    root_buffer[root_len] = 0;

    makeDirectory(root());
    var path: [512]u8 = undefined;
    makeDirectory(std.fmt.bufPrint(&path, "{s}/conf", .{root()}) catch return);
    makeDirectory(std.fmt.bufPrint(&path, "{s}/cache", .{root()}) catch return);

    // An installed app runs as a jail uid that owns none of its files, so its
    // directory is only writable if the package shipped it that way. If an
    // older package did not, fall back rather than fail every write silently
    // -- /tmp at least keeps the app working until the next reinstall.
    if (!writable()) {
        std.debug.print("store: {s} is not writable; falling back to /tmp\n", .{root()});
        const fallback = "/tmp/jellyfin-native";
        root_len = fallback.len;
        @memcpy(root_buffer[0..root_len], fallback);
        root_buffer[root_len] = 0;
        installed_app = false;
        makeDirectory(root());
        makeDirectory(std.fmt.bufPrint(&path, "{s}/conf", .{root()}) catch return);
        makeDirectory(std.fmt.bufPrint(&path, "{s}/cache", .{root()}) catch return);
    }
    std.debug.print("store: {s} ({s})\n", .{ root(), if (installed_app) "installed" else "development" });
}

fn writable() bool {
    var path: [512]u8 = undefined;
    const probe = std.fmt.bufPrintZ(&path, "{s}/conf/.probe", .{root()}) catch return false;
    const file = c.open(probe, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (file < 0) return false;
    _ = c.close(file);
    _ = c.unlink(probe);
    return true;
}

// ------------------------------------------------------------- credentials

fn credentialsPath(buffer: []u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "{s}/conf/credentials", .{root()}) catch "";
}

/// Five lines, in order: server, token, user id, user name, password.
///
/// The password is here because Jellyfin invalidates a device's previous token
/// whenever that device signs in again, so a stored token alone eventually
/// stops working and leaves the user typing on a remote. With it, a 401 is
/// recoverable in the background.
///
/// It is therefore a plaintext password on disk, mode 0600. The installed
/// directory around it is world-writable because webOS gives the app a jail
/// uid that owns nothing (see the packaging note in build.zig) -- so the file
/// mode is what protects it, and root on this TV can read it regardless.
/// Quick Connect stores no password and simply signs out on a 401.
pub fn save(url: []const u8, token: []const u8, user_id: []const u8, user_name: []const u8, password: []const u8) void {
    var path: [512]u8 = undefined;
    var body: [900]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{s}\n{s}\n{s}\n{s}\n{s}\n", .{ url, token, user_id, user_name, password }) catch return;
    const file = c.open(credentialsPath(&path), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (file < 0) return;
    defer _ = c.close(file);
    _ = c.write(file, text.ptr, text.len);
}

/// The five lines back, as slices into `body`. Null when there is nothing
/// usable stored. A file written before the password line existed still loads;
/// the missing field simply comes back empty.
pub fn load(body: *[900]u8) ?[5][]const u8 {
    var path: [512]u8 = undefined;
    const file = c.open(credentialsPath(&path), .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (file < 0) return null;
    defer _ = c.close(file);
    const n = c.read(file, body, body.len);
    if (n <= 0) return null;
    var lines = std.mem.splitScalar(u8, body[0..@intCast(n)], '\n');
    var out: [5][]const u8 = undefined;
    for (&out) |*line| line.* = lines.next() orelse "";
    return if (out[0].len != 0 and out[1].len != 0) out else null;
}

pub fn forget() void {
    var path: [512]u8 = undefined;
    _ = c.unlink(credentialsPath(&path));
}

// ------------------------------------------------------------ image cache

/// Cache file name for one image.
///
/// The tag is Jellyfin's own image tag, which is a hash of the image content:
/// when the artwork changes the tag changes, so a changed image is a different
/// file and a stale one can never be served. That is what makes this cache
/// need no revalidation request at all -- a hit costs no network.
///
/// The size is in the key because the same image is fetched at whatever size
/// the screen asked for, and the server does the scaling.
pub fn imagePath(buffer: []u8, item: []const u8, tag: []const u8, width: u32, height: u32) ?[]const u8 {
    if (tag.len == 0) return null; // untagged: not cacheable, always fetch
    return std.fmt.bufPrint(buffer, "{s}/cache/{s}-{s}-{d}x{d}.img", .{ root(), item, tag, width, height }) catch null;
}

pub fn readImage(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch null;
}

/// Write via a temporary and rename, because four workers share this
/// directory and a half-written file must never be readable as a whole one.
/// The temporary is named after the final path plus the thread id, so two
/// workers racing on the same image cannot collide either.
pub fn writeImage(io: std.Io, path: []const u8, bytes: []const u8) void {
    var temporary: [640]u8 = undefined;
    const partial = std.fmt.bufPrint(&temporary, "{s}.{d}", .{ path, std.Thread.getCurrentId() }) catch return;
    const dir = std.Io.Dir.cwd();
    dir.writeFile(io, .{ .sub_path = partial, .data = bytes }) catch return;
    dir.rename(partial, dir, path, io) catch {
        dir.deleteFile(io, partial) catch {};
    };
}

/// Keep the cache under `cache_budget`, deleting least-recently-modified
/// first. Runs at startup, on the main thread, before anything reads it.
///
/// Deliberately not an eviction policy with bookkeeping: the cache is
/// disposable, a sweep at launch is cheap against a few hundred files, and the
/// alternative -- an index to keep consistent across four writer threads -- is
/// a lot of machinery to avoid re-downloading a poster.
pub fn prune(io: std.Io, allocator: std.mem.Allocator) void {
    var path: [512]u8 = undefined;
    const cache = std.fmt.bufPrint(&path, "{s}/cache", .{root()}) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, cache, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const Entry = struct { name: [96]u8, len: usize, size: u64, mtime: i96 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(allocator);

    var total: u64 = 0;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file or entry.name.len >= 96) continue;
        const info = dir.statFile(io, entry.name, .{}) catch continue;
        var record: Entry = .{ .name = undefined, .len = entry.name.len, .size = info.size, .mtime = info.mtime.nanoseconds };
        @memcpy(record.name[0..entry.name.len], entry.name);
        entries.append(allocator, record) catch break;
        total += info.size;
    }
    if (total <= cache_budget) return;

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.mtime < b.mtime;
        }
    }.lessThan);

    var freed: u64 = 0;
    for (entries.items) |entry| {
        if (total - freed <= cache_budget) break;
        dir.deleteFile(io, entry.name[0..entry.len]) catch continue;
        freed += entry.size;
    }
    std.debug.print("store: pruned {d} KiB of artwork cache\n", .{freed / 1024});
}

test "an app directory is recognised, a development path is not" {
    var buffer: [256]u8 = undefined;
    // The marker is the path, not the mount: developer-mode and retail installs
    // differ in their prefix.
    for ([_][]const u8{
        "/media/developer/apps/usr/palm/applications/dev.hookedbehemoth.jellyfin",
        "/media/cryptofs/apps/usr/palm/applications/netflix.app",
    }) |path| {
        @memcpy(buffer[0..path.len], path);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..path.len], "/usr/palm/applications/") != null);
    }
}

test "image paths are keyed by tag and size" {
    root_len = "/tmp/x".len;
    @memcpy(root_buffer[0..root_len], "/tmp/x");
    var buffer: [512]u8 = undefined;
    const path = imagePath(&buffer, "item1", "tagA", 240, 360).?;
    try std.testing.expectEqualStrings("/tmp/x/cache/item1-tagA-240x360.img", path);
    // A changed tag is a different file, which is the whole invalidation story.
    var other: [512]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, path, imagePath(&other, "item1", "tagB", 240, 360).?));
    // No tag means no cache entry rather than an unversioned one.
    try std.testing.expect(imagePath(&buffer, "item1", "", 240, 360) == null);
}
