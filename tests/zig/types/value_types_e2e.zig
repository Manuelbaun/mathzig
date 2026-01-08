//! End-to-End tests for MathZig Value types
//! Tests full lifecycle including creation, operations, and FFI compatibility

const std = @import("std");
const mathzig = @import("mathzig");
const Value = mathzig.Value;
const ValueTag = mathzig.ValueTag;
const Matrix = mathzig.Matrix;
const Complex = mathzig.Complex;
const Series = mathzig.timeseries.Series;
const Record = mathzig.Record;

// ============================================================================
// Value Lifecycle Tests
// ============================================================================

test "Value: full lifecycle with reference counting" {
    const allocator = std.testing.allocator;

    // Create a matrix
    const m = try Matrix.init(allocator, 2, 2);
    m.set(0, 0, 1);
    m.set(0, 1, 2);
    m.set(1, 0, 3);
    m.set(1, 1, 4);

    // Wrap in Value
    var val = Value{ .tag = .matrix, .data = .{ .matrix = m } };
    try std.testing.expectEqual(@as(u32, 1), m.ref_count);

    // Retain increases ref count
    val.retain();
    try std.testing.expectEqual(@as(u32, 2), m.ref_count);

    // Release decreases ref count
    val.release();
    try std.testing.expectEqual(@as(u32, 1), m.ref_count);

    // Final release should free the matrix
    val.release();
}

test "Value: arithmetic preserves types correctly" {
    const allocator = std.testing.allocator;

    // Number + Number -> Number
    const n1 = Value.initNumber(10);
    const n2 = Value.initNumber(20);
    const sum = Value.add(n1, n2);
    try std.testing.expectEqual(ValueTag.number, sum.tag);
    try std.testing.expectEqual(@as(f64, 30), sum.data.number);

    // Number + Complex -> Complex
    const c1 = Value.initComplex(1, 2);
    const mixed = Value.add(n1, c1);
    try std.testing.expectEqual(ValueTag.complex, mixed.tag);
    try std.testing.expectEqual(@as(f64, 11), mixed.data.complex.re);
    try std.testing.expectEqual(@as(f64, 2), mixed.data.complex.im);

    // Matrix + Matrix -> Matrix
    const m1 = try Matrix.init(allocator, 2, 2);
    defer m1.release();
    m1.data[0] = 1;
    m1.data[1] = 2;
    m1.data[2] = 3;
    m1.data[3] = 4;

    const m2 = try Matrix.init(allocator, 2, 2);
    defer m2.release();
    m2.data[0] = 5;
    m2.data[1] = 6;
    m2.data[2] = 7;
    m2.data[3] = 8;

    const v_m1 = Value{ .tag = .matrix, .data = .{ .matrix = m1 } };
    const v_m2 = Value{ .tag = .matrix, .data = .{ .matrix = m2 } };
    const m_sum = Value.add(v_m1, v_m2);
    defer m_sum.data.matrix.release();

    try std.testing.expectEqual(ValueTag.matrix, m_sum.tag);
    try std.testing.expectEqual(@as(f64, 6), m_sum.data.matrix.get(0, 0));
    try std.testing.expectEqual(@as(f64, 12), m_sum.data.matrix.get(1, 1));
}

test "Value: matrix multiplication produces correct dimensions" {
    const allocator = std.testing.allocator;

    // 2x3 * 3x4 -> 2x4
    const a = try Matrix.init(allocator, 2, 3);
    defer a.release();
    for (0..6) |i| a.data[i] = @as(f64, @floatFromInt(i + 1));

    const b = try Matrix.init(allocator, 3, 4);
    defer b.release();
    for (0..12) |i| b.data[i] = @as(f64, @floatFromInt(i + 1));

    const v_a = Value{ .tag = .matrix, .data = .{ .matrix = a } };
    const v_b = Value{ .tag = .matrix, .data = .{ .matrix = b } };

    const product = Value.mul(v_a, v_b, null);
    defer product.data.matrix.release();

    try std.testing.expectEqual(ValueTag.matrix, product.tag);
    try std.testing.expectEqual(@as(u32, 2), product.data.matrix.rows);
    try std.testing.expectEqual(@as(u32, 4), product.data.matrix.cols);
}

// ============================================================================
// Series Value Tests
// ============================================================================

test "Value: series arithmetic with alignment" {
    const allocator = std.testing.allocator;

    // Series 1: [0, 10, 20] -> [1, 2, 3]
    const s1 = try Series.init(allocator, 3, .Linear, .{});
    defer s1.release();
    s1.timestamps[0] = 0;
    s1.timestamps[1] = 10;
    s1.timestamps[2] = 20;
    s1.values[0] = 1;
    s1.values[1] = 2;
    s1.values[2] = 3;
    try s1.validate();

    // Series 2: [5, 15, 25] -> [10, 20, 30]
    const s2 = try Series.init(allocator, 3, .Linear, .{});
    defer s2.release();
    s2.timestamps[0] = 5;
    s2.timestamps[1] = 15;
    s2.timestamps[2] = 25;
    s2.values[0] = 10;
    s2.values[1] = 20;
    s2.values[2] = 30;
    try s2.validate();

    const v1 = Value.initSeries(s1);
    const v2 = Value.initSeries(s2);

    // Series + Series should align and add
    const sum = Value.add(v1, v2);
    defer sum.data.series.release();

    try std.testing.expectEqual(ValueTag.series, sum.tag);
    try std.testing.expect(sum.data.series.len > 0);
}

test "Value: series with scalar operations" {
    const allocator = std.testing.allocator;

    const s = try Series.init(allocator, 3, .Linear, .{});
    defer s.release();
    s.timestamps[0] = 0;
    s.timestamps[1] = 1;
    s.timestamps[2] = 2;
    s.values[0] = 10;
    s.values[1] = 20;
    s.values[2] = 30;
    try s.validate();

    const v_s = Value.initSeries(s);
    const v_scalar = Value.initNumber(5);

    // Series + Scalar
    const sum = Value.add(v_s, v_scalar);
    defer sum.data.series.release();

    try std.testing.expectEqual(ValueTag.series, sum.tag);
    try std.testing.expectEqual(@as(f64, 15), sum.data.series.values[0]);
    try std.testing.expectEqual(@as(f64, 25), sum.data.series.values[1]);
    try std.testing.expectEqual(@as(f64, 35), sum.data.series.values[2]);
}

// ============================================================================
// Record Tests
// ============================================================================

test "Value: record with nested values" {
    const allocator = std.testing.allocator;

    const record = try Record.init(allocator, allocator);
    defer record.release();

    // Add number field
    try record.set("count", Value.initNumber(42));

    // Add complex field
    try record.set("z", Value.initComplex(3, 4));

    // Add matrix field
    const m = try Matrix.init(allocator, 2, 2);
    m.data[0] = 1;
    m.data[1] = 2;
    m.data[2] = 3;
    m.data[3] = 4;
    try record.set("matrix", Value{ .tag = .matrix, .data = .{ .matrix = m } });

    try std.testing.expectEqual(@as(usize, 3), record.len());

    // Verify retrieval
    const count = record.get("count").?;
    try std.testing.expectEqual(@as(f64, 42), count.data.number);

    const z = record.get("z").?;
    try std.testing.expectEqual(@as(f64, 3), z.data.complex.re);
    try std.testing.expectEqual(@as(f64, 4), z.data.complex.im);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "Value: NaN propagation in arithmetic" {
    const nan = Value.initNumber(std.math.nan(f64));
    const num = Value.initNumber(10);

    const sum = Value.add(nan, num);
    try std.testing.expect(std.math.isNan(sum.data.number));

    const prod = Value.mul(nan, num, null);
    try std.testing.expect(std.math.isNan(prod.data.number));
}

test "Value: Infinity in arithmetic" {
    const inf = Value.initNumber(std.math.inf(f64));
    const num = Value.initNumber(10);

    const sum = Value.add(inf, num);
    try std.testing.expect(std.math.isPositiveInf(sum.data.number));

    const neg_inf = Value.initNumber(-std.math.inf(f64));
    const diff = Value.add(inf, neg_inf);
    try std.testing.expect(std.math.isNan(diff.data.number)); // inf + (-inf) = NaN
}

test "Value: division by zero" {
    const num = Value.initNumber(10);
    const zero = Value.initNumber(0);

    const result = Value.div(num, zero, null);
    try std.testing.expect(std.math.isPositiveInf(result.data.number));

    const neg_num = Value.initNumber(-10);
    const neg_result = Value.div(neg_num, zero, null);
    try std.testing.expect(std.math.isNegativeInf(neg_result.data.number));
}

test "Value: type mismatch returns error" {
    const num = Value.initNumber(10);
    const undef = Value.initUndefined();

    const result = Value.add(num, undef);
    try std.testing.expectEqual(ValueTag.err, result.tag);
}
