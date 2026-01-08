# MathZig API Reference

> **Freshness:** may lag the code. Prefer generated bindings (`src/bindings/generated/*`, `src/ts/`) and `zig build gen-bindings` over this prose when they disagree. Live feature status: [`docs/STATUS.md`](../STATUS.md).

This document provides an API reference for the MathZig expression evaluator, including type definitions, FFI functions, and usage examples.

## Table of Contents

1. [Core Types](#core-types)
2. [Value Types](#value-types)
3. [FFI Functions](#ffi-functions)
4. [TypeScript Bindings](#typescript-bindings)
5. [Error Codes](#error-codes)

## Core Types

### CompiledExpression

The main type returned after compiling an expression. Contains all compiled bytecode and metadata.

```typescript
interface CompiledExpression {
    // Expression metadata
    id: number;
    bytecode: Uint8Array;
    bytecodeSize: number;
    stackSize: number;
    
    // Compilation info
    compilationTime: number;
    numVariables: number;
    numConstants: number;
    numInstructions: number;
    
    // Performance hints
    isSimple: boolean;
    hasSIMD: boolean;
    hasBranch: boolean;
    
    // FFI function pointers
    evaluate: (ptr: bigint, inputs: Float64Array) => number;
    evaluateBatch: (ptr: bigint, inputs: bigint, outputs: bigint, size: number) => void;
    evaluateBatchSIMD: (ptr: bigint, inputs: bigint, outputs: bigint, size: number) => void;
    evaluateBatchParallel: (ptr: bigint, inputs: bigint, outputs: bigint, size: number) => void;
    evaluateScalar: (ptr: bigint, inputs: bigint) => number;
    
    // Memory management
    free(): void;
}
```

### EvaluationContext

Context for evaluation with variable bindings.

```typescript
interface EvaluationContext {
    variables: Map<string, number>;
    functions: Map<string, Function>;
    
    setVariable(name: string, value: number): void;
    getVariable(name: string): number;
    clearVariables(): void;
    
    addFunction(name: string, fn: Function): void;
    removeFunction(name: string): void;
}
```

### CompilationResult

Result of the compilation process.

```typescript
interface CompilationResult {
    success: boolean;
    expression: CompiledExpression | null;
    error: CompilationError | null;
    warnings: string[];
    
    // Bytecode for serialization
    bytecode: Uint8Array;
    bytecodeFormat: "binary" | "json";
    
    // Statistics
    compileTime: number;
    optimizationsApplied: string[];
}
```

### CompilationError

Error details for failed compilation.

```typescript
interface CompilationError {
    code: number;
    message: string;
    position: {
        line: number;
        column: number;
        offset: number;
    };
    severity: "error" | "warning" | "hint";
    suggestion?: string;
}
```

## Value Types

### ValueKind

Enumeration of supported value types.

```typescript
enum ValueKind {
    NULL = 0,
    BOOL = 1,
    INT = 2,
    FLOAT = 3,
    VEC2 = 4,
    VEC3 = 5,
    VEC4 = 6,
    MAT2 = 7,
    MAT3 = 8,
    MAT4 = 9,
    STRING = 10,
    ARRAY = 11,
    FUNCTION = 12,
}
```

### Value

Generic value type that can hold any supported value.

```typescript
interface Value {
    kind: ValueKind;
    asNull(): null;
    asBool(): boolean;
    asInt(): bigint;
    asFloat(): number;
    asVec2(): [number, number];
    asVec3(): [number, number, number];
    asVec4(): [number, number, number, number];
    asString(): string;
    toString(): string;
    typeName(): string;
    equals(other: Value): boolean;
    clone(): Value;
}
```

### NumericValue

Type-safe numeric values.

```typescript
type NumericValue = number | bigint | boolean;

// Convert to float64
function toFloat64(value: NumericValue): number;

// Create from float64
function fromFloat64(value: number): Value;

// Create integer value
function fromInt(value: number | bigint): Value;

// Create boolean value
function fromBool(value: boolean): Value;
```

## FFI Functions

### Core Functions

#### `mathzig_version`

Get the MathZig library version.

```typescript
function mathzig_version(): string;
```

**Returns:** Version string (e.g., "0.12.0")

**Example:**
```typescript
const version = lib.symbols.mathzig_version();
console.log(`MathZig version: ${version}`);
```

#### `mathzig_create_compiler`

Create a new expression compiler instance.

```typescript
function mathzig_create_compiler(): bigint;
```

**Returns:** Pointer to compiler instance (0 on failure)

**Example:**
```typescript
const compilerPtr = lib.symbols.mathzig_create_compiler();
if (compilerPtr === 0n) {
    throw new Error("Failed to create compiler");
}
```

#### `mathzig_compile_expression`

Compile an expression string.

```typescript
function mathzig_compile_expression(
    compilerPtr: bigint,
    expression: string,
    options: number
): bigint;
```

**Parameters:**
- `compilerPtr`: Pointer to compiler instance
- `expression`: Expression string to compile
- `options`: Compilation options bitfield

**Returns:** Pointer to compiled expression (0 on error)

**Compilation Options:**
```typescript
const MATHZIG_OPT_NONE = 0;
const MATHZIG_OPT_CONST_FOLD = 1 << 0;
const MATHZIG_OPT_DEAD_CODE = 1 << 1;
const MATHZIG_OPT_SIMD = 1 << 2;
const MATHZIG_OPT_ALL = 0xFFFFFFFF;
```

**Example:**
```typescript
const exprPtr = lib.symbols.mathzig_compile_expression(
    compilerPtr,
    "x * 0.5 + 2.0",
    MATHZIG_OPT_ALL
);
```

#### `mathzig_evaluate`

Evaluate a compiled expression with single input.

```typescript
function mathzig_evaluate(
    exprPtr: bigint,
    variableId: number,
    input: number
): number;
```

**Parameters:**
- `exprPtr`: Pointer to compiled expression
- `variableId`: ID of the variable to set
- `input`: Input value for the variable

**Returns:** Result of the expression evaluation

**Example:**
```typescript
const result = lib.symbols.mathzig_evaluate(exprPtr, 0, 5.0);
console.log(`Result: ${result}`); // Output: 4.5
```

#### `mathzig_evaluate_batch`

Evaluate a compiled expression with multiple inputs.

```typescript
function mathzig_evaluate_batch(
    exprPtr: bigint,
    variableId: number,
    inputsPtr: bigint,
    outputsPtr: bigint,
    count: number
): void;
```

**Parameters:**
- `exprPtr`: Pointer to compiled expression
- `variableId`: ID of the variable to set
- `inputsPtr`: Pointer to input array (float64)
- `outputsPtr`: Pointer to output array (float64)
- `count`: Number of inputs/outputs

**Example:**
```typescript
const inputs = new Float64Array([0, 1, 2, 3, 4]);
const outputs = new Float64Array(5);

const inputsPtr = MathZig.toPointer(inputs);
const outputsPtr = MathZig.toPointer(outputs);

lib.symbols.mathzig_evaluate_batch(exprPtr, 0, inputsPtr, outputsPtr, 5);
console.log(outputs); // [2, 2.5, 3, 3.5, 4]
```

#### `mathzig_evaluate_batch_simd`

Evaluate using SIMD vectorization (4 values at a time).

```typescript
function mathzig_evaluate_batch_simd(
    exprPtr: bigint,
    variableId: number,
    inputsPtr: bigint,
    outputsPtr: bigint,
    count: number
): void;
```

**Parameters:** Same as `mathzig_evaluate_batch`

**Performance:** ~4x faster than scalar for simple expressions

**Example:** Same as batch but with SIMD optimization

#### `mathzig_evaluate_batch_parallel`

Evaluate using multi-threaded SIMD.

```typescript
function mathzig_evaluate_batch_parallel(
    exprPtr: bigint,
    variableId: number,
    inputsPtr: bigint,
    outputsPtr: bigint,
    count: number
): void;
```

**Parameters:** Same as `mathzig_evaluate_batch`

**Performance:** Linear speedup with CPU cores

**Example:** Same as batch with parallel execution

### Memory Management

#### `mathzig_free_compiler`

Free a compiler instance.

```typescript
function mathzig_free_compiler(compilerPtr: bigint): void;
```

#### `mathzig_free_expression`

Free a compiled expression.

```typescript
function mathzig_free_expression(exprPtr: bigint): void;
```

#### `mathzig_alloc_aligned`

Allocate aligned memory.

```typescript
function mathzig_alloc_aligned(alignment: number, size: number): bigint;
```

**Parameters:**
- `alignment`: Alignment in bytes (must be power of 2)
- `size`: Size in bytes

**Returns:** Pointer to allocated memory (0 on failure)

**Example:**
```typescript
const ptr = lib.symbols.mathzig_alloc_aligned(32, 1024);
```

#### `mathzig_free`

Free allocated memory.

```typescript
function mathzig_free(ptr: bigint): void;
```

### Bytecode Functions

#### `mathzig_get_bytecode`

Get the compiled bytecode.

```typescript
function mathzig_get_bytecode(
    exprPtr: bigint,
    buffer: Uint8Array
): number;
```

**Parameters:**
- `exprPtr`: Pointer to compiled expression
- `buffer`: Buffer to write bytecode to

**Returns:** Number of bytes written

**Example:**
```typescript
const buffer = new Uint8Array(4096);
const bytesWritten = lib.symbols.mathzig_get_bytecode(exprPtr, buffer);
const bytecode = buffer.slice(0, bytesWritten);
```

#### `mathzig_load_bytecode`

Load bytecode from buffer.

```typescript
function mathzig_load_bytecode(
    compilerPtr: bigint,
    bytecode: Uint8Array,
    size: number
): bigint;
```

**Parameters:**
- `compilerPtr`: Compiler instance
- `bytecode]: Bytecode buffer
- `size`: Size of bytecode

**Returns:** Compiled expression pointer

### Utility Functions

#### `mathzig_get_error`

Get the last error message.

```typescript
function mathzig_get_error(): string;
```

**Returns:** Last error message or empty string

#### `mathzig_clear_error`

Clear the error state.

```typescript
function mathzig_clear_error(): void;
```

#### `mathzig_get_stats`

Get compilation/execution statistics.

```typescript
function mathzig_get_stats(
    exprPtr: bigint,
    stats: bigint
): void;
```

**Stats structure:**
```typescript
interface MathZigStats {
    compileTime: number;
    evalCount: number;
    totalEvalTime: number;
    bytecodeSize: number;
    stackSize: number;
    numVariables: number;
    numConstants: number;
}
```

## TypeScript Bindings

### MathZig Class

Main TypeScript API for MathZig.

```typescript
class MathZig {
    // Static methods
    static load(libraryPath?: string): MathZig;
    static loadSync(libraryPath?: string): MathZig;
    static isLoaded(): boolean;
    
    // Instance methods
    createCompiler(options?: CompilerOptions): Compiler;
    compile(expression: string, options?: CompileOptions): CompilationResult;
    
    // Utility
    evaluate(expression: string, inputs: number[], options?: CompileOptions): number[];
    eval(expression: string, x: number): number;
    
    // Memory
    allocAligned(alignment: number, size: number): bigint;
    free(ptr: bigint): void;
    toPointer(array: Float64Array): bigint;
    fromPointer(ptr: bigint, size: number): Float64Array;
}
```

### Compiler Class

Expression compiler.

```typescript
class Compiler {
    readonly ptr: bigint;
    readonly isValid: boolean;
    
    compile(expression: string, options?: CompileOptions): CompiledExpression;
    compileMultiple(expressions: string[], options?: CompileOptions): CompiledExpression[];
    
    // Variables
    addVariable(name: string): number;
    getVariableId(name: string): number;
    getVariableName(id: number): string;
    getVariableCount(): number;
    
    // Constants
    addConstant(name: string, value: number): number;
    getConstant(name: string): number;
    
    // Memory
    free(): void;
}
```

### CompiledExpression Class

Compiled expression ready for evaluation.

```typescript
class CompiledExpression {
    readonly ptr: bigint;
    readonly bytecode: Uint8Array;
    readonly bytecodeSize: number;
    readonly stackSize: number;
    
    // Evaluation methods
    evaluate(x: number): number;
    evaluateArray(inputs: Float64Array): Float64Array;
    evaluateSIMD(inputs: Float64Array, outputs: Float64Array): void;
    evaluateParallel(inputs: Float64Array, outputs: Float64Array): void;
    
    // Bytecode
    serialize(): Uint8Array;
    static deserialize(compiler: Compiler, bytecode: Uint8Array): CompiledExpression;
    
    // Metadata
    getStats(): ExpressionStats;
    getVariableIds(): number[];
    getConstantValues(): number[];
    
    // Memory
    free(): void;
}
```

## Error Codes

### Compilation Errors

| Code | Name | Description |
|------|------|-------------|
| 0 | SUCCESS | No error |
| 1 | SYNTAX_ERROR | Invalid expression syntax |
| 2 | UNKNOWN_TOKEN | Unrecognized token |
| 3 | UNEXPECTED_TOKEN | Unexpected token in expression |
| 4 | UNTERMINATED_STRING | Unterminated string literal |
| 5 | INVALID_NUMBER | Invalid number format |
| 6 | DIVISION_BY_ZERO | Division by zero in constant folding |
| 7 | STACK_OVERFLOW | Expression too complex |
| 8 | UNDEFINED_VARIABLE | Reference to undefined variable |
| 9 | UNDEFINED_FUNCTION | Call to undefined function |
| 10 | WRONG_ARITY | Wrong number of arguments |
| 11 | TYPE_MISMATCH | Type mismatch in operation |
| 12 | INVALID_CONTEXT | Invalid evaluation context |

### Runtime Errors

| Code | Name | Description |
|------|------|-------------|
| 100 | NULL_POINTER | Null pointer accessed |
| 101 | INVALID_ALIGNMENT | Invalid memory alignment |
| 102 | OUT_OF_BOUNDS | Array out of bounds |
| 103 | STACK_UNDERFLOW | Stack underflow in VM |
| 104 | INVALID_OPCODE | Invalid bytecode instruction |
| 105 | INVALID_STATE | Invalid VM state |

## Examples

### Basic Evaluation

```typescript
import { MathZig } from "mathzig";

const mathzig = MathZig.loadSync();

// Simple expression
const result = mathzig.eval("x * 2 + 1", 5); // 11

// Multiple inputs
const results = mathzig.evaluate("x^2 + 1", [1, 2, 3, 4]);
// [2, 5, 10, 17]
```

### Using Compiler

```typescript
const compiler = mathzig.createCompiler();
const expr = compiler.compile("sin(x) * cos(x) + 2");

// Evaluate single value
const single = expr.evaluate(Math.PI / 4);

// Evaluate array
const inputs = new Float64Array([0, 0.5, 1, 1.5]);
const outputs = expr.evaluateSIMD(inputs, new Float64Array(4));

expr.free();
compiler.free();
```

### Custom Variables

```typescript
const compiler = mathzig.createCompiler();

// Add variables
compiler.addVariable("x");
compiler.addVariable("y");
compiler.addVariable("z");

const expr = compiler.compile("x + y * z");

// Set variable values and evaluate
const result = expr.evaluateWith({
    x: 1,
    y: 2,
    z: 3
}); // 7

// Or use the FFI directly
const xId = compiler.getVariableId("x");
const yId = compiler.getVariableId("y");
const zId = compiler.getVariableId("z");
```

### SIMD Batch Evaluation

```typescript
const expr = compiler.compile("x * 0.5 + 2.0");
const BATCH_SIZE = 1000000;

// Allocate aligned memory for SIMD
const inputsPtr = mathzig.allocAligned(32, BATCH_SIZE * 8);
const outputsPtr = mathzig.allocAligned(32, BATCH_SIZE * 8);

// Create typed array views
const inputs = mathzig.fromPointer(inputsPtr, BATCH_SIZE);
const outputs = mathzig.fromPointer(outputsPtr, BATCH_SIZE);

// Fill inputs
for (let i = 0; i < BATCH_SIZE; i++) {
    inputs[i] = i;
}

// Run SIMD evaluation
expr.evaluateSIMD(inputs, outputs);

// Clean up
inputs.free();
outputs.free();
mathzig.free(inputsPtr);
mathzig.free(outputsPtr);
```

### Serialization

```typescript
// Compile and serialize
const expr = compiler.compile("x^2 + 2x + 1");
const bytecode = expr.serialize();

// Save to file
fs.writeFileSync("expression.bin", bytecode);

// Later: deserialize
const expr2 = CompiledExpression.deserialize(compiler, bytecode);
const result = expr2.evaluate(5); // 36
```

### Error Handling

```typescript
const result = compiler.compile("x + y");

if (result.success) {
    console.log("Compiled successfully");
    result.expression!.free();
} else {
    const error = result.error!;
    console.error(`Error at line ${error.position.line}: ${error.message}`);
    if (error.suggestion) {
        console.error(`Suggestion: ${error.suggestion}`);
    }
}
```

## Built-in Functions

### Math Functions
`abs`, `sqrt`, `cbrt`, `exp`, `log` (ln), `log10`, `log2`, `floor`, `ceil`, `round`, `trunc`, `sign`, `min`, `max`, `clamp`

### Trigonometry
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`

### Time-Series (Temporal Engine)
These functions operate on `Series` objects.

| Function | Description |
|----------|-------------|
| `twa(series)` | Time-Weighted Average (integral / duration). |
| `derivative(series)` | Rate of change per second (dy/dt). |
| `integrate(series)` | Cumulative integral (trapezoidal). |
| `ema(series, half_life)` | Exponential Moving Average with time-decay. |
| `sma(series, period)` | Simple Moving Average (windowed). |
| `rsi(series, period)` | Relative Strength Index (Wilder's). |
| `series(t, v)` | Create a series from timestamp and value arrays. |

### ODE Solver
Numerical integration of Ordinary Differential Equations.

| Function | Description |
|----------|-------------|
| `ode_solve(f, y0, t_span, dt)` | Solve dy/dt = f(t, y) using 4th-order Runge-Kutta. Returns a Matrix where the first column is time and subsequent columns are state variables. |

#### Arguments:
- `f`: The derivative function name (string) or closure. Must accept `(t, y)` and return `dy/dt`.
- `y0`: Initial state. Can be a Number (scalar) or a Matrix (vector).
- `t_span`: Time range `[start, end]` as a Matrix/Vector.
- `dt`: Fixed time step size.

#### Example:
```mathzig
# Harmonic Oscillator
osc(t, y) = [y[1]; -y[0]]
sol = ode_solve("osc", [0; 1], [0, 3.14], 0.01)
# Result is a Matrix with columns: [t, y1, y2]
```

## Related Documentation

- [Overview](overview.md)
- [Time-Series Guide](guide_timeseries.md)
- [Bytecode Format](bytecode.md)
- [Virtual Machine](vm.md)
- [Memory Management](memory.md)
- [Build System](build.md)
