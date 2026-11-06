const std = @import("std");
const lifecycle = @import("service_lifecycle");

fn waitReady(io: std.Io, driver: lifecycle.driver.LifecycleDriver, key: lifecycle.registry.ServiceKey, endpoint: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const state = try driver.get(key);
        if (state.state == .ready) {
            const probe = lifecycle.health_probe.probe(io, endpoint, 250, "/readyz") catch {
                std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
                continue;
            };
            if (probe.ready) return;
        }
        std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
    return error.TestExpectedReady;
}

fn waitStopped(io: std.Io, endpoint: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const result = lifecycle.health_probe.probe(io, endpoint, 250, "/readyz");
        if (result) |_| {
            std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        } else |err| {
            if (err == error.FileNotFound or err == error.ConnectionRefused) return;
            return err;
        }
    }
    return error.TestExpectedStopped;
}

test "dev driver starts, probes, stops and restarts two real services" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const run_dir = try std.fmt.allocPrint(allocator, "/tmp/doctbase-dev-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(run_dir);
    std.Io.Dir.cwd().deleteTree(io, run_dir) catch {};

    var dev = try lifecycle.dev.DevDriver.init(allocator, io, .{
        .bin_dir = "zig-out/bin",
        .run_dir = run_dir,
        .internal_token = "dev-test-token",
        .inherit_stdio = false,
    });
    defer dev.deinit();

    const driver = dev.driver();
    defer driver.deinit();

    const gateway = try driver.start(.gateway);
    try std.testing.expect(gateway.ok);
    const auth = try driver.start(.auth);
    try std.testing.expect(auth.ok);

    const gateway_state = try driver.get(.gateway);
    const auth_state = try driver.get(.auth);
    try waitReady(io, driver, .gateway, gateway_state.endpoint.?);
    try waitReady(io, driver, .auth, auth_state.endpoint.?);

    try std.testing.expectEqual(lifecycle.driver.ServiceState.ready, (try driver.get(.gateway)).state);
    try std.testing.expectEqual(lifecycle.driver.ServiceState.ready, (try driver.get(.auth)).state);

    const stopped = try driver.stop(.gateway);
    try std.testing.expect(stopped.ok);
    try std.testing.expectEqual(lifecycle.driver.ServiceState.stopped, (try driver.get(.gateway)).state);
    try waitStopped(io, gateway_state.endpoint.?);

    const restarted = try driver.restart(.gateway);
    try std.testing.expect(restarted.ok);
    try waitReady(io, driver, .gateway, gateway_state.endpoint.?);

    _ = try driver.stop(.auth);
}
