# Memory Management

MathZig uses arena-based memory allocation for efficient expression compilation and VM execution.

## Memory Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MathZig Memory Layout                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                        Top-Level Allocator                             │  │
│  │  (std.mem.Allocator - typically page allocator)                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│         │                        │                        │                  │
│         ▼                        ▼                        ▼                  │
│  ┌─────────────┐        ┌─────────────┐        ┌─────────────────────┐    │
│  │  ChunkArena │        │    VM       │        │  CompiledExpr       │    │
│  │  (Strings)  │        │  Variables  │        │  (Bytecode + Const) │    │
│  └─────────────┘        └─────────────┘        └─────────────────────┘    │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    FFI Shared Memory Region                            │  │
│  │  ┌──────────────────────┐ ┌──────────────────────┐                   │  │
│  │  │ Input Buffer         │ │ Output Buffer        │                   │  │
│  │  │ (32-byte aligned)    │ │ (32-byte aligned)    │                   │  │
│  │  └──────────────────────┘ └──────────────────────┘                   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Chunk Arena Allocator

Used for string storage and temporary allocations:

```zig
pub const ChunkArena = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList([]u8),
    current_offset: usize,
    
    pub fn init(alloc: std.mem.Allocator) !ChunkArena
    pub fn deinit(self: *ChunkArena) void
    pub fn dupeStr(self: *ChunkArena, str: []const u8) []const u8
    pub fn alloc(self: *ChunkArena, size: usize) ![]u8
};
```

### String Duplication

```zig
/// Duplicate a string into the arena (no free needed)
pub fn dupeStr(self: *ChunkArena, str: []const u8) []const u8 {
    const dest = self.alloc(str.len + 1) catch return "";
    @memcpy(dest[0..str.len], str);
    dest[str.len] = 0;
    return dest[0..str.len];
}
```

### Chunk-Based Allocation

```zig
const CHUNK_SIZE = 64 * 1024;  // 64KB chunks

pub fn alloc(self: *ChunkArena, size: usize) ![]u8 {
    // Check if current chunk has enough space
    if (self.current_offset + size <= self.chunks.items[self.chunks.items.len - 1].len) {
        const offset = self.current_offset;
        self.current_offset += size;
        return self.chunks.items[self.chunks.items.len - 1][offset..offset + size];
    }
    
    // Allocate new chunk (minimum 64KB or requested size)
    const new_size = @max(CHUNK_SIZE, size);
    const new_chunk = try self.allocator.alloc(u8, new_size);
    try self.chunks.append(new_chunk);
    self.current_offset = size;
    return new_chunk[0..size];
}
```

## VM Memory

```zig
pub const VM = struct {
    stack: [256]Value,           // Inline stack (no allocation)
    sp: u8,
    variables: []Value,          // Allocated array
    stack_f64: [256]f64,         // Inline stack (no allocation)
    variables_f64: []f64,        // Allocated array
    variables_tags: []ValueTag,  // Allocated array
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, max_variables: usize) !VM {
        const vars = try allocator.alloc(Value, max_variables);
        @memset(vars, Value.initNumber(0));
        
        const vars_f64 = try allocator.alloc(f64, max_variables);
        @memset(vars_f64, 0);
        
        const vars_tags = try allocator.alloc(ValueTag, max_variables);
        @memset(vars_tags, .number);
        
        return .{
            .stack = undefined,
            .sp = 0,
            .variables = vars,
            .stack_f64 = undefined,
            .variables_f64 = vars_f64,
            .variables_tags = vars_tags,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *VM) void {
        self.allocator.free(self.variables);
        self.allocator.free(self.variables_f64);
        self.allocator.free(self.variables_tags);
    }
};
```

## Compiled Expression Memory

```zig
pub const CompiledExpr = struct {
    code: []Instruction,
    constants: []Value,
    constants_f64: []f64,
    max_stack: u16,
    is_number_only: bool,
    owns_memory: bool = true,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *CompiledExpr) void {
        if (self.owns_memory) {
            self.allocator.free(self.code);
            self.allocator.free(self.constants);
            if (self.constants_f64.len > 0) {
                self.allocator.free(self.constants_f64);
            }
        }
    }
};
```

## FFI Memory Management

### Aligned Memory Allocation

```zig
/// Allocate aligned memory for SIMD operations
export fn mathzig_alloc_aligned(alignment: usize, size: usize) ?[*]u8 {
    // Page allocator provides 4096-byte alignment (sufficient for AVX)
    _ = alignment;
    const slice = std.heap.page_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}
```

### TypeScript Aligned Buffers

```typescript
import { ptr, toArrayBuffer } from 'bun:ffi';

const BATCH_SIZE = 10_000_000;

// Allocate 32-byte aligned buffers for AVX-256
const inputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);  // 80 MB
const outputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8); // 80 MB

// Create typed views on aligned memory
const inputs = new Float64Array(toArrayBuffer(inputsPtr, 0, BATCH_SIZE * 8));
const outputs = new Float64Array(toArrayBuffer(outputsPtr, 0, BATCH_SIZE * 8));

// Buffers are now ready for SIMD batch operations
```

## WASM Memory

For WebAssembly targets, memory is managed through exported malloc/free:

```zig
/// WASM malloc - allocates from linear memory
export fn wasm_malloc(size: usize) ?[*]u8 {
    const slice = std.heap.page_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

/// WASM free - releases allocated memory
export fn wasm_free(ptr: ?[*]u8, size: usize) void {
    if (ptr == null) return;
    const p = ptr.?;
    const slice = p[0..size];
    std.heap.page_allocator.free(slice);
}
```

## String Handling

```zig
/// String handle for FFI
pub const StringHandle = struct {
    ptr: [*]const u8,
    len: u32,
    
    pub fn fromSlice(slice: []const u8) StringHandle {
        return .{ .ptr = slice.ptr, .len = @intCast(slice.len) };
    }
    
    pub fn toSlice(self: StringHandle) []const u8 {
        return self.ptr[0..self.len];
    }
};
```

## TypeScript String Management

```typescript
// Store allocated buffers to prevent garbage collection
const allocatedBuffers: Map<ptr, Uint8Array> = new Map();

function stringToPtr(str: string): ptr {
    const buffer = Buffer.from(str + '\0');
    const memory = buffer;
    const p = ptr(memory);
    allocatedBuffers.set(p, memory);
    return p;
}

function freePtr(p: ptr): void {
    const memory = allocatedBuffers.get(p);
    if (memory) {
        allocatedBuffers.delete(p);
        // Memory freed when buffer is garbage collected
    }
}
```

## Compiler Cache

For repeated compilations, a cache can reduce allocation overhead:

```zig
pub const CompilerCache = struct {
    buffer: []u8,
    next_offset: usize,
    
    pub fn init() CompilerCache {
        return .{
            .buffer = &.{},
            .next_offset = 0,
        };
    }
    
    pub fn reset(self: *CompilerCache) void {
        self.next_offset = 0;
    }
    
    pub fn getAllocator(self: *CompilerCache) std.mem.Allocator {
        // Return wrapper that uses cache buffer
    }
};
```

## Memory Best Practices

### 1. Use Indexed Variables

```typescript
// Avoid: String-based variable access (slow)
ctx.setVariable("x", 5);

// Prefer: Indexed access (fast, no string allocation)
const xIdx = ctx.addVariableIndexed("x");
ctx.setByIndex(xIdx, 5);
```

### 2. Reuse Compiled Expressions

```typescript
// Avoid: Re-compiling same expression
for (let i = 0; i < 1000; i++) {
    const result = ctx.eval("x * x + 1");  // Compile each time
}

// Prefer: Compile once, evaluate many times
const compiled = ctx.compile("x * x + 1");
for (let i = 0; i < 1000; i++) {
    ctx.setByIndex(xIdx, i);
    const result = compiled.evaluateFast();
}
```

### 3. Use SIMD Batch for Bulk Operations

```typescript
// Avoid: Loop with individual evaluations
for (let i = 0; i < BATCH_SIZE; i++) {
    ctx.setByIndex(xIdx, i);
    results[i] = compiled.evaluateFast();
}

// Prefer: SIMD batch evaluation (4 values per iteration)
compiled.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);
```

### 4. Aligned Memory for SIMD

```typescript
// Always use 32-byte alignment for AVX-256
const inputsPtr = MathZig.allocAligned(32, size * 8);
const outputsPtr = MathZig.allocAligned(32, size * 8);
```

## Memory Layout Summary

| Component | Allocation | Lifetime | Notes |
|-----------|------------|----------|-------|
| MathZig context | Heap (page) | Until destroy() | Owns all sub-allocations |
| CompiledExpr.code | Heap | Until freeExpr() | Bytecode instructions |
| CompiledExpr.constants | Heap | Until freeExpr() | Value constants |
| VM.variables | Heap | Until VM deinit() | Variable storage |
| ChunkArena | Heap chunks | Until context deinit() | String storage |
| FFI input/output | Heap (page) | Manual free | 32-byte aligned |

## Related Documentation

- [Overview](overview.md)
- [FFI Layer](ffi.md)
- [Virtual Machine](vm.md)
- [Performance Optimizations](optimization.md)
