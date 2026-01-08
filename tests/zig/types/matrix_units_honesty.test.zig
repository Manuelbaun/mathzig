//! task-15 / D6–D7: unit-bearing matrix literals are rejected with one stable
//! error on both mat_create (non-fused) and mat_create_3 (fused 3×1).
//! Homogeneous numeric matrix * unit remains valid.
//! Exact tests — independent of tests/parity/compare.ts.

const std = @import("std");
const mathzig = @import("mathzig");

test "mat_create rejects unit-bearing 1x2 literal (non-fused path)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // 1×2 never fuses to mat_create_3 (only 3×1 does).
    const err = ctx.eval("[1m, 2m]");
    try std.testing.expectError(error.MatrixUnitElementUnsupported, err);
}

test "mat_create_3 rejects unit-bearing 3x1 column (fused path)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // operand 4099 → optimizer rewrites mat_create → mat_create_3.
    const err = ctx.eval("[1m; 2m; 3m]");
    try std.testing.expectError(error.MatrixUnitElementUnsupported, err);
}

test "homogeneous matrix times unit remains valid" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("[1, 2] * m");
    defer res.release();
    try std.testing.expectEqual(mathzig.ValueTag.matrix, res.tag);
    try std.testing.expectEqual(@as(u32, 1), res.data.matrix.rows);
    try std.testing.expectEqual(@as(u32, 2), res.data.matrix.cols);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), res.data.matrix.data[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), res.data.matrix.data[1], 1e-12);
}

test "conv of homogeneous matrix*unit yields elementwise target units" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("conv([1, 2] * m, cm)");
    defer res.release();
    try std.testing.expectEqual(mathzig.ValueTag.matrix, res.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), res.data.matrix.data[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), res.data.matrix.data[1], 1e-12);
}

test "conv of unit-bearing matrix literal is MatrixUnitElementUnsupported" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const err = ctx.eval("conv([1m, 2m], cm)");
    try std.testing.expectError(error.MatrixUnitElementUnsupported, err);
}

test "scalar unit dimensions preserved (exact, not via compare.ts)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("(2 * m) + (50 * cm)");
    defer res.release();
    try std.testing.expectEqual(mathzig.ValueTag.unit, res.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), res.data.unit.value, 1e-12);
    try std.testing.expectEqual(@as(i8, 1), res.data.unit.info.dimensions.l);
    try std.testing.expectEqual(@as(i8, 0), res.data.unit.info.dimensions.m);
    try std.testing.expectEqual(@as(i8, 0), res.data.unit.info.dimensions.t);
}

test "dimension mismatch on scalar add is not silent strip" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // VM returns an error-tagged value for dimension mismatch on unit add.
    const res = try ctx.eval("(1 * m) + (1 * kg)");
    defer res.release();
    try std.testing.expect(res.isError());
}
