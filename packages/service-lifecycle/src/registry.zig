const std = @import("std");

pub const ServiceKey = enum {
    gateway,
    management,
    auth,
    rest,
    realtime,
    storage,
    image_proxy,
    pg_meta,
    postgresql,
    pgbouncer,
    caddy,
};

pub const ServiceKind = enum {
    app,
    infra,
};

pub const Action = enum {
    status,
    logs,
    start,
    stop,
    restart,
    enable,
    disable,
};

pub const ActionSet = struct {
    status: bool = true,
    logs: bool = true,
    start: bool = false,
    stop: bool = false,
    restart: bool = false,
    enable: bool = false,
    disable: bool = false,

    pub fn allows(self: ActionSet, action: Action) bool {
        return switch (action) {
            .status => self.status,
            .logs => self.logs,
            .start => self.start,
            .stop => self.stop,
            .restart => self.restart,
            .enable => self.enable,
            .disable => self.disable,
        };
    }
};

pub const ServiceSpec = struct {
    key: ServiceKey,
    display_name: []const u8,
    kind: ServiceKind,
    binary_name: ?[]const u8 = null,
    unit_name: ?[]const u8 = null,
    compose_service: ?[]const u8 = null,
    socket_name: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
    optional: bool = false,
    depends_on: []const ServiceKey = &.{},
    health_path: []const u8 = "/readyz",
    health_timeout_ms: u32 = 1000,
    actions: ActionSet = .{},

    pub fn isRestartable(self: ServiceSpec) bool {
        return self.actions.allows(.restart);
    }
};

const app_actions = ActionSet{
    .status = true,
    .logs = true,
    .start = true,
    .stop = true,
    .restart = true,
    .enable = true,
    .disable = true,
};

const infra_actions = ActionSet{
    .status = true,
    .logs = true,
};

pub const all = [_]ServiceSpec{
    .{
        .key = .gateway,
        .display_name = "Gateway",
        .kind = .app,
        .binary_name = "doctbase-gateway",
        .unit_name = "doctbase-gateway.service",
        .compose_service = "gateway",
        .socket_name = "gateway.sock",
        .socket_path = "/run/doctbase/gateway.sock",
        .actions = app_actions,
    },
    .{
        .key = .management,
        .display_name = "Management",
        .kind = .app,
        .binary_name = "doctbase-management",
        .unit_name = "doctbase-management.service",
        .compose_service = "management",
        .socket_name = "management.sock",
        .socket_path = "/run/doctbase/management.sock",
        .actions = app_actions,
    },
    .{
        .key = .auth,
        .display_name = "Auth",
        .kind = .app,
        .binary_name = "doctbase-auth",
        .unit_name = "doctbase-auth.service",
        .compose_service = "auth",
        .socket_name = "auth.sock",
        .socket_path = "/run/doctbase/auth.sock",
        .actions = app_actions,
    },
    .{
        .key = .storage,
        .display_name = "Storage",
        .kind = .app,
        .binary_name = "doctbase-storage",
        .unit_name = "doctbase-storage.service",
        .compose_service = "storage",
        .socket_name = "storage.sock",
        .socket_path = "/run/doctbase/storage.sock",
        .actions = app_actions,
    },
    .{
        .key = .pg_meta,
        .display_name = "PG Meta",
        .kind = .app,
        .binary_name = "doctbase-pg-meta",
        .unit_name = "doctbase-pg-meta.service",
        .compose_service = "pg-meta",
        .socket_name = "pg-meta.sock",
        .socket_path = "/run/doctbase/pg-meta.sock",
        .actions = app_actions,
    },
    .{
        .key = .rest,
        .display_name = "REST",
        .kind = .app,
        .binary_name = "doctbase-rest",
        .unit_name = "doctbase-rest.service",
        .compose_service = "rest",
        .socket_name = "rest.sock",
        .socket_path = "/run/doctbase/rest.sock",
        .optional = true,
        .depends_on = &.{.pg_meta},
        .actions = app_actions,
    },
    .{
        .key = .realtime,
        .display_name = "Realtime",
        .kind = .app,
        .binary_name = "doctbase-realtime",
        .unit_name = "doctbase-realtime.service",
        .compose_service = "realtime",
        .socket_name = "realtime.sock",
        .socket_path = "/run/doctbase/realtime.sock",
        .optional = true,
        .depends_on = &.{.auth},
        .actions = app_actions,
    },
    .{
        .key = .image_proxy,
        .display_name = "Image Proxy",
        .kind = .app,
        .binary_name = "doctbase-image-proxy",
        .unit_name = "doctbase-image-proxy.service",
        .compose_service = "image-proxy",
        .socket_name = "image-proxy.sock",
        .socket_path = "/run/doctbase/image-proxy.sock",
        .optional = true,
        .depends_on = &.{.storage},
        .actions = app_actions,
    },
    .{
        .key = .postgresql,
        .display_name = "PostgreSQL",
        .kind = .infra,
        .unit_name = "postgresql@18-doctbase.service",
        .compose_service = "postgresql",
        .actions = infra_actions,
    },
    .{
        .key = .pgbouncer,
        .display_name = "PgBouncer",
        .kind = .infra,
        .unit_name = "doctbase-pgbouncer.service",
        .compose_service = "pgbouncer",
        .socket_name = "pgbouncer.sock",
        .socket_path = "/run/doctbase/pgbouncer.sock",
        .actions = infra_actions,
    },
    .{
        .key = .caddy,
        .display_name = "Caddy",
        .kind = .infra,
        .unit_name = "doctbase-caddy.service",
        .compose_service = "caddy",
        .actions = infra_actions,
    },
};

pub fn specs() []const ServiceSpec {
    return &all;
}

pub fn get(key: ServiceKey) *const ServiceSpec {
    for (&all) |*spec| {
        if (spec.key == key) return spec;
    }
    unreachable;
}

pub fn parse(name: []const u8) ?ServiceKey {
    if (std.meta.stringToEnum(ServiceKey, name)) |key| return key;
    if (std.mem.eql(u8, name, "image-proxy")) return .image_proxy;
    if (std.mem.eql(u8, name, "pg-meta")) return .pg_meta;
    return null;
}

pub fn socketPath(allocator: std.mem.Allocator, run_dir: []const u8, spec: *const ServiceSpec) !?[]u8 {
    const socket_name = spec.socket_name orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ run_dir, socket_name });
}

test "all service specs are unique and app services have binaries" {
    var seen = std.EnumSet(ServiceKey).initEmpty();
    for (all) |spec| {
        try std.testing.expect(!seen.contains(spec.key));
        seen.insert(spec.key);
        if (spec.kind == .app) {
            try std.testing.expect(spec.binary_name != null);
            try std.testing.expect(spec.socket_name != null);
            try std.testing.expect(spec.isRestartable());
        } else {
            try std.testing.expect(!spec.isRestartable());
        }
    }
}

test "parse accepts canonical and hyphenated names" {
    try std.testing.expectEqual(ServiceKey.auth, parse("auth").?);
    try std.testing.expectEqual(ServiceKey.image_proxy, parse("image_proxy").?);
    try std.testing.expectEqual(ServiceKey.image_proxy, parse("image-proxy").?);
    try std.testing.expectEqual(ServiceKey.pg_meta, parse("pg-meta").?);
    try std.testing.expect(parse("nope") == null);
}
