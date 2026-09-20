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

pub const Video = struct { width: i32, height: i32, codec: []const u8 };
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
var smp_audio_buffer: *const fn (*anyopaque, *c_int, *c_int) callconv(.c) bool = undefined;
var smp_queue_length: *const fn (*anyopaque, *c_int) callconv(.c) bool = undefined;
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

pub fn init(app_id: []const u8) !void {
    if (pipeline != null) return;
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
    smp_audio_buffer = try sym(lib, @TypeOf(smp_audio_buffer), "_ZN17StarfishMediaAPIs18getAudioBufferSizeERiS0_");
    smp_queue_length = try sym(lib, @TypeOf(smp_queue_length), "_ZN17StarfishMediaAPIs25getVideoRenderQueueLengthERi");
    // NDL passes null here and the pipeline takes its identity from the load
    // payload's appId instead.
    smp_ctor(&instance, null);
    pipeline = &instance;
    _ = app_id;
}

var json_buf: [1024]u8 = undefined;

/// The payload is NDL's, captured off the wire and kept key for key. The two
/// latency switches stay as NDL sets them: turning them off was tried against
/// the real pipeline and changed nothing, so this keeps the configuration the
/// TV is known to accept.
fn buildPayload(buf: []u8, app_id: []const u8, window_id: []const u8, video: Video, audio: ?Audio) ![:0]u8 {
    var pcm_scratch: [192]u8 = undefined;
    const pcm = if (audio) |a| try std.fmt.bufPrint(
        &pcm_scratch,
        ",\"pcmInfo\":{{\"sampleRate\":{d},\"channelMode\":\"{s}\",\"format\":\"S16LE\",\"layout\":\"interleaved\"}}",
        .{ @intFromEnum(a.sample_rate), if (a.channels == 1) "mono" else "stereo" },
    ) else "";
    return std.fmt.bufPrintZ(buf, "{{\"args\":[{{\"mediaTransportType\":\"DIRECTMEDIA-ES-PLAYER\",\"option\":{{" ++
        "\"appId\":\"{s}\",\"lowDelayMode\":true," ++
        "\"externalStreamingInfo\":{{\"contents\":{{" ++
        "\"codec\":{{\"video\":\"{s}\"{s}}}," ++
        "\"esInfo\":{{\"videoHeight\":{d},\"videoWidth\":{d},\"pauseAtDecodeTime\":true,\"ptsToDecode\":0}}{s}}}}}," ++
        "\"adaptiveStreaming\":{{\"maxHeight\":{d},\"maxFrameRate\":120,\"maxWidth\":{d}}}," ++
        "\"windowId\":\"{s}\",\"videoInfo\":{{\"isGameMode\":true}}}}}}]}}", .{
        app_id,       video.codec, if (audio != null) ",\"audio\":\"PCM\"" else "",
        video.height, video.width, pcm,
        video.height, video.width, window_id,
    });
}

test "payload matches what NDL sends" {
    var buf: [1024]u8 = undefined;
    const captured =
        "{\"args\":[{\"mediaTransportType\":\"DIRECTMEDIA-ES-PLAYER\",\"option\":{\"appId\":\"dev.hookedbehemoth.jellyfin\"," ++
        "\"lowDelayMode\":true,\"externalStreamingInfo\":{\"contents\":{\"codec\":{\"video\":\"H265\",\"audio\":\"PCM\"}," ++
        "\"esInfo\":{\"videoHeight\":1080,\"videoWidth\":1920,\"pauseAtDecodeTime\":true,\"ptsToDecode\":0}," ++
        "\"pcmInfo\":{\"sampleRate\":1,\"channelMode\":\"stereo\",\"format\":\"S16LE\",\"layout\":\"interleaved\"}}}," ++
        "\"adaptiveStreaming\":{\"maxHeight\":1080,\"maxFrameRate\":120,\"maxWidth\":1920}," ++
        "\"windowId\":\"_Window_Id_66\",\"videoInfo\":{\"isGameMode\":true}}}]}";
    const built = try buildPayload(&buf, "dev.hookedbehemoth.jellyfin", "_Window_Id_66", .{
        .width = 1920,
        .height = 1080,
        .codec = "H265",
    }, .{ .sample_rate = .hz_48000, .channels = 2 });
    try std.testing.expectEqualStrings(captured, built);
}

pub fn load(app_id: []const u8, window_id: []const u8, video: Video, audio: ?Audio, on_event: LoadCallback) !void {
    const self = pipeline orelse return error.NotInitialized;
    const payload = try buildPayload(&json_buf, app_id, window_id, video, audio);
    if (!smp_load(self, payload.ptr, on_event)) {
        setError("Starfish rejected the load payload");
        return error.LoadFailed;
    }
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

/// Bytes the audio sink can still take, as NDL computes it: total minus used.
pub fn audioRoom() ?c_int {
    const self = pipeline orelse return null;
    var total: c_int = 0;
    var used: c_int = 0;
    if (!smp_audio_buffer(self, &total, &used)) return null;
    return total - used;
}

pub fn renderQueueLength() ?c_int {
    const self = pipeline orelse return null;
    var frames: c_int = 0;
    if (!smp_queue_length(self, &frames)) return null;
    return frames;
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
    if (pipeline) |self| _ = smp_unload(self);
}
pub fn deinit() void {
    if (pipeline) |self| {
        _ = smp_unload(self);
        smp_dtor(self);
        pipeline = null;
    }
}
