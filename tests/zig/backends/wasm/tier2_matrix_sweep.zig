//! task-19 P3 — Tier 2 matrix helpers: native `matrix_kernels` edge sweep.
//!
//! ULP notes: kernels are direct f64 arithmetic (0 ULP vs self).
//! det(singular) → 0; matrixInverse singular → false.

const std = @import("std");
const math = std.math;
const mathzig = @import("mathzig");
const kernels = mathzig.matrix_kernels;

test "tier2: determinant 1x1 / 2x2 / singular / large" {
    const allocator = std.testing.allocator;
    {
        const a = [_]f64{7.0};
        const d = try kernels.determinant(1, &a, 1, allocator);
        try std.testing.expectEqual(@as(f64, 7.0), d);
    }
    {
        const a = [_]f64{ 1, 2, 3, 4 };
        const d = try kernels.determinant(2, &a, 2, allocator);
        try std.testing.expect(@abs(d - (-2.0)) < 1e-12);
    }
    {
        const a = [_]f64{ 1, 2, 2, 4 };
        const d = try kernels.determinant(2, &a, 2, allocator);
        try std.testing.expect(@abs(d) < 1e-12);
    }
    {
        const a = [_]f64{ 1e8, 2e8, 3e8, 4e8 };
        const d = try kernels.determinant(2, &a, 2, allocator);
        try std.testing.expect(@abs(d - (-2e16)) / 2e16 < 1e-9);
    }
}

test "tier2: matrixTrace square and non-square" {
    const a = [_]f64{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(f64, 5.0), kernels.matrixTrace(2, 2, &a, 2));
    const b = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const t = kernels.matrixTrace(2, 3, &b, 3);
    try std.testing.expectEqual(@as(f64, 1.0 + 5.0), t);
}

test "tier2: vecDot / vecNorm / vecSum edges" {
    const empty: [0]f64 = .{};
    try std.testing.expectEqual(@as(f64, 0.0), kernels.vecSum(&empty));
    try std.testing.expectEqual(@as(f64, 0.0), kernels.vecNorm(&empty));

    const a = [_]f64{ 3.0, 4.0 };
    try std.testing.expectEqual(@as(f64, 5.0), kernels.vecNorm(&a));
    try std.testing.expectEqual(@as(f64, 7.0), kernels.vecSum(&a));
    try std.testing.expectEqual(@as(f64, 25.0), kernels.vecDot(&a, &a));

    const nans = [_]f64{ 1.0, math.nan(f64), 3.0 };
    try std.testing.expect(math.isNan(kernels.vecSum(&nans)));

    const infs = [_]f64{ math.inf(f64), 1.0 };
    try std.testing.expect(math.isInf(kernels.vecSum(&infs)));

    const den = [_]f64{ math.floatMin(f64), math.floatMin(f64) };
    const s = kernels.vecSum(&den);
    try std.testing.expect(s > 0.0 or s == 0.0);
}

test "tier2: matrixInverse identity-like 2x2" {
    const allocator = std.testing.allocator;
    var a = [_]f64{ 2, 0, 0, 4 };
    const ok = try kernels.matrixInverse(2, &a, 2, allocator);
    try std.testing.expect(ok);
    try std.testing.expect(@abs(a[0] - 0.5) < 1e-12);
    try std.testing.expect(@abs(a[3] - 0.25) < 1e-12);
}

test "tier2: matrixInverse singular returns false" {
    const allocator = std.testing.allocator;
    var a = [_]f64{ 1, 2, 2, 4 };
    const ok = try kernels.matrixInverse(2, &a, 2, allocator);
    try std.testing.expect(!ok);
}

test "tier2: vecCross standard basis" {
    const i = [_]f64{ 1, 0, 0 };
    const j = [_]f64{ 0, 1, 0 };
    const k = kernels.vecCross(&i, &j);
    try std.testing.expectEqual(@as(f64, 0.0), k[0]);
    try std.testing.expectEqual(@as(f64, 0.0), k[1]);
    try std.testing.expectEqual(@as(f64, 1.0), k[2]);
}
