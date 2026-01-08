const std = @import("std");
const value = @import("../core/value.zig");
const Value = value.Value;
const Matrix = value.Matrix;
const Series = @import("../timeseries/series.zig").Series;

/// Generate a sequence of numbers from start to end (exclusive) with a given step.
/// Returns a 1xN matrix (row vector).
pub fn range(start: f64, end: f64, step: f64, allocator: std.mem.Allocator) !Value {
    if (step == 0) return error.InvalidStep;
    
    // Check for infinite loops
    if ((start < end and step < 0) or (start > end and step > 0)) {
        // Return empty matrix
        const mat = try Matrix.init(allocator, 1, 0);
        return Value.initMatrix(mat);
    }
    
    // Calculate count carefully to avoid precision issues
    const diff = end - start;
    const count_f = @ceil(diff / step);
    if (count_f < 0) {
         const mat = try Matrix.init(allocator, 1, 0);
         return Value.initMatrix(mat);
    }

    const count = @as(usize, @intFromFloat(count_f));
    
    // Safety check for huge allocations
    if (count > 1_000_000_000) return error.ResultTooLarge;
    
    const mat = try Matrix.init(allocator, 1, @intCast(count));
    const data = mat.data[0..count];
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
        data[i] = start + @as(f64, @floatFromInt(i)) * step;
    }
    
    return Value.initMatrix(mat);
}

/// Generate a sequence of timestamps from start to end (exclusive) with a given step.
/// Returns a Series with zero values.
pub fn rangeSeries(start: f64, end: f64, step: f64, allocator: std.mem.Allocator) !Value {
    if (step == 0) return error.InvalidStep;
    
    const diff = end - start;
    const count_f = @ceil(diff / step);
    if (count_f <= 0) return error.InvalidArgument;

    const count = @as(usize, @intFromFloat(count_f));
    if (count > 1_000_000_000) return error.ResultTooLarge;
    
    const s = try Series.init(allocator, count, .Linear, .{});
    var i: usize = 0;
    while (i < count) : (i += 1) {
        s.timestamps[i] = start + @as(f64, @floatFromInt(i)) * step;
        s.values[i] = 0;
    }
    try s.validate();
    return Value.initSeries(s);
}

/// Generate a sequence of count numbers evenly spaced between start and end (inclusive).
/// Returns a 1xN matrix (row vector).
pub fn linspace(start: f64, end: f64, count: usize, allocator: std.mem.Allocator) !Value {
    if (count == 0) {
        const mat = try Matrix.init(allocator, 1, 0);
        return Value.initMatrix(mat);
    }
    if (count == 1) {
        const mat = try Matrix.init(allocator, 1, 1);
        mat.data[0] = start;
        return Value.initMatrix(mat);
    }
    
    const mat = try Matrix.init(allocator, 1, @intCast(count));
    const data = mat.data[0..count];
    
    const step = (end - start) / @as(f64, @floatFromInt(count - 1));
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
        data[i] = start + @as(f64, @floatFromInt(i)) * step;
    }
    // Ensure exact end value
    data[count - 1] = end;
    
    return Value.initMatrix(mat);
}

/// Generate a sequence of count timestamps evenly spaced between start and end (inclusive).
/// Returns a Series with zero values.
pub fn linspaceSeries(start: f64, end: f64, count: usize, allocator: std.mem.Allocator) !Value {
    if (count == 0) return error.InvalidArgument;
    
    const s = try Series.init(allocator, count, .Linear, .{});
    if (count == 1) {
        s.timestamps[0] = start;
        s.values[0] = 0;
        try s.validate();
        return Value.initSeries(s);
    }
    
    const step = (end - start) / @as(f64, @floatFromInt(count - 1));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        s.timestamps[i] = start + @as(f64, @floatFromInt(i)) * step;
        s.values[i] = 0;
    }
    s.timestamps[count - 1] = end;
    try s.validate();
    return Value.initSeries(s);
}

/// Generate a sequence of count numbers spaced evenly on a log scale.
/// Returns a 1xN matrix (row vector).
pub fn logspace(start: f64, end: f64, count: usize, allocator: std.mem.Allocator) !Value {
    if (count == 0) {
        const mat = try Matrix.init(allocator, 1, 0);
        return Value.initMatrix(mat);
    }
    
    const mat = try Matrix.init(allocator, 1, @intCast(count));
    const data = mat.data[0..count];
    
    if (count == 1) {
        data[0] = std.math.pow(f64, 10, start);
        return Value.initMatrix(mat);
    }
    
    const step = (end - start) / @as(f64, @floatFromInt(count - 1));
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const p = start + @as(f64, @floatFromInt(i)) * step;
        data[i] = std.math.pow(f64, 10, p);
    }
    // Ensure exact end value calculation (though floating point might still vary slightly)
    data[count - 1] = std.math.pow(f64, 10, end);
    
    return Value.initMatrix(mat);
}
