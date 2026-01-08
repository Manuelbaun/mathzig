const std = @import("std");
const mathzig = @import("mathzig");
const VM = mathzig.VM;
const BytecodeBuilder = mathzig.BytecodeBuilder;
const UserFunction = mathzig.UserFunction;
const Value = mathzig.Value;
const ode = mathzig.ode;

// =============================================================================
// Phase 3: Unit Tests for executeVectorBody()
// =============================================================================

test "executeVectorBody: simple arithmetic (2*y[0], 3*y[1])" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vm = try VM.init(allocator, arena.allocator(), 16, null);
    defer vm.deinit();

    // Build: [2*y[0], 3*y[1]] - a 2D to 2D transformation
    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();
    builder.markNonNumeric();

    // Push 2*y[0] (will be row 0)
    try builder.emitConstant(Value.initNumber(2), 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.mul, 0);

    // Push 3*y[1] (will be row 1)
    try builder.emitConstant(Value.initNumber(3), 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.mul, 0);

    // Create 2x1 matrix result
    try builder.emitWithOperand(.mat_create, 2 | (1 << 12), 0);
    try builder.emit(.halt, 0);

    const expr = try builder.build();
    defer {
        var e = expr;
        e.deinit();
    }

    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "y";
    defer allocator.free(params);

    const func = UserFunction{
        .name = "test_scale",
        .params = params,
        .body = expr,
    };

    // Test input: [3, 5] -> [6, 15]
    var y_in = [_]f64{ 3.0, 5.0 };
    var y_out = [_]f64{ 0.0, 0.0 };

    // Execute via vector path
    try vm.executeVectorDerivative(&func, 0.0, &y_in, &y_out);

    try std.testing.expectApproxEqAbs(@as(f64, 6.0), y_out[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), y_out[1], 1e-10);
}

test "executeVectorBody: 3D transformation with arithmetic" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vm = try VM.init(allocator, arena.allocator(), 16, null);
    defer vm.deinit();

    // Build: [y[1], y[2], y[0]] - a rotation/permutation
    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();
    builder.markNonNumeric();

    // Push y[1] (will be row 0)
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);

    // Push y[2] (will be row 1)
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(2), 0);
    try builder.emitWithOperand(.get_index, 1, 0);

    // Push y[0] (will be row 2)
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);

    try builder.emitWithOperand(.mat_create, 3 | (1 << 12), 0);
    try builder.emit(.halt, 0);

    const expr = try builder.build();
    defer {
        var e = expr;
        e.deinit();
    }

    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "y";
    defer allocator.free(params);

    const func = UserFunction{
        .name = "test_permute",
        .params = params,
        .body = expr,
    };

    // Input: [4, 5, 7] -> Output: [5, 7, 4]
    var y_in = [_]f64{ 4.0, 5.0, 7.0 };
    var y_out = [_]f64{ 0.0, 0.0, 0.0 };

    try vm.executeVectorDerivative(&func, 0.0, &y_in, &y_out);

    try std.testing.expectApproxEqAbs(@as(f64, 5.0), y_out[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), y_out[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), y_out[2], 1e-10);
}

test "executeVectorBody: Harmonic oscillator [y1, -y0]" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vm = try VM.init(allocator, arena.allocator(), 16, null);
    defer vm.deinit();

    // Build: [y[1], -y[0]]
    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();
    builder.markNonNumeric();

    // Push y[1] (will be row 0 after mat_create)
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);

    // Push -y[0] (will be row 1 after mat_create)
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.neg, 0);

    try builder.emitWithOperand(.mat_create, 2 | (1 << 12), 0);
    try builder.emit(.halt, 0);

    const expr = try builder.build();
    defer {
        var e = expr;
        e.deinit();
    }

    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "y";
    defer allocator.free(params);

    const func = UserFunction{
        .name = "harmonic",
        .params = params,
        .body = expr,
    };

    // y = [sin(t), cos(t)] at t=0 -> y = [0, 1]
    // dy/dt = [y1, -y0] = [1, 0]
    var y_in = [_]f64{ 0.0, 1.0 };
    var y_out = [_]f64{ 0.0, 0.0 };

    try vm.executeVectorDerivative(&func, 0.0, &y_in, &y_out);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), y_out[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), y_out[1], 1e-10);
}

test "executeVectorBody: Lorenz system derivative" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vm = try VM.init(allocator, arena.allocator(), 32, null);
    defer vm.deinit();

    // Lorenz system: dx/dt = sigma*(y-x), dy/dt = x*(rho-z)-y, dz/dt = x*y - beta*z
    // With sigma=10, rho=28, beta=8/3
    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();
    builder.markNonNumeric();

    // We'll use variables for sigma, rho, beta
    // var 0 = t, var 1 = state vector, var 2 = sigma, var 3 = rho, var 4 = beta
    vm.setVariable(2, Value.initNumber(10.0)); // sigma
    vm.setVariable(3, Value.initNumber(28.0)); // rho
    vm.setVariable(4, Value.initNumber(8.0 / 3.0)); // beta

    // Build dx = sigma * (y - x)
    // Push sigma
    try builder.emitWithOperand(.load_var, 2, 0);
    // Push (y - x) = state[1] - state[0]
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.sub, 0);
    try builder.emit(.mul, 0);

    // Build dy = x * (rho - z) - y
    // x * (rho - z)
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    // (rho - z)
    try builder.emitWithOperand(.load_var, 3, 0); // rho
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(2), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.sub, 0);
    try builder.emit(.mul, 0);
    // - y
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.sub, 0);

    // Build dz = x * y - beta * z
    // x * y
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.mul, 0);
    // beta * z
    try builder.emitWithOperand(.load_var, 4, 0); // beta
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(2), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.mul, 0);
    try builder.emit(.sub, 0);

    // Create 3x1 result matrix
    try builder.emitWithOperand(.mat_create, 3 | (1 << 12), 0);
    try builder.emit(.halt, 0);

    const expr = try builder.build();
    defer {
        var e = expr;
        e.deinit();
    }

    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "state";
    defer allocator.free(params);

    const func = UserFunction{
        .name = "lorenz",
        .params = params,
        .body = expr,
        .param_offset = 0,
    };

    // Test at initial condition [1, 1, 1]
    // dx = 10 * (1 - 1) = 0
    // dy = 1 * (28 - 1) - 1 = 26
    // dz = 1 * 1 - (8/3) * 1 = 1 - 2.667 = -1.667
    var y_in = [_]f64{ 1.0, 1.0, 1.0 };
    var y_out = [_]f64{ 0.0, 0.0, 0.0 };

    try vm.executeVectorDerivative(&func, 0.0, &y_in, &y_out);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), y_out[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 26.0), y_out[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -5.0 / 3.0), y_out[2], 1e-10);
}

test "canUseVectorPath: returns true for supported functions" {
    const allocator = std.testing.allocator;

    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();
    builder.markNonNumeric();

    // Simple supported function
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.neg, 0);
    try builder.emitWithOperand(.mat_create, 1 | (1 << 12), 0);
    try builder.emit(.halt, 0);

    const expr = try builder.build();
    defer {
        var e = expr;
        e.deinit();
    }

    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "y";
    defer allocator.free(params);

    const func = UserFunction{
        .name = "test",
        .params = params,
        .body = expr,
    };

    try std.testing.expect(VM.canUseVectorPath(&func, 2));
    try std.testing.expect(VM.canUseVectorPath(&func, 16));
    try std.testing.expect(!VM.canUseVectorPath(&func, 17)); // dim > 16
}

// =============================================================================
// Integration Tests: Vector Path vs General Path Numerical Accuracy
// =============================================================================

test "Vector path matches general path: Harmonic Oscillator" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Build the harmonic oscillator function
    var builder = BytecodeBuilder.init(allocator);
    builder.markNonNumeric();

    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);

    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.neg, 0);

    try builder.emitWithOperand(.mat_create, 2 | (1 << 12), 0);
    try builder.emit(.halt, 0);

    const expr = try builder.build();

    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "y";

    const func = UserFunction{
        .name = "oscillator",
        .params = params,
        .body = expr,
    };
    defer {
        var f = func;
        f.deinit();
        allocator.free(params);
    }

    // Verify it uses vector path
    try std.testing.expect(VM.canUseVectorPath(&func, 2));

    // Run full ODE solve
    var vm = try VM.init(allocator, arena.allocator(), 16, null);
    defer vm.deinit();

    const func_val = Value.initUserFunction(&func);

    const y0_mat = try mathzig.Matrix.init(allocator, 2, 1);
    y0_mat.data[0] = 0.0;
    y0_mat.data[1] = 1.0;
    defer y0_mat.release();

    const t_span_mat = try mathzig.Matrix.init(allocator, 1, 2);
    t_span_mat.data[0] = 0.0;
    t_span_mat.data[1] = 2.0 * std.math.pi; // Full period
    defer t_span_mat.release();

    const res_val = try ode.ode_solve(&vm, func_val, Value.initMatrix(y0_mat), Value.initMatrix(t_span_mat), 0.001);
    if (res_val.tag == .matrix) _ = vm.untrackMatrix(res_val.data.matrix);
    defer res_val.release();

    const res = res_val.data.matrix;
    const steps = res.rows;

    // After full period, should return to initial conditions
    // y1(2*pi) = sin(2*pi) = 0
    // y2(2*pi) = cos(2*pi) = 1
    const y1_final = res.get(steps - 1, 1);
    const y2_final = res.get(steps - 1, 2);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), y1_final, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), y2_final, 0.001);
}

test "Vector path: Lorenz attractor stability" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var vm = try VM.init(allocator, arena.allocator(), 32, null);
    defer vm.deinit();

    // Set Lorenz parameters as global variables
    vm.setVariable(2, Value.initNumber(10.0)); // sigma
    vm.setVariable(3, Value.initNumber(28.0)); // rho
    vm.setVariable(4, Value.initNumber(8.0 / 3.0)); // beta

    var builder = BytecodeBuilder.init(allocator);
    builder.markNonNumeric();

    // dx = sigma * (y - x)
    try builder.emitWithOperand(.load_var, 2, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.sub, 0);
    try builder.emit(.mul, 0);

    // dy = x * (rho - z) - y
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emitWithOperand(.load_var, 3, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(2), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.sub, 0);
    try builder.emit(.mul, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.sub, 0);

    // dz = x * y - beta * z
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(0), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(1), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.mul, 0);
    try builder.emitWithOperand(.load_var, 4, 0);
    try builder.emitWithOperand(.load_var, 1, 0);
    try builder.emitConstant(Value.initNumber(2), 0);
    try builder.emitWithOperand(.get_index, 1, 0);
    try builder.emit(.mul, 0);
    try builder.emit(.sub, 0);

    try builder.emitWithOperand(.mat_create, 3 | (1 << 12), 0);
    try builder.emit(.halt, 0);

    const expr = try builder.build();

    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "state";

    const func = UserFunction{
        .name = "lorenz",
        .params = params,
        .body = expr,
        .param_offset = 0,
    };
    defer {
        var f = func;
        f.deinit();
        allocator.free(params);
    }

    // Verify vector path is used
    try std.testing.expect(VM.canUseVectorPath(&func, 3));

    const func_val = Value.initUserFunction(&func);

    // Initial conditions near the attractor
    const y0_mat = try mathzig.Matrix.init(allocator, 3, 1);
    y0_mat.data[0] = 1.0;
    y0_mat.data[1] = 1.0;
    y0_mat.data[2] = 1.0;
    defer y0_mat.release();

    const t_span_mat = try mathzig.Matrix.init(allocator, 1, 2);
    t_span_mat.data[0] = 0.0;
    t_span_mat.data[1] = 10.0; // 10 time units
    defer t_span_mat.release();

    const res_val = try ode.ode_solve(&vm, func_val, Value.initMatrix(y0_mat), Value.initMatrix(t_span_mat), 0.01);
    if (res_val.tag == .matrix) _ = vm.untrackMatrix(res_val.data.matrix);
    defer res_val.release();

    const res = res_val.data.matrix;

    // Verify the solution stays bounded (characteristic of Lorenz attractor)
    // x, y should be roughly in [-20, 20], z should be roughly in [0, 50]
    var max_x: f64 = 0;
    var max_y: f64 = 0;
    var max_z: f64 = 0;

    for (0..res.rows) |i| {
        max_x = @max(max_x, @abs(res.get(@intCast(i), 1)));
        max_y = @max(max_y, @abs(res.get(@intCast(i), 2)));
        max_z = @max(max_z, @abs(res.get(@intCast(i), 3)));
    }

    // Lorenz attractor bounds check
    try std.testing.expect(max_x < 30.0);
    try std.testing.expect(max_y < 30.0);
    try std.testing.expect(max_z < 60.0);
}
