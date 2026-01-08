const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

test "Calculus: Derivative of irregular sine wave" {
    const allocator = std.testing.allocator;
    const len = 100;
    const series = try ts.Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    // Generate sin(t) sampled at irregular intervals
    var t: f64 = 0;
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    for (0..len) |i| {
        series.timestamps[i] = t;
        series.values[i] = @sin(t);
        // Random step between 0.01 and 0.2
        t += 0.01 + random.float(f64) * 0.19;
    }
    try series.validate();

    const deriv = try ts.derivative(series, allocator);
    defer deriv.deinit();

    // Derivative of sin(t) is cos(t)
    // Check accuracy (finite difference approximation error)
    for (0..deriv.len) |i| {
        const expected = @cos(deriv.timestamps[i]);
        const actual = deriv.values[i];
        // Tolerance: depends on step size, roughly 0.1 for this coarseness
        try std.testing.expectApproxEqAbs(expected, actual, 0.1);
    }
}

test "Calculus: Integral of step function (gap handling)" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 4, .Step, .{});
    defer series.deinit();

    // Value 10 for 5 seconds
    series.timestamps[0] = 0; series.values[0] = 10;
    series.timestamps[1] = 5; series.values[1] = 10;
    
    // Gap of 100 seconds where value is 0
    series.timestamps[2] = 105; series.values[2] = 0;
    
    // Value 20 for 10 seconds
    series.timestamps[3] = 115; series.values[3] = 20;

    const integral = try ts.integrate(series, allocator);
    defer integral.deinit();

    // 0 -> 5: (10+10)/2 * 5 = 50. Total = 50.
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), integral.values[1], 0.001);

    // 5 -> 105: (10+0)/2 * 100 = 500. Total = 550.
    // Note: Trapezoidal rule linearly interpolates across the gap.
    try std.testing.expectApproxEqAbs(@as(f64, 550.0), integral.values[2], 0.001);

    // 105 -> 115: (0+20)/2 * 10 = 100. Total = 650.
    try std.testing.expectApproxEqAbs(@as(f64, 650.0), integral.values[3], 0.001);
}
