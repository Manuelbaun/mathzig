const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

test "Core: Series lifecycle and large allocation" {
    const allocator = std.testing.allocator;
    // 1 Million samples (~16MB + overhead)
    const len = 1_000_000;
    const series = try ts.Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    try std.testing.expectEqual(len, series.len);
    
    // Check initial state
    try std.testing.expectEqual(@as(u8, 1), series.validity[0]);
    try std.testing.expectEqual(@as(u8, 1), series.validity[len - 1]);
    
    // Initialize monotonic timestamps
    for (0..len) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = 1.0;
    }

    // Modify ends
    series.timestamps[0] = 0;
    series.values[0] = 1.0;
    series.timestamps[len - 1] = 999999;
    series.values[len - 1] = 2.0;

    try series.validate();
    try std.testing.expect(series.is_sorted);
    try std.testing.expectEqual(@as(f64, 0), series.min_ts);
    try std.testing.expectEqual(@as(f64, 999999), series.max_ts);
}

test "Core: NaN and Validity handling" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 5, .Linear, .{});
    defer series.deinit();

    // Setup some data
    series.timestamps[0] = 1; series.values[0] = 10;
    series.timestamps[1] = 2; series.values[1] = std.math.nan(f64);
    series.timestamps[2] = 3; series.values[2] = 30;
    series.timestamps[3] = 4; series.values[3] = 40; series.validity[3] = 0; // Explicitly invalid
    series.timestamps[4] = 5; series.values[4] = 50;

    // View check
    const view = series.view(1, 4); // Indices 1, 2, 3
    try std.testing.expectEqual(@as(usize, 3), view.len());
    
    // Index 1 (relative 0): NaN value, but validity bit is 1 (default) unless manually set
    // MathZig convention: validity bit takes precedence, but NaN payload is also checked in some ops.
    try std.testing.expect(std.math.isNan(view.getValue(0)));
    try std.testing.expect(view.isValid(0)); 

    // Index 3 (relative 2): Explicitly invalid
    try std.testing.expect(!view.isValid(2));
}
