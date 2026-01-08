const std = @import("std");
const Series = @import("series.zig").Series;

pub const PredicateOp = enum(u8) {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    not_,
    is_valid,
    is_null,
    is_nan,
};

pub const Field = enum(u8) {
    timestamp,
    value,
    dt,
};

pub const Predicate = struct {
    op: PredicateOp,
    field: Field = .value,
    constant: f64 = 0,

    left: ?*const Predicate = null,
    right: ?*const Predicate = null,

    pub fn evaluate(self: *const Predicate, series: *const Series, idx: usize) bool {
        const v = switch (self.field) {
            .timestamp => series.timestamps[idx],
            .value => series.values[idx],
            .dt => if (idx > 0) series.timestamps[idx] - series.timestamps[idx - 1] else 0,
        };

        return switch (self.op) {
            .gt => v > self.constant,
            .ge => v >= self.constant,
            .lt => v < self.constant,
            .le => v <= self.constant,
            .eq => v == self.constant,
            .ne => v != self.constant,
            .and_ => self.left.?.evaluate(series, idx) and self.right.?.evaluate(series, idx),
            .or_ => self.left.?.evaluate(series, idx) or self.right.?.evaluate(series, idx),
            .not_ => !self.left.?.evaluate(series, idx),
            .is_valid => series.validity[idx] != 0,
            .is_null => series.validity[idx] == 0,
            .is_nan => std.math.isNan(v),
        };
    }

    /// Evaluates the predicate for all samples and returns a bitmap.
    /// Resulting buffer must be freed by caller.
    pub fn evaluateBitmap(self: *const Predicate, series: *const Series, allocator: std.mem.Allocator) ![]u8 {
        const bitmap_len = (series.len + 7) / 8;
        const bitmap = try allocator.alloc(u8, bitmap_len);
        @memset(bitmap, 0);

        const Vec = @import("../core/value.zig").Vec;
        const VectorLen = @import("../core/value.zig").VectorLen;

        var i: usize = 0;
        // SIMD Path for simple value comparison
        if (self.field == .value and self.op == .gt and series.len >= VectorLen) {
            const threshold_vec: Vec = @splat(self.constant);
            
            while (i + VectorLen <= series.len) : (i += VectorLen) {
                const data_vec: Vec = series.values[i..][0..VectorLen].*;
                const mask = data_vec > threshold_vec;
                
                // Pack boolean vector into bits
                // This is a simplified bit-packing, in production we'd use 
                // architecture-specific movemask instructions for maximum speed.
                var bits: u8 = 0;
                comptime var k: usize = 0;
                inline while (k < VectorLen) : (k += 1) {
                    if (mask[k]) bits |= (@as(u8, 1) << k);
                }
                
                // Since our bitmap is 1-byte per 8 bits, and VectorLen is 4 or 2:
                const byte_idx = i / 8;
                const bit_offset: u3 = @truncate(i % 8);
                bitmap[byte_idx] |= (bits << bit_offset);
            }
        }

        // Scalar Fallback / Tail
        while (i < series.len) : (i += 1) {
            if (self.evaluate(series, i)) {
                bitmap[i / 8] |= @as(u8, 1) << @as(u3, @truncate(i % 8));
            }
        }
        return bitmap;
    }
};

test "Simple value predicate" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.deinit();

    series.values[0] = 5.0;
    series.values[1] = 15.0;
    series.values[2] = 25.0;
    series.values[3] = 10.0;
    series.values[4] = 20.0;

    const pred = Predicate{
        .op = .gt,
        .constant = 12.0,
    };

    try std.testing.expect(!pred.evaluate(series, 0));
    try std.testing.expect(pred.evaluate(series, 1));
    try std.testing.expect(pred.evaluate(series, 2));
    try std.testing.expect(!pred.evaluate(series, 3));
    try std.testing.expect(pred.evaluate(series, 4));
}

test "Time and Logical AND predicate" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.deinit();

    for (0..5) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i)) * 10.0; // 0, 10, 20, 30, 40
        series.values[i] = @as(f64, @floatFromInt(i)) * 5.0; // 0, 5, 10, 15, 20
    }

    const p_time = Predicate{
        .op = .gt,
        .field = .timestamp,
        .constant = 15.0,
    };

    const p_val = Predicate{
        .op = .lt,
        .field = .value,
        .constant = 18.0,
    };

    const p_and = Predicate{
        .op = .and_,
        .left = &p_time,
        .right = &p_val,
    };

    // idx 0: ts=0, val=0 -> false AND true -> false
    // idx 1: ts=10, val=5 -> false AND true -> false
    // idx 2: ts=20, val=10 -> true AND true -> true
    // idx 3: ts=30, val=15 -> true AND true -> true
    // idx 4: ts=40, val=20 -> true AND false -> false

    try std.testing.expect(!p_and.evaluate(series, 0));
    try std.testing.expect(!p_and.evaluate(series, 1));
    try std.testing.expect(p_and.evaluate(series, 2));
    try std.testing.expect(p_and.evaluate(series, 3));
    try std.testing.expect(!p_and.evaluate(series, 4));
}

test "Filtering: Complex logic (Time AND Value OR Valid)" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 10, .Linear, .{});
    defer series.deinit();

    for (0..10) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @as(f64, @floatFromInt(i)) * 10.0;
        series.validity[i] = if (i % 2 == 0) 1 else 0;
    }

    // Predicate: (Value > 50 AND IsValid)
    const p_gt = Predicate{ .op = .gt, .field = .value, .constant = 50.0 };
    const p_valid = Predicate{ .op = .is_valid };
    const p_and = Predicate{ .op = .and_, .left = &p_gt, .right = &p_valid };

    // Matches:
    // 60 (idx 6, valid=1) -> True
    // 70 (idx 7, valid=0) -> False
    // 80 (idx 8, valid=1) -> True
    
    try std.testing.expect(!p_and.evaluate(series, 5)); // 50 not > 50
    try std.testing.expect(p_and.evaluate(series, 6));
    try std.testing.expect(!p_and.evaluate(series, 7)); // Invalid
    try std.testing.expect(p_and.evaluate(series, 8));
}

test "Filtering: Delta-Time (Gap detection)" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 5, .Linear, .{});
    defer series.deinit();

    series.timestamps[0] = 0;
    series.timestamps[1] = 1; // dt = 1
    series.timestamps[2] = 2; // dt = 1
    series.timestamps[3] = 10; // dt = 8 (Gap!)
    series.timestamps[4] = 11; // dt = 1

    // Predicate: dt > 5
    const p_gap = Predicate{ .op = .gt, .field = .dt, .constant = 5.0 };

    try std.testing.expect(!p_gap.evaluate(series, 0)); // dt=0
    try std.testing.expect(!p_gap.evaluate(series, 2)); // dt=1
    try std.testing.expect(p_gap.evaluate(series, 3)); // dt=8
    try std.testing.expect(!p_gap.evaluate(series, 4)); // dt=1
}

test "Predicate: NaN handling" {
    const allocator = std.testing.allocator;
    const series = try Series.init(allocator, 3, .Linear, .{});
    defer series.deinit();

    series.timestamps[0] = 0;
    series.timestamps[1] = 1;
    series.timestamps[2] = 2;
    series.values[0] = 10.0;
    series.values[1] = std.math.nan(f64);
    series.values[2] = 20.0;
    series.validity[1] = 1; // Mark as valid but value is NaN

    const p_gt = Predicate{ .op = .gt, .field = .value, .constant = 5.0 };

    try std.testing.expect(p_gt.evaluate(series, 0));
    try std.testing.expect(!p_gt.evaluate(series, 1)); // NaN > 5 is false
    try std.testing.expect(p_gt.evaluate(series, 2));

    const p_is_nan = Predicate{ .op = .is_nan };
    try std.testing.expect(!p_is_nan.evaluate(series, 0));
    try std.testing.expect(p_is_nan.evaluate(series, 1));
}

