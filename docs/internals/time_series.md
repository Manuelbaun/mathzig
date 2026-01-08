# MathZig Time-Series Technical Specification & Implementation Plan

## Executive Summary
This document defines the transition of MathZig into a high-performance **Temporal Math Engine**. It provides a unified execution environment for any data indexed by time, with a primary focus on **irregularly sampled data**, **stateful indicators** (RSI, EMA), **flexible temporal aggregation**, and **predicate-based filtering**. The engine is designed to handle non-uniform intervals efficiently using Zig's SIMD capabilities and a specialized VM architecture.

---

## 1. Internal Data Representation & Memory Layout

### Struct of Arrays (SoA) for Temporal Streams
A `Series` is a generic container for any numeric stream. The Struct of Arrays (SoA) layout is essential for SIMD throughput and allows direct mapping of memory from FFI/WASM host environments.

```zig
pub const SampleMode = enum(u8) {
    Step,       // Discrete states (e.g., boolean flags, mode switches) - LOCF interpolation
    Linear,     // Continuous measurements (e.g., sensor data, price) - Linear interpolation
    Cumulative, // Aggregated counters (e.g., pulse counters, meter readings)
};

pub const Series = struct {
    timestamps: [*]f64,    // Unix Epoch (seconds). Handles sub-millisecond precision.
    values: [*]f64,        // Numeric Samples.
    validity: [*]u8,       // Bitmask for NaN/Missing data handling.
    len: usize,
    capacity: usize,
    sample_mode: SampleMode,
    unit: Unit,            // Dimensional awareness (optional).

    // Metadata for optimization
    is_sorted: bool,       // True if timestamps are monotonically increasing
    min_ts: f64,           // Cached bounds for fast range checks
    max_ts: f64,
};
```

### Series View (Zero-Copy Slicing)
For filtered/windowed operations, we use views to avoid data copying:

```zig
pub const SeriesView = struct {
    base: *const Series,   // Reference to underlying series
    start_idx: usize,      // Start index in base series
    end_idx: usize,        // End index (exclusive)

    // Optional index array for non-contiguous views (predicate filtering)
    indices: ?[*]u32,      // If non-null, scattered access pattern
    indices_len: usize,

    pub fn len(self: *const SeriesView) usize {
        if (self.indices) |_| return self.indices_len;
        return self.end_idx - self.start_idx;
    }
};
```

---

## 2. Irregular Data & Temporal Calculus

### The `dt` (Delta Time) Register
Unlike traditional arrays where the distance between elements is 1, temporal data has a variable distance. The VM maintains a `reg_dt` register that is updated during iteration:
`reg_dt = timestamps[i] - timestamps[i-1]`.

This allows opcodes to perform calculus-based operations on irregular grids:
- **Derivatives**: `(val[i] - val[i-1]) / reg_dt`.
- **Integrals**: `(val[i] + val[i-1]) / 2.0 * reg_dt`.

### Sample Interpolation Logic
When aligning two series with different irregular timestamps, the VM uses the `SampleMode` to determine values at "missing" points:
- **LOCF (Last Observation Carried Forward)**: Preserves the last known value until a new one arrives.
- **Linear**: Calculates a weighted average between the two nearest points.

---

## 3. Predicate System & Conditional Aggregations

### Motivation
Real-world queries often need filtering:
- `twa where time > "2024-01-01"`
- `resample where value > 0`
- `sum where status == "active"`

### Predicate Types

```zig
pub const PredicateOp = enum(u8) {
    // Comparison operators
    eq,    // ==
    ne,    // !=
    lt,    // <
    le,    // <=
    gt,    // >
    ge,    // >=

    // Logical operators
    and_,
    or_,
    not_,

    // Range operators
    between,      // value BETWEEN a AND b
    in_set,       // value IN (a, b, c)

    // Temporal operators
    time_gt,      // time > T
    time_ge,      // time >= T
    time_lt,      // time < T
    time_le,      // time <= T
    time_between, // time BETWEEN T1 AND T2

    // Null/validity operators
    is_valid,     // NOT NULL / valid bit set
    is_null,      // NULL / invalid bit set
};

pub const Predicate = struct {
    op: PredicateOp,
    operands: union {
        // For comparison: value vs constant
        cmp: struct { field: Field, value: f64 },
        // For between: value between low and high
        range: struct { field: Field, low: f64, high: f64 },
        // For logical: combine predicates
        logical: struct { left: *Predicate, right: ?*Predicate },
    },
};

pub const Field = enum(u8) {
    timestamp,  // Compare against timestamp
    value,      // Compare against value
    dt,         // Compare against delta-time (gap)
};
```

### Predicate Evaluation Strategies

**Strategy 1: Bitmap Pre-filtering (Best for large datasets)**
```zig
pub fn evaluatePredicate(series: *const Series, pred: *const Predicate) Bitmap {
    // Generate a bitmap of matching indices
    // SIMD-accelerated comparison
    var bitmap = Bitmap.init(series.len);

    // Vectorized evaluation for simple predicates
    switch (pred.op) {
        .time_gt => {
            const threshold = pred.operands.cmp.value;
            simdCompareGt(series.timestamps, threshold, bitmap.data);
        },
        // ... other operators
    }
    return bitmap;
}
```

**Strategy 2: Lazy Iteration (Best for streaming)**
```zig
pub const FilteredIterator = struct {
    series: *const Series,
    predicate: *const Predicate,
    current_idx: usize,

    pub fn next(self: *FilteredIterator) ?Sample {
        while (self.current_idx < self.series.len) {
            const idx = self.current_idx;
            self.current_idx += 1;
            if (self.predicate.evaluate(self.series, idx)) {
                return Sample{
                    .ts = self.series.timestamps[idx],
                    .value = self.series.values[idx],
                };
            }
        }
        return null;
    }
};
```

### Syntax for Conditional Aggregations

```js
// Time-based filtering
result = twa(sensor_data) where time >= "2024-01-01" and time < "2024-02-01"

// Value-based filtering
positive_sum = sum(values) where value > 0

// Combined predicates
filtered = resample(data, 1h, "mean") where value > 0 and time >= start_time

// Gap filtering (skip large gaps)
clean_derivative = derivative(position) where dt < 10s

// Validity filtering (explicit)
valid_avg = mean(readings) where is_valid

// Range syntax shorthand
monthly = twa(data, from: "2024-01-01", to: "2024-02-01")
```

### Implementation: Aggregation with Predicate

```zig
pub fn twaWithPredicate(
    series: *const Series,
    predicate: ?*const Predicate,
    window: ?Duration,
) f64 {
    var weighted_sum: f64 = 0;
    var total_duration: f64 = 0;
    var prev_ts: f64 = undefined;
    var prev_val: f64 = undefined;
    var first = true;

    var i: usize = 0;
    while (i < series.len) : (i += 1) {
        // Skip if predicate doesn't match
        if (predicate) |p| {
            if (!p.evaluate(series, i)) continue;
        }

        const ts = series.timestamps[i];
        const val = series.values[i];

        if (!first) {
            const dt = ts - prev_ts;
            // Trapezoidal rule for irregular data
            weighted_sum += (val + prev_val) / 2.0 * dt;
            total_duration += dt;
        }

        prev_ts = ts;
        prev_val = val;
        first = false;
    }

    return if (total_duration > 0) weighted_sum / total_duration else 0;
}
```

---

## 4. Specialized Indicators & Window Kernels

### Stateful Indicator Kernels (O(1))
Indicators like RSI or EMA require maintaining state across samples. MathZig implements these as recursive kernels to avoid $O(N \times W)$ overhead.

- **RSI (Relative Strength Index)**:
    - Maintains `avg_gain` and `avg_loss` in the VM state buffer.
    - Uses $1/W$ smoothing, updated per sample regardless of interval.
- **EMA (Exponential Moving Average)**:
    - Standard: `alpha * val + (1 - alpha) * prev`.
    - Time-Decay EMA: Adjusts `alpha` based on `reg_dt` to handle irregular gaps fairly.

### Time-Decay EMA for Irregular Data

```zig
pub fn timeDecayEma(
    series: *const Series,
    half_life: f64,  // Time for weight to decay to 50%
) Series {
    var result = Series.init(series.len);
    var prev_ema: f64 = series.values[0];
    result.values[0] = prev_ema;

    for (1..series.len) |i| {
        const dt = series.timestamps[i] - series.timestamps[i-1];
        // Alpha decays exponentially with time gap
        const alpha = 1.0 - @exp(-dt * std.math.ln(2.0) / half_life);
        prev_ema = alpha * series.values[i] + (1.0 - alpha) * prev_ema;
        result.values[i] = prev_ema;
    }
    return result;
}
```

### Sliding Windows

**Sample-based**: Fixed number of elements.
**Duration-based**: Variable number of elements depending on the density.

```zig
pub const Window = union(enum) {
    samples: usize,        // Last N samples
    duration: f64,         // Last T seconds

    // Advanced windows
    expanding: void,       // From start to current
    session: SessionDef,   // Gap-based sessions
};

pub const SessionDef = struct {
    max_gap: f64,          // New session if gap > max_gap
    min_samples: usize,    // Minimum samples per session
};
```

---

## 5. User-Defined Bucketing & Resampling

### Flexible Alignment
The engine does not hardcode intervals (like 15m). Users define arbitrary durations (e.g., `1s`, `500ms`, `12.5m`, `1d`).

- **Dynamic Bucketing**: `bucket_id = floor((timestamp + tz_offset) / user_interval)`.
- **Custom Aggregators**: Users specify the kernel used to collapse data within a bucket.

### Aggregation Kernels

```zig
pub const AggKernel = enum(u8) {
    // Basic
    first,
    last,
    min,
    max,
    sum,
    count,

    // Statistical
    mean,           // Simple arithmetic mean
    twa,            // Time-weighted average (for irregular data)
    median,         // Requires sorting or streaming algorithm
    stddev,         // Standard deviation
    variance,

    // Financial (OHLC)
    open,           // First value in bucket
    high,           // Maximum value
    low,            // Minimum value
    close,          // Last value in bucket
    vwap,           // Volume-weighted average price

    // Advanced
    integral,       // Area under curve (trapezoidal)
    derivative,     // Rate of change at bucket boundary
    percentile,     // Nth percentile (parameterized)
};
```

### Resampling with Predicates

```zig
pub fn resample(
    series: *const Series,
    interval: f64,
    kernel: AggKernel,
    predicate: ?*const Predicate,
    options: ResampleOptions,
) Series {
    // ... implementation
}

pub const ResampleOptions = struct {
    tz_offset: f64 = 0,           // Timezone offset in seconds
    origin: f64 = 0,              // Bucket origin timestamp
    closed: BucketEdge = .left,   // Which edge is closed
    label: BucketEdge = .left,    // Which edge to use as label
    empty_bucket: EmptyBucket = .skip,
};

pub const BucketEdge = enum { left, right };
pub const EmptyBucket = enum { skip, fill_null, fill_zero, interpolate };
```

### Time-Weighted Average (TWA)
For irregular data, a simple arithmetic mean is incorrect. MathZig uses:
`TWA = Sum(Value[i] * dt[i]) / Total_Duration`.
This ensures that a value lasting for 90% of the bucket carries 90% of the weight.

---

## 6. Range Queries & Time Selection

### Range Expression Syntax

```js
// Explicit range
data[time >= "2024-01-01" and time < "2024-02-01"]

// Shorthand range
data["2024-01-01":"2024-02-01"]

// Relative ranges
data[time > now() - 1h]
data.last(100)           // Last 100 samples
data.since(1h)           // Last 1 hour

// Named ranges
data.today()
data.this_week()
data.last_month()
```

### Range Implementation

```zig
pub const TimeRange = struct {
    start: ?f64,           // Inclusive start (null = unbounded)
    end: ?f64,             // Exclusive end (null = unbounded)

    pub fn contains(self: TimeRange, ts: f64) bool {
        if (self.start) |s| if (ts < s) return false;
        if (self.end) |e| if (ts >= e) return false;
        return true;
    }

    // Optimized: binary search for sorted series
    pub fn findBounds(self: TimeRange, series: *const Series) struct { start: usize, end: usize } {
        const start_idx = if (self.start) |s|
            binarySearchGe(series.timestamps, s)
        else
            0;
        const end_idx = if (self.end) |e|
            binarySearchLt(series.timestamps, e)
        else
            series.len;
        return .{ .start = start_idx, .end = end_idx };
    }
};
```

---

## 7. Series Alignment & Joins

### Alignment Modes

When operating on multiple series with different timestamps:

```zig
pub const AlignMode = enum {
    union_,       // All timestamps from both series
    intersect,    // Only common time ranges
    left,         // Align to left series timestamps
    right,        // Align to right series timestamps
    asof,         // Point-in-time lookup (no future data)
};
```

### Join Operations

```js
// Align two series and compute ratio
ratio = align(price, volume, mode: "union").price / .volume

// As-of join (financial: get last known value at each point)
filled_price = asof_join(sparse_quotes, regular_timestamps)

// Interpolated alignment
aligned = align(sensor_a, sensor_b, interpolate: "linear")
```

---

## 8. Streaming & Persistence

### The Stream State Buffer
To support real-time processing, the VM allocates a persistent state buffer for each stream.

```zig
pub const IndicatorState = struct {
    // Core state
    prev_value: f64,
    accumulator: f64,
    count: u64,
    last_ts: f64,

    // EMA state
    ema_value: f64,

    // RSI state
    avg_gain: f64,
    avg_loss: f64,

    // Duration-based window state
    ring_buffer: ?RingBuffer,

    // Bucket accumulator state
    bucket_id: i64,
    bucket_sum: f64,
    bucket_count: u64,
    bucket_min: f64,
    bucket_max: f64,
    bucket_first: f64,
    bucket_last: f64,
    bucket_weighted_sum: f64,
    bucket_duration: f64,
};

pub const RingBuffer = struct {
    data: []f64,
    timestamps: []f64,
    head: usize,
    tail: usize,
    capacity: usize,
};
```

### Snapshots
The state of any complex calculation can be exported as a binary blob for resumption.

```zig
pub fn serializeState(state: *const IndicatorState) []u8 {
    // Serialize to binary for persistence/transfer
}

pub fn deserializeState(data: []const u8) IndicatorState {
    // Restore from binary
}
```

---

## 9. VM Extensions for Time-Series

### New Opcodes

```zig
pub const TimeSeriesOp = enum(u8) {
    // Series creation
    series_create,        // Create empty series
    series_from_arrays,   // Create from timestamp/value arrays

    // Filtering
    series_filter,        // Apply predicate, create view
    series_range,         // Time range selection

    // Aggregations
    series_twa,           // Time-weighted average
    series_resample,      // Bucket and aggregate
    series_sum,           // Sum with optional predicate
    series_mean,          // Mean with optional predicate

    // Indicators
    series_ema,           // Exponential moving average
    series_sma,           // Simple moving average
    series_rsi,           // Relative strength index
    series_derivative,    // Rate of change
    series_integral,      // Cumulative integral

    // Alignment
    series_align,         // Align multiple series
    series_join_asof,     // As-of join

    // Iteration
    series_iter_start,    // Begin iteration
    series_iter_next,     // Get next sample
    series_iter_dt,       // Get current dt
};
```

### New VM Registers

```zig
// Add to VM struct
reg_dt: f64,              // Current delta-time
reg_ts: f64,              // Current timestamp
reg_series_idx: usize,    // Current series iteration index
active_predicate: ?*Predicate,  // Current filter predicate
```

---

## 10. Generalized Syntax Examples

### Flexible Aggregation
```js
// Resample to a user-defined 7.5 minute bucket
resampled = resample(input, 7.5m, "mean")

// Time-weighted average over the last 12 hours
rolling_avg = twa(sensor_data, 12h)

// Conditional aggregation
positive_twa = twa(readings) where value > 0
recent_avg = mean(data) where time >= now() - 24h
```

### Range Queries
```js
// Time range selection
january_data = data["2024-01-01":"2024-02-01"]

// Relative time
last_hour = data[time > now() - 1h]

// Combined with aggregation
january_avg = mean(data["2024-01-01":"2024-02-01"])
```

### Specialized Indicators
```js
// Relative Strength Index (Standard 14-period)
strength = rsi(price, 14)

// Bollinger Bands (Manual construction)
mid = sma(price, 20)
upper = mid + 2 * stddev(price, 20)

// Time-decay EMA for irregular data
smoothed = ema(sensor, half_life: 5m)
```

### Irregular Math
```js
// Rate of change per second (Derivative)
velocity = derivative(position)

// Total accumulation (Integral)
total_volume = integrate(flow_rate)

// Skip large gaps in derivative
velocity = derivative(position) where dt < 60s
```

### Multi-Series Operations
```js
// Align and compute
ratio = (series_a / series_b) aligned by "union"

// As-of join
filled = asof_join(sparse, dense)
```

---

## 11. Error Handling & Edge Cases

### Gap Handling Policies

```zig
pub const GapPolicy = enum {
    propagate,     // Gaps in input → gaps in output
    skip,          // Skip gaps entirely
    interpolate,   // Fill gaps with interpolated values
    fill_value,    // Fill with a constant
    fill_forward,  // LOCF
    fill_backward, // Next observation carried backward
};
```

### Empty Series Handling

```zig
pub const EmptyPolicy = enum {
    return_null,   // Return null/undefined
    return_nan,    // Return NaN
    return_zero,   // Return 0
    error,         // Raise an error
};
```

---

## 12. Performance Considerations

### SIMD Vectorization for Predicates

```zig
// Vectorized predicate evaluation (4x f64 per iteration)
fn simdTimeGt(timestamps: [*]const f64, threshold: f64, result: [*]u8, len: usize) void {
    const threshold_vec = @splat(4, threshold);
    var i: usize = 0;
    while (i + 4 <= len) : (i += 4) {
        const ts_vec = @as(@Vector(4, f64), timestamps[i..][0..4].*);
        const mask = ts_vec > threshold_vec;
        // Pack 4 bools into nibble
        result[i / 8] |= @intCast(u8, @ptrCast(*const u4, &mask).*) << @intCast(u3, (i % 8));
    }
    // Scalar tail...
}
```

### Index Acceleration

For large series with frequent range queries:

```zig
pub const TimeIndex = struct {
    // B-tree or segment tree for O(log n) range lookups
    // Sparse index: store every Nth timestamp with offset
    checkpoints: []struct { ts: f64, idx: usize },
    checkpoint_interval: usize,
};
```

---

## 13. Reference Implementations

This section provides working Zig implementations for the core functions.

### 13.1 Error Handling

```zig
pub const TimeSeriesError = error{
    // Validation
    EmptySeries,
    MismatchedLengths,
    UnsortedTimestamps,
    NaNTimestamp,

    // Operations
    InsufficientData,
    InvalidWindow,
    InvalidInterval,

    // Memory
    OutOfMemory,
};

pub fn validateSeries(series: *const Series) TimeSeriesError!void {
    if (series.len == 0) return;

    // Check sorted
    for (1..series.len) |i| {
        if (series.timestamps[i] <= series.timestamps[i - 1]) {
            return TimeSeriesError.UnsortedTimestamps;
        }
    }

    // Check no NaN timestamps
    for (series.timestamps[0..series.len]) |ts| {
        if (std.math.isNan(ts)) {
            return TimeSeriesError.NaNTimestamp;
        }
    }
}
```

### 13.2 Predicate Evaluation

```zig
pub const Predicate = struct {
    op: PredicateOp,
    field: Field,
    value: f64,
    value2: f64 = 0,  // For 'between'
    left: ?*Predicate = null,
    right: ?*Predicate = null,

    pub fn evaluate(self: *const Predicate, series: *const Series, idx: usize) bool {
        const v = switch (self.field) {
            .timestamp => series.timestamps[idx],
            .value => series.values[idx],
            .dt => if (idx > 0) series.timestamps[idx] - series.timestamps[idx - 1] else 0,
        };

        return switch (self.op) {
            .gt, .time_gt => v > self.value,
            .ge, .time_ge => v >= self.value,
            .lt, .time_lt => v < self.value,
            .le, .time_le => v <= self.value,
            .eq => v == self.value,
            .ne => v != self.value,
            .between, .time_between => v >= self.value and v <= self.value2,
            .and_ => self.left.?.evaluate(series, idx) and self.right.?.evaluate(series, idx),
            .or_ => self.left.?.evaluate(series, idx) or self.right.?.evaluate(series, idx),
            .not_ => !self.left.?.evaluate(series, idx),
            .is_valid => !std.math.isNan(series.values[idx]),
            .is_null => std.math.isNan(series.values[idx]),
            else => true,
        };
    }
};

/// SIMD-accelerated bitmap evaluation for simple predicates
pub fn evaluatePredicateBitmap(
    series: *const Series,
    pred: *const Predicate,
    allocator: std.mem.Allocator,
) ![]u8 {
    const bitmap_len = (series.len + 7) / 8;
    const bitmap = try allocator.alloc(u8, bitmap_len);
    @memset(bitmap, 0);

    // Fast path: simple value comparison with SIMD
    if (pred.field == .value and pred.op == .gt) {
        const threshold = pred.value;
        var i: usize = 0;

        // SIMD loop (4x f64)
        while (i + 4 <= series.len) : (i += 4) {
            const vec: @Vector(4, f64) = series.values[i..][0..4].*;
            const mask = vec > @as(@Vector(4, f64), @splat(threshold));
            const bits = @as(u4, @bitCast(mask));
            bitmap[i / 8] |= @as(u8, bits) << @as(u3, @truncate(i % 8));
        }

        // Scalar tail
        while (i < series.len) : (i += 1) {
            if (series.values[i] > threshold) {
                bitmap[i / 8] |= @as(u8, 1) << @as(u3, @truncate(i % 8));
            }
        }
    } else {
        // Fallback: scalar evaluation
        for (0..series.len) |i| {
            if (pred.evaluate(series, i)) {
                bitmap[i / 8] |= @as(u8, 1) << @as(u3, @truncate(i % 8));
            }
        }
    }

    return bitmap;
}
```

### 13.3 Aggregations

```zig
pub fn sum(series: *const Series, pred: ?*const Predicate) f64 {
    var total: f64 = 0;
    for (0..series.len) |i| {
        if (pred == null or pred.?.evaluate(series, i)) {
            if (!std.math.isNan(series.values[i])) {
                total += series.values[i];
            }
        }
    }
    return total;
}

pub fn mean(series: *const Series, pred: ?*const Predicate) f64 {
    var total: f64 = 0;
    var n: usize = 0;
    for (0..series.len) |i| {
        if (pred == null or pred.?.evaluate(series, i)) {
            if (!std.math.isNan(series.values[i])) {
                total += series.values[i];
                n += 1;
            }
        }
    }
    return if (n > 0) total / @as(f64, @floatFromInt(n)) else std.math.nan(f64);
}

pub fn seriesMin(series: *const Series, pred: ?*const Predicate) f64 {
    var result: f64 = std.math.inf(f64);
    for (0..series.len) |i| {
        if (pred == null or pred.?.evaluate(series, i)) {
            if (!std.math.isNan(series.values[i]) and series.values[i] < result) {
                result = series.values[i];
            }
        }
    }
    return result;
}

pub fn seriesMax(series: *const Series, pred: ?*const Predicate) f64 {
    var result: f64 = -std.math.inf(f64);
    for (0..series.len) |i| {
        if (pred == null or pred.?.evaluate(series, i)) {
            if (!std.math.isNan(series.values[i]) and series.values[i] > result) {
                result = series.values[i];
            }
        }
    }
    return result;
}

pub fn count(series: *const Series, pred: ?*const Predicate) usize {
    var n: usize = 0;
    for (0..series.len) |i| {
        if (pred == null or pred.?.evaluate(series, i)) {
            if (!std.math.isNan(series.values[i])) {
                n += 1;
            }
        }
    }
    return n;
}

/// Time-Weighted Average - the key function for irregular time-series
pub fn twa(series: *const Series, pred: ?*const Predicate) f64 {
    var weighted_sum: f64 = 0;
    var total_duration: f64 = 0;
    var prev_ts: f64 = undefined;
    var prev_val: f64 = undefined;
    var first = true;

    for (0..series.len) |i| {
        if (pred != null and !pred.?.evaluate(series, i)) continue;
        if (std.math.isNan(series.values[i])) continue;

        const ts = series.timestamps[i];
        const val = series.values[i];

        if (!first) {
            const dt = ts - prev_ts;
            // Trapezoidal rule for irregular data
            weighted_sum += (val + prev_val) / 2.0 * dt;
            total_duration += dt;
        }

        prev_ts = ts;
        prev_val = val;
        first = false;
    }

    return if (total_duration > 0) weighted_sum / total_duration else std.math.nan(f64);
}
```

### 13.4 Calculus Operations

```zig
/// Derivative: rate of change per second (irregular-aware)
pub fn derivative(series: *const Series, allocator: std.mem.Allocator) !*Series {
    if (series.len < 2) return TimeSeriesError.InsufficientData;

    const result = try allocator.create(Series);
    result.timestamps = try allocator.alloc(f64, series.len - 1);
    result.values = try allocator.alloc(f64, series.len - 1);
    result.len = series.len - 1;
    result.allocator = allocator;

    for (1..series.len) |i| {
        const dt = series.timestamps[i] - series.timestamps[i - 1];
        result.timestamps[i - 1] = series.timestamps[i];
        result.values[i - 1] = (series.values[i] - series.values[i - 1]) / dt;
    }

    return result;
}

/// Integral: cumulative area under curve (trapezoidal rule)
pub fn integrate(series: *const Series, allocator: std.mem.Allocator) !*Series {
    const result = try allocator.create(Series);
    result.timestamps = try allocator.alloc(f64, series.len);
    result.values = try allocator.alloc(f64, series.len);
    result.len = series.len;
    result.allocator = allocator;

    if (series.len == 0) return result;

    var cumulative: f64 = 0;
    result.values[0] = 0;
    result.timestamps[0] = series.timestamps[0];

    for (1..series.len) |i| {
        const dt = series.timestamps[i] - series.timestamps[i - 1];
        cumulative += (series.values[i] + series.values[i - 1]) / 2.0 * dt;
        result.values[i] = cumulative;
        result.timestamps[i] = series.timestamps[i];
    }

    return result;
}
```

### 13.5 Technical Indicators

```zig
/// EMA with time-decay for irregular data
pub fn ema(
    series: *const Series,
    half_life_seconds: f64,
    allocator: std.mem.Allocator,
) !*Series {
    const result = try allocator.create(Series);
    result.timestamps = try allocator.alloc(f64, series.len);
    result.values = try allocator.alloc(f64, series.len);
    result.len = series.len;
    result.allocator = allocator;

    if (series.len == 0) return result;

    var prev_ema: f64 = series.values[0];
    result.values[0] = prev_ema;
    result.timestamps[0] = series.timestamps[0];

    const ln2 = std.math.ln(@as(f64, 2.0));

    for (1..series.len) |i| {
        const dt = series.timestamps[i] - series.timestamps[i - 1];
        // Alpha decays exponentially with time gap
        const alpha = 1.0 - @exp(-dt * ln2 / half_life_seconds);
        prev_ema = alpha * series.values[i] + (1.0 - alpha) * prev_ema;
        result.values[i] = prev_ema;
        result.timestamps[i] = series.timestamps[i];
    }

    return result;
}

/// SMA with ring buffer
pub fn sma(
    series: *const Series,
    period: usize,
    allocator: std.mem.Allocator,
) !*Series {
    const result = try allocator.create(Series);
    result.timestamps = try allocator.alloc(f64, series.len);
    result.values = try allocator.alloc(f64, series.len);
    result.len = series.len;
    result.allocator = allocator;

    var ring_sum: f64 = 0;

    for (0..series.len) |i| {
        ring_sum += series.values[i];
        if (i >= period) {
            ring_sum -= series.values[i - period];
        }

        result.timestamps[i] = series.timestamps[i];
        if (i >= period - 1) {
            result.values[i] = ring_sum / @as(f64, @floatFromInt(period));
        } else {
            result.values[i] = std.math.nan(f64);  // Not enough data
        }
    }

    return result;
}

/// RSI with Wilder smoothing
pub fn rsi(
    series: *const Series,
    period: usize,
    allocator: std.mem.Allocator,
) !*Series {
    const result = try allocator.create(Series);
    result.timestamps = try allocator.alloc(f64, series.len);
    result.values = try allocator.alloc(f64, series.len);
    result.len = series.len;
    result.allocator = allocator;

    if (series.len < period + 1) {
        for (0..series.len) |i| {
            result.timestamps[i] = series.timestamps[i];
            result.values[i] = std.math.nan(f64);
        }
        return result;
    }

    var avg_gain: f64 = 0;
    var avg_loss: f64 = 0;

    // Initialize first period
    for (1..period + 1) |i| {
        const change = series.values[i] - series.values[i - 1];
        if (change > 0) {
            avg_gain += change;
        } else {
            avg_loss -= change;
        }
    }

    avg_gain /= @as(f64, @floatFromInt(period));
    avg_loss /= @as(f64, @floatFromInt(period));

    // Fill initial NaN
    for (0..period) |i| {
        result.timestamps[i] = series.timestamps[i];
        result.values[i] = std.math.nan(f64);
    }

    // Calculate RSI
    for (period..series.len) |i| {
        const change = series.values[i] - series.values[i - 1];
        const gain = if (change > 0) change else 0;
        const loss = if (change < 0) -change else 0;

        // Wilder smoothing
        const period_f = @as(f64, @floatFromInt(period));
        avg_gain = (avg_gain * (period_f - 1) + gain) / period_f;
        avg_loss = (avg_loss * (period_f - 1) + loss) / period_f;

        result.timestamps[i] = series.timestamps[i];
        if (avg_loss == 0) {
            result.values[i] = 100;
        } else {
            const rs = avg_gain / avg_loss;
            result.values[i] = 100 - (100 / (1 + rs));
        }
    }

    return result;
}
```

### 13.6 Resampling

```zig
pub const AggKernel = enum {
    first,
    last,
    min,
    max,
    sum,
    mean,
    twa,
    count,
};

pub const ResampleOptions = struct {
    interval_seconds: f64,
    kernel: AggKernel = .twa,
    origin: f64 = 0,
    empty_value: f64 = std.math.nan(f64),
};

pub fn resample(
    series: *const Series,
    options: ResampleOptions,
    pred: ?*const Predicate,
    allocator: std.mem.Allocator,
) !*Series {
    if (series.len == 0) {
        const result = try allocator.create(Series);
        result.len = 0;
        return result;
    }

    // Calculate bucket bounds
    const start = @floor((series.timestamps[0] - options.origin) / options.interval_seconds) * options.interval_seconds + options.origin;
    const end = series.timestamps[series.len - 1];
    const num_buckets = @as(usize, @intFromFloat(@ceil((end - start) / options.interval_seconds))) + 1;

    const result = try allocator.create(Series);
    result.timestamps = try allocator.alloc(f64, num_buckets);
    result.values = try allocator.alloc(f64, num_buckets);
    result.allocator = allocator;

    // Temporary storage for bucket values
    var bucket_values = std.ArrayList(f64).init(allocator);
    defer bucket_values.deinit();

    var bucket_idx: usize = 0;
    var bucket_start = start;

    for (0..series.len) |i| {
        if (pred != null and !pred.?.evaluate(series, i)) continue;

        const ts = series.timestamps[i];

        // Move to correct bucket
        while (ts >= bucket_start + options.interval_seconds and bucket_idx < num_buckets) {
            result.timestamps[bucket_idx] = bucket_start;
            result.values[bucket_idx] = aggregateBucket(bucket_values.items, options.kernel, options.empty_value);
            bucket_values.clearRetainingCapacity();
            bucket_idx += 1;
            bucket_start += options.interval_seconds;
        }

        if (bucket_idx < num_buckets) {
            try bucket_values.append(series.values[i]);
        }
    }

    // Finalize last bucket
    if (bucket_idx < num_buckets) {
        result.timestamps[bucket_idx] = bucket_start;
        result.values[bucket_idx] = aggregateBucket(bucket_values.items, options.kernel, options.empty_value);
        bucket_idx += 1;
    }

    result.len = bucket_idx;
    return result;
}

fn aggregateBucket(values: []const f64, kernel: AggKernel, empty_value: f64) f64 {
    if (values.len == 0) return empty_value;

    return switch (kernel) {
        .first => values[0],
        .last => values[values.len - 1],
        .min => blk: {
            var m: f64 = values[0];
            for (values[1..]) |v| if (v < m) { m = v; };
            break :blk m;
        },
        .max => blk: {
            var m: f64 = values[0];
            for (values[1..]) |v| if (v > m) { m = v; };
            break :blk m;
        },
        .sum => blk: {
            var s: f64 = 0;
            for (values) |v| s += v;
            break :blk s;
        },
        .mean, .twa => blk: {
            var s: f64 = 0;
            for (values) |v| s += v;
            break :blk s / @as(f64, @floatFromInt(values.len));
        },
        .count => @as(f64, @floatFromInt(values.len)),
    };
}
```

### 13.7 Wire Protocol (FFI/WASM)

```zig
pub const WireHeader = packed struct {
    magic: u32 = 0x4D5A5453,  // "MZTS"
    version: u16 = 1,
    flags: u16 = 0,
    num_samples: u64,
    sample_mode: u8,
    _reserved: [7]u8 = .{0} ** 7,
};

pub fn serializeToWire(series: *const Series, allocator: std.mem.Allocator) ![]u8 {
    const header_size = @sizeOf(WireHeader);
    const data_size = series.len * 16;  // 8 bytes ts + 8 bytes val
    const total_size = header_size + data_size;

    const buffer = try allocator.alloc(u8, total_size);

    // Write header
    const header = WireHeader{
        .num_samples = series.len,
        .sample_mode = @intFromEnum(series.sample_mode),
    };
    @memcpy(buffer[0..header_size], std.mem.asBytes(&header));

    // Write timestamps
    const ts_bytes = std.mem.sliceAsBytes(series.timestamps[0..series.len]);
    @memcpy(buffer[header_size..][0..ts_bytes.len], ts_bytes);

    // Write values
    const val_bytes = std.mem.sliceAsBytes(series.values[0..series.len]);
    @memcpy(buffer[header_size + ts_bytes.len ..][0..val_bytes.len], val_bytes);

    return buffer;
}

pub fn deserializeFromWire(buffer: []const u8, allocator: std.mem.Allocator) !*Series {
    const header_size = @sizeOf(WireHeader);
    if (buffer.len < header_size) return error.InvalidData;

    const header: *const WireHeader = @ptrCast(@alignCast(buffer.ptr));
    if (header.magic != 0x4D5A5453) return error.InvalidMagic;

    const num_samples = header.num_samples;
    const expected_size = header_size + num_samples * 16;
    if (buffer.len < expected_size) return error.InvalidData;

    const series = try allocator.create(Series);
    series.timestamps = try allocator.alloc(f64, num_samples);
    series.values = try allocator.alloc(f64, num_samples);
    series.len = num_samples;
    series.sample_mode = @enumFromInt(header.sample_mode);
    series.allocator = allocator;

    const ts_start = header_size;
    const val_start = header_size + num_samples * 8;

    @memcpy(
        std.mem.sliceAsBytes(series.timestamps),
        buffer[ts_start..][0 .. num_samples * 8],
    );
    @memcpy(
        std.mem.sliceAsBytes(series.values),
        buffer[val_start..][0 .. num_samples * 8],
    );

    return series;
}
```

### 13.8 Performance Targets

| Operation | 1K samples | 1M samples | 10M samples |
|-----------|------------|------------|-------------|
| `sum()` | <1μs | <100μs | <1ms |
| `twa()` | <5μs | <500μs | <5ms |
| `derivative()` | <5μs | <500μs | <5ms |
| `resample(1h)` | <10μs | <1ms | <10ms |
| `ema(20)` | <5μs | <500μs | <5ms |
| `rsi(14)` | <10μs | <1ms | <10ms |

Memory: 16 bytes/sample (8 ts + 8 val) + 1 bit validity overhead.

---

## 14. Implementation Roadmap

### Phase 1: Core Data Structures
- [x] `Series` struct with SoA layout
- [x] `SeriesView` for zero-copy slicing
- [x] Basic memory management and allocation
- [x] Series validation logic (sorted, NaN)

### Phase 2: Irregular-Aware Arithmetic
- [x] Derivative function (irregular-aware)
- [x] Integral function (trapezoidal rule)
- [x] Series arithmetic (add, sub, mul, div with alignment)
- [ ] `dt` register implementation in VM (internal optimization)

### Phase 3: Predicate System
- [x] `Predicate` struct and evaluation
- [x] Time-based predicates (time >, time <, etc.)
- [x] Value-based predicates
- [x] Bitmap-based filtering (Initial SIMD optimization)
- [x] `where` clause parsing in compiler

### Phase 4: Aggregations & Indicators
- [x] Basic aggregations (sum, mean, min, max, count)
- [x] Time-weighted average (TWA)
- [x] EMA with time-decay (irregular-aware)
- [x] SMA with sample windows
- [x] RSI indicator (Wilder's)

### Phase 5: Resampling & Bucketing
- [x] Bucket calculation with custom intervals
- [x] Aggregation kernels (first, last, min, max, sum, mean, count)
- [ ] Timezone-aware bucketing
- [ ] Empty bucket policies (fill zero, interpolate, etc.)

### Phase 6: Advanced Features
- [x] As-of joins
- [x] Series alignment (Union Alignment with Linear/Step interpolation)
- [ ] Streaming state management
- [ ] State serialization/deserialization

### Phase 7: VM & TUI Integration
- [x] `Series` Value type in VM
- [x] Function bindings (twa, derivative, rsi, etc.)
- [x] VM memory tracking for Series cleanup
- [x] TUI string formatting for Series
- [x] TUI sparkline visualization for Series
- [x] DSL `series(t, v)` constructor
- [x] C ABI exports for series operations (integer handles)
- [x] WASM bindings

### Phase 8: Performance & Parallelism
- [ ] **SIMD Aggregations:** Implement `@Vector` kernels for `sum`, `mean`, `max`.
- [ ] **SIMD Calculus:** Vectorize `derivative` and `integrate` logic.
- [ ] **Parallel Aggregations:** Multi-threaded `parSum`, `parTwa`.
- [ ] **Parallel Resampling:** Multi-threaded bucket calculation.
- [ ] **Parallel Joins:** Multi-threaded as-of lookup for large arrays.
- [ ] **Prefetching:** Add `std.mem.prefetch` hints for large series scans.


---

## 14. Testing Strategy

### Unit Tests
- Predicate evaluation correctness
- Aggregation accuracy vs reference implementation
- Edge cases: empty series, single element, all NaN

### Property-Based Tests
- TWA(constant) == constant
- sum(a) + sum(b) == sum(concat(a, b))
- derivative(integral(x)) ≈ x (within tolerance)

### Benchmarks
- Predicate evaluation throughput (samples/sec)
- TWA on 1M irregular samples
- Resampling performance vs. pandas/polars

---

## DSL Reference

> **See [dsl_spec.md](./dsl_spec.md) for the complete, authoritative DSL specification.**
>
> The DSL spec contains:
> - Complete function reference with signatures
> - Formal grammar (EBNF)
> - Operator precedence
> - Predicate syntax including time component access (`time.hour`, etc.)
> - Consistent naming conventions and design principles

---

## Appendix A: Example Workflows

### A.1 Sensor Data Processing
```js
// Load irregular sensor data
raw = load_series("temperature_sensor")

// Clean: remove outliers and fill gaps
clipped = clip(raw, percentile(raw, 1), percentile(raw, 99))
cleaned = fillna(clipped, "linear")

// Resample to regular 5-minute intervals (TWA for irregular data)
regular = resample(cleaned, 5m, "twa")

// Calculate hourly statistics
hourly_mean = resample(regular, 1h, "mean")
hourly_max = resample(regular, 1h, "max")
hourly_min = resample(regular, 1h, "min")

// Detect anomalies (Z-score > 3)
mu = rolling_mean(regular, 24h)
sigma = rolling_stddev(regular, 24h)
z_score = (regular - mu) / sigma
// Filter using where clause
anomaly_count = count(regular) where abs(value) > 3
```

### A.2 Financial Analysis
```js
// Load tick data and create OHLC bars
{open, high, low, close, volume} = ohlc(load_series("ticks"), 1h)

// Technical indicators
sma_20 = sma(close, 20)
sma_50 = sma(close, 50)
rsi_14 = rsi(close, 14)
{upper, middle, lower} = bollinger(close, 20, 2)

// Signals using where clause
oversold_count = count(rsi_14) where value < 30

// Risk metrics
returns = pct_change(close)
volatility = rolling_stddev(returns, 20) * sqrt(252)
drawdown = close / cummax(close) - 1
max_dd = min(drawdown)
```

### A.3 IoT Energy Processing
```js
// Power consumption (irregular samples, step interpolation)
power = load_series("power_meter", mode: "step")

// Energy: integral of power over time (W*s -> kWh)
energy_joules = integrate(power)
energy_kwh = energy_joules / 3600000

// Daily consumption
daily = resample(energy_kwh, 1d, "last")
daily_delta = daily - shift(daily, 1)

// Peak demand (15-min max)
peak_15min = resample(power, 15m, "max")

// Time-of-use filtering with time components
peak_twa = twa(power) where time.hour >= 14 and time.hour < 20
off_peak_twa = twa(power) where time.hour < 6 or time.hour >= 22
```

### A.4 Irregular Data Handling
```js
// Derivative with gap filtering
position = load_series("gps_position")
velocity = derivative(position) where dt < 10s  // Skip GPS gaps

// Time-decay EMA for irregular sensor
sensor = load_series("temperature", mode: "linear")
smoothed = ema(sensor, half_life: 5m)

// Align two irregular series for arithmetic
{a, b} = align(sensor_a, sensor_b, mode: "union")
ratio = a / b

// As-of join with tolerance
filled = asof_join(sparse_quotes, dense_timestamps, tolerance: 5m)
```
