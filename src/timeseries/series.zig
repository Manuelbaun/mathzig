const std = @import("std");
const Dimensions = @import("../units/unit_registry.zig").Dimensions;
const live_handles = @import("../memory/live_handles.zig");

pub const SampleMode = enum(u8) {
    Step, // Discrete states (e.g., boolean flags, mode switches) - LOCF interpolation
    Linear, // Continuous measurements (e.g., sensor data, price) - Linear interpolation
    Cumulative, // Aggregated counters (e.g., pulse counters, meter readings)
};

pub const Series = struct {
    /// Alignment requirement for SIMD operations (32 bytes = 4 x f64)
    pub const simd_alignment: std.mem.Alignment = @enumFromInt(5);
    pub const simd_alignment_bytes: usize = 32;

    magic: u64 = 0x5345524945533031, // "SERIES01"
    timestamps: []align(simd_alignment_bytes) f64,
    values: []align(simd_alignment_bytes) f64,
    // Validity: 1 byte per sample for now.
    validity: []u8,
    len: usize,
    capacity: usize,
    sample_mode: SampleMode,
    dimensions: Dimensions,

    allocator: std.mem.Allocator,

    // Metadata for optimization
    is_sorted: bool,
    min_ts: f64,
    max_ts: f64,
    ref_count: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, len: usize, sample_mode: SampleMode, dimensions: Dimensions) !*Series {
        const self = try allocator.create(Series);
        errdefer allocator.destroy(self);

        const ts = try allocator.alignedAlloc(f64, simd_alignment, len);
        errdefer allocator.free(ts);

        const vals = try allocator.alignedAlloc(f64, simd_alignment, len);
        errdefer allocator.free(vals);

        const valid = try allocator.alloc(u8, len);
        errdefer allocator.free(valid);

        self.* = .{
            .timestamps = ts,
            .values = vals,
            .validity = valid,
            .len = len,
            .capacity = len,
            .sample_mode = sample_mode,
            .dimensions = dimensions,
            .allocator = allocator,
            .is_sorted = true, // Default to true, validated later
            .min_ts = std.math.inf(f64),
            .max_ts = -std.math.inf(f64),
            .ref_count = 1,
        };

        @memset(valid, 1); // Default to valid
        live_handles.incSeries();
        return self;
    }

    pub fn retain(self: *Series) *Series {
        std.debug.assert(self.magic == 0x5345524945533031);
        std.debug.assert(self.ref_count > 0);
        _ = @atomicRmw(u32, &self.ref_count, .Add, 1, .seq_cst);
        return self;
    }

    pub fn release(self: *Series) void {
        std.debug.assert(self.magic == 0x5345524945533031);
        std.debug.assert(self.ref_count > 0);
        if (@atomicRmw(u32, &self.ref_count, .Sub, 1, .seq_cst) == 1) {
            self.deinit();
        }
    }

    pub fn deinit(self: *Series) void {
        std.debug.assert(self.magic == 0x5345524945533031);
        self.magic = 0; // Mark as freed
        self.allocator.free(self.timestamps);
        self.allocator.free(self.values);
        self.allocator.free(self.validity);
        self.allocator.destroy(self);
        live_handles.decSeries();
    }

    pub fn validate(self: *Series) !void {
        std.debug.assert(self.magic == 0x5345524945533031);
        if (self.len == 0) return;

        self.min_ts = self.timestamps[0];
        self.max_ts = self.timestamps[0];
        self.is_sorted = true;

        for (0..self.len) |i| {
            const ts = self.timestamps[i];
            if (std.math.isNan(ts)) return error.NaNTimestamp;

            if (i > 0) {
                if (ts < self.timestamps[i - 1]) {
                    self.is_sorted = false;
                    return error.UnsortedTimestamps;
                }
            }

            if (ts < self.min_ts) self.min_ts = ts;
            if (ts > self.max_ts) self.max_ts = ts;
        }
    }

    pub fn view(self: *const Series, start: usize, end: usize) SeriesView {
        return .{
            .base = self,
            .start_idx = start,
            .end_idx = if (end > self.len) self.len else end,
        };
    }

    pub fn applyPredicate(self: *Series, predicate: ?*const @import("predicates.zig").Predicate) void {
        const p = predicate orelse return;
        for (0..self.len) |i| {
            if (self.validity[i] != 0) {
                if (!p.evaluate(self, i)) {
                    self.validity[i] = 0;
                }
            }
        }
    }

    pub fn binarySearch(data: []const f64, target: f64) usize {
        var left: usize = 0;
        var right: usize = data.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (data[mid] < target) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }

    pub fn head(self: *const Series, n: usize) !*Series {
        const count = @min(n, self.len);
        const result = try Series.init(self.allocator, count, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps[0..count], self.timestamps[0..count]);
        @memcpy(result.values[0..count], self.values[0..count]);
        @memcpy(result.validity[0..count], self.validity[0..count]);
        try result.validate();
        return result;
    }

    pub fn tail(self: *const Series, n: usize) !*Series {
        const count = @min(n, self.len);
        const start_idx = self.len - count;
        const result = try Series.init(self.allocator, count, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps[0..count], self.timestamps[start_idx..self.len]);
        @memcpy(result.values[0..count], self.values[start_idx..self.len]);
        @memcpy(result.validity[0..count], self.validity[start_idx..self.len]);
        try result.validate();
        return result;
    }

    pub fn slice(self: *const Series, start_ts: f64, end_ts: f64) !*Series {
        if (!self.is_sorted) return error.UnsortedTimestamps;
        const start_idx = binarySearch(self.timestamps, start_ts);
        const end_idx = binarySearch(self.timestamps, end_ts);
        
        if (start_idx >= end_idx) {
            return try Series.init(self.allocator, 0, self.sample_mode, self.dimensions);
        }

        const count = end_idx - start_idx;
        const result = try Series.init(self.allocator, count, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps[0..count], self.timestamps[start_idx..end_idx]);
        @memcpy(result.values[0..count], self.values[start_idx..end_idx]);
        @memcpy(result.validity[0..count], self.validity[start_idx..end_idx]);
        try result.validate();
        return result;
    }

    pub fn shift(self: *const Series, n: i64) !*Series {
        const result = try Series.init(self.allocator, self.len, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps, self.timestamps);
        
        if (n == 0) {
            @memcpy(result.values, self.values);
            @memcpy(result.validity, self.validity);
        } else if (n > 0) {
            const shift_u = @as(usize, @intCast(n));
            const count = if (shift_u >= self.len) 0 else self.len - shift_u;
            
            if (count > 0) {
                @memcpy(result.values[shift_u..self.len], self.values[0..count]);
                @memcpy(result.validity[shift_u..self.len], self.validity[0..count]);
            }
            
            @memset(result.values[0..@min(shift_u, self.len)], std.math.nan(f64));
            @memset(result.validity[0..@min(shift_u, self.len)], 0);
        } else {
            const shift_abs = @as(usize, @intCast(-n));
            const count = if (shift_abs >= self.len) 0 else self.len - shift_abs;
            
            if (count > 0) {
                @memcpy(result.values[0..count], self.values[shift_abs..self.len]);
                @memcpy(result.validity[0..count], self.validity[shift_abs..self.len]);
            }
            
            @memset(result.values[count..self.len], std.math.nan(f64));
            @memset(result.validity[count..self.len], 0);
        }
        
        try result.validate();
        return result;
    }

    pub fn dropna(self: *const Series) !*Series {
        var valid_count: usize = 0;
        for (0..self.len) |i| {
            if (self.validity[i] != 0 and !std.math.isNan(self.values[i])) {
                valid_count += 1;
            }
        }

        const result = try Series.init(self.allocator, valid_count, self.sample_mode, self.dimensions);
        var write_idx: usize = 0;
        for (0..self.len) |i| {
            if (self.validity[i] != 0 and !std.math.isNan(self.values[i])) {
                result.timestamps[write_idx] = self.timestamps[i];
                result.values[write_idx] = self.values[i];
                result.validity[write_idx] = 1;
                write_idx += 1;
            }
        }
        try result.validate();
        return result;
    }

    pub fn fillnaConstant(self: *const Series, value: f64) !*Series {
        const result = try Series.init(self.allocator, self.len, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps, self.timestamps);
        for (0..self.len) |i| {
            if (self.validity[i] == 0 or std.math.isNan(self.values[i])) {
                result.values[i] = value;
                result.validity[i] = 1;
            } else {
                result.values[i] = self.values[i];
                result.validity[i] = 1;
            }
        }
        try result.validate();
        return result;
    }

    pub fn fillnaForward(self: *const Series) !*Series {
        const result = try Series.init(self.allocator, self.len, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps, self.timestamps);
        var last_val: f64 = std.math.nan(f64);
        var has_val = false;

        for (0..self.len) |i| {
            const is_valid = self.validity[i] != 0 and !std.math.isNan(self.values[i]);
            if (is_valid) {
                last_val = self.values[i];
                has_val = true;
                result.values[i] = last_val;
                result.validity[i] = 1;
            } else if (has_val) {
                result.values[i] = last_val;
                result.validity[i] = 1;
            } else {
                result.values[i] = std.math.nan(f64);
                result.validity[i] = 0;
            }
        }
        try result.validate();
        return result;
    }

    pub fn fillnaBackward(self: *const Series) !*Series {
        const result = try Series.init(self.allocator, self.len, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps, self.timestamps);
        var next_val: f64 = std.math.nan(f64);
        var has_val = false;

        var i: usize = self.len;
        while (i > 0) {
            i -= 1;
            const is_valid = self.validity[i] != 0 and !std.math.isNan(self.values[i]);
            if (is_valid) {
                next_val = self.values[i];
                has_val = true;
                result.values[i] = next_val;
                result.validity[i] = 1;
            } else if (has_val) {
                result.values[i] = next_val;
                result.validity[i] = 1;
            } else {
                result.values[i] = std.math.nan(f64);
                result.validity[i] = 0;
            }
        }
        try result.validate();
        return result;
    }

    pub fn fillnaLinear(self: *const Series) !*Series {
        const result = try Series.init(self.allocator, self.len, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps, self.timestamps);
        
        var i: usize = 0;
        while (i < self.len) {
            const is_valid = self.validity[i] != 0 and !std.math.isNan(self.values[i]);
            if (is_valid) {
                result.values[i] = self.values[i];
                result.validity[i] = 1;
                i += 1;
                continue;
            }

            // Find next valid
            var j = i + 1;
            while (j < self.len and (self.validity[j] == 0 or std.math.isNan(self.values[j]))) : (j += 1) {}

            if (j < self.len and i > 0) {
                // Interpolate between i-1 and j
                const v_start = result.values[i - 1];
                const t_start = result.timestamps[i - 1];
                const v_end = self.values[j];
                const t_end = self.timestamps[j];

                for (i..j) |k| {
                    const t = result.timestamps[k];
                    const alpha = (t - t_start) / (t_end - t_start);
                    result.values[k] = v_start + alpha * (v_end - v_start);
                    result.validity[k] = 1;
                }
                i = j;
            } else {
                // Leading or trailing NaNs stay NaN (or we could forward/backward fill them)
                for (i..j) |k| {
                    result.values[k] = std.math.nan(f64);
                    result.validity[k] = 0;
                }
                i = j;
            }
        }
        try result.validate();
        return result;
    }

    pub fn clip(self: *const Series, min: f64, max: f64) !*Series {
        const result = try Series.init(self.allocator, self.len, self.sample_mode, self.dimensions);
        @memcpy(result.timestamps, self.timestamps);
        @memcpy(result.validity, self.validity);
        for (0..self.len) |i| {
            if (result.validity[i] != 0) {
                result.values[i] = std.math.clamp(self.values[i], min, max);
            } else {
                result.values[i] = self.values[i];
            }
        }
        try result.validate();
        return result;
    }
};

pub const SeriesView = struct {
    base: *const Series,
    start_idx: usize,
    end_idx: usize,

    pub fn len(self: SeriesView) usize {
        if (self.end_idx <= self.start_idx) return 0;
        return self.end_idx - self.start_idx;
    }

    pub fn getTimestamp(self: SeriesView, idx: usize) f64 {
        return self.base.timestamps[self.start_idx + idx];
    }

    pub fn getValue(self: SeriesView, idx: usize) f64 {
        return self.base.values[self.start_idx + idx];
    }

    pub fn isValid(self: SeriesView, idx: usize) bool {
        return self.base.validity[self.start_idx + idx] != 0;
    }
};

test "Series initialization and memory layout" {
    const allocator = std.testing.allocator;
    const dims = Dimensions{ .l = 1 }; // Meter
    const series = try Series.init(allocator, 100, .Linear, dims);
    defer series.release();

    try std.testing.expectEqual(@as(usize, 100), series.len);
    try std.testing.expectEqual(SampleMode.Linear, series.sample_mode);
    try std.testing.expectEqual(@as(i8, 1), series.dimensions.l);

    // Verify alignment
    try std.testing.expect(std.mem.isAligned(@intFromPtr(series.timestamps.ptr), Series.simd_alignment_bytes));
    try std.testing.expect(std.mem.isAligned(@intFromPtr(series.values.ptr), Series.simd_alignment_bytes));

    // Default validity should be 1
    for (series.validity) |v| {
        try std.testing.expectEqual(@as(u8, 1), v);
    }
}

test "Series validation (sorted)" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 10.0;
    series.timestamps[1] = 11.0;
    series.timestamps[2] = 12.0;
    series.timestamps[3] = 13.0;
    series.timestamps[4] = 14.0;

    try series.validate();
    try std.testing.expect(series.is_sorted);
    try std.testing.expectEqual(@as(f64, 10.0), series.min_ts);
    try std.testing.expectEqual(@as(f64, 14.0), series.max_ts);
}

test "Series validation (unsorted)" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 3, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 10.0;
    series.timestamps[1] = 9.0;
    series.timestamps[2] = 11.0;

    const result = series.validate();
    try std.testing.expectError(error.UnsortedTimestamps, result);
    try std.testing.expect(!series.is_sorted);
}

test "Series view slicing" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 10, .Step, .{});
    defer series.release();

    for (0..10) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i)) * 10.0;
        series.values[i] = @as(f64, @floatFromInt(i)) * 1.5;
    }

    const v = series.view(2, 5);
    try std.testing.expectEqual(@as(usize, 3), v.len());
    try std.testing.expectEqual(@as(f64, 20.0), v.getTimestamp(0));
    try std.testing.expectEqual(@as(f64, 30.0), v.getTimestamp(1));
    try std.testing.expectEqual(@as(f64, 40.0), v.getTimestamp(2));

    try std.testing.expectEqual(@as(f64, 3.0), v.getValue(0));
    try std.testing.expectEqual(@as(f64, 4.5), v.getValue(1));
    try std.testing.expectEqual(@as(f64, 6.0), v.getValue(2));
}

test "Core: Series lifecycle and large allocation" {
    const allocator = std.testing.allocator;
    // 1 Million samples (~16MB + overhead)
    const len = 1_000_000;
    const series = try Series.init(allocator, len, .Linear, .{});
    defer series.release();

    try std.testing.expectEqual(len, series.len);
    
    // Check initial state
    try std.testing.expectEqual(@as(u8, 1), series.validity[0]);
    try std.testing.expectEqual(@as(u8, 1), series.validity[len - 1]);
    
    // Initialize monotonic timestamps
    for (0..len) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = 1.0;
    }

    // Modify ends
    series.timestamps[0] = 0;
    series.values[0] = 1.0;
    series.timestamps[len - 1] = 999999;
    series.values[len - 1] = 2.0;

    try series.validate();
    try std.testing.expect(series.is_sorted);
    try std.testing.expectEqual(@as(f64, 0), series.min_ts);
    try std.testing.expectEqual(@as(f64, 999999), series.max_ts);
}

test "Core: NaN and Validity handling" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();

    // Setup some data
    series.timestamps[0] = 1; series.values[0] = 10;
    series.timestamps[1] = 2; series.values[1] = std.math.nan(f64);
    series.timestamps[2] = 3; series.values[2] = 30;
    series.timestamps[3] = 4; series.values[3] = 40; series.validity[3] = 0; // Explicitly invalid
    series.timestamps[4] = 5; series.values[4] = 50;

    // View check
    const view = series.view(1, 4); // Indices 1, 2, 3
    try std.testing.expectEqual(@as(usize, 3), view.len());
    
    // Index 1 (relative 0): NaN value, but validity bit is 1 (default) unless manually set
    // MathZig convention: validity bit takes precedence, but NaN payload is also checked in some ops.
    try std.testing.expect(std.math.isNan(view.getValue(0)));
    try std.testing.expect(view.isValid(0)); 

    // Index 3 (relative 2): Explicitly invalid
    try std.testing.expect(!view.isValid(2));
}

test "Series: head and tail" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();

    for (0..5) |i| {
        series.timestamps[i] = @floatFromInt(i);
        series.values[i] = @floatFromInt(i * 10);
    }
    try series.validate();

    const h2 = try series.head(2);
    defer h2.release();
    try std.testing.expectEqual(@as(usize, 2), h2.len);
    try std.testing.expectEqual(@as(f64, 0), h2.values[0]);
    try std.testing.expectEqual(@as(f64, 10), h2.values[1]);

    const t2 = try series.tail(2);
    defer t2.release();
    try std.testing.expectEqual(@as(usize, 2), t2.len);
    try std.testing.expectEqual(@as(f64, 30), t2.values[0]);
    try std.testing.expectEqual(@as(f64, 40), t2.values[1]);
}

test "Series: slice" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();

    for (0..5) |i| {
        series.timestamps[i] = @floatFromInt(i * 10); // 0, 10, 20, 30, 40
        series.values[i] = @floatFromInt(i);
    }
    try series.validate();

    // Slice [10, 35) -> includes 10, 20, 30
    const s = try series.slice(10, 35);
    defer s.release();
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(f64, 10), s.timestamps[0]);
    try std.testing.expectEqual(@as(f64, 30), s.timestamps[2]);
}

test "Series: shift" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 3, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 0; series.values[0] = 10;
    series.timestamps[1] = 1; series.values[1] = 20;
    series.timestamps[2] = 2; series.values[2] = 30;
    try series.validate();

    // Shift forward by 1
    const s1 = try series.shift(1);
    defer s1.release();
    try std.testing.expect(std.math.isNan(s1.values[0]));
    try std.testing.expectEqual(@as(f64, 10), s1.values[1]);
    try std.testing.expectEqual(@as(f64, 20), s1.values[2]);

    // Shift backward by 1
    const sm1 = try series.shift(-1);
    defer sm1.release();
    try std.testing.expectEqual(@as(f64, 20), sm1.values[0]);
    try std.testing.expectEqual(@as(f64, 30), sm1.values[1]);
    try std.testing.expect(std.math.isNan(sm1.values[2]));
}

test "Series: dropna" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 0; series.values[0] = 10;
    series.timestamps[1] = 1; series.values[1] = std.math.nan(f64);
    series.timestamps[2] = 2; series.values[2] = 20;
    series.timestamps[3] = 3; series.values[3] = 30; series.validity[3] = 0;
    series.timestamps[4] = 4; series.values[4] = 40;
    try series.validate();

    const d = try series.dropna();
    defer d.release();
    try std.testing.expectEqual(@as(usize, 3), d.len);
    try std.testing.expectEqual(@as(f64, 10), d.values[0]);
    try std.testing.expectEqual(@as(f64, 20), d.values[1]);
    try std.testing.expectEqual(@as(f64, 40), d.values[2]);
}

test "Series: fillna" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 0; series.values[0] = 10;
    series.timestamps[1] = 1; series.values[1] = std.math.nan(f64);
    series.timestamps[2] = 2; series.values[2] = 20;
    series.timestamps[3] = 3; series.values[3] = std.math.nan(f64);
    series.timestamps[4] = 4; series.values[4] = 40;
    try series.validate();

    const ff = try series.fillnaForward();
    defer ff.release();
    try std.testing.expectEqual(@as(f64, 10), ff.values[1]);
    try std.testing.expectEqual(@as(f64, 20), ff.values[3]);

    const fl = try series.fillnaLinear();
    defer fl.release();
    try std.testing.expectEqual(@as(f64, 15), fl.values[1]);
    try std.testing.expectEqual(@as(f64, 30), fl.values[3]);
}

test "Series: clip" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 3, .Linear, .{});
    defer series.release();

    series.timestamps[0] = 0; series.values[0] = -10;
    series.timestamps[1] = 1; series.values[1] = 50;
    series.timestamps[2] = 2; series.values[2] = 110;
    try series.validate();

    const c = try series.clip(0, 100);
    defer c.release();
    try std.testing.expectEqual(@as(f64, 0), c.values[0]);
    try std.testing.expectEqual(@as(f64, 50), c.values[1]);
    try std.testing.expectEqual(@as(f64, 100), c.values[2]);
}

