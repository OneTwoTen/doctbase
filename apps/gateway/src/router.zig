const std = @import("std");
const registry = @import("project_registry.zig");

pub const RouteResult = struct {
    project_slug: []const u8,
    target_socket: []const u8,
    upstream_service: []const u8,
};

pub const GatewayRouter = struct {
    registry: *const registry.ProjectRegistry,

    pub fn init(reg: *const registry.ProjectRegistry) GatewayRouter {
        return .{ .registry = reg };
    }

    pub fn match(self: GatewayRouter, host: []const u8, path: []const u8) ?RouteResult {
        // Strip optional port from host header
        var clean_host = host;
        if (std.mem.indexOf(u8, host, ":")) |colon| {
            clean_host = host[0..colon];
        }

        const project = self.registry.findByHost(clean_host) orelse return null;
        const route = registry.ProjectRegistry.resolveRoute(project, path) orelse return null;

        return RouteResult{
            .project_slug = project.slug,
            .target_socket = route.socket_path,
            .upstream_service = route.service_name,
        };
    }

    /// Strip incoming untrusted X-Doctbase-* headers
    pub fn isProtectedHeader(header_name: []const u8) bool {
        return std.ascii.startsWithIgnoreCase(header_name, "x-doctbase-");
    }
};

test "gateway router matches host and path to upstream socket" {
    const allocator = std.testing.allocator;
    var reg = registry.ProjectRegistry.init(allocator);
    defer reg.deinit();

    const routes = [_]registry.ProjectRoute{
        .{ .path_prefix = "/auth", .service_name = "auth", .socket_path = "/run/doctbase/auth.sock" },
        .{ .path_prefix = "/rest", .service_name = "rest", .socket_path = "/run/doctbase/rest.sock" },
    };

    try reg.addProject(.{
        .id = "p-1",
        .slug = "app",
        .domain = "app.local",
        .routes = &routes,
    });

    const router = GatewayRouter.init(&reg);
    const match = router.match("app.local:8080", "/auth/login");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("/run/doctbase/auth.sock", match.?.target_socket);

    try std.testing.expect(GatewayRouter.isProtectedHeader("X-Doctbase-Role"));
    try std.testing.expect(GatewayRouter.isProtectedHeader("x-doctbase-user"));
    try std.testing.expect(!GatewayRouter.isProtectedHeader("X-Request-Id"));
}
