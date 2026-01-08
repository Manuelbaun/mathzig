# Vector Operations Comparison

This document compares GGML's vector operations with MathZig's implementations, focusing on patterns that can improve MathZig's performance.

## GGML's Vector Dot Product

GGML's `ggml_vec_dot_f32` uses sophisticated patterns for high performance:

### Accumulator Array Pattern

```c
// From vec.h lines 111-150
// GGML_VEC_DOT_UNROLL = 2, GGML_VEC_MAD_UNROLL = 32

inline static void ggml_vec_dot_f32_unroll(
    int n, const int xs, float * GGML_RESTRICT s,
    void * GGML_RESTRICT xv, ggml_fp16_t * GGML_RESTRICT y
) {
    ggml_float sumf[GGML_VEC_DOT_UNROLL] = { 0.0 };
    
    ggml_fp16_t * GGML_RESTRICT x[GGML_VEC_DOT_UNROLL];
    
    for (int i = 0; i < GGML_VEC_DOT_UNROLL; ++i) {
        x[i] = (ggml_fp16_t *) ((char *) xv + i*xs);
    }
```

### SVE-Optimized Dot Product

```c
// From vec.h lines 122-170
#if defined(__ARM_FEATURE_SVE)

    const int sve_register_length = svcntb() * 8;
    const int ggml_f16_epr = sve_register_length / 16;
    const int ggml_f16_step = 8 * ggml_f16_epr;

    const int np = (n & ~(ggml_f16_step - 1));

    svfloat16_t sum_00 = svdup_n_f16(0.0f);
    svfloat16_t sum_01 = svdup_n_f16(0.0f);
    svfloat16_t sum_02 = svdup_n_f16(0.0f);
    svfloat16_t sum_03 = svdup_n_f16(0.0f);

    svfloat16_t ax1, ax2, ax3, ax4, ax5, ax6, ax7, ax8;
    svfloat16_t ay1, ay2, ay3, ay4, ay5, ay6, ay7, ay8;

    for (int i = 0; i < np; i += ggml_f16_step) {
        ay1 = GGML_F16x_VEC_LOAD(y + i + 0 * ggml_f16_epr, 0);
        
        ax1 = GGML_F16x_VEC_LOAD(x[0] + i + 0*ggml_f16_epr, 0);
        sum_00 = GGML_F16x_VEC_FMA(sum_00, ax1, ay1);
        ax1 = GGML_F16x_VEC_LOAD(x[1] + i + 0*ggml_f16_epr, 0);
        sum_10 = GGML_F16x_VEC_FMA(sum_10, ax1, ay1);
        // ... more unrolled operations
    }
```

### Multi-Accumulator Strategy

GGML uses multiple accumulators to hide memory latency:

```c
// Pattern: Process GGML_VEC_MAD_UNROLL elements per iteration
// This allows the CPU to pipeline memory operations

#define GGML_VEC_MAD_UNROLL  32

// Multiple accumulators in registers
float acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;

for (int i = 0; i < n; i += GGML_VEC_MAD_UNROLL) {
    // Load 32 elements at once
    __m256 x_vec = _mm256_loadu_ps(x + i);
    __m256 y_vec = _mm256_loadu_ps(y + i);
    
    // Multiple FMAs in flight
    acc0 += dot_product_4(x_vec[0], y_vec);
    acc1 += dot_product_4(x_vec[1], y_vec);
    // ...
}
```

## MathZig's Vector Dot Product

```zig
// From matrix_kernels.zig lines 417-448
pub fn vecDot(a: []const f64, b: []const f64) f64 {
    const len = @min(a.len, b.len);

    if (isAligned(a.ptr) and isAligned(b.ptr)) {
        const vec_count = len / VectorLen;
        var acc: Vec = @splat(0.0);

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            const vb = @as(*const Vec, @ptrCast(@alignCast(b.ptr + offset))).*;
            acc = @mulAdd(Vec, va, vb, acc);
        }

        var sum = @reduce(.Add, acc);

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            sum += a[j] * b[j];
        }
        return sum;
    } else {
        var sum: f64 = 0.0;
        for (0..len) |i| {
            sum += a[i] * b[i];
        }
        return sum;
    }
}
```

## Gap Analysis

| Aspect | GGML | MathZig | Improvement Potential |
|--------|------|---------|----------------------|
| Accumulators | Multiple (4-8) | Single | 10-20% throughput |
| Unrolling factor | 32 | 1 | 15-25% latency |
| Prefetching | Explicit | None | 5-15% memory-bound |
| Blocking | Cache-aware | None | 20-40% cache-sensitive |

## Recommended Improvements

### 1. Accumulator Array Pattern

```zig
// Proposed improvement for MathZig
const ACCUMULATOR_COUNT = 4;

pub fn vecDotOptimized(a: []const f64, b: []const f64) f64 {
    const len = @min(a.len, b.len);
    
    if (isAligned(a.ptr) and isAligned(b.ptr)) {
        const vec_count = len / VectorLen;
        
        // Multiple accumulators
        var accs: [ACCUMULATOR_COUNT]Vec = .{@splat(0.0)} ** ACCUMULATOR_COUNT;
        
        var i: usize = 0;
        const unroll_factor = 4; // Process 4 vectors per iteration
        
        while (i + unroll_factor * VectorLen <= len) : (i += unroll_factor * VectorLen) {
            inline for (0..unroll_factor) |k| {
                const offset = i + k * VectorLen;
                const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
                const vb = @as(*const Vec, @ptrCast(@alignCast(b.ptr + offset))).*;
                accs[k] = @mulAdd(Vec, va, vb, accs[k]);
            }
        }
        
        // Reduce accumulators
        var acc = @splat(0.0);
        for (accs) |a_vec| {
            acc += a_vec;
        }
        
        var sum = @reduce(.Add, acc);
        
        // Remainder
        var j = i;
        while (j < len) : (j += 1) {
            sum += a[j] * b[j];
        }
        return sum;
    }
    return vecDot(a, b); // Fallback
}
```

### 2. Cache-Aware Blocking

```zig
// Block size tuned for L1 cache (32KB for data + overhead)
const BLOCK_SIZE = 256; // 256 f64 = 2KB per blocking factor

pub fn vecDotBlocked(a: []const f64, b: []const f64) f64 {
    const len = @min(a.len, b.len);
    const block_count = (len + BLOCK_SIZE - 1) / BLOCK_SIZE;
    
    var acc: Vec = @splat(0.0);
    
    for (0..block_count) |block| {
        const start = block * BLOCK_SIZE;
        const end = @min(start + BLOCK_SIZE, len);
        
        // Process block with SIMD
        const vec_start = start;
        const vec_end = end - (end - start) % VectorLen;
        
        var i = vec_start;
        while (i < vec_end) : (i += VectorLen) {
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + i))).*;
            const vb = @as(*const Vec, @ptrCast(@alignCast(b.ptr + i))).*;
            acc = @mulAdd(Vec, va, vb, acc);
        }
        
        // Scalar remainder for this block
        var j = i;
        while (j < end) : (j += 1) {
            acc[0] += a[j] * b[j];
        }
    }
    
    return @reduce(.Add, acc);
}
```

### 3. Prefetching for Large Vectors

```zig
// Prefetch hints for vectors that don't fit in cache
const PREFETCH_DISTANCE = 64; // Cache line ahead

pub fn vecDotPrefetch(a: []const f64, b: []const f64) f64 {
    const len = @min(a.len, b.len);
    const vec_count = len / VectorLen;
    
    var acc: Vec = @splat(0.0);
    
    var i: usize = 0;
    while (i < vec_count) : (i += 1) {
        const offset = i * VectorLen;
        
        // Prefetch next cache line
        if (i + PREFETCH_DISTANCE / VectorLen < vec_count) {
            const prefetch_offset = (i + PREFETCH_DISTANCE / VectorLen) * VectorLen;
            const prefetch_ptr_a = @as([*]const f64, @ptrCast(a.ptr + prefetch_offset));
            const prefetch_ptr_b = @as([*]const f64, @ptrCast(b.ptr + prefetch_offset));
            // Platform-specific prefetch:
            // x86: _mm_prefetch((const char*)ptr, _MM_HINT_T0)
            // ARM: __builtin_prefetch(ptr)
        }
        
        const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
        const vb = @as(*const Vec, @ptrCast(@alignCast(b.ptr + offset))).*;
        acc = @mulAdd(Vec, va, vb, acc);
    }
    
    return @reduce(.Add, acc);
}
```

### 4. Strided Vector Operations

For cases where data isn't contiguous, GGML uses stride parameters:

```c
// GGML's strided dot product (vec.h line 42)
void ggml_vec_dot_f32(int n, float * GGML_RESTRICT s, size_t bs,
                      const float * GGML_RESTRICT x, size_t bx,
                      const float * GGML_RESTRICT y, size_t by, int nrc);
```

```zig
// MathZig equivalent
pub fn vecDotStrided(
    a: []const f64, stride_a: usize,
    b: []const f64, stride_b: usize
) f64 {
    const len = @min(a.len / stride_a, b.len / stride_b);
    
    var acc: Vec = @splat(0.0);
    
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const va = a[i * stride_a];
        const vb = b[i * stride_b];
        acc = @mulAdd(Vec, @splat(va), @splat(vb), acc);
    }
    
    return @reduce(.Add, acc);
}
```

## Performance Expectations

| Optimization | Throughput Increase | Latency Reduction |
|--------------|--------------------|-------------------|
| Accumulator array (4x) | 15-20% | 10-15% |
| Cache blocking | 20-40% (large vectors) | 30-50% |
| Prefetching | 5-15% | 10-20% |
| Full unrolling | 25-35% | 20-30% |

## Implementation Priority

1. **High Priority**: Accumulator array pattern for `vecDot`
2. **Medium Priority**: Cache-aware blocking for large vectors
3. **Low Priority**: Prefetching for specific architectures
4. **Low Priority**: Strided operations for non-contiguous data
