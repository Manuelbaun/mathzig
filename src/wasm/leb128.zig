const std = @import("std");
const list_writer = @import("list_writer.zig");

/// Encodes an unsigned integer as ULEB128 to the given writer.
/// Returns the number of bytes written.
pub fn encodeUnsigned(writer: anytype, value: anytype) !usize {
    var val: u64 = @intCast(value);
    var bytes_written: usize = 0;
    
    while (true) {
        var byte: u8 = @intCast(val & 0x7F);
        val >>= 7;
        
        if (val != 0) {
            byte |= 0x80;
        }
        
        try writer.writeByte(byte);
        bytes_written += 1;
        
        if (val == 0) {
            break;
        }
    }
    
    return bytes_written;
}

/// Encodes an unsigned integer as ULEB128 into a fixed buffer.
/// Returns the number of bytes written.
pub fn encodeUnsignedFixed(buf: []u8, value: anytype) !usize {
    var val: u64 = @intCast(value);
    var bytes_written: usize = 0;

    while (true) {
        var byte: u8 = @intCast(val & 0x7F);
        val >>= 7;

        if (val != 0) {
            byte |= 0x80;
        }

        if (bytes_written >= buf.len) return error.BufferTooSmall;
        buf[bytes_written] = byte;
        bytes_written += 1;

        if (val == 0) break;
    }

    return bytes_written;
}

/// Encodes a signed integer as SLEB128 to the given writer.
/// Returns the number of bytes written.
pub fn encodeSigned(writer: anytype, value: anytype) !usize {
    var val: i64 = @intCast(value);
    var bytes_written: usize = 0;
    const more_mask: u8 = 0x80;
    
    // Determine the size of the type in bits to handle sign extension logic correctly if needed,
    // though the algorithm usually works on the raw value bits.
    // For Zig, we just treat `val` as a mutable signed integer of sufficient size.
    
    while (true) {
        var byte: u8 = @intCast(val & 0x7F);
        val >>= 7;
        
        // Sign bit of byte is 2nd high order bit (0x40)
        const sign_bit = (byte & 0x40) != 0;
        
        // If (val == 0 && !sign_bit) || (val == -1 && sign_bit) -> done
        if ((val == 0 and !sign_bit) or (val == -1 and sign_bit)) {
            try writer.writeByte(byte);
            bytes_written += 1;
            break;
        } else {
            byte |= more_mask;
            try writer.writeByte(byte);
            bytes_written += 1;
        }
    }
    
    return bytes_written;
}

test "ULEB128 encoding" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const w = list_writer.unmanagedByteWriter(&buf, std.testing.allocator);

    // 0 -> [00]
    buf.clearRetainingCapacity();
    _ = try encodeUnsigned(w, @as(u32, 0));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, buf.items);

    // 127 -> [7F]
    buf.clearRetainingCapacity();
    _ = try encodeUnsigned(w, @as(u32, 127));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf.items);

    // 128 -> [80, 01]
    buf.clearRetainingCapacity();
    _ = try encodeUnsigned(w, @as(u32, 128));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80, 0x01}, buf.items);
    
    // 624485 -> [E5, 8E, 26]
    buf.clearRetainingCapacity();
    _ = try encodeUnsigned(w, @as(u32, 624485));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xE5, 0x8E, 0x26}, buf.items);
}

test "SLEB128 encoding" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const w = list_writer.unmanagedByteWriter(&buf, std.testing.allocator);

    // 0 -> [00]
    buf.clearRetainingCapacity();
    _ = try encodeSigned(w, @as(i32, 0));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, buf.items);

    // -1 -> [7F]
    buf.clearRetainingCapacity();
    _ = try encodeSigned(w, @as(i32, -1));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf.items);

    // 1 -> [01]
    buf.clearRetainingCapacity();
    _ = try encodeSigned(w, @as(i32, 1));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, buf.items);

    // -128 -> [80, 7F]
    buf.clearRetainingCapacity();
    _ = try encodeSigned(w, @as(i32, -128));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80, 0x7F}, buf.items);
    
    // -64 -> [40]
    buf.clearRetainingCapacity();
    _ = try encodeSigned(w, @as(i32, -64));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x40}, buf.items);
}
