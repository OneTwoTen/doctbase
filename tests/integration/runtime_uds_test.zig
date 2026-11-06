const std = @import("std");
const runtime = @import("runtime");

fn request(io: std.Io, allocator: std.mem.Allocator, socket_path: []const u8, raw: []const u8) ![]u8 {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(raw);
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(allocator);

    while (true) {
        var chunk: [512]u8 = undefined;
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        try response.appendSlice(allocator, chunk[0..count]);
    }

    return response.toOwnedSlice(allocator);
}

test "runtime serves health, readiness, info and graceful shutdown over UDS" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-runtime-test-{d}.sock", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const app = try runtime.Runtime.create(allocator, io, .{
        .service_key = "test-service",
        .version = "0.0.1-test",
        .commit = "test",
        .mode = .dev,
        .socket_path = socket_path,
        .internal_token = "test-token",
        .allow_missing_config = true,
        .install_signal_handlers = false,
    });
    defer app.destroy();

    try app.start();

    const health = try request(io, allocator, socket_path, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(health);
    try std.testing.expect(std.mem.startsWith(u8, health, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, health, "\"status\":\"ok\"") != null);

    const ready = try request(io, allocator, socket_path, "GET /readyz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(ready);
    try std.testing.expect(std.mem.startsWith(u8, ready, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, ready, "\"status\":\"ready\"") != null);

    const unauthorized = try request(io, allocator, socket_path, "GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(unauthorized);
    try std.testing.expect(std.mem.startsWith(u8, unauthorized, "HTTP/1.1 401"));

    const info = try request(io, allocator, socket_path, "GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test-token\r\nConnection: close\r\n\r\n");
    defer allocator.free(info);
    try std.testing.expect(std.mem.startsWith(u8, info, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, info, "\"service\":\"test-service\"") != null);

    app.requestShutdown();
    app.wait();

    const address = try std.Io.net.UnixAddress.init(socket_path);
    try std.testing.expectError(error.FileNotFound, address.connect(io));
}
