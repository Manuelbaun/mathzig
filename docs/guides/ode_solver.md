# ODE Solver Guide

MathZig includes native Ordinary Differential Equation (ODE) solvers for scientific computing. This guide covers usage, API reference, and examples.

## Overview

MathZig provides two ODE solvers:

1. **`ode_solve`**: 4th-order Runge-Kutta (RK4) method
2. **`ode_solve_euler`**: 1st-order Euler method

Both solvers are implemented entirely in Zig, avoiding the performance bottleneck of calling back to JavaScript for each time step.

## Quick Start

### Defining a Derivative Function

First, define the derivative function f(t, y) using MathZig's DSL:

```javascript
// Simple exponential decay: dy/dt = -0.5 * y
f(t, y) = -0.5 * y

// Harmonic oscillator: d²y/dt² = -y
// First order system: dy/dt = v, dv/dt = -y
g(t, [y, v]) = [-v, -y]
```

### Solving the ODE

```javascript
// Solve from t=0 to t=10 with step 0.1, initial condition y(0)=5
result = ode_solve(f, 5, [0, 10], 0.1)
```

The result is a matrix where:
- Column 0: Time values
- Columns 1+: State variables

## API Reference

### ode_solve

```javascript
ode_solve(func, y0, t_span, dt)
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `func` | Function or String | Derivative function f(t, y) |
| `y0` | Number or Matrix | Initial state (scalar for 1D, vector for nD) |
| `t_span` | Number or Matrix | Time span - either `[start, end]` or single end value |
| `dt` | Number | Time step (must be positive) |

**Returns:** Matrix with shape `(steps, 1 + state_dim)`

**Error Types:**
- `InvalidArgument`: Invalid initial state or time span
- `TypeError`: Function is not callable
- `InvalidStep`: Non-positive dt
- `ResultTooLarge`: Exceeds 10M step limit
- `UnknownFunction`: Function name not found

### ode_solve_euler

```javascript
ode_solve_euler(func, y0, t_span, dt)
```

Same signature as `ode_solve` but uses the Euler method (1st-order accuracy).

## Examples

### Example 1: Exponential Decay

```javascript
// Define the derivative: dy/dt = -k*y
decay(t, y) = -0.3 * y

// Solve: y(0) = 10, from t=0 to t=10, dt=0.1
result = ode_solve(decay, 10, [0, 10], 0.1)

// Extract time and values
t = result[:, 0]
y = result[:, 1]

// Expected: y(10) ≈ 10 * exp(-0.3*10) ≈ 0.498
```

### Example 2: Harmonic Oscillator

```javascript
// Second-order system converted to first-order
// d²y/dt² + ω²*y = 0, with ω = 2
// State: [y, v] where v = dy/dt
oscillator(t, state) = [state[1], -4 * state[0]]

// Initial conditions: y(0)=1, v(0)=0
y0 = [1, 0]

// Solve
result = ode_solve(oscillator, y0, [0, 2*pi], 0.01)

// Period should be π ≈ 3.14
```

### Example 3: Lorenz Attractor

```javascript
// Lorenz system: dx/dt = σ*(y-x)
//                 dy/dt = x*(ρ-z) - y
//                 dz/dt = x*y - β*z
lorenz(t, s) = [
    10 * (s[1] - s[0]),
    s[0] * (28 - s[2]) - s[1],
    s[0] * s[1] - (8/3) * s[2]
]

// Initial conditions
y0 = [1, 1, 20]

// Solve for t = 0 to 50
result = ode_solve(lorenz, y0, 50, 0.005)
```

## Performance Characteristics

### Solver Comparison

| Method | Accuracy | Speed | Use Case |
|--------|----------|-------|----------|
| RK4 (ode_solve) | O(dt⁴) | ~1M steps/sec | General purpose |
| Euler (ode_solve_euler) | O(dt) | ~2M steps/sec | Performance-critical, coarse solutions |

### Optimization Features

1. **Sub-VM Reuse**: Creates a dedicated VM instance for derivative evaluation, avoiding setup overhead
2. **Buffer Pre-allocation**: Allocates RK4 buffers (k1, k2, k3, k4) once at the start
3. **Matrix Reuse**: For vector ODEs, reuses the state matrix instead of allocating each step
4. **Safety Limits**: Maximum 10M steps to prevent runaway computations

### Benchmarks

```
RK4 Solver Performance:
- Simple function: ~1.2M steps/sec
- Complex function: ~800K steps/sec
- Vector ODE (100D): ~400K steps/sec
```

## Comparison with Other Approaches

### MathZig ODE vs. JavaScript Callbacks

Traditional approach (slow):

```javascript
// Calls JS for each time step - very slow
function solveODE() {
    const result = [];
    let y = y0;
    for (let t = t0; t < t_end; t += dt) {
        result.push(y);
        y = jsDerivative(t, y);  // Cross-language call each step!
    }
}
```

MathZig native approach (fast):

```javascript
// All computation in native Zig - very fast
f(t, y) = -0.5 * y;
result = ode_solve(f, y0, [t0, t_end], dt);
```

**Speedup**: 10-100x depending on problem complexity

## Advanced Topics

### Stiff ODEs

For stiff differential equations (where Euler struggles), use RK4 with smaller step sizes:

```javascript
// Stiff system: dy/dt = -1000*y + sin(t)
stiff(t, y) = -1000*y + sin(t)

// Must use small dt for stability
result = ode_solve(stiff, 1, [0, 1], 0.0001)
```

### Event Detection (Planned)

Future versions may support event detection for:
- Root finding (when y = 0)
- State-based termination
- Multiple simulations

### Adaptive Step Size (Planned)

Adaptive RK45 (Dormand-Prince) for automatic step adjustment:

```javascript
// Future API
result = ode45(f, y0, [t0, t_end], tol=1e-6)
```

## Troubleshooting

### Common Errors

1. **"InvalidStep"**: Ensure dt > 0
2. **"UnknownFunction"**: Function must be defined before calling ode_solve
3. **"TypeError"**: Check function signature matches state dimension
4. **"ResultTooLarge"**: Reduce dt or use smaller time span

### Accuracy Verification

Verify results against analytical solutions:

```javascript
// Analytical: y(t) = y0 * exp(-k*t)
// Numerical:
f(t, y) = -0.5 * y
result = ode_solve(f, 1, [0, 10], 0.1)
y_numerical = result[100, 1]  // y(10)
y_analytical = exp(-5)        // ≈ 0.0067
error = abs(y_numerical - y_analytical)
```

## Related Documentation

- [Architecture Overview](overview.md)
- [Time Series Guide](guide_timeseries.md)
- [Source Architecture - ODE Solver](../internals/source_architecture.md#19-ode-solver-functionsodezig)
- [Function Reference](../reference/api.md)
