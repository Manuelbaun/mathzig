const std = @import("std");
const mathzig = @import("mathzig");
const Compiler = mathzig.Compiler;
const UnitRegistry = mathzig.units.UnitRegistry;
const VM = mathzig.VM;
const Value = mathzig.Value;
const Matrix = mathzig.Matrix;
const Opcode = mathzig.Opcode;

test "fuse load_var_index_0" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    // Setup variable u as a matrix
    // Setup variable u as a matrix
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 16, null, &config);
    defer vm.deinit();

    {
        const mat = try Matrix.init(allocator, 3, 1);
        mat.data[0] = 10.5;
        mat.data[1] = 20.5;
        mat.data[2] = 30.5;
        vm.setVariable(0, Value.initMatrix(mat));
        mat.release(); // VM now owns it
    }

    var compiler = try Compiler.init(allocator, "u[0]");
    compiler.registry = &registry;
    // Force variable 'u' to index 0
    _ = compiler.getOrCreateVariable("u");
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // Pattern: load_var 0, push_const 0, get_index 1
    // Should fuse to: load_var_index_0 0
    // Bytecode: load_var_index_0, halt
    try std.testing.expectEqual(@as(usize, 2), expr.code.len);
    try std.testing.expectEqual(Opcode.load_var_index_0, expr.code[0].opcode);

    const result = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, 10.5), result.data.number);
}

test "fuse load_var_index_const" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    // Setup variable u as a matrix
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 16, null, &config);
    defer vm.deinit();

    {
        const mat = try Matrix.init(allocator, 10, 1);
        mat.data[5] = 123.45;
        vm.setVariable(0, Value.initMatrix(mat));
        mat.release(); // VM now owns it
    }

    var compiler = try Compiler.init(allocator, "u[5]");
    compiler.registry = &registry;
    _ = compiler.getOrCreateVariable("u");
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // Should fuse to: load_var_index_const (var_0, const_5)
    try std.testing.expectEqual(Opcode.load_var_index_const, expr.code[0].opcode);

    const result = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, 123.45), result.data.number);
}

test "fused load_var_index preserves matrix row slice semantics" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 16, null, &config);
    defer vm.deinit();
    defer vm.freeIntermediates();

    {
        const mat = try Matrix.init(allocator, 3, 2);
        // row 0
        mat.set(0, 0, 1.0);
        mat.set(0, 1, 2.0);
        // row 1
        mat.set(1, 0, 3.0);
        mat.set(1, 1, 4.0);
        // row 2
        mat.set(2, 0, 5.0);
        mat.set(2, 1, 6.0);
        vm.setVariable(0, Value.initMatrix(mat));
        mat.release();
    }

    var compiler = try Compiler.init(allocator, "u[1]");
    compiler.registry = &registry;
    _ = compiler.getOrCreateVariable("u");
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // Confirm peephole produced a specialized load-var-index opcode.
    try std.testing.expect(expr.code[0].opcode == Opcode.load_var_index_1 or expr.code[0].opcode == Opcode.load_var_index_const);

    const result = try vm.execute(&expr);
    defer result.release();
    try std.testing.expectEqual(mathzig.ValueTag.matrix, result.tag);
    try std.testing.expectEqual(@as(u32, 1), result.data.matrix.rows);
    try std.testing.expectEqual(@as(u32, 2), result.data.matrix.cols);
    try std.testing.expectEqual(@as(f64, 3.0), result.data.matrix.get(0, 0));
    try std.testing.expectEqual(@as(f64, 4.0), result.data.matrix.get(0, 1));
}

test "fuse load_mul" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    // Setup variable u as a matrix
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 16, null, &config);
    defer vm.deinit();
    vm.setVariableF64(0, 2.0); // a
    vm.setVariableF64(1, 3.5); // b

    var compiler = try Compiler.init(allocator, "a * b");
    compiler.registry = &registry;
    _ = compiler.getOrCreateVariable("a");
    _ = compiler.getOrCreateVariable("b");
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // Should fuse to: load_mul (var_0, var_1)
    try std.testing.expectEqual(Opcode.load_mul, expr.code[0].opcode);

    const result = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, 7.0), result.data.number);
}

test "fuse load_sub" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    // Setup variable u as a matrix
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 16, null, &config);
    defer vm.deinit();
    vm.setVariableF64(0, 10.0); // a
    vm.setVariableF64(1, 3.0); // b

    var compiler = try Compiler.init(allocator, "a - b");
    compiler.registry = &registry;
    _ = compiler.getOrCreateVariable("a");
    _ = compiler.getOrCreateVariable("b");
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // Should fuse to: load_sub (var_0, var_1)
    try std.testing.expectEqual(Opcode.load_sub, expr.code[0].opcode);

    const result = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, 7.0), result.data.number);
}

test "fuse const_mul" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    // Setup variable u as a matrix
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 16, null, &config);
    defer vm.deinit();
    vm.setVariableF64(0, 5.0); // x

    var compiler = try Compiler.init(allocator, "x * 2");
    compiler.registry = &registry;
    _ = compiler.getOrCreateVariable("x");
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // x * 2 -> load_var 0, push_const 2, mul
    // Should fuse to: load_var 0, const_mul 2
    try std.testing.expectEqual(Opcode.load_var, expr.code[0].opcode);
    try std.testing.expectEqual(Opcode.const_mul, expr.code[1].opcode);

    const result = try vm.execute(&expr);
    try std.testing.expectEqual(@as(f64, 10.0), result.data.number);
}

test "fuse mat_create_3" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    // Setup variable u as a matrix
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 16, null, &config);
    defer vm.deinit();
    // freeIntermediates will release the result matrix from execute()
    defer vm.freeIntermediates();

    var compiler = try Compiler.init(allocator, "[1; 2; 3]");
    compiler.registry = &registry;
    defer compiler.deinit();

    var expr = try compiler.compile();
    defer expr.deinit();

    // Should have mat_create_3
    var found = false;
    for (expr.code) |instr| {
        if (instr.opcode == Opcode.mat_create_3) found = true;
    }
    try std.testing.expect(found);

    const result = try vm.execute(&expr);
    defer result.release(); // Fix leak: release the matrix returned by execute()
    try std.testing.expectEqual(mathzig.ValueTag.matrix, result.tag);
    try std.testing.expectEqual(@as(u32, 3), result.data.matrix.rows);
    try std.testing.expectEqual(@as(u32, 1), result.data.matrix.cols);
    try std.testing.expectEqual(@as(f64, 1.0), result.data.matrix.data[0]);
    try std.testing.expectEqual(@as(f64, 2.0), result.data.matrix.data[1]);
    try std.testing.expectEqual(@as(f64, 3.0), result.data.matrix.data[2]);
}

test "fusion preserves jump targets (ternary + loop regression)" {
    const allocator = std.testing.allocator;
    var ctx = try mathzig.MathZig.init(allocator);
    defer ctx.deinit();

    (try ctx.eval("v = [10; 20; 30]")).release();

    // get_index fusion in the true branch used to shift the false-branch
    // jump target, returning null instead of 30.
    {
        const r = try ctx.eval("0 > 1 ? v[1] : v[2]");
        defer r.release();
        try std.testing.expectEqual(@as(?f64, 30), r.toNumber());
    }
    {
        const r = try ctx.eval("1 > 0 ? v[1] : v[2]");
        defer r.release();
        try std.testing.expectEqual(@as(?f64, 20), r.toNumber());
    }

    // load_mul / load_sub fusions in ternary branches
    (try ctx.eval("a = 2")).release();
    (try ctx.eval("b = 3")).release();
    {
        const r = try ctx.eval("a > 99 ? a * b : a - b");
        defer r.release();
        try std.testing.expectEqual(@as(?f64, -1), r.toNumber());
    }

    // get_index fusion inside a while-loop body (backward jump)
    {
        const r = try ctx.eval("s = 0; k = 0; while (k < 3) { s = s + v[1]; k = k + 1 }; s");
        defer r.release();
        try std.testing.expectEqual(@as(?f64, 60), r.toNumber());
    }
    {
        const r = try ctx.eval("s = 0; k = 0; while (k < 3) { s = s + v[k]; k = k + 1 }; s");
        defer r.release();
        try std.testing.expectEqual(@as(?f64, 60), r.toNumber());
    }
}
