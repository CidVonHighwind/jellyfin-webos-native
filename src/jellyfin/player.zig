//! Jellyfin playback through LG's Starfish media pipeline.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const wl = @import("../sdl.zig");
const smp = @import("starfish.zig");
const Queue = @import("packet_queue.zig").Queue;
var io: std.Io = undefined;
var segment_mutex: std.Io.Mutex = .init;
/// StarfishMediaAPIs is one C++ object. Feed, clock queries and state changes
/// must not enter it concurrently from the reader, audio and UI threads.
var pipeline_mutex: std.Io.Mutex = .init;
var interrupted: std.Io.Event = .unset;

extern fn jf_demux_open(url: [*:0]const u8) ?*anyopaque;
extern fn jf_demux_close(demux: *anyopaque) void;
extern fn jf_demux_stream_count(demux: *anyopaque) c_int;
extern fn jf_demux_stream(demux: *anyopaque, index: c_int, kind: *c_int, codec: *c_int, width: *c_int, height: *c_int) c_int;
extern fn jf_demux_next(demux: *anyopaque, data: *?[*]u8, size: *c_int, stream: *c_int, pts: *i64) c_int;
extern fn jf_demux_video_fps(demux: *anyopaque, index: c_int, num: *c_int, den: *c_int) c_int;
extern fn jf_demux_audio_open(demux: *anyopaque, index: c_int, rate: *c_int) c_int;
extern fn jf_demux_video_open(demux: *anyopaque, index: c_int) c_int;
extern fn jf_demux_video_unsupported(demux: *anyopaque) c_int;
extern fn jf_demux_audio_decode(demux: *anyopaque, out: *?[*]u8, size: *c_int, pts: *i64) c_int;
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
    std.debug.print("Jellyfin player error: {s}\n", .{message});
    setState(.failed);
}
fn setState(value: State) void {
    playback_state.store(@intFromEnum(value), .release);
    wl.wake();
}
pub fn lastError() []const u8 {
    return std.mem.sliceTo(&error_text, 0);
}
pub fn state() State {
    return @enumFromInt(playback_state.load(.acquire));
}
pub fn init(app_io: std.Io) void {
    io = app_io;
}
/// False: the video is on the TV's own plane, not in our framebuffer, so the
/// app punches a transparent hole rather than drawing a background.
pub fn embedded() bool {
    return false;
}
pub fn render(_: u32, _: u32) void {}
pub fn needsFrame() bool {
    return false; // Starfish presents video independently of the graphics plane.
}

var load_complete = std.atomic.Value(bool).init(false);
var pipeline_playing = std.atomic.Value(bool).init(false);
var frame_ready_count = std.atomic.Value(u32).init(0);

/// Pipeline state and errors arrive here. Frame-ready is deliberately counted
/// rather than printed per frame; the clock diagnostics below report the
/// timing data in a form that can be compared with the feed positions.
fn onLoad(kind: i32, num: i64, str: ?[*:0]const u8) callconv(.c) void {
    const event_text = if (smp.eventHasText(kind))
        if (str) |t| std.mem.sliceTo(t, 0) else ""
    else
        "";
    switch (kind) {
        0x0 => {
            if (frame_ready_count.fetchAdd(1, .monotonic) == 0)
                std.debug.print("Starfish first FRAME_READY value={d}\n", .{num});
            return;
        },
        0x16 => load_complete.store(true, .release),
        0x17 => {
            load_complete.store(false, .release);
            pipeline_playing.store(false, .release);
        },
        0x1a => pipeline_playing.store(true, .release),
        0x1b => pipeline_playing.store(false, .release),
        0x12, 0x13 => {
            var detail: [96]u8 = undefined;
            const message = if (event_text.len > 0)
                event_text
            else
                std.fmt.bufPrint(&detail, "Starfish pipeline error {d}", .{num}) catch "Starfish pipeline error";
            setError(message);
            running.store(false, .release);
        },
        else => {},
    }
    std.debug.print("SMP event: type={d} desc={s} value={d} text={s}\n", .{
        kind, smp.event_desc(kind), num, event_text,
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
        1 => .h264,
        2 => .h265,
        3 => .vp9,
        4 => .av1,
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
    defer {
        running.store(false, .release);
        if (state() != .failed) setState(.idle);
    }
    smp.init(app_id) catch {
        setError(smp.lastError());
        return;
    };
    defer smp.deinit();
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
            audio_rate = rate;
        }
    }
    read_video = video_stream;
    read_audio = audio_stream;
    _ = jf_demux_video_open(demux, video_stream);
    var fps_num: c_int = 0;
    var fps_den: c_int = 0;
    _ = jf_demux_video_fps(demux, video_stream, &fps_num, &fps_den);
    load_complete.store(false, .release);
    pipeline_playing.store(false, .release);
    frame_ready_count.store(0, .release);
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
    // Load returning only means that the request was accepted. Feeding and
    // Play belong after the asynchronous LOADCOMPLETED transition.
    while (running.load(.acquire) and !load_complete.load(.acquire))
        sleepNs(10 * std.time.ns_per_ms);
    if (!running.load(.acquire)) return;
    // The load payload describes the timeline, but libpf does not activate it
    // until CustomPipeline receives a segment event. Its public
    // setTimeToDecode wrapper rejects this LOADED state, so use the underlying
    // pipeline transition exposed by the SDK, as spool-mpv does.
    if (!pipelineBeginSegment(0)) {
        std.debug.print("Starfish segment setup failed: {s}\n", .{smp.segmentError()});
        setError("Starfish could not establish the initial media segment");
        running.store(false, .release);
        return;
    }
    std.debug.print("Starfish segment established at 0ns\n", .{});
    resetSegmentTimeline();
    setState(.playing);
    while (running.load(.acquire)) {
        segment_mutex.lockUncancelable(io);
        if (!running.load(.acquire)) {
            segment_mutex.unlock(io);
            break;
        }
        // Serialize new seek requests with segment startup. A request arriving
        // during a slow reopen stays pending for the next iteration.
        if (seek_pending.swap(false, .acq_rel)) {
            const target = seek_to_ms;
            segment_mutex.unlock(io);
            seekTo(demux, target, transcoded);
            continue;
        }
        video_queue.reset(io);
        audio_queue.reset(io);
        interrupted.reset();
        segment.store(true, .release);
        segment_mutex.unlock(io);
        runSegment(demux);
        if (!seek_pending.load(.acquire)) break;
    }
    running.store(false, .release);
}

/// In-place seek: keep the pipeline loaded and re-anchor it. Runs between
/// segments, so the reader and both feed threads are already joined and the
/// queues and clock are ours alone.
fn seekTo(demux: *anyopaque, target_ms: i32, transcoded: bool) void {
    // The source timestamps are rebased to zero for every segment.
    _ = pipelinePause();
    if (!pipelineFlush(0)) std.debug.print("SMP flush refused\n", .{});
    if (!pipelineBeginSegment(0)) std.debug.print("SMP segment restart refused: {s}\n", .{smp.segmentError()});
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
        running.store(false, .release);
        return;
    }
    stream_base_ms = target_ms;
    // The first packet after the seek re-anchors the clock.
    clock_ready.store(false, .release);
    resetSegmentTimeline();
    position_ms.store(target_ms, .monotonic);
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
        if (jf_demux_audio_open(demux, read_audio, &rate) == 0) read_audio = -1 else audio_rate = rate;
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
        interruptSegment();
        reader.join();
        if (audio_feeder) |t| t.join();
    }
    if (read_audio >= 0) audio_feeder = std.Thread.spawn(.{}, feedAudio, .{}) catch |err| {
        setError(@errorName(err));
        return;
    };

    while (video_queue.pop(io)) |chunk| {
        defer std.heap.c_allocator.free(chunk.bytes);
        if (!flowing()) break;
        const pts = pace(.video, chunk.pts);
        if (!feedRetrying(.video, chunk.bytes, pts)) {
            if (flowing()) setError(smp.lastError());
            break;
        }
        if (first_video_feed.swap(false, .acq_rel)) {
            std.debug.print("Starfish first video feed: raw={d:.3}s pts={d:.3}s bytes={d}\n", .{
                @as(f64, @floatFromInt(chunk.pts)) / std.time.ns_per_s,
                @as(f64, @floatFromInt(pts)) / std.time.ns_per_s,
                chunk.bytes.len,
            });
        }
        _ = fed_video_ms.fetchMax(nsToMs(pts), .release);
        maybeStartPipeline();
    }
}

/// Audio runs on the same clock as video, so the two stay aligned without
/// sharing a thread.
///
/// The PCM sink plays what it is handed back to back. A gap between two
/// chunks -- a dropped packet, a decoder that produced nothing, audio that
/// simply starts after the first video frame -- is therefore not heard as a
/// gap: everything after it plays that much early against the picture, and
/// stays that way. So timestamps come from our own running sample count and
/// any hole is filled with silence rather than closed up.
fn feedAudio() void {
    var cursor: i64 = -1; // next sample to feed, -1 before the first chunk
    while (audio_queue.pop(io)) |chunk| {
        defer std.heap.c_allocator.free(chunk.bytes);
        if (!flowing()) break;
        const want = samplesAt(pace(.audio, chunk.pts));
        cursor = alignCursor(cursor, want, audio_rate);
        while (cursor < want) {
            const run = @min(want - cursor, pcm_access_unit_samples);
            // A chunk the sink will not take costs a gap in the sound, not the
            // whole playback, so a lost race here is not fatal.
            if (!feedRetrying(.audio, silence[0..@intCast(run * pcm_frame)], nsAt(cursor))) return;
            cursor += run;
            _ = fed_audio_ms.fetchMax(nsToMs(nsAt(cursor)), .release);
            maybeStartPipeline();
            waitForVideoPreroll();
        }
        var offset: usize = 0;
        while (offset < chunk.bytes.len) {
            const bytes = @min(chunk.bytes.len - offset, pcm_access_unit_samples * pcm_frame);
            // The decoder always emits complete stereo S16 frames.
            const samples: i64 = @intCast(bytes / pcm_frame);
            const pts = nsAt(cursor);
            if (!feedRetrying(.audio, chunk.bytes[offset..][0..bytes], pts)) return;
            cursor += samples;
            offset += bytes;
            if (first_audio_feed.swap(false, .acq_rel)) {
                std.debug.print("Starfish first audio feed: raw={d:.3}s pts={d:.3}s end={d:.3}s bytes={d}\n", .{
                    @as(f64, @floatFromInt(chunk.pts)) / std.time.ns_per_s,
                    @as(f64, @floatFromInt(pts)) / std.time.ns_per_s,
                    @as(f64, @floatFromInt(nsAt(cursor))) / std.time.ns_per_s,
                    bytes,
                });
            }
            _ = fed_audio_ms.fetchMax(nsToMs(nsAt(cursor)), .release);
            maybeStartPipeline();
            waitForVideoPreroll();
        }
    }
}

/// Interleaved stereo S16, which is all jf_demux_audio_decode produces.
const pcm_frame = 4;
var silence: [pcm_access_unit_samples * pcm_frame]u8 = @splat(0);
/// Sample rate of that PCM, for turning sample counts into timestamps.
var audio_rate: i64 = 48000;
fn samplesAt(pts: i64) i64 {
    return @intCast(@divTrunc(@as(i128, pts) * audio_rate, std.time.ns_per_s));
}
fn nsAt(samples: i64) i64 {
    return @intCast(@divTrunc(@as(i128, samples) * std.time.ns_per_s, audio_rate));
}

/// Where the next chunk belongs in the PCM stream. Within a second of where
/// the last one ended, the count carries on (silence covers a gap, an overlap
/// is played late rather than dropped); past that it is a discontinuity, and
/// the stream restarts at the chunk's own timestamp.
fn alignCursor(cursor: i64, want: i64, rate: i64) i64 {
    if (cursor < 0 or @abs(want - cursor) > rate) return want;
    return cursor;
}

test "the PCM cursor bridges gaps but restarts on a discontinuity" {
    try std.testing.expectEqual(@as(i64, 4800), alignCursor(-1, 4800, 48000)); // first chunk
    try std.testing.expectEqual(@as(i64, 4800), alignCursor(4800, 5280, 48000)); // 10ms gap: pad
    try std.testing.expectEqual(@as(i64, 4800), alignCursor(4800, 4320, 48000)); // overlap: keep
    try std.testing.expectEqual(@as(i64, 96000), alignCursor(4800, 96000, 48000)); // seek: restart
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
            if (jf_demux_audio_decode(demux, &pcm, &pcm_size, &pts) == 0) continue;
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
        if (!target.push(io, .{ .bytes = copy, .pts = pts })) break;
    }
    video_queue.close(io);
    audio_queue.close(io);
}

// Container PTS are rebased to one segment timeline before either feed thread
// sees them. The release/acquire flag publishes the 64-bit origin on armv7.
var clock_pts: i64 = 0;
var clock_ready = std.atomic.Value(bool).init(false);

var paused = std.atomic.Value(bool).init(false);
var play_requested = std.atomic.Value(bool).init(false);
var fed_video_ms = std.atomic.Value(i32).init(std.math.minInt(i32));
var fed_audio_ms = std.atomic.Value(i32).init(std.math.minInt(i32));
var first_video_feed = std.atomic.Value(bool).init(true);
var first_audio_feed = std.atomic.Value(bool).init(true);

// These are queue bounds, not sync corrections. They match the proven mpv
// backend: enough video for decoder continuity, and a shorter PCM queue so
// stale audio cannot accumulate across pause or seek.
const video_feed_ahead_ns = 1600 * std.time.ns_per_ms;
const audio_feed_ahead_ns = 400 * std.time.ns_per_ms;
const audio_start_preroll_ms = 40;
// Starfish's PCM path expects short, regularly timestamped access units. This
// is also the unit used by ao_starfish; source PCM packets can be hundreds of
// milliseconds long and must not be handed to the sink as one access unit.
const pcm_access_unit_samples = 1024;
const clock_sample_period_ns = 20 * std.time.ns_per_ms;
const clock_slow_query_ns = 50 * std.time.ns_per_ms;
const clock_freshness_ns = 250 * std.time.ns_per_ms;
const clock_stability_ns = 250 * std.time.ns_per_ms;
const clock_backward_tolerance_ns = 100 * std.time.ns_per_ms;
const clock_fed_video_slack_ms = 500;
const playback_rate_millis = 1000;

const ClockState = struct {
    sample_valid: bool = false,
    sample_pts_ns: i64 = 0,
    sample_host_ns: i64 = 0,
    last_poll_host_ns: i64 = 0,
    last_attempt_ns: i64 = 0,
    probe_pts_ns: i64 = 0,
    probe_host_ns: i64 = 0,
    ready: bool = false,
    last_log_ns: i64 = 0,
    last_reject_log_ns: i64 = 0,

    fn reset(self: *@This()) void {
        self.* = .{};
    }

    /// Accept a frame-quantized getCurrentPlaytime sample. Repeated values keep
    /// the original anchor; when PTS advances, the flip is bracketed halfway
    /// between the previous and current polls.
    fn accept(self: *@This(), raw_pts_ns: i64, poll_host_ns: i64) bool {
        var pts_ns = raw_pts_ns;
        var anchor_ns = poll_host_ns;
        const was_ready = self.ready;
        if (self.sample_valid) {
            if (pts_ns + clock_backward_tolerance_ns < self.sample_pts_ns) return false;
            pts_ns = @max(pts_ns, self.sample_pts_ns);
            if (pts_ns == self.sample_pts_ns) {
                self.last_poll_host_ns = poll_host_ns;
                return false;
            }
            if (self.last_poll_host_ns > 0 and poll_host_ns > self.last_poll_host_ns and
                poll_host_ns - self.last_poll_host_ns <= 2 * clock_sample_period_ns)
            {
                anchor_ns = self.last_poll_host_ns + @divTrunc(poll_host_ns - self.last_poll_host_ns, 2);
            }
        }

        self.sample_valid = true;
        self.sample_pts_ns = pts_ns;
        self.sample_host_ns = anchor_ns;
        self.last_poll_host_ns = poll_host_ns;
        if (self.probe_host_ns == 0) {
            self.probe_pts_ns = pts_ns;
            self.probe_host_ns = anchor_ns;
        } else if (!self.ready and anchor_ns - self.probe_host_ns >= clock_stability_ns) {
            const wall = anchor_ns - self.probe_host_ns;
            const delta = pts_ns - self.probe_pts_ns;
            const rate_millis = @divTrunc(@as(i128, delta) * 1000, wall);
            if (delta >= 0 and rate_millis >= 800 and rate_millis <= 1200) {
                self.ready = true;
            } else {
                self.probe_pts_ns = pts_ns;
                self.probe_host_ns = anchor_ns;
            }
        }
        return !was_ready and self.ready;
    }

    fn project(self: *const @This(), now: i64, frozen: bool) ?i64 {
        if (!self.sample_valid or self.sample_host_ns <= 0) return null;
        if (frozen) return self.sample_pts_ns;
        const age = now - self.sample_host_ns;
        if (age < 0 or age > clock_freshness_ns) return null;
        return self.sample_pts_ns + @as(i64, @intCast(@divTrunc(@as(i128, age) * playback_rate_millis, 1000)));
    }
};

test "Starfish clock keeps the first poll anchor for a quantized frame" {
    var clock: ClockState = .{};
    const second: i64 = std.time.ns_per_s;
    try std.testing.expect(!clock.accept(0, second));
    try std.testing.expect(!clock.accept(0, second + 20 * std.time.ns_per_ms));
    try std.testing.expectEqual(second, clock.sample_host_ns);
    try std.testing.expectEqual(@as(?i64, 30 * std.time.ns_per_ms), clock.project(second + 30 * std.time.ns_per_ms, false));
}

test "Starfish clock becomes usable only after stable forward progress" {
    var clock: ClockState = .{};
    const second: i64 = std.time.ns_per_s;
    try std.testing.expect(!clock.accept(0, second));
    try std.testing.expect(!clock.accept(100 * std.time.ns_per_ms, second + 100 * std.time.ns_per_ms));
    try std.testing.expect(clock.accept(260 * std.time.ns_per_ms, second + 260 * std.time.ns_per_ms));
    try std.testing.expect(clock.ready);
    try std.testing.expectEqual(@as(?i64, null), clock.project(second + 260 * std.time.ns_per_ms + clock_freshness_ns + 1, false));
}

var clock_mutex: std.Io.Mutex = .init;
var display_clock: ClockState = .{};

fn shouldLogClockRejection(now: i64) bool {
    clock_mutex.lockUncancelable(io);
    defer clock_mutex.unlock(io);
    if (display_clock.last_reject_log_ns != 0 and now - display_clock.last_reject_log_ns < std.time.ns_per_s)
        return false;
    display_clock.last_reject_log_ns = now;
    return true;
}

fn resetSegmentTimeline() void {
    play_requested.store(false, .release);
    pipeline_playing.store(false, .release);
    fed_video_ms.store(std.math.minInt(i32), .release);
    fed_audio_ms.store(std.math.minInt(i32), .release);
    first_video_feed.store(true, .release);
    first_audio_feed.store(true, .release);
    clock_mutex.lockUncancelable(io);
    display_clock.reset();
    clock_mutex.unlock(io);
}

fn maybeStartPipeline() void {
    if (paused.load(.acquire) or play_requested.load(.acquire)) return;
    if (fed_video_ms.load(.acquire) < 0) return;
    if (read_audio >= 0 and fed_audio_ms.load(.acquire) < audio_start_preroll_ms) return;
    if (play_requested.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    std.debug.print("Starfish preroll ready: video={d}ms audio={d}ms; Play\n", .{
        fed_video_ms.load(.acquire), fed_audio_ms.load(.acquire),
    });
    if (!pipelinePlay()) {
        play_requested.store(false, .release);
        setError("Starfish Play failed after preroll");
        running.store(false, .release);
    }
}

/// Once the timestamped PCM preroll exists, give the video feeder the SDK
/// until it has established the other side of the timeline. Without this,
/// one large decoded PCM packet can win the feed lock repeatedly and enqueue
/// hundreds of milliseconds before the first video access unit.
fn waitForVideoPreroll() void {
    while (flowing() and !play_requested.load(.acquire) and
        fed_audio_ms.load(.acquire) >= audio_start_preroll_ms)
    {
        maybeStartPipeline();
        if (!play_requested.load(.acquire)) sleepPaced(2 * std.time.ns_per_ms);
    }
}

fn sampleClock() ?i64 {
    const now: i64 = @intCast(nowNs());
    clock_mutex.lockUncancelable(io);
    if (!pipeline_playing.load(.acquire)) {
        const held = display_clock.project(now, true);
        clock_mutex.unlock(io);
        return held;
    }
    if (display_clock.last_attempt_ns > 0 and now - display_clock.last_attempt_ns < clock_sample_period_ns) {
        const projected = display_clock.project(now, paused.load(.acquire));
        clock_mutex.unlock(io);
        return projected;
    }
    display_clock.last_attempt_ns = now;
    clock_mutex.unlock(io);

    const sample = pipelinePlaytimeSample() orelse return null;
    if (sample.duration_ns > clock_slow_query_ns) {
        if (shouldLogClockRejection(now))
            std.debug.print("Starfish clock rejected slow query={d:.1}ms\n", .{@as(f64, @floatFromInt(sample.duration_ns)) / std.time.ns_per_ms});
        return null;
    }
    const fed_ceiling_ms = fed_video_ms.load(.acquire);
    if (fed_ceiling_ms >= 0 and nsToMs(sample.pts_ns) > fed_ceiling_ms + clock_fed_video_slack_ms) {
        if (shouldLogClockRejection(now))
            std.debug.print("Starfish clock rejected ahead-of-feed pts={d}ms fed_video={d}ms\n", .{ nsToMs(sample.pts_ns), fed_ceiling_ms });
        return null;
    }

    clock_mutex.lockUncancelable(io);
    const became_ready = display_clock.accept(sample.pts_ns, sample.host_ns);
    const projected = display_clock.project(@intCast(nowNs()), paused.load(.acquire));
    const should_log = became_ready or display_clock.last_log_ns == 0 or now - display_clock.last_log_ns >= std.time.ns_per_s;
    if (should_log) display_clock.last_log_ns = now;
    const ready = display_clock.ready;
    clock_mutex.unlock(io);

    if (projected) |pts| {
        const pts_ms = nsToMs(pts);
        const fed_v = fed_video_ms.load(.acquire);
        const fed_a = fed_audio_ms.load(.acquire);
        if (ready) position_ms.store(stream_base_ms + pts_ms, .monotonic);
        if (should_log) std.debug.print(
            "Starfish clock: pts={d:.3}s projected={d:.3}s query={d:.1}ms stable={} feed_lead_v={d}ms feed_lead_a={d}ms frames={d}\n",
            .{
                @as(f64, @floatFromInt(sample.pts_ns)) / std.time.ns_per_s,
                @as(f64, @floatFromInt(pts)) / std.time.ns_per_s,
                @as(f64, @floatFromInt(sample.duration_ns)) / std.time.ns_per_ms,
                ready,
                if (fed_v >= 0) fed_v - pts_ms else -1,
                if (fed_a >= 0) fed_a - pts_ms else -1,
                frame_ready_count.load(.monotonic),
            },
        );
    }
    return projected;
}

/// Pace each source queue from Starfish's displayed-frame clock. Before the
/// first live sample, zero is the segment anchor and the same bounded preroll
/// rules apply; no host-time guess becomes part of the media timeline.
fn pace(lane: Lane, packet_pts: i64) i64 {
    const pts = @max(0, packet_pts - clock_pts);
    if (!play_requested.load(.acquire)) return pts;
    const feed_ahead: i64 = if (lane == .audio) audio_feed_ahead_ns else video_feed_ahead_ns;
    while (flowing()) {
        const clock = sampleClock() orelse 0;
        const limit = clock + feed_ahead;
        if (pts <= limit) break;
        sleepPaced(@intCast(@min(pts - limit, clock_sample_period_ns)));
    }
    return pts;
}

var video_queue: Queue = .{};
var audio_queue: Queue = .{};

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn nsToMs(ns: i64) i32 {
    return @intCast(std.math.clamp(@divTrunc(ns, std.time.ns_per_ms), std.math.minInt(i32), std.math.maxInt(i32)));
}

const PipelineClockSample = struct {
    pts_ns: i64,
    host_ns: i64,
    duration_ns: i64,
};

fn pipelinePlaytimeSample() ?PipelineClockSample {
    pipeline_mutex.lockUncancelable(io);
    defer pipeline_mutex.unlock(io);
    const before: i64 = @intCast(nowNs());
    const pts = smp.playtime();
    const after: i64 = @intCast(nowNs());
    if (pts < 0) return null;
    return .{
        .pts_ns = pts,
        .host_ns = before + @divTrunc(after - before, 2),
        .duration_ns = after - before,
    };
}

fn pipelinePlay() bool {
    pipeline_mutex.lockUncancelable(io);
    defer pipeline_mutex.unlock(io);
    if (!smp.play()) return false;
    if (!smp.setPlayRate(playback_rate_millis, true))
        std.debug.print("SMP SetPlayRate failed\n", .{});
    return true;
}

fn pipelinePause() bool {
    pipeline_mutex.lockUncancelable(io);
    defer pipeline_mutex.unlock(io);
    return smp.pause();
}

fn pipelineFlush(target: i64) bool {
    pipeline_mutex.lockUncancelable(io);
    defer pipeline_mutex.unlock(io);
    return smp.flush(target);
}

fn pipelineBeginSegment(target: i64) bool {
    pipeline_mutex.lockUncancelable(io);
    defer pipeline_mutex.unlock(io);
    return smp.beginSegment(target);
}

fn pipelineFeed(lane: Lane, bytes: []const u8, pts: i64) smp.Status {
    pipeline_mutex.lockUncancelable(io);
    defer pipeline_mutex.unlock(io);
    return switch (lane) {
        .video => smp.feedVideo(bytes, pts),
        .audio => smp.feedAudio(bytes, pts),
    };
}

/// Feed one chunk, waiting out backpressure. A full pipeline answers
/// BufferFull and keeps nothing, so the chunk has to be offered again.
fn feedRetrying(lane: Lane, bytes: []const u8, pts: i64) bool {
    var stalled: u32 = 0;
    while (flowing()) {
        const status = pipelineFeed(lane, bytes, pts);
        switch (status) {
            .ok => return true,
            .failed => {
                std.debug.print("{s} feed rejected at pts={d}ms: {s}\n", .{
                    @tagName(lane), @divTrunc(pts, std.time.ns_per_ms), smp.lastError(),
                });
                return false;
            },
            .buffer_full => {
                // While paused the pipeline consumes nothing, so waiting it
                // out is the whole point; while playing, backpressure this
                // long is something wedged.
                stalled = if (paused.load(.acquire)) 0 else stalled + 1;
                if (stalled > 2000) return false; // 10s
                sleepPaced(5 * std.time.ns_per_ms);
            },
        }
    }
    return false;
}
const Lane = enum(u8) { video, audio };

/// A pacing sleep a stop can cut short, so teardown does not wait out a
/// second of cushion.
fn sleepPaced(ns: u64) void {
    const due = nowNs() + ns;
    while (flowing()) {
        const now = nowNs();
        if (now >= due) return;
        interrupted.waitTimeout(io, .{ .duration = .{
            .raw = .fromNanoseconds(due - now),
            .clock = .awake,
        } }) catch {};
    }
}

fn sleepNs(ns: u64) void {
    const ts = linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&ts, null);
}

fn interruptSegment() void {
    segment_mutex.lockUncancelable(io);
    defer segment_mutex.unlock(io);
    interruptSegmentLocked();
}

fn interruptSegmentLocked() void {
    segment.store(false, .release);
    video_queue.close(io);
    audio_queue.close(io);
    interrupted.set(io);
}

/// Displayed media position, updated from projected getCurrentPlaytime samples.
var position_ms = std.atomic.Value(i32).init(0);
/// Where in the item the current source starts. Zero for a stream opened from
/// the beginning, the seek target for one the server re-cut at an offset.
var stream_base_ms: i32 = 0;
var seek_pending = std.atomic.Value(bool).init(false);
var seek_to_ms: i32 = 0;

pub fn position() i32 {
    return position_ms.load(.monotonic);
}

/// Jump `delta_seconds` from the displayed position. The segment loop performs the
/// seek once both feed threads have parked, so this only has to ask.
pub fn seek(delta_seconds: i32) void {
    segment_mutex.lockUncancelable(io);
    defer segment_mutex.unlock(io);
    if (!running.load(.acquire)) return;
    seek_to_ms = @max(0, position_ms.load(.monotonic) + delta_seconds * 1000);
    seek_pending.store(true, .release);
    interruptSegmentLocked();
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
    setState(.loading);
    const rect = [4]i32{ 0, 0, @intCast(width), @intCast(height) };
    window_id = try wl.exportVideoWindow(rect, rect);
    if (stream_uri.len >= uri.len or transcode_uri.len >= fallback.len) return error.UriTooLong;
    @memcpy(uri[0..stream_uri.len], stream_uri);
    uri[stream_uri.len] = 0;
    fallback_len = transcode_uri.len;
    @memcpy(fallback[0..fallback_len], transcode_uri[0..fallback_len]);
    fallback[fallback_len] = 0;
    clock_ready.store(false, .release);
    paused.store(false, .release);
    seek_pending.store(false, .release);
    position_ms.store(0, .monotonic);
    stream_base_ms = 0;
    running.store(true, .release);
    errdefer running.store(false, .release);
    session = try std.Thread.spawn(.{}, feed, .{});
}
pub fn pause() void {
    if (paused.load(.acquire)) return;
    paused.store(true, .release);
    _ = pipelinePause();
}
pub fn resumePlayback() void {
    if (paused.load(.acquire)) {
        paused.store(false, .release);
    }
    if (play_requested.load(.acquire)) {
        _ = pipelinePlay();
    } else {
        maybeStartPipeline();
    }
}
pub fn stop() void {
    running.store(false, .release);
    interruptSegment();
    setState(.idle);
}
pub fn deinit() void {
    stop();
    if (session) |t| {
        t.join();
        session = null;
    }
    smp.deinit();
    video_queue.reset(io);
    audio_queue.reset(io);
}
