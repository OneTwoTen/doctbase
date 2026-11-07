const std = @import("std");
const health = @import("install_health");

test "health uses the shared registry socket paths" {
    const options = health.registryOptions(5_000) orelse return error.MissingSocketPath;
    try std.testing.expectEqual(@as(u32, 5_000), options.timeout_ms);
    try std.testing.expectEqualStrings("/run/doctbase/gateway.sock", options.gateway_socket);
    try std.testing.expectEqualStrings("/run/doctbase/management.sock", options.management_socket);
    try std.testing.expectEqualStrings("/readyz", options.path);
}

test "missing sockets are reported as not ready without hanging" {
    const result = health.wait(std.testing.io, .{
        .timeout_ms = 0,
        .gateway_socket = "/tmp/doctbase-missing-gateway.sock",
        .management_socket = "/tmp/doctbase-missing-management.sock",
    });
    try std.testing.expect(!result.gateway_ready);
    try std.testing.expect(!result.management_ready);
}
