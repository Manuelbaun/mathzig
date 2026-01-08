const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "DSL generators: range" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // range(0, 5) -> [0, 1, 2, 3, 4]
    const res = try ctx.eval("range(0, 5)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 1), m.rows);
    try std.testing.expectEqual(@as(u32, 5), m.cols);
    try std.testing.expectEqual(@as(f64, 0), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 4), m.get(0, 4));
}

test "DSL generators: range with step" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // range(0, 5, 2) -> [0, 2, 4]
    const res = try ctx.eval("range(0, 5, 2)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 1), m.rows);
    try std.testing.expectEqual(@as(u32, 3), m.cols);
    try std.testing.expectEqual(@as(f64, 0), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 2), m.get(0, 1));
    try std.testing.expectEqual(@as(f64, 4), m.get(0, 2));
}

test "DSL generators: linspace" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // linspace(0, 10, 5) -> [0, 2.5, 5, 7.5, 10]
    const res = try ctx.eval("linspace(0, 10, 5)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 1), m.rows);
    try std.testing.expectEqual(@as(u32, 5), m.cols);
    try std.testing.expectEqual(@as(f64, 0), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 5), m.get(0, 2));
    try std.testing.expectEqual(@as(f64, 10), m.get(0, 4));
}

test "DSL generators: logspace" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // logspace(0, 2, 3) -> [1, 10, 100]
    const res = try ctx.eval("logspace(0, 2, 3)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 1), m.rows);
    try std.testing.expectEqual(@as(u32, 3), m.cols);
    try std.testing.expectApproxEqAbs(@as(f64, 1), m.get(0, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), m.get(0, 1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), m.get(0, 2), 0.0001);
}
