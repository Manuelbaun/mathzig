# GGML Architecture Overview

## Core Design Philosophy

GGML is designed around several key principles:

1. **Minimalism**: Pure C/C++ with minimal dependencies
2. **Portability**: Runs on CPU, GPU (CUDA, Metal, Vulkan, OpenCL), and specialized hardware
3. **Memory Efficiency**: Aggressive quantization and memory reuse
4. **Computation Graphs**: Lazy evaluation for optimization opportunities

## Tensor Structure

The fundamental data structure is `ggml_tensor`:

```c
struct ggml_tensor {
    enum ggml_type type;           // Data type (F32, F16, quantized, etc.)
    
    struct ggml_backend_buffer * buffer;  // Memory backend
    
    int64_t ne[GGML_MAX_DIMS];     // Number of elements per dimension (max 4D)
    size_t  nb[GGML_MAX_DIMS];     // Stride in bytes per dimension
    
    enum ggml_op op;               // Operation that produces this tensor
    int32_t op_params[16];         // Operation-specific parameters
    
    int32_t flags;                 // Tensor flags (input, output, param, loss)
    
    struct ggml_tensor * src[10];  // Source tensors for the operation
    
    struct ggml_tensor * view_src; // Source for view tensors
    size_t view_offs;              // Offset for views
    
    void * data;                   // Actual data pointer
    char name[64];                 // Tensor name for debugging
    void * extra;                  // Backend-specific data
};
```

### Key Design Decisions

**Stride-Based Layout**: Unlike some libraries that assume contiguous memory, GGML stores explicit strides (`nb[]`) for each dimension. This enables:
- Zero-copy transpositions and permutations
- Efficient sub-tensor views
- Support for non-contiguous data

**4D Maximum**: Tensors support up to 4 dimensions, which is sufficient for most ML workloads:
- `ne[0]`: Innermost dimension (column/feature size)
- `ne[1]`: Rows
- `ne[2]`: Batch dimension or attention heads
- `ne[3]`: Outer batch dimension

## Computation Graph

Operations don't execute immediately. Instead, they build a computation graph:

```c
struct ggml_cgraph {
    int size;                      // Maximum nodes/leafs
    int n_nodes;                   // Current node count
    int n_leafs;                   // Input/constant tensors
    
    struct ggml_tensor ** nodes;   // Nodes with computed values
    struct ggml_tensor ** grads;   // Gradient tensors
    struct ggml_tensor ** grad_accs; // Gradient accumulators
    struct ggml_tensor ** leafs;   // Constant/input tensors
    
    struct ggml_hash_set visited_hash_set; // For deduplication
    
    enum ggml_cgraph_eval_order order; // Evaluation order
};
```

### Graph Building Example

```c
// Define function: f(x) = a*x^2 + b
struct ggml_tensor * x = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 1);
struct ggml_tensor * a = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 1);
struct ggml_tensor * b = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 1);

struct ggml_tensor * x2 = ggml_mul(ctx, x, x);         // x^2
struct ggml_tensor * ax2 = ggml_mul(ctx, a, x2);       // a*x^2
struct ggml_tensor * f = ggml_add(ctx, ax2, b);        // a*x^2 + b

// Build graph
struct ggml_cgraph * gf = ggml_new_graph(ctx);
ggml_build_forward_expand(gf, f);

// Execute
ggml_graph_compute_with_ctx(ctx, gf, n_threads);
```

## Operation Types

GGML supports ~80 operations organized into categories:

### Unary Operations
```c
GGML_OP_DUP, GGML_OP_SQR, GGML_OP_SQRT, GGML_OP_LOG,
GGML_OP_SIN, GGML_OP_COS, GGML_OP_ABS, GGML_OP_NEG,
GGML_UNARY_OP_RELU, GGML_UNARY_OP_GELU, GGML_UNARY_OP_SILU,
GGML_UNARY_OP_SIGMOID, GGML_UNARY_OP_TANH, GGML_UNARY_OP_EXP
```

### Binary Operations
```c
GGML_OP_ADD, GGML_OP_SUB, GGML_OP_MUL, GGML_OP_DIV
```

### Matrix Operations
```c
GGML_OP_MUL_MAT,      // Matrix multiplication
GGML_OP_MUL_MAT_ID,   // Indirect matrix multiplication (for MoE)
GGML_OP_OUT_PROD      // Outer product
```

### Reduction Operations
```c
GGML_OP_SUM, GGML_OP_SUM_ROWS, GGML_OP_MEAN, GGML_OP_ARGMAX
```

### Normalization
```c
GGML_OP_NORM,         // Layer normalization
GGML_OP_RMS_NORM,     // RMS normalization
GGML_OP_GROUP_NORM,   // Group normalization
GGML_OP_L2_NORM       // L2 normalization
```

### Attention
```c
GGML_OP_FLASH_ATTN_EXT,  // Flash attention
GGML_OP_ROPE,            // Rotary position embeddings
GGML_OP_SOFT_MAX         // Softmax
```

### Shape Operations (Zero-Copy)
```c
GGML_OP_VIEW,       // Create a view
GGML_OP_RESHAPE,    // Reshape (no data copy)
GGML_OP_PERMUTE,    // Permute dimensions
GGML_OP_TRANSPOSE   // Transpose (2D permutation)
```

## Memory Context

All allocations happen through a context:

```c
struct ggml_init_params params = {
    .mem_size   = 16*1024*1024,  // 16 MB
    .mem_buffer = NULL,          // Allocate internally
    .no_alloc   = false          // Allocate tensor data
};

struct ggml_context * ctx = ggml_init(params);
// ... create tensors and compute ...
ggml_free(ctx);
```

This design:
- Avoids per-tensor allocation overhead
- Enables memory pool reuse
- Supports external memory buffers (e.g., mmap)

## Backend System

GGML abstracts hardware through backends:

```c
// Available backends
ggml-cpu.h      // CPU with SIMD
ggml-cuda.h     // NVIDIA CUDA
ggml-metal.h    // Apple Metal
ggml-vulkan.h   // Vulkan (cross-platform GPU)
ggml-opencl.h   // OpenCL
ggml-sycl.h     // Intel SYCL
ggml-cann.h     // Huawei Ascend
ggml-rpc.h      // Remote procedure call (distributed)
```

Each backend implements:
- Memory allocation/deallocation
- Tensor operations
- Synchronization primitives

## Thread Model

GGML uses a simple thread model:

```c
struct ggml_compute_params {
    int ith;        // Thread index
    int nth;        // Total threads
    void * wdata;   // Thread-local scratch space
};
```

Work is divided by rows:
```c
const int nr = ggml_nrows(tensor);
const int dr = (nr + nth - 1) / nth;  // Rows per thread
const int ir0 = dr * ith;             // Start row
const int ir1 = MIN(ir0 + dr, nr);    // End row
```

## Key Macros

```c
// Tensor dimension accessors
GGML_TENSOR_UNARY_OP_LOCALS   // Extracts ne0, nb0, ne, nb
GGML_TENSOR_BINARY_OP_LOCALS  // For two-input operations

// Memory alignment
GGML_MEM_ALIGN  // 16 bytes on 64-bit, 4 on 32-bit

// Padding helper
GGML_PAD(x, n)  // Pad x up to multiple of n
```
