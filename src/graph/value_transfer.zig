//! Host-mediated edge Values for the VM-native graph evaluator v1.
//!
//! v1 engine does **not** encode ABI wire layouts — edges carry owned
//! `mathzig.Value` with retain/release. Matrix/complex/record are refcounted
//! (or value types); numbers/booleans/complex are copy-by-value.

const std = @import("std");
const value_mod = @import("../core/value.zig");
const Value = value_mod.Value;
const Matrix = value_mod.Matrix;
const schema = @import("schema.zig");

/// Graph edge value is a MathZig Value (owned when stored in runner slots).
pub const GraphValue = Value;

/// Retain a value for storage on a graph edge / slot.
pub fn retainValue(v: Value) Value {
    v.retain();
    return v;
}

/// Release a previously retained / owned graph value.
pub fn releaseValue(v: Value) void {
    v.release();
}

/// Deep-copy a Value for independent ownership on an edge.
/// Numbers/booleans/complex are bitwise copies; matrix/record/series are retained
/// (refcount share — safe under single-threaded tick protocol). For true deep
/// matrix isolation use `cloneMatrix`.
pub fn transferValue(v: Value) Value {
    v.retain();
    return v;
}

/// Deep-copy a matrix into a new owned Matrix Value.
pub fn cloneMatrix(allocator: std.mem.Allocator, src: *const Matrix) !*Matrix {
    const m = try Matrix.init(allocator, src.rows, src.cols);
    errdefer m.release();
    var r: u32 = 0;
    while (r < src.rows) : (r += 1) {
        var c: u32 = 0;
        while (c < src.cols) : (c += 1) {
            m.set(r, c, src.get(r, c));
        }
    }
    return m;
}

/// Approx equality for golden/determinism checks (numbers + matrix elements).
pub fn valuesEqual(a: Value, b: Value, eps: f64) bool {
    if (a.tag != b.tag) return false;
    return switch (a.tag) {
        .number => blk: {
            const x = a.data.number;
            const y = b.data.number;
            if (std.math.isNan(x) and std.math.isNan(y)) break :blk true;
            break :blk @abs(x - y) <= eps;
        },
        .boolean => a.data.boolean == b.data.boolean,
        .complex => @abs(a.data.complex.re - b.data.complex.re) <= eps and
            @abs(a.data.complex.im - b.data.complex.im) <= eps,
        .matrix => blk: {
            const ma = a.data.matrix;
            const mb = b.data.matrix;
            if (ma.rows != mb.rows or ma.cols != mb.cols) break :blk false;
            var r: u32 = 0;
            while (r < ma.rows) : (r += 1) {
                var c: u32 = 0;
                while (c < ma.cols) : (c += 1) {
                    if (@abs(ma.get(r, c) - mb.get(r, c)) > eps) break :blk false;
                }
            }
            break :blk true;
        },
        else => a.equals(b),
    };
}

/// Infer PortKind from a runtime Value.
pub fn kindOf(v: Value) schema.PortKind {
    return switch (v.tag) {
        .number => .number,
        .boolean => .boolean,
        .matrix => .matrix,
        .complex => .complex,
        .record => .record,
        .string => .string,
        .series => .series,
        else => .number,
    };
}

test "cloneMatrix independent data" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 2, 2);
    defer m.release();
    m.set(0, 0, 1);
    m.set(0, 1, 2);
    m.set(1, 0, 3);
    m.set(1, 1, 4);

    const c = try cloneMatrix(allocator, m);
    defer c.release();
    c.set(0, 0, 99);
    try std.testing.expectApproxEqAbs(@as(f64, 1), m.get(0, 0), 0);
    try std.testing.expectApproxEqAbs(@as(f64, 99), c.get(0, 0), 0);
}
