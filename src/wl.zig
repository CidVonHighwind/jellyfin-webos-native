//! Minimal Wayland shim shared by the native apps: one window, one shm buffer,
//! all input events.
//!
//! Works on both targets with the same code:
//!   * webOS TV  -- `wl_webos_shell`, fullscreen, appId set as a shell property.
//!   * a desktop -- `xdg_wm_base`, a normal resizable toplevel.
//! The shell is picked from whatever the compositor advertises, so
//! `zig build run` on the TV and running the host binary locally are the same
//! program. Develop on the PC, deploy to the TV.
//!
//! libwayland-client (and libwayland-webos-client, when present) are dlopen'd,
//! so the build needs no headers, no sysroot and no .so on the build machine.
//! Request opcodes are looked up BY NAME in the wl_interface method tables the
//! libraries already carry -- nothing is hardcoded from a protocol XML.
//!
//! xdg-shell is the exception: it lives in generated code, not in any .so, so
//! its three interfaces are spelled out below. That is the only place where
//! wire order is taken on trust.
const std = @import("std");
const linux = std.os.linux;
const c = std.c;

// ---------------------------------------------------------------- libwayland

pub const Message = extern struct { name: [*:0]const u8, signature: [*:0]const u8, types: ?*const anyopaque };
pub const Interface = extern struct {
    name: [*:0]const u8,
    version: i32,
    method_count: i32,
    methods: ?[*]const Message,
    event_count: i32,
    events: ?[*]const Message,
};

var libs: [2]?*anyopaque = .{ null, null };

fn symOpt(name: [*:0]const u8) ?*anyopaque {
    for (libs) |h| if (h) |hh| if (c.dlsym(hh, name)) |p| return p;
    return null;
}
fn sym(name: [*:0]const u8) *anyopaque {
    return symOpt(name) orelse std.debug.panic("missing symbol: {s}", .{name});
}
fn fnPtr(comptime T: type, name: [*:0]const u8) T {
    return @ptrCast(@alignCast(sym(name)));
}
/// The `wl_*_interface` symbol libwayland already exports for a protocol object.
pub fn iface(name: [*:0]const u8) *const Interface {
    return @ptrCast(@alignCast(sym(name)));
}

/// Find a request's opcode by name in the interface's own method table.
/// Beats trusting a protocol XML we'd have to remember: `get_shell_surface`
/// is opcode 1, not 0, and that cost an afternoon once.
pub fn opcode(i: *const Interface, name: []const u8) u32 {
    const methods = i.methods orelse std.debug.panic("{s}: no method table", .{i.name});
    for (0..@intCast(i.method_count)) |n| {
        if (std.mem.eql(u8, std.mem.sliceTo(methods[n].name, 0), name)) return @intCast(n);
    }
    std.debug.panic("{s}: no request named '{s}'", .{ i.name, name });
}

/// wl_proxy_marshal_flags is variadic, but every argument any of these requests
/// takes is word-sized (u32/i32/pointer). For those the ARM and x86-64 variadic
/// and fixed calling conventions agree, so a fixed-arity prototype built from
/// the argument tuple is ABI-safe.
fn MarshalFn(comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    const head = [_]type{ ?*anyopaque, u32, ?*const Interface, u32, u32 };
    comptime var params: [head.len + fields.len]type = undefined;
    params[0..head.len].* = head;
    inline for (fields, head.len..) |f, i| params[i] = f.type;
    const attrs: [params.len]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
    return *const @Fn(&params, &attrs, ?*anyopaque, .{ .@"callconv" = .c });
}

var marshal_raw: *anyopaque = undefined;
var getVersion: *const fn (?*anyopaque) callconv(.c) u32 = undefined;
var addListener: *const fn (?*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) i32 = undefined;
var dispatchFn: *const fn (?*anyopaque) callconv(.c) i32 = undefined;
var roundtripFn: *const fn (?*anyopaque) callconv(.c) i32 = undefined;
var dispatchPendingFn: *const fn (?*anyopaque) callconv(.c) i32 = undefined;
var flushFn: *const fn (?*anyopaque) callconv(.c) i32 = undefined;

/// A bound protocol object plus the interface it speaks, so requests can be
/// named instead of numbered.
pub const Proxy = struct {
    p: ?*anyopaque = null,
    i: *const Interface = undefined,

    pub fn ok(self: Proxy) bool {
        return self.p != null;
    }

    /// Send a request that creates no new object.
    pub fn call(self: Proxy, name: []const u8, args: anytype) void {
        const f: MarshalFn(@TypeOf(args)) = @ptrCast(@alignCast(marshal_raw));
        _ = @call(.auto, f, .{ self.p, opcode(self.i, name), @as(?*const Interface, null), getVersion(self.p), @as(u32, 0) } ++ args);
    }

    /// Send a request whose first argument is a new_id, and wrap the result.
    /// libwayland wants a null placeholder in that argument position.
    pub fn new(self: Proxy, name: []const u8, ni: *const Interface, args: anytype) Proxy {
        const all = .{@as(?*anyopaque, null)} ++ args;
        const f: MarshalFn(@TypeOf(all)) = @ptrCast(@alignCast(marshal_raw));
        const p = @call(.auto, f, .{ self.p, opcode(self.i, name), ni, getVersion(self.p), @as(u32, 0) } ++ all);
        return .{ .p = p, .i = ni };
    }

    pub fn listen(self: Proxy, l: *const anyopaque, data: ?*anyopaque) void {
        _ = addListener(self.p, l, data);
    }
};

// ------------------------------------------------------------------ xdg-shell
//
// Not in any shared library, so the wire layout is declared here. Only the
// requests and events we actually use are exercised; the rest are present
// purely to keep the opcodes at their real positions. `types` is null
// throughout because none of the events we receive carry object arguments.

fn msg(name: [*:0]const u8, sig: [*:0]const u8) Message {
    return .{ .name = name, .signature = sig, .types = null };
}

const xdg_wm_base_requests = [_]Message{
    msg("destroy", ""),           msg("create_positioner", "n"),
    msg("get_xdg_surface", "no"), msg("pong", "u"),
};
const xdg_wm_base_events = [_]Message{msg("ping", "u")};
const xdg_wm_base_i = Interface{
    .name = "xdg_wm_base",
    .version = 1,
    .method_count = xdg_wm_base_requests.len,
    .methods = &xdg_wm_base_requests,
    .event_count = xdg_wm_base_events.len,
    .events = &xdg_wm_base_events,
};

const xdg_surface_requests = [_]Message{
    msg("destroy", ""),        msg("get_toplevel", "n"),
    msg("get_popup", "n?oo"),  msg("set_window_geometry", "iiii"),
    msg("ack_configure", "u"),
};
const xdg_surface_events = [_]Message{msg("configure", "u")};
const xdg_surface_i = Interface{
    .name = "xdg_surface",
    .version = 1,
    .method_count = xdg_surface_requests.len,
    .methods = &xdg_surface_requests,
    .event_count = xdg_surface_events.len,
    .events = &xdg_surface_events,
};

const xdg_toplevel_requests = [_]Message{
    msg("destroy", ""),              msg("set_parent", "?o"),
    msg("set_title", "s"),           msg("set_app_id", "s"),
    msg("show_window_menu", "ouii"), msg("move", "ou"),
    msg("resize", "ouu"),            msg("set_max_size", "ii"),
    msg("set_min_size", "ii"),       msg("set_maximized", ""),
    msg("unset_maximized", ""),      msg("set_fullscreen", "?o"),
    msg("unset_fullscreen", ""),     msg("set_minimized", ""),
};
const xdg_toplevel_events = [_]Message{ msg("configure", "iia"), msg("close", "") };
const xdg_toplevel_i = Interface{
    .name = "xdg_toplevel",
    .version = 1,
    .method_count = xdg_toplevel_requests.len,
    .methods = &xdg_toplevel_requests,
    .event_count = xdg_toplevel_events.len,
    .events = &xdg_toplevel_events,
};

// ---------------------------------------------------------------- public API

/// A pointer position, in wl_fixed_t (24.8 fixed point). Kept unconverted so
/// nothing here has to touch a float.
pub const Fixed = i32;
pub fn toInt(f: Fixed) i32 {
    return f >> 8;
}

pub const Event = union(enum) {
    /// Raw evdev keycode (no XKB +8 offset).
    key: struct { seat: u8, code: u32, pressed: bool },
    modifiers: struct { seat: u8, depressed: u32, latched: u32, locked: u32, group: u32 },
    pointer_enter: struct { seat: u8, x: Fixed, y: Fixed },
    pointer_leave: struct { seat: u8 },
    pointer_motion: struct { seat: u8, x: Fixed, y: Fixed },
    pointer_button: struct { seat: u8, button: u32, pressed: bool },
    pointer_axis: struct { seat: u8, axis: u32, value: Fixed },
    touch_down: struct { seat: u8, id: i32, x: Fixed, y: Fixed },
    touch_up: struct { seat: u8, id: i32 },
    touch_motion: struct { seat: u8, id: i32, x: Fixed, y: Fixed },
    /// Text committed by an input method such as the webOS on-screen keyboard.
    text_commit: []const u8,
    text_delete: struct { offset: i32, length: u32 },
    text_keysym: struct { sym: u32, pressed: bool },
    input_panel: bool,
    resized: struct { width: u32, height: u32 },
    close,
};

pub var on_event: *const fn (Event) void = ignoreEvent;
fn ignoreEvent(_: Event) void {}

pub var width: u32 = 0;
pub var height: u32 = 0;
/// The window's pixels, ARGB8888, `width * height` of them, row-major.
pub var pixels: []u32 = &.{};
pub var running = true;
/// True on the TV: the surface is fullscreen and managed by LSM.
pub var on_webos = false;

/// LG's keycodes/lg maps IR_KEY_BACK to XKB 420, i.e. Wayland key 412.
/// On desktops 412 is KEY_PREVIOUS, so only treat it as Back on the TV.
pub fn isBackKey(code: u32) bool {
    return code == 1 or code == 158 or (on_webos and code == 412);
}

/// The current mode of the first wl_output, from the compositor. `refresh_mhz`
/// is millihertz, as the protocol reports it (60000 = 60 Hz); 0 means the
/// compositor never sent a mode.
pub var output_width: u32 = 0;
pub var output_height: u32 = 0;
pub var refresh_mhz: u32 = 0;

/// The wl_display, for EGL (`eglGetDisplay`) and anything else native.
pub var display: ?*anyopaque = null;
var registry: Proxy = .{};
var compositor: Proxy = .{};
var shm: Proxy = .{};
/// The wl_surface, for wl_egl_window_create.
pub var surface: Proxy = .{};
var webos_shell: Proxy = .{};
var webos_surface: Proxy = .{};
var handles_back = false;

/// Claim Back while the app can navigate or dismiss an editor. Root screens
/// release it to webOS. The property also works on older TV shell protocols.
/// See Kodi's ShellSurfaceWebOSShell.cpp (_WEBOS_ACCESS_POLICY_KEYS_BACK).
pub fn setBackHandled(handled: bool) void {
    if (handles_back == handled) return;
    handles_back = handled;
    if (webos_surface.ok()) {
        webos_surface.call("set_property", .{
            @as([*:0]const u8, "_WEBOS_ACCESS_POLICY_KEYS_BACK"),
            @as([*:0]const u8, if (handled) "true" else "false"),
        });
        _ = flushFn(display);
    }
}
var xdg_wm: Proxy = .{};
var xdg_surf: Proxy = .{};
var xdg_top: Proxy = .{};
var buffer: Proxy = .{};
var output: Proxy = .{};
var foreign: Proxy = .{};
var exported: Proxy = .{};
var text_model_factory: Proxy = .{};
var text_model: Proxy = .{};
var configured = false;
var seat_count: u8 = 0;
var seats: [4]Proxy = @splat(.{});

/// Connect and bind globals, without creating a window. `open` calls this;
/// call it directly to inspect the compositor (see glinfo/wlinfo).
pub fn connect() !void {
    if (display != null) return;
    libs[0] = c.dlopen("libwayland-client.so.0", .{ .NOW = true }) orelse return error.NoWaylandClient;
    libs[1] = c.dlopen("libwayland-webos-client.so.1", .{ .NOW = true }); // TV only

    marshal_raw = sym("wl_proxy_marshal_flags");
    getVersion = fnPtr(@TypeOf(getVersion), "wl_proxy_get_version");
    addListener = fnPtr(@TypeOf(addListener), "wl_proxy_add_listener");
    dispatchFn = fnPtr(@TypeOf(dispatchFn), "wl_display_dispatch");
    roundtripFn = fnPtr(@TypeOf(roundtripFn), "wl_display_roundtrip");
    dispatchPendingFn = fnPtr(@TypeOf(dispatchPendingFn), "wl_display_dispatch_pending");
    flushFn = fnPtr(@TypeOf(flushFn), "wl_display_flush");
    const connectFn = fnPtr(*const fn (?[*:0]const u8) callconv(.c) ?*anyopaque, "wl_display_connect");

    display = connectFn(null) orelse return error.NoDisplay;
    const disp = Proxy{ .p = display, .i = iface("wl_display_interface") };
    registry = disp.new("get_registry", iface("wl_registry_interface"), .{});
    registry.listen(&registry_listener, null);
    _ = roundtripFn(display); // receive globals
    _ = roundtripFn(display); // settle the binds
    if (!compositor.ok() or !shm.ok()) return error.MissingGlobals;
}

/// Globals the compositor advertised, in the order they arrived.
pub const Global = struct { name: u32, interface: [64]u8, len: u8, version: u32 };
pub var globals: [64]Global = undefined;
pub var global_count: usize = 0;

/// The `wl_*_interface` symbol for a protocol object, if the loaded libraries
/// carry one. Not every advertised global has a client-side interface.
pub fn ifaceOpt(name: [*:0]const u8) ?*const Interface {
    return @ptrCast(@alignCast(symOpt(name) orelse return null));
}

/// Print an interface's request and event tables. This is how the protocol gets
/// discovered on a device whose XML nobody published.
pub fn dumpInterface(i: *const Interface) void {
    std.debug.print("{s} v{d}\n", .{ i.name, i.version });
    if (i.methods) |m| for (0..@intCast(i.method_count)) |n| std.debug.print("  -> [{d}] {s}({s})\n", .{
        n, std.mem.sliceTo(m[n].name, 0), std.mem.sliceTo(m[n].signature, 0),
    });
    if (i.events) |e| for (0..@intCast(i.event_count)) |n| std.debug.print("  <- [{d}] {s}({s})\n", .{
        n, std.mem.sliceTo(e[n].name, 0), std.mem.sliceTo(e[n].signature, 0),
    });
}

/// How the window's pixels get there: a CPU-written shm buffer, or nothing at
/// all because something else (EGL) will attach its own buffers.
pub const Buffers = enum { shm, external };

/// Connect, bind a shell and map a window. Pass 0 for `w`/`h` to take the
/// output's own mode, which is what fullscreen on the TV gets anyway.
pub fn open(app_id: [*:0]const u8, title: [*:0]const u8, w: u32, h: u32, buffers: Buffers) !void {
    try connect();
    marshal_raw = sym("wl_proxy_marshal_flags");
    surface = compositor.new("create_surface", iface("wl_surface_interface"), .{});
    if (text_model_factory.ok()) if (ifaceOpt("text_model_interface")) |text_i| {
        text_model = text_model_factory.new("create_text_model", text_i, .{});
        text_model.listen(&text_model_listener, null);
    };
    width = if (w != 0) w else output_width;
    height = if (h != 0) h else output_height;
    if (width == 0 or height == 0) return error.NoOutputMode;

    if (webos_shell.ok()) {
        on_webos = true;
        const ss = webos_shell.new("get_shell_surface", iface("wl_webos_shell_surface_interface"), .{surface.p});
        webos_surface = ss;
        // LSM only shows surfaces it can attribute to an app.
        ss.call("set_property", .{ @as([*:0]const u8, "appId"), app_id });
        ss.call("set_property", .{
            @as([*:0]const u8, "_WEBOS_ACCESS_POLICY_KEYS_BACK"),
            @as([*:0]const u8, if (handles_back) "true" else "false"),
        });
        ss.call("set_state", .{@as(u32, 1)}); // 1 = fullscreen
        configured = true;
    } else if (xdg_wm.ok()) {
        xdg_wm.listen(&wm_base_listener, null);
        xdg_surf = xdg_wm.new("get_xdg_surface", &xdg_surface_i, .{surface.p});
        xdg_surf.listen(&xdg_surface_listener, null);
        xdg_top = xdg_surf.new("get_toplevel", &xdg_toplevel_i, .{});
        xdg_top.listen(&xdg_toplevel_listener, null);
        xdg_top.call("set_title", .{title});
        xdg_top.call("set_app_id", .{app_id});
        surface.call("commit", .{});
        while (!configured) _ = dispatchFn(display);
    } else return error.NoShell;

    if (buffers == .shm) try allocBuffer();
    return;
}

/// One shm buffer, rewritten in place.
/// ponytail: no double buffering -- the compositor may tear on a slow redraw.
/// Add a second buffer and honour wl_buffer.release when that shows.
fn allocBuffer() !void {
    const stride = width * 4;
    const size = stride * height;
    const mrc = linux.memfd_create("wl-shim", 0);
    if (failed(mrc)) return error.MemfdFailed;
    const fd: i32 = @intCast(mrc);
    if (failed(linux.ftruncate(fd, size))) return error.TruncFailed;
    const prc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (failed(prc)) return error.MmapFailed;
    const px: [*]u32 = @ptrFromInt(prc);
    pixels = px[0 .. width * height];

    const pool = shm.new("create_pool", iface("wl_shm_pool_interface"), .{ fd, @as(i32, @intCast(size)) });
    buffer = pool.new("create_buffer", iface("wl_buffer_interface"), .{
        @as(i32, 0),                @as(i32, @intCast(width)),
        @as(i32, @intCast(height)), @as(i32, @intCast(stride)),
        @as(u32, 0), // WL_SHM_FORMAT_ARGB8888
    });
}

/// Push `pixels` to the screen.
pub fn present() void {
    surface.call("attach", .{ buffer.p, @as(i32, 0), @as(i32, 0) });
    surface.call("damage", .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(width)), @as(i32, @intCast(height)) });
    surface.call("commit", .{});
    _ = roundtripFn(display);
}

/// Block until something happens, delivering it to `on_event`.
/// Returns false once the window should close.
pub fn dispatch() bool {
    if (dispatchFn(display) < 0) running = false;
    return running;
}

/// Deliver whatever has already arrived without blocking, for apps that drive
/// their own frame loop (EGL). Returns false once the window should close.
pub fn poll() bool {
    if (dispatchPendingFn(display) < 0) running = false;
    _ = flushFn(display);
    return running;
}

/// Linux syscalls return errors as -4095..-1. On 32-bit a valid pointer can
/// exceed 2GB and bit-cast to a negative isize, so a plain `< 0` test is wrong.
fn failed(rc: usize) bool {
    return rc >= @as(usize, @bitCast(@as(isize, -4095)));
}

// ----------------------------------------------------------------- listeners

fn bindGlobal(name: u32, i: *const Interface, version: u32) Proxy {
    // wl_registry.bind is "usun": name, interface string, version, new_id --
    // the new_id placeholder comes last here, unlike every other request.
    const all = .{ name, i.name, version, @as(?*anyopaque, null) };
    const f: MarshalFn(@TypeOf(all)) = @ptrCast(@alignCast(marshal_raw));
    const p = @call(.auto, f, .{ registry.p, opcode(registry.i, "bind"), i, version, @as(u32, 0) } ++ all);
    return .{ .p = p, .i = i };
}

fn onGlobal(_: ?*anyopaque, _: ?*anyopaque, name: u32, i: [*:0]const u8, version: u32) callconv(.c) void {
    const s = std.mem.sliceTo(i, 0);
    if (global_count < globals.len and s.len <= 64) {
        const g = &globals[global_count];
        g.* = .{ .name = name, .interface = undefined, .len = @intCast(s.len), .version = version };
        @memcpy(g.interface[0..s.len], s);
        global_count += 1;
    }
    if (std.mem.eql(u8, s, "wl_compositor")) {
        compositor = bindGlobal(name, iface("wl_compositor_interface"), 1);
    } else if (std.mem.eql(u8, s, "wl_shm")) {
        shm = bindGlobal(name, iface("wl_shm_interface"), 1);
    } else if (std.mem.eql(u8, s, "wl_webos_shell")) {
        if (symOpt("wl_webos_shell_interface") != null)
            webos_shell = bindGlobal(name, iface("wl_webos_shell_interface"), 1);
    } else if (std.mem.eql(u8, s, "xdg_wm_base")) {
        xdg_wm = bindGlobal(name, &xdg_wm_base_i, 1);
    } else if (std.mem.eql(u8, s, "wl_webos_foreign")) {
        if (symOpt("wl_webos_foreign_interface") != null)
            foreign = bindGlobal(name, iface("wl_webos_foreign_interface"), 1);
    } else if (std.mem.eql(u8, s, "text_model_factory")) {
        if (symOpt("text_model_factory_interface") != null)
            text_model_factory = bindGlobal(name, iface("text_model_factory_interface"), 1);
    } else if (std.mem.eql(u8, s, "wl_output") and !output.ok()) {
        output = bindGlobal(name, iface("wl_output_interface"), 1);
        output.listen(&output_listener, null);
    } else if (std.mem.eql(u8, s, "wl_seat") and seat_count < seats.len) {
        // The TV advertises three seats -- remote, panel buttons and a virtual
        // one -- and does not say which is which. Listen to all of them and let
        // the app label events by index.
        const seat = bindGlobal(name, iface("wl_seat_interface"), 1);
        seats[seat_count] = seat;
        // The listener `data` pointer carries the seat index + 1; every device
        // this seat creates inherits it, so events stay attributable.
        seat.listen(&seat_listener, @ptrFromInt(@as(usize, seat_count) + 1));
        seat_count += 1;
    }
}
fn onGlobalRemove(_: ?*anyopaque, _: ?*anyopaque, _: u32) callconv(.c) void {}

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*anyopaque, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) void,
};
const registry_listener = RegistryListener{ .global = onGlobal, .global_remove = onGlobalRemove };

fn onPing(_: ?*anyopaque, _: ?*anyopaque, serial: u32) callconv(.c) void {
    xdg_wm.call("pong", .{serial});
}
const wm_base_listener = extern struct { ping: @TypeOf(&onPing) }{ .ping = onPing };

fn onXdgConfigure(_: ?*anyopaque, _: ?*anyopaque, serial: u32) callconv(.c) void {
    xdg_surf.call("ack_configure", .{serial});
    configured = true;
}
const xdg_surface_listener = extern struct { configure: @TypeOf(&onXdgConfigure) }{ .configure = onXdgConfigure };

fn onToplevelConfigure(_: ?*anyopaque, _: ?*anyopaque, w: i32, h: i32, _: ?*anyopaque) callconv(.c) void {
    // ponytail: the buffer is allocated once, so a resize is reported but not
    // honoured. Reallocate here if a resizable window ever matters.
    if (w > 0 and h > 0) on_event(.{ .resized = .{ .width = @intCast(w), .height = @intCast(h) } });
}
fn onToplevelClose(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    on_event(.close);
    running = false;
}
const xdg_toplevel_listener = extern struct {
    configure: @TypeOf(&onToplevelConfigure),
    close: @TypeOf(&onToplevelClose),
}{ .configure = onToplevelConfigure, .close = onToplevelClose };

fn onMode(_: ?*anyopaque, _: ?*anyopaque, flags: u32, w: i32, h: i32, refresh: i32) callconv(.c) void {
    if (flags & 1 == 0) return; // WL_OUTPUT_MODE_CURRENT
    output_width = @intCast(w);
    output_height = @intCast(h);
    refresh_mhz = @intCast(@max(refresh, 0));
}
const output_listener = extern struct {
    geometry: Nop,
    mode: @TypeOf(&onMode),
    rest: [4]Nop,
}{
    .geometry = nop,
    .mode = onMode,
    .rest = @splat(nop),
};

// ------------------------------------------------------- video punch-through

/// wl_webos_foreign's exported-element types. The `window_id_assigned` event
/// echoes the type back, so a wrong guess here is visible rather than silent.
pub const ExportedType = enum(u32) { video = 0, subtitle = 1, transparent = 2, opaque_object = 3 };

var window_id: [128]u8 = @splat(0);
var window_id_len: usize = 0;

fn onWindowId(_: ?*anyopaque, _: ?*anyopaque, id: [*:0]const u8, kind: u32) callconv(.c) void {
    const s = std.mem.sliceTo(id, 0);
    window_id_len = @min(s.len, window_id.len - 1);
    @memcpy(window_id[0..window_id_len], s[0..window_id_len]);
    std.debug.print("exported window id '{s}' type {d}\n", .{ window_id[0..window_id_len], kind });
}
const exported_listener = extern struct { window_id_assigned: @TypeOf(&onWindowId) }{ .window_id_assigned = onWindowId };

fn region(x: i32, y: i32, w: i32, h: i32) Proxy {
    const r = compositor.new("create_region", iface("wl_region_interface"), .{});
    r.call("add", .{ x, y, w, h });
    return r;
}

/// Export this window as a video element and return the id the compositor
/// assigns it, NUL-terminated so it can be handed straight to a C API.
///
/// The hardware decoder writes to a video plane; the compositor punches that
/// plane through wherever this surface's destination region is. The surface
/// must already have content committed, and must be transparent where the
/// video should show.
pub fn exportVideoWindow(src: [4]i32, dst: [4]i32) ![*:0]const u8 {
    if (!foreign.ok()) return error.NoWebosForeign;
    exported = foreign.new("export_element", iface("wl_webos_exported_interface"), .{
        surface.p, @intFromEnum(ExportedType.video),
    });
    exported.listen(&exported_listener, null);
    exported.call("set_exported_window", .{
        region(src[0], src[1], src[2], src[3]).p,
        region(dst[0], dst[1], dst[2], dst[3]).p,
    });
    surface.call("commit", .{});
    for (0..20) |_| {
        _ = roundtripFn(display);
        if (window_id_len != 0) return @ptrCast(window_id[0..window_id_len :0].ptr);
    }
    return error.NoWindowId;
}

// -------------------------------------------------------------- text input

pub const TextPurpose = enum(u32) { normal = 0, url = 5, password = 8 };

/// Activate the TV's text model and show its on-screen keyboard. Desktop
/// compositors do not expose this webOS protocol; physical wl_keyboard input
/// remains available on both platforms.
pub fn beginTextInput(text: [:0]const u8, rect: [4]i32, purpose: TextPurpose) bool {
    if (!text_model.ok() or seat_count == 0) return false;
    text_model.call("activate", .{ @as(u32, 0), seats[0].p, surface.p });
    text_model.call("set_surrounding_text", .{ text.ptr, @as(u32, @intCast(text.len)), @as(u32, @intCast(text.len)) });
    const hint: u32 = switch (purpose) {
        .url => 0x100, // latin
        .password => 0xc0, // hidden_text | sensitive_data
        .normal => 0,
    };
    text_model.call("set_content_type", .{ hint, @intFromEnum(purpose) });
    text_model.call("set_cursor_rectangle", .{ rect[0], rect[1], rect[2], rect[3] });
    text_model.call("set_max_text_length", .{@as(u32, 255)});
    text_model.call("commit", .{});
    text_model.call("show_input_panel", .{});
    return true;
}

pub fn updateTextInput(text: [:0]const u8) void {
    if (!text_model.ok()) return;
    text_model.call("set_surrounding_text", .{ text.ptr, @as(u32, @intCast(text.len)), @as(u32, @intCast(text.len)) });
    text_model.call("commit", .{});
}

pub fn endTextInput() void {
    if (!text_model.ok() or seat_count == 0) return;
    text_model.call("hide_input_panel", .{});
    text_model.call("deactivate", .{seats[0].p});
}

fn tmCommit(_: ?*anyopaque, _: ?*anyopaque, _: u32, text: [*:0]const u8) callconv(.c) void {
    on_event(.{ .text_commit = std.mem.sliceTo(text, 0) });
}
fn tmPreedit(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) void {}
fn tmDelete(_: ?*anyopaque, _: ?*anyopaque, _: u32, offset: i32, length: u32) callconv(.c) void {
    on_event(.{ .text_delete = .{ .offset = offset, .length = length } });
}
fn tmCursor(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: i32, _: i32) callconv(.c) void {}
fn tmStyle(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
fn tmPreeditCursor(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: i32) callconv(.c) void {}
fn tmModifiers(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
fn tmKeysym(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: u32, key_sym: u32, state: u32, _: u32) callconv(.c) void {
    on_event(.{ .text_keysym = .{ .sym = key_sym, .pressed = state != 0 } });
}
fn tmEnter(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
fn tmLeave(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
fn tmPanel(_: ?*anyopaque, _: ?*anyopaque, state: u32) callconv(.c) void {
    on_event(.{ .input_panel = state != 0 });
}
fn tmPanelRect(_: ?*anyopaque, _: ?*anyopaque, _: i32, _: i32, _: u32, _: u32) callconv(.c) void {}

const text_model_listener = extern struct {
    commit_string: @TypeOf(&tmCommit),
    preedit_string: @TypeOf(&tmPreedit),
    delete_surrounding_text: @TypeOf(&tmDelete),
    cursor_position: @TypeOf(&tmCursor),
    preedit_styling: @TypeOf(&tmStyle),
    preedit_cursor: @TypeOf(&tmPreeditCursor),
    modifiers_map: @TypeOf(&tmModifiers),
    keysym: @TypeOf(&tmKeysym),
    enter: @TypeOf(&tmEnter),
    leave: @TypeOf(&tmLeave),
    input_panel_state: @TypeOf(&tmPanel),
    input_panel_rect: @TypeOf(&tmPanelRect),
}{
    .commit_string = tmCommit,
    .preedit_string = tmPreedit,
    .delete_surrounding_text = tmDelete,
    .cursor_position = tmCursor,
    .preedit_styling = tmStyle,
    .preedit_cursor = tmPreeditCursor,
    .modifiers_map = tmModifiers,
    .keysym = tmKeysym,
    .enter = tmEnter,
    .leave = tmLeave,
    .input_panel_state = tmPanel,
    .input_panel_rect = tmPanelRect,
};

// -------------------------------------------------------------------- input
//
// Seats are bound at version 1, so only the original event set arrives. The
// trailing no-ops exist because libwayland indexes the listener by event
// opcode and newer libraries declare more events than v1 can send.

fn seatOf(data: ?*anyopaque) u8 {
    return @intCast(@intFromPtr(data) -| 1);
}
fn nop(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
const Nop = @TypeOf(&nop);

fn onCapabilities(data: ?*anyopaque, proxy: ?*anyopaque, caps: u32) callconv(.c) void {
    const seat = Proxy{ .p = proxy, .i = iface("wl_seat_interface") };
    if (caps & 1 != 0) seat.new("get_pointer", iface("wl_pointer_interface"), .{}).listen(&pointer_listener, data);
    if (caps & 2 != 0) seat.new("get_keyboard", iface("wl_keyboard_interface"), .{}).listen(&keyboard_listener, data);
    if (caps & 4 != 0) seat.new("get_touch", iface("wl_touch_interface"), .{}).listen(&touch_listener, data);
}
const seat_listener = extern struct { capabilities: @TypeOf(&onCapabilities), name: Nop }{
    .capabilities = onCapabilities,
    .name = nop,
};

fn ptrEnter(d: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*anyopaque, x: Fixed, y: Fixed) callconv(.c) void {
    on_event(.{ .pointer_enter = .{ .seat = seatOf(d), .x = x, .y = y } });
}
fn ptrLeave(d: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*anyopaque) callconv(.c) void {
    on_event(.{ .pointer_leave = .{ .seat = seatOf(d) } });
}
fn ptrMotion(d: ?*anyopaque, _: ?*anyopaque, _: u32, x: Fixed, y: Fixed) callconv(.c) void {
    on_event(.{ .pointer_motion = .{ .seat = seatOf(d), .x = x, .y = y } });
}
fn ptrButton(d: ?*anyopaque, _: ?*anyopaque, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    on_event(.{ .pointer_button = .{ .seat = seatOf(d), .button = button, .pressed = state != 0 } });
}
fn ptrAxis(d: ?*anyopaque, _: ?*anyopaque, _: u32, axis: u32, value: Fixed) callconv(.c) void {
    on_event(.{ .pointer_axis = .{ .seat = seatOf(d), .axis = axis, .value = value } });
}
const pointer_listener = extern struct {
    enter: @TypeOf(&ptrEnter),
    leave: @TypeOf(&ptrLeave),
    motion: @TypeOf(&ptrMotion),
    button: @TypeOf(&ptrButton),
    axis: @TypeOf(&ptrAxis),
    rest: [6]Nop,
}{
    .enter = ptrEnter,
    .leave = ptrLeave,
    .motion = ptrMotion,
    .button = ptrButton,
    .axis = ptrAxis,
    .rest = @splat(nop),
};

fn kbKeymap(_: ?*anyopaque, _: ?*anyopaque, _: u32, fd: i32, _: u32) callconv(.c) void {
    _ = linux.close(fd); // we report raw keycodes; xkb is not needed
}
fn kbKey(d: ?*anyopaque, _: ?*anyopaque, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    on_event(.{ .key = .{ .seat = seatOf(d), .code = key, .pressed = state != 0 } });
}
fn kbModifiers(d: ?*anyopaque, _: ?*anyopaque, _: u32, dep: u32, lat: u32, lock: u32, group: u32) callconv(.c) void {
    on_event(.{ .modifiers = .{ .seat = seatOf(d), .depressed = dep, .latched = lat, .locked = lock, .group = group } });
}
const keyboard_listener = extern struct {
    keymap: @TypeOf(&kbKeymap),
    enter: Nop,
    leave: Nop,
    key: @TypeOf(&kbKey),
    modifiers: @TypeOf(&kbModifiers),
    repeat_info: Nop,
}{
    .keymap = kbKeymap,
    .enter = nop,
    .leave = nop,
    .key = kbKey,
    .modifiers = kbModifiers,
    .repeat_info = nop,
};

fn touchDown(d: ?*anyopaque, _: ?*anyopaque, _: u32, _: u32, _: ?*anyopaque, id: i32, x: Fixed, y: Fixed) callconv(.c) void {
    on_event(.{ .touch_down = .{ .seat = seatOf(d), .id = id, .x = x, .y = y } });
}
fn touchUp(d: ?*anyopaque, _: ?*anyopaque, _: u32, _: u32, id: i32) callconv(.c) void {
    on_event(.{ .touch_up = .{ .seat = seatOf(d), .id = id } });
}
fn touchMotion(d: ?*anyopaque, _: ?*anyopaque, _: u32, id: i32, x: Fixed, y: Fixed) callconv(.c) void {
    on_event(.{ .touch_motion = .{ .seat = seatOf(d), .id = id, .x = x, .y = y } });
}
const touch_listener = extern struct {
    down: @TypeOf(&touchDown),
    up: @TypeOf(&touchUp),
    motion: @TypeOf(&touchMotion),
    rest: [4]Nop,
}{
    .down = touchDown,
    .up = touchUp,
    .motion = touchMotion,
    .rest = @splat(nop),
};
