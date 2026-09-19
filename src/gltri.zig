//! 1000 rotating triangles in one instanced draw call, with CPU and GPU frame
//! times in the bottom-right corner.
//!
//! Per-vertex attribute:   position
//! Per-instance attributes: offset, direction, speed, phase, size
//! Uniforms: time, aspect
//! Every instance scales with sin(time + phase) * size and spins at its own
//! speed, so no two triangles peak at the same moment or the same size.
//!
//! Shaders are written in Slang (src/shaders/*.slang) and compiled to GLSL ES
//! by the build -- see build.zig and docs/opengl.md.
const std = @import("std");
const linux = std.os.linux;
const gl = @import("gl.zig");
const wl = @import("wl.zig");
const txt = @import("text.zig");

const tri_vs = @embedFile("tri_vs");
const tri_fs = @embedFile("tri_fs");
const text_vs = @embedFile("text_vs");
const text_fs = @embedFile("text_fs");

const INSTANCES = 1000;
const TRI_RADIUS = 0.045;

// ------------------------------------------------------------------- GL bits

const GL_ARRAY_BUFFER = 0x8892;
const GL_UNIFORM_BUFFER = 0x8A11;
const GL_STATIC_DRAW = 0x88E4;
const GL_DYNAMIC_DRAW = 0x88E8;
const GL_FLOAT = 0x1406;
const GL_TRIANGLES = 0x0004;
const GL_TRIANGLE_STRIP = 0x0005;
const GL_COLOR_BUFFER_BIT = 0x4000;
const GL_VERTEX_SHADER = 0x8B31;
const GL_FRAGMENT_SHADER = 0x8B30;
const GL_COMPILE_STATUS = 0x8B81;
const GL_LINK_STATUS = 0x8B82;
const GL_TEXTURE_2D = 0x0DE1;
const GL_TEXTURE0 = 0x84C0;
/// Slang hands out binding points in declaration order and the `rect` uniform
/// block already took 0, so the text shader's sampler is `binding = 1` and the
/// texture has to go on unit 1. Check the generated GLSL if this ever moves.
const TEXT_ATLAS_UNIT = 1;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_WRAP_S = 0x2802;
const GL_TEXTURE_WRAP_T = 0x2803;
const GL_NEAREST = 0x2600;
const GL_CLAMP_TO_EDGE = 0x812F;
const GL_R8 = 0x8229;
const GL_RED = 0x1903;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_UNPACK_ALIGNMENT = 0x0CF5;
const GL_RGBA = 0x1908;
const GL_BLEND = 0x0BE2;
const GL_SRC_ALPHA = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA = 0x0303;
const GL_TIME_ELAPSED_EXT = 0x88BF;
const GL_QUERY_RESULT_EXT = 0x8866;
const GL_QUERY_RESULT_AVAILABLE_EXT = 0x8867;

var glClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void = undefined;
var glClear: *const fn (u32) callconv(.c) void = undefined;
var glViewport: *const fn (i32, i32, i32, i32) callconv(.c) void = undefined;
var glEnable: *const fn (u32) callconv(.c) void = undefined;
var glBlendFunc: *const fn (u32, u32) callconv(.c) void = undefined;
var glPixelStorei: *const fn (u32, i32) callconv(.c) void = undefined;
var glCreateShader: *const fn (u32) callconv(.c) u32 = undefined;
var glShaderSource: *const fn (u32, i32, [*]const [*]const u8, ?[*]const i32) callconv(.c) void = undefined;
var glCompileShader: *const fn (u32) callconv(.c) void = undefined;
var glGetShaderiv: *const fn (u32, u32, *i32) callconv(.c) void = undefined;
var glGetShaderInfoLog: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void = undefined;
var glCreateProgram: *const fn () callconv(.c) u32 = undefined;
var glAttachShader: *const fn (u32, u32) callconv(.c) void = undefined;
var glLinkProgram: *const fn (u32) callconv(.c) void = undefined;
var glGetProgramiv: *const fn (u32, u32, *i32) callconv(.c) void = undefined;
var glGetProgramInfoLog: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void = undefined;
var glUseProgram: *const fn (u32) callconv(.c) void = undefined;
var glGenBuffers: *const fn (i32, [*]u32) callconv(.c) void = undefined;
var glBindBuffer: *const fn (u32, u32) callconv(.c) void = undefined;
var glBufferData: *const fn (u32, isize, ?*const anyopaque, u32) callconv(.c) void = undefined;
var glBufferSubData: *const fn (u32, isize, isize, *const anyopaque) callconv(.c) void = undefined;
var glBindBufferBase: *const fn (u32, u32, u32) callconv(.c) void = undefined;
var glGenVertexArrays: *const fn (i32, [*]u32) callconv(.c) void = undefined;
var glBindVertexArray: *const fn (u32) callconv(.c) void = undefined;
var glVertexAttribPointer: *const fn (u32, i32, u32, u8, i32, usize) callconv(.c) void = undefined;
var glEnableVertexAttribArray: *const fn (u32) callconv(.c) void = undefined;
var glVertexAttribDivisor: *const fn (u32, u32) callconv(.c) void = undefined;
var glDrawArraysInstanced: *const fn (u32, i32, i32, i32) callconv(.c) void = undefined;
var glDrawArrays: *const fn (u32, i32, i32) callconv(.c) void = undefined;
var glGenTextures: *const fn (i32, [*]u32) callconv(.c) void = undefined;
var glBindTexture: *const fn (u32, u32) callconv(.c) void = undefined;
var glActiveTexture: *const fn (u32) callconv(.c) void = undefined;
var glTexStorage2D: *const fn (u32, i32, u32, i32, i32) callconv(.c) void = undefined;
var glTexSubImage2D: *const fn (u32, i32, i32, i32, i32, i32, u32, u32, *const anyopaque) callconv(.c) void = undefined;
var glTexParameteri: *const fn (u32, u32, i32) callconv(.c) void = undefined;
var glGetError: *const fn () callconv(.c) u32 = undefined;
var glFinish: *const fn () callconv(.c) void = undefined;
var glReadPixels: *const fn (i32, i32, i32, i32, u32, u32, [*]u8) callconv(.c) void = undefined;

// GL_EXT_disjoint_timer_query -- optional, so these stay nullable.
var glGenQueriesEXT: ?*const fn (i32, [*]u32) callconv(.c) void = null;
var glBeginQueryEXT: ?*const fn (u32, u32) callconv(.c) void = null;
var glEndQueryEXT: ?*const fn (u32) callconv(.c) void = null;
var glGetQueryObjectuivEXT: ?*const fn (u32, u32, *u32) callconv(.c) void = null;
var glGetQueryObjectui64vEXT: ?*const fn (u32, u32, *u64) callconv(.c) void = null;

fn loadGl() void {
    glClearColor = gl.proc(@TypeOf(glClearColor), "glClearColor");
    glClear = gl.proc(@TypeOf(glClear), "glClear");
    glViewport = gl.proc(@TypeOf(glViewport), "glViewport");
    glEnable = gl.proc(@TypeOf(glEnable), "glEnable");
    glBlendFunc = gl.proc(@TypeOf(glBlendFunc), "glBlendFunc");
    glPixelStorei = gl.proc(@TypeOf(glPixelStorei), "glPixelStorei");
    glCreateShader = gl.proc(@TypeOf(glCreateShader), "glCreateShader");
    glShaderSource = gl.proc(@TypeOf(glShaderSource), "glShaderSource");
    glCompileShader = gl.proc(@TypeOf(glCompileShader), "glCompileShader");
    glGetShaderiv = gl.proc(@TypeOf(glGetShaderiv), "glGetShaderiv");
    glGetShaderInfoLog = gl.proc(@TypeOf(glGetShaderInfoLog), "glGetShaderInfoLog");
    glCreateProgram = gl.proc(@TypeOf(glCreateProgram), "glCreateProgram");
    glAttachShader = gl.proc(@TypeOf(glAttachShader), "glAttachShader");
    glLinkProgram = gl.proc(@TypeOf(glLinkProgram), "glLinkProgram");
    glGetProgramiv = gl.proc(@TypeOf(glGetProgramiv), "glGetProgramiv");
    glGetProgramInfoLog = gl.proc(@TypeOf(glGetProgramInfoLog), "glGetProgramInfoLog");
    glUseProgram = gl.proc(@TypeOf(glUseProgram), "glUseProgram");
    glGenBuffers = gl.proc(@TypeOf(glGenBuffers), "glGenBuffers");
    glBindBuffer = gl.proc(@TypeOf(glBindBuffer), "glBindBuffer");
    glBufferData = gl.proc(@TypeOf(glBufferData), "glBufferData");
    glBufferSubData = gl.proc(@TypeOf(glBufferSubData), "glBufferSubData");
    glBindBufferBase = gl.proc(@TypeOf(glBindBufferBase), "glBindBufferBase");
    glGenVertexArrays = gl.proc(@TypeOf(glGenVertexArrays), "glGenVertexArrays");
    glBindVertexArray = gl.proc(@TypeOf(glBindVertexArray), "glBindVertexArray");
    glVertexAttribPointer = gl.proc(@TypeOf(glVertexAttribPointer), "glVertexAttribPointer");
    glEnableVertexAttribArray = gl.proc(@TypeOf(glEnableVertexAttribArray), "glEnableVertexAttribArray");
    glVertexAttribDivisor = gl.proc(@TypeOf(glVertexAttribDivisor), "glVertexAttribDivisor");
    glDrawArraysInstanced = gl.proc(@TypeOf(glDrawArraysInstanced), "glDrawArraysInstanced");
    glDrawArrays = gl.proc(@TypeOf(glDrawArrays), "glDrawArrays");
    glGenTextures = gl.proc(@TypeOf(glGenTextures), "glGenTextures");
    glBindTexture = gl.proc(@TypeOf(glBindTexture), "glBindTexture");
    glActiveTexture = gl.proc(@TypeOf(glActiveTexture), "glActiveTexture");
    glTexStorage2D = gl.proc(@TypeOf(glTexStorage2D), "glTexStorage2D");
    glTexSubImage2D = gl.proc(@TypeOf(glTexSubImage2D), "glTexSubImage2D");
    glTexParameteri = gl.proc(@TypeOf(glTexParameteri), "glTexParameteri");
    glReadPixels = gl.proc(@TypeOf(glReadPixels), "glReadPixels");
    glGetError = gl.proc(@TypeOf(glGetError), "glGetError");
    glFinish = gl.proc(@TypeOf(glFinish), "glFinish");

    glGenQueriesEXT = gl.procOpt(@TypeOf(glGenQueriesEXT.?), "glGenQueriesEXT");
    glBeginQueryEXT = gl.procOpt(@TypeOf(glBeginQueryEXT.?), "glBeginQueryEXT");
    glEndQueryEXT = gl.procOpt(@TypeOf(glEndQueryEXT.?), "glEndQueryEXT");
    glGetQueryObjectuivEXT = gl.procOpt(@TypeOf(glGetQueryObjectuivEXT.?), "glGetQueryObjectuivEXT");
    glGetQueryObjectui64vEXT = gl.procOpt(@TypeOf(glGetQueryObjectui64vEXT.?), "glGetQueryObjectui64vEXT");
}

var log_buf: [4096]u8 = undefined;

fn compile(kind: u32, src: []const u8) u32 {
    const sh = glCreateShader(kind);
    const ptr: [*]const u8 = src.ptr;
    const len: i32 = @intCast(src.len);
    glShaderSource(sh, 1, @ptrCast(&ptr), @ptrCast(&len));
    glCompileShader(sh);
    var ok: i32 = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        glGetShaderInfoLog(sh, log_buf.len, null, &log_buf);
        std.debug.panic("shader compile failed:\n{s}\n", .{std.mem.sliceTo(&log_buf, 0)});
    }
    return sh;
}

fn program(vs_src: []const u8, fs_src: []const u8) u32 {
    const p = glCreateProgram();
    glAttachShader(p, compile(GL_VERTEX_SHADER, vs_src));
    glAttachShader(p, compile(GL_FRAGMENT_SHADER, fs_src));
    glLinkProgram(p);
    var ok: i32 = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (ok == 0) {
        glGetProgramInfoLog(p, log_buf.len, null, &log_buf);
        std.debug.panic("program link failed:\n{s}\n", .{std.mem.sliceTo(&log_buf, 0)});
    }
    return p;
}

// ------------------------------------------------------------------- overlay

const OVERLAY_COLS = 22;
const OVERLAY_ROWS = 5;
const OVERLAY_W = OVERLAY_COLS * txt.GLYPH_W;
const OVERLAY_H = OVERLAY_ROWS * txt.GLYPH_H;
const OVERLAY_ZOOM = 2; // on-screen magnification of the 1x rasterisation

var overlay_px: [OVERLAY_W * OVERLAY_H]u8 = @splat(0);
var overlay_tex: u32 = 0;

fn overlayLine(row: usize, s: []const u8) void {
    txt.draw(u8, &overlay_px, OVERLAY_W, OVERLAY_H, 0, row * txt.GLYPH_H, 1, 255, s);
}

// --------------------------------------------------------------------- time

fn clockNs(which: linux.CLOCK) u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(which, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
fn nowNs() u64 {
    return clockNs(.MONOTONIC);
}
/// CPU time this thread actually burned, which is the honest "CPU time": wall
/// clock would just measure the wait for a free swapchain buffer and report
/// the vsync interval back to us.
fn cpuNs() u64 {
    return clockNs(.THREAD_CPUTIME_ID);
}

/// Exponential moving average, so the numbers on screen stay readable instead
/// of flickering every frame.
fn smooth(prev: f64, sample: f64) f64 {
    return if (prev == 0) sample else prev * 0.9 + sample * 0.1;
}

/// Read the frame back and print it as coarse ASCII, so the render can be
/// checked without looking at a screen:
///   GLTRI_DUMP=1 zig build run-host -Dapp=gltri
var readback: [1920 * 1080 * 4]u8 = undefined;

fn dumpFrame() void {
    const w: usize = gl.width;
    const h: usize = gl.height;
    if (w * h * 4 > readback.len) return;
    glReadPixels(0, 0, @intCast(w), @intCast(h), GL_RGBA, GL_UNSIGNED_BYTE, &readback);
    var lit: usize = 0;
    // 72x24 cells, each reporting the brightest pixel it covers.
    var row: usize = 0;
    var out: [73]u8 = undefined;
    while (row < 24) : (row += 1) {
        for (0..72) |col| {
            var best: u8 = 0;
            var sy: usize = 0;
            while (sy < 8) : (sy += 1) {
                const y = (h - 1) - (row * h / 24 + sy * h / (24 * 8));
                for (0..8) |sx| {
                    const x = col * w / 72 + sx * w / (72 * 8);
                    const px = readback[(y * w + x) * 4 ..];
                    const v = @max(px[0], @max(px[1], px[2]));
                    best = @max(best, v);
                }
            }
            if (best > 24) lit += 1;
            out[col] = switch (best) {
                0...24 => ' ',
                25...80 => '.',
                81...160 => '+',
                else => '#',
            };
        }
        std.debug.print("{s}\n", .{out[0..72]});
    }
    std.debug.print("lit cells: {d}/1728\n", .{lit});

    // The overlay is the only thing drawn in pure white, so counting white
    // pixels checks that the text program, the texture and the blend all work.
    var white: usize = 0;
    for (0..w * h) |i| {
        const px = readback[i * 4 ..];
        if (px[0] > 200 and px[0] == px[1] and px[1] == px[2]) white += 1;
    }
    std.debug.print("overlay: {d} white pixels\n", .{white});
}

pub fn main() !void {
    const appid = std.c.getenv("APPID") orelse @as([*:0]const u8, "dev.hookedbehemoth.gltri");
    try gl.init(appid, "1000 triangles", 0, 0);
    loadGl();

    const w: i32 = @intCast(gl.width);
    const h: i32 = @intCast(gl.height);
    glViewport(0, 0, w, h);
    glClearColor(0.04, 0.04, 0.06, 1.0);

    const tri_prog = program(tri_vs, tri_fs);
    const text_prog = program(text_vs, text_fs);

    // One equilateral triangle, reused by every instance.
    const verts = [_]f32{
        0.0,                 TRI_RADIUS,
        -TRI_RADIUS * 0.866, -TRI_RADIUS * 0.5,
        TRI_RADIUS * 0.866,  -TRI_RADIUS * 0.5,
    };

    // offset.x, offset.y, direction, speed, phase, size
    const FLOATS = 6;
    var instances: [INSTANCES * FLOATS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0x7A1B);
    const rnd = prng.random();
    for (0..INSTANCES) |i| {
        const inst = instances[i * FLOATS ..];
        inst[0] = rnd.float(f32) * 2.0 - 1.0; // offset.x
        inst[1] = rnd.float(f32) * 2.0 - 1.0; // offset.y
        inst[2] = rnd.float(f32) * std.math.tau; // direction
        inst[3] = 0.35 + rnd.float(f32) * 0.9; // speed
        inst[4] = rnd.float(f32) * std.math.tau; // phase: when it peaks
        inst[5] = 0.3 + rnd.float(f32) * 1.2; // size: how big it peaks
    }

    var vao: u32 = 0;
    glGenVertexArrays(1, @ptrCast(&vao));
    glBindVertexArray(vao);

    var bufs: [4]u32 = @splat(0);
    glGenBuffers(4, &bufs);
    const vbo = bufs[0];
    const ibo = bufs[1];
    const ubo = bufs[2];
    const quad_vbo = bufs[3];

    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, 0, 2 * 4, 0); // position

    glBindBuffer(GL_ARRAY_BUFFER, ibo);
    glBufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(instances)), &instances, GL_STATIC_DRAW);
    // These advance once per instance, not per vertex: { location, floats, byte offset }.
    inline for (.{ .{ 1, 2, 0 }, .{ 2, 1, 8 }, .{ 3, 1, 12 }, .{ 4, 1, 16 }, .{ 5, 1, 20 } }) |a| {
        glEnableVertexAttribArray(a[0]);
        glVertexAttribPointer(a[0], a[1], GL_FLOAT, 0, FLOATS * 4, a[2]);
        glVertexAttribDivisor(a[0], 1);
    }

    // std140: two floats, padded to a 16-byte block.
    var uniforms: [4]f32 = @splat(0);
    glBindBuffer(GL_UNIFORM_BUFFER, ubo);
    glBufferData(GL_UNIFORM_BUFFER, @sizeOf(@TypeOf(uniforms)), &uniforms, GL_DYNAMIC_DRAW);
    uniforms[1] = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(w)); // aspect

    // Overlay: an R8 coverage texture the CPU rewrites every frame, drawn as
    // one triangle strip.
    var vao_text: u32 = 0;
    glGenVertexArrays(1, @ptrCast(&vao_text));
    glBindVertexArray(vao_text);
    const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
    glBindBuffer(GL_ARRAY_BUFFER, quad_vbo);
    glBufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, 0, 2 * 4, 0);

    var text_ubo: u32 = 0;
    glGenBuffers(1, @ptrCast(&text_ubo));
    const margin = 16.0;
    const dst_w = @as(f32, OVERLAY_W * OVERLAY_ZOOM);
    const dst_h = @as(f32, OVERLAY_H * OVERLAY_ZOOM);
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const x1 = 1.0 - 2.0 * margin / fw;
    const y0 = -1.0 + 2.0 * margin / fh;
    const rect = [4]f32{ x1 - 2.0 * dst_w / fw, y0, x1, y0 + 2.0 * dst_h / fh };
    glBindBuffer(GL_UNIFORM_BUFFER, text_ubo);
    glBufferData(GL_UNIFORM_BUFFER, @sizeOf(@TypeOf(rect)), &rect, GL_STATIC_DRAW);

    glGenTextures(1, @ptrCast(&overlay_tex));
    glBindTexture(GL_TEXTURE_2D, overlay_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_R8, OVERLAY_W, OVERLAY_H);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    const setup_err = glGetError();
    if (setup_err != 0) std.debug.panic("GL error after setup: 0x{x}\n", .{setup_err});

    // How GPU time gets measured: the timer query if the driver really
    // implements it, otherwise a glFinish stopwatch.
    var gpu_mode: enum { query, finish, none } =
        if (glGenQueriesEXT != null and glGetQueryObjectui64vEXT != null) .query else .finish;
    // Two query objects, used alternately: a result is not ready until the GPU
    // has finished that frame, so the previous frame's query is the one to read.
    var queries: [2]u32 = @splat(0);
    if (gpu_mode == .query) glGenQueriesEXT.?(2, &queries);
    std.debug.print("{d} instances at {d}x{d}, output {d}.{d:0>3} Hz, swap interval {d}, GPU timing: {s}\n", .{
        INSTANCES,             gl.width,         gl.height,          wl.refresh_mhz / 1000,
        wl.refresh_mhz % 1000, gl.swap_interval, @tagName(gpu_mode),
    });

    // A couple of frames first, so the timer query has a result to show.
    var dump_after: u32 = if (std.c.getenv("GLTRI_DUMP") != null) 3 else 0;

    const start = nowNs();
    var cpu_ms: f64 = 0;
    var gpu_ms: f64 = 0;
    var frame_ms: f64 = 0;
    var last_frame = start;
    // Asking an unused query object for a result is GL_INVALID_OPERATION, so
    // the first two frames only write queries.
    var frames: u64 = 0;
    var line: [OVERLAY_COLS]u8 = undefined;

    while (wl.poll()) {
        const wall_start = nowNs();
        const cpu_start = cpuNs();
        frame_ms = smooth(frame_ms, @as(f64, @floatFromInt(wall_start - last_frame)) / std.time.ns_per_ms);
        last_frame = wall_start;

        uniforms[0] = @as(f32, @floatFromInt(wall_start - start)) / std.time.ns_per_s;
        // sin(time) is ~0 at startup, so the dump would be half-empty.
        if (dump_after > 0) uniforms[0] = 1.5;

        // The previous frame's GPU result is ready by now; reading the current
        // one here would stall the pipeline, which is what we are measuring.
        const q = queries[@intCast(frames % 2)];
        const prev_q = queries[@intCast((frames + 1) % 2)];
        if (gpu_mode == .query and frames > 1) {
            var available: u32 = 0;
            glGetQueryObjectuivEXT.?(prev_q, GL_QUERY_RESULT_AVAILABLE_EXT, &available);
            if (available != 0) {
                var elapsed: u64 = 0;
                glGetQueryObjectui64vEXT.?(prev_q, GL_QUERY_RESULT_EXT, &elapsed);
                if (elapsed != 0) gpu_ms = smooth(gpu_ms, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms);
            }
            // Mali-G52 r46p0 advertises the extension but never returns a
            // result, so give up after a second and measure it the blunt way.
            if (frames > 120 and gpu_ms == 0) gpu_mode = .finish;
        }
        if (gpu_mode == .query) glBeginQueryEXT.?(GL_TIME_ELAPSED_EXT, q);

        glClear(GL_COLOR_BUFFER_BIT);

        glUseProgram(tri_prog);
        glBindBuffer(GL_UNIFORM_BUFFER, ubo);
        glBufferSubData(GL_UNIFORM_BUFFER, 0, @sizeOf(@TypeOf(uniforms)), &uniforms);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);
        glBindVertexArray(vao);
        glDrawArraysInstanced(GL_TRIANGLES, 0, 3, INSTANCES);

        @memset(&overlay_px, 0);
        overlayLine(0, std.fmt.bufPrint(&line, "cpu  {d: >6.2} ms", .{cpu_ms}) catch "cpu ?");
        // The star marks the glFinish fallback: a real number, but measured by
        // stalling rather than by asking the GPU.
        overlayLine(1, std.fmt.bufPrint(&line, "gpu {s}{d: >6.2} ms", .{
            if (gpu_mode == .finish) "*" else " ", gpu_ms,
        }) catch "gpu ?");
        overlayLine(2, std.fmt.bufPrint(&line, "frame{d: >6.2} ms", .{frame_ms}) catch "frame ?");
        overlayLine(4, std.fmt.bufPrint(&line, "{d} tris", .{INSTANCES}) catch "?");
        // Both numbers on purpose: what the output says it runs at, and what
        // we are actually presenting. On a variable-refresh output they differ.
        overlayLine(3, std.fmt.bufPrint(&line, "{d: >5.1}/{d: >5.1} Hz", .{
            if (frame_ms > 0) 1000.0 / frame_ms else 0.0,
            @as(f64, @floatFromInt(wl.refresh_mhz)) / 1000.0,
        }) catch "hz ?");
        // Same numbers as the overlay, once a second, so `zig build run` over
        // ssh shows them without a camera pointed at the TV.
        if (dump_after > 0 or frames % 60 == 0)
            std.debug.print("cpu {d:.2} ms  gpu{s}{d:.2} ms  frame {d:.2} ms  {d:.1} Hz\n", .{
                cpu_ms,   if (gpu_mode == .finish) "* " else " ",       gpu_ms,
                frame_ms, if (frame_ms > 0) 1000.0 / frame_ms else 0.0,
            });
        glUseProgram(text_prog);
        glActiveTexture(GL_TEXTURE0 + TEXT_ATLAS_UNIT);
        glBindTexture(GL_TEXTURE_2D, overlay_tex);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, OVERLAY_W, OVERLAY_H, GL_RED, GL_UNSIGNED_BYTE, &overlay_px);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, text_ubo);
        glBindVertexArray(vao_text);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        switch (gpu_mode) {
            .query => glEndQueryEXT.?(GL_TIME_ELAPSED_EXT),
            // Costs the CPU/GPU overlap, but this app is vsync-bound anyway.
            .finish => {
                const t0 = nowNs();
                glFinish();
                gpu_ms = smooth(gpu_ms, @as(f64, @floatFromInt(nowNs() - t0)) / std.time.ns_per_ms);
            },
            .none => {},
        }
        if (dump_after > 0) {
            dump_after -= 1;
            if (dump_after == 0) {
                dumpFrame();
                return;
            }
        }

        frames += 1;
        cpu_ms = smooth(cpu_ms, @as(f64, @floatFromInt(cpuNs() - cpu_start)) / std.time.ns_per_ms);
        gl.swap();
    }
}
