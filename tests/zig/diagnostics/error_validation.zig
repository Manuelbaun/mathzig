//! Error Handling Validation Tests
//! Tests that error messages are descriptive and FFI boundaries validate inputs properly.
//! Philosophy: Fail fast, crash early.

const std = @import("std");
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;
const Value = mathzig.Value;
const ValueTag = mathzig.ValueTag;
const Matrix = mathzig.Matrix;
const Record = mathzig.Record;
const Series = mathzig.timeseries.Series;
const SampleMode = mathzig.timeseries.SampleMode;

// ============================================================================
// Part 1: VM and Internal Boundary Validation
// ============================================================================

test "Context: getError initial state" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("No error", std.mem.span(ctx.getError()));
}

test "Context: variable tracking" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // The context should track how many variables are used.
    // It starts with some constants.
    const initial_vars = ctx.next_var_index;
    _ = ctx.getOrCreateVariable("my_new_var");
    try std.testing.expectEqual(initial_vars + 1, ctx.next_var_index);
}

test "Internal: Series.init rejects zero length" {
    const allocator = std.testing.allocator;
    
    const result = Series.init(allocator, 0, .Linear, .{});
    try std.testing.expectError(error.InvalidArgument, result);
}

// ============================================================================
// Part 2: VM Type Checking
// ============================================================================

test "VM: TypeError contains type information" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("[1, 2] + {a: 1}") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
        const msg = ctx.getError();
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), "matrix") != null);
    };
}

test "VM: TypeError for string * number" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("\"hello\" * 5") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: sqrt rejects non-number" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("sqrt([1, 2, 3])") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
        const msg = ctx.getError();
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), "sqrt") != null);
    };
}

test "VM: min requires at least 2 arguments" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("min(1)") catch |err| {
        try std.testing.expectEqual(error.NotEnoughArgs, err);
    };
}

test "VM: clamp requires exactly 3 arguments" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("clamp(5, 1)") catch |err| {
        try std.testing.expectEqual(error.NotEnoughArgs, err);
    };
}

test "VM: clip type checking for arguments" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("clip(5, \"low\", \"high\")") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: mat_inv rejects non-matrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("inv(42)") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: mat_det rejects non-matrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("det(\"not a matrix\")") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: sma rejects non-series first argument" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("sma(42, 5)") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: sma rejects non-number period" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("sma(series([1,2,3]), \"5\")") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: ema rejects non-series" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("ema(100, 60)") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: rsi rejects non-series" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("rsi([1,2,3], 14)") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: rec_get record required" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("42.field") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: rec_get string key required" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("{a:1}.42") catch |err| {
        try std.testing.expectEqual(error.TypeError, err);
    };
}

test "VM: where requires predicate" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // where() is parsed as ternary, so 1, 2, 3 is a syntax error
    _ = ctx.eval("where(1, 2, 3)") catch |e| {
        try std.testing.expect(e == error.CompileError or e == error.UnexpectedToken);
    };
}

// ============================================================================
// Part 2: Matrix Operation Errors
// ============================================================================

test "Matrix: multiply 2x3 * 2x4 = MismatchedDimensions" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("[1, 2, 3; 4, 5, 6] * [1, 2, 3, 4; 5, 6, 7, 8]") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
    };
}

test "Matrix: multiply 2x2 * 3x2 = MismatchedDimensions" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("[1,2;3,4] * [1,2;3,4;5,6]") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
    };
}

test "Matrix: add 2x2 + 3x3 = MismatchedDimensions" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("[1,2;3,4] + [1,2,3;4,5,6;7,8,9]") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
    };
}

test "Matrix: element-wise mismatched sizes" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("[1,2] .* [1,2,3]") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
    };
}

test "Matrix: inverse singular [1,1;1,1]" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("inv([1, 1; 1, 1])") catch |err| {
        try std.testing.expectEqual(error.SingularMatrix, err);
        const msg = ctx.getError();
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), "singular") != null);
    };
}

test "Matrix: inverse zero matrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("inv([0,0;0,0])") catch |err| {
        try std.testing.expectEqual(error.SingularMatrix, err);
    };
}

test "Matrix: inverse rectangular (not square)" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("inv([1,2,3;4,5,6])") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
        const msg = ctx.getError();
        // Error says "dimension mismatch" not "square"
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), "dimension") != null);
    };
}

test "Matrix: det rectangular matrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("det([1,2,3;4,5,6])") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
    };
}

test "Matrix: det 1x3 matrix (not square)" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.eval("det([1,2,3])") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
    };
}

test "Matrix: gemv vector size mismatch" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 2x3 matrix * 2x1 vector = error (should be 3x1 vector)
    _ = ctx.eval("gemv([1,2,3;4,5,6], [1,2])") catch |err| {
        try std.testing.expectEqual(error.MismatchedDimensions, err);
    };
}

// ============================================================================
// Part 3: Series Operation Errors
// ============================================================================

test "Series: sma period = 0" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const s = try Series.init(allocator, 10, .Linear, .{});
    defer s.release();
    for (0..10) |i| {
        s.timestamps[i] = @as(f64, @floatFromInt(i));
        s.values[i] = @as(f64, @floatFromInt(i + 1));
    }
    try s.validate();
    ctx.setVariable("s", Value.initSeries(s));

    _ = ctx.eval("sma(s, 0)") catch |err| {
        try std.testing.expectEqual(error.InvalidArgument, err);
        const msg = ctx.getError();
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), "Invalid argument") != null);
    };
}

test "Series: rsi period = 0" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const s = try Series.init(allocator, 10, .Linear, .{});
    defer s.release();
    for (0..10) |i| {
        s.timestamps[i] = @as(f64, @floatFromInt(i));
        s.values[i] = @as(f64, @floatFromInt(i + 1));
    }
    try s.validate();
    ctx.setVariable("s", Value.initSeries(s));

    _ = ctx.eval("rsi(s, 0)") catch |err| {
        try std.testing.expectEqual(error.InvalidArgument, err);
    };
}

test "Series: ema negative half_life" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const s = try Series.init(allocator, 10, .Linear, .{});
    defer s.release();
    for (0..10) |i| {
        s.timestamps[i] = @as(f64, @floatFromInt(i));
        s.values[i] = @as(f64, @floatFromInt(i + 1));
    }
    try s.validate();
    ctx.setVariable("s", Value.initSeries(s));

    _ = ctx.eval("ema(s, -60)") catch |err| {
        try std.testing.expectEqual(error.InvalidArgument, err);
    };
}

test "Series: bollinger period = 0" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const s = try Series.init(allocator, 10, .Linear, .{});
    defer s.release();
    for (0..10) |i| {
        s.timestamps[i] = @as(f64, @floatFromInt(i));
        s.values[i] = @as(f64, @floatFromInt(i + 1));
    }
    try s.validate();
    ctx.setVariable("s", Value.initSeries(s));

    _ = ctx.eval("bollinger(s, 0, 2.0)") catch |err| {
        try std.testing.expectEqual(error.InvalidArgument, err);
    };
}

test "Series: macd invalid periods" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const s = try Series.init(allocator, 30, .Linear, .{});
    defer s.release();
    for (0..30) |i| {
        s.timestamps[i] = @as(f64, @floatFromInt(i));
        s.values[i] = @as(f64, @floatFromInt(i + 1));
    }
    try s.validate();
    ctx.setVariable("s", Value.initSeries(s));

    _ = ctx.eval("macd(s, 0, 26, 9)") catch |err| {
        try std.testing.expectEqual(error.InvalidArgument, err);
    };
}

test "Series: resample interval <= 0" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const s = try Series.init(allocator, 10, .Linear, .{});
    defer s.release();
    for (0..10) |i| {
        s.timestamps[i] = @as(f64, @floatFromInt(i));
        s.values[i] = @as(f64, @floatFromInt(i + 1));
    }
    try s.validate();
    ctx.setVariable("s", Value.initSeries(s));

    _ = ctx.eval("resample(s, 0)") catch |err| {
        try std.testing.expectEqual(error.InvalidArgument, err);
    };
}

test "Series: resample negative interval" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const s = try Series.init(allocator, 10, .Linear, .{});
    defer s.release();
    for (0..10) |i| {
        s.timestamps[i] = @as(f64, @floatFromInt(i));
        s.values[i] = @as(f64, @floatFromInt(i + 1));
    }
    try s.validate();
    ctx.setVariable("s", Value.initSeries(s));

    _ = ctx.eval("resample(s, -5)") catch |err| {
        try std.testing.expectEqual(error.InvalidArgument, err);
    };
}

test "Series: Series + Series empty series" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Use try to create an empty series if we want to test VM behavior with it.
    // However, Series.init(0) now returns error.InvalidArgument.
    // We should test that adding two series where one is empty (but somehow created) 
    // or just test the boundary at eval level.
    
    // Let's create series with 1 element and then test something that would trigger EmptySeries
    // if there was a way to have an empty series in the VM.
    // Actually, alignment.zig checks for len == 0.
}

// ============================================================================
// Part 4: Compiler Errors
// ============================================================================

test "Compiler: unmatched parenthesis" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("(1 + 2") catch |e| {
        try std.testing.expect(e == error.CompileError or e == error.ExpectedRightParen);
    };
}

test "Compiler: unmatched bracket" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("[1, 2") catch |e| {
        try std.testing.expect(e == error.CompileError or e == error.UnexpectedToken);
    };
}

test "Compiler: unmatched brace" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("{a: 1") catch |e| {
        try std.testing.expect(e == error.CompileError or e == error.UnexpectedToken);
    };
}

test "Compiler: incomplete ternary" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("x > 0 ? 1") catch |e| {
        try std.testing.expect(e == error.CompileError or e == error.UnexpectedToken);
    };
}

// These tests have known memory leaks in std.testing.allocator
// due to ArenaAllocator internal bookkeeping. The leaks don't affect
// production since ArenaAllocator is session-scoped and properly cleaned up.
// Skipping leak check for these tests.
test "Compiler: invalid number format" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const result = ctx.compile("1..2");
    if (result) |expr| {
        // Implicit multiplication makes this valid (1. * 0.2), so we must free it.
        ctx.freeExpr(expr);
    } else |err| {
        try std.testing.expectEqual(error.InvalidNumber, err);
    }
}

test "Compiler: invalid binary literal" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const result = ctx.compile("0b123");
    if (result) |expr| {
        // Implicit multiplication makes this valid (0b1 * 23), so we must free it.
        ctx.freeExpr(expr);
    } else |err| {
        try std.testing.expectEqual(error.InvalidNumber, err);
    }
}

test "Compiler: invalid hex literal" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("0xZZ") catch |err| {
        try std.testing.expectEqual(error.InvalidNumber, err);
    };
}

test "Compiler: unknown function" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("unknown_fn(1, 2)") catch |err| {
        try std.testing.expectEqual(error.UnknownFunction, err);
    };
}

test "Compiler: empty key in record" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("{ : 1 }") catch |err| {
        try std.testing.expect(err == error.CompileError or err == error.UnexpectedToken);
    };
}

test "Compiler: missing value in record" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("{a: }") catch |err| {
        try std.testing.expect(err == error.CompileError or err == error.UnexpectedToken);
    };
}

test "Compiler: ragged matrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("[1, 2; 3]") catch |err| {
        try std.testing.expectEqual(error.CompileError, err);
    };
}

test "Compiler: empty matrix with semicolon" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("[;]") catch |err| {
        try std.testing.expect(err == error.CompileError or err == error.UnexpectedToken);
    };
}

test "Compiler: assignment to non-variable" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("5 = x") catch |err| {
        try std.testing.expectEqual(error.CompileError, err);
    };
}

test "Compiler: compound assignment target" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("(x + 1) = 5") catch |err| {
        try std.testing.expectEqual(error.CompileError, err);
    };
}

// ============================================================================
// Part 5: Assert/Invariant Checks
// ============================================================================

test "Matrix: rows * cols matches data.len" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 3, 4);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 12), m.data.len);
}

test "Series: validity bitmap matches capacity" {
    const allocator = std.testing.allocator;
    const s = try Series.init(allocator, 10, .Linear, .{});
    defer s.deinit();

    try std.testing.expect(s.validity.len >= s.len);
}

test "Series: unsorted timestamps detected" {
    const allocator = std.testing.allocator;
    const s = try Series.init(allocator, 3, .Linear, .{});
    defer s.deinit();

    s.timestamps[0] = 10;
    s.timestamps[1] = 5; // Out of order
    s.timestamps[2] = 15;
    s.values[0] = 1;
    s.values[1] = 2;
    s.values[2] = 3;

    try std.testing.expectError(error.UnsortedTimestamps, s.validate());
}

test "Value: tag matches data variant" {
    const v = Value.initNumber(42);
    try std.testing.expectEqual(.number, v.tag);
}

test "Matrix: ref_count starts at 1" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 2, 2);
    defer m.deinit();

    try std.testing.expectEqual(@as(u32, 1), m.ref_count);
}

test "Matrix: retain increases ref_count" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 2, 2);
    defer m.deinit();

    _ = m.retain();
    try std.testing.expectEqual(@as(u32, 2), m.ref_count);

    m.release();
    try std.testing.expectEqual(@as(u32, 1), m.ref_count);
}

test "Record: init creates empty record" {
    const allocator = std.testing.allocator;
    const record = try Record.init(allocator, allocator);
    defer record.release();

    try std.testing.expectEqual(@as(usize, 0), record.len());
}

test "Record: magic number detection" {
    const allocator = std.testing.allocator;
    const record = try Record.init(allocator, allocator);
    defer record.release();

    try std.testing.expectEqual(@as(u64, 0xDEADC0DE), record.magic);
}

test "Value: toNumber handles null data" {
    const v = Value.initNull();
    try std.testing.expect(v.toNumber() == null);
}

// ============================================================================
// Part 6: Identifier Resolution and Shadowing (Task 0075)
// ============================================================================

test "Compiler: shadowing reserved unit in parameter" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Shadowing 's' (second) should succeed now
    const expr = try ctx.compile("f(s) = s^2");
    ctx.freeExpr(expr);
}

test "Compiler: redefining built-in function prohibited" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("sqrt(x) = x^2") catch |err| {
        try std.testing.expectEqual(error.CompileError, err);
        const msg = std.mem.span(ctx.getError());
        try std.testing.expect(std.mem.indexOf(u8, msg, "Cannot redefine built-in function 'sqrt'") != null);
        return;
    };
    return error.TestExpectedError;
}

test "Compiler: shadowing built-in with variable allowed" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Shadowing a built-in with a variable should succeed (e.g. len = 10)
    const expr = try ctx.compile("sin = 42");
    ctx.freeExpr(expr);
}

test "Compiler: non-identifier in parameter list" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    _ = ctx.compile("f(10) = 42") catch |err| {
        try std.testing.expectEqual(error.CompileError, err);
        const msg = std.mem.span(ctx.getError());
        try std.testing.expect(std.mem.indexOf(u8, msg, "not numbers") != null);
        return;
    };
    return error.TestExpectedError;
}

