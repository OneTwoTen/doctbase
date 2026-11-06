const std = @import("std");
const schema = @import("schema.zig");

pub fn defaultConfig(allocator: std.mem.Allocator) schema.Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

test "default config values" {
    var cfg = defaultConfig(std.testing.allocator);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u32, 1), cfg.schema_version);
    try std.testing.expectEqualStrings("doctbase", cfg.instance.name);
    try std.testing.expectEqual(schema.DatabaseMode.managed, cfg.database.mode);
}
