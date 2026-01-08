const std = @import("std");
const Series = @import("series.zig").Series;
const threading = @import("../core/threading.zig");

const is_wasm = threading.is_wasm;

/// As-of Join: For each timestamp in 'target_timestamps', find the most recent value in 'source'
/// that is <= target_ts.
/// target_timestamps MUST be sorted for optimal performance (linear scan).
pub fn asofJoin(target_timestamps: []const f64, source: *const Series, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, target_timestamps.len, source.sample_mode, source.dimensions);

    if (source.len == 0) {
        @memset(result.values, std.math.nan(f64));
        @memset(result.validity, 0);
        @memcpy(result.timestamps, target_timestamps);
        return result;
    }

    var source_idx: usize = 0;
    for (0..target_timestamps.len) |i| {
        const ts = target_timestamps[i];
        result.timestamps[i] = ts;

        // Advance source_idx to the last element <= ts
        while (source_idx + 1 < source.len and source.timestamps[source_idx + 1] <= ts) {
            source_idx += 1;
        }

        if (source.timestamps[source_idx] <= ts) {
            result.values[i] = source.values[source_idx];
            result.validity[i] = source.validity[source_idx];
        } else {
            // All source timestamps are in the future relative to this target ts
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }

    try result.validate();
    return result;
}

pub fn parAsofJoin(target_timestamps: []const f64, source: *const Series, pool: *threading.Pool, allocator: std.mem.Allocator) !*Series {
    if (comptime is_wasm) return asofJoin(target_timestamps, source, allocator);

    const result = try Series.init(allocator, target_timestamps.len, source.sample_mode, source.dimensions);

    if (source.len == 0) {
        @memset(result.values, std.math.nan(f64));
        @memset(result.validity, 0);
        @memcpy(result.timestamps, target_timestamps);
        return result;
    }

    const num_threads = threading.getCpuCount();
    const chunk_size = (target_timestamps.len + num_threads - 1) / num_threads;
    
    var wg = threading.WaitGroup{};
    
    var i: usize = 0;
    while (i < target_timestamps.len) : (i += chunk_size) {
        const chunk_end = @min(i + chunk_size, target_timestamps.len);
        wg.start();
        threading.spawn(pool, struct {
            fn run(w: *threading.WaitGroup, t_ts: []const f64, src: *const Series, res: *Series, start_idx: usize, end_idx: usize) void {
                defer w.finish();
                
                var source_idx: usize = 0;
                // Find initial source_idx for this chunk
                while (source_idx + 1 < src.len and src.timestamps[source_idx + 1] <= t_ts[start_idx]) {
                    source_idx += 1;
                }

                for (start_idx..end_idx) |j| {
                    const ts = t_ts[j];
                    res.timestamps[j] = ts;

                    while (source_idx + 1 < src.len and src.timestamps[source_idx + 1] <= ts) {
                        source_idx += 1;
                    }

                    if (src.timestamps[source_idx] <= ts) {
                        res.values[j] = src.values[source_idx];
                        res.validity[j] = src.validity[source_idx];
                    } else {
                        res.values[j] = std.math.nan(f64);
                        res.validity[j] = 0;
                    }
                }
            }
        }.run, .{ &wg, target_timestamps, source, result, i, chunk_end }) catch {
            wg.finish();
            // Fallback for this chunk
            var source_idx: usize = 0;
            while (source_idx + 1 < source.len and source.timestamps[source_idx + 1] <= target_timestamps[i]) {
                source_idx += 1;
            }
            for (i..chunk_end) |j| {
                const ts = target_timestamps[j];
                result.timestamps[j] = ts;
                while (source_idx + 1 < source.len and source.timestamps[source_idx + 1] <= ts) {
                    source_idx += 1;
                }
                if (source.timestamps[source_idx] <= ts) {
                    result.values[j] = source.values[source_idx];
                    result.validity[j] = source.validity[source_idx];
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
    
    

test "Simple as-of join" {
    const allocator = std.testing.allocator;
    const source = try Series.init(allocator, 3, .Step, .{});
    defer source.deinit();

    source.timestamps[0] = 10.0; source.values[0] = 100.0;
    source.timestamps[1] = 20.0; source.values[1] = 200.0;
    source.timestamps[2] = 30.0; source.values[2] = 300.0;
    try source.validate();

    const targets = [_]f64{ 5.0, 15.0, 25.0, 35.0 };
    const res = try asofJoin(&targets, source, allocator);
    defer res.deinit();

    try std.testing.expect(std.math.isNan(res.values[0])); // 5.0 < 10.0
    try std.testing.expectEqual(@as(f64, 100.0), res.values[1]); // 15.0 -> 10.0
    try std.testing.expectEqual(@as(f64, 200.0), res.values[2]); // 25.0 -> 20.0
    try std.testing.expectEqual(@as(f64, 300.0), res.values[3]); // 35.0 -> 30.0
}

test "Parallel as-of join correctness" {
    const builtin = @import("builtin");
    if (comptime builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) return;

    const allocator = std.testing.allocator;
    const source = try Series.init(allocator, 1000, .Step, .{});
    defer source.deinit();

    for (0..1000) |i| {
        source.timestamps[i] = @as(f64, @floatFromInt(i)) * 10.0;
        source.values[i] = @as(f64, @floatFromInt(i));
    }
    try source.validate();

    var pool: threading.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = 4 });
    defer pool.deinit();

    const targets = try allocator.alloc(f64, 5000);
    defer allocator.free(targets);
    for (0..5000) |i| {
        targets[i] = @as(f64, @floatFromInt(i)) * 2.0;
    }

    const res = try parAsofJoin(targets, source, &pool, allocator);
    defer res.deinit();

    try std.testing.expectEqual(targets.len, res.len);
    for (0..5000) |i| {
        const ts = targets[i];
        const expected_val = @floor(ts / 10.0);
        if (ts < 0) {
            try std.testing.expect(std.math.isNan(res.values[i]));
        } else {
            try std.testing.expectEqual(expected_val, res.values[i]);
        }
    }
}
