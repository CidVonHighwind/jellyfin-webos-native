//! EGL + OpenGL ES on top of the Wayland shim (src/wl.zig).
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
const wl = @import("wl.zig");

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

/// Open a window and make an ES 3 context current on it.
pub fn init(app_id: [*:0]const u8, title: [*:0]const u8, w: u32, h: u32) !void {
    try wl.open(app_id, title, w, h, .external);
    width = wl.width;
    height = wl.height;

    libs[0] = c.dlopen("libEGL.so.1", .{ .NOW = true }) orelse return error.NoEGL;
    libs[1] = c.dlopen("libGLESv2.so.2", .{ .NOW = true }) orelse return error.NoGLESv2;
    libs[2] = c.dlopen("libwayland-egl.so.1", .{ .NOW = true }) orelse return error.NoWaylandEGL;
    getProcAddress = @ptrCast(@alignCast(symOpt("eglGetProcAddress")));

    eglGetDisplay = proc(@TypeOf(eglGetDisplay), "eglGetDisplay");
    eglInitialize = proc(@TypeOf(eglInitialize), "eglInitialize");
    eglBindAPI = proc(@TypeOf(eglBindAPI), "eglBindAPI");
    eglChooseConfig = proc(@TypeOf(eglChooseConfig), "eglChooseConfig");
    eglCreateWindowSurface = proc(@TypeOf(eglCreateWindowSurface), "eglCreateWindowSurface");
    eglCreateContext = proc(@TypeOf(eglCreateContext), "eglCreateContext");
    eglMakeCurrent = proc(@TypeOf(eglMakeCurrent), "eglMakeCurrent");
    eglSwapBuffers = proc(@TypeOf(eglSwapBuffers), "eglSwapBuffers");
    eglSwapInterval = proc(@TypeOf(eglSwapInterval), "eglSwapInterval");
    eglQueryString = proc(@TypeOf(eglQueryString), "eglQueryString");
    wlEglWindowCreate = proc(@TypeOf(wlEglWindowCreate), "wl_egl_window_create");

    egl_display = eglGetDisplay(wl.display) orelse return error.NoEglDisplay;
    var major: i32 = 0;
    var minor: i32 = 0;
    if (eglInitialize(egl_display, &major, &minor) == 0) return error.EglInitFailed;
    if (eglBindAPI(EGL_OPENGL_ES_API) == 0) return error.EglBindApiFailed;

    const cfg_attrs = [_]i32{
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      16,
        EGL_NONE,
    };
    var config: ?*anyopaque = null;
    var n: i32 = 0;
    if (eglChooseConfig(egl_display, &cfg_attrs, @ptrCast(&config), 1, &n) == 0 or n == 0)
        return error.NoEglConfig;

    const win = wlEglWindowCreate(wl.surface.p, @intCast(width), @intCast(height)) orelse return error.NoEglWindow;
    egl_surface = eglCreateWindowSurface(egl_display, config, win, null) orelse return error.NoEglSurface;

    const ctx_attrs = [_]i32{ EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    egl_context = eglCreateContext(egl_display, config, null, &ctx_attrs) orelse return error.NoEglContext;
    if (eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) == 0) return error.EglMakeCurrentFailed;
    // 1 = throttle to the compositor. SWAP_INTERVAL=0 in the environment lets
    // frames go out as fast as they are drawn, which is what a variable-refresh
    // output wants and also shows what the GPU could actually sustain.
    setSwapInterval(if (c.getenv("SWAP_INTERVAL")) |v| parseInterval(v) else 1);

    std.debug.print("EGL {d}.{d} vendor={s}\n  apis={s}\n", .{
        major,                                                         minor,
        std.mem.sliceTo(eglQueryString(egl_display, EGL_VENDOR).?, 0), std.mem.sliceTo(eglQueryString(egl_display, EGL_CLIENT_APIS).?, 0),
    });
}

pub var swap_interval: i32 = 1;

pub fn setSwapInterval(n: i32) void {
    if (eglSwapInterval(egl_display, n) != 0) swap_interval = n;
}

fn parseInterval(v: [*:0]const u8) i32 {
    return std.fmt.parseInt(i32, std.mem.sliceTo(v, 0), 10) catch 1;
}

pub fn swap() void {
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
