//! Draws a screen that logs every input event, to map the TV remote and the
//! magic-remote cursor.
//!
//! Runs unchanged on the TV (`zig build run -Dapp=inputlog`) and on the dev
//! machine (`zig build run-host -Dapp=inputlog`) -- see src/wl.zig.
//!
//! Discrete events (keys, buttons, wheel, touch) scroll in the log; the cursor
//! is drawn as a crosshair instead, so motion does not flood it. Unknown keys
//! print their raw evdev code, which is the point: press a button, read the
//! number, add it to `key_names`.
//!
//! BACK or ESC quits.
const std = @import("std");
const wl = @import("wl.zig");
const txt = @import("text.zig");

const SCALE = 2;
const CELL_W = txt.GLYPH_W * SCALE;
const CELL_H = txt.GLYPH_H * SCALE;

const BG = 0xFF101018;
const FG = 0xFFE0E0E0;
const DIM = 0xFF808090;
const HL = 0xFF40FF80;
const CURSOR = 0xFFFF4060;

const LINES = 28;
const COLS = 96;

var log_buf: [LINES][COLS]u8 = undefined;
var log_len: [LINES]usize = @splat(0);
var log_next: usize = 0;
var log_count: usize = 0;

var last_mods: [4]u32 = @splat(0);
var cursor_x: i32 = -1;
var cursor_y: i32 = -1;
var cursor_seat: u8 = 0;
var dirty = true;

fn push(comptime fmt: []const u8, args: anytype) void {
    const slot = &log_buf[log_next];
    const s = std.fmt.bufPrint(slot, fmt, args) catch slot[0..COLS];
    log_len[log_next] = s.len;
    std.debug.print("{s}\n", .{s}); // also to the terminal, for `zig build run`
    log_next = (log_next + 1) % LINES;
    if (log_count < LINES) log_count += 1;
    dirty = true;
}

/// Linux evdev keycodes, as delivered by wl_keyboard.key. Only the ones worth
/// reading at a glance; anything else shows as a bare number.
const key_names = [_]struct { u32, []const u8 }{
    .{ 1, "ESC" },           .{ 14, "BACKSPACE" },   .{ 15, "TAB" },
    .{ 28, "ENTER/OK" },     .{ 57, "SPACE" },       .{ 103, "UP" },
    .{ 105, "LEFT" },        .{ 106, "RIGHT" },      .{ 108, "DOWN" },
    .{ 113, "MUTE" },        .{ 114, "VOLUMEDOWN" }, .{ 115, "VOLUMEUP" },
    .{ 116, "POWER" },       .{ 128, "STOP" },       .{ 158, "BACK" },
    .{ 164, "PLAYPAUSE" },   .{ 165, "PREVIOUS" },   .{ 163, "NEXT" },
    .{ 167, "RECORD" },      .{ 168, "REWIND" },     .{ 208, "FASTFORWARD" },
    .{ 172, "HOMEPAGE" },    .{ 174, "EXIT" },       .{ 352, "SELECT" },
    .{ 365, "EPG" },         .{ 370, "SUBTITLE" },   .{ 377, "TV" },
    .{ 385, "RADIO" },       .{ 388, "TEXT" },       .{ 392, "AUDIO" },
    .{ 393, "VIDEO" },       .{ 398, "RED" },        .{ 399, "GREEN" },
    .{ 400, "YELLOW" },      .{ 401, "BLUE" },       .{ 402, "CHANNELUP" },
    .{ 403, "CHANNELDOWN" }, .{ 407, "NEXT" },       .{ 412, "PREVIOUS" },
    .{ 0x160, "OK" },        .{ 0x172, "INFO" },     .{ 0x174, "MENU" },
};

fn keyName(code: u32) []const u8 {
    for (key_names) |e| if (e[0] == code) return e[1];
    return "?";
}

/// wl_pointer button codes are evdev BTN_* values.
fn buttonName(code: u32) []const u8 {
    return switch (code) {
        0x110 => "BTN_LEFT",
        0x111 => "BTN_RIGHT",
        0x112 => "BTN_MIDDLE",
        0x113 => "BTN_SIDE",
        0x114 => "BTN_EXTRA",
        else => "BTN_?",
    };
}

fn onEvent(ev: wl.Event) void {
    switch (ev) {
        .key => |k| {
            push("seat{d} key    code={d:<5} 0x{x:<3} {s:<12} {s}", .{
                k.seat, k.code, k.code, keyName(k.code), if (k.pressed) "DOWN" else "up",
            });
            if (k.pressed and (k.code == 1 or k.code == 158)) wl.running = false;
        },
        .modifiers => |m| {
            // The TV sends a modifiers event on all three seats for every key,
            // almost always all-zero. Only a real change is worth a line.
            const packed_mods = m.depressed | m.latched | m.locked | m.group;
            if (packed_mods == last_mods[m.seat]) return;
            last_mods[m.seat] = packed_mods;
            push("seat{d} mods   depressed=0x{x} latched=0x{x} locked=0x{x} group={d}", .{
                m.seat, m.depressed, m.latched, m.locked, m.group,
            });
        },
        .pointer_enter => |p| {
            cursor_seat = p.seat;
            cursor_x = wl.toInt(p.x);
            cursor_y = wl.toInt(p.y);
            push("seat{d} cursor enter at {d},{d}", .{ p.seat, cursor_x, cursor_y });
        },
        .pointer_leave => |p| {
            cursor_x = -1;
            push("seat{d} cursor leave", .{p.seat});
        },
        .pointer_motion => |p| {
            cursor_seat = p.seat;
            cursor_x = wl.toInt(p.x);
            cursor_y = wl.toInt(p.y);
            dirty = true; // drawn as a crosshair, not logged
        },
        .pointer_button => |p| push("seat{d} button code={d:<5} 0x{x:<3} {s:<12} {s}", .{
            p.seat, p.button, p.button, buttonName(p.button), if (p.pressed) "DOWN" else "up",
        }),
        .pointer_axis => |p| push("seat{d} axis   {s} {d}", .{
            p.seat, if (p.axis == 0) "vertical  " else "horizontal", wl.toInt(p.value),
        }),
        .touch_down => |t| push("seat{d} touch  down id={d} at {d},{d}", .{ t.seat, t.id, wl.toInt(t.x), wl.toInt(t.y) }),
        .touch_up => |t| push("seat{d} touch  up   id={d}", .{ t.seat, t.id }),
        .touch_motion => |t| push("seat{d} touch  move id={d} at {d},{d}", .{ t.seat, t.id, wl.toInt(t.x), wl.toInt(t.y) }),
        .resized => |r| push("window resized to {d}x{d}", .{ r.width, r.height }),
        .close => wl.running = false,
    }
}

// ------------------------------------------------------------------ drawing

fn text(x: u32, y: u32, colour: u32, s: []const u8) void {
    txt.draw(u32, wl.pixels, wl.width, wl.height, x, y, SCALE, colour, s);
}

fn hline(y: u32, colour: u32) void {
    if (y >= wl.height) return;
    @memset(wl.pixels[y * wl.width ..][0..wl.width], colour);
}

fn drawCursor() void {
    if (cursor_x < 0) return;
    const x: u32 = @intCast(std.math.clamp(cursor_x, 0, @as(i32, @intCast(wl.width)) - 1));
    const y: u32 = @intCast(std.math.clamp(cursor_y, 0, @as(i32, @intCast(wl.height)) - 1));
    hline(y, CURSOR);
    for (0..wl.height) |row| wl.pixels[row * wl.width + x] = CURSOR;
}

var status: [COLS]u8 = undefined;

fn draw() void {
    @memset(wl.pixels, BG);
    drawCursor();

    var y: u32 = 4;
    text(8, y, HL, "input event log -- press every remote button; BACK or ESC quits");
    y += CELL_H;
    const s = std.fmt.bufPrint(&status, "{d}x{d}  shell={s}  cursor=", .{
        wl.width, wl.height, if (wl.on_webos) "wl_webos_shell" else "xdg_wm_base",
    }) catch unreachable;
    text(8, y, DIM, s);
    if (cursor_x >= 0) {
        const c2 = std.fmt.bufPrint(status[s.len..], "seat{d} {d},{d}", .{ cursor_seat, cursor_x, cursor_y }) catch unreachable;
        text(8 + @as(u32, @intCast(s.len)) * CELL_W, y, FG, c2);
    } else {
        text(8 + @as(u32, @intCast(s.len)) * CELL_W, y, DIM, "none");
    }
    y += CELL_H + 4;
    hline(y, DIM);
    y += 6;

    // Oldest first, newest at the bottom.
    const start = (log_next + LINES - log_count) % LINES;
    for (0..log_count) |n| {
        const idx = (start + n) % LINES;
        const colour: u32 = if (n + 1 == log_count) HL else FG;
        text(8, y, colour, log_buf[idx][0..log_len[idx]]);
        y += CELL_H;
        if (y + CELL_H > wl.height) break;
    }
}

/// Renders one frame into a plain buffer and prints it as ASCII, so the log
/// formatting and the font can be checked without a compositor:
///   INPUTLOG_DUMP=1 zig build run-host -Dapp=inputlog
fn dump() void {
    var buf: [640 * 120]u32 = undefined;
    wl.width = 640;
    wl.height = 120;
    wl.pixels = &buf;
    onEvent(.{ .key = .{ .seat = 0, .code = 103, .pressed = true } });
    onEvent(.{ .pointer_motion = .{ .seat = 1, .x = 300 << 8, .y = 40 << 8 } });
    draw();
    var y: u32 = 0;
    while (y < wl.height) : (y += 2) {
        var line: [640]u8 = undefined;
        for (0..wl.width) |x| line[x] = if (wl.pixels[y * wl.width + x] == BG) ' ' else '#';
        std.debug.print("{s}\n", .{std.mem.trimEnd(u8, &line, " ")});
    }
}

pub fn main() !void {
    if (std.c.getenv("INPUTLOG_DUMP") != null) return dump();

    wl.on_event = onEvent;
    const appid = std.c.getenv("APPID") orelse @as([*:0]const u8, "dev.hookedbehemoth.inputlog");
    try wl.open(appid, "input event log", 1920, 1080, .shm);
    push("connected: {d}x{d}, {s}", .{ wl.width, wl.height, if (wl.on_webos) "webOS" else "desktop" });

    while (wl.running) {
        if (dirty) {
            dirty = false;
            draw();
            wl.present();
        }
        _ = wl.dispatch();
    }
}
