//! task-19 P3 — Tier 4 series: native Series ops edge sweep via mathzig.timeseries.
//!
//! ULP notes: aggregations are direct f64 sums. mean(empty) → NaN. NaN skipped in sum.

const std = @import("std");
const math = std.math;
const mathzig = @import("mathzig");
const Series = mathzig.timeseries.Series;
const agg_sum = mathzig.timeseries.sum;
const agg_mean = mathzig.timeseries.mean;
const agg_count = mathzig.timeseries.count;
const agg_cumsum = mathzig.timeseries.cumsum;
const calc_diff = mathzig.timeseries.diff;

fn makeSeries(allocator: std.mem.Allocator, ts: []const f64, vals: []const f64) !*Series {
    std.debug.assert(ts.len == vals.len);
    const s = try Series.init(allocator, ts.len, .Linear, .{});
    for (ts, 0..) |t, i| {
        s.timestamps[i] = t;
        s.values[i] = vals[i];
        s.validity[i] = 1;
    }
    if (ts.len > 0) {
        s.min_ts = ts[0];
        s.max_ts = ts[ts.len - 1];
        s.is_sorted = true;
    }
    return s;
}

test "tier4: empty series sum/mean/count" {
    const allocator = std.testing.allocator;
    const s = try Series.init(allocator, 0, .Linear, .{});
    defer s.deinit();

    try std.testing.expectEqual(@as(f64, 0.0), agg_sum(s, null));
    try std.testing.expectEqual(@as(f64, 0.0), agg_count(s, null));
    try std.testing.expect(math.isNan(agg_mean(s, null)));
}

test "tier4: single sample and signed zero" {
    const allocator = std.testing.allocator;
    const s = try makeSeries(allocator, &[_]f64{0.0}, &[_]f64{-0.0});
    defer s.deinit();

    try std.testing.expectEqual(@as(f64, 1.0), agg_count(s, null));
    try std.testing.expect(agg_sum(s, null) == 0.0);
    try std.testing.expect(agg_mean(s, null) == 0.0);
}

test "tier4: NaN skipped in sum; validity edges" {
    const allocator = std.testing.allocator;
    const s = try makeSeries(allocator, &[_]f64{ 0, 1, 2 }, &[_]f64{ 10, math.nan(f64), 30 });
    defer s.deinit();

    const sm = agg_sum(s, null);
    try std.testing.expect(@abs(sm - 40.0) < 1e-12);

    s.validity[0] = 0;
    const sm2 = agg_sum(s, null);
    try std.testing.expect(@abs(sm2 - 30.0) < 1e-12);
}

test "tier4: ±inf and large magnitudes" {
    const allocator = std.testing.allocator;
    const s = try makeSeries(allocator, &[_]f64{ 0, 1 }, &[_]f64{ math.inf(f64), 1.0 });
    defer s.deinit();
    try std.testing.expect(math.isInf(agg_sum(s, null)));

    const s2 = try makeSeries(allocator, &[_]f64{ 0, 1 }, &[_]f64{ 1e200, -1e200 });
    defer s2.deinit();
    const sm = agg_sum(s2, null);
    try std.testing.expect(math.isFinite(sm) or math.isNan(sm));
}

test "tier4: denormals and cumsum/diff lengths" {
    const allocator = std.testing.allocator;
    const s = try makeSeries(
        allocator,
        &[_]f64{ 0, 1, 2 },
        &[_]f64{ math.floatMin(f64), math.floatMin(f64), 1.0 },
    );
    defer s.deinit();

    const cs = try agg_cumsum(s, allocator);
    defer cs.deinit();
    try std.testing.expectEqual(@as(usize, 3), cs.len);

    const d = try calc_diff(s, 1, allocator);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.len);
}

test "tier4: empty cumsum / diff stay empty" {
    const allocator = std.testing.allocator;
    const s = try Series.init(allocator, 0, .Linear, .{});
    defer s.deinit();

    const cs = try agg_cumsum(s, allocator);
    defer cs.deinit();
    try std.testing.expectEqual(@as(usize, 0), cs.len);

    const d = try calc_diff(s, 1, allocator);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.len);
}
