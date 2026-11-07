const std = @import("std");
const caddy = @import("install_caddy");

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64 * 1024),
    );
}

test "Caddy paths keep the admin API off the network" {
    try std.testing.expectEqualStrings("/etc/doctbase/generated/Caddyfile", caddy.generated_path);
    try std.testing.expectEqualStrings("/run/doctbase/caddy-admin.sock", caddy.admin_socket);
    try std.testing.expectEqualStrings("/run/doctbase/management.sock", caddy.management_socket);
    try std.testing.expectEqualStrings("/run/doctbase/gateway.sock", caddy.gateway_socket);
    try std.testing.expect(caddy.validSocketPath("/run/doctbase/caddy-admin.sock"));
    try std.testing.expect(!caddy.validSocketPath("localhost:2019"));
    try std.testing.expectEqual(@as(u16, 0), caddy.file_mode & 0o007);
}

test "domain install renders admin site and TLS settings" {
    const allocator = std.testing.allocator;
    const contents = try caddy.render(allocator, .{
        .domain = "example.com",
        .acme_email = "admin@example.com",
    });
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "admin unix//run/doctbase/caddy-admin.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "email admin@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "admin.example.com {") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "reverse_proxy unix//run/doctbase/management.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Strict-Transport-Security") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "X-Frame-Options \"DENY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "2019") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "0.0.0.0") == null);
}

test "local mode renders no public site" {
    const allocator = std.testing.allocator;
    const contents = try caddy.render(allocator, .{});
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "admin unix//run/doctbase/caddy-admin.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Local mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "reverse_proxy") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "email") == null);
}

test "project sites route realtime traffic before the gateway" {
    const allocator = std.testing.allocator;
    const contents = try caddy.render(allocator, .{
        .domain = "example.com",
        .project_sites = &.{
            .{ .host = "myapp.example.com" },
            .{ .host = "blog.example.com", .realtime_socket = null },
        },
    });
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "myapp.example.com {") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "@realtime path /realtime/v1/*") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "reverse_proxy @realtime unix//run/doctbase/realtime.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "reverse_proxy unix//run/doctbase/gateway.sock") != null);

    const realtime_index = std.mem.indexOf(u8, contents, "@realtime path").?;
    const gateway_index = std.mem.lastIndexOf(u8, contents, "reverse_proxy unix//run/doctbase/gateway.sock").?;
    try std.testing.expect(realtime_index < gateway_index);

    const blog_index = std.mem.indexOf(u8, contents, "blog.example.com {").?;
    const blog_realtime = std.mem.indexOfPos(u8, contents, blog_index, "@realtime path");
    try std.testing.expect(blog_realtime == null);
}

test "hostnames are validated against injection and wildcards" {
    try std.testing.expect(caddy.validHost("example.com"));
    try std.testing.expect(caddy.validHost("my-app.example.com"));
    try std.testing.expect(caddy.validHost("a.b.c"));
    try std.testing.expect(!caddy.validHost(""));
    try std.testing.expect(!caddy.validHost("*.example.com"));
    try std.testing.expect(!caddy.validHost("Example.com"));
    try std.testing.expect(!caddy.validHost("-example.com"));
    try std.testing.expect(!caddy.validHost("example..com"));
    try std.testing.expect(!caddy.validHost("example.com\n}"));
    try std.testing.expect(!caddy.validHost("example.com:443"));
}

test "unsafe sites and sockets are rejected" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidDomain, caddy.render(allocator, .{ .domain = "Example.com" }));

    try std.testing.expectError(error.InvalidEmail, caddy.render(allocator, .{
        .acme_email = "admin@example.com\n}",
    }));

    try std.testing.expectError(error.HostConflictsWithAdmin, caddy.render(allocator, .{
        .domain = "example.com",
        .project_sites = &.{.{ .host = "admin.example.com" }},
    }));

    try std.testing.expectError(error.DuplicateHost, caddy.render(allocator, .{
        .project_sites = &.{
            .{ .host = "myapp.example.com" },
            .{ .host = "myapp.example.com" },
        },
    }));

    try std.testing.expectError(error.InvalidSocketPath, caddy.render(allocator, .{
        .project_sites = &.{.{ .host = "myapp.example.com", .upstream_socket = "/run/doctbase/gateway.sock\n}" }},
    }));
}

test "Caddy unit binds low ports without running as root" {
    const allocator = std.testing.allocator;
    const unit = try readFile(allocator, caddy.unit_template);
    defer allocator.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "User=doctbase-caddy") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Group=doctbase") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "AmbientCapabilities=CAP_NET_BIND_SERVICE") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ReadWritePaths=/run/doctbase /var/lib/doctbase/caddy") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "--config /etc/doctbase/generated/Caddyfile") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "2019") == null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "User=root") == null);
}
