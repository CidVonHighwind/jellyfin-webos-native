//! A Jellyfin client for the TV: discovery, sign-in, home rows, a virtual
//! library grid and the path down to a single episode.
//!
//! The UI is `uidemo`'s: one instanced batch, MSDF-free rasterised glyphs, the
//! same remote/pointer handling and the same virtual-list geometry. What is
//! new is that every screen is backed by a real server, so this file is mostly
//! about keeping the render thread free of that: `api.Fetcher` runs the
//! requests on worker threads, results arrive as completed tasks once a frame,
//! and screen state is plain fixed-size storage that a task result is copied
//! into. Nothing the renderer touches is owned by a worker.
//!
//! Playback is deliberately URL-only: the details screen resolves the stream
//! URL and shows it. Feeding it to a decoder is the NDL work in docs/ndl.md.

const std = @import("std");
const linux = std.os.linux;
const gl = @import("gl.zig");
const wl = @import("wl.zig");
const loom = @import("loom/loom.zig");
const UiRenderer = @import("ui_renderer.zig").Renderer;
const api = @import("jellyfin/api.zig");

const GL_COLOR_BUFFER_BIT = 0x00004000;
const GL_RGBA = 0x1908;
const GL_UNSIGNED_BYTE = 0x1401;
var glClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void = undefined;
var glClear: *const fn (u32) callconv(.c) void = undefined;
var glViewport: *const fn (i32, i32, i32, i32) callconv(.c) void = undefined;
var glReadPixels: *const fn (i32, i32, i32, i32, u32, u32, [*]u8) callconv(.c) void = undefined;

const BG: loom.Color = .{ 9, 13, 22, 255 };
const PANEL: loom.Color = .{ 20, 27, 40, 255 };
const CARD: loom.Color = .{ 27, 36, 52, 255 };
const HOT: loom.Color = .{ 38, 51, 70, 255 };
const SELECTED: loom.Color = .{ 27, 69, 91, 255 };
const ACCENT: loom.Color = .{ 0, 164, 220, 255 };
const GREEN: loom.Color = .{ 82, 205, 147, 255 };
const RED: loom.Color = .{ 228, 96, 96, 255 };
const TEXT: loom.Color = .{ 239, 244, 250, 255 };
const DIM: loom.Color = .{ 148, 163, 182, 255 };
const BORDER: loom.Color = .{ 55, 70, 91, 255 };
const WHITE: loom.Color = .{ 255, 255, 255, 255 };

// ----------------------------------------------------------- poster cache
//
// One GL texture per image, not an atlas. Artwork comes back at whatever size
// the server chose (200x300, 204x300, 534x300 for a library tile), so an atlas
// would mean cropping every image to a fixed tile and then re-uploading over
// tiles that a scrolling grid may still be drawing from. A texture per poster
// keeps each image at its own size, and the batcher already handles the cost:
// one draw call per distinct texture on screen.

const poster_w = 240;
const poster_h = 360;
/// Enough for a full grid page plus the rows behind it. Each is ~260 KB.
const cache_size = 48;

const Slot = struct {
    id: api.Text(40) = .{},
    tag: api.Text(40) = .{},
    texture: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Frame this slot was last asked for. 0 means never.
    used: u64 = 0,
    loading: bool = false,
};

var slots: [cache_size]Slot = @splat(.{});
var frame_index: u64 = 0;
/// Poster requests started this frame. Scrolling a grid can name thirty new
/// posters in one frame; the fetcher has 32 slots shared with page requests,
/// so let the visible ones trickle in over a few frames instead of starving it.
var poster_requests: u8 = 0;

/// The cached artwork for `id`, or null while it is still being fetched.
/// Calling this is also what keeps a slot alive, so it must be called every
/// frame for every visible card.
fn poster(id: []const u8, tag: []const u8) ?*const Slot {
    if (id.len == 0) return null;
    for (&slots) |*slot| {
        if (!std.mem.eql(u8, slot.id.get(), id) or !std.mem.eql(u8, slot.tag.get(), tag)) continue;
        slot.used = frame_index;
        return if (slot.texture != 0) slot else null;
    }
    if (poster_requests >= 4) return null;

    var victim: ?*Slot = null;
    var oldest: u64 = std.math.maxInt(u64);
    for (&slots) |*slot| {
        // Never evict something drawn this frame or the one before: that is a
        // slot the screen is using right now, and recycling it would thrash.
        if (slot.loading or (slot.used != 0 and slot.used + 1 >= frame_index)) continue;
        if (slot.used < oldest) {
            oldest = slot.used;
            victim = slot;
        }
    }
    const claimed = victim orelse return null;
    const index: u32 = @intCast((@intFromPtr(claimed) - @intFromPtr(&slots)) / @sizeOf(Slot));

    const task = fetcher.submit(.poster, index) orelse return null;
    task.a.set(id);
    task.b.set(tag);
    task.start = poster_w;
    task.limit = poster_h;
    renderer.destroyTexture(claimed.texture);
    claimed.* = .{ .used = frame_index, .loading = true };
    claimed.id.set(id);
    claimed.tag.set(tag);
    fetcher.start(task);
    poster_requests += 1;
    return null;
}

/// Texture coordinates that fill `rect` with the image, cropping the long axis
/// instead of stretching it. A 534x300 library banner and a 200x300 poster then
/// look right in the same portrait card.
fn coverUv(slot: *const Slot, rect: loom.Rect) [4]f32 {
    if (slot.width == 0 or slot.height == 0 or rect.w <= 0 or rect.h <= 0) return .{ 0, 0, 1, 1 };
    const want = rect.w / rect.h;
    const have = @as(f32, @floatFromInt(slot.width)) / @as(f32, @floatFromInt(slot.height));
    if (have > want) {
        const keep = want / have;
        return .{ (1 - keep) / 2, 0, (1 + keep) / 2, 1 };
    }
    const keep = have / want;
    return .{ 0, (1 - keep) / 2, 1, (1 + keep) / 2 };
}

// -------------------------------------------------------------- card model
//
// A task's result lives in that task's arena and dies when the UI releases it,
// so screens keep their own copy. Fixed-size text means the copy is a memcpy
// into storage that never moves -- which is also what the renderer needs,
// since a draw command holds a slice, not a string.

const Card = struct {
    id: api.Text(40) = .{},
    poster_id: api.Text(40) = .{},
    poster_tag: api.Text(40) = .{},
    series_id: api.Text(40) = .{},
    title: api.Text(96) = .{},
    subtitle: api.Text(72) = .{},
    kind: api.Text(16) = .{},
    runtime: api.Text(24) = .{},
    progress: f32 = 0,
    present: bool = false,

    fn from(item: api.Item) Card {
        var card: Card = .{ .present = true, .progress = item.progress() };
        card.id.set(item.Id);
        card.poster_id.set(item.posterId());
        card.poster_tag.set(item.posterTag());
        card.series_id.set(item.SeriesId orelse "");
        card.kind.set(item.Type);
        card.title.set(if (std.mem.eql(u8, item.Type, "Episode"))
            item.SeriesName orelse item.Name
        else
            item.Name);
        // Each `build` reuses one buffer, so every result is copied into the
        // card before the next call.
        card.subtitle.set(subtitleFor(item));
        if (item.minutes() != 0) card.runtime.set(build("{d}h {d:0>2}m", .{ item.minutes() / 60, item.minutes() % 60 }));
        return card;
    }

    fn is(self: Card, kind: []const u8) bool {
        return std.mem.eql(u8, self.kind.get(), kind);
    }
};

/// One line under a card: what distinguishes this item from its neighbours.
fn subtitleFor(item: api.Item) []const u8 {
    if (std.mem.eql(u8, item.Type, "Episode"))
        return build("S{d}E{d}  {s}", .{ item.ParentIndexNumber orelse 0, item.IndexNumber orelse 0, item.Name });
    if (std.mem.eql(u8, item.Type, "CollectionFolder"))
        return item.CollectionType orelse "Library";
    if (std.mem.eql(u8, item.Type, "Series"))
        return build("Series  -  {d}  -  {d} seasons", .{ item.ProductionYear orelse 0, item.ChildCount orelse 0 });
    if (std.mem.eql(u8, item.Type, "Season"))
        return build("{d} episodes", .{item.ChildCount orelse 0});
    if (item.RunTimeTicks != null and item.minutes() != 0)
        return build("{d}  -  {d}h {d:0>2}m", .{ item.ProductionYear orelse 0, item.minutes() / 60, item.minutes() % 60 });
    return item.CollectionType orelse item.Type;
}

/// Per-frame scratch for formatted labels. A draw command borrows the slice
/// until the renderer has consumed it, so these must outlive `buildUi` -- but
/// only that, hence a ring reset every frame. Sized for a full grid page:
/// every card formats a title and a subtitle to fit its width.
var scratch: [256][160]u8 = undefined;
var scratch_used: usize = 0;

fn fmt(comptime pattern: []const u8, args: anytype) []const u8 {
    if (scratch_used == scratch.len) return "...";
    const out = std.fmt.bufPrint(&scratch[scratch_used], pattern, args) catch "...";
    scratch_used += 1;
    return out;
}

/// Formatting for text that is copied into fixed storage immediately, which is
/// every field of a card. Deliberately not the frame scratch: building cards
/// happens while draining tasks, before the frame resets, and one page of
/// sixty items would eat the ring the labels then need.
var build_buffer: [256]u8 = undefined;

fn build(comptime pattern: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&build_buffer, pattern, args) catch "";
}

// -------------------------------------------------------------- app state

const Screen = enum { server, auth, quick, home, grid, details, season };
const EditField = enum { none, url, username, password };

const row_capacity = 24;
const Row = struct {
    title: []const u8,
    /// Libraries are 16:9 banners on the server, not posters. Cropping one to
    /// a portrait card cuts the library's name out of the middle of it.
    wide: bool = false,
    cards: [row_capacity]Card = @splat(.{}),
    count: usize = 0,
    loading: bool = false,

    fn fill(self: *Row, items: []const api.Item) void {
        self.count = @min(items.len, row_capacity);
        for (items[0..self.count], self.cards[0..self.count]) |item, *card| card.* = .from(item);
        self.loading = false;
    }
};

/// Fixed home layout, top to bottom. Libraries last because the first two are
/// what a returning user actually wants.
const RowId = enum(usize) { resume_watching, next_up, libraries };
var rows = [_]Row{
    .{ .title = "Continue Watching" },
    .{ .title = "Up Next" },
    .{ .title = "Libraries", .wide = true },
};

var session: api.Session = .{};
var fetcher: api.Fetcher = undefined;

var screen: Screen = .server;
var focus: usize = 0;
var row_focus: usize = 0;
var col_focus: [rows.len]usize = @splat(0);

/// Where Back goes, as a stack rather than a rule per screen.
///
/// The rule version was wrong in the ordinary case: reaching a show from a
/// home row and pressing Back returned to whichever library grid happened to
/// be loaded, because "is a grid loaded" is not the same question as "is that
/// where I came from". An entry carries enough to re-enter a screen, not a
/// snapshot of it -- re-entering refetches, which is what keeps a details
/// screen current after playback marks something watched.
const Entry = struct {
    screen: Screen,
    /// The grid's library, the details item, or the season.
    card: Card = .{},
    /// The series a season belongs to, so a season can be re-entered.
    series: Card = .{},
    selected: usize = 0,
    scroll: f32 = 0,
    focus: usize = 0,
    row_focus: usize = 0,
    col_focus: [rows.len]usize = @splat(0),
};

var stack: [12]Entry = undefined;
var depth: usize = 0;

fn here() Entry {
    return .{
        .screen = screen,
        .card = switch (screen) {
            .grid => libraryCard(),
            .season => seasonCard(),
            else => detail,
        },
        .series = detail,
        .selected = switch (screen) {
            .grid => grid_selected,
            .season => episode_selected,
            else => 0,
        },
        .scroll = grid_scroll,
        .focus = focus,
        .row_focus = row_focus,
        .col_focus = col_focus,
    };
}

fn push() void {
    if (depth == stack.len) {
        // Deeper than any real path through this app; drop the oldest rather
        // than refuse to navigate.
        std.mem.copyForwards(Entry, stack[0 .. stack.len - 1], stack[1..]);
        depth -= 1;
    }
    stack[depth] = here();
    depth += 1;
}

fn pop() void {
    if (depth == 0) {
        wl.running = false;
        return;
    }
    depth -= 1;
    const entry = stack[depth];
    row_focus = entry.row_focus;
    col_focus = entry.col_focus;
    switch (entry.screen) {
        .home => screen = .home,
        .grid => {
            // Returning to the grid we are still holding pages for is free;
            // a different library has to be fetched again.
            if (std.mem.eql(u8, grid_parent.get(), entry.card.id.get()) and grid_total != 0) {
                screen = .grid;
            } else {
                openGrid(entry.card);
            }
            grid_selected = entry.selected;
            grid_scroll = entry.scroll;
        },
        .details => {
            openDetails(entry.card);
            focus = entry.focus;
        },
        .season => {
            detail = entry.series;
            openSeason(entry.card);
            episode_selected = entry.selected;
        },
        // Nothing above the sign-in screens is ever pushed.
        else => {
            screen = entry.screen;
            focus = entry.focus;
        },
    }
}

/// The library a grid belongs to, rebuilt from what the grid kept.
fn libraryCard() Card {
    var card: Card = .{ .present = true };
    card.id.set(grid_parent.get());
    card.title.set(grid_title.get());
    return card;
}

fn seasonCard() Card {
    var card: Card = .{ .present = true };
    card.id.set(season_id.get());
    card.title.set(season_title.get());
    card.series_id.set(detail.id.get());
    return card;
}

// Discovery / manual server entry.
const discovered_capacity = 8;
var discovered: [discovered_capacity]struct { name: api.Text(64), address: api.Text(128) } = undefined;
var discovered_count: usize = 0;
var discovering = false;

// Quick Connect.
var quick_code: api.Text(16) = .{};
var quick_secret: api.Text(80) = .{};
var quick_poll_at: u64 = 0;

// Library grid: a window of a much longer server-side list.
const page_size = 60;
const window_pages = 4;
const window_size = page_size * window_pages;
var grid_parent: api.Text(40) = .{};
var grid_title: api.Text(96) = .{};
var grid_total: u32 = 0;
var grid_cards: [window_size]Card = @splat(.{});
/// Absolute item index currently stored in each window entry. Without it a
/// stale card from a page that scrolled away would be drawn as if it were the
/// item that now occupies the same ring slot.
var grid_at: [window_size]u32 = @splat(std.math.maxInt(u32));
var grid_requested: [window_pages]u32 = @splat(std.math.maxInt(u32));
var grid_selected: usize = 0;
var grid_scroll: f32 = 0;
var grid_rect: loom.Rect = .{};
var grid_columns: usize = 6;
var grid_row_height: f32 = 360;

// Details and season screens.
var detail: Card = .{};
var detail_overview: api.Text(640) = .{};
var detail_extra: api.Text(96) = .{};
var seasons_row: Row = .{ .title = "Seasons" };
var episodes_row: Row = .{ .title = "Episodes" };
var episode_selected: usize = 0;
var season_title: api.Text(96) = .{};
var season_id: api.Text(40) = .{};
var stream_url: api.Text(256) = .{};

// Text entry, remote and pointer, all as in uidemo.
var server_url: api.Text(256) = .{};
var username: api.Text(256) = .{};
var password: api.Text(256) = .{};
var password_mask: [256]u8 = @splat('*');
var url_rect: loom.Rect = .{};
var username_rect: loom.Rect = .{};
var password_rect: loom.Rect = .{};
var active_field: EditField = .none;
var shift_down = false;
var caps_lock = false;
var capture_requested = false;

var cursor_x: f32 = -1;
var cursor_y: f32 = -1;
var cursor_present = false;
var pointer_press = false;

var status: api.Text(200) = .{};
var status_error = false;

fn setStatus(comptime pattern: []const u8, args: anytype) void {
    var buffer: [200]u8 = undefined;
    status.set(std.fmt.bufPrint(&buffer, pattern, args) catch "");
    status_error = false;
}

fn setError(comptime pattern: []const u8, args: anytype) void {
    setStatus(pattern, args);
    status_error = true;
}

// ------------------------------------------------------------- requests

fn request(job: api.Job, tag: u32) ?*api.Task {
    return fetcher.submit(job, tag);
}

fn simple(job: api.Job) void {
    const task = request(job, 0) orelse return;
    fetcher.start(task);
}

fn loadHome() void {
    for (&rows) |*row| row.loading = true;
    simple(.resume_items);
    simple(.next_up);
    simple(.views);
}

fn openGrid(card: Card) void {
    grid_parent = card.id;
    grid_title = card.title;
    grid_total = 0;
    grid_selected = 0;
    grid_scroll = 0;
    grid_cards = @splat(.{});
    grid_at = @splat(std.math.maxInt(u32));
    grid_requested = @splat(std.math.maxInt(u32));
    screen = .grid;
    requestPage(0);
}

/// Ask for the page containing `index`, unless that page is already in the
/// window or already in flight.
fn requestPage(index: u32) void {
    const page = index / page_size;
    const ring = page % window_pages;
    if (grid_requested[ring] == page) return;
    const task = request(.children, page) orelse return;
    task.a.set(grid_parent.get());
    task.start = page * page_size;
    task.limit = page_size;
    grid_requested[ring] = page;
    fetcher.start(task);
}

fn openDetails(card: Card) void {
    detail = card;
    detail_overview.set("");
    detail_extra.set("");
    stream_url.set("");
    seasons_row.count = 0;
    seasons_row.loading = false;
    focus = 0;
    screen = .details;

    // An episode plays as itself; a series needs its seasons before anything
    // on this screen can be selected.
    const task = request(.item, 0) orelse return;
    task.a.set(card.id.get());
    fetcher.start(task);

    if (card.is("Series")) {
        seasons_row.loading = true;
        const seasons = request(.seasons, 0) orelse return;
        seasons.a.set(card.id.get());
        fetcher.start(seasons);
    } else {
        var buffer: [256]u8 = undefined;
        stream_url.set(api.streamUrl(&session, card.id.get(), &buffer));
    }
}

fn openSeason(card: Card) void {
    season_title = card.title;
    season_id = card.id;
    episodes_row.count = 0;
    episodes_row.loading = true;
    episode_selected = 0;
    screen = .season;
    const task = request(.episodes, 0) orelse return;
    task.a.set(if (card.series_id.len != 0) card.series_id.get() else detail.id.get());
    task.b.set(card.id.get());
    fetcher.start(task);
}

/// Re-authentications attempted since the last success. Bounded, or a server
/// that rejects a valid-looking password turns into a login loop.
var relogin_attempts: u8 = 0;

fn signedIn(auth: api.Auth, used_password: []const u8) void {
    const silent = screen == .home and session.token.len != 0;
    session.token.set(auth.AccessToken);
    session.user_id.set(auth.User.Id);
    session.user_name.set(auth.User.Name);
    session.password.set(used_password);
    fetcher.setSession(session);
    api.save(&session);
    relogin_attempts = 0;
    setStatus("Signed in as {s}", .{session.user_name.get()});
    if (silent) {
        // A token replaced underneath a screen that is already up: reload what
        // failed, do not throw the user back to the top.
        loadHome();
        return;
    }
    screen = .home;
    row_focus = 0;
    col_focus = @splat(0);
    depth = 0;
    loadHome();
}

/// Replace a rejected token without involving the user.
///
/// Jellyfin invalidates a device's previous token when that device signs in
/// again, so a stored token going stale is routine rather than exceptional --
/// signing the user out and asking for a password on a TV remote is the wrong
/// response when the password is right there.
fn reauthenticate() bool {
    if (session.password.len == 0 or session.user_name.len == 0) return false;
    if (relogin_attempts >= 2) return false;
    const task = request(.login, 0) orelse return false;
    task.a.set(session.user_name.get());
    task.b.set(session.password.get());
    relogin_attempts += 1;
    fetcher.start(task);
    setStatus("Session expired; signing in again", .{});
    return true;
}

fn signOut() void {
    api.forget();
    session.token.set("");
    session.user_id.set("");
    session.password.set("");
    relogin_attempts = 0;
    fetcher.setSession(session);
    for (&rows) |*row| row.count = 0;
    depth = 0;
    screen = .auth;
    focus = 0;
    setStatus("Signed out", .{});
}

// --------------------------------------------------------- task results

fn consume(task: *api.Task) void {
    if (task.state == .failed) {
        onFailure(task);
        return;
    }
    switch (task.job) {
        .discover => {
            discovering = false;
            discovered_count = @min(task.servers.len, discovered_capacity);
            for (task.servers[0..discovered_count], 0..) |found, index| {
                discovered[index].name.set(found.Name);
                discovered[index].address.set(found.Address);
            }
            if (discovered_count == 0)
                setStatus("No server answered the broadcast; enter an address", .{})
            else
                setStatus("Found {d} server(s)", .{discovered_count});
        },
        .login => signedIn(task.auth, task.b.get()),
        // Quick Connect never sees a password, so there is nothing to keep.
        .quick_authenticate => signedIn(task.auth, ""),
        .quick_initiate => {
            quick_code.set(task.quick.Code);
            quick_secret.set(task.quick.Secret);
            screen = .quick;
            setStatus("Waiting for approval", .{});
            // Also on stdout: on a TV the log is often easier to reach than
            // the screen, and this is the number the user has to read out.
            std.debug.print("quick connect code: {s}\n", .{quick_code.get()});
        },
        .quick_poll => if (task.quick.Authenticated) {
            const auth = request(.quick_authenticate, 0) orelse return;
            auth.a.set(quick_secret.get());
            fetcher.start(auth);
        },
        .resume_items => rows[@intFromEnum(RowId.resume_watching)].fill(task.list.Items),
        .next_up => rows[@intFromEnum(RowId.next_up)].fill(task.list.Items),
        .views => {
            // Music and playlists have no poster grid worth opening from here,
            // and the scope for this client is video.
            var keep: [row_capacity]api.Item = undefined;
            var count: usize = 0;
            for (task.list.Items) |view| {
                const kind = view.CollectionType orelse "";
                if (std.mem.eql(u8, kind, "music") or std.mem.eql(u8, kind, "playlists")) continue;
                if (count == keep.len) break;
                keep[count] = view;
                count += 1;
            }
            rows[@intFromEnum(RowId.libraries)].fill(keep[0..count]);
        },
        .children => {
            grid_total = task.list.TotalRecordCount;
            const start = task.tag * page_size;
            for (task.list.Items, 0..) |item, offset| {
                const absolute: u32 = @intCast(start + offset);
                const ring = absolute % window_size;
                grid_cards[ring] = .from(item);
                grid_at[ring] = absolute;
            }
        },
        .item => {
            detail_overview.set(task.one.Overview orelse "");
            detail_extra.set(build("{s}   {s}   {d}", .{
                task.one.Type,
                task.one.OfficialRating orelse "Unrated",
                task.one.ProductionYear orelse 0,
            }));
        },
        .seasons => seasons_row.fill(task.list.Items),
        .episodes => episodes_row.fill(task.list.Items),
        .poster => if (task.image) |art| {
            const slot = &slots[task.tag];
            slot.texture = renderer.createTexture(art.width, art.height, art.rgb);
            slot.width = art.width;
            slot.height = art.height;
            slot.loading = false;
        },
    }
}

fn onFailure(task: *api.Task) void {
    std.log.debug("{s} failed: {s}", .{ @tagName(task.job), task.err.get() });
    switch (task.job) {
        // A missing poster is normal -- plenty of items have none -- so it
        // marks the slot done and leaves the placeholder card showing. The
        // id stays, so the same item is not asked for again every frame.
        .poster => slots[task.tag].loading = false,
        .discover => {
            discovering = false;
            setError("Discovery failed: {s}", .{task.err.get()});
        },
        .children => grid_requested[task.tag % window_pages] = std.math.maxInt(u32),
        // A rejected token is the one failure with a recovery: the stored
        // credentials are stale, so drop them rather than loop on 401s.
        // Anything else -- a server restarting, a dropped Wi-Fi association --
        // keeps them, because deleting a good token over a transient error
        // means typing a password back in on a TV remote.
        .views, .resume_items, .next_up => {
            if (std.mem.eql(u8, task.err.get(), "Unauthorized")) {
                if (!reauthenticate()) signOut();
                return;
            }
            setError("{s} failed: {s}", .{ @tagName(task.job), task.err.get() });
        },
        .quick_poll => {},
        .login => {
            setError("Sign-in failed: {s}", .{task.err.get()});
            // A stored password the server no longer accepts: forget it rather
            // than retry it on every screen.
            if (relogin_attempts != 0) signOut();
        },
        else => setError("{s} failed: {s}", .{ @tagName(task.job), task.err.get() }),
    }
}

fn pump() void {
    while (fetcher.finished()) |task| {
        consume(task);
        fetcher.release(task);
    }
    if (screen == .quick and quick_secret.len != 0 and nowNs() > quick_poll_at) {
        quick_poll_at = nowNs() + 2 * std.time.ns_per_s;
        const task = request(.quick_poll, 0) orelse return;
        task.a.set(quick_secret.get());
        fetcher.start(task);
    }
}

// -------------------------------------------------------------- text entry

fn field(which: EditField) *api.Text(256) {
    return switch (which) {
        .url => &server_url,
        .username => &username,
        .password => &password,
        .none => unreachable,
    };
}

fn fieldZ(which: EditField) [:0]const u8 {
    const target = field(which);
    target.buffer[target.len] = 0;
    return target.buffer[0..target.len :0];
}

fn rectInts(rect: loom.Rect) [4]i32 {
    return .{ @intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.w), @intFromFloat(rect.h) };
}

fn beginEdit(which: EditField, rect: loom.Rect) void {
    if (active_field != .none) wl.endTextInput();
    active_field = which;
    const purpose: wl.TextPurpose = switch (which) {
        .url => .url,
        .password => .password,
        else => .normal,
    };
    if (wl.beginTextInput(fieldZ(which), rectInts(rect), purpose))
        setStatus("webOS keyboard opened", .{})
    else
        setStatus("Type with the keyboard; Enter finishes", .{});
}

fn endEdit() void {
    if (active_field == .none) return;
    wl.endTextInput();
    active_field = .none;
}

fn appendText(text: []const u8) void {
    if (active_field == .none) return;
    const target = field(active_field);
    const count = @min(text.len, target.buffer.len - 1 - target.len);
    @memcpy(target.buffer[target.len..][0..count], text[0..count]);
    target.len += count;
    target.buffer[target.len] = 0;
    wl.updateTextInput(fieldZ(active_field));
}

fn eraseText(count: usize) void {
    if (active_field == .none) return;
    const target = field(active_field);
    target.len -|= @min(count, target.len);
    target.buffer[target.len] = 0;
    wl.updateTextInput(fieldZ(active_field));
}

// -------------------------------------------------------------- navigation

fn homeRow() *Row {
    return &rows[row_focus];
}

/// A slot that has not been paged in yet. Returning a pointer to this rather
/// than a temporary keeps every card the renderer sees alive past the frame.
var blank_card: Card = .{};

fn gridCard(index: usize) ?*const Card {
    if (index >= grid_total) return null;
    const ring = index % window_size;
    if (grid_at[ring] != index) return null;
    return if (grid_cards[ring].present) &grid_cards[ring] else null;
}

fn useServer(address: []const u8) void {
    server_url.set(address);
    session.url.set(address);
    fetcher.setSession(session);
    screen = .auth;
    focus = 0;
    setStatus("Sign in to {s}", .{address});
}

fn goBack() void {
    if (active_field != .none) {
        endEdit();
        return;
    }
    switch (screen) {
        .server => wl.running = false,
        .auth => {
            screen = .server;
            focus = 0;
        },
        .quick => {
            quick_secret.set("");
            screen = .auth;
            focus = 0;
        },
        else => pop(),
    }
}

fn activate() void {
    switch (screen) {
        .server => activateServer(),
        .auth => switch (focus) {
            0 => beginEdit(.username, username_rect),
            1 => beginEdit(.password, password_rect),
            2 => {
                if (username.len == 0) return setError("Enter a username", .{});
                const task = request(.login, 0) orelse return;
                task.a.set(username.get());
                task.b.set(password.get());
                fetcher.start(task);
                setStatus("Signing in...", .{});
            },
            else => {
                simple(.quick_initiate);
                setStatus("Requesting a Quick Connect code...", .{});
            },
        },
        .quick => goBack(),
        .home => {
            const row = homeRow();
            const index = col_focus[row_focus];
            if (index >= row.count) return;
            const card = row.cards[index];
            push();
            if (row_focus == @intFromEnum(RowId.libraries)) openGrid(card) else openDetails(card);
        },
        .grid => if (gridCard(grid_selected)) |card| {
            push();
            openDetails(card.*);
        },
        .details => activateDetails(),
        .season => if (episode_selected < episodes_row.count) {
            var buffer: [256]u8 = undefined;
            stream_url.set(api.streamUrl(&session, episodes_row.cards[episode_selected].id.get(), &buffer));
            setStatus("Stream URL: {s}", .{stream_url.get()});
            std.debug.print("play {s}\n", .{stream_url.get()});
        },
    }
}

fn activateServer() void {
    if (focus < discovered_count) return useServer(discovered[focus].address.get());
    if (focus == discovered_count) return beginEdit(.url, url_rect);
    if (focus == discovered_count + 1) {
        if (server_url.len == 0) return setError("Enter a server URL first", .{});
        return useServer(server_url.get());
    }
    discovering = true;
    discovered_count = 0;
    simple(.discover);
    setStatus("Broadcasting on UDP 7359...", .{});
}

fn activateDetails() void {
    if (detail.is("Series")) {
        if (focus < seasons_row.count) {
            push();
            openSeason(seasons_row.cards[focus]);
        }
        return;
    }
    if (focus == 0) {
        setStatus("Stream URL: {s}", .{stream_url.get()});
        std.debug.print("play {s}\n", .{stream_url.get()});
    } else goBack();
}

/// How many focusable things the current screen has, so navigation clamps
/// without every caller knowing the layout.
fn focusCount() usize {
    return switch (screen) {
        .server => discovered_count + 3,
        .auth => 4,
        .quick => 1,
        .details => if (detail.is("Series")) @max(1, seasons_row.count) else 2,
        else => 1,
    };
}

fn navigate(code: u32) void {
    switch (code) {
        1, 158 => goBack(),
        103 => move(.up),
        108 => move(.down),
        105 => move(.left),
        106 => move(.right),
        28, 96, 352 => activate(),
        else => {},
    }
}

const Direction = enum { up, down, left, right };

fn move(direction: Direction) void {
    switch (screen) {
        .home => moveHome(direction),
        .grid => moveGrid(direction),
        .season => switch (direction) {
            .up => episode_selected -|= 1,
            .down => episode_selected = @min(episode_selected + 1, episodes_row.count -| 1),
            else => {},
        },
        // Every other screen is a single column of controls, except the
        // details screen's seasons, which read as a row.
        .details => if (detail.is("Series")) switch (direction) {
            .left => focus -|= 1,
            .right => focus = @min(focus + 1, focusCount() - 1),
            else => {},
        } else switch (direction) {
            .left => focus -|= 1,
            .right => focus = @min(focus + 1, focusCount() - 1),
            else => {},
        },
        else => switch (direction) {
            .up => focus -|= 1,
            .down => focus = @min(focus + 1, focusCount() - 1),
            else => {},
        },
    }
}

fn moveHome(direction: Direction) void {
    switch (direction) {
        .up => row_focus -|= 1,
        .down => row_focus = @min(row_focus + 1, rows.len - 1),
        .left => col_focus[row_focus] -|= 1,
        .right => col_focus[row_focus] = @min(col_focus[row_focus] + 1, rows[row_focus].count -| 1),
    }
    col_focus[row_focus] = @min(col_focus[row_focus], rows[row_focus].count -| 1);
}

fn moveGrid(direction: Direction) void {
    const last = grid_total -| 1;
    switch (direction) {
        .left => grid_selected -|= 1,
        .right => grid_selected = @min(grid_selected + 1, last),
        .up => grid_selected -|= grid_columns,
        .down => grid_selected = @min(grid_selected + grid_columns, last),
    }
    const list = loom.VirtualList.init(grid_rect, gridRows(), grid_row_height, grid_scroll);
    grid_scroll = list.scrollToReveal(grid_selected / grid_columns);
    requestPage(@intCast(grid_selected));
}

fn gridRows() usize {
    return (grid_total + grid_columns - 1) / grid_columns;
}

// ------------------------------------------------------------------ input

const KeyPair = struct { code: u32, lower: u8, upper: u8 };
const key_pairs = [_]KeyPair{
    .{ .code = 2, .lower = '1', .upper = '!' },   .{ .code = 3, .lower = '2', .upper = '@' },
    .{ .code = 4, .lower = '3', .upper = '#' },   .{ .code = 5, .lower = '4', .upper = '$' },
    .{ .code = 6, .lower = '5', .upper = '%' },   .{ .code = 7, .lower = '6', .upper = '^' },
    .{ .code = 8, .lower = '7', .upper = '&' },   .{ .code = 9, .lower = '8', .upper = '*' },
    .{ .code = 10, .lower = '9', .upper = '(' },  .{ .code = 11, .lower = '0', .upper = ')' },
    .{ .code = 12, .lower = '-', .upper = '_' },  .{ .code = 13, .lower = '=', .upper = '+' },
    .{ .code = 16, .lower = 'q', .upper = 'Q' },  .{ .code = 17, .lower = 'w', .upper = 'W' },
    .{ .code = 18, .lower = 'e', .upper = 'E' },  .{ .code = 19, .lower = 'r', .upper = 'R' },
    .{ .code = 20, .lower = 't', .upper = 'T' },  .{ .code = 21, .lower = 'y', .upper = 'Y' },
    .{ .code = 22, .lower = 'u', .upper = 'U' },  .{ .code = 23, .lower = 'i', .upper = 'I' },
    .{ .code = 24, .lower = 'o', .upper = 'O' },  .{ .code = 25, .lower = 'p', .upper = 'P' },
    .{ .code = 26, .lower = '[', .upper = '{' },  .{ .code = 27, .lower = ']', .upper = '}' },
    .{ .code = 30, .lower = 'a', .upper = 'A' },  .{ .code = 31, .lower = 's', .upper = 'S' },
    .{ .code = 32, .lower = 'd', .upper = 'D' },  .{ .code = 33, .lower = 'f', .upper = 'F' },
    .{ .code = 34, .lower = 'g', .upper = 'G' },  .{ .code = 35, .lower = 'h', .upper = 'H' },
    .{ .code = 36, .lower = 'j', .upper = 'J' },  .{ .code = 37, .lower = 'k', .upper = 'K' },
    .{ .code = 38, .lower = 'l', .upper = 'L' },  .{ .code = 39, .lower = ';', .upper = ':' },
    .{ .code = 40, .lower = '\'', .upper = '"' }, .{ .code = 43, .lower = '\\', .upper = '|' },
    .{ .code = 44, .lower = 'z', .upper = 'Z' },  .{ .code = 45, .lower = 'x', .upper = 'X' },
    .{ .code = 46, .lower = 'c', .upper = 'C' },  .{ .code = 47, .lower = 'v', .upper = 'V' },
    .{ .code = 48, .lower = 'b', .upper = 'B' },  .{ .code = 49, .lower = 'n', .upper = 'N' },
    .{ .code = 50, .lower = 'm', .upper = 'M' },  .{ .code = 51, .lower = ',', .upper = '<' },
    .{ .code = 52, .lower = '.', .upper = '>' },  .{ .code = 53, .lower = '/', .upper = '?' },
    .{ .code = 57, .lower = ' ', .upper = ' ' },
};

fn keyByte(code: u32) ?u8 {
    for (key_pairs) |pair| if (pair.code == code) {
        const letter = pair.lower >= 'a' and pair.lower <= 'z';
        return if (shift_down != (caps_lock and letter)) pair.upper else pair.lower;
    };
    return null;
}

fn onKey(code: u32, pressed: bool) void {
    if (code == 42 or code == 54) {
        shift_down = pressed;
        return;
    }
    if (!pressed) return;
    if (code == 88) { // F12
        capture_requested = true;
        return;
    }
    if (code == 58) {
        caps_lock = !caps_lock;
        return;
    }
    if (active_field != .none) {
        switch (code) {
            1, 158, 28, 96, 352 => endEdit(),
            14 => eraseText(1),
            else => if (keyByte(code)) |byte| appendText(&.{byte}),
        }
        return;
    }
    // Blue button / F9: sign out, the only way back to the server screen once
    // credentials are stored.
    if (code == 67 and screen != .server and screen != .auth) {
        signOut();
        return;
    }
    navigate(code);
}

fn moveCursor(x: wl.Fixed, y: wl.Fixed) void {
    cursor_x = @floatFromInt(wl.toInt(x));
    cursor_y = @floatFromInt(wl.toInt(y));
    cursor_present = true;
}

fn onEvent(event: wl.Event) void {
    switch (event) {
        .key => |e| onKey(e.code, e.pressed),
        .text_commit => |text| appendText(text),
        .text_delete => |edit| eraseText(@max(1, edit.length)),
        .text_keysym => |e| if (e.pressed and active_field != .none) switch (e.sym) {
            0xff08 => eraseText(1),
            0xff0d, 0xff8d, 0xff1b => endEdit(),
            else => {},
        },
        .input_panel => |visible| {
            if (!visible and active_field != .none) active_field = .none;
        },
        .pointer_enter => |e| moveCursor(e.x, e.y),
        .pointer_motion => |e| moveCursor(e.x, e.y),
        .pointer_leave => {
            cursor_present = false;
            cursor_x = -1;
        },
        .pointer_button => |e| if (e.pressed and e.button == 0x110) {
            pointer_press = true;
        },
        .pointer_axis => |e| if (screen == .grid and e.axis == 0) {
            grid_scroll += @as(f32, @floatFromInt(wl.toInt(e.value))) * 1.4;
        },
        .close => wl.running = false,
        else => {},
    }
}

fn hovered(rect: loom.Rect) bool {
    return cursor_present and rect.contains(cursor_x, cursor_y);
}

// ------------------------------------------------------------------ views

var renderer: UiRenderer = undefined;

fn drawChrome(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const margin = 64 * scale;
    ctx.label(.{ .x = margin, .y = 30 * scale, .w = 700 * scale, .h = 52 * scale }, null, "Jellyfin", TEXT, 38 * scale);
    const where: []const u8 = switch (screen) {
        .server => "Choose a server",
        .auth => "Sign in",
        .quick => "Quick Connect",
        .home => fmt("{s} - {s}", .{ session.user_name.get(), session.url.get() }),
        .grid => grid_title.get(),
        .details => detail.title.get(),
        .season => fmt("{s} - {s}", .{ detail.title.get(), season_title.get() }),
    };
    ctx.label(.{ .x = margin + 160 * scale, .y = 40 * scale, .w = width - margin * 2 - 400 * scale, .h = 38 * scale }, null, where, ACCENT, 24 * scale);

    const busy = fetcher.pending();
    if (busy != 0)
        ctx.label(.{ .x = width - 260 * scale, .y = 40 * scale, .w = 200 * scale, .h = 32 * scale }, null, fmt("{d} loading", .{busy}), DIM, 20 * scale);

    const hint = if (status.len != 0)
        status.get()
    else switch (screen) {
        .home, .grid => "Arrows move  -  OK selects  -  Back returns  -  F9 signs out",
        else => "Arrows move  -  OK selects  -  Back returns",
    };
    ctx.label(
        .{ .x = margin, .y = height - 46 * scale, .w = width - margin * 2, .h = 32 * scale },
        null,
        hint,
        if (status.len == 0) DIM else if (status_error) RED else GREEN,
        19 * scale,
    );
}

fn drawButton(ctx: *loom.Context, rect: loom.Rect, label: []const u8, index: usize, scale: f32) void {
    const hot = hovered(rect);
    ctx.fill(rect, null, if (hot) HOT else CARD, 12 * scale);
    ctx.stroke(rect, null, if (focus == index) ACCENT else BORDER, if (focus == index) 4 * scale else 2 * scale, 12 * scale);
    ctx.label(.{ .x = rect.x + 24 * scale, .y = rect.y + (rect.h - 30 * scale) / 2, .w = rect.w - 48 * scale, .h = 38 * scale }, rect, label, TEXT, 25 * scale);
    if (hot and pointer_press) {
        focus = index;
        activate();
    }
}

fn drawField(ctx: *loom.Context, rect: loom.Rect, label: []const u8, which: EditField, index: usize, scale: f32) void {
    const hot = hovered(rect);
    const editing = active_field == which;
    const lit = focus == index or editing;
    ctx.label(.{ .x = rect.x, .y = rect.y - 36 * scale, .w = rect.w, .h = 30 * scale }, null, label, DIM, 20 * scale);
    ctx.fill(rect, null, if (editing) SELECTED else if (hot) HOT else CARD, 10 * scale);
    ctx.stroke(rect, null, if (lit) ACCENT else BORDER, if (lit) 4 * scale else 2 * scale, 10 * scale);
    const target = field(which);
    const contents = if (which == .password) password_mask[0..target.len] else target.get();
    ctx.label(
        .{ .x = rect.x + 22 * scale, .y = rect.y + 17 * scale, .w = rect.w - 44 * scale, .h = 38 * scale },
        rect,
        if (contents.len == 0) "Press OK to type" else contents,
        if (contents.len == 0) DIM else TEXT,
        24 * scale,
    );
    if (hot and pointer_press) {
        focus = index;
        beginEdit(which, rect);
    }
}

/// One poster card. `index` is the focus identity for pointer clicks, and
/// `on_click` decides what a click means, since a card opens a grid on one
/// screen and details on another.
fn ellipsize(text: []const u8, width: f32, size: f32) []const u8 {
    if (renderer.measure(text, size) <= width) return text;
    var take = text.len;
    while (take > 1 and renderer.measure(text[0..take], size) > width - renderer.measure("...", size))
        take -= 1;
    return fmt("{s}...", .{text[0..take]});
}

fn drawCard(ctx: *loom.Context, rect: loom.Rect, clip: loom.Rect, card: *const Card, focused: bool, scale: f32) bool {
    const hot = hovered(rect) and clip.contains(cursor_x, cursor_y);
    const art = loom.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h - 78 * scale };
    if (poster(card.poster_id.get(), card.poster_tag.get())) |slot| {
        ctx.textured(art, clip, slot.texture, coverUv(slot, art), WHITE, 10 * scale);
    } else {
        ctx.fill(art, clip, if (hot) HOT else CARD, 10 * scale);
        ctx.label(
            .{ .x = art.x + 14 * scale, .y = art.y + art.h / 2 - 16 * scale, .w = art.w - 28 * scale, .h = 32 * scale },
            loom.Rect.intersect(art, clip),
            if (card.present) card.title.get() else "",
            DIM,
            19 * scale,
        );
    }
    if (focused) ctx.stroke(art.inset(-4 * scale), clip, ACCENT, 4 * scale, 12 * scale);

    if (card.progress > 1) {
        const bar = loom.Rect{ .x = art.x, .y = art.y + art.h - 8 * scale, .w = art.w, .h = 6 * scale };
        ctx.fill(bar, clip, BORDER, 3 * scale);
        ctx.fill(.{ .x = bar.x, .y = bar.y, .w = bar.w * @min(card.progress, 100) / 100, .h = bar.h }, clip, ACCENT, 3 * scale);
    }
    ctx.label(.{ .x = rect.x, .y = art.y + art.h + 12 * scale, .w = rect.w, .h = 32 * scale }, loom.Rect.intersect(rect, clip), ellipsize(card.title.get(), rect.w, 21 * scale), if (focused) TEXT else DIM, 21 * scale);
    ctx.label(.{ .x = rect.x, .y = art.y + art.h + 44 * scale, .w = rect.w, .h = 28 * scale }, loom.Rect.intersect(rect, clip), ellipsize(card.subtitle.get(), rect.w, 17 * scale), DIM, 17 * scale);
    return hot and pointer_press;
}

fn drawServer(ctx: *loom.Context, width: f32, scale: f32) void {
    const panel = loom.Rect{ .x = 270 * scale, .y = 150 * scale, .w = width - 540 * scale, .h = 800 * scale };
    ctx.fill(panel, null, PANEL, 18 * scale);
    ctx.stroke(panel, null, BORDER, 2 * scale, 18 * scale);
    const x = panel.x + 54 * scale;
    const w = panel.w - 108 * scale;
    ctx.label(.{ .x = x, .y = panel.y + 34 * scale, .w = w, .h = 44 * scale }, panel, if (discovering) "Searching the network..." else "Discovered on this network", TEXT, 28 * scale);

    var y = panel.y + 92 * scale;
    for (0..discovered_count) |index| {
        const rect = loom.Rect{ .x = x, .y = y, .w = w, .h = 92 * scale };
        const hot = hovered(rect);
        ctx.fill(rect, panel, if (hot) HOT else CARD, 13 * scale);
        ctx.stroke(rect, panel, if (focus == index) ACCENT else BORDER, if (focus == index) 4 * scale else 2 * scale, 13 * scale);
        ctx.fill(.{ .x = rect.x + 22 * scale, .y = rect.y + 24 * scale, .w = 44 * scale, .h = 44 * scale }, rect, ACCENT, 22 * scale);
        ctx.label(.{ .x = rect.x + 90 * scale, .y = rect.y + 14 * scale, .w = w - 120 * scale, .h = 36 * scale }, rect, discovered[index].name.get(), TEXT, 26 * scale);
        ctx.label(.{ .x = rect.x + 90 * scale, .y = rect.y + 52 * scale, .w = w - 120 * scale, .h = 30 * scale }, rect, discovered[index].address.get(), DIM, 20 * scale);
        if (hot and pointer_press) {
            focus = index;
            activate();
        }
        y += 104 * scale;
    }
    if (discovered_count == 0)
        ctx.label(.{ .x = x, .y = y + 10 * scale, .w = w, .h = 34 * scale }, panel, if (discovering) "..." else "Nothing found yet.", DIM, 21 * scale);

    y = panel.y + 470 * scale;
    ctx.label(.{ .x = x, .y = y - 86 * scale, .w = w, .h = 34 * scale }, panel, "or enter a server address", DIM, 22 * scale);
    url_rect = .{ .x = x, .y = y, .w = w, .h = 70 * scale };
    drawField(ctx, url_rect, "Server URL", .url, discovered_count, scale);
    drawButton(ctx, .{ .x = x, .y = y + 110 * scale, .w = 300 * scale, .h = 70 * scale }, "Connect", discovered_count + 1, scale);
    drawButton(ctx, .{ .x = x + 330 * scale, .y = y + 110 * scale, .w = 300 * scale, .h = 70 * scale }, "Search again", discovered_count + 2, scale);
}

fn drawAuth(ctx: *loom.Context, width: f32, scale: f32) void {
    const panel = loom.Rect{ .x = 430 * scale, .y = 180 * scale, .w = width - 860 * scale, .h = 680 * scale };
    ctx.fill(panel, null, PANEL, 18 * scale);
    ctx.stroke(panel, null, BORDER, 2 * scale, 18 * scale);
    const x = panel.x + 64 * scale;
    const w = panel.w - 128 * scale;
    ctx.label(.{ .x = x, .y = panel.y + 42 * scale, .w = w, .h = 40 * scale }, panel, session.url.get(), TEXT, 26 * scale);
    username_rect = .{ .x = x, .y = panel.y + 180 * scale, .w = w, .h = 70 * scale };
    password_rect = .{ .x = x, .y = panel.y + 320 * scale, .w = w, .h = 70 * scale };
    drawField(ctx, username_rect, "Username", .username, 0, scale);
    drawField(ctx, password_rect, "Password", .password, 1, scale);
    drawButton(ctx, .{ .x = x, .y = panel.y + 450 * scale, .w = 280 * scale, .h = 72 * scale }, "Sign in", 2, scale);
    drawButton(ctx, .{ .x = x + 310 * scale, .y = panel.y + 450 * scale, .w = 330 * scale, .h = 72 * scale }, "Quick Connect", 3, scale);
    ctx.label(.{ .x = x, .y = panel.y + 570 * scale, .w = w, .h = 34 * scale }, panel, "The access token is stored on this device, not the password.", DIM, 19 * scale);
}

fn drawQuick(ctx: *loom.Context, width: f32, scale: f32) void {
    const panel = loom.Rect{ .x = 470 * scale, .y = 200 * scale, .w = width - 940 * scale, .h = 640 * scale };
    ctx.fill(panel, null, PANEL, 18 * scale);
    ctx.stroke(panel, null, BORDER, 2 * scale, 18 * scale);
    ctx.label(.{ .x = panel.x + 70 * scale, .y = panel.y + 50 * scale, .w = panel.w - 140 * scale, .h = 42 * scale }, panel, "Enter this code in a signed-in Jellyfin client", TEXT, 25 * scale);
    const code = loom.Rect{ .x = panel.x + 150 * scale, .y = panel.y + 140 * scale, .w = panel.w - 300 * scale, .h = 160 * scale };
    ctx.fill(code, panel, CARD, 15 * scale);
    ctx.stroke(code, panel, ACCENT, 3 * scale, 15 * scale);
    const text = if (quick_code.len != 0) quick_code.get() else "------";
    // Centred by measuring, because the code is six digits in a proportional
    // font and eyeballing an offset is wrong at every scale.
    const size = 64 * scale;
    const half = renderer.measure(text, size) / 2;
    ctx.label(.{ .x = code.x + code.w / 2 - half, .y = code.y + 46 * scale, .w = code.w, .h = 80 * scale }, code, text, ACCENT, size);
    ctx.label(.{ .x = panel.x + 70 * scale, .y = panel.y + 340 * scale, .w = panel.w - 140 * scale, .h = 34 * scale }, panel, "Approval is polled every two seconds.", DIM, 20 * scale);
    drawButton(ctx, .{ .x = panel.x + 150 * scale, .y = panel.y + 440 * scale, .w = 260 * scale, .h = 72 * scale }, "Cancel", 0, scale);
}

/// A horizontal row of poster cards. Only the focused row scrolls; a TV row
/// holds few enough items that the whole row is one strip with an offset.
fn drawRow(ctx: *loom.Context, row: *const Row, id: usize, top: f32, width: f32, clip: loom.Rect, scale: f32) void {
    const margin = 64 * scale;
    const card_w = @as(f32, if (row.wide) 356 else 200) * scale;
    const card_h = @as(f32, if (row.wide) 278 else 378) * scale;
    const gap = 26 * scale;
    ctx.label(.{ .x = margin, .y = top, .w = 600 * scale, .h = 36 * scale }, clip, row.title, if (row_focus == id) TEXT else DIM, 25 * scale);
    const strip = loom.Rect{ .x = margin, .y = top + 46 * scale, .w = width - margin * 2, .h = card_h };

    if (row.count == 0) {
        ctx.label(.{ .x = margin, .y = strip.y + 30 * scale, .w = 700 * scale, .h = 32 * scale }, clip, if (row.loading) "Loading..." else "Nothing here", DIM, 20 * scale);
        return;
    }

    // Keep the focused card on screen by shifting the whole strip left.
    const visible: usize = @max(1, @as(usize, @intFromFloat(strip.w / (card_w + gap))));
    const first = if (col_focus[id] >= visible) col_focus[id] - visible + 1 else 0;
    for (first..row.count) |index| {
        const x = strip.x + @as(f32, @floatFromInt(index - first)) * (card_w + gap);
        if (x > strip.x + strip.w) break;
        const rect = loom.Rect{ .x = x, .y = strip.y, .w = card_w, .h = card_h };
        const focused = row_focus == id and col_focus[id] == index;
        if (drawCard(ctx, rect, clip, &row.cards[index], focused, scale)) {
            row_focus = id;
            col_focus[id] = index;
            activate();
        }
    }
}

fn drawHome(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const row_height = 470 * scale;
    // Rows scroll under the header, so everything here is clipped to the band
    // between it and the status line.
    const clip = loom.Rect{ .x = 0, .y = 108 * scale, .w = width, .h = height - 170 * scale };
    const first = row_focus -| 1;
    var top = 120 * scale - @as(f32, @floatFromInt(first)) * row_height;
    for (&rows, 0..) |*row, id| {
        if (top + row_height > clip.y and top < clip.y + clip.h)
            drawRow(ctx, row, id, top, width, clip, scale);
        top += row_height;
    }
}

fn drawGrid(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const margin = 64 * scale;
    const card_w = 200 * scale;
    const gap = 26 * scale;
    grid_rect = .{ .x = margin, .y = 120 * scale, .w = width - margin * 2, .h = height - 190 * scale };
    grid_columns = @max(1, @as(usize, @intFromFloat((grid_rect.w + gap) / (card_w + gap))));
    grid_row_height = 404 * scale;

    if (grid_total == 0) {
        ctx.label(.{ .x = margin, .y = grid_rect.y + 40 * scale, .w = 800 * scale, .h = 36 * scale }, null, "Loading library...", DIM, 24 * scale);
        return;
    }

    var list = loom.VirtualList.init(grid_rect, gridRows(), grid_row_height, grid_scroll);
    grid_scroll = list.scroll;
    const content = list.viewport;

    for (list.first..list.last) |row_index| {
        const row_rect = list.itemRect(row_index);
        for (0..grid_columns) |column| {
            const index = row_index * grid_columns + column;
            if (index >= grid_total) break;
            const rect = loom.Rect{
                .x = row_rect.x + @as(f32, @floatFromInt(column)) * (card_w + gap),
                .y = row_rect.y,
                .w = card_w,
                .h = grid_row_height - 26 * scale,
            };
            const card = gridCard(index) orelse &blank_card;
            if (drawCard(ctx, rect, content, card, index == grid_selected, scale)) {
                grid_selected = index;
                activate();
            }
        }
        // One request per visible row is enough to walk the window forward
        // while scrolling with the pointer, which never calls `moveGrid`.
        requestPage(@intCast(@min(row_index * grid_columns, grid_total -| 1)));
    }

    const track = loom.Rect{ .x = grid_rect.x + grid_rect.w + 12 * scale - 12 * scale, .y = grid_rect.y, .w = 4 * scale, .h = grid_rect.h };
    if (list.maxScroll() > 0) {
        const thumb_h = @max(40 * scale, track.h * grid_rect.h / (@as(f32, @floatFromInt(gridRows())) * grid_row_height));
        ctx.fill(track, null, BORDER, track.w / 2);
        ctx.fill(.{ .x = track.x, .y = track.y + (track.h - thumb_h) * (grid_scroll / list.maxScroll()), .w = track.w, .h = thumb_h }, null, ACCENT, track.w / 2);
    }
    ctx.label(.{ .x = width - 340 * scale, .y = 46 * scale, .w = 260 * scale, .h = 30 * scale }, null, fmt("{d} of {d}", .{ grid_selected + 1, grid_total }), DIM, 19 * scale);
}

fn drawDetails(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const margin = 64 * scale;
    const art = loom.Rect{ .x = margin, .y = 130 * scale, .w = 340 * scale, .h = 510 * scale };
    if (poster(detail.poster_id.get(), detail.poster_tag.get())) |slot|
        ctx.textured(art, null, slot.texture, coverUv(slot, art), WHITE, 16 * scale)
    else {
        ctx.fill(art, null, CARD, 16 * scale);
        ctx.label(.{ .x = art.x + 20 * scale, .y = art.y + art.h / 2, .w = art.w - 40 * scale, .h = 32 * scale }, art, "No artwork", DIM, 20 * scale);
    }

    const x = art.x + art.w + 60 * scale;
    const w = width - x - margin;
    ctx.label(.{ .x = x, .y = 140 * scale, .w = w, .h = 62 * scale }, null, detail.title.get(), TEXT, 44 * scale);
    ctx.label(.{ .x = x, .y = 210 * scale, .w = w, .h = 34 * scale }, null, detail.subtitle.get(), GREEN, 22 * scale);
    ctx.label(.{ .x = x, .y = 250 * scale, .w = w, .h = 34 * scale }, null, detail_extra.get(), DIM, 20 * scale);
    drawWrapped(ctx, .{ .x = x, .y = 310 * scale, .w = w, .h = 200 * scale }, detail_overview.get(), 22 * scale);

    if (detail.is("Series")) {
        if (seasons_row.count == 0) {
            ctx.label(.{ .x = x, .y = 560 * scale, .w = w, .h = 34 * scale }, null, if (seasons_row.loading) "Loading seasons..." else "No seasons", DIM, 22 * scale);
            return;
        }
        ctx.label(.{ .x = x, .y = 545 * scale, .w = w, .h = 34 * scale }, null, "Seasons", DIM, 22 * scale);
        for (0..seasons_row.count) |index| {
            const rect = loom.Rect{ .x = x + @as(f32, @floatFromInt(index)) * 220 * scale, .y = 595 * scale, .w = 200 * scale, .h = 80 * scale };
            if (rect.x + rect.w > width - margin) break;
            const hot = hovered(rect);
            ctx.fill(rect, null, if (hot) HOT else CARD, 12 * scale);
            ctx.stroke(rect, null, if (focus == index) ACCENT else BORDER, if (focus == index) 4 * scale else 2 * scale, 12 * scale);
            ctx.label(.{ .x = rect.x + 18 * scale, .y = rect.y + 14 * scale, .w = rect.w - 36 * scale, .h = 34 * scale }, rect, seasons_row.cards[index].title.get(), TEXT, 22 * scale);
            ctx.label(.{ .x = rect.x + 18 * scale, .y = rect.y + 46 * scale, .w = rect.w - 36 * scale, .h = 28 * scale }, rect, seasons_row.cards[index].subtitle.get(), DIM, 17 * scale);
            if (hot and pointer_press) {
                focus = index;
                activate();
            }
        }
        return;
    }

    drawButton(ctx, .{ .x = x, .y = 570 * scale, .w = 250 * scale, .h = 74 * scale }, "Play", 0, scale);
    drawButton(ctx, .{ .x = x + 280 * scale, .y = 570 * scale, .w = 250 * scale, .h = 74 * scale }, "Back", 1, scale);
    ctx.label(.{ .x = x, .y = height - 110 * scale, .w = w, .h = 30 * scale }, null, stream_url.get(), DIM, 17 * scale);
}

fn drawSeason(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const margin = 64 * scale;
    const list_rect = loom.Rect{ .x = margin, .y = 120 * scale, .w = width - margin * 2, .h = height - 200 * scale };
    ctx.fill(list_rect, null, PANEL, 16 * scale);
    ctx.stroke(list_rect, null, BORDER, 2 * scale, 16 * scale);
    if (episodes_row.count == 0) {
        ctx.label(.{ .x = margin + 30 * scale, .y = list_rect.y + 40 * scale, .w = 700 * scale, .h = 34 * scale }, list_rect, if (episodes_row.loading) "Loading episodes..." else "No episodes", DIM, 23 * scale);
        return;
    }

    const height_per = 118 * scale;
    var list = loom.VirtualList.init(list_rect.inset(10 * scale), episodes_row.count, height_per, @as(f32, @floatFromInt(episode_selected)) * height_per - list_rect.h / 2);
    const content = list.viewport;
    for (list.first..list.last) |index| {
        const raw = list.itemRect(index);
        const row = loom.Rect{ .x = raw.x + 10 * scale, .y = raw.y + 6 * scale, .w = raw.w - 20 * scale, .h = raw.h - 12 * scale };
        const hot = hovered(row);
        const focused = index == episode_selected;
        const card = &episodes_row.cards[index];
        ctx.fill(row, content, if (focused) SELECTED else if (hot) HOT else CARD, 11 * scale);
        if (focused) ctx.stroke(row, content, ACCENT, 4 * scale, 11 * scale);
        const clip = loom.Rect.intersect(row, content);
        ctx.label(.{ .x = row.x + 26 * scale, .y = row.y + 22 * scale, .w = row.w - 52 * scale, .h = 36 * scale }, clip, card.subtitle.get(), TEXT, 25 * scale);
        ctx.label(.{ .x = row.x + 26 * scale, .y = row.y + 64 * scale, .w = row.w - 52 * scale, .h = 30 * scale }, clip, card.runtime.get(), DIM, 18 * scale);
        if (card.progress > 1) {
            const bar = loom.Rect{ .x = row.x + 26 * scale, .y = row.y + row.h - 14 * scale, .w = row.w - 52 * scale, .h = 5 * scale };
            ctx.fill(.{ .x = bar.x, .y = bar.y, .w = bar.w * @min(card.progress, 100) / 100, .h = bar.h }, clip, ACCENT, 2 * scale);
        }
        if (hot and pointer_press) {
            episode_selected = index;
            activate();
        }
    }
}

/// Greedy word wrap against the real glyph advances. The renderer clips a
/// label to its rect but does not break it, so an overview needs splitting
/// before it becomes draw commands.
fn drawWrapped(ctx: *loom.Context, rect: loom.Rect, text: []const u8, size: f32) void {
    var y = rect.y;
    var rest = text;
    while (rest.len != 0 and y < rect.y + rect.h) {
        var take = rest.len;
        while (take > 0 and renderer.measure(rest[0..take], size) > rect.w) {
            take = std.mem.lastIndexOfScalar(u8, rest[0..take], ' ') orelse break;
        }
        if (take == 0) break;
        ctx.label(.{ .x = rect.x, .y = y, .w = rect.w, .h = size * 1.4 }, null, rest[0..take], TEXT, size);
        rest = std.mem.trimStart(u8, rest[take..], " ");
        y += size * 1.45;
    }
}

fn buildUi(ctx: *loom.Context) void {
    const width: f32 = @floatFromInt(gl.width);
    const height: f32 = @floatFromInt(gl.height);
    const scale = @min(width / 1920.0, height / 1080.0);
    scratch_used = 0;
    poster_requests = 0;
    frame_index += 1;

    ctx.begin(width, height);
    ctx.fill(.{ .w = width, .h = height }, null, BG, 0);
    drawChrome(ctx, width, height, scale);
    switch (screen) {
        .server => drawServer(ctx, width, scale),
        .auth => drawAuth(ctx, width, scale),
        .quick => drawQuick(ctx, width, scale),
        .home => drawHome(ctx, width, height, scale),
        .grid => drawGrid(ctx, width, height, scale),
        .details => drawDetails(ctx, width, height, scale),
        .season => drawSeason(ctx, width, height, scale),
    }
    renderer.draw(ctx.commands.items, width, height);
    pointer_press = false;
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// This application's own backbuffer as a PPM. Same path as uidemo's F12, and
/// the only way to check on-device rendering without the VNC grab.
fn captureFrame(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const width: usize = gl.width;
    const height: usize = gl.height;
    const rgba = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(rgba);
    const row = try allocator.alloc(u8, width * 3);
    defer allocator.free(row);
    glReadPixels(0, 0, @intCast(width), @intCast(height), GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var header: [64]u8 = undefined;
    try file.writeStreamingAll(io, try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ width, height }));
    for (0..height) |output_y| {
        const source = rgba[(height - 1 - output_y) * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            row[x * 3 + 0] = source[x * 4 + 0];
            row[x * 3 + 1] = source[x * 4 + 1];
            row[x * 3 + 2] = source[x * 4 + 2];
        }
        try file.writeStreamingAll(io, row);
    }
    std.debug.print("captured OpenGL framebuffer to {s} ({d}x{d})\n", .{ path, width, height });
}

fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.sliceTo(std.c.getenv(name) orelse return null, 0);
}

fn isTty(fd: i32) bool {
    var probe: [64]u8 = undefined;
    return @as(isize, @bitCast(linux.ioctl(fd, 0x5401, @intFromPtr(&probe)))) >= 0; // TCGETS
}

/// Launched from the TV's app list there is no terminal, so an installed app's
/// output goes nowhere and a failure is invisible. Same fallback as `ndlplay`:
/// send stderr to a file next to everything else this app writes.
fn logToFile() void {
    if (isTty(2)) return;
    var path: [512]u8 = undefined;
    // `conf/` rather than the app directory itself: the package can only make
    // the subdirectories world-writable, and the app runs as a jail uid that
    // owns none of them. /tmp is the fallback when even that fails.
    const name = std.fmt.bufPrintZ(&path, "{s}/conf/jellyfin.log", .{api.storeRoot()}) catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    var rc = linux.openat(linux.AT.FDCWD, name, flags, 0o644);
    if (@as(isize, @bitCast(rc)) < 0) rc = linux.openat(linux.AT.FDCWD, "/tmp/jellyfin.log", flags, 0o644);
    if (@as(isize, @bitCast(rc)) < 0) return;
    _ = linux.dup2(@intCast(rc), 2);
}

// A remote, replayed. There is no way to click through this app without a TV
// or a person, so `UI_SCRIPT=drrob` presses those buttons a few frames apart
// and `UI_CAPTURE` saves the screen it ends on. Letters are the four arrows,
// `o` for OK and `b` for Back; `.` waits one more beat, which is what a screen
// that is still fetching needs.
var script: []const u8 = "";
var script_at: usize = 0;
var script_wait: u32 = 0;

/// Frames between scripted presses. Long enough that a request started by one
/// press has landed before the next, on a LAN.
const script_beat = 45;

fn stepScript() bool {
    if (script_at == script.len) return fetcher.pending() == 0;
    // Never press a button while a request is outstanding: whether discovery
    // has answered decides what the focused control even is.
    if (fetcher.pending() != 0) return false;
    if (script_wait != 0) {
        script_wait -= 1;
        return false;
    }
    const key: u32 = switch (script[script_at]) {
        'u' => 103,
        'd' => 108,
        'l' => 105,
        'r' => 106,
        'o' => 28,
        'b' => 1,
        else => 0,
    };
    script_at += 1;
    script_wait = script_beat;
    if (key != 0) onKey(key, true);
    std.debug.print("script: '{c}' -> {s} focus={d} row={d} servers={d} depth={d}\n", .{ script[script_at - 1], @tagName(screen), focus, row_focus, discovered_count, depth });
    return false;
}

pub fn main(init: std.process.Init) !void {
    api.deviceId(&session.device_id);
    api.initStore(init.io, init.gpa);
    logToFile();
    const restored = api.load(&session);

    wl.on_event = onEvent;
    const appid = std.c.getenv("APPID") orelse @as([*:0]const u8, "dev.hookedbehemoth.jellyfin");
    try gl.init(appid, "Jellyfin", 0, 0);
    glClearColor = gl.proc(@TypeOf(glClearColor), "glClearColor");
    glClear = gl.proc(@TypeOf(glClear), "glClear");
    glViewport = gl.proc(@TypeOf(glViewport), "glViewport");
    glReadPixels = gl.proc(@TypeOf(glReadPixels), "glReadPixels");
    glViewport(0, 0, @intCast(gl.width), @intCast(gl.height));
    glClearColor(9.0 / 255.0, 13.0 / 255.0, 22.0 / 255.0, 1);

    try api.initImages();
    renderer = try UiRenderer.init(init.gpa, init.io, null);
    defer renderer.deinit();
    var ctx = loom.Context.init(init.gpa);
    defer ctx.deinit();

    try fetcher.init(init.gpa, init.io);
    defer fetcher.deinit();
    fetcher.setSession(session);

    // A stored token skips straight to the home rows; JELLYFIN_ADDRESS makes a
    // fresh install land on the sign-in screen without typing a URL on a TV.
    if (restored) {
        depth = 0;
        screen = .home;
        setStatus("Signed in as {s}", .{session.user_name.get()});
        loadHome();
    } else {
        // Development convenience, and the only way a script can sign in: the
        // fields start filled from the environment that `zig build run-host`
        // inherits. Nothing is read from there once a token is stored.
        if (env("JELLYFIN_ADDRESS")) |address| {
            server_url.set(address);
            session.url.set(address);
            fetcher.setSession(session);
        }
        if (env("JELLYFIN_USER")) |user| username.set(user);
        if (env("JELLYFIN_PASSWORD")) |secret| password.set(secret);
        discovering = true;
        simple(.discover);
    }

    const capture_path = env("UI_CAPTURE");
    script = env("UI_SCRIPT") orelse "";
    // Without a script, hold long enough for discovery's three timeouts.
    var capture_after: u32 = if (capture_path != null and script.len == 0) 240 else 0;
    while (wl.poll()) {
        pump();
        glClear(GL_COLOR_BUFFER_BIT);
        buildUi(&ctx);
        if (script.len != 0 and stepScript() and capture_path != null and capture_after == 0)
            capture_after = script_beat;
        if (capture_after > 0) {
            capture_after -= 1;
            if (capture_after == 0) capture_requested = true;
        }
        if (capture_requested) {
            captureFrame(init.gpa, init.io, capture_path orelse "jellyfin-capture.ppm") catch |err|
                std.log.err("capture failed: {s}", .{@errorName(err)});
            capture_requested = false;
            if (capture_path != null) wl.running = false;
        }
        gl.swap();
    }
}
