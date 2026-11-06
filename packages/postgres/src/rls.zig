const std = @import("std");

/// Generate SQL statement to enable Row Level Security on a target table.
pub fn enableRlsSql(allocator: std.mem.Allocator, table_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" ENABLE ROW LEVEL SECURITY;", .{table_name});
}

/// Generate SQL statement to enforce default-deny (force RLS for table owner too).
pub fn forceRlsSql(allocator: std.mem.Allocator, table_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" FORCE ROW LEVEL SECURITY;", .{table_name});
}

/// Generate SQL statement for project-tenant isolation policy.
/// Enforces current_setting('request.project_id', true) = project_id.
pub fn projectTenantPolicySql(allocator: std.mem.Allocator, table_name: []const u8, project_col: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\CREATE POLICY "{s}_tenant_isolation" ON "{s}"
        \\  AS RESTRICTIVE
        \\  USING ("{s}" = NULLIF(current_setting('request.project_id', true), ''))
        \\  WITH CHECK ("{s}" = NULLIF(current_setting('request.project_id', true), ''));
    , .{ table_name, table_name, project_col, project_col });
}

test "rls helpers generate standard postgresql security statements" {
    const allocator = std.testing.allocator;

    const enable = try enableRlsSql(allocator, "documents");
    defer allocator.free(enable);
    try std.testing.expectEqualStrings("ALTER TABLE \"documents\" ENABLE ROW LEVEL SECURITY;", enable);

    const force = try forceRlsSql(allocator, "documents");
    defer allocator.free(force);
    try std.testing.expectEqualStrings("ALTER TABLE \"documents\" FORCE ROW LEVEL SECURITY;", force);

    const policy = try projectTenantPolicySql(allocator, "documents", "project_id");
    defer allocator.free(policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "CREATE POLICY \"documents_tenant_isolation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "current_setting('request.project_id', true)") != null);
}
