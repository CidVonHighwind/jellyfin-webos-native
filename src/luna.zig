//! The webOS application lifecycle, over the Luna bus.
//!
//! SAM expects a native app to register and then answer what it is told:
//! `relaunch` when the user opens an app that is already running, `close`
//! when the system wants it gone -- switching apps, reclaiming memory,
//! powering off. An app SAM has no handle on gets signalled instead, which is
//! why this has to work before SDL's signal handling can be left alone.
//!
//! The call goes through `libhelpers.so.2`, the library webOS's own native
//! apps use, because it owns the LS2 handle. What it does *not* own is a main
//! loop: it attaches the subscription to GLib's default context and expects
//! the app to be iterating one. This app never touches GLib otherwise, so it
//! runs a loop of its own on a thread here -- without it the registration
//! succeeds and not one callback ever arrives.
const std = @import("std");
const c = std.c;

const LSHandle = opaque {};
const LSMessage = opaque {};
const GMainLoop = opaque {};
const GMainContext = opaque {};
const Filter = *const fn (?*LSHandle, ?*LSMessage, ?*anyopaque) callconv(.c) bool;

/// include/webos-helpers/libhelpers.h. `unknown` is unnamed there too.
const Context = extern struct {
    callback: ?Filter = null,
    userdata: ?*anyopaque = null,
    unknown: ?*anyopaque = null,
    multiple: c_int = 0,
    is_public: c_int = 0,
    ret_token: c_ulong = 0,
};

var HLunaServiceCall: *const fn ([*:0]const u8, [*:0]const u8, *Context) callconv(.c) c_int = undefined;
var HUnregisterServiceCallback: *const fn (*Context) callconv(.c) c_int = undefined;
var HLunaServiceMessage: *const fn (?*LSMessage) callconv(.c) ?[*:0]const u8 = undefined;
var g_main_loop_new: *const fn (?*GMainContext, c_int) callconv(.c) ?*GMainLoop = undefined;
var g_main_loop_run: *const fn (*GMainLoop) callconv(.c) void = undefined;
var g_main_loop_quit: *const fn (*GMainLoop) callconv(.c) void = undefined;

var helpers: ?*anyopaque = null;
var glib: ?*anyopaque = null;
var context: Context = .{};
var loop: ?*GMainLoop = null;
var loop_thread: ?std.Thread = null;

fn bind(comptime T: type, handle: ?*anyopaque, name: [*:0]const u8) !T {
    return @ptrCast(@alignCast(c.dlsym(handle.?, name) orelse return error.MissingLunaSymbol));
}

/// What to do when the system asks the app to go away, and to come back.
/// Both are called from the GLib thread, so they must be things a foreign
/// thread may do -- `sdl.postQuit` and `sdl.postRaise` are, because
/// SDL_PushEvent is thread-safe.
var quit: *const fn () void = ignore;
var raise: *const fn () void = ignore;
fn ignore() void {}

/// Subscribe to the lifecycle. Fails on anything that is not a webOS device,
/// which is not an error there: nothing is asking the app to close.
pub fn registerLifecycle(on_quit: *const fn () void, on_relaunch: *const fn () void) !void {
    if (helpers != null) return;
    helpers = c.dlopen("libhelpers.so.2", .{ .NOW = true }) orelse
        c.dlopen("libhelpers.so", .{ .NOW = true }) orelse return error.NoLibHelpers;
    glib = c.dlopen("libglib-2.0.so.0", .{ .NOW = true }) orelse return error.NoGlib;
    HLunaServiceCall = try bind(@TypeOf(HLunaServiceCall), helpers, "HLunaServiceCall");
    HUnregisterServiceCallback = try bind(@TypeOf(HUnregisterServiceCallback), helpers, "HUnregisterServiceCallback");
    HLunaServiceMessage = try bind(@TypeOf(HLunaServiceMessage), helpers, "HLunaServiceMessage");
    g_main_loop_new = try bind(@TypeOf(g_main_loop_new), glib, "g_main_loop_new");
    g_main_loop_run = try bind(@TypeOf(g_main_loop_run), glib, "g_main_loop_run");
    g_main_loop_quit = try bind(@TypeOf(g_main_loop_quit), glib, "g_main_loop_quit");
    quit = on_quit;
    raise = on_relaunch;

    // A subscription, so the reply keeps arriving for the life of the app.
    context = .{ .callback = onEvent, .multiple = 1, .is_public = 1 };
    // `registerApp`, because appinfo.json declares
    // `nativeLifeCycleInterfaceVersion: 2`. The older `registerNativeApp` is
    // version 1's method and SAM rejects the mismatch with
    // "trying to register via unmatched method with nativeLifeCycleInterfaceVersion".
    if (HLunaServiceCall("luna://com.webos.service.applicationmanager/registerApp", "{}", &context) != 0)
        return error.LunaRegisterFailed;

    loop = g_main_loop_new(null, 0) orelse return error.NoMainLoop;
    loop_thread = try std.Thread.spawn(.{}, runLoop, .{});
}

fn runLoop() void {
    g_main_loop_run(loop.?);
}

pub fn deinit() void {
    if (helpers == null) return;
    if (context.callback != null) {
        _ = HUnregisterServiceCallback(&context);
        context.callback = null;
    }
    if (loop) |l| g_main_loop_quit(l);
    if (loop_thread) |t| t.join();
    loop_thread = null;
}

fn onEvent(_: ?*LSHandle, message: ?*LSMessage, _: ?*anyopaque) callconv(.c) bool {
    const payload = HLunaServiceMessage(message) orelse return true;
    const text = std.mem.sliceTo(payload, 0);
    if (c.getenv("JF_LUNALOG") != null) std.debug.print("luna: {s}\n", .{text});
    const event = jsonString(text, "event") orelse return true;
    std.debug.print("luna lifecycle: {s}\n", .{event});
    if (std.mem.eql(u8, event, "close")) quit();
    // A minimised app is still running, so opening it from the launcher is a
    // relaunch rather than a start: nothing else will raise the window.
    if (std.mem.eql(u8, event, "relaunch")) raise();
    return true;
}

/// The value of a top-level string key, without pulling in a JSON parser for
/// one field of a payload libhelpers hands over as a flat C string.
fn jsonString(payload: []const u8, key: []const u8) ?[]const u8 {
    var quoted_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{key}) catch return null;
    var at = std.mem.indexOf(u8, payload, quoted) orelse return null;
    at += quoted.len;
    while (at < payload.len and (payload[at] == ' ' or payload[at] == ':')) at += 1;
    if (at >= payload.len or payload[at] != '"') return null; // not a string value
    at += 1;
    const end = std.mem.indexOfScalarPos(u8, payload, at, '"') orelse return null;
    return payload[at..end];
}

test "the event name is read out of a lifecycle payload" {
    try std.testing.expectEqualStrings("close", jsonString(
        "{\"event\":\"close\",\"reason\":\"memoryReclaim\",\"returnValue\":true}",
        "event",
    ).?);
    try std.testing.expectEqualStrings("relaunch", jsonString(
        "{\"returnValue\":true, \"event\": \"relaunch\", \"parameters\":{}}",
        "event",
    ).?);
    // A registration ack carries no event, and a non-string value is not one.
    try std.testing.expect(jsonString("{\"returnValue\":true}", "event") == null);
    try std.testing.expect(jsonString("{\"event\":42}", "event") == null);
    // The key must not be matched inside some other value.
    try std.testing.expect(jsonString("{\"reason\":\"event\"}", "event") == null);
}
