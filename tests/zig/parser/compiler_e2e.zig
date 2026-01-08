//! End-to-End tests for MathZig Compiler and VM integration
//! Tests complex expressions, operator precedence, and edge cases

const std = @import("std");
const mathzig = @import("mathzig");
const Compiler = mathzig.parser.Compiler;
const VM = mathzig.vm.VM;
const UnitRegistry = mathzig.units.UnitRegistry;
const Value = mathzig.Value;

test "Compiler E2E: basic arithmetic and precedence" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    const cases = [_]struct { expr: []const u8, expected: f64 }{
        .{ .expr = "2 + 3 * 4", .expected = 14 },
        .{ .expr = "(2 + 3) * 4", .expected = 20 },
        .{ .expr = "10 / 2 - 1", .expected = 4 },
        .{ .expr = "2^3 + 1", .expected = 9 },
        .{ .expr = "4 * (3 + 2) / 10", .expected = 2 },
    };

    for (cases) |case| {
        var compiler = try Compiler.init(allocator, case.expr);
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        const result = try vm.execute(&expr);
        try std.testing.expectEqual(case.expected, result.data.number);
    }
}

test "Compiler E2E: implicit multiplication" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    // Set variable 'x'
    try vm.setVariable("x", Value.initNumber(5));

    const cases = [_]struct { expr: []const u8, expected: f64 }{
        .{ .expr = "2x", .expected = 10 },
        .{ .expr = "x(2+1)", .expected = 15 },
        .{ .expr = "(1+2)(3+4)", .expected = 21 },
        .{ .expr = "2(x+1)", .expected = 12 },
    };

    for (cases) |case| {
        var compiler = try Compiler.init(allocator, case.expr);
        compiler.registry = &registry;
        defer compiler.deinit();

        var expr = try compiler.compile();
        defer expr.deinit();

        const result = try vm.execute(&expr);
        try std.testing.expectEqual(case.expected, result.data.number);
    }
}

test "Compiler E2E: complex numbers" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    var compiler = try Compiler.init(allocator, "(1 + 2i) * (3 + 4i)");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    const result = try vm.execute(&expr);
    // (1+2i)*(3+4i) = 3 + 4i + 6i + 8i^2 = 3 + 10i - 8 = -5 + 10i
    try std.testing.expectEqual(@as(f64, -5), result.data.complex.re);
    try std.testing.expectEqual(@as(f64, 10), result.data.complex.im);
}

test "Compiler E2E: ternary operator" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    try vm.setVariable("x", Value.initNumber(10));

    var compiler = try Compiler.init(allocator, "x > 5 ? 100 : -100");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    const result1 = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, 100), result1.data.number);

    try vm.setVariable("x", Value.initNumber(2));
    const result2 = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, -100), result2.data.number);
}

test "Compiler E2E: record literals" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var vm = try VM.init(allocator, allocator, 16, null);
    defer vm.deinit();

    var compiler = try Compiler.init(allocator, "{ a: 10, b: 20 + 5 }");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    const result = try vm.execute(&expr);
    defer result.release();

    try std.testing.expectEqual(mathzig.ValueTag.record, result.tag);
    const record = result.data.record;
    try std.testing.expectEqual(@as(f64, 10), record.get("a").?.data.number);
    try std.testing.expectEqual(@as(f64, 25), record.get("b").?.data.number);
}
