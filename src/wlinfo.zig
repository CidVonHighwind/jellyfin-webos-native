//! Lists the Wayland globals LSM advertises, and dumps the request/event table
//! of every one whose client-side interface the loaded libraries carry.
//!
//! That table dump is the whole point: the webOS protocol extensions
//! (wl_webos_shell, wl_webos_foreign, ...) have no published XML, so the only
//! trustworthy description of them is the one libwayland-webos-client compiles
//! in. Read the opcodes and signatures off this, never guess.
//!
//!   zig build run -Dapp=wlinfo
//!   IFACES="wl_webos_foreign wl_webos_exported" zig build run -Dapp=wlinfo
const std = @import("std");
const wl = @import("wl.zig");

pub fn main() !void {
    try wl.connect();

    std.debug.print("globals:\n", .{});
    for (wl.globals[0..wl.global_count]) |g| {
        std.debug.print("  [{d:>3}] {s}  v{d}\n", .{ g.name, g.interface[0..g.len], g.version });
    }
    std.debug.print("{d} globals\n\n", .{wl.global_count});

    // Interface symbols are "<name>_interface"; build that from each global.
    var buf: [96]u8 = undefined;
    for (wl.globals[0..wl.global_count]) |g| {
        const sym = std.fmt.bufPrintZ(&buf, "{s}_interface", .{g.interface[0..g.len]}) catch continue;
        if (wl.ifaceOpt(sym)) |i| wl.dumpInterface(i);
    }

    // Objects that are not globals themselves (surfaces, shell surfaces,
    // exported windows) only show up if asked for by name.
    if (std.c.getenv("IFACES")) |list| {
        var it = std.mem.tokenizeScalar(u8, std.mem.sliceTo(list, 0), ' ');
        while (it.next()) |name| {
            const sym = std.fmt.bufPrintZ(&buf, "{s}_interface", .{name}) catch continue;
            if (wl.ifaceOpt(sym)) |i| wl.dumpInterface(i) else std.debug.print("{s}: no such interface\n", .{name});
        }
    }
}
