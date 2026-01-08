const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

test "Resampling: Empty buckets handling" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 2, .Linear, .{});
    defer series.deinit();

    series.timestamps[0] = 1.0; series.values[0] = 10.0;
    series.timestamps[1] = 11.0; series.values[1] = 20.0; // Large gap (1 -> 11)
    try series.validate();

    // Interval 2.0.
    // Buckets:
    // [0, 2): includes 1.0 (val 10) -> mean 10.
    // [2, 4): empty
    // [4, 6): empty
    // [6, 8): empty
    // [8, 10): empty
    // [10, 12): includes 11.0 (val 20) -> mean 20.

    const res = try ts.resample(series, .{ .interval = 2.0, .origin = 0 }, allocator);
    defer res.deinit();

    try std.testing.expectEqual(@as(usize, 6), res.len);
    
    try std.testing.expectEqual(@as(f64, 10.0), res.values[0]);
    
    // Empty buckets should be NaN by default
    try std.testing.expect(std.math.isNan(res.values[1]));
    try std.testing.expect(std.math.isNan(res.values[2]));
    
    try std.testing.expectEqual(@as(f64, 20.0), res.values[5]);
}
