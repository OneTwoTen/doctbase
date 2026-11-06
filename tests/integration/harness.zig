const std = @import("std");

pub const TestEnvironment = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    run_dir: []u8,
    postgres_dsn: []const u8 = "postgres://postgres@localhost:5433/doctbase_test",
    pgbouncer_socket: []u8,
    caddy_admin_socket: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !TestEnvironment {
        var rand: [8]u8 = undefined;
        io.random(&rand);
        const rand_id = std.mem.readInt(u64, &rand, .little);

        const run_dir = try std.fmt.allocPrint(allocator, "/tmp/doctbase-harness-{d}", .{rand_id});
        errdefer allocator.free(run_dir);

        _ = std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => .existed,
            else => return err,
        };

        const pgbouncer_socket = try std.fmt.allocPrint(allocator, "{s}/pgbouncer.sock", .{run_dir});
        errdefer allocator.free(pgbouncer_socket);

        const caddy_admin_socket = try std.fmt.allocPrint(allocator, "{s}/caddy-admin.sock", .{run_dir});
        errdefer allocator.free(caddy_admin_socket);

        return .{
            .allocator = allocator,
            .io = io,
            .run_dir = run_dir,
            .pgbouncer_socket = pgbouncer_socket,
            .caddy_admin_socket = caddy_admin_socket,
        };
    }

    pub fn deinit(self: *TestEnvironment) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.run_dir) catch {};
        self.allocator.free(self.pgbouncer_socket);
        self.allocator.free(self.caddy_admin_socket);
        self.allocator.free(self.run_dir);
    }
};

test "test environment harness creates isolated run dir and socket paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = try TestEnvironment.init(allocator, io);
    defer env.deinit();

    try std.testing.expect(std.mem.startsWith(u8, env.run_dir, "/tmp/doctbase-harness-"));
    try std.testing.expect(std.mem.endsWith(u8, env.pgbouncer_socket, "pgbouncer.sock"));
    try std.testing.expect(std.mem.endsWith(u8, env.caddy_admin_socket, "caddy-admin.sock"));
}
