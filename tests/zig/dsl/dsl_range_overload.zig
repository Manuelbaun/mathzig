const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "DSL range: aggregation vs generation" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 1. Generation: range(0, 5) -> [0, 1, 2, 3, 4]
    {
        const res = try ctx.eval("range(0, 5)");
        defer res.release();
        try std.testing.expectEqual(ValueTag.matrix, res.tag);
        try std.testing.expectEqual(@as(u32, 5), res.data.matrix.cols);
    }

    // 2. Aggregation: range(s) -> max - min
    {
        // First create a series
        _ = try ctx.eval("s = series([0, 1, 2], [10, 20, 30])");
        
        const res = try ctx.eval("range(s)");
        defer res.release();
        try std.testing.expectEqual(ValueTag.number, res.tag);
        try std.testing.expectEqual(@as(f64, 20), res.data.number); // 30 - 10
    }

    // 3. Generation with 3 args: range(0, 10, 2)
    {
        const res = try ctx.eval("range(0, 10, 2)");
        defer res.release();
        try std.testing.expectEqual(ValueTag.matrix, res.tag);
        try std.testing.expectEqual(@as(u32, 5), res.data.matrix.cols);
        try std.testing.expectEqual(@as(f64, 0), res.data.matrix.get(0, 0));
        try std.testing.expectEqual(@as(f64, 8), res.data.matrix.get(0, 4));
    }
}

test "DSL range: failure cases" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // range(0, 5, 2, 1) -> Too many args
    const res = ctx.eval("range(0, 5, 2, 1)");
    if (res) |r| {
        r.release();
        return error.ExpectedCompileError;
    } else |err| {
        try std.testing.expect(err == error.CompileError);
    }
}
