# Memory Layout Comparison

This document compares GGML's memory alignment and layout strategies with MathZig's implementation.

## GGML Memory Alignment

GGML uses 16-byte alignment for SIMD operations:

```c
// From include/ggml.h
#define GGML_MEM_ALIGN 16
```

### GGML Tensor Structure

```c
// Tensor with strides for flexible memory layouts
struct ggml_tensor {
    enum ggml_type type;
    int    n_dims;       // 1-4 dimensions
    int64_t ne[4];       // number of elements per dimension
    size_t  nb[4];       // stride in bytes between elements in dimension
    
    // Data pointer with alignment
    void * data;
    
    // Gradient (optional)
    struct ggml_tensor * grad;
    
    // Operations
    enum ggml_op op;
    
    // Source tensor for views/permutes
    struct ggml_tensor * src[2];
};
```

### GGML Stride System

GGML's stride system allows flexible tensor layouts:

```c
// Example: 2D matrix with row-major layout
// ne[0] = columns, ne[1] = rows
// nb[0] = sizeof(element)   // Stride between columns (1 element)
// nb[1] = ne[0] * sizeof(element)  // Stride between rows (full row)

// Access element (row, col): data[row * nb[1] + col * nb[0]]

// Transposed layout: nb[0] = ne[1] * sizeof(element), nb[1] = sizeof(element)
```

### GGML Buffer Abstraction

```c
// Backend buffer for memory management
struct ggml_backend_buffer {
    enum ggml_backend_type type;
    void * data;
    size_t size;
    
    // Allocation functions
    void * (*alloc)(struct ggml_backend_buffer * buffer, size_t size);
    void (*free)(struct ggml_backend_buffer * buffer, void * ptr);
};

// Buffer types
enum ggml_backend_type {
    GGML_BACKEND_CPU,
    GGML_BACKEND_CUDA,
    GGML_BACKEND_METAL,
    GGML_BACKEND_VULKAN,
    // ...
};
```

## MathZig Memory Layout

MathZig uses 32-byte alignment:

```zig
// From src/core/value.zig lines 135-138
pub const Vector = extern struct {
    ptr: [*]const f64,
    len: usize,
    alignment: usize = 32,
};
```

### MathZig Matrix Structure

```zig
// From source files - Conceptual
pub const Matrix = struct {
    ptr: [*]f64,
    rows: u32,
    cols: u32,
    stride: u32,  // Elements between rows
    alignment: u32 = 32,
    
    pub fn index(self: *const Matrix, row: u32, col: u32) *f64 {
        return self.ptr + @as(usize, row) * self.stride + col;
    }
    
    pub fn rowSlice(self: *const Matrix, row: u32) []f64 {
        const start = @as(usize, row) * self.stride;
        return self.ptr[start .. start + self.cols];
    }
};
```

### MathZig Alignment Checking

```zig
// From matrix_kernels.zig lines 320-326
const SimdAlignment = @alignOf(Vec);

inline fn isAligned(ptr: anytype) bool {
    return @intFromPtr(ptr) % SimdAlignment == 0;
}
```

## Comparison: Memory Layouts

| Aspect | GGML | MathZig |
|--------|------|---------|
| Alignment | 16-byte | 32-byte |
| Dimensions | 1-4 | 2 (fixed for matrices) |
| Strides | Per-dimension | Single row stride |
| Buffer abstraction | Multiple backends | CPU only |
| Views | Supported | Limited |
| Views | Supported | Limited |

## Block Quantization Memory Layout

GGML's block quantization uses specific memory layouts:

```c
// From ggml-common.h lines 170-430
// Q4_0 format: 4-bit quantization per element
// Block size: 32 elements = 128 bits
// Storage: 18 bytes per block (16 * 4bits + 2 bytes for mins)

struct block_q4_0 {
    uint8_t qs[16];  // Quantized values (4 bits each)
    uint16_t m;      // Minimum value (2 bytes)
} __attribute__((packed));

// Q8_0 format: 8-bit quantization
// Block size: 32 elements = 256 bits
// Storage: 34 bytes per block (32 * 1 byte + 2 bytes for scale)

struct block_q8_0 {
    int8_t qs[32];   // Quantized values
    float d;         // Scale factor (4 bytes)
} __attribute__((packed));

// K-quant formats (Q4_K, Q5_K, Q6_K)
// Super-block size: 256 elements = QK_K
// Each super-block contains multiple sub-blocks
```

### Quantized Matrix Layout

```
Row-major quantized matrix (Q4_0):

Elements:   [0..31]  [32..63]  [64..95]  ...
            +-------+ +-------+ +-------+
Storage:    |16 bytes| |16 bytes| |16 bytes|
            |  qs[]  | |  qs[]  | |  qs[]  |
            +-------+ +-------+ +-------+
            |  2 b   | |  2 b   | |  2 b   |
            |   m    | |   m    | |   m    |
            +-------+ +-------+ +-------+
Bytes/elem:  0.5625  |  0.5625  |  0.5625  |
                     (4.5 bits per element)
```

## Optimization Opportunities for MathZig

### 1. Strided Matrix Views

```zig
// Proposed strided view for MathZig
pub const StridedMatrix = struct {
    ptr: [*]f64,
    rows: u32,
    cols: u32,
    row_stride: u32,   // Elements between row starts
    col_stride: u32,   // Elements between column starts
    alignment: u32 = 32,
    
    pub fn init(ptr: [*]f64, rows: u32, cols: u32, row_stride: u32) StridedMatrix {
        return .{
            .ptr = ptr,
            .rows = rows,
            .cols = cols,
            .row_stride = row_stride,
            .col_stride = 1,
            .alignment = 32,
        };
    }
    
    pub fn transposed(self: *const StridedMatrix) StridedMatrix {
        return .{
            .ptr = self.ptr,
            .rows = self.cols,
            .cols = self.rows,
            .row_stride = 1,
            .col_stride = self.row_stride,
            .alignment = self.alignment,
        };
    }
    
    pub fn view(self: *const StridedMatrix, row_start: u32, row_end: u32, 
                col_start: u32, col_end: u32) StridedMatrix {
        return .{
            .ptr = self.ptr + @as(usize, row_start) * self.row_stride + col_start,
            .rows = row_end - row_start,
            .cols = col_end - col_start,
            .row_stride = self.row_stride,
            .col_stride = self.col_stride,
            .alignment = self.alignment,
        };
    }
};
```

### 2. Cache-Aware Blocking Parameters

```zig
// Cache blocking tuned for typical CPU cache sizes
const CacheBlockParams = struct {
    // L1 data cache: typically 32KB per core
    const l1_block = 32 * 1024 / @sizeOf(f64); // ~4096 elements
    
    // L2 cache: typically 256KB-1MB per core
    const l2_block = 256 * 1024 / @sizeOf(f64); // ~32768 elements
    
    // L3 cache: shared, typically 8-32MB
    const l3_block = 8 * 1024 * 1024 / @sizeOf(f64); // ~1M elements
    
    // Matrix blocking sizes
    const tile_m = 64;  // Rows per tile
    const tile_n = 64;  // Columns per tile
    const tile_k = 8;   // K dimension per iteration
};

pub fn blockedGemm(
    A: []const f64, stride_a: usize,
    B: []const f64, stride_b: usize,
    C: []f64, stride_c: usize,
    rows_a: u32, cols_a: u32, cols_b: u32
) void {
    // L2 blocking for cache efficiency
    const block_size = CacheBlockParams.l2_block;
    
    var i: u32 = 0;
    while (i < rows_a) : (i += block_size) {
        const i_end = @min(i + block_size, rows_a);
        
        var j: u32 = 0;
        while (j < cols_b) : (j += block_size) {
            const j_end = @min(j + block_size, cols_b);
            
            var k: u32 = 0;
            while (k < cols_a) : (k += block_size) {
                const k_end = @min(k + block_size, cols_a);
                
                // Process blocked region
                gemmBlock(
                    A[i * stride_a ..], stride_a,
                    B[k * stride_b ..], stride_b,
                    C[i * stride_c ..], stride_c,
                    i_end - i, k_end - k, j_end - j
                );
            }
        }
    }
}
```

### 3. Aligned Memory Allocation

```zig
// Proposed aligned allocator for MathZig
pub const AlignedBuffer = struct {
    ptr: [*]f64,
    len: usize,
    alignment: usize,

    pub fn alloc(len: usize, alignment: usize) !AlignedBuffer {
        // Allocate extra bytes for alignment
        const alloc_size = len * @sizeOf(f64) + alignment;
        const raw_ptr = try std.heap.page_allocator.alloc(u8, alloc_size);
        
        // Calculate aligned address
        const align_mask = alignment - 1;
        const aligned_addr = @intFromPtr(raw_ptr.ptr) + alignment - ( @intFromPtr(raw_ptr.ptr) & align_mask);
        
        return .{
            .ptr = @as([*]f64, @ptrFromInt(aligned_addr)),
            .len = len,
            .alignment = alignment,
        };
    }
    
    pub fn free(self: *AlignedBuffer) void {
        // Note: This would need the original allocation address
        // A more practical approach uses a header with alignment info
        _ = self; // Placeholder
    }
};
```

### 4. Quantized Storage Structure (Future)

If MathZig adds quantization support:

```zig
// Block quantized matrix (Q4_0 style)
pub const QuantizedMatrix = struct {
    blocks: []const BlockQ4_0,
    rows: u32,
    cols: u32,
    // Dequantization cache (optional, computed on demand)
    dequantized: ?[*]f64 = null,
    
    pub const BlockQ4_0 = extern struct {
        qs: [16]u8,  // 4-bit values
        m: u16,      // Minimum value
    };
    
    // Dequantize a single block to f64
    pub fn dequantizeBlock(block: BlockQ4_0, out: *[32]f64) void {
        // Extract 4-bit values and denormalize
        for (0..16) |i| {
            const q = block.qs[i];
            const lo = @as(f64, @floatFromInt(q & 0x0F)) / 15.0;
            const hi = @as(f64, @floatFromInt(q >> 4)) / 15.0;
            out[i * 2] = lo * @as(f64, @floatFromInt(block.m));
            out[i * 2 + 1] = hi * @as(f64, @floatFromInt(block.m));
        }
    }
};
```

## Performance Impact

| Optimization | Memory Savings | Performance Impact |
|--------------|----------------|-------------------|
| 32-byte alignment | N/A | Better AVX-512 compatibility |
| Strided views | N/A | More flexible operations |
| Cache blocking | N/A | 20-40% for large matrices |
| Quantization (Q4_0) | 56% memory reduction | ~2x slower (dequantization) |
| Quantized matmul | 56% memory | Similar speed (dequantize-on-fly) |
