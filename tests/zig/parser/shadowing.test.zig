const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const Value = mathzig.Value;

test "shadowing seconds unit" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const def_source = "f(s) = s^2";
    const def_expr = try ctx.compile(def_source);
    defer ctx.freeExpr(def_expr);

    const def_res = try ctx.evaluate(def_expr);
    defer def_res.release();

    const call_source = "f(10)";
    const call_expr = try ctx.compile(call_source);
    defer ctx.freeExpr(call_expr);

    const call_res = try ctx.evaluate(call_expr);
    defer call_res.release();

    try std.testing.expectEqual(@as(f64, 100), call_res.data.number);
}

test "shadowing built-in function name (sin)" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Shadow 'sin'
    const def_source = "f(sin) = sin^2";
    const def_expr = try ctx.compile(def_source);
    defer ctx.freeExpr(def_expr);

    const def_res = try ctx.evaluate(def_expr);
    defer def_res.release();

    const call_source = "f(4)";
    const call_expr = try ctx.compile(call_source);
    defer ctx.freeExpr(call_expr);

    const call_res = try ctx.evaluate(call_expr);
    defer call_res.release();

    try std.testing.expectEqual(@as(f64, 16), call_res.data.number);
}

test "shadowing unit name with multiplication (min)" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Shadow 'min' (which is both a built-in and a unit)
    const def_source = "f(min) = min * 2";
    const def_expr = try ctx.compile(def_source);
    defer ctx.freeExpr(def_expr);

    const def_res = try ctx.evaluate(def_expr);
    defer def_res.release();

    const call_source = "f(5)";
    const call_expr = try ctx.compile(call_source);
    defer ctx.freeExpr(call_expr);

    const call_res = try ctx.evaluate(call_expr);
    defer call_res.release();

    // Should be 10, not 120 (60 * 2)
    try std.testing.expectEqual(@as(f64, 10), call_res.data.number);
}

test "built-in still works when not shadowed" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const source = "min(10, 20, 5)";
    const expr = try ctx.compile(source);
    defer ctx.freeExpr(expr);

    const res = try ctx.evaluate(expr);
    defer res.release();

    try std.testing.expectEqual(@as(f64, 5), res.data.number);
}

test "unit still works when not shadowed" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const source = "10min";
    const expr = try ctx.compile(source);
    defer ctx.freeExpr(expr);

    const res = try ctx.evaluate(expr);
    defer res.release();

    // 10 minutes = 600 seconds
    try std.testing.expectEqual(@as(f64, 600), res.data.unit.value);
}
