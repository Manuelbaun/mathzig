# Quantization Techniques from GGML

This document describes GGML's quantization techniques that could be adapted for MathZig to reduce memory usage while maintaining acceptable accuracy.

## Quantization Overview

GGML supports multiple quantization formats for different memory/accuracy tradeoffs:

| Format | Bits/Element | Memory vs FP32 | Quality | Use Case |
|--------|-------------|----------------|---------|----------|
| Q4_0 | 4 | 7.7x smaller | Good | LLaMA, general |
| Q4_1 | 4 | 7.7x smaller | Better | General |
| Q5_0 | 5 | 6.2x smaller | Very Good | High quality |
| Q5_1 | 5 | 6.2x smaller | Excellent | Best quality |
| Q8_0 | 8 | 3.9x smaller | Excellent | Intermediate |
| Q8_1 | 8 | 3.9x smaller | Excellent | Fused ops |
| Q2_K | 2.5 | 12.8x smaller | Acceptable | Memory constrained |
| Q3_K | 3.5 | 9.1x smaller | Good | Memory constrained |
| Q4_K | 4.5 | 7.1x smaller | Very Good | General |
| Q5_K | 5.5 | 5.8x smaller | Excellent | High quality |
| Q6_K | 6.5 | 4.9x smaller | Near FP32 | Research |

## Block Quantization Theory

GGML uses block quantization where each block contains multiple elements sharing quantization parameters:

```c
// From ggml-common.h
#define QK_K 256      // Super-block size (256 elements)
#define QK 32         // Block size (32 elements)

// Each block stores:
// - 32 quantized values (4-8 bits each)
// - 1-2 scale/minimum values for dequantization
```

### Q4_0 Format (4-bit, no scaling)

```
Block of 32 elements stored as:

+------------------------+------------------------+
|        qs[16]          |         m (16-bit)     |
|  16 bytes = 128 bits   |      2 bytes           |
|  32 x 4-bit values     |     minimum            |
+------------------------+------------------------+
Total: 18 bytes per 32 elements
       = 4.5 bits/element average
       = 7.1x compression vs FP32 (32 bytes)
```

### Q4_0 Dequantization

```c
// From ggml-quants.c
void dequantize_row_q4_0(const block_q4_0 * restrict x, float * restrict y, int k) {
    const int nb = k / QK;
    
    for (int i = 0; i < nb; i++) {
        const float d = GGML_QK4_0_SCALE;  // Fixed scale
        const float dm = -8.0f;             // Fixed minimum
        
        // Extract 4-bit values and dequantize
        for (int j = 0; j < 16; j++) {
            const uint8_t q = x[i].qs[j];
            const float v0 = (q & 0x0F) * d + dm;
            const float v1 = (q >> 4) * d + dm;
            
            y[i*32 + j*2 + 0] = v0;
            y[i*32 + j*2 + 1] = v1;
        }
    }
}
```

### Q8_0 Format (8-bit, with scale)

```
Block of 32 elements stored as:

+------------------------+------------------------+
|        qs[32]          |        d (32-bit)      |
|  32 bytes = 256 bits   |      4 bytes           |
|  32 x 8-bit values     |     scale factor       |
+------------------------+------------------------+
Total: 36 bytes per 32 elements
       = 9 bits/element average
       = 3.6x compression vs FP32 (32 bytes)
```

### K-Quant Formats (Q4_K, Q5_K, Q6_K)

K-quant formats use super-blocks with better quantization:

```
Q4_K Super-block (256 elements):

+---------------------------+------------------------+
|      super_block[0]       |      super_block[1]    |
|      (4 sub-blocks)       |      (4 sub-blocks)    |
+---------------------------+------------------------+
| sub-block 0: qs[16], d[4] | sub-block 2: qs[16], d[4] |
| sub-block 1: qs[16], d[4] | sub-block 3: qs[16], d[4] |
| d_min (4 bytes)           |                         |
+---------------------------+------------------------+
Total: ~4.5 bits/element
```

## Quantization Parameters

```c
// From ggml-common.h
#define QK4_0 32
#define QK4_1 32
#define QK5_0 32
#define QK5_1 32
#define QK8_0 32
#define QK8_1 32
#define QK_K 256

// Scales and minimums
#define GGML_QK4_0_SCALE 1.0f / 16.0f
#define GGML_QK4_0_MIN   -8.0f

#define GGML_QK8_0_SCALE 1.0f
```

## Quantization Algorithm

The K-means-style quantization algorithm:

```c
// From ggml-quants.c - Conceptual quantization
void quantize_row_q4_0(const float * restrict x, void * restrict y, int k) {
    const int nb = k / QK4_0;
    
    for (int i = 0; i < nb; i++) {
        // Find min and max in block
        float min_val = x[i*32];
        float max_val = x[i*32];
        
        for (int j = 1; j < 32; j++) {
            const float v = x[i*32 + j];
            if (v < min_val) min_val = v;
            if (v > max_val) max_val = v;
        }
        
        // Calculate scale and minimum
        const float scale = (max_val - min_val) / 15.0f;
        const float min_quant = min_val;
        
        // Quantize each value
        for (int j = 0; j < 16; j++) {
            const float v0 = x[i*32 + j*2 + 0];
            const float v1 = x[i*32 + j*2 + 1];
            
            uint8_t q0 = (uint8_t)((v0 - min_quant) / scale + 0.5f);
            uint8_t q1 = (uint8_t)((v1 - min_quant) / scale + 0.5f);
            
            block.qs[j] = (q1 << 4) | q0;
        }
        
        // Store minimum as 16-bit (scale is fixed at 1/16)
        block.m = (uint16_t)(min_quant * 16.0f + 32768.0f);
    }
}
```

## Dequantize-on-the-Fly Pattern

GGML's key optimization: dequantize during computation, not upfront:

```c
// Quantized matmul: C = A * B (both quantized)
void ggml_mul_mat_q4_0_q8_0(
    const void * restrict vA,
    const void * restrict vB,
    float * restrict vC,
    int n
) {
    const block_q4_0 * A = vA;
    const block_q8_0 * B = vB;
    
    // Dequantize block-by-block during matmul
    for (int i = 0; i < n; i += QK4_0) {
        // Dequantize A block
        float A_block[32];
        dequantize_block_q4_0(&A[i/QK4_0], A_block);
        
        // Dequantize B block and compute
        for (int j = 0; j < n; j += QK8_0) {
            float B_block[32];
            dequantize_block_q8_0(&B[j/QK8_0], B_block);
            
            // Compute dot product
            for (int k = 0; k < 32; k++) {
                vC[i*n + j] += A_block[k] * B_block[k];
            }
        }
    }
}
```

## Memory Comparison

```
FP32 Matrix (1024 x 1024):
Size: 1024 * 1024 * 4 bytes = 4 MB

Q4_0 Quantized:
Size: (1024 * 1024 / 32) * 18 bytes = 589,824 bytes = 0.56 MB
Compression: 7.1x

Q8_0 Quantized:
Size: (1024 * 1024 / 32) * 36 bytes = 1,179,648 bytes = 1.12 MB
Compression: 3.6x
```

## Accuracy Impact

| Format | Perplexity (LLaMA-7B) | Memory Savings |
|--------|----------------------|----------------|
| FP16 (baseline) | 5.68 | 1x |
| Q8_0 | 5.69 | 2x |
| Q5_1 | 5.70 | 4x |
| Q5_0 | 5.74 | 4x |
| Q4_1 | 5.78 | 8x |
| Q4_0 | 5.85 | 8x |
| Q3_K | 5.89 | 10x |

## Implementing Quantization for MathZig

### 1. Quantized Matrix Type

```zig
// Proposed QuantizedMatrix type for MathZig
pub const QuantizedMatrix = struct {
    data: []const u8,  // Raw quantized bytes
    rows: u32,
    cols: u32,
    block_size: u32,   // QK (typically 32)
    format: QuantFormat,
    
    pub const QuantFormat = enum {
        q4_0,
        q4_1,
        q5_0,
        q5_1,
        q8_0,
        q8_1,
    };
};
```

### 2. Block Structure

```zig
// Q4_0 block (18 bytes)
pub const BlockQ4_0 = packed struct {
    qs: [16]u8,   // 4-bit values packed
    m: u16,       // minimum value (stored as u16)
};

// Q8_0 block (36 bytes)
pub const BlockQ8_0 = packed struct {
    qs: [32]i8,   // 8-bit values
    d: f32,       // scale factor
};
```

### 3. Dequantization Function

```zig
// Dequantize a single block
pub fn dequantizeBlockQ4_0(comptime out_len: usize, block: BlockQ4_0, out: *[out_len]f64) void {
    const scale = 1.0 / 16.0;
    const min_val = @as(f64, @floatFromInt(@as(i16, @intCast(block.m)))) / 16.0 - 8.0;
    
    for (0..16) |i| {
        const q = block.qs[i];
        const lo = @as(f64, @floatFromInt(q & 0x0F)) * scale + min_val;
        const hi = @as(f64, @floatFromInt(q >> 4)) * scale + min_val;
        
        if (i * 2 < out_len) out[i * 2] = lo;
        if (i * 2 + 1 < out_len) out[i * 2 + 1] = hi;
    }
}
```

### 4. Quantized Matmul

```zig
// Quantized matrix multiplication with dequantize-on-the-fly
pub fn matmulQuantized(
    A: QuantizedMatrix,
    B: QuantizedMatrix,
    C: []f64,
    rows_a: u32,
    cols_a: u32,
    cols_b: u32
) void {
    // Align to block size
    const K = cols_a;
    const block_k = A.block_size;
    
    // Process block-by-block
    var i: u32 = 0;
    while (i < rows_a) : (i += 1) {
        var j: u32 = 0;
        while (j < cols_b) : (j += 1) {
            var sum: f64 = 0.0;
            
            var k: u32 = 0;
            while (k < K) : (k += block_k) {
                // Dequantize blocks on-the-fly
                var a_block: [32]f64 = undefined;
                var b_block: [32]f64 = undefined;
                
                dequantizeBlockQ4_0(32, A.getBlock(i, k), &a_block);
                dequantizeBlockQ8_0(32, B.getBlock(k, j), &b_block);
                
                // Compute partial dot product
                for (0..block_k) |kk| {
                    sum += a_block[kk] * b_block[kk];
                }
            }
            
            C[i * cols_b + j] = sum;
        }
    }
}
```

### 5. SIMD-Optimized Dequantization

```zig
// SIMD dequantization for Q4_0
pub fn dequantizeBlockQ4_0Simd(block: BlockQ4_0, out: *[32]f64) void {
    // Extract and expand 4-bit values to 8-bit
    const q_lo = [8]u8{
        block.qs[0] & 0x0F,
        block.qs[1] & 0x0F,
        block.qs[2] & 0x0F,
        block.qs[3] & 0x0F,
        block.qs[4] & 0x0F,
        block.qs[5] & 0x0F,
        block.qs[6] & 0x0F,
        block.qs[7] & 0x0F,
    };
    
    const q_hi = [8]u8{
        block.qs[0] >> 4,
        block.qs[1] >> 4,
        block.qs[2] >> 4,
        block.qs[3] >> 4,
        block.qs[4] >> 4,
        block.qs[5] >> 4,
        block.qs[6] >> 4,
        block.qs[7] >> 4,
    };
    
    // Convert to f64 and apply scale/min
    const scale = @splat(1.0 / 16.0);
    const min_val = @splat(min_val);
    
    const lo_vec: Vec = @as(Vec, @bitCast(q_lo)) * scale + min_val;
    const hi_vec: Vec = @as(Vec, @bitCast(q_hi)) * scale + min_val;
    
    out[0..4].* = lo_vec;
    out[4..8].* = hi_vec;
    // ... repeat for remaining 24 elements
}
```

## Implementation Roadmap

| Priority | Task | Complexity | Impact |
|----------|------|------------|--------|
| 1 | Add BlockQ4_0/Q8_0 structures | Low | Foundation |
| 2 | Implement quantization utility functions | Medium | Enables tools |
| 3 | Implement dequantization functions | Medium | Performance |
| 4 | Add quantized matmul with dequantize-on-fly | High | Core feature |
| 5 | SIMD-optimized dequantization | High | Performance |
| 6 | K-quant formats (Q4_K, etc.) | Very High | Best quality |

## Considerations for MathZig

1. **Use Case Fit**: MathZig is for financial calculations where accuracy is critical. Quantization should be optional.

2. **FP16 Support**: Quantization to Q4/Q5 formats requires FP16 intermediate. MathZig currently uses FP64.

3. **Accuracy Tradeoff**: Financial applications typically require high precision. Q8_0 (3.6x compression, near-FP32 accuracy) may be the best fit.

4. **Hybrid Approach**: Store matrices in FP32 but quantize during serialization/deserialization for disk/memory savings.

5. **Gradual Quantization**: Add quantization as an optional feature, not the default.
