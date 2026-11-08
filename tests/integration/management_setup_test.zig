const std = @import("std");
const runtime = @import("runtime");
const lifecycle = @import("service_lifecycle");
const app_mod = @import("management_app");
const setup_mod = app_mod.SetupState;

fn request(io: std.Io, allocator: std.mem.Allocator, socket_path: []const u8, raw: []const u8) ![]u8 {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);

    var write_buffer: [2048]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(raw);
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var response: std.ArrayList(u8) = .empty;
    while (true) {
        var chunk: [512]u8 = undefined;
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        try response.appendSlice(allocator, chunk[0..count]);
    }
    return response.toOwnedSlice(allocator);
}

test "management app serves setup, session and core health over UDS" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/doctbase-management-test-{d}.sock", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const admin_path = try std.fmt.allocPrint(allocator, "{s}/admin.json", .{path_buffer[0..length]});
    defer allocator.free(admin_path);

    var fake = lifecycle.fake.FakeDriver.init();
    const driver = fake.driver();
    defer driver.deinit();

    const setup = try setup_mod.initFromToken(allocator, io, "setup-token", 4_000_000_000);
    var app = try app_mod.ManagementApp.init(allocator, io, .{
        .admin_path = admin_path,
        .internal_token = "internal-secret",
        .setup_state = setup,
        .driver = driver,
        .cookie_secure = false,
    });
    defer app.deinit();

    const rt = try runtime.Runtime.create(allocator, io, .{
        .service_key = "management-test",
        .mode = .dev,
        .socket_path = socket_path,
        .internal_token = "internal-secret",
        .allow_missing_config = true,
        .install_signal_handlers = false,
        .fallback = app.handler(),
    });
    defer rt.destroy();
    try rt.start();

    const health = try request(io, allocator, socket_path, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(health);
    try std.testing.expect(std.mem.startsWith(u8, health, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, health, "\"status\":\"ok\"") != null);

    const status = try request(io, allocator, socket_path, "GET /setup/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(status);
    try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, status, "\"required\":true") != null);

    const body = "{\"setup_token\":\"setup-token\",\"email\":\"owner@example.com\",\"password\":\"correct-horse-battery\"}";
    const raw = try std.fmt.allocPrint(
        allocator,
        "POST /setup HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer allocator.free(raw);
    const created = try request(io, allocator, socket_path, raw);
    defer allocator.free(created);
    try std.testing.expect(std.mem.startsWith(u8, created, "HTTP/1.1 201"));
    try std.testing.expect(std.mem.indexOf(u8, created, "\"role\":\"owner\"") != null);

    const csrf = extractCookie(created, "doctbase_csrf=") orelse return error.TestExpectedCsrfCookie;
    const session = extractCookie(created, "doctbase_session=") orelse return error.TestExpectedSessionCookie;

    const cookie_header = try std.fmt.allocPrint(allocator, "Cookie: {s}; {s}\r\n", .{ session, csrf });
    defer allocator.free(cookie_header);
    const session_raw = try std.fmt.allocPrint(
        allocator,
        "GET /auth/session HTTP/1.1\r\nHost: localhost\r\n{s}Connection: close\r\n\r\n",
        .{cookie_header},
    );
    defer allocator.free(session_raw);
    const session_response = try request(io, allocator, socket_path, session_raw);
    defer allocator.free(session_response);
    try std.testing.expect(std.mem.startsWith(u8, session_response, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, session_response, "\"email\":\"owner@example.com\"") != null);

    const after = try request(io, allocator, socket_path, "GET /setup/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"required\":false") != null);

    rt.requestShutdown();
    rt.wait();
}

fn extractCookie(response: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Set-Cookie: ")) continue;
        const value = std.mem.trimEnd(u8, line["Set-Cookie: ".len..], "\r");
        if (!std.mem.startsWith(u8, value, prefix)) continue;
        const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        return value[0..end];
    }
    return null;
}
