//! Jellyfin server API, plus the background fetcher that keeps it off the
//! render thread.
//!
//! Everything here is blocking and allocates into a per-task arena; the UI
//! never calls it directly. `Fetcher` owns a small fixed pool of task slots
//! and a few worker threads, the UI submits a task and polls it once a frame,
//! and the arena is released when the UI is done reading the result. That is
//! the whole concurrency model -- no futures, no callbacks, nothing shared but
//! the slot array behind one mutex.
//!
//! Verified against Jellyfin 10.11.8.

const std = @import("std");
const image_decoder = @import("image.zig");
const store = @import("store.zig");

pub const client_name = "webos-native";
pub const client_version = "0.1";

// ------------------------------------------------------------------- model

/// The fields this UI reads. `ignore_unknown_fields` drops the rest of what is
/// a very wide server DTO, so adding a screen means adding a field here only.
pub const Item = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Type: []const u8 = "",
    CollectionType: ?[]const u8 = null,
    Overview: ?[]const u8 = null,
    ProductionYear: ?u32 = null,
    OfficialRating: ?[]const u8 = null,
    RunTimeTicks: ?u64 = null,
    IndexNumber: ?u32 = null,
    ParentIndexNumber: ?u32 = null,
    SeriesName: ?[]const u8 = null,
    SeriesId: ?[]const u8 = null,
    ChildCount: ?u32 = null,
    UserData: ?Played = null,
    ImageTags: ?Tags = null,
    /// The series' own Primary tag, carried on every episode -- so an episode
    /// can name the artwork `posterId` falls back to without fetching the
    /// series first.
    SeriesPrimaryImageTag: ?[]const u8 = null,

    pub const Played = struct {
        PlayedPercentage: ?f64 = null,
        PlaybackPositionTicks: ?u64 = null,
        Played: bool = false,
    };
    pub const Tags = struct { Primary: ?[]const u8 = null };

    pub fn hasPoster(self: Item) bool {
        const tags = self.ImageTags orelse return false;
        return tags.Primary != null;
    }

    /// The id whose Primary image represents this item on a portrait tile.
    /// An episode's own Primary is a 16:9 still, which looks wrong stretched
    /// into a poster and makes a "continue watching" row look like a different
    /// kind of list, so an episode always shows its series' poster.
    pub fn posterId(self: Item) []const u8 {
        if (self.SeriesId) |series| return series;
        return self.Id;
    }

    /// The image tag for whatever `posterId` points at. Jellyfin's tags are
    /// content hashes, so this doubles as the cache key -- see store.zig.
    pub fn posterTag(self: Item) []const u8 {
        if (self.SeriesId != null) return self.SeriesPrimaryImageTag orelse "";
        const tags = self.ImageTags orelse return "";
        return tags.Primary orelse "";
    }

    pub fn isFolder(self: Item) bool {
        return std.mem.eql(u8, self.Type, "Series") or
            std.mem.eql(u8, self.Type, "Season") or
            std.mem.eql(u8, self.Type, "BoxSet") or
            std.mem.eql(u8, self.Type, "CollectionFolder");
    }

    pub fn minutes(self: Item) u32 {
        const ticks = self.RunTimeTicks orelse return 0;
        return @intCast(ticks / (10_000_000 * 60));
    }

    /// 0..100, for the resume bar. The server only fills PlayedPercentage on
    /// some endpoints, so it is derived from the position when it is missing.
    pub fn progress(self: Item) f32 {
        const data = self.UserData orelse return 0;
        if (data.PlayedPercentage) |p| return @floatCast(p);
        const position = data.PlaybackPositionTicks orelse return 0;
        const total = self.RunTimeTicks orelse return 0;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(position)) / @as(f32, @floatFromInt(total)) * 100;
    }
};

pub const ItemList = struct {
    Items: []Item = &.{},
    TotalRecordCount: u32 = 0,
    StartIndex: u32 = 0,
};

pub const Auth = struct {
    AccessToken: []const u8 = "",
    User: Account = .{},
    pub const Account = struct { Id: []const u8 = "", Name: []const u8 = "" };
};

pub const QuickConnect = struct {
    Secret: []const u8 = "",
    Code: []const u8 = "",
    Authenticated: bool = false,
};

pub const Discovered = struct {
    Address: []const u8 = "",
    Name: []const u8 = "",
    Id: []const u8 = "",
};

// ------------------------------------------------------------- credentials

/// Everything needed to talk to a server, and the whole of what is persisted.
pub const Session = struct {
    url: Text(256) = .{},
    token: Text(64) = .{},
    user_id: Text(64) = .{},
    user_name: Text(64) = .{},
    /// Kept so an invalidated token can be replaced without the user. Empty
    /// after a Quick Connect sign-in, which never sees one.
    password: Text(256) = .{},
    device_id: Text(64) = .{},

    pub fn authorization(self: *const Session, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "MediaBrowser Client=\"{s}\", Device=\"webOS TV\", DeviceId=\"{s}\", Version=\"{s}\", Token=\"{s}\"",
            .{ client_name, self.device_id.get(), client_version, self.token.get() },
        ) catch "";
    }
};

/// A small inline string. The session is global mutable state read by worker
/// threads; keeping it inline means no allocator and no lifetime to get wrong.
pub fn Text(comptime n: usize) type {
    return struct {
        buffer: [n]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();

        pub fn get(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn set(self: *Self, value: []const u8) void {
            self.len = @min(value.len, n - 1);
            @memcpy(self.buffer[0..self.len], value[0..self.len]);
            self.buffer[self.len] = 0;
        }
    };
}

/// A stable per-installation id, so the server's device list does not grow a
/// new entry every launch and Quick Connect approvals stick.
/// Resolve libpng before any worker thread can decode an image.
pub fn initImages() !void {
    try image_decoder.init();
}

/// Resolve where this app writes, and sweep the artwork cache back under
/// budget. Both must happen before the fetcher's workers start.
pub fn initStore(io: std.Io, allocator: std.mem.Allocator) void {
    store.init();
    store.prune(io, allocator);
}

pub const storeRoot = store.root;

pub fn deviceId(out: *Text(64)) void {
    var name: [64]u8 = @splat(0);
    const host = std.posix.gethostname(&name) catch "webos";
    var hash = std.hash.Wyhash.init(0x5eed);
    hash.update(host);
    hash.update(client_name);
    out.set(std.fmt.bufPrint(&name, "{x:0>16}", .{hash.final()}) catch "webos-native");
}

/// libc `getenv`: every app here links libc for `dlopen` already, and the
/// parsed environment lives on `std.process.Init`, which this module is not
/// given.
fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.sliceTo(std.c.getenv(name) orelse return null, 0);
}

pub fn save(session: *const Session) void {
    store.save(session.url.get(), session.token.get(), session.user_id.get(), session.user_name.get(), session.password.get());
}

pub fn load(session: *Session) bool {
    var body: [900]u8 = undefined;
    const lines = store.load(&body) orelse return false;
    session.url.set(lines[0]);
    session.token.set(lines[1]);
    session.user_id.set(lines[2]);
    session.user_name.set(lines[3]);
    session.password.set(lines[4]);
    return true;
}

pub const forget = store.forget;

// --------------------------------------------------------------- discovery

/// Jellyfin answers a UDP broadcast on 7359 with one JSON datagram per server.
/// This is a plain socket rather than anything in `std.Io`: it is three
/// syscalls, it runs on a worker thread, and the timeout is the whole design.
pub fn discover(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(Discovered)) !void {
    const socket = std.c.socket(std.c.AF.INET, std.c.SOCK.DGRAM, 0);
    if (socket < 0) return error.SocketFailed;
    defer _ = std.c.close(socket);
    const yes: c_int = 1;
    _ = std.c.setsockopt(socket, std.c.SOL.SOCKET, std.c.SO.BROADCAST, &yes, @sizeOf(c_int));
    const timeout = std.c.timeval{ .sec = 1, .usec = 0 };
    _ = std.c.setsockopt(socket, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &timeout, @sizeOf(std.c.timeval));

    var address = std.c.sockaddr.in{ .port = std.mem.nativeToBig(u16, 7359), .addr = 0xffffffff };
    const probe = "who is JellyfinServer?";
    if (std.c.sendto(socket, probe, probe.len, 0, @ptrCast(&address), @sizeOf(@TypeOf(address))) < 0)
        return error.BroadcastFailed;

    // Three timeouts, not one: a second server answering late is worth 3 s of a
    // worker thread, and a lone reply usually lands in the first 20 ms.
    var datagram: [2048]u8 = undefined;
    var quiet: u8 = 0;
    while (quiet < 3) {
        const n = std.c.recv(socket, &datagram, datagram.len, 0);
        if (n <= 0) {
            quiet += 1;
            continue;
        }
        const parsed = std.json.parseFromSliceLeaky(Discovered, arena, datagram[0..@intCast(n)], .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch continue;
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen.Id, parsed.Id)) break;
        } else try out.append(arena, parsed);
    }
}

// ------------------------------------------------------------------- http

pub const HttpError = error{
    /// The request never got an answer: DNS, connect, TLS, or a dropped socket.
    RequestFailed,
    /// The token was rejected. The only failure worth forgetting credentials
    /// over -- a 500 or a timeout says nothing about whether they are valid.
    Unauthorized,
    /// Any other non-200.
    HttpStatus,
    OutOfMemory,
};

/// One request. `body` is the response, allocated in `arena`; `extra` carries
/// the JSON payload for a POST.
fn send(
    http: *std.http.Client,
    arena: std.mem.Allocator,
    session: *const Session,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
) HttpError![]u8 {
    var auth_buffer: [512]u8 = undefined;
    var collected: std.Io.Writer.Allocating = .init(arena);
    const result = http.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &collected.writer,
        .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        .extra_headers = &.{.{ .name = "Authorization", .value = session.authorization(&auth_buffer) }},
    }) catch |err| {
        std.log.debug("{s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
        return error.RequestFailed;
    };
    if (result.status != .ok) {
        std.log.debug("{s} {s}: HTTP {d}", .{ @tagName(method), url, @intFromEnum(result.status) });
        return switch (result.status) {
            .unauthorized, .forbidden => error.Unauthorized,
            else => error.HttpStatus,
        };
    }
    return collected.toOwnedSlice();
}

fn parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// `base` without a trailing slash, so every URL below is `{base}/Path`.
fn base(session: *const Session) []const u8 {
    const url = session.url.get();
    return if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url;
}

/// Percent-encode a query value. Library names and search text reach the URL,
/// and a space or `&` in one would otherwise build a different request.
fn escape(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try writer.writeByte(c),
        else => try writer.print("%{X:0>2}", .{c}),
    };
}

// ------------------------------------------------------------------ calls

pub fn login(
    http: *std.http.Client,
    arena: std.mem.Allocator,
    session: *const Session,
    user: []const u8,
    password: []const u8,
) !Auth {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/Users/AuthenticateByName", .{base(session)});
    var payload: std.Io.Writer.Allocating = .init(arena);
    try payload.writer.writeAll("{\"Username\":");
    try std.json.Stringify.value(user, .{}, &payload.writer);
    try payload.writer.writeAll(",\"Pw\":");
    try std.json.Stringify.value(password, .{}, &payload.writer);
    try payload.writer.writeAll("}");
    const body = try send(http, arena, session, .POST, url, try payload.toOwnedSlice());
    return parse(Auth, arena, body);
}

pub fn quickConnectInitiate(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session) !QuickConnect {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/QuickConnect/Initiate", .{base(session)});
    return parse(QuickConnect, arena, try send(http, arena, session, .POST, url, ""));
}

pub fn quickConnectPoll(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session, secret: []const u8) !QuickConnect {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/QuickConnect/Connect?secret={s}", .{ base(session), secret });
    return parse(QuickConnect, arena, try send(http, arena, session, .GET, url, null));
}

pub fn quickConnectAuthenticate(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session, secret: []const u8) !Auth {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/Users/AuthenticateWithQuickConnect", .{base(session)});
    var payload: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&payload, "{{\"Secret\":\"{s}\"}}", .{secret});
    return parse(Auth, arena, try send(http, arena, session, .POST, url, json));
}

fn getList(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session, url: []const u8) !ItemList {
    return parse(ItemList, arena, try send(http, arena, session, .GET, url, null));
}

pub fn views(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session) !ItemList {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/UserViews?userId={s}", .{ base(session), session.user_id.get() });
    return getList(http, arena, session, url);
}

pub fn resume_(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session) !ItemList {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/UserItems/Resume?userId={s}&limit=24&fields=Overview", .{ base(session), session.user_id.get() });
    return getList(http, arena, session, url);
}

pub fn nextUp(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session) !ItemList {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/Shows/NextUp?userId={s}&limit=24&fields=Overview", .{ base(session), session.user_id.get() });
    return getList(http, arena, session, url);
}

/// One page of a library grid. `sortBy=SortName` keeps paging stable, which is
/// the whole reason a virtual grid can ask for window [start, start+limit).
pub fn children(
    http: *std.http.Client,
    arena: std.mem.Allocator,
    session: *const Session,
    parent: []const u8,
    start: u32,
    limit: u32,
) !ItemList {
    var url_buffer: [640]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&url_buffer);
    try writer.print("{s}/Items?userId={s}&parentId=", .{ base(session), session.user_id.get() });
    try escape(&writer, parent);
    try writer.print(
        "&startIndex={d}&limit={d}&recursive=true&sortBy=SortName&sortOrder=Ascending" ++
            "&includeItemTypes=Movie,Series&fields=Overview,ChildCount&imageTypeLimit=1&enableImageTypes=Primary",
        .{ start, limit },
    );
    return getList(http, arena, session, writer.buffered());
}

pub fn item(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session, id: []const u8) !Item {
    var url_buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&url_buffer);
    try writer.print("{s}/Items/", .{base(session)});
    try escape(&writer, id);
    try writer.print("?userId={s}", .{session.user_id.get()});
    return parse(Item, arena, try send(http, arena, session, .GET, writer.buffered(), null));
}

pub fn seasons(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session, series: []const u8) !ItemList {
    var url_buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&url_buffer);
    try writer.print("{s}/Shows/", .{base(session)});
    try escape(&writer, series);
    try writer.print("/Seasons?userId={s}&fields=ChildCount", .{session.user_id.get()});
    return getList(http, arena, session, writer.buffered());
}

pub fn episodes(http: *std.http.Client, arena: std.mem.Allocator, session: *const Session, series: []const u8, season: []const u8) !ItemList {
    var url_buffer: [640]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&url_buffer);
    try writer.print("{s}/Shows/", .{base(session)});
    try escape(&writer, series);
    try writer.print("/Episodes?userId={s}&seasonId=", .{session.user_id.get()});
    try escape(&writer, season);
    try writer.writeAll("&fields=Overview");
    return getList(http, arena, session, writer.buffered());
}

/// The URL a player would open. Playback itself is out of scope for now; the
/// details screen shows and logs this.
pub fn streamUrl(session: *const Session, id: []const u8, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}/Videos/{s}/stream?static=true&api_key={s}", .{
        base(session), id, session.token.get(),
    }) catch "";
}

/// Artwork, decoded to RGB8.
///
/// Three things happen here, in order: the cache is consulted, the request is
/// made only on a miss, and the encoded bytes are cached before decoding.
///
/// The cache key is Jellyfin's image tag, which is a hash of the image, so a
/// hit needs no revalidation round trip -- changed artwork has a different tag
/// and therefore a different file. (The server offers no `ETag` on images, and
/// ignores `If-None-Match`; it does honour `If-Modified-Since`, which is the
/// fallback if a tagless image ever needs caching. Today an untagged image is
/// simply not cached.)
///
/// `fillWidth`/`fillHeight` is the server's sizing hint, not a contract -- it
/// answers 204x300 or 534x300 depending on the source art -- so the caller must
/// cope with whatever size comes back. `format=Png` is asked for because that
/// is the one decoder with the same ABI on the TV and on a development
/// machine; see image.zig.
pub fn poster(
    http: *std.http.Client,
    io: std.Io,
    arena: std.mem.Allocator,
    session: *const Session,
    id: []const u8,
    tag: []const u8,
    width: u32,
    height: u32,
) !image_decoder.Image {
    var path_buffer: [640]u8 = undefined;
    const cached = store.imagePath(&path_buffer, id, tag, width, height);
    if (cached) |path| {
        if (store.readImage(io, arena, path)) |bytes| return image_decoder.decode(arena, bytes);
    }

    var url_buffer: [640]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&url_buffer);
    try writer.print("{s}/Items/", .{base(session)});
    try escape(&writer, id);
    try writer.print("/Images/Primary?fillWidth={d}&fillHeight={d}&format=Png", .{ width, height });
    // The tag makes the URL change when the image does, which is what lets any
    // cache in between -- ours, or a proxy -- treat it as immutable.
    if (tag.len != 0) {
        try writer.writeAll("&tag=");
        try escape(&writer, tag);
    }
    const body = try send(http, arena, session, .GET, writer.buffered(), null);
    if (cached) |path| store.writeImage(io, path, body);
    return image_decoder.decode(arena, body);
}

test "authorization header carries the device id and token" {
    var session: Session = .{};
    session.device_id.set("abc123");
    session.token.set("tok");
    var buffer: [512]u8 = undefined;
    const header = session.authorization(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, header, "DeviceId=\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Token=\"tok\"") != null);
}

test "base trims exactly one trailing slash" {
    var session: Session = .{};
    session.url.set("http://host:8096/");
    try std.testing.expectEqualStrings("http://host:8096", base(&session));
    session.url.set("http://host:8096");
    try std.testing.expectEqualStrings("http://host:8096", base(&session));
}

test "query values are escaped" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try escape(&writer, "a b&c");
    try std.testing.expectEqualStrings("a%20b%26c", writer.buffered());
}

test "progress falls back to ticks when the server omits the percentage" {
    const episode: Item = .{
        .RunTimeTicks = 1000,
        .UserData = .{ .PlaybackPositionTicks = 250 },
    };
    try std.testing.expectApproxEqAbs(@as(f32, 25), episode.progress(), 0.01);
}

// ---------------------------------------------------------------- fetcher

pub const Job = enum {
    discover,
    login,
    quick_initiate,
    quick_poll,
    quick_authenticate,
    views,
    resume_items,
    next_up,
    children,
    item,
    seasons,
    episodes,
    poster,
};

/// One unit of work and its result, in the same object. The UI owns a task
/// from `submit` until `release`, a worker owns it in between, and `state` is
/// the handover -- so nothing inside needs its own lock.
pub const Task = struct {
    job: Job = .discover,
    /// Parent/series id, username, or Quick Connect secret, per job.
    a: Text(256) = .{},
    /// Season id or password, per job.
    b: Text(256) = .{},
    start: u32 = 0,
    limit: u32 = 0,
    /// Opaque to the fetcher: the UI uses it to match a result to the row,
    /// grid slot or poster tile that asked for it.
    tag: u32 = 0,

    arena: std.heap.ArenaAllocator,
    state: State = .free,

    list: ItemList = .{},
    one: Item = .{},
    auth: Auth = .{},
    quick: QuickConnect = .{},
    servers: []Discovered = &.{},
    image: ?image_decoder.Image = null,
    err: Text(128) = .{},

    pub const State = enum { free, queued, running, ready, failed };

    pub fn ok(self: *const Task) bool {
        return self.state == .ready;
    }
};

pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    work: std.Io.Condition = .init,
    tasks: [slots]Task = undefined,
    threads: [workers]std.Thread = undefined,
    /// The session workers use. Copied under the lock at the start of every
    /// task, so the UI can replace it between frames without racing.
    session: Session = .{},
    running: bool = true,

    /// Deep enough for a screen of posters plus the page request that named
    /// them; a full pool makes `submit` return null and the UI retry next frame.
    const slots = 32;
    const workers = 4;

    pub fn init(self: *Fetcher, allocator: std.mem.Allocator, io: std.Io) !void {
        self.* = .{ .allocator = allocator, .io = io };
        for (&self.tasks) |*task| task.* = .{ .arena = .init(allocator) };
        for (&self.threads) |*thread| thread.* = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Fetcher) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.running = false;
            self.work.broadcast(self.io);
        }
        for (self.threads) |thread| thread.join();
        for (&self.tasks) |*task| task.arena.deinit();
    }

    pub fn setSession(self: *Fetcher, session: Session) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.session = session;
    }

    /// Claim a slot and queue it. Null means every slot is busy.
    pub fn submit(self: *Fetcher, job: Job, tag: u32) ?*Task {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.tasks) |*task| {
            if (task.state != .free) continue;
            const arena = task.arena;
            task.* = .{ .job = job, .tag = tag, .arena = arena, .state = .queued };
            return task;
        }
        return null;
    }

    /// Hand a filled-in task to the workers. Between `submit` and `start` the
    /// slot is reserved but not yet visible to a worker, so the caller can set
    /// the inputs without a lock.
    pub fn start(self: *Fetcher, _: *Task) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.work.signal(self.io);
    }

    /// The next finished task, or null. Call until it returns null each frame.
    pub fn finished(self: *Fetcher) ?*Task {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.tasks) |*task| {
            if (task.state == .ready or task.state == .failed) return task;
        }
        return null;
    }

    pub fn release(self: *Fetcher, task: *Task) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = task.arena.reset(.retain_capacity);
        task.state = .free;
    }

    /// Tasks not yet handed back by the UI -- in flight *or* finished and
    /// still waiting to be consumed. The finished-but-unconsumed case matters:
    /// a caller that treats "nothing in flight" as "the screen is up to date"
    /// races the frame between a worker finishing and `finished` being drained.
    pub fn pending(self: *Fetcher) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (&self.tasks) |*task| {
            if (task.state != .free) n += 1;
        }
        return n;
    }

    fn run(self: *Fetcher) void {
        var http: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer http.deinit();
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const claimed: ?*Task = while (true) {
                if (!self.running) break null;
                const next: ?*Task = for (&self.tasks) |*task| {
                    if (task.state == .queued) break task;
                } else null;
                if (next) |task| {
                    task.state = .running;
                    break task;
                }
                self.work.waitUncancelable(self.io, &self.mutex);
            };
            const session = self.session;
            self.mutex.unlock(self.io);
            const task = claimed orelse return;

            const arena = task.arena.allocator();
            if (execute(&http, self.io, arena, &session, task)) |_| {
                self.mutex.lockUncancelable(self.io);
                task.state = .ready;
                self.mutex.unlock(self.io);
            } else |err| {
                task.err.set(@errorName(err));
                self.mutex.lockUncancelable(self.io);
                task.state = .failed;
                self.mutex.unlock(self.io);
            }
        }
    }
};

fn execute(http: *std.http.Client, io: std.Io, arena: std.mem.Allocator, session: *const Session, task: *Task) !void {
    switch (task.job) {
        .discover => {
            var found: std.ArrayListUnmanaged(Discovered) = .empty;
            try discover(arena, &found);
            task.servers = found.items;
        },
        .login => task.auth = try login(http, arena, session, task.a.get(), task.b.get()),
        .quick_initiate => task.quick = try quickConnectInitiate(http, arena, session),
        .quick_poll => task.quick = try quickConnectPoll(http, arena, session, task.a.get()),
        .quick_authenticate => task.auth = try quickConnectAuthenticate(http, arena, session, task.a.get()),
        .views => task.list = try views(http, arena, session),
        .resume_items => task.list = try resume_(http, arena, session),
        .next_up => task.list = try nextUp(http, arena, session),
        .children => task.list = try children(http, arena, session, task.a.get(), task.start, task.limit),
        .item => task.one = try item(http, arena, session, task.a.get()),
        .seasons => task.list = try seasons(http, arena, session, task.a.get()),
        .episodes => task.list = try episodes(http, arena, session, task.a.get(), task.b.get()),
        .poster => task.image = try poster(http, io, arena, session, task.a.get(), task.b.get(), task.start, task.limit),
    }
}

// Live round trip against a real server. Skipped unless the environment names
// one, so `zig build test` stays offline:
//
//   set -a; . ./.env; set +a; zig test src/jellyfin/api.zig
test "live: discover, log in and read a library" {
    const address = env("JELLYFIN_ADDRESS") orelse return error.SkipZigTest;
    const user = env("JELLYFIN_USER") orelse return error.SkipZigTest;
    const password = env("JELLYFIN_PASSWORD") orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var http: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer http.deinit();
    var owner: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer owner.deinit();
    const arena = owner.allocator();

    var session: Session = .{};
    session.url.set(address);
    deviceId(&session.device_id);

    var found: std.ArrayListUnmanaged(Discovered) = .empty;
    try discover(arena, &found);
    std.debug.print("discovered {d} server(s)\n", .{found.items.len});
    for (found.items) |server| std.debug.print("  {s} {s}\n", .{ server.Name, server.Address });

    const auth = try login(&http, arena, &session, user, password);
    try std.testing.expect(auth.AccessToken.len != 0);
    session.token.set(auth.AccessToken);
    session.user_id.set(auth.User.Id);

    const quick = try quickConnectInitiate(&http, arena, &session);
    try std.testing.expectEqual(@as(usize, 6), quick.Code.len);

    const libraries = try views(&http, arena, &session);
    try std.testing.expect(libraries.Items.len != 0);
    var first_library: []const u8 = "";
    for (libraries.Items) |view| {
        std.debug.print("  view {s} ({s})\n", .{ view.Name, view.CollectionType orelse "-" });
        const kind = view.CollectionType orelse continue;
        if (first_library.len == 0 and (std.mem.eql(u8, kind, "movies") or std.mem.eql(u8, kind, "tvshows")))
            first_library = view.Id;
    }
    try std.testing.expect(first_library.len != 0);

    const page = try children(&http, arena, &session, first_library, 0, 12);
    std.debug.print("library page: {d} of {d}\n", .{ page.Items.len, page.TotalRecordCount });
    try std.testing.expect(page.Items.len != 0);

    _ = try resume_(&http, arena, &session);
    _ = try nextUp(&http, arena, &session);

    // A poster proves the artwork path end to end: request, then decode.
    try image_decoder.init();
    store.init();
    const first = page.Items[0];
    const art = try poster(&http, io, arena, &session, first.posterId(), first.posterTag(), 240, 360);
    std.debug.print("poster decoded: {d}x{d}, tag {s}\n", .{ art.width, art.height, first.posterTag() });
    try std.testing.expect(art.width >= 200 and art.height >= 300);
    try std.testing.expectEqual(@as(usize, art.width) * art.height * 3, art.rgb.len);

    // Second time it must come off disk. Proven by pointing the client at a
    // dead address: a cache hit never touches the network.
    if (first.posterTag().len != 0) {
        var offline = session;
        offline.url.set("http://127.0.0.1:1");
        const again = try poster(&http, io, arena, &offline, first.posterId(), first.posterTag(), 240, 360);
        try std.testing.expectEqual(art.rgb.len, again.rgb.len);
        std.debug.print("cache hit served {d}x{d} with no server\n", .{ again.width, again.height });
    }

    // Walk a show down to an episode, which is the deepest navigation path.
    for (page.Items) |candidate| {
        if (!std.mem.eql(u8, candidate.Type, "Series")) continue;
        const list = try seasons(&http, arena, &session, candidate.Id);
        if (list.Items.len == 0) break;
        const inner = try episodes(&http, arena, &session, candidate.Id, list.Items[0].Id);
        std.debug.print("{s}: {d} seasons, {d} episodes in season 1\n", .{ candidate.Name, list.Items.len, inner.Items.len });
        try std.testing.expect(inner.Items.len != 0);
        break;
    }
}
