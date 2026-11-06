const std = @import("std");
const runtime = @import("runtime");

fn request(io: std.Io, allocator: std.mem.Allocator, port: u16, raw: []const u8) ![]u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    return exchange(io, allocator, &stream, raw);
}

fn udsRequest(io: std.Io, allocator: std.mem.Allocator, socket_path: []const u8, raw: []const u8) ![]u8 {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);
    return exchange(io, allocator, &stream, raw);
}

fn exchange(io: std.Io, allocator: std.mem.Allocator, stream: *std.Io.net.Stream, raw: []const u8) ![]u8 {
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

fn startOnRandomPort(
    allocator: std.mem.Allocator,
    io: std.Io,
    token: ?[]const u8,
) !struct { app: *runtime.Runtime, port: u16 } {
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        var random_bytes: [2]u8 = undefined;
        io.random(&random_bytes);
        const port: u16 = 20000 + (std.mem.readInt(u16, &random_bytes, .little) % 30000);
        const listen = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
        defer allocator.free(listen);

        const app = runtime.Runtime.create(allocator, io, .{
            .service_key = "tcp-test-service",
            .version = "0.0.1-test",
            .commit = "test",
            .mode = .docker,
            .listen = listen,
            .internal_token = token,
            .allow_missing_config = true,
            .install_signal_handlers = false,
        }) catch continue;
        app.start() catch {
            app.destroy();
            continue;
        };
        return .{ .app = app, .port = port };
    }
    return error.NoFreeTcpPort;
}

test "runtime serves health, readiness and info over TCP" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const instance = try startOnRandomPort(allocator, io, "tcp-test-token");
    const app = instance.app;
    defer app.destroy();

    const health = try request(io, allocator, instance.port, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(health);
    try std.testing.expect(std.mem.startsWith(u8, health, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, health, "\"status\":\"ok\"") != null);

    const ready = try request(io, allocator, instance.port, "GET /readyz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(ready);
    try std.testing.expect(std.mem.startsWith(u8, ready, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, ready, "\"status\":\"ready\"") != null);

    const unauthorized = try request(io, allocator, instance.port, "GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(unauthorized);
    try std.testing.expect(std.mem.startsWith(u8, unauthorized, "HTTP/1.1 401"));

    const info = try request(io, allocator, instance.port, "GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer tcp-test-token\r\nConnection: close\r\n\r\n");
    defer allocator.free(info);
    try std.testing.expect(std.mem.startsWith(u8, info, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, info, "\"service\":\"tcp-test-service\"") != null);

    app.requestShutdown();
    app.wait();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", instance.port);
    try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
}

test "docker mode keeps the UDS default when listen is unset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-tcp-test-{d}.sock", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const app = try runtime.Runtime.create(allocator, io, .{
        .service_key = "uds-default-service",
        .mode = .docker,
        .socket_path = socket_path,
        .allow_missing_config = true,
        .install_signal_handlers = false,
    });
    defer app.destroy();

    try std.testing.expect(app.socket_path != null);
    try app.start();

    const health = try udsRequest(io, allocator, socket_path, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(health);
    try std.testing.expect(std.mem.startsWith(u8, health, "HTTP/1.1 200"));

    app.requestShutdown();
    app.wait();
}
