const std = @import("std");

/// Zig 0.16 compatibility shim: `ArrayListUnmanaged` no longer exposes `.writer()`.
pub fn unmanagedByteWriter(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) UnmanagedByteWriter {
    return .{ .list = list, .allocator = allocator };
}

pub const UnmanagedByteWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn writeByte(self: *const UnmanagedByteWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn writeAll(self: *const UnmanagedByteWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *const UnmanagedByteWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.writeAll(formatted);
    }
};