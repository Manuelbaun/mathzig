const std = @import("std");

/// Dimensions represent the exponents of base SI units.
/// [Mass, Length, Time, Current, Temperature, Substance, Luminosity]
pub const Dimensions = struct {
    m: i8 = 0, // Mass (kg)
    l: i8 = 0, // Length (m)
    t: i8 = 0, // Time (s)
    i: i8 = 0, // Current (A)
    k: i8 = 0, // Temperature (K)
    n: i8 = 0, // Substance (mol)
    j: i8 = 0, // Luminosity (cd)

    pub fn equals(a: Dimensions, b: Dimensions) bool {
        return a.m == b.m and a.l == b.l and a.t == b.t and a.i == b.i and
            a.k == b.k and a.n == b.n and a.j == b.j;
    }

    pub fn multiply(a: Dimensions, b: Dimensions) Dimensions {
        return .{
            .m = a.m + b.m,
            .l = a.l + b.l,
            .t = a.t + b.t,
            .i = a.i + b.i,
            .k = a.k + b.k,
            .n = a.n + b.n,
            .j = a.j + b.j,
        };
    }

    pub fn divide(a: Dimensions, b: Dimensions) Dimensions {
        return .{
            .m = a.m - b.m,
            .l = a.l - b.l,
            .t = a.t - b.t,
            .i = a.i - b.i,
            .k = a.k - b.k,
            .n = a.n - b.n,
            .j = a.j - b.j,
        };
    }

    pub fn isScalar(a: Dimensions) bool {
        return a.m == 0 and a.l == 0 and a.t == 0 and a.i == 0 and
            a.k == 0 and a.n == 0 and a.j == 0;
    }

    pub fn format(self: Dimensions, allocator: std.mem.Allocator) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;

        var first = true;
        const fields = [_]struct { name: []const u8, val: i8 }{
            .{ .name = "kg", .val = self.m },
            .{ .name = "m", .val = self.l },
            .{ .name = "s", .val = self.t },
            .{ .name = "A", .val = self.i },
            .{ .name = "K", .val = self.k },
            .{ .name = "mol", .val = self.n },
            .{ .name = "cd", .val = self.j },
        };

        // Handle positive exponents first
        for (fields) |f| {
            if (f.val > 0) {
                if (!first) try writer.writeByte('*');
                try writer.writeAll(f.name);
                if (f.val > 1) {
                    try writer.print("^{d}", .{f.val});
                }
                first = false;
            }
        }

        // Handle negative exponents
        var first_neg = true;
        for (fields) |f| {
            if (f.val < 0) {
                if (first) {
                    try writer.writeAll("1/");
                    first = false;
                    first_neg = false;
                } else if (first_neg) {
                    try writer.writeByte('/');
                    first_neg = false;
                } else {
                    try writer.writeByte('*');
                }
                try writer.writeAll(f.name);
                if (f.val < -1) {
                    try writer.print("^{d}", .{-f.val});
                }
            }
        }

        if (first) return try allocator.dupe(u8, "1");
        return aw.toOwnedSlice();
    }
};

pub const Unit = struct {
    name: []const u8,
    dimensions: Dimensions,
    scale: f64, // Factor to normalize to base units
    offset: f64 = 0, // For temperature (Celsius/Fahrenheit)
};

pub const UnitRegistry = struct {
    units: std.StringHashMap(Unit),
    prefixes: std.StringHashMap(f64),
    preferred_units: std.AutoHashMap(Dimensions, []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !UnitRegistry {
        var self = UnitRegistry{
            .units = std.StringHashMap(Unit).init(allocator),
            .prefixes = std.StringHashMap(f64).init(allocator),
            .preferred_units = std.AutoHashMap(Dimensions, []const u8).init(allocator),
            .allocator = allocator,
        };

        // Standard Prefixes
        try self.prefixes.put("Y", 1e24);
        try self.prefixes.put("Z", 1e21);
        try self.prefixes.put("E", 1e18);
        try self.prefixes.put("P", 1e15);
        try self.prefixes.put("T", 1e12);
        try self.prefixes.put("G", 1e9);
        try self.prefixes.put("M", 1e6);
        try self.prefixes.put("k", 1e3);
        try self.prefixes.put("h", 1e2);
        try self.prefixes.put("da", 1e1);
        try self.prefixes.put("d", 1e-1);
        try self.prefixes.put("c", 1e-2);
        try self.prefixes.put("m", 1e-3);
        try self.prefixes.put("u", 1e-6);
        try self.prefixes.put("n", 1e-9);
        try self.prefixes.put("p", 1e-12);
        try self.prefixes.put("f", 1e-15);
        try self.prefixes.put("a", 1e-18);
        try self.prefixes.put("z", 1e-21);
        try self.prefixes.put("y", 1e-24);

        // Base Units
        try self.addUnit("m", .{ .l = 1 }, 1.0); // Meter
        try self.addUnit("kg", .{ .m = 1 }, 1.0); // Kilogram
        try self.addUnit("s", .{ .t = 1 }, 1.0); // Second
        try self.addUnit("A", .{ .i = 1 }, 1.0); // Ampere
        try self.addUnit("K", .{ .k = 1 }, 1.0); // Kelvin
        try self.addUnit("mol", .{ .n = 1 }, 1.0); // Mole
        try self.addUnit("cd", .{ .j = 1 }, 1.0); // Candela

        // Dimensionless Coherent Derived Units
        try self.addUnit("rad", .{}, 1.0); // Radian
        try self.addUnit("deg", .{}, std.math.pi / 180.0); // Degree
        try self.addUnit("sr", .{}, 1.0); // Steradian

        // Coherent Derived Units with Special Names
        try self.addUnit("Hz", .{ .t = -1 }, 1.0); // Hertz
        try self.addUnit("N", .{ .m = 1, .l = 1, .t = -2 }, 1.0); // Newton
        try self.addUnit("Pa", .{ .m = 1, .l = -1, .t = -2 }, 1.0); // Pascal
        try self.addUnit("J", .{ .m = 1, .l = 2, .t = -2 }, 1.0); // Joule
        try self.addUnit("joule", .{ .m = 1, .l = 2, .t = -2 }, 1.0);
        try self.addUnit("W", .{ .m = 1, .l = 2, .t = -3 }, 1.0); // Watt
        try self.addUnit("w", .{ .m = 1, .l = 2, .t = -3 }, 1.0); // alias
        try self.addUnit("watt", .{ .m = 1, .l = 2, .t = -3 }, 1.0);
        try self.addUnit("C", .{ .t = 1, .i = 1 }, 1.0); // Coulomb
        try self.addUnit("V", .{ .m = 1, .l = 2, .t = -3, .i = -1 }, 1.0); // Volt
        try self.addUnit("F", .{ .m = -1, .l = -2, .t = 4, .i = 2 }, 1.0); // Farad
        try self.addUnit("ohm", .{ .m = 1, .l = 2, .t = -3, .i = -2 }, 1.0); // Ohm (use 'ohm' instead of symbol for now)
        try self.addUnit("S", .{ .m = -1, .l = -2, .t = 3, .i = 2 }, 1.0); // Siemens
        try self.addUnit("Wb", .{ .m = 1, .l = 2, .t = -2, .i = -1 }, 1.0); // Weber
        try self.addUnit("T", .{ .m = 1, .t = -2, .i = -1 }, 1.0); // Tesla
        try self.addUnit("H", .{ .m = 1, .l = 2, .t = -2, .i = -2 }, 1.0); // Henry
        try self.addUnit("lm", .{ .j = 1 }, 1.0); // Lumen (sr is dimensionless)
        try self.addUnit("lx", .{ .l = -2, .j = 1 }, 1.0); // Lux
        try self.addUnit("Bq", .{ .t = -1 }, 1.0); // Becquerel
        try self.addUnit("Gy", .{ .l = 2, .t = -2 }, 1.0); // Gray
        try self.addUnit("Sv", .{ .l = 2, .t = -2 }, 1.0); // Sievert
        try self.addUnit("kat", .{ .t = -1, .n = 1 }, 1.0); // Katal

        // Energy
        try self.addUnit("Wh", .{ .m = 1, .l = 2, .t = -2 }, 3600.0); // Watt-hour (Joule * 3600)
        try self.addUnit("BTU", .{ .m = 1, .l = 2, .t = -2 }, 1055.056); // British Thermal Unit
        try self.addUnit("cal", .{ .m = 1, .l = 2, .t = -2 }, 4.184); // Calorie (thermochemical)
        try self.addUnit("eV", .{ .m = 1, .l = 2, .t = -2 }, 1.602176634e-19); // Electronvolt

        // Power
        try self.addUnit("hp", .{ .m = 1, .l = 2, .t = -3 }, 745.7); // Horsepower (mechanical)

        // Metric derived
        try self.addUnit("g", .{ .m = 1 }, 1e-3); // Gram
        try self.addUnit("tonne", .{ .m = 1 }, 1e3); // Tonne
        try self.addUnit("L", .{ .l = 3 }, 1e-3); // Liter (1 dm^3)
        try self.addUnit("l", .{ .l = 3 }, 1e-3); // alias

        // Imperial/US derived
        try self.addUnit("in", .{ .l = 1 }, 0.0254); // Inch
        try self.addUnit("inch", .{ .l = 1 }, 0.0254); // Alias
        try self.addUnit("ft", .{ .l = 1 }, 0.3048); // Foot
        try self.addUnit("yd", .{ .l = 1 }, 0.9144); // Yard
        try self.addUnit("mi", .{ .l = 1 }, 1609.344); // Mile
        try self.addUnit("psi", .{ .m = 1, .l = -1, .t = -2 }, 6894.757); // Pounds per square inch

        // Time derived
        try self.addUnit("min", .{ .t = 1 }, 60.0);
        try self.addUnit("h", .{ .t = 1 }, 3600.0);
        try self.addUnit("day", .{ .t = 1 }, 86400.0);
        try self.addUnit("week", .{ .t = 1 }, 604800.0);
        try self.addUnit("month", .{ .t = 1 }, 2629800.0); // Average month (year/12)
        try self.addUnit("year", .{ .t = 1 }, 31557600.0); // Julian year (365.25 days)

        // Temperature
        try self.addUnitWithOffset("degC", .{ .k = 1 }, 1.0, 273.15); // Celsius
        try self.addUnitWithOffset("degF", .{ .k = 1 }, 5.0 / 9.0, 459.67 * 5.0 / 9.0); // Fahrenheit

        return self;
    }

    pub fn deinit(self: *UnitRegistry) void {
        var it = self.units.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.units.deinit();
        self.prefixes.deinit();
        self.preferred_units.deinit();
    }

    pub fn addUnit(self: *UnitRegistry, name: []const u8, dims: Dimensions, scale: f64) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        try self.units.put(owned_name, .{ .name = owned_name, .dimensions = dims, .scale = scale });
    }

    pub fn addUnitWithOffset(self: *UnitRegistry, name: []const u8, dims: Dimensions, scale: f64, offset: f64) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        try self.units.put(owned_name, .{ .name = owned_name, .dimensions = dims, .scale = scale, .offset = offset });
    }

    pub fn setPreferredUnit(self: *UnitRegistry, dims: Dimensions, name: []const u8) !void {
        try self.preferred_units.put(dims, name);
    }

    pub fn findUnit(self: *const UnitRegistry, name: []const u8) ?struct { unit: Unit, prefix_scale: f64 } {
        // Direct match
        if (self.units.get(name)) |u| {
            return .{ .unit = u, .prefix_scale = 1.0 };
        }

        // Try multi-character prefixes first
        if (name.len > 2) {
            const prefix2 = name[0..2];
            if (self.prefixes.get(prefix2)) |p_scale| {
                const base = name[2..];
                if (self.units.get(base)) |u| {
                    return .{ .unit = u, .prefix_scale = p_scale };
                }
            }
        }

        // Try single-character prefix
        if (name.len > 1) {
            const prefix1 = name[0..1];
            if (self.prefixes.get(prefix1)) |p_scale| {
                const base = name[1..];
                if (self.units.get(base)) |u| {
                    return .{ .unit = u, .prefix_scale = p_scale };
                }
            }
        }

        return null;
    }

    pub fn findBestUnit(self: *const UnitRegistry, dims: Dimensions) ?[]const u8 {
        // 1. Check user preferences
        if (self.preferred_units.get(dims)) |name| {
            return name;
        }

        // 2. Search for best fit in registry
        var best_name: ?[]const u8 = null;
        var best_unit: ?Unit = null;

        var it = self.units.iterator();
        while (it.next()) |entry| {
            const unit = entry.value_ptr.*;
            if (unit.dimensions.equals(dims)) {
                if (best_unit == null) {
                    best_name = entry.key_ptr.*;
                    best_unit = unit;
                } else {
                    // Priority: SI (scale 1.0, no offset) > shorter names
                    const cur_is_si = unit.scale == 1.0 and unit.offset == 0;
                    const best_is_si = best_unit.?.scale == 1.0 and best_unit.?.offset == 0;

                    if (cur_is_si and !best_is_si) {
                        best_name = entry.key_ptr.*;
                        best_unit = unit;
                    } else if (cur_is_si == best_is_si) {
                        if (entry.key_ptr.*.len < best_name.?.len) {
                            best_name = entry.key_ptr.*;
                            best_unit = unit;
                        }
                    }
                }
            }
        }

        return best_name;
    }
};

// Tests
test "UnitRegistry basic lookup" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    const m = registry.findUnit("m");
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(f64, 1.0), m.?.unit.scale);
    try std.testing.expectEqual(@as(i8, 1), m.?.unit.dimensions.l);

    const inch = registry.findUnit("in");
    try std.testing.expect(inch != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0254), inch.?.unit.scale, 0.0001);
}

test "UnitRegistry prefixes" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    const cm = registry.findUnit("cm");
    try std.testing.expect(cm != null);
    try std.testing.expectEqualStrings("m", cm.?.unit.name);
    try std.testing.expectEqual(@as(f64, 0.01), cm.?.prefix_scale);

    const km = registry.findUnit("km");
    try std.testing.expect(km != null);
    try std.testing.expectEqual(@as(f64, 1000.0), km.?.prefix_scale);

    const dam = registry.findUnit("dam");
    try std.testing.expect(dam != null);
    try std.testing.expectEqual(@as(f64, 10.0), dam.?.prefix_scale);
}

test "UnitRegistry full SI set" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    const volt = registry.findUnit("V");
    try std.testing.expect(volt != null);
    try std.testing.expectEqual(@as(i8, 1), volt.?.unit.dimensions.m);
    try std.testing.expectEqual(@as(i8, 2), volt.?.unit.dimensions.l);
    try std.testing.expectEqual(@as(i8, -3), volt.?.unit.dimensions.t);
    try std.testing.expectEqual(@as(i8, -1), volt.?.unit.dimensions.i);

    const ohm = registry.findUnit("ohm");
    try std.testing.expect(ohm != null);
}

test "UnitRegistry derived units" {
    const allocator = std.testing.allocator;
    var registry = try UnitRegistry.init(allocator);
    defer registry.deinit();

    const newton = registry.findUnit("N");
    try std.testing.expect(newton != null);
    try std.testing.expectEqual(@as(i8, 1), newton.?.unit.dimensions.m);
    try std.testing.expectEqual(@as(i8, 1), newton.?.unit.dimensions.l);
    try std.testing.expectEqual(@as(i8, -2), newton.?.unit.dimensions.t);
}

test "Dimensions formatting" {
    const allocator = std.testing.allocator;

    const d1 = Dimensions{ .l = 2 };
    const s1 = try d1.format(allocator);
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("m^2", s1);

    const d2 = Dimensions{ .l = 1, .t = -1 };
    const s2 = try d2.format(allocator);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("m/s", s2);

    const d3 = Dimensions{ .m = 1, .l = 1, .t = -2 };
    const s3 = try d3.format(allocator);
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("kg*m/s^2", s3);

    const d4 = Dimensions{ .t = -1 };
    const s4 = try d4.format(allocator);
    defer allocator.free(s4);
    try std.testing.expectEqualStrings("1/s", s4);
}