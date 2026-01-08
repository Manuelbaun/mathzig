# SIMD Optimizations

GGML uses Single Instruction Multiple Data (SIMD) to accelerate vector operations across multiple platforms.

## Architecture Detection

GGML detects SIMD capabilities at compile time using compiler macros:

```c
// x86/x64
__AVX512F__      // AVX-512 Foundation
__AVX__          // AVX (256-bit)
__FMA__          // Fused Multiply-Add (often with AVX)
__F16C__         // Half-precision conversions
__SSE3__         // SSE3 (128-bit, baseline for x86)

// ARM
__ARM_FEATURE_SVE        // Scalable Vector Extension
__ARM_FEATURE_FMA        // Fused Multiply-Add
__ARM_NEON__             // NEON SIMD
__ARM_FEATURE_FP16_VECTOR_ARITHMETIC  // FP16 in NEON

// RISC-V
__riscv_v_intrinsic      // RISC-V Vector Extension
__riscv_zfhmin           // Half-precision

// Other
__POWER9_VECTOR__        // IBM POWER9
__wasm_simd128__         // WebAssembly SIMD
__loongarch_asx          // LoongArch ASX (256-bit)
__loongarch_sx           // LoongArch SX (128-bit)
__VXE__                  // IBM s390x Vector Extension
```

## Common SIMD Interface

GGML defines platform-agnostic macros that map to architecture-specific intrinsics:

```c
// Vector types
GGML_F32x4   // 4x float32 vector (128-bit)
GGML_F32x8   // 8x float32 vector (256-bit)
GGML_F32x16  // 16x float32 vector (512-bit)
GGML_F16x8   // 8x float16 vector (128-bit)

// Operations
GGML_F32_VEC_LOAD(p)      // Load vector from memory
GGML_F32_VEC_STORE(p, v)  // Store vector to memory
GGML_F32_VEC_SET1(x)      // Broadcast scalar to vector
GGML_F32_VEC_FMA(a, b, c) // Fused: a += b * c
GGML_F32_VEC_ADD(a, b)    // Element-wise addition
GGML_F32_VEC_MUL(a, b)    // Element-wise multiplication
GGML_F32_VEC_REDUCE(r, x) // Sum all elements into scalar
```

## Key Constants

```c
// Elements per register (EPR)
GGML_F32_EPR  4   // SSE/NEON: 4 floats = 128 bits
GGML_F32_EPR  8   // AVX/SVE:  8 floats = 256 bits
GGML_F32_EPR 16   // AVX512:  16 floats = 512 bits

// Step size: elements processed per loop iteration
GGML_F32_STEP 16  // SSE:  4 floats * 4 registers
GGML_F32_STEP 32  // AVX:  8 floats * 4 registers
GGML_F32_STEP 64  // AVX512: 16 floats * 4 registers

// Arrays: registers used per step
GGML_F32_ARR = GGML_F32_STEP / GGML_F32_EPR
```

## ARM NEON (128-bit)

### With FP16 Support

```c
#define GGML_F32_STEP 16
#define GGML_F32_EPR  4

#define GGML_F32x4              float32x4_t
#define GGML_F32x4_ZERO         vdupq_n_f32(0.0f)
#define GGML_F32x4_SET1(x)      vdupq_n_f32(x)
#define GGML_F32x4_LOAD         vld1q_f32
#define GGML_F32x4_STORE        vst1q_f32
#define GGML_F32x4_FMA(a,b,c)   vfmaq_f32(a, b, c)
#define GGML_F32x4_ADD          vaddq_f32
#define GGML_F32x4_MUL          vmulq_f32
```

**FMA Pattern:**
```c
// Scalar: sum += a[i] * b[i]
// NEON FMA: acc = vfmaq_f32(acc, va, vb)
float32x4_t acc = vdupq_n_f32(0.0f);
for (int i = 0; i < n; i += 4) {
    float32x4_t va = vld1q_f32(&a[i]);
    float32x4_t vb = vld1q_f32(&b[i]);
    acc = vfmaq_f32(acc, va, vb);  // acc += va * vb
}
float32x4_t sum = vpaddq_f32(acc, acc);
sum = vpaddq_f32(sum, sum);
result = vgetq_lane_f32(sum, 0);
```

### FP16 NEON with Hardware Support

```c
#if defined(__ARM_FEATURE_FP16_VECTOR_ARITHMETIC)
#define GGML_F16_STEP 32
#define GGML_F16_EPR  8

#define GGML_F16x8              float16x8_t
#define GGML_F16x8_ZERO         vdupq_n_f16(0.0f)
#define GGML_F16x8_SET1(x)      vdupq_n_f16(x)
#define GGML_F16x8_LOAD         vld1q_f16
#define GGML_F16x8_STORE        vst1q_f16
#define GGML_F16x8_FMA          vfmaq_f16
#define GGML_F16x8_ADD          vaddq_f16
#define GGML_F16x8_MUL          vmulq_f16
```

### Fallback without FP16 Hardware

When FP16 vector arithmetic is unavailable, GGML converts FP16 to FP32:

```c
#define GGML_F16_STEP 16
#define GGML_F16_EPR  4

#define GGML_F32Cx4              float32x4_t
#define GGML_F32Cx4_LOAD(x)      vcvt_f32_f16(vld1_f16((const __fp16 *)(x)))
```

## ARM SVE (Scalable Vector Extension)

SVE is variable-width (128-bit to 2048-bit). GGML adapts to the available width:

```c
#if defined(__ARM_FEATURE_SVE) && defined(__ARM_FEATURE_FMA)

#define GGML_F32_EPR 8  // At least 8 floats per register

#define GGML_F32xt                        svfloat32_t
#define GGML_F32xt_ZERO                   svdup_n_f32(0.0f)
#define GGML_F32xt_SET1(x)                svdup_n_f32(x)
#define GGML_F32xt_LOAD(pg, a)            svld1_f32(pg, a)
#define GGML_F32xt_STORE(pg, a, b)        svst1_f32(pg, a, b)
#define GGML_F32xt_FMA(pg, a, b, c)       svmad_f32_m(pg, b, c, a)
#define GGML_F32xt_ADD(pg, a, b)          svadd_f32_m(pg, a, b)
#define GGML_F32xt_MUL(pg, a, b)          svmul_f32_m(pg, a, b)
```

**SVE Key Features:**
- Predicated execution with `svbool_t` (pg = predicate group)
- `svaddv` for vector reduction to scalar
- Scalable to any vector length

## x86 AVX (256-bit)

```c
#if defined(__AVX__)

#define GGML_F32_STEP 32
#define GGML_F32_EPR  8

#define GGML_F32x8         __m256
#define GGML_F32x8_ZERO    _mm256_setzero_ps()
#define GGML_F32x8_SET1(x) _mm256_set1_ps(x)
#define GGML_F32x8_LOAD    _mm256_loadu_ps
#define GGML_F32x8_STORE   _mm256_storeu_ps

#if defined(__FMA__)
#define GGML_F32x8_FMA(a, b, c) _mm256_fmadd_ps(b, c, a)
#else
#define GGML_F32x8_FMA(a, b, c) _mm256_add_ps(_mm256_mul_ps(b, c), a)
#endif

#define GGML_F32x8_ADD     _mm256_add_ps
#define GGML_F32x8_MUL     _mm256_mul_ps
```

**AVX Dot Product:**
```c
__m256 sum0 = _mm256_setzero_ps();
__m256 sum1 = _mm256_setzero_ps();

for (int i = 0; i < n; i += 16) {
    __m256 a0 = _mm256_loadu_ps(&a[i]);
    __m256 a1 = _mm256_loadu_ps(&a[i + 8]);
    __m256 b0 = _mm256_loadu_ps(&b[i]);
    __m256 b1 = _mm256_loadu_ps(&b[i + 8]);

    sum0 = _mm256_fmadd_ps(a0, b0, sum0);
    sum1 = _mm256_fmadd_ps(a1, b1, sum1);
}

__m256 sum = _mm256_add_ps(sum0, sum1);
```

## x86 AVX-512 (512-bit)

```c
#if defined(__AVX512F__)

#define GGML_F32_STEP 64
#define GGML_F32_EPR  16

#define GGML_F32x16         __m512
#define GGML_F32x16_ZERO    _mm512_setzero_ps()
#define GGML_F32x16_SET1(x) _mm512_set1_ps(x)
#define GGML_F32x16_LOAD    _mm512_loadu_ps
#define GGML_F32x16_STORE   _mm512_storeu_ps
#define GGML_F32x16_FMA(a, b, c) _mm512_fmadd_ps(b, c, a)
#define GGML_F32x16_ADD     _mm512_add_ps
#define GGML_F32x16_MUL     _mm512_mul_ps
#define GGML_F32x16_REDUCE  _mm512_reduce_add_ps
```

**AVX-512 Reduction:**
```c
// Fast reduction with dedicated instruction
float result = _mm512_reduce_add_ps(sum);
```

## x86 SSE3 (128-bit)

```c
#if defined(__SSE3__)

#define GGML_F32_STEP 32
#define GGML_F32_EPR  4

#define GGML_F32x4         __m128
#define GGML_F32x4_ZERO    _mm_setzero_ps()
#define GGML_F32x4_SET1(x) _mm_set1_ps(x)
#define GGML_F32x4_LOAD    _mm_loadu_ps
#define GGML_F32x4_STORE   _mm_storeu_ps

#if defined(__FMA__)
#define GGML_F32x4_FMA(a, b, c) _mm_fmadd_ps(b, c, a)
#else
#define GGML_F32x4_FMA(a, b, c) _mm_add_ps(_mm_mul_ps(b, c), a)
#endif

#define GGML_F32x4_ADD     _mm_add_ps
#define GGML_F32x4_MUL     _mm_mul_ps
```

## RISC-V Vector Extension

```c
#if defined(__riscv_v_intrinsic)

#define GGML_F32_STEP 16
#define GGML_F32_EPR  4

#define GGML_F32x4              vfloat32m1_t
#define GGML_F32x4_ZERO         __riscv_vfmv_v_f_f32m1(0.0f, 4)
#define GGML_F32x4_SET1(x)      __riscv_vfmv_v_f_f32m1(x, 4)
#define GGML_F32x4_LOAD(x)      __riscv_vle32_v_f32m1(x, 4)
#define GGML_F32x4_STORE(b, v)  __riscv_vse32_v_f32m1(b, v, 4)
#define GGML_F32x4_FMA(a, b, c) __riscv_vfmacc_vv_f32m1(a, b, c, 4)
#define GGML_F32x4_ADD(a, b)    __riscv_vfadd_vv_f32m1(a, b, 4)
#define GGML_F32x4_MUL(a, b)    __riscv_vfmul_vv_f32m1(a, b, 4)
```

**Key RISC-V Vector Features:**
- Variable vector length (vlen) from 128 to 65536 bits
- `vl` register controls active vector elements
- Masked operations supported

## WebAssembly SIMD128

```c
#if defined(__wasm_simd128__)

#define GGML_F32_STEP 16
#define GGML_F32_EPR  4

#define GGML_F32x4              v128_t
#define GGML_F32x4_ZERO         wasm_f32x4_splat(0.0f)
#define GGML_F32x4_SET1(x)      wasm_f32x4_splat(x)
#define GGML_F32x4_LOAD         wasm_v128_load
#define GGML_F32x4_STORE        wasm_v128_store
#define GGML_F32x4_FMA(a, b, c) wasm_f32x4_add(wasm_f32x4_mul(b, c), a)
#define GGML_F32x4_ADD          wasm_f32x4_add
#define GGML_F32x4_MUL          wasm_f32x4_mul
```

**Note:** WebAssembly doesn't have native FMA, so it uses multiply-add sequence.

## LoongArch (LSX/ASX)

```c
#if defined(__loongarch_sx)  // 128-bit
#define GGML_F32x4         __m128
#define GGML_F32x4_FMA(a, b, c) __lsx_vfmadd_s(b, c, a)

#elif defined(__loongarch_asx)  // 256-bit
#define GGML_F32x8         __m256
#define GGML_F32x8_FMA(a, b, c) __lasx_xvfmadd_s(b, c, a)
```

## IBM POWER9

```c
#if defined(__POWER9_VECTOR__)

#define GGML_F32_STEP 32
#define GGML_F32_EPR  4

#define GGML_F32x4              vector float
#define GGML_F32x4_ZERO         {0.0f}
#define GGML_F32x4_SET1         vec_splats
#define GGML_F32x4_LOAD(p)      vec_xl(0, p)
#define GGML_F32x4_STORE(p, r)  vec_xst(r, 0, p)
#define GGML_F32x4_FMA(a, b, c) vec_madd(b, c, a)
```

## FMA (Fused Multiply-Add)

FMA combines multiplication and addition in one instruction:

```c
// Without FMA: 2 operations
result = a * b;
result += c;

// With FMA: 1 operation
result = fma(a, b, c);  // a * b + c
```

**Benefits:**
- 1 cycle latency vs 2 operations
- Better precision (one rounding vs two)
- Higher throughput

**GGML FMA Pattern:**
```c
// Dot product using FMA
GGML_F32_VEC_FMA(acc, va, vb);
// Equivalent to: acc = acc + va * vb
```

## Reduction Patterns

Vector reduction sums all elements into a scalar:

```c
// SSE3 reduction
#define GGML_F32x4_REDUCE(res, x)                           \
{                                                            \
    int offset = GGML_F32_ARR >> 1;                          \
    for (int i = 0; i < offset; ++i) {                       \
        x[i] = _mm_add_ps(x[i], x[offset+i]);               \
    }                                                        \
    offset >>= 1;                                            \
    for (int i = 0; i < offset; ++i) {                       \
        x[i] = _mm_add_ps(x[i], x[offset+i]);               \
    }                                                        \
    const __m128 t0 = _mm_hadd_ps(x[0], x[0]);              \
    res = (ggml_float) _mm_cvtss_f32(_mm_hadd_ps(t0, t0));  \
}
```

**Reduction Algorithm:**
1. Pairwise addition (tree reduction)
2. Horizontal add to scalar
3. Extract scalar value

## FP16 Conversion

### Lookup Table (x86 without F16C)

```c
// 256 KB table for all 16-bit values
extern float ggml_table_f32_f16[1 << 16];

inline static float ggml_lookup_fp16_to_fp32(ggml_fp16_t f) {
    uint16_t s;
    memcpy(&s, &f, sizeof(uint16_t));
    return ggml_table_f32_f16[s];
}
```

### Hardware Conversion (ARM NEON)

```c
static inline float neon_compute_fp16_to_fp32(ggml_fp16_t h) {
    __fp16 tmp;
    memcpy(&tmp, &h, sizeof(ggml_fp16_t));
    return (float)tmp;
}
```

### Intrinsic Conversion (x86 F16C)

```c
#if defined(__F16C__)
#define GGML_CPU_COMPUTE_FP16_TO_FP32(x) _cvtsh_ss(x)
#define GGML_CPU_COMPUTE_FP32_TO_FP16(x) _cvtss_sh(x, 0)
#endif
```

## Platform Comparison

| Platform | Vector Width | F32 EPR | FMA | Notes |
|----------|-------------|---------|-----|-------|
| SSE3 | 128-bit | 4 | Optional | Baseline x86 |
| AVX | 256-bit | 8 | Optional | Common x86 |
| AVX-512 | 512-bit | 16 | Native | High-end x86 |
| NEON | 128-bit | 4 | With FP16 arith | ARM baseline |
| SVE | Variable | 8+ | Native | ARM future |
| RISC-V V | Variable | 4+ | Native | Open source |
| WASM | 128-bit | 4 | Emulated | Browser |
| POWER9 | 128-bit | 4 | Native | IBM |

## Writing Portable SIMD Code

```c
// 1. Define portable interface
void ggml_vec_dot_f32(int n, float * restrict s,
                      const float * restrict x,
                      const float * restrict y) {
    float sum = 0.0f;

#if defined(GGML_SIMD)
    const int SSE_EPR = GGML_F32_EPR;
    const int SSE_STEP = GGML_F32_STEP;

    GGML_F32_VEC sum_vec[GGML_F32_ARR] = {0};

    for (int i = 0; i < n; i += SSE_STEP) {
        for (int j = 0; j < SSE_STEP; j += SSE_EPR) {
            GGML_F32_VEC xi = GGML_F32_VEC_LOAD(x + i + j);
            GGML_F32_VEC yi = GGML_F32_VEC_LOAD(y + i + j);
            sum_vec[j/SSE_EPR] = GGML_F32_VEC_FMA(sum_vec[j/SSE_EPR], xi, yi);
        }
    }

    GGML_F32_VEC_REDUCE(sum, sum_vec);
#else
    // Scalar fallback
    for (int i = 0; i < n; i++) {
        sum += x[i] * y[i];
    }
#endif
    *s = sum;
}
```

## Performance Tips

1. **Use FMA**: Always prefer FMA over separate mul+add
2. **Align Memory**: Use aligned loads when possible (`_mm_load_ps` vs `_mm_loadu_ps`)
3. **Loop Unrolling**: Process multiple registers per iteration
4. **Minimize Conversions**: Keep data in native format
5. **Use Right SIMD Width**: Match to workload size
6. **Avoid Horizontal Operations**: They break SIMD efficiency
