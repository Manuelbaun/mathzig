const std = @import("std");
const mathzig = @import("mathzig");
const VM = mathzig.VM;
const BytecodeBuilder = mathzig.BytecodeBuilder;
const UserFunction = mathzig.UserFunction;
const Value = mathzig.Value;
const ode = mathzig.ode;

test "ODE Solver: Exponential Decay (dy/dt = -y)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const meta_alloc = arena.allocator();

    var vm = try VM.init(allocator, meta_alloc, 16, null);
    defer vm.deinit();

    // 1. Create User Function: f(t, y) = -y
    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();

    // Push y (var 1)
    try builder.emitWithOperand(.load_var, 1, 0);
    // Negate
    try builder.emit(.neg, 0);
    // Halt (return top)
    try builder.emit(.halt, 0);
    builder.markNonNumeric(); 

    const expr = try builder.build();
    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "y";
    defer allocator.free(params);

    const user_func = UserFunction{
        .name = "decay",
        .params = params,
        .body = expr,
    };
    defer {
        var mut_func = user_func;
        mut_func.deinit();
    }

    const func_val = Value.initUserFunction(&user_func);

    // 2. Setup arguments
    const y0 = Value.initNumber(1.0);
    
    // t_span = [0, 1]
    const t_span_mat = try mathzig.Matrix.init(allocator, 1, 2);
    t_span_mat.data[0] = 0.0;
    t_span_mat.data[1] = 1.0;
    defer t_span_mat.release();
    const t_span = Value.initMatrix(t_span_mat);
    
    const dt = 0.1;

    // 3. Run Solver
    const res_val = try ode.ode_solve(&vm, func_val, y0, t_span, dt);
    if (res_val.tag == .matrix) _ = vm.untrackMatrix(res_val.data.matrix);
    defer res_val.release();

    try std.testing.expect(res_val.tag == .matrix);
    const res = res_val.data.matrix;
    
    // Check dimensions: steps x (1 + 1)
    // steps = (1 - 0)/0.1 + 1 = 11
    try std.testing.expectEqual(@as(u32, 11), res.rows);
    try std.testing.expectEqual(@as(u32, 2), res.cols);

    // Verify last point: y(1) approx exp(-1) = 0.367879
    const t_last = res.get(10, 0);
    const y_last = res.get(10, 1);
    
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), t_last, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.367879), y_last, 0.0001);
}

test "ODE Solver: Harmonic Oscillator (dy/dt = [y2, -y1])" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const meta_alloc = arena.allocator();

    var vm = try VM.init(allocator, meta_alloc, 16, null);
    defer vm.deinit();

    // 1. Create User Function: f(t, y) = [y[1], -y[0]]
    var builder = BytecodeBuilder.init(allocator);
    defer builder.deinit();
    builder.markNonNumeric(); 
    
    // We want dy/dt = [y[1], -y[0]]
    // mat_create pops in reverse order: Last popped -> Row 0. First popped -> Row N.
    // Wait, mat_create logic:
    // while r > 0 { r--; ... set(r, c, pop()) }
    // r goes 2 -> 1 (pop -> Row 1), then 1 -> 0 (pop -> Row 0).
    // So First Pop -> Row 1. Second Pop -> Row 0.
    
    // We want Row 0 = y[1]. So Second Pop must be y[1].
    // We want Row 1 = -y[0]. So First Pop must be -y[0].
    
    // So Stack Top must be -y[0]. Stack Below must be y[1].
    // So Push y[1] FIRST. Then Push -y[0].
    
    // Push y[1]
    try builder.emitWithOperand(.load_var, 1, 0); // y
    try builder.emitConstant(Value.initNumber(1), 0); // index 1
    try builder.emitWithOperand(.get_index, 1, 0); // get y[1]

    // Push -y[0]
    try builder.emitWithOperand(.load_var, 1, 0); // y
    try builder.emitConstant(Value.initNumber(0), 0); // index 0
    try builder.emitWithOperand(.get_index, 1, 0); // get y[0]
    try builder.emit(.neg, 0); // -y[0]
    
    try builder.emitWithOperand(.mat_create, 2 | (1 << 12), 0); // 2 rows, 1 col
    try builder.emit(.halt, 0);

    const expr = try builder.build();
    const params = try allocator.alloc([]const u8, 2);
    params[0] = "t";
    params[1] = "y";
    defer allocator.free(params);

    const user_func = UserFunction{
        .name = "oscillator",
        .params = params,
        .body = expr,
    };
    defer {
        var mut_func = user_func;
        mut_func.deinit();
    }
    const func_val = Value.initUserFunction(&user_func);

    // 2. Setup arguments
    // y0 = [0, 1] (y1=0, y2=1) -> start at sin(0)=0, cos(0)=1
    const y0_mat = try mathzig.Matrix.init(allocator, 2, 1);
    y0_mat.data[0] = 0.0;
    y0_mat.data[1] = 1.0;
    defer y0_mat.release();
    const y0 = Value.initMatrix(y0_mat);
    
    // t_span = [0, pi]
    const t_span_mat = try mathzig.Matrix.init(allocator, 1, 2);
    t_span_mat.data[0] = 0.0;
    t_span_mat.data[1] = std.math.pi;
    defer t_span_mat.release();
    const t_span = Value.initMatrix(t_span_mat);
    
    const dt = 0.01;

    // 3. Run Solver
    const res_val = try ode.ode_solve(&vm, func_val, y0, t_span, dt);
    if (res_val.tag == .matrix) _ = vm.untrackMatrix(res_val.data.matrix);
    defer res_val.release();

    try std.testing.expect(res_val.tag == .matrix);
    const res = res_val.data.matrix;
    
    // Verify at t=pi
    // y1 = sin(pi) = 0
    // y2 = cos(pi) = -1
    const steps = res.rows;
    const y1_final = res.get(steps - 1, 1);
    const y2_final = res.get(steps - 1, 2);
    
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), y1_final, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), y2_final, 0.01);
}