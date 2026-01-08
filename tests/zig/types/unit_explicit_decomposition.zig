const std = @import("std");
const mathzig = @import("mathzig");

test "explicit unit syntax [...]" {
    var ctx = try mathzig.MathZig.init(std.testing.allocator);
    defer ctx.deinit();

    // Test 1: Explicit single unit
    const result1 = try ctx.eval("10[kg]");
    try std.testing.expectEqual(mathzig.ValueTag.unit, result1.tag);
    try std.testing.expectEqual(@as(f64, 10.0), result1.data.unit.value);
    try std.testing.expectEqual(@as(i8, 1), result1.data.unit.info.dimensions.m);

    // Test 2: Explicit compound unit
    const result2 = try ctx.eval("5[m/s]");
    try std.testing.expectEqual(mathzig.ValueTag.unit, result2.tag);
    try std.testing.expectEqual(@as(f64, 5.0), result2.data.unit.value);
    try std.testing.expectEqual(@as(i8, 1), result2.data.unit.info.dimensions.l);
    try std.testing.expectEqual(@as(i8, -1), result2.data.unit.info.dimensions.t);
}

test "unit decomposition sm -> s * m" {
    var ctx = try mathzig.MathZig.init(std.testing.allocator);
    defer ctx.deinit();

    // "sm" is not a variable, so it should decompose into "s" (seconds) * "m" (meters)
    // 22sm -> 22 * s * m
    const result = try ctx.eval("22sm");
    
    try std.testing.expectEqual(mathzig.ValueTag.unit, result.tag);
    // Value = 22 * 1.0 * 1.0 = 22
    try std.testing.expectEqual(@as(f64, 22.0), result.data.unit.value);
    
    // Dimensions: s (T=1) * m (L=1)
    try std.testing.expectEqual(@as(i8, 1), result.data.unit.info.dimensions.t);
    try std.testing.expectEqual(@as(i8, 1), result.data.unit.info.dimensions.l);
}

test "explicit unit decomposition 22[sm]" {
    var ctx = try mathzig.MathZig.init(std.testing.allocator);
    defer ctx.deinit();

    const result = try ctx.eval("22[sm]");
    
    try std.testing.expectEqual(mathzig.ValueTag.unit, result.tag);
    try std.testing.expectEqual(@as(f64, 22.0), result.data.unit.value);
    try std.testing.expectEqual(@as(i8, 1), result.data.unit.info.dimensions.t);
    try std.testing.expectEqual(@as(i8, 1), result.data.unit.info.dimensions.l);
}

test "unit decomposition with prefixes (kgm)" {
    var ctx = try mathzig.MathZig.init(std.testing.allocator);
    defer ctx.deinit();

    // "kgm" -> "kg" * "m"
    // NOT "k" * "g" * "m" (because 'k' is prefix, 'g' is gram, 'm' is meter... wait, 'k' is not a unit on its own)
    // "kg" is a unit.
    const result = try ctx.eval("10kgm");
    
    try std.testing.expectEqual(mathzig.ValueTag.unit, result.tag);
    try std.testing.expectEqual(@as(f64, 10.0), result.data.unit.value); // 10 kg*m = 10 base units (kg is base for mass, m is base for length)
    
    // Dimensions: Mass=1, Length=1
    try std.testing.expectEqual(@as(i8, 1), result.data.unit.info.dimensions.m);
    try std.testing.expectEqual(@as(i8, 1), result.data.unit.info.dimensions.l);
}

test "assignment with decomposed unit c = 22sm" {
    var ctx = try mathzig.MathZig.init(std.testing.allocator);
    defer ctx.deinit();

    _ = try ctx.eval("c = 22sm");
    
    // Verify 'c' variable
    const idx = ctx.variables.get("c").?;
    const c_val = ctx.vm.variables[idx];
    
    try std.testing.expectEqual(mathzig.ValueTag.unit, c_val.tag);
    try std.testing.expectEqual(@as(f64, 22.0), c_val.data.unit.value);
}
