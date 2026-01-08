# Data Types & Quantization

GGML supports multiple data types and quantization formats optimized for different accuracy/performance tradeoffs.

## Native Data Types

### FP32 (Single Precision)
- **Size**: 32 bits (4 bytes)
- **Range**: ~1.18e-38 to 3.4e38
- **Precision**: ~7 decimal digits
- **Usage**: Activations, gradients, high-precision computations

### FP16 (Half Precision)
- **Size**: 16 bits (2 bytes)
- **Range**: ~6.1e-5 to 65504
- **Precision**: ~3 decimal digits
- **Usage**: Weights, activations where memory is constrained

### BF16 (Brain Float16)
- **Size**: 16 bits (2 bytes)
- **Range**: Same as FP32 (~1.18e-38 to 3.4e38)
- **Precision**: ~2 decimal digits (1 sign, 8 exponent, 7 mantissa)
- **Usage**: Training, applications requiring wider range

## FP16/BF16 Conversions

```c
// Half (FP16) to float32
static inline float ggml_half_to_fp32(ggml_half h) {
    return _cvtsh_ss(h);
}

// Float32 to half (FP16)
static inline ggml_half ggml_fp32_to_half(float f) {
    return _cvtss_sh(f, _MM_FROUND_TO_NEAREST_INT);
}

// BF16 to float32 (expand exponent)
static inline float ggml_bf16_to_fp32(uint16_t h) {
    const uint32_t w = (uint32_t)h << 16;
    return *(float*)&w;
}

// Float32 to BF16 (round to nearest even)
static inline uint16_t ggml_fp32_to_bf16(float f) {
    uint32_t w = *(uint32_t*)&f;
    const uint32_t w0 = (w + (1 << 15)) >> 16;
    return (uint16_t)w0;
}
```

## Block Quantization

GGML uses block-based quantization where multiple values share a single scale factor. This provides memory efficiency while maintaining accuracy.

### Block Size Constants

```c
#define QK_K 256      // Super-block size for K-quantization
#define K_SCALE_SIZE 12
```

## Standard Quantization Formats

### Q4_0 (4-bit, Block Size 32)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;           // delta (scale)
    uint8_t qs[16];        // 16 nibbles (4-bit values)
} block_q4_0;
```

**Bits per weight**: 4.125 (4 bits + 0.125 for scale)
**Memory savings**: ~7.7x vs FP32

**Dequantization:**
```c
for (int i = 0; i < 16; i++) {
    uint8_t q = qs[i] & 0xF;
    values[2*i]     = d * ((int8_t)q - 8);
    values[2*i + 1] = d * ((int8_t)(qs[i] >> 4) - 8);
}
```

**Characteristics:**
- Simple 4-bit representation
- Values in range [-8, 7] * d
- Good for smaller models, moderate accuracy loss

### Q4_1 (4-bit with Min, Block Size 32)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;           // delta (scale)
    ggml_half m;           // min (offset)
    uint8_t qs[16];        // 16 nibbles
} block_q4_1;
```

**Bits per weight**: 4.25 (4 bits + 0.25 for scale+min)
**Memory savings**: ~7.5x vs FP32

**Dequantization:**
```c
for (int i = 0; i < 16; i++) {
    uint8_t q = qs[i] & 0xF;
    values[2*i]     = d * q + m;
    values[2*i + 1] = d * (qs[i] >> 4) + m;
}
```

**Characteristics:**
- Adds per-block minimum value
- Better representation of asymmetric distributions
- Slightly more memory than Q4_0

### Q5_0 (5-bit, Block Size 32)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;           // delta
    uint8_t qh[4];         // high bit (5th bit) for each of 32 values
    uint8_t qs[16];        // low 4 bits
} block_q5_0;
```

**Bits per weight**: 5.125 (5 bits + 0.125 for scale)
**Memory savings**: ~6.2x vs FP32

**Characteristics:**
- 5-bit precision for better accuracy
- High bit stored separately (4 bytes for 32 values)
- Good balance of size/accuracy

### Q5_1 (5-bit with Min, Block Size 32)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;           // delta
    ggml_half m;           // min
    uint8_t qh[4];         // high bit for 32 values
    uint8_t qs[16];        // low 4 bits
} block_q5_1;
```

**Bits per weight**: 5.25
**Memory savings**: ~6.1x vs FP32

### Q8_0 (8-bit, Block Size 32)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;       // delta
    int8_t  qs[32];    // 8-bit signed values
} block_q8_0;
```

**Bits per weight**: 8.0625 (8 bits + 0.0625 for scale)
**Memory savings**: ~4x vs FP32

**Characteristics:**
- Full 8-bit precision
- Often used for activations, not weights
- Reference format for accuracy comparisons

### Q8_1 (8-bit with Sum, Block Size 32)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;           // delta
    ggml_half s;           // d * sum(qs[i]) - for fast dot products
    int8_t qs[32];         // 8-bit values
} block_q8_1;
```

**Characteristics:**
- Pre-computed sum for matmul optimization
- Reduces compute in dot products

## K-Quantization Formats (Super-Block 256)

These formats use a two-level quantization with 16 sub-blocks of 16 elements each.

### Q2_K (2-bit K-Quantization)

**Memory Layout:**
```c
typedef struct {
    uint8_t scales[16];    // quantized scales and mins (4 bits each)
    uint8_t qs[64];        // 2-bit quants (4 per byte)
    ggml_half d;           // super-block scale
    ggml_half dmin;        // super-block min scale
} block_q2_K;
```

**Bits per weight**: 2.625
**Memory savings**: ~12x vs FP32

**Structure:**
- 16 sub-blocks of 16 elements
- Each sub-block has 4-bit scale + 4-bit min
- 2-bit values within each sub-block

### Q3_K (3-bit K-Quantization)

**Memory Layout:**
```c
typedef struct {
    uint8_t hmask[32];     // high bit mask (256 values)
    uint8_t qs[64];        // low 2 bits (4 per byte)
    uint8_t scales[12];    // 6-bit scales
    ggml_half d;           // super-block scale
} block_q3_K;
```

**Bits per weight**: 3.4375
**Memory savings**: ~9.3x vs FP32

### Q4_K (4-bit K-Quantization)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;           // super-block scale
    ggml_half dmin;        // super-block min scale
    uint8_t scales[12];    // 6-bit quantized scales+mins
    uint8_t qs[128];       // 4-bit values (2 per byte)
} block_q4_K;
```

**Bits per weight**: 4.5
**Memory savings**: ~7.1x vs FP32

**Structure:**
- 8 sub-blocks of 32 elements
- Per-sub-block scale + min
- High accuracy for its bitwidth

### Q5_K (5-bit K-Quantization)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;           // super-block scale
    ggml_half dmin;        // super-block min scale
    uint8_t scales[12];    // quantized scales+mins
    uint8_t qh[32];        // high bit for 5-bit values
    uint8_t qs[128];       // low 4 bits
} block_q5_K;
```

**Bits per weight**: 5.5
**Memory savings**: ~5.8x vs FP32

### Q6_K (6-bit K-Quantization)

**Memory Layout:**
```c
typedef struct {
    uint8_t ql[128];       // lower 4 bits
    uint8_t qh[64];        // upper 2 bits
    int8_t  scales[16];    // 8-bit scales
    ggml_half d;           // super-block scale
} block_q6_K;
```

**Bits per weight**: 6.5625
**Memory savings**: ~4.9x vs FP32

## Improved Quantization (IQ Formats)

### IQ2_XXS (2-bit Improved)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint16_t qs[32];       // 2-bit values packed
} block_iq2_xxs;
```

**Bits per weight**: 2.0625
**Memory savings**: ~15.4x vs FP32

**Key innovation:** Uses lookup tables for efficient dequantization.

### IQ2_XS (2-bit with Scales)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint16_t qs[32];
    uint8_t  scales[8];
} block_iq2_xs;
```

**Bits per weight**: 2.3125
**Memory savings**: ~13.8x vs FP32

### IQ2_S (2-bit Sparse)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint8_t qs[64];
    uint8_t qh[8];
    uint8_t scales[8];
} block_iq2_s;
```

**Bits per weight**: 2.5625
**Memory savings**: ~12.5x vs FP32

### IQ3_XXS (3-bit Improved)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint8_t qs[96];        // 3 bits per value
} block_iq3_xxs;
```

**Bits per weight**: 3.0625
**Memory savings**: ~10.4x vs FP32

### IQ3_S (3-bit with Signs)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint8_t qs[64];
    uint8_t qh[8];
    uint8_t signs[32];
    uint8_t scales[4];
} block_iq3_s;
```

**Bits per weight**: 3.4375
**Memory savings**: ~9.3x vs FP32

### IQ1_S (1-bit Sparse)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint8_t  qs[32];
    uint16_t qh[8];
} block_iq1_s;
```

**Bits per weight**: 1.5625
**Memory savings**: ~20x vs FP32

### IQ1_M (1-bit Mixed)

**Memory Layout:**
```c
typedef struct {
    uint8_t  qs[32];       // grid indices
    uint8_t  qh[16];       // high bits
    uint8_t  scales[8];    // block scales
} block_iq1_m;
```

**Bits per weight**: 1.75
**Memory savings**: ~18x vs FP32

### IQ4_NL (4-bit Non-Linear)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint8_t qs[16];
} block_iq4_nl;
```

**Bits per weight**: 4.125
**Memory savings**: ~7.7x vs FP32

**Uses non-linear quantization for better accuracy.**

### IQ4_XS (4-bit Extended)

**Memory Layout:**
```c
typedef struct {
    ggml_half d;
    uint16_t scales_h;
    uint8_t  scales_l[4];
    uint8_t  qs[128];
} block_iq4_xs;
```

**Bits per weight**: 4.25
**Memory savings**: ~7.5x vs FP32

## MXFP4 (Mixed-Precision FP4)

**Memory Layout:**
```c
typedef struct {
    uint8_t e;     // E8M0 exponent bias
    uint8_t qs[16]; // 4-bit values
} block_mxfp4;
```

**Bits per weight**: 4.25
**Memory savings**: ~7.5x vs FP32

**Key innovation:** Uses block-level shared exponent (E8M0 format).

## Ternary Quantization

### TQ1_0 (Ternary, ~1.6875 bpw)

**Memory Layout:**
```c
typedef struct {
    uint8_t qs[(256-16)/5]; // 5 elements per byte (base-3 encoding)
    uint8_t qh[4];         // high bits
    ggml_half d;
} block_tq1_0;
```

**Uses base-3 encoding for values {-1, 0, 1}.**

### TQ2_0 (Ternary, 2-bit)

**Memory Layout:**
```c
typedef struct {
    uint8_t qs[64];        // 2 bits per element
    ggml_half d;
} block_tq2_0;
```

**Values in {-2, -1, 0, 1} * d.**

## Quantization Summary

| Format | bpw | Memory | Accuracy | Use Case |
|--------|-----|--------|----------|----------|
| FP32 | 32 | 1x | Reference | Activations, training |
| FP16 | 16 | 2x | Good | Weights, activations |
| Q8_0 | 8.06 | 4x | Excellent | High-precision quantized |
| Q8_1 | 8.12 | 4x | Excellent | Fast dot products |
| Q6_K | 6.56 | 4.9x | Very Good | General purpose |
| Q5_K | 5.5 | 5.8x | Good | Balanced |
| Q5_1 | 5.25 | 6.1x | Good | Standard 5-bit |
| Q5_0 | 5.125 | 6.2x | Good | Light 5-bit |
| Q4_K | 4.5 | 7.1x | Good | Recommended 4-bit |
| Q4_1 | 4.25 | 7.5x | Good | Standard 4-bit |
| Q4_0 | 4.125 | 7.7x | Fair | Small models |
| IQ4_XS | 4.25 | 7.5x | Good | Non-linear 4-bit |
| IQ3_XXS | 3.06 | 10.4x | Fair | Low memory |
| Q3_K | 3.44 | 9.3x | Fair | Low memory |
| IQ2_XXS | 2.06 | 15.4x | Low | Extreme compression |
| Q2_K | 2.625 | 12x | Low | Very low memory |

## Dequantization Strategy

GGML uses **dequantize-on-the-fly** for matmul:

```c
// For Q4_0 matmul against FP32 vector:
float sum = 0;
for (int i = 0; i < nb; i++) {
    ggml_half d = blocks[i].d;
    uint8_t *q = blocks[i].qs;
    for (int j = 0; j < 16; j++) {
        int8_t v1 = (q[j] & 0xF) - 8;
        int8_t v2 = (q[j] >> 4) - 8;
        sum += (float)(v1 + v2) * d * x[i*32 + j];
    }
}
```

**Benefits:**
- No full dequantization needed
- Scales applied during computation
- Reduces memory bandwidth

## Quantization Best Practices

1. **Start with Q4_K or IQ4_XS**: Best accuracy/size tradeoff
2. **Use Q5_K/Q6_K for critical layers**: Better precision where needed
3. **Consider IQ formats for extreme compression**: Use IQ2_XXS for very low memory
4. **Test on your specific model**: Accuracy varies by model architecture
5. **Use quantized activations sparingly**: Better to keep activations in higher precision
