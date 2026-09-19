//! Measures double-precision throughput on the device. Its base-register float
//! ABI does not require emulation, but Zig's `gnueabi` target currently emits it.
//!   zig build -Dapp=fptest && zig build run -Dapp=fptest
const std = @import("std");
const linux = std.os.linux;

fn now() f64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

/// `noinline` + a volatile-ish accumulator keeps the optimiser from folding the
/// loop away, which would make any timing meaningless.
noinline fn fmaChain(n: u32, seed: f64) f64 {
    var a: f64 = seed;
    var b: f64 = 1.0000001;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a = a * b + 0.5;
        b = b * 1.0000001;
        if (a > 1e250) a *= 1e-250;
    }
    return a + b;
}

noinline fn f32Chain(n: u32, seed: f32) f32 {
    var a: f32 = seed;
    var b: f32 = 1.0001;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a = a * b + 0.5;
        b = b * 1.0001;
        if (a > 1e30) a *= 1e-30;
    }
    return a + b;
}

noinline fn intChain(n: u32, seed: u64) u64 {
    var a: u64 = seed;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a = a *% 6364136223846793005 +% 1442695040888963407;
    }
    return a;
}

/// The same 2 flops, but with the FPU reached directly via inline VFP asm.
/// Zig's `gnueabi` target sets LLVM float-abi=soft, which emits __aeabi_* library
/// calls for every operation; the hardware FPU is still physically there and this
/// proves it. Argument passing stays base-ABI, so this is ABI-safe.
noinline fn vfpChain(n: u32, seed: f64) f64 {
    var a: f64 = seed;
    var b: f64 = 1.0000001;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        asm volatile (
            \\.fpu vfpv4
            \\vldr d0, [%[pa]]
            \\vldr d1, [%[pb]]
            \\vmov.f64 d2, #0.5
            \\vmul.f64 d0, d0, d1
            \\vadd.f64 d0, d0, d2
            \\vstr d0, [%[pa]]
            :
            : [pa] "r" (&a),
              [pb] "r" (&b),
            : .{ .d0 = true, .d1 = true, .d2 = true, .memory = true });
    }
    return a + b;
}

pub fn main() !void {
    const N: u32 = 20_000_000;
    std.debug.print("{d} iterations each, 2 flops per iteration\n\n", .{N});

    var t = now();
    const rd = fmaChain(N, 1.0);
    const dt_d = now() - t;

    t = now();
    const rf = f32Chain(N, 1.0);
    const dt_f = now() - t;

    t = now();
    const ri = intChain(N, 1);
    const dt_i = now() - t;

    t = now();
    const rv = vfpChain(N, 1.0);
    const dt_v = now() - t;

    std.debug.print("f64 : {d:.3} s  ({d:.1} Mflop/s)\n", .{ dt_d, 2.0 * @as(f64, @floatFromInt(N)) / dt_d / 1e6 });
    std.debug.print("f32 : {d:.3} s  ({d:.1} Mflop/s)\n", .{ dt_f, 2.0 * @as(f64, @floatFromInt(N)) / dt_f / 1e6 });
    std.debug.print("u64 : {d:.3} s  (integer reference)\n", .{dt_i});
    std.debug.print("f64 via inline VFP asm : {d:.3} s  ({d:.1} Mflop/s)\n", .{ dt_v, 2.0 * @as(f64, @floatFromInt(N)) / dt_v / 1e6 });
    std.debug.print("\nsoft-float f64 / int      : {d:.2}x\n", .{dt_d / dt_i});
    std.debug.print("soft-float f64 / VFP f64  : {d:.2}x  <-- cost of LLVM float-abi=soft\n", .{dt_d / dt_v});
    std.debug.print("(sink {d:.3} {d:.3} {d} {d:.3})\n", .{ rd, rf, ri, rv });
}
