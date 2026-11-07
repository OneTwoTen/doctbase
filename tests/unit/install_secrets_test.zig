const std = @import("std");
const secrets = @import("install_secrets");

fn executorFor(fake: *FakeExecutor) secrets.Executor {
    return .{
        .context = fake,
        .stat_secret = FakeExecutor.stat,
        .create_secret = FakeExecutor.create,
        .repair_permissions = FakeExecutor.repair,
    };
}

fn expectLowerHex(content: []const u8) !void {
    for (content) |byte| {
        try std.testing.expect((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
    }
}

fn recordName(destination: *[64]u8, length: *usize, path: []const u8) !void {
    const name = std.Io.Dir.path.basename(path);
    if (name.len > destination.len) return error.NameTooLong;
    @memcpy(destination[0..name.len], name);
    length.* = name.len;
}

fn existing(mode: u16, owner_ok: bool, group_ok: bool) secrets.ExistingSecret {
    return .{
        .mode = mode,
        .owner_ok = owner_ok,
        .group_ok = group_ok,
        .regular_file = true,
    };
}

fn allExisting() [secrets.specs.len]?secrets.ExistingSecret {
    return .{
        existing(0o600, true, true),
        existing(0o600, true, true),
        existing(0o600, true, true),
        existing(0o600, true, true),
    };
}

const FakeExecutor = struct {
    states: [secrets.specs.len]?secrets.ExistingSecret = @splat(null),
    stat_count: usize = 0,
    create_count: usize = 0,
    repair_count: usize = 0,
    created_names: [secrets.specs.len][64]u8 = undefined,
    created_name_lengths: [secrets.specs.len]usize = @splat(0),
    created_contents: [secrets.specs.len][64]u8 = undefined,
    repaired_names: [secrets.specs.len][64]u8 = undefined,
    repaired_name_lengths: [secrets.specs.len]usize = @splat(0),

    fn stat(context: ?*anyopaque, path: []const u8) anyerror!?secrets.ExistingSecret {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        const index = self.stat_count;
        self.stat_count += 1;
        if (index >= secrets.specs.len) return error.UnexpectedStat;

        var expected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const expected = try secrets.secretPath(&expected_buffer, secrets.specs[index]);
        try std.testing.expectEqualStrings(expected, path);
        return self.states[index];
    }

    fn create(context: ?*anyopaque, path: []const u8, contents: []const u8) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        const index = self.create_count;
        if (index >= secrets.specs.len) return error.UnexpectedCreate;
        if (contents.len != 64) return error.UnexpectedSecretLength;

        try recordName(&self.created_names[index], &self.created_name_lengths[index], path);
        @memcpy(self.created_contents[index][0..contents.len], contents);
        self.create_count += 1;
    }

    fn repair(context: ?*anyopaque, path: []const u8) anyerror!void {
        const self: *FakeExecutor = @ptrCast(@alignCast(context.?));
        const index = self.repair_count;
        if (index >= secrets.specs.len) return error.UnexpectedRepair;

        try recordName(&self.repaired_names[index], &self.repaired_name_lengths[index], path);
        self.repair_count += 1;
    }
};

test "secret specs are the documented 256-bit secrets" {
    const expected_names = [_][]const u8{
        "postgres_admin",
        "pgbouncer_auth",
        "internal_token",
        "admin_setup_token",
    };

    try std.testing.expectEqual(expected_names.len, secrets.specs.len);
    for (expected_names, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, secrets.specs[index].name);
        try std.testing.expectEqual(@as(usize, 32), secrets.specs[index].bytes);
    }

    try std.testing.expectEqualStrings("/etc/doctbase/secrets", secrets.directory);
    try std.testing.expectEqualStrings("root", secrets.owner);
    try std.testing.expectEqualStrings("doctbase", secrets.group);
}

test "secret files are readable only by their owner and group" {
    try std.testing.expectEqual(@as(u16, 0o600), secrets.file_mode);
    try std.testing.expectEqual(@as(u16, 0), secrets.file_mode & 0o077);
}

test "secret paths stay directly inside the secrets directory" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var expected_buffer: [128]u8 = undefined;

    for (secrets.specs) |spec| {
        const path = try secrets.secretPath(&buffer, spec);
        const expected = try std.fmt.bufPrint(&expected_buffer, "/etc/doctbase/secrets/{s}", .{spec.name});
        try std.testing.expectEqualStrings(expected, path);
        try std.testing.expect(std.mem.indexOfAny(u8, spec.name, "/\\.") == null);
    }
}

test "generated secrets are unique lowercase hex without a newline" {
    const first = try secrets.generateSecret(std.testing.allocator, std.testing.io, secrets.specs[0]);
    defer std.testing.allocator.free(first);
    const second = try secrets.generateSecret(std.testing.allocator, std.testing.io, secrets.specs[0]);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqual(@as(usize, 64), first.len);
    try std.testing.expectEqual(@as(usize, 64), second.len);
    try expectLowerHex(first);
    try expectLowerHex(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.indexOfScalar(u8, first, '\n') == null);
}

test "secret drift keeps contents and only repairs platform-owned modes" {
    const matching = existing(0o600, true, true);

    try std.testing.expectEqual(secrets.Drift.create, secrets.drift(null));
    try std.testing.expectEqual(secrets.Drift.keep, secrets.drift(matching));

    var loose = matching;
    loose.mode = 0o644;
    try std.testing.expectEqual(secrets.Drift.repair, secrets.drift(loose));

    var foreign_owner = matching;
    foreign_owner.owner_ok = false;
    try std.testing.expectEqual(secrets.Drift.conflict, secrets.drift(foreign_owner));

    var foreign_group = matching;
    foreign_group.group_ok = false;
    try std.testing.expectEqual(secrets.Drift.conflict, secrets.drift(foreign_group));

    var symlink = matching;
    symlink.regular_file = false;
    try std.testing.expectEqual(secrets.Drift.conflict, secrets.drift(symlink));
}

test "secret installation requires root before probing the host" {
    var fake = FakeExecutor{};
    const executor = executorFor(&fake);

    try std.testing.expectError(
        error.RootPrivilegesRequired,
        secrets.ensureSecrets(std.testing.io, std.testing.allocator, executor),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.stat_count);
    try std.testing.expectEqual(@as(usize, 0), fake.create_count);
}

test "missing secrets are generated once in documented order" {
    var fake = FakeExecutor{};
    var executor = executorFor(&fake);
    executor.running_as_root = true;

    try secrets.ensureSecrets(std.testing.io, std.testing.allocator, executor);

    try std.testing.expectEqual(secrets.specs.len, fake.stat_count);
    try std.testing.expectEqual(secrets.specs.len, fake.create_count);
    try std.testing.expectEqual(@as(usize, 0), fake.repair_count);

    for (0..fake.create_count) |index| {
        const name = fake.created_names[index][0..fake.created_name_lengths[index]];
        try std.testing.expectEqualStrings(secrets.specs[index].name, name);

        const content = fake.created_contents[index][0..64];
        try expectLowerHex(content);
        for (0..index) |other| {
            try std.testing.expect(!std.mem.eql(u8, content, fake.created_contents[other][0..64]));
        }
    }
}

test "existing secrets are kept without regeneration" {
    var fake = FakeExecutor{};
    fake.states = allExisting();
    var executor = executorFor(&fake);
    executor.running_as_root = true;

    try secrets.ensureSecrets(std.testing.io, std.testing.allocator, executor);

    try std.testing.expectEqual(secrets.specs.len, fake.stat_count);
    try std.testing.expectEqual(@as(usize, 0), fake.create_count);
    try std.testing.expectEqual(@as(usize, 0), fake.repair_count);
}

test "loose secret permissions are repaired without rewriting contents" {
    var fake = FakeExecutor{};
    fake.states = allExisting();
    fake.states[2] = existing(0o644, true, true);
    var executor = executorFor(&fake);
    executor.running_as_root = true;

    try secrets.ensureSecrets(std.testing.io, std.testing.allocator, executor);

    try std.testing.expectEqual(@as(usize, 0), fake.create_count);
    try std.testing.expectEqual(@as(usize, 1), fake.repair_count);
    try std.testing.expectEqualStrings(
        "internal_token",
        fake.repaired_names[0][0..fake.repaired_name_lengths[0]],
    );
}

test "ownership conflicts fail before any secret is written" {
    var fake = FakeExecutor{};
    fake.states = allExisting();
    fake.states[2] = existing(0o600, false, true);
    fake.states[3] = null;
    var executor = executorFor(&fake);
    executor.running_as_root = true;

    try std.testing.expectError(
        error.SecretOwnershipConflict,
        secrets.ensureSecrets(std.testing.io, std.testing.allocator, executor),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.create_count);
    try std.testing.expectEqual(@as(usize, 0), fake.repair_count);
}

test "evaluate reports drift without mutating the host" {
    var fake = FakeExecutor{};
    fake.states = allExisting();
    fake.states[0] = null;
    fake.states[2] = existing(0o640, true, true);
    fake.states[3] = existing(0o600, true, false);

    var decisions: secrets.Decisions = undefined;
    try secrets.evaluate(executorFor(&fake), &decisions);

    try std.testing.expectEqual(secrets.Drift.create, decisions[0]);
    try std.testing.expectEqual(secrets.Drift.keep, decisions[1]);
    try std.testing.expectEqual(secrets.Drift.repair, decisions[2]);
    try std.testing.expectEqual(secrets.Drift.conflict, decisions[3]);
    try std.testing.expectEqual(@as(usize, 0), fake.create_count);
    try std.testing.expectEqual(@as(usize, 0), fake.repair_count);
}
