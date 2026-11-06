const std = @import("std");

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
};

pub const control_migrations = [_]Migration{
    .{
        .version = 1,
        .name = "001_init",
        .sql = @embedFile("../../migrations/control/001_init.sql"),
    },
};

pub const MigrationRunner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MigrationRunner {
        return .{ .allocator = allocator };
    }

    pub fn migrationsTableSql() []const u8 {
        return
            \\CREATE TABLE IF NOT EXISTS _doctbase_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  name VARCHAR(255) NOT NULL,
            \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\);
        ;
    }

    pub fn recordMigrationSql(self: MigrationRunner, migration: Migration) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO _doctbase_migrations (version, name) VALUES ({d}, '{s}') ON CONFLICT (version) DO NOTHING;",
            .{ migration.version, migration.name },
        );
    }
};

test "control migrations embed 001_init.sql successfully" {
    try std.testing.expect(control_migrations.len >= 1);
    const m1 = control_migrations[0];
    try std.testing.expectEqual(@as(u32, 1), m1.version);
    try std.testing.expectEqualStrings("001_init", m1.name);
    try std.testing.expect(std.mem.indexOf(u8, m1.sql, "CREATE TABLE IF NOT EXISTS instances") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1.sql, "CREATE TABLE IF NOT EXISTS projects") != null);
}

test "migration runner generates valid tracking SQL" {
    const runner = MigrationRunner.init(std.testing.allocator);
    const sql = try runner.recordMigrationSql(control_migrations[0]);
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO _doctbase_migrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "001_init") != null);
}
