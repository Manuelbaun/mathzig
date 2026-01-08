const std = @import("std");
const value_module = @import("../core/value.zig");
const Value = value_module.Value;
const Matrix = value_module.Matrix;
const VM = @import("../vm/vm.zig").VM;
const bytecode = @import("../vm/bytecode.zig");

/// Solve an Ordinary Differential Equation (ODE) using Runge-Kutta 4th Order method.
/// 
/// Arguments:
/// - vm: Pointer to the VM
/// - func_val: The derivative function f(t, y). Must return dy/dt.
/// - y0: Initial state. Can be a Number (scalar) or Matrix (vector).
/// - t_span: Time span [t_start, t_end] as a 2-element Matrix/Vector.
/// - dt: Time step size.
///
/// Returns:
/// - A Matrix where the first column is time, and subsequent columns are state variables.
///   Each row corresponds to a time step.
pub fn ode_solve(vm: *VM, func_val: Value, y0: Value, t_span: Value, dt: f64) !Value {
    // y0 must be a Matrix (vector) or a Number (for 1D ODE)
    var y0_data: []const f64 = undefined;
    var rows: u32 = 0;
    var is_scalar = false;

    var temp_y0_alloc: ?[]f64 = null;
    defer if (temp_y0_alloc) |slice| vm.allocator.free(slice);

    if (y0.tag == .number) {
        is_scalar = true;
        temp_y0_alloc = try vm.allocator.alloc(f64, 1);
        temp_y0_alloc.?[0] = y0.data.number;
        y0_data = temp_y0_alloc.?;
        rows = 1;
    } else if (y0.tag == .unit) {
        is_scalar = true;
        temp_y0_alloc = try vm.allocator.alloc(f64, 1);
        temp_y0_alloc.?[0] = y0.data.unit.value;
        y0_data = temp_y0_alloc.?;
        rows = 1;
    } else if (y0.tag == .matrix) {
        const m = y0.data.matrix;
        // Flatten check: must be vector-like
        // We handle n x 1 or 1 x n
        if (m.rows > 1 and m.cols > 1) return error.InvalidArgument; 
        y0_data = m.data;
        rows = @intCast(m.data.len);
    } else {
        return error.TypeError;
    }

    // t_span must be [start, end]
    var t_start: f64 = 0;
    var t_end: f64 = 0;
    
    if (t_span.tag == .matrix) {
        const m = t_span.data.matrix;
        if (m.data.len < 2) return error.InvalidArgument;
        t_start = m.data[0];
        t_end = m.data[m.data.len - 1];
    } else if (t_span.tag == .number) {
        t_start = 0;
        t_end = t_span.data.number;
    } else if (t_span.tag == .unit) {
        t_start = 0;
        t_end = t_span.data.unit.value;
    } else {
        return error.TypeError;
    }

    if (dt <= 0) return error.InvalidStep;
    
    // Determine number of steps
    // Ensure we cover the full range
    const range = t_end - t_start;
    const steps_f = @ceil(range / dt);
    const steps = @as(usize, @intFromFloat(steps_f)) + 1;
    
    // Safety limit
    if (steps > 10_000_000) return error.ResultTooLarge;

    // Result Matrix: steps x (1 + rows)  [t, y1, y2, ...]
    const result_cols = 1 + rows;
    const result = try Matrix.init(vm.allocator, @intCast(steps), result_cols);
    vm.trackMatrix(result);
    
    // Function handling
    // We currently only support user functions (bytecode)
    var func: *const bytecode.UserFunction = undefined;

    if (func_val.tag == .function) {
        if (func_val.data.function.tag == .user) {
            func = func_val.data.function.user_func.?;
        } else {
            return error.UnimplementedOpcode;
        }
    } else if (func_val.tag == .string) {
        // Resolve by name
        const name = func_val.data.string.toSlice();
        var found: ?*const bytecode.UserFunction = null;
        for (vm.user_functions.items) |uf| {
            if (std.mem.eql(u8, uf.name, name)) {
                found = uf;
                break;
            }
        }
        if (found) |f| {
            func = f;
        } else {
            return error.UnknownFunction;
        }
    } else {
        return error.UnimplementedOpcode;
    }

    try ode_solve_optimized(vm, func, y0_data, t_start, steps, dt, is_scalar, result);
    
    return Value.initMatrix(result);
}

fn initSolverVM(parent_vm: *VM, func: *const bytecode.UserFunction) !VM {
    // Reserve space for args and existing globals
    // Account for param_offset since nested functions may have parameters at higher indices
    const max_vars = @max(parent_vm.variables.len, func.param_offset + func.params.len + 64);
    var sub_vm = try VM.init(parent_vm.allocator, parent_vm.metadata_allocator, max_vars, parent_vm.thread_pool, parent_vm.config);
    
    // Inherit user functions
    try sub_vm.user_functions.appendSlice(parent_vm.allocator, parent_vm.user_functions.items);
    
    // Inherit globals
    for (parent_vm.variables, 0..) |val, v_idx| {
        sub_vm.setVariable(@intCast(v_idx), val);
    }
    
    return sub_vm;
}

/// Optimize ODE solving by reusing a VM instance and input buffers
pub fn ode_solve_optimized(vm: *VM, func: *const bytecode.UserFunction, y0_data: []const f64, t_start: f64, steps: usize, dt: f64, is_scalar: bool, result: *Matrix) !void {
    const rows = y0_data.len;

    // Check if we can use the fast vector path
    // Requirements: not scalar, dimension <= 16, function uses only supported opcodes
    const use_vector_path = !is_scalar and VM.canUseVectorPath(func, rows);

    // Buffers for RK4
    const k1 = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(k1);
    const k2 = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(k2);
    const k3 = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(k3);
    const k4 = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(k4);
    const temp_y = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(temp_y);
    const current_y = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(current_y);
    @memcpy(current_y, y0_data);

    if (use_vector_path) {
        // FAST PATH: Use specialized vector execution
        // No sub_vm needed, no matrix allocation in the hot loop
        var sub_vm = try initSolverVM(vm, func);
        defer sub_vm.deinit();

        var t = t_start;
        var step_idx: usize = 0;

        while (step_idx < steps) : (step_idx += 1) {
            result.set(@intCast(step_idx), 0, t);
            for (0..rows) |i| {
                result.set(@intCast(step_idx), @intCast(i + 1), current_y[i]);
            }

            if (step_idx == steps - 1) break;

            // RK4 with vector path - zero allocations per step
            try rk4_step_vector(&sub_vm, func, t, current_y, dt, temp_y, k1, k2, k3, k4);

            t += dt;
        }
    } else {
        // SLOW PATH: Use general execution (existing implementation)
        var sub_vm = try initSolverVM(vm, func);
        defer sub_vm.deinit();

        // Pre-allocate input matrix for vector-valued ODEs
        // Param 0 is t (scalar), Param 1 is y (scalar or matrix)
        // IMPORTANT: These params are at func.param_offset and func.param_offset + 1
        var reusable_y_mat: ?*Matrix = null;
        if (!is_scalar) {
            reusable_y_mat = try Matrix.init(vm.allocator, @intCast(rows), 1);
            const val_y = Value.initMatrix(reusable_y_mat.?);
            sub_vm.setVariable(func.param_offset + 1, val_y);
            val_y.release(); // Ownership transferred to sub_vm
        }

        var t = t_start;
        var step_idx: usize = 0;

        while (step_idx < steps) : (step_idx += 1) {
            result.set(@intCast(step_idx), 0, t);
            for (0..rows) |i| {
                result.set(@intCast(step_idx), @intCast(i + 1), current_y[i]);
            }

            if (step_idx == steps - 1) break;

            try rk4_step_optimized(&sub_vm, func, t, current_y, dt, is_scalar, reusable_y_mat, temp_y, k1, k2, k3, k4);

            t += dt;
        }
    }
}

/// RK4 step using specialized vector execution path.
/// Zero allocations per step - all buffers are pre-allocated.
fn rk4_step_vector(
    sub_vm: *VM,
    func: *const bytecode.UserFunction,
    t: f64,
    y: []f64,
    dt: f64,
    temp_y: []f64,
    k1: []f64,
    k2: []f64,
    k3: []f64,
    k4: []f64,
) !void {
    const dim = y.len;

    // k1 = f(t, y)
    try sub_vm.executeVectorDerivative(func, t, y, k1);

    // k2 = f(t + 0.5*dt, y + 0.5*dt*k1)
    for (0..dim) |i| temp_y[i] = y[i] + 0.5 * dt * k1[i];
    try sub_vm.executeVectorDerivative(func, t + 0.5 * dt, temp_y, k2);

    // k3 = f(t + 0.5*dt, y + 0.5*dt*k2)
    for (0..dim) |i| temp_y[i] = y[i] + 0.5 * dt * k2[i];
    try sub_vm.executeVectorDerivative(func, t + 0.5 * dt, temp_y, k3);

    // k4 = f(t + dt, y + dt*k3)
    for (0..dim) |i| temp_y[i] = y[i] + dt * k3[i];
    try sub_vm.executeVectorDerivative(func, t + dt, temp_y, k4);

    // y_next = y + (dt/6)*(k1 + 2*k2 + 2*k3 + k4)
    for (0..dim) |i| {
        y[i] += (dt / 6.0) * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]);
    }
}

/// Solve an Ordinary Differential Equation (ODE) using Euler method (1st Order).
/// Matches the simple 'ndsolve' implementation in the math.js example.
pub fn ode_solve_euler(vm: *VM, func_val: Value, y0: Value, t_span: Value, dt: f64) !Value {
    var y0_data: []const f64 = undefined;
    var rows: u32 = 0;
    var is_scalar = false;

    var temp_y0_alloc: ?[]f64 = null;
    defer if (temp_y0_alloc) |slice| vm.allocator.free(slice);

    if (y0.tag == .number) {
        is_scalar = true;
        temp_y0_alloc = try vm.allocator.alloc(f64, 1);
        temp_y0_alloc.?[0] = y0.data.number;
        y0_data = temp_y0_alloc.?;
        rows = 1;
    } else if (y0.tag == .unit) {
        is_scalar = true;
        temp_y0_alloc = try vm.allocator.alloc(f64, 1);
        temp_y0_alloc.?[0] = y0.data.unit.value;
        y0_data = temp_y0_alloc.?;
        rows = 1;
    } else if (y0.tag == .matrix) {
        const m = y0.data.matrix;
        if (m.rows > 1 and m.cols > 1) return error.InvalidArgument; 
        y0_data = m.data;
        rows = @intCast(m.data.len);
    } else {
        return error.TypeError;
    }

    var t_start: f64 = 0;
    var t_end: f64 = 0;
    
    if (t_span.tag == .matrix) {
        const m = t_span.data.matrix;
        if (m.data.len < 2) return error.InvalidArgument;
        t_start = m.data[0];
        t_end = m.data[m.data.len - 1];
    } else if (t_span.tag == .number) {
        t_start = 0;
        t_end = t_span.data.number;
    } else if (t_span.tag == .unit) {
        t_start = 0;
        t_end = t_span.data.unit.value;
    } else {
        return error.TypeError;
    }

    if (dt <= 0) return error.InvalidStep;
    
    const range = t_end - t_start;
    const steps_f = @ceil(range / dt);
    const steps = @as(usize, @intFromFloat(steps_f)) + 1;
    
    if (steps > 10_000_000) return error.ResultTooLarge;

    const result_cols = 1 + rows;
    const result = try Matrix.init(vm.allocator, @intCast(steps), result_cols);
    vm.trackMatrix(result);
    
    // Resolve function
    var func: *const bytecode.UserFunction = undefined;
    if (func_val.tag == .function) {
        if (func_val.data.function.tag == .user) {
            func = func_val.data.function.user_func.?;
        } else {
            return error.UnimplementedOpcode;
        }
    } else if (func_val.tag == .string) {
        const name = func_val.data.string.toSlice();
        var found: ?*const bytecode.UserFunction = null;
        for (vm.user_functions.items) |uf| {
            if (std.mem.eql(u8, uf.name, name)) {
                found = uf;
                break;
            }
        }
        if (found) |f| {
            func = f;
        } else {
            return error.UnknownFunction;
        }
    } else {
        return error.UnimplementedOpcode;
    }

    // Check if we can use the fast vector path
    const use_vector_path = !is_scalar and VM.canUseVectorPath(func, rows);

    const dxdt = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(dxdt);
    const current_y = try vm.allocator.alloc(f64, rows);
    defer vm.allocator.free(current_y);
    @memcpy(current_y, y0_data);

    // Initialize Solver VM
    var sub_vm = try initSolverVM(vm, func);
    defer sub_vm.deinit();

    if (use_vector_path) {
        // FAST PATH: Use specialized vector execution
        var t = t_start;
        var step_idx: usize = 0;

        while (step_idx < steps) : (step_idx += 1) {
            result.set(@intCast(step_idx), 0, t);
            for (0..rows) |i| {
                result.set(@intCast(step_idx), @intCast(i + 1), current_y[i]);
            }

            if (step_idx == steps - 1) break;

            // Euler Step with vector path - zero allocations
            try sub_vm.executeVectorDerivative(func, t, current_y, dxdt);

            for (0..rows) |i| {
                current_y[i] += dxdt[i] * dt;
            }

            t += dt;
        }
    } else {
        // SLOW PATH: Use general execution
        var reusable_y_mat: ?*Matrix = null;
        if (!is_scalar) {
            reusable_y_mat = try Matrix.init(vm.allocator, @intCast(rows), 1);
            const val_y = Value.initMatrix(reusable_y_mat.?);
            sub_vm.setVariable(func.param_offset + 1, val_y);
            val_y.release();
        }

        var t = t_start;
        var step_idx: usize = 0;

        while (step_idx < steps) : (step_idx += 1) {
            result.set(@intCast(step_idx), 0, t);
            for (0..rows) |i| {
                result.set(@intCast(step_idx), @intCast(i + 1), current_y[i]);
            }

            if (step_idx == steps - 1) break;

            // Euler Step: dx = f(t, x)
            try eval_deriv_fast(&sub_vm, func, t, current_y, is_scalar, dxdt, reusable_y_mat);

            for (0..rows) |i| {
                current_y[i] += dxdt[i] * dt;
            }

            t += dt;
        }
    }

    return Value.initMatrix(result);
}

fn rk4_step_optimized(
    sub_vm: *VM, 
    func: *const bytecode.UserFunction, 
    t: f64, 
    y: []f64, 
    dt: f64, 
    is_scalar: bool,
    reusable_y_mat: ?*Matrix,
    temp_y: []f64, 
    k1: []f64, k2: []f64, k3: []f64, k4: []f64
) !void {
    const dim = y.len;
    
    // k1 = f(t, y)
    try eval_deriv_fast(sub_vm, func, t, y, is_scalar, k1, reusable_y_mat);
    
    // k2 = f(t + 0.5*dt, y + 0.5*dt*k1)
    for (0..dim) |i| temp_y[i] = y[i] + 0.5 * dt * k1[i];
    try eval_deriv_fast(sub_vm, func, t + 0.5 * dt, temp_y, is_scalar, k2, reusable_y_mat);

    // k3 = f(t + 0.5*dt, y + 0.5*dt*k2)
    for (0..dim) |i| temp_y[i] = y[i] + 0.5 * dt * k2[i];
    try eval_deriv_fast(sub_vm, func, t + 0.5 * dt, temp_y, is_scalar, k3, reusable_y_mat);

    // k4 = f(t + dt, y + dt*k3)
    for (0..dim) |i| temp_y[i] = y[i] + dt * k3[i];
    try eval_deriv_fast(sub_vm, func, t + dt, temp_y, is_scalar, k4, reusable_y_mat);

    // y_next = y + (dt/6)*(k1 + 2*k2 + 2*k3 + k4)
    for (0..dim) |i| {
        y[i] += (dt / 6.0) * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]);
    }
}

fn eval_deriv_fast(
    sub_vm: *VM, 
    func: *const bytecode.UserFunction, 
    t: f64, 
    y: []const f64, 
    is_scalar: bool, 
    out: []f64,
    reusable_y_mat: ?*Matrix
) !void {
    // Update arguments in sub_vm
    // Param 0: t
    sub_vm.setVariableF64(func.param_offset, t);
    
    // Param 1: y
    if (is_scalar) {
        sub_vm.setVariableF64(func.param_offset + 1, y[0]);
    } else {
        // reuse matrix data
        if (reusable_y_mat) |m| {
            @memcpy(m.data, y);
        } else {
            return error.RuntimeError; // Should not happen
        }
    }
    
    // Execute
    const result = try sub_vm.execute(&func.body);
    defer result.release();
    
    // Process result
    if (result.tag == .number) {
        if (out.len != 1) return error.MismatchedDimensions;
        out[0] = result.data.number;
    } else if (result.tag == .unit) {
        if (out.len != 1) return error.MismatchedDimensions;
        out[0] = result.data.unit.value;
    } else if (result.tag == .matrix) {
        const m = result.data.matrix;
        if (m.data.len != out.len) return error.MismatchedDimensions;
        @memcpy(out, m.data);
    } else {
        return error.TypeError;
    }
}

