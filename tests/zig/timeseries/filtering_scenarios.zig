const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

test "Filtering: Complex logic (Time AND Value OR Valid)" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 10, .Linear, .{});
    defer series.deinit();

    for (0..10) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @as(f64, @floatFromInt(i)) * 10.0;
        series.validity[i] = if (i % 2 == 0) 1 else 0;
    }

    // Predicate: (Value > 50 AND IsValid)
    const p_gt = ts.Predicate{ .op = .gt, .field = .value, .constant = 50.0 };
    const p_valid = ts.Predicate{ .op = .is_valid };
    const p_and = ts.Predicate{ .op = .and_, .left = &p_gt, .right = &p_valid };

    // Matches:
    // 60 (idx 6, valid=1) -> True
    // 70 (idx 7, valid=0) -> False
    // 80 (idx 8, valid=1) -> True
    
    try std.testing.expect(!p_and.evaluate(series, 5)); // 50 not > 50
    try std.testing.expect(p_and.evaluate(series, 6));
    try std.testing.expect(!p_and.evaluate(series, 7)); // Invalid
    try std.testing.expect(p_and.evaluate(series, 8));
}

test "Filtering: Delta-Time (Gap detection)" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 5, .Linear, .{});
    defer series.deinit();

    series.timestamps[0] = 0;
    series.timestamps[1] = 1; // dt = 1
    series.timestamps[2] = 2; // dt = 1
    series.timestamps[3] = 10; // dt = 8 (Gap!)
    series.timestamps[4] = 11; // dt = 1

    // Predicate: dt > 5
    const p_gap = ts.Predicate{ .op = .gt, .field = .dt, .constant = 5.0 };

    try std.testing.expect(!p_gap.evaluate(series, 0)); // dt=0
    try std.testing.expect(!p_gap.evaluate(series, 2)); // dt=1
    try std.testing.expect(p_gap.evaluate(series, 3)); // dt=8
    try std.testing.expect(!p_gap.evaluate(series, 4)); // dt=1
}
