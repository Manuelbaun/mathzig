# AOT Compilation for MathZig DSL

## Vision

Transform MathZig expressions into standalone, AOT-compiled modules that can be:
1. Deployed and executed on **wasmCloud** or other WASM runtimes
2. Compiled to **native code** for maximum performance
3. Called from any language with minimal FFI overhead

The goal: User defines math expressions in MathZig DSL → AOT compile to WASM/native → execute at near-native speed anywhere.

---

## Current Architecture (JIT-ish Bytecode)

```
┌─────────────────────────────────────────────────────────────────┐
│                    Current MathZig Pipeline                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  DSL Source   →   Tokenizer   →   Compiler   →   Bytecode       │
│  "x * 2 + 1"      (tokens)        (AST)         [instructions]  │
│                                                                  │
│                                       ↓                          │
│                                                                  │
│                              VM Interpreter                      │
│                              (stack-based)                       │
│                                       ↓                          │
│                                                                  │
│                                   Result                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

Current bytecode ops: `push_const`, `load_var`, `store_var`, `add`, `sub`, `mul`, `div`, `pow`, `call_builtin`, etc.

---

## Proposed AOT Architecture

### Option A: WASM Module Generation

```
┌─────────────────────────────────────────────────────────────────┐
│                    AOT WASM Pipeline                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  DSL Source   →   Compiler   →   WASM Codegen   →   .wasm file  │
│  "x * 2 + 1"      (AST)          (binary)           (standalone) │
│                                                                  │
│                                       ↓                          │
│                                                                  │
│                         Deploy to wasmCloud                      │
│                         Browser / Node.js                        │
│                         Embedded systems                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Option B: Native Code Generation (via LLVM or Zig)

```
┌─────────────────────────────────────────────────────────────────┐
│                    AOT Native Pipeline                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  DSL Source   →   Compiler   →   Zig/LLVM IR   →   .so/.dylib  │
│  "x * 2 + 1"      (AST)          (codegen)          (native)    │
│                                                                  │
│                                       ↓                          │
│                                                                  │
│                         Direct FFI call from                     │
│                         C, Rust, Go, Python, etc.               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## WASM AOT Compilation

### Why WASM?

1. **Universal deployment**: Runs in browsers, servers (wasmCloud, Fastly, Cloudflare Workers), embedded
2. **Sandboxed execution**: Memory-safe, capabilities-based security
3. **Near-native performance**: 0.5x-1.0x native speed for compute-bound code
4. **No recompilation**: Single binary runs anywhere WASM is supported
5. **Component model**: WASM components can be composed and orchestrated

### WASM Codegen Approaches

#### Approach 1: Generate WAT (WebAssembly Text) and Compile

```zig
// Generate WAT from AST, then use wasm-tools/wat2wasm
fn generateWat(ast: *const Node, writer: anytype) !void {
    try writer.print(
        \\(module
        \\  (func (export "compute") (param $x f64) (result f64)
        \\
    , .{});

    try generateWatExpr(ast, writer);

    try writer.print(
        \\  )
        \\)
    , .{});
}

fn generateWatExpr(node: *const Node, writer: anytype) !void {
    switch (node.type) {
        .number => try writer.print("    f64.const {d}\n", .{node.data.number}),
        .variable => try writer.print("    local.get ${s}\n", .{node.data.variable}),
        .binary_op => {
            try generateWatExpr(node.data.binary_op.lhs, writer);
            try generateWatExpr(node.data.binary_op.rhs, writer);
            const op = switch (node.data.binary_op.op) {
                .add => "f64.add",
                .sub => "f64.sub",
                .mul => "f64.mul",
                .div => "f64.div",
                else => unreachable,
            };
            try writer.print("    {s}\n", .{op});
        },
        // ...
    }
}
```

**Example output for `x * 2 + 1`:**

```wat
(module
  (func (export "compute") (param $x f64) (result f64)
    local.get $x
    f64.const 2.0
    f64.mul
    f64.const 1.0
    f64.add
  )
)
```

#### Approach 2: Direct WASM Binary Generation

Generate WASM binary directly without the text intermediate:

```zig
const WasmBinaryBuilder = struct {
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) WasmBinaryBuilder {
        var b = WasmBinaryBuilder{
            .buffer = std.ArrayList(u8).init(allocator),
        };
        // WASM magic + version
        b.buffer.appendSlice(&[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
        return b;
    }

    pub fn emitF64Const(self: *@This(), value: f64) !void {
        try self.buffer.append(0x44); // f64.const
        try self.buffer.appendSlice(std.mem.asBytes(&value));
    }

    pub fn emitF64Add(self: *@This()) !void {
        try self.buffer.append(0xa0); // f64.add
    }

    pub fn emitF64Mul(self: *@This()) !void {
        try self.buffer.append(0xa2); // f64.mul
    }

    pub fn emitLocalGet(self: *@This(), index: u32) !void {
        try self.buffer.append(0x20); // local.get
        try self.emitLeb128(index);
    }

    // ...
};
```

#### Approach 3: Use Binaryen or wasm-tools

Leverage existing tools for optimization and binary generation:

```zig
// Shell out to wasm-tools or link against Binaryen C API
const result = try std.process.Child.run(.{
    .allocator = allocator,
    .argv = &[_][]const u8{ "wat2wasm", "expr.wat", "-o", "expr.wasm" },
});
```

### Handling Builtin Functions in WASM

For functions like `sin`, `cos`, `exp`, etc., we have options:

1. **Import from host**: WASM imports math functions from the runtime
   ```wat
   (import "env" "sin" (func $sin (param f64) (result f64)))
   ```

2. **Inline implementations**: Include pure-WASM implementations
   ```wat
   ;; Taylor series for sin(x)
   (func $sin (param $x f64) (result f64)
     ;; ... polynomial approximation
   )
   ```

3. **WASI preview2**: Use standardized math imports when available

### WASM Module Interface

```wat
(module
  ;; Imports (runtime-provided)
  (import "math" "sin" (func $sin (param f64) (result f64)))
  (import "math" "cos" (func $cos (param f64) (result f64)))
  (import "math" "exp" (func $exp (param f64) (result f64)))
  (import "math" "log" (func $log (param f64) (result f64)))

  ;; Memory for arrays/matrices (optional)
  (memory (export "memory") 1)

  ;; Main compute function
  (func (export "compute")
    (param $x f64)
    (param $y f64)
    (result f64)
    ;; Generated code here
  )

  ;; Batch processing (SIMD)
  (func (export "compute_batch")
    (param $inputs i32)   ;; ptr to f64 array
    (param $outputs i32)  ;; ptr to f64 array
    (param $count i32)
    ;; Vectorized loop
  )
)
```

### wasmCloud Integration

For wasmCloud deployment, we'd generate a **WASM Component**:

```toml
# wadm.yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: mathzig-compute
spec:
  components:
    - name: compute
      type: component
      properties:
        image: file://./mathzig_expr.wasm
      traits:
        - type: spreadscaler
          properties:
            instances: 10
```

The component would expose interfaces:

```wit
// mathzig.wit
package mathzig:compute@0.1.0;

interface compute {
    record input {
        x: f64,
        y: f64,
        // ... other variables
    }

    compute: func(input: input) -> f64;
    compute-batch: func(inputs: list<input>) -> list<f64>;
}

world mathzig-world {
    export compute;
}
```

---

## Native AOT Compilation

### Why Native?

1. **Maximum performance**: Full CPU optimization (AVX-512, FMA, etc.)
2. **Zero startup**: No JIT warmup or WASM instantiation
3. **Direct memory access**: No WASM linear memory indirection
4. **System integration**: Direct OS calls, threading, SIMD

### Obstacles for Native Compilation

#### 1. Code Generation Complexity

**Problem**: Generating machine code is hard. We'd need:
- Instruction encoding for x86-64, ARM64, etc.
- Register allocation
- Calling conventions (System V, Windows, etc.)
- Platform-specific ABI handling

**Solutions**:

a) **Use Zig as backend** (recommended):
```zig
// Generate Zig source code, then compile it
fn generateZigSource(ast: *const Node, writer: anytype) !void {
    try writer.print(
        \\const std = @import("std");
        \\
        \\export fn compute(x: f64) f64 {{
        \\    return
    , .{});
    try generateZigExpr(ast, writer);
    try writer.print(";\n}}\n", .{});
}
```

b) **LLVM backend**:
```zig
// Generate LLVM IR
// (requires linking LLVM C API)
const module = LLVMModuleCreateWithName("mathzig_expr");
const func_type = LLVMFunctionType(LLVMDoubleType(), &[_]LLVMTypeRef{LLVMDoubleType()}, 1, false);
const func = LLVMAddFunction(module, "compute", func_type);
// ... emit LLVM IR instructions
```

c) **Cranelift** (Rust JIT compiler, has C API)

d) **QBE** (simple, small compiler backend)

#### 2. Runtime Dependencies

**Problem**: Builtin functions (`sin`, `cos`, matrix ops) need implementations.

**Solutions**:

a) **Static linking**: Compile mathzig's math functions into the output
```zig
// Generated native code includes:
extern fn mathzig_sin(x: f64) f64;
extern fn mathzig_exp(x: f64) f64;
// Linked from libmathzig.a
```

b) **System libm**: Link against platform's math library
```zig
const c = @cImport(@cInclude("math.h"));
// c.sin(x), c.cos(x), etc.
```

c) **Standalone implementations**: Generate inline math (like WASM approach)

#### 3. Platform-Specific Code

**Problem**: Different platforms need different code paths.

**Solution**: Multi-target compilation matrix

```zig
const targets = [_]Target{
    .{ .arch = .x86_64, .os = .linux, .abi = .gnu },
    .{ .arch = .x86_64, .os = .macos, .abi = .none },
    .{ .arch = .aarch64, .os = .linux, .abi = .gnu },
    .{ .arch = .aarch64, .os = .macos, .abi = .none },
    .{ .arch = .wasm32, .os = .wasi, .abi = .none },
};
```

#### 4. Dynamic vs Static Compilation

**Options**:

| Approach | Pros | Cons |
|----------|------|------|
| **JIT (current)** | Fast iteration, no build step | Interpreter overhead |
| **AOT to .so/.dylib** | Fast execution, standard FFI | Requires compilation step |
| **AOT to .a (static)** | No runtime deps, single binary | Larger binaries |
| **Embedded Zig** | Full optimization, SIMD | Requires Zig toolchain |

### Recommended Native Approach: Zig Code Generation

Since MathZig is already written in Zig, the simplest native AOT is:

1. **Generate Zig source** from DSL
2. **Compile with `zig build`** for target platform
3. **Output shared library** with C ABI

```zig
// aot_codegen.zig
pub fn compileToNative(
    source: []const u8,
    output_path: []const u8,
    target: std.Target,
) !void {
    // 1. Parse DSL
    var compiler = Compiler.init(allocator, source);
    const ast = try compiler.parse();

    // 2. Generate Zig source
    var zig_source = std.ArrayList(u8).init(allocator);
    try generateZigSource(ast, zig_source.writer());

    // 3. Write to temp file
    const temp_zig = try std.fs.createFileAbsolute("/tmp/mathzig_gen.zig");
    try temp_zig.writeAll(zig_source.items);

    // 4. Invoke Zig compiler
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "zig", "build-lib",
            "-target", target.serialize(),
            "-O", "ReleaseFast",
            "-femit-bin=" ++ output_path,
            "/tmp/mathzig_gen.zig",
        },
    });
}
```

**Generated Zig example for `sin(x) * 2 + cos(y)`:**

```zig
const std = @import("std");
const math = std.math;

export fn compute(x: f64, y: f64) callconv(.C) f64 {
    return math.sin(x) * 2.0 + math.cos(y);
}

// Optional: batch processing with SIMD
export fn compute_batch(
    xs: [*]const f64,
    ys: [*]const f64,
    results: [*]f64,
    count: usize,
) callconv(.C) void {
    const Vec = @Vector(4, f64);
    var i: usize = 0;
    while (i + 4 <= count) : (i += 4) {
        const x_vec: Vec = xs[i..][0..4].*;
        const y_vec: Vec = ys[i..][0..4].*;
        // Note: std.math.sin doesn't vectorize, need custom impl
        results[i..][0..4].* = x_vec * @as(Vec, @splat(2.0)) + y_vec;
    }
    // Scalar remainder
    while (i < count) : (i += 1) {
        results[i] = math.sin(xs[i]) * 2.0 + math.cos(ys[i]);
    }
}
```

---

## Variable Invocation Strategies

### Strategy 1: Function Parameters

Each variable becomes a function parameter:

```zig
// DSL: "a * x^2 + b * x + c"
export fn compute(x: f64, a: f64, b: f64, c: f64) f64 {
    return a * x * x + b * x + c;
}
```

**Pros**: Simple, no state, pure function
**Cons**: Many parameters can be unwieldy

### Strategy 2: Struct Input

Variables bundled into a struct:

```zig
pub const Input = extern struct {
    x: f64,
    a: f64,
    b: f64,
    c: f64,
};

export fn compute(input: *const Input) f64 {
    return input.a * input.x * input.x + input.b * input.x + input.c;
}
```

**Pros**: Clean API, easy to extend
**Cons**: Pointer indirection

### Strategy 3: Global State (WASM linear memory)

```wat
(module
  (memory (export "memory") 1)

  ;; Variables stored at known offsets
  ;; x at offset 0, a at offset 8, b at offset 16, c at offset 24

  (func (export "compute") (result f64)
    (f64.load (i32.const 0))   ;; x
    (f64.load (i32.const 0))   ;; x
    f64.mul                     ;; x^2
    (f64.load (i32.const 8))   ;; a
    f64.mul                     ;; a*x^2
    ;; ... etc
  )

  (func (export "set_x") (param $val f64)
    (f64.store (i32.const 0) (local.get $val))
  )
)
```

**Pros**: Fast for repeated calls with some variables constant
**Cons**: Not pure, harder to reason about

### Strategy 4: Hybrid (Constants vs Variables)

Separate compile-time constants from runtime variables:

```zig
// At compile time, user specifies:
// - constants: {a: 1.5, b: 2.0, c: 0.5}
// - variables: [x]

// Generated code inlines constants:
export fn compute(x: f64) f64 {
    return 1.5 * x * x + 2.0 * x + 0.5;
}
```

**Pros**: Maximum optimization (constant folding, etc.)
**Cons**: Need recompilation to change constants

---

## Complete Example: End-to-End AOT Flow

### 1. User Defines Expression

```typescript
// mathzig-aot.ts
import { MathZigAOT } from 'mathzig';

const compiler = new MathZigAOT();

// Define the expression
const expr = compiler.define(`
    # Quadratic formula
    x = (-b + sqrt(b^2 - 4*a*c)) / (2*a)
`);

// Declare variable types
expr.variables({
    a: 'f64',
    b: 'f64',
    c: 'f64',
});

// Compile to WASM
const wasmBytes = await expr.compileToWasm();
fs.writeFileSync('quadratic.wasm', wasmBytes);

// Or compile to native
await expr.compileToNative({
    target: 'x86_64-linux',
    output: 'libquadratic.so',
});
```

### 2. Generated WASM

```wat
(module
  (import "math" "sqrt" (func $sqrt (param f64) (result f64)))

  (func (export "compute") (param $a f64) (param $b f64) (param $c f64) (result f64)
    ;; -b
    local.get $b
    f64.neg

    ;; sqrt(b^2 - 4*a*c)
    local.get $b
    local.get $b
    f64.mul           ;; b^2
    f64.const 4.0
    local.get $a
    f64.mul
    local.get $c
    f64.mul           ;; 4*a*c
    f64.sub           ;; b^2 - 4*a*c
    call $sqrt

    ;; -b + sqrt(...)
    f64.add

    ;; 2*a
    f64.const 2.0
    local.get $a
    f64.mul

    ;; divide
    f64.div
  )
)
```

### 3. Deploy to wasmCloud

```bash
# Build component
wash build

# Deploy
wash app deploy wadm.yaml
```

### 4. Call from Any Language

**Rust:**
```rust
let module = Module::from_file(&engine, "quadratic.wasm")?;
let instance = Instance::new(&mut store, &module, &imports)?;
let compute = instance.get_typed_func::<(f64, f64, f64), f64>(&mut store, "compute")?;
let result = compute.call(&mut store, (1.0, -5.0, 6.0))?; // x = 2 or 3
```

**Python:**
```python
import wasmtime

store = wasmtime.Store()
module = wasmtime.Module.from_file(store.engine, "quadratic.wasm")
instance = wasmtime.Instance(store, module, [])
compute = instance.exports(store)["compute"]
result = compute(store, 1.0, -5.0, 6.0)  # x = 2 or 3
```

**JavaScript:**
```javascript
const { instance } = await WebAssembly.instantiateStreaming(
    fetch('quadratic.wasm'),
    { math: { sqrt: Math.sqrt } }
);
const result = instance.exports.compute(1.0, -5.0, 6.0);
```

---

## Comparison: Native vs WASM AOT

| Aspect | WASM AOT | Native AOT |
|--------|----------|------------|
| **Portability** | Universal | Platform-specific |
| **Performance** | ~0.8x native | 1.0x (baseline) |
| **SIMD** | SIMD128 (2-wide) | AVX-512 (8-wide) |
| **Startup** | ~1ms instantiation | Near-zero |
| **Security** | Sandboxed | Full access |
| **Distribution** | Single .wasm | Per-platform binaries |
| **Cloud deployment** | wasmCloud, Fastly, CF | Docker, bare metal |
| **FFI complexity** | WASM interface types | C ABI |
| **Debugging** | DWARF in WASM | Native debuggers |

---

## Implementation Roadmap

### Phase 1: WASM AOT (MVP)

1. [ ] WAT code generator from AST
2. [ ] Basic math ops: `+`, `-`, `*`, `/`, `^`
3. [ ] Math function imports: `sin`, `cos`, `exp`, `log`, `sqrt`
4. [ ] Single-value output functions
5. [ ] wat2wasm integration (shell out)

### Phase 2: WASM Optimization

1. [ ] Direct WASM binary generation (no wat2wasm dep)
2. [ ] SIMD128 batch processing
3. [ ] Memory layout for arrays/matrices
4. [ ] Constant folding in codegen
5. [ ] Dead code elimination

### Phase 3: Native AOT

1. [ ] Zig source code generation
2. [ ] Build integration (zig build invocation)
3. [ ] Multi-target support (x86-64, ARM64, WASM)
4. [ ] SIMD code generation (AVX, NEON)
5. [ ] Shared library output with C headers

### Phase 4: Advanced Features

1. [ ] WASM Component Model support
2. [ ] WIT interface generation
3. [ ] wasmCloud capability providers
4. [ ] Matrix operations in compiled code
5. [ ] Time series support (batch processing)
6. [ ] Unit-aware computation (compile-time dimension checking)

---

## Open Questions

1. **How to handle dynamic matrix sizes?** Fixed at compile time vs runtime allocation
2. **Error handling?** Traps, return codes, or error values
3. **Debugging?** Source maps from DSL to WASM/native
4. **Versioning?** ABI stability for compiled modules
5. **Caching?** Hash-based caching of compiled modules
6. **Security?** Sandboxing for untrusted expressions

---

## References

- [WebAssembly Specification](https://webassembly.github.io/spec/)
- [WASM Component Model](https://component-model.bytecodealliance.org/)
- [wasmCloud Documentation](https://wasmcloud.com/docs/)
- [Zig Cross-Compilation](https://ziglang.org/documentation/master/#Cross-Compilation)
- [LLVM Kaleidoscope Tutorial](https://llvm.org/docs/tutorial/)
- [Cranelift](https://cranelift.dev/)
