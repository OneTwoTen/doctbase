const std = @import("std");

pub fn ensureSocketAvailable(io: std.Io, path: []const u8) !void {
    const address = std.Io.net.UnixAddress.init(path) catch return error.SocketPathTooLong;
    var stream = address.connect(io) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return,
        error.AccessDenied, error.PermissionDenied => return error.SocketPermissionDenied,
        else => return err,
    };
    stream.close(io);
    return error.SocketInUse;
}

test "ensureSocketAvailable handles non-existent path" {
    const io = std.testing.io;
    try ensureSocketAvailable(io, "/tmp/doctbase-non-existent-test.sock");
}
