//! OpenGL ES symbol lookup shared by SDL-backed applications.
//!
//! libEGL, libGLESv2 and libwayland-egl are dlopen'd like everything else here,
//! so the build still needs no headers and no sysroot. GL entry points are
//! fetched by name through `proc`, which tries eglGetProcAddress first and
//! falls back to dlsym -- on Mali the core ES functions are real symbols and
//! only extensions come back from eglGetProcAddress.
//!
//! The TV has libGLESv1_CM as well, but nothing here touches fixed-function.
const std = @import("std");
const c = std.c;

pub const EGL_NONE = 0x3038;
const EGL_OPENGL_ES_API = 0x30A0;
const EGL_SURFACE_TYPE = 0x3033;
const EGL_WINDOW_BIT = 0x0004;
const EGL_RENDERABLE_TYPE = 0x3040;
const EGL_OPENGL_ES2_BIT = 0x0004;
const EGL_OPENGL_ES3_BIT = 0x0040;
const EGL_RED_SIZE = 0x3024;
const EGL_GREEN_SIZE = 0x3023;
const EGL_BLUE_SIZE = 0x3022;
const EGL_ALPHA_SIZE = 0x3021;
const EGL_DEPTH_SIZE = 0x3025;
const EGL_CONTEXT_CLIENT_VERSION = 0x3098;
const EGL_VENDOR = 0x3053;
const EGL_VERSION = 0x3054;
const EGL_EXTENSIONS = 0x3055;
const EGL_CLIENT_APIS = 0x308D;

var libs: [3]?*anyopaque = .{ null, null, null };

fn symOpt(name: [*:0]const u8) ?*anyopaque {
    for (libs) |h| if (h) |hh| if (c.dlsym(hh, name)) |p| return p;
    return null;
}

var getProcAddress: ?*const fn ([*:0]const u8) callconv(.c) ?*anyopaque = null;

/// Look up a GL/EGL entry point by name. Returns null if the driver lacks it,
/// which is how optional extensions are probed (see the timer query in gltri).
pub fn procOpt(comptime T: type, name: [*:0]const u8) ?T {
    if (symOpt(name)) |p| return @ptrCast(@alignCast(p));
    if (getProcAddress) |g| if (g(name)) |p| return @ptrCast(@alignCast(p));
    return null;
}

/// Runtime variant used by libraries which resolve GL symbols through a
/// callback instead of a compile-time function type.
pub fn procAddress(name: [*:0]const u8) ?*anyopaque {
    return symOpt(name) orelse if (getProcAddress) |g| g(name) else null;
}
pub fn proc(comptime T: type, name: [*:0]const u8) T {
    return procOpt(T, name) orelse std.debug.panic("missing GL entry point: {s}", .{name});
}

// EGL, only what is needed to get a context.
var eglGetDisplay: *const fn (?*anyopaque) callconv(.c) ?*anyopaque = undefined;
var eglInitialize: *const fn (?*anyopaque, *i32, *i32) callconv(.c) u32 = undefined;
var eglBindAPI: *const fn (u32) callconv(.c) u32 = undefined;
var eglChooseConfig: *const fn (?*anyopaque, [*]const i32, [*]?*anyopaque, i32, *i32) callconv(.c) u32 = undefined;
var eglCreateWindowSurface: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque = undefined;
var eglCreateContext: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, [*]const i32) callconv(.c) ?*anyopaque = undefined;
var eglMakeCurrent: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u32 = undefined;
var eglSwapBuffers: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u32 = undefined;
var eglSwapInterval: *const fn (?*anyopaque, i32) callconv(.c) u32 = undefined;
var eglQueryString: *const fn (?*anyopaque, i32) callconv(.c) ?[*:0]const u8 = undefined;

var wlEglWindowCreate: *const fn (?*anyopaque, i32, i32) callconv(.c) ?*anyopaque = undefined;

pub var egl_display: ?*anyopaque = null;
pub var egl_surface: ?*anyopaque = null;
pub var egl_context: ?*anyopaque = null;
pub var width: u32 = 0;
pub var height: u32 = 0;

/// Take over a window and context made by another platform layer (src/sdl.zig)
/// so that `proc` and `swap` work against it. libGLESv2 is opened directly
/// because on Mali the core ES entry points are real symbols that no
/// GetProcAddress returns.
pub fn adopt(
    get_proc: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    swap_fn: *const fn () void,
    w: u32,
    h: u32,
) void {
    getProcAddress = get_proc;
    swap_hook = swap_fn;
    width = w;
    height = h;
    libs[1] = c.dlopen("libGLESv2.so.2", .{ .NOW = true });
}

var swap_hook: ?*const fn () void = null;

/// Open a window and make an ES 3 context current on it.
pub fn init(app_id: [*:0]const u8, title: [*:0]const u8, w: u32, h: u32) !void {
    _ = .{ app_id, title, w, h };
    return error.SdlRequired;
}

pub var swap_interval: i32 = 1;

pub fn setSwapInterval(n: i32) void {
    if (eglSwapInterval(egl_display, n) != 0) swap_interval = n;
}

fn parseInterval(v: [*:0]const u8) i32 {
    return std.fmt.parseInt(i32, std.mem.sliceTo(v, 0), 10) catch 1;
}

pub fn swap() void {
    if (swap_hook) |f| return f();
    _ = eglSwapBuffers(egl_display, egl_surface);
}

pub fn eglString(what: i32) []const u8 {
    const s = eglQueryString(egl_display, what) orelse return "";
    return std.mem.sliceTo(s, 0);
}
pub const egl_string = struct {
    pub const vendor = EGL_VENDOR;
    pub const version = EGL_VERSION;
    pub const extensions = EGL_EXTENSIONS;
    pub const client_apis = EGL_CLIENT_APIS;
};
