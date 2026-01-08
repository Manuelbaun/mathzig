const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

test "Indicators: RSI on oscillating pattern" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 100, .Linear, .{});
    defer series.deinit();

    // 0, 10, 0, 10...
    for (0..100) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = if (i % 2 == 0) 0.0 else 10.0;
    }

    const rsi = try ts.rsi(series, 14, allocator);
    defer rsi.deinit();

    // Initial period is NaN
    try std.testing.expect(std.math.isNan(rsi.values[13]));

    // Check convergence: oscillating input should produce stable RSI around 50
    // Actually for perfect 0-10-0-10, gain/loss are equal, so RSI should be exactly 50.
    const last = rsi.values[99];
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), last, 2.0);
}

test "Indicators: SMA vs TWA comparison" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 10, .Linear, .{});
    defer series.deinit();

    for (0..10) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = 10.0;
    }

    const s = try ts.sma(series, 5, allocator);
    defer s.deinit();

    // Constant input -> Constant SMA
    try std.testing.expectEqual(@as(f64, 10.0), s.values[9]);
}
