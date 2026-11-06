const std = @import("std");

pub const ProjectRoute = struct {
    path_prefix: []const u8,
    service_name: []const u8,
    socket_path: []const u8,
};

pub const Project = struct {
    id: []const u8,
    slug: []const u8,
    domain: ?[]const u8 = null,
    is_default: bool = false,
    routes: []const ProjectRoute,
};

pub const ProjectRegistry = struct {
    allocator: std.mem.Allocator,
    projects: std.ArrayList(Project),

    pub fn init(allocator: std.mem.Allocator) ProjectRegistry {
        return .{
            .allocator = allocator,
            .projects = .empty,
        };
    }

    pub fn deinit(self: *ProjectRegistry) void {
        self.projects.deinit(self.allocator);
    }

    pub fn addProject(self: *ProjectRegistry, project: Project) !void {
        try self.projects.append(self.allocator, project);
    }

    pub fn findByHost(self: ProjectRegistry, host: []const u8) ?Project {
        for (self.projects.items) |p| {
            if (p.domain) |d| {
                if (std.ascii.eqlIgnoreCase(d, host)) return p;
            }
            if (std.ascii.eqlIgnoreCase(p.slug, host)) return p;
        }
        for (self.projects.items) |p| {
            if (p.is_default) return p;
        }
        return null;
    }

    pub fn resolveRoute(project: Project, path: []const u8) ?ProjectRoute {
        for (project.routes) |r| {
            if (std.mem.startsWith(u8, path, r.path_prefix)) {
                return r;
            }
        }
        return null;
    }
};

test "project registry host lookup and route resolution" {
    const allocator = std.testing.allocator;
    var reg = ProjectRegistry.init(allocator);
    defer reg.deinit();

    const routes = [_]ProjectRoute{
        .{ .path_prefix = "/auth", .service_name = "auth", .socket_path = "/run/doctbase/auth.sock" },
        .{ .path_prefix = "/storage", .service_name = "storage", .socket_path = "/run/doctbase/storage.sock" },
    };

    try reg.addProject(.{
        .id = "proj-1",
        .slug = "myapp",
        .domain = "myapp.example.com",
        .is_default = true,
        .routes = &routes,
    });

    const by_domain = reg.findByHost("myapp.example.com");
    try std.testing.expect(by_domain != null);
    try std.testing.expectEqualStrings("myapp", by_domain.?.slug);

    const route = ProjectRegistry.resolveRoute(by_domain.?, "/auth/v1/token");
    try std.testing.expect(route != null);
    try std.testing.expectEqualStrings("/run/doctbase/auth.sock", route.?.socket_path);

    const default_proj = reg.findByHost("random-host.com");
    try std.testing.expect(default_proj != null);
}
