//! msdf-zig polynomial solvers with a local sin/cos pair for the cubic case.
//!
//! In this branch theta is constrained to [0, pi/3]. A short Taylor pair is
//! accurate well beyond the solver's tolerance and, importantly, cannot call
//! the app's soft-float compiler-rt `sincos` across the private hard-FP kernel.

const std = @import("std");

pub fn solveQuadratic(roots: *[2]f64, a: f64, b: f64, c: f64) u8 {
    if (a == 0 or @abs(b) > 1e12 * @abs(a)) {
        if (b == 0) return 0;
        roots[0] = -c / b;
        return 1;
    }
    const dscr = b * b - 4.0 * a * c;
    if (dscr > 0) {
        const dscr_sqrt = @sqrt(dscr);
        roots[0] = (-b + dscr_sqrt) / (2 * a);
        roots[1] = (-b - dscr_sqrt) / (2 * a);
        return 2;
    } else if (dscr == 0) {
        roots[0] = -b / (2 * a);
        return 1;
    } else return 0;
}

fn sinCosThirdPi(x: f64) struct { sin: f64, cos: f64 } {
    const x2 = x * x;
    const sin_poly = 1.0 + x2 * (-1.0 / 6.0 + x2 * (1.0 / 120.0 + x2 * (-1.0 / 5040.0 + x2 * (1.0 / 362880.0 - x2 / 39916800.0))));
    const cos_poly = 1.0 + x2 * (-1.0 / 2.0 + x2 * (1.0 / 24.0 + x2 * (-1.0 / 720.0 + x2 * (1.0 / 40320.0 + x2 * (-1.0 / 3628800.0 + x2 / 479001600.0)))));
    return .{ .sin = x * sin_poly, .cos = cos_poly };
}

fn solveCubicNormed(roots: *[3]f64, a: f64, b: f64, c: f64) u8 {
    const a2 = a * a;
    var q = 1.0 / 9.0 * (a2 - 3 * b);
    const r = 1.0 / 54.0 * (a * (2 * a2 - 9 * b) + 27 * c);
    const r2 = r * r;
    const q3 = q * q * q;
    const one_third = 1.0 / 3.0;
    const mod_a = a * one_third;
    if (r2 < q3) {
        var t = r / @sqrt(q3);
        if (t < -1) t = -1;
        if (t > 1) t = 1;
        const theta = one_third * std.math.acos(t);
        q = -2 * @sqrt(q);
        const trig = sinCosThirdPi(theta);
        const half_sqrt3 = 0.86602540378443864676;
        roots[0] = q * trig.cos - mod_a;
        roots[1] = q * (-0.5 * trig.cos - half_sqrt3 * trig.sin) - mod_a;
        roots[2] = q * (-0.5 * trig.cos + half_sqrt3 * trig.sin) - mod_a;
        return 3;
    } else {
        const u = @as(f64, (if (r < 0) 1.0 else -1.0)) * std.math.cbrt(@abs(r) + @sqrt(r2 - q3));
        const v = if (u == 0) 0 else q / u;
        roots[0] = (u + v) - mod_a;
        if (u == v or @abs(u - v) < 1e-12 * @abs(u + v)) {
            roots[1] = -0.5 * (u + v) - mod_a;
            return 2;
        }
        return 1;
    }
}

pub fn solveCubic(x: *[3]f64, a: f64, b: f64, c: f64, d: f64) u8 {
    if (a != 0) {
        const bn = b / a;
        if (@abs(bn) < 1e6) return solveCubicNormed(x, bn, c / a, d / a);
    }
    return solveQuadratic(@ptrCast(x), b, c, d);
}

test "local sin/cos pair is accurate on its complete domain" {
    var i: usize = 0;
    while (i <= 1000) : (i += 1) {
        const x = std.math.pi / 3.0 * @as(f64, @floatFromInt(i)) / 1000.0;
        const got = sinCosThirdPi(x);
        try std.testing.expectApproxEqAbs(@sin(x), got.sin, 4e-10);
        try std.testing.expectApproxEqAbs(@cos(x), got.cos, 4e-11);
    }
}
