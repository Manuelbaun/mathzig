const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "Matrix: concat vertical" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const a = try ctx.eval("A = [1, 2]");
    a.release();
    const b = try ctx.eval("B = [3, 4]");
    b.release();
    // concat(A, B) -> [1, 2; 3, 4]
    const res = try ctx.eval("concat(A, B)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 2), m.rows);
    try std.testing.expectEqual(@as(u32, 2), m.cols);
    try std.testing.expectEqual(@as(f64, 1), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 2), m.get(0, 1));
    try std.testing.expectEqual(@as(f64, 3), m.get(1, 0));
    try std.testing.expectEqual(@as(f64, 4), m.get(1, 1));
}

test "Matrix: concat horizontal" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // A: 2x1, B: 2x1
    const a = try ctx.eval("A = [1; 2]");
    a.release();
    const b = try ctx.eval("B = [3; 4]");
    b.release();
    // concat(A, B, 1) -> [1, 3; 2, 4]
    const res = try ctx.eval("concat(A, B, 1)");
    defer res.release();
    
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 2), m.rows);
    try std.testing.expectEqual(@as(u32, 2), m.cols);
    try std.testing.expectEqual(@as(f64, 1), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 3), m.get(0, 1));
    try std.testing.expectEqual(@as(f64, 2), m.get(1, 0));
    try std.testing.expectEqual(@as(f64, 4), m.get(1, 1));
}

test "Matrix: flatten" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const assign = try ctx.eval("A = [1, 2; 3, 4]");
    assign.release();
    
    // flatten(A) -> [1; 2; 3; 4] (4x1)
    const res = try ctx.eval("flatten(A)");
    defer res.release();
    
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 4), m.rows);
    try std.testing.expectEqual(@as(u32, 1), m.cols);
    try std.testing.expectEqual(@as(f64, 1), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 4), m.get(3, 0));
}