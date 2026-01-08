//! task-15 hard-error lock-in: every builtin that is unresolvable under
//! `-s/--standalone` (per RequiredRuntimeSet.firstUnresolvedStandalone —
//! standaloneImplemented + opcode/arity + where status, NOT StandaloneTier
//! tags alone) hard-errors with the builtin name in the diagnostic.
//!
//! Checked-total fixture factory: every BuiltinFn has a syntactically valid
//! expression; the test fails if any *enumerated unresolvable* builtin lacks
//! a non-null fixture (new builtins cannot dodge coverage).

const std = @import("std");
const mathzig = @import("mathzig");
const wasm = mathzig.wasm;
const abi = wasm.abi;
const BuiltinFn = mathzig.BuiltinFn;

const SERIES = "series([0, 1, 2, 3, 4], [10, 20, 30, 40, 50])";
const MAT = "[1, 2; 3, 4]";
const MAT_COL = "[1; 2]";
const COMPLEX = "(3 + 4i)";

/// Checked-total fixture: one compileable DSL expression per BuiltinFn.
/// Returns null only for members that cannot be named in user DSL (none today).
fn fixtureFor(f: BuiltinFn) ?[]const u8 {
    return switch (f) {
        .abs => "abs(-3)",
        .sqrt => "sqrt(4)",
        .cbrt => "cbrt(8)",
        .exp => "exp(1)",
        .log => "log(1)",
        .log10 => "log10(1000)",
        .log2 => "log2(8)",
        .sin => "sin(0)",
        .cos => "cos(0)",
        .tan => "tan(0)",
        .asin => "asin(0)",
        .acos => "acos(1)",
        .atan => "atan(0)",
        .atan2 => "atan2(0, 1)",
        .sinh => "sinh(0)",
        .cosh => "cosh(0)",
        .tanh => "tanh(0)",
        .sec => "sec(1)",
        .csc => "csc(1)",
        .cot => "cot(1)",
        .asec => "asec(1)",
        .acsc => "acsc(1)",
        .acot => "acot(0)",
        .floor => "floor(1.5)",
        .ceil => "ceil(1.5)",
        .round => "round(1.5)",
        .trunc => "trunc(1.5)",
        .sign => "sign(-2)",
        .min => "min([1, 2, 3])", // 1-arg matrix form (2-arg is opcode-only)
        .max => "max([1, 2, 3])",
        .clamp => "clamp(5, 0, 10)",
        .hypot => "hypot(3, 4)",
        .norm => "norm([3, 4])",
        .random => "random()",
        .randomInt => "randomInt(1, 10)",
        .pickRandom => "pickRandom([1, 2, 3])",
        .square => "square(3)",
        .cube => "cube(2)",
        .nthRoot => "nthRoot(8, 3)",
        .log1p => "log1p(0)",
        .expm1 => "expm1(0)",
        .asinh => "asinh(0)",
        .acosh => "acosh(1)",
        .atanh => "atanh(0)",
        .sech => "sech(0)",
        .csch => "csch(1)",
        .coth => "coth(1)",
        .asech => "asech(0.5)",
        .acsch => "acsch(1)",
        .acoth => "acoth(2)",
        .factorial => "factorial(5)",
        .gamma => "gamma(5)",
        .lgamma => "lgamma(5)",
        .erf => "erf(0)",
        .combinations => "combinations(5, 2)",
        .permutations => "permutations(5, 2)",
        .re => "re(" ++ COMPLEX ++ ")",
        .im => "im(" ++ COMPLEX ++ ")",
        .arg => "arg(1 + i)",
        .conj => "conj(" ++ COMPLEX ++ ")",
        .det => "det(" ++ MAT ++ ")",
        .inv => "inv([2, 0; 0, 4])",
        .transpose => "transpose(" ++ MAT ++ ")",
        .gemv => "gemv(" ++ MAT ++ ", " ++ MAT_COL ++ ")",
        .size => "size(" ++ MAT ++ ").rows",
        .trace => "trace(" ++ MAT ++ ")",
        .dot => "dot([1, 2, 3], [4, 5, 6])",
        .cross => "cross([1, 0, 0], [0, 1, 0])",
        .reshape => "reshape([1, 2, 3, 4, 5, 6], 2, 3)",
        .flatten => "flatten(" ++ MAT ++ ")",
        .concat => "concat([1, 2], [3, 4])",
        .diag => "diag([1, 2, 3; 4, 5, 6; 7, 8, 9])",
        .identity => "identity(3)",
        .zeros => "zeros(2, 2)",
        .ones => "ones(2, 2)",
        .mean => "mean(" ++ SERIES ++ ")",
        .sum => "sum(" ++ SERIES ++ ")",
        .count => "count(" ++ SERIES ++ ")",
        .median => "median([1, 2, 3])",
        .std => "std([1, 2, 3])",
        .variance => "variance([1, 2, 3, 4])",
        .mad => "mad([1, 2, 3])",
        .prod => "prod(" ++ SERIES ++ ")",
        .gcd => "gcd(12, 18)",
        .lcm => "lcm(4, 6)",
        .isPrime => "isPrime(7)",
        // Must leave call_builtin in bytecode (const-fold of 5*cm would erase conv).
        .conv => "conv(x, m)",
        .number => "number(x, m)",
        .read_csv => "read_csv(\"no_such_file_task15.csv\")",
        .write_csv => "write_csv(\"no_such_out_task15.csv\", " ++ SERIES ++ ")",
        .assert => "assert(1 == 1)",
        .cumsum => "cumsum(" ++ SERIES ++ ")",
        .cummax => "cummax(" ++ SERIES ++ ")",
        .cummin => "cummin(" ++ SERIES ++ ")",
        .rolling_sum => "rolling_sum(" ++ SERIES ++ ", 2)",
        .rolling_mean => "rolling_mean(" ++ SERIES ++ ", 2)",
        .rolling_min => "rolling_min(" ++ SERIES ++ ", 2)",
        .rolling_max => "rolling_max(" ++ SERIES ++ ", 2)",
        .rolling_count => "rolling_count(" ++ SERIES ++ ", 2)",
        .rolling_stddev => "rolling_stddev(" ++ SERIES ++ ", 2)",
        .diff => "diff(" ++ SERIES ++ ", 1)",
        .pct_change => "pct_change(" ++ SERIES ++ ", 1)",
        .series => SERIES,
        .twa => "twa(" ++ SERIES ++ ")",
        .derivative => "derivative(" ++ SERIES ++ ")",
        .integrate => "integrate(" ++ SERIES ++ ")",
        .sma => "sma(" ++ SERIES ++ ", 2)",
        .ema => "ema(" ++ SERIES ++ ", 2)",
        .rsi => "rsi(" ++ SERIES ++ ", 2)",
        .last => "last(" ++ SERIES ++ ")",
        .duration => "duration(" ++ SERIES ++ ")",
        .asofJoin => "asofJoin(" ++ SERIES ++ ", " ++ SERIES ++ ")",
        .resample => "resample(" ++ SERIES ++ ", 1, \"mean\")",
        .align_ => "align(" ++ SERIES ++ ", " ++ SERIES ++ ")",
        .head => "head(" ++ SERIES ++ ", 2)",
        .tail => "tail(" ++ SERIES ++ ", 2)",
        .slice => "slice(" ++ SERIES ++ ", 0, 2)",
        .between => "between(" ++ SERIES ++ ", 0, 2)",
        .since => "since(" ++ SERIES ++ ", 2)",
        .shift => "shift(" ++ SERIES ++ ", 1)",
        .dropna => "dropna(" ++ SERIES ++ ")",
        .fillna => "fillna(" ++ SERIES ++ ", 0)",
        .clip => "clip(" ++ SERIES ++ ", 0, 100)",
        .bollinger => "bollinger(" ++ SERIES ++ ", 2)",
        .macd => "macd(" ++ SERIES ++ ", 2)",
        .gen_range => "range(0, 3)",
        .linspace => "linspace(0, 1, 5)",
        .logspace => "logspace(0, 1, 5)",
        .agg_range => "range(" ++ SERIES ++ ")",
        .now => "now()",
        .ode_solve => "f(t, y) = -y; ode_solve(\"f\", [1], [0, 1], 0.1)",
        .ode_solve_euler => "f(t, y) = -y; ode_solve_euler(\"f\", [1], [0, 1], 0.1)",
        .toLaTeX => "toLaTeX(\"x^2\")",
        .create_unit => "create_unit(\"points_task15\", 1)",
        .config => "config(\"angle\", \"rad\")",
    };
}

/// Representative arity for RequiredRuntimeSet membership (matches common call).
fn representativeArity(f: BuiltinFn) u8 {
    const sig = abi.signature(f);
    // Prefer min_args for variadic / optional trailing forms; min/max use 1-arg
    // matrix reduction (unresolvable) rather than 2-arg opcode-only form.
    return switch (f) {
        .min, .max => 1,
        else => sig.min_args,
    };
}

/// Membership = actual resolvability predicate (firstUnresolvedStandalone),
/// not StandaloneTier tags.
fn isUnresolvableStandalone(f: BuiltinFn) bool {
    var set = abi.RequiredRuntimeSet{};
    set.addBuiltin(f, representativeArity(f), false);
    return set.firstUnresolvedStandalone() != null;
}

test "hard-error lock-in: fixtures are checked-total over BuiltinFn" {
    const fields = std.meta.fields(BuiltinFn);
    inline for (fields) |field| {
        // fixtureFor is a total switch — missing member is a compile error.
        // Runtime null check keeps the "checked-total" invariant explicit.
        const f: BuiltinFn = @field(BuiltinFn, field.name);
        try std.testing.expect(fixtureFor(f) != null);
    }
}

test "hard-error lock-in: every resolvability-unresolvable builtin hard-errors under -s" {
    const allocator = std.testing.allocator;
    var unresolved_count: usize = 0;
    var failures: usize = 0;

    // Runtime loop over enum tags — avoids inline-for + continue comptime issues.
    var tag_i: u16 = 0;
    while (tag_i <= @intFromEnum(BuiltinFn.config)) : (tag_i += 1) {
        const f: BuiltinFn = @enumFromInt(tag_i);
        // Skip holes if any (dense enum today).
        if (@intFromEnum(f) != tag_i) continue;
        if (!isUnresolvableStandalone(f)) continue;
        unresolved_count += 1;

        const expr_src = fixtureFor(f) orelse {
            failures += 1;
            std.debug.print("no fixture for unresolvable builtin {s}\n", .{@tagName(f)});
            continue;
        };

        var ctx = try mathzig.MathZig.init(allocator);
        defer ctx.deinit();

        const expr_or_err = ctx.compile(expr_src);
        if (expr_or_err) |expr| {
            defer ctx.freeExpr(expr);

            var compiler = wasm.compiler.WasmCompiler.init(allocator);
            defer compiler.deinit();
            const compile_res = compiler.compile(expr, .{ .function_name = "eval", .standalone = true });
            if (compile_res) |_| {
                failures += 1;
                std.debug.print("expected StandaloneUnsupportedImport for {s}, got success\n", .{@tagName(f)});
            } else |e| {
                if (e != error.StandaloneUnsupportedImport) {
                    failures += 1;
                    std.debug.print("expected StandaloneUnsupportedImport for {s}, got {s}\n", .{ @tagName(f), @errorName(e) });
                } else if (compiler.standalone_error_msg) |msg| {
                    // Named-builtin compile error (membership from resolvability predicate).
                    if (std.mem.indexOf(u8, msg, @tagName(f)) == null) {
                        failures += 1;
                        std.debug.print("message for {s} missing name: {s}\n", .{ @tagName(f), msg });
                    }
                } else {
                    failures += 1;
                    std.debug.print("no standalone_error_msg for {s}\n", .{@tagName(f)});
                }
            }
        } else |e| {
            failures += 1;
            std.debug.print("fixture compile failed for {s}: {s} ({s})\n", .{ @tagName(f), expr_src, @errorName(e) });
        }
    }

    // Enumerated count must stay positive (membership from resolvability predicate).
    try std.testing.expect(unresolved_count >= 50); // currently 63; floor guards collapse
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "hard-error lock-in: where-variant is unresolvable even when base is implemented" {
    // mean is Tier-ish implemented standalone; mean_where is not.
    var set = abi.RequiredRuntimeSet{};
    set.addBuiltin(.mean, 1, true);
    const u = set.firstUnresolvedStandalone().?;
    try std.testing.expectEqual(BuiltinFn.mean, u.builtin);
    try std.testing.expectEqualStrings("where-variant", u.reason);
}

test "hard-error lock-in: implemented scalar is resolvable (negative control)" {
    var set = abi.RequiredRuntimeSet{};
    set.addBuiltin(.sin, 1, false);
    try std.testing.expect(set.firstUnresolvedStandalone() == null);
}
