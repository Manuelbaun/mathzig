const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "Unit System: Basic Attachment & Multiplication" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Basic attachment via brackets
    const res1 = try ctx.eval("10 [m]");
    try std.testing.expectEqual(ValueTag.unit, res1.tag);
    try std.testing.expectEqual(@as(f64, 10.0), res1.data.unit.value);

    // Multiplication of units
    const res2 = try ctx.eval("10 [m] * 5 [m]"); // Area
    try std.testing.expectEqual(ValueTag.unit, res2.tag);
    try std.testing.expectEqual(@as(f64, 50.0), res2.data.unit.value);
    try std.testing.expectEqual(@as(i8, 2), res2.data.unit.info.dimensions.l);
}

test "Unit System: Prefixes" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const res1 = try ctx.eval("1 [km]");
    try std.testing.expectEqual(@as(f64, 1000.0), res1.data.unit.value);

    const res2 = try ctx.eval("1 [ms]");
    try std.testing.expectEqual(@as(f64, 0.001), res2.data.unit.value);
}

test "Unit System: conv() function basic" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 1 km to m
    const res1 = try ctx.eval("conv(1 [km], [m])");
    try std.testing.expectEqual(ValueTag.number, res1.tag);
    try std.testing.expectEqual(@as(f64, 1000.0), res1.data.number);

    // 1 hour to seconds
    const res2 = try ctx.eval("conv(1 [h], [s])");
    try std.testing.expectEqual(@as(f64, 3600.0), res2.data.number);
}

test "Unit System: conv() round-tripping" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Celsius to Fahrenheit and back
    // 100 degC = 212 degF
    const f = try ctx.eval("conv(100 [degC], [degF])");
    try std.testing.expectApproxEqAbs(@as(f64, 212.0), f.data.number, 0.0001);

    ctx.setNumber("f_val", f.data.number);
    const c = try ctx.eval("conv(f_val * [degF], [degC])");
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), c.data.number, 0.0001);
}

test "Unit System: Complex Compound Units" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Density: 1000 kg / 1 m^3
    const density = try ctx.eval("1000 [kg] / (1 [m] * 1 [m] * 1 [m])");
    ctx.setVariable("rho", density);

    // Flow: 2 m^3/h
    // 2 m^3/h = 2/3600 m^3/s
    const flow = try ctx.eval("2 [m] * 1 [m] * 1 [m] / 1 [h]");
    ctx.setVariable("q", flow);

    // Mass flow: rho * q = kg/m^3 * m^3/h = kg/h
    const mass_flow = try ctx.eval("rho * q");
    
    // Convert mass flow to g/s
    // 1000 * 2 kg/h = 2000 kg / 3600 s = 2000000 g / 3600 s = 555.55... g/s
    ctx.setVariable("mf", mass_flow);
    const res = try ctx.eval("conv(mf, [g/s])");
    try std.testing.expectApproxEqAbs(@as(f64, 555.555555), res.data.number, 0.0001);
}

test "Unit System: Energy and Power" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 100W for 24 hours
    const energy = try ctx.eval("100 [W] * 24 [h]");
    ctx.setVariable("e", energy);

    // Should be 2.4 kWh
    const kwh = try ctx.eval("conv(e, [kWh])");
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), kwh.data.number, 0.0001);

    // Convert back to Joules (Ws)
    const joules = try ctx.eval("conv(e, [J])");
    try std.testing.expectApproxEqAbs(@as(f64, 100.0 * 24.0 * 3600.0), joules.data.number, 0.0001);
}

test "Unit System: Identifier style (Implicit Mul)" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 10m is implicit 10 * m
    const res = try ctx.eval("10m");
    try std.testing.expectEqual(ValueTag.unit, res.tag);
    try std.testing.expectEqual(@as(f64, 10.0), res.data.unit.value);
    
    const res2 = try ctx.eval("5kg / 2s");
    try std.testing.expectEqual(@as(f64, 2.5), res2.data.unit.value);
    try std.testing.expectEqual(@as(i8, 1), res2.data.unit.info.dimensions.m);
    try std.testing.expectEqual(@as(i8, -1), res2.data.unit.info.dimensions.t);
}
