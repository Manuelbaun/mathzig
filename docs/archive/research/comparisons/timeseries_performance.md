# Time-Series Performance Optimization

This document outlines the performance strategies for the MathZig Time-Series Engine, focusing on SIMD vectorization and multi-core parallelism.

## 1. Architectural Foundation

### SoA (Struct of Arrays) Layout
The `Series` data structure uses an SoA layout instead of AoS (Array of Structs).
- **AoS (Bad for SIMD):** `[{ts, val}, {ts, val}]`
- **SoA (MathZig):** `[ts, ts], [val, val]`

This allows the CPU to load 4 or 8 consecutive values into a single SIMD register (YMM/XMM) without shuffling memory.

### SIMD Alignment
All arrays in `Series` are **32-byte aligned**. This ensures:
- Compatibility with **AVX-256** (4x f64).
- No performance penalty for misaligned loads.
- Direct mapping to hardware vector types (`@Vector(4, f64)`).

---

## 2. SIMD Vectorization Strategy

### Completed Optimizations
- [x] **Aligned Memory:** Primary buffers use 32-byte alignment.
- [x] **Predicate Evaluation:** Simple comparisons (e.g., `value > threshold`) use explicit SIMD bit-packing to generate filter bitmaps.

### Planned SIMD Improvements (High Priority)
- [ ] **Aggregations (Sum, Mean):** Use horizontal SIMD addition.
- [ ] **TWA (Time-Weighted Average):** Vectorize the trapezoidal rule: `(v[i..i+4] + v[i-1..i+3]) * 0.5 * (ts[i..i+4] - ts[i-1..i+3])`.
- [ ] **Derivative/Integral:** Vectorize delta-time and area calculations.
- [ ] **Indicator Kernels:** EMA and RSI can be vectorized in blocks, though they are recursive.

---

## 3. Parallel Evaluation

For large datasets (>100k samples), MathZig leverages multi-core parallelism.

### Work Stealing / Work Splitting
Operations are split into chunks and distributed across the VM's thread pool.

| Operation | Parallel Strategy | Progress |
|-----------|-------------------|----------|
| **Aggregations** | Split series into $N$ segments, compute partial results, merge. | [ ] |
| **Resampling** | Buckets are independent; distribute bucket ranges to cores. | [ ] |
| **Joins** | Split target timestamp array and perform independent as-of lookups. | [ ] |
| **Indicators** | Split into large overlapping windows (requires state carry). | [ ] |

---

## 4. Optimization Roadmap & Benchmarks

### Target Throughput (10M samples)

| Operation | Current (Scalar) | Target (SIMD + Parallel) | Expected Boost |
|-----------|------------------|--------------------------|----------------|
| `sum()` | ~10ms | <1ms | 10x |
| `twa()` | ~15ms | <2ms | 7x |
| `derivative()` | ~35ms | <5ms | 7x |
| `resample()` | ~30ms | <4ms | 7x |
| `asofJoin()` | ~40ms | <10ms | 4x |

### Known Bottlenecks
1. **Branching in Predicates:** Scalar `if (evaluate())` destroys pipeline efficiency. Solution: Use SIMD bitmaps and mask loads.
2. **Memory Allocation:** `resample` and `derivative` allocate new `Series`. Solution: Use `ChunkArena` or pool-based series buffers.
3. **Data Dependency:** EMA/RSI are inherently sequential. Solution: Sub-sampling or "Parallel Prefix Sum" style algorithms.

---

## 5. Summary of Tasks

### Parallelism (The "Big Step")
- [ ] Implement `parSum`, `parTwa`, `parResample` using `std.Thread.Pool`.
- [ ] Integrate with `MathZig.thread_pool`.

### Deep SIMD
- [ ] Implement `@Vector` kernels for all arithmetic in `calculus.zig`.
- [ ] Implement SIMD-accelerated linear interpolation for aligned as-of joins.
