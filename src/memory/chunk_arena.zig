///! Chunk-based Arena Allocator for MathZig
///!
///! This allocator allocates memory in large chunks (64KB by default)
///! to minimize malloc overhead while still allowing growable memory.
///!
///! Benefits:
///! - Single malloc per chunk instead of per allocation
///! - Grows as needed (not hardcoded limits)
///! - Simple bump allocation within chunks
///! - Fast deallocation (just free all chunks at once)

const std = @import("std");

/// Chunk-based arena allocator
pub const ChunkArena = struct {
    /// Size of each chunk in bytes
    const CHUNK_SIZE = 64 * 1024; // 64KB
    
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged([]u8),
    current: []u8,
    pos: usize,
    allocated_bytes: usize,
    peak_bytes: usize,
    
    /// Create a new empty arena
    pub fn init(underlying_allocator: std.mem.Allocator) !ChunkArena {
        var self = ChunkArena{
            .allocator = underlying_allocator,
            .chunks = .empty,
            .current = &.{},
            .pos = 0,
            .allocated_bytes = 0,
            .peak_bytes = 0,
        };
        try self.addChunk();
        return self;
    }
    
    /// Add a new chunk to the arena
    fn addChunk(self: *ChunkArena) !void {
        const chunk = try self.allocator.alloc(u8, ChunkArena.CHUNK_SIZE);
        try self.chunks.append(self.allocator, chunk);
        self.current = chunk;
        self.pos = 0;
    }
    
    /// Allocate memory from the arena
    pub fn allocMem(self: *ChunkArena, comptime T: type, len: usize) []T {
        if (len == 0) return &.{};
        
        const bytes_needed = @sizeOf(T) * len;
        const align_needed = @alignOf(T);
        
        // Align position
        const aligned_pos = std.mem.alignForward(usize, self.pos, align_needed);
        
        // Check if we need a new chunk
        if (aligned_pos + bytes_needed > self.current.len) {
            // For large allocations, allocate a dedicated chunk
            if (bytes_needed > ChunkArena.CHUNK_SIZE / 2) {
                const large_chunk_T = self.allocator.alloc(T, len) catch {
                    // Out of memory - return empty slice
                    return &.{};
                };
                const large_chunk_u8 = std.mem.sliceAsBytes(large_chunk_T);
                self.chunks.append(self.allocator, large_chunk_u8) catch {};
                
                self.allocated_bytes += bytes_needed;
                if (self.allocated_bytes > self.peak_bytes) self.peak_bytes = self.allocated_bytes;
                
                return large_chunk_T;
            }
            
            // Add new chunk and retry
            self.addChunk() catch {
                // If we can't add a chunk, return empty slice
                return &.{};
            };
            return self.allocMem(T, len); // Retry with new chunk
        }
        
        // Allocate from current chunk
        self.pos = aligned_pos + bytes_needed;
        self.allocated_bytes += bytes_needed;
        if (self.allocated_bytes > self.peak_bytes) self.peak_bytes = self.allocated_bytes;
        
        // Safe to cast since we aligned the position
        const ptr = @as([*]T, @alignCast(@ptrCast(self.current[aligned_pos..].ptr)));
        return ptr[0..len];
    }
    
    /// Allocate and initialize with zeros
    pub fn allocZeros(self: *ChunkArena, comptime T: type, len: usize) []T {
        const slice = self.allocMem(T, len);
        @memset(@as([]u8, @ptrCast(slice)), 0);
        return slice;
    }
    
    /// Duplicate a string into the arena
    pub fn dupeStr(self: *ChunkArena, str: []const u8) []u8 {
        const copy = self.allocMem(u8, str.len);
        @memcpy(copy, str);
        return copy;
    }
    
    /// Get the total memory used (reserved)
    pub fn totalReserved(self: *ChunkArena) usize {
        var total: usize = 0;
        for (self.chunks.items) |chunk| {
            total += chunk.len;
        }
        return total;
    }
    
    /// Get the number of chunks
    pub fn chunkCount(self: *ChunkArena) usize {
        return self.chunks.items.len;
    }
    
    /// Reset the arena, keeping memory for reuse
    pub fn reset(self: *ChunkArena) void {
        if (self.chunks.items.len > 1) {
            // Keep only the first chunk if we have many, to avoid holding too much memory
            // Or just keep the first one.
            for (self.chunks.items[1..]) |chunk| {
                self.allocator.free(chunk);
            }
            self.chunks.shrinkAndFree(self.allocator, 1);
        }
        
        if (self.chunks.items.len > 0) {
            self.current = self.chunks.items[0];
            self.pos = 0;
        }
        
        self.allocated_bytes = 0;
    }

    /// Free all chunks
    pub fn deinit(self: *ChunkArena) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.chunks.deinit(self.allocator);
        self.current = &.{};
        self.pos = 0;
        self.allocated_bytes = 0;
        self.peak_bytes = 0;
    }

    /// Allocate memory from the arena with specific alignment
    pub fn allocAligned(self: *ChunkArena, len: usize, alignment: usize) []u8 {
        if (len == 0) return &.{};
        
        const bytes_needed = len;
        const align_needed = alignment;
        
        // Align position
        const aligned_pos = std.mem.alignForward(usize, self.pos, align_needed);
        
        // Check if we need a new chunk
        if (aligned_pos + bytes_needed > self.current.len) {
            // For large allocations, allocate a dedicated chunk
            if (bytes_needed > ChunkArena.CHUNK_SIZE / 2) {
                const res = switch (alignment) {
                    1 => self.allocator.alloc(u8, len) catch null,
                    2 => self.allocator.alignedAlloc(u8, .@"2", len) catch null,
                    4 => self.allocator.alignedAlloc(u8, .@"4", len) catch null,
                    8 => self.allocator.alignedAlloc(u8, .@"8", len) catch null,
                    16 => self.allocator.alignedAlloc(u8, .@"16", len) catch null,
                    32 => self.allocator.alignedAlloc(u8, .@"32", len) catch null,
                    64 => self.allocator.alignedAlloc(u8, .@"64", len) catch null,
                    else => self.allocator.alloc(u8, len) catch null,
                };
                
                if (res) |slice| {
                    self.chunks.append(self.allocator, slice) catch {};
                    self.allocated_bytes += bytes_needed;
                    if (self.allocated_bytes > self.peak_bytes) self.peak_bytes = self.allocated_bytes;
                    return slice;
                }
                return &.{};
            }
            
            // Add new chunk and retry
            self.addChunk() catch {
                return &.{};
            };
            return self.allocAligned(len, alignment); 
        }
        
        // Allocate from current chunk
        self.pos = aligned_pos + bytes_needed;
        self.allocated_bytes += bytes_needed;
        if (self.allocated_bytes > self.peak_bytes) self.peak_bytes = self.allocated_bytes;
        return self.current[aligned_pos .. aligned_pos + len];
    }

    pub fn getAllocator(self: *ChunkArena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *ChunkArena = @ptrCast(@alignCast(ctx));
        const slice = self.allocAligned(len, ptr_align.toByteUnits());
        if (slice.len < len) return null;
        return slice.ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        return false; // Arenas don't typically support resize
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        // Arenas don't free individual buffers
    }
};

// Tests
test "ChunkArena basic allocation" {
    const allocator = std.testing.allocator;
    var arena = try ChunkArena.init(allocator);
    defer arena.deinit();
    
    // Allocate some integers
    const ints = arena.allocMem(i32, 10);
    try std.testing.expectEqual(@as(usize, 10), ints.len);
    
    // Fill with values
    for (ints, 0..) |*val, i| {
        val.* = @intCast(i);
    }
    
    // Check values
    for (ints, 0..) |val, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), val);
    }
}

test "ChunkArena string duplication" {
    const allocator = std.testing.allocator;
    var arena = try ChunkArena.init(allocator);
    defer arena.deinit();
    
    const original = "hello world";
    const copy = arena.dupeStr(original);
    
    try std.testing.expectEqualStrings(original, copy);
}

test "ChunkArena grows with multiple allocations" {
    const allocator = std.testing.allocator;
    var arena = try ChunkArena.init(allocator);
    defer arena.deinit();
    
    // Allocate multiple times
    for (0..100) |i| {
        // Allocate 1KB each time (256 * 4 bytes)
        const slice = arena.allocMem(i32, 256);
        try std.testing.expectEqual(@as(usize, 256), slice.len);
        slice[0] = @intCast(i);
    }
    
    // Should have grown to multiple chunks (100KB total > 64KB chunk)
    try std.testing.expect(arena.chunkCount() > 1);
}

test "ChunkArena total used" {
    const allocator = std.testing.allocator;
    var arena = try ChunkArena.init(allocator);
    defer arena.deinit();
    
    const initial_used = arena.totalReserved();
    
    // Allocate large memory to force new chunk
    _ = arena.allocMem(u8, 70 * 1024);
    
    const after_alloc = arena.totalReserved();
    try std.testing.expect(after_alloc > initial_used);
}
