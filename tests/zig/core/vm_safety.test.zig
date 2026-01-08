const std = @import("std");
const mathzig = @import("mathzig");
const VM = mathzig.VM;
const CompiledExpr = mathzig.CompiledExpr;
const Instruction = mathzig.Instruction;
const Opcode = mathzig.Opcode;
const Value = mathzig.Value;
const MathZig = mathzig.MathZig;

test "VM stack detection" {
    const allocator = std.testing.allocator;
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 10, null, &config);
    defer vm.deinit();

    // Use a static array instead of ArrayList to avoid Zig version compatibility issues
    var code = [_]Instruction{
        Instruction.init(.pop),
        Instruction.init(.halt),
    };

    var expr = CompiledExpr{
        .code = &code,
        .source_offsets = try allocator.alloc(u32, 2),
        .constants = &.{},
        .constants_f64 = &.{},
        .max_stack = 1,
        .is_number_only = false,
        .allocator = allocator,
        .owns_memory = false, // code is stack-allocated here
    };
    @memset(@as([]u32, @constCast(expr.source_offsets)), 0);
    defer allocator.free(expr.source_offsets);

    const result = vm.execute(&expr);
    try std.testing.expectError(error.StackUnderflow, result);
}

test "VM variable bounds detection" {
    const allocator = std.testing.allocator;
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 10, null, &config);
    defer vm.deinit();

    var code = [_]Instruction{
        Instruction.initWithOperand(.load_var, 100),
        Instruction.init(.halt),
    };

    var expr = CompiledExpr{
        .code = &code,
        .source_offsets = try allocator.alloc(u32, 2),
        .constants = &.{},
        .constants_f64 = &.{},
        .max_stack = 1,
        .is_number_only = false,
        .allocator = allocator,
        .owns_memory = false,
    };
    @memset(@as([]u32, @constCast(expr.source_offsets)), 0);
    defer allocator.free(expr.source_offsets);

    const result = vm.execute(&expr);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

test "executeNumbersOnly stack overflow safety" {
    const allocator = std.testing.allocator;
    var config = mathzig.Config.init();
    var vm = try VM.init(allocator, allocator, 10, null, &config);
    defer vm.deinit();

    var expr = CompiledExpr{
        .code = &.{},
        .source_offsets = &.{},
        .constants = &.{},
        .constants_f64 = &.{},
        .max_stack = 5000, // Greater than 4096 stack_f64 size
        .is_number_only = true,
        .allocator = allocator,
        .owns_memory = false,
    };

    const result = vm.executeNumbersOnly(&expr);
    try std.testing.expect(result == null);
}

test "matrix slice rejects zero and negative step" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const init = try ctx.eval("A = [1, 2, 3, 4; 5, 6, 7, 8]");
    defer init.release();
    try std.testing.expectError(error.InvalidStep, ctx.eval("A[1:2:0, :]"));
    try std.testing.expectError(error.InvalidArgument, ctx.eval("A[1:2:-1, :]"));
}

test "matrix slice supports positive step > 1" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const init = try ctx.eval("A = [1, 2, 3, 4; 5, 6, 7, 8]");
    defer init.release();
    const res = try ctx.eval("A[1:2:1, 1:4:2]");
    defer res.release();

    try std.testing.expectEqual(mathzig.ValueTag.matrix, res.tag);
    const m = res.data.matrix;
    try std.testing.expectEqual(@as(u32, 2), m.rows);
    try std.testing.expectEqual(@as(u32, 2), m.cols);
    try std.testing.expectEqual(@as(f64, 1), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 3), m.get(0, 1));
    try std.testing.expectEqual(@as(f64, 5), m.get(1, 0));
    try std.testing.expectEqual(@as(f64, 7), m.get(1, 1));
}

test "matrix and series indexing reject fractional indices" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const init_a = try ctx.eval("A = [1, 2; 3, 4]");
    defer init_a.release();
    try std.testing.expectError(error.TypeError, ctx.eval("A[1.5, 1]"));

    const init_s = try ctx.eval("s = series([0,1,2], [10,20,30])");
    defer init_s.release();
    try std.testing.expectError(error.TypeError, ctx.eval("s[1.2]"));
}

test "series slice step clipping and empty range semantics" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const init_s = try ctx.eval("s = series([0,1,2,3,4], [10,20,30,40,50])");
    defer init_s.release();

    const clipped = try ctx.eval("s[0:10:2]");
    defer clipped.release();
    try std.testing.expectEqual(mathzig.ValueTag.series, clipped.tag);
    const c = clipped.data.series;
    try std.testing.expectEqual(@as(u32, 3), c.len);
    try std.testing.expectEqual(@as(f64, 0), c.timestamps[0]);
    try std.testing.expectEqual(@as(f64, 2), c.timestamps[1]);
    try std.testing.expectEqual(@as(f64, 4), c.timestamps[2]);
    try std.testing.expectEqual(@as(f64, 10), c.values[0]);
    try std.testing.expectEqual(@as(f64, 30), c.values[1]);
    try std.testing.expectEqual(@as(f64, 50), c.values[2]);

    const empty = try ctx.eval("s[4:2:2]");
    defer empty.release();
    try std.testing.expectEqual(mathzig.ValueTag.series, empty.tag);
    try std.testing.expectEqual(@as(u32, 0), empty.data.series.len);
}

test "series slice negative start clamps with positive step" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const init_s = try ctx.eval("s = series([0,1,2,3,4], [10,20,30,40,50])");
    defer init_s.release();

    const res = try ctx.eval("s[-10:5:2]");
    defer res.release();
    try std.testing.expectEqual(mathzig.ValueTag.series, res.tag);
    const s = res.data.series;
    try std.testing.expectEqual(@as(u32, 3), s.len);
    try std.testing.expectEqual(@as(f64, 10), s.values[0]);
    try std.testing.expectEqual(@as(f64, 30), s.values[1]);
    try std.testing.expectEqual(@as(f64, 50), s.values[2]);
}

test "matrix slice assignment: single element, row, column, submatrix" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Point indices are 0-based.
    const a_init = try ctx.eval("A = [1, 2, 3; 4, 5, 6]");
    defer a_init.release();
    const a0 = try ctx.eval("A[0, 1] = 99");
    defer a0.release();
    try std.testing.expectEqual(@as(f64, 99), a0.data.number);
    const a_chk = try ctx.eval("A[0, 1]");
    defer a_chk.release();
    try std.testing.expectEqual(@as(f64, 99), a_chk.data.number);

    // Row slice assign (point row index + full-range col slice).
    const b_init = try ctx.eval("B = [1, 2, 3; 4, 5, 6]");
    defer b_init.release();
    const b_set = try ctx.eval("B[0, :] = [7, 8, 9]");
    defer b_set.release();
    const b = try ctx.eval("B");
    defer b.release();
    try std.testing.expectEqual(@as(f64, 7), b.data.matrix.get(0, 0));
    try std.testing.expectEqual(@as(f64, 8), b.data.matrix.get(0, 1));
    try std.testing.expectEqual(@as(f64, 9), b.data.matrix.get(0, 2));
    try std.testing.expectEqual(@as(f64, 4), b.data.matrix.get(1, 0));

    // Column slice assign.
    const c_init = try ctx.eval("C = [1, 2, 3; 4, 5, 6]");
    defer c_init.release();
    const c_set = try ctx.eval("C[:, 1] = [10; 11]");
    defer c_set.release();
    const c = try ctx.eval("C");
    defer c.release();
    try std.testing.expectEqual(@as(f64, 10), c.data.matrix.get(0, 1));
    try std.testing.expectEqual(@as(f64, 11), c.data.matrix.get(1, 1));
    try std.testing.expectEqual(@as(f64, 1), c.data.matrix.get(0, 0));

    // Sub-matrix assign via 1-based inclusive slice endpoints (MathJS-like).
    // E[1:2, 2:3] covers rows 0..1 and cols 1..2 in 0-based storage.
    const e_init = try ctx.eval("E = [1, 2, 3, 4; 5, 6, 7, 8; 9, 10, 11, 12]");
    defer e_init.release();
    const e_set = try ctx.eval("E[1:2, 2:3] = [20, 21; 22, 23]");
    defer e_set.release();
    const e = try ctx.eval("E");
    defer e.release();
    try std.testing.expectEqual(@as(f64, 20), e.data.matrix.get(0, 1));
    try std.testing.expectEqual(@as(f64, 21), e.data.matrix.get(0, 2));
    try std.testing.expectEqual(@as(f64, 22), e.data.matrix.get(1, 1));
    try std.testing.expectEqual(@as(f64, 23), e.data.matrix.get(1, 2));
    try std.testing.expectEqual(@as(f64, 1), e.data.matrix.get(0, 0));
    try std.testing.expectEqual(@as(f64, 12), e.data.matrix.get(2, 3));
}

test "matrix indexing out of range is a hard error" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const init = try ctx.eval("A = [1, 2; 3, 4]");
    defer init.release();
    try std.testing.expectError(error.IndexOutOfBounds, ctx.eval("A[9, 0]"));
    try std.testing.expectError(error.IndexOutOfBounds, ctx.eval("A[0, 9]"));
}
