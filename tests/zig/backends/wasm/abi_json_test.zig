const std = @import("std");
const mathzig = @import("mathzig");
const abi = mathzig.wasm.abi;
const BuiltinFn = mathzig.BuiltinFn;

test "aot_abi.json serialization covers every builtin and is parseable" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try abi.writeAotAbiJson(&out.writer);
    const buffer = out.written();

    try std.testing.expect(std.mem.indexOf(u8, buffer, "\"abi_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer, "\"sin\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer, "\"args\": [\"number\"]") != null or
        std.mem.indexOf(u8, buffer, "\"args\": [\"number\"],") != null);

    inline for (std.meta.fields(BuiltinFn)) |field| {
        const needle = try std.fmt.allocPrint(std.testing.allocator, "\"{s}\":", .{field.name});
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, buffer, needle) != null);
    }
}