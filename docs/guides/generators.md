# Generators Guide

MathZig provides a set of generator functions for creating sequences, ranges, and time-based data. This guide covers all available generators and their use cases.

## Overview

Generators create numerical sequences and time series for:
- Scientific computing and simulation
- Data analysis and visualization
- Machine learning preprocessing
- Mathematical exploration

## Available Generators

### gen_range - Arithmetic Sequences

```javascript
gen_range(start, end, step)
```

Creates an arithmetic sequence from `start` to `end` (exclusive) with the given `step`.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `start` | Number | First value |
| `end` | Number | End value (exclusive) |
| `step` | Number | Increment (must be positive) |

**Returns:** Array of numbers

**Example:**

```javascript
// Generate [0, 1, 2, 3, 4]
gen_range(0, 5, 1)

// Generate [0, 0.5, 1.0, 1.5, 2.0]
gen_range(0, 2.1, 0.5)

// Generate [-2, -1, 0, 1, 2]
gen_range(-2, 3, 1)
```

### linspace - Linear Spacing

```javascript
linspace(start, end, n)
```

Creates exactly `n` evenly-spaced points from `start` to `end` (inclusive).

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `start` | Number | First value |
| `end` | Number | Last value |
| `n` | Integer | Number of points (minimum 2) |

**Returns:** Array of `n` numbers

**Example:**

```javascript
// 5 points from 0 to 1: [0, 0.25, 0.5, 0.75, 1]
linspace(0, 1, 5)

// 100 points for plotting
x = linspace(0, 2*pi, 100)
y = sin(x)

// Symmetric range around zero
linspace(-5, 5, 11)  // [-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5]
```

### logspace - Logarithmic Spacing

```javascript
logspace(start, end, n)
```

Creates `n` points logarithmically spaced from 10^`start` to 10^`end`.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `start` | Number | Exponent for start (10^start) |
| `end` | Number | Exponent for end (10^end) |
| `n` | Integer | Number of points |

**Returns:** Array of `n` numbers on logarithmic scale

**Example:**

```javascript
// 5 points from 0.01 to 100: [0.01, 0.1, 1, 10, 100]
logspace(-2, 2, 5)

// Frequency range for signal processing
freq = logspace(0, 6, 1000)  // 1 Hz to 1 MHz

// Decibel scale
db_values = logspace(-3, 2, 6)  // [0.001, 0.01, 0.1, 1, 10, 100]
```

### agg_range - Time Series Aggregation

```javascript
agg_range(start_ts, end_ts, period, aggregator)
```

Creates a time series by aggregating data over regular time periods.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `start_ts` | Number | Start timestamp |
| `end_ts` | Number | End timestamp |
| `period` | Number | Aggregation period in seconds |
| `aggregator` | String | Aggregation function name |

**Aggregators:**
- `"mean"` - Average value
- `"sum"` - Sum of values
- `"min"` - Minimum value
- `"max"` - Maximum value
- `"first"` - First value in period
- `"last"` - Last value in period
- `"count"` - Number of samples

**Returns:** Time series with aggregated values

**Example:**

```javascript
// Hourly aggregation of a series
hourly = agg_range(t0, t1, 3600, "mean")

// Daily max temperature
daily_max = agg_range(t0, t1, 86400, "max")

// Count samples per minute
counts = agg_range(t0, t1, 60, "count")
```

### now - Current Timestamp

```javascript
now()
```

Returns the current Unix timestamp in seconds.

**Returns:** Number (current time as seconds since epoch)

**Example:**

```javascript
// Get current time
current = now()

// Time since last event
elapsed = now() - last_event_time
```

## Use Cases

### Scientific Computing

**Signal Generation:**

```javascript
// Sine wave samples
t = linspace(0, 1, 1000)
omega = 2 * pi * 440  // 440 Hz
signal = sin(omega * t)

// Chirp signal (frequency sweep)
f0 = 100
f1 = 1000
t = linspace(0, 1, 1000)
freq = linspace(f0, f1, 1000)
signal = sin(2 * pi * freq * t)
```

**Mesh Generation:**

```javascript
// 2D mesh for PDE solving
x = linspace(0, 1, 50)
y = linspace(0, 1, 50)

// Grid coordinates for plotting
[X, Y] = meshgrid(x, y)
```

### Data Analysis

**Binning Data:**

```javascript
// Create histogram bins
bins = linspace(0, 100, 11)  // 0-10, 10-20, ..., 90-100

// Logarithmic bins for power-law data
power_bins = logspace(-3, 3, 20)
```

**Index Generation:**

```javascript
// Array indices
idx = gen_range(0, 100, 1)

// Step indices
idx = gen_range(0, 1000, 10)  // [0, 10, 20, ..., 990]
```

### Machine Learning

**Hyperparameter Search:**

```javascript
// Linear search space
learning_rates = linspace(1e-5, 1e-1, 20)

// Logarithmic search space
reg_values = logspace(-6, -1, 30)

// Grid search combinations
alphas = linspace(0.1, 1, 10)
betas = linspace(0.8, 0.99, 20)
```

### Financial Analysis

**Time Series Generation:**

```javascript
// Generate business days
start = now()
end = now() + 365 * 86400  // One year
dates = agg_range(start, end, 86400, "mean")

// Price levels for backtesting
prices = 100 * exp(cumsum(0.001 * random_normal(252)))
```

## Combining Generators

Generators can be combined with other MathZig functions:

```javascript
// Create and process
data = gen_range(0, 100, 1)
processed = mean(normalize(data))

// Create time series
timestamps = agg_range(t0, t1, 3600, "mean")
values = sin(2 * pi * timestamps / 86400)

// Vectorized operations
x = linspace(-pi, pi, 1000)
y = sin(x) + 0.1 * cos(10*x)
```

## Performance Tips

1. **Pre-allocate**: Generate arrays once, reuse when possible
2. **Appropriate spacing**: Use `linspace` for plotting, `gen_range` for indexing
3. **Log scales**: Use `logspace` for power-law data
4. **Streaming**: For very large ranges, consider chunked processing

## Related Documentation

- [Overview](overview.md)
- [Time Series Guide](guide_timeseries.md)
- [Matrix Operations](overview.md#matrix-operations)
- [API Reference](../reference/api.md)
