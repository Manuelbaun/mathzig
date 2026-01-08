const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;
const kernels = mz.matrix_kernels;

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const feature_id = if (args.len > 1) args[1] else "baseline";

    // Get timestamp
    var buf: [64]u8 = undefined;
    const now = std.time.timestamp();
    const timestamp = try std.fmt.bufPrint(&buf, "{d}", .{now});

    // Arithmetic
    try runArithmeticBenchmark(allocator, feature_id, timestamp);
    try runArithmeticBatchBenchmark(allocator, feature_id, timestamp);
    // Complex
    try runComplexBatchBenchmark(allocator, feature_id, timestamp);
    try runComplexPowBenchmark(allocator, feature_id, timestamp);
    // Matrix
    try runMatrixBenchmark(allocator, feature_id, timestamp);
    try runIndexingBenchmark(allocator, feature_id, timestamp);
    try runVecDotBenchmark(allocator, feature_id, timestamp);
    // Time-Series
    try runTimeSeriesBenchmark(allocator, feature_id, timestamp);
    try runTimeSeriesScalarAggBenchmark(allocator, feature_id, timestamp);
    try runTimeSeriesSIMDAggBenchmark(allocator, feature_id, timestamp);
    // ODE
    try runODEBenchmark(allocator, feature_id, timestamp);
}

fn logResult(ctx: *mz.MathZig, timestamp: []const u8, feature_id: []const u8, test_name: []const u8, iterations: usize, duration_ms: f64) void {
    const suffix = getLabelSuffix();
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);
    const mem_allocated = ctx.getMemoryUsed();
    const mem_reserved = ctx.getMemoryReserved();
    const mem_peak = ctx.getMemoryPeak();
    // Format: timestamp,feature_id,test_name,iterations,duration_ms,ops_per_sec,mem_allocated,mem_reserved,mem_peak
    std.debug.print("{s},{s},{s}{s},{d},{d:.4},{d:.2},{d},{d},{d}\n", .{
        timestamp,
        feature_id,
        test_name,
        suffix,
        iterations,
        duration_ms,
        ops_per_sec,
        mem_allocated,
        mem_reserved,
        mem_peak,
    });
}

fn getLabelSuffix() []const u8 {
    const raw = std.posix.getenvZ("MATHZIG_LABEL_SUFFIX") orelse return "";
    return std.mem.sliceTo(raw, 0);
}

fn runArithmeticBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const ITERATIONS = 1_000_000;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("x * 0.5 + 2.0");
    defer ctx.freeExpr(expr);

    const x_idx = ctx.getOrCreateVariable("x");

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        ctx.vm.variables_f64[x_idx] = @as(f64, @floatFromInt(i));
        _ = ctx.vm.executeNumbersOnlyUnchecked(expr);
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_arithmetic_scalar_fast", ITERATIONS, duration_ms);
}

fn runArithmeticBatchBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const ITERATIONS = 1_000_000;
    const BATCH_SIZE = 10_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const expr = try ctx.compile("x * 0.5 + 2.0");
    defer ctx.freeExpr(expr);

    const x_idx = @as(u8, @intCast(ctx.getOrCreateVariable("x")));

    const inputs = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);
    const outputs = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);

    const inputs_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, inputs)));
    const outputs_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, outputs)));

    for (0..BATCH_SIZE) |i| {
        inputs_f64[i] = @floatFromInt(i);
    }

    var timer = try std.time.Timer.start();
    const start = timer.read();

    const loops = ITERATIONS / BATCH_SIZE;
    var i: usize = 0;
    while (i < loops) : (i += 1) {
        ctx.vm.executeBatchSIMD(expr, x_idx, inputs_f64[0..BATCH_SIZE], outputs_f64[0..BATCH_SIZE], BATCH_SIZE);
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_arithmetic_batch_simd", ITERATIONS, duration_ms);
}

fn runComplexBatchBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const ITERATIONS = 1_000_000;
    const BATCH_SIZE = 10_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Expression: (z + 2*i) / (z - 2*i)
    const expr = try ctx.compile("(z + 2*i) / (z - 2*i)");
    defer ctx.freeExpr(expr);

    const z_idx = @as(u8, @intCast(ctx.getOrCreateVariable("z")));

    const inputs_re = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);
    const inputs_im = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);
    const outputs_re = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);
    const outputs_im = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);

    const re_in_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, inputs_re)));
    const im_in_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, inputs_im)));
    const re_out_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, outputs_re)));
    const im_out_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, outputs_im)));

    for (0..BATCH_SIZE) |k| {
        re_in_f64[k] = @floatFromInt(k);
        im_in_f64[k] = @as(f64, @floatFromInt(k)) * 0.5;
    }

    var timer = try std.time.Timer.start();
    const start = timer.read();

    const loops = ITERATIONS / BATCH_SIZE;
    var i: usize = 0;
    while (i < loops) : (i += 1) {
        ctx.vm.executeBatchComplexSIMD(expr, z_idx, re_in_f64[0..BATCH_SIZE], im_in_f64[0..BATCH_SIZE], re_out_f64[0..BATCH_SIZE], im_out_f64[0..BATCH_SIZE], BATCH_SIZE);
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_complex_div_batch_simd", ITERATIONS, duration_ms);
}

fn runComplexPowBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const ITERATIONS = 1_000_000;
    const BATCH_SIZE = 10_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Expression: z ^ 2
    const expr = try ctx.compile("z ^ 2");
    defer ctx.freeExpr(expr);

    const z_idx = @as(u8, @intCast(ctx.getOrCreateVariable("z")));

    const inputs_re = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);
    const inputs_im = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);
    const outputs_re = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);
    const outputs_im = ctx.arena.allocAligned(BATCH_SIZE * 8, 32);

    const inputs_re_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, inputs_re)));
    const inputs_im_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, inputs_im)));
    const outputs_re_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, outputs_re)));
    const outputs_im_f64 = @as([]f64, @alignCast(std.mem.bytesAsSlice(f64, outputs_im)));

    for (0..BATCH_SIZE) |k| {
        inputs_re_f64[k] = @floatFromInt(k);
        inputs_im_f64[k] = @as(f64, @floatFromInt(k)) * 0.1;
    }

    var timer = try std.time.Timer.start();
    const start = timer.read();

    const loops = ITERATIONS / BATCH_SIZE;
    var i: usize = 0;
    while (i < loops) : (i += 1) {
        ctx.vm.executeBatchComplexSIMD(expr, z_idx, inputs_re_f64[0..BATCH_SIZE], inputs_im_f64[0..BATCH_SIZE], outputs_re_f64[0..BATCH_SIZE], outputs_im_f64[0..BATCH_SIZE], BATCH_SIZE);
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_complex_pow_batch_simd", ITERATIONS, duration_ms);
}

fn runMatrixBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const N = 100;
    const ITERATIONS = 100;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const a = try allocator.alignedAlloc(f64, .@"32", N * N);
    defer allocator.free(a);
    const b = try allocator.alignedAlloc(f64, .@"32", N * N);
    defer allocator.free(b);
    const c = try allocator.alignedAlloc(f64, .@"32", N * N);
    defer allocator.free(c);

    @memset(a, 1.0);
    @memset(b, 1.0);
    @memset(c, 0.0);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        kernels.gemm(N, N, N, a, N, b, N, c, N);
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_matrix_multiply_100x100", ITERATIONS, duration_ms);
}

fn runIndexingBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const ITERATIONS = 500_000;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const vec = try mz.Matrix.init(allocator, 4, 1);
    vec.set(0, 0, 1.0);
    vec.set(1, 0, 2.0);
    vec.set(2, 0, 3.0);
    vec.set(3, 0, 4.0);
    ctx.setVariable("v", mz.Value.initMatrix(vec));

    const idx_var = ctx.getOrCreateVariable("idx");
    const expr_dynamic_key = try ctx.compile("v[idx]");
    defer ctx.freeExpr(expr_dynamic_key);
    const expr_const_key = try ctx.compile("v[0]");
    defer ctx.freeExpr(expr_const_key);

    var timer = try std.time.Timer.start();
    const start_dynamic_key = timer.read();

    var iter: usize = 0;
    while (iter < ITERATIONS) : (iter += 1) {
        ctx.vm.variables_f64[idx_var] = @as(f64, @floatFromInt(iter & 3));
        const res = try ctx.evaluate(expr_dynamic_key);
        res.release();
    }

    const end_dynamic_key = timer.read();
    const duration_dynamic_key_ms = @as(f64, @floatFromInt(end_dynamic_key - start_dynamic_key)) / 1_000_000.0;
    logResult(ctx, timestamp, feature_id, "zig_vm_get_index_dynamic_key_vector", ITERATIONS, duration_dynamic_key_ms);

    const start_const_key = timer.read();
    iter = 0;
    while (iter < ITERATIONS) : (iter += 1) {
        const res = try ctx.evaluate(expr_const_key);
        res.release();
    }

    const end_const_key = timer.read();
    const duration_const_key_ms = @as(f64, @floatFromInt(end_const_key - start_const_key)) / 1_000_000.0;
    logResult(ctx, timestamp, feature_id, "zig_vm_get_index_const_key_vector", ITERATIONS, duration_const_key_ms);
}

fn runVecDotBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const sizes = [_]usize{ 64, 1024, 65536, 1048576 };

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    for (sizes) |size| {
        const iterations = @max(10000, 1000000000 / size);

        // Allocate aligned vectors
        const a = try allocator.alignedAlloc(f64, .@"32", size);
        const b = try allocator.alignedAlloc(f64, .@"32", size);
        defer allocator.free(a);
        defer allocator.free(b);

        // Initialize with test data
        for (0..size) |i| {
            a[i] = @as(f64, @floatFromInt(i % 1000)) * 0.01;
            b[i] = @as(f64, @floatFromInt(i % 1000)) * 0.01;
        }

        // Warmup
        var warmup: usize = 0;
        while (warmup < 10) : (warmup += 1) {
            _ = kernels.vecDot(a, b);
        }

        // Benchmark
        var timer = try std.time.Timer.start();
        const start = timer.read();

        var dummy: f64 = 0;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            dummy += kernels.vecDot(a, b);
        }

        const end = timer.read();
        if (dummy == 0.123456789) std.debug.print(" ", .{});
        const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

        const test_name = try std.fmt.allocPrint(allocator, "zig_vecdot_{d}", .{size});
        defer allocator.free(test_name);

        logResult(ctx, timestamp, feature_id, test_name, iterations, duration_ms);
    }
}

fn runTimeSeriesBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const SAMPLES = 100_000;
    const ITERATIONS = 10;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const series = try ts.Series.init(allocator, SAMPLES, .Linear, .{});
    defer series.deinit();

    for (0..SAMPLES) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1);
    }
    try series.validate();

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        _ = ts.sum(series, null);
        _ = ts.twa(series, null);
        const rsi = try ts.rsi(series, 14, allocator);
        rsi.deinit();
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_timeseries_stats_100k", ITERATIONS, duration_ms);
}

fn runTimeSeriesScalarAggBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const SAMPLES = 1_000_000;
    const ITERATIONS = 100;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const series = try ts.Series.init(allocator, SAMPLES, .Linear, .{});
    defer series.deinit();

    for (0..SAMPLES) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @as(f64, @floatFromInt(i));
    }
    try series.validate();

    // Force scalar path by providing a predicate
    // We manually allocate a Predicate struct since it's re-exported via mz.timeseries
    const pred = try allocator.create(ts.Predicate);
    pred.* = .{
        .op = .gt,
        .field = .value,
        .constant = -std.math.inf(f64), // Always true
    };
    defer allocator.destroy(pred);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var dummy: f64 = 0;
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        dummy += ts.sum(series, pred);
        dummy += ts.mean(series, pred);
        dummy += ts.min(series, pred);
        dummy += ts.max(series, pred);
    }

    const end = timer.read();
    if (dummy == 0.1234567) std.debug.print(" ", .{});
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_timeseries_scalar_aggregations_1M", ITERATIONS, duration_ms);
}

fn runTimeSeriesSIMDAggBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const SAMPLES = 1_000_000;
    const ITERATIONS = 100;

    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    const series = try ts.Series.init(allocator, SAMPLES, .Linear, .{});
    defer series.deinit();

    for (0..SAMPLES) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @as(f64, @floatFromInt(i));
    }
    try series.validate();

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    var dummy: f64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        dummy += ts.sum(series, null);
        dummy += ts.mean(series, null);
        dummy += ts.min(series, null);
        dummy += ts.max(series, null);
    }

    const end = timer.read();
    if (dummy == 0.1234567) std.debug.print(" ", .{}); // Prevent dummy being optimized away
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_timeseries_simd_aggregations_1M", ITERATIONS, duration_ms);
}

fn runODEBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const ITERATIONS = 100;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // Define harmonic oscillator: dy/dt = [y2, -y1]
    _ = try ctx.eval("osc(t, y) = [y[1]; -y[0]]");

    // y0 = [0; 1], t_span = [0, 100], dt = 0.01 (10,000 steps)
    const expr = try ctx.compile("ode_solve(\"osc\", [0; 1], [0, 100], 0.01)");
    defer ctx.freeExpr(expr);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const res = try ctx.evaluate(expr);
        res.release();
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_ode_solve_10k_steps", ITERATIONS, duration_ms);

    // Lorenz attractor benchmark (3D system, uses vector path)
    runLorenzBenchmark(allocator, feature_id, timestamp) catch |err| {
        std.debug.print("Lorenz benchmark error: {}\n", .{err});
    };
}

fn runLorenzBenchmark(allocator: Allocator, feature_id: []const u8, timestamp: []const u8) !void {
    const ITERATIONS = 50;
    var ctx = try mz.MathZig.init(allocator);
    defer ctx.deinit();

    // First test: Simple 3D system (just permutation) to verify 3D works
    const simple_def = ctx.eval("simple3d(t, y) = [y[1]; y[2]; y[0]]") catch |err| {
        std.debug.print("Simple 3D function definition error: {}\n", .{err});
        return err;
    };
    _ = simple_def;

    // Test simple 3D ODE first
    const simple_expr = ctx.compile("ode_solve(\"simple3d\", [1; 2; 3], [0, 1], 0.1)") catch |err| {
        std.debug.print("Simple 3D compile error: {}\n", .{err});
        return err;
    };

    const simple_res = ctx.evaluate(simple_expr) catch |err| {
        std.debug.print("Simple 3D evaluate error: {}\n", .{err});
        ctx.freeExpr(simple_expr);
        return err;
    };
    simple_res.release();
    ctx.freeExpr(simple_expr);
    // Now test Lorenz
    const def_result = ctx.eval("lorenz(t, y) = [10*(y[1]-y[0]); y[0]*(28-y[2])-y[1]; y[0]*y[1] - 2.667*y[2]]") catch |err| {
        std.debug.print("Lorenz function definition error: {}\n", .{err});
        return err;
    };
    _ = def_result;

    // y0 = [1; 1; 1], t_span = [0, 50], dt = 0.01 (5000 steps)
    const expr = ctx.compile("ode_solve(\"lorenz\", [1; 1; 1], [0, 50], 0.01)") catch |err| {
        std.debug.print("Lorenz compile error: {}\n", .{err});
        return err;
    };
    defer ctx.freeExpr(expr);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const res = ctx.evaluate(expr) catch |err| {
            std.debug.print("Lorenz evaluate error (iter {}): {}\n", .{ i, err });
            return err;
        };
        res.release();
    }

    const end = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    logResult(ctx, timestamp, feature_id, "zig_lorenz_5k_steps", ITERATIONS, duration_ms);
}
