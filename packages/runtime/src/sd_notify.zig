const std = @import("std");

pub const SdNotify = struct {
    pub fn notifyReady(io: std.Io, environ: anytype) void {
        notify(io, environ, "READY=1");
    }

    pub fn notifyStopping(io: std.Io, environ: anytype) void {
        notify(io, environ, "STOPPING=1");
    }

    pub fn notifyStatus(io: std.Io, environ: anytype, status: []const u8) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "STATUS={s}", .{status}) catch return;
        notify(io, environ, msg);
    }

    fn notify(io: std.Io, environ: anytype, message: []const u8) void {
        const socket_path = if (environ) |env|
            env.get("NOTIFY_SOCKET")
        else
            null;

        const path = socket_path orelse return;
        if (path.len == 0) return;

        const address = std.Io.net.UnixAddress.init(path) catch return;
        var stream = address.connect(io) catch return;
        defer stream.close(io);

        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll(message) catch {};
        writer.interface.flush() catch {};
    }
};

test "sd_notify handles missing NOTIFY_SOCKET gracefully" {
    const io = std.testing.io;
    SdNotify.notifyReady(io, @as(?*const std.process.Environ.Map, null));
    SdNotify.notifyStopping(io, @as(?*const std.process.Environ.Map, null));
    SdNotify.notifyStatus(io, @as(?*const std.process.Environ.Map, null), "starting up");
}
