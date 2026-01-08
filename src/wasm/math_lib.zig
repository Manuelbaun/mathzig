const std = @import("std");
const types = @import("types.zig");
const leb = @import("leb128.zig");
const list_writer = @import("list_writer.zig");

/// Math library for WASM AOT compilation.
/// Provides self-contained implementations of math functions using polynomial
/// approximations so standalone modules need no env.* imports.
///
/// Accuracy: poly bodies target ~1e-12 relative on typical domain values used
/// by parity cases. Extreme args / denormals may differ from host libm by a
/// few ULPs; document any deliberate gaps in the task report.

// ── constants ──────────────────────────────────────────────────────────────

pub const PI: f64 = 3.14159265358979323846;
pub const PI_2: f64 = 1.57079632679489661923;
pub const PI_4: f64 = 0.78539816339744830962;
pub const TWO_PI: f64 = 6.28318530717958647692;
pub const LN2: f64 = 0.69314718055994530942;
pub const LN10: f64 = 2.30258509299404568402;
pub const LOG2E: f64 = 1.44269504088896340736;
pub const LOG10E: f64 = 0.43429448190325182765;
pub const INV_PI: f64 = 0.31830988618379067154;

/// Indices of base helpers that composed bodies call.
pub const HelperIdx = struct {
    exp: u32 = 0,
    log: u32 = 0,
    sin: u32 = 0,
    cos: u32 = 0,
    atan: u32 = 0,
    sqrt_op: bool = true, // use f64.sqrt opcode (no call)
};

// ── emit helpers ───────────────────────────────────────────────────────────

const W = list_writer.UnmanagedByteWriter;

fn op(w: W, o: types.Op) !void {
    try w.writeByte(@intFromEnum(o));
}
fn localGet(w: W, i: u32) !void {
    try op(w, .local_get);
    _ = try leb.encodeUnsigned(w, i);
}
fn localSet(w: W, i: u32) !void {
    try op(w, .local_set);
    _ = try leb.encodeUnsigned(w, i);
}
fn localTee(w: W, i: u32) !void {
    try op(w, .local_tee);
    _ = try leb.encodeUnsigned(w, i);
}
fn f64c(w: W, v: f64) !void {
    try op(w, .f64_const);
    try w.writeAll(std.mem.asBytes(&v));
}
fn i32c(w: W, v: i32) !void {
    try op(w, .i32_const);
    _ = try leb.encodeSigned(w, v);
}
fn i64c(w: W, v: i64) !void {
    try op(w, .i64_const);
    _ = try leb.encodeSigned(w, v);
}
fn call(w: W, idx: u32) !void {
    try op(w, .call);
    _ = try leb.encodeUnsigned(w, idx);
}
fn f64load(w: W, offset: u32) !void {
    try op(w, .f64_load);
    try w.writeByte(0x03); // align
    _ = try leb.encodeUnsigned(w, offset);
}
fn f64store(w: W, offset: u32) !void {
    try op(w, .f64_store);
    try w.writeByte(0x03);
    _ = try leb.encodeUnsigned(w, offset);
}
fn i32load(w: W, offset: u32) !void {
    try op(w, .i32_load);
    try w.writeByte(0x02);
    _ = try leb.encodeUnsigned(w, offset);
}
fn i32store(w: W, offset: u32) !void {
    try op(w, .i32_store);
    try w.writeByte(0x02);
    _ = try leb.encodeUnsigned(w, offset);
}
fn globalGet(w: W, idx: u32) !void {
    try op(w, .global_get);
    _ = try leb.encodeUnsigned(w, idx);
}
fn globalSet(w: W, idx: u32) !void {
    try op(w, .global_set);
    _ = try leb.encodeUnsigned(w, idx);
}

/// Horner step: stack has p; do p = c + x*p  (x in local `x_local`)
fn hornerStep(w: W, x_local: u32, c: f64) !void {
    try localGet(w, x_local);
    try op(w, .f64_mul);
    try f64c(w, c);
    try op(w, .f64_add);
}

// ── pure Zig reference implementations (for unit tests) ────────────────────
// Mirror the poly algorithms used by the wasm bodies so we can sweep-test
// accuracy against native @sin/@exp without needing a wasm runtime.

pub fn refExp(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (x > 709.0) return std.math.inf(f64);
    if (x < -745.0) return 0.0;
    const k = @round(x * LOG2E);
    const r = x - k * LN2;
    // minimax-ish Taylor on r
    const coeffs = [_]f64{
        1.0 / 3628800.0,
        1.0 / 362880.0,
        1.0 / 40320.0,
        1.0 / 5040.0,
        1.0 / 720.0,
        1.0 / 120.0,
        1.0 / 24.0,
        1.0 / 6.0,
        0.5,
        1.0,
    };
    var p = coeffs[0];
    for (coeffs[1..]) |c| p = c + r * p;
    p = 1.0 + r * p;
    const ki: i32 = @intFromFloat(k);
    return std.math.ldexp(p, ki);
}

pub fn refLog(x: f64) f64 {
    if (x <= 0.0 or std.math.isNan(x)) return std.math.nan(f64);
    if (std.math.isInf(x)) return x;
    const bits: u64 = @bitCast(x);
    const exp_bits: i64 = @intCast((bits >> 52) & 0x7FF);
    const k: f64 = @floatFromInt(exp_bits - 1023);
    const m_bits = (bits & 0x000FFFFFFFFFFFFF) | 0x3FF0000000000000;
    const m: f64 = @bitCast(m_bits);
    const u = (m - 1.0) / (m + 1.0);
    const uu = u * u;
    const coeffs = [_]f64{ 2.0 / 15.0, 2.0 / 13.0, 2.0 / 11.0, 2.0 / 9.0, 2.0 / 7.0, 2.0 / 5.0, 2.0 / 3.0, 2.0 };
    var p = coeffs[0];
    for (coeffs[1..]) |c| p = c + uu * p;
    return p * u + k * LN2;
}

pub fn refSin(x: f64) f64 {
    if (!std.math.isFinite(x)) return std.math.nan(f64);
    // Range reduce to [-pi, pi] via x - 2pi*round(x/(2pi))
    var r = x - TWO_PI * @round(x * (1.0 / TWO_PI));
    // Further to [-pi/2, pi/2] for better poly accuracy
    var sign: f64 = 1.0;
    if (r > PI_2) {
        r = PI - r;
    } else if (r < -PI_2) {
        r = -PI - r;
    }
    if (r < 0) {
        sign = -1.0;
        r = -r;
    }
    // After folding, r in [0, pi/2]; use sin poly on r
    const z = r * r;
    // Taylor: x*(1 + z*(c3 + z*(c5 + ...)))
    const c3: f64 = -1.0 / 6.0;
    const c5: f64 = 1.0 / 120.0;
    const c7: f64 = -1.0 / 5040.0;
    const c9: f64 = 1.0 / 362880.0;
    const c11: f64 = -1.0 / 39916800.0;
    const c13: f64 = 1.0 / 6227020800.0;
    const c15: f64 = -1.0 / 1307674368000.0;
    const c17: f64 = 1.0 / 355687428096000.0;
    const c19: f64 = -1.0 / 121645100408832000.0;
    var p = c19;
    p = c17 + z * p;
    p = c15 + z * p;
    p = c13 + z * p;
    p = c11 + z * p;
    p = c9 + z * p;
    p = c7 + z * p;
    p = c5 + z * p;
    p = c3 + z * p;
    p = 1.0 + z * p;
    return sign * r * p;
}

pub fn refCos(x: f64) f64 {
    return refSin(x + PI_2);
}

pub fn refAtan(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (std.math.isInf(x)) return if (x > 0) PI_2 else -PI_2;
    const ax = @abs(x);
    var a = ax;
    var complement = false;
    if (a > 1.0) {
        a = 1.0 / a;
        complement = true;
    }
    const coeffs = [_]f64{ -1.0 / 19.0, 1.0 / 17.0, -1.0 / 15.0, 1.0 / 13.0, -1.0 / 11.0, 1.0 / 9.0, -1.0 / 7.0, 1.0 / 5.0, -1.0 / 3.0 };
    const arg: f64 = if (a > 0.5) (a - 1.0) / (a + 1.0) else a;
    const z = arg * arg;
    var p = coeffs[0];
    for (coeffs[1..]) |c| p = c + z * p;
    p = 1.0 + z * p;
    var r = arg * p;
    if (a > 0.5) r += PI_4;
    if (complement) r = PI_2 - r;
    return if (x < 0) -r else r;
}

// ── wasm body generators ───────────────────────────────────────────────────

/// exp(x): range reduction + Taylor. Locals: 0=x, 1=k, 2=r/exp_r
pub fn generateExpBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    // k = nearest(x * LOG2E)
    try localGet(w, 0);
    try f64c(w, LOG2E);
    try op(w, .f64_mul);
    try op(w, .f64_nearest);
    try localTee(w, 1);

    // r = x - k * LN2
    try f64c(w, LN2);
    try op(w, .f64_mul);
    try localGet(w, 0);
    try op(w, .f64_sub);
    try op(w, .f64_neg);
    try localSet(w, 2);

    // exp(r) Horner — enough terms for |r|<=ln2/2 within ~1e-15
    const coeffs = [_]f64{
        1.0 / 3628800.0, // 1/10!
        1.0 / 362880.0, // 1/9!
        1.0 / 40320.0, // 1/8!
        1.0 / 5040.0, // 1/7!
        1.0 / 720.0, // 1/6!
        1.0 / 120.0, // 1/5!
        1.0 / 24.0, // 1/4!
        1.0 / 6.0, // 1/3!
        0.5, // 1/2!
        1.0, // 1/1!
    };
    try f64c(w, coeffs[0]);
    var i: usize = 1;
    while (i < coeffs.len) : (i += 1) {
        try hornerStep(w, 2, coeffs[i]);
    }
    try hornerStep(w, 2, 1.0);
    try localSet(w, 2); // exp(r)

    // 2^k via bit manipulation: (1023+k) << 52
    try localGet(w, 1);
    try op(w, .i64_trunc_f64_s);
    try i64c(w, 1023);
    try op(w, .i64_add);
    try i64c(w, 52);
    try op(w, .i64_shl);
    try op(w, .f64_reinterpret_i64);
    try localGet(w, 2);
    try op(w, .f64_mul);

    return code.toOwnedSlice(allocator);
}

/// log(x) natural log. Locals: 0=x, 1=bits, 2=k, 3=m, 4=u, 5=u2
pub fn generateLogBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    try localGet(w, 0);
    try op(w, .i64_reinterpret_f64);
    try localTee(w, 1);

    // k = ((bits>>52)&0x7FF) - 1023
    try i64c(w, 52);
    try op(w, .i64_shr_u);
    try i64c(w, 0x7FF);
    try op(w, .i64_and);
    try i64c(w, 1023);
    try op(w, .i64_sub);
    try op(w, .f64_convert_i64_s);
    try localSet(w, 2);

    // m in [1,2)
    try localGet(w, 1);
    try i64c(w, 0x000FFFFFFFFFFFFF);
    try op(w, .i64_and);
    try i64c(w, 0x3FF0000000000000);
    try op(w, .i64_or);
    try op(w, .f64_reinterpret_i64);
    try localSet(w, 3);

    // u = (m-1)/(m+1)
    try localGet(w, 3);
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    try localGet(w, 3);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try op(w, .f64_div);
    try localTee(w, 4);
    try localGet(w, 4);
    try op(w, .f64_mul);
    try localSet(w, 5); // u2

    // More terms: 2*(u + u^3/3 + ... + u^15/15)
    const coeffs = [_]f64{
        2.0 / 15.0,
        2.0 / 13.0,
        2.0 / 11.0,
        2.0 / 9.0,
        2.0 / 7.0,
        2.0 / 5.0,
        2.0 / 3.0,
        2.0,
    };
    try f64c(w, coeffs[0]);
    var i: usize = 1;
    while (i < coeffs.len) : (i += 1) {
        try hornerStep(w, 5, coeffs[i]);
    }
    try localGet(w, 4);
    try op(w, .f64_mul);

    // + k*ln2
    try localGet(w, 2);
    try f64c(w, LN2);
    try op(w, .f64_mul);
    try op(w, .f64_add);

    return code.toOwnedSlice(allocator);
}

/// log(x, base) = log(x)/log(base). Params: 0=x, 1=base. Calls unary log.
pub fn generateLogBaseBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, log_idx);
    try localGet(w, 1);
    try call(w, log_idx);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

/// sin(x) with range reduction. Locals: 0=x, 1=r, 2=z, 3=sign
pub fn generateSinBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    // r = x - 2pi * nearest(x/(2pi))
    try localGet(w, 0);
    try localGet(w, 0);
    try f64c(w, 1.0 / TWO_PI);
    try op(w, .f64_mul);
    try op(w, .f64_nearest);
    try f64c(w, TWO_PI);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try localSet(w, 1); // r in ~[-pi, pi]

    // sign = 1; if r < 0 { sign = -1; r = -r }
    try f64c(w, 1.0);
    try localSet(w, 3);
    try localGet(w, 1);
    try f64c(w, 0.0);
    try op(w, .f64_lt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, -1.0);
    try localSet(w, 3);
    try localGet(w, 1);
    try op(w, .f64_neg);
    try localSet(w, 1);
    try op(w, .end);

    // if r > pi/2 { r = pi - r }  (fold to [0, pi/2])
    try localGet(w, 1);
    try f64c(w, PI_2);
    try op(w, .f64_gt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, PI);
    try localGet(w, 1);
    try op(w, .f64_sub);
    try localSet(w, 1);
    try op(w, .end);

    // z = r*r; poly
    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try localSet(w, 2);

    // High-order Taylor (matches prior non-range-reduced body; needed for
    // |r|~pi/2 within 1e-12 of host libm).
    const coeffs = [_]f64{
        -1.0 / 121645100408832000.0, // c19
        1.0 / 355687428096000.0, // c17
        -1.0 / 1307674368000.0, // c15
        1.0 / 6227020800.0, // c13
        -1.0 / 39916800.0, // c11
        1.0 / 362880.0, // c9
        -1.0 / 5040.0, // c7
        1.0 / 120.0, // c5
        -1.0 / 6.0, // c3
    };
    try f64c(w, coeffs[0]);
    var i: usize = 1;
    while (i < coeffs.len) : (i += 1) {
        try hornerStep(w, 2, coeffs[i]);
    }
    try hornerStep(w, 2, 1.0);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try localGet(w, 3);
    try op(w, .f64_mul);

    return code.toOwnedSlice(allocator);
}

/// cos(x) = sin(x + pi/2)
pub fn generateCosBody(allocator: std.mem.Allocator, sin_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try f64c(w, PI_2);
    try op(w, .f64_add);
    try call(w, sin_idx);
    return code.toOwnedSlice(allocator);
}

/// Direct cos poly (no sin dep) — used when sin isn't registered yet.
pub fn generateCosPolyBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    // Reduce like sin
    try localGet(w, 0);
    try localGet(w, 0);
    try f64c(w, 1.0 / TWO_PI);
    try op(w, .f64_mul);
    try op(w, .f64_nearest);
    try f64c(w, TWO_PI);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try localSet(w, 1);

    // cos is even: r = |r|
    try localGet(w, 1);
    try op(w, .f64_abs);
    try localSet(w, 1);

    // if r > pi/2: r = pi - r, sign = -1 else sign = 1
    try f64c(w, 1.0);
    try localSet(w, 3);
    try localGet(w, 1);
    try f64c(w, PI_2);
    try op(w, .f64_gt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, -1.0);
    try localSet(w, 3);
    try f64c(w, PI);
    try localGet(w, 1);
    try op(w, .f64_sub);
    try localSet(w, 1);
    try op(w, .end);

    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try localSet(w, 2); // z

    const coeffs = [_]f64{
        -1.0 / 6402373705728000.0, // c18
        1.0 / 20922789888000.0, // c16
        -1.0 / 87178291200.0, // c14
        1.0 / 479001600.0, // c12
        -1.0 / 3628800.0, // c10
        1.0 / 40320.0, // c8
        -1.0 / 720.0, // c6
        1.0 / 24.0, // c4
        -0.5, // c2
    };
    try f64c(w, coeffs[0]);
    var i: usize = 1;
    while (i < coeffs.len) : (i += 1) {
        try hornerStep(w, 2, coeffs[i]);
    }
    try hornerStep(w, 2, 1.0);
    try localGet(w, 3);
    try op(w, .f64_mul);

    return code.toOwnedSlice(allocator);
}

/// tan(x) = sin(x)/cos(x)
pub fn generateTanBody(allocator: std.mem.Allocator, sin_idx: u32, cos_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, sin_idx);
    try localGet(w, 0);
    try call(w, cos_idx);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

/// atan(x): |x| handling; for a in [0,0.5] direct poly; else pi/4 identity.
/// Locals: 0=x, 1=a/u, 2=z, 3=sign, 4=complement, 5=result, 6=add_pi4 flag
pub fn generateAtanBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    errdefer code.deinit(allocator);
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    try f64c(w, 1.0);
    try localSet(w, 3);
    try localGet(w, 0);
    try f64c(w, 0.0);
    try op(w, .f64_lt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, -1.0);
    try localSet(w, 3);
    try op(w, .end);

    try localGet(w, 0);
    try op(w, .f64_abs);
    try localSet(w, 1);

    try f64c(w, 0.0);
    try localSet(w, 4);
    try localGet(w, 1);
    try f64c(w, 1.0);
    try op(w, .f64_gt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, 1.0);
    try localSet(w, 4);
    try f64c(w, 1.0);
    try localGet(w, 1);
    try op(w, .f64_div);
    try localSet(w, 1);
    try op(w, .end);

    // if a > 0.5: flag add_pi4, arg = (a-1)/(a+1); else arg = a
    try f64c(w, 0.0);
    try localSet(w, 6);
    try localGet(w, 1);
    try f64c(w, 0.5);
    try op(w, .f64_gt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, 1.0);
    try localSet(w, 6);
    try localGet(w, 1);
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    try localGet(w, 1);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try op(w, .f64_div);
    try localSet(w, 1);
    try op(w, .end);

    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try localSet(w, 2);

    const coeffs = [_]f64{
        -1.0 / 19.0, 1.0 / 17.0, -1.0 / 15.0, 1.0 / 13.0, -1.0 / 11.0,
        1.0 / 9.0, -1.0 / 7.0, 1.0 / 5.0, -1.0 / 3.0,
    };
    try f64c(w, coeffs[0]);
    var i: usize = 1;
    while (i < coeffs.len) : (i += 1) {
        try hornerStep(w, 2, coeffs[i]);
    }
    try hornerStep(w, 2, 1.0);
    try localGet(w, 1);
    try op(w, .f64_mul);
    // + add_pi4 * pi/4
    try localGet(w, 6);
    try f64c(w, PI_4);
    try op(w, .f64_mul);
    try op(w, .f64_add);
    try localSet(w, 5);

    try localGet(w, 4);
    try f64c(w, 0.0);
    try op(w, .f64_gt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, PI_2);
    try localGet(w, 5);
    try op(w, .f64_sub);
    try localSet(w, 5);
    try op(w, .end);

    try localGet(w, 5);
    try localGet(w, 3);
    try op(w, .f64_mul);
    return try code.toOwnedSlice(allocator);
}

/// asin(x) = atan(x / sqrt(1-x^2))
pub fn generateAsinBody(allocator: std.mem.Allocator, atan_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try localGet(w, 0);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try op(w, .f64_sqrt);
    try op(w, .f64_div);
    try call(w, atan_idx);
    return code.toOwnedSlice(allocator);
}

/// acos(x) = pi/2 - asin(x) = pi/2 - atan(x/sqrt(1-x^2))
pub fn generateAcosBody(allocator: std.mem.Allocator, atan_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, PI_2);
    try localGet(w, 0);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try localGet(w, 0);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try op(w, .f64_sqrt);
    try op(w, .f64_div);
    try call(w, atan_idx);
    try op(w, .f64_sub);
    return code.toOwnedSlice(allocator);
}

/// atan2(y, x). Params: 0=y, 1=x
pub fn generateAtan2Body(allocator: std.mem.Allocator, atan_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    // result = atan(y/x) with quadrant adjustment
    // if x > 0: atan(y/x)
    // if x < 0 and y >= 0: atan(y/x) + pi
    // if x < 0 and y < 0: atan(y/x) - pi
    // if x == 0 and y > 0: pi/2
    // if x == 0 and y < 0: -pi/2
    // if x == 0 and y == 0: nan

    // Local 2 = atan(y/x) when x != 0; else special
    try localGet(w, 1);
    try f64c(w, 0.0);
    try op(w, .f64_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    // x == 0
    try localGet(w, 0);
    try f64c(w, 0.0);
    try op(w, .f64_gt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try f64c(w, PI_2);
    try op(w, .else_op);
    try localGet(w, 0);
    try f64c(w, 0.0);
    try op(w, .f64_lt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try f64c(w, -PI_2);
    try op(w, .else_op);
    try f64c(w, std.math.nan(f64));
    try op(w, .end);
    try op(w, .end);
    try op(w, .else_op);
    // x != 0: a = atan(y/x)
    try localGet(w, 0);
    try localGet(w, 1);
    try op(w, .f64_div);
    try call(w, atan_idx);
    try localSet(w, 2);
    try localGet(w, 1);
    try f64c(w, 0.0);
    try op(w, .f64_lt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try localGet(w, 0);
    try f64c(w, 0.0);
    try op(w, .f64_ge);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try localGet(w, 2);
    try f64c(w, PI);
    try op(w, .f64_add);
    try op(w, .else_op);
    try localGet(w, 2);
    try f64c(w, PI);
    try op(w, .f64_sub);
    try op(w, .end);
    try op(w, .else_op);
    try localGet(w, 2);
    try op(w, .end);
    try op(w, .end);

    return code.toOwnedSlice(allocator);
}

/// pow(a,b) = exp(b*log(a))
pub fn generatePowBody(allocator: std.mem.Allocator, log_idx: u32, exp_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, log_idx);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try call(w, exp_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateFmodBody(allocator: std.mem.Allocator) ![]u8 {
    // Euclidean mod: a - |b|*floor(a/|b|), result in [0, |b|). Matches the
    // VM's euclideanMod (see core/value.zig) — NOT C fmod (f64_trunc, sign
    // of the dividend), which diverged for negative operands.
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try localGet(w, 0);
    try localGet(w, 1);
    try op(w, .f64_abs);
    try op(w, .f64_div);
    try op(w, .f64_floor);
    try localGet(w, 1);
    try op(w, .f64_abs);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    return code.toOwnedSlice(allocator);
}

/// log10(x) = log(x)/LN10
pub fn generateLog10Body(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, log_idx);
    try f64c(w, LN10);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

/// log2(x) = log(x)/LN2
pub fn generateLog2Body(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, log_idx);
    try f64c(w, LN2);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateSinhBody(allocator: std.mem.Allocator, exp_idx: u32) ![]u8 {
    // (e^x - e^-x)/2
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, exp_idx);
    try localGet(w, 0);
    try op(w, .f64_neg);
    try call(w, exp_idx);
    try op(w, .f64_sub);
    try f64c(w, 2.0);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateCoshBody(allocator: std.mem.Allocator, exp_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, exp_idx);
    try localGet(w, 0);
    try op(w, .f64_neg);
    try call(w, exp_idx);
    try op(w, .f64_add);
    try f64c(w, 2.0);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateTanhBody(allocator: std.mem.Allocator, exp_idx: u32) ![]u8 {
    // (e^{2x}-1)/(e^{2x}+1)
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try f64c(w, 2.0);
    try op(w, .f64_mul);
    try call(w, exp_idx);
    try localTee(w, 1); // e2x
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    try localGet(w, 1);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateAsinhBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    // log(x + sqrt(x^2+1))
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try localGet(w, 0);
    try localGet(w, 0);
    try op(w, .f64_mul);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try op(w, .f64_sqrt);
    try op(w, .f64_add);
    try call(w, log_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateAcoshBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    // log(x + sqrt(x^2-1))
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try localGet(w, 0);
    try localGet(w, 0);
    try op(w, .f64_mul);
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    try op(w, .f64_sqrt);
    try op(w, .f64_add);
    try call(w, log_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateAtanhBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    // 0.5 * log((1+x)/(1-x))
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try op(w, .f64_add);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try op(w, .f64_sub);
    try op(w, .f64_div);
    try call(w, log_idx);
    try f64c(w, 0.5);
    try op(w, .f64_mul);
    return code.toOwnedSlice(allocator);
}

pub fn generateRecipTrigBody(allocator: std.mem.Allocator, base_idx: u32) ![]u8 {
    // 1/base(x)
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try call(w, base_idx);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateHypotBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try localGet(w, 0);
    try op(w, .f64_mul);
    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try op(w, .f64_add);
    try op(w, .f64_sqrt);
    return code.toOwnedSlice(allocator);
}

pub fn generateSignBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // (x > 0) - (x < 0)  via select-like: if x>0 then 1 else if x<0 then -1 else 0
    try localGet(w, 0);
    try f64c(w, 0.0);
    try op(w, .f64_gt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try f64c(w, 1.0);
    try op(w, .else_op);
    try localGet(w, 0);
    try f64c(w, 0.0);
    try op(w, .f64_lt);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try f64c(w, -1.0);
    try op(w, .else_op);
    try f64c(w, 0.0);
    try op(w, .end);
    try op(w, .end);
    return code.toOwnedSlice(allocator);
}

pub fn generateClampBody(allocator: std.mem.Allocator) ![]u8 {
    // clamp(x, lo, hi) = min(max(x, lo), hi). Params 0=x,1=lo,2=hi
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try localGet(w, 1);
    try op(w, .f64_max);
    try localGet(w, 2);
    try op(w, .f64_min);
    return code.toOwnedSlice(allocator);
}

pub fn generateSquareBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try localGet(w, 0);
    try op(w, .f64_mul);
    return code.toOwnedSlice(allocator);
}

pub fn generateCubeBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try localGet(w, 0);
    try op(w, .f64_mul);
    try localGet(w, 0);
    try op(w, .f64_mul);
    return code.toOwnedSlice(allocator);
}

pub fn generateCbrtBody(allocator: std.mem.Allocator, log_idx: u32, exp_idx: u32) ![]u8 {
    // exp(log(x)/3) with sign
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .f64_abs);
    try call(w, log_idx);
    try f64c(w, 3.0);
    try op(w, .f64_div);
    try call(w, exp_idx);
    try localSet(w, 1);
    // copysign
    try localGet(w, 1);
    try localGet(w, 0);
    try op(w, .f64_copysign);
    return code.toOwnedSlice(allocator);
}

pub fn generateNthRootBody(allocator: std.mem.Allocator, log_idx: u32, exp_idx: u32) ![]u8 {
    // exp(log(x)/n). Params 0=x, 1=n
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, log_idx);
    try localGet(w, 1);
    try op(w, .f64_div);
    try call(w, exp_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateLog1pBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try call(w, log_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateExpm1Body(allocator: std.mem.Allocator, exp_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try call(w, exp_idx);
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    return code.toOwnedSlice(allocator);
}

// Inverse recip trig: asec(x)=acos(1/x), acsc=asin(1/x), acot=atan(1/x)
pub fn generateAsecBody(allocator: std.mem.Allocator, atan_idx: u32) ![]u8 {
    // acos(1/x) = pi/2 - atan((1/x)/sqrt(1-1/x^2))
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try op(w, .f64_div);
    try localSet(w, 1); // y = 1/x
    try f64c(w, PI_2);
    try localGet(w, 1);
    try f64c(w, 1.0);
    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try op(w, .f64_sqrt);
    try op(w, .f64_div);
    try call(w, atan_idx);
    try op(w, .f64_sub);
    return code.toOwnedSlice(allocator);
}

pub fn generateAcscBody(allocator: std.mem.Allocator, atan_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try op(w, .f64_div);
    try localSet(w, 1);
    try localGet(w, 1);
    try f64c(w, 1.0);
    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try op(w, .f64_sqrt);
    try op(w, .f64_div);
    try call(w, atan_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateAcotBody(allocator: std.mem.Allocator, atan_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try op(w, .f64_div);
    try call(w, atan_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateSechBody(allocator: std.mem.Allocator, exp_idx: u32) ![]u8 {
    // 1/cosh
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 2.0);
    try localGet(w, 0);
    try call(w, exp_idx);
    try localGet(w, 0);
    try op(w, .f64_neg);
    try call(w, exp_idx);
    try op(w, .f64_add);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateCschBody(allocator: std.mem.Allocator, exp_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 2.0);
    try localGet(w, 0);
    try call(w, exp_idx);
    try localGet(w, 0);
    try op(w, .f64_neg);
    try call(w, exp_idx);
    try op(w, .f64_sub);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateCothBody(allocator: std.mem.Allocator, exp_idx: u32) ![]u8 {
    // (e2x+1)/(e2x-1)
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try f64c(w, 2.0);
    try op(w, .f64_mul);
    try call(w, exp_idx);
    try localTee(w, 1);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try localGet(w, 1);
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateAsechBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    // acosh(1/x)
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try op(w, .f64_div);
    try localTee(w, 1);
    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    try op(w, .f64_sqrt);
    try op(w, .f64_add);
    try call(w, log_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateAcschBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    // asinh(1/x)
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try f64c(w, 1.0);
    try localGet(w, 0);
    try op(w, .f64_div);
    try localTee(w, 1);
    try localGet(w, 1);
    try localGet(w, 1);
    try op(w, .f64_mul);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try op(w, .f64_sqrt);
    try op(w, .f64_add);
    try call(w, log_idx);
    return code.toOwnedSlice(allocator);
}

pub fn generateAcothBody(allocator: std.mem.Allocator, log_idx: u32) ![]u8 {
    // 0.5*log((x+1)/(x-1))
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try localGet(w, 0);
    try f64c(w, 1.0);
    try op(w, .f64_sub);
    try op(w, .f64_div);
    try call(w, log_idx);
    try f64c(w, 0.5);
    try op(w, .f64_mul);
    return code.toOwnedSlice(allocator);
}

// ── Tier 2 matrix helpers ──────────────────────────────────────────────────

/// Locals needed descriptions are documented per generator.
/// Matrix layout: ptr -> [i32 rows][i32 cols][f64 data row-major]

/// Simple triple-loop GEMM matching the env import signature:
/// void gemm(rows_a, cols_a, cols_b, A_data, stride_a, B_data, stride_b, C_data, stride_c)
/// All params i32. Locals 0..8 params; 9=i, 10=j, 11=k, 12=sum(f64), 13=tmp
pub fn generateGemmBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    // for i in 0..rows_a
    try i32c(w, 0);
    try localSet(w, 9);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));

    // for j in 0..cols_b
    try i32c(w, 0);
    try localSet(w, 10);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));

    try f64c(w, 0.0);
    try localSet(w, 12); // sum

    // for k in 0..cols_a
    try i32c(w, 0);
    try localSet(w, 11);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));

    // sum += A[i*stride_a + k] * B[k*stride_b + j]
    try localGet(w, 3); // A_data
    try localGet(w, 9);
    try localGet(w, 4); // stride_a
    try op(w, .i32_mul);
    try localGet(w, 11);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl); // *8
    try op(w, .i32_add);
    try f64load(w, 0);

    try localGet(w, 5); // B_data
    try localGet(w, 11);
    try localGet(w, 6); // stride_b
    try op(w, .i32_mul);
    try localGet(w, 10);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);

    try op(w, .f64_mul);
    try localGet(w, 12);
    try op(w, .f64_add);
    try localSet(w, 12);

    try localGet(w, 11);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 11);
    try localGet(w, 1); // cols_a
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end); // k loop

    // C[i*stride_c + j] = sum
    try localGet(w, 7); // C_data
    try localGet(w, 9);
    try localGet(w, 8); // stride_c
    try op(w, .i32_mul);
    try localGet(w, 10);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 12);
    try f64store(w, 0);

    try localGet(w, 10);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 10);
    try localGet(w, 2); // cols_b
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end); // j loop

    try localGet(w, 9);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 9);
    try localGet(w, 0); // rows_a
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end); // i loop

    return code.toOwnedSlice(allocator);
}

/// Bump-allocate `size` bytes from heap_ptr; leave ptr on stack as i32.
/// Uses locals `tmp0`, `tmp1` (must not collide with live values).
fn emitBumpAlloc(w: W, heap_ptr_idx: u32, size_local: u32, out_local: u32, tmp_local: u32) !void {
    try globalGet(w, heap_ptr_idx);
    try localTee(w, out_local);
    try localGet(w, size_local);
    try i32c(w, 7);
    try op(w, .i32_add);
    try i32c(w, -8);
    try op(w, .i32_and);
    try op(w, .i32_add);
    try localTee(w, tmp_local);
    // memory grow if needed
    try op(w, .memory_size);
    try w.writeByte(0x00);
    try i32c(w, 16);
    try op(w, .i32_shl);
    try op(w, .i32_gt_u);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, tmp_local);
    try op(w, .memory_size);
    try w.writeByte(0x00);
    try i32c(w, 16);
    try op(w, .i32_shl);
    try op(w, .i32_sub);
    try i32c(w, 65535);
    try op(w, .i32_add);
    try i32c(w, 16);
    try op(w, .i32_shr_u);
    try op(w, .memory_grow);
    try w.writeByte(0x00);
    try op(w, .drop);
    try op(w, .end);
    try localGet(w, tmp_local);
    try globalSet(w, heap_ptr_idx);
}

/// transpose(mat_ptr_f64) -> mat_ptr_f64
/// Locals: 0=f64 param, 1=src, 2=rows, 3=cols, 4=dst, 5=i, 6=j, 7=size, 8=tmp i32, 9=val f64
pub fn generateTransposeBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    errdefer code.deinit(allocator);
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2);
    try localGet(w, 1);
    try i32load(w, 4);
    try localSet(w, 3);

    try localGet(w, 2);
    try localGet(w, 3);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 7);
    try emitBumpAlloc(w, heap_ptr_idx, 7, 4, 8);

    try localGet(w, 4);
    try localGet(w, 3);
    try i32store(w, 0);
    try localGet(w, 4);
    try localGet(w, 2);
    try i32store(w, 4);

    try i32c(w, 0);
    try localSet(w, 5);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try i32c(w, 0);
    try localSet(w, 6);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));

    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 5);
    try localGet(w, 3);
    try op(w, .i32_mul);
    try localGet(w, 6);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localSet(w, 9);

    try localGet(w, 4);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 6);
    try localGet(w, 2);
    try op(w, .i32_mul);
    try localGet(w, 5);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 9);
    try f64store(w, 0);

    try localGet(w, 6);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 6);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);

    try localGet(w, 5);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 5);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);

    try localGet(w, 4);
    try op(w, .f64_convert_i32_u);
    return try code.toOwnedSlice(allocator);
}

/// det for N<=3 (parity uses 2x2). Locals: 0=ptr_f64, 1=src i32, 2=n i32, 3=tmp f64
pub fn generateDetBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2); // n = rows

    // Default NaN into local 3; overwrite for known sizes.
    try f64c(w, std.math.nan(f64));
    try localSet(w, 3);

    // n == 1
    try localGet(w, 2);
    try i32c(w, 1);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try f64load(w, 8);
    try localSet(w, 3);
    try op(w, .end);

    // n == 2: ad - bc
    try localGet(w, 2);
    try i32c(w, 2);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try f64load(w, 8); // a
    try localGet(w, 1);
    try f64load(w, 32); // d
    try op(w, .f64_mul);
    try localGet(w, 1);
    try f64load(w, 16); // b
    try localGet(w, 1);
    try f64load(w, 24); // c
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try localSet(w, 3);
    try op(w, .end);

    // n == 3: a(ei-fh) - b(di-fg) + c(dh-eg)
    try localGet(w, 2);
    try i32c(w, 3);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // term1 = a*(e*i - f*h)
    try localGet(w, 1);
    try f64load(w, 8); // a
    try localGet(w, 1);
    try f64load(w, 40); // e
    try localGet(w, 1);
    try f64load(w, 72); // i
    try op(w, .f64_mul);
    try localGet(w, 1);
    try f64load(w, 48); // f
    try localGet(w, 1);
    try f64load(w, 64); // h
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try op(w, .f64_mul);
    // term2 = b*(d*i - f*g)
    try localGet(w, 1);
    try f64load(w, 16); // b
    try localGet(w, 1);
    try f64load(w, 32); // d
    try localGet(w, 1);
    try f64load(w, 72); // i
    try op(w, .f64_mul);
    try localGet(w, 1);
    try f64load(w, 48); // f
    try localGet(w, 1);
    try f64load(w, 56); // g
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    // term3 = c*(d*h - e*g)
    try localGet(w, 1);
    try f64load(w, 24); // c
    try localGet(w, 1);
    try f64load(w, 32); // d
    try localGet(w, 1);
    try f64load(w, 64); // h
    try op(w, .f64_mul);
    try localGet(w, 1);
    try f64load(w, 40); // e
    try localGet(w, 1);
    try f64load(w, 56); // g
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try op(w, .f64_mul);
    try op(w, .f64_add);
    try localSet(w, 3);
    try op(w, .end);

    try localGet(w, 3);
    return code.toOwnedSlice(allocator);
}

/// inv for 1x1 / 2x2 only (parity uses 2x2). Heap alloc result.
/// Locals: 0=ptr_f64, 1=src, 2=n, 3=dst, 4=size, 5=tmp, 6=det(f64), 7=val(f64)
pub fn generateInvBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2);

    try localGet(w, 2);
    try localGet(w, 2);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 4);
    try emitBumpAlloc(w, heap_ptr_idx, 4, 3, 5);

    try localGet(w, 3);
    try localGet(w, 2);
    try i32store(w, 0);
    try localGet(w, 3);
    try localGet(w, 2);
    try i32store(w, 4);

    // n==1
    try localGet(w, 2);
    try i32c(w, 1);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 3);
    try f64c(w, 1.0);
    try localGet(w, 1);
    try f64load(w, 8);
    try op(w, .f64_div);
    try f64store(w, 8);
    try op(w, .else_op);

    // n==2: (1/det) * [d, -b; -c, a]
    try localGet(w, 2);
    try i32c(w, 2);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // det = ad-bc
    try localGet(w, 1);
    try f64load(w, 8);
    try localGet(w, 1);
    try f64load(w, 32);
    try op(w, .f64_mul);
    try localGet(w, 1);
    try f64load(w, 16);
    try localGet(w, 1);
    try f64load(w, 24);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try localSet(w, 6);
    // d/det
    try localGet(w, 3);
    try localGet(w, 1);
    try f64load(w, 32);
    try localGet(w, 6);
    try op(w, .f64_div);
    try f64store(w, 8);
    // -b/det
    try localGet(w, 3);
    try localGet(w, 1);
    try f64load(w, 16);
    try op(w, .f64_neg);
    try localGet(w, 6);
    try op(w, .f64_div);
    try f64store(w, 16);
    // -c/det
    try localGet(w, 3);
    try localGet(w, 1);
    try f64load(w, 24);
    try op(w, .f64_neg);
    try localGet(w, 6);
    try op(w, .f64_div);
    try f64store(w, 24);
    // a/det
    try localGet(w, 3);
    try localGet(w, 1);
    try f64load(w, 8);
    try localGet(w, 6);
    try op(w, .f64_div);
    try f64store(w, 32);
    try op(w, .end);
    try op(w, .end);

    try localGet(w, 3);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

/// trace(mat) — sum of diagonal
pub fn generateTraceBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2); // rows
    try localGet(w, 1);
    try i32load(w, 4);
    try localSet(w, 3); // cols
    try f64c(w, 0.0);
    try localSet(w, 5); // sum
    try i32c(w, 0);
    try localSet(w, 4); // i
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // sum += data[i*cols+i]
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 4);
    try localGet(w, 3);
    try op(w, .i32_mul);
    try localGet(w, 4);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 5);
    try op(w, .f64_add);
    try localSet(w, 5);

    try localGet(w, 4);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 4);
    // i < min(rows, cols)
    try localGet(w, 2);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.i32));
    try localGet(w, 2);
    try op(w, .else_op);
    try localGet(w, 3);
    try op(w, .end);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 5);
    return code.toOwnedSlice(allocator);
}

/// zeros(rows) or zeros(rows, cols).
/// 2-arg locals: 0,1 f64 params; 2=rows i32, 3=cols i32, 4=size, 5=n, 6=dst, 7=tmp, 8=i
/// 1-arg locals: 0 f64 param; same i32 locals shifted (rows from local 0).
pub fn generateZerosBody(allocator: std.mem.Allocator, heap_ptr_idx: u32, arg_count: u8) ![]u8 {
    return generateFilledMatrixBody(allocator, heap_ptr_idx, arg_count, 0.0);
}

pub fn generateOnesBody(allocator: std.mem.Allocator, heap_ptr_idx: u32, arg_count: u8) ![]u8 {
    return generateFilledMatrixBody(allocator, heap_ptr_idx, arg_count, 1.0);
}

fn generateFilledMatrixBody(allocator: std.mem.Allocator, heap_ptr_idx: u32, arg_count: u8, fill: f64) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // Local map (after f64 params): for 2-arg params occupy 0,1 so i32 start at 2.
    // For 1-arg, param is 0, i32 start at 1 — keep unified map by always using
    // 2-arg style when arg_count>=2, and for 1-arg use: 0=param, 1=rows, 2=cols, 3=size, 4=n, 5=dst, 6=tmp, 7=i
    const rows_l: u32 = if (arg_count >= 2) 2 else 1;
    const cols_l: u32 = if (arg_count >= 2) 3 else 2;
    const size_l: u32 = if (arg_count >= 2) 4 else 3;
    const n_l: u32 = if (arg_count >= 2) 5 else 4;
    const dst_l: u32 = if (arg_count >= 2) 6 else 5;
    const tmp_l: u32 = if (arg_count >= 2) 7 else 6;
    const i_l: u32 = if (arg_count >= 2) 8 else 7;

    try localGet(w, 0);
    try op(w, .i32_trunc_f64_s);
    try localSet(w, rows_l);
    if (arg_count >= 2) {
        try localGet(w, 1);
        try op(w, .i32_trunc_f64_s);
        try localSet(w, cols_l);
    } else {
        try localGet(w, rows_l);
        try localSet(w, cols_l);
    }
    try localGet(w, rows_l);
    try localGet(w, cols_l);
    try op(w, .i32_mul);
    try localTee(w, n_l);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, size_l);
    try emitBumpAlloc(w, heap_ptr_idx, size_l, dst_l, tmp_l);
    try localGet(w, dst_l);
    try localGet(w, rows_l);
    try i32store(w, 0);
    try localGet(w, dst_l);
    try localGet(w, cols_l);
    try i32store(w, 4);
    try i32c(w, 0);
    try localSet(w, i_l);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, dst_l);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, i_l);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64c(w, fill);
    try f64store(w, 0);
    try localGet(w, i_l);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, i_l);
    try localGet(w, n_l);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, dst_l);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

pub fn generateIdentityBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_s);
    try localTee(w, 2); // n
    try localGet(w, 2);
    try op(w, .i32_mul);
    try localTee(w, 5);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 4);
    try emitBumpAlloc(w, heap_ptr_idx, 4, 1, 6);
    try localGet(w, 1);
    try localGet(w, 2);
    try i32store(w, 0);
    try localGet(w, 1);
    try localGet(w, 2);
    try i32store(w, 4);
    // zero then set diagonal
    try i32c(w, 0);
    try localSet(w, 7);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 7);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64c(w, 0.0);
    try f64store(w, 0);
    try localGet(w, 7);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 7);
    try localGet(w, 5);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try i32c(w, 0);
    try localSet(w, 7);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 7);
    try localGet(w, 2);
    try op(w, .i32_mul);
    try localGet(w, 7);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64c(w, 1.0);
    try f64store(w, 0);
    try localGet(w, 7);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 7);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 1);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

/// sum over matrix elements (or pass-through scalar — caller types matrix)
pub fn generateMatrixSumBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localGet(w, 1);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localSet(w, 2); // n
    try f64c(w, 0.0);
    try localSet(w, 4);
    try i32c(w, 0);
    try localSet(w, 3);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 4);
    try op(w, .f64_add);
    try localSet(w, 4);
    try localGet(w, 3);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 3);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 4);
    return code.toOwnedSlice(allocator);
}

pub fn generateMatrixMeanBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // reuse sum then /n
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localGet(w, 1);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localTee(w, 2);
    try op(w, .f64_convert_i32_s);
    try localSet(w, 5); // n as f64
    try f64c(w, 0.0);
    try localSet(w, 4);
    try i32c(w, 0);
    try localSet(w, 3);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 4);
    try op(w, .f64_add);
    try localSet(w, 4);
    try localGet(w, 3);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 3);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 4);
    try localGet(w, 5);
    try op(w, .f64_div);
    return code.toOwnedSlice(allocator);
}

pub fn generateMatrixProdBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localGet(w, 1);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localSet(w, 2);
    try f64c(w, 1.0);
    try localSet(w, 4);
    try i32c(w, 0);
    try localSet(w, 3);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 4);
    try op(w, .f64_mul);
    try localSet(w, 4);
    try localGet(w, 3);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 3);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 4);
    return code.toOwnedSlice(allocator);
}

pub fn generateMatrixCountBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localGet(w, 1);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try op(w, .f64_convert_i32_s);
    return code.toOwnedSlice(allocator);
}

pub fn generateDotBody(allocator: std.mem.Allocator) ![]u8 {
    // dot of two vectors (Nx1 or 1xN matrices). Params 0=a, 1=b as f64 ptrs
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 2);
    try i32load(w, 0);
    try localGet(w, 2);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localSet(w, 4); // n
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_u);
    try localSet(w, 3); // b ptr
    try f64c(w, 0.0);
    try localSet(w, 6);
    try i32c(w, 0);
    try localSet(w, 5);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 5);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 3);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 5);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try op(w, .f64_mul);
    try localGet(w, 6);
    try op(w, .f64_add);
    try localSet(w, 6);
    try localGet(w, 5);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 5);
    try localGet(w, 4);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 6);
    return code.toOwnedSlice(allocator);
}

pub fn generateCrossBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    // 3-vector cross product → 3x1 matrix
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localSet(w, 2);
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_u);
    try localSet(w, 3);
    try i32c(w, 3 * 8 + 8);
    try localSet(w, 4);
    try emitBumpAlloc(w, heap_ptr_idx, 4, 5, 6);
    try localGet(w, 5);
    try i32c(w, 3);
    try i32store(w, 0);
    try localGet(w, 5);
    try i32c(w, 1);
    try i32store(w, 4);
    // ay*bz - az*by
    try localGet(w, 5);
    try localGet(w, 2);
    try f64load(w, 16); // ay
    try localGet(w, 3);
    try f64load(w, 24); // bz
    try op(w, .f64_mul);
    try localGet(w, 2);
    try f64load(w, 24);
    try localGet(w, 3);
    try f64load(w, 16);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try f64store(w, 8);
    // az*bx - ax*bz
    try localGet(w, 5);
    try localGet(w, 2);
    try f64load(w, 24);
    try localGet(w, 3);
    try f64load(w, 8);
    try op(w, .f64_mul);
    try localGet(w, 2);
    try f64load(w, 8);
    try localGet(w, 3);
    try f64load(w, 24);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try f64store(w, 16);
    // ax*by - ay*bx
    try localGet(w, 5);
    try localGet(w, 2);
    try f64load(w, 8);
    try localGet(w, 3);
    try f64load(w, 16);
    try op(w, .f64_mul);
    try localGet(w, 2);
    try f64load(w, 16);
    try localGet(w, 3);
    try f64load(w, 8);
    try op(w, .f64_mul);
    try op(w, .f64_sub);
    try f64store(w, 24);
    try localGet(w, 5);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

pub fn generateFlattenBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localGet(w, 1);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localTee(w, 2); // n
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 4);
    try emitBumpAlloc(w, heap_ptr_idx, 4, 3, 5);
    try localGet(w, 3);
    try localGet(w, 2);
    try i32store(w, 0); // rows = n
    try localGet(w, 3);
    try i32c(w, 1);
    try i32store(w, 4); // cols = 1
    try i32c(w, 0);
    try localSet(w, 6);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 6);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localSet(w, 7);
    try localGet(w, 3);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 6);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 7);
    try f64store(w, 0);
    try localGet(w, 6);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 6);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 3);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

pub fn generateDiagBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    // Extract diagonal as column vector
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2); // rows
    try localGet(w, 1);
    try i32load(w, 4);
    try localSet(w, 3); // cols
    // n = min(rows,cols)
    try localGet(w, 2);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.i32));
    try localGet(w, 2);
    try op(w, .else_op);
    try localGet(w, 3);
    try op(w, .end);
    try localSet(w, 4); // n
    try localGet(w, 4);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 5);
    try emitBumpAlloc(w, heap_ptr_idx, 5, 6, 7);
    try localGet(w, 6);
    try localGet(w, 4);
    try i32store(w, 0);
    try localGet(w, 6);
    try i32c(w, 1);
    try i32store(w, 4);
    try i32c(w, 0);
    try localSet(w, 8);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 8);
    try localGet(w, 3);
    try op(w, .i32_mul);
    try localGet(w, 8);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localSet(w, 9);
    try localGet(w, 6);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 9);
    try f64store(w, 0);
    try localGet(w, 8);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 8);
    try localGet(w, 4);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 6);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

pub fn generateReshapeBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    // reshape(m, rows, cols) — copy data with new dims
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localSet(w, 3); // src
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_s);
    try localSet(w, 4); // new rows
    try localGet(w, 2);
    try op(w, .i32_trunc_f64_s);
    try localSet(w, 5); // new cols
    try localGet(w, 4);
    try localGet(w, 5);
    try op(w, .i32_mul);
    try localTee(w, 6);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 7);
    try emitBumpAlloc(w, heap_ptr_idx, 7, 8, 9);
    try localGet(w, 8);
    try localGet(w, 4);
    try i32store(w, 0);
    try localGet(w, 8);
    try localGet(w, 5);
    try i32store(w, 4);
    try i32c(w, 0);
    try localSet(w, 10);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 3);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 10);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localSet(w, 11);
    try localGet(w, 8);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 10);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 11);
    try f64store(w, 0);
    try localGet(w, 10);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 10);
    try localGet(w, 6);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 8);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

pub fn generateGemvBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    // y = A * x, A is MxN, x is Nx1, result Mx1
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 2); // A
    try i32load(w, 0);
    try localSet(w, 3); // rows
    try localGet(w, 2);
    try i32load(w, 4);
    try localSet(w, 4); // cols
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_u);
    try localSet(w, 5); // x
    try localGet(w, 3);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 6);
    try emitBumpAlloc(w, heap_ptr_idx, 6, 7, 8);
    try localGet(w, 7);
    try localGet(w, 3);
    try i32store(w, 0);
    try localGet(w, 7);
    try i32c(w, 1);
    try i32store(w, 4);
    try i32c(w, 0);
    try localSet(w, 9); // i
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try f64c(w, 0.0);
    try localSet(w, 11); // sum
    try i32c(w, 0);
    try localSet(w, 10); // j
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 9);
    try localGet(w, 4);
    try op(w, .i32_mul);
    try localGet(w, 10);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 5);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 10);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try op(w, .f64_mul);
    try localGet(w, 11);
    try op(w, .f64_add);
    try localSet(w, 11);
    try localGet(w, 10);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 10);
    try localGet(w, 4);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 7);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 9);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 11);
    try f64store(w, 0);
    try localGet(w, 9);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 9);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 7);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

pub fn generateNormBody(allocator: std.mem.Allocator) ![]u8 {
    // L2 norm of matrix elements
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localGet(w, 1);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localSet(w, 2);
    try f64c(w, 0.0);
    try localSet(w, 4);
    try i32c(w, 0);
    try localSet(w, 3);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localTee(w, 5);
    try localGet(w, 5);
    try op(w, .f64_mul);
    try localGet(w, 4);
    try op(w, .f64_add);
    try localSet(w, 4);
    try localGet(w, 3);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 3);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 4);
    try op(w, .f64_sqrt);
    return code.toOwnedSlice(allocator);
}

// ── Tier 3: in-wasm ODE (static deriv → direct call) ───────────────────────
//
// Signature: (name_f64, y0_f64, tspan_f64, dt_f64) -> result_mat_f64
// `name` is ignored (caller specialized the body with `deriv_func_idx`).
// Op-for-op match of src/functions/ode.zig / host runOdeSolve:
//   steps = ceil((t_end-t_start)/dt)+1
//   result = steps × (1+dim), time column first; write row then step (no step on last).
// Scalar path (dim==1): call deriv(t, y0) -> f64
// Multi path: call deriv(t, y_mat_ptr) -> mat_ptr
//
// Locals after 4 f64 params (0..3):
//  i32: 4=y0, 5=dim, 6=tspan, 7=steps, 8=cols, 9=result, 10=size, 11=tmp,
//       12=step, 13=i, 14=y_work, 15=dy, 16=k2, 17=k3, 18=k4, 19=temp_y, 20=y_mat
//  f64: 21=t_start, 22=t_end, 23=t, 24=f_tmp, 25=f_tmp2

pub const OdeMethod = enum { euler, rk4 };

/// Locals list for generateOdeBody (pass to addCode).
pub const ode_locals = [_]types.ValType{
    // 4..20 i32
    .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32,
    .i32, .i32, .i32, .i32, .i32, .i32, .i32,
    // 21..25 f64
    .f64, .f64, .f64, .f64, .f64,
};

pub fn generateOdeBody(
    allocator: std.mem.Allocator,
    heap_ptr_idx: u32,
    deriv_func_idx: u32,
    method: OdeMethod,
) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    errdefer code.deinit(allocator);
    const w = list_writer.unmanagedByteWriter(&code, allocator);

    // y0 ptr, dim = rows*cols
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 4);
    try i32load(w, 0);
    try localGet(w, 4);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localSet(w, 5); // dim

    // t_start, t_end from tspan matrix (first and last element)
    try localGet(w, 2);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 6);
    try f64load(w, 8);
    try localSet(w, 21); // t_start
    try localGet(w, 6);
    try i32load(w, 0);
    try localGet(w, 6);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try i32c(w, 1);
    try op(w, .i32_sub); // n-1
    try i32c(w, 3);
    try op(w, .i32_shl);
    try localGet(w, 6);
    try i32c(w, 8);
    try op(w, .i32_add);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localSet(w, 22); // t_end

    // steps = ceil((t_end-t_start)/dt)+1
    try localGet(w, 22);
    try localGet(w, 21);
    try op(w, .f64_sub);
    try localGet(w, 3);
    try op(w, .f64_div);
    try op(w, .f64_ceil);
    try op(w, .i32_trunc_f64_s);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localSet(w, 7); // steps

    // cols = 1 + dim
    try localGet(w, 5);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localSet(w, 8);

    // result size = 8 + steps*cols*8
    try localGet(w, 7);
    try localGet(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 10);
    try emitBumpAlloc(w, heap_ptr_idx, 10, 9, 11); // result in 9
    try localGet(w, 9);
    try localGet(w, 7);
    try i32store(w, 0);
    try localGet(w, 9);
    try localGet(w, 8);
    try i32store(w, 4);

    // y_work = dim * 8
    try localGet(w, 5);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try localSet(w, 10);
    try emitBumpAlloc(w, heap_ptr_idx, 10, 14, 11);

    // dy / k1
    try localGet(w, 5);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try localSet(w, 10);
    try emitBumpAlloc(w, heap_ptr_idx, 10, 15, 11);

    if (method == .rk4) {
        // k2, k3, k4, temp_y
        inline for (.{ 16, 17, 18, 19 }) |loc| {
            try localGet(w, 5);
            try i32c(w, 3);
            try op(w, .i32_shl);
            try localSet(w, 10);
            try emitBumpAlloc(w, heap_ptr_idx, 10, loc, 11);
        }
    }

    // y_mat buffer for multi-dim: 8 + dim*8
    try localGet(w, 5);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 10);
    try emitBumpAlloc(w, heap_ptr_idx, 10, 20, 11);
    try localGet(w, 20);
    try localGet(w, 5);
    try i32store(w, 0); // rows = dim
    try localGet(w, 20);
    try i32c(w, 1);
    try i32store(w, 4); // cols = 1

    // copy y0 data -> y_work
    try i32c(w, 0);
    try localSet(w, 13);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 14);
    try localGet(w, 13);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 4);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 13);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    try localGet(w, 13);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 13);
    try localGet(w, 5);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);

    // t = t_start; step = 0
    try localGet(w, 21);
    try localSet(w, 23);
    try i32c(w, 0);
    try localSet(w, 12);

    // block { loop { ... br 1 exits block; br 0 continues loop } }
    // (branching to a loop label continues; need outer block to exit)
    try op(w, .block);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));

    // write result row: [t, y...]
    try localGet(w, 9);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 12);
    try localGet(w, 8);
    try op(w, .i32_mul);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localTee(w, 11); // row base
    try localGet(w, 23);
    try f64store(w, 0);
    try i32c(w, 0);
    try localSet(w, 13);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 11);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 13);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 14);
    try localGet(w, 13);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    try localGet(w, 13);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 13);
    try localGet(w, 5);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);

    // if step+1 == steps: br 2 → exit block (labels: if=0, loop=1, block=2)
    try localGet(w, 12);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localGet(w, 7);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try op(w, .br);
    _ = try leb.encodeUnsigned(w, 2); // exit outer block
    try op(w, .end);

    // --- step ---
    if (method == .euler) {
        try emitOdeCallDeriv(w, deriv_func_idx, 23, 14, 15, 5, 20, 13, 24);
        // y += dy * dt
        try i32c(w, 0);
        try localSet(w, 13);
        try op(w, .loop);
        try w.writeByte(@intFromEnum(types.ValType.void));
        try localGet(w, 14);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try localGet(w, 14);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
        try localGet(w, 15);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
        try localGet(w, 3);
        try op(w, .f64_mul);
        try op(w, .f64_add);
        try f64store(w, 0);
        try localGet(w, 13);
        try i32c(w, 1);
        try op(w, .i32_add);
        try localTee(w, 13);
        try localGet(w, 5);
        try op(w, .i32_lt_s);
        try op(w, .br_if);
        _ = try leb.encodeUnsigned(w, 0);
        try op(w, .end);
    } else {
        // k1 = f(t, y)
        try emitOdeCallDeriv(w, deriv_func_idx, 23, 14, 15, 5, 20, 13, 24);
        // temp_y = y + 0.5*dt*k1; k2 = f(t+0.5*dt, temp_y)
        try emitOdeAxpy(w, 14, 15, 19, 5, 13, 3, 0.5, 24);
        try localGet(w, 23);
        try localGet(w, 3);
        try f64c(w, 0.5);
        try op(w, .f64_mul);
        try op(w, .f64_add);
        try localSet(w, 24);
        try emitOdeCallDeriv(w, deriv_func_idx, 24, 19, 16, 5, 20, 13, 25);
        // temp_y = y + 0.5*dt*k2; k3 = f(t+0.5*dt, temp_y)
        try emitOdeAxpy(w, 14, 16, 19, 5, 13, 3, 0.5, 24);
        try localGet(w, 23);
        try localGet(w, 3);
        try f64c(w, 0.5);
        try op(w, .f64_mul);
        try op(w, .f64_add);
        try localSet(w, 24);
        try emitOdeCallDeriv(w, deriv_func_idx, 24, 19, 17, 5, 20, 13, 25);
        // temp_y = y + dt*k3; k4 = f(t+dt, temp_y)
        try emitOdeAxpy(w, 14, 17, 19, 5, 13, 3, 1.0, 24);
        try localGet(w, 23);
        try localGet(w, 3);
        try op(w, .f64_add);
        try localSet(w, 24);
        try emitOdeCallDeriv(w, deriv_func_idx, 24, 19, 18, 5, 20, 13, 25);
        // y += (dt/6)*(k1 + 2*k2 + 2*k3 + k4)
        try i32c(w, 0);
        try localSet(w, 13);
        try op(w, .loop);
        try w.writeByte(@intFromEnum(types.ValType.void));
        try localGet(w, 14);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try localGet(w, 14);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
        // k1
        try localGet(w, 15);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
        // 2*k2
        try localGet(w, 16);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
        try f64c(w, 2.0);
        try op(w, .f64_mul);
        try op(w, .f64_add);
        // 2*k3
        try localGet(w, 17);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
        try f64c(w, 2.0);
        try op(w, .f64_mul);
        try op(w, .f64_add);
        // k4
        try localGet(w, 18);
        try localGet(w, 13);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
        try op(w, .f64_add);
        // * (dt/6)
        try localGet(w, 3);
        try f64c(w, 6.0);
        try op(w, .f64_div);
        try op(w, .f64_mul);
        try op(w, .f64_add);
        try f64store(w, 0);
        try localGet(w, 13);
        try i32c(w, 1);
        try op(w, .i32_add);
        try localTee(w, 13);
        try localGet(w, 5);
        try op(w, .i32_lt_s);
        try op(w, .br_if);
        _ = try leb.encodeUnsigned(w, 0);
        try op(w, .end);
    }

    // t += dt; step++
    try localGet(w, 23);
    try localGet(w, 3);
    try op(w, .f64_add);
    try localSet(w, 23);
    try localGet(w, 12);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localSet(w, 12);
    try op(w, .br);
    _ = try leb.encodeUnsigned(w, 0); // continue loop
    try op(w, .end); // loop
    try op(w, .end); // block

    try localGet(w, 9);
    try op(w, .f64_convert_i32_u);
    return try code.toOwnedSlice(allocator);
}

/// out[i] = y[i] + scale * dt * k[i]
fn emitOdeAxpy(
    w: W,
    y_loc: u32,
    k_loc: u32,
    out_loc: u32,
    dim_loc: u32,
    i_loc: u32,
    dt_param: u32,
    scale: f64,
    tmp_f: u32,
) !void {
    _ = tmp_f;
    try i32c(w, 0);
    try localSet(w, i_loc);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, out_loc);
    try localGet(w, i_loc);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, y_loc);
    try localGet(w, i_loc);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, k_loc);
    try localGet(w, i_loc);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, dt_param);
    try op(w, .f64_mul);
    if (scale != 1.0) {
        try f64c(w, scale);
        try op(w, .f64_mul);
    }
    try op(w, .f64_add);
    try f64store(w, 0);
    try localGet(w, i_loc);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, i_loc);
    try localGet(w, dim_loc);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
}

/// Call deriv into out_buf (raw f64×dim). t_loc is f64 local with time.
/// y_work is raw state; y_mat is matrix buffer for multi-dim call.
fn emitOdeCallDeriv(
    w: W,
    deriv_func_idx: u32,
    t_loc: u32,
    y_work: u32,
    out_buf: u32,
    dim_loc: u32,
    y_mat: u32,
    i_loc: u32,
    tmp_f: u32,
) !void {
    // if dim == 1: scalar call
    try localGet(w, dim_loc);
    try i32c(w, 1);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, t_loc);
    try localGet(w, y_work);
    try f64load(w, 0);
    try call(w, deriv_func_idx);
    try localSet(w, tmp_f);
    try localGet(w, out_buf);
    try localGet(w, tmp_f);
    try f64store(w, 0);
    try op(w, .else_op);
    // multi: copy y_work -> y_mat data, call, copy result mat -> out_buf
    try i32c(w, 0);
    try localSet(w, i_loc);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, y_mat);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, i_loc);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, y_work);
    try localGet(w, i_loc);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    try localGet(w, i_loc);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, i_loc);
    try localGet(w, dim_loc);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, t_loc);
    try localGet(w, y_mat);
    try op(w, .f64_convert_i32_u);
    try call(w, deriv_func_idx);
    try op(w, .i32_trunc_f64_u);
    try localSet(w, i_loc); // result mat ptr (reuse loop local)
    // for j in 0..dim: out_buf[j] = load(result+8+j*8); use local 11 as loop counter
    try i32c(w, 0);
    try localSet(w, 11);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, out_buf);
    try localGet(w, 11);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, i_loc);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 11);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    try localGet(w, 11);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 11);
    try localGet(w, dim_loc);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try op(w, .end); // if dim==1
}

// ── Tier 4: series linear memory (SeriesLayout) ────────────────────────────
// ptr -> [u32 len][u32 pad][f64 ts×len][f64 vals×len]

/// series(ts_mat, vals_mat) or series(vals_mat) — 1 or 2 args.
/// 1-arg: timestamps = 0..n-1. Vectors only (rows==1 or cols==1).
pub fn generateSeriesCtorBody(allocator: std.mem.Allocator, heap_ptr_idx: u32, arg_count: u8) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // params: 0 = first mat, 1 = second mat (if 2-arg)
    // locals: i32  (start after params)
    const base: u32 = if (arg_count >= 2) 2 else 1;
    const vals_src = base + 0; // i32
    const len_l = base + 1;
    const dst = base + 2;
    const size_l = base + 3;
    const tmp = base + 4;
    const i_l = base + 5;
    const ts_src = base + 6; // only used for 2-arg
    const ftmp = base + 7;

    // Resolve values matrix and len
    if (arg_count >= 2) {
        try localGet(w, 1);
        try op(w, .i32_trunc_f64_u);
        try localSet(w, vals_src);
        try localGet(w, 0);
        try op(w, .i32_trunc_f64_u);
        try localSet(w, ts_src);
    } else {
        try localGet(w, 0);
        try op(w, .i32_trunc_f64_u);
        try localSet(w, vals_src);
    }
    // Vector-only: rows==0 or cols==0 or rows==1 or cols==1 (match VM isVector).
    // Non-vectors return NaN.
    try localGet(w, vals_src);
    try i32load(w, 0);
    try localTee(w, len_l); // rows
    try i32c(w, 1);
    try op(w, .i32_le_s); // rows <= 1
    try localGet(w, vals_src);
    try i32load(w, 4);
    try i32c(w, 1);
    try op(w, .i32_le_s); // cols <= 1
    try op(w, .i32_or);
    try op(w, .i32_eqz);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try f64c(w, std.math.nan(f64));
    try op(w, .else_op);

    try localGet(w, vals_src);
    try i32load(w, 0);
    try localGet(w, vals_src);
    try i32load(w, 4);
    try op(w, .i32_mul);
    try localSet(w, len_l);

    // total = 8 + 16*len
    try localGet(w, len_l);
    try i32c(w, 4);
    try op(w, .i32_shl); // *16
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, size_l);
    try emitBumpAlloc(w, heap_ptr_idx, size_l, dst, tmp);
    try localGet(w, dst);
    try localGet(w, len_l);
    try i32store(w, 0);
    try localGet(w, dst);
    try i32c(w, 0);
    try i32store(w, 4);

    // copy loop
    try i32c(w, 0);
    try localSet(w, i_l);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));

    // timestamps
    try localGet(w, dst);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, i_l);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    if (arg_count >= 2) {
        try localGet(w, ts_src);
        try i32c(w, 8);
        try op(w, .i32_add);
        try localGet(w, i_l);
        try i32c(w, 3);
        try op(w, .i32_shl);
        try op(w, .i32_add);
        try f64load(w, 0);
    } else {
        try localGet(w, i_l);
        try op(w, .f64_convert_i32_s);
    }
    try f64store(w, 0);

    // values at dst + 8 + 8*len + i*8
    try localGet(w, dst);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, len_l);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, i_l);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, vals_src);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, i_l);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);

    try localGet(w, i_l);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, i_l);
    try localGet(w, len_l);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);

    try localGet(w, dst);
    try op(w, .f64_convert_i32_u);
    try op(w, .end); // end vector-check if/else
    _ = ftmp;
    return code.toOwnedSlice(allocator);
}

/// series sum: sum values (skip NaN)
pub fn generateSeriesSumBody(allocator: std.mem.Allocator) ![]u8 {
    return generateSeriesReduceBody(allocator, .sum);
}
pub fn generateSeriesMeanBody(allocator: std.mem.Allocator) ![]u8 {
    return generateSeriesReduceBody(allocator, .mean);
}
pub fn generateSeriesCountBody(allocator: std.mem.Allocator) ![]u8 {
    return generateSeriesReduceBody(allocator, .count);
}

const SeriesReduce = enum { sum, mean, count };

fn generateSeriesReduceBody(allocator: std.mem.Allocator, kind: SeriesReduce) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // 0=ptr_f64, 1=src, 2=len, 3=i, 4=sum/acc f64, 5=count f64, 6=val f64
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2);
    try f64c(w, 0.0);
    try localSet(w, 4);
    try f64c(w, 0.0);
    try localSet(w, 5);
    try i32c(w, 0);
    try localSet(w, 3);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // val = load(src + 8 + 8*len + i*8)
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localTee(w, 6);
    // skip NaN: val == val
    try localGet(w, 6);
    try op(w, .f64_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    if (kind != .count) {
        try localGet(w, 4);
        try localGet(w, 6);
        try op(w, .f64_add);
        try localSet(w, 4);
    }
    try localGet(w, 5);
    try f64c(w, 1.0);
    try op(w, .f64_add);
    try localSet(w, 5);
    try op(w, .end);
    try localGet(w, 3);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 3);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    switch (kind) {
        .sum => try localGet(w, 4),
        .count => try localGet(w, 5),
        .mean => {
            try localGet(w, 5);
            try f64c(w, 0.0);
            try op(w, .f64_eq);
            try op(w, .if_op);
            try w.writeByte(@intFromEnum(types.ValType.f64));
            try f64c(w, std.math.nan(f64));
            try op(w, .else_op);
            try localGet(w, 4);
            try localGet(w, 5);
            try op(w, .f64_div);
            try op(w, .end);
        },
    }
    return code.toOwnedSlice(allocator);
}

/// last(matrix) -> last row as 1×cols matrix (ODE trajectory tails).
pub fn generateMatrixLastBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // 0=ptr; 1=src, 2=rows, 3=cols, 4=dst, 5=size, 6=tmp, 7=i
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2);
    try localGet(w, 1);
    try i32load(w, 4);
    try localSet(w, 3);
    // size = 8 + cols*8
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 5);
    try emitBumpAlloc(w, heap_ptr_idx, 5, 4, 6);
    try localGet(w, 4);
    try i32c(w, 1);
    try i32store(w, 0);
    try localGet(w, 4);
    try localGet(w, 3);
    try i32store(w, 4);
    // copy last row: src+8+(rows-1)*cols*8
    try i32c(w, 0);
    try localSet(w, 7);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 4);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 7);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 1);
    try op(w, .i32_sub);
    try localGet(w, 3);
    try op(w, .i32_mul);
    try localGet(w, 7);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    try localGet(w, 7);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 7);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 4);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

/// last(series) -> last value (number). Empty -> NaN.
pub fn generateSeriesLastBody(allocator: std.mem.Allocator) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // 0=ptr, 1=src, 2=len
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localTee(w, 2);
    try i32c(w, 0);
    try op(w, .i32_eq);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try f64c(w, std.math.nan(f64));
    try op(w, .else_op);
    // vals[len-1] at src+8+8*len+(len-1)*8 = src+8+8*len+8*len-8 = src + 16*len
    try localGet(w, 1);
    try localGet(w, 2);
    try i32c(w, 4);
    try op(w, .i32_shl); // 16*len
    try op(w, .i32_add);
    try f64load(w, 0);
    try op(w, .end);
    return code.toOwnedSlice(allocator);
}

/// head(s, n) / tail(s, n) — SeriesLayout out.
pub fn generateSeriesHeadTailBody(allocator: std.mem.Allocator, heap_ptr_idx: u32, is_tail: bool) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // 0=s, 1=n_f64; locals: 2=src, 3=len, 4=n, 5=out_len, 6=dst, 7=size, 8=tmp, 9=i, 10=start
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 2);
    try i32load(w, 0);
    try localSet(w, 3);
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_s);
    try localTee(w, 4);
    try i32c(w, 0);
    try op(w, .i32_lt_s);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try i32c(w, 0);
    try localSet(w, 4);
    try op(w, .end);
    // out_len = min(n, len)
    try localGet(w, 4);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.i32));
    try localGet(w, 4);
    try op(w, .else_op);
    try localGet(w, 3);
    try op(w, .end);
    try localSet(w, 5);
    if (is_tail) {
        try localGet(w, 3);
        try localGet(w, 5);
        try op(w, .i32_sub);
        try localSet(w, 10);
    } else {
        try i32c(w, 0);
        try localSet(w, 10);
    }
    try localGet(w, 5);
    try i32c(w, 4);
    try op(w, .i32_shl);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 7);
    try emitBumpAlloc(w, heap_ptr_idx, 7, 6, 8);
    try localGet(w, 6);
    try localGet(w, 5);
    try i32store(w, 0);
    try localGet(w, 6);
    try i32c(w, 0);
    try i32store(w, 4);
    try i32c(w, 0);
    try localSet(w, 9);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // ts
    try localGet(w, 6);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 9);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 10);
    try localGet(w, 9);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    // vals
    try localGet(w, 6);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 5);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 9);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 10);
    try localGet(w, 9);
    try op(w, .i32_add);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    try localGet(w, 9);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 9);
    try localGet(w, 5);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 6);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

/// cumsum(series) — same length, prefix sum of values.
pub fn generateSeriesCumsumBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // 0=s; 1=src, 2=len, 3=dst, 4=size, 5=tmp, 6=i, 7=acc f64, 8=val f64
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 1);
    try i32load(w, 0);
    try localSet(w, 2);
    try localGet(w, 2);
    try i32c(w, 4);
    try op(w, .i32_shl);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 4);
    try emitBumpAlloc(w, heap_ptr_idx, 4, 3, 5);
    try localGet(w, 3);
    try localGet(w, 2);
    try i32store(w, 0);
    try localGet(w, 3);
    try i32c(w, 0);
    try i32store(w, 4);
    try f64c(w, 0.0);
    try localSet(w, 7);
    try i32c(w, 0);
    try localSet(w, 6);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // copy ts
    try localGet(w, 3);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 6);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 6);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    // val
    try localGet(w, 1);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 6);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localTee(w, 8);
    try localGet(w, 8);
    try op(w, .f64_eq); // not NaN
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 7);
    try localGet(w, 8);
    try op(w, .f64_add);
    try localSet(w, 7);
    try op(w, .end);
    try localGet(w, 3);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 6);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 7);
    try f64store(w, 0);
    try localGet(w, 6);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 6);
    try localGet(w, 2);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 3);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

/// diff(s, period) — period defaults handled by caller (must pass period).
/// First `period` values are NaN; rest v[i]-v[i-period].
pub fn generateSeriesDiffBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // 0=s, 1=period_f; 2=src, 3=len, 4=period, 5=dst, 6=size, 7=tmp, 8=i
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 2);
    try i32load(w, 0);
    try localSet(w, 3);
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_s);
    try localSet(w, 4);
    try localGet(w, 3);
    try i32c(w, 4);
    try op(w, .i32_shl);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 6);
    try emitBumpAlloc(w, heap_ptr_idx, 6, 5, 7);
    try localGet(w, 5);
    try localGet(w, 3);
    try i32store(w, 0);
    try localGet(w, 5);
    try i32c(w, 0);
    try i32store(w, 4);
    try i32c(w, 0);
    try localSet(w, 8);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // copy ts
    try localGet(w, 5);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    // value
    try localGet(w, 5);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try localGet(w, 4);
    try op(w, .i32_lt_s);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try f64c(w, std.math.nan(f64));
    try op(w, .else_op);
    // v[i] - v[i-period]
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try localGet(w, 4);
    try op(w, .i32_sub);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try op(w, .f64_sub);
    try op(w, .end);
    try f64store(w, 0);
    try localGet(w, 8);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 8);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 5);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

/// rolling_mean(s, window) / sma(s, period) — same sample-window mean.
/// Values before window is full are NaN.
pub fn generateSeriesRollingMeanBody(allocator: std.mem.Allocator, heap_ptr_idx: u32) ![]u8 {
    var code = std.ArrayListUnmanaged(u8).empty;
    const w = list_writer.unmanagedByteWriter(&code, allocator);
    // 0=s, 1=win_f; 2=src, 3=len, 4=win, 5=dst, 6=size, 7=tmp, 8=i, 9=acc f64, 10=val
    try localGet(w, 0);
    try op(w, .i32_trunc_f64_u);
    try localTee(w, 2);
    try i32load(w, 0);
    try localSet(w, 3);
    try localGet(w, 1);
    try op(w, .i32_trunc_f64_s);
    try localSet(w, 4);
    try localGet(w, 3);
    try i32c(w, 4);
    try op(w, .i32_shl);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localSet(w, 6);
    try emitBumpAlloc(w, heap_ptr_idx, 6, 5, 7);
    try localGet(w, 5);
    try localGet(w, 3);
    try i32store(w, 0);
    try localGet(w, 5);
    try i32c(w, 0);
    try i32store(w, 4);
    try f64c(w, 0.0);
    try localSet(w, 9);
    try i32c(w, 0);
    try localSet(w, 8);
    try op(w, .loop);
    try w.writeByte(@intFromEnum(types.ValType.void));
    // ts copy
    try localGet(w, 5);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try f64store(w, 0);
    // add current val
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try localGet(w, 9);
    try op(w, .f64_add);
    try localSet(w, 9);
    // subtract val leaving window if i >= win
    try localGet(w, 8);
    try localGet(w, 4);
    try op(w, .i32_ge_s);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.void));
    try localGet(w, 9);
    try localGet(w, 2);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try localGet(w, 4);
    try op(w, .i32_sub);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try f64load(w, 0);
    try op(w, .f64_sub);
    try localSet(w, 9);
    try op(w, .end);
    // store mean or NaN
    try localGet(w, 5);
    try i32c(w, 8);
    try op(w, .i32_add);
    try localGet(w, 3);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 3);
    try op(w, .i32_shl);
    try op(w, .i32_add);
    try localGet(w, 8);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localGet(w, 4);
    try op(w, .i32_ge_s);
    try op(w, .if_op);
    try w.writeByte(@intFromEnum(types.ValType.f64));
    try localGet(w, 9);
    try localGet(w, 4);
    try op(w, .f64_convert_i32_s);
    try op(w, .f64_div);
    try op(w, .else_op);
    try f64c(w, std.math.nan(f64));
    try op(w, .end);
    try f64store(w, 0);
    try localGet(w, 8);
    try i32c(w, 1);
    try op(w, .i32_add);
    try localTee(w, 8);
    try localGet(w, 3);
    try op(w, .i32_lt_s);
    try op(w, .br_if);
    _ = try leb.encodeUnsigned(w, 0);
    try op(w, .end);
    try localGet(w, 5);
    try op(w, .f64_convert_i32_u);
    return code.toOwnedSlice(allocator);
}

// ── unit tests: pure Zig poly vs native ────────────────────────────────────

test "refExp matches native across sweep" {
    const sweep = [_]f64{ 0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 10.0, -10.0, 0.1, -0.1, 20.0, -20.0 };
    for (sweep) |x| {
        const got = refExp(x);
        const want = @exp(x);
        if (std.math.isInf(want)) {
            try std.testing.expect(std.math.isInf(got));
            continue;
        }
        const err = @abs(got - want);
        const tol = 1e-10 * @max(1.0, @abs(want));
        try std.testing.expect(err <= tol);
    }
}

test "refLog matches native across sweep" {
    const sweep = [_]f64{ 1.0, 2.0, 0.5, 10.0, 0.1, std.math.e, 100.0, 1e-6, 1e6 };
    for (sweep) |x| {
        const got = refLog(x);
        const want = @log(x);
        const err = @abs(got - want);
        const tol = 1e-10 * @max(1.0, @abs(want));
        try std.testing.expect(err <= tol);
    }
}

test "refSin matches native across sweep" {
    const sweep = [_]f64{ 0.0, 0.5, 1.0, -1.0, PI / 2.0, PI / 4.0, -PI / 4.0, PI, -PI, 2.0 * PI, 3.5, -3.5, 10.0, -10.0 };
    for (sweep) |x| {
        const got = refSin(x);
        const want = @sin(x);
        const err = @abs(got - want);
        try std.testing.expect(err <= 1e-10);
    }
}

test "refCos matches native across sweep" {
    const sweep = [_]f64{ 0.0, 0.5, 1.0, PI, PI / 2.0, -PI / 3.0, 2.5, -2.5 };
    for (sweep) |x| {
        const got = refCos(x);
        const want = @cos(x);
        try std.testing.expect(@abs(got - want) <= 1e-10);
    }
}

test "refAtan matches native across sweep" {
    const sweep = [_]f64{ 0.0, 1.0, -1.0, 0.5, 2.0, -2.0, 10.0, -10.0, 100.0 };
    for (sweep) |x| {
        const got = refAtan(x);
        const want = std.math.atan(x);
        try std.testing.expect(@abs(got - want) <= 1e-8);
    }
}

test "edge cases: nan/inf/zero for refExp/refLog" {
    try std.testing.expect(std.math.isNan(refLog(-1.0)));
    try std.testing.expect(std.math.isInf(refExp(1000.0)));
    try std.testing.expect(refExp(-1000.0) == 0.0);
    try std.testing.expect(refSin(0.0) == 0.0);
}
