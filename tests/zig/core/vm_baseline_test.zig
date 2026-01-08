const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

fn expectNumber(ctx: *MathZig, expr: []const u8, expected: f64, tol: f64) !void {
    const result = try ctx.eval(expr);
    defer result.release();
    try std.testing.expectEqual(ValueTag.number, result.tag);
    try std.testing.expectApproxEqAbs(expected, result.toNumber().?, tol);
}

test "vm baseline l1 core runtime: builtins and fundamental types" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    try expectNumber(ctx, "sqrt(81) + sin(pi / 2)", 10.0, 1e-12);

    const bool_result = try ctx.eval("1 < 2");
    defer bool_result.release();
    try std.testing.expectEqual(ValueTag.boolean, bool_result.tag);
    try std.testing.expectEqual(true, bool_result.data.boolean);

    const matrix_result = try ctx.eval("[1, 2; 3, 4]");
    defer matrix_result.release();
    try std.testing.expectEqual(ValueTag.matrix, matrix_result.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), matrix_result.data.matrix.get(1, 1), 1e-12);

    const complex_result = try ctx.eval("3 + 4i");
    defer complex_result.release();
    try std.testing.expectEqual(ValueTag.complex, complex_result.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), complex_result.data.complex.re, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), complex_result.data.complex.im, 1e-12);
}

test "vm baseline l2 composition: functions with mixed features" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    try expectNumber(ctx, "f(x) = x^2 + 1; g(y) = f(y) + sum([1, 2, 3]); g(2)", 11.0, 1e-12);
    try expectNumber(ctx, "conv(72 km/h, m/s)", 20.0, 1e-9);
}

test "vm baseline l3 parser ast: stable latex shape checks" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const latex_precedence = try ctx.toLaTeX("1 + 2 * 3 / 4", allocator);
    defer allocator.free(latex_precedence);
    try std.testing.expectEqualStrings("1 + \\frac{2 \\cdot 3}{4}", latex_precedence);

    const latex_grouping = try ctx.toLaTeX("x^2 + sqrt(x)", allocator);
    defer allocator.free(latex_grouping);
    try std.testing.expectEqualStrings("x^{2} + \\sqrt{x}", latex_grouping);
}

test "vm baseline l4 compiled ast executes on vm with correct output" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("x = 5; (x + 3) * 2");
    defer ctx.freeExpr(expr);

    const result = try ctx.evaluate(expr);
    defer result.release();
    try std.testing.expectEqual(ValueTag.number, result.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 16.0), result.toNumber().?, 1e-12);
}
