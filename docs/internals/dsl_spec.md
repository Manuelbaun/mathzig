# MathZig Time-Series DSL Specification

**Version**: 1.0.0
**Status**: Draft
**Last Updated**: 2024-01-09

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [Lexical Structure](#2-lexical-structure)
3. [Data Types](#3-data-types)
4. [Literals](#4-literals)
5. [Operators](#5-operators)
6. [Core Functions](#6-core-functions)
7. [Filtering & Predicates](#7-filtering--predicates)
8. [Grammar (EBNF)](#8-grammar-ebnf)
9. [Implementation Notes](#9-implementation-notes)

---

## 1. Design Principles

### 1.1 Consistency Rules

| Rule | Convention | Example |
|------|------------|---------|
| Function names | `snake_case` | `time_weighted_avg`, `load_series` |
| Abbreviations | Allowed only for well-known terms | `ema`, `sma`, `rsi`, `twa` |
| Duration units | Lowercase suffix | `5m`, `1h`, `7d` |
| Named parameters | Colon syntax | `half_life: 5m` |
| Options object | Curly braces | `{ origin: 0, closed: "left" }` |
| Method chaining | NOT supported | Use function composition |
| Filtering | `where` clause only | `sum(x) where value > 0` |

### 1.2 Function Style Only

All operations use **function call style**. No method chaining.

```js
// CORRECT: Function style
result = tail(series, 100)
result = slice(series, start, end)
result = since(series, 1h)

// WRONG: Method style (not supported)
result = series.tail(100)
result = series.since(1h)
```

### 1.3 Explicit Over Implicit

- No automatic alignment for arithmetic (use `align()` explicitly)
- No implicit type coercion
- All durations must have explicit units

---

## 2. Lexical Structure

### 2.1 Identifiers

```
identifier = letter (letter | digit | "_")*
letter     = "a".."z" | "A".."Z"
digit      = "0".."9"
```

Reserved words: `where`, `and`, `or`, `not`, `between`, `true`, `false`, `null`, `nan`

### 2.2 Comments

```js
// Single-line comment
/* Multi-line
   comment */
```

### 2.3 Whitespace

Spaces, tabs, and newlines are ignored except as token separators.

---

## 3. Data Types

### 3.1 Scalar Types

| Type | Description | Example |
|------|-------------|---------|
| `number` | 64-bit float | `42`, `3.14`, `-1e10` |
| `bool` | Boolean | `true`, `false` |
| `string` | UTF-8 string | `"hello"`, `"2024-01-01"` |
| `duration` | Time duration | `5m`, `1h`, `7d` |
| `timestamp` | Unix epoch (seconds) | `1704067200` or `"2024-01-01"` |
| `null` | Missing value | `null` |

### 3.2 Composite Types

| Type | Description | Example |
|------|-------------|---------|
| `Series` | Time-indexed numeric array | `load_series("sensor")` |
| `BoolSeries` | Time-indexed boolean array | `series > 100` |
| `Record` | Named tuple | `{ open: 100, close: 105 }` |

### 3.3 Series Structure

A `Series` contains:
- `timestamps`: Array of Unix epoch seconds (f64)
- `values`: Array of numeric values (f64)
- `sample_mode`: `"step"` | `"linear"` | `"cumulative"`

---

## 4. Literals

### 4.1 Numbers

```js
42          // Integer
3.14        // Float
-1.5e-10    // Scientific notation
nan         // Not a number
inf         // Positive infinity
-inf        // Negative infinity
```

### 4.2 Strings

```js
"hello world"
"2024-01-15"
"2024-01-15T10:30:00Z"
```

### 4.3 Durations

Duration format: `<number><unit>`

| Unit | Meaning | Example |
|------|---------|---------|
| `ms` | Milliseconds | `500ms` |
| `s` | Seconds | `30s` |
| `m` | Minutes | `5m` |
| `h` | Hours | `1h` |
| `d` | Days | `7d` |
| `w` | Weeks | `2w` |

```js
5m          // 5 minutes (300 seconds)
1.5h        // 1.5 hours (5400 seconds)
7d          // 7 days
100ms       // 100 milliseconds
```

### 4.4 Timestamps

Timestamps can be:
1. **ISO 8601 string**: `"2024-01-15"` or `"2024-01-15T10:30:00Z"`
2. **Unix epoch number**: `1705312200`
3. **Relative expression**: `now() - 1h`

```js
"2024-01-15"              // Midnight UTC
"2024-01-15T10:30:00"     // Specific time (local)
"2024-01-15T10:30:00Z"    // Specific time (UTC)
1705312200                // Unix timestamp
now()                     // Current time
now() - 1h                // 1 hour ago
now() - 7d                // 7 days ago
```

### 4.5 General Units & Compound Units

For physical units beyond simple durations, MathZig supports two styles:

#### 4.5.1 Identifier Style (Simple Units)
Simple units can be attached to numbers via juxtaposition (implicit multiplication).
```js
distance = 10m
weight = 5.5kg
velocity = 100km/h  // Parsed as (100 * km) / h
```
*Note: This style follows standard operator precedence. `10kg/kWh` would be parsed as `(10 * kg) / (k * W * h)` if all parts are defined.*

#### 4.5.2 Bracket Style (Complex/Compound Units)
To handle units with symbols like `/`, `*`, or spaces without ambiguity, use square brackets. This treats the entire content as a single unit reference.
```js
consumption = 10[kWh]
emission_factor = 0.5[kg/kWh]
flow = 1.2[m^3/h]
```
This is the **recommended style** for units containing `/` to avoid precedence issues with expressions.

---

## 5. Operators

### 5.1 Precedence Table (Highest to Lowest)

| Precedence | Operators | Associativity | Description |
|------------|-----------|---------------|-------------|
| 1 | `()` | — | Grouping |
| 2 | `-` (unary), `not` | Right | Negation |
| 3 | `^` | Right | Power |
| 4 | `*`, `/`, `%` | Left | Multiplicative |
| 5 | `+`, `-` | Left | Additive |
| 6 | `<`, `<=`, `>`, `>=` | Left | Comparison |
| 7 | `==`, `!=` | Left | Equality |
| 8 | `and` | Left | Logical AND |
| 9 | `or` | Left | Logical OR |
| 10 | `?:` | Right | Ternary |
| 11 | `=` | Right | Assignment |

### 5.2 Arithmetic Operators

| Operator | Types | Result | Notes |
|----------|-------|--------|-------|
| `a + b` | number, number | number | |
| `a + b` | Series, number | Series | Broadcast |
| `a + b` | Series, Series | Series | **Must be aligned first** |
| `a - b` | Same as `+` | | |
| `a * b` | Same as `+` | | |
| `a / b` | Same as `+` | | Division by zero → `nan` |
| `a % b` | number, number | number | Modulo |
| `a ^ b` | number, number | number | Power |
| `-a` | number | number | Negation |
| `-a` | Series | Series | Element-wise negation |

### 5.3 Comparison Operators

| Operator | Description | Result |
|----------|-------------|--------|
| `a == b` | Equal | bool or BoolSeries |
| `a != b` | Not equal | bool or BoolSeries |
| `a < b` | Less than | bool or BoolSeries |
| `a <= b` | Less or equal | bool or BoolSeries |
| `a > b` | Greater than | bool or BoolSeries |
| `a >= b` | Greater or equal | bool or BoolSeries |

### 5.4 Logical Operators

| Operator | Description |
|----------|-------------|
| `a and b` | Logical AND |
| `a or b` | Logical OR |
| `not a` | Logical NOT |

### 5.5 Series Arithmetic Rules

**Series + Scalar**: Element-wise operation
```js
celsius = (fahrenheit - 32) * 5 / 9
```

**Series + Series**: Requires explicit alignment
```js
// CORRECT: Explicit alignment
{a, b} = align(series_a, series_b, mode: "union")
result = a / b

// WRONG: Implicit alignment not supported
result = series_a / series_b  // ERROR
```

---

## 6. Core Functions

### 6.1 Data I/O

#### `load_series`

Load a series from a data source.

```
load_series(name: string) -> Series
load_series(name: string, mode: SampleMode) -> Series
load_series(name: string, start: timestamp, end: timestamp) -> Series
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | Data source identifier |
| `mode` | string | `"linear"` | Sample mode: `"step"`, `"linear"`, `"cumulative"` |
| `start` | timestamp | unbounded | Start time filter |
| `end` | timestamp | unbounded | End time filter |

```js
// Basic load
data = load_series("temperature_sensor")

// With sample mode
power = load_series("power_meter", mode: "step")

// With time range
jan_data = load_series("sensor", start: "2024-01-01", end: "2024-02-01")
```

#### `series`

Create a series from arrays.

```
series(timestamps: [number], values: [number]) -> Series
series(timestamps: [number], values: [number], mode: SampleMode) -> Series
```

```js
s = series([1704067200, 1704067260, 1704067320], [10.5, 11.2, 10.8])
s = series(ts_array, val_array, mode: "step")
```

---

### 6.2 Aggregation Functions

All aggregation functions return a **scalar** and support an optional `where` clause.

| Function | Signature | Description |
|----------|-----------|-------------|
| `sum` | `sum(s) -> number` | Sum of values |
| `mean` | `mean(s) -> number` | Arithmetic mean |
| `twa` | `twa(s) -> number` | Time-weighted average |
| `min` | `min(s) -> number` | Minimum value |
| `max` | `max(s) -> number` | Maximum value |
| `count` | `count(s) -> number` | Number of samples |
| `first` | `first(s) -> number` | First value |
| `last` | `last(s) -> number` | Last value |
| `median` | `median(s) -> number` | Median value |
| `stddev` | `stddev(s) -> number` | Standard deviation |
| `variance` | `variance(s) -> number` | Variance |
| `range` | `range(s) -> number` | max - min |
| `integral` | `integral(s) -> number` | Area under curve |

**Syntax with predicate:**
```js
result = FUNCTION(series) where PREDICATE
```

**Examples:**
```js
total = sum(readings)
avg = mean(temperature)
time_avg = twa(sensor_data)

// With predicates
positive_sum = sum(values) where value > 0
recent_avg = mean(data) where time >= now() - 24h
valid_twa = twa(readings) where is_valid
```

---

### 6.3 Rolling Functions

Rolling functions return a **Series** with values computed over a sliding window.

| Function | Signature | Description |
|----------|-----------|-------------|
| `rolling_sum` | `rolling_sum(s, window) -> Series` | Rolling sum |
| `rolling_mean` | `rolling_mean(s, window) -> Series` | Rolling mean |
| `rolling_twa` | `rolling_twa(s, window) -> Series` | Rolling TWA |
| `rolling_min` | `rolling_min(s, window) -> Series` | Rolling minimum |
| `rolling_max` | `rolling_max(s, window) -> Series` | Rolling maximum |
| `rolling_stddev` | `rolling_stddev(s, window) -> Series` | Rolling stddev |
| `rolling_count` | `rolling_count(s, window) -> Series` | Rolling count |

**Window types:**
- **Sample-based**: Integer (e.g., `20` = last 20 samples)
- **Duration-based**: Duration literal (e.g., `1h` = last 1 hour)

```js
// Sample-based window
ma_20 = rolling_mean(price, 20)

// Duration-based window
hourly_avg = rolling_mean(temp, 1h)
weekly_std = rolling_stddev(returns, 7d)
```

---

### 6.4 Technical Indicators

| Function | Signature | Description |
|----------|-----------|-------------|
| `sma` | `sma(s, period: int) -> Series` | Simple Moving Average |
| `ema` | `ema(s, period: int) -> Series` | Exponential Moving Average |
| `ema` | `ema(s, half_life: duration) -> Series` | Time-decay EMA |
| `rsi` | `rsi(s, period: int) -> Series` | Relative Strength Index |
| `macd` | `macd(s, fast, slow, signal) -> Record` | MACD indicator |
| `bollinger` | `bollinger(s, period, mult) -> Record` | Bollinger Bands |

**MACD returns:**
```js
{ macd: Series, signal: Series, histogram: Series }
```

**Bollinger returns:**
```js
{ upper: Series, middle: Series, lower: Series }
```

**Examples:**
```js
// Moving averages
short = sma(price, 10)
long = sma(price, 50)

// EMA variants
regular = ema(price, 20)           // Period-based
decay = ema(sensor, half_life: 5m) // Time-decay for irregular data

// RSI
strength = rsi(close, 14)
oversold = strength where value < 30

// MACD
result = macd(price, 12, 26, 9)
bullish = result.histogram where value > 0

// Bollinger Bands
bands = bollinger(price, 20, 2)
squeeze = (bands.upper - bands.lower) / bands.middle
```

---

### 6.5 Calculus Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `derivative` | `derivative(s) -> Series` | Rate of change (units/sec) |
| `integrate` | `integrate(s) -> Series` | Cumulative integral |
| `diff` | `diff(s) -> Series` | Point-to-point difference |
| `diff` | `diff(s, n: int) -> Series` | N-period difference |
| `pct_change` | `pct_change(s) -> Series` | Percentage change |
| `cumsum` | `cumsum(s) -> Series` | Cumulative sum |
| `cummax` | `cummax(s) -> Series` | Cumulative maximum |
| `cummin` | `cummin(s) -> Series` | Cumulative minimum |

**Examples:**
```js
velocity = derivative(position)
acceleration = derivative(velocity)

// Skip large gaps
clean_vel = derivative(position) where dt < 10s

// Integration
total_distance = integrate(velocity)
energy = integrate(power)

// Cumulative operations
running_total = cumsum(sales)
drawdown = value / cummax(value) - 1
```

---

### 6.6 Resampling

#### `resample`

Downsample to regular intervals.

```
resample(s: Series, interval: duration, agg: string) -> Series
resample(s: Series, interval: duration, agg: string, options: ResampleOptions) -> Series
```

| Aggregation | Description |
|-------------|-------------|
| `"first"` | First value in bucket |
| `"last"` | Last value in bucket |
| `"min"` | Minimum value |
| `"max"` | Maximum value |
| `"sum"` | Sum of values |
| `"count"` | Number of samples |
| `"mean"` | Arithmetic mean |
| `"twa"` | Time-weighted average |
| `"median"` | Median value |

**Options:**
```js
{
  origin: timestamp,         // Bucket alignment origin (default: 0)
  closed: "left" | "right",  // Which edge is closed (default: "left")
  label: "left" | "right",   // Timestamp for output (default: "left")
  empty: "skip" | "null" | "zero" | "forward" | "backward"
}
```

**Examples:**
```js
// Basic resampling
hourly = resample(ticks, 1h, "last")
daily_avg = resample(temp, 1d, "mean")

// TWA for irregular data
hourly_twa = resample(sensor, 1h, "twa")

// With options
daily = resample(data, 1d, "sum", {
  origin: "2024-01-01",
  closed: "right",
  empty: "zero"
})

// With predicate
clean = resample(data, 1h, "mean") where value > 0
```

#### `ohlc`

Create OHLC bars.

```
ohlc(s: Series, interval: duration) -> Record
```

Returns: `{ open: Series, high: Series, low: Series, close: Series }`

```js
bars = ohlc(price, 15m)
candles = ohlc(ticks, 1h)
```

---

### 6.7 Range Selection

| Function | Signature | Description |
|----------|-----------|-------------|
| `slice` | `slice(s, start, end) -> Series` | Time range slice |
| `head` | `head(s, n: int) -> Series` | First N samples |
| `tail` | `tail(s, n: int) -> Series` | Last N samples |
| `since` | `since(s, duration) -> Series` | Last duration |
| `between` | `between(s, start, end) -> Series` | Time range (inclusive) |

**Examples:**
```js
january = slice(data, "2024-01-01", "2024-02-01")
first_100 = head(data, 100)
last_50 = tail(data, 50)
recent = since(data, 1h)
q1 = between(data, "2024-01-01", "2024-03-31")
```

---

### 6.8 Null Handling

| Function | Signature | Description |
|----------|-----------|-------------|
| `dropna` | `dropna(s) -> Series` | Remove null/NaN values |
| `fillna` | `fillna(s, value: number) -> Series` | Fill with constant |
| `fillna` | `fillna(s, method: string) -> Series` | Fill with method |
| `clip` | `clip(s, min, max) -> Series` | Clamp values to range |

**Fill methods:**
- `"forward"` — Forward fill (LOCF)
- `"backward"` — Backward fill
- `"linear"` — Linear interpolation

```js
clean = dropna(data)
filled = fillna(data, 0)
interpolated = fillna(data, "linear")
forward_filled = fillna(data, "forward")
clipped = clip(data, 0, 100)
```

---

### 6.9 Alignment & Joins

#### `align`

Align two series to common timestamps.

```
align(a: Series, b: Series, mode: string) -> Record
```

| Mode | Description |
|------|-------------|
| `"union"` | All timestamps from both series |
| `"intersect"` | Only overlapping time range |
| `"left"` | Use left series timestamps |
| `"right"` | Use right series timestamps |

Returns: `{ left: Series, right: Series }`

```js
{a, b} = align(price, volume, mode: "union")
ratio = a / b

{bid_aligned, ask_aligned} = align(bid, ask, mode: "intersect")
spread = ask_aligned - bid_aligned
```

#### `asof_join`

Point-in-time join (get last known value).

```
asof_join(left: Series, right: Series) -> Series
asof_join(left: Series, right: Series, tolerance: duration) -> Series
```

```js
filled = asof_join(sparse_quotes, regular_timestamps)
filled = asof_join(sparse, dense, tolerance: 5m)  // Max 5min lookback
```

---

### 6.10 Utility Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `len` | `len(s) -> number` | Number of samples |
| `duration` | `duration(s) -> number` | Time span (seconds) |
| `start_time` | `start_time(s) -> number` | First timestamp |
| `end_time` | `end_time(s) -> number` | Last timestamp |
| `now` | `now() -> number` | Current Unix timestamp |
| `conv` | `conv(v, u) -> number` | Convert value to unit |
| `shift` | `shift(s, n: int) -> Series` | Shift values by N positions |
| `is_valid` | `is_valid(s) -> BoolSeries` | Validity mask |
| `is_null` | `is_null(s) -> BoolSeries` | Null mask |

```js
n = len(data)
span = duration(data)
prev_close = shift(close, 1)
returns = (close - shift(close, 1)) / shift(close, 1)
```

---

### 6.11 Math Functions

All math functions work on both scalars and Series (element-wise).

| Function | Description |
|----------|-------------|
| `abs(x)` | Absolute value |
| `sign(x)` | Sign (-1, 0, 1) |
| `floor(x)` | Floor |
| `ceil(x)` | Ceiling |
| `round(x)` | Round to nearest |
| `sqrt(x)` | Square root |
| `exp(x)` | e^x |
| `log(x)` | Natural log |
| `log10(x)` | Base-10 log |
| `log2(x)` | Base-2 log |
| `sin(x)`, `cos(x)`, `tan(x)` | Trigonometric |
| `asin(x)`, `acos(x)`, `atan(x)` | Inverse trig |
| `min(a, b)` | Element-wise minimum |
| `max(a, b)` | Element-wise maximum |
| `clamp(x, lo, hi)` | Clamp to range |

---

### 6.12 Generation Functions

Functions to generate sequences of numbers or time series.

| Function | Signature | Description |
|----------|-----------|-------------|
| `range` | `range(start, end) -> Series` | Sequence `[start, end)` with step=1 |
| `range` | `range(start, end, step) -> Series` | Sequence with step |
| `linspace` | `linspace(start, end, n) -> Series` | N linearly spaced points |
| `logspace` | `logspace(start, end, n) -> Series` | N logarithmically spaced points |

**Note on Overloading:**
- `range(s: Series)` -> Aggregation (scalar result: max - min)
- `range(start, end, ...)` -> Generation (Series result)

**Time Generation:**
When used with timestamps and durations, `range` generates a time series.

```js
// Numeric generation
r1 = range(0, 10)          // [0, 1, 2, ..., 9]
r2 = range(0, 1, 0.1)      // [0, 0.1, 0.2, ..., 0.9]
r3 = linspace(0, 10, 5)    // [0, 2.5, 5, 7.5, 10]

// Temporal generation
// Generate timestamps from start to end with 1h step
t = range("2024-01-01", "2024-01-02", 1h)

// Generate 100 points between two times
t2 = linspace(now(), now() + 1d, 100)
```

---

## 7. Filtering & Predicates

### 7.1 The `where` Clause

The **only** way to filter in this DSL is the `where` clause. It applies to the immediately preceding function call.

```js
result = FUNCTION(series) where PREDICATE
```

### 7.2 Predicate Fields

| Field | Type | Description |
|-------|------|-------------|
| `value` | number | Current sample value |
| `time` | timestamp | Current sample timestamp |
| `dt` | duration | Time since previous sample |

### 7.3 Time Component Access

Access components of the timestamp:

| Expression | Description |
|------------|-------------|
| `time.year` | Year (e.g., 2024) |
| `time.month` | Month (1-12) |
| `time.day` | Day of month (1-31) |
| `time.hour` | Hour (0-23) |
| `time.minute` | Minute (0-59) |
| `time.second` | Second (0-59) |
| `time.weekday` | Day of week (0=Monday, 6=Sunday) |

```js
// Filter by hour
peak_hours = twa(power) where time.hour >= 14 and time.hour < 20
off_peak = mean(power) where time.hour < 6 or time.hour >= 22

// Filter by day of week (weekends)
weekends = sum(sales) where time.weekday >= 5
```

### 7.4 Predicate Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `>` | Greater than | `value > 0` |
| `>=` | Greater or equal | `time >= "2024-01-01"` |
| `<` | Less than | `dt < 10s` |
| `<=` | Less or equal | `value <= 100` |
| `==` | Equal | `value == 0` |
| `!=` | Not equal | `value != nan` |
| `between A and B` | Range (inclusive) | `value between 10 and 100` |
| `and` | Logical AND | `value > 0 and time > T` |
| `or` | Logical OR | `value < 0 or value > 100` |
| `not` | Logical NOT | `not is_null` |
| `is_valid` | Not null/NaN | `is_valid` |
| `is_null` | Is null/NaN | `is_null` |

### 7.5 Predicate Examples

```js
// Value predicates
sum(data) where value > 0
mean(data) where value between 10 and 100

// Time predicates
twa(data) where time >= "2024-01-01"
mean(data) where time > now() - 24h
sum(data) where time between "2024-01-01" and "2024-02-01"

// Gap predicates (for irregular data)
derivative(position) where dt < 60s
mean(data) where dt > 0  // Exclude duplicate timestamps

// Time component predicates
twa(power) where time.hour >= 9 and time.hour < 17  // Business hours
sum(sales) where time.weekday < 5  // Weekdays only

// Validity predicates
twa(readings) where is_valid
count(data) where not is_null

// Combined predicates
result = twa(sensor) where value > 0 and time >= "2024-01-01" and dt < 5m
filtered = sum(trades) where value > 1000 and (time.hour >= 9 and time.hour < 16)
```

---

## 8. Grammar (EBNF)

```ebnf
(* Top-level *)
program          ::= statement*
statement        ::= assignment | expression
assignment       ::= pattern "=" expression

(* Patterns *)
pattern          ::= identifier | destructure
destructure      ::= "{" identifier ("," identifier)* "}"

(* Expressions *)
expression       ::= ternary
ternary          ::= logical_or ("?" expression ":" expression)?
logical_or       ::= logical_and ("or" logical_and)*
logical_and      ::= comparison ("and" comparison)*
comparison       ::= additive (comp_op additive)*
additive         ::= multiplicative (("+" | "-") multiplicative)*
multiplicative   ::= unary (("*" | "/" | "%") unary)*
unary            ::= ("-" | "not") unary | power
power            ::= postfix ("^" unary)?
postfix          ::= primary (call | member | where_clause)*

(* Primary expressions *)
primary          ::= number | string | bool | identifier | unit_literal
                   | "(" expression ")" | "now" "()"

(* Unit literals *)
unit_literal     ::= "[" unit_content "]"
unit_content     ::= <any character except "]">+

(* Function calls *)
call             ::= "(" [arg_list] ")"
arg_list         ::= argument ("," argument)*
argument         ::= expression | named_arg
named_arg        ::= identifier ":" expression

(* Member access *)
member           ::= "." identifier

(* Where clause *)
where_clause     ::= "where" predicate

(* Predicates *)
predicate        ::= pred_or
pred_or          ::= pred_and ("or" pred_and)*
pred_and         ::= pred_term ("and" pred_term)*
pred_term        ::= pred_atom | "not" pred_term | "(" predicate ")"
pred_atom        ::= field_expr comp_op value_expr
                   | field_expr "between" value_expr "and" value_expr
                   | "is_valid" | "is_null"
field_expr       ::= "time" ["." time_component] | "value" | "dt"
time_component   ::= "year" | "month" | "day" | "hour" | "minute" | "second" | "weekday"
comp_op          ::= "==" | "!=" | "<" | "<=" | ">" | ">="
value_expr       ::= number | string | duration | "now" "()" ("-" duration)?

(* Literals *)
number           ::= ["-"] digit+ ["." digit+] [("e"|"E") ["+"|"-"] digit+]
                   | "nan" | "inf" | "-inf"
string           ::= '"' char* '"'
bool             ::= "true" | "false"
duration         ::= number duration_unit
duration_unit    ::= "ms" | "s" | "m" | "h" | "d" | "w"
identifier       ::= letter (letter | digit | "_")*

(* Tokens *)
letter           ::= "a".."z" | "A".."Z"
digit            ::= "0".."9"
char             ::= <any character except unescaped quote>
```

---

## 9. Implementation Notes

### 9.1 Zig Function Mapping

| DSL Function | Zig Implementation |
|--------------|-------------------|
| `load_series` | `SeriesLoader.load()` |
| `twa` | `aggregations.twa()` |
| `resample` | `resampling.resample()` |
| `ema(s, period)` | `indicators.ema()` |
| `ema(s, half_life: d)` | `indicators.timeDecayEma()` |
| `derivative` | `calculus.derivative()` |

### 9.2 Error Handling

Errors are returned as special values:
- Division by zero → `nan`
- Empty series aggregation → `nan`
- Invalid predicate → runtime error

### 9.3 Lazy Evaluation

Predicates are evaluated lazily during iteration, not materialized into bitmaps (unless optimization determines it's beneficial).

### 9.4 Extension Points

To add a new function:
1. Define signature in this spec
2. Implement in Zig under appropriate module
3. Register in VM opcode table
4. Add to parser function registry

### 9.5 Symbolic Math & Unit Simplification

MathZig uses an AST-based **Algebraic Rewriter** to simplify expressions and units *before* bytecode emission.

#### 9.5.1 Unit Reduction
When units are combined via multiplication or division, the rewriter attempts to reduce them to known named units or the simplest base SI form.
*   **Automatic Identity**: `[W] * [s]` → `[J]` (since $1W = 1J/s$)
*   **Complexity Reduction**: `[kg*m/s^2]` → `[N]`
*   **Canonicalization**: The system internally works in base SI, but `simplify()` can be used to target specific "human-friendly" units.

#### 9.5.2 Symbolic Simplification Rules
1.  **Constant Folding**: `1 + 2 + x` → `3 + x`
2.  **Identity Rules**: `x * 1` → `x`, `x + 0` → `x`, `x / x` → `1`
3.  **Unit Scaling**: `1000[Wh]` → `1[kWh]` (if target unit matches a prefix)

#### 9.5.3 Example: Energy Conversion
```js
power = 100[W]
duration = 1[h]
energy = power * duration  // AST resolves to 360000[J]
energy_kwh = conv(energy, [kWh]) // AST resolves to 0.1 (pure number)
```
If `conv` is used with a constant unit, the rewriter will evaluate the conversion at compile-time, resulting in zero runtime overhead.

---

## Appendix A: Quick Reference Card

### Aggregation (return scalar)
```
sum(s)  mean(s)  twa(s)  min(s)  max(s)  count(s)  first(s)  last(s)
median(s)  stddev(s)  variance(s)  range(s)  integral(s)
```

### Rolling (return Series)
```
rolling_sum(s, window)  rolling_mean(s, window)  rolling_twa(s, window)
rolling_min(s, window)  rolling_max(s, window)  rolling_stddev(s, window)
```

### Indicators (return Series)
```
sma(s, period)  ema(s, period)  ema(s, half_life: duration)
rsi(s, period)  macd(s, fast, slow, signal)  bollinger(s, period, mult)
```

### Calculus (return Series)
```
derivative(s)  integrate(s)  diff(s)  pct_change(s)
cumsum(s)  cummax(s)  cummin(s)
```

### Resampling
```
resample(s, interval, "agg")  resample(s, interval, "agg", {options})
ohlc(s, interval)
```

### Selection
```
slice(s, start, end)  head(s, n)  tail(s, n)  since(s, duration)
```

### Alignment
```
align(a, b, mode: "union"|"intersect"|"left"|"right")
asof_join(left, right)  asof_join(left, right, tolerance: duration)
```

### Null Handling
```
dropna(s)  fillna(s, value)  fillna(s, "forward"|"backward"|"linear")
clip(s, min, max)
```

### Predicates
```
where value > N          where time >= T          where dt < D
where value between A and B                       where is_valid
where time.hour >= 9 and time.hour < 17          where not is_null
```

---

## 10. Implementation Status & Roadmap

This section tracks the progress of the DSL implementation. Each step must be accompanied by unit tests to verify compliance with the specification.

### Phase 1: Lexical Foundation
- [ ] **1.1 Unit-Aware Tokenizer**
  - [ ] Implement `duration` literal tokens (`5m`, `1h`).
  - [ ] Implement `unit_literal` tokens (`[kg/kWh]`).
  - [ ] Support for `snake_case` identifiers.
  - [ ] **Verification**: Lexer tests for all literal types and edge cases.

### Phase 2: Parser & AST
- [ ] **2.1 Expression Grammar**
  - [ ] Implement recursive descent parser for the EBNF grammar.
  - [ ] Support for operator precedence (including `implicit_mul` for units).
  - [ ] Implement `Node` types for `Series`, `Record`, and `Duration`.
- [ ] **2.2 Assignment & Destructuring**
  - [ ] Implement single assignment `x = ...`.
  - [ ] Implement record destructuring `{a, b} = align(...)`.
  - [ ] **Verification**: Parser tests for nested expressions and assignments.

### Phase 3: VM Integration & Opcodes
- [ ] **3.1 Time-Series Opcodes**
  - [ ] Add `LOAD_SERIES`, `ALIGN`, `RESAMPLE` opcodes to the VM.
  - [ ] Implement stack handling for `Series` objects (reference counting).
- [ ] **3.2 Jump & Control Flow**
  - [ ] Implement `JMP_IF_FALSE` for ternary operators.
  - [ ] **Verification**: VM execution tests for basic series loading and arithmetic.

### Phase 4: The `where` Clause (Filtering)
- [ ] **4.1 Predicate Engine**
  - [ ] Implement lazy predicate evaluation logic.
  - [ ] Support for `time.*` component extraction.
  - [ ] Implement `dt` (delta time) calculation during iteration.
- [ ] **4.2 Compiler Integration**
  - [ ] Update compiler to emit filtering bytecode for aggregation calls.
  - [ ] **Verification**: Test `sum(x) where value > 0` vs standard `sum(x)`.

### Phase 5: Core Function Library
- [x] **5.1 Aggregations**
  - [x] `sum`, `mean`, `twa`, `min`, `max`, `count`.
- [ ] **5.2 Rolling Windows**
  - [ ] Implement circular buffer for sample-based windows.
  - [ ] Implement time-bucketed logic for duration-based windows.
- [x] **5.3 Indicators**
  - [x] `sma`, `ema`, `rsi`.
- [x] **5.4 Generation Functions**
  - [x] `range`, `linspace`, `logspace`.
  - [ ] **Verification**: Correctness tests against reference datasets (e.g., NumPy/Pandas outputs).

### Phase 6: Resampling & Alignment
- [ ] **6.1 Alignment Kernels**
  - [ ] Implement `union`, `intersect`, `left`, `right` join logic.
- [ ] **6.2 Resampling Logic**
  - [ ] Implement bucket origin and edge handling (`closed`, `label`).
  - [ ] Implement `empty` bucket filling strategies.
  - [ ] **Verification**: Tests for irregular timestamp alignment.

### Phase 7: Calculus & Advanced Math
- [ ] **7.1 Calculus Operations**
  - [ ] `derivative`, `integrate`, `diff`, `cumsum`.
- [ ] **7.2 Element-wise Math**
  - [ ] Map standard math functions (`sin`, `log`, etc.) to process Series element-wise.
- [ ] **7.3 Algebraic Rewriter (Symbolic)**
  - [ ] Implement AST-level constant folding.
  - [ ] Implement unit reduction logic (`W*s` -> `J`).
  - [ ] Implement `conv()` compile-time optimization.
  - [ ] **Verification**: Integration tests for complex multi-step pipelines and symbolic correctness.

### Phase 8: Final Polish & FFI
- [ ] **8.1 Error Reporting**
  - [ ] Implement descriptive compile-time and runtime error messages.
- [ ] **8.2 Bun/TS Bindings**
  - [ ] Expose the DSL execution entry point via FFI.
  - [ ] **Verification**: End-to-end tests from TypeScript.
