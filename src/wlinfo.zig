//! Lists the Wayland globals LSM advertises. libwayland-client is dlopen'd at
//! runtime, so the build needs no headers, no sysroot, no .so on disk:
//!   zig build-exe wlinfo.zig -target arm-linux-gnueabihf.2.31 -lc -O ReleaseSmall
const std = @import("std");
const c = std.c;

/// wl_proxy_marshal_flags is variadic, but every argument we pass is
/// integer/pointer sized, where the ARM EABI variadic and fixed ABIs agree.
/// So a fixed-arity prototype is safe here and avoids variadic fn pointers.
const MarshalFlags = *const fn (
    proxy: ?*anyopaque,
    opcode: u32,
    interface: ?*const anyopaque,
    version: u32,
    flags: u32,
    new_id: ?*anyopaque,
) callconv(.c) ?*anyopaque;

const Connect = *const fn (name: ?[*:0]const u8) callconv(.c) ?*anyopaque;
const Disconnect = *const fn (display: ?*anyopaque) callconv(.c) void;
const Roundtrip = *const fn (display: ?*anyopaque) callconv(.c) i32;
const AddListener = *const fn (proxy: ?*anyopaque, impl: *const anyopaque, data: ?*anyopaque) callconv(.c) i32;
const GetVersion = *const fn (proxy: ?*anyopaque) callconv(.c) u32;

const WL_DISPLAY_GET_REGISTRY = 1;

var count: u32 = 0;

fn onGlobal(_: ?*anyopaque, _: ?*anyopaque, name: u32, iface: [*:0]const u8, version: u32) callconv(.c) void {
    count += 1;
    std.debug.print("  [{d:>3}] {s}  v{d}\n", .{ name, std.mem.sliceTo(iface, 0), version });
}

fn onGlobalRemove(_: ?*anyopaque, _: ?*anyopaque, _: u32) callconv(.c) void {}

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*anyopaque, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) void,
};

fn need(h: ?*anyopaque, comptime name: [:0]const u8) *anyopaque {
    return c.dlsym(h, name.ptr) orelse {
        std.debug.print("missing symbol: {s}\n", .{name});
        std.process.exit(1);
    };
}

pub fn main() !void {
    const h = c.dlopen("libwayland-client.so.0", .{ .NOW = true }) orelse {
        std.debug.print("dlopen(libwayland-client.so.0) failed\n", .{});
        return error.NoWayland;
    };

    const connect: Connect = @ptrCast(@alignCast(need(h, "wl_display_connect")));
    const disconnect: Disconnect = @ptrCast(@alignCast(need(h, "wl_display_disconnect")));
    const roundtrip: Roundtrip = @ptrCast(@alignCast(need(h, "wl_display_roundtrip")));
    const marshal: MarshalFlags = @ptrCast(@alignCast(need(h, "wl_proxy_marshal_flags")));
    const addListener: AddListener = @ptrCast(@alignCast(need(h, "wl_proxy_add_listener")));
    const getVersion: GetVersion = @ptrCast(@alignCast(need(h, "wl_proxy_get_version")));
    const registry_iface: *const anyopaque = @ptrCast(@alignCast(need(h, "wl_registry_interface")));

    const display = connect(null) orelse {
        std.debug.print("wl_display_connect failed (WAYLAND_DISPLAY / XDG_RUNTIME_DIR set?)\n", .{});
        return error.NoDisplay;
    };
    defer disconnect(display);

    const registry = marshal(display, WL_DISPLAY_GET_REGISTRY, registry_iface, getVersion(display), 0, null) orelse {
        return error.NoRegistry;
    };

    const listener = RegistryListener{ .global = onGlobal, .global_remove = onGlobalRemove };
    _ = addListener(registry, &listener, null);

    std.debug.print("globals:\n", .{});
    _ = roundtrip(display);
    std.debug.print("{d} globals\n", .{count});
}
