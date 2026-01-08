# Zig Cheatsheet (v0.15.2+ Reference)

This cheatsheet captures Zig conventions and syntax relevant to the MathZig project, targeting Zig 0.15.2 (dev). When in doubt, consult `lib/std` source or `libs/` dependencies.

## Core Syntax

### Variables
```zig
const x: i32 = 42;      // Immutable
var y: f64 = 3.14;      // Mutable
var z = @as(u32, 100);  // Type inference with cast
```

### Functions
```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}

// Error union return type
fn mightFail() !void {
    return error.Oops;
}
```

### Errors
```zig
const res = try mightFail(); // Propagate error
const res2 = mightFail() catch |err| {
    // Handle error
    return err; // or fallback
};
```

## Memory Management

### Allocators
Standard pattern: pass `allocator` as first argument to `init`.

```zig
const std = @import("std");

pub fn main() !void {
    // General Purpose Allocator (Debug/Dev)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Arena Allocator (Monotonic/Region)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // Frees everything at once
    const arena_alloc = arena.allocator();
}
```

### Arrays & Slices
```zig
// Dynamic Array
var list = std.ArrayList(u32).init(allocator);
defer list.deinit();
try list.append(1);

// Unmanaged Array (for struct embedding)
var list_un: std.ArrayListUnmanaged(u32) = .{};
defer list_un.deinit(allocator);
try list_un.append(allocator, 1);

// Slices
const slice: []u32 = list.items;
```

## Data Structures

### Structs
```zig
const Point = struct {
    x: f32,
    y: f32,

    // Methods
    pub fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }
};
```

### Enums & Unions
```zig
const Tag = enum {
    int,
    float,
};

const Value = union(Tag) {
    int: i32,
    float: f64,
};

// Switch with capture
switch (val) {
    .int => |i| std.debug.print("Int: {d}", .{i}),
    .float => |f| std.debug.print("Float: {d}", .{f}),
}
```

## Control Flow

### Loops
```zig
// For Loop with Index
const items = [_]i32{ 1, 2, 3 };
for (items, 0..) |item, i| {
    // ...
}

// While Loop
var i: usize = 0;
while (i < 10) : (i += 1) {
    // ...
}
```

### Defer & Errdefer
```zig
const ptr = try allocator.create(T);
errdefer allocator.destroy(ptr); // Only runs if function returns error later

try someOperation(); // If this fails, ptr is destroyed

return ptr; // Success, ptr survives
```

## Comptime & Generics

### Generic Types
```zig
fn List(comptime T: type) type {
    return struct {
        items: []T,
        // ...
    };
}
```

### Inline Loops
```zig
inline for (.{1, 2, 3}) |i| {
    // Unrolled at compile time
}
```

## Build System (build.zig)

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Modules
    const my_mod = b.createModule(.{
        .root_source_file = b.path("src/mod.zig"),
    });
    exe.root_module.addImport("my_mod", my_mod);

    b.installArtifact(exe);
}
```

## MathZig Specific Conventions

- **File Structure:**
  - `src/core/`: Base types (`Value`, `Matrix`).
  - `src/vm/`: Virtual Machine logic.
  - `tests/`: Unit and integration tests.
  
- **Testing:**
  - Use `std.testing.allocator` for leak detection in tests.
  - Test files often named `*.test.zig` or inside `tests/zig/`.
  
- **Optimizations:**
  - Check `is_wasm` constant for platform-specific paths.
  - Use `@Vector` for SIMD.
  - Prefer `ArrayListUnmanaged` inside structs to decouple allocator storage.

- **Dependencies:**
  - Check `build.zig.zon` for external dependencies.
  - Local libs in `libs/`.

## Common Pitfalls (Zig 0.15+)

- **String Literals:** `[]const u8`, null-terminated usually not guaranteed unless `[:0]const u8`.
- **Pointer Alignment:** `@alignCast`, `@ptrCast` strictness.
- **Result Location:** Zig functions often write directly to return result slot (RVO).
- **Shadowing:** Variable shadowing is a compile error.

## Zig 0.15.2 Breaking Changes

### File I/O - No `.print()` on File.Writer
The `File.Writer` returned by `file.writer(&buffer)` does NOT have a `.print()` method.
`std.fmt.format(writer, ...)` also fails due to missing `adaptToNewApi`.

```zig
// BROKEN in 0.15.2:
var w = file.writer(&buffer);
try w.print("value: {d}\n", .{42});  // ❌ No 'print' member

// CORRECT - use bufPrint then writeAll:
var buf: [256]u8 = undefined;
const line = std.fmt.bufPrint(&buf, "value: {d}\n", .{42}) catch return error.FormatError;
try file.writeAll(line);  // ✅ Works
```

### ArrayList.init() Removed
`std.ArrayList(T).init(allocator)` no longer exists. Use `ArrayListUnmanaged` pattern:

```zig
// BROKEN in 0.15.2:
var list = std.ArrayList([]const u8).init(allocator);  // ❌ No 'init' member
defer list.deinit();
try list.append(item);

// CORRECT - use ArrayListUnmanaged:
var list = std.ArrayListUnmanaged([]const u8){};  // ✅ Empty init
defer list.deinit(allocator);                      // Pass allocator to deinit
try list.append(allocator, item);                  // Pass allocator to append
```

### Empty Slice Literal
Initialize struct fields with empty slices using `&.{}`:

```zig
const expr: CompiledExpr = .{
    .code = code,
    .source_offsets = &.{},  // ✅ Empty slice literal
    .allocator = allocator,
};
```

## MathZig VM & FFI Findings

### VM Stack Size & Large Literals
Large literals (like matrices) are compiled by pushing all elements to the stack first. Ensure the VM stack size and `sp` type (e.g., `u16` instead of `u8`) can handle the total number of elements in your largest supported literal.

```zig
pub const VM = struct {
    stack: [4096]Value,
    sp: u16, 
    // ...
};
```

### FFI Thread Local State
When using FFI with thread-local variables (like `last_value`), remember that subsequent calls might overwrite state. If the JS side needs to hold onto a reference, ensure it calls `retain()` immediately.

### Matrix Data Layout
MathZig uses a flat `f64` array for matrix data with row-major storage. When comparing with JS libraries like MathJS (which uses nested arrays), flatten the JS arrays or use sum/determinant for quick validation.

### WASM AOT: Scratch Local Pattern
When compiling to WASM bytecode, use "scratch locals" to manage stack access. Because WASM is a stack machine, complex operations like `a && b` or bitwise logic require "parking" values temporarily to reach buried operands.

- Pre-allocate a set of typed locals (`f64`, `i32`, `i64`) at the start of the function.
- Reuse these locals across different instruction emissions.
- Use `local.set` to park a value and `local.get` to restore it after processing the other stack branch.


