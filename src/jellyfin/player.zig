//! Jellyfin playback through the documented NDL DirectMedia v2 packet API.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const wl = @import("../wl.zig");

extern fn jf_demux_open(url: [*:0]const u8) ?*anyopaque;
extern fn jf_demux_close(demux: *anyopaque) void;
extern fn jf_demux_stream_count(demux: *anyopaque) c_int;
extern fn jf_demux_stream(demux: *anyopaque, index: c_int, kind: *c_int, codec: *c_int, width: *c_int, height: *c_int) c_int;
extern fn jf_demux_next(demux: *anyopaque, data: *?[*]u8, size: *c_int, stream: *c_int, pts: *i64) c_int;
extern fn jf_demux_audio_open(demux: *anyopaque, index: c_int, rate: *c_int) c_int;
extern fn jf_demux_audio_decode(demux: *anyopaque, out: *?[*]u8, size: *c_int) c_int;

// NDL_DIRECTMEDIA_DATA_INFO_T, webosbrew/webos-userland include/libndl-media.
// The audio member is a union over a 32-byte payload; the arm selected by
// `type` is the only part NDL reads, everything else must stay zero.
const VideoType = enum(u32) { h264 = 1, h265 = 2, vp9 = 3, av1 = 4 };
const AudioType = enum(u32) { none = 0, pcm = 1, mp3 = 2, opus = 3 };
/// Not sorted by frequency; 22.05 kHz really is 8. Zero means "bypass" and
/// crashes the pipeline, so an unlisted rate means no audio at all.
const SampleRate = enum(u32) {
    none = 0,
    hz_48000 = 1,
    hz_44100 = 2,
    hz_32000 = 3,
    hz_24000 = 4,
    hz_16000 = 5,
    hz_12000 = 6,
    hz_8000 = 7,
    hz_22050 = 8,

    fn of(hertz: c_int) SampleRate {
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
const PcmInfo = extern struct {
    type: AudioType = .pcm,
    unknown1: i32 = 0,
    format: [*:0]const u8 = "S16LE",
    layout: [*:0]const u8 = "interleaved",
    channel_mode: [*:0]const u8 = "stereo",
    sample_rate: SampleRate,
};
const DataInfo = extern struct {
    video: extern struct { width: i32, height: i32, type: VideoType, unknown1: i32 = 0 },
    audio: extern union { type: AudioType, pcm: PcmInfo, padding: [32]u8 },
};

comptime {
    // NDL reads fixed offsets; a drifting layout is silent corruption.
    std.debug.assert(@sizeOf(DataInfo) == 48);
    std.debug.assert(@offsetOf(DataInfo, "audio") == 16);
    std.debug.assert(@offsetOf(PcmInfo, "channel_mode") == 16);
    std.debug.assert(@offsetOf(PcmInfo, "sample_rate") == 20);
}

var ndl: ?*anyopaque = null;
var dl_init: *const fn () callconv(.c) bool = undefined;
var media_init: *const fn ([*:0]const u8) callconv(.c) i32 = undefined;
var set_window: *const fn ([*:0]const u8) callconv(.c) i32 = undefined;
var media_load: *const fn (*DataInfo, ?*const fn (i32, i64, ?[*:0]const u8) callconv(.c) void) callconv(.c) i32 = undefined;
var media_unload: *const fn () callconv(.c) i32 = undefined;
var media_quit: *const fn () callconv(.c) i32 = undefined;
var media_error: *const fn () callconv(.c) ?[*:0]const u8 = undefined;
var set_state: *const fn (u32) callconv(.c) i32 = undefined;
var video_play: *const fn (*const anyopaque, u32, i64) callconv(.c) i32 = undefined;
var audio_play: *const fn (*const anyopaque, u32, i64) callconv(.c) i32 = undefined;
var audio_room: *const fn (*c_int) callconv(.c) i32 = undefined;
var running = std.atomic.Value(bool).init(false);
pub const State = enum(u8) { idle, loading, playing, failed };
var playback_state = std.atomic.Value(u8).init(@intFromEnum(State.idle));
var error_text: [160]u8 = @splat(0);

fn sym(comptime T: type, name: [*:0]const u8) !T {
    return @ptrCast(@alignCast(c.dlsym(ndl, name) orelse return error.MissingNdlSymbol));
}
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

fn openNdl(window: [*:0]const u8) !void {
    if (ndl == null) {
        ndl = c.dlopen("libNDL_directmedia.so.1", .{ .NOW = true }) orelse return error.NoNdlDirectMedia;
        dl_init = try sym(@TypeOf(dl_init), "NDL_DirectMedia_DL_Initialize");
        if (!dl_init()) return error.NdlDlInitFailed;
        media_init = try sym(@TypeOf(media_init), "NDL_DirectMediaInit");
        set_window = try sym(@TypeOf(set_window), "NDL_DirectMediaSetWindowId");
        media_load = try sym(@TypeOf(media_load), "NDL_DirectMediaLoad");
        media_unload = try sym(@TypeOf(media_unload), "NDL_DirectMediaUnload");
        media_quit = try sym(@TypeOf(media_quit), "NDL_DirectMediaQuit");
        media_error = try sym(@TypeOf(media_error), "NDL_DirectMediaGetError");
        set_state = try sym(@TypeOf(set_state), "NDL_DirectMediaSetAppState");
        video_play = try sym(@TypeOf(video_play), "NDL_DirectVideoPlay");
        audio_play = try sym(@TypeOf(audio_play), "NDL_DirectAudioPlay");
        audio_room = try sym(@TypeOf(audio_room), "NDL_DirectAudioGetAvailableBufferSize");
    }
    if (set_window(window) != 0) return error.NdlWindowFailed;
    if (media_init("dev.hookedbehemoth.jellyfin") != 0) return error.NdlMediaInitFailed;
}

/// NDL reports pipeline state and errors here. Passing null hides exactly the
/// failure we are chasing, so always pass this.
fn onLoad(kind: i32, num: i64, str: ?[*:0]const u8) callconv(.c) void {
    std.debug.print("NDL event: type={d} value={d} text={s}\n", .{
        kind, num, if (str) |t| std.mem.sliceTo(t, 0) else "",
    });
}
fn videoType(codec: c_int) ?VideoType {
    return switch (codec) {
        27 => .h264,
        173 => .h265,
        167 => .vp9,
        226 => .av1,
        else => null,
    };
}
var uri: [1025]u8 = @splat(0);

fn feed() void {
    const z: [*:0]const u8 = @ptrCast(&uri);
    const demux = jf_demux_open(z) orelse {
        setError("FFmpeg could not open the Jellyfin stream");
        running.store(false, .release);
        return;
    };
    defer jf_demux_close(demux);
    var video_stream: c_int = -1;
    var audio_stream: c_int = -1;
    var codec: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    for (0..@intCast(jf_demux_stream_count(demux))) |i| {
        var kind: c_int = 0;
        var candidate: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;
        if (jf_demux_stream(demux, @intCast(i), &kind, &candidate, &w, &h) == 0) continue;
        std.debug.print("Jellyfin stream {d}: type={d} codec={d} {d}x{d}\n", .{ i, kind, candidate, w, h });
        if (video_stream < 0 and kind == 0 and videoType(candidate) != null) {
            video_stream = @intCast(i);
            codec = candidate;
            width = w;
            height = h;
        }
        if (audio_stream < 0 and kind == 1) audio_stream = @intCast(i);
    }
    // Escape hatch: JF_NOAUDIO=1 loads and feeds video only.
    if (c.getenv("JF_NOAUDIO") != null) audio_stream = -1;
    if (video_stream < 0 or width <= 0 or height <= 0) {
        setError("No DirectMedia-compatible video stream");
        running.store(false, .release);
        return;
    }
    // NDL takes PCM, MP3 or Opus only, and its MP3 arm never builds an audio
    // pipeline here (g_object_set on a null appsrc at Load), so decode to PCM.
    var info = std.mem.zeroes(DataInfo);
    info.video = .{ .width = width, .height = height, .type = videoType(codec).? };
    if (audio_stream >= 0) {
        var rate: c_int = 0;
        const sample_rate = if (jf_demux_audio_open(demux, audio_stream, &rate) != 0)
            SampleRate.of(rate)
        else
            SampleRate.none;
        if (sample_rate == .none) {
            std.debug.print("Jellyfin: no usable audio decode ({d} Hz), playing video only\n", .{rate});
            audio_stream = -1;
        } else {
            info.audio.pcm = .{ .sample_rate = sample_rate };
        }
    }
    if (media_load(&info, onLoad) != 0) {
        setError(std.mem.sliceTo(media_error() orelse "NDL load failed", 0));
        running.store(false, .release);
        return;
    }
    defer _ = media_unload();
    // FOREGROUND after Load, as ndlplay does: before Load it does not stick.
    _ = set_state(0);
    playback_state.store(@intFromEnum(State.playing), .release);
    // The pipeline presents what it is given as it arrives, so we hold the
    // clock. Reading ahead happens on its own thread: a stall in av_read_frame
    // must not land on a frame deadline.
    queue.video = video_stream;
    queue.audio = audio_stream;
    const reader = std.Thread.spawn(.{}, read, .{demux}) catch |err| {
        setError(@errorName(err));
        running.store(false, .release);
        return;
    };
    defer {
        running.store(false, .release);
        reader.join();
    }
    var origin_pts: ?i64 = null;
    var origin_ns: u64 = 0;
    while (queue.pop()) |chunk| {
        defer std.heap.c_allocator.free(chunk.bytes);
        if (origin_pts == null) {
            origin_pts = chunk.pts;
            origin_ns = nowNs();
        }
        // A fixed lead, not a queue depth: enough to cover feed jitter without
        // handing the pipeline a burst it would play early.
        const elapsed: u64 = @intCast(@max(0, chunk.pts - origin_pts.?));
        const due = origin_ns + elapsed;
        const now = nowNs() + feed_lead_ns;
        if (due > now) sleepNs(due - now);
        if (chunk.stream == audio_stream) {
            // PCM is ~176 KB/s, so NDL's audio buffer does fill up. A rejected
            // chunk costs a gap in the sound, not the whole playback.
            waitFor(audio_room, @intCast(chunk.bytes.len), .at_least);
            if (audio_play(chunk.bytes.ptr, @intCast(chunk.bytes.len), chunk.pts) != 0)
                std.log.debug("audio dropped: {s}", .{std.mem.sliceTo(media_error() orelse "", 0)});
            continue;
        }
        if (video_play(chunk.bytes.ptr, @intCast(chunk.bytes.len), chunk.pts) != 0) {
            setError(std.mem.sliceTo(media_error() orelse "NDL packet feed failed", 0));
            playback_state.store(@intFromEnum(State.failed), .release);
            break;
        }
    }
    running.store(false, .release);
}

/// Demux ahead of playback, decoding audio on the way, until the queue is full.
fn read(demux: *anyopaque) void {
    var packet: ?[*]u8 = null;
    var size: c_int = 0;
    var stream: c_int = 0;
    var pts: i64 = 0;
    while (running.load(.acquire) and jf_demux_next(demux, &packet, &size, &stream, &pts) != 0) {
        if ((stream != queue.video and stream != queue.audio) or size <= 0) continue;
        var bytes: []const u8 = (packet orelse continue)[0..@intCast(size)];
        if (stream == queue.audio) {
            var pcm: ?[*]u8 = null;
            var pcm_size: c_int = 0;
            if (jf_demux_audio_decode(demux, &pcm, &pcm_size) == 0) continue;
            bytes = (pcm orelse continue)[0..@intCast(pcm_size)];
        }
        // Both buffers belong to the demuxer and die on the next read.
        const copy = std.heap.c_allocator.dupe(u8, bytes) catch break;
        if (!queue.push(.{ .bytes = copy, .stream = stream, .pts = pts })) break;
    }
    queue.finish();
}

/// How far ahead of the clock a packet is handed to NDL.
const feed_lead_ns = 60 * std.time.ns_per_ms;

/// Demuxed-and-ready data waiting for its presentation time. One producer
/// (the reader thread), one consumer (the feed loop), so plain atomics do;
/// both sides idle with a short sleep rather than a condition variable.
const Chunk = struct { bytes: []u8, stream: c_int, pts: i64 };
var queue: struct {
    const slots = 512;
    const capacity_bytes = 8 << 20; // ~4s of 1080p at 15 Mbit
    const idle_ns = 2 * std.time.ns_per_ms;

    ring: [slots]Chunk = undefined,
    write: std.atomic.Value(usize) = .init(0),
    read: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    video: c_int = -1,
    audio: c_int = -1,

    /// False once playback is over, and the chunk is then the caller's to free.
    fn push(self: *@This(), chunk: Chunk) bool {
        const w = self.write.load(.monotonic);
        while (running.load(.acquire)) {
            const full = (w + 1) % slots == self.read.load(.acquire) or
                self.bytes.load(.monotonic) >= capacity_bytes;
            if (!full) break;
            sleepNs(idle_ns);
        } else {
            std.heap.c_allocator.free(chunk.bytes);
            return false;
        }
        self.ring[w] = chunk;
        _ = self.bytes.fetchAdd(chunk.bytes.len, .monotonic);
        self.write.store((w + 1) % slots, .release);
        return true;
    }

    fn pop(self: *@This()) ?Chunk {
        if (!running.load(.acquire)) return null; // stop() drops what is queued
        const r = self.read.load(.monotonic);
        while (r == self.write.load(.acquire)) {
            if (self.done.load(.acquire) or !running.load(.acquire)) return null;
            sleepNs(idle_ns);
        }
        const chunk = self.ring[r];
        _ = self.bytes.fetchSub(chunk.bytes.len, .monotonic);
        self.read.store((r + 1) % slots, .release);
        return chunk;
    }

    /// End of stream: let the feed drain what is left, then stop.
    fn finish(self: *@This()) void {
        self.done.store(true, .release);
    }

    fn reset(self: *@This()) void {
        var r = self.read.raw;
        while (r != self.write.raw) : (r = (r + 1) % slots) std.heap.c_allocator.free(self.ring[r].bytes);
        self.read.raw = 0;
        self.write.raw = 0;
        self.bytes.raw = 0;
        self.done.raw = false;
    }
} = .{};

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Block until an NDL queue has room: video reports frames waiting, audio
/// reports bytes free. Bounded so a stalled pipeline cannot pin this thread.
fn waitFor(query: *const fn (*c_int) callconv(.c) i32, limit: c_int, comptime want: enum { at_most, at_least }) void {
    var spins: u32 = 0;
    while (running.load(.acquire) and spins < 400) : (spins += 1) {
        var value: c_int = 0;
        if (query(&value) != 0) return; // no reading: feed and let NDL judge
        const room = switch (want) {
            .at_most => value <= limit,
            .at_least => value >= limit,
        };
        if (room) return;
        sleepNs(5 * std.time.ns_per_ms);
    }
}

fn sleepNs(ns: u64) void {
    const ts = linux.timespec{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = linux.nanosleep(&ts, null);
}

pub fn play(stream_uri: []const u8, width: u32, height: u32) !void {
    if (running.load(.acquire)) return error.AlreadyPlaying;
    @memset(&error_text, 0);
    playback_state.store(@intFromEnum(State.loading), .release);
    const rect = [4]i32{ 0, 0, @intCast(width), @intCast(height) };
    const window = try wl.exportVideoWindow(rect, rect);
    try openNdl(window);
    if (stream_uri.len >= uri.len) return error.UriTooLong;
    @memcpy(uri[0..stream_uri.len], stream_uri);
    uri[stream_uri.len] = 0;
    queue.reset();
    running.store(true, .release);
    const thread = try std.Thread.spawn(.{}, feed, .{});
    thread.detach();
}
pub fn pause() void {}
pub fn resumePlayback() void {}
pub fn stop() void {
    running.store(false, .release);
    playback_state.store(@intFromEnum(State.idle), .release);
}
pub fn deinit() void {
    stop();
    if (ndl != null) _ = media_quit();
}
