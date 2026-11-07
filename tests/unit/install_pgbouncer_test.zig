const std = @import("std");
const pgbouncer = @import("install_pgbouncer");

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64 * 1024),
    );
}

const control = pgbouncer.Database{ .name = "doctbase" };
const project = pgbouncer.Database{
    .name = "doctbase_myapp_01j",
    .db_name = "doctbase_myapp_01j",
    .pool_size = 8,
    .max_db_connections = 16,
};

test "PgBouncer paths stay inside platform-owned directories" {
    try std.testing.expectEqualStrings("/etc/doctbase/generated/pgbouncer.ini", pgbouncer.generated_path);
    try std.testing.expectEqualStrings("doctbase-pgbouncer.service", pgbouncer.unit_name);
    try std.testing.expectEqualStrings("/run/doctbase", pgbouncer.unix_socket_directory);
    try std.testing.expectEqualStrings("/var/lib/doctbase/pgbouncer/users.txt", pgbouncer.auth_file);
    try std.testing.expectEqual(@as(u16, 6432), pgbouncer.listen_port);
    try std.testing.expectEqualStrings("transaction", "transaction");
    try std.testing.expectEqual(@as(u16, 0), pgbouncer.file_mode & 0o007);
}

test "rendered pgbouncer.ini is socket-only with explicit per-database entries" {
    const allocator = std.testing.allocator;
    const contents = try pgbouncer.render(allocator, .{
        .databases = &.{ control, project },
    });
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "[databases]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "doctbase = host=/var/run/postgresql port=5433 dbname=doctbase pool_size=10 max_db_connections=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "doctbase_myapp_01j = host=/var/run/postgresql port=5433 dbname=doctbase_myapp_01j pool_size=8 max_db_connections=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\n* =") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "listen_addr =\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "0.0.0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "unix_socket_dir = /run/doctbase") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "unix_socket_mode = 0660") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "unix_socket_group = doctbase") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "pool_mode = transaction") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "auth_type = scram-sha-256") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "auth_user = pgbouncer_auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "auth_file = /var/lib/doctbase/pgbouncer/users.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "auth_query = SELECT * FROM doctbase.pgbouncer_auth($1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "max_prepared_statements = 200") != null);
}

test "database aliases are conservative identifiers" {
    try std.testing.expect(pgbouncer.validIdentifier("doctbase"));
    try std.testing.expect(pgbouncer.validIdentifier("doctbase_myapp_01j"));
    try std.testing.expect(!pgbouncer.validIdentifier("*"));
    try std.testing.expect(!pgbouncer.validIdentifier("Doctbase"));
    try std.testing.expect(!pgbouncer.validIdentifier("1app"));
    try std.testing.expect(!pgbouncer.validIdentifier("my-app"));
    try std.testing.expect(!pgbouncer.validIdentifier(""));
    try std.testing.expect(!pgbouncer.validIdentifier("doctbase\ninjected"));
}

test "upstream must be a local Unix socket path" {
    try std.testing.expect(pgbouncer.validUnixSocketPath("/var/run/postgresql"));
    try std.testing.expect(!pgbouncer.validUnixSocketPath("127.0.0.1"));
    try std.testing.expect(!pgbouncer.validUnixSocketPath("localhost"));
    try std.testing.expect(!pgbouncer.validUnixSocketPath("relative/socket"));
    try std.testing.expect(!pgbouncer.validUnixSocketPath("/var/run/postgresql\ninjected"));
    try std.testing.expect(!pgbouncer.validUnixSocketPath("/var/run/postgres'ql"));
}

test "unsafe or inconsistent database entries are rejected" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingDatabaseEntry, pgbouncer.render(allocator, .{}));

    try std.testing.expectError(error.InvalidDatabaseAlias, pgbouncer.render(allocator, .{
        .databases = &.{.{ .name = "*" }},
    }));

    try std.testing.expectError(error.InvalidUpstreamHost, pgbouncer.render(allocator, .{
        .databases = &.{.{ .name = "doctbase", .host = "127.0.0.1" }},
    }));

    try std.testing.expectError(error.PoolExceedsDatabaseLimit, pgbouncer.render(allocator, .{
        .databases = &.{.{ .name = "doctbase", .pool_size = 20, .max_db_connections = 10 }},
    }));

    try std.testing.expectError(error.DuplicateDatabaseAlias, pgbouncer.render(allocator, .{
        .databases = &.{ control, control },
    }));
}

test "PgBouncer unit template is non-root and socket-oriented" {
    const allocator = std.testing.allocator;
    const unit = try readFile(allocator, pgbouncer.unit_template);
    defer allocator.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "User=doctbase-pgbouncer") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Group=doctbase") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecReload=/bin/kill -HUP $MAINPID") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Requires=postgresql@18-doctbase.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "LoadCredential=pgbouncer_auth:/etc/doctbase/secrets/pgbouncer_auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ReadWritePaths=/run/doctbase /var/lib/doctbase/pgbouncer") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "listen_addr") == null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "2019") == null);
}
