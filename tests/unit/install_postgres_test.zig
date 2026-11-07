const std = @import("std");
const postgres = @import("install_postgres");

fn readTemplate(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64 * 1024),
    );
}

const FakeExecutor = struct {
    cluster: bool = false,
    created: usize = 0,
    starts: usize = 0,
    sql_count: usize = 0,
    writes: usize = 0,
    last_sql: [16384]u8 = undefined,
    last_sql_length: usize = 0,
    events: [8]u8 = undefined,

    fn record(self: *FakeExecutor, tag: u8) void {
        self.events[self.created + self.starts + self.writes + self.sql_count] = tag;
    }

    fn clusterExists(context: ?*anyopaque, spec: postgres.ClusterSpec) anyerror!bool {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        try std.testing.expectEqualStrings(postgres.cluster_name, spec.name);
        try std.testing.expectEqual(postgres.port, spec.port);
        return self.cluster;
    }

    fn createCluster(context: ?*anyopaque, spec: postgres.ClusterSpec) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        try std.testing.expectEqualStrings(postgres.cluster_name, spec.name);
        self.created += 1;
    }

    fn writeFile(context: ?*anyopaque, file: postgres.FileSpec) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        try std.testing.expect(file.mode & 0o022 == 0);
        try std.testing.expect(file.contents.len > 0);
        self.writes += 1;
    }

    fn startCluster(context: ?*anyopaque, _: postgres.ClusterSpec) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        self.starts += 1;
    }

    fn runSql(context: ?*anyopaque, sql: []const u8) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        const copy = @min(sql.len, self.last_sql.len);
        @memcpy(self.last_sql[0..copy], sql[0..copy]);
        self.last_sql_length = copy;
        self.sql_count += 1;
    }
};

fn options(ram_bytes: u64) postgres.EnsureOptions {
    return .{
        .ram_bytes = ram_bytes,
        .max_connections = 200,
        .tuning_template = "max_connections = @MAX_CONNECTIONS@\nshared_buffers = '@SHARED_BUFFERS@'\n",
        .bootstrap_template = "PASSWORD '@ADMIN_PASSWORD@' @PGBOUNCER_PASSWORD@ @CONTROL_DATABASE@ @TEMPLATE_DATABASE@\n",
        .admin_password = "admin-secret",
        .pgbouncer_password = "pgbouncer-secret",
    };
}

test "cluster constants never reuse PostgreSQL defaults or public ports" {
    try std.testing.expectEqualStrings("18", postgres.version);
    try std.testing.expectEqualStrings("doctbase", postgres.cluster_name);
    try std.testing.expectEqual(@as(u16, 5433), postgres.port);
    try std.testing.expect(postgres.port != 5432);
    try std.testing.expectEqualStrings("/var/run/postgresql", postgres.socket_directory);
    try std.testing.expectEqualStrings("postgresql@18-doctbase.service", postgres.unit_name);
    try std.testing.expectEqualStrings("/etc/postgresql/18/doctbase/conf.d/doctbase.conf", postgres.tuning_path);
    try std.testing.expectEqualStrings("/etc/postgresql/18/doctbase/pg_hba.conf", postgres.hba_path);
    try std.testing.expectEqualStrings("doctbase", postgres.control_database);
    try std.testing.expectEqualStrings("template_doctbase", postgres.template_database);
    try std.testing.expectEqualStrings("doctbase_admin", postgres.admin_role);
    try std.testing.expectEqualStrings("pgbouncer_auth", postgres.auth_role);
}

test "auto tuning scales from 2 GB without manual edits" {
    const tuning = postgres.tune(2 * 1024 * 1024 * 1024, 200);
    try std.testing.expectEqual(@as(u32, 512), tuning.shared_buffers_mb);
    try std.testing.expectEqual(@as(u32, 1024), tuning.effective_cache_size_mb);
    try std.testing.expectEqual(@as(u32, 128), tuning.maintenance_work_mem_mb);
    try std.testing.expectEqual(@as(u32, 3), tuning.work_mem_mb);

    const small = postgres.tune(1024 * 1024 * 1024, 1000);
    try std.testing.expectEqual(@as(u32, 256), small.shared_buffers_mb);
    try std.testing.expectEqual(@as(u32, 1), small.work_mem_mb);

    const large = postgres.tune(128 * 1024 * 1024 * 1024, 50);
    try std.testing.expectEqual(@as(u32, 8192), large.shared_buffers_mb);
    try std.testing.expectEqual(@as(u32, 64), large.work_mem_mb);
}

test "rendered tuning is socket-only and matches the shipped template" {
    const allocator = std.testing.allocator;
    const template = try readTemplate(allocator, "infrastructure/postgres/tuning.conf");
    defer allocator.free(template);

    const tuning = postgres.tune(2 * 1024 * 1024 * 1024, 200);
    const contents = try postgres.renderTuning(allocator, template, .{
        .tuning = tuning,
        .max_connections = 200,
    });
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "listen_addresses = ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "port = 5433") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "shared_buffers = '512MB'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "work_mem = '3MB'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "max_connections = 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "password_encryption = 'scram-sha-256'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "shared_preload_libraries = 'pg_stat_statements'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "@MAX_CONNECTIONS@") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "@SHARED_BUFFERS@") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "0.0.0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "listen_addresses = 'localhost'") == null);
}

test "pg_hba has no TCP lines" {
    const allocator = std.testing.allocator;
    const contents = try postgres.renderPgHba(allocator);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "local   all           all                               scram-sha-256") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\nhost") == null);
}

test "bootstrap SQL is idempotent, complete and escapes passwords" {
    const allocator = std.testing.allocator;
    const template = try readTemplate(allocator, "infrastructure/postgres/template.sql");
    defer allocator.free(template);

    const contents = try postgres.renderBootstrap(allocator, template, .{
        .admin_password = "a'b",
        .pgbouncer_password = "c'd",
    });
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\\set ON_ERROR_STOP on") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "PASSWORD 'a''b'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "PASSWORD 'c''d'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE ROLE doctbase_admin LOGIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE ROLE pgbouncer_auth LOGIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE DATABASE %I OWNER %I', 'doctbase'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE DATABASE %I OWNER %I IS_TEMPLATE true', 'template_doctbase'") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE EXTENSION IF NOT EXISTS pgcrypto") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE SCHEMA IF NOT EXISTS auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "CREATE SCHEMA IF NOT EXISTS storage") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "doctbase.pgbouncer_auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "GRANT EXECUTE ON FUNCTION doctbase.pgbouncer_auth(text) TO pgbouncer_auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "GRANT USAGE ON SCHEMA doctbase TO pgbouncer_auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "GRANT CONNECT ON DATABASE doctbase TO pgbouncer_auth") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "CREATE OR REPLACE FUNCTION doctbase.pgbouncer_auth"));
    try std.testing.expect(std.mem.indexOf(u8, contents, "IS_TEMPLATE true") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "REVOKE CONNECT ON DATABASE template_doctbase FROM PUBLIC") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "@ADMIN_PASSWORD@") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "PASSWORD 'admin-secret'") == null);
}

test "empty bootstrap passwords are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidSecret, postgres.renderBootstrap(allocator, "x", .{
        .admin_password = "",
        .pgbouncer_password = "set",
    }));
}

test "cluster change requires root before any action" {
    var fake = FakeExecutor{};
    const executor = postgres.Executor{
        .context = &fake,
        .cluster_exists = FakeExecutor.clusterExists,
        .create_cluster = FakeExecutor.createCluster,
        .write_file = FakeExecutor.writeFile,
        .start_cluster = FakeExecutor.startCluster,
        .run_sql = FakeExecutor.runSql,
    };

    try std.testing.expectError(
        error.RootPrivilegesRequired,
        postgres.ensure(std.testing.allocator, executor, options(2 * 1024 * 1024 * 1024)),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.created);
    try std.testing.expectEqual(@as(usize, 0), fake.writes);
    try std.testing.expectEqual(@as(usize, 0), fake.sql_count);
}

test "fresh install creates the cluster before writing config and bootstrapping" {
    var fake = FakeExecutor{};
    const executor = postgres.Executor{
        .context = &fake,
        .running_as_root = true,
        .cluster_exists = FakeExecutor.clusterExists,
        .create_cluster = FakeExecutor.createCluster,
        .write_file = FakeExecutor.writeFile,
        .start_cluster = FakeExecutor.startCluster,
        .run_sql = FakeExecutor.runSql,
    };

    try postgres.ensure(std.testing.allocator, executor, options(2 * 1024 * 1024 * 1024));

    try std.testing.expectEqual(@as(usize, 1), fake.created);
    try std.testing.expectEqual(@as(usize, 2), fake.writes);
    try std.testing.expectEqual(@as(usize, 1), fake.starts);
    try std.testing.expectEqual(@as(usize, 1), fake.sql_count);
    try std.testing.expect(std.mem.indexOf(u8, fake.last_sql[0..fake.last_sql_length], "PASSWORD 'admin-secret'") != null);
}

test "re-running the install keeps an existing cluster" {
    var fake = FakeExecutor{ .cluster = true };
    const executor = postgres.Executor{
        .context = &fake,
        .running_as_root = true,
        .cluster_exists = FakeExecutor.clusterExists,
        .create_cluster = FakeExecutor.createCluster,
        .write_file = FakeExecutor.writeFile,
        .start_cluster = FakeExecutor.startCluster,
        .run_sql = FakeExecutor.runSql,
    };

    try postgres.ensure(std.testing.allocator, executor, options(2 * 1024 * 1024 * 1024));

    try std.testing.expectEqual(@as(usize, 0), fake.created);
    try std.testing.expectEqual(@as(usize, 2), fake.writes);
    try std.testing.expectEqual(@as(usize, 1), fake.starts);
    try std.testing.expectEqual(@as(usize, 1), fake.sql_count);
}
