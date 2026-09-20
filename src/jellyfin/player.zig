//! Jellyfin playback through LG's Starfish media pipeline. See starfish.zig
//! for why libNDL_directmedia is not in the picture.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const wl = @import("../wl.zig");
const smp = @import("starfish.zig");

extern fn jf_demux_open(url: [*:0]const u8) ?*anyopaque;
extern fn jf_demux_close(demux: *anyopaque) void;
extern fn jf_demux_stream_count(demux: *anyopaque) c_int;
extern fn jf_demux_stream(demux: *anyopaque, index: c_int, kind: *c_int, codec: *c_int, width: *c_int, height: *c_int) c_int;
extern fn jf_demux_next(demux: *anyopaque, data: *?[*]u8, size: *c_int, stream: *c_int, pts: *i64) c_int;
extern fn jf_demux_audio_open(demux: *anyopaque, index: c_int, rate: *c_int) c_int;
extern fn jf_demux_audio_decode(demux: *anyopaque, out: *?[*]u8, size: *c_int) c_int;

const VideoType = enum(u32) { h264 = 1, h265 = 2, vp9 = 3, av1 = 4 };

var running = std.atomic.Value(bool).init(false);
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

/// Pipeline state and errors arrive here.
fn onLoad(kind: i32, num: i64, str: ?[*:0]const u8) callconv(.c) void {
    std.debug.print("SMP event: type={d} value={d} text={s}\n", .{
        kind, num, if (str) |t| std.mem.sliceTo(t, 0) else "",
    });
}
fn codecName(kind: VideoType) []const u8 {
    return switch (kind) {
        .h264 => "H264",
        .h265 => "H265",
        .vp9 => "VP9",
        .av1 => "AV1",
    };
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
const app_id = "dev.hookedbehemoth.jellyfin";
var read_video: c_int = -1;
var read_audio: c_int = -1;
var window_id: [*:0]const u8 = undefined;

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
    // The pipeline takes PCM, MP3 or Opus only, and its MP3 path never builds
    // an audio sink on this TV, so everything is decoded to PCM first.
    var audio: ?smp.Audio = null;
    if (audio_stream >= 0) {
        var rate: c_int = 0;
        const sample_rate = if (jf_demux_audio_open(demux, audio_stream, &rate) != 0)
            smp.SampleRate.of(rate)
        else
            .none;
        if (sample_rate == .none) {
            std.debug.print("Jellyfin: no usable audio decode ({d} Hz), playing video only\n", .{rate});
            audio_stream = -1;
        } else {
            audio = .{ .sample_rate = sample_rate, .channels = 2 };
        }
    }
    read_video = video_stream;
    read_audio = audio_stream;
    smp.load(app_id, std.mem.sliceTo(window_id, 0), .{
        .width = width,
        .height = height,
        .codec = codecName(videoType(codec).?),
    }, audio, onLoad) catch {
        setError(smp.lastError());
        running.store(false, .release);
        return;
    };
    defer smp.unload();
    // Nothing else starts the pipeline: NDL never called Play either, which is
    // why it could not pause or resume.
    _ = smp.play();
    playback_state.store(@intFromEnum(State.playing), .release);
    // The pipeline presents what it is given as it arrives, so we hold the
    // clock. Reading ahead happens on its own thread: a stall in av_read_frame
    // must not land on a frame deadline.
    const reader = std.Thread.spawn(.{}, read, .{demux}) catch |err| {
        setError(@errorName(err));
        running.store(false, .release);
        return;
    };
    defer {
        running.store(false, .release);
        reader.join();
    }
    // Audio gets its own thread. Sharing one meant a chunk of audio due later
    // held up every video frame queued behind it, and waiting for room in the
    // audio sink stalled video as well -- with rendering on arrival, that
    // head-of-line blocking is visible as stutter.
    const audio_feeder = if (audio_stream >= 0) std.Thread.spawn(.{}, feedAudio, .{}) catch null else null;
    defer if (audio_feeder) |t| t.join();

    while (video_queue.pop()) |chunk| {
        defer std.heap.c_allocator.free(chunk.bytes);
        const pts = pace(chunk.pts);
        if (smp.feedVideo(chunk.bytes, pts) == .failed) {
            setError(smp.lastError());
            playback_state.store(@intFromEnum(State.failed), .release);
            break;
        }
    }
    running.store(false, .release);
}

/// Audio runs on the same clock as video -- one origin, set by whichever
/// stream is fed first -- so the two stay aligned without sharing a thread.
fn feedAudio() void {
    while (audio_queue.pop()) |chunk| {
        defer std.heap.c_allocator.free(chunk.bytes);
        const pts = pace(chunk.pts);
        // PCM is ~176 KB/s, so the audio sink does fill up. A rejected chunk
        // costs a gap in the sound, not the whole playback.
        waitForAudioRoom(@intCast(chunk.bytes.len));
        if (smp.feedAudio(chunk.bytes, pts) == .failed)
            std.log.debug("audio dropped: {s}", .{smp.lastError()});
    }
}

/// Demux ahead of playback, decoding audio on the way, until a queue is full.
fn read(demux: *anyopaque) void {
    var packet: ?[*]u8 = null;
    var size: c_int = 0;
    var stream: c_int = 0;
    var pts: i64 = 0;
    while (running.load(.acquire) and jf_demux_next(demux, &packet, &size, &stream, &pts) != 0) {
        if ((stream != read_video and stream != read_audio) or size <= 0) continue;
        var bytes: []const u8 = (packet orelse continue)[0..@intCast(size)];
        const audio = stream == read_audio;
        if (audio) {
            var pcm: ?[*]u8 = null;
            var pcm_size: c_int = 0;
            if (jf_demux_audio_decode(demux, &pcm, &pcm_size) == 0) continue;
            bytes = (pcm orelse continue)[0..@intCast(pcm_size)];
        }
        // Both buffers belong to the demuxer and die on the next read.
        const copy = std.heap.c_allocator.dupe(u8, bytes) catch break;
        const target = if (audio) &audio_queue else &video_queue;
        if (!target.push(.{ .bytes = copy, .stream = stream, .pts = pts })) break;
    }
    video_queue.finish();
    audio_queue.finish();
}

// One clock for both feed threads. Plain values, published by whichever
// stream is fed first: 64-bit atomics do not exist on this target, and the
// ready flag orders the handoff.
var clock_pts: i64 = 0;
var clock_ns: u64 = 0;
var clock_claimed = std.atomic.Value(bool).init(false);
var clock_ready = std.atomic.Value(bool).init(false);

/// Sleep until this packet is due, and return its stream-relative timestamp.
fn pace(packet_pts: i64) i64 {
    if (clock_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        clock_pts = packet_pts;
        clock_ns = nowNs();
        clock_ready.store(true, .release);
    }
    while (!clock_ready.load(.acquire) and running.load(.acquire)) sleepNs(std.time.ns_per_ms);
    // Stream-relative, not container-absolute: we call Play(), so the pipeline
    // has a base time and TS timestamps start wherever they like.
    const pts = packet_pts - clock_pts;
    const due = clock_ns + @as(u64, @intCast(@max(0, pts)));
    const now = nowNs() + feed_lead_ns;
    // JF_NOPACE=1 feeds flat out: correct speed then means the pipeline is
    // clocking on the PTS itself, and this pacing can go.
    if (due > now and c.getenv("JF_NOPACE") == null) sleepNs(due - now);
    return pts;
}

/// How far ahead of the clock a packet is handed to the pipeline.
const feed_lead_ns = 60 * std.time.ns_per_ms;

/// Demuxed-and-ready data waiting for its presentation time. One producer
/// (the reader thread), one consumer (the feed loop), so plain atomics do;
/// both sides idle with a short sleep rather than a condition variable.
const Chunk = struct { bytes: []u8, stream: c_int, pts: i64 };
const Queue = struct {
    const slots = 512;
    const capacity_bytes = 8 << 20; // ~4s of 1080p at 15 Mbit
    const idle_ns = 2 * std.time.ns_per_ms;

    ring: [slots]Chunk = undefined,
    write: std.atomic.Value(usize) = .init(0),
    read: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

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
};
var video_queue: Queue = .{};
var audio_queue: Queue = .{};

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Block until the audio sink can take this many bytes. Bounded, so a stalled
/// pipeline cannot pin the feed thread.
fn waitForAudioRoom(need: c_int) void {
    var spins: u32 = 0;
    while (running.load(.acquire) and spins < 400) : (spins += 1) {
        const room = smp.audioRoom() orelse return; // no reading: feed anyway
        if (room >= need) return;
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
    window_id = try wl.exportVideoWindow(rect, rect);
    try smp.init(app_id);
    if (stream_uri.len >= uri.len) return error.UriTooLong;
    @memcpy(uri[0..stream_uri.len], stream_uri);
    uri[stream_uri.len] = 0;
    video_queue.reset();
    audio_queue.reset();
    clock_claimed.store(false, .release);
    clock_ready.store(false, .release);
    running.store(true, .release);
    const thread = try std.Thread.spawn(.{}, feed, .{});
    thread.detach();
}
pub fn pause() void {
    _ = smp.pause();
}
pub fn resumePlayback() void {
    _ = smp.play();
}
pub fn stop() void {
    running.store(false, .release);
    playback_state.store(@intFromEnum(State.idle), .release);
}
pub fn deinit() void {
    stop();
    smp.deinit();
}
