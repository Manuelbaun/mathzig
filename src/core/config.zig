const std = @import("std");

pub const AngleMode = enum {
    radians,
    degrees,
};

pub const Config = struct {
    angles: AngleMode = .radians,
    row_separator: u8 = ';',
    
    pub fn init() Config {
        return .{};
    }
};
