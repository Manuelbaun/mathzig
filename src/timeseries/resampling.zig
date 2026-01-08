const std = @import("std");
const Series = @import("series.zig").Series;
const threading = @import("../core/threading.zig");

const is_wasm = threading.is_wasm;

pub const AggKernel = enum {
    first,
    last,
    min,
    max,
    sum,
    mean,
    count,
};

pub const ResampleOptions = struct {
    interval: f64,
    kernel: AggKernel = .mean,
    origin: f64 = 0,
};

pub fn resample(series: *const Series, options: ResampleOptions, allocator: std.mem.Allocator) !*Series {
    if (series.len == 0) return Series.init(allocator, 0, .Linear, series.dimensions);

    if (options.interval <= 0) {
        return error.InvalidArgument;
    }

    const start = @floor((series.min_ts - options.origin) / options.interval) * options.interval + options.origin;
    const end = series.max_ts;
    const num_buckets = @as(usize, @intFromFloat(@ceil((end - start + 0.000001) / options.interval)));

    const result = try Series.init(allocator, num_buckets, .Linear, series.dimensions);

    var bucket_values = std.ArrayListUnmanaged(f64).empty;
    defer bucket_values.deinit(allocator);

    var current_bucket_idx: usize = 0;
    var current_bucket_start = start;

    // Initialize result
    for (0..num_buckets) |i| {
        result.timestamps[i] = start + @as(f64, @floatFromInt(i)) * options.interval;
        result.validity[i] = 0;
        result.values[i] = std.math.nan(f64);
    }

    for (0..series.len) |i| {
        const ts = series.timestamps[i];

        while (ts >= current_bucket_start + options.interval) {
            // Finalize current bucket
            if (bucket_values.items.len > 0) {
                result.values[current_bucket_idx] = aggregate(bucket_values.items, options.kernel);
                result.validity[current_bucket_idx] = 1;
                bucket_values.clearRetainingCapacity();
            }
            current_bucket_idx += 1;
            current_bucket_start += options.interval;
            if (current_bucket_idx >= num_buckets) break;
        }

        if (current_bucket_idx < num_buckets) {
            try bucket_values.append(allocator, series.values[i]);
        }
    }

    // Finalize last bucket
    if (bucket_values.items.len > 0 and current_bucket_idx < num_buckets) {
        result.values[current_bucket_idx] = aggregate(bucket_values.items, options.kernel);
        result.validity[current_bucket_idx] = 1;
    }

    try result.validate();
    return result;
}

pub fn parResample(series: *const Series, options: ResampleOptions, pool: *threading.Pool, allocator: std.mem.Allocator) !*Series {
    if (comptime is_wasm) return resample(series, options, allocator);

    if (series.len == 0) return Series.init(allocator, 0, .Linear, series.dimensions);
    if (options.interval <= 0) return error.InvalidArgument;

    const min_ts = if (series.len > 0) series.timestamps[0] else 0;
    const max_ts = if (series.len > 0) series.timestamps[series.len - 1] else 0;
    
    const start_ts = @floor((min_ts - options.origin) / options.interval) * options.interval + options.origin;
    const end_ts = max_ts;
    
    threading.debugPrint("Resample: min_ts={d}, max_ts={d}, start_ts={d}, end_ts={d}, interval={d}\n", .{ min_ts, max_ts, start_ts, end_ts, options.interval });

    if (end_ts < start_ts or series.len == 0) {
        return Series.init(allocator, 1, .Linear, series.dimensions);
    }
    
    const diff = end_ts - start_ts;
    const num_buckets_f = @ceil((diff + 0.000001) / options.interval);
    
    if (num_buckets_f > 100_000_000) return error.InvalidArgument; // Prevent huge allocations
    
    const num_buckets = @max(1, @as(usize, @intFromFloat(num_buckets_f)));

    const result = try Series.init(allocator, num_buckets, .Linear, series.dimensions);

    // Initialize timestamps in the main thread so workers can use them
    for (0..num_buckets) |k| {
        result.timestamps[k] = start_ts + @as(f64, @floatFromInt(k)) * options.interval;
    }

    const num_threads = threading.getCpuCount();
    const chunk_size = (num_buckets + num_threads - 1) / num_threads;
    
    var wg = threading.WaitGroup{};
    
    var i: usize = 0;
    while (i < num_buckets) : (i += chunk_size) {
        const chunk_end = @min(i + chunk_size, num_buckets);
        wg.start();
        threading.spawn(pool, struct {
            fn run(w: *threading.WaitGroup, s: *const Series, opts: ResampleOptions, res: *Series, start_idx: usize, end_idx: usize) void {
                defer w.finish();
                
                const b_start_ts = res.timestamps[start_idx];
                
                // Find initial source_idx for this chunk
                var source_idx: usize = 0;
                while (source_idx < s.len and s.timestamps[source_idx] < b_start_ts) {
                    source_idx += 1;
                }

                for (start_idx..end_idx) |j| {
                    const bucket_start = res.timestamps[j];
                    const bucket_end = bucket_start + opts.interval;
                    
                    // Initialize bucket timestamps (already done in main loop but for safety)
                    res.timestamps[j] = bucket_start;

                    var count: usize = 0;
                    var acc: f64 = switch (opts.kernel) {
                        .min => std.math.inf(f64),
                        .max => -std.math.inf(f64),
                        else => 0,
                    };

                    while (source_idx < s.len and s.timestamps[source_idx] < bucket_end) {
                        const val = s.values[source_idx];
                        if (s.validity[source_idx] != 0 and !std.math.isNan(val)) {
                            switch (opts.kernel) {
                                .first => if (count == 0) { acc = val; },
                                .last => acc = val,
                                .min => if (val < acc) { acc = val; },
                                .max => if (val > acc) { acc = val; },
                                .sum, .mean => acc += val,
                                .count => acc += 1,
                            }
                            count += 1;
                        }
                        source_idx += 1;
                    }

                    if (count > 0) {
                        res.values[j] = if (opts.kernel == .mean) acc / @as(f64, @floatFromInt(count)) else acc;
                        res.validity[j] = 1;
                    } else {
                        res.values[j] = std.math.nan(f64);
                        res.validity[j] = 0;
                    }
                }
            }
        }.run, .{ &wg, series, options, result, i, chunk_end }) catch {
            wg.finish();
            // Fallback: synchronous execution for this chunk
            // (Similar logic as above but directly)
            const b_start_ts = start_ts + @as(f64, @floatFromInt(i)) * options.interval;
            var source_idx: usize = 0;
            while (source_idx < series.len and series.timestamps[source_idx] < b_start_ts) {
                source_idx += 1;
            }
            for (i..chunk_end) |j| {
                const bucket_start = start_ts + @as(f64, @floatFromInt(j)) * options.interval;
                const bucket_end = bucket_start + options.interval;
                result.timestamps[j] = bucket_start;
                var count: usize = 0;
                var acc: f64 = switch (options.kernel) {
                    .min => std.math.inf(f64),
                    .max => -std.math.inf(f64),
                    else => 0,
                };
                while (source_idx < series.len and series.timestamps[source_idx] < bucket_end) {
                    const val = series.values[source_idx];
                    if (series.validity[source_idx] != 0 and !std.math.isNan(val)) {
                        switch (options.kernel) {
                            .first => if (count == 0) { acc = val; },
                            .last => acc = val,
                            .min => if (val < acc) { acc = val; },
                            .max => if (val > acc) { acc = val; },
                            .sum, .mean => acc += val,
                            .count => acc += 1,
                        }
                        count += 1;
                    }
                    source_idx += 1;
                }
                if (count > 0) {
                    result.values[j] = if (options.kernel == .mean) acc / @as(f64, @floatFromInt(count)) else acc;
                    result.validity[j] = 1;
                } else {
                    result.values[j] = std.math.nan(f64);
                    result.validity[j] = 0;
                }
            }
        };
    }
    
    wg.wait();
    try result.validate();
    return result;
}

fn aggregate(values: []const f64, kernel: AggKernel) f64 {
    if (values.len == 0) return std.math.nan(f64);
    return switch (kernel) {
        .first => values[0],
        .last => values[values.len - 1],
        .min => blk: {
            var m = values[0];
            for (values[1..]) |v| if (v < m) {
                m = v;
            };
            break :blk m;
        },
        .max => blk: {
            var m = values[0];
            for (values[1..]) |v| if (v > m) {
                m = v;
            };
            break :blk m;
        },
        .sum => blk: {
            var s: f64 = 0;
            for (values) |v| s += v;
            break :blk s;
        },
        .mean => blk: {
            var s: f64 = 0;
            for (values) |v| s += v;
            break :blk s / @as(f64, @floatFromInt(values.len));
        },
        .count => @as(f64, @floatFromInt(values.len)),
    };
}

test "Basic resampling" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 10, .Linear, .{});
    defer series.deinit();

    // 0 to 9, values 0 to 9
    for (0..10) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @as(f64, @floatFromInt(i));
    }
    try series.validate();

    // Resample to 5.0 interval. Buckets: [0, 5), [5, 10)
    // Bucket 0: 0, 1, 2, 3, 4 -> mean = 2.0
    // Bucket 1: 5, 6, 7, 8, 9 -> mean = 7.0
    const res = try resample(series, .{ .interval = 5.0, .kernel = .mean }, allocator);
    defer res.deinit();

    try std.testing.expectEqual(@as(usize, 2), res.len);
    try std.testing.expectEqual(@as(f64, 0.0), res.timestamps[0]);
    try std.testing.expectEqual(@as(f64, 5.0), res.timestamps[1]);
    try std.testing.expectEqual(@as(f64, 2.0), res.values[0]);
    try std.testing.expectEqual(@as(f64, 7.0), res.values[1]);
}

test "Parallel resampling correctness" {
    if (comptime is_wasm) return;
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 1000, .Linear, .{});
    defer series.deinit();
    for (0..1000) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = @floatFromInt(i);
    }
    
    var pool: threading.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = 4 });
    defer pool.deinit();

    // Resample to 100.0 interval. 10 buckets.
    const res = try parResample(series, .{ .interval = 100.0, .kernel = .mean }, &pool, allocator);
    defer res.deinit();

    try std.testing.expectEqual(@as(usize, 10), res.len);
    for (0..10) |i| {
        try std.testing.expectApproxEqAbs(@as(f64, @as(f64, @floatFromInt(i)) * 100.0), res.timestamps[i], 0.01);
        // Each bucket has 100 values. e.g. [0, 100) -> mean 49.5
        const expected_mean = @as(f64, @floatFromInt(i)) * 100.0 + 49.5;
        try std.testing.expectEqual(expected_mean, res.values[i]);
    }
}

test "Resampling: different modes" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 4, .Linear, .{});
    defer series.deinit();

    series.timestamps[0] = 0;
    series.timestamps[1] = 1;
    series.timestamps[2] = 2;
    series.timestamps[3] = 3;
    series.values[0] = 10;
    series.values[1] = 20;
    series.values[2] = 30;
    series.values[3] = 40;
    try series.validate();

    // Sum resample (Cumulative-like)
    const res_sum = try resample(series, .{ .interval = 2.0, .kernel = .sum }, allocator);
    defer res_sum.deinit();
    // [0, 2): 10, 20 -> 30
    // [2, 4): 30, 40 -> 70
    try std.testing.expectEqual(@as(f64, 30.0), res_sum.values[0]);
    try std.testing.expectEqual(@as(f64, 70.0), res_sum.values[1]);

    // Max resample
    const res_max = try resample(series, .{ .interval = 2.0, .kernel = .max }, allocator);
    defer res_max.deinit();
    try std.testing.expectEqual(@as(f64, 20.0), res_max.values[0]);
    try std.testing.expectEqual(@as(f64, 40.0), res_max.values[1]);
}

test "Resampling: irregular intervals" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 3, .Linear, .{});
    defer series.deinit();

    series.timestamps[0] = 0;
    series.timestamps[1] = 10;
    series.timestamps[2] = 11;
    series.values[0] = 100;
    series.values[1] = 200;
    series.values[2] = 300;
    try series.validate();

    // Resample to 5.0 interval
    // [0, 5): 100 -> mean 100
    // [5, 10): empty -> NaN (or fill mode)
    // [10, 15): 200, 300 -> mean 250
    const res = try resample(series, .{ .interval = 5.0, .kernel = .mean }, allocator);
    defer res.deinit();

    try std.testing.expectEqual(@as(usize, 3), res.len);
    try std.testing.expectEqual(@as(f64, 100.0), res.values[0]);
    try std.testing.expect(std.math.isNan(res.values[1]));
    try std.testing.expectEqual(@as(f64, 250.0), res.values[2]);
}
