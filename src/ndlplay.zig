//! Hardware video playback through NDL DirectMedia: the TV's decoder writes to
//! a video plane, and the compositor punches it through an exported window.
//! This is the path that reaches 4K and 120 fps -- the graphics plane cannot.
//! See docs/ndl.md and docs/display.md.
//!
//! No SDL, despite libNDL_directmedia_impl linking against it: give NDL a
//! window id of our own BEFORE NDL_DirectMediaInit and it takes the external
//! path. It still calls two SDL functions to tweak the window afterwards and
//! they fail harmlessly ("no video device"). See docs/ndl.md.
//!
//! Must be run as an INSTALLED app: NDL registers on the Luna bus, and the
//! role file generated at install time is keyed on the binary's exact path.
//! `zig build play` handles that.
//!
//! Plays an Annex-B elementary stream from a file or a TCP socket:
//!
//!   NDL_SRC=/media/developer/videos/demo_1920x1080p60.h264   zig build run -Dapp=ndlplay
//!   NDL_SRC=tcp://10.10.8.2:9000                            zig build run -Dapp=ndlplay
//!
//! Launched from the TV's app list there is no environment to set, so the
//! source is read from `/media/developer/videos/PLAY` instead -- `zig build
//! play -Dsrc=...` writes that file and launches the app. Output then goes to
//! `/tmp/ndlplay.log`, since SAM gives the process no terminal.
//!
//! Geometry and codec come from the name (`..._1920x1080p60.h264`), because a
//! raw elementary stream carries no container to read them from. `NDL_GEOM`
//! (e.g. `3840x2160p120`) and `NDL_CODEC` (`h264`/`h265`) override it, which is
//! what a TCP source needs.
const std = @import("std");
const linux = std.os.linux;
const c = std.c;

const wl = @import("wl.zig");

// ------------------------------------------------------------------ NDL ABI
//
// Signatures from webos-userland's NDL_directmedia v2 headers. Only the video
// path is used; the audio union is left zeroed, which this decoder accepts.

const VideoType = enum(u32) { h264 = 1, h265 = 2, vp9 = 3, av1 = 4 };

/// NDL_DIRECTMEDIA_DATA_INFO_T. The audio member is a union whose largest arm
/// is 32 bytes; zeroing it means "no audio".
const DataInfo = extern struct {
    video: extern struct {
        width: i32,
        height: i32,
        type: VideoType,
        unknown1: i32 = 0,
    },
    audio: [32]u8 = @splat(0),
};

/// NDLMediaLoadCallback: (type, numeric argument, string argument).
const LoadCallback = *const fn (i32, i64, ?[*:0]const u8) callconv(.c) void;

var ndl: ?*anyopaque = null;
var dlInitialize: *const fn () callconv(.c) bool = undefined;
var mediaInit: *const fn ([*:0]const u8) callconv(.c) i32 = undefined;
var mediaSetWindowId: *const fn ([*:0]const u8) callconv(.c) i32 = undefined;
var mediaLoad: *const fn (*DataInfo, ?LoadCallback) callconv(.c) i32 = undefined;
var mediaUnload: *const fn () callconv(.c) i32 = undefined;
var mediaQuit: *const fn () callconv(.c) i32 = undefined;
var mediaGetError: *const fn () callconv(.c) ?[*:0]const u8 = undefined;
var videoPlay: *const fn (*const anyopaque, u32, i64) callconv(.c) i32 = undefined;
var videoGetRenderBufferLength: *const fn (*i32) callconv(.c) i32 = undefined;
var videoSetArea: *const fn (i32, i32, i32, i32) callconv(.c) i32 = undefined;
var mediaSetAppState: *const fn (u32) callconv(.c) i32 = undefined;

fn ndlSym(comptime T: type, name: [*:0]const u8) T {
    return @ptrCast(@alignCast(c.dlsym(ndl, name) orelse
        std.debug.panic("missing NDL symbol: {s}", .{name})));
}

fn ndlError() []const u8 {
    return std.mem.sliceTo(mediaGetError() orelse return "(no error string)", 0);
}

fn loadNdl() !void {
    // libNDL_directmedia.so.1 is a 9 KB stub: it dlopens the real
    // libNDL_directmedia_impl.so.1 when DL_Initialize is called, and every
    // other entry point traps until then.
    ndl = c.dlopen("libNDL_directmedia.so.1", .{ .NOW = true }) orelse return error.NoNDL;
    dlInitialize = ndlSym(@TypeOf(dlInitialize), "NDL_DirectMedia_DL_Initialize");
    if (!dlInitialize()) return error.NdlDlInitFailed;

    mediaInit = ndlSym(@TypeOf(mediaInit), "NDL_DirectMediaInit");
    mediaSetWindowId = ndlSym(@TypeOf(mediaSetWindowId), "NDL_DirectMediaSetWindowId");
    mediaLoad = ndlSym(@TypeOf(mediaLoad), "NDL_DirectMediaLoad");
    mediaUnload = ndlSym(@TypeOf(mediaUnload), "NDL_DirectMediaUnload");
    mediaQuit = ndlSym(@TypeOf(mediaQuit), "NDL_DirectMediaQuit");
    mediaGetError = ndlSym(@TypeOf(mediaGetError), "NDL_DirectMediaGetError");
    videoPlay = ndlSym(@TypeOf(videoPlay), "NDL_DirectVideoPlay");
    videoGetRenderBufferLength = ndlSym(@TypeOf(videoGetRenderBufferLength), "NDL_DirectVideoGetRenderBufferLength");
    videoSetArea = ndlSym(@TypeOf(videoSetArea), "NDL_DirectVideoSetArea");
    mediaSetAppState = ndlSym(@TypeOf(mediaSetAppState), "NDL_DirectMediaSetAppState");
}

// ------------------------------------------------------------------- source

/// A file on the TV, or a TCP stream published by the host. Both end up as one
/// fd we read until it dries up.
fn openSource(src: []const u8) !i32 {
    if (std.mem.startsWith(u8, src, "tcp://")) {
        const rest = src["tcp://".len..];
        const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.BadTcpUrl;
        const port = try std.fmt.parseInt(u16, rest[colon + 1 ..], 10);
        var ip: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, rest[0..colon], '.');
        for (&ip) |*b| b.* = try std.fmt.parseInt(u8, it.next() orelse return error.BadTcpUrl, 10);

        const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (failed(s)) return error.SocketFailed;
        const fd: i32 = @intCast(s);
        const addr = linux.sockaddr.in{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(ip),
        };
        if (failed(linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))))) return error.ConnectFailed;
        std.debug.print("connected to {s}\n", .{src});
        return fd;
    }
    var path: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&path, "{s}", .{src}) catch return error.PathTooLong;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(rc)) return error.OpenFailed;
    return @intCast(rc);
}

fn failed(rc: usize) bool {
    return rc >= @as(usize, @bitCast(@as(isize, -4095)));
}

/// `..._1920x1080p60.h264` -> 1920x1080, 60 fps, H.264. A raw elementary
/// stream has no container, so there is nowhere else to get this from.
const Geom = struct { width: i32, height: i32, fps: u32, codec: VideoType };

fn parseGeom(src: []const u8) !Geom {
    var g = Geom{ .width = 1920, .height = 1080, .fps = 60, .codec = .h264 };

    if (std.mem.endsWith(u8, src, ".h265") or std.mem.endsWith(u8, src, ".hevc")) g.codec = .h265;
    if (c.getenv("NDL_CODEC")) |v| {
        const s = std.mem.sliceTo(v, 0);
        g.codec = if (std.mem.eql(u8, s, "h265") or std.mem.eql(u8, s, "hevc")) .h265 else .h264;
    }

    const spec = if (c.getenv("NDL_GEOM")) |v| std.mem.sliceTo(v, 0) else src;
    // Scan for "<w>x<h>p<fps>" anywhere in the string.
    const x = std.mem.indexOfScalar(u8, spec, 'x') orelse return g;
    const p = std.mem.indexOfScalarPos(u8, spec, x, 'p') orelse return g;
    var start = x;
    while (start > 0 and std.ascii.isDigit(spec[start - 1])) start -= 1;
    var end = p + 1;
    while (end < spec.len and std.ascii.isDigit(spec[end])) end += 1;
    g.width = std.fmt.parseInt(i32, spec[start..x], 10) catch g.width;
    g.height = std.fmt.parseInt(i32, spec[x + 1 .. p], 10) catch g.height;
    g.fps = std.fmt.parseInt(u32, spec[p + 1 .. end], 10) catch g.fps;
    return g;
}

// --------------------------------------------------------------------- main

fn onLoad(kind: i32, num: i64, str: ?[*:0]const u8) callconv(.c) void {
    std.debug.print("NDL event: type={d} value={d} text={s}\n", .{
        kind, num, if (str) |p| std.mem.sliceTo(p, 0) else "",
    });
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepMs(ms: u32) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

// Big enough for a 4K keyframe; the accumulator holds at most one access unit
// plus whatever of the next one has already arrived.
var acc: [8 << 20]u8 = undefined;
var acc_head: usize = 0; // first unconsumed byte
var acc_len: usize = 0; // first free byte
var eof = false;

fn pending() []const u8 {
    return acc[acc_head..acc_len];
}

/// Index of the next Annex-B start code at or after `from`, or null.
fn nextStartCode(b: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 3 <= b.len) : (i += 1) {
        if (b[i] == 0 and b[i + 1] == 0 and b[i + 2] == 1) return i;
    }
    return null;
}

/// True if the NAL beginning at a start code is a coded slice (VCL).
/// H.264 puts the type in the low 5 bits, H.265 in bits 1..6 of the same byte.
fn isVcl(b: []const u8, sc: usize, codec: VideoType) bool {
    const h = sc + 3;
    if (h >= b.len) return false;
    return switch (codec) {
        .h264 => switch (b[h] & 0x1f) {
            1...5 => true,
            else => false,
        },
        else => (b[h] >> 1) & 0x3f < 32,
    };
}

/// True if this VCL NAL begins a new picture rather than continuing one.
///
/// Both codecs answer this in a single bit, which is why no bit-reader is
/// needed: H.264's slice header opens with `first_mb_in_slice`, an exp-Golomb
/// value whose zero encoding is the single bit 1; H.265's opens with
/// `first_slice_segment_in_pic_flag` directly. Either way the top bit of the
/// byte after the NAL header is the answer.
///
/// Without this, x264's `-tune zerolatency` (sliced threads) reads as ~1000
/// "frames" a second: every slice looks like a picture.
fn startsPicture(b: []const u8, sc: usize, codec: VideoType) bool {
    const header_len: usize = if (codec == .h264) 1 else 2;
    const i = sc + 3 + header_len;
    if (i >= b.len) return false;
    return b[i] & 0x80 != 0;
}

/// Split the accumulator at the next access-unit boundary: the start code of a
/// VCL NAL that begins a new picture, when the buffer already holds one.
/// Parameter sets and SEI that precede it belong to the *next* unit, so the
/// cut goes before them.
fn accessUnitEnd(codec: VideoType) ?usize {
    const b = pending();
    var sc = nextStartCode(b, 0) orelse return null;
    var seen_vcl = false;
    var trailing: ?usize = null; // first non-VCL NAL after the VCL we have
    while (true) {
        if (isVcl(b, sc, codec)) {
            if (seen_vcl and startsPicture(b, sc, codec)) return trailing orelse sc;
            seen_vcl = true;
            trailing = null;
        } else if (seen_vcl and trailing == null) {
            trailing = sc;
        }
        sc = nextStartCode(b, sc + 3) orelse return null;
    }
}

/// Keep roughly a megabyte of lookahead. Compacting by sliding the whole
/// buffer down after every access unit is what made the first version run at
/// half speed -- a read cursor costs nothing.
const LOOKAHEAD = 1 << 20;

fn fill(fd: i32) !void {
    if (acc_head > 0 and acc.len - acc_len < LOOKAHEAD) {
        std.mem.copyForwards(u8, acc[0 .. acc_len - acc_head], pending());
        acc_len -= acc_head;
        acc_head = 0;
    }
    while (!eof and acc_len - acc_head < LOOKAHEAD) {
        const want = @min(acc.len - acc_len, 256 * 1024);
        if (want == 0) return;
        const rc = linux.read(fd, acc[acc_len..].ptr, want);
        if (failed(rc)) return error.ReadFailed;
        const n: usize = @intCast(rc);
        if (n == 0) {
            eof = true;
            return;
        }
        acc_len += n;
        if (n < want) return; // a socket with nothing more right now
    }
}

const PLAY_FILE = "/media/developer/videos/PLAY";

/// NDL will not register on the Luna bus unless the app id it is given belongs
/// to an installed app. An installed app runs with its own directory as the
/// working directory, so the id is that directory's name -- no environment
/// needed, which matters because SAM provides none.
fn appIdFromCwd(buf: []u8) ?[]const u8 {
    const rc = linux.readlinkat(linux.AT.FDCWD, "/proc/self/cwd", buf.ptr, buf.len);
    if (failed(rc)) return null;
    const path = buf[0..@intCast(rc)];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const name = path[slash + 1 ..];
    // Only trust it if it looks like an app id rather than some other cwd.
    return if (std.mem.indexOfScalar(u8, name, '.') != null) name else null;
}

fn isTty(fd: i32) bool {
    var buf: [64]u8 = undefined;
    return !failed(linux.ioctl(fd, 0x5401, @intFromPtr(&buf))); // TCGETS
}

/// SAM hands the process no terminal, so keep the log somewhere readable.
fn logToFile() void {
    const rc = linux.openat(linux.AT.FDCWD, "/tmp/ndlplay.log", .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    if (failed(rc)) return;
    _ = linux.dup2(@intCast(rc), 2);
}

/// Read one line from the PLAY file: the file or tcp:// URL to play.
fn readPlayFile(buf: []u8) ?[]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, PLAY_FILE, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(rc)) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (failed(n) or n == 0) return null;
    return std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
}

pub fn main() !void {
    if (!isTty(2)) logToFile();

    var src_buf: [512]u8 = undefined;
    const src = if (c.getenv("NDL_SRC")) |v|
        std.mem.sliceTo(v, 0)
    else
        readPlayFile(&src_buf) orelse {
            std.debug.print("no source: set NDL_SRC, or write one to {s}\n", .{PLAY_FILE});
            return error.NoSource;
        };
    const geom = try parseGeom(src);

    var id_buf: [256]u8 = undefined;
    var appid_z: [128]u8 = undefined;
    const appid: [*:0]const u8 = blk: {
        if (c.getenv("APPID")) |v| break :blk v;
        if (appIdFromCwd(&id_buf)) |id| {
            if (std.fmt.bufPrintZ(&appid_z, "{s}", .{id})) |z| break :blk z.ptr else |_| {}
        }
        break :blk "dev.hookedbehemoth.ndlplay";
    };
    std.debug.print("app id {s}\n", .{std.mem.sliceTo(appid, 0)});

    // Our own transparent fullscreen surface, exported as a video element.
    try wl.open(appid, "ndl player", 0, 0, .shm);
    // Transparent where the video shows; NDL_BG=opaque paints it red instead,
    // which is how you tell "surface not composited" from "punch-through not
    // working".
    @memset(wl.pixels, if (c.getenv("NDL_BG") != null) 0xFFFF0000 else 0x00000000);
    wl.present();
    const full = [4]i32{ 0, 0, @intCast(wl.width), @intCast(wl.height) };
    const window = try wl.exportVideoWindow(full, full);

    try loadNdl();
    // Window id BEFORE Init: the implementation has an "external windowid"
    // path, and if it has not been given one by the time it initialises it
    // goes looking for an SDL window instead.
    if (mediaSetWindowId(window) != 0) std.debug.print("NDL_DirectMediaSetWindowId: {s}\n", .{ndlError()});
    if (mediaInit(appid) != 0) std.debug.print("NDL_DirectMediaInit: {s}\n", .{ndlError()});

    var info = DataInfo{ .video = .{ .width = geom.width, .height = geom.height, .type = geom.codec } };
    std.debug.print("loading {d}x{d}p{d} {s} from {s}\n", .{
        geom.width, geom.height, geom.fps, @tagName(geom.codec), src,
    });
    if (mediaLoad(&info, onLoad) != 0) {
        std.debug.print("NDL_DirectMediaLoad failed: {s}\n", .{ndlError()});
        return error.LoadFailed;
    }
    // NDL drops frames it thinks belong to a backgrounded app ("Video feed in
    // the background state"), and nothing tells it otherwise by itself.
    if (mediaSetAppState(0) != 0) std.debug.print("SetAppState: {s}\n", .{ndlError()}); // 0 = FOREGROUND
    _ = videoSetArea(0, 0, @intCast(wl.width), @intCast(wl.height));

    const fd = try openSource(src);
    const frame_ns: i64 = @intCast(std.time.ns_per_s / geom.fps);
    var frames: u64 = 0;
    var bytes: u64 = 0;
    const start = nowNs();

    // A live stream paces itself; only a file needs us to hold it back.
    const live = std.mem.startsWith(u8, src, "tcp://");

    feed: while (true) {
        try fill(fd);
        const cut = accessUnitEnd(geom.codec) orelse blk: {
            // No complete access unit yet. At end of stream the remainder is
            // the last one; otherwise wait for the rest of it to arrive.
            if (!eof) continue :feed;
            if (acc_head == acc_len) break :feed;
            break :blk acc_len - acc_head;
        };

        const pts: i64 = @intCast(frames * @as(u64, @intCast(frame_ns)));
        if (videoPlay(pending().ptr, @intCast(cut), pts) != 0) {
            std.debug.print("NDL_DirectVideoPlay failed at frame {d}: {s}\n", .{ frames, ndlError() });
            break;
        }
        frames += 1;
        bytes += cut;
        acc_head += cut;

        // Feed roughly in real time. The decoder has its own render buffer, so
        // running a little ahead is fine and absorbs jitter; running far ahead
        // just overflows it.
        if (!live) {
            const due = start + @as(u64, @intCast(pts));
            const now = nowNs();
            if (due > now + 4 * std.time.ns_per_ms) sleepMs(@intCast((due - now) / std.time.ns_per_ms));
        }

        if (frames % (geom.fps * 2) == 0) {
            var queued: i32 = -1;
            _ = videoGetRenderBufferLength(&queued);
            std.debug.print("{d} frames, {d} KiB, {d}s in, render buffer {d}\n", .{
                frames, bytes / 1024, (nowNs() - start) / std.time.ns_per_s, queued,
            });
        }
    }

    std.debug.print("done: {d} frames, {d} KiB in {d}s\n", .{
        frames, bytes / 1024, (nowNs() - start) / std.time.ns_per_s,
    });
    sleepMs(2000); // let the decoder drain what is queued
    _ = mediaUnload();
    _ = mediaQuit();
}
