# Matrix Operations

Matrix multiplication is the most computationally intensive operation in neural networks. GGML implements highly optimized matrix operations.

## Matrix Multiplication (MatMul)

### Basic MatMul Concept

```
C = A * B

C[i,j] = sum_k(A[i,k] * B[k,j])
```

**Computational complexity:** O(n^3) for n x n matrices

### GGML MatMul Structure

```c
void ggml_mul_mat(
    struct ggml_context * ctx,
    struct ggml_tensor * dst,
    const struct ggml_tensor * src0,  // A (m x k)
    const struct ggml_tensor * src1   // B (k x n)
);
```

**Output:** dst (m x n)

## Blocking/Tiling Strategy

GGML uses blocking to improve cache utilization:

```c
// Typical blocking sizes
#define GGML_MAT_MUL_BLOCK_SIZE 32  // Process 32x32 blocks
#define GGML_MAT_MUL_BLOCK_K     64  // K dimension blocking
```

### 2D Blocking

```
                    B Block (K x N)
                +------------------+
                |                  |
                |                  |
   A Block      |                  |  C Block
   (M x K)      |                  |  (M x N)
                |                  |
                +------------------+

Processing: C[m,n] += sum_k(A[m,k] * B[k,n])
```

### Cache-Aware Blocking

```c
// Pseudocode for blocked matmul
for (int64_t i0 = 0; i0 < m; i0 += BM) {           // Block over rows
    for (int64_t j0 = 0; j0 < n; j0 += BN) {       // Block over cols
        for (int64_t k0 = 0; k0 < k; k0 += BK) {   // Block over K
            // Process block of size BM x BK from A
            // Process block of size BK x BN from B
            // Update C block BM x BN
        }
    }
}
```

**Benefits:**
- Keeps working set in L1/L2 cache
- Reduces memory bandwidth
- Enables vectorization

## Quantized MatMul

For quantized weights, GGML dequantizes on-the-fly:

### Q4_0 MatMul

```c
void ggml_mul_mat_q4_0_f32(int n, float * C,
                           const void * A, int64_t lda,
                           const void * B, int64_t ldb) {
    const int64_t block_size = QK4_0;  // 32
    const int64_t nb = n / block_size;

    for (int64_t i = 0; i < nb; ++i) {
        const block_q4_0 * a = (const block_q4_0 *)A + i;
        const float d = GGML_FP16_TO_FP32(a->d);

        for (int64_t j = 0; j < block_size; j += 2) {
            uint8_t q0 = a->qs[j/2] & 0xF;
            uint8_t q1 = a->qs[j/2] >> 4;

            int8_t v0 = (int8_t)q0 - 8;
            int8_t v1 = (int8_t)q1 - 8;

            C[i * block_size + j]     += d * v0 * B[i * block_size + j];
            C[i * block_size + j + 1] += d * v1 * B[i * block_size + j + 1];
        }
    }
}
```

**Dequantize-on-the-fly pattern:**
1. Load quantized block
2. Extract scale (d)
3. Dequantize individual values
4. Multiply by activation
5. Accumulate

### Dequantization Optimization

```c
// Unrolled dequantization for Q4_K
for (int i = 0; i < QK_K; i += 32) {
    const block_q4_K * b = blocks[i / QK_K];
    const float d = GGML_FP16_TO_FP32(b->d);
    const float dmin = GGML_FP16_TO_FP32(b->dmin);

    // Extract 4-bit values
    uint8_t * qs = b->qs + (i % QK_K) / 2;

    for (int j = 0; j < 32; j += 2) {
        uint8_t q = qs[j/2];
        int8_t q0 = q & 0xF;
        int8_t q1 = q >> 4;

        // Apply scale and minimum
        float v0 = d * (q0 - 8);
        float v1 = d * (q1 - 8);
        // ... use v0, v1
    }
}
```

## Flash Attention

Flash attention computes attention without materializing the full attention matrix:

```
Attention(Q, K, V) = softmax(Q * K^T / sqrt(d)) * V
```

### Standard vs Flash Attention

**Standard:**
```c
// Materialize Q * K^T (n^2 memory)
float * scores = malloc(n * n * sizeof(float));
for (int i = 0; i < n; i++) {
    for (int j = 0; j < n; j++) {
        scores[i,j] = dot(Q[i], K[j]) / sqrt(d);
    }
}
softmax(scores);
for (int i = 0; i < n; i++) {
    O[i] = sum_j(scores[i,j] * V[j]);
}
```

**Flash Attention:**
```c
// Block-wise computation (O(sqrt(n)) memory)
float * l = zeros(n);      // row sums
float * m = fill(-inf, n); // row maxes

for (int i = 0; i < n; i += Bm) {          // Block over rows
    for (int j = 0; j < n; j += Bk) {      // Block over K
        // Load Q[i:i+Bm, k:k+Bk] and K[j:j+Bk, k:k+Bk]
        // Compute partial scores
        // Update row max and sum
    }
    // Normalize and output
}
```

### GGML Flash Attention

```c
void ggml_flash_attn_ext(
    struct ggml_context * ctx,
    struct ggml_tensor * dst,
    const struct ggml_tensor * q,     // Query (B, nh, N, d)
    const struct ggml_tensor * k,     // Key   (B, nh, N, d)
    const struct ggml_tensor * v,     // Value (B, nh, N, d)
    float scale,
    float max_bias,
    float m0,
    float m1,
    const struct ggml_tensor * mask   // Optional mask
);
```

**Key optimizations:**
1. **Causal masking**: Prevents attending to future tokens
2. **Alibi bias**: Linear bias for extrapolation
3. **Window attention**: Limit attention window size
4. **Partial blocks**: Handle non-divisible dimensions

## Vector Dot Product for MatMul

MatMul is implemented using the optimized vec_dot:

```c
// For each row of A:
for (int i = 0; i < m; i++) {
    ggml_vec_dot_f32(k, &C[i * n], 0,
                     A + i * k, 0,
                     B, n);  // B has stride n
}
```

**Loop over K dimension:**
```c
// Accumulate over K blocks
for (int kk = 0; kk < k; kk += k_block) {
    // Process block of K
    ggml_vec_dot_f32(k_block,
                     &C[i * n + j], 0,
                     A + i * k + kk, 0,
                     B + kk * n + j, n);
}
```

## MatMul for Different Data Types

### FP32 MatMul

```c
void ggml_mul_mat_f32(int n, float * C,
                      const float * A, int64_t lda,
                      const float * B, int64_t ldb) {
    const int64_t np = (n & ~(GGML_F32_STEP - 1));

    for (int64_t i = 0; i < n; i += GGML_F32_STEP) {
        GGML_F32_VEC C_vec[GGML_F32_ARR] = { 0 };

        for (int64_t k = 0; k < n; k += GGML_F32_STEP) {
            for (int64_t j = 0; j < GGML_F32_ARR; j++) {
                GGML_F32_VEC A_vec = GGML_F32_VEC_LOAD(A + i + k + j*GGML_F32_EPR);
                GGML_F32_VEC B_vec = GGML_F32_VEC_LOAD(B + k + j*GGML_F32_EPR);
                C_vec[j] = GGML_F32_VEC_FMA(C_vec[j], A_vec, B_vec);
            }
        }

        GGML_F32_VEC_REDUCE(C + i, C_vec);
    }
}
```

### FP16 MatMul

```c
void ggml_mul_mat_f16(int n, float * C,
                      const ggml_fp16_t * A, int64_t lda,
                      const ggml_fp16_t * B, int64_t ldb) {
    // Similar structure but converts FP16 to FP32 for accumulation
    // Uses GGML_F16_VEC_* macros
}
```

### BF16 MatMul

```c
void ggml_mul_mat_bf16(int n, float * C,
                       const ggml_bf16_t * A, int64_t lda,
                       const ggml_bf16_t * B, int64_t ldb) {
    // BF16 has wider range but similar precision to FP16
    // Convert to FP32 for accumulation
}
```

## K-Quantized MatMul

K-quantization uses larger blocks (256 elements):

```c
void ggml_mul_mat_q_K(int n, float * C,
                      const void * A, int64_t lda,
                      const void * B, int64_t ldb) {
    const int64_t nb = n / QK_K;  // Number of super-blocks

    for (int64_t ib = 0; ib < nb; ib++) {
        const block_q6_K * a = (const block_q6_K *)A + ib;
        const block_q8_K * b = (const block_q8_K *)B + ib;

        const float d = GGML_FP16_TO_FP32(a->d);
        const float dB = GGML_FP16_TO_FP32(b->d);

        for (int64_t j = 0; j < QK_K; j++) {
            int8_t qa = a->qs[j];
            int8_t qb = b->qs[j];

            C[ib * QK_K + j] += d * dB * qa * qb;
        }
    }
}
```

## Performance Considerations

### Memory Access Patterns

```
A: row-major (M x K)
B: column-major (K x N) -> accessed as row-major with stride
C: row-major (M x N)
```

**Optimal access:**
```c
// A accessed row-wise (good for cache)
// B accessed column-wise (needs blocking)
// C accessed row-wise (good for cache)

for (int k = 0; k < K; k += BK) {
    // Load B column block into cache
    for (int j = 0; j < N; j += BN) {
        // Process all rows of A against this B block
        for (int i = 0; i < M; i += BM) {
            // Update C[i:i+BM, j:j+BN]
        }
    }
}
```

### Parallelization

```c
// GGML parallelizes over output rows
void ggml_mul_mat_parallel(
    const struct ggml_tensor * src0,
    const struct ggml_tensor * src1,
    struct ggml_tensor * dst,
    int n_threads
) {
    // Split rows among threads
    int64_t rows_per_thread = M / n_threads;

    for (int t = 0; t < n_threads; t++) {
        int64_t row_start = t * rows_per_thread;
        int64_t row_end = (t + 1) * rows_per_thread;

        // Each thread processes its row range
        ggml_mul_mat_rows(src0, src1, dst, row_start, row_end);
    }
}
```

### Mixed Precision

| Precision | Weights | Activations | Accumulator | Use Case |
|-----------|---------|-------------|-------------|----------|
| FP32 | FP32 | FP32 | FP32 | Training, high precision |
| FP16 | FP16 | FP16 | FP32 | Fast inference |
| BF16 | BF16 | BF16 | FP32 | Training |
| Q4 | Q4 | FP32 | FP32 | Memory-efficient |
| Q5 | Q5 | FP32 | FP32 | Balanced |

## MatMul Summary

| Operation | Complexity | Bandwidth | Compute Bound |
|-----------|-----------|-----------|---------------|
| FP32 MatMul | O(mnk) | High | Yes |
| Q4 MatMul | O(mnk) | Medium | Yes |
| Flash Attn | O(mnd) | Low | Yes |

**Key takeaways:**
1. Blocking is essential for cache efficiency
2. Quantized matmul saves memory bandwidth
3. Flash attention reduces O(n^2) memory
4. Parallelization over output rows is simple and effective
