const std = @import("std");
const Value = @import("../core/value.zig").Value;
const bytecode = @import("../vm/bytecode.zig");
const Instruction = bytecode.Instruction;
const CompiledExpr = bytecode.CompiledExpr;

/// Cache for compilation buffers to avoid allocations for small expressions
pub const CompilerCache = struct {
    /// Pre-allocated buffer for all compilation data
    /// Aligned to 8 bytes for f64/Value compatibility
    buffer: [256 * 1024]u8 align(8) = undefined,
    
    // Fixed buffer allocator
    fba: std.heap.FixedBufferAllocator,
    
    pub fn init() CompilerCache {
        return .{
            .fba = undefined, // Initialized when used
        };
    }
    
    /// Reset the allocator to point to the beginning of buffer
    pub fn reset(self: *CompilerCache) void {
        self.fba = std.heap.FixedBufferAllocator.init(&self.buffer);
    }
    
    /// Get allocator
    pub fn getAllocator(self: *CompilerCache) std.mem.Allocator {
        return self.fba.allocator();
    }
};
