//! Flashes a red box on /dev/fb0 to verify we can get pixels on screen.
//! Static, libc-free: zig build-exe fbflash.zig -target arm-linux-gnueabihf -O ReleaseSmall
const std = @import("std");
const linux = std.os.linux;

const FBIOGET_VSCREENINFO = 0x4600;
const FBIOGET_FSCREENINFO = 0x4602;

const Bitfield = extern struct { offset: u32, length: u32, msb_right: u32 };

const VarInfo = extern struct {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    red: Bitfield,
    green: Bitfield,
    blue: Bitfield,
    transp: Bitfield,
    nonstd: u32,
    activate: u32,
    height: u32,
    width: u32,
    accel_flags: u32,
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [4]u32,
};

const FixInfo = extern struct {
    id: [16]u8,
    smem_start: usize,
    smem_len: u32,
    type: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    line_length: u32,
    mmio_start: usize,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [2]u16,
};

/// Pack a colour using the framebuffer's own channel layout, so we don't guess ARGB vs BGRA.
fn pack(v: *const VarInfo, r: u32, g: u32, b: u32, a: u32) u32 {
    const ch = struct {
        fn f(val: u32, bf: Bitfield) u32 {
            if (bf.length == 0) return 0;
            const max = (@as(u32, 1) << @intCast(bf.length)) - 1;
            return ((val * max / 255) & max) << @intCast(bf.offset);
        }
    };
    return ch.f(r, v.red) | ch.f(g, v.green) | ch.f(b, v.blue) | ch.f(a, v.transp);
}

/// Linux syscalls return errors as -4095..-1. On 32-bit, a valid pointer can
/// exceed 2GB and bit-cast to a negative isize, so a plain `< 0` test is wrong.
fn syscallFailed(rc: usize) bool {
    return rc >= @as(usize, @bitCast(@as(isize, -4095)));
}

fn sleepMs(ms: u32) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

pub fn main() !void {
    const rc = linux.openat(linux.AT.FDCWD, "/dev/fb0", .{ .ACCMODE = .RDWR }, 0);
    if (syscallFailed(rc)) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    var vi: VarInfo = undefined;
    var fi: FixInfo = undefined;
    if (linux.ioctl(fd, FBIOGET_VSCREENINFO, @intFromPtr(&vi)) != 0) return error.VScreenInfo;
    if (linux.ioctl(fd, FBIOGET_FSCREENINFO, @intFromPtr(&fi)) != 0) return error.FScreenInfo;

    std.debug.print(
        \\fb: {s}
        \\  {d}x{d} (virtual {d}x{d}, offset {d},{d}) {d}bpp stride {d}
        \\  R off={d} len={d}  G off={d} len={d}  B off={d} len={d}  A off={d} len={d}
        \\
    , .{
        std.mem.sliceTo(&fi.id, 0),
        vi.xres,
        vi.yres,
        vi.xres_virtual,
        vi.yres_virtual,
        vi.xoffset,
        vi.yoffset,
        vi.bits_per_pixel,
        fi.line_length,
        vi.red.offset,
        vi.red.length,
        vi.green.offset,
        vi.green.length,
        vi.blue.offset,
        vi.blue.length,
        vi.transp.offset,
        vi.transp.length,
    });

    if (vi.bits_per_pixel != 32) return error.Not32Bpp;

    std.debug.print("  smem_start=0x{x} smem_len={d} visual={d} type={d}\n", .{ fi.smem_start, fi.smem_len, fi.visual, fi.type });
    const maplen: usize = fi.line_length * vi.yres_virtual;
    const mrc = linux.mmap(null, maplen, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (syscallFailed(mrc)) {
        std.debug.print("mmap({d}) failed: errno {d}\n", .{ maplen, @as(isize, @bitCast(mrc)) * -1 });
        return error.MmapFailed;
    }
    const map: []align(4096) u8 = @as([*]align(4096) u8, @ptrFromInt(mrc))[0..maplen];
    defer _ = linux.munmap(map.ptr, maplen);

    // Centred box on the page that is currently being scanned out.
    const bw: u32 = 400;
    const bh: u32 = 300;
    const x0 = (vi.xres - bw) / 2;
    const y0 = vi.yoffset + (vi.yres - bh) / 2;
    const red = pack(&vi, 255, 0, 0, 255);

    // Save what was there so the flash restores cleanly instead of leaving a red hole.
    var saved: [bh][bw]u32 = undefined;
    for (0..bh) |row| {
        const off = (y0 + row) * fi.line_length + x0 * 4;
        const line: [*]const u32 = @ptrCast(@alignCast(map.ptr + off));
        @memcpy(&saved[row], line[0..bw]);
    }

    for (0..6) |i| {
        for (0..bh) |row| {
            const off = (y0 + row) * fi.line_length + x0 * 4;
            const line: [*]u32 = @ptrCast(@alignCast(map.ptr + off));
            if (i % 2 == 0) @memset(line[0..bw], red) else @memcpy(line[0..bw], &saved[row]);
        }
        sleepMs(500);
    }

    // Always leave the screen as we found it.
    for (0..bh) |row| {
        const off = (y0 + row) * fi.line_length + x0 * 4;
        const line: [*]u32 = @ptrCast(@alignCast(map.ptr + off));
        @memcpy(line[0..bw], &saved[row]);
    }
    std.debug.print("done\n", .{});
}
