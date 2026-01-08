const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "Matrix slicing: scalar access" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const assign = try ctx.eval("A = [1, 2, 3; 4, 5, 6]");
    assign.release();
    const res = try ctx.eval("A[0, 0]");
    defer res.release();
    try std.testing.expectEqual(@as(f64, 1), res.data.number);
    
    const res2 = try ctx.eval("A[1, 2]");
    defer res2.release();
    try std.testing.expectEqual(@as(f64, 6), res2.data.number);
}

test "Matrix slicing: row slice" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const assign = try ctx.eval("A = [1, 2, 3; 4, 5, 6]");
    assign.release();
    // A[0, :] -> [1, 2, 3] (1x3 matrix)
    const res = try ctx.eval("A[0, :]");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 1), m.rows);
    try std.testing.expectEqual(@as(u32, 3), m.cols);
    try std.testing.expectEqual(@as(f64, 1), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 2), m.get(0, 1));
    try std.testing.expectEqual(@as(f64, 3), m.get(0, 2));
}

test "Matrix slicing: col slice" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const assign = try ctx.eval("A = [1, 2, 3; 4, 5, 6]");
    assign.release();
    // A[:, 1] -> [2; 5] (2x1 matrix)
    const res = try ctx.eval("A[:, 1]");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 2), m.rows);
    try std.testing.expectEqual(@as(u32, 1), m.cols);
    try std.testing.expectEqual(@as(f64, 2), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 5), m.get(1, 0));
}

test "Matrix slicing: submatrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const assign = try ctx.eval("A = [1, 2, 3, 4; 5, 6, 7, 8; 9, 10, 11, 12]");
    assign.release();
    // A[0:2, 1:3] -> [2, 3; 6, 7]
    const res = try ctx.eval("A[0:2, 1:3]");
    defer res.release();
    
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 2), m.rows);
    try std.testing.expectEqual(@as(u32, 2), m.cols);
    try std.testing.expectEqual(@as(f64, 2), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 3), m.get(0, 1));
    try std.testing.expectEqual(@as(f64, 6), m.get(1, 0));
    try std.testing.expectEqual(@as(f64, 7), m.get(1, 1));
}