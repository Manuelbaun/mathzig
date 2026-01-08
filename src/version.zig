const std = @import("std");

pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const semver: []const u8 = std.mem.trim(u8, @embedFile("VERSION"), " \t\r\n");
pub const parsed: SemVer = parseSemVer(semver);
pub const semver_z: [:0]const u8 = (semver ++ "\x00")[0..semver.len :0];

pub fn cString() [*:0]const u8 {
    return semver_z.ptr;
}

pub fn versionNumber() f64 {
    return @as(f64, @floatFromInt(parsed.major)) +
        (@as(f64, @floatFromInt(parsed.minor)) / 100.0) +
        (@as(f64, @floatFromInt(parsed.patch)) / 10_000.0);
}

fn parseSemVer(s: []const u8) SemVer {
    var it = std.mem.splitScalar(u8, s, '.');
    const major_s = it.next() orelse @compileError("VERSION must be MAJOR.MINOR.PATCH");
    const minor_s = it.next() orelse @compileError("VERSION must be MAJOR.MINOR.PATCH");
    const patch_s = it.next() orelse @compileError("VERSION must be MAJOR.MINOR.PATCH");
    if (it.next() != null) @compileError("VERSION must be MAJOR.MINOR.PATCH");

    const major = std.fmt.parseInt(u32, major_s, 10) catch @compileError("Invalid major in VERSION");
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch @compileError("Invalid minor in VERSION");
    const patch = std.fmt.parseInt(u32, patch_s, 10) catch @compileError("Invalid patch in VERSION");

    return .{ .major = major, .minor = minor, .patch = patch };
}
