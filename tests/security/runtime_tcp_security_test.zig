const std = @import("std");
const runtime = @import("runtime");

fn request(io: std.Io, allocator: std.mem.Allocator, port: u16, raw: []const u8) ![]u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
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

test "TCP mode rejects internal requests without the correct token" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const token = "tcp-security-token";
    var attempts: usize = 0;
    var app: ?*runtime.Runtime = null;
    var port: u16 = 0;
    while (attempts < 10) : (attempts += 1) {
        var random_bytes: [2]u8 = undefined;
        io.random(&random_bytes);
        const candidate: u16 = 20000 + (std.mem.readInt(u16, &random_bytes, .little) % 30000);
        const listen = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{candidate});
        defer allocator.free(listen);

        const instance = runtime.Runtime.create(allocator, io, .{
            .service_key = "tcp-security-service",
            .mode = .docker,
            .listen = listen,
            .internal_token = token,
            .allow_missing_config = true,
            .install_signal_handlers = false,
        }) catch continue;
        instance.start() catch {
            instance.destroy();
            continue;
        };
        app = instance;
        port = candidate;
        break;
    }
    const instance = app orelse return error.NoFreeTcpPort;
    defer instance.destroy();

    const missing = try request(io, allocator, port, "GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(missing);
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 401"));
    try std.testing.expect(std.mem.indexOf(u8, missing, token) == null);

    const wrong = try request(io, allocator, port, "GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer wrong-token\r\nConnection: close\r\n\r\n");
    defer allocator.free(wrong);
    try std.testing.expect(std.mem.startsWith(u8, wrong, "HTTP/1.1 401"));
    try std.testing.expect(std.mem.indexOf(u8, wrong, token) == null);

    const accepted = try request(io, allocator, port, "GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer tcp-security-token\r\nConnection: close\r\n\r\n");
    defer allocator.free(accepted);
    try std.testing.expect(std.mem.startsWith(u8, accepted, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, accepted, "tcp-security-service") != null);

    instance.requestShutdown();
    instance.wait();
}
