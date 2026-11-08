const std = @import("std");
const runtime = @import("runtime");
const lifecycle = @import("service_lifecycle");

fn acceptAndHold(io: std.Io, server: *std.Io.net.Server) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    std.Io.sleep(io, .{ .nanoseconds = 300 * std.time.ns_per_ms }, .awake) catch {};
}

test "health probe times out instead of aborting on a non-HTTP peer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-probe-timeout-{d}.sock", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const thread = try std.Thread.spawn(.{}, acceptAndHold, .{ io, &server });
    defer thread.join();

    try std.testing.expectError(
        error.Timeout,
        lifecycle.health_probe.probe(io, socket_path, 100, "/readyz"),
    );
}

test "health probe reports readiness and propagates missing socket" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-probe-test-{d}.sock", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const app = try runtime.Runtime.create(allocator, io, .{
        .service_key = "probe-test",
        .mode = .dev,
        .socket_path = socket_path,
        .allow_missing_config = true,
        .install_signal_handlers = false,
    });
    defer app.destroy();
    try app.start();

    const ready = try lifecycle.health_probe.probe(io, socket_path, 1000, "/readyz");
    try std.testing.expectEqual(@as(u16, 200), ready.status);
    try std.testing.expect(ready.ready);

    const missing = try lifecycle.health_probe.probe(io, socket_path, 1000, "/missing");
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expect(!missing.ready);

    app.requestShutdown();
    app.wait();

    try std.testing.expectError(error.FileNotFound, lifecycle.health_probe.probe(io, socket_path, 1000, "/readyz"));
}
