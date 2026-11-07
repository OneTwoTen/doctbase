const std = @import("std");
const config_file = @import("install_config");
const config_mod = @import("config");

test "generated instance configuration parses with the documented defaults" {
    const allocator = std.testing.allocator;
    const contents = try config_file.render(allocator, .{
        .domain = "example.com",
        .email = "admin@example.com",
    });
    defer allocator.free(contents);

    var config = try config_mod.fromSource(allocator, contents);
    defer config.deinit();

    try std.testing.expectEqualStrings("doctbase", config.instance.name);
    try std.testing.expectEqualStrings("example.com", config.instance.domain);
    try std.testing.expectEqualStrings("admin@example.com", config.instance.admin_email);
    try std.testing.expectEqual(config_mod.DatabaseMode.managed, config.database.mode);
    try std.testing.expect(config.pooler.enabled);
    try std.testing.expectEqual(config_mod.ProxyMode.caddy, config.proxy.mode);
    try std.testing.expect(config.services.auth);
    try std.testing.expect(!config.services.rest);
    try std.testing.expectEqual(config_mod.StorageBackend.local, config.storage.backend);
}

test "local mode renders an empty domain that the parser accepts" {
    const allocator = std.testing.allocator;
    const contents = try config_file.render(allocator, .{});
    defer allocator.free(contents);

    var config = try config_mod.fromSource(allocator, contents);
    defer config.deinit();
    try std.testing.expectEqualStrings("", config.instance.domain);
    try std.testing.expectEqualStrings("", config.instance.admin_email);
}

test "configuration values cannot inject TOML syntax" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidDomain,
        config_file.render(allocator, .{ .domain = "example.com\"\n[security]" }),
    );
    try std.testing.expectError(
        error.InvalidEmail,
        config_file.render(allocator, .{ .email = "admin@example.com\"\n[security]" }),
    );
}
