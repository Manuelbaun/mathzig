# MathZig Source Code Architecture Documentation

## Overview

MathZig is a high-performance mathematical expression evaluator written in Zig. It compiles mathematical expressions to bytecode and executes them via a register-based virtual machine with SIMD vectorization support for batch operations. The system is designed for 10-100x faster performance than JavaScript-based alternatives through native compilation, vectorization, and parallel processing.

The implementation features:
- **4-way SIMD** on native platforms (AVX/YMM, 32-byte aligned)
- **2-way SIMD** on WebAssembly (SIMD128, 16-byte aligned)  
- **Multi-threaded** matrix operations for large datasets
- **Cache-aware** algorithms with 64x64 blocking
- **Zero-overhead** fast paths for number-only expressions
- **Cross-platform** threading with WASM fallbacks

## Directory Structure

```
src/
├── main.zig                    # CLI: REPL, compile, compile-graph, graph
├── mathzig.zig                 # Main module exports and context
├── aot_wire.zig                # AOT wire value helpers
├── api_definition.zig          # ABI surface definition (codegen input)
├── VERSION / version.zig       # Package version
├── core/
│   ├── ast.zig                 # Abstract Syntax Tree node types
│   ├── value.zig               # Runtime value types and operations
│   ├── diagnostics.zig         # Error reporting and diagnostics
│   ├── threading.zig           # Cross-platform threading abstraction
│   └── config.zig              # Runtime config (e.g. angle mode)
├── parser/
│   ├── tokenizer.zig           # Lexical analysis
│   ├── compiler.zig            # AST → bytecode compilation
│   └── latex.zig               # LaTeX form helpers
├── vm/
│   ├── bytecode.zig            # Bytecode format and builder
│   └── vm.zig                  # Virtual machine interpreter
├── wasm/
│   ├── compiler.zig            # Expression / multi-root AOT compiler
│   ├── math_lib.zig            # In-wasm math / tier bodies
│   ├── module.zig              # WASM module builder
│   ├── abi.zig                 # Wire kinds / AOT ABI
│   ├── node_manifest.zig       # Per-node module manifest
│   ├── graph_manifest.zig      # Fused graph manifest (mathzig:graph)
│   └── …                      # types, leb128, list_writer
├── graph/
│   ├── runner.zig              # VM-native graph evaluator v1 (no .wasm load)
│   ├── fuse.zig                # Fuse lowerer (graph → plan)
│   ├── schema.zig / manifest.zig / topo.zig / …
│   └── root.zig                # Graph module root
├── timeseries/
│   ├── series.zig              # Time series (aligned storage)
│   ├── indicators.zig          # SMA, EMA, RSI, …
│   ├── aggregations.zig        # Aggregations
│   ├── calculus.zig            # Derivative / integral
│   ├── joins.zig               # As-of joins
│   ├── resampling.zig          # Resampling
│   ├── alignment.zig           # Series alignment
│   └── predicates.zig          # Filter predicates
├── units/
│   ├── unit_registry.zig       # SI dimensions + conversion
│   └── temporal.zig            # Temporal units
├── functions/
│   ├── matrix_kernels.zig      # BLAS-like matrix ops
│   ├── statistics.zig / number_theory.zig / generators.zig
│   ├── timeseries_bindings.zig # Time-series FFI bindings
│   └── ode.zig                 # ODE solvers
├── memory/
│   ├── chunk_arena.zig         # Chunk arena allocator
│   └── compiler_cache.zig      # Expression caching
├── io/
│   └── csv.zig                 # CSV import/export
├── tui/
│   ├── main.zig / state.zig / syntax.zig / test_runner.zig
├── ts/
│   ├── mathzig.ts              # FFI bindings
│   ├── mathzig_wasm.ts         # WASM interpreter host
│   ├── aot_env.ts              # AOT host env
│   └── graph/                  # GraphRunner, fuse, FusedGraphRunner, DSL
└── bindings/
    ├── generated/              # Auto-generated exports / api.json / aot_abi
    └── bindings/               # Manual binding helpers
```

Product UIs live outside `src/`: **`apps/console`** (REPL + graph), **`apps/progress`** (dashboard). Daily tests: **`bun run mz`**.

## Core Components

### 1. Value System (`core/value.zig`)

The Value type is a tagged union that can represent any supported data type:

```zig
pub const ValueTag = enum(u8) {
    number,      // f64
    complex,     // Complex number (re + im*i)
    unit,        // Quantity with unit
    matrix,      // Dense matrix
    series,      // Time series
    predicate,   // Filter predicate
    string,      // UTF-8 string
    boolean,     // true/false
    function,    // Function reference
    array,       // Dynamic array of values
    record,      // Record (object) with named fields
    undefined,
    null_val,
    err,
};
```

#### SIMD Vector Types

For optimized batch operations:
```zig
pub const VectorLen = if (builtin.cpu.arch == .wasm32 or .wasm64) 2 else 4;
pub const Vec = @Vector(VectorLen, f64);
```

- **Native**: 4-wide SIMD (AVX/YMM compatible, 32 bytes)
- **WASM**: 2-wide SIMD (SIMD128, 16 bytes)

#### Matrix Type with SIMD Alignment

```zig
pub const Matrix = struct {
    pub const simd_alignment_bytes: usize = 32;  // AVX/YMM compatible
    
    data: []align(simd_alignment_bytes) f64,     // 32-byte aligned for SIMD
    rows: u32,
    cols: u32,
    stride: u32,                              // Elements between row starts
    ref_count: u32,                            // Thread-safe reference counting
};
```

#### SIMD Vector Types

For optimized batch operations:
```zig
pub const VectorLen = if (builtin.cpu.arch == .wasm32 or .wasm64) 2 else 4;
pub const Vec = @Vector(VectorLen, f64);
```

- Native: 4-wide SIMD (AVX/YMM compatible, 32 bytes)
- WASM: 2-wide SIMD (SIMD128, 16 bytes)

#### Complex Numbers

```zig
pub const Complex = struct {
    re: f64,
    im: f64,

    // Operations: add, sub, mul, div, abs, arg, conj, exp, log, pow
};
```

#### Matrix Type

```zig
pub const Matrix = struct {
    data: []align(32) f64,        // 32-byte aligned for SIMD
    rows: u32,
    cols: u32,
    stride: u32,                  // Elements between row starts
    offset: usize,
    allocator: std.mem.Allocator,
    owns_data: bool,
};
```

#### Record Type

Records enable multi-output indicators (like Bollinger bands returning upper/middle/lower):

```zig
pub const Record = struct {
    fields: std.StringHashMap(Value),
    allocator: std.mem.Allocator,

    pub fn set(key: []const u8, value: Value) !void
    pub fn get(key: []const u8) ?Value
    pub fn len() usize
};
```

#### Value Arithmetic

Value type provides polymorphic arithmetic operations with SIMD optimization:
- `add(a, b)`: Number + Number, Unit + Unit, Matrix + Matrix, Series + Series
- `sub(a, b)`: Subtraction with broadcasting
- `mul(a, b, allocator)`: Matrix multiplication with SIMD GEMM, unit multiplication
- `div(a, b, allocator)`: Division with dimension checking
- `emul(a, b, allocator)`: Element-wise matrix multiplication
- `ediv(a, b, allocator)`: Element-wise matrix division

All operations support automatic broadcasting between scalars and matrices/series.

### 2. Abstract Syntax Tree (`core/ast.zig`)

AST nodes represent parsed expressions:

```zig
pub const NodeType = enum {
    number,           // f64 literal
    variable,         // Variable reference
    string,           // String literal
    unit,             // Unit literal with dimensions
    binary_op,        // Binary operation (+, -, *, /, etc.)
    unary_op,         // Unary operation (-, !, ~)
    function_call,    // Function call with optional predicate
    polynomial,       // Polynomial with coefficients
    matrix,           // Matrix literal [a,b;c,d]
    ternary,          // Ternary operator ?:
    complex,          // Complex literal
    record_literal,    // Record literal {key: value}
    member_access,    // Object field access (obj.field)
};

pub const Node = struct {
    type: NodeType,
    data: union {
        number: f64,
        variable: []const u8,
        binary_op: struct { op: Opcode, lhs: *Node, rhs: *Node },
        function_call: struct {
            name: []const u8,
            args: []*Node,
            predicate: ?*Node = null
        },
        // ... other variants
    },
};
```

### 3. Tokenizer (`parser/tokenizer.zig`)

The tokenizer converts source strings into tokens:

```zig
pub const TokenType = enum(u8) {
    // Literals
    number, string, unit_literal, identifier, complex_i,

    // Arithmetic
    plus, minus, star, slash, percent, caret,

    // Element-wise
    dot_star, dot_slash, dot_caret,

    // Comparison
    equal_equal, not_equal, less, less_equal, greater, greater_equal,

    // Logical
    ampersand_ampersand, pipe_pipe, bang,

    // Bitwise
    ampersand, pipe, tilde, caret_caret, less_less, greater_greater,

    // Control flow
    equal, lparen, rparen, lbracket, rbracket,

    // Keywords
    kw_to, kw_in, kw_and, kw_or, kw_xor, kw_not, kw_if, kw_else,

    eof, err,
};
```

#### Tokenization Features

- **Number formats**: Decimal (3.14), scientific (1e-5), hex (0xFF), binary (0b1010)
- **Implicit multiplication**: `2x` becomes `2 * x`
- **Unit literals**: `[kg]`, `[m/s]` parsed with `isUnitLiteralFollows()`
- **Strings**: `"hello"` or `'hello'` (distinguished by closing quote)

### 4. Compiler (`parser/compiler.zig`)

The compiler parses tokens into AST and generates bytecode:

#### Compilation Pipeline

1. **Parsing**: Recursive descent with Pratt parsing for operator precedence
2. **AST Simplification**: Constant folding, identity rules, unit simplification
3. **Bytecode Generation**: AST → instruction sequence

#### Operator Precedence

```zig
const Precedence = enum(u8) {
    none,
    assignment,        // =
    conditional,        // ?:
    or_,               // ||
    and_,              // &&
    bitwise_or,        // |
    bitwise_xor,       // ^^
    bitwise_and,       // &
    equality,          // == !=
    comparison,        // < >
    shift,             // << >>
    term,              // + -
    factor,            // * / %
    implicit_mul,      // Juxtaposition
    unary,             // - ! ~
    power,             // ^
    postfix,           // ' () []
    primary,
};
```

#### Optimizations

**Constant Folding** (`simplify()`):
- `2 + 3` → `5`
- Number × Unit → scaled unit
- `conv(5 cm, in)` → compile-time conversion

**Instruction Fusion** (`BytecodeBuilder.emit()`):
- Pattern: `push a, push b, mul, push c, add` → `fma a, b, c`
- Superinstruction: `fma_var_const_const` for `x * c1 + c2`

**Predicate Lowering** (`lowerPredicate()`):
- Converts AST predicates to compact `Predicate` struct
- Supports: `value < 10`, `time > 100`, logical combinations

### 5. Bytecode (`vm/bytecode.zig`)

#### Instruction Format

```zig
pub const Instruction = packed struct {
    opcode: Opcode,
    operand: u24 = 0,  // Constant index, variable index, or jump offset
};
```

#### Opcodes

```zig
pub const Opcode = enum(u8) {
    // Stack operations
    push_const, pop, dup,

    // Variables
    load_var, store_var,

    // Arithmetic
    add, sub, mul, div, mod, pow, neg, pos,

    // Comparison
    eq, ne, lt, le, gt, ge,

    // Logical/Bitwise
    and_, or_, not_, band, bor, bxor, bnot, shl, shr,

    // Function calls
    call,              // Call function (operand = arg count)
    call_user,         // Call user-defined function
    def_user,          // Define user function
    call_builtin,      // Call builtin function
    call_builtin_where,// Call builtin with predicate

    // Specialized operations
    eval_poly,         // Evaluate polynomial using Horner's method

    // Superinstructions (Instruction Fusion)
    fma,               // Fused Multiply-Add: a * b + c
    fma_var_const_const, // FMA with embedded indices: x * c1 + c2

    // Matrix operations
    mat_create,        // Create matrix
    mat_index,         // DEAD/legacy — never emitted; use get_index (ordinal retained)
    emul,              // Element-wise multiplication
    ediv,              // Element-wise division
    epow,              // Element-wise power

    // Record operations
    rec_create,        // Create record
    rec_get,           // Get field from record
    rec_get_dyn,       // Dynamic record field access

    // Unit operations
    unit_create,       // Create unit value
    unit_convert,      // Convert units

    // Slice/Index operations
    make_slice,        // Create slice value
    get_index,         // Get value by index/slice

    // Control flow
    jmp,               // Unconditional jump
    jmp_if_false,      // Jump if false
    jmp_if_true,       // Jump if true

    // Special
    halt,              // Stop execution
    nop,               // No operation
};
```

#### Compiled Expression

```zig
pub const CompiledExpr = struct {
    code: []Instruction,
    constants: []Value,
    constants_f64: []f64,      // Pre-extracted for fast-path
    max_stack: u16,
    is_number_only: bool,          // Enables fast f64 execution
    owns_memory: bool,
    allocator: std.mem.Allocator,
};
```

### 6. Virtual Machine (`vm/vm.zig`)

The VM executes bytecode with optimized paths:

```zig
pub const VM = struct {
    stack: [256]Value,
    sp: u8,                              // Stack pointer
    variables: []Value,
    variables_f64: []f64,                // Fast-path mirror
    variables_tags: []ValueTag,            // Type tags for variables

    // Tracking for cleanup
    intermediate_matrices: std.ArrayListUnmanaged(*Matrix),
    intermediate_series: std.ArrayListUnmanaged(*Series),
    intermediate_records: std.ArrayListUnmanaged(*Record),
    intermediate_units: std.ArrayListUnmanaged([]const u8),

    thread_pool: ?*std.Thread.Pool,
    prng: std.Random.DefaultPrng,
};
```

#### Execution Paths

1. **Standard Path** (`execute()`):
   - Full Value type system
   - Tracks and cleans up intermediates
   - Supports all opcodes

2. **Fast Path** (`executeNumbersOnly()`):
   - When `is_number_only = true`
   - Uses `stack_f64` and `variables_f64` arrays
   - No allocation or tracking overhead

#### Builtin Functions

The VM dispatches to built-in functions via `callBuiltin()`:

**Math**: `abs`, `sqrt`, `cbrt`, `exp`, `log`, `log10`, `log2`

**Trigonometry**: `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `sec`, `csc`, `cot`, `asec`, `acsc`, `acot`

**Rounding**: `floor`, `ceil`, `round`, `trunc`, `sign`

**Statistics**: `min`, `max`, `mean`, `median`, `std`, `variance`, `prod`

**Matrix**: `det`, `inv`, `transpose`, `trace`, `dot`, `cross`, `reshape`, `flatten`, `diag`, `identity`, `zeros`, `ones`, `norm`

**Time Series**: `sma`, `ema`, `rsi`, `derivative`, `integrate`, `duration`, `asofJoin`, `resample`, `align_`, `head`, `tail`, `slice`, `between`, `since`, `shift`, `dropna`, `fillna`, `clip`

**Advanced Indicators**: `bollinger`, `macd`

**Number Theory**: `factorial`, `gcd`, `lcm`, `isPrime`

### 7. Time Series (`timeseries/series.zig`)

#### Series Structure

```zig
pub const Series = struct {
    timestamps: []align(32) f64,
    values: []align(32) f64,
    validity: []u8,                // One byte per sample
    len: usize,
    capacity: usize,
    sample_mode: SampleMode,
    dimensions: Dimensions,

    is_sorted: bool,
    min_ts: f64,
    max_ts: f64,

    allocator: std.mem.Allocator,
};
```

#### Sample Modes

```zig
pub const SampleMode = enum(u8) {
    Step,        // Discrete states (LOCF interpolation)
    Linear,      // Continuous measurements (Linear interpolation)
    Cumulative,  // Aggregated counters
};
```

#### Series Operations

- **Validation**: Check sorted timestamps, track min/max
- **Views**: `view(start, end)` for zero-copy slicing
- **Predicates**: `applyPredicate()` filters samples
- **Search**: `binarySearch()` for timestamp lookup
- **Transformations**:
  - `head(n)`, `tail(n)`: First/last n samples
  - `slice(start_ts, end_ts)`: Time-based slicing
  - `shift(n)`: Time shift with NaN fill
  - `dropna()`: Remove invalid samples
  - `fillnaConstant(value)`: Fill with constant
  - `fillnaForward()`: Forward fill (LOCF)
  - `fillnaBackward()`: Backward fill
  - `fillnaLinear()`: Linear interpolation
  - `clip(min, max)`: Clamp values

### 8. Time Series Indicators (`timeseries/indicators.zig`)

Technical analysis indicators:

```zig
// Simple Moving Average
pub fn sma(s: *Series, period: u32) !*Series

// Exponential Moving Average
pub fn ema(s: *Series, period: u32) !*Series

// Relative Strength Index
pub fn rsi(s: *Series, period: u32) !*Series

// Stochastic Oscillator
pub fn stochastic(s: *Series, k_period: u32, d_period: u32) !*Series

// MACD
pub fn macd(s: *Series, fast: u32, slow: u32, signal: u32) !Record

// Bollinger Bands
pub fn bollinger(s: *Series, period: u32, std_dev: f64) !Record
```

### 9. Time Series Aggregations (`timeseries/aggregations.zig`)

Aggregation functions with optional predicates:

```zig
pub fn sum(s: *Series, predicate: ?*const Predicate) f64
pub fn mean(s: *Series, predicate: ?*const Predicate) f64
pub fn twa(s: *Series, predicate: ?*const Predicate) f64  // Time-weighted average
pub fn min(s: *Series, predicate: ?*const Predicate) f64
pub fn max(s: *Series, predicate: ?*const Predicate) f64
```

### 10. Time Series Calculus (`timeseries/calculus.zig`)

```zig
pub fn derivative(s: *Series) !*Series {
    // First-order derivative using central differences
}

pub fn integrate(s: *Series) !*Series {
    // Cumulative integral using trapezoidal rule
}
```

### 11. Time Series Joins (`timeseries/joins.zig`)

As-of joins align time series based on timestamps:

```zig
pub fn asofJoin(
    left: *Series,
    right: *Series,
    tolerance: ?f64 = null
) !struct { left: *Series, right: *Series }
```

### 12. Time Series Resampling (`timeseries/resampling.zig`)

```zig
pub const AggKernel = enum {
    sum, mean, min, max, first, last, count,
};

pub fn resample(
    s: *Series,
    target_period: f64,
    kernel: AggKernel,
    mode: SampleMode
) !*Series
```

### 13. Time Series Alignment (`timeseries/alignment.zig`)

```zig
pub fn alignUnion(
    a: *Series,
    b: *Series,
    allocator: std.mem.Allocator
) !struct { @"0": *Series, @"1": *Series }
```

### 14. Time Series Predicates (`timeseries/predicates.zig`)

Predicates for filtering series:

```zig
pub const Field = enum {
    value,      // Sample value
    timestamp,  // Timestamp
    dt,         // Time delta
};

pub const PredicateOp = enum {
    eq, ne, lt, le, gt, ge,
    and_, or_, not_,
};

pub const Predicate = union {
    compare: struct { op: PredicateOp, field: Field, constant: f64 },
    logical: struct { op: PredicateOp, left: *const Predicate, right: *const Predicate },
    unary: struct { op: PredicateOp, left: *const Predicate },
};
```

### 15. Unit System (`units/unit_registry.zig`)

#### Dimensions

SI base unit exponents:

```zig
pub const Dimensions = struct {
    m: i8 = 0,  // Mass (kg)
    l: i8 = 0,  // Length (m)
    t: i8 = 0,  // Time (s)
    i: i8 = 0,  // Current (A)
    k: i8 = 0,  // Temperature (K)
    n: i8 = 0,  // Substance (mol)
    j: i8 = 0,  // Luminosity (cd)

    pub fn multiply(a: Dimensions, b: Dimensions) Dimensions
    pub fn divide(a: Dimensions, b: Dimensions) Dimensions
    pub fn isScalar(a: Dimensions) bool
};
```

#### Unit Registry

```zig
pub const Unit = struct {
    name: []const u8,
    dimensions: Dimensions,
    scale: f64,     // Factor to normalize to base units
    offset: f64 = 0, // For temperature (Celsius/Fahrenheit)
};

pub const UnitRegistry = struct {
    units: std.StringHashMap(Unit),
    prefixes: std.StringHashMap(f64),  // Y, Z, E, P, T, G, M, k, h, da, d, c, m, u, n, p, f, a, z, y
    preferred_units: std.AutoHashMap(Dimensions, []const u8),

    pub fn findUnit(name: []const u8) ?struct { unit: Unit, prefix_scale: f64 }
};
```

#### Supported Units

**Base**: m, kg, s, A, K, mol, cd

**Derived**:
- Frequency: Hz
- Force: N
- Pressure: Pa
- Energy: J, Wh, BTU, cal, eV
- Power: W, hp
- Electric: C, V, F, ohm, S, Wb, T, H
- Illuminance: lm, lx
- Radioactivity: Bq, Gy, Sv
- Catalytic: kat

**Metric Derived**: g, tonne, L

**Imperial/US**: in, inch, ft, yd, mi, psi

**Time**: min, h, day, week, month, year

**Temperature**: degC, degF

### 16. Matrix Kernels (`functions/matrix_kernels.zig`)

BLAS-like operations:

```zig
// Level 1: Vector operations
pub fn gemv_simple(
    n: u32,
    A: []const f64, strideA: u32,
    x: []const f64,
    y: []f64
)

// Level 2: Matrix-vector multiplication
pub fn gemv(
    rows: u32, cols: u32,
    alpha: f64,
    A: []const f64, strideA: u32,
    x: []const f64,
    beta: f64,
    y: []f64
)

// Level 3: Matrix-matrix multiplication (SIMD)
pub fn gemm(
    rows: u32, colsA: u32, colsB: u32,
    A: []const f64, strideA: u32,
    B: []const f64, strideB: u32,
    C: []f64, strideC: u32
)

// Parallel GEMM (uses thread pool)
pub fn gemmParallel(
    pool: *std.Thread.Pool,
    rows: u32, colsA: u32, colsB: u32,
    A: []const f64, strideA: u32,
    B: []const f64, strideB: u32,
    C: []f64, strideC: u32
)

// Vector operations
pub fn vecAdd(a: []const f64, b: []const f64, c: []f64, len: u32)
pub fn vecSub(a: []const f64, b: []const f64, c: []f64, len: u32)
pub fn vecDot(a: []const f64, b: []const f64, len: u32) f64
pub fn vecNorm(a: []const f64, len: u32) f64
pub fn vecScale(alpha: f64, a: []const f64, b: []f64, len: u32)
pub fn vecAxpy(alpha: f64, x: []const f64, y: []f64, len: u32)

// Matrix operations
pub fn determinant(n: u32, A: []f64, stride: u32, allocator: std.mem.Allocator) f64
pub fn matrixTrace(rows: u32, cols: u32, A: []const f64, stride: u32) f64
pub fn matrixInverse(n: u32, A: []f64, stride: u32, allocator: std.mem.Allocator) bool
```

### 17. Statistics (`functions/statistics.zig`)

```zig
pub fn matrixMedian(m: *Matrix, allocator: std.mem.Allocator) f64
pub fn matrixStddev(m: *Matrix) f64
pub fn matrixVariance(m: *Matrix) f64
```

### 18. Number Theory (`functions/number_theory.zig`)

```zig
pub fn factorial(n: f64) f64
pub fn gcd(a: f64, b: f64) f64
pub fn lcm(a: f64, b: f64) f64
pub fn isPrime(n: f64) bool
```

### 19. ODE Solver (`functions/ode.zig`)

MathZig includes native Ordinary Differential Equation (ODE) solvers for scientific computing:

#### RK4 (Runge-Kutta 4th Order)

```zig
pub fn ode_solve(vm: *VM, func_val: Value, y0: Value, t_span: Value, dt: f64) !Value
```

Solves ODEs using the classic 4th-order Runge-Kutta method:

```
k1 = f(t, y)
k2 = f(t + 0.5*dt, y + 0.5*dt*k1)
k3 = f(t + 0.5*dt, y + 0.5*dt*k2)
k4 = f(t + dt, y + dt*k3)
y_next = y + (dt/6)*(k1 + 2*k2 + 2*k3 + k4)
```

**Parameters:**
- `func_val`: Derivative function f(t, y) as a user function or function name
- `y0`: Initial state (Number for scalar, Matrix for vector)
- `t_span`: Time span as [start, end] or single end value
- `dt`: Time step size (must be positive)

**Returns:** Matrix with first column as time, subsequent columns as state variables

#### Euler Method (1st Order)

```zig
pub fn ode_solve_euler(vm: *VM, func_val: Value, y0: Value, t_span: Value, dt: f64) !Value
```

Simpler Euler method for cases where performance is prioritized over accuracy.

#### Optimization Features

- **Sub-VM Reuse**: Creates a dedicated VM instance for derivative evaluation
- **Buffer Pre-allocation**: Allocates RK4 buffers (k1, k2, k3, k4) once
- **Matrix Reuse**: Reuses state matrix for vector-valued ODEs
- **Safety Limits**: Maximum 10M steps to prevent runaway computations

**Error Handling:**
- `error.InvalidArgument`: Invalid initial state or time span
- `error.TypeError`: Invalid function type
- `error.InvalidStep`: Non-positive time step
- `error.ResultTooLarge`: Exceeds maximum step limit
- `error.UnknownFunction`: Function name not found

### 20. Generators (`functions/generators.zig`)

Sequence and range generation functions for data creation:

```zig
// Arithmetic sequences
pub fn gen_range(start: f64, end: f64, step: f64) ![]f64

// Linear spacing (n points from start to end)
pub fn linspace(start: f64, end: f64, n: u32) ![]f64

// Logarithmic spacing (n points from 10^start to 10^end)
pub fn logspace(start: f64, end: f64, n: u32) ![]f64

// Time-based aggregation ranges
pub fn agg_range(
    start_ts: f64,
    end_ts: f64,
    period: f64,
    aggregator: []const u8
) !Series

// Current timestamp
pub fn now() f64
```

#### Usage Examples

```zig
// Generate [0, 1, 2, 3, 4]
gen_range(0, 5, 1)

// Generate 5 points from 0 to 1: [0, 0.25, 0.5, 0.75, 1]
linspace(0, 1, 5)

// Generate 5 points logarithmically: [0.01, 0.1, 1, 10, 100]
logspace(-2, 2, 5)

// Time series with hourly aggregation
agg_range(t0, t1, 3600, "mean")
```

### 21. Temporal Units (`units/temporal.zig`)

Extended unit handling for time-based operations:

```zig
pub const TemporalUnit = struct {
    name: []const u8,      // "hour", "day", "week", "month", "year"
    seconds: f64,          // Conversion factor to seconds
    category: enum { second, minute, hour, day, week, month, year },
};

// Supported temporal units with conversion to seconds:
const TEMPORAL_UNITS = [_]TemporalUnit{
    .{ .name = "ns", .seconds = 1e-9, .category = .second },
    .{ .name = "us", .seconds = 1e-6, .category = .second },
    .{ .name = "ms", .seconds = 0.001, .category = .second },
    .{ .name = "s", .seconds = 1.0, .category = .second },
    .{ .name = "min", .seconds = 60.0, .category = .minute },
    .{ .name = "h", .seconds = 3600.0, .category = .hour },
    .{ .name = "d", .seconds = 86400.0, .category = .day },
    .{ .name = "w", .seconds = 604800.0, .category = .week },
    .{ .name = "month", .seconds = 2629800.0, .category = .month },  // Average
    .{ .name = "year", .seconds = 31557600.0, .category = .year },  // Tropical year
};
```

**Features:**
- Bidirectional conversion between temporal units
- Integration with series resampling for time-based aggregation
- Support for irregular time series with varying intervals

### 22. CSV I/O (`io/csv.zig`)

CSV import and export functionality for data exchange:

```zig
pub const CsvOptions = struct {
    delimiter: u8 = ',',
    has_header: bool = true,
    columns: ?[][]const u8 = null,  // Explicit column names
};

pub fn readCsv(
    path: []const u8,
    options: CsvOptions
) !struct { headers: [][]const u8, data: [][]Value }

pub fn writeCsv(
    path: []const u8,
    value: Value,
    options: CsvOptions
) !void
```

**Read Options:**
- `delimiter`: Field separator (default: ',')
- `has_header`: First row contains column names
- `columns`: Override or provide column names

**Write Support:**
- Number matrices → CSV with numeric values
- Series → CSV with timestamp and value columns
- Records → CSV with named columns

**Example:**

```zig
// Read CSV with auto-detected headers
const result = readCsv("data.csv", .{});

// Write matrix to CSV
writeCsv("output.csv", matrix, .{.has_header = false});
```

### 23. Memory Management

#### Chunk Arena (`memory/chunk_arena.zig`)

Chunk-based arena allocator for efficient allocation:

```zig
pub const ChunkArena = struct {
    const CHUNK_SIZE = 64 * 1024;  // 64KB

    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged([]u8),
    current: []u8,
    pos: usize,
    allocated_bytes: usize,
    peak_bytes: usize,

    pub fn allocMem(comptime T: type, len: usize) []T
    pub fn allocAligned(len: usize, alignment: usize) []u8
    pub fn dupeStr(str: []const u8) []u8
    pub fn reset() void
    pub fn deinit() void
};
```

Benefits:
- Single malloc per chunk (64KB default)
- Grows as needed
- Fast bump allocation within chunks
- Simple cleanup (free all chunks at once)

#### Compiler Cache (`memory/compiler_cache.zig`)

Expression bytecode caching for recompilation:

```zig
pub const CompilerCache = struct {
    buffer: []u8,
    pos: usize,

    pub fn reset() void
    pub fn getAllocator() std.mem.Allocator
};
```

### 24. MathZig Context (`mathzig.zig`)

```zig
pub const MathZig = struct {
    allocator: std.mem.Allocator,
    arena: ChunkArena,                  // Session memory
    compiler_cache: CompilerCache,
    unit_registry: UnitRegistry,
    vm: VM,
    variables: std.StringHashMap(u24),     // Variable name → index
    next_var_index: u24,
    last_error: [256]u8,
    last_error_len: usize,
    thread_pool: std.Thread.Pool,

    pub fn init(allocator: std.mem.Allocator) !*Self
    pub fn compile(source: []const u8) !*CompiledExpr
    pub fn compileInPlace(source: []const u8) !CompiledExpr
    pub fn evaluate(expr: *const CompiledExpr) !Value
    pub fn setVariable(name: []const u8, value: Value) void
    pub fn setNumber(name: []const u8, value: f64) void
    pub fn setVariableByIndex(index: u24, value: Value) void
    pub fn addVariableIndexed(name: []const u8, value: f64) u24
};
```

Pre-defined constants:
- Math: pi, tau, e, phi, SQRT2, LN2, LN10
- Special: inf, Infinity, nan, NaN
- Physical: speedOfLight, planckConstant, gravitationalConstant

### 25. TypeScript FFI Bindings (`mathzig.ts`)

Bun native FFI for JavaScript/TypeScript integration:

```typescript
export class MathZig {
    static create(): MathZig
    eval(expr: string): number
    compile(expr: string): CompiledExpr
    setVariable(name: string, value: number): void
    addVariableIndexed(name: string, value?: number): number
    setByIndex(index: number, value: number): void
    setByIndexFast(index: number, value: number): void
    getVariablesPtr(): ptr
    createSeries(timestamps, values, mode): ptr
    freeSeries(series: ptr): void
    setSeries(name: string, series: ptr): void
    getSeriesLen(series: ptr): number
    getSeriesTimestampsPtr(series: ptr): ptr
    getSeriesValuesPtr(series: ptr): ptr
    static allocAligned(alignment, size): ptr
    static free(p: ptr): void
    static toFloat64Array(p, count): Float64Array
    static createMatrix(rows, cols): Float64Array
    matmulSIMD(a, b): Float64Array
    compilePolynomial(varIndex, coefficients): CompiledExpr
    version(): string
    getError(): string
    gemmParallel(rowsA, colsA, colsB, A, strideA, B, strideB, C, strideC): void
    matrixInverse(n, A, strideA): boolean
    determinant(n, A, strideA): number
    matrixSum(A): number
    matrixMean(A): number
    getMemoryUsed(): number
    getMemoryReserved(): number
    getMemoryPeak(): number
    resetMemory(): void
    destroy(): void
}

export class CompiledExpr {
    evaluate(): number
    evaluateFast(): number
    evaluateBatchSIMD(varIndex, inputsPtr, outputsPtr, count): void
    evaluateBatchComplexSIMD(varIndex, inputsRePtr, inputsImPtr, outputsRePtr, outputsImPtr, count): void
    evaluateBatch(varIndex, inputs): number[]
    evaluateBatchParallel(varIndex, inputsPtr, outputsPtr, count): void
    free(): void
}
```

#### BLAS Functions

```typescript
// Level 1: Vector operations
export function vecAdd(a, b, c): void
export function vecSub(a, b, c): void
export function vecDot(a, b): number
export function vecNorm(a): number
export function vecScale(alpha, a, b): void
export function vecScaleInplace(alpha, a): void
export function vecAxpy(alpha, x, y): void

// Level 2: Matrix-vector
export function gemv(rows, cols, alpha, A, strideA, x, beta, y): void
export function gemvSimple(rows, cols, A, strideA, x, y): void

// Level 3: Matrix-matrix
export function gemm(rowsA, colsA, colsB, A, strideA, B, strideB, C, strideC): void
```

### 26. CLI REPL (`main.zig`)

Interactive command-line interface:

```bash
$ ./mathzig
MathZig REPL v0.1.0
> 2 + 3 * 4
14
> x = 5
5
> x^2 + 2*x + 1
36
> sin(3.14159/2)
1
> help
Commands:
  help         Show this help
  vars         List all variables
  consts       List built-in constants
  clear/reset  Clear all variables
  quit/exit    Exit the REPL
```

### 27. Expression Evaluation Flow

#### Example: `x * 0.5 + 2.0`

1. **Tokenization**:
   - `x` (identifier)
   - `*` (star)
   - `0.5` (number)
   - `+` (plus)
   - `2.0` (number)

2. **Parsing** → AST:
   ```
   BinaryOp(mul)
     lhs: Variable("x")
     rhs: Number(0.5)
   BinaryOp(add)
     lhs: BinaryOp(mul) above
     rhs: Number(2.0)
   ```

3. **Simplification**: None needed (no constant folding)

4. **Bytecode Generation**:
   ```
   load_var(0)     # Load x
   push_const(0)    # Push 0.5
   mul              # x * 0.5
   push_const(1)    # Push 2.0
   add              # (x * 0.5) + 2.0
   halt
   ```

5. **Execution** (with `x = 10`):
   - Stack: `[10]`
   - Stack: `[10, 0.5]`
   - Stack: `[5]`
   - Stack: `[5, 2]`
   - Stack: `[7]`
   - Return: `7.0`

#### Fast Path Example: `x * 0.5 + 2.0`

If `is_number_only = true`:
1. `variables_f64[0] = 10.0`
2. Fast stack operations on `stack_f64[]`
3. Result: `7.0`

### 28. Optimization Techniques

1. **SIMD Vectorization**:
   - 4-wide on native (AVX/YMM)
   - 2-wide on WASM (SIMD128)
   - Applied in batch evaluation

2. **Instruction Fusion**:
   - `mul` + `add` → `fma` (Fused Multiply-Add)
   - `load_var + push_const + push_const + fma` → `fma_var_const_const`

3. **Constant Folding**:
   - Compiler folds `2 + 3` → `5` during bytecode generation
   - `BytecodeBuilder.tryFoldBinaryOp()` tracks pending constants

4. **Fast Path Execution**:
   - Number-only expressions use `stack_f64[]` and `variables_f64[]`
   - Avoids Value allocation and type dispatch

5. **Memory Alignment**:
   - Matrix data: 32-byte aligned (AVX compatible)
   - Series data: 32-byte aligned
   - Enables SIMD loads/stores without alignment checks

6. **Parallel Processing**:
   - Matrix multiplication uses thread pool for large matrices
   - `gemmParallel()` divides work among threads

7. **Arena Allocation**:
   - Chunk-based arena reduces malloc overhead
   - Single `free()` to deallocate all chunks

### 29. Memory Safety

The VM tracks intermediate objects for automatic cleanup:

```zig
pub fn trackMatrix(self: *VM, matrix: *Matrix) void
pub fn trackSeries(self: *VM, series: *Series) void
pub fn trackRecord(self: *VM, record: *Record) void
pub fn untrackMatrix(self: *VM, matrix: *Matrix) void
pub fn freeIntermediates(self: *VM) void
```

Cleanup on `deinit()`:
1. Transfer all variables to intermediates
2. Use HashMap to deduplicate pointers
3. Free each unique Matrix/Series/Record
4. Free variable arrays

### 30. Error Handling

```zig
pub const ValueTag = enum(u8) {
    // ... other tags
    err,  // Error value
};

pub const Value = struct {
    pub fn initError(code: u32) Value {
        return .{ .tag = .err, .data = .{ .err = code } };
    }
};
```

Error codes:
- 1: Type error
- 2: Dimension mismatch (units/matrices)
- 3: Allocation error

Context error storage:
```zig
last_error: [256]u8,
last_error_len: usize,

pub fn setError(msg: []const u8) void
pub fn getError() [*:0]const u8
```

### 31. Testing

Each module includes inline tests:

```zig
test "test name" {
    const allocator = std.testing.allocator;
    // Test implementation
    try std.testing.expectEqual(expected, actual);
}
```

Run tests:
```bash
zig build test
```

## Build Targets

### Native Executable
```bash
zig build -Dtarget=native -Doptimize=ReleaseFast
```

### Dynamic Library (C ABI)
```bash
zig build -Dtarget=native -Doptimize=ReleaseFast -Dstrip=true
# Output: libmathzig.dylib / libmathzig.so / mathzig.dll
```

### WebAssembly
```bash
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseFast
# Output: mathzig_wasm.wasm
```

## SIMD Implementation Details

### Vector Operations

MathZig implements comprehensive SIMD vector operations in `functions/matrix_kernels.zig`:

```zig
// 4-way vector operations (native) or 2-way (WASM)
pub fn vecAdd(a: []const f64, b: []const f64, c: []f64) void
pub fn vecSub(a: []const f64, b: []const f64, c: []f64) void  
pub fn vecDot(a: []const f64, b: []const f64) f64
pub fn vecNorm(a: []const f64) f64
pub fn vecScale(alpha: f64, a: []const f64, b: []f64) void
pub fn vecAxpy(alpha: f64, x: []const f64, y: []f64) void
```

Key optimizations:
- **Alignment checks**: Falls back to scalar if data isn't 32-byte aligned
- **Loop unrolling**: 4-way unrolling for dot products
- **Horizontal reductions**: Uses `@reduce(.Add, acc)` for final summation

### Matrix Operations (GEMM)

The matrix multiplication kernel uses cache-aware blocking:

```zig
pub fn gemm(
    rows_a: u32, cols_a: u32, cols_b: u32,
    A: []const f64, stride_a: u32,
    B: []const f64, stride_b: u32, 
    C: []f64, stride_c: u32
) void
```

Optimizations:
- **64x64 blocking**: Cache-friendly tile size
- **4x4 and 8x8 micro-kernels**: Specialized for common sizes
- **FMA instructions**: `@mulAdd(Vec, a, b, c)` for fused multiply-add
- **Register blocking**: Keeps data in registers during inner loops

### Batch Evaluation SIMD

The VM provides SIMD batch evaluation for number-only expressions:

```zig
pub fn executeBatchSIMD(
    self: *VM, 
    expr: *const CompiledExpr,
    var_index: u8,
    inputs: []const f64,
    outputs: []f64,
    count: usize
) void
```

Processes 4 values simultaneously using vector registers.

## Threading and Parallel Processing

### Cross-Platform Threading Abstraction

MathZig provides a threading abstraction in `core/threading.zig`:

```zig
pub const is_wasm = builtin.cpu.arch.isWasm();

pub const Pool = if (is_wasm) void else std.Thread.Pool;
pub const WaitGroup = if (is_wasm) struct {
    pub fn start(_: *@This()) void {}
    pub fn finish(_: *@This()) void {}
    pub fn wait(_: *@This()) void {}
} else std.Thread.WaitGroup;

pub fn getCpuCount() u32 {
    if (comptime is_wasm) return 1;
    return @as(u32, @intCast(std.Thread.getCpuCount() catch 1));
}
```

### Parallel Matrix Operations

Large matrix operations automatically use thread pools:

```zig
pub fn gemmParallel(
    pool: *threading.Pool,
    rows_a: u32, cols_a: u32, cols_b: u32,
    A: []const f64, stride_a: u32,
    B: []const f64, stride_b: u32,
    C: []f64, stride_c: u32
) void
```

**Work distribution**: Matrix C is divided into horizontal slabs across available threads.

### Parallel Time-Series Processing

Time-series resampling supports parallel execution:

```zig
pub fn parResample(
    series: *const Series,
    options: ResampleOptions,
    pool: *threading.Pool,
    allocator: std.mem.Allocator
) !*Series
```

### VM Integration

The VM integrates threading for matrix multiplication:

```zig
// In VM.mul() for matrix operations
if (comptime !is_wasm) {
    if (self.thread_pool) |pool| {
        kernels.gemmParallel(pool, ma.rows, ma.cols, mb.cols, 
                           ma.data, ma.stride, mb.data, mb.stride, 
                           res.data, res.stride);
    } else {
        kernels.gemm(/* single-threaded */);
    }
}
```

## Performance Characteristics

| Path | Performance | Use Case |
|------|-------------|----------|
| SIMD Batch (4-wide) | 10M+ ops/sec | Bulk processing |
| SIMD Batch (2-wide WASM) | 5M+ ops/sec | WebAssembly bulk |
| Scalar Fast | ~1M ops/sec | Single evaluations |
| Standard | ~100K ops/sec | Complex expressions |
| String Marshalling | ~10K ops/sec | Legacy API |

### Performance Optimizations

1. **SIMD Vectorization**: 4-way parallel processing (native) or 2-way (WASM)
2. **Cache Blocking**: 64x64 tiles for matrix operations
3. **Thread Parallelism**: Automatic for matrices >32 rows
4. **FMA Instructions**: Fused multiply-add where available
5. **Aligned Memory**: 32-byte alignment for SIMD loads/stores
6. **Fast Path VM**: Specialized execution for number-only expressions
7. **Arena Allocation**: Minimizes malloc overhead for temporaries

## SIMD Implementation Details

### Vector Operations

MathZig implements comprehensive SIMD vector operations in `functions/matrix_kernels.zig`:

```zig
// 4-way vector operations (native) or 2-way (WASM)
pub fn vecAdd(a: []const f64, b: []const f64, c: []f64) void
pub fn vecSub(a: []const f64, b: []const f64, c: []f64) void  
pub fn vecDot(a: []const f64, b: []const f64) f64
pub fn vecNorm(a: []const f64) f64
pub fn vecScale(alpha: f64, a: []const f64, b: []f64) void
pub fn vecAxpy(alpha: f64, x: []const f64, y: []f64) void
```

Key optimizations:
- **Alignment checks**: Falls back to scalar if data isn't 32-byte aligned
- **Loop unrolling**: 4-way unrolling for dot products
- **Horizontal reductions**: Uses `@reduce(.Add, acc)` for final summation

### Matrix Operations (GEMM)

The matrix multiplication kernel uses cache-aware blocking:

```zig
pub fn gemm(
    rows_a: u32, cols_a: u32, cols_b: u32,
    A: []const f64, stride_a: u32,
    B: []const f64, stride_b: u32, 
    C: []f64, stride_c: u32
) void
```

Optimizations:
- **64x64 blocking**: Cache-friendly tile size
- **4x4 and 8x8 micro-kernels**: Specialized for common sizes
- **FMA instructions**: `@mulAdd(Vec, a, b, c)` for fused multiply-add
- **Register blocking**: Keeps data in registers during inner loops

### Batch Evaluation SIMD

The VM provides SIMD batch evaluation for number-only expressions:

```zig
pub fn executeBatchSIMD(
    self: *VM, 
    expr: *const CompiledExpr,
    var_index: u8,
    inputs: []const f64,
    outputs: []f64,
    count: usize
) void
```

Processes 4 values simultaneously using vector registers.

## Processing Flow

### Expression Evaluation Pipeline

1. **Tokenization** (`parser/tokenizer.zig`)
   - Converts input string to tokens
   - Supports number formats (decimal, scientific, hex, binary)
   - Handles implicit multiplication: `2x` → `2 * x`
   - Parses unit literals: `[kg]`, `[m/s]`

2. **Parsing** (`parser/compiler.zig`)
   - Recursive descent with Pratt parsing for operator precedence
   - Creates Abstract Syntax Tree (AST)
   - Supports polymorphic operators and function calls

3. **Optimization** (`parser/compiler.zig`)
   - **Constant folding**: `2 + 3` → `5`
   - **Identity rules**: `x * 1` → `x`
   - **Unit simplification**: `conv(5 cm, in)` → compile-time conversion
   - **Instruction fusion**: `push a, push b, mul, push c, add` → `fma a, b, c`

4. **Bytecode Generation** (`vm/bytecode.zig`)
   - AST → instruction sequence
   - **Superinstructions**: Specialized opcodes for common patterns
   - **Metadata tracking**: Source offsets for error reporting

5. **VM Execution** (`vm/vm.zig`)
   - **Standard path**: Full Value type system with tracking
   - **Fast path**: `executeNumbersOnly()` for f64-only expressions
   - **SIMD batch**: `executeBatchSIMD()` for bulk processing

### Example: `x * 0.5 + 2.0`

```zig
// Input: "x * 0.5 + 2.0"
// Tokens: identifier, star, number, plus, number
// AST: BinaryOp(add, BinaryOp(mul, Variable("x"), Number(0.5)), Number(2.0))

// Bytecode (optimized):
load_var(0)        // Load x
push_const(0)        // Push 0.5
fma                  // x * 0.5 (fused multiply-add prepared)
push_const(1)        // Push 2.0
add                  // (x * 0.5) + 2.0
halt

// Execution paths:
// Standard: Stack-based with Value objects
// Fast: Direct f64 operations on stack_f64[]
// SIMD Batch: Process 4 values simultaneously
```

### Memory Management

### Chunk-Based Arena Allocation (`memory/chunk_arena.zig`)

```zig
pub const ChunkArena = struct {
    const CHUNK_SIZE = 64 * 1024; // 64KB chunks
    
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged([]u8),
    current: []u8,
    pos: usize,
    allocated_bytes: usize,
    peak_bytes: usize,
};
```

**Benefits**:
- **Single malloc per chunk**: 64KB allocated at once
- **Bump allocation**: O(1) allocation within chunk
- **Memory locality**: Temporaries allocated together
- **Simple cleanup**: Free all chunks at once

### VM Memory Tracking

The VM tracks all intermediate objects for automatic cleanup:

```zig
pub const VM = struct {
    intermediate_objects: std.AutoHashMapUnmanaged(usize, TrackedObject),
    intermediate_units: std.ArrayListUnmanaged([]const u8),
    
    pub fn trackMatrix(self: *VM, matrix: *Matrix) void
    pub fn trackSeries(self: *VM, series: *Series) void
    pub fn trackRecord(self: *VM, record: *Record) void
    pub fn freeIntermediates(self: *VM) void
};
```

### Reference Counting

All reference types (Matrix, Series, Record) use atomic reference counting:

```zig
pub fn retain(self: *Matrix) *Matrix {
    _ = @atomicRmw(u32, &self.ref_count, .Add, 1, .seq_cst);
    return self;
}

pub fn release(self: *Matrix) void {
    if (@atomicRmw(u32, &self.ref_count, .Sub, 1, .seq_cst) == 1) {
        self.deinit();
    }
}
```

## Key Design Decisions

1. **Tagged Union Values**: Polymorphic type system with minimal overhead
2. **Stack-Based VM**: Simple bytecode interpreter with predictable memory patterns
3. **Instruction Fusion**: Reduces instruction count and memory traffic
4. **SoA Layout**: `variables_f64[]` and `variables_tags[]` for cache efficiency
5. **Arena Allocation**: Minimizes malloc overhead for temporary allocations
6. **SIMD Alignment**: All data structures aligned for vector operations
7. **Predicate System**: Compact filter representation for time-series operations
8. **Unit System**: Compile-time dimension checking with runtime conversion
9. **FFI Layer**: Zero-copy memory access for JavaScript integration
10. **Thread Pool**: Parallel matrix operations with work stealing
11. **Cross-Platform Threading**: Unified API for native and WASM targets
12. **Memory Safety**: Reference counting with automatic cleanup in VM
