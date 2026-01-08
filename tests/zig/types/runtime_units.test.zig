const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;

test "runtime unit creation - scalar" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Create a new scalar unit 'points'
    _ = try ctx.eval("create_unit(\"points\", 1)");
    
    // Use it
    const res = try ctx.eval("50 points");
    try std.testing.expectEqual(mathzig.ValueTag.unit, res.tag);
    try std.testing.expectEqual(@as(f64, 50), res.data.unit.value);
    try std.testing.expect(res.data.unit.info.dimensions.isScalar());
}

test "runtime unit creation - derived" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 1. Create base unit USD (scalar for now)
    _ = try ctx.eval("create_unit(\"USD\", 1)");
    
    // 2. Create derived unit bitcoin
    _ = try ctx.eval("create_unit(\"bitcoin\", 50000 * USD)");
    
    // 3. Test conversion
    const res = try ctx.eval("conv(2 bitcoin, USD)");
    try std.testing.expectEqual(@as(f64, 100000), res.toNumber().?);
    
    // 4. Test reverse conversion
    const res2 = try ctx.eval("conv(25000 USD, bitcoin)");
    try std.testing.expectEqual(@as(f64, 0.5), res2.toNumber().?);
}

test "runtime unit creation - physical" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Create a unit based on existing physical units
    // 1 knot = 1.852 km/h
    _ = try ctx.eval("create_unit(\"knot\", 1.852 * km / h)");
    
    const res = try ctx.eval("conv(100 knot, m/s)");
    // 100 * 1.852 / 3.6 = 51.444...
    try std.testing.expectApproxEqAbs(@as(f64, 51.444444), res.toNumber().?, 0.0001);
}

test "unit conversion - temperature offsets" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const c100 = try ctx.eval("conv(100, degC)");
    try std.testing.expectApproxEqAbs(@as(f64, 373.15), c100.toNumber().?, 1e-9);

    const f_32 = try ctx.eval("conv(32, degF)");
    try std.testing.expectApproxEqAbs(@as(f64, 273.15), f_32.toNumber().?, 1e-9);

    const k_to_c = try ctx.eval("conv(273.15 K, degC)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), k_to_c.toNumber().?, 1e-9);
}

test "unit formatting - derived and compound dimensions" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // kg*m/s^2 should prefer a named derived unit when available (N)
    const force = try ctx.eval("5.5 [kg*m/s^2]");
    var buf1 = std.Io.Writer.Allocating.init(allocator);
    defer buf1.deinit();
    try ctx.formatValue(force, &buf1.writer);
    try std.testing.expect(std.mem.indexOf(u8, buf1.written(), "N") != null);

    // m/s should render as compound dimensions when no preferred short name exists
    const speed = try ctx.eval("10 [m/s]");
    var buf2 = std.Io.Writer.Allocating.init(allocator);
    defer buf2.deinit();
    try ctx.formatValue(speed, &buf2.writer);
    try std.testing.expect(std.mem.indexOf(u8, buf2.written(), "m/s") != null);

    // Area should auto-scale to prefixed length power for readability
    const area = try ctx.eval("2km * 3km");
    var buf3 = std.Io.Writer.Allocating.init(allocator);
    defer buf3.deinit();
    try ctx.formatValue(area, &buf3.writer);
    try std.testing.expect(std.mem.indexOf(u8, buf3.written(), "km^2") != null);
}
