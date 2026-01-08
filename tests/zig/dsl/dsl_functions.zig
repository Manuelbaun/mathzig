const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "DSL functions: simple unary function" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Define f(x) = x^2
    _ = try ctx.eval("f(x) = x^2");
    
    // Call f(3)
    const res = try ctx.eval("f(3)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.number, res.tag);
    try std.testing.expectEqual(@as(f64, 9), res.data.number);
}

test "DSL functions: multi-argument function" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Define add(a, b) = a + b
    _ = try ctx.eval("add(a, b) = a + b");
    
    // Call add(10, 20)
    const res = try ctx.eval("add(10, 20)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.number, res.tag);
    try std.testing.expectEqual(@as(f64, 30), res.data.number);
}

test "DSL functions: nested calls" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = try ctx.eval("my_square(x) = x^2");
    _ = try ctx.eval("my_square(5)");
    _ = try ctx.eval("double(x) = x * 2");
    _ = try ctx.eval("composed(x) = my_square(double(x))");
    
    // Call composed(3) -> square(double(3)) -> square(6) -> 36
    const res = try ctx.eval("composed(3)");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.number, res.tag);
    try std.testing.expectEqual(@as(f64, 36), res.data.number);
}

test "DSL functions: closure-like behavior (global access)" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = try ctx.eval("a = 10");
    _ = try ctx.eval("f(x) = x + a");
    
    const res1 = try ctx.eval("f(5)");
    defer res1.release();
    try std.testing.expectEqual(@as(f64, 15), res1.data.number);
    
    // Update global a
    _ = try ctx.eval("a = 20");
    const res2 = try ctx.eval("f(5)");
    defer res2.release();
    try std.testing.expectEqual(@as(f64, 25), res2.data.number);
}

test "DSL functions: nested scopes" {

    const allocator = std.testing.allocator;

    var ctx = try MathZig.init(allocator);

    defer ctx.deinit();

    // Test with nested function accessing outer scope variable
    _ = try ctx.eval("outer(a) = { inner(x) = x + a; inner(10) }");

    const res = try ctx.eval("outer(5)");

    defer res.release();

    try std.testing.expectEqual(@as(f64, 15), res.data.number);

}
