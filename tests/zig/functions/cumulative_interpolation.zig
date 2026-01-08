const std = @import("std");
const mathzig = @import("mathzig");
const Series = mathzig.timeseries.Series;

test "Alignment: Cumulative interpolation" {
    const allocator = std.testing.allocator;
    
    // Cumulative series: 0->0, 10->100. Rate is 10/sec.
    // At t=5, value should be 50.
    const s1 = try Series.init(allocator, 2, .Cumulative, .{});
    defer s1.release();
    s1.timestamps[0] = 0; s1.values[0] = 0;
    s1.timestamps[1] = 10; s1.values[1] = 100;
    try s1.validate();
    
    // Target series just defines timestamps: 5
    const s2 = try Series.init(allocator, 1, .Step, .{});
    defer s2.release();
    s2.timestamps[0] = 5; s2.values[0] = 0;
    try s2.validate();
    
    // Align s1 to union (0, 5, 10)
    const res = try mathzig.timeseries.alignUnion(s1, s2, allocator);
    const a = res.@"0";
    const b = res.@"1";
    defer a.release();
    defer b.release();
    
    // Check s1 interpolated at t=5
    // Index 0: t=0, v=0
    // Index 1: t=5, v should be 50 (Linear interpolation of cumulative counter)
    // Index 2: t=10, v=100
    
    try std.testing.expectEqual(@as(f64, 0.0), a.timestamps[0]);
    try std.testing.expectEqual(@as(f64, 5.0), a.timestamps[1]);
    try std.testing.expectEqual(@as(f64, 10.0), a.timestamps[2]);
    
    try std.testing.expectEqual(@as(f64, 50.0), a.values[1]);
}
