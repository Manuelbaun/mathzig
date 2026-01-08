# Value Types and Data Structures

MathZig uses a tagged union to represent any value that can appear during expression evaluation. This allows the VM to handle mixed-type expressions while maintaining type safety.

## ValueTag Enumeration

```zig
pub const ValueTag = enum(u8) {
    number,    // Standard f64 floating-point
    complex,   // Complex number (re + im*i)
    unit,      // Quantity with unit
    matrix,    // Dense matrix
    string,    // UTF-8 string
    boolean,   // true/false
    function,  // Function reference
    array,     // Dynamic array of values
    undefined, // Undefined value
    null_val,  // Null value
    err,       // Error value
};
```

## Core Value Type

```zig
pub const Value = struct {
    tag: ValueTag,
    data: Data,
    
    pub const Data = union {
        number: f64,
        complex: Complex,
        unit: UnitValue,
        matrix: *Matrix,
        string: StringHandle,
        boolean: bool,
        function: FunctionHandle,
        array: *std.ArrayList(Value),
        undefined: void,
        null_val: void,
        err: u32, // Error code
    };
};
```

## Value Constructors

```zig
pub fn initNumber(n: f64) Value
pub fn initComplex(re: f64, im: f64) Value
pub fn initBoolean(b: bool) Value
pub fn initUnit(value: f64, dimensions: Dimensions) Value
pub fn initUndefined() Value
pub fn initNull() Value
pub fn initError(code: u32) Value
```

## Complex Numbers

```zig
pub const Complex = struct {
    re: f64,  // Real part
    im: f64,  // Imaginary part
    
    pub fn init(re: f64, im: f64) Complex
    pub fn fromReal(re: f64) Complex
    pub fn add(a: Complex, b: Complex) Complex
    pub fn sub(a: Complex, b: Complex) Complex
    pub fn mul(a: Complex, b: Complex) Complex
    pub fn div(a: Complex, b: Complex) Complex
    pub fn abs(self: Complex) f64
    pub fn arg(self: Complex) f64
    pub fn conj(self: Complex) Complex
    pub fn neg(self: Complex) Complex
};
```

### Complex Arithmetic Example

```zig
const a = Complex.init(2, 3);   // 2 + 3i
const b = Complex.init(1, -2);  // 1 - 2i

// (2 + 3i) * (1 - 2i) = 2 - 4i + 3i - 6i^2 = 8 - i
const prod = Complex.mul(a, b);
// prod.re = 8, prod.im = -1
```

## Matrices

```zig
pub const Matrix = struct {
    data: []f64,     // Row-major flat array
    rows: u32,       // Number of rows
    cols: u32,       // Number of columns
    stride: u32,     // Elements to skip for next row
    offset: usize,   // Offset into data array
    allocator: std.mem.Allocator,
    owns_data: bool,
    
    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !*Matrix
    pub fn initView(rows, cols, stride, offset, data, allocator) !*Matrix
    pub fn deinit(self: *Matrix) void
    pub fn get(self: *const Matrix, row: u32, col: u32) f64
    pub fn set(self: *Matrix, row: u32, col: u32, val: f64) void
};
```

### Matrix Storage Layout

```
Matrix 3x4 with stride 4:
┌─────┬─────┬─────┬─────┐
│ m00 │ m01 │ m02 │ m03 │  row 0
├─────┼─────┼─────┼─────┤
│ m10 │ m11 │ m12 │ m13 │  row 1
├─────┼─────┼─────┼─────┤
│ m20 │ m21 │ m22 │ m23 │  row 2
└─────┴─────┴─────┴─────┘

data = [m00, m01, m02, m03, m10, m11, m12, m13, m20, m21, m22, m23]
stride = 4 (columns per row)
```

## Unit Values

```zig
pub const UnitValue = struct {
    value: f64,           // Normalized value in base SI units
    dimensions: Dimensions,
    
    pub fn init(value: f64, dimensions: Dimensions) UnitValue
};
```

### Dimensions

Dimensions track the physical dimensions of a unit (mass, length, time, etc.):

```
[L] = Length
[M] = Mass
[T] = Time
[I] = Current
[Θ] = Temperature
[N] = Amount
[J] = Intensity

Example:
- velocity: [L/T]
- force: [M*L/T^2]
- energy: [M*L^2/T^2]
```

## String Handles

```zig
pub const StringHandle = struct {
    ptr: [*]const u8,
    len: u32,
    
    pub fn fromSlice(slice: []const u8) StringHandle
    pub fn toSlice(self: StringHandle) []const u8
};
```

## Function Handles

```zig
pub const FunctionHandle = struct {
    id: u32,        // Index into function table
    arity: u8,      // Number of parameters
};
```

## Value Type Checking

```zig
pub fn isNumber(self: Value) bool
pub fn isComplex(self: Value) bool
pub fn isNumeric(self: Value) bool
pub fn isUnit(self: Value) bool
pub fn isMatrix(self: Value) bool
pub fn isError(self: Value) bool
```

## Value Conversions

```zig
pub fn toNumber(self: Value) ?f64
pub fn toComplex(self: Value) ?Complex
```

## Arithmetic Operations

### Number + Number

```zig
const a = Value.initNumber(10);
const b = Value.initNumber(3);
const sum = Value.add(a, b);  // 13
```

### Complex Arithmetic

```zig
const a = Value.initComplex(2, 3);   // 2 + 3i
const b = Value.initComplex(1, -2);  // 1 - 2i
const prod = Value.mul(a, b);        // 8 - i
```

### Unit Operations

```zig
// Adding compatible units
const len1 = Value.initUnit(5.0, dimensions.length);
const len2 = Value.initUnit(3.0, dimensions.length);
const sum = Value.add(len1, len2);  // 8.0 [L]

// Unit multiplication
const velocity = Value.initUnit(10.0, dimensions.velocity);  // 10 m/s
const time = Value.initUnit(2.0, dimensions.time);          // 2 s
const distance = Value.mul(velocity, time);                  // 20 m [L]
```

### Matrix Operations

```zig
// Matrix * Scalar
const mat = Value.initMatrix(my_matrix);
const scaled = Value.mul(mat, Value.initNumber(2));

// Matrix * Matrix
const mat_a = Value.initMatrix(matrix_a);
const mat_b = Value.initMatrix(matrix_b);
const result = Value.mul(mat_a, mat_b);
```

## Error Handling

```zig
// Division by zero, type mismatches, etc. return error values
const div_by_zero = Value.div(
    Value.initNumber(10),
    Value.initNumber(0)
);
// Returns: { tag: .err, data: .{ .err = error_code } }

// Check for errors
if (result.isError()) {
    // Handle error
}
```

## Type Coercion

When mixing types in operations:

```zig
// Number is coerced to complex if other operand is complex
const num = Value.initNumber(5);
const cplx = Value.initComplex(2, 3);
const result = Value.add(num, cplx);  // 7 + 3i
```

## Usage Example

```zig
const allocator = std.testing.allocator;

fn evaluateWithMixedTypes() !void {
    var vm = try VM.init(allocator, 16);
    defer vm.deinit();
    
    // Set up variables
    try vm.setVariable(0, Value.initNumber(5));      // x = 5
    try vm.setVariable(1, Value.initComplex(2, 3));  // z = 2 + 3i
    
    // Expression combining numbers and complex
    // Result depends on operations
}
```

## Related Documentation

- [Overview](overview.md)
- [Bytecode Format](bytecode.md)
- [Virtual Machine and SIMD](vm.md)
