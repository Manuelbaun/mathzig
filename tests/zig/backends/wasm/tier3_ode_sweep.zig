//! task-19 P3 — Tier 3 in-wasm ODE: native euler / RK4 edge sweeps via MathZig VM.
//!
//! ULP notes:
//! - Euler is O(dt); looser abs tol vs closed form.
//! - RK4 tighter (~1e-6 with moderate steps).
//! - Use **scalar** y0 form (`ode_solve(name, 1, tspan, dt)`) — vector `[1]` path
//!   is a multi-dim layout; scalar matches closed-form y'=−ky tests.
//! - Degenerate span / NaN IC must not abort.

const std = @import("std");
const math = std.math;
const mathzig = @import("mathzig");
const MathZig = mathzig.MathZig;

/// Final y from a trajectory matrix with columns [t, y, …] (or last element if 1-col).
fn finalY(ctx: *MathZig, expr: []const u8) !f64 {
    const v = try ctx.eval(expr);
    defer v.release();
    return switch (v.tag) {
        .number => v.data.number,
        .matrix => blk: {
            const m = v.data.matrix;
            if (m.rows * m.cols == 0) break :blk math.nan(f64);
            // Prefer last row, second column (t,y layout) when cols >= 2.
            if (m.cols >= 2) {
                break :blk m.get(m.rows - 1, 1);
            }
            break :blk m.data[m.rows * m.cols - 1];
        },
        else => error.UnexpectedTag,
    };
}

test "tier3: RK4 exponential decay matches closed form within tol" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // Combined def+call; scalar y0.
    const got = try finalY(ctx, "decay(t, y) = -0.5 * y; ode_solve(\"decay\", 1, [0, 1.0], 0.05)");
    const want = @exp(-0.5);
    try std.testing.expect(@abs(got - want) < 1e-5);
}

test "tier3: Euler decay is first-order accurate" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const got = try finalY(ctx, "decay_e(t, y) = -0.5 * y; ode_solve_euler(\"decay_e\", 1, [0, 1.0], 0.05)");
    const want = @exp(-0.5);
    try std.testing.expect(@abs(got - want) < 5e-2);
}

test "tier3: zero-length span does not crash" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const v = ctx.eval("f0(t, y) = 0; ode_solve(\"f0\", 1, [0, 0], 0.1)");
    if (v) |val| {
        val.release();
    } else |_| {}
}

test "tier3: NaN initial condition stays non-finite" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const got = finalY(ctx, "f1(t, y) = -y; ode_solve(\"f1\", nan, [0, 0.5], 0.1)") catch math.nan(f64);
    try std.testing.expect(!math.isFinite(got) or math.isNan(got));
}

test "tier3: multi-dim IC column vector runs" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    // 3D cyclic system from parity vector_ode.json
    const v = try ctx.eval("simple3d(t, y) = [y[1]; y[2]; y[0]]; ode_solve(\"simple3d\", [1; 2; 3], [0, 1], 0.1)");
    defer v.release();
    try std.testing.expect(v.tag == .matrix);
    try std.testing.expect(v.data.matrix.rows > 0);
}

test "tier3: large step count remains finite for stable system" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const got = try finalY(ctx, "stable(t, y) = -y; ode_solve(\"stable\", 1, [0, 2.0], 0.01)");
    try std.testing.expect(math.isFinite(got));
    try std.testing.expect(@abs(got - @exp(-2.0)) < 1e-4);
}

test "tier3: ±inf IC does not crash" {
    const allocator = std.testing.allocator;
    var ctx = try MathZig.init(allocator);
    defer ctx.deinit();

    const v = ctx.eval("fi(t, y) = 0; ode_solve(\"fi\", inf, [0, 0.2], 0.1)");
    if (v) |val| {
        val.release();
    } else |_| {}
}
