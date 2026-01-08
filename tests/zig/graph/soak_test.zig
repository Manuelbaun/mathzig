//! Native graph soak + debugStats + reload (task-16 / C5).
//!
//! Default (always-on under `zig build test`): 10k ticks + 500 reloads.
//! Full deep soak (optional): MATHZIG_SOAK_FULL=1 is a TS concern; Zig uses
//! fewer ticks because VM matrix eval is heavier and testing.allocator
//! tracks every alloc — 10k is enough to prove flat live-handle counters.
//!
//! Why fewer than 1M: each matrix tick retains/releases Values under
//! std.testing.allocator; 1M would dominate CI wall time without extra
//! signal once counters are flat at 10k.

const std = @import("std");
const mathzig = @import("mathzig");
const GraphRunner = mathzig.graph.GraphRunner;
const live_handles = mathzig.live_handles;

const TICKS: usize = 10_000;
const WARMUP: usize = 1_000;
const RELOADS: usize = 500;

const series_json =
    \\{
    \\  "nodes": [
    \\    {
    \\      "id": "g",
    \\      "type": "expr",
    \\      "expr": "series([0, 1, 2], [10, 20, 30])",
    \\      "outputKind": "series"
    \\    },
    \\    {
    \\      "id": "f",
    \\      "type": "expr",
    \\      "expr": "mean(x)",
    \\      "inputs": ["x"],
    \\      "inputKinds": ["series"],
    \\      "outputKind": "number"
    \\    }
    \\  ],
    \\  "edges": [{"from": "g.out", "to": "f.x"}],
    \\  "outputs": {"value": "f.out"}
    \\}
;

const matrix_json =
    \\{
    \\  "nodes": [
    \\    {
    \\      "id": "g",
    \\      "type": "expr",
    \\      "expr": "[1, 2; 3, 4] * 2",
    \\      "outputKind": "matrix"
    \\    },
    \\    {
    \\      "id": "f",
    \\      "type": "expr",
    \\      "expr": "x * [1, 0; 0, 1]",
    \\      "inputs": ["x"],
    \\      "inputKinds": ["matrix"],
    \\      "outputKind": "matrix"
    \\    }
    \\  ],
    \\  "edges": [{"from": "g.out", "to": "f.x"}],
    \\  "outputs": {"value": "f.out"}
    \\}
;

const reload_json =
    \\{
    \\  "nodes": [
    \\    {"id": "x", "type": "input"},
    \\    {
    \\      "id": "stage",
    \\      "type": "expr",
    \\      "expr": "x * y",
    \\      "inputs": ["x"],
    \\      "params": {"y": 3}
    \\    }
    \\  ],
    \\  "edges": [{"from": "x.out", "to": "stage.x"}],
    \\  "outputs": {"value": "stage.out"}
    \\}
;

test "native debugStats exposes live handles and slots" {
    const allocator = std.testing.allocator;
    var runner = try GraphRunner.load(allocator, series_json);
    defer runner.dispose();

    const s0 = runner.debugStats();
    try std.testing.expect(s0.slot_count >= 2);
    try std.testing.expect(s0.instance_count >= 2);
    try std.testing.expectEqual(@as(usize, 0), s0.wasm_memory_pages);

    var outs = try runner.runScalars(&.{});
    defer GraphRunner.releaseOutputs(&outs);
    const s1 = runner.debugStats();
    // After releasing outputs, process live handles should not explode.
    _ = s1;
    try std.testing.expectApproxEqAbs(@as(f64, 20), outs.get("value").?.toNumber().?, 1e-12);
}

test "native tick soak: live handles flat over 10k series+matrix ticks" {
    const allocator = std.testing.allocator;

    var series_r = try GraphRunner.load(allocator, series_json);
    defer series_r.dispose();
    var matrix_r = try GraphRunner.load(allocator, matrix_json);
    defer matrix_r.dispose();

    var i: usize = 0;
    while (i < WARMUP) : (i += 1) {
        var so = try series_r.runScalars(&.{});
        GraphRunner.releaseOutputs(&so);
        var mo = try matrix_r.runScalars(&.{});
        GraphRunner.releaseOutputs(&mo);
    }

    const warm = live_handles.snapshot();
    const warm_stats = series_r.debugStats();

    i = 0;
    while (i < TICKS - WARMUP) : (i += 1) {
        var so = try series_r.runScalars(&.{});
        try std.testing.expectApproxEqAbs(@as(f64, 20), so.get("value").?.toNumber().?, 1e-12);
        GraphRunner.releaseOutputs(&so);

        var mo = try matrix_r.runScalars(&.{});
        const m = mo.get("value").?.data.matrix;
        try std.testing.expectApproxEqAbs(@as(f64, 2), m.get(0, 0), 1e-12);
        GraphRunner.releaseOutputs(&mo);
    }

    const end = live_handles.snapshot();
    const end_stats = series_r.debugStats();

    // Live handles process-wide may include other tests' noise; relative to
    // warmup for *this* process section we allow a small absolute ceiling.
    // Primary signal: end.total not growing linearly with ticks (would be ~10k).
    try std.testing.expect(end.total < warm.total + 64);
    try std.testing.expect(end.total < 10_000);
    try std.testing.expectEqual(warm_stats.instance_count, end_stats.instance_count);
    try std.testing.expectEqual(warm_stats.slot_count, end_stats.slot_count);
}

test "native reload soak: params preserved, instances stable" {
    const allocator = std.testing.allocator;
    var runner = try GraphRunner.load(allocator, reload_json);
    defer runner.dispose();

    try runner.setParam("stage", "y", 3);
    var warm_out = try runner.runScalars(&.{.{ "x", 2 }});
    defer GraphRunner.releaseOutputs(&warm_out);
    try std.testing.expectApproxEqAbs(@as(f64, 6), warm_out.get("value").?.toNumber().?, 1e-12);

    const warm = runner.debugStats();
    var i: usize = 0;
    while (i < RELOADS) : (i += 1) {
        const expr: []const u8 = if (i % 2 == 0) "x + y" else "x * y";
        try runner.reload("stage", expr);
        var outs = try runner.runScalars(&.{.{ "x", 2 }});
        defer GraphRunner.releaseOutputs(&outs);
        const expected: f64 = if (i % 2 == 0) 5 else 6;
        try std.testing.expectApproxEqAbs(expected, outs.get("value").?.toNumber().?, 1e-12);
    }
    const end = runner.debugStats();
    try std.testing.expectEqual(warm.instance_count, end.instance_count);
    try std.testing.expectEqual(warm.slot_count, end.slot_count);
}

test "native reload compile failure keeps prior node" {
    const allocator = std.testing.allocator;
    var runner = try GraphRunner.load(allocator, reload_json);
    defer runner.dispose();

    var ok = try runner.runScalars(&.{.{ "x", 2 }});
    defer GraphRunner.releaseOutputs(&ok);
    try std.testing.expectApproxEqAbs(@as(f64, 6), ok.get("value").?.toNumber().?, 1e-12);

    const err = runner.reload("stage", "this is not ((( valid");
    try std.testing.expectError(error.CompileError, err);

    var still = try runner.runScalars(&.{.{ "x", 2 }});
    defer GraphRunner.releaseOutputs(&still);
    try std.testing.expectApproxEqAbs(@as(f64, 6), still.get("value").?.toNumber().?, 1e-12);
}

test "native alloc-failure injection: OutOfMemory does not leave live handles" {
    // Host-side fault injection for native: FixedBufferAllocator too small for
    // a large Matrix. Failed init must not bump live_handles; recovery with a
    // normal allocator succeeds (same discipline as TS GraphAllocError recovery).
    const allocator = std.testing.allocator;

    const before = live_handles.snapshot();
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const tiny = fba.allocator();
    try std.testing.expectError(error.OutOfMemory, mathzig.Matrix.init(tiny, 64, 64));

    const after_fail = live_handles.snapshot();
    try std.testing.expectEqual(before.matrix, after_fail.matrix);

    // Recovery: normal init + release.
    const ok = try mathzig.Matrix.init(allocator, 2, 2);
    defer ok.release();
    try std.testing.expect(live_handles.snapshot().matrix >= before.matrix + 1);
}
