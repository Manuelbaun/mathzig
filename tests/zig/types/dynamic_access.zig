const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const Value = mathzig.Value;

test "Dynamic Field Access: record[\"a\"]" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Setup: r = {a: 42}
    const r1 = try ctx.eval("r = {a: 42}");
    defer r1.release();
    
    // Test static optimization (string literal)
    const result1 = try ctx.eval("r[\"a\"]");
    defer result1.release();
    try std.testing.expectEqual(@as(f64, 42.0), result1.data.number);

    // Test dynamic lookup (variable key)
    const r2 = try ctx.eval("k = \"a\"");
    defer r2.release();
    const result2 = try ctx.eval("r[k]");
    defer result2.release();
    try std.testing.expectEqual(@as(f64, 42.0), result2.data.number);
}

test "Dynamic Field Access: nested and expressions" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const r1 = try ctx.eval("r = {a: {b: 100}}");
    defer r1.release();
    const r2 = try ctx.eval("key_a = \"a\"");
    defer r2.release();
    const r3 = try ctx.eval("key_b = \"b\"");
    defer r3.release();
    
    const res_a = try ctx.eval("r[key_a]");
    defer res_a.release();
    try std.testing.expectEqual(mathzig.ValueTag.record, res_a.tag);

    const result = try ctx.eval("r[key_a][key_b]");
    defer result.release();
    try std.testing.expectEqual(@as(f64, 100.0), result.data.number);
}