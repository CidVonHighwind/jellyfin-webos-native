//! Flashes a red box on screen -- the smoke test that proved a native app can
//! reach the TV's display plane at all.
//!
//! Why Wayland and not the framebuffer: /dev/fb0 ("osd0_fb") reports
//! smem_len=4096 and mmap fails with EIO -- the real scanout surface is
//! AFBC-compressed and owned by surface-manager via DRM. See fbflash.zig.
//! Wayland is the only route to the plane.
const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl.zig");

const BOX_W = 400;
const BOX_H = 300;

fn sleepMs(ms: u32) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

pub fn main() !void {
    const appid = std.c.getenv("APPID") orelse @as([*:0]const u8, "dev.hookedbehemoth.wlbox");
    try wl.open(appid, "red box", 0, 0, .shm);
    std.debug.print("appId={s} {d}x{d}\n", .{ std.mem.sliceTo(appid, 0), wl.width, wl.height });

    for (0..10) |i| {
        const on = i % 2 == 0;
        @memset(wl.pixels, 0xFF000000); // opaque black
        if (on) {
            const x0 = (wl.width - BOX_W) / 2;
            const y0 = (wl.height - BOX_H) / 2;
            for (0..BOX_H) |row| {
                @memset(wl.pixels[(y0 + row) * wl.width + x0 ..][0..BOX_W], 0xFFFF0000); // opaque red
            }
        }
        wl.present();
        std.debug.print("frame {d}: box {s}\n", .{ i, if (on) "RED" else "off" });
        sleepMs(700);
    }
    std.debug.print("done\n", .{});
}
