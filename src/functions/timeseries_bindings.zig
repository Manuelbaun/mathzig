const std = @import("std");
const Value = @import("../core/value.zig").Value;
const Matrix = @import("../core/value.zig").Matrix;
const Series = @import("../timeseries/series.zig").Series;
const Predicate = @import("../timeseries/predicates.zig").Predicate;
const calculus = @import("../timeseries/calculus.zig");
const aggs = @import("../timeseries/aggregations.zig");
const indicators = @import("../timeseries/indicators.zig");

pub fn callTimeSeriesFn(func: @import("../vm/bytecode.zig").BuiltinFn, args: []const Value, predicate: ?*const Predicate, allocator: std.mem.Allocator) !Value {
    // Helper to get series from value
    const getSeries = struct {
        fn get(val: Value) !*Series {
            if (val.isSeries()) return val.data.series;
            return error.TypeError;
        }
    }.get;

    switch (func) {
                .series => {
                    if (args.len < 1) return error.NotEnoughArgs;

                    // Vectors only: one dim must be 1 (or empty 0×0). Non-vector
                    // matrices used to OOB in Matrix.get via max(rows,cols) indexing.
                    const isVector = struct {
                        fn check(m: *const Matrix) bool {
                            return m.rows == 0 or m.cols == 0 or m.rows == 1 or m.cols == 1;
                        }
                    }.check;

                    if (args.len == 1) {
                        // Support creating series from values only (default timestamps 0, 1, 2...)
                        if (args[0].tag != .matrix) return error.TypeError;
                        const m_val = args[0].data.matrix;
                        if (!isVector(m_val)) return error.TypeError;
                        const len = @max(m_val.rows, m_val.cols);
                        const result = try Series.init(allocator, len, .Linear, .{});
                        for (0..len) |i| {
                            result.timestamps[i] = @floatFromInt(i);
                            result.values[i] = if (m_val.rows == 1) m_val.get(0, @intCast(i)) else m_val.get(@intCast(i), 0);
                        }
                        try result.validate();
                        return Value.initSeries(result);
                    }

                    // Support creating series from two matrices (vectors)
                    if (args[0].tag != .matrix or args[1].tag != .matrix) return error.TypeError;
                    const m_ts = args[0].data.matrix;
                    const m_val = args[1].data.matrix;
                    if (!isVector(m_ts) or !isVector(m_val)) return error.TypeError;

                    const len = @max(m_ts.rows, m_ts.cols);
                    if (len != @max(m_val.rows, m_val.cols)) return error.MismatchedLengths;

                    const result = try Series.init(allocator, len, .Linear, .{});
                    for (0..len) |i| {
                        result.timestamps[i] = if (m_ts.rows == 1) m_ts.get(0, @intCast(i)) else m_ts.get(@intCast(i), 0);
                        result.values[i] = if (m_val.rows == 1) m_val.get(0, @intCast(i)) else m_val.get(@intCast(i), 0);
                    }
                    try result.validate();
                    return Value.initSeries(result);
                },
        .sum => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = aggs.sum(series, predicate);
            return Value.initNumber(result);
        },
        .mean => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = aggs.mean(series, predicate);
            return Value.initNumber(result);
        },
        .min => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = aggs.min(series, predicate);
            return Value.initNumber(result);
        },
        .max => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = aggs.max(series, predicate);
            return Value.initNumber(result);
        },
        .twa => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = aggs.twa(series, predicate);
            return Value.initNumber(result);
        },
        .cumsum => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = try aggs.cumsum(series, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .cummax => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = try aggs.cummax(series, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .cummin => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = try aggs.cummin(series, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .rolling_sum => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const arg = args[1];
            // If argument is a number, it's sample-based. If it's a unit (duration), it's time-based.
            const result = if (arg.tag == .unit)
                try aggs.rollingSumDuration(series, arg.data.unit.value, allocator)
            else
                try aggs.rollingSum(series, try getUsize(arg), allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .rolling_mean => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const arg = args[1];
            const result = if (arg.tag == .unit)
                try aggs.rollingMeanDuration(series, arg.data.unit.value, allocator)
            else
                try aggs.rollingMean(series, try getUsize(arg), allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .rolling_min => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const arg = args[1];
            const result = if (arg.tag == .unit)
                try aggs.rollingMinDuration(series, arg.data.unit.value, allocator)
            else
                try aggs.rollingMin(series, try getUsize(arg), allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .rolling_max => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const arg = args[1];
            const result = if (arg.tag == .unit)
                try aggs.rollingMaxDuration(series, arg.data.unit.value, allocator)
            else
                try aggs.rollingMax(series, try getUsize(arg), allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .rolling_count => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const arg = args[1];
            const result = if (arg.tag == .unit)
                try aggs.rollingCountDuration(series, arg.data.unit.value, allocator)
            else
                try aggs.rollingCount(series, try getUsize(arg), allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .rolling_stddev => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const arg = args[1];
            const result = if (arg.tag == .unit)
                try aggs.rollingStddevDuration(series, arg.data.unit.value, allocator)
            else
                try aggs.rollingStddev(series, try getUsize(arg), allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .derivative => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = try calculus.derivative(series, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .integrate => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = try calculus.integrate(series, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .sma => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const period = try getUsize(args[1]);
            const result = try indicators.sma(series, period, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .diff => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const n = try getUsize(args[1]);
            const result = try calculus.diff(series, n, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .pct_change => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const n = try getUsize(args[1]);
            const result = try calculus.pctChange(series, n, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .ema => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const half_life = args[1].toNumber() orelse return error.TypeError;
            const result = try indicators.ema(series, half_life, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .rsi => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const period = try getUsize(args[1]);
            const result = try indicators.rsi(series, period, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .last => {
            if (args.len < 1) return error.NotEnoughArgs;
            // Matrix: return last row as 1×cols matrix (ODE trajectory tails).
            // Use the matrix's own allocator (not the session arena) so the
            // result survives arena reset / freeIntermediates interaction with
            // the delegated-call result stash.
            if (args[0].tag == .matrix) {
                const m = args[0].data.matrix;
                if (m.rows == 0) return Value.initNumber(std.math.nan(f64));
                const last_row = m.rows - 1;
                const result = try Matrix.init(m.allocator, 1, m.cols);
                errdefer result.release();
                for (0..m.cols) |c| {
                    result.set(0, @intCast(c), m.get(last_row, @intCast(c)));
                }
                return Value.initMatrix(result);
            }
            const series = try getSeries(args[0]);
            if (series.len == 0) return Value.initNumber(std.math.nan(f64));
            // Find last valid value if predicate exists, else just last
            if (predicate) |p| {
                var i: usize = series.len;
                while (i > 0) {
                    i -= 1;
                    if (p.evaluate(series, i)) return Value.initNumber(series.values[i]);
                }
                return Value.initNumber(std.math.nan(f64));
            }
            return Value.initNumber(series.values[series.len - 1]);
        },
        .duration => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            if (series.len < 2) return Value.initNumber(0);
            return Value.initNumber(series.max_ts - series.min_ts);
        },
        .asofJoin => {
            if (args.len < 2) return error.NotEnoughArgs;
            
            const target_ts: []const f64 = if (args[0].tag == .matrix) 
                args[0].data.matrix.data 
            else if (args[0].tag == .series) 
                args[0].data.series.timestamps 
            else 
                return error.TypeError;

            const s2 = try getSeries(args[1]);
            const result = try @import("../timeseries/joins.zig").asofJoin(target_ts, s2, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .resample => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const interval = args[1].toNumber() orelse return error.TypeError;
            // For now default to mean if 3rd arg is missing or just use sum
            const result = try @import("../timeseries/resampling.zig").resample(series, .{ .interval = interval, .kernel = .mean }, allocator);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .align_ => {
            if (args.len < 2) return error.NotEnoughArgs;
            const s1 = try getSeries(args[0]);
            const s2 = try getSeries(args[1]);
            // For mode, default to union if missing
            const res = try @import("../timeseries/alignment.zig").alignUnion(s1, s2, allocator);
            res.@"0".applyPredicate(predicate);
            return Value.initSeries(res.@"0");
        },
        .head => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const n = try getUsize(args[1]);
            const result = try series.head(n);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .tail => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const n = try getUsize(args[1]);
            const result = try series.tail(n);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .slice => {
            if (args.len < 3) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const start = args[1].toNumber() orelse return error.TypeError;
            const end = args[2].toNumber() orelse return error.TypeError;
            const result = try series.slice(start, end);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .between => {
            if (args.len < 3) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const start = args[1].toNumber() orelse return error.TypeError;
            const end = args[2].toNumber() orelse return error.TypeError;
            // 'between' is inclusive, 'slice' is usually [start, end)
            // But for now we use slice implementation. 
            // In a more complete implementation we'd handle inclusive boundaries.
            const result = try series.slice(start, end + 0.000000001);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .since => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const duration = args[1].toNumber() orelse return error.TypeError;
            if (series.len == 0) return Value.initSeries(try series.head(0));
            const start = series.max_ts - duration;
            const result = try series.slice(start, series.max_ts + 0.000000001);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .shift => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const n = args[1].toNumber() orelse return error.TypeError;
            const result = try series.shift(@as(i64, @intFromFloat(n)));
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .dropna => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = try series.dropna();
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .fillna => {
            if (args.len < 2) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const arg = args[1];
            
            var result: *Series = undefined;
            if (arg.tag == .number) {
                result = try series.fillnaConstant(arg.data.number);
            } else if (arg.tag == .string) {
                const method = arg.data.string.toSlice();
                if (std.mem.eql(u8, method, "forward")) {
                    result = try series.fillnaForward();
                } else if (std.mem.eql(u8, method, "backward")) {
                    result = try series.fillnaBackward();
                } else if (std.mem.eql(u8, method, "linear")) {
                    result = try series.fillnaLinear();
                } else {
                    return error.InvalidValue;
                }
            } else {
                return error.TypeError;
            }
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .clip => {
            if (args.len < 3) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const min = args[1].toNumber() orelse return error.TypeError;
            const max = args[2].toNumber() orelse return error.TypeError;
            const result = try series.clip(min, max);
            result.applyPredicate(predicate);
            return Value.initSeries(result);
        },
        .bollinger => {
            if (args.len < 3) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const period = try getUsize(args[1]);
            const mult = args[2].toNumber() orelse return error.TypeError;
            const result = try indicators.bollinger(series, period, mult, allocator);
            return Value.initRecord(result);
        },
        .macd => {
            if (args.len < 4) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const fast = try getUsize(args[1]);
            const slow = try getUsize(args[2]);
            const signal = try getUsize(args[3]);
            const result = try indicators.macd(series, fast, slow, signal, allocator);
            return Value.initRecord(result);
        },
        .size => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = getSeries(args[0]) catch return Value.initUndefined();
            return Value.initNumber(@floatFromInt(series.len));
        },
        .count => {
            if (args.len < 1) return error.NotEnoughArgs;
            const series = try getSeries(args[0]);
            const result = aggs.count(series, predicate);
            return Value.initNumber(result);
        },
        else => return error.UnknownFunction,
    }
}

fn getUsize(val: Value) !usize {
    const n = val.toNumber() orelse return error.TypeError;
    if (!std.math.isFinite(n) or n < 0 or n > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidValue;
    return @intFromFloat(n);
}
