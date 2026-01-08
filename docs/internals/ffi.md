# FFI Layer and TypeScript Bindings

MathZig provides a C ABI for FFI access from TypeScript via Bun, and exports WebAssembly functions for web applications.

## C ABI Export Layer

The `exports.zig` file provides C-compatible functions for FFI integration.

### Context Management

```zig
/// Create a new MathZig context
export fn mathzig_create() ?*MathZig {
    return MathZig.init(std.heap.page_allocator) catch null;
}

/// Destroy a MathZig context
export fn mathzig_destroy(ctx: ?*MathZig) void {
    if (ctx) |c| {
        c.deinit();
    }
}
```

### Expression Compilation

```zig
/// Compile an expression string
export fn mathzig_compile(ctx: ?*MathZig, expr: [*:0]const u8) ?*CompiledExpr {
    const c = ctx orelse return null;
    const slice = std.mem.span(expr);
    return c.compile(slice) catch null;
}

/// Free a compiled expression
export fn mathzig_free_expr(ctx: ?*MathZig, expr: ?*CompiledExpr) void {
    const c = ctx orelse return;
    if (expr) |e| {
        c.freeExpr(e);
    }
}
```

### Evaluation Functions

```zig
/// Evaluate a compiled expression
export fn mathzig_evaluate(ctx: ?*MathZig, expr: ?*const CompiledExpr) f64 {
    const c = ctx orelse return std.math.nan(f64);
    const e = expr orelse return std.math.nan(f64);
    
    const result = c.evaluate(e) catch return std.math.nan(f64);
    return result.toNumber() orelse std.math.nan(f64);
}

/// FAST PATH: Zero-overhead evaluation
export fn mathzig_evaluate_fast(ctx: *MathZig, expr: *const CompiledExpr) f64 {
    return ctx.vm.executeNumbersOnlyUnchecked(expr);
}

/// Evaluate expression string directly
export fn mathzig_eval(ctx: ?*MathZig, expr: [*:0]const u8) f64 {
    const c = ctx orelse return std.math.nan(f64);
    const slice = std.mem.span(expr);
    
    const result = c.eval(slice) catch return std.math.nan(f64);
    return result.toNumber() orelse std.math.nan(f64);
}
```

### Variable Management

```zig
/// Set a numeric variable by name
export fn mathzig_set_variable(ctx: ?*MathZig, name: [*:0]const u8, value: f64) bool {
    const c = ctx orelse return false;
    const slice = std.mem.span(name);
    c.setNumber(slice, value);
    return true;
}

/// Add a variable and return its index
export fn mathzig_add_variable_indexed(ctx: ?*MathZig, name: [*:0]const u8, value: f64) i32 {
    const c = ctx orelse return -1;
    const slice = std.mem.span(name);
    return @intCast(c.addVariableIndexed(slice, value));
}

/// Set variable by index (fast path)
export fn mathzig_set_by_index(ctx: ?*MathZig, index: i32, value: f64) void {
    const c = ctx orelse return;
    if (index < 0) return;
    c.setVariableByIndexF64(@intCast(index), value);
}

/// FAST PATH: Zero-overhead variable set
export fn mathzig_set_by_index_fast(ctx: *MathZig, index: u8, value: f64) void {
    ctx.vm.variables_f64[index] = value;
}

/// Get direct pointer to f64 variable storage
export fn mathzig_get_variables_ptr(ctx: ?*MathZig) ?[*]f64 {
    const c = ctx orelse return null;
    return c.vm.variables_f64.ptr;
}
```

### Batch Evaluation

```zig
/// Scalar batch evaluation
export fn mathzig_evaluate_batch(
    ctx: ?*MathZig,
    expr: ?*const CompiledExpr,
    var_index: i32,
    inputs: [*]const f64,
    outputs: [*]f64,
    count: i32,
) i32 {
    const c = ctx orelse return 0;
    const e = expr orelse return 0;
    if (var_index < 0 or count <= 0) return 0;
    
    const n: usize = @intCast(count);
    const idx: u24 = @intCast(var_index);
    
    if (e.is_number_only) {
        for (0..n) |i| {
            c.setVariableByIndexF64(idx, inputs[i]);
            outputs[i] = c.evaluateF64(e);
        }
        return count;
    }
    
    // Fallback for non-number expressions
    var successful: i32 = 0;
    for (0..n) |i| {
        c.setVariableByIndex(idx, Value.initNumber(inputs[i]));
        const result = c.evaluate(e) catch {
            outputs[i] = std.math.nan(f64);
            continue;
        };
        outputs[i] = result.toNumber() orelse std.math.nan(f64);
        successful += 1;
    }
    
    return successful;
}

/// SIMD batch evaluation (4 values at a time)
export fn mathzig_batch_eval_simd(
    ctx: *MathZig,
    expr: *const CompiledExpr,
    var_index: u8,
    inputs: [*]const f64,
    outputs: [*]f64,
    count: u32,
) void {
    ctx.vm.executeBatchSIMD(expr, var_index, inputs, outputs, count);
}

/// Parallel batch evaluation
export fn mathzig_batch_eval_parallel(
    ctx: *MathZig,
    expr: *const CompiledExpr,
    var_index: u8,
    inputs: [*]const f64,
    outputs: [*]f64,
    count: u32,
) void {
    ctx.vm.executeBatchSIMD(expr, var_index, inputs, outputs, count);
}
```

### Polynomial Compilation

```zig
/// Compile a polynomial using Horner's method
export fn mathzig_compile_polynomial(
    ctx: ?*MathZig,
    var_index: i32,
    coefficients: [*]const f64,
    count: u32,
) ?*CompiledExpr {
    const c = ctx orelse return null;
    if (var_index < 0 or count == 0 or count > 255) return null;
    
    // Build bytecode for polynomial evaluation
    const Instruction = mathzig.Instruction;
    const Opcode = mathzig.Opcode;
    
    const expr = c.allocator.create(CompiledExpr) catch return null;
    const code = c.allocator.alloc(Instruction, 2) catch {
        c.allocator.destroy(expr);
        return null;
    };
    
    // Encode: var_idx | coeff_start | coeff_count
    const operand: u24 = @as(u24, @intCast(var_index)) |
        (@as(u24, 0) << 8) |
        (@as(u24, @intCast(count)) << 16);
    
    code[0] = Instruction.initWithOperand(Opcode.eval_poly, operand);
    code[1] = Instruction.init(Opcode.halt);
    
    expr.* = .{
        .code = code,
        .constants = undefined,  // Will be populated
        .constants_f64 = undefined,
        .max_stack = 1,
        .is_number_only = true,
        .allocator = c.allocator,
    };
    
    return expr;
}
```

### Memory Management

```zig
/// Allocate aligned memory for SIMD
export fn mathzig_alloc_aligned(alignment: usize, size: usize) ?[*]u8 {
    _ = alignment;  // Page allocator is already aligned
    const slice = std.heap.page_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

/// WASM malloc
export fn wasm_malloc(size: usize) ?[*]u8 {
    const slice = std.heap.page_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

/// WASM free
export fn wasm_free(ptr: ?[*]u8, size: usize) void {
    if (ptr == null) return;
    const p = ptr.?;
    const slice = p[0..size];
    std.heap.page_allocator.free(slice);
}
```

## TypeScript Bindings

The `mathzig.ts` file provides TypeScript classes for easy access.

### MathZig Class

```typescript
export class MathZig {
    private ctx: ptr;
    private ownedExprs: Set<ptr> = new Set();
    
    private constructor(ctx: ptr) {
        this.ctx = ctx;
    }
    
    static create(): MathZig {
        const lib = getLib();
        const ctx = lib.symbols.mathzig_create();
        if (!ctx) {
            throw new Error('Failed to create MathZig context');
        }
        return new MathZig(ctx);
    }
    
    eval(expr: string): number {
        const lib = getLib();
        const exprPtr = stringToPtr(expr);
        try {
            return lib.symbols.mathzig_eval(this.ctx, exprPtr);
        } finally {
            freePtr(exprPtr);
        }
    }
    
    compile(expr: string): CompiledExpr {
        const lib = getLib();
        const exprPtr = stringToPtr(expr);
        try {
            const compiled = lib.symbols.mathzig_compile(this.ctx, exprPtr);
            if (!compiled) {
                throw new Error(`Failed to compile expression: ${expr}`);
            }
            this.ownedExprs.add(compiled);
            return new CompiledExpr(this, compiled);
        } finally {
            freePtr(exprPtr);
        }
    }
    
    addVariableIndexed(name: string, value: number = 0): number {
        const lib = getLib();
        const namePtr = stringToPtr(name);
        try {
            return lib.symbols.mathzig_add_variable_indexed(this.ctx, namePtr, value);
        } finally {
            freePtr(namePtr);
        }
    }
    
    setByIndex(index: number, value: number): void {
        const lib = getLib();
        lib.symbols.mathzig_set_by_index(this.ctx, index, value);
    }
    
    getVariablesPtr(): ptr {
        const lib = getLib();
        return lib.symbols.mathzig_get_variables_ptr(this.ctx);
    }
    
    static allocAligned(alignment: number, size: number): ptr {
        const lib = getLib();
        return lib.symbols.mathzig_alloc_aligned(BigInt(alignment), BigInt(size));
    }
    
    compilePolynomial(varIndex: number, coefficients: Float64Array): CompiledExpr {
        const lib = getLib();
        const compiled = lib.symbols.mathzig_compile_polynomial(
            this.ctx, varIndex, ptr(coefficients), coefficients.length
        );
        if (!compiled) {
            throw new Error('Failed to compile polynomial');
        }
        this.ownedExprs.add(compiled);
        return new CompiledExpr(this, compiled);
    }
    
    destroy(): void {
        const lib = getLib();
        for (const expr of this.ownedExprs) {
            lib.symbols.mathzig_free_expr(this.ctx, expr);
        }
        this.ownedExprs.clear();
        lib.symbols.mathzig_destroy(this.ctx);
    }
}
```

### CompiledExpr Class

```typescript
export class CompiledExpr {
    private owner: MathZig;
    private ptr: ptr;
    
    evaluate(): number {
        const lib = getLib();
        return lib.symbols.mathzig_evaluate(this.owner.ctx, this.ptr);
    }
    
    evaluateFast(): number {
        const lib = getLib();
        return lib.symbols.mathzig_evaluate_fast(this.owner.ctx, this.ptr);
    }
    
    evaluateBatchSIMD(varIndex: number, inputsPtr: ptr, outputsPtr: ptr, count: number): void {
        const lib = getLib();
        lib.symbols.mathzig_batch_eval_simd(
            this.owner.ctx, this.ptr, varIndex, inputsPtr, outputsPtr, count
        );
    }
    
    evaluateBatchParallel(varIndex: number, inputsPtr: ptr, outputsPtr: ptr, count: number): void {
        const lib = getLib();
        lib.symbols.mathzig_batch_eval_parallel(
            this.owner.ctx, this.ptr, varIndex, inputsPtr, outputsPtr, count
        );
    }
    
    evaluateBatch(varIndex: number, inputs: number[]): number[] {
        const lib = getLib();
        const inputsArray = new Float64Array(inputs);
        const inputsPtr = ptr(inputsArray);
        const outputsArray = new Float64Array(inputs.length);
        const outputsPtr = ptr(outputsArray);
        
        const count = lib.symbols.mathzig_evaluate_batch(
            this.owner.ctx, this.ptr, varIndex, inputsPtr, outputsPtr, inputs.length
        );
        
        const results: number[] = [];
        for (let i = 0; i < count; i++) {
            results.push(outputsArray[i]);
        }
        return results;
    }
    
    free(): void {
        if (this.ptr) {
            const lib = getLib();
            lib.symbols.mathzig_free_expr(this.owner.ctx, this.ptr);
            this.owner.ownedExprs.delete(this.ptr);
            this.ptr = 0 as any;
        }
    }
}
```

## FFI Symbol Definitions

```typescript
const sym = {
    mathzig_create: { args: [], returns: FFIType.pointer },
    mathzig_destroy: { args: [FFIType.pointer], returns: FFIType.void },
    mathzig_compile: { args: [FFIType.pointer, FFIType.pointer], returns: FFIType.pointer },
    mathzig_free_expr: { args: [FFIType.pointer, FFIType.pointer], returns: FFIType.void },
    mathzig_evaluate: { args: [FFIType.pointer, FFIType.pointer], returns: FFIType.double },
    mathzig_eval: { args: [FFIType.pointer, FFIType.pointer], returns: FFIType.double },
    mathzig_set_variable: { args: [FFIType.pointer, FFIType.pointer, FFIType.double], returns: FFIType.bool },
    mathzig_add_variable_indexed: { args: [FFIType.pointer, FFIType.pointer, FFIType.double], returns: FFIType.i32 },
    mathzig_set_by_index: { args: [FFIType.pointer, FFIType.i32, FFIType.double], returns: FFIType.void },
    mathzig_set_by_index_fast: { args: [FFIType.pointer, FFIType.u8, FFIType.double], returns: FFIType.void },
    mathzig_evaluate_batch: { args: [FFIType.pointer, FFIType.pointer, FFIType.i32, FFIType.pointer, FFIType.pointer, FFIType.i32], returns: FFIType.i32 },
    mathzig_batch_eval_simd: { args: [FFIType.pointer, FFIType.pointer, FFIType.u8, FFIType.pointer, FFIType.pointer, FFIType.u32], returns: FFIType.void },
    mathzig_batch_eval_parallel: { args: [FFIType.pointer, FFIType.pointer, FFIType.u8, FFIType.pointer, FFIType.pointer, FFIType.u32], returns: FFIType.void },
    mathzig_evaluate_fast: { args: [FFIType.pointer, FFIType.pointer], returns: FFIType.double },
    mathzig_get_variables_ptr: { args: [FFIType.pointer], returns: FFIType.pointer },
    mathzig_alloc_aligned: { args: [FFIType.u64, FFIType.u64], returns: FFIType.pointer },
    mathzig_compile_polynomial: { args: [FFIType.pointer, FFIType.i32, FFIType.pointer, FFIType.u32], returns: FFIType.pointer },
    mathzig_get_error: { args: [], returns: FFIType.pointer },
    mathzig_version: { args: [], returns: FFIType.pointer },
    mathzig_version_number: { args: [], returns: FFIType.double },
};
```

## Usage Examples

### Basic Evaluation

```typescript
import { MathZig } from './mathzig';

const ctx = MathZig.create();

// Direct evaluation
const result = ctx.eval("2 + 3 * 4");  // 14

// Compile and evaluate
const compiled = ctx.compile("x * x + 1");
ctx.setVariable("x", 5);
console.log(compiled.evaluate());  // 26

compiled.free();
ctx.destroy();
```

### Indexed Variable Access

```typescript
const ctx = MathZig.create();
const xIdx = ctx.addVariableIndexed("x", 0);
const compiled = ctx.compile("x * 0.5 + 2.0");

// Fast indexed access
ctx.setByIndex(xIdx, 10);
console.log(compiled.evaluateFast());  // 7.0

compiled.free();
ctx.destroy();
```

### SIMD Batch Evaluation

```typescript
import { ptr, toArrayBuffer } from 'bun:ffi';

const ctx = MathZig.create();
const xIdx = ctx.addVariableIndexed("x", 0);
const compiled = ctx.compile("x * x");

const BATCH_SIZE = 1000;
const inputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
const outputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);

const inputs = new Float64Array(toArrayBuffer(inputsPtr, 0, BATCH_SIZE * 8));
for (let i = 0; i < BATCH_SIZE; i++) inputs[i] = i;

// SIMD batch evaluation
compiled.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);

const outputs = new Float64Array(toArrayBuffer(outputsPtr, 0, BATCH_SIZE * 8));
console.log(outputs[0]);  // 0 (0*0)
console.log(outputs[5]);  // 25 (5*5)
console.log(outputs[10]); // 100 (10*10)

compiled.free();
ctx.destroy();
```

### Polynomial Evaluation

```typescript
const ctx = MathZig.create();
const xIdx = ctx.addVariableIndexed("x", 0);

// Polynomial: 25x^5 - 35x^4 - 15x^3 + 40x^2 - 15x + 1
const coeffs = new Float64Array([25, -35, -15, 40, -15, 1]);
const poly = ctx.compilePolynomial(xIdx, coeffs);

const BATCH_SIZE = 1000;
const inputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);
const outputsPtr = MathZig.allocAligned(32, BATCH_SIZE * 8);

// Fill inputs with scaled values
const inputs = new Float64Array(toArrayBuffer(inputsPtr, 0, BATCH_SIZE * 8));
for (let i = 0; i < BATCH_SIZE; i++) inputs[i] = i * 0.000001;

// Evaluate
poly.evaluateBatchSIMD(xIdx, inputsPtr, outputsPtr, BATCH_SIZE);

poly.free();
ctx.destroy();
```

## Related Documentation

- [Overview](overview.md)
- [Virtual Machine](vm.md)
- [Performance Optimizations](optimization.md)
- [Build System](build.md)
