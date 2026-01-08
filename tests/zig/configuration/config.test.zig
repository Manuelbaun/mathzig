const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;

test "global config - angle mode" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Default should be radians
    const res1 = try ctx.eval("sin(pi/2)");
    defer res1.release();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), res1.toNumber().?, 0.0001);

    // Set to degrees
    const res_cfg1 = try ctx.eval("config({ angles: \"degrees\" })");
    defer res_cfg1.release();
    
    // Check if it's applied
    const res2 = try ctx.eval("sin(90)");
    defer res2.release();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), res2.toNumber().?, 0.0001);
    
    // Inverse functions in degrees
    const res3 = try ctx.eval("asin(1)");
    defer res3.release();
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), res3.toNumber().?, 0.0001);

    // Set back to radians
    const res_cfg2 = try ctx.eval("config({ angles: \"radians\" })");
    defer res_cfg2.release();
    const res4 = try ctx.eval("sin(pi/2)");
    defer res4.release();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), res4.toNumber().?, 0.0001);
}

test "global config - get current" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const res = try ctx.eval("config()");
    defer res.release();
    try std.testing.expectEqual(mathzig.ValueTag.record, res.tag);
    
    const angles = res.data.record.fields.get("angles").?;
    try std.testing.expectEqualStrings("radians", angles.data.string.toSlice());
}
