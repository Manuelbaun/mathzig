# MathZig Time-Series Guide

MathZig includes a high-performance **Temporal Math Engine** designed for processing irregular time-series data. Unlike standard array libraries, MathZig handles time as a continuous variable, correctly processing irregular intervals, gaps, and missing data.

## 1. The `Series` Data Type

The core data type is the `Series`. It consists of:
- **Timestamps:** A sequence of strictly increasing numbers (typically Unix Epoch seconds).
- **Values:** The corresponding measurements (f64).
- **Validity:** Metadata tracking gaps or invalid points.

MathZig stores Series in a Struct-of-Arrays (SoA) layout aligned for SIMD operations, ensuring maximum performance for aggregations and transformations.

## 2. Importing Data

### Method A: DSL Constructor (REPL / Scripts)
You can create a series directly in the MathZig expression language using two arrays (row vectors).

```js
// Define timestamps (e.g., relative seconds)
T = [0, 5, 12, 30]

// Define values
V = [10, 10, 20, 15]

// Create Series
s = series(T, V)
```

### Method B: Host Application (FFI)
When using MathZig as a library (e.g., from Node.js, Bun, or Python), you should load data in your host language and pass pointers to MathZig. This is the most efficient method for large datasets.

```typescript
// (Conceptual TypeScript Example)
const timestamps = new Float64Array(await loadTimestamps());
const values = new Float64Array(await loadValues());

// Pass to MathZig context
mz.setSeries("sensor_A", timestamps, values);

// Now execute logic inside MathZig
mz.eval("twa(sensor_A)");
```

## 3. Core Functions

MathZig provides specialized functions that respect time intervals (`dt`).

### Aggregations

| Function | Description |
|----------|-------------|
| `twa(x)` | **Time-Weighted Average**. Calculates the area under the curve divided by duration. Essential for irregular data where `mean()` is misleading. |
| `mean(x)`| Simple arithmetic mean of the samples (ignores time duration). |
| `min(x)` | Minimum value. |
| `max(x)` | Maximum value. |

### Calculus

| Function | Description |
|----------|-------------|
| `derivative(x)` | Rate of change per time unit (e.g., `value / sec`). Handles irregular `dt` automatically. |
| `integrate(x)` | Cumulative area under the curve (Trapezoidal rule). |

### Technical Indicators

| Function | Description |
|----------|-------------|
| `ema(x, half_life)` | **Exponential Moving Average**. Uses a time-decay algorithm `alpha = 1 - exp(-dt * ln(2) / half_life)`. This works correctly even if data arrives at random intervals. |
| `sma(x, period)` | Simple Moving Average (sample-based). |
| `rsi(x, period)` | Relative Strength Index (Wilder's smoothing). |

### Transformation

| Function | Description |
|----------|-------------|
| `resample(x, interval)` | Aggregates irregular data into fixed-width buckets (e.g., 1-second bars). |

## 4. Examples

**Scenario: Sensor Velocity**
Calculate the velocity of a position sensor that sends updates irregularly.

```js
pos = load_position_series()
velocity = derivative(pos)
avg_speed = twa(abs(velocity))
```

**Scenario: Gap-tolerant Smoothing**
Smooth a noisy signal, respecting that some gaps are large (don't over-weight old data).

```js
raw = load_sensor()
// Decay weight by 50% every 10 seconds
smooth = ema(raw, 10.0) 
```
