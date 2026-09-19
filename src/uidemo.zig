//! Offline, multi-screen Jellyfin-shaped UI demo. The same OpenGL/Wayland
//! binary runs on desktop and webOS; no server discovery or HTTP exists yet.

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
const GL_RGBA = 0x1908;
const GL_UNSIGNED_BYTE = 0x1401;
var glClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void = undefined;
var glClear: *const fn (u32) callconv(.c) void = undefined;
var glViewport: *const fn (i32, i32, i32, i32) callconv(.c) void = undefined;
var glFinish: *const fn () callconv(.c) void = undefined;
var glGenQueriesEXT: ?*const fn (i32, [*]u32) callconv(.c) void = null;
var glBeginQueryEXT: ?*const fn (u32, u32) callconv(.c) void = null;
var glEndQueryEXT: ?*const fn (u32) callconv(.c) void = null;
var glGetQueryObjectuivEXT: ?*const fn (u32, u32, *u32) callconv(.c) void = null;
var glGetQueryObjectui64vEXT: ?*const fn (u32, u32, *u64) callconv(.c) void = null;
var glReadPixels: *const fn (i32, i32, i32, i32, u32, u32, [*]u8) callconv(.c) void = undefined;

const BG: loom.Color = .{ 9, 13, 22, 255 };
const PANEL: loom.Color = .{ 20, 27, 40, 255 };
const CARD: loom.Color = .{ 27, 36, 52, 255 };
const HOT: loom.Color = .{ 38, 51, 70, 255 };
const SELECTED: loom.Color = .{ 27, 69, 91, 255 };
const ACCENT: loom.Color = .{ 0, 164, 220, 255 };
const GREEN: loom.Color = .{ 82, 205, 147, 255 };
const TEXT: loom.Color = .{ 239, 244, 250, 255 };
const DIM: loom.Color = .{ 148, 163, 182, 255 };
const BORDER: loom.Color = .{ 55, 70, 91, 255 };

const Screen = enum { server, auth, quick_connect, library, details };
const EditField = enum { none, url, username, password };
const LIBRARY_COUNT = 1_000;

var screen: Screen = .server;
var focus: usize = 0;
var selected: usize = 0;
var scroll: f32 = 0;
var item_height: f32 = 132;
var list_rect: loom.Rect = .{};
var cursor_x: f32 = -1;
var cursor_y: f32 = -1;
var cursor_present = false;
var pointer_press = false;
var active_field: EditField = .none;
var shift_down = false;
var caps_lock = false;
var capture_requested = false;

var server_url: [256]u8 = @splat(0);
var server_url_len: usize = 0;
var username: [256]u8 = @splat(0);
var username_len: usize = 0;
var password: [256]u8 = @splat(0);
var password_len: usize = 0;
var password_mask: [256]u8 = @splat(0);
var url_rect: loom.Rect = .{};
var username_rect: loom.Rect = .{};
var password_rect: loom.Rect = .{};

var status: [160]u8 = @splat(0);
var status_len: usize = 0;
var row_labels: [16][96]u8 = undefined;
var row_label_lens: [16]usize = @splat(0);
var timer_text: [144]u8 = @splat(0);
var timer_text_len: usize = 0;
var cpu_ms: f64 = 0;
var gpu_ms: f64 = 0;
var frame_ms: f64 = 0;
var gpu_fallback = false;

const media_titles = [_][]const u8{
    "Beyond the Cloudline",
    "A Summer in Amalfi",
    "Midnight Signal",
    "The Mosswood Friends",
    "Worlds Between",
    "The Amber Expedition",
};
const screen_titles = [_][]const u8{
    "Choose a server",
    "Sign in",
    "Quick Connect",
    "My Library",
    "Media details",
};

const EditTarget = struct { buffer: *[256]u8, len: *usize };

fn target(field: EditField) EditTarget {
    return switch (field) {
        .url => .{ .buffer = &server_url, .len = &server_url_len },
        .username => .{ .buffer = &username, .len = &username_len },
        .password => .{ .buffer = &password, .len = &password_len },
        .none => unreachable,
    };
}

fn setField(field: EditField, value: []const u8) void {
    const t = target(field);
    t.len.* = @min(value.len, t.buffer.len - 1);
    @memcpy(t.buffer[0..t.len.*], value[0..t.len.*]);
    t.buffer[t.len.*] = 0;
}

fn fieldText(field: EditField) []const u8 {
    const t = target(field);
    return t.buffer[0..t.len.*];
}

fn fieldZ(field: EditField) [:0]const u8 {
    const t = target(field);
    t.buffer[t.len.*] = 0;
    return t.buffer[0..t.len.* :0];
}

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(&status, fmt, args) catch "Ready";
    status_len = result.len;
}

fn hovered(rect: loom.Rect) bool {
    return cursor_present and rect.contains(cursor_x, cursor_y);
}

fn rectInts(rect: loom.Rect) [4]i32 {
    return .{ @intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.w), @intFromFloat(rect.h) };
}

fn beginEdit(field: EditField, rect: loom.Rect) void {
    if (active_field != .none) wl.endTextInput();
    active_field = field;
    const purpose: wl.TextPurpose = switch (field) {
        .url => .url,
        .password => .password,
        else => .normal,
    };
    if (wl.beginTextInput(fieldZ(field), rectInts(rect), purpose))
        setStatus("webOS keyboard opened", .{})
    else
        setStatus("Type with the desktop keyboard; Enter finishes", .{});
}

fn endEdit() void {
    if (active_field == .none) return;
    wl.endTextInput();
    active_field = .none;
    setStatus("Text saved", .{});
}

fn syncEdit() void {
    if (active_field != .none) wl.updateTextInput(fieldZ(active_field));
}

fn appendText(text: []const u8) void {
    if (active_field == .none) return;
    const t = target(active_field);
    const count = @min(text.len, t.buffer.len - 1 - t.len.*);
    @memcpy(t.buffer[t.len.*..][0..count], text[0..count]);
    t.len.* += count;
    t.buffer[t.len.*] = 0;
    syncEdit();
}

fn eraseText(count: usize) void {
    if (active_field == .none) return;
    const t = target(active_field);
    t.len.* -|= @min(count, t.len.*);
    t.buffer[t.len.*] = 0;
    syncEdit();
}

fn go(next: Screen) void {
    endEdit();
    screen = next;
    focus = 0;
    scroll = 0;
}

fn goBack() void {
    if (active_field != .none) {
        endEdit();
        return;
    }
    switch (screen) {
        .server => wl.running = false,
        .auth => go(.server),
        .quick_connect => go(.auth),
        .library => go(.auth),
        .details => go(.library),
    }
}

fn activate() void {
    switch (screen) {
        .server => switch (focus) {
            0 => {
                setField(.url, "http://living-room.local:8096");
                go(.auth);
            },
            1 => beginEdit(.url, url_rect),
            else => if (server_url_len == 0)
                setStatus("Enter a server URL first", .{})
            else
                go(.auth),
        },
        .auth => switch (focus) {
            0 => beginEdit(.username, username_rect),
            1 => beginEdit(.password, password_rect),
            2 => go(.library),
            else => go(.quick_connect),
        },
        .quick_connect => if (focus == 0) go(.library) else go(.auth),
        .library => go(.details),
        .details => if (focus == 0)
            setStatus("Playback is intentionally not connected yet", .{})
        else
            go(.library),
    }
}

fn ensureSelectedVisible() void {
    const list = loom.VirtualList.init(list_rect, LIBRARY_COUNT, item_height, scroll);
    scroll = list.scrollToReveal(selected);
}

fn focusMax() usize {
    return switch (screen) {
        .server => 2,
        .auth => 3,
        .quick_connect => 1,
        .library => LIBRARY_COUNT - 1,
        .details => 1,
    };
}

fn navigate(code: u32) void {
    switch (code) {
        1, 158 => goBack(),
        103 => if (focus > 0) {
            focus -= 1;
            if (screen == .library) {
                selected = focus;
                ensureSelectedVisible();
            }
        },
        108 => if (focus < focusMax()) {
            focus += 1;
            if (screen == .library) {
                selected = focus;
                ensureSelectedVisible();
            }
        },
        105 => if (screen == .details and focus > 0) {
            focus -= 1;
        },
        106 => if (screen == .details and focus < 1) {
            focus += 1;
        },
        28, 96, 352 => activate(),
        else => {},
    }
}

const KeyPair = struct { code: u32, lower: u8, upper: u8 };
const key_pairs = [_]KeyPair{
    .{ .code = 2, .lower = '1', .upper = '!' },   .{ .code = 3, .lower = '2', .upper = '@' },
    .{ .code = 4, .lower = '3', .upper = '#' },   .{ .code = 5, .lower = '4', .upper = '$' },
    .{ .code = 6, .lower = '5', .upper = '%' },   .{ .code = 7, .lower = '6', .upper = '^' },
    .{ .code = 8, .lower = '7', .upper = '&' },   .{ .code = 9, .lower = '8', .upper = '*' },
    .{ .code = 10, .lower = '9', .upper = '(' },  .{ .code = 11, .lower = '0', .upper = ')' },
    .{ .code = 12, .lower = '-', .upper = '_' },  .{ .code = 13, .lower = '=', .upper = '+' },
    .{ .code = 16, .lower = 'q', .upper = 'Q' },  .{ .code = 17, .lower = 'w', .upper = 'W' },
    .{ .code = 18, .lower = 'e', .upper = 'E' },  .{ .code = 19, .lower = 'r', .upper = 'R' },
    .{ .code = 20, .lower = 't', .upper = 'T' },  .{ .code = 21, .lower = 'y', .upper = 'Y' },
    .{ .code = 22, .lower = 'u', .upper = 'U' },  .{ .code = 23, .lower = 'i', .upper = 'I' },
    .{ .code = 24, .lower = 'o', .upper = 'O' },  .{ .code = 25, .lower = 'p', .upper = 'P' },
    .{ .code = 26, .lower = '[', .upper = '{' },  .{ .code = 27, .lower = ']', .upper = '}' },
    .{ .code = 30, .lower = 'a', .upper = 'A' },  .{ .code = 31, .lower = 's', .upper = 'S' },
    .{ .code = 32, .lower = 'd', .upper = 'D' },  .{ .code = 33, .lower = 'f', .upper = 'F' },
    .{ .code = 34, .lower = 'g', .upper = 'G' },  .{ .code = 35, .lower = 'h', .upper = 'H' },
    .{ .code = 36, .lower = 'j', .upper = 'J' },  .{ .code = 37, .lower = 'k', .upper = 'K' },
    .{ .code = 38, .lower = 'l', .upper = 'L' },  .{ .code = 39, .lower = ';', .upper = ':' },
    .{ .code = 40, .lower = '\'', .upper = '"' }, .{ .code = 43, .lower = '\\', .upper = '|' },
    .{ .code = 44, .lower = 'z', .upper = 'Z' },  .{ .code = 45, .lower = 'x', .upper = 'X' },
    .{ .code = 46, .lower = 'c', .upper = 'C' },  .{ .code = 47, .lower = 'v', .upper = 'V' },
    .{ .code = 48, .lower = 'b', .upper = 'B' },  .{ .code = 49, .lower = 'n', .upper = 'N' },
    .{ .code = 50, .lower = 'm', .upper = 'M' },  .{ .code = 51, .lower = ',', .upper = '<' },
    .{ .code = 52, .lower = '.', .upper = '>' },  .{ .code = 53, .lower = '/', .upper = '?' },
    .{ .code = 57, .lower = ' ', .upper = ' ' },
};

fn keyByte(code: u32) ?u8 {
    for (key_pairs) |pair| if (pair.code == code) {
        const letter = pair.lower >= 'a' and pair.lower <= 'z';
        return if (shift_down != (caps_lock and letter)) pair.upper else pair.lower;
    };
    return null;
}

fn onKey(code: u32, pressed: bool) void {
    if (code == 42 or code == 54) {
        shift_down = pressed;
        return;
    }
    if (!pressed) return;
    if (code == 88) { // F12
        capture_requested = true;
        setStatus("Capturing the OpenGL framebuffer", .{});
        return;
    }
    if (code == 58) {
        caps_lock = !caps_lock;
        return;
    }
    if (active_field != .none) {
        switch (code) {
            1, 158, 28, 96, 352 => endEdit(),
            14 => eraseText(1),
            else => if (keyByte(code)) |byte| appendText(&.{byte}),
        }
        return;
    }
    navigate(code);
}

fn onTextKeysym(sym: u32, pressed: bool) void {
    if (!pressed or active_field == .none) return;
    switch (sym) {
        0xff08 => eraseText(1),
        0xff0d, 0xff8d, 0xff1b => endEdit(),
        else => {},
    }
}

fn onEvent(event: wl.Event) void {
    switch (event) {
        .key => |e| onKey(e.code, e.pressed),
        .text_commit => |text| appendText(text),
        .text_delete => |edit| eraseText(@max(1, edit.length)),
        .text_keysym => |e| onTextKeysym(e.sym, e.pressed),
        .input_panel => |visible| {
            if (!visible and active_field != .none) active_field = .none;
        },
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
        .pointer_axis => |e| if (screen == .library and e.axis == 0) {
            scroll += @as(f32, @floatFromInt(wl.toInt(e.value))) * 1.4;
        },
        .close => wl.running = false,
        else => {},
    }
}

fn artworkUv(index: usize) [4]f32 {
    const cell = index % media_titles.len;
    const col: f32 = @floatFromInt(cell % 3);
    const row: f32 = @floatFromInt(cell / 3);
    const px = 0.5 / 768.0;
    const py = 0.5 / 432.0;
    return .{ col / 3.0 + px, row / 2.0 + py, (col + 1) / 3.0 - px, (row + 1) / 2.0 - py };
}

var draw_calls: u32 = 0;
var overdraw: f64 = 0;
var kind_overdraw: [5]f64 = @splat(0);

fn drawHeader(ctx: *loom.Context, width: f32, scale: f32) void {
    const margin = 64 * scale;
    ctx.label(.{ .x = margin, .y = 32 * scale, .w = 700 * scale, .h = 55 * scale }, null, "Jellyfin native UI demo", TEXT, 40 * scale);
    ctx.label(.{ .x = margin, .y = 84 * scale, .w = 700 * scale, .h = 34 * scale }, null, screen_titles[@intFromEnum(screen)], ACCENT, 23 * scale);
    // Draw calls are last frame's: the header is built before the renderer
    // runs. That is the number to watch when adding textures -- the batch only
    // breaks when a binding changes.
    const metrics = std.fmt.bufPrint(&timer_text, "CPU {d:.2} ms   GPU{s}{d:.2} ms   Frame {d:.2} ms   {d} draws   {d:.1}x over", .{
        cpu_ms, if (gpu_fallback) "* " else " ", gpu_ms, frame_ms, draw_calls, overdraw,
    }) catch "timers unavailable";
    timer_text_len = metrics.len;
    ctx.label(.{ .x = width - 800 * scale, .y = 48 * scale, .w = 740 * scale, .h = 36 * scale }, null, timer_text[0..timer_text_len], DIM, 19 * scale);
}

fn drawButton(ctx: *loom.Context, rect: loom.Rect, label: []const u8, index: usize, scale: f32) void {
    const hot = hovered(rect);
    const focused = focus == index;
    ctx.fill(rect, null, if (hot) HOT else CARD, 12 * scale);
    ctx.stroke(rect, null, if (focused) ACCENT else BORDER, if (focused) 4 * scale else 2 * scale, 12 * scale);
    ctx.label(.{ .x = rect.x + 24 * scale, .y = rect.y + (rect.h - 30 * scale) / 2, .w = rect.w - 48 * scale, .h = 38 * scale }, rect, label, TEXT, 26 * scale);
    if (hot and pointer_press) {
        focus = index;
        activate();
    }
}

fn drawField(ctx: *loom.Context, rect: loom.Rect, label: []const u8, field: EditField, index: usize, scale: f32) void {
    const hot = hovered(rect);
    const focused = focus == index;
    const editing = active_field == field;
    ctx.label(.{ .x = rect.x, .y = rect.y - 34 * scale, .w = rect.w, .h = 30 * scale }, null, label, DIM, 20 * scale);
    ctx.fill(rect, null, if (editing) SELECTED else if (hot) HOT else CARD, 10 * scale);
    ctx.stroke(rect, null, if (focused or editing) ACCENT else BORDER, if (focused or editing) 4 * scale else 2 * scale, 10 * scale);
    var contents = fieldText(field);
    if (field == .password) {
        @memset(password_mask[0..password_len], '*');
        contents = password_mask[0..password_len];
    }
    ctx.label(.{ .x = rect.x + 22 * scale, .y = rect.y + 17 * scale, .w = rect.w - 44 * scale, .h = 38 * scale }, rect, if (contents.len == 0) "Press OK to type" else contents, if (contents.len == 0) DIM else TEXT, 25 * scale);
    if (editing) ctx.fill(.{ .x = rect.x + 22 * scale + @min(rect.w - 55 * scale, @as(f32, @floatFromInt(contents.len)) * 13 * scale), .y = rect.y + 18 * scale, .w = 2 * scale, .h = 31 * scale }, rect, ACCENT, 0);
    if (hot and pointer_press) {
        focus = index;
        beginEdit(field, rect);
    }
}

fn drawStatus(ctx: *loom.Context, width: f32, height: f32, scale: f32) void {
    const text = if (status_len == 0) "Arrows move - OK selects - Back returns" else status[0..status_len];
    ctx.label(.{ .x = 64 * scale, .y = height - 48 * scale, .w = width - 128 * scale, .h = 32 * scale }, null, text, if (status_len == 0) DIM else GREEN, 19 * scale);
}

fn drawServer(ctx: *loom.Context, width: f32, scale: f32) void {
    const panel = loom.Rect{ .x = 270 * scale, .y = 165 * scale, .w = width - 540 * scale, .h = 770 * scale };
    ctx.fill(panel, null, PANEL, 18 * scale);
    ctx.stroke(panel, null, BORDER, 2 * scale, 18 * scale);
    const x = panel.x + 54 * scale;
    const w = panel.w - 108 * scale;
    ctx.label(.{ .x = x, .y = panel.y + 38 * scale, .w = w, .h = 44 * scale }, panel, "Discovered on this network", TEXT, 30 * scale);
    const discovered = loom.Rect{ .x = x, .y = panel.y + 100 * scale, .w = w, .h = 150 * scale };
    const hot = hovered(discovered);
    ctx.fill(discovered, panel, if (hot) HOT else CARD, 13 * scale);
    ctx.stroke(discovered, panel, if (focus == 0) ACCENT else BORDER, if (focus == 0) 4 * scale else 2 * scale, 13 * scale);
    ctx.fill(.{ .x = discovered.x + 24 * scale, .y = discovered.y + 30 * scale, .w = 74 * scale, .h = 74 * scale }, discovered, ACCENT, 37 * scale);
    ctx.label(.{ .x = discovered.x + 126 * scale, .y = discovered.y + 27 * scale, .w = 650 * scale, .h = 40 * scale }, discovered, "Living Room Jellyfin", TEXT, 29 * scale);
    ctx.label(.{ .x = discovered.x + 126 * scale, .y = discovered.y + 75 * scale, .w = 650 * scale, .h = 34 * scale }, discovered, "http://living-room.local:8096", DIM, 21 * scale);
    ctx.label(.{ .x = discovered.x + discovered.w - 280 * scale, .y = discovered.y + 54 * scale, .w = 220 * scale, .h = 34 * scale }, discovered, "Sample discovery", GREEN, 20 * scale);
    if (hot and pointer_press) {
        focus = 0;
        activate();
    }
    ctx.label(.{ .x = x, .y = panel.y + 292 * scale, .w = w, .h = 35 * scale }, panel, "or enter a server manually", DIM, 22 * scale);
    url_rect = .{ .x = x, .y = panel.y + 370 * scale, .w = w, .h = 72 * scale };
    drawField(ctx, url_rect, "Server URL", .url, 1, scale);
    drawButton(ctx, .{ .x = x, .y = panel.y + 485 * scale, .w = 300 * scale, .h = 72 * scale }, "Continue", 2, scale);
    ctx.label(.{ .x = x, .y = panel.y + 605 * scale, .w = w, .h = 34 * scale }, panel, "Offline demo: no discovery or network request is performed.", GREEN, 21 * scale);
    ctx.label(.{ .x = x, .y = panel.y + 650 * scale, .w = w, .h = 34 * scale }, panel, "On TV, OK opens the native keyboard; USB/Bluetooth keyboards also work.", DIM, 20 * scale);
}

fn drawAuth(ctx: *loom.Context, width: f32, scale: f32) void {
    const panel = loom.Rect{ .x = 430 * scale, .y = 170 * scale, .w = width - 860 * scale, .h = 760 * scale };
    ctx.fill(panel, null, PANEL, 18 * scale);
    ctx.stroke(panel, null, BORDER, 2 * scale, 18 * scale);
    const x = panel.x + 64 * scale;
    const w = panel.w - 128 * scale;
    ctx.label(.{ .x = x, .y = panel.y + 42 * scale, .w = w, .h = 40 * scale }, panel, "Living Room Jellyfin", TEXT, 30 * scale);
    ctx.label(.{ .x = x, .y = panel.y + 88 * scale, .w = w, .h = 32 * scale }, panel, fieldText(.url), DIM, 20 * scale);
    username_rect = .{ .x = x, .y = panel.y + 190 * scale, .w = w, .h = 70 * scale };
    password_rect = .{ .x = x, .y = panel.y + 330 * scale, .w = w, .h = 70 * scale };
    drawField(ctx, username_rect, "Username", .username, 0, scale);
    drawField(ctx, password_rect, "Password", .password, 1, scale);
    drawButton(ctx, .{ .x = x, .y = panel.y + 455 * scale, .w = 280 * scale, .h = 72 * scale }, "Sign in", 2, scale);
    drawButton(ctx, .{ .x = x + 310 * scale, .y = panel.y + 455 * scale, .w = 330 * scale, .h = 72 * scale }, "Quick Connect", 3, scale);
    ctx.label(.{ .x = x, .y = panel.y + 590 * scale, .w = w, .h = 34 * scale }, panel, "Credentials stay in memory and are never sent anywhere.", GREEN, 20 * scale);
}

fn drawQuick(ctx: *loom.Context, width: f32, scale: f32) void {
    const panel = loom.Rect{ .x = 470 * scale, .y = 190 * scale, .w = width - 940 * scale, .h = 690 * scale };
    ctx.fill(panel, null, PANEL, 18 * scale);
    ctx.stroke(panel, null, BORDER, 2 * scale, 18 * scale);
    ctx.label(.{ .x = panel.x + 80 * scale, .y = panel.y + 54 * scale, .w = panel.w - 160 * scale, .h = 42 * scale }, panel, "Enter this code in an authenticated Jellyfin client", TEXT, 26 * scale);
    const code = loom.Rect{ .x = panel.x + 190 * scale, .y = panel.y + 150 * scale, .w = panel.w - 380 * scale, .h = 150 * scale };
    ctx.fill(code, panel, CARD, 15 * scale);
    ctx.stroke(code, panel, ACCENT, 3 * scale, 15 * scale);
    ctx.label(.{ .x = code.x + 94 * scale, .y = code.y + 42 * scale, .w = code.w - 188 * scale, .h = 70 * scale }, code, "NATIVE", ACCENT, 52 * scale);
    ctx.label(.{ .x = panel.x + 80 * scale, .y = panel.y + 345 * scale, .w = panel.w - 160 * scale, .h = 34 * scale }, panel, "This approval is simulated because networking is not implemented.", GREEN, 20 * scale);
    drawButton(ctx, .{ .x = panel.x + 130 * scale, .y = panel.y + 445 * scale, .w = 340 * scale, .h = 72 * scale }, "Simulate approval", 0, scale);
    drawButton(ctx, .{ .x = panel.x + 500 * scale, .y = panel.y + 445 * scale, .w = 220 * scale, .h = 72 * scale }, "Cancel", 1, scale);
}

fn updateEdgeScroll(dt: f32, scale: f32) void {
    if (!cursor_present or !list_rect.contains(cursor_x, cursor_y)) return;
    const zone = 82 * scale;
    const from_top = cursor_y - list_rect.y;
    const from_bottom = list_rect.y + list_rect.h - cursor_y;
    const speed = 950 * scale;
    if (from_top < zone) {
        scroll -= speed * (1 - std.math.clamp(from_top / zone, 0, 1)) * dt;
    } else if (from_bottom < zone) {
        scroll += speed * (1 - std.math.clamp(from_bottom / zone, 0, 1)) * dt;
    }
}

fn drawLibrary(ctx: *loom.Context, width: f32, height: f32, dt: f32, scale: f32) void {
    const margin = 64 * scale;
    item_height = 132 * scale;
    list_rect = .{ .x = margin, .y = 150 * scale, .w = width - margin * 2 - 470 * scale, .h = height - 225 * scale };
    const info = loom.Rect{ .x = list_rect.x + list_rect.w + 30 * scale, .y = list_rect.y, .w = 440 * scale, .h = list_rect.h };
    updateEdgeScroll(@min(dt, 0.05), scale);
    var list = loom.VirtualList.init(list_rect.inset(8 * scale), LIBRARY_COUNT, item_height, scroll);
    scroll = list.scroll;
    // Everything that scrolls is clipped to the list's *content* rect, not to
    // list_rect: the outer rect includes the padding band and the border ring,
    // so clipping to it lets a row paint over its own frame.
    const content = list.viewport;
    ctx.fill(list_rect, null, PANEL, 16 * scale);
    ctx.stroke(list_rect, null, BORDER, 2 * scale, 16 * scale);
    var slot: usize = 0;
    for (list.first..list.last) |index| {
        if (slot == row_labels.len) break;
        const raw = list.itemRect(index);
        const row = loom.Rect{ .x = raw.x + 8 * scale, .y = raw.y + 5 * scale, .w = raw.w - 16 * scale, .h = raw.h - 10 * scale };
        const hot = hovered(row);
        const focused = index == selected;
        ctx.fill(row, content, if (focused) SELECTED else if (hot) HOT else CARD, 11 * scale);
        if (focused) ctx.stroke(row, content, ACCENT, 4 * scale, 11 * scale);
        const art = loom.Rect{ .x = row.x + 10 * scale, .y = row.y + 10 * scale, .w = 160 * scale, .h = row.h - 20 * scale };
        ctx.image(art, content, artworkUv(index), .{ 255, 255, 255, 255 }, 8 * scale);
        const title = std.fmt.bufPrint(&row_labels[slot], "{s}  -  item {d}", .{ media_titles[index % media_titles.len], index + 1 }) catch "Media item";
        row_label_lens[slot] = title.len;
        // Clip to the row so a long title stops at its card, and to the
        // content so a half-scrolled row stops at the list edge. Clipping to
        // the row alone let the last row's text run down over the status bar.
        const row_clip = loom.Rect.intersect(row, content);
        ctx.label(.{ .x = row.x + 194 * scale, .y = row.y + 27 * scale, .w = row.w - 220 * scale, .h = 38 * scale }, row_clip, row_labels[slot][0..row_label_lens[slot]], TEXT, 27 * scale);
        ctx.label(.{ .x = row.x + 194 * scale, .y = row.y + 70 * scale, .w = row.w - 220 * scale, .h = 30 * scale }, row_clip, if (index % 2 == 0) "Movie - 2025 - 2h 08m" else "Series - 3 seasons", DIM, 19 * scale);
        if (hot and pointer_press) {
            selected = index;
            focus = index;
            activate();
        }
        slot += 1;
    }
    const track = loom.Rect{ .x = list_rect.x + list_rect.w - 7 * scale, .y = list_rect.y + 18 * scale, .w = 3 * scale, .h = list_rect.h - 36 * scale };
    const full_h = @as(f32, @floatFromInt(LIBRARY_COUNT)) * item_height;
    const thumb_h = @max(30 * scale, track.h * list.viewport.h / full_h);
    const thumb_y = track.y + (track.h - thumb_h) * (if (list.maxScroll() > 0) scroll / list.maxScroll() else 0);
    ctx.fill(track, list_rect, BORDER, track.w / 2);
    ctx.fill(.{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, list_rect, ACCENT, track.w / 2);
    ctx.fill(info, null, PANEL, 16 * scale);
    ctx.stroke(info, null, BORDER, 2 * scale, 16 * scale);
    const x = info.x + 30 * scale;
    ctx.image(.{ .x = x, .y = info.y + 30 * scale, .w = info.w - 60 * scale, .h = 250 * scale }, info, artworkUv(selected), .{ 255, 255, 255, 255 }, 11 * scale);
    ctx.label(.{ .x = x, .y = info.y + 310 * scale, .w = info.w - 60 * scale, .h = 42 * scale }, info, media_titles[selected % media_titles.len], TEXT, 28 * scale);
    ctx.label(.{ .x = x, .y = info.y + 365 * scale, .w = info.w - 60 * scale, .h = 30 * scale }, info, "OK opens details", ACCENT, 20 * scale);
    ctx.label(.{ .x = x, .y = info.y + 410 * scale, .w = info.w - 60 * scale, .h = 30 * scale }, info, "Hover at either list edge", DIM, 19 * scale);
    ctx.label(.{ .x = x, .y = info.y + 442 * scale, .w = info.w - 60 * scale, .h = 30 * scale }, info, "to scroll continuously.", DIM, 19 * scale);
    ctx.label(.{ .x = x, .y = info.y + info.h - 86 * scale, .w = info.w - 60 * scale, .h = 30 * scale }, info, "1,000 logical items", GREEN, 20 * scale);
}

fn drawDetails(ctx: *loom.Context, width: f32, scale: f32) void {
    const margin = 64 * scale;
    const hero = loom.Rect{ .x = margin, .y = 160 * scale, .w = 780 * scale, .h = 700 * scale };
    ctx.image(.{ .x = hero.x, .y = hero.y, .w = hero.w, .h = 510 * scale }, null, artworkUv(selected), .{ 255, 255, 255, 255 }, 17 * scale);
    const x = hero.x + hero.w + 62 * scale;
    const w = width - x - margin;
    ctx.label(.{ .x = x, .y = 175 * scale, .w = w, .h = 64 * scale }, null, media_titles[selected % media_titles.len], TEXT, 45 * scale);
    ctx.label(.{ .x = x, .y = 250 * scale, .w = w, .h = 34 * scale }, null, "2025   PG-13   2h 08m   4K", GREEN, 21 * scale);
    ctx.label(.{ .x = x, .y = 325 * scale, .w = w, .h = 34 * scale }, null, "Lorem ipsum dolor sit amet, consectetur adipiscing elit.", TEXT, 23 * scale);
    ctx.label(.{ .x = x, .y = 365 * scale, .w = w, .h = 34 * scale }, null, "Sed do eiusmod tempor incididunt ut labore et dolore magna", TEXT, 23 * scale);
    ctx.label(.{ .x = x, .y = 405 * scale, .w = w, .h = 34 * scale }, null, "aliqua. Ut enim ad minim veniam, quis nostrud exercitation", TEXT, 23 * scale);
    ctx.label(.{ .x = x, .y = 445 * scale, .w = w, .h = 34 * scale }, null, "ullamco laboris nisi ut aliquip ex ea commodo consequat.", TEXT, 23 * scale);
    drawButton(ctx, .{ .x = x, .y = 550 * scale, .w = 240 * scale, .h = 74 * scale }, "Play", 0, scale);
    drawButton(ctx, .{ .x = x + 270 * scale, .y = 550 * scale, .w = 240 * scale, .h = 74 * scale }, "Back", 1, scale);
    ctx.label(.{ .x = x, .y = 690 * scale, .w = w, .h = 34 * scale }, null, "Cast: Ada Example, Jules Sample, Morgan Placeholder", DIM, 20 * scale);
    ctx.label(.{ .x = x, .y = 738 * scale, .w = w, .h = 34 * scale }, null, "Offline sample artwork embedded in the executable.", ACCENT, 20 * scale);
}

fn buildUi(ctx: *loom.Context, renderer: *UiRenderer, dt: f32) void {
    const width: f32 = @floatFromInt(gl.width);
    const height: f32 = @floatFromInt(gl.height);
    const scale = @min(width / 1920.0, height / 1080.0);
    ctx.begin(width, height);
    ctx.fill(.{ .w = width, .h = height }, null, BG, 0);
    drawHeader(ctx, width, scale);
    switch (screen) {
        .server => drawServer(ctx, width, scale),
        .auth => drawAuth(ctx, width, scale),
        .quick_connect => drawQuick(ctx, width, scale),
        .library => drawLibrary(ctx, width, height, dt, scale),
        .details => drawDetails(ctx, width, scale),
    }
    drawStatus(ctx, width, height, scale);
    renderer.draw(ctx.commands.items, width, height);
    draw_calls = renderer.batches;
    const screen_px = @as(f64, width) * @as(f64, height);
    overdraw = renderer.covered() / screen_px;
    for (renderer.covered_by_kind, &kind_overdraw) |px, *out| out.* = px / screen_px;
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

/// Capture only this application's rendered backbuffer. PPM keeps the device
/// path dependency-free and is directly readable by ImageMagick and viewers.
fn captureFrame(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const width: usize = gl.width;
    const height: usize = gl.height;
    const rgba = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(rgba);
    const row = try allocator.alloc(u8, width * 3);
    defer allocator.free(row);
    glReadPixels(0, 0, @intCast(width), @intCast(height), GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var header_buffer: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ width, height });
    try file.writeStreamingAll(io, header);
    for (0..height) |output_y| {
        const source_y = height - 1 - output_y;
        const source = rgba[source_y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            row[x * 3 + 0] = source[x * 4 + 0];
            row[x * 3 + 1] = source[x * 4 + 1];
            row[x * 3 + 2] = source[x * 4 + 2];
        }
        try file.writeStreamingAll(io, row);
    }
    std.debug.print("captured OpenGL framebuffer to {s} ({d}x{d})\n", .{ path, width, height });
}

pub fn main(init: std.process.Init) !void {
    setField(.url, "http://jellyfin.local:8096");
    setField(.username, "demo");
    if (std.c.getenv("UI_SCREEN")) |value| {
        const requested = std.mem.sliceTo(value, 0);
        if (std.mem.eql(u8, requested, "auth")) screen = .auth;
        if (std.mem.eql(u8, requested, "quick")) screen = .quick_connect;
        if (std.mem.eql(u8, requested, "library")) screen = .library;
        if (std.mem.eql(u8, requested, "details")) screen = .details;
    }
    wl.on_event = onEvent;
    const appid = std.c.getenv("APPID") orelse @as([*:0]const u8, "dev.hookedbehemoth.uidemo");
    try gl.init(appid, "Jellyfin native UI demo", 0, 0);
    glClearColor = gl.proc(@TypeOf(glClearColor), "glClearColor");
    glClear = gl.proc(@TypeOf(glClear), "glClear");
    glViewport = gl.proc(@TypeOf(glViewport), "glViewport");
    glFinish = gl.proc(@TypeOf(glFinish), "glFinish");
    glGenQueriesEXT = gl.procOpt(@TypeOf(glGenQueriesEXT.?), "glGenQueriesEXT");
    glBeginQueryEXT = gl.procOpt(@TypeOf(glBeginQueryEXT.?), "glBeginQueryEXT");
    glEndQueryEXT = gl.procOpt(@TypeOf(glEndQueryEXT.?), "glEndQueryEXT");
    glGetQueryObjectuivEXT = gl.procOpt(@TypeOf(glGetQueryObjectuivEXT.?), "glGetQueryObjectuivEXT");
    glGetQueryObjectui64vEXT = gl.procOpt(@TypeOf(glGetQueryObjectui64vEXT.?), "glGetQueryObjectui64vEXT");
    glReadPixels = gl.proc(@TypeOf(glReadPixels), "glReadPixels");
    glViewport(0, 0, @intCast(gl.width), @intCast(gl.height));
    glClearColor(9.0 / 255.0, 13.0 / 255.0, 22.0 / 255.0, 1);
    const renderer_start = nowNs();
    var renderer = try UiRenderer.init(init.gpa, init.io, .{ .width = 768, .height = 432, .pixels = @embedFile("media_atlas") });
    defer renderer.deinit();
    std.debug.print("UI renderer init: {d:.2} ms\n", .{@as(f64, @floatFromInt(nowNs() - renderer_start)) / std.time.ns_per_ms});
    var ctx = loom.Context.init(init.gpa);
    defer ctx.deinit();
    std.debug.print("Offline multi-screen UI: {d}x{d}, {d} virtual media rows, batched by texture binding\n", .{ gl.width, gl.height, LIBRARY_COUNT });
    var previous = nowNs();
    var gpu_mode: enum { query, finish } = if (glGenQueriesEXT != null and glBeginQueryEXT != null and glEndQueryEXT != null and glGetQueryObjectuivEXT != null and glGetQueryObjectui64vEXT != null) .query else .finish;
    var queries: [2]u32 = @splat(0);
    if (gpu_mode == .query) glGenQueriesEXT.?(2, &queries);
    var frames: u64 = 0;
    const capture_path = if (std.c.getenv("UI_CAPTURE")) |value| std.mem.sliceTo(value, 0) else "uidemo-capture.ppm";
    var capture_after: u8 = if (std.c.getenv("UI_CAPTURE") != null) 3 else 0;
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
        if (capture_after > 0) {
            capture_after -= 1;
            if (capture_after == 0) capture_requested = true;
        }
        if (capture_requested) {
            captureFrame(init.gpa, init.io, capture_path) catch |err| std.log.err("framebuffer capture failed: {s}", .{@errorName(err)});
            capture_requested = false;
        }
        gl.swap();
        frames += 1;
        cpu_ms = smooth(cpu_ms, @as(f64, @floatFromInt(cpuNs() - cpu_start)) / std.time.ns_per_ms);
        // Same numbers as the header, once a second, because over SSH the
        // header is a picture and during shader experiments it is unreadable.
        if (frames % 60 == 0) std.debug.print("cpu {d:.2} ms  gpu{s}{d:.2} ms  frame {d:.2} ms  {d} draws  {d:.2}x over (fill {d:.2} round {d:.2} border {d:.2} glyph {d:.2} image {d:.2})\n", .{
            cpu_ms,           if (gpu_fallback) "* " else " ", gpu_ms,           frame_ms,
            draw_calls,       overdraw,                        kind_overdraw[0], kind_overdraw[1],
            kind_overdraw[2], kind_overdraw[3],                kind_overdraw[4],
        });
    }
}
