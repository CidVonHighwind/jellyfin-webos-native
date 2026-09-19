//! TV UI demo: instanced loom renderer, remote focus navigation and a 10,000
//! row virtual list. BACK exits; arrows navigate; ENTER/OK activates.

const std = @import("std");
const linux = std.os.linux;
const gl = @import("gl.zig");
const wl = @import("wl.zig");
const loom = @import("loom/loom.zig");
const UiRenderer = @import("ui_renderer.zig").Renderer;

const GL_COLOR_BUFFER_BIT = 0x00004000;
const GL_TIME_ELAPSED_EXT = 0x88BF;
const GL_QUERY_RESULT_EXT = 0x8866;
const GL_QUERY_RESULT_AVAILABLE_EXT = 0x8867;
var glClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void = undefined;
var glClear: *const fn (u32) callconv(.c) void = undefined;
var glViewport: *const fn (i32, i32, i32, i32) callconv(.c) void = undefined;
var glFinish: *const fn () callconv(.c) void = undefined;
var glGenQueriesEXT: ?*const fn (i32, [*]u32) callconv(.c) void = null;
var glBeginQueryEXT: ?*const fn (u32, u32) callconv(.c) void = null;
var glEndQueryEXT: ?*const fn (u32) callconv(.c) void = null;
var glGetQueryObjectuivEXT: ?*const fn (u32, u32, *u32) callconv(.c) void = null;
var glGetQueryObjectui64vEXT: ?*const fn (u32, u32, *u64) callconv(.c) void = null;

const BG: loom.Color = .{ 12, 16, 25, 255 };
const PANEL: loom.Color = .{ 22, 29, 43, 255 };
const ROW: loom.Color = .{ 28, 37, 54, 255 };
const ROW_ALT: loom.Color = .{ 25, 34, 50, 255 };
const HOT: loom.Color = .{ 42, 57, 79, 255 };
const SELECTED: loom.Color = .{ 35, 75, 105, 255 };
const ACCENT: loom.Color = .{ 83, 202, 255, 255 };
const TEXT: loom.Color = .{ 235, 241, 248, 255 };
const DIM: loom.Color = .{ 151, 164, 181, 255 };

const FocusArea = enum { toolbar, list };
var focus_area: FocusArea = .toolbar;
var focus_button: usize = 0;
var selected: usize = 0;
var scroll: f32 = 0;
var cursor_x: f32 = -1;
var cursor_y: f32 = -1;
var cursor_present = false;
var pointer_press = false;
var list_rect: loom.Rect = .{};
var item_height: f32 = 72;
var status: [160]u8 = @splat(0);
var status_len: usize = 0;
var row_labels: [40][72]u8 = undefined;
var row_label_lens: [40]usize = @splat(0);
var cpu_ms: f64 = 0;
var gpu_ms: f64 = 0;
var frame_ms: f64 = 0;
var gpu_fallback = false;

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(&status, fmt, args) catch "Action completed";
    status_len = result.len;
}

fn activateFocus() void {
    switch (focus_area) {
        .toolbar => setStatus("Activated {s}", .{button_labels[focus_button]}),
        .list => setStatus("Opened virtual item {d}", .{selected + 1}),
    }
}

fn ensureSelectedVisible() void {
    const list = loom.VirtualList.init(list_rect, ITEM_COUNT, item_height, scroll);
    scroll = list.scrollToReveal(selected);
}

fn key(code: u32) void {
    switch (code) {
        1, 158 => wl.running = false, // ESC / BACK
        105 => if (focus_area == .toolbar) { // left
            focus_button -|= 1;
        },
        106 => if (focus_area == .toolbar) { // right
            focus_button = @min(button_labels.len - 1, focus_button + 1);
        },
        103 => switch (focus_area) { // up
            .toolbar => {},
            .list => if (selected == 0) {
                focus_area = .toolbar;
            } else {
                selected -= 1;
                ensureSelectedVisible();
            },
        },
        108 => switch (focus_area) { // down
            .toolbar => {
                focus_area = .list;
                ensureSelectedVisible();
            },
            .list => if (selected + 1 < ITEM_COUNT) {
                selected += 1;
                ensureSelectedVisible();
            },
        },
        28, 352 => activateFocus(), // ENTER / SELECT / OK
        else => {},
    }
}

fn onEvent(event: wl.Event) void {
    switch (event) {
        .key => |e| if (e.pressed) key(e.code),
        .pointer_enter => |e| {
            cursor_x = @floatFromInt(wl.toInt(e.x));
            cursor_y = @floatFromInt(wl.toInt(e.y));
            cursor_present = true;
        },
        .pointer_motion => |e| {
            cursor_x = @floatFromInt(wl.toInt(e.x));
            cursor_y = @floatFromInt(wl.toInt(e.y));
            cursor_present = true;
        },
        .pointer_leave => {
            cursor_present = false;
            cursor_x = -1;
        },
        .pointer_button => |e| if (e.pressed and e.button == 0x110) {
            pointer_press = true;
        },
        .pointer_axis => |e| if (e.axis == 0) {
            scroll += @as(f32, @floatFromInt(wl.toInt(e.value))) * 1.4;
        },
        .close => wl.running = false,
        else => {},
    }
}

const ITEM_COUNT = 10_000;
const button_labels = [_][]const u8{ "Library", "Shuffle", "Settings" };

fn hovered(rect: loom.Rect) bool {
    return cursor_present and rect.contains(cursor_x, cursor_y);
}

fn button(ctx: *loom.Context, rect: loom.Rect, index: usize, radius: f32, font: f32) void {
    const hot = hovered(rect);
    const focused = focus_area == .toolbar and focus_button == index;
    ctx.fill(rect, null, if (hot) HOT else PANEL, radius);
    ctx.stroke(rect, null, if (focused) ACCENT else .{ 61, 75, 94, 255 }, if (focused) 4 else 2, radius);
    ctx.label(.{ .x = rect.x + font, .y = rect.y + (rect.h - font * 1.2) / 2, .w = rect.w - font * 2, .h = font * 1.3 }, null, button_labels[index], TEXT, font);
    if (hot and pointer_press) {
        focus_area = .toolbar;
        focus_button = index;
        activateFocus();
    }
}

fn updateEdgeScroll(dt: f32, scale: f32) void {
    if (!cursor_present or !list_rect.contains(cursor_x, cursor_y)) return;
    const zone = 84 * scale;
    const from_top = cursor_y - list_rect.y;
    const from_bottom = list_rect.y + list_rect.h - cursor_y;
    const speed = 920 * scale;
    if (from_top < zone) {
        const strength = 1 - std.math.clamp(from_top / zone, 0, 1);
        scroll -= speed * strength * dt;
    } else if (from_bottom < zone) {
        const strength = 1 - std.math.clamp(from_bottom / zone, 0, 1);
        scroll += speed * strength * dt;
    }
}

fn buildUi(ctx: *loom.Context, renderer: *UiRenderer, dt: f32) void {
    const width: f32 = @floatFromInt(gl.width);
    const height: f32 = @floatFromInt(gl.height);
    const scale = @min(width / 1920.0, height / 1080.0);
    const margin = 64 * scale;
    const title_size = 46 * scale;
    const body_size = 28 * scale;
    const small_size = 22 * scale;
    const radius = 14 * scale;
    item_height = 74 * scale;

    ctx.begin(width, height);
    ctx.fill(.{ .w = width, .h = height }, null, BG, 0);
    ctx.label(.{ .x = margin, .y = 38 * scale, .w = width - margin * 2, .h = 64 * scale }, null, "webOS native UI", TEXT, title_size);
    ctx.label(.{ .x = margin, .y = 96 * scale, .w = width - margin * 2, .h = 40 * scale }, null, "One instanced quad batch - real LG font - remote and pointer navigation", DIM, small_size);

    var toolbar = loom.Stack.init(.{ .x = margin, .y = 145 * scale, .w = width - margin * 2, .h = 76 * scale }, .horizontal, 0, 18 * scale);
    for (button_labels, 0..) |_, index| button(ctx, toolbar.take(230 * scale), index, radius, body_size);

    const sidebar_w = 430 * scale;
    const gap = 36 * scale;
    const content_y = 265 * scale;
    const content_h = height - content_y - margin;
    list_rect = .{ .x = margin, .y = content_y, .w = width - margin * 2 - sidebar_w - gap, .h = content_h };
    const sidebar = loom.Rect{ .x = list_rect.x + list_rect.w + gap, .y = content_y, .w = sidebar_w, .h = content_h };

    updateEdgeScroll(@min(dt, 0.05), scale);
    var list = loom.VirtualList.init(list_rect.inset(8 * scale), ITEM_COUNT, item_height, scroll);
    scroll = list.scroll;

    ctx.fill(list_rect, null, PANEL, radius);
    ctx.stroke(list_rect, null, .{ 48, 62, 81, 255 }, 2, radius);
    var label_slot: usize = 0;
    for (list.first..list.last) |index| {
        if (label_slot == row_labels.len) break;
        const raw = list.itemRect(index);
        const row = loom.Rect{ .x = raw.x + 8 * scale, .y = raw.y + 5 * scale, .w = raw.w - 16 * scale, .h = raw.h - 10 * scale };
        const hot = hovered(row);
        const focused = focus_area == .list and index == selected;
        const chosen = index == selected;
        ctx.fill(row, list_rect, if (focused) SELECTED else if (hot) HOT else if (index % 2 == 0) ROW else ROW_ALT, 9 * scale);
        if (focused) ctx.stroke(row, list_rect, ACCENT, 4 * scale, 9 * scale);

        const label = std.fmt.bufPrint(&row_labels[label_slot], "Virtual row {d}", .{index + 1}) catch "Virtual row";
        row_label_lens[label_slot] = label.len;
        ctx.label(.{ .x = row.x + 24 * scale, .y = row.y + (row.h - body_size * 1.18) / 2, .w = row.w * 0.7, .h = body_size * 1.3 }, list_rect, row_labels[label_slot][0..row_label_lens[label_slot]], TEXT, body_size);
        var number: [20]u8 = undefined;
        const number_text = std.fmt.bufPrint(&number, "#{d:0>5}", .{index + 1}) catch "#";
        // This command would borrow a stack buffer, so copy the short suffix
        // into the unused tail of the row's persistent frame slot.
        const suffix_at = row_label_lens[label_slot] + 1;
        @memcpy(row_labels[label_slot][suffix_at..][0..number_text.len], number_text);
        ctx.label(.{ .x = row.x + row.w - 135 * scale, .y = row.y + (row.h - small_size * 1.18) / 2, .w = 120 * scale, .h = small_size * 1.3 }, list_rect, row_labels[label_slot][suffix_at..][0..number_text.len], if (chosen) ACCENT else DIM, small_size);
        if (hot and pointer_press) {
            focus_area = .list;
            selected = index;
            setStatus("Opened virtual item {d}", .{selected + 1});
        }
        label_slot += 1;
    }

    // Scrollbar communicates that the ten thousand logical rows are real even
    // though only the visible dozen emitted commands this frame.
    const track = loom.Rect{ .x = list_rect.x + list_rect.w - 7 * scale, .y = list_rect.y + radius, .w = 3 * scale, .h = list_rect.h - radius * 2 };
    const content_h_full = @as(f32, @floatFromInt(ITEM_COUNT)) * item_height;
    const thumb_h = @max(30 * scale, track.h * list.viewport.h / content_h_full);
    const thumb_y = track.y + (track.h - thumb_h) * (if (list.maxScroll() > 0) scroll / list.maxScroll() else 0);
    ctx.fill(track, list_rect, .{ 52, 65, 82, 255 }, track.w / 2);
    ctx.fill(.{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, list_rect, ACCENT, track.w / 2);

    ctx.fill(sidebar, null, PANEL, radius);
    ctx.stroke(sidebar, null, .{ 48, 62, 81, 255 }, 2, radius);
    const sx = sidebar.x + 30 * scale;
    ctx.label(.{ .x = sx, .y = sidebar.y + 26 * scale, .w = sidebar.w - 60 * scale, .h = 45 * scale }, sidebar, "Remote navigation", TEXT, 31 * scale);
    ctx.label(.{ .x = sx, .y = sidebar.y + 92 * scale, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, "Arrows   move focus", DIM, small_size);
    ctx.label(.{ .x = sx, .y = sidebar.y + 132 * scale, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, "OK/Enter activate", DIM, small_size);
    ctx.label(.{ .x = sx, .y = sidebar.y + 172 * scale, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, "Back      exit", DIM, small_size);
    ctx.label(.{ .x = sx, .y = sidebar.y + 244 * scale, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, "Hover near a list edge", ACCENT, small_size);
    ctx.label(.{ .x = sx, .y = sidebar.y + 278 * scale, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, "to scroll continuously", ACCENT, small_size);

    const stats_y = sidebar.y + sidebar.h - 205 * scale;
    var stats_buf: [96]u8 = undefined;
    const stats = std.fmt.bufPrint(&stats_buf, "Rows {d}-{d} of {d}", .{ list.first + 1, list.last, ITEM_COUNT }) catch "Virtual list";
    // Render immediately after command construction, so this final stack slice
    // remains alive until draw returns below.
    ctx.label(.{ .x = sx, .y = stats_y, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, stats, DIM, small_size);
    var timer_buf: [120]u8 = undefined;
    const timers = std.fmt.bufPrint(&timer_buf, "CPU {d:.2} ms   GPU{s}{d:.2} ms", .{ cpu_ms, if (gpu_fallback) "* " else " ", gpu_ms }) catch "timers unavailable";
    ctx.label(.{ .x = sx, .y = stats_y + 40 * scale, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, timers, DIM, small_size);
    var frame_buf: [64]u8 = undefined;
    const frame = std.fmt.bufPrint(&frame_buf, "Frame {d:.2} ms", .{frame_ms}) catch "frame";
    ctx.label(.{ .x = sx, .y = stats_y + 78 * scale, .w = sidebar.w - 60 * scale, .h = 35 * scale }, sidebar, frame, DIM, small_size);
    ctx.label(.{ .x = sx, .y = stats_y + 126 * scale, .w = sidebar.w - 60 * scale, .h = 40 * scale }, sidebar, if (status_len == 0) "Ready" else status[0..status_len], ACCENT, small_size);

    renderer.draw(ctx.commands.items, width, height);
    pointer_press = false;
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn cpuNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn smooth(previous: f64, sample: f64) f64 {
    return if (previous == 0) sample else previous * 0.9 + sample * 0.1;
}

pub fn main(init: std.process.Init) !void {
    wl.on_event = onEvent;
    const appid = std.c.getenv("APPID") orelse @as([*:0]const u8, "dev.hookedbehemoth.uidemo");
    try gl.init(appid, "webOS native UI", 0, 0);
    glClearColor = gl.proc(@TypeOf(glClearColor), "glClearColor");
    glClear = gl.proc(@TypeOf(glClear), "glClear");
    glViewport = gl.proc(@TypeOf(glViewport), "glViewport");
    glFinish = gl.proc(@TypeOf(glFinish), "glFinish");
    glGenQueriesEXT = gl.procOpt(@TypeOf(glGenQueriesEXT.?), "glGenQueriesEXT");
    glBeginQueryEXT = gl.procOpt(@TypeOf(glBeginQueryEXT.?), "glBeginQueryEXT");
    glEndQueryEXT = gl.procOpt(@TypeOf(glEndQueryEXT.?), "glEndQueryEXT");
    glGetQueryObjectuivEXT = gl.procOpt(@TypeOf(glGetQueryObjectuivEXT.?), "glGetQueryObjectuivEXT");
    glGetQueryObjectui64vEXT = gl.procOpt(@TypeOf(glGetQueryObjectui64vEXT.?), "glGetQueryObjectui64vEXT");
    glViewport(0, 0, @intCast(gl.width), @intCast(gl.height));
    glClearColor(12.0 / 255.0, 16.0 / 255.0, 25.0 / 255.0, 1);

    var renderer = try UiRenderer.init(init.gpa, init.io);
    defer renderer.deinit();
    var ctx = loom.Context.init(init.gpa);
    defer ctx.deinit();
    std.debug.print("UI demo: {d}x{d}, {d} logical rows, one instanced batch\n", .{ gl.width, gl.height, ITEM_COUNT });

    var previous = nowNs();
    var gpu_mode: enum { query, finish } = if (glGenQueriesEXT != null and glBeginQueryEXT != null and glEndQueryEXT != null and glGetQueryObjectuivEXT != null and glGetQueryObjectui64vEXT != null) .query else .finish;
    var queries: [2]u32 = @splat(0);
    if (gpu_mode == .query) glGenQueriesEXT.?(2, &queries);
    var frames: u64 = 0;
    while (wl.poll()) {
        const now = nowNs();
        const cpu_start = cpuNs();
        const elapsed = now - previous;
        const dt = @as(f32, @floatFromInt(elapsed)) / std.time.ns_per_s;
        frame_ms = smooth(frame_ms, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms);
        previous = now;

        const query = queries[@intCast(frames % 2)];
        const previous_query = queries[@intCast((frames + 1) % 2)];
        if (gpu_mode == .query and frames > 1) {
            var available: u32 = 0;
            glGetQueryObjectuivEXT.?(previous_query, GL_QUERY_RESULT_AVAILABLE_EXT, &available);
            if (available != 0) {
                var elapsed_ns: u64 = 0;
                glGetQueryObjectui64vEXT.?(previous_query, GL_QUERY_RESULT_EXT, &elapsed_ns);
                if (elapsed_ns != 0) gpu_ms = smooth(gpu_ms, @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms);
            }
            // Same Mali r46p0 behavior as gltri: advertised, but no result.
            if (frames > 120 and gpu_ms == 0) gpu_mode = .finish;
        }
        gpu_fallback = gpu_mode == .finish;
        if (gpu_mode == .query) glBeginQueryEXT.?(GL_TIME_ELAPSED_EXT, query);
        glClear(GL_COLOR_BUFFER_BIT);
        buildUi(&ctx, &renderer, dt);
        switch (gpu_mode) {
            .query => glEndQueryEXT.?(GL_TIME_ELAPSED_EXT),
            .finish => {
                const gpu_start = nowNs();
                glFinish();
                gpu_ms = smooth(gpu_ms, @as(f64, @floatFromInt(nowNs() - gpu_start)) / std.time.ns_per_ms);
            },
        }
        gl.swap();
        frames += 1;
        cpu_ms = smooth(cpu_ms, @as(f64, @floatFromInt(cpuNs() - cpu_start)) / std.time.ns_per_ms);
    }
}
