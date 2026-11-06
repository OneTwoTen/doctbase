const std = @import("std");

pub const ProbeResult = struct {
    status: u16,
    ready: bool,
};

pub const ProbeError = error{
    InvalidResponse,
    Timeout,
} || std.Io.net.UnixAddress.InitError || std.Io.net.UnixAddress.ConnectError || std.Io.Writer.Error || std.Io.Reader.Error;

pub fn probe(io: std.Io, endpoint: []const u8, timeout_ms: u32, path: []const u8) ProbeError!ProbeResult {
    const socket_path = if (std.mem.startsWith(u8, endpoint, "unix:")) endpoint[5..] else endpoint;
    const address = try std.Io.net.UnixAddress.init(socket_path);

    var stream = try address.connect(io);
    defer stream.close(io);

    applyTimeout(stream.socket.handle, timeout_ms);

    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print(
        "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{path},
    );
    try writer.interface.flush();

    var read_buffer: [2048]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var response: [2048]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        const count = try reader.interface.readSliceShort(response[used..]);
        if (count == 0) break;
        used += count;
        if (std.mem.indexOf(u8, response[0..used], "\r\n") != null) break;
    }
    if (used == 0) return error.InvalidResponse;

    const line_end = std.mem.indexOf(u8, response[0..used], "\r\n") orelse used;
    const status_line = response[0..line_end];
    const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.InvalidResponse;
    const rest = status_line[first_space + 1 ..];
    const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const status = std.fmt.parseInt(u16, rest[0..second_space], 10) catch return error.InvalidResponse;

    return .{
        .status = status,
        .ready = status == 200,
    };
}

fn applyTimeout(fd: std.posix.socket_t, timeout_ms: u32) void {
    const seconds: i64 = @intCast(timeout_ms / 1000);
    const micros: i64 = @intCast((timeout_ms % 1000) * 1000);
    var value: std.posix.timeval = .{ .sec = @intCast(seconds), .usec = @intCast(micros) };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&value)) catch {};
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&value)) catch {};
}
