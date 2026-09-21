//! A Jellyfin client for the TV: discovery, sign-in, home rows, a virtual
//! library grid and the path down to a single episode.
//!
//! The UI is one instanced batch with rasterised glyphs, remote/pointer
//! handling, and virtual-list geometry. Every screen is backed by a real
//! server, so this file is mostly
//! about keeping the render thread free of that: `api.Fetcher` runs the
//! requests and image decoding on worker threads, results wake the event loop,
//! and screen state is plain fixed-size storage that a task result is copied
//! into. Nothing the renderer touches is owned by a worker.
//!
//! Playback is per-platform: the TV runs a runtime FFmpeg demuxer into LG's
//! Starfish pipeline (jellyfin/player.zig), the desktop runs the system
//! libmpv into our own GL context (jellyfin/player_mpv.zig).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const gl = @import("gl.zig");
const wl = @import("sdl.zig");
const luna = @import("luna.zig");
const loom = @import("loom/loom.zig");
const UiRenderer = @import("ui_renderer.zig").Renderer;
const api = @import("jellyfin/api.zig");
// One backend per platform. The TV feeds LG's Starfish pipeline straight from
// an FFmpeg demuxer, which keeps compressed packets on a path that never
// touches this process; the desktop drives the system libmpv and renders into
// our own GL context.
const player = if (builtin.cpu.arch == .arm)
    @import("jellyfin/player.zig")
else
    @import("jellyfin/player_mpv.zig");

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
const YELLOW: loom.Color = .{ 255, 206, 64, 255 };

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
    kind: api.ImageKind = .primary,
    requested_width: u32 = 0,
    requested_height: u32 = 0,
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
    return artwork(id, tag, .primary, poster_w, poster_h);
}

fn artwork(id: []const u8, tag: []const u8, kind: api.ImageKind, width: u32, height: u32) ?*const Slot {
    if (id.len == 0) return null;
    for (&slots) |*slot| {
        if (!std.mem.eql(u8, slot.id.get(), id) or !std.mem.eql(u8, slot.tag.get(), tag)) continue;
        if (slot.kind != kind or slot.requested_width != width or slot.requested_height != height) continue;
        slot.used = frame_index;
        return if (slot.texture != 0) slot else null;
    }
    if (poster_requests >= 4 or fetcher.pending() >= 24) return null;

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
    const claimed = victim orelse {
        // A navigation frame may still protect the previous screen's slots.
        // Advance that grace period once, even with no requests in flight.
        for (slots) |slot| if (!slot.loading and slot.used < frame_index) {
            wl.frame_requested = true;
            break;
        };
        return null;
    };
    const index: u32 = @intCast((@intFromPtr(claimed) - @intFromPtr(&slots)) / @sizeOf(Slot));

    const task = fetcher.submit(.poster, index) orelse return null;
    task.a.set(id);
    task.b.set(tag);
    task.start = width;
    task.limit = height;
    task.image_kind = kind;
    renderer.destroyTexture(claimed.texture);
    claimed.* = .{ .used = frame_index, .loading = true, .kind = kind, .requested_width = width, .requested_height = height };
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
    thumbnail_tag: api.Text(40) = .{},
    backdrop_id: api.Text(40) = .{},
    backdrop_tag: api.Text(40) = .{},
    title: api.Text(96) = .{},
    episode_title: api.Text(128) = .{},
    overview: api.Text(1024) = .{},
    rating: api.Text(32) = .{},
    subtitle: api.Text(72) = .{},
    kind: api.Text(16) = .{},
    runtime: api.Text(24) = .{},
    progress: f32 = 0,
    played: bool = false,
    remaining: ?u32 = null,
    present: bool = false,

    fn from(item: api.Item) Card {
        var card: Card = .{ .present = true, .progress = item.progress(), .played = item.finished() };
        if (std.mem.eql(u8, item.Type, "Season")) {
            card.remaining = if (card.played) 0 else if (item.UserData) |data| data.UnplayedItemCount orelse item.ChildCount else item.ChildCount;
        }
        card.id.set(item.Id);
        card.poster_id.set(item.posterId());
        card.poster_tag.set(item.posterTag());
        card.series_id.set(item.SeriesId orelse "");
        if (item.ImageTags) |tags| card.thumbnail_tag.set(tags.Primary orelse "");
        const backdrops = item.BackdropImageTags orelse &.{};
        const inherited = item.ParentBackdropImageTags orelse &.{};
        if (backdrops.len != 0) {
            card.backdrop_id.set(item.Id);
            card.backdrop_tag.set(backdrops[0]);
        } else if (inherited.len != 0) {
            card.backdrop_id.set(item.ParentBackdropItemId orelse "");
            card.backdrop_tag.set(inherited[0]);
        }
        setOverview(&card.overview, item.Overview orelse "");
        if (item.IndexNumber) |number| {
            card.episode_title.set(build("{d}. {s}", .{ number, item.Name }));
        } else card.episode_title.set(item.Name);
        if (item.CommunityRating) |rating| card.rating.set(build("{d:.1}", .{rating}));
        card.kind.set(item.Type);
        card.title.set(if (std.mem.eql(u8, item.Type, "Episode"))
            item.SeriesName orelse item.Name
        else
            item.Name);
        // Each `build` reuses one buffer, so every result is copied into the
        // card before the next call.
        card.subtitle.set(subtitleFor(item));
        if (item.RunTimeTicks) |ticks| {
            const minutes = item.minutes();
            card.runtime.set(if (minutes >= 60)
                if (minutes % 60 == 0) build("{d} hr", .{minutes / 60}) else build("{d} hr {d} min", .{ minutes / 60, minutes % 60 })
            else if (minutes > 0) build("{d} min", .{minutes}) else build("{d} sec", .{ticks / 10_000_000}));
        }
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
    if (std.mem.eql(u8, item.Type, "Series")) {
        const start = item.ProductionYear orelse dateYear(item.PremiereDate) orelse return "";
        if (dateYear(item.EndDate)) |end| {
            if (end > start) return build("{d}-{d}", .{ start, end });
        } else if (std.mem.eql(u8, item.Status orelse "", "Continuing")) return build("{d}-Present", .{start});
        return build("{d}", .{start});
    }
    if (std.mem.eql(u8, item.Type, "Season"))
        return build("{d} episodes", .{item.ChildCount orelse 0});
    if (item.RunTimeTicks != null and item.minutes() != 0) {
        if (item.ProductionYear) |year| if (year != 0)
            return build("{d}  -  {d}h {d:0>2}m", .{ year, item.minutes() / 60, item.minutes() % 60 });
        return build("{d}h {d:0>2}m", .{ item.minutes() / 60, item.minutes() % 60 });
    }
    return item.CollectionType orelse item.Type;
}

fn dateYear(date: ?[]const u8) ?u32 {
    const value = date orelse return null;
    if (value.len < 4) return null;
    const year = std.fmt.parseInt(u32, value[0..4], 10) catch return null;
    return if (year > 0) year else null;
}

fn setOverview(out: *api.Text(1024), text: []const u8) void {
    var input: usize = 0;
    var len: usize = 0;
    while (input < text.len and len < out.buffer.len - 1) {
        if (text[input] == '<') if (std.mem.indexOfScalar(u8, text[input..], '>')) |end| {
            const tag = std.mem.trim(u8, text[input + 1 .. input + end], " \t\r\n/");
            if (std.ascii.eqlIgnoreCase(tag, "br")) {
                out.buffer[len] = '\n';
                len += 1;
                input += end + 1;
                continue;
            }
        };
        out.buffer[len] = text[input];
        input += 1;
        len += 1;
    }
    out.len = len;
    out.buffer[len] = 0;
}

fn firstUnfinished(cards: []const Card) usize {
    for (cards, 0..) |card, index| if (!card.played) return index;
    return 0;
}

fn unfinishedSeasons(items: []const api.Item) u32 {
    var count: u32 = 0;
    for (items) |item| if (!item.finished()) {
        count += 1;
    };
    return count;
}

// Series UserData counts episodes, so fetch seasons to count unfinished seasons.
const SeriesStatus = struct {
    id: api.Text(40) = .{},
    count: ?u32 = null,
    loading: bool = false,
    used: u64 = 0,
    failed: bool = false,
};
var series_status: [128]SeriesStatus = @splat(.{});
var status_requests: u8 = 0;

fn remainingSeasons(card: *const Card) ?u32 {
    if (card.played) return 0;
    if (std.mem.eql(u8, card.id.get(), detail.id.get()) and !seasons_row.loading and (screen == .details or screen == .season)) {
        var count: u32 = 0;
        for (seasons_row.cards[0..seasons_row.count]) |season| if (!season.played) {
            count += 1;
        };
        return count;
    }
    var victim: usize = 0;
    var oldest: u64 = std.math.maxInt(u64);
    for (&series_status, 0..) |*entry, index| {
        if (std.mem.eql(u8, entry.id.get(), card.id.get())) {
            entry.used = frame_index;
            return entry.count;
        }
        if (!entry.loading and entry.used < oldest) {
            oldest = entry.used;
            victim = index;
        }
    }
    // Leave task slots available for opening a show/season while scrolling.
    if (status_requests >= 2 or oldest == std.math.maxInt(u64) or fetcher.pending() >= 24) return null;
    const task = request(.season_status, @intCast(victim)) orelse return null;
    const entry = &series_status[victim];
    entry.* = .{ .loading = true, .used = frame_index };
    entry.id = card.id;
    task.a.set(card.id.get());
    fetcher.start(task);
    status_requests += 1;
    return null;
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

const Screen = enum { server, auth, quick, home, grid, details, season, playback };
const EditField = enum { none, url, username, password };

const row_capacity = 24;
const Row = ItemRow(row_capacity);
fn ItemRow(comptime capacity: usize) type {
    return struct {
        title: []const u8,
        /// Libraries are 16:9 banners on the server, not posters. Cropping one to
        /// a portrait card cuts the library's name out of the middle of it.
        wide: bool = false,
        cards: [capacity]Card = @splat(.{}),
        count: usize = 0,
        loading: bool = false,

        fn fill(self: *@This(), items: []const api.Item) void {
            self.count = @min(items.len, capacity);
            for (items[0..self.count], self.cards[0..self.count]) |item, *card| card.* = .from(item);
            self.loading = false;
        }
    };
}

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
/// Back cancels the UI's interest in pending sign-in / Quick Connect replies.
var auth_generation: u32 = 0;

var screen: Screen = .server;
var focus: usize = 0;
var row_focus: usize = 0;
var col_focus: [rows.len]usize = @splat(0);
var home_scroll: f32 = 0;
var home_rect: loom.Rect = .{};
var home_row_height: f32 = 470;
var home_reveal = false;

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
        .scroll = switch (screen) {
            .home => home_scroll,
            .season => episode_scroll,
            else => grid_scroll,
        },
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
        .home => {
            screen = .home;
            home_scroll = entry.scroll;
        },
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
            select_unfinished_season = false;
        },
        .season => {
            detail = entry.series;
            openSeason(entry.card);
            episode_selected = entry.selected;
            episode_scroll = entry.scroll;
            select_unfinished_episode = false;
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
    return season_detail;
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
var detail_extra: api.Text(96) = .{};
var seasons_row: ItemRow(128) = .{ .title = "Seasons" };
var episodes_row: ItemRow(512) = .{ .title = "Episodes" };
var episode_selected: usize = 0;
var season_detail: Card = .{};
var episode_scroll: f32 = 0;
var episode_rect: loom.Rect = .{};
var episode_row_height: f32 = 170;
var episode_reveal = false;
var episode_jump = false;
var select_unfinished_season = false;
var select_unfinished_episode = false;
var stream_url: api.Text(256) = .{};
var playback_title: api.Text(160) = .{};
var playback_paused = false;
/// The player chrome is deliberately transient: it never covers a scene for
/// more than three seconds unless playback is paused.
var playback_controls_until: u64 = 0;
const playback_controls_ns = 3 * std.time.ns_per_s;

// Text entry, remote, and pointer input.
var server_url: api.Text(256) = .{};
var username: api.Text(256) = .{};
var password: api.Text(256) = .{};
var password_mask: [256]u8 = @splat('*');
var url_rect: loom.Rect = .{};
var username_rect: loom.Rect = .{};
var password_rect: loom.Rect = .{};
var active_field: EditField = .none;
var capture_requested = false;

var cursor_x: f32 = -1;
var cursor_y: f32 = -1;
var cursor_present = false;
var pointer_press = false;

var status: api.Text(200) = .{};
var status_error = false;

fn setStatus(comptime pattern: []const u8, args: anytype) void {
    wl.frame_requested = true;
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
    return fetcher.submit(job, if (isAuthJob(job)) auth_generation else tag);
}

fn isAuthJob(job: api.Job) bool {
    return switch (job) {
        .login, .quick_initiate, .quick_poll, .quick_authenticate => true,
        else => false,
    };
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
    select_unfinished_season = true;
    detail = card;
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
    select_unfinished_episode = true;
    episode_jump = false;
    season_detail = card;
    episode_scroll = 0;
    episode_reveal = true;
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
    auth_generation +%= 1;
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
    home_scroll = 0;
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
    series_status = @splat(.{});
    auth_generation +%= 1;
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
    if (isAuthJob(task.job) and task.tag != auth_generation) return;
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
            if (!std.mem.eql(u8, task.a.get(), detail.id.get())) return;
            detail = .from(task.one);
            detail_extra.set(task.one.OfficialRating orelse "");
        },
        .seasons => if (std.mem.eql(u8, task.a.get(), detail.id.get())) {
            seasons_row.fill(task.list.Items);
            if (select_unfinished_season and screen == .details) {
                focus = firstUnfinished(seasons_row.cards[0..seasons_row.count]);
                select_unfinished_season = false;
            }
            for (&series_status) |*entry| if (std.mem.eql(u8, entry.id.get(), task.a.get())) {
                entry.count = unfinishedSeasons(task.list.Items);
            };
        },
        .season_status => {
            const entry = &series_status[task.tag];
            if (!std.mem.eql(u8, task.a.get(), entry.id.get())) return;
            entry.count = unfinishedSeasons(task.list.Items);
            entry.loading = false;
        },
        .episodes => if (std.mem.eql(u8, task.b.get(), season_detail.id.get())) {
            episodes_row.fill(task.list.Items);
            if (select_unfinished_episode and screen == .season) {
                episode_selected = firstUnfinished(episodes_row.cards[0..episodes_row.count]);
                episode_reveal = true;
                episode_jump = true;
                select_unfinished_episode = false;
            }
        },
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
        .season_status => {
            const entry = &series_status[task.tag];
            if (std.mem.eql(u8, entry.id.get(), task.a.get())) {
                entry.loading = false;
                entry.failed = true;
            }
        },
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
        if (task.job != .quick_poll or !task.ok() or task.quick.Authenticated)
            wl.frame_requested = true;
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
    auth_generation +%= 1;
    server_url.set(address);
    session.url.set(address);
    fetcher.setSession(session);
    screen = .auth;
    focus = 0;
    setStatus("Sign in to {s}", .{address});
}

fn goBack() void {
    if (screen == .playback) {
        player.stop();
        playback_paused = false;
        screen = .details;
        setStatus("Stopped playback", .{});
        return;
    }
    if (active_field != .none) {
        endEdit();
        return;
    }
    switch (screen) {
        .server => wl.running = false,
        .auth => {
            auth_generation +%= 1;
            screen = .server;
            focus = 0;
        },
        .quick => {
            auth_generation +%= 1;
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
            startPlayback(episodes_row.cards[episode_selected].id.get(), episodes_row.cards[episode_selected].episode_title.get());
        },
        .playback => activatePlayback(),
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
        startPlayback(detail.id.get(), detail.title.get());
    }
}

fn startPlayback(id: []const u8, title: []const u8) void {
    var buffer: [256]u8 = undefined;
    stream_url.set(api.streamUrl(&session, id, &buffer));
    if (stream_url.len == 0) return setError("Could not build a stream URL", .{});
    // The transcode request carries the hardware capability constraints. Keep
    // this comfortably above a long reverse-proxy address plus access token;
    // bufPrint otherwise returns an empty URL without an error at this layer.
    var transcode_buffer: [2048]u8 = undefined;
    const transcode_url = api.transcodeUrl(&session, id, &transcode_buffer);
    player.play(stream_url.get(), transcode_url, gl.width, gl.height) catch |err| {
        setError("Playback failed: {s}: {s}", .{ @errorName(err), player.lastError() });
        return;
    };
    playback_title.set(title);
    playback_paused = false;
    focus = play_pause_index;
    playback_controls_until = nowNs() + playback_controls_ns;
    screen = .playback;
    setStatus("Playing", .{});
}

fn togglePlayback() void {
    if (playback_paused) {
        player.resumePlayback();
        playback_paused = false;
        setStatus("Playing", .{});
    } else {
        player.pause();
        playback_paused = true;
        setStatus("Paused", .{});
    }
}

/// How many focusable things the current screen has, so navigation clamps
/// without every caller knowing the layout.
fn focusCount() usize {
    return switch (screen) {
        .server => discovered_count + 3,
        .auth => 4,
        .quick => 1,
        .playback => playback_buttons.len,
        .details => if (detail.is("Series")) @max(1, seasons_row.count) else 1,
        else => 1,
    };
}

fn navigate(code: u32) void {
    if (wl.isBackKey(code)) return goBack();
    switch (code) {
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
        .season => {
            switch (direction) {
                .up => episode_selected -|= 1,
                .down => episode_selected = @min(episode_selected + 1, episodes_row.count -| 1),
                else => {},
            }
            episode_reveal = true;
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
        .playback => switch (direction) {
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
    home_reveal = true;
    switch (direction) {
        .up => row_focus -|= 1,
        .down => row_focus = @min(row_focus + 1, rows.len - 1),
        .left => col_focus[row_focus] -|= 1,
        .right => col_focus[row_focus] = @min(col_focus[row_focus] + 1, rows[row_focus].count -| 1),
    }
    col_focus[row_focus] = @min(col_focus[row_focus], rows[row_focus].count -| 1);
}

fn moveGrid(direction: Direction) void {
    const next = gridMove(grid_selected, grid_total, grid_columns, direction);
    if (next == grid_selected) return;
    grid_selected = next;
    const list = loom.VirtualList.init(grid_rect, gridRows(), grid_row_height, grid_scroll);
    grid_scroll = list.scrollToReveal(grid_selected / grid_columns);
    requestPage(@intCast(grid_selected));
}

fn gridMove(selected: usize, total: usize, columns: usize, direction: Direction) usize {
    if (total == 0) return selected;
    return switch (direction) {
        .left => selected -| 1,
        .right => @min(selected + 1, total - 1),
        .up => if (selected >= columns) selected - columns else selected,
        .down => if (selected + columns < total) selected + columns else selected,
    };
}

fn gridRows() usize {
    return (grid_total + grid_columns - 1) / grid_columns;
}

// ------------------------------------------------------------------ input

fn onKey(code: u32, pressed: bool) void {
    if (!pressed) return;
    wl.frame_requested = true;
    if (wl.isBackKey(code)) return goBack();
    if (screen == .playback) {
        if (code == 103) { // Up dismisses player chrome immediately.
            playback_controls_until = 0;
            return;
        }
        playback_controls_until = nowNs() + playback_controls_ns;
    }
    if (code == 88) { // F12
        capture_requested = true;
        return;
    }
    if (active_field != .none) {
        switch (code) {
            1, 158, 28, 96, 352 => endEdit(),
            14 => eraseText(1),
            else => {},
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

fn onEvent(event: wl.AppEvent) void {
    switch (event) {
        .key => {}, // Key releases do not change the UI.
        .close => {},
        .pointer_button => |e| {
            if (e.pressed) wl.frame_requested = true;
        },
        else => wl.frame_requested = true,
    }
    switch (event) {
        .key => |e| onKey(e.code, e.pressed),
        .text_commit => |text| appendText(text),
        .pointer_enter => |e| moveCursor(e.x, e.y),
        .pointer_motion => |e| moveCursor(e.x, e.y),
        .pointer_leave => {
            cursor_present = false;
            cursor_x = -1;
        },
        .pointer_button => |e| if (e.pressed and e.button == 0x110) {
            pointer_press = true;
        },
        .pointer_axis => |e| if (e.axis == 0) {
            const delta = @as(f32, @floatFromInt(e.value)) / 256 * 5;
            switch (screen) {
                .home => {
                    home_scroll += delta;
                    home_reveal = false;
                },
                .grid => grid_scroll += delta,
                .season => {
                    episode_scroll += delta;
                    episode_reveal = false;
                },
                .details => if (detail.is("Series") and delta != 0) {
                    if (delta > 0) focus = @min(focus + 1, seasons_row.count -| 1) else focus -|= 1;
                },
                else => {},
            }
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

fn drawHeadingAndStatus(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const margin = 64 * scale;
    const heading: []const u8 = switch (screen) {
        .server => "Choose a server",
        .auth => "Sign in",
        .quick => "Quick Connect",
        else => "",
    };
    if (heading.len != 0)
        ctx.label(.{ .x = margin, .y = 40 * scale, .w = width - margin * 2, .h = 50 * scale }, null, heading, TEXT, 32 * scale);
    if (status.len != 0 and (status_error or screen == .server or screen == .auth or screen == .quick))
        ctx.label(.{ .x = margin, .y = height - 46 * scale, .w = width - margin * 2, .h = 32 * scale }, null, status.get(), if (status_error) RED else DIM, 19 * scale);
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
    while (take > 1 and renderer.measure(text[0..take], size) > width - renderer.measure("...", size)) {
        take -= 1;
        while (take > 0 and text[take] & 0xc0 == 0x80) take -= 1;
    }
    return fmt("{s}...", .{text[0..take]});
}

fn drawCard(ctx: *loom.Context, rect: loom.Rect, clip: loom.Rect, card: *const Card, focused: bool, scale: f32) bool {
    const visible = loom.Rect.intersect(rect, clip);
    if (visible.w <= 0 or visible.h <= 0) return false;
    const hot = hovered(rect) and clip.contains(cursor_x, cursor_y);
    const art = loom.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h - 78 * scale };
    if (cardPoster(card)) |slot| {
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
    drawWatchBadge(ctx, art, clip, card, scale);

    if (card.progress > 1) {
        const bar = loom.Rect{ .x = art.x, .y = art.y + art.h - 8 * scale, .w = art.w, .h = 6 * scale };
        ctx.fill(bar, clip, BORDER, 3 * scale);
        ctx.fill(.{ .x = bar.x, .y = bar.y, .w = bar.w * @min(card.progress, 100) / 100, .h = bar.h }, clip, ACCENT, 3 * scale);
    }
    ctx.label(.{ .x = rect.x, .y = art.y + art.h + 12 * scale, .w = rect.w, .h = 32 * scale }, loom.Rect.intersect(rect, clip), ellipsize(card.title.get(), rect.w, 21 * scale), if (focused) TEXT else DIM, 21 * scale);
    ctx.label(.{ .x = rect.x, .y = art.y + art.h + 44 * scale, .w = rect.w, .h = 28 * scale }, loom.Rect.intersect(rect, clip), ellipsize(card.subtitle.get(), rect.w, 17 * scale), DIM, 17 * scale);
    return hot and pointer_press;
}

fn drawWatchBadge(ctx: *loom.Context, art: loom.Rect, clip: loom.Rect, card: *const Card, scale: f32) void {
    const episode = card.is("Episode");
    if (!episode and !card.is("Season") and !card.is("Series")) return;
    if (episode and !card.played) return;
    const count = if (card.is("Series")) remainingSeasons(card) else card.remaining;
    if (!episode and (count orelse 0) == 0) return;
    const label = if (episode) @as([]const u8, "✓") else fmt("{d}", .{count.?});
    const size = 22 * scale;
    const w = @max(36 * scale, renderer.measure(label, size) + 16 * scale);
    const badge = loom.Rect{ .x = art.x + art.w - w - 8 * scale, .y = art.y + 8 * scale, .w = w, .h = 36 * scale };
    ctx.fill(badge, clip, ACCENT, 6 * scale);
    ctx.label(.{ .x = badge.x + (badge.w - renderer.measure(label, size)) / 2, .y = badge.y + 3 * scale, .w = badge.w, .h = badge.h }, clip, label, WHITE, size);
}

fn drawMetadata(ctx: *loom.Context, rect: loom.Rect, clip: ?loom.Rect, prefix: []const u8, rating: []const u8, size: f32, color: loom.Color) void {
    var x = rect.x;
    if (prefix.len != 0) {
        ctx.label(rect, clip, prefix, color, size);
        x += renderer.measure(prefix, size) + size;
    }
    if (rating.len != 0) {
        ctx.label(.{ .x = x, .y = rect.y, .w = size * 1.5, .h = rect.h }, clip, "★", YELLOW, size);
        x += renderer.measure("★", size) + size * 0.3;
        ctx.label(.{ .x = x, .y = rect.y, .w = @max(0, rect.x + rect.w - x), .h = rect.h }, clip, rating, TEXT, size);
    }
}

fn cardPoster(card: *const Card) ?*const Slot {
    // Seasons may omit both SeriesId and the inherited image tag. The show
    // details already carry the fallback and remain loaded on the season page.
    if (card.is("Season") and card.thumbnail_tag.len == 0)
        return poster(detail.poster_id.get(), detail.poster_tag.get());
    return poster(card.poster_id.get(), card.poster_tag.get());
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
        if (x >= width) break;
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
    home_row_height = 470 * scale;
    home_rect = .{ .x = 0, .y = 64 * scale, .w = width, .h = height - 128 * scale };
    var list = loom.VirtualList.init(home_rect, rows.len, home_row_height, home_scroll);
    if (home_reveal) {
        list = loom.VirtualList.init(home_rect, rows.len, home_row_height, list.scrollToReveal(row_focus));
        home_reveal = false;
    }
    home_scroll = list.scroll;
    for (0..rows.len) |id| {
        drawRow(ctx, &rows[id], id, list.itemRect(id).y, width, ctx.viewport, scale);
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
        ctx.label(.{ .x = margin, .y = 40 * scale, .w = width - margin * 2, .h = 50 * scale }, null, grid_title.get(), TEXT, 32 * scale);
        ctx.label(.{ .x = margin, .y = grid_rect.y + 40 * scale, .w = 800 * scale, .h = 36 * scale }, null, "Loading library...", DIM, 24 * scale);
        return;
    }

    var list = loom.VirtualList.init(grid_rect, gridRows(), grid_row_height, grid_scroll);
    grid_scroll = list.scroll;
    ctx.label(.{ .x = margin, .y = 40 * scale - grid_scroll, .w = width - margin * 2, .h = 50 * scale }, null, grid_title.get(), TEXT, 32 * scale);
    const content = ctx.viewport;

    // Selection padding isn't a scissor: include the rows that extend into it.
    for (list.first -| 1..@min(list.last + 1, gridRows())) |row_index| {
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
}

fn drawDetails(ctx: *loom.Context, width: f32, scale: f32) void {
    const margin = 64 * scale;
    const art = loom.Rect{ .x = margin, .y = margin, .w = 320 * scale, .h = 480 * scale };
    if (poster(detail.poster_id.get(), detail.poster_tag.get())) |slot|
        ctx.textured(art, null, slot.texture, coverUv(slot, art), WHITE, 16 * scale)
    else {
        ctx.fill(art, null, CARD, 16 * scale);
        ctx.label(.{ .x = art.x + 20 * scale, .y = art.y + art.h / 2, .w = art.w - 40 * scale, .h = 32 * scale }, art, "No artwork", DIM, 20 * scale);
    }
    drawWatchBadge(ctx, art, ctx.viewport, &detail, scale);

    const x = art.x + art.w + 60 * scale;
    const w = width - x - margin;
    ctx.label(.{ .x = x, .y = margin, .w = w, .h = 72 * scale }, null, ellipsize(detail.title.get(), w, 52 * scale), TEXT, 52 * scale);
    ctx.label(.{ .x = x, .y = 150 * scale, .w = w, .h = 34 * scale }, null, detail.subtitle.get(), TEXT, 24 * scale);
    drawMetadata(ctx, .{ .x = x, .y = 195 * scale, .w = w, .h = 34 * scale }, null, detail_extra.get(), detail.rating.get(), 20 * scale, DIM);
    drawWrapped(ctx, .{ .x = x, .y = 255 * scale, .w = w, .h = 180 * scale }, detail.overview.get(), 22 * scale);

    if (detail.is("Series")) {
        if (seasons_row.count == 0) {
            ctx.label(.{ .x = x, .y = 480 * scale, .w = w, .h = 34 * scale }, null, if (seasons_row.loading) "Loading seasons..." else "No seasons", DIM, 22 * scale);
            return;
        }
        ctx.label(.{ .x = x, .y = 470 * scale, .w = w, .h = 34 * scale }, null, "Seasons", TEXT, 26 * scale);
        const clip = ctx.viewport;
        const visible: usize = @max(1, @as(usize, @intFromFloat((w + 26 * scale) / (226 * scale))));
        const first = (focus + 1) -| visible;
        for (first..seasons_row.count) |index| {
            const rect = loom.Rect{ .x = x + @as(f32, @floatFromInt(index - first)) * 226 * scale, .y = 524 * scale, .w = 200 * scale, .h = 378 * scale };
            if (rect.x >= width) break;
            if (drawCard(ctx, rect, clip, &seasons_row.cards[index], focus == index, scale)) {
                focus = index;
                activate();
                break;
            }
        }
        return;
    }

    drawButton(ctx, .{ .x = x, .y = 570 * scale, .w = 250 * scale, .h = 74 * scale }, "Play", 0, scale);
}

fn drawSeason(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const margin = 64 * scale;
    const art = loom.Rect{ .x = margin, .y = margin, .w = 320 * scale, .h = 480 * scale };
    if (cardPoster(&season_detail)) |slot|
        ctx.textured(art, null, slot.texture, coverUv(slot, art), WHITE, 12 * scale)
    else
        ctx.fill(art, null, CARD, 12 * scale);
    drawWatchBadge(ctx, art, ctx.viewport, &season_detail, scale);
    const x = art.x + art.w + 60 * scale;
    const w = width - x - margin;
    ctx.label(.{ .x = x, .y = margin, .w = w, .h = 72 * scale }, null, ellipsize(detail.title.get(), w, 52 * scale), TEXT, 52 * scale);
    ctx.label(.{ .x = x, .y = 152 * scale, .w = w, .h = 48 * scale }, null, season_detail.title.get(), TEXT, 32 * scale);
    const overview = if (season_detail.overview.len != 0) season_detail.overview.get() else detail.overview.get();
    drawWrapped(ctx, .{ .x = x, .y = 220 * scale, .w = w, .h = 145 * scale }, overview, 22 * scale);
    episode_rect = .{ .x = x, .y = 400 * scale, .w = w, .h = height - 464 * scale };
    episode_row_height = 170 * scale;
    if (episodes_row.count == 0) {
        ctx.label(.{ .x = x, .y = episode_rect.y + 20 * scale, .w = w, .h = 34 * scale }, episode_rect, if (episodes_row.loading) "Loading episodes..." else "No episodes", DIM, 23 * scale);
        return;
    }

    if (episode_jump) {
        episode_scroll = @as(f32, @floatFromInt(episode_selected)) * episode_row_height;
        episode_jump = false;
    }
    var list = loom.VirtualList.init(episode_rect, episodes_row.count, episode_row_height, episode_scroll);
    if (episode_reveal) {
        list = loom.VirtualList.init(episode_rect, episodes_row.count, episode_row_height, list.scrollToReveal(episode_selected));
        episode_reveal = false;
    }
    episode_scroll = list.scroll;
    // Keep episodes below their heading, but let them reach the screen bottom.
    const content = loom.Rect{ .x = x, .y = episode_rect.y, .w = width - x, .h = height - episode_rect.y };
    for (list.first..list.last) |index| {
        const raw = list.itemRect(index);
        const row = loom.Rect{ .x = raw.x + 10 * scale, .y = raw.y + 6 * scale, .w = raw.w - 20 * scale, .h = raw.h - 12 * scale };
        const hot = hovered(row) and content.contains(cursor_x, cursor_y);
        const focused = index == episode_selected;
        const card = &episodes_row.cards[index];
        if (focused or hot) ctx.fill(row, content, if (focused) .{ 20, 42, 60, 210 } else .{ 30, 40, 55, 180 }, 11 * scale);
        if (focused) ctx.stroke(row, content, ACCENT, 4 * scale, 11 * scale);
        const clip = loom.Rect.intersect(row, content);
        const thumb = loom.Rect{ .x = row.x + 12 * scale, .y = row.y + 12 * scale, .w = 232 * scale, .h = 130.5 * scale };
        if (artwork(card.id.get(), card.thumbnail_tag.get(), .primary, 384, 216)) |slot|
            ctx.textured(thumb, clip, slot.texture, coverUv(slot, thumb), WHITE, 7 * scale)
        else
            ctx.fill(thumb, clip, CARD, 7 * scale);
        drawWatchBadge(ctx, thumb, clip, card, scale);
        const text_x = thumb.x + thumb.w + 28 * scale;
        const text_w = row.x + row.w - text_x - 24 * scale;
        ctx.label(.{ .x = text_x, .y = row.y + 34 * scale, .w = text_w, .h = 44 * scale }, clip, ellipsize(card.episode_title.get(), text_w, 28 * scale), TEXT, 28 * scale);
        drawMetadata(ctx, .{ .x = text_x, .y = row.y + 90 * scale, .w = text_w, .h = 32 * scale }, clip, card.runtime.get(), card.rating.get(), 21 * scale, TEXT);
        if (card.progress > 1) {
            const bar = loom.Rect{ .x = thumb.x, .y = thumb.y + thumb.h - 5 * scale, .w = thumb.w, .h = 5 * scale };
            ctx.fill(.{ .x = bar.x, .y = bar.y, .w = bar.w * @min(card.progress, 100) / 100, .h = bar.h }, clip, ACCENT, 2 * scale);
        }
        if (hot and pointer_press) {
            episode_selected = index;
            activate();
        }
    }
}

/// The transport row. A zero delta is the play/pause button; the rest seek by
/// their own number of seconds.
const PlaybackAction = enum { previous, back_30, back_10, pause, forward_10, forward_30, next, subtitles, audio };
const playback_buttons = [_]struct { label: []const u8, action: PlaybackAction }{
    .{ .label = "|<", .action = .previous },
    .{ .label = "-30", .action = .back_30 },
    .{ .label = "-10", .action = .back_10 },
    .{ .label = "Pause", .action = .pause },
    .{ .label = "+10", .action = .forward_10 },
    .{ .label = "+30", .action = .forward_30 },
    .{ .label = ">|", .action = .next },
    .{ .label = "Subtitles", .action = .subtitles },
    .{ .label = "Audio", .action = .audio },
};
const play_pause_index = 3;

fn activatePlayback() void {
    playback_controls_until = nowNs() + playback_controls_ns;
    switch (playback_buttons[@min(focus, playback_buttons.len - 1)].action) {
        .back_30 => player.seek(-30),
        .back_10 => player.seek(-10),
        .pause => togglePlayback(),
        .forward_10 => player.seek(10),
        .forward_30 => player.seek(30),
        .previous, .next => setStatus("Episode navigation is not available for this item", .{}),
        .subtitles => setStatus("No subtitle tracks are available", .{}),
        .audio => setStatus("This stream has one audio track", .{}),
    }
}

fn drawPlayback(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    if (!playback_paused and nowNs() >= playback_controls_until) return;
    // The video itself is a separate NDL plane. This graphics-plane strip is
    // deliberately compact content for exercising the renderer.
    const panel = loom.Rect{ .x = 0, .y = height - 166 * scale, .w = width, .h = 166 * scale };
    ctx.fill(panel, null, .{ 8, 12, 20, 205 }, 0);
    ctx.label(.{ .x = 64 * scale, .y = panel.y + 20 * scale, .w = width - 128 * scale, .h = 34 * scale }, panel, playback_title.get(), TEXT, 27 * scale);
    const message = switch (player.state()) {
        .loading => "Loading stream…",
        .playing => if (playback_paused) "Paused — OK resumes · Back stops" else "OK pauses · Back stops",
        .failed => player.lastError(),
        .idle => "Stopped",
    };
    ctx.label(.{ .x = 64 * scale, .y = panel.y + 58 * scale, .w = width - 128 * scale, .h = 26 * scale }, panel, message, if (player.state() == .failed) RED else DIM, 19 * scale);
    // Center transport, with track controls held at the right edge.
    var x = (width - 830 * scale) / 2;
    for (playback_buttons[0..7], 0..) |control, index| {
        const button_width: f32 = if (control.action == .pause) 130 else 88;
        const rect = loom.Rect{
            .x = x,
            .y = panel.y + 96 * scale,
            .w = button_width * scale,
            .h = 48 * scale,
        };
        drawButton(ctx, rect, control.label, index, scale);
        x += rect.w + 10 * scale;
    }
    x = width - 64 * scale - 210 * scale;
    for (playback_buttons[7..], 7..) |control, index| {
        const rect = loom.Rect{ .x = x, .y = panel.y + 96 * scale, .w = 100 * scale, .h = 48 * scale };
        drawButton(ctx, rect, control.label, index, scale);
        x += 110 * scale;
    }
}

/// Greedy word wrap against the real glyph advances. The renderer clips a
/// label to its rect but does not break it, so an overview needs splitting
/// before it becomes draw commands.
fn drawWrapped(ctx: *loom.Context, rect: loom.Rect, text: []const u8, size: f32) void {
    var y = rect.y;
    var rest = text;
    while (rest.len != 0 and y + size * 1.4 <= rect.y + rect.h) {
        const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (newline == 0) {
            rest = rest[1..];
            y += size * 1.45;
            continue;
        }
        var take = newline;
        while (take > 0 and renderer.measure(rest[0..take], size) > rect.w) {
            take = std.mem.lastIndexOfScalar(u8, rest[0..take], ' ') orelse break;
        }
        if (take == 0) break;
        ctx.label(.{ .x = rect.x, .y = y, .w = rect.w, .h = size * 1.4 }, rect, rest[0..take], TEXT, size);
        rest = if (take == newline and newline < rest.len) rest[take + 1 ..] else std.mem.trimStart(u8, rest[take..], " \t\r");
        y += size * 1.45;
    }
}

fn buildUi(ctx: *loom.Context) void {
    const width: f32 = @floatFromInt(gl.width);
    const height: f32 = @floatFromInt(gl.height);
    const scale = @min(width / 1920.0, height / 1080.0);
    scratch_used = 0;
    poster_requests = 0;
    status_requests = 0;
    frame_index += 1;

    ctx.begin(width, height);
    // The NDL video plane sits behind this EGL surface. During playback every
    // untouched pixel must remain transparent, otherwise the UI obscures it.
    if (screen != .playback) ctx.fill(.{ .w = width, .h = height }, null, BG, 0);
    if (screen == .details or screen == .season) {
        const background = loom.Rect{ .w = width, .h = height };
        if (artwork(detail.backdrop_id.get(), detail.backdrop_tag.get(), .backdrop, 1920, 1080)) |slot| {
            ctx.textured(background, null, slot.texture, coverUv(slot, background), WHITE, 0);
            ctx.fill(background, null, .{ 5, 9, 16, 185 }, 0);
        }
    }
    drawHeadingAndStatus(ctx, width, height, scale);
    switch (screen) {
        .server => drawServer(ctx, width, scale),
        .auth => drawAuth(ctx, width, scale),
        .quick => drawQuick(ctx, width, scale),
        .home => drawHome(ctx, width, height, scale),
        .grid => drawGrid(ctx, width, height, scale),
        .details => drawDetails(ctx, width, scale),
        .season => drawSeason(ctx, width, height, scale),
        .playback => drawPlayback(ctx, width, height, scale),
    }
    // Pointer activation happens during layout; rebuild its resulting screen.
    if (pointer_press) wl.frame_requested = true;
    pointer_press = false;
}

/// Only these two UI features have time-dependent work in normal operation.
fn nextDeadline(now: u64, controls_visible: bool) ?u64 {
    var deadline: ?u64 = null;
    if (screen == .quick and quick_secret.len != 0) deadline = @max(now, quick_poll_at);
    if (screen == .playback and !playback_paused and controls_visible)
        deadline = @min(deadline orelse std.math.maxInt(u64), playback_controls_until);
    return deadline;
}

fn waitMilliseconds(now: u64, deadline: ?u64) i32 {
    const due = deadline orelse return -1;
    const remaining = due -| now;
    return @intCast(@min(std.math.maxInt(i32), remaining / std.time.ns_per_ms + @intFromBool(remaining % std.time.ns_per_ms != 0)));
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// This application's own backbuffer as a PPM.
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

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern var stdout: *anyopaque;
extern fn setvbuf(stream: *anyopaque, buf: ?[*]u8, mode: c_int, size: usize) c_int;

/// SAM launches an app with an environment of its own making and no way to
/// add to it, so the debug switches (`JF_KEYLOG`, `JF_LUNALOG`, `JF_MPVLOG`)
/// would be reachable only from a hand-started run -- which is exactly the
/// run that behaves differently. Read them from `conf/debug.env` instead, one
/// `KEY=VALUE` per line, so they work however the app was started:
///
///     echo JF_KEYLOG=1 > $APPDIR/<id>/conf/debug.env
///
/// Anything already in the environment wins, so a manual run can still
/// override the file.
fn loadDebugEnv() void {
    var path: [512]u8 = undefined;
    const name = std.fmt.bufPrintZ(&path, "{s}/conf/debug.env", .{api.storeRoot()}) catch return;
    const rc = linux.openat(linux.AT.FDCWD, name, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var text: [1024]u8 = undefined;
    const n = linux.read(fd, &text, text.len);
    if (@as(isize, @bitCast(n)) <= 0) return;

    var lines = std.mem.tokenizeAny(u8, text[0..n], "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var pair: [256]u8 = undefined;
        const key = std.fmt.bufPrintZ(&pair, "{s}", .{std.mem.trim(u8, line[0..split], " \t")}) catch continue;
        var value_buf: [256]u8 = undefined;
        const value = std.fmt.bufPrintZ(&value_buf, "{s}", .{std.mem.trim(u8, line[split + 1 ..], " \t")}) catch continue;
        _ = setenv(key.ptr, value.ptr, 0);
        std.debug.print("debug.env: {s}={s}\n", .{ key, value });
    }
}

/// Launched from the TV's app list there is no terminal, so an installed app's
/// output goes nowhere and a failure is invisible. The fallback is to
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
    // stdout as well as stderr: SDL and the webOS Luna bridge report on
    // stdout, and those lines are the only diagnosis when a backend refuses.
    _ = linux.dup2(@intCast(rc), 1);
    _ = linux.dup2(@intCast(rc), 2);
    // force line buffering for file logging
    _ = setvbuf(stdout, null, 1, 0);
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
        'b' => if (wl.on_webos) 412 else 158,
        else => 0,
    };
    script_at += 1;
    script_wait = script_beat;
    if (key != 0) onKey(key, true);
    switch (script[script_at - 1]) {
        '[' => onEvent(.{ .pointer_axis = .{ .seat = 0, .axis = 0, .value = -180 * 256 } }),
        ']' => onEvent(.{ .pointer_axis = .{ .seat = 0, .axis = 0, .value = 180 * 256 } }),
        else => {},
    }
    std.debug.print("script: '{c}' -> {s} focus={d} row={d} servers={d} depth={d}\n", .{ script[script_at - 1], @tagName(screen), focus, row_focus, discovered_count, depth });
    return false;
}

pub fn main(init: std.process.Init) !void {
    api.deviceId(&session.device_id);
    api.initStore(init.io, init.gpa);
    logToFile();
    // After the redirect, so the confirmation lands in the log rather than on
    // a stdout nobody is reading.
    loadDebugEnv();
    const restored = api.load(&session);

    wl.on_event = onEvent;
    const appid = std.c.getenv("APPID") orelse @as([*:0]const u8, "dev.hookedbehemoth.jellyfin");
    try wl.init(appid, "Jellyfin", 0, 0);
    defer wl.deinit();
    // How the TV asks the app to close. Absent off-device, where nothing asks.
    luna.registerLifecycle(wl.postQuit, wl.postRaise) catch |err| std.debug.print("no webOS lifecycle: {s}\n", .{@errorName(err)});
    defer luna.deinit();
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

    try fetcher.init(init.gpa, init.io, wl.wake);
    defer fetcher.deinit();
    player.init(init.io);
    defer player.deinit();
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
    var controls_visible = false;
    var last_player_state = player.state();
    while (wl.poll()) {
        pump();
        const current_state = player.state();
        if (current_state != last_player_state) {
            last_player_state = current_state;
            if (screen == .playback) wl.frame_requested = true;
        }
        const now = nowNs();
        const visible = screen == .playback and (playback_paused or now < playback_controls_until);
        if (visible != controls_visible) {
            controls_visible = visible;
            wl.frame_requested = true;
        }
        const video_frame = player.needsFrame();
        const scripted_frame = script_at < script.len or capture_after > 0;
        if (!wl.drawable or (!wl.frame_requested and !video_frame and !scripted_frame and !capture_requested)) {
            _ = wl.waitTimeout(waitMilliseconds(nowNs(), nextDeadline(now, controls_visible)));
            continue;
        }
        glViewport(0, 0, @intCast(gl.width), @intCast(gl.height));
        if (screen == .playback and !player.embedded())
            glClearColor(0, 0, 0, 0) // Starfish owns the webOS video plane.
        else
            glClearColor(9.0 / 255.0, 13.0 / 255.0, 22.0 / 255.0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        if (screen == .playback) player.render(gl.width, gl.height);
        if (wl.frame_requested or scripted_frame) {
            wl.frame_requested = false;
            buildUi(&ctx);
        }
        // Embedded video needs the retained overlay composited over new frames,
        // but neither layout nor artwork requests need to run for those frames.
        renderer.draw(ctx.commands.items, @floatFromInt(gl.width), @floatFromInt(gl.height));
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

test {
    _ = @import("jellyfin/demux_test.zig");
    _ = @import("jellyfin/packet_queue.zig");
    _ = @import("jellyfin/player.zig");
    _ = @import("jellyfin/starfish.zig");
    _ = @import("luna.zig");
}

test "idle UI waits indefinitely and deadlines round up to milliseconds" {
    try std.testing.expectEqual(@as(i32, -1), waitMilliseconds(10, null));
    try std.testing.expectEqual(@as(i32, 0), waitMilliseconds(10, 9));
    try std.testing.expectEqual(@as(i32, 1), waitMilliseconds(10, 11));
    try std.testing.expectEqual(@as(i32, 2), waitMilliseconds(10, 10 + std.time.ns_per_ms + 1));
}

test "playback controls and Quick Connect schedule only their next deadline" {
    const old_screen = screen;
    const old_secret = quick_secret;
    const old_poll = quick_poll_at;
    const old_controls = playback_controls_until;
    const old_paused = playback_paused;
    defer {
        screen = old_screen;
        quick_secret = old_secret;
        quick_poll_at = old_poll;
        playback_controls_until = old_controls;
        playback_paused = old_paused;
    }
    screen = .home;
    try std.testing.expect(nextDeadline(10, false) == null);
    screen = .quick;
    quick_secret.set("pending");
    quick_poll_at = 20;
    try std.testing.expectEqual(@as(?u64, 20), nextDeadline(10, false));
    screen = .playback;
    playback_controls_until = 30;
    playback_paused = false;
    try std.testing.expectEqual(@as(?u64, 30), nextDeadline(10, true));
    try std.testing.expect(nextDeadline(30, false) == null);
    playback_paused = true;
    try std.testing.expect(nextDeadline(10, true) == null);
}

test "Back navigates out of a screen and quits from a root one" {
    defer {
        screen = .server;
        active_field = .none;
        wl.on_webos = false;
        wl.running = true;
        depth = 0;
    }
    // 412 is only Back on the TV.
    wl.on_webos = true;
    // Editing anywhere: Back dismisses the editor and stays put.
    screen = .server;
    active_field = .url;
    onKey(412, true);
    try std.testing.expectEqual(Screen.server, screen);
    try std.testing.expectEqual(EditField.none, active_field);
    try std.testing.expect(wl.running);

    // The sign-in screens unwind towards the server list.
    screen = .quick;
    onKey(412, true);
    try std.testing.expectEqual(Screen.auth, screen);
    onKey(412, false); // a release is not a press
    try std.testing.expectEqual(Screen.auth, screen);
    onKey(412, true);
    try std.testing.expectEqual(Screen.server, screen);
    try std.testing.expect(wl.running);

    // A pushed screen pops back to what was under it.
    screen = .home;
    push();
    screen = .grid;
    onKey(412, true);
    try std.testing.expectEqual(Screen.home, screen);
    try std.testing.expect(wl.running);

    // ...and from a root screen there is nowhere left to go, so the app ends.
    // This is the only way to close it when SAM did not launch it.
    onKey(412, true);
    try std.testing.expect(!wl.running);
    wl.running = true;
    screen = .server;
    onKey(412, true);
    try std.testing.expect(!wl.running);

    wl.on_webos = false;
    try std.testing.expect(!wl.isBackKey(412));
}

test "Back cancels late Quick Connect and sign-in replies" {
    defer {
        screen = .server;
        auth_generation = 0;
    }
    var task: api.Task = .{ .arena = .init(std.testing.allocator), .job = .quick_initiate, .tag = auth_generation, .state = .ready };
    defer task.arena.deinit();
    screen = .auth;
    goBack();
    consume(&task);
    try std.testing.expectEqual(Screen.server, screen);
    task.job = .login;
    consume(&task);
    try std.testing.expectEqual(Screen.server, screen);
}

test "season artwork stays distinct from series and episode artwork" {
    const season = Card.from(.{
        .Id = "season",
        .Name = "Season 2",
        .Type = "Season",
        .SeriesId = "show",
        .ImageTags = .{ .Primary = "season-art" },
        .SeriesPrimaryImageTag = "series-art",
        .Overview = "Season description",
    });
    try std.testing.expectEqualStrings("season", season.poster_id.get());
    try std.testing.expectEqualStrings("season-art", season.poster_tag.get());
    try std.testing.expectEqualStrings("Season description", season.overview.get());
    const episode = Card.from(.{
        .Id = "episode",
        .Name = "The Return",
        .Type = "Episode",
        .SeriesId = "show",
        .SeriesName = "A show",
        .ImageTags = .{ .Primary = "still" },
        .SeriesPrimaryImageTag = "series-art",
        .IndexNumber = 3,
        .RunTimeTicks = 23 * 60 * 10_000_000,
        .CommunityRating = 8.2,
    });
    try std.testing.expectEqualStrings("show", episode.poster_id.get());
    try std.testing.expectEqualStrings("still", episode.thumbnail_tag.get());
    try std.testing.expectEqualStrings("3. The Return", episode.episode_title.get());
    try std.testing.expectEqualStrings("23 min", episode.runtime.get());
    try std.testing.expectEqualStrings("8.2", episode.rating.get());
    const long = Card.from(.{ .RunTimeTicks = 85 * 60 * 10_000_000 });
    try std.testing.expectEqualStrings("1 hr 25 min", long.runtime.get());
    try std.testing.expectEqualStrings("", long.rating.get());
}

test "home wheel scrolling survives frames and Back; remote reveals selected row" {
    defer {
        screen = .server;
        home_scroll = 0;
        row_focus = 0;
        home_reveal = false;
        depth = 0;
    }
    screen = .home;
    home_scroll = 0;
    onEvent(.{ .pointer_axis = .{ .seat = 0, .axis = 0, .value = 100 * 256 } });
    try std.testing.expectApproxEqAbs(@as(f32, 500), home_scroll, 0.01);
    try std.testing.expect(!home_reveal);
    push();
    screen = .grid;
    goBack();
    try std.testing.expectApproxEqAbs(@as(f32, 500), home_scroll, 0.01);
    moveHome(.down);
    moveHome(.down);
    try std.testing.expect(home_reveal);
    const list = loom.VirtualList.init(.{ .w = 1920, .h = 952 }, rows.len, 470, home_scroll);
    const revealed = loom.VirtualList.init(list.viewport, rows.len, 470, list.scrollToReveal(row_focus));
    const selected = revealed.itemRect(row_focus);
    try std.testing.expect(selected.y >= revealed.viewport.y);
    try std.testing.expect(selected.y + selected.h <= revealed.viewport.y + revealed.viewport.h);
}

test "grid navigation preserves the column at top, bottom and an incomplete row" {
    try std.testing.expectEqual(@as(usize, 4), gridMove(4, 16, 6, .up));
    try std.testing.expectEqual(@as(usize, 14), gridMove(14, 16, 6, .down));
    try std.testing.expectEqual(@as(usize, 10), gridMove(10, 16, 6, .down));
    try std.testing.expectEqual(@as(usize, 13), gridMove(7, 16, 6, .down));
    try std.testing.expectEqual(@as(usize, 7), gridMove(13, 16, 6, .up));
}

test "series metadata uses real year spans and seasons fall back to series posters" {
    try std.testing.expectEqualStrings("1992-1997", subtitleFor(.{
        .Type = "Series",
        .ProductionYear = 1992,
        .EndDate = "1997-02-08T00:00:00Z",
        .ChildCount = 5,
    }));
    try std.testing.expectEqualStrings("2024-Present", subtitleFor(.{
        .Type = "Series",
        .PremiereDate = "2024-01-01T00:00:00Z",
        .Status = "Continuing",
    }));
    try std.testing.expectEqualStrings("2020", subtitleFor(.{
        .Type = "Series",
        .ProductionYear = 2020,
        .EndDate = "2020-12-01T00:00:00Z",
    }));
    try std.testing.expectEqualStrings("", subtitleFor(.{ .Type = "Series" }));
    const season = Card.from(.{ .Type = "Season", .Id = "season", .SeriesId = "show", .SeriesPrimaryImageTag = "show-art" });
    try std.testing.expectEqualStrings("show", season.poster_id.get());
    try std.testing.expectEqualStrings("show-art", season.poster_tag.get());
}

test "missing movie years and HTML line breaks are cleaned up" {
    try std.testing.expectEqualStrings("1h 30m", subtitleFor(.{ .Type = "Movie", .RunTimeTicks = 90 * 60 * 10_000_000 }));
    try std.testing.expectEqualStrings("1h 30m", subtitleFor(.{ .Type = "Movie", .ProductionYear = 0, .RunTimeTicks = 90 * 60 * 10_000_000 }));
    const card = Card.from(.{ .Overview = "First<br>Second<BR />Third<br/>\nFourth" });
    try std.testing.expectEqualStrings("First\nSecond\nThird\n\nFourth", card.overview.get());
}

test "watch state chooses the first unfinished item and counts unfinished seasons" {
    const items = [_]api.Item{
        .{ .Type = "Season", .ChildCount = 12, .UserData = .{ .Played = true, .UnplayedItemCount = 0 } },
        .{ .Type = "Season", .ChildCount = 12, .UserData = .{ .UnplayedItemCount = 4 } },
        .{ .Type = "Season", .ChildCount = 12, .UserData = .{ .UnplayedItemCount = 12 } },
    };
    const cards = [_]Card{ .from(items[0]), .from(items[1]), .from(items[2]) };
    try std.testing.expectEqual(@as(u32, 2), unfinishedSeasons(&items));
    try std.testing.expectEqual(@as(usize, 1), firstUnfinished(&cards));
    try std.testing.expectEqual(@as(?u32, 4), cards[1].remaining);
    const episodes = [_]Card{
        .from(.{ .Type = "Episode", .UserData = .{ .Played = true } }),
        .from(.{ .Type = "Episode", .UserData = .{ .PlaybackPositionTicks = 500 } }),
    };
    try std.testing.expectEqual(@as(usize, 1), firstUnfinished(&episodes));
    try std.testing.expectEqual(@as(usize, 0), firstUnfinished(&.{ episodes[0], episodes[0] }));
    try std.testing.expectEqual(@as(usize, 0), firstUnfinished(&.{}));
}

test "zero counts and unwatched episodes emit no badge" {
    var ctx = loom.Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.begin(1920, 1080);
    const art = loom.Rect{ .w = 200, .h = 300 };
    const cards = [_]Card{
        .from(.{ .Type = "Episode", .UserData = .{ .Played = false } }),
        .from(.{ .Type = "Season", .ChildCount = 12, .UserData = .{ .UnplayedItemCount = 0 } }),
        .from(.{ .Type = "Season" }), // No known count yet.
        .from(.{ .Type = "Series", .UserData = .{ .Played = true } }),
    };
    for (&cards) |*card| drawWatchBadge(&ctx, art, art, card, 1);
    try std.testing.expectEqual(@as(usize, 0), ctx.commands.items.len);
}
