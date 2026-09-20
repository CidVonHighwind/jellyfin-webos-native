//! Jellyfin playback on the desktop, through the system libmpv.
//!
//! The `zig build run-host` half of playback: mpv owns demuxing, seeking,
//! audio and the clock, and renders into the app's own GL context through the
//! libmpv render API so the UI still composites on top. The TV's backend is
//! next door in player.zig, feeding LG's Starfish pipeline directly.
//!
//! libmpv is dlopen'd like every other library here, so the build needs no
//! headers and no sysroot -- the client API is small and its ABI is stable.
const std = @import("std");
const c = std.c;
const gl = @import("../gl.zig");
const wl = @import("../sdl.zig");

const app_id = "dev.hookedbehemoth.jellyfin";

// ------------------------------------------------------------ libmpv ABI
//
// Only the client and render entry points are needed, and their values are
// stable ABI, so they are spelled out here rather than pulled from a header
// the cross build would have to find.

const Handle = opaque {};
const RenderCtx = opaque {};

const Format = enum(c_int) { none = 0, string = 1, flag = 3, int64 = 4, double = 5 };
const EventId = enum(c_int) {
    none = 0,
    shutdown = 1,
    log_message = 2,
    start_file = 6,
    end_file = 7,
    file_loaded = 8,
    playback_restart = 21,
    _,
};
const EndFileReason = enum(c_int) { eof = 0, stop = 2, quit = 3, err = 4, redirect = 5, _ };

const Event = extern struct { id: EventId, err: c_int, reply_userdata: u64, data: ?*anyopaque };
const EventLogMessage = extern struct {
    prefix: [*:0]const u8,
    level: [*:0]const u8,
    text: [*:0]const u8,
    log_level: c_int,
};
const EventEndFile = extern struct {
    reason: EndFileReason,
    err: c_int,
    playlist_entry_id: i64,
    playlist_insert_id: i64,
    playlist_insert_num_entries: c_int,
};

const RenderParamType = enum(c_int) { invalid = 0, api_type = 1, opengl_init_params = 2, opengl_fbo = 3, flip_y = 4 };
const RenderParam = extern struct { kind: RenderParamType, data: ?*anyopaque };
const OpenGlInitParams = extern struct {
    get_proc_address: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
    ctx: ?*anyopaque,
};
const OpenGlFbo = extern struct { fbo: c_int, w: c_int, h: c_int, internal_format: c_int };

var mpv_create: *const fn () callconv(.c) ?*Handle = undefined;
var mpv_initialize: *const fn (*Handle) callconv(.c) c_int = undefined;
var mpv_terminate_destroy: *const fn (*Handle) callconv(.c) void = undefined;
var mpv_set_option_string: *const fn (*Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_int = undefined;
var mpv_set_property_string: *const fn (*Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_int = undefined;
var mpv_get_property: *const fn (*Handle, [*:0]const u8, Format, *anyopaque) callconv(.c) c_int = undefined;
var mpv_command: *const fn (*Handle, [*:null]const ?[*:0]const u8) callconv(.c) c_int = undefined;
var mpv_wait_event: *const fn (*Handle, f64) callconv(.c) *Event = undefined;
var mpv_request_log_messages: *const fn (*Handle, [*:0]const u8) callconv(.c) c_int = undefined;
var mpv_error_string: *const fn (c_int) callconv(.c) [*:0]const u8 = undefined;
var mpv_render_context_create: *const fn (**RenderCtx, *Handle, [*]RenderParam) callconv(.c) c_int = undefined;
var mpv_render_context_render: *const fn (*RenderCtx, [*]RenderParam) callconv(.c) c_int = undefined;
var mpv_render_context_free: *const fn (*RenderCtx) callconv(.c) void = undefined;

var lib: ?*anyopaque = null;

fn bind(comptime T: type, name: [*:0]const u8) !T {
    return @ptrCast(@alignCast(c.dlsym(lib.?, name) orelse return error.MissingMpvSymbol));
}

fn openLib() !void {
    if (lib != null) return;
    for ([_][*:0]const u8{ "libmpv.so.2", "libmpv.so.1", "libmpv.so" }) |name| {
        if (c.dlopen(name, .{ .NOW = true })) |opened| {
            lib = opened;
            break;
        }
    } else return error.NoLibMpv;
    mpv_create = try bind(@TypeOf(mpv_create), "mpv_create");
    mpv_initialize = try bind(@TypeOf(mpv_initialize), "mpv_initialize");
    mpv_terminate_destroy = try bind(@TypeOf(mpv_terminate_destroy), "mpv_terminate_destroy");
    mpv_set_option_string = try bind(@TypeOf(mpv_set_option_string), "mpv_set_option_string");
    mpv_set_property_string = try bind(@TypeOf(mpv_set_property_string), "mpv_set_property_string");
    mpv_get_property = try bind(@TypeOf(mpv_get_property), "mpv_get_property");
    mpv_command = try bind(@TypeOf(mpv_command), "mpv_command");
    mpv_wait_event = try bind(@TypeOf(mpv_wait_event), "mpv_wait_event");
    mpv_request_log_messages = try bind(@TypeOf(mpv_request_log_messages), "mpv_request_log_messages");
    mpv_error_string = try bind(@TypeOf(mpv_error_string), "mpv_error_string");
    mpv_render_context_create = try bind(@TypeOf(mpv_render_context_create), "mpv_render_context_create");
    mpv_render_context_render = try bind(@TypeOf(mpv_render_context_render), "mpv_render_context_render");
    mpv_render_context_free = try bind(@TypeOf(mpv_render_context_free), "mpv_render_context_free");
}

// ------------------------------------------------------------- app state

pub const State = enum(u8) { idle, loading, playing, failed };
var playback_state = std.atomic.Value(u8).init(@intFromEnum(State.idle));
var error_text: [160]u8 = @splat(0);

fn setError(message: []const u8) void {
    const n = @min(message.len, error_text.len - 1);
    @memcpy(error_text[0..n], message[0..n]);
    error_text[n] = 0;
}
pub fn lastError() []const u8 {
    return std.mem.sliceTo(&error_text, 0);
}
pub fn state() State {
    return @enumFromInt(playback_state.load(.acquire));
}
fn setState(s: State) void {
    playback_state.store(@intFromEnum(s), .release);
}

/// The IO the rest of the app runs on. mpv has its own threads and needs
/// nothing from it, but the lifecycle hook stays uniform.
pub fn init(_: std.Io) void {}

/// True: the video lands in our own framebuffer, so the app draws its normal
/// background and composites the UI over the frame.
pub fn embedded() bool {
    return true;
}

const max_uri_len = 2047;
var uri: [max_uri_len + 1]u8 = @splat(0);
/// The server's transcode URL, used when the original is beyond the TV's
/// decoder and as the only seekable handle once we are on it. Empty means
/// there is nothing else to try.
var fallback: [max_uri_len + 1]u8 = @splat(0);
var fallback_len: usize = 0;
/// Set once playback has moved to the server-side transcode.
var transcoding = std.atomic.Value(bool).init(false);
/// Where in the item the current source starts. A transcode is re-cut at the
/// seek target and numbers itself from zero, so its offset lives here.
var base_ms = std.atomic.Value(i32).init(0);
var transcode_sequence = std.atomic.Value(u32).init(0);

var handle: ?*Handle = null;
var pump_thread: ?std.Thread = null;
var pumping = std.atomic.Value(bool).init(false);

// -------------------------------------------------------------- commands

fn command(args: []const ?[*:0]const u8) bool {
    const h = handle orelse return false;
    var argv: [8]?[*:0]const u8 = @splat(null);
    @memcpy(argv[0..args.len], args);
    const status = mpv_command(h, @ptrCast(&argv));
    if (status < 0) std.debug.print("mpv {s}: {s}\n", .{
        args[0].?, std.mem.sliceTo(mpv_error_string(status), 0),
    });
    return status >= 0;
}

/// Jellyfin keys a running transcode by PlaySessionId. Seeking needs a new
/// job; reusing the id reconnects to the first one, whose output starts at
/// zero regardless of StartTimeTicks.
fn playSessionId(buffer: []u8) []const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const stamp: u64 = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    const sequence = transcode_sequence.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buffer, "{x:0>8}-{x:0>4}-4{x:0>3}-8{x:0>3}-{x:0>12}", .{
        @as(u32, @truncate(stamp)),
        @as(u16, @truncate(stamp >> 32)),
        @as(u16, @truncate(stamp >> 48)) & 0x0fff,
        @as(u16, @truncate(sequence)) & 0x0fff,
        (stamp ^ (@as(u64, sequence) << 32)) & 0x0000ffffffffffff,
    }) catch "";
}

/// Load the server-side transcode from `target_ms` on. Its offset goes in
/// `StartTimeTicks` -- a tick is 100 ns -- and what comes back is a fresh
/// stream numbered from zero, which is why `base_ms` has to follow it.
/// The route's canonical Pascal-case spelling is deliberate: older Jellyfin
/// servers route the lower-case one into the opaque stream-options map
/// instead of binding it to VideoRequestDto.StartTimeTicks.
fn loadTranscode(target_ms: i32) bool {
    if (fallback_len == 0) return false;
    var buffer: [max_uri_len + 96:0]u8 = undefined;
    var id: [36]u8 = undefined;
    const url = std.fmt.bufPrintZ(&buffer, "{s}&PlaySessionId={s}&StartTimeTicks={d}", .{
        fallback[0..fallback_len], playSessionId(&id), @as(i64, target_ms) * 10_000,
    }) catch {
        setError("The server transcode URL is too long");
        return false;
    };
    transcoding.store(true, .release);
    base_ms.store(target_ms, .monotonic);
    setState(.loading);
    return command(&.{ "loadfile", url.ptr, "replace" });
}

// ------------------------------------------------------------ event pump

/// mpv reports state changes and failures here. A file that will not play on
/// the TV is almost always one the decoder cannot take (10-bit, or above the
/// profile it supports), so the first error moves us to the server transcode.
fn pumpEvents() void {
    const h = handle.?;
    while (pumping.load(.acquire)) {
        const event = mpv_wait_event(h, 0.05);
        switch (event.id) {
            .none => {},
            .shutdown => return,
            .log_message => {
                const message: *const EventLogMessage = @ptrCast(@alignCast(event.data orelse continue));
                std.debug.print("mpv/{s} {s}: {s}", .{
                    std.mem.sliceTo(message.level, 0),
                    std.mem.sliceTo(message.prefix, 0),
                    std.mem.sliceTo(message.text, 0),
                });
            },
            .file_loaded, .playback_restart => setState(.playing),
            .end_file => {
                const end: *const EventEndFile = @ptrCast(@alignCast(event.data orelse continue));
                switch (end.reason) {
                    .err => {
                        if (!transcoding.load(.acquire) and loadTranscode(0)) {
                            std.debug.print("mpv: source is beyond the decoder, transcoding\n", .{});
                            continue;
                        }
                        setError(std.mem.sliceTo(mpv_error_string(end.err), 0));
                        setState(.failed);
                    },
                    // Anything else is a real end -- unless a load is already
                    // in flight, which is how a seek through the transcode
                    // ends the old stream before its replacement arrives.
                    else => if (state() != .loading) setState(.idle),
                }
            },
            else => {},
        }
    }
}

// --------------------------------------------------------------- session

fn create() !void {
    try openLib();
    if (handle != null) return;
    const h = mpv_create() orelse return error.MpvCreateFailed;
    errdefer mpv_terminate_destroy(h);

    // The render API, so the frame lands in our framebuffer under the UI.
    try set(h, "vo", "libmpv");
    try set(h, "hwdec", "auto-safe");
    // Stay alive between items so one mpv core serves the whole session.
    try set(h, "idle", "yes");
    // Read ahead, but never let a slow moment pause playback -- a pause here
    // reads as an audio underrun on the way back out.
    try set(h, "cache", "yes");
    try set(h, "cache-pause", "no");
    try set(h, "audio-client-name", app_id);
    if (mpv_initialize(h) < 0) return error.MpvInitFailed;
    // Without this the only thing we ever learn about a failure is an error
    // code. JF_MPVLOG picks a louder level (mpv's own names: v, debug, trace).
    _ = mpv_request_log_messages(h, if (c.getenv("JF_MPVLOG")) |v| v else "warn");
    handle = h;
    pumping.store(true, .release);
    pump_thread = try std.Thread.spawn(.{}, pumpEvents, .{});
}

fn set(h: *Handle, name: [*:0]const u8, value: [*:0]const u8) !void {
    if (mpv_set_option_string(h, name, value) < 0) {
        std.debug.print("mpv option {s}={s} refused\n", .{ name, value });
        return error.MpvOptionRefused;
    }
}

/// `width`/`height` are the TV backend's video-plane geometry; mpv sizes
/// itself from the framebuffer it renders into, so they are unused here.
pub fn play(stream_uri: []const u8, transcode_uri: []const u8, _: u32, _: u32) !void {
    std.log.debug("stream: {s}, transcode: {s}", .{ stream_uri, transcode_uri });
    if (stream_uri.len >= uri.len or transcode_uri.len >= fallback.len) return error.UriTooLong;
    @memset(&error_text, 0);
    try create();
    @memcpy(uri[0..stream_uri.len], stream_uri);
    uri[stream_uri.len] = 0;
    fallback_len = transcode_uri.len;
    @memcpy(fallback[0..fallback_len], transcode_uri);
    fallback[fallback_len] = 0;
    transcoding.store(false, .release);
    base_ms.store(0, .monotonic);
    setState(.loading);
    _ = mpv_set_property_string(handle.?, "pause", "no");
    if (!command(&.{ "loadfile", @ptrCast(&uri), "replace" })) return error.LoadFailed;
}

pub fn position() i32 {
    const h = handle orelse return 0;
    var seconds: f64 = 0;
    if (mpv_get_property(h, "time-pos", .double, &seconds) < 0) return base_ms.load(.monotonic);
    return base_ms.load(.monotonic) + @as(i32, @intFromFloat(seconds * 1000));
}

/// Jump `delta_seconds` from where playback is. A live transcode has no byte
/// ranges to seek over, so there the server cuts a new stream at the target
/// instead; anything else mpv seeks itself.
pub fn seek(delta_seconds: i32) void {
    if (state() == .idle) return;
    if (transcoding.load(.acquire)) {
        _ = loadTranscode(@max(0, position() + delta_seconds * 1000));
        return;
    }
    var buffer: [16]u8 = undefined;
    const amount = std.fmt.bufPrintZ(&buffer, "{d}", .{delta_seconds}) catch return;
    _ = command(&.{ "seek", amount.ptr, "relative" });
}

pub fn pause() void {
    if (handle) |h| _ = mpv_set_property_string(h, "pause", "yes");
}
pub fn resumePlayback() void {
    if (handle) |h| _ = mpv_set_property_string(h, "pause", "no");
}
pub fn stop() void {
    _ = command(&.{"stop"});
    setState(.idle);
}

pub fn deinit() void {
    const h = handle orelse return;
    pumping.store(false, .release);
    if (pump_thread) |t| t.join();
    pump_thread = null;
    if (render_ctx) |ctx| mpv_render_context_free(ctx);
    render_ctx = null;
    handle = null;
    mpv_terminate_destroy(h);
}

// ------------------------------------------------- desktop embedded video

var render_ctx: ?*RenderCtx = null;

fn getProcAddress(_: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    return gl.procAddress(name);
}

/// Draw the current frame into the app's framebuffer, under the UI. A no-op
/// on the TV, where the video never reaches GL at all.
pub fn render(width: u32, height: u32) void {
    const h = handle orelse return;
    if (render_ctx == null) {
        var init_params = OpenGlInitParams{ .get_proc_address = getProcAddress, .ctx = null };
        var params = [_]RenderParam{
            // API_TYPE carries the string itself, not a pointer to it.
            .{ .kind = .api_type, .data = @ptrCast(@constCast("opengl")) },
            .{ .kind = .opengl_init_params, .data = &init_params },
            .{ .kind = .invalid, .data = null },
        };
        var ctx: *RenderCtx = undefined;
        const status = mpv_render_context_create(&ctx, h, &params);
        if (status < 0) {
            setError(std.mem.sliceTo(mpv_error_string(status), 0));
            setState(.failed);
            return;
        }
        render_ctx = ctx;
    }
    // Into the default framebuffer, which GL addresses from the bottom left
    // while the UI above it works top-down.
    var fbo = OpenGlFbo{ .fbo = 0, .w = @intCast(width), .h = @intCast(height), .internal_format = 0 };
    var flip: c_int = 1;
    var params = [_]RenderParam{
        .{ .kind = .opengl_fbo, .data = &fbo },
        .{ .kind = .flip_y, .data = &flip },
        .{ .kind = .invalid, .data = null },
    };
    _ = mpv_render_context_render(render_ctx.?, &params);
}

// The one thing that cannot be checked by compiling: that the entry points
// and struct layouts above still match the libmpv on this machine.
test "libmpv loads and initialises" {
    openLib() catch return error.SkipZigTest;
    const h = mpv_create() orelse return error.MpvCreateFailed;
    defer mpv_terminate_destroy(h);
    try set(h, "vo", "libmpv");
    try set(h, "idle", "yes");
    try std.testing.expect(mpv_initialize(h) >= 0);
    // A command that cannot succeed: the reply still has to come back as the
    // documented negative error code with a message behind it.
    try std.testing.expect(mpv_command(h, &[_:null]?[*:0]const u8{"no-such-command"}) < 0);
    try std.testing.expect(mpv_error_string(-5)[0] != 0);
}
