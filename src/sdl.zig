//! The platform layer for the Jellyfin app: window, GL context, input and the
//! webOS on-screen keyboard, all through SDL2.
//!
//! SDL is what makes one binary work across webOS releases: talking Wayland
//! directly means binding `wl_proxy_marshal_flags`, which libwayland-client
//! only grew in 1.20, and the older TVs ship 0.3.0. SDL also carries the
//! webOS-specific pieces -- the exported video window, the Back-key access
//! policy and the on-screen keyboard.
//!
//! Events reach the app as raw **evdev** keycodes; `keymap` below is the whole
//! translation from SDL's scancodes. libSDL2 is dlopen'd like everything else
//! here, so the cross build needs no sysroot.
//!
//! The TV has SDL 2.0.14, so nothing newer than that API may be used.
const std = @import("std");
const c = std.c;
const gl = @import("gl.zig");

// ------------------------------------------------------------- SDL2 ABI

const Window = opaque {};
const GLContext = opaque {};
const Rect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
const DisplayMode = extern struct { format: u32, w: c_int, h: c_int, refresh_rate: c_int, driverdata: ?*anyopaque };

const init_video = 0x20;
const window_opengl = 0x2;
const window_shown = 0x4;
const window_resizable = 0x20;
const window_fullscreen_desktop = 0x1001;
const windowpos_undefined = 0x1FFF0000;

const attr_alpha_size = 3;
const attr_depth_size = 6;
const attr_context_major = 17;
const attr_context_minor = 18;
const attr_context_profile = 21;
const profile_es = 0x4;

/// SDL_Event is a 56-byte union; every variant below is a prefix of it.
const Event = extern struct { kind: u32, rest: [52]u8 };
// Keyboard and text events carry an extra 4-byte `inputSource` after
// `windowID` on the webOS fork -- its own header guards the field with
// `SDL_WEBOS_BROKEN_ABI`, and the name is deserved. Everything after it
// shifts, so those two events are read by offset instead of as a struct.
// Mouse and window events are not affected.
const body_offset = 12;
/// 4 on the webOS fork, 0 everywhere else. Confirmed against the first key
/// event rather than assumed; see `readKey`.
var abi_shift: usize = 0;

const Key = struct { state: u8, repeat: u8, scancode: c_int, sym: i32 };

fn field(comptime T: type, event: *const Event, offset: usize) T {
    const bytes: [*]const u8 = @ptrCast(event);
    return @as(*align(1) const T, @ptrCast(bytes + offset)).*;
}

fn readKeyAt(event: *const Event, shift: usize) Key {
    const base = body_offset + shift;
    return .{
        .state = field(u8, event, base),
        .repeat = field(u8, event, base + 1),
        .scancode = field(c_int, event, base + 4),
        .sym = field(i32, event, base + 8),
    };
}

/// `state` is 1 for a key-down and 0 for a key-up, which we already know from
/// the event type -- so the layout can be established from the data instead of
/// trusted. Checked once, on the first key event.
var abi_checked = false;
fn readKey(event: *const Event, down: bool) Key {
    const expected: u8 = if (down) 1 else 0;
    if (!abi_checked) {
        abi_checked = true;
        if (readKeyAt(event, abi_shift).state != expected) {
            const other: usize = if (abi_shift == 0) 4 else 0;
            if (readKeyAt(event, other).state == expected) {
                std.debug.print("sdl: keyboard event layout is shift={d}, not {d}\n", .{ other, abi_shift });
                abi_shift = other;
            }
        }
    }
    return readKeyAt(event, abi_shift);
}
const MouseMotionEvent = extern struct {
    kind: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    state: u32,
    x: i32,
    y: i32,
    xrel: i32,
    yrel: i32,
};
const MouseButtonEvent = extern struct {
    kind: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    button: u8,
    state: u8,
    clicks: u8,
    padding: u8,
    x: i32,
    y: i32,
};
const MouseWheelEvent = extern struct {
    kind: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    x: i32,
    y: i32,
    direction: u32,
};

const WindowEvent = extern struct {
    kind: u32,
    timestamp: u32,
    window_id: u32,
    event: u8,
    padding: [3]u8,
    data1: i32,
    data2: i32,
};

const ev_quit = 0x100;
const ev_window = 0x200;
const ev_keydown = 0x300;
const ev_keyup = 0x301;
const ev_textinput = 0x303;
const ev_mousemotion = 0x400;
const ev_mousebuttondown = 0x401;
const ev_mousebuttonup = 0x402;
const ev_mousewheel = 0x403;

const win_resized = 5;
const win_size_changed = 6;
const win_leave = 11;
const win_close = 14;

var SDL_Init: *const fn (u32) callconv(.c) c_int = undefined;
var SDL_Quit: *const fn () callconv(.c) void = undefined;
var SDL_GetError: *const fn () callconv(.c) [*:0]const u8 = undefined;
var SDL_SetHint: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int = undefined;
var SDL_GetCurrentVideoDriver: *const fn () callconv(.c) ?[*:0]const u8 = undefined;
var SDL_CreateWindow: *const fn ([*:0]const u8, c_int, c_int, c_int, c_int, u32) callconv(.c) ?*Window = undefined;
var SDL_GetWindowSize: *const fn (*Window, *c_int, *c_int) callconv(.c) void = undefined;
var SDL_GL_GetDrawableSize: *const fn (*Window, *c_int, *c_int) callconv(.c) void = undefined;
var SDL_webOSGetPanelResolution: ?*const fn (*c_int, *c_int) callconv(.c) c_int = null;
var SDL_GetCurrentDisplayMode: *const fn (c_int, *DisplayMode) callconv(.c) c_int = undefined;
var SDL_GL_SetAttribute: *const fn (c_int, c_int) callconv(.c) c_int = undefined;
var SDL_GL_CreateContext: *const fn (*Window) callconv(.c) ?*GLContext = undefined;
var SDL_GL_GetProcAddress: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque = undefined;
var SDL_GL_SwapWindow: *const fn (*Window) callconv(.c) void = undefined;
var SDL_GL_SetSwapInterval: *const fn (c_int) callconv(.c) c_int = undefined;
var SDL_PollEvent: *const fn (*Event) callconv(.c) c_int = undefined;
var SDL_PushEvent: *const fn (*Event) callconv(.c) c_int = undefined;
var SDL_StartTextInput: *const fn () callconv(.c) void = undefined;
var SDL_StopTextInput: *const fn () callconv(.c) void = undefined;
var SDL_SetTextInputRect: *const fn (*Rect) callconv(.c) void = undefined;
/// webOS only; resolved lazily because the desktop build has neither.
var SDL_webOSCreateExportedWindow: ?*const fn (c_int) callconv(.c) ?[*:0]const u8 = null;
var SDL_webOSSetExportedWindow: ?*const fn ([*:0]const u8, *Rect, *Rect) callconv(.c) c_int = null;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

var lib: ?*anyopaque = null;

fn bind(comptime T: type, name: [*:0]const u8) !T {
    return @ptrCast(@alignCast(c.dlsym(lib.?, name) orelse return error.MissingSdlSymbol));
}
fn bindOpt(comptime T: type, name: [*:0]const u8) ?T {
    return @ptrCast(@alignCast(c.dlsym(lib.?, name) orelse return null));
}

// --------------------------------------------------------- app-facing API
//
// Same shape as src/wl.zig, so the app sees no difference.

pub const Fixed = i32;
pub fn toInt(f: Fixed) i32 {
    return f >> 8;
}
fn fixed(v: i32) Fixed {
    return v << 8;
}
/// Window units to framebuffer pixels; 1.0 unless SDL and GL disagree.
var pointer_scale_x: f32 = 1;
var pointer_scale_y: f32 = 1;
fn pointerX(v: i32) Fixed {
    return fixed(@intFromFloat(@as(f32, @floatFromInt(v)) * pointer_scale_x));
}
fn pointerY(v: i32) Fixed {
    return fixed(@intFromFloat(@as(f32, @floatFromInt(v)) * pointer_scale_y));
}

pub const AppEvent = union(enum) {
    /// Raw evdev keycode (no XKB +8 offset), as the Wayland shim reported.
    key: struct { seat: u8, code: u32, pressed: bool },
    pointer_enter: struct { seat: u8, x: Fixed, y: Fixed },
    pointer_leave: struct { seat: u8 },
    pointer_motion: struct { seat: u8, x: Fixed, y: Fixed },
    pointer_button: struct { seat: u8, button: u32, pressed: bool },
    pointer_axis: struct { seat: u8, axis: u32, value: Fixed },
    /// Text committed by a keyboard or by the webOS on-screen keyboard.
    text_commit: []const u8,
    resized: struct { width: u32, height: u32 },
    close,
};

pub var on_event: *const fn (AppEvent) void = ignoreEvent;
fn ignoreEvent(_: AppEvent) void {}

pub var running = true;
/// True on the TV, where SDL drives its own webOS video backend.
pub var on_webos = false;

/// LG's keycodes/lg maps IR_KEY_BACK to XKB 420, i.e. Wayland key 412. On
/// desktops 412 is KEY_PREVIOUS, so only treat it as Back on the TV.
pub fn isBackKey(code: u32) bool {
    return code == 1 or code == 158 or (on_webos and code == 412);
}

var window: ?*Window = null;
var context: ?*GLContext = null;

/// Open the window, make an ES 3 context current on it and hand the GL entry
/// points to gl.zig, which the renderer keeps using unchanged.
pub fn init(app_id: [*:0]const u8, title: [*:0]const u8, w: u32, h: u32) !void {
    lib = c.dlopen("libSDL2-2.0.so.0", .{ .NOW = true }) orelse return error.NoSdl2;
    SDL_Init = try bind(@TypeOf(SDL_Init), "SDL_Init");
    SDL_Quit = try bind(@TypeOf(SDL_Quit), "SDL_Quit");
    SDL_GetError = try bind(@TypeOf(SDL_GetError), "SDL_GetError");
    SDL_SetHint = try bind(@TypeOf(SDL_SetHint), "SDL_SetHint");
    SDL_GetCurrentVideoDriver = try bind(@TypeOf(SDL_GetCurrentVideoDriver), "SDL_GetCurrentVideoDriver");
    SDL_CreateWindow = try bind(@TypeOf(SDL_CreateWindow), "SDL_CreateWindow");
    SDL_GetWindowSize = try bind(@TypeOf(SDL_GetWindowSize), "SDL_GetWindowSize");
    SDL_GL_GetDrawableSize = try bind(@TypeOf(SDL_GL_GetDrawableSize), "SDL_GL_GetDrawableSize");
    SDL_GetCurrentDisplayMode = try bind(@TypeOf(SDL_GetCurrentDisplayMode), "SDL_GetCurrentDisplayMode");
    SDL_GL_SetAttribute = try bind(@TypeOf(SDL_GL_SetAttribute), "SDL_GL_SetAttribute");
    SDL_GL_CreateContext = try bind(@TypeOf(SDL_GL_CreateContext), "SDL_GL_CreateContext");
    SDL_GL_GetProcAddress = try bind(@TypeOf(SDL_GL_GetProcAddress), "SDL_GL_GetProcAddress");
    SDL_GL_SwapWindow = try bind(@TypeOf(SDL_GL_SwapWindow), "SDL_GL_SwapWindow");
    SDL_GL_SetSwapInterval = try bind(@TypeOf(SDL_GL_SetSwapInterval), "SDL_GL_SetSwapInterval");
    SDL_PollEvent = try bind(@TypeOf(SDL_PollEvent), "SDL_PollEvent");
    SDL_PushEvent = try bind(@TypeOf(SDL_PushEvent), "SDL_PushEvent");
    SDL_StartTextInput = try bind(@TypeOf(SDL_StartTextInput), "SDL_StartTextInput");
    SDL_StopTextInput = try bind(@TypeOf(SDL_StopTextInput), "SDL_StopTextInput");
    SDL_SetTextInputRect = try bind(@TypeOf(SDL_SetTextInputRect), "SDL_SetTextInputRect");
    SDL_webOSGetPanelResolution = bindOpt(@TypeOf(SDL_webOSGetPanelResolution.?), "SDL_webOSGetPanelResolution");
    SDL_webOSCreateExportedWindow = bindOpt(@TypeOf(SDL_webOSCreateExportedWindow.?), "SDL_webOSCreateExportedWindow");
    SDL_webOSSetExportedWindow = bindOpt(@TypeOf(SDL_webOSSetExportedWindow.?), "SDL_webOSSetExportedWindow");

    // The webOS backend registers the app on the Luna bus as part of deciding
    // whether it is available at all, and it takes the id from the environment
    // rather than from a hint. Without it the registration fails with "Invalid
    // appId specified", SDL reports the backend as unavailable and falls back
    // to plain wayland -- where the remote has no keymap and every button
    // arrives as scancode 1. Whatever SAM set wins.
    _ = setenv("APPID", app_id, 0);
    _ = SDL_SetHint("SDL_WEBOS_REGISTER_APP", "true");
    // No exit dialog
    _ = SDL_SetHint("SDL_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
    // This SDL reports its backend as `wayland` on the TV as well -- the webOS
    // support lives inside that backend rather than in a separate one, and
    // asking for a "webOS" driver by name only gets "webOS not available".
    // What actually distinguishes a webOS build is that it exports the
    // webOS-only entry points, so that is what we test.
    on_webos = SDL_webOSCreateExportedWindow != null;
    abi_shift = if (on_webos) 4 else 0;
    if (SDL_Init(init_video) != 0) {
        std.debug.print("SDL_Init: {s}\n", .{std.mem.sliceTo(SDL_GetError(), 0)});
        return error.SdlInitFailed;
    }

    _ = SDL_GL_SetAttribute(attr_context_profile, profile_es);
    _ = SDL_GL_SetAttribute(attr_context_major, 3);
    _ = SDL_GL_SetAttribute(attr_context_minor, 0);
    _ = SDL_GL_SetAttribute(attr_depth_size, 16);
    // The TV's video plane shows through wherever the UI writes alpha 0.
    _ = SDL_GL_SetAttribute(attr_alpha_size, 8);

    // The TV is always fullscreen and managed by LSM; a desktop gets a normal
    // resizable window, 720p unless the caller asked for a size.
    const sized: u32 = if (on_webos) window_fullscreen_desktop else window_resizable;
    const flags: u32 = window_opengl | window_shown | sized;
    // Fullscreen-desktop resizes the window but not the GL surface underneath
    // it, so a window asked for at some convenient default keeps that surface
    // for its whole life while SDL reports the display's size -- which is a
    // viewport 1.5x too large and pointer coordinates in a space of their own.
    // Ask for the display's size up front instead.
    var mode: DisplayMode = undefined;
    const display_ok = SDL_GetCurrentDisplayMode(0, &mode) == 0 and mode.w > 0 and mode.h > 0;
    const want_w: c_int = if (w != 0) @intCast(w) else if (display_ok) mode.w else 1280;
    const want_h: c_int = if (h != 0) @intCast(h) else if (display_ok) mode.h else 720;
    const win = SDL_CreateWindow(
        title,
        windowpos_undefined,
        windowpos_undefined,
        want_w,
        want_h,
        flags,
    ) orelse {
        std.debug.print("SDL_CreateWindow: {s}\n", .{std.mem.sliceTo(SDL_GetError(), 0)});
        return error.SdlWindowFailed;
    };
    window = win;
    context = SDL_GL_CreateContext(win) orelse {
        std.debug.print("SDL_GL_CreateContext: {s}\n", .{std.mem.sliceTo(SDL_GetError(), 0)});
        return error.SdlContextFailed;
    };
    // 1 = throttle to the display. SWAP_INTERVAL=0 lets frames go out as fast
    // as they are drawn, which is what shows the GPU's real ceiling.
    _ = SDL_GL_SetSwapInterval(if (c.getenv("SWAP_INTERVAL")) |v|
        std.fmt.parseInt(c_int, std.mem.sliceTo(v, 0), 10) catch 1
    else
        1);

    // Everything above the platform layer works in framebuffer pixels, so the
    // drawable size is the one that matters -- the window size is in logical
    // units and the two differ wherever the compositor applies a scale.
    var lw: c_int = 0;
    var lh: c_int = 0;
    SDL_GetWindowSize(win, &lw, &lh);
    var pw: c_int = 0;
    var ph: c_int = 0;
    SDL_GL_GetDrawableSize(win, &pw, &ph);
    gl.adopt(SDL_GL_GetProcAddress, swap, @intCast(pw), @intCast(ph));
    // ...and if SDL still disagrees with GL, GL wins: it is the buffer the
    // pixels land in. Pointer coordinates arrive in window space, so remember
    // the ratio and scale them.
    var viewport_early: [4]i32 = @splat(0);
    if (gl.procOpt(*const fn (u32, [*]i32) callconv(.c) void, "glGetIntegerv")) |getIntegerv| {
        getIntegerv(0x0BA2, &viewport_early);
        if (viewport_early[2] > 0 and viewport_early[3] > 0) {
            gl.width = @intCast(viewport_early[2]);
            gl.height = @intCast(viewport_early[3]);
        }
    }
    SDL_GetWindowSize(win, &lw, &lh);
    pointer_scale_x = if (lw > 0) @as(f32, @floatFromInt(gl.width)) / @as(f32, @floatFromInt(lw)) else 1;
    pointer_scale_y = if (lh > 0) @as(f32, @floatFromInt(gl.height)) / @as(f32, @floatFromInt(lh)) else 1;
    var panel_w: c_int = 0;
    var panel_h: c_int = 0;
    if (SDL_webOSGetPanelResolution) |panel| _ = panel(&panel_w, &panel_h);
    std.debug.print("SDL video driver={s} window={d}x{d} drawable={d}x{d} gl_viewport={d}x{d} panel={d}x{d}\n", .{
        if (SDL_GetCurrentVideoDriver()) |d| std.mem.sliceTo(d, 0) else "?",
        lw,
        lh,
        pw,
        ph,
        gl.width,
        gl.height,
        panel_w,
        panel_h,
    });
}

fn swap() void {
    if (window) |win| SDL_GL_SwapWindow(win);
}

pub fn deinit() void {
    if (lib != null) SDL_Quit();
}

// ------------------------------------------------------------- key mapping
//
// SDL reports USB-HID scancodes; the app speaks evdev. Only the keys it acts
// on are here -- letters and digits are deliberately absent, because their
// text arrives as SDL_TEXTINPUT instead, already shifted, capsed and in the
// user's own layout.

const KeyMap = struct { scancode: c_int, evdev: u32 };
const keymap = [_]KeyMap{
    .{ .scancode = 40, .evdev = 28 }, // Return
    .{ .scancode = 41, .evdev = 1 }, // Escape
    .{ .scancode = 42, .evdev = 14 }, // Backspace
    .{ .scancode = 43, .evdev = 15 }, // Tab
    .{ .scancode = 44, .evdev = 57 }, // Space
    .{ .scancode = 58, .evdev = 59 }, // F1
    .{ .scancode = 59, .evdev = 60 }, // F2
    .{ .scancode = 60, .evdev = 61 }, // F3
    .{ .scancode = 61, .evdev = 62 }, // F4
    .{ .scancode = 66, .evdev = 67 }, // F9  -- sign out
    .{ .scancode = 69, .evdev = 88 }, // F12 -- screenshot
    .{ .scancode = 79, .evdev = 106 }, // Right
    .{ .scancode = 80, .evdev = 105 }, // Left
    .{ .scancode = 81, .evdev = 108 }, // Down
    .{ .scancode = 82, .evdev = 103 }, // Up
    .{ .scancode = 88, .evdev = 96 }, // Keypad Enter
    .{ .scancode = 270, .evdev = 158 }, // AC_BACK
    // The webOS remote, from SDL's own scancode block. The colour buttons are
    // the TV's only spare inputs, so Blue keeps doing what F9 does.
    .{ .scancode = 482, .evdev = 158 }, // WEBOS_BACK
    .{ .scancode = 486, .evdev = 64 }, // WEBOS_RED    -> F6
    .{ .scancode = 487, .evdev = 65 }, // WEBOS_GREEN  -> F7
    .{ .scancode = 488, .evdev = 66 }, // WEBOS_YELLOW -> F8
    .{ .scancode = 489, .evdev = 67 }, // WEBOS_BLUE   -> F9
};
/// Sent as keys by the webOS backend when the magic remote's pointer appears
/// and disappears.
const scancode_cursor_show = 484;
const scancode_cursor_hide = 485;

fn evdevFor(scancode: c_int) ?u32 {
    for (keymap) |entry| if (entry.scancode == scancode) return entry.evdev;
    return null;
}

// ------------------------------------------------------------- event pump

/// Ask the main loop to stop, from any thread. SDL_PushEvent is the one part
/// of SDL safe to call off the main thread, which is what lets the webOS
/// lifecycle callback (src/luna.zig) end the app.
pub fn postQuit() void {
    if (lib == null) return;
    var event: Event = undefined;
    const bytes: [*]u8 = @ptrCast(&event);
    @memset(bytes[0..@sizeOf(Event)], 0);
    event.kind = ev_quit;
    _ = SDL_PushEvent(&event);
}

/// Drain SDL's queue into the app's handler. Returns false once the app should
/// stop, which is what the main loop runs on.
pub fn poll() bool {
    var event: Event = undefined;
    while (SDL_PollEvent(&event) != 0) translate(&event);
    return running;
}

fn translate(event: *const Event) void {
    switch (event.kind) {
        ev_quit => {
            running = false;
            on_event(.close);
        },
        ev_keydown, ev_keyup => {
            const key = readKey(event, event.kind == ev_keydown);
            // Auto-repeat drives held-down navigation, so it is not filtered.
            switch (key.scancode) {
                scancode_cursor_hide => on_event(.{ .pointer_leave = .{ .seat = 0 } }),
                scancode_cursor_show => {},
                else => {
                    // JF_KEYLOG=1 shows every key SDL reports, which is the
                    // only way to learn what a TV remote actually sends.
                    if (std.c.getenv("JF_KEYLOG") != null or evdevFor(key.scancode) == null)
                        std.debug.print("sdl: key scancode={d} sym=0x{x} down={} repeat={d}\n", .{
                            key.scancode, key.sym, event.kind == ev_keydown, key.repeat,
                        });
                    if (evdevFor(key.scancode)) |code|
                        on_event(.{ .key = .{ .seat = 0, .code = code, .pressed = event.kind == ev_keydown } });
                },
            }
        },
        ev_textinput => {
            // Same shifted body as the key events.
            const bytes: [*]const u8 = @ptrCast(event);
            const text: [*:0]const u8 = @ptrCast(bytes + body_offset + abi_shift);
            on_event(.{ .text_commit = std.mem.sliceTo(text, 0) });
        },
        ev_mousemotion => {
            const motion: *const MouseMotionEvent = @ptrCast(event);
            on_event(.{ .pointer_motion = .{ .seat = 0, .x = pointerX(motion.x), .y = pointerY(motion.y) } });
        },
        ev_mousebuttondown, ev_mousebuttonup => {
            const button: *const MouseButtonEvent = @ptrCast(event);
            // SDL numbers buttons from 1; the app speaks evdev BTN_LEFT.
            if (button.button != 1) return;
            on_event(.{ .pointer_button = .{
                .seat = 0,
                .button = 0x110,
                .pressed = event.kind == ev_mousebuttondown,
            } });
        },
        ev_mousewheel => {
            const wheel: *const MouseWheelEvent = @ptrCast(event);
            // SDL counts notches and points up; Wayland reports a length and
            // points down. Ten surface units per notch is what the compositors
            // this was written against send, so the app's feel is unchanged.
            if (wheel.y != 0) on_event(.{ .pointer_axis = .{ .seat = 0, .axis = 0, .value = fixed(-wheel.y * 10) } });
        },
        ev_window => {
            const w: *const WindowEvent = @ptrCast(event);
            switch (w.event) {
                win_resized, win_size_changed => {
                    var pw: c_int = 0;
                    var ph: c_int = 0;
                    if (window) |win| SDL_GL_GetDrawableSize(win, &pw, &ph);
                    gl.width = @intCast(@max(0, pw));
                    gl.height = @intCast(@max(0, ph));
                    on_event(.{ .resized = .{ .width = gl.width, .height = gl.height } });
                },
                win_leave => on_event(.{ .pointer_leave = .{ .seat = 0 } }),
                win_close => {
                    running = false;
                    on_event(.close);
                },
                else => {},
            }
        },
        else => {},
    }
}

// -------------------------------------------------------------- text input

pub const TextPurpose = enum(u32) { normal = 0, url = 5, password = 8 };

/// Show the TV's on-screen keyboard, or just enable SDL_TEXTINPUT on a
/// desktop. SDL 2.0.14 has no way to seed the field with existing text, so
/// editing starts from what the app already holds and appends.
pub fn beginTextInput(_: [:0]const u8, rect: [4]i32, _: TextPurpose) bool {
    if (lib == null) return false;
    var box = Rect{ .x = rect[0], .y = rect[1], .w = rect[2], .h = rect[3] };
    SDL_SetTextInputRect(&box);
    SDL_StartTextInput();
    return true;
}
/// The OSK owns its own buffer; nothing to push back into it.
pub fn updateTextInput(_: [:0]const u8) void {}
pub fn endTextInput() void {
    if (lib != null) SDL_StopTextInput();
}

// ----------------------------------------------------- exported video plane

/// Hand back a webOS window id for the hardware video plane, positioned by
/// `src` and `dst` as {x, y, w, h}. This is what mpv's vo_starfish takes as
/// `--vo-starfish-window-id`, and it is the whole reason the video never has
/// to pass through this process.
pub fn exportVideoWindow(src: [4]i32, dst: [4]i32) ![*:0]const u8 {
    // These reach straight into the webOS backend's own driver data, so under
    // any other backend they are a crash, not a failed call.
    if (!on_webos) return error.NoWebosExportedWindow;
    const create = SDL_webOSCreateExportedWindow orelse return error.NoWebosExportedWindow;
    const window_id = create(0) orelse return error.NoWindowId; // 0 = VIDEO
    if (SDL_webOSSetExportedWindow) |place| {
        var src_rect = Rect{ .x = src[0], .y = src[1], .w = src[2], .h = src[3] };
        var dst_rect = Rect{ .x = dst[0], .y = dst[1], .w = dst[2], .h = dst[3] };
        _ = place(window_id, &src_rect, &dst_rect);
    }
    return window_id;
}

test "scancodes map to the evdev codes the app navigates with" {
    try std.testing.expectEqual(@as(?u32, 103), evdevFor(82)); // Up
    try std.testing.expectEqual(@as(?u32, 158), evdevFor(482)); // webOS Back
    try std.testing.expectEqual(@as(?u32, 67), evdevFor(489)); // webOS Blue
    // Letters must NOT map, or every keystroke would be appended twice: once
    // from the key event and once from SDL_TEXTINPUT.
    try std.testing.expectEqual(@as(?u32, null), evdevFor(4)); // 'a'
    try std.testing.expectEqual(@as(?u32, null), evdevFor(30)); // '1'
}

test "SDL_Event variants stay inside the 56-byte union" {
    inline for (.{ Event, MouseMotionEvent, MouseButtonEvent, MouseWheelEvent, WindowEvent }) |T| {
        try std.testing.expect(@sizeOf(T) <= 56);
    }
    // Mouse and window events keep the upstream layout.
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(MouseMotionEvent, "x"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(MouseButtonEvent, "button"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(MouseWheelEvent, "x"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(WindowEvent, "event"));
}

test "the webOS keyboard ABI shift is found from the event itself" {
    // A key-down of SDL_SCANCODE_WEBOS_BACK as the webOS fork lays it out:
    // type, timestamp, windowID, inputSource, then state/repeat and the keysym.
    var event: Event = undefined;
    const bytes: [*]u8 = @ptrCast(&event);
    @memset(bytes[0..56], 0);
    event.kind = ev_keydown;
    bytes[16] = 1; // state, four bytes later than upstream
    @as(*align(1) c_int, @ptrCast(bytes + 20)).* = 482;
    @as(*align(1) i32, @ptrCast(bytes + 24)).* = 0;

    abi_shift = 0; // start from the upstream guess and let it correct itself
    abi_checked = false;
    const key = readKey(&event, true);
    try std.testing.expectEqual(@as(usize, 4), abi_shift);
    try std.testing.expectEqual(@as(c_int, 482), key.scancode);
    try std.testing.expectEqual(@as(u8, 1), key.state);
    // 482 is the remote's Back, which the app sees as evdev KEY_BACK.
    try std.testing.expectEqual(@as(?u32, 158), evdevFor(key.scancode));
}
