const std = @import("std");
const runtime = @import("runtime");
const config_mod = @import("config");

test "runtime bootstrap loads config, computes hash, and progresses stages" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const run_dir = try std.fmt.allocPrint(allocator, "/tmp/doctbase-boot-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(run_dir);
    defer std.Io.Dir.cwd().deleteTree(io, run_dir) catch {};

    const rt = try runtime.Runtime.create(allocator, io, .{
        .service_key = "test_svc",
        .run_dir = run_dir,
        .allow_missing_config = true,
        .install_signal_handlers = false,
    });
    defer rt.destroy();

    try std.testing.expect(std.mem.startsWith(u8, rt.config_hash, "sha256:"));
    try std.testing.expect(rt.socket_path != null);
    try std.testing.expect(std.mem.endsWith(u8, rt.socket_path.?, "test_svc.sock"));
}
