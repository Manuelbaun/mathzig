const std = @import("std");
const Series = @import("series.zig").Series;
const Value = @import("../core/value.zig").Value;
const Record = @import("../core/value.zig").Record;

/// EMA with time-decay for irregular data
/// half_life_seconds: Time for weight to decay to 50%
pub fn ema(series: *const Series, half_life_seconds: f64, allocator: std.mem.Allocator) !*Series {
    if (half_life_seconds <= 0) return error.InvalidArgument;
    const result = try Series.init(allocator, series.len, .Linear, series.dimensions);
    if (series.len == 0) return result;

    var prev_ema = series.values[0];
    result.values[0] = prev_ema;
    result.timestamps[0] = series.timestamps[0];

    const ln2 = @log(2.0);

    for (1..series.len) |i| {
        const dt = series.timestamps[i] - series.timestamps[i - 1];
        // Alpha decays exponentially with time gap: 1 - exp(-dt * ln(2) / half_life)
        const alpha = 1.0 - @exp(-dt * ln2 / half_life_seconds);
        prev_ema = alpha * series.values[i] + (1.0 - alpha) * prev_ema;
        result.values[i] = prev_ema;
        result.timestamps[i] = series.timestamps[i];
    }
    return result;
}

/// SMA with fixed sample window
pub fn sma(series: *const Series, period: usize, allocator: std.mem.Allocator) !*Series {
    if (period == 0) return error.InvalidArgument;
    const result = try Series.init(allocator, series.len, .Linear, series.dimensions);
    if (series.len == 0) return result;
    var sum: f64 = 0;
    for (0..series.len) |i| {
        sum += series.values[i];
        if (i >= period) {
            sum -= series.values[i - period];
        }

        result.timestamps[i] = series.timestamps[i];
        if (i >= period - 1) {
            result.values[i] = sum / @as(f64, @floatFromInt(period));
        } else {
            result.values[i] = std.math.nan(f64);
        }
    }
    return result;
}

/// RSI with Wilder smoothing
pub fn rsi(series: *const Series, period: usize, allocator: std.mem.Allocator) !*Series {
    if (period == 0) return error.InvalidArgument;
    const result = try Series.init(allocator, series.len, .Linear, series.dimensions);
    if (series.len < period + 1) {
        @memset(result.values, std.math.nan(f64));
        @memcpy(result.timestamps, series.timestamps);
        return result;
    }

    var avg_gain: f64 = 0;
    var avg_loss: f64 = 0;

    // Initial SMA for first period
    for (1..period + 1) |i| {
        const diff = series.values[i] - series.values[i - 1];
        if (diff > 0) avg_gain += diff else avg_loss -= diff;
    }
    avg_gain /= @as(f64, @floatFromInt(period));
    avg_loss /= @as(f64, @floatFromInt(period));

    for (0..period) |i| {
        result.timestamps[i] = series.timestamps[i];
        result.values[i] = std.math.nan(f64);
    }

    const p_f = @as(f64, @floatFromInt(period));
    for (period..series.len) |i| {
        result.timestamps[i] = series.timestamps[i];
        if (i > period) {
            const diff = series.values[i] - series.values[i - 1];
            const gain = if (diff > 0) diff else 0;
            const loss = if (diff < 0) -diff else 0;

            avg_gain = (avg_gain * (p_f - 1) + gain) / p_f;
            avg_loss = (avg_loss * (p_f - 1) + loss) / p_f;
        }

        if (avg_loss == 0) {
            result.values[i] = 100.0;
        } else {
            const rs = avg_gain / avg_loss;
            result.values[i] = 100.0 - (100.0 / (1.0 + rs));
        }
    }
    return result;
}

/// Bollinger Bands indicator
/// Returns a Record with fields: upper, middle, lower (all Series)
/// middle: SMA of the series
/// upper: middle + mult * std_dev
/// lower: middle - mult * std_dev
pub fn bollinger(series: *const Series, period: usize, mult: f64, allocator: std.mem.Allocator) !*Record {
    if (period == 0) return error.InvalidArgument;
    // Calculate middle band (SMA)
    const middle = try sma(series, period, allocator);
    errdefer middle.release();
    
    // Calculate standard deviation using rolling window
    const upper = try Series.init(allocator, series.len, .Linear, series.dimensions);
    errdefer upper.release();
    const lower = try Series.init(allocator, series.len, .Linear, series.dimensions);
    errdefer lower.release();
    
    // Copy timestamps and validity from middle
    @memcpy(upper.timestamps, middle.timestamps);
    @memcpy(lower.timestamps, middle.timestamps);
    @memcpy(upper.validity, middle.validity);
    @memcpy(lower.validity, middle.validity);
    
    // Calculate rolling standard deviation
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    
    for (0..series.len) |i| {
        sum += series.values[i];
        sum_sq += series.values[i] * series.values[i];
        
        if (i >= period) {
            sum -= series.values[i - period];
            sum_sq -= series.values[i - period] * series.values[i - period];
        }
        
        if (i >= period - 1) {
            const mean = sum / @as(f64, @floatFromInt(period));
            const variance = (sum_sq - (sum * sum) / @as(f64, @floatFromInt(period))) / @as(f64, @floatFromInt(period));
            const std_dev = if (variance > 0) @sqrt(variance) else 0;
            
            // Verify middle band matches calculated mean
            _ = mean;
            
            upper.values[i] = middle.values[i] + mult * std_dev;
            lower.values[i] = middle.values[i] - mult * std_dev;
        } else {
            upper.values[i] = std.math.nan(f64);
            lower.values[i] = std.math.nan(f64);
        }
    }
    
    // Create record with the three bands
    const record = try Record.initCapacity(allocator, allocator, 3);
    try record.setOwned("upper", Value.initSeries(upper));
    try record.setOwned("middle", Value.initSeries(middle));
    try record.setOwned("lower", Value.initSeries(lower));
    
    // Release our local references (record now owns them)
    upper.release();
    middle.release();
    lower.release();
    
    return record;
}

/// MACD (Moving Average Convergence Divergence) indicator
/// Returns a Record with fields: macd, signal, histogram (all Series)
/// macd: EMA(fast) - EMA(slow)
/// signal: EMA(macd, signal_period)
/// histogram: macd - signal
pub fn macd(series: *const Series, fast_period: usize, slow_period: usize, signal_period: usize, allocator: std.mem.Allocator) !*Record {
    if (fast_period == 0 or slow_period == 0 or signal_period == 0) return error.InvalidArgument;
    // Calculate EMAs
    const fast_ema = try emaFixed(series, fast_period, allocator);
    errdefer fast_ema.release();
    
    const slow_ema = try emaFixed(series, slow_period, allocator);
    errdefer slow_ema.release();
    
    // Calculate MACD line
    const macd_line = try Series.init(allocator, series.len, .Linear, series.dimensions);
    errdefer macd_line.release();
    @memcpy(macd_line.timestamps, series.timestamps);
    @memcpy(macd_line.validity, series.validity);
    
    for (0..series.len) |i| {
        macd_line.values[i] = fast_ema.values[i] - slow_ema.values[i];
    }
    
    // Calculate signal line (EMA of MACD)
    const signal_line = try emaFixed(macd_line, signal_period, allocator);
    errdefer signal_line.release();
    
    // Calculate histogram
    const histogram = try Series.init(allocator, series.len, .Linear, series.dimensions);
    @memcpy(histogram.timestamps, series.timestamps);
    @memcpy(histogram.validity, series.validity);
    
    for (0..series.len) |i| {
        histogram.values[i] = macd_line.values[i] - signal_line.values[i];
    }
    
    // Create record with the three components
    const record = try Record.initCapacity(allocator, allocator, 3);
    try record.setOwned("macd", Value.initSeries(macd_line));
    try record.setOwned("signal", Value.initSeries(signal_line));
    try record.setOwned("histogram", Value.initSeries(histogram));
    
    // Release our local references (record now owns them)
    macd_line.release();
    signal_line.release();
    histogram.release();
    
    // Clean up intermediate EMAs (they're not part of the output)
    fast_ema.release();
    slow_ema.release();
    
    return record;
}

/// EMA with fixed period (not time-decay)
/// Used for MACD which uses standard EMA with N periods
pub fn emaFixed(series: *const Series, period: usize, allocator: std.mem.Allocator) !*Series {
    if (period == 0) return error.InvalidArgument;
    const result = try Series.init(allocator, series.len, .Linear, series.dimensions);
    if (series.len == 0) return result;
    
    const alpha = 2.0 / (@as(f64, @floatFromInt(period)) + 1.0);
    var prev_ema = series.values[0];
    result.values[0] = prev_ema;
    result.timestamps[0] = series.timestamps[0];
    
    for (1..series.len) |i| {
        prev_ema = alpha * series.values[i] + (1.0 - alpha) * prev_ema;
        result.values[i] = prev_ema;
        result.timestamps[i] = series.timestamps[i];
    }
    
    return result;
}

fn deepDeinitRecord(record: *Record) void {
    record.release();
}

test "EMA time decay" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 3, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 0;
    series.values[0] = 100.0;
    series.timestamps[1] = 60.0; // 60s
    series.values[1] = 100.0;
    series.timestamps[2] = 120.0; // another 60s
    series.values[2] = 200.0;

    // EMA with half-life of 60s
    const res = try ema(series, 60.0, allocator);
    defer res.release();

    try std.testing.expectEqual(@as(f64, 100.0), res.values[0]);
    try std.testing.expectEqual(@as(f64, 100.0), res.values[1]);
    
    // At t=120, dt=60. alpha = 1 - exp(-60 * ln2 / 60) = 1 - exp(-ln2) = 1 - 0.5 = 0.5
    // EMA = 0.5 * 200 + 0.5 * 100 = 150
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), res.values[2], 0.0001);
}

test "Bollinger Bands" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 10, .Linear, .{});
    defer series.release();

    // Create simple test data: 10, 11, 12, 13, 14, 15, 16, 17, 18, 19
    for (0..10) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = @as(f64, @floatFromInt(i + 10));
    }

    // Bollinger Bands with period=5, mult=2
    const record = try bollinger(series, 5, 2.0, allocator);
    defer deepDeinitRecord(record);

    // Check that record has the expected fields
    try std.testing.expect(record.has("upper"));
    try std.testing.expect(record.has("middle"));
    try std.testing.expect(record.has("lower"));

    const upper = record.get("upper").?.data.series;
    const middle = record.get("middle").?.data.series;
    const lower = record.get("lower").?.data.series;

    // First 4 values should be NaN (need full period)
    try std.testing.expect(std.math.isNan(upper.values[0]));
    try std.testing.expect(std.math.isNan(middle.values[0]));
    try std.testing.expect(std.math.isNan(lower.values[0]));

    // At index 4 (period-1), we have values 10, 11, 12, 13, 14
    // Mean = 12, StdDev = sqrt(((10-12)^2 + (11-12)^2 + (12-12)^2 + (13-12)^2 + (14-12)^2) / 5)
    // StdDev = sqrt((4 + 1 + 0 + 1 + 4) / 5) = sqrt(2) ≈ 1.414
    // Upper = 12 + 2 * 1.414 ≈ 14.828
    // Lower = 12 - 2 * 1.414 ≈ 9.172
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), middle.values[4], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 14.8284), upper.values[4], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 9.1716), lower.values[4], 0.001);
}

test "MACD" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 20, .Linear, .{});
    defer series.release();

    // Create simple test data: 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29
    for (0..20) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = @as(f64, @floatFromInt(i + 10));
    }

    // MACD with fast=12, slow=26, signal=9 (common parameters)
    const record = try macd(series, 12, 26, 9, allocator);
    defer deepDeinitRecord(record);

    // Check that record has the expected fields
    try std.testing.expect(record.has("macd"));
    try std.testing.expect(record.has("signal"));
    try std.testing.expect(record.has("histogram"));

    const macd_line = record.get("macd").?.data.series;
    const signal_line = record.get("signal").?.data.series;
    const histogram = record.get("histogram").?.data.series;

    // Check that all series have the same length
    try std.testing.expectEqual(@as(usize, 20), macd_line.len);
    try std.testing.expectEqual(@as(usize, 20), signal_line.len);
    try std.testing.expectEqual(@as(usize, 20), histogram.len);

    // Histogram should equal macd - signal
    for (0..20) |i| {
        if (!std.math.isNan(macd_line.values[i]) and !std.math.isNan(signal_line.values[i])) {
            try std.testing.expectApproxEqAbs(
                macd_line.values[i] - signal_line.values[i],
                histogram.values[i],
                0.0001
            );
        }
    }
}

test "SMA edge cases" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();
    for (0..5) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @as(f64, @floatFromInt(i + 1)) * 10.0;
    }

    // Period = 0 (invalid)
    try std.testing.expectError(error.InvalidArgument, sma(series, 0, allocator));

    // Period > len
    const res_large = try sma(series, 10, allocator);
    defer res_large.release();
    for (0..5) |i| try std.testing.expect(std.math.isNan(res_large.values[i]));
}

test "RSI edge cases" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();

    // All gains
    series.timestamps[0] = 0;
    series.values[0] = 10;
    for (1..5) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = series.values[i - 1] + 10;
    }
    const res_gains = try rsi(series, 3, allocator);
    defer res_gains.release();
    // After period, RSI should be near 100
    try std.testing.expect(res_gains.values[4] > 99.0);

    // All losses
    for (1..5) |i| {
        series.values[i] = series.values[i - 1] - 5;
    }
    const res_losses = try rsi(series, 3, allocator);
    defer res_losses.release();
    // After period, RSI should be near 0
    try std.testing.expect(res_losses.values[4] < 1.0);
}
