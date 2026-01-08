# Vector Operations

GGML provides highly optimized vector operations that form the foundation of all tensor computations.

## Fundamental Vector Operations

### Vector Dot Product (FP32)

Computes the dot product of two vectors: sum(x[i] * y[i])

```c
void ggml_vec_dot_f32(int n, float * GGML_RESTRICT s, size_t bs,
                      const float * GGML_RESTRICT x, size_t bx,
                      const float * GGML_RESTRICT y, size_t by, int nrc);
```

**Implementation with SIMD unrolling:**
```c
inline static void ggml_vec_dot_f32(int n, float * s, size_t bs,
                                    const float * x, size_t bx,
                                    const float * y, size_t by, int nrc) {
    ggml_float sum = 0.0f;

#if defined(GGML_SIMD)
    const int np = (n & ~(GGML_F32_STEP - 1));

    GGML_F32_VEC sum_vec[GGML_F32_ARR] = { 0 };

    for (int i = 0; i < np; i += GGML_F32_STEP) {
        for (int j = 0; j < GGML_F32_ARR; j++) {
            GGML_F32_VEC xi = GGML_F32_VEC_LOAD(x + i + j*GGML_F32_EPR);
            GGML_F32_VEC yi = GGML_F32_VEC_LOAD(y + i + j*GGML_F32_EPR);
            sum_vec[j] = GGML_F32_VEC_FMA(sum_vec[j], xi, yi);
        }
    }

    // Horizontal sum reduction
    GGML_F32_VEC_REDUCE(sum, sum_vec);

    // Scalar tail
    for (int i = np; i < n; ++i) {
        sum += (ggml_float)(x[i] * y[i]);
    }
#else
    // Scalar fallback
    for (int i = 0; i < n; ++i) {
        sum += (ggml_float)(x[i] * y[i]);
    }
#endif

    *s = (float)sum;
}
```

**Key techniques:**
1. **Register blocking**: Process GGML_F32_STEP elements per iteration
2. **Accumulator array**: Multiple accumulators to hide latency
3. **Tree reduction**: Pairwise summation before horizontal add
4. **Scalar tail**: Handle non-aligned remainders

### Vector Multiply-Add (FMA)

Computes: y[i] += x[i] * v (multiply by scalar, add to accumulator)

```c
inline static void ggml_vec_mad_f32(const int n, float * y,
                                    const float * x, const float v) {
#if defined(GGML_SIMD)
    const int np = (n & ~(GGML_F32_STEP - 1));

    GGML_F32_VEC vx = GGML_F32_VEC_SET1(v);

    for (int i = 0; i < np; i += GGML_F32_STEP) {
        for (int j = 0; j < GGML_F32_ARR; j++) {
            GGML_F32_VEC xi = GGML_F32_VEC_LOAD(x + i + j*GGML_F32_EPR);
            GGML_F32_VEC yi = GGML_F32_VEC_LOAD(y + i + j*GGML_F32_EPR);
            yi = GGML_F32_VEC_FMA(yi, xi, vx);
            GGML_F32_VEC_STORE(y + i + j*GGML_F32_EPR, yi);
        }
    }

    for (int i = np; i < n; ++i) {
        y[i] += x[i] * v;
    }
#else
    for (int i = 0; i < n; ++i) {
        y[i] += x[i] * v;
    }
#endif
}
```

**Why MAD is critical for matmul:**
```c
// Naive: C[i,j] += A[i,k] * B[k,j]
// GGML: y[i] += x[i] * scale  (used in blocking)
```

### Vector Scale

Multiplies all elements by a scalar:

```c
inline static void ggml_vec_scale_f32(const int n, float * x, float v) {
#if defined(GGML_SIMD)
    GGML_F32_VEC xv = GGML_F32_VEC_SET1(v);
    const int np = (n & ~(GGML_F32_STEP - 1));

    for (int i = 0; i < np; i += GGML_F32_STEP) {
        for (int j = 0; j < GGML_F32_ARR; j++) {
            GGML_F32_VEC xi = GGML_F32_VEC_LOAD(x + i + j*GGML_F32_EPR);
            xi = GGML_F32_VEC_MUL(xi, xv);
            GGML_F32_VEC_STORE(x + i + j*GGML_F32_EPR, xi);
        }
    }

    for (int i = np; i < n; ++i) {
        x[i] *= v;
    }
#else
    for (int i = 0; i < n; ++i) {
        x[i] *= v;
    }
#endif
}
```

### Element-wise Operations

**Addition:**
```c
inline static void ggml_vec_add_f32(const int n, float * z,
                                    const float * x, const float * y) {
    int i = 0;
#if defined(__AVX2__)
    for (; i + 7 < n; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vy = _mm256_loadu_ps(y + i);
        __m256 vz = _mm256_add_ps(vx, vy);
        _mm256_storeu_ps(z + i, vz);
    }
#endif
    for (; i < n; ++i) {
        z[i] = x[i] + y[i];
    }
}
```

**Multiplication:**
```c
inline static void ggml_vec_mul_f32(const int n, float * z,
                                    const float * x, const float * y) {
    for (int i = 0; i < n; ++i) {
        z[i] = x[i] * y[i];
    }
}
```

**Subtraction:**
```c
inline static void ggml_vec_sub_f32(const int n, float * z,
                                    const float * x, const float * y) {
    for (int i = 0; i < n; ++i) {
        z[i] = x[i] - y[i];
    }
}
```

**Accumulate:**
```c
inline static void ggml_vec_acc_f32(const int n, float * y,
                                    const float * x) {
    for (int i = 0; i < n; ++i) {
        y[i] += x[i];
    }
}
```

## Unrolling Strategy

GGML uses aggressive loop unrolling to maximize performance:

```c
#define GGML_VEC_DOT_UNROLL  2   // 2 dot products simultaneously
#define GGML_VEC_MAD_UNROLL  32  // 32-wide unrolling for FMA
```

### Dot Product Unrolling

```c
inline static void ggml_vec_dot_f16_unroll(const int n, const int xs,
                                           float * s, void * xv,
                                           ggml_fp16_t * y) {
    ggml_float sumf[GGML_VEC_DOT_UNROLL] = { 0.0 };

#if defined(GGML_SIMD)
    GGML_F16_VEC sum[GGML_VEC_DOT_UNROLL][GGML_F16_ARR] = { { 0 } };

    for (int i = 0; i < np; i += GGML_F16_STEP) {
        for (int j = 0; j < GGML_F16_ARR; j++) {
            GGML_F16_VEC yj = GGML_F16_VEC_LOAD(y + i + j*GGML_F16_EPR, j);

            for (int k = 0; k < GGML_VEC_DOT_UNROLL; ++k) {
                GGML_F16_VEC xk = GGML_F16_VEC_LOAD(x[k] + i + j*GGML_F16_EPR, j);
                sum[k][j] = GGML_F16_VEC_FMA(sum[k][j], xk, yj);
            }
        }
    }

    for (int k = 0; k < GGML_VEC_DOT_UNROLL; ++k) {
        GGML_F16_VEC_REDUCE(sumf[k], sum[k]);
    }
#endif

    for (int i = 0; i < GGML_VEC_DOT_UNROLL; ++i) {
        s[i] = (float)sumf[i];
    }
}
```

**Unrolling benefits:**
1. **Instruction-level parallelism**: Multiple independent operations
2. **Register pressure**: Keep more data in registers
3. **Branch reduction**: Fewer loop overhead instructions
4. **Cache utilization**: Better temporal locality

## FMA Optimization Pattern

The Multiply-Add pattern is the heart of GGML performance:

```c
// ggml_vec_mad_f32 inner loop
for (int j = 0; j < GGML_F32_ARR; j++) {
    ax[j] = GGML_F32_VEC_LOAD(x + i + j*GGML_F32_EPR);
    ay[j] = GGML_F32_VEC_LOAD(y + i + j*GGML_F32_EPR);
    ay[j] = GGML_F32_VEC_FMA(ay[j], ax[j], vx);  // y += x * v
    GGML_F32_VEC_STORE(y + i + j*GGML_F32_EPR, ay[j]);
}
```

**Why FMA matters:**
- 1 instruction instead of mul + add
- Single rounding (better precision)
- Higher throughput on all modern CPUs

## Accumulator Strategy

Multiple accumulators hide FMA latency:

```c
// AVX2 example: 4 accumulators
__m256 sum0 = _mm256_setzero_ps();
__m256 sum1 = _mm256_setzero_ps();
__m256 sum2 = _mm256_setzero_ps();
__m256 sum3 = _mm256_setzero_ps();

for (int i = 0; i < n; i += 32) {
    __m256 a0 = _mm256_loadu_ps(&a[i]);
    __m256 a1 = _mm256_loadu_ps(&a[i + 8]);
    __m256 b0 = _mm256_loadu_ps(&b[i]);
    __m256 b1 = _mm256_loadu_ps(&b[i + 8]);

    sum0 = _mm256_fmadd_ps(a0, b0, sum0);
    sum1 = _mm256_fmadd_ps(a1, b1, sum1);
}

// Final reduction
__m256 sum = _mm256_add_ps(sum0, sum1);
```

**Latency hiding:**
- FMA latency: 4-5 cycles on modern CPUs
- Multiple accumulators allow back-to-back FMAs
- CPU can issue FMA every cycle

## SVE Optimizations

ARM SVE provides flexible vector width:

```c
#if defined(__ARM_FEATURE_SVE)
const int sve_register_length = svcntb() * 8;
const int ggml_f32_epr = sve_register_length / 32;  // 4, 8, or 16
const int ggml_f32_step = 8 * ggml_f32_epr;

svfloat32_t ax1, ay1;
// ...
for (int i = 0; i < np; i += ggml_f32_step) {
    ax1 = svld1_f32(svptrue_b32(), x + i);
    ay1 = svld1_f32(svptrue_b32(), y + i);
    ay1 = svmad_f32_m(svptrue_b32(), ax1, vx, ay1);
    svst1_f32(svptrue_b32(), y + i, ay1);
}
#endif
```

**SVE advantages:**
- Predicated loads/stores handle remainders
- Variable vector length (128-2048 bits)
- Same code works on all SVE widths

## RISC-V Vector Extension

```c
#if defined(__riscv_v_intrinsic)
for (int i = 0, avl; i < n; i += avl) {
    avl = __riscv_vsetvl_e32m8(n - i);
    vfloat32m8_t ax = __riscv_vle32_v_f32m8(&x[i], avl);
    vfloat32m8_t ay = __riscv_vle32_v_f32m8(&y[i], avl);
    vfloat32m8_t ny = __riscv_vfmadd_vf_f32m8(ax, v, ay, avl);
    __riscv_vse32_v_f32m8(&y[i], ny, avl);
}
#endif
```

**RISC-V V features:**
- Automatic vector length selection
- Masked operations
- Widening multiply-add for FP16

## Vector Operations Summary

| Operation | SIMD Benefit | Typical Speedup |
|-----------|-------------|-----------------|
| vec_dot | FMA + reduction | 4-8x |
| vec_mad | FMA | 4-8x |
| vec_scale | Vector mul | 4x |
| vec_add | Vector add | 4x |
| vec_mul | Vector mul | 4x |

## Performance Tuning Constants

```c
#define GGML_F32_STEP 16/32/64  // Elements per loop iteration
#define GGML_F32_EPR  4/8/16    // Elements per register
#define GGML_F32_ARR  4         // Registers per step
#define GGML_VEC_DOT_UNROLL  2  // Parallel dot products
#define GGML_VEC_MAD_UNROLL  32 // Wide FMA unrolling
```

**Tuning guidelines:**
- Larger STEP improves cache utilization
- EPR matches SIMD width
- ARR balances register pressure vs. parallelism
- UNROLL increases instruction-level parallelism
