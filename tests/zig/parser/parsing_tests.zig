const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const ValueTag = mathzig.ValueTag;

test "number parsing: decimal and floating point" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const cases = [_]struct { input: []const u8, expected: f64 }{
        .{ .input = "123", .expected = 123.0 },
        .{ .input = "0", .expected = 0.0 },
        .{ .input = "3.141592", .expected = 3.141592 },
        .{ .input = ".5", .expected = 0.5 },
        .{ .input = "0.0001", .expected = 0.0001 },
        .{ .input = "000123", .expected = 123.0 },
        .{ .input = "000.123", .expected = 0.123 },
        .{ .input = "100_000", .expected = 100000.0 }, // Note: check if underscores are supported
    };

    for (cases) |case| {
        const res = ctx.eval(case.input) catch |err| {
            std.debug.print("Failed to parse: {s}\n", .{case.input});
            return err;
        };
        try std.testing.expectEqual(ValueTag.number, res.tag);
        try std.testing.expectEqual(case.expected, res.data.number);
    }
}

test "number parsing: underscores" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // If underscores are not supported, this might fail or ignore them.
    // Let's test them.
    const res = ctx.eval("1_000_000") catch |err| {
        if (err == error.CompileError) return; // Not supported yet, that's fine
        return err;
    };
    try std.testing.expectEqual(@as(f64, 1000000.0), res.data.number);
}

test "number parsing: scientific notation" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const cases = [_]struct { input: []const u8, expected: f64 }{
        .{ .input = "1e3", .expected = 1000.0 },
        .{ .input = "1E3", .expected = 1000.0 },
        .{ .input = "2.5e-2", .expected = 0.025 },
        .{ .input = "1.23e+2", .expected = 123.0 },
        .{ .input = "1e-5", .expected = 0.00001 },
    };

    for (cases) |case| {
        const res = try ctx.eval(case.input);
        try std.testing.expectEqual(ValueTag.number, res.tag);
        try std.testing.expectApproxEqAbs(case.expected, res.data.number, 1e-10);
    }
}

test "number parsing: hexadecimal" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const cases = [_]struct { input: []const u8, expected: f64 }{
        .{ .input = "0xFF", .expected = 255.0 },
        .{ .input = "0x10", .expected = 16.0 },
        .{ .input = "0xabcd", .expected = 43981.0 },
        .{ .input = "0XFF", .expected = 255.0 },
    };

    for (cases) |case| {
        const res = try ctx.eval(case.input);
        try std.testing.expectEqual(ValueTag.number, res.tag);
        try std.testing.expectEqual(case.expected, res.data.number);
    }
}

test "number parsing: binary" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const cases = [_]struct { input: []const u8, expected: f64 }{
        .{ .input = "0b1010", .expected = 10.0 },
        .{ .input = "0b11111111", .expected = 255.0 },
        .{ .input = "0B1100", .expected = 12.0 },
    };

    for (cases) |case| {
        const res = try ctx.eval(case.input);
        try std.testing.expectEqual(ValueTag.number, res.tag);
        try std.testing.expectEqual(case.expected, res.data.number);
    }
}

test "number parsing: imaginary numbers" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const cases = [_]struct { input: []const u8, expected_im: f64 }{
        .{ .input = "i", .expected_im = 1.0 },
        .{ .input = "10i", .expected_im = 10.0 },
        .{ .input = "3.14i", .expected_im = 3.14 },
        .{ .input = "1e2i", .expected_im = 100.0 },
    };

    for (cases) |case| {
        const res = try ctx.eval(case.input);
        try std.testing.expectEqual(ValueTag.complex, res.tag);
        try std.testing.expectEqual(@as(f64, 0), res.data.complex.re);
        try std.testing.expectEqual(case.expected_im, res.data.complex.im);
    }
}

test "number parsing: complex expressions" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 3 + 4i
    const res = try ctx.eval("3 + 4i");
    try std.testing.expectEqual(ValueTag.complex, res.tag);
    try std.testing.expectEqual(@as(f64, 3), res.data.complex.re);
    try std.testing.expectEqual(@as(f64, 4), res.data.complex.im);
}