const std = @import("std");
const runtime = @import("runtime");

fn tempSocketPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    return std.fmt.allocPrint(allocator, "/tmp/doctbase-security-test-{d}.sock", .{std.mem.readInt(u64, &random_bytes, .little)});
}

test "UDS socket is 0660 and a live socket is not silently replaced" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const socket_path = try tempSocketPath(allocator, io);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const first = try runtime.Runtime.create(allocator, io, .{
        .service_key = "security-test",
        .mode = .dev,
        .socket_path = socket_path,
        .allow_missing_config = true,
        .install_signal_handlers = false,
    });
    defer first.destroy();
    try first.start();

    const stat = try std.Io.Dir.cwd().statFile(io, socket_path, .{});
    const mode: u32 = @backingInt(stat.permissions) & 0o777;
    try std.testing.expectEqual(@as(u32, 0o660), mode);

    try std.testing.expectError(error.SocketInUse, runtime.Runtime.create(allocator, io, .{
        .service_key = "security-test",
        .mode = .dev,
        .socket_path = socket_path,
        .allow_missing_config = true,
        .install_signal_handlers = false,
    }));

    first.requestShutdown();
    first.wait();
    try std.testing.expectError(error.FileNotFound, (try std.Io.net.UnixAddress.init(socket_path)).connect(io));
}

test "native mode rejects internal requests without a token" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const socket_path = try tempSocketPath(allocator, io);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const app = try runtime.Runtime.create(allocator, io, .{
        .service_key = "native-test",
        .mode = .native,
        .socket_path = socket_path,
        .allow_missing_config = true,
        .install_signal_handlers = false,
    });
    defer app.destroy();
    try app.start();

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /internal/v1/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
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

    try std.testing.expect(std.mem.startsWith(u8, response.items, "HTTP/1.1 401"));

    app.requestShutdown();
    app.wait();
}
