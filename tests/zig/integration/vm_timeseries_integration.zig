const std = @import("std");
const mz = @import("mathzig");
const VM = mz.VM;
const Value = mz.Value;
const bytecode = @import("mathzig").CompiledExpr; // Need access to internals or use compiler
// Actually, using MathZig context is easier as it handles compilation.

test "VM Integration: TWA of Series" {
    const allocator = std.testing.allocator;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Manually create a series and inject it
    const series = try mz.timeseries.Series.init(allocator, 2, .Linear, .{});
    // series is now owned by VM after setVariable, but we have 1 initial ref from init()
    defer series.release(); 
    
    series.timestamps[0] = 0; series.values[0] = 10;
    series.timestamps[1] = 100; series.values[1] = 20;
    try series.validate();

    ctx.setVariable("data", Value.initSeries(series));

    // Compile and run "twa(data)"
    const result = try ctx.eval("twa(data)");
    defer result.release();
    
    // TWA of 10->20 over 100s is (10+20)/2 = 15.
    try std.testing.expectEqual(mz.ValueTag.number, result.tag);
    try std.testing.expectEqual(@as(f64, 15.0), result.data.number);
}

test "VM Integration: Derivative" {
    const allocator = std.testing.allocator;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const series = try mz.timeseries.Series.init(allocator, 2, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 0; series.values[0] = 0;
    series.timestamps[1] = 10; series.values[1] = 100; // slope 10
    try series.validate();

    ctx.setVariable("x", Value.initSeries(series));

    const result = try ctx.eval("derivative(x)");
    defer result.release();
    
    // Result should be a Series
    try std.testing.expect(result.isSeries());
    const out = result.data.series;
    
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(f64, 10.0), out.values[0]);
}

test "VM Integration: series constructor" {
    const allocator = std.testing.allocator;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Use DSL to create a series from two matrices
    const result = try ctx.eval("series([0, 10, 20], [100, 110, 120])");
    defer result.release();
    
    try std.testing.expect(result.isSeries());
    const s = result.data.series;

    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(f64, 10.0), s.timestamps[1]);
    try std.testing.expectEqual(@as(f64, 110.0), s.values[1]);
}

test "VM Integration: twa with where clause" {
    const allocator = std.testing.allocator;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Create a series: [0, 10, 20, 30] with values [10, 20, 0, 10]
    // Values > 5: [10, 20, 10] at times [0, 10, 30]
    const result = try ctx.eval("twa(series([0, 10, 20, 30], [10, 20, 0, 10])) where value > 5");
    defer result.release();
    
    try std.testing.expectEqual(mz.ValueTag.number, result.tag);
    try std.testing.expectEqual(@as(f64, 15.0), result.data.number);
}

test "VM Integration: Series arithmetic" {
    const allocator = std.testing.allocator;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const r1 = try ctx.eval("s1 = series([0, 20], [10, 20])");
    defer r1.release();

    const result = try ctx.eval("series([0, 20], [10, 20]) + series([10, 30], [100, 200])");
    defer result.release();
    
    try std.testing.expect(result.isSeries());
    const s = result.data.series;

    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expect(std.math.isNan(s.values[0]));
    try std.testing.expectEqual(@as(f64, 115.0), s.values[1]);
    try std.testing.expectEqual(@as(f64, 170.0), s.values[2]);
    try std.testing.expect(std.math.isNan(s.values[3]));
}



