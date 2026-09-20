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
var smp_unload: *const fn (*anyopaque) callconv(.c) bool = undefined;
var smp_eos: *const fn (*anyopaque) callconv(.c) bool = undefined;
var smp_seek: *const fn (*anyopaque, [*:0]const u8) callconv(.c) bool = undefined;
var smp_flush: *const fn (*anyopaque, [*:0]const u8) callconv(.c) bool = undefined;
var smp_time_to_decode: *const fn (*anyopaque, [*:0]const u8) callconv(.c) bool = undefined;
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
    smp_unload = try sym(lib, @TypeOf(smp_unload), "_ZN17StarfishMediaAPIs6UnloadEv");
    smp_eos = try sym(lib, @TypeOf(smp_eos), "_ZN17StarfishMediaAPIs7pushEOSEv");
    smp_seek = try sym(lib, @TypeOf(smp_seek), "_ZN17StarfishMediaAPIs4SeekEPKc");
    smp_flush = try sym(lib, @TypeOf(smp_flush), "_ZN17StarfishMediaAPIs5flushEPKc");
    smp_time_to_decode = try sym(lib, @TypeOf(smp_time_to_decode), "_ZN17StarfishMediaAPIs15setTimeToDecodeEPKc");
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

var json_buf: [2048]u8 = undefined;

/// Every key here is one libpf-1.0.so.1 parses on this firmware.
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
    return std.fmt.bufPrintZ(buf, "{{\"args\":[{{\"mediaTransportType\":\"BUFFERSTREAM\",\"option\":{{" ++
        "\"appId\":\"{s}\",\"lowDelayMode\":false,\"queryPosition\":true,\"restartStreaming\":false," ++
        "\"externalStreamingInfo\":{{" ++
        // audioSync makes the audio sink the master clock, which is what a
        // player wants; the two streamQuality keys turn on the pipeline's own
        // dropped/presented frame counters (callback types 46 and 47).
        "\"audioSync\":{s},\"streamQualityInfo\":true,\"streamQualityInfoNonFlushable\":true," ++
        "\"contents\":{{\"provider\":\"jellyfin\",\"codec\":{{\"video\":\"{s}\"{s}}}," ++
        // pauseAtDecodeTime is false on purpose: with true and no
        // setTimeToDecode trigger, "decode until pts 0, then pause" is what
        // the pipeline is being asked for.
        "\"esInfo\":{{\"videoHeight\":{d},\"videoWidth\":{d},\"pauseAtDecodeTime\":false,\"ptsToDecode\":0{s}}}{s}}}," ++
        "\"bufferingCtrInfo\":{{\"preBufferByte\":0,\"qBufferLevelAudio\":0,\"qBufferLevelVideo\":0," ++
        "\"srcBufferLevelAudio\":{{\"minimum\":1,\"maximum\":1048576}}," ++
        "\"srcBufferLevelVideo\":{{\"minimum\":1,\"maximum\":8388608}}}}}}," ++
        "\"transmission\":{{\"contentsType\":\"LIVE\"}}," ++
        "\"adaptiveStreaming\":{{\"maxHeight\":{d},\"maxFrameRate\":120,\"maxWidth\":{d}}}," ++
        "\"windowId\":\"{s}\",\"videoInfo\":{{\"isGameMode\":false}}}}}}]}}", .{
        app_id,       if (audio != null) "true" else "false",
        video.codec,  if (audio != null) ",\"audio\":\"PCM\"" else "",
        video.height, video.width,
        fps,          pcm,
        video.height, video.width,
        window_id,
    });
}

test "payload carries the keys libpf parses on this firmware" {
    var buf: [2048]u8 = undefined;
    const built = try buildPayload(&buf, "dev.hookedbehemoth.jellyfin", "_Window_Id_66", .{
        .width = 1920,
        .height = 1080,
        .codec = "H265",
        .fps_num = 24000,
        .fps_den = 1001,
    }, .{ .sample_rate = .hz_48000, .channels = 2 });
    // Checked against libpf-1.0.so.1's string table. needAudio, seperatedPTS
    // and bufferMaxLevel are absent because this firmware does not parse them.
    for ([_][]const u8{
        "\"mediaTransportType\":\"BUFFERSTREAM\"",
        "\"audioSync\":true",
        "\"streamQualityInfo\":true",
        "\"streamQualityInfoNonFlushable\":true",
        "\"videoFpsValue\":24000,\"videoFpsScale\":1001",
        "\"pauseAtDecodeTime\":false",
        "\"bitsPerSample\":16",
        "\"sampleRate\":48,",
        "\"srcBufferLevelVideo\":{\"minimum\":1,\"maximum\":8388608}",
        "\"queryPosition\":true",
        "\"windowId\":\"_Window_Id_66\"",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, built, needle) != null) catch |err| {
            std.debug.print("missing {s}\nin {s}\n", .{ needle, built });
            return err;
        };
    }
    for ([_][]const u8{ "needAudio", "seperatedPTS", "bufferMaxLevel" }) |absent|
        try std.testing.expect(std.mem.indexOf(u8, built, absent) == null);
}

test "payload is valid JSON" {
    var buf: [2048]u8 = undefined;
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
    var buf: [2048]u8 = undefined;
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
    var buf: [2048]u8 = undefined;
    const built = try buildPayload(&buf, "app", "_Window_Id_1", .{ .width = 1280, .height = 720, .codec = "H264" }, null);
    try std.testing.expect(std.mem.indexOf(u8, built, "pcmInfo") == null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"audioSync\":false") != null);
}

pub fn load(app_id: []const u8, window_id: []const u8, video: Video, audio: ?Audio, on_event: LoadCallback) !void {
    const self = pipeline orelse return error.NotInitialized;
    const payload = try buildPayload(&json_buf, app_id, window_id, video, audio);
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

/// Where the pipeline says playback actually is. Units are not documented;
/// the first run prints it next to a known feed timestamp.
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

/// Tell the decoder where the buffers that follow begin. Wants the pipeline
/// paused: libpf logs "Failed to setTimeToDecode current state: %s" otherwise.
pub fn setTimeToDecode(position: i64) bool {
    const self = pipeline orelse return false;
    var text: [48]u8 = undefined;
    const arg = std.fmt.bufPrintZ(&text, "{{\"position\":{d}}}", .{position}) catch return false;
    return smp_time_to_decode(self, arg.ptr);
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
