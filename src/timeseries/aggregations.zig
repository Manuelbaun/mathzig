const std = @import("std");
const builtin = @import("builtin");
const Series = @import("series.zig").Series;
const Predicate = @import("predicates.zig").Predicate;
const value = @import("../core/value.zig");
const threading = @import("../core/threading.zig");

const is_wasm = threading.is_wasm;
const Vec = value.Vec;
const VectorLen = value.VectorLen;

pub fn sum(series: *const Series, predicate: ?*const Predicate) f64 {
    if (predicate == null and series.len >= VectorLen) {
        return sumSIMD(series);
    }
    var total: f64 = 0;
    for (0..series.len) |i| {
        if (predicate == null or predicate.?.evaluate(series, i)) {
            if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
                total += series.values[i];
            }
        }
    }
    return total;
}

fn sumSIMD(series: *const Series) f64 {
    const len = series.len;
    const vec_len = len / VectorLen;
    const values = series.values;
    const validity = series.validity;
    
    var sum_vec: Vec = @splat(0.0);
    var i: usize = 0;
    
    // Cast to vector pointers
    const vec_ptr = @as([*]const Vec, @ptrCast(@alignCast(values.ptr)));
    
    while (i < vec_len) : (i += 1) {
        if (i + 16 < vec_len) {
            @prefetch(values.ptr + (i + 16) * VectorLen, .{ .rw = .read, .locality = 3 });
            @prefetch(validity.ptr + (i + 16) * VectorLen, .{ .rw = .read, .locality = 3 });
        }
        const v = vec_ptr[i];
        
        // We still need to check validity. 
        // For maximum performance, we check if the entire block is valid.
        const v_start = i * VectorLen;
        const v_block = validity[v_start..][0..VectorLen];
        
        var all_valid = true;
        for (v_block) |val| {
            if (val == 0) {
                all_valid = false;
                break;
            }
        }
        
        if (all_valid) {
            // Check for NaNs in the vector - @reduce(.Add, v) would be faster if no NaNs
            // But we must handle NaNs by ignoring them.
            // A simple way is to use @select with a mask.
            // In Zig, v != v is a vector-aware NaN check.
            const mask = v == v;
            sum_vec += @select(f64, mask, v, @as(Vec, @splat(0.0)));
        } else {
            // Mixed validity in this block, use selective sum
            inline for (0..VectorLen) |j| {
                if (v_block[j] != 0 and !std.math.isNan(v[j])) {
                    sum_vec[j] += v[j];
                }
            }
        }
    }
    
    var total = @reduce(.Add, sum_vec);
    
    // Handle remainder
    var j = i * VectorLen;
    while (j < len) : (j += 1) {
        if (validity[j] != 0 and !std.math.isNan(values[j])) {
            total += values[j];
        }
    }
    
    return total;
}

pub fn mean(series: *const Series, predicate: ?*const Predicate) f64 {
    if (predicate == null and series.len >= VectorLen) {
        return meanSIMD(series);
    }
    var total: f64 = 0;
    var valid_count: usize = 0;
    for (0..series.len) |i| {
        if (predicate == null or predicate.?.evaluate(series, i)) {
            if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
                total += series.values[i];
                valid_count += 1;
            }
        }
    }
    return if (valid_count > 0) total / @as(f64, @floatFromInt(valid_count)) else std.math.nan(f64);
}

fn meanSIMD(series: *const Series) f64 {
    const len = series.len;
    const vec_len = len / VectorLen;
    const values = series.values;
    const validity = series.validity;
    
    var sum_vec: Vec = @splat(0.0);
    var count_vec: @Vector(VectorLen, f64) = @splat(0.0);
    var i: usize = 0;
    
    const vec_ptr = @as([*]const Vec, @ptrCast(@alignCast(values.ptr)));
    
    while (i < vec_len) : (i += 1) {
        const v = vec_ptr[i];
        const v_start = i * VectorLen;
        const v_block = validity[v_start..][0..VectorLen];
        
        inline for (0..VectorLen) |j| {
            if (v_block[j] != 0 and !std.math.isNan(v[j])) {
                sum_vec[j] += v[j];
                count_vec[j] += 1.0;
            }
        }
    }
    
    var total_sum = @reduce(.Add, sum_vec);
    var total_count = @reduce(.Add, count_vec);
    
    var j = i * VectorLen;
    while (j < len) : (j += 1) {
        if (validity[j] != 0 and !std.math.isNan(values[j])) {
            total_sum += values[j];
            total_count += 1.0;
        }
    }
    
    return if (total_count > 0) total_sum / total_count else std.math.nan(f64);
}

pub fn parSum(series: *const Series, pool: *threading.Pool) f64 {
    const len = series.len;
    if (len < 100_000) return sum(series, null);

    const num_threads = threading.getCpuCount();
    const chunk_size = (len + num_threads - 1) / num_threads;
    
    var results = [_]f64{0} ** 32; // Support up to 32 threads
    const actual_threads = @min(num_threads, 32);
    
    var wg = threading.WaitGroup{};
    
    var i: usize = 0;
    var thread_idx: usize = 0;
    while (i < len) : (i += chunk_size) {
        const end = @min(i + chunk_size, len);
        wg.start();
        threading.spawn(pool, struct {
            fn run(w: *threading.WaitGroup, s: *const Series, start: usize, end_idx: usize, res_ptr: *f64) void {
                defer w.finish();
                // Use a view or just call a sub-sum
                var total: f64 = 0;
                for (start..end_idx) |j| {
                    if (s.validity[j] != 0 and !std.math.isNan(s.values[j])) {
                        total += s.values[j];
                    }
                }
                res_ptr.* = total;
            }
        }.run, .{ &wg, series, i, end, &results[thread_idx] }) catch {
            wg.finish();
            // Fallback
            var total: f64 = 0;
            for (i..end) |j| {
                if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                    total += series.values[j];
                }
            }
            results[thread_idx] = total;
        };
        thread_idx += 1;
        if (thread_idx >= actual_threads) break;
    }
    
    wg.wait();
    
    var total: f64 = 0;
    for (results[0..thread_idx]) |r| total += r;
    return total;
}

/// Time-Weighted Average (TWA) using Trapezoidal Rule
pub fn twa(series: *const Series, predicate: ?*const Predicate) f64 {
    if (series.len == 0) return std.math.nan(f64);
    if (predicate == null and series.len >= VectorLen + 1) {
        // Only use SIMD if we can assume all valid for now (simplification)
        // Check first if any invalid.
        var all_valid = true;
        for (series.validity) |v| {
            if (v == 0) {
                all_valid = false;
                break;
            }
        }
        if (all_valid) return twaSIMD(series);
    }

    var weighted_sum: f64 = 0;
    var total_duration: f64 = 0;
    var prev_ts: f64 = undefined;
    var prev_val: f64 = undefined;
    var first = true;

    for (0..series.len) |i| {
        const is_valid = if (predicate) |p| p.evaluate(series, i) else series.validity[i] != 0;
        if (!is_valid or std.math.isNan(series.values[i])) {
            continue;
        }

        const ts = series.timestamps[i];
        const val = series.values[i];

        if (!first) {
            const dt = ts - prev_ts;
            weighted_sum += (val + prev_val) / 2.0 * dt;
            total_duration += dt;
        }

        prev_ts = ts;
        prev_val = val;
        first = false;
    }

    const res = if (total_duration > 0) weighted_sum / total_duration else if (!first) prev_val else std.math.nan(f64);
    return res;
}

fn twaSIMD(series: *const Series) f64 {
    const len = series.len;
    const values = series.values;
    const timestamps = series.timestamps;
    
    var weighted_sum_vec: Vec = @splat(0.0);
    var duration_vec: Vec = @splat(0.0);
    
    // We process VectorLen items at a time.
    // Each SIMD step covers [i..i+VectorLen] using transitions from [i-1..i+VectorLen-1]
    var i: usize = 1;
    const vec_loop_end = ((len - 1) / VectorLen) * VectorLen + 1;
    
    while (i < vec_loop_end) : (i += VectorLen) {
        if (i + 32 < vec_loop_end) {
            @prefetch(values.ptr + i + 32, .{ .rw = .read, .locality = 3 });
            @prefetch(timestamps.ptr + i + 32, .{ .rw = .read, .locality = 3 });
        }
        // Load v[i..i+VectorLen] and v[i-1..i+VectorLen-1]
        // This is slightly unaligned for one of them if we just use pointers.
        // But Series.values is aligned. 
        // values[i..] might NOT be aligned if i is not a multiple of VectorLen.
        // Here i starts at 1, so it's definitely not aligned.
        
        const v_curr: Vec = values[i..][0..VectorLen].*;
        const v_prev: Vec = values[i-1..][0..VectorLen].*;
        const t_curr: Vec = timestamps[i..][0..VectorLen].*;
        const t_prev: Vec = timestamps[i-1..][0..VectorLen].*;
        
        const dt = t_curr - t_prev;
        // Check for NaNs
        const mask = (v_curr == v_curr) & (v_prev == v_prev);
        
        const area = (v_curr + v_prev) * @as(Vec, @splat(0.5)) * dt;
        weighted_sum_vec += @select(f64, mask, area, @as(Vec, @splat(0.0)));
        duration_vec += @select(f64, mask, dt, @as(Vec, @splat(0.0)));
    }
    
    var total_weighted_sum = @reduce(.Add, weighted_sum_vec);
    var total_duration = @reduce(.Add, duration_vec);
    
    // Remainder
    var j = i;
    while (j < len) : (j += 1) {
        if (!std.math.isNan(values[j]) and !std.math.isNan(values[j-1])) {
            const dt = timestamps[j] - timestamps[j-1];
            total_weighted_sum += (values[j] + values[j-1]) * 0.5 * dt;
            total_duration += dt;
        }
    }
    
    return if (total_duration > 0) total_weighted_sum / total_duration else values[0];
}

pub fn parTwa(series: *const Series, pool: *threading.Pool) f64 {
    if (comptime is_wasm) return twa(series, null);
    const len = series.len;
    if (len < 100_000) return twa(series, null);

    const num_threads = threading.getCpuCount();
    const chunk_size = (len + num_threads - 1) / num_threads;
    
    const TaskResult = struct {
        weighted_sum: f64,
        duration: f64,
    };
    
    var results = [_]TaskResult{.{ .weighted_sum = 0, .duration = 0 }} ** 32;
    const actual_threads = @min(num_threads, 32);
    
    var wg = threading.WaitGroup{};
    
    var i: usize = 0;
    var thread_idx: usize = 0;
    while (i < len and thread_idx < actual_threads) : (i += chunk_size) {
        // Each chunk needs to know the previous sample for the trapezoidal rule
        // So chunks overlap by 1 sample.
        const start = i;
        const end = @min(i + chunk_size + 1, len);
        if (start >= len - 1) break;

        wg.start();
        threading.spawn(pool, struct {
            fn run(w: *threading.WaitGroup, s: *const Series, s_idx: usize, e_idx: usize, res_ptr: *TaskResult) void {
                defer w.finish();
                var weighted_sum: f64 = 0;
                var duration: f64 = 0;
                var j: usize = s_idx + 1;
                while (j < e_idx) : (j += 1) {
                    if (s.validity[j] != 0 and s.validity[j-1] != 0 and !std.math.isNan(s.values[j]) and !std.math.isNan(s.values[j-1])) {
                        const dt = s.timestamps[j] - s.timestamps[j-1];
                        weighted_sum += (s.values[j] + s.values[j-1]) * 0.5 * dt;
                        duration += dt;
                    }
                }
                res_ptr.* = .{ .weighted_sum = weighted_sum, .duration = duration };
            }
        }.run, .{ &wg, series, start, end, &results[thread_idx] }) catch {
            wg.finish();
            // Fallback
            var weighted_sum: f64 = 0;
            var duration: f64 = 0;
            var j: usize = start + 1;
            while (j < end) : (j += 1) {
                if (series.validity[j] != 0 and series.validity[j-1] != 0 and !std.math.isNan(series.values[j]) and !std.math.isNan(series.values[j-1])) {
                    const dt = series.timestamps[j] - series.timestamps[j-1];
                    weighted_sum += (series.values[j] + series.values[j-1]) * 0.5 * dt;
                    duration += dt;
                }
            }
            results[thread_idx] = .{ .weighted_sum = weighted_sum, .duration = duration };
        };
        thread_idx += 1;
        if (end >= len) break;
    }
    
    wg.wait();
    
    var total_weighted_sum: f64 = 0;
    var total_duration: f64 = 0;
    for (results[0..thread_idx]) |r| {
        total_weighted_sum += r.weighted_sum;
        total_duration += r.duration;
    }
    return if (total_duration > 0) total_weighted_sum / total_duration else series.values[0];
}

pub fn min(series: *const Series, predicate: ?*const Predicate) f64 {
    if (predicate == null and series.len >= VectorLen) {
        return minSIMD(series);
    }
    var res: f64 = std.math.inf(f64);
    var found = false;
    for (0..series.len) |i| {
        if (predicate == null or predicate.?.evaluate(series, i)) {
            if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
                if (series.values[i] < res) res = series.values[i];
                found = true;
            }
        }
    }
    return if (found) res else std.math.nan(f64);
}

fn minSIMD(series: *const Series) f64 {
    const len = series.len;
    const vec_len = len / VectorLen;
    const values = series.values;
    const validity = series.validity;
    
    var min_vec: Vec = @splat(std.math.inf(f64));
    var i: usize = 0;
    var found_any = false;
    
    const vec_ptr = @as([*]const Vec, @ptrCast(@alignCast(values.ptr)));
    
    while (i < vec_len) : (i += 1) {
        const v = vec_ptr[i];
        const v_start = i * VectorLen;
        const v_block = validity[v_start..][0..VectorLen];
        
        inline for (0..VectorLen) |j| {
            if (v_block[j] != 0 and !std.math.isNan(v[j])) {
                min_vec[j] = @min(min_vec[j], v[j]);
                found_any = true;
            }
        }
    }
    
    var res = @reduce(.Min, min_vec);
    
    var j = i * VectorLen;
    while (j < len) : (j += 1) {
        if (validity[j] != 0 and !std.math.isNan(values[j])) {
            res = @min(res, values[j]);
            found_any = true;
        }
    }
    
    return if (found_any) res else std.math.nan(f64);
}

pub fn max(series: *const Series, predicate: ?*const Predicate) f64 {
    if (predicate == null and series.len >= VectorLen) {
        return maxSIMD(series);
    }
    var res: f64 = -std.math.inf(f64);
    var found = false;
    for (0..series.len) |i| {
        if (predicate == null or predicate.?.evaluate(series, i)) {
            if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
                if (series.values[i] > res) res = series.values[i];
                found = true;
            }
        }
    }
    return if (found) res else std.math.nan(f64);
}

fn maxSIMD(series: *const Series) f64 {
    const len = series.len;
    const vec_len = len / VectorLen;
    const values = series.values;
    const validity = series.validity;
    
    var max_vec: Vec = @splat(-std.math.inf(f64));
    var i: usize = 0;
    var found_any = false;
    
    const vec_ptr = @as([*]const Vec, @ptrCast(@alignCast(values.ptr)));
    
    while (i < vec_len) : (i += 1) {
        const v = vec_ptr[i];
        const v_start = i * VectorLen;
        const v_block = validity[v_start..][0..VectorLen];
        
        inline for (0..VectorLen) |j| {
            if (v_block[j] != 0 and !std.math.isNan(v[j])) {
                max_vec[j] = @max(max_vec[j], v[j]);
                found_any = true;
            }
        }
    }
    
    var res = @reduce(.Max, max_vec);
    
    var j = i * VectorLen;
    while (j < len) : (j += 1) {
        if (validity[j] != 0 and !std.math.isNan(values[j])) {
            res = @max(res, values[j]);
            found_any = true;
        }
    }
    
    return if (found_any) res else std.math.nan(f64);
}

pub fn range(series: *const Series, predicate: ?*const Predicate) f64 {
    const min_val = min(series, predicate);
    if (std.math.isNan(min_val)) return std.math.nan(f64);
    const max_val = max(series, predicate);
    if (std.math.isNan(max_val)) return std.math.nan(f64);
    return max_val - min_val;
}

pub fn count(series: *const Series, predicate: ?*const Predicate) f64 {
    var n: usize = 0;
    for (0..series.len) |i| {
        if (predicate == null or predicate.?.evaluate(series, i)) {
            if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
                n += 1;
            }
        }
    }
    return @floatFromInt(n);
}

pub fn cumsum(series: *const Series, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    var current_sum: f64 = 0;
    for (0..series.len) |i| {
        if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
            current_sum += series.values[i];
        }
        result.values[i] = current_sum;
        result.timestamps[i] = series.timestamps[i];
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn cummax(series: *const Series, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    var current_max: f64 = -std.math.inf(f64);
    for (0..series.len) |i| {
        if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
            if (series.values[i] > current_max) current_max = series.values[i];
        }
        result.values[i] = if (std.math.isInf(current_max)) std.math.nan(f64) else current_max;
        result.timestamps[i] = series.timestamps[i];
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn cummin(series: *const Series, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    var current_min: f64 = std.math.inf(f64);
    for (0..series.len) |i| {
        if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
            if (series.values[i] < current_min) current_min = series.values[i];
        }
        result.values[i] = if (std.math.isInf(current_min)) std.math.nan(f64) else current_min;
        result.timestamps[i] = series.timestamps[i];
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn rollingSum(series: *const Series, window: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    var sum_val: f64 = 0;
    var valid_count: usize = 0;
    
    for (0..series.len) |i| {
        const val = series.values[i];
        const is_valid = series.validity[i] != 0 and !std.math.isNan(val);
        
        if (is_valid) {
            sum_val += val;
            valid_count += 1;
        }
        
        if (i >= window) {
            const old_val = series.values[i - window];
            const old_valid = series.validity[i - window] != 0 and !std.math.isNan(old_val);
            if (old_valid) {
                sum_val -= old_val;
                valid_count -= 1;
            }
        }
        
        result.timestamps[i] = series.timestamps[i];
        if (i + 1 >= window) {
            result.values[i] = sum_val;
            result.validity[i] = 1;
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

pub fn rollingMean(series: *const Series, window: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    var sum_val: f64 = 0;
    var valid_count: usize = 0;
    
    for (0..series.len) |i| {
        const val = series.values[i];
        const is_valid = series.validity[i] != 0 and !std.math.isNan(val);
        
        if (is_valid) {
            sum_val += val;
            valid_count += 1;
        }
        
        if (i >= window) {
            const old_val = series.values[i - window];
            const old_valid = series.validity[i - window] != 0 and !std.math.isNan(old_val);
            if (old_valid) {
                sum_val -= old_val;
                valid_count -= 1;
            }
        }
        
        result.timestamps[i] = series.timestamps[i];
        if (i + 1 >= window) {
            result.values[i] = if (valid_count > 0) sum_val / @as(f64, @floatFromInt(valid_count)) else std.math.nan(f64);
            result.validity[i] = 1;
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

pub fn rollingMin(series: *const Series, window: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    
    for (0..series.len) |i| {
        result.timestamps[i] = series.timestamps[i];
        if (i + 1 >= window) {
            var min_val: f64 = std.math.inf(f64);
            var found = false;
            var j: usize = i + 1 - window;
            while (j <= i) : (j += 1) {
                if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                    if (series.values[j] < min_val) min_val = series.values[j];
                    found = true;
                }
            }
            result.values[i] = if (found) min_val else std.math.nan(f64);
            result.validity[i] = 1;
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

pub fn rollingMax(series: *const Series, window: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    
    for (0..series.len) |i| {
        result.timestamps[i] = series.timestamps[i];
        if (i + 1 >= window) {
            var max_val: f64 = -std.math.inf(f64);
            var found = false;
            var j: usize = i + 1 - window;
            while (j <= i) : (j += 1) {
                if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                    if (series.values[j] > max_val) max_val = series.values[j];
                    found = true;
                }
            }
            result.values[i] = if (found) max_val else std.math.nan(f64);
            result.validity[i] = 1;
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

pub fn rollingCount(series: *const Series, window: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    var valid_count: usize = 0;
    
    for (0..series.len) |i| {
        if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
            valid_count += 1;
        }
        
        if (i >= window) {
            if (series.validity[i - window] != 0 and !std.math.isNan(series.values[i - window])) {
                valid_count -= 1;
            }
        }
        
        result.timestamps[i] = series.timestamps[i];
        if (i + 1 >= window) {
            result.values[i] = @floatFromInt(valid_count);
            result.validity[i] = 1;
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

pub fn rollingSumDuration(series: *const Series, window_seconds: f64, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    if (!series.is_sorted) return error.UnsortedTimestamps;

    var sum_val: f64 = 0;
    var start_idx: usize = 0;
    
    for (0..series.len) |i| {
        const ts_end = series.timestamps[i];
        const ts_start = ts_end - window_seconds;
        
        // Add current
        if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
            sum_val += series.values[i];
        }
        
        // Remove those that fell out of window
        while (start_idx < i and series.timestamps[start_idx] < ts_start) {
            if (series.validity[start_idx] != 0 and !std.math.isNan(series.values[start_idx])) {
                sum_val -= series.values[start_idx];
            }
            start_idx += 1;
        }
        
        result.timestamps[i] = ts_end;
        result.values[i] = sum_val;
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn rollingMeanDuration(series: *const Series, window_seconds: f64, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    if (!series.is_sorted) return error.UnsortedTimestamps;

    var sum_val: f64 = 0;
    var valid_count: usize = 0;
    var start_idx: usize = 0;
    
    for (0..series.len) |i| {
        const ts_end = series.timestamps[i];
        const ts_start = ts_end - window_seconds;
        
        if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
            sum_val += series.values[i];
            valid_count += 1;
        }
        
        while (start_idx < i and series.timestamps[start_idx] < ts_start) {
            if (series.validity[start_idx] != 0 and !std.math.isNan(series.values[start_idx])) {
                sum_val -= series.values[start_idx];
                valid_count -= 1;
            }
            start_idx += 1;
        }
        
        result.timestamps[i] = ts_end;
        result.values[i] = if (valid_count > 0) sum_val / @as(f64, @floatFromInt(valid_count)) else std.math.nan(f64);
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn rollingMinDuration(series: *const Series, window_seconds: f64, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    if (!series.is_sorted) return error.UnsortedTimestamps;

    var start_idx: usize = 0;
    for (0..series.len) |i| {
        const ts_end = series.timestamps[i];
        const ts_start = ts_end - window_seconds;
        
        while (start_idx < i and series.timestamps[start_idx] < ts_start) {
            start_idx += 1;
        }
        
        var min_val: f64 = std.math.inf(f64);
        var found = false;
        var j = start_idx;
        while (j <= i) : (j += 1) {
            if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                if (series.values[j] < min_val) min_val = series.values[j];
                found = true;
            }
        }
        
        result.timestamps[i] = ts_end;
        result.values[i] = if (found) min_val else std.math.nan(f64);
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn rollingMaxDuration(series: *const Series, window_seconds: f64, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    if (!series.is_sorted) return error.UnsortedTimestamps;

    var start_idx: usize = 0;
    for (0..series.len) |i| {
        const ts_end = series.timestamps[i];
        const ts_start = ts_end - window_seconds;
        
        while (start_idx < i and series.timestamps[start_idx] < ts_start) {
            start_idx += 1;
        }
        
        var max_val: f64 = -std.math.inf(f64);
        var found = false;
        var j = start_idx;
        while (j <= i) : (j += 1) {
            if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                if (series.values[j] > max_val) max_val = series.values[j];
                found = true;
            }
        }
        
        result.timestamps[i] = ts_end;
        result.values[i] = if (found) max_val else std.math.nan(f64);
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn rollingCountDuration(series: *const Series, window_seconds: f64, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    if (!series.is_sorted) return error.UnsortedTimestamps;

    var valid_count: usize = 0;
    var start_idx: usize = 0;
    
    for (0..series.len) |i| {
        const ts_end = series.timestamps[i];
        const ts_start = ts_end - window_seconds;
        
        if (series.validity[i] != 0 and !std.math.isNan(series.values[i])) {
            valid_count += 1;
        }
        
        while (start_idx < i and series.timestamps[start_idx] < ts_start) {
            if (series.validity[start_idx] != 0 and !std.math.isNan(series.values[start_idx])) {
                valid_count -= 1;
            }
            start_idx += 1;
        }
        
        result.timestamps[i] = ts_end;
        result.values[i] = @floatFromInt(valid_count);
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

pub fn rollingStddev(series: *const Series, window: usize, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    
    for (0..series.len) |i| {
        result.timestamps[i] = series.timestamps[i];
        if (i + 1 >= window) {
            var sum_val: f64 = 0;
            var valid_count: usize = 0;
            var j: usize = i + 1 - window;
            while (j <= i) : (j += 1) {
                if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                    sum_val += series.values[j];
                    valid_count += 1;
                }
            }
            
            if (valid_count < 2) {
                result.values[i] = 0;
            } else {
                const m = sum_val / @as(f64, @floatFromInt(valid_count));
                var sum_sq_diff: f64 = 0;
                j = i + 1 - window;
                while (j <= i) : (j += 1) {
                    if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                        const diff = series.values[j] - m;
                        sum_sq_diff += diff * diff;
                    }
                }
                result.values[i] = @sqrt(sum_sq_diff / @as(f64, @floatFromInt(valid_count - 1)));
            }
            result.validity[i] = 1;
        } else {
            result.values[i] = std.math.nan(f64);
            result.validity[i] = 0;
        }
    }
    try result.validate();
    return result;
}

pub fn rollingStddevDuration(series: *const Series, window_seconds: f64, allocator: std.mem.Allocator) !*Series {
    const result = try Series.init(allocator, series.len, series.sample_mode, series.dimensions);
    if (!series.is_sorted) return error.UnsortedTimestamps;

    var start_idx: usize = 0;
    for (0..series.len) |i| {
        const ts_end = series.timestamps[i];
        const ts_start = ts_end - window_seconds;
        
        while (start_idx < i and series.timestamps[start_idx] < ts_start) {
            start_idx += 1;
        }
        
        var sum_val: f64 = 0;
        var valid_count: usize = 0;
        var j = start_idx;
        while (j <= i) : (j += 1) {
            if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                sum_val += series.values[j];
                valid_count += 1;
            }
        }
        
        if (valid_count < 2) {
            result.values[i] = 0;
        } else {
            const m = sum_val / @as(f64, @floatFromInt(valid_count));
            var sum_sq_diff: f64 = 0;
            j = start_idx;
            while (j <= i) : (j += 1) {
                if (series.validity[j] != 0 and !std.math.isNan(series.values[j])) {
                    const diff = series.values[j] - m;
                    sum_sq_diff += diff * diff;
                }
            }
            result.values[i] = @sqrt(sum_sq_diff / @as(f64, @floatFromInt(valid_count - 1)));
        }
        
        result.timestamps[i] = ts_end;
        result.validity[i] = 1;
    }
    try result.validate();
    return result;
}

test "Cumulative operations correctness" {
    const allocator = std.testing.allocator;
    const len = 5;
    const series = try Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    const ts_data = [_]f64{ 0, 1, 2, 3, 4 };
    const val_data = [_]f64{ 10, 5, 20, 15, 30 };
    @memcpy(series.timestamps[0..len], &ts_data);
    @memcpy(series.values[0..len], &val_data);
    @memset(series.validity, 1);
    try series.validate();

    const cs = try cumsum(series, allocator);
    defer cs.deinit();
    try std.testing.expectEqual(@as(f64, 10), cs.values[0]);
    try std.testing.expectEqual(@as(f64, 15), cs.values[1]);
    try std.testing.expectEqual(@as(f64, 35), cs.values[2]);
    try std.testing.expectEqual(@as(f64, 50), cs.values[3]);
    try std.testing.expectEqual(@as(f64, 80), cs.values[4]);

    const cmax = try cummax(series, allocator);
    defer cmax.deinit();
    try std.testing.expectEqual(@as(f64, 10), cmax.values[0]);
    try std.testing.expectEqual(@as(f64, 10), cmax.values[1]);
    try std.testing.expectEqual(@as(f64, 20), cmax.values[2]);
    try std.testing.expectEqual(@as(f64, 20), cmax.values[3]);
    try std.testing.expectEqual(@as(f64, 30), cmax.values[4]);

    const cmin = try cummin(series, allocator);
    defer cmin.deinit();
    try std.testing.expectEqual(@as(f64, 10), cmin.values[0]);
    try std.testing.expectEqual(@as(f64, 5), cmin.values[1]);
    try std.testing.expectEqual(@as(f64, 5), cmin.values[2]);
    try std.testing.expectEqual(@as(f64, 5), cmin.values[3]);
    try std.testing.expectEqual(@as(f64, 5), cmin.values[4]);
}

test "Rolling operations correctness" {
    const allocator = std.testing.allocator;
    const len = 5;
    const series = try Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    const ts_data = [_]f64{ 0, 1, 2, 3, 4 };
    const val_data = [_]f64{ 10, 5, 20, 15, 30 };
    @memcpy(series.timestamps[0..len], &ts_data);
    @memcpy(series.values[0..len], &val_data);
    @memset(series.validity, 1);
    try series.validate();

    // Window size 2
    const rs = try rollingSum(series, 2, allocator);
    defer rs.deinit();
    try std.testing.expect(std.math.isNan(rs.values[0]));
    try std.testing.expectEqual(@as(f64, 15), rs.values[1]); // 10+5
    try std.testing.expectEqual(@as(f64, 25), rs.values[2]); // 5+20
    try std.testing.expectEqual(@as(f64, 35), rs.values[3]); // 20+15
    try std.testing.expectEqual(@as(f64, 45), rs.values[4]); // 15+30

    const rm = try rollingMean(series, 3, allocator);
    defer rm.deinit();
    try std.testing.expect(std.math.isNan(rm.values[0]));
    try std.testing.expect(std.math.isNan(rm.values[1]));
    try std.testing.expectApproxEqAbs(@as(f64, 11.66666), rm.values[2], 0.0001); // (10+5+20)/3 = 35/3 = 11.666
    try std.testing.expectApproxEqAbs(@as(f64, 13.33333), rm.values[3], 0.0001); // (5+20+15)/3 = 40/3 = 13.333
    try std.testing.expectApproxEqAbs(@as(f64, 21.66666), rm.values[4], 0.0001); // (20+15+30)/3 = 65/3 = 21.666

    const rmin = try rollingMin(series, 2, allocator);
    defer rmin.deinit();
    try std.testing.expectEqual(@as(f64, 5), rmin.values[1]);
    try std.testing.expectEqual(@as(f64, 5), rmin.values[2]);
    try std.testing.expectEqual(@as(f64, 15), rmin.values[3]);
    try std.testing.expectEqual(@as(f64, 15), rmin.values[4]);

    const rmax = try rollingMax(series, 2, allocator);
    defer rmax.deinit();
    try std.testing.expectEqual(@as(f64, 10), rmax.values[1]);
    try std.testing.expectEqual(@as(f64, 20), rmax.values[2]);
    try std.testing.expectEqual(@as(f64, 20), rmax.values[3]);
    try std.testing.expectEqual(@as(f64, 30), rmax.values[4]);
}

test "Rolling stddev correctness" {
    const allocator = std.testing.allocator;
    const len = 5;
    const series = try Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    const ts_data = [_]f64{ 0, 1, 2, 3, 4 };
    const val_data = [_]f64{ 10, 20, 10, 20, 10 };
    @memcpy(series.timestamps[0..len], &ts_data);
    @memcpy(series.values[0..len], &val_data);
    @memset(series.validity, 1);
    try series.validate();

    // Window 2: [10, 20] -> mean 15, var (5^2 + 5^2)/1 = 50, stddev sqrt(50) = 7.071
    const rstd = try rollingStddev(series, 2, allocator);
    defer rstd.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 7.07106), rstd.values[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 7.07106), rstd.values[2], 0.0001);
}

test "TWA vs Mean on irregular data" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 2, .Linear, .{});
    defer series.deinit();

    // 100 for 59 minutes, 0 for 1 minute
    series.timestamps[0] = 0;
    series.values[0] = 100.0;
    series.timestamps[1] = 59.0 * 60.0; // 59 mins in seconds
    series.values[1] = 100.0;
    
    // Add a 3rd sample to show the drop
    const series2 = try Series.init(allocator, 3, .Linear, .{});
    defer series2.deinit();
    series2.timestamps[0] = 0;
    series2.values[0] = 100.0;
    series2.timestamps[1] = 59.0 * 60.0;
    series2.values[1] = 100.0;
    series2.timestamps[2] = 60.0 * 60.0; // 60 mins
    series2.values[2] = 0.0;

    const m = mean(series2, null);
    // (100 + 100 + 0) / 3 = 66.66
    try std.testing.expectApproxEqAbs(@as(f64, 66.6666), m, 0.0001);

    const t = twa(series2, null);
    // Duration 0-59: value 100. Area = 100 * 59 * 60
    // Duration 59-60: value 100->0. Area = (100+0)/2 * 1 * 60 = 50 * 60
    // Total Area = 60 * (5900 + 50) = 60 * 5950
    // Total Duration = 60 * 60
    // TWA = (60 * 5950) / (60 * 60) = 5950 / 60 = 99.1666
    try std.testing.expectApproxEqAbs(@as(f64, 99.1666), t, 0.0001);
}

test "SIMD Aggregations correctness" {
    const allocator = std.testing.allocator;
    const len = 100;
    const series = try Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    for (0..len) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = @floatFromInt(i + 1);
    }

    // Standard case: all valid
    try std.testing.expectEqual(@as(f64, 5050.0), sum(series, null));
    try std.testing.expectEqual(@as(f64, 50.5), mean(series, null));
    try std.testing.expectEqual(@as(f64, 1.0), min(series, null));
    try std.testing.expectEqual(@as(f64, 100.0), max(series, null));

    // Handle NaNs
    series.values[10] = std.math.nan(f64);
    try std.testing.expectEqual(@as(f64, 5050.0 - 11.0), sum(series, null));
    try std.testing.expectEqual(@as(f64, (5050.0 - 11.0) / 99.0), mean(series, null));

    // Handle Validity
    series.validity[20] = 0; // value 21.0
    try std.testing.expectEqual(@as(f64, 5050.0 - 11.0 - 21.0), sum(series, null));
    try std.testing.expectEqual(@as(f64, (5050.0 - 11.0 - 21.0) / 98.0), mean(series, null));
    
    // Min/Max with invalid at bounds
    series.values[0] = 0.5; // New min
    series.validity[0] = 0; // but invalid
    try std.testing.expectEqual(@as(f64, 2.0), min(series, null));
}

test "SIMD Min/Max edge cases" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 10, .Linear, .{});
    defer series.deinit();

    for (0..10) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = @floatFromInt(i + 10); // 10 to 19
    }

    try std.testing.expectEqual(@as(f64, 10.0), min(series, null));
    try std.testing.expectEqual(@as(f64, 19.0), max(series, null));

    series.validity[0] = 0;
    try std.testing.expectEqual(@as(f64, 11.0), min(series, null));

    series.validity[9] = 0;
    try std.testing.expectEqual(@as(f64, 18.0), max(series, null));

    series.values[5] = std.math.nan(f64);
    try std.testing.expectEqual(@as(f64, 11.0), min(series, null));
    try std.testing.expectEqual(@as(f64, 18.0), max(series, null));
}

test "SIMD TWA correctness" {
    const allocator = std.testing.allocator;
    const len = 100;
    const series = try Series.init(allocator, len, .Linear, .{});
    defer series.deinit();

    for (0..len) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = 10.0; // Constant value
    }

    // TWA of constant 10.0 should be 10.0
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), twa(series, null), 0.0001);

    // Linear ramp: 0 to 99
    for (0..len) |i| {
        series.values[i] = @floatFromInt(i);
    }
    // Average of 0..99 linearly is 49.5
    try std.testing.expectApproxEqAbs(@as(f64, 49.5), twa(series, null), 0.0001);
}

test "parallel sum" {
    if (comptime is_wasm) return;
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 200000, .Linear, .{});
    defer series.deinit();
    for (0..200000) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = 1.0;
    }
    
    var pool: threading.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = 4 });
    defer pool.deinit();

    try std.testing.expectEqual(@as(f64, 200000.0), parSum(series, &pool));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), parTwa(series, &pool), 0.0001);
    
    // Test with some NaNs
    series.values[50000] = std.math.nan(f64);
    try std.testing.expectEqual(@as(f64, 199999.0), parSum(series, &pool));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), parTwa(series, &pool), 0.0001);
}
