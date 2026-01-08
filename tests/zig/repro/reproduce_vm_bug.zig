const std = @import("std");
const mz = @import("mathzig");

test "VM Bug: matrix persistence" {
    const allocator = std.testing.allocator;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const r1 = try ctx.eval("x = [1, 2; 3, 4]");
    defer r1.release();
    
    const result = try ctx.eval("x * 2");
    defer result.release();
    try std.testing.expect(result.tag == .matrix);
    const m = result.data.matrix;
    
    try std.testing.expectEqual(@as(f64, 2), m.get(0, 0));
}
