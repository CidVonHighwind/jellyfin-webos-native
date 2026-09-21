//! Playback straight against LG's Starfish media pipeline (`libplayerAPIs`).
//! It is the layer `libNDL_directmedia` wraps, and the only one of the two
//! that exposes pause, seek and a load payload we write ourselves.
//!
//! Signatures follow webosbrew/webos-userland
//! `include/starfish-media-pipeline/StarfishMediaAPIs.h`. Everything is a C++
//! member function reached by its mangled name, so `this` is the first
//! argument, and `Feed` returns `std::string`, which on this ABI means a
//! hidden result pointer comes before it.
const std = @import("std");
const c = std.c;

extern fn jf_starfish_begin_segment(pipeline: *anyopaque, pts_ns: i64) bool;
extern fn jf_starfish_segment_error() [*:0]const u8;

pub const LoadCallback = ?*const fn (i32, i64, ?[*:0]const u8) callconv(.c) void;

/// The sample rates the pipeline accepts, by their actual frequency. An
/// unlisted rate has to mean no audio at all: the pipeline takes a rate it
/// does not know as "bypass" and comes down.
pub const SampleRate = enum(u32) {
    none = 0,
    hz_8000 = 8000,
    hz_12000 = 12000,
    hz_16000 = 16000,
    hz_22050 = 22050,
    hz_24000 = 24000,
    hz_32000 = 32000,
    hz_44100 = 44100,
    hz_48000 = 48000,

    pub fn of(hertz: c_int) SampleRate {
        return switch (hertz) {
            48000 => .hz_48000,
            44100 => .hz_44100,
            32000 => .hz_32000,
            24000 => .hz_24000,
            16000 => .hz_16000,
            12000 => .hz_12000,
            8000 => .hz_8000,
            22050 => .hz_22050,
            else => .none,
        };
    }
};

pub const Video = struct {
    width: i32,
    height: i32,
    codec: []const u8,
    /// Frame rate as value/scale, the pipeline's own convention
    /// (PF_EXT_ES_VIDEO_FRAMERATE_VALUE / _SCALE). Zero leaves the pair out,
    /// and the pipeline then believes adaptiveStreaming's maxFrameRate, which
    /// is not the content's rate.
    fps_num: i32 = 0,
    fps_den: i32 = 0,
};
pub const Audio = struct { sample_rate: SampleRate, channels: u8 };
pub const Status = enum { ok, buffer_full, failed };

/// libstdc++'s `basic_string` (cxx11): pointer, length, then either the small
/// buffer or the heap capacity. Local when the pointer aims at our own buffer.
const StdString = extern struct {
    ptr: [*]u8 = undefined,
    len: usize = 0,
    buf: [16]u8 = @splat(0),

    fn slice(self: *const StdString) []const u8 {
        return self.ptr[0..self.len];
    }
    fn deinit(self: *StdString) void {
        if (@intFromPtr(self.ptr) != @intFromPtr(&self.buf)) cpp_delete(self.ptr);
    }
};

var lib: ?*anyopaque = null;
var pipeline: ?*anyopaque = null;
/// The object is about 192 bytes in practice, but the published header
/// declares a 4 KiB tail of padding after its one known member, so match the
/// header rather than the observed size.
var instance: [8192]u8 align(16) = @splat(0);
var error_text: [160]u8 = @splat(0);
var loaded = false;

var smp_ctor: *const fn (*anyopaque, ?[*:0]const u8) callconv(.c) void = undefined;
var smp_dtor: *const fn (*anyopaque) callconv(.c) void = undefined;
var smp_load: *const fn (*anyopaque, [*:0]const u8, LoadCallback) callconv(.c) bool = undefined;
var smp_feed: *const fn (*StdString, *anyopaque, [*:0]const u8) callconv(.c) void = undefined;
var smp_play: *const fn (*anyopaque) callconv(.c) bool = undefined;
var smp_pause: *const fn (*anyopaque) callconv(.c) bool = undefined;
var smp_play_rate: *const fn (*anyopaque, [*:0]const u8) callconv(.c) bool = undefined;
var smp_unload: *const fn (*anyopaque) callconv(.c) bool = undefined;
var smp_eos: *const fn (*anyopaque) callconv(.c) bool = undefined;
var smp_seek: *const fn (*anyopaque, [*:0]const u8) callconv(.c) bool = undefined;
var smp_flush: *const fn (*anyopaque, [*:0]const u8) callconv(.c) bool = undefined;
var smp_foreground: *const fn (*anyopaque) callconv(.c) bool = undefined;
var smp_queue_length: *const fn (*anyopaque, *c_int) callconv(.c) bool = undefined;
var smp_playtime: *const fn (*anyopaque) callconv(.c) i64 = undefined;
var cpp_delete: *const fn (*anyopaque) callconv(.c) void = undefined;

fn sym(handle: ?*anyopaque, comptime T: type, name: [*:0]const u8) !T {
    return @ptrCast(@alignCast(c.dlsym(handle, name) orelse return error.MissingStarfishSymbol));
}

fn setError(message: []const u8) void {
    const n = @min(message.len, error_text.len - 1);
    @memcpy(error_text[0..n], message[0..n]);
    error_text[n] = 0;
}

pub fn lastError() []const u8 {
    return std.mem.sliceTo(&error_text, 0);
}

/// One session's worth of pipeline. The object is **not** reusable across
/// Load/Unload: its uMediaServer context is fixed at construction (every load
/// reports the same `context` id), and a second Load on it comes up with its
/// resources granted but its sinks never registered -- no sourceInfo, no
/// picture.
pub fn init(app_id: []const u8) !void {
    if (pipeline != null) return;
    if (symbols_loaded) {
        smp_ctor(&instance, null);
        pipeline = &instance;
        return;
    }
    lib = c.dlopen("libplayerAPIs.so.1", .{ .NOW = true }) orelse return error.NoPlayerApis;
    const stdcpp = c.dlopen("libstdc++.so.6", .{ .NOW = true }) orelse return error.NoStdCpp;
    cpp_delete = try sym(stdcpp, @TypeOf(cpp_delete), "_ZdlPv");
    smp_ctor = try sym(lib, @TypeOf(smp_ctor), "_ZN17StarfishMediaAPIsC1EPKc");
    smp_dtor = try sym(lib, @TypeOf(smp_dtor), "_ZN17StarfishMediaAPIsD1Ev");
    smp_load = try sym(lib, @TypeOf(smp_load), "_ZN17StarfishMediaAPIs4LoadEPKcPFvixS1_E");
    smp_feed = try sym(lib, @TypeOf(smp_feed), "_ZN17StarfishMediaAPIs4FeedB5cxx11EPKc");
    smp_play = try sym(lib, @TypeOf(smp_play), "_ZN17StarfishMediaAPIs4PlayEv");
    smp_pause = try sym(lib, @TypeOf(smp_pause), "_ZN17StarfishMediaAPIs5PauseEv");
    smp_play_rate = try sym(lib, @TypeOf(smp_play_rate), "_ZN17StarfishMediaAPIs11SetPlayRateEPKc");
    smp_unload = try sym(lib, @TypeOf(smp_unload), "_ZN17StarfishMediaAPIs6UnloadEv");
    smp_eos = try sym(lib, @TypeOf(smp_eos), "_ZN17StarfishMediaAPIs7pushEOSEv");
    smp_seek = try sym(lib, @TypeOf(smp_seek), "_ZN17StarfishMediaAPIs4SeekEPKc");
    smp_flush = try sym(lib, @TypeOf(smp_flush), "_ZN17StarfishMediaAPIs5flushEPKc");
    smp_foreground = try sym(lib, @TypeOf(smp_foreground), "_ZN17StarfishMediaAPIs16notifyForegroundEv");
    smp_queue_length = try sym(lib, @TypeOf(smp_queue_length), "_ZN17StarfishMediaAPIs25getVideoRenderQueueLengthERi");
    smp_playtime = try sym(lib, @TypeOf(smp_playtime), "_ZN17StarfishMediaAPIs18getCurrentPlaytimeEv");
    // Null: the pipeline takes its identity from the load payload's appId.
    symbols_loaded = true;
    smp_ctor(&instance, null);
    pipeline = &instance;
    _ = app_id;
}
var symbols_loaded = false;

var json_buf: [4096]u8 = undefined;

/// Raw elementary-stream payload shared in substance with spool-mpv's
/// Starfish backend. PCM needs much smaller source buffers than compressed
/// audio; using the generic limits adds a large, unnecessary audio queue.
fn buildPayload(buf: []u8, app_id: []const u8, window_id: []const u8, video: Video, audio: ?Audio) ![:0]u8 {
    var pcm_scratch: [192]u8 = undefined;
    // `sampleRate` is in kHz as a decimal -- 48, 44.1, 22.05 -- not hertz. A
    // value the pipeline cannot read is not an error: it quietly builds the
    // sink at 44.1 kHz instead, and 48 kHz PCM fed into that plays about 9%
    // slow, heard as audio drifting away from the picture rather than as
    // anything failing.
    const pcm = if (audio) |a| try std.fmt.bufPrint(
        &pcm_scratch,
        ",\"pcmInfo\":{{\"sampleRate\":{d},\"channelMode\":\"{s}\",\"format\":\"S16LE\",\"layout\":\"interleaved\",\"bitsPerSample\":16}}",
        .{ @as(f64, @floatFromInt(@intFromEnum(a.sample_rate))) / 1000.0, if (a.channels == 1) "mono" else "stereo" },
    ) else "";
    var fps_scratch: [64]u8 = undefined;
    const fps = if (video.fps_num > 0 and video.fps_den > 0) try std.fmt.bufPrint(
        &fps_scratch,
        ",\"videoFpsValue\":{d},\"videoFpsScale\":{d}",
        .{ video.fps_num, video.fps_den },
    ) else "";
    const system_clock = if (audio == null) "\"useCurrentTimeWithSystemClock\":true," else "";
    return std.fmt.bufPrintZ(buf, "{{\"args\":[" ++
        "{{" ++
        "\"mediaTransportType\":\"BUFFERSTREAM\"," ++
        "\"option\":{{" ++
        "\"appId\":\"{s}\"," ++
        "\"needAudio\":{s}," ++
        "\"seekMode\":\"keep-rate\"," ++
        "\"queryPosition\":true," ++
        "\"useDroppedFrameEvent\":true," ++
        "{s}" ++
        "\"windowId\":\"{s}\"," ++
        "\"transmission\":{{" ++
        "\"contentsType\":\"LIVE\"," ++
        "\"trickType\":\"client-side\"" ++
        "}}," ++
        "\"externalStreamingInfo\":{{" ++
        "\"audioSync\":{s}," ++
        "\"streamQualityInfo\":true," ++
        "\"streamQualityInfoNonFlushable\":true," ++
        "\"streamQualityInfoCorruptedFrame\":true," ++
        "\"contents\":{{\"format\":\"RAW\"," ++
        "\"provider\":\"{s}\"," ++
        "\"codec\":{{\"video\":\"{s}\"{s}}}," ++
        "\"esInfo\":{{" ++
        "\"pauseAtDecodeTime\":true," ++
        "\"seperatedPTS\":true," ++
        "\"ptsToDecode\":0," ++
        "\"videoWidth\":{d}," ++
        "\"videoHeight\":{d}{s}}}{s}}}," ++
        "\"bufferingCtrInfo\":{{\"preBufferByte\":0," ++
        "\"bufferMinLevel\":0," ++
        "\"bufferMaxLevel\":0," ++
        "\"qBufferLevelVideo\":0," ++
        "\"srcBufferLevelVideo\":{{\"minimum\":1048576," ++
        "\"maximum\":8388608}}," ++
        "\"qBufferLevelAudio\":0," ++
        "\"srcBufferLevelAudio\":{{\"minimum\":32768," ++
        "\"maximum\":262144}}}}}}}}}}]}}", .{
        app_id,
        if (audio != null) "true" else "false",
        system_clock,
        window_id,
        if (audio != null) "true" else "false",
        app_id,
        video.codec,
        if (audio != null) ",\"audio\":\"PCM\"" else "",
        video.width,
        video.height,
        fps,
        pcm,
    });
}

test "payload matches the spool-mpv raw ES contract" {
    var buf: [4096]u8 = undefined;
    const built = try buildPayload(&buf, "dev.hookedbehemoth.jellyfin", "_Window_Id_66", .{
        .width = 1920,
        .height = 1080,
        .codec = "H265",
        .fps_num = 24000,
        .fps_den = 1001,
    }, .{ .sample_rate = .hz_48000, .channels = 2 });
    for ([_][]const u8{
        "\"mediaTransportType\":\"BUFFERSTREAM\"",
        "\"needAudio\":true",
        "\"seekMode\":\"keep-rate\"",
        "\"audioSync\":true",
        "\"format\":\"RAW\"",
        "\"streamQualityInfo\":true",
        "\"streamQualityInfoNonFlushable\":true",
        "\"streamQualityInfoCorruptedFrame\":true",
        "\"videoFpsValue\":24000,\"videoFpsScale\":1001",
        "\"pauseAtDecodeTime\":true",
        "\"seperatedPTS\":true",
        "\"bitsPerSample\":16",
        "\"sampleRate\":48,",
        "\"srcBufferLevelAudio\":{\"minimum\":32768,\"maximum\":262144}",
        "\"srcBufferLevelVideo\":{\"minimum\":1048576,\"maximum\":8388608}",
        "\"queryPosition\":true",
        "\"windowId\":\"_Window_Id_66\"",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, built, needle) != null) catch |err| {
            std.debug.print("missing {s}\nin {s}\n", .{ needle, built });
            return err;
        };
    }
}

test "payload is valid JSON" {
    var buf: [4096]u8 = undefined;
    const built = try buildPayload(&buf, "dev.hookedbehemoth.jellyfin", "_Window_Id_89", .{
        .width = 1920,
        .height = 1080,
        .codec = "H265",
        .fps_num = 24000,
        .fps_den = 1001,
    }, .{ .sample_rate = .hz_48000, .channels = 2 });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, built, .{});
    defer parsed.deinit();
}

test "pcm sample rates go out in kHz, not hertz and not an enum tag" {
    var buf: [4096]u8 = undefined;
    const video = Video{ .width = 1920, .height = 1080, .codec = "H265" };
    for ([_]struct { rate: SampleRate, want: []const u8 }{
        .{ .rate = .hz_48000, .want = "\"sampleRate\":48," },
        .{ .rate = .hz_44100, .want = "\"sampleRate\":44.1," },
        .{ .rate = .hz_22050, .want = "\"sampleRate\":22.05," },
        .{ .rate = .hz_8000, .want = "\"sampleRate\":8," },
    }) |case| {
        const built = try buildPayload(&buf, "app", "_Window_Id_1", video, .{ .sample_rate = case.rate, .channels = 2 });
        std.testing.expect(std.mem.indexOf(u8, built, case.want) != null) catch |err| {
            std.debug.print("missing {s}\nin {s}\n", .{ case.want, built });
            return err;
        };
    }
}

test "no audio means no audio block" {
    var buf: [4096]u8 = undefined;
    const built = try buildPayload(&buf, "app", "_Window_Id_1", .{ .width = 1280, .height = 720, .codec = "H264" }, null);
    try std.testing.expect(std.mem.indexOf(u8, built, "pcmInfo") == null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"audioSync\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"useCurrentTimeWithSystemClock\":true") != null);
}

pub fn load(app_id: []const u8, window_id: []const u8, video: Video, audio: ?Audio, on_event: LoadCallback) !void {
    const self = pipeline orelse return error.NotInitialized;
    const payload = try buildPayload(&json_buf, app_id, window_id, video, audio);
    std.debug.print("SMP Load payload: {s}\n", .{payload});
    if (!smp_load(self, payload.ptr, on_event)) {
        setError("Starfish rejected the load payload");
        return error.LoadFailed;
    }
    loaded = true;
    _ = smp_foreground(self);
}

fn feed(kind: u8, bytes: []const u8, pts: i64) Status {
    const self = pipeline orelse return .failed;
    var json: [160]u8 = undefined;
    const text = std.fmt.bufPrintZ(
        &json,
        "{{\"bufferAddr\":\"0x{x}\",\"bufferSize\":{d},\"pts\":{d},\"esData\":{d}}}",
        .{ @intFromPtr(bytes.ptr), bytes.len, pts, kind },
    ) catch return .failed;
    var result: StdString = .{};
    smp_feed(&result, self, text.ptr);
    defer result.deinit();
    const status = result.slice();
    if (std.mem.indexOf(u8, status, "Ok") != null) return .ok;
    if (std.mem.indexOf(u8, status, "BufferFull") != null) return .buffer_full;
    setError(status);
    return .failed;
}

pub fn feedVideo(bytes: []const u8, pts: i64) Status {
    return feed(1, bytes, pts);
}
pub fn feedAudio(bytes: []const u8, pts: i64) Status {
    return feed(2, bytes, pts);
}

pub fn renderQueueLength() ?c_int {
    const self = pipeline orelse return null;
    var frames: c_int = 0;
    if (!smp_queue_length(self, &frames)) return null;
    return frames;
}

/// PTS of the frame actually displayed, in nanoseconds. The value is
/// frame-quantized, so callers pair it with a host-time sample and project it.
pub fn playtime() i64 {
    const self = pipeline orelse return 0;
    return smp_playtime(self);
}

pub fn play() bool {
    const self = pipeline orelse return false;
    return smp_play(self);
}
pub fn pause() bool {
    const self = pipeline orelse return false;
    return smp_pause(self);
}
pub fn setPlayRate(rate_millis: i32, audio_output: bool) bool {
    const self = pipeline orelse return false;
    var text: [64]u8 = undefined;
    const arg = std.fmt.bufPrintZ(&text, "{{\"audioOutput\":{},\"playRate\":{d:.3}}}", .{
        audio_output,
        @as(f64, @floatFromInt(rate_millis)) / 1000.0,
    }) catch return false;
    return smp_play_rate(self, arg.ptr);
}
pub fn endOfStream() void {
    if (pipeline) |self| _ = smp_eos(self);
}
/// Drop what the pipeline has buffered and re-anchor it at `position`.
///
/// `audioFlush` (bool) and `offset` (int64) are the only keys
/// `StarfishMediaAPIs::flush(const char *)` parses. It hands them to
/// `CustomPipeline::flush(int, long long)`, which pushes a real
/// FLUSH_START/FLUSH_STOP pair to both appsrcs -- the no-argument `flush()`
/// sends neither and leaves the sink on the pre-seek segment.
///
/// Units are milliseconds, matching `Seek`.
pub fn flush(position: i64) bool {
    const self = pipeline orelse return false;
    var text: [64]u8 = undefined;
    const arg = std.fmt.bufPrintZ(&text, "{{\"audioFlush\":true,\"offset\":{d}}}", .{position}) catch return false;
    return smp_flush(self, arg.ptr);
}

/// Establish the CustomPipeline segment that both elementary streams share.
/// StarfishMediaAPIs does not forward sendSegmentEvent, so the ABI bridge
/// follows its documented player member to the underlying libpf pipeline.
pub fn beginSegment(position: i64) bool {
    const self = pipeline orelse return false;
    return jf_starfish_begin_segment(self, position);
}

pub fn segmentError() []const u8 {
    return std.mem.sliceTo(jf_starfish_segment_error(), 0);
}

/// Seek takes **milliseconds** -- `Seek(const char *millis)` in the header.
pub fn seek(position_ms: i64) bool {
    const self = pipeline orelse return false;
    var text: [32]u8 = undefined;
    const arg = std.fmt.bufPrintZ(&text, "{d}", .{position_ms}) catch return false;
    return smp_seek(self, arg.ptr);
}
pub fn unload() void {
    if (!loaded) return;
    loaded = false;
    if (pipeline) |self| {
        if (!smp_unload(self)) std.debug.print("SMP Unload failed\n", .{});
    }
}
/// Tear the session down completely: Unload, then destroy the object, so the
/// next init() builds a pipeline with a context of its own.
pub fn deinit() void {
    if (pipeline) |self| {
        unload();
        smp_dtor(self);
        pipeline = null;
        instance = @splat(0);
    }
}

pub fn event_desc(kind: i32) []const u8 {
    return switch (kind) {
        0x0 => "TYPE_FRAMEREADY",
        0x1 => "TYPE_STR_STREAMING_INFO_PERI",
        0x2 => "TYPE_INT_BUFFER_RANGE_INFO",
        0x3 => "TYPE_INT_DURATION",
        0x4 => "TYPE_STR_VIDEO_INFO",
        0x5 => "TYPE_STR_VIDEO_TRACK_INFO",
        0x7 => "TYPE_STR_AUDIO_INFO",
        0x8 => "TYPE_STR_AUDIO_TRACK_INFO",
        0x9 => "TYPE_STR_SUBT_TRACK_INFO",
        0xa => "TYPE_STR_BUFF_EVENT",
        0xb => "TYPE_STR_SOURCE_INFO",
        0xd => "TYPE_INT_NUM_PROGRAM",
        0xe => "TYPE_INT_NUM_VIDEO_TRACK",
        0xf => "TYPE_INT_NUM_AUDIO_TRACK",
        0x11 => "TYPE_STR_RESOURCE_INFO",
        0x12 => "TYPE_INT_ERROR",
        0x13 => "TYPE_STR_ERROR",
        0x15 => "TYPE_STR_STATE_UPDATE__PRELOADCOMPLETED",
        0x16 => "TYPE_STR_STATE_UPDATE__LOADCOMPLETED",
        0x17 => "TYPE_STR_STATE_UPDATE__UNLOADCOMPLETED",
        0x18 => "TYPE_STR_STATE_UPDATE__TRACKSELECTED",
        0x19 => "TYPE_STR_STATE_UPDATE__SEEKDONE",
        0x1a => "TYPE_STR_STATE_UPDATE__PLAYING",
        0x1b => "TYPE_STR_STATE_UPDATE__PAUSED",
        0x1c => "TYPE_STR_STATE_UPDATE__ENDOFSTREAM",
        0x1d => "TYPE_STR_CUSTOM",
        0x26 => "TYPE_INT_NEED_DATA",
        0x27 => "TYPE_INT_ENOUGH_DATA",
        0x2b => "TYPE_INT_SVP_VDEC_READY",
        0x2c => "TYPE_INT_BUFFERLOW",
        0x2d => "TYPE_STR_BUFFERFULL",
        0x2e => "TYPE_STR_BUFFERLOW",
        0x30 => "TYPE_DROPPED_FRAME",
        0x270 => "USER_DEFINED",
        else => "(unknown)",
    };
}

/// The callback's third argument is only a C string for string-valued events.
/// For integer events libpf may leave the slot unspecified, so dereferencing
/// it produces garbage or can fault while trying to improve diagnostics.
pub fn eventHasText(kind: i32) bool {
    return switch (kind) {
        0x1,
        0x4,
        0x5,
        0x7,
        0x8,
        0x9,
        0xa,
        0xb,
        0x11,
        0x13,
        0x15...0x1d,
        0x2d,
        0x2e,
        10001,
        10002,
        => true,
        else => false,
    };
}
