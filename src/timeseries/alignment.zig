const std = @import("std");
const Series = @import("series.zig").Series;
const SampleMode = @import("series.zig").SampleMode;

pub const AlignmentError = error{
    UnsortedTimestamps,
    EmptySeries,
};

/// Aligns two series using the UNION of their timestamps.
/// Missing values are interpolated based on the series' SampleMode.
pub fn alignUnion(a: *const Series, b: *const Series, allocator: std.mem.Allocator) !struct { *Series, *Series } {
    if (a.len == 0 or b.len == 0) return AlignmentError.EmptySeries;
    
    // 1. Collect all unique timestamps
    var ts_list = std.ArrayListUnmanaged(f64).empty;
    defer ts_list.deinit(allocator);
    
    var i: usize = 0;
    var j: usize = 0;
    
    while (i < a.len or j < b.len) {
        const ts_a = if (i < a.len) a.timestamps[i] else std.math.inf(f64);
        const ts_b = if (j < b.len) b.timestamps[j] else std.math.inf(f64);
        
        if (ts_a < ts_b) {
            try ts_list.append(allocator, ts_a);
            i += 1;
        } else if (ts_b < ts_a) {
            try ts_list.append(allocator, ts_b);
            j += 1;
        } else {
            // Equal timestamps
            try ts_list.append(allocator, ts_a);
            i += 1;
            j += 1;
        }
    }
    
    const combined_ts = ts_list.items;
    const new_len = combined_ts.len;
    
    // 2. Create new series
    const res_a = try Series.init(allocator, new_len, a.sample_mode, a.dimensions);
    errdefer res_a.deinit();
    const res_b = try Series.init(allocator, new_len, b.sample_mode, b.dimensions);
    errdefer res_b.deinit();
    
    @memcpy(res_a.timestamps, combined_ts);
    @memcpy(res_b.timestamps, combined_ts);
    
    // 3. Interpolate values
    interpolateInto(a, res_a);
    interpolateInto(b, res_b);
    
    try res_a.validate();
    try res_b.validate();
    
    return .{ res_a, res_b };
}

fn interpolateInto(source: *const Series, target: *Series) void {
    if (source.len == 0 or target.len == 0) {
        if (target.len > 0) {
            @memset(target.values, std.math.nan(f64));
            @memset(target.validity, 0);
        }
        return;
    }
    var src_idx: usize = 0;
    
    for (0..target.len) |i| {
        const ts = target.timestamps[i];
        
        // Find interval in source
        while (src_idx + 1 < source.len and source.timestamps[src_idx + 1] <= ts) {
            src_idx += 1;
        }
        
        const s_ts = source.timestamps[src_idx];
        const s_val = source.values[src_idx];
        
        if (s_ts == ts) {
            target.values[i] = s_val;
            target.validity[i] = source.validity[src_idx];
        } else if (ts < s_ts) {
            // Target is before source start
            target.values[i] = std.math.nan(f64);
            target.validity[i] = 0;
        } else {
            // ts > s_ts. We are between src_idx and src_idx + 1 (if exists)
            if (src_idx + 1 < source.len) {
                const next_ts = source.timestamps[src_idx + 1];
                const next_val = source.values[src_idx + 1];
                
                target.values[i] = switch (source.sample_mode) {
                    .Step => s_val,
                    .Linear => blk: {
                        const fraction = (ts - s_ts) / (next_ts - s_ts);
                        break :blk s_val + (next_val - s_val) * fraction;
                    },
                    .Cumulative => blk: {
                        const fraction = (ts - s_ts) / (next_ts - s_ts);
                        break :blk s_val + (next_val - s_val) * fraction;
                    },
                };
                target.validity[i] = 1;
            } else {
                // Past the end of source
                target.values[i] = switch (source.sample_mode) {
                    .Step => s_val, // LOCF
                    else => std.math.nan(f64),
                };
                target.validity[i] = if (source.sample_mode == .Step) 1 else 0;
            }
        }
    }
}

test "Alignment: Union of irregular series" {
    const allocator = std.testing.allocator;
    
    const s1 = try Series.init(allocator, 2, .Step, .{});
    defer s1.deinit();
    s1.timestamps[0] = 0; s1.values[0] = 10;
    s1.timestamps[1] = 20; s1.values[1] = 20;
    try s1.validate();
    
    const s2 = try Series.init(allocator, 2, .Linear, .{});
    defer s2.deinit();
    s2.timestamps[0] = 10; s2.values[0] = 100;
    s2.timestamps[1] = 30; s2.values[1] = 200;
    try s2.validate();
    
    const res = try alignUnion(s1, s2, allocator);
    const a = res.@"0";
    const b = res.@"1";
    defer a.deinit();
    defer b.deinit();
    
    // Timestamps: [0, 10, 20, 30]
    try std.testing.expectEqual(@as(usize, 4), a.len);
    
    // Check S1 (Step): 0->10, 10->10 (interpolated), 20->20, 30->20 (LOCF)
    try std.testing.expectEqual(@as(f64, 10.0), a.values[0]);
    try std.testing.expectEqual(@as(f64, 10.0), a.values[1]);
    try std.testing.expectEqual(@as(f64, 20.0), a.values[2]);
    try std.testing.expectEqual(@as(f64, 20.0), a.values[3]);
    
    // Check S2 (Linear): 0->NaN, 10->100, 20->150 (interpolated), 30->200
    try std.testing.expect(std.math.isNan(b.values[0]));
    try std.testing.expectEqual(@as(f64, 100.0), b.values[1]);
    try std.testing.expectEqual(@as(f64, 150.0), b.values[2]);
    try std.testing.expectEqual(@as(f64, 200.0), b.values[3]);
}
