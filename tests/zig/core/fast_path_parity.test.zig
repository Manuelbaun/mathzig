const std = @import("std");
const mz = @import("mathzig");

// Compares executeNumbersFast against the general execute() bit-for-bit on
// eligible expressions, including edge inputs (NaN, ±0, inf).
test "widened fast path is bit-identical to general interpreter" {
    const allocator = std.testing.allocator;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const exprs = [_][]const u8{
        "x > 1 && y < 100 ? x * 2 + y : y / 2 - x",
        "x >= y ? x - y : y - x",
        "x == y ? 1 : 0",
        "x != y || y > 10 ? x ^ 2 : x ^ 3",
        "!(x > y) ? x / y : y / x",
        "a = x * 2; b = a + y; a > b ? a : b",
        "s = 0; k = 0; while (k < 10) { s = s + x * k; k = k + 1 }; s",
        "x > 0 ? x / 0 : -1",
        "x < 0 ? 0 / 0 : x % 3",
        "1 > 0 ? x ^ 12 : 0",
        "x ^ -2 > 0 ? x ^ -2 : 1",
        "true ? x + 0.1 : 99",
        "x > y == (y < x) ? 5 : 6",
        // Whitelisted builtins (bytecode.isFastPathBuiltin)
        "sin(x) > 0 ? cos(y) : tan(x)",
        "x > 0 ? log(x) : exp(y)",
        "abs(x) + floor(y) - ceil(x) * round(y)",
        "min(x, y) < max(x, y) ? hypot(x, y) : atan2(x, y)",
        "gamma(abs(x % 4) + 1) + lgamma(abs(y % 3) + 1) + sign(y)",
        "asin(x / 10) + acos(y / 100) + atan(x)",
        "sinh(x % 5) - cosh(y % 5) + tanh(x) + asinh(x) - atanh(y % 1)",
        "sec(x) + csc(y) + cot(x % 7)",
        "log10(abs(x) + 1) + log2(abs(y) + 1) + log(abs(x) + 2, 10)",
        "q = square(x); q + cube(y % 3) + cbrt(x)",
        "erf(x % 2) + expm1(x % 2) + log1p(abs(y % 2))",
        "s = 0; k = 0; while (k < 6) { s = s + sin(k * x) ^ 2 + cos(k) ^ 2; k = k + 1 }; s",
        "trunc(x) + nthRoot(abs(y)) + nthRoot(abs(x) + 1, 3)",
    };
    const inputs = [_][2]f64{
        .{ 3.25, 7.5 },
        .{ -1.5, 42.0 },
        .{ 0.0, -0.0 },
        .{ -0.0, 0.0 },
        .{ std.math.nan(f64), 1.0 },
        .{ std.math.inf(f64), -std.math.inf(f64) },
        .{ 1e308, 1e-308 },
        .{ 7.0, 7.0 },
    };

    const x_idx = ctx.getOrCreateVariable("x");
    const y_idx = ctx.getOrCreateVariable("y");

    var checked: usize = 0;
    for (exprs) |src| {
        const expr = try ctx.compile(src);
        defer ctx.freeExpr(expr);
        if (!(expr.fast_path_ok or expr.is_number_only)) {
            std.debug.print("not fast-path eligible: {s}\n", .{src});
            return error.TestUnexpectedResult;
        }

        for (inputs) |in| {
            ctx.setVariableByIndexF64(x_idx, in[0]);
            ctx.setVariableByIndexF64(y_idx, in[1]);
            const fast = ctx.vm.executeNumbersFast(expr) orelse {
                std.debug.print("unexpected fast-path fallback: {s}\n", .{src});
                return error.TestUnexpectedResult;
            };

            // Reset variables (expressions with assignments mutate state)
            ctx.setVariableByIndexF64(x_idx, in[0]);
            ctx.setVariableByIndexF64(y_idx, in[1]);
            const general = try ctx.vm.execute(expr);
            const gnum = general.toNumber() orelse return error.TestUnexpectedResult;

            const fast_bits: u64 = @bitCast(fast);
            const gen_bits: u64 = @bitCast(gnum);
            if (fast_bits != gen_bits) {
                std.debug.print("MISMATCH {s} x={e} y={e}: fast={e} ({x}) general={e} ({x})\n", .{ src, in[0], in[1], fast, fast_bits, gnum, gen_bits });
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
    }
    std.debug.print("bit-identical on {d} expression/input combos\n", .{checked});
}
