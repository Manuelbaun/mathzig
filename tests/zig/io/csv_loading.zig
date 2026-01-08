const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const Value = mathzig.Value;

test "CSV: loading data with headers" {
    const allocator = std.testing.allocator;
    
    // Create a temporary CSV file
    const csv_content = "Date,Close,Volume\n1000,150.5,1000000\n1001,155.2,1100000\n1002,152.8,900000\n";
    const path = "test_data.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = csv_content });
    defer std.fs.cwd().deleteFile(path) catch {};

    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Use read_csv
    const r1 = try ctx.eval("data = read_csv(\"test_data.csv\", { time: \"Date\", price: \"Close\", vol: \"Volume\" })");
    defer r1.release();
    
    // Verify results
    const price_result = try ctx.eval("len(data.price)");
    defer price_result.release();
    try std.testing.expectEqual(@as(f64, 3.0), price_result.data.number);

    const price_val = try ctx.eval("data.price[0]");
    defer price_val.release();
    try std.testing.expectEqual(@as(f64, 150.5), price_val.data.number);

    const vol_val = try ctx.eval("data.vol[2]");
    defer vol_val.release();
    try std.testing.expectEqual(@as(f64, 900000.0), vol_val.data.number);
}

test "CSV: ISO8601 timestamps" {
    const allocator = std.testing.allocator;
    
    const csv_content = "Date,Val\n2026-01-13 12:00:00,10\n2026-01-13 12:01:00,20\n";
    const path = "test_iso.csv";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = csv_content });
    defer std.fs.cwd().deleteFile(path) catch {};

    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const r1 = try ctx.eval("data = read_csv(\"test_iso.csv\", { time: \"Date\", v: \"Val\" })");
    defer r1.release();
    
    const ts0 = try ctx.eval("duration(data.v)"); // Should be 60 seconds
    defer ts0.release();
    try std.testing.expectEqual(@as(f64, 60.0), ts0.data.number);
}
