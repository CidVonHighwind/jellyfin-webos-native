//! Jellyfin playback through LG's Starfish media pipeline.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const wl = @import("../sdl.zig");
const smp = @import("starfish.zig");

extern fn jf_demux_open(url: [*:0]const u8) ?*anyopaque;
extern fn jf_demux_close(demux: *anyopaque) void;
extern fn jf_demux_stream_count(demux: *anyopaque) c_int;
extern fn jf_demux_stream(demux: *anyopaque, index: c_int, kind: *c_int, codec: *c_int, width: *c_int, height: *c_int) c_int;
extern fn jf_demux_next(demux: *anyopaque, data: *?[*]u8, size: *c_int, stream: *c_int, pts: *i64) c_int;
extern fn jf_demux_video_fps(demux: *anyopaque, index: c_int, num: *c_int, den: *c_int) c_int;
extern fn jf_demux_audio_open(demux: *anyopaque, index: c_int, rate: *c_int) c_int;
extern fn jf_demux_video_open(demux: *anyopaque, index: c_int) c_int;
extern fn jf_demux_video_unsupported(demux: *anyopaque) c_int;
extern fn jf_demux_audio_decode(demux: *anyopaque, out: *?[*]u8, size: *c_int) c_int;
extern fn jf_demux_seek(demux: *anyopaque, position_ns: i64) c_int;
extern fn jf_demux_reopen(demux: *anyopaque, url: [*:0]const u8) c_int;

const VideoType = enum(u32) { h264 = 1, h265 = 2, vp9 = 3, av1 = 4 };

var running = std.atomic.Value(bool).init(false);
/// True while a stretch of playback is flowing. A seek clears it to park the
/// reader and both feed threads without unloading the pipeline; `running`
/// stays set, so the session survives and only the segment restarts.
var segment = std.atomic.Value(bool).init(false);
fn flowing() bool {
    return running.load(.acquire) and segment.load(.acquire);
}
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
/// Starfish uses libc and needs nothing from the app's IO; the hook exists
/// because both backends expose it.
pub fn init(_: std.Io) void {}
/// False: the video is on the TV's own plane, not in our framebuffer, so the
/// app punches a transparent hole rather than drawing a background.
pub fn embedded() bool {
    return false;
}
pub fn render(_: u32, _: u32) void {}

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
        32797 => .av1,
        else => null,
    };
}
const max_uri_len = 2047;
var uri: [max_uri_len + 1]u8 = @splat(0);
/// What to ask for instead when the original is beyond the decoder. Empty
/// means there is nothing else to try.
var fallback: [max_uri_len + 1]u8 = @splat(0);
var fallback_len: usize = 0;
const app_id = "dev.hookedbehemoth.jellyfin";
var read_video: c_int = -1;
var read_audio: c_int = -1;
var window_id: [*:0]const u8 = undefined;
var transcode_sequence = std.atomic.Value(u32).init(0);

/// Jellyfin keys a running transcode by PlaySessionId.  Seeking needs a new
/// job; reusing the id simply reconnects to the first job, whose output starts
/// at zero regardless of StartTimeTicks.
fn playSessionId(buffer: []u8) []const u8 {
    const stamp = nowNs();
    const sequence = transcode_sequence.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buffer, "{x:0>8}-{x:0>4}-4{x:0>3}-8{x:0>3}-{x:0>12}", .{
        @as(u32, @truncate(stamp)),
        @as(u16, @truncate(stamp >> 32)),
        @as(u16, @truncate(stamp >> 48)) & 0x0fff,
        @as(u16, @truncate(sequence)) & 0x0fff,
        (stamp ^ (@as(u64, sequence) << 32)) & 0x0000ffffffffffff,
    }) catch "";
}

fn feed() void {
    const z: [*:0]const u8 = @ptrCast(&uri);
    const demux = jf_demux_open(z) orelse {
        setError("FFmpeg could not open the Jellyfin stream");
        running.store(false, .release);
        return;
    };
    defer jf_demux_close(demux);
    // Before anything is read: a 10-bit or above-High source will never
    // decode, so swap to the transcode URL while the demuxer is still fresh
    // and let the discovery below run against what the server sends instead.
    var transcoded = false;
    if (jf_demux_video_unsupported(demux) != 0 and fallback_len > 0) {
        std.debug.print("Jellyfin: source is beyond the decoder, transcoding\n", .{});
        var id: [36]u8 = undefined;
        const url = std.fmt.bufPrintZ(&uri, "{s}&PlaySessionId={s}&StartTimeTicks=0", .{
            std.mem.sliceTo(&fallback, 0), playSessionId(&id),
        }) catch {
            setError("The server transcode URL is too long");
            running.store(false, .release);
            return;
        };
        if (jf_demux_reopen(demux, url.ptr) == 0) {
            setError("The server would not transcode this item");
            running.store(false, .release);
            return;
        }
        transcoded = true;
    }
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
    // The pipeline takes PCM, MP3 or Opus; only PCM builds an audio sink on
    // this TV, so everything is decoded to PCM first.
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
    _ = jf_demux_video_open(demux, video_stream);
    var fps_num: c_int = 0;
    var fps_den: c_int = 0;
    _ = jf_demux_video_fps(demux, video_stream, &fps_num, &fps_den);
    smp.load(app_id, std.mem.sliceTo(window_id, 0), .{
        .width = width,
        .height = height,
        .codec = codecName(videoType(codec).?),
        .fps_num = fps_num,
        .fps_den = fps_den,
    }, audio, onLoad) catch {
        setError(smp.lastError());
        running.store(false, .release);
        return;
    };
    defer smp.deinit(); // not just Unload: the object does not survive a reload
    // Play before feeding: a merely loaded pipeline does not reliably accept
    // buffers. The cushion comes from priming, not from withholding this.
    if (!smp.play()) std.debug.print("SMP Play failed: {s}\n", .{smp.lastError()});
    playback_state.store(@intFromEnum(State.playing), .release);
    while (running.load(.acquire)) {
        segment.store(true, .release);
        runSegment(demux);
        if (!seek_pending.load(.acquire)) break;
        seek_pending.store(false, .release);
        seekTo(demux, seek_to_ms, transcoded);
    }
    running.store(false, .release);
}

/// In-place seek: keep the pipeline loaded and re-anchor it. Runs between
/// segments, so the reader and both feed threads are already joined and the
/// queues and clock are ours alone.
fn seekTo(demux: *anyopaque, target_ms: i32, transcoded: bool) void {
    // Paused first: setTimeToDecode refuses to run while playing. Both take 0,
    // not the target -- `pace` rebases every segment to zero, so zero is where
    // the pipeline's new segment begins.
    _ = smp.pause();
    if (!smp.flush(0)) std.debug.print("SMP flush refused\n", .{});
    if (!smp.setTimeToDecode(0)) std.debug.print("SMP setTimeToDecode refused\n", .{});
    // A live transcode has no byte ranges. av_seek_frame nevertheless reports
    // success for it, but positions FFmpeg at byte zero; always ask Jellyfin
    // to create a new segment at the desired time instead. Static originals
    // seek locally, falling back to a re-open only when that fails.
    const moved = if (transcoded)
        reopenAt(demux, target_ms, true)
    else
        jf_demux_seek(demux, @as(i64, target_ms) * std.time.ns_per_ms) != 0 or reopenAt(demux, target_ms, false);
    std.debug.print("Jellyfin seek: target={d}ms source={s} moved={}\n", .{
        target_ms,
        if (transcoded) "transcode" else "static",
        moved,
    });
    if (!moved) {
        setError("Could not seek this Jellyfin stream");
        playback_state.store(@intFromEnum(State.failed), .release);
        return;
    }
    stream_base_ms = target_ms;
    video_queue.reset();
    audio_queue.reset();
    // The first packet after the seek re-anchors the clock.
    clock_ready.store(false, .release);
    primed.store(false, .release);
    position_ms.store(target_ms, .monotonic);
    _ = smp.play();
}

/// Ask the server for the same stream from `target_ms` on. Jellyfin's
/// transcoding endpoint takes the offset as `StartTimeTicks` -- a tick is
/// 100 ns, so a millisecond is ten thousand of them -- and what comes back is
/// a fresh stream numbered from zero.
fn reopenAt(demux: *anyopaque, target_ms: i32, transcoded: bool) bool {
    var buffer: [max_uri_len + 96]u8 = undefined;
    // Use the route's canonical Pascal-case spelling. ASP.NET's current
    // binder is case-insensitive, but older Jellyfin servers route the
    // lower-case spelling through the opaque stream-options map instead of
    // binding it to VideoRequestDto.StartTimeTicks.
    var id: [36]u8 = undefined;
    const url = if (transcoded)
        std.fmt.bufPrintZ(&buffer, "{s}&PlaySessionId={s}&StartTimeTicks={d}", .{
            std.mem.sliceTo(&fallback, 0), playSessionId(&id), @as(i64, target_ms) * 10_000,
        }) catch return false
    else
        std.fmt.bufPrintZ(&buffer, "{s}&StartTimeTicks={d}", .{
            std.mem.sliceTo(&uri, 0), @as(i64, target_ms) * 10_000,
        }) catch return false;
    if (jf_demux_reopen(demux, url.ptr) == 0) return false;
    if (transcoded) {
        @memcpy(uri[0..url.len], url);
        uri[url.len] = 0;
    }
    // A re-cut stream is a new stream, and nothing promises it numbers its
    // tracks the way the last one did.
    const had_audio = read_audio >= 0;
    read_video = -1;
    read_audio = -1;
    for (0..@intCast(jf_demux_stream_count(demux))) |i| {
        var kind: c_int = 0;
        var codec: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;
        if (jf_demux_stream(demux, @intCast(i), &kind, &codec, &w, &h) == 0) continue;
        if (read_video < 0 and kind == 0 and videoType(codec) != null) read_video = @intCast(i);
        if (read_audio < 0 and kind == 1 and had_audio) read_audio = @intCast(i);
    }
    if (read_video < 0) return false;
    _ = jf_demux_video_open(demux, read_video);
    // The decoder went with the old source.
    if (read_audio >= 0) {
        var rate: c_int = 0;
        if (jf_demux_audio_open(demux, read_audio, &rate) == 0) read_audio = -1;
    }
    return true;
}

/// One stretch of uninterrupted playback: demux ahead, feed both lanes, and
/// return when the stream ends, playback stops, or a seek parks the segment.
fn runSegment(demux: *anyopaque) void {
    // The pipeline presents what it is given as it arrives, so we hold the
    // clock. Reading ahead happens on its own thread: a stall in av_read_frame
    // must not land on a frame deadline.
    const reader = std.Thread.spawn(.{}, read, .{demux}) catch |err| {
        setError(@errorName(err));
        running.store(false, .release);
        return;
    };
    // Audio gets its own thread: on a shared one, a chunk of audio due later
    // holds up every video frame queued behind it.
    var audio_feeder: ?std.Thread = null;
    defer {
        // Clearing this first is what lets both threads fall out of their
        // queues; joining before it would wait forever.
        segment.store(false, .release);
        reader.join();
        if (audio_feeder) |t| t.join();
    }
    if (read_audio >= 0) audio_feeder = std.Thread.spawn(.{}, feedAudio, .{}) catch null;

    while (video_queue.pop()) |chunk| {
        defer std.heap.c_allocator.free(chunk.bytes);
        const pts = pace(chunk.pts);
        if (!feedRetrying(.video, chunk.bytes, pts)) {
            setError(smp.lastError());
            playback_state.store(@intFromEnum(State.failed), .release);
            break;
        }
        position_ms.store(stream_base_ms + @as(i32, @intCast(@divTrunc(pts, std.time.ns_per_ms))), .monotonic);
        // A second of video is in: start the clock, and from here the pacing
        // keeps that same second as the cushion.
        if (!primed.load(.acquire) and pts >= prime_ns) {
            clock_ns = nowNs();
            primed.store(true, .release);
        }
    }
}

/// Audio runs on the same clock as video, so the two stay aligned without
/// sharing a thread.
fn feedAudio() void {
    while (audio_queue.pop()) |chunk| {
        defer std.heap.c_allocator.free(chunk.bytes);
        const pts = pace(chunk.pts);
        // A chunk the sink will not take costs a gap in the sound, not the
        // whole playback, so a lost race here is not fatal.
        _ = feedRetrying(.audio, chunk.bytes, pts);
    }
}

/// Demux ahead of playback, decoding audio on the way, until a queue is full.
fn read(demux: *anyopaque) void {
    var packet: ?[*]u8 = null;
    var size: c_int = 0;
    var stream: c_int = 0;
    var pts: i64 = 0;
    while (flowing() and jf_demux_next(demux, &packet, &size, &stream, &pts) != 0) {
        if ((stream != read_video and stream != read_audio) or size <= 0) continue;
        var bytes: []const u8 = (packet orelse continue)[0..@intCast(size)];
        const audio = stream == read_audio;
        if (audio) {
            var pcm: ?[*]u8 = null;
            var pcm_size: c_int = 0;
            if (jf_demux_audio_decode(demux, &pcm, &pcm_size) == 0) continue;
            bytes = (pcm orelse continue)[0..@intCast(pcm_size)];
        }
        // The clock origin belongs here, not in the feed threads: the reader
        // sees packets in container order, so the first one is the earliest.
        // Two feed threads racing for it would send the loser negative, and
        // libpf reads a negative pts as an enormous unsigned one.
        if (!clock_ready.load(.acquire)) {
            clock_pts = pts;
            clock_ready.store(true, .release);
        }
        // Both buffers belong to the demuxer and die on the next read.
        const copy = std.heap.c_allocator.dupe(u8, bytes) catch break;
        const target = if (audio) &audio_queue else &video_queue;
        if (!target.push(.{ .bytes = copy, .stream = stream, .pts = pts })) break;
    }
    video_queue.finish();
    audio_queue.finish();
}

// One clock for both feed threads. Plain values: 64-bit atomics do not exist
// on this target, so a flag with release/acquire ordering hands them over.
var clock_pts: i64 = 0;
var clock_ns: u64 = 0;
var clock_ready = std.atomic.Value(bool).init(false);
/// False until the pipeline has a cushion. Until then both lanes feed flat
/// out -- an empty pipeline shows one frame and then stalls.
var primed = std.atomic.Value(bool).init(false);

/// Sleep until this packet is due, and return its stream-relative timestamp.
fn pace(packet_pts: i64) i64 {
    // Stream-relative, not container-absolute: we call Play(), so the pipeline
    // has a base time and container timestamps start wherever they like.
    // Clamped because a stream can hand us a packet older than its first.
    const pts = @max(0, packet_pts - clock_pts);
    if (!primed.load(.acquire)) return pts; // priming: as fast as it will take
    const due = clock_ns + @as(u64, @intCast(pts));
    const now = nowNs() + prime_ns;
    // JF_NOPACE=1 feeds flat out: correct speed then means the pipeline is
    // clocking on the PTS itself, and this pacing can go.
    if (due > now and c.getenv("JF_NOPACE") == null) sleepPaced(due - now);
    return pts;
}

/// Content buffered before Play(), and the cushion kept afterwards.
const prime_ns = 1000 * std.time.ns_per_ms;

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
        while (flowing()) {
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
        if (!flowing()) return null; // a stop or a seek drops what is queued
        const r = self.read.load(.monotonic);
        while (r == self.write.load(.acquire)) {
            if (self.done.load(.acquire) or !flowing()) return null;
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

/// Feed one chunk, waiting out backpressure. A full pipeline answers
/// BufferFull and keeps nothing, so the chunk has to be offered again.
fn feedRetrying(lane: Lane, bytes: []const u8, pts: i64) bool {
    var tries: u32 = 0;
    while (flowing()) : (tries += 1) {
        const status = switch (lane) {
            .video => smp.feedVideo(bytes, pts),
            .audio => smp.feedAudio(bytes, pts),
        };
        switch (status) {
            .ok => return true,
            .failed => {
                std.debug.print("{s} feed rejected at pts={d}ms: {s}\n", .{
                    @tagName(lane), @divTrunc(pts, std.time.ns_per_ms), smp.lastError(),
                });
                return false;
            },
            .buffer_full => {
                if (tries > 600) return false; // 3s: something is wedged
                sleepNs(5 * std.time.ns_per_ms);
            },
        }
    }
    return false;
}
const Lane = enum(u8) { video, audio };

/// A pacing sleep a stop can cut short, so teardown does not wait out a
/// second of cushion.
fn sleepPaced(ns: u64) void {
    var left = ns;
    while (left > 0 and flowing()) {
        const slice = @min(left, 20 * std.time.ns_per_ms);
        sleepNs(slice);
        left -= slice;
    }
}

fn sleepNs(ns: u64) void {
    const ts = linux.timespec{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = linux.nanosleep(&ts, null);
}

/// Where the feed has got to, in stream milliseconds. This is the *fed*
/// position, which runs prime_ns ahead of what is on screen -- close enough to
/// seek relative to, and the only position we have that does not depend on the
/// pipeline reporting one.
var position_ms = std.atomic.Value(i32).init(0);
/// Where in the item the current source starts. Zero for a stream opened from
/// the beginning, the seek target for one the server re-cut at an offset.
var stream_base_ms: i32 = 0;
var seek_pending = std.atomic.Value(bool).init(false);
var seek_to_ms: i32 = 0;

pub fn position() i32 {
    return position_ms.load(.monotonic);
}

/// Jump `delta_seconds` from where the feed is. The segment loop performs the
/// seek once both feed threads have parked, so this only has to ask.
pub fn seek(delta_seconds: i32) void {
    if (!running.load(.acquire)) return;
    seek_to_ms = @max(0, position_ms.load(.monotonic) + delta_seconds * 1000);
    seek_pending.store(true, .release);
    segment.store(false, .release);
}

var session: ?std.Thread = null;

pub fn play(stream_uri: []const u8, transcode_uri: []const u8, width: u32, height: u32) !void {
    std.log.debug("stream: {s}, transcode: {s}", .{ stream_uri, transcode_uri });
    if (running.load(.acquire)) return error.AlreadyPlaying;
    // The previous session unloads the pipeline on its way out, and that must
    // land before the next Load.
    if (session) |t| {
        t.join();
        session = null;
    }
    @memset(&error_text, 0);
    playback_state.store(@intFromEnum(State.loading), .release);
    const rect = [4]i32{ 0, 0, @intCast(width), @intCast(height) };
    window_id = try wl.exportVideoWindow(rect, rect);
    try smp.init(app_id);
    if (stream_uri.len >= uri.len or transcode_uri.len >= fallback.len) return error.UriTooLong;
    @memcpy(uri[0..stream_uri.len], stream_uri);
    uri[stream_uri.len] = 0;
    fallback_len = transcode_uri.len;
    @memcpy(fallback[0..fallback_len], transcode_uri[0..fallback_len]);
    fallback[fallback_len] = 0;
    video_queue.reset();
    audio_queue.reset();
    clock_ready.store(false, .release);
    primed.store(false, .release);
    seek_pending.store(false, .release);
    position_ms.store(0, .monotonic);
    stream_base_ms = 0;
    running.store(true, .release);
    session = try std.Thread.spawn(.{}, feed, .{});
}
pub fn pause() void {
    _ = smp.pause();
}
pub fn resumePlayback() void {
    _ = smp.play();
}
pub fn stop() void {
    running.store(false, .release);
    segment.store(false, .release);
    playback_state.store(@intFromEnum(State.idle), .release);
}
pub fn deinit() void {
    stop();
    if (session) |t| {
        t.join();
        session = null;
    }
    smp.deinit();
}
