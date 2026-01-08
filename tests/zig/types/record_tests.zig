const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;
const Value = mathzig.Value;

// MathZig Memory Management in Tests:
// eval() returns a Value that has been RETAINED (ref_count incremented).
// To avoid leaks, we MUST call release() on the evaluation result if it is a reference type.
// Reference types (Series, Matrix, Record) are also tracked by VM intermediates or variables.

test "record literal and member access" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Test record literal
    const res = try ctx.eval("{ a: 1, b: 2 }");
    defer res.release();
    try std.testing.expectEqual(ValueTag.record, res.tag);
    try std.testing.expectEqual(@as(usize, 2), res.data.record.len());
    
    const a_val = res.data.record.get("a").?;
    try std.testing.expectEqual(@as(f64, 1), a_val.data.number);

    const b_val = res.data.record.get("b").?;
    try std.testing.expectEqual(@as(f64, 2), b_val.data.number);

    // Test basic member access
    const res2 = try ctx.eval("{ a: 10, b: 20 }.a");
    defer res2.release();
    try std.testing.expectEqual(ValueTag.number, res2.tag);
    try std.testing.expectEqual(@as(f64, 10), res2.data.number);

    // Test member access in expression
    const res3 = try ctx.eval("{ a: 10, b: 20 }.a + { a: 5, b: 15 }.b");
    defer res3.release();
    try std.testing.expectEqual(ValueTag.number, res3.tag);
    try std.testing.expectEqual(@as(f64, 25), res3.data.number);
}

test "record member access from variable" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const r1 = try ctx.eval("r = { x: 100, y: 200 }");
    defer r1.release();
    const res = try ctx.eval("r.x + r.y");
    defer res.release();
    
    try std.testing.expectEqual(ValueTag.number, res.tag);
    try std.testing.expectEqual(@as(f64, 300), res.data.number);
}

test "nested record member access" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("{ a: { b: 42 } }.a.b");
    defer res.release();
    try std.testing.expectEqual(ValueTag.number, res.tag);
    try std.testing.expectEqual(@as(f64, 42), res.data.number);
}

test "bollinger bands member access" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Create a series
    const s_ptr = try mathzig.timeseries.Series.init(allocator, 5, .Linear, .{});
    // setVariable retains it
    ctx.setVariable("s", Value.initSeries(s_ptr));
    // Release our initial reference from init()
    s_ptr.release();
    
    for (0..5) |i| {
        s_ptr.timestamps[i] = @floatFromInt(i + 1);
        s_ptr.values[i] = @floatFromInt(i + 1);
    }
    
    // Calculate bollinger bands
    const b_res = try ctx.eval("b = bollinger(s, 2, 2.0)");
    defer b_res.release();
    
    // Access bands
    const upper = try ctx.eval("b.upper");
    defer upper.release();
    const middle = try ctx.eval("b.middle");
    defer middle.release();
    const lower = try ctx.eval("b.lower");
    defer lower.release();
    
    try std.testing.expectEqual(ValueTag.series, upper.tag);
    try std.testing.expectEqual(ValueTag.series, middle.tag);
    try std.testing.expectEqual(ValueTag.series, lower.tag);
}

test "macd member access" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Create a series
    const s_ptr = try mathzig.timeseries.Series.init(allocator, 10, .Linear, .{});
    ctx.setVariable("s", Value.initSeries(s_ptr));
    s_ptr.release();

    for (0..10) |i| {
        s_ptr.timestamps[i] = @floatFromInt(i + 1);
        s_ptr.values[i] = @floatFromInt(i + 1);
    }
    
    // Calculate MACD
    const m_res = try ctx.eval("m = macd(s, 2, 5, 3)");
    defer m_res.release();
    
    // Access components
    const macd_line = try ctx.eval("m.macd");
    defer macd_line.release();
    const signal_line = try ctx.eval("m.signal");
    defer signal_line.release();
    const histogram = try ctx.eval("m.histogram");
    defer histogram.release();
    
    try std.testing.expectEqual(ValueTag.series, macd_line.tag);
    try std.testing.expectEqual(ValueTag.series, signal_line.tag);
    try std.testing.expectEqual(ValueTag.series, histogram.tag);
}
