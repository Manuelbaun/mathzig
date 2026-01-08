# Activation Functions Comparison

This document compares GGML's activation function implementations with MathZig's scalar approaches, focusing on optimization opportunities.

## GGML's GELU Lookup Table

GGML uses a 128KB lookup table for fast GELU approximation:

```c
// From vec.h lines 32-36
// precomputed gelu table for f16 (128 KB)
extern ggml_fp16_t ggml_table_gelu_f16[1 << 16];

// precomputed quick gelu table for f16 (128 KB)
extern ggml_fp16_t ggml_table_gelu_quick_f16[1 << 16];
```

### GELU Lookup Table Structure

```
Address:  0x0000          0x4000          0x8000          0xC000
          +----------------+----------------+----------------+----------------+
Content:  |  fp16 values   |  fp16 values   |  fp16 values   |  fp16 values   |
          |  for 0.0-0.25  |  for 0.25-0.50 |  for 0.50-0.75 |  for 0.75-1.00 |
          +----------------+----------------+----------------+----------------+
Size:     65,536 half-precision floating point values
Total:    128 KB (65,536 values * 2 bytes each)
```

### GELU Lookup Implementation

```c
// From vec.h lines 980-1009
inline static float ggml_gelu_f16(ggml_fp16_t h) {
    const float sign = GGML_CPU_FP16_TO_FP32(h) < 0 ? -1.0f : 1.0f;
    const float x = GGML_CPU_FP16_TO_FP32(h);
    const float x2 = x * x;
    const float x3 = x2 * x;
    const float r = 0.79788456f * (1.0f + 0.044715f * x3);
    
    return sign * x / (1.0f + ggml_exp_impl(-r * x, false));
}

inline static float ggml_gelu_quick_f16(ggml_fp16_t h) {
    const float sign = GGML_CPU_FP16_TO_FP32(h) < 0 ? -1.0f : 1.0f;
    const float x = GGML_CPU_FP16_TO_FP32(h);
    const float x2 = x * x;
    const float x3 = x2 * x;
    const float r = 1.0f + 0.044715f * x3;
    
    return sign * x * r / (1.0f + ggml_exp_impl(-1.702f * x, false));
}
```

### SIMD-Optimized GELU for SVE

```c
// From vec.h lines 1009-1070
inline static void ggml_gelu_f32_sve(const int n, float * y, const float * x) {
    const int sve_register_length = svcntb() * 8;
    const int sve_num_iter = n / (sve_register_length / 32);

    for (int i = 0; i < sve_num_iter; i++) {
        svfloat32_t vx = svld1_f32(svptrue_b32(), x + i * sve_register_length / 32);
        svfloat32_t vx2 = svmul_f32_m(svptrue_b32(), vx, vx);
        svfloat32_t vx3 = svmul_f32_m(svptrue_b32(), vx2, vx);
        svfloat32_t vr = svdup_n_f32(0.79788456f);
        vr = svmad_f32_m(svptrue_b32(), vr, svdup_n_f32(0.044715f), vx3);
        vr = svmul_f32_m(svptrue_b32(), vr, vx);
        svfloat32_t vexp = ggml_v_expf_sve(vr);
        svfloat32_t vexp_neg = svneg_f32_m(svptrue_b32(), vexp);
        vexp_neg = svadd_f32_m(svptrue_b32(), vexp_neg, svdup_n_f32(1.0f));
        svfloat32_t vr_div = svdiv_f32_m(svptrue_b32(), vx, vexp_neg);
        svst1_f32(svptrue_b32(), y + i * sve_register_length / 32, vr_div);
    }
    
    // Scalar remainder
    for (int i = sve_num_iter * sve_register_length / 32; i < n; i++) {
        y[i] = ggml_gelu_f32(x[i]);
    }
}
```

## GGML's SiLU (Swish) Implementation

```c
// From vec.h lines 1076-1130
inline static void ggml_silu_f32(const int n, float * y, const float * x) {
    int i = 0;
#if defined(__AVX2__)
    for (; i + 7 < n; i += 8) {
        __m256 x_vec = _mm256_loadu_ps(x + i);
        __m256 one = _mm256_set1_ps(1.0f);
        __m256 sig = _mm256_div_ps(x_vec, _mm256_add_ps(one, ggml_v_expf_f32(_mm256_sub_ps(_mm256_setzero_ps(), x_vec))));
        _mm256_storeu_ps(y + i, _mm256_mul_ps(x_vec, sig));
    }
#endif
    for (; i < n; ++i) {
        y[i] = x[i] / (1.0f + ggml_exp_impl(-x[i], false));
    }
}
```

## MathZig's Activation Functions

Currently implemented in `vm.zig` with scalar operations:

```zig
// From vm.zig lines 723-945 - Conceptual representation
pub fn gelu(ctx: *Context, a: f64) f64 {
    // Direct scalar computation
    const x = a;
    const x2 = x * x;
    const x3 = x2 * x;
    const r = 0.7978845608028654 * (1.0 + 0.044715998458862305 * x3);
    return x / (1.0 + @exp(-r * x));
}

pub fn silu(ctx: *Context, a: f64) f64 {
    // Direct scalar computation
    return a / (1.0 + @exp(-a));
}

pub fn relu(ctx: *Context, a: f64) f64 {
    return if (a > 0) a else 0.0;
}
```

## Optimization Opportunities

### 1. Lookup Table for Common Inputs

```zig
// Proposed GELU lookup table for MathZig
const GELU_LUT_SIZE = 1 << 16; // 65,536 entries
const GELU_LUT: [GELU_LUT_SIZE]f16 = @import("gelu_table.zig").gelu_lut;

pub fn geluLookup(x: f64) f64 {
    // Convert to f16 bits
    const half = @as(u16, @bitCast(@as(f16, @floatCast(x))));
    
    // Lookup GELU value
    const result = @as(f64, @floatCast(GELU_LUT[half]));
    
    // Handle negative values (sign flip)
    if (x < 0) {
        return -result;
    }
    return result;
}
```

### 2. Polynomial Approximation for SiLU

GGML's SiLU uses polynomial exp approximation. MathZig could implement:

```zig
// Taylor/Minimax polynomial for sigmoid
// sigmoid(x) = 1 / (1 + exp(-x))
// silu(x) = x * sigmoid(x)

const SIGMOID_COEFFS = [_]f64{
    0.5,
    0.1505,  // 0.5 * 0.301
    0.125,   // 0.5 * 0.25
    0.0875,  // 0.5 * 0.175
};

pub fn sigmoidPolynomial(x: f64) f64 {
    // For |x| < 3, Taylor series converges quickly
    if (@abs(x) < 3.0) {
        const x2 = x * x;
        const exp_approx = 1.0 + x + x2 * 0.5 + x2 * x * 0.16666666666666666;
        return 1.0 / exp_approx;
    }
    
    // For larger |x|, use exp directly
    return 1.0 / (1.0 + @exp(-x));
}

pub fn siluPolynomial(x: f64) f64 {
    return x * sigmoidPolynomial(x);
}
```

### 3. SIMD Vectorized Activations

```zig
// Proposed SIMD activations for MathZig
pub fn geluVec(a: []const f64, out: []f64) void {
    const vec_count = @min(a.len, out.len) / VectorLen;
    
    var i: usize = 0;
    while (i < vec_count) : (i += 1) {
        const offset = i * VectorLen;
        const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
        
        // Vectorized GELU: x / (1 + exp(-0.79788456*x*(1+0.044715*x^3)))
        const x = va;
        const x2 = x * x;
        const x3 = x2 * x;
        const r = @splat(0.79788456) * (@splat(1.0) + @splat(0.044715) * x3);
        const r_x = r * x;
        const exp_neg_rx = @exp(-r_x);
        const result = x / (@splat(1.0) + exp_neg_rx);
        
        @as(*Vec, @ptrCast(@alignCast(out.ptr + offset))).* = result;
    }
    
    // Scalar remainder
    var j = vec_count * VectorLen;
    while (j < a.len) : (j += 1) {
        out[j] = gelu(a[j]);
    }
}

pub fn siluVec(a: []const f64, out: []f64) void {
    const vec_count = @min(a.len, out.len) / VectorLen;
    
    var i: usize = 0;
    while (i < vec_count) : (i += 1) {
        const offset = i * VectorLen;
        const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
        
        // Vectorized SiLU: x / (1 + exp(-x))
        const sig = va / (@splat(1.0) + @exp(-va));
        const result = va * sig;
        
        @as(*Vec, @ptrCast(@alignCast(out.ptr + offset))).* = result;
    }
    
    // Scalar remainder
    var j = vec_count * VectorLen;
    while (j < a.len) : (j += 1) {
        out[j] = silu(a[j]);
    }
}
```

### 4. Softmax with Numerical Stability

GGML's softmax uses max-subtraction for numerical stability:

```c
// From vec.h - Conceptual
void ggml_soft_max_f32(float * y, float * x, int n) {
    // Find max for numerical stability
    float max_val = x[0];
    for (int i = 1; i < n; i++) {
        if (x[i] > max_val) max_val = x[i];
    }
    
    // Subtract max and compute exp
    float sum = 0;
    for (int i = 0; i < n; i++) {
        y[i] = exp(x[i] - max_val);
        sum += y[i];
    }
    
    // Normalize
    for (int i = 0; i < n; i++) {
        y[i] /= sum;
    }
}
```

```zig
// MathZig softmax with stability
pub fn softmax(x: []const f64, out: []f64) void {
    const len = @min(x.len, out.len);
    
    // Find maximum for numerical stability
    var max_val = x[0];
    for (x[1..len]) |v| {
        if (v > max_val) max_val = v;
    }
    
    // Compute exp(x - max) and sum
    var sum: f64 = 0.0;
    for (0..len) |i| {
        out[i] = @exp(x[i] - max_val);
        sum += out[i];
    }
    
    // Normalize
    const inv_sum = 1.0 / sum;
    for (0..len) |i| {
        out[i] *= inv_sum;
    }
}
```

## Performance Comparison

| Operation | GGML Method | MathZig Current | Potential Improvement |
|-----------|-------------|-----------------|----------------------|
| GELU | 128KB LUT (fast lookup) | Scalar exp (slow) | 5-10x for LUT hits |
| SiLU | SIMD polynomial | Scalar exp | 3-5x with SIMD |
| Softmax | SIMD + max-sub | Scalar | 4-6x with SIMD |
| Memory | 128KB (negligible) | 0 | +128KB RAM |

## Implementation Priority

1. **High Priority**: Vectorized activations (geluVec, siluVec)
2. **Medium Priority**: Lookup table for GELU (if f16 support added)
3. **Medium Priority**: Polynomial approximation for exp
4. **Low Priority**: Softmax vectorization (less common in MathZig)
