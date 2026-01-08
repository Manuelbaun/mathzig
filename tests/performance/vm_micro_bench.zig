//! Micro-benchmarks targeting the general VM execute() loop, user-function
//! calls, and compiler throughput. These paths are underrepresented in
//! perf_runner.zig (which mostly measures the f64/SIMD fast paths).
//!
//! Each benchmark prints a result checksum with full precision so that
//! before/after runs can be diffed for bit-exactness.
const std = @import("std");
const mz = @import("mathzig");

const Allocator = std.mem.Allocator;

fn report(name: []const u8, iterations: usize, duration_ns: u64, checksum: f64) void {
    const ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops = @as(f64, @floatFromInt(iterations)) / (ms / 1000.0);
    std.debug.print("{s},{d},{d:.4},{d:.2},checksum={e}\n", .{ name, iterations, ms, ops, checksum });
}

/// General execute() loop on a pure-arithmetic expression (bypasses the
/// number-only fast path by calling vm.execute directly).
fn benchGeneralArith(allocator: Allocator) !void {
    const ITERATIONS = 1_000_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("x * 2.5 + y * 1.5 - z / 3.0 + x * y");
    defer ctx.freeExpr(expr);

    ctx.setVariableByIndexF64(ctx.getOrCreateVariable("x"), 3.25);
    ctx.setVariableByIndexF64(ctx.getOrCreateVariable("y"), 7.5);
    ctx.setVariableByIndexF64(ctx.getOrCreateVariable("z"), 11.0);

    var checksum: f64 = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const res = try ctx.vm.execute(expr);
        checksum += res.toNumber() orelse 0;
    }
    report("general_execute_arith", ITERATIONS, timer.read(), checksum);
}

/// Mixed expression with comparisons and a ternary — is_number_only is false,
/// so the public evaluate() also lands in the general loop.
fn benchGeneralMixed(allocator: Allocator) !void {
    const ITERATIONS = 1_000_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("x > 1 && y < 100 ? x * 2 + y : y / 2 - x");
    defer ctx.freeExpr(expr);

    const x_idx = ctx.getOrCreateVariable("x");
    ctx.setVariableByIndexF64(ctx.getOrCreateVariable("y"), 42.0);

    var checksum: f64 = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        ctx.vm.variables_f64[x_idx] = @floatFromInt(i % 7);
        ctx.vm.variables[x_idx] = mz.Value.initNumber(@floatFromInt(i % 7));
        const res = try ctx.vm.execute(expr);
        checksum += res.toNumber() orelse 0;
    }
    report("general_execute_mixed_cmp", ITERATIONS, timer.read(), checksum);
}

/// Sequence of discarded assignments (exercises dup/store_var/pop chains and
/// the general loop's store path).
fn benchAssignSequence(allocator: Allocator) !void {
    const ITERATIONS = 500_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("a = x * 2; b = a + 3; c = b * a - x; c / (a + 1)");
    defer ctx.freeExpr(expr);

    const x_idx = ctx.getOrCreateVariable("x");
    ctx.setVariableByIndexF64(x_idx, 1.5);

    var checksum: f64 = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const res = try ctx.vm.execute(expr);
        checksum += res.toNumber() orelse 0;
    }
    report("general_execute_assign_seq", ITERATIONS, timer.read(), checksum);
}

/// Same mixed expression as benchGeneralMixed but through the public
/// evaluate() routing, which may select the widened f64 fast path.
fn benchEvaluateMixed(allocator: Allocator) !void {
    const ITERATIONS = 1_000_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("x > 1 && y < 100 ? x * 2 + y : y / 2 - x");
    defer ctx.freeExpr(expr);

    const x_idx = ctx.getOrCreateVariable("x");
    ctx.setVariableByIndexF64(ctx.getOrCreateVariable("y"), 42.0);

    var checksum: f64 = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        ctx.setVariableByIndexF64(x_idx, @floatFromInt(i % 7));
        const res = try ctx.evaluate(expr);
        checksum += res.toNumber() orelse 0;
    }
    report("evaluate_mixed_cmp", ITERATIONS, timer.read(), checksum);
}

/// Numeric while-loop through evaluate() routing (100 iterations per eval).
fn benchEvaluateLoop(allocator: Allocator) !void {
    const ITERATIONS = 100_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("s = 0; k = 0; while (k < 100) { s = s + x * k; k = k + 1 }; s");
    defer ctx.freeExpr(expr);

    const x_idx = ctx.getOrCreateVariable("x");
    ctx.setVariableByIndexF64(x_idx, 1.5);

    var checksum: f64 = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const res = try ctx.evaluate(expr);
        checksum += res.toNumber() orelse 0;
    }
    report("evaluate_while_loop_100", ITERATIONS, timer.read(), checksum);
}

/// User-defined function call (exercises call_user / sub-VM creation).
fn benchUserFunctionCall(allocator: Allocator) !void {
    const ITERATIONS = 200_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const def_res = try ctx.eval("f(x) = x * 2 + 1");
    def_res.release();

    const expr = try ctx.compile("f(3.5) + f(1.25)");
    defer ctx.freeExpr(expr);

    var checksum: f64 = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const res = try ctx.vm.execute(expr);
        checksum += res.toNumber() orelse 0;
    }
    report("user_function_call", ITERATIONS, timer.read(), checksum);
}

/// Compile throughput on a long expression (exercises tokenizer, parser,
/// simplify, optimizeBytecode).
fn benchCompileLong(allocator: Allocator) !void {
    const ITERATIONS = 2_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Build a long expression: x*1.0 + x*2.0 + ... (200 terms)
    var src: std.ArrayListUnmanaged(u8) = .{};
    defer src.deinit(allocator);
    try src.appendSlice(allocator, "x * 0.5");
    var t: usize = 1;
    while (t < 200) : (t += 1) {
        try src.writer(allocator).print(" + x * {d}.25", .{t});
    }

    var checksum: f64 = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const expr = try ctx.compile(src.items);
        checksum += @floatFromInt(expr.code.len);
        ctx.freeExpr(expr);
    }
    report("compile_long_expr_200_terms", ITERATIONS, timer.read(), checksum);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try benchGeneralArith(allocator);
    try benchGeneralMixed(allocator);
    try benchEvaluateMixed(allocator);
    try benchEvaluateLoop(allocator);
    try benchAssignSequence(allocator);
    try benchUserFunctionCall(allocator);
    try benchCompileLong(allocator);
}
