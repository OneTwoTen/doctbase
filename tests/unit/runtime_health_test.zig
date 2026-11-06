const std = @import("std");
const runtime = @import("runtime");

test "runtime readiness and health probe aggregation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const run_dir = try std.fmt.allocPrint(allocator, "/tmp/doctbase-health-test-{d}", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(run_dir);
    defer std.Io.Dir.cwd().deleteTree(io, run_dir) catch {};

    const rt = try runtime.Runtime.create(allocator, io, .{
        .service_key = "health_svc",
        .run_dir = run_dir,
        .allow_missing_config = true,
        .install_signal_handlers = false,
    });
    defer rt.destroy();

    try rt.start();
    try std.testing.expect(rt.ready.load(.acquire));

    rt.requestShutdown();
    rt.wait();
}
