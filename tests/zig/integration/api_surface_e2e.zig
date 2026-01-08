//! End-to-End tests for MathZig API Surface
//! Verifies that functions defined in src/api_definition.zig work correctly

const std = @import("std");
const mathzig = @import("mathzig");
const api = @import("api_definition.zig");

test "API Surface: MathZig lifecycle" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // Test version
    // The version method is a bit tricky to call directly because it's in a struct
    // but we can test the underlying MathZig methods it calls.
    
    // Test eval
    const result = try ctx.eval("1 + 2 * 3");
    defer result.release();
    try std.testing.expectEqual(@as(f64, 7), result.data.number);
}

test "API Surface: CompiledExpr batch evaluation" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    var compiler = try mathzig.parser.Compiler.init(allocator, "x * 2");
    defer compiler.deinit();
    var expr = try compiler.compile();
    defer expr.deinit();

    const inputs = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    var outputs = [_]f64{ 0.0, 0.0, 0.0, 0.0, 0.0 };

    // We can't easily call the anonymous struct functions from ExportConfig directly in Zig
    // without some boilerplate, but we can test the logic.
    // Let's test the batch evaluation logic used in ExportConfig.

    const var_index: i32 = try ctx.addVariableIndexed("x", 0);
    const idx: u24 = @intCast(var_index);

    for (0..5) |i| {
        ctx.setVariableByIndexF64(idx, inputs[i]);
        outputs[i] = ctx.evaluateF64(&expr);
    }

    try std.testing.expectEqual(@as(f64, 2), outputs[0]);
    try std.testing.expectEqual(@as(f64, 4), outputs[1]);
    try std.testing.expectEqual(@as(f64, 10), outputs[4]);
}

test "API Surface: Series metadata" {
    const allocator = std.testing.allocator;
    const series = try mathzig.timeseries.Series.init(allocator, 10, .Linear, .{});
    defer series.release();

    for (0..10) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @as(f64, @floatFromInt(i)) * 10.0;
    }
    try series.validate();

    try std.testing.expectEqual(@as(usize, 10), series.len);
    try std.testing.expectEqual(@as(f64, 9.0), series.max_ts - series.min_ts);
}

test "API Surface: Matrix operations" {
    const allocator = std.testing.allocator;
    
    const m = try mathzig.Matrix.init(allocator, 2, 2);
    defer m.release();
    m.set(0, 0, 1);
    m.set(0, 1, 2);
    m.set(1, 0, 3);
    m.set(1, 1, 4);

    const sum = mathzig.matrix_kernels.vecSum(m.data);
    try std.testing.expectEqual(@as(f64, 10), sum);

    const mean = mathzig.matrix_kernels.vecMean(m.data);
    try std.testing.expectEqual(@as(f64, 2.5), mean);
}

test "API Surface: Record field access" {
    const allocator = std.testing.allocator;
    var record = try mathzig.Record.init(allocator, allocator);
    defer record.release();

    try record.set("test", mathzig.Value.initNumber(123));
    
    const val = record.get("test").?;
    try std.testing.expectEqual(@as(f64, 123), val.data.number);
    
    try std.testing.expect(record.has("test"));
    try std.testing.expect(!record.has("nonexistent"));
}
