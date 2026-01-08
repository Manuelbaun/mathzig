const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

test "Joins: AsOf with multiple series" {
    const allocator = std.testing.allocator;
    const series = try ts.Series.init(allocator, 3, .Linear, .{});
    defer series.deinit();

    // Trades: at t=1, price=100; t=3, price=101; t=5, price=102
    series.timestamps[0] = 1; series.values[0] = 100;
    series.timestamps[1] = 3; series.values[1] = 101;
    series.timestamps[2] = 5; series.values[2] = 102;
    try series.validate();

    // Quotes: want price at t=0, 2, 4, 6
    const targets = [_]f64{ 0, 2, 4, 6 };
    
    const joined = try ts.asofJoin(&targets, series, allocator);
    defer joined.deinit();

    // t=0: no previous trade -> NaN
    try std.testing.expect(std.math.isNan(joined.values[0]));
    
    // t=2: last trade was t=1 (100)
    try std.testing.expectEqual(@as(f64, 100.0), joined.values[1]);

    // t=4: last trade was t=3 (101)
    try std.testing.expectEqual(@as(f64, 101.0), joined.values[2]);

    // t=6: last trade was t=5 (102)
    try std.testing.expectEqual(@as(f64, 102.0), joined.values[3]);
}
