# SIMD Architecture Comparison

This document compares GGML's SIMD abstraction layer with MathZig's use of Zig's `@Vector` type.

## GGML's Portable SIMD System

GGML defines a comprehensive set of macros in `simd-mappings.h` that abstract SIMD operations across architectures.

### Architecture Detection

```c
// From simd-mappings.h lines 148-200
#if defined(__ARM_FEATURE_SVE) && defined(__ARM_FEATURE_FMA)
    #define GGML_SIMD
    
    // F32 SVE - Scalable Vector Extension
    #define GGML_F32_EPR 8
    #define DEFAULT_PG svptrue_b32()
    
    #define GGML_F32xt                        svfloat32_t
    #define GGML_F32xt_ZERO                   svdup_n_f32(0.0f)
    #define GGML_F32xt_SET1(x)                svdup_n_f32(x)
    #define GGML_F32xt_LOAD_IMPL(pg, a)       svld1_f32(pg, a)
    #define GGML_F32xt_FMA_IMPL(pg, a, b, c)  svmad_f32_m(pg, b, c, a)
```

### Supported Architectures

| Architecture | Vector Width | FMA Support | Notes |
|--------------|-------------|-------------|-------|
| ARM SVE | Scalable (128-2048 bit) | Yes | Scalable vector extension |
| ARM NEON | 128-bit (4x f32) | Yes | 32-bit ARM standard |
| x86 AVX2 | 256-bit (8x f32) | Yes | 64-bit x86 standard |
| x86 AVX-512 | 512-bit (16x f32) | Yes | High-end desktop/server |
| x86 SSE3 | 128-bit (4x f32) | No | Legacy fallback |
| RISC-V Vector | Scalable | Yes | RISC-V V extension |
| WebAssembly SIMD128 | 128-bit (4x f32) | Yes | WebAssembly |
| POWER9 | 128-bit (4x f32) | Yes | IBM PowerPC |

### Macro-Based Abstraction Pattern

GGML defines unified macros that map to architecture-specific intrinsics:

```c
// Unified API (from simd-mappings.h lines 185-193)
#define GGML_F32_VEC        GGML_F32xt
#define GGML_F32_VEC_ZERO   GGML_F32xt_ZERO
#define GGML_F32_VEC_SET1   GGML_F32xt_SET1
#define GGML_F32_VEC_LOAD   GGML_F32xt_LOAD
#define GGML_F32_VEC_STORE  GGML_F32xt_STORE
#define GGML_F32_VEC_FMA    GGML_F32xt_FMA
#define GGML_F32_VEC_ADD    GGML_F32xt_ADD
#define GGML_F32_VEC_MUL    GGML_F32xt_MUL
#define GGML_F32_VEC_REDUCE GGML_F32xt_REDUCE
```

### FMA (Fused Multiply-Add) Pattern

FMA combines multiplication and addition in a single instruction:

```c
// AVX2 (from simd-mappings.h)
#define GGML_F32x8_FMA(a, b, c) _mm256_fmadd_ps(b, c, a)

// ARM NEON (from simd-mappings.h)
#define GGML_F32x4_FMA(a, b, c) vfmaq_f32(a, b, c)

// ARM SVE (from simd-mappings.h lines 163-164)
#define GGML_F32xt_FMA_IMPL(pg, a, b, c)  svmad_f32_m(pg, b, c, a)
#define GGML_F32xt_FMA(a, b, c)           GGML_F32xt_FMA_IMPL(DEFAULT_PG, a, b, c)
```

### Reduction Operations

GGML provides portable reduction (horizontal sum) operations:

```c
// SVE reduction (from simd-mappings.h lines 169-171)
#define GGML_F32xt_REDUCE_ONE_IMPL(pg, a) svaddv(pg, a)
#define GGML_F32xt_REDUCE_ONE(a)          GGML_F32xt_REDUCE_ONE_IMPL(DEFAULT_PG, a)

// 8-way reduction for parallelism (lines 171-181)
#define GGML_F32xt_REDUCE_IMPL(pg, res, sum1, sum2, sum3, sum4, sum5, sum6, sum7, sum8)  \
{                                                                                       \
    sum1 = svadd_f32_m(DEFAULT_PG, sum1, sum2);                                         \
    sum3 = svadd_f32_m(DEFAULT_PG, sum3, sum4);                                         \
    sum5 = svadd_f32_m(DEFAULT_PG, sum5, sum6);                                         \
    sum7 = svadd_f32_m(DEFAULT_PG, sum7, sum8);                                         \
    sum1 = svadd_f32_m(DEFAULT_PG, sum1, sum3);                                         \
    sum5 = svadd_f32_m(DEFAULT_PG, sum5, sum7);                                         \
    sum1 = svadd_f32_m(DEFAULT_PG, sum1, sum5);                                         \
    (res) = (ggml_float) GGML_F32xt_REDUCE_ONE(sum1);                                   \
}
```

## MathZig's SIMD Approach

MathZig uses Zig's native `@Vector` type with a fixed width:

```zig
// From src/core/value.zig lines 7-11
pub const VectorLen = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => @as(usize, 2),  // SIMD128: 2 f64 per vector
    else => @as(usize, 4),              // AVX/SSE: 4 f64 per vector (32 bytes)
};

pub const Vec = @Vector(4, f64);  // 4-wide f64 vector (32 bytes)
```

### MathZig SIMD Operations

```zig
// From src/functions/matrix_kernels.zig lines 15-34
pub fn matMul4x4(A: [*]const f64, B: [*]const f64, C: [*]f64, 
                stride_a: usize, stride_b: usize, stride_c: usize) void {
    var sum0 = Vec{0, 0, 0, 0};
    var sum1 = Vec{0, 0, 0, 0};
    var sum2 = Vec{0, 0, 0, 0};
    var sum3 = Vec{0, 0, 0, 0};

    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const vb: Vec = B[k * stride_b ..][0..4].*;
        sum0 = @mulAdd(Vec, @splat(A[0 * stride_a + k]), vb, sum0);
        sum1 = @mulAdd(Vec, @splat(A[1 * stride_a + k]), vb, sum1);
        sum2 = @mulAdd(Vec, @splat(A[2 * stride_a + k]), vb, sum2);
        sum3 = @mulAdd(Vec, @splat(A[3 * stride_a + k]), vb, sum3);
    }
    // Store results
    C[0 * stride_c ..][0..4].* = sum0;
    // ...
}
```

### Vector Type Definition

```zig
// From src/core/value.zig lines 135-138
pub const Vector = extern struct {
    ptr: [*]const f64,
    len: usize,
    alignment: usize = 32,
};
```

## Comparison: Key Differences

| Aspect | GGML | MathZig |
|--------|------|---------|
| Abstraction Level | C macros | Zig builtin types |
| Architecture Detection | Compile-time macros | `builtin.cpu.arch` |
| Vector Width | Dynamic per-architecture | Fixed (2 or 4) |
| Scalable Vectors | Yes (SVE, RISC-V) | No |
| Custom Intrinsics | Yes | Limited |
| Portability | Explicit per-arch code | Automatic via Zig |

## Recommendations for MathZig

### 1. Architecture-Specific Vector Widths

MathZig could leverage Zig's compile-time capabilities for architecture-specific vector sizes:

```zig
// Conceptual improvement
const Vec = switch (builtin.cpu.arch) {
    .aarch64 => @Vector(4, f64),  // NEON: 4-wide
    .aarch64_sv, .aarch64_svb32, .aarch64_svb64 => @Vector(8, f64), // SVE: 8-wide
    .x86_64 => @Vector(4, f64),   // AVX2: 4-wide
    .x86_64 => @Vector(8, f64),   // AVX-512: 8-wide
    .wasm32, .wasm64 => @Vector(2, f64), // SIMD128: 2-wide
    else => @Vector(4, f64),      // Default
};
```

### 2. Adding SVE Support

For ARM SVE support, MathZig could use Zig's inline assembly:

```zig
// Conceptual SVE support
const SVEVector = if (builtin.cpu.arch == .aarch64_sv) 
    @Vector(8, f64) else @Vector(4, f64);

pub fn sve_matmul(/* ... */) void {
    if (builtin.cpu.arch == .aarch64_sv) {
        // SVE-specific implementation using svfloat64_t
        asm volatile (
            \\ ld1b z0.b, p0/z, [x0]
            \\ fmul z0.d, z0.d, z1.d
        : 
        : [x0] "r"(ptr)
        : "memory"
        );
    }
}
```

### 3. Portable Vector Type Alias

A portable abstraction layer could unify SIMD operations:

```zig
// Proposed portable SIMD layer
const SimdVec = struct {
    data: Vec,
    
    pub fn load(ptr: [*]const f64) SimdVec {
        return .{ .data = ptr[0..VectorLen].* };
    }
    
    pub fn fma(a: SimdVec, b: SimdVec, c: SimdVec) SimdVec {
        return .{ .data = @mulAdd(Vec, a.data, b.data, c.data) };
    }
    
    pub fn reduce(self: SimdVec) f64 {
        return @reduce(.Add, self.data);
    }
};
```

### 4. FMA Optimization

GGML's FMA usage provides approximately 2x throughput improvement over separate multiply-add. MathZig already uses `@mulAdd` which maps to FMA where available, but could benefit from explicit unrolling:

```zig
// Current: single accumulator
var acc: Vec = @splat(0.0);
while (i < vec_count) : (i += 1) {
    const va = /* load */;
    const vb = /* load */;
    acc = @mulAdd(Vec, va, vb, acc);
}

// Improved: accumulator array (like GGML)
var accs: [4]Vec = .{ @splat(0.0), @splat(0.0), @splat(0.0), @splat(0.0) };
var j: usize = 0;
while (j < vec_count) : (j += 4) {
    // Process 4 vectors at once
    for (0..4) |k| {
        const va = /* load at offset j+k */;
        const vb = /* load at offset j+k */;
        accs[k] = @mulAdd(Vec, va, vb, accs[k]);
    }
}
// Final reduction
const final_acc = accs[0] + accs[1] + accs[2] + accs[3];
```

## Performance Impact

| Optimization | Estimated Improvement |
|--------------|----------------------|
| SVE support (8-wide vs 4-wide) | 1.5-2x on Graviton3/M4 |
| AVX-512 support (8-wide) | 1.5-2x on Ice Lake/Xeon |
| Accumulator array pattern | 10-20% latency reduction |
| Multiple accumulators | 20-30% throughput increase |
