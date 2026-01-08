const std = @import("std");
const mz = @import("mathzig");
const ts = mz.timeseries;

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const feature_id = if (args.len > 1) args[1] else "baseline";
    var ts_buf: [64]u8 = undefined;
    const now = std.time.timestamp();
    const timestamp = try std.fmt.bufPrint(&ts_buf, "{d}", .{now});

    const sizes = [_]usize{ 1_000, 1_000_000 };

    for (sizes) |size| {
        try runBenchmarks(allocator, feature_id, timestamp, size);
    }
}

fn runBenchmarks(allocator: Allocator, feature_id: []const u8, timestamp: []const u8, size: usize) !void {
    var series = try ts.Series.init(allocator, size, .Linear, .{});
    defer series.deinit();

    for (0..size) |i| {
        series.timestamps[i] = @as(f64, @floatFromInt(i));
        series.values[i] = @sin(@as(f64, @floatFromInt(i)) * 0.01);
    }
    try series.validate();
    _ = ts.sum(series, null);
    try measure(feature_id, timestamp, "zig_bench_ts_sum", size, struct {
        fn run(s: *ts.Series, a: Allocator) !void {
            _ = a;
            _ = ts.sum(s, null);
        }
    }.run, allocator, series);
    try measure(feature_id, timestamp, "zig_bench_ts_twa", size, struct {
        fn run(s: *ts.Series, a: Allocator) !void {
            _ = a;
            _ = ts.twa(s, null);
        }
    }.run, allocator, series);
    try measure(feature_id, timestamp, "zig_bench_ts_derivative", size, struct {
        fn run(s: *ts.Series, a: Allocator) !void {
            const res = try ts.derivative(s, a);
            res.deinit();
        }
    }.run, allocator, series);
    try measure(feature_id, timestamp, "zig_bench_ts_resample", size, struct {
        fn run(s: *ts.Series, a: Allocator) !void {
            const interval = (s.max_ts - s.min_ts) / 100.0;
            const res = try ts.resample(s, .{ .interval = interval }, a);
            res.deinit();
        }
    }.run, allocator, series);
}

fn measure(feature_id: []const u8, timestamp: []const u8, name: []const u8, size: usize, func: anytype, allocator: Allocator, series: *ts.Series) !void {
    const suffix = getLabelSuffix();
    var timer = try std.time.Timer.start();
    const start_ns = timer.read();
    try func(series, allocator);
    const end_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(end_ns - start_ns)) / 1_000_000.0;
    const ops_per_sec = if (duration_ms > 0) 1000.0 / duration_ms else 0.0;

    std.debug.print("{s},{s},{s}_{d}{s},1,{d:.4},{d:.2},0,0,0\n", .{
        timestamp,
        feature_id,
        name,
        size,
        suffix,
        duration_ms,
        ops_per_sec,
    });
}

fn getLabelSuffix() []const u8 {
    const raw = std.posix.getenvZ("MATHZIG_LABEL_SUFFIX") orelse return "";
    return std.mem.sliceTo(raw, 0);
}
