const std = @import("std");
const runtime = @import("runtime");
const lifecycle = @import("service_lifecycle");

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
