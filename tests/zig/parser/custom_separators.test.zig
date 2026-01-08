const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;

test "custom separators - matrix row pipe" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Set row separator to pipe
    _ = try ctx.eval("config({ row_separator: \"|\" })");
    
    const res = try ctx.eval("[1, 2 | 3, 4]");
    defer res.release();
    try std.testing.expectEqual(mathzig.ValueTag.matrix, res.tag);
    try std.testing.expectEqual(@as(u32, 2), res.data.matrix.rows);
    try std.testing.expectEqual(@as(u32, 2), res.data.matrix.cols);
    try std.testing.expectEqual(@as(f64, 3), res.data.matrix.get(1, 0));

    // Reset
    _ = try ctx.eval("config({ row_separator: \";\" })");
}

test "custom separators - verify standard decimal remains dot" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("1.5 + 2.5");
    defer res.release();
    try std.testing.expectEqual(@as(f64, 4.0), res.toNumber().?);
}

test "custom separators - verify standard list remains comma" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("[1, 2, 3]");
    defer res.release();
    try std.testing.expectEqual(@as(u32, 3), res.data.matrix.cols);
}