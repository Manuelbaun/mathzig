# Performance Techniques

This document summarizes key performance optimization patterns from GGML that can be applied to your own high-performance math code.

## 1. Fused Multiply-Add (FMA)

FMA combines multiplication and addition into a single instruction.

**Without FMA:**
```c
// 2 operations, 2 rounding points
result = a * b;
result += c;
```

**With FMA:**
```c
// 1 operation, 1 rounding point
result = fma(a, b, c);  // a * b + c
```

**Benefits:**
- 2x throughput on modern CPUs
- Better precision (single rounding)
- Lower latency

**GGML Usage:**
```c
// Dot product using FMA
GGML_F32_VEC_FMA(acc, xi, yi);
// acc = acc + xi * yi
```

## 2. Loop Unrolling

Unrolling loops reduces branch overhead and enables instruction-level parallelism.

**Scalar loop:**
```c
float sum = 0;
for (int i = 0; i < n; i++) {
    sum += x[i] * y[i];
}
```

**Unrolled 4x:**
```c
float sum = 0;
int i = 0;
for (; i + 3 < n; i += 4) {
    sum += x[i] * y[i];
    sum += x[i+1] * y[i+1];
    sum += x[i+2] * y[i+2];
    sum += x[i+3] * y[i+3];
}
// Scalar tail
for (; i < n; i++) {
    sum += x[i] * y[i];
}
```

**GGML Constants:**
```c
#define GGML_F32_STEP 32    // Elements per loop
#define GGML_F32_EPR  4     // Elements per register
#define GGML_VEC_DOT_UNROLL  2
#define GGML_VEC_MAD_UNROLL  32
```

**Benefits:**
- Fewer loop branches
- More independent instructions
- Better CPU pipeline utilization

## 3. Multiple Accumulators

Using multiple accumulators hides FMA latency.

**Single accumulator:**
```c
__m256 sum = _mm256_setzero_ps();
for (int i = 0; i < n; i += 8) {
    __m256 a = _mm256_loadu_ps(&x[i]);
    __m256 b = _mm256_loadu_ps(&y[i]);
    sum = _mm256_fmadd_ps(a, b, sum);  // Waits for previous FMA
}
```

**Multiple accumulators:**
```c
__m256 sum0 = _mm256_setzero_ps();
__m256 sum1 = _mm256_setzero_ps();

for (int i = 0; i < n; i += 16) {
    __m256 a0 = _mm256_loadu_ps(&x[i]);
    __m256 a1 = _mm256_loadu_ps(&x[i + 8]);
    __m256 b0 = _mm256_loadu_ps(&y[i]);
    __m256 b1 = _mm256_loadu_ps(&y[i + 8]);

    sum0 = _mm256_fmadd_ps(a0, b0, sum0);
    sum1 = _mm256_fmadd_ps(a1, b1, sum1);
    // sum0 and sum1 can execute in parallel
}

__m256 sum = _mm256_add_ps(sum0, sum1);
```

**GGML Pattern:**
```c
GGML_F32_VEC sum_vec[GGML_F32_ARR] = { 0 };

for (int i = 0; i < np; i += GGML_F32_STEP) {
    for (int j = 0; j < GGML_F32_ARR; j++) {
        GGML_F32_VEC xi = GGML_F32_VEC_LOAD(x + i + j*GGML_F32_EPR);
        GGML_F32_VEC yi = GGML_F32_VEC_LOAD(y + i + j*GGML_F32_EPR);
        sum_vec[j] = GGML_F32_VEC_FMA(sum_vec[j], xi, yi);
    }
}
```

## 4. Lookup Tables for Expensive Functions

For functions with limited input ranges, lookup tables eliminate computation.

**GELU lookup table:**
```c
// 128 KB table for all FP16 values
extern ggml_fp16_t ggml_table_gelu_f16[1 << 16];

inline static float ggml_gelu_fast(float x) {
    ggml_fp16_t fp16 = GGML_CPU_FP32_TO_FP16(x);
    uint16_t t;
    memcpy(&t, &fp16, sizeof(uint16_t));
    return GGML_CPU_FP16_TO_FP32(ggml_table_gelu_f16[t]);
}
```

**When to use:**
- Function has limited input domain (FP16 = 65K values)
- Function is expensive (exp, tanh, gelu)
- Memory access is cheap (table fits in L1 cache)

## 5. Blocking for Cache Efficiency

Blocking keeps data in cache during computation.

**Naive matmul:**
```c
for (int i = 0; i < M; i++) {
    for (int j = 0; j < N; j++) {
        for (int k = 0; k < K; k++) {
            C[i][j] += A[i][k] * B[k][j];  // B[k][j] not cached!
        }
    }
}
```

**Blocked matmul:**
```c
#define BLOCK_SIZE 32

for (int ii = 0; ii < M; ii += BLOCK_SIZE) {
    for (int jj = 0; jj < N; jj += BLOCK_SIZE) {
        for (int kk = 0; kk < K; kk += BLOCK_SIZE) {
            // Process small blocks that fit in cache
            for (int i = ii; i < min(ii+BLOCK_SIZE, M); i++) {
                for (int j = jj; j < min(jj+BLOCK_SIZE, N); j++) {
                    for (int k = kk; k < min(kk+BLOCK_SIZE, K); k++) {
                        C[i][j] += A[i][k] * B[k][j];
                    }
                }
            }
        }
    }
}
```

## 6. Quantization

Quantization reduces memory bandwidth and working set size.

**Q4_0 memory layout:**
```
Block size: 32 values
Storage: 18 bytes
Original: 128 bytes (FP32)
Compression: 7.1x
```

**Dequantize-on-the-fly:**
```c
// Process without full dequantization
for (int i = 0; i < nb; i++) {
    const block_q4_0 * block = &quantized[i];
    const float d = GGML_FP16_TO_FP32(block->d);

    for (int j = 0; j < 16; j++) {
        uint8_t q = block->qs[j];
        int8_t v0 = (int8_t)(q & 0xF) - 8;
        int8_t v1 = (int8_t)(q >> 4) - 8;

        // Use directly in computation
        acc += d * v0 * x[2*j];
        acc += d * v1 * x[2*j+1];
    }
}
```

## 7. Platform-Specific SIMD

Use architecture-specific instructions for maximum performance.

**Macro-based selection:**
```c
#if defined(__AVX2__)
    // AVX2 implementation
    for (int i = 0; i < n; i += 8) {
        __m256 x_vec = _mm256_loadu_ps(&x[i]);
        __m256 y_vec = _mm256_loadu_ps(&y[i]);
        __m256 prod = _mm256_mul_ps(x_vec, y_vec);
        // ...
    }
#elif defined(__ARM_NEON__)
    // NEON implementation
    for (int i = 0; i < n; i += 4) {
        float32x4_t x_vec = vld1q_f32(&x[i]);
        float32x4_t y_vec = vld1q_f32(&y[i]);
        float32x4_t prod = vmulq_f32(x_vec, y_vec);
        // ...
    }
#else
    // Scalar fallback
    for (int i = 0; i < n; i++) {
        sum += x[i] * y[i];
    }
#endif
```

## 8. Memory Alignment

Aligned memory access is faster on most architectures.

**Aligned allocation:**
```c
// C11 aligned_alloc
void * ptr = aligned_alloc(64, size);

// Or posix_memalign
void * ptr;
posix_memalign(&ptr, 64, size);

// Check alignment
assert(((uintptr_t)ptr % 64) == 0);
```

**Aligned loads:**
```c
// Aligned load (faster)
__m256 x_vec = _mm256_load_ps(ptr);  // Requires 32-byte alignment

// Unaligned load (slower, but safe)
__m256 x_vec = _mm256_loadu_ps(ptr);  // Works with any alignment
```

## 9. Numerical Stability

Prevent overflow/underflow in sensitive operations.

**Softmax with max subtraction:**
```c
// Find max
float max_val = x[0];
for (int i = 1; i < n; i++) {
    if (x[i] > max_val) max_val = x[i];
}

// Compute exp(x - max)
ggml_float sum = 0;
for (int i = 0; i < n; i++) {
    float exp_val = expf(x[i] - max_val);
    y[i] = exp_val;
    sum += exp_val;
}

// Normalize
for (int i = 0; i < n; i++) {
    y[i] = y[i] / (float)sum;
}
```

**GELU clamping:**
```c
inline static void ggml_vec_gelu_f32(const int n, float * y,
                                     const float * x) {
    for (int i = 0; i < n; ++i) {
        if (x[i] <= -10.0f) {
            y[i] = 0.0f;
        } else if (x[i] >= 10.0f) {
            y[i] = x[i];
        } else {
            // Use lookup table for normal range
            y[i] = ggml_gelu_f32(x[i]);
        }
    }
}
```

## 10. Scratch Memory

Reuse memory for temporary allocations.

**Pool-based scratch:**
```c
// Set up scratch memory
char scratch[16 * 1024 * 1024];
size_t scratch_offset = 0;

#define SCRATCH_ALLOC(size)                                          \
    ({                                                               \
        size_t aligned = (size + 15) & ~15;                          \
        void * ptr = &scratch[scratch_offset];                      \
        scratch_offset += aligned;                                   \
        ptr;                                                         \
    })

// Use
float * temp = SCRATCH_ALLOC(n * sizeof(float));

// Reset
scratch_offset = 0;
```

## Performance Checklist

1. **Use FMA**: Always prefer FMA over mul+add
2. **Unroll loops**: Process 4-32 elements per iteration
3. **Multiple accumulators**: Hide FMA latency
4. **Block for cache**: Keep working set in L1/L2
5. **Quantize weights**: Reduce memory bandwidth
6. **Use SIMD**: Match architecture (AVX2, NEON, SVE)
7. **Align memory**: 16-64 byte alignment
8. **Lookup tables**: For FP16 functions
9. **Prevent overflow**: Max subtraction, clamping
10. **Reuse memory**: Scratch pools, context allocation

## Roofline Analysis

Understand compute vs. memory bounds:

```
Performance (GFLOPS)
     ^
     |           Compute Bound
     |          /
     |         /
     |        /
     |       /
     |      /
     |     /
     |    /
     |   /  Memory Bound
     |  /
     | /
     |/
     +--------------------> Operational Intensity (FLOPs/byte)
```

**GGML operations by bound:**
- **Compute bound**: vec_dot, matmul, activation FMA
- **Memory bound**: Quantized matmul dequantization
- **Balance**: Flash attention, large matmul

## Benchmarking Tips

```c
// Use high-resolution timer
#include <chrono>

auto start = std::chrono::high_resolution_clock::now();

// Run operation multiple times
const int iterations = 100;
for (int i = 0; i < iterations; i++) {
    ggml_vec_dot_f32(n, &result, 0, x, 0, y, 0, 1);
}

auto end = std::chrono::high_resolution_clock::now();
double elapsed = std::chrono::duration<double>(end - start).count();

double gflops = (2.0 * n * iterations) / (elapsed * 1e9);
printf("%.2f GFLOPS\n", gflops);
```

**Key metrics:**
- GFLOPS: Compute throughput
- Memory bandwidth (GB/s): Memory-bound operations
- Latency: Time per operation
