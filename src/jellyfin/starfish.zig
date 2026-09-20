//! Playback straight against LG's Starfish media pipeline (`libplayerAPIs`),
//! the layer `libNDL_directmedia` wraps.
//!
//! NDL is skipped because it cannot pause or seek: `DMPlayer::Play()` exists
//! in that library, calls `StarfishMediaAPIs::Play()`, and nothing ever calls
//! it — there is no such entry point in the public API. Talking to SMP
//! directly also means we write the load payload instead of accepting the one
//! NDL hardcodes.
//!
//! Signatures follow webosbrew/webos-userland
//! `include/starfish-media-pipeline/StarfishMediaAPIs.h`. Everything is a C++
//! member function reached by its mangled name, so `this` is the first
//! argument, and `Feed` returns `std::string`, which on this ABI means a
//! hidden result pointer comes before it.
const std = @import("std");
const c = std.c;

pub const LoadCallback = ?*const fn (i32, i64, ?[*:0]const u8) callconv(.c) void;

/// The sample rates the pipeline accepts, which are not ordered by frequency.
/// Zero means "bypass" and takes the pipeline down, so an unlisted rate has to
/// mean no audio at all.
pub const SampleRate = enum(u8) {
    none = 0,
    hz_48000 = 1,
    hz_44100 = 2,
    hz_32000 = 3,
    hz_24000 = 4,
    hz_16000 = 5,
    hz_12000 = 6,
    hz_8000 = 7,
    hz_22050 = 8,

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
    /// which is what NDL does -- the pipeline then believes adaptiveStreaming's
    /// maxFrameRate, which is not the content's rate.
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
/// NDL allocates 0xd0 bytes for the shared_ptr block, 16 of which are the
/// control header, so the object is about 192 bytes. The published header
/// declares a 4 KiB tail of padding after its one known member, so match that
/// rather than the observed size.
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
/// picture. NDL constructs a fresh StarfishMediaAPIs per load too.
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
    smp_foreground = try sym(lib, @TypeOf(smp_foreground), "_ZN17StarfishMediaAPIs16notifyForegroundEv");
    smp_queue_length = try sym(lib, @TypeOf(smp_queue_length), "_ZN17StarfishMediaAPIs25getVideoRenderQueueLengthERi");
    smp_playtime = try sym(lib, @TypeOf(smp_playtime), "_ZN17StarfishMediaAPIs18getCurrentPlaytimeEv");
    // NDL passes null here and the pipeline takes its identity from the load
    // payload's appId instead.
    symbols_loaded = true;
    smp_ctor(&instance, null);
    pipeline = &instance;
    _ = app_id;
}
var symbols_loaded = false;

var json_buf: [2048]u8 = undefined;

/// The payload is NDL's, captured off the wire and kept key for key. The two
/// latency switches stay as NDL sets them: turning them off was tried against
/// the real pipeline and changed nothing, so this keeps the configuration the
/// TV is known to accept.
fn buildPayload(buf: []u8, app_id: []const u8, window_id: []const u8, video: Video, audio: ?Audio) ![:0]u8 {
    var pcm_scratch: [192]u8 = undefined;
    const pcm = if (audio) |a| try std.fmt.bufPrint(
        &pcm_scratch,
        ",\"pcmInfo\":{{\"sampleRate\":{d},\"channelMode\":\"{s}\",\"format\":\"S16LE\",\"layout\":\"interleaved\",\"bitsPerSample\":16}}",
        .{ @intFromEnum(a.sample_rate), if (a.channels == 1) "mono" else "stereo" },
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
        // the pipeline is being asked for. NDL sends true regardless.
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
    // Every key here was checked against libpf-1.0.so.1's string table; the
    // ones plx-native sends that this firmware does not know (needAudio,
    // seperatedPTS, bufferMaxLevel) are deliberately absent.
    for ([_][]const u8{
        "\"mediaTransportType\":\"BUFFERSTREAM\"",
        "\"audioSync\":true",
        "\"streamQualityInfo\":true",
        "\"streamQualityInfoNonFlushable\":true",
        "\"videoFpsValue\":24000,\"videoFpsScale\":1001",
        "\"pauseAtDecodeTime\":false",
        "\"bitsPerSample\":16",
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
