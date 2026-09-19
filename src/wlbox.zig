//! Flashes a red box on a webOS TV via Wayland (LSM), using wl_shm.
//!
//! Both libwayland-client and libwayland-webos-client are dlopen'd at runtime, so
//! the build needs no headers, no sysroot and no .so on the build machine:
//!   zig build-exe wlbox.zig -target arm-linux-gnueabi.2.31 -lc -O ReleaseSmall
//!
//! Why Wayland and not the framebuffer: /dev/fb0 ("osd0_fb") reports smem_len=4096
//! and mmap fails with EIO -- the real scanout surface is AFBC-compressed and owned
//! by surface-manager via DRM. See fbflash.zig. Wayland is the only route to the plane.
//!
//! Request opcodes are looked up BY NAME from the wl_interface method tables the
//! libraries already carry, so no protocol opcode is hardcoded or guessed.
const std = @import("std");
const linux = std.os.linux;
const c = std.c;

const W = 1920;
const H = 1080;
const STRIDE = W * 4;
const SIZE = STRIDE * H;
const BOX_W = 400;
const BOX_H = 300;

const SHM_FORMAT_ARGB8888 = 0;
const WL_DISPLAY_GET_REGISTRY = 1;

const Message = extern struct { name: [*:0]const u8, signature: [*:0]const u8, types: ?*const anyopaque };
const Interface = extern struct {
    name: [*:0]const u8,
    version: i32,
    method_count: i32,
    methods: ?[*]const Message,
    event_count: i32,
    events: ?[*]const Message,
};

/// wl_proxy_marshal_flags is variadic, but every argument we pass is word-sized
/// (u32/i32/pointer). For those, the ARM EABI variadic and fixed calling
/// conventions are identical, so fixed-arity prototypes are ABI-safe and spare
/// us variadic function pointers.
const M0 = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32) callconv(.c) ?*anyopaque;
const M1 = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, ?*anyopaque) callconv(.c) ?*anyopaque;
const M2 = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
const MBind = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, u32, [*:0]const u8, u32, ?*anyopaque) callconv(.c) ?*anyopaque;
const MPool = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, ?*anyopaque, i32, i32) callconv(.c) ?*anyopaque;
const MBuffer = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, ?*anyopaque, i32, i32, i32, i32, u32) callconv(.c) ?*anyopaque;
const MAttach = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, ?*anyopaque, i32, i32) callconv(.c) ?*anyopaque;
const MDamage = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, i32, i32, i32, i32) callconv(.c) ?*anyopaque;
const MStr2 = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque;
const MU1 = *const fn (?*anyopaque, u32, ?*const anyopaque, u32, u32, u32) callconv(.c) ?*anyopaque;

const Connect = *const fn (?[*:0]const u8) callconv(.c) ?*anyopaque;
const Roundtrip = *const fn (?*anyopaque) callconv(.c) i32;
const AddListener = *const fn (?*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) i32;
const GetVersion = *const fn (?*anyopaque) callconv(.c) u32;

var handles: [2]?*anyopaque = .{ null, null };

fn sym(comptime name: [:0]const u8) *anyopaque {
    for (handles) |h| {
        if (h) |hh| if (c.dlsym(hh, name.ptr)) |p| return p;
    }
    std.debug.print("missing symbol: {s}\n", .{name});
    std.process.exit(1);
}
fn fnPtr(comptime T: type, comptime name: [:0]const u8) T {
    return @ptrCast(@alignCast(sym(name)));
}
fn iface(comptime name: [:0]const u8) *const Interface {
    return @ptrCast(@alignCast(sym(name)));
}

/// Find a request's opcode by name in the interface's own method table.
/// Beats hardcoding opcodes from a protocol XML we'd have to trust from memory.
fn opcode(i: *const Interface, name: []const u8) u32 {
    const methods = i.methods orelse {
        std.debug.print("{s}: no method table\n", .{i.name});
        std.process.exit(1);
    };
    for (0..@intCast(i.method_count)) |n| {
        if (std.mem.eql(u8, std.mem.sliceTo(methods[n].name, 0), name)) return @intCast(n);
    }
    std.debug.print("{s}: no request named '{s}'\n", .{ i.name, name });
    std.process.exit(1);
}

fn dumpMethods(i: *const Interface) void {
    std.debug.print("{s} v{d}:\n", .{ i.name, i.version });
    if (i.methods) |m| for (0..@intCast(i.method_count)) |n| {
        std.debug.print("  [{d}] {s}({s})\n", .{ n, std.mem.sliceTo(m[n].name, 0), std.mem.sliceTo(m[n].signature, 0) });
    };
}

var getVersion: GetVersion = undefined;
var bindFn: MBind = undefined;
var g_registry: ?*anyopaque = null;
var g_compositor: ?*anyopaque = null;
var g_shm: ?*anyopaque = null;
var g_wshell: ?*anyopaque = null;

fn bind(name: u32, i: *const Interface, version: u32) ?*anyopaque {
    return bindFn(g_registry, 0, i, version, 0, name, i.name, version, null);
}

fn onGlobal(_: ?*anyopaque, _: ?*anyopaque, name: u32, i: [*:0]const u8, _: u32) callconv(.c) void {
    const s = std.mem.sliceTo(i, 0);
    if (std.mem.eql(u8, s, "wl_compositor")) {
        g_compositor = bind(name, iface("wl_compositor_interface"), 1);
    } else if (std.mem.eql(u8, s, "wl_shm")) {
        g_shm = bind(name, iface("wl_shm_interface"), 1);
    } else if (std.mem.eql(u8, s, "wl_webos_shell")) {
        g_wshell = bind(name, iface("wl_webos_shell_interface"), 1);
    }
}
fn onGlobalRemove(_: ?*anyopaque, _: ?*anyopaque, _: u32) callconv(.c) void {}

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*anyopaque, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) void,
};

/// Linux syscalls return errors as -4095..-1. On 32-bit a valid pointer can
/// exceed 2GB and bit-cast to a negative isize, so a plain `< 0` test is wrong.
fn syscallFailed(rc: usize) bool {
    return rc >= @as(usize, @bitCast(@as(isize, -4095)));
}

fn sleepMs(ms: u32) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

pub fn main() !void {
    handles[0] = c.dlopen("libwayland-client.so.0", .{ .NOW = true }) orelse return error.NoWaylandClient;
    handles[1] = c.dlopen("libwayland-webos-client.so.1", .{ .NOW = true }) orelse return error.NoWebosClient;

    const connect = fnPtr(Connect, "wl_display_connect");
    const roundtrip = fnPtr(Roundtrip, "wl_display_roundtrip");
    const addListener = fnPtr(AddListener, "wl_proxy_add_listener");
    getVersion = fnPtr(GetVersion, "wl_proxy_get_version");
    const marshal0 = fnPtr(M0, "wl_proxy_marshal_flags");
    bindFn = @ptrCast(marshal0);
    const marshal1: M1 = @ptrCast(marshal0);
    const marshal2: M2 = @ptrCast(marshal0);
    const mPool: MPool = @ptrCast(marshal0);
    const mBuffer: MBuffer = @ptrCast(marshal0);
    const mAttach: MAttach = @ptrCast(marshal0);
    const mDamage: MDamage = @ptrCast(marshal0);
    const mStr2: MStr2 = @ptrCast(marshal0);
    const mU1: MU1 = @ptrCast(marshal0);

    const shell_i = iface("wl_webos_shell_interface");
    const shell_surface_i = iface("wl_webos_shell_surface_interface");
    dumpMethods(shell_i);
    dumpMethods(shell_surface_i);

    const display = connect(null) orelse {
        std.debug.print("wl_display_connect failed (XDG_RUNTIME_DIR / WAYLAND_DISPLAY?)\n", .{});
        return error.NoDisplay;
    };

    g_registry = marshal1(display, WL_DISPLAY_GET_REGISTRY, iface("wl_registry_interface"), getVersion(display), 0, null) orelse return error.NoRegistry;
    const listener = RegistryListener{ .global = onGlobal, .global_remove = onGlobalRemove };
    _ = addListener(g_registry, &listener, null);
    _ = roundtrip(display); // receive globals
    _ = roundtrip(display); // settle the binds
    if (g_compositor == null or g_shm == null or g_wshell == null) {
        std.debug.print("missing globals: compositor={?*} shm={?*} webos_shell={?*}\n", .{ g_compositor, g_shm, g_wshell });
        return error.MissingGlobals;
    }

    // Shared-memory buffer, full screen so LSM has nothing to scale or reposition.
    const mrc = linux.memfd_create("wlbox", 0);
    if (syscallFailed(mrc)) return error.MemfdFailed;
    const fd: i32 = @intCast(mrc);
    if (syscallFailed(linux.ftruncate(fd, SIZE))) return error.TruncFailed;
    const prc = linux.mmap(null, SIZE, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (syscallFailed(prc)) return error.MmapFailed;
    const px: [*]u32 = @ptrFromInt(prc);

    const shm_i = iface("wl_shm_interface");
    const pool = mPool(g_shm, opcode(shm_i, "create_pool"), iface("wl_shm_pool_interface"), getVersion(g_shm), 0, null, fd, SIZE) orelse return error.NoPool;
    const pool_i = iface("wl_shm_pool_interface");
    const buffer = mBuffer(pool, opcode(pool_i, "create_buffer"), iface("wl_buffer_interface"), getVersion(pool), 0, null, 0, W, H, STRIDE, SHM_FORMAT_ARGB8888) orelse return error.NoBuffer;

    const comp_i = iface("wl_compositor_interface");
    const surface = marshal1(g_compositor, opcode(comp_i, "create_surface"), iface("wl_surface_interface"), getVersion(g_compositor), 0, null) orelse return error.NoSurface;
    const surface_i = iface("wl_surface_interface");

    const shell_surface = marshal2(g_wshell, opcode(shell_i, "get_shell_surface"), shell_surface_i, getVersion(g_wshell), 0, null, surface) orelse return error.NoShellSurface;

    // LSM only shows surfaces it can attribute to an app.
    const appid = c.getenv("APPID") orelse @as([*:0]const u8, "com.webos.app.wlbox");
    _ = mStr2(shell_surface, opcode(shell_surface_i, "set_property"), null, getVersion(shell_surface), 0, "appId", appid);
    std.debug.print("appId={s}\n", .{std.mem.sliceTo(appid, 0)});
    // state 1 = fullscreen in wl_webos_shell.
    _ = mU1(shell_surface, opcode(shell_surface_i, "set_state"), null, getVersion(shell_surface), 0, 1);

    const attach = opcode(surface_i, "attach");
    const damage = opcode(surface_i, "damage");
    const commit = opcode(surface_i, "commit");

    // ponytail: one buffer rewritten in place rather than a proper two-buffer
    // swap. Fine for a visual flash test; honour wl_buffer.release if this
    // ever becomes real rendering.
    for (0..10) |i| {
        const on = i % 2 == 0;
        @memset(px[0 .. W * H], 0xFF000000); // opaque black
        if (on) {
            const x0 = (W - BOX_W) / 2;
            const y0 = (H - BOX_H) / 2;
            for (0..BOX_H) |row| {
                @memset(px[(y0 + row) * W + x0 ..][0..BOX_W], 0xFFFF0000); // opaque red
            }
        }
        _ = mAttach(surface, attach, null, getVersion(surface), 0, buffer, 0, 0);
        _ = mDamage(surface, damage, null, getVersion(surface), 0, 0, 0, W, H);
        _ = marshal0(surface, commit, null, getVersion(surface), 0);
        _ = roundtrip(display);
        std.debug.print("frame {d}: box {s}\n", .{ i, if (on) "RED" else "off" });
        sleepMs(700);
    }
    std.debug.print("done\n", .{});
}
