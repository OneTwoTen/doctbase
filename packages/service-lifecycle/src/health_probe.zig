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
        // SO_RCVTIMEO makes the kernel return EAGAIN on expiry, which Zig 0.17
        // treats as a programmer bug. Wait for readability explicitly so a
        // non-HTTP peer (for example a misconfigured PgBouncer socket) times
        // out instead of aborting the CLI.
        try waitReadable(stream.socket.handle, timeout_ms);
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

fn waitReadable(fd: std.posix.socket_t, timeout_ms: u32) ProbeError!void {
    var fds = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) catch return error.Timeout;
    if (ready == 0) return error.Timeout;
}
