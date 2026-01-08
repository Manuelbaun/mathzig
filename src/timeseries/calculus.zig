const std = @import("std");
const Series = @import("series.zig").Series;
const value = @import("../core/value.zig");
const Vec = value.Vec;
const VectorLen = value.VectorLen;

pub const CalculusError = error{
    InsufficientData,
    UnsortedTimestamps,
    NaNTimestamp,
};

/// Derivative: rate of change per second (irregular-aware)
/// Result has len - 1 samples.
pub fn derivative(series: *const Series, allocator: std.mem.Allocator) !*Series {
    if (series.len < 2) return CalculusError.InsufficientData;
    if (!series.is_sorted) return CalculusError.UnsortedTimestamps;

    const result = try Series.init(allocator, series.len - 1, .Linear, series.dimensions);
    
    var i: usize = 1;
    // SIMD Path
    if (series.len >= VectorLen + 1) {
        const vec_loop_end = ((series.len - 1) / VectorLen) * VectorLen + 1;
        while (i < vec_loop_end) : (i += VectorLen) {
            if (i + 32 < vec_loop_end) {
                @prefetch(series.values.ptr + i + 32, .{ .rw = .read, .locality = 3 });
                @prefetch(series.timestamps.ptr + i + 32, .{ .rw = .read, .locality = 3 });
            }
            const v_curr: Vec = series.values[i..][0..VectorLen].*;
            const v_prev: Vec = series.values[i-1..][0..VectorLen].*;
            const t_curr: Vec = series.timestamps[i..][0..VectorLen].*;
            const t_prev: Vec = series.timestamps[i-1..][0..VectorLen].*;
            
            const dt = t_curr - t_prev;
            // Handle dt == 0 via select to avoid NaN if possible, or just let IEEE754 handle it
            // result = (v_curr - v_prev) / dt
            const deriv_vec = (v_curr - v_prev) / dt;
            
            result.values[i-1..][0..VectorLen].* = deriv_vec;
            result.timestamps[i-1..][0..VectorLen].* = t_curr;
        }
    }

    // Scalar Tail / Fallback
    while (i < series.len) : (i += 1) {
        const dt = series.timestamps[i] - series.timestamps[i - 1];
        result.timestamps[i - 1] = series.timestamps[i];
        
        if (dt == 0) {
            if (series.values[i] == series.values[i-1]) {
                result.values[i - 1] = 0;
            } else {
                result.values[i - 1] = if (series.values[i] > series.values[i-1]) std.math.inf(f64) else -std.math.inf(f64);
            }
        } else {
            result.values[i - 1] = (series.values[i] - series.values[i - 1]) / dt;
        }
    }

    return result;
}

/// Integral: cumulative area under curve (trapezoidal rule)
/// Result has same length as input.
pub fn integrate(series: *const Series, allocator: std.mem.Allocator) !*Series {
    if (!series.is_sorted) return CalculusError.UnsortedTimestamps;

    const result = try Series.init(allocator, series.len, .Linear, series.dimensions);
    
    if (series.len == 0) return result;

    var cumulative: f64 = 0;
    result.values[0] = 0;
    result.timestamps[0] = series.timestamps[0];

    var i: usize = 1;
    // SIMD Path for area increments
    // Note: Integration is inherently sequential due to 'cumulative' sum.
    // We can SIMD the area increments, then do a prefix sum (scan).
    if (series.len >= VectorLen + 1) {
        const vec_loop_end = ((series.len - 1) / VectorLen) * VectorLen + 1;
        while (i < vec_loop_end) : (i += VectorLen) {
            if (i + 32 < vec_loop_end) {
                @prefetch(series.values.ptr + i + 32, .{ .rw = .read, .locality = 3 });
                @prefetch(series.timestamps.ptr + i + 32, .{ .rw = .read, .locality = 3 });
            }
            const v_curr: Vec = series.values[i..][0..VectorLen].*;
            const v_prev: Vec = series.values[i-1..][0..VectorLen].*;
            const t_curr: Vec = series.timestamps[i..][0..VectorLen].*;
            const t_prev: Vec = series.timestamps[i-1..][0..VectorLen].*;
            
            const dt = t_curr - t_prev;
            const area_inc = (v_curr + v_prev) * @as(Vec, @splat(0.5)) * dt;
            
            // We still need to add them sequentially to 'cumulative'
            // or do a prefix sum within the vector.
            inline for (0..VectorLen) |j| {
                cumulative += area_inc[j];
                result.values[i + j] = cumulative;
                result.timestamps[i + j] = t_curr[j];
            }
        }
    }

    // Scalar Tail
    while (i < series.len) : (i += 1) {
        const dt = series.timestamps[i] - series.timestamps[i - 1];
        // Trapezoidal rule: (v1 + v2) / 2 * dt
        cumulative += (series.values[i] + series.values[i - 1]) / 2.0 * dt;
        result.values[i] = cumulative;
        result.timestamps[i] = series.timestamps[i];
    }

    return result;
}

pub fn diff(series: *const Series, n: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    for (0..series.len) |i| {
        result.timestamps[i] = series.timestamps[i];
        if (i >= n) {
            const v_curr = series.values[i];
            const v_prev = series.values[i - n];
            const is_valid = (series.validity[i] != 0 and !std.math.isNan(v_curr) and 
                             series.validity[i - n] != 0 and !std.math.isNan(v_prev));
            
            if (is_valid) {
                result.values[i] = v_curr - v_prev;
                result.validity[i] = 1;
            } else {
                result.values[i] = std.math.nan(f64);
                result.validity[i] = 0;
            }
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

pub fn pctChange(series: *const Series, n: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    for (0..series.len) |i| {
        result.timestamps[i] = series.timestamps[i];
        if (i >= n) {
            const v_curr = series.values[i];
            const v_prev = series.values[i - n];
            const is_valid = (series.validity[i] != 0 and !std.math.isNan(v_curr) and 
                             series.validity[i - n] != 0 and !std.math.isNan(v_prev) and
                             v_prev != 0);
            
            if (is_valid) {
                result.values[i] = (v_curr - v_prev) / v_prev;
                result.validity[i] = 1;
            } else {
                result.values[i] = std.math.nan(f64);
                result.validity[i] = 0;
            }
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

test "Calculus: diff and pctChange" {
    const allocator = std.testing.allocator;
    const len = 5;
    const series = try Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    const ts_data = [_]f64{ 0, 1, 2, 3, 4 };
    const val_data = [_]f64{ 10, 20, 30, 40, 50 };
    @memcpy(series.timestamps[0..len], &ts_data);
    @memcpy(series.values[0..len], &val_data);
    try series.validate();

    const d1 = try diff(series, 1, allocator);
    defer d1.deinit();
    try std.testing.expectEqual(@as(f64, 10), d1.values[1]);
    try std.testing.expectEqual(@as(f64, 10), d1.values[4]);

    const pc1 = try pctChange(series, 1, allocator);
    defer pc1.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pc1.values[1], 0.0001); // (20-10)/10 = 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pc1.values[4], 0.0001); // (50-40)/40 = 0.25
}

test "Derivative of linear ramp" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.deinit();

    // value = 2 * timestamp
    for (0..5) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i)) * 10.0;
        series.values[i] = series.timestamps[i] * 2.0;
    }
    try series.validate();

    const der = try derivative(series, allocator);
    defer der.deinit();

    try std.testing.expectEqual(@as(usize, 4), der.len);
    for (der.values) |v| {
        try std.testing.expectEqual(@as(f64, 2.0), v);
    }
}

test "Integral of constant" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.deinit();

    // Constant value 10.0 at irregular intervals
    series.timestamps[0] = 0;
    series.timestamps[1] = 10;
    series.timestamps[2] = 15;
    series.timestamps[3] = 30;
    series.timestamps[4] = 100;
    @memset(series.values, 10.0);
    try series.validate();

    const integral = try integrate(series, allocator);
    defer integral.deinit();

    try std.testing.expectEqual(@as(f64, 0.0), integral.values[0]);
    try std.testing.expectEqual(@as(f64, 100.0), integral.values[1]); // 10 * 10
    try std.testing.expectEqual(@as(f64, 150.0), integral.values[2]); // 10 * 15
    try std.testing.expectEqual(@as(f64, 1000.0), integral.values[4]); // 10 * 100
}

test "Calculus: Derivative of irregular sine wave" {
    const allocator = std.testing.allocator;
    const len = 100;
    const series = try Series.init(allocator, len, .Linear, .{});
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

    const deriv = try derivative(series, allocator);
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
    const series = try Series.init(allocator, 4, .Step, .{});
    defer series.deinit();

    // Value 10 for 5 seconds
    series.timestamps[0] = 0; series.values[0] = 10;
    series.timestamps[1] = 5; series.values[1] = 10;
    
    // Gap of 100 seconds where value is 0
    series.timestamps[2] = 105; series.values[2] = 0;
    
    // Value 20 for 10 seconds
    series.timestamps[3] = 115; series.values[3] = 20;

    const integral = try integrate(series, allocator);
    defer integral.deinit();

    // 0 -> 5: (10+10)/2 * 5 = 50. Total = 50.
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), integral.values[1], 0.001);

    // 5 -> 105: (10+0)/2 * 100 = 500. Total = 550.
    // Note: Trapezoidal rule linearly interpolates across the gap.
    try std.testing.expectApproxEqAbs(@as(f64, 550.0), integral.values[2], 0.001);

    // 105 -> 115: (0+20)/2 * 10 = 100. Total = 650.
    try std.testing.expectApproxEqAbs(@as(f64, 650.0), integral.values[3], 0.001);
}

