const std = @import("std");
const users = @import("install_users");

fn actionAt(index: usize) users.Action {
    return users.plan.step(index).?;
}

fn findDirectory(path: []const u8) ?users.DirectorySpec {
    for (0..users.plan.len()) |index| {
        switch (actionAt(index)) {
            .ensure_directory => |spec| {
                if (std.mem.eql(u8, spec.path, path)) return spec;
            },
            else => {},
        }
    }
    return null;
}

fn findUser(name: []const u8) ?users.UserSpec {
    for (0..users.plan.len()) |index| {
        switch (actionAt(index)) {
            .ensure_user => |spec| {
                if (std.mem.eql(u8, spec.name, name)) return spec;
            },
            else => {},
        }
    }
    return null;
}

test "plan orders the shared group, service accounts, directories and tmpfiles" {
    try std.testing.expectEqual(
        @as(usize, 1 + users.service_users.len + users.directories.len + 1),
        users.plan.len(),
    );

    const group_action = actionAt(0);
    try std.testing.expectEqual(users.Action.ensure_group, std.meta.activeTag(group_action));
    try std.testing.expectEqualStrings(users.group_name, group_action.ensure_group);

    var index: usize = 1;
    for (users.service_users) |name| {
        const action = actionAt(index);
        try std.testing.expectEqual(users.Action.ensure_user, std.meta.activeTag(action));
        try std.testing.expectEqualStrings(name, action.ensure_user.name);
        index += 1;
    }

    for (users.directories) |expected| {
        const action = actionAt(index);
        try std.testing.expectEqual(users.Action.ensure_directory, std.meta.activeTag(action));
        try std.testing.expectEqualStrings(expected.path, action.ensure_directory.path);
        index += 1;
    }

    const tmpfiles = actionAt(index);
    try std.testing.expectEqual(users.Action.apply_tmpfiles, std.meta.activeTag(tmpfiles));
    try std.testing.expectEqualStrings(users.tmpfiles_path, tmpfiles.apply_tmpfiles);
    try std.testing.expect(users.plan.step(index + 1) == null);
}

test "service accounts are unprivileged system users in the shared group" {
    var found: usize = 0;
    for (0..users.plan.len()) |index| {
        switch (actionAt(index)) {
            .ensure_user => |spec| {
                found += 1;
                try std.testing.expect(spec.system_account);
                try std.testing.expect(!spec.create_home);
                try std.testing.expectEqualStrings(users.group_name, spec.group);
                try std.testing.expectEqualStrings(users.nonexistent_home, spec.home);
                try std.testing.expectEqualStrings(users.nologin_shell, spec.shell);
                try std.testing.expect(!std.mem.eql(u8, "root", spec.name));
            },
            else => {},
        }
    }
    try std.testing.expectEqual(users.service_users.len, found);

    const gateway = findUser("doctbase-gateway") orelse return error.MissingServiceUser;
    try std.testing.expectEqualStrings("doctbase-gateway", gateway.name);
}

test "directory modes and owners follow the documented layout" {
    const expected_directories = [_]struct {
        path: []const u8,
        mode: u16,
        owner: []const u8,
    }{
        .{ .path = "/etc/doctbase", .mode = 0o750, .owner = "root" },
        .{ .path = "/etc/doctbase/secrets", .mode = 0o700, .owner = "root" },
        .{ .path = "/etc/doctbase/generated", .mode = 0o750, .owner = "doctbase-management" },
        .{ .path = "/var/lib/doctbase", .mode = 0o750, .owner = "root" },
        .{ .path = "/var/lib/doctbase/projects", .mode = 0o770, .owner = "doctbase-management" },
        .{ .path = "/var/lib/doctbase/auth", .mode = 0o700, .owner = "doctbase-auth" },
        .{ .path = "/var/lib/doctbase/pgbouncer", .mode = 0o700, .owner = "doctbase-pgbouncer" },
        .{ .path = "/var/lib/doctbase/cache", .mode = 0o770, .owner = "doctbase-image" },
        .{ .path = "/var/lib/doctbase/caddy", .mode = 0o700, .owner = "doctbase-caddy" },
        .{ .path = "/var/lib/doctbase/backups", .mode = 0o770, .owner = "doctbase-backup" },
        .{ .path = "/var/log/doctbase", .mode = 0o750, .owner = "root" },
    };

    try std.testing.expectEqual(expected_directories.len, users.directories.len);
    for (expected_directories) |expected| {
        const spec = findDirectory(expected.path) orelse return error.MissingDirectory;
        try std.testing.expectEqual(expected.mode, spec.mode);
        try std.testing.expectEqualStrings(expected.owner, spec.owner);
        try std.testing.expectEqualStrings(users.group_name, spec.group);
    }
}

test "installed directories are never world-accessible" {
    for (users.directories) |spec| {
        try std.testing.expectEqual(@as(u16, 0), spec.mode & 0o007);
    }
}

test "user drift keeps matching accounts and rejects foreign ones" {
    const spec = users.UserSpec{ .name = "doctbase-gateway" };
    try std.testing.expectEqual(users.Drift.create, users.userDrift(null, spec));

    const matching = users.ExistingUser{
        .system_account = true,
        .group = users.group_name,
        .home = users.nonexistent_home,
        .shell = users.nologin_shell,
    };
    try std.testing.expectEqual(users.Drift.keep, users.userDrift(matching, spec));

    var foreign = matching;
    foreign.system_account = false;
    try std.testing.expectEqual(users.Drift.conflict, users.userDrift(foreign, spec));

    foreign = matching;
    foreign.group = "users";
    try std.testing.expectEqual(users.Drift.conflict, users.userDrift(foreign, spec));

    foreign = matching;
    foreign.home = "/home/operator";
    try std.testing.expectEqual(users.Drift.conflict, users.userDrift(foreign, spec));
}

test "directory drift repairs modes only for platform-owned directories" {
    const spec = users.DirectorySpec{
        .path = "/var/lib/doctbase/auth",
        .mode = 0o700,
        .owner = "doctbase-auth",
    };
    try std.testing.expectEqual(users.Drift.create, users.directoryDrift(null, spec));

    const matching = users.ExistingDirectory{
        .mode = 0o700,
        .owner = "doctbase-auth",
        .group = users.group_name,
    };
    try std.testing.expectEqual(users.Drift.keep, users.directoryDrift(matching, spec));

    var drifted = matching;
    drifted.mode = 0o755;
    try std.testing.expectEqual(users.Drift.repair, users.directoryDrift(drifted, spec));

    var foreign = matching;
    foreign.owner = "nobody";
    try std.testing.expectEqual(users.Drift.conflict, users.directoryDrift(foreign, spec));
}

test "tmpfiles creates the runtime socket directory with restricted modes" {
    try std.testing.expectEqualStrings("/etc/tmpfiles.d/doctbase.conf", users.tmpfiles_path);

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "deploy/native/tmpfiles/doctbase.conf",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "d /run/doctbase 0770 root doctbase -") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "0777") == null);
}

const FakeExecutor = struct {
    calls: usize = 0,
    order: [32]u8 = undefined,

    fn record(context: ?*anyopaque, tag: u8) void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        self.order[self.calls] = tag;
        self.calls += 1;
    }

    fn ensureGroup(context: ?*anyopaque, _: []const u8) anyerror!void {
        record(context, 'g');
    }

    fn ensureUser(context: ?*anyopaque, _: users.UserSpec) anyerror!void {
        record(context, 'u');
    }

    fn ensureDirectory(context: ?*anyopaque, _: users.DirectorySpec) anyerror!void {
        record(context, 'd');
    }

    fn applyTmpfiles(context: ?*anyopaque, _: []const u8) anyerror!void {
        record(context, 't');
    }
};

test "identity plan requires root privileges before touching the host" {
    var fake = FakeExecutor{};
    const executor = users.Executor{
        .context = &fake,
        .ensure_group = FakeExecutor.ensureGroup,
        .ensure_user = FakeExecutor.ensureUser,
        .ensure_directory = FakeExecutor.ensureDirectory,
        .apply_tmpfiles = FakeExecutor.applyTmpfiles,
    };

    try std.testing.expectError(error.RootPrivilegesRequired, users.executePlan(users.plan, executor));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "identity plan applies group, users, directories and tmpfiles in order" {
    var fake = FakeExecutor{};
    const executor = users.Executor{
        .context = &fake,
        .ensure_group = FakeExecutor.ensureGroup,
        .ensure_user = FakeExecutor.ensureUser,
        .ensure_directory = FakeExecutor.ensureDirectory,
        .apply_tmpfiles = FakeExecutor.applyTmpfiles,
        .running_as_root = true,
    };

    try users.executePlan(users.plan, executor);
    try std.testing.expectEqual(users.plan.len(), fake.calls);
    try std.testing.expectEqual(@as(u8, 'g'), fake.order[0]);
    try std.testing.expectEqual(@as(u8, 't'), fake.order[fake.calls - 1]);
}
