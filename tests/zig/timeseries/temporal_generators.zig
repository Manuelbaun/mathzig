const std = @import("std");
const mathzig = @import("mathzig");
const Value = mathzig.Value;

test "Temporal Range: string literals" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // range("2024-01-01", "2024-01-02", 1h)
    const res = try ctx.eval("range(\"2024-01-01\", \"2024-01-02\", 1h)");
    defer res.release();

    try std.testing.expect(res.tag == .series);
    const s = res.data.series;
    
    // 24 hours in a day
    try std.testing.expectEqual(@as(usize, 24), s.len);
    
    // Check first timestamp (2024-01-01 00:00:00)
    try std.testing.expectEqual(@as(f64, 1704067200), s.timestamps[0]);
    
    // Check last timestamp (2024-01-01 23:00:00)
    try std.testing.expectEqual(@as(f64, 1704067200 + 23 * 3600), s.timestamps[23]);
}

test "Temporal Linspace" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    // linspace("2024-01-01", "2024-01-02", 25) -> every hour including end
    const res = try ctx.eval("linspace(\"2024-01-01\", \"2024-01-02\", 25)");
    defer res.release();

    try std.testing.expect(res.tag == .series);
    const s = res.data.series;
    
    try std.testing.expectEqual(@as(usize, 25), s.len);
    try std.testing.expectEqual(@as(f64, 1704067200), s.timestamps[0]);
    try std.testing.expectEqual(@as(f64, 1704067200 + 24 * 3600), s.timestamps[24]);
}

test "Builtin: now()" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("now()");
    defer res.release();

    try std.testing.expect(res.tag == .number);
    try std.testing.expect(res.data.number > 1700000000); // Definitely after 2023
}
