# Activation Functions

GGML implements optimized activation functions used in neural networks, with special attention to performance-critical operations like GELU and SiLU.

## GELU (Gaussian Error Linear Unit)

The GELU activation function used in transformers:

```
GELU(x) = 0.5 * x * (1 + tanh(sqrt(2/pi) * x * (1 + 0.044715 * x^2)))
```

### FP16 Lookup Table Optimization

GGML uses a 128KB lookup table for FP16 GELU:

```c
// precomputed gelu table for f16 (128 KB)
extern ggml_fp16_t ggml_table_gelu_f16[1 << 16];

inline static void ggml_vec_gelu_f16(const int n, ggml_fp16_t * y,
                                     const ggml_fp16_t * x) {
    const uint16_t * i16 = (const uint16_t *) x;
    for (int i = 0; i < n; ++i) {
        y[i] = ggml_table_gelu_f16[i16[i]];
    }
}
```

**Why lookup table works:**
- FP16 has only 65,536 possible values
- Precomputing GELU for all values eliminates runtime computation
- One table lookup = O(1) vs. multiple exp/tanh operations

### FP32 Implementation with Lookup

```c
inline static void ggml_vec_gelu_f32(const int n, float * y,
                                     const float * x) {
    uint16_t t;
    for (int i = 0; i < n; ++i) {
        if (x[i] <= -10.0f) {
            y[i] = 0.0f;  // Clamp extreme values
        } else if (x[i] >= 10.0f) {
            y[i] = x[i];
        } else {
            ggml_fp16_t fp16 = GGML_CPU_FP32_TO_FP16(x[i]);
            memcpy(&t, &fp16, sizeof(uint16_t));
            y[i] = GGML_CPU_FP16_TO_FP32(ggml_table_gelu_f16[t]);
        }
    }
}
```

**Optimization techniques:**
1. **Clamping**: Values outside [-10, 10] use simple approximations
2. **FP16 conversion**: Convert to FP16 for fast table lookup
3. **Scalar tail**: Fallback for edge cases

### Scalar GELU

```c
inline static float ggml_gelu_f32(float x) {
    return 0.5f*x*(1.0f + tanhf(SQRT_2_OVER_PI*x*(1.0f + GELU_COEF_A*x*x)));
}

static const float GELU_COEF_A = 0.044715f;
static const float SQRT_2_OVER_PI = 0.79788456080286535587989211986876f;
```

## Quick GELU

A faster approximation used in some models:

```
QuickGELU(x) = x * (1 / (1 + exp(-1.702 * x)))
```

```c
static const float GELU_QUICK_COEF = -1.702f;

inline static float ggml_gelu_quick_f32(float x) {
    return x*(1.0f/(1.0f+expf(GELU_QUICK_COEF*x)));
}

inline static void ggml_vec_gelu_quick_f32(const int n, float * y,
                                           const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] = ggml_gelu_quick_f32(x[i]);
    }
}
```

**Advantages:**
- Single sigmoid instead of tanh
- Faster to compute
- Used in lightweight models

## SiLU (Sigmoid Linear Unit / Swish)

```
SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x))
```

### Vectorized SiLU with Exp

```c
inline static float ggml_silu_f32(float x) {
    return x/(1.0f + expf(-x));
}
```

### SIMD-Optimized SiLU

GGML provides architecture-specific optimized exp and SiLU:

**AVX2 Implementation:**
```c
inline static __m256 ggml_v_expf(__m256 x) {
    const __m256 r = _mm256_set1_ps(0x1.8p23f);
    const __m256 z = _mm256_fmadd_ps(x, _mm256_set1_ps(0x1.715476p+0f), r);
    const __m256 n = _mm256_sub_ps(z, r);
    const __m256 b = _mm256_fnmadd_ps(n, _mm256_set1_ps(0x1.7f7d1cp-20f),
                                      _mm256_fnmadd_ps(n, _mm256_set1_ps(0x1.62e4p-1f), x));
    // ... polynomial approximation and exponentiation
}

inline static __m256 ggml_v_silu(__m256 x) {
    const __m256 one = _mm256_set1_ps(1);
    const __m256 zero = _mm256_setzero_ps();
    const __m256 neg_x = _mm256_sub_ps(zero, x);
    const __m256 exp_neg_x = ggml_v_expf(neg_x);
    const __m256 one_plus_exp_neg_x = _mm256_add_ps(one, exp_neg_x);
    return _mm256_div_ps(x, one_plus_exp_neg_x);
}
```

**NEON Implementation:**
```c
inline static float32x4_t ggml_v_expf(float32x4_t x) {
    const float32x4_t r = vdupq_n_f32(0x1.8p23f);
    const float32x4_t z = vfmaq_f32(r, x, vdupq_n_f32(0x1.715476p+0f));
    const float32x4_t n = vsubq_f32(z, r);
    const float32x4_t b = vfmsq_f32(vfmsq_f32(x, n, vdupq_n_f32(0x1.62e4p-1f)), n,
                                    vdupq_n_f32(0x1.7f7d1cp-20f));
    // ... continuation of exp algorithm
}

inline static float32x4_t ggml_v_silu(float32x4_t x) {
    const float32x4_t one = vdupq_n_f32(1.0f);
    const float32x4_t zero = vdupq_n_f32(0.0f);
    const float32x4_t neg_x = vsubq_f32(zero, x);
    const float32x4_t exp_neg_x = ggml_v_expf(neg_x);
    const float32x4_t one_plus_exp_neg_x = vaddq_f32(one, exp_neg_x);
    return vdivq_f32(x, one_plus_exp_neg_x);
}
```

**Algorithm:**
1. **Exponent approximation**: Polynomial-based exp(x) for range [-10, 10]
2. **Handle overflow**: Clamp extreme values to prevent inf
3. **Division**: Compute sigmoid = 1 / (1 + exp(-x))
4. **Multiply**: SiLU = x * sigmoid

### SiLU Backward

```c
inline static float ggml_silu_backward_f32(float x, float dy) {
    const float s = 1.0f/(1.0f + expf(-x));
    return dy*s*(1.0f + x*(1.0f - s));
}
```

## Softmax

Softmax is critical for attention mechanisms:

```
softmax(x_i) = exp(x_i) / sum(exp(x_j))
```

### Max-Subtraction Optimization

```c
ggml_float ggml_vec_soft_max_f32(const int n, float * y,
                                  const float * x, float max) {
    // Compute exp(x - max) for numerical stability
    // Sum all exp values
    // Divide each exp by sum
}
```

**Numerical stability:**
```c
// Instead of: softmax(x_i) = exp(x_i) / sum(exp(x_j))
// Use: softmax(x_i) = exp(x_i - max) / sum(exp(x_j - max))
// This prevents overflow when x has large values
```

### Softmax with SIMD

```c
// Find max value
float max_val = x[0];
for (int i = 1; i < n; ++i) {
    if (x[i] > max_val) max_val = x[i];
}

// Compute exp(x - max) and sum
ggml_float sum = 0;
for (int i = 0; i < n; ++i) {
    float exp_val = expf(x[i] - max_val);
    y[i] = exp_val;
    sum += exp_val;
}

// Normalize
for (int i = 0; i < n; ++i) {
    y[i] = y[i] / (float)sum;
}
```

## Other Activation Functions

### ReLU (Rectified Linear Unit)

```c
inline static void ggml_vec_relu_f32(const int n, float * y,
                                     const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] = (x[i] > 0.f) ? x[i] : 0.f;
    }
}
```

### Leaky ReLU

```c
inline static void ggml_vec_leaky_relu_f32(const int n, float * y,
                                           const float * x, const float ns) {
    for (int i = 0; i < n; ++i) {
        y[i] = ((x[i] > 0.f) ? x[i] : 0.f) + ns * ((x[i] < 0.0f) ? x[i] : 0.f);
    }
}
```

### Sigmoid

```c
inline static void ggml_vec_sigmoid_f32(const int n, float * y,
                                        const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] = 1.f / (1.f + expf(-x[i]));
    }
}
```

### Hard Swish

```c
inline static void ggml_vec_hardswish_f32(const int n, float * y,
                                          const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] = x[i] * fminf(1.0f, fmaxf(0.0f, (x[i] + 3.0f) / 6.0f));
    }
}
```

### Hard Sigmoid

```c
inline static void ggml_vec_hardsigmoid_f32(const int n, float * y,
                                            const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] = fminf(1.0f, fmaxf(0.0f, (x[i] + 3.0f) / 6.0f));
    }
}
```

### Tanh

```c
inline static void ggml_vec_tanh_f32(const int n, float * y,
                                     const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] = tanhf(x[i]);
    }
}
```

### ELU (Exponential Linear Unit)

```c
inline static void ggml_vec_elu_f32(const int n, float * y,
                                    const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] = (x[i] > 0.f) ? x[i] : expm1f(x[i]);
    }
}
```

## Activation Function Summary

| Function | Formula | Use Case | Optimized |
|----------|---------|----------|-----------|
| GELU | 0.5*x*(1 + tanh(...)) | Transformers | FP16 LUT |
| QuickGELU | x/(1 + exp(-1.702x)) | Lightweight | Yes |
| SiLU | x/(1 + exp(-x)) | SwiGLU | SIMD |
| ReLU | max(0, x) | General | Scalar |
| Leaky ReLU | x > 0 ? x : 0.01x | GANs | Scalar |
| Sigmoid | 1/(1 + exp(-x)) | Output layer | Scalar |
| Softmax | exp(x)/sum(exp(x)) | Classification | Yes |
| Tanh | tanh(x) | LSTM | Scalar |

## Performance Notes

1. **GELU**: Lookup table eliminates all transcendental operations
2. **SiLU**: Polynomial exp approximation is 5-10x faster than libm
3. **Softmax**: Max-subtraction prevents overflow
4. **Simple activations**: Scalar implementations are fast enough
