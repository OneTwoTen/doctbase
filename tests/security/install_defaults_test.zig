const std = @import("std");
const secrets = @import("install_secrets");
const postgres = @import("install_postgres");
const pgbouncer = @import("install_pgbouncer");
const caddy = @import("install_caddy");
const config_file = @import("install_config");
const state = @import("install_state");

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
}

test "no secret has a default value and the config file never carries one" {
    const allocator = std.testing.allocator;

    for (secrets.specs) |spec| {
        try std.testing.expectEqual(secrets.Drift.create, secrets.drift(null));
        try std.testing.expect(spec.bytes >= secrets.minimum_secret_bytes);
        try std.testing.expect(spec.bytes * 8 >= 256);
    }
    try std.testing.expectEqual(@as(u16, 0o600), secrets.file_mode);
    try std.testing.expectEqual(@as(u16, 0), secrets.file_mode & 0o077);

    const config = try config_file.render(allocator, .{
        .domain = "example.com",
        .email = "admin@example.com",
    });
    defer allocator.free(config);

    try std.testing.expect(std.mem.indexOf(u8, config, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, config, "token") == null);
    try std.testing.expect(std.mem.indexOf(u8, config, "admin_setup_token") == null);
    try std.testing.expectEqual(@as(u16, 0), config_file.file_mode & 0o007);
}

test "PostgreSQL and PgBouncer are Unix-socket only" {
    const allocator = std.testing.allocator;

    try std.testing.expect(postgres.port != 5432);
    try std.testing.expectEqualStrings("/var/run/postgresql", postgres.socket_directory);

    const hba = try postgres.renderPgHba(allocator);
    defer allocator.free(hba);
    try std.testing.expect(std.mem.indexOf(u8, hba, "\nhost ") == null);
    try std.testing.expect(std.mem.indexOf(u8, hba, "0.0.0.0/0") == null);
    try std.testing.expect(std.mem.indexOf(u8, hba, "::/0") == null);

    const databases = [_]pgbouncer.Database{.{
        .name = postgres.control_database,
        .db_name = postgres.control_database,
    }};
    const pooler = try pgbouncer.render(allocator, .{ .databases = &databases });
    defer allocator.free(pooler);

    try std.testing.expect(std.mem.indexOf(u8, pooler, "listen_addr =\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pooler, "host=/var/run/postgresql") != null);
    try std.testing.expect(std.mem.indexOf(u8, pooler, "host=127.0.0.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, pooler, "auth_type = scram-sha-256") != null);
    try std.testing.expectEqual(@as(u16, 0), pgbouncer.file_mode & 0o007);
}

test "Caddy exposes no TCP admin API and no raw HTTP listener" {
    const allocator = std.testing.allocator;

    const local = try caddy.render(allocator, .{});
    defer allocator.free(local);
    try std.testing.expect(std.mem.indexOf(u8, local, "admin unix/") != null);
    try std.testing.expect(std.mem.indexOf(u8, local, ":2019") == null);
    try std.testing.expect(std.mem.indexOf(u8, local, ":80") == null);
    try std.testing.expect(std.mem.indexOf(u8, local, ":443") == null);
    try std.testing.expect(std.mem.indexOf(u8, local, "admin.example.com") == null);

    const site = try caddy.render(allocator, .{
        .domain = "example.com",
        .acme_email = "admin@example.com",
    });
    defer allocator.free(site);
    try std.testing.expect(std.mem.indexOf(u8, site, "admin unix/") != null);
    try std.testing.expect(std.mem.indexOf(u8, site, "reverse_proxy unix/") != null);
    try std.testing.expect(std.mem.indexOf(u8, site, "bind ") == null);
    try std.testing.expectEqual(@as(u16, 0), caddy.file_mode & 0o007);
}

test "systemd units load the internal token as a credential, not an environment variable" {
    const allocator = std.testing.allocator;
    const template = try readFile(allocator, "deploy/native/units/doctbase-app.service.tmpl");
    defer allocator.free(template);

    try std.testing.expect(std.mem.indexOf(u8, template, "LoadCredential=internal_token:") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "Environment=DOCTBASE_INTERNAL_TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, template, "User=root") == null);
    try std.testing.expect(std.mem.indexOf(u8, template, "NoNewPrivileges=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "ProtectSystem=strict") != null);
}

test "install state stays on the data volume and is schema versioned" {
    try std.testing.expect(std.mem.startsWith(u8, state.state_path, "/var/lib/doctbase/"));
    try std.testing.expect(!std.mem.startsWith(u8, state.state_path, "/etc/"));
    try std.testing.expectEqual(@as(u32, 1), state.schema_version);
    try std.testing.expect(std.mem.startsWith(u8, state.lock_path, "/run/doctbase/"));
}
