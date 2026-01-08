# Memory Management

GGML implements a sophisticated memory management system optimized for tensor operations.

## Memory Alignment

### Alignment Requirements

```c
// Memory alignment constant
#define GGML_MEM_ALIGN 16  // 16 bytes on 64-bit, 4 on 32-bit

// Padding macro
#define GGML_PAD(x, n) (((x) + (n) - 1) / (n) * (n))
```

**Why 16-byte alignment?**
- SSE/AVX registers are 128/256/512 bits (16/32/64 bytes)
- Aligned loads are faster than unaligned
- SIMD operations require aligned memory

### Tensor Alignment

```c
struct ggml_tensor {
    // ...
    size_t nb[GGML_MAX_DIMS];  // Strides in bytes
    void * data;               // Data pointer
    // ...
};
```

**Strides:**
```c
// For a 4D tensor (batch, head, sequence, hidden)
tensor->ne[0] = d_model;      // 4096
tensor->ne[1] = n_heads;      // 32
tensor->ne[2] = seq_len;      // 2048
tensor->ne[3] = batch_size;   // 1

// Contiguous layout (most common)
tensor->nb[0] = sizeof(float);           // 4 bytes
tensor->nb[1] = tensor->ne[0] * nb[0];   // 4096 * 4 = 16384
tensor->nb[2] = tensor->ne[1] * nb[1];   // 32 * 16384 = 524288
tensor->nb[3] = tensor->ne[2] * nb[2];   // 2048 * 524288 = 1073741824
```

## Context-Based Allocation

### Context Structure

```c
struct ggml_context {
    const struct ggml_init_params * params;

    size_t mem_size;          // Total memory allocated
    void * mem_buffer;        // Memory buffer

    bool no_alloc;            // Don't allocate tensor data
    bool is_allocated;        // Has memory been allocated?

    struct ggml_object * objects_begin;
    struct ggml_object * objects_end;

    struct ggml_scratch {
        size_t offs;
        size_t size;
        void * data;
    } scratch;
};
```

### Context Initialization

```c
struct ggml_init_params params = {
    .mem_size = 16 * 1024 * 1024,  // 16 MB
    .mem_buffer = NULL,             // Allocate internally
    .no_alloc = false,              // Allocate tensor data
};

struct ggml_context * ctx = ggml_init(params);
```

**Parameters:**
- `mem_size`: Size of the memory pool
- `mem_buffer`: Optional pre-allocated buffer (NULL = malloc)
- `no_alloc`: If true, don't allocate tensor data (use external buffer)

### Tensor Creation

```c
// Create a tensor
struct ggml_tensor * tensor = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, n, m);

// Set tensor data
float * data = (float *)tensor->data;

// Or create with external data
struct ggml_tensor * ext_tensor = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n);
ext_tensor->data = external_buffer;  // Point to existing memory
```

## Memory Pool

### Pooled Allocation

```c
// Internal object structure
struct ggml_object {
    enum ggml_object_type type;
    size_t size;              // Size of this object
    struct ggml_object * next;
    // Tensor data follows
};
```

**Allocation flow:**
```c
void * ggml_alloc(struct ggml_context * ctx, size_t size) {
    // Align size to GGML_MEM_ALIGN
    size_t aligned_size = GGML_PAD(size, GGML_MEM_ALIGN);

    // Check if there's enough space
    if (ctx->scratch.offs + aligned_size > ctx->scratch.size) {
        return NULL;  // Out of memory
    }

    // Allocate from pool
    void * ptr = (char *)ctx->scratch.data + ctx->scratch.offs;
    ctx->scratch.offs += aligned_size;

    return ptr;
}
```

**Benefits:**
1. Single allocation for all tensors
2. No per-tensor malloc overhead
3. Contiguous memory for related tensors
4. Easy cleanup (just free the pool)

### Scratch Memory

```c
// Scratch memory for temporary allocations
struct ggml_scratch {
    size_t offs;
    size_t size;
    void * data;
} scratch;

// Operations
ggml_scratch_set(ctx, 0, 10 * 1024 * 1024);  // 10 MB scratch

// Allocate temporary memory
void * temp = ggml_scratch_get(ctx, size);

// Reset scratch for next operation
ggml_scratch_reset(ctx);
```

## Backend Buffer System

### Backend Interface

```c
struct ggml_backend {
    enum ggml_backend_type type;
    const char * name;

    void * (*get_tensor_buffer)(struct ggml_backend * backend);
    void * (*alloc_buffer)(struct ggml_backend * backend, size_t size);
    void (*free_buffer)(struct ggml_backend * backend, void * buffer);

    void (*set_tensor)(struct ggml_backend * backend,
                       struct ggml_tensor * tensor);
    void (*get_tensor)(struct ggml_backend * backend,
                       struct ggml_tensor * tensor);

    void (*compute)(struct ggml_backend * backend,
                    struct ggml_compute_params * params,
                    struct ggml_tensor * tensor);
};
```

### CPU Backend

```c
// CPU backend buffer
struct ggml_backend_cpu {
    struct ggml_backend base;
    void * memory;           // Memory mappings
    size_t memory_size;
    int n_threads;
};

// Allocate CPU buffer
void * ggml_cpu_alloc_buffer(struct ggml_backend * backend, size_t size) {
    void * ptr = NULL;
    posix_memalign(&ptr, 64, size);  // 64-byte alignment for AVX-512
    return ptr;
}
```

### Buffer Types

| Buffer Type | Backend | Alignment | Use Case |
|-------------|---------|-----------|----------|
| CPU | ggml-cpu | 64 bytes | CPU tensors |
| CUDA | ggml-cuda | 256 bytes | GPU tensors |
| Metal | ggml-metal | 256 bytes | Apple GPU |
| Vulkan | ggml-vulkan | 256 bytes | Cross-GPU |
| RPC | ggml-rpc | N/A | Distributed |

## Tensor Views and Strides

### Zero-Copy Views

```c
// Create a view of existing tensor
struct ggml_tensor * view = ggml_view_1d(ctx, src, n, offset);

// 2D view with custom strides
struct ggml_tensor * view = ggml_view_2d(ctx, src, n0, n1, stride0, stride1);

// View with different shape (no data copy)
struct ggml_tensor * reshaped = ggml_reshape(ctx, src, new_shape);
```

### Stride-Based Access

```c
// Access element at (i, j, k, l)
size_t offset = i * tensor->nb[0] +
                j * tensor->nb[1] +
                k * tensor->nb[2] +
                l * tensor->nb[3];

float value = *((float *)tensor->data + offset);
```

**Common layouts:**
```c
// Contiguous (row-major)
tensor->nb[0] = sizeof(T);                    // 4
tensor->nb[1] = tensor->ne[0] * nb[0];        // stride of one row
tensor->nb[2] = tensor->ne[1] * nb[1];        // stride of one column
tensor->nb[3] = tensor->ne[2] * nb[2];        // etc.

// Transposed
tensor->nb[0] = tensor->ne[1] * sizeof(T);
tensor->nb[1] = sizeof(T);

// Channel-first (CHW)
tensor->nb[0] = 1;                    // per channel element
tensor->nb[1] = C;                    // per row
tensor->nb[2] = C * H;                // per channel
```

## Memory Mapping

### File-Backed Tensors

```c
// Memory map a file
int fd = open("weights.bin", O_RDONLY);
void * data = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);

// Create tensor pointing to mmap'd data
struct ggml_tensor * tensor = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, rows, cols);
tensor->data = data;
tensor->nb[0] = sizeof(float);
tensor->nb[1] = rows * sizeof(float);

// Clean up
munmap(data, file_size);
close(fd);
```

**Benefits:**
- Zero copy when loading
- Demand paging
- Share across processes

## Quantization Memory Layout

### Block Storage

```c
// Q4_0: 32 values per block
// | delta (2 bytes) | q0 (1) | q1 (1) | ... | q15 (1) | = 18 bytes total
// 32 FP32 values = 128 bytes
// Compression: 18/128 = 14%

typedef struct {
    ggml_half d;           // delta scale
    uint8_t qs[16];        // 16 nibbles = 32 values
} block_q4_0;
```

### Access Patterns

```c
// Dequantize a block for processing
void dequantize_block(const block_q4_0 * block, float * values) {
    const float d = GGML_FP16_TO_FP32(block->d);

    for (int i = 0; i < 16; i++) {
        uint8_t q = block->qs[i];
        values[2*i]     = d * ((int8_t)(q & 0xF) - 8);
        values[2*i + 1] = d * ((int8_t)(q >> 4) - 8);
    }
}
```

## Memory Best Practices

### 1. Context Reuse

```c
// Create context once, reuse for multiple operations
struct ggml_context * ctx = ggml_init(params);

for (int i = 0; i < num_iterations; i++) {
    // Create tensors (uses pooled allocation)
    struct ggml_tensor * a = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, m, k);
    struct ggml_tensor * b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, k, n);

    // Build and compute graph
    // ...

    // Reset scratch (don't free context)
    ggml_scratch_reset(ctx);
}

// Free at end
ggml_free(ctx);
```

### 2. Quantize Before Storage

```c
// For model files: store quantized weights
ggml_quantize_params params = {
    .type = GGML_TYPE_Q4_K,
    .block_size = 32,
};

size_t written;
ggml_quantize_tensor(original_data, quantized_data, nelements, &params, &written);
fwrite(quantized_data, 1, written, file);
```

### 3. Scratch Memory for Temporaries

```c
// Set scratch for intermediate allocations
ggml_scratch_set(ctx, 0, 16 * 1024 * 1024);  // 16 MB scratch

// Operations that need temporaries will allocate from scratch
struct ggml_tensor * result = ggml_mul_mat(ctx, a, b);

// Reset for next operation
ggml_scratch_reset(ctx);
```

### 4. Alignment for SIMD

```c
// Ensure tensor data is aligned for SIMD
struct ggml_tensor * tensor = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n);

// Verify alignment
assert(((uintptr_t)tensor->data % 16) == 0);

// If using posix_memalign
void * data;
posix_memalign(&data, 64, size);  // 64-byte for AVX-512
```

## Memory Debugging

### Allocation Tracking

```c
// Enable debug mode
#define GGML_DEBUG 1

// Track allocations
void * ggml_alloc_debug(struct ggml_context * ctx, size_t size) {
    printf("Allocating %zu bytes at %p\n", size, ptr);
    // ... track allocations
}
```

### Memory Statistics

```c
struct ggml_memory_stats {
    size_t total_allocated;
    size_t total_freed;
    size_t current_used;
    size_t peak_used;
    size_t n_allocs;
};

struct ggml_memory_stats stats = ggml_get_memory_stats(ctx);
printf("Current memory: %zu bytes\n", stats.current_used);
printf("Peak memory: %zu bytes\n", stats.peak_used);
```

## Memory Summary

| Aspect | Technique | Benefit |
|--------|-----------|---------|
| Pool allocation | Context-based | No per-tensor malloc |
| Alignment | 16-64 byte | SIMD efficiency |
| Quantization | Block storage | 4-8x memory reduction |
| Scratch memory | Reset pool | Reuse temporaries |
| Memory mapping | mmap | Zero-copy loading |
| Views | Stride-based | Zero-copy reshape |
