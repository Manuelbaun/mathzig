const std = @import("std");
const builtin = @import("builtin");
const value = @import("../core/value.zig");
const threading = @import("../core/threading.zig");
// ... (existing code)
const Vec = value.Vec;
const Vec4 = value.Vec4;
const VectorLen = value.VectorLen;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// SIMD-optimized matrix multiplication for 4x4 blocks
// ... (existing code remains)
/// Computes C = A * B where A, B, C are 4x4 blocks
/// Optimized using broadcast + FMA (Outer product approach)
pub fn matMul4x4(A: [*]const f64, B: [*]const f64, C: [*]f64, stride_a: usize, stride_b: usize, stride_c: usize) void {
    var sum0 = Vec4{0, 0, 0, 0};
    var sum1 = Vec4{0, 0, 0, 0};
    var sum2 = Vec4{0, 0, 0, 0};
    var sum3 = Vec4{0, 0, 0, 0};

    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const vb: Vec4 = B[k * stride_b ..][0..4].*;
        sum0 = @mulAdd(Vec4, @splat(A[0 * stride_a + k]), vb, sum0);
        sum1 = @mulAdd(Vec4, @splat(A[1 * stride_a + k]), vb, sum1);
        sum2 = @mulAdd(Vec4, @splat(A[2 * stride_a + k]), vb, sum2);
        sum3 = @mulAdd(Vec4, @splat(A[3 * stride_a + k]), vb, sum3);
    }

    C[0 * stride_c ..][0..4].* = sum0;
    C[1 * stride_c ..][0..4].* = sum1;
    C[2 * stride_c ..][0..4].* = sum2;
    C[3 * stride_c ..][0..4].* = sum3;
}

/// SIMD-optimized matrix multiplication for 8x8 blocks
/// Uses 8x4 register blocks to maximize throughput on AVX2
pub fn matMul8x8(A: [*]const f64, B: [*]const f64, C: [*]f64, stride_a: usize, stride_b: usize, stride_c: usize) void {
    // Process as two 8x4 blocks to stay within register limits (16 YMM registers)
    // Block 1: Columns 0-3
    {
        var s0 = Vec4{0, 0, 0, 0}; var s1 = Vec4{0, 0, 0, 0};
        var s2 = Vec4{0, 0, 0, 0}; var s3 = Vec4{0, 0, 0, 0};
        var s4 = Vec4{0, 0, 0, 0}; var s5 = Vec4{0, 0, 0, 0};
        var s6 = Vec4{0, 0, 0, 0}; var s7 = Vec4{0, 0, 0, 0};

        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const vb: Vec4 = B[k * stride_b ..][0..4].*;
            s0 = @mulAdd(Vec4, @splat(A[0 * stride_a + k]), vb, s0);
            s1 = @mulAdd(Vec4, @splat(A[1 * stride_a + k]), vb, s1);
            s2 = @mulAdd(Vec4, @splat(A[2 * stride_a + k]), vb, s2);
            s3 = @mulAdd(Vec4, @splat(A[3 * stride_a + k]), vb, s3);
            s4 = @mulAdd(Vec4, @splat(A[4 * stride_a + k]), vb, s4);
            s5 = @mulAdd(Vec4, @splat(A[5 * stride_a + k]), vb, s5);
            s6 = @mulAdd(Vec4, @splat(A[6 * stride_a + k]), vb, s6);
            s7 = @mulAdd(Vec4, @splat(A[7 * stride_a + k]), vb, s7);
        }
        C[0 * stride_c ..][0..4].* = s0;
        C[1 * stride_c ..][0..4].* = s1;
        C[2 * stride_c ..][0..4].* = s2;
        C[3 * stride_c ..][0..4].* = s3;
        C[4 * stride_c ..][0..4].* = s4;
        C[5 * stride_c ..][0..4].* = s5;
        C[6 * stride_c ..][0..4].* = s6;
        C[7 * stride_c ..][0..4].* = s7;
    }
    // Block 2: Columns 4-7
    {
        var s0 = Vec4{0, 0, 0, 0}; var s1 = Vec4{0, 0, 0, 0};
        var s2 = Vec4{0, 0, 0, 0}; var s3 = Vec4{0, 0, 0, 0};
        var s4 = Vec4{0, 0, 0, 0}; var s5 = Vec4{0, 0, 0, 0};
        var s6 = Vec4{0, 0, 0, 0}; var s7 = Vec4{0, 0, 0, 0};

        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const vb: Vec4 = B[k * stride_b + 4 ..][0..4].*;
            s0 = @mulAdd(Vec4, @splat(A[0 * stride_a + k]), vb, s0);
            s1 = @mulAdd(Vec4, @splat(A[1 * stride_a + k]), vb, s1);
            s2 = @mulAdd(Vec4, @splat(A[2 * stride_a + k]), vb, s2);
            s3 = @mulAdd(Vec4, @splat(A[3 * stride_a + k]), vb, s3);
            s4 = @mulAdd(Vec4, @splat(A[4 * stride_a + k]), vb, s4);
            s5 = @mulAdd(Vec4, @splat(A[5 * stride_a + k]), vb, s5);
            s6 = @mulAdd(Vec4, @splat(A[6 * stride_a + k]), vb, s6);
            s7 = @mulAdd(Vec4, @splat(A[7 * stride_a + k]), vb, s7);
        }
        C[0 * stride_c + 4 ..][0..4].* = s0;
        C[1 * stride_c + 4 ..][0..4].* = s1;
        C[2 * stride_c + 4 ..][0..4].* = s2;
        C[3 * stride_c + 4 ..][0..4].* = s3;
        C[4 * stride_c + 4 ..][0..4].* = s4;
        C[5 * stride_c + 4 ..][0..4].* = s5;
        C[6 * stride_c + 4 ..][0..4].* = s6;
        C[7 * stride_c + 4 ..][0..4].* = s7;
    }
}

/// Tiled General Matrix Multiplication
/// Optimized for cache locality and SIMD
pub fn gemm(
    rows_a: u32, cols_a: u32, cols_b: u32,
    A: []const f64, stride_a: u32,
    B: []const f64, stride_b: u32,
    C: []f64, stride_c: u32
) void {
    // Cache-aware blocking parameters
    const BLOCK_SIZE = 64; 

    var i_start: u32 = 0;
    while (i_start < rows_a) : (i_start += BLOCK_SIZE) {
        const i_max = @min(i_start + BLOCK_SIZE, rows_a);
        
        var j_start: u32 = 0;
        while (j_start < cols_b) : (j_start += BLOCK_SIZE) {
            const j_max = @min(j_start + BLOCK_SIZE, cols_b);
            
            var k_start: u32 = 0;
            while (k_start < cols_a) : (k_start += BLOCK_SIZE) {
                const k_max = @min(k_start + BLOCK_SIZE, cols_a);
                
                // Process the block (i_start..i_max, j_start..j_max)
                var i = i_start;
                while (i < i_max) {
                    const use_8x4 = (i + 8 <= i_max);
                    var j = j_start;
                    while (j < j_max) : (j += 4) {
                        // FAST PATH: Use specialized micro-kernels if dimensions align perfectly
                        if (use_8x4 and j + 8 <= j_max and k_start == 0 and k_max == cols_a and cols_a == 8) {
                             matMul8x8(A.ptr + i * stride_a, B.ptr + j, C.ptr + i * stride_c + j, stride_a, stride_b, stride_c);
                             j += 4; 
                             continue;
                        }

                        // Fallback to scalar for remainders
                        if (i + 4 > rows_a or j + 4 > cols_b) {
                            gemmScalar(i, j, rows_a, cols_b, cols_a, A, stride_a, B, stride_b, C, stride_c);
                            continue;
                        }
                        
                        if (use_8x4) {
                            // Optimized SIMD inner loop for k (8x4 register block)
                            var s0 = Vec4{0, 0, 0, 0}; var s1 = Vec4{0, 0, 0, 0};
                            var s2 = Vec4{0, 0, 0, 0}; var s3 = Vec4{0, 0, 0, 0};
                            var s4 = Vec4{0, 0, 0, 0}; var s5 = Vec4{0, 0, 0, 0};
                            var s6 = Vec4{0, 0, 0, 0}; var s7 = Vec4{0, 0, 0, 0};

                            var k = k_start;
                            while (k < k_max) : (k += 1) {
                                const vb: Vec4 = B.ptr[k * stride_b + j ..][0..4].*;
                                s0 = @mulAdd(Vec4, @splat(A[(i + 0) * stride_a + k]), vb, s0);
                                s1 = @mulAdd(Vec4, @splat(A[(i + 1) * stride_a + k]), vb, s1);
                                s2 = @mulAdd(Vec4, @splat(A[(i + 2) * stride_a + k]), vb, s2);
                                s3 = @mulAdd(Vec4, @splat(A[(i + 3) * stride_a + k]), vb, s3);
                                s4 = @mulAdd(Vec4, @splat(A[(i + 4) * stride_a + k]), vb, s4);
                                s5 = @mulAdd(Vec4, @splat(A[(i + 5) * stride_a + k]), vb, s5);
                                s6 = @mulAdd(Vec4, @splat(A[(i + 6) * stride_a + k]), vb, s6);
                                s7 = @mulAdd(Vec4, @splat(A[(i + 7) * stride_a + k]), vb, s7);
                            }

                            if (k_start == 0) {
                                C.ptr[(i + 0) * stride_c + j ..][0..4].* = s0;
                                C.ptr[(i + 1) * stride_c + j ..][0..4].* = s1;
                                C.ptr[(i + 2) * stride_c + j ..][0..4].* = s2;
                                C.ptr[(i + 3) * stride_c + j ..][0..4].* = s3;
                                C.ptr[(i + 4) * stride_c + j ..][0..4].* = s4;
                                C.ptr[(i + 5) * stride_c + j ..][0..4].* = s5;
                                C.ptr[(i + 6) * stride_c + j ..][0..4].* = s6;
                                C.ptr[(i + 7) * stride_c + j ..][0..4].* = s7;
                            } else {
                                { var temp: Vec4 = C.ptr[(i + 0) * stride_c + j ..][0..4].*; temp += s0; C.ptr[(i + 0) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 1) * stride_c + j ..][0..4].*; temp += s1; C.ptr[(i + 1) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 2) * stride_c + j ..][0..4].*; temp += s2; C.ptr[(i + 2) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 3) * stride_c + j ..][0..4].*; temp += s3; C.ptr[(i + 3) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 4) * stride_c + j ..][0..4].*; temp += s4; C.ptr[(i + 4) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 5) * stride_c + j ..][0..4].*; temp += s5; C.ptr[(i + 5) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 6) * stride_c + j ..][0..4].*; temp += s6; C.ptr[(i + 6) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 7) * stride_c + j ..][0..4].*; temp += s7; C.ptr[(i + 7) * stride_c + j ..][0..4].* = temp; }
                            }
                        } else {
                            // Standard 4x4 register block
                            var s0 = Vec4{0, 0, 0, 0}; var s1 = Vec4{0, 0, 0, 0};
                            var s2 = Vec4{0, 0, 0, 0}; var s3 = Vec4{0, 0, 0, 0};

                            var k = k_start;
                            while (k < k_max) : (k += 1) {
                                const vb: Vec4 = B.ptr[k * stride_b + j ..][0..4].*;
                                s0 = @mulAdd(Vec4, @splat(A[(i + 0) * stride_a + k]), vb, s0);
                                s1 = @mulAdd(Vec4, @splat(A[(i + 1) * stride_a + k]), vb, s1);
                                s2 = @mulAdd(Vec4, @splat(A[(i + 2) * stride_a + k]), vb, s2);
                                s3 = @mulAdd(Vec4, @splat(A[(i + 3) * stride_a + k]), vb, s3);
                            }

                            if (k_start == 0) {
                                C.ptr[(i + 0) * stride_c + j ..][0..4].* = s0;
                                C.ptr[(i + 1) * stride_c + j ..][0..4].* = s1;
                                C.ptr[(i + 2) * stride_c + j ..][0..4].* = s2;
                                C.ptr[(i + 3) * stride_c + j ..][0..4].* = s3;
                            } else {
                                { var temp: Vec4 = C.ptr[(i + 0) * stride_c + j ..][0..4].*; temp += s0; C.ptr[(i + 0) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 1) * stride_c + j ..][0..4].*; temp += s1; C.ptr[(i + 1) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 2) * stride_c + j ..][0..4].*; temp += s2; C.ptr[(i + 2) * stride_c + j ..][0..4].* = temp; }
                                { var temp: Vec4 = C.ptr[(i + 3) * stride_c + j ..][0..4].*; temp += s3; C.ptr[(i + 3) * stride_c + j ..][0..4].* = temp; }
                            }
                        }
                    }
                    i += if (use_8x4) @as(u32, 8) else @as(u32, 4);
                }
            }
        }
    }
}

/// Task structure for parallel GEMM
const GemmTask = struct {
    rows_a: u32, cols_a: u32, cols_b: u32,
    A: []const f64, stride_a: u32,
    B: []const f64, stride_b: u32,
    C: []f64, stride_c: u32,
    i_start: u32, i_end: u32,
};

fn gemmParallelTask(task: GemmTask) void {
    // Process a horizontal slab of C
    const row_count = task.i_end - task.i_start;
    const slab_A = task.A[task.i_start * task.stride_a ..];
    const slab_C = task.C[task.i_start * task.stride_c ..];
    
    gemm(
        row_count, task.cols_a, task.cols_b,
        slab_A, task.stride_a,
        task.B, task.stride_b,
        slab_C, task.stride_c
    );
}

/// Multicore-optimized General Matrix Multiplication
/// Uses a thread pool to distribute work across horizontal slabs of C
pub fn gemmParallel(
    pool: if (is_wasm) void else *threading.Pool,
    rows_a: u32, cols_a: u32, cols_b: u32,
    A: []const f64, stride_a: u32,
    B: []const f64, stride_b: u32,
    C: []f64, stride_c: u32
) void {
    if (comptime is_wasm) {
        gemm(rows_a, cols_a, cols_b, A, stride_a, B, stride_b, C, stride_c);
        return;
    } else {
        if (rows_a < 32) {
            // Fallback to single-threaded for small matrices
            gemm(rows_a, cols_a, cols_b, A, stride_a, B, stride_b, C, stride_c);
            return;
        }

        const num_threads = threading.getCpuCount();
        const chunk_size = (rows_a + num_threads - 1) / num_threads;
        
        // Use a WaitGroup to synchronize
        var wg = threading.WaitGroup{};
        
        var i: u32 = 0;
        while (i < rows_a) : (i += chunk_size) {
            const i_end = @min(i + chunk_size, rows_a);
            wg.start();
            threading.spawn(pool, struct {
                fn run(w: *threading.WaitGroup, t: GemmTask) void {
                    defer w.finish();
                    gemmParallelTask(t);
                }
            }.run, .{ &wg, GemmTask{
                .rows_a = rows_a, .cols_a = cols_a, .cols_b = cols_b,
                .A = A, .stride_a = stride_a,
                .B = B, .stride_b = stride_b,
                .C = C, .stride_c = stride_c,
                .i_start = i, .i_end = i_end,
            } }) catch {
                // If spawning fails, run synchronously
                wg.finish();
                gemmParallelTask(.{
                    .rows_a = rows_a, .cols_a = cols_a, .cols_b = cols_b,
                    .A = A, .stride_a = stride_a,
                    .B = B, .stride_b = stride_b,
                    .C = C, .stride_c = stride_c,
                    .i_start = i, .i_end = i_end,
                });
            };
        }
        
        wg.wait();
    }
}


fn gemmScalar(
    start_r: u32, start_c: u32,
    rows_a: u32, cols_b: u32, cols_a: u32,
    A: []const f64, stride_a: u32,
    B: []const f64, stride_b: u32,
    C: []f64, stride_c: u32
) void {
    var r = start_r;
    while (r < @min(start_r + 4, rows_a)) : (r += 1) {
        var c = start_c;
        while (c < @min(start_c + 4, cols_b)) : (c += 1) {
            var sum: f64 = 0;
            var k: u32 = 0;
            while (k < cols_a) : (k += 1) {
                sum += A[r * stride_a + k] * B[k * stride_b + c];
            }
            C[r * stride_c + c] = sum;
        }
    }
}

// ... (existing code)
// ============================================================================
// Level 1 BLAS: Vector-Vector Operations
// ============================================================================

/// Required alignment for SIMD Vec operations
const SimdAlignment = @alignOf(Vec);

/// Check if a pointer is aligned for SIMD operations
inline fn isAligned(ptr: anytype) bool {
    return @intFromPtr(ptr) % SimdAlignment == 0;
}

/// SIMD-optimized vector addition: c = a + b
/// Automatically falls back to scalar if data is not aligned
pub fn vecAdd(a: []const f64, b: []const f64, c: []f64) void {
    const len = @min(a.len, @min(b.len, c.len));

    // Check alignment for SIMD path
    if (isAligned(a.ptr) and isAligned(b.ptr) and isAligned(c.ptr)) {
        const vec_count = len / VectorLen;
        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            const vb = @as(*const Vec, @ptrCast(@alignCast(b.ptr + offset))).*;
            @as(*Vec, @ptrCast(@alignCast(c.ptr + offset))).* = va + vb;
        }
        // Handle remainder
        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            c[j] = a[j] + b[j];
        }
    } else {
        // Scalar fallback for unaligned data
        for (0..len) |i| {
            c[i] = a[i] + b[i];
        }
    }
}

/// SIMD-optimized vector subtraction: c = a - b
pub fn vecSub(a: []const f64, b: []const f64, c: []f64) void {
    const len = @min(a.len, @min(b.len, c.len));

    if (isAligned(a.ptr) and isAligned(b.ptr) and isAligned(c.ptr)) {
        const vec_count = len / VectorLen;
        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            const vb = @as(*const Vec, @ptrCast(@alignCast(b.ptr + offset))).*;
            @as(*Vec, @ptrCast(@alignCast(c.ptr + offset))).* = va - vb;
        }
        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            c[j] = a[j] - b[j];
        }
    } else {
        for (0..len) |i| {
            c[i] = a[i] - b[i];
        }
    }
}

/// SIMD-optimized horizontal sum of a slice
pub fn vecSum(a: []const f64) f64 {
    const len = a.len;

    if (isAligned(a.ptr)) {
        const vec_count = len / VectorLen;
        var acc: Vec = @splat(0.0);

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            acc += va;
        }

        var res = @reduce(.Add, acc);

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            res += a[j];
        }
        return res;
    } else {
        var res: f64 = 0.0;
        for (a) |val| {
            res += val;
        }
        return res;
    }
}

/// SIMD-optimized mean of a slice
pub fn vecMean(a: []const f64) f64 {
    if (a.len == 0) return std.math.nan(f64);
    return vecSum(a) / @as(f64, @floatFromInt(a.len));
}

/// SIMD-optimized dot product: result = sum(a[i] * b[i])
/// Uses horizontal reduction for final summation
pub fn vecDot(a: []const f64, b: []const f64) f64 {
    const len = @min(a.len, b.len);

    if (isAligned(a.ptr) and isAligned(b.ptr)) {
        const vec_count = len / VectorLen;
        
        // 4 parallel accumulators to break dependency chains
        var acc0: Vec = @splat(0.0);
        var acc1: Vec = @splat(0.0);
        var acc2: Vec = @splat(0.0);
        var acc3: Vec = @splat(0.0);

        const unroll_factor = 4;
        const iterations = vec_count / unroll_factor;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const base = i * unroll_factor * VectorLen;
            
            const va0 = @as(*const Vec, @ptrCast(@alignCast(a.ptr + base))).*;
            const vb0 = @as(*const Vec, @ptrCast(@alignCast(b.ptr + base))).*;
            acc0 = @mulAdd(Vec, va0, vb0, acc0);

            const va1 = @as(*const Vec, @ptrCast(@alignCast(a.ptr + base + VectorLen))).*;
            const vb1 = @as(*const Vec, @ptrCast(@alignCast(b.ptr + base + VectorLen))).*;
            acc1 = @mulAdd(Vec, va1, vb1, acc1);

            const va2 = @as(*const Vec, @ptrCast(@alignCast(a.ptr + base + 2 * VectorLen))).*;
            const vb2 = @as(*const Vec, @ptrCast(@alignCast(b.ptr + base + 2 * VectorLen))).*;
            acc2 = @mulAdd(Vec, va2, vb2, acc2);

            const va3 = @as(*const Vec, @ptrCast(@alignCast(a.ptr + base + 3 * VectorLen))).*;
            const vb3 = @as(*const Vec, @ptrCast(@alignCast(b.ptr + base + 3 * VectorLen))).*;
            acc3 = @mulAdd(Vec, va3, vb3, acc3);
        }

        var acc = acc0 + acc1 + acc2 + acc3;

        // Handle remaining vectors that didn't fit into the unroll factor
        var j: usize = iterations * unroll_factor;
        while (j < vec_count) : (j += 1) {
            const offset = j * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            const vb = @as(*const Vec, @ptrCast(@alignCast(b.ptr + offset))).*;
            acc = @mulAdd(Vec, va, vb, acc);
        }

        var sum = @reduce(.Add, acc);

        // Handle remaining scalar elements
        var k = vec_count * VectorLen;
        while (k < len) : (k += 1) {
            sum += a[k] * b[k];
        }
        return sum;
    } else {
        var sum: f64 = 0.0;
        for (0..len) |i| {
            sum += a[i] * b[i];
        }
        return sum;
    }
}

/// SIMD-optimized Euclidean norm: result = sqrt(sum(a[i]^2))
pub fn vecNorm(a: []const f64) f64 {
    const len = a.len;

    if (isAligned(a.ptr)) {
        const vec_count = len / VectorLen;
        var acc: Vec = @splat(0.0);

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            acc = @mulAdd(Vec, va, va, acc);
        }

        var sum = @reduce(.Add, acc);

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            sum += a[j] * a[j];
        }
        return @sqrt(sum);
    } else {
        var sum: f64 = 0.0;
        for (0..len) |i| {
            sum += a[i] * a[i];
        }
        return @sqrt(sum);
    }
}

/// SIMD-optimized scalar multiplication: b = alpha * a
pub fn vecScale(alpha: f64, a: []const f64, b: []f64) void {
    const len = @min(a.len, b.len);

    if (isAligned(a.ptr) and isAligned(b.ptr)) {
        const vec_count = len / VectorLen;
        const alpha_vec: Vec = @splat(alpha);

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            @as(*Vec, @ptrCast(@alignCast(b.ptr + offset))).* = va * alpha_vec;
        }

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            b[j] = alpha * a[j];
        }
    } else {
        for (0..len) |i| {
            b[i] = alpha * a[i];
        }
    }
}

/// SIMD-optimized Minimum of a slice
pub fn vecMin(a: []const f64) f64 {
    const len = a.len;
    if (len == 0) return std.math.nan(f64);

    if (isAligned(a.ptr)) {
        const vec_count = len / VectorLen;
        var acc: Vec = @splat(std.math.inf(f64));

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            acc = @min(acc, va);
        }

        var res = @reduce(.Min, acc);

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            res = @min(res, a[j]);
        }
        return res;
    } else {
        var res: f64 = std.math.inf(f64);
        for (a) |val| {
            res = @min(res, val);
        }
        return res;
    }
}

/// SIMD-optimized Maximum of a slice
pub fn vecMax(a: []const f64) f64 {
    const len = a.len;
    if (len == 0) return std.math.nan(f64);

    if (isAligned(a.ptr)) {
        const vec_count = len / VectorLen;
        var acc: Vec = @splat(-std.math.inf(f64));

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const va = @as(*const Vec, @ptrCast(@alignCast(a.ptr + offset))).*;
            acc = @max(acc, va);
        }

        var res = @reduce(.Max, acc);

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            res = @max(res, a[j]);
        }
        return res;
    } else {
        var res: f64 = -std.math.inf(f64);
        for (a) |val| {
            res = @max(res, val);
        }
        return res;
    }
}

/// Product of a slice
pub fn vecProd(a: []const f64) f64 {
    if (a.len == 0) return std.math.nan(f64);
    var res: f64 = 1.0;
    for (a) |val| {
        res *= val;
    }
    return res;
}

/// In-place SIMD-optimized scalar multiplication: a = alpha * a
pub fn vecScaleInplace(alpha: f64, a: []f64) void {
    const len = a.len;

    if (isAligned(a.ptr)) {
        const vec_count = len / VectorLen;
        const alpha_vec: Vec = @splat(alpha);

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const ptr = @as(*Vec, @ptrCast(@alignCast(a.ptr + offset)));
            ptr.* = ptr.* * alpha_vec;
        }

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            a[j] = alpha * a[j];
        }
    } else {
        for (0..len) |i| {
            a[i] = alpha * a[i];
        }
    }
}

/// SIMD-optimized AXPY: y = alpha * x + y
/// Classic Level 1 BLAS operation
pub fn vecAxpy(alpha: f64, x: []const f64, y: []f64) void {
    const len = @min(x.len, y.len);

    if (isAligned(x.ptr) and isAligned(y.ptr)) {
        const vec_count = len / VectorLen;
        const alpha_vec: Vec = @splat(alpha);

        var i: usize = 0;
        while (i < vec_count) : (i += 1) {
            const offset = i * VectorLen;
            const vx = @as(*const Vec, @ptrCast(@alignCast(x.ptr + offset))).*;
            const vy_ptr = @as(*Vec, @ptrCast(@alignCast(y.ptr + offset)));
            vy_ptr.* = @mulAdd(Vec, vx, alpha_vec, vy_ptr.*);
        }

        var j = vec_count * VectorLen;
        while (j < len) : (j += 1) {
            y[j] = @mulAdd(f64, alpha, x[j], y[j]);
        }
    } else {
        for (0..len) |i| {
            y[i] = @mulAdd(f64, alpha, x[i], y[i]);
        }
    }
}

// ============================================================================
// Level 2 BLAS: Matrix-Vector Operations
// ============================================================================

/// General Matrix-Vector multiplication: y = alpha * A * x + beta * y
/// Optimized with 4-way unrolling to hide FMA latency
pub fn gemv(
    rows: u32, cols: u32,
    alpha: f64,
    A: []const f64, stride_a: u32,
    x: []const f64,
    beta: f64,
    y: []f64
) void {
    // Scale y by beta first (or zero it if beta == 0)
    if (beta == 0.0) {
        @memset(y[0..rows], 0.0);
    } else if (beta != 1.0) {
        for (y[0..rows]) |*val| {
            val.* *= beta;
        }
    }

    // Check if we can use SIMD path
    const use_simd = isAligned(A.ptr) and isAligned(x.ptr);

    // Unroll by 4 rows for better instruction-level parallelism
    var r: u32 = 0;
    while (r + 4 <= rows) : (r += 4) {
        var sum0: f64 = 0.0;
        var sum1: f64 = 0.0;
        var sum2: f64 = 0.0;
        var sum3: f64 = 0.0;

        const row0 = A[(r + 0) * stride_a ..][0..cols];
        const row1 = A[(r + 1) * stride_a ..][0..cols];
        const row2 = A[(r + 2) * stride_a ..][0..cols];
        const row3 = A[(r + 3) * stride_a ..][0..cols];

        if (use_simd) {
            // SIMD inner loop
            const vec_count = cols / VectorLen;
            var k: usize = 0;
            while (k < vec_count) : (k += 1) {
                const offset = k * VectorLen;
                const vx = @as(*const Vec, @ptrCast(@alignCast(x.ptr + offset))).*;

                const va0 = @as(*const Vec, @ptrCast(@alignCast(row0.ptr + offset))).*;
                const va1 = @as(*const Vec, @ptrCast(@alignCast(row1.ptr + offset))).*;
                const va2 = @as(*const Vec, @ptrCast(@alignCast(row2.ptr + offset))).*;
                const va3 = @as(*const Vec, @ptrCast(@alignCast(row3.ptr + offset))).*;

                sum0 += @reduce(.Add, va0 * vx);
                sum1 += @reduce(.Add, va1 * vx);
                sum2 += @reduce(.Add, va2 * vx);
                sum3 += @reduce(.Add, va3 * vx);
            }

            // Scalar remainder
            var j = vec_count * VectorLen;
            while (j < cols) : (j += 1) {
                sum0 += row0[j] * x[j];
                sum1 += row1[j] * x[j];
                sum2 += row2[j] * x[j];
                sum3 += row3[j] * x[j];
            }
        } else {
            // Scalar fallback
            for (0..cols) |j| {
                sum0 += row0[j] * x[j];
                sum1 += row1[j] * x[j];
                sum2 += row2[j] * x[j];
                sum3 += row3[j] * x[j];
            }
        }

        y[r + 0] += alpha * sum0;
        y[r + 1] += alpha * sum1;
        y[r + 2] += alpha * sum2;
        y[r + 3] += alpha * sum3;
    }

    // Handle remaining rows
    while (r < rows) : (r += 1) {
        var sum: f64 = 0.0;
        const row = A[r * stride_a ..][0..cols];

        if (use_simd) {
            const vec_count = cols / VectorLen;
            var k: usize = 0;
            while (k < vec_count) : (k += 1) {
                const offset = k * VectorLen;
                const vx = @as(*const Vec, @ptrCast(@alignCast(x.ptr + offset))).*;
                const va = @as(*const Vec, @ptrCast(@alignCast(row.ptr + offset))).*;
                sum += @reduce(.Add, va * vx);
            }

            var j = vec_count * VectorLen;
            while (j < cols) : (j += 1) {
                sum += row[j] * x[j];
            }
        } else {
            for (0..cols) |j| {
                sum += row[j] * x[j];
            }
        }

        y[r] += alpha * sum;
    }
}

/// Simplified gemv: y = A * x (alpha=1, beta=0)
pub fn gemvSimple(
    rows: u32, cols: u32,
    A: []const f64, stride_a: u32,
    x: []const f64,
    y: []f64
) void {
    gemv(rows, cols, 1.0, A, stride_a, x, 0.0, y);
}

// ============================================================================
// Tests
// ============================================================================

test "vecAdd basic" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const b = [_]f64{ 8, 7, 6, 5, 4, 3, 2, 1 };
    var c: [8]f64 = undefined;

    vecAdd(&a, &b, &c);

    for (c) |val| {
        try std.testing.expectEqual(@as(f64, 9), val);
    }
}

test "vecSub basic" {
    const a = [_]f64{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const b = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var c: [8]f64 = undefined;

    vecSub(&a, &b, &c);

    for (0..8) |i| {
        try std.testing.expectEqual(@as(f64, @floatFromInt((i + 1) * 9)), c[i]);
    }
}

test "vecDot basic" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const b = [_]f64{ 1, 1, 1, 1, 1, 1, 1, 1 };

    const result = vecDot(&a, &b);
    // Sum 1..8 = 36
    try std.testing.expectEqual(@as(f64, 36), result);
}

test "vecDot orthogonal" {
    const a = [_]f64{ 1, 0, 0, 0 };
    const b = [_]f64{ 0, 1, 0, 0 };

    const result = vecDot(&a, &b);
    try std.testing.expectEqual(@as(f64, 0), result);
}

test "vecNorm basic" {
    const a = [_]f64{ 3, 4 }; // Should give 5 (3-4-5 triangle)
    const result = vecNorm(&a);
    try std.testing.expectApproxEqAbs(@as(f64, 5), result, 0.0001);
}

test "vecNorm unit vector" {
    const a = [_]f64{ 1, 0, 0, 0, 0, 0, 0, 0 };
    const result = vecNorm(&a);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result, 0.0001);
}

test "vecScale basic" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var b: [8]f64 = undefined;

    vecScale(2.0, &a, &b);

    for (0..8) |i| {
        try std.testing.expectEqual(@as(f64, @floatFromInt((i + 1) * 2)), b[i]);
    }
}

test "vecAxpy basic" {
    const x = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var y = [_]f64{ 10, 20, 30, 40, 50, 60, 70, 80 };

    vecAxpy(2.0, &x, &y); // y = 2*x + y

    // Expected: y[i] = 2*(i+1) + (i+1)*10 = (i+1) * 12
    for (0..8) |i| {
        try std.testing.expectEqual(@as(f64, @floatFromInt((i + 1) * 12)), y[i]);
    }
}

test "gemv basic 4x4" {
    // 4x4 identity matrix
    const A = [_]f64{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    const x = [_]f64{ 1, 2, 3, 4 };
    var y: [4]f64 = undefined;

    gemvSimple(4, 4, &A, 4, &x, &y);

    // y = I * x = x
    try std.testing.expectEqual(@as(f64, 1), y[0]);
    try std.testing.expectEqual(@as(f64, 2), y[1]);
    try std.testing.expectEqual(@as(f64, 3), y[2]);
    try std.testing.expectEqual(@as(f64, 4), y[3]);
}

test "gemv with scaling" {
    const A = [_]f64{
        2, 0, 0, 0,
        0, 2, 0, 0,
        0, 0, 2, 0,
        0, 0, 0, 2,
    };
    const x = [_]f64{ 1, 2, 3, 4 };
    var y = [_]f64{ 10, 10, 10, 10 };

    // y = 0.5 * A * x + 1.0 * y = 0.5 * 2 * x + y = x + y
    gemv(4, 4, 0.5, &A, 4, &x, 1.0, &y);

    try std.testing.expectEqual(@as(f64, 11), y[0]);
    try std.testing.expectEqual(@as(f64, 12), y[1]);
    try std.testing.expectEqual(@as(f64, 13), y[2]);
    try std.testing.expectEqual(@as(f64, 14), y[3]);
}

test "gemv 8x8 for SIMD coverage" {
    // Simple matrix where each row i has value i+1 in all columns
    var A: [64]f64 = undefined;
    for (0..8) |r| {
        for (0..8) |c| {
            A[r * 8 + c] = @floatFromInt(r + 1);
        }
    }
    // x = [1, 1, 1, 1, 1, 1, 1, 1]
    const x = [_]f64{ 1, 1, 1, 1, 1, 1, 1, 1 };
    var y: [8]f64 = undefined;

    gemvSimple(8, 8, &A, 8, &x, &y);

    // Each y[i] = sum of row i = 8 * (i+1)
    for (0..8) |i| {
        try std.testing.expectEqual(@as(f64, @floatFromInt((i + 1) * 8)), y[i]);
    }
}

test "matMul4x4 basic" {
    var A: [16]f64 align(32) = undefined;
    var B: [16]f64 align(32) = undefined;
    var C: [16]f64 align(32) = undefined;
    
    @memset(&A, 0);
    @memset(&B, 0);
    @memset(&C, 0);
    for (0..4) |i| {
        A[i * 4 + i] = 1.0;
        B[i * 4 + i] = 1.0;
    }
    
    matMul4x4(&A, &B, &C, 4, 4, 4);
    
    for (0..4) |i| {
        for (0..4) |j| {
            if (i == j) {
                try std.testing.expectEqual(@as(f64, 1.0), C[i * 4 + j]);
            } else {
                try std.testing.expectEqual(@as(f64, 0.0), C[i * 4 + j]);
            }
        }
    }
}

test "matMul8x8 basic" {
    var A: [64]f64 align(32) = undefined;
    var B: [64]f64 align(32) = undefined;
    var C: [64]f64 align(32) = undefined;
    
    // Identity matrices
    @memset(&A, 0);
    @memset(&B, 0);
    @memset(&C, 0);
    for (0..8) |i| {
        A[i * 8 + i] = 1.0;
        B[i * 8 + i] = 1.0;
    }
    
    matMul8x8(&A, &B, &C, 8, 8, 8);
    
    for (0..8) |i| {
        for (0..8) |j| {
            if (i == j) {
                try std.testing.expectEqual(@as(f64, 1.0), C[i * 8 + j]);
            } else {
                try std.testing.expectEqual(@as(f64, 0.0), C[i * 8 + j]);
            }
        }
    }
}

test "gemmParallel basic" {
    if (comptime is_wasm) return;
    
    const allocator = std.testing.allocator;
    var pool: threading.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = 4 });
    defer pool.deinit();
    
    const size = 32;
    const A = try allocator.alloc(f64, size * size);
    defer allocator.free(A);
    const B = try allocator.alloc(f64, size * size);
    defer allocator.free(B);
    const C = try allocator.alloc(f64, size * size);
    defer allocator.free(C);
    
    @memset(A, 1.0);
    @memset(B, 1.0);
    @memset(C, 0.0);
    
    gemmParallel(&pool, size, size, size, A, size, B, size, C, size);
    
    // Each element should be sum of 1*1 size times = size
    for (C) |val| {
        try std.testing.expectEqual(@as(f64, @floatFromInt(size)), val);
    }
}

test "luDecomposition & solveLU" {
    const n = 3;
    var A = [_]f64{
        2, -1, -2,
        -4, 6, 3,
        -4, -2, 8,
    };
    var P: [n]u32 = undefined;
    
    const success = luDecomposition(n, &A, n, &P);
    try std.testing.expect(success);
    
    // b = [2, 1, 4]
    var b = [_]f64{ 2, 1, 4 };
    solveLU(n, &A, n, &P, &b);
    
    // Expected x = [1, 2, -1]
    // Check Ax = b
    // 2(1) - 1(2) - 2(-1) = 2 - 2 + 2 = 2 (Correct)
    // -4(1) + 6(2) + 3(-1) = -4 + 12 - 3 = 5 (Wait, b[1] was 1)
    // -4 + 12 - 3 = 5. So if x=[1,2,-1], b should be [2, 5, -16]
    
    // Let's re-verify with a known case:
    // A = [1 1; 1 2], b = [3, 5] -> x = [1, 2]
    var A2 = [_]f64{ 1, 1, 1, 2 };
    var P2: [2]u32 = undefined;
    _ = luDecomposition(2, &A2, 2, &P2);
    var b2 = [_]f64{ 3, 5 };
    solveLU(2, &A2, 2, &P2, &b2);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b2[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), b2[1], 1e-6);
}

test "matrixInverse basic" {
    const allocator = std.testing.allocator;
    var A = [_]f64{ 1, 2, 3, 4 };
    // Inverse of [1 2; 3 4] is 1/(4-6) * [4 -2; -3 1] = [-2 1; 1.5 -0.5]
    const success = try matrixInverse(2, &A, 2, allocator);
    try std.testing.expect(success);
    
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), A[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), A[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), A[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), A[3], 1e-6);
}

test "determinant basic" {
    const allocator = std.testing.allocator;
    const A = [_]f64{ 1, 2, 3, 4 };
    const det = try determinant(2, &A, 2, allocator);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), det, 1e-6);
}


// ============================================================================
// Level 3+ BLAS: Matrix Factorization & Linear Solve
// ============================================================================

/// LU Decomposition with Partial Pivoting (PA = LU)
/// A is modified in-place to store L (lower triangular, diagonal=1) and U (upper triangular)
/// P stores the permutation vector
/// Returns true if successful, false if matrix is singular
pub fn luDecomposition(
    n: u32,
    A: []f64, stride_a: u32,
    P: []u32
) bool {
    // Initialize permutation vector
    for (0..n) |i| P[i] = @intCast(i);

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // Find pivot
        var max_val: f64 = 0;
        var pivot_row = i;
        
        var k = i;
        while (k < n) : (k += 1) {
            const val = @abs(A[k * stride_a + i]);
            if (val > max_val) {
                max_val = val;
                pivot_row = k;
            }
        }

        if (max_val < 1e-12) return false; // Singular matrix

        // Swap rows if necessary
        if (pivot_row != i) {
            // Swap permutation
            const temp_p = P[i];
            P[i] = P[pivot_row];
            P[pivot_row] = temp_p;

            // Swap rows in A
            var col: u32 = 0;
            while (col < n) : (col += 1) {
                const temp_a = A[i * stride_a + col];
                A[i * stride_a + col] = A[pivot_row * stride_a + col];
                A[pivot_row * stride_a + col] = temp_a;
            }
        }

        // LU algorithm
        var j = i + 1;
        while (j < n) : (j += 1) {
            A[j * stride_a + i] /= A[i * stride_a + i];
            
            var col = i + 1;
            while (col < n) : (col += 1) {
                A[j * stride_a + col] -= A[j * stride_a + i] * A[i * stride_a + col];
            }
        }
    }
    return true;
}

/// Solve Ax = b using LU decomposition (from luDecomposition)
/// b is modified in-place to store the solution x
pub fn solveLU(
    n: u32,
    LU: []const f64, stride_lu: u32,
    P: []const u32,
    b: []f64
) void {
    // Forward substitution (Ly = Pb)
    // Permute b according to P
    // We need a temporary vector for this
    // Since we don't want to allocate here, we assume b is already permuted if needed,
    // or we do it in-place carefully.
    // Actually, it's easier to use a temporary.
    // Given the constraints, let's do it in-place with swaps.
    
    // Simple approach: create a temporary b_perm
    // But we don't have an allocator here.
    // Let's assume the caller handles P or we use a fixed-size buffer if small.
    
    // For now, let's use a small fixed-size buffer on stack for n up to 256
    var b_perm: [256]f64 = undefined;
    for (0..n) |idx| {
        b_perm[idx] = b[P[idx]];
    }

    // Forward substitution: Ly = b_perm
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var sum: f64 = 0;
        var k: u32 = 0;
        while (k < i) : (k += 1) {
            sum += LU[i * stride_lu + k] * b_perm[k];
        }
        b_perm[i] = (b_perm[i] - sum); // L[i][i] is implicitly 1.0
    }

    // Backward substitution: Ux = y
    var ri: i32 = @as(i32, @intCast(n)) - 1;
    while (ri >= 0) : (ri -= 1) {
        const idx = @as(u32, @intCast(ri));
        var sum: f64 = 0;
        var k = idx + 1;
        while (k < n) : (k += 1) {
            sum += LU[idx * stride_lu + k] * b_perm[k];
        }
        b_perm[idx] = (b_perm[idx] - sum) / LU[idx * stride_lu + idx];
    }

    // Copy back to b
    for (0..n) |idx| {
        b[idx] = b_perm[idx];
    }
}

/// Compute matrix inverse in-place
/// Returns true if successful
pub fn matrixInverse(
    n: u32,
    A: []f64, stride_a: u32,
    allocator: std.mem.Allocator
) !bool {
    const size = @as(usize, n);
    const LU = try allocator.alloc(f64, size * size);
    defer allocator.free(LU);
    
    // Copy A to LU workspace
    for (0..size) |r| {
        for (0..size) |c| {
            LU[r * size + c] = A[r * stride_a + c];
        }
    }
    
    const P = try allocator.alloc(u32, n);
    defer allocator.free(P);
    
    if (!luDecomposition(n, LU, n, P)) return false;
    
    const b = try allocator.alloc(f64, n);
    defer allocator.free(b);

    // Solve for each column of the identity matrix
    for (0..size) |j| {
        @memset(b, 0.0);
        b[j] = 1.0;
        
        solveLU(n, LU, n, P, b);
        
        // The result is the j-th column of the inverse
        for (0..size) |i| {
            A[i * stride_a + j] = b[i];
        }
    }
    return true;
}

/// Compute matrix determinant
pub fn determinant(
    n: u32,
    A: []const f64, stride_a: u32,
    allocator: std.mem.Allocator
) !f64 {
    const size = @as(usize, n);
    const LU = try allocator.alloc(f64, size * size);
    defer allocator.free(LU);
    
    // Copy A to LU workspace
    for (0..size) |r| {
        for (0..size) |c| {
            LU[r * size + c] = A[r * stride_a + c];
        }
    }
    
    const P = try allocator.alloc(u32, n);
    defer allocator.free(P);
    
    if (!luDecomposition(n, LU, n, P)) return 0;
    
    var det: f64 = 1.0;
    for (0..size) |i| {
        det *= LU[i * size + i];
    }
    
    // Parity of permutation
    const visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);
    
    var parity: i32 = 1;
    for (0..n) |idx| {
        if (!visited[idx]) {
            var curr = idx;
            var cycle_len: u32 = 0;
            while (!visited[curr]) {
                visited[curr] = true;
                curr = P[curr];
                cycle_len += 1;
            }
            if (cycle_len > 1 and cycle_len % 2 == 0) parity *= -1;
        }
    }
    
    return det * @as(f64, @floatFromInt(parity));
}

/// Compute matrix trace (sum of diagonal elements)
pub fn matrixTrace(rows: u32, cols: u32, A: []const f64, stride_a: u32) f64 {
    var sum: f64 = 0;
    const n = @min(rows, cols);
    for (0..n) |i| {
        sum += A[i * stride_a + i];
    }
    return sum;
}

/// Compute 3D cross product of two vectors
/// Returns [3]f64
pub fn vecCross(a: []const f64, b: []const f64) [3]f64 {
    const ax = if (a.len > 0) a[0] else 0;
    const ay = if (a.len > 1) a[1] else 0;
    const az = if (a.len > 2) a[2] else 0;

    const bx = if (b.len > 0) b[0] else 0;
    const by = if (b.len > 1) b[1] else 0;
    const bz = if (b.len > 2) b[2] else 0;

    return .{
        ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx,
    };
}


