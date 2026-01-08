const std = @import("std");
const builtin = @import("builtin");
const Series = @import("../timeseries/series.zig").Series;
const Predicate = @import("../timeseries/predicates.zig").Predicate;
const alignment = @import("../timeseries/alignment.zig");
const temporal = @import("../units/temporal.zig");
const live_handles = @import("../memory/live_handles.zig");

/// SIMD Vector size - 4 x f64 = 32 bytes (AVX/YMM compatible)
/// WASM SIMD128 is 2 x f64 (16 bytes)
pub const VectorLen = if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) 2 else 4;
pub const Vec = @Vector(VectorLen, f64);
pub const Vec4 = @Vector(4, f64); // Fixed 4-wide for 4x4 matrix kernels

/// Tag identifying the type of value
pub const ValueTag = enum(u8) {
    number, // f64
    complex, // Complex number (re + im*i)
    unit, // Quantity with unit
    matrix, // Dense matrix
    series, // Time series
    predicate, // Filter predicate
    string, // UTF-8 string
    boolean, // true/false
    function, // Function reference
    array, // Dynamic array of values
    record, // Record (object) with named fields
    slice, // Slice definition (start:end:step)
    undefined, // Undefined value
    null_val, // Null value
    err, // Error value
};

pub const Slice = struct {
    start: Value,
    end: Value,
    step: Value,
    allocator: std.mem.Allocator,
    ref_count: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, start: Value, end: Value, step: Value) !*Slice {
        const self = try allocator.create(Slice);
        start.retain();
        end.retain();
        step.retain();
        self.* = .{ .start = start, .end = end, .step = step, .allocator = allocator, .ref_count = 1 };
        return self;
    }

    pub fn retain(self: *Slice) void {
        _ = @atomicRmw(u32, &self.ref_count, .Add, 1, .seq_cst);
    }

    pub fn release(self: *Slice) void {
        if (@atomicRmw(u32, &self.ref_count, .Sub, 1, .seq_cst) == 1) {
            self.start.release();
            self.end.release();
            self.step.release();
            self.allocator.destroy(self);
        }
    }

    pub fn equals(self: *const Slice, other: *const Slice) bool {
        return self.start.equals(other.start) and self.end.equals(other.end) and self.step.equals(other.step);
    }
};

/// Complex number representation
pub const Complex = struct {
    re: f64,
    im: f64,

    pub fn init(re: f64, im: f64) Complex {
        return .{ .re = re, .im = im };
    }

    pub fn fromReal(re: f64) Complex {
        return .{ .re = re, .im = 0 };
    }

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub fn div(a: Complex, b: Complex) Complex {
        const denom = b.re * b.re + b.im * b.im;
        std.debug.assert(denom != 0);
        return .{
            .re = (a.re * b.re + a.im * b.im) / denom,
            .im = (a.im * b.re - a.re * b.im) / denom,
        };
    }

    pub fn abs(self: Complex) f64 {
        return @sqrt(self.re * self.re + self.im * self.im);
    }

    pub fn sqrt(self: Complex) Complex {
        const r = self.abs();
        const res_re = @sqrt((r + self.re) / 2.0);
        const res_im = (if (self.im >= 0) @as(f64, 1.0) else @as(f64, -1.0)) * @sqrt((r - self.re) / 2.0);
        return .{ .re = res_re, .im = res_im };
    }

    pub fn arg(self: Complex) f64 {
        return std.math.atan2(self.im, self.re);
    }

    pub fn conj(self: Complex) Complex {
        return .{ .re = self.re, .im = -self.im };
    }

    pub fn neg(self: Complex) Complex {
        return .{ .re = -self.re, .im = -self.im };
    }

    pub fn exp(self: Complex) Complex {
        const scale = @exp(self.re);
        return .{
            .re = scale * @cos(self.im),
            .im = scale * @sin(self.im),
        };
    }

    pub fn log(self: Complex) Complex {
        const mag = self.abs();
        std.debug.assert(mag > 0);
        return .{
            .re = @log(mag),
            .im = self.arg(),
        };
    }

    pub fn pow(base: Complex, exponent: Complex) Complex {
        // base^exponent = exp(exponent * log(base))
        // If base is 0, result is 0 (except 0^0 which is usually 1, but we'll stick to 0 for simplicity or handle it)
        if (base.re == 0 and base.im == 0) {
            if (exponent.re == 0 and exponent.im == 0) return .{ .re = 1, .im = 0 };
            return .{ .re = 0, .im = 0 };
        }
        return base.log().mul(exponent).exp();
    }
};

const Dimensions = @import("../units/unit_registry.zig").Dimensions;

/// Immutable, globally interned unit metadata (everything about a unit
/// except its magnitude). UnitValue keeps only the hot f64 magnitude inline
/// plus a pointer to one of these, which shrinks Value from 56 to 24 bytes.
/// Interned descriptors live for the process lifetime; the set of distinct
/// descriptors is small (registry units plus derived combinations), so this
/// is bounded.
pub const UnitInfo = struct {
    scale: f64 = 1.0, // Scale factor used to reach the normalized value
    offset: f64 = 0, // Offset for units like Celsius (273.15)
    dimensions: Dimensions = .{},
    name: ?[]const u8 = null, // Original unit name if available

    /// Dimensionless, unnamed descriptor; also the OOM fallback.
    pub const scalar: UnitInfo = .{};

    const InternKey = struct {
        scale_bits: u64,
        offset_bits: u64,
        dimensions: Dimensions,
        /// Pointer of the interned name (content-interned first, so pointer
        /// equality is content equality); 0 for unnamed.
        name_ptr: usize,
    };

    const is_single_threaded = @import("builtin").single_threaded or
        @import("builtin").cpu.arch.isWasm();

    var intern_mutex: std.atomic.Mutex = .unlocked;
    var intern_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var name_table: std.StringHashMapUnmanaged([]const u8) = .{};
    var info_table: std.AutoHashMapUnmanaged(InternKey, *const UnitInfo) = .{};

    /// Intern a unit descriptor. Never fails: on OOM the dimensionless
    /// fallback is returned (matching the historical "name allocation failed
    /// -> drop the name" degradation, just stronger).
    pub fn intern(scale: f64, offset: f64, dimensions: Dimensions, name: ?[]const u8) *const UnitInfo {
        if (!is_single_threaded) {
            while (!intern_mutex.tryLock()) std.Thread.yield() catch {};
        }
        defer if (!is_single_threaded) intern_mutex.unlock();

        const alloc = intern_arena.allocator();

        // Intern the name content first so the info key can use its pointer.
        var interned_name: ?[]const u8 = null;
        if (name) |n| {
            const gop = name_table.getOrPut(alloc, n) catch return &scalar;
            if (!gop.found_existing) {
                const copy = alloc.dupe(u8, n) catch {
                    _ = name_table.remove(n);
                    return &scalar;
                };
                gop.key_ptr.* = copy;
                gop.value_ptr.* = copy;
            }
            interned_name = gop.value_ptr.*;
        }

        const key = InternKey{
            .scale_bits = @bitCast(scale),
            .offset_bits = @bitCast(offset),
            .dimensions = dimensions,
            .name_ptr = if (interned_name) |n| @intFromPtr(n.ptr) else 0,
        };
        const gop = info_table.getOrPut(alloc, key) catch return &scalar;
        if (!gop.found_existing) {
            const info = alloc.create(UnitInfo) catch {
                _ = info_table.remove(key);
                return &scalar;
            };
            info.* = .{
                .scale = scale,
                .offset = offset,
                .dimensions = dimensions,
                .name = interned_name,
            };
            gop.value_ptr.* = info;
        }
        return gop.value_ptr.*;
    }
};

/// Unit value - magnitude plus interned unit descriptor
pub const UnitValue = struct {
    value: f64, // Normalized value in base SI units
    info: *const UnitInfo,

    pub fn init(value: f64, dimensions: Dimensions) UnitValue {
        return .{ .value = value, .info = UnitInfo.intern(1.0, 0, dimensions, null) };
    }

    pub fn initFull(value: f64, scale: f64, offset: f64, dimensions: Dimensions) UnitValue {
        return .{ .value = value, .info = UnitInfo.intern(scale, offset, dimensions, null) };
    }

    pub fn initWithName(value: f64, scale: f64, dimensions: Dimensions, name: []const u8) UnitValue {
        return .{ .value = value, .info = UnitInfo.intern(scale, 0, dimensions, name) };
    }
};

/// Matrix stored as row-major flat array with support for strides (views)
/// Data is 32-byte aligned for SIMD operations (AVX/YMM compatible)
pub const Matrix = struct {
    /// Alignment requirement for SIMD operations (32 bytes = 4 x f64)
    /// log2(32) = 5, so we use @enumFromInt(5) for std.mem.Alignment
    pub const simd_alignment: std.mem.Alignment = @enumFromInt(5);
    pub const simd_alignment_bytes: usize = 32;

    magic: u64 = 0x4D41545249583031, // "MATRIX01"
    data: []align(simd_alignment_bytes) f64,
    rows: u32,
    cols: u32,
    stride: u32, // Number of elements to skip to get to the next row
    offset: usize = 0, // Offset into data array
    allocator: std.mem.Allocator,
    owns_data: bool = true,
    ref_count: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !*Matrix {
        const self = try allocator.create(Matrix);
        errdefer allocator.destroy(self);
        // Allocate with 32-byte alignment for SIMD
        const data = try allocator.alignedAlloc(f64, simd_alignment, @as(usize, rows) * @as(usize, cols));
        self.* = .{
            .data = data,
            .rows = rows,
            .cols = cols,
            .stride = cols,
            .allocator = allocator,
            .owns_data = true,
            .ref_count = 1,
        };
        @memset(self.data, 0);
        live_handles.incMatrix();
        return self;
    }

    pub fn retain(self: *Matrix) *Matrix {
        std.debug.assert(self.magic == 0x4D41545249583031);
        std.debug.assert(self.ref_count > 0);
        _ = @atomicRmw(u32, &self.ref_count, .Add, 1, .seq_cst);
        return self;
    }

    pub fn release(self: *Matrix) void {
        std.debug.assert(self.magic == 0x4D41545249583031);
        std.debug.assert(self.ref_count > 0);
        if (@atomicRmw(u32, &self.ref_count, .Sub, 1, .seq_cst) == 1) {
            self.deinit();
        }
    }

    pub fn initView(rows: u32, cols: u32, stride: u32, offset: usize, data: []align(simd_alignment_bytes) f64, allocator: std.mem.Allocator) !*Matrix {
        const self = try allocator.create(Matrix);
        self.* = .{
            .data = data,
            .rows = rows,
            .cols = cols,
            .stride = stride,
            .offset = offset,
            .allocator = allocator,
            .owns_data = false,
            .ref_count = 1,
        };
        live_handles.incMatrix();
        return self;
    }

    pub fn deinit(self: *Matrix) void {
        std.debug.assert(self.magic == 0x4D41545249583031);
        self.magic = 0; // Mark as freed
        if (self.owns_data) {
            self.allocator.free(self.data);
        }
        self.allocator.destroy(self);
        live_handles.decMatrix();
    }

    /// Get a pointer to the start of the matrix data (aligned for SIMD)
    pub fn dataPtr(self: *const Matrix) [*]align(simd_alignment_bytes) f64 {
        std.debug.assert(self.magic == 0x4D41545249583031);
        return self.data.ptr + self.offset;
    }

    pub fn get(self: Matrix, row: u32, col: u32) f64 {
        std.debug.assert(self.magic == 0x4D41545249583031);
        return self.data[self.offset + row * self.stride + col];
    }

    pub fn equals(self: *const Matrix, other: *const Matrix) bool {
        std.debug.assert(self.magic == 0x4D41545249583031);
        std.debug.assert(other.magic == 0x4D41545249583031);
        if (self.rows != other.rows or self.cols != other.cols) return false;
        var r: u32 = 0;
        while (r < self.rows) : (r += 1) {
            var c: u32 = 0;
            while (c < self.cols) : (c += 1) {
                if (self.get(r, c) != other.get(r, c)) return false;
            }
        }
        return true;
    }

    pub fn set(self: *Matrix, row: u32, col: u32, val: f64) void {
        std.debug.assert(self.magic == 0x4D41545249583031);
        self.data[self.offset + @as(usize, row) * @as(usize, self.stride) + @as(usize, col)] = val;
    }

    pub fn reshape(self: *Matrix, rows: u32, cols: u32) !void {
        std.debug.assert(self.magic == 0x4D41545249583031);
        if (rows * cols != self.rows * self.cols) return error.MismatchedDimensions;
        self.rows = rows;
        self.cols = cols;
        self.stride = cols;
    }

    pub fn flatten(self: *Matrix) !void {
        std.debug.assert(self.magic == 0x4D41545249583031);
        try self.reshape(self.rows * self.cols, 1);
    }

    pub fn getDiagonal(self: *const Matrix, allocator: std.mem.Allocator) !*Matrix {
        std.debug.assert(self.magic == 0x4D41545249583031);
        const n = @min(self.rows, self.cols);
        const res = try Matrix.init(allocator, n, 1);
        for (0..n) |i| {
            res.data[i] = self.get(@intCast(i), @intCast(i));
        }
        return res;
    }
};

/// String handle (pointer + length)
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

/// Function handle for builtin and user-defined functions
pub const FunctionHandle = struct {
    tag: enum { builtin, user },
    id: u32, // Index into function table (builtin or context.functions)
    arity: u8, // Number of parameters
    user_func: ?*const @import("../vm/bytecode.zig").UserFunction = null,
};

/// Record (object) with named fields - key-value pairs for multi-output indicators
pub const Record = struct {
    magic: u64 = 0xDEADC0DE,
    /// Map of field names to values
    fields: std.StringHashMap(Value),
    allocator: std.mem.Allocator,
    key_allocator: std.mem.Allocator,
    ref_count: u32 = 1,

    /// Initialize a new empty Record
    pub fn init(allocator: std.mem.Allocator, key_allocator: std.mem.Allocator) !*Record {
        const self = try allocator.create(Record);
        self.* = .{
            .magic = 0xDEADC0DE,
            .fields = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .key_allocator = key_allocator,
            .ref_count = 1,
        };
        live_handles.incRecord();
        return self;
    }

    /// Initialize a Record with initial capacity
    pub fn initCapacity(allocator: std.mem.Allocator, key_allocator: std.mem.Allocator, capacity: u32) !*Record {
        const self = try allocator.create(Record);
        errdefer allocator.destroy(self);
        self.* = .{
            .magic = 0xDEADC0DE,
            .fields = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .key_allocator = key_allocator,
            .ref_count = 1,
        };
        try self.fields.ensureTotalCapacity(@intCast(capacity));
        live_handles.incRecord();
        return self;
    }

    pub fn retain(self: *Record) *Record {
        std.debug.assert(self.magic == 0xDEADC0DE);
        std.debug.assert(self.ref_count > 0);
        _ = @atomicRmw(u32, &self.ref_count, .Add, 1, .seq_cst);
        return self;
    }

    pub fn release(self: *Record) void {
        std.debug.assert(self.magic == 0xDEADC0DE);
        std.debug.assert(self.ref_count > 0);
        if (@atomicRmw(u32, &self.ref_count, .Sub, 1, .seq_cst) == 1) {
            self.deinit();
        }
    }

    /// Deinitialize and free the Record and all its contents
    pub fn deinit(self: *Record) void {
        std.debug.assert(self.magic == 0xDEADC0DE);
        self.magic = 0; // Mark as freed
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            // Free the key (string) using key_allocator
            self.key_allocator.free(entry.key_ptr.*);

            // Recursively release members
            var value = entry.value_ptr.*;

            if (value.tag == .array) {
                for (value.data.array.items) |*item| {
                    item.release();
                }
                value.data.array.deinit(self.allocator);
                self.allocator.destroy(value.data.array);
            } else {
                value.release();
            }
        }
        self.fields.deinit();
        self.allocator.destroy(self);
        live_handles.decRecord();
    }

    pub fn get(self: *const Record, key: []const u8) ?Value {
        std.debug.assert(self.magic == 0xDEADC0DE);
        return self.fields.get(key);
    }

    pub fn equals(self: *const Record, other: *const Record) bool {
        if (self.fields.count() != other.fields.count()) return false;
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            const other_val = other.fields.get(entry.key_ptr.*) orelse return false;
            if (!entry.value_ptr.*.equals(other_val)) return false;
        }
        return true;
    }

    /// Set a field value (takes ownership of the key string)
    pub fn set(self: *Record, key: []const u8, value: Value) !void {
        std.debug.assert(self.magic == 0xDEADC0DE);
        // Check if key already exists
        const gop = try self.fields.getOrPut(key);
        if (!gop.found_existing) {
            // Key is new, store a copy in key_allocator
            gop.key_ptr.* = try self.key_allocator.dupe(u8, key);
        } else {
            // Key exists, free the old key. We also release the old value.
            self.key_allocator.free(gop.key_ptr.*);
            gop.key_ptr.* = try self.key_allocator.dupe(u8, key);
            gop.value_ptr.*.release();
        }
        gop.value_ptr.* = value;
        value.retain();
    }

    /// Set a field value (takes ownership of the key string)
    pub fn setOwned(self: *Record, key: []const u8, value: Value) !void {
        std.debug.assert(self.magic == 0xDEADC0DE);
        const gop = try self.fields.getOrPut(key);
        if (gop.found_existing) {
            self.key_allocator.free(gop.key_ptr.*);
            gop.value_ptr.*.release();
        }
        gop.key_ptr.* = try self.key_allocator.dupe(u8, key);
        gop.value_ptr.* = value;
        value.retain();
    }

    /// Check if a field exists
    pub fn has(self: *const Record, key: []const u8) bool {
        std.debug.assert(self.magic == 0xDEADC0DE);
        return self.fields.contains(key);
    }

    /// Get the number of fields in the record
    pub fn len(self: *const Record) usize {
        std.debug.assert(self.magic == 0xDEADC0DE);
        return self.fields.count();
    }

    /// Get all field names
    pub fn keys(self: *const Record, allocator: std.mem.Allocator) ![][]const u8 {
        std.debug.assert(self.magic == 0xDEADC0DE);
        const field_names = try allocator.alloc([]const u8, self.fields.count());
        var i: usize = 0;
        var iter = self.fields.keyIterator();
        while (iter.next()) |key| {
            field_names[i] = try allocator.dupe(u8, key.*);
            i += 1;
        }
        return field_names;
    }
};

/// The core Value type - a tagged union representing any mathzig value
/// Euclidean modulo (`a - |b|*floor(a/|b|)`, result always in [0, |b|)).
/// This is the engine's spec'd `%` semantics (tests/ts/parity/mathjs_unit/
/// arithmetic_mod.test.ts asserts -10 % 4 == 2 AND 10 % -4 == 2) and what
/// the AOT fmod bodies implement. Zig's float `@mod` is unspecified for a
/// negative divisor, so it must not be used for user math.
pub fn euclideanMod(a: f64, b: f64) f64 {
    if (b == 0) return std.math.nan(f64);
    const m = @abs(b);
    return a - m * @floor(a / m);
}

pub const Value = struct {
    tag: ValueTag,
    data: Data,

    pub const Data = union {
        number: f64,
        complex: Complex,
        unit: UnitValue,
        matrix: *Matrix,
        series: *Series,
        predicate: *const Predicate,
        string: StringHandle,
        boolean: bool,
        function: FunctionHandle,
        array: *std.ArrayList(Value),
        record: *Record,
        slice: *Slice,
        undefined: void,
        null_val: void,
        err: u32, // Error code
    };

    // Constructors
    pub fn initNumber(n: f64) Value {
        return .{ .tag = .number, .data = .{ .number = n } };
    }

    pub fn initComplex(re: f64, im: f64) Value {
        return .{ .tag = .complex, .data = .{ .complex = Complex.init(re, im) } };
    }

    pub fn initBoolean(b: bool) Value {
        return .{ .tag = .boolean, .data = .{ .boolean = b } };
    }

    pub fn initUnit(value: f64, dimensions: Dimensions) Value {
        return .{ .tag = .unit, .data = .{ .unit = UnitValue.init(value, dimensions) } };
    }

    pub fn initUnitFull(value: f64, scale: f64, offset: f64, dimensions: Dimensions, name: ?[]const u8) Value {
        return .{ .tag = .unit, .data = .{ .unit = .{
            .value = value,
            .info = UnitInfo.intern(scale, offset, dimensions, name),
        } } };
    }

    /// Build a unit value reusing an already-interned descriptor (no intern
    /// table lookup).
    pub fn initUnitWithInfo(value: f64, info: *const UnitInfo) Value {
        return .{ .tag = .unit, .data = .{ .unit = .{ .value = value, .info = info } } };
    }

    pub fn initUserFunction(f: *const @import("../vm/bytecode.zig").UserFunction) Value {
        return .{
            .tag = .function,
            .data = .{
                .function = .{
                    .tag = .user,
                    .id = 0, // Not used when user_func is present
                    .arity = @intCast(f.params.len),
                    .user_func = f,
                },
            },
        };
    }

    pub fn initMatrix(m: *Matrix) Value {
        return .{ .tag = .matrix, .data = .{ .matrix = m } };
    }

    pub fn initSeries(s: *Series) Value {
        return .{ .tag = .series, .data = .{ .series = s } };
    }

    pub fn initPredicate(p: *const Predicate) Value {
        return .{ .tag = .predicate, .data = .{ .predicate = p } };
    }

    pub fn initUndefined() Value {
        return .{ .tag = .undefined, .data = .{ .undefined = {} } };
    }

    pub fn initNull() Value {
        return .{ .tag = .null_val, .data = .{ .null_val = {} } };
    }

    pub fn initError(code: u32) Value {
        return .{ .tag = .err, .data = .{ .err = code } };
    }

    pub fn getPointer(self: *const Value) ?*anyopaque {
        return switch (self.tag) {
            .matrix => self.data.matrix,
            .series => self.data.series,
            .record => self.data.record,
            .string => @constCast(self.data.string.ptr),
            .predicate => @constCast(self.data.predicate),
            .array => self.data.array,
            .complex => @constCast(&self.data.complex),
            .unit => @constCast(&self.data.unit),
            .boolean => @constCast(&self.data.boolean),
            .number => @constCast(&self.data.number),
            else => null,
        };
    }

    /// Deinitialize a value (for array elements)
    pub fn deinitValue(self: *Value, allocator: std.mem.Allocator) void {
        self.releaseWithAllocator(allocator);
    }

    pub fn retain(self: Value) void {
        switch (self.tag) {
            .matrix => {
                std.debug.assert(self.data.matrix.magic == 0x4D41545249583031);
                _ = self.data.matrix.retain();
            },
            .series => {
                std.debug.assert(self.data.series.magic == 0x5345524945533031);
                _ = self.data.series.retain();
            },
            .record => {
                std.debug.assert(self.data.record.magic == 0xDEADC0DE);
                _ = self.data.record.retain();
            },
            .array => {
                for (self.data.array.items) |*item| {
                    item.retain();
                }
            },
            .slice => {
                self.data.slice.retain();
            },
            else => {},
        }
    }

    pub fn release(self: Value) void {
        switch (self.tag) {
            .matrix => {
                std.debug.assert(self.data.matrix.magic == 0x4D41545249583031);
                self.data.matrix.release();
            },
            .series => {
                std.debug.assert(self.data.series.magic == 0x5345524945533031);
                self.data.series.release();
            },
            .record => {
                std.debug.assert(self.data.record.magic == 0xDEADC0DE);
                self.data.record.release();
            },
            .array => {
                for (self.data.array.items) |*item| {
                    item.release();
                }
            },
            .slice => {
                self.data.slice.release();
            },
            else => {},
        }
    }

    /// Release value. VM intermediate tracking handles its own cleanup.
    pub fn releaseWithVM(self: Value, vm: anytype) void {
        _ = vm;
        self.release();
    }

    pub fn releaseWithAllocator(self: Value, allocator: std.mem.Allocator) void {
        switch (self.tag) {
            .matrix => self.data.matrix.release(),
            .series => self.data.series.release(),
            .record => self.data.record.release(),
            .array => {
                for (self.data.array.items) |*item| {
                    item.release();
                }
            },
            .slice => self.data.slice.release(),
            .string => allocator.free(@constCast(self.data.string.ptr[0..self.data.string.len])),
            else => {},
        }
    }

    pub fn initRecord(r: *Record) Value {
        return .{ .tag = .record, .data = .{ .record = r } };
    }

    pub fn initSlice(s: *Slice) Value {
        return .{ .tag = .slice, .data = .{ .slice = s } };
    }

    // Type checks
    pub fn isNumber(self: Value) bool {
        return self.tag == .number;
    }

    pub fn isComplex(self: Value) bool {
        return self.tag == .complex;
    }

    pub fn isNumeric(self: Value) bool {
        return self.tag == .number or self.tag == .complex;
    }

    pub fn isUnit(self: Value) bool {
        return self.tag == .unit;
    }

    pub fn isMatrix(self: Value) bool {
        return self.tag == .matrix;
    }

    pub fn isSeries(self: Value) bool {
        return self.tag == .series;
    }

    pub fn isPredicate(self: Value) bool {
        return self.tag == .predicate;
    }

    pub fn isError(self: Value) bool {
        return self.tag == .err;
    }

    pub fn isRecord(self: Value) bool {
        return self.tag == .record;
    }

    // Conversions
    pub fn toNumber(self: Value) ?f64 {
        return switch (self.tag) {
            .number => self.data.number,
            .boolean => if (self.data.boolean) @as(f64, 1) else @as(f64, 0),
            .unit => self.data.unit.value,
            .matrix => blk: {
                std.debug.assert(self.data.matrix.magic == 0x4D41545249583031);
                break :blk if (self.data.matrix.data.len > 0) self.data.matrix.data[0] else null;
            },
            .series => blk: {
                std.debug.assert(self.data.series.magic == 0x5345524945533031);
                break :blk if (self.data.series.len > 0) @import("../timeseries/aggregations.zig").twa(self.data.series, null) else null;
            },
            else => null,
        };
    }

    pub fn toSeries(self: Value) ?*Series {
        return switch (self.tag) {
            .series => self.data.series,
            else => null,
        };
    }

    pub fn toComplex(self: Value) ?Complex {
        return switch (self.tag) {
            .number => Complex.fromReal(self.data.number),
            .complex => self.data.complex,
            else => null,
        };
    }

    pub fn toTimestamp(self: Value) ?f64 {
        return switch (self.tag) {
            .number => self.data.number,
            .unit => self.data.unit.value,
            .string => temporal.parseTimestamp(self.data.string.toSlice()) catch null,
            else => null,
        };
    }

    pub fn equals(self: Value, other: Value) bool {
        // Handle boolean-number duality: fast-path VM represents booleans as 1.0/0.0
        if (self.tag != other.tag) {
            // Check for number-boolean cross-comparison
            if (self.tag == .number and other.tag == .boolean) {
                const bool_as_num: f64 = if (other.data.boolean) 1.0 else 0.0;
                return std.math.approxEqAbs(f64, self.data.number, bool_as_num, 1e-9);
            }
            if (self.tag == .boolean and other.tag == .number) {
                const bool_as_num: f64 = if (self.data.boolean) 1.0 else 0.0;
                return std.math.approxEqAbs(f64, bool_as_num, other.data.number, 1e-9);
            }
            return false;
        }
        return switch (self.tag) {
            .number => if (std.math.isNan(self.data.number) and std.math.isNan(other.data.number)) true else std.math.approxEqAbs(f64, self.data.number, other.data.number, 1e-9),
            .boolean => self.data.boolean == other.data.boolean,
            .complex => std.math.approxEqAbs(f64, self.data.complex.re, other.data.complex.re, 1e-9) and std.math.approxEqAbs(f64, self.data.complex.im, other.data.complex.im, 1e-9),
            .string => std.mem.eql(u8, self.data.string.toSlice(), other.data.string.toSlice()),
            .unit => std.math.approxEqAbs(f64, self.data.unit.value, other.data.unit.value, 1e-9) and self.data.unit.info.dimensions.equals(other.data.unit.info.dimensions),
            .matrix => blk: {
                std.debug.assert(self.data.matrix.magic == 0x4D41545249583031);
                std.debug.assert(other.data.matrix.magic == 0x4D41545249583031);
                break :blk self.data.matrix.equals(other.data.matrix);
            },
            .record => blk: {
                std.debug.assert(self.data.record.magic == 0xDEADC0DE);
                std.debug.assert(other.data.record.magic == 0xDEADC0DE);
                break :blk self.data.record.equals(other.data.record);
            },
            .slice => self.data.slice.equals(other.data.slice),
            .series => blk: {
                std.debug.assert(self.data.series.magic == 0x5345524945533031);
                std.debug.assert(other.data.series.magic == 0x5345524945533031);
                // Series equality is not yet fully implemented for data contents,
                // but we assert structure validity here.
                break :blk self.data.series == other.data.series;
            },
            .undefined => true,
            .err => self.data.err == other.data.err,
            else => false,
        };
    }

    // Arithmetic operations
    pub fn add(a: Value, b: Value) Value {
        // Number + Number
        if (a.tag == .number and b.tag == .number) {
            return initNumber(a.data.number + b.data.number);
        }

        // Unit + Unit (must have same dimensions)
        if (a.tag == .unit and b.tag == .unit) {
            if (a.data.unit.info.dimensions.equals(b.data.unit.info.dimensions)) {
                return .{ .tag = .unit, .data = .{ .unit = UnitValue.init(
                    a.data.unit.value + b.data.unit.value,
                    a.data.unit.info.dimensions,
                ) } };
            }
            return initError(2); // Dimension mismatch
        }

        // Number + Unit: treat number as having same dimensions as unit
        if (a.tag == .number and b.tag == .unit) {
            return .{ .tag = .unit, .data = .{ .unit = UnitValue.init(
                a.data.number + b.data.unit.value,
                b.data.unit.info.dimensions,
            ) } };
        }
        if (a.tag == .unit and b.tag == .number) {
            return .{ .tag = .unit, .data = .{ .unit = UnitValue.init(
                a.data.unit.value + b.data.number,
                a.data.unit.info.dimensions,
            ) } };
        }

        // Matrix + Matrix
        if (a.tag == .matrix and b.tag == .matrix) {
            const ma = a.data.matrix;
            const mb = b.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            std.debug.assert(mb.magic == 0x4D41545249583031);
            if (ma.rows == mb.rows and ma.cols == mb.cols) {
                const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
                for (0..ma.data.len) |i| {
                    res.data[i] = ma.data[i] + mb.data[i];
                }
                return .{ .tag = .matrix, .data = .{ .matrix = res } };
            }
            return initError(2);
        }

        // Matrix + Scalar (Broadcasting)
        if (a.tag == .matrix and b.tag == .number) {
            const ma = a.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
            for (0..ma.data.len) |i| res.data[i] = ma.data[i] + b.data.number;
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }
        if (a.tag == .number and b.tag == .matrix) {
            const mb = b.data.matrix;
            std.debug.assert(mb.magic == 0x4D41545249583031);
            const res = Matrix.init(mb.allocator, mb.rows, mb.cols) catch return initError(3);
            for (0..mb.data.len) |i| res.data[i] = a.data.number + mb.data[i];
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }

        // Series + Series
        if (a.tag == .series and b.tag == .series) {
            const sa = a.data.series;
            const sb = b.data.series;
            std.debug.assert(sa.magic == 0x5345524945533031);
            std.debug.assert(sb.magic == 0x5345524945533031);
            const aligned = alignment.alignUnion(sa, sb, sa.allocator) catch return initError(3);
            const res_a = aligned.@"0";
            const res_b = aligned.@"1";
            // Important: these aligned series are TEMPORARY and must be freed.
            defer res_a.release();
            defer res_b.release();

            const res = Series.init(sa.allocator, res_a.len, sa.sample_mode, sa.dimensions) catch return initError(3);
            @memcpy(res.timestamps, res_a.timestamps);
            for (0..res_a.len) |i| {
                res.values[i] = res_a.values[i] + res_b.values[i];
                res.validity[i] = res_a.validity[i] & res_b.validity[i];
            }
            res.validate() catch {};
            return initSeries(res);
        }

        // Series + Scalar
        if (a.tag == .series and b.tag == .number) {
            const s = a.data.series;
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            for (0..s.len) |i| res.values[i] = s.values[i] + b.data.number;
            res.validate() catch {};
            return initSeries(res);
        }
        if (a.tag == .number and b.tag == .series) {
            const s = b.data.series;
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            for (0..s.len) |i| res.values[i] = a.data.number + s.values[i];
            res.validate() catch {};
            return initSeries(res);
        }

        // Complex arithmetic
        if (a.isNumeric() and b.isNumeric()) {
            const ac = a.toComplex() orelse return initError(1);
            const bc = b.toComplex() orelse return initError(1);
            const result = ac.add(bc);
            if (result.im == 0) {
                return initNumber(result.re);
            }
            return .{ .tag = .complex, .data = .{ .complex = result } };
        }

        return initError(1); // Type error
    }

    pub fn sub(a: Value, b: Value) Value {
        if (a.tag == .number and b.tag == .number) {
            return initNumber(a.data.number - b.data.number);
        }

        if (a.tag == .unit and b.tag == .unit) {
            if (a.data.unit.info.dimensions.equals(b.data.unit.info.dimensions)) {
                return .{ .tag = .unit, .data = .{ .unit = UnitValue.init(
                    a.data.unit.value - b.data.unit.value,
                    a.data.unit.info.dimensions,
                ) } };
            }
            return initError(2);
        }

        // Number - Unit: treat number as having same dimensions as unit
        if (a.tag == .number and b.tag == .unit) {
            return .{ .tag = .unit, .data = .{ .unit = UnitValue.init(
                a.data.number - b.data.unit.value,
                b.data.unit.info.dimensions,
            ) } };
        }
        if (a.tag == .unit and b.tag == .number) {
            return .{ .tag = .unit, .data = .{ .unit = UnitValue.init(
                a.data.unit.value - b.data.number,
                a.data.unit.info.dimensions,
            ) } };
        }

        if (a.tag == .matrix and b.tag == .matrix) {
            const ma = a.data.matrix;
            const mb = b.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            std.debug.assert(mb.magic == 0x4D41545249583031);
            if (ma.rows == mb.rows and ma.cols == mb.cols) {
                const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
                for (0..ma.data.len) |i| {
                    res.data[i] = ma.data[i] - mb.data[i];
                }
                return .{ .tag = .matrix, .data = .{ .matrix = res } };
            }
            return initError(2);
        }

        // Matrix - Scalar (Broadcasting)
        if (a.tag == .matrix and b.tag == .number) {
            const ma = a.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
            for (0..ma.data.len) |i| res.data[i] = ma.data[i] - b.data.number;
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }
        if (a.tag == .number and b.tag == .matrix) {
            const mb = b.data.matrix;
            std.debug.assert(mb.magic == 0x4D41545249583031);
            const res = Matrix.init(mb.allocator, mb.rows, mb.cols) catch return initError(3);
            for (0..mb.data.len) |i| res.data[i] = a.data.number - mb.data[i];
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }

        // Series - Series
        if (a.tag == .series and b.tag == .series) {
            const sa = a.data.series;
            const sb = b.data.series;
            std.debug.assert(sa.magic == 0x5345524945533031);
            std.debug.assert(sb.magic == 0x5345524945533031);
            const aligned = alignment.alignUnion(sa, sb, sa.allocator) catch return initError(3);
            const res_a = aligned.@"0";
            const res_b = aligned.@"1";
            defer res_a.release();
            defer res_b.release();

            const res = Series.init(sa.allocator, res_a.len, sa.sample_mode, sa.dimensions) catch return initError(3);
            @memcpy(res.timestamps, res_a.timestamps);
            for (0..res_a.len) |i| {
                res.values[i] = res_a.values[i] - res_b.values[i];
                res.validity[i] = res_a.validity[i] & res_b.validity[i];
            }
            res.validate() catch {};
            return initSeries(res);
        }

        // Series - Scalar
        if (a.tag == .series and b.tag == .number) {
            const s = a.data.series;
            std.debug.assert(s.magic == 0x5345524945533031);
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            for (0..s.len) |i| res.values[i] = s.values[i] - b.data.number;
            res.validate() catch {};
            return initSeries(res);
        }
        if (a.tag == .number and b.tag == .series) {
            const s = b.data.series;
            std.debug.assert(s.magic == 0x5345524945533031);
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            for (0..s.len) |i| res.values[i] = a.data.number - s.values[i];
            res.validate() catch {};
            return initSeries(res);
        }

        if (a.isNumeric() and b.isNumeric()) {
            const ac = a.toComplex() orelse return initError(1);
            const bc = b.toComplex() orelse return initError(1);
            const result = ac.sub(bc);
            if (result.im == 0) {
                return initNumber(result.re);
            }
            return .{ .tag = .complex, .data = .{ .complex = result } };
        }

        return initError(1);
    }

    pub fn mul(a: Value, b: Value, allocator: ?std.mem.Allocator) Value {
        // Unit names are interned globally now; the allocator parameter is
        // kept for API compatibility.
        _ = allocator;
        if (a.tag == .number and b.tag == .number) {
            return initNumber(a.data.number * b.data.number);
        }

        // Matrix * Scalar
        if (a.tag == .matrix and b.tag == .number) {
            const ma = a.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
            for (0..ma.data.len) |i| res.data[i] = ma.data[i] * b.data.number;
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }
        if (a.tag == .number and b.tag == .matrix) {
            const mb = b.data.matrix;
            std.debug.assert(mb.magic == 0x4D41545249583031);
            const res = Matrix.init(mb.allocator, mb.rows, mb.cols) catch return initError(3);
            for (0..mb.data.len) |i| res.data[i] = a.data.number * mb.data[i];
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }

        // Matrix * Unit
        if (a.tag == .matrix and b.tag == .unit) {
            const ma = a.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            const u = b.data.unit;
            const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
            // We scale by the normalized value of the unit
            for (0..ma.data.len) |i| res.data[i] = ma.data[i] * u.value;
            // Result is a matrix, but ideally it should be a "Matrix with Units"
            // For now we just return the scaled matrix as per current behavior
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }
        if (a.tag == .unit and b.tag == .matrix) {
            const mb = b.data.matrix;
            std.debug.assert(mb.magic == 0x4D41545249583031);
            const u = a.data.unit;
            const res = Matrix.init(mb.allocator, mb.rows, mb.cols) catch return initError(3);
            for (0..mb.data.len) |i| res.data[i] = u.value * mb.data[i];
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }

        // Series * Series
        if (a.tag == .series and b.tag == .series) {
            const sa = a.data.series;
            const sb = b.data.series;
            std.debug.assert(sa.magic == 0x5345524945533031);
            std.debug.assert(sb.magic == 0x5345524945533031);
            const aligned = alignment.alignUnion(sa, sb, sa.allocator) catch return initError(3);
            const res_a = aligned.@"0";
            const res_b = aligned.@"1";
            defer res_a.release();
            defer res_b.release();

            const res = Series.init(sa.allocator, res_a.len, sa.sample_mode, sa.dimensions) catch return initError(3);
            @memcpy(res.timestamps, res_a.timestamps);
            for (0..res_a.len) |i| {
                res.values[i] = res_a.values[i] * res_b.values[i];
                res.validity[i] = res_a.validity[i] & res_b.validity[i];
            }
            res.validate() catch {};
            return initSeries(res);
        }

        // Series * Scalar
        if (a.tag == .series and b.tag == .number) {
            const s = a.data.series;
            std.debug.assert(s.magic == 0x5345524945533031);
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            for (0..s.len) |i| res.values[i] = s.values[i] * b.data.number;
            res.validate() catch {};
            return initSeries(res);
        }
        if (a.tag == .number and b.tag == .series) {
            const s = b.data.series;
            std.debug.assert(s.magic == 0x5345524945533031);
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            for (0..s.len) |i| res.values[i] = a.data.number * s.values[i];
            res.validate() catch {};
            return initSeries(res);
        }

        // Matrix * Matrix (Matrix Multiplication)
        if (a.tag == .matrix and b.tag == .matrix) {
            const ma = a.data.matrix;
            const mb = b.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            std.debug.assert(mb.magic == 0x4D41545249583031);
            if (ma.cols == mb.rows) {
                const res = Matrix.init(ma.allocator, ma.rows, mb.cols) catch return initError(3);
                const kernels = @import("../functions/matrix_kernels.zig");
                kernels.gemm(ma.rows, ma.cols, mb.cols, ma.data, ma.stride, mb.data, mb.stride, res.data, res.stride);
                return .{ .tag = .matrix, .data = .{ .matrix = res } };
            }
            return initError(2);
        }

        // Unit * Scalar: only the magnitude changes, the descriptor is reused
        if (a.tag == .unit and b.tag == .number) {
            // Scale only the magnitude part, then add back offset
            const mag = a.data.unit.value - a.data.unit.info.offset;
            return .{ .tag = .unit, .data = .{ .unit = .{
                .value = mag * b.data.number + a.data.unit.info.offset,
                .info = a.data.unit.info,
            } } };
        }
        if (a.tag == .number and b.tag == .unit) {
            const mag = b.data.unit.value - b.data.unit.info.offset;
            return .{ .tag = .unit, .data = .{ .unit = .{
                .value = mag * a.data.number + b.data.unit.info.offset,
                .info = b.data.unit.info,
            } } };
        }

        // Unit * Unit
        if (a.tag == .unit and b.tag == .unit) {
            const new_dims = a.data.unit.info.dimensions.multiply(b.data.unit.info.dimensions);
            const new_val = a.data.unit.value * b.data.unit.value;
            const new_scale = a.data.unit.info.scale * b.data.unit.info.scale;
            if (new_dims.isScalar()) return initNumber(new_val);

            var name_buf: [128]u8 = undefined;
            var combined_name: ?[]const u8 = null;
            if (a.data.unit.info.name) |na| {
                if (b.data.unit.info.name) |nb| {
                    combined_name = std.fmt.bufPrint(&name_buf, "{s}*{s}", .{ na, nb }) catch null;
                }
            }

            return .{
                .tag = .unit,
                .data = .{
                    .unit = .{
                        .value = new_val,
                        // Result of multiplication is normalized (offset 0)
                        .info = UnitInfo.intern(new_scale, 0, new_dims, combined_name),
                    },
                },
            };
        }

        if (a.isNumeric() and b.isNumeric()) {
            const ac = a.toComplex() orelse return initError(1);
            const bc = b.toComplex() orelse return initError(1);
            const result = ac.mul(bc);
            if (result.im == 0) {
                return initNumber(result.re);
            }
            return .{ .tag = .complex, .data = .{ .complex = result } };
        }

        return initError(1);
    }

    pub fn div(a: Value, b: Value, allocator: ?std.mem.Allocator) Value {
        // Unit names are interned globally now; the allocator parameter is
        // kept for API compatibility.
        _ = allocator;
        if (a.tag == .number and b.tag == .number) {
            if (b.data.number == 0) {
                if (a.data.number > 0) return initNumber(std.math.inf(f64));
                if (a.data.number < 0) return initNumber(-std.math.inf(f64));
                return initNumber(std.math.nan(f64)); // 0/0 is NaN
            }
            return initNumber(a.data.number / b.data.number);
        }

        // Matrix / Scalar (Broadcasting)
        if (a.tag == .matrix and b.tag == .number) {
            const ma = a.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
            for (0..ma.data.len) |i| res.data[i] = ma.data[i] / b.data.number;
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }

        // Matrix / Unit (scale by normalized unit value)
        if (a.tag == .matrix and b.tag == .unit) {
            const ma = a.data.matrix;
            std.debug.assert(ma.magic == 0x4D41545249583031);
            const denom = b.data.unit.value;
            if (denom == 0) return initError(1);
            const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
            for (0..ma.data.len) |i| res.data[i] = ma.data[i] / denom;
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }
        if (a.tag == .number and b.tag == .matrix) {
            const mb = b.data.matrix;
            std.debug.assert(mb.magic == 0x4D41545249583031);
            const res = Matrix.init(mb.allocator, mb.rows, mb.cols) catch return initError(3);
            for (0..mb.data.len) |i| res.data[i] = a.data.number / mb.data[i];
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }

        // Series / Series
        if (a.tag == .series and b.tag == .series) {
            const sa = a.data.series;
            const sb = b.data.series;
            std.debug.assert(sa.magic == 0x5345524945533031);
            std.debug.assert(sb.magic == 0x5345524945533031);
            const aligned = alignment.alignUnion(sa, sb, sa.allocator) catch return initError(3);
            const res_a = aligned.@"0";
            const res_b = aligned.@"1";
            defer res_a.release();
            defer res_b.release();

            const res = Series.init(sa.allocator, res_a.len, sa.sample_mode, sa.dimensions) catch return initError(3);
            @memcpy(res.timestamps, res_a.timestamps);
            for (0..res_a.len) |i| {
                res.values[i] = if (res_b.values[i] != 0) res_a.values[i] / res_b.values[i] else std.math.nan(f64);
                res.validity[i] = res_a.validity[i] & res_b.validity[i];
            }
            res.validate() catch {};
            return initSeries(res);
        }

        // Series / Scalar
        if (a.tag == .series and b.tag == .number) {
            const s = a.data.series;
            std.debug.assert(s.magic == 0x5345524945533031);
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            const divisor = b.data.number;
            for (0..s.len) |i| res.values[i] = if (divisor != 0) s.values[i] / divisor else std.math.nan(f64);
            res.validate() catch {};
            return initSeries(res);
        }
        if (a.tag == .number and b.tag == .series) {
            const s = b.data.series;
            std.debug.assert(s.magic == 0x5345524945533031);
            const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
            @memcpy(res.timestamps, s.timestamps);
            @memcpy(res.validity, s.validity);
            for (0..s.len) |i| res.values[i] = if (s.values[i] != 0) a.data.number / s.values[i] else std.math.nan(f64);
            res.validate() catch {};
            return initSeries(res);
        }

        // Unit / Scalar: only the magnitude changes, the descriptor is reused
        if (a.tag == .unit and b.tag == .number) {
            return .{ .tag = .unit, .data = .{ .unit = .{
                .value = a.data.unit.value / b.data.number,
                .info = a.data.unit.info,
            } } };
        }
        // Scalar / Unit
        if (a.tag == .number and b.tag == .unit) {
            const new_dims = (Dimensions{}).divide(b.data.unit.info.dimensions);

            var name_buf: [128]u8 = undefined;
            var combined_name: ?[]const u8 = null;
            if (b.data.unit.info.name) |nb| {
                combined_name = std.fmt.bufPrint(&name_buf, "1/{s}", .{nb}) catch null;
            }

            return .{ .tag = .unit, .data = .{ .unit = .{
                .value = a.data.number / b.data.unit.value,
                .info = UnitInfo.intern(1.0 / b.data.unit.info.scale, 0, new_dims, combined_name),
            } } };
        }

        // Unit / Unit
        if (a.tag == .unit and b.tag == .unit) {
            const new_dims = a.data.unit.info.dimensions.divide(b.data.unit.info.dimensions);
            const new_val = a.data.unit.value / b.data.unit.value;
            const new_scale = a.data.unit.info.scale / b.data.unit.info.scale;
            if (new_dims.isScalar()) return initNumber(new_val);

            var name_buf: [128]u8 = undefined;
            var combined_name: ?[]const u8 = null;
            if (a.data.unit.info.name) |na| {
                if (b.data.unit.info.name) |nb| {
                    combined_name = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ na, nb }) catch null;
                }
            }

            return .{ .tag = .unit, .data = .{ .unit = .{
                .value = new_val,
                .info = UnitInfo.intern(new_scale, 0, new_dims, combined_name),
            } } };
        }

        if (a.isNumeric() and b.isNumeric()) {
            const ac = a.toComplex() orelse return initError(1);
            const bc = b.toComplex() orelse return initError(1);
            const result = ac.div(bc);
            if (result.im == 0) {
                return initNumber(result.re);
            }
            return .{ .tag = .complex, .data = .{ .complex = result } };
        }

        return initError(1);
    }

    pub fn neg(a: Value) Value {
        return switch (a.tag) {
            .number => initNumber(-a.data.number),
            .complex => .{ .tag = .complex, .data = .{ .complex = a.data.complex.neg() } },
            .unit => .{ .tag = .unit, .data = .{ .unit = .{
                .value = -a.data.unit.value,
                .info = a.data.unit.info,
            } } },
            .matrix => blk: {
                const m = a.data.matrix;
                // We need to allocate a new matrix
                // Since this is inside Value, we don't have VM allocator easily?
                // Value operations usually don't take allocator unless passed.
                // Value.neg signature: fn(a: Value) Value.
                // We are stuck if we need allocator.

                // Existing arithmetic ops take 'allocator: ?std.mem.Allocator'.
                // But neg doesn't.
                // We should change neg signature or rely on existing allocators?
                // Value.add doesn't take allocator?
                // Value.add creates new Matrix?
                // Value.add: const res = Matrix.init(ma.allocator, ...)
                // It uses the allocator of the input matrix!

                std.debug.assert(m.magic == 0x4D41545249583031);
                const res = Matrix.init(m.allocator, m.rows, m.cols) catch return initError(3);
                for (0..m.data.len) |i| res.data[i] = -m.data[i];
                break :blk .{ .tag = .matrix, .data = .{ .matrix = res } };
            },
            .series => blk: {
                const s = a.data.series;
                std.debug.assert(s.magic == 0x5345524945533031);
                const res = Series.init(s.allocator, s.len, s.sample_mode, s.dimensions) catch return initError(3);
                @memcpy(res.timestamps, s.timestamps);
                @memcpy(res.validity, s.validity);
                for (0..s.len) |i| res.values[i] = -s.values[i];
                res.validate() catch {};
                break :blk initSeries(res);
            },
            else => initError(1),
        };
    }

    pub fn sqrt(a: Value) Value {
        if (a.tag == .number) {
            if (a.data.number >= 0) {
                return initNumber(@sqrt(a.data.number));
            } else {
                return .{ .tag = .complex, .data = .{ .complex = .{ .re = 0, .im = @sqrt(-a.data.number) } } };
            }
        }
        if (a.tag == .complex) {
            return .{ .tag = .complex, .data = .{ .complex = a.data.complex.sqrt() } };
        }
        return initError(1);
    }

    pub fn pow(a: Value, b: Value) Value {
        if (a.tag == .number and b.tag == .number) {
            return initNumber(std.math.pow(f64, a.data.number, b.data.number));
        }

        // Unit ^ Number
        if (a.tag == .unit and b.tag == .number) {
            const exp = b.data.number;
            const exp_i: i8 = @intFromFloat(exp);

            // Only support integer powers for units for now (to avoid fractional dimensions)
            if (@as(f64, @floatFromInt(exp_i)) == exp) {
                var new_dims = a.data.unit.info.dimensions;
                new_dims.m *= exp_i;
                new_dims.l *= exp_i;
                new_dims.t *= exp_i;
                new_dims.i *= exp_i;
                new_dims.k *= exp_i;
                new_dims.n *= exp_i;
                new_dims.j *= exp_i;

                return .{
                    .tag = .unit,
                    .data = .{
                        .unit = .{
                            .value = std.math.pow(f64, a.data.unit.value, exp),
                            // Power of unit usually doesn't have a simple name
                            .info = UnitInfo.intern(std.math.pow(f64, a.data.unit.info.scale, exp), 0, new_dims, null),
                        },
                    },
                };
            }
        }

        if (a.isNumeric() and b.isNumeric()) {
            const ac = a.toComplex() orelse return initError(1);
            const bc = b.toComplex() orelse return initError(1);
            const result = ac.pow(bc);
            return .{ .tag = .complex, .data = .{ .complex = result } };
        }

        return initError(1);
    }

    pub fn mod(a: Value, b: Value) Value {
        if (a.tag == .number and b.tag == .number) {
            return initNumber(euclideanMod(a.data.number, b.data.number));
        }
        return initError(1);
    }

    pub fn emul(a: Value, b: Value, allocator: ?std.mem.Allocator) Value {
        if (a.tag == .matrix and b.tag == .matrix) {
            const ma = a.data.matrix;
            const mb = b.data.matrix;
            if (ma.rows == mb.rows and ma.cols == mb.cols) {
                const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
                for (0..ma.data.len) |i| {
                    res.data[i] = ma.data[i] * mb.data[i];
                }
                return .{ .tag = .matrix, .data = .{ .matrix = res } };
            }
            return initError(2);
        }
        return mul(a, b, allocator);
    }

    pub fn ediv(a: Value, b: Value, allocator: ?std.mem.Allocator) Value {
        if (a.tag == .matrix and b.tag == .matrix) {
            const ma = a.data.matrix;
            const mb = b.data.matrix;
            if (ma.rows == mb.rows and ma.cols == mb.cols) {
                const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
                for (0..ma.data.len) |i| {
                    res.data[i] = if (mb.data[i] == 0) std.math.nan(f64) else ma.data[i] / mb.data[i];
                }
                return .{ .tag = .matrix, .data = .{ .matrix = res } };
            }
            return initError(2);
        }
        return div(a, b, allocator);
    }

    pub fn epow(a: Value, b: Value, allocator: ?std.mem.Allocator) Value {
        _ = allocator;
        // Matrix .^ Matrix (element-wise)
        if (a.tag == .matrix and b.tag == .matrix) {
            const ma = a.data.matrix;
            const mb = b.data.matrix;
            if (ma.rows == mb.rows and ma.cols == mb.cols) {
                const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
                for (0..ma.data.len) |i| {
                    res.data[i] = std.math.pow(f64, ma.data[i], mb.data[i]);
                }
                return .{ .tag = .matrix, .data = .{ .matrix = res } };
            }
            return initError(2);
        }
        // Matrix .^ Scalar (broadcast scalar exponent)
        if (a.tag == .matrix and b.tag == .number) {
            const ma = a.data.matrix;
            const exp = b.data.number;
            const res = Matrix.init(ma.allocator, ma.rows, ma.cols) catch return initError(3);
            for (0..ma.data.len) |i| {
                res.data[i] = std.math.pow(f64, ma.data[i], exp);
            }
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }
        // Scalar .^ Matrix (broadcast scalar base)
        if (a.tag == .number and b.tag == .matrix) {
            const base = a.data.number;
            const mb = b.data.matrix;
            const res = Matrix.init(mb.allocator, mb.rows, mb.cols) catch return initError(3);
            for (0..mb.data.len) |i| {
                res.data[i] = std.math.pow(f64, base, mb.data[i]);
            }
            return .{ .tag = .matrix, .data = .{ .matrix = res } };
        }
        return pow(a, b);
    }
};

// Tests
test "Value basic arithmetic" {
    const a = Value.initNumber(10);
    const b = Value.initNumber(3);

    const sum = Value.add(a, b);
    try std.testing.expectEqual(@as(f64, 13), sum.data.number);

    const diff = Value.sub(a, b);
    try std.testing.expectEqual(@as(f64, 7), diff.data.number);

    const prod = Value.mul(a, b, null);
    try std.testing.expectEqual(@as(f64, 30), prod.data.number);

    const quot = Value.div(a, b, null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.333333), quot.data.number, 0.0001);
}

test "Complex arithmetic" {
    const a = Value.initComplex(2, 3); // 2 + 3i
    const b = Value.initComplex(1, -2); // 1 - 2i

    // (2 + 3i) * (1 - 2i) = 2 - 4i + 3i - 6i^2 = 2 - i + 6 = 8 - i
    const prod = Value.mul(a, b, null);
    try std.testing.expectEqual(ValueTag.complex, prod.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 8), prod.data.complex.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, -1), prod.data.complex.im, 0.0001);
}

test "Unit arithmetic" {
    const dim_l = Dimensions{ .l = 1 };
    const a = Value.initUnit(10, dim_l); // 10m
    const b = Value.initUnit(5, dim_l); // 5m

    const sum = Value.add(a, b);
    try std.testing.expectEqual(ValueTag.unit, sum.tag);
    try std.testing.expectEqual(@as(f64, 15), sum.data.unit.value);

    const area = Value.mul(a, b, null);
    try std.testing.expectEqual(ValueTag.unit, area.tag);
    try std.testing.expectEqual(@as(i8, 2), area.data.unit.info.dimensions.l);
    try std.testing.expectEqual(@as(f64, 50), area.data.unit.value);
}

test "Matrix multiplication" {
    const allocator = std.testing.allocator;
    const a = try Matrix.init(allocator, 2, 2);
    defer a.release();
    a.set(0, 0, 1);
    a.set(0, 1, 2);
    a.set(1, 0, 3);
    a.set(1, 1, 4);

    const b = try Matrix.init(allocator, 2, 2);
    defer b.release();
    b.set(0, 0, 5);
    b.set(0, 1, 6);
    b.set(1, 0, 7);
    b.set(1, 1, 8);

    const val_a = Value{ .tag = .matrix, .data = .{ .matrix = a } };
    const val_b = Value{ .tag = .matrix, .data = .{ .matrix = b } };

    const res_val = Value.mul(val_a, val_b, null);
    try std.testing.expectEqual(ValueTag.matrix, res_val.tag);
    const res = res_val.data.matrix;
    defer res.release();

    try std.testing.expectEqual(@as(f64, 19), res.get(0, 0));
    try std.testing.expectEqual(@as(f64, 22), res.get(0, 1));
    try std.testing.expectEqual(@as(f64, 43), res.get(1, 0));
    try std.testing.expectEqual(@as(f64, 50), res.get(1, 1));
}

test "Matrix broadcasting" {
    const allocator = std.testing.allocator;
    const a = try Matrix.init(allocator, 2, 2);
    defer a.release();
    a.set(0, 0, 1);
    a.set(0, 1, 2);
    a.set(1, 0, 3);
    a.set(1, 1, 4);

    const val_a = Value{ .tag = .matrix, .data = .{ .matrix = a } };
    const val_scalar = Value.initNumber(10);

    const res_val = Value.add(val_a, val_scalar);
    const res = res_val.data.matrix;
    defer res.release();

    try std.testing.expectEqual(@as(f64, 11), res.get(0, 0));
    try std.testing.expectEqual(@as(f64, 12), res.get(0, 1));
    try std.testing.expectEqual(@as(f64, 13), res.get(1, 0));
    try std.testing.expectEqual(@as(f64, 14), res.get(1, 1));
}

// ============================================================================
// Complex Number Tests
// ============================================================================

test "Complex: abs and arg" {
    // 3 + 4i has magnitude 5 and angle atan2(4, 3)
    const c = Complex.init(3, 4);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), c.abs(), 0.0001);
    try std.testing.expectApproxEqAbs(std.math.atan2(@as(f64, 4.0), @as(f64, 3.0)), c.arg(), 0.0001);

    // Pure imaginary: 0 + 1i -> abs = 1, arg = pi/2
    const i = Complex.init(0, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), i.abs(), 0.0001);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, i.arg(), 0.0001);

    // Negative real: -1 + 0i -> abs = 1, arg = pi
    const neg = Complex.init(-1, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), neg.abs(), 0.0001);
    try std.testing.expectApproxEqAbs(std.math.pi, neg.arg(), 0.0001);
}

test "Complex: exp and log" {
    // exp(0) = 1
    const zero = Complex.init(0, 0);
    const exp_zero = zero.exp();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), exp_zero.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), exp_zero.im, 0.0001);

    // exp(i*pi) = -1 (Euler's identity)
    const i_pi = Complex.init(0, std.math.pi);
    const exp_i_pi = i_pi.exp();
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), exp_i_pi.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), exp_i_pi.im, 0.0001);

    // log(1) = 0
    const one = Complex.init(1, 0);
    const log_one = one.log();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), log_one.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), log_one.im, 0.0001);

    // log(e) = 1
    const e = Complex.init(std.math.e, 0);
    const log_e = e.log();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), log_e.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), log_e.im, 0.0001);
}

test "Complex: pow" {
    // 2^3 = 8
    const two = Complex.init(2, 0);
    const three = Complex.init(3, 0);
    const result = Complex.pow(two, three);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.im, 0.0001);

    // 0^0 = 1 (by convention)
    const zero = Complex.init(0, 0);
    const zero_pow_zero = Complex.pow(zero, zero);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), zero_pow_zero.re, 0.0001);

    // 0^2 = 0
    const zero_pow_two = Complex.pow(zero, two);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), zero_pow_two.re, 0.0001);

    // i^2 = -1
    const i = Complex.init(0, 1);
    const i_squared = Complex.pow(i, two);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), i_squared.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), i_squared.im, 0.0001);
}

test "Complex: conj and neg" {
    const c = Complex.init(3, 4);

    const conjugate = c.conj();
    try std.testing.expectEqual(@as(f64, 3), conjugate.re);
    try std.testing.expectEqual(@as(f64, -4), conjugate.im);

    const negated = c.neg();
    try std.testing.expectEqual(@as(f64, -3), negated.re);
    try std.testing.expectEqual(@as(f64, -4), negated.im);
}

test "Complex: div" {
    // (1 + 2i) / (3 + 4i) = (1*3 + 2*4) / (3^2 + 4^2) + i*(2*3 - 1*4) / (3^2 + 4^2)
    // = (3 + 8) / 25 + i*(6 - 4) / 25 = 11/25 + 2i/25 = 0.44 + 0.08i
    const a = Complex.init(1, 2);
    const b = Complex.init(3, 4);
    const result = Complex.div(a, b);
    try std.testing.expectApproxEqAbs(@as(f64, 0.44), result.re, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), result.im, 0.0001);
}

// ============================================================================
// Matrix Tests
// ============================================================================

test "Matrix: init and basic operations" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 3, 3);
    defer m.release();

    // Matrix should be initialized to zeros
    try std.testing.expectEqual(@as(f64, 0), m.get(0, 0));
    try std.testing.expectEqual(@as(f64, 0), m.get(2, 2));

    // Test set and get
    m.set(1, 2, 42.0);
    try std.testing.expectEqual(@as(f64, 42.0), m.get(1, 2));
}

test "Matrix: reshape" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 2, 3);
    defer m.release();

    // 2x3 can reshape to 6x1, 3x2, 1x6
    try m.reshape(6, 1);
    try std.testing.expectEqual(@as(u32, 6), m.rows);
    try std.testing.expectEqual(@as(u32, 1), m.cols);

    try m.reshape(3, 2);
    try std.testing.expectEqual(@as(u32, 3), m.rows);
    try std.testing.expectEqual(@as(u32, 2), m.cols);

    // Invalid reshape should fail
    const result = m.reshape(4, 4);
    try std.testing.expectError(error.MismatchedDimensions, result);
}

test "Matrix: flatten" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 2, 3);
    defer m.release();

    try m.flatten();
    try std.testing.expectEqual(@as(u32, 6), m.rows);
    try std.testing.expectEqual(@as(u32, 1), m.cols);
}

test "Matrix: getDiagonal" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 3, 3);
    defer m.release();

    // Set diagonal values
    m.set(0, 0, 1.0);
    m.set(1, 1, 2.0);
    m.set(2, 2, 3.0);
    // Set off-diagonal values
    m.set(0, 1, 99.0);
    m.set(1, 0, 99.0);

    const diag = try m.getDiagonal(allocator);
    defer diag.release();

    try std.testing.expectEqual(@as(u32, 3), diag.rows);
    try std.testing.expectEqual(@as(u32, 1), diag.cols);
    try std.testing.expectEqual(@as(f64, 1.0), diag.get(0, 0));
    try std.testing.expectEqual(@as(f64, 2.0), diag.get(1, 0));
    try std.testing.expectEqual(@as(f64, 3.0), diag.get(2, 0));
}

test "Matrix: retain and release" {
    const allocator = std.testing.allocator;
    const m = try Matrix.init(allocator, 2, 2);

    try std.testing.expectEqual(@as(u32, 1), m.ref_count);

    _ = m.retain();
    try std.testing.expectEqual(@as(u32, 2), m.ref_count);

    m.release();
    try std.testing.expectEqual(@as(u32, 1), m.ref_count);

    m.release(); // Final release, should free
}

// ============================================================================
// Record Tests
// ============================================================================

test "Record: init and basic operations" {
    const allocator = std.testing.allocator;
    const record = try Record.init(allocator, allocator);
    defer record.release();

    try std.testing.expectEqual(@as(usize, 0), record.len());
}

test "Record: set and get" {
    const allocator = std.testing.allocator;
    const record = try Record.init(allocator, allocator);
    defer record.release();

    const val1 = Value.initNumber(42.0);
    const val2 = Value.initNumber(3.14);

    try record.set("answer", val1);
    try record.set("pi", val2);

    try std.testing.expectEqual(@as(usize, 2), record.len());

    const retrieved = record.get("answer");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(f64, 42.0), retrieved.?.data.number);

    const missing = record.get("missing");
    try std.testing.expect(missing == null);
}

test "Record: has" {
    const allocator = std.testing.allocator;
    const record = try Record.init(allocator, allocator);
    defer record.release();

    try record.set("exists", Value.initNumber(1));

    try std.testing.expect(record.has("exists"));
    try std.testing.expect(!record.has("does_not_exist"));
}

test "Record: keys" {
    const allocator = std.testing.allocator;
    const record = try Record.init(allocator, allocator);
    defer record.release();

    try record.set("a", Value.initNumber(1));
    try record.set("b", Value.initNumber(2));
    try record.set("c", Value.initNumber(3));

    const key_list = try record.keys(allocator);
    defer {
        for (key_list) |k| allocator.free(k);
        allocator.free(key_list);
    }

    try std.testing.expectEqual(@as(usize, 3), key_list.len);
}

test "Record: overwrite existing field" {
    const allocator = std.testing.allocator;
    const record = try Record.init(allocator, allocator);
    defer record.release();

    try record.set("value", Value.initNumber(1.0));
    try std.testing.expectEqual(@as(f64, 1.0), record.get("value").?.data.number);

    try record.set("value", Value.initNumber(2.0));
    try std.testing.expectEqual(@as(f64, 2.0), record.get("value").?.data.number);
    try std.testing.expectEqual(@as(usize, 1), record.len());
}

// ============================================================================
// Value Conversion Tests
// ============================================================================

test "Value: toNumber conversions" {
    // Number -> number
    const num = Value.initNumber(42.0);
    try std.testing.expectEqual(@as(f64, 42.0), num.toNumber().?);

    // Boolean -> number
    const t = Value.initBoolean(true);
    const f = Value.initBoolean(false);
    try std.testing.expectEqual(@as(f64, 1.0), t.toNumber().?);
    try std.testing.expectEqual(@as(f64, 0.0), f.toNumber().?);

    // Undefined -> null
    const undef = Value.initUndefined();
    try std.testing.expect(undef.toNumber() == null);
}

test "Value: toComplex conversions" {
    // Number -> Complex
    const num = Value.initNumber(5.0);
    const c = num.toComplex().?;
    try std.testing.expectEqual(@as(f64, 5.0), c.re);
    try std.testing.expectEqual(@as(f64, 0.0), c.im);

    // Complex -> Complex
    const complex = Value.initComplex(3.0, 4.0);
    const c2 = complex.toComplex().?;
    try std.testing.expectEqual(@as(f64, 3.0), c2.re);
    try std.testing.expectEqual(@as(f64, 4.0), c2.im);
}

test "Value: stays small (unit metadata is interned behind a pointer)" {
    // The general interpreter copies Values on the stack; keeping Value at
    // 24 bytes in release builds (tag + largest payload: Complex/UnitValue/
    // FunctionHandle at 16) is a deliberate perf property. If this fails,
    // something grew the Data union — box the new payload instead.
    // Debug/safe builds add a hidden union safety tag (+8).
    const debug_slack: usize = if (@import("builtin").mode == .Debug or
        @import("builtin").mode == .ReleaseSafe) 8 else 0;
    try std.testing.expect(@sizeOf(Value) <= 24 + debug_slack);
    try std.testing.expect(@sizeOf(UnitValue) <= 16);
}

test "Value: type checks" {
    const num = Value.initNumber(1.0);
    try std.testing.expect(num.isNumber());
    try std.testing.expect(num.isNumeric());
    try std.testing.expect(!num.isComplex());
    try std.testing.expect(!num.isMatrix());

    const complex = Value.initComplex(1.0, 1.0);
    try std.testing.expect(complex.isComplex());
    try std.testing.expect(complex.isNumeric());
    try std.testing.expect(!complex.isNumber());

    const undef = Value.initUndefined();
    try std.testing.expect(!undef.isNumber());
    try std.testing.expect(!undef.isNumeric());
}

test "Value: NaN handling" {
    const nan = Value.initNumber(std.math.nan(f64));
    const result = nan.toNumber().?;
    try std.testing.expect(std.math.isNan(result));
}

test "Value: Infinity handling" {
    const pos_inf = Value.initNumber(std.math.inf(f64));
    const neg_inf = Value.initNumber(-std.math.inf(f64));

    try std.testing.expect(std.math.isPositiveInf(pos_inf.toNumber().?));
    try std.testing.expect(std.math.isNegativeInf(neg_inf.toNumber().?));
}
