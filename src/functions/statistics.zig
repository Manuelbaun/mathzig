const std = @import("std");
const value = @import("../core/value.zig");
const Matrix = value.Matrix;

pub fn mean(data: []const f64) f64 {
    if (data.len == 0) return std.math.nan(f64);
    var sum: f64 = 0;
    for (data) |v| sum += v;
    return sum / @as(f64, @floatFromInt(data.len));
}

pub fn variance(data: []const f64) f64 {
    if (data.len < 2) return 0;
    const m = mean(data);
    var sum_sq_diff: f64 = 0;
    for (data) |v| {
        const diff = v - m;
        sum_sq_diff += diff * diff;
    }
    return sum_sq_diff / @as(f64, @floatFromInt(data.len - 1));
}

pub fn varianceBiased(data: []const f64) f64 {
    if (data.len == 0) return 0;
    const m = mean(data);
    var sum_sq_diff: f64 = 0;
    for (data) |v| {
        const diff = v - m;
        sum_sq_diff += diff * diff;
    }
    return sum_sq_diff / @as(f64, @floatFromInt(data.len));
}

pub fn stddev(data: []const f64) f64 {
    return @sqrt(variance(data));
}

pub fn stddevBiased(data: []const f64) f64 {
    return @sqrt(varianceBiased(data));
}

pub fn median(data: []const f64, allocator: std.mem.Allocator) !f64 {
    if (data.len == 0) return std.math.nan(f64);
    if (data.len == 1) return data[0];

    const sorted = try allocator.dupe(f64, data);
    defer allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));

    const mid = sorted.len / 2;
    if (sorted.len % 2 == 0) {
        return (sorted[mid - 1] + sorted[mid]) / 2.0;
    } else {
        return sorted[mid];
    }
}

// Matrix versions
pub fn matrixMean(m: *const Matrix) f64 {
    const data = m.data[m.offset..][0..m.rows * m.cols];
    return mean(data);
}

pub fn matrixVariance(m: *const Matrix) f64 {
    const data = m.data[m.offset..][0..m.rows * m.cols];
    return variance(data);
}

pub fn matrixVarianceBiased(m: *const Matrix) f64 {
    const data = m.data[m.offset..][0..m.rows * m.cols];
    return varianceBiased(data);
}

pub fn matrixStddev(m: *const Matrix) f64 {
    return @sqrt(matrixVariance(m));
}

pub fn matrixStddevBiased(m: *const Matrix) f64 {
    return @sqrt(matrixVarianceBiased(m));
}

pub fn matrixMedian(m: *const Matrix, allocator: std.mem.Allocator) !f64 {
    const data = m.data[m.offset..][0..m.rows * m.cols];
    return try median(data, allocator);
}

pub fn mad(data: []const f64, allocator: std.mem.Allocator) !f64 {
    if (data.len == 0) return std.math.nan(f64);
    const med = try median(data, allocator);
    
    const abs_diffs = try allocator.alloc(f64, data.len);
    defer allocator.free(abs_diffs);
    for (data, 0..) |v, i| {
        abs_diffs[i] = @abs(v - med);
    }
    
    return try median(abs_diffs, allocator);
}

pub fn matrixMad(m: *const Matrix, allocator: std.mem.Allocator) !f64 {
    const data = m.data[m.offset..][0..m.rows * m.cols];
    return try mad(data, allocator);
}

pub fn erf(x: f64) f64 {
    // A reasonably accurate approximation of the error function
    // ref: https://www.johndcook.com/blog/python_erf/
    const p = 0.3275911;
    const a1 = 0.254829592;
    const a2 = -0.284496736;
    const a3 = 1.421413741;
    const a4 = -1.453152027;
    const a5 = 1.061405429;

    const sign = if (x < 0) @as(f64, -1) else @as(f64, 1);
    const abs_x = @abs(x);

    const t = 1.0 / (1.0 + p * abs_x);
    const y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * @exp(-abs_x * abs_x);
    return sign * y;
}

