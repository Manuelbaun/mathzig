const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

test "Aggregations: Min/Max with Predicate" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 10, .Linear, .{});
    defer series.deinit();

    // 0, 1, ..., 9
    for (0..10) |i| series.values[i] = @as(f64, @floatFromInt(i));

    // Max where value < 5
    const p_lt = ts.Predicate{ .op = .lt, .field = .value, .constant = 5.0 };
    
    const max_val = ts.max(series, &p_lt);
    try std.testing.expectEqual(@as(f64, 4.0), max_val);
}

test "Aggregations: TWA robustness" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 3, .Linear, .{});
    defer series.deinit();

    // Single point TWA -> NaN (requires duration) or return value if only 1 point?
    // Implementation: returns NaN if total_duration <= 0, but "if (!first) prev_val" fallback?
    // Let's check logic: loop runs once. first=true -> first=false. Loop ends.
    // Returns prev_val (value[0]). Correct behavior for 1 point is just the point value.
    
    series.len = 1;
    series.timestamps[0] = 100;
    series.values[0] = 42.0;
    
    // Actually the current implementation returns prev_val if single point.
    const t_one = ts.twa(series, null);
    try std.testing.expectEqual(@as(f64, 42.0), t_one);

    // Two points, same timestamp (dt=0)
    series.len = 2;
    series.timestamps[1] = 100;
    series.values[1] = 100.0;
    
    const t_zero_dur = ts.twa(series, null);
    // duration=0. weighted_sum=0. returns prev_val (100.0).
    try std.testing.expectEqual(@as(f64, 100.0), t_zero_dur);
}
