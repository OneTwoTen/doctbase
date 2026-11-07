const std = @import("std");
const packages = @import("install_packages");
const preflight = @import("preflight");

fn host(distro: []const u8, version: []const u8, architecture: []const u8) preflight.Facts {
    return .{
        .distro_id = distro,
        .version_id = version,
        .architecture = architecture,
        .memory_bytes = 2 * preflight.gib,
        .available_disk_bytes = 20 * preflight.gib,
    };
}

fn sourceFile(plan: packages.Plan, path: []const u8) ?packages.RepositoryFile {
    for (0..plan.len()) |index| {
        const action = plan.step(index) orelse continue;
        switch (action) {
            .write_file => |file| if (std.mem.eql(u8, file.path, path)) return file,
            .command => {},
        }
    }
    return null;
}

fn containsArgument(argv: []const []const u8, expected: []const u8) bool {
    for (argv) |argument| if (std.mem.eql(u8, argument, expected)) return true;
    return false;
}

const FakeExecutor = struct {
    calls: usize = 0,

    fn run(context: ?*anyopaque, _: []const []const u8) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        self.calls += 1;
    }

    fn write(context: ?*anyopaque, _: packages.RepositoryFile) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        self.calls += 1;
    }
};

test "PGDG source suite is selected from the supported distro release" {
    const cases = .{
        .{ "debian", "13", "x86_64", "trixie-pgdg" },
        .{ "ubuntu", "24.04", "aarch64", "noble-pgdg" },
        .{ "ubuntu", "26.04", "arm64", "resolute-pgdg" },
    };

    inline for (cases) |case| {
        const plan = try packages.buildPlan(host(case[0], case[1], case[2]), .{});
        const pgdg = sourceFile(plan, packages.pgdg_source_path) orelse return error.PgdgSourceMissing;
        try std.testing.expect(std.mem.indexOf(u8, pgdg.contents, case[3]) != null);
        try std.testing.expect(std.mem.indexOf(u8, pgdg.contents, "signed-by=") != null);
    }
}

test "package plan installs PostgreSQL 18, PgBouncer and official Caddy repository" {
    const plan = try packages.buildPlan(host("ubuntu", "24.04", "x86_64"), .{});
    const pgdg = sourceFile(plan, packages.pgdg_source_path) orelse return error.PgdgSourceMissing;
    const caddy = sourceFile(plan, packages.caddy_source_path) orelse return error.CaddySourceMissing;

    try std.testing.expect(std.mem.indexOf(u8, pgdg.contents, "https://apt.postgresql.org/pub/repos/apt") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy.contents, "https://dl.cloudsmith.io/public/caddy/stable/deb/debian") != null);
    try std.testing.expect(std.mem.indexOf(u8, caddy.contents, "signed-by=") != null);

    const install = plan.step(plan.len() - 1).?.command;
    try std.testing.expect(containsArgument(install, "postgresql-18"));
    try std.testing.expect(containsArgument(install, "pgbouncer"));
    try std.testing.expect(containsArgument(install, "caddy"));
    try std.testing.expect(!containsArgument(install, "libvips42t64"));
}

test "optional libvips package is included only when requested" {
    const plan = try packages.buildPlan(host("debian", "13", "arm64"), .{ .install_libvips = true });
    const install = plan.step(plan.len() - 1).?.command;
    try std.testing.expect(containsArgument(install, "libvips42t64"));
}

test "package plan rejects unsupported or incomplete host facts" {
    try std.testing.expectError(error.UnsupportedOperatingSystem, packages.buildPlan(host("fedora", "43", "x86_64"), .{}));
    try std.testing.expectError(error.UnsupportedOperatingSystem, packages.buildPlan(host("ubuntu", "25.10", "x86_64"), .{}));
    try std.testing.expectError(error.UnsupportedArchitecture, packages.buildPlan(host("ubuntu", "24.04", "riscv64"), .{}));

    var facts = host("ubuntu", "24.04", "x86_64");
    facts.collection_supported = false;
    try std.testing.expectError(error.UnsupportedHostPlatform, packages.buildPlan(facts, .{}));

    facts.collection_supported = true;
    facts.os_release_available = false;
    try std.testing.expectError(error.HostFactsUnavailable, packages.buildPlan(facts, .{}));
}

test "blocked preflight prevents package planning" {
    var facts = host("ubuntu", "24.04", "x86_64");
    facts.listeners = &.{.{ .port = 443, .service = "nginx.service" }};
    try std.testing.expectError(error.PreflightBlocked, packages.buildPlan(facts, .{}));

    facts.listeners = &.{};
    facts.memory_bytes = preflight.gib;
    try std.testing.expectError(error.PreflightBlocked, packages.buildPlan(facts, .{}));
}

test "package plan uses direct argv and dedicated repository paths" {
    const plan = try packages.buildPlan(host("ubuntu", "24.04", "x86_64"), .{});
    try std.testing.expectEqual(@as(usize, 10), plan.len());

    const first = plan.step(0).?.command;
    try std.testing.expectEqualStrings("/usr/bin/apt-get", first[0]);
    try std.testing.expectEqualStrings("update", first[1]);

    const pgdg_key = plan.step(2).?.command;
    try std.testing.expectEqualStrings("/usr/bin/curl", pgdg_key[0]);
    try std.testing.expect(containsArgument(pgdg_key, "https://www.postgresql.org/media/keys/ACCC4CF8.asc"));
    try std.testing.expect(containsArgument(pgdg_key, packages.pgdg_key_path));

    const caddy_key = plan.step(5).?.command;
    try std.testing.expect(containsArgument(caddy_key, "https://dl.cloudsmith.io/public/caddy/stable/gpg.key"));
    try std.testing.expect(containsArgument(caddy_key, packages.caddy_key_path));
}

test "package actions require the transaction safety guards" {
    const plan = try packages.buildPlan(host("ubuntu", "24.04", "x86_64"), .{});
    var fake = FakeExecutor{};
    const base_executor = packages.Executor{
        .context = &fake,
        .run_command = FakeExecutor.run,
        .write_file = FakeExecutor.write,
    };

    try std.testing.expectError(error.RootPrivilegesRequired, packages.executePlan(plan, base_executor));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    var executor = base_executor;
    executor.running_as_root = true;
    try std.testing.expectError(error.ServiceStartGuardRequired, packages.executePlan(plan, executor));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    executor.package_service_starts_suppressed = true;
    try std.testing.expectError(error.DefaultClusterGuardRequired, packages.executePlan(plan, executor));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    executor.postgres_default_cluster_creation_disabled = true;
    try packages.executePlan(plan, executor);
    try std.testing.expectEqual(plan.len(), fake.calls);
}
